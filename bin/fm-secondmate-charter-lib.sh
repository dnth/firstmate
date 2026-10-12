#!/usr/bin/env bash
# Shared extraction of secondmate registry summary and scope from a charter.
# Source only. FM_SECONDMATE_CHARTER and FM_SECONDMATE_SCOPE remain explicit
# caller overrides; otherwise the named sections in the filled brief are used.

normalize_registry_text() {
  awk '
    {
      gsub(/[;()]/, " ")
      gsub(/[[:space:]]+/, " ")
      sub(/^ /, "")
      sub(/ $/, "")
      if ($0 != "") out = out (out == "" ? "" : " ") $0
    }
    END { print out }
  '
}

brief_section_text() {
  local brief=$1 heading=$2
  awk -v heading="# $heading" '
    $0 == heading { in_section=1; next }
    in_section && /^# / { exit }
    in_section { print }
  ' "$brief"
}

registry_summary_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_CHARTER:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_CHARTER" | normalize_registry_text
  else
    brief_section_text "$brief" "Charter" | normalize_registry_text
  fi
}

registry_scope_for_brief() {
  local brief=$1
  if [ -n "${FM_SECONDMATE_SCOPE:-}" ]; then
    printf '%s\n' "$FM_SECONDMATE_SCOPE" | normalize_registry_text
  else
    brief_section_text "$brief" "Routing scope" | normalize_registry_text
  fi
}

secondmate_spawn_brief() {
  local home=$1 fallback=$2 brief
  if [ -f "$home/data/charter.md" ]; then
    brief="$home/data/charter.md"
  else
    brief=$fallback
  fi
  [ -f "$brief" ] || { echo "error: no brief at $brief" >&2; return 1; }
  if grep -F '{TASK}' "$brief" >/dev/null 2>&1; then
    echo "error: secondmate brief still contains {TASK}; replace every scaffold placeholder before spawn" >&2
    return 1
  fi
  printf '%s\n' "$brief"
}
