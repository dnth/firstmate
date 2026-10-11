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
import io, urllib.error
class Response(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *args): self.close()
def handle(request, timeout):
    path = request.full_url
    method = request.get_method()
    if mode == "gone" and method == "PATCH":
        raise urllib.error.HTTPError(path, 404, "gone", {}, None)
    if "/pins/" in path:
        assert method == "PUT", method
        if mode == "missing-pin":
            raise urllib.error.HTTPError(path, 403, "forbidden", {}, None)
        result = {}
    elif method == "PATCH":
        result = {"id": "msg-1", "pinned": mode != "missing-pin"}
    else:
        assert method == "POST", method
        result = {"id": "msg-1", "channel_id": payload["channel_id"]}
    return Response(json.dumps(result).encode())
outbox_poster.urllib.request.urlopen = handle
print(outbox_poster.waiting_pin_deliver(payload, home))
PY
}

test_1_content_lists_calls_and_prs_without_leaks() {
  local home out
  home="$TMP_ROOT/c1"
  setup_home "$home"
  hold_call "$home" call1 'Approve "copy", then merge\review' "waiting on captain"
  record_pr "$home" ship1 "https://github.com/o/r/pull/42"
  out=$(home_env "$home" "$REFRESH" content) || fail "content must succeed when configured"
  assert_contains "$out" "Waiting on you" "the message must carry its headline"
  assert_contains "$out" 'Approve "copy", then merge\review' "the message must list the open captain call"
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
  printf '%s:%s\n' "$GUILD" 333333333333333333 > "$home/config/ext-waiting-pin"
  out=$(home_env "$home" "$REFRESH" refresh --force) || fail "destination refresh must succeed"
  assert_contains "$out" refreshed "destination changes must publish unchanged content"
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
  count2=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | wc -l | tr -d ' ')
  # A failed board read defers with exit 0, never blocking Firstmate's work.
  out=$(home_env "$home" env FM_DATA_OVERRIDE="$home/no-such-data" "$TODO" --emit 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "the broken-board probe must fail on its own"
  out=$(home_env "$home" env FM_DATA_OVERRIDE="$home/no-such-data" "$REFRESH" refresh 2>&1); rc=$?
  [ "$rc" = 0 ] || fail "a failed refresh must exit 0, never block (got $rc)"
  assert_contains "$out" "deferred" "a failed board read must defer"
  [ "$count2" = "$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | wc -l | tr -d ' ')" ] || fail "a failed read must not publish"
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

test_8_snapshot_delivery_recovery() {
  local home
  home="$TMP_ROOT/c8"
  setup_home "$home"
  home_env "$home" env PYTHONPATH="$PLUGIN" DISCORD_BOT_TOKEN=test-token \
    "$PYTHON_BIN" - "$home" <<'PYTEST'
import io, json, sys, urllib.error
from pathlib import Path
import outbox_poster as poster
home = Path(sys.argv[1])
box = home / "state/ext-outbox"
box.mkdir(mode=0o700)
calls = []
pin_failure = 503
pinned = False
deleted = False
class Response(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *args): self.close()
def edge(request, timeout):
    global pin_failure, pinned, deleted
    method, url = request.get_method(), request.full_url
    calls.append((method, url))
    if "/pins/" in url:
        assert method == "PUT"
        if pin_failure:
            raise urllib.error.HTTPError(url, pin_failure, "pin failure", {}, None)
        pinned = True
        return Response(b"{}")
    if method == "PATCH" and deleted:
        deleted = False
        raise urllib.error.HTTPError(url, 404, "gone", {}, None)
    return Response(json.dumps({"id": "message", "pinned": pinned if method == "PATCH" else False}).encode())
poster.urllib.request.urlopen = edge
def payload(n, channel="222222222222222222"):
    path = box / f"waiting-pin.{n}.json"
    path.write_text(json.dumps(dict(kind="waiting-pin", guild_id="111111111111111111",
        channel_id=channel, text=f"snapshot {n}", snapshot_id=n, recorded_at=0, content_hash=str(n))))
    path.chmod(0o600)
    return path
old, current = payload(1), payload(2)
try:
    poster.deliver_one(current, home=home)
except poster.DiscordSendError as err:
    assert err.http_code == 503
else:
    raise AssertionError("pin failure must remain retryable")
assert current.exists()
assert poster.waiting_pin_load(home)["message_id"] == "message"
assert poster.waiting_pin_load(home)["pinned"] is False
pin_failure = 0
assert poster.deliver_one(current, home=home) == "edited"
assert sum(method == "POST" for method, _ in calls) == 1
assert not current.exists()
assert poster.list_pending(home=home) == [old]
before = len(calls)
assert poster.deliver_one(old, home=home) == "superseded"
assert len(calls) == before and not old.exists()
assert poster.list_pending(home=home) == []
pinned = False
assert poster.deliver_one(payload(3), home=home) == "edited"
assert calls[-1][0] == "PUT" and poster.waiting_pin_load(home)["pinned"]
pinned = False
pin_failure = 403
assert poster.deliver_one(payload(4), home=home) == "edited"
assert not poster.waiting_pin_load(home)["pinned"]
pin_failure = 0
assert poster.deliver_one(payload(5), home=home) == "edited"
assert poster.waiting_pin_load(home)["pinned"]
assert poster.deliver_one(payload(6, "333333333333333333"), home=home) == "posted-pinned"
assert "/channels/333333333333333333/" in calls[-1][1]
deleted = True
pin_failure = 429
next_path = payload(7, "333333333333333333")
try:
    poster.deliver_one(next_path, home=home)
except poster.DiscordSendError as err:
    assert err.http_code == 429
else:
    raise AssertionError("recreation pin failure must retry")
posts = sum(method == "POST" for method, _ in calls)
pin_failure = 0
assert poster.deliver_one(next_path, home=home) == "edited"
assert sum(method == "POST" for method, _ in calls) == posts
PYTEST
  [ "$?" = 0 ] || fail "snapshot recovery checks must succeed"
  pass "8 snapshots retire, stay ordered, and retry pinning without duplicate posts"
}

test_9_large_board_and_private_publication() {
  local home out i payload
  home="$TMP_ROOT/c9"
  setup_home "$home"
  for i in {1..20}; do
    hold_call "$home" "call$i" "$(printf '%0190d' "$i")" waiting
  done
  out=$(home_env "$home" "$REFRESH" content) || fail "large board must render"
  [ "${#out}" -le 2000 ] || fail "message must fit Discord"
  assert_contains "$out" "More waiting items omitted" "overflow must be explicit"
  home_env "$home" env FM_EXT_NOW_OVERRIDE=100 "$REFRESH" refresh >/dev/null
  hold_call "$home" extra "A distinct update" waiting
  home_env "$home" env FM_EXT_NOW_OVERRIDE=100 "$REFRESH" refresh --force >/dev/null
  [ "$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | wc -l | tr -d ' ')" = 2 ] || fail "same-second updates must remain distinct"
  payload=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | head -1)
  home_env "$home" bash -c '. "$1/bin/fm-ext-lib.sh"; fm_ext_private_artifact_file_valid "$2/state/ext-outbox" "${3##*/}" 600' _ "$ROOT" "$home" "$payload" || fail "pin publication must satisfy ordinary private artifact rules"
  home_env "$home" bash -c '. "$1/bin/fm-ext-lib.sh"; ! fm_ext_kind_valid waiting-pin' _ "$ROOT" || fail "ordinary replies must reject waiting-pin"
  pass "9 large boards fit Discord and snapshots use private publication"
}

test_10_backend_failures_defer_without_publication() {
  local home fake out mode
  home="$TMP_ROOT/c10"
  setup_home "$home"
  record_pr "$home" ship1 "https://github.com/o/r/pull/42"
  fake="$home/fakebin"
  mkdir "$fake"
  cat > "$fake/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "$FAIL_MODE:$1" in
  list:list|show:show) exit 1 ;;
  hang:list) sleep 30; exit 1 ;;
esac
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod 700 "$fake/tasks-axi"
  for mode in list show hang; do
    out=$(home_env "$home" env PATH="$fake:$BASE_PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FAIL_MODE="$mode" "$REFRESH" refresh 2>&1) || fail "backend failure must remain best effort"
    assert_contains "$out" deferred "failed or wedged reads must defer"
    [ ! -d "$home/state/ext-outbox" ] || fail "failed reads must not queue false all-clear snapshots"
  done
  pass "10 failed and wedged board reads defer publication"
}

test_1_content_lists_calls_and_prs_without_leaks
test_2_refresh_creates_then_edits_in_place
test_3_deleted_message_recreated_once
test_4_unconfigured_stays_silent
test_5_refresh_idempotent_rate_limited_never_blocks
test_6_missing_pin_permission_falls_back_reported
test_7_todo_emit_refreshes_without_blocking

test_8_snapshot_delivery_recovery
test_9_large_board_and_private_publication
test_10_backend_failures_defer_without_publication

echo "all fm-ext-waiting-pin tests passed"
