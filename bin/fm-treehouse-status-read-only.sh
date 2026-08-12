#!/usr/bin/env bash
set -u

mode=audit
if [ "${1:-}" = --candidates ]; then
  mode=candidates
  shift
fi
repo=${1:?usage: fm-treehouse-status-read-only.sh [--candidates] <repo>}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-status.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-pool-lib.sh"
candidates="$tmp/candidates"
cwd_snapshot="$tmp/cwds"

node - "$repo" > "$candidates" <<'NODE'
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const repo = process.argv[2];
function processStartedAt(pid) {
  if (process.platform === "linux") {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      const fields = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/);
      const ticks = Number(fields[19]);
      const boot = fs.readFileSync("/proc/stat", "utf8").match(/^btime (\d+)$/m);
      const clock = spawnSync("getconf", ["CLK_TCK"], {encoding:"utf8"});
      const hz = Number(clock.stdout.trim());
      if (Number.isFinite(ticks) && boot && Number.isFinite(hz) && hz > 0) {
        return Math.trunc(ticks * 1000 / hz) + Number(boot[1]) * 1000;
      }
    } catch {}
    return null;
  }
  const started = spawnSync("ps", ["-p", String(pid), "-o", "lstart="], {encoding:"utf8"});
  if (started.status !== 0 || !started.stdout.trim()) return null;
  const value = Date.parse(started.stdout.trim());
  return Number.isFinite(value) ? value : null;
}
function ownerMatches(entry) {
  const pid = Number(entry.owner_pid || 0);
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
  } catch (error) {
    return error.code !== "ESRCH";
  }
  const expected = Number(entry.owner_started_at || 0);
  if (!Number.isFinite(expected) || expected <= 0) return true;
  const actual = processStartedAt(pid);
  if (actual === null) return true;
  return process.platform === "linux"
    ? actual === expected
    : Math.trunc(actual / 1000) === Math.trunc(expected / 1000);
}
function worktreeInUse(worktree) {
  if (process.platform !== "linux") return false;
  let root;
  try {
    root = fs.realpathSync(worktree);
  } catch {
    return true;
  }
  let processes;
  try {
    processes = fs.readdirSync("/proc").filter(name => /^\d+$/.test(name));
  } catch {
    return true;
  }
  for (const pid of processes) {
    try {
      const cwd = fs.realpathSync(`/proc/${pid}/cwd`);
      if (cwd === root || cwd.startsWith(root + path.sep)) return true;
    } catch {}
  }
  return false;
}
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
  if (ownerMatches(entry)) continue;
  if (worktreeInUse(worktree)) continue;
  process.stdout.write(String(entry.name || "unknown") + "\0" + worktree + "\0");
}
NODE

[ -s "$candidates" ] || exit 0
if [ "$(uname 2>/dev/null)" = Linux ]; then
  : > "$cwd_snapshot"
else
  command -v lsof >/dev/null 2>&1 || exit 1
  lsof -a -d cwd -Fpn > "$cwd_snapshot" 2>/dev/null || exit 1
fi
export FM_POOL_LSOF_CWD_FILE="$cwd_snapshot"

while IFS= read -r -d '' slot && IFS= read -r -d '' worktree; do
  fm_pool_worktree_idle "$worktree" || continue
  if [ "$mode" = candidates ]; then
    printf '%s\0%s\0' "$slot" "$worktree"
    continue
  fi
  fm_pool_worktree_clean "$worktree" && continue
  node -e 'process.stdout.write(JSON.stringify({slot:process.argv[1],path:process.argv[2]}) + "\n")' \
    "$slot" "$worktree"
done < "$candidates"
