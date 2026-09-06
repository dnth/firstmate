"""Local outbox poster for the Communication Officer gateway plugin.

Posts pending ``state/ext-outbox`` payloads to the Discord destination stored
in each payload and records receipts through ``bin/fm-ext-outbox.sh``.
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
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable

try:
    from .intake import firstmate_home, firstmate_root
except ImportError:  # loaded from sys.path in hermetic tests
    from intake import firstmate_home, firstmate_root

SendFn = Callable[[dict], dict]

_WATCHER_STARTED = False
_WATCHER_LOCK = threading.Lock()
_TRANSIENT_HTTP = {429, 500, 502, 503, 504}


class DiscordSendError(Exception):
    """Classified Discord send outcome for outbox delivery."""

    def __init__(self, outcome: str, message: str = "", http_code: int | None = None):
        super().__init__(message or outcome)
        self.outcome = outcome
        self.http_code = http_code


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
    def __init__(self, body: dict):
        self.body = body
        self.path = ""

    def __enter__(self) -> str:
        fd, self.path = _mktemp()
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(self.body))
        return self.path

    def __exit__(self, *args) -> None:
        if self.path:
            try:
                os.unlink(self.path)
            except OSError:
                pass


def _mktemp() -> tuple[int, str]:
    import tempfile

    return tempfile.mkstemp(prefix="fm-ext-receipt.")


def discord_send(payload: dict) -> dict:
    """Post one outbox payload to Discord REST. No Discord library."""
    token = os.environ.get("DISCORD_BOT_TOKEN") or os.environ.get("HERMES_DISCORD_TOKEN")
    if not token:
        raise DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    channel = payload["thread_id"] or payload["channel_id"]
    body = json.dumps({"content": payload["text"]}).encode("utf-8")
    request = urllib.request.Request(
        f"https://discord.com/api/v10/channels/{channel}/messages",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bot {token}",
            "Content-Type": "application/json",
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
    }


def deliver_one(path: Path, send: SendFn | None = None, home: Path | None = None) -> str:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        # The generation reached a terminal outcome and its payload was retired
        # so later polls stop re-scanning it. A sibling poster can retire it
        # between list_pending and here, so this is an ordinary outcome rather
        # than an error that would abort the whole drain pass.
        return "retired"
    home = home or firstmate_home()
    status = begin_delivery(payload, home=home)
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
        "total": len(chunks),
        "posted_count": 0,
        "inflight": None,
        "discord_message_ids": [],
        "limit": split["limit"],
        "cap": split["cap"],
    }
    if int(progress.get("total") or 0) != len(chunks):
        release_inflight(payload, home=home)
        return "mid-delivery"
    write_progress(payload, progress, home)
    start = int(progress.get("posted_count") or 0)
    ids = list(progress.get("discord_message_ids") or [])
    for index in range(start, len(chunks)):
        progress["inflight"] = index
        write_progress(payload, progress, home)
        try:
            receipt = sender(_chunk_payload(payload, chunks[index], index, len(chunks)))
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
                return "terminal-failed"
            return "mid-delivery"
        if not isinstance(receipt, dict):
            receipt = {}
        ids.append(_message_id(receipt))
        progress["discord_message_ids"] = ids
        progress["posted_count"] = index + 1
        progress["inflight"] = None
        write_progress(payload, progress, home)
    record_receipt(
        payload,
        {
            "ok": True,
            "discord_message_id": ids[0] if ids else "",
            "discord_message_ids": ids,
            "chunks": len(chunks),
            "channel_id": str(payload.get("thread_id") or payload.get("channel_id") or ""),
        },
        home=home,
    )
    return "sent"


def drain_outbox(send: SendFn | None = None, home: Path | None = None) -> list[str]:
    results = []
    for path in list_pending(home=home):
        results.append(deliver_one(path, send=send, home=home))
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
        while True:
            try:
                drain_outbox()
            except Exception:
                pass
            time.sleep(wait)

    thread = threading.Thread(target=_loop, name="fm-ext-outbox", daemon=True)
    thread.start()
