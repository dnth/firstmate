#!/usr/bin/env bash
# Opt-in real OMP primary, worker, scout, and secondmate lifecycle in one guarded Herdr lab.
set -u

if [ "${FM_OMP_HERDR_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_HERDR_LIVE_E2E=1 to run the isolated OMP Herdr role matrix"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

command -v omp >/dev/null 2>&1 || fail "omp not found"
command -v herdr >/dev/null 2>&1 || fail "herdr not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v treehouse >/dev/null 2>&1 || fail "treehouse not found"

OMP_BIN=$("$ROOT/bin/fm-omp-capabilities.sh" --print-binary) || fail "OMP capability check failed"
OMP_BIN=$(fm_test_realpath "$OMP_BIN") || fail "OMP binary realpath could not be resolved"
BUN_BIN=$(node -e 'const {realpathSync}=require("node:fs");process.stdout.write(realpathSync(process.argv[1]))' "$(command -v bun)") \
  || fail "Bun realpath could not be resolved"
REAL_HERDR=$(command -v herdr)
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"

LAB=$(fm_test_tmproot fm-omp-herdr-live)
SESSION="fm-lab-omp-matrix-$$-${RANDOM:-0}"
WRAPPER_BIN="$LAB/bin"
WRAPPER_LOG="$LAB/herdr-wrapper.log"
BASE_PATH=$PATH
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
DRIVER_ROOT="$LAB/driver-root"
PRIMARY_HOME="$HOME_DIR"
PRIMARY_PROJECT="$DRIVER_ROOT"
SECOND_HOME="$LAB/secondmate-home"
WORKER_ID="omp-herdr-worker-$$"
SCOUT_ID="omp-herdr-scout-$$"
SECONDMATE_ID="omp-herdr-secondmate-$$"
WORKER_WT=
SCOUT_WT=
TEARDOWN_DONE=0

cleanup_pid_file() { # <file> <exact-owner-script>
  local file=$1 owner=$2 pid args
  pid=$(cat "$file" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$pid" 2>/dev/null || return 0
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case " $args " in *" $owner"*) ;; *) return 1 ;; esac
  kill -TERM "$pid" 2>/dev/null || return 1
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 0
  case " $args " in *" $owner"*) kill -KILL "$pid" 2>/dev/null || return 1 ;; *) return 1 ;; esac
}

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
  if [ "${FM_OMP_HERDR_KEEP_FAILED:-0}" = 1 ] && [ "$TEARDOWN_DONE" -ne 1 ]; then
    echo "diagnostic: preserving failed lab $SESSION at $LAB" >&2
    return
  fi
  cleanup_pid_file "$PRIMARY_HOME/state/.watch.lock/pid" "$DRIVER_ROOT/bin/fm-watch.sh" || cleanup_ok=0
  cleanup_pid_file "$SECOND_HOME/state/.watch.lock/pid" "$SECOND_HOME/bin/fm-watch.sh" || cleanup_ok=0
  if [ "$TEARDOWN_DONE" -ne 1 ]; then
    FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
      "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || cleanup_ok=0
  fi
  cleanup_worktree "$WORKER_WT" || cleanup_ok=0
  cleanup_worktree "$SCOUT_WT" || cleanup_ok=0
  if [ "$cleanup_ok" -eq 1 ]; then
    rm -rf "/tmp/fm-$WORKER_ID" "/tmp/fm-$SCOUT_ID" "/tmp/fm-$SECONDMATE_ID" "$LAB"
  else
    echo "not ok - OMP Herdr fixture cleanup incomplete; preserving $LAB and its task roots" >&2
    trap - EXIT
    exit 1
  fi
}
trap cleanup EXIT

mkdir -p "$WRAPPER_BIN" "$PROJECT" "$DRIVER_ROOT" "$HOME_DIR/data/$WORKER_ID" "$HOME_DIR/data/$SCOUT_ID" \
  "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
: > "$WRAPPER_LOG"
git archive HEAD | tar -x -C "$DRIVER_ROOT"
# The live matrix validates the current branch, including uncommitted issue-fix
# slices under test, while the driver itself remains a clean committed clone.
git diff --name-only HEAD | while IFS= read -r changed; do
  [ -f "$ROOT/$changed" ] || continue
  mkdir -p "$DRIVER_ROOT/$(dirname "$changed")"
  cp "$ROOT/$changed" "$DRIVER_ROOT/$changed"
done
git init -q -b main "$DRIVER_ROOT"
fm_git_identity fmtest fmtest@example.invalid
git -C "$DRIVER_ROOT" add .
git -C "$DRIVER_ROOT" commit -qm init

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
bun_bin='$BUN_BIN'
if [ "\${FM_HERDR_LAB_INNER:-0}" = 1 ]; then
  if [ "\${1:-}" = server ]; then
    exec env -u FM_HERDR_LAB_INNER "\$real" "\$@"
  fi
  exec "\$real" "\$@"
fi
case "\${1:-}" in
  --version|-V|version) exec "\$real" "\$@" ;;
esac
# OMP itself probes Herdr with its own prefix-session syntax. Those calls are
# outside Firstmate's backend API and cannot satisfy this matrix's trailing-
# session contract. Quarantine only the exact observed read-only forms from an
# exact OMP parent; keep them out of the production-command log and never run
# them against the server.
parent_args=\$(ps -o args= -p "\$PPID" 2>/dev/null || true)
if [ -e "/proc/\$PPID/exe" ]; then
  parent_exe=\$(readlink -f "/proc/\$PPID/exe" 2>/dev/null || true)
else
  parent_exe=\$(lsof -a -p "\$PPID" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
fi
case "\$parent_exe:\$parent_args" in
  "\$bun_bin":bun\ "\$omp_bin"\ *)
    native_probe=0
    native_probe_pane=
    case "\$#:\$*" in
      "1:agent"|"1:--help"|"2:agent --help"|"2:agent list"|"3:--session \$session --help") native_probe=1 ;;
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
    ;;
esac
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
# session-enforcing Herdr wrapper and deterministic treehouse fixture.
FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
  "$HERDR_LAB_HELPER" provision "$SESSION" >/dev/null \
  || fail "could not provision the guarded Herdr role-matrix lab"

lab() {
  FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
    "$HERDR_LAB_HELPER" run "$SESSION" "$@"
}

fm_env() {
  env PATH="$WRAPPER_BIN:$BASE_PATH" HERDR_ENV=1 HERDR_SESSION="$SESSION" \
    HERDR_PANE_ID="${PRIMARY_PANE:-}" HERDR_TAB_ID="${PRIMARY_TAB:-}" \
    HERDR_WORKSPACE_ID="${PRIMARY_WORKSPACE:-}" HERDR_SOCKET_PATH="${PRIMARY_SOCKET:-}" \
    OMP_SKIP_SETUP=1 FM_BACKEND=herdr FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$DRIVER_ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    "$@"
}

drain_primary_wakes() {
  fm_env "$ROOT/bin/fm-wake-drain.sh" >/dev/null \
    || fail "primary OMP Herdr evidence queue did not drain"
  [ ! -s "$HOME_DIR/state/.wake-queue" ] \
    || fail "primary OMP Herdr evidence queue retained a notification after drain"
}

# The primary owns its wake queue. Where a segment can prove which notification
# it produced, the fixture drains only after the primary's own bound drain. Where
# it cannot, require the queue to be empty while the primary is at exact native
# idle, so a late real notification is left for the primary instead of swallowed.
primary_settled_empty() {
  [ ! -s "$HOME_DIR/state/.wake-queue" ] || return 1
  agent_is "$PRIMARY_TARGET" omp 'idle done'
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

session_file_for() {
  agent_json "$1" | jq -r 'select(.result.agent.agent_session.kind == "path") | .result.agent.agent_session.value // empty' 2>/dev/null
}

# Every predicate below tails from a recorded byte offset into jq, and OMP is
# still appending while the offset is taken, so a raw file size can land in the
# middle of a record. A tail that starts mid-record is invalid JSON forever, so
# the matching event appended later could never be read. Production already owns
# that rule, so bind each fixture offset with the exact production boundary
# function instead of a fixture copy: it waits a bounded time for a partial
# trailing record to complete and refuses rather than rewinding to the previous
# boundary, which would re-expose an already-appended record to the matcher.
session_offset() { # <session-file>
  local file=$1 offset
  offset=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_omp_session_complete_offset "$1"' \
    "$ROOT" "$file") || {
    printf 'not ok - production offset owner refused a complete JSONL record boundary in %s\n' "$file" >&2
    return 1
  }
  printf '%s' "$offset"
}

# OMP records message content as a part list, and the text part is not always
# first, so match any exact text part instead of assuming content[0].
session_has_exact_user_after() { # <file> <offset> <text> <steering-json>
  local file=$1 offset=$2 text=$3 steering=$4 start
  start=$((offset + 1))
  tail -c "+$start" "$file" 2>/dev/null \
    | jq -se --arg text "$text" --argjson steering "$steering" \
      'any(.[]; .type == "message" and .message.role == "user" and .message.attribution == "user" and ((.message.steering // false) == $steering) and any(.message.content[]?; .type == "text" and .text == $text))' \
      >/dev/null 2>&1
}

session_has_exact_steer_after() { # <file> <offset> <text>
  local file=$1 offset=$2 text=$3 start
  start=$((offset + 1))
  tail -c "+$start" "$file" 2>/dev/null \
    | jq -se --arg text "$text" 'any(.[]; .type == "message" and .message.role == "user" and .message.attribution == "user" and .message.steering == true and any(.message.content[]?; .type == "text" and .text == $text))' \
      >/dev/null 2>&1
}

session_has_text_after() { # <file> <offset> <text>
  local file=$1 offset=$2 text=$3 start
  start=$((offset + 1))
  tail -c "+$start" "$file" 2>/dev/null | grep -F -- "$text" >/dev/null 2>&1
}

# An answerable single-choice question is an assistant ask tool call that has no
# tool result yet, so the agent is genuinely waiting on the operator.
session_has_open_ask_after() { # <file> <offset>
  local file=$1 offset=$2 start
  start=$((offset + 1))
  tail -c "+$start" "$file" 2>/dev/null \
    | jq -se '
        [.[] | select(.type == "message" and .message.role == "assistant")
          | .message.content[]? | select(.type == "toolCall" and .name == "ask") | .id] as $asks
        | [.[] | select(.type == "message" and .message.role == "toolResult")
          | .message.toolCallId] as $answered
        | any($asks[]; . as $id | $answered | index($id) == null)' \
      >/dev/null 2>&1
}

# A routed choice arrives either as an ordinary user message or as the structured
# answer recorded against the receiving agent's own ask tool call. The structured
# form is only accepted when the ask tool result selected exactly the one
# requested option; its display text is never matched.
session_has_exact_choice_after() { # <file> <offset> <choice>
  local file=$1 offset=$2 choice=$3 start
  start=$((offset + 1))
  tail -c "+$start" "$file" 2>/dev/null \
    | jq -se --arg choice "$choice" '
        any(.[] | select(.type == "message") | .message;
          (.role == "user" and .attribution == "user"
            and any(.content[]?; .type == "text" and .text == $choice))
          or (.role == "toolResult" and .toolName == "ask"
            and (.details.selectedOptions // []) == [$choice]))' \
      >/dev/null 2>&1
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

watcher_fresh() { # <state>
  fm_supervision_status "$1" "${FM_GUARD_GRACE:-300}"
  [ "$FM_SUP_WATCHER_FRESH" = true ]
}

wait_for_fresh_watcher() { # <description> <state>
  local description=$1 state=$2 i=0
  while [ "$i" -lt 1400 ]; do
    watcher_fresh "$state" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  fail "timed out waiting for $description"
}

file_exists() { [ -f "$1" ]; }
file_nonempty() { [ -s "$1" ]; }
file_has() { grep -F -- "$2" "$1" >/dev/null 2>&1; }

primary_wake_arrived() { # <transcript-offset> <wake-text> [signal-file]
  session_has_text_after "$PRIMARY_SESSION" "$1" "$2" && return 0
  [ -n "${3:-}" ] && file_has "$HOME_DIR/state/.wake-queue" "$3"
}

# The primary owns its wake queue. A fixture-side drain that lands before the
# primary reads the injected wake lets the primary's own later drain consume the
# next escalation inside that earlier turn, so no second wake is ever injected.
# Bind every injected wake to the primary's exact completed bin/fm-wake-drain.sh
# tool call recorded after that wake's own transcript event. The anchor is the
# exact delivered watcher user event, not any serialized entry that happens to
# quote the wake text - the primary's own tool calls and outputs echo it too,
# and anchoring on one of those would accept a drain that ran before delivery.
primary_drained_wake_after() { # <transcript-offset> <wake-text>
  local offset=$1 text=$2 start
  start=$((offset + 1))
  tail -c "+$start" "$PRIMARY_SESSION" 2>/dev/null \
    | jq -se --arg text "$text" '
        (to_entries
          | map(select(.value.type == "message" and .value.message.role == "user"
              and .value.message.attribution == "user"
              and any(.value.message.content[]?; .type == "text" and (.text | contains($text)))))
          | first | .key) as $wake
        | if $wake == null then false
          else
            .[($wake + 1):] as $rest
            | [$rest[] | select(.type == "message" and .message.role == "assistant")
                | .message.content[]?
                | select(.type == "toolCall" and .name == "bash"
                    and ((.arguments.command // "") | contains("bin/fm-wake-drain.sh")))
                | .id] as $calls
            | [$rest[] | select(.type == "message" and .message.role == "toolResult"
                and ((.message.isError // false) | not))
                | .message.toolCallId] as $done
            | any($calls[]; . as $id | $done | index($id) != null)
          end' \
      >/dev/null 2>&1
}

await_primary_wake_drain() { # <description> <transcript-offset> <wake-text> [signal-file]
  local description=$1 offset=$2 wake_text=$3 signal_file=${4:-}
  wait_for "$description" primary_wake_arrived "$offset" "$wake_text" "$signal_file"
  wait_for "primary wake drain for $description" primary_drained_wake_after "$offset" "$wake_text"
}

await_primary_wake_and_drain() { # <description> <transcript-offset> <wake-text> [signal-file]
  await_primary_wake_drain "$@"
  wait_for "exact native primary idle after $1" agent_is "$PRIMARY_TARGET" omp 'idle done'
  drain_primary_wakes
}

primary_ask_open_after() { # <transcript-offset>
  agent_is "$PRIMARY_TARGET" omp blocked && session_has_open_ask_after "$PRIMARY_SESSION" "$1"
}

# After the correlated drain the captain may either escalate the worker's
# question with its own ask or acknowledge it and return to exact native idle.
# Both are valid model-level handlings, so wait for whichever settles first.
primary_blocked_decision_settled() { # <transcript-offset>
  primary_ask_open_after "$1" || agent_is "$PRIMARY_TARGET" omp 'idle done'
}

# An advisory can close the captain's ask between observing it open and the
# Enter that selects the default option, so that Enter routes no choice. The
# Enter is settled once the worker recorded the exact routed choice, or once the
# captain has no open ask left and is back at exact native idle - only that
# observed race falls through to the idle-captain answer path below.
primary_enter_settled() { # <primary-transcript-offset> <worker-session> <worker-offset> <choice>
  session_has_exact_choice_after "$2" "$3" "$4" && return 0
  primary_ask_open_after "$1" && return 1
  agent_is "$PRIMARY_TARGET" omp 'idle done'
}

send_task() {
  [ ! -s "$HOME_DIR/state/.wake-queue" ] \
    || fail "guarded OMP Herdr send began with an undrained primary notification: $*"
  fm_env FM_SEND_SLEEP=0.2 FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$@" >/dev/null
}

spawn_task() { # <id> [--scout]
  local id=$1
  local -a delivery_args=()
  shift
  if [ "${1:-}" != --scout ]; then
    delivery_args+=(--mode direct-PR --yolo off)
  fi
  fm_env FM_SPAWN_NO_GUARD=1 FM_OMP_LAUNCH_ACK_INTERVAL=0.25 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJECT" --harness omp \
      --model openai-codex/gpt-5.6-sol --effort low "${delivery_args[@]}" "$@"
}

# --- real primary ------------------------------------------------------------
mkdir -p "$PRIMARY_HOME/sessions"
printf 'herdr\n' > "$PRIMARY_HOME/config/backend"
printf 'omp\n' > "$PRIMARY_HOME/config/crew-harness"
# Keep this role matrix on the flat per-home workspace path; disposable
# presentation workspaces are covered by the dedicated Herdr presentation suite.
printf 'off\n' > "$PRIMARY_HOME/config/herdr-presentation-spaces"
primary_create=$(lab workspace create --cwd "$PRIMARY_PROJECT" --label omp-primary-live --no-focus) \
  || fail "could not create the guarded OMP primary workspace"
PRIMARY_PANE=$(printf '%s' "$primary_create" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PRIMARY_PANE" ] || fail "primary workspace returned no pane"
PRIMARY_TARGET="$SESSION:$PRIMARY_PANE"
printf -v primary_launch \
  "exec env PATH=%q OMP_SKIP_SETUP=1 FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_STATE_OVERRIDE=%q FM_CONFIG_OVERRIDE=%q %q --model openai-codex/gpt-5.6-sol --thinking low --session-dir %q --auto-approve -e %q %q" \
  "$WRAPPER_BIN:$BASE_PATH" "$PRIMARY_HOME" "$PRIMARY_PROJECT" "$PRIMARY_HOME/state" "$PRIMARY_HOME/config" \
  "$OMP_BIN" "$PRIMARY_HOME/sessions" "$PRIMARY_PROJECT/.omp/extensions/fm-primary-omp.ts" \
  "Follow the injected startup instruction exactly once, call the fm_watch_arm_omp tool, then reply exactly: Herdr primary is ready."
lab pane run "$PRIMARY_PANE" "$primary_launch" >/dev/null || fail "could not launch the real OMP primary"
wait_for "exact idle OMP primary identity" agent_is "$PRIMARY_TARGET" omp 'idle done'
wait_for "OMP primary integration marker" file_nonempty "$PRIMARY_HOME/state/.omp-primary-extension-loaded"
wait_for "OMP primary session lock" file_nonempty "$PRIMARY_HOME/state/.lock"
PRIMARY_SESSION=$(session_file_for "$PRIMARY_TARGET")
case "$PRIMARY_SESSION" in "$PRIMARY_HOME/sessions/"*.jsonl) ;; *) fail "primary Herdr identity did not bind its controlled native session" ;; esac
wait_for "OMP primary guarded response" file_has "$PRIMARY_SESSION" 'Herdr primary is ready.'
PRIMARY_INFO=$(lab pane get "$PRIMARY_PANE") || fail "primary OMP Herdr pane could not be read"
PRIMARY_TAB=$(printf '%s' "$PRIMARY_INFO" | jq -er '.result.pane.tab_id // empty') \
  || fail "primary OMP Herdr pane did not publish a live tab"
PRIMARY_WORKSPACE=$(printf '%s' "$PRIMARY_INFO" | jq -er '.result.pane.workspace_id // empty') \
  || fail "primary OMP Herdr pane did not publish a live workspace"
PRIMARY_SOCKET=$(lab session list --json | jq -er --arg want "$SESSION" '
  [.sessions[]? | select(.name == $want and .running == true)
   | select((.socket_path | type) == "string" and (.socket_path | length) > 0)
   | .socket_path]
  | if length == 1 then .[0] else empty end
') || fail "primary OMP Herdr session did not publish one live socket"

# Keep the real primary and its home-scoped watcher alive while it supervises
# the worker, scout, and secondmate role evidence below.
wait_for_fresh_watcher "OMP primary fresh watcher beacon" "$PRIMARY_HOME/state"

# --- production worker and scout --------------------------------------------
printf 'Reply exactly: Herdr worker is ready.\n' > "$HOME_DIR/data/$WORKER_ID/brief.md"
printf 'Reply exactly: Herdr scout is ready.\n' > "$HOME_DIR/data/$SCOUT_ID/brief.md"
printf '%s\n' '- project [direct-PR] - OMP Herdr live fixture (added 2026-07-30)' > "$HOME_DIR/data/projects.md"
printf 'fixture\n' > "$PROJECT/README.md"
git init -q -b main "$PROJECT"
fm_git_identity fmtest fmtest@example.invalid
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -qm init
git init -q --bare "$LAB/project-origin.git"
git -C "$PROJECT" remote add origin "$LAB/project-origin.git"
git -C "$PROJECT" push -qu origin main
git -C "$LAB/project-origin.git" symbolic-ref HEAD refs/heads/main

worker_log_start=$(wc -l < "$WRAPPER_LOG" | tr -d '[:space:]')
worker_start_wake_offset=$(session_offset "$PRIMARY_SESSION") || exit 1
spawn_task "$WORKER_ID" >/dev/null || fail "production OMP Herdr worker spawn failed"
worker_log_after=$(tail -n "+$((worker_log_start + 1))" "$WRAPPER_LOG")
printf '%s\n' "$worker_log_after" | grep -Fx -- "session list --json --session $SESSION " >/dev/null \
  || fail "production worker launch did not issue the exact session list --json inventory call"
WORKER_META="$HOME_DIR/state/$WORKER_ID.meta"
WORKER_TARGET=$(sed -n 's/^window=//p' "$WORKER_META")
WORKER_WT=$(sed -n 's/^worktree=//p' "$WORKER_META")
[ -n "$WORKER_WT" ] && [ "$WORKER_WT" != "$PROJECT" ] && [ -d "$WORKER_WT" ] \
  || fail "Herdr worker did not acquire a distinct isolated worktree"
assert_grep 'harness=omp' "$WORKER_META" "Herdr worker metadata lost exact OMP identity"
assert_grep 'backend=herdr' "$WORKER_META" "Herdr worker metadata lost its backend"
assert_grep "herdr_session=$SESSION" "$WORKER_META" "Herdr worker metadata lost the exact lab session"
WORKER_WORKSPACE=$(sed -n 's/^herdr_workspace_id=//p' "$WORKER_META")
[ -n "$WORKER_WORKSPACE" ] && [ "$WORKER_WORKSPACE" = "$PRIMARY_WORKSPACE" ] \
  || fail "Herdr worker workspace '$WORKER_WORKSPACE' did not match primary live workspace '$PRIMARY_WORKSPACE'"
assert_grep "worktree=$WORKER_WT" "$WORKER_META" "Herdr worker did not enter its isolated worktree"
wait_for "worker extension readiness" file_exists "$HOME_DIR/state/$WORKER_ID.omp-ready"
wait_for "worker first turn" file_exists "$HOME_DIR/state/$WORKER_ID.turn-ended"
wait_for "exact idle worker identity" agent_is "$WORKER_TARGET" omp 'idle done'
WORKER_SESSION=$(session_file_for "$WORKER_TARGET")
case "$WORKER_SESSION" in "/tmp/fm-$WORKER_ID/omp-sessions/"*.jsonl) ;; *) fail "worker Herdr identity did not bind its task-owned session" ;; esac
file_has "$WORKER_SESSION" 'Herdr worker is ready.' || fail "worker launch brief did not complete"
await_primary_wake_and_drain "worker startup turn-end delivery" "$worker_start_wake_offset" \
  "FIRSTMATE WATCHER WAKE: signal: $HOME_DIR/state/$WORKER_ID.turn-ended" \
  "$HOME_DIR/state/$WORKER_ID.turn-ended"

rm -f "$HOME_DIR/state/$WORKER_ID.turn-ended"
blocked_prompt="Before continuing, use the ask tool for one single-choice question: 'Which audience should the report focus on?' Offer exactly two options, 'Operators' and 'Maintainers', and wait for my selection."
blocked_wake_offset=$(session_offset "$PRIMARY_SESSION") || exit 1
send_task "$WORKER_ID" "$blocked_prompt" || fail "worker question-induced blocked-state setup was not submitted"
wait_for "real OMP worker blocked state" agent_is "$WORKER_TARGET" omp blocked
wait_for "watcher blocked escalation" file_has "$HOME_DIR/state/.wake-queue" "herdr: agent blocked - waiting on human"
file_has "$HOME_DIR/state/.wake-queue" "$WORKER_TARGET" \
  || fail "blocked escalation did not identify the exact OMP worker target"
# The primary answers this escalation with its own question, so it stays blocked
# until the operator decides; require exact native idle after that decision, not
# before it.
await_primary_wake_drain "primary actionable blocked follow-up" "$blocked_wake_offset" \
  "FIRSTMATE WATCHER WAKE: stale: $WORKER_TARGET (herdr: agent blocked - waiting on human"
question_wake_offset=$(session_offset "$PRIMARY_SESSION") || exit 1
# Firstmate owns the answer route. When the captain escalates the worker's
# single-choice question, the operator takes the default option on the exact
# primary pane and the primary forwards that exact choice to the worker. When
# the captain instead acknowledges the escalation and returns to exact native
# idle, the operator answers the still-blocked worker through the same guarded
# send path. Both paths must land the exact routed choice on the worker.
wait_for "primary decision on the blocked worker" primary_blocked_decision_settled "$blocked_wake_offset"
worker_answer_offset=$(session_offset "$WORKER_SESSION") || exit 1
if primary_ask_open_after "$blocked_wake_offset"; then
  lab pane send-keys "$(pane_id "$PRIMARY_TARGET")" enter >/dev/null \
    || fail "could not select the default captain option on the exact primary pane"
  wait_for "captain ask resolution after the default selection" primary_enter_settled \
    "$blocked_wake_offset" "$WORKER_SESSION" "$worker_answer_offset" Operators
fi
if ! session_has_exact_choice_after "$WORKER_SESSION" "$worker_answer_offset" Operators; then
  drain_primary_wakes
  send_task "$WORKER_ID" Operators \
    || fail "captain answer for the blocked worker was not submitted"
fi
wait_for "exact routed captain choice on the worker" session_has_exact_choice_after \
  "$WORKER_SESSION" "$worker_answer_offset" Operators
wait_for "question-induced worker turn completion" file_exists "$HOME_DIR/state/$WORKER_ID.turn-ended"
wait_for "question-induced worker return to idle" agent_is "$WORKER_TARGET" omp 'idle done'
wait_for "exact native primary idle after the captain decision" agent_is "$PRIMARY_TARGET" omp 'idle done'
await_primary_wake_and_drain "question turn-end delivery" "$question_wake_offset" \
  "FIRSTMATE WATCHER WAKE: signal: $HOME_DIR/state/$WORKER_ID.turn-ended" \
  "$HOME_DIR/state/$WORKER_ID.turn-ended"

rm -f "$HOME_DIR/state/$WORKER_ID.turn-ended"
worker_idle_text='Reply exactly: The idle worker message was processed.'
worker_idle_offset=$(session_offset "$WORKER_SESSION") || exit 1
worker_idle_wake_offset=$(session_offset "$PRIMARY_SESSION") || exit 1
send_task "$WORKER_ID" "$worker_idle_text" || fail "worker idle steering was not submitted"
wait_for "worker exact native idle user event" session_has_exact_user_after \
  "$WORKER_SESSION" "$worker_idle_offset" "$worker_idle_text" false
wait_for "worker idle turn completion" file_exists "$HOME_DIR/state/$WORKER_ID.turn-ended"
wait_for "worker idle response" file_has "$WORKER_SESSION" 'The idle worker message was processed.'
wait_for "worker idle steering return" agent_is "$WORKER_TARGET" omp 'idle done'
await_primary_wake_and_drain "worker idle turn-end delivery" "$worker_idle_wake_offset" \
  "FIRSTMATE WATCHER WAKE: signal: $HOME_DIR/state/$WORKER_ID.turn-ended" \
  "$HOME_DIR/state/$WORKER_ID.turn-ended"

rm -f "$HOME_DIR/state/$WORKER_ID.turn-ended"
worker_busy_wake_offset=$(session_offset "$PRIMARY_SESSION") || exit 1
send_task "$WORKER_ID" 'Run this exact bash command: sleep 10. Then reply exactly: The worker completed its timed command.' \
  || fail "worker busy-turn setup was not submitted"
wait_for "native working worker state" agent_is "$WORKER_TARGET" omp working
steer_offset=$(session_offset "$WORKER_SESSION") || exit 1
send_task "$WORKER_ID" 'After the tool finishes, reply exactly: The busy worker message was processed.' \
  || fail "worker busy steering was not event-confirmed"
wait_for "worker exact native steering event" session_has_exact_steer_after \
  "$WORKER_SESSION" "$steer_offset" 'After the tool finishes, reply exactly: The busy worker message was processed.'
wait_for "worker busy turn completion" file_exists "$HOME_DIR/state/$WORKER_ID.turn-ended"
wait_for "worker busy response" file_has "$WORKER_SESSION" 'The busy worker message was processed.'
wait_for "worker return to idle" agent_is "$WORKER_TARGET" omp 'idle done'
await_primary_wake_and_drain "worker busy turn-end delivery" "$worker_busy_wake_offset" \
  "FIRSTMATE WATCHER WAKE: signal: $HOME_DIR/state/$WORKER_ID.turn-ended" \
  "$HOME_DIR/state/$WORKER_ID.turn-ended"

worker_exit_offset=$(session_offset "$WORKER_SESSION") || exit 1
send_task "$WORKER_ID" /exit || fail "production worker /exit was not event-confirmed"
wait_for "exact worker pane absence" pane_missing "$WORKER_TARGET"
tail -c "+$((worker_exit_offset + 1))" "$WORKER_SESSION" \
  | jq -se 'any(.[]; .type == "custom" and .customType == "session_exit" and .data.kind == "normal")' >/dev/null \
  || fail "worker did not append a normal session_exit"
fm_env "$ROOT/bin/fm-teardown.sh" "$WORKER_ID" >/dev/null \
  || fail "production cleanup refused the clean, unchanged OMP Herdr worker"
[ ! -e "$WORKER_META" ] && [ ! -e "$HOME_DIR/state/$WORKER_ID.omp-ext.ts" ] && [ ! -e "/tmp/fm-$WORKER_ID" ] \
  || fail "worker cleanup left generated OMP artifacts behind"
WORKER_WT=

scout_start_wake_offset=$(session_offset "$PRIMARY_SESSION") || exit 1
spawn_task "$SCOUT_ID" --scout >/dev/null || fail "production OMP Herdr scout spawn failed"
SCOUT_META="$HOME_DIR/state/$SCOUT_ID.meta"
SCOUT_TARGET=$(sed -n 's/^window=//p' "$SCOUT_META")
SCOUT_WT=$(sed -n 's/^worktree=//p' "$SCOUT_META")
[ -n "$SCOUT_WT" ] && [ "$SCOUT_WT" != "$PROJECT" ] && [ -d "$SCOUT_WT" ] \
  || fail "Herdr scout did not acquire a distinct isolated worktree"
assert_grep 'harness=omp' "$SCOUT_META" "Herdr scout metadata lost exact OMP identity"
assert_grep 'kind=scout' "$SCOUT_META" "Herdr scout changed delivery semantics"
assert_grep "worktree=$SCOUT_WT" "$SCOUT_META" "Herdr scout did not enter its isolated worktree"
wait_for "scout extension readiness" file_exists "$HOME_DIR/state/$SCOUT_ID.omp-ready"
wait_for "scout first turn" file_exists "$HOME_DIR/state/$SCOUT_ID.turn-ended"
wait_for "exact idle scout identity" agent_is "$SCOUT_TARGET" omp 'idle done'
SCOUT_SESSION=$(session_file_for "$SCOUT_TARGET")
file_has "$SCOUT_SESSION" 'Herdr scout is ready.' || fail "scout launch brief did not complete"
await_primary_wake_and_drain "scout startup turn-end delivery" "$scout_start_wake_offset" \
  "FIRSTMATE WATCHER WAKE: signal: $HOME_DIR/state/$SCOUT_ID.turn-ended" \
  "$HOME_DIR/state/$SCOUT_ID.turn-ended"
rm -f "$HOME_DIR/state/$SCOUT_ID.turn-ended"
scout_idle_text='Reply exactly: The idle scout message was processed.'
scout_idle_offset=$(session_offset "$SCOUT_SESSION") || exit 1
scout_idle_wake_offset=$(session_offset "$PRIMARY_SESSION") || exit 1
send_task "$SCOUT_ID" "$scout_idle_text" || fail "scout idle steering was not submitted"
wait_for "scout exact native idle user event" session_has_exact_user_after \
  "$SCOUT_SESSION" "$scout_idle_offset" "$scout_idle_text" false
wait_for "scout idle turn completion" file_exists "$HOME_DIR/state/$SCOUT_ID.turn-ended"
wait_for "scout idle response" file_has "$SCOUT_SESSION" 'The idle scout message was processed.'
wait_for "scout idle steering return" agent_is "$SCOUT_TARGET" omp 'idle done'
await_primary_wake_and_drain "scout idle turn-end delivery" "$scout_idle_wake_offset" \
  "FIRSTMATE WATCHER WAKE: signal: $HOME_DIR/state/$SCOUT_ID.turn-ended" \
  "$HOME_DIR/state/$SCOUT_ID.turn-ended"
rm -f "$HOME_DIR/state/$SCOUT_ID.turn-ended"
scout_busy_prompt='Run this exact bash command: sleep 10. Then reply exactly: The scout completed its timed command.'
scout_busy_wake_offset=$(session_offset "$PRIMARY_SESSION") || exit 1
send_task "$SCOUT_ID" "$scout_busy_prompt" || fail "scout busy-turn setup was not submitted"
wait_for "native working scout state" agent_is "$SCOUT_TARGET" omp working
scout_steer_text='After the tool finishes, reply exactly: The busy scout message was processed.'
scout_steer_offset=$(session_offset "$SCOUT_SESSION") || exit 1
send_task "$SCOUT_ID" "$scout_steer_text" || fail "scout busy steering was not event-confirmed"
wait_for "scout exact native steering event" session_has_exact_steer_after \
  "$SCOUT_SESSION" "$scout_steer_offset" "$scout_steer_text"
wait_for "scout busy turn completion" file_exists "$HOME_DIR/state/$SCOUT_ID.turn-ended"
wait_for "scout busy response" file_has "$SCOUT_SESSION" 'The busy scout message was processed.'
wait_for "scout busy steering return" agent_is "$SCOUT_TARGET" omp 'idle done'
await_primary_wake_and_drain "scout busy turn-end delivery" "$scout_busy_wake_offset" \
  "FIRSTMATE WATCHER WAKE: signal: $HOME_DIR/state/$SCOUT_ID.turn-ended" \
  "$HOME_DIR/state/$SCOUT_ID.turn-ended"
scout_exit_offset=$(session_offset "$SCOUT_SESSION") || exit 1
send_task "$SCOUT_ID" /exit || fail "production scout /exit was not event-confirmed"
wait_for "exact scout pane absence" pane_missing "$SCOUT_TARGET"
tail -c "+$((scout_exit_offset + 1))" "$SCOUT_SESSION" \
  | jq -se 'any(.[]; .type == "custom" and .customType == "session_exit" and .data.kind == "normal")' >/dev/null \
  || fail "scout did not append a normal session_exit"
printf 'OMP Herdr scout lifecycle evidence complete.\n' > "$HOME_DIR/data/$SCOUT_ID/report.md"
fm_env "$ROOT/bin/fm-decision-hold.sh" complete "$SCOUT_ID" --none >/dev/null \
  || fail "scout unresolved-decision inventory did not complete"
fm_env "$ROOT/bin/fm-teardown.sh" "$SCOUT_ID" >/dev/null \
  || fail "production cleanup refused the clean, reported OMP Herdr scout"
[ ! -e "$SCOUT_META" ] && [ ! -e "$HOME_DIR/state/$SCOUT_ID.omp-ext.ts" ] && [ ! -e "/tmp/fm-$SCOUT_ID" ] \
  || fail "scout cleanup left generated OMP artifacts behind"
SCOUT_WT=

# --- production persistent secondmate ---------------------------------------
git clone -q "$DRIVER_ROOT" "$SECOND_HOME"
mkdir -p "$SECOND_HOME/data" "$SECOND_HOME/state" "$SECOND_HOME/config" "$SECOND_HOME/projects"
printf '%s\n' "$SECONDMATE_ID" > "$SECOND_HOME/.fm-secondmate-home"
printf 'omp openai-codex/gpt-5.6-sol low\n' > "$HOME_DIR/config/secondmate-harness"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
  FM_SECONDMATE_CHARTER='Wait for marked lifecycle-test requests and return correlated answers to the parent.' \
  FM_SECONDMATE_SCOPE='Guarded OMP Herdr lifecycle verification only.' \
  "$ROOT/bin/fm-brief.sh" "$SECONDMATE_ID" --secondmate --no-projects >/dev/null

spawn_secondmate() {
  fm_env FM_OMP_SECONDMATE_ACK_POLLS=600 FM_OMP_LAUNCH_ACK_INTERVAL=0.25 \
    "$ROOT/bin/fm-spawn.sh" "$SECONDMATE_ID" "$SECOND_HOME" --secondmate
}

spawn_secondmate >/dev/null || fail "production OMP Herdr secondmate spawn failed"
SECONDMATE_META="$HOME_DIR/state/$SECONDMATE_ID.meta"
SECONDMATE_TARGET=$(sed -n 's/^window=//p' "$SECONDMATE_META")
assert_grep 'harness=omp' "$SECONDMATE_META" "Herdr secondmate metadata lost exact OMP identity"
assert_grep 'kind=secondmate' "$SECONDMATE_META" "Herdr secondmate metadata lost its role"
wait_for "secondmate primary integration" file_nonempty "$SECOND_HOME/state/.omp-primary-extension-loaded"
wait_for_fresh_watcher "secondmate fresh watcher beacon" "$SECOND_HOME/state"
wait_for "exact idle secondmate identity" agent_is "$SECONDMATE_TARGET" omp 'idle done'
secondmate_reply_wake_offset=$(session_offset "$PRIMARY_SESSION") || exit 1
send_task "$SECONDMATE_ID" 'Return exactly "Herdr secondmate routed reply received." through the correlated parent status path.' \
  || fail "marked secondmate request was not submitted"
wait_for "correlated secondmate reply" file_has "$HOME_DIR/state/$SECONDMATE_ID.status" 'Herdr secondmate routed reply received.'
wait_for "secondmate return to idle" agent_is "$SECONDMATE_TARGET" omp 'idle done'
await_primary_wake_and_drain "secondmate routed-reply delivery" "$secondmate_reply_wake_offset" \
  "FIRSTMATE WATCHER WAKE: signal: $HOME_DIR/state/$SECONDMATE_ID.status" \
  "$HOME_DIR/state/$SECONDMATE_ID.status"
SECONDMATE_SESSION=$(cat "$SECOND_HOME/state/.omp-session" 2>/dev/null || true)
case "$SECONDMATE_SESSION" in "$SECOND_HOME/state/omp-sessions/"*.jsonl) ;; *) fail "secondmate did not publish an exact durable OMP session" ;; esac
send_task "$SECONDMATE_TARGET" /exit || fail "production secondmate /exit was not event-confirmed"
wait_for "exact secondmate pane absence" pane_missing "$SECONDMATE_TARGET"

spawn_secondmate >/dev/null || fail "production OMP Herdr secondmate exact-session recovery failed"
RESUMED_TARGET=$(sed -n 's/^window=//p' "$SECONDMATE_META")
wait_for "resumed exact secondmate identity" agent_is "$RESUMED_TARGET" omp 'idle done'
[ "$(cat "$SECOND_HOME/state/.omp-session")" = "$SECONDMATE_SESSION" ] \
  || fail "secondmate recovery changed the retained session identity"
set +e
duplicate=$(spawn_secondmate 2>&1)
duplicate_rc=$?
set -e
[ "$duplicate_rc" -ne 0 ] || fail "live OMP Herdr secondmate accepted a duplicate launch"
assert_contains "$duplicate" 'already has a live agent' "secondmate duplicate refusal was not authoritative"
# The exit, exact-session respawn, and duplicate-refusal probe above rewrite no
# signal file: the secondmate's parent status channel keeps the single routed
# reply already proven and drained above, so this segment owes no second status
# notification. So do not drain from the fixture here: that would swallow a late
# real notification this segment did not predict. Wait instead for the primary to
# own the queue itself - empty queue observed together with exact native idle,
# which is what send_task demands for the resumed /exit. Any notification that
# does arrive stays queued until the primary drains it, or fails the send loudly.
wait_for "primary-owned empty queue at exact native idle after secondmate recovery" \
  primary_settled_empty
send_task "$RESUMED_TARGET" /exit || fail "resumed OMP Herdr secondmate did not exit cleanly"
wait_for "resumed secondmate pane absence" pane_missing "$RESUMED_TARGET"

primary_offset=$(session_offset "$PRIMARY_SESSION") || exit 1
primary_verdict=$(PATH="$WRAPPER_BIN:$BASE_PATH" HERDR_SESSION="$SESSION" \
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit "$1" /exit 1 0.2 0 "" omp' \
    "$DRIVER_ROOT" "$PRIMARY_TARGET")
[ "$primary_verdict" = empty ] || fail "real OMP primary /exit was not event-confirmed"
wait_for "exact primary pane absence" pane_missing "$PRIMARY_TARGET"
tail -c "+$((primary_offset + 1))" "$PRIMARY_SESSION" \
  | jq -se 'any(.[]; .type == "custom" and .customType == "session_exit" and .data.kind == "normal")' >/dev/null \
  || fail "real OMP primary did not append a normal session_exit"

cleanup_pid_file "$PRIMARY_HOME/state/.watch.lock/pid" "$DRIVER_ROOT/bin/fm-watch.sh" \
  || fail "primary evidence watcher did not stop under its exact ownership binding"
cleanup_pid_file "$SECOND_HOME/state/.watch.lock/pid" "$SECOND_HOME/bin/fm-watch.sh" \
  || fail "secondmate evidence watcher did not stop under its exact ownership binding"
fm_env "$DRIVER_ROOT/bin/fm-wake-drain.sh" >/dev/null \
  || fail "primary OMP Herdr evidence queue did not drain"
env PATH="$WRAPPER_BIN:$BASE_PATH" HERDR_SESSION="$SESSION" FM_BACKEND=herdr \
  FM_HOME="$SECOND_HOME" FM_ROOT_OVERRIDE="$SECOND_HOME" \
  FM_STATE_OVERRIDE="$SECOND_HOME/state" FM_DATA_OVERRIDE="$SECOND_HOME/data" \
  FM_CONFIG_OVERRIDE="$SECOND_HOME/config" FM_PROJECTS_OVERRIDE="$SECOND_HOME/projects" \
  "$SECOND_HOME/bin/fm-wake-drain.sh" >/dev/null \
  || fail "secondmate OMP Herdr evidence queue did not drain"
[ ! -s "$PRIMARY_HOME/state/.wake-queue" ] \
  || fail "primary OMP Herdr evidence queue retained notifications after drain"
[ ! -s "$SECOND_HOME/state/.wake-queue" ] \
  || fail "secondmate OMP Herdr evidence queue retained notifications after drain"

# Every production Herdr command logged by the wrapper was accepted only with
# the exact trailing named-session binding. The helper owns final teardown and
# its default-session tripwire.
[ -s "$WRAPPER_LOG" ] || fail "production role matrix issued no Herdr commands through the wrapper"
if [ -s "$WRAPPER_LOG.native-omp-probes" ]; then
  grep -Ev "^(agent |--help |agent --help |agent list |agent get [A-Za-z0-9._:@%+-]+ |pane read [A-Za-z0-9._:@%+-]+ --source recent-unwrapped --lines [1-9][0-9]* |agent read [A-Za-z0-9._:@%+-]+ --source recent-unwrapped --lines [1-9][0-9]* |--session $SESSION --help |--session $SESSION agent get [A-Za-z0-9._:@%+-]+ )$" \
    "$WRAPPER_LOG.native-omp-probes" >/dev/null \
    && fail "an unexpected native OMP Herdr probe escaped quarantine"
fi
if [ -s "$WRAPPER_LOG.callers" ]; then
  cat "$WRAPPER_LOG.callers" >&2
  fail "the fixture refused a production Herdr command instead of exercising it"
fi
awk -v session="$SESSION" '$(NF - 1) != "--session" || $NF != session { bad = 1 } END { exit bad }' "$WRAPPER_LOG" \
  || fail "a production Herdr command escaped the exact lab session"
FM_HERDR_LAB_INNER=1 PATH="$WRAPPER_BIN:$BASE_PATH" \
  "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null \
  || fail "guarded Herdr role-matrix teardown or default-session tripwire failed"
TEARDOWN_DONE=1

pass "real Herdr OMP role matrix: primary, worker/scout idle and busy steering, blocked escalation, secondmate, normal exits, recovery, duplicate refusal, and guarded teardown"
