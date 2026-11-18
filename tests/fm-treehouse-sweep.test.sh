#!/usr/bin/env bash
# fm-treehouse-sweep.sh: the default pass classifies every unleased slot and
# never executes prune --yes or destroy, the ownership proof refuses slots
# claimed or named by another task's record, and the apply tiers stay behind
# their gates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-treehouse-sweep)
REPO="$TMP_ROOT/repo"
HOME_DIR="$TMP_ROOT/home"
POOL="$TMP_ROOT/pool"
mkdir -p "$REPO" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$POOL"

git -C "$REPO" init -q -b main
git -C "$REPO" config user.name "Firstmate Tests"
git -C "$REPO" config user.email "tests@firstmate.invalid"
printf 'fixture\n' > "$REPO/README.md"
# Mirror the real repo: secondmate role markers are gitignored, so a slot
# carrying them is invisible to the porcelain cleanliness check.
printf '.fm-secondmate-home\n.fm-secondmate-parent\n' > "$REPO/.gitignore"
git -C "$REPO" add README.md .gitignore
git -C "$REPO" commit -qm "initial fixture"

# An origin remote lets the landedness proof resolve a default ref.
git -C "$REPO" init -q --bare "$TMP_ROOT/origin.git"
git -C "$REPO" remote add origin "$TMP_ROOT/origin.git"
git -C "$REPO" push -q origin main
git -C "$REPO" remote set-head origin main >/dev/null

# Slots: 1 clean, 2 dirty, 3 claimed by another task, 4 meta-named, 5 damaged,
# 7 clean except for a retired secondmate's leftover role markers, 8 clean.
slot() { printf '%s/%s/repo\n' "$POOL" "$1"; }
git -C "$REPO" worktree add --detach "$(slot 1)" -q
git -C "$REPO" worktree add --detach "$(slot 2)" -q
git -C "$REPO" worktree add --detach "$(slot 3)" -q
git -C "$REPO" worktree add --detach "$(slot 4)" -q
git -C "$REPO" worktree add --detach "$(slot 7)" -q
git -C "$REPO" worktree add --detach "$(slot 8)" -q
mkdir -p "$(slot 5)"
printf 'uncommitted\n' > "$(slot 2)/dirty-file"
printf 'task=other-task\nhome=/elsewhere\n' > "$(dirname "$(slot 3)")/.fm-slot-owner"
printf 'worktree=%s\n' "$(slot 4)" > "$HOME_DIR/state/other.meta"
# Role markers are gitignored: porcelain-clean slots can still carry them.
printf 'retired-mate\n' > "$(slot 7)/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=/nowhere\n' > "$(slot 7)/.fm-secondmate-parent"
printf '{"worktrees":[{"path":"%s"},{"path":"%s"},{"path":"%s"},{"path":"%s"},{"path":"%s"},{"path":"%s"}]}\n' \
  "$(slot 1)" "$(slot 2)" "$(slot 3)" "$(slot 4)" "$(slot 7)" "$(slot 8)" > "$POOL/treehouse-state.json"

json_entries() {
  node - "$POOL" <<'NODE'
const pool = process.argv[2];
const mk = (n, status, extra={}) => JSON.stringify(Object.assign({
  name: n, path: `${pool}/${n}/repo`, status, flavor: "git",
  lease_id: "", lease_holder: "", leased_at: null, processes: [],
}, extra));
process.stdout.write("[" + [
  mk("1", "available"),
  mk("2", "dirty"),
  mk("3", "available"),
  mk("4", "available"),
  mk("5", "damaged"),
  mk("6", "leased", {lease_holder: "fm-interactive-1"}),
  mk("7", "available"),
  mk("8", "available"),
].join(",") + "]");
NODE
}

# Fake treehouse: records every invocation, serves canned status, never deletes.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CALLS="$TMP_ROOT/treehouse-calls"
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_SWEEP_CALLS"
case "$1" in
  status) cat "$FM_SWEEP_STATUS_JSON" ;;
  prune) echo "would prune 1 stale worktree" ;;
  destroy)
    case " $* " in
      *" --yes "*) echo "destroyed (fake)" ;;
      *) echo "destroy dry run (fake)" ;;
    esac
    if [ -n "${FM_SWEEP_TOUCH_STOP:-}" ]; then : > "$FM_SWEEP_TOUCH_STOP"; fi
    ;;
esac
SH
chmod +x "$FAKEBIN/treehouse"

export PATH="$FAKEBIN:$PATH"
export FM_SWEEP_CALLS="$CALLS"
FM_SWEEP_STATUS_JSON="$TMP_ROOT/status.json"
export FM_SWEEP_STATUS_JSON
json_entries > "$FM_SWEEP_STATUS_JSON"

SWEEP_ENV=(
  FM_ROOT_OVERRIDE="$REPO"
  FM_HOME="$HOME_DIR"
  FM_STATE_OVERRIDE="$HOME_DIR/state"
  FM_CONFIG_OVERRIDE="$HOME_DIR/config"
  FM_PROJECTS_OVERRIDE="$HOME_DIR/no-projects"
)
run_sweep() { env "${SWEEP_ENV[@]}" "$ROOT/bin/fm-treehouse-sweep.sh" "$@"; }

# --- default: classify only, no destructive verbs -----------------------------

out=$(run_sweep --pool "$REPO") || fail "default sweep failed: $out"
assert_contains "$out" "slot 1      clean" "the clean slot was not classified clean"
assert_contains "$out" "slot 2      dirty" "the dirty slot was not classified dirty"
assert_contains "$out" "slot 3      skipped" "the claimed slot was not skipped"
assert_contains "$out" "claimed by task other-task" "the claim reason is missing"
assert_contains "$out" "slot 4      skipped" "the meta-named slot was not skipped"
assert_contains "$out" "task other's record names this slot" "the meta-record reason is missing"
assert_contains "$out" "slot 5      damaged" "the damaged slot was not classified damaged"
assert_contains "$out" "slot 6      skipped" "the leased slot was not skipped"
assert_contains "$out" "slot 7      dirty" "a slot carrying a retired secondmate's markers was not reported"
assert_contains "$out" ".fm-secondmate-home" "the marker report did not name the marker file"
assert_contains "$out" "secondmate" "the marker report did not explain the role residue"
assert_contains "$out" "dry run" "the prune dry-run verdict is missing from the report"
if grep -Eq 'destroy .*--yes|prune .*--yes' "$CALLS" 2>/dev/null; then
  fail "the default pass executed a destructive treehouse verb: $(cat "$CALLS")"
fi
pass "default pass classifies all tiers and runs nothing destructive"

# A real empty status response is a valid empty pool and must classify zero
# slots successfully rather than entering the heredoc loop with empty fields.
status_json=$(<"$FM_SWEEP_STATUS_JSON")
printf '[]\n' > "$FM_SWEEP_STATUS_JSON"
state_json=$(<"$POOL/treehouse-state.json")
printf '{"worktrees":[]}\n' > "$POOL/treehouse-state.json"
out=$(run_sweep --pool "$REPO") || fail "empty-status sweep failed: $out"
printf '%s\n' "$status_json" > "$FM_SWEEP_STATUS_JSON"
printf '%s\n' "$state_json" > "$POOL/treehouse-state.json"
pass "empty status response succeeds with zero classifications"

# Empty Treehouse state keeps reported worktrees inspect-only.
printf '{"worktrees":[]}\n' > "$POOL/treehouse-state.json"
out=$(run_sweep --pool "$REPO") || fail "empty-state sweep failed: $out"
assert_contains "$out" "unregistered or orphaned worktree" "empty state did not keep slots inspect-only"
printf '%s\n' "$state_json" > "$POOL/treehouse-state.json"
pass "empty state keeps unregistered slots inspect-only"

mkdir -p "$(slot 9)"
printf 'surviving partial data\n' > "$(slot 9)/payload"
: > "$CALLS"
out=$(run_sweep --pool "$REPO" --measure "$(slot 1)" --measure "$(slot 5)" \
  --measure "$(slot 9)" --measure "$(slot 10)") || fail "measurement failed: $out"
assert_contains "$out" "classification: clean" "measurement lost the clean classification"
assert_contains "$out" "classification: damaged" "measurement lost the damaged classification"
assert_contains "$out" "classification: damaged/unreported" "unreported surviving content was not identified"
assert_contains "$out" "existence: present" "measurement did not report surviving content"
assert_contains "$out" "existence: absent" "measurement did not report the removed path"
assert_contains "$out" "size_kib: 0 (absent)" "removed path size was not reported"
for n in 1 5 9; do
  expected_size=$(du -sk "$(slot "$n")")
  assert_contains "$out" "$expected_size" "measurement did not return the host du size for slot $n"
done
[ -f "$(slot 9)/payload" ] || fail "measurement removed partial data"
if grep -Eq 'destroy|prune' "$CALLS"; then
  fail "measurement called a removal or prune verb: $(cat "$CALLS")"
fi
printf '{"worktrees":[]}\n' > "$POOL/treehouse-state.json"
saved_status=$(<"$FM_SWEEP_STATUS_JSON")
printf '[]\n' > "$FM_SWEEP_STATUS_JSON"
out=$(run_sweep --pool "$REPO" --measure "$(slot 10)") \
  || fail "measurement failed after all slot registrations were removed: $out"
assert_contains "$out" "existence: absent" "empty pool did not report the removed path"
printf '%s\n' "$saved_status" > "$FM_SWEEP_STATUS_JSON"
printf '%s\n' "$state_json" > "$POOL/treehouse-state.json"
pass "read-only measurement reports clean, damaged, partial, and fully removed paths"

mkdir -p "$TMP_ROOT/outside"
ln -s "$TMP_ROOT/outside" "$POOL/linked"
for invalid in "$TMP_ROOT/outside" "$POOL/linked/repo" "$POOL/1/../outside"; do
  if out=$(run_sweep --pool "$REPO" --measure "$invalid" 2>&1); then
    fail "measurement accepted an outside, symlinked, or traversal path: $invalid"
  fi
  assert_contains "$out" "inside a pool" "measurement refusal did not identify the path boundary"
done
if out=$(run_sweep --pool "$REPO" --measure 2>&1); then
  fail "measurement accepted an unnamed path"
fi
assert_contains "$out" "requires an exact slot" "unnamed measurement refusal is missing"
for mode in --apply-clean --stop; do
  if out=$(run_sweep --measure "$(slot 1)" "$mode" 2>&1); then
    fail "measurement accepted $mode"
  fi
done
if out=$(run_sweep --measure "$(slot 2)" --apply-slot "$(slot 2)" --captain-approved 2>&1); then
  fail "measurement accepted single-slot removal"
fi
[ ! -e "$HOME_DIR/state/treehouse-sweep-stop" ] || fail "measurement wrote a stop marker"
if grep -Eq 'destroy|prune' "$CALLS"; then
  fail "a refused measurement executed a removal or prune verb: $(cat "$CALLS")"
fi
pass "measurement refuses unnamed, outside, symlinked, traversal, and mutating requests"

# --- --apply-clean requires the config flag -----------------------------------

if out=$(run_sweep --pool "$REPO" --apply-clean 2>&1); then
  fail "--apply-clean ran without the config flag"
fi
assert_contains "$out" "config/treehouse-sweep-clean" "the missing-flag refusal does not name the flag"
touch "$HOME_DIR/config/treehouse-sweep-clean"
canon1=$(cd "$(slot 1)" && pwd -P)
canon2=$(cd "$(slot 2)" && pwd -P)
canon4=$(cd "$(slot 4)" && pwd -P)
canon8=$(cd "$(slot 8)" && pwd -P)
: > "$CALLS"
out=$(run_sweep --pool "$REPO" --apply-clean) || fail "--apply-clean failed: $out"
assert_contains "$out" "removing clean slot 1" "--apply-clean did not remove the clean slot"
assert_contains "$out" "removing clean slot 8" "--apply-clean did not remove the second clean slot"
grep -Fqx "destroy $canon1 --yes" "$CALLS" \
  || fail "the clean slot was not destroyed via per-slot destroy --yes: $(cat "$CALLS")"
grep -Fqx "destroy $canon8 --yes" "$CALLS" \
  || fail "the second clean slot was not destroyed via per-slot destroy --yes: $(cat "$CALLS")"
if grep -Eq "destroy $canon2|destroy $canon4|prune --yes" "$CALLS"; then
  fail "--apply-clean touched a non-clean slot or ran pool-wide prune: $(cat "$CALLS")"
fi
pass "--apply-clean removes only the proven-clean slots, behind the config flag"

# --- --apply-slot gates --------------------------------------------------------

: > "$CALLS"
if out=$(run_sweep --pool "$REPO" --apply-slot "$(slot 2)" 2>&1); then
  fail "--apply-slot ran without --captain-approved"
fi
assert_contains "$out" "--captain-approved" "the approval refusal is missing"
if out=$(run_sweep --pool "$REPO" --apply-slot "$(slot 4)" --captain-approved 2>&1); then
  fail "--apply-slot destroyed a meta-named slot"
fi
assert_contains "$out" "record names this slot" "the meta-named refusal reason is missing"
if out=$(run_sweep --pool "$REPO" --apply-slot "$(slot 3)" --captain-approved 2>&1); then
  fail "--apply-slot destroyed another task's claimed slot"
fi
if out=$(run_sweep --pool "$REPO" --apply-slot "$(slot 5)" --captain-approved 2>&1); then
  fail "--apply-slot destroyed a damaged slot"
fi
assert_contains "$out" "manual captain act" "the damaged-slot refusal reason is missing"
if grep -q 'destroy' "$CALLS" 2>/dev/null; then
  fail "a refused --apply-slot still called treehouse destroy: $(cat "$CALLS")"
fi
out=$(run_sweep --pool "$REPO" --apply-slot "$(slot 2)" --captain-approved) \
  || fail "captain-approved dirty-slot destroy failed: $out"
grep -Fqx "destroy $canon2 --include-unlanded --yes" "$CALLS" \
  || fail "the dirty slot was not destroyed with --include-unlanded --yes: $(cat "$CALLS")"
pass "--apply-slot destroys only the named dirty slot, captain-approved"

# --- --apply-slot refuses an unnamed or out-of-pool path -----------------------

: > "$CALLS"
if out=$(run_sweep --pool "$REPO" --apply-slot 2>&1); then
  fail "--apply-slot ran without a path"
fi
assert_contains "$out" "requires an exact slot worktree path" "the unnamed-path refusal is missing"
mkdir -p "$TMP_ROOT/outside"
if out=$(run_sweep --pool "$REPO" --apply-slot "$TMP_ROOT/outside" --captain-approved 2>&1); then
  fail "--apply-slot destroyed a path outside the pool"
fi
assert_contains "$out" "not a managed unleased pool slot in scope" "the out-of-pool refusal is missing"
if grep -q 'destroy' "$CALLS" 2>/dev/null; then
  fail "a refused --apply-slot still called treehouse destroy: $(cat "$CALLS")"
fi
pass "--apply-slot refuses an unnamed or out-of-pool path"

# --- --include-* verbs are never forwarded ------------------------------------

if out=$(run_sweep --pool "$REPO" --apply-slot "$(slot 2)" --captain-approved --include-in-use 2>&1); then
  fail "the sweep forwarded --include-in-use"
fi
assert_contains "$out" "never forwarded" "the --include-in-use refusal is missing"
pass "risky treehouse verbs stay manual"

# --- stop marker: --stop writes it, an apply pass consumes it ------------------

STOP_FILE="$HOME_DIR/state/treehouse-sweep-stop"
rm -f "$STOP_FILE"
out=$(run_sweep --stop) || fail "--stop failed: $out"
[ -f "$STOP_FILE" ] || fail "--stop did not write $STOP_FILE"
assert_contains "$out" "stop marker written" "the --stop confirmation is missing"
: > "$CALLS"
out=$(run_sweep --pool "$REPO" --apply-clean 2>&1)
rc=$?
[ "$rc" -eq 3 ] || fail "an apply pass with a stop marker exited $rc, not 3: $out"
assert_contains "$out" "stop requested" "the stopped pass did not name the stop"
assert_contains "$out" "removed this pass: none" "the stopped pass did not report that nothing was removed"
printf '%s\n' "$out" | grep -Fq "  slot 1 $canon1" \
  || fail "the stopped pass did not list clean slot 1 as untouched: $out"
printf '%s\n' "$out" | grep -Fq "  slot 8 $canon8" \
  || fail "the stopped pass did not list clean slot 8 as untouched: $out"
[ -e "$STOP_FILE" ] && fail "the stopped pass left the marker in place"
if grep -q 'destroy' "$CALLS" 2>/dev/null; then
  fail "a stopped apply pass still called treehouse destroy: $(cat "$CALLS")"
fi
pass "--stop writes the marker and the next apply pass stops before removing anything"

# --- --apply-slot consumes a pending stop marker -------------------------------

out=$(run_sweep --stop) || fail "--stop failed: $out"
: > "$CALLS"
if out=$(run_sweep --pool "$REPO" --apply-slot "$(slot 2)" --captain-approved 2>&1); then
  fail "--apply-slot ran with a stop marker pending"
fi
assert_contains "$out" "a stop was requested" "the single-slot stop refusal is missing"
[ -e "$STOP_FILE" ] && fail "the single-slot pass left the stop marker in place"
if grep -q 'destroy' "$CALLS" 2>/dev/null; then
  fail "a stopped --apply-slot still called treehouse destroy: $(cat "$CALLS")"
fi
pass "--apply-slot consumes a pending stop marker and removes nothing"

# --- stop marker is honored between clean slots --------------------------------

rm -f "$STOP_FILE"
: > "$CALLS"
out=$(env "${SWEEP_ENV[@]}" "FM_SWEEP_TOUCH_STOP=$STOP_FILE" \
  "$ROOT/bin/fm-treehouse-sweep.sh" --pool "$REPO" --apply-clean 2>&1)
rc=$?
[ "$rc" -eq 3 ] || fail "a stop during the pass exited $rc, not 3: $out"
assert_contains "$out" "removing clean slot 1" "the pass did not remove the first clean slot before the stop"
assert_contains "$out" "stop requested" "the stopped pass did not name the stop"
printf '%s\n' "$out" | grep -Fq "  slot 1 $canon1" \
  || fail "the stopped pass did not list clean slot 1 as removed: $out"
printf '%s\n' "$out" | grep -Fq "  slot 8 $canon8" \
  || fail "the stopped pass did not list clean slot 8 as untouched: $out"
if grep -Fq "destroy $canon8 --yes" "$CALLS"; then
  fail "the pass removed a clean slot after the stop marker appeared: $(cat "$CALLS")"
fi
[ -e "$STOP_FILE" ] && fail "the stopped pass left the marker in place"
pass "a stop marker is honored between clean slots"

# --- unsafe claim refuses the apply pass ---------------------------------------

printf 'garbage\n' > "$(dirname "$(slot 1)")/.fm-slot-owner"
if out=$(run_sweep --pool "$REPO" --apply-clean 2>&1); then
  fail "--apply-clean ran with an unreadable claim in the pool"
fi
assert_contains "$out" "unreadable slot-owner claim" "the unsafe-claim refusal is missing"
rm -f "$(dirname "$(slot 1)")/.fm-slot-owner"
pass "an unreadable claim refuses the apply pass"

pass "fm-treehouse-sweep guarded classification and tier gates hold"
