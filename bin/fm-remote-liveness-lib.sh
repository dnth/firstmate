#!/usr/bin/env bash
# fm-remote-liveness-lib.sh - the single owner of the remote-route
# sustained-unreachable rule.
#
# An unreachable remote host is never evidence that its second mate is dead or
# wedged. Only a conclusive probe may drive supervision:
#
#   conclusive    a numeric beacon age, or an owner state answer. A fresh age
#                 suppresses stale detection and a stale age enters the ordinary
#                 stale path unchanged.
#   inconclusive  a deadline hit, no answer, transport failure, non-numeric
#                 output, or no deadline tool. It starts or continues one
#                 unreachable episode for that route and never raises a stale or
#                 wedge verdict, no matter how many arrive in a row.
#
# One episode per route is tracked by the caller's endpoint key, which both the
# always-on watcher and the away-mode daemon take from the route's task id so
# either surface observes the same episode:
#
#   state/.remote-unreachable-since-<key>     epoch of the episode's first
#                                             inconclusive probe
#   state/.remote-unreachable-alerted-<key>   epoch of the episode's one alert
#
# The episode's first alert is due once it has lasted
# FM_REMOTE_UNREACHABLE_ALERT_SECS (positive integer of at most nine digits,
# default 1800; a zero, non-numeric, or oversized value uses 1800). The tick
# atomically claims the alert before returning it for delivery, preventing repeats
# across watcher or daemon restarts. Only a conclusive probe ends the
# episode and removes both files; the next inconclusive probe after that starts a
# new episode, which may alert again.
#
# The callers own probe mechanics and wording: bin/fm-watch.sh probes a remote
# beacon age and bin/fm-supervise-daemon.sh probes a stale route's owner state.
# Neither caller may turn an inconclusive result into a stale verdict, and both
# ignore the retired consecutive-probe counters
# (state/.remote-inconclusive-<key> and
# state/.subsuper-remote-inconclusive-<key>) from earlier releases.

FM_REMOTE_UNREACHABLE_ALERT_SECS_DEFAULT=1800

# Print the validated sustained-unreachable window in seconds.
fm_remote_unreachable_alert_secs() {
  local secs=${FM_REMOTE_UNREACHABLE_ALERT_SECS:-$FM_REMOTE_UNREACHABLE_ALERT_SECS_DEFAULT}
  case "$secs" in
    ''|*[!0-9]*|??????????*) secs=$FM_REMOTE_UNREACHABLE_ALERT_SECS_DEFAULT ;;
  esac
  [ -n "${secs//0/}" ] || secs=$FM_REMOTE_UNREACHABLE_ALERT_SECS_DEFAULT
  printf '%s\n' "$secs"
}

# Validate one episode key. Returns 2 for an empty or path-unsafe key, which the
# callers treat as unusable evidence rather than tracking a bogus route.
fm_remote_unreachable_key_ok() {  # <key>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_remote_unreachable_lock() {
  local state=$1 key=$2
  if ! declare -F fm_lock_acquire_wait >/dev/null; then
    FM_STATE_OVERRIDE="$state" . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"
  fi
  mkdir -p "$state/.remote-unreachable-locks" || return 2
  fm_lock_acquire_wait "$state/.remote-unreachable-locks/$key.lock"
}

# Record one inconclusive probe for <state> <endpoint-key> [now].
# Prints the episode's age in seconds.
# Returns 0 when that age has reached the window and this episode has not
# alerted yet, 1 while the
# probe must be absorbed, and 2 on an unusable key or state directory.
fm_remote_unreachable_tick() (  # <state> <key> [now]
  local state=$1 key=$2 now=${3:-} since_file alerted_file started age window
  fm_remote_unreachable_key_ok "$key" || return 2
  [ -d "$state" ] || return 2
  fm_remote_unreachable_lock "$state" "$key" || return 2
  trap 'fm_lock_release "$state/.remote-unreachable-locks/$key.lock"' EXIT
  if [ -z "$now" ]; then
    now=$(date +%s)
  fi
  case "$now" in ''|*[!0-9]*) return 2 ;; esac
  since_file="$state/.remote-unreachable-since-$key"
  alerted_file="$state/.remote-unreachable-alerted-$key"
  started=$(cat "$since_file" 2>/dev/null || true)
  case "$started" in
    ''|*[!0-9]*) started=$now ;;
  esac
  # A future start (clock jump) restarts the episode instead of waiting out an
  # impossible window.
  [ "$started" -le "$now" ] || started=$now
  printf '%s\n' "$started" > "$since_file" 2>/dev/null || return 2
  age=$(( now - started ))
  printf '%s\n' "$age"
  [ ! -e "$alerted_file" ] || return 1
  window=$(fm_remote_unreachable_alert_secs)
  [ "$age" -ge "$window" ] || return 1
  printf '%s\n' "$now" > "$alerted_file" || return 2
  return 0
)

# End the route's episode after a conclusive probe.
fm_remote_unreachable_end() (  # <state> <key>
  local state=$1 key=$2
  fm_remote_unreachable_key_ok "$key" || return 2
  [ -d "$state" ] || return 2
  fm_remote_unreachable_lock "$state" "$key" || return 2
  trap 'fm_lock_release "$state/.remote-unreachable-locks/$key.lock"' EXIT
  rm -f "$state/.remote-unreachable-since-$key" \
    "$state/.remote-unreachable-alerted-$key"
)
