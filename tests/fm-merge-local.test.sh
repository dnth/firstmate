#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh's merge guard (bin/fm-merge-guard-lib.sh):
# a local-only ship task with any accepted-blocked acceptance criterion is
# refused without a captain instruction, lands with one whose verbatim words
# are recorded in the task's durable record, and a fully evidenced task still
# fast-forwards unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# A home with a local-only ship task whose fm/task-l1 branch is one commit
# ahead of the project's main, and a ledger whose latest AC1 receipt has the
# given outcome. Echoes the case dir. Args: name outcome
make_case() {
  local name=$1 outcome=$2 case_dir project
  case_dir="$TMP_ROOT/$name"
  project="$case_dir/project"
  mkdir -p "$case_dir/state" "$case_dir/data/task-l1"
  git init -q -b main "$project"
  git -C "$project" commit -q --allow-empty -m base
  git -C "$project" branch fm/task-l1
  git -C "$project" commit -q --allow-empty -m feature
  git -C "$project" branch -f fm/task-l1 HEAD
  git -C "$project" reset -q --hard HEAD~1
  fm_write_meta "$case_dir/state/task-l1.meta" \
    "project=$project" "kind=ship" "mode=local-only" "yolo=on"
  printf '# Task\nFixture.\n\n# Acceptance criteria\n- AC1: Fixture works.\n\n# Definition of done\nDelivery contract: mode=local-only\n' \
    > "$case_dir/data/task-l1/brief.md"
  if [ "$outcome" = accepted-blocked ]; then
    printf '%s\n' '{"criterion":"AC1","type":"manual","outcome":"accepted-blocked","summary":"needs hardware","result":"not run","captain_exception":"2026-10-06 captain: no hardware here"}' \
      > "$case_dir/data/task-l1/evidence.jsonl"
  else
    printf '%s\n' '{"criterion":"AC1","type":"test","outcome":"success","summary":"fixture","result":"passed"}' \
      > "$case_dir/data/task-l1/evidence.jsonl"
  fi
  : > "$case_dir/data/task-l1/.evidence.lock"
  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  shift
  env -u FM_TASK_ID FM_HOME="$case_dir" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" "$MERGE_LOCAL" "$@"
}

main_sha() {
  git -C "$1/project" rev-parse main
}

test_accepted_blocked_task_is_refused() {
  local case_dir rc before
  case_dir=$(make_case refused accepted-blocked)
  before=$(main_sha "$case_dir")

  run_merge_local "$case_dir" task-l1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  expect_code 1 "$rc" "refused: an accepted-blocked task landed on standing authority"
  assert_grep 'acceptance criteria accepted as blocked: AC1 (captain exception: 2026-10-06 captain: no hardware here)' \
    "$case_dir/stderr" "refused: refusal did not name the criterion and its exception"
  assert_grep '--captain-instruction' "$case_dir/stderr" "refused: refusal did not name the override flag"
  [ "$(main_sha "$case_dir")" = "$before" ] || fail "refused: main moved despite the refusal"
  assert_absent "$case_dir/data/task-l1/captain-merge-instructions.jsonl" \
    "refused: a refusal wrote an override record"
  pass "fm-merge-local refuses an accepted-blocked task without a captain instruction"
}

test_accepted_blocked_task_lands_under_captain_instruction() {
  local case_dir rc words
  words='Captain 2026-10-06: land task-l1 without the hardware check'
  case_dir=$(make_case override accepted-blocked)

  run_merge_local "$case_dir" task-l1 --captain-instruction "$words" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  expect_code 0 "$rc" "override: the captain's instruction did not authorize the landing"
  [ "$(main_sha "$case_dir")" = "$(git -C "$case_dir/project" rev-parse fm/task-l1)" ] \
    || fail "override: main was not fast-forwarded to the task branch"
  jq -e --arg words "$words" \
    'select(.schema == "fm-merge-override.v1" and .script == "fm-merge-local" and .target == "fm/task-l1"
      and .captain_instruction == $words and (.overridden[0] | test("AC1")))' \
    "$case_dir/data/task-l1/captain-merge-instructions.jsonl" >/dev/null \
    || fail "override: the verbatim instruction was not recorded in the task's durable record"
  pass "fm-merge-local lands an accepted-blocked task under a recorded captain instruction"
}

test_blank_captain_instruction_is_rejected() {
  local case_dir rc before
  case_dir=$(make_case blank accepted-blocked)
  before=$(main_sha "$case_dir")

  run_merge_local "$case_dir" task-l1 --captain-instruction '  ' > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  expect_code 2 "$rc" "blank: a blank captain instruction was accepted"
  [ "$(main_sha "$case_dir")" = "$before" ] || fail "blank: main moved on a blank instruction"
  pass "fm-merge-local rejects a blank captain instruction"
}

test_evidenced_task_lands_unchanged() {
  local case_dir rc
  case_dir=$(make_case evidenced success)

  run_merge_local "$case_dir" task-l1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?

  expect_code 0 "$rc" "evidenced: a fully evidenced task was refused"
  assert_grep 'merged fm/task-l1 into local main' "$case_dir/stdout" "evidenced: the landing was not reported"
  assert_absent "$case_dir/data/task-l1/captain-merge-instructions.jsonl" \
    "evidenced: an ordinary landing wrote an override record"
  pass "fm-merge-local lands a fully evidenced task with no override"
}

test_accepted_blocked_task_is_refused
test_accepted_blocked_task_lands_under_captain_instruction
test_blank_captain_instruction_is_rejected
test_evidenced_task_lands_unchanged

echo "all fm-merge-local tests passed"
