#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/bin/fm-classify-lib.sh"

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
- calm - dormant remote (host: remote-mac; root: $ROOT; home: $REMOTE; scope: idle; projects: alpha; added 2026-08-02)
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
  FM_REMOTE_REPLY_WAIT_SECONDS=2 \
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

# Wait until no runner claim for this source is held, so assertions observe the
# capturing runner's finished retire/handled/re-arm verdicts rather than its
# still-running poll.
wait_unclaimed() {
  # A detached restart crosses the 1s launch floor before its claim exists, so
  # "absent" is only meaningful once that floor has passed.
  sleep 1.3
  for _ in $(seq 1 200); do
    [ ! -e "$CLAIMS/$SID.claim" ] && return 0
    sleep 0.05
  done
  return 1
}

# A capture can be produced by the foreground `start` below or by the detached
# runner an autohandle re-arms; either way the durable result file is the proof,
# and the runner is left to settle before returning.
capture_delta() {  # <seq>: the new remote log line(s) must already be appended
  local seq=$1 attempt
  for attempt in 1 2 3; do
    remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-$seq.out" 2>&1 || true
    [ -f "$PARENT/state/procevent-inbox/$SID.$seq.result" ] && break
    wait_for "$PARENT/state/procevent-inbox/$SID.$seq.result" && break
    [ "$attempt" = 3 ] || continue
  done
  if [ ! -f "$PARENT/state/procevent-inbox/$SID.$seq.result" ]; then
    printf 'runner output for seq %s:\n%s\n' "$seq" "$(cat "$TMP_ROOT/start-$seq.out")" >&2
    fail "remote reply delta $seq was not durably captured"
  fi
  wait_unclaimed || fail "the remote reply runner never released its claim after delta $seq"
}

wait_handled() {  # <seq>: autohandle may still be committing after the capture lands
  wait_for "$PARENT/state/procevent-inbox/$SID.$1.handled" \
    || fail "captured remote reply generation $1 was never durably handled"
}

# Hold the reply lifecycle lock so an autohandle exits busy (75) and leaves the
# capture pending, exactly as a teardown or RunPod sleep holding it would.
hold_lifecycle_lock() {  # <id>
  rm -f "$TMP_ROOT/lifecycle-ready" "$TMP_ROOT/lifecycle-release"
  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock="$2/state/.remote-reply-lifecycle-$3.lock"
    fm_lock_acquire_wait "$lock" || exit 1
    trap "fm_lock_release \"$lock\"" EXIT
    : > "$4"
    while [ ! -e "$5" ]; do
      kill -0 "$6" 2>/dev/null || exit 0
      sleep 0.02
    done
  ' _ "$ROOT" "$PARENT" "$1" "$TMP_ROOT/lifecycle-ready" "$TMP_ROOT/lifecycle-release" "$$" &
  HOLD_PID=$!
  wait_for "$TMP_ROOT/lifecycle-ready" \
    || fail "the lock holder never acquired the remote reply lifecycle lock"
}

release_lifecycle_lock() {
  : > "$TMP_ROOT/lifecycle-release"
  wait "$HOLD_PID" 2>/dev/null || true
  HOLD_PID=
}

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=0" "remote reply source was not armed at the empty cursor"

INITIAL_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "await initial correlated report")
fm_pending_reply_mark_delivered "$PARENT/state" "$INITIAL_CORR" \
  || fail "could not create initial reply expectation"
INITIAL_CORR_UPPER=$(printf '%s' "$INITIAL_CORR" | tr 'a-f' 'A-F')
printf 'done [corr=%s]: build verified (data/reply/report.md)\n' "$INITIAL_CORR_UPPER" \
  >> "$REMOTE/state/parent-replies.status"
capture_delta 1
RESULT="$PARENT/state/procevent-inbox/$SID.1.result"
assert_grep "done [corr=$INITIAL_CORR_UPPER]" "$RESULT" "captured delta lost the correlated status line"
assert_grep "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue" "runner did not publish the normalized remote-reply event"
assert_no_grep 'build verified' "$PARENT/state/.wake-queue" "reply payload leaked into the event queue"
cmp -s "$SOURCE_BEFORE" "$REMOTE/state/parent-replies.status" \
  && fail "fixture did not append the expected source line"
SOURCE_AFTER="$TMP_ROOT/source-after"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_AFTER"
pass "a blocking non-destructive remote delta reaches durable process-event capture"

# AC1: the runner's own autohandle ingests the capture with no agent turn and
# no `handle` call - status line, resolved correlation, receipt, handled
# marker, and the re-armed next generation all commit deterministically.
wait_handled 1
assert_grep "done [corr=$INITIAL_CORR_UPPER]" "$PARENT/state/ios.status" \
  "automatic handling did not append the correlated reply"
assert_grep 'data/remote-secondmates/ios/data/reply/report.md' "$PARENT/state/ios.status" \
  "automatic handling did not rewrite the remote document pointer locally"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$INITIAL_CORR")" phase)" = resolved ] \
  || fail "automatic handling did not resolve the correlated parent request"
assert_present "$PARENT/state/remote-replies/ios.1.ingested" \
  "automatic handling left no durable ingest receipt"
assert_present "$PARENT/state/procevent/$SID.source" \
  "automatic handling did not re-arm the reply source"
cmp -s "$REMOTE/data/reply/report.md" "$PARENT/data/remote-secondmates/ios/data/reply/report.md" \
  || fail "the path-confined remote document copy is not byte-identical"
cmp -s "$SOURCE_AFTER" "$REMOTE/state/parent-replies.status" \
  || fail "handling consumed or rewrote the remote append-only log"
expected_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$expected_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "automatic handling did not advance the reply cursor"
pass "AC1: a captured remote delta is ingested, acknowledged, and re-armed without an agent turn"

# Replayed handling stays idempotent through the durable ingest receipt.
out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "replayed result was not deduplicated"
assert_contains "$out" 'already-handled: remote-reply-ios 1' "replayed generation was not acknowledged idempotently"
[ "$(grep -cF "done [corr=$INITIAL_CORR_UPPER]" "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replayed ingest duplicated the parent status line"
pass "replayed capture has one deduplicated append and one durable handling identity"

# AC4+AC6: while the reply lifecycle lock is held, the runner's autohandle
# exits busy, the capture stays pending and un-ingested, `arm` reports the
# pending capture instead of stacking a duplicate registration, and a
# bootstrap-style re-arm captures no second generation. Busy autohandles never
# count failures or emit blocked lines.
hold_lifecycle_lock ios
printf 'working [corr=1111111111111111]: second generation\n' \
  >> "$REMOTE/state/parent-replies.status"
capture_delta 2
RESULT_TWO="$PARENT/state/procevent-inbox/$SID.2.result"
assert_absent "$PARENT/state/procevent-inbox/$SID.2.handled" \
  "a lock-busy autohandle acknowledged the captured result"
assert_absent "$PARENT/state/remote-replies/ios.2.ingested" \
  "a lock-busy autohandle left an ingest receipt"
assert_no_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" \
  "a lock-busy autohandle appended the reply anyway"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "a lock-busy autohandle left the source armed"
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$reconcile_out" 'published=1' \
  "a lock-busy capture was not re-announced by reconcile"
assert_absent "$PARENT/state/procevent-inbox/$SID.2.handled" \
  "a lock-busy reconcile acknowledged the captured result"
assert_absent "$PARENT/state/remote-replies/ios.2.autohandle-failures" \
  "a lock-busy autohandle counted a handling failure"
assert_no_grep 'remote-reply-autohandle-ios' "$PARENT/state/ios.status" \
  "a lock-busy autohandle emitted a blocked line"
# `arm` itself waits on the lifecycle lock, so prove the pending-capture skip
# after releasing it; the un-ingested capture still keeps arming a no-op.
release_lifecycle_lock
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "skipped: $SID capture pending (sequence 2)" \
  "arming with an unhandled capture did not report the pending generation"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "arming with an unhandled capture stacked a duplicate registration"
[ "$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" | wc -l | tr -d ' ')" = 2 ] \
  || fail "arming with an unhandled capture produced a duplicate generation"
pass "AC4/AC6: a held lifecycle lock parks arming without a duplicate generation or a counted failure"

# A handle whose re-arm fails still commits ingest but must not record handled.
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
set +e
remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO" > "$TMP_ROOT/handle-arm-fail.out" 2>&1
handle_arm_rc=$?
set -e
[ "$handle_arm_rc" -ne 0 ] || fail "reply handling acknowledged a result whose re-arm failed"
assert_grep "done [corr=$INITIAL_CORR_UPPER]" "$PARENT/state/ios.status" \
  "the first reply survived the failed re-arm"
assert_grep 'ingested: ios appended=1' "$TMP_ROOT/handle-arm-fail.out" \
  "failed re-arm did not commit the reply before retry"
assert_absent "$PARENT/state/procevent-inbox/$SID.2.handled" \
  "a failed re-arm still recorded the result handled"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"

# A later reconcile retries the pending result: the existing receipt short-
# circuits ingest, the route re-arms, and the marker lands - still with no
# agent turn.
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$reconcile_out" 'published=1' "failed re-arm did not leave the result eligible for retry"
wait_handled 2
assert_present "$PARENT/state/procevent/$SID.source" \
  "reconcile autohandle did not re-arm the reply source"
assert_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" \
  "the retried reply never reached parent status"
out=$(remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO")
assert_contains "$out" 'ingested: ios appended=0' "retried reply ingest was not idempotent"
assert_contains "$out" 'already-handled: remote-reply-ios 2' \
  "reconcile-autohandled generation was not reported as already acknowledged"
pass "AC1: a reconcile retries automatic handling, re-arms, and acknowledges the recovered capture"

# AC5: `fm-procevent.sh handled` refuses a captured result that was never
# ingested while the cursor cannot cover it; a stale duplicate fully covered
# by the cursor is allowed; a repeat stays 'already-handled'.
hold_lifecycle_lock ios
printf 'working [corr=2222222222222222]: third generation\n' \
  >> "$REMOTE/state/parent-replies.status"
capture_delta 3
set +e
gate_out=$(remote_env "$ROOT/bin/fm-procevent.sh" handled "$SID" 3 2>&1)
gate_rc=$?
set -e
[ "$gate_rc" -ne 0 ] || fail "handled acknowledged a captured remote reply before it was ingested"
assert_contains "$gate_out" 'no ingest receipt' \
  "a refused remote reply acknowledgement did not name the missing receipt"
assert_absent "$PARENT/state/procevent-inbox/$SID.3.handled" \
  "a refused remote reply acknowledgement still wrote the marker"
release_lifecycle_lock
remote_env "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
wait_handled 3
assert_grep 'working [corr=2222222222222222]' "$PARENT/state/ios.status" \
  "the gated reply was never ingested after the lock cleared"
out=$(remote_env "$ROOT/bin/fm-procevent.sh" handled "$SID" 3)
assert_contains "$out" 'already-handled: remote-reply-ios 3' \
  "repeating a remote reply acknowledgement did not stay idempotent"
pass "AC5: handled refuses an un-ingested remote reply capture and stays idempotent after ingest"

# A stale duplicate generation covered by the committed cursor is allowed:
# no receipt exists for it, so the gate must prove coverage, and the result
# replays as superseded rather than re-ingested.
craft_delta_result() { # <payload-file> <result-file>
  local payload=$1 out=$2 from fhash thash phash pbytes prefix
  from=$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/ios.cursor")
  fhash=$(sed -n 's/^prefix_sha256=//p' "$PARENT/state/remote-replies/ios.cursor")
  pbytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  phash=$(sha256_file "$payload")
  prefix="$TMP_ROOT/.craft-prefix"
  head -c "$from" "$REMOTE/state/parent-replies.status" > "$prefix"
  cat "$payload" >> "$prefix"
  thash=$(sha256_file "$prefix")
  {
    printf 'schema=fm-remote-delta.v1\nstatus=delta\n'
    printf 'path=state/parent-replies.status\n'
    printf 'from_offset=%s\nto_offset=%s\n' "$from" "$((from + pbytes))"
    printf 'from_prefix_sha256=%s\nto_prefix_sha256=%s\n' "$fhash" "$thash"
    printf 'payload_sha256=%s\npayload_bytes=%s\nreason=\n\n' "$phash" "$pbytes"
    cat "$payload"
  } > "$out"
}

cp "$RESULT" "$PARENT/state/procevent-inbox/$SID.90.result"
printf 'remote-reply\n' > "$PARENT/state/procevent-inbox/$SID.90.adapter"
out=$(remote_env "$ROOT/bin/fm-procevent.sh" handled "$SID" 90)
assert_contains "$out" 'handled: remote-reply-ios 90' \
  "a cursor-covered stale duplicate was refused acknowledgement"
out=$(remote_env "$ADAPTER" handle ios 90 "$PARENT/state/procevent-inbox/$SID.90.result")
assert_contains "$out" 'superseded: ios seq=90' \
  "a covered stale duplicate was re-ingested instead of skipped"
out=$(remote_env "$ROOT/bin/fm-procevent.sh" handled "$SID" 90)
assert_contains "$out" 'already-handled: remote-reply-ios 90' \
  "a covered stale duplicate was not acknowledged idempotently"
pass "AC5: a cursor-covered stale duplicate acknowledges once and replays as superseded"

# Autonomous lifecycle reports are valid status input but cannot resolve a
# marked parent request, even when a corr-like substring names it.
AUTONOMOUS_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "await autonomous report")
fm_pending_reply_mark_delivered "$PARENT/state" "$AUTONOMOUS_CORR" \
  || fail "could not create autonomous reply expectation"
printf 'blocked [key=remote-review]: waiting for external review\ndone: notcorr=%s is not a parent reply\ndone: not-corr=%s is not a parent reply\ndone: not.corr=%s is not a parent reply\ndone: not[corr=%s] is not a parent reply\n' "$AUTONOMOUS_CORR" "$AUTONOMOUS_CORR" "$AUTONOMOUS_CORR" "$AUTONOMOUS_CORR" \
  >> "$REMOTE/state/parent-replies.status"
capture_delta 4
wait_handled 4
assert_grep 'blocked [key=remote-review]: waiting for external review' "$PARENT/state/ios.status" \
  "autonomous lifecycle report did not reach parent status"
assert_grep "done: notcorr=$AUTONOMOUS_CORR is not a parent reply" "$PARENT/state/ios.status" \
  "corr-like autonomous report did not reach parent status"
assert_grep "done: not-corr=$AUTONOMOUS_CORR is not a parent reply" "$PARENT/state/ios.status" \
  "punctuated corr-like autonomous report did not reach parent status"
assert_grep "done: not.corr=$AUTONOMOUS_CORR is not a parent reply" "$PARENT/state/ios.status" \
  "dotted corr-like autonomous report did not reach parent status"
assert_grep "done: not[corr=$AUTONOMOUS_CORR] is not a parent reply" "$PARENT/state/ios.status" \
  "embedded corr-like autonomous report did not reach parent status"
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
capture_delta 5
wait_handled 5
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

# A structured status line may carry a decision key AND a correlation token
# before the colon, in either order.
KEYED_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "await keyed correlated report")
fm_pending_reply_mark_delivered "$PARENT/state" "$KEYED_CORR" \
  || fail "could not create keyed reply expectation"
printf 'working [key=qa-gate] [corr=%s]: final validation under way\nresolved [corr=%s] [key=qa-gate]: final validation passed\n' \
  "$KEYED_CORR" "$KEYED_CORR" >> "$REMOTE/state/parent-replies.status"
capture_delta 6
wait_handled 6
assert_grep "working [key=qa-gate] [corr=$KEYED_CORR]: final validation under way" "$PARENT/state/ios.status" \
  "keyed correlated report did not reach parent status"
assert_grep "resolved [corr=$KEYED_CORR] [key=qa-gate]: final validation passed" "$PARENT/state/ios.status" \
  "corr-first keyed report did not reach parent status"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$KEYED_CORR")" phase)" = resolved ] \
  || fail "keyed correlated report did not resolve its parent request"
[ "$(status_line_verb "working [key=qa-gate] [corr=$KEYED_CORR]: x")" = working ] \
  || fail "classifier did not treat the two-token prefix as structured"
[ "$(_fm_decision_key "working [key=qa-gate] [corr=$KEYED_CORR]: x")" = qa-gate ] \
  || fail "keyed correlated report folded to the default decision key"
pass "keyed correlated status lines ingest, resolve their request, and fold their key"

# AC2: per-line quarantine. One real captured delta mixes valid UTF-8 status
# text, a valid multi-token line resolving a pending request, and rejected
# lines - arbitrary and glued bracket tokens, an em-dash-corrupted control,
# and a line whose only correlation is on rejected bytes. Valid lines append
# in order; each rejected line is quarantined byte-exact and reported once
# with its reason, SHA-256, and byte count; the cursor still advances.
QUAR_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "await quarantine-mix report")
LOST_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "await rejected-only report")
fm_pending_reply_mark_delivered "$PARENT/state" "$QUAR_CORR" \
  || fail "could not create quarantine-mix reply expectation"
fm_pending_reply_mark_delivered "$PARENT/state" "$LOST_CORR" \
  || fail "could not create rejected-only reply expectation"
{
  printf 'working [note=one]: zz-arbitrary bracket is not structured\n'
  printf 'working [key=a][corr=b]: zz-glued tokens are not structured\n'
  printf 'working: zz-première passe — em dash et «guillemets»\n'
  printf 'resolved [key=mix-gate] [corr=%s]: zz-gate passed\n' "$QUAR_CORR"
  printf 'done [corr=%s]: zz-bidi \342\200\256 reorder\n' "$LOST_CORR"
  printf 'done: zz-del \177 char\n'
} > "$TMP_ROOT/mix.payload"
cat "$TMP_ROOT/mix.payload" >> "$REMOTE/state/parent-replies.status"
capture_delta 7
wait_handled 7
QDIR="$PARENT/state/remote-replies/ios.quarantine"
assert_grep 'working: zz-première passe — em dash et «guillemets»' "$PARENT/state/ios.status" \
  "a valid UTF-8 line in a mixed delta did not reach parent status"
assert_grep "resolved [key=mix-gate] [corr=$QUAR_CORR]: zz-gate passed" "$PARENT/state/ios.status" \
  "a valid multi-token line in a mixed delta did not reach parent status"
assert_no_grep 'zz-arbitrary' "$PARENT/state/ios.status" \
  "a rejected bracket line reached the parent status channel"
assert_no_grep 'zz-glued' "$PARENT/state/ios.status" \
  "a rejected glued-token line reached the parent status channel"
assert_no_grep 'zz-bidi' "$PARENT/state/ios.status" \
  "a bidi-corrupted line reached the parent status channel"
assert_no_grep 'zz-del' "$PARENT/state/ios.status" \
  "a control-byte line reached the parent status channel"
[ -d "$QDIR" ] || fail "rejected lines were not quarantined"
qmode=$(stat -c '%a' "$QDIR")
[ "$qmode" = 700 ] || fail "quarantine directory is not mode 700 (got $qmode)"
# Quarantine names use the raw line index; compare byte-exactly.
for qi in 1 2 5 6; do
  qf=$(find "$QDIR" -name "7.$qi.line" -print -quit)
  [ -n "$qf" ] || fail "rejected line $qi was not quarantined as $QDIR/7.$qi.line"
  printf '%s' "$(sed -n "${qi}p" "$TMP_ROOT/mix.payload")" > "$TMP_ROOT/mix-line-$qi"
  cmp -s "$qf" "$TMP_ROOT/mix-line-$qi" \
    || fail "quarantined line $qi is not byte-identical to the rejected bytes"
  qfmode=$(stat -c '%a' "$qf")
  [ "$qfmode" = 600 ] || fail "quarantined line $qi is not mode 600 (got $qfmode)"
done
[ "$(find "$QDIR" -name '7.*.line' | wc -l | tr -d ' ')" = 4 ] \
  || fail "an unexpected number of mixed-delta lines was quarantined"
quar_count=$(grep -cF 'key=remote-reply-quarantine-ios-7' "$PARENT/state/ios.status" || true)
[ "$quar_count" = 4 ] \
  || fail "a quarantined line did not produce exactly one blocked notice (got $quar_count)"
for qi in 1 2 5 6; do
  qf="$QDIR/7.$qi.line"
  qhash=$(sha256_file "$qf")
  qbytes=$(LC_ALL=C wc -c < "$qf" | tr -d ' ')
  case "$qi" in 1|2) qreason=not-a-status-line ;; *) qreason=forbidden-character ;; esac
  assert_grep "blocked [key=remote-reply-quarantine-ios-7]: remote reply line rejected ($qreason, sha256=$qhash, bytes=$qbytes)" \
    "$PARENT/state/ios.status" \
    "quarantined line $qi was not reported with its reason, sha256, and byte count"
done
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$QUAR_CORR")" phase)" = resolved ] \
  || fail "a valid line in a quarantined delta did not resolve its request"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$LOST_CORR")" phase)" = awaiting_report ] \
  || fail "a rejected line's correlation resolved a parent request"
quar_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$quar_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "a partially rejected delta did not advance the cursor"
assert_present "$PARENT/state/remote-replies/ios.7.ingested" \
  "a partially rejected delta left no ingest receipt"
pass "AC2: rejected lines quarantine byte-exactly while valid lines ingest, resolve, and advance the cursor"

# The next delta after a quarantined batch ingests normally.
printf 'done: zz-after-quarantine clean line\n' >> "$REMOTE/state/parent-replies.status"
capture_delta 8
wait_handled 8
assert_grep 'done: zz-after-quarantine clean line' "$PARENT/state/ios.status" \
  "the delta after a quarantined batch did not ingest"
pass "a delta following a quarantined batch ingests normally"

# Disarm while the adhoc crafts run: a still-armed detached runner would capture
# the cursor-covered payload appends as fresh generations from its stale offset
# and spend the sequence space the doc-fetch case below relies on.
remote_env "$ROOT/bin/fm-procevent.sh" retire "$SID" >/dev/null
wait_unclaimed

# Per-line rejection reasons under adhoc `ingest` (no capture sequence): each
# crafted delta quarantines one malformed line, advances the cursor, and
# produces one blocked notice. Payload bytes are appended to the remote log
# afterward so the committed cursor still proves the real prefix.
status_lines_before=$(grep -c '' "$PARENT/state/ios.status" || true)
printf 'done: truncated \342\200 sequence\n' > "$TMP_ROOT/badutf8.payload"
printf 'done: delete \177 char\n' > "$TMP_ROOT/delchar.payload"
printf 'done: zero \342\200\213 width\n' > "$TMP_ROOT/zwsp.payload"
printf 'done: nel \302\205 char\n' > "$TMP_ROOT/c1.payload"
printf 'done: line \342\200\250 sep\n' > "$TMP_ROOT/lsep.payload"
printf 'done: bom \357\273\277 char\n' > "$TMP_ROOT/feff.payload"
printf 'done: vertical \013 tab\n' > "$TMP_ROOT/vtab.payload"
printf 'done: isolate \342\201\167 char\n' > "$TMP_ROOT/isolate.payload"
{ printf 'done: '; head -c 2050 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$TMP_ROOT/toolong.payload"
for bad_payload in badutf8 delchar zwsp c1 lsep feff vtab isolate toolong; do
  craft_delta_result "$TMP_ROOT/$bad_payload.payload" "$TMP_ROOT/$bad_payload.result"
  out=$(remote_env "$ADAPTER" ingest ios "$TMP_ROOT/$bad_payload.result") \
    || fail "adhoc ingest of a rejectable line failed: $bad_payload"
  assert_contains "$out" 'appended=0' "a rejected line was appended: $bad_payload"
  cat "$TMP_ROOT/$bad_payload.payload" >> "$REMOTE/state/parent-replies.status"
done
[ "$(grep -c '' "$PARENT/state/ios.status" || true)" = "$((status_lines_before + 9))" ] \
  || fail "rejected charsets appended raw content or duplicated a quarantine notice"
assert_grep '(invalid-utf8,' "$PARENT/state/ios.status" "truncated UTF-8 was not quarantined as invalid-utf8"
[ "$(grep -c '(invalid-utf8,' "$PARENT/state/ios.status" || true)" = 2 ] \
  || fail "malformed UTF-8 lines were not each quarantined as invalid-utf8"
[ "$(grep -c '(forbidden-character,' "$PARENT/state/ios.status" || true)" = 8 ] \
  || fail "controls, format characters, and separators were not quarantined as forbidden-character"
assert_grep '(too-long,' "$PARENT/state/ios.status" "an over-long line was not quarantined as too-long"
assert_no_grep 'truncated ' "$PARENT/state/ios.status" "rejected bytes reached the parent status channel"
adhoc_quar=$(find "$QDIR" -name 'adhoc-*' -type f | wc -l | tr -d ' ')
[ "$adhoc_quar" = 9 ] || fail "adhoc ingest did not quarantine each rejected line (got $adhoc_quar)"
pass "ingest quarantines malformed UTF-8, controls, format characters, and over-long lines"

# A digest-valid unknown lifecycle verb is quarantined as not-a-status-line
# under adhoc ingest. Recalculate its payload commitment so the behavioral
# assertion is specifically about status validation, not incidental digest
# failure.
BAD_RESULT="$TMP_ROOT/bad.result"
printf 'unknown: not a lifecycle verb\n' > "$TMP_ROOT/bad.payload"
craft_delta_result "$TMP_ROOT/bad.payload" "$BAD_RESULT"
out=$(remote_env "$ADAPTER" ingest ios "$BAD_RESULT") \
  || fail "adhoc ingest of an unknown lifecycle verb failed"
assert_contains "$out" 'appended=0' "a status line with an unknown verb was appended"
assert_grep '(not-a-status-line,' "$PARENT/state/ios.status" \
  "an unknown lifecycle verb was not quarantined as not-a-status-line"
assert_no_grep 'not a lifecycle verb' "$PARENT/state/ios.status" \
  "an unknown lifecycle verb reached the parent status channel"
# The adhoc ingest committed the cursor past this payload's range, so the same
# bytes must land in the remote log to keep the prefix hash provable.
cat "$TMP_ROOT/bad.payload" >> "$REMOTE/state/parent-replies.status"
pass "ingest quarantines invalid lifecycle payloads even when their transport digest is valid"

# AC3+AC6: a document-fetch failure keeps the capture retryable. Each
# autohandle counts one failure; exactly one named blocked line appears at the
# configured limit; a repaired document then lets a later reconcile ingest
# cleanly and clear the counter. Re-arm the source retired before the adhoc
# crafts and let any detached runner settle first, so the doc line lands in
# exactly one fresh generation.
remote_env "$ADAPTER" arm ios >/dev/null
wait_unclaimed
DOC_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "await document report")
fm_pending_reply_mark_delivered "$PARENT/state" "$DOC_CORR" \
  || fail "could not create document reply expectation"
printf 'done [corr=%s]: see data/reply/missing.md\n' "$DOC_CORR" \
  >> "$REMOTE/state/parent-replies.status"
capture_delta 9
assert_absent "$PARENT/state/procevent-inbox/$SID.9.handled" \
  "a failed document fetch acknowledged the capture"
assert_absent "$PARENT/state/remote-replies/ios.9.ingested" \
  "a failed document fetch left an ingest receipt"
counter_file="$PARENT/state/remote-replies/ios.9.autohandle-failures"
wait_for "$counter_file" || fail "a failed autohandle left no failure counter"
[ "$(sed -n 's/^count=//p' "$counter_file" | head -1)" = 1 ] \
  || fail "the first autohandle failure was not counted once"
assert_no_grep 'remote-reply-autohandle-ios-9' "$PARENT/state/ios.status" \
  "a first autohandle failure already escalated"
remote_env "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
[ "$(sed -n 's/^count=//p' "$counter_file" | head -1)" = 2 ] \
  || fail "the second autohandle failure was not counted"
assert_no_grep 'remote-reply-autohandle-ios-9' "$PARENT/state/ios.status" \
  "autohandle failures escalated before the configured limit"
remote_env "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
[ "$(sed -n 's/^count=//p' "$counter_file" | head -1)" = 3 ] \
  || fail "the third autohandle failure was not counted"
assert_grep 'blocked [key=remote-reply-autohandle-ios-9]: remote reply sequence 9 for ios failed automatic handling 3 consecutive times' \
  "$PARENT/state/ios.status" \
  "the autohandle failure limit did not produce one named blocked line"
assert_grep 'data/reply/missing.md' "$PARENT/state/ios.status" \
  "the autohandle escalation did not name the failing fetch"
remote_env "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
[ "$(grep -cF 'key=remote-reply-autohandle-ios-9' "$PARENT/state/ios.status" || true)" = 1 ] \
  || fail "autohandle failures past the limit escalated a second time"
printf '# Found it\n' > "$REMOTE/data/reply/missing.md"
remote_env "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
wait_handled 9
assert_grep "done [corr=$DOC_CORR]: see data/remote-secondmates/ios/data/reply/missing.md" \
  "$PARENT/state/ios.status" \
  "the repaired document reply was never ingested"
assert_absent "$counter_file" "a recovered autohandle left its failure counter"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PARENT/state" "$DOC_CORR")" phase)" = resolved ] \
  || fail "the recovered document reply did not resolve its parent request"
pass "AC3/AC6: a transient ingest failure retries, escalates once at the limit, and recovers"

# AC4: ensure-armed repairs an unarmed live route without SSH and skips
# dormant and continuity-pinned routes.
remote_env "$ROOT/bin/fm-procevent.sh" retire "$SID" >/dev/null 2>&1 || true
wait_unclaimed
assert_absent "$PARENT/state/procevent/$SID.source" \
  "the fixture still had the reply source registered"
# A live remote route is a state/<id>.meta record with remote_host, exactly the
# way bootstrap enumerates them.
printf 'window=fm-remote:w1:p1\nkind=secondmate\nremote_host=remote-mac\nhome=%s\n' "$REMOTE" \
  > "$PARENT/state/ios.meta"
# A second remote route parked in a dormant lifecycle stays skipped.
printf 'window=fm-remote:w2:p1\nkind=secondmate\nremote_host=remote-mac\nremote_backend=runpod\nhome=%s\n' "$REMOTE" \
  > "$PARENT/state/calm.meta"
mkdir -p "$PARENT/data/runpod"
printf 'lifecycle=suspended\n' > "$PARENT/data/runpod/calm.meta"
ensure_out=$(remote_env "$ADAPTER" ensure-armed)
assert_contains "$ensure_out" "armed: $SID offset=" \
  "ensure-armed did not repair an unarmed live remote route"
assert_contains "$ensure_out" 'skipped: remote-reply-calm suspended' \
  "ensure-armed armed a suspended remote route"
assert_absent "$PARENT/state/procevent/remote-reply-calm.source" \
  "ensure-armed registered a suspended remote route"
assert_present "$PARENT/state/procevent/$SID.source" \
  "ensure-armed left the live route unregistered"
remote_env "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
pass "AC4: ensure-armed repairs a live route and skips a suspended one"

# AC2 continuity: the adapter re-armed at the committed cursor. Truncation is
# detected from the next blocking source, escalated once with the sequence
# named, and pinned until an operator rebases the cursor - arm and
# ensure-armed both refuse.
printf 'failed [corr=fedcba9876543210]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
capture_delta 10
RESULT_TEN="$PARENT/state/procevent-inbox/$SID.10.result"
[ "$(remote_env "$ADAPTER" classify "$RESULT_TEN")" = continuity-broken ] \
  || fail "truncated source was not classified as a continuity break"
wait_handled 10
assert_grep 'blocked [key=remote-reply-continuity-ios]: remote reply continuity broke for ios at sequence 10 (truncated)' \
  "$PARENT/state/ios.status" "continuity break did not escalate with its sequence"
assert_present "$PARENT/state/remote-replies/ios.continuity-broken" \
  "continuity break left no durable marker"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "continuity break was re-armed without an operator rebase"
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" 'skipped: remote-reply-ios continuity broken at sequence 10' \
  "a continuity-broken route was re-armed"
ensure_out=$(remote_env "$ADAPTER" ensure-armed)
assert_contains "$ensure_out" 'skipped: remote-reply-ios continuity broken at sequence 10' \
  "ensure-armed re-armed a continuity-broken route"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "a continuity-broken route gained a registration"
remote_env "$ADAPTER" ingest ios "$RESULT_TEN" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "a replayed continuity break escalated twice"

# An operator rebase clears the pin: rewrite the cursor to the new log's end,
# and arm proceeds from there.
log_bytes=$(wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
head -c "$log_bytes" "$REMOTE/state/parent-replies.status" > "$TMP_ROOT/log-prefix"
log_hash=$(sha256_file "$TMP_ROOT/log-prefix")
printf 'schema=fm-remote-reply-cursor.v1\noffset=%s\nprefix_sha256=%s\n' \
  "$log_bytes" "$log_hash" > "$PARENT/state/remote-replies/ios.cursor"
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=$log_bytes" \
  "a rebased cursor did not clear the continuity pin"
assert_absent "$PARENT/state/remote-replies/ios.continuity-broken" \
  "the continuity marker survived an operator rebase"
pass "AC2: an operator rebase clears the continuity pin and the route arms at the new offset"

echo "ALL TESTS PASSED"
