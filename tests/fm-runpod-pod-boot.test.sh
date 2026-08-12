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
  local name=$1 w fakebin
  w="$TMP_ROOT/$name"
  mkdir -p "$w/volume" "$w/home/.local/bin" "$w/origin"
  fakebin=$(fm_fakebin "$w")
  : > "$w/calls.log"

  cat > "$fakebin/apt-get" <<'SH'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "$FM_FAKE_CALLS"
exit 0
SH
  cat > "$fakebin/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "$FM_FAKE_CALLS"
exit 0
SH
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != -v ] || { printf 'v22.11.0\n'; exit 0; }
exit 0
SH
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$FM_FAKE_CALLS"
if [ "${1:-}" = clone ]; then
  dest=${!#}
  mkdir -p "$dest/.git" "$dest/bin"
  for i in fm-install-herdr.sh fm-install-treehouse.sh; do
    printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> "$FM_FAKE_CALLS"\nexit 0\n' "$i" > "$dest/bin/$i"
    chmod +x "$dest/bin/$i"
  done
  printf '#!/usr/bin/env bash\nprintf "doctor %%s\\n" "$*" >> "$FM_FAKE_CALLS"\nexit 0\n' > "$dest/bin/fm-remote-doctor.sh"
  chmod +x "$dest/bin/fm-remote-doctor.sh"
fi
exit 0
SH
  for t in jq curl unzip sshd ssh-keygen pgrep; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$t"
  done
  chmod +x "$fakebin"/*
  printf '%s\n' "$w"
}

# The boot script is a PID 1 payload that never returns, so provisioning is
# exercised through a bounded subshell that stops once the marker appears.
# Waits until the recorded contract CHANGES rather than until the marker merely
# exists, so a stale-contract re-provisioning run is not killed before it starts.
provision_only() {  # <world>
  local w=$1 marker before now
  marker="$w/volume/persistent-runtime/toolchain.provisioned"
  before=$(cat "$marker" 2>/dev/null || true)
  (
    PATH="$w/fakebin:/usr/bin:/bin" \
    HOME="$w/home" \
    FM_VOLUME="$w/volume" \
    FM_REMOTE_ORIGIN="$w/origin" \
    FM_FAKE_CALLS="$w/calls.log" \
    FM_LOCAL_BIN="$w/home/.local/bin" \
    timeout 60 bash "$BOOT" >/dev/null 2>&1 &
    boot_pid=$!
    for _ in $(seq 1 300); do
      now=$(cat "$marker" 2>/dev/null || true)
      [ -n "$now" ] && [ "$now" != "$before" ] && break
      kill -0 "$boot_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill "$boot_pid" 2>/dev/null || true
    wait "$boot_pid" 2>/dev/null || true
  )
}

# A boot that changes nothing has no marker transition to wait for, so it is
# given a fixed settle window instead.
provision_idempotent() {  # <world>
  local w=$1
  (
    PATH="$w/fakebin:/usr/bin:/bin" \
    HOME="$w/home" \
    FM_VOLUME="$w/volume" \
    FM_REMOTE_ORIGIN="$w/origin" \
    FM_FAKE_CALLS="$w/calls.log" \
    FM_LOCAL_BIN="$w/home/.local/bin" \
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
assert_present "$w/volume/persistent-runtime/toolchain.provisioned" "a completed provisioning run must record its marker"
pass "first boot clones the code root and installs the required toolchain through the pinned installers"

assert_not_contains "$calls" "npm install -g @" "no harness package may be installed unless one is configured"
pass "no harness is installed when none is configured, leaving that gap to the doctor"

# --- idempotence -------------------------------------------------------------

: > "$w/calls.log"
provision_idempotent "$w"
second=$(cat "$w/calls.log")
assert_not_contains "$second" "git clone" "a second boot must not re-clone the code root"
assert_not_contains "$second" "npm install -g tasks-axi" "a second boot must not reinstall the toolchain"
pass "provisioning is idempotent across boots on the same volume"

# --- a raised contract re-provisions exactly once ----------------------------

printf '0\n' > "$w/volume/persistent-runtime/toolchain.provisioned"
: > "$w/calls.log"
provision_only "$w"
raised=$(cat "$w/calls.log")
assert_contains "$raised" "npm install -g tasks-axi" "a stale contract version must re-provision"
[ "$(cat "$w/volume/persistent-runtime/toolchain.provisioned")" != 0 ] \
  || fail "re-provisioning must record the current contract version"
pass "a raised toolchain contract re-provisions exactly once"

# --- a configured harness is installed ---------------------------------------

w2=$(new_world harness)
(
  export FM_POD_HARNESS_NPM="@example/harness"
  PATH="$w2/fakebin:/usr/bin:/bin" HOME="$w2/home" FM_VOLUME="$w2/volume" \
  FM_REMOTE_ORIGIN="$w2/origin" FM_FAKE_CALLS="$w2/calls.log" \
  FM_LOCAL_BIN="$w2/home/.local/bin" \
  timeout 60 bash "$BOOT" >/dev/null 2>&1 &
  boot_pid=$!
  for _ in $(seq 1 300); do
    [ -f "$w2/volume/persistent-runtime/toolchain.provisioned" ] && break
    kill -0 "$boot_pid" 2>/dev/null || break
    sleep 0.1
  done
  kill "$boot_pid" 2>/dev/null || true
  wait "$boot_pid" 2>/dev/null || true
)
assert_contains "$(cat "$w2/calls.log")" "npm install -g @example/harness" \
  "a configured harness package must be installed"
pass "a configured harness package is installed on first boot"

# --- no origin and no clone is a loud refusal, not a silent partial boot -----

w3=$(new_world noorigin)
out=$(
  PATH="$w3/fakebin:/usr/bin:/bin" HOME="$w3/home" FM_VOLUME="$w3/volume" \
  FM_REMOTE_ORIGIN="" FM_FAKE_CALLS="$w3/calls.log" \
  FM_LOCAL_BIN="$w3/home/.local/bin" \
  timeout 20 bash "$BOOT" 2>&1 &
  boot_pid=$!
  sleep 3
  kill "$boot_pid" 2>/dev/null || true
  wait "$boot_pid" 2>/dev/null || true
)
assert_contains "$out" "no code root" "a pod with no clone and no origin must say so plainly"
assert_absent "$w3/volume/persistent-runtime/toolchain.provisioned" \
  "a failed provisioning run must not record a satisfied marker"
pass "a pod that cannot obtain a code root refuses loudly and records no marker"
