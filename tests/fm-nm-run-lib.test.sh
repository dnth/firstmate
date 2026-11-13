#!/usr/bin/env bash
# tests/fm-nm-run-lib.test.sh - the no-mistakes ci-monitor verdict reader
# (fm_nm_ci_checks_state in bin/fm-nm-run-lib.sh), the ONE owner both
# bin/fm-crew-state.sh and every other consumer delegate their green /
# no-checks / not-ready / unknown reading to.
#
# The load-bearing contract: a ci log whose last recognized marker reports no CI
# checks reads `no-checks`, never `green`. A pull request that no check ever ran
# against is unverified, and a repository that declares no_ci is in the same
# state even though its own sentence says "treating as all checks passed".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-nm-run-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

# The ci log the library would read back from `axi logs --step ci`; the real
# bounded read is replaced here so the verdict is exercised without a daemon.
FM_TEST_CI_LOG=
fm_nm_run() { printf '%s\n' "$FM_TEST_CI_LOG"; }

ci_state() {  # <ci-log>
  FM_TEST_CI_LOG=$1
  fm_nm_ci_checks_state "${TMPDIR:-/tmp}" 5 01RUN
}

NO_CI_SENTENCE="repository declares no CI (no_ci: true) - treating as all checks passed - still monitoring until merged or closed"

test_all_checks_passed_is_green() {
  local out
  out=$(ci_state "all CI checks passed - still monitoring until merged or closed")
  [ "$out" = green ] || fail "an all-checks-passed marker must read green, got '$out'"
  pass "fm_nm_ci_checks_state: an all-checks-passed marker reads green"
}

test_no_ci_checks_reported_is_no_checks_not_green() {
  local out
  out=$(ci_state "no CI checks reported - still monitoring until merged or closed")
  [ "$out" = no-checks ] \
    || fail "a zero-check marker must read no-checks, not '$out' (a PR nothing verified is not green)"
  pass "fm_nm_ci_checks_state: a zero-check marker reads no-checks, never green"
}

test_no_ci_declared_is_no_checks_despite_its_wording() {
  local out
  out=$(ci_state "$NO_CI_SENTENCE")
  [ "$out" = no-checks ] \
    || fail "a no_ci declaration must read no-checks even though it says checks passed, got '$out'"
  pass "fm_nm_ci_checks_state: a no_ci declaration reads no-checks, not green"
}

test_zero_checks_after_green_wins() {
  local out
  out=$(ci_state "all CI checks passed - still monitoring until merged or closed
no CI checks reported - still monitoring until merged or closed")
  [ "$out" = no-checks ] \
    || fail "the latest marker must win when a zero-check marker follows green, got '$out'"
  pass "fm_nm_ci_checks_state: the latest marker wins over an earlier green reading"
}

test_unregistered_checks_and_failures_are_not_ready() {
  local log out
  for log in \
    "no CI checks reported yet, waiting for checks to register..." \
    "CI checks running, waiting for results..." \
    "CI checks failed: build"; do
    out=$(ci_state "$log")
    [ "$out" = not-ready ] || fail "'$log' must read not-ready, got '$out'"
  done
  pass "fm_nm_ci_checks_state: pending and failing markers read not-ready"
}

test_no_recognized_marker_is_unknown() {
  local out
  out=$(ci_state "")
  [ "$out" = unknown ] || fail "an empty ci log must read unknown, got '$out'"
  out=$(ci_state "waiting for the pipeline to reach ci")
  [ "$out" = unknown ] || fail "an unrecognized log must read unknown, got '$out'"
  pass "fm_nm_ci_checks_state: an empty or unrecognized log reads unknown"
}

NO_STATUS_STEPS='run:
  id: "01TEST"
  status: completed
outcome: passed'

RUN_STATUS='run:
  id: "01TEST"
  status: completed
  steps[1]{step,status,findings,duration_ms}:
    review,completed,1,1
outcome: passed'

# The pipeline's own `axi rounds --json` document, shaped like a captured real
# one: versioned envelope and per-round findings, selections, source, origin.
ROUNDS_ONE_DECISION='{"schema_version":1,"run_id":"01TEST","step":"review","rounds":[{"round":7,"trigger":"initial","summary":null,"findings":[{"action":"","description":"changed behavior without a test","id":"R9","severity":"error"}],"selected_finding_ids":[],"selection_source":"user_declined","response_origin":"interactive","user_findings":null,"fix_summary":null,"duration_ms":10,"created_at":1}]}'
ROUNDS_TWO_DECISIONS='{"schema_version":1,"run_id":"01TEST","step":"review","rounds":[{"round":30,"trigger":"initial","summary":null,"findings":[{"action":"","description":"one","id":"R1","severity":"error"}],"selected_finding_ids":["R1"],"selection_source":"user","response_origin":"interactive","user_findings":null,"fix_summary":null,"duration_ms":10,"created_at":1},{"round":31,"trigger":"initial","summary":null,"findings":[{"action":"","description":"two","id":"R2","severity":"warning"}],"selected_finding_ids":[],"selection_source":"user_declined","response_origin":"auto_yes","user_findings":null,"fix_summary":null,"duration_ms":10,"created_at":1}]}'

# The decision audit's pipeline reads are replaced here so the audit is
# exercised without a daemon: FM_TEST_* drive the two bounded axi calls.
FM_TEST_STATUS_DOC=$RUN_STATUS
FM_TEST_STATUS_RC=0
FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
FM_TEST_ROUNDS_RC=0
fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  shift 2
  case "${2:-}" in
    status) [ "$FM_TEST_STATUS_RC" -eq 0 ] || return 1; printf '%s\n' "$FM_TEST_STATUS_DOC" ;;
    rounds) [ "$FM_TEST_ROUNDS_RC" -eq 0 ] || return 1; printf '%s\n' "$FM_TEST_ROUNDS_JSON" ;;
    *) return 1 ;;
  esac
}

decisions() {  # <status-file>
  fm_nm_ask_user_decisions "${TMPDIR:-/tmp}" 5 01TEST "$1"
}

write_status() {  # <path> [lines...]
  local f=$1
  shift
  printf '%s\n' "$@" > "$f"
}

test_decision_events_carry_step_round_finding_origin() {
  local tmp out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  out=$(fm_nm_ask_user_resolutions "${TMPDIR:-/tmp}" 5 01TEST)
  rc=$?
  expect_code 0 "$rc" "a recorded decision event could not be read"
  [ "$out" = $'review\tround 7\tR9\tdeclined\tinteractive' ] \
    || fail "a decision event did not carry its step, round, finding, action, and origin: '$out'"
  write_status "$tmp/status" 'resolved [key=nm-01TEST-review]: answered: approve R9'
  decisions "$tmp/status" >/dev/null || fail "a matching firstmate decision did not pass"
  rm -rf "$tmp"
  pass "decision events carry their step, round, finding, action, and answering origin"
}

test_suffixed_firstmate_keys_cover_their_events() {
  local tmp out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_ROUNDS_JSON=$ROUNDS_TWO_DECISIONS
  write_status "$tmp/status"
  out=$(decisions "$tmp/status")
  rc=$?
  expect_code 1 "$rc" "two recorded decision events passed with no firstmate record"
  assert_contains "$out" "run 01TEST step review" "refusal did not name the run and step"
  assert_contains "$out" "finding R1" "refusal did not name the first finding"
  assert_contains "$out" "finding R2" "refusal did not name the second finding"
  assert_contains "$out" "answered auto_yes" "refusal did not name who answered the gate"
  write_status "$tmp/status" 'resolved [key=nm-01TEST-review]: answered: fix R1'
  decisions "$tmp/status" >/dev/null && fail "one bare-key record covered two decision events"
  write_status "$tmp/status" \
    'resolved [key=nm-01TEST-review]: answered: fix R1' \
    'resolved [key=nm-01TEST-review-r30]: answered: fix R1'
  out=$(decisions "$tmp/status")
  rc=$?
  expect_code 1 "$rc" "overlapping R1 records covered the worker decision for R2"
  assert_contains "$out" "finding R2" "overlap refusal did not name the unmatched finding"
  printf '%s\n' \
    'needs-decision [key=nm-01TEST-review-detail]: next gate' \
    'resolved [key=nm-01TEST-review-detail]: answered: approve R2' >> "$tmp/status"
  decisions "$tmp/status" >/dev/null || fail "suffix-keyed firstmate decisions did not cover their events"
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "decision events match bare, -r<N>, and -detail firstmate records, one record each"
}

test_grouped_findings_share_one_gate_response_record() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_ROUNDS_JSON='{"schema_version":1,"rounds":[{"round":30,"selection_source":"user_declined","response_origin":"interactive","findings":[{"id":"R1","action":"ask-user"},{"id":"R2","action":"ask-user"}]},{"round":31,"selection_source":"user_declined","response_origin":"interactive","findings":[{"id":"R1","action":"ask-user"}]}]}'
  write_status "$tmp/status" \
    'resolved [key=nm-01TEST-review-r30]: answered: approve R1 R2' \
    'resolved [key=nm-01TEST-review-r31]: answered: approve R1'
  decisions "$tmp/status" >/dev/null || fail "one grouped firstmate approval did not cover its gate response"
  write_status "$tmp/status" \
    'resolved [key=nm-01TEST-review-r30]: answered: a bounded answer excerpt [truncated]' \
    'resolved [key=nm-01TEST-review-r31]: answered: another bounded excerpt [truncated]'
  decisions "$tmp/status" >/dev/null || fail "truncated finding IDs invalidated firstmate authority"
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "one answer covers grouped findings without requiring IDs in bounded excerpts"
}

test_surplus_records_stay_bound_when_finding_ids_repeat() {
  local tmp out rc key
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_ROUNDS_JSON=${ROUNDS_TWO_DECISIONS/\"id\":\"R2\"/\"id\":\"R1\"}
  for key in review review-detail; do
    write_status "$tmp/status" \
      "resolved [key=nm-01TEST-$key]: answered: fix R1" \
      'resolved [key=nm-01TEST-review-r30]: answered: fix R1' \
      "resolved [key=nm-01TEST-$key]: answered: fix R1"
    out=$(decisions "$tmp/status")
    rc=$?
    expect_code 1 "$rc" "surplus $key records migrated to a later repeated finding"
    assert_contains "$out" 'round 31' "refusal did not name the unmatched gate occurrence"
    assert_contains "$out" 'finding R1' "refusal did not name the repeated finding"
    printf '%s\n' 'resolved [key=nm-01TEST-review-r32]: answered: approve' >> "$tmp/status"
    decisions "$tmp/status" >/dev/null && fail "a wrong-round answer covered round 31"
    printf '%s\n' 'resolved [key=nm-01TEST-review-r31]: answered: approve' >> "$tmp/status"
    decisions "$tmp/status" >/dev/null || fail "a recovery append bound to round 31 was refused"
  done
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "bare and detail surplus records cannot authorize a repeated finding in a later round"
}

test_reopened_keys_bind_new_gate_occurrences() {
  local tmp opening
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_ROUNDS_JSON=$ROUNDS_TWO_DECISIONS
  for opening in \
    'needs-decision [key=nm-01TEST-review]: next gate' \
    'blocked: [key=nm-01TEST-review] next gate' \
    'needs-decision [corr=test] [key=nm-01TEST-review]: next gate'; do
    write_status "$tmp/status" \
      'resolved [key=nm-01TEST-review]: answered: first answer' \
      "$opening" "$opening" \
      'resolved [key=nm-01TEST-review]: answered: second answer'
    decisions "$tmp/status" >/dev/null || fail "a reopened bare key did not authorize its next gate response"
  done
  write_status "$tmp/status" \
    'resolved [key=nm-01TEST-review]: answered: first answer' \
    'needs-decision [key=nm-01TEST-review-r31]: next gate' \
    'resolved [key=nm-01TEST-review-detail]: answered: second answer'
  decisions "$tmp/status" >/dev/null || fail "a detail answer did not bind to the explicitly opened round"
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "reopened bare keys and detail aliases bind to their gate occurrence"
}

test_recovery_answers_do_not_move_implicit_gate_binding() {
  local tmp first last suffix
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_ROUNDS_JSON=$ROUNDS_TWO_DECISIONS
  for suffix in '' '-detail'; do
    for first in 30 31; do
      if [ "$first" = 31 ]; then last=30; else last=31; fi
      if [ "$first" = 31 ]; then
        write_status "$tmp/status" \
          'resolved [key=nm-01TEST-review-r31]: answered: approve' \
          "resolved [key=nm-01TEST-review$suffix]: answered: fix"
      else
        write_status "$tmp/status" \
          "resolved [key=nm-01TEST-review$suffix]: answered: fix" \
          'resolved [key=nm-01TEST-review-r31]: answered: approve'
      fi
      decisions "$tmp/status" >/dev/null || fail "round $first then round $last recovery answers did not cover both gates ($suffix)"
    done
  done
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "round and bare or detail recovery answers authorize both gates in either append order"
}

test_large_rounds_document_is_read_without_environment_limits() {
  local tmp round
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_ROUNDS_JSON=$(python3 -c '
import json
print(json.dumps({"schema_version": 1, "rounds": [
    {"round": n, "summary": "x" * 6000, "selection_source": "user_declined",
     "response_origin": "interactive", "findings": [{"id": "R9", "action": "ask-user"}]}
    for n in range(1, 31)]}))')
  write_status "$tmp/status"
  for round in {1..30}; do
    printf 'resolved [key=nm-01TEST-review-r%s]: answered: approve R9\n' "$round" >> "$tmp/status"
  done
  decisions "$tmp/status" >/dev/null || fail "valid rounds evidence over 128 KiB did not pass"
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "rounds documents over 128 KiB retain all matching decisions"
}

test_unreadable_or_unrecognized_rounds_refuse_naming_what_is_missing() {
  local tmp out rc variant
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  write_status "$tmp/status" 'resolved [key=nm-01TEST-review]: answered: approve R9'
  for variant in rounds-failed no-steps unparseable bad-origin no-schema no-round; do
    FM_TEST_STATUS_RC=0
    FM_TEST_STATUS_DOC=$RUN_STATUS
    FM_TEST_ROUNDS_RC=0
    FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
    case "$variant" in
      rounds-failed) FM_TEST_ROUNDS_RC=1 ;;
      no-steps) FM_TEST_STATUS_DOC=$NO_STATUS_STEPS ;;
      unparseable) FM_TEST_ROUNDS_JSON='not json' ;;
      bad-origin) FM_TEST_ROUNDS_JSON=${ROUNDS_ONE_DECISION/\"response_origin\":\"interactive\"/\"response_origin\":\"mystery\"} ;;
      no-schema) FM_TEST_ROUNDS_JSON='{"rounds":[]}' ;;
      no-round) FM_TEST_ROUNDS_JSON=${ROUNDS_ONE_DECISION/\"round\":7/\"round\":null} ;;
    esac
    out=$(decisions "$tmp/status")
    rc=$?
    expect_code 2 "$rc" "$variant decision data was read as a decision verdict"
    assert_contains "$out" "01TEST" "$variant refusal did not name the run"
  done
  assert_contains "$out" "round" "a missing decision round was not named"
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "missing, unparseable, unrecognized-origin, and version-less rounds data refuses naming what is missing"
}

# A test-step run document and the two real shapes PR 305's successor must
# accept: the KCC single approve round, and the Aceh auto_fix re-raise that
# repeats a finding an interactive round already declined. no-mistakes v1.106.1
# records `response_origin: unknown` on the round for approve/skip/abort
# responses (its executor writes the origin on the step result instead), so
# these rounds are "origin unproven", never a refusal by themselves.
TEST_STEP_STATUS='run:
  id: "01TEST"
  status: completed
  steps[1]{step,status,findings,duration_ms}:
    test,completed,1,1
outcome: passed'

ROUNDS_KCC_UNKNOWN='{"schema_version":1,"run_id":"01TEST","step":"test","rounds":[{"round":1,"trigger":"initial","selection_source":"user_declined","response_origin":"unknown","selected_finding_ids":[],"findings":[{"id":"test-1","action":"ask-user"}],"user_findings":null}]}'
ROUNDS_ACEH_UNKNOWN='{"schema_version":1,"run_id":"01TEST","step":"review","rounds":[{"round":1,"trigger":"initial","selection_source":"user_declined","response_origin":"interactive","selected_finding_ids":[],"findings":[{"id":"R1","description":"documentation finding","severity":"error","action":"ask-user"}],"user_findings":null},{"round":2,"trigger":"auto_fix","selection_source":"user_declined","response_origin":"unknown","selected_finding_ids":[],"findings":[{"id":"R1","description":"documentation finding","severity":"error","action":"ask-user"}],"user_findings":null}]}'
ROUNDS_UNKNOWN_FIX='{"schema_version":1,"rounds":[{"round":1,"selection_source":"user","response_origin":"unknown","selected_finding_ids":["test-1"],"findings":[{"id":"test-1","action":"ask-user"}]}]}'
ROUNDS_PARTIAL_FIX='{"schema_version":1,"rounds":[{"round":1,"selection_source":"user","response_origin":"unknown","selected_finding_ids":["test-1"],"findings":[{"id":"test-1","action":"ask-user"},{"id":"test-2","action":"ask-user"}]}]}'

test_unknown_origin_rounds_need_a_matching_firstmate_decision() {
  local tmp out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_STATUS_DOC=$TEST_STEP_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_KCC_UNKNOWN
  write_status "$tmp/status"
  out=$(decisions "$tmp/status")
  rc=$?
  expect_code 1 "$rc" "an origin-unproven decision passed with no firstmate record"
  assert_contains "$out" "run 01TEST" "refusal did not name the run"
  assert_contains "$out" "step test" "refusal did not name the step"
  assert_contains "$out" "round 1" "refusal did not name the round"
  assert_contains "$out" "finding test-1" "refusal did not name the finding"
  write_status "$tmp/status" \
    'resolved [key=nm-01TEST-test]: answered: Firstmate decision for run 01TEST test: APPROVE test-1'
  decisions "$tmp/status" >/dev/null \
    || fail "an origin-unproven approve covered by a firstmate decision was refused"
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "an origin-unproven decision passes only with a matching firstmate decision record"
}

test_repeated_unknown_round_carries_forward_a_decided_finding() {
  local tmp out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_ROUNDS_JSON=$ROUNDS_ACEH_UNKNOWN
  write_status "$tmp/status"
  out=$(decisions "$tmp/status")
  rc=$?
  expect_code 1 "$rc" "the re-raised round passed without any firstmate decision"
  assert_contains "$out" "round 2" "the first refusal did not name the re-raised round"
  write_status "$tmp/status" \
    'resolved [key=nm-01TEST-review]: answered: Firstmate decision for run 01TEST review: IGNORE R1'
  decisions "$tmp/status" >/dev/null \
    || fail "the round-1 decision did not cover the re-raised round-2 finding"
  write_status "$tmp/status" \
    'resolved [key=nm-01TEST-review-r2]: answered: FIX R1'
  out=$(decisions "$tmp/status")
  rc=$?
  expect_code 1 "$rc" "a round-2 record that contradicts the recorded decline was accepted"
  assert_contains "$out" "finding R1" "mismatch refusal did not name the finding"
  assert_contains "$out" "firstmate decided fix" "mismatch refusal did not name the decided action"
  assert_contains "$out" "recorded declined" "mismatch refusal did not name the recorded action"
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "a re-raised finding is covered by its earlier firstmate decision, and only while the action agrees"
}

test_unknown_origin_mismatch_refuses_naming_both_actions() {
  local tmp out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_STATUS_DOC=$TEST_STEP_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_KCC_UNKNOWN
  write_status "$tmp/status" 'resolved [key=nm-01TEST-test]: answered: FIX test-1'
  out=$(decisions "$tmp/status")
  rc=$?
  expect_code 1 "$rc" "a firstmate FIX decision covered a recorded decline"
  assert_contains "$out" "finding test-1" "fix/decline refusal did not name the finding"
  assert_contains "$out" "firstmate decided fix" "fix/decline refusal did not name the decided action"
  assert_contains "$out" "recorded declined" "fix/decline refusal did not name the recorded action"
  FM_TEST_ROUNDS_JSON=$ROUNDS_UNKNOWN_FIX
  write_status "$tmp/status" 'resolved [key=nm-01TEST-test]: answered: IGNORE test-1'
  out=$(decisions "$tmp/status")
  rc=$?
  expect_code 1 "$rc" "a firstmate IGNORE decision covered a recorded fix"
  assert_contains "$out" "finding test-1" "decline/fix refusal did not name the finding"
  assert_contains "$out" "firstmate decided decline" "decline/fix refusal did not name the decided action"
  assert_contains "$out" "recorded fix" "decline/fix refusal did not name the recorded action"
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "an origin-unproven action that contradicts firstmate's decision refuses naming both actions"
}

test_partial_fix_implicit_skip_is_not_a_mismatch() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_STATUS_DOC=$TEST_STEP_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_PARTIAL_FIX
  write_status "$tmp/status" 'resolved [key=nm-01TEST-test]: answered: FIX test-1'
  decisions "$tmp/status" >/dev/null \
    || fail "a partial fix's implicit decline of an unnamed finding contradicted its firstmate decision"
  write_status "$tmp/status" 'resolved [key=nm-01TEST-test]: answered: IGNORE test-1'
  decisions "$tmp/status" >/dev/null && fail "a declined firstmate finding covered a recorded fix"
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "a partial fix's implicit decline agrees with firstmate while a named mismatch still refuses"
}

test_finding_clauses_bind_their_own_actions() {
  local tmp answer out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_STATUS_DOC=$TEST_STEP_STATUS
  FM_TEST_ROUNDS_JSON='{"schema_version":1,"rounds":[{"round":1,"selection_source":"user_declined","response_origin":"unknown","findings":[{"id":"R1","action":"ask-user"},{"id":"R2","action":"ask-user"}]}]}'
  for answer in 'IGNORE R1; FIX R2' 'IGNORE R1, FIX R2' 'IGNORE R1 and FIX R2'; do
    write_status "$tmp/status" "resolved [key=nm-01TEST-test]: answered: $answer"
    out=$(decisions "$tmp/status")
    rc=$?
    expect_code 1 "$rc" "finding R2 inherited the preceding finding's decline: $answer"
    assert_contains "$out" 'finding R2' "clause mismatch did not name R2"
    assert_contains "$out" 'firstmate decided fix' "clause mismatch lost R2's FIX"
    assert_contains "$out" 'recorded declined' "clause mismatch lost the recorded decline"
  done
  FM_TEST_ROUNDS_JSON='{"schema_version":1,"rounds":[{"round":1,"selection_source":"user","response_origin":"unknown","selected_finding_ids":["R2"],"findings":[{"id":"R1","action":"ask-user"},{"id":"R2","action":"ask-user"}]}]}'
  for answer in 'IGNORE R1; FIX R2' 'IGNORE R1, FIX R2' 'IGNORE R1 and FIX R2'; do
    write_status "$tmp/status" "resolved [key=nm-01TEST-test]: answered: $answer"
    decisions "$tmp/status" >/dev/null || fail "an agreeing mixed decision was refused: $answer"
  done
  for answer in 'R1: IGNORE; R2: FIX' 'R1: IGNORE R2: FIX' 'IGNORE R1 FIX R2' 'IGNORE R1; FIX R1' 'IGNORE; FIX R2 (if approved)'; do
    write_status "$tmp/status" "resolved [key=nm-01TEST-test]: answered: $answer"
    out=$(decisions "$tmp/status")
    rc=$?
    expect_code 1 "$rc" "an ambiguous finding action was guessed: $answer"
    assert_contains "$out" 'no readable action' "ambiguous decision was not reported as unverifiable"
  done
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "finding clauses bind their own actions and ambiguous bindings refuse"
}

test_partial_fix_carries_effective_declines() {
  local tmp origin out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_STATUS_DOC=$TEST_STEP_STATUS
  for origin in unknown interactive; do
    FM_TEST_ROUNDS_JSON="{\"schema_version\":1,\"rounds\":[{\"round\":1,\"selection_source\":\"user\",\"response_origin\":\"$origin\",\"selected_finding_ids\":[\"test-1\"],\"findings\":[{\"id\":\"test-1\",\"description\":\"finding test-1\",\"severity\":\"error\",\"action\":\"ask-user\"},{\"id\":\"test-2\",\"description\":\"finding test-2\",\"severity\":\"error\",\"action\":\"ask-user\"}]},{\"round\":2,\"selection_source\":\"user_declined\",\"response_origin\":\"unknown\",\"findings\":[{\"id\":\"test-2\",\"description\":\"finding test-2\",\"severity\":\"error\",\"action\":\"ask-user\"}]}]}"
    write_status "$tmp/status" 'resolved [key=nm-01TEST-test]: answered: FIX test-1'
    decisions "$tmp/status" >/dev/null || fail "a partial fix's implicit decline was lost after an $origin round"
    FM_TEST_ROUNDS_JSON=${FM_TEST_ROUNDS_JSON/\"selection_source\":\"user_declined\"/\"selection_source\":\"user\",\"selected_finding_ids\":[\"test-2\"]}
    out=$(decisions "$tmp/status")
    rc=$?
    expect_code 1 "$rc" "an implicitly declined finding covered a later fix after an $origin round"
    assert_contains "$out" 'finding test-2 (round 2)' "carried mismatch did not name the repeated finding"
    assert_contains "$out" 'firstmate decided decline' "carried implicit skip was not a decline"
  done
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "partial fixes carry implicit declines and refuse contradictory later fixes"
}

test_review_carries_explicit_unselected_decisions() {
  local tmp origin field presentation scenario answer source selection expected out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_STATUS_DOC=$RUN_STATUS
  for origin in unknown interactive auto_yes; do
    for field in findings user_findings; do
      if [ "$field" = findings ]; then
        presentation='"findings":[{"id":"R1","description":"finding R1","severity":"error","action":"ask-user"},{"id":"R2","description":"finding R2","severity":"error","action":"ask-user"}]'
      else
        presentation='"findings":[{"id":"R1","description":"finding R1","severity":"error","action":"ask-user"}],"user_findings":[{"id":"R2","description":"finding R2","severity":"error","action":"ask-user"}]'
      fi
      for scenario in decline skip fix mismatch-decline mismatch-fix ambiguous unnamed absent; do
        source=user_declined
        selection='[]'
        expected=0
        case "$scenario" in
          decline) answer='FIX R1; IGNORE R2' ;;
          skip) answer='FIX R1; IGNORE R2'; source=user ;;
          fix) answer='FIX R1; FIX R2'; source=user; selection='["R2"]' ;;
          mismatch-decline) answer='FIX R1; FIX R2'; expected=1 ;;
          mismatch-fix) answer='FIX R1; IGNORE R2'; source=user; selection='["R2"]'; expected=1 ;;
          ambiguous) answer='FIX R1; IGNORE R2; FIX R2'; expected=1 ;;
          unnamed) answer='FIX R1' ;;
          absent) answer=''; expected=1 ;;
        esac
        FM_TEST_ROUNDS_JSON=$(cat <<EOF
{"schema_version":1,"rounds":[{"round":1,"selection_source":"user","response_origin":"$origin","selected_finding_ids":["R1"],$presentation},{"round":2,"selection_source":"$source","response_origin":"unknown","selected_finding_ids":$selection,"findings":[{"id":"R2","description":"finding R2","severity":"error","action":"ask-user"}]}]}
EOF
)
        write_status "$tmp/status"
        if [ -n "$answer" ]; then
          write_status "$tmp/status" "resolved [key=nm-01TEST-review]: answered: $answer"
        fi
        out=$(decisions "$tmp/status")
        rc=$?
        expect_code "$expected" "$rc" "unselected review decision: $origin/$field/$scenario: $out"
        if [ "$expected" -ne 0 ]; then
          assert_contains "$out" 'finding R2' "unselected review refusal did not name R2"
          assert_contains "$out" 'round 2' "unselected review refusal did not name round 2"
        fi
      done
    done
  done
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "review carries answer-derived unselected decisions and checks later actions"
}

test_carried_decisions_require_matching_finding_identity() {
  local tmp step origin field variant out rc expected
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  for step in review test; do
    FM_TEST_STATUS_DOC=${RUN_STATUS/review,completed/$step,completed}
    for origin in unknown interactive auto_yes; do
      for field in findings user_findings; do
        for variant in same description severity file line missing conflicting; do
          expected=1
          [ "$variant" != same ] || expected=0
          FM_TEST_ROUNDS_JSON=$(python3 - "$origin" "$field" "$variant" <<'FIXTURE'
import json
import sys
origin, field, variant = sys.argv[1:]
original = dict(id="R1", action="ask-user", description="documentation", severity="error", file="docs.md", line=1)
repeated = dict(original)
if variant in ("description", "severity", "file", "line"):
    repeated[variant] = dict(description="different issue", severity="warning", file="other.md", line=2)[variant]
elif variant == "missing":
    repeated.pop("description")
first = dict(round=1, selection_source="user_declined", response_origin=origin, **{field: [original]})
second = dict(round=2, selection_source="user_declined", response_origin="unknown", **{field: [repeated]})
if variant == "conflicting":
    second["user_findings" if field == "findings" else "findings"] = [dict(original, description="different issue")]
print(json.dumps(dict(schema_version=1, rounds=[first, second])))
FIXTURE
)
          write_status "$tmp/status" "resolved [key=nm-01TEST-$step]: answered: IGNORE R1"
          out=$(decisions "$tmp/status")
          rc=$?
          expect_code "$expected" "$rc" "carried identity: $step/$origin/$field/$variant: $out"
          if [ "$expected" -ne 0 ]; then
            assert_contains "$out" 'finding R1' "identity refusal did not name R1"
            assert_contains "$out" 'round 2' "identity refusal did not name round 2"
            printf '%s\n' "resolved [key=nm-01TEST-$step-r2]: answered: IGNORE R1" >> "$tmp/status"
            decisions "$tmp/status" >/dev/null || fail "a current-round record could not cover a changed identity"
          fi
        done
      done
    done
  done
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "carried authority requires the same finding identity; a new round record can cover a new identity"
}

test_action_mentions_do_not_authorize_decisions() {
  local tmp answer action out rc origin
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_STATUS_DOC=$TEST_STEP_STATUS
  # shellcheck disable=SC2016 # The backticked mention is fixture text.
  for answer in 'Do not FIX test-1; APPROVE the exception' 'Never IGNORE test-1' \
    'A command example: test-1: FIX' 'The previous answer was FIX test-1' 'Run no-mistakes axi respond --action fix test-1' \
    'If needed, FIX test-1' 'FIX test-1 is not what I want' 'FIX means changing code' 'Do not test-1: FIX' \
    '"FIX test-1"' '`FIX test-1`' "'FIX test-1'" \
    '"example; test-1: FIX; end"' 'Do not FIX; APPROVE' \
    'Do not (FIX test-1)' 'Never (IGNORE test-1)' \
    'If approved (test-1: FIX)' 'Do not; FIX test-1' \
    'FIX test-1; only after approval' '(FIX test-1)' \
    'FIX test-1; note that this requires approval' \
    'If FIX test-2; FIX test-1' 'FIX test-1; APPROVE only after confirmation' ; do
    for action in fix declined; do
      FM_TEST_ROUNDS_JSON=$(python3 - "$action" <<'FIXTURE'
import json
import sys
finding = dict(id="test-1", action="ask-user", description="documentation", severity="error")
rnd = dict(round=1, selection_source="user" if sys.argv[1] == "fix" else "user_declined", response_origin="unknown", selected_finding_ids=["test-1"] if sys.argv[1] == "fix" else [], findings=[finding])
print(json.dumps(dict(schema_version=1, rounds=[rnd])))
FIXTURE
)
      write_status "$tmp/status" "resolved [key=nm-01TEST-test]: answered: $answer"
      out=$(decisions "$tmp/status")
      rc=$?
      expect_code 1 "$rc" "an action mention authorized $action: $answer"
      assert_contains "$out" 'no readable action' "an action mention did not refuse as unverifiable"
      for origin in interactive auto_yes; do
        FM_TEST_ROUNDS_JSON=$(python3 - "$FM_TEST_ROUNDS_JSON" "$origin" <<'FIXTURE'
import copy
import json
import sys
doc = json.loads(sys.argv[1])
first = doc["rounds"][0]
second = copy.deepcopy(first)
first["response_origin"] = sys.argv[2]
second["round"] = 2
second["response_origin"] = "unknown"
doc["rounds"] = [first, second]
print(json.dumps(doc))
FIXTURE
)
        out=$(decisions "$tmp/status")
        rc=$?
        expect_code 1 "$rc" "an ambiguous $origin answer carried authority: $answer"
        assert_contains "$out" 'round 2' "carried action mention did not refuse round 2"
      done
    done
  done
  # The canonical contract ends the clause at the first '(' and ignores the
  # parenthetical as reason prose, so these are readable directives.
  for pair in 'FIX test-1 (only after approval)|user|["test-1"]|0' \
    'IGNORE test-1 (unless it is needed)|user_declined|[]|0' \
    'FIX test-1 (only after approval)|user_declined|[]|1'; do
    IFS='|' read -r answer source selection expected <<<"$pair"
    FM_TEST_ROUNDS_JSON=$(python3 - "$source" "$selection" <<'FIXTURE'
import json
import sys
finding = dict(id="test-1", action="ask-user", description="documentation", severity="error")
rnd = dict(round=1, selection_source=sys.argv[1], response_origin="unknown", selected_finding_ids=json.loads(sys.argv[2]), findings=[finding])
print(json.dumps(dict(schema_version=1, rounds=[rnd])))
FIXTURE
)
    write_status "$tmp/status" "resolved [key=nm-01TEST-test]: answered: $answer"
    out=$(decisions "$tmp/status")
    rc=$?
    expect_code "$expected" "$rc" "a parenthesised reason changed the directive: $answer"
  done
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "negated, quoted, conditional, and prose action mentions authorize neither current nor carried decisions"
}

test_unresolved_only_review_rounds_do_not_bind_answers() {
  local tmp layout origin field suffix last out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_STATUS_DOC=$RUN_STATUS
  for layout in first gap; do
    last=2
    [ "$layout" != gap ] || last=3
    for origin in interactive auto_yes unknown; do
      for field in findings user_findings; do
        FM_TEST_ROUNDS_JSON=$(python3 - "$layout" "$origin" "$field" <<'FIXTURE'
import json
import sys
layout, origin, field = sys.argv[1:]
finding = dict(id="R1", action="ask-user", description="unselected review finding", severity="error")
pending = dict(round=1, selection_source="user", response_origin=origin, selected_finding_ids=["A1"], **{field: [finding, dict(id="A1", action="auto-fix")]})
last = dict(round=2, selection_source="user_declined", response_origin=origin, findings=[finding])
rounds = [pending, last]
if layout == "gap":
    pending["round"], last["round"] = 2, 3
    rounds.insert(0, dict(round=1, selection_source="user_declined", response_origin=origin, findings=[dict(id="R0", action="ask-user")]))
print(json.dumps(dict(schema_version=1, rounds=rounds)))
FIXTURE
)
        write_status "$tmp/status"
        out=$(decisions "$tmp/status")
        rc=$?
        expect_code 1 "$rc" "unresolved context supplied authority without a record"
        assert_contains "$out" "round $last" "unanswered actual round was not named"
        for suffix in '' -detail "-r$last"; do
          write_status "$tmp/status"
          if [ "$layout" = gap ]; then
            write_status "$tmp/status" \
              'needs-decision [key=nm-01TEST-review]: first gate' \
              'resolved [key=nm-01TEST-review]: answered: IGNORE R0'
          fi
          printf '%s\n' \
            "needs-decision [key=nm-01TEST-review$suffix]: actual decision" \
            "resolved [key=nm-01TEST-review$suffix]: answered: IGNORE R1" >> "$tmp/status"
          out=$(decisions "$tmp/status")
          rc=$?
          expect_code 0 "$rc" "an unresolved-only round consumed an occurrence: $layout/$origin/$field/$suffix: $out"
        done
      done
    done
  done
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "unresolved-only review rounds consume no bare, detail, or explicit answer occurrence"
}

test_context_only_answers_update_carried_authority() {
  local tmp origin field answer later expected out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_STATUS_DOC=$RUN_STATUS
  for origin in interactive auto_yes unknown; do
    for field in findings user_findings; do
      for answer in 'FIX A1; IGNORE R1' 'unreadable answer'; do
        for later in fix declined; do
          FM_TEST_ROUNDS_JSON=$(python3 - "$origin" "$field" "$later" <<'FIXTURE'
import json
import sys
origin, field, later = sys.argv[1:]
finding = dict(id="R1", action="ask-user", description="same review finding", severity="error")
rounds = [
    dict(round=1, selection_source="user", response_origin="interactive", selected_finding_ids=["R1"], findings=[finding]),
    dict(round=2, selection_source="user", response_origin=origin, selected_finding_ids=["A1"], **{field: [finding, dict(id="A1", action="auto-fix")]}),
    dict(round=3, selection_source="user" if later == "fix" else "user_declined", response_origin="unknown", selected_finding_ids=["R1"] if later == "fix" else [], findings=[finding]),
]
print(json.dumps(dict(schema_version=1, rounds=rounds)))
FIXTURE
)
          write_status "$tmp/status" \
            'resolved [key=nm-01TEST-review]: answered: FIX R1' \
            'needs-decision [key=nm-01TEST-review-r2]: context-only gate' \
            "resolved [key=nm-01TEST-review-r2]: answered: $answer"
          expected=1
          if [ "$later" = declined ] && [ "$answer" != 'unreadable answer' ]; then
            expected=0
          fi
          out=$(decisions "$tmp/status")
          rc=$?
          expect_code "$expected" "$rc" "context-only answer did not supersede old authority: $origin/$field/$answer/$later: $out"
          if [ "$expected" -eq 1 ]; then
            assert_contains "$out" 'finding R1' 'superseded refusal omitted the finding'
            assert_contains "$out" 'round 3' 'superseded refusal omitted the round'
          fi
          write_status "$tmp/status" \
            'resolved [key=nm-01TEST-review]: answered: FIX R1' \
            'needs-decision [key=nm-01TEST-review-r2]: context-only gate' \
            'needs-decision [key=nm-01TEST-review]: actual gate' \
            "resolved [key=nm-01TEST-review]: answered: ${later/declined/DECLINE} R1"
          out=$(decisions "$tmp/status")
          rc=$?
          expect_code 0 "$rc" "context-only opening consumed a bare occurrence: $out"
          FM_TEST_ROUNDS_JSON=$(python3 - "$FM_TEST_ROUNDS_JSON" <<'FIXTURE'
import json
import sys
doc = json.loads(sys.argv[1])
doc["rounds"] = doc["rounds"][1:]
print(json.dumps(doc))
FIXTURE
)
          write_status "$tmp/status" "resolved [key=nm-01TEST-review-r2]: answered: $answer"
          out=$(decisions "$tmp/status")
          rc=$?
          expect_code "$expected" "$rc" "first context-only answer failed carry-forward: $origin/$field/$answer/$later: $out"
        done
      done
    done
  done
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "explicit context-only answers establish and supersede carried authority"
}

test_gatewide_prose_cannot_hide_unparsed_directives() {
  local tmp step verb answer origin expected out rc first
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  for step in review test; do
    FM_TEST_STATUS_DOC=${RUN_STATUS/review,completed/$step,completed}
    for verb in IGNORE APPROVE DECLINE SKIP; do
      for answer in "$verb R99; FIX R1" "$verb test-99, FIX R1" "$verb review-99" "$verb A1" "$verb proceeding; FIX" "$verb proceeding, FIX R1" "$verb proceeding FIX R1" "$verb proceeding without a fix" "$verb fix" "$verb proceeding; more context" "$verb R1 proceeding without a fix" "$verb R1 fix" "$verb R1 proceeding FIX R1" "$verb R1 proceeding FIX R99" "$verb R1 proceeding; FIX" "$verb proceeding without live validation for PR 305" "$verb documentation-only changes" "$verb unknown-label: FIX R1" "$verb proceeding; FIX R1" "$verb proceeding without live validation" "$verb without live validation, CONDITIONAL on approval"; do
        expected=1
        case "$answer" in
          "$verb proceeding without live validation"|"$verb without live validation, CONDITIONAL on approval"|"$verb proceeding without live validation for PR 305"|"$verb documentation-only changes"|"$verb proceeding without a fix"|"$verb fix"|"$verb proceeding; more context"|"$verb R1 proceeding without a fix"|"$verb R1 fix") expected=0 ;;
        esac
        first='{"round":1,"selection_source":"user_declined","response_origin":"unknown","findings":[{"id":"R1","action":"ask-user","description":"same finding"}]}'
        FM_TEST_ROUNDS_JSON="{\"schema_version\":1,\"rounds\":[$first]}"
        write_status "$tmp/status" "resolved [key=nm-01TEST-$step]: answered: $answer"
        out=$(decisions "$tmp/status")
        rc=$?
        expect_code "$expected" "$rc" "gate-wide fallback misread $answer: $out"
        for origin in interactive auto_yes; do
          FM_TEST_ROUNDS_JSON="{\"schema_version\":1,\"rounds\":[${first/unknown/$origin}]}"
          decisions "$tmp/status" >/dev/null || fail "unreadable prose changed record-only acceptance"
          FM_TEST_ROUNDS_JSON=$(python3 - "$FM_TEST_ROUNDS_JSON" <<'FIXTURE'
import json
import sys
doc = json.loads(sys.argv[1])
later = dict(doc["rounds"][0], round=2, response_origin="unknown")
doc["rounds"].append(later)
print(json.dumps(doc))
FIXTURE
)
          out=$(decisions "$tmp/status")
          rc=$?
          expect_code "$expected" "$rc" "gate-wide fallback carried invalid authority: $answer/$origin: $out"
        done
      done
    done
  done
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "gate-wide prose declines refuse unknown labels and additional directives"
}

test_covered_nonask_siblings_invalidate_carried_authority() {
  local tmp step field action layout prior origin expected out rc answer
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  for step in review test; do
    FM_TEST_STATUS_DOC=${RUN_STATUS/review,completed/$step,completed}
    for field in findings user_findings; do
      for action in auto-fix no-op; do
        for layout in mixed only; do
          for prior in FIX IGNORE; do
            for origin in interactive auto_yes unknown; do
              FM_TEST_ROUNDS_JSON=$(python3 - "$field" "$action" "$layout" "$prior" "$origin" <<'FIXTURE'
import json
import sys
field, action, layout, prior, origin = sys.argv[1:]
finding = dict(id="R1", action="ask-user", description="same finding", severity="error")
first = dict(round=1, selection_source="user" if prior == "FIX" else "user_declined", response_origin="interactive", selected_finding_ids=["R1"] if prior == "FIX" else [], findings=[finding])
siblings = [dict(finding, action=action)]
if layout == "mixed":
    siblings.append(dict(id="R2", action="ask-user", description="other finding", severity="error"))
second = dict(round=2, selection_source="user" if action == "auto-fix" else "user_declined", response_origin=origin, selected_finding_ids=[item["id"] for item in siblings] if action == "auto-fix" else [], **{field: siblings})
third = dict(first, round=3, response_origin="unknown")
print(json.dumps(dict(schema_version=1, rounds=[first, second, third])))
FIXTURE
)
              answer="IGNORE R1"
              [ "$action" != auto-fix ] || answer="FIX R1"
              [ "$layout" != mixed ] || answer+=" R2"
              write_status "$tmp/status" \
                "resolved [key=nm-01TEST-$step]: answered: $prior R1" \
                "resolved [key=nm-01TEST-$step-r2]: answered: $answer"
              out=$(decisions "$tmp/status")
              rc=$?
              expect_code 1 "$rc" "non-ask-user sibling retained authority: $step/$field/$action/$layout/$prior/$origin: $out"
              assert_contains "$out" 'finding R1 resolved as' 'stale-authority refusal omitted R1'
              assert_contains "$out" 'round 3' 'stale-authority refusal omitted round 3'
              write_status "$tmp/status" \
                "resolved [key=nm-01TEST-$step]: answered: $prior R1" \
                "needs-decision [key=nm-01TEST-$step]: next gate" \
                "resolved [key=nm-01TEST-$step]: answered: $prior R1"
              expected=0
              if [ "$layout" = mixed ]; then
                expected=1
              fi
              out=$(decisions "$tmp/status")
              rc=$?
              expect_code "$expected" "$rc" "non-ask-user-only round consumed an occurrence: $step/$field/$action/$layout/$prior/$origin: $out"
            done
          done
        done
      done
    done
  done
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "covered auto-fix and no-op siblings lose authority without consuming non-decision occurrences"
}

test_new_covered_answers_supersede_carried_authority() {
  local tmp step origin shape answer out rc initial
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  for step in review test; do
    FM_TEST_STATUS_DOC=${RUN_STATUS/review,completed/$step,completed}
    for origin in interactive auto_yes; do
      for shape in fix decline partial; do
        for answer in 'a bounded excerpt' 'FIX R1 (plain rationale)' 'Do not (FIX R1)'; do
          initial=$(python3 - "$origin" "$shape" <<'FIXTURE'
import json
import sys
origin, shape = sys.argv[1:]
finding = dict(id="R1", action="ask-user", description="same finding", severity="error")
first = dict(round=1, selection_source="user_declined", response_origin=origin, findings=[finding])
second = dict(round=2, selection_source="user", response_origin=origin, selected_finding_ids=["R1"], findings=[finding])
if shape == "decline":
    second["selection_source"] = "user_declined"
    second["selected_finding_ids"] = []
elif shape == "partial":
    second["selected_finding_ids"] = ["R2"]
    second["findings"].append(dict(id="R2", action="ask-user", description="sibling", severity="error"))
print(json.dumps(dict(schema_version=1, rounds=[first, second])))
FIXTURE
)
          write_status "$tmp/status" \
            "resolved [key=nm-01TEST-$step]: answered: IGNORE R1" \
            "resolved [key=nm-01TEST-$step-r2]: answered: $answer"
          FM_TEST_ROUNDS_JSON=$initial
          decisions "$tmp/status" >/dev/null || fail "an unreadable $origin answer changed record-only acceptance"
          FM_TEST_ROUNDS_JSON=$(python3 - "$initial" <<'FIXTURE'
import json
import sys
doc = json.loads(sys.argv[1])
doc["rounds"].append(dict(round=3, selection_source="user_declined", response_origin="unknown", findings=doc["rounds"][0]["findings"]))
print(json.dumps(doc))
FIXTURE
)
          out=$(decisions "$tmp/status")
          rc=$?
          expect_code 1 "$rc" "superseded authority survived: $step/$origin/$shape/$answer"
          assert_contains "$out" 'finding R1' "superseded refusal did not name R1"
          assert_contains "$out" 'round 3' "superseded refusal did not name round 3"
        done
      done
    done
  done
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "covered unreadable answers invalidate earlier authority for actual and unresolved sibling findings"
}

test_mixed_partial_fixes_preserve_implicit_declines() {
  local tmp origin scenario answer source selection field out rc expected
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_STATUS_DOC=$TEST_STEP_STATUS
  for origin in unknown interactive auto_yes; do
    for field in findings user_findings; do
      for scenario in skip decline repeated-skip fix absent parenthetical unreadable ambiguous unnamed; do
        answer='FIX R1; IGNORE R2'
        source=user_declined
        selection='[]'
        expected=0
        case "$scenario" in
          skip) ;;
          decline) ;;
          repeated-skip) source=user ;;
          fix) source=user; selection='["R3"]'; expected=1 ;;
          absent) expected=1 ;;
          parenthetical) answer='FIX R1 (if approved); IGNORE R2' ;;
          unreadable) answer='Option (a) applied'; expected=1 ;;
          ambiguous) answer='FIX R1; IGNORE R1; IGNORE R2'; expected=1 ;;
          unnamed) answer='FIX; IGNORE'; expected=1 ;;
        esac
        FM_TEST_ROUNDS_JSON=$(python3 - "$origin" "$field" "$scenario" "$source" "$selection" <<'FIXTURE'
import json
import sys
origin, field, scenario, source, selection = sys.argv[1:]
findings = [dict(id=f"R{i}", action="ask-user", description=f"finding {i}", severity="error") for i in range(1, 4)]
first = dict(round=1, selection_source="user", response_origin=origin, selected_finding_ids=["R1"], **{field: findings[:2] if scenario == "absent" else findings})
rounds = [first]
if scenario != "skip":
    rounds.append(dict(round=2, selection_source=source, response_origin="unknown", selected_finding_ids=json.loads(selection), findings=[findings[2]]))
print(json.dumps(dict(schema_version=1, rounds=rounds)))
FIXTURE
)
        write_status "$tmp/status" "resolved [key=nm-01TEST-test]: answered: $answer"
        out=$(decisions "$tmp/status")
        rc=$?
        expect_code "$expected" "$rc" "mixed partial fix: $origin/$field/$scenario: $out"
        if [ "$expected" -ne 0 ]; then
          assert_contains "$out" 'finding R3' "mixed partial-fix refusal did not name R3"
          if [ "$scenario" = fix ]; then
            assert_contains "$out" 'firstmate decided decline' "the implicit skip was not carried as a decline"
            assert_contains "$out" 'recorded fix' "the contradictory later fix was not named"
          fi
        fi
      done
    done
  done
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "readable mixed partial fixes preserve same-round implicit declines without authorizing absent or ambiguous findings"
}

test_mixed_finding_directives_use_full_round_context() {
  local tmp step origin field scenario answer expected out rc events_expected
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  for step in review test; do
    FM_TEST_STATUS_DOC=${RUN_STATUS/review,completed/$step,completed}
    for origin in unknown interactive auto_yes; do
      for field in findings user_findings; do
        for scenario in agreeing labeled mismatch auto-authority noop-authority unknown-id qualified parenthetical conflicting-auto conflicting-noop; do
          answer='FIX A1 R1; IGNORE N1 R2'
          expected=1
          case "$scenario" in
            agreeing) expected=0 ;;
            labeled) answer='A1: FIX; R1: FIX; N1: IGNORE; R2: IGNORE' ;;
            mismatch|auto-authority|noop-authority) ;;
            unknown-id) answer='FIX Z1 R1; IGNORE N1 R2' ;;
            qualified) answer='If approved, FIX A1 R1; IGNORE N1 R2' ;;
            parenthetical) answer='FIX A1 R1 (if approved); IGNORE N1 R2'; expected=0 ;;
            conflicting-auto) answer='FIX A1 R1; IGNORE A1; IGNORE N1 R2' ;;
            conflicting-noop) answer='FIX A1 R1; FIX N1; IGNORE N1 R2' ;;
          esac
          FM_TEST_ROUNDS_JSON=$(python3 - "$origin" "$field" "$scenario" <<'FIXTURE'
import json
import sys
origin, field, scenario = sys.argv[1:]
findings = [dict(id=fid, action=action, description=f"finding {fid}", severity="error") for fid, action in [("A1", "auto-fix"), ("N1", "no-op"), ("R1", "ask-user"), ("R2", "ask-user")]]
first = dict(round=1, selection_source="user", response_origin=origin, selected_finding_ids=["A1", "R1"], **{field: findings})
second = dict(round=2, selection_source="user_declined", response_origin="unknown", findings=[findings[3]])
if scenario == "mismatch":
    second.update(selection_source="user", selected_finding_ids=["R2"])
elif scenario in ("auto-authority", "noop-authority"):
    index = 0 if scenario == "auto-authority" else 1
    second["findings"] = [dict(findings[index], action="ask-user")]
    if scenario == "auto-authority":
        second.update(selection_source="user", selected_finding_ids=["A1"])
print(json.dumps(dict(schema_version=1, rounds=[first, second])))
FIXTURE
)
          write_status "$tmp/status" "resolved [key=nm-01TEST-$step]: answered: $answer"
          out=$(decisions "$tmp/status")
          rc=$?
          expect_code "$expected" "$rc" "mixed finding context: $step/$origin/$field/$scenario: $out"
          if [ "$scenario" = auto-authority ]; then
            assert_contains "$out" 'finding A1' "an auto-fix id acquired carried authority"
            assert_contains "$out" 'missing matching resolved' "an auto-fix id was treated as previously authorized"
          elif [ "$scenario" = noop-authority ]; then
            assert_contains "$out" 'finding N1' "a no-op id acquired carried authority"
            assert_contains "$out" 'missing matching resolved' "a no-op id was treated as previously authorized"
          elif [ "$scenario" = agreeing ]; then
            events_expected=$(printf '%s\tround 1\tR1\tfix\t%s\n' "$step" "$origin")
            if [ "$step" = test ]; then
              events_expected+=$(printf '\n%s\tround 1\tR2\tskip\t%s' "$step" "$origin")
            fi
            events_expected+=$(printf '\n%s\tround 2\tR2\tdeclined\tunknown' "$step")
            out=$(fm_nm_ask_user_resolutions "${TMPDIR:-/tmp}" 5 01TEST)
            [ "$out" = "$events_expected" ] || fail "non-ask-user siblings changed decision events: $out"
          fi
        done
      done
    done
  done
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "all round IDs parse mixed directives while only ask-user findings emit events and retain authority"
}

test_partial_fix_authority_is_independent_of_selection() {
  local tmp step field answer expected out rc first origin later
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  for step in review test; do
    FM_TEST_STATUS_DOC=${RUN_STATUS/review,completed/$step,completed}
    for field in findings user_findings; do
      for answer in 'FIX R1' 'R1: FIX' 'FIX A1' 'A1: FIX' 'IGNORE N1; FIX R1' 'FIX'; do
        expected=1
        first=$(python3 - "$field" <<'FIXTURE'
import json
import sys
findings = [dict(id=fid, action=action, description=f"finding {fid}", severity="error") for fid, action in [("A1", "auto-fix"), ("N1", "no-op"), ("R1", "ask-user"), ("R2", "ask-user")]]
rnd = dict(round=1, selection_source="user", response_origin="unknown", selected_finding_ids=["A1", "R1", "R2"], **{sys.argv[1]: findings})
print(json.dumps(dict(schema_version=1, rounds=[rnd])))
FIXTURE
)
        write_status "$tmp/status" "resolved [key=nm-01TEST-$step]: answered: $answer"
        FM_TEST_ROUNDS_JSON=$first
        out=$(decisions "$tmp/status")
        rc=$?
        expect_code "$expected" "$rc" "selection granted unnamed FIX authority: $step/$field/$answer: $out"
        if [ "$answer" = FIX ] || [[ "$answer" == *:* ]]; then
          assert_contains "$out" 'no readable action' "a bare FIX or label-first answer was read as a directive"
        elif [ "$expected" -ne 0 ]; then
          assert_contains "$out" 'finding R2' "over-selection refusal did not name R2"
          assert_contains "$out" 'firstmate decided decline' "unnamed R2 was not derived as a decline"
          assert_contains "$out" 'recorded fix' "over-selection refusal did not name the recorded fix"
        fi
        for origin in interactive auto_yes; do
          FM_TEST_ROUNDS_JSON=${first/unknown/$origin}
          decisions "$tmp/status" >/dev/null || fail "record-only acceptance changed for $origin"
          for later in fix declined; do
            FM_TEST_ROUNDS_JSON=$(python3 - "$first" "$origin" "$later" <<'FIXTURE'
import json
import sys
doc = json.loads(sys.argv[1])
doc["rounds"][0]["response_origin"] = sys.argv[2]
finding = dict(id="R2", action="ask-user", description="finding R2", severity="error")
doc["rounds"].append(dict(round=2, response_origin="unknown", selection_source="user" if sys.argv[3] == "fix" else "user_declined", selected_finding_ids=["R2"] if sys.argv[3] == "fix" else [], findings=[finding]))
print(json.dumps(doc))
FIXTURE
)
            expected=0
            if [ "$answer" = FIX ] || [[ "$answer" == *:* ]] || [ "$later" = fix ]; then
              expected=1
            fi
            out=$(decisions "$tmp/status")
            rc=$?
            expect_code "$expected" "$rc" "carried authority followed the selection: $step/$origin/$field/$answer/$later: $out"
            if [ "$expected" -ne 0 ] && [ "$answer" != FIX ] && [[ "$answer" != *:* ]]; then
              assert_contains "$out" 'finding R2 (round 2)' "carried mismatch did not name R2 and its round"
            fi
          done
        done
      done
    done
  done
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "named partial fixes decline unnamed findings independently of current and carried pipeline selections"
}


# AC8: the canonical records firstmate actually writes must parse from their
# verbatim first lines. Each case names the exact line and the disposition it
# must yield for the presented findings.
test_real_firstmate_record_lines_parse_canonically() {
  local tmp answer source selection expected out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  parse_case() {  # <label> <step> <answer> <source> <selected-json> <findings-json> <expect-rc>
    local label=$1 step=$2 answer=$3 src=$4 selected=$5 presented=$6 want=$7
    FM_TEST_STATUS_DOC=$(printf 'run:\n  id: "01TEST"\n  status: completed\n  steps[1]{step,status,findings,duration_ms}:\n    %s,completed,1,1\noutcome: passed' "$step")
    FM_TEST_ROUNDS_JSON=$(printf '{"schema_version":1,"rounds":[{"round":1,"trigger":"initial","selection_source":"%s","response_origin":"unknown","selected_finding_ids":%s,"findings":%s}]}' "$src" "$selected" "$presented")
    write_status "$tmp/status" "resolved [key=nm-01TEST-$step]: answered: $answer"
    out=$(decisions "$tmp/status")
    rc=$?
    expect_code "$want" "$rc" "AC8 $label: $out"
    [ "$want" -eq 0 ] || assert_contains "$out" 'origin-unproven decision disagrees' "AC8 $label refusal did not name the disagreement"
  }
  parse_case 'aceh IGNORE R1 with aside' review \
    'IGNORE R1 (keep the docstring change; respond --action fix with no findings selected)' \
    user_declined '[]' \
    '[{"id":"R1","action":"ask-user","description":"d1","severity":"error"},{"id":"R2","action":"ask-user","description":"d2","severity":"error"}]' 0
  parse_case 'aceh decline recorded as fix refuses' review \
    'IGNORE R1 (keep the docstring change; respond --action fix with no findings selected)' \
    user '["R1"]' '[{"id":"R1","action":"ask-user","description":"d1","severity":"error"}]' 1
  parse_case 'kcc APPROVE proceeding' test \
    'APPROVE proceeding without live validation. Reason: the PR is documentation only; the [truncated]' \
    user_declined '[]' '[{"id":"test-1","action":"ask-user","description":"d3","severity":"warning"}]' 0
  parse_case 'kcc APPROVE with recorded fix refuses' test \
    'APPROVE proceeding without live validation. Reason: the PR is documentation only; the [truncated]' \
    user '["test-1"]' '[{"id":"test-1","action":"ask-user","description":"d3","severity":"warning"}]' 1
  parse_case 'real test approval with named id and prose' test \
    'APPROVE test-1 without live validation. Reason: the acceptance signal is satisfied out of pipeline' \
    user_declined '[]' '[{"id":"test-1","action":"ask-user","description":"d3","severity":"warning"}]' 0
  parse_case 'named decline with prose action mention' test \
    'APPROVE test-1 proceeding without a fix' \
    user_declined '[]' '[{"id":"test-1","action":"ask-user","description":"d3","severity":"warning"}]' 0
  parse_case 'named decline with detached directive refuses' test \
    'APPROVE test-1 proceeding FIX test-1' \
    user_declined '[]' '[{"id":"test-1","action":"ask-user","description":"d3","severity":"warning"}]' 1
  parse_case 'named decline with semicolon directive refuses' test \
    'APPROVE test-1 proceeding; FIX' \
    user_declined '[]' '[{"id":"test-1","action":"ask-user","description":"d3","severity":"warning"}]' 1
  parse_case 'FIX with trailing prose stays unreadable' test \
    'FIX test-1 is not what I want' \
    user '["test-1"]' '[{"id":"test-1","action":"ask-user","description":"d3","severity":"warning"}]' 1
  parse_case 'FIX R3 with auto-fix sibling aside' test \
    'FIX R3 (with R1 and R2 as auto-fix). Reason: the parser contract' \
    user '["R3"]' \
    '[{"id":"R1","action":"ask-user","description":"d4","severity":"error"},{"id":"R2","action":"ask-user","description":"d5","severity":"error"},{"id":"R3","action":"ask-user","description":"d6","severity":"error"}]' 0
  parse_case 'FIX review-2 with auto-fix aside' review \
    'FIX review-2 (with review-3 as auto-fix). Reason: the parser contract' \
    user '["review-2"]' \
    '[{"id":"review-2","action":"ask-user","description":"d7","severity":"error"},{"id":"review-3","action":"auto-fix","description":"d8","severity":"warning"}]' 0
  parse_case 'FIX review-4 with reason' review \
    'FIX review-4. Reason: the parser contract' \
    user '["review-4"]' '[{"id":"review-4","action":"ask-user","description":"d9","severity":"error"}]' 0
  rm -rf "$tmp"
  FM_TEST_STATUS_DOC=$RUN_STATUS
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "verbatim firstmate record lines parse to their canonical dispositions"
}

test_all_checks_passed_is_green
test_no_ci_checks_reported_is_no_checks_not_green
test_no_ci_declared_is_no_checks_despite_its_wording
test_zero_checks_after_green_wins
test_unregistered_checks_and_failures_are_not_ready
test_no_recognized_marker_is_unknown
test_decision_events_carry_step_round_finding_origin
test_suffixed_firstmate_keys_cover_their_events
test_grouped_findings_share_one_gate_response_record
test_surplus_records_stay_bound_when_finding_ids_repeat
test_reopened_keys_bind_new_gate_occurrences
test_recovery_answers_do_not_move_implicit_gate_binding
test_large_rounds_document_is_read_without_environment_limits
test_unreadable_or_unrecognized_rounds_refuse_naming_what_is_missing
test_unknown_origin_rounds_need_a_matching_firstmate_decision
test_repeated_unknown_round_carries_forward_a_decided_finding
test_unknown_origin_mismatch_refuses_naming_both_actions
test_partial_fix_implicit_skip_is_not_a_mismatch
test_finding_clauses_bind_their_own_actions
test_partial_fix_carries_effective_declines
test_review_carries_explicit_unselected_decisions
test_carried_decisions_require_matching_finding_identity
test_action_mentions_do_not_authorize_decisions
test_unresolved_only_review_rounds_do_not_bind_answers
test_context_only_answers_update_carried_authority
test_gatewide_prose_cannot_hide_unparsed_directives
test_new_covered_answers_supersede_carried_authority
test_covered_nonask_siblings_invalidate_carried_authority
test_mixed_partial_fixes_preserve_implicit_declines
test_mixed_finding_directives_use_full_round_context
test_partial_fix_authority_is_independent_of_selection
test_real_firstmate_record_lines_parse_canonically

echo "all fm-nm-run-lib tests passed"
