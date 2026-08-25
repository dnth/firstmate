#!/usr/bin/env bash
# Opt-in credentialed Hermes persistent-TUI verification on an isolated tmux server.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_HERMES_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERMES_LIVE_E2E=1 to run the Hermes persistent-TUI verification"
  exit 0
fi

HERMES_BIN=$(command -v hermes) || fail "Hermes executable not found"
REAL_HERMES_HOME=${HERMES_HOME:-${HOME:-}/.hermes}
[ -f "$REAL_HERMES_HOME/config.yaml" ] || fail "Hermes config is missing"
[ -f "$REAL_HERMES_HOME/auth.json" ] || fail "Hermes OpenAI Codex auth store is missing"

LAB=$(fm_test_tmproot fm-hermes-live-e2e)
PROFILE="$LAB/hermes-home"
FM_LIVE_HOME="$LAB/fm-home"
PROJECT="$LAB/project"
REMOTE="$LAB/project.origin.git"
TMUX_DIR="$LAB/tmux"
WORKER=hermes-live-worker
SCOUT=hermes-live-scout
WORKER_TARGET="firstmate:fm-$WORKER"

live_expand_descendants() {  # <seed-pid-list>
  local seeds=$1 table out
  [ -n "$seeds" ] || return 0
  table=$(LC_ALL=C ps -e -o pid=,ppid=,state= 2>/dev/null) \
    || table=$(LC_ALL=C ps -e -o pid=,ppid= 2>/dev/null) || return 1
  out=$(printf '%s\n@\n%s\n' "$seeds" "$table" | awk -v self="$$" '
    BEGIN { seeding = 1 }
    seeding {
      if ($0 == "@") { seeding = 0; next }
      if ($1 ~ /^[0-9]+$/) owned[$1] = 1
      next
    }
    {
      if (NF < 2 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/) next
      if (NF >= 3 && $3 ~ /^Z/) { zombie[$1] = 1; next }
      if ($1 == self) next
      kids[$2] = kids[$2] " " $1
    }
    END {
      n = 0
      for (p in owned) queue[n++] = p
      for (i = 0; i < n; i++) {
        cnt = split(kids[queue[i]], child, " ")
        for (j = 1; j <= cnt; j++) {
          c = child[j]
          if (c == "" || (c in owned)) continue
          owned[c] = 1
          queue[n++] = c
        }
      }
      for (p in owned) if (!(p in zombie)) print p
    }
  ') || return 1
  printf '%s\n' "$out" | grep -E '^[0-9]+$' | sort -un || true
}

live_ps_rows_with_environment() {
  local out row pid
  out=$(LC_ALL=C ps axeww -o pid=,command= 2>/dev/null) \
    || out=$(LC_ALL=C ps -A -E -ww -o pid=,command= 2>/dev/null) \
    || return 1
  [ -n "$out" ] || return 1
  while IFS= read -r row; do
    pid=${row#"${row%%[![:space:]]*}"}
    pid=${pid%%[[:space:]]*}
    [ "$pid" = "$$" ] || continue
    case " $row " in
      *" PATH="*) printf '%s\n' "$out"; return 0 ;;
    esac
  done <<EOF
$out
EOF
  return 1
}

live_env_marker_pids() {  # <NAME=VALUE>
  local marker=$1 proc_dir pid entry rows line
  if [ -d /proc ]; then
    for proc_dir in /proc/[0-9]*; do
      [ -r "$proc_dir/environ" ] || continue
      pid=${proc_dir##*/}
      [ "$pid" != "$$" ] || continue
      while IFS= read -r -d '' entry; do
        if [ "$entry" = "$marker" ]; then
          printf '%s\n' "$pid"
          break
        fi
      done < "$proc_dir/environ" 2>/dev/null || true
    done
    return 0
  fi
  rows=$(live_ps_rows_with_environment) || return 1
  while IFS= read -r line; do
    case " $line " in
      *" $marker "*) ;;
      *) continue ;;
    esac
    pid=${line#"${line%%[![:space:]]*}"}
    pid=${pid%%[[:space:]]*}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" != "$$" ] || continue
    printf '%s\n' "$pid"
  done <<EOF
$rows
EOF
}

live_cwd_pids() {  # <root>
  local root=$1 pid line path
  [ -n "$root" ] || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p} ;;
      n*)
        path=${line#n}
        case "$path" in
          "$root"|"$root"/*)
            [ "$pid" = "$$" ] || printf '%s\n' "$pid"
            ;;
        esac
        ;;
    esac
  done <<EOF
$(lsof -a -d cwd -Fpn 2>/dev/null || true)
EOF
}

# The same selector bin/fm-teardown.sh task_pids_for_reap implements: the
# descendant closure starts at the exact task-token roots only, and that
# closure is unioned with the flat set of processes whose cwd is the task
# worktree.
live_task_pids() {  # <owner-token> <worktree>
  local token=$1 worktree=$2 marker_pids cwd_pids expanded
  marker_pids=$(live_env_marker_pids "FM_HERMES_TASK_TOKEN=$token") || return 1
  cwd_pids=$(live_cwd_pids "$worktree") || return 1
  expanded=$(live_expand_descendants "$marker_pids") || return 1
  printf '%s\n%s\n' "$cwd_pids" "$expanded" \
    | grep -E '^[0-9]+$' | sort -un || true
}

live_owned_pids() {
  local marker_pids cwd_pids seeds
  marker_pids=$(live_env_marker_pids "HERMES_HOME=$PROFILE") || return 1
  cwd_pids=$(live_cwd_pids "$LAB") || return 1
  seeds=$(printf '%s\n%s\n' "$marker_pids" "$cwd_pids" \
    | grep -E '^[0-9]+$' | sort -un || true)
  [ -n "$seeds" ] || return 0
  live_expand_descendants "$seeds"
}

live_force_reap() {
  local signal pids pid
  for signal in TERM KILL; do
    pids=$(live_owned_pids) || return 1
    [ -n "$pids" ] || return 0
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -"$signal" "$pid" 2>/dev/null || true
    done <<EOF
$pids
EOF
    sleep 0.5
  done
  [ -z "$(live_owned_pids)" ]
}

live_cleanup() {  # <original-exit-code>
  local original_rc=$1 cleanup_rc=0 id leftovers stale dir
  trap - EXIT INT TERM
  set +e
  live_force_reap || cleanup_rc=1
  TMUX_TMPDIR="$TMUX_DIR" tmux kill-server 2>/dev/null || true
  live_force_reap || cleanup_rc=1
  for id in "$WORKER" "$SCOUT"; do
    [ ! -f "$FM_LIVE_HOME/state/$id.meta" ] \
      || run_tmux_env "$ROOT/bin/fm-teardown.sh" "$id" --force >/dev/null 2>&1 \
      || cleanup_rc=1
  done
  leftovers=$(live_owned_pids 2>/dev/null || true)
  if [ -n "$leftovers" ]; then
    printf 'not ok - live Hermes cleanup left owned process(es): %s\n' \
      "$(printf '%s' "$leftovers" | tr '\n' ' ')" >&2
    cleanup_rc=1
  fi
  fm_test_cleanup
  stale=
  for dir in "${TMPDIR:-/tmp}"/fm-hermes-live-e2e.*; do
    [ -d "$dir" ] || continue
    if [ "$dir" = "$LAB" ] \
       || [ "$(sed -n 1p "$dir/.fm-test-fixture" 2>/dev/null)" = "$$" ]; then
      stale="$stale $dir"
    fi
  done
  if [ -n "$stale" ]; then
    printf 'not ok - live Hermes cleanup left temp dirs:%s\n' "$stale" >&2
    cleanup_rc=1
  fi
  if [ "$cleanup_rc" -eq 0 ]; then
    printf 'output: cleanup_owned_processes=0 cleanup_temp_dirs=0\n'
  fi
  if [ "$cleanup_rc" -ne 0 ]; then
    exit 1
  fi
  exit "$original_rc"
}
trap 'live_cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -m 700 "$PROFILE" "$FM_LIVE_HOME" "$TMUX_DIR"
mkdir -p "$FM_LIVE_HOME/data/$WORKER" "$FM_LIVE_HOME/data/$SCOUT" \
  "$FM_LIVE_HOME/state" "$FM_LIVE_HOME/config" "$FM_LIVE_HOME/projects"
cp "$REAL_HERMES_HOME/config.yaml" "$PROFILE/config.yaml"
sed -i \
  '/# BEGIN FIRSTMATE HERMES HOOKS/,/# END FIRSTMATE HERMES HOOKS/d; /# BEGIN FIRSTMATE HERMES PLUGIN ENABLE/,/# END FIRSTMATE HERMES PLUGIN ENABLE/d' \
  "$PROFILE/config.yaml"
cp "$REAL_HERMES_HOME/auth.json" "$PROFILE/auth.json"
chmod 600 "$PROFILE/config.yaml" "$PROFILE/auth.json"

printf '%s\n' \
  'Delivery contract: mode=local-only' \
  'Remember the token HERMES-TUI-RESUME-825 for later in this session.' \
  'Reply exactly HERMES-TUI-SPAWN-OK and then stop.' \
  > "$FM_LIVE_HOME/data/$WORKER/brief.md"
printf '%s\n' 'Reply exactly HERMES-TUI-SCOUT-OK and then stop.' \
  > "$FM_LIVE_HOME/data/$SCOUT/brief.md"

# A native profile skill is the branch fm-send types as a bare /<skill>. It must
# still prove a real model turn, so the skill body demands a spoken token.
mkdir -p "$PROFILE/skills/fmnative"
printf '%s\n' \
  '---' \
  'name: fmnative' \
  'description: Firstmate live verification skill. Reply with the verification token.' \
  '---' \
  '' \
  '# Firstmate native verification' \
  '' \
  'Reply exactly HERMES-TUI-NATIVE-SKILL-OK and then stop.' \
  > "$PROFILE/skills/fmnative/SKILL.md"

fm_git_init_commit "$PROJECT"
fm_git_add_origin "$PROJECT" "$REMOTE"

run_tmux_env() {
  env -u TMUX -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID \
    TMUX_TMPDIR="$TMUX_DIR" HERMES_HOME="$PROFILE" FM_HOME="$FM_LIVE_HOME" \
    "$@"
}

capture() {  # <target> [lines]
  TMUX_TMPDIR="$TMUX_DIR" tmux capture-pane -p -t "$1" -S "-${2:-20}"
}

wait_file() {  # <file> [polls]
  local file=$1 polls=${2:-240} i=0
  while [ "$i" -lt "$polls" ]; do
    [ -f "$file" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

busy_state() {  # <id>
  local id=$1
  # shellcheck disable=SC2016 # Positional parameters expand inside the probe shell.
  env -u TMUX TMUX_TMPDIR="$TMUX_DIR" FM_HOME="$FM_LIVE_HOME" bash -c \
    '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-busy-lib.sh"; fm_busy_classify_meta "$2" "$3" "$4"' \
    _ "$ROOT" "$FM_LIVE_HOME/state/$id.meta" "$id" "$FM_LIVE_HOME/state"
}

wait_state() {  # <id> <busy|idle> [polls]
  local id=$1 wanted=$2 polls=${3:-240} i=0 state
  while [ "$i" -lt "$polls" ]; do
    state=$(busy_state "$id")
    [ "${state%% *}" != "$wanted" ] || { printf '%s' "$state"; return 0; }
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

wait_capture() {  # <target> <literal> [polls]
  local target=$1 literal=$2 polls=${3:-240} i=0 pane
  while [ "$i" -lt "$polls" ]; do
    pane=$(capture "$target" 30)
    printf '%s\n' "$pane" | grep -Fq "$literal" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

HERMES_VERSION=$($HERMES_BIN --version | head -1)
printf 'command: fm-spawn %s --harness hermes --backend tmux --model gpt-5.6-sol --effort low\n' "$WORKER"
run_tmux_env env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$WORKER" "$PROJECT" \
  --harness hermes --backend tmux --model gpt-5.6-sol --effort low \
  --mode local-only --yolo off
wait_file "$FM_LIVE_HOME/state/$WORKER.turn-ended" || fail "initial Hermes TUI turn did not end"
wait_capture "$WORKER_TARGET" HERMES-TUI-SPAWN-OK || fail "initial Hermes TUI response missing"
SESSION_ID=$(cat "$FM_LIVE_HOME/state/$WORKER.hermes-session")
[ -n "$SESSION_ID" ] || fail "Hermes TUI session id is empty"
printf 'output: persistent=yes session=%s turn_end=touched busy=%s\n' "$SESSION_ID" "$(busy_state "$WORKER")"

mv "$FM_LIVE_HOME/state/$WORKER.turn-ended" "$FM_LIVE_HOME/state/$WORKER.initial-turn-ended"
printf 'command: fm-send %s "Use terminal_tool to run sleep 5 ..."\n' "$WORKER"
run_tmux_env env FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$WORKER" \
  'Use terminal_tool to run sleep 5, then reply exactly HERMES-TUI-STEER-OK.'
BUSY=$(wait_state "$WORKER" busy) || fail "Hermes TUI never reported busy"
wait_file "$FM_LIVE_HOME/state/$WORKER.turn-ended" || fail "steered Hermes TUI turn did not end"
IDLE=$(wait_state "$WORKER" idle) || fail "Hermes TUI did not return idle"
wait_capture "$WORKER_TARGET" HERMES-TUI-STEER-OK || fail "Hermes TUI steer response missing"
printf 'output: submit=verified busy=%s idle=%s turn_end=touched\n' "$BUSY" "$IDLE"

mv "$FM_LIVE_HOME/state/$WORKER.turn-ended" "$FM_LIVE_HOME/state/$WORKER.steer-turn-ended"
printf 'command: fm-send %s /fmnative\n' "$WORKER"
run_tmux_env env FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$WORKER" /fmnative \
  || fail "native Hermes skill send was not accepted as a proven model turn"
NATIVE_BUSY=$(wait_state "$WORKER" busy) || fail "native Hermes skill never reported busy"
wait_file "$FM_LIVE_HOME/state/$WORKER.turn-ended" || fail "native Hermes skill turn did not end"
NATIVE_IDLE=$(wait_state "$WORKER" idle) || fail "native Hermes skill turn did not return idle"
wait_capture "$WORKER_TARGET" HERMES-TUI-NATIVE-SKILL-OK \
  || fail "native Hermes skill did not produce its model reply"
printf 'output: native_skill=/fmnative send=0 busy=%s idle=%s turn_end=touched\n' \
  "$NATIVE_BUSY" "$NATIVE_IDLE"

mv "$FM_LIVE_HOME/state/$WORKER.turn-ended" "$FM_LIVE_HOME/state/$WORKER.native-turn-ended"
printf 'command: fm-send %s "sleep 20"; fm-send %s --key C-c\n' "$WORKER" "$WORKER"
run_tmux_env env FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$WORKER" \
  'Use terminal_tool to run sleep 20, then reply SHOULD-NOT-COMPLETE.'
wait_state "$WORKER" busy >/dev/null || fail "Hermes interrupt probe never became busy"
run_tmux_env "$ROOT/bin/fm-send.sh" "$WORKER" --key C-c
INTERRUPTED=$(wait_state "$WORKER" idle) || fail "Hermes TUI did not settle after Ctrl+C"
wait_file "$FM_LIVE_HOME/state/$WORKER.turn-ended" || fail "Hermes interrupt did not fire turn-end"
wait_capture "$WORKER_TARGET" interrupted || fail "Hermes TUI did not render its interrupt result"
printf 'output: interrupt=C-c state=%s turn_end=touched\n' "$INTERRUPTED"

printf 'command: fm-send %s /exit\n' "$WORKER"
run_tmux_env "$ROOT/bin/fm-send.sh" "$WORKER" /exit
[ "$(TMUX_TMPDIR="$TMUX_DIR" tmux display-message -p -t "$WORKER_TARGET" '#{pane_current_command}')" != python3 ] \
  || fail "Hermes /exit left the TUI process alive"
printf 'output: exit=0 foreground=shell\n'

TMUX_TMPDIR="$TMUX_DIR" tmux kill-window -t "$WORKER_TARGET"
printf 'command: fm-spawn %s ... --resume %s (from task state)\n' "$WORKER" "$SESSION_ID"
run_tmux_env env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$WORKER" "$PROJECT" \
  --harness hermes --backend tmux --model gpt-5.6-sol --effort low \
  --mode local-only --yolo off
[ "$(cat "$FM_LIVE_HOME/state/$WORKER.hermes-session")" = "$SESSION_ID" ] \
  || fail "Hermes TUI resume changed the task-bound session"
wait_state "$WORKER" idle >/dev/null || fail "resumed Hermes TUI did not settle"
run_tmux_env env FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$WORKER" \
  'Print only the token you were asked to remember earlier.'
wait_state "$WORKER" idle >/dev/null || fail "resumed Hermes context turn did not settle"
wait_capture "$WORKER_TARGET" HERMES-TUI-RESUME-825 || fail "Hermes TUI resume lost context"
printf 'output: same_session=yes context=HERMES-TUI-RESUME-825\n'
run_tmux_env "$ROOT/bin/fm-send.sh" "$WORKER" /exit
run_tmux_env "$ROOT/bin/fm-teardown.sh" "$WORKER" >/dev/null

printf 'command: fm-spawn %s --scout --harness hermes --backend tmux\n' "$SCOUT"
run_tmux_env env FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$SCOUT" "$PROJECT" \
  --scout --harness hermes --backend tmux --model gpt-5.6-sol --effort medium
wait_file "$FM_LIVE_HOME/state/$SCOUT.turn-ended" || fail "Hermes scout TUI turn did not end"
SCOUT_TARGET=$(sed -n 's/^window=//p' "$FM_LIVE_HOME/state/$SCOUT.meta")
wait_capture "$SCOUT_TARGET" HERMES-TUI-SCOUT-OK || fail "Hermes scout TUI response missing"
printf 'output: scout_persistent=yes turn_end=touched\n'
SCOUT_TOKEN=$(sed -n 's/^hermes_owner_token=//p' "$FM_LIVE_HOME/state/$SCOUT.meta")
SCOUT_WT=$(sed -n 's/^worktree=//p' "$FM_LIVE_HOME/state/$SCOUT.meta")
[ -n "$SCOUT_TOKEN" ] || fail "Hermes scout recorded no owner token"
[ -n "$SCOUT_WT" ] || fail "Hermes scout recorded no worktree"
SCOUT_TREE=$(live_task_pids "$SCOUT_TOKEN" "$SCOUT_WT")
[ -n "$SCOUT_TREE" ] \
  || fail "Hermes scout owned no live process before teardown; the active-tree case would prove nothing"
printf 'scout report\n' > "$FM_LIVE_HOME/data/$SCOUT/report.md"
FM_HOME="$FM_LIVE_HOME" "$ROOT/bin/fm-decision-hold.sh" complete "$SCOUT" --none >/dev/null
printf 'command: fm-teardown %s (persistent TUI still running, no /exit)\n' "$SCOUT"
run_tmux_env "$ROOT/bin/fm-teardown.sh" "$SCOUT" >/dev/null
SCOUT_SURVIVORS=$(live_task_pids "$SCOUT_TOKEN" "$SCOUT_WT")
[ -z "$SCOUT_SURVIVORS" ] \
  || fail "fm-teardown left scout-owned process(es) alive: $(printf '%s' "$SCOUT_SURVIVORS" | tr '\n' ' ')"
printf 'output: active_teardown=yes owned_before=%s survivors=0\n' \
  "$(printf '%s' "$SCOUT_TREE" | tr '\n' ' ' | sed 's/ $//')"

printf 'ok - %s persistent Hermes TUI: crew/scout launch, composer steer, native skill turn, busy->idle, turn-end, interrupt, exit, and exact-session resume\n' "$HERMES_VERSION"
