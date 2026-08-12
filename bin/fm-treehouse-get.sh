#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REAL_GIT=$(command -v git 2>/dev/null) || {
  echo "error: git is required for guarded Treehouse acquisition" >&2
  exit 1
}
GUARD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-get.XXXXXX") || exit 1
trap 'rm -rf "$GUARD_DIR"' EXIT

FM_TREEHOUSE_REAL_GIT=$REAL_GIT \
FM_TREEHOUSE_GUARD_ERROR_FILE="$GUARD_DIR/error" \
FM_TREEHOUSE_GUARD_SAFE_FILE="$GUARD_DIR/safe" \
FM_TREEHOUSE_GUARD_COMPLETE_FILE="$GUARD_DIR/complete" \
PATH="$SCRIPT_DIR/treehouse-git-guard:$PATH" \
  treehouse get "$@"
status=$?
if [ "$status" -ne 0 ] && [ -s "$GUARD_DIR/error" ]; then
  sed -n '1p' "$GUARD_DIR/error" >&2
fi
exit "$status"
