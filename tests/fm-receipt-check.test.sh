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
FAKE_NO_MISTAKES="$TMP_ROOT/fake-no-mistakes"
cat > "$FAKE_NO_MISTAKES" <<'EOF'
#!/bin/sh
[ -z "${FM_NM_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_NM_LOG"
printf '%s\n' "$FM_FAKE_NM_STATUS"
EOF
chmod +x "$FAKE_NO_MISTAKES"
export FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES"
FAIL_NO_MISTAKES="$TMP_ROOT/fail-no-mistakes"
cat > "$FAIL_NO_MISTAKES" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$FAIL_NO_MISTAKES"

nm_status() {  # <run-id> <head> <outcome>
  local status
  if [ "$3" = passed ]; then status=completed; else status=running; fi
  printf 'run:\n  id: "%s"\n  status: %s\n  head: "%s"\noutcome: %s\n' "$1" "$status" "$2" "$3"
}

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
      printf 'release note\n' > "$project/CHANGELOG.md"
      ;;
    authoritative_docs)
      printf 'seed\nsecurity deployment instructions\n' > "$project/README.md"
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
  local id=low-docs base out meta project validated_head new_head rc
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
  grep -Eq '^validation_started_at=[0-9]+$' "$meta" || fail "low plan omitted validation start time"
  project="$TMP_ROOT/project-$id"
  validated_head=$(git -C "$project" rev-parse HEAD)
  ! grep -q '^validation_completed_at=' "$meta" || fail "low plan completed before post-plan mechanical evidence"
  add_receipt "$id" AC1 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence mechanical-checks-passed >/dev/null \
    || fail "low plan did not complete after post-plan mechanical evidence"
  grep -qx "validation_completed_head=$validated_head" "$meta" \
    || fail "low completion was not bound to its validated head"
  printf 'post-validation correction\n' >> "$project/CHANGELOG.md"
  git -C "$project" add CHANGELOG.md
  git -C "$project" commit -q -m 'post-validation correction'
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence mechanical-checks-passed 2>&1)
  rc=$?
  expect_code 2 "$rc" "completion refuses code changed after validation"
  assert_contains "$out" "replan and revalidate" "stale completion refusal omitted recovery guidance"
  [ "$(grep '^validation_completed_head=' "$meta" | tail -1)" = 'validation_completed_head=' ] \
    || fail "stale completion remained active after the head changed"
  new_head=$(git -C "$project" rev-parse HEAD)
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null \
    || fail "corrected low-risk change could not be replanned"
  add_receipt "$id" AC1 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence mechanical-checks-passed >/dev/null \
    || fail "replanned low-risk change did not complete"
  [ "$(grep '^validation_completed_head=' "$meta" | tail -1)" = "validation_completed_head=$new_head" ] \
    || fail "replanned completion did not bind the corrected head"
  pass "low-risk mechanical changes can skip a full No-Mistakes run"
}

test_authoritative_docs_remain_high() {
  local id=unclassified-docs base out
  base=$(make_project "$id" no-mistakes authoritative_docs)
  add_receipt "$id" AC1 lint "passed"
  add_receipt "$id" AC2 review "reviewed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "unclassified documentation plan failed"
  printf '%s' "$out" | jq -e '.tier == "high" and .path == "full-no-mistakes"' >/dev/null \
    || fail "authoritative documentation reached low"
  pass "authoritative documentation remains high"
}

test_terminal_paths_record_completion_at_their_boundary() {
  local mode id base out meta expected_head evidence observed rc running_status passed_status
  for mode in no-mistakes direct-PR local-only; do
    id="completion-${mode}"
    base=$(make_project "$id" "$mode" localized)
    add_receipt "$id" AC1 test "2 passed"
    add_receipt "$id" AC2 lint "passed"
    FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "$mode timing plan failed"
    meta="$HOME_DIR/state/$id.meta"
    grep -Eq '^validation_started_at=[0-9]+$' "$meta" || fail "$mode omitted validation start time"
    ! grep -q '^validation_completed_at=' "$meta" || fail "$mode completed validation during planning"
    case "$mode" in
      no-mistakes) evidence=no-mistakes-passed; observed=bound-matching-no-mistakes-run ;;
      direct-PR) evidence=pr-opened; observed=canonical-non-github-pr ;;
      local-only) evidence=branch-ready; observed=clean-ready-branch ;;
    esac
    FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence wrong-boundary >/dev/null 2>&1
    rc=$?
    expect_code 2 "$rc" "$mode rejects terminal evidence for another path"
    if [ "$mode" != local-only ]; then
      FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence "$evidence" >/dev/null 2>&1
      rc=$?
      expect_code 2 "$rc" "$mode rejects unobserved terminal evidence"
    fi
    expected_head=$(git -C "$TMP_ROOT/project-$id" rev-parse HEAD)
    case "$mode" in
      no-mistakes)
        running_status=$(nm_status RUN-$id "$expected_head" pending)
        passed_status=$(nm_status RUN-$id "$expected_head" checks-passed)
        FM_FAKE_NM_STATUS="$running_status" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
          "$CHECK" "$id" --bind-run RUN-$id --generation "$(grep '^validation_generation=' "$meta" | tail -1 | cut -d= -f2-)" >/dev/null || fail "$mode run binding failed"
        FM_FAKE_NM_STATUS="$(nm_status RUN-$id "$base" passed)" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" \
          FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence "$evidence" >/dev/null 2>&1
        rc=$?
        expect_code 2 "$rc" "No-Mistakes completion rejects a different run head"
        printf 'validation_run_path=receipts-mechanical\n' >> "$meta"
        FM_FAKE_NM_STATUS="$passed_status" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
          "$CHECK" "$id" --complete --terminal-evidence "$evidence" >/dev/null 2>&1
        rc=$?
        expect_code 2 "$rc" "No-Mistakes completion rejects a different run path"
        printf 'validation_run_path=full-no-mistakes\n' >> "$meta"
        ;;
      direct-PR)
        printf 'pr=https://gitlab.example/o/r/-/merge_requests/1\n' >> "$meta"
        ;;
      local-only) ;;
    esac
    if [ "$mode" = no-mistakes ]; then
      out=$(FM_FAKE_NM_STATUS="$passed_status" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
        "$CHECK" "$id" --complete --terminal-evidence "$evidence") || fail "$mode completion recording failed"
    else
      out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence "$evidence") \
        || fail "$mode completion recording failed"
    fi
    printf '%s' "$out" | jq -e --arg head "$expected_head" \
      --arg evidence "$observed" \
      '.status == "completed" and (.completed_at | type == "number") and .completed_head == $head and .evidence == $evidence' >/dev/null \
      || fail "$mode completion output was not machine-readable"
    if [ "$mode" = no-mistakes ]; then
      FM_FAKE_NM_STATUS="$passed_status" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
        "$CHECK" "$id" --complete --terminal-evidence "$evidence" >/dev/null || fail "$mode duplicate completion failed"
    else
      FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence "$evidence" >/dev/null \
        || fail "$mode duplicate completion failed"
    fi
    [ "$(grep -c '^validation_completed_at=' "$meta")" -eq 1 ] || fail "$mode completion was not idempotent"
    [ "$(grep -c '^validation_completed_head=' "$meta")" -eq 1 ] || fail "$mode completed head was not idempotent"
    [ "$(grep -c '^validation_completed_path=' "$meta")" -eq 1 ] || fail "$mode completed path was not idempotent"
    [ "$(grep -c '^validation_completed_evidence=' "$meta")" -eq 1 ] || fail "$mode terminal evidence was not idempotent"
  done
  pass "terminal delivery paths record one completion timestamp at their boundary"
}

test_completion_signal_releases_validation_lock() {
  local id=completion-signal base fakebin rc expected_head running_status passed_status
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "signal fixture plan failed"
  expected_head=$(git -C "$TMP_ROOT/project-$id" rev-parse HEAD)
  running_status=$(nm_status RUN-signal "$expected_head" pending)
  passed_status=$(nm_status RUN-signal "$expected_head" passed)
  FM_FAKE_NM_STATUS="$running_status" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-signal --generation "$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)" >/dev/null || fail "signal fixture run binding failed"
  fakebin="$TMP_ROOT/signal-fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/date" <<'EOF'
#!/bin/sh
kill -TERM "$PPID"
exit 1
EOF
  chmod +x "$fakebin/date"
  PATH="$fakebin:$PATH" FM_FAKE_NM_STATUS="$passed_status" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete \
    --terminal-evidence no-mistakes-passed >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "completion ignored the injected termination signal"
  [ ! -d "$HOME_DIR/state/.$id.validation-plan.lock" ] || fail "termination stranded the validation lock"
  FM_FAKE_NM_STATUS="$passed_status" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence no-mistakes-passed >/dev/null \
    || fail "completion could not retry after signal cleanup"
  pass "completion signals release the validation lock for retry"
}

test_replan_invalidates_run_binding() {
  local id=replan-binding base project head running passed rc
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "initial binding plan failed"
  project="$TMP_ROOT/project-$id"
  head=$(git -C "$project" rev-parse HEAD)
  running=$(nm_status RUN-old "$head" pending)
  passed=$(nm_status RUN-old "$head" passed)
  FM_FAKE_NM_STATUS="$running" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-old --generation "$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)" >/dev/null || fail "initial run binding failed"
  FM_FAKE_NM_STATUS="$running" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "replan failed"
  FM_FAKE_NM_STATUS="$passed" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --complete --terminal-evidence no-mistakes-passed >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "replan invalidates the prior run binding"
  pass "replanning invalidates prior run and completion bindings"
}

test_dirty_worktrees_cannot_plan_or_complete() {
  local id=dirty-plan base project out rc
  base=$(make_project "$id" no-mistakes docs)
  add_receipt "$id" AC1 lint "passed"
  add_receipt "$id" AC2 review "reviewed"
  project="$TMP_ROOT/project-$id"
  mkdir -p "$project/src"
  printf 'uncommitted secret\n' > "$project/src/security.txt"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "dirty worktree cannot be planned"

  id=dirty-completion
  base=$(make_project "$id" local-only localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "dirty completion fixture plan failed"
  project="$TMP_ROOT/project-$id"
  printf 'untracked\n' > "$project/untracked.txt"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence branch-ready >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "dirty worktree cannot complete"
  pass "dirty worktrees cannot be planned or completed"
}

test_direct_and_local_plans_never_query_no_mistakes() {
  local mode id base log
  log="$TMP_ROOT/non-nm-plan.log"
  : > "$log"
  for mode in direct-PR local-only; do
    id="no-nm-${mode}"
    base=$(make_project "$id" "$mode" localized)
    add_receipt "$id" AC1 test "2 passed"
    add_receipt "$id" AC2 lint "passed"
    FM_NM_LOG="$log" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
      "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "$mode plan failed"
  done
  [ ! -s "$log" ] || fail "direct/local planning invoked No-Mistakes"
  pass "direct and local plans never invoke No-Mistakes"
}

test_local_completion_requires_fast_forward_readiness() {
  local id=local-diverged base project rc
  base=$(make_project "$id" local-only localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "local divergence fixture plan failed"
  project="$TMP_ROOT/project-$id"
  git -C "$project" checkout -q main
  printf 'advanced\n' >> "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -q -m 'advance main'
  git -C "$project" checkout -q "fm/$id"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence branch-ready >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "diverged local branch cannot complete"

  id=local-missing-default
  base=$(make_project "$id" local-only localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  project="$TMP_ROOT/project-$id"
  git -C "$project" update-ref refs/remotes/origin/develop "$base"
  git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "missing-default fixture plan failed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence branch-ready >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "missing authoritative local default branch cannot complete"
  pass "local completion requires fast-forward readiness"
}



test_high_risk_and_uncertain_inputs_fail_safe() {
  local id=high-auth base out rc project hidden_base current_head running_status
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
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "default-high"' >/dev/null \
    || fail "a negative test receipt was treated as strong regression proof"

  id=zero-test-proof
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "0 tests passed"
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "zero-test plan should still be a successful plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "default-high"' >/dev/null \
    || fail "zero tests passed was treated as regression proof"

  id=skipped-test-proof
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed, 1 skipped"
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "skipped-test plan should still be a successful plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "default-high"' >/dev/null \
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
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "default-high"' >/dev/null \
    || fail "filename silence downgraded an unclassified login change"

  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" --risky-area "login flow" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "removed risk hints are rejected"

  id=hidden-sensitive-base
  base=$(make_project "$id" no-mistakes auth)
  project="$TMP_ROOT/project-$id"
  hidden_base=$(git -C "$project" rev-parse HEAD)
  printf 'documentation tail\n' >> "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -q -m 'documentation tail'
  add_receipt "$id" AC1 lint "passed"
  add_receipt "$id" AC2 review "reviewed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$hidden_base") \
    || fail "mismatched base should produce a conservative plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "unreadable-or-empty-diff"' >/dev/null \
    || fail "caller-selected ancestor hid a sensitive commit"

  id=uncertain-base
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "passed"
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base does-not-exist); rc=$?
  expect_code 0 "$rc" "uncertain diff still records a conservative plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "unreadable-or-empty-diff"' >/dev/null \
    || fail "unreadable base did not fail safe to high"

  id=preplan-run
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  project="$TMP_ROOT/project-$id"
  current_head=$(git -C "$project" rev-parse HEAD)
  running_status=$(nm_status OLD-RUN "$current_head" pending)
  FM_FAKE_NM_STATUS="$running_status" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "preplan-run fixture planning failed"
  FM_FAKE_NM_STATUS="$running_status" FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run OLD-RUN --generation "$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "run active before planning cannot bind to the new plan"

  id=preplan-observation-failure
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  FM_NO_MISTAKES_BIN="$FAIL_NO_MISTAKES" FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "full validation planning fails closed when its run boundary is unavailable"

  id=dangling-origin-head
  base=$(make_project "$id" no-mistakes docs)
  project="$TMP_ROOT/project-$id"
  git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/missing
  add_receipt "$id" AC1 lint "passed"
  add_receipt "$id" AC2 review "reviewed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan) || fail "dangling origin plan should fail safe"
  printf '%s' "$out" | jq -e '.tier == "high" and .reason == "unreadable-or-empty-diff"' >/dev/null \
    || fail "dangling origin HEAD fell back to a low local base"
  pass "security and uncertain changes retain full No-Mistakes validation"
}

test_direct_and_local_modes_never_invoke_no_mistakes() {
  local mode id base out expected
  for mode in direct-PR local-only; do
    id="mode-${mode}"
    base=$(make_project "$id" "$mode" localized)
    add_receipt "$id" AC1 test "passed"
    add_receipt "$id" AC2 lint "passed"
    out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
      || fail "$mode plan failed"
    expected=$mode
    printf '%s' "$out" | jq -e --arg expected "$expected" '.tier == "high" and .path == $expected' >/dev/null \
      || fail "$mode accidentally entered a No-Mistakes path"
  done
  pass "direct-PR and local-only retain evidence gates without invoking No-Mistakes"
}



test_reports_missing_criteria_deterministically
test_complete_and_invalid_ledgers_have_distinct_results
test_invalid_brief_and_scout_behavior
test_low_risk_skips_no_mistakes_under_explicit_policy
test_authoritative_docs_remain_high
test_terminal_paths_record_completion_at_their_boundary
test_completion_signal_releases_validation_lock
test_replan_invalidates_run_binding
test_dirty_worktrees_cannot_plan_or_complete
test_direct_and_local_plans_never_query_no_mistakes
test_local_completion_requires_fast_forward_readiness
test_high_risk_and_uncertain_inputs_fail_safe
test_direct_and_local_modes_never_invoke_no_mistakes
