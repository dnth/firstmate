#!/usr/bin/env bash
# The remote control script's sleep helpers: `children` counts live workers only,
# and `sleep-reconcile` retires finished ships of every delivery mode through
# ordinary teardown, never forced. fm-crew-state and fm-teardown are replaced by
# recording fakes in a copy of bin/, so this owns only the control script's
# decisions; teardown's landed-work test is owned by tests/fm-teardown*.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-sleep-reconcile)
BIN="$TMP_ROOT/bin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/bin"
cp -R "$ROOT/bin" "$BIN"
printf 'agents\n' > "$HOME_DIR/AGENTS.md"
printf 'ios\n' > "$HOME_DIR/.fm-secondmate-home"

CREW_STATES="$TMP_ROOT/crew-states"
UNLANDED="$TMP_ROOT/unlanded"
TEARDOWNS="$TMP_ROOT/teardowns"
TRANSITION="$TMP_ROOT/transition"
: > "$CREW_STATES"; : > "$UNLANDED"; : > "$TEARDOWNS"

cat > "$BIN/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
state=\$(sed -n "s/^\$1 //p" "$CREW_STATES" | head -1)
if [ -f "$TRANSITION" ] && [ "\$1" = shiprace ]; then
  printf 'shiprace done\n' > "$CREW_STATES"
  rm -f "$TRANSITION"
fi
printf 'state: %s · source: fake · fixture\n' "\${state:-unknown}"
SH
cat > "$BIN/fm-teardown.sh" <<SH
#!/usr/bin/env bash
[ "\$#" -eq 1 ] || exit 64
printf '%s\n' "\$1" >> "$TEARDOWNS"
if grep -qx "\$1" "$UNLANDED"; then printf 'refusing: unlanded work\n' >&2; exit 1; fi
rm -f "$HOME_DIR/state/\$1.meta"
SH
chmod +x "$BIN/fm-crew-state.sh" "$BIN/fm-teardown.sh"

ctl() { FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" "$BIN/fm-remote-secondmate-control.sh" "$@"; }
add_child() { # <id> <kind> <mode> <fake crew state>
  printf 'kind=%s\nmode=%s\n' "$2" "$3" > "$HOME_DIR/state/$1.meta"
  printf '%s %s\n' "$1" "$4" >> "$CREW_STATES"
}

add_child shipnm ship no-mistakes 'done'
add_child shipdp ship direct-PR 'done'
add_child shiplo ship local-only 'done'
add_child live ship no-mistakes working
add_child scout scout no-mistakes 'done'
add_child blind ship direct-PR unknown

[ "$(ctl children ios)" = children=3 ] \
  || fail "children must count only live ships, scouts, and unreadable ships, got: $(ctl children ios)"
pass "children leaves finished ships of every mode out of the live count"

: > "$TEARDOWNS"
if out=$(ctl sleep-reconcile ios 2>&1); then fail "remaining live work must refuse reconciliation"; fi
assert_contains "$out" "worker blind remains" "remaining worker refusal must name its record"
sort "$TEARDOWNS" | tr '\n' ' ' | grep -qx 'shipdp shiplo shipnm ' \
  || fail "reconcile touched the wrong tasks: $(tr '\n' ' ' < "$TEARDOWNS")"
[ ! -e "$HOME_DIR/state/shipnm.meta" ] && [ -e "$HOME_DIR/state/live.meta" ] \
  && [ -e "$HOME_DIR/state/scout.meta" ] && [ -e "$HOME_DIR/state/blind.meta" ] \
  || fail "reconcile removed something other than the finished ships"
[ "$(ctl children ios)" = children=3 ] || fail "live work must still count after reconcile"
pass "reconcile retires finished ships in every mode and refuses remaining live work"

rm -f "$HOME_DIR/state/live.meta" "$HOME_DIR/state/scout.meta" "$HOME_DIR/state/blind.meta"
[ "$(ctl sleep-reconcile ios)" = reconciled=0 ] || fail "an empty reconciled home must permit sleep"
[ "$(ctl children ios)" = children=0 ] || fail "an empty home must have no live workers"
add_child shipnm ship no-mistakes 'done'
add_child shipdp ship direct-PR 'done'
add_child shiplo ship local-only 'done'
[ "$(ctl sleep-reconcile ios)" = reconciled=3 ] || fail "finished landed ships must permit reconciliation"
[ "$(ctl children ios)" = children=0 ] || fail "successful reconciliation left workers behind"
pass "reconciliation succeeds for empty homes and finished landed ships in every mode"

# Unlanded finished work: teardown refuses, so reconcile fails and keeps it.
add_child shipun ship no-mistakes 'done'
printf 'shipun\n' > "$UNLANDED"
: > "$TEARDOWNS"
if out=$(ctl sleep-reconcile ios 2>&1); then fail "reconcile succeeded past unlanded finished work"; fi
assert_contains "$out" "shipun could not be torn down safely" "the refusal must name the finished ship"
[ -e "$HOME_DIR/state/shipun.meta" ] || fail "unlanded work was removed"
pass "a finished ship with unlanded work refuses the reconcile and is kept"

rm -f "$HOME_DIR/state/shipun.meta"
for mode in no-mistakes direct-PR local-only; do
  : > "$CREW_STATES"; : > "$TEARDOWNS"
  add_child shiprace ship "$mode" working
  printf 'shiprace\n' > "$UNLANDED"
  touch "$TRANSITION"
  if out=$(ctl sleep-reconcile ios 2>&1); then fail "a transitioning $mode ship permitted suspension"; fi
  assert_contains "$out" "worker shiprace remains" "transition refusal must name the ship"
  [ ! -s "$TEARDOWNS" ] || fail "the working observation must skip teardown"
  [ "$(ctl children ios)" = children=0 ] || fail "the later children read must see the ship as finished"
  [ -e "$HOME_DIR/state/shiprace.meta" ] || fail "transitioning unlanded work was removed"
  if out=$(ctl sleep-reconcile ios 2>&1); then fail "the now-finished unlanded ship permitted suspension"; fi
  assert_contains "$out" "shiprace could not be torn down safely" "ordinary teardown must reject unlanded work"
  [ "$(cat "$TEARDOWNS")" = shiprace ] || fail "finished ship did not pass through ordinary teardown"
  [ -e "$HOME_DIR/state/shiprace.meta" ] || fail "unlanded ship was removed after teardown refusal"
  rm -f "$HOME_DIR/state/shiprace.meta"
done
pass "working-to-done unlanded ships refuse suspension despite a later zero live count"
