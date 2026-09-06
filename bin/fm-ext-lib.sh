# shellcheck shell=bash
# Shared helpers for the sibling local-bridge Communication Officer
# (fm-ext-intake.sh, fm-ext-emit.sh, fm-ext-link.sh, fm-ext-poll.sh).
#
# This file is sourced, never executed. It copies the private-artifact
# publication pattern used by X mode without sourcing bin/fm-x-lib.sh and
# without touching the hosted relay, FMX_PAIRING_TOKEN, myfirstmate.io, or
# pending-reply.
#
# Opt-in is config/ext-bridge presence plus a local mode-0600 secret file.
# The presence file is the only way to turn the bridge on, so no caller's
# environment can activate a home that never opted in. There is no hosted
# pairing token.
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

# fm_ext_bridge_opted_in [home]: config/ext-bridge presence.
# The presence file is the single activation authority, so the bootstrap, the
# watcher, the poll, the intake, and the gateway plugin all reach the same
# verdict in one home. FM_EXT_BRIDGE may only turn a configured bridge OFF
# (empty/0/false/no/off); it can never turn one on. A caller that could set
# the environment could otherwise activate the intake half of a home whose
# supervision half still believed the bridge was off.
fm_ext_bridge_opted_in() {
  local home=${1:-${FM_HOME:?}} flag file
  if [ -n "${FM_EXT_BRIDGE+x}" ]; then
    flag=$(printf '%s' "${FM_EXT_BRIDGE-}" | tr '[:upper:]' '[:lower:]')
    case "$flag" in
      ''|0|false|no|off) return 1 ;;
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

# --- allowlist and authority ------------------------------------------------

# Allowlist file: comments (#) and blank lines ignored. Each rule is one of:
#   <guild>                      admits the request at "confirm" authority
#   <guild>:<channel>            admits the request at "confirm" authority
#   <guild>:<channel>:<author>   grants standing captain-level authority
#
# Least privilege: only the finest-grained three-component rule grants standing
# authority. A guild-only or channel-only rule admits the request but leaves
# every project-changing action from it needing captain confirmation first, so
# no guild-wide standing grant exists at any setting.
#
# A rule is well formed only with one, two, or three non-empty colon-separated
# components. Every other shape - a trailing or embedded empty component, or a
# fourth component - is malformed and is ignored rather than guessed at, so a
# typo can never widen a grant.
#
# Missing, empty, comments-only, unreadable, or symlink allowlist denies every
# request. This file is the single owner of the decision: the gateway plugin
# resolves through it instead of reimplementing the grammar.
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

# fm_ext_rule_authority <rule> <guild> <channel> <author>: print the authority
# one allowlist rule grants this request ("standing" or "confirm"). Returns 1
# when the rule is malformed or does not match.
fm_ext_rule_authority() {
  local rule=$1 guild=$2 channel=$3 author=$4 rest rguild rchannel rauthor
  case "$rule" in
    *:*:*:*) return 1 ;;
  esac
  rguild=${rule%%:*}
  [ -n "$rguild" ] || return 1
  case "$rule" in
    *:*)
      rest=${rule#*:}
      rchannel=${rest%%:*}
      [ -n "$rchannel" ] || return 1
      case "$rest" in
        *:*)
          rauthor=${rest#*:}
          [ -n "$rauthor" ] || return 1
          [ "$rguild" = "$guild" ] || return 1
          [ "$rchannel" = "$channel" ] || return 1
          [ "$rauthor" = "$author" ] || return 1
          printf 'standing\n'
          return 0
          ;;
      esac
      [ "$rguild" = "$guild" ] || return 1
      [ "$rchannel" = "$channel" ] || return 1
      printf 'confirm\n'
      return 0
      ;;
  esac
  [ "$rguild" = "$guild" ] || return 1
  printf 'confirm\n'
}

# fm_ext_authority <allowlist> <guild> <channel> <author>: print the highest
# authority this allowlist grants the request ("standing" or "confirm"), or
# return 1 when nothing matches. Standing beats confirm, so an author-scoped
# rule still grants standing authority alongside a broader admitting rule.
fm_ext_authority() {
  local file=$1 guild=$2 channel=$3 author=$4 rule granted best=
  [ -n "$guild" ] && [ -n "$channel" ] || return 1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r rule || [ -n "$rule" ]; do
    [ -n "$rule" ] || continue
    granted=$(fm_ext_rule_authority "$rule" "$guild" "$channel" "$author") || continue
    case "$granted" in
      standing) printf 'standing\n'; return 0 ;;
      confirm) best=confirm ;;
    esac
  done <<EOF
$(fm_ext_allowlist_read "$file")
EOF
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# fm_ext_allowlisted <allowlist> <guild> <channel> <author>: true when the
# request is admitted at any authority. The authority level itself comes from
# fm_ext_authority; admission alone never implies standing authority.
fm_ext_allowlisted() {
  fm_ext_authority "$@" >/dev/null
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

fm_ext_outbox_progress_basename() {
  local slug=$1 kind=$2 generation=$3
  fm_ext_slug_valid "$slug" || return 1
  fm_ext_kind_valid "$kind" || return 1
  fm_ext_generation_valid "$generation" || return 1
  printf '%s.%s.%s.progress.json\n' "$slug" "$kind" "$generation"
}

# Exclusive send claim. Not a .json basename so pending's payload glob skips it.
fm_ext_outbox_inflight_basename() {
  local slug=$1 kind=$2 generation=$3
  fm_ext_slug_valid "$slug" || return 1
  fm_ext_kind_valid "$kind" || return 1
  fm_ext_generation_valid "$generation" || return 1
  printf '%s.%s.%s.inflight\n' "$slug" "$kind" "$generation"
}

# Momentary directory used only to serialize a stale-claim steal. Not a
# payload, and pending's *.json glob skips it.
fm_ext_outbox_inflight_steallock_basename() {
  local slug=$1 kind=$2 generation=$3
  fm_ext_slug_valid "$slug" || return 1
  fm_ext_kind_valid "$kind" || return 1
  fm_ext_generation_valid "$generation" || return 1
  printf '%s.%s.%s.inflight.lock\n' "$slug" "$kind" "$generation"
}

# Conservative short TTL before a dead-owner inflight claim may be stolen.
# Default 30 seconds (above the 15s Discord send timeout). Non-numeric values
# reset to 30. Zero is allowed so tests can expire immediately while live
# owners still refuse steal.
fm_ext_inflight_ttl_secs() {
  local raw=${1:-${FM_EXT_INFLIGHT_TTL_SECS-}}
  case "$raw" in
    ''|*[!0-9]*) raw=30 ;;
  esac
  printf '%s\n' "$raw"
}

# Absolute age after which a generation stuck mid-chunk is force-recovered.
# The ambiguous-failure path deliberately keeps the in-flight chunk recorded so
# no chunk is double-posted, but on its own nothing ever clears it: one network
# timeout would wedge that reply forever. The default sits far above the
# 15-second Discord send timeout, so a genuinely live send is never recovered
# out from under its sender.
fm_ext_middelivery_recovery_secs() {
  local raw=${1:-${FM_EXT_MIDDELIVERY_RECOVERY_SECS-}}
  case "$raw" in
    ''|*[!0-9]*) raw=300 ;;
  esac
  printf '%s\n' "$raw"
}

# How many times one generation may be force-recovered before it is failed
# terminally. Each recovery re-sends the ambiguous chunk, which may duplicate a
# single Discord message; a bounded number of duplicates beats silent
# truncation, and an unbounded number would be its own defect.
fm_ext_middelivery_recovery_max() {
  local raw=${1:-${FM_EXT_MIDDELIVERY_RECOVERY_MAX-}}
  case "$raw" in
    ''|*[!0-9]*) raw=3 ;;
  esac
  printf '%s\n' "$raw"
}

# Owner pid recorded in the inflight claim. The begin CLI is ephemeral, so
# the default is PPID (the poster that will send). Override with
# FM_EXT_INFLIGHT_OWNER_PID. Falls back to $$ when PPID is unusable.
fm_ext_outbox_inflight_owner_pid() {
  local owner=${FM_EXT_INFLIGHT_OWNER_PID:-${PPID:-}}
  case "$owner" in
    ''|*[!0-9]*|0) owner=$$ ;;
  esac
  printf '%s\n' "$owner"
}

fm_ext_pid_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

fm_ext_file_mtime() {
  local file=$1
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$file" 2>/dev/null
  else
    stat -c %Y "$file" 2>/dev/null
  fi
}

# True when an existing inflight file may be stolen: age >= TTL and the
# recorded owner pid is dead and is not this claiming process. Live owners
# never steal, even past TTL. Missing pid is fail-closed (not stealable).
fm_ext_outbox_inflight_is_stale() {
  local dir=$1 base=$2 dest ttl now pid recorded_at age owner
  dest="$dir/$base"
  fm_ext_private_artifact_file_valid "$dir" "$base" 600 || return 1
  ttl=$(fm_ext_inflight_ttl_secs)
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pid=$(jq -er '.pid | select(type=="number")' "$dest" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  owner=$(fm_ext_outbox_inflight_owner_pid)
  if [ "$pid" = "$$" ] || [ "$pid" = "$owner" ]; then
    return 1
  fi
  if fm_ext_pid_alive "$pid"; then
    return 1
  fi
  recorded_at=$(jq -er '.recorded_at | select(type=="number")' "$dest" 2>/dev/null) || recorded_at=
  case "$recorded_at" in
    ''|*[!0-9]*)
      recorded_at=$(fm_ext_file_mtime "$dest") || return 1
      case "$recorded_at" in
        ''|*[!0-9]*) return 1 ;;
      esac
      ;;
  esac
  age=$((now - recorded_at))
  [ "$age" -ge 0 ] 2>/dev/null || return 1
  [ "$age" -ge "$ttl" ]
}

# Reclaim a leftover steal-lock directory whose mtime is at least
# max(claim TTL, 1) seconds. A zero claim TTL must not make a live
# steal-lock immediately reclaimable: two concurrent stealers would
# otherwise rmdir each other's lock and both return a send right.
fm_ext_inflight_steallock_ttl_secs() {
  local ttl
  ttl=$(fm_ext_inflight_ttl_secs)
  if [ "$ttl" -lt 1 ]; then
    ttl=1
  fi
  printf '%s\n' "$ttl"
}

fm_ext_outbox_inflight_steallock_drop() {
  local dir=$1 slug=$2 kind=$3 generation=$4 lock
  lock=$(fm_ext_outbox_inflight_steallock_basename "$slug" "$kind" "$generation") || return 0
  rmdir "$dir/$lock" 2>/dev/null || true
}

fm_ext_outbox_inflight_steallock_stale() {
  local dir=$1 base=$2 dest ttl now mtime age
  dest="$dir/$base"
  [ -d "$dest" ] && [ ! -L "$dest" ] || return 1
  ttl=$(fm_ext_inflight_steallock_ttl_secs)
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  mtime=$(fm_ext_file_mtime "$dest") || return 1
  case "$mtime" in
    ''|*[!0-9]*) return 1 ;;
  esac
  age=$((now - mtime))
  [ "$age" -ge 0 ] 2>/dev/null || return 1
  [ "$age" -ge "$ttl" ]
}

fm_ext_outbox_inflight_publish_once() {
  local dir=$1 slug=$2 kind=$3 generation=$4 inflight now owner
  inflight=$(fm_ext_outbox_inflight_basename "$slug" "$kind" "$generation") || return 2
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 2 ;;
  esac
  owner=$(fm_ext_outbox_inflight_owner_pid)
  case "$owner" in
    ''|*[!0-9]*) return 2 ;;
  esac
  jq -cn --arg slug "$slug" --arg kind "$kind" --argjson generation "$generation" \
    --argjson recorded_at "$now" --argjson pid "$owner" \
    '{slug:$slug, kind:$kind, generation:$generation, recorded_at:$recorded_at, pid:$pid}' \
    | fm_ext_private_artifact_publish_stdin_once "$dir" "$inflight" 600
}

# CAS-claim the exclusive send marker. Returns 0 when this caller owns the
# next send, 1 when another valid inflight marker already holds it (live
# owner, or dead owner still inside the TTL), and 2 on validation or
# publication failure. A dead owner whose claim is at least
# FM_EXT_INFLIGHT_TTL_SECS (default 30) old may be stolen: the steal is
# serialized with a momentary lock directory whose reclaim floor is
# max(TTL, 1) so TTL=0 cannot reopen dual claim.
fm_ext_outbox_inflight_claim() {
  local dir=$1 slug=$2 kind=$3 generation=$4 inflight lock rc
  inflight=$(fm_ext_outbox_inflight_basename "$slug" "$kind" "$generation") || return 2
  lock=$(fm_ext_outbox_inflight_steallock_basename "$slug" "$kind" "$generation") || return 2
  fm_ext_outbox_inflight_publish_once "$dir" "$slug" "$kind" "$generation"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    1) ;;
    *) return 2 ;;
  esac
  if ! fm_ext_outbox_inflight_is_stale "$dir" "$inflight"; then
    return 1
  fi
  if ! mkdir "$dir/$lock" 2>/dev/null; then
    if fm_ext_outbox_inflight_steallock_stale "$dir" "$lock"; then
      rmdir "$dir/$lock" 2>/dev/null || return 1
      mkdir "$dir/$lock" 2>/dev/null || return 1
    else
      return 1
    fi
  fi
  if ! fm_ext_private_artifact_file_valid "$dir" "$inflight" 600; then
    fm_ext_outbox_inflight_publish_once "$dir" "$slug" "$kind" "$generation"
    rc=$?
    rmdir "$dir/$lock" 2>/dev/null || true
    case "$rc" in
      0) return 0 ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
  fi
  if ! fm_ext_outbox_inflight_is_stale "$dir" "$inflight"; then
    rmdir "$dir/$lock" 2>/dev/null || true
    return 1
  fi
  if ! fm_ext_private_artifact_remove "$dir" "$inflight" 600; then
    rmdir "$dir/$lock" 2>/dev/null || true
    return 2
  fi
  fm_ext_outbox_inflight_publish_once "$dir" "$slug" "$kind" "$generation"
  rc=$?
  rmdir "$dir/$lock" 2>/dev/null || true
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# Drop the exclusive send marker. Returns 0 when the path is absent or this
# caller deleted a valid inflight marker, 1 when the path exists but is not
# a safe private artifact, and 2 on an unsafe identity. Also drops a leftover
# steal-lock directory.
fm_ext_outbox_inflight_release() {
  local dir=$1 slug=$2 kind=$3 generation=$4 inflight rc
  inflight=$(fm_ext_outbox_inflight_basename "$slug" "$kind" "$generation") || return 2
  fm_ext_private_artifact_remove "$dir" "$inflight" 600
  rc=$?
  fm_ext_outbox_inflight_steallock_drop "$dir" "$slug" "$kind" "$generation"
  return "$rc"
}

# fm_ext_outbox_stuck_age <dir> <slug> <kind> <generation>: print how long this
# generation has recorded an in-flight chunk in its JSON progress. The age comes
# from the exclusive inflight claim when that marker is present, and from the
# progress artifact's own mtime when the claim was released without the chunk
# ever being cleared. Returns 1 when the generation records no in-flight chunk
# or the age cannot be established.
fm_ext_outbox_stuck_age() {
  local dir=$1 slug=$2 kind=$3 generation=$4 progress inflight now recorded_at age
  progress=$(fm_ext_outbox_progress_basename "$slug" "$kind" "$generation") || return 1
  inflight=$(fm_ext_outbox_inflight_basename "$slug" "$kind" "$generation") || return 1
  fm_ext_private_artifact_file_valid "$dir" "$progress" 600 || return 1
  jq -e '.inflight | type == "number"' "$dir/$progress" >/dev/null 2>&1 || return 1
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  recorded_at=
  if fm_ext_private_artifact_file_valid "$dir" "$inflight" 600; then
    recorded_at=$(jq -er '.recorded_at | select(type=="number")' "$dir/$inflight" 2>/dev/null) \
      || recorded_at=
  fi
  if [ -z "$recorded_at" ]; then
    recorded_at=$(fm_ext_file_mtime "$dir/$progress") || return 1
  fi
  case "$recorded_at" in
    ''|*[!0-9]*) return 1 ;;
  esac
  age=$((now - recorded_at))
  [ "$age" -ge 0 ] 2>/dev/null || return 1
  printf '%s\n' "$age"
}

# fm_ext_outbox_stuck_recover <dir> <slug> <kind> <generation>: bounded recovery
# for a generation wedged by an ambiguous mid-chunk send failure. Once the
# generation has recorded the same in-flight chunk for longer than
# FM_EXT_MIDDELIVERY_RECOVERY_SECS, this clears that chunk so the next claim
# re-sends exactly it, and records the attempt in the progress artifact. After
# FM_EXT_MIDDELIVERY_RECOVERY_MAX attempts it writes the terminal failed marker
# instead, so the reply surfaces as a failure rather than retrying forever.
# Returns 0 when this call cleared the chunk, 5 when the budget is spent and the
# generation is now terminally failed, 1 when the generation is not stuck or is
# not yet eligible, and 2 on failure.
fm_ext_outbox_stuck_recover() {
  local dir=$1 slug=$2 kind=$3 generation=$4
  local progress age threshold attempts max now body reason rc
  progress=$(fm_ext_outbox_progress_basename "$slug" "$kind" "$generation") || return 2
  age=$(fm_ext_outbox_stuck_age "$dir" "$slug" "$kind" "$generation") || return 1
  threshold=$(fm_ext_middelivery_recovery_secs)
  [ "$age" -ge "$threshold" ] 2>/dev/null || return 1
  attempts=$(jq -r '.recovery_count // 0 | floor' "$dir/$progress" 2>/dev/null) || attempts=0
  case "$attempts" in
    ''|*[!0-9]*) attempts=0 ;;
  esac
  max=$(fm_ext_middelivery_recovery_max)
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 2 ;;
  esac
  if [ "$attempts" -ge "$max" ]; then
    reason=$(jq -cn --argjson attempts "$attempts" --argjson stuck_secs "$age" \
      --argjson recorded_at "$now" \
      '{ok:false, outcome:"mid-delivery-unrecoverable", recovery_attempts:$attempts,
        stuck_secs:$stuck_secs, recorded_at:$recorded_at,
        detail:"ambiguous mid-chunk send never resolved"}') || return 2
    fm_ext_outbox_fail "$dir" "$slug" "$kind" "$generation" "$reason"
    rc=$?
    case "$rc" in
      0|4) return 5 ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
  fi
  fm_ext_outbox_inflight_release "$dir" "$slug" "$kind" "$generation" || return 2
  body=$(jq -c --argjson attempts "$((attempts + 1))" --argjson recovered_at "$now" \
    '.inflight = null | .recovery_count = $attempts | .recovered_at = $recovered_at' \
    "$dir/$progress" 2>/dev/null) || return 2
  [ -n "$body" ] || return 2
  fm_ext_outbox_progress "$dir" "$slug" "$kind" "$generation" "$body" || return 2
  return 0
}

# Discord per-message split budget. Copies the FMX_DISCORD_REPLY_MAX_CHARS
# clamp (default 1900, min 50, values above 2000 reset to 1900) without
# reading X-mode env or requiring FMX_PAIRING_TOKEN.
fm_ext_discord_reply_max_chars() {
  local raw=${1:-${FM_EXT_DISCORD_REPLY_MAX_CHARS-}}
  case "$raw" in
    ''|*[!0-9]*) raw=1900 ;;
  esac
  [ "$raw" -ge 50 ] 2>/dev/null || raw=50
  [ "$raw" -le 2000 ] 2>/dev/null || raw=1900
  printf '%s\n' "$raw"
}

# Maximum messages in one auto-split Discord thread. Copies FMX_X_THREAD_MAX
# (default 25) without reading X-mode env.
fm_ext_discord_thread_max() {
  local raw=${1:-${FM_EXT_DISCORD_THREAD_MAX-}}
  case "$raw" in
    ''|*[!0-9]*) raw=25 ;;
  esac
  [ "$raw" -ge 1 ] 2>/dev/null || raw=25
  printf '%s\n' "$raw"
}

# Split a reply into a numbered thread of <=<max>-codepoint chunks.
# Copied from fmx_split_thread in bin/fm-x-lib.sh; do not source that file.
# Reads the reply text on stdin and prints a compact JSON array of chunks.
fm_ext_split_thread() {
  jq -Rsc --argjson limit "$1" --argjson cap "$2" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def fence_marker: test("^[[:space:]]*```");
    def fence_count: ((split("```") | length) - 1);
    def numbered($i; $n):
      "(\($i + 1)/\($n))" as $mark
      | if ((fence_count % 2) == 0) and (split("\n")[-1] | fence_marker)
        then . + "\n" + $mark
        else . + " " + $mark
        end;
    def hardsplit($b): . as $s | [range(0; ($s|length); $b) as $i | $s[$i:$i+$b]];
    def wordsplit($b):
      (gsub("[[:space:]]+"; " ") | trim) as $norm
      | if ($norm | length) == 0 then []
        else
          [ $norm | split(" ")[] | if (length > $b) then hardsplit($b)[] else . end ] as $words
          | (reduce $words[] as $w ({chunks: [], cur: ""};
              (if .cur == "" then $w else .cur + " " + $w end) as $cand
              | if ($cand | length) <= $b then .cur = $cand
                else .chunks += (if .cur == "" then [] else [.cur] end) | .cur = $w end
            )) as $st
          | $st.chunks + (if $st.cur != "" then [$st.cur] else [] end)
        end;
    def split_units:
      split("\n") as $lines
      | (reduce $lines[] as $line ({units: [], cur: "", fence: false};
          if .fence then
            .cur = (if .cur == "" then $line else .cur + "\n" + $line end)
            | if ($line | fence_marker) then .units += [.cur] | .cur = "" | .fence = false else . end
          elif ($line | fence_marker) then
            (if .cur != "" then .units += [.cur] | .cur = "" else . end)
            | .cur = $line
            | .fence = true
          elif ($line | test("^[[:space:]]*$")) then
            if .cur != "" then .units += [.cur] | .cur = "" else . end
          else
            ($line | trim) as $clean
            | .cur = (if .cur == "" then $clean else .cur + " " + $clean end)
          end
        )) as $st
      | ($st.units + (if $st.cur != "" then [$st.cur] else [] end))
      | map(select((trim | length) > 0));
    def pack_units($units; $b):
      (reduce $units[] as $u ({chunks: [], cur: ""};
        if ($u | length) > $b then
          (if .cur != "" then .chunks += [.cur] | .cur = "" else . end)
          | .chunks += ($u | wordsplit($b))
        else
          (if .cur == "" then $u else .cur + "\n\n" + $u end) as $cand
          | if ($cand | length) <= $b then .cur = $cand
            else .chunks += (if .cur == "" then [] else [.cur] end) | .cur = $u end
        end
      )) as $st
      | $st.chunks + (if $st.cur != "" then [$st.cur] else [] end);
    def split_thread($limit; $cap):
      trim as $norm
      | if ($norm | length) == 0 then []
        elif ($norm | length) <= $limit then [$norm]
        else
          ($cap | tostring | length) as $digits
          | (4 + 2 * $digits) as $suffixw
          | (if ($limit - $suffixw - 1) < 1 then 1 else ($limit - $suffixw - 1) end) as $budget
          | ($norm | split_units) as $units
          | pack_units($units; $budget) as $raw
          | (if ($raw | length) > $cap
              then ($raw[0:$cap] | (.[($cap - 1)] += "…"))
              else $raw end) as $kept
          | ($kept | length) as $n
          | [ range(0; $n) as $i | $kept[$i] | numbered($i; $n) ]
        end;
    split_thread($limit; $cap)
  '
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

# Begin delivery: CAS the posting marker, then CAS an exclusive inflight
# send marker before returning a send right. Returns 0 on a new claim, a
# resumable split this caller exclusively claimed, or a steal of a dead
# owner past FM_EXT_INFLIGHT_TTL_SECS, 1 when a valid receipt already
# exists (idempotent success), 4 when a terminal failed marker exists, 3
# when a posting marker exists without a receipt and this caller does not
# own the next send (live owner, or dead owner still inside the TTL), 2
# on validation/publication failure. JSON progress with inflight==null is
# not itself a shared claim. Returns 5 when the generation was stuck past the
# mid-delivery recovery budget and is now terminally failed.
fm_ext_outbox_begin() {
  local dir=$1 slug=$2 kind=$3 generation=$4 payload posting receipt failed progress now rc
  payload=$(fm_ext_outbox_basename "$slug" "$kind" "$generation") || return 2
  posting=$(fm_ext_outbox_posting_basename "$slug" "$kind" "$generation") || return 2
  receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || return 2
  failed=$(fm_ext_outbox_failed_basename "$slug" "$kind" "$generation") || return 2
  progress=$(fm_ext_outbox_progress_basename "$slug" "$kind" "$generation") || return 2
  # Terminal outcomes are answered before the payload is required. A delivered
  # or terminally failed generation has had its payload retired, and a second
  # begin for it must still report that idempotent outcome rather than a
  # validation failure.
  if fm_ext_private_artifact_file_valid "$dir" "$receipt" 600; then
    return 1
  fi
  if fm_ext_private_artifact_file_valid "$dir" "$failed" 600; then
    return 4
  fi
  fm_ext_private_artifact_file_valid "$dir" "$payload" 600 || return 2
  if fm_ext_private_artifact_file_valid "$dir" "$posting" 600; then
    # An ambiguous mid-chunk send leaves the chunk recorded in-flight and the
    # claim held, which is what stops a double post. Consult the bounded
    # recovery first so that state cannot outlive its usefulness: past the
    # recovery window it either reopens the chunk for one more attempt or
    # turns into a terminal failure, instead of refusing forever.
    fm_ext_outbox_stuck_recover "$dir" "$slug" "$kind" "$generation"
    rc=$?
    case "$rc" in
      5) return 5 ;;
      2) return 2 ;;
    esac
    if fm_ext_outbox_progress_resumable "$dir" "$slug" "$kind" "$generation"; then
      if jq -e '.posted_count >= .total' "$dir/$progress" >/dev/null 2>&1; then
        return 0
      fi
      fm_ext_outbox_inflight_claim "$dir" "$slug" "$kind" "$generation"
      rc=$?
      case "$rc" in
        0) return 0 ;;
        1) return 3 ;;
        *) return 2 ;;
      esac
    fi
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
    0)
      fm_ext_outbox_inflight_claim "$dir" "$slug" "$kind" "$generation"
      rc=$?
      case "$rc" in
        0) return 0 ;;
        1) return 3 ;;
        *) return 2 ;;
      esac
      ;;
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
# A leftover inflight send marker is released after a successful or already
# present receipt.
fm_ext_outbox_receipt() {
  local dir=$1 slug=$2 kind=$3 generation=$4 receipt_json=$5 receipt rc
  receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || return 2
  [ -n "$receipt_json" ] || return 2
  printf '%s\n' "$receipt_json" \
    | fm_ext_private_artifact_publish_stdin_once "$dir" "$receipt" 600
  rc=$?
  case "$rc" in
    0|1)
      fm_ext_outbox_inflight_release "$dir" "$slug" "$kind" "$generation" || true
      fm_ext_outbox_retire "$dir" "$slug" "$kind" "$generation" || true
      ;;
  esac
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
  local dir=$1 slug=$2 kind=$3 generation=$4 posting receipt failed progress
  posting=$(fm_ext_outbox_posting_basename "$slug" "$kind" "$generation") || return 2
  receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || return 2
  failed=$(fm_ext_outbox_failed_basename "$slug" "$kind" "$generation") || return 2
  progress=$(fm_ext_outbox_progress_basename "$slug" "$kind" "$generation") || return 2
  if fm_ext_private_artifact_file_valid "$dir" "$receipt" 600; then
    return 1
  fi
  if fm_ext_private_artifact_file_valid "$dir" "$failed" 600; then
    return 1
  fi
  # Release inflight first: abort is pre-success-only, so dropping the send
  # claim cannot reopen a confirmed post. A crash after posting/progress
  # removal must not leave a stale inflight that makes the next begin stick.
  fm_ext_outbox_inflight_release "$dir" "$slug" "$kind" "$generation" || return 2
  fm_ext_private_artifact_remove "$dir" "$posting" 600 || return 2
  fm_ext_private_artifact_remove "$dir" "$progress" 600 || return 2
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
    fm_ext_outbox_inflight_release "$dir" "$slug" "$kind" "$generation" || true
    fm_ext_outbox_retire "$dir" "$slug" "$kind" "$generation" || true
    return 4
  fi
  printf '%s\n' "$reason_json" \
    | fm_ext_private_artifact_publish_stdin_once "$dir" "$failed" 600
  rc=$?
  case "$rc" in
    0)
      fm_ext_private_artifact_remove "$dir" "$posting" 600 || true
      fm_ext_outbox_inflight_release "$dir" "$slug" "$kind" "$generation" || true
      fm_ext_outbox_retire "$dir" "$slug" "$kind" "$generation" || true
      return 0
      ;;
    1)
      if fm_ext_private_artifact_file_valid "$dir" "$receipt" 600; then
        fm_ext_outbox_inflight_release "$dir" "$slug" "$kind" "$generation" || true
        return 1
      fi
      fm_ext_private_artifact_remove "$dir" "$posting" 600 || true
      fm_ext_outbox_inflight_release "$dir" "$slug" "$kind" "$generation" || true
      fm_ext_outbox_retire "$dir" "$slug" "$kind" "$generation" || true
      return 4
      ;;
    *) return 2 ;;
  esac
}

# fm_ext_outbox_retire <dir> <slug> <kind> <generation>: drop the payload of a
# generation that has reached a terminal outcome, so `pending` scans only work
# that is genuinely still pending instead of every reply ever sent. The terminal
# marker itself stays in place, so a duplicate emit of the same generation is
# still recognized as already delivered until retention expires it. Returns 0
# when the generation is terminal and its payload is gone, 1 when it is not
# terminal, and 2 on an unsafe path or a removal failure.
fm_ext_outbox_retire() {
  local dir=$1 slug=$2 kind=$3 generation=$4 payload receipt failed
  payload=$(fm_ext_outbox_basename "$slug" "$kind" "$generation") || return 2
  receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || return 2
  failed=$(fm_ext_outbox_failed_basename "$slug" "$kind" "$generation") || return 2
  if ! fm_ext_private_artifact_file_valid "$dir" "$receipt" 600 \
    && ! fm_ext_private_artifact_file_valid "$dir" "$failed" 600; then
    return 1
  fi
  fm_ext_private_artifact_remove "$dir" "$payload" 600 || return 2
  return 0
}

# True when JSON progress looks resumable: progress exists, no chunk is
# recorded in-flight, and posted_count/total are numbers. Exclusive send
# ownership is the inflight file CAS in begin, not this JSON check.
fm_ext_outbox_progress_resumable() {
  local dir=$1 slug=$2 kind=$3 generation=$4 progress
  progress=$(fm_ext_outbox_progress_basename "$slug" "$kind" "$generation") || return 1
  fm_ext_private_artifact_file_valid "$dir" "$progress" 600 || return 1
  jq -e '.inflight == null
    and (.posted_count | type == "number")
    and (.total | type == "number")' "$dir/$progress" >/dev/null 2>&1
}

# Replace the chunk-progress artifact. Returns 0 on write, 2 on failure.
fm_ext_outbox_progress() {
  local dir=$1 slug=$2 kind=$3 generation=$4 progress_json=$5 progress
  progress=$(fm_ext_outbox_progress_basename "$slug" "$kind" "$generation") || return 2
  [ -n "$progress_json" ] || return 2
  printf '%s\n' "$progress_json" \
    | fm_ext_private_artifact_publish_stdin "$dir" "$progress" 600
}

# --- retention --------------------------------------------------------------

# Retention window for local bridge records, mirroring X mode's seven-day cap
# (FMX_FOLLOWUP_MAX_AGE_SECS). A larger request clamps back down to the cap, so
# the bridge cannot be configured to keep durable Discord records indefinitely.
fm_ext_retention_max_age_secs() {
  local raw=${1:-${FM_EXT_CONTEXT_MAX_AGE_SECS-}}
  case "$raw" in
    ''|*[!0-9]*) raw=604800 ;;
  esac
  [ "${#raw}" -le 18 ] || raw=604800
  [ "$raw" -le 604800 ] || raw=604800
  printf '%s\n' "$raw"
}

# fm_ext_context_prune <state>: drop destination-context and offer records past
# the retention window so state/ext-context stays bounded. Both record kinds are
# kept while their request is still sitting unhandled in the inbox: expiring the
# offer marker would re-offer queued work, and expiring the destination context
# would leave a request that can no longer be replied to. Follow-ups after the
# inbox is cleared are what the window itself bounds. Best effort: a record that
# cannot be read or removed is left alone rather than failing the caller.
fm_ext_context_prune() {
  local state=$1 dir inbox now max_age file base slug recorded_at age
  dir="$state/$FM_EXT_CONTEXT_DIRNAME"
  inbox="$state/$FM_EXT_INBOX_DIRNAME"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 0 ;;
  esac
  max_age=$(fm_ext_retention_max_age_secs)
  while IFS= read -r -d '' file; do
    base=${file##*/}
    case "$base" in
      *.offered.json) slug=${base%.offered.json} ;;
      *) slug=${base%.json} ;;
    esac
    if [ -e "$inbox/$slug.json" ]; then
      continue
    fi
    recorded_at=$(jq -er '.recorded_at | select(type=="number")' "$file" 2>/dev/null) \
      || recorded_at=
    if [ -z "$recorded_at" ]; then
      recorded_at=$(fm_ext_file_mtime "$file") || continue
    fi
    case "$recorded_at" in
      ''|*[!0-9]*) continue ;;
    esac
    age=$((now - recorded_at))
    [ "$age" -gt "$max_age" ] 2>/dev/null || continue
    rm -f -- "$file" 2>/dev/null || true
  done < <(find "$dir" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
  return 0
}

# fm_ext_outbox_prune <state>: drop the leftover markers of retired generations
# past the retention window so state/ext-outbox stays bounded too. A generation
# whose payload is still present is pending or mid-delivery and is never touched,
# so this can only ever remove the residue of work that already finished.
fm_ext_outbox_prune() {
  local state=$1 dir now max_age file base stem mtime age
  dir="$state/$FM_EXT_OUTBOX_DIRNAME"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 0 ;;
  esac
  max_age=$(fm_ext_retention_max_age_secs)
  while IFS= read -r -d '' file; do
    base=${file##*/}
    # Only marker suffixes are pruned. A payload is <stem>.json and falls
    # through to the default, so this can never delete undelivered work.
    case "$base" in
      *.receipt.json) stem=${base%.receipt.json} ;;
      *.failed.json) stem=${base%.failed.json} ;;
      *.progress.json) stem=${base%.progress.json} ;;
      *.posting) stem=${base%.posting} ;;
      *.inflight) stem=${base%.inflight} ;;
      *) continue ;;
    esac
    if [ -e "$dir/$stem.json" ]; then
      continue
    fi
    mtime=$(fm_ext_file_mtime "$file") || continue
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    age=$((now - mtime))
    [ "$age" -gt "$max_age" ] 2>/dev/null || continue
    rm -f -- "$file" 2>/dev/null || true
  done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null)
  return 0
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
