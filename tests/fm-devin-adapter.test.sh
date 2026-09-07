#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
TMP_ROOT=$(fm_test_tmproot fm-devin-adapter)
HOME="$TMP_ROOT/home"; export HOME
workspace="$TMP_ROOT/workspace"; state="$TMP_ROOT/state"; id=devin-hook; gen=g1; token=fm.abcdefghijkl
mkdir -p "$HOME/.devin/hooks/fm-turn-end.d" "$workspace" "$state"
printf 'token=%s\n' "$token" > "$workspace/.fm-devin-turnend"
printf 'target=%s/%s.turn-ended\nspawn_gen=%s\nsignal=%s/bin/fm-turnend-signal.sh\n' "$state" "$id" "$gen" "$ROOT" > "$HOME/.devin/hooks/fm-turn-end.d/$token"
HOME="$HOME" "$ROOT/bin/fm-devin-turnend-hook.sh" install
printf '%s\n' '{"hook_event_name":"Stop","cwd":"'"$workspace"'"}' | HOME="$HOME" "$HOME/.devin/hooks/fm-turn-end.sh"
[ -f "$state/$id.turn-ended.$gen" ] || fail "Devin Stop hook did not publish the generation-bound marker"
HOME="$HOME" "$ROOT/bin/fm-devin-turnend-hook.sh" remove
[ ! -e "$HOME/.devin/hooks/fm-turn-end.sh" ] || fail "Devin hook teardown left the hook installed"
pass "Devin Stop hook publishes generation-bound markers and tears down cleanly"
