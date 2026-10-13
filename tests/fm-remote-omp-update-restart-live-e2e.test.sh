#!/usr/bin/env bash
# Opt-in live guard: a real remote OMP second mate, running in a guarded Herdr
# lab, is updated across a change to its loaded primary-extension closure and is
# then restarted through the persist-gated restart.
#
# Scope is OMP only: the loaded-closure binding exists only for remote OMP
# second mates. The guard proves, against the real harness, that the version the
# real extension publishes at load equals the committed closure of the commit it
# loaded from, that after the update the restart's persist request still reaches
# that live session while ordinary requests stay refused, that the session
# answers before it is stopped, and that the relaunched session loads the new
# closure.
#
# Every real Herdr call goes through the guarded lab helper. The remote host
# control pins its Herdr session to `fm-remote`, so the code root's herdr
# wrapper maps exactly that name, and the lab's own name, to the lab session and
# refuses every other session, lifecycle, or server command. The SSH readiness
# doctor is answered by the deterministic boundary, and the remote reply relay
# is modelled by copying the agent's own correlated reply into the parent status
# channel (tests/fm-remote-reply.test.sh owns the relay itself).
#
# Run: FM_OMP_REMOTE_UPDATE_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-remote-omp-update-restart-live-e2e.test.sh
# Optional: FM_OMP_REMOTE_UPDATE_LIVE_MODEL (default openai-codex/gpt-5.6-luna),
# HERDR_LAB_HELPER, FM_OMP_REMOTE_UPDATE_LIVE_KEEP_FAILED=1.
set -u

if [ "${FM_OMP_REMOTE_UPDATE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_REMOTE_UPDATE_LIVE_E2E=1 to run the real remote OMP update and restart guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-omp-process-lib.sh
. "$ROOT/bin/fm-omp-process-lib.sh"
# shellcheck source=bin/fm-primary-watch-version-lib.sh
. "$ROOT/bin/fm-primary-watch-version-lib.sh"

command -v omp >/dev/null 2>&1 || fail "omp not found"
command -v herdr >/dev/null 2>&1 || fail "herdr not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v perl >/dev/null 2>&1 || fail "perl not found"

OMP_BIN=$("$ROOT/bin/fm-omp-capabilities.sh" --print-binary) || fail "OMP capability check failed"
OMP_BIN=$(fm_test_realpath "$OMP_BIN") || fail "OMP binary realpath could not be resolved"
OMP_LAUNCH_IDENTITY=$(fm_omp_process_launch_identity "$OMP_BIN") \
  || fail "OMP launch identity could not be resolved for $OMP_BIN"
OMP_RUNTIME=$(printf '%s\n' "$OMP_LAUNCH_IDENTITY" | sed -n '1p')
OMP_BIN=$(printf '%s\n' "$OMP_LAUNCH_IDENTITY" | sed -n '2p')
OMP_VERSION=$("$OMP_BIN" --version 2>/dev/null | head -1)
REAL_HERDR=$(command -v herdr)
HERDR_VERSION=$("$REAL_HERDR" --version 2>/dev/null | head -1)
MODEL=${FM_OMP_REMOTE_UPDATE_LIVE_MODEL:-openai-codex/gpt-5.6-luna}
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"
echo "# harness: $OMP_VERSION ($OMP_BIN); herdr: $HERDR_VERSION; model: $MODEL"

fm_git_identity
LAB=$(fm_test_tmproot fm-remote-omp-update-live)
LAB=$(cd "$LAB" && pwd -P)
git -C "$LAB" init -q
SESSION=$("$HERDR_LAB_HELPER" name remote-omp-upd) || fail "could not name the guarded Herdr lab"
BASE_PATH=$PATH
PARENT="$LAB/parent"
REMOTE_ROOT="$LAB/remote-root"
REMOTE_ORIGIN="$LAB/firstmate-origin.git"
OMP_HOME="$LAB/remote-omp-home"
ID="omp-upd-live-$$"
CONTROL="$OMP_HOME/state/parent-route"
WRAPPER_LOG="$LAB/herdr-wrapper.log"
FAKEBIN=$(fm_fakebin "$LAB/fake")
CLAIMS="$LAB/claims"
TEARDOWN_DONE=0
RELAY_PID=

# The host's job worker is a supervisor plus its serving child. Stop both while
# their state root still exists, so the child can release its ownership.
stop_remote_job_worker() {
  local pid supervisor='' waited=0
  pid=$(cat "$LAB/remote-jobs/worker.pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  case "$(ps -p "$pid" -o command= 2>/dev/null || true)" in
    *"$REMOTE_ROOT/bin/fm-remote-job-worker.sh"*) ;;
    *) return 0 ;;
  esac
  supervisor=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
  case "$supervisor" in
    ''|*[!0-9]*|0|1) supervisor='' ;;
    *)
      case "$(ps -p "$supervisor" -o command= 2>/dev/null || true)" in
        *"$REMOTE_ROOT/bin/fm-remote-job-worker.sh"*) kill "$supervisor" 2>/dev/null || true ;;
        *) supervisor='' ;;
      esac
      ;;
  esac
  kill "$pid" 2>/dev/null || true
  while { [ -n "$supervisor" ] && kill -0 "$supervisor" 2>/dev/null; } || kill -0 "$pid" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -lt 200 ] || return 1
    sleep 0.05
  done
}

cleanup() {
  local cleanup_ok=1
  [ -z "$RELAY_PID" ] || kill "$RELAY_PID" 2>/dev/null || true
  if [ "${FM_OMP_REMOTE_UPDATE_LIVE_KEEP_FAILED:-0}" = 1 ] && [ "$TEARDOWN_DONE" -ne 1 ]; then
    echo "diagnostic: preserving failed lab $SESSION at $LAB" >&2
    return
  fi
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  stop_remote_job_worker || cleanup_ok=0
  if [ "$TEARDOWN_DONE" -ne 1 ]; then
    FM_HERDR_LAB_INNER=1 PATH="$BASE_PATH" "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 \
      || cleanup_ok=0
  fi
  if [ "$cleanup_ok" -eq 1 ]; then
    rm -rf "/tmp/fm-$ID"
    fm_test_cleanup
  else
    echo "not ok - lab teardown, its default-session tripwire, or the job worker stop failed; preserving $LAB" >&2
    trap - EXIT
    exit 1
  fi
}
trap cleanup EXIT

wait_for() { # <seconds> <description> <command...>
  local seconds=$1 description=$2 i=0
  shift 2
  while [ "$i" -lt $((seconds * 4)) ]; do
    "$@" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  fail "timed out after ${seconds}s waiting for $description"
}

# --- remote host code root --------------------------------------------------
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
ln -s "$OMP_BIN" "$REMOTE_ROOT/bin/omp"
# The host's job worker puts the code root's bin first on PATH, so this wrapper
# is the only herdr every host-side Firstmate command and OMP pane can reach.
cat > "$REMOTE_ROOT/bin/herdr" <<SH
#!/usr/bin/env bash
set -u
real='$REAL_HERDR'
helper='$HERDR_LAB_HELPER'
session='$SESSION'
pinned=fm-remote
base_path='$BASE_PATH'
log='$WRAPPER_LOG'
omp_bin='$OMP_BIN'
omp_runtime='$OMP_RUNTIME'
process_lib='$ROOT/bin/fm-omp-process-lib.sh'
if [ "\${FM_HERDR_LAB_INNER:-0}" = 1 ]; then
  exec "\$real" "\$@"
fi
case "\${1:-}" in
  --version|-V|version) exec "\$real" "\$@" ;;
esac
. "\$process_lib"
# OMP probes Herdr with its own read-only commands, outside Firstmate's
# backend API; quarantine exactly those from an exact OMP parent.
parent_args=\$(ps -o args= -p "\$PPID" 2>/dev/null || true)
parent_exe=\$(readlink -f "/proc/\$PPID/exe" 2>/dev/null || true)
if FM_OMP_PROCESS_EXPECTED_BUN="\$omp_runtime" FM_OMP_PROCESS_EXPECTED_BIN="\$omp_bin" \
    fm_omp_process_matches "\$parent_exe" "\$parent_args" "\$PPID"; then
  case "\$#:\$*" in
    "1:agent"|"1:--help"|"2:agent --help"|"2:agent list"|"2:pane read --help"|3:agent\ get\ *|7:pane\ read\ *|7:agent\ read\ *)
      printf '%q ' "\$@" >> "\$log.native-omp-probes"
      printf '\n' >> "\$log.native-omp-probes"
      exit 96
      ;;
  esac
fi
printf -v rendered '%q ' "\$@"
printf '%s\n' "\$rendered" >> "\$log"
refuse() { # <exit-code> <reason>
  printf 'args=%s reason=%s parent=%s\n' "\$rendered" "\$2" "\$parent_args" >> "\$log.callers"
  echo "remote OMP lab wrapper refused \$2" >&2
  exit "\$1"
}
argc=\$#
args=("\$@")
if [ "\$argc" -ge 2 ] && [ "\${args[\$((argc - 2))]}" = --session ]; then
  case "\${args[\$((argc - 1))]}" in
    "\$session"|"\$pinned") set -- "\${args[@]:0:\$((argc - 2))}" ;;
    *) refuse 96 "a command outside the lab session" ;;
  esac
else
  case "\$argc:\$*" in
    "2:status --json"|"3:session list --json"|"3:api schema --json") ;;
    *) refuse 96 "a command without an explicit session binding" ;;
  esac
fi
case "\${1:-}" in
  server) refuse 97 "a server command" ;;
  session)
    [ "\$#" -eq 3 ] && [ "\$2" = list ] && [ "\$3" = --json ] || refuse 97 "a session lifecycle command"
    # Only the lab is visible, under the name the remote control pins.
    env FM_HERDR_LAB_INNER=1 PATH="\$base_path" "\$helper" run "\$session" "\$@" \
      | jq -c --arg lab "\$session" --arg pinned "\$pinned" \
        '.sessions |= [.[]? | select(.name == \$lab) | .name = \$pinned]'
    exit "\${PIPESTATUS[0]}"
    ;;
esac
exec env FM_HERDR_LAB_INNER=1 PATH="\$base_path" "\$helper" run "\$session" "\$@"
SH
chmod +x "$REMOTE_ROOT/bin/herdr"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" add -A
git -C "$REMOTE_ROOT" commit -qm 'remote live root'
git init -q --bare "$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" remote add origin "file://$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$REMOTE_ORIGIN" symbolic-ref HEAD refs/heads/main
# The parent side has no Herdr endpoint of its own; any local Herdr call from it
# is refused and recorded rather than reaching a real server.
cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$LAB/parent-herdr-refused.log'
exit 97
SH
chmod +x "$FAKEBIN/herdr"
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = remote-mac ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
cd "$FM_FAKE_REMOTE_CWD" || exit 93
command_name=$(perl -MMIME::Base64=decode_base64 -e '
  my @args=split(/\0/, decode_base64($ARGV[0]));
  print $args[0];
' "$4")
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u HERDR_TAB_ID \
    -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH -u FM_TASK_ID \
    PATH="$FAKEBIN:$BASE_PATH" \
    FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$LAB/remote-jobs" \
    FM_FAKE_REMOTE_CWD="$LAB" FM_SEND_SETTLE=0 \
    "$@"
}

loaded_field() { sed -n "${1}p" "$OMP_HOME/state/.omp-primary-extension-loaded" 2>/dev/null; }
tracked_version() {
  fm_primary_watch_version "$OMP_HOME/.omp/extensions/fm-primary-omp.ts" "$OMP_HOME"
}
remote_state() {
  remote_env "$ROOT/bin/fm-on.sh" "$ID" fm-remote-secondmate-control.sh state "$ID" < /dev/null 2>/dev/null
}
remote_pane() { sed -n 's/^herdr_pane_id=//p' "$CONTROL/$ID.meta" 2>/dev/null; }
agent_is() { # <identity> <state-pattern>
  local info identity state
  info=$(FM_HERDR_LAB_INNER=1 PATH="$BASE_PATH" "$HERDR_LAB_HELPER" run "$SESSION" agent get "$(remote_pane)" 2>/dev/null || true)
  identity=$(printf '%s' "$info" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  state=$(printf '%s' "$info" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  [ "$identity" = "$1" ] || return 1
  case " $2 " in *" $state "*) return 0 ;; *) return 1 ;; esac
}
marker_owned_by_new_session() { # <old-pid>
  local pid
  pid=$(loaded_field 2)
  [ -n "$pid" ] && [ "$pid" != "$1" ] && kill -0 "$pid" 2>/dev/null
}

# A live parent watcher keeps the guard banner out of reported refusals.
watcher_identity=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" /bin/bash -c \
  '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
  || fail "could not derive the parent watcher identity"
mkdir -p "$PARENT/state/.watch.lock"
printf '%s\n' "$$" > "$PARENT/state/.watch.lock/pid"
printf '%s\n' "$watcher_identity" > "$PARENT/state/.watch.lock/pid-identity"
printf '%s\n' "$PARENT" > "$PARENT/state/.watch.lock/fm-home"
printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$PARENT/state/.watch.lock/watcher-path"
touch "$PARENT/state/.last-watcher-beat"
printf 'omp %s low\n' "$MODEL" > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"

FM_HERDR_LAB_INNER=1 PATH="$BASE_PATH" "$HERDR_LAB_HELPER" provision "$SESSION" >/dev/null \
  || fail "could not provision the guarded Herdr lab"

# --- a real remote OMP second mate on the pre-update closure ---------------
FM_SECONDMATE_CHARTER='Live guard second mate. Hold no project work; answer parent requests through your parent channel.' \
  FM_SECONDMATE_SCOPE='remote OMP update and restart live guard' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" "$ID" remote-mac "$REMOTE_ROOT" \
  "$OMP_HOME" --no-projects > "$LAB/seed.out" 2>&1 \
  || fail "remote OMP route seeding failed: $(cat "$LAB/seed.out")"
remote_env "$ROOT/bin/fm-spawn.sh" "$ID" --secondmate > "$LAB/launch.out" 2>&1 \
  || fail "real remote OMP secondmate launch failed: $(cat "$LAB/launch.out")"
[ "$(remote_state)" = alive ] || fail "the real remote OMP endpoint is not alive after launch"
wait_for 120 "the real OMP primary marker" test -s "$OMP_HOME/state/.omp-primary-extension-loaded"
wait_for 120 "the real OMP task doorbell" test -s "$CONTROL/$ID.omp-doorbell-ready"
wait_for 900 "the real OMP second mate to finish its first turn" agent_is omp 'idle done'
OLD_HEAD=$(git -C "$OMP_HOME" rev-parse HEAD)
OLD_PID=$(loaded_field 2)
OLD_VERSION=$(loaded_field 1)
[ "$OLD_VERSION" = "$(tracked_version)" ] \
  || fail "$OMP_VERSION published loaded version $OLD_VERSION, not the tracked closure $(tracked_version)"
[ "$OLD_VERSION" = "$(fm_omp_primary_version_at_commit "$OMP_HOME" "$OLD_HEAD")" ] \
  || fail "$OMP_VERSION published a loaded version that is not the committed closure of $OLD_HEAD"
pass "$OMP_VERSION publishes the committed closure version it loaded"

# --- the update crosses an extension change --------------------------------
git clone -q "file://$REMOTE_ORIGIN" "$LAB/firstmate-dev"
printf '// extension change shipped by the live update\n' >> "$LAB/firstmate-dev/bin/fm-primary-watch-core.ts"
git -C "$LAB/firstmate-dev" commit -qam 'change the OMP primary extension closure'
git -C "$LAB/firstmate-dev" push -q origin main
NEW_HEAD=$(git -C "$LAB/firstmate-dev" rev-parse HEAD)
remote_env "$ROOT/bin/fm-update.sh" > "$LAB/update.out" 2>&1 \
  || fail "the update failed: $(cat "$LAB/update.out")"
grep -Fqx "restart-secondmates: fm-$ID" "$LAB/update.out" \
  || fail "the update did not name the live remote OMP mate for restart:"$'\n'"$(cat "$LAB/update.out")"
[ "$(git -C "$OMP_HOME" rev-parse HEAD)" = "$NEW_HEAD" ] \
  || fail "the update did not fast-forward the remote home to $NEW_HEAD"
{ [ "$(loaded_field 2)" = "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; } \
  || fail "the update did not leave the original OMP session running"
{ [ "$(loaded_field 1)" = "$OLD_VERSION" ] && [ "$OLD_VERSION" != "$(tracked_version)" ]; } \
  || fail "the update did not leave the live session on a superseded closure"

post_rc=0
touch "$PARENT/state/.last-watcher-beat"
remote_env "$ROOT/bin/fm-send.sh" "fm-$ID" "ordinary steer after the update" > "$LAB/post-update.out" 2>&1 \
  || post_rc=$?
expect_code 9 "$post_rc" "an ordinary request reached the superseded live session: $(cat "$LAB/post-update.out")"
assert_grep 'loaded OMP primary extension does not match its tracked closure' "$LAB/post-update.out" \
  "the superseded live session's ordinary refusal lost its exact reason"
pass "the superseded live OMP session refuses ordinary requests after the update"

# --- the persist-gated restart ----------------------------------------------
# The loop below models the parent's reply relay and keeps the modelled parent
# watcher beacon fresh while the restart waits for the live answer.
: > "$LAB/relay.log"
(
  seen=0
  while :; do
    touch "$PARENT/state/.last-watcher-beat"
    log="$OMP_HOME/state/parent-replies.status"
    if [ -f "$log" ]; then
      total=$(wc -l < "$log" | tr -d '[:space:]')
      if [ "$total" -gt "$seen" ]; then
        sed -n "$((seen + 1)),${total}p" "$log" | while IFS= read -r line; do
          # The charter asks for the exact corr=<id> token anywhere in the line.
          case "$line" in
            *corr=*)
              alive=stopped
              kill -0 "$OLD_PID" 2>/dev/null && alive=running
              printf '%s\n' "$line" >> "$PARENT/state/$ID.status"
              printf 'relayed original-session=%s %s\n' "$alive" "$line" >> "$LAB/relay.log"
              ;;
          esac
        done
        seen=$total
      fi
    fi
    sleep 1
  done
) &
RELAY_PID=$!
restart_rc=0
remote_env FM_SECONDMATE_PERSIST_WAIT=900 FM_SECONDMATE_PERSIST_POLL=5 \
  "$ROOT/bin/fm-secondmate-restart.sh" "fm-$ID" > "$LAB/restart.out" 2>&1 || restart_rc=$?
kill "$RELAY_PID" 2>/dev/null || true
RELAY_PID=
cat "$LAB/restart.out"
expect_code 0 "$restart_rc" "the live restart after the update did not restart the mate:"$'\n'"$(cat "$LAB/restart.out")"
grep -Fqx "restarted: $ID on remote-mac (omp)" "$LAB/restart.out" \
  || fail "the live restart did not report the remote OMP mate as restarted"
grep -q '^relayed original-session=running .*corr=' "$LAB/relay.log" \
  || fail "the live session did not answer the persist request before it stopped:"$'\n'"$(cat "$LAB/relay.log")"
persisted_records=$(find "$CONTROL/$ID.inbox/handled" -name '*.msg' -exec grep -l 'Open-record persistence' {} + 2>/dev/null) \
  || fail "the live session never acknowledged the persist request record"
[ -n "$persisted_records" ] \
  || fail "the live session never acknowledged the persist request record"
kill -0 "$OLD_PID" 2>/dev/null && fail "the original OMP session is still running after the restart"
wait_for 120 "the relaunched OMP session's marker" marker_owned_by_new_session "$OLD_PID"
[ "$(loaded_field 1)" = "$(tracked_version)" ] \
  || fail "the relaunched OMP session did not load the updated closure"
[ "$(remote_state)" = alive ] || fail "the relaunched remote OMP endpoint is not alive"
pass "the live restart persists the superseded session's open work, stops it, and relaunches on the new closure"

# Every Herdr command reached the lab helper with an accepted session binding,
# and none was refused or escaped it.
[ -s "$WRAPPER_LOG" ] || fail "no Herdr command went through the lab wrapper"
if [ -s "$WRAPPER_LOG.callers" ]; then
  cat "$WRAPPER_LOG.callers" >&2
  fail "the lab wrapper refused a production Herdr command"
fi
[ ! -s "$LAB/parent-herdr-refused.log" ] \
  || fail "the parent side issued local Herdr commands: $(cat "$LAB/parent-herdr-refused.log")"
FM_HERDR_LAB_INNER=1 PATH="$BASE_PATH" "$HERDR_LAB_HELPER" teardown "$SESSION" >/dev/null \
  || fail "guarded Herdr lab teardown or its default-session tripwire failed"
TEARDOWN_DONE=1
pass "real remote OMP update and restart in a guarded Herdr lab ($OMP_VERSION, $HERDR_VERSION)"
