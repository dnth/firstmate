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

test_1_interleaved_identical_text_keeps_authority
test_2_denied_author_gets_allowlist_refusal
test_3_reply_target_is_originating_thread
test_4_unresolvable_names_hermes_version
test_5_rebind_clears_stale_destination
test_6_hook_registration_errors_propagate

echo "all fm-ext-plugin-dest tests passed"
