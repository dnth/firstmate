"""Fail-closed Discord intake for the local Firstmate Communication Officer.

Three Discord paths reach Firstmate, all through bin/fm-ext-intake.sh and
its one allowlist: the /fm slash command, every ordinary message in the
optional dedicated channel named by config/ext-channel, and a Discord reply
to one of Firstmate's own posted messages anywhere the gateway listens.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import threading
from contextvars import ContextVar
from pathlib import Path

# bin/fm-ext-intake.sh exits 3 when the allowlist refuses the request, which is
# how a refusal is told apart from a broken bridge without parsing its message.
INTAKE_REFUSED = 3
_SNOWFLAKE = re.compile(r"^[0-9]+$")
_FM_PREFIX = re.compile(r"^/fm(?:@\S+)?(?:\s+|$)")
# discord.MessageType values for a new text message and a reply. Every other
# type (joins, pins, boosts, thread starters, ...) is a system message.
_MESSAGE_DEFAULT = 0
_MESSAGE_REPLY = 19
# Returned from pre_gateway_dispatch for a message this plugin owns, so the
# gateway's general agent never also answers it.
_SKIP = {"action": "skip", "reason": "firstmate-comms request"}
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


def dedicated_channel(home: Path | None = None) -> str:
    """The dedicated Firstmate channel id from config/ext-channel, or "".
    The file names exactly one Discord channel id on its own line; comments
    and blank lines are ignored. Absent, symlinked, unreadable, empty, or
    ambiguous (more than one id) leaves the channel path off. It is read per
    message, so a change needs no gateway restart.
    """
    path = (home or firstmate_home()) / "config" / "ext-channel"
    try:
        if path.is_symlink() or not path.is_file():
            return ""
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return ""
    ids = [line.strip() for line in lines if line.strip() and not line.strip().startswith("#")]
    if len(ids) != 1:
        return ""
    return _snowflake(ids[0])


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
    # In a thread Hermes reports the thread itself as the chat. Allowlist
    # rules name channels, so authorise against the thread's parent channel
    # and keep the thread as the reply target. Only a thread qualifies: a
    # top-level channel's parent_id is its category, never a channel rule.
    try:
        chat_type = str(getattr(source, "chat_type", "") or "").strip()
    except Exception:
        chat_type = ""
    if chat_type == "thread":
        parent = _source_field(source, "parent_chat_id")
        if not parent and raw is not None:
            parent = _snowflake(getattr(getattr(raw, "channel", None), "parent_id", None))
        if parent:
            thread = thread or channel
            channel = parent
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


def _poster():
    # Imported on use: outbox_poster imports this module at load time.
    try:
        from . import outbox_poster
    except ImportError:  # loaded from sys.path in hermetic tests
        import outbox_poster
    return outbox_poster


def _message_type(raw: object) -> int | None:
    kind = getattr(raw, "type", None)
    value = getattr(kind, "value", kind)
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def ordinary_message(event: object) -> bool:
    """True only for a new, human-written Discord text message or reply.
    A slash-command interaction, a bot or webhook post (Firstmate's own
    included), an edited message, and a system message are never ordinary,
    so none of them can become a request through the message paths.
    """
    raw = getattr(event, "raw_message", None)
    if _message_type(raw) not in (_MESSAGE_DEFAULT, _MESSAGE_REPLY):
        return False
    author = getattr(raw, "author", None)
    if author is None or getattr(author, "bot", False) or getattr(author, "system", False):
        return False
    if getattr(raw, "webhook_id", None) or getattr(raw, "edited_at", None) is not None:
        return False
    return not getattr(getattr(event, "source", None), "is_bot", False)


def replied_to(event: object) -> tuple[str, str]:
    """(id, text) of the message a Discord reply answers, or ("", "").
    Discord delivers the referenced message with the reply, so its text needs
    no extra fetch; text is empty when that message has since been deleted.
    """
    raw = getattr(event, "raw_message", None)
    if _message_type(raw) != _MESSAGE_REPLY:
        return "", ""
    reference = getattr(raw, "reference", None)
    message_id = _snowflake(getattr(reference, "message_id", None)) or _snowflake(
        getattr(event, "reply_to_message_id", None)
    )
    if not message_id:
        return "", ""
    resolved = getattr(reference, "resolved", None)
    text = getattr(resolved, "content", None) or getattr(event, "reply_to_text", None) or ""
    return message_id, str(text)


def react_in_background(dest: dict[str, str], reaction: str) -> threading.Thread | None:
    """React on the request's own message without blocking the gateway loop.
    A reaction is best effort: any failure is dropped, never retried, and
    never changes what happened to the request itself.
    """
    try:
        poster = _poster()
        payload = {
            "origin": "message",
            "thread_id": dest["thread_id"],
            "channel_id": dest["channel_id"],
            "message_id": dest["message_id"],
        }
        thread = threading.Thread(
            target=poster.react_to_request,
            args=(payload, getattr(poster, reaction)),
            name="fm-ext-react",
            daemon=True,
        )
        thread.start()
        return thread
    except Exception:
        return None


def raw_message_text(event: object) -> str:
    """The human-typed Discord message behind an event, without enrichment.
    The gateway prepends small text-attachment contents ("[Content of ...]")
    to event.text, so attachment bytes must never be read from there: they
    would enter the request as trusted instruction text. Prefer the raw
    message content behind event.raw_message. The raw message is read-only
    here; the live adapter is never touched.
    """
    raw = getattr(event, "raw_message", None)
    for attr in ("content", "text"):
        try:
            value = getattr(raw, attr, None)
        except Exception:
            value = None
        if isinstance(value, str):
            text = value
            break
    else:
        media_urls, _media_types = event_attachments(event)
        if media_urls:
            text = ""
        else:
            text = getattr(event, "text", None) or ""
            if not isinstance(text, str):
                text = str(text)
    return text


def event_attachments(event: object) -> tuple[list[str], list[str]]:
    """(media_urls, media_types) carried by one gateway MessageEvent."""
    try:
        urls = list(getattr(event, "media_urls", None) or [])
    except Exception:
        urls = []
    try:
        types = list(getattr(event, "media_types", None) or [])
    except Exception:
        types = []
    return [str(u) for u in urls], [str(m) for m in types]


def route_message_event(event: object) -> dict | None:
    """Turn an ordinary Discord message into a Firstmate request when it is
    one: any message in the dedicated channel (or a thread under it), or a
    reply to one of Firstmate's own posted messages anywhere. Both go through
    bin/fm-ext-intake.sh exactly like /fm, so its allowlist alone decides
    admission and authority. Returns the gateway skip action for a message
    this plugin owns, so the general agent never also answers it, and None
    to leave every other message on its normal path.

    An accepted request gets the seen reaction. A refused author's message is
    dropped silently in the dedicated channel and keeps its normal path
    elsewhere. Any other intake failure gets the warning reaction, never a
    silent drop.
    """
    if not ordinary_message(event):
        return None
    dest = destination_from_event(event)
    if not destination_valid(dest):
        return None
    home = firstmate_home()
    channel = dedicated_channel(home)
    in_channel = bool(channel) and dest["channel_id"] == channel
    reply_id, reply_text = replied_to(event)
    post = _poster().firstmate_post_for(reply_id, home) if reply_id else None
    if not in_channel and post is None:
        return None
    reply_to = None
    if post is not None:
        reply_to = {"message_id": reply_id, "request_id": post["request_id"], "text": reply_text}
    text = fm_request_text(raw_message_text(event))
    media_urls, media_types = event_attachments(event)
    try:
        code = _run_intake(
            home, dest, text, origin="message", reply_to=reply_to,
            media_urls=media_urls, media_types=media_types,
        )
    except Exception:
        code = -1
    if code == 0:
        react_in_background(dest, "REACT_SEEN")
        return dict(_SKIP)
    if code == INTAKE_REFUSED:
        return dict(_SKIP) if in_channel else None
    react_in_background(dest, "REACT_FAILED")
    return dict(_SKIP)


def pre_gateway_dispatch_hook(event=None, **kwargs) -> dict | None:
    """Hermes pre_gateway_dispatch hook.
    Fires once per inbound MessageEvent before auth and dispatch, in the
    same asyncio task that later runs handle_fm_command. It binds the /fm
    destination task-locally, then routes an ordinary message through
    route_message_event. Anything unexpected leaves normal dispatch alone.
    """
    bind_event_destination(event)
    try:
        return route_message_event(event)
    except Exception:
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
    A valid explicit caller context dict wins when one is passed. Otherwise the
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
    A slash command is a Discord interaction, not a message, so it cannot take
    the delivery reactions; this short text is its only acknowledgement.
    The allowlist decision is not made here. bin/fm-ext-intake.sh owns the rule
    grammar and the authority it grants, and it is the gate that actually
    protects the home, so a second copy in this file could only ever drift away
    from it. This maps that one decision back to a Discord-facing sentence.
    The Hermes 0.20.x plugin dispatch calls handler(user_args) with no
    context, so the destination arrives via the task-local bound by the
    pre_gateway_dispatch hook in the same task; an explicit context dict
    still wins when a caller (or a newer Hermes) passes a valid one.
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
    return "Aye, captain - Firstmate has it."


def _write_temp(text: str) -> str:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(text)
        return handle.name


def attachment_manifest_entries(
    media_urls: list[str] | None, media_types: list[str] | None,
) -> list[dict[str, str]]:
    """Manifest entries for locally cached adapter attachments.
    Only local paths are listed; a CDN-URL fallback entry keeps its URL so
    the shell records it as uncached, and it is never fetched here.
    """
    urls = list(media_urls or [])
    types = list(media_types or [])
    entries: list[dict[str, str]] = []
    for i, url in enumerate(urls):
        media = types[i] if i < len(types) else ""
        name = str(url).rsplit("/", 1)[-1] or "attachment-%d" % (i + 1)
        entries.append({"path": str(url), "media_type": str(media), "name": name})
    return entries


def _write_manifest(entries: list[dict[str, str]]) -> str:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".json", delete=False) as handle:
        json.dump(entries, handle)
        return handle.name


def _run_intake(
    home: Path,
    dest: dict[str, str],
    text: str,
    origin: str = "slash",
    reply_to: dict[str, str] | None = None,
    media_urls: list[str] | None = None,
    media_types: list[str] | None = None,
) -> int:
    intake = firstmate_root() / "bin" / "fm-ext-intake.sh"
    secret = secret_path(home)
    env = os.environ.copy()
    env["FM_HOME"] = str(home)
    env["FM_ROOT_OVERRIDE"] = str(firstmate_root())
    # Deliberately no FM_EXT_BRIDGE here. config/ext-bridge is the single
    # activation authority, so installing this plugin cannot switch the intake
    # half of a home on while its bootstrap and watcher still believe the
    # bridge is off.
    temp_paths = [_write_temp(text)]
    args = [
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
        temp_paths[0],
        "--origin",
        origin,
    ]
    try:
        if reply_to:
            temp_paths.append(_write_temp(reply_to.get("text") or ""))
            args += ["--reply-to-message-id", reply_to["message_id"], "--reply-to-text-file", temp_paths[1]]
            if reply_to.get("request_id"):
                args += ["--reply-to-request-id", reply_to["request_id"]]
        entries = attachment_manifest_entries(media_urls, media_types)
        if entries:
            manifest = _write_manifest(entries)
            temp_paths.append(manifest)
            args += ["--attachment-manifest", manifest]
        result = subprocess.run(args, check=False, env=env, capture_output=True, text=True)
        return result.returncode
    finally:
        for path in temp_paths:
            os.unlink(path)
