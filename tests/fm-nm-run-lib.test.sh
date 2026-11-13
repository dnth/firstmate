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
ROUNDS_ACEH_UNKNOWN='{"schema_version":1,"run_id":"01TEST","step":"review","rounds":[{"round":1,"trigger":"initial","selection_source":"user_declined","response_origin":"interactive","selected_finding_ids":[],"findings":[{"id":"R1","action":"ask-user"}],"user_findings":null},{"round":2,"trigger":"auto_fix","selection_source":"user_declined","response_origin":"unknown","selected_finding_ids":[],"findings":[{"id":"R1","action":"ask-user"}],"user_findings":null}]}'
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
    'resolved [key=nm-01TEST-test]: answered: Firstmate decision for run 01TEST test-1: APPROVE proceeding without live validation'
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
    'resolved [key=nm-01TEST-review]: answered: Firstmate decision for run 01TEST review: IGNORE R1 (keep the docstring change; respond --action fix with no findings selected)'
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

echo "all fm-nm-run-lib tests passed"
