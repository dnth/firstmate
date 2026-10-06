#!/usr/bin/env bash
# Mechanical merge guards shared by bin/fm-pr-merge.sh and bin/fm-merge-local.sh.
# Each caller collects the reasons a merge must not run on standing authority,
# then lets fm_merge_guard_resolve refuse or apply the captain's override.
#
# Guards:
#   - accepted-blocked: a ship task whose bin/fm-receipt-check.sh <id> output
#     lists any accepted_blocked criterion is refused, naming each criterion id
#     and its recorded captain exception. Evidence that cannot be read refuses
#     too, because an accepted-blocked criterion cannot then be ruled out.
#     Tasks whose metadata kind is not ship carry no acceptance criteria and
#     are not checked.
#   - red checks: owned by bin/fm-pr-merge.sh, which adds its own reasons.
#
# Override: --captain-instruction "<words>" carries the captain's concrete
# merge instruction verbatim; it must be one non-blank line. Standing yolo
# merge authority never satisfies a guard, and destructive or
# security-sensitive escalation rules are unchanged. When the flag overrides at
# least one reason, one fm-merge-override.v1 JSON line (task, script, target,
# overridden reasons, verbatim instruction, UTC time) is appended to
# data/<id>/captain-merge-instructions.jsonl before the merge runs; a record
# that cannot be written refuses the merge. A flag passed while no guard fires
# records nothing.
#
# Caller contract: set SCRIPT_DIR, FM_HOME, and FM_MERGE_GUARD_DATA (the data
# directory) before calling; ids are validated by fm_merge_guard_task_id_valid.

FM_MERGE_GUARD_REASONS=

fm_merge_guard_task_id_valid() {
  case "${1:-}" in
    ''|.|..|*[!A-Za-z0-9._-]*|[._-]*) return 1 ;;
  esac
  return 0
}

# A usable instruction is one line with at least one non-blank character.
fm_merge_guard_instruction_valid() {
  local words=${1:-}
  case "$words" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  [ -n "${words//[[:space:]]/}" ]
}

fm_merge_guard_add_reason() {
  if [ -n "$FM_MERGE_GUARD_REASONS" ]; then
    FM_MERGE_GUARD_REASONS="$FM_MERGE_GUARD_REASONS"$'\n'"$1"
  else
    FM_MERGE_GUARD_REASONS=$1
  fi
}

# fm_merge_guard_check_accepted_blocked <task-id> <meta-file>
fm_merge_guard_check_accepted_blocked() {
  local id=$1 meta=$2 kind out rc=0 blocked
  kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ "$kind" = ship ] || return 0
  out=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$FM_MERGE_GUARD_DATA" \
    "$SCRIPT_DIR/fm-receipt-check.sh" "$id" 2>/dev/null) || rc=$?
  if [ "$rc" -gt 2 ] || ! blocked=$(printf '%s' "$out" | jq -er '
      .accepted_blocked
      | if type == "array" then . else error("no accepted_blocked") end
      | map(.criterion + " (captain exception: " + (.captain_exception // "") + ")")
      | join(", ")' 2>/dev/null); then
    fm_merge_guard_add_reason "acceptance evidence for task $id could not be read, so an accepted-blocked criterion cannot be ruled out"
    return 0
  fi
  [ -z "$blocked" ] \
    || fm_merge_guard_add_reason "acceptance criteria accepted as blocked: $blocked"
}

# fm_merge_guard_resolve <task-id> <script-name> <target> <instruction>
# Returns 0 when the merge may run, 1 after printing a refusal.
fm_merge_guard_resolve() {
  local id=$1 script=$2 target=$3 instruction=$4 reason dir log reasons_json now
  [ -n "$FM_MERGE_GUARD_REASONS" ] || return 0
  if [ -z "$instruction" ]; then
    while IFS= read -r reason; do
      printf 'error: refusing to merge %s for task %s: %s\n' "$target" "$id" "$reason" >&2
    done <<EOF
$FM_MERGE_GUARD_REASONS
EOF
    printf 'error: standing merge authority does not cover this merge; only the captain'"'"'s explicit instruction for it does: retry with --captain-instruction "<the captain'"'"'s exact words>"\n' >&2
    return 1
  fi
  dir="$FM_MERGE_GUARD_DATA/$id"
  log="$dir/captain-merge-instructions.jsonl"
  reasons_json=$(printf '%s\n' "$FM_MERGE_GUARD_REASONS" | jq -Rsc 'split("\n") | map(select(length > 0))') \
    || reasons_json=
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -z "$reasons_json" ] || [ -L "$dir" ] || [ -L "$log" ] || ! mkdir -p "$dir" \
    || ! jq -cn --arg task "$id" --arg script "$script" --arg target "$target" \
      --arg instruction "$instruction" --arg at "$now" --argjson reasons "$reasons_json" \
      '{schema:"fm-merge-override.v1",task:$task,script:$script,target:$target,overridden:$reasons,captain_instruction:$instruction,at:$at}' \
      >> "$log"; then
    printf 'error: refusing to merge %s for task %s: the captain instruction could not be recorded at %s\n' \
      "$target" "$id" "$log" >&2
    return 1
  fi
  while IFS= read -r reason; do
    printf 'notice: merging %s for task %s under the recorded captain instruction despite: %s\n' \
      "$target" "$id" "$reason" >&2
  done <<EOF
$FM_MERGE_GUARD_REASONS
EOF
  return 0
}
