#!/usr/bin/env bash
# The additive wiring that lets firstmate tell a deliberately suspended
# scale-to-zero route apart from a broken one, and wake it before delivering.
#
# Every case here is about the core supervision, convergence, and delivery
# paths, so each one also asserts that a route WITHOUT a compute provider record
# keeps its existing behavior byte for byte.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/runpod-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/runpod-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-runpod-routing)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# new_world <name>: a primary home with the RunPod boundary and the SSH
# transport both faked, and one shared call log so ordering is observable.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/data" "$w/home/state" "$w/home/config" "$w/home/projects" "$w/claims"
  local fakebin
  fakebin=$(fm_fakebin "$w")
  install_fake_runpod "$fakebin"
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi pi-signed gh gh-axi tmux herdr
  printf 'codex\n' > "$w/home/config/secondmate-harness"
  printf 'RUNPOD_API_KEY=rp_fixture_key\n' > "$w/home/config/runpod.env"
  chmod 600 "$w/home/config/runpod.env"
  runpod_fixture_init "$w/runpod.json"
  : > "$w/calls.log"
  printf '%s\n' "$w"
}

world_env() {  # <world> -- <command...>
  local w=$1
  shift
  PATH="$w/fakebin:$BASE_PATH" \
  FM_HOME="$w/home" \
  FM_SSH_BIN="$w/fakebin/ssh" \
  FM_PROCEVENT_CLAIM_ROOT="$w/claims" \
  FM_FAKE_RUNPOD_STATE="$w/runpod.json" \
  FM_FAKE_RUNPOD_LOG="$w/calls.log" \
  FM_FAKE_REMOTE_LOG="$w/calls.log" \
  FM_RUNPOD_POLL_INTERVAL=0 \
  FM_RUNPOD_WAKE_TIMEOUT=10 \
  "$@"
}

# Bring a route all the way to suspended, then clear the call log so each case
# observes only what it triggered.
suspend_route() {  # <world> <id>
  local w=$1 id=$2
  world_env "$w" "$ROOT/bin/fm-runpod.sh" provision "$id" --datacenter EU-RO-1 --size 50 \
    --code-origin https://example.test/firstmate.git >/dev/null \
    || fail "provision failed for $id"
  world_env "$w" "$ROOT/bin/fm-runpod.sh" wake "$id" >/dev/null \
    || fail "wake failed for $id"
  world_env "$w" "$ROOT/bin/fm-runpod.sh" sleep "$id" >/dev/null \
    || fail "sleep failed for $id"
  : > "$w/calls.log"
}

lifecycle_of() {  # <world> <id>
  sed -n 's/^lifecycle=//p' "$1/home/data/runpod/$2.meta"
}

# --- provider-owned crew routing -------------------------------------------

w=$(new_world crew-routing)
remote_home="$w/remote-home"
mkdir -p "$remote_home/bin" "$remote_home/data" "$remote_home/state" "$remote_home/config"
printf '# Firstmate\n' > "$remote_home/AGENTS.md"
printf 'ios\n' > "$remote_home/.fm-secondmate-home"
FM_HOME="$remote_home" "$ROOT/bin/fm-remote-secondmate-control.sh" runpod-crews ios >/dev/null \
  || fail "RunPod crew routing could not be installed in a seeded remote home"
[ "$(cat "$remote_home/config/crew-harness")" = codex ] \
  || fail "RunPod crew routing did not set codex as the static default"
[ "$(cat "$remote_home/config/crew-harness-fallback")" = claude ] \
  || fail "RunPod crew routing did not publish Claude as the configured fallback"
[ ! -e "$remote_home/config/crew-dispatch.json" ] \
  || fail "RunPod crew routing left a quota-array dispatch override ahead of the configured primary"
FM_HOME="$remote_home" "$ROOT/bin/fm-remote-secondmate-control.sh" runpod-crews ios >/dev/null \
  || fail "RunPod crew routing was not idempotent"
pass "RunPod remote homes route crews through a Codex primary and predictive Claude fallback"

# --- health polling never wakes a suspended route ---------------------------

w=$(new_world liveness)
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
runpod_seed_remote_route "$w/home" plain plain-host /srv/firstmate /srv/sm-plain
suspend_route "$w" ios

out=$(world_env "$w" "$ROOT/bin/fm-bootstrap.sh" 2>&1)
assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate ios" \
  "a deliberately suspended route must not be reported as a liveness gap"
assert_no_grep "fm-sm-ios-runpod" "$w/calls.log" \
  "a suspended route must not be reached over SSH at all"
[ "$(grep -c 'POST /pods' "$w/calls.log" || true)" = 0 ] \
  || fail "health polling must never create compute for a suspended route"
[ "$(lifecycle_of "$w" ios)" = suspended ] \
  || fail "health polling must leave the suspended lifecycle alone"
pass "startup health polling skips a suspended route without probing, warning, or relaunching it"

# The always-on watcher also owns a stale-pane loop that is separate from
# bootstrap liveness. A suspended route must enter the long pause cadence there
# without an SSH beacon probe or possible-wedge escalation.
w=$(new_world watcher-dormant)
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
runpod_seed_remote_route "$w/home" alpha plain-host /srv/firstmate /srv/sm-plain
suspend_route "$w" ios
: > "$w/calls.log"
watch_out="$w/watch.out"
touch "$w/home/state/.last-check" "$w/home/state/.last-heartbeat"
FM_POLL=0.1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_PAUSE_RESURFACE_SECS=0 FM_WATCH_REMOTE_TIMEOUT=1 \
  world_env "$w" timeout 2 "$ROOT/bin/fm-watch.sh" > "$watch_out" 2>&1
watch_rc=$?
case "$watch_rc" in
  0|124) ;;
  *) fail "the dormant watcher fixture exited unexpectedly: $(cat "$watch_out")" ;;
esac
assert_not_contains "$(cat "$watch_out")" "possible wedge" \
  "the watcher escalated a deliberately suspended route as wedged"
assert_no_grep '^fm-sm-ios-runpod fm-remote-secondmate-control.sh beacon-age$' "$w/calls.log" \
  "the watcher probed a suspended route's absent remote beacon"
[ ! -f "$w/home/state/.wedge-escalations-remote_ios" ] \
  || fail "the watcher started a wedge escalation counter for a suspended route"
pass "the watcher absorbs suspended RunPod routes on the long dormant cadence"

# The same sweep still reaches an ordinary remote route with no compute
# provider behind it, exactly as before this feature existed.
assert_grep 'fm-remote-secondmate-control.sh beacon-age' "$w/calls.log" \
  "an ordinary remote route must still be probed by the same sweep"
pass "an ordinary remote route keeps its existing liveness probe unchanged"

# --- startup convergence and config push ------------------------------------

w=$(new_world converge)
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
suspend_route "$w" ios

out=$(world_env "$w" "$ROOT/bin/fm-bootstrap.sh" 2>&1)
assert_not_contains "$out" "SECONDMATE_SYNC: secondmate ios" \
  "convergence must not report a suspended route as a sync failure"
[ "$(grep -c 'fm-remote-secondmate-control.sh sync' "$w/calls.log" || true)" = 0 ] \
  || fail "startup convergence must not reach a suspended host"
[ "$(grep -c 'POST /pods' "$w/calls.log" || true)" = 0 ] \
  || fail "startup convergence must never create compute"
pass "startup convergence defers a suspended route instead of waking it"

: > "$w/calls.log"
out=$(world_env "$w" "$ROOT/bin/fm-config-push.sh" 2>&1)
assert_contains "$out" "suspended" "config push must say why the suspended route was skipped"
[ "$(grep -c 'POST /pods' "$w/calls.log" || true)" = 0 ] \
  || fail "config push must never create compute"
[ "$(lifecycle_of "$w" ios)" = suspended ] || fail "config push must leave the route suspended"
pass "pushing inherited material skips a suspended route rather than waking it"

: > "$w/calls.log"
out=$(world_env "$w" "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios 2>&1) \
  || fail "arming a suspended reply source must be a clean skip, not an error: $out"
assert_contains "$out" "suspended" "arming must report the skip"
[ "$(grep -c 'POST /pods' "$w/calls.log" || true)" = 0 ] \
  || fail "arming a reply source must never create compute"
pass "the reply source is not armed against a suspended host"

# --- wake before deliver ----------------------------------------------------

w=$(new_world deliver)
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
suspend_route "$w" ios

out=$(world_env "$w" "$ROOT/bin/fm-send.sh" fm-ios 'status please' 2>&1) \
  || fail "sending to a suspended second mate failed: $out"
[ "$(lifecycle_of "$w" ios)" = ready ] || fail "delivery must wake the route first"
[ "$(grep -c 'POST /pods' "$w/calls.log" || true)" = 1 ] \
  || fail "delivery must create exactly one pod"
first_pod=$(grep -n 'POST /pods' "$w/calls.log" | head -1 | cut -d: -f1)
first_send=$(grep -n 'fm-remote-secondmate-control.sh send' "$w/calls.log" | head -1 | cut -d: -f1)
[ -n "$first_send" ] || fail "the request must actually be delivered after the wake"
[ "$first_pod" -lt "$first_send" ] || fail "the wake must happen strictly before delivery"
pass "an explicit request wakes a suspended second mate and then delivers through the normal path"

: > "$w/calls.log"
out=$(world_env "$w" "$ROOT/bin/fm-send.sh" fm-ios 'second request' 2>&1) \
  || fail "sending to an already-awake second mate failed: $out"
[ "$(grep -c 'POST /pods' "$w/calls.log" || true)" = 0 ] \
  || fail "an awake second mate must not be re-provisioned on every send"
pass "delivery to an already-awake second mate is unchanged"

# --- a failed wake never delivers -------------------------------------------

w=$(new_world wakefail)
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
suspend_route "$w" ios

out=$(FM_FAKE_RUNPOD_UNREACHABLE=1 world_env "$w" "$ROOT/bin/fm-send.sh" fm-ios 'urgent work' 2>&1) \
  && fail "a send whose wake failed must not report success"
assert_contains "$out" "nothing was delivered" "a failed wake must say plainly that nothing was delivered"
[ "$(grep -c 'fm-remote-secondmate-control.sh send' "$w/calls.log" || true)" = 0 ] \
  || fail "a failed wake must never deliver the request"
[ "$(lifecycle_of "$w" ios)" = suspended ] || fail "a failed wake must leave the route suspended"

: > "$w/calls.log"
out=$(world_env "$w" "$ROOT/bin/fm-send.sh" fm-ios 'urgent work' 2>&1) \
  || fail "the retried send failed: $out"
[ "$(grep -c 'fm-remote-secondmate-control.sh send' "$w/calls.log" || true)" = 1 ] \
  || fail "the retry must deliver the request exactly once"
pass "a compute failure before delivery loses nothing and never duplicates the request"

w=$(new_world delivery255)
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
suspend_route "$w" ios

out=$(FM_FAKE_SSH_MODE=post-delivery-255 world_env "$w" \
  "$ROOT/bin/fm-send.sh" fm-ios 'may have landed' 2>&1) \
  && fail "an SSH-255 send must report unknown completion"
assert_contains "$out" "do not resend" "an unknown delivery must preserve the no-retry instruction"
[ "$(grep -c 'fm-remote-secondmate-control.sh send' "$w/calls.log" || true)" = 1 ] \
  || fail "an SSH-255 delivery must make exactly one remote send attempt with no retry or failover"
unknown_record=$(grep -l '^phase=delivery_unknown$' "$w/home/state/pending-replies"/* 2>/dev/null | head -1 || true)
[ -n "$unknown_record" ] \
  || fail "an SSH-255 delivery must leave a durable unknown-completion record"
pass "a post-delivery SSH-255 makes one attempt and preserves unknown completion"

# --- launch wakes before the readiness gate ---------------------------------

w=$(new_world launch)
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
suspend_route "$w" ios

out=$(FM_FAKE_DOCTOR_MODE=unready \
  world_env "$w" "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) \
  && fail "the injected readiness refusal did not stop the launch"
[ "$(lifecycle_of "$w" ios)" = ready ] || fail "a launch must wake a suspended route"
first_pod=$(grep -n 'POST /pods' "$w/calls.log" | head -1 | cut -d: -f1)
first_doctor=$(grep -n 'fm-remote-doctor.sh' "$w/calls.log" | head -1 | cut -d: -f1)
[ -n "$first_pod" ] || fail "a launch must create the pod for a suspended route"
[ -n "$first_doctor" ] || fail "a launch must still run the readiness gate"
[ "$first_pod" -lt "$first_doctor" ] \
  || fail "the wake must happen before the readiness gate, not after it reports the host unreachable"
pass "a launch wakes a suspended route before the readiness gate runs"

w=$(new_world launchsleep)
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
suspend_route "$w" ios
doctor_ready="$w/doctor.ready"
doctor_release="$w/doctor.release"
FM_FAKE_DOCTOR_READY="$doctor_ready" FM_FAKE_DOCTOR_RELEASE="$doctor_release" \
  FM_FAKE_REMOTE_LAUNCH_SUCCESS=1 \
  world_env "$w" "$ROOT/bin/fm-spawn.sh" ios --secondmate > "$w/spawn.out" 2>&1 &
spawn_pid=$!
for _ in $(seq 1 500); do
  [ -e "$doctor_ready" ] && break
  kill -0 "$spawn_pid" 2>/dev/null || fail "spawn exited before reaching readiness: $(cat "$w/spawn.out")"
  sleep 0.01
done
assert_present "$doctor_ready" "the spawn fixture must reach its readiness barrier"
world_env "$w" "$ROOT/bin/fm-runpod.sh" sleep ios > "$w/sleep.out" 2>&1 &
sleep_pid=$!
sleep 0.2
kill -0 "$sleep_pid" 2>/dev/null || fail "sleep escaped the active RunPod spawn boundary"
[ "$(grep -c 'DELETE /pods/' "$w/calls.log" || true)" = 0 ] \
  || fail "sleep terminated the pod while readiness was still active"
: > "$doctor_release"
wait "$spawn_pid" || fail "spawn failed after readiness resumed: $(cat "$w/spawn.out")"
wait "$sleep_pid" || fail "sleep failed after spawn completed: $(cat "$w/sleep.out")"
assert_grep "fm-remote-secondmate-control.sh runpod-crews" "$w/calls.log" \
  "remote launch inheritance did not reapply the provider-owned crew route"
pass "every RunPod remote launch converges its provider-owned crew routing after inheritance"
launch_line=$(grep -n 'fm-remote-secondmate-control.sh launch' "$w/calls.log" | head -1 | cut -d: -f1)
delete_line=$(grep -n 'DELETE /pods/' "$w/calls.log" | head -1 | cut -d: -f1)
[ -n "$launch_line" ] && [ -n "$delete_line" ] && [ "$launch_line" -lt "$delete_line" ] \
  || fail "sleep must terminate compute only after the remote launch completes"
pass "sleep waits for the whole RunPod remote spawn operation"

# A brand-new pod has no Herdr fm-remote server running yet. The readiness gate
# is what brings it back, and it runs on every launch, so each fresh pod is
# recovered by the same path an existing host uses. The doctor's own Linux
# behavior - no launch agent, no GUI session, the server started directly - is
# owned by tests/fm-remote-doctor.test.sh.
w=$(new_world freshpod)
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
suspend_route "$w" ios

FM_FAKE_DOCTOR_MODE=fresh-pod FM_FAKE_DOCTOR_FIXED="$w/doctor.fixed" \
  world_env "$w" "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null 2>&1 || true
[ "$(lifecycle_of "$w" ios)" = ready ] || fail "a fresh pod must be woken"
assert_present "$w/doctor.fixed" "a fresh pod's readiness repair must actually run"
doctor_calls=$(grep -c 'fm-remote-doctor.sh' "$w/calls.log" || true)
[ "$doctor_calls" -ge 3 ] \
  || fail "the fresh pod must go through check, repair, and re-check, not a single probe (saw $doctor_calls)"
[ "$(grep -n 'fm-remote-doctor.sh --fix' "$w/calls.log" | head -1 | cut -d: -f1)" -gt \
  "$(grep -n 'POST /pods' "$w/calls.log" | head -1 | cut -d: -f1)" ] \
  || fail "the repair must run against the woken pod, not before it exists"
assert_no_grep "SECONDMATE_LIVENESS" "$w/calls.log" "the fresh-pod path must not go through a liveness warning"
pass "each fresh pod is recovered through the ordinary readiness gate: check, repair, re-check"

w=$(new_world launchfail)
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
suspend_route "$w" ios
out=$(FM_FAKE_RUNPOD_UNREACHABLE=1 world_env "$w" "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) \
  && fail "a launch whose wake failed must not report success"
assert_contains "$out" "could not be woken" "a refused launch must name the compute failure"
[ "$(grep -c 'fm-remote-doctor.sh' "$w/calls.log" || true)" = 0 ] \
  || fail "a launch refused for compute must not go on to probe the host"
assert_grep "- ios - " "$w/home/data/secondmates.md" "a refused launch must preserve the route"
pass "a launch refused for compute preserves the route and probes nothing"

# --- local second mates are untouched ---------------------------------------

w=$(new_world local)
mkdir -p "$w/home/data" "$w/home/state" "$w/local-home/data"
printf 'ios\n' > "$w/local-home/.fm-secondmate-home"
printf -- '- local1 - local domain. (home: %s; scope: local work; projects: alpha; added 2026-08-12)\n' \
  "$w/local-home" > "$w/home/data/secondmates.md"
fm_write_secondmate_meta "$w/home/state/local1.meta" "$w/local-home"
before=$(cat "$w/home/state/local1.meta")
out=$(world_env "$w" "$ROOT/bin/fm-bootstrap.sh" 2>&1)
[ "$(cat "$w/home/state/local1.meta")" = "$before" ] \
  || fail "a local secondmate's record must be unchanged by the compute-provider wiring"
[ "$(grep -c 'POST /pods' "$w/calls.log" || true)" = 0 ] \
  || fail "a local secondmate must never touch a compute provider"
assert_not_contains "$out" "suspended" "a local secondmate must never be described as suspended"
assert_absent "$w/home/data/runpod" "a local secondmate must create no compute-provider records"
pass "local second mates are completely unaffected"

# --- registry shape is unchanged --------------------------------------------

w=$(new_world registry)
mkdir -p "$w/home/data" "$w/home/state" "$w/local2/data"
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios alpha
runpod_seed_remote_route "$w/home" web fm-sm-web-runpod /srv/firstmate /srv/sm-web alpha
printf -- '- local2 - local domain. (home: %s; scope: local alpha work; projects: alpha; added 2026-08-12)\n' \
  "$w/local2" >> "$w/home/data/secondmates.md"

out=$(PATH="$w/fakebin:$BASE_PATH" FM_HOME="$w/home" "$ROOT/bin/fm-home-seed.sh" validate 2>&1) \
  || fail "two remote second mates plus a local one on one project must validate: $out"
pass "two second mates may reference the same project, and local and remote ids and homes stay distinct"
