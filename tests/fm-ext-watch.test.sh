#!/usr/bin/env bash
# Watcher-side behavior of the local Communication Officer bridge, through real
# fm-watch.sh cycles over a throwaway home:
#
#   the inbox poll shim converges with config/ext-bridge on every cycle, so a
#   bridge switched on (or off) mid-session needs no session restart;
#   a request the gateway records rings the primary exactly once, and stays
#   presented by the drain until it is answered.
#
# The gateway's intake runs in another process and cannot wake the watcher, so
# before this the request waited for some unrelated wake and could be lost.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-ext-lib.sh
. "$ROOT/bin/fm-ext-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
INTAKE="$ROOT/bin/fm-ext-intake.sh"
TMP_ROOT=$(fm_test_tmproot fm-ext-watch)

GUILD=111111111111111111
CHANNEL=222222222222222222
AUTHOR=555555555555555555

opt_in() {
  local home=$1
  mkdir -p "$home/config"
  : > "$home/config/ext-bridge"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
}

# One one-shot watcher run (state/.afk keeps it one-shot): it exits with a
# single reason line on a wake, or is stopped after ~3s of quiet cycles.
run_cycle() {  # <home> <out>
  local home=$1 out=$2
  date '+%s' > "$home/state/.afk"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>"$out.err" &
  wait_for_exit "$!" 30 || true
}

intake() {  # <home> <message-id> <text>: prints the request slug
  local home=$1 message=$2 text=$3
  printf '%s' "$text" > "$home/text.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$INTAKE" \
    --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:$message" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$CHANNEL" \
    --message-id "$message" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt"
}

test_shim_converges_with_the_optin_mid_session() {
  local dir home shim
  dir=$(make_supercase ext-converge)
  home=$dir
  shim="$home/state/ext-watch.check.sh"
  run_cycle "$home" "$dir/off.out"
  [ ! -e "$shim" ] || fail "a home that has not opted in must not gain the poll shim"
  opt_in "$home"
  run_cycle "$home" "$dir/on.out"
  assert_present "$shim" "switching the bridge on mid-session must arm the poll shim within one cycle"
  fm_ext_poll_shim_valid "$shim" "$home" "$FM_ROOT_OVERRIDE" \
    || fail "the armed shim must be the byte-exact identity shim the watcher accepts"
  rm -f "$home/config/ext-bridge"
  run_cycle "$home" "$dir/off-again.out"
  [ ! -e "$shim" ] || fail "switching the bridge off mid-session must remove the poll shim"
  pass "the poll shim converges with config/ext-bridge on every watcher cycle"
}

test_new_request_rings_once_and_stays_presented() {
  local dir home slug1 slug2 out
  dir=$(make_supercase ext-doorbell)
  home=$dir
  opt_in "$home"
  slug1=$(intake "$home" 370000000000000001 "first order") || fail "intake must record the first request"
  run_cycle "$home" "$dir/ring1.out"
  assert_contains "$(cat "$dir/ring1.out")" "check: ext-request $slug1" \
    "a recorded request must wake the primary with its own reason"
  run_cycle "$home" "$dir/quiet.out"
  case "$(cat "$dir/quiet.out")" in
    *"ext-request"*) fail "a request that already rang must not ring again" ;;
  esac
  slug2=$(intake "$home" 370000000000000002 "second order") || fail "intake must record the second request"
  run_cycle "$home" "$dir/ring2.out"
  out=$(cat "$dir/ring2.out")
  assert_contains "$out" "check: ext-request $slug2" "a newer request must ring again"
  case "$out" in
    *"$slug1"*) fail "a newer ring must not repeat an already rung request" ;;
  esac
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$DRAIN" 2>/dev/null)
  assert_contains "$out" "EXT REQUESTS AWAITING ANSWER" "the drain must present the unanswered requests"
  assert_contains "$out" "ext-request $slug1" "the first unanswered request must stay presented"
  assert_contains "$out" "ext-request $slug2" "the second unanswered request must stay presented"
  pass "a recorded request rings the primary once and stays presented until answered"
}

test_shim_converges_with_the_optin_mid_session
test_new_request_rings_once_and_stays_presented

echo "all fm-ext-watch tests passed"
