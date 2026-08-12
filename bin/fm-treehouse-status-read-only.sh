#!/usr/bin/env bash
set -u

repo=${1:?usage: fm-treehouse-status-read-only.sh <repo>}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-status.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-pool-lib.sh"
candidates="$tmp/candidates"

node - "$repo" > "$candidates" <<'NODE'
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const repo = process.argv[2];
const result = spawnSync("git", ["-C", repo, "worktree", "list", "--porcelain"]);
if (result.status !== 0) process.exit(result.status || 1);
for (const field of result.stdout.toString("utf8").split("\n")) {
  if (!field.startsWith("worktree ")) continue;
  const worktree = field.slice(9);
  const statePath = path.join(path.dirname(path.dirname(worktree)), "treehouse-state.json");
  if (!fs.existsSync(statePath)) continue;
  let state;
  try {
    state = JSON.parse(fs.readFileSync(statePath, "utf8"));
  } catch {
    continue;
  }
  const entry = (state.worktrees || []).find(item => item.path === worktree);
  if (!entry || entry.leased || entry.destroying) continue;
  if (entry.owner_pid) {
    try {
      process.kill(entry.owner_pid, 0);
      continue;
    } catch (error) {
      if (error.code !== "ESRCH") continue;
    }
  }
  process.stdout.write(String(entry.name || "unknown") + "\0" + worktree + "\0");
}
NODE

while IFS= read -r -d '' slot && IFS= read -r -d '' worktree; do
  fm_pool_worktree_clean "$worktree" && continue
  node -e 'process.stdout.write(JSON.stringify({slot:process.argv[1],path:process.argv[2]}) + "\n")' \
    "$slot" "$worktree"
done < "$candidates"
