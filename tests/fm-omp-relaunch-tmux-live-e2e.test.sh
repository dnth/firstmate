#!/usr/bin/env bash
# Opt-in real OMP same-task relaunch on a private tmux socket.
set -u

if [ "${FM_OMP_TMUX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_TMUX_LIVE_E2E=1 to run the isolated OMP relaunch lifecycle"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v omp >/dev/null 2>&1 || { echo "omp not found"; exit 1; }
command -v tmux >/dev/null 2>&1 || { echo "tmux not found"; exit 1; }

LAB=$(fm_test_tmproot fm-omp-relaunch-live)
REAL_TMUX=$(command -v tmux)
SOCKET="fm-omp-relaunch-live-$$"
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
ORIGIN="$LAB/origin.git"
WRAPPER_BIN="$LAB/bin"
WORKER_ID="omp-relaunch-live-${LAB##*/}"
WORKER_WT="$LAB/worker-wt"

wait_file() {
  local file=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -f "$file" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

wait_turnend() {
  local sd=$1 id=$2 attempts=${3:-240} i=0 g
  while [ "$i" -lt "$attempts" ]; do
    for g in "$sd/$id".turn-ended.*; do
      [ -f "$g" ] && return 0
    done
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

capture() {
  PATH="$WRAPPER_BIN:$PATH" tmux capture-pane -p -t "$1" -S -220 2>/dev/null || true
}

agent_state() {
  PATH="$WRAPPER_BIN:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; meta=$(fm_backend_meta_for_window "$2" "$3") || exit 1; fm_backend_agent_state tmux "$2" "$meta"' \
    _ "$ROOT" "$1" "$HOME_DIR/state"
}

cleanup() {
  PATH="$WRAPPER_BIN:$PATH" tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "/tmp/fm-$WORKER_ID"
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/data/$WORKER_ID" "$HOME_DIR/state" "$HOME_DIR/config" \
  "$HOME_DIR/projects" "$WRAPPER_BIN" "$PROJECT"

git init -q -b main "$PROJECT"
fm_git_identity fmtest fmtest@example.invalid
echo fixture > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm init
git init -q --bare "$ORIGIN"
git -C "$PROJECT" remote add origin "$ORIGIN"
git -C "$PROJECT" push -q -u origin main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$PROJECT" remote set-head origin main
git -C "$PROJECT" worktree add -q -b "fm/$WORKER_ID" "$WORKER_WT"

cat > "$WRAPPER_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
EOF
cat > "$WRAPPER_BIN/treehouse" <<EOF
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  get)
    shift
    lease=0
    holder=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --lease) lease=1 ;;
        --lease-holder) shift; holder=\${1:-} ;;
        --lease-holder=*) holder=\${1#--lease-holder=} ;;
      esac
      shift
    done
    if [ "\$lease" -eq 1 ]; then
      ( cd '$WORKER_WT' \
        && git checkout --detach --force HEAD >/dev/null \
        && git reset --hard HEAD >/dev/null \
        && git clean -fd >/dev/null ) || exit \$?
      printf '%s\n' '$WORKER_WT'
      exit 0
    fi
    ;;
  return)
    exit 0
    ;;
esac
window=\$(tmux display-message -p -t "\${TMUX_PANE:?}" '#{window_name}')
case "\$window" in
  fm-$WORKER_ID) cd '$WORKER_WT' || exit 1 ;;
  *) echo "unexpected window: \$window" >&2; exit 1 ;;
esac
exec bash --noprofile --norc
EOF
chmod +x "$WRAPPER_BIN/tmux" "$WRAPPER_BIN/treehouse"

printf '1m\n' > "$HOME_DIR/config/omp-max-time"

printf 'Delivery contract: mode=no-mistakes\nReply exactly RELAUNCH_LIVE_OK, then wait for further instruction.\n' > "$HOME_DIR/data/$WORKER_ID/brief.md"

FIXTURE_PATH="$WRAPPER_BIN:$PATH"
PATH="$FIXTURE_PATH" tmux new-session -d -s firstmate -n fixture -c "$PROJECT"
PATH="$FIXTURE_PATH" tmux set-option -g default-shell /bin/bash
PATH="$FIXTURE_PATH" tmux set-option -g default-command "env PATH='$FIXTURE_PATH' bash --noprofile --norc"

FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
  OMP_SKIP_SETUP=1 PATH="$FIXTURE_PATH" \
  "$ROOT/bin/fm-spawn.sh" "$WORKER_ID" "$PROJECT" --harness omp \
    --mode no-mistakes --yolo off --model openai-codex/gpt-5.6-luna --effort low >/dev/null \
  || { echo "initial spawn failed"; exit 1; }

META="$HOME_DIR/state/$WORKER_ID.meta"
TARGET=$(sed -n 's/^window=//p' "$META")
WT=$(sed -n 's/^worktree=//p' "$META")

echo "initial target=$TARGET worktree=$WT"
wait_file "$HOME_DIR/state/$WORKER_ID.omp-ready" || { echo "no omp-ready"; exit 1; }
wait_file "$HOME_DIR/state/$WORKER_ID.omp-started" || { echo "no omp-started"; exit 1; }

i=0
while [ "$i" -lt 120 ]; do
  [ "$(capture "$TARGET" | grep -Fc RELAUNCH_LIVE_OK)" -ge 1 ] && break
  sleep 0.25
  i=$((i + 1))
done
[ "$i" -lt 120 ] || { echo "no RELAUNCH_LIVE_OK"; capture "$TARGET"; exit 1; }

# Preserve dirty sentinel and pending instruction
printf 'dirty-sentinel\n' > "$WT/sentinel.txt"
mkdir -p "$HOME_DIR/state/$WORKER_ID.inbox"
printf 'After the relaunch, respond exactly RESUMED.\n' > "$HOME_DIR/state/$WORKER_ID.inbox/001.msg"

# Send /exit
FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BACKEND=tmux FM_SEND_SLEEP=0.2 \
  FM_SEND_SETTLE=0 PATH="$FIXTURE_PATH" \
  "$ROOT/bin/fm-send.sh" "$WORKER_ID" /exit >/dev/null \
  || { echo "send /exit failed"; exit 1; }

for _ in $(seq 1 120); do
  [ "$(agent_state "$TARGET")" = dead ] && break
  sleep 0.25
done
[ "$(agent_state "$TARGET")" = dead ] || { echo "agent not dead after /exit"; exit 1; }

GEN1=$(sed -n 's/^spawn_gen=//p' "$META")
echo "gen before=$GEN1"

# Relaunch
FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
  OMP_SKIP_SETUP=1 PATH="$FIXTURE_PATH" \
  "$ROOT/bin/fm-spawn.sh" "$WORKER_ID" --relaunch >/dev/null \
  || { echo "relaunch failed"; exit 1; }

wait_file "$HOME_DIR/state/$WORKER_ID.omp-ready" 240 || { echo "relauch did not write omp-ready"; exit 1; }
wait_file "$HOME_DIR/state/$WORKER_ID.omp-started" 240 || { echo "relauch did not write omp-started"; exit 1; }

GEN2=$(sed -n 's/^spawn_gen=//p' "$META")
echo "gen after=$GEN2"
[ "$GEN1" != "$GEN2" ] || { echo "spawn_gen did not change"; exit 1; }

[ -d "$WT" ] || { echo "worktree missing"; exit 1; }
[ -f "$WT/sentinel.txt" ] || { echo "dirty sentinel missing"; exit 1; }
[ -f "$HOME_DIR/state/$WORKER_ID.inbox/001.msg" ] || { echo "pending instruction missing"; exit 1; }

WT_COUNT=$(git -C "$PROJECT" worktree list --porcelain | grep -c '^worktree ')
[ "$WT_COUNT" -eq 2 ] || { echo "unexpected worktree count: $WT_COUNT"; exit 1; }

# Wait for the relaunched turn to complete and re-acknowledge
i=0
while [ "$i" -lt 240 ]; do
  [ "$(capture "$TARGET" | grep -Fc RELAUNCH_LIVE_OK)" -ge 2 ] && break
  sleep 0.25
  i=$((i + 1))
done
[ "$i" -lt 240 ] || { echo "relaunch did not re-acknowledge"; capture "$TARGET"; exit 1; }
wait_turnend "$HOME_DIR/state" "$WORKER_ID" 240 || { echo "relauch turn did not end"; exit 1; }

echo "ok - real tmux OMP relaunch: preserved worktree/inbox, new generation, and resumed acknowledgement"
