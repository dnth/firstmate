#!/usr/bin/env bash
# Opt-in live guard for fm-control.sh switch-model against a REAL OMP worker in
# a guarded, non-default Herdr lab. It is the proof that the OMP behaviours the
# portable tests assume are true of the installed OMP:
#   - setModel while idle takes effect for the NEXT turn, and a switch requested
#     mid-run waits for the run to settle: the in-flight run stays on the old
#     model and the next turn runs on the new one (the session's own message
#     order shows it);
#   - the switch is session-only: the global ~/.omp config files do not change;
#   - a model the session has no credentials for is told apart from an unknown
#     one, through the registry the real OMP exposes;
#   - the documented OMP resume path restores the switched model.
# Run it after every OMP upgrade; docs/verification/runtime-backends.md records
# the dated result.
#
#   FM_OMP_MODEL_SWITCH_LIVE_E2E=1 bash tests/fm-omp-model-switch-live-e2e.test.sh
#
# It drives Firstmate from an explicit Git revision (default HEAD,
# FM_OMP_MODEL_SWITCH_LIVE_REV), so commit the change under review first. It
# spends five one-line model turns. FM_OMP_MODEL_SWITCH_LIVE_FROM and _TO name
# two authenticated models (`omp models`); the defaults are inexpensive and the
# TO model must support the thinking level in FM_OMP_MODEL_SWITCH_LIVE_TO_EFFORT.
set -u

if [ "${FM_OMP_MODEL_SWITCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_MODEL_SWITCH_LIVE_E2E=1 to run the real-OMP model-switch guard in a guarded Herdr lab"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v omp >/dev/null 2>&1 || fail "omp not found"
command -v herdr >/dev/null 2>&1 || fail "herdr not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v treehouse >/dev/null 2>&1 || fail "treehouse not found"

FROM=${FM_OMP_MODEL_SWITCH_LIVE_FROM:-opencode-go/deepseek-v4.1-flash}
TO=${FM_OMP_MODEL_SWITCH_LIVE_TO:-opencode-go/qwen3.8-flash}
FROM_EFFORT=${FM_OMP_MODEL_SWITCH_LIVE_FROM_EFFORT:-low}
TO_EFFORT=${FM_OMP_MODEL_SWITCH_LIVE_TO_EFFORT:-medium}
UNAUTHENTICATED=${FM_OMP_MODEL_SWITCH_LIVE_UNAUTHENTICATED:-abliteration/abliterated-model}

# The global OMP configuration the switch must never rewrite.
OMP_AGENT_DIR=${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}
config_fingerprint() {
  local f digest
  for f in "$OMP_AGENT_DIR/config.yml" "$OMP_AGENT_DIR/models.yml"; do
    [ -f "$f" ] || continue
    digest=$(sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") || return 1
    printf '%s %s\n' "${digest%% *}" "$f"
  done
}
CONFIG_BEFORE=$(config_fingerprint) || fail "could not fingerprint the global OMP config"
[ -n "$CONFIG_BEFORE" ] || echo "note: no global OMP config.yml or models.yml found under $OMP_AGENT_DIR; the unchanged-config check has nothing to compare"

LAB=$(fm_test_tmproot fm-omp-model-switch-live)
DRIVER_ROOT="$LAB/driver-root"
REVISION=${FM_OMP_MODEL_SWITCH_LIVE_REV:-HEAD}
REVISION_SHA=$(git -C "$ROOT" rev-parse --verify --quiet "$REVISION^{commit}") \
  || fail "FM_OMP_MODEL_SWITCH_LIVE_REV '$REVISION' is not a commit"
mkdir -p "$DRIVER_ROOT"
( set -o pipefail; git -C "$ROOT" archive "$REVISION_SHA" | tar -x -C "$DRIVER_ROOT" ) \
  || fail "could not extract the selected revision $REVISION_SHA"
printf '# model-switch live guard drives revision %s\n' "$REVISION_SHA"
git init -q -b main "$DRIVER_ROOT" || fail "could not initialize the archived driver root"
fm_git_identity fmtest fmtest@example.invalid
git -C "$DRIVER_ROOT" add . && git -C "$DRIVER_ROOT" commit -qm init \
  || fail "could not register the archived driver root"

# shellcheck source=bin/fm-omp-process-lib.sh
. "$DRIVER_ROOT/bin/fm-omp-process-lib.sh"
# shellcheck source=bin/backends/herdr.sh
FM_ROOT_OVERRIDE="$DRIVER_ROOT" . "$DRIVER_ROOT/bin/backends/herdr.sh"

OMP_BIN=$(FM_ROOT_OVERRIDE="$DRIVER_ROOT" "$DRIVER_ROOT/bin/fm-omp-capabilities.sh" --print-binary) || fail "OMP capability check failed"
OMP_BIN=$(fm_test_realpath "$OMP_BIN") || fail "OMP binary realpath could not be resolved"
OMP_LAUNCH_IDENTITY=$(fm_omp_process_launch_identity "$OMP_BIN") \
  || fail "OMP launch identity could not be resolved for $OMP_BIN"
OMP_RUNTIME=$(printf '%s\n' "$OMP_LAUNCH_IDENTITY" | sed -n '1p')
OMP_BIN=$(printf '%s\n' "$OMP_LAUNCH_IDENTITY" | sed -n '2p')
OMP_VERSION=$(omp --version 2>&1 | head -1)
REAL_HERDR=$(command -v herdr)
HERDR_LAB_HELPER="$DRIVER_ROOT/bin/fm-herdr-lab.sh"
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"

SESSION=$("$HERDR_LAB_HELPER" name omp-model-switch) || fail "could not generate a guarded Herdr lab session name"
WRAPPER_BIN="$LAB/bin"
WRAPPER_LOG="$LAB/herdr-wrapper.log"
BASE_PATH=$PATH
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
WORKER_ID="omp-model-switch-$$"
WORKER_WT=
TEARDOWN_DONE=0

cleanup_worktree() { # <path>
  local wt=$1 project_head wt_head
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || return 1
  project_head=$(git -C "$PROJECT" rev-parse HEAD 2>/dev/null || true)
  wt_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
  [ -n "$project_head" ] && [ "$project_head" = "$wt_head" ] || return 1
  ( cd "$PROJECT" && treehouse return --force "$wt" ) >/dev/null 2>&1
}

cleanup() {
  local cleanup_ok=1
  if [ "${FM_OMP_MODEL_SWITCH_KEEP_FAILED:-0}" = 1 ] && [ "$TEARDOWN_DONE" -ne 1 ]; then
    echo "diagnostic: preserving failed lab $SESSION at $LAB" >&2
    return
  fi
  if [ "$TEARDOWN_DONE" -ne 1 ]; then
    FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
      "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || cleanup_ok=0
  fi
  cleanup_worktree "$WORKER_WT" || cleanup_ok=0
  if [ "$cleanup_ok" -eq 1 ]; then
    rm -rf "/tmp/fm-$WORKER_ID" "$LAB"
  else
    echo "not ok - model-switch lab cleanup incomplete; preserving $LAB and its task root" >&2
    trap - EXIT
    exit 1
  fi
}
trap cleanup EXIT

mkdir -p "$WRAPPER_BIN" "$PROJECT" "$DRIVER_ROOT" "$HOME_DIR/data/$WORKER_ID" \
  "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
: > "$WRAPPER_LOG"
cat > "$WRAPPER_BIN/herdr" <<SH
#!/usr/bin/env bash
set -u
real='$REAL_HERDR'
helper='$HERDR_LAB_HELPER'
session='$SESSION'
base_path='$BASE_PATH'
wrapper_bin='$WRAPPER_BIN'
log='$WRAPPER_LOG'
omp_bin='$OMP_BIN'
omp_runtime='$OMP_RUNTIME'
process_lib='$DRIVER_ROOT/bin/fm-omp-process-lib.sh'
if [ "\${FM_HERDR_LAB_INNER:-0}" = 1 ]; then
  if [ "\${1:-}" = server ]; then
    exec env -u FM_HERDR_LAB_INNER "\$real" "\$@"
  fi
  exec "\$real" "\$@"
fi
case "\${1:-}" in
  --version|-V|version) exec "\$real" "\$@" ;;
esac
. "\$process_lib"
# OMP itself probes Herdr with its own prefix-session syntax. Those calls are
# outside Firstmate's backend API and cannot satisfy this lab's trailing-session
# contract. Quarantine only the exact observed read-only forms from an exact OMP
# parent and never run them against the server.
parent_args=\$(ps -o args= -p "\$PPID" 2>/dev/null || true)
if [ -e "/proc/\$PPID/exe" ]; then
  parent_exe=\$(readlink -f "/proc/\$PPID/exe" 2>/dev/null || true)
else
  parent_exe=\$(lsof -a -p "\$PPID" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
fi
native_omp_parent=0
if FM_OMP_PROCESS_EXPECTED_BUN="\$omp_runtime" FM_OMP_PROCESS_EXPECTED_BIN="\$omp_bin" \
    fm_omp_process_matches "\$parent_exe" "\$parent_args" "\$PPID"; then
  native_omp_parent=1
fi
if [ "\$native_omp_parent" -eq 1 ]; then
  native_probe=0
  native_probe_pane=
  case "\$#:\$*" in
    "1:agent"|"1:--help"|"2:agent --help"|"2:agent list"|"2:pane read --help"|"3:--session \$session --help") native_probe=1 ;;
    3:agent\ get\ *) native_probe_pane=\$3 ;;
    5:--session\ "\$session"\ agent\ get\ *) native_probe_pane=\$5 ;;
    7:pane\ read\ *\ --source\ recent-unwrapped\ --lines\ *) native_probe_pane=\$3 ;;
    7:agent\ read\ *\ --source\ recent-unwrapped\ --lines\ *)
      case "\$7" in
        ''|0*|*[!0-9]*) ;;
        *) native_probe_pane=\$3 ;;
      esac
      ;;
  esac
  case "\$native_probe_pane" in
    ''|*[!A-Za-z0-9._:@%+-]*) ;;
    *) native_probe=1 ;;
  esac
  if [ "\$native_probe" -eq 1 ]; then
    printf -v rendered '%q ' "\$@"
    printf '%s\n' "\$rendered" >> "\$log.native-omp-probes"
    exit 96
  fi
fi
if [ "\$#" -eq 2 ] && [ "\$1" = status ] && [ "\$2" = --json ] \
  && [ "\${HERDR_SESSION:-}" = "\$session" ]; then
  set -- "\$@" --session "\$session"
fi
case "\$#:\$*" in
  "3:session list --json"|"3:api schema --json") set -- "\$@" --session "\$session" ;;
esac
printf -v rendered '%q ' "\$@"
printf '%s\n' "\$rendered" >> "\$log"
refuse() { # <exit-code> <reason>
  local parent_call
  parent_call=\$(ps -o args= -p "\$PPID" 2>/dev/null || printf 'unreadable')
  printf 'args=%s reason=%s parent=%s\n' "\$rendered" "\$2" "\$parent_call" >> "\$log.callers"
  echo "OMP Herdr fixture refused \$2" >&2
  exit "\$1"
}
argc=\$#
[ "\$argc" -ge 2 ] || refuse 96 "a command without explicit session binding"
args=("\$@")
penultimate=\${args[\$((argc - 2))]}
last=\${args[\$((argc - 1))]}
[ "\$penultimate" = --session ] && [ "\$last" = "\$session" ] \
  || refuse 96 "a command outside its exact lab session"
set -- "\${args[@]:0:\$((argc - 2))}"
case "\${1:-}" in
  server)
    refuse 97 "an unguarded lifecycle command"
    ;;
  session)
    if [ "\$#" -ne 3 ] || [ "\$2" != list ] || [ "\$3" != --json ]; then
      refuse 97 "an unguarded lifecycle command"
    fi
    ;;
esac
exec env FM_HERDR_LAB_INNER=1 PATH="\$wrapper_bin:\$base_path" "\$helper" run "\$session" "\$@"
SH

chmod +x "$WRAPPER_BIN/herdr"

# Launch the server through the guarded helper while giving every pane the
# session-enforcing Herdr wrapper.
FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
  "$HERDR_LAB_HELPER" provision "$SESSION" >/dev/null \
  || fail "could not provision the guarded Herdr model-switch lab"

lab() {
  FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
    "$HERDR_LAB_HELPER" run "$SESSION" "$@"
}

# Firstmate runs here outside Herdr, so its worker lands in the home's own
# labeled workspace. Every ambient launcher identity is stripped so nothing can
# resolve to the captain's own panes.
fm_env() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    -u TMUX -u TMUX_PANE \
    PATH="$WRAPPER_BIN:$BASE_PATH" HERDR_SESSION="$SESSION" \
    OMP_SKIP_SETUP=1 FM_BACKEND=herdr FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$DRIVER_ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    "$@"
}

pane_id() { printf '%s' "${1#*:}"; }

agent_json() {
  lab agent get "$(pane_id "$1")" 2>/dev/null
}

agent_is() { # <target> <identity> <state-pattern>
  local info identity state
  info=$(agent_json "$1" || true)
  identity=$(printf '%s' "$info" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  state=$(printf '%s' "$info" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  [ "$identity" = "$2" ] || return 1
  case " $3 " in *" $state "*) return 0 ;; *) return 1 ;; esac
}

pane_missing() {
  local out
  out=$(lab pane get "$(pane_id "$1")" 2>&1 || true)
  printf '%s' "$out" | jq -e '.error.code == "pane_not_found"' >/dev/null 2>&1
}

display_agent_of() { # <target>
  lab pane get "$(pane_id "$1")" 2>/dev/null | jq -r '.result.pane.display_agent // empty' 2>/dev/null
}

pane_label_is() { # <label>
  [ "$(display_agent_of "$WORKER_TARGET")" = "$1" ]
}

omp_agent_absent() { # <target>
  [ -z "$(agent_json "$1" | jq -r '.result.agent.agent // empty' 2>/dev/null)" ]
}

# The resumed process republishes the ready marker under its own pid.
resumed_channel_active() { # <old-pid>
  local pid
  pid=$(jq -r '.pid // empty' "$REQ_DIR/model-switch.ready" 2>/dev/null)
  [ -n "$pid" ] && [ "$pid" != "$1" ]
}

session_file_for() {
  agent_json "$1" | jq -r 'select(.result.agent.agent_session.kind == "path") | .result.agent.agent_session.value // empty' 2>/dev/null
}

# Offsets are bound with the production boundary owner, so a record being
# appended while the offset is taken can never start a tail mid-record.
session_offset() { # <session-file>
  local offset
  offset=$(FM_ROOT_OVERRIDE="$DRIVER_ROOT" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_omp_session_complete_offset "$1"' \
    "$DRIVER_ROOT" "$1") || {
    printf 'not ok - production offset owner refused a complete JSONL record boundary in %s\n' "$1" >&2
    return 1
  }
  printf '%s' "$offset"
}

entries_after() { # <session-file> <offset>
  tail -c "+$(($2 + 1))" "$1" 2>/dev/null
}

session_has_assistant_reply_after() { # <file> <offset> <text>
  entries_after "$1" "$2" | jq -se --arg reply "$3" '
    any(.[]; .type == "message" and .message.role == "assistant"
      and any(.message.content[]?; .type == "text" and (.text | contains($reply))))' >/dev/null 2>&1
}

session_has_model_change_after() { # <file> <offset> <provider/id>
  entries_after "$1" "$2" | jq -se --arg m "$3" 'any(.[]; .type == "model_change" and .model == $m)' >/dev/null 2>&1
}

# The provider/id of the last assistant message after the offset.
last_assistant_after() { # <file> <offset>
  entries_after "$1" "$2" \
    | jq -sr '[.[] | select(.type == "message" and .message.role == "assistant") | "\(.message.provider)/\(.message.model)"] | last // empty' 2>/dev/null
}

wait_for() { # <description> <command...>
  local description=$1 i=0
  shift
  while [ "$i" -lt 600 ]; do
    "$@" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  fail "timed out waiting for $description"
}

file_exists() { [ -f "$1" ]; }

meta_value() { # <key>
  grep "^$1=" "$HOME_DIR/state/$WORKER_ID.meta" | tail -1 | cut -d= -f2-
}

control() { # <fm-control args...>
  fm_env FM_CONTROL_POLL=0.25 "$DRIVER_ROOT/bin/fm-control.sh" "$WORKER_ID" "$@"
}

send_task() {
  fm_env FM_SEND_SLEEP=0.2 FM_SEND_SETTLE=0 FM_SEND_REMOTE_TYPED=0 "$DRIVER_ROOT/bin/fm-send.sh" "$WORKER_ID" "$@" >/dev/null
}

# --- a real worker through production fm-spawn --------------------------------
printf 'Reply exactly: switch worker ready.\n' > "$HOME_DIR/data/$WORKER_ID/brief.md"
printf '%s\n' '- project [direct-PR] - OMP model-switch live fixture (added 2026-11-23)' > "$HOME_DIR/data/projects.md"
printf 'herdr\n' > "$HOME_DIR/config/backend"
printf 'omp\n' > "$HOME_DIR/config/crew-harness"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
printf 'fixture\n' > "$PROJECT/README.md"
git init -q -b main "$PROJECT"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm init
git init -q --bare "$LAB/project-origin.git"
git -C "$PROJECT" remote add origin "$LAB/project-origin.git"
git -C "$PROJECT" push -qu origin main
git -C "$LAB/project-origin.git" symbolic-ref HEAD refs/heads/main

fm_env FM_SPAWN_NO_GUARD=1 FM_OMP_LAUNCH_ACK_INTERVAL=0.25 \
  "$DRIVER_ROOT/bin/fm-spawn.sh" "$WORKER_ID" "$PROJECT" --harness omp \
    --model "$FROM" --effort "$FROM_EFFORT" --mode direct-PR --yolo off >/dev/null \
  || fail "production OMP Herdr worker spawn failed"
WORKER_META="$HOME_DIR/state/$WORKER_ID.meta"
WORKER_TARGET=$(sed -n 's/^window=//p' "$WORKER_META")
WORKER_WT=$(sed -n 's/^worktree=//p' "$WORKER_META")
WORKER_GEN=$(sed -n 's/^spawn_gen=//p' "$WORKER_META" | tail -1)
REQ_DIR="$HOME_DIR/state/$WORKER_ID.omp-doorbell-ready.requests"
[ -n "$WORKER_WT" ] && [ "$WORKER_WT" != "$PROJECT" ] && [ -d "$WORKER_WT" ] \
  || fail "the worker did not acquire a distinct isolated worktree"
wait_for "worker extension readiness" file_exists "$HOME_DIR/state/$WORKER_ID.omp-ready"
wait_for "worker model-switch channel" file_exists "$REQ_DIR/model-switch.ready"
wait_for "worker first turn" file_exists "$HOME_DIR/state/$WORKER_ID.turn-ended.$WORKER_GEN"
wait_for "exact idle worker identity" agent_is "$WORKER_TARGET" omp 'idle done'
WORKER_SESSION=$(session_file_for "$WORKER_TARGET")
case "$WORKER_SESSION" in "/tmp/fm-$WORKER_ID/omp-sessions/"*.jsonl) ;; *) fail "the worker's Herdr identity did not bind its task-owned session" ;; esac
[ "$(jq -r '.spawnGen' "$REQ_DIR/model-switch.ready")" = "$WORKER_GEN" ] \
  || fail "the ready marker names another worker generation"
[ "$(last_assistant_after "$WORKER_SESSION" 0)" = "$FROM" ] \
  || fail "the worker did not start on $FROM (reads $(last_assistant_after "$WORKER_SESSION" 0))"
pass "live OMP worker spawned on $FROM ($FROM_EFFORT) with its model-switch channel active ($OMP_VERSION)"

# --- AC3: refusals are typed, with the real OMP registry ---------------------
refused=$(control switch-model --model nowhere/not-a-model 2>&1) \
  && fail "an unknown model was not refused: $refused"
case "$refused" in refused\ "$WORKER_ID"\ *reason=unknown-model*meta=unchanged*) ;; *) fail "unknown model was not a typed refusal: $refused" ;; esac
refused=$(control switch-model --model "$UNAUTHENTICATED" 2>&1) \
  && fail "a model without credentials was not refused: $refused"
case "$refused" in refused\ "$WORKER_ID"\ *reason=no-credentials*meta=unchanged*) ;; *) fail "a model without credentials was not a typed refusal: $refused" ;; esac
[ "$(meta_value model)" = "$FROM" ] && [ "$(meta_value effort)" = "$FROM_EFFORT" ] \
  || fail "a refusal changed task meta: model=$(meta_value model) effort=$(meta_value effort)"
pass "live OMP: an unknown model and a model without credentials are refused with typed reasons, meta unchanged"

# --- AC1: idle switch, new model and thinking level, next turn on the new model
idle_offset=$(session_offset "$WORKER_SESSION") || exit 1
out=$(control switch-model --model "$TO" --effort "$TO_EFFORT" 2>&1) || fail "idle switch-model failed: $out"
printf '# %s\n' "$out"
case "$out" in switched\ "$WORKER_ID"\ request=ms-*) ;; *) fail "idle switch-model is not a typed switched result: $out" ;; esac
case "$out" in *"model=$FROM->$TO"*"boundary=idle"*) ;; *) fail "idle switch-model did not report the model change at the idle boundary: $out" ;; esac
IDLE_RID=$(printf '%s' "$out" | sed -n 's/.*request=\([^ ]*\).*/\1/p')
[ "$(meta_value model)" = "$TO" ] && [ "$(meta_value effort)" = "$TO_EFFORT" ] \
  || fail "task meta does not record the switch: model=$(meta_value model) effort=$(meta_value effort)"
ack="$REQ_DIR/model-switch.$IDLE_RID.ack.json.folded"
[ "$(jq -r '.after.model' "$ack")" = "$TO" ] && [ "$(jq -r '.after.thinking' "$ack")" = "$TO_EFFORT" ] \
  || fail "the extension's ctx.models.current() readback is not the target: $(jq -c . "$ack")"
session_has_model_change_after "$WORKER_SESSION" "$idle_offset" "$TO" \
  || fail "the session recorded no model-change entry for $TO"
printf '# extension readback: %s\n' "$(jq -c '{id, outcome, boundary, before, after, modelChanged}' "$ack")"
wait_for "pane label refreshed from meta" pane_label_is "omp · $TO $TO_EFFORT"
idle_prompt='Reply exactly: idle switch applied.'
idle_submit=$(PATH="$WRAPPER_BIN:$BASE_PATH" HERDR_ENV=1 HERDR_SESSION="$SESSION" \
  fm_backend_herdr_send_text_submit "$WORKER_TARGET" "$idle_prompt" 3 0.2 0 "" \
    omp "$OMP_RUNTIME" "$OMP_BIN") || true
idle_assistant_recorded() {
  [ -n "$(last_assistant_after "$WORKER_SESSION" "$idle_offset")" ]
}
wait_for "the turn after the idle switch (submit verdict: ${idle_submit:-none})" idle_assistant_recorded
wait_for "worker return to idle" agent_is "$WORKER_TARGET" omp 'idle done'
[ "$(last_assistant_after "$WORKER_SESSION" "$idle_offset")" = "$TO" ] \
  || fail "the turn after the switch ran on $(last_assistant_after "$WORKER_SESSION" "$idle_offset"), not $TO"
entries_after "$WORKER_SESSION" "$idle_offset" \
  | jq -se --arg prompt "$idle_prompt" '
      [.[] | select(.type == "message" and .message.role == "user") | .message.content
        | if type == "array" then map(select(.type == "text") | .text) | join("") else . end]
      == [$prompt]' >/dev/null \
  || fail "the session did not record exactly the one post-switch user prompt"
pass "live OMP: an idle worker switches $FROM -> $TO and $FROM_EFFORT -> $TO_EFFORT; the next turn runs on $TO; meta and the pane label follow; nothing is chat"

# --- AC2: a switch requested mid-run waits for the run to settle -------------
busy_offset=$(session_offset "$WORKER_SESSION") || exit 1
busy_reply='slept through the switch.'
send_task "Run this exact bash command: sleep 15. Then reply exactly: $busy_reply" \
  || fail "the busy turn was not submitted"
wait_for "native working worker state" agent_is "$WORKER_TARGET" omp working
sleep 3
out=$(control switch-model --model "$FROM" --effort "$FROM_EFFORT" --wait 120 2>&1) || fail "mid-run switch-model failed: $out"
printf '# %s\n' "$out"
case "$out" in switched\ "$WORKER_ID"\ *"boundary=agent_end"*) ;; *) fail "a mid-run switch was not applied at settled idle: $out" ;; esac
wait_for "the busy worker's final reply" session_has_assistant_reply_after "$WORKER_SESSION" "$busy_offset" "$busy_reply"
wait_for "worker return to idle" agent_is "$WORKER_TARGET" omp 'idle done'
# Every assistant message of the busy run - the tool turn and the final reply -
# precedes the model-change entry and was served by the old model.
entries_after "$WORKER_SESSION" "$busy_offset" | jq -se --arg from "$FROM" --arg to "$TO" --arg reply "$busy_reply" '
  [range(0; length)] as $i
  | . as $e
  | ($i | map(select($e[.].type == "model_change" and $e[.].model == $from)) | first) as $change
  | ($i | map(select($e[.].type == "message" and $e[.].message.role == "assistant"))) as $assistant
  | $change != null
    and ($assistant | length) >= 2
    and ($assistant | all(. < $change and ("\($e[.].message.provider)/\($e[.].message.model)" == $to)))
    and ($assistant | last | $e[.].message.content
         | any(.type == "text" and (.text | contains($reply))))
    and ($e | any(.type == "message" and .message.role == "assistant"
                  and ((.message.content // []) | any(.type == "toolCall"))))' >/dev/null 2>&1 \
  || fail "the session order does not show: the whole in-flight run on $TO, then the switch"
[ "$(meta_value model)" = "$FROM" ] && [ "$(meta_value effort)" = "$FROM_EFFORT" ] \
  || fail "task meta does not record the mid-run switch: model=$(meta_value model) effort=$(meta_value effort)"
post_offset=$(session_offset "$WORKER_SESSION") || exit 1
post_prompt='Reply exactly: busy switch applied.'
post_submit=$(PATH="$WRAPPER_BIN:$BASE_PATH" HERDR_ENV=1 HERDR_SESSION="$SESSION" \
  fm_backend_herdr_send_text_submit "$WORKER_TARGET" "$post_prompt" 3 0.2 0 "" \
    omp "$OMP_RUNTIME" "$OMP_BIN") || true
post_assistant_recorded() {
  [ -n "$(last_assistant_after "$WORKER_SESSION" "$post_offset")" ]
}
wait_for "the turn after the mid-run switch (submit verdict: ${post_submit:-none})" post_assistant_recorded
wait_for "worker return to idle" agent_is "$WORKER_TARGET" omp 'idle done'
[ "$(last_assistant_after "$WORKER_SESSION" "$post_offset")" = "$FROM" ] \
  || fail "the turn after the mid-run switch ran on $(last_assistant_after "$WORKER_SESSION" "$post_offset"), not $FROM"
# The user-message sequence is the oracle for the original failure: a typed
# /model or /switch would appear as a message of its own.
fallback_prompt=": Firstmate instruction waiting: list files named '*.msg' in '\$FM_TASK_INBOX', your '$WORKER_ID.inbox' steering inbox, read and act on each in numeric order, then mv each into its handled/."
entries_after "$WORKER_SESSION" "$busy_offset" \
  | jq -se --arg prompt "$post_prompt" --arg fallback "$fallback_prompt" '
      [.[] | select(.type == "message" and .message.role == "user") | .message.content
        | if type == "array" then map(select(.type == "text") | .text) | join("") else . end]
      | . == [$prompt] or . == [$fallback, $prompt]' >/dev/null \
  || fail "the session recorded an unexpected user message during the busy or post-switch turn"
pass "live OMP: a switch requested mid-run leaves the whole in-flight run on $TO and applies at settled idle; the next turn runs on $FROM; nothing is chat"

# --- AC4: the documented OMP resume path keeps the switched model ------------
out=$(control switch-model --model "$TO" --effort "$TO_EFFORT" 2>&1) || fail "the pre-resume switch-model failed: $out"
case "$out" in switched\ "$WORKER_ID"\ *) ;; *) fail "the pre-resume switch is not a typed switched result: $out" ;; esac
OLD_PID=$(jq -r '.pid // empty' "$REQ_DIR/model-switch.ready" 2>/dev/null)
out=$(control exit 2>&1) || fail "fm-control exit failed: $out"
wait_for "the worker's OMP to exit" omp_agent_absent "$WORKER_TARGET"
resume_offset=$(session_offset "$WORKER_SESSION") || exit 1
# The documented resume command (harness-adapters, omp): the exact OMP binary,
# the task's session directory and session file, the generated extension, and no
# --model, so only the session's own record can say which model to resume on.
# fm-control exit leaves the endpoint's shell in place, so it resumes there.
printf -v resume_launch \
  "exec env PATH=%q OMP_SKIP_SETUP=1 %q --session-dir %q --resume %q --auto-approve -e %q" \
  "$WRAPPER_BIN:$BASE_PATH" "$OMP_BIN" "/tmp/fm-$WORKER_ID/omp-sessions" "$WORKER_SESSION" \
  "$HOME_DIR/state/$WORKER_ID.omp-ext.ts"
PATH="$WRAPPER_BIN:$BASE_PATH" HERDR_SESSION="$SESSION" \
  fm_backend_herdr_send_text_line "$WORKER_TARGET" "$resume_launch" \
  || fail "could not launch the documented OMP resume command"
wait_for "resumed worker identity" agent_is "$WORKER_TARGET" omp 'idle done'
[ "$(session_file_for "$WORKER_TARGET")" = "$WORKER_SESSION" ] \
  || fail "the resumed OMP bound a different session than the worker's"
wait_for "the resumed worker's model-switch channel" resumed_channel_active "$OLD_PID"
verdict=$(PATH="$WRAPPER_BIN:$BASE_PATH" HERDR_ENV=1 HERDR_SESSION="$SESSION" \
  fm_backend_herdr_send_text_submit "$WORKER_TARGET" 'Reply exactly: resumed on the switched model.' 3 0.2 0 "" \
    omp "$OMP_RUNTIME" "$OMP_BIN") || true
resume_assistant_recorded() {
  [ -n "$(last_assistant_after "$WORKER_SESSION" "$resume_offset")" ]
}
# The assistant message, not the echoed prompt text, proves the resumed turn ran.
wait_for "the resumed worker's reply (submit verdict: ${verdict:-none})" resume_assistant_recorded
wait_for "resumed worker return to idle" agent_is "$WORKER_TARGET" omp 'idle done'
[ "$(last_assistant_after "$WORKER_SESSION" "$resume_offset")" = "$TO" ] \
  || fail "the resumed session ran on $(last_assistant_after "$WORKER_SESSION" "$resume_offset"), not the switched model $TO (submit verdict: ${verdict:-none})"
out=$(control switch-model --status 2>&1) || fail "status on the resumed worker failed: $out"
case "$out" in *"channel=ready"*"unresolved=0"*) ;; *) fail "the resumed worker's model-switch channel is not ready: $out" ;; esac
pass "live OMP: the documented resume path (no --model) keeps the switched model $TO, and the resumed worker's channel is live again"

# --- AC1: the global OMP configuration never changed -------------------------
CONFIG_AFTER=$(config_fingerprint) || fail "could not fingerprint the global OMP config"
[ "$CONFIG_BEFORE" = "$CONFIG_AFTER" ] \
  || fail "the global OMP configuration changed during the run:"$'\n'"before: $CONFIG_BEFORE"$'\n'"after:  $CONFIG_AFTER"
pass "live OMP: the global OMP config files are byte-identical before and after"

out=$(control exit 2>&1) || fail "fm-control exit of the resumed worker failed: $out"
wait_for "the resumed worker's OMP to exit" omp_agent_absent "$WORKER_TARGET"
fm_env "$DRIVER_ROOT/bin/fm-teardown.sh" "$WORKER_ID" >/dev/null \
  || fail "production cleanup refused the clean model-switch worker"
WORKER_WT=
FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
  "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null \
  || fail "guarded Herdr teardown or the default-session tripwire failed"
TEARDOWN_DONE=1
pass "live OMP model switch: guarded lab torn down with the default-session tripwire intact"
