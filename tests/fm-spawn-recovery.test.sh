#!/usr/bin/env bash
# Guarded OMP ordinary-worker recovery behavior through the real spawn entrypoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v bun >/dev/null 2>&1 || fail "bun is required for the fake OMP fixture"
command -v tmux >/dev/null 2>&1 || fail "tmux is required for the recovery fixture"

LAB=$(fm_test_tmproot fm-spawn-recovery)
REAL_TMUX=$(command -v tmux)
SOCKET="fm-spawn-recovery-$$"
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
WORKTREE="$LAB/worktree"
ORIGIN="$LAB/origin.git"
WRAPPER_BIN="$LAB/bin"
ID="recovery-worker-$$"
TARGET="firstmate:fm-$ID"
TASK_TMP="/tmp/fm-$ID"
TASK_TMP_OWNED=0

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  [ "$TASK_TMP_OWNED" -eq 0 ] || rm -rf "$TASK_TMP"
  if [ -d "$WORKTREE" ] && [ -z "$(git -C "$WORKTREE" status --porcelain 2>/dev/null || true)" ]; then
    git -C "$PROJECT" worktree remove "$WORKTREE" >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$WRAPPER_BIN"
printf 'Recovery fixture: acknowledge the first turn.\n' > "$HOME_DIR/data/$ID/brief.md"
mkdir -p "$PROJECT"
printf 'fixture\n' > "$PROJECT/README.md"
git init -q -b main "$PROJECT"
fm_git_identity fmtest fmtest@example.invalid
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm initial
git init -q --bare "$ORIGIN"
git -C "$PROJECT" remote add origin "$ORIGIN"
git -C "$PROJECT" push -q -u origin main
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$PROJECT" remote set-head origin main
git -C "$PROJECT" worktree add -q -b "fm/$ID" "$WORKTREE"

[ ! -e "$TASK_TMP" ] && [ ! -L "$TASK_TMP" ] \
  || fail "recovery fixture task root already exists: $TASK_TMP"
TASK_TMP_OWNED=1

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
    holder=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        --lease-holder) shift; holder=\${1:-} ;;
        --lease-holder=*) holder=\${1#--lease-holder=} ;;
      esac
      shift
    done
    [ "\$holder" = "fm-$ID" ] || { echo "unexpected lease holder: \$holder" >&2; exit 1; }
    (
      cd '$WORKTREE' || exit 1
      git reset --hard HEAD >/dev/null && git clean -fd >/dev/null
    ) || exit \$?
    printf '%s\n' '$WORKTREE'
    ;;
  status)
    [ "\${2:-}" = --json ] || exit 1
    printf '[{"path":"%s","status":"leased","lease_holder":"fm-$ID","lease_id":"fixture-lease"}]\n' '$WORKTREE'
    ;;
  return) exit 0 ;;
  *) exit 1 ;;
esac
SH
cat > "$WRAPPER_BIN/omp" <<'JS'
#!/usr/bin/env bun
const args = process.argv.slice(2);
if (args.includes("--help")) {
  console.log("--model= --thinking= --auto-approve --session-dir= --extension= --resume= --max-time=");
  process.exit(0);
}
const value = (...names) => {
  for (let i = 0; i < args.length; i += 1) {
    if (names.includes(args[i])) return args[i + 1];
    for (const name of names) if (args[i].startsWith(`${name}=`)) return args[i].slice(name.length + 1);
  }
  return "";
};
const sessionDir = value("--session-dir");
const resume = value("--resume");
const extension = value("-e", "--extension");
if (!sessionDir || !extension) process.exit(2);
const sessionFile = `${sessionDir}/fixture-session.jsonl`;
const prior = resume ? await Bun.file(sessionFile).text() : "";
await Bun.write(sessionFile, `${prior}${resume ? "replacement-attempt\n" : "FIRSTMATE_OP: v1 launch-brief: fixture\n"}`);
const source = await Bun.file(extension).text();
const paths = [...source.matchAll(/execFile\("touch", \["([^"]+)"\]\)/g)].map((match) => match[1]);
Bun.spawnSync({ cmd: ["touch", ...paths] });
await new Promise(() => {});
JS
chmod +x "$WRAPPER_BIN/tmux" "$WRAPPER_BIN/treehouse" "$WRAPPER_BIN/omp"

FIXTURE_PATH="$WRAPPER_BIN:$PATH"
PATH="$FIXTURE_PATH" tmux new-session -d -s firstmate -n fixture -c "$PROJECT"
PATH="$FIXTURE_PATH" tmux set-option -g default-shell /bin/bash
PATH="$FIXTURE_PATH" tmux set-option -g default-command "env PATH='$FIXTURE_PATH' bash --noprofile --norc"

spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
    OMP_SKIP_SETUP=1 PATH="$FIXTURE_PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@"
}

agent_state() {
  PATH="$FIXTURE_PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2" "$3"' \
    _ "$ROOT" "$TARGET" "$HOME_DIR/state/$ID.meta"
}

wait_for_state() {
  local want=$1 i=0 state
  while [ "$i" -lt 80 ]; do
    state=$(agent_state)
    [ "$state" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

spawn "$ID" "$PROJECT" --scout --harness omp --model fixture-model --effort low >/dev/null \
  || fail "initial OMP worker spawn failed"
META="$HOME_DIR/state/$ID.meta"
wait_for_state alive || fail "initial OMP worker was not live"
wait_file() {
  local path=$1 i=0
  while [ "$i" -lt 80 ]; do
    [ -f "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
wait_file "$HOME_DIR/state/$ID.omp-started" || fail "initial worker did not acknowledge its launch"

printf 'uncommitted recovery state\n' > "$WORKTREE/.recovery-preserved"
printf 'signal: preserved fixture event\n' > "$HOME_DIR/state/$ID.status"
cp "$META" "$LAB/meta.before"
cp "$HOME_DIR/data/$ID/brief.md" "$LAB/brief.before"
cp "$HOME_DIR/state/$ID.status" "$LAB/status.before"
cp "$TASK_TMP/omp-sessions/fixture-session.jsonl" "$LAB/session.before"
BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD) || fail "fixture worker is not on a branch"

PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "fixture endpoint did not become missing"
printf 'FIRSTMATE_OP: v1 launch-brief: competing\n' > "$TASK_TMP/omp-sessions/competing.jsonl"
MULTIPLE_OUTPUT=$(spawn "$ID" --recover 2>&1)
MULTIPLE_STATUS=$?
[ "$MULTIPLE_STATUS" -ne 0 ] || fail "recovery accepted multiple retained sessions"
assert_contains "$MULTIPLE_OUTPUT" "could not select one exact prior task session" \
  "multiple-session refusal did not name the session-selection boundary"
cmp -s "$META" "$LAB/meta.before" || fail "multiple-session refusal rewrote metadata"
rm -f "$TASK_TMP/omp-sessions/competing.jsonl"

INJECTED_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_BEFORE_PUBLISH=1 spawn "$ID" --recover 2>&1)
INJECTED_STATUS=$?
[ "$INJECTED_STATUS" -ne 0 ] || fail "recovery test injector unexpectedly published metadata"
assert_contains "$INJECTED_OUTPUT" "stopped before endpoint publication" "recovery injector did not stop before publication"
wait_for_state missing || fail "failed replacement endpoint was not removed"
cmp -s "$META" "$LAB/meta.before" || fail "failed recovery rewrote metadata"
cmp -s "$HOME_DIR/data/$ID/brief.md" "$LAB/brief.before" || fail "failed recovery rewrote the preserved brief"
cmp -s "$HOME_DIR/state/$ID.status" "$LAB/status.before" || fail "failed recovery rewrote task status"
cmp -s "$TASK_TMP/omp-sessions/fixture-session.jsonl" "$LAB/session.before" || fail "failed recovery did not restore the exact session bytes"
[ "$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] || fail "failed recovery changed the branch"
[ -f "$WORKTREE/.recovery-preserved" ] || fail "failed recovery discarded uncommitted work"

RECOVERED_OUTPUT=$(spawn "$ID" --recover) || fail "guarded recovery from a missing endpoint failed"
assert_contains "$RECOVERED_OUTPUT" "recovered $ID harness=omp" "recovery did not report success"
wait_for_state alive || fail "recovered missing endpoint was not live"
cmp -s "$HOME_DIR/data/$ID/brief.md" "$LAB/brief.before" || fail "successful recovery rewrote the preserved brief"
cmp -s "$HOME_DIR/state/$ID.status" "$LAB/status.before" || fail "successful recovery rewrote task status"
[ "$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] || fail "successful recovery changed the branch"
[ -f "$WORKTREE/.recovery-preserved" ] || fail "successful recovery discarded uncommitted work"
cp "$META" "$LAB/meta.after-missing"
ACTIVE_OUTPUT=$(spawn "$ID" --recover 2>&1)
ACTIVE_STATUS=$?
[ "$ACTIVE_STATUS" -ne 0 ] || fail "recovery accepted an alive endpoint"
assert_contains "$ACTIVE_OUTPUT" "definitely dead or missing endpoint" \
  "alive-endpoint refusal did not name the duplicate-agent safety boundary"
cmp -s "$META" "$LAB/meta.after-missing" || fail "alive-endpoint refusal rewrote metadata"

PATH="$FIXTURE_PATH" tmux send-keys -t "$TARGET" C-c
wait_for_state dead || fail "fixture endpoint did not return to a dead shell for ambiguity coverage"
PATH="$FIXTURE_PATH" tmux send-keys -t "$TARGET" 'sleep 30' Enter
wait_for_state ambiguous || fail "fixture endpoint did not become ambiguous"
AMBIGUOUS_OUTPUT=$(spawn "$ID" --recover 2>&1)
AMBIGUOUS_STATUS=$?
[ "$AMBIGUOUS_STATUS" -ne 0 ] || fail "recovery accepted an ambiguous endpoint"
assert_contains "$AMBIGUOUS_OUTPUT" "definitely dead or missing endpoint" \
  "ambiguous-endpoint refusal did not name the duplicate-agent safety boundary"
cmp -s "$META" "$LAB/meta.after-missing" || fail "ambiguous-endpoint refusal rewrote metadata"
PATH="$FIXTURE_PATH" tmux send-keys -t "$TARGET" C-c
wait_for_state dead || fail "fixture endpoint did not return to a dead shell after ambiguity coverage"

wait_for_state dead || fail "fixture endpoint did not become a retained dead shell"
cp "$META" "$LAB/meta.before-dead"
DEAD_OUTPUT=$(spawn "$ID" --recover) || fail "guarded recovery from a dead endpoint failed"
assert_contains "$DEAD_OUTPUT" "recovered $ID harness=omp" "dead-endpoint recovery did not report success"
wait_for_state alive || fail "dead endpoint recovery was not live"
cmp -s "$META" "$LAB/meta.before-dead" || fail "dead endpoint recovery rewrote same endpoint metadata"
[ "$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] || fail "dead endpoint recovery changed the branch"
[ -f "$WORKTREE/.recovery-preserved" ] || fail "dead endpoint recovery discarded uncommitted work"


PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "dead-endpoint recovery did not leave a removable endpoint"
rm -f "$TASK_TMP/omp-sessions/fixture-session.jsonl"
rmdir "$TASK_TMP/omp-sessions" || fail "fixture could not remove the retained task session directory"
[ ! -e "$TASK_TMP/omp-sessions" ] || fail "fixture retained a task session directory for fresh-recovery coverage"
FRESH_OUTPUT=$(spawn "$ID" --recover) || fail "guarded recovery from a lost task session failed"
assert_contains "$FRESH_OUTPUT" "recovered $ID harness=omp" "fresh-session recovery did not report success"
wait_for_state alive || fail "fresh-session recovery was not live"
[ -f "$TASK_TMP/omp-sessions/fixture-session.jsonl" ] \
  || fail "fresh-session recovery did not create one task-owned session"
assert_contains "$(cat "$TASK_TMP/omp-sessions/fixture-session.jsonl")" "FIRSTMATE_OP: v1 launch-brief:" \
  "fresh-session recovery did not launch a new OMP trajectory"
cmp -s "$HOME_DIR/data/$ID/brief.md" "$LAB/brief.before" \
  || fail "fresh-session recovery rewrote the preserved brief"
cmp -s "$HOME_DIR/state/$ID.status" "$LAB/status.before" \
  || fail "fresh-session recovery rewrote task status"
[ "$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] \
  || fail "fresh-session recovery changed the branch"
[ -f "$WORKTREE/.recovery-preserved" ] \
  || fail "fresh-session recovery discarded uncommitted work"
NON_OMP_ID="recovery-non-omp-$$"
cat > "$HOME_DIR/state/$NON_OMP_ID.meta" <<EOF
window=firstmate:fm-$NON_OMP_ID
endpoint_task_id=$NON_OMP_ID
worktree=$WORKTREE
project=$PROJECT
harness=codex
kind=scout
tasktmp=/tmp/fm-$NON_OMP_ID
model=fixture-model
effort=low
EOF
cp "$HOME_DIR/state/$NON_OMP_ID.meta" "$LAB/non-omp.before"
NON_OMP_OUTPUT=$(spawn "$NON_OMP_ID" --recover 2>&1)
NON_OMP_STATUS=$?
[ "$NON_OMP_STATUS" -ne 0 ] || fail "recovery accepted a non-OMP worker"
assert_contains "$NON_OMP_OUTPUT" "supports only recorded harness=omp" "non-OMP refusal did not name the restriction"
cmp -s "$HOME_DIR/state/$NON_OMP_ID.meta" "$LAB/non-omp.before" || fail "non-OMP refusal rewrote metadata"


UNSUPPORTED_ID="recovery-unsupported-$$"
cat > "$HOME_DIR/state/$UNSUPPORTED_ID.meta" <<EOF
window=firstmate:fm-$UNSUPPORTED_ID
endpoint_task_id=$UNSUPPORTED_ID
backend=zellij
harness=omp
kind=scout
EOF
cp "$HOME_DIR/state/$UNSUPPORTED_ID.meta" "$LAB/unsupported.before"
UNSUPPORTED_OUTPUT=$(spawn "$UNSUPPORTED_ID" --recover 2>&1)
UNSUPPORTED_STATUS=$?
[ "$UNSUPPORTED_STATUS" -ne 0 ] || fail "recovery accepted an unsupported OMP backend"
assert_contains "$UNSUPPORTED_OUTPUT" "verified only on tmux or Herdr" \
  "unsupported-backend refusal did not name the verified recovery boundary"
cmp -s "$HOME_DIR/state/$UNSUPPORTED_ID.meta" "$LAB/unsupported.before" \
  || fail "unsupported-backend refusal rewrote metadata"

MALFORMED_ID="recovery-malformed-$$"
cat > "$HOME_DIR/state/$MALFORMED_ID.meta" <<EOF
window=firstmate:fm-$MALFORMED_ID
endpoint_task_id=$MALFORMED_ID
harness=omp
harness=omp
kind=scout
EOF
cp "$HOME_DIR/state/$MALFORMED_ID.meta" "$LAB/malformed.before"
MALFORMED_OUTPUT=$(spawn "$MALFORMED_ID" --recover 2>&1)
MALFORMED_STATUS=$?
[ "$MALFORMED_STATUS" -ne 0 ] || fail "recovery accepted malformed metadata"
assert_contains "$MALFORMED_OUTPUT" "supports only recorded harness=omp" \
  "malformed-metadata refusal did not stop before recovery"
cmp -s "$HOME_DIR/state/$MALFORMED_ID.meta" "$LAB/malformed.before" \
  || fail "malformed-metadata refusal rewrote metadata"
rm -f "$WORKTREE/.recovery-preserved"
PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "recovered fixture endpoint did not stop"
pass "guarded OMP recovery preserves task state, restores failed attempts, and rejects unsafe records"
