#!/usr/bin/env bash
# Wake acknowledgement guard for local Communication Officer requests.
#
#   an inbox request with no reply receipt refuses --ack-through, acknowledges
#   nothing, and names the request's slug, thread, and age;
#   a reply emitted with no delivery receipt still refuses and names the
#   gateway poster as the likely cause;
#   an ack, answer, followup, or final receipt lets the acknowledgement through;
#   `bin/fm-ext-inbox.sh dismiss` needs a reason, records it, and unblocks;
#   an ack-only request past the threshold warns on every drain, never blocks;
#   a home without the bridge, or with an empty inbox, is unchanged.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-ext-lib.sh
. "$ROOT/bin/fm-ext-lib.sh"

JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] || fail "test needs jq"
command -v python3 >/dev/null 2>&1 || fail "test needs python3 to set file times"
TMP_ROOT=$(fm_test_tmproot fm-ext-ack-guard)

DRAIN="$ROOT/bin/fm-wake-drain.sh"
INBOX_CMD="$ROOT/bin/fm-ext-inbox.sh"

GUILD=111111111111111111
CHANNEL=222222222222222222
THREAD=333333333333333333
RID="discord:${GUILD}:${CHANNEL}:${THREAD}:444444444444444444"
SLUG=$(fm_ext_request_slug "$RID") || fail "could not derive the request slug"

setup_home() {  # <home> [bridge]
  local home=$1 bridge=${2:-on}
  (umask 077; mkdir -p "$home/config" "$home/state")
  if [ "$bridge" = on ]; then
    : > "$home/config/ext-bridge"
    printf 'test-secret\n' > "$home/config/ext-secret"
    chmod 600 "$home/config/ext-secret"
  fi
}

home_env() {  # <home> <cmd...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    env -u FM_SUPERVISION_ACTOR -u FM_TASK_ID -u FM_EXT_ACK_ONLY_WARN_SECS "$@"
}

# write_inbox <home> <age-seconds>: one safe inbox record filed that long ago.
write_inbox() {
  local home=$1 age=$2 dir="$1/state/ext-inbox"
  (umask 077; mkdir -p "$dir")
  jq -cn --arg rid "$RID" --arg slug "$SLUG" --argjson at "$(( $(date +%s) - age ))" \
    '{schema_version:1, request_id:$rid, slug:$slug, platform:"discord",
      authority:"standing", origin:"message", text:"status please",
      thread_name:"Aceh · ingestion status", project:"aceh", recorded_at:$at}' \
    > "$dir/$SLUG.json" || fail "could not write inbox record"
  chmod 600 "$dir/$SLUG.json"
}

# write_outbox <home> <basename> [age-seconds]: one safe outbox artifact.
write_outbox() {
  local home=$1 base=$2 age=${3:-0} dir="$1/state/ext-outbox"
  (umask 077; mkdir -p "$dir")
  printf '{"ok":true}\n' > "$dir/$base"
  chmod 600 "$dir/$base"
  python3 -c 'import os, sys, time; t = time.time() - int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' \
    "$dir/$base" "$age"
}

# drain_once <home> <out> <err>: a plain drain over one queued wake row.
drain_once() {
  home_env "$1" "$DRAIN" > "$2" 2> "$3" || fail "plain drain failed: $(cat "$3")"
}

# ack <home> <err-of-drain> <ack-err>: run the printed acknowledgement; prints rc.
ack() {
  local home=$1 err=$2 ack_err=$3 sequence generation rc=0
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "drain printed no acknowledgement command: $(cat "$err")"
  home_env "$home" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    > /dev/null 2> "$ack_err" || rc=$?
  printf '%s\n' "$rc"
}

# prepare <name> [bridge]: a home with one queued wake row, drained once.
prepare() {
  local home="$TMP_ROOT/$1"
  setup_home "$home" "${2:-on}"
  append_wake "$home/state" check "ext-request:$SLUG" "ext-request $SLUG"
  printf '%s\n' "$home"
}

queue_rows() { awk 'END { print NR }' "$1/state/.wake-queue" 2>/dev/null || echo 0; }

test_unanswered_request_refuses_and_keeps_the_queue() {
  local home rc before
  home=$(prepare unanswered)
  write_inbox "$home" 5400
  drain_once "$home" "$home/d1.out" "$home/d1.err"
  before=$(cat "$home/state/.wake-queue")
  rc=$(ack "$home" "$home/d1.err" "$home/ack.err")
  expect_code 4 "$rc" "an unanswered request must refuse the acknowledgement"
  assert_grep "ext-request $SLUG" "$home/ack.err" "missing: ext-request \$SLUG in ack.err"
  assert_grep "thread: Aceh · ingestion status (aceh)" "$home/ack.err" "missing: thread: Aceh · ingestion status (aceh) in ack.err"
  assert_grep "age: 1h30m" "$home/ack.err" "missing: age: 1h30m in ack.err"
  assert_grep "nothing was acknowledged" "$home/ack.err" "missing: nothing was acknowledged in ack.err"
  assert_grep "no reply emitted at all" "$home/ack.err" "missing: no reply emitted at all in ack.err"
  assert_grep "bin/fm-ext-inbox.sh dismiss --slug" "$home/ack.err" "missing: bin/fm-ext-inbox.sh dismiss --slug in ack.err"
  [ "$(cat "$home/state/.wake-queue")" = "$before" ] || fail "a refused acknowledgement changed the wake queue"
  drain_once "$home" "$home/d2.out" "$home/d2.err"
  assert_grep "ext-request $SLUG" "$home/d2.out" "missing: ext-request \$SLUG in d2.out"
  [ "$(grep '^WAKE_ACK_REQUIRED:' "$home/d2.err")" = "$(grep '^WAKE_ACK_REQUIRED:' "$home/d1.err")" ] \
    || fail "a refused acknowledgement moved the sequence or recovery generation"
  pass "an unanswered request refuses the acknowledgement and leaves the queue intact"
}

test_emitted_without_receipt_names_the_gateway() {
  local home rc
  home=$(prepare emitted)
  write_inbox "$home" 600
  write_outbox "$home" "$SLUG.answer.1.json"
  write_outbox "$home" "$SLUG.answer.1.posting"
  drain_once "$home" "$home/d1.out" "$home/d1.err"
  rc=$(ack "$home" "$home/d1.err" "$home/ack.err")
  expect_code 4 "$rc" "a reply with no delivery receipt must still refuse"
  assert_grep "reply emitted, no delivery receipt" "$home/ack.err" "missing: reply emitted, no delivery receipt in ack.err"
  assert_grep "gateway poster may be down" "$home/ack.err" "missing: gateway poster may be down in ack.err"
  assert_no_grep "no reply emitted at all" "$home/ack.err" "unexpected: no reply emitted at all in ack.err"
  pass "a reply emitted without a receipt refuses and names the gateway poster"
}

test_any_reply_receipt_lets_the_ack_through() {
  local home rc kind
  for kind in ack answer followup final; do
    home=$(prepare "receipt-$kind")
    write_inbox "$home" 600
    write_outbox "$home" "$SLUG.$kind.1.receipt.json"
    drain_once "$home" "$home/d1.out" "$home/d1.err"
    rc=$(ack "$home" "$home/d1.err" "$home/ack.err")
    expect_code 0 "$rc" "a $kind receipt must let the acknowledgement through ($(cat "$home/ack.err"))"
    [ "$(queue_rows "$home")" -eq 0 ] || fail "a $kind receipt acknowledgement left rows queued"
  done
  pass "an ack, answer, followup, or final receipt lets the acknowledgement through"
}

test_dismiss_needs_a_reason_records_it_and_unblocks() {
  local home rc=0 record
  home=$(prepare dismiss)
  write_inbox "$home" 600
  write_outbox "$home" "$SLUG.answer.1.posting"
  home_env "$home" "$INBOX_CMD" dismiss --slug "$SLUG" > /dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "dismiss without a reason must be refused"
  rc=0
  home_env "$home" "$INBOX_CMD" dismiss --slug "$SLUG" --reason "" > /dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "dismiss with an empty reason must be refused"
  assert_present "$home/state/ext-inbox/$SLUG.json" "a refused dismiss must keep the inbox record"
  drain_once "$home" "$home/d1.out" "$home/d1.err"
  rc=$(ack "$home" "$home/d1.err" "$home/ack.err")
  expect_code 4 "$rc" "an undismissed request must still refuse"
  rc=0
  home_env "$home" "$INBOX_CMD" dismiss --slug "$SLUG" \
    --reason "duplicate of a request already answered in this thread" > /dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "dismiss with a reason must succeed even while a reply is mid-delivery"
  assert_absent "$home/state/ext-inbox/$SLUG.json" "a dismissed request must leave the inbox"
  record="$home/state/ext-outbox/$SLUG.noreply.json"
  assert_equals "dismissed" "$(jq -r '.disposition' "$record")" "dismiss must record its disposition"
  assert_equals "duplicate of a request already answered in this thread" "$(jq -r '.reason' "$record")" \
    "dismiss must record its reason"
  rc=$(ack "$home" "$home/d1.err" "$home/ack.err")
  expect_code 0 "$rc" "a dismissed request must no longer block ($(cat "$home/ack.err"))"
  pass "dismiss needs a reason, records it, and unblocks the acknowledgement"
}

test_stale_ack_only_request_warns_without_blocking() {
  local home rc
  home=$(prepare stale-ack)
  write_inbox "$home" 12000
  write_outbox "$home" "$SLUG.ack.1.receipt.json" 10800
  drain_once "$home" "$home/d1.out" "$home/d1.err"
  assert_grep "EXT REQUESTS ACKED BUT NOT ANSWERED" "$home/d1.out" "missing: EXT REQUESTS ACKED BUT NOT ANSWERED in d1.out"
  assert_grep "$SLUG  thread: Aceh · ingestion status (aceh)" "$home/d1.out" "missing: \$SLUG  thread: Aceh · ingestion status (aceh) in d1.out"
  assert_grep "last ack: 3h00m ago" "$home/d1.out" "missing: last ack: 3h00m ago in d1.out"
  rc=$(ack "$home" "$home/d1.err" "$home/ack.err")
  expect_code 0 "$rc" "the ack-only warning must never block"
  assert_grep "EXT REQUESTS ACKED BUT NOT ANSWERED" "$home/ack.err" "missing: EXT REQUESTS ACKED BUT NOT ANSWERED in ack.err"

  home=$(prepare fresh-ack)
  write_inbox "$home" 600
  write_outbox "$home" "$SLUG.ack.1.receipt.json" 300
  drain_once "$home" "$home/d1.out" "$home/d1.err"
  assert_no_grep "EXT REQUESTS ACKED BUT NOT ANSWERED" "$home/d1.out" "unexpected: EXT REQUESTS ACKED BUT NOT ANSWERED in d1.out"
  home_env "$home" env FM_EXT_ACK_ONLY_WARN_SECS=60 "$DRAIN" > "$home/d2.out" 2>/dev/null \
    || fail "drain with a lowered threshold failed"
  assert_grep "EXT REQUESTS ACKED BUT NOT ANSWERED" "$home/d2.out" "missing: EXT REQUESTS ACKED BUT NOT ANSWERED in d2.out"
  pass "an ack-only request past the threshold warns without blocking; a fresh one does not"
}

test_inert_without_bridge_or_with_empty_inbox() {
  local home rc
  home=$(prepare no-bridge off)
  write_inbox "$home" 600
  drain_once "$home" "$home/d1.out" "$home/d1.err"
  assert_no_grep "EXT REQUESTS" "$home/d1.out" "unexpected: EXT REQUESTS in d1.out"
  rc=$(ack "$home" "$home/d1.err" "$home/ack.err")
  expect_code 0 "$rc" "a home without the bridge must acknowledge as before"
  [ ! -s "$home/ack.err" ] || fail "a home without the bridge printed acknowledgement output: $(cat "$home/ack.err")"

  home=$(prepare empty-inbox)
  drain_once "$home" "$home/d1.out" "$home/d1.err"
  assert_no_grep "EXT REQUESTS" "$home/d1.out" "unexpected: EXT REQUESTS in d1.out"
  rc=$(ack "$home" "$home/d1.err" "$home/ack.err")
  expect_code 0 "$rc" "an empty inbox must acknowledge as before"
  [ ! -s "$home/ack.err" ] || fail "an empty inbox printed acknowledgement output: $(cat "$home/ack.err")"
  [ "$(queue_rows "$home")" -eq 0 ] || fail "an empty-inbox acknowledgement left rows queued"
  pass "a home without the bridge or with an empty inbox is unchanged"
}

test_unanswered_request_refuses_and_keeps_the_queue
test_emitted_without_receipt_names_the_gateway
test_any_reply_receipt_lets_the_ack_through
test_dismiss_needs_a_reason_records_it_and_unblocks
test_stale_ack_only_request_warns_without_blocking
test_inert_without_bridge_or_with_empty_inbox
echo "all fm-ext-ack-guard tests passed"
