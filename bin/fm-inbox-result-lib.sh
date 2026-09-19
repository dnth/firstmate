#!/usr/bin/env bash
# Shared validation for trusted-local inbox reply metadata and result delivery.
# This file is sourced; callers own error reporting and process exits.

FM_INBOX_CONFIG="${FM_CONFIG_OVERRIDE:-${FM_HOME:-$HOME/.firstmate}/config}"
FM_INBOX_RESULT_TARGETS_FILE="${FM_INBOX_RESULT_TARGETS_FILE:-$FM_INBOX_CONFIG/inbox-result-targets}"

fm_inbox_valid_note_id() {
  case "${1:-}" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_inbox_valid_correlation_id() {
  local value=${1:-}
  [ -n "$value" ] && [ "${#value}" -le 256 ] || return 1
  case "$value" in
    *[!A-Za-z0-9._:-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_inbox_valid_reply_target() {
  local target=${1:-}
  [ "${#target}" -le 512 ] || return 1
  [[ "$target" =~ ^hermes:[a-z][a-z0-9_-]*:[A-Za-z0-9@#%+._-]+(:[A-Za-z0-9@#%+._-]+)?$ ]]
}

fm_inbox_private_regular_file() { # <path> [mode]
  local path=$1 expected=${2:-} mode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  if [ -n "$expected" ]; then
    if [ "$(uname)" = Darwin ]; then
      mode=$(stat -f %Lp "$path" 2>/dev/null) || return 1
    else
      mode=$(stat -c %a "$path" 2>/dev/null) || return 1
    fi
    [ "$mode" = "$expected" ] || return 1
  fi
}

fm_inbox_reply_target_authorized() {
  local target=$1 line
  fm_inbox_valid_reply_target "$target" || return 1
  fm_inbox_private_regular_file "$FM_INBOX_RESULT_TARGETS_FILE" 600 || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    [ "$line" = "$target" ] && return 0
  done < "$FM_INBOX_RESULT_TARGETS_FILE"
  return 1
}

fm_inbox_note_is_envelope() {
  local note=$1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e '.schema == "firstmate.inbox-note.v1" and
         (.note_id | type == "string") and
         (.request_note_id | type == "string") and
         (.correlation_id | type == "string") and
         (.reply_target | type == "string") and
         (.message | type == "string") and
         (.created_at | type == "string")' "$note" >/dev/null 2>&1
}

fm_inbox_artifact_safe() {
  local path=$1 parent physical logical
  case "$path" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *'/../'*|*'/./'*|*'//'*) return 1 ;;
  esac
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 1
  parent=${path%/*}
  [ -n "$parent" ] || parent=/
  physical=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -P) || return 1
  logical=$(CDPATH='' cd -- "$parent" 2>/dev/null && pwd -L) || return 1
  [ "$physical" = "$logical" ]
}
