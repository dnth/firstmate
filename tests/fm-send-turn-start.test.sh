#!/usr/bin/env bash
# fm-send OMP turn-start verification and supervised wedge recovery.
#
# These tests drive the public fm-send executable through a stubbed tmux
# backend and fake process identity, so no live OMP session is required.
# They prove a confirmed submit does not count as success until an initially
# idle OMP target becomes busy or advances its turn-start marker, while the
# already-busy queued-Enter exception and non-OMP delivery keep their existing
# behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-turn-start)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send literal=%s key=%s\n' "$literal" "${1:-}" >> "$FM_TEST_SEND_LOG"
    if [ "$literal" -eq 0 ] && [ "${1:-}" = Enter ]; then
      : > "$FM_TEST_ENTERED"
      if [ "$FM_TEST_MODE" = activity ]; then
        touch "$FM_TEST_TURNSTART_MARKER"
      fi
    fi
    exit 0
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'bun\n'; exit 0 ;;
      *pane_pid*) printf '4242\n'; exit 0 ;;
      *cursor_y*)
        if [ "$FM_TEST_MODE" = queued ]; then printf '2\n'; else printf '1\n'; fi
        exit 0
        ;;
    esac
    printf '%%1\n'
    exit 0
    ;;
  capture-pane)
    if [ "$FM_TEST_MODE" = queued ] \
      || { [ "$FM_TEST_MODE" = starts ] && [ -f "$FM_TEST_ENTERED" ]; }; then
      printf 'Working… ⟦esc⟧\n'
    fi
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0
    ;;
  list-windows)
    printf 'fm-turn-test\n'
    exit 0
    ;;
  kill-window)
    printf 'kill-window\n' >> "$FM_TEST_SEND_LOG"
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *tpgid=*) printf '4242\n' ;;
  *args=*) printf '%s %s --auto-approve\n' "$FM_TEST_BUN" "$FM_TEST_OMP" ;;
esac
SH
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
printf 'n%s\n' "$FM_TEST_BUN"
SH
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_SLEEP_LOG:-}" ] || printf '%s\n' "${1:-0}" >> "$FM_TEST_SLEEP_LOG"
exit 0
SH
  chmod +x "$fb/tmux" "$fb/ps" "$fb/lsof" "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() {  # <name> <harness> -> echoes "home fakebin bun omp log entered"
  local name=$1 harness=$2 dir home fb bun omp log entered
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  mkdir -p "$home/state"
  fb=$(make_stubs "$dir")
  bun="$dir/bun"
  omp="$dir/omp"
  log="$dir/send.log"
  entered="$dir/entered"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bun"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$omp"
  chmod +x "$bun" "$omp"
  bun=$(fm_test_realpath "$bun")
  omp=$(fm_test_realpath "$omp")
  fm_write_meta "$home/state/turn-test.meta" \
    'window=test:fm-turn-test' 'endpoint_task_id=turn-test' \
    "worktree=$dir/worktree" "project=$dir/project" "harness=$harness" \
    'kind=ship' 'mode=no-mistakes' 'yolo=off' "tasktmp=$dir/tasktmp" \
    "omp_bin=$omp" "omp_bun=$bun"
  : > "$log"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$home" "$fb" "$bun" "$omp" "$log" "$entered"
}

run_case() {  # <mode> <home> <fakebin> <bun> <omp> <log> <entered> [fm-send args...]
  local mode=$1 home=$2 fb=$3 bun=$4 omp=$5 log=$6 entered=$7
  shift 7
  [ $# -gt 0 ] || set -- 'steer now'
  env PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_TEST_MODE="$mode" FM_TEST_BUN="$bun" FM_TEST_OMP="$omp" \
    FM_TEST_SEND_LOG="$log" FM_TEST_ENTERED="$entered" \
    FM_TEST_TURNSTART_MARKER="$home/state/turn-test.omp-started" \
    FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    FM_SEND_TURNSTART_TIMEOUT="${FM_SEND_TURNSTART_TIMEOUT:-0.1}" \
    FM_SEND_TURNSTART_POLL="${FM_SEND_TURNSTART_POLL:-0.02}" \
    FM_TEST_SLEEP_LOG="${FM_TEST_SLEEP_LOG:-}" \
    "$SEND" turn-test "$@"
}

test_confirmed_submit_without_turn_is_distinct_and_wakes_recovery() {
  local home fb bun omp log entered rc err status wake
  IFS=$'\t' read -r home fb bun omp log entered < <(setup_case wedge omp)
  err="$home/no-turn.err"
  run_case wedge "$home" "$fb" "$bun" "$omp" "$log" "$entered" >/dev/null 2>"$err"; rc=$?
  expect_code 4 "$rc" "a confirmed OMP submit with no turn should return the distinct exit status"
  assert_contains "$(cat "$err")" 'delivered-no-turn' \
    "the no-turn verdict was not loud and machine-distinct"
  status=$(cat "$home/state/turn-test.status")
  assert_contains "$status" 'failed: delivered-no-turn:' \
    "the no-turn verdict did not append an actionable recovery marker"
  wake=$(cat "$home/state/.wake-queue")
  assert_contains "$wake" $'\tsignal\tturn-test.status\tdelivered-no-turn: turn-test' \
    "the no-turn verdict did not enqueue a durable watcher wake"
  assert_not_contains "$(cat "$log")" 'kill-window' \
    "no-turn recovery automatically killed a crewmate that may hold unlanded work"
  pass "fm-send: confirmed OMP delivery without a turn returns delivered-no-turn and wakes supervised recovery"
}

test_turn_start_keeps_normal_success() {
  local home fb bun omp log entered rc
  IFS=$'\t' read -r home fb bun omp log entered < <(setup_case starts omp)
  run_case starts "$home" "$fb" "$bun" "$omp" "$log" "$entered" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "an OMP submit whose turn becomes busy should still succeed"
  assert_absent "$home/state/turn-test.status" \
    "a normal OMP turn start emitted a recovery marker"
  assert_not_contains "$(cat "$log")" 'kill-window' \
    "normal OMP turn-start verification invoked destructive recovery"
  pass "fm-send: a real OMP turn start preserves normal success"
}

test_no_turn_does_not_close_answered_decision() {
  local home fb bun omp log entered rc status
  IFS=$'\t' read -r home fb bun omp log entered < <(setup_case answer-wedge omp)
  printf 'blocked [key=turn-answer]: waiting for a steer\n' > "$home/state/turn-test.status"
  run_case wedge "$home" "$fb" "$bun" "$omp" "$log" "$entered" \
    --resolve-key turn-answer 'use this answer' >/dev/null 2>&1; rc=$?
  expect_code 4 "$rc" "a delivered answer with no receiving turn should retain the no-turn verdict"
  status=$(cat "$home/state/turn-test.status")
  assert_not_contains "$status" 'resolved [key=turn-answer]:' \
    "a submitted answer closed its decision before OMP started a turn"
  assert_contains "$status" 'failed: delivered-no-turn:' \
    "an answered decision with no receiving turn lost its recovery marker"
  pass "fm-send: delivered-no-turn never closes an answered decision"
}

test_turn_activity_advance_keeps_fast_success() {
  local home fb bun omp log entered rc
  IFS=$'\t' read -r home fb bun omp log entered < <(setup_case activity omp)
  : > "$home/state/turn-test.omp-started"
  run_case activity "$home" "$fb" "$bun" "$omp" "$log" "$entered" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "an OMP session activity advance should prove a fast turn started"
  assert_absent "$home/state/turn-test.status" \
    "an OMP turn-start activity advance emitted a recovery marker"
  pass "fm-send: OMP session activity advancement proves a fast turn start"
}

test_busy_queued_enter_remains_success() {
  local home fb bun omp log entered rc
  IFS=$'\t' read -r home fb bun omp log entered < <(setup_case queued omp)
  run_case queued "$home" "$fb" "$bun" "$omp" "$log" "$entered" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "the already-busy OMP queued-Enter exception should remain accepted"
  [ "$(grep -c 'key=Enter' "$log")" -eq 1 ] \
    || fail "the busy OMP queued-Enter path no longer transports exactly one Enter"
  assert_absent "$home/state/turn-test.status" \
    "the busy queued-Enter exception emitted a false no-turn recovery marker"
  pass "fm-send: the already-busy OMP queued-Enter exception is unchanged"
}

test_non_omp_does_not_gain_turn_start_verification() {
  local home fb bun omp log entered rc
  IFS=$'\t' read -r home fb bun omp log entered < <(setup_case non-omp codex)
  run_case wedge "$home" "$fb" "$bun" "$omp" "$log" "$entered" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a non-OMP confirmed submit should not require OMP turn-start evidence"
  assert_absent "$home/state/turn-test.status" \
    "a non-OMP send emitted an OMP no-turn recovery marker"
  pass "fm-send: turn-start verification remains scoped to OMP targets"
}

test_timeout_bounds_final_poll_interval() {
  local home fb bun omp log entered rc sleep_log total
  IFS=$'\t' read -r home fb bun omp log entered < <(setup_case bounded-timeout omp)
  sleep_log="$home/sleep.log"
  FM_TEST_SLEEP_LOG="$sleep_log" FM_SEND_TURNSTART_POLL=0.099 \
    run_case wedge "$home" "$fb" "$bun" "$omp" "$log" "$entered" >/dev/null 2>&1
  rc=$?
  expect_code 4 "$rc" "a bounded no-turn poll should retain its distinct verdict"
  total=$(awk '$1 > 0 && $1 <= 0.1 { sum += $1 } END { printf "%.6f", sum }' "$sleep_log")
  awk -v total="$total" 'BEGIN { exit !(total >= 0.099999 && total <= 0.100001) }' \
    || fail "turn-start polling slept $total seconds for a 0.1 second timeout"
  pass "fm-send: the final turn-start poll is bounded by the configured timeout"
}

test_omp_key_ignores_turnstart_configuration() {
  local home fb bun omp log entered rc
  IFS=$'\t' read -r home fb bun omp log entered < <(setup_case key-config omp)
  FM_SEND_TURNSTART_TIMEOUT=invalid \
    run_case wedge "$home" "$fb" "$bun" "$omp" "$log" "$entered" --key Enter >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "an OMP key should not validate text-only turn-start configuration"
  [ "$(grep -c 'key=Enter' "$log")" -eq 1 ] \
    || fail "the OMP key path did not transport exactly one Enter"
  pass "fm-send: OMP keys ignore text-only turn-start configuration"
}

test_remote_control_uses_task_bound_omp_route() {
  local dir root home rc
  dir="$TMP_ROOT/remote-control-route"
  root="$dir/root"
  home="$dir/home"
  mkdir -p "$root/bin" "$home/bin" "$home/state/parent-route" "$home/data/.parent-route"
  cp "$ROOT/bin/fm-remote-secondmate-control.sh" "$root/bin/"
  cat > "$root/bin/fm-backend.sh" <<'SH'
fm_backend_validate_task_endpoint() {
  FM_BACKEND_VALIDATED_BACKEND=herdr
  FM_BACKEND_VALIDATED_TARGET='fm-remote:w1:p1'
}
fm_backend_meta_exact_value() {
  sed -n "s/^$2=//p" "$1"
}
fm_meta_get() {
  sed -n "s/^$2=//p" "$1" | tail -1
}
SH
  : > "$root/bin/fm-pending-reply-lib.sh"
  : > "$root/bin/fm-quota-axi-lib.sh"
  cat > "$root/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = 'fm-remote:w1:p1' ] || exit 81
[ "$FM_STATE_OVERRIDE" = "$FM_HOME/state/parent-route" ] || exit 82
[ "$FM_DATA_OVERRIDE" = "$FM_HOME/data/.parent-route" ] || exit 83
[ "$(sed -n 's/^harness=//p' "$FM_STATE_OVERRIDE/remote-turn.meta")" = omp ] || exit 84
exit 4
SH
  chmod +x "$root/bin/fm-remote-secondmate-control.sh" "$root/bin/fm-send.sh"
  : > "$home/AGENTS.md"
  printf 'remote-turn\n' > "$home/.fm-secondmate-home"
  fm_write_meta "$home/state/parent-route/remote-turn.meta" \
    'window=fm-remote:w1:p1' 'endpoint_task_id=remote-turn' 'backend=herdr' \
    'worktree=/remote/worktree' 'project=/remote/project' 'harness=omp' \
    'herdr_session=fm-remote' 'herdr_workspace_id=w1' 'herdr_tab_id=w1:t1' \
    'herdr_pane_id=w1:p1'
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$root/bin/fm-remote-secondmate-control.sh" send remote-turn 'remote steer' >/dev/null 2>&1
  rc=$?
  expect_code 4 "$rc" "remote control should preserve the host-local OMP no-turn verdict"
  pass "fm-send: remote control verifies through task-bound OMP route metadata"
}

test_confirmed_submit_without_turn_is_distinct_and_wakes_recovery
test_turn_start_keeps_normal_success
test_no_turn_does_not_close_answered_decision
test_turn_activity_advance_keeps_fast_success
test_busy_queued_enter_remains_success
test_non_omp_does_not_gain_turn_start_verification
test_timeout_bounds_final_poll_interval
test_omp_key_ignores_turnstart_configuration
test_remote_control_uses_task_bound_omp_route
