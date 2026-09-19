#!/usr/bin/env bash
# Behavior tests for the trusted-local Firstmate inbox.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-inbox)
INBOX="$ROOT/bin/fm-inbox.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

home_env() {
  local home=$1
  shift
  PATH="$BASE_PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    "$@"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

pending_count() {
  local dir=$1 note count=0
  for note in "$dir"/*.note; do
    [ -f "$note" ] && [ ! -L "$note" ] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

test_note_persists_and_wakes() {
  local home out id note wake mode
  home="$TMP_ROOT/note"
  mkdir -p "$home"

  out=$(home_env "$home" "$INBOX" note "Review /tmp/handoff.md") \
    || fail "note command must succeed"
  id=${out#noted }
  [ -n "$id" ] && [ "$id" != "$out" ] || fail "note must return its id"

  note="$home/state/inbox/${id}.note"
  assert_present "$note" "note must persist before returning"
  assert_grep 'Review /tmp/handoff.md' "$note" "note must preserve the message"
  mode=$(file_mode "$note")
  [ "$mode" = 600 ] || fail "note mode must be 600, got $mode"

  wake="$home/state/.wake-queue"
  assert_present "$wake" "note must append a durable wake"
  assert_grep $'\tcheck\tinbox-'"$id"$'\tcaptain inbox note '"$id" "$wake" \
    "wake must identify the durable note"
  assert_grep "acknowledge after handling with bin/fm-inbox.sh drain --ack $id" "$wake" \
    "wake must explain how to inspect and acknowledge the note"
  [ "$(wc -l < "$wake" | tr -d ' ')" = 1 ] || fail "one note must append exactly one wake"
  pass "note persists privately and appends one durable wake"
}

test_list_drain_and_idempotent_ack() {
  local home out first second listed drained
  home="$TMP_ROOT/drain"
  mkdir -p "$home"
  first=$(home_env "$home" "$INBOX" note "first brief" | sed 's/^noted //')
  second=$(home_env "$home" "$INBOX" note "second brief" | sed 's/^noted //')

  listed=$(home_env "$home" "$INBOX" list) || fail "list must succeed"
  assert_contains "$listed" "$first" "list must include the first id"
  assert_contains "$listed" "first brief" "list must include the first message"
  assert_contains "$listed" "$second" "list must include the second id"
  assert_contains "$listed" "second brief" "list must include the second message"

  drained=$(home_env "$home" "$INBOX" drain) || fail "drain must succeed"
  assert_contains "$drained" "--- $first ---" "drain must identify the first note"
  assert_contains "$drained" "first brief" "drain must print the first note"

  out=$(home_env "$home" "$INBOX" drain --ack "$first") || fail "ack must succeed"
  assert_contains "$out" "acked $first" "ack must report the note id"
  assert_absent "$home/state/inbox/$first.note" "ack must remove the pending note"
  assert_present "$home/state/inbox/handled/$first.note" "ack must retain handled history"

  out=$(home_env "$home" "$INBOX" drain --ack "$first") || fail "repeat ack must be idempotent"
  assert_contains "$out" "already-acked $first" "repeat ack must report prior handling"

  if home_env "$home" "$INBOX" drain --ack '../escape' >/dev/null 2>&1; then
    fail "ack must reject path traversal"
  fi
  assert_present "$home/state/inbox/$second.note" "invalid ack must not mutate pending notes"
  pass "list and drain expose notes; ack is retained, idempotent, and path-safe"
}

test_legacy_option_looking_message_remains_plain() {
  local home out id reversed missing explicit malformed invalid unauthorized
  home="$TMP_ROOT/legacy-option-message"
  mkdir -p "$home"
  out=$(home_env "$home" "$INBOX" note --reply-target hello) \
    || fail "legacy option-looking messages must remain accepted"
  id=${out#noted }
  assert_grep '--reply-target hello' "$home/state/inbox/$id.note" \
    "legacy option-looking message must remain plain text"
  reversed=$(home_env "$home" "$INBOX" note --correlation-id hello --reply-target | sed 's/^noted //') \
    || fail "reversed incomplete metadata must remain accepted as plain text"
  assert_grep '--correlation-id hello --reply-target' "$home/state/inbox/$reversed.note" \
    "reversed incomplete metadata must remain plain text"
  missing=$(home_env "$home" "$INBOX" note --reply-target | sed 's/^noted //') \
    || fail "missing metadata values must remain accepted as plain text"
  assert_grep '--reply-target' "$home/state/inbox/$missing.note" \
    "missing metadata value must remain plain text"
  explicit=$(home_env "$home" "$INBOX" note -- --reply-target hello | sed 's/^noted //') \
    || fail "explicit legacy separator must remain accepted"
  assert_grep '--reply-target hello' "$home/state/inbox/$explicit.note" \
    "explicit separator must preserve plain text"
  malformed=$(home_env "$home" "$INBOX" note --reply-target --correlation-id foo | sed 's/^noted //') \
    || fail "malformed option-like messages must remain accepted"
  assert_grep '--reply-target --correlation-id foo' "$home/state/inbox/$malformed.note" \
    "malformed option-like message must remain plain text"
  invalid=$(home_env "$home" "$INBOX" note --reply-target invalid --correlation-id corr | sed 's/^noted //') \
    || fail "invalid option-like messages must remain accepted"
  assert_grep '--reply-target invalid --correlation-id corr' "$home/state/inbox/$invalid.note" \
    "invalid option-like message must remain plain text"
  unauthorized=$(home_env "$home" "$INBOX" note --reply-target 'hermes:telegram:-999:1' \
    --correlation-id corr | sed 's/^noted //') \
    || fail "unauthorized option-like messages must remain accepted"
  assert_grep 'hermes:telegram:-999:1 --correlation-id corr' "$home/state/inbox/$unauthorized.note" \
    "unauthorized option-like message must remain plain text"
  pass "legacy option-looking messages remain plain text"
}

test_list_and_drain_reject_malformed_structured_note() {
  local home id
  home="$TMP_ROOT/malformed-structured-note"
  id=malformed-structured-1
  mkdir -p "$home/state/inbox"
  jq -n --arg id "$id" \
    '{schema:"firstmate.inbox-note.v1", note_id:$id, request_note_id:$id,
      correlation_id:"corr", reply_target:"hermes:telegram:chat", message:"bad",
      created_at:"garbage"}' > "$home/state/inbox/$id.note"
  chmod 0600 "$home/state/inbox/$id.note"
  if home_env "$home" "$INBOX" list >"$home/list.out" 2>"$home/list.err"; then
    fail "list must reject malformed structured notes"
  fi
  assert_grep 'invalid pending note' "$home/list.err" \
    "list malformed-note rejection must be explicit"
  if home_env "$home" "$INBOX" drain >"$home/drain.out" 2>"$home/drain.err"; then
    fail "drain must reject malformed structured notes"
  fi
  assert_grep 'invalid pending note' "$home/drain.err" \
    "drain malformed-note rejection must be explicit"
  if home_env "$home" "$INBOX" drain --ack "$id" >"$home/ack.out" 2>"$home/ack.err"; then
    fail "ack must reject malformed structured notes"
  fi
  assert_grep 'invalid pending note' "$home/ack.err" \
    "ack malformed-note rejection must be explicit"
  assert_present "$home/state/inbox/$id.note" \
    "malformed structured note must not be acknowledged"
  pass "list and drain reject malformed structured notes"
}

test_truncated_structured_note_fails_closed() {
  local home id
  home="$TMP_ROOT/truncated-structured-note"
  id=truncated-structured-1
  mkdir -p "$home/state/inbox"
  printf '{"schema":"firstmate.inbox-note.v1"' > "$home/state/inbox/$id.note"
  chmod 0600 "$home/state/inbox/$id.note"
  if home_env "$home" "$INBOX" list >"$home/list.out" 2>"$home/list.err"; then
    fail "list must reject truncated structured notes"
  fi
  if home_env "$home" "$INBOX" drain >"$home/drain.out" 2>"$home/drain.err"; then
    fail "drain must reject truncated structured notes"
  fi
  if home_env "$home" "$INBOX" drain --ack "$id" >"$home/ack.out" 2>"$home/ack.err"; then
    fail "ack must reject truncated structured notes"
  fi
  assert_present "$home/state/inbox/$id.note" \
    "truncated structured note must not be acknowledged"
  pass "truncated structured notes fail closed"
}

test_status_is_read_only() {
  local home before after out
  home="$TMP_ROOT/status"
  mkdir -p "$home"
  home_env "$home" "$INBOX" note "status brief" >/dev/null
  before=$(find "$home/state/inbox" -type f -print | LC_ALL=C sort)
  out=$(home_env "$home" "$INBOX" status) || fail "status must succeed"
  after=$(find "$home/state/inbox" -type f -print | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "status must not mutate inbox records"
  assert_contains "$out" "inbox pending: 1" "status must report pending notes"
  pass "status reads durable state without mutating inbox records"
}

test_concurrent_notes_are_unique_and_woken() {
  local home i count ids unique wakes
  home="$TMP_ROOT/concurrent"
  mkdir -p "$home"
  for ((i = 1; i <= 20; i++)); do
    home_env "$home" "$INBOX" note "concurrent $i" > "$home/out.$i" &
  done
  wait || fail "concurrent notes must all succeed"

  count=$(pending_count "$home/state/inbox")
  ids=$(sed -n 's/^noted //p' "$home"/out.*)
  unique=$(printf '%s\n' "$ids" | sort -u | wc -l | tr -d ' ')
  wakes=$(wc -l < "$home/state/.wake-queue" | tr -d ' ')
  [ "$count" = 20 ] || fail "expected 20 durable notes, got $count"
  [ "$unique" = 20 ] || fail "expected 20 unique ids, got $unique"
  [ "$wakes" = 20 ] || fail "expected 20 wake rows, got $wakes"
  pass "concurrent notes remain unique and each append one wake"
}

test_wake_failure_preserves_note() {
  local home rc count
  home="$TMP_ROOT/wake-failure"
  mkdir -p "$home/state/broken-queue"
  set +e
  FM_WAKE_QUEUE="$home/state/broken-queue" \
    home_env "$home" "$INBOX" note "recover me" >"$home/out" 2>"$home/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "wake append failure must fail the command"
  count=$(pending_count "$home/state/inbox")
  [ "$count" = 1 ] || fail "wake failure must preserve the durable note"
  assert_grep 'persisted, but wake append failed' "$home/err" \
    "wake failure must explain that the note survived"
  pass "wake failure is reported without losing the durable note"
}

test_symlink_note_fails_closed() {
  local home outside
  home="$TMP_ROOT/symlink"
  outside="$home/outside"
  mkdir -p "$home/state/inbox"
  printf 'must not leak\n' > "$outside"
  ln -s "$outside" "$home/state/inbox/attacker.note"

  if home_env "$home" "$INBOX" list >"$home/out" 2>"$home/err"; then
    fail "list must reject a symlinked note"
  fi
  assert_grep 'invalid pending note' "$home/err" "symlink rejection must be explicit"
  if home_env "$home" "$INBOX" drain >/dev/null 2>&1; then
    fail "drain must reject a symlinked note"
  fi
  pass "list and drain fail closed on symlinked notes"
}

test_status_rejects_symlink_note() {
  local home outside
  home="$TMP_ROOT/status-symlink"
  outside="$home/outside"
  mkdir -p "$home/state/inbox"
  printf 'must not hide\n' > "$outside"
  ln -s "$outside" "$home/state/inbox/tampered.note"

  if home_env "$home" "$INBOX" status >"$home/out" 2>"$home/err"; then
    fail "status must reject a symlinked note"
  fi
  assert_grep 'invalid note: tampered.note' "$home/err" \
    "status symlink rejection must be explicit"
  pass "status fails closed on symlinked notes"
}

test_status_rejects_symlink_directory() {
  local home real_inbox
  home="$TMP_ROOT/status-directory-symlink"
  real_inbox="$home/real-inbox"
  mkdir -p "$real_inbox"
  mkdir -p "$home/state"
  ln -s "$real_inbox" "$home/state/inbox"

  if home_env "$home" "$INBOX" status >"$home/out" 2>"$home/err"; then
    fail "status must reject a symlinked inbox directory"
  fi
  assert_grep 'inbox path must not be a symlink' "$home/err" \
    "status directory symlink rejection must be explicit"
  pass "status fails closed on symlinked inbox directories"
}

test_list_and_drain_reject_symlink_directory() {
  local home real_inbox
  home="$TMP_ROOT/list-drain-directory-symlink"
  real_inbox="$home/real-inbox"
  mkdir -p "$real_inbox"
  mkdir -p "$home/state"
  ln -s "$real_inbox" "$home/state/inbox"

  if home_env "$home" "$INBOX" list >"$home/out" 2>"$home/err"; then
    fail "list must reject a symlinked inbox directory"
  fi
  assert_grep 'inbox path must not be a symlink' "$home/err" \
    "list directory symlink rejection must be explicit"
  if home_env "$home" "$INBOX" drain >"$home/drain-out" 2>"$home/drain-err"; then
    fail "drain must reject a symlinked inbox directory"
  fi
  assert_grep 'inbox path must not be a symlink' "$home/drain-err" \
    "drain directory symlink rejection must be explicit"
  pass "list and drain fail closed on symlinked inbox directories"
}

test_status_rejects_nondirectory_path() {
  local home
  home="$TMP_ROOT/status-nondirectory"
  mkdir -p "$home/state"
  printf 'not a directory\n' > "$home/state/inbox"

  if home_env "$home" "$INBOX" status >"$home/out" 2>"$home/err"; then
    fail "status must reject a non-directory inbox path"
  fi
  assert_grep 'inbox path must be a directory' "$home/err" \
    "status non-directory rejection must be explicit"
  pass "status fails closed on non-directory inbox paths"
}

test_status_rejects_malformed_wake_queue() {
  local home
  home="$TMP_ROOT/status-wake-queue-directory"
  mkdir -p "$home/state/inbox" "$home/state/inbox/handled" "$home/state/.wake-queue"

  if home_env "$home" "$INBOX" status >"$home/out" 2>"$home/err"; then
    fail "status must reject a non-file wake queue"
  fi
  assert_grep 'wake queue must be a regular file' "$home/err" \
    "status wake queue rejection must be explicit"
  pass "status fails closed on malformed wake queues"
}

test_note_persists_and_wakes
test_list_drain_and_idempotent_ack
test_legacy_option_looking_message_remains_plain
test_list_and_drain_reject_malformed_structured_note
test_truncated_structured_note_fails_closed
test_status_is_read_only
test_concurrent_notes_are_unique_and_woken
test_wake_failure_preserves_note
test_symlink_note_fails_closed
test_status_rejects_symlink_note
test_status_rejects_symlink_directory
test_list_and_drain_reject_symlink_directory
test_status_rejects_nondirectory_path
test_status_rejects_malformed_wake_queue
