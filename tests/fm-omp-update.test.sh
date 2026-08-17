#!/usr/bin/env bash
# Behavior tests for the machine-wide omp self-updater.
#
# The executable boundary proves that installs require a stopped fleet,
# --check is detect-only, --force is rejected, and daemon-management commands
# are never invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OMP_UPDATE="$ROOT/bin/fm-omp-update.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-omp-update-tests)

make_world() {  # <name>
  local dir=$TMP_ROOT/$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/home/state" "$dir/home/data"
  printf '%s\n' 'omp/17.3.4' > "$dir/version"
  : > "$dir/omp.log"
  : > "$dir/daemon.log"
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${OMP_TEST_LOG:?}"
case "${1:-}" in
  --version)
    cat "${OMP_TEST_VERSION:?}"
    ;;
  update)
    if [ "${2:-}" = --check ]; then
      printf '%s\n' 'Current version: 17.3.4'
      printf '%s\n' 'New version available: 17.3.5'
    else
      printf '%s\n' 'Updated to 17.3.5'
      printf '%s\n' 'omp/17.3.5' > "${OMP_TEST_VERSION:?}"
    fi
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/omp"
  printf '%s\n' "$dir"
}

install_daemon_traps() {  # <fakebin>
  local fakebin=$1 command
  for command in no-mistakes systemctl launchctl pkill killall; do
    cat > "$fakebin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${OMP_TEST_DAEMON_LOG:?}"
exit 97
SH
    chmod +x "$fakebin/$command"
  done
}

install_alive_tmux() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' win ;;
  display-message) printf '%s\n' claude ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/tmux"
}

run_update() {  # <world> [args...]
  local world=$1
  shift
  PATH="$world/fakebin:$BASE_PATH" \
    FM_HOME="$world/home" \
    OMP_TEST_LOG="$world/omp.log" \
    OMP_TEST_VERSION="$world/version" \
    OMP_TEST_DAEMON_LOG="$world/daemon.log" \
    "$OMP_UPDATE" "$@"
}

test_refuses_a_live_fleet() {
  local world secondmate_world out
  world=$(make_world live)
  install_alive_tmux "$world/fakebin"
  fm_write_meta "$world/home/state/live.meta" \
    'window=main:win' \
    'harness=claude'

  if out=$(run_update "$world" 2>&1); then
    fail "omp update succeeded while a recorded worker was alive"
  fi
  assert_contains "$out" 'omp: refused: a worker is still running (task live)' \
    "live worker refusal is explicit"
  assert_not_contains "$(cat "$world/omp.log")" 'update' \
    "live fleet never reaches omp update"
  [ "$(cat "$world/version")" = 'omp/17.3.4' ] \
    || fail "live-fleet refusal changed the omp version"

  secondmate_world=$(make_world secondmate-live)
  install_alive_tmux "$secondmate_world/fakebin"
  mkdir -p "$secondmate_world/secondmate/state"
  fm_write_meta "$secondmate_world/home/state/sm1.meta" \
    'window=main:win' \
    'harness=claude' \
    'kind=secondmate' \
    "home=$secondmate_world/secondmate"
  if out=$(run_update "$secondmate_world" 2>&1); then
    fail "omp update succeeded while a recorded secondmate was alive"
  fi
  assert_contains "$out" 'omp: refused: a worker is still running (second mate sm1)' \
    "live secondmate refusal uses the persistent-worker label"
  assert_not_contains "$(cat "$secondmate_world/omp.log")" 'update' \
    "live secondmate never reaches omp update"
  pass "omp update refuses a live fleet"
}

test_check_is_detect_only() {
  local world out log
  world=$(make_world check)
  fm_write_meta "$world/home/state/live.meta" \
    'window=main:win' \
    'harness=claude'

  out=$(run_update "$world" --check)
  log=$(cat "$world/omp.log")
  assert_contains "$out" 'Current version: 17.3.4' \
    "check reports the current version"
  assert_contains "$out" 'New version available: 17.3.5' \
    "check reports the available version"
  assert_contains "$log" 'update --check' \
    "check uses omp's detect-only mode"
  assert_not_contains "$log" 'update --force' \
    "check never forces"
  [ "$(cat "$world/version")" = 'omp/17.3.4' ] \
    || fail "detect-only check changed the omp version"
  pass "omp update --check reports availability without changing anything"
}

test_never_forces_or_touches_the_daemon() {
  local world log out
  world=$(make_world invariants)
  install_daemon_traps "$world/fakebin"

  out=$(run_update "$world")
  log=$(cat "$world/omp.log")
  assert_contains "$out" 'omp: after: omp/17.3.5' \
    "empty fleet permits the supported update path"
  assert_contains "$log" 'update' \
    "normal mode calls omp update"
  assert_not_contains "$log" 'update --force' \
    "normal mode never adds a force flag"
  [ ! -s "$world/daemon.log" ] \
    || fail "omp updater invoked a daemon-management command: $(cat "$world/daemon.log")"

  : > "$world/omp.log"
  if run_update "$world" --force >/dev/null 2>&1; then
    fail "omp updater accepted --force"
  fi
  [ ! -s "$world/omp.log" ] \
    || fail "rejected --force still invoked omp: $(cat "$world/omp.log")"
  [ ! -s "$world/daemon.log" ] \
    || fail "rejected --force touched the daemon"
  pass "omp updater never forces and never manages the shared daemon"
}

test_refuses_a_live_fleet
test_check_is_detect_only
test_never_forces_or_touches_the_daemon

echo "# all fm-omp-update tests passed"
