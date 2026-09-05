# shellcheck shell=bash
# Shared helpers for the sibling local-bridge Communication Officer
# (fm-ext-intake.sh, fm-ext-emit.sh, fm-ext-link.sh, fm-ext-poll.sh).
#
# This file is sourced, never executed. It copies the private-artifact
# publication pattern used by X mode without sourcing bin/fm-x-lib.sh and
# without touching the hosted relay, FMX_PAIRING_TOKEN, myfirstmate.io, or
# pending-reply.
#
# Opt-in is config/ext-bridge presence or FM_EXT_BRIDGE=1, plus a local
# mode-0600 secret file. There is no hosted pairing token.
#
# Canonical request_id keeps colons in JSON bodies
# (discord:<guild>:<channel>:<thread>:<message>). Filenames use the SHA-256
# hex digest of that canonical id.
#
# Callers must have FM_HOME set (or pass explicit state/config paths).

_FM_EXT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_EXT_LIB_DIR="."

FM_EXT_SCHEMA_VERSION=1
FM_EXT_INBOX_DIRNAME='ext-inbox'
FM_EXT_CONTEXT_DIRNAME='ext-context'
FM_EXT_OUTBOX_DIRNAME='ext-outbox'
FM_EXT_WATCH_SHIM='ext-watch.check.sh'
FM_EXT_SECRET_BASENAME='ext-secret'
FM_EXT_ALLOWLIST_BASENAME='ext-allowlist'
FM_EXT_BRIDGE_BASENAME='ext-bridge'

# --- private artifact publication (X-mode pattern, local names) -------------

fm_ext_single_link_file_valid() {
  local file=$1 expected_device=${2-} links device
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    links=$(stat -f %l "$file" 2>/dev/null) || return 1
    device=$(stat -f %d "$file" 2>/dev/null) || return 1
  else
    links=$(stat -c %h "$file" 2>/dev/null) || return 1
    device=$(stat -c %d "$file" 2>/dev/null) || return 1
  fi
  [ "$links" = 1 ] || return 1
  [ -z "$expected_device" ] || [ "$device" = "$expected_device" ]
}

fm_ext_single_link_file_mode_valid() {
  local file=$1 expected_mode=$2 expected_device=${3-} mode
  fm_ext_single_link_file_valid "$file" "$expected_device" || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$file" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$file" 2>/dev/null) || return 1
  fi
  [ "$mode" = "$expected_mode" ]
}

fm_ext_private_artifact_dir_device() {
  local dir=$1 mode device
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$dir" 2>/dev/null) || return 1
    device=$(stat -f %d "$dir" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$dir" 2>/dev/null) || return 1
    device=$(stat -c %d "$dir" 2>/dev/null) || return 1
  fi
  [ "$mode" = 700 ] || return 1
  printf '%s\n' "$device"
}

fm_ext_private_artifact_dir_prepare() {
  local dir=$1 parent
  parent=${dir%/*}
  if [ "$parent" != "$dir" ]; then
    if [ -e "$parent" ] || [ -L "$parent" ]; then
      [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    else
      (umask 077; mkdir -p "$parent" 2>/dev/null) || return 1
      [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    fi
  fi
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    (umask 077; mkdir -p "$dir" 2>/dev/null) || return 1
  fi
  fm_ext_private_artifact_dir_device "$dir"
}

fm_ext_private_artifact_publish_stdin() {
  local dir=$1 base=$2 mode=$3 device tmp dest
  case "$base" in
    ''|.*|*/*) return 1 ;;
  esac
  case "$mode" in
    600|700) ;;
    *) return 1 ;;
  esac
  device=$(fm_ext_private_artifact_dir_prepare "$dir") || return 1
  dest="$dir/$base"
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-ext.XXXXXX" 2>/dev/null) || return 1
  if ! cat > "$tmp" \
    || ! chmod "$mode" "$tmp" 2>/dev/null \
    || ! fm_ext_single_link_file_mode_valid "$tmp" "$mode" "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fm_ext_single_link_file_mode_valid "$dest" "$mode" "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_ext_single_link_file_mode_valid "$dest" "$mode" "$device"; then
    rm -f -- "$dest"
    return 1
  fi
}

# Publish stdin as a new private artifact without replacing an existing path.
# Returns 0 when this caller created it, 1 when another valid private artifact
# already owns the path, and 2 on an unsafe path or publication failure.
fm_ext_private_artifact_publish_stdin_once() {
  local dir=$1 base=$2 mode=$3 device tmp dest
  case "$base" in
    ''|.*|*/*) return 2 ;;
  esac
  case "$mode" in
    600|700) ;;
    *) return 2 ;;
  esac
  device=$(fm_ext_private_artifact_dir_prepare "$dir") || return 2
  dest="$dir/$base"
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-ext.XXXXXX" 2>/dev/null) || return 2
  if ! cat > "$tmp" \
    || ! chmod "$mode" "$tmp" 2>/dev/null \
    || ! fm_ext_single_link_file_mode_valid "$tmp" "$mode" "$device"; then
    rm -f -- "$tmp"
    return 2
  fi
  if ln -- "$tmp" "$dest" 2>/dev/null; then
    rm -f -- "$tmp"
    if fm_ext_single_link_file_mode_valid "$dest" "$mode" "$device"; then
      return 0
    fi
    rm -f -- "$dest"
    return 2
  fi
  rm -f -- "$tmp"
  if fm_ext_single_link_file_mode_valid "$dest" "$mode" "$device"; then
    return 1
  fi
  return 2
}

fm_ext_private_artifact_file_valid() {
  local dir=$1 base=$2 mode=$3 device
  case "$base" in
    ''|.*|*/*) return 1 ;;
  esac
  case "$mode" in
    600|700) ;;
    *) return 1 ;;
  esac
  device=$(fm_ext_private_artifact_dir_device "$dir") || return 1
  fm_ext_single_link_file_mode_valid "$dir/$base" "$mode" "$device"
}

# Remove a previously published private artifact. Returns 0 when the path is
# absent or this caller deleted a valid artifact, and 1 when the path exists
# but is not a safe private artifact or deletion failed.
fm_ext_private_artifact_remove() {
  local dir=$1 base=$2 mode=$3 dest
  case "$base" in
    ''|.*|*/*) return 1 ;;
  esac
  dest="$dir/$base"
  if ! fm_ext_private_artifact_file_valid "$dir" "$base" "$mode"; then
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      return 1
    fi
    return 0
  fi
  rm -f -- "$dest" || return 1
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    return 1
  fi
  return 0
}

# --- identifiers ------------------------------------------------------------

fm_ext_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# fm_ext_request_slug <canonical-request-id>: SHA-256 hex of the canonical id.
# The canonical id keeps colons; the slug is the only filename component.
fm_ext_request_slug() {
  local rid=$1 slug
  [ -n "$rid" ] || return 1
  slug=$(printf '%s' "$rid" | fm_ext_sha256) || return 1
  case "$slug" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#slug}" -eq 64 ] || return 1
  printf '%s\n' "$slug"
}

# Canonical Communication Officer request id: discord:<guild>:<channel>:<thread>:<message>
# All four ids are non-empty decimal snowflakes. Thread may equal channel when
# the source message is not in a thread.
fm_ext_request_id_valid() {
  local rid=$1 rest guild channel thread message
  case "$rid" in
    discord:*) ;;
    *) return 1 ;;
  esac
  rest=${rid#discord:}
  guild=${rest%%:*}
  rest=${rest#"$guild"}
  rest=${rest#:}
  [ -n "$guild" ] && [ -n "$rest" ] || return 1
  channel=${rest%%:*}
  rest=${rest#"$channel"}
  rest=${rest#:}
  [ -n "$channel" ] && [ -n "$rest" ] || return 1
  thread=${rest%%:*}
  message=${rest#"$thread"}
  message=${message#:}
  [ -n "$thread" ] && [ -n "$message" ] || return 1
  case "$message" in
    *:*) return 1 ;;
  esac
  case "$guild$channel$thread$message" in
    *[!0-9]*) return 1 ;;
  esac
}

fm_ext_slug_valid() {
  local v=$1
  case "$v" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#v}" -eq 64 ]
}

fm_ext_kind_valid() {
  case "$1" in
    ack|answer|followup|final) return 0 ;;
    *) return 1 ;;
  esac
}

fm_ext_generation_valid() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ]
}

# --- layout -----------------------------------------------------------------

fm_ext_config_dir() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-${1:-${FM_HOME:?FM_HOME is required}}/config}"
}

fm_ext_state_dir() {
  printf '%s\n' "${FM_STATE_OVERRIDE:-${1:-${FM_HOME:?FM_HOME is required}}/state}"
}

fm_ext_secret_path() {
  local config
  config=$(fm_ext_config_dir "${1:-}")
  printf '%s\n' "${FM_EXT_SECRET_FILE:-$config/$FM_EXT_SECRET_BASENAME}"
}

fm_ext_allowlist_path() {
  local config
  config=$(fm_ext_config_dir "${1:-}")
  printf '%s\n' "${FM_EXT_ALLOWLIST_FILE:-$config/$FM_EXT_ALLOWLIST_BASENAME}"
}

fm_ext_bridge_path() {
  local config
  config=$(fm_ext_config_dir "${1:-}")
  printf '%s\n' "$config/$FM_EXT_BRIDGE_BASENAME"
}

fm_ext_inbox_dir()  { printf '%s\n' "$(fm_ext_state_dir "${1:-}")/$FM_EXT_INBOX_DIRNAME"; }
fm_ext_context_dir(){ printf '%s\n' "$(fm_ext_state_dir "${1:-}")/$FM_EXT_CONTEXT_DIRNAME"; }
fm_ext_outbox_dir() { printf '%s\n' "$(fm_ext_state_dir "${1:-}")/$FM_EXT_OUTBOX_DIRNAME"; }
fm_ext_watch_shim_path() { printf '%s\n' "$(fm_ext_state_dir "${1:-}")/$FM_EXT_WATCH_SHIM"; }

# --- activation and secret --------------------------------------------------

# fm_ext_bridge_opted_in [home]: config/ext-bridge presence or FM_EXT_BRIDGE=1.
# Environment wins when set: a non-empty truthy FM_EXT_BRIDGE opts in, and an
# explicit empty/0/false/no/off value opts out even if the file exists.
fm_ext_bridge_opted_in() {
  local home=${1:-${FM_HOME:?}} flag file
  if [ -n "${FM_EXT_BRIDGE+x}" ]; then
    flag=$(printf '%s' "${FM_EXT_BRIDGE-}" | tr '[:upper:]' '[:lower:]')
    case "$flag" in
      ''|0|false|no|off) return 1 ;;
      *) return 0 ;;
    esac
  fi
  file=$(fm_ext_bridge_path "$home")
  [ -f "$file" ] && [ ! -L "$file" ]
}

# fm_ext_secret_valid <path>: regular file, mode 0600, non-empty, no symlink.
fm_ext_secret_valid() {
  local file=$1 mode
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ -s "$file" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$file" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$file" 2>/dev/null) || return 1
  fi
  [ "$mode" = 600 ]
}

# fm_ext_secret_matches <home-secret> <presented-secret>: byte-identical secrets.
fm_ext_secret_matches() {
  local home_secret=$1 presented=$2
  fm_ext_secret_valid "$home_secret" || return 1
  fm_ext_secret_valid "$presented" || return 1
  cmp -s "$home_secret" "$presented"
}

# fm_ext_active [home]: opted in AND a valid local secret file exists.
fm_ext_active() {
  local home=${1:-${FM_HOME:?}} secret
  fm_ext_bridge_opted_in "$home" || return 1
  secret=$(fm_ext_secret_path "$home")
  fm_ext_secret_valid "$secret"
}

# --- allowlist --------------------------------------------------------------

# Allowlist file: comments (#) and blank lines ignored. Each rule is one of:
#   <guild>
#   <guild>:<channel>
#   <guild>:<channel>:<author>
# A request is allowed when any rule matches every specified component.
# Missing, empty, unreadable, or symlink allowlist denies every request.
fm_ext_allowlist_read() {
  local file=$1 line
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%"${line##*[![:space:]]}"}
    line=${line#"${line%%[![:space:]]*}"}
    case "$line" in
      ''|\#*) continue ;;
    esac
    printf '%s\n' "$line"
  done < "$file"
}

fm_ext_allowlisted() {
  local file=$1 guild=$2 channel=$3 author=$4 rule rguild rchannel rauthor rest
  [ -n "$guild" ] && [ -n "$channel" ] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r rule || [ -n "$rule" ]; do
    [ -n "$rule" ] || continue
    rguild=${rule%%:*}
    rest=${rule#"$rguild"}
    rest=${rest#:}
    if [ -z "$rest" ] || [ "$rest" = "$rule" ]; then
      [ "$rguild" = "$guild" ] && return 0
      continue
    fi
    rchannel=${rest%%:*}
    rauthor=${rest#"$rchannel"}
    rauthor=${rauthor#:}
    [ "$rguild" = "$guild" ] || continue
    [ "$rchannel" = "$channel" ] || continue
    if [ -z "$rauthor" ] || [ "$rauthor" = "$rest" ]; then
      return 0
    fi
    [ "$rauthor" = "$author" ] && return 0
  done <<EOF
$(fm_ext_allowlist_read "$file")
EOF
  return 1
}

# --- offer / context --------------------------------------------------------

fm_ext_offer_registry_claim() {
  local state=$1 slug=$2 rid=$3 now record rc
  fm_ext_slug_valid "$slug" || return 2
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 2 ;;
  esac
  record=$(jq -cn --arg rid "$rid" --arg slug "$slug" --argjson recorded_at "$now" \
    '{request_id:$rid, slug:$slug, recorded_at:$recorded_at}') || return 2
  printf '%s\n' "$record" \
    | fm_ext_private_artifact_publish_stdin_once "$state/$FM_EXT_CONTEXT_DIRNAME" "$slug.offered.json" 600
  rc=$?
  return "$rc"
}

# Drop a claimed offer so a later intake or poll can retry the wake.
# Returns 0 when the marker is absent or was a valid private artifact that this
# caller deleted, and 1 when the path is unsafe or deletion failed.
fm_ext_offer_registry_unclaim() {
  local state=$1 slug=$2
  fm_ext_slug_valid "$slug" || return 1
  fm_ext_private_artifact_remove "$state/$FM_EXT_CONTEXT_DIRNAME" "$slug.offered.json" 600
}

# --- outbox schema ----------------------------------------------------------

fm_ext_outbox_basename() {
  local slug=$1 kind=$2 generation=$3
  fm_ext_slug_valid "$slug" || return 1
  fm_ext_kind_valid "$kind" || return 1
  fm_ext_generation_valid "$generation" || return 1
  printf '%s.%s.%s.json\n' "$slug" "$kind" "$generation"
}

fm_ext_outbox_posting_basename() {
  local slug=$1 kind=$2 generation=$3
  fm_ext_slug_valid "$slug" || return 1
  fm_ext_kind_valid "$kind" || return 1
  fm_ext_generation_valid "$generation" || return 1
  printf '%s.%s.%s.posting\n' "$slug" "$kind" "$generation"
}

fm_ext_outbox_receipt_basename() {
  local slug=$1 kind=$2 generation=$3
  fm_ext_slug_valid "$slug" || return 1
  fm_ext_kind_valid "$kind" || return 1
  fm_ext_generation_valid "$generation" || return 1
  printf '%s.%s.%s.receipt.json\n' "$slug" "$kind" "$generation"
}

fm_ext_outbox_failed_basename() {
  local slug=$1 kind=$2 generation=$3
  fm_ext_slug_valid "$slug" || return 1
  fm_ext_kind_valid "$kind" || return 1
  fm_ext_generation_valid "$generation" || return 1
  printf '%s.%s.%s.failed.json\n' "$slug" "$kind" "$generation"
}

# fm_ext_outbox_schema_valid <file>: payload has required fields and matching slug.
fm_ext_outbox_schema_valid() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  jq -e --argjson schema "$FM_EXT_SCHEMA_VERSION" '
    .schema_version == $schema
    and (.request_id | type == "string" and startswith("discord:"))
    and (.slug | type == "string" and test("^[0-9a-f]{64}$"))
    and (.kind | . == "ack" or . == "answer" or . == "followup" or . == "final")
    and (.generation | type == "number" and . >= 1)
    and (.platform == "discord")
    and (.source == "hermes-gateway")
    and (.guild_id | type == "string" and test("^[0-9]+$"))
    and (.channel_id | type == "string" and test("^[0-9]+$"))
    and (.thread_id | type == "string" and test("^[0-9]+$"))
    and (.message_id | type == "string" and test("^[0-9]+$"))
    and (.text | type == "string")
  ' "$file" >/dev/null 2>&1
}

# Begin delivery: CAS the posting marker. Returns 0 on claim, 1 when a valid
# receipt already exists (idempotent success), 4 when a terminal failed marker
# exists, 3 when a posting marker exists without a receipt (mid-send refuse),
# 2 on validation/publication failure.
fm_ext_outbox_begin() {
  local dir=$1 slug=$2 kind=$3 generation=$4 payload posting receipt failed now rc
  payload=$(fm_ext_outbox_basename "$slug" "$kind" "$generation") || return 2
  posting=$(fm_ext_outbox_posting_basename "$slug" "$kind" "$generation") || return 2
  receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || return 2
  failed=$(fm_ext_outbox_failed_basename "$slug" "$kind" "$generation") || return 2
  fm_ext_private_artifact_file_valid "$dir" "$payload" 600 || return 2
  if fm_ext_private_artifact_file_valid "$dir" "$receipt" 600; then
    return 1
  fi
  if fm_ext_private_artifact_file_valid "$dir" "$failed" 600; then
    return 4
  fi
  if fm_ext_private_artifact_file_valid "$dir" "$posting" 600; then
    return 3
  fi
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 2 ;;
  esac
  jq -cn --arg slug "$slug" --arg kind "$kind" --argjson generation "$generation" \
    --argjson recorded_at "$now" \
    '{slug:$slug, kind:$kind, generation:$generation, recorded_at:$recorded_at}' \
    | fm_ext_private_artifact_publish_stdin_once "$dir" "$posting" 600
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      if fm_ext_private_artifact_file_valid "$dir" "$receipt" 600; then
        return 1
      fi
      if fm_ext_private_artifact_file_valid "$dir" "$failed" 600; then
        return 4
      fi
      return 3
      ;;
    *) return 2 ;;
  esac
}

# Record a delivery receipt once. Returns 0 on create, 1 when a valid receipt
# already exists, 2 on failure. The posting marker is left in place so a
# later begin still sees mid-delivery-or-receipt and refuses a second send.
fm_ext_outbox_receipt() {
  local dir=$1 slug=$2 kind=$3 generation=$4 receipt_json=$5 receipt rc
  receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || return 2
  [ -n "$receipt_json" ] || return 2
  printf '%s\n' "$receipt_json" \
    | fm_ext_private_artifact_publish_stdin_once "$dir" "$receipt" 600
  rc=$?
  return "$rc"
}

# Drop the posting marker after a transient definite send failure (HTTP 429
# or 5xx) that happened before a successful response. Returns 0 when the
# generation is retryable (no marker, or this caller deleted a valid posting
# marker), 1 when a receipt or terminal failed marker already exists (do not
# reopen), and 2 on validation or deletion failure. An ambiguous crash or
# transport error after the post started keeps the marker; this helper is
# only for the transient definite-failure path.
fm_ext_outbox_abort() {
  local dir=$1 slug=$2 kind=$3 generation=$4 posting receipt failed
  posting=$(fm_ext_outbox_posting_basename "$slug" "$kind" "$generation") || return 2
  receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || return 2
  failed=$(fm_ext_outbox_failed_basename "$slug" "$kind" "$generation") || return 2
  if fm_ext_private_artifact_file_valid "$dir" "$receipt" 600; then
    return 1
  fi
  if fm_ext_private_artifact_file_valid "$dir" "$failed" 600; then
    return 1
  fi
  fm_ext_private_artifact_remove "$dir" "$posting" 600 || return 2
  return 0
}

# Record a terminal delivery failure so pending will not retry this generation.
# Returns 0 on create, 1 when a valid receipt already exists (do not reopen),
# 4 when a valid failed marker already exists (idempotent), and 2 on failure.
# Removes the posting marker after a successful failed publication so a later
# begin sees terminal-failed rather than mid-delivery.
fm_ext_outbox_fail() {
  local dir=$1 slug=$2 kind=$3 generation=$4 reason_json=$5 failed posting receipt rc
  failed=$(fm_ext_outbox_failed_basename "$slug" "$kind" "$generation") || return 2
  posting=$(fm_ext_outbox_posting_basename "$slug" "$kind" "$generation") || return 2
  receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || return 2
  [ -n "$reason_json" ] || return 2
  if fm_ext_private_artifact_file_valid "$dir" "$receipt" 600; then
    return 1
  fi
  if fm_ext_private_artifact_file_valid "$dir" "$failed" 600; then
    fm_ext_private_artifact_remove "$dir" "$posting" 600 || true
    return 4
  fi
  printf '%s\n' "$reason_json" \
    | fm_ext_private_artifact_publish_stdin_once "$dir" "$failed" 600
  rc=$?
  case "$rc" in
    0)
      fm_ext_private_artifact_remove "$dir" "$posting" 600 || true
      return 0
      ;;
    1)
      if fm_ext_private_artifact_file_valid "$dir" "$receipt" 600; then
        return 1
      fi
      fm_ext_private_artifact_remove "$dir" "$posting" 600 || true
      return 4
      ;;
    *) return 2 ;;
  esac
}

# --- poll shim --------------------------------------------------------------

fm_ext_poll_shim_content() {
  local home=$1 root=$2
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-bootstrap.sh - local ext-bridge poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted poll script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$root/bin/fm-ext-poll.sh")"
}

fm_ext_poll_shim_valid() {
  local file=$1 home=$2 root=$3
  fm_ext_single_link_file_mode_valid "$file" 700 || return 1
  cmp -s "$file" <(fm_ext_poll_shim_content "$home" "$root")
}

# --- task meta link (not x_request=) ----------------------------------------

fm_ext_meta_get() {
  local meta=$1 key=$2 line
  [ -f "$meta" ] || return 0
  line=$(grep -E "^${key}=" "$meta" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  printf '%s' "${line#*=}"
}

fm_ext_meta_tmp() {
  local meta=$1 dir base
  dir=${meta%/*}
  base=${meta##*/}
  [ "$dir" != "$meta" ] || dir=.
  [ -d "$dir" ] || return 1
  mktemp "$dir/.${base}.fm-ext.XXXXXX"
}

# fm_ext_meta_link_set <meta> <request_id> <slug> <epoch> [followups]
fm_ext_meta_link_set() {
  local meta=$1 rid=$2 slug=$3 ts=$4 followups=${5:-0} tmp
  [ -f "$meta" ] || return 1
  tmp=$(fm_ext_meta_tmp "$meta") || return 1
  if ! { grep -vE '^ext_request=|^ext_request_slug=|^ext_request_ts=|^ext_followups=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  printf 'ext_request=%s\n' "$rid" >> "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'ext_request_slug=%s\n' "$slug" >> "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'ext_request_ts=%s\n' "$ts" >> "$tmp" || { rm -f "$tmp"; return 1; }
  printf 'ext_followups=%s\n' "$followups" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

fm_ext_meta_followups_set() {
  local meta=$1 n=$2 tmp
  [ -f "$meta" ] || return 1
  tmp=$(fm_ext_meta_tmp "$meta") || return 1
  if ! { grep -vE '^ext_followups=' "$meta" || true; } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  printf 'ext_followups=%s\n' "$n" >> "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$meta" || { rm -f "$tmp"; return 1; }
}

# Silence unused-dir lint when this file is sourced for helpers only.
: "$_FM_EXT_LIB_DIR"
