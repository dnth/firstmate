#!/usr/bin/env bash
# Opt-in real OMP worker/scout lifecycle on a private tmux socket.
set -u

if [ "${FM_OMP_TMUX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_TMUX_LIVE_E2E=1 to run the isolated OMP worker/scout lifecycle"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v omp >/dev/null 2>&1 || fail "omp not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"
LAB=$(fm_test_tmproot fm-omp-worker-tmux-live)
REAL_TMUX=$(command -v tmux)
SOCKET="fm-omp-worker-live-$$"
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
WRAPPER_BIN="$LAB/bin"
"$ROOT/bin/fm-omp-capabilities.sh" >/dev/null || fail "OMP capability check failed"
WORKER_ID=omp-live-worker
SCOUT_ID=omp-live-scout
WORKER_WT="$LAB/worker-wt"
SCOUT_WT="$LAB/scout-wt"
ORIGIN="$LAB/origin.git"

remove_clean_worktree() {
  local wt=$1 label=$2
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    printf 'not ok - %s worktree is dirty; preserving %s\n' "$label" "$wt" >&2
    return 1
  fi
  git -C "$PROJECT" worktree remove "$wt" >/dev/null 2>&1
}

cleanup() {
  local cleanup_ok=1
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 1
  remove_clean_worktree "$WORKER_WT" worker || cleanup_ok=0
  remove_clean_worktree "$SCOUT_WT" scout || cleanup_ok=0
  rm -rf "/tmp/fm-$WORKER_ID" "/tmp/fm-$SCOUT_ID"
  if [ "$cleanup_ok" -eq 1 ]; then
    rm -rf "$LAB"
  else
    printf 'not ok - OMP live fixture cleanup incomplete; preserving %s\n' "$LAB" >&2
  fi
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/data/$WORKER_ID" "$HOME_DIR/data/$SCOUT_ID" \
  "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$WRAPPER_BIN" \
  "$PROJECT/.omp/skills/fm-omp-probe"
printf '%s\n' \
  'Remember the token OMP_CONTEXT_TOKEN_73 for this session.' \
  'Respond exactly OMP_INITIAL_DONE and do nothing else.' \
  > "$HOME_DIR/data/$WORKER_ID/brief.md"
printf '%s\n' 'Respond exactly OMP_SCOUT_INITIAL_DONE and do nothing else.' \
  > "$HOME_DIR/data/$SCOUT_ID/brief.md"
cat > "$PROJECT/.omp/skills/fm-omp-probe/SKILL.md" <<'EOF'
---
name: fm-omp-probe
description: Test-only OMP skill submission probe.
---

Respond exactly `OMP_SKILL_DONE`.
EOF
printf 'fixture\n' > "$PROJECT/README.md"
git init -q -b main "$PROJECT"
fm_git_identity fmtest fmtest@example.invalid
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm init
git init -q --bare "$ORIGIN"
git -C "$PROJECT" remote add origin "$ORIGIN"
git -C "$PROJECT" push -q -u origin main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$PROJECT" remote set-head origin main
git -C "$PROJECT" worktree add -q -b fm/omp-live-worker "$WORKER_WT"
git -C "$PROJECT" worktree add -q -b fm/omp-live-scout "$SCOUT_WT"

cat > "$WRAPPER_BIN/tmux" <<SH
#!/usr/bin/env bash
exec '$REAL_TMUX' -L '$SOCKET' "\$@"
SH
cat > "$WRAPPER_BIN/treehouse" <<SH
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
      case "\$holder" in
        fm-$WORKER_ID) worktree='$WORKER_WT' ;;
        fm-$SCOUT_ID) worktree='$SCOUT_WT' ;;
        *) echo "unexpected OMP live fixture lease holder: \$holder" >&2; exit 1 ;;
      esac
      # Fresh fixture acquisition must satisfy fm-treehouse-get's guarded
      # clean-base proof. Recovery never enters this branch.
      (
        cd "\$worktree" || exit 1
        git reset --hard HEAD >/dev/null
        git clean -fd >/dev/null
      ) || exit 1
      printf '%s\n' "\$worktree"
      exit 0
    fi
    ;;
  status)
    [ "\${2:-}" = --json ] || exit 1
    printf '[{"path":"%s","status":"leased","lease_holder":"fm-$WORKER_ID","lease_id":"worker-live"},{"path":"%s","status":"leased","lease_holder":"fm-$SCOUT_ID","lease_id":"scout-live"}]\n' \
      '$WORKER_WT' '$SCOUT_WT'
    exit 0
    ;;
  return)
    exit 0
    ;;
esac
window=\$(tmux display-message -p -t "\${TMUX_PANE:?}" '#{window_name}')
case "\$window" in
  fm-$WORKER_ID) cd '$WORKER_WT' || exit 1 ;;
  fm-$SCOUT_ID) cd '$SCOUT_WT' || exit 1 ;;
  *) echo "unexpected OMP live fixture window: \$window" >&2; exit 1 ;;
esac
exec bash --noprofile --norc
SH
chmod +x "$WRAPPER_BIN/tmux" "$WRAPPER_BIN/treehouse"
FIXTURE_PATH="$WRAPPER_BIN:$PATH"
PATH="$FIXTURE_PATH" tmux new-session -d -s firstmate -n fixture -c "$PROJECT"
PATH="$FIXTURE_PATH" tmux set-option -g default-shell /bin/bash
PATH="$FIXTURE_PATH" tmux set-option -g default-command "env PATH='$FIXTURE_PATH' bash --noprofile --norc"

capture() {
  PATH="$WRAPPER_BIN:$PATH" tmux capture-pane -p -t "$1" -S -220 2>/dev/null || true
}

agent_state() {
  PATH="$WRAPPER_BIN:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; meta=$(fm_backend_meta_for_window "$2" "$3") || exit 1; fm_backend_agent_state tmux "$2" "$meta"' \
    _ "$ROOT" "$1" "$HOME_DIR/state"
}

composer_state() {
  PATH="$WRAPPER_BIN:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; meta=$(fm_backend_meta_for_window "$2" "$3") || exit 1; fm_backend_agent_record_identity tmux "$2" "$meta" || exit 1; fm_backend_composer_state tmux "$2" omp "$FM_BACKEND_AGENT_OMP_BUN" "$FM_BACKEND_AGENT_OMP_BIN"' \
    _ "$ROOT" "$1" "$HOME_DIR/state"
}

pane_busy() {
  PATH="$WRAPPER_BIN:$PATH" bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_pane_is_busy "$2" omp' \
    _ "$ROOT" "$1"
}

wait_file() {
  local file=$1 attempts=${2:-320} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -f "$file" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

wait_text_count() {
  local target=$1 text=$2 count=$3 attempts=${4:-320} pane i=0
  while [ "$i" -lt "$attempts" ]; do
    pane=$(capture "$target")
    [ "$(printf '%s\n' "$pane" | grep -Fc "$text")" -ge "$count" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  capture "$target" >&2
  return 1
}

wait_launch_brief_once() {
  local session_dir="$HOME_DIR/state/$WORKER_ID.omp-sessions" attempts=120 i=0 count file file_count
  while [ "$i" -lt "$attempts" ]; do
    count=0
    for file in "$session_dir"/*.jsonl; do
      [ -f "$file" ] || continue
      file_count=$(grep -Fhc 'FIRSTMATE_OP: v1 launch-brief:' "$file" 2>/dev/null || printf '0\n')
      count=$((count + file_count))
    done
    [ "$count" = 1 ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

wait_busy() {
  local target=$1 attempts=${2:-160} i=0
  while [ "$i" -lt "$attempts" ]; do
    pane_busy "$target" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  capture "$target" >&2
  return 1
}

wait_idle() {
  local target=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    if ! pane_busy "$target" && [ "$(composer_state "$target")" = empty ]; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

run_send() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BACKEND=tmux FM_SEND_SLEEP=0.2 \
    FM_SEND_SETTLE=0 PATH="$WRAPPER_BIN:$PATH" "$ROOT/bin/fm-send.sh" "$@" >/dev/null
}

spawn_omp() {
  local id=$1 kind=$2 args=()
  if [ "$kind" = scout ]; then
    args+=(--scout)
  else
    args+=(--mode no-mistakes --yolo off)
  fi
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
    OMP_SKIP_SETUP=1 PATH="$WRAPPER_BIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT" "${args[@]}" --harness omp \
      --model openai-codex/gpt-5.6-luna --effort low
}
recover_omp() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
    OMP_SKIP_SETUP=1 PATH="$WRAPPER_BIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$1" --recover
}

spawn_omp "$WORKER_ID" ship >/dev/null || fail "real OMP worker spawn failed"
WORKER_META="$HOME_DIR/state/$WORKER_ID.meta"
WORKER_WT=$(sed -n 's/^worktree=//p' "$WORKER_META")
WORKER_TARGET=$(sed -n 's/^window=//p' "$WORKER_META")
assert_grep 'harness=omp' "$WORKER_META" "worker metadata lost exact OMP identity"
assert_grep 'kind=ship' "$WORKER_META" "worker metadata lost ship kind"
assert_grep 'model=openai-codex/gpt-5.6-luna' "$WORKER_META" "worker metadata lost selected model"
assert_grep 'effort=low' "$WORKER_META" "worker metadata lost selected thinking level"

wait_file "$HOME_DIR/state/$WORKER_ID.omp-ready" || fail "OMP worker extension did not report session readiness"
wait_file "$HOME_DIR/state/$WORKER_ID.turn-ended" || fail "initial OMP worker turn did not complete"
wait_text_count "$WORKER_TARGET" OMP_INITIAL_DONE 2 || fail "initial OMP worker response was not observed"
wait_launch_brief_once || fail "OMP worker initial launch brief was not persisted exactly once"
assert_contains "$(capture "$WORKER_TARGET")" 'GPT-5.6-Luna' "OMP worker did not display the selected model"
assert_contains "$(capture "$WORKER_TARGET")" 'low' "OMP worker did not display the selected thinking level"
[ "$(agent_state "$WORKER_TARGET")" = alive ] || fail "idle OMP worker was not classified alive"
# The narrow live recovery lane avoids additional composer steering so it can
# isolate the guarded restart path when a current OMP build changes composer
# rendering independently of launch and recovery semantics.
if [ "${FM_OMP_TMUX_RECOVERY_ONLY:-0}" = 1 ]; then
  SESSION_DIR="$HOME_DIR/state/$WORKER_ID.omp-sessions"
  SESSION_FILE=
  for candidate in "$SESSION_DIR"/*.jsonl; do
    [ -f "$candidate" ] || continue
    SESSION_FILE=$candidate
    break
  done
  [ -n "$SESSION_FILE" ] || fail "OMP worker session file was not retained for recovery"
  [ "$(cat "$HOME_DIR/state/$WORKER_ID.omp-session")" = "$SESSION_FILE" ] \
    || fail "OMP worker durable session pointer did not name its retained session"
  WORKER_META_BEFORE="$LAB/worker.meta.before"
  WORKER_BRIEF_BEFORE="$LAB/worker.brief.before"
  cp "$WORKER_META" "$WORKER_META_BEFORE"
  cp "$HOME_DIR/data/$WORKER_ID/brief.md" "$WORKER_BRIEF_BEFORE"
  printf 'preserve this uncommitted recovery fixture change\n' > "$WORKER_WT/.recovery-preserved"
  WORKER_BRANCH=$(git -C "$WORKER_WT" symbolic-ref --quiet --short HEAD) \
    || fail "OMP worker recovery fixture lost its non-default branch"
  PATH="$WRAPPER_BIN:$PATH" tmux kill-window -t "$WORKER_TARGET"
  for _ in $(seq 1 120); do
    [ "$(agent_state "$WORKER_TARGET")" = missing ] && break
    sleep 0.25
  done
  [ "$(agent_state "$WORKER_TARGET")" = missing ] \
    || fail "OMP worker endpoint did not become missing for guarded recovery"
  RECOVERY_OUTPUT=$(recover_omp "$WORKER_ID") || fail "guarded OMP worker recovery failed"
  assert_contains "$RECOVERY_OUTPUT" "recovered $WORKER_ID harness=omp" \
    "guarded recovery did not report the recovered worker"
  for _ in $(seq 1 160); do
    [ "$(agent_state "$WORKER_TARGET")" = alive ] && break
    sleep 0.25
  done
  [ "$(agent_state "$WORKER_TARGET")" = alive ] \
    || fail "guarded OMP recovery did not restore a live agent"
  cmp -s "$WORKER_META" "$WORKER_META_BEFORE" \
    || fail "guarded recovery rewrote same-endpoint metadata"
  cmp -s "$HOME_DIR/data/$WORKER_ID/brief.md" "$WORKER_BRIEF_BEFORE" \
    || fail "guarded recovery rewrote the preserved brief"
  [ "$(git -C "$WORKER_WT" symbolic-ref --quiet --short HEAD)" = "$WORKER_BRANCH" ] \
    || fail "guarded recovery changed the worker branch"
  [ -f "$WORKER_WT/.recovery-preserved" ] \
    || fail "guarded recovery discarded uncommitted task work"
  rm -f "$WORKER_WT/.recovery-preserved"
  PATH="$WRAPPER_BIN:$PATH" tmux kill-window -t "$WORKER_TARGET"
  pass "real tmux OMP guarded recovery preserves the task copy and retained session"
  exit 0
fi

rm -f "$HOME_DIR/state/$WORKER_ID.turn-ended"
run_send "$WORKER_ID" 'Respond exactly OMP_IDLE_STEER_DONE.' || fail "idle OMP steer was not acknowledged"
wait_file "$HOME_DIR/state/$WORKER_ID.turn-ended" || fail "idle OMP steer did not complete a turn"
wait_text_count "$WORKER_TARGET" OMP_IDLE_STEER_DONE 2 || fail "idle OMP steer response was not observed"

rm -f "$HOME_DIR/state/$WORKER_ID.turn-ended"
run_send "$WORKER_ID" 'Run this exact command with bash: sleep 5. Then respond exactly OMP_BUSY_FIRST_DONE.' \
  || fail "OMP busy-turn setup was not submitted"
wait_busy "$WORKER_TARGET" || fail "OMP busy indicator was not observed"
run_send "$WORKER_ID" 'After the current tool finishes, respond exactly OMP_BUSY_STEER_DONE.' \
  || fail "busy OMP steer was not acknowledged"
assert_contains "$(capture "$WORKER_TARGET")" 'Steering · 1' "busy OMP steer did not enter the verified steering queue"
wait_file "$HOME_DIR/state/$WORKER_ID.turn-ended" 400 || fail "busy OMP turn did not complete"
wait_idle "$WORKER_TARGET" 400 || fail "OMP did not return idle after busy steering"
wait_text_count "$WORKER_TARGET" OMP_BUSY_STEER_DONE 2 || fail "busy OMP steer response was not observed"

rm -f "$HOME_DIR/state/$WORKER_ID.turn-ended"
run_send "$WORKER_ID" 'Run this exact command with bash: sleep 30. Then respond exactly OMP_INTERRUPT_SHOULD_NOT_COMPLETE.' \
  || fail "OMP interrupt setup was not submitted"
wait_busy "$WORKER_TARGET" || fail "OMP interrupt setup never became busy"
run_send "$WORKER_ID" --key Escape || fail "OMP interrupt key failed"
wait_idle "$WORKER_TARGET" || fail "OMP interrupt did not stop the active turn"
[ "$(agent_state "$WORKER_TARGET")" = alive ] || fail "OMP interrupt exited the session"

rm -f "$HOME_DIR/state/$WORKER_ID.turn-ended"
run_send "$WORKER_ID" /skill:fm-omp-probe || fail "OMP skill command was not submitted"
wait_file "$HOME_DIR/state/$WORKER_ID.turn-ended" || fail "OMP skill command did not complete a turn"
wait_text_count "$WORKER_TARGET" OMP_SKILL_DONE 1 || fail "OMP skill invocation did not reach the model"

run_send "$WORKER_ID" /exit || fail "OMP clean exit command was not acknowledged"
for _ in $(seq 1 120); do
  [ "$(agent_state "$WORKER_TARGET")" = dead ] && break
  sleep 0.25
done
[ "$(agent_state "$WORKER_TARGET")" = dead ] || fail "OMP clean exit did not return to the shell"
SESSION_DIR="$HOME_DIR/state/$WORKER_ID.omp-sessions"
SESSION_FILE=$(find "$SESSION_DIR" -type f -name '*.jsonl' -print -quit 2>/dev/null)
[ -n "$SESSION_FILE" ] || fail "OMP worker session file was not retained for recovery"
WORKER_META_BEFORE="$LAB/worker.meta.before"
WORKER_BRIEF_BEFORE="$LAB/worker.brief.before"
WORKER_STATUS_BEFORE="$LAB/worker.status.before"
cp "$WORKER_META" "$WORKER_META_BEFORE"
cp "$HOME_DIR/data/$WORKER_ID/brief.md" "$WORKER_BRIEF_BEFORE"
printf 'signal: preserved recovery fixture event\n' > "$HOME_DIR/state/$WORKER_ID.status"
cp "$HOME_DIR/state/$WORKER_ID.status" "$WORKER_STATUS_BEFORE"
printf 'preserve this uncommitted recovery fixture change\n' > "$WORKER_WT/.recovery-preserved"
WORKER_BRANCH=$(git -C "$WORKER_WT" symbolic-ref --quiet --short HEAD) \
  || fail "OMP worker recovery fixture lost its non-default branch"
RECOVERY_OUTPUT=$(recover_omp "$WORKER_ID") || fail "guarded OMP worker recovery failed"
assert_contains "$RECOVERY_OUTPUT" "recovered $WORKER_ID harness=omp" "guarded recovery did not report the recovered worker"
cmp -s "$WORKER_META" "$WORKER_META_BEFORE" \
  || fail "guarded recovery rewrote metadata beyond its same-endpoint replacement"
cmp -s "$HOME_DIR/data/$WORKER_ID/brief.md" "$WORKER_BRIEF_BEFORE" \
  || fail "guarded recovery rewrote the preserved brief"
cmp -s "$HOME_DIR/state/$WORKER_ID.status" "$WORKER_STATUS_BEFORE" \
  || fail "guarded recovery rewrote preserved task status"
[ "$(git -C "$WORKER_WT" symbolic-ref --quiet --short HEAD)" = "$WORKER_BRANCH" ] \
  || fail "guarded recovery changed the worker branch"
[ -f "$WORKER_WT/.recovery-preserved" ] \
  || fail "guarded recovery discarded uncommitted task work"
wait_idle "$WORKER_TARGET" 160 || fail "guarded OMP recovery did not restore an idle composer"
[ "$(agent_state "$WORKER_TARGET")" = alive ] || fail "guarded OMP recovery did not restore the live agent"
rm -f "$WORKER_WT/.recovery-preserved"
rm -f "$HOME_DIR/state/$WORKER_ID.turn-ended"
run_send "$WORKER_ID" 'Reply with the remembered session token only.' || fail "resumed OMP session did not accept input"
wait_file "$HOME_DIR/state/$WORKER_ID.turn-ended" || fail "resumed OMP session did not complete a turn"
wait_text_count "$WORKER_TARGET" OMP_CONTEXT_TOKEN_73 2 || fail "OMP resume did not preserve conversation context"
run_send "$WORKER_ID" /exit || fail "resumed OMP session did not exit cleanly"
for _ in $(seq 1 120); do
  [ "$(agent_state "$WORKER_TARGET")" = dead ] && break
  sleep 0.25
done
[ "$(agent_state "$WORKER_TARGET")" = dead ] || fail "resumed OMP session remained live after exit"

spawn_omp "$SCOUT_ID" scout >/dev/null || fail "real OMP scout spawn failed"
SCOUT_META="$HOME_DIR/state/$SCOUT_ID.meta"
SCOUT_WT=$(sed -n 's/^worktree=//p' "$SCOUT_META")
SCOUT_TARGET=$(sed -n 's/^window=//p' "$SCOUT_META")
assert_grep 'harness=omp' "$SCOUT_META" "scout metadata lost exact OMP identity"
assert_grep 'kind=scout' "$SCOUT_META" "OMP scout changed delivery semantics"
wait_file "$HOME_DIR/state/$SCOUT_ID.omp-ready" || fail "OMP scout extension did not report session readiness"
wait_file "$HOME_DIR/state/$SCOUT_ID.turn-ended" || fail "initial OMP scout turn did not complete"
wait_text_count "$SCOUT_TARGET" OMP_SCOUT_INITIAL_DONE 2 || fail "OMP scout response was not observed"
[ "$(agent_state "$SCOUT_TARGET")" = alive ] || fail "idle OMP scout was not classified alive"
rm -f "$HOME_DIR/state/$SCOUT_ID.turn-ended"
run_send "$SCOUT_ID" 'Respond exactly OMP_SCOUT_IDLE_STEER_DONE.' || fail "idle OMP scout steer was not acknowledged"
wait_file "$HOME_DIR/state/$SCOUT_ID.turn-ended" || fail "idle OMP scout steer did not complete"
wait_text_count "$SCOUT_TARGET" OMP_SCOUT_IDLE_STEER_DONE 2 || fail "idle OMP scout steer response was not observed"
rm -f "$HOME_DIR/state/$SCOUT_ID.turn-ended"
run_send "$SCOUT_ID" 'Run this exact command with bash: sleep 5. Then respond exactly OMP_SCOUT_BUSY_FIRST_DONE.' \
  || fail "OMP scout busy-turn setup was not submitted"
wait_busy "$SCOUT_TARGET" || fail "OMP scout busy indicator was not observed"
run_send "$SCOUT_ID" 'After the current tool finishes, respond exactly OMP_SCOUT_BUSY_STEER_DONE.' \
  || fail "busy OMP scout steer was not acknowledged"
assert_contains "$(capture "$SCOUT_TARGET")" 'Steering · 1' "busy OMP scout steer did not enter the verified queue"
wait_file "$HOME_DIR/state/$SCOUT_ID.turn-ended" 400 || fail "busy OMP scout turn did not complete"
wait_idle "$SCOUT_TARGET" 400 || fail "OMP scout did not return idle after busy steering"
wait_text_count "$SCOUT_TARGET" OMP_SCOUT_BUSY_STEER_DONE 2 || fail "busy OMP scout steer response was not observed"
run_send "$SCOUT_ID" /exit || fail "OMP scout did not exit cleanly"
for _ in $(seq 1 120); do
  [ "$(agent_state "$SCOUT_TARGET")" = dead ] && break
  sleep 0.25
done
[ "$(agent_state "$SCOUT_TARGET")" = dead ] || fail "OMP scout remained live after exit"

pass "real tmux OMP worker/scout lifecycle: launch, exact identity, worker and scout idle/busy steering, interrupt, skill, exit, and resume"
