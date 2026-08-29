#!/usr/bin/env bash
# tests/fm-trace-context-lib.test.sh - unit tests for the native, default-off
# W3C trace-context library (bin/fm-trace-context-lib.sh) plus an isolated spawn
# fixture that exercises Herdr's launch command and secondmate inheritance.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

VALID='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'

# --- strict W3C validation ---------------------------------------------------

fm_trace_context_valid "$VALID" || fail "a conformant traceparent must validate"
pass "fm_trace_context_valid accepts a conformant W3C traceparent"

for bad in \
  '00-00000000000000000000000000000000-00f067aa0ba902b7-01' \
  '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01' \
  'ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  '00-4BF92F3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  '00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01' \
  '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7' \
  '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01; rm -rf /' \
  '' ; do
  if fm_trace_context_valid "$bad"; then
    fail "invalid traceparent wrongly accepted: '$bad'"
  fi
done
pass "fm_trace_context_valid rejects all-zero ids, ff version, uppercase, wrong length, missing field, shell metacharacters, and empty"

# A value shaped like a command substitution must be rejected as inert data and
# never executed. Assemble it so the test itself never runs it.
dollar='$'
fm_trace_context_valid "${dollar}(touch pwned-$$)" && fail "command-substitution-shaped value wrongly accepted"
[ ! -e "pwned-$$" ] || fail "validation must never execute an injected value"
pass "a command-substitution-shaped value is rejected as inert data, never executed"

# --- entropy source: exact length, hex-only, fresh each call -----------------

t=$(fm_trace_context_hex 16)
[ "${#t}" -eq 32 ] || fail "16-byte hex must be 32 chars, got ${#t}"
case "$t" in *[!0-9a-f]*) fail "trace hex is not lowercase hex: $t" ;; esac
s=$(fm_trace_context_hex 8)
[ "${#s}" -eq 16 ] || fail "8-byte hex must be 16 chars, got ${#s}"
[ "$(fm_trace_context_hex 8)" != "$(fm_trace_context_hex 8)" ] || fail "hex must be fresh per call"
pass "fm_trace_context_hex yields exact-length lowercase hex, distinct per call"

# --- root mint ---------------------------------------------------------------

ROOT_TP=$(fm_trace_context_mint)
fm_trace_context_valid "$ROOT_TP" || fail "root mint must be a valid traceparent: $ROOT_TP"
[ "${ROOT_TP:53:2}" = "01" ] || fail "root mint must default to sampled flags 01: $ROOT_TP"
[ "${ROOT_TP:3:32}" != "00000000000000000000000000000000" ] || fail "root trace id must be non-zero"
pass "fm_trace_context_mint starts a valid sampled root trace"

# --- every mint roots a distinct trace: no parent-adoption path exists --------
# The trace boundary is each task, so consecutive mints from one process must
# never share a trace id; there is no argument or environment input through
# which a caller could chain them.

SECOND_TP=$(fm_trace_context_mint)
fm_trace_context_valid "$SECOND_TP" || fail "second mint must be a valid traceparent: $SECOND_TP"
[ "${SECOND_TP:3:32}" != "${ROOT_TP:3:32}" ] || fail "every mint must root a distinct trace id"
[ "${SECOND_TP:36:16}" != "${ROOT_TP:36:16}" ] || fail "every mint must carry a distinct span id"
pass "every mint is an unrelated fresh root - one trace per task, no parent adoption"

# --- minted-root shape --------------------------------------------------------
# A firstmate-MINTED root is exactly the fixed 55-char W3C form with random ids
# and no free-form field where firstmate could originate a prompt, path, or
# secret (that the lib reads no task prose is asserted separately below). With
# no inherited-context path, every carrier the lib yields is either such a mint
# or the same task's previously recorded carrier reused verbatim.
case "$ROOT_TP" in
  *[!0-9a-f-]*) fail "a minted traceparent must contain only hex and hyphens: $ROOT_TP" ;;
esac
[ "${#ROOT_TP}" -eq 55 ] || fail "a minted traceparent is exactly 55 chars, got ${#ROOT_TP}"
pass "a minted root is the fixed 55-char W3C form (hex and hyphens only), so firstmate originates no free-form content in the carrier"

# --- enablement precedence ---------------------------------------------------

WORK=$(fm_test_tmproot fm-trace-context)
CFG_ON="$WORK/cfg-on"; CFG_OFF="$WORK/cfg-off"
mkdir -p "$CFG_ON" "$CFG_OFF"
: > "$CFG_ON/trace-context"

unset FM_TRACE_CONTEXT
fm_trace_context_enabled "$CFG_OFF" && fail "absent config/trace-context must be off by default"
fm_trace_context_enabled "$CFG_ON" || fail "present config/trace-context must enable"
FM_TRACE_CONTEXT=off fm_trace_context_enabled "$CFG_ON" && fail "FM_TRACE_CONTEXT=off must override a present file"
FM_TRACE_CONTEXT=on fm_trace_context_enabled "$CFG_OFF" || fail "FM_TRACE_CONTEXT=on must override an absent file"
FM_TRACE_CONTEXT=1 fm_trace_context_enabled "$CFG_OFF" || fail "FM_TRACE_CONTEXT=1 must enable"
FM_TRACE_CONTEXT=maybe fm_trace_context_enabled "$CFG_ON" && fail "a non-truthy FM_TRACE_CONTEXT must disable"
FM_TRACE_CONTEXT='' fm_trace_context_enabled "$CFG_ON" || fail "empty FM_TRACE_CONTEXT must defer to a present file (enabled)"
FM_TRACE_CONTEXT='' fm_trace_context_enabled "$CFG_OFF" && fail "empty FM_TRACE_CONTEXT must defer to an absent file (disabled)"
pass "enablement is default-off; FM_TRACE_CONTEXT overrides with truthy/other precedence, and unset or empty defers to config/trace-context"

SESSION_DIR="$WORK/session-state"
SESSION_STATE="$SESSION_DIR/.trace-context-effective"
mkdir -p "$SESSION_DIR"
printf '101\n' > "$SESSION_DIR/.lock"
FM_TRACE_CONTEXT=off fm_trace_context_session_start "$CFG_ON" "$SESSION_STATE"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = off ] \
  || fail "session state must freeze an env-off override over a present config file"
FM_TRACE_CONTEXT=on fm_trace_context_session_start "$CFG_OFF" "$SESSION_STATE"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = on ] \
  || fail "a new session state must freeze an env-on override over an absent config file"
pass "session start normalizes config and environment precedence into frozen on/off state"

printf '100 on\n' > "$SESSION_STATE"
chmod 0400 "$SESSION_STATE"
FM_TRACE_CONTEXT=off fm_trace_context_session_start "$CFG_ON" "$SESSION_STATE"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = off ] \
  || fail "atomic publication must replace a read-only stale on record with the current off decision"
[ "$(cat "$SESSION_STATE")" = "101 off" ] \
  || fail "session publication must bind the normalized decision to the current lock (got '$(cat "$SESSION_STATE")')"
pass "session state is atomically published through a same-directory replacement"

FM_TRACE_CONTEXT=on fm_trace_context_session_start "$CFG_OFF" "$SESSION_STATE"
printf '202\n' > "$SESSION_DIR/.lock"
chmod 0500 "$SESSION_DIR"
FM_TRACE_CONTEXT=off fm_trace_context_session_start "$CFG_ON" "$SESSION_STATE"
chmod 0700 "$SESSION_DIR"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = off ] \
  || fail "a failed publication must not reactivate the prior session's on decision"
pass "a stale on record is inactive when publication fails in a new locked session"

printf '202 invalid\n' > "$SESSION_STATE"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = off ] \
  || fail "invalid session state must fail independent and default off"
rm "$SESSION_STATE"
[ "$(fm_trace_context_session_effective "$SESSION_STATE")" = off ] \
  || fail "missing session state must fail independent and default off"
pass "missing or invalid frozen session state defaults off"

# --- resolve: default-off omits; enabled mints ------------------------------

NOMETA="$WORK/none.meta"
out=$(fm_trace_context_resolve "$CFG_OFF" "$NOMETA"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] || fail "default-off resolve must omit and return 0 (got rc=$rc out='$out')"
pass "resolve omits the carrier and returns success when the capability is off (byte-identical default)"

out=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_OFF" "$NOMETA")
fm_trace_context_valid "$out" || fail "enabled resolve must mint a valid traceparent: $out"
pass "resolve mints a valid traceparent when enabled"

# --- secondmate home-session boundary ---------------------------------------
# fm-spawn launches every Secondmate with the primary session's non-empty frozen
# FM_TRACE_CONTEXT decision. The Secondmate resolves it at its own session start.
# Its own launch-time TRACEPARENT stays in its process environment for its whole
# life, but that is the Secondmate's agent identity, never a parent: every task
# it spawns must root a fresh trace, or unrelated routed tasks would accumulate
# into one ever-growing trace per Secondmate.
PRIMARY_TP='00-abcabcabcabcabcabcabcabcabcabcab-1212121212121212-01'
saved_tp=${TRACEPARENT-__unset__}
unset TRACEPARENT
frozen_off=$(FM_TRACE_CONTEXT=off fm_trace_context_resolve "$CFG_ON" "$WORK/sm-frozen-off.meta")
[ -z "$frozen_off" ] || fail "a Secondmate launched off must stay disabled even after the config file appears: $frozen_off"
frozen_on=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_OFF" "$WORK/sm-frozen-on.meta")
fm_trace_context_valid "$frozen_on" || fail "a Secondmate launched on must stay enabled even while the config file is absent: $frozen_on"
[ "${frozen_on:3:32}" != "${PRIMARY_TP:3:32}" ] || fail "an enabled Secondmate without an ambient carrier must start a new root"
routed_a=$(TRACEPARENT="$PRIMARY_TP" FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$WORK/sm-routed-a.meta")
routed_b=$(TRACEPARENT="$PRIMARY_TP" FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$WORK/sm-routed-b.meta")
fm_trace_context_valid "$routed_a" || fail "resolving under an ambient TRACEPARENT must still mint a valid carrier (a='$routed_a')"
fm_trace_context_valid "$routed_b" || fail "resolving under an ambient TRACEPARENT must still mint a valid carrier (b='$routed_b')"
[ "${routed_a:3:32}" != "${PRIMARY_TP:3:32}" ] && [ "${routed_b:3:32}" != "${PRIMARY_TP:3:32}" ] \
  || fail "a task resolved under a persistent ambient TRACEPARENT must root its own trace, never adopt it (a='$routed_a' b='$routed_b')"
[ "${routed_a:3:32}" != "${routed_b:3:32}" ] \
  || fail "two tasks resolved from one ambient environment must root distinct traces (a='$routed_a' b='$routed_b')"
[ "$saved_tp" = "__unset__" ] || export TRACEPARENT="$saved_tp"
pass "Secondmate home-session state stays off or on despite later file state; ambient TRACEPARENT is never adopted, so each routed task roots its own trace"

# --- recovery: a recorded value is reused verbatim, disabled still omits -----

REC_META="$WORK/rec.meta"
printf 'kind=ship\ntraceparent=%s\nmode=no-mistakes\n' "$VALID" > "$REC_META"
out=$(TRACEPARENT='00-ffffffffffffffffffffffffffffffff-1111111111111111-01' \
  FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$REC_META")
[ "$out" = "$VALID" ] || fail "recovery must reuse the recorded traceparent verbatim, ignoring the ambient environment (got '$out')"
pass "resolve reuses a valid recorded traceparent verbatim on relaunch (stable identity across restarts)"

out=$(fm_trace_context_resolve "$CFG_OFF" "$REC_META")
[ -z "$out" ] || fail "a disabled home must omit even when a traceparent is already recorded (got '$out')"
pass "disabling the capability omits the carrier even for a task with a recorded identity"

CORRUPT_META="$WORK/corrupt.meta"
printf 'traceparent=not-a-valid-traceparent\n' > "$CORRUPT_META"
out=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$CORRUPT_META")
fm_trace_context_valid "$out" || fail "a corrupt recorded value must be re-minted to a valid one"
[ "$out" != "not-a-valid-traceparent" ] || fail "a corrupt recorded value must not be reused"
pass "a corrupt recorded traceparent is re-minted rather than propagated"

# --- durable metadata consistency: one value for record and injection --------

out=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$NOMETA")
fm_trace_context_valid "$out" || fail "resolve must yield a single valid carrier per call"
pass "resolve yields exactly one carrier per logical task, so the recorded and injected values are identical by construction"

# --- entropy failure omits telemetry safely (never aborts) -------------------

fm_trace_context_hex() { return 1; }
ef_mint=$(fm_trace_context_mint); ef_mint_rc=$?
ef_res=$(FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$NOMETA"); ef_res_rc=$?
# Restore the real entropy source for any later use.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
[ -z "$ef_mint" ] && [ "$ef_mint_rc" -ne 0 ] || fail "mint must omit and report failure on entropy failure (rc=$ef_mint_rc out='$ef_mint')"
[ -z "$ef_res" ] && [ "$ef_res_rc" -eq 0 ] || fail "resolve must omit and STILL return 0 on entropy failure (rc=$ef_res_rc out='$ef_res')"
pass "entropy failure omits telemetry safely: mint reports failure, resolve returns success with no carrier"

# --- fail-independent timing: no hang source, always returns 0 ---------------

TRACE_TOOL_LOG="$WORK/trace-tools.log"
TRACE_FAKEBIN="$WORK/trace-fakebin"
mkdir -p "$TRACE_FAKEBIN"
for tool in sleep timeout trace-context-provider; do
  cat > "$TRACE_FAKEBIN/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >> "${FM_TRACE_TOOL_LOG:?}"
exit 70
SH
  chmod +x "$TRACE_FAKEBIN/$tool"
done
fm_trace_context_hex() {
  case "$1" in
    16) printf '%s' 11111111111111111111111111111111 ;;
    8) printf '%s' 2222222222222222 ;;
    *) return 1 ;;
  esac
}
FIXED_TP='00-11111111111111111111111111111111-2222222222222222-01'
TRACE_START_MS=$(node -e 'process.stdout.write(String(Date.now()))')
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  out=$(PATH="$TRACE_FAKEBIN:$PATH" FM_TRACE_TOOL_LOG="$TRACE_TOOL_LOG" \
    FM_TRACE_CONTEXT_COMMAND="$TRACE_FAKEBIN/trace-context-provider" \
    FM_TRACE_CONTEXT_PROVIDER="$TRACE_FAKEBIN/trace-context-provider" \
    FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$NOMETA"); rc=$?
done
TRACE_END_MS=$(node -e 'process.stdout.write(String(Date.now()))')
TRACE_ELAPSED_MS=$((TRACE_END_MS - TRACE_START_MS))
fm_trace_context_valid "$out" || fail "resolve must mint without a sleep, timeout, or configurable provider (rc=$rc out='$out')"
[ "$rc" -eq 0 ] || fail "resolve must return 0 when enabled"
[ "$TRACE_ELAPSED_MS" -lt 500 ] \
  || fail "20 fixed-entropy resolves must complete without delay (elapsed=${TRACE_ELAPSED_MS}ms)"
[ ! -s "$TRACE_TOOL_LOG" ] || fail "resolve must not invoke a sleep, timeout, or configurable provider (called '$(tr '\n' ' ' < "$TRACE_TOOL_LOG")')"
fm_trace_context_resolve "$CFG_OFF" "$NOMETA" >/dev/null || fail "resolve must return 0 when off"
pass "the resolver returns directly without sleep, timeout, or configurable-provider dependencies and always succeeds"

# --- harness/backend/kind and task-prose independence ------------------------

BRIEF_FILE="$WORK/brief"; PROMPT_FILE="$WORK/prompt"
REPORT_FILE="$WORK/report"; STATUS_FILE="$WORK/status"
mkfifo "$BRIEF_FILE" "$PROMPT_FILE" "$REPORT_FILE" "$STATUS_FILE"
for axes in \
  'claude tmux ship' \
  'codex herdr scout' \
  'opencode zellij secondmate' \
  'grok orca ship' \
  'kimi cmux scout'; do
  IFS=' ' read -r harness backend kind <<EOF
$axes
EOF
  TRACE_WRITER_PIDS=
  for prose_file in "$BRIEF_FILE" "$PROMPT_FILE" "$REPORT_FILE" "$STATUS_FILE"; do
    ( /bin/sleep 1; printf '%s\n' 'task-prose-read' > "$prose_file" ) &
    TRACE_WRITER_PIDS="$TRACE_WRITER_PIDS $!"
  done
  TRACE_START_MS=$(node -e 'process.stdout.write(String(Date.now()))')
  out=$(HARNESS="$harness" BACKEND="$backend" KIND="$kind" \
    FM_CREW_HARNESS="$harness" FM_BACKEND="$backend" FM_TASK_KIND="$kind" \
    BRIEF="$BRIEF_FILE" PROMPT="$PROMPT_FILE" REPORT="$REPORT_FILE" STATUS="$STATUS_FILE" \
    FM_BRIEF="$BRIEF_FILE" FM_PROMPT="$PROMPT_FILE" FM_REPORT="$REPORT_FILE" FM_STATUS="$STATUS_FILE" \
    FM_TRACE_CONTEXT=on fm_trace_context_resolve "$CFG_ON" "$NOMETA")
  TRACE_END_MS=$(node -e 'process.stdout.write(String(Date.now()))')
  for writer_pid in $TRACE_WRITER_PIDS; do
    kill "$writer_pid" 2>/dev/null || true
    wait "$writer_pid" 2>/dev/null || true
  done
  TRACE_ELAPSED_MS=$((TRACE_END_MS - TRACE_START_MS))
  [ "$TRACE_ELAPSED_MS" -lt 500 ] \
    || fail "harness=$harness backend=$backend kind=$kind read a blocking task-prose fixture or delayed (elapsed=${TRACE_ELAPSED_MS}ms)"
  [ "$out" = "$FIXED_TP" ] \
    || fail "harness=$harness backend=$backend kind=$kind or task prose changed the fixed-entropy carrier (got '$out')"
done
# Restore the real entropy source for the launch fixture below.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
pass "controlled entropy yields the same carrier across harnesses, backends, spawn kinds, and task-prose fixtures"

# --- executable Herdr launch wiring ------------------------------------------

make_trace_spawn_herdr_fixture() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_HERDR_LOG:?}
state=${FM_FAKE_HERDR_STATE:?}
project=${FM_FAKE_PROJECT:?}
worktree=${FM_FAKE_WORKTREE:?}
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$log"

case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.7.5","protocol":14},"server":{"running":true}}'
    ;;
  "server")
    ;;
  "workspace list")
    if [ -e "$state/workspace" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"ws1","label":"firstmate"}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[]}}'
    fi
    ;;
  "workspace create")
    : > "$state/workspace"
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"ws1","label":"firstmate"},"tab":{"tab_id":"seed-tab"},"root_pane":{"pane_id":"seed-pane"}}}'
    ;;
  "tab list")
    if [ -e "$state/task" ]; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"seed-tab","label":"1"},{"tab_id":"task-tab","label":"fm-trace-herdr"}]}}'
    else
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"seed-tab","label":"1"}]}}'
    fi
    ;;
  "tab create")
    : > "$state/task"
    printf '%s\n' '{"result":{"tab":{"tab_id":"task-tab"},"root_pane":{"pane_id":"task-pane"}}}'
    ;;
  "pane list")
    if [ -e "$state/task" ]; then
      printf '%s\n' '{"result":{"panes":[{"pane_id":"seed-pane","tab_id":"seed-tab"},{"pane_id":"task-pane","tab_id":"task-tab"}]}}'
    else
      printf '%s\n' '{"result":{"panes":[{"pane_id":"seed-pane","tab_id":"seed-tab"}]}}'
    fi
    ;;
  "pane get")
    pane=${3:-}
    if [ "$pane" = seed-pane ]; then
      cwd=$project
      tab=seed-tab
    else
      cwd=$project
      tab=task-tab
      [ -e "$state/ready" ] && cwd=$worktree
    fi
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"ws1","foreground_cwd":"%s"}}}\n' "$pane" "$tab" "$cwd"
    ;;
  "pane process-info")
    pane=${4:-}
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"bash","argv0":"bash"}]}}}\n' "$pane"
    ;;
  "pane run")
    pane=${3:-}
    payload=${4:-}
    case "$payload" in
      *fm-treehouse-get.sh*--ready-file*)
        ready_file=${payload##* --ready-file }
        ready_file=${ready_file%% *}
        printf '%s\n' "$worktree" > "$ready_file"
        : > "$state/ready"
        ;;
      *)
        bash -c "$payload"
        ;;
    esac
    ;;
  "pane close")
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}'
    ;;
esac
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-axo pid=,ppid=") printf '%s\n' '4242 1' ;;
  "-p 4242 -o stat=") printf '%s\n' 'S' ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_herdr_spawn_executes_one_atomic_launch_with_trace_context() {
  local dir home project worktree fakebin state log ps_bin side_effect id out status meta tp observed run_count launch_payload unit_separator
  dir="$WORK/herdr-spawn"
  home="$dir/home"
  project="$dir/project"
  worktree="$dir/worktree"
  state="$dir/herdr-state"
  log="$dir/herdr.log"
  ps_bin="$dir/ps-bin"
  side_effect="$dir/launch-side-effect"
  id=trace-herdr
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects" "$state"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$$ on" > "$home/state/.trace-context-effective"
  : > "$home/config/trace-context"
  printf 'launch brief\n' > "$home/data/$id/brief.md"
  printf '# fake firstmate home\n' > "$home/AGENTS.md"
  mkdir -p "$home/bin"
  fm_git_worktree "$project" "$worktree" trace-herdr
  cat > "$side_effect" <<'SH'
#!/usr/bin/env bash
set -u
printf 'GOTMPDIR=%s\nTRACEPARENT=%s\n' "${GOTMPDIR:-}" "${TRACEPARENT:-}" > "${FM_TRACE_SPAWN_OBSERVED:?}"
SH
  chmod +x "$side_effect"
  fakebin=$(make_trace_spawn_herdr_fixture "$dir")
  : > "$log"
  : > "$ps_bin"
  cp "$fakebin/ps" "$ps_bin"
  chmod +x "$ps_bin"

  out=$(env -u FM_TRACE_CONTEXT -u HERDR_ENV -u HERDR_PANE_ID \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 HERDR_SESSION=trace-fixture \
    FM_HERDR_LOG="$log" FM_FAKE_HERDR_STATE="$state" \
    FM_FAKE_PROJECT="$project" FM_FAKE_WORKTREE="$worktree" \
    FM_HERDR_PS_BIN="$ps_bin" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    FM_TRACE_SPAWN_OBSERVED="$dir/observed" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "env $side_effect" --backend herdr \
    --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "the Herdr-backed spawn should succeed"
  assert_contains "$out" "spawned $id" "the Herdr-backed spawn should report success"
  meta="$home/state/$id.meta"
  tp=$(sed -n 's/^traceparent=//p' "$meta")
  fm_trace_context_valid "$tp" || fail "the executable Herdr spawn must record a valid carrier (got '$tp')"
  observed=$(cat "$dir/observed")
  assert_contains "$observed" "TRACEPARENT=$tp" "the launched command must receive the recorded carrier"
  assert_contains "$observed" "GOTMPDIR=/tmp/fm-$id/gotmp" "the launched command must receive the task GOTMPDIR"
  unit_separator=$'\x1f'
  run_count=$(awk -F "$unit_separator" '$2 == "pane" && $3 == "run" { count += 1 } END { print count + 0 }' "$log")
  [ "$run_count" -eq 2 ] || fail "Herdr must submit treehouse setup and launch through two pane run calls (got $run_count)"
  launch_payload=$(awk -F "$unit_separator" '$2 == "pane" && $3 == "run" && $5 !~ /fm-treehouse-get.sh/ { print $5; exit }' "$log")
  assert_contains "$launch_payload" "GOTMPDIR=" "the recorded Herdr launch command must bind GOTMPDIR"
  assert_contains "$launch_payload" "TRACEPARENT=" "the recorded Herdr launch command must bind TRACEPARENT"
  pass "an executable Herdr spawn records metadata and executes one atomic trace-aware launch"
}

test_herdr_spawn_executes_one_atomic_launch_with_trace_context

# --- secondmate inheritance wires the nested chain ---------------------------

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"
case " $FM_INHERITABLE_CONFIG " in
  *" trace-context "*) : ;;
  *) fail "config/trace-context must be in FM_INHERITABLE_CONFIG so secondmate homes stay traced" ;;
esac
pass "config/trace-context is inherited into secondmate homes, keeping the nested chain enabled end to end"

echo "# fm-trace-context-lib.test.sh: all assertions passed"
