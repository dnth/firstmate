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
Oversized replies are split by ``discord_split``, which keeps the reply's own
lines and list nesting (``FM_EXT_DISCORD_REPLY_MAX_CHARS``, default 1900), and
posted in order.
A later-chunk transient failure records progress so earlier chunks are not
sent again, then releases the exclusive inflight send marker so only one
poster can resume the next chunk. A pre-send split failure or chunk-count
mismatch after a successful begin also releases that marker; posted_count
zero still aborts unless a media upload was already tried. An in-flight
chunk without a confirmed post stays
mid-delivery.
A transient definite send failure (HTTP 429 or 5xx) before any chunk
succeeds deletes the posting marker so that generation can retry, unless a
media upload was already tried: then progress is kept so the one upload
retry holds across delivery attempts.
The delivery and bounded-recovery contract, including ambiguous HTTP 408,
is owned by docs/configuration.md under "Local Communication Officer bridge";
"Outbound media" owns nonce reconciliation and upload retry versus fallback.

For a request that arrived as an ordinary Discord message (payload origin
``message``), the poster reacts on that message: ``✅`` once an ``answer`` or
``final`` reply has posted and ``⚠️`` when any reply fails terminally. A
reaction is best effort and runs only after the delivery outcome is durable,
so a failed reaction can neither block nor repeat a reply. A slash-command
request has no message to react to.
Each chunk-progress record keeps the Discord ids Firstmate posted for its
request, which is how ``firstmate_post_for`` recognises a reply to one of
Firstmate's own messages.

A decision payload carries buttons only on the final chunk and only when it
names options and ``decisions.buttons_ready(bot_user_id)`` confirms click
routing; otherwise it stays plain text. Progress keeps the decision, button
state, chunk ids, and posting time.
Structured sections keep options together on the final chunk and reserve room
for a later outcome header.
``reconcile_decision_posts`` edits only that final message under the display
rules in docs/configuration.md, "Decision buttons".

Topic-thread titles are written only by ``thread_title``; a delivery hands
its thread state, retitle, and decision flag to ``thread_autoname`` through
``queue_title_inputs``, and ``sweep_thread_titles`` feeds the decision
ledger. docs/configuration.md, "Thread title reconciler", owns the contract.

A payload with ``media`` uploads its staged files with its last chunk as one
multipart message; docs/configuration.md, "Outbound media", owns the single
retry, the failure note, and the receipt fields.

The watcher loop and delivery diagnostics are described in README.md under
"How it works".
"""

from __future__ import annotations

import hashlib
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
import uuid
from pathlib import Path
from typing import Callable

try:
    from . import decisions
    from . import discord_split
    from .intake import dedicated_channel, firstmate_home, firstmate_root
    from .tool_path import firstmate_env
except ImportError:  # loaded from sys.path in hermetic tests
    import decisions
    import discord_split
    from intake import dedicated_channel, firstmate_home, firstmate_root
    from tool_path import firstmate_env

SendFn = Callable[[dict], dict]
ReactFn = Callable[[str, str, str], None]
ThreadFn = Callable[[dict, str], dict]

_WATCHER_STARTED = False
_WATCHER_LOCK = threading.Lock()
# One lock serializes every writer of a request-wide "<slug>.thread.json"
# record. Delivery, title inputs, and the title reconciler all
# read-merge-write that file, so without it one could overwrite another.
_THREAD_RECORD_LOCK = threading.RLock()
# Time each watcher step separately so a slow drain or reconciliation step
# can be identified in the journal.
SLOW_STEP_SECS = 5.0
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

DISCORD_MESSAGE_MAX = 2000
DECISION_OUTCOME_HEADER_RESERVE = 256
# A request slug is the SHA-256 hex of its canonical id, and the request-wide
# topic-thread record beside its payload is named "<slug>.thread.json".
_SLUG = re.compile(r"^[0-9a-f]{64}$")
_THREAD_RECORD_SUFFIX = ".thread.json"
# How often the watcher sweeps decision posts for decisions closed on another
# channel, which reads Firstmate's ledgers; click outcomes show within a cycle.
DECISION_SWEEP_SECS = 30.0
# Outbound media. bin/fm-ext-media.sh owns screening, staging, and the generic
# names Discord sees; docs/configuration.md "Outbound media" owns delivery.
# A media upload is tried at most MEDIA_UPLOAD_ATTEMPTS times per delivery
# attempt - the first try plus exactly one retry - and only after Discord
# answered with an HTTP error, so no try can have created a message. After
# that the text posts alone with MEDIA_FAILED_NOTE.
MEDIA_UPLOAD_ATTEMPTS = 2
# Pause before the one retry; hermetic tests set it to 0.
MEDIA_RETRY_DELAY_SECS = 2.0
MEDIA_UPLOAD_TIMEOUT_SECS = 120
MEDIA_FAILED_NOTE = "_(screenshot couldn't be posted)_"
# Room the splitter keeps free on a media post for the note above.
MEDIA_NOTE_RESERVE = len(MEDIA_FAILED_NOTE) + 2


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


def media_cli() -> Path:
    return firstmate_root() / "bin" / "fm-ext-media.sh"


def load_media_uploads(payload_path: Path, payload: dict, home: Path) -> tuple[list[dict], list[str]]:
    """Read this payload's staged media for upload: (uploads, dropped names).

    ``bin/fm-ext-media.sh verify`` owns which staged files may still post. The
    bytes read here must hash to the digest it verified, so the bytes sent are
    exactly the bytes checked; any doubt drops the file rather than sending it.
    """
    media = payload.get("media") if isinstance(payload.get("media"), dict) else {}
    entries = media.get("files") if isinstance(media.get("files"), list) else []
    names = [str(entry.get("name") or "") for entry in entries if isinstance(entry, dict)]
    try:
        result = subprocess.run(
            [str(media_cli()), "verify", "--payload", str(payload_path)],
            check=False,
            env=_env_for(home),
            capture_output=True,
            text=True,
        )
        verified = json.loads(result.stdout) if result.returncode == 0 else {}
    except (OSError, ValueError):
        verified = {}
    if not isinstance(verified, dict) or not isinstance(verified.get("files"), list):
        return [], names
    staged = state_dir(home) / "ext-media" / "staged" / str(media.get("dir") or "")
    uploads: list[dict] = []
    dropped = [str(name) for name in verified.get("dropped") or []]
    for item in verified["files"]:
        name = str(item.get("name") or "") if isinstance(item, dict) else ""
        try:
            path = Path(str(item["path"]))
            if path.name != name or path.parent.resolve() != staged.resolve():
                raise ValueError("staged media escaped its folder")
            fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as handle:
                data = handle.read()
            if hashlib.sha256(data).hexdigest() != item["sha256"]:
                raise ValueError("staged media changed after verification")
            uploads.append({"name": name, "media_type": str(item["media_type"]), "data": data})
        except (KeyError, OSError, TypeError, ValueError):
            dropped.append(name)
    return uploads, dropped


def _multipart_body(message: dict, files: list[dict]) -> tuple[bytes, str]:
    """Discord's multipart create-message body: payload_json plus files[n]."""
    boundary = "fm-ext-" + uuid.uuid4().hex
    body = dict(message)
    body["attachments"] = [{"id": index, "filename": item["name"]} for index, item in enumerate(files)]
    parts = [
        f"--{boundary}\r\n".encode(),
        b'Content-Disposition: form-data; name="payload_json"\r\n',
        b"Content-Type: application/json\r\n\r\n",
        json.dumps(body).encode("utf-8"),
        b"\r\n",
    ]
    for index, item in enumerate(files):
        parts += [
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="files[{index}]"; filename="{item["name"]}"\r\n'.encode(),
            f"Content-Type: {item['media_type']}\r\n\r\n".encode(),
            item["data"],
            b"\r\n",
        ]
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def state_dir(home: Path) -> Path:
    override = os.environ.get("FM_STATE_OVERRIDE")
    return Path(override) if override else home / "state"


def _env_for(home: Path) -> dict[str, str]:
    """The environment for one Firstmate script this poster runs."""
    return firstmate_env(home, firstmate_root())


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


def reply_limits(home: Path) -> dict:
    """Resolve the configured Discord split budget from its shell owner."""
    result = subprocess.run(
        [str(outbox_cli()), "limits"],
        check=False,
        env=_env_for(home),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "limits failed")
    data = json.loads(result.stdout)
    return {"limit": int(data["limit"]), "cap": int(data["cap"])}


def split_reply(
    text: str,
    home: Path | None = None,
    limit: int | None = None,
    cap: int | None = None,
    legacy: bool = False,
    reserve: int = 0,
) -> dict:
    """Split a reply into Discord chunks.

    discord_split owns new splits, so the Discord path no longer shells out to
    jq. A legacy resume - a generation that was already partially posted before
    chunk plans were persisted - keeps the pre-change splitter through
    `fm-ext-outbox.sh split --legacy`, so it finishes the chunks it started with.
    ``reserve`` keeps that many characters of Discord's message limit free on
    every new chunk, for text the poster may append later.
    """
    home = home or firstmate_home()
    if not legacy:
        resolved = reply_limits(home) if limit is None or cap is None else None
        used_limit = limit if limit is not None else resolved["limit"]
        used_cap = cap if cap is not None else resolved["cap"]
        if reserve:
            used_limit = min(used_limit, DISCORD_MESSAGE_MAX - reserve)
        texts = discord_split.split_discord(text, used_limit, used_cap)
        if not texts:
            texts = [text]
        return {"limit": used_limit, "cap": used_cap, "texts": [str(item) for item in texts]}
    args = [str(outbox_cli()), "split", "--legacy"]
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


def split_decision_reply(
    payload: dict,
    home: Path,
    limit: int | None = None,
    cap: int | None = None,
    legacy: bool = False,
) -> dict:
    """Split decision sections while keeping their option list on the button post."""
    text = payload.get("text") or ""
    decision = payload.get("decision") or {}
    sections = decision.get("sections") or {}
    resolved = reply_limits(home) if limit is None or cap is None else None
    used_limit = limit if limit is not None else resolved["limit"]
    used_cap = cap if cap is not None else resolved["cap"]
    if legacy:
        return split_reply(text, home=home, limit=used_limit, cap=used_cap, legacy=True)
    budget = min(used_limit, DISCORD_MESSAGE_MAX - DECISION_OUTCOME_HEADER_RESERVE)
    if not sections.get("structured"):
        split = split_reply(text, home=home, limit=budget, cap=max(used_cap, len(text) + 1))
        if len(split["texts"]) > used_cap:
            raise ValueError("decision question exceeds the configured chunk cap")
        split["cap"] = used_cap
        return split

    question = sections.get("question", "")
    explanation = sections.get("explanation", "")
    options = sections.get("options", "")
    cue = sections.get("cue", "")
    prefix = question + (("\n\n" + explanation) if explanation else "")
    suffix = (("\n\n" + options) if options else "") + (("\n" + cue) if cue else "")
    if prefix + suffix != text:
        raise ValueError("decision sections do not reproduce the post text")
    budget = min(DISCORD_MESSAGE_MAX - DECISION_OUTCOME_HEADER_RESERVE,
                 max(budget, len(suffix) + 1))
    prefix_budget = budget - len(suffix)
    if prefix_budget < 1:
        raise ValueError("decision option list leaves no room for question text")
    chunks = discord_split.split_discord(prefix, prefix_budget, max(used_cap, len(prefix) + 1))
    if len(chunks) > used_cap:
        raise ValueError("decision question and explanation exceed the configured chunk cap")
    if not chunks:
        chunks = [""]
    chunks[-1] += suffix
    if any(len(chunk) > budget for chunk in chunks):
        raise RuntimeError("decision chunk exceeded its reserved message budget")
    return {"limit": budget, "cap": used_cap, "texts": chunks}


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


_TOKEN_KEYS = ("DISCORD_BOT_TOKEN", "HERMES_DISCORD_TOKEN")
# Profile home whose bot this poster speaks as. None means unconfigured: process env only.
_BOT_PROFILE_HOME = None
_BOT_IDENTITY_LOGGED = ""


def _owner_profile_name(home) -> str:
    """Hermes profile id for *home*: its profiles/<name> folder, else the default profile."""
    if home is None:
        return "default"
    try:
        from hermes_constants import profile_name_for_home
    except ImportError:
        return home.name if home.parent.name == "profiles" else "default"
    return profile_name_for_home(home) or "default"


def configure_bot_identity(profile_home) -> None:
    """Choose the Hermes profile whose Discord bot REST calls authenticate as.

    register() passes the home Hermes loaded this plugin for. Pass None to
    keep the process environment alone (standalone runs and tests).
    """
    global _BOT_PROFILE_HOME, _BOT_IDENTITY_LOGGED
    _BOT_PROFILE_HOME = Path(profile_home) if profile_home else None
    _BOT_IDENTITY_LOGGED = ""
    decisions.set_owner_profile(_owner_profile_name(_BOT_PROFILE_HOME))


def _process_hermes_home() -> Path:
    try:
        from hermes_constants import get_process_hermes_home
    except ImportError:
        return Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    return Path(get_process_hermes_home())


def _same_home(a: Path, b: Path) -> bool:
    return a.resolve() == b.resolve()


def _env_token(env) -> str:
    for key in _TOKEN_KEYS:
        if env.get(key):
            return env[key]
    return ""


def _read_env_file(path: Path) -> dict:
    """KEY=VALUE lines from a profile .env. Used only when Hermes is not importable."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    values = {}
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip("'\"")
    return values


def _profile_env_token(home: Path) -> str:
    """The owning profile's bot token from its own secret scope, never another profile's."""
    try:
        from agent.secret_scope import build_profile_secret_scope
    except ImportError:
        scope = _read_env_file(home / ".env")
    else:
        scope = build_profile_secret_scope(home)
    return _env_token(scope)


def _bot_identity() -> tuple:
    """(token, source). Source names the resolution used, or every source tried when empty."""
    if _BOT_PROFILE_HOME is None:
        token = _env_token(os.environ)
        return (token, "process-env") if token else ("", "tried process-env")
    home = _BOT_PROFILE_HOME
    tried = []
    if _same_home(home, _process_hermes_home()):
        tried.append("process-env")
        token = _env_token(os.environ)
        if token:
            return token, "process-env"
    tried.append("profile-env")
    token = _profile_env_token(home)
    if token:
        return token, f"profile-env ({home.name})"
    return "", "tried " + " then ".join(tried)


def _bot_token() -> str:
    """Discord bot token REST calls authenticate with. Empty when unresolved (transient)."""
    global _BOT_IDENTITY_LOGGED
    token, source = _bot_identity()
    label = source if token else f"no token ({source})"
    if label != _BOT_IDENTITY_LOGGED:
        _BOT_IDENTITY_LOGGED = label
        print(f"fm-ext-poster: bot identity {label}", file=sys.stderr)
    return token


def request_progress_path(payload: dict, home: Path) -> Path:
    """Progress-adjacent record holding this request's topic-thread id.

    The outbox payload and its chunk progress are per generation but the thread
    belongs to the whole request, so the thread id lives in one request-wide
    record beside them. Every later generation reuses it instead of creating a
    second thread.
    """
    return state_dir(home) / "ext-outbox" / f"{payload['slug']}.thread.json"


def load_request_thread(payload: dict, home: Path) -> str:
    """This request's recorded topic-thread id, or "" when none exists."""
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
    creating = data.get("creating_title") or ""
    creator = data.get("creator") or ""
    title = data.get("title")
    if not creator and data.get("adopted"):
        # Records written while adoption was a bare flag still say the thread
        # was not ours to begin with.
        creator = "adopted"
    return {"path": path,
            "request_id": request_id if isinstance(request_id, str) else "",
            "topic_thread_id": thread_id,
            "topic_name": name if isinstance(name, str) else "",
            "creator": creator if isinstance(creator, str) else "",
            "creating_title": creating if isinstance(creating, str) else "",
            "title": title if isinstance(title, dict) else {}}


def _epoch(value: object) -> float:
    """A recorded epoch time, or 0 when absent or not a number."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0.0
    return float(value)


def load_request_topic(payload: dict, home: Path) -> dict:
    """This request's recorded topic-thread record, or {}."""
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
                        topic_name: str = "", creating_title: str = "", creator: str = "",
                        opening_posted: bool | None = None) -> None:
    """Record this request's topic-thread id for every later generation.

    The record is the request-wide one beside its outbox payload. Title
    inputs for the thread update that same record through
    save_thread_record instead of writing a second one.
    """
    save_thread_record(request_progress_path(payload, home), payload.get("request_id"),
                       thread_id, topic_name=topic_name, creating_title=creating_title,
                       creator=creator, opening_posted=opening_posted)


def save_thread_record(path: Path, request_id: object, thread_id: str,
                       topic_name: str = "", creating_title: str = "",
                       creator: str = "", title: dict | None = None,
                       open_attempt: bool | None = None,
                       opening_posted: bool | None = None) -> None:
    """Write one thread record atomically, preserving any prior unset field.

    ``creator`` is the provenance that authorises a later rename: ``firstmate``
    when this home created the thread, ``adopted`` when an existing thread was
    only reused for routing. It is kept once known, so a record never loses
    the evidence that a rename decision depends on.

    ``topic_name`` is the last title this home gave the thread, by creating
    or renaming it. ``creating_title`` is the title the creating reply
    supplied. ``title`` replaces the thread title reconciler's object whole:
    its inputs and bookkeeping, owned by ``thread_title``.

    A private state artifact beside the outbox, written with the same guards
    the shell publication helper enforces: a regular single-link file at mode
    0600, replaced atomically. Its basename is <slug>.thread.json, which the
    pending scan skips as a marker, avoiding payload validation for completed
    topics.

    Every writer holds ``_THREAD_RECORD_LOCK`` across its read-merge-write, so
    a delivery and a title update for the same record cannot lose one another.
    """
    with _THREAD_RECORD_LOCK:
        _merge_thread_record(path, request_id, thread_id, topic_name, creating_title,
                             creator, title, open_attempt, opening_posted)


def _merge_thread_record(path: Path, request_id: object, thread_id: str,
                         topic_name: str, creating_title: str, creator: str,
                         title: dict | None, open_attempt: bool | None,
                         opening_posted: bool | None) -> None:
    if path.is_symlink():
        raise RuntimeError("thread record is a symlink")
    try:
        prior = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        prior = {}
    if not isinstance(prior, dict):
        prior = {}
    prior_request = prior.get("request_id") or ""
    prior_name = prior.get("topic_name") or ""
    prior_creating = prior.get("creating_title") or ""
    prior_creator = prior.get("creator") or ("adopted" if prior.get("adopted") else "")
    record = {"request_id": request_id if request_id is not None else prior_request,
              "topic_thread_id": thread_id,
              "topic_name": topic_name or prior_name,
              "creating_title": creating_title or prior_creating}
    kept_creator = creator or (prior_creator if isinstance(prior_creator, str) else "")
    if kept_creator:
        record["creator"] = kept_creator
    kept_title = title if title is not None else prior.get("title")
    if isinstance(kept_title, dict) and kept_title:
        record["title"] = kept_title
    if (open_attempt if open_attempt is not None else prior.get("open_attempt")) is True:
        record["open_attempt"] = True
    if (opening_posted if opening_posted is not None else prior.get("opening_posted")) is True:
        record["opening_posted"] = True
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


def _thread_title():
    # Imported on use: thread_title imports this module.
    try:
        from . import thread_title
    except ImportError:
        import thread_title
    return thread_title


def _thread_autoname():
    try:
        from . import thread_autoname
    except ImportError:
        import thread_autoname
    return thread_autoname


def public_topic_name(
    payload: dict,
    name: str,
    home: Path | None = None,
    request_text: str = "",
    title: str = "",
) -> str:
    """Re-derive this request's thread name and check the stored one.

    The request text (plus Firstmate's title) goes through
    bin/fm-ext-topic.sh, and the stored name is accepted only when it equals
    that fresh derivation or a legacy label-plus-time name for the same
    message when no valid title takes precedence. Anything else falls back to
    the fresh name.
    """
    with _temp_text(request_text) as text_file, _temp_text(title) as title_file, \
            _temp_text(name) as stored_file:
        result = subprocess.run(
            [str(firstmate_root() / "bin" / "fm-ext-topic.sh"),
             "--text-file", text_file, "--origin", str(payload.get("origin") or "slash"),
             "--thread-id", str(payload.get("thread_id") or ""),
             "--channel-id", str(payload.get("channel_id") or ""),
             "--message-id", str(payload.get("message_id") or ""),
             "--title-file", title_file,
             "--validate-name", "--stored-file", stored_file],
            capture_output=True, text=True, check=False,
            env=_env_for(home or firstmate_home()),
        )
    return result.stdout.strip() if result.returncode == 0 else ""


def thread_name_for(payload: dict, home: Path) -> str:
    """Public-safe thread name for this request, or "" when it needs none.

    Firstmate's title on the creating payload wins; otherwise the name is
    re-derived from the request text the intake recorded, never trusted from
    the stored string alone. Anything unusable - no context, no recorded
    name, an already-threaded request - means no thread is created. A thread
    bin/fm-ext-open.sh opened is named by its context's origin, so its title
    is its only name even when the caller stands in as a message request.
    Once the thread exists, a later title never names it: the title
    reconciler owns its name.
    """
    if payload.get("origin") not in ("message", "open"):
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
    opened = context.get("origin") == "open"
    if payload.get("origin") == "open" and not opened:
        return ""
    if opened:
        payload = dict(payload, origin="open")
    name = context.get("topic") or ""
    request_text = context.get("request_text") or ""
    if not isinstance(name, str) or not name or not isinstance(request_text, str):
        return ""
    return public_topic_name(payload, name, home, request_text,
                             "" if load_request_topic(payload, home) else _title_for(payload))


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


def screened_title(text: object, home: Path) -> str:
    """The shared title screen's verdict on one candidate name, or "".

    ``bin/fm-ext-topic.sh --check-title`` owns the bounds and safety rules a
    creating title passes, and it judges a retitle and a model-proposed base
    too, so neither can put a name on a thread that a creation could not. An
    absent, unusable, or unscreened candidate reads as "".
    """
    if not isinstance(text, str) or not text:
        return ""
    with _temp_text(text) as title_file:
        result = subprocess.run(
            [str(firstmate_root() / "bin" / "fm-ext-topic.sh"),
             "--check-title", "--title-file", title_file],
            capture_output=True, text=True, check=False,
            env=_env_for(home),
        )
    return result.stdout.strip() if result.returncode == 0 else ""


def _bot_user_id(token: str | None = None) -> str:
    """This bot's own Discord user id, or "" when it cannot be read."""
    if token is None:
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
    return user_id


def _discord_thread(thread_id: str) -> dict:
    """Discord's current view of one thread, or {} when it cannot be read.

    Read-only and best effort: a missing token, an unusable id, a transport or
    HTTP failure, or a reply that is not an object all read as {}.
    """
    token = _bot_token()
    if not token or not _SNOWFLAKE.fullmatch(thread_id):
        return {}
    request = urllib.request.Request(
        f"{DISCORD_API_BASE}/channels/{thread_id}",
        headers={"Authorization": f"Bot {token}", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            data = json.loads(response.read().decode("utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def discord_thread_owner(thread_id: str) -> str:
    """The Discord user id that created a thread, or "" when unproved.

    An unreadable thread or a reply without an owner leaves ownership
    unproved, which a rename check reads as "not ours" and refuses to rename
    on.
    """
    owner = str(_discord_thread(thread_id).get("owner_id") or "")
    return owner if _SNOWFLAKE.fullmatch(owner) else ""


def discord_thread_name(thread_id: str) -> str:
    """The name Discord shows for a thread now, or "" when it cannot be read."""
    name = _discord_thread(thread_id).get("name")
    return name if isinstance(name, str) else ""


def title_thread_for(payload: dict, thread_id: str, home: Path) -> str:
    """The topic thread whose title this delivered generation may move, or "".

    Only a thread in the dedicated channel qualifies: the one a top-level
    message request or an opened thread created, or the thread an in-thread
    request of any origin arrived in, which resolves through that thread's
    own record. An adopted thread never takes inputs; the title reconciler
    applies the remaining eligibility rules.
    """
    if str(payload.get("channel_id") or "") != dedicated_channel(home):
        return ""
    thread_field = str(payload.get("thread_id") or "")
    if thread_field == str(payload.get("channel_id") or ""):
        if payload.get("origin") not in ("message", "open"):
            return ""
        recorded = load_request_topic(payload, home)
        if not thread_id or recorded.get("topic_thread_id") != thread_id:
            return ""
    else:
        recorded = load_thread_record_by_id(thread_field, home)
    return "" if not recorded or recorded.get("creator") == "adopted" else recorded["topic_thread_id"]


def queue_title_inputs(payload: dict, thread_id: str, ids: list, home: Path) -> None:
    """Hand one delivered reply to the title worker and return at once.

    Runs after the reply and its receipt are durable. It only queues: the
    judging check, Jev, the naming model, and every rename happen elsewhere,
    so nothing here can delay or fail a delivery.
    """
    try:
        target = title_thread_for(payload, thread_id, home)
        message_id = str(next((item for item in reversed(ids) if _SNOWFLAKE.fullmatch(str(item))), ""))
        if not target or not message_id:
            return
        state = payload.get("thread_state")
        retitle = payload.get("thread_retitle")
        _thread_autoname().after_post(home, target, {
            "message_id": message_id,
            "state": state if isinstance(state, str) else "",
            "retitle": retitle if isinstance(retitle, str) else "",
            "decision": isinstance(payload.get("decision"), dict),
        })
    except Exception as err:
        print(f"fm-ext-poster: title inputs skipped: {err}", file=sys.stderr)


def decision_threads(home: Path, thread_id: str = "") -> dict[str, dict] | None:
    """Read the thread summaries owned by ``bin/fm-ext-decision.sh threads``."""
    args = [str(_decision_cli()), "threads"] + (["--thread", thread_id] if thread_id else [])
    try:
        result = subprocess.run(args, check=False, env=_env_for(home),
                                capture_output=True, text=True)
    except (OSError, ValueError):
        return None
    if result.returncode != 0:
        return None
    threads = {}
    for line in result.stdout.splitlines():
        try:
            item = json.loads(line)
            threads[str(item["thread_id"])] = {"open": int(item["open"]), "closed": int(item["closed"]),
                                               "last_posted_at": _epoch(item["last_posted_at"]),
                                               "last_closed_at": _epoch(item["last_closed_at"]),
                                               "keys": tuple(item["keys"])}
        except (ValueError, KeyError, TypeError):
            return None
    return threads


def sweep_thread_titles(home: Path | None = None) -> list[str]:
    """The periodic pass: refresh every thread's decision input from the ledger.

    It only updates inputs; ``thread_title.run_due`` writes any title change.
    """
    home = home or firstmate_home()
    summaries = decision_threads(home)
    if summaries is None:
        return []
    return _thread_title().sweep_decisions(home, summaries)


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
    return _post_thread(f"{DISCORD_API_BASE}/channels/{channel}/messages/{message}/threads",
                        {"name": name, "auto_archive_duration": 1440}, token)


# Discord's public-thread channel type, for a thread started without a message.
_PUBLIC_THREAD = 11
# Discord refusals that mean the bot lacks a permission in the channel.
_MISSING_ACCESS = {50001, 50013}


def discord_open_thread(payload: dict, name: str) -> dict:
    """Start a public thread with no parent message in the dedicated channel.

    This is how a thread bin/fm-ext-open.sh asked for comes into being. It
    needs the same Create Public Threads permission as a thread on a request
    message; a refusal for a missing permission says so in its reason.
    """
    name = public_topic_name(payload, name, None, "", _title_for(payload))
    if not name:
        raise DiscordSendError("permanent", "opened thread has no valid title")
    token = _bot_token()
    if not token:
        raise DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    channel = str(payload.get("channel_id") or "")
    if not _SNOWFLAKE.fullmatch(channel) or str(payload.get("thread_id") or "") != channel:
        raise DiscordSendError("permanent", "opened thread parent is not the request channel")
    try:
        return _post_thread(f"{DISCORD_API_BASE}/channels/{channel}/threads",
                            {"name": name, "type": _PUBLIC_THREAD, "auto_archive_duration": 1440}, token)
    except DiscordSendError as err:
        if err.http_code == 403 or err.api_error.get("code") in _MISSING_ACCESS:
            raise DiscordSendError(
                err.outcome,
                f"{err}: the bot lacks permission to open threads in the dedicated channel "
                "(needs View Channel, Create Public Threads, and Send Messages in Threads)",
                err.http_code, err.api_error) from err
        raise


def _post_thread(url: str, body_fields: dict, token: str) -> dict:
    """POST one thread-create request and return its thread id."""
    body = json.dumps(body_fields).encode("utf-8")
    request = urllib.request.Request(
        url,
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
    # Provenance decides whether the title reconciler may rename this thread:
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
            creating_title = _thread_title().split_marker(name)[1]
            if public_topic_name(payload, creating_title, home,
                                 _request_text_for(payload, home), creating_title) != creating_title:
                return thread_id
        except Exception:
            return thread_id
        creator_provenance = "adopted"
        receipt = {"thread_id": thread_id}
    except Exception:
        return ""
    thread_id = str((receipt or {}).get("thread_id") or "")
    if not _SNOWFLAKE.fullmatch(thread_id):
        return ""
    try:
        save_request_thread(payload, thread_id, home, topic_name=name,
                            creating_title=creating_title, creator=creator_provenance)
    except Exception:
        return thread_id
    return thread_id


def ensure_open_thread(
    payload: dict,
    progress: dict,
    home: Path,
    create_thread: ThreadFn | None = None,
) -> str:
    """Return the opened topic's shared destination or create its initial thread."""
    initial = dict(payload, kind="answer", generation=1)
    path = request_progress_path(payload, home)
    try:
        shared = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        shared = {}
    if not isinstance(shared, dict):
        raise DiscordSendError("permanent", "opened thread record is invalid")
    if payload.get("kind") != "answer" or payload.get("generation") != 1:
        directory = progress_path(initial, home).parent
        receipt = directory / f"{payload['slug']}.answer.1.receipt.json"
        failed = directory / f"{payload['slug']}.answer.1.failed.json"
        if receipt.is_symlink() or not receipt.is_file():
            if failed.is_file() and not failed.is_symlink():
                raise DiscordSendError("permanent", "the opening answer failed; cannot post later updates")
            if shared.get("opening_posted") is not True:
                raise DiscordSendError("transient", "waiting for the opening answer to post")
    initial_progress = load_progress(initial, home) or {}
    recorded = (str(progress.get("topic_thread_id") or "")
                or load_request_thread(payload, home)
                or str(initial_progress.get("topic_thread_id") or ""))
    if recorded:
        return recorded
    if shared.get("open_attempt") or progress.get("open_attempt") or initial_progress.get("open_attempt"):
        raise DiscordSendError("permanent", "an earlier attempt to open this thread has an unknown "
                               "outcome; refusing to open a second thread")
    if payload.get("kind") != "answer" or payload.get("generation") != 1:
        raise DiscordSendError("transient", "the opening answer has no recorded thread")
    channel = str(payload.get("channel_id") or "")
    if str(payload.get("thread_id") or "") != channel or channel != dedicated_channel(home):
        raise DiscordSendError("permanent", "an opened thread may only start in the dedicated channel")
    name = thread_name_for(payload, home)
    if not name:
        raise DiscordSendError("permanent", "opened thread has no valid title")
    save_thread_record(path, payload.get("request_id"), "", open_attempt=True)
    progress["open_attempt"] = True
    write_progress(payload, progress, home)
    try:
        receipt = (create_thread or discord_open_thread)(payload, name)
    except Exception as err:
        if classify_send_failure(err) != "ambiguous":
            save_thread_record(path, payload.get("request_id"), "", open_attempt=False)
            progress["open_attempt"] = False
            write_progress(payload, progress, home)
        raise
    thread_id = str((receipt or {}).get("thread_id") or "")
    if not _SNOWFLAKE.fullmatch(thread_id):
        raise DiscordSendError("ambiguous", "discord thread open returned no thread id")
    save_request_thread(payload, thread_id, home, topic_name=name,
                        creating_title=_title_for(payload), creator="firstmate")
    return thread_id


def discord_send(payload: dict) -> dict:
    """Post one outbox payload to Discord REST. No Discord library.

    A chunk carrying ``files`` (loaded by ``load_media_uploads``) posts as one
    multipart message: the text and buttons in ``payload_json`` and each file
    as ``files[n]`` under its generic staged name.
    """
    token = _bot_token()
    if not token:
        raise DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    channel = payload["thread_id"] or payload["channel_id"]
    message = {"content": payload["text"]}
    if payload.get("nonce"):
        message.update(nonce=payload["nonce"], enforce_nonce=True)
    decision = payload.get("decision")
    last_chunk = int(payload.get("chunk_index") or 0) + 1 >= int(payload.get("chunk_count") or 1)
    buttons = (isinstance(decision, dict) and bool(decision.get("options"))
               and last_chunk and decisions.buttons_ready(_bot_user_id(token)))
    if buttons:
        message["components"] = decisions.components_for(decision)
    files = payload.get("files") or []
    if files:
        body, content_type = _multipart_body(message, files)
        timeout = MEDIA_UPLOAD_TIMEOUT_SECS
    else:
        body, content_type = json.dumps(message).encode("utf-8"), "application/json"
        timeout = 15
    request = urllib.request.Request(
        f"{DISCORD_API_BASE}/channels/{channel}/messages",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": content_type,
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
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
    receipt = {
        "ok": True,
        "discord_message_id": str(data.get("id") or ""),
        "channel_id": str(data.get("channel_id") or channel),
        "buttons": bool(buttons),
    }
    if files:
        attached = data.get("attachments")
        receipt["attachments"] = len(attached) if isinstance(attached, list) else len(files)
    return receipt


def discord_edit(channel_id: str, message_id: str, content: str | None, components: list) -> None:
    """Edit buttons and optional text over REST; None preserves text. Mentions are
    never parsed, so a name in the outcome line cannot ping anyone. Raises
    DiscordSendError on any failure.
    """
    token = _bot_token()
    if not token:
        raise DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    if not (_SNOWFLAKE.fullmatch(channel_id or "") and _SNOWFLAKE.fullmatch(message_id or "")):
        raise DiscordSendError("permanent", "edit target is not a Discord message id")
    body = {"components": components, "allowed_mentions": {"parse": []}}
    if content is not None:
        body["content"] = content
    body = json.dumps(body).encode("utf-8")
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
    edit: Callable[[str, str, str | None, list], None] | None = None,
) -> list[str]:
    """Reconcile decision displays through the CLI's content and receipt plan.
    A null content preserves legacy message text.
    ``full`` also settles posts whose decision closed or was replaced, which
    reads Firstmate's ledgers, so the watcher
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
            components = decisions.components_for(
                item,
                disabled=True,
                selected_option_id=item.get("selected_option_id"),
            )
            (edit or discord_edit)(item["channel_id"], item["message_id"], item["content"], components)
        except DiscordSendError as err:
            if err.outcome != "permanent":
                continue
        except Exception:
            continue
        with _temp_text(item["receipt"]) as content_file:
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


def firstmate_posts(home: Path) -> dict[str, dict]:
    outbox = state_dir(home) / "ext-outbox"
    posts = {}
    if outbox.is_symlink() or not outbox.is_dir():
        return posts
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
        if isinstance(posted, list):
            request_id = data.get("request_id")
            for message_id in posted:
                if _SNOWFLAKE.fullmatch(str(message_id or "")):
                    posts.setdefault(str(message_id), {"request_id": request_id if isinstance(request_id, str) else ""})
    return posts


def firstmate_post_for(message_id: str, home: Path | None = None) -> dict | None:
    """Return {"request_id": ...} when Firstmate's outbox posted message_id.

    Chunk progress remembers every posted id during its retention window.
    request_id is empty for legacy progress without it. None means this home
    no longer has provenance for the message.
    """
    if not _SNOWFLAKE.fullmatch(str(message_id or "")):
        return None
    return firstmate_posts(home or firstmate_home()).get(str(message_id))


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
    token = _bot_token()
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


def recover_pending_message(payload: dict, pending: dict) -> dict | None:
    token = _bot_token()
    if not token:
        raise RuntimeError("missing bot token")
    channel = payload.get("thread_id") or payload.get("channel_id")
    headers = {"Authorization": f"Bot {token}", "User-Agent": USER_AGENT}
    def get(path):
        request = urllib.request.Request(f"{DISCORD_API_BASE}{path}", headers=headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)
    bot = get("/users/@me")
    messages = get(f"/channels/{channel}/messages?limit=100")
    if not isinstance(messages, list) or not bot.get("id"):
        raise RuntimeError("invalid message lookup")
    for message in messages:
        if str((message.get("author") or {}).get("id")) != str(bot["id"]):
            continue
        matches = str(message.get("nonce") or "") == pending["nonce"]
        if not message.get("nonce"):
            created = (int(message["id"]) >> 22) / 1000 + 1420070400
            matches = (created >= int(pending["attempted_at"] * 1000) / 1000
                       and message.get("content") == pending["text"]
                       and [item.get("filename") for item in message.get("attachments") or []] == pending["names"])
        if matches and _SNOWFLAKE.fullmatch(str(message.get("id") or "")):
            return {"discord_message_id": str(message["id"]),
                    "buttons": bool(message.get("components"))}
    return None


def deliver_one(
    path: Path,
    send: SendFn | None = None,
    home: Path | None = None,
    react: ReactFn | None = None,
    create_thread: ThreadFn | None = None,
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
    # The delivery clock: queued_at comes from the payload's emit time and
    # picked_at from here, so the journal line and receipt can show how long a
    # reply waited for a poster rather than only when Discord accepted it.
    # A payload without a numeric emit time records 0 and logs wait=unknown.
    queued_at = _epoch(payload.get("recorded_at"))
    picked_at = time.time()
    status = begin_delivery(payload, home=home)
    if status == "recovery-exhausted":
        react_to_request(payload, REACT_FAILED, react)
    if status != "claimed":
        return status
    sender = send or discord_send
    stored = load_progress(payload, home)
    decision = isinstance(payload.get("decision"), dict)
    media = payload.get("media") if isinstance(payload.get("media"), dict) else None
    try:
        if stored and "texts" in stored:
            split = {"texts": stored["texts"], "limit": stored["limit"], "cap": stored["cap"]}
        else:
            limit = stored.get("limit") if stored else None
            cap = stored.get("cap") if stored else None
            if decision:
                split = split_decision_reply(
                    payload,
                    home=home,
                    limit=limit,
                    cap=cap,
                    legacy=bool(stored),
                )
            else:
                split = split_reply(
                    payload.get("text") or "",
                    home=home,
                    limit=limit,
                    cap=cap,
                    legacy=bool(stored),
                    reserve=MEDIA_NOTE_RESERVE if media else 0,
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
        post_decision = dict(payload["decision"])
        if stored and ("texts" not in stored or not isinstance(
            (stored.get("decision") or {}).get("sections"), dict
        )):
            post_decision.pop("sections", None)
        progress["decision"] = post_decision
    progress["texts"] = chunks
    if media and not isinstance(progress.get("media"), dict):
        # Upload state for the post's last message: pending, posted, or dropped.
        progress["media"] = {"state": "pending", "attempts": 0, "posted": [], "dropped": []}
    if int(progress.get("total") or 0) != len(chunks):
        release_inflight(payload, home=home)
        return "mid-delivery"
    if payload.get("origin") == "open":
        try:
            thread_id = ensure_open_thread(payload, progress, home, create_thread)
        except Exception as err:
            outcome = classify_send_failure(err)
            if outcome == "transient":
                abort_status = abort_delivery(payload, home=home)
                return abort_status if abort_status == "already-receipted" else "failed"
            if outcome == "permanent":
                fail_status = record_failed(payload, failure_reason(err), home=home)
                return fail_status if fail_status == "already-receipted" else "terminal-failed"
            return "mid-delivery"
    else:
        thread_id = ensure_topic_thread(payload, progress, home, create_thread)
    progress["topic_thread_id"] = thread_id
    write_progress(payload, progress, home)
    start = int(progress.get("posted_count") or 0)
    ids = list(progress.get("discord_message_ids") or [])
    send_payload = dict(payload)
    if thread_id:
        send_payload["thread_id"] = thread_id
    for index in range(start, len(chunks)):
        last = index + 1 == len(chunks)
        media_state = progress.get("media") if media and last else None
        uploads: list[dict] = []
        recovered = None
        pending = progress.get("pending_send")
        if pending:
            progress["inflight"] = index
            write_progress(payload, progress, home)
            try:
                recovered = recover_pending_message(send_payload, pending)
            except Exception:
                return "mid-delivery"
            if recovered is None:
                return "mid-delivery"
            text = pending["text"]
            if media_state is not None and pending["names"]:
                media_state["state"] = "posted"
                media_state["posted"] = pending["names"]
        while True:
            if recovered:
                receipt = recovered
                break
            if media_state is not None and media_state.get("state") == "pending":
                if int(media_state.get("attempts") or 0) >= MEDIA_UPLOAD_ATTEMPTS:
                    # A resumed ambiguous upload already used its one retry.
                    media_state["state"] = "dropped"
                    media_state["dropped"] = [str(entry.get("name") or "") for entry in media.get("files") or []
                                              if isinstance(entry, dict)]
                else:
                    uploads, unverified = load_media_uploads(path, payload, home)
                    media_state["dropped"] = unverified
                    if not uploads:
                        media_state["state"] = "dropped"
            attaching = bool(uploads) and media_state is not None and media_state.get("state") == "pending"
            text = chunks[index]
            if media_state is not None and (media_state.get("state") == "dropped" or media_state.get("dropped")) \
                    and not text.endswith(MEDIA_FAILED_NOTE):
                text = f"{text}\n\n{MEDIA_FAILED_NOTE}"
            chunk = _chunk_payload(send_payload, text, index, len(chunks))
            if attaching:
                chunk["files"] = uploads
                media_state["attempts"] = int(media_state.get("attempts") or 0) + 1
            chunk["nonce"] = hashlib.sha256(
                f"{payload['slug']}:{payload['kind']}:{payload['generation']}:{index}".encode()
            ).hexdigest()[:25]
            progress["pending_send"] = {
                "nonce": chunk["nonce"], "text": text, "names": [item["name"] for item in uploads] if attaching else [],
                "attempted_at": time.time(),
            }
            progress["inflight"] = index
            write_progress(payload, progress, home)
            try:
                receipt = sender(chunk)
                if not isinstance(receipt, dict) or not _message_id(receipt):
                    raise DiscordSendError("ambiguous", "discord post returned no message id")
            except Exception as err:
                outcome = classify_send_failure(err)
                refused = getattr(err, "http_code", None) is not None or isinstance(err, urllib.error.HTTPError)
                if outcome != "ambiguous":
                    progress.pop("pending_send", None)
                if attaching and refused and outcome in ("transient", "permanent"):
                    # Discord answered with an HTTP error, so this try created no
                    # message: retry the upload once, then post the text alone.
                    progress["inflight"] = None
                    if int(media_state.get("attempts") or 0) >= MEDIA_UPLOAD_ATTEMPTS:
                        media_state["state"] = "dropped"
                        media_state["dropped"] = [item["name"] for item in uploads] + list(media_state.get("dropped") or [])
                        media_state["reason"] = failure_reason(err)
                    write_progress(payload, progress, home)
                    if media_state.get("state") == "pending" and MEDIA_RETRY_DELAY_SECS > 0:
                        time.sleep(MEDIA_RETRY_DELAY_SECS)
                    continue
                if outcome == "transient":
                    progress["inflight"] = None
                    write_progress(payload, progress, home)
                    # Abort deletes progress, which would reset the media
                    # upload count; once an upload was tried, keep progress and
                    # resume like a later-chunk failure so the one retry holds.
                    uploads_tried = int((progress.get("media") or {}).get("attempts") or 0) > 0
                    if int(progress.get("posted_count") or 0) == 0 and not uploads_tried:
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
            if attaching:
                media_state["state"] = "posted"
                media_state["posted"] = [item["name"] for item in uploads]
            break
        if not isinstance(receipt, dict):
            receipt = {}
        # The stored plan keeps what this message actually showed, note included.
        chunks[index] = text
        ids.append(_message_id(receipt))
        progress["discord_message_ids"] = ids
        progress["posted_count"] = index + 1
        progress.pop("pending_send", None)
        progress["inflight"] = None
        if "decision" in progress and index + 1 == len(chunks):
            progress["buttons"] = bool(receipt.get("buttons"))
            progress["posted_at"] = time.time()
        write_progress(payload, progress, home)
    posted_at = time.time()
    receipt_record = {
        "ok": True,
        "discord_message_id": ids[0] if ids else "",
        "discord_message_ids": ids,
        "chunks": len(chunks),
        "channel_id": str(send_payload.get("thread_id") or send_payload.get("channel_id") or ""),
        "thread_id": str(send_payload.get("thread_id") or ""),
        "queued_at": queued_at,
        "picked_at": picked_at,
    }
    attachments = ""
    media_state = progress.get("media") if media else None
    if isinstance(media_state, dict):
        posted_names = list(media_state.get("posted") or [])
        dropped_names = list(media_state.get("dropped") or [])
        receipt_record["attachments"] = [
            {"name": entry.get("name"), "media": entry.get("media"), "bytes": entry.get("bytes")}
            for entry in media.get("files") or []
            if isinstance(entry, dict) and entry.get("name") in posted_names
        ]
        receipt_record["attachments_dropped"] = dropped_names
        receipt_record["media_upload_attempts"] = int(media_state.get("attempts") or 0)
        receipt_record["media_note"] = media_state.get("state") == "dropped" or bool(dropped_names)
        attachments = f" attachments={len(posted_names)}"
    record_receipt(payload, receipt_record, home=home)
    waited = f"{max(0.0, picked_at - queued_at):.1f}s" if queued_at > 0 else "unknown"
    print(f"fm-ext-poster: delivered {str(payload.get('slug') or '')[:12]} "
          f"{payload.get('kind')}.{payload.get('generation')} queued={queued_at:.3f} "
          f"picked={picked_at:.3f} posted={posted_at:.3f} "
          f"wait={waited} post={max(0.0, posted_at - picked_at):.1f}s chunks={len(chunks)}{attachments}",
          file=sys.stderr)
    if payload.get("origin") == "open" and payload.get("kind") == "answer" and payload.get("generation") == 1:
        save_request_thread(payload, thread_id, home, opening_posted=True)
    if payload.get("kind") in ("answer", "final"):
        react_to_request(payload, REACT_DONE, react)
    # The title is not tied to this generation's destination: an in-thread
    # request posts where it arrived and its thread still gets the inputs, so
    # the hand-off always runs and decides inside what it may touch.
    queue_title_inputs(payload, thread_id, ids, home)
    return "sent"


def drain_outbox(
    send: SendFn | None = None,
    home: Path | None = None,
    react: ReactFn | None = None,
    create_thread: ThreadFn | None = None,
) -> list[str]:
    results = []
    for path in list_pending(home=home):
        try:
            results.append(deliver_one(path, send=send, home=home, react=react,
                                       create_thread=create_thread))
        except DiscordSendError:
            results.append("failed")
    return results


def _run_step(label: str, step) -> None:
    """Run one watcher step, logging a journal line when it overruns.

    A step's failure is swallowed here, exactly as the single loop swallowed
    it: one bad sweep must not end the watcher.
    """
    started = time.monotonic()
    try:
        step()
    except Exception:
        pass
    finally:
        elapsed = time.monotonic() - started
        if elapsed >= SLOW_STEP_SECS:
            print(f"fm-ext-poster: slow step {label}={elapsed:.1f}s", file=sys.stderr)


def outbox_delivery_loop(interval: float) -> None:
    """Post queued payloads every ``interval`` seconds.

    This runs separately from reconciliation so delivery does not wait for a
    sweep to finish; local record updates still share the thread-record lock.
    """
    while True:
        _run_step("ensure-click-route", decisions.ensure_click_route)
        _run_step("drain", drain_outbox)
        time.sleep(interval)


def outbox_reconcile_loop(interval: float) -> None:
    """Sweep decision posts every ``interval`` seconds.

    Clicks settle posts locally, so their edits follow within a cycle; posts
    closed on another channel need a ledger read and are swept on the slower
    cadence, followed by the pass that refreshes each topic thread's decision
    input for the title reconciler.
    """
    last_full = 0.0
    while True:
        full = time.monotonic() - last_full >= DECISION_SWEEP_SECS
        if full:
            last_full = time.monotonic()
        _run_step("posts", lambda: _reconcile_posts_step(full))
        if full:
            _run_step("threads", sweep_thread_titles)
        time.sleep(interval)


def thread_title_loop(interval: float) -> None:
    """Run the title reconciler for every due thread every ``interval`` seconds.

    This is the only thread that writes topic-thread titles.
    """
    while True:
        _run_step("titles", lambda: _thread_title().run_due())
        time.sleep(interval)


def _reconcile_posts_step(full: bool) -> None:
    if full or _unshown_settled_posts():
        reconcile_decision_posts(full=full)


def start_outbox_watcher(interval: float | None = None) -> None:
    global _WATCHER_STARTED
    with _WATCHER_LOCK:
        if _WATCHER_STARTED:
            return
        _WATCHER_STARTED = True

    wait = interval
    if wait is None:
        wait = float(os.environ.get("FM_EXT_OUTBOX_POLL_SECS", "2"))

    threading.Thread(target=outbox_delivery_loop, args=(wait,),
                     name="fm-ext-outbox-delivery", daemon=True).start()
    threading.Thread(target=outbox_reconcile_loop, args=(wait,),
                     name="fm-ext-outbox-reconcile", daemon=True).start()
    threading.Thread(target=thread_title_loop, args=(wait,),
                     name="fm-ext-thread-title", daemon=True).start()
    _thread_autoname().start_catch_up()
