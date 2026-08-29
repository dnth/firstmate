#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/fm-pending-reply-lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" "$CLAIMS"
cleanup() {
  local worker_pid attempt=0
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid" 2>/dev/null || true)
  case "$worker_pid" in
    ''|*[!0-9]*) ;;
    *)
      kill "$worker_pid" 2>/dev/null || true
      while kill -0 "$worker_pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
        attempt=$((attempt + 1))
        sleep 0.05
      done
      ;;
  esac
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"
: > "$REMOTE/state/parent-replies.status"
SOURCE_BEFORE="$TMP_ROOT/source-before"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_BEFORE"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

wait_for() {
  local path=$1
  for _ in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=0" "remote reply source was not armed at the empty cursor"

INITIAL_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "await initial correlated report")
fm_pending_reply_mark_delivered "$PARENT/state" "$INITIAL_CORR" \
  || fail "could not create initial reply expectation"
INITIAL_CORR_UPPER=$(printf '%s' "$INITIAL_CORR" | tr 'a-f' 'A-F')
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-one.out" 2>&1 &
RUNNER=$!
wait_for "$CLAIMS/$SID.claim" || fail "process-event runner never claimed the remote reply source"
printf 'done [corr=%s]: build verified (data/reply/report.md)\n' "$INITIAL_CORR_UPPER" \
  >> "$REMOTE/state/parent-replies.status"
wait "$RUNNER" || fail "remote reply source failed to capture its first delta"
RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null)
if [ -z "$RESULT" ]; then
  printf 'runner output:\n%s\n' "$(cat "$TMP_ROOT/start-one.out")" >&2
  fail "the remote reply delta was not durably captured"
fi
assert_grep "done [corr=$INITIAL_CORR_UPPER]" "$RESULT" "captured delta lost the correlated status line"
assert_grep "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue" "runner did not publish the normalized remote-reply event"
assert_no_grep 'build verified' "$PARENT/state/.wake-queue" "reply payload leaked into the event queue"
cmp -s "$SOURCE_BEFORE" "$REMOTE/state/parent-replies.status" \
  && fail "fixture did not append the expected source line"
SOURCE_AFTER="$TMP_ROOT/source-after"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_AFTER"
pass "a blocking non-destructive remote delta reaches durable process-event capture"

rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
set +e
remote_env "$ADAPTER" handle ios 1 "$RESULT" > "$TMP_ROOT/handle-arm-fail.out" 2>&1
handle_arm_rc=$?
set -e
[ "$handle_arm_rc" -ne 0 ] || fail "reply handling acknowledged a result whose re-arm failed"
assert_grep "done [corr=$INITIAL_CORR_UPPER]" "$PARENT/state/ios.status" "failed re-arm lost the ingested reply"
assert_grep 'ingested: ios appended=1' "$TMP_ROOT/handle-arm-fail.out" "failed re-arm did not commit the reply before retry"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$reconcile_out" 'published=1' "failed re-arm did not leave the result eligible for retry"
out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "retried reply ingest was not idempotent"
assert_contains "$out" 'handled: remote-reply-ios 1' "captured generation was not acknowledged"
assert_grep "done [corr=$INITIAL_CORR_UPPER]" "$PARENT/state/ios.status" "parent status did not receive the correlated reply"
assert_grep 'data/remote-secondmates/ios/data/reply/report.md' "$PARENT/state/ios.status" "remote document pointer was not rewritten locally"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$INITIAL_CORR")" phase)" = resolved ] \
  || fail "exact correlated report did not resolve its parent request"
cmp -s "$REMOTE/data/reply/report.md" "$PARENT/data/remote-secondmates/ios/data/reply/report.md" \
  || fail "the path-confined remote document copy is not byte-identical"
cmp -s "$SOURCE_AFTER" "$REMOTE/state/parent-replies.status" \
  || fail "handling consumed or rewrote the remote append-only log"
expected_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$expected_offset" "$PARENT/state/remote-replies/ios.cursor" "reply cursor did not advance to the committed delta"
pass "ingest appends one validated line, fetches its document, and advances the cursor"

out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "replayed result was not deduplicated"
assert_contains "$out" 'already-handled: remote-reply-ios 1' "replayed generation was not acknowledged idempotently"
[ "$(grep -cF "done [corr=$INITIAL_CORR_UPPER]" "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replayed ingest duplicated the parent status line"
pass "replayed capture has one deduplicated append and one durable handling identity"

printf 'working [corr=1111111111111111]: second generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "second reply generation was not captured"
RESULT_TWO="$PARENT/state/procevent-inbox/$SID.2.result"
ln -s "$TMP_ROOT/missing-handled-marker" "$PARENT/state/procevent-inbox/$SID.2.handled"
set +e
remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO" > "$TMP_ROOT/handle-two-unacked.out" 2>&1
handle_two_rc=$?
set -e
[ "$handle_two_rc" -ne 0 ] || fail "second generation acknowledged through an unsafe handled marker"
assert_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" "unacknowledged generation was not ingested"
printf 'done [corr=2222222222222222]: third generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "third reply generation was not captured"
RESULT_THREE="$PARENT/state/procevent-inbox/$SID.3.result"
remote_env "$ADAPTER" handle ios 3 "$RESULT_THREE" >/dev/null \
  || fail "third reply generation was not handled"
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
out=$(remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO")
assert_contains "$out" 'ingested: ios appended=0' "earlier generation did not replay from its durable ingestion receipt"
assert_contains "$out" 'handled: remote-reply-ios 2' "earlier generation remained unacknowledged after later cursor advancement"
[ "$(grep -cF 'working [corr=1111111111111111]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "earlier generation replay duplicated its parent status"
pass "later generations cannot invalidate an unacknowledged ingested result"

# Autonomous lifecycle reports are valid status input but cannot resolve a
# marked parent request, even when a corr-like substring names it.
# The handled generation must still advance and re-arm.
AUTONOMOUS_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "await autonomous report")
fm_pending_reply_mark_delivered "$PARENT/state" "$AUTONOMOUS_CORR" \
  || fail "could not create autonomous reply expectation"
printf 'blocked [key=remote-review]: waiting for external review\ndone: notcorr=%s is not a parent reply\ndone: not-corr=%s is not a parent reply\ndone: not.corr=%s is not a parent reply\n' "$AUTONOMOUS_CORR" "$AUTONOMOUS_CORR" "$AUTONOMOUS_CORR" \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "autonomous reply generation was not captured"
RESULT_FOUR="$PARENT/state/procevent-inbox/$SID.4.result"
out=$(remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR")
assert_contains "$out" 'ingested: ios appended=4' "autonomous reports were not ingested"
assert_contains "$out" 'handled: remote-reply-ios 4' "autonomous capture was not acknowledged"
assert_grep 'blocked [key=remote-review]: waiting for external review' "$PARENT/state/ios.status" \
  "autonomous lifecycle report did not reach parent status"
assert_grep "done: notcorr=$AUTONOMOUS_CORR is not a parent reply" "$PARENT/state/ios.status" \
  "corr-like autonomous report did not reach parent status"
assert_grep "done: not-corr=$AUTONOMOUS_CORR is not a parent reply" "$PARENT/state/ios.status" \
  "punctuated corr-like autonomous report did not reach parent status"
assert_grep "done: not.corr=$AUTONOMOUS_CORR is not a parent reply" "$PARENT/state/ios.status" \
  "dotted corr-like autonomous report did not reach parent status"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$AUTONOMOUS_CORR")" phase)" = awaiting_report ] \
  || fail "corr-like autonomous lifecycle report resolved a marked parent request"
assert_present "$PARENT/state/procevent/$SID.source" "autonomous handling did not re-arm the source"
pass "autonomous lifecycle reports ingest without resolving marked requests"

# One captured delta may mix autonomous lifecycle reports with a correlated
# parent reply. It must preserve line order, resolve only the exact request,
# advance the cursor, acknowledge the capture, and re-arm normally.
MATCHING_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "await matching report")
WRONG_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "await different report")
fm_pending_reply_mark_delivered "$PARENT/state" "$MATCHING_CORR" \
  || fail "could not create matching reply expectation"
fm_pending_reply_mark_delivered "$PARENT/state" "$WRONG_CORR" \
  || fail "could not create wrong-correlation expectation"
printf 'blocked [key=remote-build]: remote build needs an approval\nresolved [key=remote-build]: approval arrived\ndone [corr=%s]: remote build passed\n' "$MATCHING_CORR" \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "mixed reply generation was not captured"
RESULT_FIVE="$PARENT/state/procevent-inbox/$SID.5.result"
out=$(remote_env "$ADAPTER" handle ios 5 "$RESULT_FIVE")
assert_contains "$out" 'ingested: ios appended=3' "mixed reply generation was not ingested as one delta"
assert_contains "$out" 'handled: remote-reply-ios 5' "mixed capture was not acknowledged"
blocked_line=$(grep -nF 'blocked [key=remote-build]: remote build needs an approval' "$PARENT/state/ios.status" | cut -d: -f1)
resolved_line=$(grep -nF 'resolved [key=remote-build]: approval arrived' "$PARENT/state/ios.status" | cut -d: -f1)
done_line=$(grep -nF "done [corr=$MATCHING_CORR]: remote build passed" "$PARENT/state/ios.status" | cut -d: -f1)
[ "$blocked_line" -lt "$resolved_line" ] && [ "$resolved_line" -lt "$done_line" ] \
  || fail "mixed reply generation did not preserve status-line order"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$MATCHING_CORR")" phase)" = resolved ] \
  || fail "matching correlated reply did not resolve its parent request"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$WRONG_CORR")" phase)" = awaiting_report ] \
  || fail "wrong correlation resolved a different parent request"
mixed_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$mixed_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "mixed reply generation did not advance the cursor"
assert_present "$PARENT/state/procevent/$SID.source" "mixed handling did not re-arm the source"
pass "mixed autonomous and correlated reports preserve exact resolution and cursor continuity"

# A digest-valid unknown lifecycle verb is still rejected at the public ingest
# boundary. Recalculate its payload commitment so the behavioral assertion is
# specifically about status validation, not incidental digest failure.
BAD_RESULT="$TMP_ROOT/bad.result"
cp "$RESULT" "$BAD_RESULT"
boundary=$(grep -n -m 1 '^$' "$BAD_RESULT" | cut -d: -f1)
tail -n "+$((boundary + 1))" "$BAD_RESULT" \
  | sed 's/^done /unknown /' > "$TMP_ROOT/bad.payload"
bad_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/bad.payload" | tr -d ' ')
bad_hash=$(sha256_file "$TMP_ROOT/bad.payload")
head -n "$boundary" "$BAD_RESULT" \
  | sed "s/^payload_sha256=.*/payload_sha256=$bad_hash/;s/^payload_bytes=.*/payload_bytes=$bad_bytes/" \
  > "$TMP_ROOT/bad.header"
cat "$TMP_ROOT/bad.header" "$TMP_ROOT/bad.payload" > "$BAD_RESULT"
if remote_env "$ADAPTER" ingest ios "$BAD_RESULT" >/dev/null 2>&1; then
  fail "ingest accepted a status line with an unknown lifecycle verb"
fi
[ "$(grep -cF "done [corr=$INITIAL_CORR_UPPER]" "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "invalid ingest disturbed the accepted parent status line"
pass "ingest rejects invalid lifecycle payloads even when their transport digest is valid"

# The adapter re-armed at the committed cursor. Truncation is detected from the
# next blocking source and escalated once; it is never silently treated as a new
# log or re-armed past the break.
printf 'failed [corr=fedcba9876543210]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-two.out" 2>&1 &
RUNNER=$!
wait "$RUNNER" || fail "continuity break was not captured as a structured result"
RESULT_SIX=$(find "$PARENT/state/procevent-inbox" -name "$SID.6.result" -print -quit)
[ -n "$RESULT_SIX" ] || fail "continuity break produced no durable result"
[ "$(remote_env "$ADAPTER" classify "$RESULT_SIX")" = continuity-broken ] \
  || fail "truncated source was not classified as a continuity break"
set +e
remote_env "$ADAPTER" handle ios 6 "$RESULT_SIX" > "$TMP_ROOT/handle-six.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "continuity handling returned an unexpected status: $handle_rc"
assert_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "continuity break did not escalate"
assert_absent "$PARENT/state/procevent/$SID.source" "continuity break was re-armed without an operator rebase"
remote_env "$ADAPTER" ingest ios "$RESULT_SIX" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "continuity replay duplicated the escalation"
pass "truncation is detected, escalated once, and not silently rebased"

rm -f "$PARENT/state/procevent-inbox/$SID.6.handled"
if remote_env "$ADAPTER" retire ios > "$TMP_ROOT/retire-pending.out" 2>&1; then
  fail "remote reply retirement accepted an unhandled captured result"
fi
assert_grep 'unhandled captured result' "$TMP_ROOT/retire-pending.out" \
  "remote reply retirement did not explain its pending-result refusal"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "refused retirement left the reply source running past its pending-result check"
remote_env "$ADAPTER" handle ios 6 "$RESULT_SIX" >/dev/null 2>&1 || [ "$?" -eq 3 ] \
  || fail "pending continuity result could not be acknowledged after retirement refusal"
remote_env "$ADAPTER" retire ios >/dev/null
assert_absent "$PARENT/state/remote-replies/ios.cursor" "adapter retirement left its cursor"
pass "remote reply retirement quiesces and refuses unhandled captured results"

echo "ALL TESTS PASSED"
