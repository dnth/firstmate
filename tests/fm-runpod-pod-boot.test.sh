#!/usr/bin/env bash
# First-boot toolchain provisioning for a RunPod pod, exercised against faked
# package managers and installers so the real script runs end to end with no
# pod, no network, and no paid resource.
#
# The load-bearing case is coverage: bin/fm-remote-doctor.sh owns what "ready"
# means, so this suite reads the doctor's OWN required-tool output through its
# documented line protocol and asserts the boot plan covers every entry. That is
# what stops the two lists from drifting apart as the doctor changes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOT="$ROOT/bin/fm-runpod-pod-boot.sh"
TMP_ROOT=$(fm_test_tmproot fm-runpod-pod-boot)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# --- the plan covers what the doctor requires --------------------------------

plan=$(bash "$BOOT" --check 2>&1) || fail "--check failed: $plan"

# The doctor reports one `required <tool>=...` line per required tool. Running it
# with an empty PATH makes every tool report MISSING, which is exactly the list
# of names it requires - read through its output, never from its source.
mkdir -p "$TMP_ROOT/empty-bin"
doctor_out=$(PATH="$TMP_ROOT/empty-bin" /bin/bash "$ROOT/bin/fm-remote-doctor.sh" 2>&1 || true)
required=$(printf '%s\n' "$doctor_out" | sed -n 's/^required \([a-z-]*\)=.*/\1/p' | sort -u)
[ -n "$required" ] || fail "could not read the doctor's required-tool list from its output"

for tool in $required; do
  [ "$tool" != harness ] || continue
  case "$plan" in
    *"ensure=$tool"*) ;;
    *) fail "the boot plan does not provision '$tool', which the doctor requires"$'\n'"plan:"$'\n'"$plan" ;;
  esac
done
pass "the first-boot plan covers every tool the doctor reports as required"

assert_contains "$plan" "ensure=code-root" "the plan must clone the code root so first boot needs no manual clone"
pass "the plan clones the code root on first boot"

# --- --check touches nothing -------------------------------------------------

probe="$TMP_ROOT/probe"
mkdir -p "$probe"
before=$(find "$probe" | sort)
FM_VOLUME="$probe" bash "$BOOT" --check >/dev/null 2>&1 || fail "--check failed against a probe volume"
[ "$(find "$probe" | sort)" = "$before" ] || fail "--check must not create anything on the volume"
pass "--check is a pure dry run"

# --- a real provisioning pass over faked tooling -----------------------------

# fakebin stands in for the package manager, npm, git, and the pinned installers.
# Each records its calls so the test can assert order, idempotence, and that the
# repository's own pinned installers are the ones used.
new_world() {  # <name> -> world dir
  local name=$1 w fakebin tool
  w="$TMP_ROOT/$name"
  mkdir -p "$w/volume" "$w/home" "$w/origin" "$w/templates" "$w/system-ssh" "$w/basebin"
  fakebin=$(fm_fakebin "$w")
  : > "$w/calls.log"

  # Keep the exercised boot independent of tools installed on the host runner.
  # These are only the neutral utilities the boot needs; provisioned tools live
  # in fakebin and disappear for real when a replacement pod is simulated.
  for tool in awk bash cat chmod cp date dirname env grep ln mkdir mktemp mv readlink rm sleep timeout uname; do
    ln -s "$(command -v "$tool")" "$w/basebin/$tool"
  done

  cat > "$w/templates/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "$FM_FAKE_CALLS"
if [ "${1:-}" = install ] && [ "${2:-}" = -g ]; then
  mkdir -p "$npm_config_prefix/bin"
  case "${3:-}" in
    tasks-axi) tool=tasks-axi ;;
    *) tool=harness ;;
  esac
  printf '#!/usr/bin/env bash\nexit 0\n' > "$npm_config_prefix/bin/$tool"
  chmod +x "$npm_config_prefix/bin/$tool"
fi
exit 0
SH
  chmod +x "$w/templates/npm"

  cat > "$fakebin/apt-get" <<'SH'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "$FM_FAKE_CALLS"
[ "${FM_FAKE_APT_FAIL:-0}" != 1 ] || exit 1
case " $* " in
  *" install "*)
    for pkg in "$@"; do
      case "$pkg" in
        git|jq|curl|unzip)
          printf '#!/usr/bin/env bash\nexit 0\n' > "$FM_FAKE_EPHEMERAL_BIN/$pkg"
          chmod +x "$FM_FAKE_EPHEMERAL_BIN/$pkg"
          ;;
        openssh-server)
          printf '#!/usr/bin/env bash\nexit 0\n' > "$FM_FAKE_EPHEMERAL_BIN/sshd"
          chmod +x "$FM_FAKE_EPHEMERAL_BIN/sshd"
          ;;
      esac
    done
    ;;
esac
exit 0
SH
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$FM_FAKE_CALLS"
out=
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift; out=${1:-} ;; esac
  shift || break
done
[ -n "$out" ] || exit 1
: > "$out"
SH
  cat > "$fakebin/sha256sum" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *node-v24.19.0-linux-x64.tar.gz)
    printf 'f625d97cd707df4ff96254916fbc5ff014f09c09effe5a1e0ca8f6d41a8789d4  %s\n' "$1"
    ;;
  *node-v24.19.0-linux-arm64.tar.gz)
    printf 'd28c8a5bf0a808f0ed434a1dce8c54ae98f0371c0bd86ac58abc613f73e6643f  %s\n' "$1"
    ;;
  *) exec /usr/bin/sha256sum "$@" ;;
esac
SH
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
archive=
dest=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -xzf) shift; archive=${1:-} ;;
    -C) shift; dest=${1:-} ;;
  esac
  shift || break
done
root=${archive##*/}
root=${root%.tar.gz}
mkdir -p "$dest/$root/bin"
version=${root#node-v}
version=${version%%-linux-*}
cat > "$dest/$root/bin/node" <<SH2
#!/usr/bin/env bash
[ "\${1:-}" != -v ] || { printf 'v$version\\n'; exit 0; }
exit 0
SH2
cp "$FM_FAKE_NPM_TEMPLATE" "$dest/$root/bin/npm"
chmod +x "$dest/$root/bin/node" "$dest/$root/bin/npm"
SH
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$FM_FAKE_CALLS"
if [ "${1:-}" = clone ]; then
  dest=${!#}
  mkdir -p "$dest/.git" "$dest/bin"
  for i in fm-install-herdr.sh fm-install-treehouse.sh; do
    tool=${i#fm-install-}
    tool=${tool%.sh}
    printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$FM_FAKE_CALLS"\nprintf '\''#!/usr/bin/env bash\\nexit 0\\n'\'' > "$1/%s"\nchmod +x "$1/%s"\n' "$i" "$tool" "$tool" > "$dest/bin/$i"
    chmod +x "$dest/bin/$i"
  done
  printf '#!/usr/bin/env bash\ncommand -v herdr >> "$FM_FAKE_CALLS" || exit 1\ncommand -v treehouse >> "$FM_FAKE_CALLS" || exit 1\ncommand -v tasks-axi >> "$FM_FAKE_CALLS" || exit 1\ncommand -v harness >> "$FM_FAKE_CALLS" || exit 1\nprintf "doctor %%s\\n" "$*" >> "$FM_FAKE_CALLS"\nexit 0\n' > "$dest/bin/fm-remote-doctor.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dest/bin/fm-remote-entrypoint.sh"
  chmod +x "$dest/bin/fm-remote-doctor.sh" "$dest/bin/fm-remote-entrypoint.sh"
fi
exit 0
SH
  cat > "$fakebin/ssh-keygen" <<'SH'
#!/usr/bin/env bash
key=
while [ "$#" -gt 0 ]; do
  case "$1" in -f) shift; key=${1:-} ;; esac
  shift || break
done
[ -n "$key" ] || exit 1
printf 'private\n' > "$key"
printf 'public\n' > "$key.pub"
SH
  cat > "$fakebin/sshd" <<'SH'
#!/usr/bin/env bash
printf 'sshd start\n' >> "$FM_FAKE_CALLS"
exit 0
SH
  for t in jq unzip; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$t"
  done
  cat > "$fakebin/pgrep" <<'SH'
#!/usr/bin/env bash
# No daemon is running in a fresh test world. Returning not-found forces the
# real boot path to invoke the fake sshd instead of accepting a false positive.
exit 1
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$w"
}

# The boot script is a PID 1 payload that never returns, so provisioning is
# exercised through a bounded subshell that stops once the whole boot completes.
provision_only() {  # <world> [harness]
  local w=$1 harness=${2:-}
  mkdir -p "$w/volume/persistent-runtime"
  : > "$w/volume/persistent-runtime/boot.log"
  (
    PATH="$w/fakebin:$w/basebin" \
    HOME="$w/home" \
    FM_VOLUME="$w/volume" \
    FM_REMOTE_ORIGIN="$w/origin" \
    FM_FAKE_CALLS="$w/calls.log" \
    FM_FAKE_EPHEMERAL_BIN="$w/fakebin" \
    FM_FAKE_NPM_TEMPLATE="$w/templates/npm" \
    FM_SYSTEM_SSH_DIR="$w/system-ssh" \
    FM_SSHD_FALLBACK="$w/fakebin/sshd" \
    FM_POD_HARNESS_NPM="$harness" \
    timeout 60 bash "$BOOT" >/dev/null 2>&1 &
    boot_pid=$!
    for _ in $(seq 1 300); do
      grep -qxF "harness=$harness" "$w/volume/persistent-runtime/toolchain.provisioned" 2>/dev/null && break
      kill -0 "$boot_pid" 2>/dev/null || break
      sleep 0.1
    done
    sleep 1
    kill "$boot_pid" 2>/dev/null || true
    wait "$boot_pid" 2>/dev/null || true
  )
}

# A boot that changes nothing has no marker transition to wait for, so it is
# given a fixed settle window instead.
provision_idempotent() {  # <world> [harness]
  local w=$1 harness=${2:-}
  (
    PATH="$w/fakebin:$w/basebin" \
    HOME="$w/home" \
    FM_VOLUME="$w/volume" \
    FM_REMOTE_ORIGIN="$w/origin" \
    FM_FAKE_CALLS="$w/calls.log" \
    FM_FAKE_EPHEMERAL_BIN="$w/fakebin" \
    FM_FAKE_NPM_TEMPLATE="$w/templates/npm" \
    FM_SYSTEM_SSH_DIR="$w/system-ssh" \
    FM_SSHD_FALLBACK="$w/fakebin/sshd" \
    FM_POD_HARNESS_NPM="$harness" \
    timeout 30 bash "$BOOT" >/dev/null 2>&1 &
    boot_pid=$!
    sleep 3
    kill "$boot_pid" 2>/dev/null || true
    wait "$boot_pid" 2>/dev/null || true
  )
}

w=$(new_world provision)
provision_only "$w"
calls=$(cat "$w/calls.log")

assert_contains "$calls" "git clone" "first boot must clone the code root"
assert_contains "$calls" "fm-install-herdr.sh" "herdr must come from the repository's pinned installer"
assert_contains "$calls" "fm-install-treehouse.sh" "treehouse must come from the repository's pinned installer"
assert_contains "$calls" "npm install -g tasks-axi" "tasks-axi must be installed"
assert_present "$w/volume/persistent-runtime/bin/herdr" "the pinned herdr binary must live on the volume"
assert_present "$w/volume/persistent-runtime/npm/bin/tasks-axi" "the global npm prefix must live on the volume"
assert_present "$w/volume/persistent-runtime/node/bin/node" "the pinned Node runtime must live on the volume"
assert_contains "$calls" "$w/volume/persistent-runtime/bin/herdr" "the doctor must see pinned tools through the durable PATH"
assert_contains "$calls" "$w/volume/persistent-runtime/npm/bin/tasks-axi" "the doctor must see npm tools through the durable PATH"
assert_present "$w/home/.local/bin/herdr" "later SSH jobs must receive a per-pod link to durable tools"
assert_present "$w/home/.local/bin/node" "later SSH jobs must receive a per-pod link to durable Node"
assert_present "$w/home/.local/bin/tasks-axi" "later SSH jobs must receive a per-pod link to durable npm tools"
assert_present "$w/volume/persistent-runtime/toolchain.provisioned" "a completed provisioning run must record its marker"
pass "first boot clones the code root and installs the required toolchain through the pinned installers"

assert_not_contains "$calls" "npm install -g @" "no harness package may be installed unless one is configured"
assert_absent "$w/volume/persistent-runtime/boot.ready" \
  "an unset harness must leave readiness to the doctor's human-step refusal"
pass "no harness is installed when none is configured, leaving that gap to the doctor"

provision_only "$w" "@example/harness"
assert_contains "$(cat "$w/calls.log")" "npm install -g @example/harness" \
  "changing the configured harness must invalidate the durable marker and install it"
assert_present "$w/volume/persistent-runtime/boot.ready" \
  "a configured durable harness must permit the doctor-owned readiness handoff"

# --- idempotence -------------------------------------------------------------

: > "$w/calls.log"
provision_idempotent "$w" "@example/harness"
second=$(cat "$w/calls.log")
assert_not_contains "$second" "git clone" "a second boot must not re-clone the code root"
assert_not_contains "$second" "npm install -g tasks-axi" "a second boot must not reinstall the toolchain"
pass "provisioning is idempotent across boots on the same volume"

rm -rf "${w:?}/home"
rm -rf "${w:?}/system-ssh"
mkdir -p "$w/home" "$w/system-ssh"
rm -f "$w/fakebin/git" "$w/fakebin/jq" "$w/fakebin/curl" "$w/fakebin/unzip" \
  "$w/fakebin/sshd"
: > "$w/calls.log"
provision_only "$w" "@example/harness"
replacement=$(cat "$w/calls.log")
assert_contains "$replacement" "apt-get install" "a replacement pod must restore its ephemeral system prerequisites"
assert_not_contains "$replacement" "curl -fsSL" "a replacement pod must not reinstall its durable Node runtime"
assert_not_contains "$replacement" "git clone" "a replacement pod must reuse the durable code root"
assert_not_contains "$replacement" "fm-install-herdr.sh" "a replacement pod must reuse durable pinned tools"
assert_not_contains "$replacement" "npm install -g tasks-axi" "a replacement pod must reuse its durable npm prefix"
assert_contains "$replacement" "$w/volume/persistent-runtime/bin/herdr" "a replacement doctor handoff must see durable tools"
assert_present "$w/home/.local/bin/herdr" "a replacement pod must recreate its SSH-visible durable-tool links"
assert_present "$w/home/.local/bin/node" "a replacement pod must recreate its SSH-visible durable Node link"
[ "$(readlink "$w/home/.local/bin/node")" = "$w/volume/persistent-runtime/node/bin/node" ] \
  || fail "a replacement pod must serve Node from the retained volume"
assert_present "$w/volume/persistent-runtime/boot.ready" "a replacement pod must reach readiness from the retained volume"
pass "replacement pods restore ephemeral prerequisites and reuse the durable toolchain"

# --- pre-existing tools cannot bypass the repository pins -------------------

printf '#!/usr/bin/env bash\nexit 0\n' > "$w/volume/persistent-runtime/bin/herdr"
printf '#!/usr/bin/env bash\nexit 0\n' > "$w/volume/persistent-runtime/bin/treehouse"
chmod +x "$w/volume/persistent-runtime/bin/herdr" "$w/volume/persistent-runtime/bin/treehouse"
printf '0\n' > "$w/volume/persistent-runtime/toolchain.provisioned"
: > "$w/calls.log"
provision_only "$w" "@example/harness"
pinned=$(cat "$w/calls.log")
assert_contains "$pinned" "fm-install-herdr.sh" "a stale contract must replace a pre-existing herdr through the pinned installer"
assert_contains "$pinned" "fm-install-treehouse.sh" "a stale contract must replace a pre-existing treehouse through the pinned installer"
pass "a contract bump cannot be satisfied by pre-existing unverified tools"

# --- a raised contract re-provisions exactly once ----------------------------

printf '0\n' > "$w/volume/persistent-runtime/toolchain.provisioned"
: > "$w/calls.log"
provision_only "$w" "@example/harness"
raised=$(cat "$w/calls.log")
assert_contains "$raised" "npm install -g tasks-axi" "a stale contract version must re-provision"
[ "$(cat "$w/volume/persistent-runtime/toolchain.provisioned")" != 0 ] \
  || fail "re-provisioning must record the current contract version"
pass "a raised toolchain contract re-provisions exactly once"

[ "$("$w/volume/persistent-runtime/node/bin/node" -v)" = v24.19.0 ] \
  || fail "new volumes must pin the current Node 24.19.0 LTS runtime"
pass "new volumes install the current pinned Node LTS"

# --- the marker follows the configured harness -------------------------------

w2=$(new_world harness)
provision_only "$w2"
: > "$w2/calls.log"
provision_only "$w2" "@example/harness"
assert_contains "$(cat "$w2/calls.log")" "npm install -g @example/harness" \
  "changing the configured harness must invalidate the durable marker and install it"
: > "$w2/calls.log"
provision_idempotent "$w2" "@example/harness"
assert_not_contains "$(cat "$w2/calls.log")" "npm install -g @example/harness" \
  "the marker bound to the configured harness must make its next boot idempotent"
: > "$w2/calls.log"
provision_only "$w2"
assert_absent "$w2/volume/persistent-runtime/npm/bin/harness" \
  "unsetting the harness must remove its durable executable"
assert_absent "$w2/home/.local/bin/harness" \
  "unsetting the harness must remove its SSH-visible executable"
assert_absent "$w2/volume/persistent-runtime/boot.ready" \
  "an unset harness must not leave a stale readiness marker"
pass "the durable marker reconciles harness configuration in both directions"

# --- base-package failures cannot satisfy the contract ----------------------

w4=$(new_world packages)
rm -f "$w4/fakebin/sshd"
out=$(
  PATH="$w4/fakebin:$w4/basebin" HOME="$w4/home" FM_VOLUME="$w4/volume" \
  FM_REMOTE_ORIGIN="$w4/origin" FM_FAKE_CALLS="$w4/calls.log" \
  FM_FAKE_EPHEMERAL_BIN="$w4/fakebin" FM_FAKE_NPM_TEMPLATE="$w4/templates/npm" \
  FM_SYSTEM_SSH_DIR="$w4/system-ssh" \
  FM_SSHD_FALLBACK="$w4/fakebin/sshd" \
  FM_FAKE_APT_FAIL=1 \
  timeout 3 bash "$BOOT" 2>&1 || true
)
assert_contains "$out" "base-package index could not be updated" "a package-manager failure must be reported"
assert_absent "$w4/volume/persistent-runtime/toolchain.provisioned" \
  "a package-manager failure must not record a satisfied contract"
assert_not_contains "$out" "boot complete" "a failed package contract must never report boot completion"
pass "base-package failure propagates and leaves the pod unready"

w5=$(new_world oldnode)
mkdir -p "$w5/volume/persistent-runtime/node/bin"
cat > "$w5/volume/persistent-runtime/node/bin/node" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != -v ] || { printf 'v18.20.0\n'; exit 0; }
exit 0
SH
chmod +x "$w5/volume/persistent-runtime/node/bin/node"
provision_only "$w5"
assert_contains "$(cat "$w5/calls.log")" "node-v24.19.0" \
  "an unsupported durable Node must be replaced by the pinned volume runtime"
assert_present "$w5/volume/persistent-runtime/toolchain.provisioned" \
  "the corrected durable Node must permit the contract marker"
pass "an unsupported durable Node is replaced before the contract is recorded"

w6=$(new_world hostkeyfail)
real_cp=$(command -v cp)
cat > "$w6/fakebin/cp" <<SH
#!/usr/bin/env bash
case "\${*: -1}" in
  "$w6/volume/persistent-runtime/ssh/"*) exit 1 ;;
esac
exec "$real_cp" "\$@"
SH
chmod +x "$w6/fakebin/cp"
out=$(
  PATH="$w6/fakebin:$w6/basebin" HOME="$w6/home" FM_VOLUME="$w6/volume" \
  FM_REMOTE_ORIGIN="$w6/origin" FM_FAKE_CALLS="$w6/calls.log" \
  FM_FAKE_EPHEMERAL_BIN="$w6/fakebin" FM_FAKE_NPM_TEMPLATE="$w6/templates/npm" \
  FM_SYSTEM_SSH_DIR="$w6/system-ssh" \
  FM_SSHD_FALLBACK="$w6/fakebin/sshd" \
  timeout 4 bash "$BOOT" 2>&1 || true
)
assert_contains "$out" "volume-backed host key could not be restored or persisted" \
  "a host-key persistence failure must refuse before SSH starts"
assert_not_contains "$(cat "$w6/calls.log")" "sshd start" \
  "sshd must not start with a container-local host identity"
assert_absent "$w6/volume/persistent-runtime/boot.ready" \
  "a host-key persistence failure must never record readiness"
pass "host-key persistence failures fail closed before sshd"

# --- sshd is the diagnostic channel and survives failed provisioning ---------
#
# RunPod exposes no log or console API, so a pod whose provisioning fails must
# still be reachable over SSH or the failure cannot be inspected at all. A live
# pilot lost 25 minutes to exactly this: sshd was gated behind provisioning, the
# port stayed refused, and nothing could be diagnosed. These assert the ordering
# that makes the failure observable, and that readiness stays separate from it.

w4=$(new_world sshd_first)
rm -rf "$w4/origin"        # provisioning cannot obtain a code root, so it MUST fail
(
  PATH="$w4/fakebin:$w4/basebin" HOME="$w4/home" FM_VOLUME="$w4/volume" \
  FM_REMOTE_ORIGIN="" FM_FAKE_CALLS="$w4/calls.log" FM_LOCAL_BIN="$w4/home/.local/bin" \
  FM_FAKE_EPHEMERAL_BIN="$w4/fakebin" FM_FAKE_NPM_TEMPLATE="$w4/templates/npm" \
  FM_SYSTEM_SSH_DIR="$w4/system-ssh" FM_SSHD_FALLBACK="$w4/fakebin/sshd" \
  timeout 25 bash "$BOOT" >/dev/null 2>&1 &
  bp=$!
  sleep 4
  kill "$bp" 2>/dev/null || true
  wait "$bp" 2>/dev/null || true
)
boot_log="$w4/volume/persistent-runtime/boot.log"
assert_present "$boot_log" "a failing boot must still leave its log on the volume"
log_text=$(cat "$boot_log" 2>/dev/null)
assert_contains "$(cat "$w4/calls.log")" "sshd start" \
  "the failing boot must actually invoke sshd before provisioning"
assert_contains "$log_text" "started sshd on port 22" \
  "sshd must come up BEFORE provisioning so a failure is diagnosable"
sshd_line=$(grep -n "started sshd on port 22" "$boot_log" | head -1 | cut -d: -f1)
fail_line=$(grep -n "provisioning could not complete" "$boot_log" | head -1 | cut -d: -f1)
[ -n "$fail_line" ] || fail "the provisioning failure was not recorded in the boot log"
[ "$sshd_line" -lt "$fail_line" ] \
  || fail "sshd came up after the provisioning failure; the pod would be unreachable"
assert_absent "$w4/volume/persistent-runtime/boot.ready" \
  "a failed provisioning must NOT publish the readiness sentinel"
pass "sshd comes up before provisioning, so a failed provision stays diagnosable"
pass "readiness stays gated on the sentinel, not on sshd being up"

# --- no origin and no clone is a loud refusal, not a silent partial boot -----

w3=$(new_world noorigin)
out=$(
  PATH="$w3/fakebin:$w3/basebin" HOME="$w3/home" FM_VOLUME="$w3/volume" \
  FM_REMOTE_ORIGIN="" FM_FAKE_CALLS="$w3/calls.log" \
  FM_FAKE_EPHEMERAL_BIN="$w3/fakebin" FM_FAKE_NPM_TEMPLATE="$w3/templates/npm" \
  FM_SYSTEM_SSH_DIR="$w3/system-ssh" \
  FM_SSHD_FALLBACK="$w3/fakebin/sshd" \
  timeout 20 bash "$BOOT" 2>&1 &
  boot_pid=$!
  sleep 3
  kill "$boot_pid" 2>/dev/null || true
  wait "$boot_pid" 2>/dev/null || true
)
assert_contains "$out" "no code root" "a pod with no clone and no origin must say so plainly"
assert_absent "$w3/volume/persistent-runtime/toolchain.provisioned" \
  "a failed provisioning run must not record a satisfied marker"
assert_not_contains "$out" "boot complete" "a failed clone contract must never report boot completion"
pass "a pod that cannot obtain a code root refuses loudly and records no marker"
