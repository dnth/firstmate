#!/usr/bin/env bash
# Usage: source bin/fm-omp-process-lib.sh; fm_omp_process_matches <comm-or-path> <args> [pid]
# Exact OMP process identity shared by primary ancestry and backend liveness probes.
# Bun may publish comm=omp as its process title, but argv must still begin with the
# launch-bound Bun executable and OMP entrypoint after canonical resolution.
# Callers supply those paths from task metadata; primary probes may use the loaded
# marker written by the running OMP extension and bound to the exact PID. A fresh
# PATH lookup is never identity evidence. When Linux exposes /proc/<pid>/exe, that
# executable must be the launch-bound Bun too. This file has no source side effects.

fm_omp_process_resolve_path() {  # <path-or-command>
  local value=$1 resolved
  [ -n "$value" ] || return 1
  case "$value" in
    /*) ;;
    *) value=$(command -v "$value" 2>/dev/null) || return 1 ;;
  esac
  if resolved=$(readlink -f "$value" 2>/dev/null) && [ -n "$resolved" ]; then
    printf '%s' "$resolved"
    return 0
  fi
  if command -v node >/dev/null 2>&1 \
     && resolved=$(node -e 'const { realpathSync } = require("node:fs"); process.stdout.write(realpathSync(process.argv[1]));' "$value" 2>/dev/null) \
     && [ -n "$resolved" ]; then
    printf '%s' "$resolved"
    return 0
  fi
  return 1
}

fm_omp_process_identity_path_valid() {  # <canonical-executable-path>
  local value=$1
  case "$value" in /*) ;; *) return 1 ;; esac
  # ps exposes one flattened command string on the portable tmux path, so
  # whitespace-bearing executable paths cannot retain provable argv boundaries.
  # Refuse them rather than guessing where either launch identity ends.
  case "$value" in *[[:space:]]*) return 1 ;; esac
  [ -x "$value" ] || return 1
  [ "$(fm_omp_process_resolve_path "$value" 2>/dev/null)" = "$value" ]
}

fm_omp_primary_marker_read() {  # <marker>; sets FM_OMP_MARKER_{VERSION,PID,BUN,BIN}
  local marker=$1
  FM_OMP_MARKER_VERSION=
  FM_OMP_MARKER_PID=
  FM_OMP_MARKER_BUN=
  FM_OMP_MARKER_BIN=
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(wc -l < "$marker" 2>/dev/null | tr -d '[:space:]')" = 4 ] \
    && [ "$(tail -c 1 "$marker" 2>/dev/null | od -An -tuC | tr -d '[:space:]')" = 10 ] || return 1
  FM_OMP_MARKER_VERSION=$(sed -n '1p' "$marker" 2>/dev/null)
  FM_OMP_MARKER_PID=$(sed -n '2p' "$marker" 2>/dev/null)
  FM_OMP_MARKER_BUN=$(sed -n '3p' "$marker" 2>/dev/null)
  FM_OMP_MARKER_BIN=$(sed -n '4p' "$marker" 2>/dev/null)
  [ -n "$FM_OMP_MARKER_VERSION" ] || return 1
  case "$FM_OMP_MARKER_PID" in ''|*[!0-9]*) return 1 ;; esac
  fm_omp_process_identity_path_valid "$FM_OMP_MARKER_BUN" \
    && fm_omp_process_identity_path_valid "$FM_OMP_MARKER_BIN"
}

fm_omp_process_primary_marker_path() {
  local lib_dir root state
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  root=$(cd "$lib_dir/.." && pwd -P) || return 1
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$root}/state}
  printf '%s' "$state/.omp-primary-extension-loaded"
}

# True when this home can produce OMP identity evidence at all: either the
# caller supplied both expected launch paths, or a primary marker file exists.
# Without one of those, fm_omp_process_matches can never match, so ancestry
# probes may skip their process walk entirely.
fm_omp_process_identity_available() {
  local marker
  [ -n "${FM_OMP_PROCESS_EXPECTED_BUN:-}" ] && [ -n "${FM_OMP_PROCESS_EXPECTED_BIN:-}" ] && return 0
  marker=$(fm_omp_process_primary_marker_path) || return 1
  [ -f "$marker" ]
}

fm_omp_process_primary_identity() {  # <pid> -> <bun-realpath> newline <omp-realpath>
  local pid=$1 marker
  marker=$(fm_omp_process_primary_marker_path) || return 1
  fm_omp_primary_marker_read "$marker" || return 1
  [ "$FM_OMP_MARKER_PID" = "$pid" ] || return 1
  printf '%s\n%s\n' "$FM_OMP_MARKER_BUN" "$FM_OMP_MARKER_BIN"
}

fm_omp_process_executable() {  # <pid>
  local pid=$1 path
  if [ -e "/proc/$pid/exe" ]; then
    fm_omp_process_resolve_path "/proc/$pid/exe"
    return
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  path=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  [ -n "$path" ] || return 1
  fm_omp_process_resolve_path "$path"
}

fm_omp_process_matches() {  # <comm-or-path> <args> [pid]
  local comm=$1 args=$2 pid=${3:-} first second rest marker_identity
  local expected_bun=${FM_OMP_PROCESS_EXPECTED_BUN:-} expected_omp=${FM_OMP_PROCESS_EXPECTED_BIN:-}
  local actual_bun actual_omp process_exe
  comm=$(basename -- "$comm")
  case "$comm" in bun|omp) ;; *) return 1 ;; esac
  read -r first second rest <<EOF
$args
EOF
  [ -n "${first:-}" ] && [ -n "${second:-}" ] || return 1
  if { [ -z "$expected_bun" ] || [ -z "$expected_omp" ]; } && [ -n "$pid" ]; then
    marker_identity=$(fm_omp_process_primary_identity "$pid") || return 1
    expected_bun=$(printf '%s\n' "$marker_identity" | sed -n '1p')
    expected_omp=$(printf '%s\n' "$marker_identity" | sed -n '2p')
  fi
  [ -n "$expected_bun" ] && [ -n "$expected_omp" ] || return 1
  expected_bun=$(fm_omp_process_resolve_path "$expected_bun") || return 1
  expected_omp=$(fm_omp_process_resolve_path "$expected_omp") || return 1
  fm_omp_process_identity_path_valid "$expected_bun" \
    && fm_omp_process_identity_path_valid "$expected_omp" || return 1
  case "$second" in /*) ;; *) return 1 ;; esac
  actual_omp=$(fm_omp_process_resolve_path "$second") || return 1
  [ "$actual_omp" = "$expected_omp" ] || return 1
  case "$first" in
    /*)
      actual_bun=$(fm_omp_process_resolve_path "$first") || return 1
      [ "$actual_bun" = "$expected_bun" ] || return 1
      ;;
    *)
      [ -n "$pid" ] && [ "$first" = "$(basename "$expected_bun")" ] || return 1
      ;;
  esac
  if [ -n "$pid" ]; then
    process_exe=$(fm_omp_process_executable "$pid") || return 1
    [ "$process_exe" = "$expected_bun" ] || return 1
  fi
}

# Remove OMP runtime markers from a recycled home only after proving that the
# previous session lock and primary marker owners are absent.
fm_omp_clear_stale_runtime_markers() { # <home>
  local home=$1 state lock_pid marker marker_pid session_dir session
  state="$home/state"
  [ -e "$state" ] || return 0
  [ -d "$state" ] && [ ! -L "$state" ] || {
    printf 'error: OMP runtime state is not an ordinary directory: %s\n' "$state" >&2
    return 1
  }

  if [ -e "$state/.lock" ] || [ -L "$state/.lock" ]; then
    [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || {
      printf 'error: cannot verify the previous OMP session lock at %s\n' "$state/.lock" >&2
      return 1
    }
    lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
    case "$lock_pid" in
      ''|*[!0-9]*|0*|1)
        printf 'error: previous OMP session lock at %s has an unverifiable PID\n' "$state/.lock" >&2
        return 1
        ;;
      *)
        if kill -0 "$lock_pid" 2>/dev/null; then
          printf 'error: previous OMP session is still live (PID %s); preserving runtime markers in %s\n' "$lock_pid" "$state" >&2
          return 1
        fi
        ;;
    esac
  fi

  marker="$state/.omp-primary-extension-loaded"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || {
      printf 'error: cannot verify the previous OMP primary marker at %s\n' "$marker" >&2
      return 1
    }
    marker_pid=$(sed -n '2p' "$marker" 2>/dev/null || true)
    case "$marker_pid" in
      ''|*[!0-9]*|0*|1)
        printf 'error: previous OMP primary marker at %s has an unverifiable PID\n' "$marker" >&2
        return 1
        ;;
      *)
        if kill -0 "$marker_pid" 2>/dev/null; then
          printf 'error: previous OMP primary marker owner is still live (PID %s); preserving runtime markers in %s\n' "$marker_pid" "$state" >&2
          return 1
        fi
        ;;
    esac
  fi

  for marker in "$state"/.omp-*; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    [ -f "$marker" ] && [ ! -L "$marker" ] || {
      printf 'error: refusing to remove non-file OMP runtime marker %s\n' "$marker" >&2
      return 1
    }
  done
  session_dir="$state/omp-sessions"
  if [ -e "$session_dir" ] || [ -L "$session_dir" ]; then
    [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || {
      printf 'error: OMP session directory is not an ordinary directory: %s\n' "$session_dir" >&2
      return 1
    }
    for session in "$session_dir"/*.jsonl; do
      [ -e "$session" ] || continue
      [ -f "$session" ] && [ ! -L "$session" ] || {
        printf 'error: refusing to remove non-file OMP session %s\n' "$session" >&2
        return 1
      }
    done
  fi

  rm -f "$state"/.omp-* || {
    printf 'error: could not clear stale OMP runtime markers in %s\n' "$state" >&2
    return 1
  }
  if [ -d "$session_dir" ] && [ ! -L "$session_dir" ]; then
    rm -f "$session_dir"/*.jsonl || {
      printf 'error: could not clear stale OMP sessions in %s\n' "$session_dir" >&2
      return 1
    }
  fi
}