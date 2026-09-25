#!/usr/bin/env bash
# Write a private per-worker Devin config for one Firstmate crew.
# Usage: fm-devin-config.sh <state-dir> <task-id> [<user-config>]
# The default source is ${XDG_CONFIG_HOME:-$HOME/.config}/devin/config.json (Devin's --config default).
# An absent source starts from {}; unreadable or malformed sources refuse.
# Output: <state-dir>/<task-id>.devin-config.json, mode 600, atomically replaced.
# No project or user config is edited. fm-teardown.sh owns retirement.
# Two settings are forced for every worker. read_config_from.claude=false,
# because Devin otherwise runs every Claude Code hook it finds (~/.claude and
# the project's .claude/settings*.json), including Herdr's hook that reports
# the pane as a Claude agent; it also drops Devin's CLAUDE.md, .claude/skills,
# and Claude MCP imports, while AGENTS.md and .agents/skills still load.
# attribution=false, because Devin otherwise adds a Co-Authored-By: Devin
# trailer and a Generated with Devin line to commits and PRs.
# The worker config also carries this fork's guarded turn-end Stop hook
# (bin/fm-devin-turnend-hook.sh) so the notification survives even if a
# --config launch changes how project-local .devin/config.local.json loads;
# a duplicate registration is harmless because the publisher is idempotent
# and generation-bound.
set -eu
case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
    ;;
esac
STATE=${1:?state directory required}
ID=${2:?task id required}
SOURCE=${3:-${XDG_CONFIG_HOME:-$HOME/.config}/devin/config.json}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'error: invalid task id' >&2; exit 1 ;; esac
[ -d "$STATE" ] || { echo 'error: state directory missing' >&2; exit 1; }
STATE=$(cd "$STATE" && pwd -P)
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 1; }
DEVIN_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/devin"
STOP_HOOK="bash \"$DEVIN_HOME/fm-turn-end.sh\""
if [ ! -e "$SOURCE" ] && [ ! -L "$SOURCE" ]; then SOURCE=/dev/null; fi
umask 077
temp=$(mktemp "$STATE/.$ID.devin-config.XXXXXX")
trap 'rm -f "$temp"' EXIT
jq -s --arg stop "$STOP_HOOK" '
  (if length == 0 then {} elif length == 1 then .[0] else error("expected one config object") end) |
  if type != "object" then error("expected config object") else . end |
  .attribution = false |
  .read_config_from = ((.read_config_from // {}) + {claude: false}) |
  .hooks = (.hooks // {}) |
  .hooks.Stop = ((.hooks.Stop // []) + [{matcher: "", hooks: [{type: "command", command: $stop, timeout: 5}]}])
' "$SOURCE" > "$temp"
mv "$temp" "$STATE/$ID.devin-config.json"
