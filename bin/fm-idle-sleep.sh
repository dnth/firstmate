#!/usr/bin/env bash
# Opt-in idle auto-sleep for Boat and RunPod second-mate placements.
#
# Usage:
#   fm-idle-sleep.sh tick            one watcher-cycle pass (cheap, no network)
#   fm-idle-sleep.sh check <id>      read-only verdict for one placement
#   fm-idle-sleep.sh run <id>        one guarded sleep attempt (tick detaches it)
#
# Opt-in lives in config/idle-sleep, one placement per line: `<id> [<minutes>]`.
# A blank minutes field means FM_IDLE_SLEEP_DEFAULT_MINUTES (default 30); `#`
# starts a comment. A home without that file does nothing, and a placement not
# listed in it is never touched. docs/configuration.md owns the file's contract.
#
# This is not a second watcher. bin/fm-watch.sh calls `tick` once per cycle;
# tick is throttled to FM_IDLE_SLEEP_TICK_SECONDS (default 60) and reads only
# this home's records, so a quiet fleet pays nothing. A placement is a candidate
# only when its compute is awake, it has no undelivered backlog handoff, no
# unresolved routed reply, no open decision, and nothing in this home's records
# for it (status, endpoint meta, pending replies, handoff files, provider meta)
# has changed for the whole window. A candidate gets one detached `run` per
# FM_IDLE_SLEEP_ATTEMPT_SECONDS (default 300), or per window after a refusal.
#
# `run` adds the two remote reads tick cannot make: the second-mate agent must
# read idle (busy or unreadable keeps it awake) and its home must supervise no
# live worker. It then calls the provider's own guarded `sleep` - bin/fm-boat.sh
# or bin/fm-runpod.sh - which re-checks every guard and reconciles finished
# ships. Nothing here passes a force flag or deletes anything. A success appends
# one line to state/idle-sleep.log; delivery wakes the placement as usual.
#
# A refusal by the guarded sleep is recorded under state/idle-sleep/<id>.refused
# and surfaced by tick as one `check:` wake naming the placement and the reason.
# The same reason is not surfaced again, and new activity clears the record, so
# a refusal that persists costs one report, not one per attempt.
#
# Environment overrides (tests): FM_IDLE_SLEEP_UNIT_SECONDS (seconds per
# configured minute, default 60), FM_IDLE_SLEEP_TICK_SECONDS,
# FM_IDLE_SLEEP_ATTEMPT_SECONDS, FM_IDLE_SLEEP_DEFAULT_MINUTES.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/idle-sleep"
RECORDS="$STATE/idle-sleep"
UNIT_SECONDS=${FM_IDLE_SLEEP_UNIT_SECONDS:-60}
TICK_SECONDS=${FM_IDLE_SLEEP_TICK_SECONDS:-60}
ATTEMPT_SECONDS=${FM_IDLE_SLEEP_ATTEMPT_SECONDS:-300}
DEFAULT_MINUTES=${FM_IDLE_SLEEP_DEFAULT_MINUTES:-30}

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-compute-lib.sh
. "$SCRIPT_DIR/fm-compute-lib.sh"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
id_valid() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
positive_int() { case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac; }

# Print `<id> <minutes>` for each valid line and `!invalid <line>` for each invalid
# one, so a typo is reported rather than silently opting a placement in or out.
config_entries() {
  local line id minutes extra
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    # shellcheck disable=SC2086 # word splitting is the parse
    set -- $line
    [ "$#" -gt 0 ] || continue
    id=$1 minutes=${2:-$DEFAULT_MINUTES} extra=${3:-}
    if [ -n "$extra" ] || ! id_valid "$id" || ! positive_int "$minutes"; then
      printf '!invalid %s\n' "$*"
      continue
    fi
    printf '%s %s\n' "$id" "$minutes"
  done < "$CONFIG_FILE"
}

window_minutes() { # <id> -> minutes, or empty when not opted in
  local id=$1 entry_id minutes selected=
  while read -r entry_id minutes; do
    if [ "$entry_id" = "!invalid" ]; then
      [ "${minutes%% *}" != "$id" ] || return 0
      continue
    fi
    [ "$entry_id" != "$id" ] || [ -n "$selected" ] || selected=$minutes
  done < <(config_entries)
  [ -z "$selected" ] || printf '%s\n' "$selected"
  return 0
}

# The newest change this home recorded for the placement.
last_activity() { # <id> -> epoch
  local id=$1 newest=0 path m task_id
  for path in "$STATE/$id.status" "$STATE/$id.meta" "$DATA/boat/$id.meta" \
              "$DATA/runpod/$id.meta" "$DATA/handoff/$id".*; do
    [ -e "$path" ] || continue
    m=$(fm_path_mtime "$path") || continue
    [ "$m" -le "$newest" ] || newest=$m
  done
  for path in "$STATE/pending-replies/"*; do
    [ -f "$path" ] || continue
    task_id=$(fm_pending_reply_get "$path" task_id)
    [ "$task_id" = "$id" ] || continue
    m=$(fm_path_mtime "$path") || continue
    [ "$m" -le "$newest" ] || newest=$m
  done
  printf '%s\n' "$newest"
}

# Local-only verdict, no network. Prints `idle` or the reason it is not, and
# returns 0 only for a placement that is a candidate for a guarded attempt.
local_verdict() { # <id>
  local id=$1 minutes path open window now last
  minutes=$(window_minutes "$id")
  [ -n "$minutes" ] || { printf 'not opted in\n'; return 1; }
  [ "$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null || true)" = 1 ] \
    || { printf 'not a remote second-mate route\n'; return 1; }
  fm_compute_is_managed "$DATA" "$id" || { printf 'not a Boat or RunPod placement\n'; return 1; }
  fm_compute_provider "$DATA" "$id" >/dev/null 2>&1 || { printf 'ambiguous placement ownership\n'; return 1; }
  if fm_compute_is_dormant "$DATA" "$id"; then printf 'already dormant\n'; return 1; fi
  path="$DATA/handoff/$id.outbox.md"
  if [ -e "$path" ] || [ -L "$path" ]; then printf 'undelivered backlog handoff\n'; return 1; fi
  for path in "$STATE/pending-replies/"*; do
    [ -f "$path" ] || continue
    [ "$(fm_pending_reply_get "$path" task_id)" = "$id" ] || continue
    [ "$(fm_pending_reply_get "$path" phase)" = resolved ] || { printf 'unresolved routed reply\n'; return 1; }
  done
  open=$(status_open_decisions "$STATE/$id.status")
  [ -z "$open" ] || { printf 'open decision\n'; return 1; }
  window=$((minutes * UNIT_SECONDS))
  now=$(date +%s)
  last=$(last_activity "$id")
  [ $((now - last)) -ge "$window" ] || { printf 'active within the idle window\n'; return 1; }
  printf 'idle\n'
}

log_line() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$STATE/idle-sleep.log"; }

cmd_check() {
  local id=${1:-} verdict rc=0
  id_valid "$id" || usage
  verdict=$(local_verdict "$id") || rc=$?
  printf '%s\n' "$verdict"
  return "$rc"
}

# Print the line a refused attempt still owes the captain, once.
report_refusals() { # <id>
  local id=$1 refused="$RECORDS/$1.refused" reported="$RECORDS/$1.reported" reason
  [ -f "$refused" ] || return 0
  [ ! -f "$reported" ] || return 0
  reason="check: idle-sleep $id refused by the guarded sleep, left awake and not forced: $(head -c 400 "$refused")"
  fm_wake_append check "idle-sleep:$id" "$reason" || return 0
  : > "$reported"
  printf '%s\n' "$reason"
}

cmd_tick() {
  local entry_id minutes marker bad_marker bad_hash verdict attempt age floor
  [ -f "$CONFIG_FILE" ] || return 0
  marker="$STATE/.idle-sleep-tick"
  [ "$(fm_path_age "$marker")" -ge "$TICK_SECONDS" ] || return 0
  mkdir -p "$RECORDS" && touch "$marker" || return 0
  while read -r entry_id minutes; do
    if [ "$entry_id" = "!invalid" ]; then
      bad_hash=$(printf '%s' "$minutes" | cksum | tr ' ' '-')
      bad_marker="$RECORDS/.config-reported-$bad_hash"
      [ ! -f "$bad_marker" ] || continue
      fm_wake_append check "idle-sleep-config:$bad_hash" "check: idle-sleep config line ignored (expected '<id> [<minutes>]'): $minutes" \
        && touch "$bad_marker" && printf 'check: idle-sleep config line ignored (expected '"'"'<id> [<minutes>]'"'"'): %s\n' "$minutes"
      continue
    fi
    if [ -f "$RECORDS/$entry_id.refused" ] \
       && [ "$(last_activity "$entry_id")" -gt "$(fm_path_mtime "$RECORDS/$entry_id.refused" || echo 0)" ]; then
      rm -f "$RECORDS/$entry_id.refused" "$RECORDS/$entry_id.reported"
    fi
    report_refusals "$entry_id"
    verdict=$(local_verdict "$entry_id") || continue
    attempt="$RECORDS/$entry_id.attempt"
    floor=$ATTEMPT_SECONDS
    [ ! -f "$RECORDS/$entry_id.refused" ] || floor=$((minutes * UNIT_SECONDS))
    age=$(fm_path_age "$attempt")
    [ "$age" -ge "$floor" ] || continue
    touch "$attempt"
    ( nohup "$0" run "$entry_id" </dev/null >/dev/null 2>&1 & ) || true
  done < <(config_entries)
}

run_remote_read() { # <id> <action>
  "$SCRIPT_DIR/fm-on.sh" "$1" fm-remote-secondmate-control.sh "$2" "$1" </dev/null 2>/dev/null
}

cmd_run() {
  local id=${1:-} lock="$STATE/.idle-sleep-$1.lock" provider out rc=0 observed children msg refused="$RECORDS/$1.refused"
  id_valid "$id" || usage
  mkdir -p "$RECORDS" || exit 1
  fm_lock_try_acquire "$lock" || exit 0
  trap "fm_lock_release $(printf '%q' "$lock")" EXIT
  local_verdict "$id" >/dev/null || exit 0
  observed=$(run_remote_read "$id" observe) || exit 0
  case "$observed" in idle) ;; *) exit 0 ;; esac
  children=$(run_remote_read "$id" children) || exit 0
  [ "$children" = children=0 ] || exit 0
  provider=$(fm_compute_provider "$DATA" "$id") || exit 0
  out=$(FM_IDLE_SLEEP_RECHECK=1 "$SCRIPT_DIR/fm-$provider.sh" sleep "$id" 2>&1 </dev/null) || rc=$?
  if [ "$rc" -eq 0 ]; then
    log_line "idle-sleep: $id ($provider) slept after an idle window"
    rm -f "$refused" "$RECORDS/$id.reported"
    return 0
  fi
  [ "$rc" -ne 75 ] || return 0
  msg=$(printf '%s\n' "$out" | fm_wake_clean_field | grep -v '^[[:space:]]*$' | tail -1)
  [ -n "$msg" ] || msg="sleep exited $rc without a message"
  log_line "idle-sleep: $id ($provider) refused: $msg"
  if [ "$(cat "$refused" 2>/dev/null || true)" != "$msg" ]; then
    printf '%s\n' "$msg" > "$refused"
    rm -f "$RECORDS/$id.reported"
  fi
}

case "${1:-}" in
  tick) cmd_tick ;;
  check) shift; cmd_check "$@" ;;
  run) shift; cmd_run "$@" ;;
  *) usage ;;
esac
