#!/usr/bin/env bash
# tests/fm-remote-herdr-launch.test.sh - the macOS launch agent's herdr launcher
# must start the server as its own session leader and keep launchd supervision
# intact.
#
# bin/fm-remote-herdr-launch.pl is the job's top process under launchd. Herdr
# reports detached_server_daemon only when the server is its own session
# leader, so the launcher forks and calls setsid() in the child before it execs
# herdr. These tests drive the real launcher with a stub herdr that records its
# pid, session id, and arguments. They prove the session-leader fact, signal
# forwarding on stop, and the exit contract that KeepAlive depends on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found (the launcher is a perl script)"; exit 0; }
command -v ps >/dev/null 2>&1 || { echo "skip: ps not found (the test reads the session id with ps)"; exit 0; }

LAUNCHER="$ROOT/bin/fm-remote-herdr-launch.pl"
[ -f "$LAUNCHER" ] || fail "the herdr launcher is missing: $LAUNCHER"

TMP_ROOT=$(fm_test_tmproot fm-remote-herdr-launch)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

STUB="$TMP_ROOT/herdr"
RECORD="$TMP_ROOT/server.record"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
# Records "<pid> <session id> <args>", then exits with FM_STUB_EXIT after
# FM_STUB_SLEEP seconds when FM_STUB_EXIT is set. Otherwise it runs until
# signaled, replacing itself with sleep so no extra process is left behind.
set -u
printf '%s %s %s\n' "$$" "$(ps -o sid= -p $$ | tr -d ' ')" "$*" > "$FM_STUB_RECORD"
if [ -n "${FM_STUB_EXIT:-}" ]; then
  sleep "${FM_STUB_SLEEP:-0}"
  exit "$FM_STUB_EXIT"
fi
exec sleep 600
SH
chmod +x "$STUB"

LAUNCHER_PID=""
SERVER_PID=""
SERVER_SID=""
SERVER_ARGS=""

cleanup() {
  [ -z "$LAUNCHER_PID" ] || kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
}
trap cleanup EXIT

wait_record() {
  local _
  for _ in $(seq 1 50); do
    [ -s "$RECORD" ] && return 0
    sleep 0.1
  done
  fail "the launcher never started the herdr stub"
}

read_record() {
  wait_record
  read -r SERVER_PID SERVER_SID SERVER_ARGS < "$RECORD"
}

# --- the server is its own session leader -----------------------------------

rm -f "$RECORD"
FM_STUB_RECORD="$RECORD" perl "$LAUNCHER" "$STUB" server --session fm-remote &
LAUNCHER_PID=$!
read_record
[ "$SERVER_ARGS" = "server --session fm-remote" ] \
  || fail "the launcher passed the wrong herdr arguments: $SERVER_ARGS"
[ "$SERVER_SID" = "$SERVER_PID" ] \
  || fail "the herdr server runs in session $SERVER_SID, not its own session (pid $SERVER_PID)"
kill -TERM "$LAUNCHER_PID" 2>/dev/null
wait "$LAUNCHER_PID" 2>/dev/null
pass "the launcher starts herdr as its own session leader with the fm-remote arguments"
LAUNCHER_PID=""

# --- stopping the job stops the server, with nothing left behind -------------

rm -f "$RECORD"
FM_STUB_RECORD="$RECORD" perl "$LAUNCHER" "$STUB" server --session fm-remote &
LAUNCHER_PID=$!
read_record
kill -TERM "$LAUNCHER_PID"
wait "$LAUNCHER_PID" 2>/dev/null
LAUNCHER_RC=$?
kill -0 "$SERVER_PID" 2>/dev/null && fail "the herdr server outlived its launch agent job (pid $SERVER_PID)"
[ "$LAUNCHER_RC" -ne 0 ] || fail "the launcher exited 0 after its server was stopped, so KeepAlive would not restart it"
LAUNCHER_PID=""
pass "stopping the job stops the server and leaves no orphan"

# --- a server that exits makes the supervisor exit non-zero, without exiting early

rm -f "$RECORD"
FM_STUB_EXIT=3 FM_STUB_SLEEP=1 FM_STUB_RECORD="$RECORD" perl "$LAUNCHER" "$STUB" server --session fm-remote &
LAUNCHER_PID=$!
read_record
sleep 0.3
state=$(ps -o stat= -p "$LAUNCHER_PID" 2>/dev/null | tr -d ' ')
case "$state" in
  ''|Z*) fail "the launcher exited before its server did (state: ${state:-gone})" ;;
esac
wait "$LAUNCHER_PID"
LAUNCHER_RC=$?
LAUNCHER_PID=""
[ "$LAUNCHER_RC" -eq 3 ] || fail "the launcher exited $LAUNCHER_RC, not the server's exit code 3"
pass "the launcher waits for the server and then exits with the server's failure code"

# --- a clean server exit still makes the supervisor fail, so KeepAlive restarts it

rm -f "$RECORD"
FM_STUB_EXIT=0 FM_STUB_SLEEP=0 FM_STUB_RECORD="$RECORD" perl "$LAUNCHER" "$STUB" server --session fm-remote &
LAUNCHER_PID=$!
wait "$LAUNCHER_PID"
LAUNCHER_RC=$?
LAUNCHER_PID=""
[ "$LAUNCHER_RC" -ne 0 ] || fail "a server that exited 0 made the launcher exit 0, so KeepAlive would not restart the job"
pass "a server that exits cleanly still makes the launcher exit non-zero"
