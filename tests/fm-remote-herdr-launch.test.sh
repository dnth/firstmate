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
# forwarding on stop, the exit contract that KeepAlive depends on, and adoption
# of a server left behind by a SIGKILLed launcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found (the launcher is a perl script)"; exit 0; }
command -v ps >/dev/null 2>&1 || { echo "skip: ps not found (the launcher and the test read the process table)"; exit 0; }

read_sid() { # <pid>
  python3 -c 'import os, sys; print(os.getsid(int(sys.argv[1])))' "$1" 2>/dev/null \
    || ps -o sid= -p "$1" 2>/dev/null | tr -d ' '
}
case "$(read_sid $$)" in
  ''|*[!0-9]*) echo "skip: no portable session id reader (needs python3 or procps ps -o sid)"; exit 0 ;;
esac

LAUNCHER="$ROOT/bin/fm-remote-herdr-launch.pl"
[ -f "$LAUNCHER" ] || fail "the herdr launcher is missing: $LAUNCHER"

TMP_ROOT=$(fm_test_tmproot fm-remote-herdr-launch)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

STUB="$TMP_ROOT/herdr"
RECORD="$TMP_ROOT/server.record"
cat > "$STUB" <<'PL'
#!/usr/bin/perl
# Shows up in the process table as "<path> <args>", like a real herdr, and
# records "<pid> <session id> <args>". Exits with FM_STUB_EXIT after
# FM_STUB_SLEEP seconds when FM_STUB_EXIT is set; otherwise runs until signaled.
use strict;
use warnings;
my @args = @ARGV;
$0 = join ' ', $0, @args;
my $sid = `$ENV{FM_STUB_SID_READER} $$`;
chomp $sid;
open(my $fh, '>', "$ENV{FM_STUB_RECORD}.tmp") or die "$!";
print $fh "$$ $sid @args\n";
close $fh;
rename "$ENV{FM_STUB_RECORD}.tmp", $ENV{FM_STUB_RECORD} or die "$!";
if (defined $ENV{FM_STUB_EXIT} && $ENV{FM_STUB_EXIT} ne '') {
  sleep($ENV{FM_STUB_SLEEP} || 0);
  exit $ENV{FM_STUB_EXIT};
}
sleep 600;
PL
SID_READER="$TMP_ROOT/read-sid"
{
  printf '#!/usr/bin/env bash\n'
  declare -f read_sid
  echo "read_sid \"\$1\""
} > "$SID_READER"
chmod +x "$SID_READER"
export FM_STUB_SID_READER="$SID_READER"
SESSION="fm-remote-launch-test-$$"
chmod +x "$STUB"

LAUNCHER_PID=""
SERVER_PID=""
SERVER_SID=""
SERVER_ARGS=""

cleanup() {
  [ -z "$LAUNCHER_PID" ] || kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
  [ -z "$SERVER_PID" ] || kill -TERM "$SERVER_PID" 2>/dev/null || true
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
FM_STUB_RECORD="$RECORD" perl "$LAUNCHER" "$STUB" server --session "$SESSION" &
LAUNCHER_PID=$!
read_record
[ "$SERVER_ARGS" = "server --session $SESSION" ] \
  || fail "the launcher passed the wrong herdr arguments: $SERVER_ARGS"
[ "$SERVER_SID" = "$SERVER_PID" ] \
  || fail "the herdr server runs in session $SERVER_SID, not its own session (pid $SERVER_PID)"
kill -TERM "$LAUNCHER_PID" 2>/dev/null
wait "$LAUNCHER_PID" 2>/dev/null
pass "the launcher starts herdr as its own session leader with the fm-remote arguments"
LAUNCHER_PID=""

# --- stopping the job stops the server, with nothing left behind -------------

rm -f "$RECORD"
FM_STUB_RECORD="$RECORD" perl "$LAUNCHER" "$STUB" server --session "$SESSION" &
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
FM_STUB_EXIT=3 FM_STUB_SLEEP=1 FM_STUB_RECORD="$RECORD" perl "$LAUNCHER" "$STUB" server --session "$SESSION" &
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
FM_STUB_EXIT=0 FM_STUB_SLEEP=0 FM_STUB_RECORD="$RECORD" perl "$LAUNCHER" "$STUB" server --session "$SESSION" &
LAUNCHER_PID=$!
wait "$LAUNCHER_PID"
LAUNCHER_RC=$?
LAUNCHER_PID=""
[ "$LAUNCHER_RC" -ne 0 ] || fail "a server that exited 0 made the launcher exit 0, so KeepAlive would not restart the job"
pass "a server that exits cleanly still makes the launcher exit non-zero"

# --- a SIGKILLed job's server is adopted on restart, not duplicated ----------

rm -f "$RECORD"
FM_STUB_RECORD="$RECORD" perl "$LAUNCHER" "$STUB" server --session "$SESSION" &
LAUNCHER_PID=$!
read_record
kill -KILL "$LAUNCHER_PID"
wait "$LAUNCHER_PID" 2>/dev/null
kill -0 "$SERVER_PID" 2>/dev/null || fail "the server did not outlive a SIGKILLed launcher, so this case proves nothing"
rm -f "$RECORD"
FM_STUB_RECORD="$RECORD" perl "$LAUNCHER" "$STUB" server --session "$SESSION" &
LAUNCHER_PID=$!
sleep 1.5
[ ! -e "$RECORD" ] || fail "the restarted launcher started a second server instead of adopting pid $SERVER_PID"
kill -0 "$LAUNCHER_PID" 2>/dev/null || fail "the restarted launcher exited instead of supervising the running server"
kill -0 "$SERVER_PID" 2>/dev/null || fail "the restarted launcher stopped the running server instead of adopting it"
kill -TERM "$LAUNCHER_PID"
wait "$LAUNCHER_PID" 2>/dev/null
LAUNCHER_RC=$?
LAUNCHER_PID=""
for _ in $(seq 1 30); do
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$SERVER_PID" 2>/dev/null && fail "stopping the restarted job left the adopted server running (pid $SERVER_PID)"
[ "$LAUNCHER_RC" -ne 0 ] || fail "the launcher exited 0 after its adopted server stopped"
SERVER_PID=""
pass "a restarted job adopts the server a SIGKILLed launcher left behind and stops it on TERM"
