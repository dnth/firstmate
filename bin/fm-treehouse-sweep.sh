#!/usr/bin/env bash
# bin/fm-treehouse-sweep.sh - guarded pool-hygiene sweep.
#
# A thin wrapper over treehouse's own `prune` and `destroy` verbs, with
# firstmate's ownership proof layered on top, because treehouse cannot see
# `.fm-slot-owner` claims or other homes' `state/*.meta` records.
#
# Usage:
#   fm-treehouse-sweep.sh [--all]                       classify + dry-run only
#   fm-treehouse-sweep.sh --pool <repo>                 restrict scope to one
#                                                       backing repo (repeatable)
#   fm-treehouse-sweep.sh --apply-clean                 also remove the proven
#                                                       clean tier (requires the
#                                                       config/treehouse-sweep-clean
#                                                       opt-in flag file)
#   fm-treehouse-sweep.sh --apply-slot <path> --captain-approved
#                                                       destroy ONE dirty-tier
#                                                       slot by exact path
#
# Scope defaults to "$FM_ROOT" plus every clone under "$FM_HOME/projects"
# (overridable via FM_ROOT_OVERRIDE / FM_HOME / FM_PROJECTS_OVERRIDE), matching
# the bootstrap TREEHOUSE_POOL audit's pool set.
#
# Every unleased slot is classified through the full ownership proof, in order:
#   1. slot claim: an unreadable `.fm-slot-owner` refuses the apply pass; a
#      claim naming another task skips the slot. Claims are never removed.
#   2. cross-home record scan: any `state/*.meta` `worktree=`/`home=` record in
#      this or any registered local home naming the slot skips it
#      (bin/fm-homes-lib.sh owns the home set).
#   3. live occupancy: `treehouse status` processes[] plus a /proc cwd scan on
#      Linux or lsof elsewhere; a foreign-owned process's cwd is
#      un-attributable (best effort, same limit the audit accepts), and a host
#      where occupancy cannot be proven at all refuses the apply pass.
#   4. landedness: clean porcelain (fm_pool_worktree_clean), no unpushed
#      commits, and HEAD merged into the backing repo's default ref; failure
#      demotes the slot to the dirty tier.
# Leased or destroying entries are skipped by definition.
#
# Resulting tiers:
#   clean    - provably returnable; --apply-clean removes each one with a
#              per-slot `treehouse destroy <path> --yes` (never pool-wide
#              `prune --yes`, which cannot see firstmate claims). Gated on the
#              gitignored config/treehouse-sweep-clean presence flag, default
#              off - deleting warm slots is a resource-policy choice.
#   dirty    - unlanded or unmerged content; inspect-only unless the captain
#              names one exact path via --apply-slot <path> --captain-approved,
#              which runs `treehouse destroy <path> --include-unlanded --yes`.
#              Never batched, never config-enabled.
#   damaged  - broken admin link or missing worktree directory; inspect-only
#              forever. Removal means manual rm plus state surgery and stays a
#              manual captain act - a "broken" slot can still hold a live
#              foreign consumer.
#   skipped  - leased, destroying, claimed, meta-named, or live-occupied.
#
# `--include-in-use` and `--include-leased` are never forwarded: those remain
# explicit per-slot `treehouse destroy` acts by the captain outside the sweep.
#
# Apply passes refuse when another pool operation holds the shared project
# lock (fm_treehouse_project_lock_path) or when any scanned slot carries an
# unreadable claim or unprovable occupancy.

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pool-lib.sh
. "$SCRIPT_DIR/fm-pool-lib.sh"
# shellcheck source=bin/fm-homes-lib.sh
. "$SCRIPT_DIR/fm-homes-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# Leased or destroying/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { echo "REFUSED: $*" >&2; exit 1; }
warn() { echo "sweep: $*" >&2; }

pools=()
apply_clean=0
apply_slot=
captain_approved=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all) ;;
    --pool)
      [ "$#" -ge 2 ] || die "--pool requires a backing-repo path"
      pools+=("$2"); shift
      ;;
    --pool=*) pools+=("${1#--pool=}") ;;
    --apply-clean) apply_clean=1 ;;
    --apply-slot)
      [ "$#" -ge 2 ] || die "--apply-slot requires an exact slot worktree path"
      apply_slot=$2; shift
      ;;
    --apply-slot=*) apply_slot=${1#--apply-slot=} ;;
    --captain-approved) captain_approved=1 ;;
    --include-*)
      die "$1 is never forwarded by the sweep; remove the named slot by hand with treehouse destroy only on explicit captain review"
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[ "$apply_clean" = 1 ] && [ -n "$apply_slot" ] \
  && die "--apply-clean and --apply-slot are separate passes; run them one at a time"
[ "$captain_approved" = 0 ] || [ -n "$apply_slot" ] \
  || die "--captain-approved only accompanies --apply-slot"
command -v treehouse >/dev/null 2>&1 \
  || die "treehouse is not on PATH; nothing was classified"
command -v node >/dev/null 2>&1 \
  || die "node is not on PATH; pool status cannot be parsed"

if [ "${#pools[@]}" -eq 0 ]; then
  for repo in "$FM_ROOT" "$PROJECTS"/*; do
    [ -d "$repo" ] || continue
    [ "$repo" = "$FM_ROOT" ] || git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    pools+=("$repo")
  done
fi

# --- helpers ----------------------------------------------------------------

# Occupancy proof for one slot path: 0 occupied, 1 provably idle, 2 unprovable.
# On Linux a /proc cwd scan is authoritative for attributable processes; a
# foreign-owned process's cwd is un-attributable (EACCES/EPERM) and skipped,
# matching the audit's documented best-effort limit. Elsewhere lsof is required.
sweep_proc_occupied() {  # <worktree>
  local worktree=$1 rc
  if [ "$(uname 2>/dev/null)" = Linux ]; then
    node - "$worktree" <<'NODE'
const fs = require("fs");
const path = require("path");
const worktree = process.argv[2];
const procRoot = process.env.FM_PROC_ROOT_OVERRIDE || "/proc";
let root;
try {
  root = fs.realpathSync(worktree);
} catch {
  process.exit(2);
}
let processes;
try {
  processes = fs.readdirSync(procRoot).filter(name => /^\d+$/.test(name));
} catch {
  process.exit(2);
}
for (const pid of processes) {
  try {
    const cwd = fs.realpathSync(path.join(procRoot, pid, "cwd"));
    if (cwd === root || cwd.startsWith(root + path.sep)) process.exit(0);
  } catch (error) {
    if (error.code === "ENOENT" || error.code === "ESRCH") continue;
    if (error.code === "EACCES" || error.code === "EPERM") continue;
    process.exit(2);
  }
}
process.exit(1);
NODE
    return $?
  fi
  fm_pool_worktree_idle "$worktree"
  rc=$?
  case "$rc" in
    0) return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

# 0 when some task record in any scanned home names this canonical slot.
sweep_meta_names_slot() {  # <canonical-slot> → prints the naming task id
  local slot=$1 state_dir meta field value canon
  SWEEP_META_MATCH=
  for state_dir in "${TREEHOUSE_OWNER_STATES[@]}"; do
    [ -d "$state_dir" ] && [ -r "$state_dir" ] && [ -x "$state_dir" ] || {
      SWEEP_UNSAFE_CLAIM=1
      return 1
    }
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      for field in worktree home; do
        value=$(fm_meta_get "$meta" "$field")
        [ -n "$value" ] || continue
      canon=$(canonical_existing_dir "$value") || continue
      [ "$canon" = "$slot" ] || continue
        SWEEP_META_MATCH=$(basename "$meta" .meta)
        return 0
      done
    done
  done
  return 1
}

sweep_pool_default_ref() {  # <repo> → prints a ref the slot HEAD must reach
  local repo=$1 ref
  ref=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) \
    && [ -n "$ref" ] && { printf '%s\n' "$ref"; return 0; }
  ref=$(git -C "$repo" rev-parse -q --verify origin/HEAD 2>/dev/null) \
    && { printf '%s\n' "origin/HEAD"; return 0; }
  for ref in main master; do
    git -C "$repo" rev-parse -q --verify "$ref" >/dev/null 2>&1 \
      && { printf '%s\n' "$ref"; return 0; }
  done
  return 1
}

sweep_pool_path_registered() {  # <repo> <slot>
  local repo=$1 slot=$2 canon listed line listed_abs pool state
  canon=$(canonical_existing_dir "$slot") || return 1
  [ "$canon" != "$(canonical_existing_dir "$repo")" ] || return 1
  pool=$(dirname "$(dirname "$canon")")
  state="$pool/treehouse-state.json"
  [ -f "$state" ] && [ ! -L "$state" ] || return 1
  node - "$state" "$canon" <<'NODE'
const fs = require("fs");
const statePath = process.argv[2];
const slotPath = process.argv[3];
let state;
try {
  state = JSON.parse(fs.readFileSync(statePath, "utf8"));
} catch {
  process.exit(1);
}
if (!Array.isArray(state.worktrees)) {
  process.exit(1);
}
if (!state.worktrees.some(entry => entry && entry.path === slotPath)) {
  process.exit(1);
}
NODE
  [ "$?" -eq 0 ] || return 1
  listed=$(git -C "$repo" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(canonical_existing_dir "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$canon" ] && return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

# Emit one "class|name|path|reason" line per managed entry via node so tab and
# newline edge cases in paths stay exact.
sweep_pool_entries() {  # <repo> <status-json>
  node - "$1" "$2" <<'NODE'
const fs = require("fs");
const path = require("path");
const status = JSON.parse(process.argv[3]);
const out = [];
const seen = new Set();
const stateEntries = new Map();
const poolRoot = process.argv[2];
const enc = value => Buffer.from(String(value), "utf8").toString("base64");
const stateListFor = (p) => {
  try {
    const state = JSON.parse(fs.readFileSync(
      path.join(path.dirname(path.dirname(p)), "treehouse-state.json"), "utf8"));
    return Array.isArray(state.worktrees) ? state.worktrees : null;
  } catch { return null; }
};
const stateFor = (p) => {
  const entries = stateListFor(p);
  return entries ? entries.find(e => e && e.path === p) || null : null;
};
const stateFiles = [path.join(poolRoot, "treehouse-state.json"), path.join(path.dirname(poolRoot), "treehouse-state.json")];
try {
  for (const child of fs.readdirSync(path.dirname(poolRoot))) {
    stateFiles.push(path.join(path.dirname(poolRoot), child, "treehouse-state.json"));
  }
} catch { process.exit(5); }
for (const file of stateFiles) {
  if (!fs.existsSync(file)) continue;
  let state;
  try { state = JSON.parse(fs.readFileSync(file, "utf8")); } catch { process.exit(5); }
  if (!Array.isArray(state.worktrees)) process.exit(5);
  for (const entry of state.worktrees) {
    if (entry && typeof entry.path === "string") stateEntries.set(entry.path, entry);
  }
}
for (const item of status) {
  if (!item || typeof item.path !== "string") {
    console.error("treehouse status entry is missing a string path");
    process.exit(3);
  }
  if (seen.has(item.path)) {
    console.error(`treehouse status contains duplicate path: ${item.path}`);
    process.exit(4);
  }
  seen.add(item.path);
  const entry = stateFor(item.path) || {};
  for (const stateEntry of stateListFor(item.path) || []) {
    if (stateEntry && typeof stateEntry.path === "string") stateEntries.set(stateEntry.path, stateEntry);
  }
  const leased = entry.leased || item.status === "leased" ? 1 : 0;
  const destroying = entry.destroying || item.status === "destroying" ? 1 : 0;
  out.push([
    String(item.name || entry.name || "unknown"),
    item.path,
    String(item.status || "unknown"),
    String(Array.isArray(item.processes) ? item.processes.length : 0),
    String(leased),
    String(destroying),
    String(item.lease_holder || entry.lease_holder || ""),
  ].map(enc).join("\t"));
}
for (const entry of stateEntries.values()) {
  if (seen.has(entry.path)) continue;
  seen.add(entry.path);
  out.push([
    String(entry.name || "unknown"), entry.path, String(entry.status || "unknown"),
    String(Array.isArray(entry.processes) ? entry.processes.length : 0),
    String(entry.leased ? 1 : 0), String(entry.destroying ? 1 : 0),
    String(entry.lease_holder || ""),
  ].map(enc).join("\t"));
}
if (out.length) process.stdout.write(out.join("\n") + "\n");
NODE
}

# Classification results for the current pool, consumed by report + apply.
SWEEP_CLASSES=()       # parallel to SWEEP_NAMES/SWEEP_PATHS/SWEEP_REASONS
SWEEP_NAMES=()
SWEEP_PATHS=()
SWEEP_REASONS=()
SWEEP_UNSAFE_CLAIM=0
SWEEP_UNPROVABLE=0

sweep_classify_pool() {  # <repo> — fills the SWEEP_* arrays
  local repo=$1 status_rc entries parsed_entries parsed_rc line name path status nprocs leased destroying holder
  local canon reason class default_ref porcelain_head
  SWEEP_CLASSES=(); SWEEP_NAMES=(); SWEEP_PATHS=(); SWEEP_REASONS=()
  SWEEP_UNSAFE_CLAIM=0; SWEEP_UNPROVABLE=0
  entries=$(
    cd "$repo" 2>/dev/null && treehouse status --json 2>/dev/null
  )
  status_rc=$?
  [ "$status_rc" -eq 0 ] && [ -n "$entries" ] || {
    warn "pool $repo: treehouse status --json failed; nothing classified"
    return 1
  }
  default_ref=$(sweep_pool_default_ref "$repo" || true)
  parsed_entries=$(sweep_pool_entries "$repo" "$entries")
  parsed_rc=$?
  [ "$parsed_rc" -eq 0 ] || {
    warn "pool $repo: treehouse status --json contained invalid data; nothing classified"
    return 1
  }
  while IFS=$'\t' read -r name path status nprocs leased destroying holder; do
    name=$(printf '%s' "$name" | base64 -d) || return 1
    path=$(printf '%s' "$path" | base64 -d) || return 1
    status=$(printf '%s' "$status" | base64 -d) || return 1
    nprocs=$(printf '%s' "$nprocs" | base64 -d) || return 1
    leased=$(printf '%s' "$leased" | base64 -d) || return 1
    destroying=$(printf '%s' "$destroying" | base64 -d) || return 1
    holder=$(printf '%s' "$holder" | base64 -d) || return 1
    [ -n "$path" ] || return 1
    class=skipped; reason=
    canon=
    if [ "$leased" = 1 ]; then
      reason="leased${holder:+ to $holder}"
    elif [ "$destroying" = 1 ]; then
      reason="destroying"
    elif ! sweep_pool_path_registered "$repo" "$path"; then
      class=damaged
      reason="unregistered or orphaned worktree; inspect-only, removal stays manual"
    elif ! canon=$(canonical_existing_dir "$path"); then
      class=damaged
      reason="worktree directory is gone; inspect-only, removal stays manual"
    else
      fm_treehouse_slot_owner_state "$canon" ""
      case "$FM_TREEHOUSE_SLOT_OWNER" in
        unsafe)
          class=refused
          reason="unreadable slot-owner claim; refuses any apply pass"
          SWEEP_UNSAFE_CLAIM=1
          ;;
        other)
          reason="claimed by task $FM_TREEHOUSE_SLOT_OWNER_ID${FM_TREEHOUSE_SLOT_OWNER_HOME:+ (home $FM_TREEHOUSE_SLOT_OWNER_HOME)}"
          ;;
        *)
          if sweep_meta_names_slot "$canon"; then
            reason="task $SWEEP_META_MATCH's record names this slot"
          elif [ "$SWEEP_UNSAFE_CLAIM" = 1 ]; then
            class=refused
            reason="a registered Firstmate state directory is unreadable; refuses any apply pass"
          elif [ "$status" = "in-use" ] || [ "$nprocs" -gt 0 ] 2>/dev/null; then
            reason="in use ($nprocs live processes reported by treehouse status)"
          else
            sweep_proc_occupied "$canon"
            case "$?" in
              0) reason="in use (a live process holds a cwd inside the slot)" ;;
              2)
                reason="occupancy unprovable on this host; refuses any apply pass"
                SWEEP_UNPROVABLE=1
                ;;
              *)
                if [ "$status" = damaged ] || [ "$status" = missing ] \
                   || ! git -C "$canon" rev-parse --git-dir >/dev/null 2>&1; then
                  class=damaged
                  reason="broken worktree admin link; inspect-only, removal stays manual"
                elif ! git -C "$canon" status --porcelain --untracked-files=all >/dev/null 2>&1; then
                  class=refused
                  reason="git status failed; cleanliness cannot be proven"
                  SWEEP_UNSAFE_CLAIM=1
                elif porcelain_head=$(fm_pool_first_real_porcelain_line "$canon"); then
                  class=dirty
                  reason="uncommitted changes ($porcelain_head); captain may destroy by exact path"
                elif [ -n "$(git -C "$canon" log --format=%H HEAD --not --remotes 2>/dev/null)" ]; then
                  class=dirty
                  reason="unpushed commits on HEAD; captain may destroy by exact path"
                elif [ -z "$default_ref" ]; then
                  class=dirty
                  reason="no default ref to prove merged HEAD; captain may destroy by exact path"
                elif ! git -C "$canon" merge-base --is-ancestor HEAD "$default_ref" 2>/dev/null; then
                  class=dirty
                  reason="HEAD is not merged into $default_ref; captain may destroy by exact path"
                else
                  class=clean
                  reason="clean, idle, unclaimed, merged; prune candidate"
                fi
                ;;
            esac
          fi
          ;;
      esac
    fi
    SWEEP_CLASSES+=("$class")
    SWEEP_NAMES+=("$name")
    SWEEP_PATHS+=("$path")
    SWEEP_REASONS+=("$reason")
  done <<EOF
${parsed_entries}
EOF
  return 0
}

sweep_report_pool() {  # <repo>
  local repo=$1 i
  echo "pool $repo"
  for i in "${!SWEEP_CLASSES[@]}"; do
    printf '  slot %-6s %-8s %s\n      %s\n' \
      "${SWEEP_NAMES[$i]}" "${SWEEP_CLASSES[$i]}" \
      "${SWEEP_PATHS[$i]}" "${SWEEP_REASONS[$i]}"
  done
  echo "  treehouse prune (dry run):"
  ( cd "$repo" && treehouse prune 2>&1 ) | sed 's/^/    /' || true
}

sweep_acquire_pool_lock() {  # <repo> → sets SWEEP_POOL_LOCK
  local repo=$1
  SWEEP_POOL_LOCK=$(fm_treehouse_project_lock_path "$repo") \
    || die "cannot resolve the shared Treehouse project lock for $repo; nothing was changed"
  fm_lock_try_acquire "$SWEEP_POOL_LOCK" \
    || die "another Treehouse pool operation holds the project lock for $repo; nothing was changed"
}

sweep_release_pool_lock() {
  [ -n "${SWEEP_POOL_LOCK:-}" ] && fm_lock_release "$SWEEP_POOL_LOCK" || true
  SWEEP_POOL_LOCK=
}
SWEEP_BATCH_LOCKS=()
sweep_acquire_batch_lock() {
  local repo=$1 lock existing
  lock=$(fm_treehouse_project_lock_path "$repo") \
    || die "cannot resolve the shared Treehouse project lock for $repo; nothing was changed"
  for existing in "${SWEEP_BATCH_LOCKS[@]}"; do
    [ "$existing" = "$lock" ] && return 0
  done
  fm_lock_try_acquire "$lock" \
    || die "another Treehouse pool operation holds the project lock for $repo; nothing was changed"
  SWEEP_BATCH_LOCKS+=("$lock")
}
sweep_release_batch_locks() {
  local lock
  for lock in "${SWEEP_BATCH_LOCKS[@]}"; do
    fm_lock_release "$lock" || true
  done
  SWEEP_BATCH_LOCKS=()
}
trap 'sweep_release_pool_lock; sweep_release_batch_locks' EXIT

# --- apply passes ------------------------------------------------------------

# The cross-home record scan must be armed before ANY pass - classification
# reads it silently, and an apply pass without it would skip nothing.
collect_local_firstmate_states "$STATE" || exit 1

if [ -n "$apply_slot" ]; then
  [ "$captain_approved" = 1 ] \
    || die "--apply-slot requires --captain-approved; a dirty slot destroys unlanded work"
  target=$(canonical_existing_dir "$apply_slot") \
    || die "--apply-slot target $apply_slot is not an existing directory"
  found=0
  target_repo=
  target_class=
  target_reason=
  for repo in "${pools[@]}"; do
    sweep_classify_pool "$repo" \
      || die "pool $repo could not be classified; nothing was changed"
    [ "$SWEEP_UNSAFE_CLAIM" = 0 ] \
      || die "an unreadable slot-owner claim exists in pool $repo; nothing was changed"
    [ "$SWEEP_UNPROVABLE" = 0 ] \
      || die "slot occupancy is unprovable in pool $repo; nothing was changed"
    for i in "${!SWEEP_PATHS[@]}"; do
      canon=$(canonical_existing_dir "${SWEEP_PATHS[$i]}") || continue
      [ "$canon" = "$target" ] || continue
      found=1
      target_repo=$repo
      target_class=${SWEEP_CLASSES[$i]}
      target_reason=${SWEEP_REASONS[$i]}
    done
  done
  [ "$found" = 1 ] || die "$apply_slot is not a managed unleased pool slot in scope"
  case "$target_class" in
    dirty) ;;
    clean) die "slot $target is in the clean tier; use --apply-clean (never --include-unlanded on clean work)" ;;
    damaged) die "slot $target is damaged/orphaned; removal is a manual captain act, never the sweep's" ;;
    refused) die "slot $target cannot be proven safe: $target_reason" ;;
    *) die "slot $target is skipped ($target_reason); nothing was changed" ;;
  esac
  sweep_acquire_pool_lock "$target_repo"
  sweep_classify_pool "$target_repo" \
    || die "pool $target_repo could not be revalidated; nothing was changed"
  [ "$SWEEP_UNSAFE_CLAIM" = 0 ] \
    || die "an unreadable slot-owner claim exists in pool $target_repo; nothing was changed"
  [ "$SWEEP_UNPROVABLE" = 0 ] \
    || die "slot occupancy is unprovable in pool $target_repo; nothing was changed"
  for i in "${!SWEEP_PATHS[@]}"; do
    canon=$(canonical_existing_dir "${SWEEP_PATHS[$i]}") || continue
    [ "$canon" = "$target" ] || continue
    [ "${SWEEP_CLASSES[$i]}" = dirty ] \
      || die "slot $target changed tier during validation; nothing was changed"
    echo "sweep: captain-approved destroy of dirty slot ${SWEEP_NAMES[$i]} at $canon"
    ( cd "$target_repo" && treehouse destroy "$canon" --include-unlanded --yes ) \
      || die "treehouse destroy failed for $canon"
    exit 0
  done
  die "$apply_slot disappeared during validation; nothing was changed"
fi

if [ "$apply_clean" = 1 ]; then
  flag="$CONFIG_DIR/treehouse-sweep-clean"
  [ -f "$flag" ] && [ ! -L "$flag" ] \
    || die "clean-tier removal is gated on the opt-in config/treehouse-sweep-clean flag file under the Firstmate home; create it to enable, or run without --apply-clean for a dry run"
fi

# --- classify + report (default) ---------------------------------------------

sweep_rc=0
clean_repos=()
clean_paths=()
clean_names=()
for repo in "${pools[@]}"; do
  sweep_classify_pool "$repo" || {
    [ "$apply_clean" = 0 ] || die "pool $repo could not be classified; nothing was changed"
    sweep_rc=1
    continue
  }
  sweep_report_pool "$repo"
  if [ "$apply_clean" = 1 ]; then
    [ "$SWEEP_UNSAFE_CLAIM" = 0 ] \
      || die "an unreadable slot-owner claim exists in pool $repo; nothing was changed"
    [ "$SWEEP_UNPROVABLE" = 0 ] \
      || die "slot occupancy is unprovable in pool $repo; nothing was changed"
    for i in "${!SWEEP_CLASSES[@]}"; do
      [ "${SWEEP_CLASSES[$i]}" = clean ] || continue
      canon=$(canonical_existing_dir "${SWEEP_PATHS[$i]}") \
        || die "clean slot ${SWEEP_PATHS[$i]} disappeared during validation; nothing was changed"
      clean_repos+=("$repo")
      clean_paths+=("$canon")
      clean_names+=("${SWEEP_NAMES[$i]}")
    done
  fi
done

if [ "$apply_clean" = 1 ]; then
  for repo in "${pools[@]}"; do
    sweep_acquire_batch_lock "$repo"
  done
  for i in "${!clean_paths[@]}"; do
    repo=${clean_repos[$i]}
    canon=${clean_paths[$i]}
    sweep_classify_pool "$repo" \
      || die "pool $repo could not be revalidated; nothing was changed"
    [ "$SWEEP_UNSAFE_CLAIM" = 0 ] \
      || die "an unreadable slot-owner claim exists in pool $repo; nothing was changed"
    [ "$SWEEP_UNPROVABLE" = 0 ] \
      || die "slot occupancy is unprovable in pool $repo; nothing was changed"
    still_clean=0
    for j in "${!SWEEP_PATHS[@]}"; do
      check=$(canonical_existing_dir "${SWEEP_PATHS[$j]}" 2>/dev/null || true)
      if [ "$check" = "$canon" ] && [ "${SWEEP_CLASSES[$j]}" = clean ]; then
        still_clean=1
        break
      fi
    done
    [ "$still_clean" = 1 ] \
      || die "clean slot $canon changed state during validation; nothing was changed"
  done
  for i in "${!clean_paths[@]}"; do
    repo=${clean_repos[$i]}
    canon=${clean_paths[$i]}
    echo "sweep: removing clean slot ${clean_names[$i]} at $canon"
    ( cd "$repo" && treehouse destroy "$canon" --yes ) \
      || die "treehouse destroy failed for clean slot $canon"
  done
  sweep_release_batch_locks
fi
exit "$sweep_rc"
