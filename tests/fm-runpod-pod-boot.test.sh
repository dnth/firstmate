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
doctor_out_parity=$(PATH="$TMP_ROOT/empty-bin" /bin/bash "$ROOT/bin/fm-remote-doctor.sh" --parity 2>&1 || true)
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

# A RunPod second mate must reach FULL local parity, so the same drift guard
# applies to the doctor's parity tier: every tool it names there is read from its
# own --parity output and must appear in the plan. Adding a parity tool to the
# doctor without provisioning it here fails right here.
parity=$(printf '%s\n' "$doctor_out_parity" | sed -n 's/^parity \([a-z0-9-]*\)=.*/\1/p' | sort -u)
[ -n "$parity" ] || fail "could not read the doctor's parity-tool list from its --parity output"
for tool in $parity; do
  case "$plan" in
    *"ensure=$tool"*) ;;
    *) fail "the boot plan does not provision '$tool', which the doctor requires for parity"$'\n'"plan:"$'\n'"$plan" ;;
  esac
done
pass "the first-boot plan covers every tool the doctor reports as required for parity"

assert_contains "$plan" "ensure=code-root" "the plan must clone the code root so first boot needs no manual clone"
assert_contains "$plan" "ensure=account-home" \
  "the plan must move the account home onto the volume so logins survive pod replacement"
assert_contains "$plan" "ensure=account-shell" \
  "the plan must publish the durable account bin and root-sandbox marker to login shells"
assert_contains "$plan" "ensure=claude-headless" \
  "the plan must prepare Claude's unattended root-sandbox state"
assert_contains "$plan" "ensure=bun" "omp runs on bun, so the plan must provision the bun runtime"
pass "the plan clones the code root, makes the account home durable, and prepares unattended shells"

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
  mkdir -p "$w/volume" "$w/home" "$w/origin" "$w/templates" "$w/system-ssh" "$w/basebin" "$w/etc"
  fakebin=$(fm_fakebin "$w")
  : > "$w/calls.log"
  # Stands in for the container's /etc/passwd. sshd reads the account home from
  # it, so the boot must rewrite it for a login to land on the volume.
  printf '%s:x:%s:%s:%s:/root:/bin/bash\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' \
    "$(id -un)" "$(id -u)" "$(id -g)" "$(id -un)" > "$w/etc/passwd"

  # Keep the exercised boot independent of tools installed on the host runner.
  # These are only the neutral utilities the boot needs; provisioned tools live
  # in fakebin and disappear for real when a replacement pod is simulated.
  for tool in awk bash cat chmod cp date dirname env grep head id ln mkdir mktemp mv \
    readlink rm sed seq sleep timeout uname; do
    ln -s "$(command -v "$tool")" "$w/basebin/$tool"
  done

  cat > "$w/templates/npm" <<'SH'
#!/usr/bin/env bash
printf 'npm %s\n' "$*" >> "$FM_FAKE_CALLS"
if [ "${1:-}" = install ] && [ "${2:-}" = -g ]; then
  mkdir -p "$npm_config_prefix/bin"
  case "${3:-}" in
    tasks-axi|gh-axi|chrome-devtools-axi|lavish-axi|quota-axi) tool=${3:-} ;;
    @openai/codex) tool=codex ;;
    @colbymchenry/codegraph) tool=codegraph ;;
    *) tool=harness ;;
  esac
  printf '#!/usr/bin/env bash\nexit 0\n' > "$npm_config_prefix/bin/$tool"
  chmod +x "$npm_config_prefix/bin/$tool"
fi
exit 0
SH
  # The browser is fetched through the published @puppeteer/browsers CLI, which
  # unpacks a versioned Chrome for Testing tree under --path.
  cat > "$w/templates/npx" <<'SH'
#!/usr/bin/env bash
printf 'npx %s\n' "$*" >> "$FM_FAKE_CALLS"
path=
while [ "$#" -gt 0 ]; do
  case "$1" in --path) shift; path=${1:-} ;; esac
  shift || break
done
[ -n "$path" ] || exit 0
mkdir -p "$path/chrome/linux64-140.0.7339.80/chrome-linux64"
# Echoes its argv so a caller can assert what the published browser launches with.
printf '#!/usr/bin/env bash\nprintf "chrome %%s\\n" "$*"\nexit 0\n' \
  > "$path/chrome/linux64-140.0.7339.80/chrome-linux64/chrome"
chmod +x "$path/chrome/linux64-140.0.7339.80/chrome-linux64/chrome"
exit 0
SH
  # bun installs itself into BUN_INSTALL, and its global installs land in the
  # same durable prefix, so omp survives pod replacement with the volume.
  cat > "$w/templates/bun" <<'SH'
#!/usr/bin/env bash
printf 'bun %s\n' "$*" >> "$FM_FAKE_CALLS"
if [ "${1:-}" = install ] && [ "${2:-}" = -g ]; then
  mkdir -p "$BUN_INSTALL/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BUN_INSTALL/bin/omp"
  chmod +x "$BUN_INSTALL/bin/omp"
fi
exit 0
SH
  chmod +x "$w/templates/npm" "$w/templates/npx" "$w/templates/bun"

  cat > "$fakebin/apt-get" <<'SH'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "$FM_FAKE_CALLS"
[ "${FM_FAKE_APT_FAIL:-0}" != 1 ] || exit 1
case " $* " in
  *" install "*)
    for pkg in "$@"; do
      case "$pkg" in
        git)
          if [ ! -x "$FM_FAKE_EPHEMERAL_BIN/$pkg" ]; then
            printf '#!/usr/bin/env bash\nexit 0\n' > "$FM_FAKE_EPHEMERAL_BIN/$pkg"
            chmod +x "$FM_FAKE_EPHEMERAL_BIN/$pkg"
          fi
          ;;
        jq|curl|unzip)
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
  # Downloads land in a file with -o; the vendor install scripts are piped to a
  # shell instead, so with no -o this prints the script those pipelines run.
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$FM_FAKE_CALLS"
out= url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; out=${1:-} ;;
    http://*|https://*) url=$1 ;;
  esac
  shift || break
done
if [ -n "$out" ]; then : > "$out"; exit 0; fi
case "$url" in
  *api.github.com/repos/cli/cli/releases/latest*)
    printf '{"tag_name": "v2.99.0", "name": "GitHub CLI 2.99.0"}\n'
    ;;
  *bun.sh/install*)
    printf 'mkdir -p "$BUN_INSTALL/bin"\n'
    printf 'cp "$FM_FAKE_BUN_TEMPLATE" "$BUN_INSTALL/bin/bun"\n'
    printf 'chmod +x "$BUN_INSTALL/bin/bun"\n'
    ;;
  *claude.ai/install.sh*)
    printf 'mkdir -p "$HOME/.local/bin"\n'
    printf 'printf "#!/usr/bin/env bash\\nexit 0\\n" > "$HOME/.local/bin/claude"\n'
    printf 'chmod +x "$HOME/.local/bin/claude"\n'
    ;;
  *no-mistakes*install.sh*)
    printf 'mkdir -p "$HOME/.local/bin"\n'
    printf 'printf "#!/usr/bin/env bash\\nexit 0\\n" > "$HOME/.local/bin/no-mistakes"\n'
    printf 'chmod +x "$HOME/.local/bin/no-mistakes"\n'
    ;;
  *) exit 1 ;;
esac
exit 0
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
case "$root" in
  gh_*)
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dest/$root/bin/gh"
    chmod +x "$dest/$root/bin/gh"
    exit 0
    ;;
esac
version=${root#node-v}
version=${version%%-linux-*}
cat > "$dest/$root/bin/node" <<SH2
#!/usr/bin/env bash
[ "\${1:-}" != -v ] || { printf 'v$version\\n'; exit 0; }
exit 0
SH2
cp "$FM_FAKE_NPM_TEMPLATE" "$dest/$root/bin/npm"
cp "$FM_FAKE_NPX_TEMPLATE" "$dest/$root/bin/npx"
chmod +x "$dest/$root/bin/node" "$dest/$root/bin/npm" "$dest/$root/bin/npx"
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
  # Stands in for the readiness owner: it resolves every tool it is contracted
  # to require through the PATH the boot handed it, so a tool the boot installed
  # somewhere the doctor cannot see fails the handoff instead of passing.
  cat > "$dest/bin/fm-remote-doctor.sh" <<'DOCTOR'
#!/usr/bin/env bash
printf 'sandbox=%s\n' "${IS_SANDBOX:-unset}" >> "$FM_FAKE_CALLS"
[ "${IS_SANDBOX:-}" = 1 ] || exit 1
for tool in herdr treehouse tasks-axi omp; do
  command -v "$tool" >> "$FM_FAKE_CALLS" || exit 1
done
account=$(id -un) || exit 1
account_home=$(awk -F: -v user="$account" '$1 == user { print $6; exit }' "$FM_PASSWD_FILE")
durable_root=$(cat "$FM_DURABLE_ROOT_FILE")
case "$account_home" in "$durable_root"|"$durable_root"/*) ;; *) exit 1 ;; esac
case " $* " in
  *" --parity "*)
    for tool in claude codex no-mistakes gh gh-axi chrome-devtools-axi \
      lavish-axi quota-axi codegraph google-chrome; do
      command -v "$tool" >> "$FM_FAKE_CALLS" || exit 1
    done
    ;;
esac
printf 'doctor %s\n' "$*" >> "$FM_FAKE_CALLS"
exit 0
DOCTOR
  cp "$FM_FAKE_CLAUDE_SETUP" "$dest/bin/fm-claude-headless-setup.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dest/bin/fm-remote-entrypoint.sh"
  chmod +x "$dest/bin/fm-remote-doctor.sh" "$dest/bin/fm-remote-entrypoint.sh" \
    "$dest/bin/fm-claude-headless-setup.sh"
fi
if [ "${1:-}" = -C ] && [ "${3:-}" = pull ]; then
  cp "$FM_FAKE_CLAUDE_SETUP" "$2/bin/fm-claude-headless-setup.sh"
  chmod +x "$2/bin/fm-claude-headless-setup.sh"
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

# One owner for the pod environment every case boots under, so a new contract
# variable is added in a single place instead of six.
world_env() {  # <world> [harness]; exports into the calling subshell
  local w=$1 harness=${2:-}
  export PATH="$w/fakebin:$w/basebin"
  export HOME="$w/home"
  export FM_VOLUME="$w/volume"
  export FM_REMOTE_ORIGIN="$w/origin"
  export FM_FAKE_CALLS="$w/calls.log"
  export FM_FAKE_EPHEMERAL_BIN="$w/fakebin"
  export FM_FAKE_NPM_TEMPLATE="$w/templates/npm"
  export FM_FAKE_NPX_TEMPLATE="$w/templates/npx"
  export FM_FAKE_BUN_TEMPLATE="$w/templates/bun"
  export FM_FAKE_CLAUDE_SETUP="$ROOT/bin/fm-claude-headless-setup.sh"
  export FM_SYSTEM_SSH_DIR="$w/system-ssh"
  export FM_SSHD_FALLBACK="$w/fakebin/sshd"
  export FM_PASSWD_FILE="$w/etc/passwd"
  export FM_DURABLE_ROOT_FILE="$w/etc/durable-root"
  export FM_CHROME_LINK="$w/fakebin/google-chrome"
  export FM_POD_HARNESS_NPM="$harness"
}

# The boot script is a PID 1 payload that never returns, so provisioning is
# exercised through a bounded subshell that stops once the whole boot completes.
provision_only() {  # <world> [harness]
  local w=$1 harness=${2:-}
  mkdir -p "$w/volume/persistent-runtime"
  : > "$w/volume/persistent-runtime/boot.log"
  rm -f "$w/volume/persistent-runtime/boot.ready"
  (
    world_env "$w" "$harness"
    timeout 60 bash "$BOOT" >/dev/null 2>&1 &
    boot_pid=$!
    for _ in $(seq 1 300); do
      grep -qF 'boot complete; holding the pod open' \
        "$w/volume/persistent-runtime/boot.log" 2>/dev/null && break
      kill -0 "$boot_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill "$boot_pid" 2>/dev/null || true
    wait "$boot_pid" 2>/dev/null || true
  )
}

# A boot that changes nothing has no marker transition to wait for, so it is
# given a fixed settle window instead.
provision_idempotent() {  # <world> [harness]
  local w=$1 harness=${2:-}
  (
    world_env "$w" "$harness"
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
HOMEDIR="$w/volume/home"
# The doctor resolves tools through the account bin directory, which is what the
# fixed remote entrypoint puts first when it composes a later job's PATH, and
# every entry there is a link into the volume.
assert_contains "$calls" "$HOMEDIR/.local/bin/herdr" "the doctor must see pinned tools through the account PATH"
assert_contains "$calls" "$HOMEDIR/.local/bin/tasks-axi" "the doctor must see npm tools through the account PATH"
[ "$(readlink "$HOMEDIR/.local/bin/herdr")" = "$w/volume/persistent-runtime/bin/herdr" ] \
  || fail "the account PATH must resolve the pinned herdr on the volume"
assert_present "$HOMEDIR/.local/bin/herdr" "later SSH jobs must receive a per-pod link to durable tools"
assert_present "$HOMEDIR/.local/bin/node" "later SSH jobs must receive a per-pod link to durable Node"
assert_present "$HOMEDIR/.local/bin/tasks-axi" "later SSH jobs must receive a per-pod link to durable npm tools"
assert_present "$w/volume/persistent-runtime/toolchain.provisioned" "a completed provisioning run must record its marker"
assert_grep 'runpod-root-sandbox-v1' "$w/volume/persistent-runtime/runpod-root-sandbox" \
  "boot did not publish the provider-owned root-sandbox marker"
pass "first boot clones the code root and installs the required toolchain through the pinned installers"

# Bare SSH login shells and interactive shells do not inherit the boot process's
# PATH, so both account startup files must independently recover the durable bin.
profile_probe=$(HOME="$HOMEDIR" PATH=/usr/bin:/bin /bin/bash -c '. "$HOME/.profile"; printf "%s|%s\n" "$(command -v codex)" "${IS_SANDBOX:-}"')
[ "$profile_probe" = "$HOMEDIR/.local/bin/codex|1" ] \
  || fail "the login-shell profile did not restore the durable tool PATH and IS_SANDBOX=1: $profile_probe"
bashrc_probe=$(HOME="$HOMEDIR" PATH=/usr/bin:/bin /bin/bash -c '. "$HOME/.bashrc"; printf "%s|%s\n" "$(command -v claude)" "${IS_SANDBOX:-}"')
[ "$bashrc_probe" = "$HOMEDIR/.local/bin/claude|1" ] \
  || fail "the interactive-shell rc did not restore the durable tool PATH and IS_SANDBOX=1: $bashrc_probe"
assert_contains "$calls" "sandbox=1" \
  "the non-interactive readiness handoff did not inherit IS_SANDBOX=1"
pass "login, interactive, and non-interactive pod processes inherit the durable tool PATH and sandbox marker"

jq -e '
  .hasCompletedOnboarding == true
  and .theme == "dark"
' "$HOMEDIR/.claude.json" >/dev/null \
  || fail "Claude's durable state did not preseed onboarding and theme"
jq -e '
  .skipDangerousModePermissionPrompt == true
  and .attribution.commit == ""
  and .attribution.pr == ""
  and .attribution.sessionUrl == false
' "$HOMEDIR/.claude/settings.json" >/dev/null \
  || fail "Claude's durable settings did not preseed unattended bypass and disabled attribution"
pass "Claude onboarding, bypass confirmation, and git attribution are preseeded on the volume"

# --- the account home is on the volume, so a login is once-per-volume --------
#
# Every worker login, gh credential, and runtime config lands under the account
# home. On a container-local home they die with the pod, which is the whole gap
# this closes: the home moves onto the volume and sshd is told where it is.

assert_present "$HOMEDIR" "the durable account home was not created on the volume"
assert_absent "$w/home/.local/bin/herdr" \
  "durable tools were linked into the container-local home, which dies with the pod"
assert_grep ":$HOMEDIR:" "$w/etc/passwd" \
  "the account passwd entry still points sshd at the container-local home"
assert_no_grep ':/root:' "$w/etc/passwd" "the container-local home survived in the passwd entry"
assert_grep ':/nonexistent:' "$w/etc/passwd" "the rewrite touched an account other than this one"
[ "$(cat "$w/etc/durable-root" 2>/dev/null)" = "$w/volume" ] \
  || fail "the boot did not declare the volume as this host's durable root"
pass "the account home moves onto the volume and the host declares its durable root"

# --- the whole parity toolchain is installed on the volume -------------------

assert_contains "$calls" "bun install -g @oh-my-pi/pi-coding-agent" "omp must be installed through bun"
assert_contains "$calls" "npm install -g @openai/codex" "codex must be installed"
assert_contains "$calls" "npm install -g @colbymchenry/codegraph" "the code-intelligence CLI must be installed"
assert_contains "$calls" "npm install -g gh-axi" "gh-axi must be installed"
assert_contains "$calls" "npm install -g quota-axi" "quota-axi must be installed"
assert_contains "$calls" "claude.ai/install.sh" "the claude harness must come from its vendor installer"
assert_contains "$calls" "no-mistakes" "the validation pipeline must be installed"
assert_contains "$calls" "@puppeteer/browsers" "a headless browser must be installed for browser work"
assert_present "$w/volume/persistent-runtime/bun/bin/omp" "omp must live on the volume"
assert_present "$w/volume/persistent-runtime/npm/bin/codex" "codex must live on the volume"
assert_present "$w/volume/persistent-runtime/npm/bin/codegraph" "the code-intelligence CLI must live on the volume"
assert_present "$HOMEDIR/.local/bin/claude" "the claude harness must install into the durable account home"
assert_present "$HOMEDIR/.local/bin/no-mistakes" "the validation pipeline must install into the durable account home"
assert_present "$HOMEDIR/.local/bin/omp" "later SSH jobs must receive a link to the durable omp"
assert_present "$HOMEDIR/.local/bin/gh" "later SSH jobs must receive a link to the durable gh"
assert_present "$w/fakebin/google-chrome" "the browser must be reachable at its standard system path"
pass "first boot installs the whole parity toolchain onto the volume"

assert_present "$w/volume/persistent-runtime/boot.ready" \
  "the parity toolchain must satisfy the doctor-owned readiness handoff with no extra harness configured"
assert_not_contains "$calls" "npm install -g @example/harness" \
  "no optional extra harness package may be installed unless one is configured"
pass "the parity toolchain alone reaches readiness; an extra harness stays optional"

: > "$w/calls.log"
provision_only "$w" "@example/harness"
assert_contains "$(cat "$w/calls.log")" "npm install -g @example/harness" \
  "changing the configured extra harness must invalidate the durable marker and install it"
assert_present "$w/volume/persistent-runtime/boot.ready" \
  "a configured extra harness must still permit the doctor-owned readiness handoff"

# --- idempotence -------------------------------------------------------------

: > "$w/calls.log"
provision_idempotent "$w" "@example/harness"
second=$(cat "$w/calls.log")
assert_not_contains "$second" "git clone" "a second boot must not re-clone the code root"
assert_not_contains "$second" "npm install -g tasks-axi" "a second boot must not reinstall the toolchain"
pass "provisioning is idempotent across boots on the same volume"

# A completed interactive login is the thing that must survive pod replacement,
# so the case plants one on the volume before the replacement pod boots.
mkdir -p "$HOMEDIR/.claude" "$HOMEDIR/.config/gh"
printf 'subscription-login\n' > "$HOMEDIR/.claude/.credentials.json"
printf 'github.com:\n  oauth_token: login\n' > "$HOMEDIR/.config/gh/hosts.yml"
jq '.operatorState = "keep"' "$HOMEDIR/.claude.json" > "$HOMEDIR/.claude.json.next" \
  && mv "$HOMEDIR/.claude.json.next" "$HOMEDIR/.claude.json"
jq '.operatorSetting = "keep"' "$HOMEDIR/.claude/settings.json" > "$HOMEDIR/.claude/settings.json.next" \
  && mv "$HOMEDIR/.claude/settings.json.next" "$HOMEDIR/.claude/settings.json"
printf 'export OPERATOR_PROFILE=keep\nPATH=/operator-profile\nunset IS_SANDBOX\n' > "$HOMEDIR/.profile"
printf 'case $- in *i*) ;; *) return ;; esac\nexport OPERATOR_BASHRC=keep\nPATH=/operator-bashrc\nunset IS_SANDBOX\n' > "$HOMEDIR/.bashrc"
ln -s .profile "$HOMEDIR/.bash_profile"
printf 'export OPERATOR_BASH_LOGIN=keep\nPATH=/operator-bash-login\nunset IS_SANDBOX\n' > "$HOMEDIR/.bash_login"
rm -f "$w/volume/firstmate/bin/fm-claude-headless-setup.sh"
: > "$w/calls.log"

rm -rf "${w:?}/home"
rm -rf "${w:?}/system-ssh"
mkdir -p "$w/home" "$w/system-ssh"
rm -f "$w/fakebin/jq" "$w/fakebin/curl" "$w/fakebin/unzip" \
  "$w/fakebin/sshd" "$w/fakebin/google-chrome"
printf '%s:x:%s:%s:%s:/root:/bin/bash\n' "$(id -un)" "$(id -u)" "$(id -g)" "$(id -un)" > "$w/etc/passwd"
: > "$w/calls.log"
provision_only "$w" "@example/harness"
replacement=$(cat "$w/calls.log")
assert_contains "$replacement" "apt-get install" "a replacement pod must restore its ephemeral system prerequisites"
assert_not_contains "$replacement" "curl -fsSL" "a replacement pod must not reinstall its durable Node runtime"
assert_not_contains "$replacement" "git clone" "a replacement pod must reuse the durable code root"
assert_not_contains "$replacement" "fm-install-herdr.sh" "a replacement pod must reuse durable pinned tools"
assert_not_contains "$replacement" "npm install -g tasks-axi" "a replacement pod must reuse its durable npm prefix"
assert_not_contains "$replacement" "bun install -g" "a replacement pod must reuse its durable bun harness"
assert_not_contains "$replacement" "@puppeteer/browsers" "a replacement pod must reuse its durable browser"
assert_contains "$replacement" "$HOMEDIR/.local/bin/herdr" "a replacement doctor handoff must see durable tools"
assert_present "$HOMEDIR/.local/bin/herdr" "a replacement pod must recreate its SSH-visible durable-tool links"
assert_present "$HOMEDIR/.local/bin/node" "a replacement pod must recreate its SSH-visible durable Node link"
[ "$(readlink "$HOMEDIR/.local/bin/node")" = "$w/volume/persistent-runtime/node/bin/node" ] \
  || fail "a replacement pod must serve Node from the retained volume"
assert_present "$w/fakebin/google-chrome" "a replacement pod must relink the browser at its standard system path"
assert_grep ":$HOMEDIR:" "$w/etc/passwd" "a replacement pod must point sshd back at the durable account home"
[ "$(cat "$HOMEDIR/.claude/.credentials.json")" = 'subscription-login' ] \
  || fail "a replacement pod lost the harness login that was completed on the volume"
assert_grep 'oauth_token: login' "$HOMEDIR/.config/gh/hosts.yml" \
  "a replacement pod lost the GitHub login that was completed on the volume"
jq -e '.operatorState == "keep" and .hasCompletedOnboarding == true' "$HOMEDIR/.claude.json" >/dev/null \
  || fail "a replacement pod clobbered existing Claude state while reconciling headless defaults"
jq -e '.operatorSetting == "keep" and .attribution.sessionUrl == false' "$HOMEDIR/.claude/settings.json" >/dev/null \
  || fail "a replacement pod clobbered existing Claude settings while enforcing attribution"
profile_probe=$(HOME="$HOMEDIR" PATH=/usr/bin:/bin /bin/bash -c '. "$HOME/.profile"; printf "%s|%s|%s\n" "$(command -v codex)" "${IS_SANDBOX:-}" "${OPERATOR_PROFILE:-}"')
[ "$profile_probe" = "$HOMEDIR/.local/bin/codex|1|keep" ] \
  || fail "retained .profile assignments overrode the managed RunPod environment: $profile_probe"
profile_precedence_probe=$(HOME="$HOMEDIR" PATH=/usr/bin:/bin /bin/bash -c '. "$HOME/.bash_profile"; printf "%s|%s|%s\n" "$(command -v codex)" "${IS_SANDBOX:-}" "${OPERATOR_PROFILE:-}"')
[ "$profile_precedence_probe" = "$HOMEDIR/.local/bin/codex|1|keep" ] \
  || fail "a retained .bash_profile bypassed the managed RunPod environment: $profile_precedence_probe"
[ -L "$HOMEDIR/.bash_profile" ] && [ "$(readlink "$HOMEDIR/.bash_profile")" = .profile ] \
  || fail "replacement boot did not preserve the conventional .bash_profile symlink"
bash_login_probe=$(HOME="$HOMEDIR" PATH=/usr/bin:/bin /bin/bash -c '. "$HOME/.bash_login"; printf "%s|%s|%s\n" "$(command -v claude)" "${IS_SANDBOX:-}" "${OPERATOR_BASH_LOGIN:-}"')
[ "$bash_login_probe" = "$HOMEDIR/.local/bin/claude|1|keep" ] \
  || fail "a retained .bash_login bypassed the managed RunPod environment: $bash_login_probe"
bashrc_probe=$(HOME="$HOMEDIR" PATH=/usr/bin:/bin /bin/bash --noprofile --norc -ic '. "$HOME/.bashrc"; printf "%s|%s|%s\n" "$(command -v claude)" "${IS_SANDBOX:-}" "${OPERATOR_BASHRC:-}"' 2>/dev/null | tail -1)
[ "$bashrc_probe" = "$HOMEDIR/.local/bin/claude|1|keep" ] \
  || fail "retained interactive .bashrc assignments overrode the managed RunPod environment: $bashrc_probe"
noninteractive_bashrc_probe=$(HOME="$HOMEDIR" PATH=/usr/bin:/bin /bin/bash -c '. "$HOME/.bashrc"; printf "%s|%s\n" "${OPERATOR_BASHRC:-}" "${IS_SANDBOX:-}"')
[ "$noninteractive_bashrc_probe" = '|' ] \
  || fail "the retained .bashrc early return no longer protects non-interactive shells: $noninteractive_bashrc_probe"
assert_contains "$(cat "$w/calls.log")" "pull --ff-only --quiet" \
  "a contract-5 replacement did not reconcile the tracked helper from its retained checkout"
assert_present "$w/volume/firstmate/bin/fm-claude-headless-setup.sh" \
  "a contract-5 replacement could not recover the tracked Claude helper"
assert_present "$w/volume/persistent-runtime/boot.ready" "a replacement pod must reach readiness from the retained volume"
pass "replacement pods restore ephemeral prerequisites and reuse the durable toolchain"
pass "a login completed once on the volume survives pod replacement"

wsymlink=$(new_world unsafe-shell-symlink)
provision_only "$wsymlink"
printf 'outside\n' > "$wsymlink/outside-profile"
ln -s "$wsymlink/outside-profile" "$wsymlink/volume/home/.bash_profile"
rm -f "$wsymlink/volume/persistent-runtime/boot.ready"
: > "$wsymlink/volume/persistent-runtime/boot.log"
provision_idempotent "$wsymlink"
assert_absent "$wsymlink/volume/persistent-runtime/boot.ready" \
  "a startup-file symlink escaping the durable home reached readiness"
assert_grep 'startup symlink outside the durable home' "$wsymlink/volume/persistent-runtime/boot.log" \
  "an escaping startup-file symlink did not produce a clear refusal"
[ "$(cat "$wsymlink/outside-profile")" = outside ] \
  || fail "replacement boot overwrote an escaping startup-file symlink target"
pass "replacement boot preserves in-home startup symlinks and refuses escaping targets"

# --- a failed passwd rewrite cannot be masked by the boot process HOME ------

wlogin=$(new_world passwd-rewrite-failure)
mv "$wlogin/etc/passwd" "$wlogin/etc/passwd-disposable"
ln -s "$wlogin/etc/passwd-disposable" "$wlogin/etc/passwd"
(
  world_env "$wlogin"
  timeout 20 bash "$BOOT" >/dev/null 2>&1 &
  bp=$!
  sleep 6
  kill "$bp" 2>/dev/null || true
  wait "$bp" 2>/dev/null || true
)
assert_present "$wlogin/volume/persistent-runtime/toolchain.provisioned" \
  "the failed account rewrite case did not finish toolchain provisioning"
assert_absent "$wlogin/volume/persistent-runtime/boot.ready" \
  "the boot process HOME masked a login account that still lands on disposable storage"
pass "a failed passwd rewrite keeps the pod below readiness"

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
  "unsetting the extra harness must remove its durable executable"
assert_absent "$w2/volume/home/.local/bin/harness" \
  "unsetting the extra harness must remove its SSH-visible executable"
assert_present "$w2/volume/persistent-runtime/boot.ready" \
  "the parity toolchain must keep the volume ready after the extra harness is unset"
pass "the durable marker reconciles extra-harness configuration in both directions"

# --- base-package failures cannot satisfy the contract ----------------------

w4=$(new_world packages)
rm -f "$w4/fakebin/sshd"
out=$(
  world_env "$w4"
  FM_FAKE_APT_FAIL=1 timeout 3 bash "$BOOT" 2>&1 || true
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
  world_env "$w6"
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
  world_env "$w4"
  FM_REMOTE_ORIGIN="" FM_LOCAL_BIN="$w4/volume/home/.local/bin" \
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
  world_env "$w3"
  FM_REMOTE_ORIGIN="" timeout 20 bash "$BOOT" 2>&1 &
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

# --- a parity install that fails leaves the pod unready ----------------------
#
# Parity is the contract, not a best effort: a pod whose browser or harness did
# not install must not publish readiness, because work routed to it would then
# fail in the middle of a task instead of at provisioning time.

w7=$(new_world parityfail)
cat > "$w7/templates/bun" <<'SH'
#!/usr/bin/env bash
printf 'bun %s\n' "$*" >> "$FM_FAKE_CALLS"
[ "${1:-}" != install ] || exit 1
exit 0
SH
chmod +x "$w7/templates/bun"
(
  world_env "$w7"
  timeout 25 bash "$BOOT" >/dev/null 2>&1 &
  bp=$!
  sleep 6
  kill "$bp" 2>/dev/null || true
  wait "$bp" 2>/dev/null || true
)
parityfail=$(cat "$w7/volume/persistent-runtime/boot.log" 2>/dev/null)
assert_contains "$parityfail" "started sshd on port 22" \
  "a failed parity install must still leave the pod reachable for diagnosis"
assert_absent "$w7/volume/persistent-runtime/toolchain.provisioned" \
  "a failed parity install must not record a satisfied contract"
assert_absent "$w7/volume/persistent-runtime/boot.ready" \
  "a failed parity install must never publish the readiness sentinel"
pass "a parity install failure leaves the pod diagnosable and unready"

# --- the browser is launchable by the account that actually runs it ----------
#
# The pod is root by construction, and Chrome refuses to start as root without
# --no-sandbox. The published browser must therefore be launchable as-is by the
# tools that call it, with no flag threaded through their environments.

w8=$(new_world browserroot)
provision_only "$w8"
assert_present "$w8/fakebin/google-chrome" "the browser was not published at its standard system path"
browser_probe="$w8/probe-browser"
mkdir -p "$browser_probe"
cat > "$browser_probe/id" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != -u ] || { printf '0\n'; exit 0; }
exec /usr/bin/id "$@"
SH
chmod +x "$browser_probe/id"
launched=$(PATH="$browser_probe:$w8/basebin" "$w8/fakebin/google-chrome" --headless about:blank 2>&1)
assert_contains "$launched" "--no-sandbox" \
  "a browser launched by the pod's root account was not given the flag it needs to start"
assert_contains "$launched" "about:blank" "the published browser dropped its caller's own arguments"

cat > "$browser_probe/id" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != -u ] || { printf '1000\n'; exit 0; }
exec /usr/bin/id "$@"
SH
unprivileged=$(PATH="$browser_probe:$w8/basebin" "$w8/fakebin/google-chrome" --headless about:blank 2>&1)
assert_not_contains "$unprivileged" "--no-sandbox" \
  "an unprivileged account was given a sandbox-dropping flag it does not need"
pass "the published browser drops its sandbox only for the root account that requires it"

printf 'operator browser\n' > "$w8/fakebin/google-chrome"
: > "$w8/calls.log"
provision_idempotent "$w8"
[ "$(cat "$w8/fakebin/google-chrome")" = 'operator browser' ] \
  || fail "the boot overwrote a browser file it did not write"
pass "a browser file Firstmate did not write is left for the operator"
