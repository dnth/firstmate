#!/usr/bin/env bash
# Internal promotion transaction for fm-receipt-store.sh.
# Usage: fm-promote-transaction.sh <prepare|precommit|report|rollback> <task-id> <mode> <yolo> <criteria-block> <token>
# prepare installs the task-side candidate while retaining identity-bound recovery files.
# precommit validates that recovery ownership remains intact, report emits post-commit guidance, and rollback restores the task-side original.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

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
[ "$#" -eq 6 ] || exit 2
PHASE=$1
ID=$2
MODE=$3
YOLO=$4
CRITERIA_BLOCK=$5
TOKEN=$6
BRIEF=./brief.md
EVIDENCE=./evidence.jsonl
BRIEF_TMP="./.brief.promote.$TOKEN"
BRIEF_ORIGINAL="./.brief.original.$TOKEN"
BRIEF_RESTORE="./.brief.restore.$TOKEN"
OWNER="./.promotion.owner.$TOKEN"
READY="./.promotion.ready.$TOKEN"

owner_valid() {
  [ -f "$OWNER" ] && [ ! -L "$OWNER" ] && [ "$(cat "$OWNER")" = "$TOKEN" ]
}

ready_valid() {
  [ -f "$READY" ] && [ ! -L "$READY" ] && [ "$(cat "$READY")" = "$TOKEN" ]
}

case "$PHASE" in
  precommit)
    owner_valid && ready_valid || exit 1
    exit 0
    ;;
  report)
    HOME_Q=$(printf '%q' "$FM_HOME")
    echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
    echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: read the concrete acceptance criteria in the promoted brief; review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; record receipts; report done>'"
    exit 0
    ;;
  rollback)
    owner_valid || exit 0
    rc=0
    if ready_valid; then
      if [ -f "$BRIEF_ORIGINAL" ]; then
        rm -f "$BRIEF_RESTORE"
        if ! cp -p "$BRIEF_ORIGINAL" "$BRIEF_RESTORE" || ! mv "$BRIEF_RESTORE" "$BRIEF"; then
          echo "error: promotion rollback could not restore brief; recovery copy retained at $BRIEF_ORIGINAL" >&2
          rc=1
        fi
      fi
      rm -f "$EVIDENCE" || rc=1
    fi
    rm -f "$BRIEF_TMP" "$BRIEF_RESTORE"
    exit "$rc"
    ;;
  prepare) ;;
  *) exit 2 ;;
esac

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
for transaction_file in "$BRIEF_TMP" "$BRIEF_ORIGINAL"; do
  if ! ( set -C; : > "$transaction_file" ) 2>/dev/null; then
    rm -f "$BRIEF_TMP" "$BRIEF_ORIGINAL"
    exit 1
  fi
done
trap 'exit 1' HUP INT TERM

SETUP_LINE=$(grep -n '^# Setup[[:space:]]*$' "$BRIEF" | tail -1 | cut -d: -f1 || true)
[ -n "$SETUP_LINE" ] || { echo "error: scout brief is missing its scaffold setup boundary" >&2; exit 1; }
head -n "$((SETUP_LINE - 1))" "$BRIEF" > "$BRIEF_TMP"
cp -p "$BRIEF" "$BRIEF_ORIGINAL"
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

mv "$BRIEF_TMP" "$BRIEF"
