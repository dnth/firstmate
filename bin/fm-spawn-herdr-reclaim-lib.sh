#!/usr/bin/env bash
# Herdr presentation-journal reclaim authority for bin/fm-spawn.sh.
#
# When a task's herdr presentation journal is already published, a relaunch
# under the same task id must prove the recorded endpoint is genuinely gone
# before it may reclaim the pane and fall back to flat placement. That proof is
# this file's whole job, and it lives in a sourceable library so the guard can
# be driven directly by behavioral tests instead of only through a full spawn.
#
# Callers must have sourced bin/fm-backend.sh and must set $ID to the task id
# the diagnostics name; the herdr adapter is loaded on demand here. On success the HERDR_RECOVERY_* globals below carry the
# exact identities the narrower version 2 reclaim path consumes.
set -u

herdr_projection_meta_field_exact() {  # <meta> <key>
  local meta=$1 key=$2 count
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(grep -c "^${key}=" "$meta" 2>/dev/null || true)
  [ "$count" = 1 ] || return 1
  grep "^${key}=" "$meta" 2>/dev/null | cut -d= -f2-
}

# A stale presentation journal never grants launch authority.
# Under the session lock, authoritative metadata must identify one positively
# dead or agent-free endpoint before token inspection may allow flat fallback.
# Exact Herdr fields are retained for the narrower version 2 reclaim path.
# Both liveness reads go through fm_backend_agent_state with the task metadata,
# so every harness is classified here exactly as it is everywhere else. Hermes
# liveness is its persistent TUI process: a pane whose Hermes TUI is gone is
# agent-free and reclaimable even when a resumable session id is still
# recorded. Passing the metadata also makes an unreadable or self-inconsistent
# record refuse rather than read as an agent-free pane, which is the
# fail-closed direction.
herdr_projection_existing_meta_allows_flat() {  # <meta>
  local meta=$1 old_backend old_target old_session old_pane old_state target_session target_pane
  HERDR_RECOVERY_BACKEND=""
  HERDR_RECOVERY_WORKSPACE_ID=""
  HERDR_RECOVERY_TAB_ID=""
  HERDR_RECOVERY_PANE_ID=""
  old_backend=$(fm_backend_of_meta "$meta")
  old_target=$(fm_backend_target_of_meta "$meta")
  [ -n "$old_target" ] || {
    echo "error: existing metadata for $ID has no endpoint; refusing duplicate launch while its herdr presentation journal is quarantined" >&2
    return 1
  }
  # shellcheck disable=SC2034 # Output global consumed by bin/fm-spawn.sh's reclaim path.
  HERDR_RECOVERY_BACKEND=$old_backend
  if [ "$old_backend" = herdr ]; then
    fm_backend_source herdr || {
      echo "error: the herdr adapter could not be loaded to inspect $ID; refusing duplicate launch" >&2
      return 1
    }
    fm_backend_herdr_parse_target "$old_target" || {
      echo "error: existing herdr endpoint for $ID is malformed; refusing duplicate launch" >&2
      return 1
    }
    target_session=$FM_BACKEND_HERDR_SESSION
    target_pane=$FM_BACKEND_HERDR_PANE
    old_session=$(herdr_projection_meta_field_exact "$meta" herdr_session) || {
      echo "error: existing herdr metadata for $ID has an ambiguous session; refusing duplicate launch" >&2
      return 1
    }
    # shellcheck disable=SC2034 # Output global consumed by bin/fm-spawn.sh's reclaim path.
    HERDR_RECOVERY_WORKSPACE_ID=$(herdr_projection_meta_field_exact "$meta" herdr_workspace_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous workspace; refusing duplicate launch" >&2
      return 1
    }
    # shellcheck disable=SC2034 # Output global consumed by bin/fm-spawn.sh's reclaim path.
    HERDR_RECOVERY_TAB_ID=$(herdr_projection_meta_field_exact "$meta" herdr_tab_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous tab; refusing duplicate launch" >&2
      return 1
    }
    old_pane=$(herdr_projection_meta_field_exact "$meta" herdr_pane_id) || {
      echo "error: existing herdr metadata for $ID has an ambiguous pane; refusing duplicate launch" >&2
      return 1
    }
    [ "$target_session" = "$old_session" ] && [ "$target_pane" = "$old_pane" ] || {
      echo "error: existing herdr metadata for $ID has inconsistent endpoint identities; refusing duplicate launch" >&2
      return 1
    }
    # shellcheck disable=SC2034 # Output global consumed by bin/fm-spawn.sh's reclaim path.
    HERDR_RECOVERY_PANE_ID=$old_pane
    fm_backend_herdr_server_ensure "$old_session" || {
      echo "error: existing herdr endpoint for $ID could not be inspected; refusing duplicate launch" >&2
      return 1
    }
    old_state=$(fm_backend_agent_state herdr "$old_target" "$meta")
    case "$old_state" in
      dead|missing) return 0 ;;
      alive)
        echo "error: existing herdr endpoint for $ID is live; refusing duplicate launch" >&2
        return 1
        ;;
      *)
        echo "error: existing herdr endpoint for $ID is unknown; refusing duplicate launch" >&2
        return 1
        ;;
    esac
  fi
  old_state=$(fm_backend_agent_alive "$old_backend" "$old_target" "$meta")
  case "$old_state" in
    dead) return 0 ;;
    alive|unknown)
      echo "error: existing $old_backend endpoint for $ID is $old_state; refusing duplicate launch" >&2
      return 1
      ;;
  esac
}
