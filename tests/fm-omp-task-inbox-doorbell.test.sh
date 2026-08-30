#!/usr/bin/env bash
# OMP task-inbox doorbell routing and extension behavior.
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
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
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
JS
  pass "OMP extension drains canonical counted requests and safely retires signal readiness"
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
PROGRAMMATIC_AVAILABLE=0 fm_task_inbox_ring herdr target "$REC" fm-t1 omp /runtime/omp /bin/omp
[ "$(grep -c '^programmatic:' "$LOG")" = 1 ]
[ "$(grep -c '^composer-submit:' "$LOG")" = 1 ]

: > "$LOG"
fm_backend_omp_trigger_turn() {
  printf 'programmatic-indeterminate\n' >> "$LOG"
  return 2
}
fm_task_inbox_ring herdr target "$REC" fm-t1 omp /runtime/omp /bin/omp
[ "$(grep -c '^programmatic-indeterminate' "$LOG")" = 1 ]
! grep -q '^composer-' "$LOG"

: > "$LOG"
PROGRAMMATIC_AVAILABLE=1 fm_task_inbox_ring tmux target "$REC" fm-t1 claude
! grep -q '^programmatic:' "$LOG"
[ "$(grep -c '^composer-submit:' "$LOG")" = 1 ]
SH
  expect_code 0 "$?" "OMP/non-OMP doorbell routing matrix"
  pass "doorbell routing selects OMP programmatic wake and preserves both composer branches"
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
  list-windows) exit 0 ;;
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

test_extension_signal_uses_trigger_turn
test_ring_routing_matrix
test_request_terminal_states
test_fm_send_rings_one_programmatic_doorbell
