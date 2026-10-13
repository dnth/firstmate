#!/usr/bin/env bash
# Remote OMP second mate: an update that changes the extension closure its
# running session loaded, followed by the persist-gated restart.
#
# What these pin, through the real host-local control
# (bin/fm-remote-secondmate-control.sh) against real git homes:
#
#   1. The binding matrix. The restart pass's correlated persist request binds
#      to a loaded closure that the home's own recorded fast-forwards
#      superseded, across one update or several. Every other case is refused
#      before any notification, exactly as before: an ordinary request to that
#      same session, a persist request without its parent correlation, a
#      loaded closure that no recorded fast-forward explains, a rewind, and a
#      tracked closure with uncommitted edits.
#   2. End to end over the deterministic SSH boundary and the Herdr fixture:
#      the real update crosses an extension change, and the real restart
#      delivers the persist request, waits for the running session's answer,
#      stops that session only afterwards, and brings up a replacement on the
#      new closure.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"
# shellcheck source=bin/fm-primary-watch-version-lib.sh
. "$ROOT/bin/fm-primary-watch-version-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

fm_git_identity
TMP_ROOT=$(fm_test_tmproot fm-remote-update-restart)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
# Keep every git discovery inside the fixture rather than the repo under test.
git -C "$TMP_ROOT" init -q

# --- 1. binding matrix ------------------------------------------------------

M="$TMP_ROOT/matrix"
M_ROOT="$M/root"
M_HOME="$M/home"
M_DEV="$M/dev"
M_ID=bind-omp
M_STATE="$M_HOME/state/parent-route"
mkdir -p "$M/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$M/bin/bun"
printf '#!/usr/bin/env bash\nexit 0\n' > "$M/bin/omp"
chmod +x "$M/bin/bun" "$M/bin/omp"

git init -q --bare "$M/origin.git"
git -C "$M/origin.git" symbolic-ref HEAD refs/heads/main
git init -q -b main "$M_DEV"
while IFS= read -r path; do
  mkdir -p "$M_DEV/$(dirname "$path")"
  cp "$ROOT/$path" "$M_DEV/$path"
done <<EOF
$(fm_omp_primary_closure_paths)
EOF
printf '# agents\n' > "$M_DEV/AGENTS.md"
printf '/data/\n/state/\n/config/\n.fm-secondmate-home\n' > "$M_DEV/.gitignore"
git -C "$M_DEV" add -A
git -C "$M_DEV" commit -qm c1
git -C "$M_DEV" remote add origin "$M/origin.git"
git -C "$M_DEV" push -q -u origin main
git clone -q "$M/origin.git" "$M_ROOT"
git clone -q "$M/origin.git" "$M_HOME"

# The code root carries the real control and the libraries a delivery binding
# sources. Only the backend inventory and the host-local send are stubbed: the
# stub send is the notification, so an empty log proves nothing was notified.
cp "$ROOT/bin/fm-remote-secondmate-control.sh" "$ROOT/bin/fm-omp-auth-token-lib.sh" \
  "$ROOT/bin/fm-secondmate-charter-lib.sh" "$ROOT/bin/fm-marker-lib.sh" \
  "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-primary-watch-version-lib.sh" \
  "$ROOT/bin/fm-omp-process-lib.sh" "$M_ROOT/bin/"
cat > "$M_ROOT/bin/fm-backend.sh" <<'SH'
fm_backend_validate_task_endpoint() {
  FM_BACKEND_VALIDATED_BACKEND=herdr
  FM_BACKEND_VALIDATED_TARGET='fm-remote:w1:p1'
}
fm_backend_agent_record_identity() { return 0; }
fm_backend_agent_state() { printf 'alive'; }
fm_backend_meta_exact_value() { sed -n "s/^$2=//p" "$1"; }
fm_meta_get() { sed -n "s/^$2=//p" "$1" | tail -1; }
SH
: > "$M_ROOT/bin/fm-pending-reply-lib.sh"
: > "$M_ROOT/bin/fm-quota-axi-lib.sh"
cat > "$M_ROOT/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_NOTIFIED"
printf 'request=0123456789abcdef record=001 state=recorded\n'
SH
chmod +x "$M_ROOT/bin/fm-remote-secondmate-control.sh" "$M_ROOT/bin/fm-send.sh"

printf '%s\n' "$M_ID" > "$M_HOME/.fm-secondmate-home"
mkdir -p "$M_STATE" "$M_HOME/state/omp-sessions" "$M_HOME/data/.parent-route"
printf '{"type":"session"}\n' > "$M_HOME/state/omp-sessions/selected.jsonl"
printf '%s\n' "$M_HOME/state/omp-sessions/selected.jsonl" > "$M_HOME/state/.omp-session"
printf '4242\n' > "$M_STATE/$M_ID.omp-doorbell-ready"
fm_write_meta "$M_STATE/$M_ID.meta" \
  'window=fm-remote:w1:p1' "endpoint_task_id=$M_ID" 'backend=herdr' \
  "worktree=$M_HOME" "project=$M_HOME" 'harness=omp' 'kind=secondmate' \
  "omp_bun=$M/bin/bun" "omp_bin=$M/bin/omp" \
  'herdr_session=fm-remote' 'herdr_workspace_id=w1' 'herdr_tab_id=w1:t1' \
  'herdr_pane_id=w1:p1'

matrix_head() { git -C "$M_HOME" rev-parse HEAD; }
matrix_version_at() { fm_omp_primary_version_at_commit "$M_HOME" "$1"; }
# The running session's loaded marker: version, owner pid, launch identity.
matrix_load() { # <version>
  printf '%s\n4242\n%s\n%s\n' "$1" "$M/bin/bun" "$M/bin/omp" \
    > "$M_HOME/state/.omp-primary-extension-loaded"
}
# One published extension change, taken the way an update takes it: the code
# root fast-forwards, then the real `sync` verb fast-forwards the home to it.
matrix_update() { # <label>
  printf '// %s\n' "$1" >> "$M_DEV/bin/fm-primary-watch-core.ts"
  git -C "$M_DEV" commit -qam "$1"
  git -C "$M_DEV" push -q origin main
  git -C "$M_ROOT" pull -q --ff-only
  FM_HOME="$M_HOME" FM_ROOT_OVERRIDE="$M_ROOT" \
    "$M_ROOT/bin/fm-remote-secondmate-control.sh" sync "$M_ID" > "$M/sync.out" 2>&1 \
    || fail "matrix home did not fast-forward for $1: $(cat "$M/sync.out")"
}
# Sends <body> with a parent correlation unless the body already starts with
# one or opts out with a leading "-"; extra arguments follow the message.
matrix_send() { # <body> [restart-persist]
  local body=$1 carrier
  shift
  case "$body" in
    -*) body=${body#-} ;;
    corr=*) ;;
    *) body="corr=0123456789abcdef $body" ;;
  esac
  fm_message_mark_from_firstmate "$body" carrier
  : > "$M/notified"
  FM_HOME="$M_HOME" FM_ROOT_OVERRIDE="$M_ROOT" FM_TEST_NOTIFIED="$M/notified" \
    "$M_ROOT/bin/fm-remote-secondmate-control.sh" send "$M_ID" "$carrier" "$@" > "$M/send.out" 2>&1
  MATRIX_RC=$?
}
expect_bound() { # <what>
  expect_code 0 "$MATRIX_RC" "$1 was refused: $(cat "$M/send.out")"
  [ -s "$M/notified" ] || fail "$1 never reached the session's host-local delivery"
}
expect_refused() { # <what>
  expect_code 9 "$MATRIX_RC" "$1 was not refused as a binding mismatch: $(cat "$M/send.out")"
  assert_grep 'remote-omp-binding-refused' "$M/send.out" "$1 did not name its binding refusal"
  assert_grep 'no remote notification was sent' "$M/send.out" "$1 did not promise that nothing was notified"
  [ ! -s "$M/notified" ] || fail "$1 notified the session after refusing: $(cat "$M/notified")"
}

C1=$(matrix_head)
matrix_load "$(matrix_version_at "$C1")"
matrix_send "steer before any update"
expect_bound "an ordinary request to a current session"
matrix_send /exit
expect_bound "a slash command to a current session"
assert_grep '/exit' "$M/notified" "the current session did not receive the slash command"

# One update crosses an extension change while the session keeps running.
matrix_update first-extension-change
C2=$(matrix_head)
[ "$(matrix_version_at "$C1")" != "$(matrix_version_at "$C2")" ] \
  || fail "the matrix update did not change the extension closure"
matrix_send "ordinary steer after the update"
expect_refused "an ordinary request to a session the update superseded"
matrix_send /exit
expect_refused "a slash command to a session the update superseded"
assert_grep 'loaded OMP primary extension does not match its tracked closure' "$M/send.out" \
  "an ordinary request after the update lost its exact refusal reason"
matrix_send "persist request" restart-persist
expect_bound "the restart persist request to a session one recorded update superseded"
matrix_send "-persist request without correlation" restart-persist
expect_refused "a restart persist request without its parent correlation"
matrix_send "corr=0123456789abcdef /exit" restart-persist
expect_refused "a slash command marked as the restart persist request"
pass "the restart persist request alone binds to the closure one recorded update superseded"

# A second update before any restart: the chain of recorded fast-forwards
# still explains the closure the session loaded two commits ago.
matrix_update second-extension-change
C3=$(matrix_head)
matrix_send "persist request" restart-persist
expect_bound "the restart persist request across two recorded updates"
matrix_send "ordinary steer after two updates"
expect_refused "an ordinary request after two updates"
pass "a chain of recorded fast-forwards explains a closure several updates old"

# A loaded closure no commit on the home's recorded chain carries, such as a
# session started from uncommitted extension edits, explains nothing.
matrix_load "$(printf 'foreign extension bytes' | fm_version_hash_stdin)"
matrix_send "persist request" restart-persist
expect_refused "the restart persist request to a session no recorded update explains"
assert_grep 'loaded OMP primary extension does not match its tracked closure' "$M/send.out" \
  "an unexplained closure lost its exact refusal reason"
matrix_send /exit
expect_refused "a slash command to a session no recorded update explains"

# Tracked files that are not HEAD's committed closure leave the mismatch
# unexplained even when the loaded closure is on the chain.
matrix_load "$(matrix_version_at "$C2")"
printf '// uncommitted\n' >> "$M_HOME/bin/fm-primary-watch-core.ts"
cp "$M_HOME/bin/fm-primary-watch-core.ts" "$M_ROOT/bin/fm-primary-watch-core.ts"
matrix_send "persist request" restart-persist
expect_refused "the restart persist request over an uncommitted tracked closure"
git -C "$M_HOME" checkout -q -- bin/fm-primary-watch-core.ts
git -C "$M_ROOT" checkout -q -- bin/fm-primary-watch-core.ts

# A rewind is not an update: a session that loaded the newest closure cannot be
# explained by the home moving back to an older commit.
matrix_load "$(matrix_version_at "$C3")"
git -C "$M_HOME" checkout -q --detach "$C1"
git -C "$M_ROOT" checkout -q --detach "$C1"
matrix_send "persist request" restart-persist
expect_refused "the restart persist request after a rewind"
pass "unexplained, uncommitted, and rewound closures stay refused before notification"

# --- 2. end to end: update, then the persist-gated restart -----------------

E="$TMP_ROOT/e2e"
PARENT="$E/parent"
REMOTE_ROOT="$E/remote-root"
REMOTE_ORIGIN="$E/firstmate-origin.git"
OMP_HOME="$E/remote-omp-home"
ID=omp-update-restart
FAKEBIN=$(fm_fakebin "$E/fake")
HERDR_STATE="$E/remote-herdr.state"
HERDR_LOG="$E/remote-herdr.log"
OMP_ACTIVE_PID="$E/remote-omp-active.pid"
OMP_EVENTS="$E/remote-omp-events.log"
OMP_SENT="$E/remote-omp-send-message.log"
CLAIMS="$E/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"

# The host's job worker is a supervisor plus its serving child. Stop both while
# their state root still exists, so the child can release its ownership.
stop_remote_job_worker() {
  local pid supervisor='' waited=0
  pid=$(cat "$E/remote-jobs/worker.pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  case "$(ps -p "$pid" -o command= 2>/dev/null || true)" in
    *"$REMOTE_ROOT/bin/fm-remote-job-worker.sh"*) ;;
    *) return 0 ;;
  esac
  supervisor=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
  case "$supervisor" in
    ''|*[!0-9]*|0|1) supervisor='' ;;
    *)
      case "$(ps -p "$supervisor" -o command= 2>/dev/null || true)" in
        *"$REMOTE_ROOT/bin/fm-remote-job-worker.sh"*) kill "$supervisor" 2>/dev/null || true ;;
        *) supervisor='' ;;
      esac
      ;;
  esac
  kill "$pid" 2>/dev/null || true
  while { [ -n "$supervisor" ] && kill -0 "$supervisor" 2>/dev/null; } || kill -0 "$pid" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || return 1
    sleep 0.05
  done
}

cleanup() {
  local pid
  if [ -s "$OMP_ACTIVE_PID" ]; then
    pid=$(cat "$OMP_ACTIVE_PID")
    kill -TERM "$pid" 2>/dev/null || true
  fi
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  stop_remote_job_worker || echo "warning: the fixture's remote job worker did not stop" >&2
  fm_test_cleanup
}
trap cleanup EXIT

# The remote host's code root is this branch's tracked tree plus the fixture
# runtimes, committed so the update below fast-forwards a clean checkout.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
cat > "$REMOTE_ROOT/bin/omp" <<'JS'
#!/usr/bin/env bun
import { appendFileSync, existsSync, readFileSync, readdirSync, renameSync, writeFileSync, mkdirSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";

if (process.argv[2] === "models" && process.argv.includes("--json")) {
  console.log(JSON.stringify({models: [{selector: "test/model", thinking: ["low", "medium", "high", "xhigh"]}]}));
  process.exit(0);
}
if (process.argv.includes("--help") || process.argv.includes("--version") || process.env.OMP_SKIP_SETUP !== "1") {
  console.log(`OMP 17.2.11
--model=<value>
--thinking=<value>
--auto-approve
--extension=<value>
--session-dir=<value>
--resume=<value>
--prewalk native switch
--prewalk-into=<value>
--no-prewalk`);
  process.exit(0);
}

// The modelled mate: every doorbell turn handles its oldest inbox record. A
// persist request is answered on the parent channel with the correlation the
// request carried, after the open work is recorded as written down.
const events = process.env.FM_TEST_OMP_EVENTS;
const inbox = process.env.FM_OMP_TASK_INBOX_DIR;
const { installTaskInboxDoorbell } =
  await import(pathToFileURL(process.env.FM_TEST_OMP_HELPER).href);
const doorbell = installTaskInboxDoorbell(
  {
    sendMessage(message, options) {
      appendFileSync(process.env.FM_TEST_OMP_SENT, `${JSON.stringify({ message, options })}\n`);
      writeFileSync(process.env.FM_OMP_TASK_TURN_STARTED, `${process.pid}\n`);
      const record = readdirSync(inbox).filter((name) => name.endsWith(".msg")).sort()[0];
      if (!record) return;
      const body = readFileSync(`${inbox}/${record}`, "utf8");
      const corr = body.match(/corr=[0-9a-f]{16}/);
      if (corr && body.includes("Open-record persistence")) {
        appendFileSync(events, `persisted ${process.pid} ${corr[0]}\n`);
        appendFileSync(process.env.FM_TEST_OMP_ANSWER_STATUS,
          `done [${corr[0]}]: open records written down\n`);
      } else {
        appendFileSync(events, `handled ${process.pid}\n`);
      }
      renameSync(`${inbox}/${record}`, `${inbox}/handled/${record}`);
    },
  },
  {
    inboxDir: inbox,
    readyMarker: process.env.FM_OMP_TASK_DOORBELL_READY,
  },
);
process.title = `bun ${process.argv[1]}`;
const sessionDir = process.argv[process.argv.indexOf("--session-dir") + 1];
mkdirSync(sessionDir, { recursive: true });
const session = `${sessionDir}/selected.jsonl`;
if (!existsSync(session)) writeFileSync(session, '{"type":"session"}\n');
writeFileSync(process.env.FM_OMP_SESSION_POINTER, `${session}\n`);
// The loaded closure is the one on disk when this session started.
const version = execFileSync("bash", ["-c",
  '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_primary_watch_version "$2/.omp/extensions/fm-primary-omp.ts" "$2"',
  "_", process.env.FM_TEST_OMP_ROOT, process.env.FM_HOME], { encoding: "utf8" }).trim();
writeFileSync(`${process.env.FM_HOME}/state/.omp-primary-extension-loaded`,
  `${version}\n${process.pid}\n${process.env.FM_OMP_BUN}\n${process.env.FM_OMP_BIN}\n`);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
writeFileSync(process.env.FM_TEST_OMP_PID, `${process.pid}\n`);
doorbell.activate();
appendFileSync(events, `started ${process.pid} ${version}\n`);
const retire = () => {
  appendFileSync(events, `stopped ${process.pid}\n`);
  doorbell.retire();
  process.exit(0);
};
process.on("SIGTERM", retire);
process.on("SIGINT", retire);
setInterval(() => {}, 1_000);
JS
chmod +x "$REMOTE_ROOT/bin/omp"
REMOTE_OMP_BIN=$(fm_test_realpath "$REMOTE_ROOT/bin/omp")
REMOTE_OMP_BUN=$(fm_test_realpath "$(command -v node)")
ln -sf "$REMOTE_OMP_BUN" "$REMOTE_ROOT/bin/bun"
cat > "$REMOTE_ROOT/bin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/quota-axi"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$E/herdr-send-fail" "$E/herdr.sock" "$$" "$REMOTE_OMP_BUN" "$REMOTE_OMP_BIN" \
  "$OMP_ACTIVE_PID" "$E/herdr-force-idle" "$E/remote-omp-typed-input" "$E/omp-broken-ack" \
  "$E/execute-omp-launch" "$E/exit-stops"
: > "$E/exit-stops"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" add -A
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
git init -q --bare "$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" remote add origin "file://$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$REMOTE_ORIGIN" symbolic-ref HEAD refs/heads/main

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = remote-mac ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
cd "$FM_FAKE_REMOTE_CWD" || exit 93
command_name=$(perl -MMIME::Base64=decode_base64 -e '
  my @args=split(/\0/, decode_base64($ARGV[0]));
  print $args[0];
' "$4")
# The readiness gate is answered here rather than by the real doctor, which
# would inspect the runner's own account; tests/fm-remote-doctor.test.sh owns it.
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$E/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$E" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

loaded_field() { sed -n "${1}p" "$OMP_HOME/state/.omp-primary-extension-loaded"; }
tracked_version() {
  fm_primary_watch_version "$OMP_HOME/.omp/extensions/fm-primary-omp.ts" "$OMP_HOME"
}
wait_for_listener() { # <previous-pid-or-empty>
  local previous=$1 waited=0 pid=
  while :; do
    [ -s "$OMP_ACTIVE_PID" ] && pid=$(cat "$OMP_ACTIVE_PID")
    if [ -n "$pid" ] && [ "$pid" != "$previous" ] \
      && [ -s "$OMP_HOME/state/parent-route/$ID.omp-doorbell-ready" ]; then
      printf '%s\n' "$pid"
      return 0
    fi
    waited=$((waited + 1))
    [ "$waited" -le 250 ] || return 1
    sleep 0.02
  done
}

printf 'omp test/model low\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
# A live parent watcher keeps the guard banner out of every reported reason.
watcher_identity=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" /bin/bash -c \
  '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
  || fail "could not derive the fixture watcher identity"
mkdir -p "$PARENT/state/.watch.lock"
printf '%s\n' "$$" > "$PARENT/state/.watch.lock/pid"
printf '%s\n' "$watcher_identity" > "$PARENT/state/.watch.lock/pid-identity"
printf '%s\n' "$PARENT" > "$PARENT/state/.watch.lock/fm-home"
printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$PARENT/state/.watch.lock/watcher-path"
touch "$PARENT/state/.last-watcher-beat"
FM_SECONDMATE_CHARTER='Exercise an update across an OMP extension change.' \
  FM_SECONDMATE_SCOPE='remote OMP update and restart' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" "$ID" remote-mac "$REMOTE_ROOT" \
  "$OMP_HOME" --no-projects > "$E/seed.out" 2>&1 \
  || fail "remote OMP route seeding failed: $(cat "$E/seed.out")"
{
  cat <<'SH'
#!/usr/bin/env bash
set -eu
cd "$1"
SH
  printf 'export FM_TEST_OMP_ROOT=%q FM_HOME=%q\n' "$REMOTE_ROOT" "$OMP_HOME"
  printf 'export FM_TEST_OMP_HELPER=%q FM_TEST_OMP_SENT=%q FM_TEST_OMP_PID=%q\n' \
    "$REMOTE_ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$OMP_SENT" "$OMP_ACTIVE_PID"
  printf 'export FM_TEST_OMP_EVENTS=%q FM_TEST_OMP_ANSWER_STATUS=%q\n' \
    "$OMP_EVENTS" "$PARENT/state/$ID.status"
  cat <<'SH'
exec /bin/bash -c "$2"
SH
} > "$E/execute-omp-launch"
chmod +x "$E/execute-omp-launch"
: > "$OMP_EVENTS"
remote_env "$ROOT/bin/fm-spawn.sh" "$ID" --secondmate > "$E/launch.out" 2>&1 \
  || fail "remote OMP secondmate launch failed: $(cat "$E/launch.out") $(cat "$E/execute-omp-launch.out" 2>/dev/null)"
OLD_PID=$(wait_for_listener '') || fail "the remote OMP session never published its doorbell"
[ "$(loaded_field 1)" = "$(tracked_version)" ] \
  || fail "the freshly launched session did not load the tracked closure"
remote_env "$ROOT/bin/fm-send.sh" "fm-$ID" "steer before the update" > "$E/pre-update.out" 2>&1 \
  || fail "a current remote OMP session refused an ordinary request: $(cat "$E/pre-update.out")"

# The update crosses an extension change: origin gains a commit that changes
# the primary closure, and the real update fast-forwards the code root and
# the persistent home to it while the session keeps running the old closure.
OLD_HEAD=$(git -C "$OMP_HOME" rev-parse HEAD)
git clone -q "file://$REMOTE_ORIGIN" "$E/firstmate-dev"
printf '// extension change shipped by the update\n' >> "$E/firstmate-dev/bin/fm-primary-watch-core.ts"
git -C "$E/firstmate-dev" commit -qam 'change the OMP primary extension closure'
git -C "$E/firstmate-dev" push -q origin main
NEW_HEAD=$(git -C "$E/firstmate-dev" rev-parse HEAD)
remote_env "$ROOT/bin/fm-update.sh" > "$E/update.out" 2>&1 \
  || fail "the update failed: $(cat "$E/update.out")"
grep -Fqx "restart-secondmates: fm-$ID" "$E/update.out" \
  || fail "the update did not name the running remote OMP mate for restart:"$'\n'"$(cat "$E/update.out")"
[ "$(git -C "$OMP_HOME" rev-parse HEAD)" = "$NEW_HEAD" ] \
  || fail "the update did not fast-forward the remote home from $OLD_HEAD to $NEW_HEAD"
[ "$(loaded_field 2)" = "$OLD_PID" ] || fail "the update replaced the running session itself"
[ "$(loaded_field 1)" = "$(fm_omp_primary_version_at_commit "$OMP_HOME" "$OLD_HEAD")" ] \
  || fail "the running session's loaded closure is not the pre-update commit's"
[ "$(loaded_field 1)" != "$(tracked_version)" ] \
  || fail "the update did not leave the running session on a superseded closure"

# The superseded session still refuses ordinary requests until it restarts.
records_before=$(find "$OMP_HOME/state/parent-route/$ID.inbox" -name '*.msg' | wc -l | tr -d ' ')
sent_before=$(wc -l < "$OMP_SENT" | tr -d ' ')
post_update_rc=0
remote_env "$ROOT/bin/fm-send.sh" "fm-$ID" "ordinary steer after the update" > "$E/post-update.out" 2>&1 \
  || post_update_rc=$?
expect_code 9 "$post_update_rc" "an ordinary request reached the superseded session: $(cat "$E/post-update.out")"
assert_grep 'loaded OMP primary extension does not match its tracked closure' "$E/post-update.out" \
  "the superseded session's ordinary refusal lost its exact reason"
[ "$(find "$OMP_HOME/state/parent-route/$ID.inbox" -name '*.msg' | wc -l | tr -d ' ')" = "$records_before" ] \
  || fail "the refused ordinary request was enqueued"
[ "$(wc -l < "$OMP_SENT" | tr -d ' ')" = "$sent_before" ] \
  || fail "the refused ordinary request rang the session"
pass "an update across an extension change leaves the running session refusing ordinary requests"

restart_rc=0
remote_env env FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_PERSIST_WAIT=60 \
  "$ROOT/bin/fm-secondmate-restart.sh" "fm-$ID" > "$E/restart.out" 2>&1 || restart_rc=$?
expect_code 0 "$restart_rc" "the restart after the update did not restart the mate:"$'\n'"$(cat "$E/restart.out")"
grep -Fqx "restarted: $ID on remote-mac (omp)" "$E/restart.out" \
  || fail "the restart did not report the remote OMP mate as restarted:"$'\n'"$(cat "$E/restart.out")"
grep -Fqx 'summary: 1 of 1 restarted, 0 nudged, 0 unreached' "$E/restart.out" \
  || fail "the restart summary did not account for one clean reload:"$'\n'"$(cat "$E/restart.out")"
persisted_line=$(grep -n "^persisted $OLD_PID corr=" "$OMP_EVENTS" | head -1 | cut -d: -f1)
stopped_line=$(grep -n "^stopped $OLD_PID\$" "$OMP_EVENTS" | head -1 | cut -d: -f1)
[ -n "$persisted_line" ] || fail "the superseded session never handled the persist request:"$'\n'"$(cat "$OMP_EVENTS")"
[ -n "$stopped_line" ] || fail "the superseded session was never stopped:"$'\n'"$(cat "$OMP_EVENTS")"
[ "$persisted_line" -lt "$stopped_line" ] \
  || fail "the session was stopped before its open work was persisted:"$'\n'"$(cat "$OMP_EVENTS")"
grep -Fqx /exit "$E/remote-omp-typed-input" \
  || fail "the persistence-gated restart never delivered /exit to the superseded session"
NEW_PID=$(wait_for_listener "$OLD_PID") || fail "no replacement session came up after the restart"
[ "$(loaded_field 2)" = "$NEW_PID" ] || fail "the replacement session did not publish its own marker"
[ "$(loaded_field 1)" = "$(tracked_version)" ] \
  || fail "the replacement session did not load the updated closure"
grep -h '^phase=' "$PARENT/state/pending-replies"/* | grep -q '^phase=resolved$' \
  || fail "the persist answer did not settle its parent-owned expectation"
remote_env "$ROOT/bin/fm-send.sh" "fm-$ID" "steer after the restart" > "$E/post-restart.out" 2>&1 \
  || fail "the restarted session refused an ordinary request: $(cat "$E/post-restart.out")"
pass "the restart after the update persists the running session's open work before stopping it"

# A mismatch no recorded update explains is still refused end to end: the
# restart reaches nothing, notifies nothing, and leaves the session running.
printf '%s\n%s\n%s\n%s\n' "$(printf 'foreign extension bytes' | fm_version_hash_stdin)" \
  "$(loaded_field 2)" "$(loaded_field 3)" "$(loaded_field 4)" > "$E/foreign.marker"
mv -f "$E/foreign.marker" "$OMP_HOME/state/.omp-primary-extension-loaded"
records_before=$(find "$OMP_HOME/state/parent-route/$ID.inbox" -name '*.msg' | wc -l | tr -d ' ')
sent_before=$(wc -l < "$OMP_SENT" | tr -d ' ')
typed_before=$(wc -l < "$E/remote-omp-typed-input" | tr -d ' ')
slash_rc=0
remote_env "$ROOT/bin/fm-send.sh" "fm-$ID" /exit > "$E/unexplained-exit.out" 2>&1 \
  || slash_rc=$?
expect_code 9 "$slash_rc" "an unexplained mismatch accepted /exit: $(cat "$E/unexplained-exit.out")"
[ "$(wc -l < "$E/remote-omp-typed-input" | tr -d ' ')" = "$typed_before" ] \
  || fail "the refused /exit notified the remote pane"
kill -0 "$NEW_PID" 2>/dev/null || fail "the refused /exit stopped the running session"
unexplained_rc=0
remote_env env FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_PERSIST_WAIT=60 \
  "$ROOT/bin/fm-secondmate-restart.sh" "fm-$ID" > "$E/unexplained.out" 2>&1 || unexplained_rc=$?
expect_code 3 "$unexplained_rc" "an unexplained mismatch was not left unreached:"$'\n'"$(cat "$E/unexplained.out")"
assert_grep "unreached: $ID: the request to write down its open work could not be delivered: remote-omp-binding-refused: loaded OMP primary extension does not match its tracked closure; no remote notification was sent; do not resend" \
  "$E/unexplained.out" "an unexplained mismatch did not report its exact binding refusal:"$'\n'"$(cat "$E/unexplained.out")"
assert_grep 'summary: 0 of 1 restarted' "$E/unexplained.out" "an unexplained mismatch claimed a reload"
[ "$(find "$OMP_HOME/state/parent-route/$ID.inbox" -name '*.msg' | wc -l | tr -d ' ')" = "$records_before" ] \
  || fail "the unexplained mismatch enqueued a request"
[ "$(wc -l < "$OMP_SENT" | tr -d ' ')" = "$sent_before" ] \
  || fail "the unexplained mismatch rang the session"
kill -0 "$NEW_PID" 2>/dev/null || fail "the unexplained mismatch stopped the running session"
! grep -Fqx "stopped $NEW_PID" "$OMP_EVENTS" || fail "the unexplained mismatch stopped the running session"
pass "a mismatch no recorded update explains is still refused before any notification"
