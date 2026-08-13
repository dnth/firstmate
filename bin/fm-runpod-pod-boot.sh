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
#   1. Ensure the base packages, restore the persisted SSH host identity from
#      the network volume, authorize the configured public key, and start sshd.
#   2. Provision the required toolchain, then link the durable bins and fixed
#      remote entrypoint.
#   3. Hand readiness to bin/fm-remote-doctor.sh --fix. The doctor is the single
#      owner of what "ready for a remote second mate" means, and on Linux it
#      starts the remote job worker and the headless Herdr fm-remote server
#      itself - no GUI or Aqua session is involved on this platform. Nothing
#      here duplicates those checks.
#   4. Publish the separate boot.ready sentinel only after the doctor's handoff
#      succeeds. SSH stays available while human-only gaps remain, but wake
#      never reports ready before the sentinel exists.
#
# RunPod exposes no log or console API, so SSH is the only diagnostic channel
# and must exist before toolchain provisioning or any later step that can hang.
# Starting sshd never implies readiness because wake remains gated on the
# separate boot.ready sentinel.
#
# On a volume's first boot the toolchain provisioning step clones the code root
# from FM_REMOTE_ORIGIN and installs the tools bin/fm-remote-doctor.sh requires,
# so a fresh pod reaches readiness without a manual clone.
# docs/runpod-secondmates.md owns the operator sequence.
#
# Durable toolchain provisioning is idempotent and volume-scoped: a marker on
# the volume records the contract version it satisfied, so later boots reuse
# that work while each replacement pod re-ensures its system packages.
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
FM_SYSTEM_SSH_DIR=${FM_SYSTEM_SSH_DIR:-/etc/ssh}
FM_SSHD_FALLBACK=${FM_SSHD_FALLBACK:-/usr/sbin/sshd}
FM_BOOT_LOG=${FM_BOOT_LOG:-$FM_PERSIST/boot.log}

# Raise this when the provisioning contract changes so existing volumes
# re-provision exactly once instead of silently keeping an older toolchain.
FM_TOOLCHAIN_CONTRACT=4
FM_TOOLCHAIN_MARKER="$FM_PERSIST/toolchain.provisioned"
FM_BOOT_READY="$FM_PERSIST/boot.ready"
FM_LOCAL_BIN=${FM_LOCAL_BIN:-$FM_PERSIST/bin}
FM_NPM_PREFIX=${FM_NPM_PREFIX:-$FM_PERSIST/npm}
FM_NODE_ROOT=${FM_NODE_ROOT:-$FM_PERSIST/node}
PATH="$FM_NODE_ROOT/bin:$FM_LOCAL_BIN:$FM_NPM_PREFIX/bin:$PATH"
export PATH
npm_config_prefix="$FM_NPM_PREFIX"
export npm_config_prefix
# The git URL the code root is cloned from on a volume's first boot.
FM_REMOTE_ORIGIN=${FM_REMOTE_ORIGIN:-}
# Optional npm package providing a worker harness. Left unset the pod installs
# no harness and the doctor reports that gap, because every harness needs an
# interactive login the doctor already classifies as a human step.
FM_POD_HARNESS_NPM=${FM_POD_HARNESS_NPM:-}
FM_APT_PACKAGES="git jq curl ca-certificates unzip openssh-server"
FM_NODE_VERSION=24.19.0

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
      openssh-server) have sshd || [ -x "$FM_SSHD_FALLBACK" ] || missing="$missing $pkg" ;;
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
      openssh-server) have sshd || [ -x "$FM_SSHD_FALLBACK" ] || return 1 ;;
      ca-certificates) [ -e /etc/ssl/certs/ca-certificates.crt ] || return 1 ;;
      *) have "$pkg" || return 1 ;;
    esac
  done
}

ensure_node() {
  local arch archive checksum url tmp actual
  [ "$("$FM_NODE_ROOT"/bin/node -v 2>/dev/null || true)" != "v$FM_NODE_VERSION" ] || return 0
  have curl || { log "curl is unavailable, so Node cannot be installed"; return 1; }
  have tar || { log "tar is unavailable, so Node cannot be installed"; return 1; }
  case "$(uname -m)" in
    x86_64) arch=x64; checksum=f625d97cd707df4ff96254916fbc5ff014f09c09effe5a1e0ca8f6d41a8789d4 ;;
    aarch64|arm64) arch=arm64; checksum=d28c8a5bf0a808f0ed434a1dce8c54ae98f0371c0bd86ac58abc613f73e6643f ;;
    *) log "Node has no pinned build for $(uname -m)"; return 1 ;;
  esac
  archive="node-v$FM_NODE_VERSION-linux-$arch.tar.gz"
  url="https://nodejs.org/dist/v$FM_NODE_VERSION/$archive"
  tmp=$(mktemp -d "$FM_PERSIST/.node.XXXXXX") || return 1
  log "installing durable Node $FM_NODE_VERSION"
  if ! curl -fsSL --max-filesize 60000000 "$url" -o "$tmp/$archive"; then
    rm -rf -- "$tmp"
    log "the pinned Node download failed"
    return 1
  fi
  if have sha256sum; then
    actual=$(sha256sum "$tmp/$archive" | awk '{print $1}')
  elif have shasum; then
    actual=$(shasum -a 256 "$tmp/$archive" | awk '{print $1}')
  else
    rm -rf -- "$tmp"
    log "no SHA-256 tool is available to verify Node"
    return 1
  fi
  if [ "$actual" != "$checksum" ]; then
    rm -rf -- "$tmp"
    log "the pinned Node checksum did not match"
    return 1
  fi
  tar -xzf "$tmp/$archive" -C "$tmp" || { rm -rf -- "$tmp"; return 1; }
  rm -rf -- "$FM_NODE_ROOT.next"
  mv "$tmp/node-v$FM_NODE_VERSION-linux-$arch" "$FM_NODE_ROOT.next" || { rm -rf -- "$tmp"; return 1; }
  rm -rf -- "$FM_NODE_ROOT"
  mv "$FM_NODE_ROOT.next" "$FM_NODE_ROOT" || { rm -rf -- "$tmp"; return 1; }
  rm -rf -- "$tmp"
  [ "$("$FM_NODE_ROOT"/bin/node -v 2>/dev/null || true)" = "v$FM_NODE_VERSION" ] \
    || { log "durable Node did not report the pinned version"; return 1; }
  [ -x "$FM_NODE_ROOT/bin/npm" ] || { log "durable npm is unavailable after Node installation"; return 1; }
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
  mkdir -p "$FM_NPM_PREFIX" || return 1
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
  local expected actual
  [ -f "$FM_TOOLCHAIN_MARKER" ] || return 1
  expected=$(printf 'contract=%s\nharness=%s' "$FM_TOOLCHAIN_CONTRACT" "$FM_POD_HARNESS_NPM")
  actual=$(cat "$FM_TOOLCHAIN_MARKER" 2>/dev/null) || return 1
  [ "$actual" = "$expected" ]
}

toolchain_marker_write() {
  printf 'contract=%s\nharness=%s\n' "$FM_TOOLCHAIN_CONTRACT" "$FM_POD_HARNESS_NPM" > "$FM_TOOLCHAIN_MARKER"
}

provision_toolchain() {
  local rc=0
  ensure_base_packages || return 1
  ensure_node || return 1
  if toolchain_marker_current; then
    log "durable toolchain contract $FM_TOOLCHAIN_CONTRACT already satisfied on this volume"
    return 0
  fi
  log "provisioning durable toolchain contract $FM_TOOLCHAIN_CONTRACT"
  ensure_code_root || return 1
  ensure_pinned_tools || rc=1
  rm -rf -- "$FM_NPM_PREFIX" || return 1
  ensure_npm_tools || rc=1
  if [ "$rc" -eq 0 ]; then
    toolchain_marker_write 2>/dev/null || {
      log "the satisfied toolchain contract could not be recorded"
      return 1
    }
    log "durable toolchain provisioning complete"
    return 0
  fi
  log "durable toolchain provisioning finished with gaps; the doctor reports what remains"
  return 1
}

install_sshd() {
  command -v sshd >/dev/null 2>&1 && return 0
  [ -x "$FM_SSHD_FALLBACK" ] && return 0
  log "installing openssh-server"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq openssh-server >/dev/null 2>&1 || true
  command -v sshd >/dev/null 2>&1 || [ -x "$FM_SSHD_FALLBACK" ]
}

# The pod's SSH identity is a property of the VOLUME, not of the machine, so a
# replaced pod presents the key the primary already pinned under its HostKeyAlias.
restore_host_keys() {
  local type key
  mkdir -p "$FM_SYSTEM_SSH_DIR" || return 1
  for type in ed25519 rsa ecdsa; do
    key="$FM_HOST_KEY_DIR/ssh_host_${type}_key"
    if [ -f "$key" ]; then
      cp -f "$key" "$FM_SYSTEM_SSH_DIR/ssh_host_${type}_key" || return 1
      if [ -f "$key.pub" ]; then
        cp -f "$key.pub" "$FM_SYSTEM_SSH_DIR/ssh_host_${type}_key.pub" || return 1
      fi
      chmod 600 "$FM_SYSTEM_SSH_DIR/ssh_host_${type}_key" || return 1
      log "restored the persisted $type host key from the volume"
    fi
  done
  if [ ! -f "$FM_SYSTEM_SSH_DIR/ssh_host_ed25519_key" ]; then
    log "no persisted host key on the volume; generating this volume's permanent identity"
    ssh-keygen -q -t ed25519 -N '' -f "$FM_SYSTEM_SSH_DIR/ssh_host_ed25519_key" </dev/null || return 1
  fi
  for type in ed25519 rsa ecdsa; do
    key="$FM_SYSTEM_SSH_DIR/ssh_host_${type}_key"
    [ -f "$key" ] || continue
    if [ ! -f "$FM_HOST_KEY_DIR/ssh_host_${type}_key" ]; then
      cp -f "$key" "$FM_HOST_KEY_DIR/ssh_host_${type}_key" || return 1
      if [ -f "$key.pub" ]; then
        cp -f "$key.pub" "$FM_HOST_KEY_DIR/ssh_host_${type}_key.pub" || return 1
      fi
      chmod 600 "$FM_HOST_KEY_DIR/ssh_host_${type}_key" || return 1
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
  [ -n "$bin" ] || bin=$FM_SSHD_FALLBACK
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
  local entrypoint_dir="$HOME/.local/bin"
  [ -x "$want" ] || { log "the fixed remote entrypoint is missing from the code root"; return 1; }
  mkdir -p "$entrypoint_dir" || return 1
  if [ -L "$entrypoint_dir/fm-remote-entrypoint.sh" ]; then
    [ "$(readlink "$entrypoint_dir/fm-remote-entrypoint.sh")" = "$want" ] && return 0
    rm -f -- "$entrypoint_dir/fm-remote-entrypoint.sh" || return 1
  elif [ -e "$entrypoint_dir/fm-remote-entrypoint.sh" ]; then
    log "an existing non-symlink file holds the entrypoint path; leaving it for the operator"
    return 1
  fi
  ln -s "$want" "$entrypoint_dir/fm-remote-entrypoint.sh" || return 1
  log "linked the fixed remote entrypoint"
}

link_durable_bins() {
  local source target bin_dir="$HOME/.local/bin"
  mkdir -p "$bin_dir" || return 1
  for target in "$bin_dir"/*; do
    [ -L "$target" ] || continue
    source=$(readlink "$target")
    case "$source" in
      "$FM_NODE_ROOT/bin/"*|"$FM_LOCAL_BIN/"*|"$FM_NPM_PREFIX/bin/"*)
        [ -e "$source" ] || rm -f -- "$target" || return 1
        ;;
    esac
  done
  for source in "$FM_NODE_ROOT/bin"/* "$FM_LOCAL_BIN"/* "$FM_NPM_PREFIX/bin"/*; do
    [ -f "$source" ] && [ -x "$source" ] || continue
    target="$bin_dir/${source##*/}"
    if [ -L "$target" ]; then
      [ "$(readlink "$target")" = "$source" ] && continue
      rm -f -- "$target" || return 1
    elif [ -e "$target" ]; then
      log "an existing non-symlink file holds $target; leaving it for the operator"
      return 1
    fi
    ln -s "$source" "$target" || return 1
  done
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

  # SSH comes up FIRST, deliberately independent of provisioning. RunPod exposes
  # no log or console API, so this connection IS the only diagnostic channel: a
  # pod whose provisioning is slow or broken must still be reachable, or the
  # failure cannot be inspected at all. Readiness is NOT implied by sshd being
  # up - it is the separate FM_BOOT_READY sentinel written only after
  # provisioning succeeds, so wake still never reports ready on an incomplete
  # pod. Only the host-identity guarantees gate sshd, because a pod that cannot
  # present its volume-backed key must never expose a different one.
  # The base packages carry openssh-server itself, so they are ensured here
  # rather than inside provisioning: without them there is no sshd and therefore
  # no diagnostic channel at all. The call is idempotent, so provisioning's own
  # later invocation is a no-op once these are present.
  ensure_base_packages || { log "FATAL: base packages are unavailable; SSH will not come up"; hold_pod; }
  install_sshd || { log "FATAL: openssh-server is unavailable; SSH will not come up"; hold_pod; }
  restore_host_keys || { log "FATAL: the volume-backed host key could not be restored or persisted; SSH will not come up"; hold_pod; }
  authorize_key || log "the authorized key could not be written"
  start_sshd || { log "FATAL: sshd did not start; this pod has no diagnostic channel"; hold_pod; }
  log "sshd is up; diagnostic access is available before provisioning starts"

  # Everything below can fail without taking SSH away. Each failure logs and
  # holds the pod open so the operator can connect and read this same log.
  if ! provision_toolchain; then
    log "FATAL: toolchain provisioning could not complete; connect over SSH and read $FM_BOOT_LOG"
    hold_pod
  fi
  link_durable_bins || { log "FATAL: durable tools could not be linked; connect over SSH and read $FM_BOOT_LOG"; hold_pod; }
  link_entrypoint || { log "FATAL: the remote entrypoint could not be linked; connect over SSH and read $FM_BOOT_LOG"; hold_pod; }
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
