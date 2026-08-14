#!/usr/bin/env bash
# Reproducible boot for a RunPod Linux container hosting one remote second mate.
#
# bin/fm-runpod.sh sends this file after the shared Treehouse-root helper to
# every pod it creates, base64-encoded in the FM_POD_BOOT_B64 environment
# variable, and makes the pod's start command decode and exec the combined
# payload. Both files are tracked, so the boot contract is versioned with the
# code that creates the pod and the container image needs nothing from this repo
# preinstalled.
#
# It does the smallest thing that makes the pod an ordinary SSH-reachable remote
# second-mate host, then hands over:
#
#   0. Move the account home onto the volume and point the account database at
#      it, so every credential a later interactive login writes is durable.
#   1. Ensure the base packages, restore the persisted SSH host identity from
#      the network volume, authorize the configured public key, and start sshd.
#   2. Provision the required toolchain, then link the durable bins, the browser,
#      and the fixed remote entrypoint, and seed Claude's unattended root state.
#   3. Hand readiness to bin/fm-remote-doctor.sh --fix --parity. The doctor is the single
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
# Usage:
#   fm-runpod-pod-boot.sh
#   fm-runpod-pod-boot.sh --check
#   fm-runpod-pod-boot.sh --install-omp-auth-broker-token < token-file
#   fm-runpod-pod-boot.sh --check-omp-auth-broker-client
#   fm-runpod-pod-boot.sh --help
#
# The pod is contracted to reach FULL parity with a local second mate: every
# worker harness its crew dispatch can select, the universal toolchain, the
# code-intelligence CLI, and a browser. Every one of them installs UNDER THE
# VOLUME, so the setup cost is paid once per volume rather than once per pod.
# Codex, Claude, and gh credentials still use the durable account home.
# OMP is the deliberate exception: its subscription credentials stay in the
# workstation auth broker, and this pod receives only a mode-600 bearer plus a
# loopback endpoint reached through the workstation-owned reverse tunnel.
#
# The volume is mounted at /workspace. Durable remote state lives under it:
#   /workspace/firstmate            the remote Firstmate code root
#   /workspace/secondmate-home      the persistent FM_HOME, separate from the code root
#   /workspace/persistent-runtime   SSH host keys, the toolchain, and selected caches
#   /workspace/home                 the account home: every login and runtime config
#
# This script runs as the container's PID 1 payload, so it must never exit while
# the pod should stay up.
set -u

# A fresh pod receives this helper in the same boot payload. Direct invocations
# from a checkout source the tracked copy instead.
if ! declare -F fm_treehouse_root_prepare_runpod_boot >/dev/null; then
  FM_TREEHOUSE_ROOT_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
  # shellcheck source=bin/fm-treehouse-root-lib.sh
  . "$FM_TREEHOUSE_ROOT_LIB_DIR/fm-treehouse-root-lib.sh"
  unset FM_TREEHOUSE_ROOT_LIB_DIR
fi

FM_VOLUME=${FM_VOLUME:-/workspace}
FM_REMOTE_ROOT=${FM_REMOTE_ROOT:-$FM_VOLUME/firstmate}
FM_REMOTE_HOME=${FM_REMOTE_HOME:-$FM_VOLUME/secondmate-home}
FM_PERSIST=${FM_PERSIST:-$FM_VOLUME/persistent-runtime}
FM_ACCOUNT_HOME=${FM_ACCOUNT_HOME:-$FM_VOLUME/home}
FM_TREEHOUSE_LOCAL_ROOT=${FM_TREEHOUSE_LOCAL_ROOT:-/tmp/firstmate-treehouse}
export FM_TREEHOUSE_LOCAL_ROOT
FM_ORIGINAL_HOME=${HOME:-}
FM_HOST_KEY_DIR="$FM_PERSIST/ssh"
FM_SYSTEM_SSH_DIR=${FM_SYSTEM_SSH_DIR:-/etc/ssh}
FM_SSHD_FALLBACK=${FM_SSHD_FALLBACK:-/usr/sbin/sshd}
FM_BOOT_LOG=${FM_BOOT_LOG:-$FM_PERSIST/boot.log}
# sshd reads each account's home from here, so this is what makes an SSH login
# land on the volume. It is on the disposable container disk and is rewritten on
# every boot. bin/fm-remote-doctor.sh reads the durable-root declaration.
FM_PASSWD_FILE=${FM_PASSWD_FILE:-/etc/passwd}
FM_DURABLE_ROOT_FILE=${FM_DURABLE_ROOT_FILE:-/etc/firstmate/durable-root}
IS_SANDBOX=1
export IS_SANDBOX

# Raise this when the provisioning contract changes so existing volumes
# re-provision exactly once instead of silently keeping an older toolchain.
FM_TOOLCHAIN_CONTRACT=6
FM_TOOLCHAIN_MARKER="$FM_PERSIST/toolchain.provisioned"
FM_BOOT_READY="$FM_PERSIST/boot.ready"
FM_RUNPOD_SANDBOX_MARKER="$FM_PERSIST/runpod-root-sandbox"
FM_BOOT_CONTROL="$FM_PERSIST/fm-runpod-pod-boot.sh"
FM_OMP_AUTH_BROKER_TOKEN_FILE=${FM_OMP_AUTH_BROKER_TOKEN_FILE:-$FM_PERSIST/omp-auth-broker.token}
OMP_AUTH_BROKER_URL=${OMP_AUTH_BROKER_URL:-http://127.0.0.1:8765}
FM_OMP_AUTH_BROKER_REMOTE_BIND=${FM_OMP_AUTH_BROKER_REMOTE_BIND:-127.0.0.1:8765}
FM_LOCAL_BIN=${FM_LOCAL_BIN:-$FM_PERSIST/bin}
FM_NPM_PREFIX=${FM_NPM_PREFIX:-$FM_PERSIST/npm}
FM_NODE_ROOT=${FM_NODE_ROOT:-$FM_PERSIST/node}
FM_BUN_ROOT=${FM_BUN_ROOT:-$FM_PERSIST/bun}
FM_CHROME_ROOT=${FM_CHROME_ROOT:-$FM_PERSIST/chrome}
FM_CHROME_LINK=${FM_CHROME_LINK:-/usr/bin/google-chrome}
# Leads with the account bin directory, the same one the fixed remote entrypoint
# puts first when it composes a worker's PATH, so what this boot resolves and
# what a later SSH job resolves are the same tools.
PATH="$FM_ACCOUNT_HOME/.local/bin:$FM_NODE_ROOT/bin:$FM_LOCAL_BIN:$FM_NPM_PREFIX/bin:$FM_BUN_ROOT/bin:$PATH"
export PATH
npm_config_prefix="$FM_NPM_PREFIX"
export npm_config_prefix
BUN_INSTALL="$FM_BUN_ROOT"
export BUN_INSTALL
# The git URL the code root is cloned from on a volume's first boot.
FM_REMOTE_ORIGIN=${FM_REMOTE_ORIGIN:-}
# An OPTIONAL extra npm harness beyond the parity set below. The parity set is
# unconditional, so leaving this unset is the normal case.
FM_POD_HARNESS_NPM=${FM_POD_HARNESS_NPM:-}
FM_APT_PACKAGES="git jq curl ca-certificates unzip openssh-server"
# Chrome's shared-library dependencies, named as the pinned Ubuntu 22.04 base
# image publishes them. Kept out of FM_APT_PACKAGES because that set gates sshd:
# a browser dependency must never be able to cost the pod its only diagnostic
# channel. A missing name here degrades the browser, never SSH.
FM_BROWSER_PACKAGES="fonts-liberation libasound2 libatk-bridge2.0-0 libatk1.0-0
libatspi2.0-0 libcairo2 libcups2 libdbus-1-3 libdrm2 libgbm1 libnspr4 libnss3
libpango-1.0-0 libxcomposite1 libxdamage1 libxfixes3 libxkbcommon0 libxrandr2"
FM_NODE_VERSION=24.19.0
# The parity toolchain's package identities. bin/fm-remote-doctor.sh --parity is
# the single owner of WHAT parity requires; these are only how each item is
# obtained noninteractively in a container. bin/fm-bootstrap.sh's install_cmd is
# the same identity source for the universal toolchain a workstation installs by
# hand. Every one of these needs an interactive login before it can do work,
# which the doctor already classifies as a human step; the durable account home
# is what makes that login once-per-volume.
FM_OMP_PACKAGE=@oh-my-pi/pi-coding-agent
FM_CODEX_PACKAGE=@openai/codex
FM_CODEGRAPH_PACKAGE=@colbymchenry/codegraph
FM_AXI_PACKAGES="gh-axi chrome-devtools-axi lavish-axi quota-axi"
FM_AXI_HOOK_PACKAGES="gh-axi chrome-devtools-axi lavish-axi"
FM_BUN_INSTALL_URL=https://bun.sh/install
FM_CLAUDE_INSTALL_URL=https://claude.ai/install.sh
FM_NO_MISTAKES_INSTALL_URL=https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh
FM_GH_REPO=cli/cli
FM_CHROME_CHANNEL=${FM_CHROME_CHANNEL:-stable}

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
  for pkg in $FM_APT_PACKAGES $FM_BROWSER_PACKAGES; do
    plan_step "apt:$pkg"
  done
  plan_step account-home
  plan_step account-shell
  plan_step treehouse-local-pool
  plan_step root-sandbox-marker
  plan_step node
  plan_step npm
  plan_step code-root
  plan_step git
  plan_step jq
  plan_step herdr
  plan_step treehouse
  plan_step tasks-axi
  # The parity set. Each name here is the tool name the doctor's parity tier
  # reports, so the two lists are checked against each other by the tests.
  plan_step bun
  plan_step omp
  plan_step claude
  plan_step codex
  plan_step no-mistakes
  plan_step gh
  for pkg in $FM_AXI_PACKAGES; do
    plan_step "$pkg"
  done
  plan_step codegraph
  plan_step google-chrome
  plan_step claude-headless
  plan_step sshd-remote-forwarding
  plan_step omp-auth-broker-client
  [ -z "$FM_POD_HARNESS_NPM" ] || plan_step "harness:$FM_POD_HARNESS_NPM"
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- the durable account home ------------------------------------------------
#
# Every interactive login a worker harness or gh completes writes its credential
# under the account home. On the container's own home that credential dies with
# the pod, so setup would be once-per-pod. Moving the home onto the volume is
# what makes it once-per-volume, and it covers every runtime at once rather than
# one credential-directory variable per tool.

ensure_account_home() {
  mkdir -p "$FM_ACCOUNT_HOME" || return 1
  chmod 700 "$FM_ACCOUNT_HOME" 2>/dev/null || true
  HOME=$FM_ACCOUNT_HOME
  export HOME
  mkdir -p "$(dirname "$FM_DURABLE_ROOT_FILE")" || return 1
  # The doctor reads this to check that the account home is inside the part of
  # the filesystem that survives replacement.
  printf '%s\n' "$FM_VOLUME" > "$FM_DURABLE_ROOT_FILE" || return 1
}

FM_SHELL_RC_BEGIN='# Firstmate RunPod environment begin'
FM_SHELL_RC_END='# Firstmate RunPod environment end'

write_account_shell_rc() {  # <path>
  local path=$1 tmp target home
  if [ -e "$path" ] || [ -L "$path" ]; then
    target=$path
    if [ -L "$path" ]; then
      home=$(cd "$FM_ACCOUNT_HOME" && pwd -P) || return 1
      target=$(readlink -f -- "$path" 2>/dev/null) || {
        log "refusing unsafe account shell startup path: $path"
        return 1
      }
      case "$target" in
        "$home"/*) ;;
        *)
          log "refusing account shell startup symlink outside the durable home: $path"
          return 1
          ;;
      esac
    fi
    [ -f "$target" ] && [ ! -L "$target" ] || {
      log "refusing unsafe account shell startup path: $path"
      return 1
    }
  else
    target=$path
  fi
  tmp=$(mktemp "$FM_ACCOUNT_HOME/.fm-shell-rc.XXXXXX") || return 1
  {
    if [ -f "$target" ]; then
      awk -v begin="$FM_SHELL_RC_BEGIN" -v end="$FM_SHELL_RC_END" '
        $0 == begin { managed = 1; next }
        $0 == end { managed = 0; next }
        !managed { print }
      ' "$target"
    fi
    printf '%s\n' "$FM_SHELL_RC_BEGIN"
    # shellcheck disable=SC2016 # HOME and PATH expand when the generated startup file is sourced.
    printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"'
    printf '%s\n' 'export IS_SANDBOX=1'
    printf 'export FM_TREEHOUSE_LOCAL_ROOT=%q\n' "$FM_TREEHOUSE_LOCAL_ROOT"
    printf '%s\n' "$FM_SHELL_RC_END"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; return 1; }
}

ensure_account_shell() {
  write_account_shell_rc "$FM_ACCOUNT_HOME/.profile" || return 1
  write_account_shell_rc "$FM_ACCOUNT_HOME/.bashrc" || return 1
  if [ -e "$FM_ACCOUNT_HOME/.bash_profile" ] || [ -L "$FM_ACCOUNT_HOME/.bash_profile" ]; then
    write_account_shell_rc "$FM_ACCOUNT_HOME/.bash_profile" || return 1
  fi
  if [ -e "$FM_ACCOUNT_HOME/.bash_login" ] || [ -L "$FM_ACCOUNT_HOME/.bash_login" ]; then
    write_account_shell_rc "$FM_ACCOUNT_HOME/.bash_login" || return 1
  fi
  log "login shells now inherit the durable account PATH and IS_SANDBOX=1"
}

ensure_runpod_sandbox_marker() {
  local tmp="$FM_RUNPOD_SANDBOX_MARKER.tmp.$$"
  printf '%s\n' runpod-root-sandbox-v1 > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$FM_RUNPOD_SANDBOX_MARKER" || { rm -f -- "$tmp"; return 1; }
}

# Published before sshd starts so the workstation has one fixed, versioned
# bootstrap interface for installing the broker bearer while the rest of the
# durable toolchain is still provisioning.
install_boot_control() {
  local source source_dir helper target tmp
  source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 1
  source=$source_dir/${BASH_SOURCE[0]##*/}
  helper=$source_dir/fm-treehouse-root-lib.sh
  target=$FM_BOOT_CONTROL
  if [ "$source" = "$target" ]; then
    chmod 700 "$target" || return 1
    return 0
  fi
  tmp="$target.tmp.$$"
  if [ -f "$helper" ]; then
    cat "$helper" "$source" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  else
    cp -f -- "$source" "$tmp" || { rm -f -- "$tmp"; return 1; }
  fi
  chmod 700 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; return 1; }
}

mode_600() {
  if [ "$(uname)" = Darwin ]; then
    [ "$(stat -f %Lp "$1" 2>/dev/null || true)" = 600 ]
  else
    [ "$(stat -c %a "$1" 2>/dev/null || true)" = 600 ]
  fi
}

omp_auth_broker_token_valid() {  # <token>
  [ -n "$1" ] && [ "${#1}" -le 512 ] || return 1
  case "$1" in *[!A-Za-z0-9_-]*) return 1 ;; esac
}

install_omp_auth_broker_token() {
  local token tmp
  require_volume || return 1
  token=$(LC_ALL=C head -c 513)
  omp_auth_broker_token_valid "$token" || {
    log "refusing an empty, oversized, or malformed omp auth-broker bearer"
    return 1
  }
  tmp="$FM_OMP_AUTH_BROKER_TOKEN_FILE.tmp.$$"
  if ! (umask 077; printf '%s' "$token" > "$tmp"); then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$FM_OMP_AUTH_BROKER_TOKEN_FILE" || { rm -f -- "$tmp"; return 1; }
  printf 'installed=omp-auth-broker-token\n'
}

omp_auth_broker_client_configure() {
  local token port
  case "$OMP_AUTH_BROKER_URL" in http://127.0.0.1:[0-9]*|http://localhost:[0-9]*) ;;
    *) return 1 ;;
  esac
  port=${OMP_AUTH_BROKER_URL##*:}
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  [ -f "$FM_OMP_AUTH_BROKER_TOKEN_FILE" ] && [ ! -L "$FM_OMP_AUTH_BROKER_TOKEN_FILE" ] \
    && mode_600 "$FM_OMP_AUTH_BROKER_TOKEN_FILE" || return 1
  token=$(cat "$FM_OMP_AUTH_BROKER_TOKEN_FILE") || return 1
  omp_auth_broker_token_valid "$token" || return 1
  OMP_AUTH_BROKER_TOKEN=$token
  export OMP_AUTH_BROKER_URL OMP_AUTH_BROKER_TOKEN FM_OMP_AUTH_BROKER_TOKEN_FILE
}

check_omp_auth_broker_client() {
  omp_auth_broker_client_configure || return 1
  have curl || return 1
  {
    printf 'silent\n'
    printf 'show-error\n'
    printf 'fail\n'
    printf 'max-time = "2"\n'
    printf 'url = "%s/v1/snapshot"\n' "$OMP_AUTH_BROKER_URL"
    printf 'header = "Authorization: Bearer %s"\n' "$OMP_AUTH_BROKER_TOKEN"
  } | curl --config - >/dev/null 2>&1 || return 1
  printf 'auth-broker=ready mode=credential-read-only\n'
}

wait_for_omp_auth_broker_client() {
  log "waiting for the workstation omp auth broker and reverse tunnel"
  until check_omp_auth_broker_client >/dev/null 2>&1; do
    sleep 2
  done
  log "configured omp to read subscription auth through the workstation broker"
}

# sshd resolves the login's home from the passwd database, not from this
# process, so the durable home only takes effect for SSH once the account's
# entry names it. The file is container-local, so this repeats every boot.
bind_account_home_to_sshd() {
  local user tmp
  user=$(id -un 2>/dev/null || true)
  if [ -z "$user" ]; then
    log "the account name could not be read, so sshd keeps the container-local home"
    return 1
  fi
  if [ ! -f "$FM_PASSWD_FILE" ] || [ -L "$FM_PASSWD_FILE" ]; then
    log "no usable account database at $FM_PASSWD_FILE, so sshd keeps the container-local home"
    return 1
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-passwd.XXXXXX") || return 1
  if ! awk -F: -v user="$user" -v home="$FM_ACCOUNT_HOME" \
    'BEGIN { OFS = ":" } $1 == user { $6 = home } { print }' "$FM_PASSWD_FILE" > "$tmp"; then
    rm -f -- "$tmp"
    log "the account database could not be rewritten, so sshd keeps the container-local home"
    return 1
  fi
  if ! grep -q "^$user:.*:$FM_ACCOUNT_HOME:" "$tmp"; then
    rm -f -- "$tmp"
    log "no entry for $user in $FM_PASSWD_FILE, so sshd keeps the container-local home"
    return 1
  fi
  # Written through the existing file so its inode, owner, and mode survive.
  if ! cat "$tmp" > "$FM_PASSWD_FILE"; then
    rm -f -- "$tmp"
    log "the account database could not be published, so sshd keeps the container-local home"
    return 1
  fi
  rm -f -- "$tmp"
  log "the account home is $FM_ACCOUNT_HOME on the volume, so a completed login survives pod replacement"
}

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
    if [ ! -x "$FM_REMOTE_ROOT/bin/fm-claude-headless-setup.sh" ]; then
      [ -z "$(git -C "$FM_REMOTE_ROOT" status --porcelain 2>/dev/null)" ] || {
        log "the retained code root is dirty and lacks fm-claude-headless-setup.sh"
        return 1
      }
      log "fast-forwarding the retained code root to obtain the Claude headless helper"
      git -C "$FM_REMOTE_ROOT" pull --ff-only --quiet >> "$FM_BOOT_LOG" 2>&1 || {
        log "the retained code root could not be fast-forwarded"
        return 1
      }
      [ -x "$FM_REMOTE_ROOT/bin/fm-claude-headless-setup.sh" ] || {
        log "fm-claude-headless-setup.sh is still missing after the retained code root update"
        return 1
      }
    fi
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
  local rc=0 package
  have npm || { log "npm is unavailable, so npm-distributed tools cannot be installed"; return 1; }
  mkdir -p "$FM_NPM_PREFIX" || return 1
  for package in tasks-axi $FM_AXI_PACKAGES "$FM_CODEX_PACKAGE" "$FM_CODEGRAPH_PACKAGE"; do
    log "installing $package"
    npm install -g "$package" >> "$FM_BOOT_LOG" 2>&1 \
      || { log "$package installation failed"; rc=1; }
  done
  # The axi tools' own install instructions pair the package with a hook setup
  # step. It is best effort: the tool works without it, and refusing the whole
  # contract for a hook would leave the volume re-provisioning forever.
  for package in $FM_AXI_HOOK_PACKAGES; do
    have "$package" || continue
    "$package" setup hooks >> "$FM_BOOT_LOG" 2>&1 \
      || log "$package installed but its hook setup did not complete"
  done
  if [ -n "$FM_POD_HARNESS_NPM" ]; then
    log "installing the configured extra harness package"
    npm install -g "$FM_POD_HARNESS_NPM" >> "$FM_BOOT_LOG" 2>&1 \
      || { log "the extra harness package installation failed"; rc=1; }
  fi
  return "$rc"
}

# --- the parity toolchain ----------------------------------------------------

ensure_bun() {
  [ ! -x "$FM_BUN_ROOT/bin/bun" ] || return 0
  have curl || { log "curl is unavailable, so bun cannot be installed"; return 1; }
  mkdir -p "$FM_BUN_ROOT" || return 1
  log "installing the durable bun runtime"
  curl -fsSL "$FM_BUN_INSTALL_URL" | bash >> "$FM_BOOT_LOG" 2>&1 \
    || { log "the bun installation failed"; return 1; }
  [ -x "$FM_BUN_ROOT/bin/bun" ] || { log "bun is unavailable after its installer ran"; return 1; }
}

ensure_bun_tools() {
  [ -x "$FM_BUN_ROOT/bin/bun" ] || { log "bun is unavailable, so omp cannot be installed"; return 1; }
  log "installing $FM_OMP_PACKAGE"
  "$FM_BUN_ROOT/bin/bun" install -g "$FM_OMP_PACKAGE" >> "$FM_BOOT_LOG" 2>&1 \
    || { log "the omp installation failed"; return 1; }
  [ -x "$FM_BUN_ROOT/bin/omp" ] || { log "omp is unavailable after its installation"; return 1; }
}

# claude and no-mistakes publish shell installers rather than packages. Both
# install under the account home, which is on the volume by the time these run,
# so they are durable for the same reason every login is.
ensure_home_installer() {  # <label> <url> <installed-binary>
  local label=$1 url=$2 binary=$3
  [ ! -x "$HOME/.local/bin/$binary" ] || return 0
  have curl || { log "curl is unavailable, so $label cannot be installed"; return 1; }
  log "installing $label"
  curl -fsSL "$url" | bash >> "$FM_BOOT_LOG" 2>&1 \
    || { log "the $label installation failed"; return 1; }
  [ -x "$HOME/.local/bin/$binary" ] \
    || { log "$label is unavailable after its installer ran"; return 1; }
}

ensure_gh() {
  local arch version archive url tmp
  [ ! -x "$FM_LOCAL_BIN/gh" ] || return 0
  have curl || { log "curl is unavailable, so gh cannot be installed"; return 1; }
  have tar || { log "tar is unavailable, so gh cannot be installed"; return 1; }
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) log "gh publishes no linux build for $(uname -m)"; return 1 ;;
  esac
  # Resolved rather than pinned: a hardcoded gh version rots into a download
  # that no longer exists, and the volume freezes whatever it resolved here.
  version=$(curl -fsSL "https://api.github.com/repos/$FM_GH_REPO/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
  case "$version" in
    ''|*[!0-9.]*) log "the current gh release could not be resolved"; return 1 ;;
  esac
  archive="gh_${version}_linux_${arch}.tar.gz"
  url="https://github.com/$FM_GH_REPO/releases/download/v$version/$archive"
  tmp=$(mktemp -d "$FM_PERSIST/.gh.XXXXXX") || return 1
  log "installing gh $version"
  if ! curl -fsSL --max-filesize 60000000 "$url" -o "$tmp/$archive"; then
    rm -rf -- "$tmp"
    log "the gh download failed"
    return 1
  fi
  if ! tar -xzf "$tmp/$archive" -C "$tmp"; then
    rm -rf -- "$tmp"
    log "the gh archive could not be unpacked"
    return 1
  fi
  mkdir -p "$FM_LOCAL_BIN" || { rm -rf -- "$tmp"; return 1; }
  if ! cp -f "$tmp/gh_${version}_linux_${arch}/bin/gh" "$FM_LOCAL_BIN/gh"; then
    rm -rf -- "$tmp"
    log "the gh binary was not where its archive publishes it"
    return 1
  fi
  chmod 0755 "$FM_LOCAL_BIN/gh" || { rm -rf -- "$tmp"; return 1; }
  rm -rf -- "$tmp"
}

# Chrome for Testing, unpacked onto the volume through its published CLI. The
# resolved build is frozen by the durable marker, so a volume keeps the browser
# it provisioned rather than drifting under a running second mate.
browser_binary() {
  local candidate
  for candidate in "$FM_CHROME_ROOT"/chrome/*/chrome-linux64/chrome; do
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

ensure_browser() {
  browser_binary >/dev/null 2>&1 && return 0
  have npx || { log "npx is unavailable, so the browser cannot be installed"; return 1; }
  mkdir -p "$FM_CHROME_ROOT" || return 1
  log "installing the durable headless browser"
  npx --yes @puppeteer/browsers install "chrome@$FM_CHROME_CHANNEL" --path "$FM_CHROME_ROOT" \
    >> "$FM_BOOT_LOG" 2>&1 || { log "the browser installation failed"; return 1; }
  browser_binary >/dev/null 2>&1 \
    || { log "no browser binary is present after its installation"; return 1; }
}

# Chrome's shared libraries live on the container disk, so a replacement pod
# re-ensures them. A failure here is not fatal on its own; link_browser decides,
# because the browser actually running is the only verdict that matters.
ensure_browser_packages() {
  local missing="" pkg
  have dpkg-query || return 0
  for pkg in $FM_BROWSER_PACKAGES; do
    dpkg-query -W -f '${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$' \
      || missing="$missing $pkg"
  done
  [ -n "$missing" ] || return 0
  log "installing browser system libraries:$missing"
  apt-get update -qq >/dev/null 2>&1 || true
  # shellcheck disable=SC2086 # deliberate word splitting of the package list.
  apt_install $missing || log "some browser system libraries could not be installed"
}

# Published at the standard system path a browser tool looks for, as a wrapper
# rather than a symlink. This pod is root by construction - it writes /etc/ssh,
# the account database, and system packages - and Chrome refuses to start as
# root without --no-sandbox. Putting that at the launch seam means no tool
# needs the flag threaded through its own environment. The container is
# single-tenant and disposable, and the sandbox it drops protects the container
# from the page, not the fleet from the container.
FM_CHROME_WRAPPER_MARK='# Firstmate pod browser wrapper v1'

write_browser_wrapper() {  # <resolved-browser>
  local resolved=$1 tmp
  tmp="$FM_CHROME_LINK.fm.tmp.$$"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "$FM_CHROME_WRAPPER_MARK"
    printf '%s\n' 'args=()'
    # shellcheck disable=SC2016 # deliberate literal for the generated browser wrapper.
    printf '%s\n' '[ "$(id -u)" -ne 0 ] || args=(--no-sandbox --disable-dev-shm-usage)'
    # shellcheck disable=SC2016 # deliberate literals for the generated browser wrapper.
    printf 'exec %s ${args[@]+"${args[@]}"} "$@"\n' "$resolved"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0755 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$FM_CHROME_LINK" || { rm -f -- "$tmp"; return 1; }
}

browser_wrapper_is_ours() {
  local second
  [ -f "$FM_CHROME_LINK" ] && [ ! -L "$FM_CHROME_LINK" ] || return 1
  second=$(sed -n 2p "$FM_CHROME_LINK" 2>/dev/null) || return 1
  [ "$second" = "$FM_CHROME_WRAPPER_MARK" ]
}

link_browser() {
  local resolved
  resolved=$(browser_binary) || { log "no durable browser is present on the volume"; return 1; }
  mkdir -p "$(dirname "$FM_CHROME_LINK")" || return 1
  if [ -e "$FM_CHROME_LINK" ] || [ -L "$FM_CHROME_LINK" ]; then
    if ! browser_wrapper_is_ours; then
      log "an existing file holds $FM_CHROME_LINK that Firstmate did not write; leaving it for the operator"
      return 1
    fi
  fi
  write_browser_wrapper "$resolved" || { log "the browser wrapper could not be published"; return 1; }
  # Presence is not capability: a browser whose system libraries are incomplete
  # exists and cannot start, and that failure belongs here rather than in the
  # middle of a worker's page.
  "$FM_CHROME_LINK" --version >> "$FM_BOOT_LOG" 2>&1 || {
    log "the durable browser could not start; its system libraries are incomplete"
    return 1
  }
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
  ensure_code_root || return 1
  if toolchain_marker_current; then
    log "durable toolchain contract $FM_TOOLCHAIN_CONTRACT already satisfied on this volume"
    return 0
  fi
  log "provisioning durable toolchain contract $FM_TOOLCHAIN_CONTRACT"
  ensure_pinned_tools || rc=1
  rm -rf -- "$FM_NPM_PREFIX" || return 1
  ensure_npm_tools || rc=1
  ensure_bun || rc=1
  ensure_bun_tools || rc=1
  ensure_home_installer "the claude harness" "$FM_CLAUDE_INSTALL_URL" claude || rc=1
  ensure_home_installer "no-mistakes" "$FM_NO_MISTAKES_INSTALL_URL" no-mistakes || rc=1
  ensure_gh || rc=1
  ensure_browser || rc=1
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

authorize_key_in() {  # <home>
  local home=$1 pubkey=$2
  [ -n "$home" ] || return 0
  mkdir -p "$home/.ssh" || return 1
  chmod 700 "$home/.ssh"
  if ! grep -qxF -- "$pubkey" "$home/.ssh/authorized_keys" 2>/dev/null; then
    printf '%s\n' "$pubkey" >> "$home/.ssh/authorized_keys" || return 1
  fi
  chmod 600 "$home/.ssh/authorized_keys"
}

# Authorized in BOTH homes on purpose. If the account database could not be
# rewritten, sshd still resolves the container-local home, and a pod nobody can
# log into is a pod nobody can diagnose.
authorize_key() {
  local pubkey=${PUBLIC_KEY:-${SSH_PUBLIC_KEY:-}} rc=0
  [ -n "$pubkey" ] || { log "no PUBLIC_KEY or SSH_PUBLIC_KEY in the pod environment"; return 0; }
  authorize_key_in "$HOME" "$pubkey" || rc=1
  [ "$FM_ORIGINAL_HOME" = "$HOME" ] || authorize_key_in "$FM_ORIGINAL_HOME" "$pubkey" || rc=1
  return "$rc"
}

start_sshd() {
  local bin effective
  bin=$(command -v sshd 2>/dev/null || true)
  [ -n "$bin" ] || bin=$FM_SSHD_FALLBACK
  [ -x "$bin" ] || { log "FATAL: no sshd executable is available"; return 1; }
  mkdir -p /run/sshd /var/run/sshd 2>/dev/null || true
  if pgrep -x sshd >/dev/null 2>&1; then
    effective=$("$bin" -T 2>/dev/null || true)
    if ! printf '%s\n' "$effective" | grep -Eq '^allowtcpforwarding (remote|yes)$' \
       || ! printf '%s\n' "$effective" | grep -q '^gatewayports no$' \
       || ! printf '%s\n' "$effective" | grep -q "^permitlisten $FM_OMP_AUTH_BROKER_REMOTE_BIND$"; then
      log "FATAL: the pre-existing sshd does not prove the scoped omp broker reverse-forward policy"
      return 1
    fi
    log "sshd is already running with the scoped omp broker reverse-forward policy"
    return 0
  fi
  "$bin" -t -o AllowTcpForwarding=remote -o GatewayPorts=no \
    -o "PermitListen=$FM_OMP_AUTH_BROKER_REMOTE_BIND" || {
      log "FATAL: sshd does not accept the scoped omp broker reverse-forward policy"
      return 1
    }
  "$bin" -o AllowTcpForwarding=remote -o GatewayPorts=no \
    -o "PermitListen=$FM_OMP_AUTH_BROKER_REMOTE_BIND" || return 1
  log "started sshd on port 22 with one loopback-only remote-forward listener"
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
      "$FM_NODE_ROOT/bin/"*|"$FM_LOCAL_BIN/"*|"$FM_NPM_PREFIX/bin/"*|"$FM_BUN_ROOT/bin/"*)
        [ -e "$source" ] || rm -f -- "$target" || return 1
        ;;
    esac
  done
  for source in "$FM_NODE_ROOT/bin"/* "$FM_LOCAL_BIN"/* "$FM_NPM_PREFIX/bin"/* "$FM_BUN_ROOT/bin"/*; do
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

ensure_claude_headless() {
  local helper="$FM_REMOTE_ROOT/bin/fm-claude-headless-setup.sh"
  [ -x "$helper" ] || { log "the Claude headless setup helper is missing from the code root"; return 1; }
  "$helper" || { log "Claude's unattended root state could not be prepared"; return 1; }
  log "prepared Claude's unattended root state and disabled its git attribution"
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
  # --parity because this host is contracted to do everything a local second
  # mate and its crews do, not just the remote minimum.
  FM_ROOT_OVERRIDE="$FM_REMOTE_ROOT" FM_HOME="$FM_REMOTE_HOME" \
    "$doctor" --fix --parity >> "$FM_BOOT_LOG" 2>&1 || {
      log "the readiness repair reported remaining gaps; see $FM_BOOT_LOG"
      return 1
    }
}

hold_pod() {
  while :; do
    sleep 3600
  done
}

usage() {
  printf '%s\n' \
    'Usage:' \
    '  fm-runpod-pod-boot.sh' \
    '  fm-runpod-pod-boot.sh --check' \
    '  fm-runpod-pod-boot.sh --install-omp-auth-broker-token < token-file' \
    '  fm-runpod-pod-boot.sh --check-omp-auth-broker-client' \
    '  fm-runpod-pod-boot.sh --help'
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
    --check)
      toolchain_plan
      exit 0
      ;;
    --install-omp-auth-broker-token)
      install_omp_auth_broker_token
      exit $?
      ;;
    --check-omp-auth-broker-client)
      check_omp_auth_broker_client
      exit $?
      ;;
    '') ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  require_volume || exit 1
  ensure_runpod_sandbox_marker || exit 1
  install_boot_control || exit 1
  # Before anything writes under a home: everything below, including the
  # authorized key and every later login, must land on the volume.
  ensure_account_home || exit 1
  ensure_account_shell || exit 1
  fm_treehouse_root_prepare_runpod_boot || exit 1
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
  # Deliberately not fatal: an SSH login landing in the container-local home is
  # a reported readiness gap, not a reason to give up the diagnostic channel.
  # The doctor's durable-home check is what refuses to call such a pod ready.
  bind_account_home_to_sshd || log "logins will not land on the durable account home"
  authorize_key || log "the authorized key could not be written"
  start_sshd || { log "FATAL: sshd did not start; this pod has no diagnostic channel"; hold_pod; }
  log "sshd is up; diagnostic access is available before provisioning starts"

  # Everything below can fail without taking SSH away. Each failure logs and
  # holds the pod open so the operator can connect and read this same log.
  if ! provision_toolchain; then
    log "FATAL: toolchain provisioning could not complete; connect over SSH and read $FM_BOOT_LOG"
    hold_pod
  fi
  ensure_browser_packages
  link_browser || { log "FATAL: the browser is not usable on this pod; connect over SSH and read $FM_BOOT_LOG"; hold_pod; }
  link_durable_bins || { log "FATAL: durable tools could not be linked; connect over SSH and read $FM_BOOT_LOG"; hold_pod; }
  link_entrypoint || { log "FATAL: the remote entrypoint could not be linked; connect over SSH and read $FM_BOOT_LOG"; hold_pod; }
  ensure_claude_headless || { log "FATAL: Claude headless setup failed; connect over SSH and read $FM_BOOT_LOG"; hold_pod; }
  # The workstation installs the bearer through the fixed boot-control path as
  # soon as sshd is reachable, then starts the loopback-only reverse tunnel.
  # Do not start the long-lived Herdr server before these exports exist: every
  # OMP secondmate and OMP crew pane must inherit the broker client path.
  wait_for_omp_auth_broker_client
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
