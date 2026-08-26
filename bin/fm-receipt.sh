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
# The helper validates input schema, opens the task, brief, and original ledger
# through portable no-follow descriptors, locks that ledger, validates the pinned
# ship contract and criterion, and appends exactly one compact JSON object without
# rewriting existing evidence.
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

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
command -v perl >/dev/null 2>&1 || { echo "error: perl is required" >&2; exit 1; }
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

if ! FM_RECEIPT_DATA="$DATA_REAL" FM_RECEIPT_ID="$ID" FM_RECEIPT_CRITERION="$CRITERION" \
  FM_RECEIPT_PAYLOAD="$receipt" perl - <<'PERL'
use strict;
use warnings;
use Fcntl qw(:DEFAULT :flock :mode);

sub refuse {
  print STDERR "error: $_[0]\n";
  exit 1;
}

my $task_path = "$ENV{FM_RECEIPT_DATA}/$ENV{FM_RECEIPT_ID}";
sysopen(my $task, $task_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
  or refuse("task directory is missing or unsafe: $task_path");
my @task_identity = stat($task);
refuse("task path is not a directory") unless @task_identity && S_ISDIR($task_identity[2]);
my @named_identity = lstat($task_path);
refuse("task directory identity changed") unless @named_identity
  && !S_ISLNK($named_identity[2])
  && $named_identity[0] == $task_identity[0]
  && $named_identity[1] == $task_identity[1];
my $task_fd_path = "/dev/fd/" . fileno($task);
my @descriptor_identity = stat($task_fd_path);
refuse("portable task descriptor path is unavailable") unless @descriptor_identity
  && $descriptor_identity[0] == $task_identity[0]
  && $descriptor_identity[1] == $task_identity[1];

sysopen(my $brief, "$task_fd_path/brief.md", O_RDONLY | O_NOFOLLOW)
  or refuse("task brief is missing or unsafe");
my @brief_identity = stat($brief);
refuse("task brief is not a regular file") unless @brief_identity && S_ISREG($brief_identity[2]);
sysopen(my $ledger, "$task_fd_path/evidence.jsonl", O_WRONLY | O_APPEND | O_NOFOLLOW)
  or refuse("evidence ledger is missing or unsafe");
my @ledger_identity = stat($ledger);
refuse("evidence ledger must be a single-link regular file") unless @ledger_identity
  && S_ISREG($ledger_identity[2]) && $ledger_identity[3] == 1;
flock($ledger, LOCK_EX) or refuse("evidence ledger could not be locked");

local $/;
my $brief_text = <$brief>;
defined($brief_text) or refuse("task brief could not be read");
my @delivery = ($brief_text =~ /^Delivery contract: mode=(no-mistakes|direct-PR|local-only)$/mg);
refuse("receipts apply only to ship tasks with one delivery contract") unless @delivery == 1;
my %criteria;
my $sections = 0;
my $in_section = 0;
my $invalid = 0;
for my $line (split /\n/, $brief_text, -1) {
  if ($line =~ /^# Acceptance criteria\s*$/) {
    $sections++;
    $in_section = 1;
    next;
  }
  if ($in_section && $line =~ /^#/) {
    $in_section = 0;
  }
  next unless $in_section;
  next if $line =~ /^\s*$/;
  if ($line !~ /^- (AC[1-9][0-9]*):\s+(.+)$/) {
    $invalid = 1;
    next;
  }
  my ($criterion, $description) = ($1, $2);
  $invalid = 1 if $description =~ /^\{.*\}$/ || exists $criteria{$criterion};
  $criteria{$criterion} = 1;
}
refuse("ship brief has an invalid acceptance-criterion contract")
  if $sections != 1 || $invalid || !%criteria;
refuse("criterion is not declared by the ship brief: $ENV{FM_RECEIPT_CRITERION}")
  unless $criteria{$ENV{FM_RECEIPT_CRITERION}};

my $record = "$ENV{FM_RECEIPT_PAYLOAD}\n";
my $written = syswrite($ledger, $record);
refuse("evidence receipt append failed") unless defined($written) && $written == length($record);
close($ledger) or refuse("evidence ledger close failed");
PERL
then
  exit 1
fi
printf '%s\n' "$receipt"
