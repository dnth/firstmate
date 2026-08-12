#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REAL_GIT=$(command -v git 2>/dev/null) || {
  echo "error: git is required for guarded Treehouse acquisition" >&2
  exit 1
}
GUARD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-get.XXXXXX") || exit 1
trap 'rm -rf "$GUARD_DIR"' EXIT
. "$SCRIPT_DIR/fm-pool-lib.sh"

if ! "$SCRIPT_DIR/fm-treehouse-status-read-only.sh" --candidates "$PWD" > "$GUARD_DIR/candidates"; then
  echo "error: could not establish a safe Treehouse acquisition boundary" >&2
  exit 1
fi
default_ref=$(git -C "$PWD" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
if [ -z "$default_ref" ]; then
  default_branch=$(git -C "$PWD" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -z "$default_branch" ] || default_ref="refs/heads/$default_branch"
fi
while IFS= read -r -d '' slot && IFS= read -r -d '' worktree; do
  fm_pool_worktree_clean "$worktree" || continue
  if [ -z "$default_ref" ] || ! git -C "$worktree" rev-parse --verify "$default_ref^{commit}" >/dev/null 2>&1; then
    echo "error: refusing pooled worktree acquisition: could not resolve the default branch before inspecting slot $slot at $worktree" >&2
    exit 1
  fi
  if ! git -C "$worktree" merge-base --is-ancestor HEAD "$default_ref" 2>/dev/null; then
    echo "error: refusing pooled worktree acquisition at $worktree: HEAD is not an ancestor of $default_ref; local commits were preserved" >&2
    exit 1
  fi
done < "$GUARD_DIR/candidates"

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
if [ "$status" -eq 0 ] && [ ! -f "$GUARD_DIR/complete" ]; then
  echo "error: refusing pooled worktree acquisition because Treehouse did not complete the verified pre-reset boundary" >&2
  exit 1
fi
exit "$status"
