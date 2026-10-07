#!/usr/bin/env bash
# Opt-in idle auto-sleep for Boat and RunPod placements. The provider sleep
# commands and the remote control reads are fakes in a copy of bin/, so this
# owns only fm-idle-sleep.sh's decisions: who is a candidate, what blocks an
# attempt, that the guarded sleep is called exactly once and never forced, and
# that a refusal is reported once. The guards themselves are owned by
# tests/fm-boat-lifecycle.test.sh and tests/fm-runpod-lifecycle.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-sleep)
BIN="$TMP_ROOT/bin"
HOME_DIR="$TMP_ROOT/home"
FAKE="$TMP_ROOT/fake"
DATA="$HOME_DIR/data"
STATE="$HOME_DIR/state"
CONFIG="$HOME_DIR/config"
mkdir -p "$DATA/boat" "$DATA/runpod" "$STATE" "$CONFIG" "$FAKE"
cp -R "$ROOT/bin" "$BIN"

printf 'idle\n' > "$FAKE/observe"
printf '0\n' > "$FAKE/children"
printf '0\n' > "$FAKE/sleep-rc"
printf 'error: undelivered backlog handoff\n' > "$FAKE/sleep-msg"
: > "$FAKE/calls"

cat > "$BIN/fm-on.sh" <<SH
#!/usr/bin/env bash
printf 'on %s\n' "\$*" >> "$FAKE/calls"
case "\$3" in
  observe) cat "$FAKE/observe" ;;
  sleep-reconcile) exit 0 ;;
  children)
    if [ -f "$FAKE/activity-on-children" ]; then
      touch "$STATE/\$1.status"
    fi
    printf 'children=%s\n' "\$(cat "$FAKE/children")" ;;
  *) exit 64 ;;
esac
SH
for provider in boat runpod; do
  cat > "$BIN/fm-$provider.sh" <<SH
#!/usr/bin/env bash
printf '$provider %s\n' "\$*" >> "$FAKE/calls"
[ "\$1" = sleep ] || exit 64
rc=\$(cat "$FAKE/sleep-rc")
if [ "\$rc" != 0 ]; then cat "$FAKE/sleep-msg" >&2; exit "\$rc"; fi
printf 'lifecycle=suspended\n' > "$DATA/$provider/\$2.meta"
SH
done
chmod +x "$BIN/fm-on.sh" "$BIN/fm-boat.sh" "$BIN/fm-runpod.sh"

ids=(ios web)
for id in "${ids[@]}"; do
  printf -- '- %s - %s domain. (host: fm-sm-%s; root: /srv/fm; home: /srv/sm-%s; scope: %s work; projects: alpha; added 2026-08-12)\n' \
    "$id" "$id" "$id" "$id" "$id" >> "$DATA/secondmates.md"
done
printf 'lifecycle=ready\n' > "$DATA/boat/ios.meta"
printf 'lifecycle=ready\n' > "$DATA/runpod/web.meta"
printf 'ios 2\nweb\n' > "$CONFIG/idle-sleep"

idle_env() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
  FM_IDLE_SLEEP_UNIT_SECONDS=1 FM_IDLE_SLEEP_DEFAULT_MINUTES=2 \
  FM_IDLE_SLEEP_TICK_SECONDS=0 FM_IDLE_SLEEP_ATTEMPT_SECONDS=0 "$@"
}
idle() { idle_env "$BIN/fm-idle-sleep.sh" "$@"; }
age_everything() { # backdate every record the activity scan reads, plus the attempt marker
  find "$STATE" "$DATA" -type f ! -name '*.lock' -exec perl -e 'utime(time-3600,time-3600,@ARGV)' {} +
}
wait_for_calls() { # <expected line count>
  local n=60
  while [ "$n" -gt 0 ]; do
    [ "$(grep -c . "$FAKE/calls")" -ge "$1" ] && return 0
    n=$((n - 1)); sleep 0.1
  done
  return 1
}
sleep_calls() { grep -c -E '^(boat|runpod) ' "$FAKE/calls" || true; }
settle() { # wait for every detached attempt of this fixture to exit
  local n=100
  sleep 0.2
  while pgrep -f "$BIN/fm-idle-sleep.sh run" >/dev/null 2>&1 && [ "$n" -gt 0 ]; do
    n=$((n - 1)); sleep 0.1
  done
}

# Not opted in: no file, or an id the file does not name, is never touched.
mv "$CONFIG/idle-sleep" "$TMP_ROOT/idle-sleep.saved"
age_everything
idle tick; settle
[ "$(grep -c . "$FAKE/calls")" = 0 ] || fail "a home with no config/idle-sleep attempted something"
mv "$TMP_ROOT/idle-sleep.saved" "$CONFIG/idle-sleep"
out=$(idle check other) || true
assert_contains "$out" "not opted in" "an unlisted placement must read as not opted in"
pass "auto-sleep is opt-in per placement"

# Recent activity inside the window keeps the placement awake.
touch "$STATE/ios.status"
out=$(idle check ios) && fail "recent activity must keep ios awake"
assert_contains "$out" "active within the idle window" "the verdict must name the window"
pass "activity inside the window blocks"

# Each local blocker, one at a time, past the window.
age_everything
[ "$(idle check ios)" = idle ] || fail "ios should be a candidate once idle past its window"
printf -- '- [ ] ios-1\n' > "$DATA/handoff-fixture"; mkdir -p "$DATA/handoff"
printf -- '- [ ] ios-1\n' > "$DATA/handoff/ios.outbox.md"; rm -f "$DATA/handoff-fixture"
out=$(idle check ios) && fail "an undelivered handoff must block"
assert_contains "$out" "undelivered backlog handoff" "outbox verdict"
rm -f "$DATA/handoff/ios.outbox.md"; age_everything

mkdir -p "$STATE/pending-replies"
printf 'task_id=ios\nphase=delivered\ncorr=aa11\n' > "$STATE/pending-replies/aa11"; age_everything
out=$(idle check ios) && fail "an unresolved routed reply must block"
assert_contains "$out" "unresolved routed reply" "reply verdict"
printf 'task_id=ios\nphase=resolved\ncorr=aa11\n' > "$STATE/pending-replies/aa11"; age_everything

printf 'needs-decision [key=ios-tier]: pick a tier\n' >> "$STATE/ios.status"; age_everything
out=$(idle check ios) && fail "an open decision must block"
assert_contains "$out" "open decision" "decision verdict"
printf 'resolved [key=ios-tier]: standard\n' >> "$STATE/ios.status"; age_everything
[ "$(idle check ios)" = idle ] || fail "ios should be a candidate again after the blockers cleared"
pass "pending outbox, unresolved reply, and open decision each block"

# Remote reads in the detached attempt: live workers and a busy agent block it.
printf '1\n' > "$FAKE/children"; : > "$FAKE/calls"
idle tick; settle
assert_grep "children ios" "$FAKE/calls" "the live-worker probe never ran"
[ "$(sleep_calls)" = 0 ] || fail "a placement with a live worker was slept"
printf '0\n' > "$FAKE/children"; printf 'busy\n' > "$FAKE/observe"; : > "$FAKE/calls"
age_everything; idle tick; settle
assert_grep "observe ios" "$FAKE/calls" "the agent observation never ran"
assert_no_grep "children ios" "$FAKE/calls" "a busy agent must stop the attempt before the child probe"
[ "$(sleep_calls)" = 0 ] || fail "a placement whose agent is busy was slept"
printf 'unknown\n' > "$FAKE/observe"; : > "$FAKE/calls"
age_everything; idle tick; settle
[ "$(sleep_calls)" = 0 ] || fail "a placement whose agent state is unreadable was slept"
printf 'fallback-idle\n' > "$FAKE/observe"; : > "$FAKE/calls"
age_everything; idle tick; settle
[ "$(sleep_calls)" = 0 ] || fail "weak fallback-idle evidence permitted sleep"
pass "live workers and all non-authoritative idle observations keep placements awake"

# Idle past the window: the guarded sleep runs exactly once per placement, on the
# right provider, with no force flag, and a later tick finds it dormant.
printf 'idle\n' > "$FAKE/observe"; : > "$FAKE/calls"
age_everything; idle tick
wait_for_calls 6 || fail "idle placements were not slept: $(cat "$FAKE/calls")"
settle
[ "$(grep -c '^boat sleep ios$' "$FAKE/calls")" = 1 ] || fail "boat sleep was not called exactly once: $(cat "$FAKE/calls")"
[ "$(grep -c '^runpod sleep web$' "$FAKE/calls")" = 1 ] || fail "runpod sleep was not called exactly once: $(cat "$FAKE/calls")"
assert_no_grep '--force' "$FAKE/calls" "auto-sleep must never force"
grep -qx 'lifecycle=suspended' "$DATA/boat/ios.meta" || fail "the fake provider did not record the sleep"
: > "$FAKE/calls"
age_everything; idle tick; settle
[ "$(sleep_calls)" = 0 ] || fail "a dormant placement was slept again"
[ "$(grep -c 'slept after an idle window' "$STATE/idle-sleep.log")" = 2 ] || fail "expected one log line per auto-sleep"
for id in "${ids[@]}"; do
  [ ! -e "$STATE/.idle-sleep-$id.lock" ] && [ ! -L "$STATE/.idle-sleep-$id.lock" ] \
    || fail "successful attempt leaked its lock"
done
pass "an idle placement is slept through the guarded provider path exactly once"

# A guard refusal is left as is, never forced, and reported exactly once.
printf 'lifecycle=ready\n' > "$DATA/boat/ios.meta"
printf '1\n' > "$FAKE/sleep-rc"
printf 'error: remote child work is active or unknown\n' > "$FAKE/sleep-msg"
rm -f "$STATE/idle-sleep/ios".*; : > "$FAKE/calls"
age_everything
first=$(idle tick); wait_for_calls 3 || fail "the refused attempt never ran"; settle
[ -z "$first" ] || fail "the first tick had nothing to report yet: $first"
age_everything
report=$(idle tick)
assert_contains "$report" "idle-sleep ios refused" "the refusal must be surfaced"
assert_contains "$report" "remote child work is active or unknown" "the report must carry the guard's reason"
assert_contains "$report" "not forced" "the report must say nothing was forced"
[ "$(grep -c 'idle-sleep:ios' "$STATE/.wake-queue")" = 1 ] || fail "the refusal was not queued exactly once"
assert_no_grep '--force' "$FAKE/calls" "a refused sleep must never be retried with force"
age_everything; touch -d '1 hour ago' "$STATE/idle-sleep/ios.refused" 2>/dev/null || perl -e 'utime(time-3600,time-3600,@ARGV)' "$STATE/idle-sleep/ios.refused"
perl -e 'utime(time-7200,time-7200,@ARGV)' "$STATE/idle-sleep/ios.attempt"
idle tick; settle
again=$(idle tick)
[ -z "$again" ] || fail "the same refusal was reported twice: $again"
[ "$(grep -c 'idle-sleep:ios' "$STATE/.wake-queue")" = 1 ] || fail "the repeated refusal queued another wake"
settle
[ ! -e "$STATE/.idle-sleep-ios.lock" ] && [ ! -L "$STATE/.idle-sleep-ios.lock" ] \
  || fail "refused attempt leaked its lock"
pass "a guard refusal is reported once and never forced"

# A different reason after new activity is a new report.
printf 'error: unresolved decisions\n' > "$FAKE/sleep-msg"
touch "$STATE/ios.status"
idle tick >/dev/null; settle
age_everything; perl -e 'utime(time-7200,time-7200,@ARGV)' "$STATE/idle-sleep/ios.attempt"
rm -f "$STATE/idle-sleep/ios.refused" "$STATE/idle-sleep/ios.reported"
idle tick >/dev/null; wait_for_calls 4; settle; age_everything
report=$(idle tick)
assert_contains "$report" "unresolved decisions" "a new refusal reason must be reported"
pass "a new refusal reason is reported again"

# Malformed entries override valid opt-ins regardless of order.
settle
printf 'ios 2\nios invalid\nweb 2 extra\nweb 2\n' > "$CONFIG/idle-sleep"
rm -f "$STATE/.idle-sleep-tick"
: > "$FAKE/calls"
report=$(idle tick)
assert_contains "$report" "ios invalid" "first malformed line must be surfaced"
assert_contains "$report" "web 2 extra" "second malformed line must be surfaced"
for id in "${ids[@]}"; do
  out=$(idle check "$id") && fail "malformed entry left $id opted in"
  assert_contains "$out" "not opted in" "malformed entry disables its placement"
done
printf 'web 2\nweb 2 extra\nios invalid\nios 2\n' > "$CONFIG/idle-sleep"
[ -z "$(idle tick)" ] || fail "alternating malformed lines were reported again"
[ "$(grep -c 'idle-sleep-config:' "$STATE/.wake-queue")" = 2 ] || fail "expected one wake per malformed line"
settle
[ "$(sleep_calls)" = 0 ] || fail "malformed configuration attempted sleep"
pass "distinct malformed lines disable placements and each report once"

# Exercise both real provider lock boundaries with fake compute interfaces.
cp "$ROOT/bin/fm-boat.sh" "$ROOT/bin/fm-runpod.sh" "$BIN/"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/uv" <<SH
#!/usr/bin/env bash
printf 'boat stopped\n' >> "$FAKE/stops"
printf 'lifecycle=suspended\n' > "$DATA/boat/ios.meta"
SH
cat > "$FAKEBIN/curl" <<SH
#!/usr/bin/env bash
printf 'runpod stopped\n' >> "$FAKE/stops"
printf '{}\n200'
SH
cat > "$FAKEBIN/auth-stop" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$BIN/fm-procevent-remote-reply.sh" <<SH
#!/usr/bin/env bash
. "$BIN/fm-secondmate-registry-lib.sh"
handoff=\$(secondmate_handoff_lock_path "$STATE" "\$2")
reply=\$(secondmate_reply_lifecycle_lock_path "$STATE" "\$2")
[ -e "\$handoff" ] && [ -e "\$reply" ] || exit 90
printf '%s\n' "\$1" >> "$FAKE/reply-actions"
if [ "\$1" = retire-quiesce-locked ] && [ -f "$FAKE/activity-on-quiesce" ]; then
  touch "$STATE/\$2.status"
fi
SH
chmod +x "$FAKEBIN/uv" "$FAKEBIN/curl" "$FAKEBIN/auth-stop" "$BIN/fm-procevent-remote-reply.sh"
export PATH="$FAKEBIN:$PATH"
export FM_RUNPOD_OMP_AUTH_BIN="$FAKEBIN/auth-stop"
printf 'RUNPOD_API_KEY=fixture_key\n' > "$CONFIG/runpod.env"
chmod 600 "$CONFIG/runpod.env"
printf 'ios 2\nweb 2\n' > "$CONFIG/idle-sleep"
printf '0\n' > "$FAKE/sleep-rc"
reset_awake() {
  printf 'lifecycle=ready\n' > "$DATA/boat/ios.meta"
  printf 'lifecycle=ready\never_ready=1\npod_id=fixture-pod\n' > "$DATA/runpod/web.meta"
  for id in "${ids[@]}"; do
    printf 'kind=secondmate\n' > "$STATE/$id.meta"
    rm -f "$STATE/idle-sleep/$id.refused" "$STATE/idle-sleep/$id.reported"
  done
  : > "$FAKE/stops"; : > "$FAKE/reply-actions"
  age_everything
}
for stage in children quiesce; do
  reset_awake
  touch "$FAKE/activity-on-$stage"
  for id in "${ids[@]}"; do
    idle run "$id" || fail "changed eligibility should defer $id successfully"
    assert_absent "$STATE/idle-sleep/$id.refused" "deferral must not record refusal"
  done
  [ ! -s "$FAKE/stops" ] || fail "fresh activity did not block provider compute stop"
  grep -qx 'lifecycle=ready' "$DATA/boat/ios.meta" || fail "Boat deferral changed lifecycle"
  grep -qx 'lifecycle=ready' "$DATA/runpod/web.meta" || fail "RunPod deferral changed lifecycle"
  if [ "$stage" = quiesce ]; then
    [ "$(grep -c '^arm-locked$' "$FAKE/reply-actions")" = 2 ] || fail "deferred providers did not restore reply sources"
  fi
  rm -f "$FAKE/activity-on-$stage"
done
reset_awake
for id in "${ids[@]}"; do idle run "$id" || fail "quiet placement $id did not sleep"; done
[ "$(wc -l < "$FAKE/stops")" -eq 2 ] || fail "ordinary auto-sleep did not stop both providers"
reset_awake
for id in "${ids[@]}"; do
  touch "$STATE/$id.status"
  provider=boat; [ "$id" != web ] || provider=runpod
  idle_env "$BIN/fm-$provider.sh" sleep "$id" || fail "explicit sleep inherited auto-sleep window"
done
[ "$(wc -l < "$FAKE/stops")" -eq 2 ] || fail "explicit sleep did not stop both providers"
pass "locked provider rechecks defer fresh activity while ordinary and explicit sleeps succeed"
