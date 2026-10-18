#!/usr/bin/env bash
# Ask the captain a choice in a Discord thread, with one button per option.
#
# Usage:
#   fm-ext-ask.sh --request-id discord:<guild>:<channel>:<thread>:<message>
#     --kind answer|followup|final --generation <n>
#     --task <task-id> [--title <title>] [--repo <repo>] --reason <reason>
#     (--text-file <path> | --text-file -) [--explanation-file <path>]
#     --option <label> [--recommended] [--confirm]
#     [--option <label> [--recommended] [--confirm]] ... (1-5 options)
#     --mode done|release [--thread-title <text>] [--thread-retitle <text>]
#
# This is the one way to post a choice. It does the three steps a choice post
# needs, in order, so none can be skipped:
#   1. places or refreshes the captain hold for --task through
#      bin/fm-captain-hold.sh hold (--title and --repo only matter when the task
#      does not exist yet and must be created; --reason is the hold reason and
#      follows that command's rules, including no parentheses);
#   2. writes the decision file (key hold:<task-id>, the mode, the options);
#   3. posts through bin/fm-ext-emit.sh --decision-file with
#      --thread-state needs-you; --thread-title and --thread-retitle pass
#      straight through to that post, and the emit header owns what each does.
# The post text keeps the question, optional explanation, numbered option
# lines, and reply cue as separate sections for safe chunking and settlement.
# The numbered option lines follow button order, and a recommended option shows
# "⭐ " in both. --recommended marks the option just before it (at most one);
# --confirm asks for a second click on the option just before it. Options whose
# label matches FM_EXT_DECISION_CONFIRM_PATTERN in bin/fm-ext-lib.sh (merge,
# deploy, delete, and other risky words) get the confirmation click automatically.
# --mode is required and has no default: it chooses how a chosen option closes
# the call, as in bin/fm-captain-hold.sh answers. done closes a question;
# release lifts the hold so held work proceeds. A held build task that has not
# spawned yet has no worker metadata but still needs release, so the mode is
# never inferred.
#
# Never write the task id or the key into the text or a label: the key rides
# only in the button ids, and this script refuses such text before holding
# anything. bin/fm-ext-emit.sh header owns the decision file format, the
# buttons contract, and the choice guard that sends choice-shaped text here.
# Before mutating the hold, retries with the same request, kind, and generation
# defer to emit's existing outbox identity: a receipt is a no-op success;
# a posting marker without a receipt is refused as mid-delivery; otherwise an
# existing payload is a no-op success. None of these retries changes the hold,
# even after the captain has answered. See tests/fm-ext-ask.test.sh.
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
usage: fm-ext-ask.sh --request-id discord:<guild>:<channel>:<thread>:<message>
         --kind answer|followup|final --generation <n>
         --task <task-id> [--title <title>] [--repo <repo>] --reason <reason>
         (--text-file <path> | --text-file -) [--explanation-file <path>]
         --option <label> [--recommended] [--confirm] [--option <label> ...]
         --mode done|release [--thread-title <text>] [--thread-retitle <text>]
EOF
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-ext-ask: %s\n' "$1" >&2; exit "${2:-2}"; }

REQUEST_ID=
KIND=
GENERATION=
TASK=
TITLE=
REPO=
REASON=
TEXT_FILE=
EXPLANATION_FILE=
MODE=
THREAD_TITLE=
THREAD_RETITLE=
OPTIONS_JSON='[]'
case "${1:-}" in
  --help|-h) help; exit 0 ;;
  '') usage; exit 2 ;;
esac
command -v jq >/dev/null 2>&1 || die "jq is required" 1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --request-id) shift; REQUEST_ID=${1:-} ;;
    --kind) shift; KIND=${1:-} ;;
    --generation) shift; GENERATION=${1:-} ;;
    --task) shift; TASK=${1:-} ;;
    --title) shift; TITLE=${1:-} ;;
    --repo) shift; REPO=${1:-} ;;
    --reason) shift; REASON=${1:-} ;;
    --text-file) shift; TEXT_FILE=${1:-} ;;
    --explanation-file) shift; EXPLANATION_FILE=${1:-} ;;
    --mode) shift; MODE=${1:-} ;;
    --thread-title) shift; THREAD_TITLE=${1:-} ;;
    --thread-retitle) shift; THREAD_RETITLE=${1:-} ;;
    --option)
      shift
      OPTIONS_JSON=$(jq -c --arg lbl "${1:-}" '. + [{"label": $lbl}]' <<<"$OPTIONS_JSON") \
        || die "could not record the option" 1
      ;;
    --recommended|--confirm)
      flag=${1#--}
      [ "$OPTIONS_JSON" != '[]' ] || die "$1 follows an --option"
      OPTIONS_JSON=$(jq -c --arg flag "$flag" '.[-1][$flag] = true' <<<"$OPTIONS_JSON") \
        || die "could not record $1" 1
      ;;
    --help|-h) help; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift || true
done

[ -n "$REQUEST_ID" ] && [ -n "$KIND" ] && [ -n "$GENERATION" ] && [ -n "$TASK" ] \
  && [ -n "$REASON" ] && [ -n "$TEXT_FILE" ] || { usage; exit 2; }

fm_ext_request_id_valid "$REQUEST_ID" || die "unsafe request_id: $REQUEST_ID"
case "$KIND" in
  answer|followup|final) ;;
  *) die "kind must be answer, followup, or final" ;;
esac
fm_ext_generation_valid "$GENERATION" || die "generation must be a positive integer"
case "$MODE" in
  done|release) ;;
  '') die "--mode is required: done = close a question, release = lift the hold so held work proceeds" ;;
  *) die "mode must be done or release" ;;
esac
case "$TASK" in
  ''|*[!A-Za-z0-9._-]*|[-.]*) die "task must be a task id (letters, digits, dot, underscore, dash)" ;;
esac

jq -e --argjson max "$FM_EXT_DECISION_MAX_OPTIONS" --argjson label_max "$FM_EXT_DECISION_LABEL_MAX" '
  length >= 1 and length <= $max
  and all(.[]; (.label | length >= 1 and length <= $label_max
      and (explode | all(. >= 32 and . != 127)) and test("^\\S(.*\\S)?$"))
    and ((.recommended // false) | type == "boolean"))
  and ([.[] | select(.recommended // false)] | length <= 1)
  and ([.[].label | ascii_downcase] | length == (unique | length))
' <<<"$OPTIONS_JSON" >/dev/null 2>&1 \
  || die "give 1-$FM_EXT_DECISION_MAX_OPTIONS distinct --option labels of 1-$FM_EXT_DECISION_LABEL_MAX characters, at most one --recommended"

KEY="hold:$TASK"
if [ "$TEXT_FILE" = '-' ]; then
  TEXT=$(cat)
else
  [ -f "$TEXT_FILE" ] && [ ! -L "$TEXT_FILE" ] || die "text file not found: $TEXT_FILE"
  TEXT=$(cat -- "$TEXT_FILE")
fi
[ -n "$TEXT" ] || die "text is empty"
EXPLANATION=
if [ -n "$EXPLANATION_FILE" ]; then
  [ -f "$EXPLANATION_FILE" ] && [ ! -L "$EXPLANATION_FILE" ] \
    || die "explanation file not found: $EXPLANATION_FILE"
  EXPLANATION=$(cat -- "$EXPLANATION_FILE")
fi

if { printf '%s\n' "$TEXT" "$EXPLANATION"; jq -r '.[].label' <<<"$OPTIONS_JSON"; } \
  | grep -qiF -e "$TASK" -e "$KEY"; then
  die "the text and labels must not name the task id"
fi

# Numbered lines in button order, with the same label the button shows.
LINES=$(jq -r '. as $o | range(0; length) as $i
  | $o[$i] | "\($i + 1). " + (if (.recommended // false) and ((.label | startswith("⭐")) | not) then "⭐ " + .label else .label end)' \
  <<<"$OPTIONS_JSON") || die "could not number the options" 1
CUE='Tap a button, or reply with the number.'
BODY=$TEXT
[ -z "$EXPLANATION" ] || BODY=$(printf '%s\n\n%s' "$TEXT" "$EXPLANATION")
FULL_TEXT=$(printf '%s\n\n%s\n%s' "$BODY" "$LINES" "$CUE")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-ext-ask.XXXXXX") || die "could not make a scratch directory" 1
trap 'rm -rf "$WORK"' EXIT
jq -n --arg key "$KEY" --arg mode "$MODE" --arg question "$TEXT" \
  --arg explanation "$EXPLANATION" --arg option_text "$LINES" --arg cue "$CUE" \
  --argjson options "$OPTIONS_JSON" \
  '{key: $key, mode: $mode, options: $options,
    sections: {question: $question, explanation: $explanation,
      options: $option_text, cue: $cue}}' > "$WORK/decision.json" \
  || die "could not write the decision file" 1

emit=("$SCRIPT_DIR/fm-ext-emit.sh" --request-id "$REQUEST_ID" --kind "$KIND"
  --generation "$GENERATION" --text-file - --decision-file "$WORK/decision.json"
  --thread-state needs-you)
[ -z "$THREAD_TITLE" ] || emit+=(--thread-title "$THREAD_TITLE")
[ -z "$THREAD_RETITLE" ] || emit+=(--thread-retitle "$THREAD_RETITLE")

SLUG=$(fm_ext_request_slug "$REQUEST_ID") || die "could not derive request slug" 1
OUTBOX=$(fm_ext_outbox_dir)
for identity in fm_ext_outbox_basename fm_ext_outbox_receipt_basename fm_ext_outbox_posting_basename; do
  artifact=$("$identity" "$SLUG" "$KIND" "$GENERATION") || die "invalid outbox identity" 1
  if fm_ext_private_artifact_file_valid "$OUTBOX" "$artifact" 600; then
    printf '%s\n' "$FULL_TEXT" | "${emit[@]}"
    exit "$?"
  fi
done

hold=("$SCRIPT_DIR/fm-captain-hold.sh" hold "$TASK" --reason "$REASON")
[ -z "$TITLE" ] || hold+=(--title "$TITLE")
[ -z "$REPO" ] || hold+=(--repo "$REPO")
"${hold[@]}" >&2 || die "could not hold task $TASK for the captain" 1

printf '%s\n' "$FULL_TEXT" | "${emit[@]}"
