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
print(outbox_poster.deliver_one(payload_path, home=home))
PY
}

test_1b_long_titles_render_cleanly_without_ids_or_commands() {
  local home out line len
  home="$TMP_ROOT/c1b"
  setup_home "$home"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi add longcall "$(python3 -c 'print("B" * 300)')" --kind captain >/dev/null) \
    || fail "tasks-axi add longcall must succeed"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi hold longcall --reason "waiting on captain" --kind captain >/dev/null) \
    || fail "tasks-axi hold longcall must succeed"
  hold_call "$home" short1 "Decide the merge wording" "waiting on captain"
  record_pr "$home" ship1 "https://github.com/o/r/pull/42"
  out=$(home_env "$home" "$REFRESH" content) || fail "content must succeed when configured"
  assert_contains "$out" "Decide the merge wording" "short titles must pass through unchanged"
  assert_contains "$out" "https://github.com/o/r/pull/42" "PR links must still render"
  case "$out" in
    *truncated*|*"--full"*|*"use show"*|*longcall*) fail "content must not leak task ids or tool help: $out" ;;
  esac
  line=$(printf '%s\n' "$out" | grep '^- B' | head -1)
  [ -n "$line" ] || fail "the long title must render as its own pin line"
  len=$(printf '%s' "$line" | wc -m | tr -d ' ')
  [ "$len" = 200 ] || fail "the long title must use the existing 200-character call-line cap (got $len)"
  case "$line" in
    *"…"*) : ;;
    *) fail "the long title must end in a plain ellipsis" ;;
  esac
  case "$out" in
    *"$home"*|*"worktree"*|*"secret"*|*"token"*|*".meta"*) fail "content must not leak paths or secrets: $out" ;;
  esac
  [ "${#out}" -le 2000 ] || fail "message must fit Discord"
  pass "1b long titles render cleanly with no task id or tool help"
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
  [ "$count2" = 1 ] || fail "a changed board must publish one pending payload (got $count2)"
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
  [ ! -e "$payload" ] || fail "setup delivery must retire its snapshot"
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
  home_env "$home" "$REFRESH" refresh --force >/dev/null || fail "fallback reconciliation must publish"
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
    "$PYTHON_BIN" - "$home" <<'PYTEST' || fail "snapshot recovery checks must succeed"
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
    (home / "config/ext-waiting-pin").write_text(f"111111111111111111:{channel}\n")
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
original_edge = edge
def broken_channel(request, timeout):
    if request.get_method() == "POST" and json.loads(request.data)["content"] == "snapshot 8":
        raise urllib.error.HTTPError(request.full_url, 404, "missing channel", {}, None)
    return original_edge(request, timeout)
poster.urllib.request.urlopen = broken_channel
bad = payload(8, "555555555555555555")
good = payload(9, "555555555555555555")
assert poster.drain_outbox(home=home) == ["failed", "posted-pinned"]
assert bad.exists() and not good.exists()
assert poster.waiting_pin_load(home)["channel_id"] == "555555555555555555"
assert poster.drain_outbox(home=home) == ["superseded"]
assert not bad.exists()
PYTEST
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
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  home_env "$home" bash -c '. "$1/bin/fm-ext-lib.sh"; fm_ext_private_artifact_file_valid "$2/state/ext-outbox" "${3##*/}" 600' _ "$ROOT" "$home" "$payload" || fail "pin publication must satisfy ordinary private artifact rules"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  home_env "$home" bash -c '. "$1/bin/fm-ext-lib.sh"; ! fm_ext_reply_kind_valid waiting-pin' _ "$ROOT" || fail "ordinary replies must reject waiting-pin"
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
    [ -z "$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' 2>/dev/null)" ] || fail "failed reads must not queue false all-clear snapshots"
  done
  pass "10 failed and wedged board reads defer publication"
}

test_11_unchanged_reconciliation_and_pending_limits() {
  local home
  home="$TMP_ROOT/c11"
  setup_home "$home"
  hold_call "$home" call1 "Choose the wording" waiting
  home_env "$home" env PYTHONPATH="$PLUGIN" DISCORD_BOT_TOKEN=test-token TASKS_AXI_REAL="$TASKS_AXI_BIN" \
    "$PYTHON_BIN" - "$home" "$REFRESH" <<'PYTEST' || fail "normal unchanged refresh must reach reconciliation and limit publication"
import io, json, os, subprocess, sys, urllib.error
from pathlib import Path
import outbox_poster as poster
home, refresh = Path(sys.argv[1]), sys.argv[2]
mode = "normal"
pinned = False
posts = 0
pins = 0
class Response(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *args): self.close()
def edge(request, timeout):
    global pinned, posts, pins, mode
    method, url = request.get_method(), request.full_url
    if method == "PATCH" and mode == "deleted":
        mode = "normal"
        raise urllib.error.HTTPError(url, 404, "deleted", {}, None)
    if "/pins/" in url:
        pins += 1
        if mode == "forbidden":
            raise urllib.error.HTTPError(url, 403, "forbidden", {}, None)
        pinned = True
        return Response(b"{}")
    if method == "POST":
        posts += 1
        pinned = False
    return Response(json.dumps({"id": f"message-{posts}", "pinned": pinned}).encode())
poster.urllib.request.urlopen = edge
def publish(now, force=False):
    env = dict(os.environ, FM_EXT_NOW_OVERRIDE=str(now))
    result = subprocess.run([refresh, "refresh"] + (["--force"] if force else []), env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()
assert publish(100) == "waiting-pin: refreshed"
assert publish(100) == "waiting-pin: unchanged"
assert publish(200, True) == "waiting-pin: unchanged"
assert len(poster.list_pending(home=home)) == 1
assert poster.drain_outbox(home=home) == ["posted-pinned"]
assert poster.list_pending(home=home) == []
assert publish(159) == "waiting-pin: unchanged"
assert publish(160) == "waiting-pin: refreshed"
mode = "deleted"
assert poster.drain_outbox(home=home) == ["posted-pinned"]
assert posts == 2
pinned = False
before = pins
assert publish(220) == "waiting-pin: refreshed"
assert poster.drain_outbox(home=home) == ["edited"]
assert pins == before + 1 and posts == 2
pinned = False
mode = "forbidden"
assert publish(221, True) == "waiting-pin: refreshed"
assert poster.drain_outbox(home=home) == ["edited"]
assert not poster.waiting_pin_load(home)["pinned"]
mode = "normal"
assert publish(281) == "waiting-pin: refreshed"
assert poster.drain_outbox(home=home) == ["edited"]
assert poster.waiting_pin_load(home)["pinned"] and posts == 2
assert publish(282, True) == "waiting-pin: refreshed"
subprocess.run([os.environ["TASKS_AXI_REAL"], "add", "extra", "Choose another option", "--kind", "captain"], cwd=home / "data", check=True, capture_output=True)
subprocess.run([os.environ["TASKS_AXI_REAL"], "hold", "extra", "--reason", "waiting", "--kind", "captain"], cwd=home / "data", check=True, capture_output=True)
assert publish(283) == "waiting-pin: rate-limited"
assert len(poster.list_pending(home=home)) == 1
assert publish(283, True) == "waiting-pin: refreshed"
assert len(poster.list_pending(home=home)) == 2
PYTEST
  pass "11 unchanged refresh repairs deletion, pins, and permissions without duplicate pending snapshots"
}

test_12_landing_and_dated_calls() {
  local home out today
  home="$TMP_ROOT/c12"
  setup_home "$home"
  hold_call "$home" future "Deferred future choice" waiting
  hold_call "$home" due "Choice due today" waiting
  hold_call "$home" past "Past choice still pending" waiting
  today=$(date -u '+%Y-%m-%d')
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi hold future --kind captain --reason waiting --until 2099-01-01 >/dev/null) || fail "future hold must succeed"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi hold due --kind captain --reason waiting --until "$today" >/dev/null) || fail "today hold must succeed"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi hold past --kind captain --reason waiting --until 2000-01-01 >/dev/null) || fail "past hold must succeed"
  printf 'kind=landing\nsecondmate=mate\npr=https://github.com/o/r/pull/44\n' > "$home/state/land-mate-44.meta"
  record_pr "$home" ship1 "https://github.com/o/r/pull/42"
  out=$(home_env "$home" "$REFRESH" content) || fail "landing metadata must not require a board row"
  assert_not_contains "$out" "Deferred future choice" "future deferrals must stay out of captain calls"
  assert_contains "$out" "Choice due today" "date gates must open on their date"
  assert_contains "$out" "Past choice still pending" "expired held flags must not hide unresolved calls"
  assert_contains "$out" "https://github.com/o/r/pull/44" "landing PRs must remain visible"
  assert_contains "$out" "https://github.com/o/r/pull/42" "ordinary task PRs must remain visible"
  printf 'pr=https://github.com/o/r/pull/45\n' > "$home/state/missing-task.meta"
  out=$(home_env "$home" "$REFRESH" refresh 2>&1) || fail "a failed real task lookup must defer"
  assert_contains "$out" deferred "missing task rows must still fail the refresh"
  [ -z "$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' 2>/dev/null)" ] || fail "task lookup failures must not publish"
  pass "12 landing PRs and due calls render while future calls stay deferred"
}

test_13_pr_selection_uses_state_fields() {
  local home out
  home="$TMP_ROOT/c13"
  setup_home "$home"
  record_pr "$home" state-title "https://github.com/o/r/pull/51"
  record_pr "$home" absence-title "https://github.com/o/r/pull/52"
  record_pr "$home" completed "https://github.com/o/r/pull/53"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi update state-title --title "Fix state: done detection" >/dev/null) || fail "state-like title must be accepted"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi update absence-title --title "Fix not found in this backlog detection" >/dev/null) || fail "absence-like title must be accepted"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi start absence-title >/dev/null) || fail "in-flight fixture must start"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi "done" completed >/dev/null) || fail "completed fixture must close"
  out=$(home_env "$home" "$REFRESH" content) || fail "state-like titles must not prevent rendering"
  assert_contains "$out" "https://github.com/o/r/pull/51" "queued PR eligibility must use the state field"
  assert_contains "$out" "https://github.com/o/r/pull/52" "in-flight PR eligibility must use lookup status"
  assert_not_contains "$out" "https://github.com/o/r/pull/53" "completed PRs must remain absent"
  home_env "$home" "$REFRESH" refresh >/dev/null || fail "state-field selection must publish"
  out=$(jq -r '.text' "$home/state/ext-outbox/"waiting-pin.*.json) || fail "published snapshot must be readable"
  assert_contains "$out" "https://github.com/o/r/pull/51" "refresh must publish the eligible queued PR"
  assert_contains "$out" "https://github.com/o/r/pull/52" "refresh must publish the eligible in-flight PR"
  assert_not_contains "$out" "https://github.com/o/r/pull/53" "refresh must omit the completed PR"
  pass "13 PR selection ignores state-like and absence-like task titles"
}

test_14_existing_task_captain_holds() {
  local home out kind phase id today payload
  home="$TMP_ROOT/c14"
  setup_home "$home"
  for kind in ship scout; do
    for phase in queued in_flight; do
      id="$kind-$phase"
      (cd "$home/data" && PATH="$BASE_PATH" tasks-axi add "$id" "Approve $kind $phase work" --kind "$kind" >/dev/null) || fail "existing task fixture must be created"
      if [ "$phase" = in_flight ]; then
        (cd "$home/data" && PATH="$BASE_PATH" tasks-axi start "$id" >/dev/null) || fail "existing task fixture must start"
      fi
      home_env "$home" env FM_EXT_WAITING_PIN_MIN_SECS=0 "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason "captain approval pending" >/dev/null || fail "existing tasks must accept captain holds"
      out=$(cd "$home/data" && PATH="$BASE_PATH" tasks-axi show "$id") || fail "held task must remain readable"
      assert_contains "$out" "kind: $kind" "holding an existing task must preserve its kind"
      assert_contains "$out" "state: $phase" "holding an existing task must preserve its state"
    done
  done
  out=$(home_env "$home" "$REFRESH" content) || fail "open holds must render"
  for kind in ship scout; do
    for phase in queued in_flight; do
      assert_contains "$out" "Approve $kind $phase work" "every open existing-task hold must be listed"
    done
  done
  payload=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | sort | tail -1)
  out=$(jq -r '.text' "$payload") || fail "hold lifecycle must publish a snapshot"
  assert_contains "$out" "Approve ship in_flight work" "hold refresh must publish ship calls"
  assert_contains "$out" "Approve scout in_flight work" "hold refresh must publish scout calls"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold ship-in_flight --reason "later approval" --until 2099-01-01 >/dev/null || fail "existing-task date gate must be accepted"
  out=$(home_env "$home" "$REFRESH" content) || fail "future hold must render"
  assert_not_contains "$out" "Approve ship in_flight work" "future existing-task holds must remain deferred"
  today=$(date -u '+%Y-%m-%d')
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold ship-in_flight --reason "approval due" --until "$today" >/dev/null || fail "existing-task due date must be accepted"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi "done" scout-queued >/dev/null) || fail "completed fixture must close"
  (cd "$home/data" && PATH="$BASE_PATH" tasks-axi hold ship-queued --kind external --reason "external approval" >/dev/null) || fail "external hold fixture must be accepted"
  out=$(home_env "$home" "$REFRESH" content) || fail "due existing-task holds must render"
  assert_contains "$out" "Approve ship in_flight work" "due existing-task holds must resurface even when held becomes no"
  assert_not_contains "$out" "Approve scout queued work" "completed holds must stay absent"
  assert_not_contains "$out" "Approve ship queued work" "external holds must stay absent"
  home_env "$home" "$REFRESH" refresh --force >/dev/null || fail "corrected board must publish"
  payload=$(find "$home/state/ext-outbox" -name 'waiting-pin.*.json' | sort | tail -1)
  out=$(jq -r '.text' "$payload") || fail "corrected snapshot must be readable"
  assert_contains "$out" "Approve ship in_flight work" "published snapshots must include due existing-task holds"
  assert_not_contains "$out" "Approve scout queued work" "published snapshots must omit completed holds"
  pass "14 existing ship and scout captain holds respect state and date gates"
}

test_15_pin_targets_and_reply_separation() {
  local home out rc
  home="$TMP_ROOT/c15"
  setup_home "$home"
  out=$(home_env "$home" "$ROOT/bin/fm-ext-emit.sh" --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:999" --kind waiting-pin --generation 1 --text-file - <<< 'ordinary reply' 2>&1); rc=$?
  [ "$rc" = 2 ] || fail "ordinary emit must reject the pin kind"
  assert_contains "$out" "reply kind must be ack, answer, followup, or final" "emit must explain supported reply kinds"
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  home_env "$home" bash -c '. "$1/bin/fm-ext-lib.sh"; fm_ext_kind_valid waiting-pin && ! fm_ext_reply_kind_valid waiting-pin' _ "$ROOT" || fail "dedicated pin kinds and ordinary reply kinds must remain distinct"
  home_env "$home" bash -s -- "$ROOT" "$home" <<'SH' || fail "ordinary request/generation schemas must reject the pin kind"
set -euo pipefail
. "$1/bin/fm-ext-lib.sh"
for kind in ack answer followup final waiting-pin; do
  jq -cn --argjson schema "$FM_EXT_SCHEMA_VERSION" --arg kind "$kind" \
    '{schema_version:$schema,request_id:"discord:test",slug:("a" * 64),kind:$kind,generation:1,platform:"discord",source:"hermes-gateway",guild_id:"111",channel_id:"222",thread_id:"222",message_id:"333",text:"reply"}' > "$2/reply-schema.json"
  if [ "$kind" = waiting-pin ]; then
    ! fm_ext_outbox_schema_valid "$2/reply-schema.json"
  else
    fm_ext_outbox_schema_valid "$2/reply-schema.json"
  fi
done
SH
  home_env "$home" env PYTHONPATH="$PLUGIN" DISCORD_BOT_TOKEN=test-token "$PYTHON_BIN" - "$home" <<'PYTEST' || fail "disabled and obsolete target checks must succeed"
import json, sys
from pathlib import Path
import outbox_poster as poster
home = Path(sys.argv[1])
config = home / "config/ext-waiting-pin"
box = home / "state/ext-outbox"
box.mkdir(mode=0o700)
def no_network(*args, **kwargs):
    raise AssertionError("obsolete snapshots must never contact Discord")
poster.waiting_pin_http = no_network
def snapshot(n):
    path = box / f"waiting-pin.{n}.json"
    path.write_text(json.dumps(dict(kind="waiting-pin", guild_id="111111111111111111", channel_id="222222222222222222", text="private board", snapshot_id=n)))
    path.chmod(0o600)
    return path
for target in (None, "111111111111111111:333333333333333333", "999999999999999999:222222222222222222", "invalid"):
    if target is None:
        config.unlink(missing_ok=True)
    else:
        config.write_text(target + "\n")
    path = snapshot(1)
    assert poster.deliver_one(path, home=home) == "obsolete"
    assert not path.exists()
config.write_text("111111111111111111:222222222222222222\n")
(home / "config/ext-bridge").unlink()
path = snapshot(2)
assert poster.deliver_one(path, home=home) == "obsolete" and not path.exists()
assert not poster.waiting_pin_state_path(home).exists()
PYTEST
  pass "15 ordinary emit rejects pin kinds and obsolete snapshots retire without Discord calls"
}

test_16_competing_pin_posters_share_one_claim() {
  local home
  home="$TMP_ROOT/c16"
  setup_home "$home"
  home_env "$home" env PYTHONPATH="$PLUGIN" DISCORD_BOT_TOKEN=test-token "$PYTHON_BIN" - "$home" <<'PYTEST' || fail "competing posters must serialize creation, recreation, and state updates"
import json, multiprocessing as mp, sys
from pathlib import Path
import outbox_poster as poster
home = Path(sys.argv[1])
box = home / "state/ext-outbox"
box.mkdir(mode=0o700)
ctx = mp.get_context("fork")
posts = ctx.Value("i", 0)
entered, finish = ctx.Event(), ctx.Event()
results = ctx.Queue()
recreate = False
def edge(action, path, token, body):
    if action == "edit" and recreate:
        raise poster.DiscordSendError("permanent", "deleted", 404)
    if action == "post":
        with posts.get_lock():
            posts.value += 1
            message = str(posts.value)
        entered.set()
        assert finish.wait(20), "first poster was never released"
        return {"id": message}
    return {"pinned": True}
poster.waiting_pin_http = edge
def payload(n):
    path = box / f"waiting-pin.{n}.json"
    path.write_text(json.dumps(dict(kind="waiting-pin", guild_id="111111111111111111", channel_id="222222222222222222", text=f"board {n}", snapshot_id=n, recorded_at=n)))
    path.chmod(0o600)
    return path
def worker(path):
    try:
        results.put(poster.deliver_one(path, home=home))
    except Exception as error:
        results.put(repr(error))
def overlap(first_path, second_path):
    entered.clear(); finish.clear()
    first = ctx.Process(target=worker, args=(first_path,))
    first.start()
    assert entered.wait(20), "first poster must reach creation"
    second = ctx.Process(target=worker, args=(second_path,))
    second.start()
    assert results.get(timeout=20) == "mid-delivery"
    second.join(20)
    assert second.exitcode == 0 and first_path.exists() and second_path.exists()
    finish.set()
    assert results.get(timeout=20) == "posted-pinned"
    first.join(20)
    assert first.exitcode == 0
path = payload(1)
overlap(path, path)
assert posts.value == 1 and not path.exists()
assert poster.waiting_pin_load(home)["message_id"] == "1"
recreate = True
older, newer = payload(2), payload(3)
overlap(older, newer)
assert posts.value == 2 and not older.exists() and newer.exists()
recreate = False
assert poster.deliver_one(newer, home=home) == "edited"
assert poster.waiting_pin_load(home)["snapshot_id"] == 3 and posts.value == 2
stale = payload(1)
assert poster.deliver_one(stale, home=home) == "superseded"
assert not stale.exists() and posts.value == 2
assert not list(home.joinpath("state").glob(".ext-waiting-pin.*"))
assert not list(box.glob("*.inflight"))
PYTEST
  pass "16 competing pin posters share the existing exclusive claim across snapshots"
}

test_17_refresh_capture_and_publication_are_serialized() {
  local home fake
  home="$TMP_ROOT/c17"
  setup_home "$home"
  hold_call "$home" choice "Approve the now answered call" waiting
  fake="$home/fakebin"
  mkdir "$fake"
  cat > "$fake/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = list ]; then
  if [ "$REFRESH_ACTOR" = first ]; then
    listing=$("$REAL_TASKS_AXI" "$@") || exit "$?"
    touch "$RACE_HOME/first-captured"
    while [ ! -f "$RACE_HOME/first-release" ]; do sleep 0.05; done
    printf '%s\n' "$listing"
    exit 0
  fi
  touch "$RACE_HOME/second-read"
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  # Pause a failed claim link until the owner releases it, reproducing the
  # contention-to-release race before the contender validates the destination.
  cat > "$fake/ln" <<'SH'
#!/usr/bin/env bash
"$REAL_LN" "$@"
rc=$?
dest="${@: -1}"
if [ "$REFRESH_ACTOR" = second ] && [ "$rc" -ne 0 ]; then
  case "$dest" in
    *.inflight)
      touch "$RACE_HOME/second-contended"
      while [ -e "$dest" ]; do sleep 0.05; done
      ;;
  esac
fi
exit "$rc"
SH
  chmod 700 "$fake/tasks-axi" "$fake/ln"
  home_env "$home" env PYTHONPATH="$PLUGIN" DISCORD_BOT_TOKEN=test-token REAL_TASKS_AXI="$TASKS_AXI_BIN" REAL_LN="$(command -v ln)" RACE_HOME="$home" PATH="$fake:$BASE_PATH" \
    "$PYTHON_BIN" - "$home" "$REFRESH" <<'PYTEST' || fail "overlapping refreshes must preserve capture and publication order"
import json, os, subprocess, sys, time
from pathlib import Path
import outbox_poster as poster
home, refresh = Path(sys.argv[1]), sys.argv[2]
def wait_for(name):
    until = time.monotonic() + 20
    while not (home / name).exists():
        assert time.monotonic() < until, f"timed out waiting for {name}"
        time.sleep(.05)
def launch(actor):
    return subprocess.Popen([refresh, "refresh", "--force"], env=dict(os.environ, REFRESH_ACTOR=actor), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
first = launch("first")
second = None
try:
    wait_for("first-captured")
    subprocess.run([os.environ["REAL_TASKS_AXI"], "done", "choice"], cwd=home / "data", check=True, capture_output=True)
    second = launch("second")
    wait_for("second-contended")
    assert not (home / "second-read").exists(), "a competing refresh read the board before obtaining the publication claim"
    (home / "first-release").touch()
    for process in (first, second):
        stdout, stderr = process.communicate(timeout=20)
        assert process.returncode == 0 and "refreshed" in stdout, (stdout, stderr)
    assert (home / "second-read").exists()
finally:
    (home / "first-release").touch()
    for process in (first, second):
        if process is not None and process.poll() is None:
            process.kill(); process.wait()
paths = sorted(home.joinpath("state/ext-outbox").glob("waiting-pin.*.json"))
assert len(paths) == 2
records = [json.loads(path.read_text()) for path in paths]
assert "Approve the now answered call" in records[0]["text"]
assert "Nothing waiting - all clear." in records[1]["text"]
assert int(records[0]["snapshot_id"]) < int(records[1]["snapshot_id"])
contents = []
def edge(action, path, token, body):
    if action in ("post", "edit"):
        contents.append(body["content"])
    return {"id": "message", "pinned": True}
poster.waiting_pin_http = edge
assert poster.drain_outbox(home=home) == ["posted-pinned", "edited"]
assert "Nothing waiting - all clear." in contents[-1]
assert not list(home.joinpath("state/ext-outbox").glob("*.inflight"))
PYTEST
  pass "17 overlapping refreshes capture and publish in the same order"
}

test_1b_long_titles_render_cleanly_without_ids_or_commands
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

test_11_unchanged_reconciliation_and_pending_limits
test_12_landing_and_dated_calls

test_13_pr_selection_uses_state_fields

test_14_existing_task_captain_holds

test_15_pin_targets_and_reply_separation
test_16_competing_pin_posters_share_one_claim

test_17_refresh_capture_and_publication_are_serialized

echo "all fm-ext-waiting-pin tests passed"
