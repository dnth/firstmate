"""The one writer of Firstmate topic-thread titles.

docs/configuration.md, "Thread title reconciler", owns the contract: the
inputs, marker precedence, freshness, the captain's own words, and pacing.

Every other part of the plugin only updates a thread's inputs, kept in the
``title`` object of its ``<slug>.thread.json`` record:

- ``verdict``: the latest status for the thread with the message id it was
  judged through (``cutoff``), its ``source`` (``jev`` for an after-post
  judgment, ``explicit`` for a reply's own thread state while judging is off),
  and ``during_decision`` once known;
- ``base``: a new screened base name from the naming model or a retitle;
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


class RateLimited(Exception):
    """Discord refused a write with HTTP 429 and said how long to wait."""

    def __init__(self, retry_after: float):
        super().__init__(f"discord rate limited; retry after {retry_after}s")
        self.retry_after = retry_after


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

def firstmate_messages(home: Path) -> dict[str, int]:
    """The newest Discord-accepted Firstmate message id per destination thread.

    Chunk progress records each message id as soon as Discord accepts it,
    before the whole reply's receipt, so a visible post counts even while its
    receipt is pending or a later chunk failed.
    """
    newest: dict[str, int] = {}
    outbox = poster.state_dir(home) / "ext-outbox"
    if outbox.is_symlink() or not outbox.is_dir():
        return newest
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
        if not poster._SNOWFLAKE.fullmatch(thread_id):
            continue
        top = max((_id(item) for item in data["discord_message_ids"]), default=0)
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


def _set_verdict(title: dict, verdict: dict, decision: bool) -> None:
    """Make ``verdict`` the latest one, unless it only repeats a decision's question.

    A question that comes with a decision post, or while a decision is open,
    belongs to that decision: it never replaces a kept status, so a done
    judged during the decision still lands when the last decision closes. The
    kept status stays current through the newer post that only asked again.
    """
    prior = title.get("verdict") or {}
    open_now = int((title.get("decisions") or {}).get("open", 0)) > 0
    if verdict["status"] == "open-question" and (decision or open_now):
        if prior and prior.get("status") != "open-question":
            title["verdict"] = dict(prior, cutoff=verdict["cutoff"])
            return
        verdict["during_decision"] = True
    title["verdict"] = verdict


def record_explicit(home: Path, thread_id: str, state: str | None, retitle: str,
                    message_id: str, decision: bool = False) -> bool:
    """A reply's own thread state and retitle, used while judging is off."""
    status = EXPLICIT_STATUS.get(state or "")

    def change(title, _record):
        if status is None and not retitle:
            return False
        if status is not None:
            _set_verdict(title, {"status": status, "source": "explicit", "cutoff": str(message_id)}, decision)
        if retitle:
            title["base"] = retitle
        return True

    return _update(home, thread_id, change)


def record_verdict(home: Path, thread_id: str, status: str, topic_fits: bool,
                   cutoff: str, base: str = "", decision: bool = False) -> str:
    """Store a Jev verdict judged through ``cutoff``; drop it when stale.

    ``decision`` says the judged post carried a decision. Returns recorded,
    stale (a newer Firstmate post reached Discord, or a newer verdict is
    already stored), or gone (no thread record).
    """
    if status not in STATUS_MARKER or status == "none":
        raise ValueError(f"unknown status {status!r}")

    def change(title, _record):
        prior = title.get("verdict") or {}
        if not fresh(home, thread_id, cutoff) or (
                prior.get("source") == "jev" and _id(prior.get("cutoff")) > _id(cutoff)):
            return False
        _set_verdict(title, {"status": status, "source": "jev", "cutoff": str(cutoff),
                             "topic_fits": bool(topic_fits)}, decision)
        if base:
            title["base"] = base
        return True

    if not poster.load_thread_record_by_id(thread_id, home):
        return "gone"
    return "recorded" if _update(home, thread_id, change) else "stale"


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
        seen = {"open": int(summary.get("open", 0)),
                "last_closed_at": float(summary.get("last_closed_at", 0) or 0)}
        title = record.get("title") or {}
        if (title.get("decisions") or {"open": 0, "last_closed_at": 0.0}) != seen:
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
    return seconds if seconds >= 0 else None


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
        try:
            details = json.loads(err.read().decode("utf-8"))
        except (OSError, UnicodeError, ValueError):
            details = {}
        if not isinstance(details, dict):
            details = {}
        if err.code == 429:
            wait = _seconds(details.get("retry_after"))
            for header in ("Retry-After", "X-RateLimit-Reset-After"):
                if wait is None and err.headers is not None:
                    wait = _seconds(err.headers.get(header))
            if wait is not None:
                raise RateLimited(wait) from err
        raise poster.DiscordSendError(poster.classify_http_code(err.code), f"discord HTTP {err.code}",
                                      err.code, details) from err
    except (urllib.error.URLError, TimeoutError, OSError) as err:
        raise poster.DiscordSendError("ambiguous", f"discord transport: {err}") from err
    remaining = headers.get("X-RateLimit-Remaining")
    return {"remaining": int(remaining) if str(remaining or "").isdigit() else None,
            "reset_after": _seconds(headers.get("X-RateLimit-Reset-After"))}


# --- the reconciler -----------------------------------------------------------------

def _eligible(record: dict, home: Path, thread_owner) -> bool:
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
    if not written or not live or title.get("pending") == live:
        return False
    return split_marker(live)[1] != split_marker(written)[1]


def reconcile(home: Path, thread_id: str, *, now: float | None = None, rename=None,
              read_thread=None, thread_owner=None, summaries: dict | None = None) -> str:
    """Bring one thread's Discord title to the title its inputs ask for.

    Returns unchanged, applied, waiting (our pace or Discord's limit holds
    the write; the thread is due again then), rate-limited, failed,
    unreadable, or skipped. Every failure leaves the title as it is.
    """
    now = time.time() if now is None else now
    record = poster.load_thread_record_by_id(thread_id, home)
    if not _eligible(record, home, thread_owner):
        return "skipped"
    title = dict(record.get("title") or {})
    rev = int(title.get("rev") or 0)
    # Input clean-ups (a stale verdict, an unusable base) are kept only if no
    # newer input arrived meanwhile; what this pass saw on Discord always is.
    inputs: dict = {}
    seen: dict = {}
    shown = ""

    def finish(outcome: str, due: float = 0.0, error: str = "", topic_name: str = "",
               **fields) -> str:
        last = {"outcome": outcome, "at": now}
        if error:
            last["error"] = error
        fields.update(due_at=due, last=last)
        with poster._THREAD_RECORD_LOCK:
            current = poster.load_thread_record_by_id(thread_id, home)
            if not current:
                return outcome
            merged = dict(current.get("title") or {})
            if int(merged.get("rev") or 0) == rev:
                merged.update(inputs)
            else:
                # Inputs moved while Discord was busy: look again at once.
                fields["due_at"] = now
            merged.update(seen)
            merged.update(fields)
            for key in [key for key, value in merged.items() if value is None]:
                del merged[key]
            poster.save_thread_record(current["path"], current.get("request_id"), thread_id,
                                      topic_name=topic_name or shown, title=merged)
            due = float(merged.get("due_at") or 0)
        if due:
            mark_due(home, thread_id, due)
        return outcome

    discord_after = float(title.get("discord_after") or 0)
    if now < discord_after:
        return finish("waiting", discord_after)
    if summaries is None:
        summaries = poster.decision_threads(home, thread_id)
        if summaries is None:
            return finish("unreadable", now + RETRY_SECS, error="decision ledger unreadable")
    summary = summaries.get(thread_id, {})
    seen["decisions"] = {"open": int(summary.get("open", 0)),
                         "last_closed_at": float(summary.get("last_closed_at", 0) or 0)}
    try:
        live = (read_thread or poster.discord_thread_name)(thread_id)
    except Exception:
        live = ""
    if not live:
        return finish("unreadable", now + RETRY_SECS, error="live title unreadable")
    shown = live
    live_marker, live_base = split_marker(live)

    written = record.get("topic_name") or ""
    if title.get("pending"):
        if title["pending"] == live:
            # Our last write landed even though Discord's answer was lost.
            written = live
        seen["pending"] = None
    if written:
        written_marker, written_base = split_marker(written)
        if live_base != written_base:
            # The captain renamed the thread: his words stay for good.
            title["manual_base"] = seen["manual_base"] = live_base
        if written_marker and not live_marker:
            # The captain took our marker off: respected until ours changes.
            title["respect"] = seen["respect"] = written_marker

    verdict = title.get("verdict") or None
    if verdict and verdict.get("source") == "jev" and not fresh(home, thread_id, verdict.get("cutoff")):
        # Stale: a newer Firstmate post reached Discord. It is never applied;
        # it stays only so a newer judgment of that post can confirm it.
        verdict = None
    if verdict and "during_decision" not in verdict:
        # First seen while a decision is open: it belongs to that decision.
        verdict = inputs["verdict"] = dict(verdict, during_decision=int(summary.get("open", 0)) > 0)
    marker = _marker(title, summary, live_marker, verdict)
    if "respect" in title:
        if marker == title["respect"]:
            marker = live_marker
        else:
            seen["respect"] = None
    decision_question = marker == QUESTION and int(summary.get("open", 0)) > 0

    base = title.get("manual_base") or ""
    if not base:
        wanted = title.get("base") or ""
        base = live_base
        if wanted and wanted != live_base:
            if poster.screened_title(wanted, home) == wanted:
                base = wanted
            else:
                inputs["base"] = None
    desired = marker + base
    if desired == live:
        return finish("unchanged", decision_marked=decision_question or None)

    target = desired
    priority = decision_question and live_marker != QUESTION
    paced_at = float(title.get("paced_at") or 0)
    if priority:
        # Only the question mark skips our pace; any base change waits.
        target = QUESTION + live_base
    elif paced_at and now < paced_at + PACE_SECS:
        return finish("waiting", paced_at + PACE_SECS)

    with poster._THREAD_RECORD_LOCK:
        current = poster.load_thread_record_by_id(thread_id, home)
        if not current:
            return "skipped"
        poster.save_thread_record(current["path"], current.get("request_id"), thread_id,
                                  title=dict(current.get("title") or {}, pending=target))
    try:
        limits = (rename or discord_write_title)(thread_id, target) or {}
    except RateLimited as err:
        _log(f"thread {thread_id} waits {err.retry_after:.1f}s for Discord before writing its title")
        return finish("rate-limited", now + err.retry_after, error=str(err),
                      discord_after=now + err.retry_after, pending=None)
    except Exception as err:
        outcome = poster.classify_send_failure(err)
        _log(f"thread {thread_id} keeps its title: {err}")
        if outcome == "ambiguous":
            # The write may have landed; the pending title lets the next pass
            # tell our own write from the captain's.
            return finish("failed", now + RETRY_SECS, error=str(err), pending=target)
        return finish("failed", now + RETRY_SECS if outcome == "transient" else 0.0,
                      error=str(err), pending=None)
    fields = {"pending": None, "decision_marked": decision_question or None}
    if not priority:
        fields["paced_at"] = paced_at = now
    if isinstance(limits, dict) and limits.get("remaining") == 0 and limits.get("reset_after") is not None:
        fields["discord_after"] = now + float(limits["reset_after"])
    due = 0.0
    if target != desired:
        due = max(now, paced_at + PACE_SECS if paced_at else now, fields.get("discord_after") or now)
    return finish("applied", due, topic_name=target, **fields)


def run_due(home: Path | None = None, now: float | None = None, **kwargs) -> list[str]:
    """Reconcile every thread whose due time has come; the loop's one step."""
    home = home or poster.firstmate_home()
    now = time.time() if now is None else now
    with _DUE_LOCK:
        ready = [thread for (where, thread), at in _DUE.items() if where == home and at <= now]
        for thread_id in ready:
            del _DUE[home, thread_id]
    touched = []
    for thread_id in ready:
        try:
            outcome = reconcile(home, thread_id, now=now, **kwargs)
        except Exception as err:
            _log(f"thread {thread_id} keeps its title: {err}")
            mark_due(home, thread_id, now + RETRY_SECS)
            continue
        if outcome == "applied":
            touched.append(thread_id)
    return touched
