#!/usr/bin/env bash
# Check whether a ship task's declared acceptance criteria are accounted for.
#
# Usage:
#   fm-receipt-check.sh <task-id>
#   fm-receipt-check.sh <task-id> --criterion <criterion-id>
#   fm-receipt-check.sh --parse-criteria <brief-file|-> [--require <criterion-id>]
#
# Evidence receipts establish whether the implementing worker accounted for
# every acceptance criterion the ship brief declares. They certify nothing
# about review, test coverage, CI, No-Mistakes completion, or merge readiness;
# those belong to No-Mistakes, the forge, and the delivery owners.
#
# The default command emits one compact fm-evidence-check.v2 JSON object with
# required, evidenced, accepted_blocked, missing, and invalid. It exits 0 when
# every declared criterion is accounted for, 1 when evidence is missing, and 2
# for an invalid brief, ledger, or task contract. Tasks whose metadata
# identifies them as scouts or secondmates return status=not-applicable.
#
# Acceptance criteria are owned by the exact ship-brief section:
#
#   # Acceptance criteria
#   - AC1: First required outcome.
#   - AC2: Second required outcome.
#
# Every listed criterion is required. IDs must be unique AC-prefixed positive
# integers, and placeholder descriptions are invalid.
# The latest structurally valid receipt per criterion decides it: outcome=success
# evidences the criterion, outcome=accepted-blocked (with its verbatim
# captain_exception) accounts for it without evidencing it, and every other
# outcome leaves it missing. A criterion that is invalidated by a finding is
# therefore recorded as a later failure receipt and satisfied again only by a
# fresher success. result stays descriptive, so an expected observation such
# as 401 is successful evidence when the worker records outcome=success.
# A receipt naming a criterion the brief does not declare, or any malformed
# record, makes the ledger invalid rather than silently disappearing.
# accepted_blocked is always reported as a distinct list with exception
# references, never inside evidenced; firstmate never auto-merges a task with
# any accepted-blocked criterion, which bin/fm-merge-guard-lib.sh enforces.
# --criterion exits 0 when the id is declared by the pinned brief, else 1.
# --parse-criteria prints "<id>\t<description>" per criterion, or exits 1
# with --require when the named id is absent.
# Reads go through bin/fm-receipt-store.sh's pinned snapshot so the brief and
# ledger are read under the shared ledger lock and never through symlinks.
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
      upper=toupper(description)
      if (upper ~ /\{[[:space:]]*(TASK|TODO|ACCEPTANCE[ _-]+CRITERION|PLACEHOLDER)([[:space:]}]|$)/) bad=1
      if (upper ~ /(TASK|TODO|ACCEPTANCE[ _-]+CRITERION|PLACEHOLDER)[[:space:]]*\}/) bad=1
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
    *) echo "error: unknown option: $option" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "error: perl is required" >&2; exit 2; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-receipt-check.XXXXXX")
TMP_ROOT=$(CDPATH='' cd -- "$TMP_ROOT" && pwd -P)
STORE_PID=
STORE_RELEASE=
STORE_RELEASE_OPEN=0
STORE_READY=
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  if [ -n "$STORE_PID" ]; then
    if kill -0 "$STORE_PID" 2>/dev/null; then
      if [ -s "$STORE_READY" ]; then
        printf 'release\n' >&9 2>/dev/null || true
      else
        kill -TERM "$STORE_PID" 2>/dev/null || true
      fi
    fi
    wait "$STORE_PID" 2>/dev/null || true
  fi
  if [ "$STORE_RELEASE_OPEN" -eq 1 ]; then
    exec 9>&-
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
BRIEF="$TMP_ROOT/brief.md"
LEDGER="$TMP_ROOT/evidence.jsonl"
META="$TMP_ROOT/task.meta"
: > "$BRIEF"
: > "$LEDGER"
STORE_READY="$TMP_ROOT/store.ready"
STORE_RELEASE="$TMP_ROOT/store.release"
mkfifo "$STORE_RELEASE"
exec 9<> "$STORE_RELEASE"
STORE_RELEASE_OPEN=1
FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-receipt-store.sh" "$ID" hold \
  "$BRIEF" "$LEDGER" "$META" "$STORE_READY" "$STORE_RELEASE" &
STORE_PID=$!
while [ ! -f "$STORE_READY" ] || [ -L "$STORE_READY" ] || [ ! -s "$STORE_READY" ]; do
  kill -0 "$STORE_PID" 2>/dev/null \
    || { wait "$STORE_PID" 2>/dev/null || true; STORE_PID=; echo "error: pinned evidence snapshot failed" >&2; exit 2; }
done
SNAPSHOT_RC=$(sed -n '1p' "$STORE_READY")
case "$SNAPSHOT_RC" in
  0) LEDGER_EXISTS=true ;;
  3|4) LEDGER_EXISTS=false ;;
  *) echo "error: pinned evidence snapshot failed" >&2; exit 2 ;;
esac

KIND_COUNT=$(grep -c '^kind=' "$META" 2>/dev/null || true)
[ "$KIND_COUNT" -eq 1 ] \
  || { echo "error: task metadata must contain exactly one kind" >&2; exit 2; }
KIND=$(sed -n 's/^kind=//p' "$META")
case "$KIND" in
  scout|secondmate)
    [ "$ACTION" != criterion ] || exit 1
    jq -cn --arg task "$ID" \
      '{schema:"fm-evidence-check.v2",task:$task,kind:"non-ship",status:"not-applicable",required:[],evidenced:[],accepted_blocked:[],missing:[],invalid:[]}'
    exit 0
    ;;
  ship) ;;
  *) echo "error: task metadata has an invalid kind" >&2; exit 2 ;;
esac

MODE_COUNT=$(grep -c '^Delivery contract: mode=' "$BRIEF" 2>/dev/null || true)
if [ "$MODE_COUNT" -eq 1 ]; then
  MODE=$(sed -n 's/^Delivery contract: mode=//p' "$BRIEF")
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    *) echo "error: ship brief has an invalid delivery contract" >&2; exit 2 ;;
  esac
elif [ "$MODE_COUNT" -eq 0 ]; then
  echo "error: ship brief has no delivery contract" >&2; exit 2
else
  echo "error: ship brief has multiple delivery contracts" >&2; exit 2
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
"$SCRIPT_DIR/fm-receipt-check.sh" --parse-criteria "$BRIEF" > "$CRITERIA" || exit 2

if [ "$ACTION" = criterion ]; then
  case "$CRITERION_QUERY" in
    AC[1-9]|AC[1-9][0-9]*) ;;
    *) exit 1 ;;
  esac
  cut -f1 "$CRITERIA" | grep -Fx "$CRITERION_QUERY" >/dev/null 2>&1
  exit $?
fi

INVALID="$TMP_ROOT/invalid"
LATEST="$TMP_ROOT/latest.jsonl"
: > "$INVALID"
: > "$LATEST"
if [ "$LEDGER_EXISTS" = true ]; then
  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    [ -n "$line" ] || { printf 'line %s: blank JSONL record\n' "$line_number" >> "$INVALID"; continue; }
    if ! printf '%s\n' "$line" | "$SCRIPT_DIR/fm-receipt-schema.sh"; then
      printf 'line %s: invalid receipt\n' "$line_number" >> "$INVALID"
      continue
    fi
    receipt_criterion=$(printf '%s' "$line" | jq -r '.criterion')
    if ! cut -f1 "$CRITERIA" | grep -Fx "$receipt_criterion" >/dev/null 2>&1; then
      printf 'line %s: undeclared criterion %s\n' "$line_number" "$receipt_criterion" >> "$INVALID"
      continue
    fi
    printf '%s\n' "$line" \
      | jq -c '{criterion,outcome,captain_exception:(.captain_exception // "")}' >> "$LATEST"
  done < "$LEDGER"
fi

REQUIRED_JSON=$(cut -f1 "$CRITERIA" | jq -Rsc 'split("\n") | map(select(length > 0))')
ACCOUNTING=$(jq -sc --argjson required "$REQUIRED_JSON" '
  (reduce .[] as $r ({}; .[$r.criterion] = $r)) as $latest
  | {
      evidenced: [$required[] | select($latest[.].outcome == "success")],
      accepted_blocked: [$required[] | . as $c | select($latest[$c].outcome == "accepted-blocked")
        | {criterion:$c, captain_exception:$latest[$c].captain_exception}],
      missing: [$required[] | select(($latest[.].outcome // "") | test("^(success|accepted-blocked)$") | not)]
    }
' "$LATEST")
INVALID_JSON=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$INVALID")

if [ -s "$INVALID" ]; then
  CHECK_STATUS=invalid
  CHECK_RC=2
elif [ "$(printf '%s' "$ACCOUNTING" | jq '.missing | length')" -gt 0 ]; then
  CHECK_STATUS=missing
  CHECK_RC=1
else
  CHECK_STATUS=complete
  CHECK_RC=0
fi

jq -cn \
  --arg task "$ID" \
  --arg status "$CHECK_STATUS" \
  --argjson required "$REQUIRED_JSON" \
  --argjson accounting "$ACCOUNTING" \
  --argjson invalid "$INVALID_JSON" \
  '{schema:"fm-evidence-check.v2",task:$task,kind:"ship",status:$status,required:$required,evidenced:$accounting.evidenced,accepted_blocked:$accounting.accepted_blocked,missing:$accounting.missing,invalid:$invalid}'
exit "$CHECK_RC"
