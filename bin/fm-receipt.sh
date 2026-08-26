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
COMMAND=
ARTIFACT=
FILE_POINTER=

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
    --result|--command|--artifact|--file)
      [ "$#" -gt 0 ] || { echo "error: $option requires a value" >&2; exit 2; }
      value=$1
      shift
      case "$option" in
        --result) RESULT=$value ;;
        --command) COMMAND=$value ;;
        --artifact) ARTIFACT=$value ;;
        --file) FILE_POINTER=$value ;;
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
case "$CRITERION" in
  AC[1-9]|AC[1-9][0-9]*) ;;
  *) echo "error: criterion must be AC followed by a positive integer (got '$CRITERION')" >&2; exit 2 ;;
esac
case "$TYPE" in
  test|build|lint|typecheck|api|browser|manual|review) ;;
  *) echo "error: unsupported receipt type: $TYPE" >&2; exit 2 ;;
esac
case "$SUMMARY" in *[![:space:]]*) ;; *) echo "error: summary must not be empty" >&2; exit 2 ;; esac
case "$RESULT" in *[![:space:]]*) ;; *) echo "error: result must not be empty" >&2; exit 2 ;; esac

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
[ -d "$DATA" ] || { echo "error: data directory is missing: $DATA" >&2; exit 1; }
DATA_REAL=$(CDPATH='' cd -- "$DATA" 2>/dev/null && pwd -P) \
  || { echo "error: data directory is unsafe: $DATA" >&2; exit 1; }

receipt=$(jq -cn \
  --arg criterion "$CRITERION" \
  --arg type "$TYPE" \
  --arg summary "$SUMMARY" \
  --arg result "$RESULT" \
  --arg command "$COMMAND" \
  --arg artifact "$ARTIFACT" \
  --arg file "$FILE_POINTER" '
    {criterion:$criterion,type:$type,summary:$summary,result:$result}
    + (if $command == "" then {} else {command:$command} end)
    + (if $artifact == "" then {} else {artifact:$artifact} end)
    + (if $file == "" then {} else {file:$file} end)
  ')

if ! FM_DATA_OVERRIDE="$DATA_REAL" FM_RECEIPT_PAYLOAD="$receipt" \
  "$SCRIPT_DIR/fm-receipt-store.sh" "$ID" append "$CRITERION" "$SCRIPT_DIR/fm-receipt-check.sh"; then
  exit 1
fi
printf '%s\n' "$receipt"
