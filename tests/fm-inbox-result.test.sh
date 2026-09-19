#!/usr/bin/env bash
# Behavior tests for durable trusted-local inbox result delivery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox-result)
INBOX="$ROOT/bin/fm-inbox.sh"
RESULT="$ROOT/bin/fm-inbox-result.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TARGET='hermes:telegram:-1001234567890:77'

home_env() {
  local home=$1
  shift
  PATH="$BASE_PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$@"
}

setup_home() {
  local home=$1
  mkdir -p "$home/config"
  printf '%s\n' "$TARGET" > "$home/config/inbox-result-targets"
  chmod 0600 "$home/config/inbox-result-targets"
}

write_adapter() {
  local home=$1
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/result-adapter" <<'ADAPTER'
#!/usr/bin/env bash
set -eu
payload=
target=
key=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --payload-file) payload=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    --idempotency-key) key=$2; shift 2 ;;
    *) exit 64 ;;
  esac
done
[ -f "$payload" ] || exit 64
jq -e '.schema == "firstmate.inbox-result.v1"' "$payload" >/dev/null || exit 64
printf '%s\t%s\n' "$key" "$target" >> "$FM_ADAPTER_LOG"
case "${FM_ADAPTER_MODE:-success}" in
  success) printf '{"ok":true,"message_id":"msg-%s"}\n' "$key" ;;
  transient) exit 75 ;;
  permanent) exit 64 ;;
  ambiguous) exit 70 ;;
  *) exit 70 ;;
esac
ADAPTER
  chmod +x "$home/fakebin/result-adapter"
}

new_linked_note() {
  local home=$1 correlation=${2:-request-42}
  home_env "$home" "$INBOX" note \
    --reply-target "$TARGET" --correlation-id "$correlation" \
    "Review the durable brief at $home/brief.md" | sed 's/^noted //'
}

publish_result() {
  local home=$1 id=$2
  shift 2
  printf 'All requested work completed.\n' > "$home/summary.txt"
  FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" \
  FM_ADAPTER_LOG="$home/adapter.log" \
    home_env "$home" "$RESULT" publish --note-id "$id" --status completed \
      --summary-file "$home/summary.txt" "$@"
}

test_reply_metadata_and_plain_compatibility() {
  local home linked plain dash_plain drained
  home="$TMP_ROOT/metadata"
  setup_home "$home"
  linked=$(new_linked_note "$home") || fail "linked note must succeed"
  plain=$(home_env "$home" "$INBOX" note "legacy plain note" | sed 's/^noted //') \
    || fail "plain note must remain supported"
  dash_plain=$(home_env "$home" "$INBOX" note "-legacy flag-like note" | sed 's/^noted //') \
    || fail "legacy messages beginning with a dash must remain supported"

  jq -e --arg id "$linked" --arg target "$TARGET" \
    '.schema == "firstmate.inbox-note.v1" and .note_id == $id and
     .request_note_id == $id and .correlation_id == "request-42" and
     .reply_target == $target' \
    "$home/state/inbox/$linked.note" >/dev/null \
    || fail "linked note must persist immutable correlation and reply metadata"
  assert_grep 'legacy plain note' "$home/state/inbox/$plain.note" \
    "unlinked notes must retain the legacy plain format"
  assert_grep '-legacy flag-like note' "$home/state/inbox/$dash_plain.note" \
    "legacy flag-like messages must retain the plain format"
  drained=$(home_env "$home" "$INBOX" drain) || fail "drain must render mixed notes"
  assert_contains "$drained" "correlation: request-42" "drain must expose correlation"
  assert_contains "$drained" "reply-target: $TARGET" "drain must expose reply target"
  assert_contains "$drained" "legacy plain note" "drain must preserve old notes"
  home_env "$home" "$INBOX" drain --ack "$linked" >/dev/null \
    || fail "linked note ack must succeed"
  jq -e '.reply_target != null' "$home/state/inbox/handled/$linked.note" >/dev/null \
    || fail "ack must retain linked note metadata"
  pass "reply metadata is durable while legacy notes remain compatible"
}

test_malformed_and_unauthorized_targets_fail_closed() {
  local home id note tampered
  home="$TMP_ROOT/targets"
  setup_home "$home"
  if home_env "$home" "$INBOX" note --reply-target 'hermes:telegram:../escape' \
      --correlation-id request-1 "bad" >/dev/null 2>"$home/bad.err"; then
    fail "malformed reply targets must fail"
  fi
  assert_grep 'invalid reply target' "$home/bad.err" "malformed target rejection must be explicit"
  if home_env "$home" "$INBOX" note --reply-target 'hermes:telegram:-999:1' \
      --correlation-id request-2 "unauthorized" >/dev/null 2>"$home/deny.err"; then
    fail "non-allowlisted reply targets must fail"
  fi
  assert_grep 'reply target is not authorized' "$home/deny.err" \
    "unauthorized target rejection must be explicit"
  [ ! -d "$home/state/inbox" ] || [ -z "$(find "$home/state/inbox" -name '*.note' -print)" ] \
    || fail "rejected targets must not create notes"

  id=$(new_linked_note "$home" malformed-envelope-1)
  note="$home/state/inbox/$id.note"
  tampered="$home/state/inbox/.tampered-note"
  jq '.correlation_id = null' "$note" > "$tampered"
  chmod 0600 "$tampered"
  mv "$tampered" "$note"
  if publish_result "$home" "$id" >/dev/null 2>"$home/envelope.err"; then
    fail "malformed persisted note envelopes must fail closed"
  fi
  assert_grep 'no supported reply metadata' "$home/envelope.err" \
    "malformed envelope rejection must be explicit"
  assert_absent "$home/state/inbox-results/$id.result.json" \
    "malformed envelope must not publish a result"
  pass "malformed and unauthorized reply targets fail closed"
}

test_publish_deliver_and_duplicate_suppression() {
  local home id out result receipt status
  home="$TMP_ROOT/success"
  setup_home "$home"
  write_adapter "$home"
  : > "$home/adapter.log"
  id=$(new_linked_note "$home")
  printf 'artifact body\n' > "$home/artifact.txt"

  out=$(publish_result "$home" "$id" --artifact "$home/artifact.txt") \
    || fail "publish must persist and deliver"
  assert_contains "$out" "delivered $id" "publish must report delivery"
  result="$home/state/inbox-results/$id.result.json"
  receipt="$home/state/inbox-results/$id.receipt.json"
  assert_present "$result" "result must exist before/after delivery"
  assert_present "$receipt" "successful delivery must persist a receipt"
  jq -e --arg artifact "$home/artifact.txt" \
    '.status == "completed" and .summary == "All requested work completed." and
     .artifacts == [$artifact]' "$result" >/dev/null \
    || fail "result envelope must contain status, summary, and artifacts"
  [ "$(wc -l < "$home/adapter.log" | tr -d ' ')" = 1 ] \
    || fail "first publication must invoke the adapter once"

  out=$(publish_result "$home" "$id" --artifact "$home/artifact.txt") \
    || fail "identical repeat publication must be idempotent"
  assert_contains "$out" "already-published $id" "repeat must reuse immutable result"
  FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
    home_env "$home" "$RESULT" deliver --note-id "$id" >/dev/null \
    || fail "repeat delivery after receipt must succeed"
  [ "$(wc -l < "$home/adapter.log" | tr -d ' ')" = 1 ] \
    || fail "receipt must suppress duplicate user-visible delivery"
  cp "$receipt" "$home/receipt.backup"
  printf '{}\n' > "$receipt"
  if FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
      home_env "$home" "$RESULT" deliver --note-id "$id" >/dev/null 2>"$home/receipt.err"; then
    fail "malformed receipts must not suppress delivery as if they were valid"
  fi
  assert_grep 'invalid delivery receipt' "$home/receipt.err" \
    "malformed receipt rejection must be explicit"
  mv "$home/receipt.backup" "$receipt"
  status=$(home_env "$home" "$RESULT" status --note-id "$id")
  assert_contains "$status" "$id	delivered	completed" \
    "status must expose the delivered terminal outcome"
  pass "results persist before delivery and receipts suppress duplicates"
}

test_restart_recovery_from_pending() {
  local home id out
  home="$TMP_ROOT/restart"
  setup_home "$home"
  write_adapter "$home"
  : > "$home/adapter.log"
  id=$(new_linked_note "$home" restart-1)

  out=$(publish_result "$home" "$id" --no-deliver) \
    || fail "no-deliver publication must persist"
  assert_contains "$out" "published $id" "no-deliver must report publication"
  assert_present "$home/state/inbox-results/$id.result.json" \
    "pending result must survive process exit"
  assert_absent "$home/state/inbox-results/$id.receipt.json" \
    "pending result must not have a receipt"

  FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
    home_env "$home" "$RESULT" deliver --note-id "$id" >/dev/null \
    || fail "fresh process must deliver a pending result"
  assert_present "$home/state/inbox-results/$id.receipt.json" \
    "restart recovery must persist receipt"
  [ "$(wc -l < "$home/adapter.log" | tr -d ' ')" = 1 ] \
    || fail "restart recovery must deliver exactly once"
  pass "pending results recover after restart"
}

test_definite_failure_and_retry() {
  local home id out
  home="$TMP_ROOT/retry"
  setup_home "$home"
  write_adapter "$home"
  : > "$home/adapter.log"
  id=$(new_linked_note "$home" retry-1)

  set +e
  out=$(FM_ADAPTER_MODE=transient publish_result "$home" "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "definite delivery failure must fail publication"
  assert_contains "$out" "delivery failed" "failure must be explicit"
  assert_present "$home/state/inbox-results/$id.failed.json" \
    "delivery failure must survive restart"
  assert_absent "$home/state/inbox-results/$id.receipt.json" \
    "failed delivery must not forge a receipt"

  FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
    home_env "$home" "$RESULT" retry --note-id "$id" >/dev/null \
    || fail "definite no-delivery failure must be retryable"
  assert_present "$home/state/inbox-results/$id.receipt.json" \
    "successful retry must persist receipt"
  assert_absent "$home/state/inbox-results/$id.failed.json" \
    "successful retry must clear failed state"
  pass "definite failures persist and retry safely"
}

test_ambiguous_failure_requires_confirmation() {
  local home id
  home="$TMP_ROOT/ambiguous"
  setup_home "$home"
  write_adapter "$home"
  : > "$home/adapter.log"
  id=$(new_linked_note "$home" ambiguous-1)

  if FM_ADAPTER_MODE=ambiguous publish_result "$home" "$id" >/dev/null 2>&1; then
    fail "ambiguous delivery must not report success"
  fi
  assert_present "$home/state/inbox-results/$id.posting" \
    "ambiguous delivery must retain the posting marker"
  if FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
      home_env "$home" "$RESULT" retry --note-id "$id" >/dev/null 2>"$home/retry.err"; then
    fail "ambiguous delivery must not retry automatically"
  fi
  assert_grep 'confirm-ambiguous' "$home/retry.err" \
    "ambiguous recovery must require explicit confirmation"
  FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
    home_env "$home" "$RESULT" retry --note-id "$id" --confirm-ambiguous >/dev/null \
    || fail "confirmed ambiguous recovery must retry"
  assert_present "$home/state/inbox-results/$id.receipt.json" \
    "confirmed recovery must persist receipt"
  pass "ambiguous delivery fails closed against duplicate replies"
}

test_restart_recovery_from_posting_gap() {
  local home id status
  home="$TMP_ROOT/posting-gap"
  setup_home "$home"
  write_adapter "$home"
  : > "$home/adapter.log"
  id=$(new_linked_note "$home" posting-gap-1)
  publish_result "$home" "$id" --no-deliver >/dev/null \
    || fail "pending result setup must succeed"
  printf 'interrupted-before-receipt\n' > "$home/state/inbox-results/$id.posting"

  status=$(home_env "$home" "$RESULT" status --note-id "$id")
  assert_contains "$status" "$id"$'\t'"ambiguous"$'\t'"completed" \
    "orphaned posting marker must expose ambiguous restart state"
  if FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
      home_env "$home" "$RESULT" retry --note-id "$id" >/dev/null 2>"$home/posting-retry.err"; then
    fail "orphaned posting marker must not retry without confirmation"
  fi
  assert_grep 'confirm-ambiguous' "$home/posting-retry.err" \
    "posting-gap recovery must require explicit confirmation"
  FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
    home_env "$home" "$RESULT" retry --note-id "$id" --confirm-ambiguous >/dev/null \
    || fail "confirmed posting-gap recovery must retry"
  assert_present "$home/state/inbox-results/$id.receipt.json" \
    "confirmed posting-gap recovery must persist receipt"
  pass "restart recovery handles pre-send posting gaps conservatively"
}

test_unsafe_artifacts_and_revoked_target_fail_closed() {
  local home id outside newline_artifact
  home="$TMP_ROOT/safety"
  setup_home "$home"
  write_adapter "$home"
  : > "$home/adapter.log"
  id=$(new_linked_note "$home" safety-1)
  outside="$home/outside.txt"
  printf 'outside\n' > "$outside"
  ln -s "$outside" "$home/link.txt"
  if publish_result "$home" "$id" --artifact "$home/link.txt" >/dev/null 2>"$home/artifact.err"; then
    fail "symlinked artifact must be rejected"
  fi
  assert_grep 'artifact must not be a symlink' "$home/artifact.err" \
    "unsafe artifact rejection must be explicit"
  assert_absent "$home/state/inbox-results/$id.result.json" \
    "invalid artifact must not publish a partial result"

  newline_artifact="$home/line"$'\n'"break.txt"
  printf 'newline path\n' > "$newline_artifact"
  if publish_result "$home" "$id" --artifact "$newline_artifact" >/dev/null 2>"$home/newline.err"; then
    fail "artifact paths containing record separators must be rejected"
  fi
  assert_grep 'unsafe artifact path' "$home/newline.err" \
    "record-separator artifact rejection must be explicit"
  assert_absent "$home/state/inbox-results/$id.result.json" \
    "newline artifact must not publish a partial result"

  publish_result "$home" "$id" --no-deliver >/dev/null \
    || fail "valid result publication must succeed"
  : > "$home/config/inbox-result-targets"
  if FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
      home_env "$home" "$RESULT" deliver --note-id "$id" >/dev/null 2>"$home/revoked.err"; then
    fail "revoked target must fail delivery"
  fi
  assert_grep 'reply target is not authorized' "$home/revoked.err" \
    "delivery must re-check recipient authority"
  assert_present "$home/state/inbox-results/$id.result.json" \
    "revoked recipient must not lose the durable result"
  [ ! -s "$home/adapter.log" ] || fail "revoked target must not reach adapter"
  pass "unsafe artifacts and revoked recipients fail closed without data loss"
}

test_publish_rejects_symlinked_summary_parent() {
  local home id outside
  home="$TMP_ROOT/summary-parent-symlink"
  setup_home "$home"
  id=$(new_linked_note "$home" summary-parent-1)
  outside="$home/outside"
  mkdir -p "$outside"
  printf 'outside summary\n' > "$outside/summary.txt"
  ln -s "$outside" "$home/summary-link"
  if FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" \
      home_env "$home" "$RESULT" publish --note-id "$id" --status completed \
      --summary-file "$home/summary-link/summary.txt" >/dev/null 2>"$home/summary.err"; then
    fail "summary files under symlinked parents must be rejected"
  fi
  assert_grep 'summary file must be a regular non-symlink file' "$home/summary.err" \
    "symlinked summary parent rejection must be explicit"
  assert_absent "$home/state/inbox-results/$id.result.json" \
    "symlinked summary parent must not publish a result"
  pass "publish rejects summaries under symlinked parents"
}

test_publish_preserves_summary_after_size_check() {
  local home id
  home="$TMP_ROOT/summary-size"
  setup_home "$home"
  write_adapter "$home"
  id=$(new_linked_note "$home" summary-size-1)
  printf 'Non-empty stable summary.\n' > "$home/summary.txt"
  FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
    home_env "$home" "$RESULT" publish --note-id "$id" --status completed \
      --summary-file "$home/summary.txt" --no-deliver >/dev/null \
    || fail "publication with a non-empty summary must succeed"
  jq -e '.summary == "Non-empty stable summary."' \
    "$home/state/inbox-results/$id.result.json" >/dev/null \
    || fail "summary-size validation must not consume the summary descriptor"
  pass "summary content survives stable descriptor size validation"
}

test_publish_rejects_fifo_summary_without_blocking() {
  local home id pid rc
  home="$TMP_ROOT/summary-fifo"
  setup_home "$home"
  id=$(new_linked_note "$home" summary-fifo-1)
  mkfifo "$home/summary.fifo"
  home_env "$home" "$RESULT" publish --note-id "$id" --status completed \
    --summary-file "$home/summary.fifo" >/dev/null 2>"$home/fifo.err" &
  pid=$!
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "FIFO summary validation must not block on open"
  fi
  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "FIFO summaries must be rejected"
  assert_grep 'summary file must be a regular non-symlink file' "$home/fifo.err" \
    "FIFO summary rejection must be explicit"
  pass "publish rejects FIFO summaries without blocking"
}

test_publish_rejects_symlinked_inbox_directory() {
  local home id outside
  home="$TMP_ROOT/inbox-directory-symlink"
  setup_home "$home"
  id=$(new_linked_note "$home" inbox-directory-1)
  outside="$home/outside-inbox"
  mkdir -p "$outside"
  mv "$home/state/inbox/$id.note" "$outside/$id.note"
  rmdir "$home/state/inbox/handled"
  rmdir "$home/state/inbox"
  ln -s "$outside" "$home/state/inbox"
  printf 'Must not publish.\n' > "$home/summary.txt"
  if home_env "$home" "$RESULT" publish --note-id "$id" --status completed \
      --summary-file "$home/summary.txt" >/dev/null 2>"$home/inbox.err"; then
    fail "symlinked inbox directories must be rejected"
  fi
  assert_grep 'inbox directory must not be a symlink' "$home/inbox.err" \
    "symlinked inbox rejection must be explicit"
  assert_absent "$home/state/inbox-results/$id.result.json" \
    "symlinked inbox must not publish a result"
  pass "publish rejects symlinked inbox directories"
}

test_publish_rejects_symlinked_handled_directory() {
  local home id outside
  home="$TMP_ROOT/handled-directory-symlink"
  setup_home "$home"
  id=$(new_linked_note "$home" handled-directory-1)
  home_env "$home" "$INBOX" drain --ack "$id" >/dev/null \
    || fail "handled note setup must succeed"
  outside="$home/outside-handled"
  mkdir -p "$outside"
  mv "$home/state/inbox/handled/$id.note" "$outside/$id.note"
  rmdir "$home/state/inbox/handled"
  ln -s "$outside" "$home/state/inbox/handled"
  printf 'Must not publish.\n' > "$home/summary.txt"
  if home_env "$home" "$RESULT" publish --note-id "$id" --status completed \
      --summary-file "$home/summary.txt" >/dev/null 2>"$home/handled.err"; then
    fail "symlinked handled directories must be rejected"
  fi
  assert_grep 'handled inbox directory must not be a symlink' "$home/handled.err" \
    "symlinked handled rejection must be explicit"
  assert_absent "$home/state/inbox-results/$id.result.json" \
    "symlinked handled directory must not publish a result"
  pass "publish rejects symlinked handled directories"
}

test_shipped_hermes_adapter_returns_to_declared_session() {
  local home id
  home="$TMP_ROOT/hermes-adapter"
  setup_home "$home"
  id=$(new_linked_note "$home" hermes-origin-1)
  printf 'Returned through Hermes.\n' > "$home/summary.txt"
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/hermes" <<'HERMES'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" > "$FM_HERMES_ARGS"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --file) cp "$2" "$FM_HERMES_MESSAGE"; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"success":true,"message_id":"origin-message-1"}\n'
HERMES
  chmod +x "$home/fakebin/hermes"

  HERMES_BIN="$home/fakebin/hermes" FM_HERMES_ARGS="$home/hermes.args" \
    FM_HERMES_MESSAGE="$home/hermes.message" \
    home_env "$home" "$RESULT" publish --note-id "$id" --status completed \
      --summary-file "$home/summary.txt" >/dev/null \
    || fail "shipped Hermes adapter must deliver a valid result"
  assert_grep 'telegram:-1001234567890:77' "$home/hermes.args" \
    "Hermes adapter must strip only the declarative hermes prefix"
  assert_grep 'FirstMate result: completed' "$home/hermes.message" \
    "Hermes message must expose terminal status"
  assert_grep 'Correlation: hermes-origin-1' "$home/hermes.message" \
    "Hermes message must preserve origin correlation"
  jq -e '.adapter_receipt.message_id == "origin-message-1"' \
    "$home/state/inbox-results/$id.receipt.json" >/dev/null \
    || fail "Hermes provider receipt must be durable"
  pass "shipped adapter returns a result through the declared Hermes session target"
}

test_shipped_hermes_adapter_rejects_non_delivery_success() {
  local home id mode
  for mode in skipped malformed; do
    home="$TMP_ROOT/hermes-adapter-$mode"
    setup_home "$home"
    id=$(new_linked_note "$home" "hermes-$mode-1")
    printf 'Must not be marked delivered.\n' > "$home/summary.txt"
    mkdir -p "$home/fakebin"
    cat > "$home/fakebin/hermes" <<'HERMES'
#!/usr/bin/env bash
set -eu
case "$FM_HERMES_MODE" in
  skipped) printf '{"success":true,"skipped":true,"note":"duplicate suppressed"}\n' ;;
  malformed) printf 'not-json\n' ;;
  *) exit 2 ;;
esac
HERMES
    chmod +x "$home/fakebin/hermes"

    if HERMES_BIN="$home/fakebin/hermes" FM_HERMES_MODE="$mode" \
        home_env "$home" "$RESULT" publish --note-id "$id" --status completed \
          --summary-file "$home/summary.txt" >/dev/null 2>"$home/publish.err"; then
      fail "Hermes $mode response must not be accepted as delivered"
    fi
    assert_present "$home/state/inbox-results/$id.result.json" \
      "Hermes $mode response must preserve the durable result"
    assert_absent "$home/state/inbox-results/$id.receipt.json" \
      "Hermes $mode response must not persist a delivery receipt"
    assert_present "$home/state/inbox-results/$id.failed.json" \
      "Hermes $mode response must persist retry state"
    jq -e '.classification == "ambiguous"' \
      "$home/state/inbox-results/$id.failed.json" >/dev/null \
      || fail "Hermes $mode response must require operator-confirmed retry"
  done
  pass "shipped adapter rejects skipped and malformed Hermes success output"
}

test_shipped_hermes_adapter_enforces_target_allowlist() {
  local home payload
  home="$TMP_ROOT/hermes-adapter-allowlist"
  setup_home "$home"
  payload="$home/result.json"
  jq -n --arg target 'hermes:telegram:-999:1' \
    '{schema:"firstmate.inbox-result.v1", note_id:"allowlist-1", request_note_id:"allowlist-1",
      correlation_id:"allowlist-1", reply_target:$target, status:"completed", summary:"no", artifacts:[]}' \
    > "$payload"
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/hermes" <<'HERMES'
#!/usr/bin/env bash
printf called > "$FM_HERMES_CALLED"
HERMES
  chmod +x "$home/fakebin/hermes"
  if FM_HOME="$home" HERMES_BIN="$home/fakebin/hermes" FM_HERMES_CALLED="$home/called" \
      "$ROOT/bin/fm-inbox-hermes-adapter.sh" --target 'hermes:telegram:-999:1' \
      --idempotency-key allowlist-1 --payload-file "$payload" >/dev/null 2>"$home/adapter.err"; then
    fail "direct Hermes adapter calls must enforce the target allowlist"
  fi
  assert_absent "$home/called" "unauthorized direct adapter calls must not reach Hermes"
  pass "direct Hermes adapter calls enforce target authorization"
}

test_custom_adapter_rejects_symlinked_parent() {
  local home id
  home="$TMP_ROOT/custom-adapter-parent-symlink"
  setup_home "$home"
  write_adapter "$home"
  id=$(new_linked_note "$home" custom-adapter-parent-1)
  printf 'Must not deliver.\n' > "$home/summary.txt"
  mkdir -p "$home/realbin"
  cp "$home/fakebin/result-adapter" "$home/realbin/result-adapter"
  ln -s "$home/realbin" "$home/linkbin"
  if FM_INBOX_RESULT_ADAPTER="$home/linkbin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
      home_env "$home" "$RESULT" publish --note-id "$id" --status completed \
      --summary-file "$home/summary.txt" >/dev/null 2>"$home/adapter-parent.err"; then
    fail "custom adapters under symlinked parents must be rejected"
  fi
  assert_grep 'result adapter is unavailable' "$home/adapter-parent.err" \
    "symlinked custom adapter rejection must be explicit"
  assert_absent "$home/adapter.log" \
    "symlinked custom adapter must not execute"
  pass "custom adapters reject symlinked parent paths"
}

test_shipped_hermes_adapter_rejects_payload_target_mismatch() {
  local home payload
  home="$TMP_ROOT/hermes-adapter-payload-target"
  setup_home "$home"
  payload="$home/result.json"
  jq -n --arg target 'hermes:telegram:-999:1' \
    '{schema:"firstmate.inbox-result.v1", note_id:"payload-target-1", request_note_id:"payload-target-1",
      correlation_id:"payload-target-1", reply_target:$target, status:"completed", summary:"no", artifacts:[]}' \
    > "$payload"
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/hermes" <<'HERMES'
#!/usr/bin/env bash
printf called > "$FM_HERMES_CALLED"
HERMES
  chmod +x "$home/fakebin/hermes"
  if FM_HOME="$home" HERMES_BIN="$home/fakebin/hermes" FM_HERMES_CALLED="$home/called" \
      "$ROOT/bin/fm-inbox-hermes-adapter.sh" --target "$TARGET" \
      --idempotency-key payload-target-1 --payload-file "$payload" >/dev/null 2>"$home/adapter.err"; then
    fail "adapter must reject payloads targeting a different Hermes session"
  fi
  assert_absent "$home/called" "target-mismatched payloads must not reach Hermes"
  pass "adapter rejects payload target mismatches"
}

test_shipped_hermes_adapter_rejects_symlinked_payload_parent() {
  local home outside payload
  home="$TMP_ROOT/hermes-adapter-payload-parent"
  setup_home "$home"
  outside="$home/outside"
  mkdir -p "$outside"
  payload="$outside/result.json"
  jq -n --arg target "$TARGET" \
    '{schema:"firstmate.inbox-result.v1", note_id:"payload-parent-1", request_note_id:"payload-parent-1",
      correlation_id:"payload-parent-1", reply_target:$target, status:"completed", summary:"no", artifacts:[]}' \
    > "$payload"
  ln -s "$outside" "$home/payload-link"
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/hermes" <<'HERMES'
#!/usr/bin/env bash
printf called > "$FM_HERMES_CALLED"
HERMES
  chmod +x "$home/fakebin/hermes"
  if FM_HOME="$home" HERMES_BIN="$home/fakebin/hermes" FM_HERMES_CALLED="$home/called" \
      "$ROOT/bin/fm-inbox-hermes-adapter.sh" --target "$TARGET" \
      --idempotency-key payload-parent-1 --payload-file "$home/payload-link/result.json" \
      >/dev/null 2>"$home/adapter.err"; then
    fail "adapter must reject payloads under symlinked parents"
  fi
  assert_absent "$home/called" "symlinked payload parents must not reach Hermes"
  pass "adapter rejects payloads under symlinked parents"
}

test_restart_reclaims_a_dead_delivery_lock() {
  local home id lock
  home="$TMP_ROOT/dead-lock"
  setup_home "$home"
  write_adapter "$home"
  : > "$home/adapter.log"
  id=$(new_linked_note "$home" dead-lock-1)
  publish_result "$home" "$id" --no-deliver >/dev/null \
    || fail "pending result setup must succeed"
  lock="$home/state/inbox-results/$id.delivery.lock"
  mkdir "$lock"
  printf '99999999\ndead-process-identity\n' > "$lock/owner"
  chmod 0600 "$lock/owner"

  FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
    home_env "$home" "$RESULT" deliver --note-id "$id" >/dev/null \
    || fail "restart recovery must reclaim a provably dead lock owner"
  assert_present "$home/state/inbox-results/$id.receipt.json" \
    "dead-lock recovery must complete delivery"
  pass "restart recovery reclaims provably dead delivery ownership"
}

test_ownerless_delivery_lock_fails_closed() {
  local home id lock
  home="$TMP_ROOT/ownerless-lock"
  setup_home "$home"
  write_adapter "$home"
  : > "$home/adapter.log"
  id=$(new_linked_note "$home" ownerless-lock-1)
  publish_result "$home" "$id" --no-deliver >/dev/null \
    || fail "pending result setup must succeed"
  lock="$home/state/inbox-results/$id.delivery.lock"
  mkdir "$lock"

  if FM_INBOX_RESULT_ADAPTER="$home/fakebin/result-adapter" FM_ADAPTER_LOG="$home/adapter.log" \
      home_env "$home" "$RESULT" deliver --note-id "$id" >/dev/null 2>"$home/ownerless.err"; then
    fail "ownerless lock must not be reclaimed while its creator may still be live"
  fi
  assert_grep 'lock owner is missing or malformed' "$home/ownerless.err" \
    "ownerless lock refusal must be explicit"
  [ ! -s "$home/adapter.log" ] \
    || fail "ownerless lock refusal must happen before user-visible delivery"
  assert_present "$home/state/inbox-results/$id.result.json" \
    "ownerless lock refusal must preserve the pending result"
  pass "ownerless delivery locks fail closed against duplicate senders"
}

test_reply_metadata_and_plain_compatibility
test_malformed_and_unauthorized_targets_fail_closed
test_publish_deliver_and_duplicate_suppression
test_restart_recovery_from_pending
test_definite_failure_and_retry
test_ambiguous_failure_requires_confirmation
test_restart_recovery_from_posting_gap
test_unsafe_artifacts_and_revoked_target_fail_closed
test_publish_rejects_symlinked_summary_parent
test_publish_preserves_summary_after_size_check
test_publish_rejects_fifo_summary_without_blocking
test_publish_rejects_symlinked_inbox_directory
test_publish_rejects_symlinked_handled_directory
test_shipped_hermes_adapter_returns_to_declared_session
test_shipped_hermes_adapter_rejects_non_delivery_success
test_shipped_hermes_adapter_enforces_target_allowlist
test_custom_adapter_rejects_symlinked_parent
test_shipped_hermes_adapter_rejects_payload_target_mismatch
test_shipped_hermes_adapter_rejects_symlinked_payload_parent
test_restart_reclaims_a_dead_delivery_lock
test_ownerless_delivery_lock_fails_closed
