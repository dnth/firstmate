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

fm_inbox_valid_utc_timestamp() {
  local value=${1:-} year month day hour minute second max_day
  [[ "$value" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] || return 1
  year=$((10#${BASH_REMATCH[1]}))
  month=$((10#${BASH_REMATCH[2]}))
  day=$((10#${BASH_REMATCH[3]}))
  hour=$((10#${BASH_REMATCH[4]}))
  minute=$((10#${BASH_REMATCH[5]}))
  second=$((10#${BASH_REMATCH[6]}))
  [ "$month" -ge 1 ] && [ "$month" -le 12 ] || return 1
  [ "$hour" -le 23 ] && [ "$minute" -le 59 ] && [ "$second" -le 59 ] || return 1
  case "$month" in
    2)
      max_day=28
      ((year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))) && max_day=29
      ;;
    4|6|9|11) max_day=30 ;;
    *) max_day=31 ;;
  esac
  [ "$day" -ge 1 ] && [ "$day" -le "$max_day" ]
}

fm_inbox_private_regular_file() { # <path> [mode]
  local path=$1 expected=${2:-} mode
  fm_inbox_artifact_safe "$path" || return 1
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
  local target=$1 line fd fd_identity path_identity
  fm_inbox_valid_reply_target "$target" || return 1
  fm_inbox_private_regular_file "$FM_INBOX_RESULT_TARGETS_FILE" 600 || return 1
  exec {fd}<"$FM_INBOX_RESULT_TARGETS_FILE" || return 1
  fm_inbox_private_regular_file "$FM_INBOX_RESULT_TARGETS_FILE" 600 || {
    exec {fd}<&-
    return 1
  }
  if [ "$(uname)" = Darwin ]; then
    fd_identity=$(stat -L -f '%d:%i' "/dev/fd/$fd") || { exec {fd}<&-; return 1; }
    path_identity=$(stat -L -f '%d:%i' "$FM_INBOX_RESULT_TARGETS_FILE") || { exec {fd}<&-; return 1; }
  else
    fd_identity=$(stat -L -c '%d:%i' "/proc/$$/fd/$fd") || { exec {fd}<&-; return 1; }
    path_identity=$(stat -L -c '%d:%i' "$FM_INBOX_RESULT_TARGETS_FILE") || { exec {fd}<&-; return 1; }
  fi
  [ "$fd_identity" = "$path_identity" ] || { exec {fd}<&-; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    if [ "$line" = "$target" ]; then
      exec {fd}<&-
      return 0
    fi
  done <&$fd
  exec {fd}<&-
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

fm_inbox_validate_note_envelope() { # <path> <note-id>
  local note=$1 id=$2 correlation target created message_size
  fm_inbox_valid_note_id "$id" || return 1
  jq -e --arg id "$id" \
    '.schema == "firstmate.inbox-note.v1" and .note_id == $id and
     .request_note_id == $id and
     (.correlation_id | type == "string") and
     (.reply_target | type == "string") and
     (.message | type == "string" and length > 0 and length <= 65536) and
     (.created_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
    "$note" >/dev/null || return 1
  correlation=$(jq -r '.correlation_id' "$note") || return 1
  fm_inbox_valid_correlation_id "$correlation" || return 1
  target=$(jq -r '.reply_target' "$note") || return 1
  fm_inbox_valid_reply_target "$target" || return 1
  created=$(jq -r '.created_at' "$note") || return 1
  fm_inbox_valid_utc_timestamp "$created" || return 1
  message_size=$(jq -j '.message' "$note" | wc -c | tr -d ' ') || return 1
  [ "$message_size" -le 65536 ]
}

fm_inbox_validate_result_envelope() { # <path> <note-id>
  local path=$1 id=$2 correlation target created summary_size artifact
  fm_inbox_valid_note_id "$id" || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  jq -e --arg id "$id" \
    '.schema == "firstmate.inbox-result.v1" and .note_id == $id and
     .request_note_id == $id and
     (.correlation_id | type == "string") and
     (.reply_target | type == "string") and
     (.status == "completed" or .status == "failed" or .status == "needs-input") and
     (.summary | type == "string" and length > 0) and
     (.created_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
     (.artifacts | type == "array" and length <= 20 and all(.[]; type == "string"))' \
    "$path" >/dev/null || return 1
  correlation=$(jq -r '.correlation_id' "$path") || return 1
  fm_inbox_valid_correlation_id "$correlation" || return 1
  target=$(jq -r '.reply_target' "$path") || return 1
  fm_inbox_valid_reply_target "$target" || return 1
  created=$(jq -r '.created_at' "$path") || return 1
  fm_inbox_valid_utc_timestamp "$created" || return 1
  summary_size=$(jq -j '.summary' "$path" | wc -c | tr -d ' ') || return 1
  [ "$summary_size" -le 16384 ] || return 1
  while IFS= read -r artifact; do
    fm_inbox_artifact_safe "$artifact" || return 1
  done < <(jq -r '.artifacts[]' "$path")
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
