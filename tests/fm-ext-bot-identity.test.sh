#!/usr/bin/env bash
# Behavior tests for the outbox poster's Discord bot identity.
#
# Hermetic: no Discord network. REST calls are captured at urllib.
# A multi-profile gateway must authenticate as the owning profile's bot, never
# as the process-env bot. A dedicated gateway keeps the process-env token.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PLUGIN="$ROOT/contrib/hermes-gateway-firstmate-comms"
TMP_ROOT=$(fm_test_tmproot fm-ext-bot-identity)

run_identity() {
  local name=$1
  shift
  PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$TMP_ROOT/$name" "$@" <<'PY'
import contextlib
import io
import json
import os
import sys
from pathlib import Path
from unittest.mock import patch

import outbox_poster as poster

base = Path(sys.argv[1])
mode = sys.argv[2]
hermes = base / "hermes"
fmcomms = hermes / "profiles" / "fmcomms"
hermes.mkdir(parents=True, exist_ok=True)
fmcomms.mkdir(parents=True, exist_ok=True)
os.environ["HERMES_HOME"] = str(hermes)
os.environ["DISCORD_BOT_TOKEN"] = "hermes-default-token"
os.environ.pop("HERMES_DISCORD_TOKEN", None)

if mode == "owning-profile-token":
    (fmcomms / ".env").write_text("DISCORD_BOT_TOKEN=fmcomms-token\n", encoding="utf-8")
    poster.configure_bot_identity(fmcomms)
elif mode == "owning-profile-missing":
    (fmcomms / ".env").write_text("# no token here\n", encoding="utf-8")
    poster.configure_bot_identity(fmcomms)
elif mode == "dedicated-process-env":
    poster.configure_bot_identity(hermes)
else:
    raise SystemExit(f"unknown mode {mode}")

auth = []

def fake_urlopen(request, timeout):
    auth.append(request.get_header("Authorization"))
    user_id = {
        "Bot fmcomms-token": "700000000000000009",
        "Bot replacement-token": "700000000000000011",
        "Bot restored-token": "700000000000000012",
        "Bot hermes-default-token": "700000000000000013",
    }[request.get_header("Authorization")]
    return io.BytesIO(json.dumps({"id": user_id}).encode())

stderr = io.StringIO()
with patch.object(poster.urllib.request, "urlopen", side_effect=fake_urlopen), \
        contextlib.redirect_stderr(stderr):
    user_id = poster._bot_user_id()
    if mode == "owning-profile-token":
        (fmcomms / ".env").write_text("DISCORD_BOT_TOKEN=replacement-token\n", encoding="utf-8")
        assert poster._bot_user_id() == "700000000000000011"
        poster.discord_rename_thread("700000000000000010", "renamed")
        (fmcomms / ".env").unlink()
        assert poster._bot_user_id() == ""
        try:
            poster.discord_rename_thread("700000000000000010", "missing")
        except poster.DiscordSendError as exc:
            assert poster.classify_send_failure(exc) == "transient", exc
            assert "missing DISCORD_BOT_TOKEN" in str(exc), exc
        else:
            raise AssertionError("removed profile token still authorized a request")
        (fmcomms / ".env").write_text("HERMES_DISCORD_TOKEN=restored-token\n", encoding="utf-8")
        assert poster._bot_user_id() == "700000000000000012"
        poster.discord_rename_thread("700000000000000010", "restored")

print(json.dumps({"user_id": user_id, "auth": auth, "stderr": stderr.getvalue()}))
PY
}

out=$(run_identity owning owning-profile-token) || fail "owning-profile token case crashed"
"$PYTHON_BIN" - "$out" <<'PY' || fail "a multi-profile poster must authenticate as the owning profile's bot"
import json, sys
got = json.loads(sys.argv[1])
assert got["auth"] == ["Bot fmcomms-token", "Bot replacement-token", "Bot replacement-token",
                       "Bot restored-token", "Bot restored-token"], got
assert got["user_id"] == "700000000000000009", got
assert "hermes-default-token" not in got["stderr"], got
assert "fmcomms-token" not in got["stderr"], got
assert "replacement-token" not in got["stderr"], got
assert "restored-token" not in got["stderr"], got
assert "no token (tried profile-env)" in got["stderr"], got
PY
pass "multi-profile poster uses current owner credentials across replacement, removal and recovery"

out=$(run_identity missing owning-profile-missing) || fail "owning-profile missing case crashed"
"$PYTHON_BIN" - "$out" <<'PY' || fail "a profile without a token must not borrow another profile's token"
import json, sys
got = json.loads(sys.argv[1])
assert got["auth"] == [], got
assert got["user_id"] == "", got
assert "hermes-default-token" not in got["stderr"], got
assert "profile-env" in got["stderr"], got
PY
pass "missing owning-profile token falls back to nothing and names the source tried"

out=$(run_identity dedicated dedicated-process-env) || fail "dedicated gateway case crashed"
"$PYTHON_BIN" - "$out" <<'PY' || fail "a dedicated gateway must keep the process-env token"
import json, sys
got = json.loads(sys.argv[1])
assert got["auth"] == ["Bot hermes-default-token"], got
assert got["user_id"] == "700000000000000013", got
assert "process-env" in got["stderr"], got
assert "hermes-default-token" not in got["stderr"], got
PY
pass "dedicated gateway keeps the process-env token"

out=$(PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - <<'PY'
import json
import sys
import types
from enum import Enum


class Platform(Enum):
    DISCORD = "discord"


gateway = types.ModuleType("gateway")
config = types.ModuleType("gateway.config")
config.Platform = Platform
run = types.ModuleType("gateway.run")
gateway.config = config
gateway.run = run
sys.modules.update({"gateway": gateway, "gateway.config": config, "gateway.run": run})

primary = type("Adapter", (), {"_client": "primary-client"})()
owner = type("Adapter", (), {"_client": "owner-client"})()


class Runner:
    adapters = {Platform.DISCORD: primary}
    _profile_adapters = {"fmcomms": {Platform.DISCORD: owner}}

    def _adapters_for_profile(self, profile):
        if profile in (None, "", "default"):
            return self.adapters
        return self._profile_adapters.get(profile, {})


runner = Runner()
run._gateway_runner_ref = lambda: runner

import decisions


def name(adapter):
    if adapter is None:
        return "none"
    if adapter is owner:
        return "owner"
    if adapter is primary:
        return "primary"
    return "unknown"


decisions.set_owner_profile("fmcomms")
owner_seen = name(decisions._live_discord_adapter())
decisions.set_owner_profile("default")
default_seen = name(decisions._live_discord_adapter())
decisions.set_owner_profile("other")
unknown_seen = name(decisions._live_discord_adapter())
print(json.dumps({"owner": owner_seen, "after_default": default_seen, "unknown_profile": unknown_seen}))
PY
) || fail "click route case crashed"
"$PYTHON_BIN" - "$out" <<'PY' || fail "decision buttons must route clicks through the owning profile's bot"
import json, sys
got = json.loads(sys.argv[1])
assert got == {"owner": "owner", "after_default": "primary", "unknown_profile": "none"}, got
PY
pass "decision click route follows the owning profile's bot"

PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$TMP_ROOT/buttons" <<'PY' || fail "decision buttons must match the posting bot's registered client"
import io
import json
import os
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import decisions
import outbox_poster as poster

home = Path(sys.argv[1]) / "profiles" / "fmcomms"
home.mkdir(parents=True)
os.environ["HERMES_HOME"] = str(home.parent.parent)
os.environ["DISCORD_BOT_TOKEN"] = "default-token"
poster.configure_bot_identity(home)


class Client:
    def __init__(self, bot_id):
        self.user = SimpleNamespace(id=bot_id)
        self.loop = SimpleNamespace(call_soon_threadsafe=lambda fn, item: fn(item))
        self.items = []

    def add_dynamic_items(self, item):
        self.items.append(item)


client = Client(700000000000000009)
adapter = SimpleNamespace(_client=client, is_connected=True)
posts = []
lookup_fails = False
rotate_during_lookup = False
payload = {"thread_id": "700000000000000010", "channel_id": "700000000000000010",
           "text": "Pick a route: North or South", "decision": {
               "key": "key:fixture:pick", "options": [{"id": 1, "label": "North"}]}}


def urlopen(request, timeout):
    auth = request.get_header("Authorization")
    if request.full_url.endswith("/users/@me"):
        if lookup_fails:
            raise OSError("identity unavailable")
        bot_id = {"Bot token-a": "700000000000000009", "Bot token-b": "700000000000000011"}[auth]
        if rotate_during_lookup:
            (home / ".env").write_text("DISCORD_BOT_TOKEN=token-a\n")
        return io.BytesIO(json.dumps({"id": bot_id}).encode())
    posts.append((auth, json.loads(request.data)))
    return io.BytesIO(b'{"id":"700000000000000012"}')


def send(expect_buttons, expected_auth):
    receipt = poster.discord_send(payload)
    auth, body = posts[-1]
    assert auth == expected_auth, posts
    assert body["content"] == payload["text"], body
    assert bool(body.get("components")) == expect_buttons, body
    assert receipt["buttons"] == expect_buttons, receipt


with patch.object(decisions, "_live_discord_adapter", return_value=adapter), \
        patch.object(decisions, "click_item_class", return_value=object()), \
        patch.object(poster.urllib.request, "urlopen", side_effect=urlopen):
    (home / ".env").write_text("DISCORD_BOT_TOKEN=token-a\n")
    send(False, "Bot token-a")
    assert decisions.ensure_click_route()
    assert len(client.items) == 1
    send(True, "Bot token-a")
    (home / ".env").write_text("DISCORD_BOT_TOKEN=token-b\n")
    assert decisions.ensure_click_route()
    send(False, "Bot token-b")
    adapter._client = Client(700000000000000011)
    send(False, "Bot token-b")
    assert decisions.ensure_click_route()
    send(True, "Bot token-b")
    lookup_fails = True
    send(False, "Bot token-b")
    lookup_fails = False
    rotate_during_lookup = True
    send(True, "Bot token-b")
    rotate_during_lookup = False
    send(False, "Bot token-a")
PY
pass "decision buttons require the posting bot's registered client across credential changes"
