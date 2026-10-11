#!/usr/bin/env bash
# Derive one public-safe Discord thread name for a Communication Officer request.
#
# Usage:
#   fm-ext-topic.sh --text-file <path> --origin slash|message
#     --thread-id <id> --channel-id <id> --message-id <id> [--validate-name]
#
# Prints one fixed public label: Aceh, InfoConnect, Firstmate, Question, or
# Firstmate request, followed by the source message's MYT time as HH:MM.
# Matching selects a label but never copies request words into the name.
# Only top-level message requests in config/ext-channel receive a name.
# Slash requests, existing threads, and other channels print nothing.
# --message-id supplies the Discord snowflake containing the message timestamp.
# --validate-name checks a stored name against the same closed list and time;
# an invalid name becomes the fixed fallback with the message time.
# Admission and authority stay owned by bin/fm-ext-intake.sh.
set -u

usage() {
  echo "usage: fm-ext-topic.sh --text-file <path> --origin slash|message --thread-id <id> --channel-id <id> --message-id <id> [--validate-name]" >&2
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-ext-topic: %s\n' "$1" >&2; exit "${2:-2}"; }

TEXT_FILE=
ORIGIN=
THREAD_ID=
CHANNEL_ID=
MESSAGE_ID=
VALIDATE=0

case "${1:-}" in
  --help|-h) help; exit 0 ;;
  '') usage; exit 2 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --text-file) shift; TEXT_FILE=${1:-} ;;
    --origin) shift; ORIGIN=${1:-} ;;
    --thread-id) shift; THREAD_ID=${1:-} ;;
    --channel-id) shift; CHANNEL_ID=${1:-} ;;
    --message-id) shift; MESSAGE_ID=${1:-} ;;
    --validate-name) VALIDATE=1 ;;
    --help|-h) help; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift || true
done

[ -n "$TEXT_FILE" ] || { usage; exit 2; }
[ -n "$ORIGIN" ] || { usage; exit 2; }
[ -n "$THREAD_ID" ] || { usage; exit 2; }
[ -n "$CHANNEL_ID" ] || { usage; exit 2; }
case "$MESSAGE_ID" in
  ''|*[!0-9]*) die "message id must be a Discord id" ;;
esac

case "$ORIGIN" in
  slash|message) ;;
  *) die "origin must be slash or message" ;;
esac

# A request that already arrived inside a thread stays in that thread: there is
# nothing to name, so print nothing and succeed.
if [ "$ORIGIN" != message ] || [ "$THREAD_ID" != "$CHANNEL_ID" ]; then
  exit 0
fi

if [ "$TEXT_FILE" = '-' ]; then
  TEXT=$(cat)
else
  [ -f "$TEXT_FILE" ] && [ ! -L "$TEXT_FILE" ] || die "text file not found: $TEXT_FILE"
  TEXT=$(cat -- "$TEXT_FILE")
fi

FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
python3 - "$FM_ROOT" "$FM_HOME" "$CHANNEL_ID" "$MESSAGE_ID" "$VALIDATE" 3<<< "$TEXT" <<'PY'
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "contrib/hermes-gateway-firstmate-comms"))
from intake import dedicated_channel
if dedicated_channel(Path(sys.argv[2])) != sys.argv[3]:
    sys.exit(0)
text = os.fdopen(3).read().strip()
message_ms = (int(sys.argv[4]) >> 22) + 1420070400000
clock = datetime.fromtimestamp(message_ms / 1000, timezone(timedelta(hours=8))).strftime("%H:%M")
labels = {"aceh": "Aceh", "infoconnect": "InfoConnect", "firstmate": "Firstmate", "question": "Question"}
fallback = "Firstmate request"
if sys.argv[5] == "1":
    allowed = {label + " " + clock for label in (*labels.values(), fallback)}
    print(text if text in allowed else fallback + " " + clock)
else:
    words = set(text.casefold().split())
    label = next((label for word, label in labels.items() if word in words), fallback)
    print(label + " " + clock)
PY
