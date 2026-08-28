#!/usr/bin/env bash
# Guarded OMP ordinary-worker recovery behavior through the real spawn entrypoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v bun >/dev/null 2>&1 || fail "bun is required for the fake OMP fixture"
command -v tmux >/dev/null 2>&1 || fail "tmux is required for the recovery fixture"

LAB=$(fm_test_tmproot fm-spawn-recovery)
REAL_TMUX=$(command -v tmux)
REAL_TAR=$(command -v tar)
REAL_RM=$(command -v rm)
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
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
printf '%s on\n' "$$" > "$HOME_DIR/state/.trace-context-effective"
printf 'Recovery fixture: acknowledge the first turn.\n' > "$HOME_DIR/data/$ID/brief.md"
mkdir -p "$PROJECT"
printf 'fixture\n' > "$PROJECT/README.md"
printf 'tracked deletion fixture\n' > "$PROJECT/rollback-delete.txt"
git init -q -b main "$PROJECT"
fm_git_identity fmtest fmtest@example.invalid
git -C "$PROJECT" add README.md rollback-delete.txt
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
cat > "$WRAPPER_BIN/tar" <<SH
#!/usr/bin/env bash
[ "\${FM_SPAWN_RECOVERY_TEST_FAIL_SNAPSHOT:-0}" != 1 ] || exit 1
exec '$REAL_TAR' "\$@"
SH
cat > "$WRAPPER_BIN/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\${FM_SPAWN_RECOVERY_TEST_FAIL_FRESH_SESSION_CLEANUP:-0}" = 1 ] \
     && [ "\$arg" = '$HOME_DIR/state/$ID.omp-sessions/fixture-session.jsonl' ]; then
    exit 1
  fi
done
exec '$REAL_RM' "\$@"
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
import { appendFileSync } from "node:fs";
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
if (process.env.GOTMPDIR) await Bun.write(`${process.env.GOTMPDIR}/fixture-build-artifact`, "fixture build artifact\n");
if (process.env.GOTMPDIR) await Bun.write(`${process.env.GOTMPDIR}/traceparent`, process.env.TRACEPARENT ?? "");
const sessionFile = `${sessionDir}/fixture-session.jsonl`;
const prior = resume ? await Bun.file(sessionFile).text() : "";
await Bun.write(sessionFile, `${prior}${resume ? "replacement-attempt\n" : "FIRSTMATE_OP: v1 launch-brief: fixture\n"}`);
if (resume && process.env.OMP_FIXTURE_LOG) appendFileSync(process.env.OMP_FIXTURE_LOG, `${extension}\n`);
if (resume && await Bun.file(".recovery-mutate-on-launch").exists()) {
  const replacementBranch = (await Bun.file(".recovery-mutate-on-launch").text()).trim();
  const switchBranch = Bun.spawnSync(["git", "switch", replacementBranch]);
  if (switchBranch.exitCode !== 0) process.exit(switchBranch.exitCode ?? 1);
  await Bun.write(".recovery-replacement-edit", "replacement edit\n");
  const add = Bun.spawnSync(["git", "add", ".recovery-replacement-edit"]);
  if (add.exitCode !== 0) process.exit(add.exitCode ?? 1);
  const commit = Bun.spawnSync([
    "git", "-c", "user.name=Recovery Fixture", "-c", "user.email=recovery@example.invalid",
    "commit", "-m", "replacement mutation",
  ]);
  if (commit.exitCode !== 0) process.exit(commit.exitCode ?? 1);
}
const handlers = new Map();
const mod = await import(`${new URL(`file://${extension}`).href}?fixture=${process.pid}-${Date.now()}`);
mod.default({ on(event, handler) { handlers.set(event, handler); } });
const sessionStart = handlers.get("session_start");
const turnStart = handlers.get("turn_start");
if (!sessionStart || !turnStart) process.exit(3);
await sessionStart({}, { sessionManager: { getSessionFile: () => sessionFile } });
await turnStart();
await new Promise((resolve) => setTimeout(resolve, 20));
await new Promise(() => {});
JS
chmod +x "$WRAPPER_BIN/tmux" "$WRAPPER_BIN/tar" "$WRAPPER_BIN/rm" "$WRAPPER_BIN/treehouse" "$WRAPPER_BIN/omp"

FIXTURE_PATH="$WRAPPER_BIN:$PATH"
export OMP_FIXTURE_LOG="$LAB/omp-launches"
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
SESSION_DIR="$HOME_DIR/state/$ID.omp-sessions"
SESSION_POINTER="$HOME_DIR/state/$ID.omp-session"
SESSION_FILE="$SESSION_DIR/fixture-session.jsonl"
wait_file "$SESSION_POINTER" || fail "initial worker did not publish its durable OMP session pointer"
[ "$(cat "$SESSION_POINTER")" = "$SESSION_FILE" ] \
  || fail "initial worker durable OMP session pointer did not name its exact session"
wait_file "$HOME_DIR/state/$ID.omp-started" || fail "initial worker did not acknowledge its launch"
RECORDED_TRACEPARENT=$(sed -n 's/^traceparent=//p' "$META")
[ -n "$RECORDED_TRACEPARENT" ] || fail "initial worker did not record trace context"
[ "$(cat "$TASK_TMP/gotmp/traceparent")" = "$RECORDED_TRACEPARENT" ] \
  || fail "initial worker did not receive its recorded trace context"
printf '%s off\n' "$$" > "$HOME_DIR/state/.trace-context-effective"

PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "fixture endpoint did not become missing"
RECORDED_TMUX_SESSION="recovery-$ID"
awk -v target="$RECORDED_TMUX_SESSION:fm-$ID" '/^window=/ { print "window=" target; next } { print }' "$META" > "$LAB/meta.recorded-session"
mv "$LAB/meta.recorded-session" "$META"
TARGET="$RECORDED_TMUX_SESSION:fm-$ID"
printf 'uncommitted recovery state\n' > "$WORKTREE/.recovery-preserved"
printf 'signal: preserved fixture event\n' > "$HOME_DIR/state/$ID.status"
cp "$META" "$LAB/meta.before"
cp "$HOME_DIR/data/$ID/brief.md" "$LAB/brief.before"
cp "$SESSION_FILE" "$LAB/session.before"
cp "$HOME_DIR/state/$ID.status" "$LAB/status.before"
BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD) || fail "fixture worker is not on a branch"
assert_contains "$(cat "$META")" "branch=$BRANCH" \
  "initial worker did not record its exact branch identity"

printf 'FIRSTMATE_OP: v1 launch-brief: retained-sibling\n' > "$SESSION_DIR/retained-sibling.jsonl"
POINTER_OUTPUT=$(spawn "$ID" --recover) || fail "authoritative durable pointer did not disambiguate retained sessions"
assert_contains "$POINTER_OUTPUT" "recovered $ID harness=omp" \
  "authoritative-pointer recovery did not report success"
wait_for_state alive || fail "authoritative-pointer recovery was not live"
[ "$(PATH="$FIXTURE_PATH" tmux display-message -p -t "$TARGET" '#S')" = "$RECORDED_TMUX_SESSION" ] \
  || fail "recovery did not recreate the worker in its recorded tmux session"
[ "$(cat "$SESSION_POINTER")" = "$SESSION_FILE" ] \
  || fail "authoritative-pointer recovery changed the selected exact session"
case "$(tail -n 1 "$OMP_FIXTURE_LOG")" in
  "$TASK_TMP"/.fm-spawn-recovery-ext.*.ts) ;;
  *) fail "recovery did not stage its OMP launch extension in task scratch" ;;
esac
[ "$(cat "$TASK_TMP/gotmp/traceparent")" = "$RECORDED_TRACEPARENT" ] \
  || fail "recovery did not preserve the recorded trace context"
PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "authoritative-pointer fixture endpoint did not become missing"
rm -f "$SESSION_DIR/retained-sibling.jsonl"
cp "$SESSION_FILE" "$LAB/session.before"
POSTPUBLISH_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_FINALIZATION=1 spawn "$ID" --recover 2>&1)
POSTPUBLISH_STATUS=$?
[ "$POSTPUBLISH_STATUS" -ne 0 ] || fail "post-publication cleanup failure unexpectedly succeeded"
assert_contains "$POSTPUBLISH_OUTPUT" "published its replacement endpoint" \
  "post-publication cleanup failure did not reach endpoint finalization"
wait_for_state missing || fail "post-publication cleanup failure retained replacement endpoint"
cmp -s "$META" "$LAB/meta.before" || fail "post-publication cleanup failure retained replacement metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "post-publication cleanup failure did not restore the exact session bytes"
LATE_FINALIZATION_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_ROLLBACK_FINALIZATION=1 spawn "$ID" --recover 2>&1)
LATE_FINALIZATION_STATUS=$?
[ "$LATE_FINALIZATION_STATUS" -ne 0 ] || fail "late rollback finalization failure unexpectedly succeeded"
assert_contains "$LATE_FINALIZATION_OUTPUT" "published its replacement endpoint" \
  "late rollback finalization failure did not reach endpoint finalization"
wait_for_state missing || fail "late rollback finalization failure retained replacement endpoint"
cmp -s "$META" "$LAB/meta.before" || fail "late rollback finalization failure retained replacement metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "late rollback finalization failure did not restore the exact session bytes"
PARTIAL_FINALIZATION_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_PARTIAL_ROLLBACK_FINALIZATION=1 spawn "$ID" --recover 2>&1)
PARTIAL_FINALIZATION_STATUS=$?
[ "$PARTIAL_FINALIZATION_STATUS" -ne 0 ] || fail "partial rollback finalization failure unexpectedly succeeded"
assert_contains "$PARTIAL_FINALIZATION_OUTPUT" "published its replacement endpoint" \
  "partial rollback finalization failure did not reach endpoint finalization"
wait_for_state missing || fail "partial rollback finalization failure retained replacement endpoint"
cmp -s "$META" "$LAB/meta.before" || fail "partial rollback finalization failure retained replacement metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "partial rollback finalization failure did not restore the exact session bytes"
ARCHIVE_FINALIZATION_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_FINALIZATION_ARCHIVE_DELETE=1 spawn "$ID" --recover 2>&1)
ARCHIVE_FINALIZATION_STATUS=$?
[ "$ARCHIVE_FINALIZATION_STATUS" -ne 0 ] || fail "finalization archive deletion failure unexpectedly succeeded"
assert_contains "$ARCHIVE_FINALIZATION_OUTPUT" "published its replacement endpoint" \
  "finalization archive deletion failure did not reach endpoint finalization"
wait_for_state missing || fail "finalization archive deletion failure retained replacement endpoint"
cmp -s "$META" "$LAB/meta.before" || fail "finalization archive deletion failure retained replacement metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "finalization archive deletion failure did not restore the exact session bytes"
ln -s "$SESSION_FILE" "$SESSION_DIR/symlinked.jsonl"
SYMLINK_OUTPUT=$(spawn "$ID" --recover 2>&1)
SYMLINK_STATUS=$?
[ "$SYMLINK_STATUS" -ne 0 ] || fail "recovery accepted a symlinked session candidate"
assert_contains "$SYMLINK_OUTPUT" "could not select one exact prior task session" \
  "symlinked-session refusal did not name the session-selection boundary"
cmp -s "$META" "$LAB/meta.before" || fail "symlinked-session refusal rewrote metadata"
rm -f "$SESSION_DIR/symlinked.jsonl"

rm -rf "$TASK_TMP/gotmp"
mkdir -p "$TASK_TMP"
printf 'pre-existing scratch\n' > "$TASK_TMP/preserve-me"
printf 'staged recovery state\n' > "$WORKTREE/.recovery-staged"
git -C "$WORKTREE" add .recovery-staged
printf 'unstaged recovery state\n' >> "$WORKTREE/.recovery-staged"
RECOVERY_HEAD=$(git -C "$WORKTREE" rev-parse HEAD) || fail "fixture could not record the pre-recovery worktree head"
RECOVERY_ALT_BRANCH="$BRANCH-recovery-rollback"
git -C "$WORKTREE" branch "$RECOVERY_ALT_BRANCH" "$RECOVERY_HEAD" \
  || fail "fixture could not create the alternate replacement branch"
printf '%s\n' "$RECOVERY_ALT_BRANCH" > "$WORKTREE/.recovery-mutate-on-launch"
rm "$WORKTREE/rollback-delete.txt"
INJECTED_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_BEFORE_PUBLISH=1 spawn "$ID" --recover 2>&1)
INJECTED_STATUS=$?
[ "$INJECTED_STATUS" -ne 0 ] || fail "recovery test injector unexpectedly published metadata"
assert_contains "$INJECTED_OUTPUT" "stopped before endpoint publication" "recovery injector did not stop before publication"
wait_for_state missing || fail "failed replacement endpoint was not removed"
cmp -s "$META" "$LAB/meta.before" || fail "failed recovery rewrote metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "failed recovery did not restore the exact session bytes"
cmp -s "$HOME_DIR/state/$ID.status" "$LAB/status.before" || fail "failed recovery rewrote task status"
[ "$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] || fail "failed recovery changed the branch"
[ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$RECOVERY_HEAD" ] || fail "failed recovery retained a replacement commit"
[ "$(git -C "$WORKTREE" rev-parse "$BRANCH")" = "$RECOVERY_HEAD" ] || fail "failed recovery did not restore the recorded branch ref"
[ -f "$WORKTREE/.recovery-preserved" ] || fail "failed recovery discarded uncommitted work"
[ -f "$WORKTREE/.recovery-mutate-on-launch" ] || fail "failed recovery discarded pre-existing mutation marker"
[ ! -e "$WORKTREE/.recovery-replacement-edit" ] || fail "failed recovery retained replacement worktree edits"
[ ! -e "$WORKTREE/rollback-delete.txt" ] || fail "failed recovery restored an unstaged tracked deletion"
[ "$(git -C "$WORKTREE" show :'.recovery-staged')" = 'staged recovery state' ] \
  || fail "failed recovery did not restore staged worktree state"
[ "$(cat "$WORKTREE/.recovery-staged")" = $'staged recovery state\nunstaged recovery state' ] \
  || fail "failed recovery did not restore unstaged worktree state"
[ -f "$TASK_TMP/preserve-me" ] || fail "failed recovery removed pre-existing task scratch"
[ ! -e "$TASK_TMP/gotmp" ] && [ ! -L "$TASK_TMP/gotmp" ] \
  || fail "failed recovery retained replacement-owned build scratch"
rm -f "$WORKTREE/.recovery-mutate-on-launch"

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
rm -rf "$TASK_TMP"
[ ! -e "$TASK_TMP" ] || fail "fixture could not remove volatile task scratch"
SNAPSHOT_FAILURE_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_SNAPSHOT=1 spawn "$ID" --recover 2>&1)
SNAPSHOT_FAILURE_STATUS=$?
[ "$SNAPSHOT_FAILURE_STATUS" -ne 0 ] || fail "snapshot-failure recovery unexpectedly launched"
assert_contains "$SNAPSHOT_FAILURE_OUTPUT" "could not snapshot the preserved isolated worktree" \
  "snapshot-failure recovery did not name its snapshot boundary"
wait_for_state missing || fail "snapshot-failure recovery created an endpoint"
[ ! -e "$TASK_TMP" ] && [ ! -L "$TASK_TMP" ] \
  || fail "snapshot-failure recovery retained attempt-owned task scratch"
DURABLE_OUTPUT=$(spawn "$ID" --recover) || fail "recovery after task scratch removal failed"
assert_contains "$DURABLE_OUTPUT" "recovered $ID harness=omp" \
  "durable-session recovery did not report success"
wait_for_state alive || fail "durable-session recovery was not live"
[ "$(cat "$SESSION_POINTER")" = "$SESSION_FILE" ] \
  || fail "task scratch removal invalidated the durable OMP session pointer"
assert_contains "$(cat "$SESSION_FILE")" "FIRSTMATE_OP: v1 launch-brief:" \
  "task scratch removal invalidated the durable OMP session"

PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "durable-session recovery did not leave a removable endpoint"
rm -rf "$TASK_TMP"
[ ! -e "$TASK_TMP" ] || fail "fixture could not remove volatile task scratch before failed retry"
TASKTMP_ABORT_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_BEFORE_PUBLISH=1 spawn "$ID" --recover 2>&1)
TASKTMP_ABORT_STATUS=$?
[ "$TASKTMP_ABORT_STATUS" -ne 0 ] || fail "missing-tasktmp recovery injector unexpectedly published metadata"
assert_contains "$TASKTMP_ABORT_OUTPUT" "stopped before endpoint publication" \
  "missing-tasktmp recovery injector did not stop before publication"
wait_for_state missing || fail "failed missing-tasktmp replacement endpoint was not removed"
[ ! -e "$TASK_TMP" ] && [ ! -L "$TASK_TMP" ] \
  || fail "failed missing-tasktmp recovery retained replacement scratch"
DURABLE_RETRY_OUTPUT=$(spawn "$ID" --recover) || fail "recovery retry after failed missing-tasktmp attempt failed"
assert_contains "$DURABLE_RETRY_OUTPUT" "recovered $ID harness=omp" \
  "recovery retry after failed missing-tasktmp attempt did not report success"
wait_for_state alive || fail "recovery retry after failed missing-tasktmp attempt was not live"
PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "missing-tasktmp retry did not leave a removable endpoint"
rm -f "$SESSION_POINTER" "$SESSION_FILE"
rmdir "$SESSION_DIR" || fail "fixture could not remove durable session state for fresh recovery coverage"
FRESH_OUTPUT=$(spawn "$ID" --recover) || fail "guarded recovery from a lost durable session failed"
assert_contains "$FRESH_OUTPUT" "recovered $ID harness=omp" "fresh-session recovery did not report success"
wait_for_state alive || fail "fresh-session recovery was not live"
[ "$(cat "$SESSION_POINTER")" = "$SESSION_FILE" ] \
  || fail "fresh-session recovery did not publish a durable session pointer"
[ -f "$SESSION_FILE" ] || fail "fresh-session recovery did not create its durable session"
assert_contains "$(cat "$SESSION_FILE")" "FIRSTMATE_OP: v1 launch-brief:" \
  "fresh-session recovery did not launch a new OMP trajectory"

PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "fresh-session recovery did not leave a removable endpoint"
mkdir -p "$TASK_TMP/omp-sessions"
cp "$SESSION_FILE" "$TASK_TMP/omp-sessions/fixture-session.jsonl"
rm -f "$SESSION_POINTER" "$SESSION_FILE"
rmdir "$SESSION_DIR" || fail "fixture could not prepare one surviving legacy session"
cp "$TASK_TMP/omp-sessions/fixture-session.jsonl" "$LAB/legacy-session.before"
cp "$TASK_TMP/omp-sessions/fixture-session.jsonl" "$TASK_TMP/omp-sessions/competing.jsonl"
MULTIPLE_OUTPUT=$(spawn "$ID" --recover 2>&1)
MULTIPLE_STATUS=$?
[ "$MULTIPLE_STATUS" -ne 0 ] || fail "recovery accepted multiple legacy session candidates without a pointer"
assert_contains "$MULTIPLE_OUTPUT" "could not select one exact prior task session" \
  "multiple legacy-session refusal did not name the session-selection boundary"
cmp -s "$META" "$LAB/meta.after-missing" || fail "multiple legacy-session refusal rewrote metadata"
[ ! -e "$SESSION_POINTER" ] && [ ! -e "$SESSION_DIR" ] \
  || fail "multiple legacy-session refusal created durable session state"
rm -f "$TASK_TMP/omp-sessions/competing.jsonl"
LEGACY_INJECTED_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_BEFORE_PUBLISH=1 spawn "$ID" --recover 2>&1)
LEGACY_INJECTED_STATUS=$?
[ "$LEGACY_INJECTED_STATUS" -ne 0 ] \
  || fail "legacy-session recovery injector unexpectedly published metadata"
assert_contains "$LEGACY_INJECTED_OUTPUT" "stopped before endpoint publication" \
  "legacy-session recovery injector did not stop before publication"
wait_for_state missing || fail "failed legacy-session replacement endpoint was not removed"
cmp -s "$TASK_TMP/omp-sessions/fixture-session.jsonl" "$LAB/legacy-session.before" \
  || fail "failed legacy-session recovery changed the preserved temporary session"
[ ! -e "$SESSION_POINTER" ] \
  || fail "failed legacy-session recovery published a durable pointer"
[ ! -e "$SESSION_DIR" ] \
  || fail "failed legacy-session recovery retained replacement-owned durable session state"
LEGACY_OUTPUT=$(spawn "$ID" --recover) || fail "legacy-session migration recovery failed"
assert_contains "$LEGACY_OUTPUT" "recovered $ID harness=omp" "legacy-session recovery did not report success"
wait_for_state alive || fail "legacy-session recovery was not live"
[ "$(cat "$SESSION_POINTER")" = "$SESSION_FILE" ] \
  || fail "legacy-session recovery did not bind the durable exact-session pointer"
[ -f "$SESSION_FILE" ] || fail "legacy-session recovery did not bind a durable session file"
[ -f "$TASK_TMP/omp-sessions/fixture-session.jsonl" ] \
  || fail "legacy-session recovery discarded the preserved temporary session"
cmp -s "$HOME_DIR/data/$ID/brief.md" "$LAB/brief.before" \
  || fail "durable session recovery rewrote the preserved brief"
cmp -s "$HOME_DIR/state/$ID.status" "$LAB/status.before" \
  || fail "durable session recovery rewrote task status"
[ "$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] \
  || fail "durable session recovery changed the branch"
[ -f "$WORKTREE/.recovery-preserved" ] \
  || fail "durable session recovery discarded uncommitted work"
PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "legacy-session recovery did not leave a removable endpoint"
git -C "$WORKTREE" switch -q -c "fm/$ID-branch-mismatch" \
  || fail "fixture could not switch to a mismatched task branch"
cp "$META" "$LAB/meta.before-branch-mismatch"
BRANCH_MISMATCH_OUTPUT=$(spawn "$ID" --recover 2>&1)
BRANCH_MISMATCH_STATUS=$?
[ "$BRANCH_MISMATCH_STATUS" -ne 0 ] || fail "recovery accepted a mismatched task branch"
assert_contains "$BRANCH_MISMATCH_OUTPUT" "exact recorded non-default branch" \
  "branch-mismatch refusal did not name the exact branch boundary"
cmp -s "$META" "$LAB/meta.before-branch-mismatch" \
  || fail "branch-mismatch refusal rewrote metadata"
git -C "$WORKTREE" switch -q "$BRANCH" || fail "fixture could not restore its recorded task branch"
grep -v '^branch=' "$META" > "$LAB/meta.legacy-without-branch"
cp "$LAB/meta.legacy-without-branch" "$META"
LEGACY_BRANCH_OUTPUT=$(spawn "$ID" --recover 2>&1)
LEGACY_BRANCH_STATUS=$?
[ "$LEGACY_BRANCH_STATUS" -ne 0 ] || fail "recovery accepted legacy metadata without branch identity"
assert_contains "$LEGACY_BRANCH_OUTPUT" "exact recorded non-default branch" \
  "legacy-branch refusal did not name the exact branch boundary"
cmp -s "$META" "$LAB/meta.legacy-without-branch" \
  || fail "legacy-branch refusal rewrote metadata"
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
cp "$LAB/meta.before-branch-mismatch" "$META"
rm -f "$SESSION_POINTER"
rm -rf "$SESSION_DIR" "$TASK_TMP/omp-sessions"
FRESH_CLEANUP_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_FINALIZATION=1 \
  FM_SPAWN_RECOVERY_TEST_FAIL_FRESH_SESSION_CLEANUP=1 spawn "$ID" --recover 2>&1)
FRESH_CLEANUP_STATUS=$?
[ "$FRESH_CLEANUP_STATUS" -ne 0 ] || fail "fresh-session cleanup failure unexpectedly succeeded"
wait_for_state missing || fail "fresh-session cleanup failure retained replacement endpoint"
FRESH_DIRECT_SESSIONS=$(find "$SESSION_DIR" -maxdepth 1 -type f -name '*.jsonl' -print)
[ -z "$FRESH_DIRECT_SESSIONS" ] || fail "fresh-session cleanup failure stranded an unpointed durable session"
pass "guarded OMP recovery preserves task state, restores failed attempts, and rejects unsafe records"
