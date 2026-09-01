#!/usr/bin/env bash
# Behavior tests for evidence completeness and risk routing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-receipt-check.sh"
RECEIPT="$ROOT/bin/fm-receipt.sh"
STORE="$ROOT/bin/fm-receipt-store.sh"
SCHEMA="$ROOT/bin/fm-receipt-schema.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
LOCAL_DEFAULT="$ROOT/bin/fm-local-default.sh"
TMP_ROOT=$(fm_test_tmproot fm-receipt-check)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state"
fm_git_identity fmtest fmtest@example.invalid
FAKE_NO_MISTAKES="$TMP_ROOT/fake-no-mistakes"
cat > "$FAKE_NO_MISTAKES" <<'EOF'
#!/bin/sh
[ -z "${FM_NM_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_NM_LOG"
case "$*" in
  *"axi logs --step intent --run "*) printf '%s\n' "${FM_FAKE_NM_INTENT:-}" ;;
  *"axi logs --step ci --run "*) printf '%s\n' "${FM_FAKE_NM_CI_LOG:-}" ;;
  *) printf '%s\n' "$FM_FAKE_NM_STATUS" ;;
esac
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

nm_pipeline_status() {  # <run-id> <branch> <head> <status> <outcome> <sync-state>
  printf 'run:\n  id: "%s"\n  branch: %s\n  status: %s\n  head: "%s"\noutcome: %s\nbranch_sync:\n  state: %s\n' \
    "$1" "$2" "$4" "$3" "$5" "$6"
}

test_help_advertises_generation_bound_run_binding() {
  local out
  out=$("$CHECK" --help) || fail "receipt checker help failed"
  assert_contains "$out" "--bind-run <run-id> --generation <plan-generation>" \
    "receipt checker help omitted the required run generation"
  assert_contains "$out" "--implementation-complete" \
    "receipt checker help omitted the implementation boundary action"
  assert_contains "$out" "refreshes it when that head changes" \
    "receipt checker help misstated current-head timestamp refresh"
  assert_contains "$out" "--mechanical-ready" \
    "receipt checker help omitted the receipts-mechanical readiness command"
  assert_contains "$out" "bin/fm-pr-check.sh <task-id> <url>" \
    "receipt checker help omitted canonical LOW PR registration"
  out=$("$STORE" --help) || fail "receipt store help failed"
  assert_contains "$out" "hold <brief-out> <ledger-out>" \
    "receipt store help omitted the pinned read mode"
  assert_contains "$out" "append <criterion> <criterion-parser>" \
    "receipt store help omitted the pinned append mode"
  assert_contains "$out" "recovers identity-bound" \
    "receipt store help omitted promotion recovery ownership"
  out=$("$SCHEMA" --help) || fail "receipt schema help failed"
  assert_contains "$out" "Usage: fm-receipt-schema.sh" \
    "receipt schema help omitted its executable interface"
  assert_contains "$out" "required criterion, type, outcome" \
    "receipt schema help omitted its required key contract"
  out=$("$LOCAL_DEFAULT" --help) || fail "local default help failed"
  assert_contains "$out" "Usage: fm-local-default.sh <repository>" \
    "local default help omitted its executable interface"
  out=$("$BRIEF" --render-ship-delivery help-task no-mistakes) \
    || fail "ship delivery renderer failed"
  assert_contains "$out" "fm-receipt-check.sh help-task --implementation-complete" \
    "generated ship sequence omitted the implementation boundary action"
  pass "fm-receipt-check help renders an executable generation-bound bind command"
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
  : > "$HOME_DIR/data/$id/.evidence.lock"
  fm_write_meta "$HOME_DIR/state/$id.meta" "kind=ship" "mode=$mode"
}

add_receipt() {  # <id> <criterion> <type> <result> [file] [outcome]
  local id=$1 criterion=$2 type=$3 result=$4 file=${5:-} outcome=${6:-success}
  if [ -n "$file" ]; then
    FM_HOME="$HOME_DIR" "$RECEIPT" "$id" "$criterion" "$type" "evidence for $criterion" "$result" --outcome "$outcome" --file "$file" >/dev/null \
      || fail "could not append fixture receipt for $id/$criterion"
  else
    FM_HOME="$HOME_DIR" "$RECEIPT" "$id" "$criterion" "$type" "evidence for $criterion" "$result" --outcome "$outcome" >/dev/null \
      || fail "could not append fixture receipt for $id/$criterion"
  fi
  if [ "$criterion" = AC2 ] && grep -q '^worktree=' "$HOME_DIR/state/$id.meta" 2>/dev/null; then
    FM_HOME="$HOME_DIR" "$CHECK" "$id" --implementation-complete >/dev/null 2>&1 || true
  fi
}

make_project() {  # <id> <mode> <surface> -> prints base
  local id=$1 mode=$2 surface=$3 project="$TMP_ROOT/project-$1" base
  mkdir -p "$project"
  git -C "$project" init -q
  printf 'seed\n' > "$project/README.md"
  case "$surface" in
    docs) printf 'Release note\n' > "$project/CHANGELOG.md" ;;
    policy_docs) printf 'Passwords expire in 90 days.\n' > "$project/CHANGELOG.md" ;;
  esac
  git -C "$project" add .
  git -C "$project" commit -q -m init
  git -C "$project" branch -M main
  base=$(git -C "$project" rev-parse HEAD)
  git -C "$project" checkout -q -b "fm/$id"
  case "$surface" in
    docs)
      printf 'Release  note\n' > "$project/CHANGELOG.md"
      ;;
    policy_docs)
      printf 'Passwords expire in 30 days.\n' > "$project/CHANGELOG.md"
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
  printf '%s\n' '{"criterion":"AC1","type":"test","outcome":"passed","summary":"x","result":"passed","extra":true}' \
    >> "$HOME_DIR/data/$id/evidence.jsonl"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id"); rc=$?
  expect_code 2 "$rc" "invalid ledger exits 2"
  printf '%s' "$out" | jq -e '.status == "invalid" and (.invalid | length) == 1' >/dev/null \
    || fail "invalid ledger was not reported mechanically"

  id=whitespace-ledger
  write_brief "$id" direct-PR
  printf '%s\n' '{"criterion":"AC1","type":"test","outcome":"passed","summary":"   ","result":"passed"}' \
    '{"criterion":"AC2","type":"lint","outcome":"passed","summary":"lint","result":"   "}' \
    > "$HOME_DIR/data/$id/evidence.jsonl"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id"); rc=$?
  expect_code 2 "$rc" "whitespace-only ledger strings are invalid"
  printf '%s' "$out" | jq -e '.status == "invalid"' >/dev/null \
    || fail "whitespace-only summary was not reported invalid"

  id=nonstring-pointer-ledger
  write_brief "$id" direct-PR
  printf '%s\n' '{"criterion":"AC1","type":"test","outcome":"passed","summary":"test","result":"passed","command":null}' \
    '{"criterion":"AC2","type":"lint","outcome":"passed","summary":"lint","result":"passed","file":false}' \
    > "$HOME_DIR/data/$id/evidence.jsonl"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id"); rc=$?
  expect_code 2 "$rc" "present optional pointer values must be strings"
  printf '%s' "$out" | jq -e '.status == "invalid" and (.invalid | length) == 2' >/dev/null \
    || fail "non-string optional pointers were not reported invalid"
  pass "fm-receipt-check distinguishes complete evidence from invalid JSONL"
}

test_closed_outcomes_control_evidence() {
  local id=closed-outcomes out rc
  write_brief "$id" direct-PR
  add_receipt "$id" AC1 test "12 passed" "" failure
  add_receipt "$id" AC2 test "0 tests passed" "" zero
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id"); rc=$?
  expect_code 1 "$rc" "failed outcome leaves its criterion missing"
  printf '%s' "$out" | jq -e '
    .status == "missing"
    and .required == ["AC1","AC2"]
    and .evidenced == []
    and .missing == ["AC1","AC2"]
    and .receipt_count == 2
  ' >/dev/null || fail "closed outcome evidence status was not deterministic"
  add_receipt "$id" AC1 test failed "" success
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id"); rc=$?
  expect_code 1 "$rc" "success outcome evidences regardless of descriptive result"
  printf '%s' "$out" | jq -e '.evidenced == ["AC1"] and .missing == ["AC2"]' >/dev/null \
    || fail "success outcome did not recover the criterion"
  add_receipt "$id" AC2 api 401 "" success
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id"); rc=$?
  expect_code 0 "$rc" "expected observations can carry explicit success"
  printf '%s' "$out" | jq -e '.evidenced == ["AC1","AC2"] and .missing == []' >/dev/null \
    || fail "expected 401 success did not recover the criterion"
  pass "structured success and negative outcomes control criterion evidence"
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
  pass "pinned metadata owner rejects hard-linked validation records"
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
  printf '%s\n' '{"criterion":"AC1","type":"test","outcome":"passed","summary":"external","result":"passed"}' > "$outside/evidence.jsonl"
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
  printf '%s' "$out" | jq -e '.status == "not-applicable" and .kind == "non-ship"' >/dev/null \
    || fail "scout behavior did not remain separate"
  [ ! -e "$HOME_DIR/data/$scout/evidence.jsonl" ] || fail "checker created a scout ledger"
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
    '{"criterion":"AC1","type":"test","outcome":"passed","summary":"external","result":"passed"}' \
    '{"criterion":"AC2","type":"lint","outcome":"passed","summary":"external","result":"passed"}' > "$outside/evidence.jsonl"
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

test_shared_criterion_parser_drives_append_and_check() {
  local id=shared-criteria out rc
  id=shared-criteria
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
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id"); rc=$?
  expect_code 0 "$rc" "checker accepts the same detailed criterion as append"
  printf '%s' "$out" | jq -e '.required == ["AC10"] and .evidenced == ["AC10"]' >/dev/null \
    || fail "shared criterion parser produced inconsistent append/check behavior"
  printf '# Acceptance criteria\n- AC1:    \n# End acceptance criteria\n' \
    | "$CHECK" --parse-criteria - >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "shared criterion parser rejects an all-whitespace description"
  printf '# Acceptance criteria\n- AC1: Implement {TODO} before completion.\n# End acceptance criteria\n' \
    | "$CHECK" --parse-criteria - >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "shared criterion parser rejects embedded placeholders"
  printf '# Acceptance criteria\n- AC1: Implement {TODO before completion.\n# End acceptance criteria\n' \
    | "$CHECK" --parse-criteria - >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "shared criterion parser rejects unmatched opening braces"
  printf '# Acceptance criteria\n- AC1: Implement TODO} before completion.\n# End acceptance criteria\n' \
    | "$CHECK" --parse-criteria - >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "shared criterion parser rejects unmatched closing braces"
  printf '# Acceptance criteria\n- AC1: API returns {"ok":true}.\n# End acceptance criteria\n' \
    | "$CHECK" --parse-criteria - >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "shared criterion parser accepts concrete brace syntax"
  pass "receipt append and check consume one criterion grammar"
}

test_ci_green_log_allows_exact_bound_run_completion() {
  local id=ci-log-ready base project head generation running ci_status rc
  id=ci-log-ready
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint passed
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null \
    || fail "CI-log readiness fixture plan failed"
  project="$TMP_ROOT/project-$id"
  head=$(git -C "$project" rev-parse HEAD)
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  running=$(nm_status RUN-ci-log "$head" pending)
  FM_FAKE_NM_STATUS="$running" FM_FAKE_NM_INTENT="Firstmate-Validation-Generation: $generation" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-ci-log --generation "$generation" >/dev/null \
    || fail "CI-log readiness fixture run binding failed"
  ci_status=$(printf 'run:\n  id: "RUN-ci-log"\n  status: ci\n  head: "%s"\noutcome: pending\n' "$head")
  FM_FAKE_NM_STATUS="$ci_status" FM_FAKE_NM_CI_LOG='CI checks running' \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --complete --terminal-evidence no-mistakes-passed >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "current CI log keeps pending checks incomplete"
  FM_FAKE_NM_STATUS="$ci_status" FM_FAKE_NM_CI_LOG='all CI checks passed - still monitoring until merged or closed' \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --complete --terminal-evidence no-mistakes-passed >/dev/null \
    || fail "current checks-green CI log did not complete the exact bound run"
  pass "exact bound runs complete from the shared current CI-log readiness predicate"
}

test_claim_invalidation_marker_is_append_only_and_idempotent() {
  local id=claim-invalidation out rc meta base generation first_generation project invalidated_head invalidated_boundary
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test passed
  add_receipt "$id" AC2 lint passed
  meta="$HOME_DIR/state/$id.meta"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --invalidate-claim F9 --invalidated-criterion AC1 >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "claim invalidation requires a current plan generation"
  FM_FAKE_NM_STATUS='' FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null \
    || fail "claim invalidation fixture plan failed"
  first_generation=$(grep '^validation_generation=' "$meta" | tail -1 | cut -d= -f2-)
  project="$TMP_ROOT/project-$id"
  printf '#!/usr/bin/env bash\nprintf "pre-finding\\n"\n' > "$project/src/app.sh"
  git -C "$project" add src/app.sh
  git -C "$project" commit -q -m 'change before finding'
  add_receipt "$id" AC1 test "pre-finding evidence"
  invalidated_head=$(git -C "$project" rev-parse HEAD)
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --invalidate-claim F9 --invalidated-criterion AC1) \
    || fail "claim invalidation marker failed"
  invalidated_boundary=$(printf '%s' "$out" | jq -r '.receipt_boundary')
  printf '%s' "$out" | jq -e --arg generation "$first_generation" --arg head "$invalidated_head" \
    '.status == "recorded" and .generation == $generation and .finding == "F9" and .criterion == "AC1"
      and .invalidated_head == $head and .receipt_boundary == 3' >/dev/null \
    || fail "claim invalidation result was not machine-readable"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --invalidate-claim F9 --invalidated-criterion AC1 >/dev/null \
    || fail "duplicate claim invalidation was not idempotent"
  [ "$(grep -c "^validation_claim_invalidation=$first_generation:F9:AC1:$invalidated_head:$invalidated_boundary\$" "$meta")" -eq 1 ] \
    || fail "claim invalidation marker was not append-only and idempotent"
  out=$(FM_FAKE_NM_STATUS='' FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" 2>&1)
  rc=$?
  expect_code 2 "$rc" "claim invalidation refuses a same-head replan"
  assert_contains "$out" "strict non-empty follow-up delta" \
    "same-head invalidation refusal omitted the delta boundary"
  printf '#!/usr/bin/env bash\nprintf "fixed\\n"\n' > "$project/src/app.sh"
  git -C "$project" add src/app.sh
  git -C "$project" commit -q -m 'resolve invalidated claim'
  out=$(FM_FAKE_NM_STATUS='' FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" 2>&1)
  rc=$?
  expect_code 2 "$rc" "claim invalidation requires post-boundary evidence"
  assert_contains "$out" "requires fresh successful evidence" \
    "missing invalidation receipt did not identify its generation boundary"
  add_receipt "$id" AC1 test "fixed behavior"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --implementation-complete >/dev/null \
    || fail "claim invalidation fix did not refresh implementation completion"
  FM_FAKE_NM_STATUS='' FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null \
    || fail "claim invalidation fixture replan failed after a fix and fresh evidence"
  generation=$(grep '^validation_generation=' "$meta" | tail -1 | cut -d= -f2-)
  [ "$generation" != "$first_generation" ] || fail "claim invalidation replan reused its generation"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --invalidate-claim F9 --invalidated-criterion AC1 >/dev/null \
    || fail "later-generation claim invalidation failed"
  [ "$(grep -c '^validation_claim_invalidation=.*:F9:AC1:.*:[0-9][0-9]*$' "$meta")" -eq 2 ] \
    || fail "later generation collapsed a distinct claim invalidation"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --invalidate-claim F10 --invalidated-criterion AC3 >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "claim invalidation rejects an undeclared criterion"
  pass "finding-to-criterion invalidations remain inspectable in task metadata"
}

test_low_risk_skips_no_mistakes_under_explicit_policy() {
  local id=low-docs base out meta project validated_head new_head generation rc
  base=$(make_project "$id" no-mistakes docs)
  add_receipt "$id" AC1 lint "passed" CHANGELOG.md
  add_receipt "$id" AC2 review "reviewed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "low-risk plan failed"
  printf '%s' "$out" | jq -e --arg id "$id" '
    .tier == "low" and .path == "receipts-mechanical"
    and .receipt_command == ("bin/fm-receipt.sh " + $id + " <criterion> <test|build|lint|typecheck> <summary> <result> --outcome success --file <changed-file>")
    and .mechanical_command == ("bin/fm-receipt-check.sh " + $id + " --mechanical-ready")
    and .push_command == ("git push -u origin fm/" + $id)
    and .pr_command == "gh-axi pr create <options>"
    and .done_status == "done: PR <url>"
    and .register_command == ("bin/fm-pr-check.sh " + $id + " <url>")
  ' >/dev/null \
    || fail "narrow mechanically proven docs change did not take the low path"
  meta="$HOME_DIR/state/$id.meta"
  grep -qx 'validation_tier=low' "$meta" || fail "low tier was not recorded durably"
  grep -qx 'validation_path=receipts-mechanical' "$meta" || fail "low path was not recorded durably"
  grep -Eq '^validation_started_at=[0-9]+$' "$meta" || fail "low plan omitted validation start time"
  project="$TMP_ROOT/project-$id"
  validated_head=$(git -C "$project" rev-parse HEAD)
  ! grep -q '^validation_completed_at=' "$meta" || fail "low plan completed before post-plan mechanical evidence"
  add_receipt "$id" AC1 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --mechanical-ready >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "low readiness rejects mechanical evidence unrelated to the changed file"
  add_receipt "$id" AC1 lint "passed" CHANGELOG.md
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --mechanical-ready >/dev/null \
    || fail "low plan was not mechanically ready after post-plan evidence"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence mechanical-checks-passed >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "mechanical readiness alone cannot complete PR delivery"
  generation=$(grep '^validation_generation=' "$meta" | tail -1 | cut -d= -f2-)
  printf 'pr=https://github.com/example/repo/pull/1\npr_head=%s\nvalidation_pr_published_generation=%s\n' \
    "$validated_head" "$generation" >> "$meta"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence pr-opened >/dev/null \
    || fail "low plan did not complete after PR evidence"
  grep -qx "validation_completed_head=$validated_head" "$meta" \
    || fail "low completion was not bound to its validated head"
  printf 'Release   note\n' > "$project/CHANGELOG.md"
  git -C "$project" add CHANGELOG.md
  git -C "$project" commit -q -m 'post-validation correction'
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence pr-opened 2>&1)
  rc=$?
  expect_code 2 "$rc" "completion refuses code changed after validation"
  assert_contains "$out" "replan and revalidate" "stale completion refusal omitted recovery guidance"
  [ "$(grep '^validation_completed_head=' "$meta" | tail -1)" = 'validation_completed_head=' ] \
    || fail "stale completion remained active after the head changed"
  new_head=$(git -C "$project" rev-parse HEAD)
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --implementation-complete >/dev/null \
    || fail "corrected low-risk change did not record implementation completion"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null \
    || fail "corrected low-risk change could not be replanned"
  add_receipt "$id" AC1 lint "passed" CHANGELOG.md
  generation=$(grep '^validation_generation=' "$meta" | tail -1 | cut -d= -f2-)
  printf 'pr_head=%s\nvalidation_pr_published_generation=%s\n' "$new_head" "$generation" >> "$meta"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence pr-opened >/dev/null \
    || fail "replanned low-risk change did not complete"
  [ "$(grep '^validation_completed_head=' "$meta" | tail -1)" = "validation_completed_head=$new_head" ] \
    || fail "replanned completion did not bind the corrected head"
  pass "low-risk mechanical changes can skip a full No-Mistakes run"
}

test_low_risk_requires_safe_prose_and_applicable_evidence() {
  local id base out project
  id=low-unbound-proof
  base=$(make_project "$id" no-mistakes docs)
  add_receipt "$id" AC1 lint passed
  add_receipt "$id" AC2 review reviewed
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "unbound-proof plan failed"
  printf '%s' "$out" | jq -e '.tier == "high" and .path == "full-no-mistakes"' >/dev/null \
    || fail "unrelated mechanical evidence downgraded a changelog change"

  id=low-command-prose
  base=$(make_project "$id" no-mistakes docs)
  project="$TMP_ROOT/project-$id"
  printf "Run \`kubectl apply -f production.yaml\` during deployment.\n" >> "$project/CHANGELOG.md"
  git -C "$project" add CHANGELOG.md
  git -C "$project" commit -q -m 'add deployment command'
  add_receipt "$id" AC1 lint passed CHANGELOG.md
  add_receipt "$id" AC2 review reviewed
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "command-like prose plan failed"
  printf '%s' "$out" | jq -e '.tier == "high" and .path == "full-no-mistakes"' >/dev/null \
    || fail "command-like changelog prose reached low"

  id=low-prescriptive-prose
  base=$(make_project "$id" no-mistakes docs)
  project="$TMP_ROOT/project-$id"
  printf 'Administrators must rotate access tokens every 30 days.\n' >> "$project/CHANGELOG.md"
  git -C "$project" add CHANGELOG.md
  git -C "$project" commit -q -m 'add prescriptive security text'
  add_receipt "$id" AC1 lint passed CHANGELOG.md
  add_receipt "$id" AC2 review reviewed
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "prescriptive prose plan failed"
  printf '%s' "$out" | jq -e '.tier == "high" and .path == "full-no-mistakes"' >/dev/null \
    || fail "prescriptive changelog prose reached low"

  id=low-policy-value
  base=$(make_project "$id" no-mistakes policy_docs)
  add_receipt "$id" AC1 lint passed CHANGELOG.md
  add_receipt "$id" AC2 review reviewed
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "policy-value plan failed"
  printf '%s' "$out" | jq -e '.tier == "high" and .path == "full-no-mistakes"' >/dev/null \
    || fail "policy value change reached low"

  id=low-typo-content
  base=$(make_project "$id" no-mistakes docs)
  project="$TMP_ROOT/project-$id"
  printf 'Release notee\n' > "$project/CHANGELOG.md"
  git -C "$project" add CHANGELOG.md
  git -C "$project" commit -q -m 'change prose bytes'
  add_receipt "$id" AC1 lint passed CHANGELOG.md
  add_receipt "$id" AC2 review reviewed
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "content-byte plan failed"
  printf '%s' "$out" | jq -e '.tier == "high" and .path == "full-no-mistakes"' >/dev/null \
    || fail "content-byte typo reached low"
  pass "low risk requires safe changelog prose and file-bound mechanical evidence"
}

test_implementation_completion_precedes_planning() {
  local id=implementation-boundary base fakebin out rc meta head new_head project
  base=$(make_project "$id" no-mistakes localized)
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test primary passed --outcome success >/dev/null \
    || fail "implementation boundary AC1 receipt failed"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC2 lint secondary passed --outcome success >/dev/null \
    || fail "implementation boundary AC2 receipt failed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "planning requires an explicit implementation boundary"
  fakebin="$TMP_ROOT/implementation-date-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/date" <<'EOF'
#!/bin/sh
printf '%s\n' "$FM_FAKE_DATE"
EOF
  chmod +x "$fakebin/date"
  head=$(git -C "$TMP_ROOT/project-$id" rev-parse HEAD)
  out=$(PATH="$fakebin:$PATH" FM_FAKE_DATE=100 FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --implementation-complete) \
    || fail "implementation boundary action failed"
  printf '%s' "$out" | jq -e --arg head "$head" \
    '.status == "completed" and .completed_at == 100 and .completed_head == $head' >/dev/null \
    || fail "implementation boundary output was not machine-readable"
  PATH="$fakebin:$PATH" FM_FAKE_DATE=200 FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --implementation-complete >/dev/null \
    || fail "duplicate implementation boundary failed"
  meta="$HOME_DIR/state/$id.meta"
  [ "$(grep -c '^implementation_completed_at=' "$meta")" -eq 1 ] \
    || fail "same-head implementation completion was not idempotent"
  project="$TMP_ROOT/project-$id"
  printf 'head change\n' >> "$project/src/app.sh"
  git -C "$project" add src/app.sh
  git -C "$project" commit -q -m 'advance implementation head'
  new_head=$(git -C "$project" rev-parse HEAD)
  out=$(PATH="$fakebin:$PATH" FM_FAKE_DATE=250 FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --implementation-complete) \
    || fail "changed-head implementation boundary failed"
  printf '%s' "$out" | jq -e --arg head "$new_head" \
    '.completed_at == 250 and .completed_head == $head' >/dev/null \
    || fail "changed-head implementation completion did not refresh its binding"
  PATH="$fakebin:$PATH" FM_FAKE_DATE=275 FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --implementation-complete >/dev/null \
    || fail "same changed-head implementation boundary failed"
  [ "$(grep -c '^implementation_completed_at=' "$meta")" -eq 2 ] \
    || fail "changed-head timestamp was not refreshed exactly once"
  PATH="$fakebin:$PATH" FM_FAKE_DATE=300 FM_FAKE_NM_STATUS='' FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --plan --base "$base" >/dev/null \
    || fail "plan after implementation boundary failed"
  [ "$(grep '^validation_started_at=' "$meta" | tail -1)" = 'validation_started_at=250' ] \
    || fail "validation interval did not originate at current-head implementation completion"
  pass "implementation completion refreshes per head and remains idempotent"
}

test_plan_boundary_excludes_concurrent_receipts() {
  local id=plan-receipt-boundary base fakebin real_od ready release plan_pid receipt_pid rc meta
  base=$(make_project "$id" no-mistakes docs)
  add_receipt "$id" AC1 lint passed CHANGELOG.md
  add_receipt "$id" AC2 review reviewed
  fakebin="$TMP_ROOT/plan-boundary-fakebin"
  ready="$TMP_ROOT/plan-boundary-ready"
  release="$TMP_ROOT/plan-boundary-release"
  mkdir -p "$fakebin"
  mkfifo "$release"
  real_od=$(command -v od)
  cat > "$fakebin/od" <<EOF
#!/bin/sh
: > "$ready"
IFS= read -r _ < "$release"
exec "$real_od" "\$@"
EOF
  chmod +x "$fakebin/od"
  PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" \
    > "$TMP_ROOT/plan-boundary-output" 2>&1 &
  plan_pid=$!
  while [ ! -e "$ready" ]; do
    kill -0 "$plan_pid" 2>/dev/null || fail "planner exited before the publication boundary"
  done
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 lint fresh passed --outcome success --file CHANGELOG.md \
    > "$TMP_ROOT/plan-boundary-receipt" 2>&1 &
  receipt_pid=$!
  sleep 1
  kill -0 "$receipt_pid" 2>/dev/null \
    || fail "receipt append crossed the unpublished plan boundary"
  printf 'continue\n' > "$release"
  wait "$plan_pid"
  rc=$?
  expect_code 0 "$rc" "planner publishes while holding the pinned ledger boundary"
  wait "$receipt_pid"
  rc=$?
  expect_code 0 "$rc" "receipt appends after the published plan boundary"
  meta="$HOME_DIR/state/$id.meta"
  [ "$(grep '^validation_ledger_receipt_count=' "$meta" | tail -1)" = 'validation_ledger_receipt_count=2' ] \
    || fail "plan boundary included a receipt appended after publication"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --mechanical-ready >/dev/null \
    || fail "post-publication receipt did not satisfy fresh mechanical evidence"
  pass "plan publication holds the pinned ledger boundary against concurrent receipts"
}

test_diff_summary_errors_fail_planning() {
  local id=summary-error base fakebin real_git rc
  base=$(make_project "$id" no-mistakes docs)
  add_receipt "$id" AC1 lint passed CHANGELOG.md
  add_receipt "$id" AC2 review reviewed
  fakebin="$TMP_ROOT/summary-error-bin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<EOF
#!/bin/sh
case "\$*" in
  *"diff --no-ext-diff --no-renames --summary"*) exit 7 ;;
esac
exec "$real_git" "\$@"
EOF
  chmod +x "$fakebin/git"
  PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "diff summary errors cannot publish a plan"
  pass "diff summary errors fail closed before risk classification"
}

test_terminal_and_failed_runs_bind_by_current_plan() {
  local id base project head generation terminal failed rc
  id='terminal-bind'
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint passed
  FM_FAKE_NM_STATUS='' FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "terminal-bind plan failed"
  project="$TMP_ROOT/project-$id"
  head=$(git -C "$project" rev-parse HEAD)
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  terminal=$(printf 'run:\n  id: "RUN-terminal"\n  status: completed\n  head: "%s"\noutcome: checks-passed\n' "$head")
  FM_FAKE_NM_STATUS="$terminal" FM_FAKE_NM_INTENT="Firstmate-Validation-Generation: $generation" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-terminal --generation "$generation" >/dev/null \
    || fail "successful terminal run could not bind to its current plan"

  id='failed-bind'
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint passed
  FM_FAKE_NM_STATUS='' FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "failed-bind plan failed"
  project="$TMP_ROOT/project-$id"
  head=$(git -C "$project" rev-parse HEAD)
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  failed=$(printf 'run:\n  id: "RUN-failed"\n  status: failed\n  head: "%s"\noutcome: failed\n' "$head")
  FM_FAKE_NM_STATUS="$failed" FM_FAKE_NM_INTENT="Firstmate-Validation-Generation: $generation" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-failed --generation "$generation" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "failed terminal run cannot bind"
  pass "successful terminal runs bind while failed runs remain rejected"
}

test_run_heads_resolve_authoritatively() {
  local id=receipt-binding-identity base project head short generation status rc
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint passed
  FM_FAKE_NM_STATUS='' FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "identity fixture plan failed"
  project="$TMP_ROOT/project-$id"
  head=$(git -C "$project" rev-parse HEAD)
  short=${head:0:8}
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  status=$(nm_status RUN-identity "$short" pending)
  FM_FAKE_NM_STATUS="$status" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-identity --generation "$generation" >/dev/null \
    || fail "abbreviated run head was rejected instead of resolved authoritatively"
  printf 'descendant\n' >> "$project/src/app.sh"
  git -C "$project" add src/app.sh
  git -C "$project" commit -q -m 'descendant run head'
  status=$(nm_status RUN-descendant "$(git -C "$project" rev-parse HEAD)" pending)
  FM_FAKE_NM_STATUS="$status" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-descendant --generation "$generation" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "bind accepted a strict descendant instead of the planned commit"
  pass "run binding resolves abbreviated heads and rejects non-planned commits"
}

test_completion_accepts_only_pipeline_owned_head_advance() {
  local id=receipt-pipeline-advance base project initial_head current_head short generation status out rc
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint passed
  FM_FAKE_NM_STATUS='' FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "pipeline advance plan failed"
  project="$TMP_ROOT/project-$id"
  initial_head=$(git -C "$project" rev-parse HEAD)
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  status=$(nm_status RUN-advance "$initial_head" pending)
  FM_FAKE_NM_STATUS="$status" FM_FAKE_NM_INTENT="Firstmate-Validation-Generation: $generation" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-advance --generation "$generation" >/dev/null \
    || fail "pipeline advance run binding failed"
  printf 'pipeline fix\n' >> "$project/src/app.sh"
  git -C "$project" add src/app.sh
  git -C "$project" commit -q -m 'no-mistakes: apply CI fixes'
  current_head=$(git -C "$project" rev-parse HEAD)
  short=${current_head:0:8}
  status=$(nm_pipeline_status RUN-advance "fm/$id" "$short" ci '' pipeline_owned)
  out=$(FM_FAKE_NM_STATUS="$status" FM_FAKE_NM_CI_LOG='all CI checks passed - still monitoring' \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --complete --terminal-evidence no-mistakes-passed) \
    || fail "pipeline-owned post-plan head was not accepted"
  printf '%s' "$out" | jq -e --arg head "$current_head" '.status == "completed" and .completed_head == $head' >/dev/null \
    || fail "pipeline-owned completion did not bind current head"

  id=receipt-unproven-advance
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint passed
  FM_FAKE_NM_STATUS='' FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "unproven advance plan failed"
  project="$TMP_ROOT/project-$id"
  initial_head=$(git -C "$project" rev-parse HEAD)
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  status=$(nm_status RUN-unproven "$initial_head" pending)
  FM_FAKE_NM_STATUS="$status" FM_FAKE_NM_INTENT="Firstmate-Validation-Generation: $generation" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-unproven --generation "$generation" >/dev/null \
    || fail "unproven fixture run binding failed"
  printf 'unrelated\n' >> "$project/src/app.sh"
  git -C "$project" add src/app.sh
  git -C "$project" commit -q -m unrelated
  current_head=$(git -C "$project" rev-parse HEAD)
  status=$(nm_pipeline_status RUN-unproven "fm/$id" "$current_head" ci '' manual)
  FM_FAKE_NM_STATUS="$status" FM_FAKE_NM_CI_LOG='all CI checks passed - still monitoring' \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --complete --terminal-evidence no-mistakes-passed >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "unproven head advance was accepted"
  pass "completion accepts only active pipeline-owned descendant heads"
}

test_no_mistakes_observations_are_bounded() {
  local hang_nm id base project head generation running ci_status rc
  hang_nm="$TMP_ROOT/hang-no-mistakes"
  cat > "$hang_nm" <<'EOF'
#!/bin/sh
case "$*" in
  *"$FM_HANG_ON"*) sleep 5 ;;
esac
case "$*" in
  *"axi logs --step intent --run "*) printf '%s\n' "${FM_FAKE_NM_INTENT:-}" ;;
  *"axi logs --step ci --run "*) printf '%s\n' "${FM_FAKE_NM_CI_LOG:-}" ;;
  *) printf '%s\n' "${FM_FAKE_NM_STATUS:-}" ;;
esac
EOF
  chmod +x "$hang_nm"

  id=bounded-observation
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint passed
  FM_HANG_ON='axi status' FM_RECEIPT_NM_TIMEOUT=1 FM_NO_MISTAKES_BIN="$hang_nm" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --plan --base "$base" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "planning bounds No-Mistakes status observation"

  FM_FAKE_NM_STATUS='' FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "bounded observation fixture plan failed"
  project="$TMP_ROOT/project-$id"
  head=$(git -C "$project" rev-parse HEAD)
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  running=$(nm_status RUN-bounded "$head" pending)
  FM_FAKE_NM_STATUS="$running" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-bounded --generation "$generation" >/dev/null \
    || fail "bounded observation fixture binding failed"
  ci_status=$(printf 'run:\n  id: "RUN-bounded"\n  status: ci\n  head: "%s"\noutcome: pending\n' "$head")
  FM_HANG_ON='axi logs --step ci' FM_RECEIPT_NM_TIMEOUT=1 FM_FAKE_NM_STATUS="$ci_status" \
    FM_NO_MISTAKES_BIN="$hang_nm" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --complete --terminal-evidence no-mistakes-passed >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "completion bounds No-Mistakes CI-log observation"
  pass "No-Mistakes status and CI-log observations are bounded"
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
  local mode id base out meta expected_head evidence observed rc running_status passed_status generation
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
      local-only) evidence='branch-ready'; observed='clean-ready-branch' ;;
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
        generation=$(grep '^validation_generation=' "$meta" | tail -1 | cut -d= -f2-)
        FM_FAKE_NM_STATUS="$running_status" FM_FAKE_NM_INTENT="Firstmate-Validation-Generation: $generation" \
          FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
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
        generation=$(grep '^validation_generation=' "$meta" | tail -1 | cut -d= -f2-)
        printf 'pr=https://gitlab.example/o/r/-/merge_requests/1\nvalidation_pr_published_generation=%s\n' \
          "$generation" >> "$meta"
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
  local id=completion-signal base fakebin rc expected_head running_status passed_status generation
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "signal fixture plan failed"
  expected_head=$(git -C "$TMP_ROOT/project-$id" rev-parse HEAD)
  running_status=$(nm_status RUN-signal "$expected_head" pending)
  passed_status=$(nm_status RUN-signal "$expected_head" passed)
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  FM_FAKE_NM_STATUS="$running_status" FM_FAKE_NM_INTENT="Firstmate-Validation-Generation: $generation" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
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
  local id=replan-binding base project head running passed rc generation
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "initial binding plan failed"
  project="$TMP_ROOT/project-$id"
  head=$(git -C "$project" rev-parse HEAD)
  running=$(nm_status RUN-old "$head" pending)
  passed=$(nm_status RUN-old "$head" passed)
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  FM_FAKE_NM_STATUS="$running" FM_FAKE_NM_INTENT="Firstmate-Validation-Generation: $generation" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
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

test_git_status_errors_fail_every_cleanliness_gate() {
  local id=status-error base project fakebin real_git rc
  id='status-error'
  base=$(make_project "$id" direct-PR localized)
  project="$TMP_ROOT/project-$id"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC1 test primary passed --outcome success >/dev/null || fail "status-error AC1 receipt failed"
  FM_HOME="$HOME_DIR" "$RECEIPT" "$id" AC2 lint secondary passed --outcome success >/dev/null || fail "status-error AC2 receipt failed"
  fakebin="$TMP_ROOT/status-error-bin"
  mkdir -p "$fakebin"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<EOF
#!/bin/sh
case "\$*" in
  *"status --porcelain"*) exit 7 ;;
esac
exec "$real_git" "\$@"
EOF
  chmod +x "$fakebin/git"
  PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$CHECK" "$id" --implementation-complete >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "implementation completion rejects status errors"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --implementation-complete >/dev/null || fail "status-error implementation marker failed"
  PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "planning rejects status errors"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null || fail "status-error plan failed"
  printf 'pr=https://gitlab.example/o/r/-/merge_requests/2\n' >> "$HOME_DIR/state/$id.meta"
  PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" "$CHECK" "$id" --complete --terminal-evidence pr-opened >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "completion rejects status errors"
  [ -d "$project/.git" ] || fail "status-error fixture lost its repository"
  pass "git status errors fail implementation, planning, and completion cleanliness gates"
}

test_submodule_ignore_cannot_hide_dirty_work() {
  local id=dirty-submodule project subrepo rc
  make_project "$id" no-mistakes localized >/dev/null
  project="$TMP_ROOT/project-$id"
  subrepo="$TMP_ROOT/subrepo-$id"
  git init -q "$subrepo"
  git -C "$subrepo" config user.email test@example.com
  git -C "$subrepo" config user.name Test
  printf 'tracked\n' > "$subrepo/tracked.txt"
  git -C "$subrepo" add tracked.txt
  git -C "$subrepo" commit -q -m initial
  git -C "$project" -c protocol.file.allow=always submodule add -q "$subrepo" vendor/sub
  git -C "$project" config -f .gitmodules submodule.vendor/sub.ignore all
  git -C "$project" add .gitmodules vendor/sub
  git -C "$project" commit -q -m 'add ignored submodule'
  add_receipt "$id" AC1 test passed
  add_receipt "$id" AC2 lint passed
  printf 'dirty\n' >> "$project/vendor/sub/tracked.txt"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --implementation-complete >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "configured submodule ignore cannot hide dirty work"
  pass "shared cleanliness inspects ignored submodules"
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

test_shared_local_default_resolver() {
  local id=local-default-resolver base project out rc
  base=$(make_project "$id" local-only localized)
  project="$TMP_ROOT/project-$id"
  out=$("$ROOT/bin/fm-local-default.sh" "$project") \
    || fail "shared local default resolver rejected main fallback"
  [ "$out" = main ] || fail "shared local default resolver returned '$out', expected main"
  git -C "$project" branch develop "$base"
  git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
  out=$("$ROOT/bin/fm-local-default.sh" "$project") \
    || fail "shared local default resolver rejected a local origin/HEAD branch"
  [ "$out" = develop ] || fail "shared local default resolver returned '$out', expected develop"
  git -C "$project" branch -D develop >/dev/null
  "$ROOT/bin/fm-local-default.sh" "$project" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "shared local default resolver fell back around a missing origin/HEAD branch"
  pass "local readiness and landing share one fail-closed default resolver"
}



test_high_risk_and_uncertain_inputs_fail_safe() {
  local id=high-auth base out rc project hidden_base current_head running_status generation other_status
  base=$(make_project "$id" no-mistakes auth)
  add_receipt "$id" AC1 test "3 passed"
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
    || fail "high-risk plan should still be a successful plan"
  printf '%s' "$out" | jq -e '.tier == "high" and .path == "full-no-mistakes"' >/dev/null \
    || fail "auth surface did not retain full No-Mistakes"

  id=weak-test-proof
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "not passed" "" failure
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base"); rc=$?
  expect_code 1 "$rc" "failed test outcome blocks validation planning"
  printf '%s' "$out" | jq -e '.status == "missing" and .missing == ["AC1"]' >/dev/null \
    || fail "failed test outcome did not leave its criterion missing"

  id=zero-test-proof
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "0 tests passed" "" zero
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base"); rc=$?
  expect_code 1 "$rc" "failed zero-test outcome blocks validation planning"
  printf '%s' "$out" | jq -e '.status == "missing" and .missing == ["AC1"]' >/dev/null \
    || fail "failed zero-test outcome did not leave its criterion missing"

  id=skipped-test-proof
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed, 1 skipped" "" skipped
  add_receipt "$id" AC2 lint "passed"
  out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base"); rc=$?
  expect_code 1 "$rc" "failed skipped-test outcome blocks validation planning"
  printf '%s' "$out" | jq -e '.status == "missing" and .missing == ["AC1"]' >/dev/null \
    || fail "failed skipped-test outcome did not leave its criterion missing"

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

  id=hidden-sensitive-base
  base=$(make_project "$id" no-mistakes auth)
  project="$TMP_ROOT/project-$id"
  hidden_base=$(git -C "$project" rev-parse HEAD)
  printf 'documentation tail\n' >> "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" commit -q -m 'documentation tail'
  add_receipt "$id" AC1 lint "passed"
  add_receipt "$id" AC2 review "reviewed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$hidden_base" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "caller-selected ancestor cannot publish a plan"

  id=uncertain-base
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "passed"
  add_receipt "$id" AC2 lint "passed"
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base does-not-exist >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "unresolved base cannot publish a plan"

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
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  other_status=$(nm_status OTHER-RUN "$current_head" pending)
  FM_FAKE_NM_STATUS="$other_status" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run OTHER-RUN --generation "stale-generation" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a generation that does not match the current plan cannot bind"
  FM_FAKE_NM_STATUS="$other_status" \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run OTHER-RUN --generation "$generation" >/dev/null \
    || fail "run carrying the authoritative plan generation could not bind"

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
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "dangling origin HEAD cannot publish a plan"
  pass "security and uncertain changes retain full No-Mistakes validation"
}

test_agent_supplied_intent_log_binds_and_completes() {
  local id base project head generation running ci_status rc
  # Real no-mistakes never echoes the agent-supplied --intent body back through
  # `axi logs --step intent`; it reports only this generic line. Binding and
  # completion must therefore work from the authoritative run id and head plus the
  # plan-metadata generation, never from an inline generation record in the log.
  id=agent-supplied-intent
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint passed
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null \
    || fail "agent-supplied-intent fixture plan failed"
  project="$TMP_ROOT/project-$id"
  head=$(git -C "$project" rev-parse HEAD)
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  running=$(nm_status RUN-agent-intent "$head" pending)
  FM_FAKE_NM_STATUS="$running" FM_FAKE_NM_INTENT='using intent supplied by the agent' \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-agent-intent --generation "$generation" >/dev/null \
    || fail "binding failed against the real agent-supplied intent-log shape"
  ci_status=$(printf 'run:\n  id: "RUN-agent-intent"\n  status: ci\n  head: "%s"\noutcome: pending\n' "$head")
  FM_FAKE_NM_STATUS="$ci_status" FM_FAKE_NM_CI_LOG='all CI checks passed - still monitoring until merged or closed' \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --complete --terminal-evidence no-mistakes-passed >/dev/null \
    || fail "CI-green bound run could not complete against the agent-supplied intent-log shape"

  # A genuinely wrong generation still fails closed without the intent log.
  id=agent-supplied-intent-wrong-generation
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint passed
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null \
    || fail "wrong-generation fixture plan failed"
  project="$TMP_ROOT/project-$id"
  head=$(git -C "$project" rev-parse HEAD)
  running=$(nm_status RUN-wrong-gen "$head" pending)
  FM_FAKE_NM_STATUS="$running" FM_FAKE_NM_INTENT='using intent supplied by the agent' \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-wrong-gen --generation "not-the-plan-generation" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a mismatched generation still fails closed without the intent log"

  # A genuinely wrong head still fails closed: the run's observed head must resolve
  # to the exact validated head.
  id=agent-supplied-intent-wrong-head
  base=$(make_project "$id" no-mistakes localized)
  add_receipt "$id" AC1 test "2 passed"
  add_receipt "$id" AC2 lint passed
  FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base" >/dev/null \
    || fail "wrong-head fixture plan failed"
  generation=$(grep '^validation_generation=' "$HOME_DIR/state/$id.meta" | tail -1 | cut -d= -f2-)
  running=$(nm_status RUN-wrong-head "$base" pending)
  FM_FAKE_NM_STATUS="$running" FM_FAKE_NM_INTENT='using intent supplied by the agent' \
    FM_NO_MISTAKES_BIN="$FAKE_NO_MISTAKES" FM_HOME="$HOME_DIR" \
    "$CHECK" "$id" --bind-run RUN-wrong-head --generation "$generation" >/dev/null 2>&1
  rc=$?
  expect_code 2 "$rc" "a run at the wrong head still fails closed without the intent log"
  pass "binding and completion work against the real agent-supplied intent-log shape while wrong runs fail closed"
}

test_direct_and_local_modes_never_invoke_no_mistakes() {
  local mode id base out expected rc
  for mode in direct-PR local-only; do
    id="mode-${mode}"
    base=$(make_project "$id" "$mode" localized)
    add_receipt "$id" AC1 test "passed"
    add_receipt "$id" AC2 lint "passed"
    FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base does-not-exist >/dev/null 2>&1
    rc=$?
    expect_code 2 "$rc" "$mode refuses an unresolved authoritative base"
    out=$(FM_HOME="$HOME_DIR" "$CHECK" "$id" --plan --base "$base") \
      || fail "$mode plan failed"
    expected=$mode
    printf '%s' "$out" | jq -e --arg expected "$expected" '.tier == "high" and .path == $expected' >/dev/null \
      || fail "$mode accidentally entered a No-Mistakes path"
  done
  pass "direct-PR and local-only retain evidence gates without invoking No-Mistakes"
}



test_help_advertises_generation_bound_run_binding
test_reports_missing_criteria_deterministically
test_complete_and_invalid_ledgers_have_distinct_results
test_closed_outcomes_control_evidence
test_delivery_mode_mismatch_fails_closed
test_metadata_hard_links_are_rejected_by_the_pinned_owner
test_invalid_brief_and_scout_behavior
test_early_snapshot_failure_does_not_block_cleanup
test_readiness_publication_failure_is_terminal
test_pinned_checker_rejects_redirected_and_linked_evidence
test_shared_criterion_parser_drives_append_and_check
test_ci_green_log_allows_exact_bound_run_completion
test_claim_invalidation_marker_is_append_only_and_idempotent
test_run_heads_resolve_authoritatively
test_agent_supplied_intent_log_binds_and_completes
test_completion_accepts_only_pipeline_owned_head_advance
test_low_risk_skips_no_mistakes_under_explicit_policy
test_low_risk_requires_safe_prose_and_applicable_evidence
test_implementation_completion_precedes_planning
test_plan_boundary_excludes_concurrent_receipts
test_diff_summary_errors_fail_planning
test_terminal_and_failed_runs_bind_by_current_plan
test_no_mistakes_observations_are_bounded
test_authoritative_docs_remain_high
test_terminal_paths_record_completion_at_their_boundary
test_completion_signal_releases_validation_lock
test_replan_invalidates_run_binding
test_dirty_worktrees_cannot_plan_or_complete
test_git_status_errors_fail_every_cleanliness_gate
test_submodule_ignore_cannot_hide_dirty_work
test_direct_and_local_plans_never_query_no_mistakes
test_local_completion_requires_fast_forward_readiness
test_shared_local_default_resolver
test_high_risk_and_uncertain_inputs_fail_safe
test_direct_and_local_modes_never_invoke_no_mistakes
