"""Local outbox poster for the Communication Officer gateway plugin.

Posts pending ``state/ext-outbox`` payloads to the Discord destination stored
in each payload and records receipts through ``bin/fm-ext-outbox.sh``.
Unsent payloads (no posting marker, no receipt) are retried after restart.
A posting marker without a receipt is refused so a crash mid-send cannot
double-post.
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
    raise RuntimeError(result.stderr.strip() or "begin failed")


def record_receipt(payload: dict, receipt: dict, home: Path | None = None) -> str:
    home = home or firstmate_home()
    with _temp_receipt(receipt) as receipt_path:
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


class _temp_receipt:
    def __init__(self, receipt: dict):
        self.receipt = receipt
        self.path = ""

    def __enter__(self) -> str:
        fd, self.path = _mktemp()
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(self.receipt))
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
        raise RuntimeError("missing DISCORD_BOT_TOKEN")
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
            data = json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as err:
        raise RuntimeError(f"discord HTTP {err.code}") from err
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
    receipt = sender(payload)
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
