#!/usr/bin/env bash
# Pinned "Waiting on you" Discord message, through the real refresh script
# and a stubbed Discord edge:
#
#   content lists open captain calls and ready PR URLs from durable records
#   only, with no paths or secrets;
#   refresh creates the message once, edits it in place on later refreshes
#   (same message id), recreates it once when deleted, and stays silent
#   when unconfigured;
#   refresh is idempotent, rate-limited, and never blocks Firstmate's work;
#   missing Manage Messages falls back to a single edited post and is
#   reported in state.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH="$PYTHON_DIR:$BASE_PATH"
TASKS_AXI_BIN=$(command -v tasks-axi 2>/dev/null) || TASKS_AXI_BIN=
[ -n "$TASKS_AXI_BIN" ] || fail "test needs tasks-axi on PATH"
BASE_PATH="$(dirname "$TASKS_AXI_BIN"):$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ext-waiting-pin)

REFRESH="$ROOT/bin/fm-ext-waiting-pin.sh"
TODO="$ROOT/bin/fm-todo-project.sh"
PLUGIN="$ROOT/contrib/hermes-gateway-firstmate-comms"
GUILD=111111111111111111
CHANNEL=222222222222222222
AUTHOR=555555555555555555

setup_home() {
  local home=$1
  mkdir -p "$home/config" "$home/state" "$home/data"
  : > "$home/config/ext-bridge"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
  printf '%s:%s\n' "$GUILD" "$CHANNEL" > "$home/config/ext-waiting-pin"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
}

home_env() {
  local home=$1
  shift
  PATH="$BASE_PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" \
    "$@"
}

hold_call() {  # <home> <id> <title> <reason>
  local home=$1 id=$2 title=$3 reason=$4
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi add "$id" "$title" --kind captain >/dev/null) \
    || fail "tasks-axi add $id must succeed"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi hold "$id" --reason "$reason" --kind captain >/dev/null) \
    || fail "tasks-axi hold $id must succeed"
}

record_pr() {  # <home> <id> <url>
  local home=$1 id=$2 url=$3
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi add "$id" "ship $id" >/dev/null) \
    || fail "tasks-axi add $id must succeed"
  printf 'window=test\npr=%s\n' "$url" > "$home/state/$id.meta"
}

# Run the poster's waiting-pin deliver against a stubbed Discord edge.
# STUB_MODE: normal | missing-pin | gone (404 on edit).
stub_deliver() {  # <home> <payload> <mode>: prints the deliver verdict
  local home=$1 payload=$2 mode=$3
  home_env "$home" env PYTHONPATH="$PLUGIN" DISCORD_BOT_TOKEN=test-token \
    "$PYTHON_BIN" - "$home" "$payload" "$mode" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
from pathlib import Path
home, payload_path, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
os.environ["FM_HOME"] = str(home)
payload = json.loads(payload_path.read_text(encoding="utf-8"))
calls = []
def handle(action, path, token, body):
    calls.append(action + " " + path)
    if mode == "gone" and action == "edit":
        raise outbox_poster.DiscordSendError("ambiguous", "discord HTTP 404", 404)
    if mode == "missing-pin" and "/pins/" in path:
        raise outbox_poster.DiscordSendError("permanent", "discord HTTP 403", 403)
    if "/pins/" in path:
        return {}
    if action == "edit":
        return {"id": "msg-1"}
    return {"id": "msg-1", "channel_id": os.environ.get("CHANNEL", "c")}
os.environ["CHANNEL"] = payload.get("channel_id", "")
outbox_poster.waiting_pin_http = handle
print(outbox_poster.waiting_pin_deliver(payload, home))
PY
}

test_1_content_lists_calls_and_prs_without_leaks() {
  local home out
  home="$TMP_ROOT/c1"
  setup_home "$home"
  hold_call "$home" call1 "Decide the merge wording" "waiting on captain"
  record_pr "$home" ship1 "https://github.com/o/r/pull/42"
  out=$(home_env "$home" "$REFRESH" content) || fail "content must succeed when configured"
  assert_contains "$out" "Waiting on you" "the message must carry its headline"
  assert_contains "$out" "Decide the merge wording" "the message must list the open captain call"
  assert_contains "$out" "https://github.com/o/r/pull/42" "the message must list the ready PR URL"
  assert_contains "$out" "updated" "the message must carry a last-updated time"
  case "$out" in
    *"$home"*|*"worktree"*|*"secret"*|*"token"*|*".meta"*) fail "content must not leak paths or secrets: $out" ;;
  esac
  pass "1 content lists open calls and ready PRs from durable records only"
}

test_2_refresh_creates_then_edits_in_place() {
  local home payload count1 count2
  home="$TMP_ROOT/c2"
  setup_home "$home"
  hold_call "$home" call1 "Decide the merge wording" "waiting on captain"
  out=$(home_env "$home" "$REFRESH" refresh) || fail "refresh must succeed"
  assert_contains "$out" "refreshed" "the first refresh must publish"
  count1=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | wc -l | tr -d ' ')
  [ "$count1" = 1 ] || fail "the first refresh must publish exactly one payload (got $count1)"
  payload=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | head -1)
  [ "$(stub_deliver "$home" "$payload" normal)" = "posted-pinned" ] || fail "the poster must post and pin once"
  [ "$(jq -r .message_id "$home/state/ext-waiting-pin.json")" = "msg-1" ] || fail "the poster must record the message id"
  # A board change plus --force publishes again; the poster edits the same id.
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi add call2 "Approve the copy" --kind captain >/dev/null)
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi hold call2 --reason "waiting" --kind captain >/dev/null)
  out=$(home_env "$home" "$REFRESH" refresh --force) || fail "forced refresh must succeed"
  assert_contains "$out" "refreshed" "a changed board must publish again"
  count2=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | wc -l | tr -d ' ')
  [ "$count2" = 2 ] || fail "a changed board must publish a second payload (got $count2)"
  payload=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | sort | tail -1)
  [ "$(stub_deliver "$home" "$payload" normal)" = "edited" ] || fail "the second refresh must edit in place"
  [ "$(jq -r .message_id "$home/state/ext-waiting-pin.json")" = "msg-1" ] \
    || fail "an edit in place must keep the same message id"
  pass "2 refresh creates once and edits in place on later refreshes"
}

test_3_deleted_message_recreated_once() {
  local home payload
  home="$TMP_ROOT/c3"
  setup_home "$home"
  hold_call "$home" call1 "Decide the merge wording" "waiting on captain"
  home_env "$home" "$REFRESH" refresh >/dev/null || fail "refresh must succeed"
  payload=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | head -1)
  [ "$(stub_deliver "$home" "$payload" normal)" = "posted-pinned" ] || fail "setup post must succeed"
  # The message is deleted out of band; the next deliver recreates and pins.
  payload=$(python3 -c "import json; p=json.load(open('$payload')); p['text']='After deletion'; print(json.dumps(p))" \
    | tee "$home/recreated.json" >/dev/null; cat "$home/recreated.json" >/dev/null || true)
  home_env "$home" "$REFRESH" refresh --force >/dev/null || fail "forced refresh must succeed"
  payload=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | sort | tail -1)
  [ "$(stub_deliver "$home" "$payload" gone)" = "posted-pinned" ] || fail "a deleted message must be recreated and pinned"
  [ "$(jq -r .message_id "$home/state/ext-waiting-pin.json")" = "msg-1" ] \
    || fail "the recreated message id must be recorded"
  pass "3 a deleted message is recreated once and the new id is recorded"
}

test_4_unconfigured_stays_silent() {
  local home out rc
  home="$TMP_ROOT/c4"
  setup_home "$home"
  hold_call "$home" call1 "Decide the merge wording" "waiting on captain"
  rm -f "$home/config/ext-waiting-pin"
  out=$(home_env "$home" "$REFRESH" refresh 2>&1); rc=$?
  [ "$rc" = 3 ] || fail "refresh without a pin target must exit 3 (got $rc)"
  assert_contains "$out" "unconfigured" "refresh without a pin target must say unconfigured"
  [ -z "$(find "$home/state/ext-outbox" -name '*.json' 2>/dev/null)" ] \
    || fail "an unconfigured refresh must not publish"
  rm -f "$home/config/ext-bridge"
  printf '%s:%s\n' "$GUILD" "$CHANNEL" > "$home/config/ext-waiting-pin"
  out=$(home_env "$home" "$REFRESH" content 2>&1); rc=$?
  [ "$rc" = 3 ] || fail "content without the bridge must exit 3 (got $rc)"
  pass "4 refresh is silent when unconfigured"
}

test_5_refresh_idempotent_rate_limited_never_blocks() {
  local home out count1 count2
  home="$TMP_ROOT/c5"
  setup_home "$home"
  hold_call "$home" call1 "Decide the merge wording" "waiting on captain"
  home_env "$home" "$REFRESH" refresh >/dev/null || fail "first refresh must succeed"
  payload=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | head -1)
  stub_deliver "$home" "$payload" normal >/dev/null
  count1=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | wc -l | tr -d ' ')
  out=$(home_env "$home" "$REFRESH" refresh) || fail "second refresh must succeed"
  assert_contains "$out" "unchanged" "an unchanged board must skip the publish"
  count2=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | wc -l | tr -d ' ')
  [ "$count1" = "$count2" ] || fail "an unchanged refresh must not publish again"
  # A changed board inside the interval is rate-limited; --force bypasses it.
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi add call2 "Approve the copy" --kind captain >/dev/null)
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi hold call2 --reason "waiting" --kind captain >/dev/null)
  out=$(home_env "$home" "$REFRESH" refresh) || fail "rate-limited refresh must still exit 0"
  assert_contains "$out" "rate-limited" "a changed board inside the interval must be rate-limited"
  out=$(home_env "$home" env FM_EXT_WAITING_PIN_MIN_SECS=broken "$REFRESH" refresh --force) \
    || fail "forced refresh must succeed"
  assert_contains "$out" "refreshed" "force must bypass the interval"
  # A failed board read defers with exit 0, never blocking Firstmate's work.
  out=$(home_env "$home" env FM_DATA_OVERRIDE="$home/no-such-data" "$TODO" --emit 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "the broken-board probe must fail on its own"
  out=$(home_env "$home" env FM_DATA_OVERRIDE="$home/no-such-data" "$REFRESH" refresh 2>&1); rc=$?
  [ "$rc" = 0 ] || fail "a failed refresh must exit 0, never block (got $rc)"
  pass "5 refresh is idempotent, rate-limited, and never blocks"
}

test_6_missing_pin_permission_falls_back_reported() {
  local home payload verdict
  home="$TMP_ROOT/c6"
  setup_home "$home"
  hold_call "$home" call1 "Decide the merge wording" "waiting on captain"
  home_env "$home" "$REFRESH" refresh >/dev/null || fail "refresh must succeed"
  payload=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | head -1)
  verdict=$(stub_deliver "$home" "$payload" missing-pin)
  [ "$verdict" = "posted-unpinned" ] || fail "missing Manage Messages must fall back unpinned (got $verdict)"
  [ "$(jq -r .pinned "$home/state/ext-waiting-pin.json")" = "false" ] \
    || fail "the fallback must record pinned=false"
  assert_contains "$(jq -r .pin_error "$home/state/ext-waiting-pin.json")" "Manage Messages" \
    "the fallback must report the missing permission plainly"
  payload=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | head -1)
  [ "$(stub_deliver "$home" "$payload" missing-pin)" = "edited" ] \
    || fail "later refreshes must keep editing the same unpinned message"
  pass "6 missing Manage Messages falls back to an unpinned edited message"
}

test_7_todo_emit_refreshes_without_blocking() {
  local home out
  home="$TMP_ROOT/c7"
  setup_home "$home"
  hold_call "$home" call1 "Decide the merge wording" "waiting on captain"
  record_pr "$home" shipT "https://github.com/o/r/pull/7"
  out=$(home_env "$home" "$TODO" --emit 2>/dev/null) || fail "todo --emit must succeed"
  [ -n "$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' 2>/dev/null)" ] \
    || fail "todo --emit must trigger a waiting-pin refresh"
  rm -f "$home/config/ext-waiting-pin"
  out=$(home_env "$home" "$TODO" --check 2>/dev/null) || fail "todo --check must succeed unconfigured too"
  case "$out" in
    *Traceback*|*refresh_waiting_pin*) fail "todo --check must not leak refresh internals" ;;
  esac
  pass "7 todo --emit refreshes the pin without blocking projection"
}

test_1_content_lists_calls_and_prs_without_leaks
test_2_refresh_creates_then_edits_in_place
test_3_deleted_message_recreated_once
test_4_unconfigured_stays_silent
test_5_refresh_idempotent_rate_limited_never_blocks
test_6_missing_pin_permission_falls_back_reported
test_7_todo_emit_refreshes_without_blocking

echo "all fm-ext-waiting-pin tests passed"
