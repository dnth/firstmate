#!/usr/bin/env bash
# Remove one drained Communication Officer inbox record only when its delivery
# disposition is durably recorded.
#
# Usage:
#   fm-ext-inbox.sh remove --slug <slug>
#       [--task <task-id>] [--no-reply [--reason "<text>"]]
#   fm-ext-inbox.sh dismiss --slug <slug> --reason "<text>"
#
# The inbox record is `state/ext-inbox/<slug>.json`; the durable delivery
# records live in `state/ext-outbox/`. A request is cleared only when one of
# these recorded dispositions exists:
#
#   receipt    `state/ext-outbox/<slug>.<kind>.<generation>.receipt.json` for
#              the highest generation this request reached, carrying
#              `"ok": true` for every reply kind present at that generation.
#              Answer, followup, final, and ack deliveries all qualify. The
#              latest generation decides: an older receipt never clears a
#              request whose newest attempt is still pending or
#              terminally failed.
#   task       `--task <task-id>` plus the link `bin/fm-ext-link.sh` records
#              (`ext_request` or `ext_request_slug`) in that task's meta. This
#              is the long-running case: work is under way and the task record
#              keeps the request reachable for its later follow-ups. It still
#              refuses an unpaired mid-delivery posting marker or a terminal
#              failure for the latest generation.
#   no-reply   `--no-reply` for a true pure acknowledgment. The helper records
#              `state/ext-outbox/<slug>.noreply.json` with the reason before
#              removing the inbox record. It refuses when any delivery record
#              exists for the slug, so a pending, failed, or already-receipted
#              reply can never be cleared as if nothing had been sent.
#
# `remove` refuses - leaving the inbox file in place - when:
#   - the inbox record is missing or is not a safe mode-0600 private artifact;
#   - a posting marker for the latest generation has no receipt (mid-delivery);
#   - the latest generation's receipt does not carry `"ok": true`;
#   - the latest generation recorded a terminal delivery failure;
#   - `--task` names a task whose meta does not link this request;
#   - `--no-reply` is combined with any reply delivery record.
# The receipt path additionally refuses when the latest generation has no
# receipt at all.
#
# `dismiss` marks one request as needing no reply when no reply disposition
# above fits, for example a duplicate already answered through another request
# in the same thread, or a malformed message. `--reason` is required and must
# be one non-empty line. It records `state/ext-outbox/<slug>.noreply.json` with
# `"disposition": "dismissed"` and the reason, then removes the inbox record.
# Unlike `--no-reply` it does not check delivery records: it is the explicit,
# recorded way out when a reply is stuck mid-delivery or failed and the
# request should no longer block `bin/fm-wake-drain.sh --ack-through`. It still
# refuses an unsafe inbox record, or an existing no-reply record that carries
# another disposition.
#
# This command is the single owner of inbox removal. Never chain a raw `rm` of
# `state/ext-inbox/<slug>.json` to an emit: a published payload is not a
# delivery receipt, and a refused emit must leave the request in place.
#
# Exit codes: 0 removed, 1 refused, 2 invalid usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-ext-inbox.sh remove --slug <slug>
         [--task <task-id>] [--no-reply [--reason "<text>"]]
       fm-ext-inbox.sh dismiss --slug <slug> --reason "<text>"
EOF
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

refuse() {
  printf 'fm-ext-inbox: refusing to remove %s: %s\n' "${SLUG:-<slug>}" "$*" >&2
  exit 1
}

CMD=${1:-}
case "$CMD" in
  --help|-h) help; exit 0 ;;
  remove|dismiss) shift ;;
  '') usage; exit 2 ;;
  *) usage; exit 2 ;;
esac

SLUG=''
TASK=''
NO_REPLY=0
REASON=''
REASON_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --slug)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      SLUG=$2
      shift 2
      ;;
    --task)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      TASK=$2
      shift 2
      ;;
    --no-reply)
      NO_REPLY=1
      shift
      ;;
    --reason)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      REASON=$2
      REASON_SET=1
      shift 2
      ;;
    --help|-h)
      help
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$SLUG" ] || { usage; exit 2; }
fm_ext_slug_valid "$SLUG" || { echo "fm-ext-inbox: unsafe slug" >&2; exit 2; }
if [ -n "$TASK" ]; then
  fm_pr_task_id_valid "$TASK" || { echo "fm-ext-inbox: unsafe task id" >&2; exit 2; }
fi
if [ "$CMD" = dismiss ]; then
  [ -z "$TASK" ] && [ "$NO_REPLY" -eq 0 ] || {
    echo "fm-ext-inbox: dismiss takes only --slug and --reason" >&2
    exit 2
  }
  [ "$REASON_SET" -eq 1 ] || {
    echo "fm-ext-inbox: dismiss needs --reason \"<why no reply is needed>\"" >&2
    exit 2
  }
else
  [ "$NO_REPLY" -eq 1 ] || [ "$REASON_SET" -eq 0 ] || {
    echo "fm-ext-inbox: --reason needs --no-reply" >&2
    exit 2
  }
  [ "$REASON_SET" -eq 1 ] || REASON='pure acknowledgement'
fi
case "$REASON" in
  ''|*$'\n'*) echo "fm-ext-inbox: --reason must be one non-empty line" >&2; exit 2 ;;
esac

INBOX=$(fm_ext_inbox_dir) || exit 1
OUTBOX=$(fm_ext_outbox_dir) || exit 1
INBOX_RECORD="$SLUG.json"

[ -d "$INBOX" ] && [ ! -L "$INBOX" ] || refuse "no inbox directory"
fm_ext_private_artifact_file_valid "$INBOX" "$INBOX_RECORD" 600 \
  || refuse "no safe inbox record at state/ext-inbox/$INBOX_RECORD"

# Read the request id from the inbox record before deciding; the task link and
# the no-reply disposition both name it.
REQUEST_ID=$(jq -r '.request_id // empty' "$INBOX/$INBOX_RECORD" 2>/dev/null) || REQUEST_ID=''
if [ -n "$REQUEST_ID" ]; then
  EXPECTED_SLUG=$(fm_ext_request_slug "$REQUEST_ID" 2>/dev/null) || EXPECTED_SLUG=''
  [ "$EXPECTED_SLUG" = "$SLUG" ] \
    || refuse "inbox record request id does not hash to its own slug"
fi

# Scan this request's outbox records. Only the highest generation decides:
# an old receipt must never clear a request whose newest attempt is pending,
# mid-delivery, or failed.
max_gen=0
latest_records=()
reply_records=0

if [ -d "$OUTBOX" ] && [ ! -L "$OUTBOX" ]; then
  for file in "$OUTBOX/$SLUG".*; do
    [ -e "$file" ] || continue
    [ -f "$file" ] || continue
    base=${file##*/}
    rest=${base#"$SLUG".}
    kind=${rest%%.*}
    remainder=${rest#*.}
    gen=${remainder%%.*}
    suffix=${remainder#*.}
    [ "$remainder" != "$rest" ] || continue
    fm_ext_reply_kind_valid "$kind" || continue
    fm_ext_generation_valid "$gen" || continue
    case "$suffix" in
      json) : ;;
      posting|receipt.json|failed.json|progress.json) : ;;
      *) continue ;;
    esac
    gen=$((10#$gen))
    reply_records=$((reply_records + 1))
    if [ "$gen" -gt "$max_gen" ]; then
      max_gen=$gen
      latest_records=()
    fi
    [ "$gen" -eq "$max_gen" ] || continue
    latest_records+=("$base")
  done
fi

latest_receipt_ok=0
latest_pending=0
# Dismissing is the recorded way out of a stuck or failed delivery, so the
# latest generation's delivery state never refuses it.
[ "$CMD" != dismiss ] || latest_records=()
for base in ${latest_records[@]+"${latest_records[@]}"}; do
  rest=${base#"$SLUG".}
  kind=${rest%%.*}
  remainder=${rest#*.}
  suffix=${remainder#*.}
  receipt="${base%."$suffix"}.receipt.json"
  case "$suffix" in
    failed.json)
      refuse "generation $max_gen ($kind) recorded a terminal delivery failure"
      ;;
    receipt.json)
      fm_ext_private_artifact_file_valid "$OUTBOX" "$base" 600 \
        || refuse "latest receipt $base is not a safe private artifact"
      ok=$(jq -r 'if .ok == true then "true" else "false" end' "$OUTBOX/$base" 2>/dev/null) || ok='false'
      [ "$ok" = 'true' ] || refuse "latest receipt $base does not record ok: true"
      latest_receipt_ok=1
      ;;
    *)
      if ! fm_ext_private_artifact_file_valid "$OUTBOX" "$receipt" 600; then
        [ "$suffix" != posting ] \
          || refuse "generation $max_gen ($kind) is mid-delivery with no receipt"
        latest_pending=1
      fi
      ;;
  esac
done

disposition=''
if [ "$CMD" = dismiss ]; then
  disposition='dismissed'
elif [ "$NO_REPLY" -eq 1 ]; then
  [ "$reply_records" -eq 0 ] \
    || refuse "--no-reply is a pure acknowledgement, but delivery records exist for this request"
  disposition='no-reply'
elif [ -n "$TASK" ]; then
  META="$STATE/$TASK.meta"
  [ -f "$META" ] && [ ! -L "$META" ] || refuse "no task record for --task $TASK"
  LINKED_SLUG=$(fm_ext_meta_get "$META" ext_request_slug)
  LINKED_RID=$(fm_ext_meta_get "$META" ext_request)
  if [ "$LINKED_SLUG" != "$SLUG" ] && { [ -z "$REQUEST_ID" ] || [ "$LINKED_RID" != "$REQUEST_ID" ]; }; then
    refuse "task $TASK does not link this request"
  fi
  disposition="task:$TASK"
elif [ "$latest_receipt_ok" -eq 1 ] && [ "$latest_pending" -eq 0 ]; then
  disposition='receipt'
else
  refuse "no delivery receipt for the latest generation; a published emit is not a delivery"
fi

# Record a no-reply or dismissed disposition before removing anything, so a
# crash between the two steps leaves the request pending rather than lost.
if [ "$disposition" = 'no-reply' ] || [ "$disposition" = 'dismissed' ]; then
  NOW=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$NOW" in
    ''|*[!0-9]*) refuse "could not read the current time" ;;
  esac
  DISPOSITION_JSON=$(jq -cn \
    --arg slug "$SLUG" \
    --arg request_id "$REQUEST_ID" \
    --arg disposition "$disposition" \
    --arg reason "$REASON" \
    --argjson recorded_at "$NOW" \
    '{schema_version:1, slug:$slug, disposition:$disposition, reason:$reason, recorded_at:$recorded_at}
     + if $request_id == "" then {} else {request_id:$request_id} end') \
    || refuse "could not build the $disposition disposition"
  publish_rc=0
  printf '%s\n' "$DISPOSITION_JSON" \
    | fm_ext_private_artifact_publish_stdin_once "$OUTBOX" "$SLUG.noreply.json" 600 \
    || publish_rc=$?
  case "$publish_rc" in
    0) : ;;
    1)
      # A valid disposition from an interrupted earlier attempt is the record
      # this run needs; anything else at that path is a refusal.
      [ "$(jq -r '.disposition // empty' "$OUTBOX/$SLUG.noreply.json" 2>/dev/null)" = "$disposition" ] \
        || refuse "state/ext-outbox/$SLUG.noreply.json already exists with another disposition"
      ;;
    *) refuse "could not record the $disposition disposition" ;;
  esac
fi

fm_ext_private_artifact_remove "$INBOX" "$INBOX_RECORD" 600 \
  || refuse "could not remove state/ext-inbox/$INBOX_RECORD"

printf 'removed %s (%s)\n' "$SLUG" "$disposition"
