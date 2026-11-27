#!/usr/bin/env bash
# fm-ext-thread-name.sh - propose a new "<Project> · <topic>" base name for one
# Communication Officer topic thread whose name drifted from its conversation.
#
# Usage:
#   fm-ext-thread-name.sh --state-file <json>
#
# Input file: the thread state documented in bin/fm-ext-thread-judge.sh.
# The naming model receives the name, the current project label, the other
# known project labels, and the messages. This tool never reads Discord,
# attachments, or images.
#
# Output: the screened base name on stdout, or exit 1 with one reason on
# stderr. The proposal is always "<Project> · <topic>": a model answer without
# a project prefix and a nonempty topic is refused. The prefix must be the
# thread's current project label. When the conversation clearly moves to
# another project, it may use the built-in Firstmate label or a public label
# from config/ext-project-labels for a project registered in data/projects.md;
# any other prefix is refused, so a prefix is never free text. The result must
# pass bin/fm-ext-topic.sh --check-title (bounds and shared safety screen).
#
# OpenCode runs the fixed OpenCode Go DeepSeek V4.1 Flash model for at most
# 120 seconds, using private input and structured output.
# docs/configuration.md "Thread title reconciler" owns when callers ask.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die() {
  printf 'fm-ext-thread-name: %s\n' "$1" >&2
  exit 1
}

helptext() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

STATE_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state-file) shift; STATE_FILE=${1:-} ;;
    --help|-h) helptext; exit 0 ;;
    *) echo "usage: fm-ext-thread-name.sh --state-file <json>" >&2; exit 2 ;;
  esac
  shift || true
done
[ -n "$STATE_FILE" ] || { echo "usage: fm-ext-thread-name.sh --state-file <json>" >&2; exit 2; }
[ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || die "state file not found: $STATE_FILE"
command -v jq >/dev/null 2>&1 || die "jq required"
command -v opencode >/dev/null 2>&1 || die "opencode not installed"

PROJECT=$(jq -er '.thread.project | strings | select(length > 0 and . != "unknown")' "$STATE_FILE") \
  || die "thread project is unknown"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(dirname "$SCRIPT_DIR")}}
REGISTRY="${FM_DATA_OVERRIDE:-$FM_HOME/data}/projects.md"
PUBLIC_LABELS="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/ext-project-labels"
LABELS=$(
  {
    printf '%s\n' Firstmate
    if [ -f "$REGISTRY" ] && [ -f "$PUBLIC_LABELS" ] && [ ! -L "$PUBLIC_LABELS" ]; then
      awk -F '\t' '
        FILENAME == ARGV[1] {
          if ($0 ~ /^- [^[:space:]]+ (\[[^]]+\] )?- /) {
            split($0, fields, " ")
            registered[fields[2]] = 1
          }
          next
        }
        NF == 2 && $1 in registered { print $2 }
      ' "$REGISTRY" "$PUBLIC_LABELS"
    fi
  } | while IFS= read -r label; do
    case "$label" in
      ''|unknown|"$PROJECT"|*" · "*) continue ;;
    esac
    screened=$(printf '%s · x\n' "$label" | "$SCRIPT_DIR/fm-ext-topic.sh" --check-title --title-file - 2>/dev/null) || continue
    [ "$screened" = "$label · x" ] && printf '%s\n' "$label"
  done | sort -u
)

WORK=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
PROMPT="$WORK/prompt.txt" OUT="$WORK/out.txt"

{
  printf '%s\n' 'You name Discord work threads.'
  printf '%s\n' "Read the conversation below and answer with a short new thread name in the form: <Project> · <topic>"
  printf '%s\n' "The current project label is: $PROJECT"
  printf '%s\n' 'Other known project labels, if any, follow on their own lines.'
  printf '%s\n' 'Keep the current project label unless the conversation has clearly moved to the work of another project from that list; then use that project label exactly as listed.'
  printf '%s\n' 'Do not invent a project label.'
  printf '%s\n' 'Keep the topic to a few concrete words (the whole name must be at most 60 characters).'
  printf '%s\n' 'Do not include a status emoji, quotes, markdown, a file path, a task id, a hostname, a token, or a sentence.'
  printf '%s\n' 'Answer with the name only, on one line.'
  printf '\n%s\n' '--- known project labels ---'
  printf '%s\n' "$LABELS"
  printf '\n%s\n' '--- conversation ---'
  jq -r '
    .thread.name as $name |
    "current name: \($name)",
    (.thread.messages[]? | "\(.role): \(.text // "")")
  ' "$STATE_FILE" || die "could not read the conversation"
} > "$PROMPT" || die "could not build the prompt"

# shellcheck disable=SC2016
OPENCODE_CONFIG_CONTENT='{"share":"disabled","permission":{"*":"deny"}}' \
  fm_run_timed 120 bash -c 'exec opencode run --format json -m opencode-go/deepseek-v4.1-flash < "$1"' \
  _ "$PROMPT" > "$OUT" 2>/dev/null || die "naming model command exited $?"

CANDIDATE=$(jq -ers '
  if any(.[]; .type == "error") then error("naming model error") else
    [.[] | select(.type == "text") | .part.text | strings] | join("\n")
    | gsub("^\\s+|\\s+$"; "")
  end
' "$OUT") || die "could not read the naming model answer"
printf '%s\n' "$CANDIDATE" > "$WORK/candidate"
TITLE=$("$SCRIPT_DIR/fm-ext-topic.sh" --check-title --title-file "$WORK/candidate") \
  || die "naming model produced an unsafe title"
case "$TITLE" in
  *" · "?*) ;;
  *) die "naming model produced no title for the thread project" ;;
esac
PREFIX=${TITLE%% · *}
if [ "$PREFIX" != "$PROJECT" ] && ! printf '%s\n' "$LABELS" | grep -Fxq -- "$PREFIX"; then
  die "naming model produced an unknown project prefix"
fi
printf '%s\n' "$TITLE"
