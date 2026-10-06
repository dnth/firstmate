#!/usr/bin/env bash
# Behavior tests for acceptance-evidence accounting.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-receipt-check.sh"
RECEIPT="$ROOT/bin/fm-receipt.sh"
TMP_ROOT=$(fm_test_tmproot fm-receipt-check)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
fm_git_identity fmtest fmtest@example.invalid

# A No-Mistakes stub that records every invocation: the receipt checker must
# never consult the pipeline, so any line in this log fails the suite.
NM_CALL_LOG="$TMP_ROOT/no-mistakes-calls.log"
: > "$NM_CALL_LOG"
TRIPWIRE_NO_MISTAKES="$TMP_ROOT/tripwire-no-mistakes"
cat > "$TRIPWIRE_NO_MISTAKES" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$NM_CALL_LOG"
exit 1
EOF
chmod +x "$TRIPWIRE_NO_MISTAKES"
export FM_NO_MISTAKES_BIN="$TRIPWIRE_NO_MISTAKES"

write_brief() {  # <id> <mode>
  local id=$1 mode=$2
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
Implement the fixture behavior.

# Acceptance criteria
- AC1: The requested behavior works.
- AC2: Verification remains green.

# Definition of done
Delivery contract: mode=$mode
EOF
  : > "$HOME_DIR/data/$id/evidence.jsonl"
  : > "$HOME_DIR/data/$id/.evidence.lock"
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship" "mode=$mode"
}

add_receipt() {  # <id> <criterion> <type> <result> [outcome]
  local id=$1 criterion=$2 type=$3 result=$4 outcome=${5:-success}
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" "$criterion" "$type" "evidence for $criterion" "$result" --outcome "$outcome" >/dev/null \
    || fail "could not append fixture receipt for $id/$criterion"
}

check_json() {  # <id> <expected-rc> <jq-predicate> <message>
  local out rc
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$1" 2>/dev/null); rc=$?
  expect_code "$2" "$rc" "$4 (exit)"
  printf '%s' "$out" | jq -e "$3" >/dev/null || fail "$4: $out"
}

test_complete_evidence_reports_v2_shape() {
  local id=complete-evidence
  write_brief "$id" direct-PR
  add_receipt "$id" AC1 test "4 passed"
  add_receipt "$id" AC2 lint clean
  check_json "$id" 0 '
    . == {schema:"fm-evidence-check.v2",task:"complete-evidence",kind:"ship",status:"complete",
          required:["AC1","AC2"],evidenced:["AC1","AC2"],accepted_blocked:[],missing:[],invalid:[]}
  ' "complete evidence did not report the exact v2 object"
  pass "complete evidence reports the fm-evidence-check.v2 shape and exits 0"
}

test_missing_criterion_is_named() {
  local id=missing-evidence
  write_brief "$id" no-mistakes
  add_receipt "$id" AC2 lint passed
  check_json "$id" 1 '
    .status == "missing" and .required == ["AC1","AC2"] and .evidenced == ["AC2"]
    and .missing == ["AC1"] and .accepted_blocked == [] and .invalid == []
  ' "missing evidence did not name AC1"
  check_json "$id" 1 '.schema == "fm-evidence-check.v2"' "missing report schema changed"
  pass "a missing criterion is named and exits 1"
}

test_failed_evidence_does_not_satisfy_and_latest_wins() {
  local id=closed-outcomes
  write_brief "$id" direct-PR
  add_receipt "$id" AC1 test "12 passed" failure
  add_receipt "$id" AC2 test "0 tests passed" zero
  check_json "$id" 1 '.status == "missing" and .evidenced == [] and .missing == ["AC1","AC2"]' \
    "failed and zero outcomes satisfied a criterion"
  add_receipt "$id" AC1 test failed success
  check_json "$id" 1 '.evidenced == ["AC1"] and .missing == ["AC2"]' \
    "a later success did not supersede the earlier failure"
  add_receipt "$id" AC2 api 401 success
  check_json "$id" 0 '.status == "complete" and .evidenced == ["AC1","AC2"]' \
    "an expected 401 recorded as success was not evidence"
  # Invalidation by a finding: a later failure for AC2 revokes its success
  # until a fresh success lands, with no commit, generation, or head involved.
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC2 review "finding F3 shows AC2 unsatisfied" "401 path regressed" --outcome failure >/dev/null \
    || fail "invalidation receipt failed"
  check_json "$id" 1 '.status == "missing" and .missing == ["AC2"] and .evidenced == ["AC1"]' \
    "a later failure did not invalidate the earlier success"
  add_receipt "$id" AC2 api "401 restored" success
  check_json "$id" 0 '.status == "complete" and .missing == []' \
    "a fresh success after invalidation did not restore completeness"
  pass "failure never satisfies, expected-negative success does, and the latest receipt per criterion wins"
}

test_unknown_criterion_and_malformed_records_are_invalid() {
  local id=unknown-criterion out rc
  write_brief "$id" direct-PR
  add_receipt "$id" AC1 test passed
  add_receipt "$id" AC2 lint passed
  out=$(FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC9 test "evidence for AC9" passed --outcome success 2>&1); rc=$?
  expect_code 1 "$rc" "the writer accepted an undeclared criterion"
  assert_contains "$out" "not declared" "undeclared-criterion refusal did not say so"
  printf '%s\n' '{"criterion":"AC9","type":"test","outcome":"success","summary":"smuggled","result":"passed"}' \
    >> "$HOME_DIR/data/$id/evidence.jsonl"
  check_json "$id" 2 '.status == "invalid" and (.invalid | length) == 1 and (.invalid[0] | test("undeclared criterion AC9"))' \
    "an undeclared criterion in the ledger did not fail closed"
  id=malformed-ledger
  write_brief "$id" direct-PR
  printf '%s\n' \
    '{"criterion":"AC1","type":"test","outcome":"success","summary":"   ","result":"passed"}' \
    '{"criterion":"AC2","type":"lint","outcome":"success","summary":"lint","result":"passed","extra":true}' \
    '' \
    'not json' \
    > "$HOME_DIR/data/$id/evidence.jsonl"
  check_json "$id" 2 '.status == "invalid" and (.invalid | length) == 4 and .missing == ["AC1","AC2"]' \
    "malformed records were not each reported"
  id=legacy-head-ledger
  write_brief "$id" direct-PR
  printf '%s\n' \
    '{"criterion":"AC1","type":"test","outcome":"success","summary":"old","result":"passed","head":"0123456789abcdef0123456789abcdef01234567"}' \
    '{"criterion":"AC2","type":"lint","outcome":"success","summary":"old","result":"passed"}' \
    > "$HOME_DIR/data/$id/evidence.jsonl"
  check_json "$id" 0 '.status == "complete"' "a legacy head-stamped receipt was rejected"
  pass "unknown criteria and malformed records make the ledger invalid instead of vanishing"
}

test_accepted_blocked_accounts_without_evidencing() {
  local id=accepted-blocked id2=still-missing out rc
  write_brief "$id" no-mistakes
  add_receipt "$id" AC1 lint passed
  out=$(FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC2 manual "blocked by design" "no live provider credentials" --outcome accepted-blocked 2>&1); rc=$?
  expect_code 2 "$rc" "accepted-blocked without a captain exception was accepted"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC2 manual "blocked by design" "no live provider credentials" \
    --outcome accepted-blocked --captain-exception "2026-09-29 captain sanctioned AC2 as blocked" >/dev/null \
    || fail "accepted-blocked receipt failed"
  check_json "$id" 0 '
    .status == "complete" and .evidenced == ["AC1"] and .missing == []
    and .accepted_blocked == [{criterion:"AC2", captain_exception:"2026-09-29 captain sanctioned AC2 as blocked"}]
  ' "accepted-blocked criterion was not reported distinctly"
  write_brief "$id2" no-mistakes
  add_receipt "$id2" AC1 test "1 passed"
  add_receipt "$id2" AC2 manual "still blocked" skipped
  check_json "$id2" 1 '.status == "missing" and .missing == ["AC2"] and .accepted_blocked == []' \
    "a skipped criterion did not stay missing"
  pass "accepted-blocked accounts for its criterion visibly without evidencing it"
}

test_criterion_query_and_parser_share_one_grammar() {
  local id=shared-criteria out rc
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<'EOF'
# Acceptance criteria
- AC10: A detailed outcome: including punctuation.
# Definition of done
Delivery contract: mode=direct-PR
EOF
  : > "$HOME_DIR/data/$id/evidence.jsonl"
  : > "$HOME_DIR/data/$id/.evidence.lock"
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship" "mode=direct-PR"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC10 test summary passed --outcome success >/dev/null \
    || fail "receipt append rejected a criterion accepted by the shared parser"
  check_json "$id" 0 '.required == ["AC10"] and .evidenced == ["AC10"]' \
    "shared criterion parser produced inconsistent append/check behavior"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --criterion AC10 || fail "--criterion refused a declared id"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --criterion AC1 && fail "--criterion accepted an undeclared id"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --criterion bogus && fail "--criterion accepted a malformed id"
  printf '# Acceptance criteria\n- AC1:    \n# End acceptance criteria\n' \
    | "$CHECK" --parse-criteria - >/dev/null 2>&1
  expect_code 2 "$?" "shared criterion parser accepted an all-whitespace description"
  printf '# Acceptance criteria\n- AC1: Implement {TODO} before completion.\n# End acceptance criteria\n' \
    | "$CHECK" --parse-criteria - >/dev/null 2>&1
  expect_code 2 "$?" "shared criterion parser accepted embedded placeholders"
  printf '# Acceptance criteria\n- AC1: Implement {TODO before completion.\n# End acceptance criteria\n' \
    | "$CHECK" --parse-criteria - >/dev/null 2>&1
  expect_code 2 "$?" "shared criterion parser accepted unmatched opening braces"
  printf '# Acceptance criteria\n- AC1: Implement TODO} before completion.\n# End acceptance criteria\n' \
    | "$CHECK" --parse-criteria - >/dev/null 2>&1
  expect_code 2 "$?" "shared criterion parser accepted unmatched closing braces"
  out=$(printf '# Acceptance criteria\n- AC1: API returns {"ok":true}.\n# End acceptance criteria\n' \
    | "$CHECK" --parse-criteria -); rc=$?
  expect_code 0 "$rc" "shared criterion parser rejected concrete brace syntax"
  [ "$out" = $'AC1\tAPI returns {"ok":true}.' ] || fail "parser output changed: $out"
  printf '# Acceptance criteria\n- AC1: One.\n- AC2: Two.\n' | "$CHECK" --parse-criteria - --require AC2 \
    || fail "--require refused a declared id"
  printf '# Acceptance criteria\n- AC1: One.\n' | "$CHECK" --parse-criteria - --require AC2 \
    && fail "--require accepted an undeclared id"
  pass "receipt append, --criterion, and --parse-criteria consume one criterion grammar"
}

test_checker_offers_only_accounting_options() {
  local id=accounting-only option out rc
  write_brief "$id" no-mistakes
  add_receipt "$id" AC1 test passed
  add_receipt "$id" AC2 lint passed
  for option in --plan --implementation-complete --mechanical-ready --complete --invalidate-claim --bind-run --bind-check --generation --terminal-evidence --base; do
    out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" "$option" value 2>&1); rc=$?
    expect_code 2 "$rc" "$option was accepted"
    assert_contains "$out" "unknown option: $option" "$option refusal did not name the option"
  done
  out=$(FM_HOME="$HOME_DIR" "$CHECK" --help)
  case "$out" in
    *--plan*|*--bind-run*|*--complete*|*--implementation-complete*|*generation*) fail "help still advertises a removed validation action" ;;
  esac
  assert_contains "$out" "certify nothing" "help does not state the accounting-only scope"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" >/dev/null || fail "complete fixture failed after option probes"
  grep -q 'validation_\|implementation_completed' "$HOME_DIR/state/$id.meta" \
    && fail "the checker wrote validation metadata"
  pass "fm-receipt-check offers only accounting actions and writes no validation metadata"
}

test_delivery_mode_mismatch_fails_closed() {
  local id=mode-mismatch out rc
  write_brief "$id" no-mistakes
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship" "mode=direct-PR"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" 2>&1); rc=$?
  expect_code 2 "$rc" "contradictory brief and metadata modes fail closed"
  assert_contains "$out" "contradicts the pinned ship brief" \
    "mode contradiction refusal did not identify its authority boundary"
  pass "pinned brief and metadata delivery modes must match exactly"
}

test_metadata_hard_links_are_rejected_by_the_pinned_owner() {
  local id=hard-linked-meta outside out rc
  write_brief "$id" direct-PR
  outside="$TMP_ROOT/external-meta"
  cp "$HOME_DIR/state/$id.meta" "$outside"
  rm "$HOME_DIR/state/$id.meta"
  ln "$outside" "$HOME_DIR/state/$id.meta"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" 2>&1)
  rc=$?
  expect_code 2 "$rc" "hard-linked metadata fails closed"
  assert_contains "$out" "single-link regular file" \
    "hard-linked metadata refusal did not come from the pinned state owner"
  pass "pinned metadata owner rejects hard-linked task records"
}

test_invalid_brief_and_scout_behavior() {
  local id=placeholder-brief rc out scout=scout-brief old=old-ship-brief linked=linked-ship outside
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<'EOF'
# Acceptance criteria
- AC1: {ACCEPTANCE CRITERION}
Delivery contract: mode=no-mistakes
EOF
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship" "mode=no-mistakes"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "placeholder acceptance criterion is invalid"

  mkdir -p "$HOME_DIR/data/$old"
  printf '# Task\nOld ship brief without evidence fields.\n' > "$HOME_DIR/data/$old/brief.md"
  fm_write_meta "$HOME_DIR/state/$old.meta" "kind=ship" "mode=direct-PR"
  FM_HOME="$HOME_DIR" "$CHECK" "$old" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "metadata kind=ship fails closed without a delivery contract"
  [ ! -e "$HOME_DIR/data/$old/.evidence.lock" ] || fail "read-only checking created a missing evidence lock"

  outside="$TMP_ROOT/outside-linked-ship"
  mkdir -p "$outside"
  cat > "$outside/brief.md" <<'EOF'
# Acceptance criteria
- AC1: External evidence exists.
# Definition of done
Delivery contract: mode=direct-PR
EOF
  printf '%s\n' '{"criterion":"AC1","type":"test","outcome":"success","summary":"external","result":"passed"}' > "$outside/evidence.jsonl"
  ln -s "$outside" "$HOME_DIR/data/$linked"
  fm_write_meta "$HOME_DIR/state/$linked.meta" "kind=ship" "mode=direct-PR"
  FM_HOME="$HOME_DIR" "$CHECK" "$linked" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "ship evidence checker rejects a symlinked task directory"

  mkdir -p "$HOME_DIR/data/$scout"
  printf '# Task\nInvestigate only.\n' > "$HOME_DIR/data/$scout/brief.md"
  fm_write_meta "$HOME_DIR/state/$scout.meta" "kind=scout"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$scout"); rc=$?
  expect_code 0 "$rc" "scout evidence check is not applicable"
  printf '%s' "$out" | jq -e '.schema == "fm-evidence-check.v2" and .status == "not-applicable" and .kind == "non-ship"' >/dev/null \
    || fail "scout behavior did not remain separate"
  [ ! -e "$HOME_DIR/data/$scout/evidence.jsonl" ] || fail "checker created a scout ledger"
  FM_HOME="$HOME_DIR" "$CHECK" "$scout" --criterion AC1 && fail "a scout declared a criterion"
  pass "invalid ship briefs fail and scout/report behavior stays unchanged"
}

test_early_snapshot_failure_does_not_block_cleanup() {
  local id=snapshot-open-failure modules pid rc attempts=0
  modules="$TMP_ROOT/snapshot-failure-modules"
  mkdir -p "$modules"
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship" "mode=direct-PR"
  cat > "$modules/LingerEnd.pm" <<'PERL'
package LingerEnd;
use strict;
use warnings;
END { sleep 2 }
1;
PERL
  PERL5LIB="$modules" PERL5OPT=-MLingerEnd FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" > "$TMP_ROOT/snapshot-failure-output" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 250 ]; do
    attempts=$((attempts + 1))
    sleep 0.02
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "early snapshot failure blocked cleanup on an unopened release channel"
  fi
  wait "$pid"
  rc=$?
  expect_code 2 "$rc" "early snapshot open failure returns promptly"
  pass "early snapshot failures release cleanup without a FIFO reader"
}

test_readiness_publication_failure_is_terminal() {
  local id=readiness-failure fakebin real_perl pid rc attempts=0
  write_brief "$id" direct-PR
  fakebin="$TMP_ROOT/readiness-failure-bin"
  mkdir -p "$fakebin"
  real_perl=$(command -v perl)
  cat > "$fakebin/perl" <<EOF
#!/bin/sh
mkdir "\$4" 2>/dev/null || true
exec "$real_perl" "\$@"
EOF
  chmod +x "$fakebin/perl"
  PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$CHECK" "$id" \
    > "$TMP_ROOT/readiness-failure-output" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$attempts" -lt 150 ]; do
    attempts=$((attempts + 1))
    sleep 0.02
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "readiness publication failure left parent or child waiting"
  fi
  wait "$pid"
  rc=$?
  expect_code 2 "$rc" "readiness publication failure is terminal"
  pass "snapshot readiness publication failures terminate without waiting"
}

test_pinned_checker_rejects_redirected_and_linked_evidence() {
  local id=pinned-check task moved outside fakebin real_grep ready release pid out rc alias
  write_brief "$id" direct-PR
  add_receipt "$id" AC1 test passed
  task="$HOME_DIR/data/$id"
  moved="$HOME_DIR/data/$id-original"
  outside="$TMP_ROOT/outside-pinned-check"
  fakebin="$TMP_ROOT/checker-race-fakebin"
  ready="$TMP_ROOT/checker-race-ready"
  release="$TMP_ROOT/checker-race-release"
  mkdir -p "$outside" "$fakebin"
  cp "$task/brief.md" "$outside/brief.md"
  printf '%s\n' \
    '{"criterion":"AC1","type":"test","outcome":"success","summary":"external","result":"passed"}' \
    '{"criterion":"AC2","type":"lint","outcome":"success","summary":"external","result":"passed"}' > "$outside/evidence.jsonl"
  mkfifo "$release"
  real_grep=$(command -v grep)
  cat > "$fakebin/grep" <<EOF
#!/bin/sh
case "\$*" in
  *"Delivery contract: mode="*)
    if mkdir "$TMP_ROOT/checker-race-once" 2>/dev/null; then
      : > "$ready"
      IFS= read -r _ < "$release"
    fi
    ;;
esac
exec "$real_grep" "\$@"
EOF
  chmod +x "$fakebin/grep"
  PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$CHECK" "$id" > "$TMP_ROOT/checker-race-output" 2>&1 &
  pid=$!
  while [ ! -e "$ready" ]; do
    kill -0 "$pid" 2>/dev/null || fail "checker exited before the task replacement boundary"
  done
  mv "$task" "$moved"
  ln -s "$outside" "$task"
  printf 'continue\n' > "$release"
  wait "$pid"
  rc=$?
  expect_code 1 "$rc" "checker uses the pinned incomplete ledger after task replacement"
  out=$(cat "$TMP_ROOT/checker-race-output")
  printf '%s' "$out" | jq -e '.status == "missing" and .missing == ["AC2"]' >/dev/null \
    || fail "task replacement redirected the checker away from its pinned evidence"

  id=checker-linked-ledger
  write_brief "$id" direct-PR
  add_receipt "$id" AC1 test passed
  add_receipt "$id" AC2 lint passed
  alias="$TMP_ROOT/checker-ledger-alias"
  ln "$HOME_DIR/data/$id/evidence.jsonl" "$alias"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "checker rejects a multiply linked evidence ledger"
  pass "fm-receipt-check pins task evidence and rejects hard-linked ledgers"
}

test_checker_never_consults_no_mistakes() {
  [ ! -s "$NM_CALL_LOG" ] || fail "the receipt checker invoked no-mistakes: $(cat "$NM_CALL_LOG")"
  pass "receipt accounting never consults No-Mistakes"
}

test_complete_evidence_reports_v2_shape
test_missing_criterion_is_named
test_failed_evidence_does_not_satisfy_and_latest_wins
test_unknown_criterion_and_malformed_records_are_invalid
test_accepted_blocked_accounts_without_evidencing
test_criterion_query_and_parser_share_one_grammar
test_checker_offers_only_accounting_options
test_delivery_mode_mismatch_fails_closed
test_metadata_hard_links_are_rejected_by_the_pinned_owner
test_invalid_brief_and_scout_behavior
test_early_snapshot_failure_does_not_block_cleanup
test_readiness_publication_failure_is_terminal
test_pinned_checker_rejects_redirected_and_linked_evidence
test_checker_never_consults_no_mistakes
