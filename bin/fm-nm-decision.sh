#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
STATE="${FM_STATE_OVERRIDE:-${FM_HOME:?FM_HOME is required}/state}"
if [ "${1:-}" = --help ]; then
  echo "usage: FM_HOME=<home> fm-nm-decision.sh <task-id> <nm-key> <decision>"
  exit 0
fi
if [ "$#" -ne 3 ]; then
  echo "usage: fm-nm-decision.sh <task-id> <nm-key> <decision>" >&2
  exit 2
fi
case "$1" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac
case "$2" in nm-*) ;; *) exit 2 ;; esac
case "$2" in *[!A-Za-z0-9._-]*) exit 2 ;; esac
[ -n "$3" ] || exit 2
if [ -n "${FM_TASK_ID:-}" ] || ! fm_session_lock_owned_by_self "$STATE"; then
  echo "error: recording a no-mistakes decision requires the lock-owning Firstmate session" >&2
  exit 1
fi
STATUS="$STATE/$1.status"
LEDGER="$STATUS.nm-decisions"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 1
for path in "$STATUS" "$LEDGER"; do
  [ ! -e "$path" ] || { [ -f "$path" ] && [ ! -L "$path" ]; } || exit 1
  [ ! -L "$path" ] || exit 1
done
umask 077
TOKEN=$(mktemp "$STATE/.nm-decision.XXXXXX")
trap 'rm -f -- "$TOKEN"' EXIT
NOTE=$(printf '%s' "$3" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
LINE="resolved [key=$2]: decided [record=${TOKEN##*/}]: $NOTE"
printf '%s\n' "$LINE" >> "$LEDGER"
printf '%s\n' "$LINE" >> "$STATUS"
