"""Discord thread context for a Communication Officer request.

A request filed from a thread in the dedicated Firstmate channel carries what
Firstmate needs to know where it is speaking: the thread's name, the project
it belongs to, and the recent conversation. bin/fm-ext-intake.sh records all
three (--thread-name, --project, --history-file); docs/configuration.md owns
the record contract.

Hermes' own Discord adapter builds a similar "[Recent channel messages]" block
in ``_fetch_channel_context``. That method is async and bound to the adapter's
client and per-chat session state, which a plugin hook cannot reach without
patching Hermes, so this module follows the same pattern over Discord's REST
API with the bot token the outbox poster already uses. It differs on purpose:
Firstmate keeps no per-thread conversation, so the scan does not stop at the
bot's own last message; it collects both sides and leaves trimming to the
intake script, which keeps the replied-to message and Firstmate's latest post.

Everything here is best effort. A failed read never stops a request: it is
reported as an unavailable history with its reason.
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

_SNOWFLAKE = re.compile(r"^[0-9]+$")
# discord.MessageType values for a new text message and a reply.
_MESSAGE_DEFAULT = 0
_MESSAGE_REPLY = 19
_PROJECT_SEPARATOR = " · "
_STATE_MARKERS = ("❓ ", "✅ ")
PROJECT_UNKNOWN = "unknown"
# Mirrors bin/fm-ext-intake.sh, which owns the trimming budget. The plugin only
# needs it to know when it has fetched enough.
HISTORY_DEFAULT_CHARS = 8000
PAGE_SIZE = 100
REPLY_WINDOW = 10
READ_TIMEOUT = 8


def _poster():
    # Imported on use: outbox_poster imports intake, which imports this module.
    try:
        from . import outbox_poster
    except ImportError:  # loaded from sys.path in hermetic tests
        import outbox_poster
    return outbox_poster


def in_dedicated_thread(dest: dict, channel: str) -> bool:
    """True for a request filed from a thread under the dedicated channel.

    The destination's channel is the thread's parent (see
    intake.destination_from_event), so a top-level message in that channel,
    which has no thread yet, and every thread elsewhere are out of scope.
    """
    if not channel or dest.get("channel_id") != channel:
        return False
    thread = dest.get("thread_id") or ""
    return bool(thread) and thread != dest.get("channel_id")


def _event_thread_name(event: object) -> str:
    raw = getattr(event, "raw_message", None)
    channel = getattr(raw, "channel", None)
    name = getattr(channel, "name", None)
    return name.strip() if isinstance(name, str) else ""


def thread_name(event: object, dest: dict) -> str:
    """The thread's current name, or "" when it cannot be read.

    The event's own channel is the live Discord object the gateway client
    delivered, so it is read first; a REST read covers an event that does not
    carry the channel (a slash interaction, a partial payload).
    """
    name = _event_thread_name(event) if event is not None else ""
    if name:
        return name
    try:
        return _poster().discord_thread_name(dest.get("thread_id") or "").strip()
    except Exception:
        return ""


def project_from_name(name: str) -> str:
    """The project in a "<Project> · <topic>" thread name, or ""."""
    text = (name or "").strip()
    for marker in _STATE_MARKERS:
        if text.startswith(marker):
            text = text[len(marker):]
            break
    head, separator, _topic = text.partition(_PROJECT_SEPARATOR)
    head = head.strip()
    if not separator or not head or len(head) > 60:
        return ""
    return head


def _meta_value(path: Path, key: str) -> str:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return ""
    value = ""
    for line in lines:
        if line.startswith(key + "="):
            value = line[len(key) + 1:]
    return value


def project_from_task(thread_id: str, home: Path) -> str:
    """The project of the task linked to the request that opened this thread.

    The thread's topic record names the request, a task's meta names the
    request it answers (ext_request / ext_request_slug), and the meta's
    project path ends in the project's name. "" when no task is linked.
    """
    poster = _poster()
    try:
        record = poster.load_thread_record_by_id(thread_id, home)
    except Exception:
        return ""
    if not record:
        return ""
    request_id = record.get("request_id") or ""
    try:
        slug = poster._thread_record_slug(record["path"])
    except Exception:
        slug = ""
    if not request_id and not slug:
        return ""
    state = poster.state_dir(home)
    try:
        metas = sorted(state.glob("*.meta"))
    except OSError:
        return ""
    for meta in metas:
        if meta.is_symlink() or not meta.is_file():
            continue
        if (request_id and _meta_value(meta, "ext_request") == request_id) or (
            slug and _meta_value(meta, "ext_request_slug") == slug
        ):
            name = Path(_meta_value(meta, "project").rstrip("/")).name
            if name:
                return name
    return ""


def resolve_project(name: str, thread_id: str, home: Path) -> str:
    return project_from_name(name) or project_from_task(thread_id, home) or PROJECT_UNKNOWN


class HistoryUnavailable(Exception):
    """A thread read Discord refused or the plugin could not make."""


def _get(path: str, query: dict, token: str) -> list:
    poster = _poster()
    url = f"{poster.DISCORD_API_BASE}{path}?{urllib.parse.urlencode(query)}"
    request = urllib.request.Request(
        url, headers={"Authorization": f"Bot {token}", "User-Agent": poster.USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=READ_TIMEOUT) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        raise HistoryUnavailable(f"Discord refused the read (HTTP {err.code})") from err
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as err:
        raise HistoryUnavailable(f"Discord read failed ({type(err).__name__})") from err
    if not isinstance(data, list):
        raise HistoryUnavailable("Discord returned no message list")
    return data


def _entry(message: dict, bot_id: str, requester: str, posts: dict, reply_id: str) -> dict | None:
    """One history entry for a Discord message object, or None to skip it."""
    if not isinstance(message, dict):
        return None
    message_id = str(message.get("id") or "")
    explicit_reply = bool(reply_id) and message_id == reply_id
    if not explicit_reply and message.get("type") not in (_MESSAGE_DEFAULT, _MESSAGE_REPLY):
        return None
    author = message.get("author")
    if not _SNOWFLAKE.fullmatch(message_id) or not isinstance(author, dict):
        return None
    author_id = str(author.get("id") or "")
    if message.get("webhook_id") and not explicit_reply:
        return None
    is_bot = bool(author.get("bot") or author_id == bot_id)
    if message_id in posts:
        role = "firstmate"
    elif author_id == bot_id:
        role = "other"
    elif (author.get("bot") or author.get("system")) and not explicit_reply:
        return None
    elif author_id == requester:
        role = "requester"
    else:
        role = "other"
    text = message.get("content")
    text = text if isinstance(text, str) else ""
    if not text.strip() and message.get("attachments"):
        text = "(attachment)"
    if not text.strip() and not explicit_reply:
        return None
    name = author.get("global_name") or author.get("username") or "unknown"
    return {
        "id": message_id,
        "author_id": author_id,
        "author": str(name),
        "bot": is_bot,
        "role": role,
        "at": str(message.get("timestamp") or ""),
        "text": text,
    }


def collect_history(
    dest: dict,
    reply_id: str = "",
    reply_text: str = "",
    reply_message: dict | None = None,
    budget: int | None = None,
    home: Path | None = None,
) -> dict:
    """The thread's recent conversation as the intake script's history file.

    Scans back from the request's message, both the captain's and Firstmate's
    messages, until it holds about ``budget`` characters of text and
    Firstmate's latest post, or reaches the thread start; adds a window around a
    replied-to message that lies further back. Returns
    {"status": "ok", "reply_to_id": ..., "messages": [...]} or {"status": "unavailable",
    "reason": ...}. Never raises.
    """
    try:
        return _collect_history(dest, reply_id, reply_text, reply_message, budget, home or _poster().firstmate_home())
    except HistoryUnavailable as err:
        return {"status": "unavailable", "reason": str(err)}
    except Exception as err:  # best effort: never stop a request
        return {"status": "unavailable", "reason": f"history read failed ({type(err).__name__})"}


def _collect_history(dest, reply_id, reply_text, reply_message, budget, home) -> dict:
    poster = _poster()
    token = poster._bot_token()
    if not token:
        raise HistoryUnavailable("no Discord bot token in the gateway environment")
    thread = dest.get("thread_id") or ""
    anchor = dest.get("message_id") or ""
    if not (_SNOWFLAKE.fullmatch(thread) and _SNOWFLAKE.fullmatch(anchor)):
        raise HistoryUnavailable("the request has no readable thread")
    bot_id = poster._bot_user_id()
    if not bot_id:
        raise HistoryUnavailable("could not read the bot identity")
    requester = dest.get("author") or ""
    if budget is None:
        try:
            budget = int(os.environ.get("FM_EXT_HISTORY_MAX_CHARS", HISTORY_DEFAULT_CHARS))
        except ValueError:
            budget = HISTORY_DEFAULT_CHARS

    posts = poster.firstmate_posts(home)
    entries: dict[str, dict] = {}
    before = anchor
    chars = 0
    seen_firstmate = False
    while True:
        page = _get(f"/channels/{thread}/messages", {"limit": PAGE_SIZE, "before": before}, token)
        for message in page:
            entry = _entry(message, bot_id, requester, posts, reply_id)
            if entry is not None and entry["id"] not in entries:
                entries[entry["id"]] = entry
                chars += len(entry["text"])
                seen_firstmate = seen_firstmate or entry["role"] == "firstmate"
        ids = [str(m.get("id")) for m in page if isinstance(m, dict) and _SNOWFLAKE.fullmatch(str(m.get("id") or ""))]
        if len(page) < PAGE_SIZE or not ids:
            break
        if chars >= budget and seen_firstmate:
            break
        before = min(ids, key=lambda value: (len(value), value))

    if reply_id and _SNOWFLAKE.fullmatch(reply_id) and reply_id not in entries:
        for message in _get(
            f"/channels/{thread}/messages", {"limit": REPLY_WINDOW, "around": reply_id}, token,
        ):
            entry = _entry(message, bot_id, requester, posts, reply_id)
            if entry is not None and entry["id"] not in entries and entry["id"] != anchor:
                entries[entry["id"]] = entry
    if reply_id and reply_id not in entries and (reply_message is not None or reply_text.strip()):
        message = reply_message or {
            "id": reply_id, "type": _MESSAGE_REPLY, "content": reply_text, "author": {},
        }
        entry = _entry(message, bot_id, requester, posts, reply_id)
        if entry is not None:
            entries[entry["id"]] = entry
    return {"status": "ok", "reply_to_id": reply_id, "messages": list(entries.values())}


def resolved_reply(event: object, reply_id: str, reply_text: str) -> dict | None:
    raw = getattr(event, "raw_message", None)
    resolved = getattr(getattr(raw, "reference", None), "resolved", None)
    if resolved is None or not reply_id:
        return None
    author = getattr(resolved, "author", None)
    timestamp = getattr(resolved, "created_at", None)
    return {
        "id": str(getattr(resolved, "id", None) or reply_id),
        "type": getattr(getattr(resolved, "type", None), "value", _MESSAGE_REPLY),
        "content": getattr(resolved, "content", None) or reply_text,
        "timestamp": timestamp.isoformat() if timestamp is not None else "",
        "author": {
            "id": str(getattr(author, "id", None) or ""),
            "global_name": getattr(author, "global_name", None),
            "username": getattr(author, "name", None),
            "bot": getattr(author, "bot", False),
            "system": getattr(author, "system", False),
        },
        "webhook_id": getattr(resolved, "webhook_id", None),
        "attachments": getattr(resolved, "attachments", None),
    }


def gather(
    dest: dict,
    home: Path,
    channel: str,
    event: object = None,
    reply_id: str = "",
    reply_text: str = "",
) -> dict:
    """Thread name, project, and history for one request, or {}.

    {} when the request was not filed from a thread under the dedicated
    channel; only those threads belong to the bridge. Never raises.
    """
    try:
        if not in_dedicated_thread(dest, channel):
            return {}
        name = thread_name(event, dest)
        return {
            "name": name,
            "project": resolve_project(name, dest["thread_id"], home),
            "history": collect_history(
                dest, reply_id, reply_text, resolved_reply(event, reply_id, reply_text), home=home,
            ),
        }
    except Exception:
        return {}
