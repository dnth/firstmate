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
# The helper validates the task, schema, and criterion before taking an exclusive
# task-local append lock.
# It writes exactly one compact JSON object with one append operation and never
# rewrites existing evidence.
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
[ -n "$SUMMARY" ] || { echo "error: summary must not be empty" >&2; exit 2; }
[ -n "$RESULT" ] || { echo "error: result must not be empty" >&2; exit 2; }

TASK_DIR="$DATA/$ID"
BRIEF="$TASK_DIR/brief.md"
LEDGER="$TASK_DIR/evidence.jsonl"
LOCK="$TASK_DIR/.evidence-append.lock"

[ -d "$DATA" ] && [ ! -L "$TASK_DIR" ] && [ -d "$TASK_DIR" ] \
  || { echo "error: task directory is missing or unsafe: $TASK_DIR" >&2; exit 1; }
DATA_REAL=$(cd "$DATA" && pwd -P)
TASK_REAL=$(cd "$TASK_DIR" && pwd -P)
[ "$TASK_REAL" = "$DATA_REAL/$ID" ] || { echo "error: task directory escapes data root" >&2; exit 1; }
exec 8< "$TASK_DIR"
TASK_IDENTITY=$(stat -L -c '%d:%i' "$TASK_DIR" 2>/dev/null || stat -L -f '%d:%i' "$TASK_DIR" 2>/dev/null)
PINNED_DIR="/proc/$$/fd/8"
PINNED_IDENTITY=$(stat -L -c '%d:%i' "$PINNED_DIR" 2>/dev/null || stat -L -f '%d:%i' "$PINNED_DIR" 2>/dev/null)
[ "$TASK_IDENTITY" = "$PINNED_IDENTITY" ] || { echo "error: task directory identity changed" >&2; exit 1; }
BRIEF="$PINNED_DIR/brief.md"
LEDGER="$PINNED_DIR/evidence.jsonl"
LOCK="$PINNED_DIR/.evidence-append.lock"
[ -f "$BRIEF" ] && [ ! -L "$BRIEF" ] \
  || { echo "error: task brief is missing or unsafe: $BRIEF" >&2; exit 1; }
grep -Eq '^Delivery contract: mode=(no-mistakes|direct-PR|local-only)$' "$BRIEF" \
  || { echo "error: receipts apply only to ship tasks with a delivery contract" >&2; exit 1; }
"$SCRIPT_DIR/fm-receipt-check.sh" "$ID" --criterion "$CRITERION" >/dev/null \
  || { echo "error: criterion is not declared by the ship brief: $CRITERION" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

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

if [ -L "$LEDGER" ] || [ ! -f "$LEDGER" ]; then
  echo "error: evidence ledger is not a regular file: $LEDGER" >&2
  exit 1
fi
ledger_links() {
  stat -c %h "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null
}
[ "$(ledger_links "$LEDGER")" = 1 ] \
  || { echo "error: evidence ledger has multiple links" >&2; exit 1; }

umask 077
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "error: evidence ledger is locked by another append: $LOCK" >&2
  exit 1
fi
cleanup() {
  rmdir "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ -L "$LEDGER" ] || [ ! -f "$LEDGER" ]; then
  echo "error: evidence ledger became unsafe before append: $LEDGER" >&2
  exit 1
fi
[ "$(ledger_links "$LEDGER")" = 1 ] \
  || { echo "error: evidence ledger became multiply linked" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "error: perl is required" >&2; exit 1; }
if ! printf '%s\n' "$receipt" | FM_PINNED_LEDGER="$LEDGER" perl -MFcntl=O_WRONLY,O_APPEND,O_NOFOLLOW -e '
  sysopen(my $ledger, $ENV{FM_PINNED_LEDGER}, O_WRONLY | O_APPEND | O_NOFOLLOW) or exit 1;
  my @identity = stat($ledger);
  exit 1 unless @identity && $identity[3] == 1;
  while (<STDIN>) { print {$ledger} $_ or exit 1; }
  close($ledger) or exit 1;
'; then
  echo "error: evidence ledger identity changed before append" >&2
  exit 1
fi
cleanup
trap - EXIT
exec 8<&-
printf '%s\n' "$receipt"
