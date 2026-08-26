#!/usr/bin/env bash
# Behavior tests for the append-only evidence receipt helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECEIPT="$ROOT/bin/fm-receipt.sh"
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
  [ "$(wc -c < "$HOME_DIR/data/$id/evidence.jsonl")" -eq "$before" ] \
    || fail "a refused receipt mutated the ledger"
  pass "fm-receipt rejects invalid types, ids, missing results, and undeclared criteria"
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

test_appends_one_compact_valid_receipt
test_append_is_additive_and_result_flag_works
test_rejects_invalid_schema_and_undeclared_criteria
test_rejects_non_ship_and_unsafe_ledger
