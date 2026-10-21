#!/usr/bin/env bash
# Tests for the watcher's No-Mistakes PR-guard backstop
# (bin/fm-watch.sh nm_pr_unguarded_tick).
#
# bin/fm-nm-pr-guard.sh refuses a worker-initiated PR creation inside a
# no-mistakes ship's launch environment. This tick is the detection backstop
# for a bypass: a no-mistakes ship task whose branch already has an open PR but
# no No-Mistakes run on it means the worker created the PR itself, so it must
# raise one supervisor-actionable check wake naming the task and the PR, and
# stay quiet once a run exists on the branch.
#
# The tick is exercised in-process against a real worktree and fake `gh` /
# `no-mistakes` binaries: no network, no daemon, and no watcher loop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-nm-pr-unguarded)

# make_case <name>: a home with one no-mistakes ship task, its real worktree on
# branch fm/nm-detector, and fake `gh`/`no-mistakes` stand-ins whose answers are
# driven by FM_FAKE_PR_NUMBER / FM_FAKE_NM_RUNS. Echoes
# "case_dir|home|state|worktree|fakebin".
make_case() {
  local name=$1 case_dir home state worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  state="$home/state"
  worktree="$case_dir/worktree"
  fakebin="$case_dir/fakebin"
  mkdir -p "$state" "$home/data" "$home/projects" "$home/config" "$fakebin" || return 1

  mkdir -p "$worktree" || return 1
  git -C "$worktree" init --quiet -b fm/nm-detector || return 1
  printf 'base\n' > "$worktree/README.md" || return 1
  git -C "$worktree" add README.md || return 1
  git -C "$worktree" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial || return 1

  fm_write_meta "$state/nm-ship-r1.meta" \
    "window=firstmate:0" \
    "endpoint_task_id=nm-ship-r1" \
    "worktree=$worktree" \
    "project=$case_dir/project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=gen1" || return 1

  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# `gh pr list --state open --head <branch> --json number,url --jq ...`
case "${1:-} ${2:-}" in
  "pr list")
    [ "${FM_FAKE_PR_FAIL:-0}" = 0 ] || exit 1
    [ -n "${FM_FAKE_PR_NUMBER:-}" ] || exit 0
    printf '%s\thttps://github.com/o/r/pull/%s\n' "$FM_FAKE_PR_NUMBER" "$FM_FAKE_PR_NUMBER"
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
# `no-mistakes axi status`: report the run count for the current branch.
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  printf 'current_branch: fm/nm-detector\n'
  printf 'runs_on_current_branch: %s\n' "${FM_FAKE_NM_RUNS:-0}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/no-mistakes" || return 1
  printf '%s\n' "$home|$state|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_HOME CASE_STATE CASE_FAKEBIN <<EOF
$1
EOF
}

# run_tick <pr-number> <runs>: source the watcher in a subshell that sees this
# case's state, override wake(), and run one scan. Prints the tick's wake
# reasons, one per line.
run_tick() {
  local pr=$1 runs=$2
  (
    export FM_HOME="$CASE_HOME" \
      FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$CASE_STATE" \
      FM_DATA_OVERRIDE="$CASE_HOME/data" \
      FM_PROJECTS_OVERRIDE="$CASE_HOME/projects" \
      FM_CONFIG_OVERRIDE="$CASE_HOME/config" \
      PATH="$CASE_FAKEBIN:$PATH" \
      FM_FAKE_PR_NUMBER="$pr" \
      FM_FAKE_NM_RUNS="$runs"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-watch.sh"
    # shellcheck disable=SC2329 # Replaces the watcher's exit-on-wake callback.
    wake() { printf 'WAKE:%s\n' "$1"; }
    rm -f "$CASE_STATE/.last-nm-pr-scan"
    nm_pr_unguarded_tick
  )
}

queue_rows() {  # <state>
  awk -F '\t' 'NF >= 5 { print $3 "|" $4 "|" $5 }' "$1/.wake-queue" 2>/dev/null || true
}

test_open_pr_without_run_raises_one_wake() {
  local rec out rows
  rec=$(make_case no-run) || fail "fixture setup failed"
  read_case "$rec"

  out=$(run_tick 7 0 2>&1) || fail "tick failed: $out"
  assert_contains "$out" "WAKE:check: no-mistakes task nm-ship-r1 has open PR https://github.com/o/r/pull/7" \
    "tick did not raise the expected check wake"
  rows=$(queue_rows "$CASE_STATE")
  assert_equals "1" "$(printf '%s\n' "$rows" | grep -c '^check|nm-pr-unguarded-nm-ship-r1-7|' || true)" \
    "tick did not append exactly one durable check row: $rows"
  assert_contains "$rows" "no No-Mistakes run on fm/nm-detector" \
    "wake payload did not name the branch and the missing run"

  # A second scan of the same episode stays quiet.
  out=$(run_tick 7 0 2>&1) || fail "second tick failed: $out"
  assert_not_contains "$out" "WAKE:" "tick re-raised the same PR"
  rows=$(queue_rows "$CASE_STATE")
  assert_equals "1" "$(printf '%s\n' "$rows" | grep -c '^check|nm-pr-unguarded-nm-ship-r1-7|' || true)" \
    "tick appended a duplicate durable row: $rows"
  pass "one wake for an open PR with no run, silent on repeat"
}

test_failed_lookup_preserves_episode() {
  local rec out rows
  rec=$(make_case lookup-failure) || fail "fixture setup failed"
  read_case "$rec"
  out=$(run_tick 7 0 2>&1) || fail "initial tick failed: $out"
  assert_contains "$out" "WAKE:" "initial episode did not wake"
  : > "$CASE_STATE/.wake-queue"

  out=$(FM_FAKE_PR_FAIL=1 run_tick 7 0 2>&1) || fail "failed-lookup tick failed: $out"
  assert_not_contains "$out" "WAKE:" "failed lookup raised a wake"
  out=$(run_tick 7 0 2>&1) || fail "recovery tick failed: $out"
  assert_not_contains "$out" "WAKE:" "lookup recovery repeated an acknowledged episode"
  rows=$(queue_rows "$CASE_STATE")
  assert_equals "" "$rows" "lookup recovery requeued the acknowledged episode"

  out=$(run_tick '' 0 2>&1) || fail "closed PR tick failed: $out"
  assert_not_contains "$out" "WAKE:" "closed PR raised a wake"
  out=$(run_tick 7 0 2>&1) || fail "reopened PR tick failed: $out"
  assert_contains "$out" "WAKE:" "confirmed closure did not reset the episode"
  out=$(run_tick 7 1 2>&1) || fail "run-present tick failed: $out"
  assert_not_contains "$out" "WAKE:" "run-present tick raised a wake"
  assert_absent "$CASE_STATE/.nm-pr-unguarded-nm-ship-r1" "observed run did not clear marker"
  pass "failed lookup preserves deduplication; confirmed closure or run resets it"
}

test_run_on_branch_stays_quiet() {
  local rec out rows
  rec=$(make_case with-run) || fail "fixture setup failed"
  read_case "$rec"

  out=$(run_tick 7 1 2>&1) || fail "tick failed: $out"
  assert_not_contains "$out" "WAKE:" "tick raised a wake although a run exists on the branch"
  rows=$(queue_rows "$CASE_STATE")
  assert_equals "" "$rows" "tick appended a row although a run exists on the branch"
  pass "a branch with a No-Mistakes run stays quiet"
}

test_no_open_pr_stays_quiet() {
  local rec out rows
  rec=$(make_case no-pr) || fail "fixture setup failed"
  read_case "$rec"

  out=$(run_tick '' 0 2>&1) || fail "tick failed: $out"
  assert_not_contains "$out" "WAKE:" "tick raised a wake with no open PR"
  rows=$(queue_rows "$CASE_STATE")
  assert_equals "" "$rows" "tick appended a row with no open PR"
  pass "no open PR stays quiet"
}

test_recorded_pr_is_skipped() {
  local rec out rows
  rec=$(make_case recorded) || fail "fixture setup failed"
  read_case "$rec"
  printf '%s\n' 'pr=https://github.com/o/r/pull/9' 'nm_run_id=run-9' >> "$CASE_STATE/nm-ship-r1.meta"

  out=$(run_tick 7 0 2>&1) || fail "tick failed: $out"
  assert_not_contains "$out" "WAKE:" "tick scanned a task whose recorded pr= already proves its run"
  rows=$(queue_rows "$CASE_STATE")
  assert_equals "" "$rows" "tick appended a row for a task with a recorded PR"
  pass "a recorded PR already proves its run and is skipped"
}

test_recorded_run_id_is_skipped() {
  local rec out rows
  rec=$(make_case recorded-run) || fail "fixture setup failed"
  read_case "$rec"
  printf '%s\n' 'nm_run_id=run-9' >> "$CASE_STATE/nm-ship-r1.meta"

  out=$(run_tick 7 0 2>&1) || fail "tick failed: $out"
  assert_not_contains "$out" "WAKE:" "tick scanned a task with a recorded nm_run_id"
  rows=$(queue_rows "$CASE_STATE")
  assert_equals "" "$rows" "tick appended a row for a task with a recorded run id"
  pass "a recorded run id is skipped"
}

test_open_pr_without_run_raises_one_wake
test_failed_lookup_preserves_episode
test_run_on_branch_stays_quiet
test_no_open_pr_stays_quiet
test_recorded_pr_is_skipped
test_recorded_run_id_is_skipped
