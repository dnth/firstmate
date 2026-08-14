#!/usr/bin/env bash
# Workstation-side omp auth-broker and RunPod reverse-tunnel lifecycle.
#
# Usage:
#   fm-runpod-omp-auth.sh start <id> <ssh-alias> <ssh-config>
#   fm-runpod-omp-auth.sh stop <id>
#   fm-runpod-omp-auth.sh status <id>
#   fm-runpod-omp-auth.sh broker-run
#   fm-runpod-omp-auth.sh proxy-run
#   fm-runpod-omp-auth.sh tunnel-run <id> <ssh-alias> <ssh-config>
#
# `start` obtains the existing omp broker bearer without rotating it, stores a
# home-scoped copy at <FM_HOME>/config/runpod/omp-auth-broker.token with mode
# 0600, and sends it over the already host-key-pinned SSH connection to the
# pod boot script's token-install interface.
# The token never appears in argv, logs, generated SSH configuration, RunPod
# environment variables, or tracked files.
#
# One detached broker supervisor keeps `omp auth-broker serve` available on
# workstation loopback.
# One detached proxy supervisor keeps the credential-read-only facade available
# on a second workstation-loopback port.
# One detached tunnel supervisor per pod runs OpenSSH `-R` with dead-peer
# keepalives and restarts it after every drop.
# The pod receives only the facade at its loopback endpoint, never the canonical
# broker port.
#
# `stop` retires only the named pod's tunnel.
# The workstation broker and facade stay available for other RunPod second mates
# and are harmless loopback-only services when no pod is awake.
#
# Environment overrides for tests and self-hosted layouts:
#   FM_RUNPOD_OMP_BIN                    omp executable, default omp
#   FM_RUNPOD_NODE_BIN                   node executable, default node
#   FM_RUNPOD_OMP_CURL_BIN               curl executable, default curl
#   FM_RUNPOD_OMP_SSH_BIN                ssh executable, default ssh
#   FM_RUNPOD_OMP_BROKER_BIND            canonical broker host:port, default 127.0.0.1:8765
#   FM_RUNPOD_OMP_PROXY_BIND             read-only facade host:port, default 127.0.0.1:18766
#   FM_RUNPOD_OMP_REMOTE_BIND            pod tunnel host:port, default 127.0.0.1:8765
#   FM_RUNPOD_OMP_REMOTE_INSTALLER       pod boot control path
#   FM_RUNPOD_OMP_RESTART_DELAY          restart delay in seconds, default 2
#   FM_RUNPOD_OMP_START_TIMEOUT          startup deadline in seconds, default 60
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

OMP_BIN=${FM_RUNPOD_OMP_BIN:-omp}
NODE_BIN=${FM_RUNPOD_NODE_BIN:-node}
CURL_BIN=${FM_RUNPOD_OMP_CURL_BIN:-curl}
SSH_BIN=${FM_RUNPOD_OMP_SSH_BIN:-${FM_SSH_BIN:-ssh}}
BROKER_BIND=${FM_RUNPOD_OMP_BROKER_BIND:-127.0.0.1:8765}
PROXY_BIND=${FM_RUNPOD_OMP_PROXY_BIND:-127.0.0.1:18766}
REMOTE_BIND=${FM_RUNPOD_OMP_REMOTE_BIND:-127.0.0.1:8765}
REMOTE_INSTALLER=${FM_RUNPOD_OMP_REMOTE_INSTALLER:-/workspace/persistent-runtime/fm-runpod-pod-boot.sh}
RESTART_DELAY=${FM_RUNPOD_OMP_RESTART_DELAY:-2}
START_TIMEOUT=${FM_RUNPOD_OMP_START_TIMEOUT:-60}
TOKEN_FILE="$CONFIG/runpod/omp-auth-broker.token"
RUNTIME_DIR="$STATE/runpod-omp-auth"
PROXY_SCRIPT="$SCRIPT_DIR/fm-omp-auth-broker-readonly-proxy.mjs"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
validate_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $1" ;; esac; }

host_port_parts() {  # <host:port>
  case "$1" in
    127.0.0.1:[0-9]*|localhost:[0-9]*) ;;
    *) die "auth-broker endpoints must use a workstation or pod loopback host:port: $1" ;;
  esac
  PORT_PART=${1##*:}
  case "$PORT_PART" in ''|*[!0-9]*) die "invalid auth-broker port: $PORT_PART" ;; esac
  [ "$PORT_PART" -ge 1 ] && [ "$PORT_PART" -le 65535 ] || die "invalid auth-broker port: $PORT_PART"
}

mode_600() {
  if [ "$(uname)" = Darwin ]; then
    [ "$(stat -f %Lp "$1" 2>/dev/null || true)" = 600 ]
  else
    [ "$(stat -c %a "$1" 2>/dev/null || true)" = 600 ]
  fi
}

token_valid() {  # <token>
  [ -n "$1" ] && [ "${#1}" -le 512 ] || return 1
  case "$1" in *[!A-Za-z0-9_-]*) return 1 ;; esac
}

token_sync() {
  local token tmp
  command -v "$OMP_BIN" >/dev/null 2>&1 || die "omp is required on the workstation for RunPod broker authentication"
  token=$("$OMP_BIN" auth-broker token) || die "omp auth-broker token failed"
  token=${token%$'\n'}
  token=${token%$'\r'}
  token_valid "$token" || die "omp auth-broker token returned an invalid bearer"
  if [ -e "$CONFIG/runpod" ] || [ -L "$CONFIG/runpod" ]; then
    if [ ! -d "$CONFIG/runpod" ] || [ -L "$CONFIG/runpod" ]; then
      die "RunPod config directory is unavailable or unsafe: $CONFIG/runpod"
    fi
  else
    mkdir -p "$CONFIG/runpod" || die "cannot create $CONFIG/runpod"
  fi
  chmod 700 "$CONFIG/runpod" || die "cannot secure $CONFIG/runpod"
  tmp=$(mktemp "$CONFIG/runpod/.omp-auth-broker.token.XXXXXX") || die "cannot stage the omp broker token"
  if ! (umask 077; printf '%s' "$token" > "$tmp"); then
    rm -f -- "$tmp"
    die "cannot stage the omp broker token"
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; die "cannot secure the omp broker token"; }
  mv -f -- "$tmp" "$TOKEN_FILE" || { rm -f -- "$tmp"; die "cannot publish the omp broker token"; }
}

token_require() {
  if [ ! -f "$TOKEN_FILE" ] || [ -L "$TOKEN_FILE" ] || ! mode_600 "$TOKEN_FILE"; then
    die "the workstation omp broker token is missing, unsafe, or not mode 0600: $TOKEN_FILE"
  fi
}

runtime_prepare() {
  mkdir -p "$RUNTIME_DIR" || die "cannot create $RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR" || die "cannot secure $RUNTIME_DIR"
}

record_dir() {  # <name>
  printf '%s/%s.lock\n' "$RUNTIME_DIR" "$1"
}

record_alive() {  # <name>
  local dir pid expected current
  dir=$(record_dir "$1")
  pid=$(cat "$dir/pid" 2>/dev/null || true)
  expected=$(cat "$dir/pid-identity" 2>/dev/null || true)
  [ -n "$expected" ] && fm_pid_alive "$pid" || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null || true)
  [ "$current" = "$expected" ]
}

record_claim() {  # <name>
  local name=$1 dir identity
  runtime_prepare
  dir=$(record_dir "$name")
  if ! mkdir "$dir" 2>/dev/null; then
    record_alive "$name" && return 1
    rm -rf -- "$dir" || return 1
    mkdir "$dir" || return 1
  fi
  printf '%s\n' "$$" > "$dir/pid" || return 1
  identity=$(fm_pid_identity "$$") || return 1
  printf '%s\n' "$identity" > "$dir/pid-identity" || return 1
  chmod 700 "$dir"
  chmod 600 "$dir/pid" "$dir/pid-identity"
}

record_release() {  # <name>
  local dir
  dir=$(record_dir "$1")
  [ "$(cat "$dir/pid" 2>/dev/null || true)" != "$$" ] || rm -rf -- "$dir"
}

daemon_start() {  # <name> <command> [args...]
  local name=$1 command=$2 log deadline
  shift 2
  runtime_prepare
  record_alive "$name" && return 0
  rm -rf -- "$(record_dir "$name")"
  log="$RUNTIME_DIR/$name.log"
  nohup "$0" "$command" "$@" </dev/null >> "$log" 2>&1 &
  deadline=$((SECONDS + START_TIMEOUT))
  while ! record_alive "$name"; do
    [ "$SECONDS" -lt "$deadline" ] || die "$name supervisor did not start; inspect $log"
    sleep 0.1
  done
}

daemon_stop() {  # <name>
  local name=$1 dir pid deadline
  record_alive "$name" || { rm -rf -- "$(record_dir "$name")"; return 0; }
  dir=$(record_dir "$name")
  pid=$(cat "$dir/pid")
  kill -TERM "$pid" 2>/dev/null || true
  deadline=$((SECONDS + 10))
  while record_alive "$name"; do
    [ "$SECONDS" -lt "$deadline" ] || die "$name supervisor did not stop"
    sleep 0.1
  done
  rm -rf -- "$dir"
}

broker_url() { printf 'http://%s\n' "$BROKER_BIND"; }
proxy_url() { printf 'http://%s\n' "$PROXY_BIND"; }
remote_url() { printf 'http://%s\n' "$REMOTE_BIND"; }

broker_ready() {
  "$CURL_BIN" -fsS --max-time 2 "$(broker_url)/v1/healthz" >/dev/null 2>&1
}

proxy_ready() {
  "$CURL_BIN" -fsS --max-time 2 "$(proxy_url)/v1/healthz" 2>/dev/null \
    | grep -q '"mode"[[:space:]]*:[[:space:]]*"credential-read-only"'
}

wait_ready() {  # <label> <probe-function>
  local label=$1 probe=$2 deadline
  deadline=$((SECONDS + START_TIMEOUT))
  until "$probe"; do
    [ "$SECONDS" -lt "$deadline" ] || die "$label did not become ready"
    sleep 0.2
  done
}

remote_token_install() {  # <alias> <ssh-config>
  local alias=$1 ssh_config=$2
  token_require
  "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes \
    -F "$ssh_config" "$alias" "$REMOTE_INSTALLER" --install-omp-auth-broker-token \
    < "$TOKEN_FILE" >/dev/null
}

remote_ready() {  # <alias> <ssh-config>
  "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes \
    -F "$2" "$1" "$REMOTE_INSTALLER" --check-omp-auth-broker-client >/dev/null 2>&1
}

cmd_broker_run() {
  local child=0
  record_claim broker || exit 0
  trap 'test "$child" -eq 0 || kill -TERM "$child" 2>/dev/null || true; record_release broker' EXIT
  trap 'exit 0' INT TERM
  while :; do
    if broker_ready; then
      sleep "$RESTART_DELAY"
      continue
    fi
    "$OMP_BIN" auth-broker serve --bind="$BROKER_BIND" &
    child=$!
    wait "$child" || true
    child=0
    sleep "$RESTART_DELAY"
  done
}

cmd_proxy_run() {
  local child=0
  record_claim proxy || exit 0
  trap 'test "$child" -eq 0 || kill -TERM "$child" 2>/dev/null || true; record_release proxy' EXIT
  trap 'exit 0' INT TERM
  token_require
  [ -f "$PROXY_SCRIPT" ] && [ ! -L "$PROXY_SCRIPT" ] || die "read-only auth-broker facade is missing: $PROXY_SCRIPT"
  while :; do
    if proxy_ready; then
      sleep "$RESTART_DELAY"
      continue
    fi
    FM_OMP_AUTH_BROKER_TOKEN_FILE="$TOKEN_FILE" \
      FM_OMP_AUTH_BROKER_UPSTREAM_URL="$(broker_url)" \
      FM_OMP_AUTH_BROKER_PROXY_BIND="$PROXY_BIND" \
      "$NODE_BIN" "$PROXY_SCRIPT" &
    child=$!
    wait "$child" || true
    child=0
    sleep "$RESTART_DELAY"
  done
}

cmd_tunnel_run() {
  local id=$1 alias=$2 ssh_config=$3 name child=0
  validate_id "$id"
  name="tunnel-$id"
  record_claim "$name" || exit 0
  trap 'test "$child" -eq 0 || kill -TERM "$child" 2>/dev/null || true; record_release "$name"' EXIT
  trap 'exit 0' INT TERM
  while :; do
    if ! proxy_ready; then
      sleep "$RESTART_DELAY"
      continue
    fi
    "$SSH_BIN" -N -T -o BatchMode=yes \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -o TCPKeepAlive=yes -F "$ssh_config" \
      -R "$REMOTE_BIND:$PROXY_BIND" "$alias" &
    child=$!
    wait "$child" || true
    child=0
    sleep "$RESTART_DELAY"
  done
}

cmd_start() {
  local id=$1 alias=$2 ssh_config=$3 deadline
  validate_id "$id"
  [ -f "$ssh_config" ] && [ ! -L "$ssh_config" ] || die "SSH config is missing or unsafe: $ssh_config"
  host_port_parts "$BROKER_BIND"
  host_port_parts "$PROXY_BIND"
  host_port_parts "$REMOTE_BIND"
  token_sync
  daemon_start broker broker-run
  wait_ready "workstation omp auth broker" broker_ready
  daemon_start proxy proxy-run
  wait_ready "workstation credential-read-only broker facade" proxy_ready
  remote_token_install "$alias" "$ssh_config" || die "the omp broker token could not be installed on the pod"
  daemon_start "tunnel-$id" tunnel-run "$id" "$alias" "$ssh_config"
  deadline=$((SECONDS + START_TIMEOUT))
  until remote_ready "$alias" "$ssh_config"; do
    [ "$SECONDS" -lt "$deadline" ] || die "the pod could not read the workstation omp auth broker through its reverse tunnel"
    sleep 0.2
  done
  printf 'auth-broker: ready id=%s endpoint=%s mode=credential-read-only\n' "$id" "$(remote_url)"
}

cmd_stop() {
  validate_id "$1"
  daemon_stop "tunnel-$1"
  printf 'auth-broker: tunnel stopped id=%s\n' "$1"
}

cmd_status() {
  local id=$1 name state_value
  validate_id "$id"
  for name in broker proxy "tunnel-$id"; do
    state_value=stopped
    record_alive "$name" && state_value=running
    printf '%s=%s\n' "$name" "$state_value"
  done
  printf 'token_file=%s\n' "$TOKEN_FILE"
  printf 'pod_endpoint=%s\n' "$(remote_url)"
}

case "${1:-}" in
  start) shift; [ "$#" -eq 3 ] || usage; cmd_start "$@" ;;
  stop) shift; [ "$#" -eq 1 ] || usage; cmd_stop "$1" ;;
  status) shift; [ "$#" -eq 1 ] || usage; cmd_status "$1" ;;
  broker-run) shift; [ "$#" -eq 0 ] || usage; cmd_broker_run ;;
  proxy-run) shift; [ "$#" -eq 0 ] || usage; cmd_proxy_run ;;
  tunnel-run) shift; [ "$#" -eq 3 ] || usage; cmd_tunnel_run "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
