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
: > "$w/calls"
if out=$(FM_FAKE_DOCTOR_MODE=unready world_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1); then fail 'unready remote fixture launched'; fi
grep -qx 'lifecycle=ready' "$w/home/data/boat/ios.meta" || fail 'spawn did not wake before readiness'
grep -qx 'boat resume' "$w/calls" || fail 'spawn bypassed Boat wake'
pass 'Boat wake precedes public remote spawn readiness'
fm_test_cleanup
