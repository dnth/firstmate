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

(cd "$REPO" && treehouse return --if-lease-holder retry "$second") >/dev/null \
  || fail "the recovered lease could not be returned"
(cd "$REPO" && treehouse return --if-lease-holder first "$first") >/dev/null \
  || fail "the first lease could not be returned"

pass "an interrupted unregistered Treehouse target is removed and acquired automatically"
