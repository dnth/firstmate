"""The one writer of Firstmate topic-thread titles.

docs/configuration.md, "Thread title reconciler", owns the contract. This
module is level-triggered: ``reconcile`` recomputes a thread's title from
durable state alone, and a race that slips past its last check is corrected
by the next pass instead of being prevented by ordering.

Durable state it reads:

- the decision ledger (``bin/fm-ext-decision.sh threads``): open, closed, or
  unknown decision posts, whether each carried buttons, and closure times;
- the accepted-message log: chunk progress records the poster writes as
  Discord accepts each chunk, including each reply's explicit thread state
  and retitle (``title_input``);
- the thread record's ``title`` object: the Jev verdict log, the last bot
  write, a write whose answer was lost, the pace stamp, the captain's
  words, and a marker he removed;
- the cooldowns file ``state/ext-autoname/cooldowns.json``: Discord's
  bot-global and per-thread deadlines, stamped when each response arrived.

Passes run on events (a post, a verdict, a decision change, a pace or
cooldown slot opening) and on a slow safety sweep; nothing else in the
plugin writes a title.
"""

from __future__ import annotations

import json
import math
import os
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:
    from . import outbox_poster as poster
except ImportError:  # loaded from sys.path in hermetic tests
    import outbox_poster as poster

QUESTION = "\u2753 "
BLOCKED = "\u26a0\ufe0f "
RUNNING = "\u23f3 "
DONE = "\u2705 "
# Strongest first: an open decision or question outranks a blocker, which
# outranks running work, which outranks settled work, which outranks no marker.
PRECEDENCE = (QUESTION, BLOCKED, RUNNING, DONE, "")
MARKERS = PRECEDENCE[:-1]
STATUS_MARKER = {"open-question": QUESTION, "blocked": BLOCKED, "running": RUNNING,
                 "done": DONE, "none": ""}
# A reply's explicit thread state, used as the status only while judging is off.
EXPLICIT_STATUS = {"needs-you": "open-question", "done": "done", "none": "none"}
# Our own pace: one title change per thread per this many seconds. Only a
# decision button's question mark and a correction of our own raced write
# skip it.
PACE_SECS = 600.0
# Retry cadence after an unreadable title or ledger or a transient Discord
# failure; Discord's own limits come only from its headers and 429 replies.
RETRY_SECS = 30.0
# The safety sweep: every eligible thread is reconciled at least this often,
# which catches what raises no event, such as the captain's own renames.
SAFETY_SECS = 600.0
# Discord snowflakes count milliseconds from this epoch in their top bits.
_DISCORD_EPOCH = 1420070400.0
# Compare-and-write retries inside one pass before leaving it to the next.
_ATTEMPTS = 3
_AUDIT_VERDICT_LIMIT = 20
_FULL_VERDICT_LIMIT = 20

_DUE: dict[tuple[Path, str], float] = {}
_DUE_LOCK = threading.Lock()
_REQUEST_LOCK = threading.Lock()


class RateLimited(Exception):
    """The next time Discord permits this title-path request."""

    def __init__(self, until: float):
        super().__init__("discord rate limited")
        self.until = until


class _InputsMoved(Exception):
    pass


def _log(message: str) -> None:
    print(f"fm-ext-title: {message}", file=sys.stderr)


def split_marker(name: str) -> tuple[str, str]:
    """The (marker, base) of a thread title; the marker may be ""."""
    for marker in MARKERS:
        if name.startswith(marker):
            return marker, name[len(marker):]
    return "", name


def _id(value: object) -> int:
    text = str(value or "")
    return int(text) if poster._SNOWFLAKE.fullmatch(text) else 0


def message_time(message_id: object) -> float:
    """The epoch second a Discord id was created, or 0 for a non-id."""
    value = _id(message_id)
    return (value >> 22) / 1000.0 + _DISCORD_EPOCH if value else 0.0


def _atomic_json(path: Path, data: dict) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
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


# --- the accepted-message log ---------------------------------------------------

def accepted_posts(home: Path) -> dict[str, list[dict]]:
    """Every Discord-accepted Firstmate reply per destination thread, oldest first.

    Each entry is one outbox generation: ``message_id`` is its newest accepted
    chunk, ``complete`` says every chunk landed, and ``state`` and ``retitle``
    are the reply's own title inputs.
    """
    posts: dict[str, list[dict]] = {}
    outbox = poster.state_dir(home) / "ext-outbox"
    if outbox.is_symlink() or not outbox.is_dir():
        return posts
    for path in outbox.glob("*.progress.json"):
        if path.is_symlink():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or not isinstance(data.get("discord_message_ids"), list):
            continue
        newest = max((_id(item) for item in data["discord_message_ids"]), default=0)
        request = str(data.get("request_id") or "").split(":")
        thread_id = str(data.get("topic_thread_id") or (request[3] if len(request) > 3 else ""))
        if not newest or not poster._SNOWFLAKE.fullmatch(thread_id):
            continue
        given = data.get("title_input") if isinstance(data.get("title_input"), dict) else {}
        state, retitle = given.get("state"), given.get("retitle")
        posts.setdefault(thread_id, []).append({
            "message_id": newest,
            "complete": int(data.get("posted_count") or 0) >= int(data.get("total") or 0),
            "state": state if isinstance(state, str) else "",
            "retitle": retitle if isinstance(retitle, str) else "",
        })
    for entries in posts.values():
        entries.sort(key=lambda entry: entry["message_id"])
    return posts


def newest_accepted(home: Path) -> dict[str, int]:
    """The newest Discord-accepted Firstmate message id per thread."""
    return {thread: entries[-1]["message_id"] for thread, entries in accepted_posts(home).items()}


# --- Discord's cooldowns -------------------------------------------------------------

def _cooldown_path(home: Path) -> Path:
    return poster.state_dir(home) / "ext-autoname" / "cooldowns.json"


def cooldowns(home: Path) -> dict:
    path = _cooldown_path(home)
    try:
        data = json.loads(path.read_text(encoding="utf-8")) if not path.is_symlink() else {}
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    threads = data.get("threads") if isinstance(data.get("threads"), dict) else {}
    return {"global": float(data.get("global") or 0), "threads": threads}


def blocked_until(home: Path, thread_id: str) -> float:
    """The time Discord allows this thread's next title-path request."""
    held = cooldowns(home)
    return max(held["global"], float(held["threads"].get(thread_id) or 0))


def _hold(home: Path, thread_id: str, until: float, global_limit: bool) -> None:
    """Record a Discord deadline durably, for this thread or for the bot."""
    held = cooldowns(home)
    now = time.time()
    held["threads"] = {key: value for key, value in held["threads"].items() if float(value) > now}
    if global_limit:
        held["global"] = max(held["global"], until)
    else:
        held["threads"][thread_id] = max(float(held["threads"].get(thread_id) or 0), until)
    _atomic_json(_cooldown_path(home), held)


def _seconds(value: object) -> float | None:
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    return seconds if math.isfinite(seconds) and seconds >= 0 else None


def _response_wait(home: Path, thread_id: str, headers, at: float,
                   details: dict | None = None) -> float | None:
    limited = details is not None
    if not limited and headers.get("X-RateLimit-Remaining") != "0":
        return None
    details = details or {}
    waits = [_seconds(value) for value in (details.get("retry_after"), headers.get("Retry-After"),
                                           headers.get("X-RateLimit-Reset-After"))]
    wait = max((value for value in waits if value is not None), default=None)
    reset = _seconds(headers.get("X-RateLimit-Reset"))
    until = at + wait if wait is not None else (max(at, reset) if reset is not None else None)
    if until is not None:
        global_limit = limited and (details.get("global") is True
                                    or headers.get("X-RateLimit-Global") == "true"
                                    or headers.get("X-RateLimit-Scope") == "global")
        _hold(home, thread_id, until, global_limit)
        if limited:
            _log(f"thread {thread_id} waits {until - at:.1f}s for Discord"
                 + (" (bot-wide)" if global_limit else ""))
    return until


def _request(home: Path, thread_id: str, method: str, path: str, body: dict | None = None,
             prepare=None) -> bytes:
    token = poster._bot_token()
    if not token:
        raise poster.DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    request = urllib.request.Request(
        f"{poster.DISCORD_API_BASE}{path}",
        data=json.dumps(body).encode("utf-8") if body is not None else None,
        method=method,
        headers={"Authorization": f"Bot {token}", "Content-Type": "application/json",
                 "User-Agent": poster.USER_AGENT},
    )
    with _REQUEST_LOCK:
        allowed = blocked_until(home, thread_id)
        if time.time() < allowed:
            raise RateLimited(allowed)
        if prepare is not None:
            prepare()
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                _response_wait(home, thread_id, response.headers, time.time())
                return response.read()
        except urllib.error.HTTPError as err:
            at = time.time()
            details = None
            if err.code == 429:
                try:
                    details = json.loads(err.read())
                except (OSError, UnicodeError, ValueError):
                    details = {}
                if not isinstance(details, dict):
                    details = {}
            until = _response_wait(home, thread_id, err.headers or {}, at, details)
            if err.code == 429 and until is not None:
                raise RateLimited(until) from err
            raise poster.DiscordSendError(poster.classify_http_code(err.code), f"discord HTTP {err.code}",
                                          err.code) from err
        except (urllib.error.URLError, TimeoutError, OSError) as err:
            raise poster.DiscordSendError("ambiguous", f"discord transport: {err}") from err


def _discord_thread(home: Path, thread_id: str) -> dict:
    if not poster._SNOWFLAKE.fullmatch(thread_id):
        raise poster.DiscordSendError("permanent", "thread id is not a Discord id")
    raw = _request(home, thread_id, "GET", f"/channels/{thread_id}")
    data = json.loads(raw.decode("utf-8") or "{}")
    return data if isinstance(data, dict) else {}


def discord_read_title(home: Path, thread_id: str) -> str:
    """The name Discord shows now; raises RateLimited or DiscordSendError."""
    name = _discord_thread(home, thread_id).get("name")
    if not isinstance(name, str) or not name:
        raise poster.DiscordSendError("ambiguous", "discord thread read returned no name")
    return name


def discord_read_messages(home: Path, thread_id: str, through: int, limit: int) -> list:
    """Up to ``limit`` messages at or before ``through``, newest first."""
    query = urllib.parse.urlencode({"limit": limit, "before": str(through + 1)})
    raw = _request(home, thread_id, "GET", f"/channels/{thread_id}/messages?{query}")
    data = json.loads(raw.decode("utf-8") or "[]")
    if not isinstance(data, list):
        raise poster.DiscordSendError("ambiguous", "discord returned no message list")
    return data


def discord_write_title(home: Path, thread_id: str, name: str, prepare=None) -> None:
    """PATCH one thread's name, honoring and recording Discord's cooldowns."""
    if not poster._SNOWFLAKE.fullmatch(thread_id):
        raise poster.DiscordSendError("permanent", "thread id is not a Discord id")
    _request(home, thread_id, "PATCH", f"/channels/{thread_id}", {"name": name}, prepare=prepare)


# --- inputs other parts of the plugin record --------------------------------------

def mark_due(home: Path, thread_id: str, at: float = 0.0) -> None:
    """Ask the reconciler to look at a thread no earlier than ``at``."""
    with _DUE_LOCK:
        key = (home, thread_id)
        _DUE[key] = min(at, _DUE.get(key, at))


def _change_title(home: Path, thread_id: str, change, topic_name: str = "") -> bool:
    """Apply ``change(title)`` to a thread's ``title`` object under the record lock."""
    with poster._THREAD_RECORD_LOCK:
        record = poster.load_thread_record_by_id(thread_id, home)
        if not record:
            return False
        title = dict(record.get("title") or {})
        if change(title) is False:
            return False
        for key in [key for key, value in title.items() if value is None]:
            del title[key]
        poster.save_thread_record(record["path"], record.get("request_id"), thread_id,
                                  topic_name=topic_name, title=title, preserve_mtime=True)
    return True


def _publish_verdict(title: dict, verdict: dict) -> None:
    cutoff = _id(verdict["message_id"])
    previous = _verdict_at(title, cutoff)
    if any(previous.get(key) != value for key, value in verdict.items() if key != "at"):
        applicable = [entry for entry in _applicable_verdicts(title) if _id(entry.get("message_id")) != cutoff]
        applicable.append(dict(verdict, at=time.time()))
        applicable.sort(key=lambda entry: _id(entry["message_id"]))
        audit = [entry for entry in title.get("verdicts") or [] if entry.get("audit_only")]
        historical = [_reconcile_verdict(entry) for entry in applicable[:-_FULL_VERDICT_LIMIT]]
        title["verdicts"] = historical + applicable[-_FULL_VERDICT_LIMIT:] + audit
    if (title.get("judge_failed") or {}).get("message_id") == str(cutoff):
        title["judge_failed"] = None


def record_verdict(home: Path, thread_id: str, message_id: object, status: str, topic_fits: bool,
                   base: str = "", judged: dict | None = None,
                   confidence: float | None = None, *, pending_name: bool = False) -> str:
    """Add a Jev verdict judged through ``message_id`` to the thread's log.

    The entry's ``message_id`` is the newest judged message. ``judged`` is the
    bounded input summary for that judgment (thread name, project, the reply's
    own explicit state when it declared one, and message count), and
    ``confidence`` is the model's own confidence in its status. No message
    text is recorded.

    Stale verdicts and those awaiting a name are retained for audit only.
    Returns recorded, pending-name, stale, or gone.
    """
    if status not in STATUS_MARKER or status == "none":
        raise ValueError(f"unknown status {status!r}")
    cutoff = _id(message_id)
    verdict = {"message_id": str(cutoff), "status": status, "topic_fits": bool(topic_fits),
               "base": base or "", "at": time.time()}
    if isinstance(confidence, (int, float)) and not isinstance(confidence, bool):
        verdict["confidence"] = float(confidence)
    if judged:
        verdict["judged"] = dict(judged)

    def change(title):
        if stale or pending_name:
            log = title.get("verdicts") or []
            audit = [entry for entry in log if entry.get("audit_only")]
            audit.append(dict(verdict, audit_only=True))
            title["verdicts"] = _applicable_verdicts(title) + audit[-_AUDIT_VERDICT_LIMIT:]
        else:
            _publish_verdict(title, verdict)

    with poster._THREAD_RECORD_LOCK:
        stale = newest_accepted(home).get(thread_id, 0) > cutoff
        if not _change_title(home, thread_id, change):
            return "gone"
    if stale:
        return "stale"
    if pending_name:
        return "pending-name"
    mark_due(home, thread_id)
    return "recorded"


def publish_named_verdict(home: Path, thread_id: str, cutoff: int, base: str) -> str:
    """Make the scan's latest audited verdict for this message usable."""
    def change(title):
        log = title.get("verdicts") or []
        for index in range(len(log) - 1, -1, -1):
            entry = log[index]
            if entry.get("audit_only") and _id(entry.get("message_id")) == cutoff:
                title["verdicts"] = log[:index] + log[index + 1:]
                verdict = dict(entry, base=base)
                del verdict["audit_only"]
                _publish_verdict(title, verdict)
                return
        return False

    with poster._THREAD_RECORD_LOCK:
        if newest_accepted(home).get(thread_id, 0) > cutoff:
            return "stale"
        if not _change_title(home, thread_id, change):
            return "gone"
    mark_due(home, thread_id)
    return "recorded"


def record_judge_failure(home: Path, thread_id: str, message_id: object) -> None:
    """Remember that judging this message failed, so only the safety sweep retries it."""
    _change_title(home, thread_id, lambda title: title.__setitem__(
        "judge_failed", {"message_id": str(_id(message_id))}))


def title_inputs(record: dict) -> dict:
    """A record's reconciler object, translating intent from before the reconciler.

    Main kept a deferred state behind an open decision and a failed or
    deferred retitle; both become a seed the reconciler applies like an
    explicit reply.
    """
    title = record.get("title")
    if isinstance(title, dict):
        return title
    seed = {}
    rename = record.get("rename") if isinstance(record.get("rename"), dict) else {}
    state = record.get("deferred_state")
    if state not in ("none", "done"):
        state = {"deferred": rename.get("state"), "failed": record.get("thread_state")}.get(rename.get("outcome"))
    marked_open = record.get("marked_open") is True
    if state in EXPLICIT_STATUS and not (marked_open and state == "needs-you"):
        seed["state"] = state
    retitle = record.get("retitle")
    if isinstance(retitle, str) and retitle and rename.get("outcome") in ("failed", "deferred"):
        seed["retitle"] = retitle
    title = {"seed": seed} if seed else {}
    name = record.get("topic_name")
    if marked_open and isinstance(name, str) and split_marker(name)[0] == QUESTION:
        title["held"] = ""
    return title


# --- the desired title ---------------------------------------------------------------

def _during_decision(posts: list[dict], message_id: int) -> bool:
    """True when a decision post was open at the time this message was posted."""
    at = message_time(message_id)
    return any(0 < _id(post.get("message_id")) <= message_id
               and (post.get("state") == "open" or float(post.get("closed_at") or 0) > at)
               for post in posts)


def _applicable_verdicts(title: dict) -> list[dict]:
    return [entry for entry in title.get("verdicts") or []
            if not entry.get("audit_only") and entry.get("status") in STATUS_MARKER]


def _verdict_at(title: dict, cutoff: int) -> dict:
    return next((entry for entry in reversed(_applicable_verdicts(title))
                 if _id(entry.get("message_id")) == cutoff), {})


def _entries(view: dict, title: dict, judging: bool) -> list[dict]:
    """Status entries, oldest first: Jev verdicts, or the replies' own states."""
    if judging:
        return [dict(entry, message_id=_id(entry.get("message_id"))) for entry in _applicable_verdicts(title)]
    entries = []
    seed = (title.get("seed") or {}).get("state")
    if seed in EXPLICIT_STATUS:
        entries.append({"message_id": 0, "status": EXPLICIT_STATUS[seed]})
    for post in view["posts"]:
        if post["complete"] and post["state"] in EXPLICIT_STATUS:
            entries.append({"message_id": post["message_id"], "status": EXPLICIT_STATUS[post["state"]]})
    return entries


def plan(title: dict, view: dict, judging: bool) -> dict:
    """The title the durable inputs ask for: a pure function of its arguments.

    ``computed`` is the marker before a removed marker is respected.
    """
    live_marker, live_base = split_marker(view["live"])
    summary = view["summary"]
    ledger = summary.get("posts") or []
    open_decisions = int(summary.get("open") or 0)
    entries = _entries(view, title, judging)
    newest = view["newest"]
    verdict = _verdict_at(title, newest) if judging else {}

    chosen = None
    if judging:
        chosen = dict(verdict, message_id=newest) if verdict else None
    elif entries:
        chosen = entries[-1]
    if chosen is None:
        # Nothing judged on the newest post yet: hold the marker of our last
        # paced write until a verdict arrives.
        status_marker = split_marker(title.get("held", view["written"]))[0]
    else:
        pick = chosen
        if (pick["status"] == "open-question" and open_decisions == 0
                and _during_decision(ledger, pick["message_id"])):
            # A question asked while a decision was open belongs to that
            # decision; once every decision closed, the status kept before it
            # stands.
            earlier = [entry for entry in entries if entry["message_id"] < pick["message_id"]
                       and not (entry["status"] == "open-question"
                                and _during_decision(ledger, entry["message_id"]))]
            pick = earlier[-1] if earlier else {"status": "none"}
        status_marker = STATUS_MARKER[pick["status"]]
    candidates = [status_marker] + ([QUESTION] if open_decisions else [])
    computed = min(candidates, key=PRECEDENCE.index)
    marker = computed
    if title.get("removed_marker") and computed == title["removed_marker"]:
        marker = live_marker

    base = title.get("manual_base") or ""
    if not base:
        base = live_base
        if judging and chosen is not None and not chosen.get("topic_fits", True) and chosen.get("base"):
            base = chosen["base"]
        elif not judging:
            retitles = [post["retitle"] for post in view["posts"] if post["complete"] and post["retitle"]]
            base = (retitles[-1] if retitles else (title.get("seed") or {}).get("retitle")) or live_base
    return {"desired": marker + base, "computed": computed, "verdict": _reconcile_verdict(verdict),
            "decision_question": marker == QUESTION and int(summary.get("open_buttons") or 0) > 0}


def _reconcile_verdict(verdict: dict) -> dict:
    return {key: verdict[key] for key in ("message_id", "status", "topic_fits", "base", "at")
            if key in verdict}


def _correction(title: dict, view: dict, verdict: dict) -> bool:
    """True when our last write raced newer durable state that existed before it landed."""
    written = title.get("written") or {}
    if not written or view["live"] != written.get("name"):
        return False
    landed = float(written.get("at") or 0)
    basis = written.get("basis") or {}
    if ("verdict" in basis and verdict != _reconcile_verdict(basis["verdict"])
            and 0 < float(verdict.get("at") or 0) < landed):
        return True
    if any(entry["message_id"] > int(basis.get("newest") or 0) and message_time(entry["message_id"]) < landed
           for entry in view["posts"]):
        return True
    before = {item[0]: item[1] for item in basis.get("ledger") or []}
    for post in view["summary"].get("posts") or []:
        message_id = str(post.get("message_id"))
        state = post.get("state")
        if before.get(message_id) == state:
            continue
        changed_at = float(post.get("closed_at") or 0) if state == "closed" else message_time(message_id)
        if changed_at and changed_at < landed:
            return True
    return False


def _fingerprint(summary: dict) -> list:
    return sorted([str(post.get("message_id")), post.get("state"), bool(post.get("buttons"))]
                  for post in summary.get("posts") or [])


# --- the reconciler -----------------------------------------------------------------

def eligible(record: dict, home: Path, thread_owner=None) -> bool:
    """Only a thread this home created in the dedicated channel is renamed."""
    if not record or record.get("creator") == "adopted":
        return False
    if (poster._creating_request(record).get("channel_id") or "") != poster.dedicated_channel(home):
        return False
    if record.get("creator") == "firstmate":
        return True
    # A record written before provenance was kept needs Discord's word that
    # this bot owns the thread.
    thread_id = record["topic_thread_id"]
    try:
        if thread_owner is not None:
            owner_id = thread_owner(thread_id)
        else:
            owner_id = str(_discord_thread(home, thread_id).get("owner_id") or "")
        if not poster._SNOWFLAKE.fullmatch(owner_id or ""):
            return False
        if owner_id != poster._bot_user_id(read=lambda: _request(home, thread_id, "GET", "/users/@me")):
            return False
    except RateLimited:
        raise
    except Exception as err:
        _log(f"thread {record['topic_thread_id']} owner lookup skipped: {err}")
        return False
    poster.save_thread_record(record["path"], record.get("request_id"), record["topic_thread_id"],
                              creator="firstmate", preserve_mtime=True)
    return True


def captain_named(record: dict, live: str) -> bool:
    """True once the captain's own words name the thread."""
    title = record.get("title") or {}
    if title.get("manual_base"):
        return True
    written = (title.get("written") or {}).get("name") or record.get("topic_name") or ""
    attempt = (title.get("attempt") or {}).get("name")
    if not written or not live or live == attempt:
        return False
    return split_marker(live)[1] != split_marker(written)[1]


def _read_view(home: Path, thread_id: str, read_thread) -> dict | str:
    """Read the live title and decision ledger, or return a reason to stop."""
    live = read_thread(thread_id) if read_thread is not None else discord_read_title(home, thread_id)
    if not live:
        return "live title unreadable"
    summaries = poster.decision_threads(home, thread_id)
    if summaries is None:
        return "decision ledger unreadable"
    summary = summaries.get(thread_id, {})
    if int(summary.get("unknown") or 0):
        return "a decision's state is unknown"
    return {"summary": summary, "live": live, "ledger": _fingerprint(summary)}


def _observe(title: dict, view: dict) -> dict:
    """What the live title says about our last write and the captain; the changes to save."""
    changes: dict = {}
    live = view["live"]
    attempt = title.get("attempt") or {}
    if attempt:
        if attempt.get("name") == live:
            # Our last write landed even though Discord's answer was lost.
            changes.update(_written(attempt, title.get("held", view["written"])))
            title.update(changes)
            view["written"] = live
        changes["attempt"] = None
    written = view["written"]
    if written:
        written_marker, written_base = split_marker(written)
        live_marker, live_base = split_marker(live)
        if live_base != written_base and live_base != title.get("manual_base"):
            # The captain renamed the thread: his words stay for good.
            title["manual_base"] = changes["manual_base"] = live_base
        if written_marker and not live_marker and title.get("removal_for") != written:
            # The captain took our marker off: respected until ours changes.
            title["removed_marker"] = changes["removed_marker"] = written_marker
            title["removal_for"] = changes["removal_for"] = written
    return changes


def _written(attempt: dict, held: str) -> dict:
    fields = {"written": {key: attempt.get(key) for key in ("name", "at", "basis")}, "held": held}
    if attempt.get("kind") != "decision":
        fields["paced_at"] = attempt.get("at")
        fields["held"] = attempt.get("name")
    return fields


def reconcile(home: Path, thread_id: str, *, judging: str | None = None, rename=None,
              read_thread=None, thread_owner=None) -> str:
    """Bring one thread's Discord title to the title its durable inputs ask for.

    ``judging`` is the one key check's word (on, off, inactive, unknown);
    only on and off do title work. Returns applied, unchanged, waiting,
    rate-limited, failed, unreadable, moved, or skipped. Every failure leaves
    the title as it is and schedules the thread again.
    """
    if judging is None:
        judging = judging_state(home)
    if judging not in ("on", "off"):
        return "skipped"
    record = poster.load_thread_record_by_id(thread_id, home)
    if not record:
        return "skipped"

    def save(outcome: str, due: float = 0.0, error: str = "", **fields) -> str:
        last = {"outcome": outcome, "at": time.time()}
        if error:
            last["error"] = error
        fields["last"] = last
        name = (fields.get("written") or {}).get("name") or ""
        _change_title(home, thread_id, lambda title: title.update(fields), topic_name=name)
        if due:
            mark_due(home, thread_id, due)
        return outcome

    for _ in range(_ATTEMPTS):
        allowed = blocked_until(home, thread_id)
        if time.time() < allowed:
            mark_due(home, thread_id, allowed)
            return "waiting"
        try:
            if not eligible(record, home, thread_owner):
                return "skipped"
            view = _read_view(home, thread_id, read_thread)
        except RateLimited as err:
            return save("rate-limited", err.until, str(err))
        except Exception as err:
            view = f"live title unreadable: {err}"
        if isinstance(view, str):
            return save("unreadable", time.time() + RETRY_SECS, view)
        title = dict(record.get("title") or {})
        posts = accepted_posts(home).get(thread_id, [])
        view.update(posts=posts, newest=posts[-1]["message_id"] if posts else 0,
                    written=(title.get("written") or {}).get("name") or record.get("topic_name") or "")
        changes = _observe(title, view)
        changes["ledger"] = view["ledger"]
        wanted = plan(title, view, judging == "on")
        verdict = wanted["verdict"]
        if title.get("removed_marker") and wanted["computed"] != title["removed_marker"]:
            changes["removed_marker"] = None
        if wanted["desired"] == view["live"]:
            return save("unchanged", **changes)

        live_marker, live_base = split_marker(view["live"])
        desired_marker, desired_base = split_marker(wanted["desired"])
        if (desired_base != live_base and desired_base != title.get("manual_base")
                and poster.screened_title(desired_base, home) != desired_base):
            desired_base = live_base
            wanted["desired"] = desired_marker + live_base
            if wanted["desired"] == view["live"]:
                return save("unchanged", **changes)

        if wanted["decision_question"] and live_marker != QUESTION:
            kind, target = "decision", QUESTION + live_base
        elif _correction(title, view, verdict):
            kind, target = "correction", wanted["desired"]
        else:
            kind, target = "paced", wanted["desired"]
            slot = float(title.get("paced_at") or 0) + PACE_SECS
            if time.time() < slot:
                return save("waiting", slot, **changes)
        refused = title.get("refused") or {}
        if refused.get("name") == target and refused.get("newest") == view["newest"]:
            # Discord refused this exact write for good; the thread's next
            # reply is the next chance, and the refusal stays the last outcome.
            _change_title(home, thread_id, lambda title: title.update(changes))
            return "refused"

        # Compare and write: the state this title was computed from must
        # still hold right before the request leaves.
        try:
            check = _read_view(home, thread_id, read_thread)
        except RateLimited as err:
            return save("rate-limited", err.until, str(err), **changes)
        except Exception as err:
            check = f"live title unreadable: {err}"
        if isinstance(check, str):
            return save("unreadable", time.time() + RETRY_SECS, check, **changes)
        if any(check[key] != view[key] for key in ("live", "ledger")):
            save("moved", **changes)
            record = poster.load_thread_record_by_id(thread_id, home) or record
            continue

        attempt = {"name": target, "kind": kind,
                   "basis": {"newest": view["newest"], "ledger": view["ledger"], "verdict": verdict}}

        def prepare():
            with poster._THREAD_RECORD_LOCK:
                if newest_accepted(home).get(thread_id, 0) != view["newest"]:
                    raise _InputsMoved

                def save_attempt(current):
                    if judging == "on" and _reconcile_verdict(_verdict_at(current, view["newest"])) != verdict:
                        return False
                    attempt["at"] = time.time()
                    current.update(changes, attempt=attempt)

                if not _change_title(home, thread_id, save_attempt):
                    raise _InputsMoved

        try:
            if rename is None:
                discord_write_title(home, thread_id, target, prepare=prepare)
            else:
                allowed = blocked_until(home, thread_id)
                if time.time() < allowed:
                    raise RateLimited(allowed)
                prepare()
                rename(thread_id, target)
        except _InputsMoved:
            save("moved", **changes)
            record = poster.load_thread_record_by_id(thread_id, home) or record
            continue
        except RateLimited as err:
            return save("rate-limited", err.until, str(err), **dict(changes, attempt=None))
        except Exception as err:
            outcome = poster.classify_send_failure(err)
            _log(f"thread {thread_id} keeps its title: {err}")
            if outcome == "ambiguous":
                # The write may have landed; the attempt lets the next pass
                # tell our own write from the captain's, and its pace counts
                # from when Discord stopped answering.
                return save("failed", time.time() + RETRY_SECS, str(err), attempt=dict(attempt, at=time.time()))
            if outcome == "transient":
                return save("failed", time.time() + RETRY_SECS, str(err), attempt=None)
            return save("failed", 0.0, str(err), attempt=None,
                        refused={"name": target, "newest": view["newest"]})
        landed = dict(attempt, at=time.time())
        fields = dict(_written(landed, title.get("held", view["written"])), attempt=None, refused=None)
        due = 0.0
        if target != wanted["desired"]:
            due = max(landed["at"], float(title.get("paced_at") or 0) + PACE_SECS)
        return save("applied", due, **fields)
    mark_due(home, thread_id, time.time())
    return "moved"


# --- events and the loop step -----------------------------------------------------------

def judging_state(home: Path) -> str:
    """The one key check: on, off, inactive, or unknown (any failure)."""
    try:
        from .thread_autoname import judging_state as check
    except ImportError:
        from thread_autoname import judging_state as check
    return check(home)


def _eligible_records(home: Path) -> list[dict]:
    try:
        paths = sorted((poster.state_dir(home) / "ext-outbox").glob(f"*{poster._THREAD_RECORD_SUFFIX}"))
    except OSError:
        return []
    channel = poster.dedicated_channel(home)
    records = []
    for path in paths:
        record = poster._read_thread_record(path)
        if record and record.get("creator") != "adopted" \
                and (poster._creating_request(record).get("channel_id") or "") == channel:
            records.append(record)
    return records


def ledger_events(home: Path, summaries: dict[str, dict]) -> list[str]:
    """Mark due every thread whose decision posts changed since its last pass."""
    marked = []
    for record in _eligible_records(home):
        thread_id = record["topic_thread_id"]
        if (record.get("title") or {}).get("ledger", []) != _fingerprint(summaries.get(thread_id, {})):
            mark_due(home, thread_id)
            marked.append(thread_id)
    return marked


def safety_sweep(home: Path) -> list[str]:
    """Mark every eligible thread due now; the slow self-healing pass."""
    threads = [record["topic_thread_id"] for record in _eligible_records(home)]
    for thread_id in threads:
        mark_due(home, thread_id)
    return threads


def run_due(home: Path | None = None, **kwargs) -> list[str]:
    """Reconcile every thread whose due time has come; the loop's one step."""
    home = home or poster.firstmate_home()
    now = time.time()
    with _DUE_LOCK:
        ready = [thread for (where, thread), at in _DUE.items() if where == home and at <= now]
        for thread_id in ready:
            del _DUE[home, thread_id]
    if not ready:
        return []
    judging = kwargs.pop("judging", None) or judging_state(home)
    touched = []
    for thread_id in ready:
        try:
            outcome = reconcile(home, thread_id, judging=judging, **kwargs)
        except Exception as err:
            _log(f"thread {thread_id} keeps its title: {err}")
            mark_due(home, thread_id, time.time() + RETRY_SECS)
            continue
        if outcome == "applied":
            touched.append(thread_id)
    return touched
