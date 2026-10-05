#!/usr/bin/env bash
# Usage: fm-boat.sh provision|wake|sleep|destroy|status|cost|ssh <id> [options]
# provision requires --identity <private-key> --model <provider/model>; --omp-auth
# enables the scoped workstation credential lease. No ephemeral crew path exists.
# Sleep/destroy share existing delivery, reply, work and decision guards;
# destroy of a dormant placement skips remote checks only with sleep-time
# quiescence proof, since failed wakes can also leave a suspended record.
# Python owns provider compensation; systemd cgroups own local credential custody.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(dirname "$SCRIPT_DIR")}}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
case "${1:-}" in
  sleep|destroy)
    id=${2:?secondmate id required}
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    # shellcheck source=bin/fm-secondmate-registry-lib.sh
    . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    # shellcheck source=bin/fm-pending-reply-lib.sh
    . "$SCRIPT_DIR/fm-pending-reply-lib.sh"
    case "$id" in ''|.*|*[!A-Za-z0-9._-]*) exit 2 ;; esac
    handoff=$(secondmate_handoff_lock_path "$STATE" "$id")
    reply=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
    fm_lock_acquire_wait "$handoff"
    trap 'fm_lock_release "$handoff"' EXIT
    fm_lock_acquire_wait "$reply"
    trap 'fm_lock_release "$reply"; fm_lock_release "$handoff"' EXIT
    [ ! -e "$DATA/handoff/$id.outbox.md" ] || { printf 'error: undelivered backlog handoff\n' >&2; exit 1; }
    fm_pending_reply_reconcile_task "$STATE" "$id" "$STATE/$id.status"
    for path in "$STATE/pending-replies/"*; do
      [ -f "$path" ] || continue
      if [ "$(fm_pending_reply_get "$path" task_id)" = "$id" ] && [ "$(fm_pending_reply_get "$path" phase)" != resolved ]; then
        printf 'error: unresolved routed reply\n' >&2; exit 1
      fi
    done
    [ -z "$(status_open_decisions "$STATE/$id.status")" ] || { printf 'error: unresolved decisions\n' >&2; exit 1; }
    dormant_destroy=0
    checked=0
    remote_route=0
    [ "$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null || true)" = 1 ] && remote_route=1
    if [ "$1" = destroy ] && [ "$remote_route" = 1 ]; then
      lifecycle=$(grep -m1 '^lifecycle=' "$DATA/boat/$id.meta" 2>/dev/null | cut -d= -f2- || true)
      quiesced=$(grep -m1 '^sleep_quiesced=' "$DATA/boat/$id.meta" 2>/dev/null | cut -d= -f2- || true)
      case "$lifecycle" in
        suspended|provisioned)
          if [ "$quiesced" = 1 ]; then
            dormant_destroy=1
          else
            printf 'error: dormant placement has no sleep-time quiescence proof; wake it so destroy can run remote checks\n' >&2
            exit 1
          fi
          ;;
      esac
    fi
    if [ "$remote_route" = 1 ] && [ "$dormant_destroy" = 0 ]; then
      "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh sleep-reconcile "$id"
      children=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh children "$id")
      [ "$children" = children=0 ] || { printf 'error: remote child work is active or unknown\n' >&2; exit 1; }
      checked=1
    fi
    remote=0
    if [ -f "$STATE/$id.meta" ]; then
      remote=1
      if ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" retire-quiesce-locked "$id"; then
        "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm-locked "$id" \
          || printf 'error: reply-source restoration incomplete\n' >&2
        exit 1
      fi
    fi
    if FM_BOAT_SLEEP_QUIESCED=$checked FM_BOAT_DESTROY_DORMANT=$dormant_destroy \
       uv run --no-project "$SCRIPT_DIR/fm-boat.py" "$@"; then
      [ "$remote" = 0 ] || "$SCRIPT_DIR/fm-procevent-remote-reply.sh" retire-finalize-locked "$id"
    else
      [ "$remote" = 0 ] || "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm-locked "$id" \
        || printf 'error: reply-source restoration incomplete\n' >&2
      exit 1
    fi
    ;;
  *) exec uv run --no-project "$SCRIPT_DIR/fm-boat.py" "$@" ;;
esac
