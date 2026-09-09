#!/usr/bin/env bash
# tests/fm-afk-inject-herdr-e2e.test.sh - real-Herdr end-to-end test for the
# away-mode daemon's Herdr admission path. Every explicit and production-adapter
# Herdr call is bound to one guarded named non-default lab through
# bin/fm-herdr-lab.sh. The suite skips cleanly when Herdr or jq is absent.
#
# Unlike the tmux e2e (which redirects a bare `tmux` PATH shim to a private
# socket), Herdr already supports named-session isolation via --session. The
# daemon is pointed at FM_SUPERVISOR_BACKEND=herdr,
# FM_SUPERVISOR_TARGET="<session>:<pane-id>", and HERDR_SESSION="<the isolated
# session>". The current Herdr API has no atomic composer admission primitive,
# so this suite proves that both a pre-existing draft and a newly idle composer
# preserve the escalation without typing into the captain's input channel.
#
# The "supervisor pane" is a tiny deterministic bash loop (not a real harness
# binary): it draws a bordered composer row ("│ > <buf> │") that exercises the
# bordered branch of fm_backend_herdr_composer_state, and logs every submitted
# line (hex + text + injection/user classification) - the same technique
# tests/fm-afk-inject-e2e.test.sh uses for its tmux supervisor pane, so this
# test asserts on submitted content, not pane appearance. It registers itself
# as a real Herdr agent so the production busy and composer readers observe an
# actual agent identity. The fixture submits only explicit human input; every
# supervisor escalation must remain out of the composer until Herdr exposes a
# verified atomic admission primitive.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

ORIGINAL_PATH=$PATH
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
LAB_HELPER=${HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
SESSION=$(PATH="$ORIGINAL_PATH" "$LAB_HELPER" name fm-afk-inject-herdr-e2e)
export HERDR_SESSION="$SESSION"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

STATE_DIR=
HERDR_WRAPPER_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_TARGET=
PANE_ID=
LOOP_SCRIPT=

cleanup_all() {
  local rc=$?
  trap - EXIT
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    printf 'not ok - guarded Herdr lab teardown failed\n' >&2
    return 1
  fi
  rm -rf "${HERDR_WRAPPER_DIR:-}" "${STATE_DIR:-}" 2>/dev/null || true
  return "$rc"
}
trap cleanup_all EXIT
PATH="$ORIGINAL_PATH" "$LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"

HERDR_WRAPPER_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-wrapper.XXXXXX")
cat > "$HERDR_WRAPPER_DIR/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo 'wrapper refused foreign session' >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo 'wrapper requires isolated session' >&2; exit 98; }
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$HERDR_WRAPPER_DIR/herdr"
PATH="$HERDR_WRAPPER_DIR:$ORIGINAL_PATH"
export PATH
# shellcheck source=/dev/null
. "$DAEMON"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- build the isolated session's supervisor pane ----------------------------

fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-e2e.XXXXXX")
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-afk-e2e-supervisor" /tmp "$SEEDED_TAB_ID") \
  || fail "create_task for the scratch supervisor pane failed"
read -r _TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$PANE_ID" ] || fail "create_task did not return a pane id"
SUPERVISOR_TARGET="$SESSION:$PANE_ID"

# Herdr can return the created pane before its interactive shell is ready to
# receive Enter. Require a stable shell-owned foreground before launching the
# fixture, or the command can remain typed but unsubmitted in the shell buffer.
PANE_READY=false
READY_SAMPLES=0
for _ in $(seq 1 100); do
  PROCESS_INFO=$(fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE_ID" 2>/dev/null || true)
  if printf '%s' "$PROCESS_INFO" | jq -e '
    .result.process_info as $process
    | ($process.foreground_processes | length == 1)
      and ($process.foreground_processes[0].pid == $process.shell_pid)
  ' >/dev/null 2>&1; then
    READY_SAMPLES=$((READY_SAMPLES + 1))
    if [ "$READY_SAMPLES" -ge 10 ]; then
      PANE_READY=true
      break
    fi
  else
    READY_SAMPLES=0
  fi
  sleep 0.1
done
[ "$PANE_READY" = true ] || fail "the supervisor pane's shell did not become ready"

# A second, independent live task tab in the same workspace, mirroring the tmux
# e2e's fake fm-fake-c1 crewmate window - not required by scan_signals (which
# only watches state/*.status mtimes, no window/pane dependency), but kept for
# parity so this test's shape matches the tmux e2e's.
FAKE_CREW_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-fake-c1" /tmp) \
  || fail "could not create the fake crewmate scratch tab"
read -r _FAKE_TAB_ID FAKE_CREW_PANE_ID <<EOF
$FAKE_CREW_IDS
EOF

# --- deterministic bordered-composer loop, drawn in the scratch pane ---------
# Mirrors tests/fm-afk-inject-e2e.test.sh's supervisor-loop.sh, but draws a
# "│ > <buf> │" border so the bordered branch of
# fm_backend_herdr_composer_state recognizes it, exactly like a bordered-TUI
# harness composer. ALSO registers itself as a real herdr agent via `herdr
# pane report-agent` and reports idle/working transitions around each
# submission: fm_backend_herdr_send_text_submit's confirmation is now native
# agent-state (agent get), not composer content (docs/herdr-backend.md
# "Native agent-state submit confirmation"), so a synthetic pane that only
# draws composer TEXT but is never registered as an agent would report
# agent_not_found forever - every confirmation attempt would read 'unknown',
# never 'empty', and the daemon would treat every injection as unconfirmed and
# keep retyping it on every housekeeping tick (the exact duplicate-send
# failure mode this whole change exists to prevent) - discovered by this very
# test regressing when the composer-only version of this fixture was run
# against the new confirmation code. `herdr pane report-agent` is herdr's own
# documented integration-protocol primitive for a non-built-in-harness process
# to report its own agent state, verified empirically against real herdr 0.7.1
# in an isolated session.
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
AGENT_SOURCE=fm-test-supervisor
AGENT_LABEL=fm-test-supervisor
report_agent_state() {  # <idle|working>
  herdr pane report-agent "$HERDR_PANE_ID" --source "$AGENT_SOURCE" --agent "$AGENT_LABEL" --state "$1" --session "$HERDR_SESSION" >/dev/null 2>&1
}
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
report_agent_state idle

_buf=
# redraw: keep the composer visually pinned to ONE terminal row regardless of
# _buf's length - a realistic bordered single-line composer horizontally
# scrolls to show the tail near the cursor rather than letting the terminal
# hard-wrap a too-long line across multiple rows (which would break the
# structural border-row classifier's one-row assumption: a batched escalation
# digest easily exceeds a narrow pane's column width). A hardcoded width
# (not `tput cols`) is used deliberately: verified empirically against a real
# herdr pane launched this same way that `tput cols` inside this script's own
# process reports 80 regardless of the pane's ACTUAL width (54, confirmed via
# a separate interactively-typed `tput cols`), so trusting it here silently
# let content overflow the real width and wrap across two rows. 40 is
# comfortably under every real pane width observed on this machine.
redraw() {
  local avail=40 shown tail_n
  if [ "${#_buf}" -gt "$avail" ]; then
    tail_n=$((avail - 3))
    shown="...${_buf: -$tail_n}"
  else
    shown="$_buf"
  fi
  printf '\r\033[K│ > %s │' "$shown"
}
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then
    _c="injection"
  else
    _c="user"
  fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
  # Report a real idle->working->idle cycle around the submission, exactly
  # like a real harness's agent_status - this is the signal
  # fm_backend_herdr_send_text_submit now confirms against. The 0.6s "working"
  # window comfortably covers the daemon's FM_INJECT_CONFIRM_SLEEP=0.5
  # per-attempt budget used by the scenarios below.
  report_agent_state working
  sleep 0.6
  report_agent_state idle
}

redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then
    submit_line
    continue
  fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"

fm_backend_herdr_send_text_line "$SUPERVISOR_TARGET" "bash '$LOOP_SCRIPT' '$LOG_FILE'" \
  || fail "could not start the supervisor-loop script in the scratch herdr pane"
sleep 1  # let the loop start and settle


wait_daemon_started() {
  local label=${1:-daemon} start_line=${2:-0} i=0 new_log
  while [ "$i" -lt 30 ]; do
    new_log=$(tail -n +"$((start_line + 1))" "$STATE_DIR/.supervise-daemon.log" 2>/dev/null || true)
    if printf '%s\n' "$new_log" | grep -q 'backend=herdr'; then
      [ -f "$STATE_DIR/.supervise-daemon.pid" ] || fail "$label startup log recorded backend=herdr but no pid file was written"
      kill -0 "$DAEMON_PID" 2>/dev/null || fail "$label exited after recording backend=herdr"
      return 0
    fi
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
      echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
      fail "$label exited before recording backend=herdr: $(cat "$STATE_DIR/.supervise-daemon.log" 2>/dev/null)"
    fi
    sleep 0.2
    i=$((i + 1))
  done
  echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
  fail "$label did not record backend=herdr after 6s: $new_log"
}

start_daemon() {
  local log_start=0
  [ ! -f "$STATE_DIR/.supervise-daemon.log" ] || log_start=$(wc -l < "$STATE_DIR/.supervise-daemon.log")
  HERDR_SESSION="$SESSION" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_BACKEND=herdr \
  FM_SUPERVISOR_HARNESS=pi \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_TARGET" \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.5 \
  FM_INJECT_CONFIRM_RETRIES=6 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  wait_daemon_started daemon "$log_start"
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

reset_state() {
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.watcher-down* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         2>/dev/null || true
  : > "$LOG_FILE"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify pane_input_pending (dispatched through fm_backend_composer_state for
# backend=herdr) can detect typed text in THIS real herdr environment before
# trusting the scenarios below to prove anything.

selfcheck_pane_input_pending() {
  local check_text="selfcheck-marker-12345"
  fm_backend_herdr_send_literal "$SUPERVISOR_TARGET" "$check_text" \
    || fail "selfcheck: could not send literal text to the scratch pane"
  sleep 0.5
  if HERDR_SESSION="$SESSION" pane_input_pending "$SUPERVISOR_TARGET" herdr; then
    fm_backend_herdr_send_key "$SUPERVISOR_TARGET" Enter
    sleep 0.5
    return 0
  fi
  echo "pane_input_pending cannot detect typed text in this real-herdr environment" >&2
  fm_backend_herdr_capture "$SUPERVISOR_TARGET" 10 | sed 's/^/    /' >&2
  fm_backend_herdr_send_key "$SUPERVISOR_TARGET" Enter
  fail "pane_input_pending self-check failed against real herdr"
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  fm_backend_herdr_send_literal "$SUPERVISOR_TARGET" "human draft text"
  sleep 0.5

  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"

  sleep 8

  if grep -q 'Supervisor escalate' "$LOG_FILE"; then
    fail "Scenario A: daemon injected while the herdr pane had pending input"
  fi
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" 2>/dev/null || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario A: human text and digest were merged into one line"
  fi

  fm_backend_herdr_send_key "$SUPERVISOR_TARGET" Enter
  sleep 0.5

  sleep 8

  grep -q 'human draft text' "$LOG_FILE" \
    || fail "Scenario A: human text not in log after submit"
  [ -s "$STATE_DIR/.subsuper-escalations" ] \
    || fail "Scenario A: the pending-then-idle composer lost the deferred escalation"
  if grep -q 'Supervisor escalate' "$LOG_FILE"; then
    fail "Scenario A: daemon injected after the human draft was cleared"
  fi
  if grep -q 'human draft text.*Supervisor escalate' "$LOG_FILE" || \
     grep -q 'Supervisor escalate.*human draft text' "$LOG_FILE"; then
    fail "Scenario A: human text and digest merged into one line (after idle)"
  fi

  local human_line
  human_line=$(grep 'human draft text' "$LOG_FILE" | head -1)
  case "$human_line" in
    *user) ;;
    *) fail "Scenario A: human text misclassified (expected user): $human_line" ;;
  esac

  stop_daemon
  pass "real herdr Scenario A: pending input defers, and a later empty composer still preserves the digest without typing"
}

# --- Scenario B: empty composer without atomic admission ---------------------

test_scenario_b_atomic_admission_unavailable() {
  reset_state
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"
  sleep 8

  [ ! -s "$LOG_FILE" ] \
    || fail "Scenario B: Herdr submitted text despite lacking atomic composer admission"
  [ -s "$STATE_DIR/.subsuper-escalations" ] \
    || fail "Scenario B: atomic-admission deferral lost the escalation"
  grep -F "Herdr API has no verified atomic composer admission; no text typed" \
    "$STATE_DIR/.supervise-daemon.log" >/dev/null \
    || fail "Scenario B: atomic-admission deferral was not recorded truthfully"

  stop_daemon
  pass "real herdr Scenario B: an idle composer has no typed supervisor injection without atomic admission"
}


# --- Scenario D: max-defer alarm on a persistently non-clearing composer -----
# A pending composer that NEVER clears (every Enter attempt leaves real text
# behind) must never be silently swallowed: the daemon must alarm (write
# state/.subsuper-inject-wedged) while preserving the buffered escalation, and
# must never crash or hot-loop. Exercises fm_backend_composer_state(herdr, ...)
# reporting "pending" indefinitely through the REAL structural border reader.

test_scenario_d_max_defer() {
  reset_state
  afk_enter "$STATE_DIR"
  local log_start=0
  [ ! -f "$STATE_DIR/.supervise-daemon.log" ] || log_start=$(wc -l < "$STATE_DIR/.supervise-daemon.log")
  # Persistent-pending composer: type real text and never submit it, so every
  # composer read is genuinely "pending" against the real herdr binary.
  fm_backend_herdr_send_literal "$SUPERVISOR_TARGET" "stuck-in-the-box"
  sleep 0.5

  HERDR_SESSION="$SESSION" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_BACKEND=herdr \
  FM_SUPERVISOR_HARNESS=pi \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_TARGET" \
  FM_ESCALATE_BATCH_SECS=99999 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_MAX_DEFER_SECS=3 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=2 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  wait_daemon_started "Scenario D daemon" "$log_start"

  echo "needs-decision: pick A or B" > "$STATE_DIR/fake-c1.status"

  sleep 12

  [ -s "$STATE_DIR/.subsuper-inject-wedged" ] \
    || fail "Scenario D: a persistently pending real herdr composer never raised the max-defer wedge alarm"
  [ -s "$STATE_DIR/.subsuper-escalations" ] \
    || fail "Scenario D: the buffered escalation was lost instead of preserved during the wedge"
  if grep -q 'Supervisor escalate' "$LOG_FILE" 2>/dev/null; then
    fail "Scenario D: a digest was somehow logged as submitted despite the composer never clearing"
  fi
  kill -0 "$DAEMON_PID" 2>/dev/null || fail "Scenario D: the daemon process died instead of alarming and continuing"
  grep -F 'stuck-in-the-box' "$STATE_DIR/daemon.err" >/dev/null 2>&1 && : # not fatal either way

  stop_daemon
  # Clean up the stuck composer text for a tidy teardown (best-effort).
  fm_backend_herdr_send_key "$SUPERVISOR_TARGET" C-c >/dev/null 2>&1 || true
  pass "real herdr Scenario D: a persistently pending composer raises the max-defer wedge alarm, preserves the buffer, and never crashes the daemon"
}

test_scenario_a
test_scenario_b_atomic_admission_unavailable
test_scenario_d_max_defer

echo "all real-herdr afk injection e2e tests passed"

fm_backend_herdr_kill "$SUPERVISOR_TARGET" 2>/dev/null || true
fm_backend_herdr_kill "$SESSION:$FAKE_CREW_PANE_ID" 2>/dev/null || true
cleanup_all || exit 1
