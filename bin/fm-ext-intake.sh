#!/usr/bin/env bash
# Publish one Communication Officer request into the local ext-bridge inbox.
#
# Usage:
#   fm-ext-intake.sh --request-id discord:<guild>:<channel>:<thread>:<message>
#     --guild-id <id> --channel-id <id> --thread-id <id> --message-id <id>
#     --author <id> --secret-file <path>
#     (--text-file <path> | --text-file -)
#     [--platform discord] [--source hermes-gateway] [--no-wake]
#     [--origin slash|message]
#     [--reply-to-message-id <id> [--reply-to-request-id <request_id>]
#      [--reply-to-text-file <path>]]
#     [--attachment-manifest <path>]
#
# Opt-in is config/ext-bridge plus a mode-0600 home secret. FM_EXT_BRIDGE can
# only turn a configured bridge off, never on. The presented --secret-file must
# match that secret. Missing, empty, comments-only, symlinked, or unmatched
# allowlist writes nothing and exits 3.
#
# The recorded request carries the authority its matching rule grants:
# "standing" only from a <guild>:<channel>:<author> rule, and "confirm" from a
# broader guild-only or channel-only rule, whose requests need the captain's
# confirmation before any project-changing action.
#
# --origin records how the request arrived: "slash" (the default) for a /fm
# command interaction, "message" for an ordinary Discord message, which is the
# only kind the gateway can add reactions to. --reply-to-message-id marks a
# request that answers one of Firstmate's own posted Discord messages: the
# inbox record then carries reply_to {message_id, request_id, text}, with that
# message's text cut to its first 1000 characters (a trailing ellipsis marks a
# cut), so Firstmate can tell what a short answer such as "yes" refers to.
# Neither field changes admission or authority.
#
# --attachment-manifest points at a JSON array of {path, media_type, name}
# entries for the gateway's locally cached Discord attachments. Admitted files
# are copied into state/ext-attachments/<slug>/ (mode 0700 dir, 0600 files)
# and listed in the inbox record as attachments [{name, path, media_type,
# bytes}]; the rest are listed as skipped_attachments [{name, reason}] and
# never fetched or followed. The per-file byte cap is FM_EXT_ATTACHMENT_MAX_BYTES
# (default 33554432) and the per-request count cap is FM_EXT_ATTACHMENT_MAX_COUNT
# (default 10). Only regular files are copied: symlinks, remote URLs, and
# path-like names are skipped, and an unknown media type is kept as
# application/octet-stream. The manifest never changes admission or authority:
# a non-allowlisted author copies nothing, and an attachment-only message
# (empty text) is still recorded when a manifest entry is present.
#
# Idempotent: the same message id claims the existing offer and does not
# append a second wake. If the wake cannot be appended, the offer marker is
# removed so a later intake or poll can retry. Canonical request_id keeps
# colons in the JSON body; the inbox filename is the SHA-256 slug of that id.
#
# Discord text is untrusted: pass it with --text-file or stdin, never by
# interpolating it into a shell command.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-ext-intake.sh --request-id discord:<guild>:<channel>:<thread>:<message>
         --guild-id <id> --channel-id <id> --thread-id <id> --message-id <id>
         --author <id> --secret-file <path>
         (--text-file <path> | --text-file -)
         [--platform discord] [--source hermes-gateway] [--no-wake]
         [--origin slash|message]
         [--reply-to-message-id <id> [--reply-to-request-id <request_id>]
          [--reply-to-text-file <path>]]
         [--attachment-manifest <path>]
EOF
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-ext-intake: %s\n' "$1" >&2; exit "${2:-2}"; }

REQUEST_ID=
GUILD_ID=
CHANNEL_ID=
THREAD_ID=
MESSAGE_ID=
AUTHOR=
SECRET_FILE=
TEXT_FILE=
PLATFORM=discord
SOURCE=hermes-gateway
WAKE=1
ORIGIN=slash
REPLY_MESSAGE_ID=
REPLY_REQUEST_ID=
REPLY_TEXT_FILE=
ATTACHMENT_MANIFEST=
# Longest replied-to text kept in a request's reply_to context, in characters.
REPLY_TEXT_MAX=1000

case "${1:-}" in
  --help|-h) help; exit 0 ;;
  '') usage; exit 2 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --request-id) shift; REQUEST_ID=${1:-} ;;
    --guild-id) shift; GUILD_ID=${1:-} ;;
    --channel-id) shift; CHANNEL_ID=${1:-} ;;
    --thread-id) shift; THREAD_ID=${1:-} ;;
    --message-id) shift; MESSAGE_ID=${1:-} ;;
    --author) shift; AUTHOR=${1:-} ;;
    --secret-file) shift; SECRET_FILE=${1:-} ;;
    --text-file) shift; TEXT_FILE=${1:-} ;;
    --platform) shift; PLATFORM=${1:-} ;;
    --source) shift; SOURCE=${1:-} ;;
    --no-wake) WAKE=0 ;;
    --origin) shift; ORIGIN=${1:-} ;;
    --reply-to-message-id) shift; REPLY_MESSAGE_ID=${1:-} ;;
    --reply-to-request-id) shift; REPLY_REQUEST_ID=${1:-} ;;
    --reply-to-text-file) shift; REPLY_TEXT_FILE=${1:-} ;;
    --attachment-manifest) shift; ATTACHMENT_MANIFEST=${1:-} ;;
    --help|-h) help; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift || true
done

[ -n "$REQUEST_ID" ] || { usage; exit 2; }
[ -n "$GUILD_ID" ] || { usage; exit 2; }
[ -n "$CHANNEL_ID" ] || { usage; exit 2; }
[ -n "$THREAD_ID" ] || { usage; exit 2; }
[ -n "$MESSAGE_ID" ] || { usage; exit 2; }
[ -n "$AUTHOR" ] || { usage; exit 2; }
[ -n "$SECRET_FILE" ] || { usage; exit 2; }
[ -n "$TEXT_FILE" ] || { usage; exit 2; }

[ "$PLATFORM" = discord ] || die "platform must be discord, got '$PLATFORM'"
[ "$SOURCE" = hermes-gateway ] || die "source must be hermes-gateway, got '$SOURCE'"
fm_ext_request_id_valid "$REQUEST_ID" || die "unsafe request_id: $REQUEST_ID"
EXPECTED_RID="discord:${GUILD_ID}:${CHANNEL_ID}:${THREAD_ID}:${MESSAGE_ID}"
[ "$REQUEST_ID" = "$EXPECTED_RID" ] \
  || die "request_id does not match guild/channel/thread/message fields"

case "$ORIGIN" in
  slash|message) ;;
  *) die "origin must be slash or message, got '$ORIGIN'" ;;
esac
if [ -n "$REPLY_MESSAGE_ID" ]; then
  case "$REPLY_MESSAGE_ID" in
    *[!0-9]*) die "reply-to message id must be a Discord id, got '$REPLY_MESSAGE_ID'" ;;
  esac
  if [ -n "$REPLY_REQUEST_ID" ]; then
    fm_ext_request_id_valid "$REPLY_REQUEST_ID" || die "unsafe reply-to request_id: $REPLY_REQUEST_ID"
  fi
elif [ -n "$REPLY_REQUEST_ID$REPLY_TEXT_FILE" ]; then
  die "--reply-to-request-id and --reply-to-text-file need --reply-to-message-id"
fi

fm_ext_active "$FM_HOME" || die "local ext-bridge is not active (need config/ext-bridge plus a mode-0600 secret)" 1
HOME_SECRET=$(fm_ext_secret_path "$FM_HOME")
fm_ext_secret_matches "$HOME_SECRET" "$SECRET_FILE" \
  || die "presented secret does not match the home secret" 1

ALLOWLIST=$(fm_ext_allowlist_path "$FM_HOME")
# Exit 3 is reserved for an allowlist refusal so the gateway can tell "not
# allowed" apart from "the bridge is broken" without parsing a message, and
# without keeping a second copy of the allowlist grammar.
AUTHORITY=$(fm_ext_authority "$ALLOWLIST" "$GUILD_ID" "$CHANNEL_ID" "$AUTHOR") \
  || die "request is not allowlisted" 3

command -v jq >/dev/null 2>&1 || die "jq is required" 1

if [ "$TEXT_FILE" = '-' ]; then
  TEXT=$(cat)
else
  [ -f "$TEXT_FILE" ] && [ ! -L "$TEXT_FILE" ] || die "text file not found: $TEXT_FILE"
  TEXT=$(cat -- "$TEXT_FILE")
fi
MANIFEST_PRESENT=0
if [ -n "$ATTACHMENT_MANIFEST" ]; then
  [ -f "$ATTACHMENT_MANIFEST" ] && [ ! -L "$ATTACHMENT_MANIFEST" ] \
    || die "attachment manifest not found: $ATTACHMENT_MANIFEST"
  MANIFEST_PRESENT=1
fi
[ -n "$TEXT" ] || [ "$MANIFEST_PRESENT" = 1 ] || die "text is empty"

REPLY_TEXT=
if [ -n "$REPLY_TEXT_FILE" ]; then
  [ -f "$REPLY_TEXT_FILE" ] && [ ! -L "$REPLY_TEXT_FILE" ] \
    || die "reply-to text file not found: $REPLY_TEXT_FILE"
  REPLY_TEXT=$(cat -- "$REPLY_TEXT_FILE")
fi

SLUG=$(fm_ext_request_slug "$REQUEST_ID") || die "could not derive request slug" 1
NOW=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) die "could not read the current time" 1 ;;
esac

ATTACH_KEPT_JSON='[]'
ATTACH_SKIPPED_JSON='[]'

INBOX_JSON=$(jq -cn \
  --argjson schema_version "$FM_EXT_SCHEMA_VERSION" \
  --arg request_id "$REQUEST_ID" \
  --arg slug "$SLUG" \
  --arg platform "$PLATFORM" \
  --arg source "$SOURCE" \
  --arg guild_id "$GUILD_ID" \
  --arg channel_id "$CHANNEL_ID" \
  --arg thread_id "$THREAD_ID" \
  --arg message_id "$MESSAGE_ID" \
  --arg author "$AUTHOR" \
  --arg authority "$AUTHORITY" \
  --arg origin "$ORIGIN" \
  --arg text "$TEXT" \
  --arg reply_message_id "$REPLY_MESSAGE_ID" \
  --arg reply_request_id "$REPLY_REQUEST_ID" \
  --arg reply_text "$REPLY_TEXT" \
  --argjson reply_max "$REPLY_TEXT_MAX" \
  --argjson recorded_at "$NOW" \
  --argjson attachments "$ATTACH_KEPT_JSON" \
  --argjson skipped_attachments "$ATTACH_SKIPPED_JSON" \
  '{schema_version:$schema_version, request_id:$request_id, slug:$slug,
    platform:$platform, source:$source, guild_id:$guild_id,
    channel_id:$channel_id, thread_id:$thread_id, message_id:$message_id,
    author:$author, authority:$authority, origin:$origin, text:$text,
    recorded_at:$recorded_at,
    attachments:$attachments, skipped_attachments:$skipped_attachments}
   + if $reply_message_id == "" then {} else
       {reply_to: ({message_id:$reply_message_id,
         text: (if ($reply_text | length) > $reply_max
                then ($reply_text | .[0:$reply_max]) + "…"
                else $reply_text end)}
         + if $reply_request_id == "" then {} else {request_id:$reply_request_id} end)}
     end') \
  || die "could not build the inbox record" 1

CONTEXT_JSON=$(jq -cn \
  --arg request_id "$REQUEST_ID" \
  --arg slug "$SLUG" \
  --arg platform "$PLATFORM" \
  --arg source "$SOURCE" \
  --arg guild_id "$GUILD_ID" \
  --arg channel_id "$CHANNEL_ID" \
  --arg thread_id "$THREAD_ID" \
  --arg message_id "$MESSAGE_ID" \
  --arg author "$AUTHOR" \
  --arg authority "$AUTHORITY" \
  --arg origin "$ORIGIN" \
  --argjson recorded_at "$NOW" \
  '{request_id:$request_id, slug:$slug, platform:$platform, source:$source,
    guild_id:$guild_id, channel_id:$channel_id, thread_id:$thread_id,
    message_id:$message_id, author:$author, authority:$authority,
    origin:$origin, recorded_at:$recorded_at}') \
  || die "could not build the destination context" 1

INBOX_DIR=$(fm_ext_inbox_dir)
CONTEXT_DIR=$(fm_ext_context_dir)
ATTACH_DIR=

if fm_ext_private_artifact_file_valid "$CONTEXT_DIR" "$SLUG.offered.json" 600; then
  printf '%s\n' "$SLUG"
  exit 0
fi

if [ "$MANIFEST_PRESENT" = 1 ]; then
  if ! ATTACH_DIR=$(fm_ext_private_request_dir_prepare "$STATE" "$FM_EXT_ATTACHMENTS_DIRNAME" "$SLUG"); then
    die "could not prepare the attachment folder" 1
  fi
  if ! ATTACH_OUT=$(fm_ext_attachments_stage "$ATTACH_DIR" "$ATTACHMENT_MANIFEST"); then
    rm -rf -- "$ATTACH_DIR" 2>/dev/null || true
    die "could not read the attachment manifest" 1
  fi
  ATTACH_KEPT_JSON=$(printf '%s\n' "$ATTACH_OUT" | jq -c '[.kept[] | {name, path: (.staged | split("/") | last), media_type, bytes}]') \
    || ATTACH_KEPT_JSON='[]'
  ATTACH_SKIPPED_JSON=$(printf '%s\n' "$ATTACH_OUT" | jq -c '.skipped') || ATTACH_SKIPPED_JSON='[]'
  INBOX_JSON=$(printf '%s\n' "$INBOX_JSON" | jq -c --argjson kept "$ATTACH_KEPT_JSON" --argjson skipped "$ATTACH_SKIPPED_JSON" --arg dir "$ATTACH_DIR" '
    .attachments = [$kept[] | {name, path: ($dir + "/" + .path), media_type, bytes}]
    | .skipped_attachments = $skipped
  ') || {
    rm -rf -- "$ATTACH_DIR" 2>/dev/null || true
    die "could not record the attachments" 1
  }
fi

printf '%s\n' "$INBOX_JSON" \
  | fm_ext_private_artifact_publish_stdin "$INBOX_DIR" "$SLUG.json" 600 \
  || {
    [ -z "$ATTACH_DIR" ] || rm -rf -- "$ATTACH_DIR" 2>/dev/null || true
    die "could not write inbox" 1
  }

printf '%s\n' "$CONTEXT_JSON" \
  | fm_ext_private_artifact_publish_stdin "$CONTEXT_DIR" "$SLUG.json" 600 \
  || {
    [ -z "$ATTACH_DIR" ] || rm -rf -- "$ATTACH_DIR" 2>/dev/null || true
    die "could not write destination context" 1
  }

fm_ext_offer_registry_claim "$STATE" "$SLUG" "$REQUEST_ID"
offer_rc=$?
case "$offer_rc" in
  0)
    if [ "$WAKE" = 1 ]; then
      if ! fm_wake_append check "$(fm_ext_wake_key ext-request "$SLUG")" "ext-request $SLUG"; then
        if ! fm_ext_offer_registry_unclaim "$STATE" "$SLUG"; then
          [ -z "$ATTACH_DIR" ] || rm -rf -- "$ATTACH_DIR" 2>/dev/null || true
          die "could not append the wake, and the offer marker could not be released" 1
        fi
        [ -z "$ATTACH_DIR" ] || rm -rf -- "$ATTACH_DIR" 2>/dev/null || true
        die "could not append the wake" 1
      fi
    fi
    ;;
  1) ;;
  *) {
    [ -z "$ATTACH_DIR" ] || rm -rf -- "$ATTACH_DIR" 2>/dev/null || true
    die "could not claim the offer marker" 1
  } ;;
esac

printf '%s\n' "$SLUG"
