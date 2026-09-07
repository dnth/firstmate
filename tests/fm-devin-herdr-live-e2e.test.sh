#!/usr/bin/env bash
# Opt-in real Devin crew lifecycle evidence on Herdr.
set -u
[ "${FM_DEVIN_LIVE_E2E:-}" = 1 ] || { echo "SKIP: set FM_DEVIN_LIVE_E2E=1"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
command -v devin >/dev/null 2>&1 || { echo "ERROR: Devin CLI is required" >&2; exit 1; }
command -v herdr >/dev/null 2>&1 || { echo "ERROR: Herdr CLI is required" >&2; exit 1; }
[ -n "${FM_DEVIN_LIVE_TASK:-}" ] || { echo "ERROR: FM_DEVIN_LIVE_TASK must name a prepared crew task" >&2; exit 1; }
state=${FM_DEVIN_LIVE_STATE:-$ROOT/state}
id=$FM_DEVIN_LIVE_TASK
meta="$state/$id.meta"
[ -f "$meta" ] || { echo "ERROR: missing task metadata: $meta" >&2; exit 1; }
gen=$(sed -n 's/^spawn_gen=//p' "$meta" | tail -1)
[ -n "$gen" ] || { echo "ERROR: task metadata has no spawn generation" >&2; exit 1; }
marker="$state/$id.turn-ended.$gen"
worktree=$(sed -n 's/^worktree=//p' "$meta" | tail -1)
registry=$(sed -n 's/^devin_turnend_dir=//p' "$meta" | tail -1)
[ -n "$worktree" ] && [ -n "$registry" ] \
  || { echo "ERROR: task metadata has no Devin hook paths" >&2; exit 1; }
config="$worktree/.devin/config.local.json"
hook="${registry%/fm-turn-end.d}/fm-turn-end.sh"
jq -e --arg command "bash \"$hook\"" '
  .hooks.Stop == [{matcher:"",hooks:[{type:"command",command:$command,timeout:5}]}]
' "$config" >/dev/null || { echo "ERROR: Devin native project-local Stop hook is not installed" >&2; exit 1; }
for expected in working 'done'; do
  found=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    status=$(FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" 2>/dev/null || true)
    case "$status" in *"state=$expected"*|*"$expected"*) found=1; break ;; esac
    sleep 1
  done
  [ "$found" -eq 1 ] || { echo "ERROR: Devin crew state never reached $expected" >&2; exit 1; }
done
[ -f "$marker" ] || { echo "ERROR: Devin Stop hook did not publish $marker" >&2; exit 1; }
echo "ok - Devin Herdr crew loaded its native project-local Stop hook, published the turn-end marker, and reached working/done"
