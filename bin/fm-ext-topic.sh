#!/usr/bin/env bash
# Derive one public-safe Discord thread name for a Communication Officer request.
#
# Usage:
#   fm-ext-topic.sh --text-file <path> --origin slash|message
#     --thread-id <id> --channel-id <id> --message-id <id>
#     [--title-file <path>] [--validate-name --stored-file <path>]
#
# Naming, in priority order: Firstmate's title, the request-text fallback, the
# label-plus-time last fallback. Admission and authority stay owned by
# bin/fm-ext-intake.sh; docs/configuration.md owns the contract.
# Only top-level message requests in config/ext-channel receive a name.
# Slash requests, existing threads, and other channels print nothing.
# --message-id supplies the Discord snowflake containing the message timestamp.
# --title-file carries Firstmate's "<Project> · <topic>" title: one line, at
# most 60 characters, screened like reply text. Over-long, multi-line, or
# unsafe titles fall through to the request-text fallback instead of cutting.
# The request-text fallback uses the first non-empty line of the request with
# Discord mention, role, channel, emoji, and timestamp tokens stripped,
# whitespace collapsed, control characters dropped, cut to at most 90
# characters on a word boundary ending in … when cut. The thread sits on the
# captain's own message, so the fallback shows nothing its audience cannot
# already read. An empty-after-cleaning request falls back to the label-plus-
# time name: one fixed public label (Aceh, InfoConnect, Firstmate, Question,
# or Firstmate request) plus the source message's MYT time as HH:MM.
# --validate-name checks --stored-file's name against the same priority order
# re-derived from --text-file's request text (plus --title-file when given):
# the fresh name, or a legacy label-plus-time name for this message. Anything
# else falls back to the freshly derived name.
set -u

usage() {
  echo "usage: fm-ext-topic.sh --text-file <path> --origin slash|message --thread-id <id> --channel-id <id> --message-id <id> [--title-file <path>] [--validate-name --stored-file <path>]" >&2
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
TITLE_FILE=
STORED_FILE=

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
    --stored-file) shift; STORED_FILE=${1:-} ;;
    --title-file) shift; TITLE_FILE=${1:-} ;;
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

TITLE_TEXT=
if [ -n "${TITLE_FILE:-}" ]; then
  if [ "$TITLE_FILE" = '-' ]; then
    [ "$TEXT_FILE" != '-' ] || die "text and title cannot both read stdin"
    TITLE_TEXT=$(cat)
  else
    [ -f "$TITLE_FILE" ] && [ ! -L "$TITLE_FILE" ] || die "title file not found: $TITLE_FILE"
    TITLE_TEXT=$(cat -- "$TITLE_FILE")
  fi
fi

STORED=
if [ "$VALIDATE" = 1 ]; then
  [ -n "${STORED_FILE:-}" ] || die "--validate-name needs --stored-file"
  if [ "$STORED_FILE" = '-' ]; then
    [ "$TEXT_FILE" != '-' ] || die "text and stored name cannot both read stdin"
    STORED=$(cat)
  else
    [ -f "$STORED_FILE" ] && [ ! -L "$STORED_FILE" ] || die "stored file not found: $STORED_FILE"
    STORED=$(cat -- "$STORED_FILE")
  fi
fi

FM_ROOT=${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
FM_HOME=${FM_HOME:-$FM_ROOT}
python3 - "$FM_ROOT" "$FM_HOME" "$CHANNEL_ID" "$MESSAGE_ID" "$VALIDATE" 3<<< "$TEXT" 4<<< "$TITLE_TEXT" 5<<< "$STORED" <<'PY'
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "contrib/hermes-gateway-firstmate-comms"))
from intake import dedicated_channel
if dedicated_channel(Path(sys.argv[2])) != sys.argv[3]:
    sys.exit(0)
text = os.fdopen(3).read()
title_raw = os.fdopen(4).read()
message_ms = (int(sys.argv[4]) >> 22) + 1420070400000
clock = datetime.fromtimestamp(message_ms / 1000, timezone(timedelta(hours=8))).strftime("%H:%M")
labels = {"aceh": "Aceh", "infoconnect": "InfoConnect", "firstmate": "Firstmate", "question": "Question"}
fallback = "Firstmate request"

TOKEN_RE = re.compile(r"<@&?\d+>|<#[^>]*>|<a?:[A-Za-z0-9_~:-]+:\d+>|<t:[^>]*>")
# Firstmate's title shares reply text's public-safety screen: nothing like an
# internal identifier, path, hostname, or secret may reach the thread name.
UNSAFE_RE = re.compile(
    r"(?:"
    r"\bfm-[a-z0-9]+(?:-[a-z0-9]+)*\b"  # task ids such as fm-ship-login
    r"|\bhold:[^\s]*|\bkey:[^\s]*|\bfmd:[^\s]*"  # decision keys
    r"|(?:^|\s)(?:/[A-Za-z0-9_.-]+)+(?:\s|$)"  # absolute paths
    r"|(?:^|\s)\./\S+|(?:^|\s)~\S+"  # relative and home paths
    r"|\b[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.[a-z]+(?:\.[a-z]+)*\b"  # hostnames
    r"|\b(?:token|secret|password|api[_-]?key|bearer)\b\s*[:=]\s*\S+"  # secrets
    r"|(?:^|\s)[A-Za-z0-9_+/]{32,}={0,2}(?:\s|$)"  # token-shaped blobs
    r")",
    re.IGNORECASE,
)

TITLE_MAX = 60
NAME_MAX = 90


def clean_title(raw):
    raw = raw.strip()
    if "\n" in raw or "\r" in raw:
        return ""
    cleaned = "".join(ch for ch in raw if ord(ch) >= 32 or ch == "\t")
    cleaned = " ".join(cleaned.split())
    if not cleaned or len(cleaned) > TITLE_MAX:
        return ""
    if not cleaned.strip(" .!?,;:"):
        return ""
    if UNSAFE_RE.search(cleaned):
        return ""
    return cleaned


def request_name(raw):
    first = next((line for line in raw.splitlines() if line.strip()), "")
    stripped = TOKEN_RE.sub(" ", first)
    stripped = "".join(ch for ch in stripped if ord(ch) >= 32 or ch == "\t")
    cleaned = " ".join(stripped.split())
    if not cleaned or not cleaned.strip(" .!?,;:"):
        return ""
    if len(cleaned) <= NAME_MAX:
        return cleaned
    head = cleaned[:NAME_MAX - 1].rsplit(" ", 1)
    base = head[0] if len(head) == 2 and head[0] else cleaned[:NAME_MAX - 1].rstrip()
    return base + "…"


def legacy_names():
    return {label + " " + clock for label in (*labels.values(), fallback)}


def derive():
    titled = clean_title(title_raw)
    if titled:
        return titled
    named = request_name(text)
    if named:
        return named
    words = set(text.casefold().split())
    label = next((label for word, label in labels.items() if word in words), fallback)
    return label + " " + clock


fresh = derive()
if sys.argv[5] == "1":
    stored = os.fdopen(5).read().strip()
    allowed = legacy_names()
    if stored == fresh or (not clean_title(title_raw) and stored in allowed):
        # A title or request-text name must equal the fresh one; a legacy
        # label-plus-time name stays valid only for its own message time.
        print(stored)
    else:
        print(fresh)
else:
    print(fresh)
PY
