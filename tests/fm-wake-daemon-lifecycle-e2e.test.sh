#!/usr/bin/env bash
# tests/fm-wake-daemon-lifecycle-e2e.test.sh - the watcher + supervise-daemon
# lifecycle, end to end, over one shared state root and a shimmed tmux:
#
#   routine status -> self-handled, queued
#   terminal status written while the watcher is DOWN -> caught on restart (catch-up)
#   drain queued records -> exactly ONE captain-relevant digest is buffered
#   housekeeping catch-all scan -> NO duplicate digest
#   buffered digest flushes to the supervisor pane as exactly ONE submission
#   stale working-pane: transient (self + marker) -> persistent (escalates once,
#     clears its marker) -> resumed/busy (clears without escalating)
#
# This proves the operator-visible routing/queueing/dedupe behavior through real
# fm-watch.sh runs plus the daemon's own functions. The captain-relevant
# status-phrase matrix and the lock-primitive races stay as focused units
# (fm-daemon.test.sh, fm-watcher-lock.test.sh) - an e2e cannot deterministically
# cover a race, and the phrase list is a product contract worth a dedicated test.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Source the daemon's pure functions (its main loop is guarded out under sourcing).
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=/dev/null
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-wake-daemon-e2e)

# Run the daemon-managed watcher once: under the supervise-daemon (away mode) the
# watcher is one-shot - it exits with a single reason line on EVERY wake and the
# daemon does the triage. This e2e exercises exactly that path, so it runs with
# state/.afk present (which the daemon owns) to keep the watcher one-shot; the
# always-on standalone triage is covered by fm-watch-triage.test.sh. fakebin
# shadows tmux. Echoes nothing; the caller reads $out.
run_watcher_once() {
  local state=$1 fakebin=$2 out=$3
  mkdir -p "$state"
  date '+%s' > "$state/.afk"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 50
}

ack_handled_wakes() {  # <state> <drain-stderr>
  local state=$1 drain_err=$2 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# --- Phase 1: routine self-handled, queued; terminal caught after restart ---
test_routine_then_terminal_after_restart() {
  local dir state fakebin out drain_out drain_err status_file
  dir=$(make_supercase wd-lifecycle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  status_file="$state/task-w1.status"

  # A routine status fires a signal; the watcher queues it and exits.
  printf 'working: building\n' > "$status_file"
  run_watcher_once "$state" "$fakebin" "$out" || fail "watcher did not exit for the routine signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not report the routine signal"

  # Drain it and route through the daemon: a routine status self-handles.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
    || fail "drain after routine signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "routine signal was not queued"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  ack_handled_wakes "$state" "$drain_err" || fail "routine wake acknowledgement failed"
  [ ! -s "$state/.subsuper-escalations" ] || fail "routine status was escalated by the daemon"

  # The watcher is now DOWN (one-shot exit). A terminal status lands while it is
  # down; the next watcher run must catch it up (losslessness across restart).
  printf 'done: PR https://example.test/pr/900\n' >> "$status_file"
  : > "$out"
  run_watcher_once "$state" "$fakebin" "$out" || fail "restarted watcher did not exit for the terminal signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "terminal signal written while watcher down was not caught on restart"

  # Drain and route the terminal: exactly ONE digest is buffered.
  : > "$drain_out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
    || fail "drain after terminal signal failed"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  ack_handled_wakes "$state" "$drain_err" || fail "terminal wake acknowledgement failed"
  [ -s "$state/.subsuper-escalations" ] || fail "captain-relevant terminal status was not buffered"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "expected exactly one buffered digest after the terminal signal"

  # The catch-all heartbeat scan must NOT re-escalate the same status (no dup).
  FM_STATE_OVERRIDE="$state" housekeeping "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "catch-all scan duplicated the already-buffered digest"

  # With afk active, the buffered digest flushes to the supervisor pane as ONE
  # submission (one typed line + one Enter), then the buffer clears.
  local sent
  sent="$dir/sent.log"; : > "$sent"
  : > "$dir/pane.txt"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed for the buffered digest"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "buffered digest was not submitted exactly once"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after a successful flush"
  pass "lifecycle: routine self-handles, terminal survives a watcher restart, buffers once, no dup, injects once"
}

test_decision_only_recovery_routes_before_acknowledgement() {
  local dir state fakebin daemon_bin expected marker sent capture
  dir=$(make_supercase wd-decision-only-recovery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  daemon_bin="$dir/daemon-bin"
  expected="decision-task [key=release-route] needs-decision: choose the guarded release route"
  marker="$state/.watcher-down"
  sent="$dir/sent.log"
  capture="$dir/pane.txt"
  mkdir -p "$daemon_bin"
  : > "$sent"
  : > "$capture"
  printf 'needs-decision [key=release-route]: choose the guarded release route\nworking: unrelated progress after the decision\n' \
    > "$state/decision-task.status"
  afk_enter "$state"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_publish "$2" downtime
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$marker" || fail "decision-only recovery marker could not be published"

  cat > "$daemon_bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --ack-through ]; then
  grep -F "$FM_EXPECTED_DECISION" "$FM_EXPECTED_SENT" >/dev/null \
    || { printf 'decision acknowledgement ran before confirmed decision injection\n' >&2; exit 91; }
  printf 'ack-after-decision\n' > "$FM_STATE_OVERRIDE/.decision-ack-order"
fi
exec "$FM_REAL_WAKE_DRAIN" "$@"
SH
  chmod +x "$daemon_bin/fm-wake-drain.sh"

  FM_DAEMON_DIR="$daemon_bin" \
    FM_REAL_WAKE_DRAIN="$DRAIN" \
    FM_EXPECTED_DECISION="$expected" \
    FM_EXPECTED_SENT="$sent" \
    FM_STATE_OVERRIDE="$state" \
    FM_ESCALATE_BATCH_SECS=30 \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    PATH="$fakebin:$PATH" \
    handle_durable_wakes "check: rearm-resurface" "$state" \
    || fail "decision-only durable recovery failed"

  grep -F "$expected" "$sent" >/dev/null \
    || fail "decision-only recovery omitted the buried open decision from its injection"
  grep -F 'check: rearm-resurface' "$sent" >/dev/null \
    || fail "decision-only recovery lost its generic fallback injection"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "decision-only recovery acknowledged before its escalation buffer was injected"
  [ -e "$state/.decision-ack-order" ] \
    || fail "decision-only recovery did not prove routing before acknowledgement"
  case "$(cat "$marker" 2>/dev/null || true)" in
    acked:handling:*) ;;
    *) fail "decision-only recovery did not retire its handled recovery episode" ;;
  esac
  pass "lifecycle: decision-only recovery routes the buried decision before acknowledgement"
}

test_decision_route_failure_retains_recovery_for_retry() {
  local dir state fakebin daemon_bin expected marker sent capture
  dir=$(make_supercase wd-decision-route-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  daemon_bin="$dir/daemon-bin"
  expected="decision-retry [key=release-route] needs-decision: preserve this choice for retry"
  marker="$state/.watcher-down"
  sent="$dir/sent.log"
  capture="$dir/pane.txt"
  mkdir -p "$daemon_bin" "$state/.subsuper-escalations"
  : > "$sent"
  : > "$capture"
  printf 'needs-decision [key=release-route]: preserve this choice for retry\nworking: unrelated progress after the decision\n' \
    > "$state/decision-retry.status"
  afk_enter "$state"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_publish "$2" downtime
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$marker" || fail "decision retry recovery marker could not be published"

  cat > "$daemon_bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --ack-through ]; then
  printf 'ack-attempted\n' > "$FM_STATE_OVERRIDE/.decision-ack-attempt"
fi
exec "$FM_REAL_WAKE_DRAIN" "$@"
SH
  chmod +x "$daemon_bin/fm-wake-drain.sh"

  if FM_DAEMON_DIR="$daemon_bin" \
    FM_REAL_WAKE_DRAIN="$DRAIN" \
    FM_STATE_OVERRIDE="$state" \
    FM_ESCALATE_BATCH_SECS=30 \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    PATH="$fakebin:$PATH" \
    handle_durable_wakes "check: rearm-resurface" "$state" \
    2> "$dir/failed-route.err"; then
    fail "decision routing failure was reported as acknowledged"
  fi

  [ ! -e "$state/.decision-ack-attempt" ] \
    || fail "decision routing failure still invoked recovery acknowledgement"
  case "$(cat "$marker" 2>/dev/null || true)" in
    pending:handling:*|announced:handling:*) ;;
    *) fail "decision routing failure retired its recovery episode" ;;
  esac

  rmdir "$state/.subsuper-escalations" \
    || fail "decision routing failure fixture could not restore its escalation path"
  FM_DAEMON_DIR="$daemon_bin" \
    FM_REAL_WAKE_DRAIN="$DRAIN" \
    FM_STATE_OVERRIDE="$state" \
    FM_ESCALATE_BATCH_SECS=30 \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    PATH="$fakebin:$PATH" \
    handle_durable_wakes "check: rearm-resurface" "$state" \
    || fail "retained decision recovery could not be retried"

  [ -e "$state/.decision-ack-attempt" ] \
    || fail "successful decision retry did not reach recovery acknowledgement"
  grep -F "$expected" "$sent" >/dev/null \
    || fail "successful decision retry did not inject the retained decision"
  case "$(cat "$marker" 2>/dev/null || true)" in
    acked:handling:*) ;;
    *) fail "successful decision retry did not retire its handled recovery episode" ;;
  esac
  pass "lifecycle: failed decision routing retains recovery for a successful retry"
}

test_incomplete_decision_capture_retains_recovery() {
  local mode dir state daemon_bin marker expected
  for mode in truncated remove-capture; do
    dir=$(make_supercase "wd-decision-$mode")
    state="$dir/state"
    daemon_bin="$dir/daemon-bin"
    marker="$state/.watcher-down"
    expected="decision-$mode [key=route] needs-decision: retain this decision after $mode output"
    mkdir -p "$daemon_bin"
    printf 'needs-decision [key=route]: retain this decision after %s output\nworking: later progress\n' "$mode" \
      > "$state/decision-$mode.status"

    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      fm_recovery_marker_publish "$2" downtime
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$marker" || fail "$mode recovery marker could not be published"

    cat > "$daemon_bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --ack-through ]; then
  printf 'ack-attempted\n' > "$FM_STATE_OVERRIDE/.decision-ack-attempt"
  exec "$FM_REAL_WAKE_DRAIN" "$@"
fi
case "$FM_DECISION_CAPTURE_MODE" in
  truncated)
    raw=$(mktemp "$FM_STATE_OVERRIDE/.truncated-drain.XXXXXX") || exit 1
    raw_err=$(mktemp "$FM_STATE_OVERRIDE/.truncated-drain.XXXXXX") || { rm -f "$raw"; exit 1; }
    rc=0
    "$FM_REAL_WAKE_DRAIN" > "$raw" 2> "$raw_err" || rc=$?
    sed '/^OPEN DECISIONS: close one by answering it:/,$d' "$raw"
    cat "$raw_err" >&2
    rm -f "$raw" "$raw_err"
    exit "$rc"
    ;;
  remove-capture)
    probe="decision-capture-probe-$$"
    printf '%s\n' "$probe"
    removed=false
    for candidate in "$FM_STATE_OVERRIDE"/.subsuper-wake-drain.*; do
      [ -f "$candidate" ] || continue
      if grep -F -x "$probe" "$candidate" >/dev/null 2>&1; then
        rm -f "$candidate" || exit 1
        removed=true
        break
      fi
    done
    [ "$removed" = true ] || exit 92
    exec "$FM_REAL_WAKE_DRAIN" "$@"
    ;;
  *) exit 93 ;;
esac
SH
    chmod +x "$daemon_bin/fm-wake-drain.sh"

    if FM_DAEMON_DIR="$daemon_bin" \
      FM_REAL_WAKE_DRAIN="$DRAIN" \
      FM_DECISION_CAPTURE_MODE="$mode" \
      FM_STATE_OVERRIDE="$state" \
      FM_ESCALATE_BATCH_SECS=30 \
      handle_durable_wakes "check: rearm-resurface" "$state" \
      2> "$dir/failed-capture.err"; then
      fail "$mode decision capture was reported as acknowledged"
    fi

    [ ! -e "$state/.decision-ack-attempt" ] \
      || fail "$mode decision capture still invoked recovery acknowledgement"
    case "$(cat "$marker" 2>/dev/null || true)" in
      pending:handling:*|announced:handling:*) ;;
      *) fail "$mode decision capture retired its recovery episode" ;;
    esac
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/retry.out" 2> "$dir/retry.err" \
      || fail "$mode decision capture did not remain retryable"
    grep -F "$expected" "$dir/retry.out" >/dev/null \
      || fail "$mode decision capture lost the open decision before retry"
  done
  pass "lifecycle: incomplete decision captures retain recovery and remain retryable"
}

test_decision_injection_failure_retains_recovery() {
  local dir state fakebin daemon_bin marker expected sent capture
  dir=$(make_supercase wd-decision-injection-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  daemon_bin="$dir/daemon-bin"
  marker="$state/.watcher-down"
  expected="decision-inject [key=route] needs-decision: retry after injection recovers"
  sent="$dir/sent.log"
  capture="$dir/pane.txt"
  mkdir -p "$daemon_bin"
  : > "$sent"
  : > "$capture"
  printf 'needs-decision [key=route]: retry after injection recovers\nworking: later progress\n' \
    > "$state/decision-inject.status"
  afk_enter "$state"

  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_publish "$2" downtime
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$marker" || fail "injection retry recovery marker could not be published"

  cat > "$daemon_bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --ack-through ]; then
  printf 'ack-attempted\n' > "$FM_STATE_OVERRIDE/.decision-ack-attempt"
fi
exec "$FM_REAL_WAKE_DRAIN" "$@"
SH
  chmod +x "$daemon_bin/fm-wake-drain.sh"

  if FM_DAEMON_DIR="$daemon_bin" \
    FM_REAL_WAKE_DRAIN="$DRAIN" \
    FM_STATE_OVERRIDE="$state" \
    FM_ESCALATE_BATCH_SECS=30 \
    FM_FAKE_TMUX_PANE_ALIVE=0 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    PATH="$fakebin:$PATH" \
    handle_durable_wakes "check: rearm-resurface" "$state"; then
    fail "unconfirmed decision injection was reported as acknowledged"
  fi

  [ ! -e "$state/.decision-ack-attempt" ] \
    || fail "unconfirmed decision injection still invoked recovery acknowledgement"
  grep -F "$expected" "$state/.subsuper-escalations" >/dev/null \
    || fail "unconfirmed decision injection did not preserve its durable buffer"
  case "$(cat "$marker" 2>/dev/null || true)" in
    pending:handling:*|announced:handling:*) ;;
    *) fail "unconfirmed decision injection retired its recovery episode" ;;
  esac

  FM_DAEMON_DIR="$daemon_bin" \
    FM_REAL_WAKE_DRAIN="$DRAIN" \
    FM_STATE_OVERRIDE="$state" \
    FM_ESCALATE_BATCH_SECS=30 \
    FM_FAKE_TMUX_PANE_ALIVE=1 \
    FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    PATH="$fakebin:$PATH" \
    handle_durable_wakes "check: rearm-resurface" "$state" \
    || fail "retained decision injection could not be retried"

  grep -F "$expected" "$sent" >/dev/null \
    || fail "successful injection retry omitted the retained decision"
  case "$(cat "$marker" 2>/dev/null || true)" in
    acked:handling:*) ;;
    *) fail "successful injection retry did not retire its handled recovery episode" ;;
  esac
  pass "lifecycle: unconfirmed decision injection retains recovery for retry"
}

# --- Phase 2: stale working-pane transient -> persistent -> resumed ----------
test_stale_pane_transient_persistent_resume() {
  local dir state fakebin win key resumed_gen
  dir=$(make_supercase wd-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-stale-w2"
  key=$(printf '%s' "stale-w2" | tr ':/.' '___')
  printf 'working: compiling\n' > "$state/stale-w2.status"

  # Transient: first stale observation self-handles and records a marker.
  stale_marker_record "$win" "$state"
  case "$(FM_STATE_OVERRIDE="$state" classify_stale "$win" "$state")" in
    self\|*) : ;;
    *) fail "transient stale did not self-handle" ;;
  esac
  [ -e "$state/.subsuper-stale-$key" ] || fail "transient stale did not record a persistence marker"

  # Persistent: the marker ages past the threshold and the pane is still idle, so
  # housekeeping escalates exactly once and clears the marker.
  printf 'idle prompt $\n' > "$dir/pane.txt"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  : > "$state/.subsuper-escalations" 2>/dev/null || true
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state" \
    2>"$dir/housekeeping.err"
  [ ! -s "$dir/housekeeping.err" ] \
    || fail "missing task metadata leaked a raw read error: $(cat "$dir/housekeeping.err")"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent stale did not escalate"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "stale marker not cleared after escalation"

  # Resumed: a fresh transient marker but the crew is provably working again ->
  # housekeeping clears the marker without escalating. The proof is the crew's
  # own semantic busy-state record (bin/fm-busy-lib.sh), not rendered pane text.
  stale_marker_record "$win" "$state"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  printf 'Working...\n' > "$dir/pane.txt"
  fm_write_meta "$state/stale-w2.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  resumed_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" stale-w2)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" stale-w2 busy --gen "$resumed_gen" \
    --source pi-ext --event agent-start
  : > "$state/.subsuper-escalations"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 housekeeping "$state"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "resumed stale marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "resumed (busy) stale was escalated"
  pass "lifecycle: stale pane transient self-handles, persistent escalates once and clears, resumed clears quietly"
}

test_routine_then_terminal_after_restart
test_decision_only_recovery_routes_before_acknowledgement
test_decision_route_failure_retains_recovery_for_retry
test_incomplete_decision_capture_retains_recovery
test_decision_injection_failure_retains_recovery
test_stale_pane_transient_persistent_resume
