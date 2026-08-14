#!/usr/bin/env bash
# RunPod compute lifecycle for a whole-home remote second mate, over the
# deterministic mocked RunPod boundary. No account, key, or paid resource.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/runpod-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/runpod-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-runpod-lifecycle)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
install_fake_runpod "$FAKEBIN"

PARENT="$TMP_ROOT/parent"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects"
REAL_MV=$(command -v mv)
cat > "$FAKEBIN/mv" <<SH
#!/usr/bin/env bash
if [ "\${FM_FAKE_RUNPOD_RECORD_FAIL:-}" = suspending ] \
   && [ "\${*: -1}" = "$PARENT/data/runpod/ios.meta" ]; then
  exit 1
fi
exec "$REAL_MV" "\$@"
SH
chmod +x "$FAKEBIN/mv"
printf 'RUNPOD_API_KEY=rp_fixture_key\n' > "$PARENT/config/runpod.env"
chmod 600 "$PARENT/config/runpod.env"

API_STATE="$TMP_ROOT/runpod.json"
API_LOG="$TMP_ROOT/api.log"
REMOTE_LOG="$TMP_ROOT/remote.log"
runpod_fixture_init "$API_STATE"
: > "$API_LOG"
: > "$REMOTE_LOG"

runpod_seed_remote_route "$PARENT" ios fm-sm-ios-runpod /srv/firstmate /srv/sm-ios
runpod_seed_remote_route "$PARENT" web fm-sm-web-runpod /srv/firstmate /srv/sm-web

rp() {  # run the provider with the fixture wired in
  PATH="$FAKEBIN:$PATH" \
  FM_HOME="$PARENT" \
  FM_SSH_BIN="$FAKEBIN/ssh" \
  FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" \
  FM_FAKE_RUNPOD_STATE="$API_STATE" \
  FM_FAKE_RUNPOD_LOG="$API_LOG" \
  FM_FAKE_REMOTE_LOG="$REMOTE_LOG" \
  FM_RUNPOD_POLL_INTERVAL="${FM_TEST_RUNPOD_POLL_INTERVAL:-0}" \
  FM_RUNPOD_WAKE_TIMEOUT="${FM_TEST_RUNPOD_WAKE_TIMEOUT:-10}" \
  "$ROOT/bin/fm-runpod.sh" "$@"
}

record_field() {  # <id> <key>
  sed -n "s/^$2=//p" "$PARENT/data/runpod/$1.meta"
}

fragment() {  # <alias>
  printf '%s' "$PARENT/config/runpod/ssh.d/$1.conf"
}

# --- credentials fail closed ------------------------------------------------

chmod 644 "$PARENT/config/runpod.env"
out=$(rp provision ios --datacenter EU-RO-1 2>&1) && fail "provision succeeded with a public API key file"
assert_contains "$out" "config/runpod.env" "an unsafe credential mode must name the credential path"
assert_contains "$out" "RUNPOD_API_KEY" "an unsafe credential mode must name the required key"
assert_contains "$out" "mode 600" "an unsafe credential mode must give the exact remediation"
[ ! -s "$API_LOG" ] || fail "an unsafe credential mode must refuse before any request is made"
chmod 600 "$PARENT/config/runpod.env"
pass "a group- or world-readable API key file is refused"

mv "$PARENT/config/runpod.env" "$TMP_ROOT/api-key.hidden"
out=$(rp provision ios --datacenter EU-RO-1 2>&1) && fail "provision succeeded with no API key"
assert_contains "$out" "config/runpod.env" "missing credentials must name the exact file to create"
assert_contains "$out" "RUNPOD_API_KEY=" "missing credentials must name the exact key to set"
assert_not_contains "$out" rp_fixture_key "a credential error must never echo a key"
[ ! -s "$API_LOG" ] || fail "a missing key must refuse before any request is made: $(cat "$API_LOG")"
printf '# runpod credentials\nOTHER_KEY=nope\n' > "$PARENT/config/runpod.env"
out=$(rp provision ios --datacenter EU-RO-1 2>&1) && fail "provision succeeded with no RUNPOD_API_KEY assignment"
assert_contains "$out" "RUNPOD_API_KEY" "a file without the key must be refused the same way"
[ ! -s "$API_LOG" ] || fail "a keyless credential file must refuse before any request is made: $(cat "$API_LOG")"
mv "$TMP_ROOT/api-key.hidden" "$PARENT/config/runpod.env"
chmod 600 "$PARENT/config/runpod.env"
pass "a missing or keyless credential file refuses before any request, naming the exact path and key"

# --- provision --------------------------------------------------------------

out=$(rp provision .hidden --datacenter EU-RO-1 2>&1) \
  && fail "provision must reject a leading-dot secondmate id"
assert_contains "$out" "invalid secondmate id" "the refusal must identify the invalid secondmate id"
assert_absent "$PARENT/data/runpod/.hidden.meta" "a hidden ownership record must never be created"
[ ! -s "$API_LOG" ] || fail "an invalid hidden id must refuse before any request is made"
pass "leading-dot ids cannot create hidden ownership records"

out=$(rp provision ios --datacenter EU-RO-1 --size 100 --code-origin https://example.test/firstmate.git --harness-npm @example/harness 2>&1) || fail "provision failed: $out"
assert_contains "$out" "provisioned: secondmate ios" "provision must report what it created"
[ "$(runpod_volume_count "$API_STATE")" = 1 ] || fail "provision must create exactly one network volume"
[ "$(runpod_pod_count "$API_STATE")" = 0 ] || fail "provision must not create a pod"
[ "$(record_field ios lifecycle)" = provisioned ] || fail "provision must record the provisioned lifecycle"
[ "$(record_field ios volume_name)" = fm-sm-ios-runpod ] || fail "provision must use the fm-sm-<domain>-runpod volume name"
[ "$(record_field ios ssh_alias)" = fm-sm-ios-runpod ] || fail "provision must bind the route's SSH alias"
pass "provision creates one volume, records placement, and creates no pod"

out=$(rp provision ios --datacenter EU-RO-1 --size 100 --code-origin https://example.test/firstmate.git --harness-npm @example/harness 2>&1) || fail "second provision failed: $out"
assert_contains "$out" "reused: volume" "a repeated provision must reuse the recorded volume"
[ "$(runpod_volume_count "$API_STATE")" = 1 ] || fail "a repeated provision must not create a second volume"
[ "$(runpod_api_calls "$API_LOG" "POST /networkvolumes")" = 1 ] || fail "a repeated provision must not POST a second volume"
pass "provision is idempotent and never accumulates volumes"

out=$(rp provision ios --datacenter EU-RO-1 --size 100 --harness-npm @example/harness 2>&1) \
  || fail "reprovision without --code-origin failed: $out"
[ "$(record_field ios code_origin)" = https://example.test/firstmate.git ] \
  || fail "omitting --code-origin on reprovision must preserve the recorded clone source"
pass "reprovision preserves the recorded code origin when the flag is omitted"

out=$(rp provision ios --datacenter EU-RO-1 --size 100 --code-origin '' --harness-npm @example/harness 2>&1) \
  && fail "reprovision accepted an explicitly empty code origin"
assert_contains "$out" "--code-origin cannot be empty" "the empty-origin refusal must name the invalid flag"
[ "$(record_field ios code_origin)" = https://example.test/firstmate.git ] \
  || fail "a refused empty origin must preserve the recorded clone source"
pass "an explicit empty code origin cannot create a clone-free wake contract"

out=$(rp provision nonroot --user ubuntu --datacenter EU-RO-1 --code-origin https://example.test/firstmate.git 2>&1) \
  && fail "provision accepted an SSH account the pod does not prepare"
assert_contains "$out" "only the root account is supported" "the account refusal must explain the pod contract"
assert_absent "$PARENT/data/runpod/nonroot.meta" "a refused account must create no ownership record"
pass "the SSH login cannot diverge from the account prepared by pod boot"

before_posts=$(runpod_api_calls "$API_LOG" "POST /networkvolumes")
out=$(rp provision fresh --datacenter EU-RO-1 2>&1) \
  && fail "provision created a fresh clone-free volume without --code-origin"
assert_contains "$out" "--code-origin is required" "the fresh-volume refusal must name the missing source"
[ "$(runpod_api_calls "$API_LOG" "POST /networkvolumes")" = "$before_posts" ] \
  || fail "a missing code origin must refuse before creating paid storage"
assert_absent "$PARENT/data/runpod/fresh.meta" "a refused clone-free volume must have no local ownership record"
pass "fresh volumes require a code origin before paid storage is created"

jq '.volumes += [{"id":"vol-unowned","name":"fm-sm-collision-runpod","size":50,"dataCenterId":"EU-RO-1"}]' \
  "$API_STATE" > "$API_STATE.next" && mv "$API_STATE.next" "$API_STATE"
out=$(rp provision collision --volume-name fm-sm-collision-runpod --code-origin https://example.test/firstmate.git 2>&1) \
  && fail "provision adopted an unrecorded same-name volume"
assert_contains "$out" "unowned name collision" "the collision refusal must distinguish missing local provenance"
assert_contains "$out" "fm-sm-collision-runpod" "the collision refusal must name the provider volume"
assert_absent "$PARENT/data/runpod/collision.meta" "an unowned collision must not create local ownership evidence"
pass "provider volumes without local ownership evidence are never adopted"
jq 'del(.volumes[] | select(.id == "vol-unowned"))' "$API_STATE" > "$API_STATE.next" \
  && mv "$API_STATE.next" "$API_STATE"

out=$(rp provision web --volume-name fm-sm-ios-runpod 2>&1) \
  && fail "provision must reject a volume already owned by another second mate"
assert_contains "$out" "already owned by secondmate ios" "cross-record ownership must be refused at provision"
assert_absent "$PARENT/data/runpod/web.meta" "a refused shared-volume provision must create no ownership record"
pass "provision rejects a volume owned by another second mate"

out=$(rp provision web --alias fm-sm-ios-runpod --datacenter EU-RO-1 2>&1) \
  && fail "provision must reject an SSH alias already owned by another second mate"
assert_contains "$out" "already owned by secondmate ios" "cross-record alias ownership must be refused at provision"
assert_absent "$PARENT/data/runpod/web.meta" "a refused shared-alias provision must create no ownership record"
pass "provision rejects an SSH alias owned by another second mate"

# --- wake -------------------------------------------------------------------

started=$(date +%s)
out=$(FM_FAKE_ENDPOINT_API_BLOCK=1 FM_TEST_RUNPOD_POLL_INTERVAL=1 \
  FM_TEST_RUNPOD_WAKE_TIMEOUT=2 rp wake ios 2>&1) \
  && fail "wake must stop at its wall-clock deadline when endpoint discovery blocks"
elapsed=$(($(date +%s) - started))
assert_contains "$out" "RunPod API could not be reached while waiting for pod" \
  "a blocked endpoint status request must report the bounded wake failure"
[ "$elapsed" -le 4 ] || fail "the 2s wake deadline took ${elapsed}s during endpoint discovery"
[ "$(record_field ios lifecycle)" != ready ] || fail "an endpoint timeout must never record the pod ready"
pass "endpoint discovery shares the one wall-clock wake deadline"

started=$(date +%s)
out=$(FM_FAKE_KEYSCAN_BLOCK=1 FM_TEST_RUNPOD_POLL_INTERVAL=1 \
  FM_TEST_RUNPOD_WAKE_TIMEOUT=2 rp wake ios 2>&1) \
  && fail "wake must stop at its wall-clock deadline when keyscan blocks"
elapsed=$(($(date +%s) - started))
assert_contains "$out" "could not read the pod's SSH host key" \
  "a blocked host-key scan must report the bounded wake failure"
[ "$elapsed" -le 4 ] || fail "the 2s wake deadline took ${elapsed}s while host-key scanning"
[ "$(record_field ios lifecycle)" != ready ] || fail "a keyscan timeout must never record the pod ready"
pass "endpoint discovery and host-key scanning share one wall-clock deadline"

started=$(date +%s)
out=$(FM_FAKE_SSH_PROBE_BLOCK=1 FM_TEST_RUNPOD_POLL_INTERVAL=1 \
  FM_TEST_RUNPOD_WAKE_TIMEOUT=4 rp wake ios 2>&1) \
  && fail "wake must stop at its wall-clock deadline when readiness probing blocks"
elapsed=$(($(date +%s) - started))
assert_contains "$out" "SSH bootstrap did not complete" \
  "a blocked readiness probe must report the bounded wake failure"
[ "$elapsed" -le 6 ] || fail "the 4s wake deadline took ${elapsed}s during readiness probing"
[ "$(record_field ios lifecycle)" != ready ] || fail "a readiness timeout must never record the pod ready"
pass "readiness probing shares the one wall-clock wake deadline"

KEYSCAN_ATTEMPTS="$TMP_ROOT/keyscan-attempts"
out=$(FM_FAKE_BOOT_INCOMPLETE=1 FM_FAKE_KEYSCAN_ATTEMPTS="$KEYSCAN_ATTEMPTS" \
  FM_FAKE_KEYSCAN_FAILS=1 FM_TEST_RUNPOD_POLL_INTERVAL=1 FM_TEST_RUNPOD_WAKE_TIMEOUT=4 \
  rp wake ios 2>&1) && fail "wake must refuse while first-boot provisioning is incomplete"
assert_contains "$out" "SSH bootstrap did not complete" "an incomplete bootstrap must fail at the wake readiness boundary"
[ "$(cat "$KEYSCAN_ATTEMPTS")" -ge 2 ] || fail "wake must retry host-key scanning while sshd is still starting"
[ "$(record_field ios lifecycle)" != ready ] || fail "an incompletely provisioned pod must never be recorded ready"
pass "wake retries host-key scanning and refuses an incomplete bootstrap"

# A provider can leave a paid pod RUNNING without ever publishing an endpoint.
# The failure must identify that provisioning state, and a never-ready record is
# the one safe provenance that permits provider-only termination without SSH.
out=$(rp provision stalled --datacenter EU-RO-1 --size 50 \
  --code-origin https://example.test/firstmate.git 2>&1) \
  || fail "stalled-pod fixture provision failed: $out"
out=$(FM_FAKE_RUNPOD_INIT_POLLS=999 FM_TEST_RUNPOD_POLL_INTERVAL=1 \
  FM_TEST_RUNPOD_WAKE_TIMEOUT=2 rp wake stalled 2>&1) \
  && fail "the stalled endpoint fixture unexpectedly reached ready"
assert_contains "$out" "did not publish an SSH endpoint" \
  "a provisioning stall must retain the endpoint timeout diagnosis"
assert_contains "$out" "desiredStatus=RUNNING" \
  "a provisioning stall must report the provider desiredStatus"
assert_contains "$out" "status=INITIALIZING" \
  "a provisioning stall must report the provider status"
STALLED_POD=$(record_field stalled pod_id)
STALLED_VOLUME=$(record_field stalled volume_id)
[ -n "$STALLED_POD" ] || fail "the stalled pod id was not preserved for recovery"
posts_before_failed_retry=$(runpod_api_calls "$API_LOG" "POST /pods")
jq '(.pods[] | select(.id == $p) | .desiredStatus) = "TERMINATED"' --arg p "$STALLED_POD" \
  "$API_STATE" > "$API_STATE.next" && mv "$API_STATE.next" "$API_STATE"
out=$(rp wake stalled 2>&1) && fail "ordinary wake replaced a failed never-ready paid attempt"
assert_contains "$out" "recover-stuck stalled --yes" \
  "the paid-attempt refusal did not name the explicit acknowledgement path"
[ "$(runpod_api_calls "$API_LOG" "POST /pods")" = "$posts_before_failed_retry" ] \
  || fail "ordinary wake created a second pod before explicit recovery acknowledgement"
pass "ordinary wake cannot replace a failed never-ready paid attempt without acknowledgement"
deletes_before_recovery=$(runpod_api_calls "$API_LOG" "DELETE /pods/$STALLED_POD")
out=$(rp recover-stuck stalled 2>&1) && fail "never-ready recovery deleted compute without explicit confirmation"
assert_contains "$out" "pass --yes" \
  "unconfirmed never-ready recovery did not name the explicit authorization"
[ "$(runpod_api_calls "$API_LOG" "DELETE /pods/$STALLED_POD")" = "$deletes_before_recovery" ] \
  || fail "unconfirmed never-ready recovery reached provider deletion"
out=$(rp recover-stuck stalled --yes 2>&1) || fail "never-ready stuck recovery failed: $out"
assert_contains "$out" "recover-stuck evidence:" \
  "confirmed recovery did not print its provider and endpoint evidence"
assert_contains "$out" "current_endpoint=none current_ssh=not-applicable" \
  "confirmed recovery did not report the absent current endpoint"
assert_contains "$out" "recorded_endpoint=none recorded_ssh=not-applicable confirmation=--yes" \
  "confirmed recovery did not report recorded evidence and authorization"
assert_contains "$out" "recovered-stuck: secondmate stalled" \
  "stuck recovery must report the exact pod it terminated"
[ -z "$(record_field stalled pod_id)" ] || fail "stuck recovery left the terminated pod recorded"
[ "$(record_field stalled lifecycle)" = provisioned ] \
  || fail "stuck recovery did not return a never-ready volume to provisioned"
[ "$(jq -r --arg p "$STALLED_POD" '[.pods[] | select(.id == $p)] | length' "$API_STATE")" = 0 ] \
  || fail "stuck recovery left the never-ready billing pod alive"
[ "$(jq -r --arg v "$STALLED_VOLUME" '[.volumes[] | select(.id == $v)] | length' "$API_STATE")" = 1 ] \
  || fail "stuck recovery deleted the retained network volume"
pass "endpoint stalls report provider state and never-ready pods have a guarded recovery path"
rp destroy stalled --yes >/dev/null 2>&1 || fail "the isolated stalled-pod fixture volume could not be cleaned up"

out=$(FM_FAKE_BOOT_INCOMPLETE=1 rp ssh ios 2>&1) \
  || fail "SSH remediation must remain reachable before readiness: $out"
[ "$(record_field ios lifecycle)" != ready ] || fail "interactive SSH must not mark an incomplete pod ready"
pass "interactive SSH remains available for pre-ready human steps"

out=$(rp provision reachable --datacenter EU-RO-1 --size 50 \
  --code-origin https://example.test/firstmate.git 2>&1) \
  || fail "reachable-recovery fixture provision failed: $out"
out=$(FM_FAKE_RUNPOD_INIT_POLLS=999 FM_TEST_RUNPOD_POLL_INTERVAL=1 \
  FM_TEST_RUNPOD_WAKE_TIMEOUT=2 rp wake reachable 2>&1) \
  && fail "reachable-recovery fixture unexpectedly reached ready"
REACHABLE_POD=$(record_field reachable pod_id)
[ -z "$(record_field reachable endpoint_host)" ] \
  || fail "current-only recovery fixture unexpectedly recorded an endpoint"
jq '(.pods[] | select(.id == $p)) |= (.remainingInitPolls = 0 | .status = "RUNNING" | .publicIp = "10.0.0.99" | .portMappings = {"22":20999})' \
  --arg p "$REACHABLE_POD" "$API_STATE" > "$API_STATE.next" && mv "$API_STATE.next" "$API_STATE"
out=$(rp recover-stuck reachable --yes 2>&1) \
  && fail "recover-stuck terminated a pod that became SSH-reachable"
assert_contains "$out" "current_ssh=reachable:keyscan" \
  "reachable recovery refusal did not print the renewed SSH proof"
[ "$(jq -r --arg p "$REACHABLE_POD" '[.pods[] | select(.id == $p)] | length' "$API_STATE")" = 1 ] \
  || fail "reachable recovery refusal deleted compute"
jq '(.pods[] | select(.id == $p)) |= (.remainingInitPolls = 999 | .status = "INITIALIZING" | .publicIp = null | .portMappings = null)' \
  --arg p "$REACHABLE_POD" "$API_STATE" > "$API_STATE.next" && mv "$API_STATE.next" "$API_STATE"
rp recover-stuck reachable --yes >/dev/null 2>&1 || fail "reachable fixture cleanup recovery failed"
rp destroy reachable --yes >/dev/null 2>&1 || fail "reachable fixture volume cleanup failed"
pass "recover-stuck probes a current-only endpoint and refuses SSH-reachable compute"

out=$(rp provision recorded --datacenter EU-RO-1 --size 50 \
  --code-origin https://example.test/firstmate.git 2>&1) \
  || fail "recorded-endpoint recovery fixture provision failed: $out"
out=$(FM_FAKE_BOOT_INCOMPLETE=1 FM_TEST_RUNPOD_POLL_INTERVAL=1 \
  FM_TEST_RUNPOD_WAKE_TIMEOUT=2 rp wake recorded 2>&1) \
  && fail "recorded-endpoint recovery fixture unexpectedly reached ready"
RECORDED_POD=$(record_field recorded pod_id)
RECORDED_HOST=$(record_field recorded endpoint_host)
RECORDED_PORT=$(record_field recorded endpoint_port)
[ -n "$RECORDED_HOST" ] && [ -n "$RECORDED_PORT" ] \
  || fail "recorded-endpoint recovery fixture did not retain its discovered endpoint"
jq '(.pods[] | select(.id == $p)) |= (.remainingInitPolls = 999 | .status = "INITIALIZING" | .publicIp = null | .portMappings = null)' \
  --arg p "$RECORDED_POD" "$API_STATE" > "$API_STATE.next" && mv "$API_STATE.next" "$API_STATE"
out=$(FM_FAKE_SSH_REACHABLE_HOST="$RECORDED_HOST" rp recover-stuck recorded --yes 2>&1) \
  && fail "recover-stuck terminated compute while its recorded endpoint was reachable"
assert_contains "$out" "recorded_endpoint=$RECORDED_HOST:$RECORDED_PORT recorded_ssh=reachable:ssh" \
  "recorded-endpoint reachability refusal did not print the endpoint evidence"
[ "$(jq -r --arg p "$RECORDED_POD" '[.pods[] | select(.id == $p)] | length' "$API_STATE")" = 1 ] \
  || fail "recorded-endpoint reachability refusal deleted compute"
out=$(FM_FAKE_SSH_INDETERMINATE_HOST="$RECORDED_HOST" rp recover-stuck recorded --yes 2>&1) \
  && fail "recover-stuck accepted an indeterminate recorded endpoint"
assert_contains "$out" "recorded_endpoint=$RECORDED_HOST:$RECORDED_PORT recorded_ssh=indeterminate:ssh-exit-42" \
  "indeterminate recorded-endpoint refusal did not print the safety evidence"
out=$(rp recover-stuck recorded --yes 2>&1) \
  && fail "recover-stuck treated SSH exit 255 as proof of unreachability"
assert_contains "$out" "recorded_endpoint=$RECORDED_HOST:$RECORDED_PORT recorded_ssh=indeterminate:ssh-exit-255" \
  "SSH exit 255 was not reported as indeterminate recorded-endpoint evidence"
[ "$(jq -r --arg p "$RECORDED_POD" '[.pods[] | select(.id == $p)] | length' "$API_STATE")" = 1 ] \
  || fail "SSH exit 255 ambiguity deleted compute"
jq 'del(.pods[] | select(.id == $p)) | del(.volumes[] | select(.id == $v))' \
  --arg p "$RECORDED_POD" --arg v "$(record_field recorded volume_id)" \
  "$API_STATE" > "$API_STATE.next" && mv "$API_STATE.next" "$API_STATE"
rm -f -- "$PARENT/data/runpod/recorded.meta" "$(fragment fm-sm-recorded-runpod)"
pass "recover-stuck prints recorded evidence and refuses reachable or SSH-255 ambiguity"

out=$(rp wake ios 2>&1) || fail "wake failed: $out"
assert_contains "$out" "ready: secondmate ios" "wake must report readiness"
[ "$(runpod_pod_count "$API_STATE")" = 1 ] || fail "wake must create exactly one pod"
[ "$(record_field ios lifecycle)" = ready ] || fail "wake must record the ready lifecycle"
[ "$(record_field ios compute)" = cpu ] || fail "wake must default to CPU compute"
[ "$(jq -r '.pods[0].imageName' "$API_STATE")" = runpod/base:1.0.7-dev-nix-ubuntu2204 ] \
  || fail "wake must request the pinned Ubuntu 22.04 image that satisfies the toolchain glibc floor"
FIRST_POD=$(record_field ios pod_id)
FIRST_HOST=$(record_field ios endpoint_host)
FIRST_PORT=$(record_field ios endpoint_port)
[ -n "$FIRST_HOST" ] && [ -n "$FIRST_PORT" ] || fail "wake must record the discovered endpoint"
assert_grep "HostName $FIRST_HOST" "$(fragment fm-sm-ios-runpod)" "the fragment must carry the pod HostName"
assert_grep "Port $FIRST_PORT" "$(fragment fm-sm-ios-runpod)" "the fragment must carry the pod Port"
assert_grep "HostKeyAlias fm-sm-ios-runpod" "$(fragment fm-sm-ios-runpod)" "the fragment must pin a stable HostKeyAlias"
assert_grep "StrictHostKeyChecking yes" "$(fragment fm-sm-ios-runpod)" "strict host-key checking must stay on"
assert_no_grep "StrictHostKeyChecking no" "$(fragment fm-sm-ios-runpod)" "host-key checking must never be disabled"
FIRST_KEY=$(grep '^fm-sm-ios-runpod ' "$PARENT/config/runpod/known_hosts")
assert_contains "$FIRST_KEY" "fm-sm-ios-runpod ssh-ed25519" "the host key must be pinned under the alias, not the IP"
pass "wake creates one pod on the glibc-compatible default image, discovers its endpoint, and pins a verified host key"

out=$(rp recover-stuck ios --yes 2>&1) \
  && fail "stuck recovery terminated a pod whose volume had already reached ready"
assert_contains "$out" "has reached ready before" \
  "the ready-provenance refusal must explain why unknown completion still applies"
[ "$(record_field ios pod_id)" = "$FIRST_POD" ] \
  || fail "a refused ready-provenance recovery changed the recorded pod"
[ "$(jq -r --arg p "$FIRST_POD" '[.pods[] | select(.id == $p)] | length' "$API_STATE")" = 1 ] \
  || fail "a refused ready-provenance recovery terminated live compute"
pass "stuck recovery never weakens unknown-completion safety after readiness"

stored_harness=$(record_field ios harness_npm)
out=$(rp provision ios --datacenter EU-RO-1 --size 100 --code-origin https://example.test/firstmate.git 2>&1) \
  && fail "reprovision must reject a live configured-to-unset harness change"
assert_contains "$out" "sleep" "a live boot-contract refusal must name the required lifecycle step"
[ "$(record_field ios harness_npm)" = "$stored_harness" ] \
  || fail "a refused live harness change must preserve the recorded contract"
pass "live pods reject configured-to-unset boot-contract changes"

out=$(rp provision ios --alias fm-sm-ios-new --datacenter EU-RO-1 --code-origin https://example.test/firstmate.git --harness-npm @example/harness 2>&1) \
  && fail "reprovision must reject reassignment of an existing SSH alias"
assert_contains "$out" "already owns SSH alias fm-sm-ios-runpod" "the refusal must name the existing alias"
[ "$(record_field ios ssh_alias)" = fm-sm-ios-runpod ] || fail "a refused alias reassignment must preserve the record"
assert_present "$(fragment fm-sm-ios-runpod)" "a refused alias reassignment must preserve the old SSH fragment"
assert_absent "$(fragment fm-sm-ios-new)" "a refused alias reassignment must not create a new SSH fragment"
[ "$(grep '^fm-sm-ios-runpod ' "$PARENT/config/runpod/known_hosts")" = "$FIRST_KEY" ] \
  || fail "a refused alias reassignment must preserve the pinned host identity"
pass "reprovision cannot leave stale identity by reassigning an alias"

runpod_seed_remote_route "$PARENT" dot fm.ios /srv/firstmate /srv/sm-dot
printf 'fmXios ssh-ed25519 AAAAconfusing\n' >> "$PARENT/config/runpod/known_hosts"
out=$(rp provision dot --datacenter EU-RO-1 --size 20 --code-origin https://example.test/firstmate.git 2>&1) || fail "dot-alias provision failed: $out"
out=$(rp wake dot 2>&1) || fail "dot-alias wake failed: $out"
[ "$(awk '$1 == "fm.ios" { count++ } END { print count + 0 }' "$PARENT/config/runpod/known_hosts")" = 1 ] \
  || fail "a regex-like alias must be pinned despite a similar literal entry"
rp sleep dot >/dev/null 2>&1 || fail "could not suspend the dot-alias second mate"
grep -v '^- dot ' "$PARENT/data/secondmates.md" > "$PARENT/data/secondmates.next"
mv -f "$PARENT/data/secondmates.next" "$PARENT/data/secondmates.md"
rp destroy dot --yes >/dev/null 2>&1 || fail "could not destroy the dot-alias second mate"
assert_grep 'fmXios ' "$PARENT/config/runpod/known_hosts" "literal alias cleanup must preserve a similar entry"
[ "$(awk '$1 == "fm.ios" { count++ } END { print count + 0 }' "$PARENT/config/runpod/known_hosts")" = 0 ] \
  || fail "literal alias cleanup must remove the exact entry"
pass "known_hosts aliases are matched and removed literally"

before=$(runpod_api_calls "$API_LOG" "POST /pods")
out=$(rp wake ios 2>&1) || fail "second wake failed: $out"
[ "$(runpod_api_calls "$API_LOG" "POST /pods")" = "$before" ] || fail "a repeated wake must not create a second pod"
[ "$(record_field ios pod_id)" = "$FIRST_POD" ] || fail "a repeated wake must keep the same pod"
pass "wake is idempotent for an already-running pod"

# --- the readiness check defaults to the parity verdict ---------------------
#
# Every RunPod host is provisioned for full local-second-mate parity, so its own
# readiness check must report against that contract rather than the minimum
# every remote host shares.

: > "$REMOTE_LOG"
rp doctor ios >/dev/null 2>&1 || fail "the readiness check failed on a live pod"
assert_grep 'fm-remote-doctor.sh --parity' "$REMOTE_LOG" \
  "the RunPod readiness check did not default to the parity verdict"
: > "$REMOTE_LOG"
rp doctor ios --fix >/dev/null 2>&1 || fail "the readiness repair failed on a live pod"
assert_grep 'fm-remote-doctor.sh --fix' "$REMOTE_LOG" \
  "an explicit readiness argument was not passed through"
assert_no_grep '--parity' "$REMOTE_LOG" \
  "an explicit readiness argument was silently extended with the parity tier"
pass "the RunPod readiness check defaults to parity and passes explicit arguments through"

# --- concurrent wake --------------------------------------------------------

rp sleep ios >/dev/null 2>&1 || fail "could not suspend before the concurrency case"
before=$(runpod_api_calls "$API_LOG" "POST /pods")
rp wake ios >"$TMP_ROOT/wake.a" 2>&1 &
wake_a=$!
rp wake ios >"$TMP_ROOT/wake.b" 2>&1 &
wake_b=$!
wait "$wake_a" || fail "concurrent wake A failed: $(cat "$TMP_ROOT/wake.a")"
wait "$wake_b" || fail "concurrent wake B failed: $(cat "$TMP_ROOT/wake.b")"
created=$(( $(runpod_api_calls "$API_LOG" "POST /pods") - before ))
[ "$created" = 1 ] || fail "two concurrent wakes created $created pods; the lifecycle lock must admit exactly one"
[ "$(runpod_pod_count "$API_STATE")" = 1 ] || fail "two concurrent wakes must leave exactly one live pod"
pass "two concurrent wakes create exactly one pod"

# --- initialization polling -------------------------------------------------

rp sleep ios >/dev/null 2>&1 || fail "could not suspend before the initialization case"
out=$(FM_FAKE_RUNPOD_INIT_POLLS=3 rp wake ios 2>&1) || fail "wake through initialization failed: $out"
[ "$(record_field ios lifecycle)" = ready ] || fail "wake must wait out pod initialization"
[ -n "$(record_field ios endpoint_host)" ] || fail "wake must record the endpoint published after initialization"
pass "wake waits for a pod that publishes its endpoint late"

# --- endpoint refresh and stable SSH identity -------------------------------

SECOND_POD=$(record_field ios pod_id)
[ "$SECOND_POD" != "$FIRST_POD" ] || fail "the fixture must have replaced the pod"
SECOND_HOST=$(record_field ios endpoint_host)
[ "$SECOND_HOST" != "$FIRST_HOST" ] || fail "the fixture must have moved the endpoint"
assert_grep "HostName $SECOND_HOST" "$(fragment fm-sm-ios-runpod)" "wake must refresh the fragment HostName"
assert_no_grep "HostName $FIRST_HOST" "$(fragment fm-sm-ios-runpod)" "the stale HostName must be gone"
[ "$(grep '^fm-sm-ios-runpod ' "$PARENT/config/runpod/known_hosts")" = "$FIRST_KEY" ] \
  || fail "the pinned host key must survive pod replacement unchanged"
pass "a replaced pod refreshes the alias endpoint and keeps the same verified host identity"

# --- CPU/GPU exclusivity ----------------------------------------------------

out=$(rp wake ios --gpu 2>&1) && fail "waking a live CPU second mate as GPU must be refused"
assert_contains "$out" "already has a cpu pod" "the refusal must name the conflicting compute type"
[ "$(runpod_pod_count "$API_STATE")" = 1 ] || fail "a refused GPU wake must not create a pod"
pass "one second mate cannot hold a CPU and a GPU pod at the same time"

# --- container disk stays inside the provider's hard limit -------------------
#
# A real pilot pod creation was refused with HTTP 500 "Container Disk must be
# less than or equal to 40" because the create body asked for 50, which the
# earlier double accepted. The double now enforces that limit, so these cases
# fail if either pod body regresses past it.

disk=$(jq -r '[.pods[] | .containerDiskInGb // 40] | max // 40' "$API_STATE" 2>/dev/null)
[ -n "$disk" ] || disk=40
[ "$disk" -le 40 ] || fail "a created pod asked for ${disk}GB of container disk, above the provider's 40GB limit"
pass "created pods stay inside the provider's container-disk limit"

# --- GPU selection ----------------------------------------------------------

rp sleep ios >/dev/null 2>&1 || fail "could not suspend before the GPU cases"
out=$(rp wake ios --gpu --min-vram 500 2>&1) && fail "an unsatisfiable VRAM floor must be refused"
assert_contains "$out" "--gpu-type" "the refusal must name the exact way to place it anyway"
[ "$(runpod_pod_count "$API_STATE")" = 0 ] || fail "an unsatisfiable VRAM floor must not rent anything"

out=$(rp wake ios --gpu --min-vram 80 2>&1) || fail "GPU wake failed: $out"
[ "$(record_field ios compute)" = gpu ] || fail "a GPU wake must record GPU compute"
requested=$(jq -r '[.pods[] | select(.computeType == "GPU")][0].requestedGpuTypeIds | join(",")' "$API_STATE")
assert_contains "$requested" "NVIDIA H100" "an 80GB floor must offer the 80GB class"
assert_not_contains "$requested" "NVIDIA L4," "an 80GB floor must not offer a 24GB card"
assert_not_contains "$requested" "Tesla T4" "an 80GB floor must not offer a 16GB card"
pass "a VRAM floor narrows GPU candidates and fails closed rather than renting something smaller"

rp sleep ios >/dev/null 2>&1 || fail "could not suspend before the explicit GPU case"
out=$(rp wake ios --gpu --gpu-type 'NVIDIA L4' 2>&1) || fail "explicit GPU wake failed: $out"
requested=$(jq -r '[.pods[] | select(.computeType == "GPU")][0].requestedGpuTypeIds | join(",")' "$API_STATE")
[ "$requested" = "NVIDIA L4" ] || fail "an explicit --gpu-type must be the only candidate, got: $requested"
pass "an explicit GPU type overrides the VRAM filter entirely"

rp sleep ios >/dev/null 2>&1 || fail "could not suspend after the GPU cases"
rp wake ios >/dev/null 2>&1 || fail "could not return to CPU after the GPU cases"

# --- one volume backs at most one live pod ----------------------------------

out=$(rp provision web --datacenter EU-RO-1 --size 50 --code-origin https://example.test/firstmate.git 2>&1) || fail "web provision failed: $out"
IOS_VOLUME=$(record_field ios volume_id)
WEB_VOLUME=$(record_field web volume_id)
sed -i.bak "s/^volume_id=.*/volume_id=$IOS_VOLUME/" "$PARENT/data/runpod/web.meta"
rm -f "$PARENT/data/runpod/web.meta.bak"
out=$(rp wake web 2>&1) && fail "activating a volume that already backs a live pod must be refused"
assert_contains "$out" "already owned by secondmate ios" "wake must recheck local volume ownership before activation"
pass "wake rejects a volume record owned by another second mate"

# --- multiple distinct second mates -----------------------------------------

sed -i.bak "s/^volume_id=.*/volume_id=/" "$PARENT/data/runpod/web.meta"
rm -f "$PARENT/data/runpod/web.meta.bak"
rm -f "$PARENT/data/runpod/web.meta"
jq 'del(.volumes[] | select(.id == $v))' --arg v "$WEB_VOLUME" "$API_STATE" > "$API_STATE.next" \
  && mv "$API_STATE.next" "$API_STATE"
out=$(rp provision web --datacenter EU-RO-1 --size 50 --code-origin https://example.test/firstmate.git 2>&1) || fail "web reprovision failed: $out"
sed -i.bak 's/^ssh_alias=.*/ssh_alias=fm-sm-ios-runpod/' "$PARENT/data/runpod/web.meta"
rm -f "$PARENT/data/runpod/web.meta.bak"
sed -i.bak '/^- web / s/host: fm-sm-web-runpod/host: fm-sm-ios-runpod/' "$PARENT/data/secondmates.md"
rm -f "$PARENT/data/secondmates.md.bak"
out=$(rp wake web 2>&1) && fail "wake must reject an SSH alias owned by another second mate"
assert_contains "$out" "already owned by secondmate ios" "wake must recheck alias ownership before activation"
sed -i.bak 's/^ssh_alias=.*/ssh_alias=fm-sm-web-runpod/' "$PARENT/data/runpod/web.meta"
rm -f "$PARENT/data/runpod/web.meta.bak"
sed -i.bak '/^- web / s/host: fm-sm-ios-runpod/host: fm-sm-web-runpod/' "$PARENT/data/secondmates.md"
rm -f "$PARENT/data/secondmates.md.bak"
rp sleep ios >/dev/null 2>&1 || fail "could not suspend ios before concurrent distinct wakes"
awk '$1 != "fm-sm-ios-runpod"' "$PARENT/config/runpod/known_hosts" > "$PARENT/config/runpod/known_hosts.next"
mv -f "$PARENT/config/runpod/known_hosts.next" "$PARENT/config/runpod/known_hosts"
KEYSCAN_BARRIER="$TMP_ROOT/keyscan-barrier"
mkdir -p "$KEYSCAN_BARRIER"
FM_FAKE_KEYSCAN_BARRIER_DIR="$KEYSCAN_BARRIER" rp wake ios > "$TMP_ROOT/wake-ios.out" 2>&1 &
wake_ios=$!
FM_FAKE_KEYSCAN_BARRIER_DIR="$KEYSCAN_BARRIER" rp wake web > "$TMP_ROOT/wake-web.out" 2>&1 &
wake_web=$!
wait "$wake_ios" || fail "concurrent ios wake failed: $(cat "$TMP_ROOT/wake-ios.out")"
wait "$wake_web" || fail "concurrent web wake failed: $(cat "$TMP_ROOT/wake-web.out")"
assert_grep 'fm-sm-ios-runpod ' "$PARENT/config/runpod/known_hosts" "concurrent pinning must retain the ios alias"
assert_grep 'fm-sm-web-runpod ' "$PARENT/config/runpod/known_hosts" "concurrent pinning must retain the web alias"
[ "$(runpod_pod_count "$API_STATE")" = 2 ] || fail "two distinct second mates must hold two pods"
[ "$(record_field ios pod_id)" != "$(record_field web pod_id)" ] || fail "two second mates must not share a pod"
[ "$(record_field ios volume_id)" != "$(record_field web volume_id)" ] || fail "two second mates must not share a volume"
[ "$(record_field ios ssh_alias)" != "$(record_field web ssh_alias)" ] || fail "two second mates must not share an SSH alias"
pass "several RunPod second mates run concurrently with separate pods, volumes, and aliases"

# --- sleep guards -----------------------------------------------------------

out=$(FM_FAKE_REMOTE_CHILDREN=3 rp sleep ios 2>&1) && fail "sleep must refuse while the host supervises work"
assert_contains "$out" "still supervises 3 worker(s)" "the refusal must name the outstanding remote work"
[ "$(record_field ios lifecycle)" = ready ] || fail "a refused sleep must leave the second mate awake"
[ "$(runpod_pod_count "$API_STATE")" = 2 ] || fail "a refused sleep must not terminate the pod"
pass "a pending crewmate on the remote host blocks sleep"

mkdir -p "$PARENT/state/pending-replies"
printf 'task_id=ios\nphase=delivered\ncorr=00112233445566aa\n' > "$PARENT/state/pending-replies/00112233445566aa"
out=$(rp sleep ios 2>&1) && fail "sleep must refuse while a routed reply is unresolved"
assert_contains "$out" "unresolved routed reply" "the refusal must name the outstanding reply"
printf 'task_id=ios\nphase=resolved\ncorr=00112233445566aa\n' > "$PARENT/state/pending-replies/00112233445566aa"
pass "an unresolved routed reply blocks sleep"

# A handled recovery reply may have landed after its recovery delivery failed,
# while an older release left a keyless blocker open. Sleep reconciles both and
# safely tears down a finished direct-PR child before evaluating child count.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
recovery_corr=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios "handled recovery") \
  || fail "could not create the recovery reconciliation fixture"
fm_pending_reply_mark_delivered "$PARENT/state" "$recovery_corr"
recovery_rec=$(fm_pending_reply_path "$PARENT/state" "$recovery_corr")
fm_pending_reply_set "$recovery_rec" recovery_delivery_outcome failed
fm_pending_reply_set "$recovery_rec" phase escalated
printf 'blocked: pending-reply-recovery-delivery-failed: task=ios pending-reply-id=%s request=handled recovery\n' \
  "$recovery_corr" >> "$PARENT/state/ios.status"
printf 'done [corr=%s]: fetched handled reply\n' "$recovery_corr" >> "$PARENT/state/ios.status"
REMOTE_CHILDREN_FILE="$TMP_ROOT/remote-children"
printf '1\n' > "$REMOTE_CHILDREN_FILE"
IOS_POD=$(record_field ios pod_id)
out=$(FM_FAKE_REMOTE_CHILDREN_FILE="$REMOTE_CHILDREN_FILE" FM_FAKE_DELIVERED_DIRECT_PR=1 \
  FM_FAKE_RUNPOD_FAIL="DELETE /pods/$IOS_POD" rp sleep ios 2>&1) \
  && fail "the injected pod termination failure should still abort sleep"
assert_contains "$out" "terminate pod $IOS_POD" \
  "sleep did not pass reconciliation and reach the injected provider failure"
[ "$(fm_pending_reply_get "$recovery_rec" phase)" = resolved ] \
  || fail "sleep did not resolve the handled recovery-delivery-failed reply"
[ -z "$(status_open_decisions "$PARENT/state/ios.status")" ] \
  || fail "sleep did not close the exact legacy keyless reply blocker"
[ "$(cat "$REMOTE_CHILDREN_FILE")" = 0 ] \
  || fail "sleep did not tear down the delivered direct-PR child"
pass "sleep reconciles handled recovery replies and delivered direct-PR children"

printf 'needs-decision [key=ios-storage]: pick the storage tier\n' >> "$PARENT/state/ios.status"
out=$(rp sleep ios 2>&1) && fail "sleep must refuse while a decision is open"
assert_contains "$out" "unresolved decisions" "the refusal must name the open decision"
printf 'resolved [key=ios-storage]: standard tier\n' >> "$PARENT/state/ios.status"
pass "an unresolved decision blocks sleep"

mkdir -p "$PARENT/data/handoff"
printf -- '- [ ] ios-1 - queued work\n' > "$PARENT/data/handoff/ios.outbox.md"
out=$(rp sleep ios 2>&1) && fail "sleep must refuse while a backlog handoff is undelivered"
assert_contains "$out" "undelivered backlog handoff" "the refusal must name the outbox"
rm -f "$PARENT/data/handoff/ios.outbox.md"
pass "an unfinished backlog outbox blocks sleep"

out=$(FM_FAKE_CHILDREN_MODE=unreachable rp sleep ios 2>&1) && fail "sleep must refuse on unknown remote completion"
assert_contains "$out" "unreachable" "an unknown remote state must be reported as unknown, not assumed idle"
[ "$(record_field ios lifecycle)" = ready ] || fail "an unknown-completion sleep must leave the route untouched"
[ "$(runpod_pod_count "$API_STATE")" = 2 ] || fail "an unknown-completion sleep must not terminate the pod"
pass "unknown remote completion blocks sleep and preserves everything"

SID=$(PATH="$FAKEBIN:$PATH" FM_HOME="$PARENT" \
  "$ROOT/bin/fm-procevent-remote-reply.sh" source-id ios)
mkdir -p "$PARENT/state/procevent-inbox"
printf 'captured reply\n' > "$PARENT/state/procevent-inbox/$SID.99.result"
printf 'remote-reply\n' > "$PARENT/state/procevent-inbox/$SID.99.adapter"
out=$(rp sleep ios 2>&1) && fail "sleep must refuse an unhandled captured reply"
assert_contains "$out" "unhandled captured reply" "the quiesce refusal must remain actionable"
[ "$(record_field ios lifecycle)" = ready ] || fail "a quiesce refusal must restore ready lifecycle"
assert_present "$PARENT/state/procevent/$SID.source" \
  "a quiesce refusal must re-arm the reply source"
rm -f "$PARENT/state/procevent-inbox/$SID.99.result" "$PARENT/state/procevent-inbox/$SID.99.adapter"
pass "a refused quiesce restores ready state and re-arms replies"

out=$(FM_FAKE_RUNPOD_RECORD_FAIL=suspending rp sleep ios 2>&1) \
  && fail "sleep must refuse when the suspending lifecycle cannot be recorded"
assert_contains "$out" "could not record its suspending lifecycle" "the transition failure must remain actionable"
[ "$(record_field ios lifecycle)" = ready ] || fail "a failed suspending transition must preserve ready lifecycle"
assert_present "$PARENT/state/procevent/$SID.source" \
  "a failed suspending transition must re-arm the reply source"
pass "a failed suspending transition restores ready state and replies"

IOS_POD=$(record_field ios pod_id)
out=$(FM_FAKE_RUNPOD_FAIL="DELETE /pods/$IOS_POD" rp sleep ios 2>&1) \
  && fail "sleep must report a refused pod termination"
assert_contains "$out" "terminate pod $IOS_POD" "the termination failure must remain actionable"
[ "$(record_field ios lifecycle)" = ready ] || fail "a failed pod termination must restore ready before re-arming"
assert_present "$PARENT/state/procevent/$SID.source" \
  "a failed pod termination must re-arm the reply source after restoring ready"
[ "$(record_field ios pod_id)" = "$IOS_POD" ] || fail "a failed pod termination must retain the live pod record"
pass "a failed pod termination restores ready state before replies"

# --- sleep ------------------------------------------------------------------

IOS_VOLUME=$(record_field ios volume_id)
out=$(rp sleep ios 2>&1) || fail "sleep failed: $out"
assert_contains "$out" "suspended: secondmate ios" "sleep must report the suspension"
[ "$(record_field ios lifecycle)" = suspended ] || fail "sleep must record the suspended lifecycle"
[ -z "$(record_field ios pod_id)" ] || fail "sleep must clear the terminated pod"
[ -z "$(record_field ios endpoint_host)" ] || fail "sleep must clear the stale endpoint"
[ "$(record_field ios volume_id)" = "$IOS_VOLUME" ] || fail "sleep must retain the network volume"
[ "$(jq -r --arg v "$IOS_VOLUME" '[.volumes[] | select(.id == $v)] | length' "$API_STATE")" = 1 ] \
  || fail "sleep must not delete the network volume"
assert_grep "- ios - " "$PARENT/data/secondmates.md" "sleep must preserve the secondmate route"
assert_present "$PARENT/state/ios.meta" "sleep must preserve the secondmate task record"
pass "sleep terminates the pod, retains the volume, and never retires the second mate"

out=$(rp sleep ios 2>&1) || fail "a repeated sleep failed: $out"
assert_contains "$out" "already-suspended" "a repeated sleep must be a clean no-op"
pass "sleep is idempotent"

# --- wake restores ----------------------------------------------------------

out=$(rp wake ios 2>&1) || fail "wake after sleep failed: $out"
[ "$(record_field ios lifecycle)" = ready ] || fail "wake must restore the second mate"
[ -n "$(record_field ios pod_id)" ] || fail "wake must record the restored pod"
[ "$(record_field ios volume_id)" = "$IOS_VOLUME" ] || fail "wake must reattach the retained volume"
[ "$(grep '^fm-sm-ios-runpod ' "$PARENT/config/runpod/known_hosts")" = "$FIRST_KEY" ] \
  || fail "the restored second mate must keep its pinned host identity"
pass "wake restores a suspended second mate onto its retained volume"

# --- status and cost --------------------------------------------------------

out=$(rp status 2>&1) || fail "status failed: $out"
assert_contains "$out" "ios lifecycle=ready" "status must report each managed second mate"
assert_contains "$out" "web lifecycle=ready" "status must report every managed second mate"
out=$(rp cost ios 2>&1) || fail "cost failed: $out"
assert_contains "$out" "volume_usd_per_month=7.00" "cost must price 100 GB of standard storage at 0.07/GB/month"
assert_contains "$out" "idle_usd_per_month=7.00" "cost must state the scale-to-zero idle cost"
assert_contains "$out" "compute_usd_per_hour=" "cost must report the live pod's hourly rate"
assert_contains "$out" "pod_uptime_hours=" "cost must report pod uptime"
pass "status and cost report the placement, the idle storage cost, and the live compute rate"

# --- destroy ----------------------------------------------------------------

out=$(rp destroy ios 2>&1) && fail "destroy without --yes must be refused"
assert_contains "$out" "captain's explicit word" "destroy must require explicit authority"
out=$(rp destroy ios --yes 2>&1) && fail "destroy must refuse while the route is registered"
assert_contains "$out" "fm-teardown.sh ios" "destroy must point at the guarded retirement path first"
[ "$(jq -r --arg v "$IOS_VOLUME" '[.volumes[] | select(.id == $v)] | length' "$API_STATE")" = 1 ] \
  || fail "a refused destroy must not delete the volume"

rp sleep ios >/dev/null 2>&1 || fail "could not suspend before retirement"
out=$(rp destroy ios --yes 2>&1) && fail "destroy must still refuse a registered route once suspended"
assert_contains "$out" "fm-teardown.sh ios" "retirement, not suspension, is what releases a route for destroy"

# Retirement is bin/fm-teardown.sh's job; this stands in for its registry effect.
grep -v '^- ios ' "$PARENT/data/secondmates.md" > "$PARENT/data/secondmates.next"
mv -f "$PARENT/data/secondmates.next" "$PARENT/data/secondmates.md"
sed -i.bak 's/^ssh_alias=.*/ssh_alias=fm-sm-ios-runpod/' "$PARENT/data/runpod/web.meta"
rm -f "$PARENT/data/runpod/web.meta.bak"
out=$(rp destroy ios --yes 2>&1) && fail "destroy must reject an SSH alias owned by another record"
assert_contains "$out" "already owned by secondmate web" "destroy must recheck alias ownership before cleanup"
sed -i.bak 's/^ssh_alias=.*/ssh_alias=fm-sm-web-runpod/' "$PARENT/data/runpod/web.meta"
rm -f "$PARENT/data/runpod/web.meta.bak"
out=$(rp destroy ios --yes 2>&1) || fail "destroy failed: $out"
[ "$(jq -r --arg v "$IOS_VOLUME" '[.volumes[] | select(.id == $v)] | length' "$API_STATE")" = 0 ] \
  || fail "destroy must delete the network volume"
assert_absent "$PARENT/data/runpod/ios.meta" "destroy must remove the local record"
assert_absent "$(fragment fm-sm-ios-runpod)" "destroy must remove the generated SSH fragment"
assert_no_grep 'fm-sm-ios-runpod ' "$PARENT/config/runpod/known_hosts" \
  "destroy must remove the alias's exact pinned host-key entries"
pass "destroy is a separate, explicitly authorized path that runs only after suspension and retirement"

# A retired route has no remote home left to supervise anything, so suspending
# it needs no host probe - but a live pod still blocks destroy.
grep -v '^- web ' "$PARENT/data/secondmates.md" > "$PARENT/data/secondmates.next"
mv -f "$PARENT/data/secondmates.next" "$PARENT/data/secondmates.md"
WEB_VOLUME=$(record_field web volume_id)
out=$(rp destroy web --yes 2>&1) && fail "destroy must refuse while a pod is still running"
assert_contains "$out" "fm-runpod.sh sleep web" "destroy must require suspension first"
[ "$(jq -r --arg v "$WEB_VOLUME" '[.volumes[] | select(.id == $v)] | length' "$API_STATE")" = 1 ] \
  || fail "a destroy refused for a live pod must not delete the volume"
out=$(rp sleep web 2>&1) || fail "suspending a retired route failed: $out"
out=$(rp destroy web --yes 2>&1) || fail "destroy of a retired, suspended second mate failed: $out"
[ "$(runpod_pod_count "$API_STATE")" = 0 ] || fail "no pod may survive the last destroy"
[ "$(runpod_volume_count "$API_STATE")" = 0 ] || fail "no volume may survive the last destroy"
pass "a live pod blocks destroy, and a retired second mate suspends without probing a host it no longer has"

# --- the API boundary is the only RunPod dependency -------------------------

[ "$(runpod_api_calls "$API_LOG" "POST /pods")" -gt 0 ] || fail "the fixture never observed a pod creation"
assert_no_grep rp_fixture_key "$API_LOG" "the API key must never reach the request log"
pass "every RunPod interaction went through the one mocked boundary"

# --- legacy empty-origin wake admission ------------------------------------

runpod_seed_remote_route "$PARENT" never fm-sm-never-runpod /srv/firstmate /srv/sm-never
out=$(rp provision never --datacenter EU-RO-1 --code-origin https://example.test/firstmate.git 2>&1) \
  || fail "never-ready fixture provision failed: $out"
sed -i.bak 's/^code_origin=.*/code_origin=/' "$PARENT/data/runpod/never.meta"
rm -f "$PARENT/data/runpod/never.meta.bak"
: > "$API_LOG"
out=$(rp wake never 2>&1) && fail "a never-ready volume woke without a recorded code origin"
assert_contains "$out" "secondmate never" "the wake refusal must name the affected second mate"
assert_contains "$out" "fm-runpod.sh provision never --code-origin <git-url>" \
  "the wake refusal must give the exact repair command"
[ ! -s "$API_LOG" ] || fail "a never-ready empty-origin volume must refuse before every provider call"
pass "never-ready empty-origin volumes refuse before provider access"

out=$(rp provision slept --datacenter EU-RO-1 --code-origin https://example.test/firstmate.git 2>&1) \
  || fail "pre-ready sleep fixture provision failed: $out"
sed -i.bak 's/^code_origin=.*/code_origin=/' "$PARENT/data/runpod/slept.meta"
rm -f "$PARENT/data/runpod/slept.meta.bak"
out=$(rp sleep slept 2>&1) || fail "sleeping a never-woken route failed: $out"
[ "$(record_field slept lifecycle)" = provisioned ] \
  || fail "sleep must preserve the never-ready lifecycle distinction"
: > "$API_LOG"
out=$(rp wake slept 2>&1) && fail "a slept-but-never-ready empty-origin volume woke"
assert_contains "$out" "fm-runpod.sh provision slept --code-origin <git-url>" \
  "the slept never-ready refusal must retain the repair command"
[ ! -s "$API_LOG" ] || fail "a slept never-ready empty-origin volume must refuse before every provider call"
pass "sleep preserves never-ready empty-origin wake refusal"

runpod_seed_remote_route "$PARENT" legacy fm-sm-legacy-runpod /srv/firstmate /srv/sm-legacy
out=$(rp provision legacy --datacenter EU-RO-1 --code-origin https://example.test/firstmate.git 2>&1) \
  || fail "legacy fixture provision failed: $out"
out=$(rp wake legacy 2>&1) || fail "legacy fixture did not genuinely reach ready: $out"
[ "$(record_field legacy ever_ready)" = 1 ] \
  || fail "a genuinely ready volume must latch its readiness provenance"
sed -i.bak '/^ever_ready=/d' "$PARENT/data/runpod/legacy.meta"
rm -f "$PARENT/data/runpod/legacy.meta.bak"
sed -i.bak 's/^code_origin=.*/code_origin=/' "$PARENT/data/runpod/legacy.meta"
rm -f "$PARENT/data/runpod/legacy.meta.bak"
out=$(rp wake legacy 2>&1) || fail "a pre-latch ready record with an empty origin did not wake: $out"
[ "$(record_field legacy ever_ready)" = 1 ] \
  || fail "a pre-existing ready record must migrate its durable readiness evidence"
out=$(rp sleep legacy 2>&1) || fail "legacy fixture did not suspend after readiness: $out"
: > "$API_LOG"
out=$(rp wake legacy 2>&1) || fail "a previously-ready legacy volume with an empty origin did not wake: $out"
assert_contains "$out" "ready: secondmate legacy" "a prior-ready legacy route must continue through normal wake"
[ "$(runpod_api_calls "$API_LOG" "POST /pods")" = 1 ] \
  || fail "a prior-ready legacy route must be allowed to rent its replacement pod"
pass "previously-ready empty-origin volumes remain wakeable"

runpod_seed_remote_route "$PARENT" resilient fm-sm-resilient-runpod /srv/firstmate /srv/sm-resilient
out=$(rp provision resilient --datacenter EU-RO-1 --code-origin https://example.test/firstmate.git 2>&1) \
  || fail "interrupted-wake fixture provision failed: $out"
out=$(rp wake resilient 2>&1) || fail "interrupted-wake fixture did not genuinely reach ready: $out"
sed -i.bak 's/^code_origin=.*/code_origin=/' "$PARENT/data/runpod/resilient.meta"
rm -f "$PARENT/data/runpod/resilient.meta.bak"
out=$(rp sleep resilient 2>&1) || fail "interrupted-wake fixture did not suspend: $out"
out=$(FM_FAKE_SSH_PROBE_BLOCK=1 FM_TEST_RUNPOD_POLL_INTERVAL=1 \
  FM_TEST_RUNPOD_WAKE_TIMEOUT=4 rp wake resilient 2>&1) \
  && fail "replacement wake unexpectedly reached readiness"
assert_contains "$out" "SSH bootstrap did not complete" \
  "the replacement wake fixture must fail before readiness"
out=$(rp sleep resilient 2>&1) || fail "sleep after the interrupted replacement wake failed: $out"
[ "$(record_field resilient ever_ready)" = 1 ] \
  || fail "sleep after an interrupted wake must preserve readiness provenance"
: > "$API_LOG"
out=$(rp wake resilient 2>&1) \
  || fail "a prior-ready empty-origin volume did not recover after an interrupted replacement wake: $out"
assert_contains "$out" "ready: secondmate resilient" \
  "the readiness latch must admit a later replacement wake"
[ "$(runpod_api_calls "$API_LOG" "POST /pods")" = 1 ] \
  || fail "the recovered route must create exactly one replacement pod"
pass "readiness provenance survives interrupted replacement wakes"

runpod_seed_remote_route "$PARENT" sourced fm-sm-sourced-runpod /srv/firstmate /srv/sm-sourced
out=$(rp provision sourced --datacenter EU-RO-1 --code-origin https://example.test/firstmate.git 2>&1) \
  || fail "recorded-origin fixture provision failed: $out"
: > "$API_LOG"
out=$(rp wake sourced 2>&1) || fail "a never-ready volume with a recorded origin did not wake: $out"
assert_contains "$out" "ready: secondmate sourced" "a recorded origin must permit wake regardless of lifecycle history"
[ "$(runpod_api_calls "$API_LOG" "POST /pods")" = 1 ] \
  || fail "a recorded-origin route must create its pod normally"
pass "recorded origins wake regardless of readiness history"
