#!/usr/bin/env bash
# Full remote secondmate lifecycle over the deterministic generic SSH boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-e2e)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
LOCAL_HOME="$TMP_ROOT/local-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
TMUX_LOG="$TMP_ROOT/remote-tmux.log"
TMUX_STATE="$TMP_ROOT/remote-tmux.state"
OMP_ACTIVE_PID="$TMP_ROOT/remote-omp-active.pid"
HERDR_FORCE_IDLE="$TMP_ROOT/remote-herdr-force-idle"
OMP_TYPED_INPUT="$TMP_ROOT/remote-omp-typed-input"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"
cleanup() {
  local worker_pid='' supervisor_pid='' supervisor_command='' wait_attempt=0
  [ -z "${OMP_LISTENER_PID:-}" ] || kill -TERM "$OMP_LISTENER_PID" 2>/dev/null || true
  [ -z "${OMP_LISTENER_PID:-}" ] || wait "$OMP_LISTENER_PID" 2>/dev/null || true
  rm -f "$OMP_ACTIVE_PID" "$HERDR_FORCE_IDLE"
  touch "$TMP_ROOT/provision.release" "$TMP_ROOT/seed.release" "$TMP_ROOT/handoff.release" \
    "$TMP_ROOT/inherit.release" "$TMP_ROOT/launch.release" 2>/dev/null || true
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    supervisor_pid=$(ps -p "$worker_pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
    case "$supervisor_pid" in
      ''|*[!0-9]*|0|1) supervisor_pid='' ;;
      *) supervisor_command=$(ps -p "$supervisor_pid" -o command= 2>/dev/null || true) ;;
    esac
    case "$supervisor_command" in
      *"$REMOTE_ROOT/bin/fm-remote-job-worker.sh"*) kill "$supervisor_pid" 2>/dev/null || true ;;
      *) supervisor_pid=''; kill "$worker_pid" 2>/dev/null || true ;;
    esac
    while { [ -n "$supervisor_pid" ] && kill -0 "$supervisor_pid" 2>/dev/null; } \
      || kill -0 "$worker_pid" 2>/dev/null; do
      wait_attempt=$((wait_attempt + 1))
      [ "$wait_attempt" -lt 100 ] || break
      sleep 0.05
    done
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

# Materialize the current branch as the remote host's tracked code root. The
# fixture is a real git repository because provisioning and guarded sync exercise
# the same clone and fast-forward path as a second Mac.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
cat > "$REMOTE_ROOT/bin/tmux" <<SH
#!/usr/bin/env bash
set -u
log='$TMUX_LOG'
state='$TMUX_STATE'
fail_send='$TMP_ROOT/tmux-send-fail'
printf '%s\n' "\$*" >> "\$log"
case "\${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ -f "\$state" ] || exit 0
    name=\$(cut -d'|' -f1 "\$state")
    case "\$*" in *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "\$name" ;; *) printf '%s\n' "\$name" ;; esac
    exit 0
    ;;
  new-window)
    name=; cwd=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in -n) shift; name=\$1 ;; -c) shift; cwd=\$1 ;; esac
      shift
    done
    printf '%s|%s\n' "\$name" "\$cwd" > "\$state"
    printf '@1\n'
    exit 0
    ;;
  display-message)
    case "\$*" in
      *'#{pane_current_path}'*) cut -d'|' -f2- "\$state" ;;
      *'#{pane_current_command}'*) printf 'codex\n' ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0
    ;;
  capture-pane) printf '\n'; exit 0 ;;
  send-keys) [ ! -f "\$fail_send" ] || exit 1; exit 0 ;;
  kill-window) rm -f -- "\$state"; exit 0 ;;
  list-panes) printf 'codex\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
cat > "$REMOTE_ROOT/bin/omp" <<'JS'
#!/usr/bin/env bun
if (process.argv[2] === "models" && process.argv.includes("--json")) {
  console.log(JSON.stringify({models: [{selector: "test/model", thinking: ["low", "medium", "high", "xhigh"]}]}));
} else {
  console.log(`OMP 17.2.11
--model=<value>
--thinking=<value>
--auto-approve
--max-time=<value>
--extension=<value>
--session-dir=<value>
--resume=<value>
--prewalk native switch
--prewalk-into=<value>
--no-prewalk`);
}
JS
chmod +x "$REMOTE_ROOT/bin/omp"
REMOTE_OMP_BIN=$(fm_test_realpath "$REMOTE_ROOT/bin/omp")
REMOTE_OMP_BUN=$(fm_test_realpath "$(command -v node)")
ln -sf "$REMOTE_OMP_BUN" "$REMOTE_ROOT/bin/bun"
cat > "$REMOTE_ROOT/bin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = --json ]; then
  printf '%s\n' '{"auth":[{"provider":"claude","sources":[{"source":"oauth-file","status":"available"}]}]}'
elif [ "${1:-}" = --provider ] && [ "${3:-}" = --json ]; then
  printf '%s\n' '{"providers":[{"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","effectivePercentRemaining":42}]}}]}'
fi
SH
chmod +x "$REMOTE_ROOT/bin/quota-axi"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock" "$$" "$REMOTE_OMP_BUN" "$REMOTE_OMP_BIN" \
  "$OMP_ACTIVE_PID" "$HERDR_FORCE_IDLE" "$OMP_TYPED_INPUT"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
REMOTE_ORIGIN="$TMP_ROOT/firstmate-origin.git"
git init -q --bare "$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" remote add origin "file://$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$REMOTE_ORIGIN" symbolic-ref HEAD refs/heads/main

# One remote-backed direct-PR project. The remote home clones its origin, never
# the primary working tree.
git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
cat > "$PARENT/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-08-02)
EOF
printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'primary harness defaults\n' > "$PARENT/config/crew-harness"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..2]);
' "$argv_b64")
IFS=$'\t' read -r command_name _command_action command_rel <<EOF
$command_fields
EOF
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_rel" in
  inherit-partial:fm-remote-inherit.sh:config/crew-harness) exit 255 ;;
  inherit-block:fm-remote-inherit.sh:data/captain-shared.md)
    cat > "$FM_FAKE_INHERIT_PAYLOAD"
    touch "$FM_FAKE_INHERIT_ENTERED"
    while [ ! -f "$FM_FAKE_INHERIT_RELEASE" ]; do sleep 0.02; done
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" < "$FM_FAKE_INHERIT_PAYLOAD"
    exit $?
    ;;
esac
# The readiness gate is answered here rather than by the real doctor, which
# would inspect and repair the RUNNER's own account. tests/fm-remote-doctor.test.sh
# owns the doctor's real behavior against controlled account fixtures; this
# boundary owns only what the callers do with its verdict.
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf '%s %s\n' "${FM_FAKE_SSH_MODE:-normal}" "${_command_action:--}" >> "$FM_FAKE_DOCTOR_LOG"
  case "${FM_FAKE_SSH_MODE:-normal}" in
    unreachable) exit 255 ;;
    doctor-fix-unknown)
      if [ "${_command_action:-}" = --fix ]; then
        printf 'fix launchagent=applied: wrote the Aqua-scoped launch agent\n'
        exit 255
      fi
      printf 'check launchagent=fixable: no Firstmate herdr launch agent\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: launchagent\n' >&2
      exit 1
      ;;
    doctor-human)
      printf 'check gui-session=human: no Aqua login session exists for uid 501\n'
      printf 'action: gui-session: log that account in once at the console\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: gui-session\n' >&2
      exit 1
      ;;
    doctor-fixable)
      # Red until --fix runs on this host, green on every later read-only run.
      if [ "${_command_action:-}" = --fix ]; then
        touch "$FM_FAKE_DOCTOR_REPAIRED"
        printf 'fix launchagent=applied: wrote the Aqua-scoped launch agent\n'
        printf 'ok: remote second-mate readiness confirmed on this host\n'
        exit 0
      fi
      [ -f "$FM_FAKE_DOCTOR_REPAIRED" ] || {
        printf 'check launchagent=fixable: no Firstmate herdr launch agent\n'
        printf 'error: this host is not ready for a remote second mate; unresolved: launchagent\n' >&2
        exit 1
      }
      ;;
  esac
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "${FM_FAKE_SSH_MODE:-normal}" = doctor-fixable ] \
  && [ "$command_name" = fm-remote-secondmate-control.sh ] \
  && [ "$_command_action" = state ] \
  && [ ! -f "$FM_FAKE_DOCTOR_REPAIRED" ]; then
  printf 'unreadable\n'
  exit 0
fi
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_rel" in
  launch-nonherdr-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=tmux\n'
    printf 'target=firstmate:fm-ios\n'
    printf 'harness=codex\n'
    printf 'model=default\n'
    printf 'effort=default\n'
    exit 0
    ;;
  launch-default-session-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=herdr\n'
    printf 'target=default:w1:p2\n'
    printf 'herdr_session=default\n'
    printf 'harness=codex\n'
    printf 'model=default\n'
    printf 'effort=default\n'
    exit 0
    ;;
  launch-unverified-harness-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=herdr\n'
    printf 'target=fm-remote:w1:p2\n'
    printf 'herdr_session=fm-remote\n'
    printf 'harness=raw-agent\n'
    printf 'model=default\n'
    printf 'effort=default\n'
    exit 0
    ;;
  provision-block-fail:fm-remote-home-provision.sh:*)
    touch "$FM_FAKE_SEED_ENTERED"
    while [ ! -f "$FM_FAKE_SEED_RELEASE" ]; do sleep 0.02; done
    exit 1
    ;;
  launch-block:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    touch "$FM_FAKE_LAUNCH_ENTERED"
    while [ ! -f "$FM_FAKE_LAUNCH_RELEASE" ]; do sleep 0.02; done
    ;;
esac
case "${FM_FAKE_SSH_MODE:-normal}" in
  unreachable) exit 255 ;;
  ambiguous) "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"; exit 255 ;;
  *) exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"

publish_healthy_watcher_identity() { # <state> <home> <watch-script>
  local state=$1 home=$2 watch=$3 identity
  identity=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" /bin/bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
    || fail "could not derive fixture watcher identity"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$watch" > "$state/.watch.lock/watcher-path"
  touch "$state/.last-watcher-beat"
}

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" \
  FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" \
  FM_FAKE_INHERIT_ENTERED="$TMP_ROOT/inherit.entered" \
  FM_FAKE_INHERIT_RELEASE="$TMP_ROOT/inherit.release" \
  FM_FAKE_INHERIT_PAYLOAD="$TMP_ROOT/inherit.payload" \
  FM_FAKE_LAUNCH_ENTERED="$TMP_ROOT/launch.entered" \
  FM_FAKE_LAUNCH_RELEASE="$TMP_ROOT/launch.release" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

seed_env() {
  FM_HOME="$TMP_ROOT/seed-parent" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" \
  FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" \
  "$@"
}

REAL_GIT=$(command -v git)
cat > "$FAKEBIN/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = clone ] && [ "\${!#}" = "$TMP_ROOT/concurrent-home" ]; then
  printf 'clone\n' >> "$TMP_ROOT/provision-clones"
  if mkdir "$TMP_ROOT/provision-first" 2>/dev/null; then
    touch "$TMP_ROOT/provision.entered"
    while [ ! -f "$TMP_ROOT/provision.release" ]; do sleep 0.02; done
  fi
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$FAKEBIN/git"
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
  "$(printf ios | base64 | tr -d '\n')" \
  "$(printf 'Concurrent provisioning charter.\n' | base64 | tr -d '\n')" \
  > "$TMP_ROOT/provision.manifest"
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/concurrent-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/provision.manifest" \
  > "$TMP_ROOT/provision-one.out" 2>&1 &
provision_one=$!
provision_wait=0
while [ ! -f "$TMP_ROOT/provision.entered" ]; do
  kill -0 "$provision_one" 2>/dev/null || fail "first provisioning attempt exited before cloning"
  provision_wait=$((provision_wait + 1))
  [ "$provision_wait" -le 250 ] || fail "first provisioning attempt never reached cloning"
  sleep 0.02
done
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/concurrent-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/provision.manifest" \
  > "$TMP_ROOT/provision-two.out" 2>&1 &
provision_two=$!
sleep 0.2
[ "$(grep -cF clone "$TMP_ROOT/provision-clones")" -eq 1 ] \
  || fail "overlapping provisioning reached home classification concurrently"
touch "$TMP_ROOT/provision.release"
wait "$provision_one" || fail "first serialized provisioning attempt failed"
wait "$provision_two" || fail "reconciled provisioning attempt failed"
[ "$(cat "$TMP_ROOT/concurrent-home/.fm-secondmate-home")" = ios ] \
  || fail "serialized provisioning lost the published home"
[ "$(grep -cF clone "$TMP_ROOT/provision-clones")" -eq 1 ] \
  || fail "reconciled provisioning cloned the already-published home"
pass "overlapping remote home provisioning serializes through publication and rollback"
if [ "${FM_TEST_PROVISION_ONLY:-0}" = 1 ]; then
  echo "ALL TESTS PASSED"
  exit 0
fi

mkdir -p "$TMP_ROOT/seed-parent/data" "$TMP_ROOT/seed-parent/state"
FM_SECONDMATE_CHARTER='Failing seed charter.' FM_SECONDMATE_SCOPE='failed seed' \
  FM_FAKE_SSH_MODE=provision-block-fail seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-fail remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-fail-home" --no-projects \
  > "$TMP_ROOT/seed-fail.out" 2>&1 &
seed_fail_pid=$!
seed_wait=0
while [ ! -f "$TMP_ROOT/seed.entered" ]; do
  kill -0 "$seed_fail_pid" 2>/dev/null || fail "failing seed exited before remote provisioning"
  seed_wait=$((seed_wait + 1))
  [ "$seed_wait" -le 250 ] || fail "failing seed never reached remote provisioning"
  sleep 0.02
done
FM_SECONDMATE_CHARTER='Successful seed charter.' FM_SECONDMATE_SCOPE='successful seed' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-keep remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-keep-home" --no-projects > "$TMP_ROOT/seed-keep.out" 2>&1 &
seed_keep_pid=$!
sleep 0.2
kill -0 "$seed_keep_pid" 2>/dev/null || fail "competing seed bypassed the shared registry transaction"
touch "$TMP_ROOT/seed.release"
if wait "$seed_fail_pid"; then
  fail "known-failing seed unexpectedly succeeded"
fi
wait "$seed_keep_pid" || fail "serialized successful seed failed"
assert_no_grep '- seed-fail ' "$TMP_ROOT/seed-parent/data/secondmates.md" "failed seed route survived rollback"
assert_grep '- seed-keep ' "$TMP_ROOT/seed-parent/data/secondmates.md" "failed seed rollback removed a competing successful route"
assert_present "$TMP_ROOT/seed-keep-home/.fm-secondmate-home" "serialized seed lost its published remote home"
pass "remote seed rollback preserves serialized competing routes"

: > "$DOCTOR_LOG"
if FM_SECONDMATE_CHARTER='Unknown readiness charter.' FM_SECONDMATE_SCOPE='unknown readiness' \
  FM_FAKE_SSH_MODE=doctor-fix-unknown seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-unknown remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-unknown-home" --no-projects \
  > "$TMP_ROOT/seed-unknown.out" 2>&1; then
  fail "seeding claimed success after readiness repair completion became unknown"
fi
assert_grep 'remote readiness completion is unknown' "$TMP_ROOT/seed-unknown.out" \
  "unknown readiness did not report its distinct completion state"
assert_grep '- seed-unknown ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "unknown readiness removed the registered route"
assert_present "$TMP_ROOT/seed-parent/data/seed-unknown/brief.md" \
  "unknown readiness removed the scaffolded brief"
assert_absent "$TMP_ROOT/seed-unknown-home" \
  "unknown readiness proceeded into remote home provisioning"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fix-unknown -
doctor-fix-unknown --fix' ] || fail "unknown readiness did not occur during the repair stage"$'\n'"$(cat "$DOCTOR_LOG")"
pass "unknown readiness preserves its route and brief for reconciliation"

# A host that cannot hold a durable second mate must be rejected by the
# readiness gate before any home is created on it, and the operator must get the
# gap text rather than a bare refusal.
: > "$DOCTOR_LOG"
if FM_SECONDMATE_CHARTER='Unready host charter.' FM_SECONDMATE_SCOPE='unready host' \
  FM_FAKE_SSH_MODE=doctor-human seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-toolless remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-toolless-home" --no-projects \
  > "$TMP_ROOT/seed-toolless.out" 2>&1; then
  fail "seeding proceeded against a host that is not ready for a remote second mate"
fi
assert_grep 'check gui-session=human:' \
  "$TMP_ROOT/seed-toolless.out" "the seed hid the remaining human gap"
assert_grep 'action: gui-session:' \
  "$TMP_ROOT/seed-toolless.out" "the seed hid the operator step that closes the gap"
assert_grep 'remote runtime preflight failed' "$TMP_ROOT/seed-toolless.out" \
  "the seed did not report the failing stage"
assert_absent "$TMP_ROOT/seed-toolless-home" "the seed provisioned a home despite a failing preflight"
assert_no_grep '- seed-toolless ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the refused route survived the preflight rollback"
assert_absent "$TMP_ROOT/seed-parent/data/seed-toolless/brief.md" \
  "the refused route left its scaffolded charter behind"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-human -
doctor-human --fix
doctor-human -' ] || fail "the seed did not run the check, repair, re-check sequence"$'\n'"$(cat "$DOCTOR_LOG")"
pass "remote seeding checks, repairs, and re-checks readiness, then stops on a remaining gap"

# The same gate must accept a host whose only gaps were repairable.
: > "$DOCTOR_LOG"
rm -f "$TMP_ROOT/doctor.repaired"
out=$(FM_SECONDMATE_CHARTER='Repairable host charter.' FM_SECONDMATE_SCOPE='repairable host' \
  FM_FAKE_SSH_MODE=doctor-fixable seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-repair remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-repair-home" --no-projects 2>&1) \
  || fail "seeding refused a host whose gaps the repair closed"$'\n'"$out"
assert_present "$TMP_ROOT/seed-repair-home/.fm-secondmate-home" "the repaired host was never provisioned"
assert_grep '- seed-repair ' "$TMP_ROOT/seed-parent/data/secondmates.md" "the repaired route was not registered"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable -
doctor-fixable --fix
doctor-fixable -' ] || fail "the repaired seed did not re-check after its repair"$'\n'"$(cat "$DOCTOR_LOG")"
pass "remote seeding proceeds once the repair closes every gap"

# Provision and register the remote route from the captain-facing primary.
out=$(FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha)
assert_contains "$out" "home=remote-mac:$REMOTE_HOME" "remote seed did not report the host-qualified home"
assert_grep 'host: remote-mac; root:' "$PARENT/data/secondmates.md" "registry did not record the remote host dimension"
assert_present "$REMOTE_HOME/.fm-secondmate-home" "remote provisioning did not publish the identity marker"
assert_present "$REMOTE_HOME/projects/alpha/.git" "remote provisioning did not clone the project on that host"
assert_grep "$REMOTE_HOME/state/parent-replies.status" "$REMOTE_HOME/data/charter.md" "remote charter did not use its append-only reply log"
assert_no_grep "$PARENT/state/ios.status" "$REMOTE_HOME/data/charter.md" "remote charter retained the inaccessible local status path"
if FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$TMP_ROOT/other-home" alpha \
  >/dev/null 2>&1; then
  fail "remote seed allowed an existing id to move to another home"
fi
assert_grep "home: $REMOTE_HOME" "$PARENT/data/secondmates.md" "refused remote reassignment changed the durable route"
pass "remote seed registers the route and provisions the whole home and project clone on that host"

PROTOCOL_HOME="$TMP_ROOT/protocol-home"
mkdir -p "$PROTOCOL_HOME/config" "$PROTOCOL_HOME/data" "$PROTOCOL_HOME/state"
printf 'complete inherited payload\n' > "$TMP_ROOT/inherit-complete"
inherit_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/inherit-complete" | tr -d ' ')
inherit_hash=$(sha256_file "$TMP_ROOT/inherit-complete")
if printf 'complete' | FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_bytes" "$inherit_hash" 1 >/dev/null 2>&1; then
  fail "remote inheritance published a truncated payload"
fi
assert_absent "$PROTOCOL_HOME/config/crew-harness" "truncated inheritance published a destination"
FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_bytes" "$inherit_hash" 2 \
  < "$TMP_ROOT/inherit-complete" >/dev/null
printf 'stale inherited payload\n' > "$TMP_ROOT/inherit-stale"
inherit_stale_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/inherit-stale" | tr -d ' ')
inherit_stale_hash=$(sha256_file "$TMP_ROOT/inherit-stale")
if FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_stale_bytes" "$inherit_stale_hash" 1 \
  < "$TMP_ROOT/inherit-stale" >/dev/null 2>&1; then
  fail "remote inheritance accepted a superseded payload generation"
fi
cmp -s "$TMP_ROOT/inherit-complete" "$PROTOCOL_HOME/config/crew-harness" \
  || fail "superseded inheritance replaced the current payload"
pass "remote inheritance rejects incomplete and superseded payload generations"

# Add one local route to prove mixed fleets remain parseable and projected.
mkdir -p "$LOCAL_HOME/data" "$LOCAL_HOME/state" "$LOCAL_HOME/config" "$LOCAL_HOME/projects" "$LOCAL_HOME/bin"
printf 'local\n' > "$LOCAL_HOME/.fm-secondmate-home"
printf 'fixture\n' > "$LOCAL_HOME/AGENTS.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LOCAL_HOME/data/backlog.md"
cat >> "$PARENT/data/secondmates.md" <<EOF
- local - Local delivery (home: $LOCAL_HOME; scope: local work; projects: alpha; added 2026-08-02)
EOF
remote_env "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "mixed local and remote registry validation failed"
pass "mixed local and remote routes validate without migration"

# Launch on the remote home's own configured backend. Parent metadata records
# host placement separately from that backend and arms the reply source.
printf 'pi\n' > "$PARENT/config/crew-harness"
launches_before_inherit=0
[ ! -f "$HERDR_LOG" ] || launches_before_inherit=$(grep -c '^tab create' "$HERDR_LOG" || true)
if FM_FAKE_SSH_MODE=inherit-partial remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-inherit-partial.out" 2>&1; then
  fail "remote spawn launched after ambiguous partial inheritance"
fi
launches_after_inherit=0
[ ! -f "$HERDR_LOG" ] || launches_after_inherit=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_inherit" -eq "$launches_after_inherit" ] \
  || fail "remote spawn reached launch after ambiguous partial inheritance"
assert_absent "$PARENT/state/ios.meta" "failed remote inheritance published launch metadata"
out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate)
assert_contains "$out" 'remote=remote-mac backend=herdr' "remote spawn did not report separate host and backend dimensions"
assert_grep 'remote_host=remote-mac' "$PARENT/state/ios.meta" "parent metadata omitted the remote host"
assert_grep 'remote_backend=herdr' "$PARENT/state/ios.meta" "parent metadata omitted the remote-local backend"
assert_grep 'remote_herdr_session=fm-remote' "$PARENT/state/ios.meta" "parent metadata omitted the pinned remote Herdr session"
assert_grep 'remote_target=fm-remote:' "$PARENT/state/ios.meta" "parent metadata did not record an fm-remote endpoint"
assert_grep 'herdr_session=fm-remote' "$REMOTE_HOME/state/parent-route/ios.meta" "remote metadata did not record the pinned Herdr session"
assert_grep '--session fm-remote' "$HERDR_LOG" "remote launch did not target the fm-remote session"
assert_no_grep '--session default' "$HERDR_LOG" "remote launch targeted the interactive default session"
assert_grep 'window=remote:ios' "$PARENT/state/ios.meta" "parent metadata pretended the endpoint was local"
assert_present "$PARENT/state/procevent/remote-reply-ios.source" "remote spawn did not arm its reply source"
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$ROOT/bin/fm-watch.sh"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "remote endpoint was not projected alive from its own host"
# Herdr reports a native agent state, so the delivery observation resolves
# without the rendered-output fallback a tmux endpoint needs.
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh observe ios)" = idle ] \
  || fail "remote endpoint delivery observation did not execute on its own host"
pass "remote spawn launches on the remote-local backend and records a host-qualified route"

# A missing durable home marker must not make the liveness read lose a route
# whose host-local endpoint record still binds the exact secondmate id.
markerless_state_backup="$TMP_ROOT/herdr-before-markerless-probe.state"
cp "$HERDR_STATE" "$markerless_state_backup"
rm -f "$REMOTE_HOME/.fm-secondmate-home"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "a markerless remote home was not classified from its live endpoint"
assert_contains "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios)" \
  'backend=herdr' "a markerless live route could not be read without its home marker"
markerless_liveness_before=$(grep -c '^tab create' "$HERDR_LOG" || true)
markerless_liveness_out=$(remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_not_contains "$markerless_liveness_out" 'SECONDMATE_LIVENESS: secondmate ios:' \
  "the liveness sweep treated a live markerless route as a recovery gap"
markerless_liveness_after=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$markerless_liveness_before" -eq "$markerless_liveness_after" ] \
  || fail "the liveness sweep relaunched a live markerless remote endpoint"
set +e
FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios \
  > "$TMP_ROOT/markerless-unreachable.out" 2>&1
markerless_unreachable_rc=$?
set -e
[ "$markerless_unreachable_rc" = 255 ] \
  || fail "an unreachable markerless route was not preserved as unknown (rc=$markerless_unreachable_rc)"
rm -f "$PARENT/state/ios.reconcile-nudged"
set +e
markerless_reconcile_unreachable=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" FM_DATA_OVERRIDE="$PARENT/data" \
  FM_FAKE_SSH_MODE=unreachable "$ROOT/bin/fm-secondmate-reconcile.sh" notify --snapshot "$remote_reconcile_snapshot" 2>&1)
set -e
assert_contains "$markerless_reconcile_unreachable" 'failed: ios orphan_in_flight' "unreachable reconciliation did not remain visible"
reset_remote_herdr_fixture "$HERDR_STATE"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = missing ] \
  || fail "a markerless remote home with no endpoint was not classified missing"
set +e
markerless_dead_out=$(remote_env "$ROOT/bin/fm-bootstrap.sh" 2>&1)
markerless_dead_rc=$?
set -e
assert_contains "$markerless_dead_out" 'respawn failed after remote endpoint missing' \
  "the liveness sweep did not preserve a dead markerless route as a failed recovery"
cp "$markerless_state_backup" "$HERDR_STATE"
remote_root=$(sed -n 's/^remote_root=//p' "$PARENT/state/ios.meta")
remote_reconcile_snapshot="$TMP_ROOT/markerless-reconcile.json"
jq -n --arg id ios --arg host remote-mac --arg root "$remote_root" \
  '{schema:"fm-fleet-snapshot.v1",secondmate_current:{records:[{id:$id,host:$host,remote_root:$root,remote:true,reconcile_inventory:{kind:"orphan_in_flight",ids:["ios"]}}]}}' \
  > "$remote_reconcile_snapshot"
reconcile_out=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" FM_DATA_OVERRIDE="$PARENT/data" \
  "$ROOT/bin/fm-secondmate-reconcile.sh" notify --snapshot "$remote_reconcile_snapshot" 2>&1) || fail "markerless reconciliation notify failed: $reconcile_out"
assert_contains "$reconcile_out" 'sent: ios orphan_in_flight' "markerless remote reconciliation did not deliver"
reconcile_again=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" FM_DATA_OVERRIDE="$PARENT/data" \
  "$ROOT/bin/fm-secondmate-reconcile.sh" notify --snapshot "$remote_reconcile_snapshot" 2>&1) || fail "markerless reconciliation cooldown failed: $reconcile_again"
assert_contains "$reconcile_again" 'cooldown: ios' "markerless reconciliation cooldown did not suppress repeat"
printf '%s\n' ios > "$REMOTE_HOME/.fm-secondmate-home"
pass "markerless remote liveness distinguishes live, unreachable, and missing endpoints without route loss"
if [ "${FM_TEST_MARKERLESS_ONLY:-0}" = 1 ]; then
  echo "ALL TESTS PASSED"
  exit 0
fi

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-default-session.meta"
legacy_pane=$(sed -n 's/^herdr_pane_id=//p' "$remote_route_meta")
awk -v pane="$legacy_pane" '
  /^window=/ { print "window=default:" pane; next }
  /^herdr_session=/ { print "herdr_session=default"; next }
  { print }
' "$TMP_ROOT/remote-ios-before-default-session.meta" > "$remote_route_meta"
cp "$HERDR_LOG" "$TMP_ROOT/herdr-before-default-session.log"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios 2>/dev/null)" = unverified ] \
  || fail "legacy default-session metadata was not classified unverified"
if remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh send ios probe >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh key ios Enter >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh capture ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh observe ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh retire ios --force >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios codex - - herdr - - - >/dev/null 2>&1; then
  fail "legacy default-session metadata remained operational"
fi
cmp -s "$TMP_ROOT/herdr-before-default-session.log" "$HERDR_LOG" \
  || fail "legacy default-session metadata caused a Herdr operation"
assert_present "$REMOTE_HOME" "refused legacy retirement removed the remote home"
assert_grep 'herdr_session=default' "$remote_route_meta" "refused legacy retirement rewrote endpoint metadata"

awk -v pane="$legacy_pane" '
  /^window=/ { print "window=default:" pane; next }
  { print }
' "$TMP_ROOT/remote-ios-before-default-session.meta" > "$remote_route_meta"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios 2>/dev/null)" = unverified ] \
  || fail "mismatched fm-remote target was not classified unverified"
cmp -s "$TMP_ROOT/herdr-before-default-session.log" "$HERDR_LOG" \
  || fail "mismatched fm-remote target caused a Herdr operation"
mv -f "$TMP_ROOT/remote-ios-before-default-session.meta" "$remote_route_meta"
pass "legacy and mismatched remote endpoints fail closed before backend access"

cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-nonherdr.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-nonherdr.md"
set +e
FM_FAKE_SSH_MODE=launch-nonherdr-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-nonherdr-route.out" 2>&1
nonherdr_parent_rc=$?
set -e
[ "$nonherdr_parent_rc" -ne 0 ] || fail "parent accepted a non-herdr remote launch route"
assert_grep "remote launch returned backend 'tmux', expected herdr" "$TMP_ROOT/spawn-nonherdr-route.out" \
  "parent refusal did not name the returned remote backend"
cmp -s "$TMP_ROOT/parent-ios-before-nonherdr.meta" "$PARENT/state/ios.meta" \
  || fail "parent rewrote its endpoint metadata after a non-herdr route refusal"
cmp -s "$TMP_ROOT/registry-before-nonherdr.md" "$PARENT/data/secondmates.md" \
  || fail "parent removed or changed the registry route after a non-herdr route refusal"

set +e
FM_FAKE_SSH_MODE=launch-unverified-harness-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-unverified-harness-route.out" 2>&1
unverified_harness_parent_rc=$?
set -e
[ "$unverified_harness_parent_rc" -ne 0 ] || fail "parent accepted an unverified harness returned by the remote host"
assert_grep 'remote launch returned malformed route metadata' \
  "$TMP_ROOT/spawn-unverified-harness-route.out" \
  "parent did not reject an unverified harness returned by the remote host"
cmp -s "$TMP_ROOT/parent-ios-before-nonherdr.meta" "$PARENT/state/ios.meta" \
  || fail "parent rewrote its endpoint metadata after an unverified returned-harness refusal"

set +e
FM_FAKE_SSH_MODE=launch-default-session-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-default-session-route.out" 2>&1
default_session_parent_rc=$?
set -e
[ "$default_session_parent_rc" -ne 0 ] || fail "parent accepted an interactive default-session remote route"
assert_grep "remote launch returned Herdr session 'default', expected 'fm-remote'" "$TMP_ROOT/spawn-default-session-route.out" \
  "parent refusal did not name the default session"
cmp -s "$TMP_ROOT/parent-ios-before-nonherdr.meta" "$PARENT/state/ios.meta" \
  || fail "parent rewrote its endpoint metadata after a default-session route refusal"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-legacy.meta"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
project=$REMOTE_ROOT
harness=codex
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-legacy-before-refusal.meta"
printf 'fm-ios|%s\n' "$REMOTE_HOME" > "$TMUX_STATE"
set +e
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios codex - - herdr - - - \
  > "$TMP_ROOT/legacy-alive-refusal.out" 2>&1
legacy_alive_rc=$?
set -e
[ "$legacy_alive_rc" -ne 0 ] || fail "remote control reused an alive legacy tmux endpoint"
assert_grep "endpoint is recorded on backend 'tmux', expected 'herdr'" "$TMP_ROOT/legacy-alive-refusal.out" \
  "remote refusal did not name the endpoint's recorded backend"
cmp -s "$TMP_ROOT/remote-ios-legacy-before-refusal.meta" "$remote_route_meta" \
  || fail "remote refusal changed the legacy endpoint metadata"
assert_present "$TMUX_STATE" "remote refusal killed the alive legacy endpoint"
cmp -s "$TMP_ROOT/registry-before-nonherdr.md" "$PARENT/data/secondmates.md" \
  || fail "remote legacy refusal removed or changed the registry route"
mv -f "$TMP_ROOT/remote-ios-before-legacy.meta" "$remote_route_meta"
rm -f "$TMUX_STATE"
pass "non-herdr remote endpoints are refused without changing either route"

rm -f "$TMP_ROOT/inherit.entered" "$TMP_ROOT/inherit.release" "$TMP_ROOT/inherit.payload"
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
stale spawn preference
EOF
FM_FAKE_SSH_MODE=inherit-block remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-concurrent.out" 2>&1 &
spawn_concurrent=$!
spawn_inherit_wait=0
# Earlier inherited files traverse the worker before captain-shared.md, so give
# a loaded portable runner 30 seconds to reach this deliberately blocked write.
while [ ! -f "$TMP_ROOT/inherit.entered" ]; do
  kill -0 "$spawn_concurrent" 2>/dev/null || fail "remote spawn exited before its blocked inheritance write"
  spawn_inherit_wait=$((spawn_inherit_wait + 1))
  [ "$spawn_inherit_wait" -le 1500 ] || fail "remote spawn never reached its blocked inheritance write"
  sleep 0.02
done
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
current post-spawn preference
EOF
remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/spawn-concurrent-push.out" 2>&1 &
spawn_config_push=$!
sleep 0.2
kill -0 "$spawn_config_push" 2>/dev/null \
  || fail "config push bypassed the active remote spawn inheritance transaction"
touch "$TMP_ROOT/inherit.release"
wait "$spawn_concurrent" || fail "serialized remote spawn failed"
wait "$spawn_config_push" || fail "config push failed after serialized remote spawn"$'\n'"$(cat "$TMP_ROOT/spawn-concurrent-push.out")"
[ "$(tail -1 "$REMOTE_HOME/data/captain-shared.md")" = 'current post-spawn preference' ] \
  || fail "stale spawn inheritance overwrote later config convergence"
pass "remote spawn serializes inheritance through launch publication"

# A normal marked parent request traverses SSH, reaches the remote endpoint once,
# and resolves only after the correlated remote log delta is ingested.
ssh_before_send=$(cat "$SSH_COUNT")
set +e
FM_FAKE_SSH_MODE=ambiguous remote_env "$ROOT/bin/fm-send.sh" fm-ios \
  'report the build result' > "$TMP_ROOT/send.out" 2> "$TMP_ROOT/send.err"
send_rc=$?
set -e
[ "$send_rc" -ne 0 ] || fail "ambiguous remote send claimed definite delivery"
assert_grep 'do not resend' "$TMP_ROOT/send.err" "ambiguous remote send did not require same-host reconciliation"
ssh_after_send=$(cat "$SSH_COUNT")
[ "$ssh_after_send" -eq $((ssh_before_send + 1)) ] || fail "ambiguous remote send was retried"
CORR=$(grep -Eo 'corr=[a-f0-9]{16}' "$HERDR_LOG" | tail -1 | cut -d= -f2-)
[ -n "$CORR" ] || fail "remote send did not carry a correlation token"
phase=$(grep '^phase=' "$PARENT/state/pending-replies/$CORR" | cut -d= -f2-)
[ "$phase" = delivery_unknown ] || fail "ambiguous remote send did not preserve its pending expectation"
printf 'done [corr=%s]: remote build passed\n' "$CORR" >> "$REMOTE_HOME/state/parent-replies.status"
SID='remote-reply-ios'
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "remote reply source did not capture the correlated answer"
RESULT="$PARENT/state/procevent-inbox/$SID.1.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 1 "$RESULT" >/dev/null \
  || fail "remote reply ingest failed"
assert_grep "done [corr=$CORR]: remote build passed" "$PARENT/state/ios.status" "correlated remote reply did not reach the parent status channel"
phase=$(grep '^phase=' "$PARENT/state/pending-replies/$CORR" | cut -d= -f2-)
[ "$phase" = resolved ] || fail "correlated remote reply did not resolve the parent expectation"
pass "marked send and routed reply complete through the existing parent correlation owner"
rm -f "$PARENT/state/.wake-queue"

printf '{"revision":2}\n' > "$PARENT/config/crew-dispatch.json"
printf 'grok\n' > "$PARENT/config/crew-harness"
set +e
FM_FAKE_SSH_MODE=inherit-partial remote_env "$ROOT/bin/fm-config-push.sh" \
  > "$TMP_ROOT/config-partial.out" 2>&1
config_partial_rc=$?
set -e
[ "$config_partial_rc" -ne 0 ] || fail "partial remote inheritance claimed complete convergence"
assert_grep '"revision":2' "$REMOTE_HOME/config/crew-dispatch.json" "partial inheritance did not apply its first file"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" != grok ] \
  || fail "partial inheritance unexpectedly applied the failed file"
NUDGE_MARKER="$PARENT/state/.secondmate-nudge-pending/ios.pending"
assert_grep 'remote=1' "$NUDGE_MARKER" "partial inheritance left no durable remote reread marker"
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"
remote_env "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/config-partial-retry.out" \
  || fail "bootstrap did not converge partial remote inheritance"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" = grok ] \
  || fail "bootstrap did not apply the remaining inherited file"
assert_absent "$NUDGE_MARKER" "bootstrap cleared no remote reread marker after convergence"
PARTIAL_CONFIG_CORR=$(grep -Eo 'corr=[a-f0-9]{16}' "$HERDR_LOG" | tail -1 | cut -d= -f2-)
[ -n "$PARTIAL_CONFIG_CORR" ] || fail "bootstrap config reread did not carry a correlation token"
printf 'done [corr=%s]: converged inherited config re-read\n' "$PARTIAL_CONFIG_CORR" >> "$REMOTE_HOME/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "remote reply source did not capture the converged config acknowledgment"
PARTIAL_CONFIG_RESULT="$PARENT/state/procevent-inbox/$SID.2.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 2 "$PARTIAL_CONFIG_RESULT" >/dev/null \
  || fail "converged remote config acknowledgment was not ingested"
pass "partial remote inheritance retains reread intent through bootstrap convergence"

rm -f "$TMP_ROOT/inherit.entered" "$TMP_ROOT/inherit.release" "$TMP_ROOT/inherit.payload"
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
stale concurrent preference
EOF
FM_FAKE_SSH_MODE=inherit-block remote_env "$ROOT/bin/fm-config-push.sh" \
  > "$TMP_ROOT/config-concurrent-first.out" 2>&1 &
config_first=$!
inherit_wait=0
while [ ! -f "$TMP_ROOT/inherit.entered" ]; do
  kill -0 "$config_first" 2>/dev/null || fail "first inheritance transaction exited before its blocked write"
  inherit_wait=$((inherit_wait + 1))
  # Match the earlier spawn/inheritance wait: a loaded portable runner can
  # spend several seconds in the remote entrypoint before reaching this write.
  [ "$inherit_wait" -le 1500 ] || fail "first inheritance transaction never reached its blocked write"
  sleep 0.02
done
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
current concurrent preference
EOF
remote_env "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/config-concurrent-second.out" 2>&1 &
config_second=$!
sleep 0.2
kill -0 "$config_second" 2>/dev/null \
  || fail "bootstrap bypassed the active remote inheritance transaction"
touch "$TMP_ROOT/inherit.release"
wait "$config_first" || fail "first serialized inheritance transaction failed"
wait "$config_second" || fail "bootstrap inheritance transaction failed after waiting"
[ "$(tail -1 "$REMOTE_HOME/data/captain-shared.md")" = 'current concurrent preference' ] \
  || fail "later bootstrap convergence was overwritten by stale inherited bytes"
pass "config push and bootstrap serialize remote inheritance convergence"

printf 'codex\n' > "$PARENT/config/crew-harness"
touch "$TMP_ROOT/herdr-send-fail"
if remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/config-push-fail.out" 2>&1; then
  fail "remote config push claimed success after its reread send failed"
fi
if [ ! -f "$NUDGE_MARKER" ]; then
  printf 'config push failure output:\n%s\n' "$(cat "$TMP_ROOT/config-push-fail.out")" >&2
  fail "failed remote config reread did not retain a retry marker"
fi
assert_grep 'remote=1' "$NUDGE_MARKER" "remote config reread marker lost its placement"
rm -f "$TMP_ROOT/herdr-send-fail"
remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/config-push-retry.out" \
  || fail "unchanged remote config push did not retry its pending reread"
assert_absent "$NUDGE_MARKER" "successful remote config reread left its retry marker"
assert_grep 'config-reread: sent' "$TMP_ROOT/config-push-retry.out" "remote config reread retry was not reported"
CONFIG_CORR=$(grep -Eo 'corr=[a-f0-9]{16}' "$HERDR_LOG" | tail -1 | cut -d= -f2-)
[ -n "$CONFIG_CORR" ] || fail "remote config reread did not carry a correlation token"
printf 'done [corr=%s]: inherited config re-read\n' "$CONFIG_CORR" >> "$REMOTE_HOME/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "remote reply source did not capture the config reread acknowledgement"
CONFIG_RESULT="$PARENT/state/procevent-inbox/$SID.3.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 3 "$CONFIG_RESULT" >/dev/null \
  || fail "remote config reread acknowledgement was not ingested"
pass "remote inherited config retains and retries a failed live reread nudge"

resolve_ios_pending() {
  local pending_record pending_corr pending_result pending_seq
  for pending_record in "$PARENT/state/pending-replies"/*; do
    [ -f "$pending_record" ] || continue
    [ "$(grep '^task_id=' "$pending_record" | cut -d= -f2-)" = ios ] || continue
    [ "$(grep '^phase=' "$pending_record" | cut -d= -f2-)" != resolved ] || continue
    pending_corr=$(basename "$pending_record")
    printf 'done [corr=%s]: concurrent inherited data re-read\n' "$pending_corr" \
      >> "$REMOTE_HOME/state/parent-replies.status"
    remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
      || fail "remote reply source did not capture a concurrent inheritance acknowledgment"
    pending_result=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" -print | sort | tail -1)
    pending_seq=${pending_result%.result}
    pending_seq=${pending_seq##*.}
    remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios "$pending_seq" "$pending_result" >/dev/null \
      || fail "concurrent inheritance acknowledgment was not ingested"
  done
}
resolve_ios_pending

# Structured fleet state comes from each home's own snapshot. The remote host is
# explicit, and the local route remains alongside it.
SNAPSHOT=$(remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
if ! printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "ios" and .remote == true and .host == "remote-mac" and .provenance.selected == "structured-home")' >/dev/null; then
  printf 'secondmate projection:\n%s\n' "$(printf '%s' "$SNAPSHOT" | jq '.secondmate_current')" >&2
  fail "fleet snapshot did not select the remote structured-home projection"
fi
printf '%s' "$SNAPSHOT" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == true' >/dev/null \
  || fail "remote structured observation did not prove the remote home present"
printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "local" and .remote == false)' >/dev/null \
  || fail "fleet snapshot lost the existing local secondmate route"
pass "fleet snapshot projects mixed local and remote structured state"
rm -f "$PARENT/state/.wake-queue"

# The remote code root updates independently, then the persistent home imports
# and fast-forwards to that host-local commit without touching project clones.
REMOTE_SEED="$TMP_ROOT/firstmate-seed"
git clone -q "file://$REMOTE_ORIGIN" "$REMOTE_SEED"
git -C "$REMOTE_SEED" config user.email test@example.com
git -C "$REMOTE_SEED" config user.name Test
printf 'remote update probe\n' > "$REMOTE_SEED/REMOTE_UPDATE_PROBE"
git -C "$REMOTE_SEED" add REMOTE_UPDATE_PROBE
git -C "$REMOTE_SEED" commit -qm 'advance remote code root'
git -C "$REMOTE_SEED" push -q origin main
UPDATE_OUT=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh update ios)
assert_contains "$UPDATE_OUT" 'synced:' "remote update did not report a host-local fast-forward"
[ "$(git -C "$REMOTE_HOME" rev-parse HEAD)" = "$(git -C "$REMOTE_ROOT" rev-parse HEAD)" ] \
  || fail "remote persistent home did not fast-forward to its code-root commit"
assert_present "$REMOTE_HOME/REMOTE_UPDATE_PROBE" "remote update did not materialize the code-root commit"
pass "remote update imports and fast-forwards the persistent home on its configured host"

rm -f "$TMP_ROOT/doctor.repaired"
: > "$DOCTOR_LOG"
[ "$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = unreadable ] \
  || fail "the stopped-server fixture did not make the pre-repair endpoint probe unreadable"
launches_before_repair=$(grep -c '^tab create' "$HERDR_LOG" || true)
BOOT_REPAIRED=$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-bootstrap.sh")
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable -
doctor-fixable --fix
doctor-fixable -' ] || fail "liveness did not check, repair, and re-check readiness before probing"$'\n'"$(cat "$DOCTOR_LOG")"
assert_not_contains "$BOOT_REPAIRED" 'SECONDMATE_LIVENESS: secondmate ios:' \
  "successful pre-probe readiness repair produced a liveness failure"
launches_after_repair=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_repair" -eq "$launches_after_repair" ] \
  || fail "readiness repair introduced a new remote relaunch point"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the endpoint was not probed successfully after readiness repair"
pass "startup repairs remote readiness before probing without relaunching"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-liveness-legacy.meta"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-liveness-legacy.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-liveness-legacy.md"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
project=$REMOTE_ROOT
harness=codex
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-liveness-legacy.meta"
printf 'fm-ios|%s\n' "$REMOTE_HOME" > "$TMUX_STATE"
tmux_state_before=$(cat "$TMUX_STATE")
launches_before_legacy=$(grep -c '^tab create' "$HERDR_LOG" || true)
BOOT_LEGACY=$(remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_LEGACY" "SECONDMATE_LIVENESS: secondmate ios: skipped: remote endpoint state is unverified on remote-mac" \
  "liveness accepted an alive legacy remote backend"
cmp -s "$TMP_ROOT/remote-ios-liveness-legacy.meta" "$remote_route_meta" \
  || fail "liveness rewrote the alive legacy endpoint metadata"
cmp -s "$TMP_ROOT/parent-ios-before-liveness-legacy.meta" "$PARENT/state/ios.meta" \
  || fail "liveness rewrote the parent route metadata for an alive legacy endpoint"
cmp -s "$TMP_ROOT/registry-before-liveness-legacy.md" "$PARENT/data/secondmates.md" \
  || fail "liveness changed the registry route for an alive legacy endpoint"
[ "$(cat "$TMUX_STATE")" = "$tmux_state_before" ] \
  || fail "liveness changed or killed the alive legacy endpoint"
launches_after_legacy=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before_legacy" -eq "$launches_after_legacy" ] \
  || fail "liveness relaunched an alive legacy endpoint"
mv -f "$TMP_ROOT/remote-ios-before-liveness-legacy.meta" "$remote_route_meta"
rm -f "$TMUX_STATE"
pass "startup reports alive legacy backends without changing their routes"

# Host loss maps to unknown/unavailable and never creates a local replacement.
launches_before=$(grep -c '^tab create' "$HERDR_LOG" || true)
rm -rf -- "$PARENT/state/.watch.lock"
rm -f -- "$PARENT/state/.last-watcher-beat"
BOOT_UNAVAILABLE=$(FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_UNAVAILABLE" 'SECONDMATE_LIVENESS: secondmate ios: skipped: remote host unavailable or endpoint state unknown' \
  "bootstrap did not preserve an unreachable remote endpoint as unknown"
UNAVAILABLE=$(FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
printf '%s' "$UNAVAILABLE" | jq -e '.secondmate_current.records | any(.id == "ios" and .current.state == "unknown")' >/dev/null \
  || fail "unreachable remote host was not projected unknown"
printf '%s' "$UNAVAILABLE" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == null' >/dev/null \
  || fail "unreachable remote home presence was not projected unknown"
rm -f "$PARENT/state/.wake-queue"
launches_after=$(grep -c '^tab create' "$HERDR_LOG" || true)
[ "$launches_before" -eq "$launches_after" ] || fail "unreachable projection attempted a replacement launch"
assert_present "$PARENT/state/ios.meta" "unreachable readiness removed the parent route metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "unreachable readiness removed the registry route"
pass "unreachable remote state remains unknown with no local respawn or failover"

# Retirement delegates its safety check to the remote home. An in-flight child
# record refuses cleanup and preserves both machines' durable routes.
# A sibling remote secondmate workspace shares fm-remote and must survive every
# refusal and the eventual successful retirement of ios.
# This fixture overrides FM_ROOT for transport, so teardown's root-owned guard
# sees the fixture root rather than the source script path used by fm-send.
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"
resolve_ios_pending
SIBLING_CREATE=$("$REMOTE_ROOT/bin/herdr" workspace create --cwd "$REMOTE_ROOT" \
  --label 2ndmate-macos --no-focus --session fm-remote)
SIBLING_WORKSPACE=$(printf '%s' "$SIBLING_CREATE" | jq -r '.result.workspace.workspace_id')
SIBLING_PANE=$(printf '%s' "$SIBLING_CREATE" | jq -r '.result.root_pane.pane_id')
[ -n "$SIBLING_WORKSPACE" ] && [ "$SIBLING_WORKSPACE" != null ] \
  || fail "the shared-session sibling fixture did not create a workspace"
[ -n "$SIBLING_PANE" ] && [ "$SIBLING_PANE" != null ] \
  || fail "the shared-session sibling fixture did not create a pane"
printf 'kind=ship\n' > "$REMOTE_HOME/state/child.meta"
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement ignored in-flight child work"
fi
assert_present "$REMOTE_HOME" "refused remote retirement removed the home"
assert_present "$PARENT/state/ios.meta" "refused remote retirement removed parent metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "refused remote retirement removed the route"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
remote_env "$ROOT/bin/fm-bootstrap.sh" >/dev/null \
  || fail "bootstrap failed while repairing a preserved remote reply source"
assert_present "$PARENT/state/procevent/remote-reply-ios.source" \
  "bootstrap did not repair reply registration after retirement rollback"
resolve_ios_pending
rm -f "$REMOTE_HOME/state/child.meta"
mkdir -p "$PARENT/data/handoff"
ln -s "$TMP_ROOT/missing-outbox-target" "$PARENT/data/handoff/ios.outbox.md"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement accepted an unsafe backlog outbox"
fi
assert_present "$REMOTE_HOME" "unsafe backlog outbox retirement removed the remote home"
rm -f "$PARENT/data/handoff/ios.outbox.md"
mkdir -p "$TMP_ROOT/external-pending"
printf 'task_id=ios\nphase=resolved\n' > "$TMP_ROOT/external-pending/escape"
mv "$PARENT/state/pending-replies" "$PARENT/state/pending-replies.safe"
ln -s "$TMP_ROOT/external-pending" "$PARENT/state/pending-replies"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement accepted a symlinked pending-replies directory"
fi
assert_present "$REMOTE_HOME" "unsafe pending-replies retirement removed the remote home"
assert_present "$TMP_ROOT/external-pending/escape" "unsafe retirement removed an external pending reply"
rm -f "$PARENT/state/pending-replies"
mv "$PARENT/state/pending-replies.safe" "$PARENT/state/pending-replies"
handoff_lock="$PARENT/state/.backlog-handoff-ios.lock"
FM_HOME="$PARENT" /bin/bash -c '
  . "$1"
  fm_lock_acquire_wait "$2"
  touch "$3"
  while [ ! -f "$4" ]; do sleep 0.02; done
  fm_lock_release "$2"
' _ "$ROOT/bin/fm-wake-lib.sh" "$handoff_lock" "$TMP_ROOT/handoff.entered" \
  "$TMP_ROOT/handoff.release" &
handoff_holder_pid=$!
handoff_wait=0
while [ ! -f "$TMP_ROOT/handoff.entered" ]; do
  kill -0 "$handoff_holder_pid" 2>/dev/null || fail "handoff lock holder exited before acquiring the route lock"
  handoff_wait=$((handoff_wait + 1))
  [ "$handoff_wait" -le 250 ] || fail "handoff lock holder never acquired the route lock"
  sleep 0.02
done
rm -f "$TMUX_STATE" "$TMP_ROOT/launch.entered" "$TMP_ROOT/launch.release"
FM_FAKE_SSH_MODE=launch-block remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-retirement.out" 2>&1 &
spawn_retirement_pid=$!
launch_wait=0
# The respawn performs readiness and inheritance jobs before launch, so allow
# the same 30-second loaded-runner bound as the earlier blocked worker path.
while [ ! -f "$TMP_ROOT/launch.entered" ]; do
  kill -0 "$spawn_retirement_pid" 2>/dev/null || fail "remote respawn exited before its blocked launch"
  launch_wait=$((launch_wait + 1))
  [ "$launch_wait" -le 1500 ] || fail "remote respawn never reached its blocked launch"
  sleep 0.02
done
remote_env "$ROOT/bin/fm-teardown.sh" ios > "$TMP_ROOT/teardown-serialized.out" 2>&1 &
teardown_pid=$!
sleep 0.2
kill -0 "$teardown_pid" 2>/dev/null || fail "remote retirement bypassed an active remote respawn"
assert_present "$REMOTE_HOME" "remote retirement removed the home during an active remote respawn"
touch "$TMP_ROOT/launch.release"
if ! wait "$spawn_retirement_pid"; then
  printf 'serialized respawn output:\n%s\n' "$(cat "$TMP_ROOT/spawn-retirement.out")" >&2
  fail "serialized remote respawn failed"
fi
sleep 0.2
kill -0 "$teardown_pid" 2>/dev/null || fail "remote retirement bypassed an active backlog handoff"
touch "$TMP_ROOT/handoff.release"
wait "$handoff_holder_pid" || fail "handoff lock holder failed to release"
if ! wait "$teardown_pid"; then
  printf 'serialized retirement output:\n%s\n' "$(cat "$TMP_ROOT/teardown-serialized.out")" >&2
  fail "safe remote retirement failed after handoff serialization"
fi
assert_absent "$REMOTE_HOME" "remote retirement did not remove the remote home"
assert_absent "$PARENT/state/ios.meta" "remote retirement did not remove parent metadata"
assert_no_grep '- ios ' "$PARENT/data/secondmates.md" "remote retirement did not remove the registry route"
jq -e --arg workspace "$SIBLING_WORKSPACE" --arg pane "$SIBLING_PANE" '
  any(.workspaces[]; .workspace_id == $workspace and .label == "2ndmate-macos")
  and any(.tabs[]; .workspace_id == $workspace and .pane_id == $pane)
' "$HERDR_STATE" >/dev/null \
  || fail "remote retirement removed the sibling secondmate workspace or pane from fm-remote"
assert_no_grep 'session stop' "$HERDR_LOG" "remote retirement stopped the shared fm-remote session"
assert_no_grep 'server stop' "$HERDR_LOG" "remote retirement stopped the shared fm-remote server"
pass "remote retirement refuses child work, then removes only its own endpoint while a shared-session sibling survives"

# The parent and remote host both accept OMP as an agent harness while keeping
# the raw-command and remote-Prewalk refusals intact. The optional fallback is
# accepted independently, then a second route drives the real OMP launch across
# the encoded SSH/job boundary into the remote Herdr pane and back into parent
# metadata.
FALLBACK_REMOTE_HOME="$TMP_ROOT/remote-fallback-omp-home"
printf 'claude opus medium\n' > "$PARENT/config/secondmate-harness"
printf 'omp test/model low\n' > "$PARENT/config/secondmate-harness-fallback"
FM_SECONDMATE_CHARTER='Exercise an OMP remote fallback configuration.' \
  FM_SECONDMATE_SCOPE='remote fallback validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" fallback-omp remote-mac "$REMOTE_ROOT" \
  "$FALLBACK_REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote OMP fallback route seeding failed"
remote_env "$ROOT/bin/fm-spawn.sh" fallback-omp --secondmate >/dev/null 2>&1 \
  || fail "remote spawn rejected OMP as the verified fallback harness"
assert_grep 'harness=claude' "$PARENT/state/fallback-omp.meta" \
  "fresh primary quota unexpectedly selected the OMP fallback"
assert_grep 'secondmate_model_source=primary' "$PARENT/state/fallback-omp.meta" \
  "accepted OMP fallback configuration lost the remote primary selection record"

OMP_REMOTE_HOME="$TMP_ROOT/remote-omp-home"
printf 'omp test/model low\n' > "$PARENT/config/secondmate-harness"
rm -f "$PARENT/config/secondmate-harness-fallback"
FM_SECONDMATE_CHARTER='Exercise the remote OMP agent launch.' \
  FM_SECONDMATE_SCOPE='remote OMP launch validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" remote-omp remote-mac "$REMOTE_ROOT" \
  "$OMP_REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote OMP route seeding failed"
if remote_env "$ROOT/bin/fm-spawn.sh" remote-omp --secondmate --harness 'raw-agent --flag' \
  > "$TMP_ROOT/remote-omp-raw.out" 2>&1; then
  fail "remote secondmate accepted a raw launch command after OMP was allowlisted"
fi
assert_grep 'requires a verified harness adapter, not a raw launch command' \
  "$TMP_ROOT/remote-omp-raw.out" "remote raw-command refusal weakened while allowlisting OMP"
if remote_env "$ROOT/bin/fm-spawn.sh" remote-omp --secondmate --harness omp \
  --prewalk-into test/model > "$TMP_ROOT/remote-omp-prewalk.out" 2>&1; then
  fail "remote secondmate accepted a Prewalk target that its control protocol cannot carry"
fi
assert_grep 'remote control protocol does not carry a Prewalk target' \
  "$TMP_ROOT/remote-omp-prewalk.out" "remote Prewalk refusal does not name its protocol boundary"
: > "$HERDR_LOG"
remote_env "$ROOT/bin/fm-spawn.sh" remote-omp --secondmate >/dev/null 2>&1 \
  || fail "verified remote OMP secondmate launch failed"
assert_grep 'harness=omp' "$PARENT/state/remote-omp.meta" \
  "parent metadata rejected the OMP harness returned by the remote launch"
assert_grep 'harness=omp' "$OMP_REMOTE_HOME/state/parent-route/remote-omp.meta" \
  "remote endpoint metadata did not preserve its OMP harness"
OMP_REMOTE_LAUNCH=$(grep -F 'FM_OMP_SESSION_POINTER=' "$HERDR_LOG" | tail -1 || true)
assert_contains "$OMP_REMOTE_LAUNCH" \
  "FM_OMP_BUN='\\''$REMOTE_OMP_BUN'\\'' FM_OMP_BIN='\\''$REMOTE_OMP_BIN'\\''" \
  "remote OMP pane did not receive the canonical runtime and entrypoint identities"
assert_contains "$OMP_REMOTE_LAUNCH" "/bin/bash -c" \
  "remote OMP pane did not keep PATH validation inside its Bash-owned command wrapper"
assert_contains "$OMP_REMOTE_LAUNCH" "PATH='\\''$REMOTE_ROOT/bin:" \
  "remote OMP pane did not put the canonical Bun directory first in PATH"
# shellcheck disable=SC2016 # The literal expansion must never reach the pane shell.
assert_not_contains "$OMP_REMOTE_LAUNCH" '${PATH:+' \
  "remote OMP pane exposed POSIX parameter expansion to the pane shell"
assert_contains "$OMP_REMOTE_LAUNCH" \
  "FM_OMP_HARNESS=omp '\\''$REMOTE_OMP_BIN'\\''" \
  "remote OMP pane did not execute the canonical entrypoint directly"
assert_contains "$OMP_REMOTE_LAUNCH" "--session-dir '\\''$OMP_REMOTE_HOME/state/omp-sessions'\\''" \
  "remote OMP pane did not receive its home-owned durable session directory"
assert_contains "$OMP_REMOTE_LAUNCH" \
  "FM_OMP_TASK_INBOX_DIR='\\''$OMP_REMOTE_HOME/state/parent-route/remote-omp.inbox'\\''" \
  "remote OMP extension did not receive its parent-route canonical inbox"
assert_contains "$OMP_REMOTE_LAUNCH" \
  "FM_OMP_TASK_DOORBELL_READY='\\''$OMP_REMOTE_HOME/state/parent-route/remote-omp.omp-doorbell-ready'\\''" \
  "remote OMP extension did not receive its parent-route doorbell readiness marker"
assert_contains "$OMP_REMOTE_LAUNCH" \
  "FM_OMP_TASK_TURN_STARTED='\\''$OMP_REMOTE_HOME/state/parent-route/remote-omp.omp-started'\\''" \
  "remote OMP extension did not receive its parent-route turn-start marker"

# Reproduce the old explicit-pane transport with a real task-bound OMP listener
cat > "$REMOTE_ROOT/bin/omp" <<'JS'
import { appendFileSync, existsSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { installTaskInboxDoorbell } =
  await import(pathToFileURL(process.env.FM_TEST_OMP_HELPER).href);
const doorbell = installTaskInboxDoorbell(
  {
    sendMessage(message, options) {
      appendFileSync(process.env.FM_TEST_OMP_SENT, `${JSON.stringify({ message, options })}\n`);
      writeFileSync(process.env.FM_TEST_OMP_TURN_STARTED, `${process.pid}\n`);
      if (!existsSync(process.env.FM_TEST_OMP_SKIP_HANDLED)) {
        const record = readdirSync(process.env.FM_TEST_OMP_INBOX)
          .filter((name) => name.endsWith(".msg"))
          .sort()[0];
        if (record) renameSync(
          `${process.env.FM_TEST_OMP_INBOX}/${record}`,
          `${process.env.FM_TEST_OMP_INBOX}/handled/${record}`,
        );
      }
    },
  },
  {
    inboxDir: process.env.FM_TEST_OMP_INBOX,
    readyMarker: process.env.FM_TEST_OMP_READY,
  },
);
doorbell.activate();
writeFileSync(process.env.FM_TEST_OMP_PID, `${process.pid}\n`);
const retire = () => {
  doorbell.retire();
  process.exit(0);
};
process.on("SIGTERM", retire);
process.on("SIGINT", retire);
setInterval(() => {}, 1_000);
JS
chmod +x "$REMOTE_ROOT/bin/omp"
OMP_CONTROL_STATE="$OMP_REMOTE_HOME/state/parent-route"
OMP_READY="$OMP_CONTROL_STATE/remote-omp.omp-doorbell-ready"
OMP_INBOX="$OMP_CONTROL_STATE/remote-omp.inbox"
OMP_TURN_STARTED="$OMP_CONTROL_STATE/remote-omp.omp-started"
OMP_SENT="$TMP_ROOT/remote-omp-send-message.log"
OMP_SKIP_HANDLED="$TMP_ROOT/remote-omp-skip-handled"
rm -f "$OMP_READY" "$OMP_TURN_STARTED" "$OMP_ACTIVE_PID" "$OMP_SENT" "$OMP_SKIP_HANDLED"
FM_TEST_OMP_HELPER="$REMOTE_ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" \
  FM_TEST_OMP_SENT="$OMP_SENT" FM_TEST_OMP_TURN_STARTED="$OMP_TURN_STARTED" \
  FM_TEST_OMP_INBOX="$OMP_INBOX" FM_TEST_OMP_READY="$OMP_READY" \
  FM_TEST_OMP_PID="$OMP_ACTIVE_PID" FM_TEST_OMP_SKIP_HANDLED="$OMP_SKIP_HANDLED" \
  bash -c 'exec -a bun "$1" "$2"' _ \
    "$REMOTE_ROOT/bin/bun" "$REMOTE_ROOT/bin/omp" \
  > "$TMP_ROOT/remote-omp-listener.out" 2>&1 &
OMP_LISTENER_PID=$!
listener_wait=0
while [ ! -s "$OMP_READY" ] || [ ! -s "$OMP_ACTIVE_PID" ]; do
  kill -0 "$OMP_LISTENER_PID" 2>/dev/null \
    || fail "remote OMP listener exited before publishing its task-bound readiness"
  listener_wait=$((listener_wait + 1))
  [ "$listener_wait" -le 250 ] || fail "remote OMP listener never published task-bound readiness"
  sleep 0.02
done
OMP_PROCESS=$(ps -o comm= -o args= -p "$OMP_LISTENER_PID")
assert_contains "$OMP_PROCESS" "bun $REMOTE_OMP_BIN" \
  "remote OMP listener did not retain the exact Bun-plus-entrypoint process shape"
PATH="$REMOTE_ROOT/bin:$PATH" FM_OMP_PROCESS_EXPECTED_BUN="$REMOTE_OMP_BUN" \
  FM_OMP_PROCESS_EXPECTED_BIN="$REMOTE_OMP_BIN" /bin/bash -c '
    . "$1/bin/fm-omp-process-lib.sh"
    comm=$(ps -p "$2" -o comm=)
    args=$(ps -p "$2" -o args=)
    fm_omp_process_matches "$comm" "$args" "$2"
  ' _ "$REMOTE_ROOT" "$OMP_LISTENER_PID" \
  || fail "remote OMP listener process did not satisfy the exact delivery identity:"$'\n'"$OMP_PROCESS"
OMP_VERSION=$(bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_primary_watch_version "$2/.omp/extensions/fm-primary-omp.ts" "$2"' \
  _ "$REMOTE_ROOT" "$OMP_REMOTE_HOME") \
  || fail "could not derive the remote OMP primary extension version"
printf '%s\n%s\n%s\n%s\n' "$OMP_VERSION" "$OMP_LISTENER_PID" "$REMOTE_OMP_BUN" "$REMOTE_OMP_BIN" \
  > "$OMP_REMOTE_HOME/state/.omp-primary-extension-loaded"
OMP_TARGET=$(FM_ROOT_OVERRIDE="$REMOTE_ROOT" /bin/bash -c \
  '. "$1/bin/fm-backend.sh"; fm_backend_target_of_meta "$2"' _ "$REMOTE_ROOT" \
  "$OMP_CONTROL_STATE/remote-omp.meta") \
  || fail "could not recover the legacy explicit remote OMP target"
OMP_PANE=$(sed -n 's/^herdr_pane_id=//p' "$OMP_CONTROL_STATE/remote-omp.meta")
[ -n "$OMP_PANE" ] || fail "remote OMP endpoint metadata omitted its Herdr pane identity"
"$REMOTE_ROOT/bin/herdr" agent get "$OMP_PANE" >/dev/null
rm -f "$OMP_ACTIVE_PID"
touch "$HERDR_FORCE_IDLE"
: > "$HERDR_LOG"
set +e
FM_HOME="$OMP_REMOTE_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_STATE_OVERRIDE="$OMP_CONTROL_STATE" \
  FM_SEND_SETTLE=0 FM_SEND_TURNSTART_TIMEOUT=0.1 FM_SEND_TURNSTART_POLL=0.02 \
  PATH="$REMOTE_ROOT/bin:$PATH" "$REMOTE_ROOT/bin/fm-send.sh" "$OMP_TARGET" \
  "legacy explicit remote OMP steer" > "$TMP_ROOT/remote-omp-legacy.out" 2>&1
legacy_rc=$?
set -e
[ "$legacy_rc" = 4 ] || fail "legacy explicit OMP text did not expose its missing turn start (rc=$legacy_rc):"$'\n'"$(cat "$TMP_ROOT/remote-omp-legacy.out")"
assert_grep 'pane send-text' "$HERDR_LOG" \
  "legacy explicit OMP transport did not type the request into the remote pane"
case "$(cat "$HERDR_LOG")" in
  *' Enter'*|*' enter'*) ;;
  *) fail "legacy explicit OMP transport did not submit Enter to the remote pane" ;;
esac
printf '%s\n' "$OMP_LISTENER_PID" > "$OMP_ACTIVE_PID"

# A parent correlation prefixes ordinary relay text, so prove it cannot cause
# /exit to fall through into the remote OMP inbox plane.
: > "$HERDR_LOG"
: > "$OMP_TYPED_INPUT"
remote_env "$ROOT/bin/fm-send.sh" fm-remote-omp /exit \
  > "$TMP_ROOT/remote-omp-exit.out" 2>&1 || true
assert_grep 'pane send-text' "$HERDR_LOG" \
  "remote OMP /exit stopped using the typed lifecycle path"
[ "$(cat "$OMP_TYPED_INPUT")" = /exit ] \
  || fail "remote OMP /exit was not typed as the exact harness command: $(cat "$OMP_TYPED_INPUT")"
[ ! -e "$OMP_INBOX/001.msg" ] \
  || fail "remote OMP /exit was converted into an ordinary inbox instruction"

# The repaired route sends no payload to the pane. It binds the listener,
# enqueues exactly once, programmatically triggers its turn, and leaves the
# worker's durable handled move as the acknowledgement.
: > "$HERDR_LOG"
: > "$OMP_SENT"
remote_env "$ROOT/bin/fm-send.sh" fm-remote-omp "ordinary remote OMP steer" \
  > "$TMP_ROOT/remote-omp-delivery.out" 2>&1 \
  || fail "bound remote OMP inbox delivery failed:"$'\n'"$(cat "$TMP_ROOT/remote-omp-delivery.out")"$'\n'"listener:"$'\n'"$(cat "$TMP_ROOT/remote-omp-listener.out")"$'\n'"programmatic sends:"$'\n'"$(cat "$OMP_SENT" 2>/dev/null)"
OMP_RECORD="$OMP_INBOX/handled/001.msg"
[ -f "$OMP_RECORD" ] || fail "bound remote OMP delivery did not durably acknowledge its canonical inbox record"
OMP_BODY=$(FM_ROOT_OVERRIDE="$REMOTE_ROOT" /bin/bash -c \
  '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_body "$2"' _ "$REMOTE_ROOT" "$OMP_RECORD")
assert_contains "$OMP_BODY" "ordinary remote OMP steer" \
  "bound remote OMP delivery did not preserve the payload in the canonical inbox"
assert_grep '"deliverAs":"steer","triggerTurn":true' "$OMP_SENT" \
  "bound remote OMP delivery did not use programmatic triggerTurn"
assert_no_grep 'pane send-text' "$HERDR_LOG" \
  "bound remote OMP delivery typed payload or doorbell into the remote composer"
assert_no_grep 'pane send-keys' "$HERDR_LOG" \
  "bound remote OMP delivery used Enter as a transport or receipt"
[ -f "$OMP_TURN_STARTED" ] || fail "bound remote OMP delivery did not publish its task-bound turn start"
[ -f "$OMP_INBOX/handled/001.msg" ] || fail "bound remote OMP inbox request lacked the durable handled acknowledgement"

BAD_EXIT="[fm-from-firstmate]"$'\xE2\x81\xA3'"/exit"
set +e
remote_env "$ROOT/bin/fm-on.sh" remote-omp fm-remote-secondmate-control.sh send remote-omp "$BAD_EXIT" \
  > "$TMP_ROOT/remote-omp-bad-exit.out" 2>&1
bad_exit_rc=$?
set -e
[ "$bad_exit_rc" = 9 ] || fail "uncorrelated remote OMP slash carrier was not refused (rc=$bad_exit_rc)"
assert_grep 'canonical parent correlation' "$TMP_ROOT/remote-omp-bad-exit.out" \
  "uncorrelated remote OMP slash carrier did not report its named refusal"

rm -f "$OMP_READY"
set +e
remote_env "$ROOT/bin/fm-send.sh" fm-remote-omp "extension unavailable" \
  > "$TMP_ROOT/remote-omp-unavailable.out" 2>&1
unavailable_rc=$?
set -e
[ "$unavailable_rc" = 9 ] || fail "inactive remote OMP extension did not return its named refusal (rc=$unavailable_rc)"
assert_grep 'remote-omp-binding-refused' "$TMP_ROOT/remote-omp-unavailable.out" \
  "inactive remote OMP extension did not report its named refusal"
[ ! -e "$OMP_INBOX/002.msg" ] || fail "inactive remote OMP extension enqueued a request after refusing delivery"
assert_no_grep 'pane send-text' "$HERDR_LOG" "inactive remote OMP extension touched the composer"
printf '%s\n' "$OMP_LISTENER_PID" > "$OMP_READY"

touch "$OMP_SKIP_HANDLED"
set +e
remote_env "$ROOT/bin/fm-send.sh" fm-remote-omp "acknowledgement timeout" \
  > "$TMP_ROOT/remote-omp-timeout.out" 2>&1
timeout_rc=$?
set -e
[ "$timeout_rc" = 8 ] || fail "remote OMP acknowledgement timeout did not retain a named queue verdict (rc=$timeout_rc)"
assert_grep 'did not durably acknowledge' "$TMP_ROOT/remote-omp-timeout.out" \
  "remote OMP acknowledgement timeout did not name the missing receipt"
[ -f "$OMP_INBOX/002.msg" ] || fail "remote OMP acknowledgement timeout lost its durable request"
sent_before_retry=$(wc -l < "$OMP_SENT")
set +e
remote_env "$ROOT/bin/fm-on.sh" remote-omp fm-remote-secondmate-control.sh send remote-omp \
  "[fm-from-firstmate]"$'\xE2\x81\xA3'"corr=0123456789abcdef acknowledgement timeout" \
  > "$TMP_ROOT/remote-omp-retry.out" 2>&1
retry_rc=$?
set -e
[ "$retry_rc" = 8 ] || fail "remote OMP retry did not preserve its queued receipt requirement (rc=$retry_rc)"
[ "$(wc -l < "$OMP_SENT")" = "$((sent_before_retry + 1))" ] \
  || fail "remote OMP retry replayed a prior programmatic request"
rm -f "$OMP_SKIP_HANDLED"

cp "$OMP_CONTROL_STATE/remote-omp.meta" "$TMP_ROOT/remote-omp.meta.before-stale"
meta_tmp="$OMP_CONTROL_STATE/remote-omp.meta.tmp"
sed 's/^endpoint_task_id=.*/endpoint_task_id=stale-endpoint/' "$OMP_CONTROL_STATE/remote-omp.meta" > "$meta_tmp"
mv "$meta_tmp" "$OMP_CONTROL_STATE/remote-omp.meta"
set +e
remote_env "$ROOT/bin/fm-send.sh" fm-remote-omp "stale binding" \
  > "$TMP_ROOT/remote-omp-stale.out" 2>&1
stale_rc=$?
set -e
[ "$stale_rc" = 9 ] || fail "stale remote OMP identity did not return a binding refusal (rc=$stale_rc)"
assert_grep 'remote-omp-binding-refused' "$TMP_ROOT/remote-omp-stale.out" \
  "stale remote OMP identity did not report its named refusal"
mv "$TMP_ROOT/remote-omp.meta.before-stale" "$OMP_CONTROL_STATE/remote-omp.meta"

"$REMOTE_ROOT/bin/herdr" pane close "$OMP_PANE"
set +e
remote_env "$ROOT/bin/fm-send.sh" fm-remote-omp "missing live endpoint" \
  > "$TMP_ROOT/remote-omp-missing.out" 2>&1
missing_rc=$?
set -e
[ "$missing_rc" = 9 ] || fail "missing remote OMP endpoint did not refuse delivery (rc=$missing_rc)"
[ ! -e "$OMP_INBOX/004.msg" ] || fail "missing remote OMP endpoint enqueued a request after refusing delivery"
rm -f "$HERDR_FORCE_IDLE"
pass "remote OMP delivery replaces the reproducible typed no-turn regression with one bound inbox request, programmatic turn, and handled acknowledgement"

pass "remote OMP primary, fallback, result metadata, pane launch, and existing safety refusals hold end to end"

echo "ALL TESTS PASSED"
