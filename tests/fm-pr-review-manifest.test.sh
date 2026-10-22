#!/usr/bin/env bash
# Behavior tests for the PR review manifest and body-format gates.
#
# bin/fm-review-manifest.sh owns the contract: every counted review and every
# unresolved review thread needs a `## Review follow-up` row whose disposition
# parses and proves itself, and the PR body must carry the pr skill's sections
# plus No-Mistakes' attestation where a pipeline ran. bin/fm-pr-check.sh refuses
# PR-ready on any failure, the watcher's PR poll reports items the table still
# leaves unanswered, and bin/fm-pr-merge.sh re-checks both immediately before a
# merge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANIFEST="$ROOT/bin/fm-review-manifest.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-review-manifest)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.invalid
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

ID=task-rm
URL=https://github.com/o/r/pull/41

# make_case <name>: one home with a real task worktree, a fake gh, a fake root
# holding only the guard, and a ship task whose acceptance evidence is complete.
# Prints the case directory.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data/$ID" "$dir/fakebin" "$dir/root/bin"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0700 "$dir/root/bin/fm-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefOid*)
        [ -z "${FM_TEST_GH_HEAD:-}" ] || { printf '%s\n' "$FM_TEST_GH_HEAD"; exit 0; }
        ;;
      *state*) printf 'OPEN\n'; exit 0 ;;
    esac
    ;;
  "pr checks") printf '[]\n'; exit 0 ;;
  "api graphql")
    if [ -n "${FM_TEST_REVIEW_TEMP_CHECK:-}" ]; then
      python3 - "$FM_TEST_REVIEW_TEMP_CHECK" <<'CHECK'
import json
import os
import stat
import sys
from pathlib import Path
files = list(Path(os.environ["TMPDIR"]).iterdir())
with open(sys.argv[1], "a") as report:
    report.write(json.dumps({"output_mode": stat.S_IMODE(os.fstat(1).st_mode),
                             "modes": [stat.S_IMODE(p.stat().st_mode) for p in files]}) + "\n")
CHECK
    fi
    # bin/fm-review-manifest.sh's single read; a case pins its answer in
    # $dir/reviews.json.
    case " $* " in
      *PullRequestReviewThread*)
        if [ -e "$FM_TEST_REVIEW_STATE.delay" ]; then
          printf 'comments\n' >> "$FM_TEST_REVIEW_STATE.calls"
          sleep 5
        fi
        cat "$FM_TEST_REVIEW_STATE.comments"; exit 0
        ;;
      *reviewThreads*)
        [ -f "${FM_TEST_REVIEW_STATE:-/nonexistent}" ] || exit 1
        if [ -e "$FM_TEST_REVIEW_STATE.delay" ]; then
          case " $* " in
            *reviewsCursor=page2*) printf 'page2\n' >> "$FM_TEST_REVIEW_STATE.calls"; sleep 5 ;;
            *) printf 'page1\n' >> "$FM_TEST_REVIEW_STATE.calls"; sleep 1 ;;
          esac
        fi
        case " $* " in
          *reviewsCursor=page2*) [ ! -e "$FM_TEST_REVIEW_STATE.fail" ] || exit 1; cat "$FM_TEST_REVIEW_STATE.next" ;;
          *) cat "$FM_TEST_REVIEW_STATE" ;;
        esac
        exit 0
        ;;
    esac
    exit 1
    ;;
  "api repos/"*)
    case "${2:-}" in
      */compare/*)
        [ ! -e "$FM_TEST_REVIEW_STATE.compare-fail" ] || exit 1
        if [ -e "$FM_TEST_REVIEW_STATE.evidence-delay" ]; then
          printf 'compare\n' >> "$FM_TEST_REVIEW_STATE.calls"
          sleep 5
        fi
        head=${FM_TEST_GH_HEAD:-$(jq -r '.data.repository.pullRequest.headRefOid' "$FM_TEST_REVIEW_STATE")}
        printf '{"status":"ahead","merge_base_commit":{"sha":"%s"}}\n' "$head"
        exit 0
        ;;
      */issues/*)
        if [ -e "$FM_TEST_REVIEW_STATE.evidence-delay" ]; then
          printf 'issue\n' >> "$FM_TEST_REVIEW_STATE.calls"
          sleep 5
        fi
        [ ! -e "$FM_TEST_REVIEW_STATE.issue-fail" ] && [ "${FM_TEST_ISSUE_MISSING:-0}" = 0 ] && { printf '7\n'; exit 0; }
        exit 1
        ;;
    esac
    exit 1
    ;;
esac
exit 1
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
esac
exit 0
SH
  chmod 0700 "$fakebin/gh" "$fakebin/gh-axi"
  git init -q "$dir/wt"
  printf 'fixture\n' > "$dir/wt/file.txt"
  git -C "$dir/wt" add file.txt
  git -C "$dir/wt" commit -qm "fixture head"
  printf '# Task\nFixture.\n\n# Acceptance criteria\n- AC1: Fixture works.\n\n# Definition of done\nDelivery contract: mode=%s\n' \
    "${FM_TEST_MODE:-direct-PR}" > "$dir/home/data/$ID/brief.md"
  printf '%s\n' '{"criterion":"AC1","type":"test","outcome":"success","summary":"fixture","result":"passed"}' \
    > "$dir/home/data/$ID/evidence.jsonl"
  : > "$dir/home/data/$ID/.evidence.lock"
  fm_write_meta "$dir/home/state/$ID.meta" \
    "window=fm-$ID" \
    "endpoint_task_id=$ID" \
    "worktree=$dir/wt" \
    "project=$dir/wt" \
    "kind=ship" \
    "mode=${FM_TEST_MODE:-direct-PR}"
  printf '%s\n' "$dir"
}

head_of() {  # <dir>
  git -C "$1/wt" rev-parse HEAD
}

# review_state <dir> <head> <reviews-json> <threads-json> [mode]
# Writes $dir/reviews.json, the response the fake gh serves.
review_state() {
  fm_write_pr_review_state "$1/reviews.json" "$2" "$3" "$4" "${5:-direct-PR}"
}

# body_state <dir> <head> <body> [reviews-json] [threads-json]
body_state() {
  local dir=$1 head=$2 body=$3 reviews=${4:-[]} threads=${5:-[]}
  local file="$dir/reviews.json"
  jq -n --arg head "$head" --arg body "$body" --argjson reviews "$reviews" --argjson threads "$threads" \
    '{data:{repository:{pullRequest:{
      headRefOid:$head,
      body:$body,
      reviews:{pageInfo:{hasNextPage:false},nodes:$reviews},
      reviewThreads:{pageInfo:{hasNextPage:false},nodes:$threads}}}}}' > "$file"
}

sections() {  # the three required sections with no review table
  printf '## Summary\n\nfixture\n\n## Evidence\n\n- **Before:** none\n  **After:** none\n\n## Merge Danger\n\n**Door:** two-way.\n**Blast Radius:** low.\n'
}

pipeline() {  # <head>
  printf '\n## Pipeline\n\nUpdates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":[{"step":"review","status":"completed"}]} -->\n\n| Test | Result |\n| --- | --- |\n| fixture | passed |\n' "$1"
}

run_pr_check() {  # <dir>
  local dir=$1
  CHECK_OUT=$(FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_REVIEW_STATE="$dir/reviews.json" \
    FM_TEST_GH_HEAD="${FM_TEST_GH_HEAD:-}" \
    FM_TEST_ISSUE_MISSING="${FM_TEST_ISSUE_MISSING:-0}" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_CHECK" "$ID" "$URL" 2>&1)
  CHECK_RC=$?
}

run_pr_merge() {  # <dir>
  local dir=$1
  MERGE_OUT=$(FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_REVIEW_STATE="$dir/reviews.json" \
    FM_TEST_GH_HEAD="${FM_TEST_GH_HEAD:-}" \
    PATH="$dir/fakebin:$BASE_PATH" "$PR_MERGE" "$ID" "$URL" 2>&1)
  MERGE_RC=$?
}

run_poll() {  # <dir>
  local dir=$1
  POLL_OUT=$(FM_TEST_REVIEW_STATE="$dir/reviews.json" PATH="$dir/fakebin:$BASE_PATH" \
    "$POLL" --validated github "$URL" github.com o/r 41 2>&1)
}

run_watcher_cycle() {  # <dir>
  local dir=$1 check_timeout=${2:-10}
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 15; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env -u FM_TASK_ID FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/root" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT="$check_timeout" \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 FM_WATCH_HANDLING_SUCCESSOR=1 \
      FM_WATCH_RESURFACE_MAX_ANNOUNCEMENTS=999999 FM_WATCH_RESURFACE_MAX_SECS=999999 \
      FM_TEST_REVIEW_STATE="$dir/reviews.json" FM_TEST_GH_HEAD="$FM_TEST_GH_HEAD" \
      FM_TEST_ISSUE_MISSING="${FM_TEST_ISSUE_MISSING:-0}" \
      PATH="$dir/fakebin:$BASE_PATH" "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err"
}

AUTHOR_REVIEW_REVIEWS='[{"databaseId":55,"state":"CHANGES_REQUESTED","body":"1. Quote the item text\n2. Fix the nit"}]'

test_commented_review_without_a_table_is_not_ready() {
  local dir head
  dir=$(make_case commented-no-table)
  head=$(head_of "$dir")
  review_state "$dir" "$head" "$AUTHOR_REVIEW_REVIEWS" '[]'
  FM_TEST_GH_HEAD=$head
  run_pr_check "$dir"
  [ "$CHECK_RC" -ne 0 ] || fail "AC1a: a review with no manifest table was accepted"
  assert_contains "$CHECK_OUT" "$URL#pullrequestreview-55" \
    "AC1a: the refusal did not name the review URL"
  [ ! -e "$dir/home/state/$ID.check.sh" ] || fail "AC1a: a refused PR armed the poll"
  pass "AC1a: another user's COMMENTED review with no manifest table is not ready"
}

test_fixed_sha_must_be_reachable_from_the_pr_head() {
  local dir head tree foreign
  dir=$(make_case fixed-sha)
  head=$(head_of "$dir")
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  foreign=$(git -C "$dir/wt" commit-tree "$tree" -m "unrelated commit")
  body_state "$dir" "$head" "$(sections)

## Review follow-up

| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-55 | \"1. Quote the item text\" | fixed $foreign |
"
  FM_TEST_GH_HEAD=$head
  run_pr_check "$dir"
  [ "$CHECK_RC" -ne 0 ] || fail "AC1b1: a fixed sha outside the PR was accepted"
  assert_contains "$CHECK_OUT" "$foreign" "AC1b1: the refusal did not name the unreachable commit"
  [ ! -e "$dir/home/state/$ID.check.sh" ] || fail "AC1b1: a refused PR armed the poll"
  pass "AC1b1: a fixed <sha> that is not in the PR refuses PR-ready"
}

test_well_formed_rows_are_ready_with_the_coverage_disclosure() {
  local dir head
  dir=$(make_case well-formed)
  head=$(head_of "$dir")
  body_state "$dir" "$head" "$(sections)

## Review follow-up

| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-55 | \"1. Quote the item text\" | fixed $head |
| pullrequestreview-56 | \"2. Rename the helper\" | declined: the name is part of the public contract |
| pullrequestreview-57 | \"3. Cover the edge case\" | deferred: https://github.com/o/r/issues/9 |
" \
    '[{"databaseId":55,"state":"CHANGES_REQUESTED","body":"1. Quote the item text"},
      {"databaseId":56,"state":"COMMENTED","body":"2. Rename the helper"},
      {"databaseId":57,"state":"COMMENTED","body":"3. Cover the edge case"}]' '[]'
  FM_TEST_GH_HEAD=$head
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "AC1b2: well-formed rows were refused: $CHECK_OUT"
  assert_contains "$CHECK_OUT" \
    "review $URL: 3 items declared by author; coverage of review text NOT machine-verified" \
    "AC1b2: the success output carried no coverage disclosure"
  [ -e "$dir/home/state/$ID.check.sh" ] || fail "AC1b2: a ready PR did not arm the poll"
  pass "AC1b2: well-formed rows are ready and print the not-machine-verified disclosure"
}

test_review_id_in_prose_only_is_not_ready() {
  local dir head
  dir=$(make_case prose-only)
  head=$(head_of "$dir")
  body_state "$dir" "$head" "$(sections)
Review follow-up applied: pullrequestreview-55 was addressed in prose, see $URL#pullrequestreview-55.
" "$AUTHOR_REVIEW_REVIEWS" '[]'
  FM_TEST_GH_HEAD=$head
  run_pr_check "$dir"
  [ "$CHECK_RC" -ne 0 ] || fail "AC1b3: a review id mentioned only in prose counted as coverage"
  assert_contains "$CHECK_OUT" "$URL#pullrequestreview-55" "AC1b3: the refusal did not name the review URL"
  [ ! -e "$dir/home/state/$ID.check.sh" ] || fail "AC1b3: a refused PR armed the poll"
  pass "AC1b3: a review id that appears only in prose proves no coverage"
}

test_unresolved_thread_needs_its_own_row() {
  local dir head threads
  dir=$(make_case unresolved-thread)
  head=$(head_of "$dir")
  threads='[{"id":"PRRT_kwDOthread","isResolved":false,"comments":{"nodes":[{"databaseId":907,"body":"this branch is never taken"}]}}]'
  body_state "$dir" "$head" "$(sections)" '[]' "$threads"
  FM_TEST_GH_HEAD=$head
  run_pr_check "$dir"
  [ "$CHECK_RC" -ne 0 ] || fail "AC1c: an unresolved thread without a row was accepted"
  assert_contains "$CHECK_OUT" "$URL#discussion_r907" \
    "AC1c: the refusal did not name the unresolved thread's comment URL"
  body_state "$dir" "$head" "$(sections)

## Review follow-up

| Review | Item | Disposition |
| --- | --- | --- |
| PRRT_kwDOthread | \"this branch is never taken\" | fixed $head |
" '[]' "$threads"
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "AC1c: a row keyed by the thread id was refused: $CHECK_OUT"
  pass "AC1c: every unresolved thread needs its own keyed row"
}

test_tool_generated_items_are_skipped_by_their_markers() {
  local dir head reviews threads
  dir=$(make_case tool-markers)
  head=$(head_of "$dir")
  reviews='[{"databaseId":61,"state":"COMMENTED","body":"<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":[]} -->"},
            {"databaseId":62,"state":"COMMENTED","body":"<!-- fm-worker-note -->"},
            {"databaseId":63,"state":"COMMENTED","body":"human note from the author account"}]'
  threads='[{"id":"PRRT_kwDOauto","isResolved":false,"comments":{"nodes":[{"databaseId":908,"body":"<!-- no-mistakes-pr-appendix: generated -->"}]}}]'
  body_state "$dir" "$head" "$(sections)" "$reviews" "$threads"
  FM_TEST_GH_HEAD=$head
  run_pr_check "$dir"
  [ "$CHECK_RC" -ne 0 ] || fail "AC1d: an author-account comment needed a row but was accepted"
  assert_contains "$CHECK_OUT" "$URL#pullrequestreview-63" \
    "AC1d: the refusal did not name the author-account comment"
  case "$CHECK_OUT" in
    *"pullrequestreview-61"*|*"pullrequestreview-62"*|*"#discussion_r908"*)
      fail "AC1d: a tool-generated item was counted as a review item"
      ;;
  esac
  body_state "$dir" "$head" "$(sections)

## Review follow-up

| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-63 | \"human note from the author account\" | declined: the author's own note needs no change |
" "$reviews" "$threads"
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "AC1d: tool-generated items were refused after the human row was added: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "review $URL: 1 item declared by author" \
    "AC1d: the disclosure did not count only the human item"
  pass "AC1d: tool-generated comments are skipped by marker, the author account's own comment still needs a row"
}

test_inline_only_review_still_needs_a_row() {
  local dir head reviews
  dir=$(make_case inline-only-review)
  head=$(head_of "$dir")
  # A review that carries only inline comments has an empty body, and its
  # threads are resolved, so the review itself is the only remaining item.
  reviews='[{"databaseId":58,"state":"CHANGES_REQUESTED","body":""}]'
  body_state "$dir" "$head" "$(sections)" "$reviews" \
    '[{"id":"PRRT_kwDOresolved","isResolved":true,"comments":{"nodes":[{"databaseId":910,"body":"already handled"}]}}]'
  FM_TEST_GH_HEAD=$head
  run_pr_check "$dir"
  [ "$CHECK_RC" -ne 0 ] || fail "AC1: an inline-only review with no row was accepted"
  assert_contains "$CHECK_OUT" "$URL#pullrequestreview-58" \
    "AC1: the refusal did not name the inline-only review"
  body_state "$dir" "$head" "$(sections)

## Review follow-up

| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-58 | \"inline: the branch is never taken\" | fixed $head |
" "$reviews" '[]'
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "AC1: a row covering an inline-only review was refused: $CHECK_OUT"
  pass "AC1: a review with an empty body still needs a row, and a covering row is ready"
}

test_no_reviews_requires_no_table() {
  local dir head
  dir=$(make_case no-reviews)
  head=$(head_of "$dir")
  review_state "$dir" "$head" '[]' '[]'
  FM_TEST_GH_HEAD=$head
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "AC1e: a PR with no reviews was refused: $CHECK_OUT"
  case "$CHECK_OUT" in
    *"NOT machine-verified"*) fail "AC1e: a PR with no reviews printed a coverage disclosure" ;;
  esac
  pass "AC1e: no reviews and no threads means no manifest table is required"
}

test_body_sections_are_required() {
  local dir head body section
  dir=$(make_case body-sections)
  head=$(head_of "$dir")
  FM_TEST_GH_HEAD=$head
  for section in Summary Evidence "Merge Danger"; do
    body=$(sections | grep -v "^## $section$")
    body_state "$dir" "$head" "$body" >/dev/null
    run_pr_check "$dir"
    [ "$CHECK_RC" -ne 0 ] || fail "AC2: a body without '## $section' was accepted"
    assert_contains "$CHECK_OUT" "## $section" "AC2: the refusal did not name the missing '## $section' section"
    [ ! -e "$dir/home/state/$ID.check.sh" ] || fail "AC2: a refused PR armed the poll"
  done
  pass "AC2: a body missing Summary, Evidence, or Merge Danger is not ready and names the section"
}

test_pipeline_attestation_must_be_intact() {
  local dir head out
  dir=$(make_case pipeline-attestation)
  head=$(head_of "$dir")
  FM_TEST_GH_HEAD=$head
  review_state "$dir" "$head" '[]' '[]' no-mistakes

  # The verifier owns the mode rule; the gates call it in the task's own mode.
  verify_out() {
    FM_TEST_REVIEW_STATE="$dir/reviews.json" PATH="$dir/fakebin:$BASE_PATH" \
      "$MANIFEST" verify "$URL" --mode no-mistakes --worktree "$dir/wt" 2>&1
  }

  body_state "$dir" "$head" "$(sections)"
  out=$(verify_out) && fail "AC2: a no-mistakes body without '## Pipeline' was accepted"
  assert_contains "$out" "no '## Pipeline' section" "AC2: the refusal did not name the missing Pipeline section"

  body_state "$dir" "$head" "$(sections)
## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)
"
  out=$(verify_out) && fail "AC2: a Pipeline section without its attestation was accepted"
  assert_contains "$out" "no intact No-Mistakes attestation" \
    "AC2: the refusal did not name the missing attestation"

  body_state "$dir" "$head" "$(sections)
## Pipeline

<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$head\",\"steps\":[]} -->
"
  out=$(verify_out) && fail "AC2: an altered attestation was accepted"
  assert_contains "$out" "attestation is malformed" "AC2: an altered attestation was not named"

  body_state "$dir" "$head" "$(sections)$(pipeline deadbeefdeadbeefdeadbeefdeadbeefdeadbeef)"
  out=$(verify_out) && fail "AC2: an attestation for another head was accepted"
  assert_contains "$out" "not the PR head $head" \
    "AC2: an attestation bound to another head was not named"

  body_state "$dir" "$head" "$(sections)$(pipeline "$head")"
  out=$(verify_out) || fail "AC2: a correct body was refused: $out"

  # A body that carries a Pipeline section in any mode has to carry an intact
  # attestation, so the same rule reaches PR-ready through fm-pr-check.sh. The
  # task is a direct-PR one, so no No-Mistakes run has to exist.
  body_state "$dir" "$head" "$(sections)
## Pipeline

<!-- no-mistakes-pipeline-attestation:v1 not-json -->
"
  run_pr_check "$dir"
  [ "$CHECK_RC" -ne 0 ] || fail "AC2: a direct-PR body with a broken Pipeline section was accepted"
  assert_contains "$CHECK_OUT" "attestation" "AC2: the PR-ready refusal did not name the attestation"

  body_state "$dir" "$head" "$(sections)$(pipeline "$head")"
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "AC2: a correct body was refused at PR-ready: $CHECK_OUT"
  pass "AC2: the Pipeline section and its attestation must be intact, and a correct body is ready"
}

test_merge_refuses_an_unanswered_review() {
  local dir head
  dir=$(make_case merge-unanswered)
  head=$(head_of "$dir")
  FM_TEST_GH_HEAD=$head
  body_state "$dir" "$head" "$(sections)" "$AUTHOR_REVIEW_REVIEWS" '[]'
  run_pr_merge "$dir"
  [ "$MERGE_RC" -ne 0 ] || fail "AC3: fm-pr-merge merged with an unanswered review"
  assert_contains "$MERGE_OUT" "$URL#pullrequestreview-55" \
    "AC3: the merge refusal did not name the unanswered review"
  assert_contains "$MERGE_OUT" "--captain-instruction" \
    "AC3: the merge refusal did not name the only override"

  body_state "$dir" "$head" "$(sections)

## Review follow-up

| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-55 | \"1. Quote the item text\" | declined: item one is out of scope for this change |
" "$AUTHOR_REVIEW_REVIEWS" '[]'
  run_pr_merge "$dir"
  [ "$MERGE_RC" -eq 0 ] || fail "AC3: a covered review still refused the merge: $MERGE_OUT"
  pass "AC3: fm-pr-merge re-runs the review check and refuses an unanswered review"
}

test_pr_poll_reports_an_unanswered_review_once() {
  local dir head state queue_before queue_after
  dir=$(make_case poll-review)
  head=$(head_of "$dir")
  state="$dir/home/state"
  FM_TEST_GH_HEAD=$head
  body_state "$dir" "$head" "$(sections)

## Review follow-up

| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-55 | \"1. Quote the item text\" | fixed $head |
" "$AUTHOR_REVIEW_REVIEWS" '[]'
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "AC3: the ready seed was refused: $CHECK_OUT"

  # A review posted after PR-ready has no row yet.
  body_state "$dir" "$head" "$(sections)

## Review follow-up

| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-55 | \"1. Quote the item text\" | fixed $head |
" '[{"databaseId":55,"state":"CHANGES_REQUESTED","body":"1. Quote the item text"},
    {"databaseId":56,"state":"COMMENTED","body":"a later remark with no row"}]' '[]'

  run_poll "$dir"
  [ "$POLL_OUT" = "review $URL pullrequestreview-56" ] \
    || fail "AC3: the poll did not report the unanswered review (got: '$POLL_OUT')"

  queue_before=$(grep -c 'review' "$state/.wake-queue" 2>/dev/null || true)
  run_watcher_cycle "$dir"
  assert_contains "$(cat "$dir/watch.out")" "pullrequestreview-56" \
    "AC3: the watcher did not surface the unanswered review"
  queue_after=$(grep -c 'review' "$state/.wake-queue" 2>/dev/null || true)
  [ "${queue_after:-0}" -gt "${queue_before:-0}" ] \
    || fail "AC3: the unanswered review produced no durable wake record"
  run_watcher_cycle "$dir"
  case "$(cat "$dir/watch.out")" in
    *pullrequestreview-56*) fail "AC3: the same unanswered review woke firstmate again" ;;
  esac
  pass "AC3: the PR poll reports a review posted after ready, and the watcher reports it once"
}

test_poll_validates_dispositions() {
  local dir head reviews threads key disp item
  dir=$(make_case poll-dispositions)
  head=$(head_of "$dir")
  FM_TEST_GH_HEAD=$head
  body_state "$dir" "$head" "$(sections)"
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "disposition seed refused: $CHECK_OUT"
  reviews='[{"databaseId":56,"state":"COMMENTED","body":"quoted item"}]'
  threads='[{"id":"PRRT_draft","isResolved":false,"comments":{"nodes":[{"databaseId":902,"body":"quoted item"}]}}]'
  body_state "$dir" "$head" "$(sections)
## Review follow-up
| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-56 | quoted item | TODO |" "$reviews" '[]'
  run_poll "$dir"
  [ "$POLL_OUT" = "review $URL pullrequestreview-56" ] || fail "draft review row produced clear: $POLL_OUT"
  run_watcher_cycle "$dir"
  assert_contains "$(cat "$dir/watch.out")" 'pullrequestreview-56' "review posted after ready with a TODO row did not wake supervision"
  for key in pullrequestreview-56 PRRT_draft; do
    for disp in TODO 'fixed deadbeef' 'declined:' 'deferred: not-an-issue' malformed-row; do
      item='quoted item'
      if [ "$disp" = malformed-row ]; then item='quoted | item'; disp='declined: reason'; fi
      if [ "$key" = pullrequestreview-56 ]; then
        body_state "$dir" "$head" "$(sections)
## Review follow-up
| Review | Item | Disposition |
| --- | --- | --- |
| $key | $item | $disp |" "$reviews" '[]'
      else
        body_state "$dir" "$head" "$(sections)
## Review follow-up
| Review | Item | Disposition |
| --- | --- | --- |
| $key | $item | $disp |" '[]' "$threads"
      fi
      run_poll "$dir"
      [ "$POLL_OUT" = "review $URL $key" ] || fail "invalid $key row was covered: $POLL_OUT"
    done
    for disp in "fixed $head" 'declined: reason' 'deferred: https://github.com/o/r/issues/9'; do
      body_state "$dir" "$head" "$(sections)
## Review follow-up
| Review | Item | Disposition |
| --- | --- | --- |
| $key | quoted item | $disp |" \
        "$(if [ "$key" = pullrequestreview-56 ]; then printf '%s' "$reviews"; else printf '[]'; fi)" \
        "$(if [ "$key" = PRRT_draft ]; then printf '%s' "$threads"; else printf '[]'; fi)"
      run_poll "$dir"
      [ "$POLL_OUT" = "review $URL clear" ] || fail "valid $key disposition refused: $POLL_OUT"
      case "$disp" in
        fixed*) touch "$dir/reviews.json.compare-fail" ;;
        deferred*) touch "$dir/reviews.json.issue-fail" ;;
        *) continue ;;
      esac
      run_poll "$dir"
      [ "$POLL_OUT" = "review $URL unreadable" ] || fail "failed disposition evidence read was hidden: $POLL_OUT"
      rm -f "$dir/reviews.json.compare-fail" "$dir/reviews.json.issue-fail"
    done
  done
  pass "poll and verify share row validation for reviews and threads, including TODO rows after ready"
}

test_poll_evidence_deadline() {
  local dir head disp
  for disp in fixed deferred; do
    dir=$(make_case "poll-evidence-$disp")
    head=$(head_of "$dir")
    FM_TEST_GH_HEAD=$head
    body_state "$dir" "$head" "$(sections)"
    run_pr_check "$dir"
    [ "$CHECK_RC" -eq 0 ] || fail "evidence deadline seed refused: $CHECK_OUT"
    case "$disp" in
      fixed) disp="fixed $head" ;;
      deferred) disp='deferred: https://github.com/o/r/issues/9' ;;
    esac
    body_state "$dir" "$head" "$(sections)
## Review follow-up
| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-56 | quoted item | $disp |" \
      '[{"databaseId":56,"state":"COMMENTED","body":"quoted item"}]' '[]'
    touch "$dir/reviews.json.delay" "$dir/reviews.json.evidence-delay"
    run_watcher_cycle "$dir" 6 \
      || fail "disposition evidence did not wake before the outer timeout: $(cat "$dir/watch.out" "$dir/watch.err")"
    assert_contains "$(cat "$dir/watch.out")" "review $URL unreadable" "slow disposition evidence failed silently"
    [ "$(wc -l < "$dir/reviews.json.calls" | tr -d ' ')" -eq 2 ] || fail "deadline fixture did not reach disposition evidence"
  done
  pass "disposition evidence shares the paginated read deadline"
}

test_reopened_thread_wakes_again() {
  local dir head threads expected
  dir=$(make_case reopened-thread)
  head=$(head_of "$dir")
  FM_TEST_GH_HEAD=$head
  body_state "$dir" "$head" "$(sections)"
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "reopened-thread seed was refused: $CHECK_OUT"
  threads='[{"id":"PRRT_reopened","isResolved":false,"comments":{"nodes":[{"databaseId":901,"body":"unanswered item"}]}}]'
  body_state "$dir" "$head" "$(sections)" '[]' "$threads"
  run_poll "$dir"
  expected="review $URL PRRT_reopened"
  [ "$POLL_OUT" = "$expected" ] || fail "unanswered thread was not reported: $POLL_OUT"
  run_watcher_cycle "$dir"
  assert_contains "$(cat "$dir/watch.out")" "$expected" "unanswered thread did not wake supervision"
  body_state "$dir" "$head" "$(sections)" '[]' "$(printf '%s' "$threads" | jq '.[0].isResolved=true')"
  run_poll "$dir"
  [ "$POLL_OUT" = "review $URL clear" ] || fail "resolved thread did not produce a clear result: $POLL_OUT"
  run_watcher_cycle "$dir"
  [ ! -e "$dir/home/state/$ID.pr-poll-review-notified" ] || fail "clear result retained the unanswered-thread notification"
  case "$(cat "$dir/watch.out")" in
    *"review $URL"*) fail "resolved thread woke supervision" ;;
  esac
  body_state "$dir" "$head" "$(sections)" '[]' "$threads"
  run_poll "$dir"
  [ "$POLL_OUT" = "$expected" ] || fail "reopened thread changed its poll identity: $POLL_OUT"
  run_watcher_cycle "$dir"
  assert_contains "$(cat "$dir/watch.out")" "$expected" "reopened thread did not wake supervision again"
  [ "$(grep -c "$expected" "$dir/home/state/.wake-queue")" -eq 2 ] \
    || fail "unanswered and reopened thread did not each produce one durable wake"
  pass "a resolved and reopened unanswered thread wakes supervision again"
}

test_review_regressions() {
  local dir head out body key
  dir=$(make_case review-regressions)
  head=$(head_of "$dir")
  FM_TEST_GH_HEAD=$head
  for body in "$(sections)$(pipeline "$head" | sed '/^|/d')" \
      "$(sections)$(pipeline "$head" | sed 's/\[{"step":"review","status":"completed"}\]/[{}]/')" \
      "$(pipeline "$head" | sed '/^## Pipeline$/d')$(sections)
## Pipeline
| Test | Result |
| --- | --- |
| fixture | passed |"; do
    body_state "$dir" "$head" "$body"
    out=$(FM_TEST_REVIEW_STATE="$dir/reviews.json" PATH="$dir/fakebin:$BASE_PATH" \
      "$MANIFEST" verify "$URL" --mode no-mistakes) && fail "altered Pipeline accepted: $out"
  done
  body_state "$dir" "$head" "$(sections)" \
    '[{"databaseId":55,"state":"COMMENTED","body":"Preserve no-mistakes-pipeline-attestation when rewriting"}]' \
    '[{"id":"PRRT_human","isResolved":false,"comments":{"nodes":[{"databaseId":1,"body":"<!-- fm-worker-note -->"},{"databaseId":2,"body":"human follow-up"}]}}]'
  run_pr_check "$dir"
  [ "$CHECK_RC" -ne 0 ] || fail "human marker mentions were skipped"
  assert_contains "$CHECK_OUT" "pullrequestreview-55" "human review skipped"
  assert_contains "$CHECK_OUT" "discussion_r1" "human thread follow-up skipped"
  for key in 'pullrequestreview-55 PRRT_human' 'discussion_r1' "$URL#pullrequestreview-55"; do
    body_state "$dir" "$head" "$(sections)
## Review follow-up
| Review | Item | Disposition |
| --- | --- | --- |
| $key | quote | declined: reason |" "$AUTHOR_REVIEW_REVIEWS" '[]'
    run_pr_check "$dir"
    [ "$CHECK_RC" -ne 0 ] || fail "noncanonical key accepted: $key"
  done
  body_state "$dir" "$head" "$(sections)
## Review follow-up
| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-55 | a \|\| b | fixed $head |
| pullrequestreview-55 | second item | declined: reason |" "$AUTHOR_REVIEW_REVIEWS" '[]'
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "escaped pipes refused: $CHECK_OUT"
  assert_contains "$CHECK_OUT" '2 items declared by author' "container count used for disclosure"
  out=$(FM_TEST_REVIEW_STATE="$dir/reviews.json" FM_TEST_GH_HEAD="$head" PATH="$dir/fakebin:$BASE_PATH" \
    "$MANIFEST" verify "$URL" --mode direct-PR) || fail "forge reachability refused: $out"
  touch "$dir/reviews.json.compare-fail"
  out=$(FM_TEST_REVIEW_STATE="$dir/reviews.json" FM_TEST_GH_HEAD="$head" PATH="$dir/fakebin:$BASE_PATH" \
    "$MANIFEST" verify "$URL" --mode direct-PR) && fail "unproved forge reachability accepted"
  pass "Pipeline integrity, human envelopes, canonical keys, escaped pipes, row counts, forge reachability"
}

test_paginated_reviews() {
  local dir head out
  dir=$(make_case paginated-reviews)
  head=$(head_of "$dir")
  FM_TEST_GH_HEAD=$head
  body_state "$dir" "$head" "$(sections)" '[]' \
    '[{"id":"PRRT_later","isResolved":false,"comments":{"nodes":[{"databaseId":999,"body":"later thread"}]}}]'
  cp "$dir/reviews.json" "$dir/reviews.json.next"
  jq '.data.repository.pullRequest.reviews.pageInfo={hasNextPage:true,endCursor:"page2"} | .data.repository.pullRequest.reviewThreads.pageInfo={hasNextPage:true,endCursor:"page2"} | .data.repository.pullRequest.reviewThreads.nodes=[]' \
    "$dir/reviews.json.next" > "$dir/reviews.json"
  run_pr_check "$dir"
  [ "$CHECK_RC" -ne 0 ] || fail "page two thread omitted"
  assert_contains "$CHECK_OUT" 'discussion_r999' "page two thread not named"
  run_poll "$dir"
  assert_contains "$POLL_OUT" 'PRRT_later' "poll omitted page two thread"
  body_state "$dir" "$head" "$(sections)
## Review follow-up
| Review | Item | Disposition |
| --- | --- | --- |
| PRRT_later | later thread | fixed $head |" '[]' \
    '[{"id":"PRRT_later","isResolved":false,"comments":{"nodes":[{"databaseId":999,"body":"later thread"}]}}]'
  cp "$dir/reviews.json" "$dir/reviews.json.next"
  jq '.data.repository.pullRequest.reviews.pageInfo={hasNextPage:true,endCursor:"page2"} | .data.repository.pullRequest.reviewThreads.pageInfo={hasNextPage:true,endCursor:"page2"} | .data.repository.pullRequest.reviewThreads.nodes=[]' \
    "$dir/reviews.json.next" > "$dir/reviews.json"
  run_pr_check "$dir"
  [ "$CHECK_RC" -eq 0 ] || fail "covered paginated thread refused: $CHECK_OUT"
  touch "$dir/reviews.json.fail"
  run_pr_check "$dir"
  [ "$CHECK_RC" -ne 0 ] || fail "partial read accepted"
  out=$(FM_TEST_REVIEW_STATE="$dir/reviews.json" PATH="$dir/fakebin:$BASE_PATH" \
    "$MANIFEST" poll "$URL" 2>&1) && fail "partial poll silently succeeded"
  assert_contains "$out" 'could not be read' "partial poll had no error"
  run_poll "$dir"
  [ "$POLL_OUT" = "review $URL unreadable" ] || fail "production poll hid the failed page: $POLL_OUT"
  run_watcher_cycle "$dir"
  assert_contains "$(cat "$dir/watch.out")" "review $URL unreadable" "unreadable review state did not wake supervision"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" "review $URL unreadable" "read failure produced no durable wake"
  run_watcher_cycle "$dir"
  case "$(cat "$dir/watch.out")" in
    *"review $URL unreadable"*) fail "the same read failure repeatedly woke supervision" ;;
  esac
  rm -f "$dir/reviews.json.fail"
  run_poll "$dir"
  [ "$POLL_OUT" = "review $URL clear" ] || fail "successful empty review result did not prove recovery: $POLL_OUT"
  run_watcher_cycle "$dir"
  [ ! -e "$dir/home/state/$ID.pr-poll-review-notified" ] || fail "recovery retained the unreadable notification"
  case "$(cat "$dir/watch.out")" in
    *"review $URL clear"*) fail "successful empty review result woke supervision" ;;
  esac
  touch "$dir/reviews.json.fail"
  run_watcher_cycle "$dir"
  assert_contains "$(cat "$dir/watch.out")" "review $URL unreadable" "a separate outage was suppressed after recovery"
  [ "$(grep -c "review $URL unreadable" "$dir/home/state/.wake-queue")" -eq 2 ] \
    || fail "separate outages did not each produce one durable wake"
  pass "paginated coverage, failed page reads, deduplication, and notification reset after recovery"
}

test_gitlab_without_github_tools() {
  local dir out command
  dir="$TMP_ROOT/gitlab-only"
  mkdir -p "$dir/bin"
  ln -s "$BASH" "$dir/bin/bash"
  ln -s "$(command -v dirname)" "$dir/bin/dirname"
  printf '#!/bin/sh\nexit 99\n' > "$dir/bin/glab"
  chmod 0700 "$dir/bin/glab"
  PATH="$dir/bin" "$BASH" -c 'command -v glab >/dev/null && ! command -v gh >/dev/null && ! command -v jq >/dev/null' \
    || fail "GitLab-only fixture has the wrong available tools"
  for command in verify poll; do
    if [ "$command" = verify ]; then
      out=$(PATH="$dir/bin" "$BASH" "$MANIFEST" verify https://gitlab.example/group/repo/-/merge_requests/7 --mode direct-PR 2>&1)
    else
      out=$(PATH="$dir/bin" "$BASH" "$MANIFEST" poll https://gitlab.example/group/repo/-/merge_requests/7 2>&1)
    fi
    [ "$?" -eq 0 ] || fail "$command blocked GitLab on missing GitHub tools: $out"
    assert_contains "$out" 'notice: review manifest verification covers GitHub pull requests only' "$command did not identify GitLab as out of scope"
  done
  out=$(PATH="$dir/bin" "$BASH" "$MANIFEST" verify "$URL" --mode direct-PR 2>&1) \
    && fail "GitHub verification passed without GitHub prerequisites"
  assert_contains "$out" 'could not be read' "GitHub missing-tool refusal was lost"
  out=$(PATH="$dir/bin" "$BASH" "$MANIFEST" poll "$URL" 2>&1) \
    && fail "GitHub poll passed without GitHub prerequisites"
  assert_contains "$out" 'could not be read completely' "GitHub poll missing-tool refusal was lost"
  pass "GitLab skips GitHub prerequisites while GitHub reads still fail closed"
}

test_slow_paginated_read() {
  local dir head axis started
  for axis in reviews comments; do
    dir=$(make_case "slow-$axis")
    head=$(head_of "$dir")
    FM_TEST_GH_HEAD=$head
    body_state "$dir" "$head" "$(sections)"
    run_pr_check "$dir"
    [ "$CHECK_RC" -eq 0 ] || fail "slow-read seed refused: $CHECK_OUT"
    if [ "$axis" = reviews ]; then
      cp "$dir/reviews.json" "$dir/reviews.json.next"
      jq '.data.repository.pullRequest.reviews.pageInfo={hasNextPage:true,endCursor:"page2"}' \
        "$dir/reviews.json.next" > "$dir/reviews.json"
    else
      body_state "$dir" "$head" "$(sections)" '[]' \
        '[{"id":"PRRT_slow","isResolved":false,"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"more"},"nodes":[{"databaseId":999,"body":"<!-- fm-worker-note -->"}]}}]'
      printf '%s\n' '{"data":{"node":{"comments":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}' > "$dir/reviews.json.comments"
    fi
    touch "$dir/reviews.json.delay"
    started=$SECONDS
    run_watcher_cycle "$dir" 6
    [ "$((SECONDS - started))" -lt 6 ] || fail "paginated $axis read outlived its outer check deadline"
    assert_contains "$(cat "$dir/watch.out")" "review $URL unreadable" "slow $axis read timed out silently"
    assert_contains "$(cat "$dir/home/state/.wake-queue")" "review $URL unreadable" "slow $axis read did not produce a durable wake"
    [ "$(wc -l < "$dir/reviews.json.calls" | tr -d ' ')" -ge 2 ] || fail "slow $axis fixture never reached its second page"
  done
  pass "slow review and thread-comment pages share one deadline and wake before the outer timeout"
}

test_private_review_temp_files() {
  local dir head out rc
  dir=$(make_case private-review-files)
  head=$(head_of "$dir")
  body_state "$dir" "$head" "$(sections)"
  mkdir "$dir/private"
  for rc in 0 1; do
    if [ "$rc" -eq 1 ]; then printf '%s\n' '{"errors":[{"message":"unavailable"}]}' > "$dir/reviews.json"; fi
    out=$(umask 022; TMPDIR="$dir/private" FM_TEST_REVIEW_TEMP_CHECK="$dir/modes.jsonl" \
      FM_TEST_REVIEW_STATE="$dir/reviews.json" PATH="$dir/fakebin:$BASE_PATH" \
      "$MANIFEST" poll "$URL" 2>&1)
    [ "$?" -eq "$rc" ] || fail "unexpected private-file fixture result: $out"
    python3 - "$dir/modes.jsonl" "$dir/private" <<'CHECK' || fail "review files were public or leaked"
import json
import sys
from pathlib import Path
records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
assert records
assert all(r["output_mode"] == 0o600 and all(mode == 0o600 for mode in r["modes"]) for r in records)
assert not list(Path(sys.argv[2]).iterdir())
CHECK
  done
  pass "review temporary files stay private under umask 022 and are cleaned on success and failure"
}

test_paginated_thread_comments() {
  local dir head out
  dir=$(make_case paginated-comments)
  head=$(head_of "$dir")
  body_state "$dir" "$head" "$(sections)" '[]' \
    '[{"id":"PRRT_later","isResolved":false,"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"more"},"nodes":[{"databaseId":999,"body":"<!-- fm-worker-note -->"}]}}]'
  printf '%s\n' '{"data":{"node":{"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"databaseId":1000,"body":"human follow-up"}]}}}}' > "$dir/reviews.json.comments"
  out=$(FM_TEST_REVIEW_STATE="$dir/reviews.json" PATH="$dir/fakebin:$BASE_PATH" \
    "$MANIFEST" poll "$URL" 2>&1) || fail "paginated comments unreadable: $out"
  assert_contains "$out" 'PRRT_later' "human follow-up on page two skipped"
  pass "paginated thread comments preserve human follow-ups"
}

test_remote_custody_mode() {
  local dir head
  dir=$(make_case remote-custody)
  head=$(head_of "$dir")
  FM_TEST_GH_HEAD=$head
  printf 'kind=landing\ncustody_mode=no-mistakes\ncustody_evidence=complete\ncustody_blocked=none\npr=%s\n' "$URL" > "$dir/home/state/$ID.meta"
  body_state "$dir" "$head" "$(sections)"
  run_pr_merge "$dir"
  [ "$MERGE_RC" -ne 0 ] || fail "custody bypassed Pipeline"
  assert_contains "$MERGE_OUT" "no '## Pipeline' section" "custody mode not used"
  body_state "$dir" "$head" "$(sections)$(pipeline "$head")
## Review follow-up
| Review | Item | Disposition |
| --- | --- | --- |
| pullrequestreview-55 | item | fixed $head |" "$AUTHOR_REVIEW_REVIEWS" '[]'
  run_pr_merge "$dir"
  [ "$MERGE_RC" -eq 0 ] || fail "remote custody refused valid evidence: $MERGE_OUT"
  pass "remote custody enforces Pipeline and accepts forge-proved fixed commits"
}

test_poll_validates_dispositions
test_poll_evidence_deadline
test_reopened_thread_wakes_again
test_gitlab_without_github_tools
test_slow_paginated_read
test_private_review_temp_files
test_review_regressions
test_paginated_reviews
test_remote_custody_mode
test_paginated_thread_comments

test_commented_review_without_a_table_is_not_ready
test_fixed_sha_must_be_reachable_from_the_pr_head
test_well_formed_rows_are_ready_with_the_coverage_disclosure
test_review_id_in_prose_only_is_not_ready
test_unresolved_thread_needs_its_own_row
test_tool_generated_items_are_skipped_by_their_markers
test_inline_only_review_still_needs_a_row
test_no_reviews_requires_no_table
test_body_sections_are_required
test_pipeline_attestation_must_be_intact
test_merge_refuses_an_unanswered_review
test_pr_poll_reports_an_unanswered_review_once
