"""After-post judging for Firstmate's topic threads, as a durable scan.

docs/configuration.md, "Thread title reconciler", owns the contract. This
module hands verdicts to ``thread_title``, which alone writes title updates.
``judge_scan`` selects the newest Discord-accepted Firstmate message from
chunk progress, so a later failed chunk cannot hide it. Only a usable
verdict satisfies the scan checkpoint.

The one-time catch-up is the first scan: ``state/ext-autoname/catch-up.json``
fixes, before the first model call, the newest message id at that moment
(the horizon) and the ten threads Firstmate posted in most recently. Older
threads are judged only once they get a post newer than the horizon.

``after_post`` is all the delivery path calls: it marks the thread due and
wakes a background worker, so the key check, Jev, and the naming model never
delay a reply. Every failure leaves the title as it is.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

try:
    from . import outbox_poster as poster
    from . import thread_context
    from . import thread_title
    from .intake import allowlist_path
    from .tool_path import firstmate_env
except ImportError:  # loaded from sys.path in hermetic tests
    import outbox_poster as poster
    import thread_context
    import thread_title
    from intake import allowlist_path
    from tool_path import firstmate_env

# Catch-up judges only this many of the threads Firstmate posted in most
# recently.
CATCH_UP_LIMIT = 10
NEWEST_REPLY_MAX_CHARS = 47_500
TEXT_BUDGET_CHARS = 8000
MESSAGE_MAX_CHARS = 2000
MESSAGE_LIMIT = 40

_LOCK = threading.Lock()
_PENDING: set[tuple[Path, str]] = set()
_WAITING: set[tuple[Path, str]] = set()
_RUNNING: set[Path] = set()
_SCAN_LOCK = threading.Lock()


def _log(message: str) -> None:
    print(f"fm-ext-autoname: {message}", file=sys.stderr)


def _tool(name: str) -> str:
    return str(poster.firstmate_root() / "bin" / name)


def judging_state(home: Path) -> str:
    """The one key check: on, off, inactive, or unknown when the check fails."""
    try:
        result = subprocess.run([_tool("fm-ext-thread-judge.sh"), "--check"],
                                capture_output=True, text=True, check=False, timeout=30,
                                env=firstmate_env(home, poster.firstmate_root(), jev=True))
    except (OSError, subprocess.SubprocessError):
        return "unknown"
    word = result.stdout.strip()
    return word if result.returncode == 0 and word in ("on", "off", "inactive", "unknown") else "unknown"


# --- thread text -----------------------------------------------------------------

def _captains(record: dict, home: Path) -> set[str]:
    request = poster._creating_request(record)
    prefix = f"{request.get('guild_id')}:{request.get('channel_id')}:"
    path = allowlist_path(home)
    if path.is_symlink():
        return set()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return set()
    return {line.strip()[len(prefix):] for line in lines
            if line.strip().startswith(prefix)
            and poster._SNOWFLAKE.fullmatch(line.strip()[len(prefix):])}


class UnjudgeableReply(Exception):
    pass


def _bounded_history(candidates: dict[int, dict]) -> dict[int, dict]:
    kept = {}
    budget = TEXT_BUDGET_CHARS
    for key in sorted(candidates, reverse=True):
        text = candidates[key]["text"].strip()
        if len(text) > MESSAGE_MAX_CHARS:
            text = text[:MESSAGE_MAX_CHARS - 1].rstrip() + "…"
        if len(kept) >= MESSAGE_LIMIT or len(text) > budget:
            break
        kept[key] = dict(candidates[key], text=text)
        budget -= len(text)
    return kept


def thread_messages(record: dict, home: Path, post: dict) -> tuple[list[dict], list[dict]]:
    """The judge and namer histories through the selected message, oldest first."""
    thread_id = record["topic_thread_id"]
    through = post["message_id"]
    raw = thread_title.discord_read_messages(home, thread_id, through, MESSAGE_LIMIT)
    posts = poster.firstmate_posts(home)
    captains = _captains(record, home)

    def read(item):
        entry = thread_context._entry(item, "", "", posts, "")
        if entry is None:
            return None
        role = "firstmate" if entry["role"] == "firstmate" else (
            "captain" if entry["author_id"] in captains else "participant")
        return {"role": role, "text": entry["text"]}

    recent = {}
    for item in raw:
        if isinstance(item, dict) and 0 < (key := thread_title._id(item.get("id"))) <= through:
            message = read(item)
            if message:
                recent[key] = message

    newest = {}
    total = 0
    for key in post["message_ids"]:
        message = recent.get(key)
        if message is None:
            try:
                message = read(thread_title.discord_read_message(home, thread_id, str(key)))
            except poster.DiscordSendError as err:
                if err.http_code == 404:
                    raise UnjudgeableReply("incomplete reply, chunk deleted") from err
                raise
        if message is None:
            raise RuntimeError("accepted reply chunk missing from judge history")
        newest[key] = message
        total += len(message["text"])
    if total > NEWEST_REPLY_MAX_CHARS:
        raise UnjudgeableReply("reply too long to judge")

    naming = _bounded_history(recent)
    judging = _bounded_history({key: message for key, message in recent.items() if key not in newest})
    judging.update(newest)
    aliases = {}
    for key in sorted(judging, reverse=True):
        message = judging[key]
        if message["role"] == "firstmate":
            reply = posts[str(key)]["reply"]
            judging[key] = dict(message, reply=aliases.setdefault(reply, len(aliases) + 1))
    return [judging[key] for key in sorted(judging)], [naming[key] for key in sorted(naming)]


# --- the two model calls -----------------------------------------------------------

def _run_tool(tool: str, state: dict, home: Path, timeout: float, jev: bool) -> subprocess.CompletedProcess:
    fd, state_file = tempfile.mkstemp(prefix="fm-ext-autoname.", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle)
        return subprocess.run([_tool(tool), "--state-file", state_file],
                              capture_output=True, text=True, check=False, timeout=timeout,
                              env=firstmate_env(home, poster.firstmate_root(), jev=jev))
    finally:
        try:
            os.unlink(state_file)
        except OSError:
            pass


def judge(state: dict, home: Path) -> dict:
    """Jev's {status, confidence, topic_fits} for one thread; raises on any failure."""
    result = _run_tool("fm-ext-thread-judge.sh", state, home, timeout=30, jev=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"judge exited {result.returncode}")
    verdict = json.loads(result.stdout)
    confidence = verdict.get("confidence")
    if (verdict.get("status") not in ("open-question", "running", "done", "blocked")
            or not isinstance(verdict.get("topic_fits"), bool)
            or not isinstance(confidence, (int, float)) or isinstance(confidence, bool)
            or not 0 <= confidence <= 1):
        raise RuntimeError("judge returned an unusable verdict")
    return verdict


def propose_name(state: dict, home: Path) -> str:
    """A screened "<Project> · <topic>" base name; raises on any failure."""
    result = _run_tool("fm-ext-thread-name.sh", state, home, timeout=180, jev=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"namer exited {result.returncode}")
    name = result.stdout.strip()
    if not name or "\n" in name:
        raise RuntimeError("namer returned no single-line name")
    return name


# --- judging one thread ----------------------------------------------------------------

def judge_thread(home: Path, record: dict, post: dict) -> str:
    """Judge a thread through one accepted message and add the verdict to its log.

    Returns recorded, stale, gone, waiting, skipped, or failed.
    """
    thread_id = record["topic_thread_id"]
    through = post["message_id"]
    try:
        live = thread_title.discord_read_title(home, thread_id)
        base = thread_title.split_marker(live)[1]
        # The project comes only from the thread's own public name.
        project = thread_context.project_from_name(base)
        messages, naming_messages = thread_messages(record, home, post)
        thread = {"name": base, "project": project, "messages": messages}
        judged = {"name": base, "project": project, "messages": len(messages)}
        reply_state = post["state"]
        if reply_state in thread_title.EXPLICIT_STATUS:
            thread["reply_state"] = reply_state
            judged["reply_state"] = reply_state
        state = {"thread": thread}
        verdict = judge(state, home)
        needs_name = not verdict["topic_fits"] and bool(project) and not thread_title.captain_named(record, live)
        outcome = thread_title.record_verdict(home, thread_id, through, verdict["status"],
                                              verdict["topic_fits"], judged=judged,
                                              confidence=verdict["confidence"], pending_name=needs_name)
        if outcome == "pending-name":
            name_state = {"thread": dict(thread, messages=naming_messages)}
            return thread_title.publish_named_verdict(home, thread_id, through, propose_name(name_state, home))
        return outcome
    except thread_title.RateLimited:
        return "waiting"
    except UnjudgeableReply as err:
        thread_title.record_judge_skip(home, thread_id, post, str(err))
        return "skipped"
    except Exception as err:
        _log(f"thread {thread_id} keeps its title: {err}")
        thread_title.record_judge_failure(home, thread_id, through)
        return "failed"


# --- the scan -----------------------------------------------------------------------

def _catch_up_path(home: Path) -> Path:
    return poster.state_dir(home) / "ext-autoname" / "catch-up.json"


def _catch_up(home: Path, newest: dict[str, dict], eligible: dict[str, dict]) -> dict:
    """The saved catch-up cohort, written once before the first model call."""
    path = _catch_up_path(home)
    if not path.is_symlink() and path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("threads"), list):
                return data
        except (OSError, ValueError):
            pass
    ranked = sorted((thread for thread in newest if thread in eligible),
                    key=lambda thread: newest[thread]["message_id"], reverse=True)
    horizon = max((post["message_id"] for post in newest.values()), default=0)
    data = {"horizon": str(horizon), "threads": ranked[:CATCH_UP_LIMIT]}
    thread_title._atomic_json(path, data)
    return data


def judge_scan(home: Path | None = None, threads=None, retry_failed: bool = False) -> list[str]:
    """Judge every thread whose newest accepted message has no usable verdict yet.

    ``threads`` limits the scan; ``retry_failed`` also retries a message
    whose judgment failed before (the safety sweep passes it). Returns the
    threads that got a verdict.
    """
    home = home or poster.firstmate_home()
    with _SCAN_LOCK:
        if judging_state(home) != "on":
            return []
        newest = {thread: posts[-1] for thread, posts in thread_title.accepted_posts(home).items()}
        eligible = {record["topic_thread_id"]: record for record in thread_title._eligible_records(home)
                    if record.get("creator") == "firstmate"}
        cohort = _catch_up(home, newest, eligible)
        horizon = thread_title._id(cohort.get("horizon"))
        judged = []
        for thread_id, post in sorted(newest.items(), key=lambda item: item[1]["message_id"], reverse=True):
            if threads is not None and thread_id not in threads:
                continue
            record = eligible.get(thread_id)
            through = post["message_id"]
            if not record or (through <= horizon and thread_id not in cohort["threads"]):
                continue
            title = record.get("title") or {}
            if (thread_title._verdict_at(title, through)
                    or thread_title.judge_skipped(title, post["message_ids"][0])):
                continue
            failed = title.get("judge_failed") or {}
            if not retry_failed and thread_title._id(failed.get("message_id")) == through:
                continue
            outcome = judge_thread(home, record, post)
            with _LOCK:
                _WAITING.discard((home, thread_id))
                if outcome == "waiting":
                    _WAITING.add((home, thread_id))
            if outcome == "recorded":
                judged.append(thread_id)
        return judged


# --- after every post ------------------------------------------------------------------

def _run(home: Path) -> None:
    while True:
        with _LOCK:
            threads = {thread for where, thread in _PENDING if where == home}
            _PENDING.difference_update({(home, thread) for thread in threads})
            if not threads:
                _RUNNING.discard(home)
                return
        try:
            judge_scan(home, threads)
        except Exception as err:
            _log(f"judging skipped: {err}")


def after_post(home: Path, thread_id: str) -> None:
    """A Firstmate chunk reached Discord in this thread: queue it and return at once."""
    if not poster._SNOWFLAKE.fullmatch(str(thread_id or "")):
        return
    thread_title.mark_due(home, thread_id)
    with _LOCK:
        _PENDING.add((home, thread_id))
        if home in _RUNNING:
            return
        _RUNNING.add(home)
    threading.Thread(target=_run, args=(home,), name="fm-ext-autoname", daemon=True).start()


def start_due(home: Path) -> None:
    """Resume judgments whose Discord wait has ended."""
    now = thread_title.time.time()
    with _LOCK:
        due = {thread for where, thread in _WAITING if where == home
               and thread_title.blocked_until(home, thread) <= now}
        _WAITING.difference_update((home, thread) for thread in due)
    if due:
        start_scan(home, retry_failed=True, threads=due)


def start_scan(home: Path | None = None, retry_failed: bool = False, *, threads=None) -> None:
    """Run the requested judge scan in the background."""
    def run() -> None:
        try:
            judge_scan(home, threads=threads, retry_failed=retry_failed)
        except Exception as err:
            _log(f"judging skipped: {err}")

    threading.Thread(target=run, name="fm-ext-autoname-scan", daemon=True).start()
