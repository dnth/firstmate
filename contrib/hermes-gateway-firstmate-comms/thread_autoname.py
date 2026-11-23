"""After-post judging and the one-time catch-up for Firstmate's topic threads.

docs/configuration.md, "Thread title reconciler", owns the contract. This
module never renames anything: it reads a thread, asks Jev
(``bin/fm-ext-thread-judge.sh``) for its status and topic fit, asks the
naming model (``bin/fm-ext-thread-name.sh``) for a new base when the topic
drifted, and hands the result to ``thread_title`` as an input. While judging
is off it hands over the reply's own thread state and retitle instead.

``after_post`` is all the delivery path calls: it queues the post and
returns. A per-thread background worker does the rest, so judging, naming,
and even the "is judging on" check never delay a reply. Every Jev, model,
Discord, or record failure is logged and leaves the title as it is.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque
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
# Give the gateway time to connect before catch-up starts.
CATCH_UP_DELAY_SECS = 60.0
# Bound what one judgment sends: newest messages first, whole messages only.
TEXT_BUDGET_CHARS = 8000
MESSAGE_MAX_CHARS = 2000
MESSAGE_LIMIT = 40

_LOCK = threading.Lock()
_QUEUES: dict[tuple[Path, str], deque] = {}


def _log(message: str) -> None:
    print(f"fm-ext-autoname: {message}", file=sys.stderr)


def _tool(name: str) -> str:
    return str(poster.firstmate_root() / "bin" / name)


def enabled(home: Path) -> bool:
    """The one key-presence check: ``bin/fm-ext-thread-judge.sh --check``."""
    try:
        result = subprocess.run([_tool("fm-ext-thread-judge.sh"), "--check"],
                                capture_output=True, text=True, check=False, timeout=30,
                                env=firstmate_env(home, poster.firstmate_root(), jev=True))
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


# --- thread text -----------------------------------------------------------------

def _message(role: str, text: object) -> dict | None:
    if not isinstance(text, str) or not text.strip():
        return None
    text = text.strip()
    if len(text) > MESSAGE_MAX_CHARS:
        text = text[:MESSAGE_MAX_CHARS - 1].rstrip() + "…"
    return {"role": role, "text": text}


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


def thread_messages(record: dict, home: Path, through: str) -> list[dict]:
    """The thread's text through message ``through``, oldest first."""
    thread_id = record["topic_thread_id"]
    token = poster._bot_token()
    if not token:
        raise thread_context.HistoryUnavailable("no Discord bot token in the gateway environment")
    messages = thread_context._get(f"/channels/{thread_id}/messages",
                                   {"limit": MESSAGE_LIMIT, "before": str(int(through) + 1)}, token)
    posts = poster.firstmate_posts(home)
    captains = _captains(record, home)
    kept, seen, budget = [], set(), TEXT_BUDGET_CHARS
    for raw in sorted((item for item in messages if isinstance(item, dict)),
                      key=lambda item: int(str(item.get("id") or "0")) if
                      poster._SNOWFLAKE.fullmatch(str(item.get("id") or "")) else 0,
                      reverse=True):
        entry = thread_context._entry(raw, "", "", posts, "")
        if entry is None or entry["id"] in seen or int(entry["id"]) > int(through):
            continue
        role = "firstmate" if entry["role"] == "firstmate" else (
            "captain" if entry["author_id"] in captains else "participant")
        message = _message(role, entry["text"])
        if message is None:
            continue
        if len(kept) >= MESSAGE_LIMIT or len(message["text"]) > budget:
            break
        seen.add(entry["id"])
        budget -= len(message["text"])
        kept.append(message)
    kept.reverse()
    return kept


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
    """Jev's {status, topic_fits} for one thread; raises on any failure."""
    result = _run_tool("fm-ext-thread-judge.sh", state, home, timeout=30, jev=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"judge exited {result.returncode}")
    verdict = json.loads(result.stdout)
    if (verdict.get("status") not in ("open-question", "running", "done", "blocked")
            or not isinstance(verdict.get("topic_fits"), bool)):
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

def _eligible(record: dict, home: Path) -> bool:
    return (bool(record) and record.get("creator") == "firstmate"
            and (poster._creating_request(record).get("channel_id") or "") == poster.dedicated_channel(home))


def judge_thread(home: Path, thread_id: str, cutoff: str, read_thread=None, decision: bool = False) -> str:
    """Judge one thread through message ``cutoff`` and record the verdict.

    Returns recorded, stale, skipped, or failed. Nothing here renames.
    """
    record = poster.load_thread_record_by_id(thread_id, home)
    if not _eligible(record, home):
        return "skipped"
    if not thread_title.fresh(home, thread_id, cutoff):
        return "stale"
    try:
        live = (read_thread or poster.discord_thread_name)(thread_id)
        if not live:
            raise RuntimeError("live title unreadable")
        base = thread_title.split_marker(live)[1]
        state = {"thread": {"name": base,
                            "project": thread_context.resolve_project(base, thread_id, home),
                            "messages": thread_messages(record, home, cutoff)}}
        if not state["thread"]["messages"]:
            return "skipped"
        verdict = judge(state, home)
        new_base = ""
        if not verdict["topic_fits"] and not thread_title.captain_named(record, live):
            new_base = propose_name(state, home)
    except Exception as err:
        _log(f"thread {thread_id} keeps its title: {err}")
        return "failed"
    outcome = thread_title.record_verdict(home, thread_id, verdict["status"], verdict["topic_fits"],
                                          cutoff, new_base, decision=decision)
    return "recorded" if outcome == "recorded" else "stale"


# --- after every post ------------------------------------------------------------------

def handle_post(home: Path, thread_id: str, post: dict, judging: bool | None = None,
                read_thread=None, newest: bool = True) -> str:
    """Turn one delivered post into reconciler inputs.

    ``post`` carries the final ``message_id``, the reply's explicit ``state``
    and unscreened ``retitle``, and whether it carried a ``decision``. Every
    post makes the thread due, so a decision post's question mark is written
    as soon as Discord permits and a failed write is retried by the next
    reply. With judging on, the newest queued post is judged; otherwise the
    reply's own state and retitle are recorded.
    """
    thread_title.mark_due(home, thread_id)
    if judging is None:
        judging = enabled(home)
    if judging:
        if not newest:
            return "superseded"
        return judge_thread(home, thread_id, post["message_id"], read_thread=read_thread,
                            decision=bool(post.get("decision")))
    retitle = poster.screened_title(post.get("retitle") or "", home) if post.get("retitle") else ""
    if thread_title.record_explicit(home, thread_id, post.get("state"), retitle, post["message_id"],
                                    decision=bool(post.get("decision"))):
        return "recorded"
    return "skipped"


def _run_queue(home: Path, thread_id: str) -> None:
    key = (home, thread_id)
    judging = None
    while True:
        with _LOCK:
            queue = _QUEUES[key]
            if not queue:
                del _QUEUES[key]
                return
            post = queue.popleft()
            newest = not queue
        try:
            if judging is None:
                judging = enabled(home)
            handle_post(home, thread_id, post, judging=judging, newest=newest)
        except Exception as err:
            _log(f"thread {thread_id} keeps its title: {err}")


def after_post(home: Path, thread_id: str, post: dict) -> None:
    """Queue one delivered post for its thread's worker and return at once."""
    if not poster._SNOWFLAKE.fullmatch(str(thread_id or "")) or not poster._SNOWFLAKE.fullmatch(
            str(post.get("message_id") or "")):
        return
    key = (home, thread_id)
    with _LOCK:
        if key in _QUEUES:
            _QUEUES[key].append(post)
            return
        _QUEUES[key] = deque([post])
    threading.Thread(target=_run_queue, args=(home, thread_id),
                     name="fm-ext-autoname", daemon=True).start()


# --- the one-time catch-up ------------------------------------------------------------

def _catch_up_path(home: Path) -> Path:
    return poster.state_dir(home) / "ext-autoname" / "catch-up.json"


def _load_catch_up(path: Path) -> dict | None:
    if path.is_symlink() or not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) and isinstance(data.get("threads"), list) else None


def _save_catch_up(path: Path, data: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="catch-up.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def catch_up(home: Path | None = None, read_thread=None) -> list[str]:
    """Judge the ten threads Firstmate posted in most recently, once per home.

    The thread list and each thread's progress are saved before the first
    model call and after every thread, so a restart resumes where it stopped
    without repeating a finished thread's model calls. Returns the threads
    this run judged.
    """
    home = home or poster.firstmate_home()
    path = _catch_up_path(home)
    data = _load_catch_up(path)
    if data and data.get("completed"):
        return []
    if not enabled(home):
        return []
    if data is None:
        newest = thread_title.firstmate_messages(home)
        cohort = []
        for thread_id in sorted(newest, key=newest.__getitem__, reverse=True):
            if len(cohort) == CATCH_UP_LIMIT:
                break
            if _eligible(poster.load_thread_record_by_id(thread_id, home), home):
                cohort.append({"thread_id": thread_id, "cutoff": str(newest[thread_id])})
        data = {"started_at": time.time(), "threads": cohort, "done": [], "completed": False}
        _save_catch_up(path, data)
    judged = []
    for item in data["threads"]:
        thread_id = str(item.get("thread_id") or "")
        if thread_id in data["done"]:
            continue
        cutoff = str(thread_title.firstmate_messages(home).get(thread_id) or item.get("cutoff") or "")
        if poster._SNOWFLAKE.fullmatch(cutoff):
            judge_thread(home, thread_id, cutoff, read_thread=read_thread)
            judged.append(thread_id)
        data["done"].append(thread_id)
        _save_catch_up(path, data)
    data["completed"] = True
    data["completed_at"] = time.time()
    _save_catch_up(path, data)
    return judged


def start_catch_up(home: Path | None = None) -> None:
    """Run the one-time catch-up in the background after the gateway connects."""
    def run() -> None:
        time.sleep(CATCH_UP_DELAY_SECS)
        try:
            catch_up(home)
        except Exception as err:
            _log(f"catch-up stopped: {err}")

    threading.Thread(target=run, name="fm-ext-autoname-catch-up", daemon=True).start()
