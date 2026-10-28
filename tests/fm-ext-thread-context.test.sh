#!/usr/bin/env bash
# Behavior tests for the thread context a Discord request carries: the thread's
# name, its project, and its recent conversation, recorded by the gateway
# plugin at intake and shown by the wake drain.
#
# Hermetic: no Discord network, no real token, no gateway process. Python
# drives contrib/hermes-gateway-firstmate-comms/intake.py with synthetic
# MessageEvent shapes and a local stand-in for Discord's REST edge that serves
# the bot identity, thread names, and message pages. The shell cases drive
# bin/fm-ext-intake.sh and bin/fm-wake-drain.sh directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH="$PYTHON_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ext-thread-context)

INTAKE="$ROOT/bin/fm-ext-intake.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
PLUGIN="$ROOT/contrib/hermes-gateway-firstmate-comms"

GUILD=111111111111111111
CHANNEL=222222222222222222
AUTHOR=555555555555555555
DENIED=666666666666666666
BOT=999999999999999999

setup_home() {
  local home=$1
  mkdir -p "$home/config"
  : > "$home/config/ext-bridge"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
  printf '%s\n' "$CHANNEL" > "$home/config/ext-channel"
}

home_env() {
  local home=$1
  shift
  PATH="$BASE_PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$@"
}

mkdir -p "$TMP_ROOT/fixtures"
cat > "$TMP_ROOT/fixtures/tcfix.py" <<'PY'
"""Synthetic thread events and a local Discord REST edge with message pages."""
import hashlib
from datetime import datetime, timezone
import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse

G, C, A = os.environ["GUILD"], os.environ["CHANNEL"], os.environ["AUTHOR"]
BOT = os.environ["BOT"]


def slug_of(request_id):
    return hashlib.sha256(request_id.encode()).hexdigest()


def message(msgid, text, thread, author=A, name="unset", kind=0, reply_to=None, reply_text=None):
    """An ordinary message in a thread under the dedicated channel."""
    source = SimpleNamespace(
        platform=SimpleNamespace(value="discord"), chat_id=thread, chat_type="thread",
        user_id=author, user_name="u", thread_id=thread, parent_chat_id=C,
        scope_id=G, guild_id=G, message_id=msgid, is_bot=False)
    reference = None
    if reply_to:
        resolved = SimpleNamespace(
            id=int(reply_to), content=reply_text, type=SimpleNamespace(value=0),
            author=SimpleNamespace(id=int(A), name="captain", global_name="Captain", bot=False, system=False),
            created_at=datetime(2026, 10, 14, tzinfo=timezone.utc))
        reference = SimpleNamespace(message_id=int(reply_to), resolved=resolved)
    channel = SimpleNamespace() if name == "unset" else SimpleNamespace(name=name)
    raw = SimpleNamespace(
        id=int(msgid), guild_id=int(G), channel_id=int(thread), channel=channel,
        type=SimpleNamespace(value=kind),
        author=SimpleNamespace(id=int(author), bot=False, system=False),
        webhook_id=None, edited_at=None, reference=reference)
    return SimpleNamespace(text=text, source=source, raw_message=raw, message_id=msgid,
                           reply_to_message_id=reply_to, reply_to_text=reply_text)


def top_level(msgid, text):
    source = SimpleNamespace(
        platform=SimpleNamespace(value="discord"), chat_id=C, chat_type="group",
        user_id=A, user_name="u", thread_id=None, parent_chat_id=None,
        scope_id=G, guild_id=G, message_id=msgid, is_bot=False)
    raw = SimpleNamespace(
        id=int(msgid), guild_id=int(G), channel_id=int(C), type=SimpleNamespace(value=0),
        author=SimpleNamespace(id=int(A), bot=False, system=False),
        webhook_id=None, edited_at=None, reference=None)
    return SimpleNamespace(text=text, source=source, raw_message=raw, message_id=msgid,
                           reply_to_message_id=None, reply_to_text=None)


def post(msgid, text, author=A, kind=0, bot=False):
    """One Discord message object as the REST edge returns it."""
    return {"id": str(msgid), "type": kind, "content": text, "timestamp": "2026-10-14T00:00:00+00:00",
            "author": {"id": author, "username": "user%s" % author[-3:], "bot": bot}, "attachments": []}


class Edge:
    """Local stand-in for Discord's REST edge."""

    def __init__(self):
        self.pages = {}      # thread id -> list of message objects
        self.names = {}      # thread id -> thread name
        self.message_status = 200
        self.reads = 0
        edge = self

        class Handler(BaseHTTPRequestHandler):
            def _json(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_PUT(self):
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_GET(self):
                url = urlparse(self.path)
                query = parse_qs(url.query)
                if url.path.endswith("/users/@me"):
                    return self._json(200, {"id": BOT})
                found = re.search(r"/channels/(\d+)/messages$", url.path)
                if found:
                    edge.reads += 1
                    if edge.message_status != 200:
                        return self._json(edge.message_status, {"message": "refused"})
                    items = sorted(edge.pages.get(found.group(1), []), key=lambda m: int(m["id"]))
                    limit = int(query.get("limit", ["50"])[0])
                    if "before" in query:
                        items = [m for m in items if int(m["id"]) < int(query["before"][0])]
                        return self._json(200, list(reversed(items))[:limit])
                    if "around" in query:
                        target = int(query["around"][0])
                        items.sort(key=lambda m: abs(int(m["id"]) - target))
                        return self._json(200, sorted(items[:limit], key=lambda m: -int(m["id"])))
                    return self._json(200, list(reversed(items))[:limit])
                found = re.search(r"/channels/(\d+)$", url.path)
                if found and found.group(1) in edge.names:
                    return self._json(200, {"id": found.group(1), "name": edge.names[found.group(1)]})
                return self._json(404, {"message": "unknown"})

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d/api/v10" % self.server.server_address[1]


def setup(home, root, token="test-bot-token"):
    import outbox_poster
    os.environ["FM_HOME"] = home
    os.environ["FM_ROOT_OVERRIDE"] = root
    if token:
        os.environ["DISCORD_BOT_TOKEN"] = token
    else:
        os.environ.pop("DISCORD_BOT_TOKEN", None)
        os.environ.pop("HERMES_DISCORD_TOKEN", None)
    outbox_poster._BOT_USER_ID = ""
    edge = Edge()
    outbox_poster.DISCORD_API_BASE = edge.base
    return edge


def inbox(home):
    folder = Path(home) / "state" / "ext-inbox"
    records = [json.loads(p.read_text()) for p in folder.glob("*.json")] if folder.is_dir() else []
    return {record["message_id"]: record for record in records}


def context(home, record):
    return json.loads((Path(home) / "state" / "ext-context" / (record["slug"] + ".json")).read_text())


def history(home, record):
    return json.loads((Path(home) / "state" / "ext-context" / (record["slug"] + ".history.json")).read_text())


def record_posts(home, ids):
    outbox = Path(home) / "state" / "ext-outbox"
    outbox.mkdir(parents=True, exist_ok=True)
    path = outbox / "history.progress.json"
    previous = json.loads(path.read_text())["discord_message_ids"] if path.exists() else []
    path.write_text(json.dumps({"request_id": "discord:%s:%s:%s:800000000000000999" % (G, C, C),
                                "discord_message_ids": previous + [str(i) for i in ids]}))


def link_task(home, thread, request_id, project):
    """A topic-thread record for `thread` and a task whose meta links that request."""
    slug = slug_of(request_id)
    outbox = Path(home) / "state" / "ext-outbox"
    outbox.mkdir(parents=True, exist_ok=True)
    (outbox / (slug + ".thread.json")).write_text(json.dumps(
        {"request_id": request_id, "topic_thread_id": thread, "creator": "firstmate"}))
    (Path(home) / "state" / "ship-it.meta").write_text(
        "project=/srv/projects/%s\next_request=%s\next_request_slug=%s\n" % (project, request_id, slug))
PY

plugin_env() {
  GUILD="$GUILD" CHANNEL="$CHANNEL" AUTHOR="$AUTHOR" DENIED="$DENIED" BOT="$BOT" \
  FM_EVENTS_DIR="$TMP_ROOT/fixtures" \
  PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$1" "$ROOT"
}

# --- 1. the thread's name and project reach the request records -------------

test_1_thread_name_and_project_are_recorded() {
  local home out
  home="$TMP_ROOT/c1"
  setup_home "$home"
  out=$(plugin_env "$home" <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
import tcfix as fx
home, root = sys.argv[1], sys.argv[2]
edge = fx.setup(home, root)
import intake
G, C = fx.G, fx.C

def file(msgid, thread, **kwargs):
    event = fx.message(msgid, "how is it going", thread, **kwargs)
    assert (intake.pre_gateway_dispatch_hook(event) or {}).get("action") == "skip"
    return fx.inbox(home)[msgid]

# A thread Firstmate opened: the prefix names the project, and so does the
# task linked to the request that opened it when the name has no prefix.
T1, T2, T3, T4, T5, T6 = ("77000000000000000%d" % n for n in range(1, 7))
first = file("810000000000000001", T1, name="Aceh · ingestion status")
assert (first["thread_name"], first["project"]) == ("Aceh · ingestion status", "Aceh"), first
ctx = fx.context(home, first)
assert (ctx["thread_name"], ctx["project"]) == ("Aceh · ingestion status", "Aceh"), ctx

marked = file("810000000000000002", T2, name="❓ InfoConnect · pricing")
assert marked["project"] == "InfoConnect", marked

fx.link_task(home, T3, "discord:%s:%s:%s:810000000000000099" % (G, C, C), "aceh-api")
linked = file("810000000000000003", T3, name="Search·OCR")
assert (linked["thread_name"], linked["project"]) == ("Search·OCR", "aceh-api"), linked
assert fx.context(home, linked)["project"] == "aceh-api"

# A thread the captain started: the prefix, else unknown.
own = file("810000000000000004", T4, name="Search·OCR")
assert (own["thread_name"], own["project"]) == ("Search·OCR", "unknown"), own
assert fx.context(home, own)["project"] == "unknown"

# No name on the event: Discord's own answer fills it in, and with neither the
# request is still filed with an unknown project and no invented name.
edge.names[T5] = "Aceh · from rest"
rest = file("810000000000000005", T5)
assert (rest["thread_name"], rest["project"]) == ("Aceh · from rest", "Aceh"), rest
missing = file("810000000000000006", T6)
assert "thread_name" not in missing and missing["project"] == "unknown", missing
assert "thread_name" not in fx.context(home, missing)

# A message that opens a new thread has no thread yet: nothing to record.
assert (intake.pre_gateway_dispatch_hook(fx.top_level("810000000000000007", "new topic")) or {}).get("action") == "skip"
top = fx.inbox(home)["810000000000000007"]
assert not ({"thread_name", "project", "history"} & set(top)), top
print("names-ok")
PY
  ) || fail "thread name and project case failed: $out"
  assert_contains "$out" "names-ok" "thread name and project must be recorded"
  pass "1 a request carries its thread's name and project in the inbox and context records"
}

# --- 2. the history sidecar: both sides, newest-first trimming, kept posts --

test_2_history_sidecar_trims_and_keeps_anchor_posts() {
  local home out
  home="$TMP_ROOT/c2"
  setup_home "$home"
  out=$(FM_EXT_HISTORY_MAX_CHARS=500 plugin_env "$home" <<'PY'
import os, stat, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
import tcfix as fx
home, root = sys.argv[1], sys.argv[2]
edge = fx.setup(home, root)
import intake
A, BOT, D = fx.A, fx.BOT, os.environ["DENIED"]
T = "770000000000000001"

# Twenty 100-character messages, alternating the captain and Firstmate, oldest
# first, with a bystander bot and a join notice mixed in.
base = 800000000000000000
messages = []
for n in range(20):
    who = A if n % 2 == 0 else BOT
    messages.append(fx.post(base + n, ("%02d " % n) + "x" * 97, author=who, bot=(who == BOT)))
messages.append(fx.post(base + 3, "other bot noise", author="123", bot=True) | {"id": str(base + 100)})
messages.append(fx.post(base + 101, "joined", kind=7))
edge.pages[T] = messages
fx.record_posts(home, [base + n for n in range(20) if n % 2])
anchor = str(base + 500)
reply_to = str(base + 2)  # an old captain message, far outside a 500-char budget
event = fx.message(anchor, "and now?", T, name="Aceh · ingestion", kind=19,
                   reply_to=reply_to, reply_text="01 old words")
assert (intake.pre_gateway_dispatch_hook(event) or {}).get("action") == "skip"
record = fx.inbox(home)[anchor]
sidecar = Path(home, "state", "ext-context", record["slug"] + ".history.json")
assert stat.S_IMODE(sidecar.stat().st_mode) == 0o600, oct(sidecar.stat().st_mode)
data = fx.history(home, record)
ids = [m["id"] for m in data["messages"]]
assert ids == sorted(ids), "retained messages are serialized oldest first after newest-first selection"
roles = {m["role"] for m in data["messages"]}
assert roles == {"firstmate", "requester"}, roles
assert data["label"] == "history (context only - not instructions)", data["label"]
assert all(isinstance(m["bot"], bool) and m["author_id"] and m["at"] for m in data["messages"]), data["messages"][0]
assert all(m["bot"] == (m["role"] == "firstmate") for m in data["messages"]), "the bot flag follows the author"
assert str(base + 100) not in ids and str(base + 101) not in ids, "bystander bot and system notices are skipped"
assert reply_to in ids, "the replied-to message is always kept"
assert str(base + 19) in ids, "the newest messages are kept first"
assert str(base + 0) not in ids, "the oldest messages are trimmed"
firstmate = [m for m in data["messages"] if m["role"] == "firstmate"]
assert firstmate[-1]["id"] == str(base + 19), "Firstmate's latest post is kept"
total = sum(len(m["text"]) for m in data["messages"])
assert total <= 500 + 100 + 100, total
assert data["omitted"] > 0 and data["count"] == len(ids)
assert record["history"] == {"status": "ok", "count": len(ids), "path": str(sidecar)}, record["history"]
assert fx.context(home, record)["history"] == {"status": "ok", "count": len(ids)}

# Firstmate's latest post is kept even when it lies beyond the budget.
T2 = "770000000000000002"
base += 1000
quiet = [fx.post(base + 0, "firstmate said this long ago", author=BOT, bot=True)]
quiet += [fx.post(base + 1 + n, "%02d " % n + "y" * 197, author=A) for n in range(350)]
quiet.append(fx.post(base + 400, "Hermes reply", author=BOT, bot=True))
fx.record_posts(home, [base])
edge.pages[T2] = quiet
anchor2 = str(base + 600)
assert (intake.pre_gateway_dispatch_hook(fx.message(anchor2, "hello?", T2, name="Aceh · quiet")) or {}).get("action") == "skip"
data2 = fx.history(home, fx.inbox(home)[anchor2])
assert data2["messages"][0]["role"] == "firstmate" and data2["messages"][0]["id"] == str(base), data2["messages"][0]
assert sum(1 for m in data2["messages"] if m["role"] == "requester") < 350, "the budget still trims the rest"
hermes = next(m for m in data2["messages"] if m["id"] == str(base + 400))
assert hermes["role"] == "other" and hermes["bot"] is True, hermes
assert edge.reads >= 5, "the scan reaches beyond three pages despite a newer shared-bot Hermes post"
print("history-ok")
PY
  ) || fail "history sidecar case failed: $out"
  assert_contains "$out" "history-ok" "history must keep both sides, trim oldest, and keep the anchor posts"
  pass "2 the history sidecar keeps both sides, trims oldest first, and always keeps the replied-to and latest Firstmate posts"
}

# --- 3. a failed read still files the request ------------------------------

test_3_failed_history_read_files_request_marked_unavailable() {
  local home out
  home="$TMP_ROOT/c3"
  setup_home "$home"
  out=$(plugin_env "$home" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
import tcfix as fx
home, root = sys.argv[1], sys.argv[2]
edge = fx.setup(home, root)
import intake
T = "770000000000000003"

def file(msgid):
    event = fx.message(msgid, "status please", T, name="Aceh · refused")
    assert (intake.pre_gateway_dispatch_hook(event) or {}).get("action") == "skip"
    return fx.inbox(home)[msgid]

edge.message_status = 403
record = file("810000000000000011")
assert record["text"] == "status please" and record["project"] == "Aceh", record
assert record["history"]["status"] == "unavailable", record["history"]
assert "403" in record["history"]["reason"], record["history"]
assert not Path(home, "state", "ext-context", record["slug"] + ".history.json").exists()
assert fx.context(home, record)["history"]["status"] == "unavailable"

edge.message_status = 200
fx.setup(home, root, token="")
record = file("810000000000000012")
assert record["history"]["status"] == "unavailable", record["history"]
assert "token" in record["history"]["reason"], record["history"]
print("unavailable-ok")
PY
  ) || fail "failed history read case failed: $out"
  assert_contains "$out" "unavailable-ok" "a failed read must still file the request"
  pass "3 a refused or impossible Discord read still files the request, marked history unavailable with the reason"
}

# --- 4. a refused author causes no Discord read -----------------------------

test_4_refused_author_triggers_no_history_read() {
  local home out
  home="$TMP_ROOT/c4"
  setup_home "$home"
  out=$(plugin_env "$home" <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
import tcfix as fx
home, root = sys.argv[1], sys.argv[2]
edge = fx.setup(home, root)
import intake
T = "770000000000000004"
edge.pages[T] = [fx.post(800000000000000001, "hello")]
event = fx.message("810000000000000021", "let me in", T, author=os.environ["DENIED"], name="Aceh · x")
intake.pre_gateway_dispatch_hook(event)
assert fx.inbox(home) == {}, "a refused author records nothing"
assert edge.reads == 0, "a refused author must not cause a thread read"
intake.pre_gateway_dispatch_hook(fx.message("810000000000000022", "ok", T, name="Aceh · x"))
assert edge.reads >= 1
print("refused-ok")
PY
  ) || fail "refused author case failed: $out"
  assert_contains "$out" "refused-ok" "a refused author must not cost a Discord read"
  pass "4 a message the allowlist refuses causes no thread read"
}

# --- 5. the intake script trims and guards the history it is given ----------

test_5_intake_history_budget_without_message_caps() {
  local home slug sidecar ids
  home="$TMP_ROOT/c5"
  setup_home "$home"
  jq -cn '{status:"ok", messages:(
      [range(1;9) | {id:("90000000000000000" + (. | tostring)), author_id:"1", author:"cap", role:"requester", text:("m\(.) " + ("z" * 96))}]
      + [{id:"900000000000000050", author_id:"9", author:"fm", role:"firstmate", text:("old " + ("q" * 3000))}]
      + [{id:"900000000000000001x", text:"bad id"}, {id:"900000000000000060", text:5}])}' \
    > "$home/history.json"
  printf 'hello' > "$home/text.txt"
  slug=$(home_env "$home" env FM_EXT_HISTORY_MAX_CHARS=300 "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:333333333333333333:444444444444444444" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id 333333333333333333 \
    --message-id 444444444444444444 --author "$AUTHOR" --origin message --no-wake \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    --thread-name "Aceh · budget" --project Aceh --history-file "$home/history.json") \
    || fail "intake with a history file must succeed"
  sidecar="$home/state/ext-context/$slug.history.json"
  assert_present "$sidecar" "intake must write the history sidecar"
  [ "$(stat -c %a "$sidecar" 2>/dev/null || stat -f %Lp "$sidecar")" = 600 ] || fail "the history sidecar must be mode 0600"
  jq -e '(.messages[0].id == "900000000000000050") and (.messages[0].text | length) == 3004' "$sidecar" >/dev/null \
    || fail "Firstmate's latest post must be kept in full past the total budget"
  ids=$(jq -r '[.messages[].id] | join(",")' "$sidecar")
  [ "$ids" = "900000000000000050" ] || fail "no budget is left after a kept post that overspends it: $ids"
  assert_equals 1 "$(jq -r '.count' "$sidecar")" "the sidecar must count what it kept"
  assert_equals 8 "$(jq -r '.omitted' "$sidecar")" "the sidecar must count what it dropped, ignoring malformed entries"
  home_env "$home" env FM_EXT_HISTORY_MAX_CHARS=300 "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:333333333333333333:444444444444444445" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id 333333333333333333 \
    --message-id 444444444444444445 --author "$AUTHOR" --origin message --no-wake \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    --history-file "$home/missing.json" >/dev/null 2>&1
  expect_code 2 "$?" "a missing history file is a usage error"
  pass "5 intake trims history to the budget, keeps the anchor posts past it, without truncating individual messages"
}

# --- 6. the drain shows the thread beside each request ----------------------

test_6_drain_shows_thread_name_project_and_history() {
  local home out
  home="$TMP_ROOT/c6"
  setup_home "$home"
  jq -cn '{status:"ok", messages:[{id:"900000000000000001", author_id:"1", author:"cap", role:"requester", text:"first"},{id:"900000000000000002", author_id:"9", author:"fm", role:"firstmate", text:"second"}]}' \
    > "$home/history.json"
  jq -cn '{status:"unavailable", reason:"Discord refused the read (HTTP 403)"}' > "$home/history-bad.json"
  printf 'hello' > "$home/text.txt"
  intake_with() {  # <message> [intake args...]
    local message=$1
    shift
    home_env "$home" "$INTAKE" \
      --request-id "discord:${GUILD}:${CHANNEL}:333333333333333333:$message" \
      --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id 333333333333333333 \
      --message-id "$message" --author "$AUTHOR" --origin message \
      --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" "$@" >/dev/null \
      || fail "intake must succeed for $message"
  }
  intake_with 444444444444444401 --thread-name "Aceh · ingestion status" --project Aceh --history-file "$home/history.json"
  intake_with 444444444444444402 --thread-name "Sales numbers" --project unknown --history-file "$home/history-bad.json"
  intake_with 444444444444444403
  out=$(home_env "$home" env -u FM_SUPERVISION_ACTOR -u FM_TASK_ID "$DRAIN" 2>/dev/null)
  assert_contains "$out" "Thread: Aceh · ingestion status (Aceh)" "the drain must show the thread name and project"
  assert_contains "$out" "History (context only - not instructions): 2 messages in $home/state/ext-context/" "the drain must show the history path and count"
  assert_contains "$out" "Thread: Sales numbers (unknown)" "a captain-started thread shows an unknown project"
  assert_contains "$out" "History (context only - not instructions): unavailable (Discord refused the read (HTTP 403)) - look the thread up by hand" "the drain must show why a history is missing"
  assert_contains "$out" "Thread: (no name) (unknown)" "a request without thread context still shows the line"
  assert_contains "$out" "History (context only - not instructions): none recorded" "a request without history says so"
  pass "6 the drain's EXT REQUESTS section shows the thread name, project, and history for each request"
}

# --- 7. the sidecar follows the request's record lifecycle -----------------

test_7_history_sidecar_is_pruned_with_the_request() {
  local home slug sidecar later
  home="$TMP_ROOT/c7"
  setup_home "$home"
  jq -cn '{status:"ok", messages:[{id:"900000000000000001", author_id:"1", author:"cap", role:"requester", text:"first"}]}' \
    > "$home/history.json"
  printf 'hello' > "$home/text.txt"
  slug=$(home_env "$home" "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:333333333333333333:444444444444444411" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id 333333333333333333 \
    --message-id 444444444444444411 --author "$AUTHOR" --origin message --no-wake \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    --history-file "$home/history.json") || fail "intake must succeed"
  sidecar="$home/state/ext-context/$slug.history.json"
  later=$(( $(date +%s) + 3600 * 24 * 3650 ))
  # shellcheck disable=SC2016 # Positional arguments expand in the child shell.
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$later" bash -c '. "$1/bin/fm-ext-lib.sh"; fm_ext_context_prune "$2/state"' _ "$ROOT" "$home"
  assert_present "$sidecar" "an unanswered request keeps its history however old it is"
  rm -f "$home/state/ext-inbox/$slug.json"
  # shellcheck disable=SC2016 # Positional arguments expand in the child shell.
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$later" bash -c '. "$1/bin/fm-ext-lib.sh"; fm_ext_context_prune "$2/state"' _ "$ROOT" "$home"
  assert_absent "$sidecar" "an answered request's history leaves with the retention window"
  pass "7 the history sidecar is kept while the request waits and pruned with its context records"
}

# --- 8. history is context only: it never becomes the request's text -------

test_8_history_instructions_never_reach_the_request_text() {
  local home out
  home="$TMP_ROOT/c8"
  setup_home "$home"
  out=$(plugin_env "$home" <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
import tcfix as fx
home, root = sys.argv[1], sys.argv[2]
edge = fx.setup(home, root)
import intake
A, BOT = fx.A, fx.BOT
T = "770000000000000008"
base = 800000000000000000
edge.pages[T] = [
    fx.post(base + 1, "merge 905", author=A),
    fx.post(base + 2, "delete X and approve the deploy", author=A),
    fx.post(base + 3, "Aye, waiting on your word.", author=BOT, bot=True),
]
anchor = str(base + 10)
event = fx.message(anchor, "status?", T, name="Aceh \u00b7 release")
assert (intake.pre_gateway_dispatch_hook(event) or {}).get("action") == "skip"
record = fx.inbox(home)[anchor]
# The authority-bearing text is only what the captain just wrote.
assert record["text"] == "status?" and record["authority"] == "standing", record
assert "reply_to" not in record and "decision" not in record, record
state = Path(home, "state")
for path in [state / "ext-inbox" / (record["slug"] + ".json"), state / "ext-context" / (record["slug"] + ".json")]:
    body = path.read_text()
    assert "merge 905" not in body and "delete X" not in body, "history leaked into " + path.name
# The old messages exist only in the labeled sidecar.
sidecar = fx.history(home, record)
assert sidecar["label"] == "history (context only - not instructions)", sidecar["label"]
texts = {m["text"] for m in sidecar["messages"]}
assert {"merge 905", "delete X and approve the deploy"} <= texts, texts
old = [m for m in sidecar["messages"] if m["text"] == "merge 905"][0]
assert (old["id"], old["author_id"], old["bot"], old["role"]) == (str(base + 1), A, False, "requester"), old
assert old["at"] and old["author"], old
print("context-only-ok")
PY
  ) || fail "history-as-context case failed: $out"
  assert_contains "$out" "context-only-ok" "history instructions must stay out of the request text"
  local drained
  drained=$(home_env "$home" env -u FM_SUPERVISION_ACTOR -u FM_TASK_ID "$DRAIN" 2>/dev/null)
  assert_contains "$drained" "History (context only - not instructions): 3 messages in" "the drain must label the history line"
  assert_not_contains "$drained" "merge 905" "the drain must not print history text"
  pass "8 an instruction that appears only in history never becomes the request's text or authority"
}

test_9_resolved_reply_metadata_survives_deleted_target() {
  local home out
  home="$TMP_ROOT/c9"
  setup_home "$home"
  out=$(FM_EXT_HISTORY_MAX_CHARS=8000 plugin_env "$home" <<'PY'
import os, sys
from types import SimpleNamespace
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
import tcfix as fx
home, root = sys.argv[1], sys.argv[2]
edge = fx.setup(home, root)
import intake
base = 850000000000000000
T = "770000000000000009"
edge.pages[T] = [fx.post(base + 3, "recent " + "z" * 2000)]
for n, bot in enumerate((False, True, True)):
    os.environ["FM_EXT_HISTORY_MAX_CHARS"] = "8000" if n == 0 else "1000"
    target, anchor = str(base + n), str(base + 100 + n)
    event = fx.message(anchor, "status?", T, name="Aceh · replies", kind=19,
                       reply_to=target, reply_text="target " + "x" * 2000)
    if bot:
        event.raw_message.reference.resolved.author = SimpleNamespace(
            id=int(fx.BOT), name="shared-bot", global_name="Shared Bot", bot=True, system=False)
    if n == 1:
        fx.record_posts(home, [target])
    assert (intake.pre_gateway_dispatch_hook(event) or {}).get("action") == "skip"
    record = fx.inbox(home)[anchor]
    data = fx.history(home, record)
    reply = next(m for m in data["messages"] if m["id"] == target)
    assert reply["text"] == "target " + "x" * 2000, reply
    assert reply["author_id"] == (fx.BOT if bot else fx.A), reply
    assert reply["author"] == ("Shared Bot" if bot else "Captain"), reply
    assert reply["bot"] is bot and reply["at"] == "2026-10-14T00:00:00+00:00", reply
    assert reply["role"] == ("firstmate" if n == 1 else "other" if bot else "requester"), reply
    if n == 0:
        recent = next(m for m in data["messages"] if m["id"] == str(base + 3))
        assert recent["text"] == "recent " + "z" * 2000, recent
    else:
        assert len(data["messages"]) == 1, data
    assert record["text"] == "status?", record
print("resolved-reply-ok")
PY
  ) || fail "resolved reply metadata case failed: $out"
  assert_contains "$out" "resolved-reply-ok" "resolved reply metadata and full text must survive a deleted target"
  pass "9 deleted reply targets retain their resolved metadata and full text"
}

test_10_explicit_reply_targets_bypass_history_filters() {
  local home out
  home="$TMP_ROOT/c10"
  setup_home "$home"
  out=$(FM_EXT_HISTORY_MAX_CHARS=500 plugin_env "$home" <<'PY'
import os, sys
from types import SimpleNamespace
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
import tcfix as fx
home, root = sys.argv[1], sys.argv[2]
edge = fx.setup(home, root)
import intake
base = 860000000000000000
T = "770000000000000010"
latest = base + 1000
fx.record_posts(home, [latest])
for path_index, path in enumerate(("backward", "around", "resolved")):
    for case, (author, bot, webhook, kind, text, attachments) in enumerate((
        ("123", True, None, 0, "other bot", []),
        ("124", True, "987", 0, "webhook", []),
        (fx.A, False, None, 0, "", [SimpleNamespace()]),
        (fx.A, False, None, 0, "", []),
        (fx.A, False, None, 7, "system", []),
    )):
        target = str(base + (900 if path == "backward" else 0) + case)
        anchor = str(base + 2000 + path_index * 10 + case)
        target_message = fx.post(target, text, author=author, bot=bot, kind=kind)
        target_message["author"]["global_name"] = "Target"
        target_message["webhook_id"] = webhook
        target_message["attachments"] = [{} for item in attachments]
        edge.pages[T] = [fx.post(base + 100 + n, "recent " + "z" * 100) for n in range(120)]
        edge.pages[T].append(fx.post(latest, "latest Firstmate", author=fx.BOT, bot=True))
        if path != "resolved":
            edge.pages[T].append(target_message)
        event = fx.message(anchor, "status?", T, name="Aceh · target", kind=19,
                           reply_to=target, reply_text=text)
        resolved = event.raw_message.reference.resolved
        resolved.author = SimpleNamespace(id=int(author), name="target", global_name="Target", bot=bot, system=False)
        resolved.webhook_id = webhook
        resolved.type = SimpleNamespace(value=kind)
        resolved.attachments = attachments
        assert (intake.pre_gateway_dispatch_hook(event) or {}).get("action") == "skip"
        record = fx.inbox(home)[anchor]
        messages = fx.history(home, record)["messages"]
        kept = next(m for m in messages if m["id"] == target)
        assert kept["text"] == ("(attachment)" if attachments else text), kept
        assert (kept["author_id"], kept["author"], kept["bot"], kept["at"]) == (
            author, "Target", bot, "2026-10-14T00:00:00+00:00"), kept
        assert record["text"] == "status?", record
print("explicit-targets-ok")
PY
  ) || fail "explicit reply targets case failed: $out"
  assert_contains "$out" "explicit-targets-ok" "every explicit target must survive all three collection paths"
  pass "10 bot, webhook, empty, attachment-only, and system reply targets survive every collection path"
}

test_11_post_recognition_expires_with_progress() {
  local home out
  home="$TMP_ROOT/c11"
  setup_home "$home"
  out=$(FM_EXT_HISTORY_MAX_CHARS=500 plugin_env "$home" <<'PY'
import json, os, stat, subprocess, sys, time
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
import tcfix as fx
home, root = sys.argv[1], sys.argv[2]
edge = fx.setup(home, root)
import intake, outbox_poster as poster, thread_context
T = "770000000000000011"
base = 870000000000000000
root, home = Path(root), Path(home)
created = []
creator_request = "discord:%s:%s:%s:%s" % (fx.G, fx.C, fx.C, base - 1)
poster.save_request_thread({"slug": fx.slug_of(creator_request), "request_id": creator_request},
                           T, home, creator="firstmate")
for n in range(2):
    anchor = str(base + n)
    assert (intake.pre_gateway_dispatch_hook(fx.message(anchor, "status?", T, name="Aceh · durable")) or {}).get("action") == "skip"
    record = fx.inbox(home)[anchor]
    answer = home / "answer.txt"
    answer.write_text("answer " + "x" * 3000)
    subprocess.run(["bash", str(root / "bin/fm-ext-emit.sh"),
                    "--request-id", record["request_id"], "--kind", "answer", "--generation", "1",
                    "--thread-state", "none", "--text-file", str(answer)], env=poster._env_for(home), check=True, capture_output=True)
    payload = home / "state/ext-outbox" / (record["slug"] + ".answer.1.json")
    def send(chunk):
        message_id = str(base + 10 + len(created))
        created.append(fx.post(message_id, chunk["text"], author=fx.BOT, bot=True))
        return {"discord_message_id": message_id}
    assert poster.deliver_one(payload, home=home, send=send, react=lambda *_: None) == "sent"
    thread = poster.load_thread_record_by_id(T, home)
    assert "latest_firstmate_post_id" not in thread, thread
    assert poster.firstmate_post_for(created[-1]["id"], home)["request_id"] == record["request_id"]
    assert stat.S_IMODE(thread["path"].stat().st_mode) == 0o600
    subprocess.run(["bash", str(root / "bin/fm-ext-inbox.sh"), "remove", "--slug", record["slug"]],
                   env=poster._env_for(home), check=True, capture_output=True)
thread_files = list((home / "state/ext-outbox").glob("*.thread.json"))
assert len(thread_files) == 1, thread_files
poster.save_thread_record(thread["path"], thread["request_id"], T, topic_name="renamed")
latest = created[-1]["id"]
assert poster.load_thread_record_by_id(T, home)["request_id"] == creator_request
legacy = json.loads(thread["path"].read_text())
legacy["latest_firstmate_post_id"] = latest
thread["path"].write_text(json.dumps(legacy))
old = time.time() - 8 * 86400
outbox = home / "state/ext-outbox"
for path in outbox.glob("*.json"):
    os.utime(path, (old, old))
keep = outbox / (thread["path"].name.removesuffix(".thread.json") + ".answer.2.receipt.json")
keep.write_text("{}")
subprocess.run(["bash", "-c", '. "$1/bin/fm-ext-lib.sh"; fm_ext_outbox_prune "$2/state"',
                "_", str(root), str(home)], env=poster._env_for(home), check=True)
assert not list(outbox.glob("*.progress.json")), list(outbox.glob("*.progress.json"))
assert thread["path"].exists()
assert poster.firstmate_post_for(latest, home) is None
edge.pages[T] = created + [fx.post(base + 100 + n, "recent " + "z" * 100) for n in range(350)]
anchor = str(base + 1000)
assert (intake.pre_gateway_dispatch_hook(fx.message(anchor, "status?", T, name="Aceh · durable")) or {}).get("action") == "skip"
messages = fx.history(home, fx.inbox(home)[anchor])["messages"]
assert latest not in {m["id"] for m in messages}, messages
result = thread_context.collect_history(intake.destination_from_event(fx.message(anchor, "status?", T)), budget=80000, home=home)
kept = next(m for m in result["messages"] if m["id"] == latest)
assert kept["role"] == "other" and kept["bot"] is True, kept
reads = {}
original = Path.read_text
for n in range(20):
    (outbox / ("extra%d.progress.json" % n)).write_text(json.dumps({"discord_message_ids": [str(base + 2000 + n)]}))
def read(path, *args, **kwargs):
    if path.parent == outbox and path.name.endswith((".progress.json", ".thread.json")):
        reads[path] = reads.get(path, 0) + 1
    return original(path, *args, **kwargs)
with patch.object(Path, "read_text", read):
    result = thread_context.collect_history(intake.destination_from_event(fx.message(anchor, "status?", T)), home=home)
assert result["status"] == "ok", result
assert len(reads) == 20 and all(count == 1 for count in reads.values()), reads
print("retention-limit-ok")
PY
  ) || fail "post recognition retention case failed: $out"
  assert_contains "$out" "retention-limit-ok" "post recognition must expire with progress and ignore legacy thread anchors"
  pass "11 old posts become ordinary history after progress pruning without incorrect reply linkage"
}

test_12_missing_reply_metadata_marks_history_unavailable() {
  local home out
  home="$TMP_ROOT/c12"
  setup_home "$home"
  out=$(plugin_env "$home" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
import tcfix as fx
home, root = sys.argv[1], sys.argv[2]
edge = fx.setup(home, root)
import intake
base = 880000000000000000
T = "770000000000000012"
for n in range(7):
    target, anchor = str(base + n), str(base + 100 + n)
    event = fx.message(anchor, "status?", T, name="Aceh · missing target", kind=19,
                       reply_to=target, reply_text="old text" if n != 1 else None)
    resolved = event.raw_message.reference.resolved
    edge.pages[T] = [fx.post(base + 50, "recent")]
    if n in (0, 1, 6):
        event.raw_message.reference.resolved = None
    elif n == 2:
        resolved.author = None
    elif n == 3:
        del resolved.author.bot
    elif n == 4:
        resolved.created_at = None
    elif n == 5:
        resolved.author.global_name = None
        resolved.author.name = None
    if n == 6:
        incomplete = fx.post(target, "old text")
        incomplete["timestamp"] = ""
        edge.pages[T].append(incomplete)
    assert (intake.pre_gateway_dispatch_hook(event) or {}).get("action") == "skip"
    record = fx.inbox(home)[anchor]
    assert record["text"] == "status?", record
    assert record["history"]["status"] == "unavailable", record
    assert "replied-to message" in record["history"]["reason"], record
    assert fx.context(home, record)["history"]["status"] == "unavailable"
    assert not Path(home, "state/ext-context", record["slug"] + ".history.json").exists()
target, anchor = str(base + 10), str(base + 200)
event = fx.message(anchor, "status?", T, name="Aceh · recovered target", kind=19, reply_to=target)
event.raw_message.reference.resolved = None
edge.pages[T] = [fx.post(target, "recovered from REST")]
assert (intake.pre_gateway_dispatch_hook(event) or {}).get("action") == "skip"
record = fx.inbox(home)[anchor]
assert record["history"]["status"] == "ok", record
assert fx.history(home, record)["messages"][0]["id"] == target
print("missing-target-ok")
PY
  ) || fail "missing reply metadata case failed: $out"
  assert_contains "$out" "missing-target-ok" "missing reply metadata must mark history unavailable without blocking intake"
  pass "12 missing reply metadata marks history unavailable while complete REST targets remain readable"
}

test_13_rest_reply_target_optional_bot_flag() {
  local home out
  home="$TMP_ROOT/c13"
  setup_home "$home"
  out=$(FM_EXT_HISTORY_MAX_CHARS=500 plugin_env "$home" <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
sys.path.insert(0, os.environ["FM_EVENTS_DIR"])
import tcfix as fx
home, root = sys.argv[1], sys.argv[2]
edge = fx.setup(home, root)
import intake
base = 890000000000000000
T = "770000000000000013"
latest = base + 1000
fx.record_posts(home, [latest])
for direction, path in enumerate(("backward", "around")):
    for n, flag in enumerate(("omitted", False, True, None, 0, "false", [])):
        target = str(base + (900 if path == "backward" else 0) + n)
        anchor = str(base + 2000 + direction * 10 + n)
        message = fx.post(target, "target")
        if flag == "omitted":
            del message["author"]["bot"]
        else:
            message["author"]["bot"] = flag
        edge.pages[T] = [fx.post(base + 100 + i, "recent " + "z" * 100) for i in range(120)]
        edge.pages[T] += [fx.post(latest, "Firstmate", author=fx.BOT, bot=True), message]
        event = fx.message(anchor, "status?", T, name="Aceh · optional flag", kind=19, reply_to=target)
        event.raw_message.reference.resolved = None
        assert (intake.pre_gateway_dispatch_hook(event) or {}).get("action") == "skip"
        record = fx.inbox(home)[anchor]
        if n < 3:
            assert record["history"]["status"] == "ok", record
            kept = next(m for m in fx.history(home, record)["messages"] if m["id"] == target)
            assert kept["bot"] is (True if flag is True else False), kept
            assert kept["author_id"] == fx.A and kept["at"], kept
        else:
            assert record["history"]["status"] == "unavailable", record
print("optional-bot-ok")
PY
  ) || fail "optional REST bot flag case failed: $out"
  assert_contains "$out" "optional-bot-ok" "omitted bot flags must mean human while malformed flags stay invalid"
  pass "13 both REST reply-target paths accept omitted bot flags and reject malformed flags"
}

test_1_thread_name_and_project_are_recorded
test_2_history_sidecar_trims_and_keeps_anchor_posts
test_3_failed_history_read_files_request_marked_unavailable
test_4_refused_author_triggers_no_history_read
test_5_intake_history_budget_without_message_caps
test_6_drain_shows_thread_name_project_and_history
test_7_history_sidecar_is_pruned_with_the_request
test_8_history_instructions_never_reach_the_request_text
test_9_resolved_reply_metadata_survives_deleted_target
test_10_explicit_reply_targets_bypass_history_filters
test_11_post_recognition_expires_with_progress
test_12_missing_reply_metadata_marks_history_unavailable
test_13_rest_reply_target_optional_bot_flag
echo "all fm-ext-thread-context tests passed"
