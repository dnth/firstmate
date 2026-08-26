#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

[ "$#" -eq 4 ] || exit 2
ID=$1
MODE=$2
YOLO=$3
CRITERIA_BLOCK=$4
META="$STATE/$ID.meta"
BRIEF=./brief.md
EVIDENCE=./evidence.jsonl

[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no safe meta for task $ID at $META" >&2; exit 1; }
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

umask 077
BRIEF_TMP=$(mktemp ./.brief.promote.XXXXXXXX) || exit 1
META_TMP=$(mktemp "$STATE/.$ID.meta.promote.XXXXXXXX") || { rm -f "$BRIEF_TMP"; exit 1; }
BRIEF_ORIGINAL=$(mktemp ./.brief.original.XXXXXXXX) || { rm -f "$BRIEF_TMP" "$META_TMP"; exit 1; }
META_ORIGINAL=$(mktemp "$STATE/.$ID.meta.original.XXXXXXXX") \
  || { rm -f "$BRIEF_TMP" "$META_TMP" "$BRIEF_ORIGINAL"; exit 1; }
COMMITTED=0
EVIDENCE_CREATED=0
BRIEF_REPLACED=0
META_REPLACED=0
cleanup() {
  local cleanup_rc=0
  if [ "$COMMITTED" -ne 1 ]; then
    if [ "$META_REPLACED" -eq 1 ]; then
      if mv "$META_ORIGINAL" "$META"; then
        META_REPLACED=0
      else
        echo "error: promotion rollback could not restore metadata; recovery copy retained at $META_ORIGINAL" >&2
        cleanup_rc=1
      fi
    fi
    if [ "$BRIEF_REPLACED" -eq 1 ]; then
      if mv "$BRIEF_ORIGINAL" "$BRIEF"; then
        BRIEF_REPLACED=0
      else
        echo "error: promotion rollback could not restore brief; recovery copy retained at $BRIEF_ORIGINAL" >&2
        cleanup_rc=1
      fi
    fi
    if [ "$EVIDENCE_CREATED" -eq 1 ] && ! rm -f "$EVIDENCE"; then
      echo "error: promotion rollback could not remove the new evidence ledger" >&2
      cleanup_rc=1
    fi
  fi
  rm -f "$BRIEF_TMP" "$META_TMP"
  [ "$COMMITTED" -eq 1 ] || [ "$BRIEF_REPLACED" -eq 1 ] || rm -f "$BRIEF_ORIGINAL"
  [ "$COMMITTED" -eq 1 ] || [ "$META_REPLACED" -eq 1 ] || rm -f "$META_ORIGINAL"
  [ "$COMMITTED" -ne 1 ] || rm -f "$BRIEF_ORIGINAL" "$META_ORIGINAL"
  return "$cleanup_rc"
}
on_exit() {
  local rc=$?
  cleanup || rc=1
  trap - EXIT
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 1' HUP INT TERM

SETUP_LINE=$(grep -n '^# Setup[[:space:]]*$' "$BRIEF" | tail -1 | cut -d: -f1 || true)
[ -n "$SETUP_LINE" ] || { echo "error: scout brief is missing its scaffold setup boundary" >&2; exit 1; }
head -n "$((SETUP_LINE - 1))" "$BRIEF" > "$BRIEF_TMP"
cp -p "$BRIEF" "$BRIEF_ORIGINAL"
cp -p "$META" "$META_ORIGINAL"
PROMOTED_DELIVERY=$("$FM_ROOT/bin/fm-brief.sh" --render-ship-delivery "$ID" "$MODE") \
  || { echo "error: could not render the ship delivery contract" >&2; exit 1; }
cat >> "$BRIEF_TMP" <<EOF

# Acceptance criteria
$CRITERIA_BLOCK

# Ship setup and delivery
Verify \`pwd -P\` and \`git rev-parse --show-toplevel\` still identify the isolated task worktree before changing code.
Reset scratch work to a clean default-branch base, carry over only intended changes, and create \`fm/$ID\`.

$PROMOTED_DELIVERY
EOF

EVIDENCE_CREATED=1
if ! ( set -C; : > "$EVIDENCE" ) 2>/dev/null; then
  EVIDENCE_CREATED=0
  echo "error: could not prepare evidence ledger: $EVIDENCE" >&2
  exit 1
fi

grep -v -e '^kind=' -e '^mode=' -e '^yolo=' "$META" > "$META_TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} >> "$META_TMP"

BRIEF_REPLACED=1
mv "$BRIEF_TMP" "$BRIEF"
META_REPLACED=1
mv "$META_TMP" "$META"
COMMITTED=1

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: read the concrete acceptance criteria in the promoted brief; review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; record receipts; report done>'"
