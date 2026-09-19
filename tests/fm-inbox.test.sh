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

test_note_persists_and_wakes
test_list_drain_and_idempotent_ack
test_status_is_read_only
test_concurrent_notes_are_unique_and_woken
test_wake_failure_preserves_note
test_symlink_note_fails_closed
test_status_rejects_symlink_note
test_status_rejects_symlink_directory
test_list_and_drain_reject_symlink_directory
