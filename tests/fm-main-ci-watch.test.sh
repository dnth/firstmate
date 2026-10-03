#!/usr/bin/env bash
# Tests for the post-merge base-branch CI watch: bin/fm-pr-merge.sh arms
# bin/fm-main-ci-watch.sh only after a merge is verified, the armed
# state/<task>-main-ci-<pr>.check.sh custom check (bin/fm-main-ci-poll.sh)
# wakes firstmate once on a failing run, retires silently on green, keeps
# waiting while runs are pending or uncreated, and emits one bounded-timeout
# wake instead of giving up silently.
#
# Matrix:
#   (a) a verified merge arms state/<id>-main-ci-<n>.check.sh + .check-trust
#   (b) a refused (still-open) merge arms no CI watch
#   (c) a queued (merge-queue) merge arms no CI watch
#   (d) an arming failure warns on stderr but never fails the verified merge
#   (e) failing run: exactly one wake line naming PR URL + workflow/job, then
#       the check and its trust are gone
#   (f) all-green runs: silent retirement
#   (g) pending-then-green: silent while pending, silent retirement on green
#   (h) deadline with no run ever listed: one "not observed" wake + retirement
#   (i) deadline with runs still pending: one "still pending" wake + retirement
#   (j) pending runs inside the deadline: silent and still armed
#   (k) a forge read error inside the deadline: silent and still armed
#   (l) fm-main-ci-watch.sh invoked directly arms the same check and refuses
#       bad input
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
CI_WATCH="$ROOT/bin/fm-main-ci-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-main-ci-watch-tests)
BASE_PATH=$PATH

# Fresh sandbox per case: a state dir with one task meta plus a fakebin holding
# gh-axi and gh mocks. The gh mock answers the merge-read calls
# fm-pr-merge.sh makes and the CI-watch calls the armed check makes, all from
# case-local response files so each test controls the forge's answers.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$case_dir"
}

# gh-axi merges and reports the PR merged; gh answers fm-pr-check.sh's
# headRefOid lookup, the GraphQL outcome read, the rules read, and the
# CI-watch reads: `pr view --json baseRefName,mergeCommit`, `run list
# --commit`, and `run view --json jobs`.
add_forge_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      *mergeCommit*) cat "\$FM_TEST_PR_VIEW" ; exit 0 ;;
    esac
    ;;
  "api graphql")
    cat "\$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    cat "\$FM_TEST_GH_RULES"
    exit 0
    ;;
  "run list")
    [ -n "\${FM_TEST_RUN_LIST_FAIL:-}" ] && { echo 'error: run list failed' >&2; exit 1; }
    cat "\$FM_TEST_RUN_LIST"
    exit 0
    ;;
  "run view")
    cat "\$FM_TEST_RUN_VIEW"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
  write_github_outcome "$case_dir" MERGED true false main
  : > "$case_dir/github-rules"
  write_pr_view "$case_dir" main deadbeefcafefeed0000000000000000deadbeef
  write_run_list "$case_dir" '[]'
  write_run_view "$case_dir" ''
}

write_github_outcome() {
  local case_dir=$1 state=$2 merged=$3 queued=$4 base=$5
  printf '%s\n' \
    "state=$state" \
    "merged=$merged" \
    "queued=$queued" \
    "base=$base" > "$case_dir/github-outcome"
}

write_pr_view() {
  local case_dir=$1 base=$2 sha=$3
  printf '{"baseRefName":"%s","mergeCommit":{"oid":"%s"}}\n' \
    "$base" "$sha" > "$case_dir/pr-view"
}

write_run_list() {
  local case_dir=$1 json=$2
  printf '%s\n' "$json" > "$case_dir/run-list"
}

write_run_view() {
  local case_dir=$1 json=$2
  printf '%s\n' "$json" > "$case_dir/run-view"
}

run_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$ROOT}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_PR_VIEW="$case_dir/pr-view" \
  FM_TEST_RUN_LIST="$case_dir/run-list" \
  FM_TEST_RUN_VIEW="$case_dir/run-view" \
  FM_MAIN_CI_WATCH_SECS="${FM_MAIN_CI_WATCH_SECS-}" \
  PATH="$case_dir/fakebin:$BASE_PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  return "$rc"
}

# Run one watcher sweep's worth of the armed check exactly as run_check_process
# would: bash on the state/<id>.check.sh bytes with the fake forge on PATH.
run_check() {
  local case_dir=$1 check=$2 rc
  PATH="$case_dir/fakebin:$BASE_PATH" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_PR_VIEW="$case_dir/pr-view" \
  FM_TEST_RUN_LIST="$case_dir/run-list" \
  FM_TEST_RUN_VIEW="$case_dir/run-view" \
  FM_TEST_RUN_LIST_FAIL="${FM_TEST_RUN_LIST_FAIL:-}" \
    bash "$case_dir/state/$check" > "$case_dir/check-out" 2> "$case_dir/check-err"
  rc=$?
  return "$rc"
}

CHECK_NAME=task-x1-main-ci-9

test_verified_merge_arms_ci_watch() {
  local case_dir rc
  case_dir=$(make_case arms-on-merge)
  add_forge_mocks "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"

  set +e
  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "arms-on-merge: fm-pr-merge should succeed"
  assert_grep "armed: state/$CHECK_NAME.check.sh" "$case_dir/stdout" \
    "arms-on-merge: the CI watch was not reported armed"
  assert_present "$case_dir/state/$CHECK_NAME.check.sh" \
    "arms-on-merge: the armed check file is missing"
  assert_present "$case_dir/state/$CHECK_NAME.check-trust" \
    "arms-on-merge: the check trust binding is missing"
  [ "$(stat -c %a "$case_dir/state/$CHECK_NAME.check.sh")" = 700 ] \
    || fail "arms-on-merge: the armed check is not mode 0700"
  pass "fm-pr-merge arms the base-branch CI watch after a verified merge"
}

test_refused_merge_arms_nothing() {
  local case_dir rc
  case_dir=$(make_case refused-merge)
  add_forge_mocks "$case_dir" 6262626262626262626262626262626262626262
  write_github_outcome "$case_dir" OPEN false false main

  set +e
  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "refused-merge: an unproved merge must refuse"
  assert_absent "$case_dir/state/$CHECK_NAME.check.sh" \
    "refused-merge: a refused merge armed a CI watch"
  pass "fm-pr-merge arms no CI watch when the merge is refused"
}

test_queued_merge_arms_nothing() {
  local case_dir rc
  case_dir=$(make_case queued-merge)
  add_forge_mocks "$case_dir" 7373737373737373737373737373737373737373
  write_github_outcome "$case_dir" OPEN false true main

  set +e
  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "queued-merge: a queued merge still reports verified"
  assert_grep 'is queued' "$case_dir/stdout" \
    "queued-merge: the queued outcome was not reported"
  assert_absent "$case_dir/state/$CHECK_NAME.check.sh" \
    "queued-merge: a queued merge armed a CI watch before landing"
  pass "fm-pr-merge arms no CI watch while the merge is only queued"
}

test_arm_failure_never_fails_the_merge() {
  local case_dir rc
  case_dir=$(make_case arm-failure)
  add_forge_mocks "$case_dir" 8484848484848484848484848484848484848484

  set +e
  FM_MAIN_CI_WATCH_SECS=bogus \
  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "arm-failure: a failed watch arm must not fail a verified merge"
  assert_grep 'is merged' "$case_dir/stdout" \
    "arm-failure: the verified merge was not still reported"
  assert_grep 'could not arm the base-branch CI watch' "$case_dir/stderr" \
    "arm-failure: the arming failure was not reported"
  pass "fm-pr-merge keeps a verified merge successful when watch arming fails"
}

test_failing_run_wakes_once() {
  local case_dir rc
  case_dir=$(make_case failing-run)
  add_forge_mocks "$case_dir" 9494949494949494949494949494949494949494
  write_run_list "$case_dir" \
    '[{"databaseId":37096198505,"workflowName":"CI","status":"completed","conclusion":"failure"}]'
  write_run_view "$case_dir" \
    '{"jobs":[{"name":"Behavior portable serial 4","conclusion":"failure"},{"name":"lint","conclusion":"success"}]}'

  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "failing-run: fm-pr-merge should succeed"

  set +e
  run_check "$case_dir" "$CHECK_NAME.check.sh"
  rc=$?
  set -e
  expect_code 0 "$rc" "failing-run: the check must exit 0"

  # One line, naming the PR and the failing workflow plus its failing job; the
  # watcher wraps whatever the check prints into its single check wake.
  [ "$(wc -l < "$case_dir/check-out")" = 1 ] \
    || fail "failing-run: expected exactly one wake line, got $(wc -l < "$case_dir/check-out")"
  assert_grep 'main CI failed after https://github.com/example/repo/pull/9: CI / Behavior portable serial 4' \
    "$case_dir/check-out" \
    "failing-run: the wake did not name the PR, workflow, and job"
  assert_absent "$case_dir/state/$CHECK_NAME.check.sh" \
    "failing-run: the fired check was not retired"
  assert_absent "$case_dir/state/$CHECK_NAME.check-trust" \
    "failing-run: the fired check's trust was not retired"
  pass "a failing post-merge run produces exactly one wake naming the PR and job"
}

test_green_run_retires_silently() {
  local case_dir rc
  case_dir=$(make_case green-run)
  add_forge_mocks "$case_dir" a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5
  write_run_list "$case_dir" \
    '[{"databaseId":37136077554,"workflowName":"CI","status":"completed","conclusion":"success"}]'

  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "green-run: fm-pr-merge should succeed"

  run_check "$case_dir" "$CHECK_NAME.check.sh" \
    || fail "green-run: the check must exit 0"
  [ ! -s "$case_dir/check-out" ] \
    || fail "green-run: a green run must not wake firstmate"
  assert_absent "$case_dir/state/$CHECK_NAME.check.sh" \
    "green-run: a green run did not retire the check"
  assert_absent "$case_dir/state/$CHECK_NAME.check-trust" \
    "green-run: a green run did not retire the trust"
  pass "a green post-merge run retires the check with no wake"
}

test_pending_then_green_retires_silently() {
  local case_dir rc
  case_dir=$(make_case pending-green)
  add_forge_mocks "$case_dir" b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6
  write_run_list "$case_dir" \
    '[{"databaseId":1,"workflowName":"CI","status":"in_progress","conclusion":""}]'

  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "pending-green: fm-pr-merge should succeed"

  run_check "$case_dir" "$CHECK_NAME.check.sh" \
    || fail "pending-green: the pending sweep must exit 0"
  [ ! -s "$case_dir/check-out" ] \
    || fail "pending-green: a pending run must not wake firstmate"
  assert_present "$case_dir/state/$CHECK_NAME.check.sh" \
    "pending-green: a pending run retired the check early"

  write_run_list "$case_dir" \
    '[{"databaseId":1,"workflowName":"CI","status":"completed","conclusion":"success"}]'
  run_check "$case_dir" "$CHECK_NAME.check.sh" \
    || fail "pending-green: the green sweep must exit 0"
  [ ! -s "$case_dir/check-out" ] \
    || fail "pending-green: the green sweep must not wake firstmate"
  assert_absent "$case_dir/state/$CHECK_NAME.check.sh" \
    "pending-green: the green sweep did not retire the check"
  pass "a pending-then-green sequence retires silently"
}

test_deadline_without_runs_wakes_not_observed() {
  local case_dir rc
  case_dir=$(make_case deadline-no-runs)
  add_forge_mocks "$case_dir" c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7
  write_run_list "$case_dir" '[]'

  FM_MAIN_CI_WATCH_SECS=0 \
  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "deadline-no-runs: fm-pr-merge should succeed"

  run_check "$case_dir" "$CHECK_NAME.check.sh" \
    || fail "deadline-no-runs: the check must exit 0"
  [ "$(wc -l < "$case_dir/check-out")" = 1 ] \
    || fail "deadline-no-runs: expected exactly one timeout wake line"
  assert_grep 'main CI not observed after https://github.com/example/repo/pull/9' \
    "$case_dir/check-out" \
    "deadline-no-runs: the timeout wake did not name the PR"
  assert_absent "$case_dir/state/$CHECK_NAME.check.sh" \
    "deadline-no-runs: the timed-out check was not retired"
  pass "a deadline with no run wakes once with not-observed and retires"
}

test_deadline_with_pending_runs_wakes() {
  local case_dir rc
  case_dir=$(make_case deadline-pending)
  add_forge_mocks "$case_dir" d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8d8
  write_run_list "$case_dir" \
    '[{"databaseId":2,"workflowName":"CI","status":"in_progress","conclusion":""}]'

  FM_MAIN_CI_WATCH_SECS=0 \
  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "deadline-pending: fm-pr-merge should succeed"

  run_check "$case_dir" "$CHECK_NAME.check.sh" \
    || fail "deadline-pending: the check must exit 0"
  [ "$(wc -l < "$case_dir/check-out")" = 1 ] \
    || fail "deadline-pending: expected exactly one timeout wake line"
  assert_grep 'main CI still pending after https://github.com/example/repo/pull/9: CI' \
    "$case_dir/check-out" \
    "deadline-pending: the timeout wake did not name the pending workflow"
  assert_absent "$case_dir/state/$CHECK_NAME.check.sh" \
    "deadline-pending: the timed-out check was not retired"
  pass "a deadline with runs still pending wakes once and retires"
}

test_pending_inside_deadline_stays_silent() {
  local case_dir rc
  case_dir=$(make_case pending-inside)
  add_forge_mocks "$case_dir" e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9e9
  write_run_list "$case_dir" \
    '[{"databaseId":3,"workflowName":"CI","status":"queued","conclusion":""}]'

  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "pending-inside: fm-pr-merge should succeed"

  run_check "$case_dir" "$CHECK_NAME.check.sh" \
    || fail "pending-inside: the check must exit 0"
  [ ! -s "$case_dir/check-out" ] \
    || fail "pending-inside: a queued run must not wake firstmate"
  assert_present "$case_dir/state/$CHECK_NAME.check.sh" \
    "pending-inside: a queued run retired the check early"
  pass "a pending run inside the deadline stays silent and armed"
}

test_deadline_with_forge_error_wakes_not_observed() {
  local case_dir rc
  case_dir=$(make_case deadline-forge-error)
  add_forge_mocks "$case_dir" a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1

  FM_MAIN_CI_WATCH_SECS=0 \
  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "deadline-forge-error: fm-pr-merge should succeed"

  FM_TEST_RUN_LIST_FAIL=1 \
  run_check "$case_dir" "$CHECK_NAME.check.sh" \
    || fail "deadline-forge-error: the check must exit 0"
  [ "$(wc -l < "$case_dir/check-out")" = 1 ] \
    || fail "deadline-forge-error: expected exactly one timeout wake line"
  assert_grep 'main CI not observed after https://github.com/example/repo/pull/9' \
    "$case_dir/check-out" \
    "deadline-forge-error: an unreadable CI never produced the bounded wake"
  assert_absent "$case_dir/state/$CHECK_NAME.check.sh" \
    "deadline-forge-error: the timed-out check was not retired"
  pass "a deadline with an unreadable forge wakes once with not-observed and retires"
}

test_forge_error_inside_deadline_stays_silent() {
  local case_dir rc
  case_dir=$(make_case forge-error)
  add_forge_mocks "$case_dir" f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0

  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "forge-error: fm-pr-merge should succeed"

  FM_TEST_RUN_LIST_FAIL=1 \
  run_check "$case_dir" "$CHECK_NAME.check.sh" \
    || fail "forge-error: the check must exit 0"
  [ ! -s "$case_dir/check-out" ] \
    || fail "forge-error: a failed run-list read must not wake firstmate"
  assert_present "$case_dir/state/$CHECK_NAME.check.sh" \
    "forge-error: a failed read retired the check early"
  pass "a forge read error inside the deadline stays silent and armed"
}

test_direct_arm_and_bad_input() {
  local case_dir rc
  case_dir=$(make_case direct-arm)

  set +e
  FM_STATE_OVERRIDE="$case_dir/state" "$CI_WATCH" task-x1 \
    https://github.com/example/repo/pull/9 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "direct-arm: the arming script should succeed"
  assert_grep "armed: state/$CHECK_NAME.check.sh" "$case_dir/stdout" \
    "direct-arm: the armed check was not reported"
  assert_present "$case_dir/state/$CHECK_NAME.check-trust" \
    "direct-arm: the check was not trust-bound"

  set +e
  FM_STATE_OVERRIDE="$case_dir/state" "$CI_WATCH" 'bad id' \
    https://github.com/example/repo/pull/9 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "direct-arm: an invalid task id must refuse"

  set +e
  FM_STATE_OVERRIDE="$case_dir/state" "$CI_WATCH" task-x1 \
    https://gitlab.example.com/group/proj/-/merge_requests/9 >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" "direct-arm: a non-GitHub URL must refuse"
  pass "fm-main-ci-watch.sh arms directly and refuses invalid input"
}

test_verified_merge_records_pr_and_head() {
  local case_dir rc
  case_dir=$(make_case arms-and-records)
  mkdir -p "$case_dir/wt"
  add_forge_mocks "$case_dir" a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0
  : > "$case_dir/gh-axi.log"

  set +e
  run_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "arms-and-records: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "arms-and-records: pr= was not recorded"
  assert_grep 'pr_head=a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0' "$case_dir/state/task-x1.meta" \
    "arms-and-records: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "arms-and-records: gh-axi pr merge was not invoked as before"
  pass "fm-pr-merge records pr= and pr_head= unchanged while arming the watch"
}

test_verified_merge_records_pr_and_head
test_verified_merge_arms_ci_watch
test_refused_merge_arms_nothing
test_queued_merge_arms_nothing
test_arm_failure_never_fails_the_merge
test_failing_run_wakes_once
test_green_run_retires_silently
test_pending_then_green_retires_silently
test_deadline_without_runs_wakes_not_observed
test_deadline_with_pending_runs_wakes
test_pending_inside_deadline_stays_silent
test_deadline_with_forge_error_wakes_not_observed
test_forge_error_inside_deadline_stays_silent
test_direct_arm_and_bad_input
printf 'all fm-main-ci-watch tests passed\n'
