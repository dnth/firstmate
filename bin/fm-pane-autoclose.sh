#!/usr/bin/env bash
# fm-pane-autoclose.sh - close a finished task's pane once its completion
# delivery receipt is recorded and no follow-on work remains.
#
# Usage: fm-pane-autoclose.sh <task-id> --endpoint <status-endpoint>
#        --status-ident <device:inode>
#
# THE PROBLEM THIS SOLVES: finished panes accumulate because pane closure only
# happened at teardown (merge, local landing, explicit cleanup). A scout, an
# audit, or a task whose row stays In flight until later ends its pane's useful
# life at the delivery receipt, and Herdr upstream has no auto-reap - correctly,
# because a supervisor may still need live context. So the decision belongs to
# firstmate's delivery path: bin/fm-branch-outcome.sh deliver calls this script
# immediately after it records a receipt, passing the exact status-file byte
# endpoint that receipt covers.
#
# CONTRACT (this header is the one owner of the gate and its exit codes).
# Every condition below must hold before closing.
#
#   1. The status file still holds the identity the receipt was recorded
#      against (--status-ident, rechecked immediately before the close), and the
#      --endpoint equals the byte endpoint of the live standing nonblank event.
#      deliver --endpoint deliberately accepts a rotated or replaced status file
#      so an old receipt stays inert; here that same staleness must never close
#      a replacement task's pane, and a later appending status event means the
#      claim moved on either way. Nothing is closed in either case.
#   2. That line's leading verb is `done` AND it carries the delivery artifact
#      its kind/mode requires, judged by bin/fm-classify-lib.sh's
#      status_done_line_has_artifact (a PR URL for PR modes or the report path
#      for a scout). Local-only mode never satisfies the trigger.
#      A failed:, paused:, or
#      unkeyed needs-decision:/blocked: receipt never closes a pane: a
#      supervisor still needs that context.
#   3. No follow-on work remains: a still-open keyed decision or
#      blocker in the status fold (bin/fm-classify-lib.sh status_open_decisions);
#      an incomplete or unanswered linked captain-call inventory
#      (bin/fm-captain-hold.sh verify --require-answered);
#      a held or blocked backlog row (bin/fm-backlog-transition-lib.sh
#      fm_backlog_row_probe); an open routed reply
#      (bin/fm-pending-reply-lib.sh fm_pending_reply_task_has_open); an armed or
#      intended custom watcher check (state/<id>.check.sh present); an
#      ext_request= or legacy x_request= task link in the metadata; or an
#      unresolved public commitment the myfirstmate relay still owes
#      (bin/fm-public-followup.sh guard-work, addressed through the verified
#      work owner resolved by bin/fm-public-followup-lib.sh). A board row that
#      is merely In flight does not itself keep the pane: completion recording and the
#      board close are separate, so the row often stays open at receipt time.
#   4. A kind=secondmate record keeps its pane: a persistent home is a
#      supervisor surface, not finished task work.
#   5. The endpoint comes only from ordinary task metadata. A missing or
#      ambiguous endpoint in a present record refuses loudly (exit 2). An
#      absent metadata record means no managed endpoint exists and keeps silently.
#   6. The close is the same guarded path teardown uses for one exact task
#      pane: bin/backends/herdr.sh
#      fm_backend_herdr_projection_close_pane_focus_preserving, serialized by
#      the named session's presentation lock, which never calls
#      `workspace close` and refuses to touch the captain's active tab. Only
#      the pane view closes: the Herdr session, its other panes, and every
#      transcript stay intact, and no durable task record is removed.
#      After acquiring the presentation lock, the status identity, standing
#      event byte endpoint, artifact, follow-on gate, and metadata endpoint
#      are revalidated before closing.
#
# Backend scope: Herdr is the backend with a focus-preserving exact-pane close
# contract. Every other backend is left to teardown and reported as skipped,
# because no other adapter guarantees the active-tab refusal this path needs.
#
# Exit codes: 0 closed, already gone, kept (a gate held), or skipped (backend
# outside scope); 1 the close was attempted and could not be confirmed (the
# pane, its metadata, and every other record are left exactly as they were);
# 2 refused loudly (ambiguous endpoint, unprovable follow-on state) - nothing
# was closed.
#
# The caller treats every non-zero exit as a reported non-close, never as a
# delivery failure: the receipt is already durable when this runs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"

usage() {
  echo "usage: fm-pane-autoclose.sh <task-id> --endpoint <status-endpoint> --status-ident <device:inode>" >&2
  exit 2
}

# Print "closed: ..." or "kept: <reason>" and exit 0: this walk decided not to
# close, which is never an error for the caller.
kept() { # <task> <reason>
  printf 'kept: %s %s\n' "$1" "$2"
  exit 0
}

refused() { # <task> <reason>
  printf 'refused: %s %s\n' "$1" "$2" >&2
  exit 2
}

read_standing_event() {
  local LC_ALL=C line pos=0 newline
  STANDING_ENDPOINT=0
  EVENT_LINE=
  while
    newline=1
    IFS= read -r line || { newline=0; [ -n "$line" ]; }
  do
    pos=$((pos + ${#line} + newline))
    if [[ "$line" =~ [^[:space:]] ]]; then
      STANDING_ENDPOINT=$pos
      EVENT_LINE=$line
    fi
  done < "$1"
}

# Open follow-on work, or empty when none was found. Prints one plain reason on
# a hold and returns 1; returns 2 when durable state cannot prove the answer, so
# the caller refuses rather than closing on an unproven guess.
open_follow_on() { # <task> <kind>
  local task=$1 kind=$2 meta="$STATE/$1.meta" status="$STATE/$1.status" open rc

  open=$(status_open_decisions "$status")
  if [ -n "$open" ]; then
    printf 'open keyed decision or blocker: %s' "$(printf '%s' "$open" | cut -f1 | tr '\n' ' ')"
    return 1
  fi

  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" verify "$task" --require-answered >/dev/null 2>&1; then
    printf 'linked captain-call inventory is incomplete or unresolved'
    return 1
  fi

  if [ -n "$(fm_meta_get "$meta" ext_request)$(fm_meta_get "$meta" x_request)" ]; then
    printf 'linked external request'
    return 1
  fi

  if [ -e "$STATE/$task.check.sh" ] || [ -L "$STATE/$task.check.sh" ]; then
    printf 'armed or intended custom check'
    return 1
  fi

  if fm_pending_reply_task_has_open "$STATE" "$task"; then
    printf 'open routed reply'
    return 1
  fi

  public_followup_state "$task"
  rc=$?
  case "$rc" in
    0) ;;
    1) printf 'unresolved public commitment'; return 1 ;;
    *) printf 'public commitment state cannot be read'; return 2 ;;
  esac

  board_row_state "$task" "$kind"
  rc=$?
  case "$rc" in
    0) ;;
    1) printf 'blocked or held backlog row'; return 1 ;;
    *) printf 'backlog row state cannot be read (%s)' "${FM_BACKLOG_ROW_ERROR:-unknown error}"; return 2 ;;
  esac
  return 0
}

# 0 when no unresolved public commitment is bound to <task> here, 1 when one is
# still owed, 2 when the answer cannot be proven. A home that never opted into
# the relay answers 0 through the script's own activation gate.
public_followup_state() { # <task>
  local task=$1 rc
  [ -x "$SCRIPT_DIR/fm-public-followup.sh" ] || return 0
  fm_pf_resolve_work_owner "$FM_HOME" "$STATE" "$KIND" "$task"
  [ "$PUBLIC_FOLLOWUP_PARENT_UNRESOLVED" = 0 ] || return 2
  [ -n "$PUBLIC_FOLLOWUP_STATE" ] && [ "$PUBLIC_FOLLOWUP_RELAY_ACTIVE" = 1 ] || return 0
  FM_HOME="$PUBLIC_FOLLOWUP_HOME" FM_STATE_OVERRIDE="$PUBLIC_FOLLOWUP_STATE" \
    "$SCRIPT_DIR/fm-public-followup.sh" guard-work "$PUBLIC_FOLLOWUP_WORK_HOME" "$task" >/dev/null 2>&1
  rc=$?
  case "$rc" in
    0) return 0 ;;
    3) return 1 ;;
    *) return 2 ;;
  esac
}

# 0 when <task>'s board row is absent or neither held nor blocked, 1 when it is
# held or blocked, 2 when the row cannot be read. A board row that is merely In
# flight does not hold a pane: completion delivery and the board close are
# separate events. A home whose configured backend is manual, or which keeps no
# backlog file, has no automatic row to consult, which is not a hold.
board_row_state() { # <task> <kind>
  local task=$1 kind=$2 rc held blocked
  fm_backlog_transition_applies "$CONFIG" "$DATA" "$kind"
  rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
  fm_backlog_row_probe "$DATA" "$task"
  rc=$?
  case "$rc" in
    0)
      held=${FM_BACKLOG_ROW_STATE#* }
      blocked=${held#* }
      held=${held%% *}
      [ "$held" = yes ] || [ "$blocked" = yes ] || return 0
      return 1
      ;;
    *)
      [ "$FM_BACKLOG_ROW_RESULT" = not_found ] && return 0
      return 2
      ;;
  esac
}

TASK=''
ENDPOINT=''
STATUS_IDENT=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --endpoint) ENDPOINT=${2:-}; shift 2 || usage ;;
    --status-ident) STATUS_IDENT=${2:-}; shift 2 || usage ;;
    --help|-h) sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) usage ;;
    *) [ -z "$TASK" ] || usage; TASK=$1; shift ;;
  esac
done
[ -n "$TASK" ] || usage
case "$TASK" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
case "$ENDPOINT" in ''|*[!0-9]*) usage ;; esac
case "$STATUS_IDENT" in ''|*[!0-9:]*|*:*:*) usage ;; esac

META="$STATE/$TASK.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  kept "$TASK" "no task endpoint metadata"
fi

META_LOCK=$(fm_meta_lock_path "$META") || refused "$TASK" "task lifecycle lock is unresolvable"
fm_lock_acquire_wait "$META_LOCK" || refused "$TASK" "task lifecycle lock is contended"
LOCK_HELD=0
trap 'if [ "$LOCK_HELD" = 1 ]; then fm_lock_release "$LOCK_PATH" || true; fi; fm_lock_release "$META_LOCK" || true' EXIT
[ -f "$META" ] && [ ! -L "$META" ] || kept "$TASK" "no task endpoint metadata"

KIND=$(fm_meta_get "$META" kind)
[ -n "$KIND" ] || KIND=ship
[ "$KIND" != secondmate ] || kept "$TASK" "secondmate home keeps its pane"
MODE=$(fm_meta_get "$META" mode)
[ -n "$MODE" ] || MODE=no-mistakes

STATUS="$STATE/$TASK.status"
validate_completion() {
  [ "$MODE" != local-only ] || kept "$TASK" "local-only completion never autocloses"
  [ ! -L "$STATUS" ] || refused "$TASK" "status path is unsafe"
  [ -f "$STATUS" ] || kept "$TASK" "no live status record"
  LIVE_IDENT=$(_fm_open_decisions_file_ident "$STATUS") || refused "$TASK" "status file identity cannot be read"
  [ "$LIVE_IDENT" = "$STATUS_IDENT" ] \
    || kept "$TASK" "receipt status identity no longer matches this status file"
  read_standing_event "$STATUS" || refused "$TASK" "live standing event is unreadable"
  [ "$STANDING_ENDPOINT" = "$ENDPOINT" ] \
    || kept "$TASK" "a later status event supersedes the delivered claim"
  [ -n "$EVENT_LINE" ] || refused "$TASK" "no status line ends at $ENDPOINT"

  [ "$(status_line_verb "$EVENT_LINE")" = "done" ] \
    || kept "$TASK" "delivered event is not a done: claim"
  status_done_line_has_artifact "$EVENT_LINE" "$KIND" "$MODE" "$TASK" \
    || kept "$TASK" "done: claim carries no delivery artifact"

  FOLLOW_ON=$(open_follow_on "$TASK" "$KIND")
  rc=$?
  case "$rc" in
    0) ;;
    1) kept "$TASK" "follow-on work remains: $FOLLOW_ON" ;;
    *) refused "$TASK" "cannot prove follow-on state is clear: $FOLLOW_ON" ;;
  esac
}
validate_completion

fm_backend_validate_task_endpoint "$META" "$TASK" || exit 2
BACKEND=$FM_BACKEND_VALIDATED_BACKEND
TARGET=$FM_BACKEND_VALIDATED_TARGET
[ "$BACKEND" = herdr ] || kept "$TASK" "backend $BACKEND has no guarded autoclose path"

fm_backend_source herdr || refused "$TASK" "herdr adapter is unavailable"
for prerequisite in \
  fm_backend_herdr_parse_target \
  fm_backend_herdr_pane_presence_state \
  fm_backend_herdr_endpoint_confirmed_gone \
  fm_backend_herdr_projection_close_pane_focus_preserving \
  fm_backend_herdr_presentation_session_lock_path; do
  declare -F "$prerequisite" >/dev/null 2>&1 \
    || refused "$TASK" "herdr close prerequisite $prerequisite is unavailable"
done

fm_backend_herdr_parse_target "$TARGET" || refused "$TASK" "endpoint $TARGET cannot be parsed exactly"
SESSION=$FM_BACKEND_HERDR_SESSION
PANE=$FM_BACKEND_HERDR_PANE

PRESENCE=$(fm_backend_herdr_pane_presence_state "$SESSION" "$PANE")
case "$PRESENCE" in
  dead) printf 'closed: %s pane %s:%s was already gone\n' "$TASK" "$SESSION" "$PANE"; exit 0 ;;
  present) ;;
  *) refused "$TASK" "endpoint $TARGET has ambiguous structured presence";;
esac

LOCK_PATH=$(fm_backend_herdr_presentation_session_lock_path "$SESSION") \
  || refused "$TASK" "herdr session presentation lock is unresolvable"
LOCK_HELD=0
attempt=0
while [ "$attempt" -lt 50 ]; do
  if fm_lock_try_acquire "$LOCK_PATH"; then
    LOCK_HELD=1
    break
  fi
  sleep 0.1
  attempt=$((attempt + 1))
done
if [ "$LOCK_HELD" != 1 ]; then
  refused "$TASK" "herdr session presentation lock is contended"
fi
VERIFIED_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$SESSION" 2>/dev/null) || VERIFIED_LOCK=
if [ "$VERIFIED_LOCK" != "$LOCK_PATH" ]; then
  refused "$TASK" "herdr session presentation lock changed while acquiring it"
fi

validate_completion
fm_backend_validate_task_endpoint "$META" "$TASK" || exit 2
[ "$FM_BACKEND_VALIDATED_BACKEND" = "$BACKEND" ] && [ "$FM_BACKEND_VALIDATED_TARGET" = "$TARGET" ] \
  || refused "$TASK" "task endpoint changed before the close"

CLOSE_RC=0
fm_backend_herdr_projection_close_pane_focus_preserving "$SESSION" "$PANE" || CLOSE_RC=$?
fm_lock_release "$LOCK_PATH" || true
LOCK_HELD=0

if fm_backend_herdr_endpoint_confirmed_gone "$TARGET"; then
  printf 'closed: %s pane %s:%s\n' "$TASK" "$SESSION" "$PANE"
  exit 0
fi
if [ "$CLOSE_RC" -eq 1 ]; then
  kept "$TASK" "pane close was refused (active tab or unverifiable focus)"
fi
printf 'error: herdr pane %s:%s for %s is not confirmed gone after the close attempt\n' \
  "$SESSION" "$PANE" "$TASK" >&2
exit 1
