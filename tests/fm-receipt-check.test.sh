#!/usr/bin/env bash
# Behavior tests for evidence completeness, risk routing, and audit packets.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-receipt-check.sh"
RECEIPT="$ROOT/bin/fm-receipt.sh"
TMP_ROOT=$(fm_test_tmproot fm-receipt-check)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
fm_git_identity fmtest fmtest@example.invalid

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
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship" "mode=$mode"
}

add_receipt() {  # <id> <criterion> <type> <result>
  local id=$1 criterion=$2 type=$3 result=$4 file=${5:-}
  if [ -n "$file" ]; then
    FM_HOME="$HOME_DIR" "$RECEIPT" "$id" "$criterion" "$type" "evidence for $criterion" "$result" --file "$file" >/dev/null \
      || fail "could not append fixture receipt for $id/$criterion"
  else
    FM_HOME="$HOME_DIR" "$RECEIPT" "$id" "$criterion" "$type" "evidence for $criterion" "$result" >/dev/null \
      || fail "could not append fixture receipt for $id/$criterion"
  fi
}

make_project() {  # <id> <mode> <surface> -> prints base
  local id=$1 mode=$2 surface=$3 project="$TMP_ROOT/project-$1" base
  mkdir -p "$project"
  git -C "$project" init -q
  printf 'seed\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -q -m init
  git -C "$project" branch -M main
  base=$(git -C "$project" rev-parse HEAD)
  git -C "$project" checkout -q -b "fm/$id"
  case "$surface" in
    docs)
      printf 'seed\nupdated docs\n' > "$project/README.md"
      ;;
    localized)
      mkdir -p "$project/src" "$project/tests"
      printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' > "$project/src/app.sh"
      printf '#!/usr/bin/env bash\n./src/app.sh\n' > "$project/tests/app.test.sh"
      ;;
    auth)
      mkdir -p "$project/src" "$project/tests"
      printf 'validate_token() { return 0; }\n' > "$project/src/authentication.sh"
      printf '#!/usr/bin/env bash\n./src/authentication.sh\n' > "$project/tests/auth.test.sh"
      ;;
    config)
      printf 'root = true\n' > "$project/.editorconfig"
      ;;
    package)
      printf '{"scripts":{"postinstall":"./setup.sh"}}\n' > "$project/package.json"
      ;;
  esac
  git -C "$project" add .
  git -C "$project" commit -q -m change
  write_brief "$id" "$mode"
  fm_write_meta "$HOME_DIR/state/$id.meta" "worktree=$project" "kind=ship" "mode=$mode"
  printf '%s\n' "$base"
}

test_reports_missing_criteria_deterministically() {
  local id=missing-evidence out rc
  write_brief "$id" no-mistakes
  add_receipt "$id" AC2 lint passed
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id"); rc=$?
  expect_code 1 "$rc" "missing evidence exits 1"
  printf '%s' "$out" | jq -e '
    .schema == "fm-evidence-check.v1" and .status == "missing"
    and .required == ["AC1","AC2"] and .evidenced == ["AC2"]
    and .missing == ["AC1"] and .receipt_count == 1
  ' >/dev/null || fail "missing-evidence JSON was not deterministic"
  pass "fm-receipt-check reports required, evidenced, and missing ids deterministically"
}

test_complete_and_invalid_ledgers_have_distinct_results() {
  local id=complete-evidence out rc
  write_brief "$id" direct-PR
  add_receipt "$id" AC1 test "4 passed"
  add_receipt "$id" AC2 lint clean
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id"); rc=$?
  expect_code 0 "$rc" "complete evidence exits 0"
  printf '%s' "$out" | jq -e '.status == "complete" and .missing == [] and .receipt_count == 2' >/dev/null \
    || fail "complete evidence JSON is wrong"
  printf '%s\n' '{"criterion":"AC1","type":"test","summary":"x","result":"passed","extra":true}' \
    >> "$HOME_DIR/data/$id/evidence.jsonl"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id"); rc=$?
  expect_code 2 "$rc" "invalid ledger exits 2"
  printf '%s' "$out" | jq -e '.status == "invalid" and (.invalid | length) == 1' >/dev/null \
    || fail "invalid ledger was not reported mechanically"
  pass "fm-receipt-check distinguishes complete evidence from invalid JSONL"
}

test_invalid_brief_and_scout_behavior() {
  local id=placeholder-brief rc out scout=scout-brief old=old-ship-brief
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

  mkdir -p "$HOME_DIR/data/$scout"
  printf '# Task\nInvestigate only.\n' > "$HOME_DIR/data/$scout/brief.md"
  fm_write_meta "$HOME_DIR/state/$scout.meta" "kind=scout"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$scout"); rc=$?
  expect_code 0 "$rc" "scout evidence check is not applicable"
  printf '%s' "$out" | jq -e '.status == "not-applicable" and .kind == "non-ship"' >/dev/null \
    || fail "scout behavior did not remain separate"
  [ ! -e "$HOME_DIR/data/$scout/evidence.jsonl" ] || fail "checker created a scout ledger"
  pass "invalid ship briefs fail and scout/report behavior stays unchanged"
}

test_low_risk_skips_no_mistakes_under_explicit_policy() {
  local id=low-docs base out meta
  base=$(make_project "$id" no-mistakes docs)
  add_receipt "$id" AC1 lint "passed"
  add_receipt "$id" AC2 review "reviewed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "low-risk plan failed"
  printf '%s' "$out" | jq -e '.tier == "low" and .path == "receipts-mechanical" and .packet == null' >/dev/null \
    || fail "narrow mechanically proven docs change did not take the low path"
  meta="$HOME_DIR/state/$id.meta"
  grep -qx 'validation_tier=low' "$meta" || fail "low tier was not recorded durably"
  grep -qx 'validation_path=receipts-mechanical' "$meta" || fail "low path was not recorded durably"
  pass "low-risk mechanical changes can skip a full No-Mistakes run"
}

test_low_config_requires_allowlist_and_applicable_proof() {
  local id base out
  id=package-config
  base=$(make_project "$id" no-mistakes package)
  add_receipt "$id" AC1 lint "passed"
  add_receipt "$id" AC2 review "reviewed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "package-manifest plan failed"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "weak-evidence"' >/dev/null \
    || fail "package manifest was treated as low-risk mechanical config"

  id=allowlisted-config-unbound
  base=$(make_project "$id" no-mistakes config)
  add_receipt "$id" AC1 lint "passed"
  add_receipt "$id" AC2 review "reviewed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "unbound config plan failed"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "unbound-mechanical-config"' >/dev/null \
    || fail "unbound config receipt was treated as applicable proof"

  id=allowlisted-config-bound
  base=$(make_project "$id" no-mistakes config)
  add_receipt "$id" AC1 lint "passed" .editorconfig
  add_receipt "$id" AC2 review "reviewed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "bound config plan failed"
  printf '%s' "$out" | jq -e '.tier == "low" and .path == "receipts-mechanical"' >/dev/null \
    || fail "allowlisted config with applicable proof did not take the low path"
  pass "low config requires an allowlisted path and applicable proof"
}

test_medium_plan_writes_a_bounded_audit_packet() {
  local id=medium-feature base out packet meta
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 typecheck "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" --change-class localized-non-sensitive --risky-area "parser boundary") \
    || fail "medium-risk plan failed"
  printf '%s' "$out" | jq -e '.tier == "medium" and .path == "targeted-no-mistakes" and (.packet | type == "string")' >/dev/null \
    || fail "localized tested change did not take the targeted path"
  packet=$(printf '%s' "$out" | jq -r '.packet')
  assert_present "$packet" "targeted audit packet was not written"
  assert_grep '## Task contract' "$packet" "packet omitted the task contract"
  assert_grep '## Evidence receipts' "$packet" "packet omitted evidence"
  assert_grep '## Diff' "$packet" "packet omitted the base..HEAD diff"
  assert_grep 'parser boundary' "$packet" "packet omitted declared risky areas"
  assert_grep 'Do not reimplement the feature during review.' "$packet" "packet omitted the bounded audit remit"
  meta="$HOME_DIR/state/$id.meta"
  grep -qx 'validation_path=targeted-no-mistakes' "$meta" || fail "targeted path was not recorded"
  pass "medium-risk work produces a brief, evidence, diff, and risky-area audit packet"
}

test_high_risk_and_uncertain_inputs_fail_safe() {
  local id=high-auth base out rc project
  base=$(make_project "$id" no-mistakes auth)
  add_receipt "$id" AC1 test "3 passed"
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "high-risk plan should still be a successful plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .path == "full-no-mistakes"' >/dev/null \
    || fail "auth surface did not retain full No-Mistakes"

  id=weak-test-proof
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "not passed"
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "weak-evidence plan should still be a successful plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "weak-evidence"' >/dev/null \
    || fail "a negative test receipt was treated as strong regression proof"

  id=zero-test-proof
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "0 tests passed"
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" --risky-area "parser boundary") \
    || fail "zero-test plan should still be a successful plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "weak-evidence"' >/dev/null \
    || fail "zero tests passed was treated as regression proof"

  id=skipped-test-proof
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed, 1 skipped"
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" --risky-area "parser boundary") \
    || fail "skipped-test plan should still be a successful plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "weak-evidence"' >/dev/null \
    || fail "a skipped test run was treated as regression proof"

  id=unclassified-login
  base=$(make_project "$id" no-mistakes localized)
  project="$TMP_ROOT/project-$id"
  mv "$project/src/app.sh" "$project/src/login.sh"
  mv "$project/tests/app.test.sh" "$project/tests/login.test.sh"
  git -C "$project" add -A
  git -C "$project" commit -q -m 'rename fixture to login surface'
  add_receipt "$id" AC1 test "3 passed"
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "unclassified login plan should still be a successful plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "unclassified-change"' >/dev/null \
    || fail "filename silence downgraded an unclassified login change"

  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" --risky-area "login flow") \
    || fail "free-form login plan should still be a successful plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "unclassified-change"' >/dev/null \
    || fail "free-form risky-area text was treated as positive safety proof"

  id=uncertain-base
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "passed"
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base does-not-exist); rc=$?
  expect_code 0 "$rc" "uncertain diff still records a conservative plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "unreadable-or-empty-diff"' >/dev/null \
    || fail "unreadable base did not fail safe to high"
  pass "security and uncertain changes retain full No-Mistakes validation"
}

test_direct_and_local_modes_never_invoke_no_mistakes() {
  local mode id base out expected
  for mode in direct-PR local-only; do
    id="mode-${mode}"
    base=$(make_project "$id" "$mode" localized)
    add_receipt "$id" AC1 test "passed"
    add_receipt "$id" AC2 lint "passed"
    out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" --change-class localized-non-sensitive --risky-area "localized fixture") \
      || fail "$mode plan failed"
    expected=$mode
    printf '%s' "$out" | jq -e --arg expected "$expected" '.tier == "medium" and .path == $expected and .packet == null' >/dev/null \
      || fail "$mode accidentally entered a No-Mistakes path"
  done
  pass "direct-PR and local-only retain evidence gates without invoking No-Mistakes"
}

test_follow_up_packet_uses_finding_delta_and_updated_receipts() {
  local id=medium-followup base initial_head current_head project out packet rc
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" --change-class localized-non-sensitive --risky-area "localized fixture" >/dev/null \
    || fail "initial medium plan failed"
  project="$TMP_ROOT/project-$id"
  initial_head=$(git -C "$project" rev-parse HEAD)
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --follow-up --delta-base "$initial_head" \
    --change-class localized-non-sensitive --risky-area "localized fixture" \
    --finding "F1: output assertion was incomplete" 2>&1)
  rc=$?
  expect_code 2 "$rc" "follow-up refuses an unchanged head"
  assert_contains "$out" "strict descendant" "unchanged-head refusal did not identify the delta contract"
  printf '#!/usr/bin/env bash\nprintf "fixed\\n"\n' > "$project/src/app.sh"
  git -C "$project" add src/app.sh
  git -C "$project" commit -q -m 'resolve finding'
  current_head=$(git -C "$project" rev-parse HEAD)
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --follow-up --delta-base "$current_head" \
    --finding "F1: output assertion was incomplete" 2>&1)
  rc=$?
  expect_code 2 "$rc" "follow-up refuses a delta base that omits the finding fix"
  assert_contains "$out" "latest recorded validation head" "follow-up refusal did not identify the continuity contract"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --follow-up --delta-base "$initial_head" \
    --change-class localized-non-sensitive --risky-area "localized fixture" \
    --finding "F1: output assertion was incomplete" --invalidated-criterion AC99 2>&1)
  rc=$?
  expect_code 2 "$rc" "follow-up rejects undeclared invalidated criteria"
  assert_contains "$out" "not declared" "invalidated-criterion refusal did not identify the bad id"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --follow-up --delta-base "$initial_head" \
    --change-class localized-non-sensitive --risky-area "localized fixture" \
    --finding "F1: output assertion was incomplete" --invalidated-criterion AC1 2>&1)
  rc=$?
  expect_code 2 "$rc" "follow-up requires post-boundary evidence for invalidated criteria"
  assert_contains "$out" "requires a new receipt" "missing replacement evidence was not identified"
  add_receipt "$id" AC1 test "3 passed after fix"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --follow-up --delta-base "$initial_head" \
    --change-class localized-non-sensitive --risky-area "localized fixture" \
    --finding "F1: output assertion was incomplete" --invalidated-criterion AC1) \
    || fail "bounded follow-up plan failed"
  printf '%s' "$out" | jq -e '
    .status == "follow-up-ready" and .tier == "medium"
    and .finding_count == 1 and .invalidated_receipt_count == 1
  ' >/dev/null || fail "follow-up instrumentation is incomplete"
  packet=$(printf '%s' "$out" | jq -r '.packet')
  assert_grep 'Packet kind: follow-up.' "$packet" "follow-up packet was not marked"
  assert_grep 'F1: output assertion was incomplete' "$packet" "follow-up packet omitted the finding"
  assert_grep '3 passed after fix' "$packet" "follow-up packet omitted updated receipts"
  assert_grep "Review diff: $initial_head.." "$packet" "follow-up packet did not bind the delta base"
  grep -qx 'validation_pass=follow-up' "$HOME_DIR/state/$id.meta" || fail "follow-up pass was not recorded"
  pass "follow-up validation is bounded to the finding, delta, and updated receipts"
}

test_follow_up_scope_change_requires_full_rerun() {
  local id=medium-scope-change base initial_head project out rc
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" --change-class localized-non-sensitive --risky-area "localized fixture" >/dev/null \
    || fail "initial medium plan failed"
  project="$TMP_ROOT/project-$id"
  initial_head=$(git -C "$project" rev-parse HEAD)
  printf 'validate_login() { return 0; }\n' > "$project/src/login.ts"
  git -C "$project" add src/login.ts
  git -C "$project" commit -q -m 'expand into login surface'
  add_receipt "$id" AC1 test "3 passed after expansion"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --follow-up --delta-base "$initial_head" \
    --finding "F2: implementation expanded into login handling")
  rc=$?
  expect_code 1 "$rc" "material follow-up risk change refuses a bounded packet"
  printf '%s' "$out" | jq -e '
    .status == "full-rerun-required" and .tier == "high"
    and .path == "full-no-mistakes" and .reason == "follow-up-scope-or-risk-changed"
  ' >/dev/null || fail "scope-changing follow-up did not retain a full rerun"
  pass "material follow-up scope changes retain full No-Mistakes validation"
}

test_reports_missing_criteria_deterministically
test_complete_and_invalid_ledgers_have_distinct_results
test_invalid_brief_and_scout_behavior
test_low_risk_skips_no_mistakes_under_explicit_policy
test_low_config_requires_allowlist_and_applicable_proof
test_medium_plan_writes_a_bounded_audit_packet
test_high_risk_and_uncertain_inputs_fail_safe
test_direct_and_local_modes_never_invoke_no_mistakes
test_follow_up_packet_uses_finding_delta_and_updated_receipts
test_follow_up_scope_change_requires_full_rerun
