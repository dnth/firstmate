#!/usr/bin/env bash
set -u

repo=${1:?usage: fm-treehouse-status-read-only.sh <repo>}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-status.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
pools_file="$tmp/pools"
: > "$pools_file"

git -C "$repo" worktree list --porcelain 2>/dev/null \
  | sed -n 's/^worktree //p' \
  | while IFS= read -r worktree; do
      pool=$(dirname -- "$(dirname -- "$worktree")")
      [ -f "$pool/treehouse-state.json" ] || continue
      grep -Fqx -- "$pool" "$pools_file" 2>/dev/null || printf '%s\n' "$pool" >> "$pools_file"
    done

[ -s "$pools_file" ] || exit 0
repo_name=$(basename -- "$repo")
remote=$(git -C "$repo" remote get-url origin 2>/dev/null || printf '%s\n' "$repo")
index=0
while IFS= read -r pool; do
  index=$((index + 1))
  case_dir="$tmp/$index"
  probe_repo="$case_dir/repo-parent/$repo_name"
  pool_root="$case_dir/pool-root"
  copied_pool="$pool_root/.treehouse/$(basename -- "$pool")"
  mkdir -p "$probe_repo" "$copied_pool"
  git -C "$probe_repo" init --quiet
  git -C "$probe_repo" remote add origin "$remote"
  root_json=$(printf '%s' "$pool_root" | jq -Rs .) || exit 1
  printf 'root = %s\n' "$root_json" > "$probe_repo/treehouse.toml"
  cp "$pool/treehouse-state.json" "$copied_pool/treehouse-state.json"
  (cd "$probe_repo" && treehouse status --json)
done < "$pools_file"
