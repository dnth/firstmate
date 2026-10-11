#!/usr/bin/env bash
# Derive one public-safe Discord thread name for a Communication Officer request.
#
# Usage:
#   fm-ext-topic.sh --text-file <path> --origin slash|message
#     --thread-id <id> --channel-id <id>
#
# Reads the request text on the given file and prints one thread name plus a
# trailing newline. A request that already arrived inside a thread prints
# nothing and exits 0 with no output: it keeps its existing thread, so there
# is nothing to name.
#
# The derivation is allowlist-only, never a redaction. Only tokens from the
# explicit SAFE_WORDS vocabulary below survive, in request order, up to four.
# Everything else - secrets, ids, paths, hostnames, numbers, unfamiliar words -
# is dropped, and a request with no safe word falls back to "fm request".
# Only whole whitespace-delimited vocabulary words are admitted.
# Admission and authority stay owned by bin/fm-ext-intake.sh.
# The name stays far under Discord's 100-character thread-name limit.
set -u

usage() {
  echo "usage: fm-ext-topic.sh --text-file <path> --origin slash|message --thread-id <id> --channel-id <id>" >&2
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-ext-topic: %s\n' "$1" >&2; exit "${2:-2}"; }

# Conservative safe topic vocabulary: generic workflow words only, all
# lowercase ASCII, 2-12 characters. No stopwords, no secret-adjacent words
# (secret, token, password, key), no filesystem words (home, path, file is a
# verb here and stays), no network words (host, server, ip), no proper nouns.
# A word outside this list is dropped even when it looks innocent.
SAFE_WORDS='add agenda answer approve ask audit backlog bug build channel check chore clean close confirm daily debug demo deploy design doc docs draft explain feature find fix fleet help hotfix inbox investigate issue list login logout look meeting merge message note notes open plan please proposal quick read refactor release remind reply report request retro review run schedule search ship show spec standup start status stop summarize summary sync task test thread track triage update urgent verify watch write'

TEXT_FILE=
ORIGIN=
THREAD_ID=
CHANNEL_ID=

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
    --help|-h) help; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift || true
done

[ -n "$TEXT_FILE" ] || { usage; exit 2; }
[ -n "$ORIGIN" ] || { usage; exit 2; }
[ -n "$THREAD_ID" ] || { usage; exit 2; }
[ -n "$CHANNEL_ID" ] || { usage; exit 2; }

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

WORDS=$(printf '%s' "$TEXT" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -s '[:space:]' '\n') \
  || die "could not tokenize the text" 1

KEPT=
COUNT=0
while IFS= read -r word; do
  [ "$COUNT" -lt 4 ] || break
  case "$word" in
    *[!a-z]*) continue ;;
  esac
  case ${#word} in
    2|3|4|5|6|7|8|9|10|11|12) ;;
    *) continue ;;
  esac
  case " $SAFE_WORDS " in
    *" $word "*) ;;
    *) continue ;;
  esac
  case " $KEPT " in
    *" $word "*) continue ;;
  esac
  KEPT="$KEPT${KEPT:+ }$word"
  COUNT=$((COUNT + 1))
done <<EOF
$WORDS
EOF

[ -n "$KEPT" ] || { printf 'fm request\n'; exit 0; }
printf 'fm %s\n' "$KEPT"
