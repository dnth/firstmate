#!/usr/bin/env bash
# A guarded acquisition removes only the exact unregistered worktree target
# left by an interrupted Treehouse add, then retries without manual cleanup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-treehouse-orphan-recovery)
REPO="$TMP_ROOT/repo"
POOL_ROOT="$TMP_ROOT/pool"
mkdir -p "$REPO" "$POOL_ROOT"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Firstmate Tests"
git -C "$REPO" config user.email "tests@firstmate.invalid"
printf 'fixture\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm "initial fixture"
printf 'max_trees = 2\nroot = "%s"\n' "$POOL_ROOT" > "$REPO/treehouse.toml"

first=$(cd "$REPO" && "$ROOT/bin/fm-treehouse-get.sh" --lease --lease-holder first) \
  || fail "the first guarded lease could not be acquired"
pool=$(dirname "$(dirname "$first")")
orphan="$pool/2/$(basename "$REPO")"
mkdir -p "$orphan"
printf 'partial arrival\n' > "$orphan/interrupted-copy"

out=$(cd "$REPO" && "$ROOT/bin/fm-treehouse-get.sh" --lease --lease-holder retry 2>&1)
status=$?
[ "$status" -eq 0 ] || fail "the retry did not recover the unregistered orphan: $out"
second=$(printf '%s\n' "$out" | tail -1)
[ "$second" = "$orphan" ] || fail "the retry acquired $second instead of the recovered target $orphan"
[ ! -e "$orphan/interrupted-copy" ] || fail "the interrupted orphan contents survived the guarded retry"
git -C "$REPO" worktree list --porcelain | grep -Fqx "worktree $orphan" \
  || fail "the recovered target was not registered as a Git worktree"

registered_repo="$TMP_ROOT/registered-repo"
registered_pool="$TMP_ROOT/"$'registered\npool'
registered="$registered_pool/1/registered-repo"
mkdir -p "$registered_repo" "$(dirname "$registered")"
git -C "$registered_repo" init -q -b main
git -C "$registered_repo" config user.name "Firstmate Tests"
git -C "$registered_repo" config user.email "tests@firstmate.invalid"
printf 'fixture\n' > "$registered_repo/README.md"
git -C "$registered_repo" add README.md
git -C "$registered_repo" commit -qm "initial fixture"
git -C "$registered_repo" worktree add --detach "$registered" >/dev/null \
  || fail "the unusual-path registered worktree could not be created"
guard_dir="$TMP_ROOT/registered-guard"
mkdir -p "$guard_dir"
if (cd "$registered_repo" && \
  FM_TREEHOUSE_REAL_GIT=$(command -v git) \
  FM_TREEHOUSE_GUARD_ERROR_FILE="$guard_dir/error" \
  FM_TREEHOUSE_GUARD_SAFE_FILE="$guard_dir/safe" \
  FM_TREEHOUSE_GUARD_COMPLETE_FILE="$guard_dir/complete" \
  "$ROOT/bin/treehouse-git-guard/git" worktree add "$registered") 2>/dev/null; then
  fail "the guard accepted an already registered unusual-byte path"
fi
[ -d "$registered" ] || fail "the guard deleted an already registered unusual-byte path"

network_pool="$TMP_ROOT/network-volume/treehouse"
local_pool="$TMP_ROOT/local-treehouse"
mkdir -p "$network_pool" "$local_pool"
printf 'max_trees = 1\n"root" = "%s"\n' "$network_pool" > "$REPO/treehouse.toml"
repo_config=$(cat "$REPO/treehouse.toml")
local_acquired=$(cd "$REPO" && IS_SANDBOX=1 FM_TREEHOUSE_LOCAL_ROOT="$local_pool" \
  "$ROOT/bin/fm-treehouse-get.sh" --lease --lease-holder local-first) \
  || fail "the repository Treehouse config was not routed to the RunPod-local pool"
case "$local_acquired" in
  "$local_pool"/.treehouse/*) ;;
  *) fail "the repository Treehouse config acquired outside the RunPod-local pool: $local_acquired" ;;
esac
[ "$(cat "$REPO/treehouse.toml")" = "$repo_config" ] \
  || fail "routing the repository Treehouse config changed the project copy"
if (cd "$REPO" && IS_SANDBOX=1 FM_TREEHOUSE_LOCAL_ROOT="$local_pool" \
  "$ROOT/bin/fm-treehouse-get.sh" --lease --lease-holder pool-limit) >/dev/null 2>&1; then
  fail "the routed acquisition discarded the repository max_trees setting"
fi
[ ! -d "$network_pool/.treehouse" ] \
  || fail "the repository Treehouse root created a pool on network storage"

concurrent_pool="$TMP_ROOT/concurrent-local-treehouse"
mkdir -p "$concurrent_pool"
printf 'max_trees = 4\n"root" = "%s"\n' "$network_pool" > "$REPO/treehouse.toml"
concurrent_pids=
for index in 1 2 3 4; do
  (
    cd "$REPO" || exit 1
    IS_SANDBOX=1 FM_TREEHOUSE_LOCAL_ROOT="$concurrent_pool" \
      "$ROOT/bin/fm-treehouse-get.sh" --lease --lease-holder "concurrent-$index"
  ) > "$TMP_ROOT/concurrent-$index.out" 2> "$TMP_ROOT/concurrent-$index.err" &
  concurrent_pids="$concurrent_pids $!"
done
index=0
for concurrent_pid in $concurrent_pids; do
  index=$((index + 1))
  wait "$concurrent_pid" \
    || fail "concurrent first acquisition $index failed: $(cat "$TMP_ROOT/concurrent-$index.err")"
done
[ "$(cat "$TMP_ROOT"/concurrent-*.out | sort -u | wc -l | tr -d ' ')" = 4 ] \
  || fail "concurrent first acquisitions did not receive four distinct worktrees"
for index in 1 2 3 4; do
  concurrent_acquired=$(tail -1 "$TMP_ROOT/concurrent-$index.out")
  case "$concurrent_acquired" in
    "$concurrent_pool"/.treehouse/*) ;;
    *) fail "concurrent acquisition escaped the local pool: $concurrent_acquired" ;;
  esac
  (cd "$REPO" && IS_SANDBOX=1 FM_TREEHOUSE_LOCAL_ROOT="$concurrent_pool" \
    "$ROOT/bin/fm-treehouse-command.sh" return --if-lease-holder "concurrent-$index" "$concurrent_acquired") \
    >/dev/null || fail "concurrent local lease $index could not be returned"
done
printf '%s\n' "$repo_config" > "$REPO/treehouse.toml"

for unsafe_child in .treehouse .firstmate-config; do
  unsafe_pool="$TMP_ROOT/unsafe-${unsafe_child#.}"
  escaped="$TMP_ROOT/escaped-${unsafe_child#.}"
  mkdir -p "$unsafe_pool" "$escaped"
  printf 'sentinel\n' > "$escaped/sentinel"
  ln -s "$escaped" "$unsafe_pool/$unsafe_child"
  if (cd "$REPO" && IS_SANDBOX=1 FM_TREEHOUSE_LOCAL_ROOT="$unsafe_pool" \
    "$ROOT/bin/fm-treehouse-get.sh" --lease --lease-holder unsafe) >/dev/null 2>&1; then
    fail "the routed acquisition followed a symlinked $unsafe_child directory"
  fi
  [ "$(find "$escaped" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ] \
    || fail "the routed acquisition wrote through a symlinked $unsafe_child directory"
done

rm -rf -- "$local_pool"
mkdir -p "$local_pool"
local_retry=$(cd "$REPO" && IS_SANDBOX=1 FM_TREEHOUSE_LOCAL_ROOT="$local_pool" \
  "$ROOT/bin/fm-treehouse-get.sh" --lease --lease-holder local-retry) \
  || fail "the replacement pod could not reconcile its exact missing worktree registration"
[ "$local_retry" = "$local_acquired" ] \
  || fail "the replacement pod acquired $local_retry instead of its recovered local slot $local_acquired"
[ -d "$first" ] || fail "reconciling a missing local registration removed an existing worktree"
git -C "$REPO" worktree list --porcelain | grep -Fqx "worktree $first" \
  || fail "reconciling a missing local registration removed another registration"
(cd "$REPO" && IS_SANDBOX=1 FM_TREEHOUSE_LOCAL_ROOT="$local_pool" \
  "$ROOT/bin/fm-treehouse-command.sh" return --if-lease-holder local-retry "$local_retry") >/dev/null \
  || fail "the routed local lease could not be returned"

(cd "$REPO" && treehouse return --if-lease-holder retry "$second") >/dev/null \
  || fail "the recovered lease could not be returned"
(cd "$REPO" && treehouse return --if-lease-holder first "$first") >/dev/null \
  || fail "the first lease could not be returned"

pass "an interrupted unregistered Treehouse target is removed and acquired automatically"
