#!/usr/bin/env bash
# Behavior tests for the PR-ready handoff gates in bin/fm-pr-check.sh: complete
# acceptance evidence for every ship mode, No-Mistakes run identity proven from
# the pipeline's own status, and the ask-user decision audit at PR-ready.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
RECEIPT="$ROOT/bin/fm-receipt.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-handoff)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
fm_git_identity fmtest fmtest@example.invalid
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
NM_CALL_LOG="$TMP_ROOT/no-mistakes-calls.log"
: > "$NM_CALL_LOG"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*) [ -z "${FM_FAKE_GH_HEAD:-}" ] || printf '%s\n' "$FM_FAKE_GH_HEAD" ;;
esac
SH
cat > "$FAKEBIN/no-mistakes" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$NM_CALL_LOG"
[ "\${FM_FAKE_NM_DOWN:-0}" = 0 ] || exit 1
case "\$*" in
  *"axi logs --step ci"*) printf '%s\n' "\${FM_FAKE_NM_CI_LOG:-}" ;;
  *) printf '%s\n' "\${FM_FAKE_NM_STATUS:-}" ;;
esac
EOF
chmod +x "$FAKEBIN/gh" "$FAKEBIN/no-mistakes"
export FM_NO_MISTAKES_BIN="$FAKEBIN/no-mistakes"
export FM_GUARD_READ_ONLY=1

# The no-mistakes daemon state database is read-only evidence for the
# ask-user decision audit; the suite gets an isolated fixture copy.
NM_DIR="$TMP_ROOT/nm-home"
mkdir -p "$NM_DIR"
python3 - "$NM_DIR" <<'PY'
import os, sqlite3, sys
db = sqlite3.connect(os.path.join(sys.argv[1], "state.sqlite"))
db.executescript("""
CREATE TABLE runs (id TEXT PRIMARY KEY);
CREATE TABLE step_results (
  id TEXT PRIMARY KEY, run_id TEXT, step_name TEXT, step_order INTEGER, status TEXT,
  findings_json TEXT, approval_reason TEXT, override_reason TEXT, skip_reason TEXT
);
CREATE TABLE step_rounds (
  id TEXT PRIMARY KEY, step_result_id TEXT, round INTEGER, selection_source TEXT,
  selected_finding_ids TEXT, findings_json TEXT, user_findings_json TEXT
);
""")
db.commit()
PY
export NM_HOME="$NM_DIR"

nm_db() {  # <sql>
  python3 - "$NM_DIR" "$1" <<'PY'
import os, sqlite3, sys
db = sqlite3.connect(os.path.join(sys.argv[1], "state.sqlite"))
db.executescript(sys.argv[2])
db.commit()
PY
}

HEAD_A=0123456789abcdef0123456789abcdef01234567
HEAD_B=89abcdef0123456789abcdef0123456789abcdef

nm_status() {  # <run-id> <branch> <head_sha> <status> [outcome] [pr]
  printf 'run:\n  id: "%s"\n  branch: %s\n  status: %s\n  head: %s\n  head_sha: %s\n' "$1" "$2" "$4" "${3:0:8}" "$3"
  [ -z "${6:-}" ] || printf '  pr: "%s"\n' "$6"
  [ -z "${5:-}" ] || printf 'outcome: %s\n' "$5"
}

make_task() {  # <id> <mode> -> worktree on fm/<id>
  local id=$1 mode=$2 repo wt
  repo="$TMP_ROOT/repo-$id"
  wt="$TMP_ROOT/wt-$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
Fixture.

# Acceptance criteria
- AC1: The behavior works.
- AC2: Verification is green.

# Definition of done
Delivery contract: mode=$mode
EOF
  : > "$HOME_DIR/data/$id/evidence.jsonl"
  : > "$HOME_DIR/data/$id/.evidence.lock"
  fm_write_meta "$HOME_DIR/state/$id.meta" "window=fm-$id" "endpoint_task_id=$id" \
    "worktree=$wt" "project=$repo" "kind=ship" "mode=$mode"
  : > "$HOME_DIR/state/$id.status"
  printf '%s\n' "$wt"
}

receipt() {  # <id> <criterion> [outcome]
  FM_HOME="$HOME_DIR" "$RECEIPT" "$1" "$2" test "evidence for $2" passed --outcome "${3:-success}" >/dev/null \
    || fail "fixture receipt failed for $1/$2"
}

run_pr_check() {  # <id> <url>
  PR_OUT=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$PR_CHECK" "$1" "$2" 2>&1)
  PR_RC=$?
}

assert_not_armed() {  # <id> <label>
  [ ! -e "$HOME_DIR/state/$1.check.sh" ] || fail "$2: watcher was armed"
  ! grep -q '^pr=' "$HOME_DIR/state/$1.meta" || fail "$2: pr= was recorded"
  ! grep -q '^nm_run_id=' "$HOME_DIR/state/$1.meta" || fail "$2: nm_run_id= was recorded"
}

test_direct_pr_handoff_requires_complete_evidence() {
  local id=direct url=https://github.com/o/r/pull/11
  make_task "$id" direct-PR >/dev/null
  receipt "$id" AC1
  FM_FAKE_GH_HEAD=$HEAD_A run_pr_check "$id" "$url"
  expect_code 1 "$PR_RC" "direct-PR registration accepted missing evidence"
  assert_contains "$PR_OUT" "missing evidence: AC2" "refusal did not name the missing criterion"
  assert_not_armed "$id" "missing-evidence direct-PR"
  receipt "$id" AC2 failure
  FM_FAKE_GH_HEAD=$HEAD_A run_pr_check "$id" "$url"
  expect_code 1 "$PR_RC" "direct-PR registration accepted a failed criterion"
  receipt "$id" AC2
  FM_FAKE_GH_HEAD=$HEAD_A run_pr_check "$id" "$url"
  expect_code 0 "$PR_RC" "direct-PR registration failed on complete evidence: $PR_OUT"
  assert_grep "pr=$url" "$HOME_DIR/state/$id.meta" "direct-PR registration did not record pr="
  assert_grep "pr_head=$HEAD_A" "$HOME_DIR/state/$id.meta" "direct-PR registration did not record pr_head="
  ! grep -q '^nm_run_id=' "$HOME_DIR/state/$id.meta" || fail "direct-PR recorded a No-Mistakes run"
  assert_present "$HOME_DIR/state/$id.check.sh" "direct-PR registration did not arm the poll"
  [ ! -s "$NM_CALL_LOG" ] || fail "direct-PR registration consulted No-Mistakes: $(cat "$NM_CALL_LOG")"
  pass "direct-PR handoff proceeds on complete evidence and never consults No-Mistakes"
}

test_no_mistakes_handoff_proves_run_from_pipeline_status() {
  local id=nmpass url=https://github.com/o/r/pull/12 status
  make_task "$id" no-mistakes >/dev/null
  receipt "$id" AC1
  receipt "$id" AC2
  nm_db "INSERT INTO runs VALUES ('RUN-pass');"
  status=$(nm_status RUN-pass "fm/$id" "$HEAD_A" completed passed "$url")
  FM_FAKE_GH_HEAD=$HEAD_A FM_FAKE_NM_STATUS="$status" run_pr_check "$id" "$url"
  expect_code 0 "$PR_RC" "passed run on the task branch and PR was refused: $PR_OUT"
  assert_grep "nm_run_id=RUN-pass" "$HOME_DIR/state/$id.meta" "run id was not recorded"
  assert_grep "pr=$url" "$HOME_DIR/state/$id.meta" "pr= was not recorded"
  assert_present "$HOME_DIR/state/$id.check.sh" "no-mistakes registration did not arm the poll"
  grep -q 'validation_\|implementation_completed' "$HOME_DIR/state/$id.meta" \
    && fail "registration wrote validation metadata"
  # Re-registration of the same PR (fm-pr-merge does this before every merge)
  # replaces rather than duplicates the records and does not re-run the
  # handoff gates, so a daemon that is down later cannot block a merge of a PR
  # that was accepted at registration; a different URL is gated in full.
  FM_FAKE_GH_HEAD=$HEAD_A FM_FAKE_NM_DOWN=1 run_pr_check "$id" "$url"
  expect_code 0 "$PR_RC" "idempotent re-registration failed: $PR_OUT"
  [ "$(grep -c '^nm_run_id=' "$HOME_DIR/state/$id.meta")" -eq 1 ] || fail "nm_run_id was duplicated"
  [ "$(grep -c '^pr=' "$HOME_DIR/state/$id.meta")" -eq 1 ] || fail "pr= was duplicated"
  FM_FAKE_GH_HEAD=$HEAD_A FM_FAKE_NM_DOWN=1 run_pr_check "$id" https://github.com/o/r/pull/120
  expect_code 1 "$PR_RC" "a different PR skipped the handoff gates"
  assert_grep "pr=$url" "$HOME_DIR/state/$id.meta" "a refused re-registration replaced the recorded PR"
  pass "no-mistakes handoff records nm_run_id from a passed run matching branch, PR, and head"
}

test_ci_green_active_run_is_pr_ready() {
  local id=nmci url=https://github.com/o/r/pull/13 status
  make_task "$id" no-mistakes >/dev/null
  receipt "$id" AC1
  receipt "$id" AC2
  nm_db "INSERT INTO runs VALUES ('RUN-ci');"
  status=$(nm_status RUN-ci "fm/$id" "$HEAD_A" ci "" "$url")
  FM_FAKE_GH_HEAD=$HEAD_A FM_FAKE_NM_STATUS="$status" FM_FAKE_NM_CI_LOG='CI checks running' run_pr_check "$id" "$url"
  expect_code 1 "$PR_RC" "a run still waiting on CI was accepted"
  assert_contains "$PR_OUT" "neither passed nor CI-green" "CI-wait refusal did not say why"
  assert_not_armed "$id" "ci-running"
  FM_FAKE_GH_HEAD=$HEAD_A FM_FAKE_NM_STATUS="$status" FM_FAKE_NM_CI_LOG='CI checks passed' run_pr_check "$id" "$url"
  expect_code 0 "$PR_RC" "a CI-green monitoring run was refused: $PR_OUT"
  assert_grep "nm_run_id=RUN-ci" "$HOME_DIR/state/$id.meta" "CI-green run id was not recorded"
  pass "an active run whose CI log reads green is PR-ready"
}

test_wrong_or_foreign_runs_are_refused() {
  local id=nmwrong url=https://github.com/o/r/pull/14 variant status head=$HEAD_A log='' down=0 reason
  make_task "$id" no-mistakes >/dev/null
  receipt "$id" AC1
  receipt "$id" AC2
  for variant in other-branch other-pr foreign-head failed cancelled running-no-log no-run daemon-down no-forge-head; do
    head=$HEAD_A; log=''; down=0
    case "$variant" in
      other-branch) status=$(nm_status RUN-w "fm/other-task" "$HEAD_A" completed passed "$url"); reason="on branch 'fm/other-task'" ;;
      other-pr) status=$(nm_status RUN-w "fm/$id" "$HEAD_A" completed passed https://github.com/o/r/pull/99); reason="opened 'https://github.com/o/r/pull/99'" ;;
      foreign-head) status=$(nm_status RUN-w "fm/$id" "$HEAD_B" completed passed "$url"); reason="validated head $HEAD_B but the PR head is $HEAD_A" ;;
      failed) status=$(nm_status RUN-w "fm/$id" "$HEAD_A" failed failed "$url"); reason='neither passed nor CI-green' ;;
      cancelled) status=$(nm_status RUN-w "fm/$id" "$HEAD_A" cancelled cancelled "$url"); reason='neither passed nor CI-green' ;;
      running-no-log) status=$(nm_status RUN-w "fm/$id" "$HEAD_A" running "" "$url"); reason='neither passed nor CI-green' ;;
      no-run) status=$'current_branch: unknown\ncount: 0 of 0 total'; reason='reports no run' ;;
      daemon-down) status=''; down=1; reason='could not be observed' ;;
      no-forge-head) status=$(nm_status RUN-w "fm/$id" "$HEAD_A" completed passed "$url"); head=''; reason="PR head could not be observed" ;;
    esac
    FM_FAKE_GH_HEAD=$head FM_FAKE_NM_STATUS="$status" FM_FAKE_NM_CI_LOG="$log" FM_FAKE_NM_DOWN=$down run_pr_check "$id" "$url"
    expect_code 1 "$PR_RC" "$variant run was accepted"
    assert_contains "$PR_OUT" "$reason" "$variant refusal did not name its reason: $PR_OUT"
    assert_not_armed "$id" "$variant"
  done
  pass "runs on another branch or PR, foreign heads, failed, unfinished, or unobservable runs never arm"
}

seed_ask_user_run() {  # <run-id>
  nm_db "
    INSERT INTO runs VALUES ('$1');
    INSERT INTO step_results (id, run_id, step_name, step_order, status, findings_json)
    VALUES ('sr-$1', '$1', 'review', 3, 'completed',
      '{\"findings\":[{\"id\":\"R9\",\"action\":\"ask-user\",\"severity\":\"error\"}]}');
    INSERT INTO step_rounds (id, step_result_id, round, selection_source, selected_finding_ids, findings_json)
    VALUES ('sr-$1-1', 'sr-$1', 1, 'user_declined', '[]',
      '{\"findings\":[{\"id\":\"R9\",\"action\":\"ask-user\"}]}');
  " || fail "ask-user fixture seeding failed"
}

test_pr_ready_requires_firstmate_decisions_for_ask_user_findings() {
  local id=nmask url=https://github.com/o/r/pull/15 status
  make_task "$id" no-mistakes >/dev/null
  receipt "$id" AC1
  receipt "$id" AC2
  seed_ask_user_run RUN-ask
  status=$(nm_status RUN-ask "fm/$id" "$HEAD_A" completed passed "$url")
  FM_FAKE_GH_HEAD=$HEAD_A FM_FAKE_NM_STATUS="$status" run_pr_check "$id" "$url"
  expect_code 1 "$PR_RC" "a worker-answered ask-user finding reached PR-ready"
  assert_contains "$PR_OUT" "finding R9 resolved as approve" "refusal did not name the finding and action"
  assert_contains "$PR_OUT" "resolved [key=nm-RUN-ask-review]" "refusal did not name the missing decision key"
  assert_not_armed "$id" "undecided ask-user"
  printf 'resolved [key=nm-RUN-ask-review]: decided: approve R9\n' >> "$HOME_DIR/state/$id.status"
  FM_FAKE_GH_HEAD=$HEAD_A FM_FAKE_NM_STATUS="$status" run_pr_check "$id" "$url"
  expect_code 1 "$PR_RC" "a noncanonical decision record was counted"
  printf 'resolved [key=nm-RUN-ask-review]: answered: approve R9\n' >> "$HOME_DIR/state/$id.status"
  FM_FAKE_GH_HEAD=$HEAD_A FM_FAKE_NM_STATUS="$status" run_pr_check "$id" "$url"
  expect_code 0 "$PR_RC" "a firstmate-decided finding was still refused: $PR_OUT"
  assert_grep "nm_run_id=RUN-ask" "$HOME_DIR/state/$id.meta" "decided run was not recorded"
  pass "PR-ready refuses a self-answered ask-user finding until a firstmate decision record exists"
}

test_unreadable_decision_data_fails_closed() {
  local id=nmunread url=https://github.com/o/r/pull/16 status empty
  make_task "$id" no-mistakes >/dev/null
  receipt "$id" AC1
  receipt "$id" AC2
  empty="$TMP_ROOT/nm-empty"
  mkdir -p "$empty"
  status=$(nm_status RUN-unread "fm/$id" "$HEAD_A" completed passed "$url")
  NM_HOME="$empty" FM_FAKE_GH_HEAD=$HEAD_A FM_FAKE_NM_STATUS="$status" run_pr_check "$id" "$url"
  expect_code 1 "$PR_RC" "unreadable decision data armed the poll"
  assert_contains "$PR_OUT" "decision evidence could not be read" "unreadable refusal did not name the requirement"
  assert_not_armed "$id" "unreadable decisions"
  pass "unreadable No-Mistakes decision data refuses PR-ready with its own reason"
}

test_direct_pr_handoff_requires_complete_evidence
test_no_mistakes_handoff_proves_run_from_pipeline_status
test_ci_green_active_run_is_pr_ready
test_wrong_or_foreign_runs_are_refused
test_pr_ready_requires_firstmate_decisions_for_ask_user_findings
test_unreadable_decision_data_fails_closed
