#!/usr/bin/env bash
# Guarded OMP ordinary-worker recovery behavior through the real spawn entrypoint.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || fail "tmux is required for the recovery fixture"

LAB=$(fm_test_tmproot fm-spawn-recovery)
REAL_TMUX=$(command -v tmux)
REAL_TAR=$(command -v tar)
REAL_RM=$(command -v rm)
REAL_RMDIR=$(command -v rmdir)
REAL_MV=$(command -v mv)
REAL_GIT=$(command -v git)
REAL_BUN=$(command -v bun) || fail "bun is required for the recovery fixture"
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
git -C "$PROJECT" worktree add -q --detach "$WORKTREE"

[ ! -e "$TASK_TMP" ] && [ ! -L "$TASK_TMP" ] \
  || fail "recovery fixture task root already exists: $TASK_TMP"
TASK_TMP_OWNED=1

cat > "$WRAPPER_BIN/tmux" <<SH
#!/usr/bin/env bash
if [ "\${FM_SPAWN_RECOVERY_TEST_FAIL_GOTMPDIR_EXPORT:-0}" = 1 ]; then
  for arg in "\$@"; do
    case "\$arg" in
      'export GOTMPDIR='*) exit 1 ;;
    esac
  done
fi
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
  case "\$arg" in
    '$HOME_DIR/state/.fm-spawn-recovery-turnend.'*)
      [ "\${FM_SPAWN_RECOVERY_TEST_FAIL_TURNEND_BACKUP_CLEANUP:-0}" != 1 ] || exit 1
      ;;
  esac
done
exec '$REAL_RM' "\$@"
SH
cat > "$WRAPPER_BIN/rmdir" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\${FM_SPAWN_RECOVERY_TEST_FAIL_SESSION_DIR_CLEANUP:-0}" = 1 ] \
     && [ "\$arg" = '$HOME_DIR/state/$ID.omp-sessions' ]; then
    exit 1
  fi
done
exec '$REAL_RMDIR' "\$@"
SH
cat > "$WRAPPER_BIN/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    '$HOME_DIR/state/$ID.omp-sessions/.fm-spawn-recovery-session.'*|'$TASK_TMP/.fm-spawn-recovery-finalize.'*/session)
      [ "\${FM_SPAWN_RECOVERY_TEST_FAIL_SESSION_RESTORE:-0}" != 1 ] || exit 1
      ;;
  esac
done
exec '$REAL_MV' "\$@"
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
    if [ "\${FM_SPAWN_RECOVERY_TEST_ENDPOINT_LIVE_ON_PREPARE:-0}" = 1 ]; then
      counter='$HOME_DIR/state/.recovery-prepare-status-count'
      count=0
      [ ! -f "\$counter" ] || count=\$(cat "\$counter")
      count=\$((count + 1))
      printf '%s\n' "\$count" > "\$counter"
      if [ "\$count" -eq 2 ]; then
        '$REAL_TMUX' -L '$SOCKET' new-session -d -s 'recovery-$ID' -n 'fm-$ID' -c '$WORKTREE' 'sleep 120'
      fi
    fi
    printf '[{"path":"%s","status":"leased","lease_holder":"fm-$ID","lease_id":"fixture-lease"}]\n' '$WORKTREE'
    ;;
  return) exit 0 ;;
  *) exit 1 ;;
esac
SH
ln -s /bin/bash "$WRAPPER_BIN/bun"
cat > "$WRAPPER_BIN/ack-extension.mjs" <<'JS'
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [extension, sessionFile, triggerTurnEnd, attemptBranch, releaseMarker] = process.argv.slice(2);
const handlers = new Map();
const omp = {
  on(event, handler) {
    handlers.set(event, handler);
  },
};
const module = await import(`${pathToFileURL(extension).href}?fixture=${process.pid}`);
module.default(omp);
const toolCall = async (command) => {
  const handler = handlers.get("tool_call");
  if (!handler) throw new Error("OMP extension did not register a recovery tool-call boundary");
  return handler({ type: "tool_call", toolName: "bash", input: { command } });
};
handlers.get("session_start")?.({}, {
  sessionManager: { getSessionFile: () => sessionFile },
});
if (attemptBranch) {
  const command = `PATH=/tmp/recovery-path-override ${process.env.OMP_FIXTURE_REAL_GIT} switch -c ${attemptBranch}`;
  const result = await toolCall(command);
  if (!result?.block) {
    execFileSync(process.env.OMP_FIXTURE_REAL_GIT, ["switch", "-q", "-c", attemptBranch]);
    writeFileSync(".recovery-own-branch-edit", "replacement branch edit\n");
    execFileSync(process.env.OMP_FIXTURE_REAL_GIT, ["add", ".recovery-own-branch-edit"]);
    execFileSync(process.env.OMP_FIXTURE_REAL_GIT, ["-c", "user.name=Recovery Fixture", "-c", "user.email=recovery@example.invalid", "commit", "-m", "replacement branch mutation"]);
    throw new Error("OMP recovery allowed an absolute Git mutation before authority committed");
  }
}
handlers.get("turn_start")?.();
if (triggerTurnEnd === "1") handlers.get("turn_end")?.();
if (releaseMarker) {
  let released = false;
  for (let attempt = 0; attempt < 300; attempt += 1) {
    const result = await toolCall(`PATH=/tmp/recovery-path-override ${process.env.OMP_FIXTURE_REAL_GIT} status --short`);
    if (!result?.block) {
      execFileSync(process.env.OMP_FIXTURE_REAL_GIT, ["status", "--short"]);
      writeFileSync(releaseMarker, "released\n");
      released = true;
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  if (!released) throw new Error("OMP recovery tool-call boundary did not release after finalization");
}
await new Promise((resolve) => setTimeout(resolve, 100));
JS
cat > "$WRAPPER_BIN/omp" <<'SH'
#!/usr/bin/env bun
case "${1:-}" in
  --help)
    printf '%s\n' '--model= --thinking= --auto-approve --session-dir= --extension= --resume= --max-time='
    exit 0
    ;;
esac
session_dir=
resume=
extension=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session-dir) session_dir=${2:-}; shift 2 ;;
    --session-dir=*) session_dir=${1#*=}; shift ;;
    -e|--extension) extension=${2:-}; shift 2 ;;
    --extension=*) extension=${1#*=}; shift ;;
    -r|--resume) resume=${2:-}; shift 2 ;;
    --resume=*) resume=${1#*=}; shift ;;
    *) shift ;;
  esac
done
[ -n "$session_dir" ] && [ -n "$extension" ] || exit 2
mkdir -p "$session_dir"
if [ -n "${GOTMPDIR:-}" ]; then
  mkdir -p "$GOTMPDIR"
  printf 'fixture build artifact\n' > "$GOTMPDIR/fixture-build-artifact"
  printf '%s' "${TRACEPARENT:-}" > "$GOTMPDIR/traceparent"
fi
session_file="$session_dir/fixture-session.jsonl"
if [ -n "$resume" ]; then
  cat "$session_file" > "$session_file.next" || exit 1
  printf 'replacement-attempt\n' >> "$session_file.next"
  mv "$session_file.next" "$session_file" || exit 1
  [ -z "${OMP_FIXTURE_LOG:-}" ] || printf '%s\n' "$extension" >> "$OMP_FIXTURE_LOG"
  if [ -f .recovery-concurrent-worktree-on-launch ]; then
    concurrent_worktree=$(tr -d '\r\n' < .recovery-concurrent-worktree-on-launch)
    printf 'concurrent worktree edit\n' > "$concurrent_worktree/concurrent.txt"
    "${OMP_FIXTURE_REAL_GIT:?}" -C "$concurrent_worktree" add concurrent.txt || exit 1
    "${OMP_FIXTURE_REAL_GIT:?}" -C "$concurrent_worktree" -c user.name='Recovery Fixture' \
      -c user.email=recovery@example.invalid commit -m 'concurrent mutation' || exit 1
  fi
else
  printf 'FIRSTMATE_OP: v1 launch-brief: fixture\n' > "$session_file"
fi
base=${session_dir%.omp-sessions}
printf '%s\n' "$session_file" > "$base.omp-session"
tool_gate_attempt=
tool_gate_release=
[ ! -f .recovery-tool-gate-attempt ] || tool_gate_attempt=$(tr -d '\r\n' < .recovery-tool-gate-attempt)
[ ! -f .recovery-tool-gate-release-check ] || tool_gate_release=$(tr -d '\r\n' < .recovery-tool-gate-release-check)
"${OMP_FIXTURE_BUN:?}" "$(dirname "$0")/ack-extension.mjs" "$extension" "$session_file" "${OMP_FIXTURE_TURN_END:-0}" "$tool_gate_attempt" "$tool_gate_release" || exit 1
while :; do sleep 1; done
SH
chmod +x "$WRAPPER_BIN/tmux" "$WRAPPER_BIN/tar" "$WRAPPER_BIN/rm" "$WRAPPER_BIN/rmdir" "$WRAPPER_BIN/mv" "$WRAPPER_BIN/treehouse" "$WRAPPER_BIN/omp"

FIXTURE_PATH="$WRAPPER_BIN:$PATH"
export OMP_FIXTURE_LOG="$LAB/omp-launches"
export OMP_FIXTURE_BUN="$REAL_BUN"
export OMP_FIXTURE_REAL_GIT="$REAL_GIT"
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
[ "$BRANCH" = "fm/$ID" ] \
  || fail "initial OMP worker did not establish its task branch from a detached lease"
assert_contains "$(cat "$META")" "branch=$BRANCH" \
  "initial worker did not record its exact branch identity"

FOREIGN_SESSION_SNAPSHOT="$SESSION_DIR/.fm-spawn-recovery-session.foreign"
printf 'foreign interrupted snapshot\n' > "$FOREIGN_SESSION_SNAPSHOT"
RACE_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_ENDPOINT_LIVE_ON_PREPARE=1 spawn "$ID" --recover 2>&1)
RACE_STATUS=$?
[ "$RACE_STATUS" -ne 0 ] || fail "revalidation race unexpectedly launched recovery"
assert_contains "$RACE_OUTPUT" "definitely dead or missing endpoint" \
  "revalidation race did not reject its newly live endpoint"
wait_for_state ambiguous || fail "revalidation race did not make the recorded endpoint live"
[ ! -e "$HOME_DIR/state/$ID.omp-recovery-rollback-pending" ] \
  && [ ! -L "$HOME_DIR/state/$ID.omp-recovery-rollback-pending" ] \
  || fail "revalidation race retained a rollback manifest before snapshots"
RACE_ARTIFACT=$(find "$TASK_TMP" -maxdepth 1 -name '.fm-spawn-recovery*' -print -quit)
[ -z "$RACE_ARTIFACT" ] || fail "revalidation race retained a recovery attempt artifact"
cmp -s "$FOREIGN_SESSION_SNAPSHOT" <(printf 'foreign interrupted snapshot\n') \
  || fail "revalidation race deleted a foreign recovery snapshot"
cmp -s "$META" "$LAB/meta.before" || fail "revalidation race rewrote metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "revalidation race changed durable session state"
PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "revalidation race fixture endpoint did not return to missing"
rm -f "$FOREIGN_SESSION_SNAPSHOT"
rm -f "$HOME_DIR/state/.recovery-prepare-status-count"

PRELAUNCH_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_GOTMPDIR_EXPORT=1 spawn "$ID" --recover 2>&1)
PRELAUNCH_STATUS=$?
[ "$PRELAUNCH_STATUS" -ne 0 ] || fail "pre-launch recovery failure unexpectedly succeeded"
assert_contains "$PRELAUNCH_OUTPUT" "GOTMPDIR export could not be submitted" \
  "pre-launch recovery failure did not reach the endpoint setup boundary"
wait_for_state missing || fail "pre-launch recovery failure retained its replacement endpoint"
cmp -s "$META" "$LAB/meta.before" || fail "pre-launch recovery failure rewrote metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "pre-launch recovery failure changed the durable session"

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
GATE_RELEASE_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_GATE_RELEASE=1 spawn "$ID" --recover 2>&1)
GATE_RELEASE_STATUS=$?
[ "$GATE_RELEASE_STATUS" -ne 0 ] || fail "recovery gate-release failure unexpectedly succeeded"
assert_contains "$GATE_RELEASE_OUTPUT" "published its replacement endpoint" \
  "gate-release failure did not reach endpoint finalization"
wait_for_state missing || fail "gate-release failure retained replacement endpoint"
cmp -s "$META" "$LAB/meta.before" || fail "gate-release failure retained replacement metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "gate-release failure did not restore the exact session bytes"
SESSION_RESTORE_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_FINALIZATION=1 \
  FM_SPAWN_RECOVERY_TEST_FAIL_SESSION_RESTORE=1 spawn "$ID" --recover 2>&1)
SESSION_RESTORE_STATUS=$?
[ "$SESSION_RESTORE_STATUS" -ne 0 ] || fail "session-restore failure unexpectedly succeeded"
wait_for_state missing || fail "session-restore failure retained replacement endpoint"
[ -f "$HOME_DIR/state/$ID.omp-recovery-rollback-pending" ] \
  || fail "session-restore failure did not retain its durable rollback manifest"
SESSION_RESTORE_RETRY_OUTPUT=$(spawn "$ID" --recover 2>&1)
SESSION_RESTORE_RETRY_STATUS=$?
[ "$SESSION_RESTORE_RETRY_STATUS" -ne 0 ] || fail "incomplete recovery rollback allowed a retry"
assert_contains "$SESSION_RESTORE_RETRY_OUTPUT" "unfinished recovery rollback state" \
  "incomplete recovery rollback did not name its durable safety boundary"
cp "$LAB/session.before" "$SESSION_FILE"
rm -f "$HOME_DIR/state/$ID.omp-recovery-rollback-pending"
INTERRUPT_RELEASE_MARKER="$LAB/tool-gate-interrupt-released"
printf '%s\n' "$INTERRUPT_RELEASE_MARKER" > "$WORKTREE/.recovery-tool-gate-release-check"
INTERRUPT_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_INTERRUPT_AFTER_GATE_COMMIT=1 spawn "$ID" --recover 2>&1)
INTERRUPT_STATUS=$?
[ "$INTERRUPT_STATUS" -ne 0 ] || fail "gate-commit interruption unexpectedly succeeded"
wait_for_state alive || fail "gate-commit interruption rolled back its committed replacement"
wait_file "$INTERRUPT_RELEASE_MARKER" \
  || fail "gate-commit interruption left committed replacement tools blocked"
rm -f "$WORKTREE/.recovery-tool-gate-release-check"
PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "gate-commit interruption fixture endpoint did not stop"
cp "$SESSION_FILE" "$LAB/session.before"
ARCHIVE_FINALIZATION_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_FINALIZATION_ARCHIVE_DELETE=1 spawn "$ID" --recover 2>&1) \
  || fail "post-commit archive cleanup failure reported a failed recovery"
assert_contains "$ARCHIVE_FINALIZATION_OUTPUT" "recovered $ID harness=omp" \
  "post-commit archive cleanup failure did not preserve committed recovery"
wait_for_state alive || fail "post-commit archive cleanup failure did not retain replacement endpoint"
PATH="$FIXTURE_PATH" tmux kill-window -t "$TARGET"
wait_for_state missing || fail "post-commit archive cleanup fixture endpoint did not stop"
cp "$SESSION_FILE" "$LAB/session.before"
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
rm "$WORKTREE/rollback-delete.txt"
TURNEND="$HOME_DIR/state/$ID.turn-ended"
printf 'preserved turn-end marker\n' > "$TURNEND"
cp "$TURNEND" "$LAB/turnend.before"
INJECTED_OUTPUT=$(OMP_FIXTURE_TURN_END=1 FM_SPAWN_RECOVERY_TEST_FAIL_BEFORE_PUBLISH=1 spawn "$ID" --recover 2>&1)
INJECTED_STATUS=$?
[ "$INJECTED_STATUS" -ne 0 ] || fail "recovery test injector unexpectedly published metadata"
assert_contains "$INJECTED_OUTPUT" "stopped before endpoint publication" "recovery injector did not stop before publication"
wait_for_state missing || fail "failed replacement endpoint was not removed"
cmp -s "$META" "$LAB/meta.before" || fail "failed recovery rewrote metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "failed recovery did not restore the exact session bytes"
cmp -s "$HOME_DIR/state/$ID.status" "$LAB/status.before" || fail "failed recovery rewrote task status"
cmp -s "$TURNEND" "$LAB/turnend.before" || fail "failed recovery rewrote the prior turn-end marker"
[ "$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] || fail "failed recovery changed the branch"
[ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$RECOVERY_HEAD" ] || fail "failed recovery retained a replacement commit"
[ "$(git -C "$WORKTREE" rev-parse "$BRANCH")" = "$RECOVERY_HEAD" ] || fail "failed recovery did not restore the recorded branch ref"
[ -f "$WORKTREE/.recovery-preserved" ] || fail "failed recovery discarded uncommitted work"
[ ! -e "$WORKTREE/.recovery-replacement-edit" ] || fail "failed recovery retained replacement worktree edits"
[ ! -e "$WORKTREE/rollback-delete.txt" ] || fail "failed recovery restored an unstaged tracked deletion"
[ "$(git -C "$WORKTREE" show :'.recovery-staged')" = 'staged recovery state' ] \
  || fail "failed recovery did not restore staged worktree state"
[ "$(cat "$WORKTREE/.recovery-staged")" = $'staged recovery state\nunstaged recovery state' ] \
  || fail "failed recovery did not restore unstaged worktree state"
[ -f "$TASK_TMP/preserve-me" ] || fail "failed recovery removed pre-existing task scratch"
[ ! -e "$TASK_TMP/gotmp" ] && [ ! -L "$TASK_TMP/gotmp" ] \
  || fail "failed recovery retained replacement-owned build scratch"
TURNEND_BACKUP_OUTPUT=$(OMP_FIXTURE_TURN_END=1 FM_SPAWN_RECOVERY_TEST_FAIL_BEFORE_PUBLISH=1 \
  FM_SPAWN_RECOVERY_TEST_FAIL_TURNEND_BACKUP_CLEANUP=1 spawn "$ID" --recover 2>&1)
TURNEND_BACKUP_STATUS=$?
[ "$TURNEND_BACKUP_STATUS" -ne 0 ] || fail "turn-end backup cleanup failure unexpectedly succeeded"
wait_for_state missing || fail "turn-end backup cleanup failure retained replacement endpoint"
cmp -s "$META" "$LAB/meta.before" || fail "turn-end backup cleanup failure rewrote metadata"
cmp -s "$SESSION_FILE" "$LAB/session.before" || fail "turn-end backup cleanup failure did not restore the exact session bytes"
cmp -s "$TURNEND" "$LAB/turnend.before" || fail "turn-end backup cleanup failure rewrote the prior marker"
TURNEND_BACKUP_RETRY_OUTPUT=$(spawn "$ID" --recover 2>&1)
TURNEND_BACKUP_RETRY_STATUS=$?
[ "$TURNEND_BACKUP_RETRY_STATUS" -ne 0 ] || fail "incomplete turn-end rollback allowed a retry"
assert_contains "$TURNEND_BACKUP_RETRY_OUTPUT" "unfinished recovery rollback state" \
  "turn-end rollback manifest did not block an unsafe retry"
rm -f "$HOME_DIR/state/$ID.omp-recovery-rollback-pending"
rm -f "$TURNEND"
TURNEND_ABSENT_OUTPUT=$(OMP_FIXTURE_TURN_END=1 FM_SPAWN_RECOVERY_TEST_FAIL_BEFORE_PUBLISH=1 spawn "$ID" --recover 2>&1)
TURNEND_ABSENT_STATUS=$?
[ "$TURNEND_ABSENT_STATUS" -ne 0 ] || fail "absent turn-end marker injector unexpectedly published metadata"
assert_contains "$TURNEND_ABSENT_OUTPUT" "stopped before endpoint publication" \
  "absent turn-end marker injector did not stop before publication"
wait_for_state missing || fail "absent turn-end marker failure retained replacement endpoint"
[ ! -e "$TURNEND" ] && [ ! -L "$TURNEND" ] \
  || fail "failed recovery retained an attempt-created turn-end marker"
TOOL_GATE_RELEASE_MARKER="$LAB/tool-gate-released"
printf '%s\n' "$TOOL_GATE_RELEASE_MARKER" > "$WORKTREE/.recovery-tool-gate-release-check"
RECOVERED_OUTPUT=$(spawn "$ID" --recover) || fail "guarded recovery from a missing endpoint failed"
assert_contains "$RECOVERED_OUTPUT" "recovered $ID harness=omp" "recovery did not report success"
wait_for_state alive || fail "recovered missing endpoint was not live"
wait_file "$TOOL_GATE_RELEASE_MARKER" || fail "OMP recovery tool-call boundary did not release after finalization"
rm -f "$WORKTREE/.recovery-tool-gate-release-check"
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
OWN_BRANCH="fm/$ID-replacement-attempt"
printf '%s\n' "$OWN_BRANCH" > "$WORKTREE/.recovery-tool-gate-attempt"
OWN_BRANCH_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_BEFORE_PUBLISH=1 spawn "$ID" --recover 2>&1)
OWN_BRANCH_STATUS=$?
[ "$OWN_BRANCH_STATUS" -ne 0 ] || fail "attempt-branch recovery failure unexpectedly succeeded"
wait_for_state missing || fail "attempt-branch recovery failure retained replacement endpoint"
[ "$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] \
  || fail "attempt-branch recovery failure retained its replacement branch"
git -C "$WORKTREE" show-ref --verify --quiet "refs/heads/$OWN_BRANCH" \
  && fail "attempt-branch recovery failure retained its replacement ref"
[ ! -e "$WORKTREE/.recovery-own-branch-edit" ] \
  || fail "attempt-branch recovery failure retained its replacement commit"
rm -f "$WORKTREE/.recovery-tool-gate-attempt"
rm -rf "$TASK_TMP"
[ ! -e "$TASK_TMP" ] || fail "fixture could not remove volatile task scratch"
STALE_SESSION_SNAPSHOT=$(find "$SESSION_DIR" -maxdepth 1 -type f -name '.fm-spawn-recovery-session.*' -print -quit)
if [ -n "$STALE_SESSION_SNAPSHOT" ]; then
  cp "$STALE_SESSION_SNAPSHOT" "$LAB/stale-session-snapshot.before"
fi
SNAPSHOT_FAILURE_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_SNAPSHOT=1 spawn "$ID" --recover 2>&1)
SNAPSHOT_FAILURE_STATUS=$?
[ "$SNAPSHOT_FAILURE_STATUS" -ne 0 ] || fail "snapshot-failure recovery unexpectedly launched"
assert_contains "$SNAPSHOT_FAILURE_OUTPUT" "could not snapshot the preserved isolated worktree" \
  "snapshot-failure recovery did not name its snapshot boundary"
wait_for_state missing || fail "snapshot-failure recovery created an endpoint"
[ ! -e "$TASK_TMP" ] && [ ! -L "$TASK_TMP" ] \
  || fail "snapshot-failure recovery retained attempt-owned task scratch"
if [ -n "$STALE_SESSION_SNAPSHOT" ]; then
  cmp -s "$STALE_SESSION_SNAPSHOT" "$LAB/stale-session-snapshot.before" \
    || fail "snapshot-failure recovery changed a foreign session snapshot"
fi
REMAINING_SESSION_SNAPSHOT=$(find "$SESSION_DIR" -maxdepth 1 -type f -name '.fm-spawn-recovery-session.*' -print -quit)
[ "$REMAINING_SESSION_SNAPSHOT" = "$STALE_SESSION_SNAPSHOT" ] \
  || fail "snapshot-failure recovery retained its own incomplete session snapshot"
[ -z "$STALE_SESSION_SNAPSHOT" ] || rm -f -- "$STALE_SESSION_SNAPSHOT"
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
TEARDOWN_ARCHIVE=$(mktemp "$HOME_DIR/state/.fm-teardown-omp-state-$ID.XXXXXX.tar")
mv "$META" "$LAB/meta.during-teardown-rollback"
TEARDOWN_ROLLBACK_OUTPUT=$(spawn "$ID" --recover 2>&1)
TEARDOWN_ROLLBACK_STATUS=$?
[ "$TEARDOWN_ROLLBACK_STATUS" -ne 0 ] || fail "recovery accepted unfinished ordinary-session teardown rollback state"
assert_contains "$TEARDOWN_ROLLBACK_OUTPUT" "unfinished ordinary-session teardown rollback state" \
  "recovery did not refuse unfinished ordinary-session teardown rollback state"
mv "$LAB/meta.during-teardown-rollback" "$META"
rm -f "$TEARDOWN_ARCHIVE"
if FM_SPAWN_RECOVERY_TEST_FAIL_FINALIZATION=1 \
  FM_SPAWN_RECOVERY_TEST_FAIL_FRESH_SESSION_CLEANUP=1 spawn "$ID" --recover >/dev/null 2>&1; then
  fail "fresh-session cleanup failure unexpectedly succeeded"
fi
wait_for_state missing || fail "fresh-session cleanup failure retained replacement endpoint"
FRESH_DIRECT_SESSIONS=$(find "$SESSION_DIR" -maxdepth 1 -type f -name '*.jsonl' -print)
[ -z "$FRESH_DIRECT_SESSIONS" ] || fail "fresh-session cleanup failure stranded an unpointed durable session"
[ -f "$SESSION_DIR/.fm-spawn-recovery-cleanup-pending" ] \
  || fail "fresh-session cleanup failure did not retain its deterministic recovery guard"
FRESH_RETRY_OUTPUT=$(spawn "$ID" --recover 2>&1)
FRESH_RETRY_STATUS=$?
[ "$FRESH_RETRY_STATUS" -ne 0 ] || fail "fresh-session cleanup failure allowed an unsafe retry"
assert_contains "$FRESH_RETRY_OUTPUT" "unfinished recovery rollback state" \
  "fresh-session cleanup did not refuse a deterministic retry"
rm -f "$HOME_DIR/state/$ID.omp-recovery-rollback-pending"
rm -f "$SESSION_DIR/.fm-spawn-recovery-cleanup-pending"
rm -rf "$SESSION_DIR"
[ ! -e "$SESSION_DIR" ] || fail "fixture could not remove the resolved fresh-session cleanup guard"
rm -f "$SESSION_POINTER"
if FM_SPAWN_RECOVERY_TEST_FAIL_FINALIZATION=1 \
  FM_SPAWN_RECOVERY_TEST_FAIL_SESSION_DIR_CLEANUP=1 spawn "$ID" --recover >/dev/null 2>&1; then
  fail "fresh-session directory cleanup failure unexpectedly succeeded"
fi
wait_for_state missing || fail "fresh-session directory cleanup failure retained replacement endpoint"
[ ! -e "$SESSION_POINTER" ] && [ ! -L "$SESSION_POINTER" ] \
  || fail "fresh-session directory cleanup failure retained a dangling pointer"
[ -f "$SESSION_DIR/.fm-spawn-recovery-cleanup-pending" ] \
  || fail "fresh-session directory cleanup failure did not retain its retry guard"
RMDIR_RETRY_OUTPUT=$(spawn "$ID" --recover 2>&1)
RMDIR_RETRY_STATUS=$?
[ "$RMDIR_RETRY_STATUS" -ne 0 ] || fail "fresh-session directory cleanup allowed an unsafe retry"
assert_contains "$RMDIR_RETRY_OUTPUT" "unfinished recovery rollback state" \
  "fresh-session directory cleanup did not refuse retry"
rm -f "$HOME_DIR/state/$ID.omp-recovery-rollback-pending"
rm -f "$SESSION_DIR/.fm-spawn-recovery-cleanup-pending"
rm -rf "$SESSION_DIR"
rm -f "$SESSION_POINTER"
rm -rf "$TASK_TMP"
mkdir -p "$SESSION_DIR"
printf 'FIRSTMATE_OP: v1 launch-brief: concurrent\n' > "$SESSION_FILE"
printf '%s\n' "$SESSION_FILE" > "$SESSION_POINTER"
CONCURRENT_WORKTREE="$LAB/concurrent-worktree"
CONCURRENT_BRANCH="$BRANCH"
git -C "$PROJECT" worktree add -q --force "$CONCURRENT_WORKTREE" "$CONCURRENT_BRANCH" \
  || fail "fixture could not create a concurrent linked worktree"
CONCURRENT_HEAD=$(git -C "$CONCURRENT_WORKTREE" rev-parse HEAD) || fail "fixture could not record concurrent branch head"
printf '%s\n' "$CONCURRENT_WORKTREE" > "$WORKTREE/.recovery-concurrent-worktree-on-launch"
CONCURRENT_OUTPUT=$(FM_SPAWN_RECOVERY_TEST_FAIL_BEFORE_PUBLISH=1 spawn "$ID" --recover 2>&1)
CONCURRENT_STATUS=$?
[ "$CONCURRENT_STATUS" -ne 0 ] || fail "concurrent-ref recovery failure unexpectedly succeeded"
assert_contains "$CONCURRENT_OUTPUT" "could not restore the preserved isolated worktree snapshot" \
  "concurrent-ref recovery failure did not retain rollback authority"
wait_for_state missing || fail "concurrent-ref recovery failure retained replacement endpoint"
CONCURRENT_AFTER=$(git -C "$CONCURRENT_WORKTREE" rev-parse "$CONCURRENT_BRANCH") \
  || fail "concurrent-ref recovery failure removed the concurrent branch"
[ "$CONCURRENT_AFTER" != "$CONCURRENT_HEAD" ] \
  || fail "fixture did not advance the concurrent linked worktree branch"
[ -f "$HOME_DIR/state/$ID.omp-ref-rollback-pending" ] \
  || fail "concurrent-ref recovery failure did not retain its rollback guard"
CONCURRENT_RETRY_OUTPUT=$(spawn "$ID" --recover 2>&1)
CONCURRENT_RETRY_STATUS=$?
[ "$CONCURRENT_RETRY_STATUS" -ne 0 ] || fail "concurrent-ref recovery guard allowed an unsafe retry"
assert_contains "$CONCURRENT_RETRY_OUTPUT" "unresolved branch rollback state" \
  "concurrent-ref recovery guard did not name the branch rollback boundary"
pass "guarded OMP recovery preserves task state, restores failed attempts, and rejects unsafe records"
