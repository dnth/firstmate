#!/usr/bin/env bash
# Behavior tests for the append-only evidence receipt helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECEIPT="$ROOT/bin/fm-receipt.sh"
CHECK="$ROOT/bin/fm-receipt-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-receipt)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"

write_ship() {  # <id>
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<'EOF'
# Task
Exercise evidence receipts.

# Acceptance criteria
- AC1: The primary behavior works.
- AC2: The regression remains covered.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  : > "$HOME_DIR/data/$id/evidence.jsonl"
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship" "mode=no-mistakes"
}

test_appends_one_compact_valid_receipt() {
  local id=append-valid out ledger
  write_ship "$id"
  ledger="$HOME_DIR/data/$id/evidence.jsonl"
  out=$(FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test \
    "primary behavior is covered" "12 passed" \
    --command "tests/primary.test.sh" --artifact "artifacts/result.json" --file "src/primary.sh") \
    || fail "valid receipt append failed"
  printf '%s' "$out" | jq -e '
    .criterion == "AC1" and .type == "test"
    and .summary == "primary behavior is covered"
    and .result == "12 passed"
    and .command == "tests/primary.test.sh"
    and .artifact == "artifacts/result.json"
    and .file == "src/primary.sh"
  ' >/dev/null || fail "receipt helper did not emit the expected v1 object"
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 1 ] || fail "one append did not write exactly one JSONL record"
  jq -e . "$ledger" >/dev/null || fail "ledger record is not valid JSON"
  pass "fm-receipt appends one compact validated receipt"
}

test_append_is_additive_and_result_flag_works() {
  local id=append-additive ledger first
  write_ship "$id"
  ledger="$HOME_DIR/data/$id/evidence.jsonl"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 lint "lint is clean" --result "passed" >/dev/null \
    || fail "--result receipt append failed"
  first=$(sed -n '1p' "$ledger")
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC2 review "regression reviewed" "approved" >/dev/null \
    || fail "second receipt append failed"
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 2 ] || fail "second append did not preserve both records"
  [ "$(sed -n '1p' "$ledger")" = "$first" ] || fail "second append rewrote the first receipt"
  pass "fm-receipt preserves prior records and accepts --result"
}

test_large_receipt_is_appended_completely() {
  local id=append-large ledger result out
  write_ship "$id"
  ledger="$HOME_DIR/data/$id/evidence.jsonl"
  result=$(awk 'BEGIN { for (i=0; i<32768; i++) printf "x" }')
  out=$(FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test large "$result") \
    || fail "large receipt append failed"
  [ "$(printf '%s' "$out" | jq -r '.result | length')" -eq 32768 ] \
    || fail "large receipt output was truncated"
  [ "$(jq -r '.result | length' "$ledger")" -eq 32768 ] \
    || fail "large ledger record was truncated"
  pass "fm-receipt appends complete large JSONL records"
}

test_rejects_invalid_schema_and_undeclared_criteria() {
  local id=append-invalid rc before
  write_ship "$id"
  before=$(wc -c < "$HOME_DIR/data/$id/evidence.jsonl")
  for args in \
    "$id AC0 test summary passed" \
    "$id AC3 test summary passed" \
    "$id AC1 unknown summary passed" \
    "$id AC1 test summary"; do
    # shellcheck disable=SC2086 # Each row is an intentional argument fixture.
    FM_HOME="$HOME_DIR" "$RECEIPT" $args >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 0 ] || fail "invalid receipt fixture unexpectedly succeeded: $args"
  done
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test '   ' passed >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "receipt helper accepted a whitespace-only summary"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test summary '   ' >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "receipt helper accepted a whitespace-only result"
  [ "$(wc -c < "$HOME_DIR/data/$id/evidence.jsonl")" -eq "$before" ] \
    || fail "a refused receipt mutated the ledger"
  pass "fm-receipt rejects invalid types, ids, missing results, and undeclared criteria"
}

test_portable_paths_and_failed_append_rollback() {
  local id=portable-store modules ledger before rc
  write_ship "$id"
  modules="$TMP_ROOT/perl-modules"
  mkdir -p "$modules"
  cat > "$modules/RejectDevFd.pm" <<'PERL'
package RejectDevFd;
use strict;
use warnings;
BEGIN {
  *CORE::GLOBAL::sysopen = sub (*$$;$) {
    die "nonportable /dev/fd traversal\n" if defined($_[1]) && $_[1] =~ m{^/dev/fd/};
    return @_ == 4
      ? CORE::sysopen($_[0], $_[1], $_[2], $_[3])
      : CORE::sysopen($_[0], $_[1], $_[2]);
  };
}
1;
PERL
  PERL5LIB="$modules" PERL5OPT=-MRejectDevFd FM_HOME="$HOME_DIR" \
    "$RECEIPT" "$id" AC1 test portable passed >/dev/null \
    || fail "public receipt append required /dev/fd directory traversal"
  PERL5LIB="$modules" PERL5OPT=-MRejectDevFd FM_HOME="$HOME_DIR" \
    "$RECEIPT" "$id" AC2 lint portable passed >/dev/null \
    || fail "second public receipt append required /dev/fd directory traversal"
  PERL5LIB="$modules" PERL5OPT=-MRejectDevFd FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" >/dev/null \
    || fail "public receipt check required /dev/fd directory traversal"
  ledger="$HOME_DIR/data/$id/evidence.jsonl"
  before=$(wc -c < "$ledger")
  cat > "$modules/FailSyswrite.pm" <<'PERL'
package FailSyswrite;
use strict;
use warnings;
use Errno qw(ENOSPC);
our $calls = 0;
BEGIN {
  *CORE::GLOBAL::syswrite = sub (*$$;$$) {
    if ($calls++ == 0) {
      return CORE::syswrite($_[0], $_[1], 5, $_[3] // 0);
    }
    $! = ENOSPC;
    return undef;
  };
}
1;
PERL
  PERL5LIB="$modules" PERL5OPT=-MFailSyswrite FM_HOME="$HOME_DIR" \
    "$RECEIPT" "$id" AC2 lint rollback passed >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "fault-injected partial append unexpectedly succeeded"
  [ "$(wc -c < "$ledger")" -eq "$before" ] || fail "failed partial append left a ledger tail"
  jq -e . "$ledger" >/dev/null || fail "failed partial append corrupted prior JSONL"
  pass "fm-receipt uses portable paths and rolls back incomplete appends"
}

test_rejects_non_ship_and_unsafe_ledger() {
  local id=scout-task rc target alias
  mkdir -p "$HOME_DIR/data/$id"
  printf '# Task\nInvestigate only.\n' > "$HOME_DIR/data/$id/brief.md"
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=scout"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 review summary reviewed >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "receipt helper accepted a scout task"

  id=unsafe-ledger
  write_ship "$id"
  target="$TMP_ROOT/outside-ledger"
  : > "$target"
  rm -f "$HOME_DIR/data/$id/evidence.jsonl"
  ln -s "$target" "$HOME_DIR/data/$id/evidence.jsonl"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test summary passed >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "receipt helper followed a ledger symlink"
  [ ! -s "$target" ] || fail "receipt helper wrote through a ledger symlink"

  id=linked-ledger
  write_ship "$id"
  alias="$TMP_ROOT/ledger-alias"
  ln "$HOME_DIR/data/$id/evidence.jsonl" "$alias"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test summary passed >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "receipt helper accepted a multiply linked ledger"
  [ ! -s "$alias" ] || fail "receipt helper mutated a hard-linked ledger alias"

  id=linked-task
  mkdir -p "$TMP_ROOT/outside-task"
  ln -s "$TMP_ROOT/outside-task" "$HOME_DIR/data/$id"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test summary passed >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "receipt helper accepted a symlinked task directory"
  pass "fm-receipt refuses non-ship tasks and unsafe ledger paths"
}

test_task_directory_swap_before_open_is_rejected() {
  local id=swapped-task task moved outside fakebin real_jq ready release pid rc
  write_ship "$id"
  task="$HOME_DIR/data/$id"
  moved="$HOME_DIR/data/$id-pinned"
  outside="$TMP_ROOT/outside-swapped-task"
  fakebin="$TMP_ROOT/swap-fakebin"
  ready="$TMP_ROOT/swap-ready"
  release="$TMP_ROOT/swap-release"
  mkdir -p "$outside" "$fakebin"
  cp "$task/brief.md" "$outside/brief.md"
  : > "$outside/evidence.jsonl"
  mkfifo "$release"
  real_jq=$(command -v jq)
  cat > "$fakebin/jq" <<EOF
#!/bin/sh
if mkdir "$TMP_ROOT/swap-once" 2>/dev/null; then
  : > "$ready"
  IFS= read -r _ < "$release"
fi
exec "$real_jq" "\$@"
EOF
  chmod +x "$fakebin/jq"
  PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test summary passed > "$TMP_ROOT/swap-output" 2>&1 &
  pid=$!
  while [ ! -e "$ready" ]; do
    kill -0 "$pid" 2>/dev/null || fail "receipt exited before the directory-swap boundary"
  done
  mv "$task" "$moved"
  ln -s "$outside" "$task"
  printf 'continue\n' > "$release"
  wait "$pid"
  rc=$?
  [ "$rc" -ne 0 ] || fail "receipt accepted a task path replaced before its no-follow open"
  [ ! -s "$moved/evidence.jsonl" ] || fail "rejected task-path replacement mutated the original ledger"
  [ ! -s "$outside/evidence.jsonl" ] || fail "task-path replacement redirected the receipt outside its pinned directory"
  pass "fm-receipt rejects task-directory replacement before its no-follow open"
}

test_data_directory_swap_before_open_is_rejected() {
  local id=swapped-data data moved outside fakebin real_perl ready release pid rc
  write_ship "$id"
  data="$HOME_DIR/data"
  moved="$HOME_DIR/data-pinned"
  outside="$TMP_ROOT/outside-swapped-data"
  fakebin="$TMP_ROOT/data-swap-fakebin"
  ready="$TMP_ROOT/data-swap-ready"
  release="$TMP_ROOT/data-swap-release"
  mkdir -p "$outside/$id" "$fakebin"
  cp "$data/$id/brief.md" "$outside/$id/brief.md"
  : > "$outside/$id/evidence.jsonl"
  mkfifo "$release"
  real_perl=$(command -v perl)
  cat > "$fakebin/perl" <<EOF
#!/bin/sh
if mkdir "$TMP_ROOT/data-swap-once" 2>/dev/null; then
  : > "$ready"
  IFS= read -r _ < "$release"
fi
exec "$real_perl" "\$@"
EOF
  chmod +x "$fakebin/perl"
  PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test summary passed \
    > "$TMP_ROOT/data-swap-output" 2>&1 &
  pid=$!
  while [ ! -e "$ready" ]; do
    kill -0 "$pid" 2>/dev/null || fail "receipt exited before the data-directory swap boundary"
  done
  mv "$data" "$moved"
  ln -s "$outside" "$data"
  printf 'continue\n' > "$release"
  wait "$pid"
  rc=$?
  [ "$rc" -ne 0 ] || fail "receipt followed a replaced data-directory prefix"
  [ ! -s "$moved/$id/evidence.jsonl" ] || fail "rejected data replacement mutated the original ledger"
  [ ! -s "$outside/$id/evidence.jsonl" ] || fail "data replacement redirected the receipt outside its pinned root"
  rm "$data"
  mv "$moved" "$data"
  pass "fm-receipt rejects data-directory replacement before its pinned open"
}

test_ledger_replacement_after_open_cannot_redirect_append() {
  local id=swapped-ledger task ledger pinned replacement ready release holder receipt_pid rc
  id=swapped-ledger
  write_ship "$id"
  task="$HOME_DIR/data/$id"
  ledger="$task/evidence.jsonl"
  pinned="$task/evidence.original"
  replacement="$task/evidence.replacement"
  ready="$TMP_ROOT/ledger-lock-ready"
  release="$TMP_ROOT/ledger-lock-release"
  mkfifo "$release"
  FM_LOCK_LEDGER="$ledger" FM_LOCK_READY="$ready" FM_LOCK_RELEASE="$release" perl -MFcntl=:flock -e '
    open(my $ledger, "+<", $ENV{FM_LOCK_LEDGER}) or exit 1;
    flock($ledger, LOCK_EX) or exit 1;
    open(my $ready, ">", $ENV{FM_LOCK_READY}) or exit 1;
    close($ready) or exit 1;
    open(my $release, "<", $ENV{FM_LOCK_RELEASE}) or exit 1;
    <$release>;
  ' &
  holder=$!
  while [ ! -e "$ready" ]; do
    kill -0 "$holder" 2>/dev/null || fail "ledger lock holder exited before the race boundary"
  done
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test summary passed > "$TMP_ROOT/ledger-swap-output" 2>&1 &
  receipt_pid=$!
  sleep 1
  mv "$ledger" "$pinned"
  : > "$replacement"
  mv "$replacement" "$ledger"
  printf 'continue\n' > "$release"
  wait "$holder" || fail "ledger lock holder failed"
  wait "$receipt_pid"
  rc=$?
  expect_code 0 "$rc" "receipt append through the original ledger descriptor"
  [ "$(wc -l < "$pinned" | tr -d ' ')" -eq 1 ] || fail "receipt did not append through its pinned ledger descriptor"
  [ ! -s "$ledger" ] || fail "ledger replacement redirected the receipt append"
  pass "fm-receipt appends only through the ledger descriptor opened before validation"
}

test_appends_one_compact_valid_receipt
test_append_is_additive_and_result_flag_works
test_large_receipt_is_appended_completely
test_rejects_invalid_schema_and_undeclared_criteria
test_portable_paths_and_failed_append_rollback
test_rejects_non_ship_and_unsafe_ledger
test_task_directory_swap_before_open_is_rejected
test_data_directory_swap_before_open_is_rejected
test_ledger_replacement_after_open_cannot_redirect_append
