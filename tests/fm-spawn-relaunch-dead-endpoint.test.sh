#!/usr/bin/env bash
# tests/fm-spawn-relaunch-dead-endpoint.test.sh
# Regression tests for the proven-gone relaunch endpoint recovery in
# bin/fm-spawn.sh and bin/fm-control.sh (2026-09-17 incident on
# ic-prod-outage-astra-fix): when the recorded endpoint is authoritatively
# absent, relaunch must skip the impossible live-pane cwd proof and recreate
# the endpoint inside the recorded worktree - but only while the task still
# owns that worktree (a firstmate slot-owner claim or a durable fm-<id>
# Treehouse lease).
#
# These tests exercise the real executables through their public interfaces:
# bin/fm-spawn.sh <id> --relaunch and bin/fm-control.sh <id> relaunch, against
# stateful fake backend CLIs (tmux, herdr, zellij, cmux) plus the fake-omp/bun
# launch plumbing pattern from tests/fm-omp-relaunch-guard.test.sh. No real
# terminal server or agent is required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-relaunch-dead-endpoint)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by backend adapters)"; exit 0; }

# --- fake backend CLIs -------------------------------------------------------

make_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb
  fb=$(fm_fakebin "$dir/fake")

  # --- stateful tmux ---------------------------------------------------------
  # State dir $FM_FAKE_TMUX_STATE holds <session>.windows files, one
  # "id<TAB>name<TAB>cwd<TAB>comm" line per window. A present-but-empty file
  # is a live session with no windows; an absent file is a dead session.
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
omp_doorbell_emulate() {  # <stem>: mirror the generated extension's handshake
  [ -f "$1.omp-ext.ts" ] || return 0
  : > "$1.omp-doorbell-ready"
}
touch_omp_acks() {  # after a launch literal landed, ack the OMP harness
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
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      for a in "$@"; do
        case "$a" in -*|"$target") ;; *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;; esac
      done
      touch_omp_acks
    fi
    # A delivered line means the pane's agent is now running.
    mark_comm "$ses" "$wid" "codex"
    exit 0 ;;
  kill-window|kill-session|set-window-option|run-shell) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/tmux"

  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"-o tpgid="*) printf '4242\n' ;;
  *"-o comm="*) printf 'bash\n' ;;
  *"-o args="*) printf 'bash\n' ;;
  *"-o stat="*) printf 'Ss\n' ;;
  *"pid=,pgid=,ppid=") printf '4242 4242 1\n' ;;
  *"pid=,ppid=") printf '4242 1\n' ;;
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

  cat > "$fb/bun" <<'SH'
#!/usr/bin/env bash
set -u
script=$1
shift
exec bash "$script" "$@"
SH
  chmod +x "$fb/bun"

  cat > "$fb/omp" <<'SH'
#!/usr/bin/env bun
set -u
case "${1:-}" in
  --help)
    printf '%s\n' '--model=<value>' '--thinking=<value>' '--auto-approve' '--max-time=<value>' '--session-dir=<value>' '-e, --extension=<value>' '-r, --resume=<value>' '--prewalk native-switch' '--prewalk-into=<value>' '--config=<value>' '--no-prewalk'
    ;;
  --version) printf 'omp/18.1.14\n' ;;
  config)
    printf '{"key":"prewalk.enabled","value":%s,"type":"boolean"}\n' "${FM_FAKE_OMP_PREWALK_ENABLED:-false}"
    ;;
  models)
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-5.6-luna","selector":"openai-codex/gpt-5.6-luna","thinking":["low","medium","high","xhigh","max"]}]}'
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/omp"

  # --- stateful herdr --------------------------------------------------------
  # $FM_FAKE_HERDR_STATE is one JSON document:
  # {"server_running":bool,"next":N,"workspaces":[...],"tabs":[...]}
  # Each tab: {tab_id,label,workspace_id,pane_id,cwd,busy}. A stopped server
  # makes every pane/workspace read uninterpretable; `herdr <ses> server`
  # flips it back on. A tab with busy=true reports a non-shell foreground.
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_HERDR_STATE:?}"
LOG="${FM_FAKE_HERDR_LOG:-/dev/null}"
{ printf 'herdr'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
running() { [ "$(jq_state -r '.server_running')" = "true" ]; }
touch_omp_acks() {  # after a launch line landed, ack the OMP harness
  grep -Fq 'FM_OMP_HARNESS=omp' "$FM_FAKE_LAUNCH_LOG" 2>/dev/null || return 0
  for extension in "${FM_FAKE_OMP_ACK_DIR:-/nonexistent}"/*.omp-ext.ts; do
    [ -e "$extension" ] || continue
    : > "${extension%.omp-ext.ts}.omp-doorbell-ready"
  done
  if [ -n "${FM_FAKE_OMP_ACK:-}" ]; then
    while IFS= read -r ack; do
      [ -z "$ack" ] && continue
      : > "$ack"
      case "$ack" in *.omp-started) : > "${ack%.omp-started}.omp-doorbell-ready" ;; esac
    done <<EOF
$FM_FAKE_OMP_ACK
EOF
  fi
}

args=("$@")
ws=""; label=""; cwd=""; pane=""
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
    --pane) pane=${args[$((i+1))]:-} ;;
  esac
done

cmd=${1:-}; sub=${2:-}
case "$cmd" in
  status)
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":%s}}\n' "$(jq_state -r '.server_running')"
    ;;
  server)
    jq_state '.server_running = true' | save
    ;;
  workspace)
    case "$sub" in
      list)
        running && jq_state '{result:{workspaces:[.workspaces[]|{workspace_id,label}]}}' \
          || printf '{"error":{"code":"server_not_running"}}\n'
        ;;
      create)
        running || { printf '{"error":{"code":"server_not_running"}}\n'; exit 0; }
        n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
        jq_state --arg wsid "$wsid" --arg wlabel "$label" --arg wcwd "$cwd" \
          --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
          '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
           | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid, cwd:$wcwd}]
           | .next = (.next + 2)' | save
        printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
          "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
        ;;
    esac
    ;;
  tab)
    case "$sub" in
      list)
        running || { printf '{"error":{"code":"server_not_running"}}\n'; exit 0; }
        jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)|{tab_id,label,workspace_id,pane_id}]}}'
        ;;
      create)
        running || { printf '{"error":{"code":"server_not_running"}}\n'; exit 0; }
        n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
        jq_state --arg w "$ws" --arg wlabel "$label" --arg wcwd "$cwd" --arg tabid "$tabid" --arg paneid "$paneid" \
          '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid, cwd:$wcwd}]
           | .next = (.next + 1)' | save
        printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
        ;;
      close)
        jq_state --arg t "${3:-}" '.tabs |= [.[]|select(.tab_id != $t)]' | save
        ;;
    esac
    ;;
  pane)
    case "$sub" in
      list)
        running || { printf '{"error":{"code":"server_not_running"}}\n'; exit 0; }
        jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id,tab_id}]}}'
        ;;
      get)
        p=${3:-}
        running || { printf '{"error":{"code":"server_not_running","message":"session server is not running"}}\n'; exit 0; }
        if jq_state -e --arg p "$p" '.tabs[] | select(.pane_id == $p)' >/dev/null 2>&1; then
          pcwd=$(jq_state -r --arg p "$p" '.tabs[] | select(.pane_id == $p) | .cwd')
          printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s","foreground_pid":4242}}}\n' "$p" "$pcwd"
        else
          printf '{"error":{"code":"pane_not_found"}}\n'
        fi
        ;;
      process-info)
        running || { printf '{"error":{"code":"server_not_running"}}\n'; exit 0; }
        if ! jq_state -e --arg p "$pane" '.tabs[] | select(.pane_id == $p)' >/dev/null 2>&1; then
          printf '{"error":{"code":"pane_not_found"}}\n'
        elif [ "$(jq_state -r --arg p "$pane" '.tabs[] | select(.pane_id == $p) | .busy // false')" = "true" ]; then
          printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_process_group_id":5555,"foreground_processes":[{"pid":5555,"name":"codex","argv0":"codex"}]}}}\n' "$pane"
        else
          printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"bash","argv0":"-bash"}]}}}\n' "$pane"
        fi
        ;;
      run)
        running || { printf '{"error":{"code":"server_not_running"}}\n'; exit 0; }
        p=${3:-}; text=${4:-}
        if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
          printf '%s\n' "$text" >> "$FM_FAKE_LAUNCH_LOG"
          touch_omp_acks
        fi
        case "$text" in
          "cd -- "*)
            dest=${text#"cd -- "}
            dest=${dest#\'}; dest=${dest%\'}
            jq_state --arg p "$p" --arg d "$dest" \
              '(.tabs[] | select(.pane_id == $p)).cwd = $d' | save
            ;;
        esac
        ;;
      send-text|send-keys|close)
        [ "$sub" = "close" ] && jq_state --arg p "${3:-}" '.tabs |= [.[]|select(.pane_id != $p)]' | save || true
        ;;
    esac
    ;;
  agent)
    case "$sub" in
      get)
        p=${3:-}
        running || { printf '{"error":{"code":"server_not_running"}}\n'; exit 0; }
        st=$(jq_state -r --arg p "$p" '.agent_status[$p] // empty' 2>/dev/null || true)
        if [ -n "$st" ]; then
          printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$st"
        else
          printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$p"
        fi
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"

  # --- stateful zellij -------------------------------------------------------
  # $FM_FAKE_ZELLIJ_STATE holds: sessions (one name per line), <ses>.tabs
  # ("tab_id|name|active"), <ses>.panes ("pane_id|tab_id|is_plugin").
  cat > "$fb/zellij" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_ZELLIJ_STATE:?}"
LOG="${FM_FAKE_ZELLIJ_LOG:-/dev/null}"
{ printf 'zellij'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"

ses=""
prev=""
for a in "$@"; do [ "$prev" = "--session" ] && ses=$a; prev=$a; done
[ -n "$ses" ] || ses="${ZELLIJ_SESSION_NAME:-}"

case "${1:-}" in
  --version) printf 'zellij 0.44.0\n'; exit 0 ;;
  list-sessions) cat "$STATE/sessions" 2>/dev/null; exit 0 ;;
  attach)
    name=""
    prev=""
    for a in "$@"; do [ "$prev" = "-b" ] && name=$a; prev=$a; done
    [ -n "$name" ] || name=$ses
    grep -qxF "$name" "$STATE/sessions" 2>/dev/null || printf '%s\n' "$name" >> "$STATE/sessions"
    : > "$STATE/$name.tabs"; : > "$STATE/$name.panes"
    exit 0 ;;
esac

if [ "${1:-}" = "--session" ]; then shift 2; fi
if [ "${1:-}" = "action" ]; then
  act=${2:-}
  case "$act" in
    list-tabs)
      if [ -f "$STATE/$ses.tabs" ]; then
        awk -F '|' 'BEGIN{printf "["; first=1} {if(!first)printf ","; first=0; printf "{\"tab_id\":%s,\"name\":\"%s\",\"active\":%s}", $1, $2, ($3=="true"?"true":"false")} END{print "]"}' "$STATE/$ses.tabs"
      else
        printf '[]\n'
      fi
      ;;
    list-panes)
      if [ -f "$STATE/$ses.panes" ]; then
        awk -F '|' 'BEGIN{printf "["; first=1} {if(!first)printf ","; first=0; printf "{\"id\":%s,\"tab_id\":%s,\"is_plugin\":%s}", $1, $2, $3} END{print "]"}' "$STATE/$ses.panes"
      else
        printf '[]\n'
      fi
      ;;
    new-tab)
      name=""; cwd=""
      prev=""
      for a in "$@"; do
        case "$prev" in --name) name=$a ;; --cwd) cwd=$a ;; esac
        prev=$a
      done
      tid=$(( $(wc -l < "$STATE/$ses.tabs" 2>/dev/null || echo 0) + 1 ))
      pid=$(( 100 + tid ))
      printf '%s|%s|false\n' "$tid" "$name" >> "$STATE/$ses.tabs"
      printf '%s|%s|false\n' "$pid" "$tid" >> "$STATE/$ses.panes"
      printf '%s\n' "$tid"
      ;;
    go-to-tab-by-id|paste|send-keys|close-tab|close-pane) : ;;
    *) : ;;
  esac
fi
exit 0
SH
  chmod +x "$fb/zellij"

  # --- stateful cmux ---------------------------------------------------------
  # $FM_FAKE_CMUX_STATE holds workspaces.json ({"workspaces":[{id,title,cwd}]})
  # and <wsid>.panes ({"panes":[{selected_surface_id,surface_ids}]}).
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
set -u
STATE="${FM_FAKE_CMUX_STATE:?}"
LOG="${FM_FAKE_CMUX_LOG:-/dev/null}"
{ printf 'cmux'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$LOG"

cmd=${1:-}
case "$cmd" in
  version) printf 'cmux 0.64.17 (97) [abcdef1]\n'; exit 0 ;;
  ping) printf 'PONG\n'; exit 0 ;;
  workspace)
    case "${2:-}" in
      list) cat "$STATE/workspaces.json" ;;
    esac
    exit 0 ;;
  new-workspace)
    name=""; cwd=""
    prev=""
    for a in "$@"; do
      case "$prev" in --name) name=$a ;; --cwd) cwd=$a ;; esac
      prev=$a
    done
    n=$(( $(jq '.workspaces | length' "$STATE/workspaces.json" 2>/dev/null || echo 0) + 1 ))
    wsid=$(printf 'ws-%04d' "$n")
    sfid=$(printf 'sf-%04d' "$n")
    tmp="$STATE/workspaces.json.tmp.$$"
    jq --arg id "$wsid" --arg t "$name" --arg c "$cwd" \
      '.workspaces += [{id:$id, title:$t, cwd:$c}]' "$STATE/workspaces.json" > "$tmp" && mv "$tmp" "$STATE/workspaces.json"
    printf '{"panes":[{"selected_surface_id":"%s","surface_ids":["%s"]}]}' "$sfid" "$sfid" > "$STATE/$wsid.panes"
    printf '{"id":"%s"}\n' "$wsid"
    exit 0 ;;
  list-panes)
    ws=""
    prev=""
    for a in "$@"; do [ "$prev" = "--workspace" ] && ws=$a; prev=$a; done
    if [ -f "$STATE/$ws.panes" ]; then cat "$STATE/$ws.panes"; else printf '{"panes":[]}\n'; fi
    exit 0 ;;
  send|send-key) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/cmux"

  # --- orca -------------------------------------------------------------------
  # Orca relaunch stays refused by design; the fake only needs to satisfy the
  # runtime check that precedes that refusal.
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json") printf '{"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fb/orca"

  printf '%s\n' "$fb"
}

# --- fixture helpers ---------------------------------------------------------

# make_case <name> <id> [pool|flat|missing] -> echoes
#   case_dir|home|proj|wt|fakebin|launchlog|slot_dir
# `pool` lays the worktree out as <case>/pool/17/proj with a
# treehouse-state.json; `flat` keeps the worktree outside any pool (the
# "cannot prove ownership" shape); `missing` points metadata at a worktree
# that does not exist.
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
    "$case_dir/fake/tmux-state" "$case_dir/fake/zellij-state" "$case_dir/fake/cmux-state"
  printf '{"server_running":false,"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' \
    > "$case_dir/fake/herdr-state.json"
  printf '{"workspaces":[]}\n' > "$case_dir/fake/cmux-state/workspaces.json"
  printf 'omp\n' > "$home/config/crew-harness"
  mkdir -p "$home/data/$id"
  printf 'Delivery contract: mode=no-mistakes\nrelaunch brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  case "$shape" in
    pool)
      mkdir -p "$case_dir/pool"
      fm_git_worktree "$proj" "$wt" "wt-$name"
      ;;
    flat)
      wt="$case_dir/wt"
      fm_git_worktree "$proj" "$wt" "wt-$name"
      ;;
    missing)
      fm_git_worktree "$proj" "$case_dir/real-wt" "wt-$name"
      wt="$case_dir/gone-wt"
      ;;
  esac
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$slot_dir"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG SLOT_DIR <<EOF
$1
EOF
}

# write_pool_state <case_dir> <wt> <holder-or-empty>: the durable
# treehouse-state.json a `treehouse get --lease` acquisition leaves behind.
# An empty holder records an unleased slot.
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

# write_slot_marker <slot_dir> <id> <home>: the firstmate interactive-spawn
# ownership claim a live spawn leaves at the pool slot root.
write_slot_marker() {
  printf 'task=%s\nhome=%s\n' "$2" "$3" > "$1/.fm-slot-owner"
}

# write_meta <file> <id> <backend> <wt> <proj> [harness]
write_meta() {
  local file=$1 id=$2 backend=$3 wt=$4 proj=$5 harness=${6:-omp}
  local omp_bin bun
  omp_bin=$(cd "$FAKEBIN_DIR" && pwd -P)/omp
  bun=$(cd "$FAKEBIN_DIR" && pwd -P)/bun
  {
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$proj"
    printf 'harness=%s\n' "$harness"
    printf 'kind=ship\n'
    printf 'mode=no-mistakes\n'
    printf 'yolo=off\n'
    printf 'tasktmp=\n'
    printf 'model=openai-codex/gpt-5.6-luna\n'
    printf 'effort=high\n'
    printf 'spawn_gen=gen1\n'
    [ "$harness" != omp ] || {
      printf 'omp_bin=%s\n' "$omp_bin"
      printf 'omp_bun=%s\n' "$bun"
    }
    case "$backend" in
      tmux)
        printf 'window=ses-%s:fm-%s\n' "$id" "$id"
        printf 'backend=tmux\n'
        ;;
      herdr)
        printf 'window=ses-%s:w99:p99\n' "$id"
        printf 'backend=herdr\n'
        printf 'herdr_session=ses-%s\n' "$id"
        printf 'herdr_workspace_id=w99\n'
        printf 'herdr_tab_id=w99:t99\n'
        printf 'herdr_pane_id=w99:p99\n'
        ;;
      zellij)
        printf 'window=ses-%s:9\n' "$id"
        printf 'backend=zellij\n'
        printf 'zellij_session=ses-%s\n' "$id"
        printf 'zellij_tab_id=3\n'
        printf 'zellij_pane_id=9\n'
        ;;
      cmux)
        printf 'window=ws-old:sf-old\n'
        printf 'backend=cmux\n'
        printf 'cmux_workspace_id=ws-old\n'
        printf 'cmux_surface_id=sf-old\n'
        ;;
      orca)
        printf 'window=fm-%s\n' "$id"
        printf 'backend=orca\n'
        printf 'terminal=orca-term-1\n'
        printf 'orca_worktree_id=orca-wt-1\n'
        ;;
    esac
  } > "$file"
}

# create_prior_artifacts: the prior incarnation's durable runtime files the
# launch transaction cleans up or consumes.
create_prior_artifacts() {
  local state=$1 id=$2
  : > "$state/$id.status"
  : > "$state/$id.omp-ext.ts"
  : > "$state/$id.omp-ready"
  : > "$state/$id.omp-started"
  : > "$state/$id.omp-doorbell-ready"
  mkdir -p "$state/$id.omp-doorbell-ready.requests"
}

case_id() {
  printf 'rel-de-%s-%s' "$1" "$$"
}

# scoped_task_title <backend> <id>: the adapter's home-scoped endpoint label.
scoped_task_title() {
  local backend=$1 id=$2
  FM_HOME=$HOME_DIR bash -c '
    . "$0/bin/fm-backend.sh"
    case "$1" in
      zellij) fm_backend_source zellij; fm_backend_zellij_scoped_title "fm-$2" ;;
      cmux) fm_backend_source cmux; fm_backend_cmux_scoped_title "fm-$2" ;;
    esac
  ' "$ROOT" "$backend" "$id"
}

# spawn_env <case_dir> <home> <id> <command...>: the shared environment
# prefix for both entry paths. Ambient backend env is scrubbed so a leaked
# HERDR_PANE_ID or ZELLIJ_SESSION_NAME cannot masquerade as launcher ancestry.
spawn_env() {
  local case_dir=$1 home=$2 id=$3
  shift 3
  env -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID \
    -u HERDR_ENV -u HERDR_SOCKET_PATH -u ZELLIJ_SESSION_NAME -u ZELLIJ \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_TMUX_STATE="$case_dir/fake/tmux-state" \
    FM_FAKE_TMUX_LOG="$case_dir/fake/tmux.log" \
    FM_FAKE_HERDR_STATE="$case_dir/fake/herdr-state.json" \
    FM_FAKE_HERDR_LOG="$case_dir/fake/herdr.log" \
    FM_FAKE_ZELLIJ_STATE="$case_dir/fake/zellij-state" \
    FM_FAKE_ZELLIJ_LOG="$case_dir/fake/zellij.log" \
    FM_FAKE_CMUX_STATE="$case_dir/fake/cmux-state" \
    FM_FAKE_CMUX_LOG="$case_dir/fake/cmux.log" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_OMP_ACK="$home/state/$id.omp-started" \
    FM_FAKE_OMP_ACK_DIR="$home/state" \
    FM_FAKE_OMP_NO_PREWALK=1 \
    FM_HERDR_PS_BIN=ps \
    FM_OMP_LAUNCH_ACK_POLLS=20 FM_OMP_DOORBELL_ACK_POLLS=20 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=10 \
    FM_BACKEND_TMUX_IDLE_SHELL_PROOF_POLLS=10 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$@"
}

run_spawn() {  # <case_dir> <home> <id>
  local case_dir=$1 home=$2 id=$3
  SPAWN_OUT=$(spawn_env "$case_dir" "$home" "$id" "$SPAWN" "$id" --relaunch 2>&1)
  SPAWN_STATUS=$?
}

run_control() {  # <case_dir> <home> <id> [extra args...]
  local case_dir=$1 home=$2 id=$3
  shift 3
  CONTROL_OUT=$(spawn_env "$case_dir" "$home" "$id" \
    FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=5 FM_CONTROL_LAUNCH_WAIT=20 \
    "$CONTROL" "$id" relaunch --note "relaunch progress note for $id" "$@" 2>&1)
  CONTROL_STATUS=$?
}

# --- AC1: proven-gone endpoint + task-owned worktree relaunches in place -----

test_tmux_gone_relaunch_recreates_in_worktree() {
  local rec id
  id=$(case_id tmux-gone)
  rec=$(make_case tmux-gone "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" tmux "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  # The recorded session exists but the task's window is gone.
  : > "$CASE_DIR/fake/tmux-state/ses-$id.windows"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  expect_code 0 "$SPAWN_STATUS" "tmux proven-missing relaunch should succeed; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "spawned $id" "tmux gone relaunch did not report success"
  # The replacement window was created in the recorded worktree, not the project.
  assert_grep "new-window" "$CASE_DIR/fake/tmux.log" "relaunch did not create a replacement tmux window"
  assert_grep "$WT_DIR" "$CASE_DIR/fake/tmux.log" "replacement window was not created in the recorded worktree"
  assert_grep "mode=no-mistakes" "$HOME_DIR/state/$id.meta" "relaunch did not preserve mode"
  assert_grep "yolo=off" "$HOME_DIR/state/$id.meta" "relaunch did not preserve yolo"
  assert_grep "model=openai-codex/gpt-5.6-luna" "$HOME_DIR/state/$id.meta" "relaunch did not preserve model"
  assert_grep "effort=high" "$HOME_DIR/state/$id.meta" "relaunch did not preserve effort"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "relaunch did not keep the recorded worktree"
  pass "fm-spawn --relaunch: proven-missing tmux endpoint recreates the window in the recorded worktree"
}

test_tmux_gone_relaunch_durable_lease_ownership() {
  local rec id
  id=$(case_id tmux-lease)
  rec=$(make_case tmux-lease "$id" pool)
  read_case "$rec"
  # The incident's ownership shape: NO slot-owner marker, only the durable
  # Treehouse lease held by fm-<id>.
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_meta "$HOME_DIR/state/$id.meta" "$id" tmux "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  : > "$CASE_DIR/fake/tmux-state/ses-$id.windows"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  expect_code 0 "$SPAWN_STATUS" "lease-only ownership relaunch should succeed; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "spawned $id" "lease-only relaunch did not report success"
  pass "fm-spawn --relaunch: a durable fm-<id> Treehouse lease proves worktree ownership"
}

test_control_relaunch_treats_missing_endpoint_as_stopped() {
  local rec id journal
  id=$(case_id control-gone)
  rec=$(make_case control-gone "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" tmux "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  : > "$CASE_DIR/fake/tmux-state/ses-$id.windows"

  run_control "$CASE_DIR" "$HOME_DIR" "$id"
  expect_code 0 "$CONTROL_STATUS" "fm-control relaunch on a missing endpoint should continue; got: $CONTROL_OUT"
  assert_contains "$CONTROL_OUT" "relaunched $id" "fm-control relaunch did not report success"
  journal="$HOME_DIR/state/$id.control-relaunch"
  assert_grep "exit_result=already-stopped" "$journal" "the transaction did not record the missing endpoint as already stopped"
  assert_grep "phase=complete" "$journal" "the relaunch transaction did not complete"
  # The progress note survives in the replacement's brief.
  assert_grep "relaunch progress note for $id" "$HOME_DIR/data/$id/brief.md" "the progress note was not preserved in the brief"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "relaunch did not keep the recorded worktree"
  pass "fm-control relaunch: a proven-missing endpoint counts as already stopped and the transaction completes"
}

# --- AC2: every unproven shape still refuses ---------------------------------

test_tmux_live_endpoint_wrong_cwd_refuses() {
  local rec id
  id=$(case_id tmux-wrongcwd)
  rec=$(make_case tmux-wrongcwd "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" tmux "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  # The recorded window is ALIVE at a shell prompt but sitting in a foreign cwd.
  mkdir -p "$CASE_DIR/elsewhere"
  printf '@1\tfm-%s\t%s\tbash\n' "$id" "$CASE_DIR/elsewhere" > "$CASE_DIR/fake/tmux-state/ses-$id.windows"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "a live endpoint outside the recorded worktree should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "not its recorded worktree" "live wrong-cwd endpoint did not refuse with the worktree reason"
  pass "fm-spawn --relaunch: a live endpoint in a foreign cwd still refuses"
}

test_tmux_live_agent_refuses() {
  local rec id
  id=$(case_id tmux-live)
  rec=$(make_case tmux-live "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" tmux "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  printf '@1\tfm-%s\t%s\tcodex\n' "$id" "$WT_DIR" > "$CASE_DIR/fake/tmux-state/ses-$id.windows"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "a live agent endpoint should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "live agent" "live-agent endpoint did not refuse with the duplicate reason"
  pass "fm-spawn --relaunch: a live agent at the recorded endpoint still refuses"
}

test_tmux_ambiguous_endpoint_refuses() {
  local rec id
  id=$(case_id tmux-ambiguous)
  rec=$(make_case tmux-ambiguous "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" tmux "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  # An unattributed process holds the pane.
  printf '@1\tfm-%s\t%s\tvim\n' "$id" "$WT_DIR" > "$CASE_DIR/fake/tmux-state/ses-$id.windows"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "an ambiguous endpoint should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "ambiguous" "ambiguous endpoint did not refuse with the attribution reason"
  pass "fm-spawn --relaunch: an ambiguous endpoint state still refuses"
}

test_gone_relaunch_nonpool_worktree_refuses() {
  local rec id
  id=$(case_id nonpool)
  rec=$(make_case nonpool "$id" flat)
  read_case "$rec"
  write_meta "$HOME_DIR/state/$id.meta" "$id" tmux "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  : > "$CASE_DIR/fake/tmux-state/ses-$id.windows"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "a non-pool recorded worktree should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "not a Treehouse pool slot" "non-pool worktree did not refuse with the ownership reason"
  pass "fm-spawn --relaunch: a proven-gone endpoint with a non-pool worktree refuses"
}

test_gone_relaunch_foreign_slot_owner_refuses() {
  local rec id
  id=$(case_id foreign-owner)
  rec=$(make_case foreign-owner "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  # The pool slot was reassigned to another task after this task died.
  write_slot_marker "$SLOT_DIR" "other-task" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" tmux "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  : > "$CASE_DIR/fake/tmux-state/ses-$id.windows"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "a slot claimed by another task should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "claimed by task other-task" "foreign-owned slot did not refuse with the reassignment reason"
  pass "fm-spawn --relaunch: a slot claimed by another task refuses"
}

test_gone_relaunch_no_ownership_evidence_refuses() {
  local rec id
  id=$(case_id no-owner)
  rec=$(make_case no-owner "$id" pool)
  read_case "$rec"
  # A pool slot carrying neither the slot-owner claim nor a live lease.
  write_pool_state "$CASE_DIR" "$WT_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" tmux "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  : > "$CASE_DIR/fake/tmux-state/ses-$id.windows"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "a worktree with no ownership evidence should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "cannot prove it still owns" "unowned worktree did not refuse with the ownership reason"
  pass "fm-spawn --relaunch: a worktree with no ownership evidence refuses"
}

test_gone_relaunch_foreign_lease_refuses() {
  local rec id
  id=$(case_id foreign-lease)
  rec=$(make_case foreign-lease "$id" pool)
  read_case "$rec"
  # The durable lease is held by a DIFFERENT task.
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-another-task"
  write_meta "$HOME_DIR/state/$id.meta" "$id" tmux "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  : > "$CASE_DIR/fake/tmux-state/ses-$id.windows"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "a worktree leased to another task should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "cannot prove it still owns" "foreign-leased worktree did not refuse with the ownership reason"
  pass "fm-spawn --relaunch: a worktree leased to another task refuses"
}

# --- herdr -------------------------------------------------------------------

test_herdr_gone_server_relaunch_recreates() {
  local rec id
  id=$(case_id herdr-gone)
  rec=$(make_case herdr-gone "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_meta "$HOME_DIR/state/$id.meta" "$id" herdr "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  expect_code 0 "$SPAWN_STATUS" "herdr gone-server relaunch should succeed; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "spawned $id" "herdr gone relaunch did not report success"
  # The replacement tab was created in the recorded worktree.
  assert_grep "tab" "$CASE_DIR/fake/herdr.log" "herdr relaunch did not create a replacement tab"
  assert_grep "$WT_DIR" "$CASE_DIR/fake/herdr.log" "replacement tab was not created in the recorded worktree"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "herdr relaunch did not keep the recorded worktree"
  assert_grep "herdr_pane_id=" "$HOME_DIR/state/$id.meta" "herdr relaunch did not publish a fresh pane id"
  pass "fm-spawn --relaunch: a stopped herdr session server recreates the endpoint in the worktree"
}

test_herdr_drifted_pane_gets_one_cd() {
  local rec id
  id=$(case_id herdr-drift)
  rec=$(make_case herdr-drift "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_meta "$HOME_DIR/state/$id.meta" "$id" herdr "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  mkdir -p "$CASE_DIR/elsewhere"
  # A live server; the recorded pane exists, agentless, and drifted out of the
  # worktree. The recovery must deliver exactly one `cd -- <worktree>` and
  # proceed once the pane's cwd lands back inside it.
  jq --arg id "$id" --arg drift "$CASE_DIR/elsewhere" \
    '.server_running = true
     | .workspaces = [{workspace_id:"w99", label:"firstmate"}]
     | .tabs = [{tab_id:"w99:t99", label:("fm-" + $id), workspace_id:"w99", pane_id:"w99:p99", cwd:$drift}]' \
    "$CASE_DIR/fake/herdr-state.json" > "$CASE_DIR/fake/herdr-state.json.tmp" \
    && mv "$CASE_DIR/fake/herdr-state.json.tmp" "$CASE_DIR/fake/herdr-state.json"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  expect_code 0 "$SPAWN_STATUS" "herdr drifted-pane relaunch should recover with one cd; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "spawned $id" "herdr drifted relaunch did not report success"
  assert_grep "cd -- " "$CASE_DIR/fake/herdr.log" "the drifted pane was never told to return to the worktree"
  pass "fm-spawn --relaunch: a drifted herdr shell gets one cd back to the worktree"
}

test_herdr_drift_refuses_when_shell_wont_go() {
  local rec id
  id=$(case_id herdr-nocd)
  rec=$(make_case herdr-nocd "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_meta "$HOME_DIR/state/$id.meta" "$id" herdr "$WT_DIR" "$PROJ_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id"
  mkdir -p "$CASE_DIR/elsewhere"
  # A drifted pane whose foreground is a busy agent process: the idle-shell
  # proof the recovery cd requires never passes, so the pane cannot be told
  # to return and relaunch must refuse.
  jq --arg id "$id" --arg drift "$CASE_DIR/elsewhere" \
    '.server_running = true
     | .workspaces = [{workspace_id:"w99", label:"firstmate"}]
     | .tabs = [{tab_id:"w99:t99", label:("fm-" + $id), workspace_id:"w99", pane_id:"w99:p99", cwd:$drift, busy:true}]' \
    "$CASE_DIR/fake/herdr-state.json" > "$CASE_DIR/fake/herdr-state.json.tmp" \
    && mv "$CASE_DIR/fake/herdr-state.json.tmp" "$CASE_DIR/fake/herdr-state.json"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "a herdr pane whose shell cannot be told to return should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "could not be told to return" "unrecoverable drift did not refuse with the cd reason"
  pass "fm-spawn --relaunch: a herdr shell that cannot return to the worktree refuses"
}

# --- zellij ------------------------------------------------------------------

test_zellij_absent_relaunch_recreates() {
  local rec id
  id=$(case_id zellij-gone)
  rec=$(make_case zellij-gone "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  # Zellij relaunch coverage uses a non-OMP harness: the OMP gate requires a
  # recovery-grade agent_state, which zellij cannot provide by design - the
  # launch-owner path is the supported owner here.
  write_meta "$HOME_DIR/state/$id.meta" "$id" zellij "$WT_DIR" "$PROJ_DIR" claude
  create_prior_artifacts "$HOME_DIR/state" "$id"
  # Session alive; the recorded pane 9 is positively absent.
  printf 'ses-%s\n' "$id" > "$CASE_DIR/fake/zellij-state/sessions"
  : > "$CASE_DIR/fake/zellij-state/ses-$id.tabs"
  : > "$CASE_DIR/fake/zellij-state/ses-$id.panes"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  expect_code 0 "$SPAWN_STATUS" "zellij proven-absent relaunch should succeed; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "spawned $id" "zellij absent relaunch did not report success"
  assert_grep "new-tab" "$CASE_DIR/fake/zellij.log" "zellij relaunch did not create a replacement tab"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "zellij relaunch did not keep the recorded worktree"
  pass "fm-spawn --relaunch: a proven-absent zellij endpoint recreates the tab in the worktree"
}

test_zellij_present_endpoint_refuses() {
  local rec id title
  id=$(case_id zellij-live)
  rec=$(make_case zellij-live "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" zellij "$WT_DIR" "$PROJ_DIR" claude
  create_prior_artifacts "$HOME_DIR/state" "$id"
  # The recorded pane 9 still sits in a tab carrying THIS task's scoped label -
  # the endpoint is live and zellij cannot safely prove its cwd, so relaunch
  # must refuse.
  title=$(scoped_task_title zellij "$id")
  printf 'ses-%s\n' "$id" > "$CASE_DIR/fake/zellij-state/sessions"
  printf '3|%s|false\n' "$title" > "$CASE_DIR/fake/zellij-state/ses-$id.tabs"
  printf '9|3|false\n' > "$CASE_DIR/fake/zellij-state/ses-$id.panes"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "a live zellij endpoint should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "live endpoint" "live zellij endpoint did not refuse"
  pass "fm-spawn --relaunch: a live zellij endpoint still refuses"
}

# --- cmux --------------------------------------------------------------------

test_cmux_absent_relaunch_recreates() {
  local rec id
  id=$(case_id cmux-gone)
  rec=$(make_case cmux-gone "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" cmux "$WT_DIR" "$PROJ_DIR" claude
  create_prior_artifacts "$HOME_DIR/state" "$id"
  # The recorded workspace ws-old is positively absent from the app.
  printf '{"workspaces":[{"id":"ws-other","title":"unrelated"}]}\n' > "$CASE_DIR/fake/cmux-state/workspaces.json"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  expect_code 0 "$SPAWN_STATUS" "cmux proven-absent relaunch should succeed; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "spawned $id" "cmux absent relaunch did not report success"
  assert_grep "new-workspace" "$CASE_DIR/fake/cmux.log" "cmux relaunch did not create a replacement workspace"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "cmux relaunch did not keep the recorded worktree"
  pass "fm-spawn --relaunch: a proven-absent cmux endpoint recreates the workspace in the worktree"
}

test_cmux_present_endpoint_refuses() {
  local rec id title
  id=$(case_id cmux-live)
  rec=$(make_case cmux-live "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" cmux "$WT_DIR" "$PROJ_DIR" claude
  create_prior_artifacts "$HOME_DIR/state" "$id"
  # A live workspace carries this task's scoped title - the endpoint is alive.
  title=$(scoped_task_title cmux "$id")
  jq -n --arg t "$title" '{workspaces:[{id:"ws-live", title:$t}]}' > "$CASE_DIR/fake/cmux-state/workspaces.json"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "a live cmux workspace should refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "live endpoint" "live cmux endpoint did not refuse"
  pass "fm-spawn --relaunch: a live cmux endpoint still refuses"
}

# --- orca stays refused ------------------------------------------------------

test_orca_relaunch_still_refuses() {
  local rec id
  id=$(case_id orca-refuse)
  rec=$(make_case orca-refuse "$id" pool)
  read_case "$rec"
  write_pool_state "$CASE_DIR" "$WT_DIR" "fm-$id"
  write_slot_marker "$SLOT_DIR" "$id" "$HOME_DIR"
  write_meta "$HOME_DIR/state/$id.meta" "$id" orca "$WT_DIR" "$PROJ_DIR" claude
  create_prior_artifacts "$HOME_DIR/state" "$id"

  run_spawn "$CASE_DIR" "$HOME_DIR" "$id"
  [ "$SPAWN_STATUS" -ne 0 ] || fail "an orca relaunch should still refuse; got: $SPAWN_OUT"
  assert_contains "$SPAWN_OUT" "cannot prove the relaunch endpoint cwd" "orca relaunch did not refuse with the cwd-proof reason"
  pass "fm-spawn --relaunch: orca remains refused"
}

# --- run ---------------------------------------------------------------------

test_tmux_gone_relaunch_recreates_in_worktree
test_tmux_gone_relaunch_durable_lease_ownership
test_control_relaunch_treats_missing_endpoint_as_stopped
test_tmux_live_endpoint_wrong_cwd_refuses
test_tmux_live_agent_refuses
test_tmux_ambiguous_endpoint_refuses
test_gone_relaunch_nonpool_worktree_refuses
test_gone_relaunch_foreign_slot_owner_refuses
test_gone_relaunch_no_ownership_evidence_refuses
test_gone_relaunch_foreign_lease_refuses
test_herdr_gone_server_relaunch_recreates
test_herdr_drifted_pane_gets_one_cd
test_herdr_drift_refuses_when_shell_wont_go
test_zellij_absent_relaunch_recreates
test_zellij_present_endpoint_refuses
test_cmux_absent_relaunch_recreates
test_cmux_present_endpoint_refuses
test_orca_relaunch_still_refuses

pass "all dead-endpoint relaunch tests"
