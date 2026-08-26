#!/usr/bin/env bash
# Resolve the authoritative local default branch for guarded readiness and landing.
#
# Usage: fm-local-default.sh <repository>
#
# Prints the local branch named by origin/HEAD when it exists locally, otherwise
# prints the first existing local fallback branch in the fixed order main, master.
# Any missing or unreadable boundary exits nonzero without output.
set -eu

REPO=${1:?usage: fm-local-default.sh <repository>}
[ "$#" -eq 1 ] || { echo "usage: fm-local-default.sh <repository>" >&2; exit 2; }
[ -d "$REPO" ] || { echo "error: repository is missing: $REPO" >&2; exit 1; }

ref=$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
if [ -n "$ref" ]; then
  branch=${ref#origin/}
  git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch" || exit 1
  printf '%s\n' "$branch"
  exit 0
fi
for branch in main master; do
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    printf '%s\n' "$branch"
    exit 0
  fi
done
exit 1
