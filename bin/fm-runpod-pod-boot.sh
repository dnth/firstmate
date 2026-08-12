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
#   2. Install and start sshd, authorizing the account's configured public key.
#   3. Link the fixed fm-remote-entrypoint.sh when the volume already carries a
#      Firstmate code root, so the very first fm-on.sh call resolves.
#   4. Hand readiness to bin/fm-remote-doctor.sh --fix when that code root
#      exists. The doctor is the single owner of what "ready for a remote second
#      mate" means, and on Linux it starts the remote job worker and the
#      headless Herdr fm-remote server itself - no GUI or Aqua session is
#      involved on this platform. Nothing here duplicates those checks.
#
# On a volume's first boot there is no code root yet, so this script stops after
# step 2 and the operator runs bin/fm-remote-home-seed.sh from the primary; that
# seeding path clones the code root onto the volume and every later wake reaches
# step 4. docs/runpod-secondmates.md owns the operator sequence.
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
  [ -x "$want" ] || return 0
  mkdir -p "$HOME/.local/bin" || return 0
  if [ -L "$HOME/.local/bin/fm-remote-entrypoint.sh" ]; then
    [ "$(readlink "$HOME/.local/bin/fm-remote-entrypoint.sh")" = "$want" ] && return 0
    rm -f -- "$HOME/.local/bin/fm-remote-entrypoint.sh"
  elif [ -e "$HOME/.local/bin/fm-remote-entrypoint.sh" ]; then
    log "an existing non-symlink file holds the entrypoint path; leaving it for the operator"
    return 0
  fi
  ln -s "$want" "$HOME/.local/bin/fm-remote-entrypoint.sh" || return 0
  log "linked the fixed remote entrypoint"
}

# The doctor owns readiness. On Linux it starts the remote job worker and the
# headless Herdr fm-remote server directly, with no GUI login session involved,
# so this is the whole of "bring the worker and Herdr back on a fresh pod".
hand_over_to_doctor() {
  local doctor="$FM_REMOTE_ROOT/bin/fm-remote-doctor.sh"
  if [ ! -x "$doctor" ]; then
    log "no Firstmate code root on the volume yet; run bin/fm-remote-home-seed.sh from the primary"
    return 0
  fi
  log "running the remote readiness repair"
  FM_ROOT_OVERRIDE="$FM_REMOTE_ROOT" FM_HOME="$FM_REMOTE_HOME" \
    "$doctor" --fix >> "$FM_BOOT_LOG" 2>&1 || \
    log "the readiness repair reported remaining gaps; see $FM_BOOT_LOG"
}

main() {
  require_volume || exit 1
  install_sshd || log "openssh-server is unavailable; SSH will not come up"
  restore_host_keys || log "the persisted host key could not be restored"
  authorize_key || log "the authorized key could not be written"
  start_sshd || exit 1
  link_entrypoint
  hand_over_to_doctor
  log "boot complete; holding the pod open"
  while :; do
    sleep 3600
  done
}

main "$@"
