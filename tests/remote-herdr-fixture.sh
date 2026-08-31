#!/usr/bin/env bash
# tests/remote-herdr-fixture.sh - the stateful herdr CLI fixture the remote
# second-mate suites install on their fake remote host.
#
# A remote second mate always launches on the Herdr backend
# (docs/remote-secondmates.md), so a remote-route test needs a herdr CLI on the
# remote code root's own bin directory. This fixture models the workspace, tab,
# pane, and agent facts bin/backends/herdr.sh actually reads, backed by a JSON
# state file mutated with real jq, using the same verified herdr behaviors as
# tests/fm-backend-herdr.test.sh's stateful fake: workspace create seeds one
# default tab and returns its tab and root pane in the same response, closing a
# tab's only pane closes the tab, and agent get reports agent_not_found for a
# pane no agent has registered on.
#
# Beyond that it models the pane IO a real launch performs. A pane reports a
# registered agent once anything has been typed into it, and submitting starts
# one turn: the next agent read reports working and the pane settles back to
# idle, which is the native transition the adapter confirms a submit with.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"
#   install_remote_herdr_fixture <remote-root> <state-file> <log-file> \
#     <send-fail-flag> <socket-path> [<omp-ack-pid> <omp-bun> <omp-bin> \
#     <omp-active-pid-file> <force-idle-file> <pane-text-log>]
#
# Every invocation is appended verbatim to <log-file>, so a test reads back what
# the remote pane received. Creating <send-fail-flag> makes every pane write
# fail, which is how a test simulates an endpoint that cannot be reached.
# Supplying the three OMP acknowledgement fields makes an OMP launch publish the
# same home-owned integration marker, lock, and durable-session pointer that the
# real primary extension publishes, while leaving every non-OMP launch unchanged.
# An active-PID file replaces the fixture's inert foreground process with one
# real listener process, while a force-idle file prevents typed submission from
# manufacturing a turn-start acknowledgement.

install_remote_herdr_fixture() { # <remote-root> <state> <log> <send-fail> <socket>
  local remote_root=$1 state=$2 log=$3 send_fail=$4 socket=$5 script="$1/bin/herdr"
  local omp_ack_pid=${6:-} omp_bun=${7:-} omp_bin=${8:-} omp_active_pid_file=${9:-} force_idle_file=${10:-} pane_text_log=${11:-}
  local real_ps ps_fixture
  mkdir -p "$remote_root/bin"
  cat > "$script" <<SH
#!/usr/bin/env bash
set -u
STATE='$state'
LOG='$log'
SEND_FAIL='$send_fail'
SOCKET='$socket'
SH
  printf 'OMP_ACK_PID=%q\nOMP_BUN=%q\nOMP_BIN=%q\nOMP_ACTIVE_PID_FILE=%q\nFORCE_IDLE_FILE=%q\nPANE_TEXT_LOG=%q\n' \
    "$omp_ack_pid" "$omp_bun" "$omp_bin" "$omp_active_pid_file" "$force_idle_file" "$pane_text_log" >> "$script"
  cat >> "$script" <<'SH'
printf '%s\n' "$*" >> "$LOG"
jq_state() { jq "$@" "$STATE"; }
save() { tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
publish_omp_ack() { # <pane> <launch>
  local pane=$1 launch=$2 cwd session version
  [ -n "$OMP_ACK_PID" ] && [ -n "$OMP_BUN" ] && [ -n "$OMP_BIN" ] || return 0
  case "$launch" in
    *FM_OMP_SESSION_POINTER=*)
      cwd=$(jq_state -r --arg p "$pane" '.tabs[] | select(.pane_id == $p) | .cwd // empty')
      [ -n "$cwd" ] || return 1
      mkdir -p "$cwd/state/omp-sessions"
      session="$cwd/state/omp-sessions/selected.jsonl"
      printf '{"type":"session"}\n' > "$session"
      printf '%s\n' "$session" > "$cwd/state/.omp-session"
      version=$(bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_primary_watch_version "$1/.omp/extensions/fm-primary-omp.ts" "$1"' _ "$cwd")
      printf '%s\n%s\n%s\n%s\n' "$version" "$OMP_ACK_PID" "$OMP_BUN" "$OMP_BIN" \
        > "$cwd/state/.omp-primary-extension-loaded"
      printf '%s\n' "$OMP_ACK_PID" > "$cwd/state/.lock"
      jq_state --arg p "$pane" --arg session "$session" '.omp_session[$p] = $session' | save
      ;;
  esac
}
ws=""; label=""; cwd=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
  esac
done
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "server "*|"server") : ;;
  "workspace list") jq_state '{result:{workspaces:.workspaces}}' ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" --arg cwd "$cwd" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel, cwd:$cwd}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list") jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}' ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg cwd "$cwd" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid, cwd:$cwd}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "tab close")
    jq_state --arg t "${3:-}" '.tabs |= [.[]|select(.tab_id != $t)]' | save ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}' ;;
  "pane get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '[.tabs[]|select(.pane_id==$p)]|length')" = 0 ]; then
      printf '{"error":{"code":"pane_not_found","message":"%s"}}\n' "$pane"
    else
      printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane"
    fi
    ;;
  "pane close")
    jq_state --arg p "${3:-}" \
      '.tabs |= [.[]|select(.pane_id != $p)]
       | .typed |= with_entries(select(.key != $p))
       | .working |= with_entries(select(.key != $p))' | save ;;
  "pane send-text")
    [ ! -f "$SEND_FAIL" ] || exit 1
    [ -z "$PANE_TEXT_LOG" ] || printf '%s\n' "${4:-}" >> "$PANE_TEXT_LOG"
    jq_state --arg p "${3:-}" --arg text "${4:-}" \
      '.typed[$p] = true | .launch[$p] = $text' | save ;;
  "pane run")
    [ ! -f "$SEND_FAIL" ] || exit 1
    pane=${3:-}; launch=${4:-}
    jq_state --arg p "$pane" --arg text "$launch" \
      '.typed[$p] = true | .launch[$p] = $text | .working[$p] = true' | save
    publish_omp_ack "$pane" "$launch"
    ;;
  "pane send-keys")
    [ ! -f "$SEND_FAIL" ] || exit 1
    pane=${3:-}
    jq_state --arg p "$pane" '.typed[$p] = true | .working[$p] = true' | save
    launch=$(jq_state -r --arg p "$pane" '.launch[$p] // ""')
    if [ "${4:-}" = enter ] && [ ! -f "$FORCE_IDLE_FILE" ]; then
      publish_omp_ack "$pane" "$launch"
    fi
    ;;
  "pane read") printf '\n' ;;
  "pane process-info")
    pane_pid=987654
    pane_name=fish
    if [ -n "$OMP_ACTIVE_PID_FILE" ] && [ -f "$OMP_ACTIVE_PID_FILE" ]; then
      IFS= read -r candidate < "$OMP_ACTIVE_PID_FILE" || candidate=
      case "$candidate" in
        ''|*[!0-9]*) ;;
        *) pane_pid=$candidate; pane_name=bun ;;
      esac
    fi
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"%s","argv0":"%s"}]}}}\n' \
      "${4:-${3:-}}" "$pane_pid" "$pane_pid" "$pane_pid" "$pane_name" "$pane_name"
    ;;
  "agent get")
    pane=${3:-}
    omp_session=$(jq_state -r --arg p "$pane" '.omp_session[$p] // empty')
    if [ "$(jq_state -r --arg p "$pane" '.working[$p] // false')" = true ]; then
      jq_state --arg p "$pane" '.working |= with_entries(select(.key != $p))' | save
      agent_status=working
    elif [ "$(jq_state -r --arg p "$pane" '.typed[$p] // false')" = true ]; then
      agent_status=idle
    else
      printf '{"error":{"code":"agent_not_found","message":"%s"}}\n' "$pane"
      exit 0
    fi
    if [ -n "$omp_session" ]; then
      printf '{"result":{"agent":{"agent":"omp","agent_status":"%s","agent_session":{"kind":"path","value":"%s"}}}}\n' \
        "$agent_status" "$omp_session"
    else
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$agent_status"
    fi
    ;;
  "session list"*)
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s"},{"name":"fm-remote","running":true,"socket_path":"%s"}]}\n' "$SOCKET" "$SOCKET" ;;
esac
exit 0
SH
  chmod +x "$script"
  real_ps=$(command -v ps) || return 1
  ps_fixture="$remote_root/bin/ps"
  cat > "$ps_fixture" <<SH
#!/usr/bin/env bash
REAL_PS='$real_ps'
ACTIVE_PID_FILE='$omp_active_pid_file'
active_pid=
if [ -n "\$ACTIVE_PID_FILE" ] && [ -f "\$ACTIVE_PID_FILE" ]; then
  IFS= read -r active_pid < "\$ACTIVE_PID_FILE" || active_pid=
fi
if [ -n "\$active_pid" ] && [ "\${1:-}" = -p ] && [ "\${2:-}" = "\$active_pid" ] \
   && [ "\${3:-}" = -o ] && [ "\${4:-}" = comm= ]; then
  printf '%s\n' bun
  exit 0
fi
case "\$*" in
  "-axo pid=,ppid=")
    "\$REAL_PS" "\$@"
    printf '%s\n' '987654 1'
    ;;
  "-p 987654 -o stat=") printf '%s\n' 'S' ;;
  *) exec "\$REAL_PS" "\$@" ;;
esac
SH
  chmod +x "$ps_fixture"
  reset_remote_herdr_fixture "$state"
}

# reset_remote_herdr_fixture <state>: return the fake host to "no workspaces,
# tabs, or panes", which is what a test means by "the previous endpoint is gone".
reset_remote_herdr_fixture() { # <state>
  printf '{"next":1,"workspaces":[],"tabs":[],"typed":{},"working":{},"launch":{},"omp_session":{}}\n' > "$1"
}
