#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"
# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

test_omp_daemon_broker_is_never_the_session() {
  local dir fakebin got rc entry runtime launch broker_runtime broker_launch distro shape proc_root
  dir="$TMP_ROOT/omp-daemon-worker"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state" "$dir/scope" "$dir/@oh-my-pi/pi-coding-agent/src"
  mkdir -p "$dir/proc/2147483600" "$dir/proc/2147483647"
  printf 'OMP_DAEMON_RUNTIME_DIR=%s\0' "$dir/scope" > "$dir/proc/2147483600/environ"
  cp "$dir/proc/2147483600/environ" "$dir/proc/2147483647/environ"
  fm_fake_exit0 "$fakebin" omp bun renamed-omp other-bun
  printf '#!/usr/bin/env bun\n' > "$dir/@oh-my-pi/pi-coding-agent/src/cli.ts"
  chmod +x "$dir/@oh-my-pi/pi-coding-agent/src/cli.ts"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  2147483647:comm=) printf '%s\n' "${FM_TEST_OMP_EXE##*/}" ;;
  2147483600:comm=) printf '%s\n' "${FM_TEST_BROKER_EXE##*/}" ;;
  2147483647:args=) printf '%s\n' "$FM_TEST_OMP_LAUNCH  __omp_worker_daemon_broker is the bug to investigate" ;;
  2147483647:ppid=) printf '%s\n' 1 ;;
  2147483600:args=) printf '%s\n' "$FM_TEST_BROKER_LAUNCH __omp_worker_daemon_broker" ;;
  2147483600:ppid=) printf '%s\n' 2147483647 ;;
  2147483599:comm=) printf '%s\n' codex ;;
  2147483599:args=) printf '%s\n' 'codex __omp_worker_daemon_broker is the bug to investigate' ;;
  2147483599:ppid=) printf '%s\n' 1 ;;
  2147483598:comm=) printf '%s\n' bun ;;
  2147483598:args=) printf '%s\n' 'bun /opt/project/cli.ts __omp_worker_daemon_broker' ;;
  2147483598:ppid=) printf '%s\n' 2147483599 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=)
    case "$FM_TEST_OMP_SHAPE" in
      broker|shared) printf '%s\n' 2147483600 ;;
      direct) printf '%s\n' 2147483647 ;;
      codex) printf '%s\n' 2147483598 ;;
    esac
    ;;
esac
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d txt "*)
    case " $* " in
      *" -p 2147483600 "*) printf 'n%s\n' "$FM_TEST_BROKER_EXE" ;;
      *" -p 2147483647 "*) printf 'n%s\n' "$FM_TEST_OMP_EXE" ;;
    esac
    ;;
  *" -p 2147483600 "*|*" -p 2147483647 "*)
    printf 'n%s/broker.pid\n' "$FM_TEST_BROKER_SCOPE" ;;
esac
SH
  chmod +x "$fakebin/lsof"

  for distro in standalone bun-script renamed-standalone; do
    case "$distro" in
      standalone) runtime="$fakebin/omp"; entry="$runtime" ;;
      bun-script) runtime="$fakebin/bun"; entry="$dir/@oh-my-pi/pi-coding-agent/src/cli.ts" ;;
      renamed-standalone) runtime="$fakebin/renamed-omp"; entry="$runtime" ;;
    esac
    printf '18.8.4\n2147483647\n%s\n%s\n' "$runtime" "$entry" > "$dir/state/.omp-primary-extension-loaded"
    printf '2147483647\n' > "$dir/state/.lock"
    launch=$runtime
    [ "$runtime" = "$entry" ] || launch="$runtime $entry"
    printf '{"pid":2147483600}' > "$dir/scope/broker.pid"
    for shape in direct broker shared codex; do
      broker_runtime=$runtime
      broker_launch=$launch
      if [ "$shape" = shared ]; then
        if [ "$distro" = bun-script ]; then
          broker_runtime="$fakebin/other-bun"
          broker_launch="$broker_runtime $entry"
        else
          broker_runtime="$fakebin/omp"
          [ "$runtime" != "$broker_runtime" ] || broker_runtime="$fakebin/renamed-omp"
          broker_launch=$broker_runtime
        fi
      fi
      for proc_root in "$dir/proc" "$dir/no-proc"; do
        got=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_TEST_OMP_EXE="$runtime" \
          FM_OMP_PROCESS_EXPECTED_BUN="$runtime" FM_OMP_PROCESS_EXPECTED_BIN="$entry" \
          FM_TEST_BROKER_EXE="$broker_runtime" FM_TEST_BROKER_LAUNCH="$broker_launch" \
          FM_PROC_ROOT_OVERRIDE="$proc_root" FM_TEST_BROKER_SCOPE="$dir/scope" \
          FM_TEST_OMP_LAUNCH="$launch" FM_TEST_OMP_SHAPE="$shape" \
          lib_eval "$fakebin" '
            rc=0
            fm_harness_ancestry_pid || rc=$?
            printf "ancestry exit: %s\n" "$rc"
            if fm_session_lock_owned_by_self "$FM_STATE_OVERRIDE"; then printf "owns session lock\n"; fi
            for pid in 2147483647 2147483600 2147483599; do
              if fm_harness_pid_alive "$pid"; then printf "live: %s\n" "$pid"; fi
            done
          ')
        case "$shape" in
          direct) rc=$'2147483647\nancestry exit: 0\nowns session lock' ;;
          broker|shared) rc='ancestry exit: 2' ;;
          codex) rc=$'2147483599\nancestry exit: 0' ;;
        esac
        [ "$got" = "$rc"$'\nlive: 2147483647\nlive: 2147483599' ] \
          || fail "$distro $shape: wrong ancestry or holder liveness: $got"
      done
    done
  done
  pass "session-lock: standalone and Bun-script OMP brokers stop ancestry and read stale"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-omp-process-lib.sh" "$dir/bin/fm-omp-process-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

test_e2e_fm_lock_under_omp_daemon_broker() {
  local dir runtime session_pid worker_pid
  dir="$TMP_ROOT/e2e-omp-daemon-broker"
  runtime=$(fm_test_realpath "$(command -v node)") || fail "cannot resolve the fixture's Node executable"
  mkdir -p "$dir/state"
  install_autoarm_scripts "$dir"
  cat > "$dir/worker.cjs" <<'JS'
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");
const lease = fs.openSync(process.env.OMP_DAEMON_RUNTIME_DIR + "/broker.pid", "w");
fs.writeFileSync(lease, JSON.stringify({pid: process.pid}));
const lock = spawnSync(process.env.FM_LOCK, [], {encoding: "utf8"});
fs.writeFileSync(process.env.FM_HOME + "/state/worker.out", lock.stderr);
fs.writeFileSync(process.env.FM_HOME + "/state/worker.rc", String(lock.status));
setInterval(() => {}, 1000);
JS
  cat > "$dir/session.sh" <<'SH'
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
OMP_DAEMON_RUNTIME_DIR="$FM_HOME/state" "$BROKER_RUNTIME" "$FM_HOME/worker.cjs" __omp_worker_daemon_broker &
held=$!
trap 'kill "$held" 2>/dev/null; wait "$held" 2>/dev/null' EXIT
printf '%s\n' "$held" > "$FM_HOME/state/worker-pid"
i=0
while [ "$i" -lt 200 ] && [ ! -s "$FM_HOME/state/worker.rc" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -s "$FM_HOME/state/worker.rc" ] || exit 1
printf '%s\n' "$held" > "$FM_HOME/state/.lock"
"$FM_LOCK" status > "$FM_HOME/state/status.out"
"$FM_LOCK" > "$FM_HOME/state/session.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/session.rc"
SH
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_LOCK="$dir/bin/fm-lock.sh" \
    FM_OMP_PROCESS_EXPECTED_BUN="$runtime" FM_OMP_PROCESS_EXPECTED_BIN="$runtime" \
    BROKER_RUNTIME="$runtime" \
    "$NAMED_CLAUDE" "$dir/session.sh" || fail "the OMP broker fixture never finished"

  expect_code 1 "$(cat "$dir/state/worker.rc")" \
    "fm-lock.sh under an OMP daemon broker must refuse: $(cat "$dir/state/worker.out")"
  grep -q 'OMP daemon broker' "$dir/state/worker.out" \
    || fail "the refusal does not name the OMP daemon broker: $(cat "$dir/state/worker.out")"
  session_pid=$(cat "$dir/state/session-pid")
  worker_pid=$(cat "$dir/state/worker-pid")
  assert_contains "$(cat "$dir/state/status.out")" "lock: stale (pid $worker_pid" \
    "fm-lock status must report a live broker as stale"
  expect_code 0 "$(cat "$dir/state/session.rc")" \
    "the session could not reclaim a lock pinned to a live OMP daemon broker: $(cat "$dir/state/session.out")"
  [ "$(cat "$dir/state/.lock")" = "$session_pid" ] \
    || fail "the reclaimed lock names $(cat "$dir/state/.lock"), expected session $session_pid (broker $worker_pid)"
  pass "session-lock e2e: fm-lock.sh names the OMP daemon broker and reclaims a broker-pinned lock"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_omp_daemon_broker_is_never_the_session
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_e2e_fm_lock_under_omp_daemon_broker
