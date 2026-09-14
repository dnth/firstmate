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
# shellcheck source=bin/fm-pool-lib.sh disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-pool-lib.sh"
candidates="$tmp/candidates"
orphans="$tmp/orphans"
cwd_snapshot="$tmp/cwds"

node - "$repo" "$mode" "$orphans" > "$candidates" <<'NODE'
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const repo = process.argv[2];
const mode = process.argv[3];
const orphansPath = process.argv[4];
const procRoot = process.env.FM_PROC_ROOT_OVERRIDE || "/proc";
function processStartedAt(pid) {
  if (process.platform === "linux") {
    try {
      const stat = fs.readFileSync(path.join(procRoot, String(pid), "stat"), "utf8");
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
    processes = fs.readdirSync(procRoot).filter(name => /^\d+$/.test(name));
  } catch {
    return true;
  }
  for (const pid of processes) {
    try {
      const cwd = fs.realpathSync(path.join(procRoot, pid, "cwd"));
      if (cwd === root || cwd.startsWith(root + path.sep)) return true;
    } catch (error) {
      if (error.code === "ENOENT" || error.code === "ESRCH") continue;
      // A foreign-owned process's cwd is unreadable (EACCES/EPERM) on any
      // multi-user Linux host; the pid cannot be attributed to this worktree,
      // so occupancy against foreign processes stays best effort, the same
      // limit `treehouse status` accepts. Only other errors fail closed.
      if (error.code === "EACCES" || error.code === "EPERM") continue;
      return true;
    }
  }
  return false;
}
const result = spawnSync("git", ["-C", repo, "worktree", "list", "--porcelain"]);
if (result.status !== 0) process.exit(result.status || 1);
const listed = new Set();
const poolStates = new Map();
function poolState(statePath) {
  if (!poolStates.has(statePath)) {
    let state = null;
    try {
      state = JSON.parse(fs.readFileSync(statePath, "utf8"));
    } catch {}
    poolStates.set(statePath, state);
  }
  return poolStates.get(statePath);
}
if (mode !== "candidates") {
  const status = spawnSync("treehouse", ["status", "--json"], {cwd: repo, encoding: "utf8"});
  if (status.status === 0) {
    try {
      for (const item of JSON.parse(status.stdout || "[]")) {
        if (item && typeof item.path === "string") {
          poolState(path.join(path.dirname(path.dirname(item.path)), "treehouse-state.json"));
        }
      }
    } catch {}
  }
}
for (const field of result.stdout.toString("utf8").split("\n")) {
  if (!field.startsWith("worktree ")) continue;
  const worktree = field.slice(9);
  listed.add(worktree);
  const state = poolState(path.join(path.dirname(path.dirname(worktree)), "treehouse-state.json"));
  if (!state) continue;
  const entry = (state.worktrees || []).find(item => item.path === worktree);
  if (!entry || entry.leased || entry.destroying) continue;
  if (mode === "candidates") {
    process.stdout.write(String(entry.name || "unknown") + "\0" + worktree + "\0");
    continue;
  }
  if (ownerMatches(entry)) continue;
  if (worktreeInUse(worktree)) continue;
  process.stdout.write(String(entry.name || "unknown") + "\0" + worktree + "\0");
}
// Orphan pass (audit mode only): an unleased state entry with no backing git
// worktree is a damaged or foreign-administered slot this repo cannot verify.
// git worktree list never surfaces it, so diff discovered pool state against
// the listed set and report each as a distinct read-only orphan diagnostic.
if (mode !== "candidates") {
  const seen = new Set();
  const orphans = [];
  for (const state of poolStates.values()) {
    if (!state) continue;
    for (const entry of state.worktrees || []) {
      if (entry.leased || entry.destroying) continue;
      if (typeof entry.path !== "string" || listed.has(entry.path)) continue;
      if (seen.has(entry.path)) continue;
      seen.add(entry.path);
      orphans.push({slot: String(entry.name || "unknown"), path: entry.path, orphan: true});
    }
  }
  if (orphans.length) {
    fs.writeFileSync(orphansPath, orphans.map(item => JSON.stringify(item) + "\n").join(""));
  }
}
NODE

if [ -s "$candidates" ]; then
  if [ "$(uname 2>/dev/null)" = Linux ]; then
    : > "$cwd_snapshot"
  else
    command -v lsof >/dev/null 2>&1 || exit 1
    lsof -a -d cwd -Fpn > "$cwd_snapshot" 2>/dev/null || exit 1
  fi
  export FM_POOL_LSOF_CWD_FILE="$cwd_snapshot"

  while IFS= read -r -d '' slot && IFS= read -r -d '' worktree; do
    if [ "$mode" = candidates ]; then
      printf '%s\0%s\0' "$slot" "$worktree"
      continue
    fi
    fm_pool_worktree_idle "$worktree" || continue
    fm_pool_worktree_clean "$worktree" && continue
    node -e 'process.stdout.write(JSON.stringify({slot:process.argv[1],path:process.argv[2]}) + "\n")' \
      "$slot" "$worktree"
  done < "$candidates"
fi

# Orphan records are complete diagnostics: no backing worktree exists to run
# the git or occupancy predicates against, so they print verbatim.
[ -s "$orphans" ] && cat "$orphans"
exit 0
