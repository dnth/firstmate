#!/usr/bin/env bash
# Publish one Communication Officer request into the local ext-bridge inbox.
#
# Usage:
#   fm-ext-intake.sh --request-id discord:<guild>:<channel>:<thread>:<message>
#     --guild-id <id> --channel-id <id> --thread-id <id> --message-id <id>
#     --author <id> --secret-file <path>
#     (--text-file <path> | --text-file -)
#     [--platform discord] [--source hermes-gateway] [--no-wake]
#
# Opt-in is config/ext-bridge or FM_EXT_BRIDGE=1 plus a mode-0600 home secret.
# The presented --secret-file must match that secret. Missing or empty
# allowlist, or a request that matches no rule, writes nothing.
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

fm_ext_active "$FM_HOME" || die "local ext-bridge is not active (need config/ext-bridge or FM_EXT_BRIDGE=1 plus a mode-0600 secret)" 1
HOME_SECRET=$(fm_ext_secret_path "$FM_HOME")
fm_ext_secret_matches "$HOME_SECRET" "$SECRET_FILE" \
  || die "presented secret does not match the home secret" 1

ALLOWLIST=$(fm_ext_allowlist_path "$FM_HOME")
fm_ext_allowlisted "$ALLOWLIST" "$GUILD_ID" "$CHANNEL_ID" "$AUTHOR" \
  || die "request is not allowlisted" 1

command -v jq >/dev/null 2>&1 || die "jq is required" 1

if [ "$TEXT_FILE" = '-' ]; then
  TEXT=$(cat)
else
  [ -f "$TEXT_FILE" ] && [ ! -L "$TEXT_FILE" ] || die "text file not found: $TEXT_FILE"
  TEXT=$(cat -- "$TEXT_FILE")
fi
[ -n "$TEXT" ] || die "text is empty"

SLUG=$(fm_ext_request_slug "$REQUEST_ID") || die "could not derive request slug" 1
NOW=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) die "could not read the current time" 1 ;;
esac

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
  --arg text "$TEXT" \
  --argjson recorded_at "$NOW" \
  '{schema_version:$schema_version, request_id:$request_id, slug:$slug,
    platform:$platform, source:$source, guild_id:$guild_id,
    channel_id:$channel_id, thread_id:$thread_id, message_id:$message_id,
    author:$author, text:$text, recorded_at:$recorded_at}') \
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
  --argjson recorded_at "$NOW" \
  '{request_id:$request_id, slug:$slug, platform:$platform, source:$source,
    guild_id:$guild_id, channel_id:$channel_id, thread_id:$thread_id,
    message_id:$message_id, author:$author, recorded_at:$recorded_at}') \
  || die "could not build the destination context" 1

INBOX_DIR=$(fm_ext_inbox_dir)
CONTEXT_DIR=$(fm_ext_context_dir)

if fm_ext_private_artifact_file_valid "$CONTEXT_DIR" "$SLUG.offered.json" 600; then
  printf '%s\n' "$SLUG"
  exit 0
fi

printf '%s\n' "$INBOX_JSON" \
  | fm_ext_private_artifact_publish_stdin "$INBOX_DIR" "$SLUG.json" 600 \
  || die "could not write inbox" 1

printf '%s\n' "$CONTEXT_JSON" \
  | fm_ext_private_artifact_publish_stdin "$CONTEXT_DIR" "$SLUG.json" 600 \
  || die "could not write destination context" 1

fm_ext_offer_registry_claim "$STATE" "$SLUG" "$REQUEST_ID"
offer_rc=$?
case "$offer_rc" in
  0)
    if [ "$WAKE" = 1 ]; then
      if ! fm_wake_append check "$FM_EXT_WATCH_SHIM" "ext-request $SLUG"; then
        if ! fm_ext_offer_registry_unclaim "$STATE" "$SLUG"; then
          die "could not append the wake, and the offer marker could not be released" 1
        fi
        die "could not append the wake" 1
      fi
    fi
    ;;
  1) ;;
  *) die "could not claim the offer marker" 1 ;;
esac

printf '%s\n' "$SLUG"
