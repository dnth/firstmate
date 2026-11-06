# shellcheck shell=bash
# Overdue-request policy for the sibling local-bridge Communication Officer.
#
# Sourced, never executed. Caller: bin/fm-watch.sh's ext_overdue_tick, which
# appends the durable wake row and rings. This owner decides WHICH request earns
# the next reminder and records that it rang.
#
# Every drain presents an unanswered request, so one that has waited past
# FM_EXT_OVERDUE_SECS means no drain reached main since it arrived - typically
# because its check close was coalesced behind a handling episode. One reminder
# per request per FM_EXT_OVERDUE_REMIND_SECS bounds the nagging, and the record's
# removal (ext-respond answering or dismissing it) stops it at the next cycle.
#
# A request acknowledged on Discord while the task spawned for it is still live
# is expected to stay unanswered, so that pair stays quiet; with no live task
# the same reminder applies. bin/fm-ext-lib.sh owns the record, reply-state,
# presentation, and threshold helpers; bin/fm-classify-lib.sh owns what a
# terminal task status is.

_FM_EXT_OVERDUE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_EXT_OVERDUE_LIB_DIR="."
# shellcheck source=bin/fm-ext-lib.sh
. "$_FM_EXT_OVERDUE_LIB_DIR/fm-ext-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_EXT_OVERDUE_LIB_DIR/fm-classify-lib.sh"

# 0 when a task still linked to this request is expected to answer it: its meta
# records ext_request_slug=<slug> and its last status line is not terminal.
fm_ext_overdue_live_task() {  # <state> <slug>
  local state=$1 slug=$2 meta task last
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    grep -qx -- "ext_request_slug=$slug" "$meta" 2>/dev/null || continue
    task=${meta##*/}
    task=${task%.meta}
    last=$(last_status_line "$state/$task.status")
    status_is_terminal_verb "$last" || return 0
  done
  return 1
}

# fm_ext_overdue_ring <home> <state>: print the wake payload of the next
# overdue request, or nothing when none is due. Records the ring in its marker
# so the next call inside the cadence window stays silent. The caller owns the
# durable row and the wake itself.
fm_ext_overdue_ring() {
  local home=${1:-${FM_HOME:?}} state=${2:-} pending slug record recorded age now threshold remind
  local mark reply last
  [ -n "$state" ] || return 1
  pending=$(fm_ext_pending_requests "$home" 2>/dev/null) || return 0
  now=$(date +%s)
  threshold=$(fm_ext_overdue_secs)
  remind=$(fm_ext_overdue_remind_secs)
  # Forget the marker of every request that is no longer unanswered, so a
  # answered request cannot keep a leftover file and a later one cannot inherit
  # an old cadence.
  for mark in "$state"/.ext-overdue.*; do
    [ -e "$mark" ] || continue
    slug=${mark##*/.ext-overdue.}
    printf '%s\n' "$pending" | grep -Fx -- "$slug" >/dev/null 2>&1 || rm -f -- "$mark" 2>/dev/null || true
  done
  while IFS= read -r slug; do
    [ -n "$slug" ] || continue
    record=$(fm_ext_inbox_dir "$home")/$slug.json
    recorded=$(jq -r '.recorded_at // empty | tostring' "$record" 2>/dev/null) || recorded=''
    case "$recorded" in ''|*[!0-9]*) recorded=$(fm_ext_file_mtime "$record") || recorded=$now ;; esac
    case "$recorded" in ''|*[!0-9]*) recorded=$now ;; esac
    [ "$recorded" -le "$now" ] || recorded=$now
    age=$((now - recorded))
    [ "$age" -ge "$threshold" ] || continue
    reply=$(fm_ext_request_reply_state "$slug" "$home") || reply=none
    case "$reply" in
      ack\ *) fm_ext_overdue_live_task "$state" "$slug" && continue ;;
    esac
    mark="$state/.ext-overdue.$slug"
    if [ -f "$mark" ] && [ ! -L "$mark" ]; then
      last=$(fm_ext_file_mtime "$mark") || last=0
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      [ "$((now - last))" -ge "$remind" ] || continue
    fi
    printf '%s\n' "$now" > "$mark" 2>/dev/null || return 1
    printf 'ext-request-overdue %s age=%sm\n' "$slug" "$((age / 60))"
    return 0
  done <<EOF
$pending
EOF
  return 0
}
