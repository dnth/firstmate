#!/usr/bin/env bash
# Shared durable wake queue and portable lock helpers.

FM_WAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_DEFAULT_ROOT="$(cd "$FM_WAKE_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_WAKE_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
FM_WAKE_QUEUE="${FM_WAKE_QUEUE:-$STATE/.wake-queue}"
FM_WAKE_QUEUE_LOCK="${FM_WAKE_QUEUE_LOCK:-$STATE/.wake-queue.lock}"
FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}"
# Resolved once at source time: fm_pid_identity and fm_path_mtime run inside 0.2s
# confirm and 0.5s attach polls, and forking uname per call is a measurable cost on
# the platform (Git Bash/MSYS) that already pays the highest fork price.
_FM_UNAME=$(uname 2>/dev/null || echo unknown)
mkdir -p "$STATE"

fm_current_pid() {
  printf '%s\n' "${BASHPID:-$$}"
}

fm_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_pid_identity() {
  local pid=$1 out proc_root stat_line starttime cmdline_hex identity_key
  local -a stat_fields
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  # Prefer a Linux-compatible /proc when present: stat field 22 (starttime, clock ticks since boot) is
  # immune to the wall-clock steps that re-render the ps lstart fallback's date
  # (observed as WSL2 btime drift) and would evict a live watcher; combining the
  # full NUL-separated cmdline keeps PID reuse a mismatch even on a tick collision.
  # Git Bash/MSYS exposes these compatible files but its Cygwin ps rejects the
  # portable fallback's -o fields, so capability detection must not key on uname.
  if [ -r "$proc_root/$pid/stat" ] && [ -r "$proc_root/$pid/cmdline" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    # After the final comm delimiter, array index 19 is proc stat field 22.
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "$proc_root/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    identity_key=proc-starttime
    [ "$_FM_UNAME" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  # Pin LC_ALL=C so lstart's date format is locale-invariant: the identity is
  # written under one locale but re-read under the machine's ambient locale, which
  # would otherwise mismatch on a non-C locale (e.g. ko_KR) and reject a live watcher.
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_path_mtime() {
  if [ "$_FM_UNAME" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local path=$1 m
  m=$(fm_path_mtime "$path") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

FM_WATCHER_MATCHED_IDENTITY=
fm_watcher_lock_matches_pid() {
  local state=$1 watch_path=$2 pid=$3 home=${4:-$FM_HOME} lockdir lock_home lock_path lock_identity current_identity
  FM_WATCHER_MATCHED_IDENTITY=
  lockdir="$state/.watch.lock"
  lock_home=$(cat "$lockdir/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lockdir/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$home" ] || return 1
  [ "$lock_path" = "$watch_path" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ] || return 1
  FM_WATCHER_MATCHED_IDENTITY=$lock_identity
}

FM_WATCHER_HEALTHY_PID=
FM_WATCHER_HEALTHY_IDENTITY=
fm_watcher_healthy() {
  local state=$1 watch_path=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME} lockdir beat pid identity age
  FM_WATCHER_HEALTHY_PID=
  FM_WATCHER_HEALTHY_IDENTITY=
  lockdir="$state/.watch.lock"
  beat="$state/.last-watcher-beat"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  fm_watcher_lock_matches_pid "$state" "$watch_path" "$pid" "$home" || return 1
  identity=$FM_WATCHER_MATCHED_IDENTITY
  age=$(fm_path_age "$beat")
  [ "$age" -lt "$grace" ] || return 1
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_PID=$pid
  # shellcheck disable=SC2034 # Read by callers after fm_watcher_healthy returns.
  FM_WATCHER_HEALTHY_IDENTITY=$identity
  return 0
}

# fm_watcher_healthy above is the PID-STRICT primitive: true only when a live,
# identity-matched watcher PROCESS holds this home's lock with a fresh beacon. The
# arm layer (bin/fm-watch-arm.sh, bin/fm-claude-stop-autoarm.sh) needs exactly
# that - it decides whether to start, attach to, or replace a real watcher
# process, so a leftover beacon must never satisfy it. bin/fm-turnend-guard.sh
# also keeps this strict check because it fires at the turn boundary where the
# auto-arm brings a fresh watcher up. The pull warning (bin/fm-guard.sh) fires
# mid-turn, where the auto-arm model runs no watcher at all, so it wants a
# different, model-aware question:

# fm_supervision_model
# Print the supervision model of this home's PRIMARY harness:
#   autoarm     Claude Stop-hook auto-arm: the watcher is armed at each turn end
#               and exits on its wake, so it runs only BETWEEN turns. Mid-turn a
#               fresh beacon with no live watcher process is the healthy state.
#   persistent  every other harness (codex foreground checkpoint, opencode/pi/grok
#               background arm, tmux, unknown): the watcher runs as a tracked live
#               process, so a live identity-matched pid is the real liveness signal.
# FM_SUPERVISION_MODEL overrides detection (tests, and callers that already know
# the harness). Otherwise bin/fm-harness.sh is the single detection owner, so this
# stays consistent with the harness-specific repair line the guards already emit.
fm_supervision_model() {
  local harness
  case "${FM_SUPERVISION_MODEL:-}" in
    autoarm|persistent) printf '%s\n' "$FM_SUPERVISION_MODEL"; return 0 ;;
  esac
  harness=$("$FM_WAKE_LIB_DIR/fm-harness.sh" 2>/dev/null || printf unknown)
  case "$harness" in
    claude) printf 'autoarm\n' ;;
    *) printf 'persistent\n' ;;
  esac
}

# fm_watcher_supervision_verdict <state> <watch-path> [grace] [home]
# Model-aware "is supervision healthy right now" verdict for the pull warning
# guard (bin/fm-guard.sh), NOT the arm layer or the turn-end guard. Sets:
#   FM_WATCHER_VERDICT_OK      true when supervision is healthy for this model
#   FM_WATCHER_VERDICT_REASON  when not ok, the true failing condition:
#                              no-watcher   - a live watcher process is the real
#                                             signal for this model but none holds
#                                             the lock (the beacon is still fresh)
#                              stale-beacon - the beacon is stale beyond grace or
#                                             absent (a genuine supervision lapse)
# autoarm: a fresh beacon within grace is healthy even with no live watcher,
# because the watcher only runs between turns; only a stale beacon is a lapse.
# persistent: require a live identity-matched watcher with a fresh beacon
# (fm_watcher_healthy); a fresh leftover beacon with no live watcher is still down.
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_OK=false
# shellcheck disable=SC2034 # Read by callers after the function returns.
FM_WATCHER_VERDICT_REASON=stale-beacon
fm_watcher_supervision_verdict() {
  local state=$1 watch=$2 grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-$FM_HOME}
  local beat age fresh=false
  FM_WATCHER_VERDICT_OK=false
  FM_WATCHER_VERDICT_REASON=stale-beacon
  beat="$state/.last-watcher-beat"
  age=$(fm_path_age "$beat")
  case "$age" in
    ''|*[!0-9]*) ;;
    *) [ "$age" -lt "$grace" ] && fresh=true ;;
  esac
  if [ "$(fm_supervision_model)" = autoarm ]; then
    [ "$fresh" = true ] && FM_WATCHER_VERDICT_OK=true
    return 0
  fi
  if fm_watcher_healthy "$state" "$watch" "$grace" "$home"; then
    # shellcheck disable=SC2034 # Read by callers after the function returns.
    FM_WATCHER_VERDICT_OK=true
  elif [ "$fresh" = true ]; then
    # shellcheck disable=SC2034 # Read by callers after the function returns.
    FM_WATCHER_VERDICT_REASON=no-watcher
  fi
  return 0
}

fm_lock_clean_known_files() {
  local lockdir=$1
  rm -f \
    "$lockdir/pid" \
    "$lockdir/fm-home" \
    "$lockdir/pid-identity" \
    "$lockdir/role" \
    "$lockdir/watcher-path" \
    2>/dev/null || true
}

fm_lock_set_role() {
  local lockdir=$1 role=$2 current pid back
  case "$role" in
    autoarm|terminal-check) : ;;
    *) return 1 ;;
  esac
  current=${BASHPID:-$$}
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 1
  printf '%s\n' "$role" > "$lockdir/role" 2>/dev/null || return 1
  back=$(cat "$lockdir/role" 2>/dev/null || true)
  [ "$back" = "$role" ]
}

fm_lock_role() {
  cat "$1/role" 2>/dev/null
}

fm_lock_abs_path() {
  local path=$1 dir base
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$dir" "$base"
}

fm_lock_owner_dir() {
  local lockdir=$1 lock_abs
  lock_abs=$(fm_lock_abs_path "$lockdir") || return 1
  mktemp -d "${lock_abs}.owner.XXXXXX" 2>/dev/null
}

fm_lock_prepare_owner() {
  local ownerdir=$1 mypid back
  mypid=${BASHPID:-$$}
  printf '%s\n' "$mypid" > "$ownerdir/pid" 2>/dev/null || return 1
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  [ "$back" = "$mypid" ]
}

fm_lock_link_owner() {
  local lockdir=$1 owner
  owner=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ -n "$owner" ] || return 1
  case "$owner" in
    /*) printf '%s\n' "$owner" ;;
    *) printf '%s/%s\n' "$(dirname "$lockdir")" "$owner" ;;
  esac
}

fm_lock_points_to_owner() {
  local lockdir=$1 ownerdir=$2 actual
  actual=$(readlink "$lockdir" 2>/dev/null) || return 1
  [ "$actual" = "$ownerdir" ]
}

fm_lock_discard_owner() {
  local ownerdir=$1
  [ -n "$ownerdir" ] || return 0
  fm_lock_clean_known_files "$ownerdir"
  rmdir "$ownerdir" 2>/dev/null || true
}

fm_lock_remove_stray_owner_link() {
  local lockdir=$1 ownerdir=$2 stray
  stray="$lockdir/$(basename "$ownerdir")"
  if [ -L "$stray" ] && [ "$(readlink "$stray" 2>/dev/null || true)" = "$ownerdir" ]; then
    rm -f "$stray" 2>/dev/null || true
  fi
}

fm_lock_claim_blocked_by_steal() {
  local lockdir=$1 allowed_steal_owner=${2:-} steal
  steal="$lockdir.steal"
  [ -e "$steal" ] || [ -L "$steal" ] || return 1
  if [ -n "$allowed_steal_owner" ] && fm_lock_points_to_owner "$steal" "$allowed_steal_owner"; then
    return 1
  fi
  return 0
}

fm_lock_claim() {
  local lockdir=$1 ownerdir=$2 allowed_steal_owner=${3:-} mypid back
  mypid=${BASHPID:-$$}
  if ! { printf '%s\n' "$mypid" > "$ownerdir/pid"; } 2>/dev/null; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  back=$(cat "$ownerdir/pid" 2>/dev/null || true)
  if [ "$back" != "$mypid" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if fm_lock_claim_blocked_by_steal "$lockdir" "$allowed_steal_owner"; then
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  return 0
}

fm_lock_try_create() {
  local lockdir=$1 allowed_steal_owner=${2:-} ownerdir
  FM_LOCK_OWNER_DIR=
  ownerdir=$(fm_lock_owner_dir "$lockdir") || return 1
  if [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ! fm_lock_prepare_owner "$ownerdir"; then
    fm_lock_discard_owner "$ownerdir"
    return 1
  fi
  if ln -s "$ownerdir" "$lockdir" 2>/dev/null && fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
    if fm_lock_claim "$lockdir" "$ownerdir" "$allowed_steal_owner"; then
      FM_LOCK_OWNER_DIR=$ownerdir
      return 0
    fi
    if fm_lock_points_to_owner "$lockdir" "$ownerdir"; then
      rm -f "$lockdir" 2>/dev/null || true
    fi
  else
    fm_lock_remove_stray_owner_link "$lockdir" "$ownerdir"
  fi
  fm_lock_discard_owner "$ownerdir"
  return 1
}

fm_lock_remove_path() {
  local lockdir=$1 ownerdir
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    rm -f "$lockdir" 2>/dev/null || return 1
    [ -n "$ownerdir" ] && fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null
}

fm_lock_mid_acquire_is_fresh() {
  local lockdir=$1 pid=$2 mid_acquire_stale
  case "$pid" in
    ''|*[!0-9]*)
      mid_acquire_stale=$FM_LOCK_STALE_AFTER
      [ "$mid_acquire_stale" -lt 2 ] && mid_acquire_stale=2
      [ "$(fm_path_age "$lockdir")" -lt "$mid_acquire_stale" ]
      return
      ;;
  esac
  return 1
}

fm_lock_recheck_stale_owner() {
  local lockdir=$1 expected_owner=$2 expected_pid=$3 actual_pid
  if [ -n "$expected_owner" ]; then
    fm_lock_points_to_owner "$lockdir" "$expected_owner" || return 1
  elif [ -e "$lockdir" ] || [ -L "$lockdir" ]; then
    [ -d "$lockdir" ] && [ ! -L "$lockdir" ] || return 1
  fi
  actual_pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$actual_pid" = "$expected_pid" ] || return 1
  if fm_pid_alive "$actual_pid"; then
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$actual_pid"; then
    return 1
  fi
  return 0
}

FM_RECOVERY_MARKER_TOKEN=
FM_RECOVERY_MARKER_ACTION='none'

# Token grammar (one owner): <pending|announced|acked>:<handling|downtime>:<generation>
# docs/watcher-continuity.md owns the recovery-episode contract, including the
# once-per-generation announcement rule for unacknowledged downtime.
fm_recovery_marker_read() {
  local marker=$1 line count
  FM_RECOVERY_MARKER_TOKEN=
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  count=$(wc -l < "$marker" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$count" = 1 ] || return 1
  IFS= read -r line < "$marker" || return 1
  case "$line" in
    pending:handling:*|pending:downtime:*|announced:handling:*|announced:downtime:*|acked:handling:*|acked:downtime:*) ;;
    *) return 1 ;;
  esac
  case "${line##*:}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  FM_RECOVERY_MARKER_TOKEN=$line
}

_fm_atomic_replace() {
  mv -f -- "$1" "$2"
}

_fm_recovery_marker_write_locked() {
  local marker=$1 kind=$2 generation=${3:-} status=${4:-pending} tmp
  case "$kind" in handling|downtime) ;; *) return 1 ;; esac
  case "$status" in pending|announced) ;; *) return 1 ;; esac
  tmp=$(mktemp "${marker}.tmp.XXXXXX") || return 1
  [ -n "$generation" ] || generation="$(fm_current_pid).$(date +%s).${tmp##*.}"
  if ! printf '%s:%s:%s\n' "$status" "$kind" "$generation" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! _fm_atomic_replace "$tmp" "$marker"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# True when <lock> is currently claimed by THIS process.
fm_lock_held_by_self() {  # <lockdir>
  local lockdir=$1 ownerdir pid current
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 1
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
  else
    [ -d "$lockdir" ] || return 1
    pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fi
  [ -n "$pid" ] && [ "$pid" = "$current" ]
}

# Set by _fm_recovery_lock_acquire: 1 when the caller entered a marker lock this
# process already held, 0 when it genuinely acquired one.
FM_RECOVERY_LOCK_REENTERED=0

# Acquire a recovery-marker lock. With no attempt budget this waits exactly like
# every other marker transition. With one, it bounds the wait so a caller that
# promised its own whole-call bound (fm_wake_append's bounded mode) keeps it, and
# reports exhaustion as 3 rather than blocking or silently skipping publication.
#
# Reentrancy is not a style concern here, it is the difference between a watcher
# that stops and one that cannot be stopped. bin/fm-watch.sh's EXIT trap performs
# a marker transition, and a signal can fire that trap while an interrupted frame
# is still inside a marker critical section - observed landing between
# fm_recovery_marker_arm_check's release and its return. Waiting for a lock this
# same process holds can never be satisfied, so the watcher would spin forever,
# ignore every later signal, and pin the durable wake queue's lock with it.
# Detect that case, proceed under the exclusion already held, and let the caller
# leave the lock exactly as the interrupted frame left it: the exiting process
# abandons it, and fm_lock_try_acquire reclaims a dead owner's lock as usual.
_fm_recovery_lock_acquire() {
  local lock=$1 attempts=${2:-} tries=0
  FM_RECOVERY_LOCK_REENTERED=0
  if fm_lock_held_by_self "$lock"; then
    FM_RECOVERY_LOCK_REENTERED=1
    return 0
  fi
  if [ -z "$attempts" ]; then
    fm_lock_acquire_wait "$lock"
    return 0
  fi
  case "$attempts" in ''|*[!0-9]*|0) return 2 ;; esac
  while ! fm_lock_try_acquire "$lock"; do
    tries=$((tries + 1))
    [ "$tries" -lt "$attempts" ] || return 3
    sleep 0.05
  done
}

# Release a marker lock only when this frame actually acquired it.
_fm_recovery_lock_release() {  # <lock> <reentered>
  [ "${2:-0}" = 1 ] || fm_lock_release "$1"
}

# Preserve a pending or announced episode's generation across downtime
# republication so its outstanding acknowledgement remains usable, and keep an
# already-announced generation announced so it cannot be re-presented until a
# new down stretch mints a new generation.
# docs/watcher-continuity.md owns the recovery contract and sequence-safety rationale.
_fm_recovery_marker_publish() {
  local marker=$1 kind=${2:-downtime} lock_attempts=${3:-} lock status reentered
  local saved_token generation='' marker_status=pending
  case "$kind" in handling|downtime) ;; *) return 1 ;; esac
  lock="${marker}.lock"
  _fm_recovery_lock_acquire "$lock" "$lock_attempts" || { status=$?; return "$status"; }
  reentered=$FM_RECOVERY_LOCK_REENTERED
  if [ -d "$marker" ] && [ ! -L "$marker" ]; then
    _fm_recovery_lock_release "$lock" "$reentered"
    return 1
  fi
  if [ "$kind" = downtime ]; then
    # Read inline rather than in a command substitution: this runs inside the
    # marker-lock critical section, so it must not add a subshell fork there.
    # The token is restored because publishing owns no snapshot of its own.
    saved_token=$FM_RECOVERY_MARKER_TOKEN
    if fm_recovery_marker_read "$marker"; then
      case "$FM_RECOVERY_MARKER_TOKEN" in
        pending:handling:*|pending:downtime:*)
          generation=${FM_RECOVERY_MARKER_TOKEN##*:}
          marker_status=pending
          ;;
        announced:handling:*|announced:downtime:*)
          generation=${FM_RECOVERY_MARKER_TOKEN##*:}
          marker_status=announced
          ;;
      esac
    fi
    FM_RECOVERY_MARKER_TOKEN=$saved_token
  fi
  if ! _fm_recovery_marker_write_locked "$marker" "$kind" "$generation" "$marker_status"; then
    _fm_recovery_lock_release "$lock" "$reentered"
    return 1
  fi
  _fm_recovery_lock_release "$lock" "$reentered"
}

_fm_recovery_marker_begin_handling() {
  local marker=$1 expected_generation=${2:-} lock line generation status reentered
  lock="${marker}.lock"
  _fm_recovery_lock_acquire "$lock" 20 || { status=$?; return "$status"; }
  reentered=$FM_RECOVERY_LOCK_REENTERED
  if ! fm_recovery_marker_read "$marker"; then
    _fm_recovery_lock_release "$lock" "$reentered"
    return 1
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  generation=${line##*:}
  if [ -n "$expected_generation" ] && [ "$generation" != "$expected_generation" ]; then
    _fm_recovery_lock_release "$lock" "$reentered"
    return 3
  fi
  case "$line" in
    pending:handling:*|announced:handling:*) ;;
    pending:downtime:*)
      if ! _fm_recovery_marker_write_locked "$marker" handling "$generation"; then
        _fm_recovery_lock_release "$lock" "$reentered"
        return 1
      fi
      FM_RECOVERY_MARKER_TOKEN="pending:handling:$generation"
      ;;
    announced:downtime:*)
      if ! _fm_recovery_marker_write_locked "$marker" handling "$generation" announced; then
        _fm_recovery_lock_release "$lock" "$reentered"
        return 1
      fi
      FM_RECOVERY_MARKER_TOKEN="announced:handling:$generation"
      ;;
    *) _fm_recovery_lock_release "$lock" "$reentered"; return 1 ;;
  esac
  _fm_recovery_lock_release "$lock" "$reentered"
}

fm_recovery_marker_snapshot() {
  local marker=$1 lock
  FM_RECOVERY_MARKER_TOKEN=
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  fm_recovery_marker_read "$marker" || true
  fm_lock_release "$lock"
}

_fm_recovery_marker_ack() {
  local marker=$1 expected_generation=$2 lock tmp line
  [ -n "$expected_generation" ] || return 2
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_recovery_marker_read "$marker" \
    || [ "${FM_RECOVERY_MARKER_TOKEN##*:}" != "$expected_generation" ]; then
    fm_lock_release "$lock"
    return 3
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  case "$line" in
    pending:*|announced:*) line="acked:${line#*:}" ;;
    acked:*) fm_lock_release "$lock"; return 0 ;;
    *) fm_lock_release "$lock"; return 1 ;;
  esac
  tmp=$(mktemp "${marker}.tmp.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  if ! printf '%s\n' "$line" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$marker"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
}

_fm_recovery_marker_arm_check() {
  local marker=$1 lock line quarantine
  FM_RECOVERY_MARKER_ACTION='none'
  lock="${marker}.lock"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  if ! fm_lock_acquire_wait "$lock"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  fi
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    if [ -s "$FM_WAKE_QUEUE" ]; then
      if ! _fm_recovery_marker_write_locked "$marker" downtime "" announced; then
        fm_lock_release "$lock"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        return 1
      fi
      FM_RECOVERY_MARKER_ACTION='recover'
    fi
    fm_lock_release "$lock"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  if ! fm_recovery_marker_read "$marker"; then
    quarantine=$(mktemp -d "${marker}.invalid.XXXXXX") \
      || {
        fm_lock_release "$lock"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        return 1
      }
    if ! mv -- "$marker" "$quarantine/marker" \
      || ! _fm_recovery_marker_write_locked "$marker" downtime "" announced; then
      rmdir "$quarantine" 2>/dev/null || true
      fm_lock_release "$lock"
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
    fi
    FM_RECOVERY_MARKER_ACTION='recover'
    fm_lock_release "$lock"
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  line=$FM_RECOVERY_MARKER_TOKEN
  case "$line" in
    pending:handling:*|announced:handling:*|announced:downtime:*)
      FM_RECOVERY_MARKER_ACTION='wait'
      fm_lock_release "$lock"
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 0
      ;;
    pending:downtime:*)
      if ! _fm_recovery_marker_write_locked "$marker" downtime "${line##*:}" announced; then
        fm_lock_release "$lock"
        fm_lock_release "$FM_WAKE_QUEUE_LOCK"
        return 1
      fi
      FM_RECOVERY_MARKER_TOKEN="announced:downtime:${line##*:}"
      FM_RECOVERY_MARKER_ACTION='recover'
      ;;
    acked:*)
      if [ -s "$FM_WAKE_QUEUE" ]; then
        if ! _fm_recovery_marker_write_locked "$marker" downtime "" announced; then
          fm_lock_release "$lock"
          fm_lock_release "$FM_WAKE_QUEUE_LOCK"
          return 1
        fi
        # shellcheck disable=SC2034 # Output read by callers after this function returns.
        FM_RECOVERY_MARKER_ACTION='recover'
      fi
      ;;
  esac
  fm_lock_release "$lock"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

# A non-successor watcher start after an announced-but-unacked episode is a new
# down stretch: mint a fresh pending generation so a still-open decision or
# buried note can be presented once more. Handling successors must not call
# this, because Option B re-arm is not a new down stretch.
_fm_recovery_marker_reopen_announced() {
  local marker=$1 lock
  lock="${marker}.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if ! fm_recovery_marker_read "$marker"; then
    fm_lock_release "$lock"
    return 0
  fi
  case "$FM_RECOVERY_MARKER_TOKEN" in
    announced:*)
      if ! _fm_recovery_marker_write_locked "$marker" downtime ""; then
        fm_lock_release "$lock"
        return 1
      fi
      ;;
  esac
  fm_lock_release "$lock"
}

fm_recovery_transition() {
  local marker=$1 action=$2 target=${3:-} value=${4:-}
  case "$action" in
    publish)
      _fm_recovery_marker_publish "$marker" "${target:-downtime}"
      ;;
    acknowledge)
      _fm_recovery_marker_ack "$marker" "$target"
      ;;
    arm-check)
      _fm_recovery_marker_arm_check "$marker"
      ;;
    reopen-announced)
      _fm_recovery_marker_reopen_announced "$marker"
      ;;
    release-lock)
      [ -n "$target" ] || return 1
      _fm_recovery_marker_publish "$marker" "${value:-downtime}" || return 1
      fm_lock_release "$target"
      ;;
    release-lock-existing)
      [ -n "$target" ] || return 1
      local lock="${marker}.lock" reentered
      _fm_recovery_lock_acquire "$lock" || return 1
      reentered=$FM_RECOVERY_LOCK_REENTERED
      if ! fm_recovery_marker_read "$marker"; then
        _fm_recovery_lock_release "$lock" "$reentered"
        return 1
      fi
      fm_lock_release "$target"
      _fm_recovery_lock_release "$lock" "$reentered"
      ;;
    clear-stale-lock)
      [ -n "$target" ] || return 1
      _fm_recovery_marker_publish "$marker" "${value:-downtime}" || return 1
      fm_lock_remove_path "$target"
      ;;
    *) return 2 ;;
  esac
}

fm_recovery_marker_publish() {
  fm_recovery_transition "$1" publish "${2:-downtime}"
}

fm_recovery_marker_ack() {
  fm_recovery_transition "$1" acknowledge "$2"
}

fm_recovery_marker_begin_handling() {
  _fm_recovery_marker_begin_handling "$1" "${2:-}"
}

fm_recovery_marker_arm_check() {
  fm_recovery_transition "$1" arm-check
}

fm_recovery_marker_reopen_announced() {
  fm_recovery_transition "$1" reopen-announced
}

fm_lock_try_acquire() {
  local lockdir=$1 pid steal cur rc steal_owner primary_owner
  FM_LOCK_HELD_PID=
  FM_LOCK_OWNER_DIR=
  FM_LOCK_RECOVERED_PID=

  if fm_lock_try_create "$lockdir"; then
    return 0
  fi

  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi

  steal="$lockdir.steal"
  if ! fm_lock_try_acquire "$steal"; then
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  steal_owner=${FM_LOCK_OWNER_DIR:-}

  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if fm_lock_mid_acquire_is_fresh "$lockdir" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  if ! fm_lock_points_to_owner "$steal" "$steal_owner"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  primary_owner=
  if [ -L "$lockdir" ]; then
    primary_owner=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
  fi
  cur=$(cat "$lockdir/pid" 2>/dev/null || true)
  if ! fm_lock_recheck_stale_owner "$lockdir" "$primary_owner" "$cur"; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
    return 1
  fi

  if [ "$lockdir" = "$STATE/.watch.lock" ] \
    && ! _fm_recovery_marker_publish "$STATE/.watcher-down" downtime; then
    fm_lock_release "$steal"
    FM_LOCK_HELD_PID=$cur
    FM_LOCK_OWNER_DIR=
    return 1
  fi
  fm_lock_remove_path "$lockdir" || true
  rc=1
  if fm_lock_try_create "$lockdir" "$steal_owner"; then
    rc=0
    # shellcheck disable=SC2034 # Read by sourcing callers after lock acquisition.
    FM_LOCK_RECOVERED_PID=$cur
  fi
  if [ "$rc" -ne 0 ]; then
    # shellcheck disable=SC2034 # Read by callers after fm_lock_try_acquire returns.
    FM_LOCK_HELD_PID=$(cat "$lockdir/pid" 2>/dev/null || true)
    FM_LOCK_OWNER_DIR=
  fi
  fm_lock_release "$steal"
  return "$rc"
}

fm_lock_acquire_wait() {
  local lockdir=$1
  while ! fm_lock_try_acquire "$lockdir"; do
    sleep 0.1
  done
}

fm_lock_release() {
  local lockdir=$1 pid current ownerdir
  current=${BASHPID:-$$}
  if [ -L "$lockdir" ]; then
    ownerdir=$(fm_lock_link_owner "$lockdir" 2>/dev/null || true)
    [ -n "$ownerdir" ] || return 0
    pid=$(cat "$ownerdir/pid" 2>/dev/null || true)
    [ "$pid" = "$current" ] || return 0
    fm_lock_points_to_owner "$lockdir" "$ownerdir" || return 0
    rm -f "$lockdir" 2>/dev/null || return 0
    fm_lock_discard_owner "$ownerdir"
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "$current" ] || return 0
  fm_lock_clean_known_files "$lockdir"
  rmdir "$lockdir" 2>/dev/null || true
}

fm_meta_lock_path() {  # <state-dir>/<task-id>.meta
  local meta=$1 dir base id
  dir=${meta%/*}
  base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  case "$base" in
    *.meta) id=${base%.meta} ;;
    *) return 1 ;;
  esac
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s/.meta-%s.lock\n' "$dir" "$id"
}

fm_failure_episode_reset() {
  local state=$1 mode=${2:-acquire} lock current pid acquired=0 path
  lock="$state/.turnend-claude-blocks.lock"
  case "$mode" in
    acquire)
      fm_lock_try_acquire "$lock" || return 1
      acquired=1
      ;;
    held)
      current=${BASHPID:-$$}
      pid=$(cat "$lock/pid" 2>/dev/null || true)
      [ "$pid" = "$current" ] || return 1
      ;;
    *) return 1 ;;
  esac
  for path in \
    "$state/.turnend-claude-blocks" \
    "$state/.claude-autoarm-failure-notified" \
    "$state/.claude-autoarm-failure-alarmed"
  do
    if [ -d "$path" ] && [ ! -L "$path" ]; then
      [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
      return 1
    fi
  done
  if ! rm -f \
    "$state/.turnend-claude-blocks" \
    "$state/.claude-autoarm-failure-notified" \
    "$state/.claude-autoarm-failure-alarmed" \
    2>/dev/null; then
    [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
    return 1
  fi
  [ "$acquired" -eq 0 ] || fm_lock_release "$lock"
  return 0
}

# --- Claude Stop auto-arm generation claims -----------------------------------
# Both Stop-event participants (bin/fm-claude-stop-autoarm.sh and
# bin/fm-turnend-guard.sh --claude) coordinate through the epoch ledger
# state/.claude-autoarm-epoch, whose monotonic epoch sequence IS the claim
# generation. This is an optimistic, generation-based single-flight design:
#
#   - The CURRENT claim is the ledger's latest entry: line 1 is the classic
#     "epoch=N owner_pid=P outcome=O updated_at=T" record, and line 2 is the
#     claiming process's pid-identity, the same identity every other
#     supervision lock in this repo records (fm_pid_identity above). The
#     identity is MANDATORY: a claimant that cannot record it does not claim
#     (continuity falls to the synchronous guard), and the identity is read
#     from the ledger entry alone - never substituted from any lock - so a
#     reused pid can never authenticate someone else's stale entry.
#   - A claim is OPEN (fm_autoarm_claim_open) while its outcome is "arming",
#     its owner pid is alive, its recorded identity successfully recomputes
#     and matches that pid, and it is not STUCK - stuck meaning both the
#     ledger entry and the watcher beacon (state/.last-watcher-beat) are older
#     than the guard grace, which proves the owner hung mid-arm with nothing
#     supervising (every legitimate arming phase with no watcher is bounded in
#     seconds, while a healthy hours-long cycle keeps the beacon beating).
#   - Every firing DEFERS (exits 0) to an open claim; anything else - a
#     terminal outcome, a dead or identity-mismatched owner, a stuck owner, an
#     identityless entry, or no claim at all - lets the next firing take
#     generation N+1 (fm_autoarm_claim_next). Taking a newer generation IS the
#     reclaim: a steady-state predecessor is never signalled or revoked.
#   - NO mutex is ever held across a blocking step. The owner lock
#     state/.claude-autoarm.lock survives only as a micro-mutex serializing
#     individual ledger reads-then-writes (a few non-blocking file
#     operations); a holder that dies inside the hold is reclaimed by
#     fm_lock_try_acquire's ordinary dead-owner steal.
#   - A superseded owner goes COMPLETELY silent - cleanup only. Ownership is
#     re-verified before every side effect: each arm invocation, each
#     episode-state mutation, each ledger write, and each continuation.
#   - The irrevocable commit point of a translation is the EXIT STATUS: the
#     harness delivers the collected stderr banner only on exit 2 and discards
#     it on exit 0, so the owned terminal ledger write is the atomic commit -
#     when it succeeds the owner exits 2 unconditionally, and when it is
#     refused (superseded) the owner exits 0 silently even after printing.
#     The once-per-episode failure notice commits in the same owned critical
#     section as the winning "failed" write, so the notice can never be
#     consumed by a generation whose delivery lost.
#
# This structurally removes the failure classes the lock-held-across-arm
# design produced: a hung owner deferring every later firing forever (observed
# 2026-08-26: a hook hung mid-arm with its ledger frozen at "arming" kept the
# watcher from ever being auto-re-armed again; and 2026-08-14: a finished
# claim whose leftover lock silenced both participants for 40 beacon-less
# minutes), a reclaim mutex held across a blocking banner write recreating the
# same unreclaimable-live-owner shape, and a reclaimed-but-alive owner racing
# its replacement to translate one close twice.
#
# Two bounded residuals are ACCEPTED INTENT, because closing them absolutely
# would require a mutex held across output or steady-state revocation, both
# deliberately rejected: (1) an owner that dies between its owned terminal
# write and its own process exit leaves a committed outcome whose banner was
# never delivered (process-death territory; the durable wake queue retains the
# underlying event), and (2) a hung old-build owner that resumes during the
# one legacy upgrade window may add one duplicate continuation. Each residual
# costs at most one extra exit-2 continuation turn absorbed by the durable
# idempotent wake queue. A claim misread as stuck in a pathological race
# (e.g. a beacon read right at system wake) likewise yields at most one extra
# arm that the watcher singleton dedupes, while the superseded owner still
# goes silent.
#
# fm_autoarm_claim_abandoned / fm_autoarm_release_abandoned below survive as
# the LEGACY shim for a lock-holding claim from a pre-generation build (the
# lock carries a role file only in that legacy shape, and in the guard's own
# short terminal-check hold): a live legacy owner still defers per the legacy
# proof, and a proven-abandoned one is reclaimed once through the steal mutex
# - with an identity-verified live owner retired via TERM first, because old
# code cannot re-check generations - so an upgrade mid-session can neither
# double-arm nor deadlock behind a hung legacy hook.
_fm_autoarm_epoch_field() {  # <epoch-file> <field>
  local file=$1 field=$2 tok
  local -a toks=()
  [ -r "$file" ] || return 1
  # 2> before <: a failed input redirection reports through whatever stderr is
  # current when it runs, so the suppression has to be established first.
  IFS=' ' read -r -a toks 2>/dev/null < "$file" || return 1
  for tok in ${toks[@]+"${toks[@]}"}; do
    case "$tok" in
      "$field="?*) printf '%s\n' "${tok#*=}"; return 0 ;;
    esac
  done
  return 1
}

# Parse the current ledger claim. Sets FM_AUTOARM_GEN, FM_AUTOARM_OWNER,
# FM_AUTOARM_OUTCOME, and FM_AUTOARM_IDENTITY (line 2 of the entry, and ONLY
# line 2 - identity is never substituted from a lock, so a transient
# micro-mutex hold or a reused pid can never authenticate a stale entry).
fm_autoarm_ledger_read() {  # <state-dir>
  local state=$1 epoch
  epoch="$state/.claude-autoarm-epoch"
  FM_AUTOARM_GEN=
  FM_AUTOARM_OWNER=
  FM_AUTOARM_OUTCOME=
  FM_AUTOARM_IDENTITY=
  FM_AUTOARM_GEN=$(_fm_autoarm_epoch_field "$epoch" epoch) || return 1
  FM_AUTOARM_OWNER=$(_fm_autoarm_epoch_field "$epoch" owner_pid) || return 1
  FM_AUTOARM_OUTCOME=$(_fm_autoarm_epoch_field "$epoch" outcome) || return 1
  case "$FM_AUTOARM_GEN" in
    ''|*[!0-9]*) return 1 ;;
  esac
  FM_AUTOARM_IDENTITY=$(sed -n '2p' "$epoch" 2>/dev/null || true)
  return 0
}

# True while the CURRENT ledger claim is open and healthy - the defer predicate
# both Stop participants use. Open means: outcome "arming", a live owner whose
# mandatory recorded identity recomputes and matches its pid, and not stuck
# (the contract comment above owns the stuck proof). fm_path_age reports an
# absent beacon as ancient, which is exactly right: arming for a full grace
# window without producing a first beat is the same hang. An identityless
# entry is never open: real generation claims always record identity, a legacy
# build's entry gets its deference from its held role-carrying lock through
# the legacy shim, and anything else must not defer.
fm_autoarm_claim_open() {  # <state-dir> [grace]
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} epoch current
  epoch="$state/.claude-autoarm-epoch"
  case "$grace" in
    ''|*[!0-9]*|0) grace=300 ;;
  esac
  fm_autoarm_ledger_read "$state" || return 1
  [ "$FM_AUTOARM_OUTCOME" = arming ] || return 1
  fm_pid_alive "$FM_AUTOARM_OWNER" || return 1
  [ -n "$FM_AUTOARM_IDENTITY" ] || return 1
  current=$(fm_pid_identity "$FM_AUTOARM_OWNER" 2>/dev/null) || return 1
  [ -n "$current" ] || return 1
  [ "$current" = "$FM_AUTOARM_IDENTITY" ] || return 1
  if [ "$(fm_path_age "$epoch")" -ge "$grace" ] \
    && [ "$(fm_path_age "$state/.last-watcher-beat")" -ge "$grace" ]; then
    return 1
  fi
  return 0
}

# Atomically publish this process as the owner of generation N+1, under one
# short micro-mutex hold. Returns 0 with FM_AUTOARM_MY_GEN set on success, 2
# when a competing claimant won the race (the ledger holds an open claim), and
# 1 when the micro-mutex is contended, the mandatory identity cannot be
# computed, or the write failed.
fm_autoarm_claim_next() {  # <state-dir> [grace]
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} lock epoch pid gen identity tmp
  lock="$state/.claude-autoarm.lock"
  epoch="$state/.claude-autoarm-epoch"
  FM_AUTOARM_MY_GEN=
  # Resolve the pid into a variable FIRST: expanding ${BASHPID:-$$} inside a
  # command substitution would resolve it in that subshell, recording the
  # identity of a process that exits immediately.
  pid=${BASHPID:-$$}
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  fm_lock_try_acquire "$lock" || return 1
  if fm_autoarm_claim_open "$state" "$grace"; then
    fm_lock_release "$lock"
    return 2
  fi
  gen=$(_fm_autoarm_epoch_field "$epoch" epoch 2>/dev/null || true)
  case "$gen" in
    ''|*[!0-9]*) gen=0 ;;
  esac
  gen=$((gen + 1))
  tmp="$epoch.tmp.$pid"
  if ! printf 'epoch=%s owner_pid=%s outcome=arming updated_at=%s\n%s\n' \
      "$gen" "$pid" "$(date +%s)" "$identity" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$epoch" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$lock"
    return 1
  fi
  fm_lock_release "$lock"
  # shellcheck disable=SC2034 # Read by callers after the claim succeeds.
  FM_AUTOARM_MY_GEN=$gen
  return 0
}

# Write a new outcome for a generation this process still owns, re-verified
# under the micro-mutex so a superseded owner can never clobber a newer claim.
# With a fourth argument, atomically create that marker file in the same owned
# critical section as the write (the once-per-episode failure notice), so the
# marker can only ever be consumed by the generation whose translation wins.
# Returns 0 written, 2 superseded, 1 unable (bounded contention or write
# failure).
fm_autoarm_write_owned() {  # <state-dir> <gen> <outcome> [marker-file]
  local state=$1 gen=$2 outcome=$3 marker=${4:-} lock epoch pid identity tmp i
  lock="$state/.claude-autoarm.lock"
  epoch="$state/.claude-autoarm-epoch"
  pid=${BASHPID:-$$}
  i=0
  while ! fm_lock_try_acquire "$lock"; do
    [ "$i" -lt 20 ] || return 1
    sleep 0.02
    i=$((i + 1))
  done
  if ! fm_autoarm_ledger_read "$state" \
    || [ "$FM_AUTOARM_GEN" != "$gen" ] || [ "$FM_AUTOARM_OWNER" != "$pid" ]; then
    fm_lock_release "$lock"
    return 2
  fi
  identity=$FM_AUTOARM_IDENTITY
  tmp="$epoch.tmp.$pid"
  if ! {
      printf 'epoch=%s owner_pid=%s outcome=%s updated_at=%s\n' \
        "$gen" "$pid" "$outcome" "$(date +%s)"
      [ -z "$identity" ] || printf '%s\n' "$identity"
    } > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$epoch" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$lock"
    return 1
  fi
  if [ -n "$marker" ]; then
    : > "$marker" 2>/dev/null || true
  fi
  fm_lock_release "$lock"
  return 0
}

# Lockless pre-side-effect ownership check: true while the ledger still names
# <gen> owned by this process. A superseded owner must go silent instead of
# arming, mutating shared state, or emitting.
fm_autoarm_still_owner() {  # <state-dir> <gen>
  local state=$1 gen=$2 pid
  pid=${BASHPID:-$$}
  fm_autoarm_ledger_read "$state" || return 1
  [ "$FM_AUTOARM_GEN" = "$gen" ] && [ "$FM_AUTOARM_OWNER" = "$pid" ]
}

# LEGACY shim (see the contract comment above): the abandonment proof for a
# lock-holding claim from a pre-generation build, recognizable by the role
# file only such claims and the guard's short terminal-check hold publish.
# A live legacy owner defers per this proof; a finished, identity-mismatched,
# or stuck one is abandoned:
#
#   1. the owner lock exists and carries the auto-arm role,
#   2. its recorded pid is numeric,
#   3. a recorded pid-identity that no longer matches the live pid is
#      abandonment on its own (pid reuse after a group kill), and otherwise
#   4. the ledger's owner_pid is exactly that pid and its outcome is present
#      and either is not "arming", or is "arming" while both the ledger entry
#      and the watcher beacon are older than the guard grace (the same stuck
#      proof as fm_autoarm_claim_open).
fm_autoarm_claim_abandoned() {  # <state-dir> [grace]
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} epoch lock role pid owner outcome recorded current
  lock="$state/.claude-autoarm.lock"
  epoch="$state/.claude-autoarm-epoch"
  case "$grace" in
    ''|*[!0-9]*|0) grace=300 ;;
  esac
  [ -e "$lock" ] || [ -L "$lock" ] || return 1
  role=$(fm_lock_role "$lock")
  [ "$role" = autoarm ] || return 1
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  recorded=$(cat "$lock/pid-identity" 2>/dev/null || true)
  if [ -n "$recorded" ] && current=$(fm_pid_identity "$pid" 2>/dev/null) \
    && [ -n "$current" ] && [ "$current" != "$recorded" ]; then
    return 0
  fi
  owner=$(_fm_autoarm_epoch_field "$epoch" owner_pid) || return 1
  [ "$owner" = "$pid" ] || return 1
  outcome=$(_fm_autoarm_epoch_field "$epoch" outcome) || return 1
  case "$outcome" in
    '') return 1 ;;
    arming)
      [ "$(fm_path_age "$epoch")" -ge "$grace" ] || return 1
      [ "$(fm_path_age "$state/.last-watcher-beat")" -ge "$grace" ] || return 1
      return 0
      ;;
  esac
  return 0
}

# Remove a proven-abandoned legacy claim so the next claimant can arm. The
# proof is re-verified while holding the lock's steal mutex, the same
# serialization fm_lock_try_acquire uses for stale-owner reclaim: while it is
# held no other process can publish the primary lock, so the window between
# proving abandonment and removing the lock cannot swallow a genuine new
# claim.
#
# Old-build code cannot re-check generations, so a LIVE proven-abandoned
# legacy owner whose recorded identity is verified to match its pid is retired
# with TERM before the lock is removed: once the TERM is successfully queued
# the process can never resume normal execution (delivery precedes any further
# user code when it continues), so a short bounded wait for observed exit is a
# courtesy, not a requirement. A pid is never signalled without a verified
# matching identity; when the kill itself fails or the identity stops matching
# mid-procedure (pid reuse), the reclaim refuses. Missing identity evidence
# never blocks the reclaim of a proven-abandoned claim - it only disables the
# TERM and the ledger graft below, keeping the documented bounded
# upgrade-window residual instead of the deadlock.
fm_autoarm_release_abandoned() {  # <state-dir> [grace]
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} lock steal epoch lock_pid recorded current owner line1 tmp i
  lock="$state/.claude-autoarm.lock"
  steal="$lock.steal"
  epoch="$state/.claude-autoarm-epoch"
  fm_autoarm_claim_abandoned "$state" "$grace" || return 1
  fm_lock_try_acquire "$steal" || return 1
  if ! fm_autoarm_claim_abandoned "$state" "$grace"; then
    fm_lock_release "$steal"
    return 1
  fi
  lock_pid=$(cat "$lock/pid" 2>/dev/null || true)
  recorded=$(cat "$lock/pid-identity" 2>/dev/null || true)
  if [ -n "$recorded" ] && fm_pid_alive "$lock_pid" \
    && current=$(fm_pid_identity "$lock_pid" 2>/dev/null) \
    && [ -n "$current" ] && [ "$current" = "$recorded" ]; then
    # A live pid still answering to the recorded identity IS the genuine
    # legacy owner (proven stuck or blocked after a terminal write): retire it
    # before removing its lock, because old-build code cannot re-check
    # generations. A pid the recorded identity does NOT verify - reused,
    # unverifiable, or never recorded - is NEVER signalled; those shapes are
    # reclaimed as-is, which is safe exactly because the recorded owner is
    # gone or was never provably this process.
    if ! kill -TERM "$lock_pid" 2>/dev/null; then
      fm_lock_release "$steal"
      return 1
    fi
    i=0
    while [ "$i" -lt 20 ] && fm_pid_alive "$lock_pid"; do
      sleep 0.05
      i=$((i + 1))
    done
  fi
  # Preserve the legacy lock's identity evidence in the ledger before the lock
  # disappears, keeping the ledger's original mtime so the stuck proof's age
  # window is not silently reopened. Best effort.
  if [ -n "$recorded" ] && [ -n "$lock_pid" ] \
    && owner=$(_fm_autoarm_epoch_field "$epoch" owner_pid 2>/dev/null) \
    && [ "$owner" = "$lock_pid" ] \
    && [ -z "$(sed -n '2p' "$epoch" 2>/dev/null)" ]; then
    line1=$(sed -n '1p' "$epoch" 2>/dev/null || true)
    tmp="$epoch.tmp.${BASHPID:-$$}"
    if [ -n "$line1" ] \
      && printf '%s\n%s\n' "$line1" "$recorded" > "$tmp" 2>/dev/null \
      && touch -r "$epoch" "$tmp" 2>/dev/null \
      && mv -f "$tmp" "$epoch" 2>/dev/null; then
      :
    fi
    rm -f "$tmp" 2>/dev/null || true
  fi
  fm_lock_remove_path "$lock" || true
  fm_lock_release "$steal"
  [ -e "$lock" ] || [ -L "$lock" ] || return 0
  return 1
}

fm_wake_clean_field() {
  LC_ALL=C tr '\t\r\n' '   '
}

fm_wake_append() {
  local kind=$1 key=$2 payload=$3 lock_attempts=${4:-} clean_key clean_payload epoch seq seq_file status attempt=0
  local recovery_marker
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_append: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac

  clean_key=$(printf '%s' "$key" | fm_wake_clean_field)
  clean_payload=$(printf '%s' "$payload" | fm_wake_clean_field)
  epoch=$(date +%s)
  seq_file="$STATE/.wake-queue.seq"
  recovery_marker="$STATE/.watcher-down"
  status=0

  if [ -n "$lock_attempts" ]; then
    case "$lock_attempts" in ''|*[!0-9]*|0) return 2 ;; esac
    while ! fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK"; do
      attempt=$((attempt + 1))
      [ "$attempt" -lt "$lock_attempts" ] || return 3
      sleep 0.05
    done
  else
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  fi
  # Recovery evidence is published BEFORE the durable row commits, so a crash in
  # this window leaves the wake recoverable rather than silently orphaned. The
  # bounded caller keeps its whole-call bound: the marker lock is bounded too,
  # and an exhausted attempt budget returns 3 exactly like the queue lock does.
  _fm_recovery_marker_publish "$recovery_marker" downtime "$lock_attempts" || status=$?
  if [ "$status" -eq 0 ]; then
    seq=$(cat "$seq_file" 2>/dev/null || echo 0)
    case "$seq" in
      ''|*[!0-9]*) seq=0 ;;
    esac
    seq=$((seq + 1))
    printf '%s\n' "$seq" > "$seq_file" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$seq" "$kind" "$clean_key" "$clean_payload" >> "$FM_WAKE_QUEUE" || status=$?
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

# fm_wake_queued_keys <kind>
# Print the distinct keys currently queued for <kind>, oldest first. Read under
# the append lock so a concurrent append is never observed half-written. The
# durable queue stays the authority: a key appears here exactly while a record
# for it is queued and unacknowledged, and disappears only after post-handling
# acknowledgement consumes it.
fm_wake_queued_keys() {
  local kind=$1
  case "$kind" in
    signal|stale|check|heartbeat) ;;
    *) printf 'fm_wake_queued_keys: invalid wake kind: %s\n' "$kind" >&2; return 2 ;;
  esac
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  fm_wake_queued_keys_locked "$kind"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
}

fm_wake_queued_keys_locked() {
  local kind=$1
  awk -F '\t' -v kind="$kind" 'NF >= 5 && $3 == kind && !seen[$4]++ { print $4 }' \
    "$FM_WAKE_QUEUE" 2>/dev/null || true
}

fm_wake_restore_queue() {
  local drained=$1 restore
  restore="$STATE/.wake-queue.restore.$(fm_current_pid)"
  if [ -e "$FM_WAKE_QUEUE" ]; then
    cat "$drained" "$FM_WAKE_QUEUE" > "$restore" && mv "$restore" "$FM_WAKE_QUEUE"
  else
    mv "$drained" "$FM_WAKE_QUEUE"
  fi
}

fm_wake_print_deduped() {
  local file=$1
  awk -F '\t' '
    NF >= 5 {
      dedupe = $3 SUBSEP $4
      if ($3 == "heartbeat") {
        dedupe = "heartbeat"
      }
      if (!(dedupe in seen)) {
        order[++count] = dedupe
        seen[dedupe] = 1
      }
      line[dedupe] = $0
    }
    END {
      for (i = 1; i <= count; i++) {
        print line[order[i]]
      }
    }
  ' "$file"
}

# Map one structurally valid signal key to its home-local status filename.
# Queue payload text is intentionally ignored: it is display data, not a path
# authority. The caller still verifies the resulting regular file immediately
# before its bounded read.
FM_WAKE_STATUS_KEY=
FM_WAKE_STATUS_HISTORICAL=false
fm_wake_status_key_map() {  # <queue-key>
  local key=$1 id
  FM_WAKE_STATUS_KEY=
  FM_WAKE_STATUS_HISTORICAL=false
  case "$key" in
    *.status)
      id=${key%.status}
      ;;
    *.turn-ended)
      id=${key%.turn-ended}
      FM_WAKE_STATUS_HISTORICAL=true
      ;;
    *)
      return 1
      ;;
  esac
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ] || return 1
  FM_WAKE_STATUS_KEY="$id.status"
}

fm_wake_annotation_manifest() {  # <deduped-raw-rows>
  local rows=$1 epoch seq kind key payload
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = signal ] || continue
    fm_wake_status_key_map "$key" || continue
    if [ "$FM_WAKE_STATUS_HISTORICAL" = true ]; then
      printf '%s\thistorical\n' "$FM_WAKE_STATUS_KEY"
    else
      printf '%s\tdirect\n' "$FM_WAKE_STATUS_KEY"
    fi
  done <<EOF
$rows
EOF
}

FM_WAKE_EVENT_LINE=
FM_WAKE_UNREAD_LINES=
fm_wake_status_cursor_offset() {  # <validated-status-path> -> already-presented byte offset
  local path=$1 offset
  command -v status_presentation_cursor_offset >/dev/null 2>&1 || return 1
  offset=$(status_presentation_cursor_offset "$path" 2>/dev/null) || return 1
  case "$offset" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$offset"
}

# O_NOFOLLOW read of every still-unread status byte. min-offset is the
# already-presented cursor from classify-lib. Lines whose bytes begin before
# that offset are not replayed. Prints nothing and returns 1 when no unread
# non-blank line exists.
fm_wake_unread_events() {  # <validated-status-path> <unused-tail-byte-cap> <min-offset> [<end-offset>]
  local path=$1 min_offset=$3 end_offset=${4:-} result size chunk chunk_start
  local LC_ALL=C
  FM_WAKE_EVENT_LINE=
  FM_WAKE_UNREAD_LINES=
  case "$min_offset" in ''|*[!0-9]*) min_offset=0 ;; esac
  result=$(perl -MFcntl=:DEFAULT -e '
    my ($path, $start, $end) = @ARGV;
    sysopen(my $file, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    my @stat = stat $file or exit 1;
    exit 1 unless -f _;
    my $size = $stat[7];
    exit 1 unless $size =~ /\A\d+\z/ && $start =~ /\A\d+\z/ && $start <= $size;
    $end = $size unless length $end;
    exit 1 unless $end =~ /\A\d+\z/ && $start <= $end && $end <= $size;
    seek($file, $start, 0) or exit 1;
    printf "%s\t", $end or exit 1;
    my $remaining = $end - $start;
    while ($remaining > 0) {
      my $read = read($file, my $buffer, $remaining);
      exit 1 unless defined $read;
      last unless $read;
      print $buffer or exit 1;
      $remaining -= $read;
    }
  ' "$path" "$min_offset" "$end_offset" 2>/dev/null) || return 1
  size=${result%%$'\t'*}
  chunk=${result#*$'\t'}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$chunk" ] || return 1
  [ "$min_offset" -lt "$size" ] || return 1
  chunk_start=$min_offset
  FM_WAKE_UNREAD_LINES=$(printf '%s' "$chunk" | LC_ALL=C awk -v start="$chunk_start" -v min="$min_offset" '
    BEGIN { pos = start + 0 }
    {
      line_start = pos
      pos += length($0) + 1
      if ($0 ~ /[^[:space:]]/ && line_start >= min) print $0
    }
  ') || return 1
  [ -n "$FM_WAKE_UNREAD_LINES" ] || return 1
  FM_WAKE_EVENT_LINE=$(printf '%s\n' "$FM_WAKE_UNREAD_LINES" | tail -1)
  FM_WAKE_EVENT_LINE=$(printf '%s' "$FM_WAKE_EVENT_LINE" | LC_ALL=C tr '\t\r' '  ')
}

fm_wake_latest_event() {  # <validated-status-path> <tail-byte-cap>
  fm_wake_unread_events "$1" "$2" 0
}

# Print supplemental drain-time context only after the caller has committed the
# raw queue consumption and released the append lock.
fm_wake_print_annotations() {  # <deduped-raw-rows> [<presentation-snapshot>]
  local rows=$1 snapshot=${2:-} manifest status_key mode path prefix line task endpoint
  local snapshot_task snapshot_endpoint _snapshot_ident offset last_event event_line
  local LC_ALL=C

  manifest=$(fm_wake_annotation_manifest "$rows" | awk -F '\t' '
    {
      key = $1
      if (!(key in seen)) {
        order[++count] = key
        seen[key] = 1
        mode[key] = $2
      } else if ($2 == "direct") {
        mode[key] = "direct"
      }
    }
    END {
      for (i = 1; i <= count; i++) print order[i] "\t" mode[order[i]]
    }
  ') || return 0

  # Test-only latency seam for proving that queue appends remain independent of
  # a slow best-effort annotation phase.
  case "${FM_WAKE_ENRICH_TEST_DELAY:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$FM_WAKE_ENRICH_TEST_DELAY" ;;
  esac

  while IFS=$(printf '\t') read -r status_key mode; do
    [ -n "$status_key" ] || continue
    path="$STATE/$status_key"
    # Every signal row is annotated only for status bytes that remain unread at
    # the shared presentation cursor. Historical rows retain their caveat, and
    # already-presented bytes are not replayed.
    endpoint=
    if [ -n "$snapshot" ]; then
      task=${status_key%.status}
      while IFS=$(printf '\t') read -r snapshot_task snapshot_endpoint _snapshot_ident; do
        if [ "$snapshot_task" = "$task" ]; then endpoint=$snapshot_endpoint; break; fi
      done <<EOF
$snapshot
EOF
      [ -n "$endpoint" ] || continue
    fi
    offset=$(fm_wake_status_cursor_offset "$path") || return 1
    if [ -n "$endpoint" ] && [ "$offset" -ge "$endpoint" ]; then continue; fi
    if ! fm_wake_unread_events "$path" 0 "$offset" "$endpoint"; then
      # Annotation enrichment is supplemental to the already-printed durable
      # wake rows. A file that disappears, rotates, or becomes unreadable after
      # the snapshot must not suppress annotations for other status files; the
      # presentation commit will reject a changed snapshot identity.
      continue
    fi
    last_event=$FM_WAKE_EVENT_LINE
    while IFS= read -r event_line || [ -n "$event_line" ]; do
      [ -n "$event_line" ] || continue
      event_line=$(printf '%s' "$event_line" | LC_ALL=C tr '\t\r' '  ')
      prefix="wake annotation: latest wake-EVENT observed at drain, not current state"
      if [ "$event_line" != "$last_event" ]; then
        prefix="wake annotation: unread wake-EVENT since last drain, not current state"
      fi
      if [ "$mode" = historical ]; then
        prefix="$prefix; historical / not necessarily the triggering event"
      fi
      line="$prefix: $status_key: $event_line"
      printf '%s\n' "$line" || return 1
    done <<EOF
$FM_WAKE_UNREAD_LINES
EOF
  done <<EOF
$manifest
EOF

  return 0
}
