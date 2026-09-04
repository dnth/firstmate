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
  local dir home node_bin out err rc silent_pid request
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
  assert_contains "$(cat "$err")" 'do not resend' "the refusal invited a resend"
  assert_contains "$(cat "$err")" "record=$home/state/idle.inbox/001.msg" \
    "the refusal did not name the durable record holding the exact message"
  [ -f "$home/state/idle.inbox/001.msg" ] || fail "the refused steer lost its durable record"
  [ ! -s "$dir/composer.log" ] \
    || fail "a refused OMP steer typed into the composer: $(cat "$dir/composer.log")"

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
  FM_OMP_TASK_DOORBELL_ACK_ATTEMPTS=1 \
    run_native_send "$dir" "$home" "$silent_pid" "$node_bin" "$out" "$err" \
    quiet "pick up the review findings"; rc=$?
  expect_code 7 "$rc" "an unacknowledged native request must not exit 0"
  request="$home/state/quiet.omp-doorbell-ready.requests/request.001.msg"
  assert_contains "$(cat "$err")" 'omp-native-queued:' \
    "the unacknowledged request did not report a durable native queue outcome"
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
  run_native_send "$dir" "$home" "$((listener_pid + 1))" "$node_bin" "$out" "$err" \
    bound "apply the accepted fix"; rc=$?
  expect_code 6 "$rc" "an unproven session binding must exit nonzero"
  assert_contains "$(cat "$err")" 'omp-native-refused:' \
    "an unproven session binding was not explicitly refused"
  [ ! -s "$dir/composer.log" ] \
    || fail "a refused binding fell back to the composer: $(cat "$dir/composer.log")"
  [ ! -s "$dir/signals.log" ] || fail "a mismatched binding still reached a session: $(cat "$dir/signals.log")"
  kill -TERM "$listener_pid" 2>/dev/null || true
  wait "$listener_pid" 2>/dev/null || true
  LISTENER_PID=
  pass "fm-send: an unproven OMP session binding is refused, never redirected to the terminal"
}

test_extension_signal_uses_trigger_turn
test_ring_routing_matrix
test_request_terminal_states
test_fm_send_rings_one_programmatic_doorbell
test_omp_native_receive_reports_exact_binding
test_omp_native_refusal_and_queue_are_bounded
test_omp_native_binding_mismatch_is_refused
