#!/usr/bin/env bash
# Behavior tests for the gateway plugin's Discord destination resolution and
# its message paths: the dedicated channel, replies to Firstmate's own posts,
# and the seen/warning reactions on the captain's message.
#
# Hermetic: no Discord network, no real token, no gateway process. Python
# drives contrib/hermes-gateway-firstmate-comms/intake.py with synthetic
# MessageEvent shapes mirroring the installed Hermes 0.20.5 Discord adapter
# (_build_slash_event plus the interaction's guild/message ids, and the text
# message event built by _handle_message) and asserts the task-local
# pre_gateway_dispatch -> handle_fm_command contract. Reactions go to a local
# stand-in for Discord's REST edge.
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
  FM_EVENTS_DIR="$TMP_ROOT/fixtures" \
  PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$1" "$ROOT" "$PLUGIN"
}

# Shared synthetic events and a recording REST edge for the message-path cases.
mkdir -p "$TMP_ROOT/fixtures"
cat > "$TMP_ROOT/fixtures/fmevents.py" <<'PY'
"""Synthetic Hermes 0.20.5 Discord events and a local REST edge."""
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

G, C, A = os.environ["GUILD"], os.environ["CHANNEL"], os.environ["AUTHOR"]
DEFAULT, REPLY, MEMBER_JOIN = 0, 19, 7


def message(msgid, text, author=A, channel=C, thread=None, kind=DEFAULT,
            bot=False, edited=False, webhook=None, reply_to=None, reply_text=None):
    """A guild text message as _handle_message builds it; raw is the Message."""
    chat = thread or channel
    source = SimpleNamespace(
        platform=SimpleNamespace(value="discord"), chat_id=chat,
        chat_type="thread" if thread else "group", user_id=author,
        user_name="u", thread_id=thread,
        parent_chat_id=channel if thread else None, scope_id=G, guild_id=G,
        message_id=msgid, is_bot=bot)
    reference = None
    if reply_to:
        resolved = None
        if reply_text is not None:
            resolved = SimpleNamespace(id=int(reply_to), content=reply_text)
        reference = SimpleNamespace(message_id=int(reply_to), resolved=resolved)
    raw = SimpleNamespace(
        id=int(msgid), guild_id=int(G), channel_id=int(chat),
        type=SimpleNamespace(value=kind),
        author=SimpleNamespace(id=int(author), bot=bot, system=False),
        webhook_id=webhook,
        edited_at="2026-10-11T00:00:00+00:00" if edited else None,
        reference=reference)
    return SimpleNamespace(text=text, source=source, raw_message=raw,
                           message_id=msgid, reply_to_message_id=reply_to,
                           reply_to_text=reply_text)


def slash(msgid, text, author=A, channel=C):
    """A /fm invocation as _build_slash_event builds it; raw is the Interaction."""
    source = SimpleNamespace(
        platform=SimpleNamespace(value="discord"), chat_id=channel,
        chat_type="group", user_id=author, user_name="u", thread_id=None,
        scope_id=G, guild_id=G, message_id=None)
    raw = SimpleNamespace(id=int(msgid), guild_id=int(G), channel_id=int(channel),
                          type=SimpleNamespace(value=2),
                          user=SimpleNamespace(id=int(author)))
    return SimpleNamespace(text=text, source=source, raw_message=raw, message_id=None)


def inbox(home):
    """Recorded requests keyed by Discord message id."""
    folder = Path(home) / "state" / "ext-inbox"
    records = [json.loads(p.read_text()) for p in folder.glob("*.json")] if folder.is_dir() else []
    return {record["message_id"]: record for record in records}


def wake_rows(home, slug):
    queue = Path(home) / "state" / ".wake-queue"
    if not queue.is_file():
        return 0
    return sum(1 for line in queue.read_text().splitlines() if line.endswith("ext-request " + slug))


class Edge:
    """Local stand-in for Discord's REST edge; records each reaction PUT."""

    def __init__(self, status=204):
        self.seen = []
        edge = self

        class Handler(BaseHTTPRequestHandler):
            def do_PUT(self):
                edge.seen.append((self.path, self.headers.get("User-Agent", "")))
                self.send_response(status)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d/api/v10" % self.server.server_address[1]

    def wait(self, count, timeout=10.0):
        """Wait until count reactions arrived; return the recorded paths."""
        deadline = time.monotonic() + timeout
        while len(self.seen) < count and time.monotonic() < deadline:
            time.sleep(0.02)
        return [path for path, _agent in self.seen]


def setup(home, root, status=204):
    """Point the plugin at this home and its reactions at a fresh edge."""
    import outbox_poster
    os.environ["FM_HOME"] = home
    os.environ["FM_ROOT_OVERRIDE"] = root
    os.environ["DISCORD_BOT_TOKEN"] = "test-bot-token"
    edge = Edge(status)
    outbox_poster.DISCORD_API_BASE = edge.base
    return edge


def reaction_path(channel, message, emoji):
    from urllib.parse import quote
    return "/api/v10/channels/%s/messages/%s/reactions/%s/@me" % (channel, message, quote(emoji, safe=""))
PY

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

# --- 8. the dedicated channel turns a plain message into one request --------
#
# config/ext-channel names one channel. Every ordinary message an allowlisted
# author sends there, or in a thread under it, becomes a request through the
# same intake as /fm, so it carries the same authority, and the general agent
# never also answers it. The request's message gets the seen reaction.

test_8_dedicated_channel_message_is_one_request_with_slash_authority() {
  local home out
  home="$TMP_ROOT/c8"
  setup_home "$home"
  out=$(THREAD=777777777777777777 plugin_env "$home" <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
from pathlib import Path
import fmevents as ev
home, root = sys.argv[1], sys.argv[2]
edge = ev.setup(home, root)
import intake, outbox_poster
G, C, A, T = ev.G, ev.C, ev.A, os.environ["THREAD"]
SEEN = outbox_poster.REACT_SEEN

def hook(event):
    return (intake.pre_gateway_dispatch_hook(event) or {}).get("action")

# Off until configured: a plain message keeps its normal path.
assert hook(ev.message("810000000000000001", "ship the docs fix")) is None
assert ev.inbox(home) == {}, "an unconfigured channel must record nothing"

Path(home, "config", "ext-channel").write_text("# Firstmate's channel\n%s\n" % C)
event = ev.message("810000000000000002", "ship the docs fix")
assert hook(event) == "skip", "a channel request must not also reach the general agent"
assert hook(event) == "skip", "a redelivered message stays Firstmate's"
records = ev.inbox(home)
assert list(records) == ["810000000000000002"], records
record = records["810000000000000002"]
assert record["text"] == "ship the docs fix", record
assert record["origin"] == "message", record
assert (record["channel_id"], record["thread_id"], record["author"]) == (C, C, A), record
assert ev.wake_rows(home, record["slug"]) == 1, "one message must raise exactly one wake"
seen = edge.wait(2)
assert set(seen) == {ev.reaction_path(C, "810000000000000002", SEEN)}, seen
assert all(agent.startswith("DiscordBot (") for _path, agent in edge.seen), edge.seen

# The same authority as /fm from the same author and channel.
assert intake.pre_gateway_dispatch_hook(ev.slash("810000000000000003", "/fm ship it")) is None
print("slash=" + intake.handle_fm_command("ship it"))
records = ev.inbox(home)
assert records["810000000000000003"]["authority"] == record["authority"] == "standing", records

# A broader channel rule grants confirm on both paths alike.
Path(home, "config", "ext-allowlist").write_text("%s:%s\n" % (G, C))
assert hook(ev.message("810000000000000004", "what is waiting on me")) == "skip"
intake.pre_gateway_dispatch_hook(ev.slash("810000000000000005", "/fm what is waiting on me"))
intake.handle_fm_command("what is waiting on me")
records = ev.inbox(home)
assert records["810000000000000004"]["authority"] == "confirm", records
assert records["810000000000000005"]["authority"] == "confirm", records

# Typed /fm text and a thread under the channel are requests too.
assert hook(ev.message("810000000000000006", "/fm check the build")) == "skip"
assert hook(ev.message("810000000000000007", "and the notes", thread=T)) == "skip"
records = ev.inbox(home)
assert records["810000000000000006"]["text"] == "check the build", records
thread_record = records["810000000000000007"]
assert (thread_record["channel_id"], thread_record["thread_id"]) == (C, T), thread_record
assert ev.reaction_path(T, "810000000000000007", SEEN) in edge.wait(5), edge.seen
print("dedicated-channel-ok")
PY
  ) || fail "dedicated-channel request case failed: $out"
  assert_contains "$out" "slash=Aye, captain" "the /fm comparison request must be accepted"
  assert_contains "$out" "dedicated-channel-ok" "the dedicated channel must record one request per message"
  pass "8 a dedicated-channel message is one request with the same authority as /fm"
}

# --- 9. nothing else in or outside the channel becomes a request ------------

test_9_dedicated_channel_ignores_everyone_and_everything_else() {
  local home out
  home="$TMP_ROOT/c9"
  setup_home "$home"
  out=$(OTHER=888888888888888888 plugin_env "$home" <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
from pathlib import Path
import fmevents as ev
home, root = sys.argv[1], sys.argv[2]
edge = ev.setup(home, root)
import intake
G, C, A, D, O = ev.G, ev.C, ev.A, os.environ["DENIED"], os.environ["OTHER"]
channel_file = Path(home, "config", "ext-channel")
channel_file.write_text(C + "\n")

def hook(event):
    return (intake.pre_gateway_dispatch_hook(event) or {}).get("action")

# Someone the allowlist does not admit is ignored outright in the channel.
assert hook(ev.message("820000000000000001", "let me in", author=D)) == "skip"

# A guild-wide rule would admit anything below, so only the path decides.
Path(home, "config", "ext-allowlist").write_text("%s:%s:%s\n%s\n" % (G, C, A, G))
cases = {
    "bot": ev.message("820000000000000002", "beep", bot=True),
    "webhook": ev.message("820000000000000003", "hook post", webhook=999),
    "edited": ev.message("820000000000000004", "edited order", edited=True),
    "system": ev.message("820000000000000005", "joined", kind=ev.MEMBER_JOIN),
    "other-channel": ev.message("820000000000000006", "elsewhere", channel=O),
    "slash-interaction": ev.slash("820000000000000007", "/fm from the pop-up"),
}
for name, event in cases.items():
    assert hook(event) is None, name

# A malformed, ambiguous, or symlinked setting leaves the channel off.
for content in ("", "general\n", "%s\n%s\n" % (C, O)):
    channel_file.write_text(content)
    assert hook(ev.message("820000000000000008", "still off")) is None, content
real = Path(home, "real-channel")
real.write_text(C + "\n")
channel_file.unlink()
channel_file.symlink_to(real)
assert hook(ev.message("820000000000000009", "still off")) is None, "symlink"

assert ev.inbox(home) == {}, ev.inbox(home)
time.sleep(0.3)
assert edge.seen == [], edge.seen
print("ignored-ok")
PY
  ) || fail "dedicated-channel negative case failed: $out"
  assert_contains "$out" "ignored-ok" "only allowlisted human messages in the channel may become requests"
  pass "9 the dedicated channel ignores other authors, bots, edits, system messages, and other channels"
}

# --- 10. a reply to a Firstmate post continues that conversation ------------
#
# A Discord reply to one of Firstmate's own posted messages becomes a request
# anywhere the gateway listens, carrying the replied-to id, Firstmate's
# original request id, and that message's text cut to 1000 characters.

test_10_reply_to_firstmate_post_carries_its_context() {
  local home out
  home="$TMP_ROOT/c10"
  setup_home "$home"
  out=$(THREAD=777777777777777777 plugin_env "$home" <<'PY'
import os, subprocess, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
from pathlib import Path
import fmevents as ev
home, root = sys.argv[1], sys.argv[2]
edge = ev.setup(home, root)
import intake, outbox_poster
G, C, A, D, T = ev.G, ev.C, ev.A, os.environ["DENIED"], os.environ["THREAD"]

def hook(event):
    return (intake.pre_gateway_dispatch_hook(event) or {}).get("action")

# Firstmate answers a /fm request; the poster keeps the Discord id it posted.
intake.pre_gateway_dispatch_hook(ev.slash("830000000000000001", "/fm docs status"))
assert intake.handle_fm_command("docs status").startswith("Aye, captain")
rid = "discord:%s:%s:%s:830000000000000001" % (G, C, C)
Path(home, "ans.txt").write_text("Docs fix is ready. Shall I merge it?")
subprocess.run([os.path.join(root, "bin", "fm-ext-emit.sh"), "--request-id", rid,
                "--kind", "answer", "--generation", "1",
                "--text-file", os.path.join(home, "ans.txt")], check=True, capture_output=True)
POSTED = "830000000000000900"
sent = outbox_poster.drain_outbox(
    send=lambda _payload: {"ok": True, "discord_message_id": POSTED}, home=Path(home))
assert sent == ["sent"], sent

quoted = "Docs fix is ready. Shall I merge it? " + "\u00e9" * 2000
assert hook(ev.message("830000000000000002", "yes", kind=ev.REPLY,
                       reply_to=POSTED, reply_text=quoted)) == "skip"
record = ev.inbox(home)["830000000000000002"]
context = record["reply_to"]
assert (record["text"], record["origin"]) == ("yes", "message"), record
assert (context["message_id"], context["request_id"]) == (POSTED, rid), context
assert context["text"] == quoted[:1000] + "\u2026", len(context["text"])

# The same continuation works from a thread under the channel.
assert hook(ev.message("830000000000000003", "go ahead", thread=T, kind=ev.REPLY,
                       reply_to=POSTED, reply_text="Shall I merge it?")) == "skip"
threaded = ev.inbox(home)["830000000000000003"]
assert (threaded["channel_id"], threaded["thread_id"]) == (C, T), threaded
assert threaded["reply_to"]["request_id"] == rid, threaded

# A reply to anyone else's message, or from an author the allowlist refuses,
# keeps its normal path and records nothing.
assert hook(ev.message("830000000000000004", "agreed", kind=ev.REPLY,
                       reply_to="830000000000000999", reply_text="someone else")) is None
assert hook(ev.message("830000000000000005", "yes", author=D, kind=ev.REPLY,
                       reply_to=POSTED, reply_text="Shall I merge it?")) is None
assert set(ev.inbox(home)) == {"830000000000000001", "830000000000000002",
                               "830000000000000003"}, sorted(ev.inbox(home))

# Inside the dedicated channel any reply is a request; only a reply to
# Firstmate carries reply context.
Path(home, "config", "ext-channel").write_text(C + "\n")
assert hook(ev.message("830000000000000006", "noted", kind=ev.REPLY,
                       reply_to="830000000000000999", reply_text="someone else")) == "skip"
assert "reply_to" not in ev.inbox(home)["830000000000000006"]
assert ev.reaction_path(C, "830000000000000002", outbox_poster.REACT_SEEN) in edge.wait(3)
print("reply-ok")
PY
  ) || fail "reply continuation case failed: $out"
  assert_contains "$out" "reply-ok" "a reply to Firstmate must carry its context and nothing else may"
  pass "10 a reply to a Firstmate post becomes a request carrying the replied-to id and bounded text"
}

# --- 11. reactions are best effort; an unrecorded request warns -------------

test_11_reaction_failure_never_blocks_and_intake_failure_warns() {
  local home out
  home="$TMP_ROOT/c11"
  setup_home "$home"
  out=$(plugin_env "$home" <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
from pathlib import Path
import fmevents as ev
home, root = sys.argv[1], sys.argv[2]
edge = ev.setup(home, root, status=500)
import intake, outbox_poster
C = ev.C
Path(home, "config", "ext-channel").write_text(C + "\n")

def hook(event):
    return (intake.pre_gateway_dispatch_hook(event) or {}).get("action")

# Discord refusing the reaction changes nothing about the request.
assert hook(ev.message("840000000000000001", "status please")) == "skip"
assert "840000000000000001" in ev.inbox(home)
assert edge.wait(1) == [ev.reaction_path(C, "840000000000000001", outbox_poster.REACT_SEEN)]

# A request the bridge cannot record is flagged on the message, not dropped.
Path(home, "config", "ext-bridge").rename(Path(home, "config", "ext-bridge.off"))
assert hook(ev.message("840000000000000002", "status again")) == "skip"
assert "840000000000000002" not in ev.inbox(home)
assert ev.reaction_path(C, "840000000000000002", outbox_poster.REACT_FAILED) in edge.wait(2)
from unittest.mock import patch

bridge = Path(home, "config", "ext-bridge")
bridge_off = bridge.with_name("ext-bridge.off")
# A thread under the dedicated channel also reads its context from the REST
# edge, whose server threads would count against the patched Thread below.
# Without a token that read stops before any request, which is the case
# under test: the reaction machinery failing, not the context read.
os.environ.pop("DISCORD_BOT_TOKEN", None)
failures = (
    ("intake._poster", ImportError("poster unavailable")),
    ("intake._poster", RuntimeError("poster load failed")),
    ("intake.threading.Thread", RuntimeError("thread construction failed")),
    ("intake.threading.Thread.start", RuntimeError("cannot allocate thread")),
)
sequence = 10
for accepted in (True, False):
    if accepted:
        bridge_off.rename(bridge)
    else:
        bridge.rename(bridge_off)
    for target, error in failures:
        for thread in (None, "777777777777777777"):
            sequence += 1
            message_id = str(840000000000000000 + sequence)
            with patch(target, side_effect=error) as failed:
                assert hook(ev.message(message_id, "status", thread=thread)) == "skip", (target, accepted)
                assert failed.call_count == 1, (target, failed.call_count)
            records = ev.inbox(home)
            assert (message_id in records) == accepted, (target, accepted, records)
            if accepted:
                assert ev.wake_rows(home, records[message_id]["slug"]) == 1
assert len(edge.seen) == 2, edge.seen
print("best-effort-ok")
PY
  ) || fail "reaction failure case failed: $out"
  assert_contains "$out" "best-effort-ok" "a reaction failure must not affect the request"
  pass "11 reaction failures never block a request and an unrecorded request gets the warning reaction"
}

test_1_interleaved_identical_text_keeps_authority
test_2_denied_author_gets_allowlist_refusal
test_3_reply_target_is_originating_thread
test_4_unresolvable_names_hermes_version
test_5_rebind_clears_stale_destination
test_6_hook_registration_errors_propagate
test_7_thread_uses_parent_channel_for_allowlist_and_replies_in_thread
test_8_dedicated_channel_message_is_one_request_with_slash_authority
test_9_dedicated_channel_ignores_everyone_and_everything_else
test_10_reply_to_firstmate_post_carries_its_context
test_11_reaction_failure_never_blocks_and_intake_failure_warns
test_attachment_injection_never_becomes_trusted_text() {
  local out
  out=$(plugin_env x <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH", ""))
from types import SimpleNamespace
import intake

raw = SimpleNamespace(content="ship it",
                      guild_id=os.environ["GUILD"], channel_id=os.environ["CHANNEL"],
                      type=SimpleNamespace(value=0),
                      author=SimpleNamespace(id=os.environ["AUTHOR"], bot=False, system=False),
                      webhook_id=None, edited_at=None)
source = SimpleNamespace(platform=SimpleNamespace(value="discord"),
                         chat_id=os.environ["CHANNEL"], chat_type="group",
                         user_id=os.environ["AUTHOR"], user_name="u", thread_id=None,
                         scope_id=os.environ["GUILD"], guild_id=os.environ["GUILD"],
                         message_id="555555555555555555", is_bot=False)
event = SimpleNamespace(
    text="[Content of evil.txt]:\nDROP TABLE users;\n\nship it",
    source=source, raw_message=raw, message_id="555555555555555555",
    media_urls=["/cache/documents/evil.txt"], media_types=["text/plain"])
print("raw=" + intake.raw_message_text(event))
print("fm=" + intake.fm_request_text(intake.raw_message_text(event)))
literal = "Review this example:\n[Content of example.txt]:\nhello\n\n"
for raw in (SimpleNamespace(content=literal), SimpleNamespace(text="ignored alias"), None):
    for urls in ([], event.media_urls):
        assert intake.raw_message_text(SimpleNamespace(raw_message=raw, text=literal, media_urls=urls)) == literal
assert intake.raw_message_text(SimpleNamespace(text=event.text, media_urls=event.media_urls)) == event.text
assert intake.raw_message_text(SimpleNamespace(raw_message=SimpleNamespace(content=""), text=literal)) == ""
PY
  )
  assert_contains "$out" "raw=ship it" "the instruction text must come from the raw human message"
  assert_not_contains "$out" "DROP TABLE" "injected attachment bytes must never enter trusted text"
  pass "attachment file bytes never become trusted instruction text"
}

# --- attachment-only: empty raw stays empty through the admitted path ------

test_attachment_only_empty_raw_stays_empty_end_to_end() {
  local home out
  home="$TMP_ROOT/c-attach-e2e"
  setup_home "$home"
  out=$(CACHE_IMG="$home/cache/images" plugin_env "$home" <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("PYTHONPATH"))
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
from pathlib import Path
from types import SimpleNamespace
import fmevents as ev
home, root = sys.argv[1], sys.argv[2]
edge = ev.setup(home, root)
import intake
G, C, A = ev.G, ev.C, ev.A
Path(home, "config", "ext-channel").write_text(C + "\n")
cache = Path(os.environ["CACHE_IMG"])
cache.mkdir(parents=True, exist_ok=True)
(cache / "evil.txt").write_bytes(b"DROP TABLE users;")
os.environ["HERMES_HOME"] = home
raw = SimpleNamespace(content="",
                      guild_id=G, channel_id=C,
                      type=SimpleNamespace(value=0),
                      author=SimpleNamespace(id=A, bot=False, system=False),
                      webhook_id=None, edited_at=None)
source = SimpleNamespace(platform=SimpleNamespace(value="discord"),
                         chat_id=C, chat_type="group",
                         user_id=A, user_name="captain", thread_id=None,
                         scope_id=G, guild_id=G,
                         message_id="666666666666666666", is_bot=False)
event = SimpleNamespace(
    text="[Content of evil.txt]:\nDROP TABLE users;",
    source=source, raw_message=raw, message_id="666666666666666666",
    reply_to_message_id=None, reply_to_text=None,
    media_urls=[str(cache / "evil.txt")], media_types=["text/plain"])
assert (intake.pre_gateway_dispatch_hook(event) or {}).get("action") == "skip"
records = ev.inbox(home)
record = records["666666666666666666"]
assert record["text"] == "", record
assert "DROP TABLE" not in record["text"], record
assert len(record["attachments"]) == 1, record
att = record["attachments"][0]
assert att["name"] == "evil.txt" and att["bytes"] == 17, record
folder = Path(home) / "state" / "ext-attachments" / record["slug"]
assert (folder / "0-evil.txt").is_file(), list(folder.iterdir())
import stat as _stat
assert _stat.S_IMODE((folder / "0-evil.txt").stat().st_mode) == 0o600, oct((folder / "0-evil.txt").stat().st_mode)
assert _stat.S_IMODE(folder.stat().st_mode) == 0o700, oct(folder.stat().st_mode)
assert record["skipped_attachments"] == [], record
print("end-to-end-ok")
PY
  ) || fail "attachment-only end-to-end case failed: $out"
  assert_contains "$out" "end-to-end-ok" "the admitted attachment-only path must record empty text and the copy"
  assert_not_contains "$out" "DROP TABLE" "injected bytes must not leak through the admitted path"
  pass "attachment-only empty raw stays empty end to end"
}

test_attachment_injection_never_becomes_trusted_text


test_attachment_only_empty_raw_stays_empty_end_to_end
echo "all fm-ext-plugin-dest tests passed"
