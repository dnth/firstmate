#!/usr/bin/env bash
# tests/fm-stall-recovery.test.sh
# Behavioral tests for bin/fm-stall-recovery.sh, the custody-checked bounded
# auto-recovery the watcher invokes before publishing a stale wake for an
# unhandled steering-inbox record, plus the generation reconciliation in
# bin/fm-spawn.sh's relaunch path that retires the prior incarnation's
# doorbell receipts.
#
# Contract under test (data/fm-stalled-worker-astra-investigate/report.md):
#   - triggers on queued/unproven + persistent unhandled inbox records
#   - distinguishes live-non-turning from missing-endpoint
#   - reconciles stale .acked tombstones against handled state and generation
#   - re-checks inbox AND task/run state immediately before the lifecycle
#     action
#   - proves a terminal outcome or escalates deliberately; publishing the
#     relaunch is not recovery
#   - preserves custody: durable fm-<id> lease, same worktree/branch/commits,
#     no shared-daemon restart, no inbox handled/ moves, no duplicate records
#
# The tests drive the real bin/fm-stall-recovery.sh and, for the
# missing-endpoint path, the real bin/fm-control.sh -> bin/fm-spawn.sh
# relaunch transaction against a stateful fake tmux. No real terminal server
# or agent is required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECOVERY="$ROOT/bin/fm-stall-recovery.sh"
CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-stall-recovery)

# Kill every bun sleeper a case registered, then run the fixture cleanup.
fm_stall_cleanup() {
  local p
  if [ -f "$TMP_ROOT/agent-pids" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done < "$TMP_ROOT/agent-pids"
  fi
  fm_test_cleanup
}
trap fm_stall_cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the lease proof)"; exit 0; }
command -v bun >/dev/null 2>&1 || { echo "skip: bun not found (required by the OMP identity probe)"; exit 0; }

# --- fake backend CLIs -------------------------------------------------------

make_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb real_bun
  fb=$(fm_fakebin "$dir/fake")

  # --- stateful tmux ---------------------------------------------------------
  # $FM_FAKE_TMUX_STATE holds <session>.windows files, one
  # "id<TAB>name<TAB>cwd<TAB>comm" line per window. send-keys semantics model
  # the real foreground transition: an /exit line returns the pane to its
  # shell (comm=bash), any other delivered line means the agent is running
  # (comm=bun, the OMP runtime), and kill-window actually removes the window.
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_TMUX_STATE:?}"
LOG="${FM_FAKE_TMUX_LOG:-/dev/null}"
{ printf 'tmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"

winfile() { printf '%s/%s.windows' "$STATE" "$1"; }
resolve() {  # <ses:name|@id> -> prints "ses<TAB>id<TAB>name<TAB>cwd<TAB>comm"
  local t=$1 ses name f line
  case "$t" in
    @*)
      for f in "$STATE"/*.windows; do
        [ -e "$f" ] || continue
        line=$(awk -F '\t' -v id="$t" '$1 == id {print; exit}' "$f")
        if [ -n "$line" ]; then
          ses=${f##*/}; ses=${ses%.windows}
          printf '%s\t%s\n' "$ses" "$line"
          return 0
        fi
      done
      return 1
      ;;
    *:*)
      ses=${t%%:*}; name=${t#*:}
      f=$(winfile "$ses")
      [ -f "$f" ] || return 1
      line=$(awk -F '\t' -v n="$name" '$2 == n {print; exit}' "$f")
      [ -n "$line" ] || return 1
      printf '%s\t%s\n' "$ses" "$line"
      ;;
    *) return 1 ;;
  esac
}
mark_comm() {  # <ses> <id> <comm>: rewrite a window's comm field in place
  local f tmp
  f=$(winfile "$1")
  [ -f "$f" ] || return 0
  tmp="$f.tmp.$$"
  awk -F '\t' -v id="$2" -v c="$3" 'BEGIN{OFS="\t"} $1 == id {$4 = c} {print}' "$f" > "$tmp" && mv "$tmp" "$f"
}
drop_window() {  # <ses> <id>: remove a window line entirely
  local f tmp
  f=$(winfile "$1")
  [ -f "$f" ] || return 0
  tmp="$f.tmp.$$"
  awk -F '\t' -v id="$2" '$1 != id {print}' "$f" > "$tmp" && mv "$tmp" "$f"
}
omp_doorbell_emulate() {  # <stem>: mirror the generated extension's handshake
  [ -f "$1.omp-ext.ts" ] || return 0
  : > "$1.omp-doorbell-ready"
}
touch_omp_acks() {
  grep -Fq 'FM_OMP_HARNESS=omp' "$FM_FAKE_LAUNCH_LOG" 2>/dev/null || return 0
  for extension in "${FM_FAKE_OMP_ACK_DIR:-/nonexistent}"/*.omp-ext.ts; do
    [ -e "$extension" ] || continue
    omp_doorbell_emulate "${extension%.omp-ext.ts}"
  done
  if [ -n "${FM_FAKE_OMP_ACK:-}" ]; then
    while IFS= read -r ack; do
      [ -z "$ack" ] && continue
      : > "$ack"
      case "$ack" in *.omp-started) omp_doorbell_emulate "${ack%.omp-started}" ;; esac
    done <<EOF
$FM_FAKE_OMP_ACK
EOF
  fi
}

cmd=${1:-}
case "$cmd" in
  list-windows)
    ses=""
    prev=""
    for a in "$@"; do [ "$prev" = "-t" ] && ses=$a; prev=$a; done
    f=$(winfile "$ses")
    if [ ! -f "$f" ]; then
      printf "can't find session: %s\n" "$ses" >&2
      exit 1
    fi
    awk -F '\t' '{print $2}' "$f"
    exit 0 ;;
  has-session)
    ses=""
    prev=""
    for a in "$@"; do [ "$prev" = "-t" ] && ses=$a; prev=$a; done
    [ -f "$(winfile "$ses")" ]
    exit $? ;;
  new-session)
    ses=""
    prev=""
    for a in "$@"; do [ "$prev" = "-s" ] && ses=$a; prev=$a; done
    [ -n "$ses" ] || exit 1
    : > "$(winfile "$ses")"
    exit 0 ;;
  new-window)
    ses="" name="" cwd=""
    prev=""
    for a in "$@"; do
      case "$prev" in
        -t) ses=${a%%:*} ;;
        -n) name=$a ;;
        -c) cwd=$a ;;
      esac
      prev=$a
    done
    f=$(winfile "$ses")
    if [ ! -f "$f" ]; then
      printf "can't find session: %s\n" "$ses" >&2
      exit 1
    fi
    n=$(( $(awk 'END{print NR}' "$f" 2>/dev/null || echo 0) + 1 ))
    wid="@$n"
    printf '%s\t%s\t%s\t%s\n' "$wid" "$name" "$cwd" "bash" >> "$f"
    printf '%s\n' "$wid"
    exit 0 ;;
  display-message)
    target="" fmt=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "-t" ] && target=$a
      fmt=$a
      prev=$a
    done
    if [ -z "$target" ]; then
      printf 'firstmate\n'
      exit 0
    fi
    line=$(resolve "$target") || exit 1
    wid=$(printf '%s' "$line" | awk -F '\t' '{print $2}')
    wname=$(printf '%s' "$line" | awk -F '\t' '{print $3}')
    wcwd=$(printf '%s' "$line" | awk -F '\t' '{print $4}')
    wcomm=$(printf '%s' "$line" | awk -F '\t' '{print $5}')
    case "$fmt" in
      '#{pane_current_path}') printf '%s\n' "$wcwd" ;;
      '#{pane_current_command}') printf '%s\n' "$wcomm" ;;
      '#{pane_pid}') printf '4242\n' ;;
      '#{pane_id}') printf '%%%s\n' "${wid#@}" ;;
      '#{window_id}') printf '%s\n' "$wid" ;;
      *) printf '%s\n' "$wname" ;;
    esac
    exit 0 ;;
  send-keys)
    target=""
    prev=""
    for a in "$@"; do [ "$prev" = "-t" ] && target=$a; prev=$a; done
    line=$(resolve "$target") || exit 1
    ses=${line%%	*}
    wid=$(printf '%s' "$line" | awk -F '\t' '{print $2}')
    exit_sent=0
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      for a in "$@"; do
        case "$a" in
          -*|"$target") ;;
          /exit) exit_sent=1; printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
      touch_omp_acks
    else
      for a in "$@"; do [ "$a" = "/exit" ] && exit_sent=1; done
    fi
    if [ "$exit_sent" -eq 1 ]; then
      mark_comm "$ses" "$wid" "bash"
    else
      mark_comm "$ses" "$wid" "bun"
    fi
    exit 0 ;;
  kill-window)
    target=""
    prev=""
    for a in "$@"; do [ "$prev" = "-t" ] && target=$a; prev=$a; done
    target=${target#=}
    line=$(resolve "$target") || exit 0
    ses=${line%%	*}
    wid=$(printf '%s' "$line" | awk -F '\t' '{print $2}')
    drop_window "$ses" "$wid"
    exit 0 ;;
  kill-session|set-window-option|run-shell) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/tmux"

  # Order-sensitive ps bound to a REAL bun process ($FM_FAKE_AGENT_PID_FILE):
  # the OMP agent-state probe asks `-o args= -p <pid>` (args first) and must
  # see the bun launch line, while the idle-shell proof asks `-p <pid> -o
  # comm=`/`-o args=` (pid first) and must see a bare shell. The pid must be
  # real because fm_omp_process_matches reads /proc/<pid>/exe.
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
set -u
agent_pid=$(cat "${FM_FAKE_AGENT_PID_FILE:?}" 2>/dev/null || printf '4242')
case "$*" in
  *"-o tpgid="*) printf '%s\n' "$agent_pid" ;;
  *"-o args= -p"*) printf 'bun %s\n' "${FM_FAKE_OMP_BIN:?}" ;;
  *"-o comm="*) printf 'bash\n' ;;
  *"-o args="*) printf 'bash\n' ;;
  *"-o stat="*) printf 'Ss\n' ;;
  *"pid=,pgid=,ppid=") printf '%s %s 4242\n' "$agent_pid" "$agent_pid" ;;
  *"pid=,ppid=") printf '%s 4242\n' "$agent_pid" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/ps"

  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
exit 0
SH
  chmod +x "$fb/treehouse"

  # bun resolves to the REAL bun executable: fm-spawn derives the launch
  # identity from `command -v bun` and rewrites omp_bun in the metadata, so
  # the recorded identity and the sleeper's /proc/<pid>/exe must both be the
  # real binary.
  real_bun=$(command -v bun) || { echo "skip: bun not found"; exit 1; }
  ln -sf "$real_bun" "$fb/bun"

  # omp keeps its `#!/usr/bin/env bun` shebang (fm_omp_process_launch_identity
  # requires a bun launch identity) and is therefore real JavaScript executed
  # by real bun.
  cat > "$fb/omp" <<'SH'
#!/usr/bin/env bun
const arg = process.argv[2] || "";
if (arg === "--help") {
  console.log("--model=<value>\n--thinking=<value>\n--auto-approve\n--max-time=<value>\n--session-dir=<value>\n-e, --extension=<value>\n-r, --resume=<value>\n--prewalk native-switch\n--prewalk-into=<value>\n--config=<value>\n--no-prewalk");
} else if (arg === "--version") {
  console.log("omp/18.1.14");
} else if (arg === "config") {
  console.log(`{"key":"prewalk.enabled","value":${process.env.FM_FAKE_OMP_PREWALK_ENABLED || "false"},"type":"boolean"}`);
} else if (arg === "models") {
  console.log('{"models":[{"provider":"openai-codex","id":"gpt-5.6-luna","selector":"openai-codex/gpt-5.6-luna","thinking":["low","medium","high","xhigh","max"]}]}');
}
SH
  chmod +x "$fb/omp"

  # fm-crew-state.sh stub: prints a canned verdict, or moves the named inbox
  # record to handled/ once FM_FAKE_CREW_HANDLE_AFTER calls have happened
  # (the late-ack race test).
  cat > "$fb/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
count_file="${FM_FAKE_CREW_COUNT:-/dev/null}"
n=0
[ -f "$count_file" ] && n=$(cat "$count_file" 2>/dev/null || printf '0')
n=$((n + 1))
[ "$count_file" = /dev/null ] || printf '%s' "$n" > "$count_file"
after=${FM_FAKE_CREW_HANDLE_AFTER:-0}
if [ "$after" -gt 0 ] && [ "$n" -ge "$after" ]; then
  rec="${FM_FAKE_CREW_HANDLE_RECORD:-}"
  if [ -n "$rec" ] && [ -f "$rec" ]; then
    mkdir -p "${rec%/*}/handled"
    mv "$rec" "${rec%/*}/handled/"
  fi
fi
printf 'state: %s · source: status-log · fake crew-state\n' "${FM_FAKE_CREW_STATE:-done}"
SH
  chmod +x "$fb/fm-crew-state.sh"

  # fm-control.sh stub for tests that only need to prove the lifecycle verb
  # was (or was not) invoked.
  cat > "$fb/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -u
{ printf 'fm-control'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "${FM_FAKE_CONTROL_LOG:?}"
exit "${FM_FAKE_CONTROL_RC:-0}"
SH
  chmod +x "$fb/fm-control.sh"

  # git forwards to the real binary, with two test hooks on the first
  # `git -C <wt> status --porcelain` inside fm-control's safe_checkpoint:
  # FM_FAKE_GIT_MOVE names an inbox record moved to handled/, simulating a
  # worker that acknowledges the instruction in the gap between the caller's
  # pre-invocation check and fm-control's in-lock re-check; FM_FAKE_GIT_BUSY
  # names a busy-state file overwritten with a valid busy record, simulating
  # a worker that starts a turn on the instruction during the checkpoint.
  cat > "$fb/git" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-C" ] && [ "${3:-}" = "status" ]; then
  if [ -n "${FM_FAKE_GIT_MOVE:-}" ] && [ -f "$FM_FAKE_GIT_MOVE" ]; then
    mkdir -p "${FM_FAKE_GIT_MOVE%/*}/handled"
    mv "$FM_FAKE_GIT_MOVE" "${FM_FAKE_GIT_MOVE%/*}/handled/"
  fi
  if [ -n "${FM_FAKE_GIT_BUSY:-}" ]; then
    printf 'v1 gen=gentest seq=3 state=busy source=omp-ext event=turn-start ts=1\n' \
      > "$FM_FAKE_GIT_BUSY"
  fi
fi
exec /usr/bin/git "$@"
SH
  chmod +x "$fb/git"

  printf '%s\n' "$fb"
}

# --- fixture helpers ---------------------------------------------------------

# make_case <name> <id> [pool|flat] -> echoes
#   case_dir|home|proj|wt|fakebin|launchlog|slot_dir
make_case() {
  local name=$1 id=$2 shape=${3:-pool}
  local case_dir home proj wt fakebin launchlog slot_dir
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/pool/17/proj"
  slot_dir="$case_dir/pool/17"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" \
    "$case_dir/fake/tmux-state"
  printf 'omp\n' > "$home/config/crew-harness"
  mkdir -p "$home/data/$id"
  printf 'Delivery contract: mode=no-mistakes\nrelaunch brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  # A real bun process stands in for the pane's agent: the OMP identity probe
  # reads /proc/<pid>/exe, so the pid must be a live bun. Registered for
  # cleanup by the EXIT trap below.
  bun -e 'setInterval(() => {}, 1000000)' >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$TMP_ROOT/agent-pids"
  printf '%s\n' "$!" > "$case_dir/fake/agent.pid"
  case "$shape" in
    pool)
      mkdir -p "$case_dir/pool"
      fm_git_worktree "$proj" "$wt" "wt-$name"
      git -C "$proj" fetch --quiet origin
      ;;
    flat)
      wt="$case_dir/wt"
      fm_git_worktree "$proj" "$wt" "wt-$name"
      git -C "$proj" fetch --quiet origin
      ;;
  esac
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$slot_dir"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG SLOT_DIR <<EOF
$1
EOF
}

# write_pool_state <case_dir> <wt> <holder-or-empty>
write_pool_state() {
  local case_dir=$1 wt=$2 holder=${3:-}
  local wt_real
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P)
  if [ -n "$holder" ]; then
    jq -n --arg p "$wt_real" --arg h "$holder" \
      '{worktrees:[{name:"17", path:$p, created_at:"2026-09-17T12:53:36+08:00", leased:true, lease_id:"c300c30567691b53fee1558601cfc49f", lease_holder:$h, leased_at:"2026-09-17T12:53:36+08:00"}]}' \
      > "$case_dir/pool/treehouse-state.json"
  else
    jq -n --arg p "$wt_real" \
      '{worktrees:[{name:"17", path:$p, created_at:"2026-09-17T12:53:36+08:00", leased:false}]}' \
      > "$case_dir/pool/treehouse-state.json"
  fi
}

write_slot_marker() {
  printf 'task=%s\nhome=%s\n' "$2" "$3" > "$1/.fm-slot-owner"
}

write_meta() {
  local file=$1 id=$2 wt=$3 proj=$4
  local omp_bin bun
  omp_bin=$(cd "$FAKEBIN_DIR" && pwd -P)/omp
  bun=$(readlink -f "$FAKEBIN_DIR/bun")
  {
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$proj"
    printf 'harness=omp\n'
    printf 'kind=ship\n'
    printf 'mode=no-mistakes\n'
    printf 'yolo=off\n'
    printf 'tasktmp=\n'
    printf 'model=openai-codex/gpt-5.6-luna\n'
    printf 'effort=high\n'
    printf 'spawn_gen=gen1\n'
    printf 'omp_bin=%s\n' "$omp_bin"
    printf 'omp_bun=%s\n' "$bun"
    printf 'window=ses-%s:fm-%s\n' "$id" "$id"
    printf 'backend=tmux\n'
  } > "$file"
}

# create_prior_artifacts: the prior incarnation's durable runtime files.
create_prior_artifacts() {
  local state=$1 id=$2
  : > "$state/$id.status"
  : > "$state/$id.omp-ext.ts"
  : > "$state/$id.omp-ready"
  : > "$state/$id.omp-started"
  : > "$state/$id.omp-doorbell-ready"
  mkdir -p "$state/$id.omp-doorbell-ready.requests"
}

# write_inbox <state> <id> <seq>: one unhandled instruction record.
write_inbox() {
  local state=$1 id=$2 seq=$3
  mkdir -p "$state/$id.inbox/handled"
  printf 'steer: test instruction %s\n' "$seq" > "$state/$id.inbox/$seq.msg"
}

# write_busy <state> <id> <busy|idle>: a valid armed busy-state record.
write_busy() {
  local state=$1 id=$2 st=$3
  printf 'gentest\n' > "$state/$id.busy-gen"
  printf 'v1 gen=gentest seq=2 state=%s source=fm-spawn event=turn-end ts=1\n' "$st" \
    > "$state/$id.busy-state"
}

# live_window <case_dir> <id> <comm>: the recorded window exists with <comm>.
live_window() {
  printf '@1\tfm-%s\t%s\t%s\n' "$2" "$WT_DIR" "$3" > "$1/fake/tmux-state/ses-$2.windows"
}

# missing_window <case_dir> <id>: the session exists but the window is gone.
missing_window() {
  : > "$1/fake/tmux-state/ses-$2.windows"
}

case_id() {
  printf 'stall-%s-%s' "$1" "$$"
}

# run_recovery <case_dir> <home> <id> <record> <trigger> [env assignments...]
run_recovery() {
  local case_dir=$1 home=$2 id=$3 record=$4 trigger=$5
  shift 5
  RECOVERY_OUT=$(env -u HERDR_PANE_ID -u HERDR_SESSION -u ZELLIJ_SESSION_NAME \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_TMUX_STATE="$case_dir/fake/tmux-state" \
    FM_FAKE_TMUX_LOG="$case_dir/fake/tmux.log" \
    FM_FAKE_AGENT_PID_FILE="$case_dir/fake/agent.pid" \
    FM_FAKE_OMP_BIN="$FAKEBIN_DIR/omp" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_OMP_ACK="$home/state/$id.omp-started" \
    FM_FAKE_OMP_ACK_DIR="$home/state" \
    FM_FAKE_OMP_NO_PREWALK=1 \
    FM_FAKE_CONTROL_LOG="$case_dir/control.log" \
    FM_CREW_STATE_BIN="$FAKEBIN_DIR/fm-crew-state.sh" \
    FM_STALL_RECOVERY_CONTROL_BIN="${FM_STALL_RECOVERY_CONTROL_BIN:-$FAKEBIN_DIR/fm-control.sh}" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_OMP_LAUNCH_ACK_POLLS=20 FM_OMP_DOORBELL_ACK_POLLS=20 \
    FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=5 FM_CONTROL_LAUNCH_WAIT=20 \
    FM_BACKEND_TMUX_IDLE_SHELL_PROOF_POLLS=10 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$@" "$RECOVERY" "$id" "$record" "$trigger" 2>&1)
  RECOVERY_STATUS=$?
}

# --- tests -------------------------------------------------------------------

# Missing endpoint + unhandled record + clean custody: the real fm-control
# relaunch transaction runs, the replacement window is created in the recorded
# worktree, the ladder resets, and the prior generation's doorbell receipts
# are retired so the new incarnation's doorbell is not suppressed.
test_missing_endpoint_recovers_via_control() {
  local rec id record requests
  id=$(case_id missing-e2e)
  rec=$(make_case missing-e2e "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  requests="$HOME_DIR/state/$id.omp-doorbell-ready.requests"
  : > "$requests/request.1.pending.acked"
  : > "$requests/request.2.pending.unproven"
  printf '001.msg\t3\t1\n' > "$HOME_DIR/state/$id.inbox/.ring-state"
  printf '001.msg\n' > "$HOME_DIR/state/$id.inbox/.escalated"
  missing_window "$CASE_DIR" "$id"

  FM_STALL_RECOVERY_CONTROL_BIN="$CONTROL" \
    run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  expect_code 0 "$RECOVERY_STATUS" "missing-endpoint recovery should exit 0; got: $RECOVERY_OUT"
  assert_contains "$RECOVERY_OUT" "verdict=deferred" "missing-endpoint recovery did not defer pending the episode"
  assert_contains "$RECOVERY_OUT" "missing-endpoint" "verdict did not name the missing-endpoint path"
  assert_grep "new-window" "$CASE_DIR/fake/tmux.log" "relaunch did not create a replacement tmux window"
  assert_grep "$WT_DIR" "$CASE_DIR/fake/tmux.log" "replacement window was not created in the recorded worktree"
  assert_grep "phase=complete" "$HOME_DIR/state/$id.control-relaunch" "the relaunch transaction did not complete"
  assert_absent "$HOME_DIR/state/$id.inbox/.escalated" "the spent escalation marker survived the ladder reset"
  assert_absent "$HOME_DIR/state/$id.inbox/.ring-state" "the spent ring ladder survived the reset"
  assert_absent "$requests/request.1.pending.acked" "stale .acked tombstone survived the relaunch"
  assert_absent "$requests/request.2.pending.unproven" "stale .unproven receipt survived the relaunch"
  assert_grep "001.msg" "$HOME_DIR/state/$id.inbox/.recovery-attempts" "the per-record attempt bound was not recorded"
  assert_grep "control_relaunch_tx=" "$HOME_DIR/state/$id.meta" "fm-spawn did not record the relaunch transaction id in the published metadata"
  assert_grep "relaunch_tx=" "$HOME_DIR/state/$id.control-relaunch" "the relaunch journal did not record the transaction id"
  assert_present "$record" "the unhandled instruction record was moved or deleted"
  assert_grep "stall auto-recovery" "$HOME_DIR/state/$id.status" "no audit note was appended to the task status"
  pass "missing endpoint: real relaunch publishes, ladder resets, stale receipts retire, record stays unhandled"
}

# Live endpoint whose agent is idle (turn ended, record still unhandled): the
# live-non-turning path invokes the lifecycle verb.
test_live_non_turning_recovers() {
  local rec id record
  id=$(case_id live-idle)
  rec=$(make_case live-idle "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  write_busy "$HOME_DIR/state" "$id" idle
  live_window "$CASE_DIR" "$id" bun

  run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" ladder-exhausted
  expect_code 0 "$RECOVERY_STATUS" "live-non-turning recovery should exit 0; got: $RECOVERY_OUT"
  assert_contains "$RECOVERY_OUT" "verdict=deferred" "live-non-turning recovery did not defer pending the episode"
  assert_contains "$RECOVERY_OUT" "live-non-turning" "verdict did not name the live path"
  assert_grep "relaunch" "$CASE_DIR/control.log" "the lifecycle verb was not invoked"
  pass "live non-turning worker: idle verdict plus clean custody publishes the relaunch"
}

# A live endpoint with a provably busy agent defers: the worker may be
# mid-turn on the instruction.
test_live_busy_defers() {
  local rec id record
  id=$(case_id live-busy)
  rec=$(make_case live-busy "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  write_busy "$HOME_DIR/state" "$id" busy
  live_window "$CASE_DIR" "$id" bun

  run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" ladder-exhausted
  assert_contains "$RECOVERY_OUT" "verdict=deferred" "a busy worker did not defer"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran against a busy worker"
  pass "live busy worker: recovery defers without a lifecycle action"
}

# A live endpoint with no semantic busy proof escalates: unknown is never a
# custody proof.
test_live_unknown_busy_escalates() {
  local rec id record
  id=$(case_id live-unknown)
  rec=$(make_case live-unknown "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  live_window "$CASE_DIR" "$id" bun

  run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" ladder-exhausted
  assert_contains "$RECOVERY_OUT" "verdict=escalate" "an unprovable busy verdict did not escalate"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran without a busy proof"
  pass "live worker with no busy proof: recovery escalates"
}

# A record already handled ends the episode quietly - no lifecycle action.
test_handled_record_recovers_quietly() {
  local rec id record
  id=$(case_id handled)
  rec=$(make_case handled "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  mkdir -p "$HOME_DIR/state/$id.inbox/handled"
  printf 'steer: done\n' > "$HOME_DIR/state/$id.inbox/handled/001.msg"
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"

  run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  assert_contains "$RECOVERY_OUT" "verdict=recovered" "a handled record did not close the episode"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran for a handled record"
  pass "handled record: recovery reports the terminal outcome without a relaunch"
}

# A handled move DURING the custody probe still cancels the action: the
# crew-state stub moves the record to handled/ on its second call (the final
# pre-lifecycle proof), so the post-proof record check sees an empty inbox.
test_late_handled_cancels_relaunch() {
  local rec id record
  id=$(case_id late-ack)
  rec=$(make_case late-ack "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"

  FM_FAKE_CREW_HANDLE_AFTER=2 FM_FAKE_CREW_HANDLE_RECORD="$record" \
    FM_FAKE_CREW_COUNT="$CASE_DIR/crew-count" \
    run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  assert_contains "$RECOVERY_OUT" "verdict=recovered" "a late handled move did not cancel the relaunch"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran after the record was handled"
  pass "late handled move during the custody probe cancels the relaunch"
}

# Uncommitted work in the worktree is exactly what recovery preserves: the
# stalled worker's unlanded changes must NOT block the relaunch, and the
# replacement inherits the same worktree, branch, and dirty state untouched.
test_dirty_worktree_recovers_preserving_work() {
  local rec id record
  id=$(case_id dirty)
  rec=$(make_case dirty "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"
  printf 'uncommitted\n' > "$WT_DIR/scratch.txt"

  FM_STALL_RECOVERY_CONTROL_BIN="$CONTROL" \
    run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  expect_code 0 "$RECOVERY_STATUS" "dirty-worktree recovery should exit 0; got: $RECOVERY_OUT"
  assert_contains "$RECOVERY_OUT" "verdict=deferred" "a dirty worktree did not defer pending the episode"
  assert_grep "new-window" "$CASE_DIR/fake/tmux.log" "relaunch did not create a replacement tmux window"
  assert_grep "worktree_dirty=yes" "$HOME_DIR/state/$id.control-relaunch" "the relaunch checkpoint did not record the dirty state"
  assert_grep "uncommitted" "$WT_DIR/scratch.txt" "the relaunch discarded uncommitted work"
  assert_present "$record" "the unhandled instruction record was moved or deleted"
  pass "dirty worktree: recovery relaunches and preserves uncommitted work in place"
}

# Commits not on any remote-tracking ref are unlanded work the replacement
# inherits: recovery must relaunch into the same branch, not escalate.
test_unlanded_commits_recover_preserving_branch() {
  local rec id record head_before
  id=$(case_id unlanded)
  rec=$(make_case unlanded "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"
  printf 'wip\n' > "$WT_DIR/wip.txt"
  git -C "$WT_DIR" add wip.txt
  git -C "$WT_DIR" -c user.email=t@t -c user.name=t commit -qm wip
  head_before=$(git -C "$WT_DIR" rev-parse HEAD)

  FM_STALL_RECOVERY_CONTROL_BIN="$CONTROL" \
    run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  expect_code 0 "$RECOVERY_STATUS" "unlanded-commits recovery should exit 0; got: $RECOVERY_OUT"
  assert_contains "$RECOVERY_OUT" "verdict=deferred" "unlanded commits did not defer pending the episode"
  assert_grep "new-window" "$CASE_DIR/fake/tmux.log" "relaunch did not create a replacement tmux window"
  assert_equals "$head_before" "$(git -C "$WT_DIR" rev-parse HEAD)" "the relaunch moved the branch head"
  assert_grep "worktree_head=$head_before" "$HOME_DIR/state/$id.control-relaunch" "the relaunch checkpoint did not record the preserved head"
  pass "unlanded commits: recovery relaunches into the same branch and preserves every commit"
}

# The per-record bound: a second automatic attempt for the same record
# escalates instead of looping relaunches. The bound is a fixed invariant -
# FM_STALL_RECOVERY_MAX must not be able to raise it.
test_attempt_cap_escalates() {
  local rec id record
  id=$(case_id capped)
  rec=$(make_case capped "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  printf '001.msg\t1\n' > "$HOME_DIR/state/$id.inbox/.recovery-attempts"
  missing_window "$CASE_DIR" "$id"

  FM_STALL_RECOVERY_MAX=5 \
    run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  assert_contains "$RECOVERY_OUT" "verdict=escalate" "a spent attempt bound did not escalate"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran past the attempt bound"
  pass "attempt bound: a second automatic relaunch for the same record escalates"
}

# A slot leased to a different holder is not this task's worktree.
test_foreign_lease_escalates() {
  local rec id record
  id=$(case_id foreign-lease)
  rec=$(make_case foreign-lease "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-other-task"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"

  run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  assert_contains "$RECOVERY_OUT" "verdict=escalate" "a foreign lease did not escalate"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran against a foreign-leased worktree"
  pass "foreign lease: recovery escalates rather than relaunching into another task's slot"
}

# A worktree outside the pool cannot prove ownership: escalate.
test_non_pool_worktree_escalates() {
  local rec id record
  id=$(case_id flat)
  rec=$(make_case flat "$id" flat)
  read_case "$rec"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"

  run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  assert_contains "$RECOVERY_OUT" "verdict=escalate" "a non-pool worktree did not escalate"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran against an unprovable worktree"
  pass "non-pool worktree: recovery escalates without ownership proof"
}

# A working crew-state needs firstmate, not auto-relaunch.
test_working_crew_state_escalates() {
  local rec id record
  id=$(case_id working)
  rec=$(make_case working "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"

  FM_FAKE_CREW_STATE=working \
    run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  assert_contains "$RECOVERY_OUT" "verdict=escalate" "a working crew-state did not escalate"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran against a working task"
  pass "working crew-state: recovery escalates to firstmate"
}

# A secondmate is never an ordinary direct report: escalate.
test_secondmate_kind_escalates() {
  local rec id record
  id=$(case_id secondmate)
  rec=$(make_case secondmate "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  printf 'kind=secondmate\n' >> "$HOME_DIR/state/$id.meta"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"

  run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  assert_contains "$RECOVERY_OUT" "verdict=escalate" "a secondmate did not escalate"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran against a secondmate"
  pass "secondmate kind: recovery escalates; secondmates recover through their own path"
}

# A refused relaunch preserves the prior generation's receipts: the purge runs
# only after every refusal gate, so a live-agent refusal deletes nothing.
test_refused_relaunch_preserves_receipts() {
  local rec id requests
  id=$(case_id refuse-keep)
  rec=$(make_case refuse-keep "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  requests="$HOME_DIR/state/$id.omp-doorbell-ready.requests"
  : > "$requests/request.1.pending.acked"
  live_window "$CASE_DIR" "$id" bun

  SPAWN_OUT=$(env -u HERDR_PANE_ID -u HERDR_SESSION -u ZELLIJ_SESSION_NAME \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_FAKE_TMUX_STATE="$CASE_DIR/fake/tmux-state" \
    FM_FAKE_TMUX_LOG="$CASE_DIR/fake/tmux.log" \
    FM_FAKE_AGENT_PID_FILE="$CASE_DIR/fake/agent.pid" \
    FM_FAKE_OMP_BIN="$FAKEBIN_DIR/omp" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_OMP_ACK="$HOME_DIR/state/$id.omp-started" \
    FM_FAKE_OMP_ACK_DIR="$HOME_DIR/state" \
    FM_FAKE_OMP_NO_PREWALK=1 \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_OMP_LAUNCH_ACK_POLLS=20 FM_OMP_DOORBELL_ACK_POLLS=20 \
    FM_BACKEND_TMUX_IDLE_SHELL_PROOF_POLLS=10 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  SPAWN_STATUS=$?
  [ "$SPAWN_STATUS" -ne 0 ] || fail "a live-agent relaunch should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "live agent" "the refusal did not name the live agent"
  assert_present "$requests/request.1.pending.acked" "a refused relaunch deleted the prior generation's receipts"
  pass "refused relaunch: prior doorbell receipts survive untouched"
}

# A lifecycle lock held by a live process means another lifecycle action is in
# flight: recovery defers instead of racing it, and the watcher re-evaluates on
# the next cycle.
# shellcheck disable=SC2031 # This test intentionally coordinates with a background lock-holder subshell.
test_held_lifecycle_lock_defers() {
  local rec id record lockdir holder n
  id=$(case_id lockheld)
  rec=$(make_case lockheld "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"

  lockdir="$HOME_DIR/state/.control-$id.lock"
  ( . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lockdir" || exit 1
    : > "$HOME_DIR/state/.test-lock-ready"
    sleep 60 ) &
  holder=$!
  n=0
  while [ ! -e "$HOME_DIR/state/.test-lock-ready" ] && [ "$n" -lt 100 ]; do
    sleep 0.05; n=$((n + 1))
  done
  [ -e "$HOME_DIR/state/.test-lock-ready" ] \
    || { kill "$holder" 2>/dev/null; fail "the lock holder never acquired $lockdir"; }

  run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  assert_contains "$RECOVERY_OUT" "verdict=deferred" "a held lifecycle lock did not defer recovery"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran while the lock was held"
  pass "held lifecycle lock: recovery defers rather than racing another lifecycle action"
}

# The generated OMP extension must serialize busy-state writes: a turn_end's
# idle can never land after a following turn_start's busy, or a live worker
# reads falsely idle (and a dead one falsely busy suppresses recovery). The
# fake FM_ROOT wraps fm-busy-event.sh with a delay on the turn-end write, so
# an unserialized pair deterministically inverts.
test_omp_ext_serializes_busy_events() {
  local rec id record fakeroot ext out tool
  id=$(case_id omp-order)
  rec=$(make_case omp-order "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"

  # Fake FM_ROOT: every bin entry is the real script except fm-busy-event.sh,
  # which delays the turn-end apply so an unserialized turn-start write would
  # land first and leave the worker falsely busy.
  fakeroot="$CASE_DIR/fakeroot"
  mkdir -p "$fakeroot/bin" "$fakeroot/.omp/extensions"
  for tool in "$ROOT"/bin/*; do
    [ "$(basename "$tool")" = fm-busy-event.sh ] || ln -s "$tool" "$fakeroot/bin/$(basename "$tool")"
  done
  ln -s "$ROOT/.omp/extensions/lib" "$fakeroot/.omp/extensions/lib"
  cat > "$fakeroot/bin/fm-busy-event.sh" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = "turn-end" ]; then sleep 0.4; fi
done
exec "$ROOT/bin/fm-busy-event.sh" "\$@"
SH
  chmod +x "$fakeroot/bin/fm-busy-event.sh"

  FM_ROOT_OVERRIDE="$fakeroot" FM_STALL_RECOVERY_CONTROL_BIN="$CONTROL" \
    run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  expect_code 0 "$RECOVERY_STATUS" "recovery under the fake root should exit 0; got: $RECOVERY_OUT"
  assert_contains "$RECOVERY_OUT" "verdict=deferred" "recovery under the fake root did not publish the relaunch"
  ext="$HOME_DIR/state/$id.omp-ext.ts"
  assert_present "$ext" "the relaunch did not regenerate the OMP extension"

  # Fire turn_end then turn_start concurrently (the runtime may dispatch

  # handlers without awaiting them). The busy write must still land last.
  EXT_PATH="$ext" bun -e '
    const mod = await import(process.env.EXT_PATH);
    const handlers = {};
    mod.default({ on: (n, fn) => { handlers[n] = fn; } });
    handlers["turn_end"]();
    handlers["turn_start"]();
    await new Promise((r) => setTimeout(r, 3000));
  ' || fail "driving the generated OMP extension failed"
  out=$(cat "$HOME_DIR/state/$id.busy-state" 2>/dev/null || true)
  case "$out" in
    *"state=busy"*"event=turn-start"*) ;;
    *) fail "turn_end's idle write landed after turn_start's busy (final record: '${out:-missing}'); the extension does not serialize busy events" ;;
  esac
  pass "OMP extension serializes busy-state writes: turn-start busy lands after turn-end idle"
}

# A record handled in the gap between the caller's pre-invocation check and
# fm-control's in-lock re-check must still cancel the relaunch: the fake git
# moves the record to handled/ during safe_checkpoint, so fm-control's own
# stall-record proof sees it resolved and exits 3 before the agent is touched.
# The cancelled transaction must also leave the worker's instructions
# byte-exact - no relaunch means no progress-note append survives.
test_in_lock_handled_record_cancels_relaunch() {
  local rec id record
  id=$(case_id inlock-ack)
  rec=$(make_case inlock-ack "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  missing_window "$CASE_DIR" "$id"
  cp -p "$HOME_DIR/data/$id/brief.md" "$CASE_DIR/brief.orig"

  FM_FAKE_GIT_MOVE="$record" FM_STALL_RECOVERY_CONTROL_BIN="$CONTROL" \
    run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  expect_code 0 "$RECOVERY_STATUS" "in-lock cancellation should exit 0; got: $RECOVERY_OUT"
  assert_contains "$RECOVERY_OUT" "verdict=recovered" "a record resolved inside the lock did not report recovered"
  assert_no_grep "new-window" "$CASE_DIR/fake/tmux.log" "the relaunch created a window for a resolved record"
  assert_grep "cancelled:record-resolved" "$HOME_DIR/state/$id.control-relaunch" "the journal did not record the in-lock cancellation"
  assert_present "$HOME_DIR/state/$id.inbox/handled/001.msg" "the handled record is not in handled/"
  cmp -s "$CASE_DIR/brief.orig" "$HOME_DIR/data/$id/brief.md" \
    || fail "a cancelled relaunch left the worker's instructions modified"
  pass "in-lock handled record: fm-control cancels the relaunch before touching the agent"
}

# A worker that goes busy DURING the checkpoint - publishing a valid
# turn-start busy record while its instruction stays unhandled - must never
# be interrupted: the supervised relaunch cancels with the deferred verdict,
# sends no interrupt or exit keys, creates no replacement window, and leaves
# the worker's instructions byte-exact. The fake git publishes the busy
# record inside fm-control's safe_checkpoint, after every earlier custody
# proof already saw an idle worker.
test_busy_during_checkpoint_defers() {
  local rec id record
  id=$(case_id checkpoint-busy)
  rec=$(make_case checkpoint-busy "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  write_busy "$HOME_DIR/state" "$id" idle
  live_window "$CASE_DIR" "$id" bun
  cp -p "$HOME_DIR/data/$id/brief.md" "$CASE_DIR/brief.orig"

  FM_FAKE_GIT_BUSY="$HOME_DIR/state/$id.busy-state" \
    FM_STALL_RECOVERY_CONTROL_BIN="$CONTROL" \
    run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" ladder-exhausted
  expect_code 0 "$RECOVERY_STATUS" "busy-during-checkpoint recovery should exit 0; got: $RECOVERY_OUT"
  assert_contains "$RECOVERY_OUT" "verdict=deferred" "a worker that went busy during the checkpoint did not defer"
  assert_no_grep "Escape" "$CASE_DIR/fake/tmux.log" "an interrupt key was sent to a worker that went busy during the checkpoint"
  assert_no_grep "/exit" "$CASE_DIR/fake/tmux.log" "an exit command was sent to a worker that went busy during the checkpoint"
  assert_no_grep "new-window" "$CASE_DIR/fake/tmux.log" "the relaunch created a window for a worker that went busy"
  assert_grep "cancelled:worker-busy" "$HOME_DIR/state/$id.control-relaunch" "the journal did not record the busy-worker cancellation"
  assert_present "$record" "the unhandled instruction record was moved or deleted"
  assert_grep "001.msg" "$HOME_DIR/state/$id.inbox/.recovery-attempts" "the deferred episode did not record its attempt bound"
  cmp -s "$CASE_DIR/brief.orig" "$HOME_DIR/data/$id/brief.md" \
    || fail "a busy-cancelled relaunch left the worker's instructions modified"
  pass "busy during checkpoint: recovery defers without interrupt, exit, or relaunch"
}

# A well-formed attempt marker naming a record that was since handled must
# not deny the next queued record its own first attempt: structure is
# validated separately from identity, so 002.msg recovers with a fresh count
# even though the watcher never observed an empty inbox between the two.
test_next_record_gets_own_attempt() {
  local rec id record
  id=$(case_id next-record)
  rec=$(make_case next-record "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  write_inbox "$HOME_DIR/state" "$id" 002
  printf '001.msg\t1\n' > "$HOME_DIR/state/$id.inbox/.recovery-attempts"
  mv "$HOME_DIR/state/$id.inbox/001.msg" "$HOME_DIR/state/$id.inbox/handled/"
  record="$HOME_DIR/state/$id.inbox/002.msg"
  missing_window "$CASE_DIR" "$id"

  FM_STALL_RECOVERY_CONTROL_BIN="$CONTROL" \
    run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  expect_code 0 "$RECOVERY_STATUS" "next-record recovery should exit 0; got: $RECOVERY_OUT"
  assert_contains "$RECOVERY_OUT" "verdict=deferred" "the next queued record did not get its own recovery attempt"
  assert_grep "phase=complete" "$HOME_DIR/state/$id.control-relaunch" "the relaunch transaction did not complete for the next record"
  assert_grep "002.msg" "$HOME_DIR/state/$id.inbox/.recovery-attempts" "the new record's attempt bound was not recorded"
  assert_no_grep "001.msg" "$HOME_DIR/state/$id.inbox/.recovery-attempts" "the prior record's spent marker survived the atomic replace"
  pass "next record: a handled record's spent marker does not consume the next record's attempt"
}

# A corrupt attempt marker still fails closed: structure validation is
# unchanged, so an unparseable marker escalates without any lifecycle action.
test_malformed_attempt_marker_escalates() {
  local rec id record
  id=$(case_id bad-marker)
  rec=$(make_case bad-marker "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  write_inbox "$HOME_DIR/state" "$id" 001
  record="$HOME_DIR/state/$id.inbox/001.msg"
  printf 'garbage-no-tab\n' > "$HOME_DIR/state/$id.inbox/.recovery-attempts"
  missing_window "$CASE_DIR" "$id"

  run_recovery "$CASE_DIR" "$HOME_DIR" "$id" "$record" endpoint-unavailable
  assert_contains "$RECOVERY_OUT" "verdict=escalate" "a corrupt attempt marker did not escalate"
  assert_contains "$RECOVERY_OUT" "malformed recovery-attempt marker" "the escalation did not name the corrupt marker"
  assert_absent "$CASE_DIR/control.log" "the lifecycle verb ran against a corrupt attempt marker"
  pass "corrupt attempt marker: recovery escalates without a lifecycle action"
}

# --- run ---------------------------------------------------------------------

test_missing_endpoint_recovers_via_control
test_live_non_turning_recovers
test_live_busy_defers
test_live_unknown_busy_escalates
test_handled_record_recovers_quietly
test_late_handled_cancels_relaunch
test_dirty_worktree_recovers_preserving_work
test_unlanded_commits_recover_preserving_branch
test_attempt_cap_escalates
test_foreign_lease_escalates
test_non_pool_worktree_escalates
test_working_crew_state_escalates
test_secondmate_kind_escalates
test_refused_relaunch_preserves_receipts
test_held_lifecycle_lock_defers
test_in_lock_handled_record_cancels_relaunch
test_omp_ext_serializes_busy_events
test_busy_during_checkpoint_defers
test_next_record_gets_own_attempt
test_malformed_attempt_marker_escalates

pass "all stall-recovery tests"
