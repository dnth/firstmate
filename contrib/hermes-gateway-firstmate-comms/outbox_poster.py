"""Local outbox poster for the Communication Officer gateway plugin.

Posts pending ``state/ext-outbox`` payloads to the Discord destination stored
in each payload and records receipts through ``bin/fm-ext-outbox.sh``.
Unsent payloads (no posting marker, no receipt, no terminal failed marker)
are retried after restart.
A transient definite send failure (HTTP 429 or 5xx) before a successful
response deletes the posting marker so that generation can retry.
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
    raise RuntimeError(result.stderr.strip() or "begin failed")


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
    payload = json.loads(path.read_text(encoding="utf-8"))
    status = begin_delivery(payload, home=home)
    if status != "claimed":
        return status
    sender = send or discord_send
    try:
        receipt = sender(payload)
    except Exception as err:
        outcome = classify_send_failure(err)
        if outcome == "transient":
            abort_status = abort_delivery(payload, home=home)
            if abort_status == "already-receipted":
                return abort_status
            return "failed"
        if outcome == "permanent":
            fail_status = record_failed(payload, failure_reason(err), home=home)
            if fail_status == "already-receipted":
                return fail_status
            return "terminal-failed"
        return "mid-delivery"
    receipt.setdefault("ok", True)
    record_receipt(payload, receipt, home=home)
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
