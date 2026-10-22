# shellcheck shell=bash
# Shared helpers for the sibling local-bridge Communication Officer
# (fm-ext-intake.sh, fm-ext-emit.sh, fm-ext-decision.sh, fm-ext-link.sh,
# fm-ext-poll.sh, fm-ext-media.sh, and the bridge parts of fm-bootstrap.sh,
# fm-watch.sh, and fm-wake-drain.sh).
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
FM_EXT_ATTACHMENTS_DIRNAME='ext-attachments'
FM_EXT_MEDIA_DIRNAME='ext-media'
# Outbound media (staged copies, screening attestations, sampled video frames,
# and files pulled from a remote second mate) is kept 14 days, counted from
# posting for a staged copy; see fm_ext_media_prune.
FM_EXT_MEDIA_RETENTION_SECS=1209600
# The only names a staged outbound file can carry; Discord sees these names,
# never a source path or filename.
FM_EXT_MEDIA_NAME_RE='^(image-[1-4]\.(png|jpg|gif|webp)|video-1\.(mp4|webm))$'
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

# fm_ext_private_request_dir_prepare <state> <dirname> <slug>: prepare the
# private per-request directory state/<dirname>/<slug> (mode 0700) and print
# its path. The slug is the only path component, so no caller input can
# escape the directory. Refuses symlinks and wrong modes like the file
# publisher above.
fm_ext_private_request_dir_prepare() {
  local state=$1 dirname=$2 slug=$3 dir device
  fm_ext_slug_valid "$slug" || return 1
  case "$dirname" in
    ''|.*|*/*) return 1 ;;
  esac
  dir="$state/$dirname/$slug"
  device=$(fm_ext_private_artifact_dir_prepare "$dir") || return 1
  printf '%s\n' "$dir"
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

fm_ext_reply_kind_valid() {
  case "$1" in
    ack|answer|followup|final) return 0 ;;
    *) return 1 ;;
  esac
}

fm_ext_kind_valid() {
  [ "$1" = waiting-pin ] || fm_ext_reply_kind_valid "$1"
}

fm_ext_waiting_pin_target() {
  local cfg line guild channel rest
  cfg="$(fm_ext_config_dir "${1:-$FM_HOME}")/ext-waiting-pin"
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
fm_ext_attachments_dir() { printf '%s\n' "$(fm_ext_state_dir "${1:-}")/$FM_EXT_ATTACHMENTS_DIRNAME"; }
fm_ext_media_dir() { printf '%s\n' "$(fm_ext_state_dir "${1:-}")/$FM_EXT_MEDIA_DIRNAME"; }
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

# --- decision buttons -------------------------------------------------------
#
# A decision post carries option buttons bound to one decision Firstmate
# already tracks. Its key is hold:<task-id> for a captain call held on the
# board, or key:<task-id>:<slug> for a worker's keyed status decision. Each
# button's Discord custom_id carries that key and a 1-based option id
# (fmd:<key>:<n>, or fmd:<key>:d for Discuss). The decision itself lives only
# in those ledgers, and only Firstmate records an answer there: a click files a
# request like a typed reply. The bridge keeps only what a post needs to be
# found and redrawn: decision options and structured question, explanation, and
# numbered-list sections in chunk progress, its sent click, outcome, and display.

# Most options one decision post carries: one Discord action row.
FM_EXT_DECISION_MAX_OPTIONS=5
# Longest option label, which is Discord's own button label limit.
FM_EXT_DECISION_LABEL_MAX=80
# Longest decision text a click carries as context, in characters.
# shellcheck disable=SC2034 # Read by the sourcing emit and intake scripts.
FM_EXT_DECISION_TEXT_MAX=1000
# Longest Discord component custom_id.
# shellcheck disable=SC2034 # Read by the sourcing emit script.
FM_EXT_DECISION_CUSTOM_ID_MAX=100
# The bin/fm-ext-emit.sh header owns the choice-shaped text detection rules.
FM_EXT_CHOICE_OPTION_RE='^[[:space:]]*((-|\*|•)[[:space:]]+)?(\(?[0-9]{1,2}[.):]|[A-Za-z][0-9]{1,2}[.):]?)([[:space:]]+[^[:space:]]|$)'
FM_EXT_CHOICE_CUE_RE='(^|[^[:alnum:]_])((reply|respond|answer|type|send|pick|choose|select|tap|click)([^[:alnum:]_.!?]|[^[:alnum:]_.!?][^.!?]{0,38}[^[:alnum:]_.!?])(number|code|letter|option|choice)s?|which (one|options?)|(pick|choose) one)([^[:alnum:]_]|$)'
FM_EXT_CHOICE_REPLY_RE='(^|[^[:alnum:]_])reply([^[:alnum:]_.!?]|[^[:alnum:]_.!?][^.!?]{0,28}[^[:alnum:]_.!?])(with|using)([^[:alnum:]_.!?]|[^[:alnum:]_.!?][^.!?]{0,18}[^[:alnum:]_.!?])(number|code|letter|option|choice)s?([^[:alnum:]_]|$)'
FM_EXT_CHOICE_DIGIT_CUE_RE='(^|[^[:alnum:]_])(reply|pick|choose|select|say)([^[:alnum:]_.!?]|[^[:alnum:]_.!?][^.!?]{0,38}[^[:alnum:]_.!?])(([0-9]{1,2}([[:space:]]*,[[:space:]]*[0-9]{1,2}([[:space:]]*,?[[:space:]]+or[[:space:]]+[0-9]{1,2})?|[[:space:]]+or[[:space:]]+[0-9]{1,2}))|[0-9]{1,2}[[:space:]]*/[[:space:]]*[0-9]{1,2})([^[:alnum:]_]|$)'
FM_EXT_CHOICE_HEADING_RE='^[[:space:]]*(\*\*(options?|your[[:space:]]+call|choose)(:?\*\*|\*\*:)|__(options?|your[[:space:]]+call|choose)(:?__|__:)|(options?|your[[:space:]]+call|choose):?)[[:space:]]*$'

fm_ext_text_choice_shaped() {
  local text=$1 options line choice_heading=0 choice_options=0
  if printf '%s\n' "$text" | grep -qiE -e "$FM_EXT_CHOICE_REPLY_RE" \
    || printf '%s\n' "$text" | grep -qiE -e "$FM_EXT_CHOICE_DIGIT_CUE_RE"; then
    return 0
  fi
  while IFS= read -r line; do
    if printf '%s\n' "$line" | grep -qiE -e "$FM_EXT_CHOICE_HEADING_RE"; then
      choice_heading=1
      choice_options=0
    elif [ "$choice_heading" = 1 ] \
      && printf '%s\n' "$line" | grep -qE -e "$FM_EXT_CHOICE_OPTION_RE"; then
      choice_options=$((choice_options + 1))
      [ "$choice_options" -ge 2 ] && return 0
    fi
  done <<< "$text"
  options=$(printf '%s\n' "$text" | grep -cE -e "$FM_EXT_CHOICE_OPTION_RE")
  [ "${options:-0}" -ge 2 ] || return 1
  printf '%s\n' "$text" | grep -qiE -e "$FM_EXT_CHOICE_CUE_RE"
}

# Option labels naming a deletion, money, credentials, or another irreversible
# destruction always need a second confirmation click, whatever the emitter
# declared. Merges, deploys, releases, and other reversible production changes
# are deliberately absent: one click, or the same author's clear typed reply, is
# the captain's word for that one decision, and docs/configuration.md's
# decision-buttons contract owns that policy. Matched case-insensitively
# anywhere in the label; only destruction still earns the extra click.
# shellcheck disable=SC2034 # Read by the sourcing emit script.
FM_EXT_DECISION_CONFIRM_PATTERN='delete|deletion|remove|destroy|discard|drop|wipe|purge|erase|reset|force ?-? ?push|push([[:space:]]+[^[:space:]]+)*[[:space:]]+(-[vqund46]*[fd][^[:space:]]*|--?force(-with-lease)?|--(mirror|prune)|[+:][^[:space:]]+)([[:space:]=]|$)|overwrite|tear ?down|revoke|rotate|kill|money|pay|charge|refund|purchase|buy|invoice|billing|budget|credential|secret|token|password|api ?key'

_fm_ext_decision_part_valid() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# fm_ext_decision_key_valid <key>: hold:<task-id> or key:<task-id>:<slug>,
# each part a privacy-safe slug.
fm_ext_decision_key_valid() {
  local key=$1 rest
  case "$key" in
    hold:*)
      _fm_ext_decision_part_valid "${key#hold:}"
      ;;
    key:*:*)
      rest=${key#key:}
      _fm_ext_decision_part_valid "${rest%%:*}" && _fm_ext_decision_part_valid "${rest#*:}"
      ;;
    *) return 1 ;;
  esac
}

# fm_ext_decision_key_task <key>: print the task id a valid key names.
fm_ext_decision_key_task() {
  local key=$1 rest
  fm_ext_decision_key_valid "$key" || return 1
  case "$key" in
    hold:*) printf '%s\n' "${key#hold:}" ;;
    key:*) rest=${key#key:}; printf '%s\n' "${rest%%:*}" ;;
  esac
}

# fm_ext_decision_key_occurrence <key>: print which lifecycle of the decision is
# open right now, so a post can be bound to the one it asked about: a captain
# call's `fm-captain-hold.sh open --identity` (hold-set stamp and answer count,
# printed only while it is held), or the number of times a worker's key has
# been opened in its status log (bin/fm-classify-lib.sh's
# status_key_occurrence). Returns 1 when the decision is not open or its
# lifecycle cannot be read.
fm_ext_decision_key_occurrence() {
  local key=$1 rest out
  fm_ext_decision_key_valid "$key" || return 1
  case "$key" in
    hold:*)
      out=$("$_FM_EXT_LIB_DIR/fm-captain-hold.sh" open "${key#hold:}" --identity 2>/dev/null) || return 1
      ;;
    key:*)
      rest=${key#key:}
      out=$(bash -c '. "$1" && status_key_occurrence "$2" "$3"' \
        _ "$_FM_EXT_LIB_DIR/fm-classify-lib.sh" \
        "$(fm_ext_state_dir)/${rest%%:*}.status" "${rest#*:}") || return 1
      [ "$out" != 0 ] || return 1
      ;;
  esac
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# fm_ext_decision_key_outcome <key> [occurrence]: print "<state>\t<answer>" for
# the decision right now, asking the authoritative ledgers rather than keeping
# a copy - `fm-captain-hold.sh open` and `answered` for a captain call, and
# bin/fm-classify-lib.sh's fold and resolved-answer reader for a worker's keyed
# decision. With an occurrence from fm_ext_decision_key_occurrence, a later
# lifecycle of the same key (a re-held call, a reopened key) reads as
# superseded, so an old post never answers or shows a newer question. The
# state is one of:
#   open        still waiting for an answer
#   decided     answered, on any channel; <answer> is what the ledger recorded
#               (empty when it recorded no answer text)
#   superseded  closed with no captain answer: by its task's terminal outcome,
#               moved to a captain call, reconciled as moot, gone with its task,
#               or replaced by a later lifecycle of the same key
#   unknown     its state cannot be read
# Returns 1 only for a malformed key.
fm_ext_decision_key_outcome() {
  local key=$1 occurrence=${2:-} rest task slug file rc out mode answer count current stamp
  fm_ext_decision_key_valid "$key" || return 1
  case "$key" in
    hold:*)
      task=${key#hold:}
      current=$("$_FM_EXT_LIB_DIR/fm-captain-hold.sh" open "$task" --identity 2>/dev/null)
      rc=$?
      if [ "$rc" = 1 ]; then
        "$_FM_EXT_LIB_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null 2>&1
        rc=$?
      fi
      case "$rc" in
        0)
          if [ -n "$occurrence" ] && [ "$current" != "$occurrence" ]; then
            printf 'superseded\t\n'
          else
            printf 'open\t\n'
          fi
          ;;
        1)
          out=$("$_FM_EXT_LIB_DIR/fm-captain-hold.sh" answered "$task" 2>/dev/null)
          rc=$?
          case "$rc" in
            0) ;;
            1) printf 'superseded\t\n'; return 0 ;;
            *) printf 'unknown\t\n'; return 0 ;;
          esac
          stamp=$(printf '%s\n' "$out" | sed -n '4p')
          mode=${out%%$'\n'*}
          out=${out#*$'\n'}
          answer=${out%%$'\n'*}
          out=${out#*$'\n'}
          count=${out%%$'\n'*}
          # The post's call was answered once more than the count it was
          # posted at; any other count is a later lifecycle's record.
          if [ "$mode" = reconciled ]; then
            printf 'superseded\t\n'
            return 0
          fi
          if [ -n "$occurrence" ]; then
            [ -z "$stamp" ] || [ "$stamp" = "${occurrence%#*}" ] || { printf 'superseded\t\n'; return 0; }
            case "${occurrence##*#}" in
              ''|*[!0-9]*) printf 'superseded\t\n'; return 0 ;;
            esac
            [ "$count" = "$(( ${occurrence##*#} + 1 ))" ] || { printf 'superseded\t\n'; return 0; }
          fi
          printf 'decided\t%s\n' "$answer"
          ;;
        3) printf 'superseded\t\n' ;;
        *) printf 'unknown\t\n' ;;
      esac
      return 0
      ;;
  esac
  rest=${key#key:}
  task=${rest%%:*}
  slug=${rest#*:}
  file="$(fm_ext_state_dir)/$task.status"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf 'superseded\t\n'
    return 0
  fi
  if ! { [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ]; }; then
    printf 'unknown\t\n'
    return 0
  fi
  if ! out=$(bash -c '
    file=$2 slug=$3 occurrence=$4
    . "$1" \
    && current=$(status_key_occurrence "$file" "$slug") \
    && if [ -n "$occurrence" ] && [ "$current" != "$occurrence" ]; then
      printf "superseded\t"
    else
      case "$(status_key_closing_verb "$file" "$slug")" in
        needs-decision|blocked) printf "open\t" ;;
        resolved) printf "decided\t%s" "$(status_resolved_key_answer "$file" "$slug")" ;;
        *) printf "superseded\t" ;;
      esac
    fi' _ "$_FM_EXT_LIB_DIR/fm-classify-lib.sh" "$file" "$slug" "$occurrence"); then
    printf 'unknown\t\n'
    return 0
  fi
  printf '%s\n' "$out"
}

# fm_ext_decision_key_state <key> [occurrence]: just the state word of the
# outcome above.
fm_ext_decision_key_state() {
  local out
  out=$(fm_ext_decision_key_outcome "$@") || return 1
  printf '%s\n' "${out%%$'\t'*}"
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

# Inactivity age after which a generation stuck mid-chunk is force-recovered.
# The ambiguous-failure path deliberately keeps the in-flight chunk recorded so
# no chunk is double-posted, but on its own nothing ever clears it: one network
# timeout would wedge that reply forever. Each chunk attempt refreshes progress,
# so a genuinely active sender is never recovered out from under its sender.
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
# owner, or dead owner still inside the TTL) or was released during acquisition,
# and 2 on validation or publication failure. A dead owner whose claim is at least
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
    *)
      # A competing owner can release after our link fails but before the
      # publisher validates the existing marker. Retry contention when the
      # marker is now absent; never grant ownership without a successful claim.
      if [ ! -e "$dir/$inflight" ] && [ ! -L "$dir/$inflight" ] \
        && fm_ext_private_artifact_dir_device "$dir" >/dev/null; then
        return 1
      fi
      return 2
      ;;
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
# from the most recent exclusive claim or progress heartbeat. Returns 1 when the
# generation records no in-flight chunk or the age cannot be established.
fm_ext_outbox_stuck_age() {
  local dir=$1 slug=$2 kind=$3 generation=$4 progress inflight now recorded_at inflight_recorded_at progress_mtime age
  progress=$(fm_ext_outbox_progress_basename "$slug" "$kind" "$generation") || return 1
  inflight=$(fm_ext_outbox_inflight_basename "$slug" "$kind" "$generation") || return 1
  fm_ext_private_artifact_file_valid "$dir" "$progress" 600 || return 1
  jq -e '.inflight | type == "number"' "$dir/$progress" >/dev/null 2>&1 || return 1
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  progress_mtime=$(fm_ext_file_mtime "$dir/$progress") || return 1
  case "$progress_mtime" in
    ''|*[!0-9]*) return 1 ;;
  esac
  recorded_at=$progress_mtime
  if fm_ext_private_artifact_file_valid "$dir" "$inflight" 600; then
    inflight_recorded_at=$(jq -er '.recorded_at | select(type=="number")' "$dir/$inflight" 2>/dev/null) || inflight_recorded_at=
    case "$inflight_recorded_at" in
      ''|*[!0-9]*) ;;
      *) [ "$inflight_recorded_at" -gt "$recorded_at" ] && recorded_at=$inflight_recorded_at ;;
    esac
  fi
  age=$((now - recorded_at))
  [ "$age" -ge 0 ] 2>/dev/null || return 1
  printf '%s\n' "$age"
}

# fm_ext_outbox_stuck_recover <dir> <slug> <kind> <generation>: bounded recovery
# for a generation wedged by an ambiguous mid-chunk send failure. Once the
# generation has recorded no fresh claim or progress heartbeat for longer than
# FM_EXT_MIDDELIVERY_RECOVERY_SECS, this clears that chunk so the next claim
# re-sends exactly it, and records the attempt in the progress artifact. After
# FM_EXT_MIDDELIVERY_RECOVERY_MAX attempts it writes the terminal failed marker
# instead, so the reply surfaces as a failure rather than retrying forever.
# Returns 0 when this call cleared the chunk, 5 when the budget is spent and the
# generation is now terminally failed, 1 when the generation is not stuck or is
# not yet eligible, and 2 on failure.
fm_ext_outbox_stuck_recover() {
  local dir=$1 slug=$2 kind=$3 generation=$4
  local progress inflight posting age threshold attempts max now body reason rc recorded_at owner_pid owner_dead
  progress=$(fm_ext_outbox_progress_basename "$slug" "$kind" "$generation") || return 2
  inflight=$(fm_ext_outbox_inflight_basename "$slug" "$kind" "$generation") || return 2
  posting=$(fm_ext_outbox_posting_basename "$slug" "$kind" "$generation") || return 2
  owner_dead=0
  if fm_ext_private_artifact_file_valid "$dir" "$inflight" 600; then
    owner_pid=$(jq -er '.pid | select(type=="number")' "$dir/$inflight" 2>/dev/null) || owner_pid=
    if [ -n "$owner_pid" ] \
      && [ "$owner_pid" != "$$" ] \
      && [ "$owner_pid" != "$(fm_ext_outbox_inflight_owner_pid)" ] \
      && ! fm_ext_pid_alive "$owner_pid"; then
      owner_dead=1
    fi
  fi
  if ! fm_ext_private_artifact_file_valid "$dir" "$progress" 600; then
    fm_ext_private_artifact_file_valid "$dir" "$posting" 600 || return 1
    fm_ext_private_artifact_file_valid "$dir" "$inflight" 600 || return 1
    now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
    case "$now" in
      ''|*[!0-9]*) return 2 ;;
    esac
    recorded_at=$(jq -er '.recorded_at | select(type=="number")' "$dir/$inflight" 2>/dev/null) || return 1
    case "$recorded_at" in
      ''|*[!0-9]*) return 1 ;;
    esac
    age=$((now - recorded_at))
    [ "$age" -ge 0 ] 2>/dev/null || return 1
    threshold=$(fm_ext_middelivery_recovery_secs)
    [ "$age" -ge "$threshold" ] 2>/dev/null || [ "$owner_dead" = 1 ] || return 1
    # Progress is written before the first send, so no progress proves no post occurred.
    fm_ext_outbox_abort "$dir" "$slug" "$kind" "$generation"
    rc=$?
    case "$rc" in
      0) return 0 ;;
      1) return 1 ;;
      *) return 2 ;;
    esac
  fi
  age=$(fm_ext_outbox_stuck_age "$dir" "$slug" "$kind" "$generation") || return 1
  threshold=$(fm_ext_middelivery_recovery_secs)
  [ "$age" -ge "$threshold" ] 2>/dev/null || [ "$owner_dead" = 1 ] || return 1
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
  body=$(jq -c --argjson attempts "$((attempts + 1))" --argjson recovered_at "$now" \
    '.inflight = null | .recovery_count = $attempts | .recovered_at = $recovered_at' \
    "$dir/$progress" 2>/dev/null) || return 2
  [ -n "$body" ] || return 2
  fm_ext_outbox_progress "$dir" "$slug" "$kind" "$generation" "$body" || return 2
  fm_ext_outbox_inflight_release "$dir" "$slug" "$kind" "$generation" || return 2
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
  raw=${raw#"${raw%%[!0]*}"}
  raw=${raw:-0}
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
  raw=${raw#"${raw%%[!0]*}"}
  raw=${raw:-0}
  [ "$raw" -ge 1 ] 2>/dev/null || raw=25
  printf '%s\n' "$raw"
}

# Legacy Discord splitter: the joined, "(k/n)"-numbered splitter that shipped
# before Discord replies kept their line structure.
# It is retained only so a generation that was already partially posted when the
# Python splitter landed can resume with the exact chunks it started with, which
# is why fm-ext-outbox.sh exposes it as `split --legacy`.
# New splits never come here: contrib/hermes-gateway-firstmate-comms/discord_split.py
# owns the Discord splitter, and its module docstring owns the rules.
fm_ext_split_thread_legacy() {
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

# fm_ext_outbox_schema_valid <file>: payload has required fields and matching
# slug. An optional decision carries its key, close mode, lifecycle, option
# buttons, and the post text the buttons answer. Optional media names this
# generation's staged folder and its generically named files, which
# bin/fm-ext-media.sh owns.
fm_ext_outbox_schema_valid() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  jq -e --argjson schema "$FM_EXT_SCHEMA_VERSION" \
    --argjson max_options "$FM_EXT_DECISION_MAX_OPTIONS" \
    --argjson label_max "$FM_EXT_DECISION_LABEL_MAX" \
    --arg media_name "$FM_EXT_MEDIA_NAME_RE" '
    . as $payload
    | .schema_version == $schema
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
    and (if has("thread_title") then (.thread_title | type == "string" and length >= 1 and length <= 60) else true end)
    and (if has("thread_retitle") then (.thread_retitle | type == "string" and length >= 1 and length <= 60) else true end)
    and (if has("thread_state") then (.thread_state == "needs-you" or .thread_state == "done" or .thread_state == "none") else true end)
    and (if has("no_buttons_reason") then (.no_buttons_reason | type == "string" and length >= 1 and length <= 200) else true end)
    and (if has("decision") then
      (.decision | type == "object"
        and (.key | type == "string" and test("^(hold|key):"))
        and (.mode == "done" or .mode == "release")
        and (.occurrence | type == "string" and length >= 1)
        and (.text | type == "string")
        and (.options | type == "array" and length >= 1 and length <= $max_options
          and all(.[]; type == "object"
            and (.id | type == "number")
            and (.label | type == "string" and length >= 1 and length <= $label_max)
            and (.confirm | type == "boolean")
            and ((.recommended // false) | type == "boolean")))
        and (if has("sections") then
          (.sections | type == "object"
            and (.question | type == "string")
            and (.explanation | type == "string")
            and (.options | type == "string")
            and (.cue | type == "string")
            and (.structured | type == "boolean"))
        else true end))
      else true end)
    and (if has("media") then
      (.media | type == "object"
        and (.dir | type == "string" and test("^[0-9a-f]{64}\\.(answer|followup|final)\\.[0-9]+\\.[0-9a-f]{16}$")
          and startswith($payload.slug + "." + $payload.kind + "." + ($payload.generation | tostring) + "."))
        and (.files | type == "array" and length >= 1 and length <= 5
          and all(.[]; type == "object"
            and (.name | type == "string" and test($media_name))
            and (.media == "image" or .media == "video")
            and (.media_type | type == "string")
            and (.bytes | type == "number" and . >= 1)
            and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
            and (.screened_sha256 | type == "string" and test("^[0-9a-f]{64}$")))))
      else true end)
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
# present receipt. A new receipt starts the retention clock of the
# generation's staged media.
fm_ext_outbox_receipt() {
  local dir=$1 slug=$2 kind=$3 generation=$4 receipt_json=$5 receipt rc
  receipt=$(fm_ext_outbox_receipt_basename "$slug" "$kind" "$generation") || return 2
  [ -n "$receipt_json" ] || return 2
  printf '%s\n' "$receipt_json" \
    | fm_ext_private_artifact_publish_stdin_once "$dir" "$receipt" 600
  rc=$?
  case "$rc" in
    0|1)
      [ "$rc" != 0 ] || fm_ext_media_mark_posted "$dir" "$slug" "$kind" "$generation"
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
# begin sees terminal-failed rather than mid-delivery. A new failed marker also
# starts the retention clock of the generation's staged media.
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
      fm_ext_media_mark_posted "$dir" "$slug" "$kind" "$generation"
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

# Per-file attachment byte cap for the local bridge. Mirrors the
# fm_ext_discord_reply_max_chars clamp shape: non-numeric values reset to the
# default, and the 32 MiB default matches the Discord adapter's own
# historical per-attachment cap.
fm_ext_attachment_max_bytes() {
  local raw=${1:-${FM_EXT_ATTACHMENT_MAX_BYTES-}}
  case "$raw" in
    ''|*[!0-9]*) raw=33554432 ;;
  esac
  [ "$raw" -ge 1 ] 2>/dev/null || raw=33554432
  printf '%s\n' "$raw"
}

# Per-request attachment count cap. Non-numeric values reset to the default.
fm_ext_attachment_max_count() {
  local raw=${1:-${FM_EXT_ATTACHMENT_MAX_COUNT-}}
  case "$raw" in
    ''|*[!0-9]*) raw=10 ;;
  esac
  [ "$raw" -ge 1 ] 2>/dev/null || raw=10
  printf '%s\n' "$raw"
}

# fm_ext_attachments_prune <state>: drop per-request attachment folders past
# the retention window so state/ext-attachments stays bounded. A folder whose
# request is still sitting unhandled in the inbox is kept: expiring it would
# leave a request whose files are already gone. Best effort, like the context
# prune above: an unreadable folder is left alone rather than failing.
fm_ext_attachments_prune() {
  local state=$1 dir inbox now max_age folder base slug recorded_at age
  dir="$state/$FM_EXT_ATTACHMENTS_DIRNAME"
  inbox="$state/$FM_EXT_INBOX_DIRNAME"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 0 ;;
  esac
  max_age=$(fm_ext_retention_max_age_secs)
  while IFS= read -r -d '' folder; do
    base=${folder##*/}
    slug=$base
    fm_ext_slug_valid "$slug" || continue
    if fm_ext_private_artifact_file_valid "$inbox" "$slug.json" 600; then
      continue
    fi
    recorded_at=$(fm_ext_file_mtime "$folder") || continue
    case "$recorded_at" in
      ''|*[!0-9]*) continue ;;
    esac
    age=$((now - recorded_at))
    [ "$age" -gt "$max_age" ] 2>/dev/null || continue
    rm -rf -- "$folder" 2>/dev/null || true
  done < <(find "$dir" -maxdepth 1 -mindepth 1 -print0 2>/dev/null)
  return 0
}

# fm_ext_media_mark_posted <outbox-dir> <slug> <kind> <generation>: start the
# retention clock of this generation's staged media folder by setting its
# modification time to now, so the window counts from posting rather than
# staging. Best effort: a folder that cannot be touched keeps its staging time.
fm_ext_media_mark_posted() {
  local outbox=$1 slug=$2 kind=$3 generation=$4 staged folder
  staged="${outbox%/*}/$FM_EXT_MEDIA_DIRNAME/staged"
  [ -d "$staged" ] && [ ! -L "$staged" ] || return 0
  for folder in "$staged/$slug.$kind.$generation".*; do
    [ -d "$folder" ] && [ ! -L "$folder" ] || continue
    touch -c -- "$folder" 2>/dev/null || true
  done
  return 0
}

# fm_ext_media_prune <state>: drop outbound media past FM_EXT_MEDIA_RETENTION_SECS
# (14 days) so state/ext-media stays bounded. A staged generation folder whose
# outbox payload is still present is pending or mid-delivery and is never
# touched; once its post has a receipt or terminal failure, its age counts from
# that moment (fm_ext_media_mark_posted). Screening attestations, sampled
# video frames, and files pulled from a remote second mate expire on their own
# modification time. Best effort, like the other prunes.
fm_ext_media_prune() {
  local state=$1 root outbox now sub depth entry base mtime age
  root="$state/$FM_EXT_MEDIA_DIRNAME"
  outbox="$state/$FM_EXT_OUTBOX_DIRNAME"
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 0 ;;
  esac
  for sub in staged screened frames pulled; do
    [ -d "$root/$sub" ] && [ ! -L "$root/$sub" ] || continue
    depth=1
    [ "$sub" != pulled ] || depth=2
    while IFS= read -r -d '' entry; do
      base=${entry##*/}
      if [ "$sub" = staged ] && [ -e "$outbox/${base%.*}.json" ]; then
        continue
      fi
      mtime=$(fm_ext_file_mtime "$entry") || continue
      case "$mtime" in
        ''|*[!0-9]*) continue ;;
      esac
      age=$((now - mtime))
      [ "$age" -gt "$FM_EXT_MEDIA_RETENTION_SECS" ] 2>/dev/null || continue
      rm -rf -- "$entry" 2>/dev/null || true
    done < <(find "$root/$sub" -mindepth "$depth" -maxdepth "$depth" -print0 2>/dev/null)
  done
  if [ -d "$root/pulled" ] && [ ! -L "$root/pulled" ]; then
    find "$root/pulled" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir -- {} + 2>/dev/null || true
  fi
  return 0
}
# fm_ext_attachment_safe_name <name>: reject path-like names, strip control
# bytes, and reject empty or dot-only names. Prints the safe name
# or returns 1 when nothing usable remains. The caller prefixes an index so
# two attachments with the same Discord name cannot collide.
fm_ext_attachment_safe_name() {
  local name=$1 safe
  case "$name" in
    */*|*\\*) return 1 ;;
  esac
  safe=${name%%$'\n'*}
  safe=${safe%$'\r'*}
  case "$safe" in
    */*|*\\*) return 1 ;;
  esac
  safe=$(printf '%s' "$safe" | tr -d '\000-\037\177') || return 1
  safe=$(printf '%s' "$safe" | sed 's/^ *//;s/ *$//') || return 1
  [ -n "$safe" ] || return 1
  case "$safe" in
    .|..) return 1 ;;
  esac
  [ "${#safe}" -le 128 ] || safe=$(printf '%s' "$safe" | cut -c1-128)

  [ -n "$safe" ] || return 1
  printf '%s\n' "$safe"
}

# fm_ext_attachment_cache_roots: print the Hermes adapter cache roots the
# gateway may hand us, one per line. The adapter caches downloads under
# HERMES_HOME/cache/{images,audio,documents} (legacy
# HERMES_HOME/{image_cache,audio_cache,document_cache} when populated), so a
# manifest path outside those roots is never copied. HERMES_HOME resolves
# physically so a symlinked root cannot escape the comparison.
fm_ext_attachment_cache_roots() {
  local dir=${HERMES_HOME-} resolved
  [ -n "$dir" ] || return 0
  resolved=$(cd -- "$dir" 2>/dev/null && pwd -P) || return 0
  printf '%s\n' "$resolved/cache/images"
  printf '%s\n' "$resolved/cache/audio"
  printf '%s\n' "$resolved/cache/documents"
  printf '%s\n' "$resolved/image_cache"
  printf '%s\n' "$resolved/audio_cache"
  printf '%s\n' "$resolved/document_cache"
}

# fm_ext_attachments_stage <stage-dir> <manifest>: copy the gateway's cached
# attachments into a staging dir and print {"kept":[...],"skipped":[...]}.
# The manifest is a JSON array of {path, media_type, name} written by the
# gateway plugin. Only regular files inside the adapter cache roots are
# copied: symlinks (including symlinked parents), remote URLs, paths outside
# the cache, missing files, oversize files, and entries past the count cap
# are skipped with a reason, never fetched or followed. The copy opens the
# source with O_NOFOLLOW, checks fstat, and reads at most max-bytes+1 so a
# file grown or replaced after sizing cannot defeat the byte cap. Prints kept
# entries as {name, staged, media_type, bytes} with staged as the temp path;
# the caller rewrites it to the per-request path. Best effort per entry: one
# bad entry never fails the whole request.
fm_ext_attachments_stage() {
  local stage=$1 manifest=$2 max_bytes max_count count kept skipped rc roots
  [ -d "$stage" ] && [ ! -L "$stage" ] || return 1
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  max_bytes=$(fm_ext_attachment_max_bytes)
  max_count=$(fm_ext_attachment_max_count)
  kept=$(mktemp "${TMPDIR:-/tmp}/fm-ext-kept.XXXXXX") || return 1
  skipped=$(mktemp "${TMPDIR:-/tmp}/fm-ext-skipped.XXXXXX") || return 1
  : > "$kept"
  : > "$skipped"
  roots=$(mktemp "${TMPDIR:-/tmp}/fm-ext-roots.XXXXXX") || return 1
  fm_ext_attachment_cache_roots >"$roots" 2>/dev/null || : >"$roots"
  count=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    count=$(wc -l <"$kept" 2>/dev/null | tr -d ' ') || count=0
    case "$count" in
      ''|*[!0-9]*) count=0 ;;
    esac
    FM_EXT_ATTACHMENT_ROOTS_FILE="$roots" fm_ext_attachments_stage_one \
      "$stage" "$entry" "$max_bytes" "$max_count" "$count" "$kept" "$skipped" || true
  done < <(jq -c '.[]' "$manifest" 2>/dev/null)
  jq -cn --slurpfile kept "$kept" --slurpfile skipped "$skipped" '{kept:$kept, skipped:$skipped}' 2>/dev/null
  rc=$?
  rm -f -- "$kept" "$skipped" "$roots" 2>/dev/null || true
  return "$rc"
}

# fm_ext_attachments_stage_one <stage> <entry-json> <max-bytes> <max-count>
# <index> <kept-file> <skipped-file>: stage one manifest entry. Appends one
# JSON line to the kept or skipped file. Kept lines carry
# {name, staged, media_type, bytes}; skipped lines carry {name, reason} with
# reason one of uncached, not-found, unsafe-name, too-large, or over-count.
# The source must resolve inside one of the adapter cache roots
# ($FM_EXT_ATTACHMENT_ROOTS_FILE, one physical path per line): anything else
# is uncached. The copy itself runs through the no-follow helper below, which
# refuses symlinks at every path component and reads at most max-bytes+1.
fm_ext_attachments_stage_one() {
  local stage=$1 entry=$2 max_bytes=$3 max_count=$4 index=$5 kept=$6 skipped=$7
  local path media_type raw_name name reason dest safe match match_root match_rel out rc
  local roots=${FM_EXT_ATTACHMENT_ROOTS_FILE-}
  path=$(printf '%s' "$entry" | jq -er '.path | select(type=="string")' 2>/dev/null) || path=
  media_type=$(printf '%s' "$entry" | jq -er '.media_type | select(type=="string")' 2>/dev/null) || media_type=
  raw_name=$(printf '%s' "$entry" | jq -er '.name | select(type=="string")' 2>/dev/null) || raw_name=
  [ -n "$raw_name" ] || raw_name=${path##*/}
  [ -n "$raw_name" ] || raw_name="attachment-$((index + 1))"
  if ! safe=$(fm_ext_attachment_safe_name "$raw_name"); then
    reason="unsafe-name"
    jq -cn --arg name "$raw_name" --arg reason "$reason" '{name:$name, reason:$reason}' >>"$skipped"
    return 0
  fi
  name="$safe"
  case "$path" in
    http://*|https://*|ftp://*|data:*)
      jq -cn --arg name "$name" --arg reason "uncached" '{name:$name, reason:$reason}' >>"$skipped"
      return 0
      ;;
  esac
  if ! match=$(fm_ext_attachment_cache_match "$path" "$roots"); then
    jq -cn --arg name "$name" --arg reason "uncached" '{name:$name, reason:$reason}' >>"$skipped"
    return 0
  fi
  match_root=$(printf '%s' "$match" | jq -er '.root') || return 1
  match_rel=$(printf '%s' "$match" | jq -er '.rel') || return 1
  [ -n "$match_root" ] && [ -n "$match_rel" ] || {
    jq -cn --arg name "$name" --arg reason "uncached" '{name:$name, reason:$reason}' >>"$skipped"
    return 0
  }
  if [ "$index" -ge "$max_count" ] 2>/dev/null; then
    jq -cn --arg name "$name" --arg reason "over-count" '{name:$name, reason:$reason}' >>"$skipped"
    return 0
  fi
  case "$media_type" in
    ''|*/*) ;;
    *) media_type="application/octet-stream" ;;
  esac
  [ -n "$media_type" ] || media_type="application/octet-stream"
  dest="$stage/$index-$name"
  case "$dest" in
    "$stage/"*) ;;
    *) jq -cn --arg name "$name" --arg reason "unsafe-name" '{name:$name, reason:$reason}' >>"$skipped"; return 0 ;;
  esac
  out=$(fm_ext_attachment_copy_nofollow "$match_root" "$match_rel" "$dest" "$max_bytes")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" = 11 ]; then
      jq -cn --arg name "$name" --arg reason "too-large" '{name:$name, reason:$reason}' >>"$skipped"
    else
      jq -cn --arg name "$name" --arg reason "not-found" '{name:$name, reason:$reason}' >>"$skipped"
    fi
    return 0
  fi
  case "$out" in
    ''|*[!0-9]*) jq -cn --arg name "$name" --arg reason "not-found" '{name:$name, reason:$reason}' >>"$skipped"; return 0 ;;
  esac
  jq -cn --arg name "$name" --arg staged "$dest" --arg media_type "$media_type" --argjson bytes "$out" \
    '{name:$name, staged:$staged, media_type:$media_type, bytes:$bytes}' >>"$kept"
}

# fm_ext_attachment_copy_nofollow <root> <rel> <dest> <max-bytes>: copy one
# regular file without following any symlink, printing the byte count.
# Opens the cache root, then walks each path component relative to directory
# FDs with O_NOFOLLOW, requires a regular-file fstat, creates the destination
# as a temporary mode-0600 file, and reads at most max-bytes+1 so growth
# after sizing still trips too-large before atomically replacing dest.
# Exits 10 on a non-file or symlink, 11 past the byte cap, and 1 on any other failure.
fm_ext_attachment_copy_nofollow() {
  FM_EXT_ATTACHMENT_ROOT=$1 FM_EXT_ATTACHMENT_REL=$2 FM_EXT_ATTACHMENT_DEST=$3 FM_EXT_ATTACHMENT_MAX=$4 python3 -c \
    'import os,stat,sys,tempfile
root=os.environ["FM_EXT_ATTACHMENT_ROOT"]; rel=os.environ["FM_EXT_ATTACHMENT_REL"]
dest=os.environ["FM_EXT_ATTACHMENT_DEST"]
limit=int(os.environ.get("FM_EXT_ATTACHMENT_MAX") or 0)
parts=[p for p in rel.split("/") if p not in ("", ".", "..")]
if not parts:
  sys.exit(1)
rfd=os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
  dfd=rfd
  # Each intermediate folder FD is closed exactly once, as the walk moves past
  # it: closing one twice could close a later, reused descriptor number,
  # such as the source file itself, two or more folders deep.
  try:
    for part in parts[:-1]:
      nfd=os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=dfd)
      if dfd != rfd:
        os.close(dfd)
      dfd=nfd
    fd=os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
  finally:
    if dfd != rfd:
      os.close(dfd)
  try:
    st=os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
      sys.exit(10)
    out, temp=tempfile.mkstemp(prefix=".attachment-", dir=os.path.dirname(dest))
    try:
      got=0
      while True:
        chunk=os.read(fd, 65536)
        if not chunk:
          break
        got+=len(chunk)
        if got > limit:
          sys.exit(11)
        view=memoryview(chunk)
        while view:
          view=view[os.write(out, view):]
      os.replace(temp, dest)
    finally:
      os.close(out)
      if os.path.exists(temp):
        os.unlink(temp)
    sys.stdout.write(str(got))
  finally:
    os.close(fd)
finally:
  os.close(rfd)
' 2>/dev/null
}

# fm_ext_attachment_cache_match <path> <roots-file>: print {root, rel}
# when the path sits under one of the cache roots, else return 1.
# The match is lexical on the unresolved path, so a swapped parent cannot
# race it: the no-follow copy below re-verifies every component at open time
# and refuses symlinks there. Remote-looking values fail closed.
fm_ext_attachment_cache_match() {
  local path=$1 roots=$2 root rel
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -n "$roots" ] && [ -f "$roots" ] || return 1
  while IFS= read -r root || [ -n "$root" ]; do
    [ -n "$root" ] || continue
    case "$path" in
      "$root"/*)
        rel=${path#"$root"/}
        case "$rel" in
          ''|*//*|*/|/*) continue ;;
        esac
        jq -cn --arg root "$root" --arg rel "$rel" '{root:$root, rel:$rel}'
        return 0
        ;;
    esac
  done <"$roots"
  return 1
}

# --- retention prune cadence -----------------------------------------------
# fm-ext-poll.sh runs the four prunes after it has claimed the inbox offers,
# and at most once per interval: the watcher kills a poll that outruns its
# check timeout, so a prune must never sit in front of a request's claim, and
# repeating it every poll buys nothing. FM_EXT_PRUNE_INTERVAL_SECS=0 prunes
# every poll.
FM_EXT_PRUNE_STAMP='ext-prune.stamp'

# fm_ext_prune_interval_secs: the prune cadence, defaulting to one hour.
fm_ext_prune_interval_secs() {
  local raw=${1:-${FM_EXT_PRUNE_INTERVAL_SECS-}}
  case "$raw" in
    ''|*[!0-9]*) raw=3600 ;;
  esac
  [ "${#raw}" -le 9 ] || raw=3600
  printf '%s\n' "$raw"
}

# fm_ext_prune_due <state>: true when the last recorded prune is old enough.
fm_ext_prune_due() {
  local stamp="$1/$FM_EXT_PRUNE_STAMP" now last
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -L "$stamp" ] || [ ! -f "$stamp" ]; then
    return 0
  fi
  last=$(fm_ext_file_mtime "$stamp") || return 0
  case "$last" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ $((now - last)) -lt "$(fm_ext_prune_interval_secs)" ] 2>/dev/null && return 1
  return 0
}

# fm_ext_prune_mark <state> [duration-seconds]: record that a prune pass just
# completed. The mtime is the cadence source; the content keeps the pass
# duration inspectable, because the watcher discards a check's stderr.
fm_ext_prune_mark() {
  local state=$1 elapsed=${2:-0} stamp tmp
  [ -d "$state" ] && [ ! -L "$state" ] || return 0
  stamp="$state/$FM_EXT_PRUNE_STAMP"
  [ -L "$stamp" ] && return 0
  tmp=$(umask 077; mktemp "$state/.fm-ext-prune.XXXXXX" 2>/dev/null) || return 0
  if printf 'prune=%ss at=%s\n' "$elapsed" "$(date +%s)" >"$tmp" 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$stamp" 2>/dev/null || rm -f -- "$tmp"
  else
    rm -f -- "$tmp"
  fi
  return 0
}

# fm_ext_prune_run <state>: run the retention prunes when their cadence allows.
# Writes the completed pass duration to stderr and the cadence stamp; the
# stamp retains it when the watcher discards stderr. An interrupted pass has
# no new stamp and is retried when the next poll finds the cadence due.
fm_ext_prune_run() {
  local state=$1 started elapsed
  fm_ext_prune_due "$state" || return 0
  started=$(date +%s)
  fm_ext_context_prune "$state"
  fm_ext_outbox_prune "$state"
  fm_ext_attachments_prune "$state"
  fm_ext_media_prune "$state"
  elapsed=$(( $(date +%s) - started ))
  fm_ext_prune_mark "$state" "$elapsed"
  printf 'fm-ext-poll: prune=%ss\n' "$elapsed" >&2
  return 0
}

# fm_ext_context_prune <state>: drop destination-context, thread-history, and offer records past
# the retention window so state/ext-context stays bounded. Every record kind is
# kept while their request is still sitting unhandled in the inbox: expiring the
# offer marker would re-offer queued work, and expiring the destination context
# would leave a request that can no longer be replied to. Follow-ups after the
# inbox is cleared are what the window itself bounds. Best effort: a record that
# cannot be read or removed is left alone rather than failing the caller.
fm_ext_context_prune() {
  local state=$1 dir inbox now max_age file base slug line mtime age kind base_name
  local inbox_list='' context_rows=''
  local -a fallback doomed
  # An assigned empty array keeps ${#arr[@]} defined under set -u.
  fallback=()
  doomed=()
  dir="$state/$FM_EXT_CONTEXT_DIRNAME"
  inbox="$state/$FM_EXT_INBOX_DIRNAME"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 0 ;;
  esac
  max_age=$(fm_ext_retention_max_age_secs)
  # The inbox is usually empty, so the pin check below only runs for a slug the
  # inbox actually lists instead of for every record in the directory.
  if [ -d "$inbox" ] && [ ! -L "$inbox" ]; then
    for base_name in "$inbox"/*.json; do
      [ -e "$base_name" ] || continue
      inbox_list="$inbox_list${base_name##*/}"$'\n'
    done
  fi
  # One jq process per batch decides every record with a numeric recorded_at
  # and lists the ones that need an mtime check; a launch per file is what made
  # this prune outlast the watcher's check timeout, so retention never ran.
  # Batches stay bounded so one unreadable record cannot hide the rest.
  # shellcheck disable=SC2016  # jq program: $now, $max_age, $r, and $kind are jq variables.
  context_rows=$(find "$dir" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null \
    | xargs -0 -n 100 jq -rn --argjson now "$now" --argjson max_age "$max_age" '
      inputs
      | .recorded_at as $r
      | (if ($r | type) == "number" then
           (if ($r | tostring | test("^[0-9]+$")) then
              (if ($now - $r) > $max_age then "old" else "keep" end)
            else "keep" end)
         else "mtime" end) as $kind
      | [$kind, input_filename] | @tsv' 2>/dev/null)
  while IFS=$'\t' read -r kind file; do
    [ -n "$file" ] || continue
    case "$kind" in
      keep) continue ;;
      mtime) fallback[${#fallback[@]}]=$file; continue ;;
    esac
    base=${file##*/}
    case "$base" in
      *.offered.json) slug=${base%.offered.json} ;;
      *.history.json) slug=${base%.history.json} ;;
      *) slug=${base%.json} ;;
    esac
    fm_ext_inbox_pins "$inbox" "$inbox_list" "$slug" && continue
    doomed[${#doomed[@]}]=$file
  done <<<"$context_rows"
  # Records without a numeric recorded_at fall back to their file mtime, read
  # in one stat batch rather than one process each.
  if [ "${#fallback[@]}" -gt 0 ]; then
    while IFS= read -r line; do
      mtime=${line%% *}
      file=${line#* }
      case "$mtime" in
        ''|*[!0-9]*) continue ;;
      esac
      base=${file##*/}
      case "$base" in
        *.offered.json) slug=${base%.offered.json} ;;
        *.history.json) slug=${base%.history.json} ;;
        *) slug=${base%.json} ;;
      esac
      fm_ext_inbox_pins "$inbox" "$inbox_list" "$slug" && continue
      age=$((now - mtime))
      [ "$age" -gt "$max_age" ] 2>/dev/null || continue
      doomed[${#doomed[@]}]=$file
    done < <(printf '%s\0' "${fallback[@]}" | fm_ext_path_mtimes)
  fi
  [ "${#doomed[@]}" -gt 0 ] || return 0
  printf '%s\0' "${doomed[@]}" | fm_ext_remove_all
  return 0
}

# fm_ext_inbox_pins <inbox> <inbox-list> <slug>: true when this request still
# waits in the inbox, so its records must survive the retention window.
fm_ext_inbox_pins() {
  case $'\n'"$2"$'\n' in
    *$'\n'"$3.json"$'\n'*) fm_ext_private_artifact_file_valid "$1" "$3.json" 600 ;;
    *) return 1 ;;
  esac
}

# fm_ext_path_mtimes: read NUL-separated paths, print "<mtime> <path>" for each.
# One stat process per batch keeps a thousands-of-files prune inside the poll's
# check timeout; a path that vanished is simply absent.
fm_ext_path_mtimes() {
  if [ "$(uname)" = Darwin ]; then
    xargs -0 -n 200 stat -f '%m %N'
  else
    xargs -0 -n 200 stat -c '%Y %n'
  fi 2>/dev/null
}

# fm_ext_remove_all: delete the NUL-separated paths on stdin in batches.
fm_ext_remove_all() {
  xargs -0 -n 200 rm -f -- 2>/dev/null
}

# fm_ext_outbox_prune <state>: drop the leftover markers of retired generations
# past the retention window so state/ext-outbox stays bounded too. A generation
# whose payload is still present is pending or mid-delivery and is never touched,
# so this can only ever remove the residue of work that already finished. A
# request-wide thread record (<slug>.thread.json) is kept while any other JSON
# record for its slug remains, then is pruned when its own age exceeds the window.
# A decision post's sent, settled, and finalized markers go the same way as its
# chunk-progress record, so its buttons expire with it.
fm_ext_outbox_prune() {
  local state=$1 dir now max_age line file base stem slug mtime age other
  local -a doomed thread_doomed
  # An assigned empty array keeps ${#arr[@]} defined under set -u.
  doomed=()
  thread_doomed=()
  dir="$state/$FM_EXT_OUTBOX_DIRNAME"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  now=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
  case "$now" in
    ''|*[!0-9]*) return 0 ;;
  esac
  max_age=$(fm_ext_retention_max_age_secs)
  # Removals are queued and applied in batches: a stat and a uname per file is
  # what made this prune take tens of seconds on a mature outbox. A thread
  # record's sibling test still sees the same files the immediate-removal walk
  # saw, because the queue is flushed before it is evaluated.
  flush_prune_queue() {
    if [ "${#doomed[@]}" -gt 0 ]; then
      printf '%s\0' "${doomed[@]}" | fm_ext_remove_all
    fi
    if [ "${#thread_doomed[@]}" -gt 0 ]; then
      printf '%s\0' "${thread_doomed[@]}" | fm_ext_remove_all
    fi
    doomed=()
    thread_doomed=()
  }
  while IFS= read -r line; do
    mtime=${line%% *}
    file=${line#* }
    case "$mtime" in
      ''|*[!0-9]*) continue ;;
    esac
    base=${file##*/}
    # Only marker suffixes are pruned. A payload is <stem>.json and falls
    # through to the default, so this can never delete undelivered work.
    case "$base" in
      *.receipt.json) stem=${base%.receipt.json} ;;
      *.failed.json) stem=${base%.failed.json} ;;
      *.progress.json) stem=${base%.progress.json} ;;
      *.thread.json) stem=${base%.thread.json} ;;
      *.posting) stem=${base%.posting} ;;
      *.inflight) stem=${base%.inflight} ;;
      *.settled.json) stem=${base%.settled.json} ;;
      *.finalized) stem=${base%.finalized} ;;
      *.sent.json) stem=${base%.sent.json} ;;
      *) continue ;;
    esac
    if [ -e "$dir/$stem.json" ]; then
      continue
    fi
    # A thread record belongs to the whole request, not one generation: keep
    # it while any non-thread JSON file for its slug remains, so markers of
    # retired generations keep it alive until they expire too.
    case "$base" in
      *.thread.json)
        flush_prune_queue
        slug=${base%.thread.json}
        for other in "$dir/$slug".*.json; do
          [ -e "$other" ] || continue
          case "${other##*/}" in
            *.thread.json) continue ;;
            *) continue 2 ;;
          esac
        done
        ;;
    esac
    age=$((now - mtime))
    [ "$age" -gt "$max_age" ] 2>/dev/null || continue
    case "$base" in
      *.thread.json) thread_doomed[${#thread_doomed[@]}]=$file ;;
      *) doomed[${#doomed[@]}]=$file ;;
    esac
  done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | fm_ext_path_mtimes)
  flush_prune_queue
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

# fm_ext_shim_home <home>: the FM_HOME spelling baked into the shim - an
# absolute path as given, a relative one resolved physically.
fm_ext_shim_home() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) ;;
  esac
}

# fm_ext_file_write_if_changed <dest> <content> <mode>: atomically replace a
# single-link regular file with <content> plus a trailing newline unless it
# already matches; refuses a symlink or hard-linked destination.
fm_ext_file_write_if_changed() {
  local dest=$1 content=$2 mode=$3 parent tmp device current
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    device=$(stat -f %d "$parent" 2>/dev/null) || return 1
  else
    device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fm_ext_single_link_file_valid "$dest" "$device" || return 1
    if [ "$(uname)" = Darwin ]; then
      current=$(stat -f %Lp "$dest" 2>/dev/null) || return 1
    else
      current=$(stat -c %a "$dest" 2>/dev/null) || return 1
    fi
    if [ "$current" = "$mode" ] && cmp -s "$dest" <(printf '%s\n' "$content"); then
      return 0
    fi
  fi
  tmp=$(umask 077; mktemp "$parent/.fm-ext-shim.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod "$mode" "$tmp" \
    || ! fm_ext_single_link_file_mode_valid "$tmp" "$mode" "$device" \
    || ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_ext_single_link_file_mode_valid "$dest" "$mode" "$device" \
    && cmp -s "$dest" <(printf '%s\n' "$content")
}

fm_ext_file_remove_if_present() {
  local file=$1 parent=${1%/*}
  [ -e "$file" ] || [ -L "$file" ] || return 0
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  rm -f -- "$file" 2>/dev/null || return 1
  ! { [ -e "$file" ] || [ -L "$file" ]; }
}

# fm_ext_watch_shim_converge <home> <root>: make state/ext-watch.check.sh agree
# with this home's opt-in. The single owner of arming and removing the shim:
# the session-start bootstrap reports its verdict, and every watcher cycle
# calls it so a bridge switched on or off mid-session converges without a
# restart. Prints "<state> <action>":
#   state  off (not opted in), secret (secret missing or not 0600),
#          jq (jq missing), on (active and armable)
#   action none, removed, remove-failed, armed, arm-failed, arm-failed-stale
fm_ext_watch_shim_converge() {
  local home=$1 root=$2 verdict shim shim_home content
  shim="$(fm_ext_state_dir "$home")/$FM_EXT_WATCH_SHIM"
  if ! fm_ext_bridge_opted_in "$home"; then
    verdict=off
  elif ! fm_ext_secret_valid "$(fm_ext_secret_path "$home")"; then
    verdict=secret
  elif ! command -v jq >/dev/null 2>&1; then
    verdict=jq
  else
    verdict=on
  fi
  if [ "$verdict" != on ]; then
    if [ -e "$shim" ] || [ -L "$shim" ]; then
      if fm_ext_file_remove_if_present "$shim"; then
        printf '%s removed\n' "$verdict"
      else
        printf '%s remove-failed\n' "$verdict"
      fi
    else
      printf '%s none\n' "$verdict"
    fi
    return 0
  fi
  if mkdir -p "${shim%/*}" 2>/dev/null \
    && shim_home=$(fm_ext_shim_home "$home") \
    && content=$(fm_ext_poll_shim_content "$shim_home" "$root") \
    && fm_ext_file_write_if_changed "$shim" "$content" 700 \
    && fm_ext_poll_shim_valid "$shim" "$shim_home" "$root"; then
    printf 'on armed\n'
  elif fm_ext_file_remove_if_present "$shim"; then
    printf 'on arm-failed\n'
  else
    printf 'on arm-failed-stale\n'
  fi
}

# --- wake keys and pending requests ------------------------------------------

# fm_ext_wake_key <event> <slug>: the durable wake-row key for one bridge
# event (ext-request or ext-delivery-failed). Keyed per request, because the
# drain presents one row per kind+key and a shared key collapsed every pending
# request into one presented line.
fm_ext_wake_key() {
  printf '%s:%s\n' "$1" "$2"
}

# fm_ext_pending_requests [home]: one slug per unanswered request.
# The inbox record is the
# durable truth: ext-respond removes it once the request is answered, so a
# request stays listed however its wake rows were presented or acknowledged.
# Silent unless the bridge is active.
fm_ext_pending_requests() {
  local home=${1:-${FM_HOME:?}} inbox file base slug
  fm_ext_active "$home" || return 0
  inbox=$(fm_ext_inbox_dir "$home")
  [ -d "$inbox" ] && [ ! -L "$inbox" ] || return 0
  for file in "$inbox"/*.json; do
    [ -e "$file" ] || continue
    base=${file##*/}
    slug=${base%.json}
    fm_ext_slug_valid "$slug" || continue
    fm_ext_private_artifact_file_valid "$inbox" "$base" 600 || continue
    printf '%s\n' "$slug"
  done
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
