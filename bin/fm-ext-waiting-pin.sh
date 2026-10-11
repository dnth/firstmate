#!/usr/bin/env bash
# fm-ext-waiting-pin.sh - refresh the pinned "Waiting on you" Discord message.
#
# Usage:
#   fm-ext-waiting-pin.sh refresh [--force]
#   fm-ext-waiting-pin.sh content
#   fm-ext-waiting-pin.sh --help
#
# In one configured channel, a single bot message lists what is waiting on
# the captain: open captain-held board items (titles only), PRs ready for
# the captain's merge word (full URLs), and a last-updated time. The message
# is edited in place, never re-posted. When it was deleted or unpinned, it
# is recreated once and the new id is recorded.
#
# The bridge must be active (config/ext-bridge plus a mode-0600 secret; see
# bin/fm-ext-lib.sh) AND the pin target must be configured
# (config/ext-waiting-pin with `<guild>:<channel>`). Without both, refresh
# and content print `waiting-pin: unconfigured` on stderr and exit 3.
# Titles and PR URLs only: no paths, no secrets, no worktree names.
#
# State: state/ext-waiting-pin.json records the posted message id, the
# channel it was posted in, whether it is pinned, and the last content hash.
# A content hash match skips the Discord call (idempotent). A minimum
# interval (FM_EXT_WAITING_PIN_MIN_SECS, default 60) rate-limits refreshes;
# --force bypasses the interval but never the content-hash skip.
#
# Delivery reuses the poster path: content is written as a one-shot outbox
# payload that the gateway plugin's outbox_poster drains, through a
# `waiting-pin` helper pair in outbox_poster.py (post + edit + pin). The
# refresh command never touches the Discord network itself, so it stays
# hermetic and a failed refresh never blocks Firstmate's own work: refresh
# failures exit 0 after printing `waiting-pin: deferred <reason>`.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

WAITING_PIN_STATE_BASENAME='ext-waiting-pin.json'
WAITING_PIN_CONFIG_BASENAME='ext-waiting-pin'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-ext-waiting-pin: %s\n' "$*" >&2
  exit 1
}

# A refresh failure must never block Firstmate's own work: print the reason
# and exit 0 so lifecycle callers can append `|| true`-free.
defer() {
  printf 'waiting-pin: deferred %s\n' "$*" >&2
  exit 0
}

waiting_pin_config_path() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/$WAITING_PIN_CONFIG_BASENAME"
}

waiting_pin_state_path() {
  printf '%s\n' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$WAITING_PIN_STATE_BASENAME"
}

# Print "<guild_id> <channel_id>" from config/ext-waiting-pin. The file holds
# one `<guild>:<channel>` line; callers ignore extra lines after the first.
waiting_pin_target() {
  local cfg line guild channel rest
  cfg=$(waiting_pin_config_path)
  [ -f "$cfg" ] && [ ! -L "$cfg" ] || return 1
  line=$(sed -n '1p' "$cfg" 2>/dev/null) || return 1
  case "$line" in
    *:*) guild=${line%%:*}; rest=${line#*:} ;;
    *) return 1 ;;
  esac
  case "$rest" in
    *:*|*/*|*' '*) return 1 ;;
  esac
  channel=$rest
  case "$guild" in ''|*[!0-9]*) return 1 ;; esac
  case "$channel" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s %s\n' "$guild" "$channel"
}

waiting_pin_min_secs() {
  local raw=${FM_EXT_WAITING_PIN_MIN_SECS:-60}
  case "$raw" in ''|*[!0-9]*) printf '60\n' ;; *) printf '%s\n' "$raw" ;; esac
}

waiting_pin_now() {
  local now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$now"
}

# waiting_pin_board <data>: print the message body lines from durable board
# records only. Captain calls come from tasks-axi held rows (open items only);
# PR-ready URLs come from the recorded pr= metadata fm-pr-lib.sh owns.
# Prints nothing when there is nothing waiting.
waiting_pin_board() {
  local data=$1 root backend listing rows
  data=$(fm_backlog_data_absolute "$data") || return 1
  root=$(fm_backlog_root "$data") || return 1
  backend=$(fm_tasks_axi_backend "$root") || return 1
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") || return 1
    listing=$(cd "$root" && tasks-axi list --state held --fields held,hold_kind,hold_reason --file "$file" 2>/dev/null) || return 1
  else
    listing=$(cd "$root" && tasks-axi list --state held --fields held,hold_kind,hold_reason 2>/dev/null) || return 1
  fi
  rows=$(printf '%s\n' "$listing" | LC_ALL=C awk '
    /^tasks\[[0-9]+\]/ { declared = 1; next }
    /^count:/ { next }
    /^help\[/ { exit }
    /^task:/ { exit }
    NF == 0 { next }
    { print }
  ') || true
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | while IFS=, read -r id _state _kind _repo title held hold_kind _rest; do
    id=$(printf '%s' "$id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    title=$(printf '%s' "$title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    held=$(printf '%s' "$held" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    hold_kind=$(printf '%s' "$hold_kind" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$id" ] || continue
    [ "$held" = yes ] || continue
    [ "$hold_kind" = captain ] || continue
    case "$title" in '"'*) title=$(printf '%s' "$title" | sed 's/^"//;s/"$//') ;; esac
    [ -n "$title" ] || title=$id
    printf 'CALL %s\t%s\n' "$id" "$title"
  done
  return 0
}

# waiting_pin_prs <state>: print PR-ready URLs from recorded task metadata.
# A PR counts as ready when state/<id>.meta carries a canonical pr= URL and
# the board row for <id> is still open (not Done).
waiting_pin_prs() {
  local state=$1 meta id url rest
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    url=$(grep '^pr=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" >/dev/null 2>&1 || continue
    rest=$(fm_backlog_row_show "$DATA" "$id" 2>/dev/null) || continue
    case "$rest" in *'state: done'*|*'not found in this backlog'*) continue ;; esac
    printf 'PR %s\t%s\n' "$id" "$FM_PR_URL"
  done
  return 0
}

# waiting_pin_body: print the body lines WITHOUT the timestamp header, so the
# content hash is stable across refreshes with unchanged board state.
waiting_pin_body() {
  local calls prs line title url
  calls=$(waiting_pin_board "$DATA") || calls=
  prs=$(waiting_pin_prs "$STATE") || prs=
  if [ -z "$calls" ] && [ -z "$prs" ]; then
    printf 'Nothing waiting - all clear.\n'
    return 0
  fi
  if [ -n "$calls" ]; then
    printf 'Open decisions:\n'
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      title=${line#*	}
      [ -n "$title" ] || continue
      printf -- '- %s\n' "$title" | cut -c1-200
    done <<< "$calls"
  fi
  if [ -n "$prs" ]; then
    printf 'PRs ready for your merge word:\n'
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      url=${line#*	}
      [ -n "$url" ] || continue
      printf -- '- %s\n' "$url"
    done <<< "$prs"
  fi
  return 0
}

# waiting_pin_render <now>: print the full message text to stdout.
waiting_pin_render() {
  local now=$1 stamp
  stamp=$(date -u -d "@$now" '+%Y-%m-%d %H:%M' 2>/dev/null || date -u '+%Y-%m-%d %H:%M')
  printf 'Waiting on you (updated %s UTC)\n' "$stamp"
  waiting_pin_body
}

# content: print the rendered message to stdout (for tests and previews).
cmd_content() {
  local guild channel now
  fm_ext_active "$FM_HOME" >/dev/null 2>&1 || { printf 'waiting-pin: unconfigured\n' >&2; return 3; }
  waiting_pin_target >/dev/null || { printf 'waiting-pin: unconfigured\n' >&2; return 3; }
  guild=$(waiting_pin_target | cut -d' ' -f1)
  channel=$(waiting_pin_target | cut -d' ' -f2)
  now=$(waiting_pin_now) || fail "could not read the current time"
  waiting_pin_render "$now"
}

# refresh: recompute content; skip when unchanged or rate-limited; else write
# a one-shot outbox payload the gateway poster drains into an edit-in-place.
cmd_refresh() {
  local force=0 guild channel now body text hash state_path old_hash last_at min_secs age
  case "${1:-}" in ''|--force) [ "${1:-}" != "--force" ] || force=1 ;; *) fail "invalid arguments '$*'" ;; esac
  fm_ext_active "$FM_HOME" >/dev/null 2>&1 || { printf 'waiting-pin: unconfigured\n' >&2; return 3; }
  waiting_pin_target >/dev/null || { printf 'waiting-pin: unconfigured\n' >&2; return 3; }
  guild=$(waiting_pin_target | cut -d' ' -f1)
  channel=$(waiting_pin_target | cut -d' ' -f2)
  now=$(waiting_pin_now) || defer "the current time could not be read"
  command -v jq >/dev/null 2>&1 || defer "jq is required"
  body=$(waiting_pin_body) || defer "the board could not be read"
  text=$(waiting_pin_render "$now") || defer "the board could not be read"
  hash=$(printf '%s' "$body" | sha256sum 2>/dev/null | awk '{print $1}' \
    || printf '%s' "$body" | shasum -a 256 | awk '{print $1}') || defer "the content hash failed"
  state_path=$(waiting_pin_state_path)
  if [ -f "$state_path" ]; then
    old_hash=$(jq -r '.content_hash // empty' "$state_path" 2>/dev/null) || old_hash=
    last_at=$(jq -r '.refreshed_at // 0' "$state_path" 2>/dev/null) || last_at=0
    if [ "$hash" = "$old_hash" ] && [ -n "$old_hash" ]; then
      printf 'waiting-pin: unchanged\n'
      return 0
    fi
    if [ "$force" -eq 0 ]; then
      min_secs=$(waiting_pin_min_secs)
      case "$last_at" in ''|*[!0-9]*) last_at=0 ;; esac
      age=$((now - last_at))
      if [ "$age" -lt "$min_secs" ]; then
        printf 'waiting-pin: rate-limited\n'
        return 0
      fi
    fi
  fi
  # One-shot payload the gateway poster's waiting-pin helper drains: it posts
  # once, pins once, then edits in place on later refreshes.
  outbox_publish "$guild" "$channel" "$text" "$hash" "$now" || defer "the outbox publish failed"
  printf 'waiting-pin: refreshed\n'
  return 0
}

# Write state/ext-outbox/waiting-pin.<n>.json once; the poster claims it,
# posts or edits the pinned message, and records state/ext-waiting-pin.json.
outbox_publish() {
  local guild=$1 channel=$2 text=$3 hash=$4 now=$5
  local outbox payload tmp
  outbox=$(fm_ext_outbox_dir "$FM_HOME")
  mkdir -p "$outbox" || return 1
  payload="$outbox/waiting-pin.$now.json"
  tmp="$payload.tmp.$$"
  jq -cn \
    --argjson schema_version "$FM_EXT_SCHEMA_VERSION" \
    --arg kind "waiting-pin" \
    --arg guild_id "$guild" \
    --arg channel_id "$channel" \
    --arg text "$text" \
    --arg content_hash "$hash" \
    --argjson recorded_at "$now" \
    '{schema_version:$schema_version, kind:$kind, platform:"discord",
      source:"hermes-gateway", guild_id:$guild_id, channel_id:$channel_id,
      text:$text, content_hash:$content_hash, recorded_at:$recorded_at}' > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f -- "$tmp" "$payload" || { rm -f "$tmp"; return 1; }
  return 0
}

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "${1:-}" in
  refresh) shift; cmd_refresh "${1:-}" ;;
  content) cmd_content ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
