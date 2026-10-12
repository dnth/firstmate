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
# is edited in place. When deleted, it is recreated once and the new id is
# recorded; when unpinned, its pin is restored.
#
# The bridge must be active (config/ext-bridge plus a mode-0600 secret; see
# bin/fm-ext-lib.sh) AND the pin target must be configured
# (config/ext-waiting-pin with `<guild>:<channel>`). Without both, refresh
# and content print `waiting-pin: unconfigured` on stderr and exit 3.
# Titles and PR URLs only: no paths, no secrets, no worktree names.
#
# State: state/ext-waiting-pin.json records the posted message id, the
# channel it was posted in, whether it is pinned, and the last content hash.
# Matching pending content skips publication. A minimum interval
# (FM_EXT_WAITING_PIN_MIN_SECS, default 60) rate-limits publication, including
# reconciliation of unchanged delivered content; --force bypasses the interval.
#
# Delivery reuses the poster path: content is written as a one-shot outbox
# payload that the gateway plugin's outbox_poster drains, through a
# `waiting-pin` helper pair in outbox_poster.py (post + edit + pin). The
# refresh command never touches the Discord network itself, so it stays
# hermetic and a failed refresh never blocks Firstmate's own work: refresh
# failures exit 0 after printing `waiting-pin: deferred <reason>`.
set -uo pipefail

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
# shellcheck source=bin/fm-axi-rows-lib.sh
. "$SCRIPT_DIR/fm-axi-rows-lib.sh"

WAITING_PIN_STATE_BASENAME='ext-waiting-pin.json'

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

waiting_pin_state_path() {
  printf '%s\n' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$WAITING_PIN_STATE_BASENAME"
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

# waiting_pin_title <data> <id>: print the task's full title from an exact
# `show --full` read, decoded and normalized to one pin line. The board
# listing truncates long titles with a tool-generated helper (`...
# (truncated, N chars total - use show <id> --full ...)`), which must never
# reach the public pin: it leaks the task id and a command. Held calls
# therefore always read the full title here instead of reusing the listed
# one; the renderer's 200-character call-line cap shortens it cleanly.
# tasks-axi folds typed links (--report, --pr) into the stored title prose,
# so strip those artifact suffixes plus the `(repo: ...)` tag here: no local
# paths or PR URLs may reach the public pin. A final backstop drops any
# remaining path-like token. Fails when the read fails so the refresh defers
# rather than publishing a leak or a false all-clear.
waiting_pin_title() {
  local data=$1 id=$2 show_output raw links
  show_output=$(fm_backlog_row_show "$data" "$id" --full 2>/dev/null) || return 1
  raw=$(printf '%s\n' "$show_output" | sed -n 's/^  title: //p' | head -1) || return 1
  [ -n "$raw" ] || return 1
  links=$(printf '%s\n' "$show_output" | sed -n 's/^  links: //p' | head -1) || return 1
  printf '%s' "$raw" | python3 -c '
import json, re, sys
s = sys.stdin.read()
value = json.loads(s) if s.startswith(chr(34)) else s
value = value.replace(chr(9), " ").replace(chr(10), " ").replace(chr(13), " ")
value = re.sub(r"\s*\(repo:\s*[^)]+\)\s*$", "", value)
links = sys.argv[1]
links = json.loads(links) if links.startswith(chr(34)) else links
pr_targets = [link[3:] for link in links.split(",") if link.startswith("pr:")]
artifact = r"\((?:report|pr)\)\s+(?:https?://\S+|\S*/\S+|\S+\.md)"
targets = [artifact, r"data/\S+?/report\.md"] + [re.escape(url) for url in pr_targets]
value = re.sub(r"(?:\s+(?:" + "|".join(targets) + r"))+$", "", value)
tokens = [t for t in value.split(" ") if not re.search(r"(?:data|state)/|/home/|\.md\b", t)]
print(re.sub(r"\s+", " ", " ".join(tokens)).strip(), end="")
' "$links" || return 1
}

# waiting_pin_board <data>: print the message body lines from durable board
# records only. Captain calls come from actionable open captain-hold annotations.
# Prints nothing when there is nothing waiting.
waiting_pin_board() {
  local data=$1 listing ids today id title
  today=$(date -u '+%Y-%m-%d') || return 1
  listing=$(FM_TASKS_AXI_TIMEOUT=10 fm_backlog_row_list "$data" --fields hold_kind,hold_reason,hold_until,blocked) || return 1
  ids=$(axi_rows tasks "$listing" rows id hold_kind hold_reason hold_until blocked state | awk -F '\t' -v today="$today" '
    ($6 == "queued" || $6 == "in_flight") && $2 == "captain" && $3 != "" && $3 != "null" && $3 != "-" && $5 == "no" &&
      ($4 == "" || $4 == "null" || $4 == "-" || $4 <= today) {
        print $1
      }') || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    title=$(waiting_pin_title "$data" "$id") || return 1
    printf 'CALL %s\t%s\n' "$id" "$title"
  done <<< "$ids"
}

# waiting_pin_prs <state>: print PR-ready URLs from recorded task metadata.
# A PR counts as ready when state/<id>.meta carries a canonical pr= URL and
# the board row for <id> is still open (not Done), or the metadata is a
# retained landing record awaiting the captain's merge word.
waiting_pin_prs() {
  local state=$1 meta id url metadata
  [ -d "$state" ] && [ -r "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    metadata=$(cat "$meta") || return 1
    url=$(printf '%s\n' "$metadata" | grep '^pr=' 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" >/dev/null 2>&1 || continue
    if ! fm_pr_meta_kind_is "$meta" landing; then
      fm_backlog_row_probe "$DATA" "$id" >/dev/null 2>&1 || return 1
      case "${FM_BACKLOG_ROW_STATE%% *}" in
        done) continue ;;
        queued|in_flight) ;;
        *) return 1 ;;
      esac
    fi
    printf 'PR %s\t%s\n' "$id" "$FM_PR_URL"
  done
  return 0
}

# waiting_pin_body: print the body lines WITHOUT the timestamp header, so the
# content hash is stable across refreshes with unchanged board state.
waiting_pin_body() {
  local calls prs line title url
  calls=$(waiting_pin_board "$DATA") || return 1
  prs=$(waiting_pin_prs "$STATE") || return 1
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
      printf -- '- %s\n' "$title"
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
  local now=$1 body=${2-} stamp
  if [ "$#" -lt 2 ]; then
    body=$(waiting_pin_body) || return 1
  fi
  stamp=$(date -u -d "@$now" '+%Y-%m-%d %H:%M' 2>/dev/null || date -u '+%Y-%m-%d %H:%M')
  printf 'Waiting on you (updated %s UTC)\n%s\n' "$stamp" "$body" | python3 -c '
import sys
text = sys.stdin.read().rstrip("\n")
lines = text.splitlines()
in_calls = False
for index, line in enumerate(lines):
    if line == "Open decisions:":
        in_calls = True
    elif line == "PRs ready for your merge word:":
        in_calls = False
    elif in_calls and line.startswith("- ") and len(line) > 200:
        lines[index] = line[:199] + "…"
text = "\n".join(lines)
if len(text) > 2000:
    suffix = "\n… More waiting items omitted; check the board for the full list."
    lines = text.splitlines()
    while lines and len("\n".join(lines)) + len(suffix) > 2000:
        lines.pop()
    text = "\n".join(lines) + suffix
print(text)
'
}

# content: print the rendered message to stdout (for tests and previews).
cmd_content() {
  local guild channel now
  fm_ext_active "$FM_HOME" >/dev/null 2>&1 || { printf 'waiting-pin: unconfigured\n' >&2; return 3; }
  fm_ext_waiting_pin_target "$FM_HOME" >/dev/null || { printf 'waiting-pin: unconfigured\n' >&2; return 3; }
  guild=$(fm_ext_waiting_pin_target "$FM_HOME" | cut -d' ' -f1)
  channel=$(fm_ext_waiting_pin_target "$FM_HOME" | cut -d' ' -f2)
  now=$(waiting_pin_now) || fail "could not read the current time"
  waiting_pin_render "$now"
}

# refresh: recompute content; skip matching pending content or rate limits; write
# a one-shot outbox payload the gateway poster drains into an edit-in-place.
cmd_refresh() {
  local force=0 guild channel now body text hash state_path old_hash old_guild old_channel last_at min_secs age
  local records reference outbox file pending same=0 publication_slug publication_release target
  case "${1:-}" in ''|--force) [ "${1:-}" != "--force" ] || force=1 ;; *) fail "invalid arguments '$*'" ;; esac
  fm_ext_active "$FM_HOME" >/dev/null 2>&1 || { printf 'waiting-pin: unconfigured\n' >&2; return 3; }
  fm_ext_waiting_pin_target "$FM_HOME" >/dev/null || { printf 'waiting-pin: unconfigured\n' >&2; return 3; }
  command -v jq >/dev/null 2>&1 || defer "jq is required"
  outbox=$(fm_ext_outbox_dir "$FM_HOME")
  publication_slug=$(printf '%064d' 1)
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  FM_EXT_INFLIGHT_OWNER_PID=$$ fm_run_timed 30 bash -c '
    . "$1/fm-ext-lib.sh"
    while :; do
      fm_ext_outbox_inflight_claim "$2" "$3" waiting-pin 1
      claim_status=$?
      [ "$claim_status" -eq 1 ] || exit "$claim_status"
      sleep 0.1
    done
  ' _ "$SCRIPT_DIR" "$outbox" "$publication_slug" || defer "the publication claim could not be acquired"
  printf -v publication_release 'fm_ext_outbox_inflight_release %q %q waiting-pin 1 >/dev/null 2>&1' "$outbox" "$publication_slug"
  # shellcheck disable=SC2064 # Capture shell-escaped locals before the function returns.
  trap "$publication_release" EXIT
  target=$(fm_ext_waiting_pin_target "$FM_HOME") || { printf 'waiting-pin: unconfigured\n' >&2; return 3; }
  read -r guild channel <<< "$target"
  now=$(waiting_pin_now) || defer "the current time could not be read"
  body=$(waiting_pin_body) || defer "the board could not be read"
  text=$(waiting_pin_render "$now" "$body") || defer "the board could not be read"
  hash=$(printf '%s' "$body" | sha256sum 2>/dev/null | awk '{print $1}' \
    || printf '%s' "$body" | shasum -a 256 | awk '{print $1}') || defer "the content hash failed"
  state_path=$(waiting_pin_state_path)
  records='{}'
  if [ -f "$state_path" ]; then
    records=$(jq -c '. + {pending:false}' "$state_path") || defer "the delivery record could not be read"
  fi
  for file in "$outbox"/waiting-pin.*.json; do
    [ -e "$file" ] || continue
    fm_ext_private_artifact_file_valid "$outbox" "${file##*/}" 600 || defer "the pending snapshot is unsafe"
    reference=$(jq -c '. + {pending:true}' "$file") || defer "the pending snapshot could not be read"
    records="$records
$reference"
  done
  reference=$(printf '%s\n' "$records" | jq -sc 'max_by((.snapshot_id // ((.refreshed_at // 0) * 1000000000)) | tonumber)') || defer "the refresh record could not be read"
  old_hash=$(jq -r '.content_hash // empty' <<< "$reference")
  old_guild=$(jq -r '.guild_id // empty' <<< "$reference")
  old_channel=$(jq -r '.channel_id // empty' <<< "$reference")
  last_at=$(jq -r '.recorded_at // .refreshed_at // 0' <<< "$reference")
  pending=$(jq -r '.pending // false' <<< "$reference")
  if [ "$guild" = "$old_guild" ] && [ "$channel" = "$old_channel" ] && [ "$hash" = "$old_hash" ] && [ -n "$old_hash" ]; then
    same=1
    if [ "$pending" = true ]; then
      printf 'waiting-pin: unchanged\n'
      return 0
    fi
  fi
  if [ -n "$old_hash" ] && [ "$force" -eq 0 ]; then
    min_secs=$(waiting_pin_min_secs)
    case "$last_at" in ''|*[!0-9]*) last_at=0 ;; esac
    age=$((now - last_at))
    if [ "$age" -lt "$min_secs" ]; then
      if [ "$same" -eq 1 ]; then
        printf 'waiting-pin: unchanged\n'
      else
        printf 'waiting-pin: rate-limited\n'
      fi
      return 0
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
  local outbox snapshot payload
  outbox=$(fm_ext_outbox_dir "$FM_HOME")
  snapshot=$(python3 -c 'import time; print(time.time_ns())') || return 1
  payload=$(jq -cn \
    --argjson schema_version "$FM_EXT_SCHEMA_VERSION" \
    --arg kind "waiting-pin" \
    --arg guild_id "$guild" \
    --arg channel_id "$channel" \
    --arg text "$text" \
    --arg content_hash "$hash" \
    --arg snapshot_id "$snapshot" \
    --argjson recorded_at "$now" \
    '{schema_version:$schema_version, kind:$kind, platform:"discord",
      source:"hermes-gateway", guild_id:$guild_id, channel_id:$channel_id,
      text:$text, content_hash:$content_hash, recorded_at:$recorded_at,
      snapshot_id:$snapshot_id}') || return 1
  printf '%s\n' "$payload" | fm_ext_private_artifact_publish_stdin_once "$outbox" "waiting-pin.$snapshot.json" 600
}

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "${1:-}" in
  refresh) shift; cmd_refresh "${1:-}" ;;
  content) cmd_content ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
