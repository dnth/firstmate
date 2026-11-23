"""The one writer of Firstmate topic-thread titles.

docs/configuration.md, "Thread title reconciler", owns the contract: the
inputs, marker precedence, freshness, the captain's own words, and pacing.

Every other part of the plugin only updates a thread's inputs, kept in the
``title`` object of its ``<slug>.thread.json`` record:

- ``verdict``: the latest status for the thread with the message id it was
  judged through (``cutoff``), its ``source`` (``jev`` for an after-post
  judgment, ``explicit`` for a reply's own thread state while judging is off),
  its decision association, and any screened base from the naming model;
- ``base``: an independently requested explicit retitle;
- ``decisions``: the last open-count and closure time read from the decision
  ledger through ``bin/fm-ext-decision.sh threads``;
- ``manual_base``: the captain's own words, once seen, kept for good.

The rest of the object is the reconciler's own bookkeeping: the pace stamp,
Discord's next permitted write, a removed marker it respects, a write whose
answer was lost, the due time, and the last outcome.

``reconcile`` turns those inputs plus the live Discord title into the one
desired title and writes it only when it differs, within Discord's own rate
limits and our pace. ``run_due`` is the loop step that calls it; nothing else
in the plugin renames a thread.
"""

from __future__ import annotations

import json
import math
import sys
import threading
import time
import urllib.error
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
# Our own pace: one title change per thread per this many seconds, except a
# question mark an open decision button asks for.
PACE_SECS = 600.0
# When a transient Discord failure or an unreadable title stops a write, try
# again on the decision sweep's cadence; Discord's own limits come only from
# its headers and 429 replies.
RETRY_SECS = poster.DECISION_SWEEP_SECS

_DUE: dict[tuple[Path, str], float] = {}
_DUE_LOCK = threading.Lock()
_GLOBAL_AFTER: dict[Path, float] = {}


class RateLimited(Exception):
    """Discord refused a title request and said how long to wait."""

    def __init__(self, deadline: float, global_limit: bool = False, *, absolute: bool = False):
        super().__init__("discord rate limited")
        self.deadline = deadline
        self.global_limit = global_limit
        self.absolute = absolute

    def until(self, now: float) -> float:
        return max(now, self.deadline) if self.absolute else now + self.deadline


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


# --- what Firstmate has posted -------------------------------------------------

def _accepted_chunks(home: Path):
    outbox = poster.state_dir(home) / "ext-outbox"
    if outbox.is_symlink() or not outbox.is_dir():
        return
    for path in outbox.glob("*.progress.json"):
        if path.is_symlink():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or not isinstance(data.get("discord_message_ids"), list):
            continue
        request = str(data.get("request_id") or "").split(":")
        thread_id = str(data.get("topic_thread_id") or (request[3] if len(request) > 3 else ""))
        if poster._SNOWFLAKE.fullmatch(thread_id):
            yield thread_id, data["discord_message_ids"]


def firstmate_messages(home: Path) -> dict[str, int]:
    """The newest Discord-accepted Firstmate message id per destination thread."""
    newest: dict[str, int] = {}
    for thread_id, ids in _accepted_chunks(home):
        top = max((_id(item) for item in ids), default=0)
        if top > newest.get(thread_id, 0):
            newest[thread_id] = top
    return newest


def fresh(home: Path, thread_id: str, cutoff: object) -> bool:
    """True when no Firstmate message newer than ``cutoff`` reached Discord."""
    return firstmate_messages(home).get(thread_id, 0) <= _id(cutoff)


# --- inputs ----------------------------------------------------------------------

def mark_due(home: Path, thread_id: str, at: float = 0.0) -> None:
    """Ask the reconciler to look at a thread no earlier than ``at``."""
    with _DUE_LOCK:
        key = (home, thread_id)
        _DUE[key] = min(at, _DUE.get(key, at))


def _update(home: Path, thread_id: str, change) -> bool:
    """Apply ``change(title, record)`` to a thread's inputs; False when absent.

    ``change`` returns False to leave the record untouched. Every accepted
    change bumps the input revision and makes the thread due now.
    """
    with poster._THREAD_RECORD_LOCK:
        record = poster.load_thread_record_by_id(thread_id, home)
        if not record:
            return False
        title = dict(record.get("title") or {})
        if change(title, record) is False:
            return False
        title["rev"] = int(title.get("rev") or 0) + 1
        title["due_at"] = time.time()
        poster.save_thread_record(record["path"], record.get("request_id"), thread_id, title=title)
    mark_due(home, thread_id)
    return True


def title_inputs(record: dict) -> dict:
    """Translate pending intent from a record written before the reconciler."""
    title = record.get("title")
    if isinstance(title, dict):
        return title
    title = {}
    rename = record.get("rename")
    rename = rename if isinstance(rename, dict) else {}
    state = record.get("deferred_state")
    if state not in ("none", "done"):
        state = {"deferred": rename.get("state"), "failed": record.get("thread_state")}.get(rename.get("outcome"))
    status = EXPLICIT_STATUS.get(state) if isinstance(state, str) else None
    if status is not None:
        title["verdict"] = {"source": "explicit", "status": status,
                            "during_decision": status == "open-question" and record.get("marked_open") is True}
    if record.get("marked_open") is True:
        title["decision_marked"] = True
    retitle = record.get("retitle")
    if isinstance(retitle, str) and retitle and rename.get("outcome") in ("failed", "deferred"):
        _, failed_base = split_marker(str(rename.get("name") or ""))
        if rename.get("retitle", retitle == failed_base):
            title["base"] = retitle
    if title:
        title["due_at"] = 1.0
    return title


def _during_decision(home: Path, thread_id: str, cutoff: str, status: str, decision: bool,
                     summaries: dict | None = None) -> bool | None:
    if status != "open-question":
        return False
    if decision:
        return True
    if summaries is None:
        summaries = poster.decision_threads(home, thread_id)
        if summaries is None:
            return None
    cutoff_id = _id(cutoff)
    cutoff_at = (cutoff_id >> 22) / 1000 + 1420070400
    return any(0 < _id(post["message_id"]) <= cutoff_id
               and (post["state"] == "open" or cutoff_at < post["closed_at"])
               for post in summaries.get(thread_id, {}).get("posts", ()))


def _set_verdict(home: Path, thread_id: str, title: dict, verdict: dict) -> None:
    prior = title.get("verdict") or {}
    if verdict["during_decision"] and prior and prior.get("status") != "open-question":
        cutoff = _id(verdict["cutoff"])
        previous = max((_id(item) for target, ids in _accepted_chunks(home) if target == thread_id
                        for item in ids if 0 < _id(item) < cutoff), default=0)
        both_explicit = prior.get("source") == verdict["source"] == "explicit"
        if both_explicit or (previous and _id(prior.get("cutoff")) == previous):
            verdict["status"] = prior["status"]
            verdict["during_decision"] = False
    title["verdict"] = verdict


def record_explicit(home: Path, thread_id: str, state: str | None, retitle: str,
                    message_id: str, decision: bool = False) -> bool:
    """A reply's own thread state and retitle, used while judging is off."""
    status = EXPLICIT_STATUS.get(state or "")
    if status is None and not retitle:
        return False
    during = _during_decision(home, thread_id, message_id, status or "", decision)
    if during is None:
        return False

    def change(title, _record):
        if status is not None:
            _set_verdict(home, thread_id, title, {"status": status, "source": "explicit",
                         "cutoff": str(message_id), "during_decision": during})
        if retitle:
            title["base"] = retitle
        return True

    return _update(home, thread_id, change)


def record_verdict(home: Path, thread_id: str, status: str, topic_fits: bool,
                   cutoff: str, base: str = "", decision: bool = False, summaries: dict | None = None) -> str:
    """Store a fresh Jev verdict, with any new base bound to its cutoff."""
    if status not in STATUS_MARKER or status == "none":
        raise ValueError(f"unknown status {status!r}")
    if not poster.load_thread_record_by_id(thread_id, home):
        return "gone"
    during = _during_decision(home, thread_id, cutoff, status, decision, summaries)
    if during is None:
        return "unreadable"

    def change(title, _record):
        prior = title.get("verdict") or {}
        if not fresh(home, thread_id, cutoff) or (
                prior.get("source") == "jev" and _id(prior.get("cutoff")) >= _id(cutoff)):
            return False
        _set_verdict(home, thread_id, title, {"status": status, "source": "jev", "cutoff": str(cutoff),
                     "topic_fits": bool(topic_fits), "base": base, "during_decision": during})
        return True

    return "recorded" if _update(home, thread_id, change) else "stale"


def _decision_input(summary: dict) -> dict:
    return {"open": int(summary.get("open", 0)), "open_buttons": int(summary.get("open_buttons", 0)),
            "last_closed_at": float(summary.get("last_closed_at") or 0)}


def _decision_snapshot(summary: dict) -> tuple:
    return (summary.get("open", 0), summary.get("open_buttons", 0),
            tuple((post["message_id"], post["state"], post["buttons"], post["closed_at"])
                  for post in summary.get("posts", ())))


def sweep_decisions(home: Path, summaries: dict[str, dict], now: float | None = None) -> list[str]:
    """Refresh every eligible thread's decision input from one ledger read.

    Also re-queues any thread whose recorded due time has come, so a restart
    resumes the reconciler's waits. Returns the threads it marked due.
    """
    now = time.time() if now is None else now
    channel = poster.dedicated_channel(home)
    marked = []
    for path in _record_paths(home):
        record = poster._read_thread_record(path)
        if not record or record.get("creator") == "adopted":
            continue
        if (poster._creating_request(record).get("channel_id") or "") != channel:
            continue
        thread_id = record["topic_thread_id"]
        summary = summaries.get(thread_id, {})
        seen = _decision_input(summary)
        title = record.get("title") or {}
        if (title.get("decisions") or _decision_input({})) != seen:
            _update(home, thread_id, lambda t, _r, seen=seen: t.__setitem__("decisions", seen))
            marked.append(thread_id)
        elif float(title.get("due_at") or 0) and float(title["due_at"]) <= now:
            mark_due(home, thread_id, float(title["due_at"]))
            marked.append(thread_id)
    return marked


def _record_paths(home: Path) -> list[Path]:
    try:
        return sorted((poster.state_dir(home) / "ext-outbox").glob(f"*{poster._THREAD_RECORD_SUFFIX}"))
    except OSError:
        return []


# --- Discord ----------------------------------------------------------------------

def _seconds(value: object) -> float | None:
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    return seconds if math.isfinite(seconds) and seconds >= 0 else None


def read_rate_limit(err: urllib.error.HTTPError) -> RateLimited | None:
    try:
        details = json.loads(err.read())
    except (OSError, UnicodeError, ValueError):
        details = {}
    if not isinstance(details, dict):
        details = {}
    headers = err.headers or {}
    global_limit = (details.get("global") is True or headers.get("X-RateLimit-Global") == "true"
                    or headers.get("X-RateLimit-Scope") == "global")
    waits = [_seconds(value) for value in (details.get("retry_after"), headers.get("Retry-After"),
                                         headers.get("X-RateLimit-Reset-After"))]
    wait = max((value for value in waits if value is not None), default=None)
    if wait is not None:
        return RateLimited(wait, global_limit)
    reset = _seconds(headers.get("X-RateLimit-Reset"))
    return RateLimited(reset, global_limit, absolute=True) if reset is not None else None


def discord_write_title(thread_id: str, name: str) -> dict:
    """PATCH one thread's name and return Discord's rate-limit view.

    Returns ``{"remaining": int | None, "reset_after": float | None}`` from
    the ``X-RateLimit-*`` headers. Raises RateLimited on HTTP 429 with the
    wait Discord named (``retry_after`` in the body, else ``Retry-After`` or
    ``X-RateLimit-Reset-After``), and DiscordSendError for anything else.
    """
    token = poster._bot_token()
    if not token:
        raise poster.DiscordSendError("transient", "missing DISCORD_BOT_TOKEN")
    if not poster._SNOWFLAKE.fullmatch(thread_id):
        raise poster.DiscordSendError("permanent", "thread id is not a Discord id")
    request = urllib.request.Request(
        f"{poster.DISCORD_API_BASE}/channels/{thread_id}",
        data=json.dumps({"name": name}).encode("utf-8"),
        method="PATCH",
        headers={"Authorization": f"Bot {token}", "Content-Type": "application/json",
                 "User-Agent": poster.USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            headers = response.headers
            response.read()
    except urllib.error.HTTPError as err:
        if err.code == 429:
            limit = read_rate_limit(err)
            if limit is not None:
                raise limit from err
        raise poster.DiscordSendError(poster.classify_http_code(err.code), f"discord HTTP {err.code}",
                                      err.code) from err
    except (urllib.error.URLError, TimeoutError, OSError) as err:
        raise poster.DiscordSendError("ambiguous", f"discord transport: {err}") from err
    remaining = headers.get("X-RateLimit-Remaining")
    return {"remaining": int(remaining) if str(remaining or "").isdigit() else None,
            "reset_after": _seconds(headers.get("X-RateLimit-Reset-After")),
            "reset": _seconds(headers.get("X-RateLimit-Reset"))}


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
    try:
        owner_id = (thread_owner or poster.discord_thread_owner)(record["topic_thread_id"])
    except RateLimited:
        raise
    except Exception as err:
        _log(f"thread {record['topic_thread_id']} owner lookup skipped: {err}")
        return False
    if not owner_id or owner_id != poster._bot_user_id():
        return False
    poster.save_thread_record(record["path"], record.get("request_id"), record["topic_thread_id"],
                              creator="firstmate")
    return True


def _marker(title: dict, summary: dict, live_marker: str, verdict: dict | None) -> str:
    """The marker the inputs ask for, by precedence."""
    candidates = []
    if int(summary.get("open", 0)) > 0:
        candidates.append(QUESTION)
    if verdict:
        marker = STATUS_MARKER.get(verdict.get("status"), live_marker)
        if marker == QUESTION and verdict.get("during_decision") and not candidates:
            # A question asked while a decision was open belongs to that
            # decision, and the ledger has closed every decision since.
            marker = ""
        candidates.append(marker)
    elif title.get("decision_marked") and not candidates:
        # Our question mark was the decision's; with no verdict to follow,
        # closing the last decision takes it off.
        candidates.append("")
    else:
        candidates.append(live_marker)
    return min(candidates, key=PRECEDENCE.index)


def captain_named(record: dict, live: str) -> bool:
    """True once the captain's own words name the thread.

    Either they are already kept, or the live base differs from the last
    base this home wrote (and the live title is not our own pending write).
    """
    title = record.get("title") or {}
    if title.get("manual_base"):
        return True
    written = record.get("topic_name") or ""
    pending = title.get("pending") or {}
    if not written or not live or pending.get("name") == live:
        return False
    return split_marker(live)[1] != split_marker(written)[1]


def _global_after(home: Path) -> float:
    if home not in _GLOBAL_AFTER:
        _GLOBAL_AFTER[home] = max(
            (float((poster._read_thread_record(path).get("title") or {}).get("discord_global_after") or 0)
             for path in _record_paths(home)), default=0.0)
    return _GLOBAL_AFTER[home]


def _written_fields(attempt: dict, at: float) -> dict:
    fields = {"pending": None, "decision_marked": attempt["decision"] or None,
              "observed": attempt["name"]}
    if not attempt["priority"]:
        fields["paced_at"] = at
    return fields


def reconcile(home: Path, thread_id: str, *, now: float | None = None, rename=None,
              read_thread=None, thread_owner=None) -> str:
    """Bring one thread's Discord title to the title its inputs ask for."""
    clock = time.time if now is None else lambda: now
    record = poster.load_thread_record_by_id(thread_id, home)
    if not record:
        return "skipped"
    title = dict(record.get("title") or {})
    rev = int(title.get("rev") or 0)
    inputs: dict = {}
    seen: dict = {}
    written = ""

    def finish(outcome: str, due: float = 0.0, error: str = "", **fields) -> str:
        last = {"outcome": outcome, "at": clock()}
        if error:
            last["error"] = error
        fields.update(due_at=due, last=last)
        with poster._THREAD_RECORD_LOCK:
            current = poster.load_thread_record_by_id(thread_id, home)
            if not current:
                return outcome
            merged = dict(current.get("title") or {})
            merged.update(seen)
            if int(merged.get("rev") or 0) == rev:
                merged.update(inputs)
            else:
                fields["due_at"] = last["at"]
            merged.update(fields)
            for key in [key for key, value in merged.items() if value is None]:
                del merged[key]
            poster.save_thread_record(current["path"], current.get("request_id"), thread_id,
                                      topic_name=written, title=merged)
            due = float(merged.get("due_at") or 0)
        if due:
            mark_due(home, thread_id, due)
        return outcome

    def rate_limited(err: RateLimited, **fields) -> str:
        response_at = clock()
        until = err.until(response_at)
        _log(f"thread {thread_id} waits {until - response_at:.1f}s for Discord before writing its title")
        if err.global_limit:
            _GLOBAL_AFTER[home] = until
            fields["discord_global_after"] = until
        return finish("rate-limited", until, error=str(err), discord_after=until, **fields)

    allowed = max(_global_after(home), float(title.get("discord_after") or 0))
    if clock() < allowed:
        return finish("waiting", allowed)
    try:
        if not eligible(record, home, thread_owner):
            return "skipped"
        live = (read_thread or poster.discord_thread_name)(thread_id)
    except RateLimited as err:
        return rate_limited(err)
    except Exception:
        live = ""
    if not live:
        return finish("unreadable", clock() + RETRY_SECS, error="live title unreadable")

    decision_view = poster.decision_threads(home, thread_id)
    if decision_view is None:
        return finish("unreadable", clock() + RETRY_SECS, error="decision ledger unreadable")
    summary = decision_view.get(thread_id, {})
    inputs["decisions"] = _decision_input(summary)
    accepted = firstmate_messages(home).get(thread_id, 0)
    live_marker, live_base = split_marker(live)
    bot_name = record.get("topic_name") or ""
    if pending := title.get("pending"):
        if pending["name"] == live:
            bot_name = written = live
            recovered = _written_fields(pending, pending.get("at") or clock())
            title.update(recovered)
            seen.update(recovered)
        seen["pending"] = None

    if bot_name:
        bot_marker, bot_base = split_marker(bot_name)
        observed_marker, observed_base = split_marker(title.get("observed") or bot_name)
        if live_base != (observed_base if title.get("manual_base") else bot_base):
            title["manual_base"] = seen["manual_base"] = live_base
        if bot_marker and observed_marker and not live_marker:
            title["respect"] = seen["respect"] = bot_marker
    seen["observed"] = live

    verdict = title.get("verdict") or None
    if verdict and verdict.get("source") == "jev" and accepted > _id(verdict.get("cutoff")):
        verdict = None
    marker = _marker(title, summary, live_marker, verdict)
    decision_question = marker == QUESTION and inputs["decisions"]["open"] > 0
    if respect := title.get("respect"):
        if marker == respect:
            marker = live_marker
        elif verdict or inputs["decisions"]["open"] or title.get("decision_marked"):
            inputs["respect"] = None

    proposed = (verdict or {}).get("base") or title.get("base") or ""
    base = title.get("manual_base") or live_base
    if not title.get("manual_base") and proposed and poster.screened_title(proposed, home) == proposed:
        base = proposed
    desired = marker + base
    if desired == live:
        if title.get("base") == base:
            inputs["base"] = None
        return finish("unchanged", decision_marked=decision_question or None)

    priority = (decision_question and marker == QUESTION and live_marker != QUESTION
                and inputs["decisions"]["open_buttons"] > 0)
    target = QUESTION + live_base if priority else desired
    paced_at = float(title.get("paced_at") or 0)
    if not priority and paced_at and clock() < paced_at + PACE_SECS:
        return finish("waiting", paced_at + PACE_SECS)

    decision_view = poster.decision_threads(home, thread_id)
    if decision_view is None:
        inputs.clear()
        return finish("unreadable", clock() + RETRY_SECS, error="decision ledger unreadable")
    with poster._THREAD_RECORD_LOCK:
        current = poster.load_thread_record_by_id(thread_id, home)
        if not current:
            return "skipped"
        current_title = current.get("title") or {}
        if (int(current_title.get("rev") or 0) != rev
                or _decision_snapshot(decision_view.get(thread_id, {})) != _decision_snapshot(summary)
                or firstmate_messages(home).get(thread_id, 0) != accepted):
            inputs.clear()
            return finish("waiting", clock())
        attempt = {"name": target, "decision": decision_question, "priority": priority}
        poster.save_thread_record(current["path"], current.get("request_id"), thread_id,
                                  title=dict(current_title, pending=attempt))
    try:
        limits = (rename or discord_write_title)(thread_id, target) or {}
    except RateLimited as err:
        return rate_limited(err, pending=None)
    except Exception as err:
        outcome = poster.classify_send_failure(err)
        _log(f"thread {thread_id} keeps its title: {err}")
        failed_at = clock()
        pending = dict(attempt, at=failed_at) if outcome == "ambiguous" else None
        due = failed_at + RETRY_SECS if outcome in ("ambiguous", "transient") else 0.0
        return finish("failed", due, error=str(err), pending=pending)

    landed_at = clock()
    written = target
    fields = _written_fields(attempt, landed_at)
    if isinstance(limits, dict) and limits.get("remaining") == 0:
        reset_after = limits.get("reset_after")
        reset = landed_at + reset_after if reset_after is not None else limits.get("reset")
        if reset is not None:
            fields["discord_after"] = reset
    if target == desired and title.get("base") == base:
        inputs["base"] = None
    due = max(landed_at, paced_at + PACE_SECS, fields.get("discord_after", 0)) if target != desired else 0.0
    return finish("applied", due, **fields)


def run_due(home: Path | None = None, now: float | None = None, **kwargs) -> list[str]:
    """Reconcile every thread whose due time has come; the loop's one step."""
    home = home or poster.firstmate_home()
    ready_at = time.time() if now is None else now
    with _DUE_LOCK:
        ready = [thread for (where, thread), at in _DUE.items() if where == home and at <= ready_at]
        for thread_id in ready:
            del _DUE[home, thread_id]
    touched = []
    for thread_id in ready:
        try:
            outcome = reconcile(home, thread_id, now=now, **kwargs)
        except Exception as err:
            _log(f"thread {thread_id} keeps its title: {err}")
            mark_due(home, thread_id, (time.time() if now is None else now) + RETRY_SECS)
            continue
        if outcome == "applied":
            touched.append(thread_id)
    return touched
