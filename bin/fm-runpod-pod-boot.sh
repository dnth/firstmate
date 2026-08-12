#!/usr/bin/env bash
# Reproducible boot for a RunPod Linux container hosting one remote second mate.
#
# bin/fm-runpod.sh sends this exact file to every pod it creates, base64-encoded
# in the FM_POD_BOOT_B64 environment variable, and makes the pod's start command
# decode and exec it. The file is tracked, so the boot contract is versioned with
# the code that creates the pod and the container image needs nothing from this
# repo preinstalled.
#
# It does the smallest thing that makes the pod an ordinary SSH-reachable remote
# second-mate host, then hands over:
#
#   1. Restore the persisted SSH HOST key from the network volume, or generate
#      and persist one on the volume's first boot. This is what keeps strict
#      host-key verification working across pod replacement: the pod's identity
#      lives on the volume, not on the machine.
#   2. Provision the required toolchain and link the fixed remote entrypoint.
#   3. Start sshd with the account's configured public key, then hand readiness
#      to bin/fm-remote-doctor.sh --fix. The doctor is the single owner of what
#      "ready for a remote second mate" means, and on Linux it starts the remote
#      job worker and the headless Herdr fm-remote server itself - no GUI or
#      Aqua session is involved on this platform. Nothing here duplicates those
#      checks.
#   4. Record boot success only after the doctor's handoff succeeds. SSH stays
#      available while human-only gaps remain, but wake never reports ready.
#
# On a volume's first boot the toolchain provisioning step clones the code root
# from FM_REMOTE_ORIGIN and installs the tools bin/fm-remote-doctor.sh requires,
# so a fresh pod reaches readiness without a manual clone.
# docs/runpod-secondmates.md owns the operator sequence.
#
# Toolchain provisioning is idempotent and volume-scoped: a marker on the volume
# records the contract version it satisfied, so later boots skip the work and a
# raised contract version re-provisions exactly once.
#
# bin/fm-remote-doctor.sh remains the single owner of what "ready" means. This
# script installs toward that set and never re-states the verdict; the doctor
# still decides, and tests assert this script covers what the doctor requires.
#
# --check prints the provisioning plan as one `ensure=<item>` line per step and
# exits without touching the system, so the contract is testable with no pod.
#
# The volume is mounted at /workspace. Durable remote state lives under it:
#   /workspace/firstmate            the remote Firstmate code root
#   /workspace/secondmate-home      the persistent FM_HOME, separate from the code root
#   /workspace/persistent-runtime   SSH host keys and selected caches
#
# This script runs as the container's PID 1 payload, so it must never exit while
# the pod should stay up.
set -u

FM_VOLUME=${FM_VOLUME:-/workspace}
FM_REMOTE_ROOT=${FM_REMOTE_ROOT:-$FM_VOLUME/firstmate}
FM_REMOTE_HOME=${FM_REMOTE_HOME:-$FM_VOLUME/secondmate-home}
FM_PERSIST=${FM_PERSIST:-$FM_VOLUME/persistent-runtime}
FM_HOST_KEY_DIR="$FM_PERSIST/ssh"
FM_BOOT_LOG=${FM_BOOT_LOG:-$FM_PERSIST/boot.log}

# Raise this when the provisioning contract changes so existing volumes
# re-provision exactly once instead of silently keeping an older toolchain.
FM_TOOLCHAIN_CONTRACT=1
FM_TOOLCHAIN_MARKER="$FM_PERSIST/toolchain.provisioned"
FM_BOOT_READY="$FM_PERSIST/boot.ready"
FM_LOCAL_BIN=${FM_LOCAL_BIN:-$HOME/.local/bin}
PATH="$FM_LOCAL_BIN:$PATH"
export PATH
# The git URL the code root is cloned from on a volume's first boot.
FM_REMOTE_ORIGIN=${FM_REMOTE_ORIGIN:-}
# Optional npm package providing a worker harness. Left unset the pod installs
# no harness and the doctor reports that gap, because every harness needs an
# interactive login the doctor already classifies as a human step.
FM_POD_HARNESS_NPM=${FM_POD_HARNESS_NPM:-}
FM_APT_PACKAGES="git jq curl ca-certificates unzip openssh-server"

log() {
  printf '[fm-pod-boot] %s\n' "$1"
  mkdir -p "$(dirname "$FM_BOOT_LOG")" 2>/dev/null || return 0
  printf '%s [fm-pod-boot] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$FM_BOOT_LOG" 2>/dev/null || true
}

require_volume() {
  if [ ! -d "$FM_VOLUME" ]; then
    log "FATAL: the network volume is not mounted at $FM_VOLUME"
    return 1
  fi
  mkdir -p "$FM_PERSIST" "$FM_HOST_KEY_DIR" || return 1
  chmod 700 "$FM_HOST_KEY_DIR" 2>/dev/null || true
}

# --- toolchain provisioning ---------------------------------------------------
#
# Every step is announced through plan_step so --check can print the exact plan
# without touching the system, and so the plan and the work can never drift.

plan_step() {  # <item>
  printf 'ensure=%s\n' "$1"
}

toolchain_plan() {
  local pkg
  for pkg in $FM_APT_PACKAGES; do
    plan_step "apt:$pkg"
  done
  plan_step node
  plan_step npm
  plan_step code-root
  plan_step git
  plan_step jq
  plan_step herdr
  plan_step treehouse
  plan_step tasks-axi
  [ -z "$FM_POD_HARNESS_NPM" ] || plan_step "harness:$FM_POD_HARNESS_NPM"
}

have() { command -v "$1" >/dev/null 2>&1; }

apt_install() {  # <package>...
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
}

ensure_base_packages() {
  local missing="" pkg
  for pkg in $FM_APT_PACKAGES; do
    case "$pkg" in
      openssh-server) have sshd || [ -x /usr/sbin/sshd ] || missing="$missing $pkg" ;;
      ca-certificates) [ -e /etc/ssl/certs/ca-certificates.crt ] || missing="$missing $pkg" ;;
      *) have "$pkg" || missing="$missing $pkg" ;;
    esac
  done
  [ -n "$missing" ] || return 0
  log "installing base packages:$missing"
  apt-get update -qq >/dev/null 2>&1 || {
    log "the base-package index could not be updated"
    return 1
  }
  # shellcheck disable=SC2086 # deliberate word splitting of the package list.
  apt_install $missing || {
    log "some base packages could not be installed:$missing"
    return 1
  }
  for pkg in $FM_APT_PACKAGES; do
    case "$pkg" in
      openssh-server) have sshd || [ -x /usr/sbin/sshd ] || return 1 ;;
      ca-certificates) [ -e /etc/ssl/certs/ca-certificates.crt ] || return 1 ;;
      *) have "$pkg" || return 1 ;;
    esac
  done
}

# Node provides the npm-distributed tools the doctor requires. The distro
# package is used when it is new enough, and NodeSource supplies a current LTS
# otherwise, because an ancient distro Node cannot run the required CLIs.
ensure_node() {
  local major=0
  if have node; then
    major=$(node -v 2>/dev/null | sed -e 's/^v//' -e 's/\..*$//')
    case "$major" in ''|*[!0-9]*) major=0 ;; esac
    [ "$major" -lt 20 ] || return 0
    log "node $major is older than the required 20; installing a current LTS"
  fi
  if ! have curl; then
    log "curl is unavailable, so Node cannot be installed"
    return 1
  fi
  curl -fsSL https://deb.nodesource.com/setup_lts.x 2>/dev/null | bash - >/dev/null 2>&1 \
    || log "the NodeSource setup script did not complete; falling back to the distro package"
  apt_install nodejs || true
  have node || { log "node is still unavailable after installation"; return 1; }
  have npm || { log "npm is still unavailable after installation"; return 1; }
}

# The code root is what every later step runs from, including the pinned
# installers and the doctor itself, so a volume with no clone gets one here
# rather than requiring an operator to create it by hand.
ensure_code_root() {
  if [ -d "$FM_REMOTE_ROOT/.git" ]; then
    return 0
  fi
  if [ -z "$FM_REMOTE_ORIGIN" ]; then
    log "FATAL: no code root at $FM_REMOTE_ROOT and no FM_REMOTE_ORIGIN to clone from"
    return 1
  fi
  if ! have git; then
    log "FATAL: git is unavailable, so the code root cannot be cloned"
    return 1
  fi
  log "cloning the code root from FM_REMOTE_ORIGIN"
  mkdir -p "$(dirname "$FM_REMOTE_ROOT")" || return 1
  git clone --quiet "$FM_REMOTE_ORIGIN" "$FM_REMOTE_ROOT" || {
    log "FATAL: the code root clone failed"
    return 1
  }
}

# herdr and treehouse come from the repository's own pinned, checksum-verified
# installers rather than a floating package-manager latest, so a pod runs the
# exact builds CI verifies. bin/fm-install-herdr.sh and
# bin/fm-install-treehouse.sh own those pins.
ensure_pinned_tools() {
  local rc=0 installer
  mkdir -p "$FM_LOCAL_BIN" || return 1
  for installer in fm-install-herdr.sh fm-install-treehouse.sh; do
    if [ ! -x "$FM_REMOTE_ROOT/bin/$installer" ]; then
      log "$installer is missing from the code root"
      rc=1
      continue
    fi
    log "running $installer"
    "$FM_REMOTE_ROOT/bin/$installer" "$FM_LOCAL_BIN" >> "$FM_BOOT_LOG" 2>&1 || {
      log "$installer failed; see $FM_BOOT_LOG"
      rc=1
    }
  done
  return "$rc"
}

ensure_npm_tools() {
  local rc=0
  have npm || { log "npm is unavailable, so npm-distributed tools cannot be installed"; return 1; }
  log "installing tasks-axi"
  npm install -g tasks-axi >> "$FM_BOOT_LOG" 2>&1 || { log "tasks-axi installation failed"; rc=1; }
  if [ -n "$FM_POD_HARNESS_NPM" ]; then
    log "installing the configured harness package"
    npm install -g "$FM_POD_HARNESS_NPM" >> "$FM_BOOT_LOG" 2>&1 \
      || { log "the harness package installation failed"; rc=1; }
  else
    log "no FM_POD_HARNESS_NPM configured; the doctor will report the harness gap"
  fi
  return "$rc"
}

toolchain_marker_current() {
  [ -f "$FM_TOOLCHAIN_MARKER" ] || return 1
  [ "$(cat "$FM_TOOLCHAIN_MARKER" 2>/dev/null)" = "$FM_TOOLCHAIN_CONTRACT" ]
}

provision_toolchain() {
  local rc=0
  if toolchain_marker_current; then
    log "toolchain contract $FM_TOOLCHAIN_CONTRACT already satisfied on this volume"
    return 0
  fi
  log "provisioning toolchain contract $FM_TOOLCHAIN_CONTRACT"
  ensure_base_packages || rc=1
  ensure_node || rc=1
  ensure_code_root || return 1
  ensure_pinned_tools || rc=1
  ensure_npm_tools || rc=1
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$FM_TOOLCHAIN_CONTRACT" > "$FM_TOOLCHAIN_MARKER" 2>/dev/null || {
      log "the satisfied toolchain contract could not be recorded"
      return 1
    }
    log "toolchain provisioning complete"
    return 0
  fi
  log "toolchain provisioning finished with gaps; the doctor reports what remains"
  return 1
}

install_sshd() {
  command -v sshd >/dev/null 2>&1 && return 0
  command -v /usr/sbin/sshd >/dev/null 2>&1 && return 0
  log "installing openssh-server"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq openssh-server >/dev/null 2>&1 || true
  command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]
}

# The pod's SSH identity is a property of the VOLUME, not of the machine, so a
# replaced pod presents the key the primary already pinned under its HostKeyAlias.
restore_host_keys() {
  local type key
  mkdir -p /etc/ssh || return 1
  for type in ed25519 rsa ecdsa; do
    key="$FM_HOST_KEY_DIR/ssh_host_${type}_key"
    if [ -f "$key" ]; then
      cp -f "$key" "/etc/ssh/ssh_host_${type}_key" || return 1
      [ ! -f "$key.pub" ] || cp -f "$key.pub" "/etc/ssh/ssh_host_${type}_key.pub"
      chmod 600 "/etc/ssh/ssh_host_${type}_key"
      log "restored the persisted $type host key from the volume"
    fi
  done
  if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    log "no persisted host key on the volume; generating this volume's permanent identity"
    ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key </dev/null || return 1
  fi
  for type in ed25519 rsa ecdsa; do
    key="/etc/ssh/ssh_host_${type}_key"
    [ -f "$key" ] || continue
    if [ ! -f "$FM_HOST_KEY_DIR/ssh_host_${type}_key" ]; then
      cp -f "$key" "$FM_HOST_KEY_DIR/ssh_host_${type}_key" || return 1
      [ ! -f "$key.pub" ] || cp -f "$key.pub" "$FM_HOST_KEY_DIR/ssh_host_${type}_key.pub"
      chmod 600 "$FM_HOST_KEY_DIR/ssh_host_${type}_key"
      log "persisted the $type host key onto the volume"
    fi
  done
}

authorize_key() {
  local pubkey=${PUBLIC_KEY:-${SSH_PUBLIC_KEY:-}}
  [ -n "$pubkey" ] || { log "no PUBLIC_KEY or SSH_PUBLIC_KEY in the pod environment"; return 0; }
  mkdir -p "$HOME/.ssh" || return 1
  chmod 700 "$HOME/.ssh"
  if ! grep -qxF -- "$pubkey" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
    printf '%s\n' "$pubkey" >> "$HOME/.ssh/authorized_keys" || return 1
  fi
  chmod 600 "$HOME/.ssh/authorized_keys"
}

start_sshd() {
  local bin
  bin=$(command -v sshd 2>/dev/null || true)
  [ -n "$bin" ] || bin=/usr/sbin/sshd
  [ -x "$bin" ] || { log "FATAL: no sshd executable is available"; return 1; }
  mkdir -p /run/sshd /var/run/sshd 2>/dev/null || true
  if pgrep -x sshd >/dev/null 2>&1; then
    log "sshd is already running"
    return 0
  fi
  "$bin" || return 1
  log "started sshd on port 22"
}

link_entrypoint() {
  local want="$FM_REMOTE_ROOT/bin/fm-remote-entrypoint.sh"
  [ -x "$want" ] || { log "the fixed remote entrypoint is missing from the code root"; return 1; }
  mkdir -p "$FM_LOCAL_BIN" || return 1
  if [ -L "$FM_LOCAL_BIN/fm-remote-entrypoint.sh" ]; then
    [ "$(readlink "$FM_LOCAL_BIN/fm-remote-entrypoint.sh")" = "$want" ] && return 0
    rm -f -- "$FM_LOCAL_BIN/fm-remote-entrypoint.sh" || return 1
  elif [ -e "$FM_LOCAL_BIN/fm-remote-entrypoint.sh" ]; then
    log "an existing non-symlink file holds the entrypoint path; leaving it for the operator"
    return 1
  fi
  ln -s "$want" "$FM_LOCAL_BIN/fm-remote-entrypoint.sh" || return 1
  log "linked the fixed remote entrypoint"
}

# The doctor owns readiness. On Linux it starts the remote job worker and the
# headless Herdr fm-remote server directly, with no GUI login session involved,
# so this is the whole of "bring the worker and Herdr back on a fresh pod".
hand_over_to_doctor() {
  local doctor="$FM_REMOTE_ROOT/bin/fm-remote-doctor.sh"
  if [ ! -x "$doctor" ]; then
    log "the remote doctor is missing from the code root"
    return 1
  fi
  log "running the remote readiness repair"
  FM_ROOT_OVERRIDE="$FM_REMOTE_ROOT" FM_HOME="$FM_REMOTE_HOME" \
    "$doctor" --fix >> "$FM_BOOT_LOG" 2>&1 || {
      log "the readiness repair reported remaining gaps; see $FM_BOOT_LOG"
      return 1
    }
}

hold_pod() {
  while :; do
    sleep 3600
  done
}

main() {
  if [ "${1:-}" = --check ]; then
    toolchain_plan
    exit 0
  fi
  require_volume || exit 1
  rm -f -- "$FM_BOOT_READY" || exit 1
  if ! provision_toolchain; then
    log "FATAL: toolchain provisioning could not complete; SSH will not come up"
    hold_pod
  fi
  install_sshd || { log "FATAL: openssh-server is unavailable; SSH will not come up"; hold_pod; }
  restore_host_keys || log "the persisted host key could not be restored"
  authorize_key || log "the authorized key could not be written"
  link_entrypoint || { log "FATAL: the remote entrypoint could not be linked; SSH will not come up"; hold_pod; }
  start_sshd || exit 1
  until hand_over_to_doctor; do
    log "remote readiness is incomplete; SSH is available for the required human steps"
    sleep 5
  done
  printf '%s\n' "$FM_TOOLCHAIN_CONTRACT" > "$FM_BOOT_READY" || {
    log "FATAL: boot readiness could not be recorded"
    hold_pod
  }
  log "boot complete; holding the pod open"
  hold_pod
}

main "$@"
