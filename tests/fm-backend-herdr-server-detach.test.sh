#!/usr/bin/env bash
# tests/fm-backend-herdr-server-detach.test.sh - the headless herdr server
# start must leave the invoking job's process group and descriptor table.
#
# bin/fm-remote-job-worker.sh executes every staged remote command under
# `set -m` in its own process group, polls that group for liveness before
# publishing the result, and relays stdout/stderr through pipes it reads to
# EOF. On a Linux host, bin/fm-remote-doctor.sh --fix reaches
# fm_backend_herdr_server_ensure to start the fm-remote server. A server
# start left inside the invoking session, process group, or descriptor
# table keeps the invoking command "alive" to that supervision for as long
# as the daemon runs - the wedge observed on a real remote second-mate
# host. This test drives the real ensure function through a fake
# long-running herdr server and proves the invoking group drains while the
# daemon keeps running in its own session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the adapter parses its JSON)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-herdr-server-detach)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

FAKEBIN="$TMP_ROOT/bin"
mkdir -p "$FAKEBIN"
SERVER_RUNNING="$TMP_ROOT/server.running"
SERVER_PID_FILE="$TMP_ROOT/server.pid"
SERVER_STDIN_EOF="$TMP_ROOT/server.stdin-eof"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "status --json")
    if [ -f "$FM_FAKE_HERDR_RUNNING" ]; then
      printf '{"server":{"running":true}}\n'
    else
      printf '{"server":{"running":false}}\n'
    fi
    ;;
  "server "*)
    # A real herdr server is a long-running daemon. This double records its
    # pid, marks itself reachable so the next status poll answers running,
    # and proves its stdin is detached: an inherited SSH/job pipe held open
    # by the invoker would never produce the EOF that marks a closed stdin.
    printf '%s\n' "$$" > "$FM_FAKE_SERVER_PID"
    : > "$FM_FAKE_HERDR_RUNNING"
    ( IFS= read -r _ 2>/dev/null || : > "$FM_FAKE_SERVER_STDIN_EOF" ) &
    exec sleep 300
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/herdr"

# The invoker models bin/fm-remote-job-worker.sh's supervised execution
# contract exactly: `set -m`, the staged command in its own process group,
# a bounded group-liveness poll, then wait. A leaked background server in
# that group - or holding the staged pipes - keeps the poll true until the
# job timeout, which is the defect this test regresses.
cat > "$TMP_ROOT/run-job.sh" <<SH
#!/usr/bin/env bash
set -u
set -m
out=\$1
(
  export PATH="$FAKEBIN:\$PATH"
  export FM_FAKE_HERDR_RUNNING="$SERVER_RUNNING" \
    FM_FAKE_SERVER_PID="$SERVER_PID_FILE" \
    FM_FAKE_SERVER_STDIN_EOF="$SERVER_STDIN_EOF"
  . "$ROOT/bin/backends/herdr.sh"
  fm_backend_herdr_server_ensure fm-remote
) </dev/null >"\$out.stdout" 2>"\$out.stderr" &
gp=\$!
printf '%s\n' "\$gp" > "\$out.group"
timed_out=0
deadline=\$((SECONDS + 20))
while kill -0 -- "-\$gp" 2>/dev/null; do
  if [ "\$SECONDS" -ge "\$deadline" ]; then
    timed_out=1
    break
  fi
  sleep 0.05
done
wait "\$gp" 2>/dev/null
rc=\$?
printf '%s %s\n' "\$timed_out" "\$rc" > "\$out.result"
SH
chmod +x "$TMP_ROOT/run-job.sh"

cleanup() {
  [ ! -f "$SERVER_PID_FILE" ] || kill "$(cat "$SERVER_PID_FILE")" 2>/dev/null || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

bash "$TMP_ROOT/run-job.sh" "$TMP_ROOT/job" || fail "the supervised invocation driver failed"
read -r timed_out rc < "$TMP_ROOT/job.result"
[ "$timed_out" = 0 ] || fail "the supervised job's process group stayed alive; the detached server held the invoker open"
[ "$rc" = 0 ] || fail "fm_backend_herdr_server_ensure failed under group supervision (rc=$rc):"$'\n'"$(cat "$TMP_ROOT/job.stderr" 2>/dev/null)"
group_pid=$(cat "$TMP_ROOT/job.group")
kill -0 -- "-$group_pid" 2>/dev/null \
  && fail "the herdr server remained inside the invoking process group $group_pid"

assert_present "$SERVER_PID_FILE" "the detached start never launched the herdr server"
server_pid=$(cat "$SERVER_PID_FILE")
kill -0 "$server_pid" 2>/dev/null \
  || fail "the herdr server did not keep running after the invoking command returned"
server_sid=$(ps -o sid= -p "$server_pid" 2>/dev/null | tr -d '[:space:]')
[ "$server_sid" = "$server_pid" ] \
  || fail "the herdr server did not move into its own session (sid=$server_sid pid=$server_pid)"
server_pgid=$(ps -o pgid= -p "$server_pid" 2>/dev/null | tr -d '[:space:]')
[ "$server_pgid" != "$group_pid" ] \
  || fail "the herdr server kept the invoking job's process group $group_pid"
assert_present "$SERVER_STDIN_EOF" "the detached server still holds an inherited stdin pipe"
assert_present "$SERVER_RUNNING" "the herdr server was not reported running after the ensure"
pass "the detached herdr server drains the invoking process group and closes inherited pipes while it keeps running"

# A second ensure against the already-running server is a no-op: it takes
# the early return and never starts a second daemon.
kill "$(cat "$SERVER_PID_FILE")" 2>/dev/null || true
rm -f "$SERVER_PID_FILE"
( PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_RUNNING="$SERVER_RUNNING" \
  FM_FAKE_SERVER_PID="$SERVER_PID_FILE" FM_FAKE_SERVER_STDIN_EOF="$SERVER_STDIN_EOF" \
  bash -c '. "$1"; fm_backend_herdr_server_ensure fm-remote' _ "$ROOT/bin/backends/herdr.sh" ) \
  || fail "ensure failed against an already-running server"
assert_absent "$SERVER_PID_FILE" "ensure started a second server while one was already running"
pass "ensure is idempotent against an already-running server"

# Exercise the portable fallback when setsid is unavailable. The nested
# asynchronous shell must still drain the supervised invocation promptly.
rm -f "$SERVER_RUNNING" "$SERVER_PID_FILE" "$SERVER_STDIN_EOF"
outcome="$TMP_ROOT/fallback"
FM_HERDR_DISABLE_SETSID=1 FM_HERDR_DISABLE_PERL=1 bash "$TMP_ROOT/run-job.sh" "$outcome" \
  || fail "the fallback supervision driver failed"
read -r timed_out rc < "$outcome.result"
[ "$timed_out" = 0 ] || fail "the fallback server remained attached to the invoking group"
[ "$rc" = 0 ] || fail "fallback ensure failed (rc=$rc): $(cat "$outcome.stderr" 2>/dev/null)"
fallback_pid=$(cat "$SERVER_PID_FILE")
kill -0 "$fallback_pid" 2>/dev/null || fail "fallback herdr server did not survive the invoking command"
fallback_group=$(cat "$outcome.group")
kill -0 -- "-$fallback_group" 2>/dev/null && fail "fallback herdr server remained in the invoking group"
kill "$fallback_pid" 2>/dev/null || true
pass "setsid-absent fallback double-forks away from the invoking group"

echo "ALL TESTS PASSED"
