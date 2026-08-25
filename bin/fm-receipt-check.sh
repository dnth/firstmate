#!/usr/bin/env bash
# Check a ship task's acceptance-criterion evidence and plan risk-based validation.
#
# Usage:
#   fm-receipt-check.sh <task-id>
#   fm-receipt-check.sh <task-id> --criterion <criterion-id>
#   fm-receipt-check.sh <task-id> --plan [--base <commit>]
#                       [--change-class <localized-non-sensitive|sensitive>]
#                       [--risky-area <text>]...
#   fm-receipt-check.sh <task-id> --follow-up --delta-base <commit>
#                       [--change-class <localized-non-sensitive|sensitive>]
#                       [--risky-area <text>]...
#                       (--finding <text>|--finding-file <path>)...
#                       [--invalidated-criterion <criterion-id>]...
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
#
# --plan first requires a complete evidence check, then inspects the recorded
# worktree's base..HEAD diff with a deterministic conservative classifier.
# Unreadable or uncertain inputs resolve to high.
# Low is limited to a small documentation diff or an allowlisted mechanical-config
# diff whose changed config files are named by strong mechanical receipts.
# Medium requires --change-class localized-non-sensitive plus a strong passing
# test receipt.
# Free-form risky-area text is packet context and can raise risk but never proves
# that a change is non-sensitive.
# Security, migration, concurrency, state/lifecycle, broad, binary, weakly proven,
# undeclared, or otherwise uncertain changes resolve to high.
# The resolved validation_tier, validation_path, reason code, base, head, size,
# and start time are appended to state/<task-id>.meta for durable inspection.
# Delivery mode remains authoritative: direct-PR and local-only never invoke
# No-Mistakes, while no-mistakes maps low to receipts-mechanical, medium to a
# targeted audit packet, and high to full-no-mistakes.
#
# A medium plan writes data/<task-id>/audit-packet.md with the task contract,
# evidence ledger, base..HEAD diff, declared risky areas, and narrow audit remit.
# --follow-up freshly classifies the complete change and rewrites the packet around
# the original finding, a non-empty strict-descendant delta, and updated receipts
# only when the complete change still classifies medium and --delta-base exactly
# matches the latest recorded validation head.
# Initial planning records the ledger receipt count, and every invalidated criterion
# requires a matching receipt appended after that boundary.
# A material scope/risk change records high/full-no-mistakes and refuses the
# bounded follow-up so the supervisor retains a full rerun.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

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
DELTA_BASE=
RISKY_AREAS=
CHANGE_CLASS=
FINDINGS=
FINDING_COUNT=0
INVALIDATED=
INVALIDATED_COUNT=0

append_value() {  # <current> <value>
  if [ -n "$1" ]; then printf '%s\n%s' "$1" "$2"; else printf '%s' "$2"; fi
}

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
    --follow-up)
      [ "$ACTION" = check ] || { echo "error: choose only one action" >&2; exit 2; }
      ACTION=follow-up
      ;;
    --base|--delta-base|--change-class|--risky-area|--finding|--finding-file|--invalidated-criterion)
      [ "$#" -gt 0 ] || { echo "error: $option requires a value" >&2; exit 2; }
      value=$1
      shift
      case "$option" in
        --base) BASE_INPUT=$value ;;
        --delta-base) DELTA_BASE=$value ;;
        --change-class) CHANGE_CLASS=$value ;;
        --risky-area) RISKY_AREAS=$(append_value "$RISKY_AREAS" "$value") ;;
        --finding)
          FINDINGS=$(append_value "$FINDINGS" "$value")
          FINDING_COUNT=$((FINDING_COUNT + 1))
          ;;
        --finding-file)
          [ -f "$value" ] && [ ! -L "$value" ] \
            || { echo "error: finding file is missing or unsafe: $value" >&2; exit 2; }
          finding_text=$(cat "$value")
          [ -n "$finding_text" ] || { echo "error: finding file is empty: $value" >&2; exit 2; }
          FINDINGS=$(append_value "$FINDINGS" "$finding_text")
          FINDING_COUNT=$((FINDING_COUNT + 1))
          ;;
        --invalidated-criterion)
          INVALIDATED=$(append_value "$INVALIDATED" "$value")
          INVALIDATED_COUNT=$((INVALIDATED_COUNT + 1))
          ;;
      esac
      ;;
    *) echo "error: unknown option: $option" >&2; exit 2 ;;
  esac
done

case "$CHANGE_CLASS" in
  ''|localized-non-sensitive|sensitive) ;;
  *) echo "error: --change-class must be localized-non-sensitive or sensitive" >&2; exit 2 ;;
esac

case "$ACTION" in
  check|criterion)
    [ -z "$BASE_INPUT$DELTA_BASE$CHANGE_CLASS$RISKY_AREAS$FINDINGS$INVALIDATED" ] \
      || { echo "error: validation-planning options require --plan or --follow-up" >&2; exit 2; }
    ;;
  plan)
    [ -z "$DELTA_BASE$FINDINGS$INVALIDATED" ] \
      || { echo "error: follow-up options require --follow-up" >&2; exit 2; }
    ;;
  follow-up)
    [ -z "$BASE_INPUT" ] \
      || { echo "error: --base applies only to --plan" >&2; exit 2; }
    [ -n "$DELTA_BASE" ] || { echo "error: --follow-up requires --delta-base" >&2; exit 2; }
    [ "$FINDING_COUNT" -gt 0 ] || { echo "error: --follow-up requires a finding" >&2; exit 2; }
    ;;
esac

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

TASK_DIR="$DATA/$ID"
BRIEF="$TASK_DIR/brief.md"
LEDGER="$TASK_DIR/evidence.jsonl"
META="$STATE/$ID.meta"
PACKET="$TASK_DIR/audit-packet.md"

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

[ -f "$BRIEF" ] && [ ! -L "$BRIEF" ] \
  || { echo "error: ship task brief is missing or unsafe: $BRIEF" >&2; exit 2; }

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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-receipt-check.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM
CRITERIA="$TMP_ROOT/criteria.tsv"
EVIDENCED="$TMP_ROOT/evidenced"
INVALID="$TMP_ROOT/invalid"
: > "$EVIDENCED"
: > "$INVALID"

if ! awk '
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
    if (description ~ /^\{.*\}$/) bad=1
    if (seen[id]++) bad=1
    print id "\t" description
    count++
  }
  END {
    if (!found || count == 0 || bad) exit 1
  }
' "$BRIEF" > "$CRITERIA"; then
  echo "error: ship brief must contain one valid '# Acceptance criteria' section with unique AC ids and no placeholders" >&2
  exit 2
fi

if [ "$ACTION" = follow-up ] && [ -n "$INVALIDATED" ]; then
  INVALIDATED_SEEN="$TMP_ROOT/invalidated-seen"
  : > "$INVALIDATED_SEEN"
  while IFS= read -r invalidated_criterion; do
    case "$invalidated_criterion" in
      AC[1-9]|AC[1-9][0-9]*) ;;
      *) echo "error: invalidated criterion must be AC followed by a positive integer" >&2; exit 2 ;;
    esac
    cut -f1 "$CRITERIA" | grep -Fx "$invalidated_criterion" >/dev/null 2>&1 \
      || { echo "error: invalidated criterion is not declared: $invalidated_criterion" >&2; exit 2; }
    if grep -Fx "$invalidated_criterion" "$INVALIDATED_SEEN" >/dev/null 2>&1; then
      echo "error: invalidated criterion was supplied more than once: $invalidated_criterion" >&2
      exit 2
    fi
    printf '%s\n' "$invalidated_criterion" >> "$INVALIDATED_SEEN"
  done <<< "$INVALIDATED"
fi

if [ "$ACTION" = criterion ]; then
  case "$CRITERION_QUERY" in
    AC[1-9]|AC[1-9][0-9]*) ;;
    *) exit 1 ;;
  esac
  cut -f1 "$CRITERIA" | grep -Fx "$CRITERION_QUERY" >/dev/null 2>&1
  exit $?
fi

RECEIPT_COUNT=0
LEDGER_EXISTS=false
if [ -L "$LEDGER" ] || { [ -e "$LEDGER" ] && [ ! -f "$LEDGER" ]; }; then
  printf '%s\n' "ledger is not a regular file" > "$INVALID"
elif [ -f "$LEDGER" ]; then
  LEDGER_EXISTS=true
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
    printf '%s\n' "$receipt_criterion" >> "$EVIDENCED"
    RECEIPT_COUNT=$((RECEIPT_COUNT + 1))
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
  --arg ledger "$LEDGER" \
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

[ -f "$META" ] && [ ! -L "$META" ] \
  || { echo "error: task metadata is missing or unsafe: $META" >&2; exit 2; }
WORKTREE=$(grep '^worktree=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
META_MODE=$(grep '^mode=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
[ -n "$META_MODE" ] && MODE=$META_MODE
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "error: task metadata has no concrete delivery mode" >&2; exit 2 ;;
esac

RECORDED_TIER=
RECORDED_PATH=
RECORDED_HEAD=
RECORDED_LEDGER_RECEIPTS=
if [ "$ACTION" = follow-up ]; then
  RECORDED_TIER=$(grep '^validation_tier=' "$META" | tail -1 | cut -d= -f2- || true)
  RECORDED_PATH=$(grep '^validation_path=' "$META" | tail -1 | cut -d= -f2- || true)
  [ "$RECORDED_TIER:$RECORDED_PATH" = medium:targeted-no-mistakes ] \
    || { echo "error: bounded follow-up requires a recorded medium targeted-no-mistakes plan" >&2; exit 2; }
  BASE_INPUT=$(grep '^validation_base=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$BASE_INPUT" ] || { echo "error: recorded validation base is missing" >&2; exit 2; }
  RECORDED_HEAD=$(grep '^validation_head=' "$META" | tail -1 | cut -d= -f2- || true)
  [ -n "$RECORDED_HEAD" ] || { echo "error: recorded validation head is missing" >&2; exit 2; }
  RECORDED_LEDGER_RECEIPTS=$(grep '^validation_ledger_receipt_count=' "$META" | tail -1 | cut -d= -f2- || true)
  case "$RECORDED_LEDGER_RECEIPTS" in
    ''|*[!0-9]*) echo "error: recorded validation ledger boundary is missing or invalid" >&2; exit 2 ;;
  esac
fi

BASE=
HEAD=
DIFF_AVAILABLE=0
DIFF_FILES=0
DIFF_LINES=0
HAS_BINARY=0
HAS_SPECIAL_MODE=0
HIGH_PATH=0
LOW_PATH=1
CONFIG_COUNT=0
SENSITIVE_PATH=
NUMSTAT="$TMP_ROOT/numstat"
NAMES="$TMP_ROOT/names"
CONFIG_PATHS="$TMP_ROOT/config-paths"
: > "$NUMSTAT"
: > "$NAMES"
: > "$CONFIG_PATHS"

resolve_diff() {
  [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ] && git -C "$WORKTREE" rev-parse --git-dir >/dev/null 2>&1 || return 1
  HEAD=$(git -C "$WORKTREE" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || return 1
  if [ -n "$BASE_INPUT" ]; then
    BASE=$(git -C "$WORKTREE" rev-parse --verify "$BASE_INPUT^{commit}" 2>/dev/null) || return 1
  else
    BASE=$(git -C "$WORKTREE" merge-base HEAD refs/remotes/origin/HEAD 2>/dev/null \
      || git -C "$WORKTREE" merge-base HEAD main 2>/dev/null \
      || git -C "$WORKTREE" merge-base HEAD master 2>/dev/null) || return 1
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
    lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
    if printf '%s\n' "$lower" | grep -Eq '(^|[/_.-])(api|architecture|auth[^/_.-]*|contracts?|deploy[^/_.-]*|security|secrets?|credentials?|crypt[^/_.-]*|migrations?|runbooks?|schema|database|concurr[^/_.-]*|locks?|threads?|queues?|lifecycle|state|workflow|daemon|watcher|teardown|permissions?|session)([/_.-]|$)'; then
      HIGH_PATH=1
      SENSITIVE_PATH=${SENSITIVE_PATH:-$path}
    fi
    case "$path" in
      AGENTS.md|CLAUDE.md|.agents/skills/*|skills/*|.github/workflows/*)
        HIGH_PATH=1
        SENSITIVE_PATH=${SENSITIVE_PATH:-$path}
        ;;
    esac
    case "$path" in
      README.md|CONTRIBUTING.md|CHANGELOG.md|docs/*.md) ;;
      .editorconfig|.prettierignore|.prettierrc|.prettierrc.json|.prettierrc.yaml|.prettierrc.yml|.markdownlint.json|.markdownlint.yaml|.markdownlint.yml|.shellcheckrc)
        printf '%s\n' "$path" >> "$CONFIG_PATHS"
        CONFIG_COUNT=$((CONFIG_COUNT + 1))
        ;;
      *) LOW_PATH=0 ;;
    esac
  done < "$NUMSTAT"
fi

MECHANICAL_PROOF=0
REGRESSION_PROOF=0
STRONG_RESULT_MODULE="$TMP_ROOT/strong-result.jq"
cat > "$STRONG_RESULT_MODULE" <<'JQ'
def strong_result:
  (test("(fail|error|not[[:space:]]+pass|red|broken|skip|(^|[^0-9])0[[:space:]]+(tests?[[:space:]]+)?pass|no[[:space:]]+tests?|empty)"; "i") | not)
  and test("^([[:space:]]*(pass(ed)?|success(ful)?|green|clean|ok)[[:space:]]*|[[:space:]]*[1-9][0-9]*[[:space:]]+(tests?[[:space:]]+)?passed([[:space:]].*)?)$"; "i");
JQ
PROOF_FLAGS=$(jq -L "$TMP_ROOT" -rse '
  include "strong-result";
  [
    any(.[]; (.type | test("^(test|build|lint|typecheck)$")) and (.result | strong_result)),
    any(.[]; .type == "test" and (.result | strong_result))
  ] | @tsv
' "$LEDGER")
IFS=$'\t' read -r mechanical_proof regression_proof <<< "$PROOF_FLAGS"
[ "$mechanical_proof" = true ] && MECHANICAL_PROOF=1
[ "$regression_proof" = true ] && REGRESSION_PROOF=1

CONFIG_PROOF=1
if [ "$CONFIG_COUNT" -gt 0 ]; then
  if ! jq -L "$TMP_ROOT" -se --rawfile paths "$CONFIG_PATHS" '
    include "strong-result";
    . as $receipts
    | ($paths | split("\n") | map(select(length > 0))) as $required
    | all($required[]; . as $path
        | any($receipts[]; (.type | test("^(test|build|lint|typecheck)$"))
            and .file == $path and (.result | strong_result)))
  ' "$LEDGER" >/dev/null 2>&1; then
    CONFIG_PROOF=0
  fi
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
elif [ "$HIGH_PATH" -eq 1 ]; then
  TIER=high
  REASON=sensitive-or-lifecycle-surface
elif [ "$DIFF_FILES" -gt 8 ] || [ "$DIFF_LINES" -gt 400 ]; then
  TIER=high
  REASON=broad-change
elif [ "$CHANGE_CLASS" = sensitive ]; then
  TIER=high
  REASON=declared-sensitive-change
elif [ -n "$RISKY_AREAS" ] && printf '%s\n' "$RISKY_AREAS" | tr '[:upper:]' '[:lower:]' \
  | grep -Eq '(auth|security|migration|concurr|lifecycle|cross-cut|state|uncertain)'; then
  TIER=high
  REASON=declared-high-risk-area
elif [ "$LOW_PATH" -eq 1 ] && [ "$DIFF_FILES" -le 3 ] && [ "$DIFF_LINES" -le 80 ] \
  && [ "$MECHANICAL_PROOF" -eq 1 ] && [ "$CONFIG_PROOF" -eq 1 ]; then
  TIER=low
  REASON=narrow-mechanical-change
elif [ "$CHANGE_CLASS" = localized-non-sensitive ] && [ "$REGRESSION_PROOF" -eq 1 ]; then
  TIER=medium
  REASON=localized-change-with-test
else
  TIER=high
  if [ "$LOW_PATH" -eq 1 ] && [ "$CONFIG_COUNT" -gt 0 ] && [ "$CONFIG_PROOF" -eq 0 ]; then
    REASON=unbound-mechanical-config
  elif [ "$REGRESSION_PROOF" -eq 1 ]; then
    REASON=unclassified-change
  else
    REASON=weak-evidence
  fi
fi

case "$MODE:$TIER" in
  direct-PR:*) VALIDATION_PATH=direct-PR ;;
  local-only:*) VALIDATION_PATH=local-only ;;
  no-mistakes:low) VALIDATION_PATH=receipts-mechanical ;;
  no-mistakes:medium) VALIDATION_PATH=targeted-no-mistakes ;;
  no-mistakes:high) VALIDATION_PATH=full-no-mistakes ;;
esac

write_meta_record() {  # <pass>
  local pass=$1 now lock normalized_risks packet_value
  now=$(date +%s)
  lock="$STATE/.$ID.validation-plan.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    echo "error: validation metadata is locked by another planner: $lock" >&2
    return 1
  fi
  normalized_risks=$(printf '%s' "$RISKY_AREAS" | tr '\n\r' '; ')
  packet_value=
  [ "$VALIDATION_PATH" = targeted-no-mistakes ] && packet_value=$PACKET
  if ! {
    printf 'validation_tier=%s\n' "$TIER"
    printf 'validation_path=%s\n' "$VALIDATION_PATH"
    printf 'validation_reason=%s\n' "$REASON"
    printf 'validation_base=%s\n' "$BASE"
    printf 'validation_head=%s\n' "$HEAD"
    printf 'validation_diff_files=%s\n' "$DIFF_FILES"
    printf 'validation_diff_lines=%s\n' "$DIFF_LINES"
    printf 'validation_pass=%s\n' "$pass"
    printf 'validation_started_at=%s\n' "$now"
    printf 'validation_risky_areas=%s\n' "$normalized_risks"
    printf 'validation_change_class=%s\n' "$CHANGE_CLASS"
    printf 'validation_ledger_receipt_count=%s\n' "$RECEIPT_COUNT"
    printf 'validation_packet=%s\n' "$packet_value"
    if [ "$pass" = follow-up ]; then
      printf 'validation_delta_base=%s\n' "$DELTA_BASE"
      printf 'validation_finding_count=%s\n' "$FINDING_COUNT"
      printf 'validation_invalidated_receipt_count=%s\n' "$INVALIDATED_COUNT"
    fi
  } >> "$META"; then
    rmdir "$lock" 2>/dev/null || true
    echo "error: could not append validation metadata: $META" >&2
    return 1
  fi
  rmdir "$lock"
}

render_task_contract() {
  awk '
    /^# Task[[:space:]]*$/ { printing=1; next }
    printing && /^# / { exit }
    printing { print }
  ' "$BRIEF"
}

render_acceptance_criteria() {
  printf '# Acceptance criteria\n'
  while IFS=$'\t' read -r criterion description; do
    printf -- '- %s: %s\n' "$criterion" "$description"
  done < "$CRITERIA"
}

write_packet() {  # <initial|follow-up> <diff-base>
  local packet_kind=$1 diff_base=$2 tmp
  tmp="$TASK_DIR/.audit-packet.tmp.$$"
  umask 077
  {
    printf '# Targeted No-Mistakes audit packet\n\n'
    printf 'Packet kind: %s.\n' "$packet_kind"
    printf 'Task: %s.\n' "$ID"
    printf 'Risk tier: medium.\n'
    printf 'Validation path: targeted-no-mistakes.\n'
    printf 'Change class: %s.\n' "$CHANGE_CLASS"
    printf 'Brief source: %s.\n' "$BRIEF"
    printf 'Evidence source: %s.\n' "$LEDGER"
    printf 'Review diff: %s..%s.\n\n' "$diff_base" "$HEAD"
    printf '## Audit remit\n\n'
    printf 'Challenge unsupported or suspicious acceptance-criterion claims.\n'
    printf 'Inspect the changed surface for material correctness, regression, and security issues.\n'
    printf 'Flag important missing tests or evidence.\n'
    printf 'Treat mechanically proven receipts as audit inputs and do not redo them without a concrete reason.\n'
    printf 'Do not reimplement the feature during review.\n'
    if [ "$packet_kind" = follow-up ]; then
      printf 'Review the named finding resolution, the delta, and updated receipts instead of reconstructing the original review.\n'
    fi
    printf '\n## Task contract\n\n'
    render_task_contract
    printf '\n'
    render_acceptance_criteria
    printf '\n## Evidence receipts\n\n```jsonl\n'
    cat "$LEDGER"
    printf '```\n'
    if [ -n "$RISKY_AREAS" ]; then
      printf '\n## Declared risky areas\n\n'
      printf '%s\n' "$RISKY_AREAS" | sed 's/^/- /'
    fi
    if [ "$packet_kind" = follow-up ]; then
      printf '\n## Findings to resolve\n\n'
      printf '%s\n' "$FINDINGS"
      if [ -n "$INVALIDATED" ]; then
        printf '\n## Receipt claims challenged by findings\n\n'
        printf '%s\n' "$INVALIDATED" | sed 's/^/- /'
      fi
    fi
    printf '\n## Diff\n\n```diff\n'
    git -C "$WORKTREE" diff --no-ext-diff --no-renames --unified=3 "$diff_base..$HEAD"
    printf '```\n'
  } > "$tmp"
  mv "$tmp" "$PACKET"
}

if [ "$ACTION" = follow-up ]; then
  DELTA_RESOLVED=$(git -C "$WORKTREE" rev-parse --verify "$DELTA_BASE^{commit}" 2>/dev/null) \
    || { echo "error: invalid --delta-base: $DELTA_BASE" >&2; exit 2; }
  RECORDED_HEAD_RESOLVED=$(git -C "$WORKTREE" rev-parse --verify "$RECORDED_HEAD^{commit}" 2>/dev/null) \
    || { echo "error: recorded validation head is invalid" >&2; exit 2; }
  [ "$DELTA_RESOLVED" = "$RECORDED_HEAD_RESOLVED" ] \
    || { echo "error: --delta-base must equal the latest recorded validation head" >&2; exit 2; }
  git -C "$WORKTREE" merge-base --is-ancestor "$DELTA_RESOLVED" "$HEAD" 2>/dev/null \
    || { echo "error: delta base is not an ancestor of the current head" >&2; exit 2; }
  [ "$DELTA_RESOLVED" != "$HEAD" ] \
    || { echo "error: follow-up head must be a strict descendant of the recorded validation head" >&2; exit 2; }
  if git -C "$WORKTREE" diff --no-ext-diff --quiet "$DELTA_RESOLVED..$HEAD"; then
    echo "error: follow-up delta is empty" >&2
    exit 2
  else
    delta_diff_rc=$?
    [ "$delta_diff_rc" -eq 1 ] \
      || { echo "error: follow-up delta could not be inspected" >&2; exit 2; }
  fi
  [ "$RECORDED_LEDGER_RECEIPTS" -le "$RECEIPT_COUNT" ] \
    || { echo "error: evidence ledger is shorter than the recorded validation boundary" >&2; exit 2; }
  DELTA_BASE=$DELTA_RESOLVED
  if [ "$TIER" != medium ]; then
    VALIDATION_PATH=full-no-mistakes
    TIER=high
    REASON=follow-up-scope-or-risk-changed
    write_meta_record follow-up
    jq -cn --arg task "$ID" --arg tier "$TIER" --arg path "$VALIDATION_PATH" --arg reason "$REASON" \
      '{schema:"fm-validation-plan.v1",task:$task,status:"full-rerun-required",tier:$tier,path:$path,reason:$reason}'
    exit 1
  fi
  if [ -n "$INVALIDATED" ]; then
    NEW_RECEIPTS="$TMP_ROOT/new-receipts.jsonl"
    if [ "$RECORDED_LEDGER_RECEIPTS" -lt "$RECEIPT_COUNT" ]; then
      tail -n "+$((RECORDED_LEDGER_RECEIPTS + 1))" "$LEDGER" > "$NEW_RECEIPTS"
    else
      : > "$NEW_RECEIPTS"
    fi
    while IFS= read -r invalidated_criterion; do
      jq -se --arg criterion "$invalidated_criterion" \
        'any(.[]; .criterion == $criterion)' "$NEW_RECEIPTS" >/dev/null 2>&1 \
        || { echo "error: invalidated criterion requires a new receipt after the validation boundary: $invalidated_criterion" >&2; exit 2; }
    done <<< "$INVALIDATED"
  fi
  write_packet follow-up "$DELTA_BASE"
  write_meta_record follow-up
  jq -cn --arg task "$ID" --arg tier "$TIER" --arg path "$VALIDATION_PATH" --arg reason "$REASON" \
    --arg packet "$PACKET" --arg base "$BASE" --arg head "$HEAD" --arg delta_base "$DELTA_BASE" \
    --argjson findings "$FINDING_COUNT" --argjson invalidated_receipts "$INVALIDATED_COUNT" \
    '{schema:"fm-validation-plan.v1",task:$task,status:"follow-up-ready",tier:$tier,path:$path,reason:$reason,base:$base,head:$head,delta_base:$delta_base,packet:$packet,finding_count:$findings,invalidated_receipt_count:$invalidated_receipts}'
  exit 0
fi

if [ "$VALIDATION_PATH" = targeted-no-mistakes ]; then
  write_packet initial "$BASE"
fi
write_meta_record initial
jq -cn --arg task "$ID" --arg mode "$MODE" --arg tier "$TIER" --arg path "$VALIDATION_PATH" --arg reason "$REASON" \
  --arg base "$BASE" --arg head "$HEAD" --arg packet "$([ "$VALIDATION_PATH" = targeted-no-mistakes ] && printf '%s' "$PACKET")" \
  --argjson diff_files "$DIFF_FILES" --argjson diff_lines "$DIFF_LINES" \
  '{schema:"fm-validation-plan.v1",task:$task,status:"planned",mode:$mode,tier:$tier,path:$path,reason:$reason,base:$base,head:$head,diff_files:$diff_files,diff_lines:$diff_lines,packet:(if $packet == "" then null else $packet end)}'
