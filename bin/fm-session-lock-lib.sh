#!/usr/bin/env bash
# Usage: source bin/fm-session-lock-lib.sh, then call its fm_session_lock_* and fm_harness_* functions.
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known generic harness command names; exact OMP identity is delegated below.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'
FM_SESSION_LOCK_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-omp-process-lib.sh
. "$FM_SESSION_LOCK_LIB_DIR/fm-omp-process-lib.sh"

# A daemon broker hosts named bash calls for every OMP session in its scope.
# Its parent cannot identify the session that requested a command.
fm_omp_daemon_broker() {  # <comm> <args> <pid>
  local comm=$1 args=$2 pid=$3 field record=''
  local proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$comm:$args" in
    'omp daemon brok:'*|*'omp daemon broker'*|*__omp_worker_daemon_broker*) ;;
    *) return 1 ;;
  esac
  if [ -d "$proc_root" ]; then
    while IFS= read -r -d '' field; do
      case "$field" in
        OMP_DAEMON_RUNTIME_DIR=/*)
          record=${field#*=}/broker.pid
          break
          ;;
      esac
    done 2>/dev/null < "$proc_root/$pid/environ"
  else
    while IFS= read -r field; do
      case "$field" in
        n/*/broker.pid)
          record=${field#n}
          break
          ;;
      esac
    done < <(lsof -nP -a -p "$pid" -Fn 2>/dev/null)
  fi
  [ -f "$record" ] && [ "$(cat "$record" 2>/dev/null)" = "{\"pid\":$pid}" ]
}

# The same generic harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1, full argument string $2,
# and optional pid $3 is a verified harness.
# Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. exact launch-bound OMP process identity;
#   2. the basename of the reported command name, against FM_HARNESS_RE;
#   3. an exact generic-harness component in that command path or in argv[0].
#      Both are needed because the two platforms report different things:
#      macOS reports argv[0] in `ps -o comm=`, while procps on Linux reports the
#      kernel exec name and ignores argv[0] entirely, so a version-named Claude
#      Code binary is identified by its install path on macOS and by argv[0] on
#      Linux;
#   4. a bare interpreter (node, python) running a generic harness script path.
#
# An OMP daemon broker returns 2 so the ancestry walk can stop at it.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args> [pid]
  local comm=$1 args=$2 pid=${3:-} base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  fm_omp_daemon_broker "$comm" "$args" "$pid" && return 2
  if fm_omp_process_matches "$comm" "$args" "$pid"; then
    return 0
  fi
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
# Return 2 if an OMP daemon broker ends the walk before any session is found.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -ww -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args" "$pid"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
    else
      if [ "$?" -eq 2 ] && [ "$printed" -eq 0 ]; then
        return 2
      fi
      [ "$printed" -eq 0 ] || break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return "$?"
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -ww -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" "$pid" || return 1
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
