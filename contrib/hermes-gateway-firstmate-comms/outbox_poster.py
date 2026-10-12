"""Local outbox poster for the Communication Officer gateway plugin.

Posts pending ``state/ext-outbox`` payloads to the request's Discord destination
and records receipts through ``bin/fm-ext-outbox.sh``.
The topic-thread routing contract is owned by docs/configuration.md under
"Topic threads (one thread per request)"; bin/fm-ext-topic.sh owns the name
priority (Firstmate's title, the request-text fallback, the label-plus-time
last fallback) and the validation the poster applies before every create and
rename.
Unsent payloads (no posting marker, no receipt, no terminal failed marker)
are retried after restart.
Oversized replies are split with the X-mode Discord budget pattern
(``FM_EXT_DISCORD_REPLY_MAX_CHARS``, default 1900) and posted in order.
A later-chunk transient failure records progress so earlier chunks are not
sent again, then releases the exclusive inflight send marker so only one
poster can resume the next chunk. A pre-send split failure or chunk-count
mismatch after a successful begin also releases that marker; posted_count
zero still aborts. An in-flight chunk without a confirmed post stays
mid-delivery.
A transient definite send failure (HTTP 429 or 5xx) before any chunk
succeeds deletes the posting marker so that generation can retry.
A permanent 4xx records a terminal failed marker so pending stops retrying.
A posting marker without a receipt is refused so an ambiguous crash or
transport error after Discord may have accepted the post cannot double-post.

For a request that arrived as an ordinary Discord message (payload origin
``message``), the poster reacts on that message: ``✅`` once an ``answer`` or
``final`` reply has posted and ``⚠️`` when any reply fails terminally. A
reaction is best effort and runs only after the delivery outcome is durable,
so a failed reaction can neither block nor repeat a reply. A slash-command
request has no message to react to.
Each chunk-progress record keeps the Discord ids Firstmate posted for its
request, which is how ``firstmate_post_for`` recognises a reply to one of
Firstmate's own messages.

A payload carrying a ``decision`` posts its option buttons on its last chunk,
but only while ``decisions.buttons_ready()`` says the gateway's Discord client
routes the clicks; otherwise the decision posts as plain text that the captain
can still answer by replying to it. Its chunk-progress record also keeps the
decision, whether buttons were posted, and when, which is how a click finds
its post. ``reconcile_decision_posts`` edits each settled decision post to its
outcome line with its buttons disabled.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable

try:
    from . import decisions
    from .intake import dedicated_channel, firstmate_home, firstmate_root
except ImportError:  # loaded from sys.path in hermetic tests
    import decisions
    from intake import dedicated_channel, firstmate_home, firstmate_root

SendFn = Callable[[dict], dict]
ReactFn = Callable[[str, str, str], None]
ThreadFn = Callable[[dict, str], dict]

_WATCHER_STARTED = False
_WATCHER_LOCK = threading.Lock()
_TRANSIENT_HTTP = {429, 500, 502, 503, 504}
# Discord REST base. Hermetic tests point the real sender at a local stub by
# assigning this module attribute; nothing in production overrides it.
DISCORD_API_BASE = "https://discord.com/api/v10"
# Discord requires a "DiscordBot ($url, $version)" agent. Its Cloudflare edge
# refuses urllib's default "Python-urllib/x.y" with HTTP 403 and the plain-text
# body "error code: 1010" before the API, so every post failed without it.
USER_AGENT = "DiscordBot (https://github.com/dnth/firstmate, 0.1.0)"
REACT_SEEN = "\U0001f440"  # eyes: the request was accepted
REACT_DONE = "\u2705"  # check mark: the answer has posted
REACT_FAILED = "\u26a0\ufe0f"  # warning: a reply could not be delivered
_SNOWFLAKE = re.compile(r"^[0-9]+$")
# A request slug is the SHA-256 hex of its canonical id, and the request-wide
# topic-thread record beside its payload is named "<slug>.thread.json".
_SLUG = re.compile(r"^[0-9a-f]{64}$")
_THREAD_RECORD_SUFFIX = ".thread.json"
# This bot's own Discord user id, read once per process for the thread
# ownership check a record without stored provenance needs.
_BOT_USER_ID = ""
# How often the watcher sweeps decision posts for decisions closed on another
# channel, which reads Firstmate's ledgers; click outcomes show within a cycle.
DECISION_SWEEP_SECS = 30.0


class DiscordSendError(Exception):
    """Classified Discord send outcome for outbox delivery."""

    def __init__(self, outcome: str, message: str = "", http_code: int | None = None, api_error: dict | None = None):
        super().__init__(message or outcome)
        self.outcome = outcome
        self.http_code = http_code
        self.api_error = api_error or {}


def classify_http_code(code: int) -> str:
    if code in _TRANSIENT_HTTP or code >= 500:
        return "transient"
    if code == 408:
        return "ambiguous"
    if 400 <= code < 500:
        return "permanent"
    return "ambiguous"


def classify_send_failure(exc: BaseException) -> str:
    if isinstance(exc, DiscordSendError):
        return exc.outcome
    if isinstance(exc, urllib.error.HTTPError):
        return classify_http_code(exc.code)
    if isinstance(exc, (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError)):
        return "ambiguous"
    if isinstance(exc, RuntimeError) and "missing DISCORD_BOT_TOKEN" in str(exc):
        return "transient"
    return "ambiguous"


def failure_reason(exc: BaseException) -> dict:
    http_code = getattr(exc, "http_code", None)
    if http_code is None and isinstance(exc, urllib.error.HTTPError):
        http_code = exc.code
    reason = {"ok": False, "reason": str(exc)}
    if http_code is not None:
        reason["http_code"] = http_code
    return reason


def outbox_cli() -> Path:
    return firstmate_root() / "bin" / "fm-ext-outbox.sh"


def state_dir(home: Path) -> Path:
    override = os.environ.get("FM_STATE_OVERRIDE")
    return Path(override) if override else home / "state"


def _env_for(home: Path) -> dict[str, str]:
    env = os.environ.copy()
    env["FM_HOME"] = str(home)
    env["FM_ROOT_OVERRIDE"] = str(firstmate_root())
    return env


def list_pending(home: Path | None = None) -> list[Path]:
    home = home or firstmate_home()
    result = subprocess.run(
        [str(outbox_cli()), "pending"],
        check=False,
        env=_env_for(home),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    paths = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if line:
            paths.append(Path(line))
    return paths


def begin_delivery(payload: dict, home: Path | None = None) -> str:
    home = home or firstmate_home()
    result = subprocess.run(
        [
            str(outbox_cli()),
            "begin",
            "--slug",
            payload["slug"],
            "--kind",
            payload["kind"],
            "--generation",
            str(payload["generation"]),
        ],
        check=False,
        env=_env_for(home),
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return "claimed"
    if result.returncode == 1:
        return "already-receipted"
    if result.returncode == 3:
        return "mid-delivery"
    if result.returncode == 4:
        return "terminal-failed"
    if result.returncode == 5:
        # A generation left in-flight by an ambiguous send stayed stuck past its
        # recovery budget: begin has recorded the terminal failure and woken
        # Firstmate, so this reply stops here instead of retrying forever.
        return "recovery-exhausted"
    raise RuntimeError(result.stderr.strip() or "begin failed")


def release_inflight(payload: dict, home: Path | None = None) -> str:
    home = home or firstmate_home()
    result = subprocess.run(
        [
            str(outbox_cli()),
            "release",
            "--slug",
            payload["slug"],
            "--kind",
            payload["kind"],
            "--generation",
            str(payload["generation"]),
        ],
        check=False,
        env=_env_for(home),
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return "released"
    raise RuntimeError(result.stderr.strip() or "release failed")


def abort_delivery(payload: dict, home: Path | None = None) -> str:
    home = home or firstmate_home()
    result = subprocess.run(
        [
            str(outbox_cli()),
            "abort",
            "--slug",
            payload["slug"],
            "--kind",
            payload["kind"],
            "--generation",
            str(payload["generation"]),
        ],
        check=False,
        env=_env_for(home),
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return "aborted"
    if result.returncode == 1:
        return "already-receipted"
    raise RuntimeError(result.stderr.strip() or "abort failed")


def record_receipt(payload: dict, receipt: dict, home: Path | None = None) -> str:
    home = home or firstmate_home()
    with _temp_json(receipt) as receipt_path:
        result = subprocess.run(
            [
                str(outbox_cli()),
                "receipt",
                "--slug",
                payload["slug"],
                "--kind",
                payload["kind"],
                "--generation",
                str(payload["generation"]),
                "--receipt-file",
                receipt_path,
            ],
            check=False,
            env=_env_for(home),
            capture_output=True,
            text=True,
        )
    if result.returncode in (0, 1):
        return "receipted" if result.returncode == 0 else "already-receipted"
    raise RuntimeError(result.stderr.strip() or "receipt failed")


def record_failed(payload: dict, reason: dict, home: Path | None = None) -> str:
    home = home or firstmate_home()
    with _temp_json(reason) as reason_path:
        result = subprocess.run(
            [
                str(outbox_cli()),
                "fail",
                "--slug",
                payload["slug"],
                "--kind",
                payload["kind"],
                "--generation",
                str(payload["generation"]),
                "--reason-file",
                reason_path,
            ],
            check=False,
            env=_env_for(home),
            capture_output=True,
            text=True,
        )
    if result.returncode in (0, 4):
        return "terminal-failed"
    if result.returncode == 1:
        return "already-receipted"
    raise RuntimeError(result.stderr.strip() or "fail failed")


def split_reply(
    text: str,
    home: Path | None = None,
    limit: int | None = None,
    cap: int | None = None,
) -> dict:
    home = home or firstmate_home()
    args = [str(outbox_cli()), "split"]
    if limit is not None:
        args.extend(["--max", str(limit)])
    if cap is not None:
        args.extend(["--cap", str(cap)])
    result = subprocess.run(
        args,
        check=False,
        env=_env_for(home),
        input=text,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "split failed")
    data = json.loads(result.stdout)
    texts = data.get("texts")
    if not isinstance(texts, list) or not texts:
        texts = [text]
    return {
        "limit": int(data.get("limit") or 1900),
        "cap": int(data.get("cap") or 25),
        "texts": [str(item) for item in texts],
    }


def progress_path(payload: dict, home: Path) -> Path:
    name = f"{payload['slug']}.{payload['kind']}.{payload['generation']}.progress.json"
    return state_dir(home) / "ext-outbox" / name


def load_progress(payload: dict, home: Path) -> dict | None:
    path = progress_path(payload, home)
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def write_progress(payload: dict, progress: dict, home: Path) -> None:
    with _temp_json(progress) as progress_file:
        result = subprocess.run(
            [
                str(outbox_cli()),
                "progress",
                "--slug",
                payload["slug"],
                "--kind",
                payload["kind"],
                "--generation",
                str(payload["generation"]),
                "--progress-file",
                progress_file,
            ],
            check=False,
            env=_env_for(home),
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "progress failed")


def _chunk_payload(payload: dict, text: str, index: int, total: int) -> dict:
    chunk = dict(payload)
    chunk["text"] = text
    chunk["chunk_index"] = index
    chunk["chunk_count"] = total
    return chunk


def _message_id(receipt: dict) -> str:
    return str(receipt.get("discord_message_id") or "")


class _temp_json:
    def __init__(self, body):
        self.body = body
        self.path = ""

    def _text(self) -> str:
        return json.dumps(self.body)

    def __enter__(self) -> str:
        fd, self.path = _mktemp()
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(self._text())
        return self.path

    def __exit__(self, *args) -> None:
        if self.path:
            try:
                os.unlink(self.path)
            except OSError:
                pass


class _temp_text(_temp_json):
    """A private temp file holding plain text instead of JSON."""

    def _text(self) -> str:
        return str(self.body)


def _mktemp() -> tuple[int, str]:
    return tempfile.mkstemp(prefix="fm-ext-receipt.")


def _bot_token() -> str:
    return os.environ.get("DISCORD_BOT_TOKEN") or os.environ.get("HERMES_DISCORD_TOKEN") or ""


def request_progress_path(payload: dict, home: Path) -> Path:
    """Progress-adjacent record holding this request's topic-thread id.

    The outbox payload and its chunk progress are per generation but the thread
    belongs to the whole request, so the thread id lives in one request-wide
    record beside them. Every later generation reuses it instead of creating a
    second thread.
    """
    return state_dir(home) / "ext-outbox" / f"{payload['slug']}.thread.json"


def load_request_thread(payload: dict, home: Path) -> str:
    """This request's recorded topic-thread id, or "" when none exists.

    Kept for callers that need only the id; load_request_topic carries the
    recorded name and state rename comparisons use."""
    path = request_progress_path(payload, home)
    if path.is_symlink() or not path.is_file():
        return ""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    if not isinstance(data, dict):
        return ""
    if data.get("request_id") != payload.get("request_id"):
        return ""
    thread_id = str(data.get("topic_thread_id") or "")
    return thread_id if _SNOWFLAKE.fullmatch(thread_id) else ""


def _read_thread_record(path: Path) -> dict:
    """A thread record's fields plus its own path, or {} when unusable."""
    if path.is_symlink() or not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    thread_id = str(data.get("topic_thread_id") or "")
    if not _SNOWFLAKE.fullmatch(thread_id):
        return {}
    request_id = data.get("request_id") or ""
    name = data.get("topic_name") or ""
    state = data.get("thread_state") or ""
    creating = data.get("creating_title") or ""
    creator = data.get("creator") or ""
    if not creator and data.get("adopted"):
        # Records written while adoption was a bare flag still say the thread
        # was not ours to begin with.
        creator = "adopted"
    return {"path": path,
            "request_id": request_id if isinstance(request_id, str) else "",
            "topic_thread_id": thread_id,
            "topic_name": name if isinstance(name, str) else "",
            "thread_state": state if isinstance(state, str) else "",
            "creator": creator if isinstance(creator, str) else "",
            "creating_title": creating if isinstance(creating, str) else ""}


def load_request_topic(payload: dict, home: Path) -> dict:
    """This request's recorded topic-thread id, name, and state, or {}."""
    record = _read_thread_record(request_progress_path(payload, home))
    if not record or record.get("request_id") != payload.get("request_id"):
        return {}
    return record


def _thread_record_slug(path: Path) -> str:
    """The request slug a thread record file is named for, or "".

    The record keeps no slug field, but its basename is always
    ``<sha256-request-slug>.thread.json``, which is how the creating
    request's context is found again for name validation.
    """
    name = path.name
    if not name.endswith(_THREAD_RECORD_SUFFIX):
        return ""
    slug = name[:-len(_THREAD_RECORD_SUFFIX)]
    return slug if _SLUG.fullmatch(slug) else ""


def _creating_request(recorded: dict) -> dict:
    """A stand-in payload for the top-level request that created a thread.

    Name validation re-derives the public name from the creating request's
    own text, title, and message time, so the thread's record is resolved
    back to that request through its canonical id - guild, channel, thread,
    and message are all still readable there - and then through that
    request's context file.
    """
    parts = str(recorded.get("request_id") or "").split(":")
    if len(parts) != 5 or parts[0] != "discord":
        return {}
    slug = _thread_record_slug(recorded["path"])
    if not slug:
        return {}
    return {"origin": "message", "slug": slug, "request_id": recorded["request_id"],
            "guild_id": parts[1], "channel_id": parts[2], "thread_id": parts[2],
            "message_id": parts[4]}


def load_thread_record_by_id(thread_id: str, home: Path) -> dict:
    """The record of the topic thread with this id, or {}.

    A thread is renamed both by the request that created it and by a later
    request that arrived inside it, so the record is found by the thread it
    names rather than by the request that is speaking.
    """
    if not _SNOWFLAKE.fullmatch(str(thread_id or "")):
        return {}
    directory = state_dir(home) / "ext-outbox"
    try:
        candidates = sorted(directory.glob(f"*{_THREAD_RECORD_SUFFIX}"))
    except OSError:
        return {}
    for path in candidates:
        record = _read_thread_record(path)
        if record and record.get("topic_thread_id") == thread_id:
            return record
    return {}


def save_request_thread(payload: dict, thread_id: str, home: Path,
                        topic_name: str = "", thread_state: str = "",
                        creating_title: str = "", creator: str = "") -> None:
    """Record this request's topic-thread id for every later generation.

    The record is the request-wide one beside its outbox payload. A rename
    made from inside the thread updates that same record through
    save_thread_record instead of writing a second one.
    """
    save_thread_record(request_progress_path(payload, home), payload.get("request_id"),
                       thread_id, topic_name=topic_name, thread_state=thread_state,
                       creating_title=creating_title, creator=creator)


def save_thread_record(path: Path, request_id: object, thread_id: str,
                       topic_name: str = "", thread_state: str = "",
                       creating_title: str = "", creator: str = "") -> None:
    """Write one thread record atomically, preserving any prior unset field.

    ``creator`` is the provenance that authorises a later rename: ``firstmate``
    when this home created the thread, ``adopted`` when an existing thread was
    only reused for routing. It is kept once known, so a record never loses
    the evidence that a rename decision depends on.

    A private state artifact beside the outbox, written with the same guards
    the shell publication helper enforces: a regular single-link file at mode
    0600, replaced atomically. Its basename is <slug>.thread.json, which the
    pending scan skips as a marker, avoiding payload validation for completed
    topics.
    """
    if path.is_symlink():
        raise RuntimeError("thread record is a symlink")
    try:
        prior = json.loads(path.read_text(encoding="utf-8"))
        prior_request = prior.get("request_id") if isinstance(prior, dict) else ""
        prior_name = prior.get("topic_name") if isinstance(prior, dict) else ""
        prior_state = prior.get("thread_state") if isinstance(prior, dict) else ""
        prior_creating = prior.get("creating_title") if isinstance(prior, dict) else ""
        prior_creator = prior.get("creator") if isinstance(prior, dict) else ""
        if not prior_creator and isinstance(prior, dict) and prior.get("adopted"):
            prior_creator = "adopted"
    except (OSError, ValueError):
        prior_request, prior_name, prior_state, prior_creating, prior_creator = "", "", "", "", ""
    record = {"request_id": request_id if request_id is not None else prior_request,
              "topic_thread_id": thread_id,
              "topic_name": topic_name or prior_name,
              "thread_state": thread_state or prior_state,
              "creating_title": creating_title or prior_creating}
    kept_creator = creator or (prior_creator if isinstance(prior_creator, str) else "")
    if kept_creator:
        record["creator"] = kept_creator
    body = json.dumps(record)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="fm-ext-thread.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    try:
        if path.stat().st_nlink != 1:
            path.unlink()
            raise RuntimeError("thread record is hard-linked")
    except FileNotFoundError:
        raise RuntimeError("thread record vanished after write")
    os.chmod(path, 0o600)


_THREAD_STATES = {"needs-you": "❓ ", "done": "✅ ", "none": ""}


def public_topic_name(
    payload: dict,
    name: str,
    home: Path | None = None,
    request_text: str = "",
    title: str = "",
) -> str:
    """Re-derive this request's thread name and check the stored one.

    The request text (plus Firstmate's title when the creating payload
    carries one) goes through bin/fm-ext-topic.sh, and the stored name is
    accepted only when it equals that fresh derivation, or a legacy
    label-plus-time name for the same message when no valid title takes
    precedence. Anything else falls back to the fresh name.
    """
    with _temp_text(request_text) as text_file, _temp_text(title) as title_file, _temp_text(name) as stored_file:
        result = subprocess.run(
            [str(firstmate_root() / "bin" / "fm-ext-topic.sh"),
             "--text-file", text_file, "--origin", str(payload.get("origin") or "slash"),
             "--thread-id", str(payload.get("thread_id") or ""),
             "--channel-id", str(payload.get("channel_id") or ""),
             "--message-id", str(payload.get("message_id") or ""),
             "--title-file", title_file, "--validate-name", "--stored-file", stored_file],
            capture_output=True, text=True, check=False,
            env=_env_for(home or firstmate_home()),
        )
    return result.stdout.strip() if result.returncode == 0 else ""


def thread_name_for(payload: dict, home: Path) -> str:
    """Public-safe thread name for this request, or "" when it needs none.

    Firstmate's title on the creating payload wins; otherwise the name is
    re-derived from the request text the intake recorded, never trusted from
    the stored string alone, so later follow-ups reuse the exact name the
    first reply used. Anything unusable - no context, no recorded name, an
    already-threaded request - means no thread is created.
    """
    if payload.get("origin") != "message":
        return ""
    if str(payload.get("thread_id") or "") != str(payload.get("channel_id") or ""):
        return ""
    try:
        context_path = state_dir(home) / "ext-context" / f"{payload['slug']}.json"
        context = json.loads(context_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, KeyError):
        return ""
    if not isinstance(context, dict):
        return ""
    name = context.get("topic") or ""
    request_text = context.get("request_text") or ""
    if not isinstance(name, str) or not name or not isinstance(request_text, str):
        return ""
    recorded = load_request_topic(payload, home)
    recorded_name = recorded.get("topic_name") or ""
    if recorded_name:
        # A thread already exists: its recorded base name wins over any
        # later title, so state renames build on the name Discord shows.
        # The base re-validates against the creating title the record keeps,
        # so a tampered record still falls back to a fresh derivation.
        return public_topic_name(payload, state_thread_name(recorded_name, "none"), home, request_text,
                                 recorded.get("creating_title") or "")
    return public_topic_name(payload, name, home, request_text,
                             "" if recorded else _title_for(payload))


def _context_for(payload: dict, home: Path | None) -> dict:
    try:
        base = home or firstmate_home()
        context_path = state_dir(base) / "ext-context" / f"{payload['slug']}.json"
        context = json.loads(context_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, KeyError):
        return {}
    return context if isinstance(context, dict) else {}


def _request_text_for(payload: dict, home: Path | None) -> str:
    text = _context_for(payload, home).get("request_text") or ""
    return text if isinstance(text, str) else ""


def _title_for(payload: dict) -> str:
    title = payload.get("thread_title") or ""
    return title if isinstance(title, str) else ""


def state_prefix(state: object) -> str | None:
    """Thread-name prefix for a thread_state value, or None when unknown."""
    if not isinstance(state, str):
        return None
    return _THREAD_STATES.get(state)


def state_thread_name(base: str, state: object) -> str | None:
    """Base name with the thread_state prefix applied, or None when unknown.

    The base is always the unprefixed thread name: any existing marker is
    stripped before the new one is applied, so needs-you then done shows a
    single ✅ and none always restores the bare name.
    """
    prefix = state_prefix(state)
    if prefix is None or not base:
        return None
    bare = base
    for known in ("❓ ", "✅ "):
        if bare.startswith(known):
            bare = bare[len(known):]
            break
    return prefix + bare if prefix else bare


def discord_rename_thread(thread_id: str, name: str) -> dict:
    """Rename a topic thread Firstmate created, best effort over REST."""
    token = _bot_token()
    if not token:
        raise DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    if not _SNOWFLAKE.fullmatch(thread_id):
        raise DiscordSendError("permanent", "thread id is not a Discord id")
    body = json.dumps({"name": name}).encode("utf-8")
    request = urllib.request.Request(
        f"{DISCORD_API_BASE}/channels/{thread_id}",
        data=body,
        method="PATCH",
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            raw = response.read().decode("utf-8") or "{}"
    except urllib.error.HTTPError as err:
        outcome = classify_http_code(err.code)
        try:
            details = json.loads(err.read().decode("utf-8"))
        except (OSError, UnicodeError, ValueError):
            details = {}
        if not isinstance(details, dict):
            details = {}
        raise DiscordSendError(outcome, f"discord HTTP {err.code}", err.code, details) from err
    except urllib.error.URLError as err:
        raise DiscordSendError("ambiguous", f"discord transport: {err}") from err
    except (TimeoutError, OSError) as err:
        raise DiscordSendError("ambiguous", f"discord transport: {err}") from err
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as err:
        raise DiscordSendError("ambiguous", "discord HTTP 200 with invalid JSON") from err
    if not isinstance(data, dict):
        raise DiscordSendError("ambiguous", "discord thread rename returned no object")
    return {"ok": True, "thread_id": thread_id}


def _bot_user_id() -> str:
    """This bot's own Discord user id, or "" when it cannot be read.

    Cached for the process: the id never changes for a token, and an
    ownership check must not pay a round trip per thread.
    """
    global _BOT_USER_ID
    if _BOT_USER_ID:
        return _BOT_USER_ID
    token = _bot_token()
    if not token:
        return ""
    request = urllib.request.Request(
        f"{DISCORD_API_BASE}/users/@me",
        headers={"Authorization": f"Bot {token}", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            data = json.loads(response.read().decode("utf-8"))
    except Exception:
        return ""
    if not isinstance(data, dict):
        return ""
    user_id = str(data.get("id") or "")
    if not _SNOWFLAKE.fullmatch(user_id):
        return ""
    _BOT_USER_ID = user_id
    return user_id


def discord_thread_owner(thread_id: str) -> str:
    """The Discord user id that created a thread, or "" when unproved.

    Read-only and best effort. A missing token, an unusable id, a transport
    or HTTP failure, or a reply without an owner all leave ownership unproved,
    which a rename check reads as "not ours" and refuses to rename on.
    """
    token = _bot_token()
    if not token or not _SNOWFLAKE.fullmatch(thread_id):
        return ""
    request = urllib.request.Request(
        f"{DISCORD_API_BASE}/channels/{thread_id}",
        headers={"Authorization": f"Bot {token}", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            data = json.loads(response.read().decode("utf-8"))
    except Exception:
        return ""
    if not isinstance(data, dict):
        return ""
    owner = str(data.get("owner_id") or "")
    return owner if _SNOWFLAKE.fullmatch(owner) else ""


def maybe_rename_topic_thread(
    payload: dict,
    thread_id: str,
    home: Path,
    rename_thread=None,
    thread_owner=None,
) -> str:
    """Apply this generation's thread_state to its topic thread, best effort.

    The creating request renames the thread it created; a request that
    arrived inside a topic thread this home created in the dedicated channel
    renames that thread, resolved by its id so the base name and the last
    applied marker come from the thread's own record.

    A thread is renamed only with positive evidence that this home created it.
    A record that says ``firstmate`` carries that evidence; one that says
    ``adopted`` was only reused for routing and is never renamed or marked; a
    record written before provenance was kept is renamed only when Discord
    reports the bot itself as the thread owner, and anything unproved - an
    unknown owner, another user's owner, or a failed lookup - leaves the name
    alone and is logged. Any other failure - unknown state, no base name, rate
    limit, transport error - is logged too and leaves the reply delivered;
    renaming never blocks or loses a reply.
    """
    state = payload.get("thread_state")
    if state_prefix(state) is None:
        return thread_id
    if payload.get("origin") != "message":
        return thread_id
    if str(payload.get("channel_id") or "") != dedicated_channel(home):
        return thread_id
    thread_field = str(payload.get("thread_id") or "")
    if thread_field == str(payload.get("channel_id") or ""):
        recorded = load_request_topic(payload, home)
        if recorded.get("topic_thread_id") != thread_id:
            return thread_id
        base = thread_name_for(payload, home)
        if not base:
            return thread_id
    else:
        thread_id = thread_field
        recorded = load_thread_record_by_id(thread_id, home)
        if not recorded:
            return thread_id
        creator = _creating_request(recorded)
        if not creator:
            return thread_id
        base = thread_name_for(creator, home)
        if not base:
            return thread_id
    provenance = recorded.get("creator") or ""
    if provenance == "adopted":
        return thread_id
    if provenance != "firstmate":
        owner = thread_owner or discord_thread_owner
        try:
            owner_id = owner(thread_id)
        except Exception as err:
            print(f"fm-ext-poster: thread owner lookup skipped: {err}", file=sys.stderr)
            return thread_id
        if not owner_id or owner_id != _bot_user_id():
            print(f"fm-ext-poster: thread {thread_id} ownership unproved; leaving its name alone",
                  file=sys.stderr)
            return thread_id
        provenance = "firstmate"
    want = state_thread_name(base, state)
    if want is None:
        return thread_id
    if want == (recorded.get("topic_name") or base):
        return thread_id
    renamer = rename_thread or discord_rename_thread
    try:
        renamer(thread_id, want)
    except Exception as err:
        print(f"fm-ext-poster: thread rename skipped: {err}", file=sys.stderr)
        return thread_id
    try:
        save_thread_record(recorded["path"], recorded.get("request_id"), thread_id,
                           topic_name=want, thread_state=state, creator=provenance,
                           creating_title=recorded.get("creating_title") or "")
    except Exception as err:
        print(f"fm-ext-poster: thread record update skipped: {err}", file=sys.stderr)
    return thread_id


def discord_create_thread(payload: dict, name: str) -> dict:
    """Start a public thread on the request's own message over Discord REST.

    Thread creation needs the channel that owns the message and that message's
    id. An in-thread request has a thread field distinct from its parent
    channel and must keep that destination rather than create a nested thread.

    The name the caller derived is re-validated against the request text
    (plus Firstmate's title when this payload carries one) before it may
    reach Discord, so only a name the rules can produce is ever created.
    """
    name = public_topic_name(payload, name, None,
                             _request_text_for(payload, None), _title_for(payload))
    if not name:
        raise DiscordSendError("permanent", "request does not need a topic thread")
    token = _bot_token()
    if not token:
        raise DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    channel = str(payload.get("channel_id") or "")
    message = str(payload.get("message_id") or "")
    if not (_SNOWFLAKE.fullmatch(channel) and _SNOWFLAKE.fullmatch(message)):
        raise DiscordSendError("permanent", "thread parent is not a Discord message id")
    if str(payload.get("thread_id") or "") != channel:
        raise DiscordSendError("permanent", "thread parent is not the request channel")
    body = json.dumps({"name": name, "auto_archive_duration": 1440}).encode("utf-8")
    request = urllib.request.Request(
        f"{DISCORD_API_BASE}/channels/{channel}/messages/{message}/threads",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            raw = response.read().decode("utf-8") or "{}"
    except urllib.error.HTTPError as err:
        outcome = classify_http_code(err.code)
        try:
            details = json.loads(err.read().decode("utf-8"))
        except (OSError, UnicodeError, ValueError):
            details = {}
        if not isinstance(details, dict):
            details = {}
        raise DiscordSendError(outcome, f"discord HTTP {err.code}", err.code, details) from err
    except urllib.error.URLError as err:
        raise DiscordSendError("ambiguous", f"discord transport: {err}") from err
    except (TimeoutError, OSError) as err:
        raise DiscordSendError("ambiguous", f"discord transport: {err}") from err
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as err:
        raise DiscordSendError("ambiguous", "discord HTTP 200 with invalid JSON") from err
    thread_id = str(data.get("id") or "")
    if not _SNOWFLAKE.fullmatch(thread_id):
        raise DiscordSendError("ambiguous", "discord thread create returned no thread id")
    return {"ok": True, "thread_id": thread_id}


def ensure_topic_thread(
    payload: dict,
    progress: dict,
    home: Path,
    create_thread: ThreadFn | None = None,
) -> str:
    """Return the thread id this generation must post into.

    A partially posted generation keeps its original destination so retries
    cannot split one reply between conversations, even if another generation
    creates a topic thread in the meantime. New generations reuse the
    request-wide record, or create a thread only for a top-level message in
    the dedicated channel. Discord error 160004 identifies an existing thread
    by the source message id, including when concurrent creators race.
    An empty result lets the caller post in place; the caller records this
    generation's destination in chunk progress, while save_request_thread
    persists the shared destination for later generations.
    """
    if (payload.get("origin") != "message"
            or str(payload.get("thread_id") or "") != str(payload.get("channel_id") or "")):
        return ""
    if int(progress.get("posted_count") or 0) > 0:
        return str(progress.get("topic_thread_id", load_request_thread(payload, home)) or "")
    recorded = load_request_thread(payload, home)
    if recorded:
        return recorded
    if str(payload.get("channel_id") or "") != dedicated_channel(home):
        return ""
    name = thread_name_for(payload, home)
    if not name:
        return ""
    creator = create_thread or discord_create_thread
    creating_title = _title_for(payload)
    thread_state = payload.get("thread_state") if isinstance(payload.get("thread_state"), str) else ""
    # Provenance decides whether a later state change may rename this thread:
    # this home created it, or it only adopted a thread that already existed.
    creator_provenance = "firstmate"
    try:
        receipt = creator(payload, name)
    except DiscordSendError as err:
        if err.api_error.get("code") != 160004:
            return ""
        thread_id = str(payload.get("message_id") or "")
        if not _SNOWFLAKE.fullmatch(thread_id):
            return ""
        try:
            request = urllib.request.Request(
                f"{DISCORD_API_BASE}/channels/{thread_id}",
                headers={"Authorization": f"Bot {_bot_token()}", "User-Agent": USER_AGENT},
            )
            with urllib.request.urlopen(request, timeout=15) as response:
                existing = json.loads(response.read().decode("utf-8"))
            if not isinstance(existing, dict) or str(existing.get("id") or "") != thread_id:
                return thread_id
            name = existing.get("name")
            if not isinstance(name, str) or not name:
                return thread_id
            creating_title = state_thread_name(name, "none")
            if public_topic_name(payload, creating_title, home,
                                 _request_text_for(payload, home), creating_title) != creating_title:
                return thread_id
        except Exception:
            return thread_id
        thread_state = ""
        creator_provenance = "adopted"
        receipt = {"thread_id": thread_id}
    except Exception:
        return ""
    thread_id = str((receipt or {}).get("thread_id") or "")
    if not _SNOWFLAKE.fullmatch(thread_id):
        return ""
    try:
        save_request_thread(payload, thread_id, home, topic_name=name,
                            thread_state=thread_state, creating_title=creating_title,
                            creator=creator_provenance)
    except Exception:
        return thread_id
    return thread_id


def discord_send(payload: dict) -> dict:
    """Post one outbox payload to Discord REST. No Discord library."""
    token = _bot_token()
    if not token:
        raise DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    channel = payload["thread_id"] or payload["channel_id"]
    message = {"content": payload["text"]}
    decision = payload.get("decision")
    last_chunk = int(payload.get("chunk_index") or 0) + 1 >= int(payload.get("chunk_count") or 1)
    buttons = isinstance(decision, dict) and last_chunk and decisions.buttons_ready()
    if buttons:
        message["components"] = decisions.components_for(decision)
    body = json.dumps(message).encode("utf-8")
    request = urllib.request.Request(
        f"{DISCORD_API_BASE}/channels/{channel}/messages",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            raw = response.read().decode("utf-8") or "{}"
    except urllib.error.HTTPError as err:
        outcome = classify_http_code(err.code)
        raise DiscordSendError(outcome, f"discord HTTP {err.code}", err.code) from err
    except urllib.error.URLError as err:
        raise DiscordSendError("ambiguous", f"discord transport: {err}") from err
    except (TimeoutError, OSError) as err:
        raise DiscordSendError("ambiguous", f"discord transport: {err}") from err
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as err:
        raise DiscordSendError("ambiguous", "discord HTTP 200 with invalid JSON") from err
    return {
        "ok": True,
        "discord_message_id": str(data.get("id") or ""),
        "channel_id": str(data.get("channel_id") or channel),
        "buttons": bool(buttons),
    }


def discord_edit(channel_id: str, message_id: str, content: str, components: list) -> None:
    """Replace one posted message's text and buttons over REST. Mentions are
    never parsed, so a name in the outcome line cannot ping anyone. Raises
    DiscordSendError on any failure.
    """
    token = _bot_token()
    if not token:
        raise DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    if not (_SNOWFLAKE.fullmatch(channel_id or "") and _SNOWFLAKE.fullmatch(message_id or "")):
        raise DiscordSendError("permanent", "edit target is not a Discord message id")
    body = json.dumps(
        {"content": content, "components": components, "allowed_mentions": {"parse": []}}
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{DISCORD_API_BASE}/channels/{channel_id}/messages/{message_id}",
        data=body,
        method="PATCH",
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15):
            pass
    except urllib.error.HTTPError as err:
        raise DiscordSendError(classify_http_code(err.code), f"discord HTTP {err.code}", err.code) from err
    except (urllib.error.URLError, TimeoutError, OSError) as err:
        raise DiscordSendError("ambiguous", f"discord transport: {err}") from err


def _decision_cli() -> Path:
    return firstmate_root() / "bin" / "fm-ext-decision.sh"


def _unshown_settled_posts(home: Path | None = None) -> bool:
    """True when a decision post's sent or final line is newer than what
    Discord was last shown for it."""
    outbox = state_dir(home or firstmate_home()) / "ext-outbox"
    for suffix in (".sent.json", ".settled.json"):
        for note in outbox.glob("*" + suffix):
            shown = outbox / (note.name[: -len(suffix)] + ".finalized")
            try:
                if not shown.exists() or note.stat().st_mtime >= shown.stat().st_mtime:
                    return True
            except OSError:
                return True
    return False


def reconcile_decision_posts(
    home: Path | None = None,
    full: bool = True,
    edit: Callable[[str, str, str, list], None] | None = None,
) -> list[str]:
    """Show each decision post's current line on Discord with its buttons off:
    the sent line once a click filed its request, then the outcome once
    Firstmate records the answer. ``full`` also settles posts whose decision
    closed or was replaced, which reads Firstmate's ledgers, so the watcher
    runs it on a slower cadence than the pass after a click. A permanent
    refusal (the message is gone) counts as shown; anything else is retried on
    a later pass. Returns the posts it updated.
    """
    home = home or firstmate_home()
    args = [str(_decision_cli()), "posts"] + ([] if full else ["--settled-only"])
    result = subprocess.run(args, check=False, env=_env_for(home), capture_output=True, text=True)
    if result.returncode != 0:
        return []
    shown = []
    for line in result.stdout.splitlines():
        try:
            item = json.loads(line)
            components = decisions.components_for(item, disabled=True)
            (edit or discord_edit)(item["channel_id"], item["message_id"], item["content"], components)
        except DiscordSendError as err:
            if err.outcome != "permanent":
                continue
        except Exception:
            continue
        with _temp_text(item["content"]) as content_file:
            done = subprocess.run(
                [str(_decision_cli()), "finalized", "--post", item["post"], "--content-file", content_file],
                check=False,
                env=_env_for(home),
                capture_output=True,
                text=True,
            )
        if done.returncode == 0:
            shown.append(item["post"])
    return shown


def discord_add_reaction(channel_id: str, message_id: str, emoji: str) -> None:
    """Add this bot's reaction to one Discord message over REST.
    Raises DiscordSendError on any failure; callers treat reactions as best
    effort and never let one decide a delivery outcome.
    """
    token = _bot_token()
    if not token:
        raise DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    if not (_SNOWFLAKE.fullmatch(channel_id or "") and _SNOWFLAKE.fullmatch(message_id or "")):
        raise DiscordSendError("permanent", "reaction target is not a Discord message id")
    request = urllib.request.Request(
        f"{DISCORD_API_BASE}/channels/{channel_id}/messages/{message_id}"
        f"/reactions/{urllib.parse.quote(emoji, safe='')}/@me",
        data=b"",
        method="PUT",
        headers={
            "Authorization": f"Bot {token}",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10):
            pass
    except urllib.error.HTTPError as err:
        raise DiscordSendError(classify_http_code(err.code), f"discord HTTP {err.code}", err.code) from err
    except (urllib.error.URLError, TimeoutError, OSError) as err:
        raise DiscordSendError("ambiguous", f"discord transport: {err}") from err


def react_to_request(payload: dict, emoji: str, react: ReactFn | None = None) -> bool:
    """React on the Discord message a request came from, best effort.
    Only a message-origin request has a message to react to; a slash command
    is an interaction. Returns whether the reaction was added and never raises.
    """
    if payload.get("origin") != "message":
        return False
    channel = str(payload.get("thread_id") or payload.get("channel_id") or "")
    try:
        (react or discord_add_reaction)(channel, str(payload.get("message_id") or ""), emoji)
    except Exception:
        return False
    return True


def firstmate_post_for(message_id: str, home: Path | None = None) -> dict | None:
    """Return {"request_id": ...} when Firstmate's outbox posted message_id.
    The chunk-progress records hold every Discord id the poster has sent,
    including the leading chunks of a reply still being delivered, and they
    follow the bridge's retention window. request_id is empty for a record
    written before progress carried it. None means the message is not one of
    Firstmate's own posts that this home still remembers.
    """
    if not _SNOWFLAKE.fullmatch(str(message_id or "")):
        return None
    home = home or firstmate_home()
    outbox = state_dir(home) / "ext-outbox"
    if outbox.is_symlink() or not outbox.is_dir():
        return None
    for path in sorted(outbox.glob("*.progress.json")):
        if path.is_symlink() or not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        posted = data.get("discord_message_ids")
        if isinstance(posted, list) and str(message_id) in [str(item) for item in posted]:
            request_id = data.get("request_id")
            return {"request_id": request_id if isinstance(request_id, str) else ""}
    return None


WAITING_PIN_STATE = "ext-waiting-pin.json"
WAITING_PIN_MISSING_PERMISSIONS = {403, 50013, 50001}


def waiting_pin_state_path(home: Path) -> Path:
    return state_dir(home) / WAITING_PIN_STATE


def waiting_pin_http(action: str, path: str, token: str, body: dict | None = None) -> dict:
    import urllib.request

    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(
        f"{DISCORD_API_BASE}{path}",
        data=data,
        method={"edit": "PATCH", "post": "POST", "pin": "PUT"}[action],
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            raw = response.read().decode("utf-8") or "{}"
    except urllib.error.HTTPError as err:
        raise DiscordSendError(classify_http_code(err.code), f"discord HTTP {err.code}", err.code) from err
    except urllib.error.URLError as err:
        raise DiscordSendError("ambiguous", f"discord transport: {err}") from err
    except (TimeoutError, OSError) as err:
        raise DiscordSendError("ambiguous", f"discord transport: {err}") from err
    try:
        return json.loads(raw)
    except json.JSONDecodeError as err:
        raise DiscordSendError("ambiguous", "discord HTTP 200 with invalid JSON") from err


def waiting_pin_load(home: Path) -> dict | None:
    path = waiting_pin_state_path(home)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def waiting_pin_store(home: Path, record: dict) -> None:
    path = waiting_pin_state_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, prefix=".ext-waiting-pin.", delete=False) as stream:
        tmp = Path(stream.name)
        stream.write(json.dumps(record))
    try:
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def waiting_pin_deliver(payload: dict, home: Path) -> str:
    target = subprocess.run([str(outbox_cli()), "pin-target"], env=_env_for(home), capture_output=True, text=True)
    expected = f"{payload.get('guild_id', '')} {payload.get('channel_id', '')}"
    if target.returncode != 0 or target.stdout.strip() != expected:
        return "obsolete"
    if any(key in payload for key in ("request_id", "slug", "generation")):
        return "obsolete"
    identity = {"slug": "0" * 64, "kind": "waiting-pin", "generation": 1}
    claim = subprocess.run(
        [str(outbox_cli()), "claim", "--slug", identity["slug"], "--kind", identity["kind"], "--generation", "1"],
        env=dict(_env_for(home), FM_EXT_INFLIGHT_OWNER_PID=str(os.getpid())), capture_output=True, text=True,
    )
    if claim.returncode == 1:
        return "mid-delivery"
    if claim.returncode != 0:
        raise DiscordSendError("transient", claim.stderr.strip() or "pin claim failed")
    try:
        target = subprocess.run([str(outbox_cli()), "pin-target"], env=_env_for(home), capture_output=True, text=True)
        if target.returncode != 0 or target.stdout.strip() != expected:
            return "obsolete"
        return _waiting_pin_deliver_claimed(payload, home)
    finally:
        release_inflight(identity, home=home)


def _waiting_pin_deliver_claimed(payload: dict, home: Path) -> str:
    """Post once, pin once, then edit the pinned message in place."""
    token = os.environ.get("DISCORD_BOT_TOKEN") or os.environ.get("HERMES_DISCORD_TOKEN")
    if not token:
        raise DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    channel = str(payload.get("channel_id") or "")
    text = str(payload.get("text") or "")
    if not channel or not text:
        raise DiscordSendError("permanent", "waiting-pin payload missing channel or text")
    stored = waiting_pin_load(home) or {}
    snapshot_id = int(payload.get("snapshot_id") or int(payload.get("recorded_at") or 0) * 1_000_000_000)
    stored_snapshot = int(stored.get("snapshot_id") or int(stored.get("refreshed_at") or 0) * 1_000_000_000)
    if snapshot_id < stored_snapshot:
        return "superseded"
    guild = str(payload.get("guild_id") or "")
    message_id = str(stored.get("message_id") or "")
    if str(stored.get("channel_id") or "") != channel or str(stored.get("guild_id") or "") != guild:
        message_id = ""
    pinned = False
    created_message = False
    if message_id:
        try:
            edited = waiting_pin_http("edit", f"/channels/{channel}/messages/{message_id}", token, {"content": text})
            pinned = edited.get("pinned") is True
        except DiscordSendError as err:
            if err.http_code != 404:
                raise
            message_id = ""
    if not message_id:
        created = waiting_pin_http("post", f"/channels/{channel}/messages", token, {"content": text})
        message_id = str(created.get("id") or "")
        if not message_id:
            raise DiscordSendError("ambiguous", "discord post returned no message id")
        pinned = created.get("pinned") is True
        created_message = True
    record = {
        "message_id": message_id,
        "guild_id": guild,
        "channel_id": channel,
        "pinned": pinned,
        "content_hash": str(payload.get("content_hash") or ""),
        "refreshed_at": int(payload.get("recorded_at") or 0),
        "snapshot_id": snapshot_id,
    }
    waiting_pin_store(home, record)
    if not pinned:
        try:
            waiting_pin_http("pin", f"/channels/{channel}/pins/{message_id}", token, {})
        except DiscordSendError as err:
            if err.http_code not in WAITING_PIN_MISSING_PERMISSIONS:
                raise
            record["pin_error"] = f"missing Manage Messages (discord HTTP {err.http_code})"
        else:
            record["pinned"] = True
        waiting_pin_store(home, record)
    if created_message:
        return "posted-pinned" if record["pinned"] else "posted-unpinned"
    return "edited"


def deliver_one(
    path: Path,
    send: SendFn | None = None,
    home: Path | None = None,
    react: ReactFn | None = None,
    create_thread: ThreadFn | None = None,
    rename_thread=None,
) -> str:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        # The generation reached a terminal outcome and its payload was retired
        # so later polls stop re-scanning it. A sibling poster can retire it
        # between list_pending and here, so this is an ordinary outcome rather
        # than an error that would abort the whole drain pass.
        return "retired"
    home = home or firstmate_home()
    if isinstance(payload.get("kind"), str) and payload["kind"] == "waiting-pin":
        result = waiting_pin_deliver(payload, home)
        if result != "mid-delivery":
            path.unlink(missing_ok=True)
        return result
    status = begin_delivery(payload, home=home)
    if status == "recovery-exhausted":
        react_to_request(payload, REACT_FAILED, react)
    if status != "claimed":
        return status
    sender = send or discord_send
    stored = load_progress(payload, home)
    try:
        split = split_reply(
            payload.get("text") or "",
            home=home,
            limit=stored.get("limit") if stored else None,
            cap=stored.get("cap") if stored else None,
        )
    except Exception:
        if stored and int(stored.get("posted_count") or 0) > 0:
            release_inflight(payload, home=home)
            return "mid-delivery"
        abort_delivery(payload, home=home)
        return "failed"
    chunks = split["texts"]
    progress = stored or {
        "request_id": payload["request_id"],
        "total": len(chunks),
        "posted_count": 0,
        "inflight": None,
        "discord_message_ids": [],
        "limit": split["limit"],
        "cap": split["cap"],
    }
    if isinstance(payload.get("decision"), dict):
        # The post record a click and a later edit find this decision by.
        progress["decision"] = payload["decision"]
    if int(progress.get("total") or 0) != len(chunks):
        release_inflight(payload, home=home)
        return "mid-delivery"
    thread_id = ensure_topic_thread(payload, progress, home, create_thread)
    progress["topic_thread_id"] = thread_id
    write_progress(payload, progress, home)
    start = int(progress.get("posted_count") or 0)
    ids = list(progress.get("discord_message_ids") or [])
    send_payload = dict(payload)
    if thread_id:
        send_payload["thread_id"] = thread_id
    for index in range(start, len(chunks)):
        progress["inflight"] = index
        write_progress(payload, progress, home)
        try:
            receipt = sender(_chunk_payload(send_payload, chunks[index], index, len(chunks)))
        except Exception as err:
            outcome = classify_send_failure(err)
            if outcome == "transient":
                progress["inflight"] = None
                write_progress(payload, progress, home)
                if int(progress.get("posted_count") or 0) == 0:
                    abort_status = abort_delivery(payload, home=home)
                    if abort_status == "already-receipted":
                        return abort_status
                    return "failed"
                release_inflight(payload, home=home)
                return "failed"
            if outcome == "permanent":
                fail_status = record_failed(payload, failure_reason(err), home=home)
                if fail_status == "already-receipted":
                    return fail_status
                react_to_request(payload, REACT_FAILED, react)
                return "terminal-failed"
            return "mid-delivery"
        if not isinstance(receipt, dict):
            receipt = {}
        ids.append(_message_id(receipt))
        progress["discord_message_ids"] = ids
        progress["posted_count"] = index + 1
        progress["inflight"] = None
        if "decision" in progress and index + 1 == len(chunks):
            progress["buttons"] = bool(receipt.get("buttons"))
            progress["posted_at"] = time.time()
        write_progress(payload, progress, home)
    record_receipt(
        payload,
        {
            "ok": True,
            "discord_message_id": ids[0] if ids else "",
            "discord_message_ids": ids,
            "chunks": len(chunks),
            "channel_id": str(send_payload.get("thread_id") or send_payload.get("channel_id") or ""),
            "thread_id": str(send_payload.get("thread_id") or ""),
        },
        home=home,
    )
    if payload.get("kind") in ("answer", "final"):
        react_to_request(payload, REACT_DONE, react)
    # Renaming is not tied to this generation's destination: an in-thread
    # request posts where it arrived and may still mark that thread's state,
    # so the call always runs and decides inside what it may touch.
    maybe_rename_topic_thread(payload, thread_id, home, rename_thread)
    return "sent"


def drain_outbox(
    send: SendFn | None = None,
    home: Path | None = None,
    react: ReactFn | None = None,
    create_thread: ThreadFn | None = None,
    rename_thread=None,
) -> list[str]:
    results = []
    for path in list_pending(home=home):
        try:
            results.append(deliver_one(path, send=send, home=home, react=react,
                                       create_thread=create_thread, rename_thread=rename_thread))
        except DiscordSendError:
            results.append("failed")
    return results


def start_outbox_watcher(interval: float | None = None) -> None:
    global _WATCHER_STARTED
    with _WATCHER_LOCK:
        if _WATCHER_STARTED:
            return
        _WATCHER_STARTED = True

    wait = interval
    if wait is None:
        wait = float(os.environ.get("FM_EXT_OUTBOX_POLL_SECS", "2"))

    def _loop() -> None:
        last_full = 0.0
        while True:
            try:
                decisions.ensure_click_route()
            except Exception:
                pass
            try:
                drain_outbox()
            except Exception:
                pass
            # Clicks settle posts locally, so their edits follow within a
            # cycle; posts closed on another channel need a ledger read and
            # are swept on the slower cadence.
            try:
                full = time.monotonic() - last_full >= DECISION_SWEEP_SECS
                if full:
                    last_full = time.monotonic()
                if full or _unshown_settled_posts():
                    reconcile_decision_posts(full=full)
            except Exception:
                pass
            time.sleep(wait)

    thread = threading.Thread(target=_loop, name="fm-ext-outbox", daemon=True)
    thread.start()
