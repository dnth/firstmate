# shellcheck shell=bash
# fm-omp-secondmate-restart-lib.sh - restart one LOCAL OMP second mate. Source only.
#
# Why OMP does not take the generic control-plane relaunch:
# bin/fm-control.sh's relaunch stops the agent and hands the replacement to
# bin/fm-spawn.sh --relaunch, which is correct for every adapter whose only
# launch-time state is its own process. An OMP second mate also owns a set of
# session artifacts that outlive the process it belongs to - the task extension
# and its two acknowledgement markers in the parent's state, and the home's
# primary-integration marker - and bin/fm-spawn.sh refuses a second mate launch
# while any of them is still on disk, because a live agent's artifact and a dead
# one's leftover are the same bytes. Only the pass that just proved the previous
# owner gone can tell those two apart, so retiring them belongs here, between the
# absence proof and the launch, and nowhere else.
#
# The order below is the whole contract, and each step is a precondition of the
# next one:
#
#   1. STOP the process that owns the mate's home session.
#   2. PROVE it absent. Nothing is deleted while it might still be running,
#      because an artifact removed under a live agent is indistinguishable from a
#      fresh one and the next launch would accept a duplicate.
#   3. RETIRE the four session artifacts, now that no owner can recreate them.
#   4. LAUNCH the replacement through the single launch owner.
#   5. RECONCILE the durable record: the launch allocates a fresh endpoint, so the
#      restart is proven by the new endpoint the launch owner published, never by
#      the retired one this pass started from.
#
# Seams, so the two real side effects can be driven deterministically by
# tests/fm-secondmate-restart.test.sh. Both default to the real thing, so
# production behavior is identical when neither is set:
#   FM_RESTART_STOP_CMD   stops and probes the owner process (default: kill).
#                         Invoked as "<cmd> <pid>" to stop it and "<cmd> -0 <pid>"
#                         to probe it, so one override covers both halves of the
#                         stop-then-prove step.
#   FM_RESTART_SPAWN_CMD  the launch owner (default: bin/fm-spawn.sh). Invoked as
#                         "<cmd> <id> --secondmate".
#   FM_RESTART_STOP_WAIT  seconds to wait for the owner to go (default 30).
#   FM_RESTART_STOP_POLL  seconds between absence probes (default 1).
#
# Every path resolves from ${FM_STATE_OVERRIDE:-$FM_HOME/state} and the mate's
# own recorded home, so a test home redirects all of them at once.

_FM_OMP_SECONDMATE_RESTART_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$_FM_OMP_SECONDMATE_RESTART_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-omp-process-lib.sh disable=SC1091
. "$_FM_OMP_SECONDMATE_RESTART_LIB_DIR/fm-omp-process-lib.sh"

# The pid of the process holding the mate's home session. bin/fm-spawn.sh
# refuses a duplicate launch on exactly these two records, so they are also the
# only two that can name the owner this pass has to see gone.
_fm_omp_restart_owner_pid() {  # <home-state>
  local home_state=$1 pid=""
  if [ -f "$home_state/.lock" ] && [ ! -L "$home_state/.lock" ]; then
    IFS= read -r pid < "$home_state/.lock" || pid=""
  fi
  case "$pid" in
    ''|*[!0-9]*|0|1)
      if fm_omp_primary_marker_read "$home_state/.omp-primary-extension-loaded"; then
        pid=$FM_OMP_MARKER_PID
      else
        pid=""
      fi
      ;;
  esac
  case "$pid" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  printf '%s' "$pid"
}

# Restart one local OMP second mate. Prints the same "relaunched <id> harness=..."
# line bin/fm-control.sh prints, so the reporting caller reads one shape for every
# placement. Returns non-zero with one operator-readable "error: " line otherwise.
fm_omp_secondmate_restart() {  # <id>
  local id=${1-} state meta home home_state pid prior_window new_window
  local stop_cmd spawn_cmd stop_wait stop_poll elapsed proven marker spawn_out
  local model effort backend
  local -a markers

  [ -n "$id" ] || { echo "error: fm_omp_secondmate_restart needs a second mate id" >&2; return 1; }
  [ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set, so second mate $id cannot be resolved" >&2; return 1; }
  state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  meta="$state/$id.meta"
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    echo "error: second mate $id has no durable record at $meta" >&2
    return 1
  fi
  prior_window=$(fm_meta_get "$meta" window)
  if [ -z "$prior_window" ]; then
    echo "error: second mate $id's durable record names no endpoint, so there is no agent to replace" >&2
    return 1
  fi
  home=$(fm_meta_get "$meta" project)
  [ -n "$home" ] || home=$FM_HOME
  home_state="$home/state"
  model=$(fm_meta_get "$meta" model)
  effort=$(fm_meta_get "$meta" effort)
  backend=$(fm_backend_of_meta "$meta")

  markers=(
    "$state/$id.omp-started"
    "$state/$id.omp-ext.ts"
    "$state/$id.omp-ready"
    "$home_state/.omp-primary-extension-loaded"
  )

  stop_cmd=${FM_RESTART_STOP_CMD:-kill}
  spawn_cmd=${FM_RESTART_SPAWN_CMD:-$_FM_OMP_SECONDMATE_RESTART_LIB_DIR/fm-spawn.sh}
  stop_wait=${FM_RESTART_STOP_WAIT:-30}
  stop_poll=${FM_RESTART_STOP_POLL:-1}
  case "$stop_wait" in ''|*[!0-9]*) echo "error: FM_RESTART_STOP_WAIT must be a non-negative integer: $stop_wait" >&2; return 1 ;; esac
  case "$stop_poll" in ''|*[!0-9]*|0) echo "error: FM_RESTART_STOP_POLL must be a positive integer: $stop_poll" >&2; return 1 ;; esac

  if ! pid=$(_fm_omp_restart_owner_pid "$home_state"); then
    echo "error: second mate $id's home names no running session owner, so its agent cannot be stopped deliberately; reconcile the home before restarting it" >&2
    return 1
  fi

  # 1. Stop. A stop that reports failure is not itself fatal: the owner may have
  # gone between reading its pid and signalling it, and step 2 is the authority.
  "$stop_cmd" "$pid" >/dev/null 2>&1 || true

  # 2. Prove absent, before anything is deleted.
  proven=0
  elapsed=0
  while :; do
    if ! "$stop_cmd" -0 "$pid" >/dev/null 2>&1; then
      proven=1
      break
    fi
    [ "$elapsed" -lt "$stop_wait" ] || break
    sleep "$stop_poll"
    elapsed=$((elapsed + stop_poll))
  done
  if [ "$proven" -ne 1 ]; then
    echo "error: second mate $id's session owner (pid $pid) was still running ${stop_wait}s after it was asked to stop; nothing was cleaned up and its agent was left as it was" >&2
    return 1
  fi

  # 3. Retire the session artifacts the launch owner refuses to launch over.
  for marker in "${markers[@]}"; do
    if [ -L "$marker" ]; then
      echo "error: second mate $id's session artifact $marker is a symlink; refusing to retire it" >&2
      return 1
    fi
    [ -e "$marker" ] || continue
    rm -f "$marker" || {
      echo "error: second mate $id's session artifact $marker could not be retired" >&2
      return 1
    }
  done

  # 4. Launch the replacement.
  if ! spawn_out=$(FM_SPAWN_NO_GUARD="${FM_SPAWN_NO_GUARD:-1}" "$spawn_cmd" "$id" --secondmate 2>&1); then
    echo "error: the replacement agent for $id could not be launched: $(printf '%s\n' "$spawn_out" | sed -n '/./{s/^error: //;p;q;}')" >&2
    return 1
  fi

  # 5. Reconcile against the endpoint the launch owner actually published.
  new_window=$(fm_meta_get "$meta" window)
  if [ -z "$new_window" ] || [ "$new_window" = "$prior_window" ]; then
    echo "error: $id was relaunched but its durable record still names the retired endpoint '${prior_window}'; the restart outcome is unknown" >&2
    return 1
  fi

  printf 'relaunched %s harness=omp from=omp model=%s effort=%s backend=%s endpoint=%s worktree=%s\n' \
    "$id" "${model:-default}" "${effort:-default}" "$backend" "$new_window" "$home"
}
