#!/usr/bin/env bash
# Exercise public convergence/delivery paths with fake Boat and remote SSH.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/runpod-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/runpod-fixture.sh"
TMP_ROOT=$(fm_test_tmproot fm-boat-routing)
w="$TMP_ROOT/world"
mkdir -p "$w/home/data" "$w/home/state" "$w/home/config" "$w/claims" "$w/boatbin"
fakebin=$(fm_fakebin "$w")
install_fake_runpod "$fakebin"
fm_fake_exit0 "$fakebin" chrome-devtools-axi pi-signed gh gh-axi tmux herdr
printf 'codex\n' > "$w/home/config/secondmate-harness"
printf '{"state":"archived","key":"ssh-ed25519 Zml4dHVyZQ==","ip":"127.0.0.1","fail":[]}\n' > "$w/provider.json"
printf '{"token":"fixture_api_key"}\n' > "$w/api.json"
chmod 600 "$w/api.json"
printf 'fixture key\n' > "$w/identity"
printf 'ssh-ed25519 Zml4dHVyZQ== fixture\n' > "$w/identity.pub"
for tool in boat curl ssh; do ln -s "$ROOT/tests/boat-fixture.py" "$w/boatbin/$tool"; done
# Fake executable root derives its world from the containing bin directory.
: > "$w/calls.log"
runpod_seed_remote_route "$w/home" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
world_env() {
  PATH="$fakebin:$PATH" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
  FM_STATE_OVERRIDE="$w/home/state" FM_CONFIG_OVERRIDE="$w/home/config" \
  FM_SSH_BIN="$fakebin/ssh" FM_BOAT_SSH_BIN="$w/boatbin/ssh" \
  FM_BOAT_BIN="$w/boatbin/boat" FM_BOAT_CURL_BIN="$w/boatbin/curl" \
  FM_BOAT_CONFIG_FILE="$w/api.json" FM_BOAT_WAKE_TIMEOUT=3 FM_BOAT_POLL_INTERVAL=.05 \
  FM_PROCEVENT_CLAIM_ROOT="$w/claims" FM_FAKE_REMOTE_LOG="$w/calls.log" \
  FM_FAKE_RUNPOD_LOG="$w/calls.log" "$@"
}
world_env "$ROOT/bin/fm-boat.sh" provision ios --identity "$w/identity" --alias fm-sm-ios-runpod --model openai-codex/fixture >/dev/null
world_env "$ROOT/bin/fm-boat.sh" wake ios >/dev/null
world_env "$ROOT/bin/fm-boat.sh" sleep ios >/dev/null
: > "$w/calls.log"
out=$(world_env "$ROOT/bin/fm-bootstrap.sh" 2>&1)
assert_not_contains "$out" 'SECONDMATE_LIVENESS: secondmate ios' 'dormant Boat route was treated as unreachable'
assert_no_grep fm-sm-ios-runpod "$w/calls.log" 'bootstrap probed a dormant Boat route'
out=$(world_env "$ROOT/bin/fm-config-push.sh" 2>&1)
assert_contains "$out" suspended 'config push did not defer dormant Boat route'
out=$(world_env "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios 2>&1)
assert_contains "$out" suspended 'reply source did not skip dormant Boat route'
pass 'Boat dormancy defers convergence and polling without billing'
: > "$w/calls.log"
: > "$w/calls"
out=$(world_env "$ROOT/bin/fm-send.sh" fm-ios 'fixture status request' 2>&1)
grep -qx 'lifecycle=ready' "$w/home/data/boat/ios.meta" || fail "send did not wake Boat route: $out"
grep -qx 'boat resume' "$w/calls" || fail 'send bypassed compute wake'
assert_grep 'fm-remote-secondmate-control.sh send' "$w/calls.log" 'send did not deliver after wake'
pass 'Boat wake precedes public remote delivery'
for request in "$w/home/state/pending-replies/"*; do
  [ -f "$request" ] || continue
  printf 'done [corr=%s]: fixture reply\n' "$(basename "$request")" >> "$w/home/state/ios.status"
done
world_env "$ROOT/bin/fm-boat.sh" sleep ios >/dev/null
mkdir -p "$w/home/data/runpod"
printf 'lifecycle=suspended\n' > "$w/home/data/runpod/ios.meta"
: > "$w/calls"
: > "$w/calls.log"
if out=$(world_env "$ROOT/bin/fm-send.sh" fm-ios 'contradictory fixture' 2>&1); then fail 'duplicate provider ownership delivered'; fi
assert_contains "$out" contradictory 'duplicate ownership failure missing'
assert_no_grep resume "$w/calls" 'contradictory ownership resumed Boat'
assert_no_grep 'fm-remote-secondmate-control.sh send' "$w/calls.log" 'contradictory ownership delivered remotely'
rm "$w/home/data/runpod/ios.meta"
pass 'double provider claim refuses before provider creation or delivery'

# A compute stop does not keep the second-mate agent: a routed delivery to a
# slept route wakes the placement, proves the remote endpoint is gone on the
# replaced machine, restores the agent through the same readiness and launch
# gate, and only then delivers - exactly once.
: > "$w/calls"
: > "$w/calls.log"
printf 'missing\n' > "$w/agent-state"
out=$(FM_FAKE_REMOTE_STATE_FILE="$w/agent-state" FM_FAKE_REMOTE_LAUNCH_SUCCESS=1 \
  FM_FAKE_DOCTOR_MODE=fresh-pod FM_FAKE_DOCTOR_FIXED="$w/doctor-fixed" \
  world_env "$ROOT/bin/fm-send.sh" fm-ios 'restore after stop' 2>&1) \
  || fail "routed delivery after compute sleep did not restore the remote agent: $out"
grep -qx 'lifecycle=ready' "$w/home/data/boat/ios.meta" || fail "delivery did not wake the compute placement: $out"
[ "$(grep -c 'fm-remote-secondmate-control.sh state' "$w/calls.log")" -ge 2 ] \
  || fail "delivery did not probe the remote agent state before and after restore: $(cat "$w/calls.log")"
assert_grep 'fm-remote-secondmate-control.sh launch' "$w/calls.log" \
  'delivery did not relaunch the missing remote agent'
assert_grep 'fm-remote-doctor.sh' "$w/calls.log" \
  'the restore did not pass the readiness gate on the woken machine'
[ "$(grep -c 'fm-remote-secondmate-control.sh send' "$w/calls.log")" = 1 ] \
  || fail "restored delivery did not deliver exactly once: $(cat "$w/calls.log")"
[ "$(cat "$w/agent-state")" = alive ] || fail "the restored remote agent was not reported alive"
state_line=$(grep -n 'fm-remote-secondmate-control.sh state' "$w/calls.log" | head -1 | cut -d: -f1)
launch_line=$(grep -n 'fm-remote-secondmate-control.sh launch' "$w/calls.log" | head -1 | cut -d: -f1)
send_line=$(grep -n 'fm-remote-secondmate-control.sh send' "$w/calls.log" | cut -d: -f1)
[ "$state_line" -lt "$launch_line" ] && [ "$launch_line" -lt "$send_line" ] \
  || fail "restore order was not state probe -> relaunch -> delivery: $(cat "$w/calls.log")"
pass 'Boat wake-on-delivery restores the remote agent before delivering exactly once'

for send_rc in 6 7 8; do
  printf 'codex\n' > "$w/home/config/secondmate-harness"
  printf 'missing\n' > "$w/agent-state"
  : > "$w/calls.log"
  restored_rc=0
  out=$(FM_FAKE_REMOTE_STATE_FILE="$w/agent-state" FM_FAKE_REMOTE_LAUNCH_SUCCESS=1 \
    FM_FAKE_REMOTE_LAUNCH_HARNESS=omp FM_FAKE_REMOTE_SEND_RC="$send_rc" \
    world_env "$ROOT/bin/fm-send.sh" fm-ios "restored OMP result $send_rc" 2>&1) \
    || restored_rc=$?
  [ "$restored_rc" = "$send_rc" ] || fail "restored OMP result was misclassified (rc=$restored_rc): $out"
  assert_contains "$out" 'remote-omp-inbox-' 'restored OMP result lost its durable inbox verdict'
  assert_not_contains "$out" 'delivery to remote secondmate ios is unknown' 'known OMP result became unknown delivery'
  [ "$(grep -c 'fm-remote-secondmate-control.sh send' "$w/calls.log")" = 1 ] \
    || fail 'restored OMP request was sent more than once'
  grep -qx 'harness=omp' "$w/home/state/ios.meta" || fail 'restore did not change the recorded harness'
  for request in "$w/home/state/pending-replies/"*; do
    [ -f "$request" ] || continue
    grep -Eq '^delivered_epoch=[0-9]+$' "$request" || fail 'known queued OMP result was not recorded as delivered'
  done
  sed 's/^harness=omp$/harness=codex/' "$w/home/state/ios.meta" > "$w/meta.tmp"
  mv "$w/meta.tmp" "$w/home/state/ios.meta"
done
pass 'Boat restoration refreshes the harness before decoding queued OMP results'

FM_HOME="$w/home"
STATE="$w/home/state"
. "$ROOT/bin/fm-wake-lib.sh"
delivery_lock="$STATE/.backlog-handoff-ios.lock"
real_cat=$(command -v cat)
printf '#!/usr/bin/env bash\nREAL_CAT=%q\nLOCK_PID=%q\nWAIT_MARKER=%q\n' \
  "$real_cat" "$delivery_lock/pid" "$w/sender-waiting" > "$fakebin/cat"
cat >> "$fakebin/cat" <<'SH'
if [ "$#" = 1 ] && [ "$1" = "$LOCK_PID" ]; then
  : > "$WAIT_MARKER"
fi
exec "$REAL_CAT" "$@"
SH
chmod +x "$fakebin/cat"
for direction in omp codex; do
  rm -f "$w/sender-waiting"
  : > "$w/calls.log"
  printf 'alive\n' > "$w/agent-state"
  if [ "$direction" = omp ]; then
    old_harness=codex
    expected_rc=8
  else
    old_harness=omp
    expected_rc=0
  fi
  sed "s/^harness=.*/harness=$old_harness/" "$STATE/ios.meta" > "$w/meta.tmp"
  mv "$w/meta.tmp" "$STATE/ios.meta"
  fm_lock_acquire_wait "$delivery_lock" || fail 'could not hold the concurrent delivery lock'
  FM_FAKE_REMOTE_STATE_FILE="$w/agent-state" FM_FAKE_REMOTE_SEND_RC="$expected_rc" \
    world_env "$ROOT/bin/fm-send.sh" fm-ios "concurrent $direction request" > "$w/concurrent.out" 2>&1 &
  sender_pid=$!
  wait_attempt=0
  while [ ! -f "$w/sender-waiting" ] && kill -0 "$sender_pid" 2>/dev/null; do
    wait_attempt=$((wait_attempt + 1))
    [ "$wait_attempt" -lt 1000 ] || break
    sleep .02
  done
  if [ ! -f "$w/sender-waiting" ]; then
    fm_lock_release "$delivery_lock"
    kill "$sender_pid" 2>/dev/null || true
    wait "$sender_pid" 2>/dev/null || true
    fail 'concurrent sender did not wait on the held delivery lock'
  fi
  assert_no_grep 'fm-remote-secondmate-control.sh state' "$w/calls.log" 'waiting sender probed the endpoint without owning its delivery lock'
  sed "s/^harness=.*/harness=$direction/" "$STATE/ios.meta" > "$w/meta.tmp"
  mv "$w/meta.tmp" "$STATE/ios.meta"
  fm_lock_release "$delivery_lock"
  concurrent_rc=0
  wait "$sender_pid" || concurrent_rc=$?
  [ "$concurrent_rc" = "$expected_rc" ] \
    || fail "waiting sender used its cached $old_harness harness: $(cat "$w/concurrent.out")"
  assert_no_grep 'fm-remote-secondmate-control.sh launch' "$w/calls.log" 'waiting sender relaunched the already restored endpoint'
  [ "$(grep -c 'fm-remote-secondmate-control.sh send' "$w/calls.log")" = 1 ] \
    || fail 'waiting sender did not deliver exactly once'
  if [ "$direction" = omp ]; then
    assert_grep 'remote-omp-inbox-queued' "$w/concurrent.out" 'waiting sender lost the known OMP result'
  fi
  for request in "$STATE/pending-replies/"*; do
    [ -f "$request" ] || continue
    grep -Eq '^delivered_epoch=[0-9]+$' "$request" || fail 'waiting sender recorded a known result as unknown delivery'
  done
done
rm -f "$fakebin/cat"
pass 'Waiting Boat senders refresh both OMP and Codex harness transitions under the delivery lock'

# The same sleep guards hold: a routed reply still in flight refuses sleep,
# the route stays awake, and the provider is never told to stop.
: > "$w/calls"
out=$(world_env "$ROOT/bin/fm-boat.sh" sleep ios 2>&1) && fail 'sleep accepted a routed reply still in flight'
grep -qx 'lifecycle=ready' "$w/home/data/boat/ios.meta" || fail 'a refused sleep suspended the route anyway'
assert_no_grep 'boat stop' "$w/calls" 'a refused sleep still stopped the sandbox'
assert_no_grep 'boat delete' "$w/calls" 'a refused sleep still deleted the sandbox'
pass 'Boat sleep refuses a routed reply still in flight'
for request in "$w/home/state/pending-replies/"*; do
  [ -f "$request" ] || continue
  printf 'done [corr=%s]: fixture reply\n' "$(basename "$request")" >> "$w/home/state/ios.status"
done
world_env "$ROOT/bin/fm-boat.sh" sleep ios >/dev/null \
  || fail 'could not re-suspend the route after settling replies'
: > "$w/calls"
if out=$(FM_FAKE_DOCTOR_MODE=unready world_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1); then fail 'unready remote fixture launched'; fi
grep -qx 'lifecycle=ready' "$w/home/data/boat/ios.meta" || fail 'spawn did not wake before readiness'
grep -qx 'boat resume' "$w/calls" || fail 'spawn bypassed Boat wake'
pass 'Boat wake precedes public remote spawn readiness'
fm_test_cleanup
