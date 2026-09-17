#!/usr/bin/env bash
# fm-treehouse-status-read-only.sh audit regressions:
#  - a foreign-owned /proc pid whose cwd is unreadable (EACCES/EPERM) is
#    un-attributable, so it must not mark every slot in-use and silence the audit
#  - an unleased treehouse-state.json entry with no backing `git worktree list`
#    registration surfaces as a distinct orphan diagnostic
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
[ "$(uname 2>/dev/null)" = Linux ] || { echo "skip: /proc occupancy scan is Linux-only"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-treehouse-status)
REPO="$TMP_ROOT/repo"
POOL="$TMP_ROOT/pool"
SLOT="$POOL/1/repo"
mkdir -p "$REPO" "$POOL"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Firstmate Tests"
git -C "$REPO" config user.email "tests@firstmate.invalid"
printf 'fixture\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -qm "initial fixture"
git -C "$REPO" worktree add --detach "$SLOT" -q
printf 'uncommitted\n' > "$SLOT/dirty-file"

# Pool state: slot 1 unleased; slot 9 is an orphan - in state but never
# registered in `git worktree list`.
ORPHAN="$POOL/9/repo"
node - "$POOL" "$SLOT" "$ORPHAN" <<'NODE'
const fs = require("fs");
const [pool, slot, orphan] = process.argv.slice(2);
fs.writeFileSync(`${pool}/treehouse-state.json`, JSON.stringify({worktrees: [
  {name: "1", path: slot, created_at: "2026-01-01T00:00:00Z"},
  {name: "9", path: orphan, created_at: "2026-01-01T00:00:00Z"},
]}));
NODE

# Fake /proc: pid 4001's cwd points under a directory nobody can read, exactly
# like a foreign-owned process on a multi-user host.
PROC="$TMP_ROOT/proc"
SECRET="$TMP_ROOT/foreign-secret"
mkdir -p "$PROC/4001" "$SECRET/inner"
ln -s "$SECRET/inner" "$PROC/4001/cwd"
chmod 000 "$SECRET"

audit() {
  FM_PROC_ROOT_OVERRIDE="$PROC" "$ROOT/bin/fm-treehouse-status-read-only.sh" "$REPO"
}

out=$(audit) || fail "the audit failed: $out"
assert_contains "$out" "\"slot\":\"1\"" "a foreign-owned EACCES pid still silences the dirty-slot report"
assert_contains "$out" "\"orphan\":true" "the state-only orphan slot did not surface as a diagnostic"
assert_contains "$out" "\"slot\":\"9\"" "the orphan diagnostic does not name slot 9"
pass "a foreign EACCES pid is un-attributable and orphaned slots are reported"

# The same scan still detects a process that really is inside the slot.
mkdir -p "$PROC/4002"
ln -s "$SLOT" "$PROC/4002/cwd"
out=$(audit) || fail "the audit failed with a live occupant: $out"
case "$out" in
  *'"slot":"1"'*) fail "a process cwd inside the slot no longer marks it in-use" ;;
esac
assert_contains "$out" "\"slot\":\"9\"" "the orphan diagnostic vanished when a slot read as in-use"
pass "a live process cwd inside the slot still suppresses it"

chmod 755 "$SECRET"
pass "fm-treehouse-status-read-only audit regressions hold"
