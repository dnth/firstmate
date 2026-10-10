#!/usr/bin/env bash
# Behavior tests for the gateway plugin's Discord destination resolution.
#
# Hermetic: no Discord network, no token, no gateway process. Python drives
# contrib/hermes-gateway-firstmate-comms/intake.py with synthetic MessageEvent
# shapes mirroring the installed Hermes 0.20.5 Discord adapter
# (_build_slash_event plus the interaction's guild/message ids) and asserts
# the task-local pre_gateway_dispatch -> handle_fm_command contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH="$PYTHON_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ext-plugin-dest)

PLUGIN="$ROOT/contrib/hermes-gateway-firstmate-comms"

GUILD=111111111111111111
CHANNEL=222222222222222222
AUTHOR=555555555555555555
DENIED=666666666666666666

setup_home() {
  local home=$1
  mkdir -p "$home/config"
  : > "$home/config/ext-bridge"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
}

plugin_env() {
  GUILD="$GUILD" CHANNEL="$CHANNEL" AUTHOR="$AUTHOR" DENIED="$DENIED" \
  PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$1" "$ROOT" "$PLUGIN"
}

# --- 1. task-local bind: identical text from two authors never crosses ------

test_1_interleaved_identical_text_keeps_authority() {
  local out
  out=$(plugin_env x <<'PY'
import asyncio, os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from types import SimpleNamespace
import intake

def make_event(author, msgid):
    source = SimpleNamespace(
        platform=SimpleNamespace(value="discord"),
        chat_id=os.environ["CHANNEL"], chat_type="thread",
        user_id=author, user_name="u", thread_id=os.environ["CHANNEL"],
        scope_id=os.environ["GUILD"], guild_id=os.environ["GUILD"],
        message_id=None)
    raw = SimpleNamespace(id=msgid, guild_id=os.environ["GUILD"],
                          channel_id=os.environ["CHANNEL"],
                          user=SimpleNamespace(id=author))
    return SimpleNamespace(text="/fm identical order", source=source,
                           raw_message=raw, message_id=None)

async def run_one(author, msgid, delay):
    intake.pre_gateway_dispatch_hook(make_event(author, msgid))
    await asyncio.sleep(delay)
    return intake.resolve_destination("identical order")

async def main():
    a, b = await asyncio.gather(
        run_one(os.environ["AUTHOR"], "111111111111111111", 0.05),
        run_one(os.environ["DENIED"], "222222222222222222", 0.0))
    print("a=%s/%s" % (a["author"], a["message_id"]))
    print("b=%s/%s" % (b["author"], b["message_id"]))

asyncio.run(main())
PY
  )
  assert_contains "$out" "a=$AUTHOR/111111111111111111" "interleaved allowlisted task must keep its own author"
  assert_contains "$out" "b=$DENIED/222222222222222222" "interleaved denied task must keep its own author"
  pass "1 interleaved identical /fm text never crosses author authority"
}
# --- 2. non-allowlisted author is still refused with the allowlist sentence --

test_2_denied_author_gets_allowlist_refusal() {
  local home out
  home="$TMP_ROOT/c2"
  setup_home "$home"
  out=$(plugin_env "$home" <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from types import SimpleNamespace
import intake
os.environ["FM_HOME"] = sys.argv[1]
os.environ["FM_ROOT_OVERRIDE"] = sys.argv[2]
source = SimpleNamespace(
    platform=SimpleNamespace(value="discord"),
    chat_id=os.environ["CHANNEL"], chat_type="thread",
    user_id=os.environ["DENIED"], user_name="outsider",
    thread_id=os.environ["CHANNEL"],
    scope_id=os.environ["GUILD"], guild_id=os.environ["GUILD"],
    message_id=None)
raw = SimpleNamespace(id="333333333333333333", guild_id=os.environ["GUILD"],
                      channel_id=os.environ["CHANNEL"],
                      user=SimpleNamespace(id=os.environ["DENIED"]))
event = SimpleNamespace(text="/fm try to get in", source=source,
                        raw_message=raw, message_id=None)
intake.pre_gateway_dispatch_hook(event)
print(intake.handle_fm_command("try to get in"))
PY
  )
  assert_contains "$out" "it is not on the local allowlist" "a denied author must get the allowlist refusal"
  pass "2 non-allowlisted author is refused with the existing refusal sentence"
}

# --- 3. slash-originated reply target is the originating thread -------------
test_3_reply_target_is_originating_thread() {
  local home slug out target
  home="$TMP_ROOT/c3"
  setup_home "$home"
  out=$(plugin_env "$home" <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from types import SimpleNamespace
import intake
os.environ["FM_HOME"] = sys.argv[1]
os.environ["FM_ROOT_OVERRIDE"] = sys.argv[2]
source = SimpleNamespace(
    platform=SimpleNamespace(value="discord"),
    chat_id=os.environ["CHANNEL"], chat_type="thread",
    user_id=os.environ["AUTHOR"], user_name="captain",
    thread_id=os.environ["CHANNEL"],
    scope_id=os.environ["GUILD"], guild_id=os.environ["GUILD"],
    message_id=None)
raw = SimpleNamespace(id="444444444444444444", guild_id=os.environ["GUILD"],
                      channel_id=os.environ["CHANNEL"],
                      user=SimpleNamespace(id=os.environ["AUTHOR"]))
event = SimpleNamespace(text="/fm status please", source=source,
                        raw_message=raw, message_id=None)
intake.pre_gateway_dispatch_hook(event)
print(intake.handle_fm_command("status please"))
PY
  )
  assert_contains "$out" "Aye, captain" "allowlisted slash event must ack"
  slug=$(printf '%s' "discord:${GUILD}:${CHANNEL}:${CHANNEL}:444444444444444444" | sha256sum | awk '{print $1}')
  target=$(jq -r '.thread_id' "$home/state/ext-context/${slug}.json")
  [ "$target" = "$CHANNEL" ] || fail "reply target must be the originating thread, got $target"
  pass "3 slash-originated requests resolve replies to the originating thread"
}

# --- 4. unresolvable destination names the Hermes version, never silence ----

test_4_unresolvable_names_hermes_version() {
  local out
  out=$(plugin_env x <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from types import ModuleType
from unittest.mock import patch
import intake
intake.bind_event_destination(None)
for version in ("0.20.0", "0.20.9"):
    hermes = ModuleType("hermes_cli")
    hermes.__version__ = version
    with patch.dict(sys.modules, {"hermes_cli": hermes}):
        reply = intake.handle_fm_command("no destination anywhere")
        assert f"(Hermes {version})" in reply, reply
        print(reply)
with patch.dict(sys.modules, {"hermes_cli": None}):
    reply = intake.handle_fm_command("no destination anywhere")
    assert "(Hermes unknown)" in reply, reply
    print(reply)
PY
  ) || fail "Hermes version diagnostic failed"
  assert_contains "$out" "destination is incomplete" "an unresolvable destination must say so"
  assert_contains "$out" "Hermes 0.20.0" "the refusal must name the running Hermes version"
  assert_contains "$out" "Hermes 0.20.9" "the refusal must reflect a different Hermes version"
  pass "4 unresolvable destination fails loudly with the Hermes version"
}

# --- 5. every event rebinds: a stale destination never leaks ----------------

test_5_rebind_clears_stale_destination() {
  local out
  out=$(plugin_env x <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from types import SimpleNamespace
import intake
source = SimpleNamespace(
    platform=SimpleNamespace(value="discord"),
    chat_id=os.environ["CHANNEL"], chat_type="thread",
    user_id=os.environ["AUTHOR"], user_name="captain",
    thread_id=os.environ["CHANNEL"],
    scope_id=os.environ["GUILD"], guild_id=os.environ["GUILD"],
    message_id=None)
raw = SimpleNamespace(id="555555555555555555", guild_id=os.environ["GUILD"],
                      channel_id=os.environ["CHANNEL"],
                      user=SimpleNamespace(id=os.environ["AUTHOR"]))
intake.pre_gateway_dispatch_hook(SimpleNamespace(
    text="/fm first order", source=source, raw_message=raw, message_id=None))
print("first=" + str(intake.destination_valid(intake.resolve_destination("first order"))))
intake.pre_gateway_dispatch_hook(SimpleNamespace(
    text="just chatting", source=source, raw_message=raw, message_id=None))
print("after=" + str(intake.destination_valid(intake.resolve_destination("second order"))))
PY
  )
  assert_contains "$out" "first=True" "the bound event must resolve"
  assert_contains "$out" "after=False" "a later non-/fm event must clear the stale destination"
  pass "5 every event rebinds so no stale destination leaks"
}

test_6_hook_registration_errors_propagate() {
  local out
  out=$(plugin_env x <<'PY'
import importlib.util, sys
from pathlib import Path
from unittest.mock import Mock, patch
spec = importlib.util.spec_from_file_location("fm_plugin", Path(sys.argv[3]) / "__init__.py")
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)
with patch.object(plugin, "start_outbox_watcher") as watcher:
    ctx = Mock()
    error = RuntimeError("hook registration failed")
    ctx.register_hook.side_effect = error
    try:
        plugin.register(ctx)
    except RuntimeError as exc:
        assert exc is error
    else:
        raise AssertionError("hook registration failure was hidden")
    ctx.register_command.assert_called_once_with(
        "fm", handler=plugin.handle_fm_command,
        description="Send this request to the local Firstmate Communication Officer",
        args_hint="request")
    watcher.assert_not_called()
    ctx = Mock()
    plugin.register(ctx)
    ctx.register_command.assert_called_once()
    ctx.register_hook.assert_called_once_with("pre_gateway_dispatch", plugin.pre_gateway_dispatch_hook)
    watcher.assert_called_once_with()
print("registration errors propagate; successful registration starts watcher")
PY
  ) || fail "plugin registration behavior failed"
  assert_contains "$out" "registration errors propagate" "hook errors must remain visible"
  pass "6 required hook registration errors propagate and successful startup works"
}

# --- 7. /fm inside a thread is authorised by the thread's parent channel ----
#
# Allowlist rules name a channel. In a thread Hermes reports the thread as the
# chat, so the plugin must authorise against the thread's parent channel and
# still reply into the thread. A top-level channel also has a parent (its
# category), which must never replace the channel.

test_7_thread_uses_parent_channel_for_allowlist_and_replies_in_thread() {
  local home out slug ctx target
  home="$TMP_ROOT/c7"
  setup_home "$home"
  out=$(THREAD=777777777777777777 OTHER=888888888888888888 CATEGORY=999999999999999999 \
    plugin_env "$home" <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from types import SimpleNamespace
import intake
os.environ["FM_HOME"] = sys.argv[1]
os.environ["FM_ROOT_OVERRIDE"] = sys.argv[2]
G, C, A = os.environ["GUILD"], os.environ["CHANNEL"], os.environ["AUTHOR"]
T, O, K = os.environ["THREAD"], os.environ["OTHER"], os.environ["CATEGORY"]

def text_in_thread(thread, parent, msgid):
    # Shape of the adapter's text-message source inside a thread.
    source = SimpleNamespace(platform=SimpleNamespace(value="discord"),
        chat_id=thread, chat_type="thread", user_id=A, user_name="captain",
        thread_id=thread, parent_chat_id=parent, scope_id=G, guild_id=G,
        message_id=msgid)
    raw = SimpleNamespace(id=msgid, guild_id=G, channel_id=thread,
                          author=SimpleNamespace(id=A))
    return SimpleNamespace(text="/fm status please", source=source, raw_message=raw)

def slash(chat, chat_type, channel_parent, msgid):
    # Shape of _build_slash_event: no parent_chat_id; the interaction's channel
    # carries parent_id (the parent channel for a thread, the category otherwise).
    source = SimpleNamespace(platform=SimpleNamespace(value="discord"),
        chat_id=chat, chat_type=chat_type, user_id=A, user_name="captain",
        thread_id=chat if chat_type == "thread" else None, message_id=None)
    raw = SimpleNamespace(id=msgid, guild_id=G, channel_id=chat,
                          channel=SimpleNamespace(id=chat, parent_id=channel_parent),
                          user=SimpleNamespace(id=A))
    return SimpleNamespace(text="/fm status please", source=source, raw_message=raw)

cases = [
    ("text-thread", text_in_thread(T, C, "700000000000000001")),
    ("slash-thread", slash(T, "thread", C, "700000000000000002")),
    ("slash-top", slash(C, "group", K, "700000000000000003")),
    ("stranger-text-thread", text_in_thread(T, O, "700000000000000004")),
    ("stranger-slash-thread", slash(T, "thread", O, "700000000000000005")),
    ("other-channel", slash(O, "group", K, "700000000000000006")),
]
for name, event in cases:
    intake.pre_gateway_dispatch_hook(event)
    print("%s=%s" % (name, intake.handle_fm_command("status please")))
PY
  )
  for name in text-thread slash-thread slash-top; do
    assert_contains "$out" "$name=Aye, captain" "/fm $name under the allowlisted channel must be accepted"
  done
  for name in stranger-text-thread stranger-slash-thread other-channel; do
    assert_contains "$out" "$name=Firstmate refused this request: it is not on the local allowlist." \
      "/fm $name outside the allowlisted channel must be refused"
  done
  for msg in 700000000000000001 700000000000000002; do
    slug=$(printf '%s' "discord:${GUILD}:${CHANNEL}:777777777777777777:${msg}" | sha256sum | awk '{print $1}')
    ctx="$home/state/ext-context/${slug}.json"
    [ -f "$ctx" ] || fail "a thread request must be recorded against its parent channel and thread ($msg)"
    target=$(jq -r '.channel_id + ":" + .thread_id' "$ctx")
    [ "$target" = "$CHANNEL:777777777777777777" ] \
      || fail "a thread request must keep the parent channel and reply into the thread, got $target"
  done
  # The answer firstmate emits is what the outbox poster posts: it must target
  # the thread the captain asked in.
  printf 'Aye, all shipshape.' > "$home/ans.txt"
  PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-ext-emit.sh" \
    --request-id "discord:${GUILD}:${CHANNEL}:777777777777777777:700000000000000001" \
    --kind answer --generation 1 --text-file "$home/ans.txt" >/dev/null \
    || fail "an answer to a thread request must be emitted"
  slug=$(printf '%s' "discord:${GUILD}:${CHANNEL}:777777777777777777:700000000000000001" | sha256sum | awk '{print $1}')
  target=$(jq -r '.thread_id' "$home/state/ext-outbox/${slug}.answer.1.json")
  [ "$target" = 777777777777777777 ] || fail "the reply to a thread request must post into the thread, got $target"
  slug=$(printf '%s' "discord:${GUILD}:${CHANNEL}:${CHANNEL}:700000000000000003" | sha256sum | awk '{print $1}')
  [ -f "$home/state/ext-context/${slug}.json" ] \
    || fail "a top-level channel request must keep its own channel, never its category"
  pass "7 /fm in a thread is authorised by its parent channel and replies into the thread"
}

test_1_interleaved_identical_text_keeps_authority
test_2_denied_author_gets_allowlist_refusal
test_3_reply_target_is_originating_thread
test_4_unresolvable_names_hermes_version
test_5_rebind_clears_stale_destination
test_6_hook_registration_errors_propagate
test_7_thread_uses_parent_channel_for_allowlist_and_replies_in_thread

echo "all fm-ext-plugin-dest tests passed"
