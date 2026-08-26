#!/usr/bin/env bash
# Check a ship task's acceptance-criterion evidence and plan risk-based validation.
#
# Usage:
#   fm-receipt-check.sh <task-id>
#   fm-receipt-check.sh <task-id> --criterion <criterion-id>
#   fm-receipt-check.sh <task-id> --bind-run <run-id> --generation <plan-generation>
#   fm-receipt-check.sh <task-id> --complete --terminal-evidence <evidence>
#   fm-receipt-check.sh <task-id> --plan [--base <commit>]
#   fm-receipt-check.sh <task-id> --invalidate-claim <finding-id> --invalidated-criterion <criterion-id>
#   fm-receipt-check.sh --parse-criteria <brief-file|-> [--require <criterion-id>]
#
# The default command emits one compact fm-evidence-check.v1 JSON object.
# It exits 0 when every declared criterion has at least one structurally valid
# receipt, 1 when evidence is missing, and 2 for an invalid brief or ledger.
# Tasks whose metadata positively identifies them as scouts or secondmates return
# status=not-applicable without a ledger check.
#
# Acceptance criteria are owned by the exact ship-brief section:
#
#   # Acceptance criteria
#   - AC1: First required outcome.
#   - AC2: Second required outcome.
#
# Every listed criterion is required in v1.
# IDs must be unique AC-prefixed positive integers, and placeholder descriptions
# are invalid once completion is checked.
# Structurally valid receipts with explicit failure, negative, zero-test, empty,
# or skip result indicators remain recorded but do not evidence their criterion.
# A positive result paired only with an explicit zero-failure phrase remains eligible.
#
# --plan first requires a complete evidence check, then inspects the recorded
# worktree's base..HEAD diff with a deterministic conservative classifier.
# A supplied initial --base is accepted only when it equals the repository's
# authoritative merge boundary.
# Unreadable or uncertain inputs resolve to high.
# Risk is binary: high by default, or low only for a narrow CHANGELOG-only prose
# change with strong mechanical evidence.
# Caller hints never lower risk.
# The resolved validation_tier, validation_path, reason code, base, head, size,
# and start time are appended to state/<task-id>.meta for durable inspection.
# Every completion records validation_completed_head and refuses a current
# worktree HEAD that differs from the latest validation_head.
# Low-risk completion requires a strong mechanical receipt appended after planning.
# --complete requires the path-specific terminal evidence named by the generated
# instructions and records that evidence with the latest plan, path, and head;
# exact bound runs may prove current checks-green readiness through the shared CI log predicate.
# --invalidate-claim appends one idempotent finding-to-criterion marker to task
# metadata after confirming that the criterion and evidence contract are current.
# Delivery mode remains authoritative: direct-PR and local-only never invoke
# No-Mistakes, while no-mistakes maps low to receipts-mechanical and high to
# full-no-mistakes, and the pinned brief and metadata mode must match exactly.
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
NO_MISTAKES_BIN="${FM_NO_MISTAKES_BIN:-no-mistakes}"
NM_TIMEOUT=${FM_RECEIPT_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac

# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

parse_criteria() {
  awk '
    BEGIN { in_section=0; found=0; count=0; bad=0 }
    /^# Acceptance criteria[[:space:]]*$/ {
      if (found) bad=1
      found=1
      in_section=1
      next
    }
    in_section && /^#/ { in_section=0 }
    in_section && /^[[:space:]]*$/ { next }
    in_section {
      if ($0 !~ /^- AC[1-9][0-9]*:[[:space:]]+.+/) { bad=1; next }
      line=$0
      sub(/^- /, "", line)
      id=line
      sub(/:.*/, "", id)
      description=line
      sub(/^[^:]*:[[:space:]]*/, "", description)
      if (description !~ /[^[:space:]]/) bad=1
      if (description ~ /^\{.*\}$/) bad=1
      if (seen[id]++) bad=1
      print id "\t" description
      count++
    }
    END {
      if (!found || count == 0 || bad) exit 2
    }
  ' "$1"
}

if [ "${1:-}" = --parse-criteria ]; then
  [ "$#" -eq 2 ] || [ "$#" -eq 4 ] \
    || { echo "error: --parse-criteria requires <brief-file|-> [--require <criterion-id>]" >&2; exit 2; }
  PARSE_INPUT=$2
  PARSE_REQUIRED=
  if [ "$#" -eq 4 ]; then
    [ "$3" = --require ] || { echo "error: unknown parser option: $3" >&2; exit 2; }
    PARSE_REQUIRED=$4
    case "$PARSE_REQUIRED" in AC[1-9]|AC[1-9][0-9]*) ;; *) exit 1 ;; esac
  fi
  PARSE_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-receipt-criteria.XXXXXX")
  trap 'rm -f "$PARSE_TMP"' EXIT
  trap 'exit 1' HUP INT TERM
  parse_criteria "$PARSE_INPUT" > "$PARSE_TMP" \
    || { echo "error: ship brief must contain one valid '# Acceptance criteria' section with unique AC ids and no placeholders" >&2; exit 2; }
  if [ -n "$PARSE_REQUIRED" ] && ! cut -f1 "$PARSE_TMP" | grep -Fx "$PARSE_REQUIRED" >/dev/null 2>&1; then
    exit 1
  fi
  [ -z "$PARSE_REQUIRED" ] || exit 0
  cat "$PARSE_TMP"
  exit 0
fi

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -ge 1 ] || { usage >&2; exit 2; }

ID=$1
shift
case "$ID" in
  ''|.|..|*[!A-Za-z0-9._-]*|[._-]*)
    echo "error: invalid task id: $ID" >&2
    exit 2
    ;;
esac

ACTION=check
CRITERION_QUERY=
BASE_INPUT=
TERMINAL_EVIDENCE=
RUN_ID_INPUT=
RUN_GENERATION_INPUT=
INVALIDATION_FINDING=
INVALIDATION_CRITERION=

while [ "$#" -gt 0 ]; do
  option=$1
  shift
  case "$option" in
    --criterion)
      [ "$#" -gt 0 ] || { echo "error: --criterion requires a value" >&2; exit 2; }
      [ "$ACTION" = check ] || { echo "error: choose only one action" >&2; exit 2; }
      ACTION=criterion
      CRITERION_QUERY=$1
      shift
      ;;
    --plan)
      [ "$ACTION" = check ] || { echo "error: choose only one action" >&2; exit 2; }
      ACTION=plan
      ;;
    --complete)
      [ "$ACTION" = check ] || { echo "error: choose only one action" >&2; exit 2; }
      ACTION=complete
      ;;
    --bind-run)
      [ "$#" -gt 0 ] || { echo "error: --bind-run requires a value" >&2; exit 2; }
      [ "$ACTION" = check ] || { echo "error: choose only one action" >&2; exit 2; }
      ACTION=bind-run
      RUN_ID_INPUT=$1
      shift
      ;;
    --invalidate-claim)
      [ "$#" -gt 0 ] || { echo "error: --invalidate-claim requires a value" >&2; exit 2; }
      [ "$ACTION" = check ] || { echo "error: choose only one action" >&2; exit 2; }
      ACTION=invalidate-claim
      INVALIDATION_FINDING=$1
      shift
      ;;
    --invalidated-criterion)
      [ "$#" -gt 0 ] || { echo "error: --invalidated-criterion requires a value" >&2; exit 2; }
      INVALIDATION_CRITERION=$1
      shift
      ;;
    --generation)
      [ "$#" -gt 0 ] || { echo "error: --generation requires a value" >&2; exit 2; }
      RUN_GENERATION_INPUT=$1
      shift
      ;;
    --base|--terminal-evidence)
      [ "$#" -gt 0 ] || { echo "error: $option requires a value" >&2; exit 2; }
      value=$1
      shift
      case "$option" in
        --base) BASE_INPUT=$value ;;
        --terminal-evidence) TERMINAL_EVIDENCE=$value ;;
      esac
      ;;
    *) echo "error: unknown option: $option" >&2; exit 2 ;;
  esac
done

if [ "$ACTION" != bind-run ] && [ -n "$RUN_GENERATION_INPUT" ]; then
  echo "error: --generation requires --bind-run" >&2
  exit 2
fi
if [ "$ACTION" != invalidate-claim ] && [ -n "$INVALIDATION_CRITERION" ]; then
  echo "error: --invalidated-criterion requires --invalidate-claim" >&2
  exit 2
fi

case "$ACTION" in
  check|criterion|bind-run|invalidate-claim)
    [ -z "$BASE_INPUT" ] || { echo "error: --base requires --plan" >&2; exit 2; }
    [ -z "$TERMINAL_EVIDENCE" ] || { echo "error: --terminal-evidence requires --complete" >&2; exit 2; }
    if [ "$ACTION" = bind-run ]; then
      case "$RUN_ID_INPUT" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid run id" >&2; exit 2 ;; esac
      [ -n "$RUN_GENERATION_INPUT" ] || { echo "error: --bind-run requires --generation" >&2; exit 2; }
    fi
    if [ "$ACTION" = invalidate-claim ]; then
      case "$INVALIDATION_FINDING" in F[1-9]|F[1-9][0-9]*) ;; *) echo "error: invalid finding id" >&2; exit 2 ;; esac
      case "$INVALIDATION_CRITERION" in AC[1-9]|AC[1-9][0-9]*) ;; *) echo "error: invalid invalidated criterion" >&2; exit 2 ;; esac
    fi
    ;;
  complete)
    [ -z "$BASE_INPUT" ] || { echo "error: --base requires --plan" >&2; exit 2; }
    [ -n "$TERMINAL_EVIDENCE" ] || { echo "error: --complete requires --terminal-evidence" >&2; exit 2; }
    ;;
  plan)
    [ -z "$TERMINAL_EVIDENCE" ] || { echo "error: --terminal-evidence requires --complete" >&2; exit 2; }
    ;;
esac

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

TASK_DIR="$DATA/$ID"
BRIEF_PATH="$TASK_DIR/brief.md"
LEDGER_PATH="$TASK_DIR/evidence.jsonl"
META="$STATE/$ID.meta"

[ -f "$META" ] && [ ! -L "$META" ] \
  || { echo "error: task metadata is missing or unsafe: $META" >&2; exit 2; }
KIND_COUNT=$(grep -c '^kind=' "$META" 2>/dev/null || true)
[ "$KIND_COUNT" -eq 1 ] \
  || { echo "error: task metadata must contain exactly one kind" >&2; exit 2; }
KIND=$(sed -n 's/^kind=//p' "$META")
case "$KIND" in
  scout|secondmate)
    if [ "$ACTION" = criterion ]; then exit 1; fi
    if [ "$ACTION" != check ]; then
      echo "error: validation planning applies only to ship tasks" >&2
      exit 2
    fi
    jq -cn --arg task "$ID" \
      '{schema:"fm-evidence-check.v1",task:$task,kind:"non-ship",status:"not-applicable",required:[],evidenced:[],missing:[],invalid:[],receipt_count:0,ledger_exists:false}'
    exit 0
    ;;
  ship) ;;
  *) echo "error: task metadata has an invalid kind" >&2; exit 2 ;;
esac

command -v perl >/dev/null 2>&1 || { echo "error: perl is required" >&2; exit 2; }
[ -d "$DATA" ] || { echo "error: data directory is missing: $DATA" >&2; exit 2; }
DATA_REAL=$(CDPATH='' cd -- "$DATA" 2>/dev/null && pwd -P) \
  || { echo "error: data directory is unsafe: $DATA" >&2; exit 2; }
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-receipt-check.XXXXXX")
VALIDATION_LOCK=
cleanup() {
  [ -z "$VALIDATION_LOCK" ] || rmdir "$VALIDATION_LOCK" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
release_validation_lock() {
  [ -z "$VALIDATION_LOCK" ] || rmdir "$VALIDATION_LOCK" 2>/dev/null || true
  VALIDATION_LOCK=
}
BRIEF="$TMP_ROOT/brief.md"
LEDGER="$TMP_ROOT/evidence.jsonl"
: > "$BRIEF"
: > "$LEDGER"
set +e
FM_RECEIPT_DATA="$DATA_REAL" FM_RECEIPT_ID="$ID" FM_RECEIPT_BRIEF_OUT="$BRIEF" \
  FM_RECEIPT_LEDGER_OUT="$LEDGER" perl - <<'PERL'
use strict;
use warnings;
use Errno qw(ENOENT);
use Fcntl qw(:DEFAULT :flock :mode);

sub refuse {
  print STDERR "error: $_[0]\n";
  exit 1;
}

sub copy_file {
  my ($source, $destination) = @_;
  open(my $output, ">", $destination) or refuse("could not prepare pinned task snapshot");
  my $buffer;
  while (1) {
    my $read = sysread($source, $buffer, 65536);
    defined($read) or refuse("could not read pinned task artifact");
    last if $read == 0;
    print {$output} substr($buffer, 0, $read) or refuse("could not write pinned task snapshot");
  }
  close($output) or refuse("could not close pinned task snapshot");
}

my $task_path = "$ENV{FM_RECEIPT_DATA}/$ENV{FM_RECEIPT_ID}";
sysopen(my $task, $task_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
  or refuse("ship task directory is missing or unsafe: $task_path");
my @task_identity = stat($task);
refuse("ship task path is not a directory") unless @task_identity && S_ISDIR($task_identity[2]);
my @named_identity = lstat($task_path);
refuse("ship task directory identity changed") unless @named_identity
  && !S_ISLNK($named_identity[2])
  && $named_identity[0] == $task_identity[0]
  && $named_identity[1] == $task_identity[1];
my $task_fd_path = "/dev/fd/" . fileno($task);
my @descriptor_identity = stat($task_fd_path);
refuse("portable task descriptor path is unavailable") unless @descriptor_identity
  && $descriptor_identity[0] == $task_identity[0]
  && $descriptor_identity[1] == $task_identity[1];

sysopen(my $brief, "$task_fd_path/brief.md", O_RDONLY | O_NOFOLLOW)
  or refuse("ship task brief is missing or unsafe");
my @brief_identity = stat($brief);
refuse("ship task brief is not a regular file") unless @brief_identity && S_ISREG($brief_identity[2]);
my $ledger_missing = 0;
my $ledger;
if (!sysopen($ledger, "$task_fd_path/evidence.jsonl", O_RDONLY | O_NOFOLLOW)) {
  $ledger_missing = 1 if $! == ENOENT;
  refuse("evidence ledger is missing or unsafe") unless $ledger_missing;
}
if (!$ledger_missing) {
  my @ledger_identity = stat($ledger);
  refuse("evidence ledger must be a single-link regular file") unless @ledger_identity
    && S_ISREG($ledger_identity[2]) && $ledger_identity[3] == 1;
  flock($ledger, LOCK_SH) or refuse("evidence ledger could not be locked");
}

copy_file($brief, $ENV{FM_RECEIPT_BRIEF_OUT});
copy_file($ledger, $ENV{FM_RECEIPT_LEDGER_OUT}) unless $ledger_missing;
exit($ledger_missing ? 3 : 0);
PERL
SNAPSHOT_RC=$?
set -e
case "$SNAPSHOT_RC" in
  0) PINNED_LEDGER_EXISTS=true ;;
  3) PINNED_LEDGER_EXISTS=false ;;
  *) exit 2 ;;
esac

MODE_COUNT=$(grep -c '^Delivery contract: mode=' "$BRIEF" 2>/dev/null || true)
if [ "$MODE_COUNT" -eq 1 ]; then
  MODE=$(sed -n 's/^Delivery contract: mode=//p' "$BRIEF")
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    *) echo "error: ship brief has an invalid delivery contract" >&2; exit 2 ;;
  esac
elif [ "$MODE_COUNT" -eq 0 ]; then
  echo "error: ship brief has no delivery contract" >&2
  exit 2
else
  echo "error: ship brief has multiple delivery contracts" >&2
  exit 2
fi
META_MODE_COUNT=$(grep -c '^mode=' "$META" 2>/dev/null || true)
[ "$META_MODE_COUNT" -eq 1 ] \
  || { echo "error: task metadata must contain exactly one concrete delivery mode" >&2; exit 2; }
META_MODE=$(sed -n 's/^mode=//p' "$META")
case "$META_MODE" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "error: task metadata has no concrete delivery mode" >&2; exit 2 ;;
esac
[ "$META_MODE" = "$MODE" ] \
  || { echo "error: task metadata delivery mode contradicts the pinned ship brief" >&2; exit 2; }
CRITERIA="$TMP_ROOT/criteria.tsv"
EVIDENCED="$TMP_ROOT/evidenced"
INVALID="$TMP_ROOT/invalid"
STRONG_RESULT_MODULE="$TMP_ROOT/strong-result.jq"
: > "$EVIDENCED"
: > "$INVALID"
cat > "$STRONG_RESULT_MODULE" <<'JQ'
def without_zero_failures:
  gsub("(^|[^0-9])0[[:space:]]+fail(s|ed|ures?)?([^[:alnum:]_]|$)"; " "; "i")
  | sub("[[:space:],;:]+$"; "")
  | sub("^[[:space:],;:]+"; "");
def evidence_result:
  without_zero_failures
  |
  (test("^[[:space:]]*$") | not)
  and (test("(^|[^[:alnum:]_])(fail(s|ed|ures?)?|error|negative|red|broken|skip(s|ped|ping)?|empty)([^[:alnum:]_]|$)|not[[:space:]]+pass(ed)?|no[[:space:]]+tests?|(^|[^0-9])0[[:space:]]+(tests?([[:space:]]+passed)?|passed)([^[:alnum:]_]|$)"; "i") | not);
def strong_result:
  without_zero_failures
  | evidence_result
  and test("^([[:space:]]*(pass(ed)?|success(ful)?|green|clean|ok)[[:space:]]*|[[:space:]]*[1-9][0-9]*[[:space:]]+(tests?[[:space:]]+)?passed([[:space:]].*)?)$"; "i");
JQ

"$SCRIPT_DIR/fm-receipt-check.sh" --parse-criteria "$BRIEF" > "$CRITERIA" || exit 2

if [ "$ACTION" = criterion ]; then
  case "$CRITERION_QUERY" in
    AC[1-9]|AC[1-9][0-9]*) ;;
    *) exit 1 ;;
  esac
  cut -f1 "$CRITERIA" | grep -Fx "$CRITERION_QUERY" >/dev/null 2>&1
  exit $?
fi

RECEIPT_COUNT=0
LEDGER_EXISTS=$PINNED_LEDGER_EXISTS
if [ "$LEDGER_EXISTS" = true ]; then
  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    [ -n "$line" ] || { printf 'line %s: blank JSONL record\n' "$line_number" >> "$INVALID"; continue; }
    if ! printf '%s' "$line" | jq -e '
      type == "object"
      and ((keys - ["artifact","command","criterion","file","result","summary","type"]) | length == 0)
      and (.criterion | type == "string" and test("^AC[1-9][0-9]*$"))
      and (.type | type == "string" and test("^(test|build|lint|typecheck|api|browser|manual|review)$"))
      and (.summary | type == "string" and length > 0)
      and (.result | type == "string" and length > 0)
      and ((.command // "") | type == "string")
      and ((.artifact // "") | type == "string")
      and ((.file // "") | type == "string")
    ' >/dev/null 2>&1; then
      printf 'line %s: invalid v1 receipt\n' "$line_number" >> "$INVALID"
      continue
    fi
    receipt_criterion=$(printf '%s' "$line" | jq -r '.criterion')
    if ! cut -f1 "$CRITERIA" | grep -Fx "$receipt_criterion" >/dev/null 2>&1; then
      printf 'line %s: undeclared criterion %s\n' "$line_number" "$receipt_criterion" >> "$INVALID"
      continue
    fi
    RECEIPT_COUNT=$((RECEIPT_COUNT + 1))
    if printf '%s' "$line" | jq -L "$TMP_ROOT" -e 'include "strong-result"; .result | evidence_result' >/dev/null 2>&1; then
      printf '%s\n' "$receipt_criterion" >> "$EVIDENCED"
    fi
  done < "$LEDGER"
fi

REQUIRED_JSON=$(cut -f1 "$CRITERIA" | jq -Rsc 'split("\n") | map(select(length > 0))')
EVIDENCED_ORDERED="$TMP_ROOT/evidenced-ordered"
MISSING="$TMP_ROOT/missing"
: > "$EVIDENCED_ORDERED"
: > "$MISSING"
while IFS=$'\t' read -r criterion _description; do
  if grep -Fx "$criterion" "$EVIDENCED" >/dev/null 2>&1; then
    printf '%s\n' "$criterion" >> "$EVIDENCED_ORDERED"
  else
    printf '%s\n' "$criterion" >> "$MISSING"
  fi
done < "$CRITERIA"
EVIDENCED_JSON=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$EVIDENCED_ORDERED")
MISSING_JSON=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$MISSING")
INVALID_JSON=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$INVALID")

if [ -s "$INVALID" ]; then
  CHECK_STATUS=invalid
  CHECK_RC=2
elif [ -s "$MISSING" ]; then
  CHECK_STATUS=missing
  CHECK_RC=1
else
  CHECK_STATUS=complete
  CHECK_RC=0
fi

CHECK_JSON=$(jq -cn \
  --arg task "$ID" \
  --arg status "$CHECK_STATUS" \
  --arg ledger "$LEDGER_PATH" \
  --argjson required "$REQUIRED_JSON" \
  --argjson evidenced "$EVIDENCED_JSON" \
  --argjson missing "$MISSING_JSON" \
  --argjson invalid "$INVALID_JSON" \
  --argjson receipt_count "$RECEIPT_COUNT" \
  --argjson ledger_exists "$LEDGER_EXISTS" \
  '{schema:"fm-evidence-check.v1",task:$task,kind:"ship",status:$status,required:$required,evidenced:$evidenced,missing:$missing,invalid:$invalid,receipt_count:$receipt_count,ledger:$ledger,ledger_exists:$ledger_exists}')

if [ "$ACTION" = check ]; then
  printf '%s\n' "$CHECK_JSON"
  exit "$CHECK_RC"
fi

if [ "$CHECK_RC" -ne 0 ]; then
  printf '%s\n' "$CHECK_JSON"
  exit "$CHECK_RC"
fi

if [ "$ACTION" = invalidate-claim ]; then
  cut -f1 "$CRITERIA" | grep -Fx "$INVALIDATION_CRITERION" >/dev/null 2>&1 \
    || { echo "error: invalidated criterion is not declared by the ship brief" >&2; exit 2; }
  INVALIDATION_MARKER="validation_claim_invalidation=$INVALIDATION_FINDING:$INVALIDATION_CRITERION"
  VALIDATION_LOCK="$STATE/.$ID.validation-plan.lock"
  if ! mkdir "$VALIDATION_LOCK" 2>/dev/null; then
    VALIDATION_LOCK=
    echo "error: validation metadata is locked" >&2
    exit 2
  fi
  if ! grep -Fx "$INVALIDATION_MARKER" "$META" >/dev/null 2>&1; then
    printf '%s\n' "$INVALIDATION_MARKER" >> "$META" \
      || { release_validation_lock; echo "error: could not record claim invalidation" >&2; exit 2; }
  fi
  release_validation_lock
  jq -cn --arg task "$ID" --arg finding "$INVALIDATION_FINDING" --arg criterion "$INVALIDATION_CRITERION" \
    '{schema:"fm-claim-invalidation.v1",task:$task,status:"recorded",finding:$finding,criterion:$criterion}'
  exit 0
fi

nm_status_field() {
  printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" | head -1
}

if [ "$ACTION" = bind-run ]; then
  BIND_WORKTREE=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  BIND_PATH=$(grep '^validation_path=' "$META" | tail -1 | cut -d= -f2- || true)
  BIND_HEAD=$(grep '^validation_head=' "$META" | tail -1 | cut -d= -f2- || true)
  BIND_GENERATION=$(grep '^validation_generation=' "$META" | tail -1 | cut -d= -f2- || true)
  BIND_PREPLAN_RUN=$(grep '^validation_preplan_run_id=' "$META" | tail -1 | cut -d= -f2- || true)
  [ "$BIND_PATH" = full-no-mistakes ] || { echo "error: latest plan does not use full No-Mistakes" >&2; exit 2; }
  [ -n "$BIND_WORKTREE" ] && [ -d "$BIND_WORKTREE" ] || { echo "error: validation worktree is missing" >&2; exit 2; }
  BIND_HEAD=$(git -C "$BIND_WORKTREE" rev-parse --verify "$BIND_HEAD^{commit}" 2>/dev/null) \
    || { echo "error: validated head is missing" >&2; exit 2; }
  [ -z "$(git -C "$BIND_WORKTREE" status --porcelain --untracked-files=all 2>/dev/null)" ] \
    || { echo "error: validation worktree is dirty" >&2; exit 2; }
  BIND_OUT=$(cd "$BIND_WORKTREE" && "$NO_MISTAKES_BIN" axi status --run "$RUN_ID_INPUT" 2>/dev/null) \
    || { echo "error: No-Mistakes run could not be observed" >&2; exit 2; }
  BIND_INTENT=$(cd "$BIND_WORKTREE" && "$NO_MISTAKES_BIN" axi logs --step intent --run "$RUN_ID_INPUT" 2>/dev/null) \
    || { echo "error: No-Mistakes run intent could not be observed" >&2; exit 2; }
  BIND_OBSERVED_ID=$(nm_status_field "$BIND_OUT" id)
  BIND_OBSERVED_HEAD=$(nm_status_field "$BIND_OUT" head)
  BIND_STATUS=$(nm_status_field "$BIND_OUT" status)
  BIND_OUTCOME=$(nm_status_field "$BIND_OUT" outcome)
  [ "$RUN_ID_INPUT" != "$BIND_PREPLAN_RUN" ] || { echo "error: No-Mistakes run predates the latest plan" >&2; exit 2; }
  [ "$RUN_GENERATION_INPUT" = "$BIND_GENERATION" ] || { echo "error: run generation does not match the latest plan" >&2; exit 2; }
  printf '%s\n' "$BIND_INTENT" | grep -Fqx "Firstmate-Validation-Generation: $BIND_GENERATION" \
    || { echo "error: No-Mistakes run was not created for the latest plan generation" >&2; exit 2; }
  [ "$BIND_OBSERVED_ID" = "$RUN_ID_INPUT" ] && [ "$BIND_OBSERVED_HEAD" = "$BIND_HEAD" ] \
    && { [ "$BIND_STATUS" = running ] || [ "$BIND_STATUS" = fixing ] || [ "$BIND_STATUS" = ci ] || [ "$BIND_STATUS" = awaiting_approval ]; } \
    && [ "$BIND_OUTCOME" != passed ] \
    || { echo "error: No-Mistakes run does not match the latest plan" >&2; exit 2; }
  [ -n "$BIND_GENERATION" ] || { echo "error: validation generation is missing" >&2; exit 2; }
  printf 'validation_run_id=%s\nvalidation_run_path=%s\nvalidation_run_head=%s\nvalidation_run_generation=%s\n' \
    "$RUN_ID_INPUT" "$BIND_PATH" "$BIND_HEAD" "$BIND_GENERATION" >> "$META"
  jq -cn --arg task "$ID" --arg run "$RUN_ID_INPUT" --arg path "$BIND_PATH" --arg head "$BIND_HEAD" \
    '{schema:"fm-validation-run-binding.v1",task:$task,status:"bound",run:$run,path:$path,head:$head}'
  exit 0
fi

record_validation_completed() {
  local started path generation completed completed_head completed_path completed_evidence completed_generation now worktree validated_head current_head expected_evidence observed pr pr_head branch boundary new_receipts run_id run_path run_generation run_out observed_id observed_head outcome run_status default_ref default_branch ci_state run_ready
  VALIDATION_LOCK="$STATE/.$ID.validation-plan.lock"
  if ! mkdir "$VALIDATION_LOCK" 2>/dev/null; then
    VALIDATION_LOCK=
    echo "error: validation metadata is locked by another planner" >&2
    return 1
  fi
  started=$(grep '^validation_started_at=' "$META" | head -1 | cut -d= -f2- || true)
  path=$(grep '^validation_path=' "$META" | tail -1 | cut -d= -f2- || true)
  generation=$(grep '^validation_generation=' "$META" | tail -1 | cut -d= -f2- || true)
  worktree=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  validated_head=$(grep '^validation_head=' "$META" | tail -1 | cut -d= -f2- || true)
  case "$started" in
    ''|*[!0-9]*) release_validation_lock; echo "error: validation start timestamp is missing or invalid" >&2; return 1 ;;
  esac
  case "$path" in
    receipts-mechanical) expected_evidence=mechanical-checks-passed ;;
    full-no-mistakes) expected_evidence=no-mistakes-passed ;;
    direct-PR) expected_evidence='pr-opened' ;;
    local-only) expected_evidence='branch-ready' ;;
    *) release_validation_lock; echo "error: validation path is missing or invalid" >&2; return 1 ;;
  esac
  [ "$TERMINAL_EVIDENCE" = "$expected_evidence" ] \
    || { release_validation_lock; echo "error: terminal evidence does not match validation path $path" >&2; return 1; }
  [ -n "$worktree" ] && [ -d "$worktree" ] \
    || { release_validation_lock; echo "error: validation worktree is missing" >&2; return 1; }
  validated_head=$(git -C "$worktree" rev-parse --verify "$validated_head^{commit}" 2>/dev/null) \
    || { release_validation_lock; echo "error: validated head is missing or invalid" >&2; return 1; }
  current_head=$(git -C "$worktree" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || { release_validation_lock; echo "error: current worktree head is unavailable" >&2; return 1; }
  [ -z "$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null)" ] \
    || { release_validation_lock; echo "error: validation worktree is dirty; commit or remove all changes" >&2; return 1; }
  if [ "$current_head" != "$validated_head" ]; then
    printf 'validation_completed_at=\nvalidation_completed_head=\nvalidation_completed_path=\nvalidation_completed_evidence=\nvalidation_completed_generation=\n' >> "$META" \
      || { release_validation_lock; echo "error: could not invalidate stale validation completion" >&2; return 1; }
    release_validation_lock
    echo "error: current worktree head differs from the validated head; replan and revalidate" >&2
    return 1
  fi
  observed=
  case "$path" in
    receipts-mechanical)
      boundary=$(grep '^validation_ledger_receipt_count=' "$META" | tail -1 | cut -d= -f2- || true)
      case "$boundary" in ''|*[!0-9]*) release_validation_lock; echo "error: mechanical evidence boundary is missing" >&2; return 1 ;; esac
      new_receipts="$TMP_ROOT/completion-new-receipts.jsonl"
      tail -n "+$((boundary + 1))" "$LEDGER" > "$new_receipts"
      jq -L "$TMP_ROOT" -se 'include "strong-result"; any(.[]; (.type | test("^(test|build|lint|typecheck)$")) and (.result | strong_result))' \
        "$new_receipts" >/dev/null 2>&1 \
        || { release_validation_lock; echo "error: no post-plan mechanical evidence was observed" >&2; return 1; }
      observed=post-plan-mechanical-receipt
      ;;
    full-no-mistakes)
      run_id=$(grep '^validation_run_id=' "$META" | tail -1 | cut -d= -f2- || true)
      run_path=$(grep '^validation_run_path=' "$META" | tail -1 | cut -d= -f2- || true)
      run_generation=$(grep '^validation_run_generation=' "$META" | tail -1 | cut -d= -f2- || true)
      observed_head=$(grep '^validation_run_head=' "$META" | tail -1 | cut -d= -f2- || true)
      [ -n "$run_id" ] && [ "$run_path" = "$path" ] && [ "$run_generation" = "$generation" ] && [ "$observed_head" = "$validated_head" ] \
        || { release_validation_lock; echo "error: no No-Mistakes run is bound to the latest plan" >&2; return 1; }
      run_out=$(cd "$worktree" && "$NO_MISTAKES_BIN" axi status --run "$run_id" 2>/dev/null) \
        || { release_validation_lock; echo "error: bound No-Mistakes run could not be observed" >&2; return 1; }
      observed_id=$(nm_status_field "$run_out" id)
      observed_head=$(nm_status_field "$run_out" head)
      outcome=$(nm_status_field "$run_out" outcome)
      run_status=$(nm_status_field "$run_out" status)
      run_ready=0
      if [ "$outcome" = passed ] || [ "$outcome" = checks-passed ] || [ "$run_status" = checks-passed ]; then
        run_ready=1
      elif [ "$run_status" = ci ] || [ "$run_status" = running ]; then
        ci_state=$(fm_nm_ci_checks_state "$worktree" "$NM_TIMEOUT" "$run_id")
        [ "$ci_state" != green ] || run_ready=1
      fi
      if [ "$observed_id" != "$run_id" ] || [ "$observed_head" != "$validated_head" ] || [ "$run_ready" -ne 1 ]; then
        release_validation_lock
        echo "error: bound No-Mistakes run did not pass checks at the exact validated head" >&2
        return 1
      fi
      observed=bound-matching-no-mistakes-run
      ;;
    direct-PR)
      pr=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
      pr_head=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
      case "$pr" in
        https://github.com/*)
          [ "$pr_head" = "$validated_head" ] \
            || { release_validation_lock; echo "error: GitHub PR head is missing or not bound to the validated head" >&2; return 1; }
          observed=canonical-github-pr-head
          ;;
        https://*) observed=canonical-non-github-pr ;;
        *) release_validation_lock; echo "error: canonical PR metadata is missing" >&2; return 1 ;;
      esac
      ;;
    local-only)
      branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
      [ "$branch" = "fm/$ID" ] \
        || { release_validation_lock; echo "error: local-only branch is not ready" >&2; return 1; }
      default_ref=$(git -C "$worktree" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
      default_ref=${default_ref#origin/}
      if [ -n "$default_ref" ]; then
        git -C "$worktree" show-ref --verify --quiet "refs/heads/$default_ref" \
          || { release_validation_lock; echo "error: authoritative local default branch is missing" >&2; return 1; }
        default_ref="refs/heads/$default_ref"
      else
        for default_branch in main master; do
          if git -C "$worktree" show-ref --verify --quiet "refs/heads/$default_branch"; then
            default_ref="refs/heads/$default_branch"
            break
          fi
        done
      fi
      if [ -z "$default_ref" ] \
        || ! git -C "$worktree" merge-base --is-ancestor "$default_ref" "$validated_head" 2>/dev/null; then
        release_validation_lock
        echo "error: local-only branch is not fast-forward ready" >&2
        return 1
      fi
      observed=clean-ready-branch
      ;;
  esac
  completed=$(grep '^validation_completed_at=' "$META" | tail -1 | cut -d= -f2- || true)
  completed_head=$(grep '^validation_completed_head=' "$META" | tail -1 | cut -d= -f2- || true)
  completed_path=$(grep '^validation_completed_path=' "$META" | tail -1 | cut -d= -f2- || true)
  completed_evidence=$(grep '^validation_completed_evidence=' "$META" | tail -1 | cut -d= -f2- || true)
  completed_generation=$(grep '^validation_completed_generation=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -n "$completed_head" ]; then
    [ -n "$completed" ] \
      || { release_validation_lock; echo "error: validation completion timestamp is missing" >&2; return 1; }
    case "$completed" in
      *[!0-9]*) release_validation_lock; echo "error: validation completion timestamp is invalid" >&2; return 1 ;;
    esac
    completed_head=$(git -C "$worktree" rev-parse --verify "$completed_head^{commit}" 2>/dev/null) \
      || { release_validation_lock; echo "error: validation completed head is invalid" >&2; return 1; }
  fi
  if [ "$completed_head:$completed_path:$completed_evidence:$completed_generation" != "$validated_head:$path:$observed:$generation" ]; then
    now=$(date +%s)
    printf 'validation_completed_at=%s\nvalidation_completed_head=%s\nvalidation_completed_path=%s\nvalidation_completed_evidence=%s\nvalidation_completed_generation=%s\n' \
      "$now" "$validated_head" "$path" "$observed" "$generation" >> "$META" \
      || { release_validation_lock; echo "error: could not record validation completion" >&2; return 1; }
    completed=$now
    completed_head=$validated_head
  fi
  release_validation_lock
  VALIDATION_COMPLETED=$completed
  VALIDATION_COMPLETED_HEAD=$completed_head
  VALIDATION_COMPLETED_PATH=$path
  VALIDATION_COMPLETED_EVIDENCE=$observed
}

if [ "$ACTION" = complete ]; then
  record_validation_completed || exit 2
  jq -cn --arg task "$ID" --argjson completed_at "$VALIDATION_COMPLETED" --arg completed_head "$VALIDATION_COMPLETED_HEAD" \
    --arg path "$VALIDATION_COMPLETED_PATH" --arg evidence "$VALIDATION_COMPLETED_EVIDENCE" \
    '{schema:"fm-validation-completion.v1",task:$task,status:"completed",completed_at:$completed_at,completed_head:$completed_head,path:$path,evidence:$evidence}'
  exit 0
fi

[ -f "$META" ] && [ ! -L "$META" ] \
  || { echo "error: task metadata is missing or unsafe: $META" >&2; exit 2; }
WORKTREE=$(grep '^worktree=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
[ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] \
  || { echo "error: validation worktree is missing" >&2; exit 2; }
if [ -n "$(git -C "$WORKTREE" status --porcelain --untracked-files=all 2>/dev/null)" ]; then
  echo "error: validation worktree is dirty; commit or remove all changes" >&2
  exit 2
fi

BASE=
HEAD=
DIFF_AVAILABLE=0
DIFF_FILES=0
DIFF_LINES=0
HAS_BINARY=0
HAS_SPECIAL_MODE=0
LOW_PATH=1
NUMSTAT="$TMP_ROOT/numstat"
NAMES="$TMP_ROOT/names"
: > "$NUMSTAT"
: > "$NAMES"

resolve_diff() {
  local requested_base authoritative_base origin_head
  [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] && git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1 || return 1
  [ -z "$(git -C "$WORKTREE" status --porcelain --untracked-files=all 2>/dev/null)" ] || return 1
  HEAD=$(git -C "$WORKTREE" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  origin_head=$(git -C "$WORKTREE" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$origin_head" ]; then
    authoritative_base=$(git -C "$WORKTREE" merge-base HEAD "$origin_head" 2>/dev/null) || return 1
  else
    authoritative_base=$(git -C "$WORKTREE" merge-base HEAD main 2>/dev/null \
      || git -C "$WORKTREE" merge-base HEAD master 2>/dev/null) || return 1
  fi
  BASE=$authoritative_base
  if [ -n "$BASE_INPUT" ]; then
    requested_base=$(git -C "$WORKTREE" rev-parse --verify "$BASE_INPUT^{commit}" 2>/dev/null) || return 1
    [ "$requested_base" = "$authoritative_base" ] || return 1
  fi
  git -C "$WORKTREE" merge-base --is-ancestor "$BASE" "$HEAD" 2>/dev/null || return 1
  git -C "$WORKTREE" diff --no-ext-diff --no-renames --numstat "$BASE..$HEAD" > "$NUMSTAT" 2>/dev/null || return 1
  git -C "$WORKTREE" diff --no-ext-diff --no-renames --name-only "$BASE..$HEAD" > "$NAMES" 2>/dev/null || return 1
  if git -C "$WORKTREE" diff --no-ext-diff --no-renames --summary "$BASE..$HEAD" \
    | grep -Eq '(mode change|mode (100755|120000|160000))'; then
    HAS_SPECIAL_MODE=1
  fi
  DIFF_AVAILABLE=1
}

resolve_diff || true
if [ "$DIFF_AVAILABLE" -eq 1 ]; then
  while IFS=$'\t' read -r added deleted path; do
    [ -n "$path" ] || continue
    DIFF_FILES=$((DIFF_FILES + 1))
    case "$added:$deleted" in
      *-*) HAS_BINARY=1 ;;
      *) DIFF_LINES=$((DIFF_LINES + added + deleted)) ;;
    esac
    case "$path" in
      CHANGELOG.md) ;;
      *) LOW_PATH=0 ;;
    esac
  done < "$NUMSTAT"
fi

MECHANICAL_PROOF=0
if jq -L "$TMP_ROOT" -se '
  include "strong-result";
  any(.[]; (.type | test("^(test|build|lint|typecheck)$")) and (.result | strong_result))
' "$LEDGER" >/dev/null 2>&1; then
  MECHANICAL_PROOF=1
fi

TIER=high
REASON=uncertain-input
if [ "$DIFF_AVAILABLE" -eq 0 ] || [ "$DIFF_FILES" -eq 0 ]; then
  TIER=high
  REASON=unreadable-or-empty-diff
elif [ "$HAS_SPECIAL_MODE" -eq 1 ]; then
  TIER=high
  REASON=special-file-or-mode-change
elif [ "$HAS_BINARY" -eq 1 ]; then
  TIER=high
  REASON=binary-change
elif [ "$DIFF_FILES" -gt 8 ] || [ "$DIFF_LINES" -gt 400 ]; then
  TIER=high
  REASON=broad-change
elif [ "$LOW_PATH" -eq 1 ] && [ "$DIFF_FILES" -le 3 ] && [ "$DIFF_LINES" -le 80 ] \
  && [ "$MECHANICAL_PROOF" -eq 1 ]; then
  TIER=low
  REASON=non-authoritative-prose
else
  TIER=high
  REASON=default-high
fi

case "$MODE:$TIER" in
  direct-PR:*) VALIDATION_PATH=direct-PR ;;
  local-only:*) VALIDATION_PATH=local-only ;;
  no-mistakes:low) VALIDATION_PATH=receipts-mechanical ;;
  no-mistakes:high) VALIDATION_PATH=full-no-mistakes ;;
esac

write_meta_record() {  # <pass>
  local pass=$1 now started previous_generation
  now=$(date +%s)
  VALIDATION_LOCK="$STATE/.$ID.validation-plan.lock"
  if ! mkdir "$VALIDATION_LOCK" 2>/dev/null; then
    VALIDATION_LOCK=
    echo "error: validation metadata is locked by another planner: $STATE/.$ID.validation-plan.lock" >&2
    return 1
  fi
  started=$(grep '^validation_started_at=' "$META" | head -1 | cut -d= -f2- || true)
  previous_generation=$(grep '^validation_generation=' "$META" | tail -1 | cut -d= -f2- || true)
  case "$started" in
    '') ;;
    *[!0-9]*) release_validation_lock; echo "error: validation start timestamp is invalid" >&2; return 1 ;;
  esac
  if ! {
    printf 'validation_generation=%s\n' "$PLAN_GENERATION"
    printf 'validation_tier=%s\n' "$TIER"
    printf 'validation_path=%s\n' "$VALIDATION_PATH"
    printf 'validation_reason=%s\n' "$REASON"
    printf 'validation_base=%s\n' "$BASE"
    printf 'validation_head=%s\n' "$HEAD"
    printf 'validation_diff_files=%s\n' "$DIFF_FILES"
    printf 'validation_diff_lines=%s\n' "$DIFF_LINES"
    printf 'validation_pass=%s\n' "$pass"
    [ -n "$started" ] || printf 'validation_started_at=%s\n' "$now"
    printf 'validation_ledger_receipt_count=%s\n' "$RECEIPT_COUNT"
    printf 'validation_preplan_run_id=%s\n' "${PREPLAN_RUN_ID:-}"
    if [ -n "$previous_generation" ]; then
      printf 'validation_run_id=\nvalidation_run_path=\nvalidation_run_head=\nvalidation_run_generation=\n'
      printf 'validation_completed_at=\nvalidation_completed_head=\nvalidation_completed_path=\nvalidation_completed_evidence=\nvalidation_completed_generation=\n'
    fi
  } >> "$META"; then
    release_validation_lock
    echo "error: could not append validation metadata: $META" >&2
    return 1
  fi
  release_validation_lock
}

PLAN_GENERATION=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[ "${#PLAN_GENERATION}" -eq 32 ] || { echo "error: validation generation could not be created" >&2; exit 2; }
PREPLAN_RUN_ID=
if [ "$VALIDATION_PATH" = full-no-mistakes ]; then
  PREPLAN_OUT=$(cd "$WORKTREE" && "$NO_MISTAKES_BIN" axi status 2>/dev/null) \
    || { echo "error: pre-plan No-Mistakes boundary could not be observed" >&2; exit 2; }
  PREPLAN_RUN_ID=$(nm_status_field "$PREPLAN_OUT" id)
fi
write_meta_record initial
jq -cn --arg task "$ID" --arg mode "$MODE" --arg tier "$TIER" --arg path "$VALIDATION_PATH" --arg reason "$REASON" \
  --arg base "$BASE" --arg head "$HEAD" --arg generation "$PLAN_GENERATION" \
  --argjson diff_files "$DIFF_FILES" --argjson diff_lines "$DIFF_LINES" \
  '{schema:"fm-validation-plan.v1",task:$task,status:"planned",mode:$mode,tier:$tier,path:$path,reason:$reason,base:$base,head:$head,generation:$generation,diff_files:$diff_files,diff_lines:$diff_lines}'
