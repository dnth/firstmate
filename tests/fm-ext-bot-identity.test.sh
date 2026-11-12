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
    return io.BytesIO(json.dumps({"id": "700000000000000009"}).encode())

stderr = io.StringIO()
poster._BOT_USER_ID = ""
with patch.object(poster.urllib.request, "urlopen", side_effect=fake_urlopen), \
        contextlib.redirect_stderr(stderr):
    user_id = poster._bot_user_id()
    if mode == "owning-profile-token":
        (fmcomms / ".env").write_text("DISCORD_BOT_TOKEN=replacement-token\n", encoding="utf-8")
        poster.discord_rename_thread("700000000000000010", "renamed")
        (fmcomms / ".env").unlink()
        try:
            poster.discord_rename_thread("700000000000000010", "missing")
        except poster.DiscordSendError as exc:
            assert poster.classify_send_failure(exc) == "transient", exc
            assert "missing DISCORD_BOT_TOKEN" in str(exc), exc
        else:
            raise AssertionError("removed profile token still authorized a request")
        (fmcomms / ".env").write_text("HERMES_DISCORD_TOKEN=restored-token\n", encoding="utf-8")
        poster.discord_rename_thread("700000000000000010", "restored")

print(json.dumps({"user_id": user_id, "auth": auth, "stderr": stderr.getvalue()}))
PY
}

out=$(run_identity owning owning-profile-token) || fail "owning-profile token case crashed"
"$PYTHON_BIN" - "$out" <<'PY' || fail "a multi-profile poster must authenticate as the owning profile's bot"
import json, sys
got = json.loads(sys.argv[1])
assert got["auth"] == ["Bot fmcomms-token", "Bot replacement-token", "Bot restored-token"], got
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
