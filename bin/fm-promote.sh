#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Promotion also installs the ship acceptance-criterion
# scaffold and evidence ledger before changing kind=, so every ship path reaches
# the same fail-closed completion gate. Firstmate resolves the posture after
# reading the scout report (AGENTS.md section 7); this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's merge authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

"$FM_ROOT/bin/fm-guard.sh" || true
ID=${POS[0]}
META="$STATE/$ID.meta"
TASK_DIR="$DATA/$ID"
BRIEF="$TASK_DIR/brief.md"
EVIDENCE="$TASK_DIR/evidence.jsonl"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }
[ -f "$BRIEF" ] && [ ! -L "$BRIEF" ] \
  || { echo "error: scout brief is missing or unsafe: $BRIEF" >&2; exit 1; }

CRITERIA_COUNT=$(grep -c '^# Acceptance criteria$' "$BRIEF" 2>/dev/null || true)
DELIVERY_COUNT=$(grep -c '^Delivery contract: mode=' "$BRIEF" 2>/dev/null || true)
if [ "$CRITERIA_COUNT" -ne 0 ] || [ "$DELIVERY_COUNT" -ne 0 ]; then
  echo "error: scout brief already contains a partial or conflicting ship contract" >&2
  exit 1
fi
if [ -e "$EVIDENCE" ] || [ -L "$EVIDENCE" ]; then
  echo "error: scout task already has an evidence ledger: $EVIDENCE" >&2
  exit 1
fi

BRIEF_TMP="$TASK_DIR/.brief.promote.$$"
META_TMP="$STATE/.$ID.meta.promote.$$"
cleanup() {
  rm -f "$BRIEF_TMP" "$META_TMP"
}
trap cleanup EXIT HUP INT TERM

cp "$BRIEF" "$BRIEF_TMP"
cat >> "$BRIEF_TMP" <<EOF

# Acceptance criteria
- AC1: {ACCEPTANCE CRITERION}

# Acceptance evidence
Before reporting implementation complete, replace every acceptance-criterion placeholder and record at least one compact receipt for every criterion with \`$FM_ROOT/bin/fm-receipt.sh $ID <criterion> <type> <summary> <result> [options]\`.
Run \`$FM_ROOT/bin/fm-receipt-check.sh $ID\` and do not append \`done:\` unless its JSON status is \`complete\`.

# Promoted ship delivery
Delivery contract: mode=$MODE
EOF

umask 077
if ! ( set -C; : > "$EVIDENCE" ) 2>/dev/null; then
  echo "error: could not prepare evidence ledger: $EVIDENCE" >&2
  exit 1
fi

grep -v -e '^kind=' -e '^mode=' -e '^yolo=' "$META" > "$META_TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} >> "$META_TMP"

mv "$BRIEF_TMP" "$BRIEF"
mv "$META_TMP" "$META"
trap - EXIT HUP INT TERM

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: replace the acceptance-criterion placeholder; review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; record receipts; report done>'"
