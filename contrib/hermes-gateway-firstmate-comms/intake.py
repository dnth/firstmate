"""Fail-closed /fm intake for the local Firstmate Communication Officer."""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from contextvars import ContextVar
from pathlib import Path

# bin/fm-ext-intake.sh exits 3 when the allowlist refuses the request, which is
# how a refusal is told apart from a broken bridge without parsing its message.
INTAKE_REFUSED = 3
_SNOWFLAKE = re.compile(r"^[0-9]+$")
_FM_PREFIX = re.compile(r"^/fm(?:@\S+)?(?:\s+|$)")
# Task-local destination for the inbound event currently dispatching.
# Set on EVERY pre_gateway_dispatch event (None for non-/fm) and read by
# handle_fm_command later in the same asyncio task. Task-locality is the
# whole point: two concurrent /fm texts, even byte-identical ones from an
# allowlisted and a denied author, never share a destination. No
# process-global cache keyed by text is used here.
_current_event_dest: ContextVar = ContextVar("FM_CURRENT_EVENT_DEST", default=None)


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
    guild = context_field(context, "guild_id", "guild", "server_id", "scope_id")
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


def _snowflake(value: object) -> str:
    text = str(value or "").strip()
    return text if _SNOWFLAKE.fullmatch(text) else ""


def _source_field(source: object, *names: str) -> str:
    for name in names:
        try:
            value = getattr(source, name, None)
        except Exception:
            continue
        text = _snowflake(value)
        if text:
            return text
    return ""


def destination_from_event(event: object) -> dict[str, str]:
    """Build the intake destination from a Hermes MessageEvent.
    Structural source: gateway/session.py SessionSource on event.source,
    plus the Discord interaction behind event.raw_message. No rendered
    output is parsed: every field is a native id attribute.
    """
    source = getattr(event, "source", None)
    raw = getattr(event, "raw_message", None)
    guild = _source_field(source, "scope_id", "guild_id")
    channel = _source_field(source, "chat_id")
    thread = _source_field(source, "thread_id") or channel
    message = _source_field(source, "message_id") or _snowflake(getattr(event, "message_id", None))
    author = _source_field(source, "user_id", "user_id_alt")
    platform = ""
    try:
        platform_value = getattr(getattr(source, "platform", None), "value", None)
        platform = str(platform_value or getattr(source, "platform", "") or "").strip()
    except Exception:
        platform = ""
    if not guild and raw is not None:
        guild = _snowflake(getattr(raw, "guild_id", None))
        if not guild:
            guild = _snowflake(getattr(getattr(raw, "guild", None), "id", None))
    if not message and raw is not None:
        message = _snowflake(getattr(raw, "id", None))
    if not author and raw is not None:
        user = getattr(raw, "user", None) or getattr(raw, "author", None)
        author = _snowflake(getattr(user, "id", None))
    if not channel and raw is not None:
        channel = _snowflake(getattr(raw, "channel_id", None)) or _snowflake(getattr(getattr(raw, "channel", None), "id", None))
        if not thread:
            thread = channel
    return {
        "guild_id": guild,
        "channel_id": channel,
        "thread_id": thread or channel,
        "message_id": message,
        "author": author,
        "platform": platform or "discord",
    }


def bind_event_destination(event: object = None) -> object:
    """Bind this turn's destination task-locally. Called from the
    pre_gateway_dispatch hook on EVERY event: /fm events bind their
    MessageEvent destination, anything else binds None so a previous
    turn's destination can never leak into this one. Returns the token
    so tests can reset it; the gateway task rebinds per event anyway.
    """
    try:
        text = getattr(event, "text", None) or ""
        dest = destination_from_event(event) if is_fm_text(text) else None
        if dest is not None and not destination_valid(dest):
            dest = None
    except Exception:
        dest = None
    return _current_event_dest.set(dest)


def pre_gateway_dispatch_hook(event=None, **kwargs) -> dict | None:
    """Hermes pre_gateway_dispatch hook: bind the /fm destination locally.
    Fires once per inbound MessageEvent before auth and dispatch, in the
    same asyncio task that later runs handle_fm_command. Returns None
    always so normal dispatch continues untouched.
    """
    bind_event_destination(event)
    return None


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


def resolve_destination(raw_args: str, context: dict | None = None) -> dict[str, str]:
    """Resolve the intake destination for one /fm dispatch.
    An explicit caller context dict wins when one is passed. Otherwise the
    destination is the task-local bound by pre_gateway_dispatch in this
    same asyncio task - never a shared cache, so concurrent identical
    texts cannot cross author or channel authority. Hermes binds its own
    session vars after plugin dispatch, so they are not read here.
    Anything unresolved stays empty and fails closed in destination_valid.
    """
    dest = destination_from_context(context)
    if destination_valid(dest):
        return dest
    try:
        bound = _current_event_dest.get()
    except Exception:
        bound = None
    if isinstance(bound, dict) and destination_valid(bound):
        return bound
    return destination_from_context(None)


def handle_fm_command(raw_args: str, context: dict | None = None) -> str:
    """Slash-command handler. Returns a fast ack without waiting for Firstmate work.
    The allowlist decision is not made here. bin/fm-ext-intake.sh owns the rule
    grammar and the authority it grants, and it is the gate that actually
    protects the home, so a second copy in this file could only ever drift away
    from it. This maps that one decision back to a Discord-facing sentence.
    The Hermes 0.20.x plugin dispatch calls handler(user_args) with no
    context, so the destination arrives via the task-local bound by the
    pre_gateway_dispatch hook in the same task; an explicit context dict
    still wins when a caller (or a newer Hermes) passes one.
    """
    dest = resolve_destination(raw_args, context)
    if not destination_valid(dest):
        try:
            from hermes_cli import __version__ as hermes_version
        except ImportError:
            hermes_version = "unknown"
        return (
            "Firstmate refused this request: Discord destination is incomplete "
            f"(Hermes {hermes_version}). Try again from the channel or thread."
        )
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
