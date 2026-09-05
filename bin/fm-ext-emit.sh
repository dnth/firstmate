#!/usr/bin/env bash
# Emit one Communication Officer outbox payload (ack/answer/followup/final).
#
# Usage:
#   fm-ext-emit.sh --request-id discord:<guild>:<channel>:<thread>:<message>
#     --kind ack|answer|followup|final --generation <n>
#     (--text-file <path> | --text-file -)
#
# Writes state/ext-outbox/<slug>.<kind>.<generation>.json once. Re-emitting the
# same identity is a no-op success. A posting marker without a receipt is
# refused (mid-delivery), matching public-follow-up delivery-posting behavior.
# Destination fields come from the durable per-request context, so a delayed
# follow-up still works after the inbox file is gone.
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
         (--text-file <path> | --text-file -)
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
fm_ext_kind_valid "$KIND" || die "kind must be ack, answer, followup, or final"
fm_ext_generation_valid "$GENERATION" || die "generation must be a positive integer"
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
[ "$PLATFORM" = discord ] || die "context platform must be discord"
[ "$SOURCE" = hermes-gateway ] || die "context source must be hermes-gateway"
[ -n "$GUILD" ] && [ -n "$CHANNEL" ] && [ -n "$THREAD" ] && [ -n "$MESSAGE" ] \
  || die "destination context is incomplete"

NOW=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) die "could not read the current time" 1 ;;
esac

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
  --arg text "$TEXT" \
  --argjson recorded_at "$NOW" \
  '{schema_version:$schema_version, request_id:$request_id, slug:$slug,
    kind:$kind, generation:$generation, platform:$platform, source:$source,
    guild_id:$guild_id, channel_id:$channel_id, thread_id:$thread_id,
    message_id:$message_id, text:$text, recorded_at:$recorded_at}') \
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
