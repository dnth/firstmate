#!/usr/bin/env bash
# Append one validated acceptance-criterion evidence receipt to a ship task.
#
# Usage:
#   fm-receipt.sh <task-id> <criterion> <type> <summary> <result> [options]
#   fm-receipt.sh <task-id> <criterion> <type> <summary> --result <result> [options]
#
# Required values:
#   task-id     Existing ship task under data/<task-id>/.
#   criterion   Stable acceptance-criterion id declared by the brief (AC1, AC2, ...).
#   type        test|build|lint|typecheck|api|browser|manual|review.
#   summary     Compact statement of what the evidence demonstrates.
#   result      Compact observed result, either positional or supplied by --result.
#
# Options:
#   --outcome <status> Required structured outcome: success, failure, negative,
#                      zero, skipped, empty, placeholder, weak, or
#                      accepted-blocked.
#   --captain-exception <text>
#                      Required with --outcome accepted-blocked and refused with
#                      every other outcome; records the captain's explicit
#                      blocked acceptance verbatim (date plus the captain's own
#                      words or the board key that holds them). Never inferred
#                      or defaulted. An accepted-blocked receipt accounts for
#                      its criterion without evidencing it.
#   --result <text>    Observed result when it is not supplied positionally.
#   --command <text>   Command that produced the evidence.
#   --artifact <path>  Artifact or URL carrying the evidence.
#   --file <path>      Source or evidence file pointer.
#
# The helper validates input schema and delegates the pinned ship-contract append
# to fm-receipt-store.sh, then emits exactly one compact JSON object.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "$#" -ge 4 ] || { usage >&2; exit 2; }

ID=$1
CRITERION=$2
TYPE=$3
SUMMARY=$4
shift 4

RESULT=
OUTCOME=
COMMAND=
ARTIFACT=
FILE_POINTER=
CAPTAIN_EXCEPTION=

if [ "$#" -gt 0 ]; then
  case "$1" in
    --*) ;;
    *) RESULT=$1; shift ;;
  esac
fi

while [ "$#" -gt 0 ]; do
  option=$1
  shift
  case "$option" in
    --outcome|--result|--command|--artifact|--file|--captain-exception)
      [ "$#" -gt 0 ] || { echo "error: $option requires a value" >&2; exit 2; }
      value=$1
      shift
      case "$option" in
        --outcome) OUTCOME=$value ;;
        --result) RESULT=$value ;;
        --command) COMMAND=$value ;;
        --artifact) ARTIFACT=$value ;;
        --file) FILE_POINTER=$value ;;
        --captain-exception) CAPTAIN_EXCEPTION=$value ;;
      esac
      ;;
    *) echo "error: unknown option: $option" >&2; exit 2 ;;
  esac
done

case "$ID" in
  ''|.|..|*[!A-Za-z0-9._-]*|[._-]*)
    echo "error: invalid task id: $ID" >&2
    exit 2
    ;;
esac
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

if [ "$OUTCOME" = accepted-blocked ]; then
  [ -n "$(printf '%s' "$CAPTAIN_EXCEPTION" | tr -d '[:space:]')" ] \
    || { echo "error: --outcome accepted-blocked requires a non-empty --captain-exception reference" >&2; exit 2; }
elif [ -n "$CAPTAIN_EXCEPTION" ]; then
  echo "error: --captain-exception applies only to --outcome accepted-blocked" >&2
  exit 2
fi

case "$ARTIFACT" in
  ''|/*|*://*) ;;
  *) echo "warning: --artifact is a relative path ($ARTIFACT); worktree-relative references die at teardown - copy the artifact under data/<task-id>/artifacts/ and cite that path" >&2 ;;
esac

receipt=$(jq -cn \
  --arg criterion "$CRITERION" \
  --arg type "$TYPE" \
  --arg outcome "$OUTCOME" \
  --arg summary "$SUMMARY" \
  --arg result "$RESULT" \
  --arg command "$COMMAND" \
  --arg artifact "$ARTIFACT" \
  --arg file "$FILE_POINTER" \
  --arg captain_exception "$CAPTAIN_EXCEPTION" '
    {criterion:$criterion,type:$type,outcome:$outcome,summary:$summary,result:$result}
    + (if $command == "" then {} else {command:$command} end)
    + (if $artifact == "" then {} else {artifact:$artifact} end)
    + (if $file == "" then {} else {file:$file} end)
    + (if $captain_exception == "" then {} else {captain_exception:$captain_exception} end)
  ')
printf '%s\n' "$receipt" | "$SCRIPT_DIR/fm-receipt-schema.sh" \
  || { echo "error: invalid receipt schema" >&2; exit 2; }

if ! stored_receipt=$(FM_DATA_OVERRIDE="$DATA" FM_RECEIPT_PAYLOAD="$receipt" \
  "$SCRIPT_DIR/fm-receipt-store.sh" "$ID" append "$CRITERION" "$SCRIPT_DIR/fm-receipt-check.sh"); then
  exit 1
fi
printf '%s\n' "$stored_receipt"
