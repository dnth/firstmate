"""Fail-closed /fm intake for the local Firstmate Communication Officer."""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path

# bin/fm-ext-intake.sh exits 3 when the allowlist refuses the request, which is
# how a refusal is told apart from a broken bridge without parsing its message.
INTAKE_REFUSED = 3

_SNOWFLAKE = re.compile(r"^[0-9]+$")
_FM_PREFIX = re.compile(r"^/fm(?:@\S+)?(?:\s+|$)")


def firstmate_root() -> Path:
    override = os.environ.get("FM_ROOT_OVERRIDE") or os.environ.get("FM_ROOT")
    if override:
        return Path(override)
    return Path(__file__).resolve().parents[2]


def firstmate_home() -> Path:
    override = os.environ.get("FM_HOME")
    if override:
        return Path(override)
    return firstmate_root()


def secret_path(home: Path | None = None) -> Path:
    home = home or firstmate_home()
    override = os.environ.get("FM_EXT_SECRET_FILE")
    if override:
        return Path(override)
    return home / "config" / "ext-secret"


def allowlist_path(home: Path | None = None) -> Path:
    home = home or firstmate_home()
    override = os.environ.get("FM_EXT_ALLOWLIST_FILE")
    if override:
        return Path(override)
    return home / "config" / "ext-allowlist"


def context_field(context: dict | None, *names: str) -> str:
    if not context:
        return ""
    for name in names:
        value = context.get(name)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return ""


def destination_from_context(context: dict | None) -> dict[str, str]:
    guild = context_field(context, "guild_id", "guild", "server_id")
    channel = context_field(context, "channel_id", "chat_id")
    thread = context_field(context, "thread_id") or channel
    message = context_field(context, "message_id", "id")
    author = context_field(context, "user_id", "author_id", "author")
    platform = context_field(context, "platform") or "discord"
    return {
        "guild_id": guild,
        "channel_id": channel,
        "thread_id": thread,
        "message_id": message,
        "author": author,
        "platform": platform,
    }


def request_id_for(dest: dict[str, str]) -> str:
    return (
        f"discord:{dest['guild_id']}:{dest['channel_id']}:"
        f"{dest['thread_id']}:{dest['message_id']}"
    )


def destination_valid(dest: dict[str, str]) -> bool:
    if dest.get("platform") not in ("", "discord"):
        return False
    for key in ("guild_id", "channel_id", "thread_id", "message_id", "author"):
        if not _SNOWFLAKE.fullmatch(dest.get(key, "")):
            return False
    return True


def is_fm_text(text: str) -> bool:
    return bool(_FM_PREFIX.match((text or "").lstrip()))


def fm_request_text(raw_args: str) -> str:
    text = (raw_args or "").strip()
    if is_fm_text(text):
        return _FM_PREFIX.sub("", text, count=1).strip()
    return text


def maybe_intake_from_text(text: str, context: dict | None) -> str | None:
    """No-op unless the message is a /fm command. Used by tests and free-form chat."""
    if not is_fm_text(text):
        return None
    return handle_fm_command(fm_request_text(text), context)


def handle_fm_command(raw_args: str, context: dict | None = None) -> str:
    """Slash-command handler. Returns a fast ack without waiting for Firstmate work.

    The allowlist decision is not made here. bin/fm-ext-intake.sh owns the rule
    grammar and the authority it grants, and it is the gate that actually
    protects the home, so a second copy in this file could only ever drift away
    from it. This maps that one decision back to a Discord-facing sentence.
    """
    dest = destination_from_context(context)
    if not destination_valid(dest):
        return "Firstmate refused this request: Discord destination is incomplete."
    home = firstmate_home()
    request_text = fm_request_text(raw_args)
    if not request_text:
        return "Aye. Use `/fm` followed by the order you want Firstmate to take."
    try:
        code = _run_intake(home, dest, request_text)
    except Exception:
        return "Firstmate could not record that request locally. Try again from this thread."
    if code == INTAKE_REFUSED:
        return "Firstmate refused this request: it is not on the local allowlist."
    if code != 0:
        return "Firstmate could not record that request locally. Try again from this thread."
    return "Aye, captain - Firstmate has the order and is on it."


def _run_intake(home: Path, dest: dict[str, str], text: str) -> int:
    intake = firstmate_root() / "bin" / "fm-ext-intake.sh"
    secret = secret_path(home)
    env = os.environ.copy()
    env["FM_HOME"] = str(home)
    env["FM_ROOT_OVERRIDE"] = str(firstmate_root())
    # Deliberately no FM_EXT_BRIDGE here. config/ext-bridge is the single
    # activation authority, so installing this plugin cannot switch the intake
    # half of a home on while its bootstrap and watcher still believe the
    # bridge is off.
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(text)
        text_path = handle.name
    try:
        result = subprocess.run(
            [
                str(intake),
                "--request-id",
                request_id_for(dest),
                "--guild-id",
                dest["guild_id"],
                "--channel-id",
                dest["channel_id"],
                "--thread-id",
                dest["thread_id"],
                "--message-id",
                dest["message_id"],
                "--author",
                dest["author"],
                "--secret-file",
                str(secret),
                "--text-file",
                text_path,
            ],
            check=False,
            env=env,
            capture_output=True,
            text=True,
        )
        return result.returncode
    finally:
        os.unlink(text_path)
