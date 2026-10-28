#!/usr/bin/env bash
# Regression: a Hermes gateway started for validation must not rewrite the real
# user systemd units. `bin/fm-hermes-sandbox.sh` confines HOME, so `Path.home()`
# (which is what Hermes uses to find the unit) stays inside the sandbox.
#
# The stub repeats the installed Hermes rewrite: on `gateway run` it writes
# `$HOME/.config/systemd/user/hermes-gateway.service` carrying `HERMES_HOME`
# and the working directory. Case 1 shows that write reaching the fake real
# home without the guard; case 2 proves the guard moves it into the sandbox.
# Case 8 probes installed Hermes with a stale sandbox unit when available,
# checking confinement without requiring Hermes to rewrite the fixture.
# Every case leaves the actual user unit directory byte-identical, and
# case 9 records that before-and-after checksum as its evidence.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-hermes-sandbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-sandbox)
FAKE_HOME="$TMP_ROOT/realhome"
UNIT_DIR="$FAKE_HOME/.config/systemd/user"
UNIT="$UNIT_DIR/hermes-gateway.service"
STUB="$TMP_ROOT/stub/hermes"

hash_dir() {  # <dir> -> per-file digest lines
  local dir=$1 file
  [ -d "$dir" ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    while IFS= read -r -d '' file; do sha256sum "$file"; done \
      < <(find "$dir" -type f -print0) | LC_ALL=C sort
  elif command -v shasum >/dev/null 2>&1; then
    while IFS= read -r -d '' file; do shasum -a 256 "$file"; done \
      < <(find "$dir" -type f -print0) | LC_ALL=C sort
  fi
}

REAL_UNITS="$HOME/.config/systemd/user"
REAL_UNITS_BEFORE=$(hash_dir "$REAL_UNITS")
if [ -n "$REAL_UNITS_BEFORE" ]; then
  printf 'info - real user unit checksums before the run:\n%s\n' "$REAL_UNITS_BEFORE"
else
  echo "info - no user unit directory at $REAL_UNITS (or no sha256 tool); the live checksum comparison is empty"
fi

mkdir -p "$UNIT_DIR" "$(dirname "$STUB")"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
# A faithful stand-in for the installed Hermes unit refresh: `gateway run`
# rewrites the user unit under Path.home() with the current HERMES_HOME and cwd.
[ "${1:-}" = gateway ] && [ "${2:-}" = run ] || {
  printf 'stub hermes: unexpected arguments: %s\n' "$*" >&2
  exit 1
}
unit="$HOME/.config/systemd/user/hermes-gateway.service"
mkdir -p "$(dirname "$unit")" || exit 1
printf 'Environment="HERMES_HOME=%s"\nWorkingDirectory=%s\n' "$HERMES_HOME" "$PWD" > "$unit"
SH
chmod +x "$STUB"

write_unit() {  # <hermes-home>
  printf 'Environment="HERMES_HOME=%s"\nWorkingDirectory=%s\n' "$1" "$FAKE_HOME" > "$UNIT"
}

reset_unit() {
  write_unit "$FAKE_HOME/.hermes"
  cp "$UNIT" "$TMP_ROOT/original.service"
}

# 1. The hazard the guard exists for: the real HOME plus a throwaway HERMES_HOME
#    rewrites the real user unit. This case fails if the stub stops modelling it.
reset_unit
HOME="$FAKE_HOME" HERMES_HOME="$TMP_ROOT/throwaway" "$STUB" gateway run ||
  fail "the gateway stub could not run"
grep -Fq "HERMES_HOME=$TMP_ROOT/throwaway" "$UNIT" ||
  fail "the unguarded gateway stub did not reproduce the real-unit rewrite"
pass "unguarded gateway start rewrites the HOME unit (the hazard is reproduced)"

# 2. The guard keeps that same rewrite inside the sandbox.
reset_unit
SANDBOX="$TMP_ROOT/sandbox"
FM_HERMES_SANDBOX_WATCH_HOMES="$FAKE_HOME" \
  HOME="$FAKE_HOME" HERMES_HOME="$TMP_ROOT/throwaway" \
  "$GUARD" --root "$SANDBOX" -- "$STUB" gateway run >/dev/null 2>&1 ||
  fail "the guard did not run the gateway stub successfully"
cmp -s "$TMP_ROOT/original.service" "$UNIT" ||
  fail "the guarded gateway start rewrote the real-home unit"
SANDBOX_UNIT="$SANDBOX/home/.config/systemd/user/hermes-gateway.service"
[ -f "$SANDBOX_UNIT" ] || fail "the guarded gateway start wrote no sandboxed unit"
grep -Fq "HERMES_HOME=$SANDBOX/hermes" "$SANDBOX_UNIT" ||
  fail "the sandboxed unit does not carry the sandboxed HERMES_HOME"
pass "the guard confines the unit rewrite to the sandbox"

# 3. Inherited home variables are replaced, never merged.
OVERRIDE="$TMP_ROOT/override"
env_out=$(
  HOME="$FAKE_HOME" HERMES_HOME="$FAKE_HOME/.hermes" XDG_CONFIG_HOME="$FAKE_HOME/.config" \
    "$GUARD" --root "$OVERRIDE" -- env 2>/dev/null
) || fail "the guard refused a valid sandbox root"
OVERRIDE_REAL=$(cd "$OVERRIDE" && pwd -P)
for pair in "HOME=$OVERRIDE_REAL/home" "HERMES_HOME=$OVERRIDE_REAL/hermes" \
  "XDG_CONFIG_HOME=$OVERRIDE_REAL/config" "XDG_DATA_HOME=$OVERRIDE_REAL/data" \
  "XDG_CACHE_HOME=$OVERRIDE_REAL/cache" "XDG_STATE_HOME=$OVERRIDE_REAL/state" \
  "DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null"; do
  printf '%s\n' "$env_out" | grep -Fxq "$pair" ||
    fail "the guard did not set $pair"
done
if printf '%s\n' "$env_out" | grep -q '^XDG_RUNTIME_DIR='; then
  fail "the guard inherited the user runtime directory"
fi
pass "the guard replaces every inherited home variable and disconnects the user manager"

# 4. Roots that could still reach the real units are refused before anything
#    runs.
for root in "$FAKE_HOME" "$FAKE_HOME/.config/systemd/user" "$TMP_ROOT"; do
  marker="$TMP_ROOT/ran.$(printf '%s' "$root" | tr '/' '_')"
  rc=0
  HOME="$FAKE_HOME" "$GUARD" --root "$root" -- touch "$marker" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 78 ] || fail "the guard did not refuse the overlapping root $root (exit $rc)"
  [ ! -e "$marker" ] || fail "the guard ran the command for the refused root $root"
done
pass "the guard refuses roots that overlap the real home or its unit directory"

# 5. The command's exit status survives the guard.
rc=0
"$GUARD" -- bash -c 'exit 7' >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 7 ] || fail "the guard lost the command exit status (got $rc)"
pass "the guard propagates the command exit status"

# 6. The tripwire fails the run when a watched real unit directory changes.
cat > "$TMP_ROOT/append-unit.sh" <<'SH'
#!/usr/bin/env bash
printf 'changed\n' >> "$1"
SH
chmod +x "$TMP_ROOT/append-unit.sh"
rc=0
FM_HERMES_SANDBOX_WATCH_HOMES="$FAKE_HOME" \
  "$GUARD" --root "$TMP_ROOT/tripwire" -- \
  "$TMP_ROOT/append-unit.sh" "$UNIT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 70 ] || fail "the tripwire did not report a changed real unit (exit $rc)"
reset_unit
pass "the guard tripwire fails when a watched real unit changes"

# 7. A default root is cleaned up; explicit roots are retained.
tmp_home=$("$GUARD" -- env 2>/dev/null | sed -n 's/^HOME=//p') ||
  fail "the guard failed a default-root run"
[ -n "$tmp_home" ] || fail "the guard printed no sandbox HOME"
[ ! -d "$tmp_home" ] || fail "the guard left its default sandbox root behind"
[ -d "$SANDBOX" ] || fail "the guard removed an explicit sandbox root"
for option in --keep "--root=$TMP_ROOT/alias"; do
  rc=0
  "$GUARD" "$option" -- touch "$TMP_ROOT/unsupported-ran" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 64 ] || fail "the guard accepted unsupported option $option"
  [ ! -e "$TMP_ROOT/unsupported-ran" ] || fail "an unsupported option ran the command"
done
pass "the guard cleans default roots and supports only explicit --root retention"

for destination in home hermes config data cache state home/.config home/.config/systemd home/.config/systemd/user; do
  root="$TMP_ROOT/symlink-${destination//\//-}"
  mkdir -p "$root/$(dirname "$destination")"
  ln -s "$FAKE_HOME" "$root/$destination"
  rc=0
  HOME="$FAKE_HOME" "$GUARD" --root "$root" -- touch "$TMP_ROOT/escaped" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 78 ] || fail "the guard accepted an escaping $destination symlink"
  [ ! -e "$TMP_ROOT/escaped" ] || fail "the guard executed through an escaping $destination symlink"
  cmp -s "$TMP_ROOT/original.service" "$UNIT" || fail "symlink refusal changed the fake-real unit"
done
pass "the guard refuses escaping symlinks at every sandbox destination"

for entry in hermes-gateway.service hermes-gateway-fmcomms.service nested/other.service linked/other.service; do
  root="$TMP_ROOT/unit-link-${entry//\//-}"
  sandbox_units="$root/home/.config/systemd/user"
  mkdir -p "$sandbox_units"
  if [ "$entry" = linked/other.service ]; then
    mkdir -p "$root/unit-targets"
    ln -s "$root/unit-targets" "$sandbox_units/linked"
  else
    mkdir -p "$sandbox_units/$(dirname "$entry")"
  fi
  ln -s "$UNIT" "$sandbox_units/$entry"
  marker="$root/command-ran"
  rc=0
  HOME="$FAKE_HOME" "$GUARD" --root "$root" -- \
    bash -c 'touch "$1"; exec "$2" gateway run' _ "$marker" "$STUB" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 78 ] || fail "the guard accepted an escaping unit-tree entry $entry (exit $rc)"
  [ ! -e "$marker" ] || fail "the guard ran the command with an escaping unit-tree entry $entry"
  cmp -s "$TMP_ROOT/original.service" "$UNIT" || fail "unit-tree refusal changed the fake-real unit"
done
pass "the guard refuses escaping default, profile, nested, and directory-linked unit entries"

root="$TMP_ROOT/confined-unit-link"
sandbox_units="$root/home/.config/systemd/user"
mkdir -p "$sandbox_units" "$root/unit-targets"
printf 'stale\n' > "$root/unit-targets/gateway.service"
ln -s "$root/unit-targets/gateway.service" "$sandbox_units/hermes-gateway.service"
ln -s "$sandbox_units" "$sandbox_units/loop"
HOME="$FAKE_HOME" "$GUARD" --root "$root" -- "$STUB" gateway run >/dev/null 2>&1 ||
  fail "the guard refused confined unit-tree symlinks"
grep -Fq "HERMES_HOME=$root/hermes" "$root/unit-targets/gateway.service" ||
  fail "the confined unit symlink did not receive the sandbox rewrite"
cmp -s "$TMP_ROOT/original.service" "$UNIT" || fail "the confined unit rewrite changed the fake-real unit"
pass "the guard accepts confined unit symlinks and terminates directory cycles"

root="$TMP_ROOT/internal-link"
mkdir -p "$root/physical-home"
ln -s "$root/physical-home" "$root/home"
HOME="$FAKE_HOME" "$GUARD" --root "$root" -- "$STUB" gateway run >/dev/null 2>&1 ||
  fail "the guard refused a confined physical HOME"
[ -f "$root/physical-home/.config/systemd/user/hermes-gateway.service" ] ||
  fail "the confined physical HOME did not receive the unit"
pass "the guard supports physical destinations inside the sandbox"

if command -v systemctl >/dev/null 2>&1; then
  rc=0
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}" \
    "$GUARD" --root "$TMP_ROOT/manager" -- systemctl --user show-environment >"$TMP_ROOT/manager.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the sandbox reached a user service manager"
  pass "real systemctl cannot reach the user manager through the sandbox"
fi

# 8. The installed Hermes resolves its unit inside the sandbox when it is
#    available; without it, an explicit skip names what is missing.
HERMES_RUNTIME=${FM_TEST_HERMES_PYTHON:-$HOME/.hermes/hermes-agent/venv/bin/python}
REAL_UNITS_BEFORE_REAL=$(hash_dir "$REAL_UNITS")
if [ -x "$HERMES_RUNTIME" ] && "$HERMES_RUNTIME" -c 'import hermes_cli.gateway' >/dev/null 2>&1; then
  reset_unit
  python_out=$(HOME="$FAKE_HOME" "$GUARD" --root "$TMP_ROOT/real-hermes" -- "$HERMES_RUNTIME" -c '
import pathlib
from hermes_cli.gateway import get_systemd_unit_path, refresh_systemd_unit_if_needed
unit = get_systemd_unit_path()
unit.parent.mkdir(parents=True, exist_ok=True)
unit.write_text("[Service]\nEnvironment=HERMES_HOME=/obsolete-validation-home\nExecStart=/obsolete-hermes gateway run\n")
print(pathlib.Path.home(), flush=True)
print(unit, flush=True)
print(refresh_systemd_unit_if_needed())
' 2>/dev/null) || fail "the guard could not run the installed Hermes probe"
  sandbox_real=$(cd "$TMP_ROOT/real-hermes" && pwd -P)
  real_path=$(printf '%s\n' "$python_out" | sed -n '1p')
  real_unit=$(printf '%s\n' "$python_out" | sed -n '2p')
  case "$real_path/" in
    "$sandbox_real"/*) ;;
    *) fail "installed Hermes Path.home() escaped the sandbox: $real_path" ;;
  esac
  case "$real_unit/" in
    "$sandbox_real"/*) ;;
    *) fail "installed Hermes resolved its unit outside the sandbox: $real_unit" ;;
  esac
  [ -f "$real_unit" ] || fail "the installed Hermes stale-unit fixture disappeared"
  cmp -s "$TMP_ROOT/original.service" "$UNIT" ||
    fail "the installed Hermes probe changed the fake-real unit"
  [ "$REAL_UNITS_BEFORE_REAL" = "$(hash_dir "$REAL_UNITS")" ] ||
    fail "the installed Hermes probe changed the real user unit directory"
  pass "installed Hermes stale-unit probe leaves real and fake-real units unchanged"
else
  echo "info - no importable Hermes runtime at $HERMES_RUNTIME; the installed-Hermes case was not run"
fi

# 9. Whole-suite evidence: the real user unit directory is byte-identical.
if [ -n "$REAL_UNITS_BEFORE" ]; then
  REAL_UNITS_AFTER=$(hash_dir "$REAL_UNITS")
  [ "$REAL_UNITS_BEFORE" = "$REAL_UNITS_AFTER" ] ||
    fail "a test case changed the real user unit directory $REAL_UNITS"
  printf 'info - real user unit checksums after the run:\n%s\n' "$REAL_UNITS_AFTER"
  pass "real user unit directory is unchanged before and after the run"
fi

pass "fm-hermes-sandbox.test.sh"
