#!/usr/bin/env bash
# OMP task-inbox doorbell routing, extension behavior, and the bounded
# outcomes fm-send reports for an OMP steer.
# OMP steering never touches the composer: the terminal cannot receipt a
# session that may already be streaming, so these cases drive the public
# fm-send over tmux and Herdr and require exactly one of a native receive
# acknowledgement, a named durable native queue entry, or an explicit refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-task-inbox-doorbell)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
HELPER="$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
SEND="$ROOT/bin/fm-send.sh"

cleanup() {
  [ -z "${LISTENER_PID:-}" ] || kill -TERM "$LISTENER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

test_extension_signal_uses_trigger_turn() {
  local dir="$TMP_ROOT/extension"
  mkdir -p "$dir/state/t1.inbox"
  HELPER="$HELPER" INBOX="$dir/state/t1.inbox" READY="$dir/state/t1.omp-doorbell-ready" \
    node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { FM_TASK_INBOX_DOORBELL_SIGNAL, installTaskInboxDoorbell } =
  await import(pathToFileURL(process.env.HELPER).href);
const sent = [];
const requestDir = `${process.env.READY}.requests`;
const line = `Firstmate instruction waiting: list ${process.env.INBOX}/*.msg and, in numeric order, read and act on each, then mv each handled file to ${process.env.INBOX}/handled/.`;
const doorbell = installTaskInboxDoorbell(
  {
    sendMessage(message, options) {
      assert.equal(readdirSync(requestDir).some((name) => name.endsWith(".pending.ambiguous")), true);
      sent.push({ message, options });
    },
  },
  { inboxDir: process.env.INBOX, readyMarker: process.env.READY },
);
assert.equal(existsSync(process.env.READY), false);
mkdirSync(requestDir, { recursive: true });
writeFileSync(`${requestDir}/preexisting.pending`, line);
writeFileSync(`${requestDir}/stale.pending.processing.${process.pid}`, "");
doorbell.activate();
assert.equal(readFileSync(process.env.READY, "utf8"), `${process.pid}\n`);
assert.equal(sent.length, 1);
assert.equal(existsSync(`${requestDir}/preexisting.pending.delivered`), true);
assert.equal(existsSync(`${requestDir}/stale.pending.ambiguous`), true);
assert.equal(existsSync(`${requestDir}/stale.pending.processing.${process.pid}`), false);
writeFileSync(`${requestDir}/one.pending`, line);
writeFileSync(`${requestDir}/two.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(sent.length, 3);
assert.equal(sent[0].message.customType, "firstmate-task-inbox-doorbell");
assert.equal(sent[0].message.content, line);
assert.deepEqual(sent[1].options, { deliverAs: "steer", triggerTurn: true });
assert.equal(existsSync(`${requestDir}/one.pending.delivered`), true);
assert.equal(existsSync(`${requestDir}/two.pending.delivered`), true);
doorbell.retire();
assert.equal(existsSync(process.env.READY), false);
process.kill(process.pid, FM_TASK_INBOX_DOORBELL_SIGNAL);
await new Promise((resolve) => setImmediate(resolve));

const unavailable = `${process.env.READY}.unavailable`;
const unavailableDoorbell = installTaskInboxDoorbell({}, {
  inboxDir: process.env.INBOX,
  readyMarker: unavailable,
});
unavailableDoorbell.activate();
assert.equal(existsSync(unavailable), false);
unavailableDoorbell.retire();

const failing = `${process.env.READY}.failing`;
const failingApi = { sendMessage() {} };
const failingDoorbell = installTaskInboxDoorbell(
  failingApi,
  { inboxDir: process.env.INBOX, readyMarker: failing },
);
failingDoorbell.activate();
failingApi.sendMessage = undefined;
writeFileSync(`${failing}.requests/one.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(existsSync(`${failing}.requests/one.pending.failed`), true);
assert.equal(existsSync(failing), false);

const uncertain = `${process.env.READY}.uncertain`;
const uncertainDoorbell = installTaskInboxDoorbell(
  { sendMessage() { throw new Error("uncertain"); } },
  { inboxDir: process.env.INBOX, readyMarker: uncertain },
);
uncertainDoorbell.activate();
writeFileSync(`${uncertain}.requests/one.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(existsSync(`${uncertain}.requests/one.pending.ambiguous`), true);
assert.equal(existsSync(`${uncertain}.requests/one.pending.failed`), false);
assert.equal(existsSync(uncertain), false);

const asyncFailure = `${process.env.READY}.async-failure`;
const asyncFailureJournal = `${asyncFailure}.omp-doorbell-failed`;
const asyncFailing = installTaskInboxDoorbell(
  { sendMessage() { return Promise.reject(new Error("async session channel closed")); } },
  { inboxDir: process.env.INBOX, readyMarker: asyncFailure, failureJournal: asyncFailureJournal },
);
asyncFailing.activate();
writeFileSync(`${asyncFailure}.requests/one.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
await new Promise((resolve) => setImmediate(resolve));
assert.equal(existsSync(asyncFailure), false);
assert.match(readFileSync(asyncFailureJournal, "utf8"), /drain: Error: async session channel closed/);

const concurrent = `${process.env.READY}.concurrent`;
const concurrentJournal = `${concurrent}.omp-doorbell-failed`;
mkdirSync(`${concurrent}.requests`, { recursive: true });
writeFileSync(`${concurrent}.requests/first.pending`, line);
let releaseFirst;
let concurrentSends = 0;
const firstSend = new Promise((resolve) => { releaseFirst = resolve; });
const concurrentDoorbell = installTaskInboxDoorbell(
  { sendMessage() {
      concurrentSends += 1;
      if (concurrentSends === 1) return firstSend;
      return Promise.reject(new Error("late concurrent channel closed"));
    } },
  { inboxDir: process.env.INBOX, readyMarker: concurrent, failureJournal: concurrentJournal },
);
const concurrentActivation = concurrentDoorbell.activate();
assert.equal(typeof concurrentActivation.then, "function");
writeFileSync(`${concurrent}.requests/late.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
releaseFirst();
assert.equal(await concurrentActivation, false);
assert.equal(existsSync(concurrent), false);
assert.match(readFileSync(concurrentJournal, "utf8"), /drain: Error: late concurrent channel closed/);

const initialAsyncFailure = `${process.env.READY}.initial-async-failure`;
const initialAsyncJournal = `${initialAsyncFailure}.omp-doorbell-failed`;
mkdirSync(`${initialAsyncFailure}.requests`, { recursive: true });
writeFileSync(`${initialAsyncFailure}.requests/one.pending`, line);
const initialAsync = installTaskInboxDoorbell(
  { sendMessage() { return Promise.reject(new Error("initial async channel closed")); } },
  { inboxDir: process.env.INBOX, readyMarker: initialAsyncFailure, failureJournal: initialAsyncJournal },
);
assert.equal(await initialAsync.activate(), false);
assert.equal(existsSync(initialAsyncFailure), false);
assert.match(readFileSync(initialAsyncJournal, "utf8"), /drain: Error: initial async channel closed/);

const unreadable = `${process.env.READY}.unreadable`;
let unreadableSends = 0;
const unreadableDoorbell = installTaskInboxDoorbell(
  { sendMessage() { unreadableSends += 1; } },
  { inboxDir: process.env.INBOX, readyMarker: unreadable },
);
unreadableDoorbell.activate();
writeFileSync(`${unreadable}.requests/one.pending`, line);
chmodSync(`${unreadable}.requests/one.pending`, 0o000);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(unreadableSends, 0);
assert.equal(existsSync(`${unreadable}.requests/one.pending.failed`), true);
assert.equal(existsSync(unreadable), false);
JS
  pass "OMP extension drains canonical counted requests and safely retires signal readiness"
}

test_extension_requires_turn_proof_or_redrives() {
  local dir="$TMP_ROOT/turn-proof"
  mkdir -p "$dir/state/t1.inbox"
  HELPER="$HELPER" INBOX="$dir/state/t1.inbox" READY="$dir/state/t1.omp-doorbell-ready" \
    node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { FM_TASK_INBOX_DOORBELL_SIGNAL, installTaskInboxDoorbell } =
  await import(pathToFileURL(process.env.HELPER).href);
const requestDir = `${process.env.READY}.requests`;
const line = `Firstmate instruction waiting: list ${process.env.INBOX}/*.msg`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const sent = [];
const userSent = [];
const handlers = new Map();
const api = {
  sendMessage(message, options) { sent.push({ message, options }); },
  sendUserMessage(content) { userSent.push(content); },
  on(event, handler) { handlers.set(event, handler); },
};
const doorbell = installTaskInboxDoorbell(api, {
  inboxDir: process.env.INBOX,
  readyMarker: process.env.READY,
  turnGraceMs: 150,
});
doorbell.activate();
assert.equal(handlers.has("turn_start"), true);

// The downgrade: sendMessage accepts but no turn ever starts. The request must
// NOT be claimed delivered on the call alone.
mkdirSync(requestDir, { recursive: true });
writeFileSync(`${requestDir}/downgraded.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(sent.length, 1);
assert.equal(existsSync(`${requestDir}/downgraded.pending.awaiting-turn`), true);
assert.equal(existsSync(`${requestDir}/downgraded.pending.delivered`), false);

await sleep(500);
assert.equal(userSent.length, 1, "a downgraded triggerTurn must re-drive the instruction as a user prompt");
assert.equal(userSent[0], line);
assert.equal(existsSync(`${requestDir}/downgraded.pending.delivered`), true);

writeFileSync(`${requestDir}/proved.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(sent.length, 2);
assert.equal(existsSync(`${requestDir}/proved.pending.awaiting-turn`), true);
// A turn opening while the steer is parked is proof of delivery: the steer
// caused the turn or was absorbed into it, so the request settles delivered
// and its grace timer is cancelled instead of re-driving the same
// instruction through the user-prompt channel.
handlers.get("turn_start")();
assert.equal(existsSync(`${requestDir}/proved.pending.delivered`), true);
assert.equal(existsSync(`${requestDir}/proved.pending.awaiting-turn`), false);
await sleep(500);
assert.equal(userSent.length, 1, "a proven turn must suppress the user-channel re-drive");

// An open turn at send time is real delivery: the steer joins it.
writeFileSync(`${requestDir}/steered.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(sent.length, 3);
assert.equal(existsSync(`${requestDir}/steered.pending.delivered`), true);
assert.equal(userSent.length, 1);

// A failed re-drive reports failure, not silent stranding.
const failingApi = {
  sendMessage() {},
  sendUserMessage() { throw new Error("no user channel"); },
  on(_e, h) { handlers.set(`f:${_e}`, h); },
};
const failingReady = `${process.env.READY}.failing`;
const failing = installTaskInboxDoorbell(failingApi, {
  inboxDir: process.env.INBOX,
  readyMarker: failingReady,
  turnGraceMs: 150,
});
failing.activate();
mkdirSync(`${failingReady}.requests`, { recursive: true });
writeFileSync(`${failingReady}.requests/stuck.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
await sleep(500);
assert.equal(existsSync(`${failingReady}.requests/stuck.pending.failed`), true);
failing.retire();

// A dead generation's unsettled proof re-queues on activate and re-enters
// delivery immediately: re-sending is the only way to know the runtime's
// deferred queue did not survive with it.
const restartReady = `${process.env.READY}.restart`;
const restartSent = [];
mkdirSync(`${restartReady}.requests`, { recursive: true });
writeFileSync(`${restartReady}.requests/orphaned.pending.awaiting-turn`, line);
const restartDoorbell = installTaskInboxDoorbell(
  { sendMessage(m) { restartSent.push(m); }, sendUserMessage() {}, on() {} },
  { inboxDir: process.env.INBOX, readyMarker: restartReady, turnGraceMs: 60 },
);
restartDoorbell.activate();
assert.equal(restartSent.length, 1, "an unsettled proof must re-enter the delivery path, not sit stranded");
assert.equal(restartSent[0].content, line);
restartDoorbell.retire();
doorbell.retire();
JS
  pass "OMP extension requires turn proof and re-drives a deferred triggerTurn through the user channel"
}

# observeTurns:false keeps the doorbell off the event surface; the embedding
# extension forwards its own correlated turn_start/turn_end through
# notifyTurnStart/notifyTurnEnd. Turn proof and downgrade re-drive still apply.
test_extension_external_notify_drives_turn_proof() {
  local dir="$TMP_ROOT/external-notify"
  mkdir -p "$dir/state/t1.inbox"
  HELPER="$HELPER" INBOX="$dir/state/t1.inbox" READY="$dir/state/t1.omp-doorbell-ready" \
    node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { FM_TASK_INBOX_DOORBELL_SIGNAL, installTaskInboxDoorbell } =
  await import(pathToFileURL(process.env.HELPER).href);
const requestDir = `${process.env.READY}.requests`;
const line = `Firstmate instruction waiting: list ${process.env.INBOX}/*.msg`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const sent = [];
const userSent = [];
const handlers = new Map();
let fireTurnStartDuringSend = false;
const doorbell = installTaskInboxDoorbell(
  {
    sendMessage(message, options) {
      sent.push({ message, options });
      if (fireTurnStartDuringSend) doorbell.notifyTurnStart();
    },
    sendUserMessage(content) { userSent.push(content); },
    on(event, handler) { handlers.set(event, handler); },
  },
  {
    inboxDir: process.env.INBOX,
    readyMarker: process.env.READY,
    observeTurns: false,
    turnGraceMs: 150,
  },
);
doorbell.activate();
assert.equal(handlers.size, 0, "observeTurns:false must not subscribe to the event surface");

mkdirSync(requestDir, { recursive: true });
writeFileSync(`${requestDir}/downgraded.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(sent.length, 1);
assert.equal(existsSync(`${requestDir}/downgraded.pending.awaiting-turn`), true);
assert.equal(existsSync(`${requestDir}/downgraded.pending.delivered`), false);

await sleep(500);
assert.equal(userSent.length, 1, "an unproven steer must re-drive as a user prompt");
assert.equal(userSent[0], line);
assert.equal(existsSync(`${requestDir}/downgraded.pending.delivered`), true);

// A turn_start forwarded inside the dispatch call is the correlated proof.
fireTurnStartDuringSend = true;
writeFileSync(`${requestDir}/proved.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(sent.length, 2);
assert.equal(existsSync(`${requestDir}/proved.pending.delivered`), true);
assert.equal(userSent.length, 1);

// The forwarded turn stays open until notifyTurnEnd: a mid-turn steer joins it
// without its own dispatch proof.
fireTurnStartDuringSend = false;
writeFileSync(`${requestDir}/open.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(sent.length, 3);
assert.equal(existsSync(`${requestDir}/open.pending.delivered`), true);
assert.equal(userSent.length, 1);
doorbell.notifyTurnEnd();

// A stale open flag must not prove the next idle steer: after notifyTurnEnd a
// silent dispatch waits out the grace and re-drives again.
writeFileSync(`${requestDir}/reopened.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(sent.length, 4);
assert.equal(existsSync(`${requestDir}/reopened.pending.awaiting-turn`), true);
await sleep(500);
assert.equal(userSent.length, 2, "a closed turn must not keep proving later steers");
assert.equal(existsSync(`${requestDir}/reopened.pending.delivered`), true);

// A forwarded turn_start that lands after the steer is parked is still
// proof: the content is already in the session, so the parked entry settles
// delivered and never re-drives the same instruction as a user prompt.
writeFileSync(`${requestDir}/async.pending`, line);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(sent.length, 5);
assert.equal(existsSync(`${requestDir}/async.pending.awaiting-turn`), true);
doorbell.notifyTurnStart();
assert.equal(existsSync(`${requestDir}/async.pending.delivered`), true);
await sleep(500);
assert.equal(userSent.length, 2, "an asynchronously proven turn must suppress the re-drive");
doorbell.notifyTurnEnd();
doorbell.retire();
JS
  pass "OMP doorbell driven by external turn notifications proves turns and unlatches on turn_end"
}

# activate() is the handshake contract fm-spawn's generated extension gates
# .omp-ready on: it must report truthfully, journal every failure durably, and
# leave no owned marker behind when the doorbell is not live.
test_extension_activate_reports_and_journals_failures() {
  local dir="$TMP_ROOT/activate-failure"
  mkdir -p "$dir/state/t1.inbox"
  HELPER="$HELPER" INBOX="$dir/state/t1.inbox" READY="$dir/state/t1.omp-doorbell-ready" \
    FAILED="$dir/state/t1.omp-doorbell-failed" \
    node --input-type=module <<'JS'
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { installTaskInboxDoorbell } = await import(pathToFileURL(process.env.HELPER).href);
const requestDir = `${process.env.READY}.requests`;
const line = `Firstmate instruction waiting: list ${process.env.INBOX}/*.msg`;

// An unconfigured doorbell cannot activate and must say so through the journal.
const stub = installTaskInboxDoorbell({}, {
  inboxDir: process.env.INBOX,
  readyMarker: process.env.READY,
  failureJournal: process.env.FAILED,
});
assert.equal(stub.activate(), false, "a doorbell without sendMessage must report failure");
assert.match(readFileSync(process.env.FAILED, "utf8"), /activate: Error: OMP sendMessage is unavailable/);
stub.retire();

// A thrown activation journals the concrete reason and retires cleanly: no
// ready marker survives to claim a handshake that never happened.
writeFileSync(requestDir, "not a directory");
const failing = installTaskInboxDoorbell(
  { sendMessage() {} },
  { inboxDir: process.env.INBOX, readyMarker: process.env.READY,
    failureJournal: process.env.FAILED },
);
assert.equal(failing.activate(), false, "a failed activation must report failure");
assert.equal(existsSync(process.env.READY), false, "a failed activation left its ready marker");
assert.match(readFileSync(process.env.FAILED, "utf8"), /activate: Error: E/);
failing.retire();
assert.equal(existsSync(process.env.READY), false);
rmSync(requestDir);

// A drain-time failure during activation takes the doorbell down with a
// journaled reason instead of leaving a marker for a dead watcher.
mkdirSync(requestDir, { recursive: true });
writeFileSync(`${requestDir}/stuck.pending`, line);
const draining = installTaskInboxDoorbell(
  { sendMessage() { throw new Error("session channel closed"); } },
  { inboxDir: process.env.INBOX, readyMarker: process.env.READY,
    failureJournal: process.env.FAILED },
);
assert.equal(draining.activate(), false, "an activation whose first drain fails must report failure");
assert.equal(existsSync(process.env.READY), false, "a drain failure left the ready marker");
assert.match(readFileSync(process.env.FAILED, "utf8"), /drain: Error: session channel closed/);
draining.retire();

// A recovered activation clears a stale journal so the marker alone is truth.
writeFileSync(process.env.FAILED, "stale reason\n");
const recovered = installTaskInboxDoorbell(
  { sendMessage() {} },
  { inboxDir: process.env.INBOX, readyMarker: process.env.READY,
    failureJournal: process.env.FAILED },
);
assert.equal(recovered.activate(), true);
assert.equal(readFileSync(process.env.READY, "utf8"), `${process.pid}\n`);
assert.equal(existsSync(process.env.FAILED), false,
  "a live doorbell must clear the stale failure journal");
recovered.retire();
assert.equal(existsSync(process.env.READY), false);

const derivedReady = `${process.env.READY}.derived`;
const derivedJournal = `${derivedReady}.omp-doorbell-failed`;
writeFileSync(`${derivedReady}.requests`, "not a directory");
const derived = installTaskInboxDoorbell(
  { sendMessage() {} },
  { inboxDir: process.env.INBOX, readyMarker: derivedReady },
);
assert.equal(derived.activate(), false);
assert.match(readFileSync(derivedJournal, "utf8"), /activate: Error: E/);
derived.retire();
rmSync(`${derivedReady}.requests`);

const primaryState = `${process.env.INBOX}.primary-state`;
mkdirSync(primaryState, { recursive: true });
const previousState = process.env.FM_STATE_OVERRIDE;
process.env.FM_STATE_OVERRIDE = primaryState;
const primary = installTaskInboxDoorbell({}, {});
assert.equal(primary.activate(), false);
assert.match(readFileSync(`${primaryState}/.omp-doorbell-failed.${process.pid}`, "utf8"), /activate: Error:/);
if (previousState === undefined) delete process.env.FM_STATE_OVERRIDE;
else process.env.FM_STATE_OVERRIDE = previousState;
JS
  pass "OMP extension activation reports failures, journals their reasons, and retires cleanly"
}

test_ring_routing_matrix() {
  local dir="$TMP_ROOT/routing" rec log
  mkdir -p "$dir/state/t1.inbox/handled"
  rec="$dir/state/t1.inbox/001.msg"
  printf 'schema=fm-task-inbox.v1\nat=2026-08-29T00:00:00Z\n--\nwork\n' > "$rec"
  log="$dir/calls.log"

  ROOT="$ROOT" REC="$rec" LOG="$log" bash <<'SH'
set -u
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_backend_omp_trigger_turn() {
  printf 'programmatic:%s:%s\n' "$1" "$2" >> "$LOG"
  [ "${PROGRAMMATIC_AVAILABLE:-0}" = 1 ]
}
fm_backend_composer_state() {
  printf 'composer-state:%s\n' "$1" >> "$LOG"
  printf 'empty'
}
fm_backend_send_text_submit() {
  printf 'composer-submit:%s:%s\n' "$1" "$2" >> "$LOG"
  printf 'empty'
}

: > "$LOG"
PROGRAMMATIC_AVAILABLE=1 fm_task_inbox_ring tmux target "$REC" fm-t1 omp /runtime/omp /bin/omp
[ "$(grep -c '^programmatic:' "$LOG")" = 1 ]
! grep -q '^composer-' "$LOG"

: > "$LOG"
PROGRAMMATIC_AVAILABLE=1 fm_task_inbox_ring herdr target "$REC" fm-t1 omp /runtime/omp /bin/omp
[ "$(grep -c '^programmatic:' "$LOG")" = 1 ]
! grep -q '^composer-' "$LOG"

: > "$LOG"
set +e
PROGRAMMATIC_AVAILABLE=0 fm_task_inbox_ring herdr target "$REC" fm-t1 omp /runtime/omp /bin/omp
rc=$?
set -e
[ "$rc" = 3 ]
[ "$(grep -c '^programmatic:' "$LOG")" = 1 ]
! grep -q '^composer-' "$LOG"

: > "$LOG"
set +e
PROGRAMMATIC_AVAILABLE=0 fm_task_inbox_ring tmux target "$REC" fm-t1 omp /runtime/omp /bin/omp
rc=$?
set -e
[ "$rc" = 3 ]
! grep -q '^composer-' "$LOG"

: > "$LOG"
fm_backend_omp_trigger_turn() {
  printf 'programmatic-indeterminate\n' >> "$LOG"
  return 2
}
set +e
fm_task_inbox_ring herdr target "$REC" fm-t1 omp /runtime/omp /bin/omp
rc=$?
set -e
[ "$rc" = 4 ]
[ "$(grep -c '^programmatic-indeterminate' "$LOG")" = 1 ]
! grep -q '^composer-' "$LOG"

: > "$LOG"
set +e
fm_task_inbox_ring tmux target "$REC" fm-t1 omp /runtime/omp /bin/omp
rc=$?
set -e
[ "$rc" = 4 ]
! grep -q '^composer-' "$LOG"

: > "$LOG"
PROGRAMMATIC_AVAILABLE=1 fm_task_inbox_ring tmux target "$REC" fm-t1 claude
! grep -q '^programmatic:' "$LOG"
[ "$(grep -c '^composer-submit:' "$LOG")" = 1 ]
SH
  expect_code 0 "$?" "OMP/non-OMP doorbell routing matrix"
  pass "doorbell routing keeps OMP on its native adapter and preserves the non-OMP composer branch"
}

test_request_terminal_states() {
  local dir="$TMP_ROOT/request-states"
  mkdir -p "$dir/ready.requests"
  ROOT="$ROOT" MARKER="$dir/ready" bash <<'SH'
set -u
. "$ROOT/bin/fm-backend.sh"
request_dir="${MARKER}.requests"

printf '4242\n' > "$MARKER"
kill() {
  case "$1:$2" in
    -0:2147483647) return 1 ;;
    *) return 0 ;;
  esac
}
FM_OMP_TASK_DOORBELL_ACK_ATTEMPTS=1 \
  fm_omp_task_doorbell_request "$MARKER" 4242 timeout.msg 'canonical doorbell'
[ "$?" = 2 ]
[ -f "$request_dir/request.timeout.msg.pending" ]
[ "$(cat "$request_dir/request.timeout.msg.pending")" = 'canonical doorbell' ]

rm -f "$MARKER"
set +e
fm_omp_task_doorbell_request_existing "$MARKER" timeout.msg
rc=$?
set -e
[ "$rc" = 4 ]
[ -e "$request_dir/request.timeout.msg.pending" ]
rm -f "$request_dir/request.timeout.msg.pending"

printf '4242\n' > "$MARKER"
: > "$request_dir/request.revalidate.msg.pending"
validated="$request_dir/validated"
fm_backend_source() { return 0; }
fm_backend_tmux_omp_trigger_turn() {
  : > "$validated"
  return 1
}
set +e
fm_backend_omp_trigger_turn tmux target "$MARKER" /runtime/omp /bin/omp revalidate.msg 'canonical doorbell'
rc=$?
set -e
[ "$rc" = 1 ]
[ -f "$validated" ]
rm -f "$request_dir/request.revalidate.msg.pending"

: > "$request_dir/request.claimed.msg.pending.processing.4242"
set +e
fm_omp_task_doorbell_request_existing "$MARKER" claimed.msg
rc=$?
set -e
[ "$rc" = 2 ]
[ -f "$request_dir/request.claimed.msg.pending.processing.4242" ]

: > "$request_dir/request.ambiguous.msg.pending.ambiguous"
set +e
fm_omp_task_doorbell_request_existing "$MARKER" ambiguous.msg
rc=$?
set -e
[ "$rc" = 2 ]
set +e
fm_omp_task_doorbell_request_existing "$MARKER" ambiguous.msg
rc=$?
set -e
[ "$rc" = 2 ]
[ -f "$request_dir/request.ambiguous.msg.pending.ambiguous" ]
[ ! -e "$request_dir/request.ambiguous.msg.pending" ]

: > "$request_dir/request.failed.msg.pending.failed"
set +e
fm_omp_task_doorbell_request_existing "$MARKER" failed.msg
rc=$?
set -e
[ "$rc" = 1 ]
[ ! -e "$request_dir/request.failed.msg.pending.failed" ]

# A delivered receipt retires into a durable .acked tombstone on first read
# and every later probe for the same record still reports delivered, so a
# re-ring can never treat the consumed receipt as never-sent.
: > "$request_dir/request.delivered.msg.pending.delivered"
set +e
fm_omp_task_doorbell_request_existing "$MARKER" delivered.msg
rc=$?
set -e
[ "$rc" = 0 ]
[ ! -e "$request_dir/request.delivered.msg.pending.delivered" ]
[ -f "$request_dir/request.delivered.msg.pending.acked" ]
set +e
fm_omp_task_doorbell_request_existing "$MARKER" delivered.msg
rc=$?
set -e
[ "$rc" = 5 ]
[ -f "$request_dir/request.delivered.msg.pending.acked" ]
fm_backend_tmux_omp_trigger_turn() { return 99; }
set +e
fm_backend_omp_trigger_turn tmux target "$MARKER" /runtime/omp /bin/omp delivered.msg 'canonical doorbell'
rc=$?
set -e
[ "$rc" = 0 ]
SH
  expect_code 0 "$?" "OMP request terminal-state boundary"
  pass "OMP pending retries revalidate identity while ambiguous claims suppress resend"
}

make_send_stubs() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_pid*) printf '4242\n' ;;
      *) printf 'fakepane\n' ;;
    esac
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$FM_FAKE_COMPOSER_LOG"
    ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    ;;
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
esac
SH
  chmod +x "$fb/tmux"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'-o tpgid= -p 4242'*) printf '%s\n' "$FM_FAKE_OMP_PID" ;;
  *'-o comm='*) printf 'node\n' ;;
  *'-o args='*) printf '%s --input-type=module\n' "$FM_FAKE_NODE" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/ps"
}

test_fm_send_rings_one_programmatic_doorbell() {
  local dir="$TMP_ROOT/send" home="$TMP_ROOT/send/home" listener_ready signal_log composer_log node_bin
  mkdir -p "$home/state"
  make_send_stubs "$dir"
  listener_ready="$dir/listener.ready"
  signal_log="$dir/signals.log"
  composer_log="$dir/composer.log"
  : > "$signal_log"
  : > "$composer_log"
  node_bin=$(realpath "$(command -v node)")

  HELPER="$HELPER" INBOX="$home/state/t1.inbox" READY="$home/state/t1.omp-doorbell-ready" \
    SIGNAL_LOG="$signal_log" LISTENER_READY="$listener_ready" node --input-type=module <<'JS' &
import { appendFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { installTaskInboxDoorbell } = await import(pathToFileURL(process.env.HELPER).href);
const doorbell = installTaskInboxDoorbell(
  { sendMessage(_message, options) { appendFileSync(process.env.SIGNAL_LOG, `${JSON.stringify(options)}\n`); } },
  { inboxDir: process.env.INBOX, readyMarker: process.env.READY },
);
doorbell.activate();
writeFileSync(process.env.LISTENER_READY, `${process.pid}\n`);
setInterval(() => {}, 1000);
JS
  LISTENER_PID=$!
  for _ in $(seq 1 100); do
    [ -f "$listener_ready" ] && break
    /bin/sleep 0.01
  done
  [ -f "$listener_ready" ] || fail "signal listener did not start"
  fm_write_meta "$home/state/t1.meta" \
    "window=sess:fm-t1" "endpoint_task_id=t1" "worktree=$dir/worktree" \
    "project=$dir/project" "harness=omp" "kind=ship" "mode=no-mistakes" \
    "yolo=off" "tasktmp=/tmp/fm-t1" "omp_bin=$node_bin" "omp_bun=$node_bin"

  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_OMP_PID="$LISTENER_PID" FM_FAKE_NODE="$node_bin" \
    FM_FAKE_COMPOSER_LOG="$composer_log" FM_SEND_SETTLE=0 \
    "$SEND" t1 "apply the queued review finding" >/dev/null 2>"$dir/send.err" \
    || fail "OMP inbox send failed: $(cat "$dir/send.err")"
  for _ in $(seq 1 100); do
    [ "$(wc -l < "$signal_log" | tr -d '[:space:]')" = 1 ] && break
    /bin/sleep 0.01
  done
  [ "$(wc -l < "$signal_log" | tr -d '[:space:]')" = 1 ] \
    || fail "one enqueue did not produce exactly one programmatic signal"
  [ ! -s "$composer_log" ] || fail "successful programmatic wake touched the composer: $(cat "$composer_log")"
  [ -f "$home/state/t1.inbox/001.msg" ] || fail "programmatic wake lost the durable inbox record"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" MARKER="$home/state/t1.omp-doorbell-ready" \
    OMP_PID="$LISTENER_PID" OMP_BIN="$node_bin" bash <<'SH'
set -u
. "$FM_ROOT_OVERRIDE/bin/fm-backend.sh"
fm_backend_source herdr
fm_backend_herdr_cli() {
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","foreground_process_group_id":%s}}}\n' "$OMP_PID"
}
fm_backend_herdr_omp_trigger_turn default:w1:p2 "$MARKER" "$OMP_BIN" "$OMP_BIN" manual.msg 'canonical doorbell'
SH
  expect_code 0 "$?" "Herdr OMP programmatic trigger adapter"
  for _ in $(seq 1 100); do
    [ "$(wc -l < "$signal_log" | tr -d '[:space:]')" = 2 ] && break
    /bin/sleep 0.01
  done
  [ "$(wc -l < "$signal_log" | tr -d '[:space:]')" = 2 ] \
    || fail "Herdr adapter did not signal the task-bound OMP process exactly once"
  kill -TERM "$LISTENER_PID" 2>/dev/null || true
  wait "$LISTENER_PID" 2>/dev/null || true
  LISTENER_PID=
  pass "fm-send and both tmux/Herdr adapters preserve task-bound OMP programmatic doorbells"
}

# A live task-bound extension for <task>, plus the fake tmux/herdr/ps binaries
# fm-send resolves it through. Echoes the listener PID.
start_native_listener() {  # <dir> <home> <task> <signal-log> <ready-flag>
  local dir=$1 home=$2 task=$3 signal_log=$4 ready=$5 pid
  HELPER="$HELPER" INBOX="$home/state/$task.inbox" READY="$home/state/$task.omp-doorbell-ready" \
    SIGNAL_LOG="$signal_log" LISTENER_READY="$ready" node --input-type=module \
    > "$dir/native-listener.log" 2>&1 <<'JS' &
import { appendFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { installTaskInboxDoorbell } = await import(pathToFileURL(process.env.HELPER).href);
const doorbell = installTaskInboxDoorbell(
  {
    sendMessage(message, options) {
      appendFileSync(process.env.SIGNAL_LOG, `${JSON.stringify({ content: message.content, options })}\n`);
    },
  },
  { inboxDir: process.env.INBOX, readyMarker: process.env.READY },
);
doorbell.activate();
writeFileSync(process.env.LISTENER_READY, `${process.pid}\n`);
setInterval(() => {}, 1000);
JS
  pid=$!
  for _ in $(seq 1 200); do
    [ -f "$ready" ] && break
    /bin/sleep 0.01
  done
  [ -f "$ready" ] || fail "task-bound extension for $task did not start"
  printf '%s' "$pid"
}

# A node process that stays alive and deliberately never acknowledges a
# doorbell request, so the native request stays queued without a receipt.
start_silent_listener() {  # <ready-flag>
  local ready=$1 pid
  LISTENER_READY="$ready" node --input-type=module > "${ready}.log" 2>&1 <<'JS' &
import { writeFileSync } from "node:fs";
process.on("SIGUSR2", () => {});
writeFileSync(process.env.LISTENER_READY, `${process.pid}\n`);
setInterval(() => {}, 1000);
JS
  pid=$!
  for _ in $(seq 1 200); do
    [ -f "$ready" ] && break
    /bin/sleep 0.01
  done
  [ -f "$ready" ] || fail "silent OMP process did not start"
  printf '%s' "$pid"
}

# A live task-bound extension whose runtime accepts the steer but never opens
# a turn for it, so each request parks awaiting-turn until the turn-grace
# re-drive lands it through the user-prompt channel. Echoes the listener PID.
start_redriving_listener() {  # <dir> <home> <task> <signal-log> <ready-flag> <grace-ms>
  local dir=$1 home=$2 task=$3 signal_log=$4 ready=$5 grace=$6 pid
  HELPER="$HELPER" INBOX="$home/state/$task.inbox" READY="$home/state/$task.omp-doorbell-ready" \
    SIGNAL_LOG="$signal_log" LISTENER_READY="$ready" \
    FM_OMP_DOORBELL_TURN_GRACE_MS="$grace" node --input-type=module \
    > "$dir/redrive-listener.log" 2>&1 <<'JS' &
import { appendFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { installTaskInboxDoorbell } = await import(pathToFileURL(process.env.HELPER).href);
const doorbell = installTaskInboxDoorbell(
  {
    sendMessage() { appendFileSync(process.env.SIGNAL_LOG, "sendMessage\n"); },
    sendUserMessage() { appendFileSync(process.env.SIGNAL_LOG, "sendUserMessage\n"); },
    on() {},
  },
  { inboxDir: process.env.INBOX, readyMarker: process.env.READY },
);
doorbell.activate();
writeFileSync(process.env.LISTENER_READY, `${process.pid}\n`);
setInterval(() => {}, 1000);
JS
  pid=$!
  for _ in $(seq 1 200); do
    [ -f "$ready" ] && break
    /bin/sleep 0.01
  done
  [ -f "$ready" ] || fail "redriving task-bound extension for $task did not start"
  printf '%s' "$pid"
}

make_herdr_send_stub() {  # <dir>
  cat > "$1/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  'status --json') printf '%s\n' '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}' ;;
  'pane process-info')
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","foreground_process_group_id":%s}}}\n' \
      "$FM_FAKE_OMP_PID"
    ;;
  'pane send-text'|'pane send-keys') printf '%s\n' "$*" >> "$FM_FAKE_COMPOSER_LOG" ;;
  'pane get') printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' ;;
esac
SH
  chmod +x "$1/fakebin/herdr"
}

write_native_meta() {  # <home> <task> <backend> <node-bin>
  local home=$1 task=$2 backend=$3 node_bin=$4
  case "$backend" in
    tmux)
      fm_write_meta "$home/state/$task.meta" \
        "window=sess:fm-$task" "endpoint_task_id=$task" "harness=omp" "kind=ship" \
        "omp_bin=$node_bin" "omp_bun=$node_bin"
      ;;
    herdr)
      fm_write_meta "$home/state/$task.meta" \
        "window=fm-lab:w1:p1" "endpoint_task_id=$task" "backend=herdr" "harness=omp" \
        "kind=ship" "herdr_session=fm-lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t1" \
        "herdr_pane_id=w1:p1" "omp_bin=$node_bin" "omp_bun=$node_bin"
      ;;
  esac
}

record_body_of() {  # <record-path>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

run_native_send() {  # <dir> <home> <omp-pid> <node-bin> <out> <err> <fm-send args...>
  local dir=$1 home=$2 omp_pid=$3 node_bin=$4 out=$5 err=$6
  shift 6
  env PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_OMP_PID="$omp_pid" FM_FAKE_NODE="$node_bin" \
    FM_FAKE_COMPOSER_LOG="$dir/composer.log" FM_SEND_SETTLE=0 \
    FM_SEND_RECONCILE_AUTH="${FM_SEND_RECONCILE_AUTH:-0}" \
    FM_OMP_TASK_DOORBELL_ACK_ATTEMPTS="${FM_OMP_TASK_DOORBELL_ACK_ATTEMPTS:-200}" \
    "$SEND" "$@" >"$out" 2>"$err"
}

# AC1/AC3: over tmux and Herdr an ordinary OMP steer reaches the worker through
# the task-bound native adapter alone, and the reported outcome names the exact
# session and message rather than anything rendered in a composer.
test_omp_native_receive_reports_exact_binding() {
  local backend dir home node_bin listener_pid signal_log out err rec body request
  node_bin=$(realpath "$(command -v node)")
  for backend in tmux herdr; do
    dir="$TMP_ROOT/native-$backend"
    home="$dir/home"
    mkdir -p "$home/state"
    make_send_stubs "$dir"
    make_herdr_send_stub "$dir"
    signal_log="$dir/signals.log"
    : > "$signal_log"
    : > "$dir/composer.log"
    listener_pid=$(start_native_listener "$dir" "$home" native "$signal_log" "$dir/listener.ready")
    LISTENER_PID=$listener_pid
    write_native_meta "$home" native "$backend" "$node_bin"
    out="$dir/out"; err="$dir/err"
    run_native_send "$dir" "$home" "$listener_pid" "$node_bin" "$out" "$err" \
      native "rebase onto main and rerun the suite" \
      || fail "$backend OMP native steer failed: $(cat "$err")"

    rec="$home/state/native.inbox/001.msg"
    request="$home/state/native.omp-doorbell-ready.requests/request.001.msg"
    assert_contains "$(cat "$out")" 'omp-native-received:' \
      "$backend OMP steer did not report a native receive acknowledgement"
    [ "$(cat "$out" "$err" | grep -Ec 'omp-native-(received|queued|refused):' || true)" = 1 ] \
      || fail "$backend OMP steer reported more than one bounded outcome"
    assert_contains "$(cat "$out")" "task=native" "$backend outcome did not bind the exact task"
    assert_contains "$(cat "$out")" "session-pid=$listener_pid" \
      "$backend outcome did not bind the exact OMP session process"
    assert_contains "$(cat "$out")" "request=$request" \
      "$backend outcome did not name the native queue entry"
    assert_contains "$(cat "$out")" "record=$rec" "$backend outcome did not bind the exact message record"
    assert_contains "$(cat "$out")" 'message-bytes=36' "$backend outcome did not report the exact message size"
    [ ! -s "$dir/composer.log" ] \
      || fail "$backend OMP native steer touched the composer: $(cat "$dir/composer.log")"
    body=$(record_body_of "$rec")
    [ "$body" = "rebase onto main and rerun the suite" ] \
      || fail "$backend OMP steer did not preserve the exact message: $body"
    for _ in $(seq 1 200); do
      [ "$(wc -l < "$signal_log" | tr -d '[:space:]')" = 1 ] && break
      /bin/sleep 0.01
    done
    assert_contains "$(cat "$signal_log")" "$home/state/native.inbox" \
      "$backend native session event did not carry this task's own instruction"
    assert_contains "$(cat "$signal_log")" '"triggerTurn":true' \
      "$backend native delivery did not trigger a bound turn"
    kill -TERM "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
    LISTENER_PID=
  done
  pass "fm-send: an OMP steer is received natively over tmux and Herdr with no composer transport"
}

# AC2/AC6: a crewless or non-listening OMP mate still yields exactly one bounded
# outcome. AC4: nothing appends /exit to resolve it, and an explicit /exit stays
# an independent typed operation.
test_omp_native_refusal_and_queue_are_bounded() {
  local dir home node_bin out err rc silent_pid request handled
  node_bin=$(realpath "$(command -v node)")
  dir="$TMP_ROOT/native-refused"
  home="$dir/home"
  mkdir -p "$home/state"
  make_send_stubs "$dir"
  : > "$dir/composer.log"
  write_native_meta "$home" idle tmux "$node_bin"
  out="$dir/out"; err="$dir/err"
  run_native_send "$dir" "$home" 4242 "$node_bin" "$out" "$err" \
    idle "look at the failing lint job"; rc=$?
  expect_code 6 "$rc" "a steer to an OMP mate with no live receive adapter must not exit 0"
  assert_contains "$(cat "$err")" 'omp-native-refused:' \
    "the unreachable OMP adapter did not produce an explicit refusal"
  [ "$(cat "$out" "$err" | grep -Ec 'omp-native-(received|queued|refused):' || true)" = 1 ] \
    || fail "the refused OMP steer reported more than one bounded outcome"
  assert_contains "$(cat "$err")" 'do not resend' "the refusal invited a resend"
  assert_contains "$(cat "$err")" "record=$home/state/idle.inbox/001.msg" \
    "the refusal did not name the durable record holding the exact message"
  # The refusal names the concrete artifact explaining it, not just
  # session-pid=unreadable: the handshake marker that never appeared.
  assert_contains "$(cat "$err")" "doorbell-marker-missing=$home/state/idle.omp-doorbell-ready" \
    "the refusal did not name the missing doorbell marker"
  [ -f "$home/state/idle.inbox/001.msg" ] || fail "the refused steer lost its durable record"
  [ ! -s "$dir/composer.log" ] \
    || fail "a refused OMP steer typed into the composer: $(cat "$dir/composer.log")"

  dir="$TMP_ROOT/native-doorbell-failed"
  home="$dir/home"
  mkdir -p "$home/state"
  make_send_stubs "$dir"
  : > "$dir/composer.log"
  write_native_meta "$home" doomed tmux "$node_bin"
  printf '2026-09-01T00:00:00.000Z activate: Error: request directory creation failed\n' \
    > "$home/state/doomed.omp-doorbell-failed"
  out="$dir/out"; err="$dir/err"
  run_native_send "$dir" "$home" 4242 "$node_bin" "$out" "$err" \
    doomed "apply the queued fix"; rc=$?
  expect_code 6 "$rc" "a steer to an OMP mate with a journaled doorbell failure must refuse"
  assert_contains "$(cat "$err")" 'omp-native-refused:' \
    "the journaled doorbell failure did not produce an explicit refusal"
  assert_contains "$(cat "$err")" "doorbell-failure=$home/state/doomed.omp-doorbell-failed" \
    "the refusal did not name the doorbell failure journal"

  dir="$TMP_ROOT/native-missing-request-dir"
  home="$dir/home"
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/raced.omp-doorbell-ready"
  state=$(bash -c '. "$1"; fm_task_inbox_omp_doorbell_state "$2"' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state/raced.omp-doorbell-ready")
  [ "$state" = "doorbell-request-dir-missing=$home/state/raced.omp-doorbell-ready.requests" ] \
    || fail "missing OMP request directory was misdiagnosed: $state"

  dir="$TMP_ROOT/native-handled"
  home="$dir/home"
  mkdir -p "$home/state"
  make_send_stubs "$dir"
  : > "$dir/composer.log"
  write_native_meta "$home" replay tmux "$node_bin"
  handled=$(bash -c '. "$1"; fm_task_inbox_write "$2" replay "replay this exact steer" replay-id' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state")
  mkdir -p "${handled%/*}/handled"
  mv "$handled" "${handled%/*}/handled/${handled##*/}"
  out="$dir/out"; err="$dir/err"
  FM_SEND_RECONCILE_AUTH=1 run_native_send "$dir" "$home" 4242 "$node_bin" "$out" "$err" \
    replay --reconcile-delivery replay-id "replay this exact steer" || fail "handled OMP reconciliation replay failed: $(cat "$err")"
  assert_contains "$(cat "$out")" 'omp-native-received:' \
    "handled OMP reconciliation replay did not report its receipt"
  assert_contains "$(cat "$out")" 'receipt source' \
    "handled OMP reconciliation replay did not identify its receipt source"
  assert_contains "$(cat "$out")" 'request=none' \
    "handled OMP reconciliation replay unexpectedly named a native request"
  assert_contains "$(cat "$out")" 'session-pid=not-a-session-receipt' \
    "handled OMP reconciliation replay named an unknown session"
  assert_contains "$(cat "$out")" "record=$home/state/replay.inbox/handled/001.msg" \
    "handled OMP reconciliation replay did not name its handled record"
  [ "$(cat "$out" "$err" | grep -Ec 'omp-native-(received|queued|refused):' || true)" = 1 ] \
    || fail "handled OMP reconciliation replay reported more than one bounded outcome"
  [ "$(find "$home/state/replay.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d '[:space:]')" = 0 ] \
    || fail "handled OMP reconciliation replay enqueued a second record"
  [ ! -s "$dir/composer.log" ] \
    || fail "handled OMP reconciliation replay touched the composer: $(cat "$dir/composer.log")"

  dir="$TMP_ROOT/native-delivered"
  home="$dir/home"
  mkdir -p "$home/state"
  make_send_stubs "$dir"
  : > "$dir/composer.log"
  silent_pid=$(start_silent_listener "$dir/delivered.ready")
  LISTENER_PID=$silent_pid
  write_native_meta "$home" delivered tmux "$node_bin"
  handled=$(bash -c '. "$1"; fm_task_inbox_write "$2" delivered "replay this delivered steer" delivered-id' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$home/state")
  mkdir -p "$home/state/delivered.omp-doorbell-ready.requests"
  printf '%s\n' "$silent_pid" > "$home/state/delivered.omp-doorbell-ready"
  : > "$home/state/delivered.omp-doorbell-ready.requests/request.001.msg.pending.delivered"
  out="$dir/out"; err="$dir/err"
  set +e
  FM_SEND_RECONCILE_AUTH=1 run_native_send "$dir" "$home" "$silent_pid" "$node_bin" "$out" "$err" \
    delivered --reconcile-delivery delivered-id "replay this delivered steer"
  rc=$?
  set -e
  expect_code 6 "$rc" "delivered OMP reconciliation replay without historical binding must refuse"
  assert_contains "$(cat "$err")" 'omp-native-refused:' \
    "unbound delivered OMP reconciliation replay did not report refusal"
  assert_contains "$(cat "$err")" 'session-pid=unreadable' \
    "unbound delivered OMP reconciliation replay did not keep its session unproven"
  [ -f "$home/state/delivered.omp-doorbell-ready.requests/request.001.msg.pending.acked" ] \
    || fail "the consumed delivery receipt did not leave a durable suppression tombstone"
  assert_contains "$(cat "$err")" "doorbell-binding-unproven=$home/state/delivered.omp-doorbell-ready" \
    "the refusal did not name the readable marker whose binding stayed unproven"
  kill -TERM "$silent_pid" 2>/dev/null || true
  wait "$silent_pid" 2>/dev/null || true
  LISTENER_PID=

  # AC4: nothing appended /exit to resolve the unconfirmed steer, and an
  # explicit /exit stays its own typed operation instead of becoming a second
  # durable steer behind the first one.
  assert_not_contains "$(cat "$dir/composer.log")" '/exit' \
    "an unresolved steer appended /exit as a workaround"
  run_native_send "$dir" "$home" 4242 "$node_bin" "$out" "$err" idle /exit || true
  assert_absent "$home/state/idle.inbox/002.msg" \
    "an explicit /exit was converted into a durable steer instead of staying independent"

  dir="$TMP_ROOT/native-queued"
  home="$dir/home"
  mkdir -p "$home/state"
  make_send_stubs "$dir"
  : > "$dir/composer.log"
  silent_pid=$(start_silent_listener "$dir/silent.ready")
  LISTENER_PID=$silent_pid
  write_native_meta "$home" quiet tmux "$node_bin"
  printf '%s\n' "$silent_pid" > "$home/state/quiet.omp-doorbell-ready"
  mkdir -p "$home/state/quiet.omp-doorbell-ready.requests"
  out="$dir/out"; err="$dir/err"
  set +e
  FM_OMP_TASK_DOORBELL_ACK_ATTEMPTS=1 \
    run_native_send "$dir" "$home" "$silent_pid" "$node_bin" "$out" "$err" \
    quiet "pick up the review findings"; rc=$?
  set -e
  expect_code 7 "$rc" "an unacknowledged native request must not exit 0"
  request="$home/state/quiet.omp-doorbell-ready.requests/request.001.msg"
  assert_contains "$(cat "$err")" 'omp-native-queued:' \
    "the unacknowledged request did not report a durable native queue outcome"
  [ "$(cat "$out" "$err" | grep -Ec 'omp-native-(received|queued|refused):' || true)" = 1 ] \
    || fail "the queued OMP steer reported more than one bounded outcome"
  assert_contains "$(cat "$err")" "request=$request" \
    "the queued outcome did not name its durable native queue identity"
  assert_contains "$(cat "$err")" 'do not resend' "the queued outcome invited a resend"
  [ -f "$request.pending" ] || fail "the named native queue entry is not durable at $request.pending"
  [ ! -s "$dir/composer.log" ] \
    || fail "a queued OMP steer typed into the composer: $(cat "$dir/composer.log")"
  kill -TERM "$silent_pid" 2>/dev/null || true
  wait "$silent_pid" 2>/dev/null || true
  LISTENER_PID=
  pass "fm-send: refused and unacknowledged OMP steers stay bounded, durable and non-resend-inviting"
}

# AC3: a binding that does not prove the exact task-bound session is refused
# rather than delivered somewhere else.
test_omp_native_binding_mismatch_is_refused() {
  local dir home node_bin listener_pid out err rc
  node_bin=$(realpath "$(command -v node)")
  dir="$TMP_ROOT/native-binding"
  home="$dir/home"
  mkdir -p "$home/state"
  make_send_stubs "$dir"
  : > "$dir/composer.log"
  listener_pid=$(start_native_listener "$dir" "$home" bound "$dir/signals.log" "$dir/listener.ready")
  LISTENER_PID=$listener_pid
  write_native_meta "$home" bound tmux "$node_bin"
  out="$dir/out"; err="$dir/err"
  # The pane's foreground process is not the process that published the
  # task-bound readiness marker.
  set +e
  run_native_send "$dir" "$home" "$((listener_pid + 1))" "$node_bin" "$out" "$err" \
    bound "apply the accepted fix"; rc=$?
  set -e
  expect_code 6 "$rc" "an unproven session binding must exit nonzero"
  assert_contains "$(cat "$err")" 'omp-native-refused:' \
    "an unproven session binding was not explicitly refused"
  assert_contains "$(cat "$err")" "doorbell-binding-unproven=$home/state/bound.omp-doorbell-ready" \
    "the refusal did not name the marker whose session binding stayed unproven"
  [ ! -s "$dir/composer.log" ] \
    || fail "a refused binding fell back to the composer: $(cat "$dir/composer.log")"
  [ ! -s "$dir/signals.log" ] || fail "a mismatched binding still reached a session: $(cat "$dir/signals.log")"
  kill -TERM "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
  LISTENER_PID=
  pass "fm-send: an unproven OMP session binding is refused, never redirected to the terminal"
}

# A requester with no explicit ack bound derives its window from the
# doorbell's turn-grace setting, so a re-drive that lands inside the grace
# bound reports delivered instead of a false queued verdict; an explicit
# FM_OMP_TASK_DOORBELL_ACK_ATTEMPTS still wins. The consumed receipt leaves a
# durable .acked tombstone, so a re-ring for the same record reports
# delivered without ever sending the doorbell again.
test_requester_window_tracks_turn_grace_and_acked_suppresses() {
  local dir="$TMP_ROOT/ack-window" home signal_log listener_pid request_dir
  home="$dir/home"
  mkdir -p "$home/state"
  signal_log="$dir/signals.log"
  : > "$signal_log"
  listener_pid=$(start_redriving_listener "$dir" "$home" t1 "$signal_log" "$dir/listener.ready" 2500)
  LISTENER_PID=$listener_pid
  request_dir="$home/state/t1.omp-doorbell-ready.requests"

  ROOT="$ROOT" MARKER="$home/state/t1.omp-doorbell-ready" PID="$listener_pid" \
    REQDIR="$request_dir" SIGNAL_LOG="$signal_log" bash <<'SH'
set -u
. "$ROOT/bin/fm-backend.sh"

set +e
FM_OMP_DOORBELL_TURN_GRACE_MS=2500 \
  fm_omp_task_doorbell_request "$MARKER" "$PID" first.msg 'canonical doorbell'
rc=$?
set -e
[ "$rc" = 0 ] || { echo "landed re-drive must report delivered, got rc=$rc" >&2; exit 1; }
[ -f "$REQDIR/request.first.msg.pending.acked" ] \
  || { echo "the consumed receipt left no .acked tombstone" >&2; exit 1; }

set +e
fm_omp_task_doorbell_request "$MARKER" "$PID" first.msg 'canonical doorbell'
rc=$?
set -e
[ "$rc" = 0 ] || { echo "a re-ring of an acked request must report delivered, got rc=$rc" >&2; exit 1; }
[ ! -e "$REQDIR/request.first.msg.pending" ] \
  || { echo "a re-ring of an acked request re-published the pending request" >&2; exit 1; }
[ "$(wc -l < "$SIGNAL_LOG" | tr -d '[:space:]')" = 2 ] \
  || { echo "expected exactly one sendMessage plus one re-drive, got: $(cat "$SIGNAL_LOG")" >&2; exit 1; }

set +e
FM_OMP_DOORBELL_TURN_GRACE_MS=2500 FM_OMP_TASK_DOORBELL_ACK_ATTEMPTS=5 \
  fm_omp_task_doorbell_request "$MARKER" "$PID" second.msg 'canonical doorbell'
rc=$?
set -e
[ "$rc" = 2 ] || { echo "an explicit short ack window must still report queued, got rc=$rc" >&2; exit 1; }
SH
  expect_code 0 "$?" "requester window and acked suppression"
  kill -TERM "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
  LISTENER_PID=
  pass "requester ack window tracks the turn grace and an acked receipt suppresses the re-ring"
}

test_extension_signal_uses_trigger_turn
test_extension_requires_turn_proof_or_redrives
test_extension_external_notify_drives_turn_proof
test_extension_activate_reports_and_journals_failures
test_ring_routing_matrix
test_request_terminal_states
test_fm_send_rings_one_programmatic_doorbell
test_omp_native_receive_reports_exact_binding
test_omp_native_refusal_and_queue_are_bounded
test_omp_native_binding_mismatch_is_refused
test_requester_window_tracks_turn_grace_and_acked_suppresses
