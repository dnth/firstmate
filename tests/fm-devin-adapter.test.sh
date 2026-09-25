#!/usr/bin/env bash
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
TMP_ROOT=$(fm_test_tmproot fm-devin-adapter)
HOME="$TMP_ROOT/home"; export HOME
XDG_CONFIG_HOME="$HOME/.config"; export XDG_CONFIG_HOME
workspace="$TMP_ROOT/workspace"; state="$TMP_ROOT/state"; id=devin-hook; gen=g1; token=fm.abcdefghijkl
mkdir -p "$workspace" "$state"
printf 'token=%s\n' "$token" > "$workspace/.fm-devin-turnend"
HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$ROOT/bin/fm-devin-turnend-hook.sh" install "$workspace"
hook="$XDG_CONFIG_HOME/devin/fm-turn-end.sh"
registry="$XDG_CONFIG_HOME/devin/fm-turn-end.d/$token"
config="$workspace/.devin/config.local.json"
printf 'target=%s/%s.turn-ended\nspawn_gen=%s\nsignal=%s/bin/fm-turnend-signal.sh\n' "$state" "$id" "$gen" "$ROOT" > "$registry"
jq -e --arg command "bash \"$hook\"" '
  .hooks.Stop == [{matcher:"",hooks:[{type:"command",command:$command,timeout:5}]}]
' "$config" >/dev/null || fail "Devin native project-local config did not register the Stop hook"
printf '%s\n' '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"direct-probe","prompt_id":"turn-1"}' \
  | DEVIN_PROJECT_DIR="$workspace" "$hook"
[ -f "$state/$id.turn-ended.$gen" ] || fail "Devin Stop hook did not publish the generation-bound marker"
HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$ROOT/bin/fm-devin-turnend-hook.sh" install "$workspace"
HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$ROOT/bin/fm-devin-turnend-hook.sh" remove "$workspace"
[ ! -e "$config" ] || fail "Devin hook removal left the project-local config installed"

foreign="$TMP_ROOT/foreign"; mkdir -p "$foreign/.devin"
printf '%s\n' '{"operator":"keep"}' > "$foreign/.devin/config.local.json"
if HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$ROOT/bin/fm-devin-turnend-hook.sh" install "$foreign" >/dev/null 2>&1; then
  fail "Devin hook install overwrote a foreign project-local config"
fi
jq -e '.operator == "keep" and length == 1' "$foreign/.devin/config.local.json" >/dev/null \
  || fail "Devin hook refusal changed a foreign project-local config"

fakebin="$TMP_ROOT/fakebin"; mkdir -p "$fakebin"
agent_status="$TMP_ROOT/agent-status"
cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  'status --json') printf '%s\n' '{"server":{"running":true}}' ;;
  'pane get') printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
  'pane read') printf '\n' ;;
  'agent get')
    status=$(cat "$FM_DEVIN_TEST_AGENT_STATUS")
    printf '{"result":{"agent":{"agent":"devin","agent_status":"%s"}}}\n' "$status"
    ;;
  *) exit 1 ;;
esac
SH
chmod 700 "$fakebin/herdr"
cat > "$state/direct-state.meta" <<EOF
window=default:w1:p2
worktree=$workspace
project=$workspace
harness=devin
backend=herdr
kind=scout
EOF
printf '%s\n' working > "$agent_status"
out=$(PATH="$fakebin:$PATH" FM_DEVIN_TEST_AGENT_STATUS="$agent_status" FM_STATE_OVERRIDE="$state" \
  "$ROOT/bin/fm-crew-state.sh" direct-state)
case "$out" in 'state: working'*'source: pane'*'herdr-native'*) ;; *) fail "live Devin state was not working: $out" ;; esac
printf '%s\n' 'done: direct Devin turn completed' > "$state/direct-state.status"
printf '%s\n' 'done' > "$agent_status"
out=$(PATH="$fakebin:$PATH" FM_DEVIN_TEST_AGENT_STATUS="$agent_status" FM_STATE_OVERRIDE="$state" \
  "$ROOT/bin/fm-crew-state.sh" direct-state)
case "$out" in 'state: done'*'source: status-log'*) ;; *) fail "finished Devin state was not done: $out" ;; esac
pass "Devin native Stop hook publishes markers safely and crew-state reports working/done without unknown"

# Per-worker Devin config (bin/fm-devin-config.sh): forced isolation settings,
# preserved operator settings and hooks, embedded turn-end Stop hook, mode 600,
# atomic output, and loud refusal on a malformed source.
usercfg="$HOME/.config/devin/config.json"
mkdir -p "$HOME/.config/devin"
printf '%s\n' '{"model":"opus","read_config_from":{"claude":true,"other":true},"hooks":{"Stop":[{"matcher":"x","hooks":[{"type":"command","command":"user-hook","timeout":3}]}]}}' > "$usercfg"
HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$ROOT/bin/fm-devin-config.sh" "$state" "$id"
workercfg="$state/$id.devin-config.json"
[ -f "$workercfg" ] || fail "per-worker Devin config was not written"
[ "$(stat -c %a "$workercfg")" = 600 ] || fail "per-worker Devin config is not mode 600"
jq -e '
  .attribution == false and
  .read_config_from.claude == false and
  .read_config_from.other == true and
  .model == "opus" and
  (.hooks.Stop | length == 2) and
  (.hooks.Stop[0].hooks[0].command == "user-hook") and
  (.hooks.Stop[1].hooks[0].command | test("fm-turn-end\\.sh"))
' "$workercfg" >/dev/null || fail "per-worker Devin config lost user settings or missed the forced settings"
jq -e '.model == "opus" and (.read_config_from.claude == true) and (.hooks.Stop | length == 1)' "$usercfg" >/dev/null \
  || fail "per-worker Devin config write changed the operator's global config"
printf '%s\n' 'not json' > "$usercfg"
if HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$ROOT/bin/fm-devin-config.sh" "$state" "$id" >/dev/null 2>&1; then
  fail "per-worker Devin config accepted a malformed source config"
fi
rm -f "$usercfg"
HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" "$ROOT/bin/fm-devin-config.sh" "$state" "$id"
jq -e '.attribution == false and .read_config_from.claude == false' "$workercfg" >/dev/null \
  || fail "per-worker Devin config without a source lost the forced settings"
pass "Devin per-worker config forces isolation settings, preserves operator config, and refuses malformed sources"
