#!/usr/bin/env bash
# Emit one Communication Officer outbox payload (ack/answer/followup/final).
#
# Usage:
#   fm-ext-emit.sh --request-id discord:<guild>:<channel>:<thread>:<message>
#     --kind ack|answer|followup|final --generation <n>
#     (--text-file <path> | --text-file -) [--decision-file <path>]
#     [--thread-title <text>] [--thread-state needs-you|done|none]
#
# --thread-title names the request's topic thread ("<Project> · <topic>", one
# line, at most 60 characters, screened like reply text) on the reply that
# creates it; once the thread exists, later titles are recorded but do not
# replace its name. Over-long, multi-line, or unsafe titles are
# refused here instead of silently cut. --thread-state renames the existing
# topic thread: needs-you prefixes "❓ ", done prefixes "✅ ", none removes the
# prefix. Renames never block delivery; the poster applies them best effort,
# records each outcome, and retries a failed one (docs/configuration.md
# "Topic threads" owns the contract, including the needs-you auto-clear).
#
# Writes state/ext-outbox/<slug>.<kind>.<generation>.json once. Re-emitting the
# same identity is a no-op success. A posting marker without a receipt is
# refused (mid-delivery), matching public-follow-up delivery-posting behavior.
# Destination fields come from the durable per-request context, so a delayed
# follow-up still works after the inbox file is gone. The payload also carries
# the request's origin (slash, message, or button; slash when the context
# predates it), which tells the gateway poster whether it can react to the
# original message.
#
# --decision-file attaches option buttons to an answer, followup, or final.
# The file is JSON:
#   {"key": "hold:<task-id>" | "key:<task-id>:<slug>",
#    "mode": "done" | "release",
#    "options": [{"label": "<text>", "confirm": true|false}, ...]}
# with 1-5 options whose labels are distinct, 1-80 characters, and free of
# control characters, in the same order as the post text numbers them; option
# ids are 1-based in that order. "mode" (captain calls only, default done)
# chooses how a chosen option closes the call, as in fm-captain-hold.sh
# answers. The key must name a decision that is open right now (a held captain
# call, or a worker's open keyed status decision) and must fit Discord's
# 100-character custom_id as fmd:<key>:<n>. An option needs a confirmation
# click when it declares confirm, and always when its label matches
# FM_EXT_DECISION_CONFIRM_PATTERN in bin/fm-ext-lib.sh. The post text and labels
# are refused when they name the key or its task id, because only the button
# custom_ids may carry the key. The payload's decision field carries the key,
# mode, numbered options, the post text cut to its first 1000 characters, and
# the decision's current lifecycle (fm_ext_decision_key_occurrence in
# bin/fm-ext-lib.sh), so the post can only ever answer that lifecycle.
#
# Discord text is untrusted: pass it with --text-file or stdin.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-ext-emit.sh --request-id discord:<guild>:<channel>:<thread>:<message>
         --kind ack|answer|followup|final --generation <n>
         (--text-file <path> | --text-file -) [--decision-file <path>]
         [--thread-title <text>] [--thread-state needs-you|done|none]
EOF
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-ext-emit: %s\n' "$1" >&2; exit "${2:-2}"; }

REQUEST_ID=
KIND=
GENERATION=
TEXT_FILE=
DECISION_FILE=
THREAD_TITLE=
THREAD_STATE=

case "${1:-}" in
  --help|-h) help; exit 0 ;;
  '') usage; exit 2 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --request-id) shift; REQUEST_ID=${1:-} ;;
    --kind) shift; KIND=${1:-} ;;
    --generation) shift; GENERATION=${1:-} ;;
    --text-file) shift; TEXT_FILE=${1:-} ;;
    --decision-file) shift; DECISION_FILE=${1:-} ;;
    --thread-title) shift; THREAD_TITLE=${1:-} ;;
    --thread-state) shift; THREAD_STATE=${1:-} ;;
    --help|-h) help; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift || true
done

[ -n "$REQUEST_ID" ] || { usage; exit 2; }
[ -n "$KIND" ] || { usage; exit 2; }
[ -n "$GENERATION" ] || { usage; exit 2; }
[ -n "$TEXT_FILE" ] || { usage; exit 2; }

fm_ext_request_id_valid "$REQUEST_ID" || die "unsafe request_id: $REQUEST_ID"
fm_ext_reply_kind_valid "$KIND" || die "reply kind must be ack, answer, followup, or final"
fm_ext_generation_valid "$GENERATION" || die "generation must be a positive integer"
if [ -n "$THREAD_TITLE" ]; then
  THREAD_TITLE=$(printf '%s' "$THREAD_TITLE" | bash "$SCRIPT_DIR/fm-ext-topic.sh" --check-title --title-file -) \
    || die "thread title failed the shared bounds or safety check"
fi
case "${THREAD_STATE:-}" in
  ''|needs-you|done|none) ;;
  *) die "thread state must be needs-you, done, or none" ;;
esac
if [ -n "$DECISION_FILE" ]; then
  case "$KIND" in
    answer|followup|final) ;;
    *) die "a decision can only post with an answer, followup, or final" ;;
  esac
fi
fm_ext_active "$FM_HOME" || die "local ext-bridge is not active" 1
command -v jq >/dev/null 2>&1 || die "jq is required" 1

SLUG=$(fm_ext_request_slug "$REQUEST_ID") || die "could not derive request slug" 1
OUTBOX=$(fm_ext_outbox_dir)
CONTEXT_DIR=$(fm_ext_context_dir)
PAYLOAD=$(fm_ext_outbox_basename "$SLUG" "$KIND" "$GENERATION") || die "invalid outbox identity" 1
RECEIPT=$(fm_ext_outbox_receipt_basename "$SLUG" "$KIND" "$GENERATION") || die "invalid receipt identity" 1
POSTING=$(fm_ext_outbox_posting_basename "$SLUG" "$KIND" "$GENERATION") || die "invalid posting identity" 1

if fm_ext_private_artifact_file_valid "$OUTBOX" "$RECEIPT" 600; then
  printf '%s\n' "$SLUG"
  exit 0
fi
if fm_ext_private_artifact_file_valid "$OUTBOX" "$POSTING" 600 \
  && ! fm_ext_private_artifact_file_valid "$OUTBOX" "$RECEIPT" 600; then
  die "mid-delivery: $KIND generation $GENERATION is posting and has no receipt; refusing a second emit" 1
fi
if fm_ext_private_artifact_file_valid "$OUTBOX" "$PAYLOAD" 600; then
  printf '%s\n' "$SLUG"
  exit 0
fi

if [ "$TEXT_FILE" = '-' ]; then
  TEXT=$(cat)
else
  [ -f "$TEXT_FILE" ] && [ ! -L "$TEXT_FILE" ] || die "text file not found: $TEXT_FILE"
  TEXT=$(cat -- "$TEXT_FILE")
fi
[ -n "$TEXT" ] || die "text is empty"

CTX=
if fm_ext_private_artifact_file_valid "$CONTEXT_DIR" "$SLUG.json" 600; then
  CTX="$CONTEXT_DIR/$SLUG.json"
elif fm_ext_private_artifact_file_valid "$(fm_ext_inbox_dir)" "$SLUG.json" 600; then
  CTX="$(fm_ext_inbox_dir)/$SLUG.json"
else
  die "no durable destination context for request $REQUEST_ID; cannot emit after the inbox is gone without context" 1
fi

GUILD=$(jq -r '.guild_id // empty' "$CTX")
CHANNEL=$(jq -r '.channel_id // empty' "$CTX")
THREAD=$(jq -r '.thread_id // empty' "$CTX")
MESSAGE=$(jq -r '.message_id // empty' "$CTX")
PLATFORM=$(jq -r '.platform // "discord"' "$CTX")
SOURCE=$(jq -r '.source // "hermes-gateway"' "$CTX")
ORIGIN=$(jq -r '.origin // "slash"' "$CTX")
[ "$PLATFORM" = discord ] || die "context platform must be discord"
[ "$SOURCE" = hermes-gateway ] || die "context source must be hermes-gateway"
case "$ORIGIN" in
  slash|message|button) ;;
  *) die "context origin must be slash, message, or button" ;;
esac
[ -n "$GUILD" ] && [ -n "$CHANNEL" ] && [ -n "$THREAD" ] && [ -n "$MESSAGE" ] \
  || die "destination context is incomplete"

NOW=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) die "could not read the current time" 1 ;;
esac

# A decision is validated in full before anything is published, so a refused
# decision posts nothing at all.
DECISION_JSON=null
if [ -n "$DECISION_FILE" ]; then
  [ -f "$DECISION_FILE" ] && [ ! -L "$DECISION_FILE" ] || die "decision file not found: $DECISION_FILE"
  jq -e \
    --argjson max_options "$FM_EXT_DECISION_MAX_OPTIONS" \
    --argjson label_max "$FM_EXT_DECISION_LABEL_MAX" '
    type == "object"
    and (.key | type == "string")
    and ((.mode // "done") | . == "done" or . == "release")
    and (.options | type == "array" and length >= 1 and length <= $max_options)
    and all(.options[]; type == "object"
      and (.label | type == "string" and length >= 1 and length <= $label_max
        and (explode | all(. >= 32 and . != 127))
        and test("^\\S(.*\\S)?$"))
      and ((.confirm // false) | type == "boolean"))
    and ([.options[].label | ascii_downcase] | length == (unique | length))
  ' "$DECISION_FILE" >/dev/null 2>&1 \
    || die "decision file must hold {key, mode, options:[{label, confirm}]} with 1-$FM_EXT_DECISION_MAX_OPTIONS distinct labels of 1-$FM_EXT_DECISION_LABEL_MAX characters"
  DECISION_KEY=$(jq -r '.key' "$DECISION_FILE")
  DECISION_MODE=$(jq -r '.mode // "done"' "$DECISION_FILE")
  DECISION_TASK=$(fm_ext_decision_key_task "$DECISION_KEY") \
    || die "decision key must be hold:<task-id> or key:<task-id>:<slug>"
  case "$DECISION_KEY:$DECISION_MODE" in
    key:*:release) die "mode release only applies to a captain call (hold:<task-id>)" ;;
  esac
  [ "$(printf 'fmd:%s:d' "$DECISION_KEY" | wc -c)" -le "$FM_EXT_DECISION_CUSTOM_ID_MAX" ] \
    || die "decision key is too long for a Discord button; post the numbered text without buttons"
  # Public safety: the post and its labels are public; only the custom_ids
  # carry the key.
  if { printf '%s\n' "$TEXT"; jq -r '.options[].label' "$DECISION_FILE"; } \
    | grep -qiF -e "$DECISION_TASK" -e "$DECISION_KEY"; then
    die "decision post text and labels must not name the decision key or its task id"
  fi
  DECISION_STATE=$(fm_ext_decision_key_state "$DECISION_KEY") \
    || die "decision key is malformed"
  case "$DECISION_STATE" in
    open) ;;
    unknown) die "could not read whether decision $DECISION_KEY is open" 1 ;;
    *) die "decision $DECISION_KEY is $DECISION_STATE; only an open decision can post buttons" ;;
  esac
  # The post belongs to this lifecycle of the decision only: a click after the
  # call is re-held or the key reopened is a no-op.
  DECISION_OCCURRENCE=$(fm_ext_decision_key_occurrence "$DECISION_KEY") \
    || die "could not read which lifecycle of decision $DECISION_KEY is open" 1
  DECISION_JSON=$(jq -c \
    --arg pattern "$FM_EXT_DECISION_CONFIRM_PATTERN" \
    --arg mode "$DECISION_MODE" \
    --arg occurrence "$DECISION_OCCURRENCE" \
    --arg text "$TEXT" \
    --argjson text_max "$FM_EXT_DECISION_TEXT_MAX" '
    {key, mode: $mode, occurrence: $occurrence,
     options: [.options | to_entries[] | {"id": (.key + 1), "label": .value.label,
       "confirm": ((.value.confirm // false) or (.value.label | test($pattern; "i")))}],
     text: (if ($text | length) > $text_max
            then ($text | .[0:$text_max]) + "…" else $text end)}
  ' "$DECISION_FILE") || die "could not build the decision payload" 1
fi

OUTBOX_JSON=$(jq -cn \
  --argjson schema_version "$FM_EXT_SCHEMA_VERSION" \
  --arg request_id "$REQUEST_ID" \
  --arg slug "$SLUG" \
  --arg kind "$KIND" \
  --argjson generation "$GENERATION" \
  --arg platform "$PLATFORM" \
  --arg source "$SOURCE" \
  --arg guild_id "$GUILD" \
  --arg channel_id "$CHANNEL" \
  --arg thread_id "$THREAD" \
  --arg message_id "$MESSAGE" \
  --arg origin "$ORIGIN" \
  --arg text "$TEXT" \
  --arg thread_title "$THREAD_TITLE" \
  --arg thread_state "$THREAD_STATE" \
  --argjson decision "$DECISION_JSON" \
  --argjson recorded_at "$NOW" \
  '{schema_version:$schema_version, request_id:$request_id, slug:$slug,
    kind:$kind, generation:$generation, platform:$platform, source:$source,
    guild_id:$guild_id, channel_id:$channel_id, thread_id:$thread_id,
    message_id:$message_id, origin:$origin, text:$text,
    recorded_at:$recorded_at}
   + if $thread_title == "" then {} else {thread_title:$thread_title} end
   + if $thread_state == "" then {} else {thread_state:$thread_state} end
   + if $decision == null then {} else {decision:$decision} end') \
  || die "could not build the outbox payload" 1

printf '%s\n' "$OUTBOX_JSON" \
  | fm_ext_private_artifact_publish_stdin_once "$OUTBOX" "$PAYLOAD" 600
case $? in
  0|1)
    if ! fm_ext_outbox_schema_valid "$OUTBOX/$PAYLOAD"; then
      die "published outbox payload failed schema validation" 1
    fi
    printf '%s\n' "$SLUG"
    ;;
  *) die "could not publish the outbox payload" 1 ;;
esac
