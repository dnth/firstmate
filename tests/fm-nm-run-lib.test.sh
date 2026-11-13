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
  printf '%s\n' 'resolved [key=nm-01TEST-review-detail]: answered: approve R2' >> "$tmp/status"
  decisions "$tmp/status" >/dev/null || fail "suffix-keyed firstmate decisions did not cover their events"
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "decision events match bare, -r<N>, and -detail firstmate records, one record each"
}

test_each_finding_and_round_needs_its_own_record() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  FM_TEST_ROUNDS_JSON='{"schema_version":1,"rounds":[{"round":30,"selection_source":"user_declined","response_origin":"interactive","findings":[{"id":"R1","action":"ask-user"},{"id":"R2","action":"ask-user"}]},{"round":31,"selection_source":"user_declined","response_origin":"interactive","findings":[{"id":"R1","action":"ask-user"}]}]}'
  write_status "$tmp/status" \
    'resolved [key=nm-01TEST-review-r30]: answered: approve R1 R2' \
    'resolved [key=nm-01TEST-review-r31]: answered: approve R1'
  decisions "$tmp/status" >/dev/null
  rc=$?
  expect_code 1 "$rc" "one round-30 record covered two findings"
  printf '%s\n' 'resolved [key=nm-01TEST-review-r31]: answered: approve R2' >> "$tmp/status"
  decisions "$tmp/status" >/dev/null
  rc=$?
  expect_code 1 "$rc" "a record for the wrong round covered R2"
  printf '%s\n' 'resolved [key=nm-01TEST-review-r30]: answered: approve R2' >> "$tmp/status"
  decisions "$tmp/status" >/dev/null || fail "distinct finding and round records did not pass"
  rm -rf "$tmp"
  FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
  pass "every finding and round requires a distinct matching decision record"
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

test_unreadable_or_originless_rounds_refuse_naming_what_is_missing() {
  local tmp out rc variant
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-rounds.XXXXXX")
  write_status "$tmp/status" 'resolved [key=nm-01TEST-review]: answered: approve R9'
  for variant in rounds-failed no-steps unparseable no-origin no-schema no-round; do
    FM_TEST_STATUS_RC=0
    FM_TEST_STATUS_DOC=$RUN_STATUS
    FM_TEST_ROUNDS_RC=0
    FM_TEST_ROUNDS_JSON=$ROUNDS_ONE_DECISION
    case "$variant" in
      rounds-failed) FM_TEST_ROUNDS_RC=1 ;;
      no-steps) FM_TEST_STATUS_DOC=$NO_STATUS_STEPS ;;
      unparseable) FM_TEST_ROUNDS_JSON='not json' ;;
      no-origin) FM_TEST_ROUNDS_JSON=${ROUNDS_ONE_DECISION/,\"response_origin\":\"interactive\"/} ;;
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
  pass "missing, unparseable, origin-less, and version-less rounds data refuses naming what is missing"
}

test_all_checks_passed_is_green
test_no_ci_checks_reported_is_no_checks_not_green
test_no_ci_declared_is_no_checks_despite_its_wording
test_zero_checks_after_green_wins
test_unregistered_checks_and_failures_are_not_ready
test_no_recognized_marker_is_unknown
test_decision_events_carry_step_round_finding_origin
test_suffixed_firstmate_keys_cover_their_events
test_each_finding_and_round_needs_its_own_record
test_large_rounds_document_is_read_without_environment_limits
test_unreadable_or_originless_rounds_refuse_naming_what_is_missing

echo "all fm-nm-run-lib tests passed"
