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

test_all_checks_passed_is_green
test_no_ci_checks_reported_is_no_checks_not_green
test_no_ci_declared_is_no_checks_despite_its_wording
test_zero_checks_after_green_wins
test_unregistered_checks_and_failures_are_not_ready
test_no_recognized_marker_is_unknown

echo "all fm-nm-run-lib tests passed"
