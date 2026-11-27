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
# OMP's daemon workers are launched through the same `omp` executable, so the
# fixture needs that name to reproduce a worker's argv[0].
ln -s /bin/bash "$FAKEBIN/omp"
NAMED_OMP="$FAKEBIN/omp"

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

# Evaluate one library expression as an OMP session would. The fake table makes
# 2147483647 the launch-bound standalone OMP session, whose identity needs a real
# executable path plus the PID executable, and 2147483600 OMP's daemon broker.
# With shape=direct nothing sits between the tool shell and the session; with
# shape=broker the tool shell runs under the shared broker.
omp_lib_eval() {  # <fakebin> <shape> <expression>
  local fakebin=$1 shape=$2 expr=$3
  FM_TEST_OMP_SHAPE="$shape" FM_TEST_OMP_EXE="$fakebin/omp" \
    FM_OMP_PROCESS_EXPECTED_BUN="$fakebin/omp" \
    FM_OMP_PROCESS_EXPECTED_BIN="$fakebin/omp" \
    lib_eval "$fakebin" "$expr"
}

# OMP's daemon broker (`omp __omp_worker_daemon_broker`) hosts every bash call
# made with `name`, carries the bare name `omp`, and is shared by every OMP in
# one project directory, so it outlives sessions and its parent is whichever OMP
# started it. It is never the session: the walk must stop at it instead of
# climbing into an unrelated OMP, and a lock naming it must read stale.
test_omp_daemon_worker_is_never_the_session() {
  local dir fakebin got args
  dir="$TMP_ROOT/omp-daemon-worker"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/omp"
  chmod +x "$fakebin/omp"
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
case "$pid:$field:${FM_TEST_OMP_SHAPE:-broker}" in
  2147483647:comm=:*) printf '%s\n' omp ;;
  2147483647:args=:*) printf '%s\n' 'omp --resume 01a0d36d' ;;
  2147483647:ppid=:*) printf '%s\n' 1 ;;
  2147483600:comm=:*) printf '%s\n' /opt/homebrew/Cellar/omp/18.8.4/bin/omp ;;
  2147483600:args=:*) printf '%s\n' '/opt/homebrew/Cellar/omp/18.8.4/bin/omp __omp_worker_daemon_broker' ;;
  2147483600:ppid=:*) printf '%s\n' 2147483647 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=:broker) printf '%s\n' 2147483600 ;;
  *:ppid=:direct) printf '%s\n' 2147483647 ;;
esac
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'n%s\n' "${FM_TEST_OMP_EXE:-}"
SH
  chmod +x "$fakebin/lsof"

  # Only an `__omp_worker_*` argument in subcommand position makes a worker; an
  # ordinary OMP session, and a prompt that merely mentions the token, do not.
  for args in \
    '/opt/homebrew/Cellar/omp/18.8.4/bin/omp __omp_worker_daemon_broker' \
    '/opt/homebrew/Cellar/omp/18.8.4/bin/omp __omp_worker_lsp_mux --stdio' \
    'omp __omp_worker_text_predict'; do
    lib_eval "$fakebin" "fm_omp_daemon_worker '$args'" \
      || fail "an OMP daemon worker argv was not recognized: $args"
  done
  for args in \
    '/opt/homebrew/Cellar/omp/18.8.4/bin/omp' \
    '/opt/homebrew/Cellar/omp/18.8.4/bin/omp --resume 01a0d36d' \
    'omp --model x __omp_worker_daemon_broker'; do
    if lib_eval "$fakebin" "fm_omp_daemon_worker '$args'"; then
      fail "a non-worker OMP argv was treated as a daemon worker: $args"
    fi
  done

  # Non-vacuity: an ordinary tool call straight under the OMP session resolves it,
  # and nothing claims it runs under a worker.
  got=$(omp_lib_eval "$fakebin" direct 'fm_harness_ancestry_pid') \
    || fail "an OMP session directly above the tool shell was not found"
  [ "$got" = 2147483647 ] || fail "direct ancestry resolved '$got', expected the OMP session pid 2147483647"
  if omp_lib_eval "$fakebin" direct 'fm_harness_ancestry_under_omp_worker'; then
    fail "a direct tool call was reported as running under an OMP daemon worker"
  fi
  printf '2147483647\n' > "$dir/state/.lock"
  omp_lib_eval "$fakebin" direct "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the OMP session did not recognize its own lock"

  # Under the broker the walk must stop with no verdict, not climb to the OMP
  # session above it: that OMP is merely whichever one started the shared worker.
  if got=$(omp_lib_eval "$fakebin" broker 'fm_harness_ancestry_pid'); then
    fail "a broker-hosted command resolved harness pid '$got'; the walk must stop at the OMP daemon worker"
  fi
  omp_lib_eval "$fakebin" broker 'fm_harness_ancestry_under_omp_worker' \
    || fail "a broker-hosted command was not reported as running under an OMP daemon worker"

  if omp_lib_eval "$fakebin" broker 'fm_harness_pid_alive 2147483600'; then
    fail "a live OMP daemon broker was recognized as a harness"
  fi
  omp_lib_eval "$fakebin" broker 'fm_harness_pid_alive 2147483647' \
    || fail "a live OMP session was not recognized as a harness"
  printf '2147483600\n' > "$dir/state/.lock"
  if omp_lib_eval "$fakebin" broker "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock recorded with the OMP daemon broker pid was claimed as this session's own"
  fi
  pass "session-lock: an OMP daemon worker is never the session, and a lock pinned to one reads stale"
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

# The same shape through the real bin/fm-lock.sh in a real process tree. The fake
# worker is invoked exactly as OMP starts one - `omp __omp_worker_daemon_broker` -
# by running a script of that name through an executable named `omp`. Under it
# acquisition must fail and name the cause instead of recording the worker; the
# session acquiring directly must then reclaim a lock that a live worker pid
# pinned. The session is a harness-named process, so the walk would otherwise
# climb from the worker into it and record the wrong pid.
test_e2e_fm_lock_under_omp_daemon_worker() {
  local dir session_pid worker_pid i
  dir="$TMP_ROOT/e2e-omp-daemon-worker"
  mkdir -p "$dir/state" "$dir/worker"
  install_autoarm_scripts "$dir"
  cat > "$dir/worker/__omp_worker_daemon_broker" <<'SH'
case "$WORKER_MODE" in
  lock)
    "$FM_LOCK" > "$FM_HOME/state/worker.out" 2>&1
    printf '%s\n' "$?" > "$FM_HOME/state/worker.rc"
    ;;
  hold) sleep 30 ;;
esac
SH
  cat > "$dir/session.sh" <<'SH'
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
cd "$FM_HOME/worker" || exit 1
WORKER_MODE=lock "$OMP" __omp_worker_daemon_broker
WORKER_MODE=hold "$OMP" __omp_worker_daemon_broker &
held=$!
printf '%s\n' "$held" > "$FM_HOME/state/worker-pid"
printf '%s\n' "$held" > "$FM_HOME/state/.lock"
"$FM_LOCK" > "$FM_HOME/state/session.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/session.rc"
kill "$held" 2>/dev/null
SH
  FM_HOME="$dir" FM_LOCK="$dir/bin/fm-lock.sh" OMP="$NAMED_OMP" \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/session.sh"
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/session.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/session.rc" ] || fail "the OMP broker fixture never finished"

  expect_code 1 "$(tr -d '[:space:]' < "$dir/state/worker.rc")" \
    "fm-lock.sh under an OMP daemon worker must refuse: $(cat "$dir/state/worker.out")"
  grep -q 'OMP daemon worker' "$dir/state/worker.out" \
    || fail "the refusal does not name the OMP daemon worker: $(cat "$dir/state/worker.out")"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  worker_pid=$(tr -d '[:space:]' < "$dir/state/worker-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/session.rc")" \
    "the session could not reclaim a lock pinned to a live OMP daemon worker: $(cat "$dir/state/session.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$session_pid" ] \
    || fail "the reclaimed lock names $(cat "$dir/state/.lock"), expected the OMP session $session_pid (worker $worker_pid)"
  pass "session-lock e2e: fm-lock.sh refuses under an OMP daemon worker and the session reclaims a worker-pinned lock"
}

test_version_named_session_is_identified_on_both_platforms
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_omp_daemon_worker_is_never_the_session
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_e2e_fm_lock_under_omp_daemon_worker
