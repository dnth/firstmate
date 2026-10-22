#!/usr/bin/env bash
# Open a new Communication Officer topic thread that no captain request started.
#
# Usage:
#   fm-ext-open.sh --key <key> --thread-title <text>
#     (--text-file <path> | --text-file -) [--thread-state needs-you|done|none]
#     [--media <path>]...
#   fm-ext-open.sh --key <key> --lookup
#
# Firstmate opens one titled thread in the dedicated channel (config/ext-channel)
# and posts its first message there through the ordinary outbox and gateway
# poster. --key is a private stable name for the tracked item, 1-80 characters,
# starting with a letter or digit and otherwise containing letters, digits,
# dot, underscore, or dash; it never reaches Discord.
# The same key always maps to the same request id,
#   discord:<guild>:<channel>:<channel>:<synthetic>
# whose last part is derived from the key, so re-running a recorded open is a no-op
# and a posting marker without a receipt refuses exactly as fm-ext-emit.sh
# does. The guild is the one valid allowlist rules name for the dedicated channel;
# no valid allowlist rule for that channel, or rules naming more than one guild,
# refuses. There is no channel argument: only the dedicated channel can host
# an opened thread, and the poster re-checks that before creating it.
#
# --thread-title is required and goes through bin/fm-ext-topic.sh --check-title,
# the same bounds and safety screen as an emitted title; an opened thread has
# no request text to fall back to. The first message is the request's
# answer generation 1, so later posts use bin/fm-ext-emit.sh with the printed
# request id and --kind followup or final from generation 1, including
# --thread-state renames. A captain reply inside the thread is an ordinary
# in-thread request. --media attaches screened media to that first message
# exactly as bin/fm-ext-emit.sh --media does; its header owns the rules.
#
# On success the request id is printed on stdout and the open is recorded in
# state/ext-context/<slug>.json (origin "open", open_key <key>), which keeps it
# addressable for the bridge retention window. The key stays bound to its
# thread while any bridge records remain; reopening with that key returns
# that thread.
#
# --lookup prints the key's request id and the first message's delivery on a
# second line: "pending", "posted thread=<id> messages=<id>[,<id>...]", or
# "failed <reason>". It exits 1 when the key has no recorded open.
# docs/configuration.md "Topic threads" owns the routing contract.
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
usage: fm-ext-open.sh --key <key> --thread-title <text>
         (--text-file <path> | --text-file -) [--thread-state needs-you|done|none]
         [--media <path>]...
       fm-ext-open.sh --key <key> --lookup
EOF
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-ext-open: %s\n' "$1" >&2; exit "${2:-2}"; }

KEY=
TITLE=
TEXT_FILE=
THREAD_STATE=
LOOKUP=0
MEDIA_ARGS=()

case "${1:-}" in
  --help|-h) help; exit 0 ;;
  '') usage; exit 2 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --key) shift; KEY=${1:-} ;;
    --thread-title) shift; TITLE=${1:-} ;;
    --text-file) shift; TEXT_FILE=${1:-} ;;
    --thread-state) shift; THREAD_STATE=${1:-} ;;
    --lookup) LOOKUP=1 ;;
    --media) shift; [ -n "${1:-}" ] || die "--media needs a file path"; MEDIA_ARGS+=(--media "$1") ;;
    --help|-h) help; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift || true
done

[ -n "$KEY" ] || { usage; exit 2; }
printf '%s' "$KEY" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' \
  || die "key must be 1-80 letters, digits, dots, underscores, or dashes"
if [ "$LOOKUP" = 0 ]; then
  [ -n "$TITLE" ] || die "an opened thread needs --thread-title"
  [ -n "$TEXT_FILE" ] || { usage; exit 2; }
  TITLE=$(printf '%s' "$TITLE" | bash "$SCRIPT_DIR/fm-ext-topic.sh" --check-title --title-file -) \
    || die "thread title failed the shared bounds or safety check"
fi
fm_ext_active "$FM_HOME" || die "local ext-bridge is not active" 1
command -v jq >/dev/null 2>&1 || die "jq is required" 1

# The gateway plugin owns reading config/ext-channel; reusing it keeps this
# script and the poster agreed on which channel is dedicated.
CHANNEL=$(python3 -c '
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "contrib/hermes-gateway-firstmate-comms"))
from intake import dedicated_channel
print(dedicated_channel(Path(sys.argv[2])))
' "$FM_ROOT" "$FM_HOME" 2>/dev/null)
case "$CHANNEL" in
  ''|*[!0-9]*) die "no dedicated channel is configured; an opened thread needs exactly one id in config/ext-channel" 1 ;;
esac

# The allowlist is the only record of which guild owns the dedicated channel.
GUILDS=$(fm_ext_allowlist_read "$(fm_ext_allowlist_path)" 2>/dev/null \
  | while IFS= read -r rule; do
      [[ "$rule" == *:* ]] || continue
      rule_guild=${rule%%:*}
      [[ -n "$rule_guild" && "$rule_guild" != *[!0-9]* ]] || continue
      fm_ext_rule_authority "$rule" "$rule_guild" "$CHANNEL" "${rule##*:}" >/dev/null \
        && printf '%s\n' "$rule_guild"
    done \
  | sort -u)
case "$(printf '%s\n' "$GUILDS" | grep -c .)" in
  1) GUILD=$GUILDS ;;
  0) die "the allowlist names no guild for the dedicated channel" 1 ;;
  *) die "the allowlist names more than one guild for the dedicated channel" 1 ;;
esac

HASH=$(printf 'fm-ext-open:%s:%s:%s' "$GUILD" "$CHANNEL" "$KEY" | fm_ext_sha256) \
  || die "could not hash the key" 1
SYNTHETIC=$((16#${HASH:0:15}))
REQUEST_ID="discord:${GUILD}:${CHANNEL}:${CHANNEL}:${SYNTHETIC}"
fm_ext_request_id_valid "$REQUEST_ID" || die "could not derive a request id" 1
SLUG=$(fm_ext_request_slug "$REQUEST_ID") || die "could not derive request slug" 1
CONTEXT_DIR=$(fm_ext_context_dir)

context_is_this_open() {
  fm_ext_private_artifact_file_valid "$CONTEXT_DIR" "$SLUG.json" 600 \
    && jq -e --arg rid "$REQUEST_ID" --arg key "$KEY" \
      '.request_id == $rid and .origin == "open" and .open_key == $key' \
      "$CONTEXT_DIR/$SLUG.json" >/dev/null 2>&1
}

if [ "$LOOKUP" = 1 ]; then
  context_is_this_open || die "no thread is recorded as opened for this key" 1
  printf '%s\n' "$REQUEST_ID"
  OUTBOX=$(fm_ext_outbox_dir)
  RECEIPT=$(fm_ext_outbox_receipt_basename "$SLUG" answer 1) || die "invalid receipt identity" 1
  FAILED=$(fm_ext_outbox_failed_basename "$SLUG" answer 1) || die "invalid failure identity" 1
  if fm_ext_private_artifact_file_valid "$OUTBOX" "$RECEIPT" 600; then
    jq -r '"posted thread=\(.thread_id // "") messages=\((.discord_message_ids // [.discord_message_id]) | map(tostring) | join(","))"' \
      "$OUTBOX/$RECEIPT" || die "could not read the receipt" 1
  elif fm_ext_private_artifact_file_valid "$OUTBOX" "$FAILED" 600; then
    jq -r '"failed \(.reason // "unknown reason")"' "$OUTBOX/$FAILED" || die "could not read the failure" 1
  else
    printf 'pending\n'
  fi
  exit 0
fi

NOW=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) die "could not read the current time" 1 ;;
esac

# The context is the open's durable record and the destination every later
# emit reads; publishing it once keeps the first title and key.
CONTEXT_JSON=$(jq -cn \
  --arg request_id "$REQUEST_ID" \
  --arg slug "$SLUG" \
  --arg guild_id "$GUILD" \
  --arg channel_id "$CHANNEL" \
  --arg message_id "$SYNTHETIC" \
  --arg key "$KEY" \
  --arg topic "$TITLE" \
  --argjson recorded_at "$NOW" \
  '{request_id:$request_id, slug:$slug, platform:"discord", source:"hermes-gateway",
    guild_id:$guild_id, channel_id:$channel_id, thread_id:$channel_id,
    message_id:$message_id, origin:"open", open_key:$key,
    topic:$topic, request_text:"", recorded_at:$recorded_at}') \
  || die "could not build the open record" 1
printf '%s\n' "$CONTEXT_JSON" \
  | fm_ext_private_artifact_publish_stdin_once "$CONTEXT_DIR" "$SLUG.json" 600
case $? in
  0|1) ;;
  *) die "could not record the open" 1 ;;
esac
context_is_this_open || die "the recorded context for this key is not an opened thread" 1

set -- --request-id "$REQUEST_ID" --kind answer --generation 1 \
  --text-file "$TEXT_FILE" --thread-title "$TITLE"
[ -z "$THREAD_STATE" ] || set -- "$@" --thread-state "$THREAD_STATE"
[ "${#MEDIA_ARGS[@]}" -eq 0 ] || set -- "$@" "${MEDIA_ARGS[@]}"
bash "$SCRIPT_DIR/fm-ext-emit.sh" "$@" >/dev/null || exit $?
printf '%s\n' "$REQUEST_ID"
