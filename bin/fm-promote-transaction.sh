#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

[ "$#" -eq 6 ] || exit 2
PHASE=$1
ID=$2
MODE=$3
YOLO=$4
CRITERIA_BLOCK=$5
TOKEN=$6
META="$STATE/$ID.meta"
BRIEF=./brief.md
EVIDENCE=./evidence.jsonl
BRIEF_TMP="./.brief.promote.$TOKEN"
META_TMP="$STATE/.$ID.meta.promote.$TOKEN"
BRIEF_ORIGINAL="./.brief.original.$TOKEN"
META_ORIGINAL="$STATE/.$ID.meta.original.$TOKEN"
BRIEF_RESTORE="./.brief.restore.$TOKEN"
META_RESTORE="$STATE/.$ID.meta.restore.$TOKEN"
OWNER="./.promotion.owner.$TOKEN"
READY="./.promotion.ready.$TOKEN"

owner_valid() {
  [ -f "$OWNER" ] && [ ! -L "$OWNER" ] && [ "$(cat "$OWNER")" = "$TOKEN" ]
}

ready_valid() {
  [ -f "$READY" ] && [ ! -L "$READY" ] && [ "$(cat "$READY")" = "$TOKEN" ]
}

case "$PHASE" in
  finalize)
    owner_valid && ready_valid || exit 1
    rm -f "$BRIEF_ORIGINAL" "$META_ORIGINAL" "$BRIEF_TMP" "$META_TMP" "$BRIEF_RESTORE" "$META_RESTORE" "$READY" "$OWNER" \
      || echo "warning: promotion committed but a recovery artifact could not be removed" >&2
    HOME_Q=$(printf '%q' "$FM_HOME")
    echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
    echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: read the concrete acceptance criteria in the promoted brief; review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; record receipts; report done>'"
    exit 0
    ;;
  rollback)
    owner_valid || exit 0
    rc=0
    if ready_valid; then
      if [ -f "$META_ORIGINAL" ]; then
        rm -f "$META_RESTORE"
        if ! cp -p "$META_ORIGINAL" "$META_RESTORE" || ! mv "$META_RESTORE" "$META"; then
          echo "error: promotion rollback could not restore metadata; recovery copy retained at $META_ORIGINAL" >&2
          rc=1
        fi
      fi
      if [ -f "$BRIEF_ORIGINAL" ]; then
        rm -f "$BRIEF_RESTORE"
        if ! cp -p "$BRIEF_ORIGINAL" "$BRIEF_RESTORE" || ! mv "$BRIEF_RESTORE" "$BRIEF"; then
          echo "error: promotion rollback could not restore brief; recovery copy retained at $BRIEF_ORIGINAL" >&2
          rc=1
        fi
      fi
      rm -f "$EVIDENCE" || rc=1
    fi
    rm -f "$BRIEF_TMP" "$META_TMP" "$BRIEF_RESTORE" "$META_RESTORE"
    exit "$rc"
    ;;
  cleanup)
    owner_valid || exit 0
    rm -f "$BRIEF_ORIGINAL" "$META_ORIGINAL" "$BRIEF_TMP" "$META_TMP" "$BRIEF_RESTORE" "$META_RESTORE" "$READY" "$OWNER"
    exit 0
    ;;
  prepare) ;;
  *) exit 2 ;;
esac

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
if ! ( set -C; printf '%s\n' "$TOKEN" > "$OWNER" ) 2>/dev/null; then
  exit 1
fi
for transaction_file in "$BRIEF_TMP" "$META_TMP" "$BRIEF_ORIGINAL" "$META_ORIGINAL"; do
  if ! ( set -C; : > "$transaction_file" ) 2>/dev/null; then
    rm -f "$BRIEF_TMP" "$META_TMP" "$BRIEF_ORIGINAL" "$META_ORIGINAL"
    exit 1
  fi
done
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

if ! ( set -C; printf '%s\n' "$TOKEN" > "$READY" ) 2>/dev/null; then
  exit 1
fi

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
