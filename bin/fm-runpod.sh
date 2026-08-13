#!/usr/bin/env bash
# Optional RunPod compute lifecycle for one whole-home remote second mate.
#
# Usage:
#   fm-runpod.sh provision <id> [--size <gb>] [--datacenter <id>] [--alias <ssh-alias>]
#                               [--volume-name <name>] [--user root] [--identity <key-path>]
#                               [--image <tag>] [--code-origin <git-url>] [--harness-npm <pkg>]
#   fm-runpod.sh wake <id> [--gpu] [--min-vram <gb>] [--gpu-type <id>]
#   fm-runpod.sh sleep <id>
#   fm-runpod.sh status [<id>]
#   fm-runpod.sh ssh <id> [<ssh-arg>...]
#   fm-runpod.sh doctor <id> [--fix]
#   fm-runpod.sh cost <id>
#   fm-runpod.sh destroy <id> --yes
#
# This is a compute lifecycle provider BENEATH the existing remote second-mate
# mechanism, never a session backend. A RunPod second mate is an ordinary remote
# second mate (docs/remote-secondmates.md) whose SSH host happens to be an
# ephemeral pod that can scale to zero when idle; Herdr remains its backend, the
# primary still owns routing and supervision, and every command that reaches it
# still goes through fm-on.sh, fm-spawn.sh, fm-send.sh, and fm-teardown.sh.
#
# The local record under <FM_HOME>/data/runpod/<id>.meta is authoritative for
# this home. RunPod is queried to confirm or create what that record names; it
# is never scanned to discover routes this home did not create.
#
# Record fields (bin/fm-runpod-lib.sh owns the lifecycle vocabulary):
#   schema=fm-runpod-secondmate.v1  provider=runpod  secondmate=<id>
#   lifecycle=provisioned|waking|ready|suspending|suspended
#   volume_id= volume_name= volume_size_gb= datacenter=
#   pod_id= endpoint_host= endpoint_port= compute=cpu|gpu gpu_type= min_vram_gb=
#   image= code_origin= harness_npm= ssh_alias= ssh_user= ssh_identity=
#   cost_per_hr= pod_started_at= updated=
#
# Credentials: the RunPod API key is read from <FM_HOME>/config/runpod.env, a
# local gitignored mode-600 file in ordinary KEY=value form, from its
# RUNPOD_API_KEY assignment. That file is PARSED, never sourced, so nothing in
# it can execute. The key is passed to curl through a mode-600 config file, so
# it never appears in argv, is never written to the record, and is never
# printed. Every command that needs the API refuses with that path and key name
# before it makes any request, so a missing key can never become a confusing
# 401 from an unauthenticated call.
#
# First-boot toolchain: the pod boot script clones the code root from
# --code-origin and installs the full parity toolchain onto the volume, so a
# fresh pod reaches readiness with no manual clone. --harness-npm names an
# OPTIONAL EXTRA npm harness beyond that set; each runtime's own login stays a
# human step either way. bin/fm-runpod-pod-boot.sh owns that contract.
#
# SSH: wake regenerates <FM_HOME>/config/runpod/ssh.d/<alias>.conf with the
# pod's current HostName and Port plus a stable HostKeyAlias, and pins the pod's
# host key in <FM_HOME>/config/runpod/known_hosts under that alias. The pod
# restores the SAME host key from its network volume on every wake, so strict
# host-key verification keeps working across pod replacement. The key is pinned
# once, on the first wake of a volume that has no persisted key yet;
# StrictHostKeyChecking is never disabled, and a later mismatch fails the
# connection rather than being re-pinned.
#
# Idempotence and locking: provision, wake, sleep, and destroy each take the
# per-second mate lifecycle lock in <FM_HOME>/state, so two concurrent wakes can
# never create two pods for one second mate and lifecycle mutations cannot race.
#
# Sleep is guarded by the same conditions bin/fm-teardown.sh refuses a remote
# retirement for - remote child work, an unfinished backlog outbox, an
# unresolved routed reply, an unhandled captured reply, and an unresolved
# decision - and additionally refuses when any remote call returns SSH status
# 255, because unknown remote completion must be reconciled on the same host.
# Sleep never retires the logical second mate: the route, the registry record,
# the reply cursor, and the volume all survive it.
#
# Automatic idle sleep is deliberately NOT implemented. Every suspension is an
# explicit `sleep` from an operator or from firstmate, so a second mate is never
# taken away mid-thought. Nothing in this repo schedules or triggers one.
#
# Environment overrides (tests and self-hosted API mirrors only):
#   FM_RUNPOD_API_BASE      REST base URL, default https://rest.runpod.io/v1
#   FM_RUNPOD_CURL_BIN      curl executable, default curl
#   FM_RUNPOD_SSH_BIN       ssh executable, default $FM_SSH_BIN or ssh
#   FM_RUNPOD_KEYSCAN_BIN   ssh-keyscan executable, default ssh-keyscan
#   FM_RUNPOD_WAKE_TIMEOUT  seconds to wait for endpoint and SSH, default 300
#   FM_RUNPOD_POLL_INTERVAL seconds between wake polls, default 5
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
REG="$DATA/secondmates.md"

API_BASE=${FM_RUNPOD_API_BASE:-https://rest.runpod.io/v1}
CURL_BIN=${FM_RUNPOD_CURL_BIN:-curl}
SSH_BIN=${FM_RUNPOD_SSH_BIN:-${FM_SSH_BIN:-ssh}}
KEYSCAN_BIN=${FM_RUNPOD_KEYSCAN_BIN:-ssh-keyscan}
WAKE_TIMEOUT=${FM_RUNPOD_WAKE_TIMEOUT:-300}
POLL_INTERVAL=${FM_RUNPOD_POLL_INTERVAL:-5}
API_KEY_FILE="$CONFIG/runpod.env"
API_KEY_NAME=RUNPOD_API_KEY
SSH_DIR="$CONFIG/runpod"
SSH_FRAGMENT_DIR="$SSH_DIR/ssh.d"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
# Ubuntu 22.04 (glibc 2.35) is required, not merely preferred: the pinned
# treehouse build needs GLIBC_2.34, so the older Ubuntu 20.04 base (glibc 2.31)
# downloaded it successfully and then could not execute it, which failed a live
# pilot's first-boot provisioning. This tag is an official RunPod base with no
# GPU stack, and is smaller than the 20.04 image it replaces.
DEFAULT_IMAGE=${FM_RUNPOD_DEFAULT_IMAGE:-runpod/base:1.0.7-dev-nix-ubuntu2204}
DEFAULT_SIZE_GB=100

# shellcheck source=bin/fm-runpod-lib.sh
. "$SCRIPT_DIR/fm-runpod-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# status_open_decisions lives with the shared wake-classification vocabulary.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
note() { printf '%s\n' "$1"; }

TMP=
LIFECYCLE_LOCK=
LIFECYCLE_LOCK_HELD=0
VOLUME_LOCK=
VOLUME_LOCK_HELD=0
DELIVERY_LOCK=
DELIVERY_LOCK_HELD=0
KNOWN_HOSTS_LOCK=
KNOWN_HOSTS_LOCK_HELD=0
REPLY_LOCK=
REPLY_LOCK_HELD=0
cleanup() {
  [ -z "$TMP" ] || rm -rf -- "$TMP"
  if [ "$REPLY_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$REPLY_LOCK" || true
    REPLY_LOCK_HELD=0
  fi
  if [ "$KNOWN_HOSTS_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$KNOWN_HOSTS_LOCK" || true
    KNOWN_HOSTS_LOCK_HELD=0
  fi
  if [ "$VOLUME_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$VOLUME_LOCK" || true
    VOLUME_LOCK_HELD=0
  fi
  if [ "$LIFECYCLE_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$LIFECYCLE_LOCK" || true
    LIFECYCLE_LOCK_HELD=0
  fi
  if [ "$DELIVERY_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$DELIVERY_LOCK" || true
    DELIVERY_LOCK_HELD=0
  fi
}
trap cleanup EXIT

stage() {
  [ -n "$TMP" ] && return 0
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-runpod.XXXXXX") || die "cannot create a staging directory"
}

require_id() {
  fm_runpod_id_safe "${1:-}" || die "invalid secondmate id: ${1:-}"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required to read RunPod API responses"
}

lifecycle_lock_acquire() {  # <id>
  mkdir -p "$STATE" || die "cannot create the state directory: $STATE"
  LIFECYCLE_LOCK=$(fm_runpod_lifecycle_lock_path "$STATE" "$1") \
    || die "cannot derive the lifecycle lock path for $1"
  fm_lock_acquire_wait "$LIFECYCLE_LOCK" \
    || die "cannot lock the RunPod lifecycle for $1"
  LIFECYCLE_LOCK_HELD=1
}

volume_lock_acquire() {
  mkdir -p "$STATE" || die "cannot create the state directory: $STATE"
  VOLUME_LOCK="$STATE/.runpod-volume-ownership.lock"
  fm_lock_acquire_wait "$VOLUME_LOCK" || die "cannot lock RunPod volume ownership"
  VOLUME_LOCK_HELD=1
}

volume_lock_release() {
  [ "$VOLUME_LOCK_HELD" -eq 1 ] || return 0
  fm_lock_release "$VOLUME_LOCK"
  VOLUME_LOCK_HELD=0
}

delivery_lock_acquire() {  # <id>
  DELIVERY_LOCK=$(secondmate_handoff_lock_path "$STATE" "$1")
  fm_lock_acquire_wait "$DELIVERY_LOCK" || die "cannot lock delivery for secondmate $1"
  DELIVERY_LOCK_HELD=1
}

known_hosts_lock_acquire() {
  KNOWN_HOSTS_LOCK="$STATE/.runpod-known-hosts.lock"
  fm_lock_acquire_wait "$KNOWN_HOSTS_LOCK" || die "cannot lock RunPod SSH host identities"
  KNOWN_HOSTS_LOCK_HELD=1
}

known_hosts_lock_release() {
  [ "$KNOWN_HOSTS_LOCK_HELD" -eq 1 ] || return 0
  fm_lock_release "$KNOWN_HOSTS_LOCK"
  KNOWN_HOSTS_LOCK_HELD=0
}

# --- record -----------------------------------------------------------------

record_path() {  # <id>
  fm_runpod_meta_path "$DATA" "$1" || die "cannot derive the RunPod record path for $1"
}

record_require() {  # <id>
  fm_runpod_is_managed "$DATA" "$1" \
    || die "secondmate $1 has no RunPod record at $(record_path "$1"); run 'fm-runpod.sh provision $1' first"
}

record_get() {  # <id> <key>
  fm_runpod_field "$DATA" "$1" "$2" 2>/dev/null || true
}

# Rewrite the record atomically with the given key=value pairs replaced or
# appended, preserving every other field and its order.
record_set() {  # <id> <key=value>...
  local id=$1 path tmp kv key line keys=' '
  shift
  path=$(record_path "$id")
  mkdir -p "$(dirname "$path")" || die "cannot create the RunPod record directory"
  chmod 700 "$(dirname "$path")" 2>/dev/null || true
  [ ! -L "$path" ] || die "RunPod record is a symlink: $path"
  tmp="$path.tmp.$$"
  for kv in "$@"; do
    key=${kv%%=*}
    keys="$keys$key "
  done
  if [ -f "$path" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      key=${line%%=*}
      case "$keys" in *" $key "*) continue ;; esac
      printf '%s\n' "$line"
    done < "$path" > "$tmp"
  else
    : > "$tmp"
  fi
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$tmp"
  done
  printf 'updated=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$tmp"
  chmod 600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the RunPod record"; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; die "cannot commit the RunPod record"; }
}

record_set_lifecycle() {  # <id> <lifecycle>
  record_set "$1" "lifecycle=$2"
}

assert_volume_owner() {  # <id> <volume-id>
  local id=$1 volume_id=$2 path owner count claimed
  [ -d "$DATA/runpod" ] || return 0
  for path in "$DATA/runpod"/*.meta; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || die "RunPod record is unsafe: $path"
    owner=$(basename "$path" .meta)
    fm_runpod_id_safe "$owner" || die "RunPod record has an unsafe secondmate id: $path"
    [ "$owner" != "$id" ] || continue
    count=$(grep -c '^volume_id=' "$path" 2>/dev/null || true)
    [ "$count" -le 1 ] || die "RunPod record has ambiguous volume ownership: $path"
    [ "$count" -eq 1 ] || continue
    claimed=$(sed -n 's/^volume_id=//p' "$path")
    [ "$claimed" != "$volume_id" ] \
      || die "network volume $volume_id is already owned by secondmate $owner; one RunPod volume cannot be shared across secondmates"
  done
}

assert_alias_owner() {  # <id> <ssh-alias>
  local id=$1 alias=$2 path owner count claimed
  [ -d "$DATA/runpod" ] || return 0
  for path in "$DATA/runpod"/*.meta; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -f "$path" ] && [ ! -L "$path" ] || die "RunPod record is unsafe: $path"
    owner=$(basename "$path" .meta)
    fm_runpod_id_safe "$owner" || die "RunPod record has an unsafe secondmate id: $path"
    [ "$owner" != "$id" ] || continue
    count=$(grep -c '^ssh_alias=' "$path" 2>/dev/null || true)
    [ "$count" -le 1 ] || die "RunPod record has ambiguous SSH alias ownership: $path"
    [ "$count" -eq 1 ] || continue
    claimed=$(sed -n 's/^ssh_alias=//p' "$path")
    [ "$claimed" != "$alias" ] \
      || die "SSH alias $alias is already owned by secondmate $owner; one RunPod alias cannot be shared across secondmates"
  done
}

# --- RunPod API boundary ----------------------------------------------------
#
# Every RunPod call goes through here, so the whole provider has exactly one
# seam to mock. It prints the response body followed by a final line holding the
# HTTP status, and returns non-zero only when the transport itself failed.
# api_body and api_status split that; nothing carries the status in a global,
# because every caller reads this through a command substitution.

# The credential file is PARSED, never sourced, so a stray line in it can never
# execute anything. It is the ordinary KEY=value env shape: the first
# RUNPOD_API_KEY assignment wins, an optional `export ` prefix is accepted, and
# surrounding single or double quotes are stripped.
api_key_read() {
  local line key mode
  [ -f "$API_KEY_FILE" ] && [ ! -L "$API_KEY_FILE" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$API_KEY_FILE" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$API_KEY_FILE" 2>/dev/null) || return 1
  fi
  [ "$mode" = 600 ] || return 1
  line=$(sed -n "s/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}${API_KEY_NAME}[[:space:]]*=//p" \
    "$API_KEY_FILE" 2>/dev/null | head -1) || true
  key=$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$key" in
    \"*\") key=${key#\"}; key=${key%\"} ;;
    \'*\') key=${key#\'}; key=${key%\'} ;;
  esac
  [ -n "$key" ] || return 1
  printf '%s' "$key"
}

# Checked in the main shell, before any command substitution, so a missing key
# is one clear refusal and never an unauthenticated request that comes back as
# a confusing 401. Every command that touches the API calls this first.
require_api_key() {
  api_key_read >/dev/null \
    || die "no usable $API_KEY_NAME in $API_KEY_FILE; add a '$API_KEY_NAME=<key>' line there (mode 600) and retry"
}

runpod_api() {  # <method> <path> [json-body] [timeout] -> "<body>\n<http-status>"
  local method=$1 path=$2 body=${3:-} timeout=${4:-} key cfg out rc=0 bodyfile
  stage
  key=$(api_key_read) || return 1
  cfg="$TMP/curl.cfg"
  bodyfile="$TMP/curl.body"
  (
    umask 077
    {
      printf 'silent\n'
      printf 'show-error\n'
      printf 'header = "Authorization: Bearer %s"\n' "$key"
      printf 'header = "Content-Type: application/json"\n'
      printf 'request = "%s"\n' "$method"
      printf 'url = "%s%s"\n' "$API_BASE" "$path"
      printf 'write-out = "\\n%%{http_code}"\n'
      if [ -n "$timeout" ]; then
        printf 'connect-timeout = "%s"\n' "$timeout"
        printf 'max-time = "%s"\n' "$timeout"
      fi
      if [ -n "$body" ]; then
        printf '%s' "$body" > "$bodyfile"
        printf 'data-binary = "@%s"\n' "$bodyfile"
      fi
    } > "$cfg"
  )
  chmod 600 "$cfg" 2>/dev/null || true
  out=$("$CURL_BIN" --config "$cfg" 2>&1) || rc=$?
  rm -f -- "$cfg" "$bodyfile"
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s' "$out"
}

api_status() { printf '%s' "$1" | tail -1; }
api_body() { printf '%s' "$1" | sed '$d'; }

api_ok() {  # <status>
  case "${1:-}" in 2??) return 0 ;; esac
  return 1
}

api_call_or_die() {  # <method> <path> [body] <what> [timeout]
  local method=$1 path=$2 body=$3 what=$4 timeout=${5:-} raw status
  raw=$(runpod_api "$method" "$path" "$body" "$timeout") \
    || die "the RunPod API could not be reached while $what"
  status=$(api_status "$raw")
  if ! api_ok "$status"; then
    api_body "$raw" >&2
    die "RunPod refused while $what (HTTP ${status:-unknown})"
  fi
  api_body "$raw"
}

json_field() {  # <json> <jq-filter>
  printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null || true
}

# --- SSH surface ------------------------------------------------------------

ssh_fragment_path() {  # <alias>
  printf '%s/%s.conf\n' "$SSH_FRAGMENT_DIR" "$1"
}

ssh_fragment_write() {  # <alias> <host> <port> <user> <identity>
  local alias=$1 host=$2 port=$3 user=$4 identity=$5 path tmp
  mkdir -p "$SSH_FRAGMENT_DIR" || die "cannot create the SSH fragment directory"
  chmod 700 "$SSH_DIR" "$SSH_FRAGMENT_DIR" 2>/dev/null || true
  path=$(ssh_fragment_path "$alias")
  [ ! -L "$path" ] || die "SSH fragment is a symlink: $path"
  tmp="$path.tmp.$$"
  {
    printf '# Generated by bin/fm-runpod.sh for remote secondmate %s.\n' "$alias"
    printf '# Regenerated on every wake; edit fm-runpod.sh, never this file.\n'
    printf 'Host %s\n' "$alias"
    printf '  HostName %s\n' "$host"
    printf '  Port %s\n' "$port"
    printf '  User %s\n' "$user"
    printf '  HostKeyAlias %s\n' "$alias"
    printf '  UserKnownHostsFile %s\n' "$KNOWN_HOSTS"
    printf '  StrictHostKeyChecking yes\n'
    printf '  ForwardAgent no\n'
    [ -z "$identity" ] || printf '  IdentityFile %s\n' "$identity"
    [ -z "$identity" ] || printf '  IdentitiesOnly yes\n'
  } > "$tmp"
  chmod 600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the SSH fragment"; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; die "cannot commit the SSH fragment"; }
}

known_hosts_has_alias() {  # <alias>
  [ -f "$KNOWN_HOSTS" ] || return 1
  awk -v alias="$1" '$1 == alias { found = 1; exit } END { exit !found }' \
    "$KNOWN_HOSTS" 2>/dev/null
}

# Pin the pod's host key under the stable alias, once. A volume that already
# carries a persisted host key restores the SAME key on every later pod, so the
# pinned entry keeps verifying and a mismatch is a real failure, not a rotation.
known_hosts_pin() {  # <alias> <host> <port> <timeout>
  local alias=$1 host=$2 port=$3 scan_timeout=$4 scanned tmp
  mkdir -p "$SSH_DIR" || die "cannot create the SSH state directory"
  chmod 700 "$SSH_DIR" 2>/dev/null || true
  scanned=$("$KEYSCAN_BIN" -T "$scan_timeout" -p "$port" "$host" 2>/dev/null | grep -v '^#' | head -20) || true
  [ -n "$scanned" ] || return 1
  known_hosts_lock_acquire
  known_hosts_has_alias "$alias" && { known_hosts_lock_release; return 0; }
  [ ! -L "$KNOWN_HOSTS" ] || die "known_hosts is a symlink: $KNOWN_HOSTS"
  stage
  tmp="$TMP/known_hosts.new"
  [ ! -f "$KNOWN_HOSTS" ] || cat "$KNOWN_HOSTS" > "$tmp"
  printf '%s\n' "$scanned" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s %s\n' "$alias" "${line#* }" >> "$tmp"
  done
  chmod 600 "$tmp" || die "cannot secure the pinned host key"
  mv -f -- "$tmp" "$KNOWN_HOSTS" || die "cannot commit the pinned host key"
  known_hosts_lock_release
  note "pinned: first-wake host key for $alias (persisted on the volume for every later pod)"
}

known_hosts_remove_alias() {  # <alias>
  local alias=$1 tmp
  known_hosts_lock_acquire
  if [ ! -e "$KNOWN_HOSTS" ] && [ ! -L "$KNOWN_HOSTS" ]; then
    known_hosts_lock_release
    return 0
  fi
  [ -f "$KNOWN_HOSTS" ] && [ ! -L "$KNOWN_HOSTS" ] || die "known_hosts is unsafe: $KNOWN_HOSTS"
  tmp="$KNOWN_HOSTS.tmp.$$"
  awk -v alias="$alias" '$1 != alias' "$KNOWN_HOSTS" > "$tmp" \
    || { rm -f -- "$tmp"; die "cannot remove the pinned host key for $alias"; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the updated known_hosts"; }
  mv -f -- "$tmp" "$KNOWN_HOSTS" || { rm -f -- "$tmp"; die "cannot commit the updated known_hosts"; }
  known_hosts_lock_release
}

# The probe reads the generated fragment directly and requires the boot marker
# written only after the doctor-owned readiness handoff succeeds.
ssh_probe() {  # <alias> <timeout>
  "$SSH_BIN" -o BatchMode=yes -o "ConnectTimeout=$2" \
    -F "$(ssh_fragment_path "$1")" "$1" \
    test -f /workspace/persistent-runtime/boot.ready >/dev/null 2>&1
}

# --- route binding ----------------------------------------------------------

route_alias() {  # <id> -> registry host alias when a route exists
  secondmate_registry_field "$REG" "$1" host 2>/dev/null || true
}

route_is_remote() {  # <id>
  [ "$(secondmate_registry_field "$REG" "$1" remote 2>/dev/null || true)" = 1 ]
}

# The recorded alias and the registry route must agree, or an SSH fragment
# could be regenerated for a host this record does not own.
alias_for() {  # <id>
  local id=$1 recorded route
  recorded=$(record_get "$id" ssh_alias)
  [ -n "$recorded" ] || die "secondmate $id has no recorded SSH alias; re-run provision"
  if route_is_remote "$id"; then
    route=$(route_alias "$id")
    [ "$route" = "$recorded" ] \
      || die "secondmate $id is routed to SSH alias '$route' but its RunPod record names '$recorded'; reconcile them before waking"
  fi
  printf '%s' "$recorded"
}

# --- provision --------------------------------------------------------------

cmd_provision() {
  local id=${1:-} size=$DEFAULT_SIZE_GB image=$DEFAULT_IMAGE user=root
  local datacenter='' alias='' volume_name='' identity='' code_origin='' code_origin_set=0 harness_npm=''
  shift || true
  require_id "$id"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --size) [ "$#" -ge 2 ] || usage; size=$2; shift 2 ;;
      --datacenter) [ "$#" -ge 2 ] || usage; datacenter=$2; shift 2 ;;
      --alias) [ "$#" -ge 2 ] || usage; alias=$2; shift 2 ;;
      --volume-name) [ "$#" -ge 2 ] || usage; volume_name=$2; shift 2 ;;
      --user) [ "$#" -ge 2 ] || usage; user=$2; shift 2 ;;
      --identity) [ "$#" -ge 2 ] || usage; identity=$2; shift 2 ;;
      --image) [ "$#" -ge 2 ] || usage; image=$2; shift 2 ;;
      --code-origin) [ "$#" -ge 2 ] || usage; code_origin=$2; code_origin_set=1; shift 2 ;;
      --harness-npm) [ "$#" -ge 2 ] || usage; harness_npm=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$size" in ''|*[!0-9]*) die "--size must be a whole number of gigabytes" ;; esac
  [ "$size" -ge 1 ] && [ "$size" -le 4000 ] || die "--size must be between 1 and 4000 GB"
  case "$user" in ''|*[!A-Za-z0-9._-]*) die "--user must be a plain account name" ;; esac
  [ "$user" = root ] || die "only the root account is supported because pod boot prepares root for durable SSH login"
  [ "$code_origin_set" -eq 0 ] || [ -n "$code_origin" ] || die "--code-origin cannot be empty"
  if [ -n "$identity" ]; then
    case "$identity" in /*) ;; *) die "--identity must be an absolute path" ;; esac
  fi
  require_jq
  require_api_key

  if [ -z "$alias" ]; then
    alias=$(route_alias "$id")
    [ -n "$alias" ] || alias="fm-sm-$id-runpod"
  fi
  case "$alias" in ''|-*|*[!A-Za-z0-9._-]*) die "invalid SSH alias: $alias" ;; esac
  [ -n "$volume_name" ] || volume_name="fm-sm-$id-runpod"
  case "$volume_name" in *[!A-Za-z0-9._-]*) die "invalid volume name: $volume_name" ;; esac

  lifecycle_lock_acquire "$id"
  volume_lock_acquire

  local existing_volume existing_alias existing_dc volumes match existing_pod existing_origin existing_harness collision_volume_id
  existing_volume=$(record_get "$id" volume_id)
  existing_alias=$(record_get "$id" ssh_alias)
  if [ -n "$existing_volume" ] && [ -n "$existing_alias" ] && [ "$existing_alias" != "$alias" ]; then
    die "secondmate $id already owns SSH alias $existing_alias; destroy and reprovision it before assigning a different alias"
  fi
  assert_alias_owner "$id" "$alias"
  if [ -n "$existing_volume" ]; then
    assert_volume_owner "$id" "$existing_volume"
    volumes=$(api_call_or_die GET /networkvolumes '' "listing network volumes")
    match=$(printf '%s' "$volumes" | jq -r --arg id "$existing_volume" \
      '(if type == "array" then . else (.data // []) end) | map(select(.id == $id)) | .[0] // empty' 2>/dev/null || true)
    if [ -n "$match" ]; then
      existing_pod=$(record_get "$id" pod_id)
      existing_origin=$(record_get "$id" code_origin)
      existing_harness=$(record_get "$id" harness_npm)
      if [ "$code_origin_set" -eq 0 ]; then
        [ -n "$existing_origin" ] \
          || die "secondmate $id has no recorded code origin; rerun provision with --code-origin before wake"
        code_origin=$existing_origin
      fi
      if [ -n "$existing_pod" ] \
        && { [ "$existing_origin" != "$code_origin" ] || [ "$existing_harness" != "$harness_npm" ]; }; then
        die "secondmate $id has live pod $existing_pod; run 'fm-runpod.sh sleep $id' before changing --code-origin or --harness-npm"
      fi
      existing_dc=$(json_field "$match" '.dataCenterId')
      record_set "$id" "ssh_alias=$alias" "ssh_user=$user" "ssh_identity=$identity" "image=$image" \
        "code_origin=$code_origin" "harness_npm=$harness_npm"
      note "reused: volume $existing_volume in ${existing_dc:-unknown} for secondmate $id"
      note "alias=$alias"
      return 0
    fi
    die "secondmate $id records volume $existing_volume, but RunPod does not list it; investigate before reprovisioning"
  fi

  # Reuse a volume this home previously created under the same name rather than
  # accumulating one per provision attempt.
  volumes=$(api_call_or_die GET /networkvolumes '' "listing network volumes")
  match=$(printf '%s' "$volumes" | jq -r --arg n "$volume_name" \
    '(if type == "array" then . else (.data // []) end) | map(select(.name == $n)) | .[0] // empty' 2>/dev/null || true)
  if [ -z "$match" ]; then
    [ -n "$code_origin" ] \
      || die "--code-origin is required before creating fresh network volume $volume_name"
    [ -n "$datacenter" ] || die "--datacenter is required to create a new network volume (for example EU-RO-1)"
    case "$datacenter" in ''|*[!A-Za-z0-9-]*) die "invalid datacenter id: $datacenter" ;; esac
    match=$(api_call_or_die POST /networkvolumes \
      "$(jq -nc --arg n "$volume_name" --arg dc "$datacenter" --argjson s "$size" \
        '{name: $n, size: $s, dataCenterId: $dc}')" \
      "creating network volume $volume_name")
    note "created: network volume $volume_name"
  else
    collision_volume_id=$(json_field "$match" '.id')
    [ -n "$collision_volume_id" ] || die "RunPod returned a same-name network volume with no id"
    assert_volume_owner "$id" "$collision_volume_id"
    die "unowned name collision: RunPod already has network volume $volume_name, but this home has no local ownership record for it; choose a different --volume-name or investigate the existing volume"
  fi
  local volume_id volume_dc volume_size
  volume_id=$(json_field "$match" '.id')
  volume_dc=$(json_field "$match" '.dataCenterId')
  volume_size=$(json_field "$match" '.size')
  [ -n "$volume_id" ] || die "RunPod returned a network volume with no id"
  assert_volume_owner "$id" "$volume_id"
  [ -n "$volume_dc" ] || volume_dc=$datacenter
  [ -n "$volume_size" ] || volume_size=$size

  record_set "$id" \
    "schema=fm-runpod-secondmate.v1" \
    "provider=runpod" \
    "secondmate=$id" \
    "lifecycle=provisioned" \
    "volume_id=$volume_id" \
    "volume_name=$volume_name" \
    "volume_size_gb=$volume_size" \
    "datacenter=$volume_dc" \
    "pod_id=" \
    "endpoint_host=" \
    "endpoint_port=" \
    "compute=" \
    "gpu_type=" \
    "min_vram_gb=" \
    "image=$image" \
    "code_origin=$code_origin" \
    "harness_npm=$harness_npm" \
    "ssh_alias=$alias" \
    "ssh_user=$user" \
    "ssh_identity=$identity" \
    "cost_per_hr=" \
    "pod_started_at="
  note "provisioned: secondmate $id volume=$volume_id datacenter=$volume_dc size=${volume_size}GB"
  note "alias=$alias"
  note "next: fm-runpod.sh wake $id, then seed or launch the remote second mate on that alias"
}

# --- wake -------------------------------------------------------------------

# RunPod caps a pod's container disk at 40 GB and refuses creation outright
# above it ("Container Disk must be less than or equal to 40", HTTP 500), so the
# pod bodies below use that ceiling. Durable state lives on the network volume
# rather than the container disk, so the cap costs this provider nothing.

# GPU candidates for --min-vram, ascending by memory. This is a convenience
# filter over RunPod's own published GPU type ids, not an authority on what is
# available: the created pod still passes gpuTypePriority=availability, so
# RunPod picks among the candidates. --gpu-type overrides the filter entirely,
# and a --min-vram with no candidate at or above it fails closed rather than
# quietly renting something smaller.
gpu_type_catalog() {
  cat <<'EOF'
16	NVIDIA RTX A4000
16	Tesla T4
24	NVIDIA L4
24	NVIDIA RTX A5000
24	NVIDIA GeForce RTX 3090
24	NVIDIA GeForce RTX 4090
32	NVIDIA GeForce RTX 5090
48	NVIDIA RTX A6000
48	NVIDIA L40S
48	NVIDIA RTX 6000 Ada Generation
80	NVIDIA A100 80GB PCIe
80	NVIDIA A100-SXM4-80GB
80	NVIDIA H100 PCIe
80	NVIDIA H100 80GB HBM3
141	NVIDIA H200
180	NVIDIA B200
EOF
}

gpu_types_at_least() {  # <gb> -> one candidate id per line
  local want=$1 gb name
  while IFS=$'\t' read -r gb name; do
    [ -n "$name" ] || continue
    [ "$gb" -ge "$want" ] || continue
    printf '%s\n' "$name"
  done < <(gpu_type_catalog)
}

# The pod runs the tracked boot script, delivered as one base64 environment
# value, so the container image needs nothing preinstalled from this repo and
# the boot contract stays versioned with the code that creates the pod.
pod_boot_env() {
  [ -f "$SCRIPT_DIR/fm-runpod-pod-boot.sh" ] \
    || die "the pod boot script is missing: $SCRIPT_DIR/fm-runpod-pod-boot.sh"
  base64 < "$SCRIPT_DIR/fm-runpod-pod-boot.sh" | tr -d '\n'
}

pod_create_body() {  # <id> <compute> <gpu-type> <min-vram>
  local id=$1 compute=$2 gpu_type=$3 min_vram=$4 volume_id datacenter image boot candidates
  local code_origin harness_npm
  code_origin=$(record_get "$id" code_origin)
  harness_npm=$(record_get "$id" harness_npm)
  volume_id=$(record_get "$id" volume_id)
  datacenter=$(record_get "$id" datacenter)
  image=$(record_get "$id" image)
  [ -n "$image" ] || image=$DEFAULT_IMAGE
  boot=$(pod_boot_env "$id")
  if [ "$compute" = gpu ]; then
    if [ -n "$gpu_type" ]; then
      candidates=$(jq -nc --arg g "$gpu_type" '[$g]')
    elif [ -n "$min_vram" ]; then
      candidates=$(gpu_types_at_least "$min_vram" | jq -Rnc '[inputs | select(length > 0)]')
      [ "$candidates" != '[]' ] \
        || die "no known GPU type has at least ${min_vram}GB of VRAM; pass --gpu-type with an exact RunPod GPU id instead"
    else
      candidates='[]'
    fi
  else
    candidates='[]'
  fi
  jq -nc \
    --arg name "fm-sm-$id" --arg image "$image" --arg vol "$volume_id" --arg dc "$datacenter" \
    --arg boot "$boot" --arg compute "$compute" --argjson gpus "$candidates" --arg vram "${min_vram:-}" \
    --arg origin "$code_origin" --arg harness "$harness_npm" \
    '(if $compute == "gpu" then
        {computeType: "GPU", gpuCount: 1, gpuTypeIds: $gpus, gpuTypePriority: "availability",
         env: {FM_POD_MIN_VRAM_GB: $vram}}
      else
        {computeType: "CPU", cpuFlavorIds: ["cpu3c"], vcpuCount: 4, env: {}}
      end) as $compute_fields
     | {name: $name, imageName: $image, computeType: $compute_fields.computeType, cloudType: "SECURE"}
       + ($compute_fields | del(.computeType, .env))
       + {
           dataCenterIds: [$dc], networkVolumeId: $vol, volumeMountPath: "/workspace",
           containerDiskInGb: 40, ports: ["22/tcp"], supportPublicIp: true,
           env: ({FM_POD_BOOT_B64: $boot} + $compute_fields.env
                 + {FM_REMOTE_ORIGIN: $origin, FM_POD_HARNESS_NPM: $harness}),
           dockerStartCmd: ["/bin/bash","-c","printf %s \"$FM_POD_BOOT_B64\" | base64 --decode > /tmp/fm-pod-boot.sh 2>/dev/null || printf %s \"$FM_POD_BOOT_B64\" | base64 -D > /tmp/fm-pod-boot.sh; exec /bin/bash /tmp/fm-pod-boot.sh"]
         }'
}

pod_get() {  # <pod-id> [timeout] -> body, or empty when the pod is gone
  local raw status
  raw=$(runpod_api GET "/pods/$1" '' "${2:-}") || return 1
  status=$(api_status "$raw")
  case "$status" in
    404) printf '' ; return 0 ;;
    2??) api_body "$raw" ; return 0 ;;
  esac
  api_body "$raw" >&2
  return 1
}

cmd_wake() {
  local id=${1:-} want_gpu=0
  local min_vram='' gpu_type=''
  shift || true
  require_id "$id"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --gpu) want_gpu=1; shift ;;
      --min-vram) [ "$#" -ge 2 ] || usage; min_vram=$2; want_gpu=1; shift 2 ;;
      --gpu-type) [ "$#" -ge 2 ] || usage; gpu_type=$2; want_gpu=1; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -z "$min_vram" ] || case "$min_vram" in *[!0-9]*) die "--min-vram must be a whole number of gigabytes" ;; esac
  require_jq
  require_api_key
  record_require "$id"
  lifecycle_lock_acquire "$id"

  local compute alias volume_id host port pod_id pod body status recorded_compute deadline remaining delay
  deadline=$((SECONDS + WAKE_TIMEOUT))
  compute=cpu
  [ "$want_gpu" -eq 0 ] || compute=gpu
  alias=$(alias_for "$id")
  volume_id=$(record_get "$id" volume_id)
  [ -n "$volume_id" ] || die "secondmate $id has no recorded network volume; re-run provision"
  volume_lock_acquire
  assert_volume_owner "$id" "$volume_id"
  assert_alias_owner "$id" "$alias"
  volume_lock_release

  # Confirm the volume still exists before creating anything that would attach it.
  local volumes match
  remaining=$((deadline - SECONDS))
  [ "$remaining" -gt 0 ] || die "wake for secondmate $id exceeded ${WAKE_TIMEOUT}s before volume verification"
  volumes=$(api_call_or_die GET /networkvolumes '' "verifying the network volume for $id" "$remaining")
  match=$(printf '%s' "$volumes" | jq -r --arg v "$volume_id" \
    '(if type == "array" then . else (.data // []) end) | map(select(.id == $v)) | .[0] // empty' 2>/dev/null || true)
  [ -n "$match" ] || die "network volume $volume_id for secondmate $id no longer exists on RunPod; refusing to wake"

  pod_id=$(record_get "$id" pod_id)
  recorded_compute=$(record_get "$id" compute)
  if [ -n "$pod_id" ]; then
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] || die "wake for secondmate $id exceeded ${WAKE_TIMEOUT}s before reading pod $pod_id"
    pod=$(pod_get "$pod_id" "$remaining") || die "the RunPod API could not be reached while reading pod $pod_id"
    if [ -n "$pod" ]; then
      status=$(json_field "$pod" '.desiredStatus')
      if [ "$status" != TERMINATED ]; then
        # A live or stopped pod already owns this second mate's compute. One
        # second mate never runs CPU and GPU pods at the same time.
        if [ -n "$recorded_compute" ] && [ "$recorded_compute" != "$compute" ]; then
          die "secondmate $id already has a $recorded_compute pod ($pod_id); run 'fm-runpod.sh sleep $id' before waking it as $compute"
        fi
        if [ "$status" = EXITED ]; then
          remaining=$((deadline - SECONDS))
          [ "$remaining" -gt 0 ] || die "wake for secondmate $id exceeded ${WAKE_TIMEOUT}s before starting pod $pod_id"
          api_call_or_die POST "/pods/$pod_id/start" '' "starting pod $pod_id" "$remaining" >/dev/null
          note "started: existing pod $pod_id for secondmate $id"
        fi
      else
        pod_id=
      fi
    else
      pod_id=
    fi
  fi

  if [ -z "$pod_id" ]; then
    record_set "$id" "lifecycle=waking" "compute=$compute" "gpu_type=$gpu_type" "min_vram_gb=$min_vram"
    body=$(pod_create_body "$id" "$compute" "$gpu_type" "$min_vram")
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] || die "wake for secondmate $id exceeded ${WAKE_TIMEOUT}s before pod creation"
    pod=$(api_call_or_die POST /pods "$body" "creating a $compute pod for secondmate $id" "$remaining")
    pod_id=$(json_field "$pod" '.id')
    [ -n "$pod_id" ] || die "RunPod returned a pod with no id"
    record_set "$id" "pod_id=$pod_id"
    note "created: $compute pod $pod_id for secondmate $id"
  else
    record_set "$id" "lifecycle=waking" "compute=$compute"
  fi

  # Bounded wait for the endpoint. The pod reports no public IP or port mapping
  # while it is still initializing.
  host=
  port=
  while :; do
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] \
      || die "pod $pod_id did not publish an SSH endpoint within ${WAKE_TIMEOUT}s; it is preserved for inspection"
    pod=$(pod_get "$pod_id" "$remaining") || die "the RunPod API could not be reached while waiting for pod $pod_id"
    [ -n "$pod" ] || die "pod $pod_id disappeared while waking secondmate $id"
    host=$(json_field "$pod" '.publicIp')
    port=$(json_field "$pod" '.portMappings."22"')
    [ -z "$host" ] || [ -z "$port" ] || break
    remaining=$((deadline - SECONDS))
    delay=$POLL_INTERVAL
    [ "$delay" -le "$remaining" ] || delay=$remaining
    [ "$delay" -le 0 ] || sleep "$delay"
  done

  while :; do
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] \
      || die "could not read the pod's SSH host key at $host:$port within ${WAKE_TIMEOUT}s; it is preserved for inspection"
    known_hosts_pin "$alias" "$host" "$port" "$remaining" && break
    remaining=$((deadline - SECONDS))
    delay=$POLL_INTERVAL
    [ "$delay" -le "$remaining" ] || delay=$remaining
    [ "$delay" -le 0 ] || sleep "$delay"
  done
  ssh_fragment_write "$alias" "$host" "$port" \
    "$(record_get "$id" ssh_user)" "$(record_get "$id" ssh_identity)"
  record_set "$id" "endpoint_host=$host" "endpoint_port=$port" \
    "cost_per_hr=$(json_field "$pod" '.costPerHr')" \
    "pod_started_at=$(json_field "$pod" '.lastStartedAt')"

  while :; do
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] \
      || die "pod $pod_id published $host:$port but its SSH bootstrap did not complete within ${WAKE_TIMEOUT}s; it is preserved for inspection"
    ssh_probe "$alias" "$remaining" && break
    remaining=$((deadline - SECONDS))
    delay=$POLL_INTERVAL
    [ "$delay" -le "$remaining" ] || delay=$remaining
    [ "$delay" -le 0 ] || sleep "$delay"
  done

  record_set_lifecycle "$id" ready
  # Sleep quiesced the reply source; the host is back, so re-arm it from the
  # cursor sleep preserved. A route that has not been seeded yet has nothing to
  # arm, which is why this is best effort rather than a wake failure.
  if route_is_remote "$id"; then
    "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm "$id" >/dev/null 2>&1 \
      || note "warning: secondmate $id is awake but its reply source could not be re-armed; run 'bin/fm-spawn.sh $id --secondmate' to reconcile"
  fi
  note "ready: secondmate $id pod=$pod_id compute=$compute endpoint=$host:$port alias=$alias"
}

# --- sleep ------------------------------------------------------------------

remote_children_probe() {  # <id> -> prints the count, or dies
  local id=$1 out rc=0
  out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh children "$id" < /dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 255 ]; then
    die "secondmate $id is unreachable, so its remote work is unknown; refusing to suspend until it is reconciled on that host"
  fi
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    die "could not read remote child work for secondmate $id; refusing to suspend"
  fi
  printf '%s' "$out" | sed -n 's/^children=//p' | tail -1
}

sleep_guards() {  # <id>
  local id=$1 outbox rec phase task_id children open
  # Every guard below except the remote child-work probe reads this home's own
  # durable records, so they apply whether or not a route still exists. The
  # probe needs a route: a second mate already retired through
  # bin/fm-teardown.sh has no remote home left to supervise anything.
  outbox="$DATA/handoff/$id.outbox.md"
  if [ -e "$outbox" ] || [ -L "$outbox" ]; then
    die "secondmate $id still has an undelivered backlog handoff at $outbox; deliver it before suspending"
  fi
  if [ -d "$STATE/pending-replies" ]; then
    for rec in "$STATE/pending-replies"/*; do
      [ -f "$rec" ] || continue
      task_id=$(sed -n 's/^task_id=//p' "$rec" | head -1)
      [ "$task_id" = "$id" ] || continue
      phase=$(sed -n 's/^phase=//p' "$rec" | head -1)
      [ "$phase" = resolved ] \
        || die "secondmate $id still has an unresolved routed reply; wait for it before suspending"
    done
  fi
  open=$(status_open_decisions "$STATE/$id.status")
  [ -z "$open" ] \
    || die "secondmate $id still has unresolved decisions ($open); close them before suspending"
  route_is_remote "$id" || return 0
  children=$(remote_children_probe "$id")
  case "$children" in ''|*[!0-9]*) die "secondmate $id returned an unreadable child-work count; refusing to suspend" ;; esac
  [ "$children" -eq 0 ] \
    || die "secondmate $id still supervises $children worker(s) on its host; finish or land that work before suspending"
}

# A sleep that cannot finish must leave the second mate exactly as it found it:
# awake, with its reply source armed again.
sleep_abort() {  # <id> <message>
  [ "$(fm_runpod_lifecycle "$DATA" "$1")" = ready ] || record_set_lifecycle "$1" ready
  "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm-locked "$1" >/dev/null 2>&1 || true
  die "$2"
}

cmd_sleep() {
  local id=${1:-} pod_id raw rc=0
  shift || true
  [ "$#" -eq 0 ] || usage
  require_id "$id"
  require_jq
  require_api_key
  record_require "$id"
  delivery_lock_acquire "$id"
  lifecycle_lock_acquire "$id"
  case "$(fm_runpod_lifecycle "$DATA" "$id")" in
    suspended)
      note "already-suspended: secondmate $id"
      return 0
      ;;
  esac

  # The reply source polls the host over SSH, so it must be quiesced under the
  # same lock teardown uses before the pod can go away. The cursor is kept, so
  # the next wake resumes the delta read exactly where it stopped.
  REPLY_LOCK=$(secondmate_reply_lifecycle_lock_path "$STATE" "$id")
  fm_lock_acquire_wait "$REPLY_LOCK" || die "cannot lock the reply lifecycle for $id"
  REPLY_LOCK_HELD=1

  sleep_guards "$id"

  if route_is_remote "$id" \
     && ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" retire-quiesce-locked "$id" >/dev/null 2>&1; then
    sleep_abort "$id" "secondmate $id still has an unhandled captured reply; handle it before suspending"
  fi

  if ! (record_set_lifecycle "$id" suspending); then
    sleep_abort "$id" "secondmate $id could not record its suspending lifecycle; it is left running"
  fi
  pod_id=$(record_get "$id" pod_id)
  if [ -n "$pod_id" ]; then
    raw=$(runpod_api DELETE "/pods/$pod_id" '') || rc=$?
    if [ "$rc" -ne 0 ]; then
      sleep_abort "$id" "the RunPod API could not be reached while terminating pod $pod_id; secondmate $id is left running"
    fi
    case "$(api_status "$raw")" in
      2??|404) ;;
      *)
        api_body "$raw" >&2
        sleep_abort "$id" "RunPod refused to terminate pod $pod_id (HTTP $(api_status "$raw")); secondmate $id is left running"
        ;;
    esac
  fi
  record_set "$id" "lifecycle=suspended" "pod_id=" "endpoint_host=" "endpoint_port=" \
    "cost_per_hr=" "pod_started_at="
  note "suspended: secondmate $id pod terminated, volume $(record_get "$id" volume_id) retained, route preserved"
}

# --- status, ssh, doctor, cost, destroy -------------------------------------

status_line() {  # <id>
  local id=$1 lifecycle compute pod endpoint
  lifecycle=$(fm_runpod_lifecycle "$DATA" "$id")
  compute=$(record_get "$id" compute)
  pod=$(record_get "$id" pod_id)
  endpoint=
  [ -z "$(record_get "$id" endpoint_host)" ] \
    || endpoint="$(record_get "$id" endpoint_host):$(record_get "$id" endpoint_port)"
  printf '%s lifecycle=%s compute=%s pod=%s endpoint=%s volume=%s datacenter=%s alias=%s\n' \
    "$id" "${lifecycle:-unknown}" "${compute:--}" "${pod:--}" "${endpoint:--}" \
    "$(record_get "$id" volume_id)" "$(record_get "$id" datacenter)" "$(record_get "$id" ssh_alias)"
}

cmd_status() {
  local id=${1:-} path
  if [ -n "$id" ]; then
    require_id "$id"
    record_require "$id"
    status_line "$id"
    return 0
  fi
  [ -d "$DATA/runpod" ] || { note "no RunPod-backed secondmates in $DATA/runpod"; return 0; }
  for path in "$DATA/runpod"/*.meta; do
    [ -f "$path" ] || continue
    id=$(basename "$path" .meta)
    fm_runpod_id_safe "$id" || continue
    status_line "$id"
  done
}

cmd_ssh() {
  local id=${1:-} alias fragment
  shift || true
  require_id "$id"
  record_require "$id"
  alias=$(alias_for "$id")
  fragment=$(ssh_fragment_path "$alias")
  [ -n "$(record_get "$id" endpoint_host)" ] && [ -n "$(record_get "$id" endpoint_port)" ] \
    && [ -f "$fragment" ] \
    || die "secondmate $id has no reachable SSH endpoint; run 'fm-runpod.sh wake $id' first"
  exec "$SSH_BIN" -F "$fragment" "$alias" "$@"
}

cmd_doctor() {
  local id=${1:-}
  shift || true
  require_id "$id"
  record_require "$id"
  route_is_remote "$id" \
    || die "secondmate $id has no remote route in $REG; seed it before running the readiness check"
  if fm_runpod_is_dormant "$DATA" "$id"; then
    "$0" wake "$id" >&2
  fi
  # Every RunPod host is provisioned for full local-second-mate parity, so the
  # parity tier is this route's default verdict rather than an opt-in. An
  # explicit argument still passes through, including a plain base-tier run.
  [ "$#" -gt 0 ] || set -- --parity
  exec "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-doctor.sh "$@"
}

cmd_cost() {
  local id=${1:-} size storage pod_id pod cost started compute
  shift || true
  [ "$#" -eq 0 ] || usage
  require_id "$id"
  require_jq
  require_api_key
  record_require "$id"
  size=$(record_get "$id" volume_size_gb)
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  if [ "$size" -le 1000 ]; then
    storage=$(awk -v s="$size" 'BEGIN { printf "%.2f", s * 0.07 }')
  else
    storage=$(awk -v s="$size" 'BEGIN { printf "%.2f", 1000 * 0.07 + (s - 1000) * 0.05 }')
  fi
  printf 'secondmate=%s\n' "$id"
  printf 'volume_size_gb=%s\n' "$size"
  printf 'volume_usd_per_month=%s\n' "$storage"
  printf 'idle_usd_per_month=%s  # suspended: storage only, no compute\n' "$storage"
  compute=$(record_get "$id" compute)
  pod_id=$(record_get "$id" pod_id)
  if [ -z "$pod_id" ]; then
    printf 'compute=none  # no pod is running\n'
    return 0
  fi
  pod=$(pod_get "$pod_id") || die "the RunPod API could not be reached while reading pod $pod_id"
  [ -n "$pod" ] || { printf 'compute=none  # recorded pod %s no longer exists\n' "$pod_id"; return 0; }
  cost=$(json_field "$pod" '.costPerHr')
  started=$(json_field "$pod" '.lastStartedAt')
  printf 'compute=%s\n' "${compute:-unknown}"
  printf 'pod=%s\n' "$pod_id"
  printf 'compute_usd_per_hour=%s\n' "${cost:-unknown}"
  printf 'pod_started_at=%s\n' "${started:-unknown}"
  if [ -n "$started" ]; then
    local start_epoch now_epoch
    start_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${started%%.*}" +%s 2>/dev/null \
      || date -u -d "$started" +%s 2>/dev/null || true)
    case "$start_epoch" in
      ''|*[!0-9]*) ;;
      *)
        now_epoch=$(date -u +%s)
        printf 'pod_uptime_hours=%s\n' \
          "$(awk -v a="$now_epoch" -v b="$start_epoch" 'BEGIN { printf "%.2f", (a - b) / 3600 }')"
        ;;
    esac
  fi
}

cmd_destroy() {
  local id=${1:-} confirmed=0 volume_id raw rc=0 path alias
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes) confirmed=1; shift ;;
      *) usage ;;
    esac
  done
  require_id "$id"
  require_jq
  require_api_key
  record_require "$id"
  [ "$confirmed" -eq 1 ] \
    || die "destroy permanently deletes secondmate $id's network volume and everything on it; pass --yes only with the captain's explicit word"
  if route_is_remote "$id"; then
    die "secondmate $id is still a registered remote route; retire it with 'bin/fm-teardown.sh $id' before destroying its volume"
  fi
  lifecycle_lock_acquire "$id"
  [ -z "$(record_get "$id" pod_id)" ] \
    || die "secondmate $id still has pod $(record_get "$id" pod_id); run 'fm-runpod.sh sleep $id' first"
  volume_id=$(record_get "$id" volume_id)
  alias=$(record_get "$id" ssh_alias)
  volume_lock_acquire
  [ -z "$volume_id" ] || assert_volume_owner "$id" "$volume_id"
  [ -z "$alias" ] || assert_alias_owner "$id" "$alias"
  if [ -n "$volume_id" ]; then
    raw=$(runpod_api DELETE "/networkvolumes/$volume_id" '') || rc=$?
    [ "$rc" -eq 0 ] || die "the RunPod API could not be reached while deleting volume $volume_id"
    case "$(api_status "$raw")" in
      2??|404) ;;
      *)
        api_body "$raw" >&2
        die "RunPod refused to delete volume $volume_id (HTTP $(api_status "$raw"))"
        ;;
    esac
  fi
  # Read the alias before the record goes away, or the generated fragment would
  # be orphaned with a stale endpoint in it.
  path=$(record_path "$id")
  [ -z "$alias" ] || known_hosts_remove_alias "$alias"
  rm -f -- "$path"
  [ -z "$alias" ] || rm -f -- "$(ssh_fragment_path "$alias")"
  note "destroyed: secondmate $id volume $volume_id and its local RunPod record"
}

case "${1:-}" in
  provision) shift; [ "$#" -ge 1 ] || usage; cmd_provision "$@" ;;
  wake) shift; [ "$#" -ge 1 ] || usage; cmd_wake "$@" ;;
  sleep) shift; [ "$#" -ge 1 ] || usage; cmd_sleep "$@" ;;
  status) shift; [ "$#" -le 1 ] || usage; cmd_status "${1:-}" ;;
  ssh) shift; [ "$#" -ge 1 ] || usage; cmd_ssh "$@" ;;
  doctor) shift; [ "$#" -ge 1 ] || usage; cmd_doctor "$@" ;;
  cost) shift; [ "$#" -ge 1 ] || usage; cmd_cost "$@" ;;
  destroy) shift; [ "$#" -ge 1 ] || usage; cmd_destroy "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
