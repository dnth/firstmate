#!/usr/bin/env bash
# Opt-in live guard for the omp semantic busy state (bin/fm-busy-lib.sh's
# omp-ext source). It drives a REAL installed omp session through the extension
# fm-spawn generates, and asserts the classifier reports busy during a turn and
# idle after it, so fm-crew-state.sh never reports `unknown` for a healthy omp
# worker. Run after every omp upgrade; docs/verification/runtime-backends.md
# records the dated result and points here.
#
#   FM_OMP_BUSY_LIVE_E2E=1 bash tests/fm-omp-busy-live-e2e.test.sh
set -u

if [ "${FM_OMP_BUSY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_BUSY_LIVE_E2E=1 to run the real-OMP busy-state guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

command -v omp >/dev/null 2>&1 || {
  echo "skip: omp not found on PATH; the live OMP busy-state guard checked nothing"
  exit 0
}
command -v node >/dev/null 2>&1 || fail "node not found"

OMP_VERSION=$(omp --version 2>&1 | head -1)
[ -n "$OMP_VERSION" ] || fail "installed omp did not report a version"

TMP_ROOT=$(fm_test_tmproot fm-omp-busy-live)
ID=omp-busy-live
rm -rf -- "/tmp/fm-$ID"
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
WT="$TMP_ROOT/wt"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$FAKEBIN"
printf '%s\n' omp > "$HOME_DIR/config/crew-harness"
printf 'Live busy-state guard for %s\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
fm_git_worktree "$PROJECT" "$WT" "wt-$ID"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    for a in "$@"; do
      case "$a" in
        touch\ */.fm-launch-probe.*)
          marker=${a#touch }
          marker=${marker#\'}
          marker=${marker%\'}
          : > "$marker"
          ;;
      esac
    done
    lit=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        lit=$arg
        break
      fi
      prev=$arg
    done
    if [ -n "${FM_FAKE_OMP_ACK_STATE:-}" ]; then
      text=$lit
      case "$lit" in
        *.fm-launch-*)
          script=${lit#/bin/bash }
          script=${script#\'}
          script=${script%\'}
          [ ! -f "$script" ] || text=$(cat "$script")
          ;;
      esac
      case "$text" in
        *FM_OMP_HARNESS=omp*)
          for ext in "$FM_FAKE_OMP_ACK_STATE"/*.omp-ext.ts; do
            [ -e "$ext" ] || continue
            stem=${ext%.omp-ext.ts}
            : > "$stem.omp-doorbell-ready"
            : > "$stem.omp-started"
          done
          ;;
      esac
    fi
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

# The omp adapter always leases a pooled worktree. This stand-in runs the
# reset+clean sequence the guarded acquisition requires through the guard
# fm-treehouse-get places first on PATH, then reports the fixture worktree.
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    wt=${FM_FAKE_TREEHOUSE_WT:?}
    ( cd "$wt" && git checkout --force HEAD && git clean -fdq ) || exit 1
    printf '%s\n' "$wt"
    ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKEBIN/treehouse"

FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" TMUX="fake,1,0" \
  FM_FAKE_OMP_ACK_STATE="$HOME_DIR/state" FM_FAKE_TREEHOUSE_WT="$WT" \
  GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --mode no-mistakes --yolo off --harness omp 2>&1 \
  || fail "the live omp worker spawn failed"

STATE_DIR="$HOME_DIR/state"
EXT="$STATE_DIR/$ID.omp-ext.ts"
[ -f "$EXT" ] || fail "the live omp spawn wrote no per-task extension"
[ -f "$STATE_DIR/$ID.busy-gen" ] || fail "the live omp spawn did not arm the busy contract"

classify() {
  fm_busy_classify tmux fake:w omp "$ID" "$STATE_DIR"
}

[ "$(classify)" = "busy fm-spawn" ] || fail "the spawn seed must classify 'busy fm-spawn', got '$(classify)'"

# One turn that keeps the agent running long enough to observe the state edge.
# The tool call forces a second inner turn, so busy==omp-ext also proves the
# inner turn boundary did not clear the record.
OMP_LOG="$TMP_ROOT/omp-turn.log"
( cd "$WT" && omp --no-session -p --auto-approve -e "$EXT" \
  "Run the shell command 'sleep 8; echo hi' and then reply with exactly DONE" \
  >"$OMP_LOG" 2>&1 ) &
OMP_PID=$!

BUSY_SEEN=0
n=0
while [ "$n" -lt 300 ]; do
  verdict=$(classify)
  case "$verdict" in
    unknown\ *) fail "the live omp worker classified '$verdict' during its turn" ;;
    busy\ omp-ext) BUSY_SEEN=1 ;;
  esac
  [ "$BUSY_SEEN" -eq 0 ] || break
  kill -0 "$OMP_PID" 2>/dev/null || break
  sleep 0.2
  n=$((n + 1))
done

wait "$OMP_PID" || fail "the live omp turn failed; log follows:"$'\n'"$(cat "$OMP_LOG")"
[ "$BUSY_SEEN" -eq 1 ] || fail "the live omp turn never reported 'busy omp-ext'; final verdict '$(classify)'"$'\n'"$(cat "$OMP_LOG")"

n=0
IDLE_SEEN=0
while [ "$n" -lt 100 ]; do
  verdict=$(classify)
  if [ "$verdict" = "idle omp-ext" ]; then
    IDLE_SEEN=1
    break
  fi
  sleep 0.1
  n=$((n + 1))
done
[ "$IDLE_SEEN" -eq 1 ] || fail "the live omp turn never settled to 'idle omp-ext'; final verdict '$(classify)'"

grep -F 'DONE' "$OMP_LOG" >/dev/null || fail "the live omp turn did not complete; log follows:"$'\n'"$(cat "$OMP_LOG")"

pass "$OMP_VERSION: real omp reports 'busy omp-ext' during a turn and 'idle omp-ext' after it (never unknown)"
