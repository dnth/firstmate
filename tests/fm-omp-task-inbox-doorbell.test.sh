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
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { FM_TASK_INBOX_DOORBELL_SIGNAL, installTaskInboxDoorbell } =
  await import(pathToFileURL(process.env.HELPER).href);
const sent = [];
const retire = installTaskInboxDoorbell(
  { sendMessage(message, options) { sent.push({ message, options }); } },
  { inboxDir: process.env.INBOX, readyMarker: process.env.READY },
);
assert.equal(readFileSync(process.env.READY, "utf8"), `${process.pid}\n`);
process.emit(FM_TASK_INBOX_DOORBELL_SIGNAL);
assert.equal(sent.length, 1);
assert.equal(sent[0].message.customType, "firstmate-task-inbox-doorbell");
assert.match(sent[0].message.content, new RegExp(`${process.env.INBOX.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/\\*\\.msg`));
assert.deepEqual(sent[0].options, { deliverAs: "steer", triggerTurn: true });
retire();
assert.equal(existsSync(process.env.READY), false);

const unavailable = `${process.env.READY}.unavailable`;
const retireUnavailable = installTaskInboxDoorbell({}, {
  inboxDir: process.env.INBOX,
  readyMarker: unavailable,
});
assert.equal(existsSync(unavailable), false);
retireUnavailable();
JS
  pass "OMP worker extension turns one task-bound signal into one programmatic triggerTurn steer"
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
PROGRAMMATIC_AVAILABLE=1 fm_task_inbox_ring tmux target "$REC" fm-t1 claude
! grep -q '^programmatic:' "$LOG"
[ "$(grep -c '^composer-submit:' "$LOG")" = 1 ]
SH
  expect_code 0 "$?" "OMP/non-OMP doorbell routing matrix"
  pass "doorbell routing selects OMP programmatic wake and preserves both composer branches"
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

  SIGNAL_LOG="$signal_log" LISTENER_READY="$listener_ready" node --input-type=module <<'JS' &
import { appendFileSync, writeFileSync } from "node:fs";
process.on("SIGUSR2", () => appendFileSync(process.env.SIGNAL_LOG, "ring\n"));
writeFileSync(process.env.LISTENER_READY, `${process.pid}\n`);
setInterval(() => {}, 1000);
JS
  LISTENER_PID=$!
  for _ in $(seq 1 100); do
    [ -f "$listener_ready" ] && break
    /bin/sleep 0.01
  done
  [ -f "$listener_ready" ] || fail "signal listener did not start"
  printf '%s\n' "$LISTENER_PID" > "$home/state/t1.omp-doorbell-ready"
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
fm_backend_herdr_omp_trigger_turn default:w1:p2 "$MARKER" "$OMP_BIN" "$OMP_BIN"
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
test_fm_send_rings_one_programmatic_doorbell
