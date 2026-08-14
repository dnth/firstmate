#!/usr/bin/env bash
# Recovery reconciliation resolves a fetched correlated reply and closes the
# exact legacy keyless blocker that the same pending-reply record opened.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pending-reply-sleep-reconcile)
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE"

corr=$(fm_pending_reply_create "$HOME_DIR" "$STATE" ios "recover the remote reply") \
  || fail "the pending reply fixture could not be created"
fm_pending_reply_mark_delivered "$STATE" "$corr" \
  || fail "the pending reply fixture could not be marked delivered"
rec=$(fm_pending_reply_path "$STATE" "$corr")
fm_pending_reply_set "$rec" recovery_delivery_outcome failed
fm_pending_reply_set "$rec" phase escalated
{
  printf 'blocked: pending-reply-recovery-delivery-failed: task=ios pending-reply-id=%s request=recover the remote reply\n' \
    "$corr"
  printf 'blocked [key=pending-reply-%s]: pending-reply-recovery-delivery-failed: task=ios pending-reply-id=%s request=recover the remote reply\n' \
    "$corr" "$corr"
  printf 'done [corr=%s]: fetched remote completion\n' "$corr"
} >> "$STATE/ios.status"

fm_pending_reply_reconcile_task "$STATE" ios "$STATE/ios.status" \
  || fail "the handled recovery reply did not reconcile"
[ "$(fm_pending_reply_get "$rec" phase)" = resolved ] \
  || fail "the recovery-delivery-failed record remained unresolved"
[ -z "$(status_open_decisions "$STATE/ios.status")" ] \
  || fail "the keyed and exact legacy pending-reply blockers did not both close"

printf 'blocked: investigate external reference pending-reply-id=%s\n' "$corr" \
  >> "$STATE/unrelated.status"
fm_pending_reply_close_decision "$STATE/unrelated.status" "$corr" ios "recover the remote reply" \
  || fail "the unrelated-decision reconciliation check failed"
[ -n "$(status_open_decisions "$STATE/unrelated.status")" ] \
  || fail "an unrelated keyless decision referencing the correlation id was closed"

pass "handled recovery replies close only their keyed and exact legacy blockers"
