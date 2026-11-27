#!/usr/bin/env bash
# Behavior tests for the topic-thread title reconciler and its inputs.
#
# One reconciler per thread is the only code that writes a Discord title, and
# it works from durable state alone: the decision ledger, the chunks Discord
# accepted (with each reply's own state and retitle), the thread's Jev verdict
# log, and Discord's cooldowns. After every Firstmate post a background judge
# scan asks Jev for the thread's status and topic fit; the first scan is the
# one-time catch-up of the ten threads Firstmate posted in most recently. The
# reconciler applies marker precedence, keeps the captain's own words, paces
# changes to one per thread per ten minutes, lets only a decision button's
# question mark and a correction of its own raced write skip that pace, and
# always obeys Discord's rate limits. docs/configuration.md "Thread title
# reconciler" owns the contract.
#
# Hermetic: no Discord, Jev, or model network. The real poster, intake, emit,
# decision ledger, bin/fm-ext-thread-judge.sh, bin/fm-ext-thread-name.sh, and
# bin/fm-ext-topic.sh run against fixture homes. Jev is replayed at the HTTP
# boundary by a stand-in curl that returns a recorded answer from
# tests/fixtures/thread-autoname/<case>.json; the naming model is a stand-in
# opencode. Discord is a local HTTP server that keeps thread names, messages,
# and every title write, and can answer with HTTP 429 and rate-limit headers.
# Time is a fake clock shared by every process a test runs: Python's clock,
# the decision ledger's clock, and the ids of new Discord messages follow it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
BASE_PATH="$(dirname "$PYTHON_BIN"):$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ext-thread-autoname)

INTAKE="$ROOT/bin/fm-ext-intake.sh"
EMIT="$ROOT/bin/fm-ext-emit.sh"
JUDGE="$ROOT/bin/fm-ext-thread-judge.sh"
PLUGIN="$ROOT/contrib/hermes-gateway-firstmate-comms"
FIXTURES="$ROOT/tests/fixtures/thread-autoname"

GUILD=111111111111111111
CHANNEL=222222222222222222
AUTHOR=555555555555555555

# --- stand-ins at the network boundaries ----------------------------------------

STUBS="$TMP_ROOT/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/curl" <<'EOF'
#!/usr/bin/env bash
out='' data=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --data-binary) data=${2#@}; shift 2 ;;
    *) shift ;;
  esac
done
body=$(cat "$data")
printf '%s\n' "$body" | jq -c . >> "$FM_TEST_CAPTURE/jev.jsonl"
calls=$(wc -l < "$FM_TEST_CAPTURE/jev.jsonl")
if [ -n "${FM_TEST_KILL_AT:-}" ] && [ "$calls" -eq "$FM_TEST_KILL_AT" ]; then
  kill -9 "$FM_TEST_KILL_PID"
  exit 1
fi
if [ -n "${FM_TEST_JEV_HOLD:-}" ]; then
  : > "$FM_TEST_CAPTURE/jev-entered"
  for ((i=0; i<500; i++)); do
    [ ! -f "$FM_TEST_CAPTURE/jev-release" ] || break
    sleep 0.02
  done
fi
if [ "${FM_TEST_SPLIT_JUDGE:-}" = 1 ]; then
  if jq -e '
    .questions.status.instructions | contains("judge the newest reply with all its chunks read together")
  ' <<< "$body" >/dev/null && jq -e '
    .state.thread.messages as $messages | $messages[-1].reply as $reply
    | $reply != null and any($messages[]; .reply == $reply and (.text | contains("Closing this thread.")))
  ' <<< "$body" >/dev/null; then
    FM_TEST_JEV="$FM_TEST_FIXTURES/done.json"
  else
    FM_TEST_JEV="$FM_TEST_FIXTURES/blocked.json"
  fi
fi
if [ -n "${FM_TEST_JEV:-}" ] && [ -f "$FM_TEST_JEV" ]; then
  jq --arg drift "${FM_TEST_SPLIT_DRIFT:-}" '
    .jev | if $drift == "1" then .answers.topic_fits.noul = 0.01 else . end
  ' "$FM_TEST_JEV" > "$out"
  printf '200'
else
  printf '{"error":"stand-in"}' > "$out"
  printf '500'
fi
EOF
cat > "$STUBS/opencode" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 5 ] && [ "$1 $2 $3 $4" = "run --format json -m" ] || exit 2
[ -z "${TYPESAFE_API_KEY+x}${TYPESAFE_API_KEY_PRIVATE+x}" ] || exit 2
prompt=$(cat)
printf 'model=%s\n%s\n---\n' "$5" "$prompt" >> "$FM_TEST_CAPTURE/namer.txt"
[ -n "${FM_TEST_NAME:-}" ] || exit 1
printf '{"type":"step_start"}\n'
jq -cn --arg text "$FM_TEST_NAME" '{type:"text", part:{text:$text}}'
EOF
chmod +x "$STUBS/curl" "$STUBS/opencode"

# The shared Python side: a local Discord, the fake sender and thread creator
# the poster is given, and small helpers every test uses.
cat > "$TMP_ROOT/driver.py" <<'EOF'
import json, os, re, sys, threading, time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, os.environ["FM_TEST_PLUGIN"])
import outbox_poster as poster
import thread_autoname as autoname
import thread_title as title

HOME = Path(os.environ["FM_HOME"])
FIXTURES = Path(os.environ["FM_TEST_FIXTURES"])
CAPTURE = Path(os.environ["FM_TEST_CAPTURE"])
BOT = "888888888888888888"
CAPTAIN = os.environ["FM_TEST_CAPTAIN"]
STATE = HOME / "discord.json"
LOCK = threading.RLock()
EPOCH_MS = 1420070400000


def load():
    with LOCK:
        try:
            return json.loads(STATE.read_text())
        except (OSError, ValueError):
            return {"threads": {}, "patches": [], "script": [], "seq": 0}


def save(data):
    STATE.write_text(json.dumps(data))


def snowflake(data):
    data["seq"] += 1
    return str(((int(CLOCK[0] * 1000) - EPOCH_MS) << 22) + data["seq"])


# The fake clock: one origin per home, ahead of real time, persisted so each
# process a test runs continues where the last one stopped. Python's clock,
# the decision ledger's clock, and new Discord message ids all follow it.
_data = load()
T0 = _data.setdefault("t0", int(time.time()) + 1000)
CLOCK = [_data.get("now", T0)]
save(_data)
time.time = lambda: CLOCK[0]


def set_clock(at):
    with LOCK:
        CLOCK[0] = at
        os.environ["FM_EXT_NOW_OVERRIDE"] = str(int(at))
        data = load()
        data["now"] = at
        save(data)


set_clock(CLOCK[0])


class Discord(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body, headers=()):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        url = urlparse(self.path)
        parts = url.path.strip("/").split("/")
        with LOCK:
            data = load()
            data.setdefault("gets", []).append(url.path)
            save(data)
            if parts == ["users", "@me"]:
                return self.reply(200, {"id": BOT})
            thread = data["threads"].get(parts[1]) if len(parts) > 1 else None
            if thread is None or thread.get("unreadable"):
                return self.reply(404, {"message": "Unknown Channel", "code": 10003})
            if len(parts) == 2:
                delays = data.get("read_limits") or []
                if delays:
                    retry_after = delays.pop(0)
                    data["read_limits"] = delays
                    save(data)
                    return self.reply(429, {"retry_after": retry_after}, [("X-RateLimit-Scope", "global")])
                reset = data.pop("title_reset", None)
                headers = []
                if reset is not None:
                    save(data)
                    headers = [("X-RateLimit-Remaining", "0"), ("X-RateLimit-Reset", str(reset))]
                return self.reply(200, {"id": parts[1], "name": thread["name"], "owner_id": BOT}, headers)
            if len(parts) == 4:
                message = next((m for m in thread["messages"] if m["id"] == parts[3]), None)
                if message is None:
                    return self.reply(404, {"message": "Unknown Message", "code": 10008})
                return self.reply(200, message)
            query = parse_qs(url.query)
            before = int(query.get("before", ["9" * 20])[0])
            limit = int(query.get("limit", ["100"])[0])
            messages = [m for m in thread["messages"] if int(m["id"]) < before]
            return self.reply(200, list(reversed(messages))[:limit])

    def do_POST(self):
        thread_id = urlparse(self.path).path.strip("/").split("/")[1]
        message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        message_id = _append(thread_id, BOT, message["content"], components=message.get("components", []))
        return self.reply(200, {"id": message_id, "channel_id": thread_id})

    def do_PATCH(self):
        thread_id = urlparse(self.path).path.strip("/").split("/")[1]
        name = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["name"]
        with LOCK:
            data = load()
            step = data["script"].pop(0) if data["script"] else {}
            status = step.get("status", 200)
            data["patches"].append({"thread": thread_id, "name": name, "status": status})
            if status == 200:
                data["threads"][thread_id]["name"] = name
            save(data)
        if step.get("elapsed"):
            set_clock(CLOCK[0] + step["elapsed"])
        if step.get("disconnect"):
            self.close_connection = True
            return
        if status == 429:
            return self.reply(429, {"message": "You are being rate limited.", "retry_after": step["retry_after"],
                                    "global": step.get("global", False)}, [("X-RateLimit-Remaining", "0")])
        if status != 200:
            return self.reply(status, {"message": "stand-in failure"})
        headers = [("X-RateLimit-Remaining", step.get("remaining", "1"))]
        if "reset" in step:
            headers.append(("X-RateLimit-Reset", str(step["reset"])))
        else:
            headers.append(("X-RateLimit-Reset-After", step.get("reset_after", "1.0")))
        return self.reply(200, {"id": thread_id, "name": name}, headers)


_server = ThreadingHTTPServer(("127.0.0.1", 0), Discord)
threading.Thread(target=_server.serve_forever, daemon=True).start()
poster.DISCORD_API_BASE = f"http://127.0.0.1:{_server.server_port}"
os.environ["DISCORD_BOT_TOKEN"] = "fixture-token"
poster.decisions.buttons_ready = lambda bot_id: bot_id == BOT


def _append(thread_id, author, text, **fields):
    with LOCK:
        data = load()
        message_id = snowflake(data)
        data["threads"].setdefault(thread_id, {"name": "", "messages": []})["messages"].append({
            "id": message_id, "type": 0, "channel_id": thread_id, "content": text,
            "author": {"id": author, "username": "fm" if author == BOT else "captain", "bot": author == BOT},
            "timestamp": "2026-11-23T00:00:00+00:00", **fields})
        save(data)
    return message_id


def send(payload):
    return poster.discord_send(payload)


def create(payload, name):
    with LOCK:
        data = load()
        thread_id = snowflake(data)
        data["threads"][thread_id] = {"name": name, "messages": []}
        save(data)
    return {"ok": True, "thread_id": thread_id}


def settle():
    for worker in threading.enumerate():
        if worker.name in ("fm-ext-autoname", "fm-ext-autoname-scan"):
            worker.join(timeout=60)


def deliver(case=None):
    """Post every queued reply, then let the title worker finish."""
    use(case)
    results = poster.drain_outbox(send=send, home=HOME, react=lambda *args: None, create_thread=create)
    settle()
    return results


def use(case):
    if case:
        os.environ["FM_TEST_JEV"] = str(FIXTURES / f"{case}.json")
    else:
        os.environ.pop("FM_TEST_JEV", None)


def tick(offset, **kwargs):
    """One reconcile-loop step at T0 + offset seconds.

    It settles decision posts, marks threads whose decisions changed, and runs
    the safety sweep, as the gateway's loops do, then reconciles every due
    thread. Only the reconciler writes.
    """
    set_clock(T0 + offset)
    settle_decisions()
    poster.sweep_thread_titles(HOME)
    title.safety_sweep(HOME)
    return title.run_due(HOME, **kwargs)


@contextmanager
def only(marker):
    """Hold every queued reply except the one whose file name has ``marker``."""
    outbox = HOME / "state" / "ext-outbox"
    held = [path for path in outbox.glob("*.json")
            if re.search(r"\.(answer|followup)\.\d+\.json$", path.name) and marker not in path.name]
    for path in held:
        path.rename(path.with_suffix(".held"))
    try:
        yield
    finally:
        for path in held:
            path.with_suffix(".held").rename(path)


def threads():
    return sorted(load()["threads"])


def name(thread_id):
    return load()["threads"][thread_id]["name"]


def captain_renames(thread_id, new_name):
    with LOCK:
        data = load()
        data["threads"][thread_id]["name"] = new_name
        save(data)


def captain_says(thread_id, text):
    return _append(thread_id, CAPTAIN, text)


def script(*steps):
    with LOCK:
        data = load()
        data["script"].extend(steps)
        save(data)


def patches(thread_id=None):
    return [p for p in load()["patches"] if thread_id in (None, p["thread"])]


def record(thread_id):
    return poster.load_thread_record_by_id(thread_id, HOME).get("title") or {}


def verdicts(thread_id):
    return record(thread_id).get("verdicts") or []


def jev_calls():
    path = CAPTURE / "jev.jsonl"
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def settle_decisions():
    """The full decision-post sweep: settle posts whose decision closed."""
    poster.reconcile_decision_posts(HOME, full=True, edit=lambda *args: None)
EOF

# --- fixture homes ------------------------------------------------------------------

setup_home() {  # <home> [off]
  local home=$1
  mkdir -p "$home/config" "$home/capture" "$home/state"
  : > "$home/config/ext-bridge"
  printf '%s\n' "$CHANNEL" > "$home/config/ext-channel"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
  [ "${2:-}" = off ] || printf 'TYPESAFE_API_KEY=fixture-key\n' > "$home/.env"
}

home_env() {
  local home=$1
  shift
  env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE -u DISCORD_BOT_TOKEN \
    PATH="$STUBS:$BASE_PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEST_CAPTURE="$home/capture" \
    FM_TEST_PLUGIN="$PLUGIN" \
    FM_TEST_FIXTURES="$FIXTURES" \
    FM_TEST_CAPTAIN="$AUTHOR" \
    PYTHONPATH="$TMP_ROOT" \
    "$@"
}

# py <home>: run a Python snippet from stdin with the shared driver loaded.
py() {
  home_env "$1" "$PYTHON_BIN" -c 'import sys; from driver import *; exec(sys.stdin.read())'
}

# new_thread <home> <message-id> <title> <first post>: a top-level request whose
# first answer creates a titled topic thread. Jev has no recorded answer here,
# so judging the creating post fails and leaves the title alone.
new_thread() {
  local home=$1 message=$2 title=$3 text=$4
  printf '%s' "Please look at: $title" > "$home/request-$message.txt"
  home_env "$home" "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:${CHANNEL}:${message}" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$CHANNEL" \
    --message-id "$message" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" \
    --text-file "$home/request-$message.txt" --origin message >/dev/null \
    || fail "intake refused the fixture request"
  post "$home" "$message" answer 1 "$text" --thread-title "$title" --thread-state none
  py "$home" <<'PY' >/dev/null || fail "the creating post was not delivered"
assert deliver() == ["sent"], "creating post"
PY
}

# post <home> <message-id> <kind> <generation> <text> [emit flags...]
post() {
  local home=$1 message=$2 kind=$3 generation=$4 text=$5
  shift 5
  printf '%s' "$text" > "$home/post-$message-$generation.txt"
  home_env "$home" "$EMIT" --request-id "discord:${GUILD}:${CHANNEL}:${CHANNEL}:${message}" \
    --kind "$kind" --generation "$generation" --text-file "$home/post-$message-$generation.txt" "$@" \
    >/dev/null || fail "emit refused $kind $generation"
}

# decision_post <home> <message-id> <generation> <key-slug>: a worker's keyed
# decision posted with two options.
decision_post() {
  local home=$1 message=$2 generation=$3 key=$4 options
  options=${5:-'[{"label":"North"},{"label":"South"}]'}
  printf 'needs-decision [key=%s]: pick a route\n' "$key" >> "$home/state/route-fix.status"
  printf '{"key":"key:route-fix:%s","options":%s}' "$key" "$options" \
    > "$home/decision-$generation.json"
  post "$home" "$message" followup "$generation" "Which way should it go? 1. North 2. South" \
    --decision-file "$home/decision-$generation.json" --thread-state needs-you
}

resolve_key() {  # <home> <key-slug>
  printf 'resolved [key=%s]: answered: North\n' "$2" >> "$1/state/route-fix.status"
}


M1=444444444444444441

# --- 1. only the reconciler writes a title -------------------------------------------
#
# The judge worker, the decision sweep, and the judge scan only record inputs:
# while they run, Discord sees no title write at all. The post itself marks
# the thread due, so the reconciler's next pass writes the one title those
# inputs ask for.

test_1_only_the_reconciler_writes_titles() {
  local home="$TMP_ROOT/t1" out
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  post "$home" "$M1" followup 2 "Reindex moved to 02:00; first run is under way."
  decision_post "$home" "$M1" 3 route-a
  out=$(py "$home" <<'PY'
(thread,) = threads()
assert deliver("open-question") == ["sent", "sent"]
assert verdicts(thread)[-1]["status"] == "open-question", record(thread)
assert poster.decision_threads(HOME, thread)[thread]["open"] == 1
assert patches() == [], "the judge worker wrote a title"
autoname.judge_scan(HOME, retry_failed=True)
assert patches() == [], "the judge scan wrote a title"
poster.sweep_thread_titles(HOME)
assert patches() == [], "the decision sweep wrote a title"
assert title.run_due(HOME) == [thread]
assert [p["name"] for p in patches()] == ["❓ Aceh · nightly reindex"], patches()
print("ok")
PY
  ) || fail "only the reconciler may write: $out"
  pass "the judge worker, judge scan, and decision sweep write no title; the reconciler does"
}

# --- 2. marker precedence follows the recorded verdicts -------------------------------
#
# Each recorded Jev answer maps to its marker: open-question (a plain question,
# no button) shows ❓, running ⏳, done ✅, blocked ⚠️. An open decision button
# outranks every verdict, including blocked.

test_2_marker_precedence_follows_recorded_verdicts() {
  local home="$TMP_ROOT/t2" out
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  post "$home" "$M1" followup 2 "Which do you want, 02:00 or a second worker?"
  post "$home" "$M1" followup 3 "Reindex moved to 02:00; first run is under way."
  post "$home" "$M1" followup 4 "The 02:00 reindex finished cleanly."
  post "$home" "$M1" followup 5 "The reindex worker cannot reach the OCR box: credential expired."
  decision_post "$home" "$M1" 6 route-a
  out=$(py "$home" <<'PY'
(thread,) = threads()
steps = []
for generation, case in ((2, "open-question"), (3, "running"), (4, "done"), (5, "blocked")):
    with only(f"followup.{generation}"):
        deliver(case)
    tick(generation * 601)
    steps.append(name(thread))
assert steps == ["❓ Aceh · nightly reindex", "⏳ Aceh · nightly reindex",
                 "✅ Aceh · nightly reindex", "⚠️ Aceh · nightly reindex"], steps
deliver("blocked")
assert verdicts(thread)[-1]["status"] == "blocked"
tick(6 * 601 + 10)
assert name(thread) == "❓ Aceh · nightly reindex", name(thread)
print("ok")
PY
  ) || fail "markers did not follow precedence: $out"
  pass "recorded verdicts map to ❓ ⏳ ✅ ⚠️ and an open decision outranks a blocked verdict"
}

# --- 3. with judging off, a reply's own state marks the thread, never ⚠️ ---------------
#
# Without the Jev key the reconciler follows each reply's explicit state, read
# from the chunks Discord accepted. A worker that reports itself blocked on a
# keyed decision shows ❓ for that decision: ⚠️ comes only from Jev.

test_3_explicit_states_drive_markers_when_judging_is_off() {
  local home="$TMP_ROOT/t3" out
  setup_home "$home" off
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  post "$home" "$M1" answer 2 "Reindex moved and finished." --thread-state "done"
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver()
tick(0)
assert name(thread) == "✅ Aceh · nightly reindex", name(thread)
assert jev_calls() == [], "judging ran with no key"
print("ok")
PY
  ) || fail "explicit done did not mark the thread: $out"
  printf 'blocked [key=route-b]: credential expired, which route?\n' >> "$home/state/route-fix.status"
  printf '{"key":"key:route-fix:route-b","options":[{"label":"North"},{"label":"South"}]}' \
    > "$home/decision-3.json"
  post "$home" "$M1" followup 3 "Blocked on a credential. Which route? 1. North 2. South" \
    --decision-file "$home/decision-3.json" --thread-state needs-you
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver()
tick(601)
assert name(thread) == "❓ Aceh · nightly reindex", name(thread)
assert not any(p["name"].startswith("⚠") for p in patches()), patches()
print("ok")
PY
  ) || fail "a blocked worker decision did not show ❓: $out"
  pass "explicit states mark the thread while judging is off, and a blocked worker shows ❓ not ⚠️"
}

# --- 4. pacing: our ten minutes, Discord's own limits, and the button exception ------
#
# Judged changes land at most once per thread per ten minutes and the newest
# desired title wins the slot. Discord's X-RateLimit headers and a 429's
# retry_after always hold the next write, even a decision button's question
# mark, which alone skips our pace.

test_4_pacing_obeys_our_pace_and_discord_limits() {
  local home="$TMP_ROOT/t4" out
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  post "$home" "$M1" followup 2 "Reindex moved to 02:00; first run is under way."
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver("running")
tick(0)
assert name(thread) == "⏳ Aceh · nightly reindex"
PY
  ) || fail "the first judged change did not land: $out"
  post "$home" "$M1" followup 3 "The 02:00 reindex finished cleanly."
  post "$home" "$M1" followup 4 "The OCR box refused the worker: credential expired."
  out=$(py "$home" <<'PY'
(thread,) = threads()
with only("followup.3"):
    deliver("done")
tick(60)
assert name(thread) == "⏳ Aceh · nightly reindex" and len(patches()) == 1, patches()
deliver("blocked")
tick(300)
assert len(patches()) == 1, "a write landed inside the ten-minute pace"
PY
  ) || fail "judged changes did not wait for the pace: $out"
  decision_post "$home" "$M1" 5 route-free '[]'
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver("open-question")
summary = poster.decision_threads(HOME, thread)[thread]
assert summary["open"] == 1 and summary["open_buttons"] == 0, summary
assert not load()["threads"][thread]["messages"][-1]["components"]
tick(301)
assert len(patches()) == 1, "a free-text question bypassed the pace"
PY
  ) || fail "the free-text decision was not paced: $out"
  resolve_key "$home" route-free
  out=$(py "$home" <<'PY'
script({"status": 200, "remaining": "0", "reset": T0 + 604.25})
tick(601)
assert [p["name"] for p in patches()][1:] == ["⚠️ Aceh · nightly reindex"], patches()
PY
  ) || fail "the newest kept verdict did not land at the paced slot: $out"
  decision_post "$home" "$M1" 6 route-a
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver("open-question")
summary = poster.decision_threads(HOME, thread)[thread]
assert summary["open"] == 1 and summary["open_buttons"] == 1, summary
assert load()["threads"][thread]["messages"][-1]["components"]
tick(604.24)
assert len(patches()) == 2, "a button write went out before Discord's reset"
script({"status": 429, "retry_after": 7.5})
tick(604.25)
assert patches()[-1]["status"] == 429 and name(thread) == "⚠️ Aceh · nightly reindex"
tick(611.74)
assert len(patches()) == 3, "a write went out before the 429 retry_after"
tick(611.75)
assert patches()[-1]["status"] == 200 and name(thread) == "❓ Aceh · nightly reindex", patches()
print("ok")
PY
  ) || fail "the decision button did not skip our pace while obeying Discord: $out"
  pass "one judged change per ten minutes, newest wins; button ❓ skips our pace but waits out headers and 429"
}

# --- 5. a done judged during an open decision lands after closure ---------------------
#
# Verdicts judged while a decision is open are kept. When the ledger closes
# the last decision, the kept done is applied at the next permitted slot, and
# a reminder about the decision posted before it closed does not replace it.
# A question asked while the decision was open belongs to that decision and
# does not keep ❓ after it closes.

test_5_done_during_a_decision_lands_after_closure() {
  local home="$TMP_ROOT/t5" out
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  post "$home" "$M1" followup 2 "Reindex is running at 02:00 now."
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver("running")
tick(0)
assert name(thread) == "⏳ Aceh · nightly reindex"
PY
  ) || fail "setup marker did not land: $out"
  decision_post "$home" "$M1" 3 route-a
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver("open-question")
tick(10)
assert name(thread) == "❓ Aceh · nightly reindex", name(thread)
PY
  ) || fail "the decision button did not show ❓: $out"
  post "$home" "$M1" followup 4 "The reindex finished; nothing else is needed."
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver("done")
tick(20)
assert name(thread) == "❓ Aceh · nightly reindex" and verdicts(thread)[-1]["status"] == "done"
PY
  ) || fail "done replaced the open decision's ❓: $out"
  local generation
  for generation in {5..25}; do
    post "$home" "$M1" followup "$generation" "Reminder: the route call above still needs you."
    py "$home" <<'PY' >/dev/null || fail "decision reminder was not judged"
set_clock(CLOCK[0] + 1)
deliver("open-question")
PY
  done
  post "$home" "$M1" followup 26 "Reminder: the route call above still needs you."
  out=$(py "$home" <<'PY'
(thread,) = threads()
judge = autoname.judge
def close_while_judging(state, home):
    set_clock(CLOCK[0] + 1)
    with (HOME / "state" / "route-fix.status").open("a") as status:
        status.write("resolved [key=route-a]: answered: North\n")
    settle_decisions()
    return judge(state, home)

with patch.object(autoname, "judge", close_while_judging):
    deliver("open-question")
entries = verdicts(thread)
assert [entry for entry in entries if "judged" in entry or "confidence" in entry] == entries[-20:], entries
assert all("judged" in entry and "confidence" in entry for entry in entries[-20:]), entries
(kept_done,) = (entry for entry in entries if entry["status"] == "done")
assert "judged" not in kept_done and "confidence" not in kept_done, kept_done
summary = poster.decision_threads(HOME, thread)[thread]
assert summary["open"] == 0 and summary["last_closed_at"] > 0, summary
tick(50)
assert name(thread) == "❓ Aceh · nightly reindex", "the kept done skipped our pace"
tick(601)
assert name(thread) == "✅ Aceh · nightly reindex", "the decision reminder replaced the kept done"
print("ok")
PY
  ) || fail "the kept done did not land at the next slot after closure: $out"

  home="$TMP_ROOT/t5b"
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  decision_post "$home" "$M1" 2 route-c
  py "$home" <<'PY' >/dev/null || fail "decision setup failed"
(thread,) = threads()
deliver()
assert not verdicts(thread)
script({"disconnect": True})
tick(0)
assert name(thread) == "❓ Aceh · nightly reindex"
PY
  resolve_key "$home" route-c
  out=$(py "$home" <<'PY'
(thread,) = threads()
tick(601)
assert name(thread) == "Aceh · nightly reindex", name(thread)
path = poster.load_thread_record_by_id(thread, HOME)["path"]
old = 1_600_000_000_000_000_000
os.utime(path, ns=(old, old))
tick(1202)
assert path.stat().st_mtime_ns == old, "unchanged safety pass renewed thread retention"
data = load()
data["threads"][thread]["unreadable"] = True
save(data)
tick(1803)
tick(1833)
assert path.stat().st_mtime_ns == old, "failed safety passes renewed thread retention"
print("ok")
PY
  ) || fail "a lost decision write kept its marker after closure or renewed retention: $out"
  pass "a done judged during a decision lands at the next slot after closure; the decision's own question clears"
}

# --- 6. stale verdicts are dropped ---------------------------------------------------
#
# A verdict is stale once a newer Firstmate message reached Discord, counted
# from chunk progress, so a visible chunk of a reply whose later chunk failed
# still makes an older verdict stale. A chunk accepted while a pass computes
# stops that pass from writing.

test_6_stale_verdicts_are_dropped() {
  local home="$TMP_ROOT/t6" out
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  out=$(py "$home" <<'PY'
(thread,) = threads()
cutoff = load()["threads"][thread]["messages"][-1]["id"]
assert title.record_verdict(HOME, thread, cutoff, "running", False, "Aceh · GPU cutover") == "recorded"
newer = str(int(cutoff) + 1)
slug = next((HOME / "state" / "ext-outbox").glob("*.thread.json")).name.split(".")[0]
progress = HOME / "state" / "ext-outbox" / f"{slug}.followup.9.progress.json"
screen = poster.screened_title
def accept_while_screening(value, home):
    progress.write_text(json.dumps({"request_id": poster.load_thread_record_by_id(thread, HOME)["request_id"],
                                    "topic_thread_id": thread, "total": 2, "posted_count": 1,
                                    "discord_message_ids": [newer]}))
    return screen(value, home)

poster.screened_title = accept_while_screening
tick(0)
assert progress.exists() and patches() == [], "a concurrent accepted chunk did not stop the write"
poster.screened_title = screen
assert title.record_verdict(HOME, thread, cutoff, "done", True) == "stale"
tick(1)
assert patches() == [], "a stale verdict was applied"
assert title.record_verdict(HOME, thread, newer, "done", True) == "recorded"
tick(2)
assert name(thread) == "✅ Aceh · nightly reindex", "a newer fit verdict inherited the stale base"
assert title.record_verdict(HOME, thread, newer, "running", True) == "recorded"
reads = []
def publish_between_reads(thread_id):
    reads.append(thread_id)
    if len(reads) == 2:
        assert title.record_verdict(HOME, thread_id, newer, "blocked", True) == "recorded"
    return title.discord_read_title(HOME, thread_id)

tick(603, read_thread=publish_between_reads)
assert [p["name"] for p in patches()] == ["✅ Aceh · nightly reindex", "⚠️ Aceh · nightly reindex"], patches()

assert title.record_verdict(HOME, thread, newer, "running", True) == "recorded"
def publish_during_write(thread_id, name):
    set_clock(CLOCK[0] + 1)
    assert title.record_verdict(HOME, thread_id, newer, "done", True) == "recorded"
    script({"elapsed": 1})
    title.discord_write_title(HOME, thread_id, name)

tick(1204, rename=publish_during_write)
assert name(thread) == "⏳ Aceh · nightly reindex"
tick(1207)
assert name(thread) == "✅ Aceh · nightly reindex", "a same-cutoff verdict racing PATCH waited for the pace"
print("ok")
PY
  ) || fail "a verdict older than a visible post was used: $out"
  pass "verdicts older than a Discord-accepted chunk are dropped, at input and before the write"
}

# --- 7. the captain's own words stay for good ------------------------------------------
#
# A live base that differs from the last base Firstmate wrote is the captain's
# rename. His words stay on that thread for good, even when Jev says the topic
# drifted; only the marker changes. A marker he removes stays off until the
# thread's state changes, and a rename made while a pass computes wins.

test_7_manual_renames_keep_the_captains_words() {
  local home="$TMP_ROOT/t7" out
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · search latency" "Search latency is back to normal."
  post "$home" "$M1" followup 2 "Moving on to the OCR GPU migration you asked for next."
  out=$(py "$home" <<'PY'
(thread,) = threads()
os.environ["FM_TEST_NAME"] = "Aceh · OCR GPU migration"
deliver("running")
tick(0)
assert name(thread) == "⏳ Aceh · search latency"
captain_renames(thread, "⏳ GPU box move")
PY
  ) || fail "setup failed: $out"
  post "$home" "$M1" followup 3 "Driver versions are pinned; cutover is planned for Friday."
  out=$(py "$home" <<'PY'
(thread,) = threads()
os.environ["FM_TEST_NAME"] = "Aceh · OCR GPU migration"
deliver("drift")
assert verdicts(thread)[-1]["topic_fits"] is False
tick(601)
assert name(thread) == "⏳ GPU box move", name(thread)
assert record(thread)["manual_base"] == "GPU box move"
assert not (CAPTURE / "namer.txt").exists(), "the naming model ran on a captain-named thread"
print("ok")
PY
  ) || fail "the captain's words were replaced on topic drift: $out"
  post "$home" "$M1" followup 4 "The migration is done and verified."
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver("done")
tick(2000)
assert name(thread) == "✅ GPU box move", name(thread)
captain_renames(thread, "GPU box move")
tick(2700)
assert name(thread) == "GPU box move", "a marker the captain removed came back without a state change"
PY
  ) || fail "the marker did not follow on the captain's words: $out"
  post "$home" "$M1" followup 5 "Everything remains finished."
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver(None)
tick(3300)
assert name(thread) == "GPU box move", "an unjudged post restored the removed marker"
newest = load()["threads"][thread]["messages"][-1]["id"]
assert title.record_verdict(HOME, thread, newest, "done", True) == "recorded"
tick(3301)
assert name(thread) == "GPU box move", "a repeated state restored the removed marker"
PY
  ) || fail "a repeated state restored the removed marker: $out"
  post "$home" "$M1" followup 6 "Reopening: the new box drops jobs under load."
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver("running")
tick(3400)
assert name(thread) == "⏳ GPU box move", name(thread)
print("ok")
PY
  ) || fail "the next state change did not restore the marker: $out"

  home="$TMP_ROOT/t7b"
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · search latency" "Search latency is back to normal."
  post "$home" "$M1" followup 2 "Moving on to the OCR GPU migration you asked for next."
  out=$(py "$home" <<'PY'
(thread,) = threads()
os.environ["FM_TEST_NAME"] = "Aceh · OCR GPU migration"
propose = autoname.propose_name
def finish_later(state, home):
    assert verdicts(thread)[-1]["audit_only"] is True
    set_clock(T0 + 2)
    return propose(state, home)

with patch.object(autoname, "propose_name", finish_later):
    assert deliver("drift") == ["sent"]
assert verdicts(thread)[-1]["base"] == "Aceh · OCR GPU migration", verdicts(thread)
assert verdicts(thread)[-1]["at"] == T0 + 2, verdicts(thread)
reads = []
def rename_between_reads(thread_id):
    reads.append(thread_id)
    if len(reads) == 2:
        captain_renames(thread_id, "GPU box move")
    return title.discord_read_title(HOME, thread_id)

tick(2, read_thread=rename_between_reads)
assert not any("OCR GPU migration" in p["name"] for p in patches()), patches()
assert name(thread).endswith("GPU box move") and record(thread)["manual_base"] == "GPU box move", name(thread)
print("ok")
PY
  ) || fail "a rename made during a pass was overwritten: $out"
  pass "the captain's words stay for good, even mid-pass; a removed marker waits for a state change"
}

# --- 8. catch-up: ten newest threads, fixed before the first call, resumes ---------------
#
# The first judge scan fixes its ten-thread list and the newest message at
# that moment before the first model call. Each verdict is the thread's own
# progress, so a restart resumes without repeating a finished thread's model
# calls or renames, and older threads wait for a newer post.

test_8_catch_up_resumes_after_restart() {
  local home="$TMP_ROOT/t8" out i
  setup_home "$home" off
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    new_thread "$home" "4444444444444444$i" "Aceh · topic $i" "Working on topic $i."
  done
  printf 'TYPESAFE_API_KEY=%s\n' fixture-key > "$home/.env"
  for kill_at in 1 4; do
    home_env "$home" env FM_TEST_KILL_AT="$kill_at" "$PYTHON_BIN" -c '
import os, sys
from driver import *
os.environ["FM_TEST_KILL_PID"] = str(os.getpid())
use("running")
autoname.judge_scan(HOME)
' >/dev/null 2>&1 && fail "the judge scan was not interrupted at call $kill_at"
    out=$(py "$home" <<PY
state = json.loads((HOME / "state" / "ext-autoname" / "catch-up.json").read_text())
assert len(state["threads"]) == 10, state
names = {t: name(t) for t in threads()}
assert {names[t] for t in state["threads"]} == {"Aceh · topic %02d" % n for n in range(3, 13)}, state
judged = [t for t in threads() if verdicts(t)]
assert len(judged) == {1: 0, 4: 2}[$kill_at], judged
print("ok")
PY
    ) || fail "the judge scan did not save its list and progress (kill at $kill_at): $out"
  done
  out=$(py "$home" <<'PY'
use("running")
judged = autoname.judge_scan(HOME)
assert len(judged) == 8, judged
tick(0)
assert autoname.judge_scan(HOME, retry_failed=True) == []
calls = [call["state"]["thread"]["name"] for call in jev_calls()]
counts = {n: calls.count(n) for n in set(calls)}
assert set(counts) == {"Aceh · topic %02d" % n for n in range(3, 13)}, counts
repeated = sorted(n for n, c in counts.items() if c > 1)
assert len(repeated) == 2 and len(calls) == 12, counts
written = [p["thread"] for p in patches()]
assert len(written) == 10 == len(set(written)), patches()
print("ok")
PY
  ) || fail "the judge scan repeated finished threads or went past ten: $out"
  post "$home" "444444444444444401" followup 2 "Topic 01 is moving again."
  out=$(py "$home" <<'PY'
before = len(jev_calls())
deliver("running")
calls = jev_calls()[before:]
assert [c["state"]["thread"]["name"] for c in calls] == ["Aceh · topic 01"], calls
print("ok")
PY
  ) || fail "an older thread was not judged after a newer post: $out"
  pass "catch-up fixes ten threads before the first call, resumes without repeats, and older threads wait for a post"
}

# --- 9. judging stays off the delivery path, and failures leave the title alone ----------
#
# Delivery returns while Jev is still thinking. A Jev failure, a naming-model
# failure, and a Discord write failure each leave the title unchanged; the
# Discord failure is retried. One shared key check decides whether judging is
# on, and gateway subprocesses other than the judge never see the key.

test_9_judging_never_delays_replies_and_failures_keep_the_title() {
  local home="$TMP_ROOT/t9" out ENV_KEY=from-env
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · search latency" "Search latency is back to normal."
  post "$home" "$M1" followup 2 "A worker is checking the cache warm-up."
  out=$(home_env "$home" env FM_TEST_JEV_HOLD=1 "$PYTHON_BIN" -c '
import sys, time
from driver import *
(thread,) = threads()
use("blocked")
assert poster.drain_outbox(send=send, home=HOME, react=lambda *a: None, create_thread=create) == ["sent"]
# The judge is held until this process releases it, so a delivery that waited
# for judging could not have returned before the verdict was recorded.
assert not verdicts(thread), "delivery returned only after the judge finished"
assert any(t.name == "fm-ext-autoname" and t.is_alive() for t in threading.enumerate())
for _ in range(250):
    if (CAPTURE / "jev-entered").exists():
        break
    time.sleep(0.02)
assert (CAPTURE / "jev-entered").exists(), "the judge never started"
assert not verdicts(thread)
(CAPTURE / "jev-release").write_text("")
settle()
assert verdicts(thread)[-1]["status"] == "blocked"
print("ok")
') || fail "delivery waited for the judge: $out"
  rm -f "$home/capture/jev-entered" "$home/capture/jev-release"
  post "$home" "$M1" followup 3 "Cache is warm; checking the next box."
  post "$home" "$M1" followup 4 "Moving on to the OCR GPU migration you asked for next."
  out=$(py "$home" <<'PY'
(thread,) = threads()
script({"remaining": "0"})
tick(0)
assert name(thread) == "⚠️ Aceh · search latency"
set_clock(T0 + 1)
before = verdicts(thread)
calls = len(jev_calls())
with only("followup.3"):
    assert deliver(None) == ["sent"]
assert len(jev_calls()) == calls + 1
assert jev_calls()[-1]["state"]["thread"]["messages"][-1]["text"] == "Cache is warm; checking the next box."
assert verdicts(thread) == before, "a failed Jev call changed the inputs"
os.environ.pop("FM_TEST_NAME", None)
assert deliver("drift") == ["sent"]
assert len(jev_calls()) == calls + 2
entry = verdicts(thread)[-1]
assert verdicts(thread)[:-1] == before
assert entry["audit_only"] is True and entry["base"] == "", entry
assert entry["message_id"] == load()["threads"][thread]["messages"][-1]["id"], entry
assert (entry["status"], entry["topic_fits"], entry["confidence"]) == ("running", False, 0.95), entry
assert entry["judged"] == {"name": "Aceh · search latency", "project": "Aceh", "messages": 4}, entry
tick(601)
assert name(thread) == "⚠️ Aceh · search latency" and len(patches()) == 1, patches()
assert autoname.judge_scan(HOME, retry_failed=True) == []
assert len(jev_calls()) == calls + 3
assert len(verdicts(thread)) == len(before) + 2, "the audit entry suppressed a retry"
print("ok")
PY
  ) || fail "a Jev or naming failure changed the title: $out"
  post "$home" "$M1" followup 5 "All done; the box is migrated."
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver("done")
script({"status": 500})
tick(1300)
assert patches()[-1]["status"] == 500 and name(thread) == "⚠️ Aceh · search latency", patches()
assert record(thread)["last"]["outcome"] == "failed"
tick(1300 + title.RETRY_SECS)
assert name(thread) == "✅ Aceh · search latency", name(thread)
print("ok")
PY
  ) || fail "a Discord failure was not left alone and retried: $out"

  mkdir -p "$TMP_ROOT/no-key-home" "$TMP_ROOT/bad-key-home/.env" "$TMP_ROOT/inactive-config"
  out=$(home_env "$home" env FM_HOME="$TMP_ROOT/no-key-home" "$JUDGE" --check)
  [ "$out" = off ] || fail "the judge check with no key anywhere said: $out"
  out=$(home_env "$home" "$JUDGE" --check)
  [ "$out" = on ] || fail "the judge check with the home .env key said: $out"
  out=$(home_env "$home" env FM_HOME="$TMP_ROOT/no-key-home" "TYPESAFE_API_KEY=$ENV_KEY" "$JUDGE" --check)
  [ "$out" = on ] || fail "the judge check with an environment key said: $out"
  out=$(home_env "$home" env FM_HOME="$TMP_ROOT/bad-key-home" "$JUDGE" --check)
  [ "$out" = unknown ] || fail "the judge check with an unreadable .env said: $out"
  out=$(home_env "$home" env FM_CONFIG_OVERRIDE="$TMP_ROOT/inactive-config" "$JUDGE" --check)
  [ "$out" = inactive ] || fail "the judge check with the bridge off said: $out"
  out=$(home_env "$home" env "TYPESAFE_API_KEY=$ENV_KEY" "$PYTHON_BIN" -c '
import sys
from driver import *
from tool_path import firstmate_env
assert "TYPESAFE_API_KEY" not in firstmate_env(HOME, poster.firstmate_root())
assert firstmate_env(HOME, poster.firstmate_root(), jev=True)["TYPESAFE_API_KEY"] == "from-env"
print("ok")
') || fail "the gateway leaked the Jev key to a subprocess: $out"
  pass "judging runs off the delivery path, failures keep the title, and one key check gates judging"
}

# --- 10. Discord's limits hold across threads, slow answers, and lost answers -------------
#
# A bot-wide 429, from a write or from a title read, holds every thread, timed
# from when Discord answered. A write whose answer was lost still counts as
# our write and keeps its pace.

test_10_title_request_limits_survive_a_slow_response_and_lost_ack() {
  local home="$TMP_ROOT/t10" out
  setup_home "$home" off
  new_thread "$home" "$M1" "Aceh · first thread" "Starting the first task."
  new_thread "$home" "444444444444444442" "Aceh · second thread" "Starting the second task."
  post "$home" "$M1" followup 2 "The first task is finished." --thread-state "done"
  post "$home" "444444444444444442" followup 2 "The second task is finished." --thread-state "done"
  out=$(py "$home" <<'PY'
a, b = threads()
deliver()
script({"status": 429, "retry_after": 7.5, "global": True, "elapsed": 10})
tick(0)
assert len(patches()) == 1, "a global PATCH limit allowed the next thread to write"
tick(17)
assert len(patches()) == 1, "the wait was measured before Discord responded"
data = load()
data["read_limits"] = [5]
save(data)
tick(18)
assert len(patches()) == 1, "a global GET limit allowed the next thread to write"
tick(22)
assert len(patches()) == 1
script({"disconnect": True, "elapsed": 10})
tick(23)
assert len(patches()) == 3, patches()
lost = patches()[1]["thread"]
assert name(lost).startswith("✅ ")
print(lost)
PY
  ) || fail "Discord title request limits failed: $out"
  local lost=${out##*$'\n'} message
  message=$(home_env "$home" "$PYTHON_BIN" -c '
import sys
from driver import *
record = poster.load_thread_record_by_id(sys.argv[1], HOME)
print(record["request_id"].split(":")[-1])' "$lost")
  post "$home" "$message" followup 3 "Another task is starting." --thread-state none
  out=$(py "$home" <<'PY'
lost = patches()[1]["thread"]
set_clock(T0 + 40)
deliver()
tick(64)
tick(632)
assert len(patches()) == 3, "a lost PATCH response erased the pace of the landed write"
tick(633)
assert len(patches()) == 4 and not name(lost).startswith("✅ "), patches()
print("ok")
PY
  ) || fail "a lost write answer lost its pace: $out"
  pass "bot-wide waits apply across threads from the answer time, and a lost write answer keeps its pace"
}

# --- 11. partial replies are judged; private labels stay private --------------------------

test_11_partial_posts_are_judged_and_private_labels_stay_private() {
  local home="$TMP_ROOT/t11" out text
  setup_home "$home"
  new_thread "$home" "$M1" "Search status" "Starting the first task."
  text=$(awk 'BEGIN {for (i = 0; i < 420; i++) printf "progress "; print ""}')
  post "$home" "$M1" followup 2 "$text"
  out=$(py "$home" <<'PY'
(thread,) = threads()
topic = poster.load_thread_record_by_id(thread, HOME)
(HOME / "state" / "private-task.meta").write_text(
    f"ext_request={topic['request_id']}\nproject=/private/Undisclosed Project\n")
first_name = name(thread)
assert " · " not in first_name, first_name
earlier_calls = len(jev_calls())
use("drift")
os.environ["FM_TEST_NAME"] = "Undisclosed Project · search"
def refuse_next(payload):
    if payload["chunk_index"] > 0:
        raise poster.DiscordSendError("permanent", "Discord refused a later chunk")
    return send(payload)

assert poster.drain_outbox(send=refuse_next, home=HOME, react=lambda *a: None) == ["terminal-failed"]
settle()
calls = jev_calls()[earlier_calls:]
assert len(calls) == 1, len(calls)
assert calls[0]["state"]["thread"]["project"] == ""
assert not (CAPTURE / "namer.txt").exists(), "a private checkout name reached the naming model"
tick(0)
assert name(thread) == "⏳ " + first_name, name(thread)
print("ok")
PY
  ) || fail "a partially delivered reply was skipped or exposed a private label: $out"
  pass "an accepted chunk is judged even if a later chunk fails, without sourcing private labels"
}

# --- 12. legacy intent, and no title work without a clear key check or bridge ------------

test_12_legacy_intent_and_unclear_checks_keep_the_title() {
  local home="$TMP_ROOT/t12" out
  setup_home "$home" off
  new_thread "$home" "$M1" "Aceh · legacy thread" "The legacy task is complete."
  post "$home" "$M1" followup 2 "Another task is starting." --thread-state none
  out=$(py "$home" <<'PY'
(thread,) = threads()
topic = poster.load_thread_record_by_id(thread, HOME)
question_name = "❓ Aceh · legacy thread"
with topic["path"].open("w") as state:
    json.dump({"request_id": topic["request_id"], "topic_thread_id": thread, "creator": "firstmate",
               "topic_name": question_name, "marked_open": True,
               "thread_state": "needs-you", "rename": {"outcome": "failed"}}, state)
captain_renames(thread, question_name)
# Replies delivered before the reconciler kept no title input in their progress.
for path in (HOME / "state" / "ext-outbox").glob("*.progress.json"):
    data = json.loads(path.read_text())
    data.pop("title_input", None)
    path.write_text(json.dumps(data))
tick(0)
assert name(thread) == "Aceh · legacy thread", name(thread)
with topic["path"].open("w") as state:
    json.dump({"request_id": topic["request_id"], "topic_thread_id": thread, "creator": "firstmate",
               "topic_name": question_name, "marked_open": True, "deferred_state": "done"}, state)
captain_renames(thread, question_name)
tick(1)
assert name(thread) == "✅ Aceh · legacy thread", name(thread)

check = autoname.subprocess.run
def failed_check(args, *pos, **kwargs):
    if args[-1] == "--check":
        raise autoname.subprocess.TimeoutExpired(args, 30)
    return check(args, *pos, **kwargs)

with patch.object(autoname.subprocess, "run", failed_check):
    assert deliver() == ["sent"]
    tick(601)
assert name(thread) == "✅ Aceh · legacy thread", "a failed key check enabled the explicit fallback"
(HOME / "config" / "ext-bridge").unlink()
tick(1300)
assert name(thread) == "✅ Aceh · legacy thread" and len(patches()) == 2, "title work ran with the bridge off"
print("ok")
PY
  ) || fail "legacy intent or check handling failed: $out"
  pass "a legacy deferred done lands; an unclear key check or a disabled bridge leaves the title alone"
}

# --- 13. a write that raced newer state is corrected without our pace ---------------------
#
# A reply Discord accepted while our title write was in flight makes that
# write wrong. The next pass corrects it at once; a change that arrives after
# the write landed still waits for the pace.

test_13_a_raced_write_is_corrected_without_waiting() {
  local home="$TMP_ROOT/t13" out
  setup_home "$home" off
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  post "$home" "$M1" followup 2 "The reindex finished." --thread-state "done"
  post "$home" "$M1" followup 3 "A follow-up run is starting." --thread-state none
  post "$home" "$M1" followup 4 "The follow-up run finished." --thread-state "done"
  out=$(py "$home" <<'PY'
(thread,) = threads()
with only("followup.2"):
    deliver()

def accept_reply_mid_write(thread_id, name):
    with only("followup.3"):
        deliver()
    script({"elapsed": 5})
    return title.discord_write_title(HOME, thread_id, name)

tick(0, rename=accept_reply_mid_write)
assert name(thread) == "✅ Aceh · nightly reindex", patches()
tick(6)
assert name(thread) == "Aceh · nightly reindex", "the raced write was not corrected at once"
set_clock(T0 + 10)
deliver()
tick(20)
assert name(thread) == "Aceh · nightly reindex", "a later change skipped the pace"
tick(607)
assert name(thread) == "✅ Aceh · nightly reindex", name(thread)
print("ok")
PY
  ) || fail "a raced title write was not corrected: $out"
  pass "a write that raced an accepted reply is corrected at once; later changes keep the pace"
}

test_get_cooldowns_gate_compare_and_history() {
  local home="$TMP_ROOT/gets" out
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  post "$home" "$M1" followup 2 "Reindex moved to 02:00; first run is under way."
  out=$(py "$home" <<'PY'
(thread,) = threads()
deliver("running")
channel = "/channels/" + thread
data = load()
data["gets"] = []
data["title_reset"] = T0 + 12.5
save(data)
tick(0)
assert load()["gets"] == [channel], load()["gets"]
assert patches() == []
tick(12.49)
assert load()["gets"] == [channel] and patches() == []
tick(12.5)
assert name(thread) == "⏳ Aceh · nightly reindex", patches()
PY
  ) || fail "a successful title GET did not hold the compare read and PATCH: $out"
  post "$home" "$M1" followup 3 "The reindex finished."
  out=$(py "$home" <<'PY'
(thread,) = threads()
channel = "/channels/" + thread
data = load()
data["gets"] = []
data["title_reset"] = T0 + 25
save(data)
before = len(jev_calls())
deliver("done")
assert load()["gets"] == [channel] and len(jev_calls()) == before
set_clock(T0 + 24.99)
autoname.start_due(HOME)
settle()
assert load()["gets"] == [channel] and len(jev_calls()) == before
set_clock(T0 + 25)
autoname.start_due(HOME)
settle()
assert load()["gets"] == [channel, channel, channel + "/messages"], load()["gets"]
assert len(jev_calls()) == before + 1 and verdicts(thread)[-1]["status"] == "done"
PY
  ) || fail "a judge did not wait for Discord and resume at expiry: $out"
  pass "a successful title GET holds compare and history reads, and the judge resumes at expiry"
}

# --- 14. the judge reads the reply's own state, and every call is logged ---------------
#
# The judged reply's explicit state reaches the judge, and a reply that
# declared no state is judged without that field. A `done` closing reply ends at
# ✅ even when an earlier open question is still in the history. Each verdict
# records the judge's input summary and confidence, never message text.

test_14_the_judge_reads_the_reply_state_and_logs_each_call() {
  local home="$TMP_ROOT/t14" out
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  post "$home" "$M1" followup 2 "Which window should the reindex use, 02:00 or 03:00?"
  out=$(py "$home" <<'PY'
(thread,) = threads()
calls = len(jev_calls())
assert deliver("open-question") == ["sent"]
assert len(jev_calls()) == calls + 1
script({"remaining": "0"})
tick(0)
assert name(thread) == "❓ Aceh · nightly reindex", name(thread)
sent = jev_calls()[-1]["state"]["thread"]
assert (sent["name"], sent["project"]) == ("Aceh · nightly reindex", "Aceh"), sent
assert "reply_state" not in sent, sent
assert [(m["role"], m["text"]) for m in sent["messages"]] == [
    ("firstmate", "Looking at the reindex schedule now."),
    ("firstmate", "Which window should the reindex use, 02:00 or 03:00?"),
], sent["messages"]
assert all(m.get("reply") for m in sent["messages"]), sent["messages"]
assert sent["messages"][0]["reply"] != sent["messages"][1]["reply"], sent["messages"]
entry = verdicts(thread)[-1]
assert (entry["status"], entry["topic_fits"], entry["confidence"]) == ("open-question", True, 1.0), entry
assert entry["judged"] == {"name": "Aceh · nightly reindex", "project": "Aceh",
                           "messages": 2}, entry
assert entry["message_id"] == load()["threads"][thread]["messages"][-1]["id"], entry
print("ok")
PY
  ) || fail "the judge input or log record was wrong without a declared state: $out"
  post "$home" "$M1" answer 3 "Noted: the QA gate still waits for your word. Closing this thread." \
    --thread-state "done"
  out=$(py "$home" <<'PY'
(thread,) = threads()
set_clock(T0 + 1)
calls = len(jev_calls())
assert deliver("done") == ["sent"]
assert len(jev_calls()) == calls + 1
sent = jev_calls()[-1]["state"]["thread"]
assert (sent["name"], sent["project"], sent["reply_state"]) == (
    "Aceh · nightly reindex", "Aceh", "done"), sent
assert [m["text"] for m in sent["messages"]] == [
    "Looking at the reindex schedule now.",
    "Which window should the reindex use, 02:00 or 03:00?",
    "Noted: the QA gate still waits for your word. Closing this thread.",
], sent["messages"]
assert len({m.get("reply") for m in sent["messages"]}) == 3, sent["messages"]
assert all(m.get("reply") for m in sent["messages"]), sent["messages"]
script({"remaining": "0"})
tick(601)
assert name(thread) == "✅ Aceh · nightly reindex", name(thread)
assert verdicts(thread)[-2]["status"] == "open-question", "the earlier question lost its verdict"
entry = verdicts(thread)[-1]
assert (entry["status"], entry["topic_fits"], entry["confidence"]) == ("done", True, 1.0), entry
assert entry["message_id"] == load()["threads"][thread]["messages"][-1]["id"], entry
assert entry["judged"] == {"name": "Aceh · nightly reindex", "project": "Aceh",
                           "reply_state": "done", "messages": 3}, entry
logged = json.dumps(verdicts(thread))
assert "QA gate still waits" not in logged and "Which window" not in logged, "message text was logged"
print("ok")
PY
  ) || fail "a done closing reply did not end at ✅ or its log was wrong: $out"
  post "$home" "$M1" followup 4 "Closing reply removed before judging." --thread-state 'done'
  post "$home" "$M1" followup 5 "Wrap-up with another chunk on the way." --thread-state 'done'
  out=$(py "$home" <<'PY'
from driver import _append

(thread,) = threads()
set_clock(T0 + 602)
before = verdicts(thread)
calls = len(jev_calls())
with patch.object(autoname, "after_post"), only("followup.4"):
    assert deliver("done") == ["sent"]
data = load()
data["threads"][thread]["messages"].pop()
save(data)
history_path = f"/channels/{thread}/messages"
history_reads = data["gets"].count(history_path)
assert autoname.judge_scan(HOME) == []
assert load()["gets"].count(history_path) == history_reads + 1, "the scan skipped the history read"
assert len(jev_calls()) == calls, "the deleted reply was judged"
assert verdicts(thread)[:-1] == before and verdicts(thread)[-1]["skip_reason"] == "incomplete reply, chunk deleted"

with patch.object(autoname, "after_post"):
    assert deliver("blocked") == ["sent"]
selected = load()["threads"][thread]["messages"][-1]["id"]
progress = next((HOME / "state" / "ext-outbox").glob("*.followup.5.progress.json"))
read_history = title.discord_read_messages
def next_chunk_lands(*args):
    newer = _append(thread, BOT, "The second chunk.")
    state = json.loads(progress.read_text())
    state["discord_message_ids"].append(newer)
    state.update(total=2, posted_count=2)
    progress.write_text(json.dumps(state))
    return read_history(*args)

with patch.object(title, "discord_read_messages", next_chunk_lands):
    assert autoname.judge_scan(HOME) == []
assert len(jev_calls()) == calls + 1, "the scan skipped the selected chunk"
entry = verdicts(thread)[-1]
sent = jev_calls()[-1]["state"]["thread"]
assert sent["reply_state"] == "done", sent
assert sent["messages"][-1]["text"] == "Wrap-up with another chunk on the way.", sent
assert sent["messages"][-1].get("reply"), sent
assert entry["message_id"] == selected and entry["audit_only"] is True, entry
assert entry["status"] == "blocked" and entry["judged"]["reply_state"] == "done", entry
tick(1202)
assert name(thread) == "✅ Aceh · nightly reindex", name(thread)
use("done")
assert autoname.judge_scan(HOME) == [thread]
assert len(jev_calls()) == calls + 2
assert jev_calls()[-1]["state"]["thread"]["messages"][-1]["text"] == "The second chunk."
print("ok")
PY
  ) || fail "the accepted message, reply state, and verdict came apart: $out"
  pass "the judge receives the judged reply's state when it declared one and nothing when it did not, a done closing reply ends at ✅, and each call logs its input and confidence"
}

# --- 15. the judge criteria keep a closing note and a question apart ------------------
#
# A closing message that only notes a pending approval or gate meets only the
# done criterion, and a message that needs the captain to answer meets only
# open-question. The judge receives both rules in the criteria it is asked, so
# this asserts the request itself rather than a canned verdict.

test_15_the_judge_criteria_keep_a_closing_note_and_a_question_apart() {
  local home="$TMP_ROOT/t15" out
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  post "$home" "$M1" answer 2 "Noted: the QA gate still waits for your word. Closing this thread." \
    --thread-state "done"
  out=$(py "$home" <<'PY'
assert deliver() == ["sent"]
call = jev_calls()[-1]
criteria = call["questions"]["status"]["criteria"]
assert call["state"]["thread"]["messages"][-1]["text"] == \
    "Noted: the QA gate still waits for your word. Closing this thread.", call
assert call["state"]["thread"]["reply_state"] == "done", call
assert "closes out the work and only notes a pending approval" in criteria["open-question"], criteria
assert "needs the captain to answer, decide, or approve" in criteria["open-question"], criteria
assert "even if it reports a completed step" in criteria["open-question"], criteria
assert "closes the work in this thread, and no response, decision, or approval from the captain is required" in criteria["done"], criteria
assert "A completed step such as a merge or handoff qualifies only if it closes the work in this thread." in criteria["done"], criteria
assert "Work that remains under way, queued, or stopped by an obstacle is still open." in criteria["done"], criteria
assert "Apply both conditions regardless of `thread.reply_state`" in criteria["done"], criteria
assert "leaves work open" in criteria["running"] and "leaves work open" in criteria["blocked"], criteria
assert "Continuing the work does not require a response, decision, or approval from the captain" in criteria["blocked"], criteria
assert "newest reply" in call["questions"]["status"]["instructions"], call["questions"]["status"]
assert "`reply`" in call["questions"]["status"]["instructions"], call["questions"]["status"]
print("ok")
PY
  ) || fail "the closing noting a gate did not reach the done-only criteria: $out"
  post "$home" "$M1" followup 3 "I merged the change. Production deployment needs your approval before I can proceed."
  out=$(py "$home" <<'PY'
assert deliver() == ["sent"]
call = jev_calls()[-1]
assert call["state"]["thread"]["messages"][-1]["text"] == \
    "I merged the change. Production deployment needs your approval before I can proceed.", call
assert "reply_state" not in call["state"]["thread"], call
print("ok")
PY
  ) || fail "the captain-approval wait did not reach the judge as the newest message: $out"
  post "$home" "$M1" followup 4 "Which window should the reindex use, 02:00 or 03:00?"
  out=$(py "$home" <<'PY'
assert deliver() == ["sent"]
call = jev_calls()[-1]
assert call["state"]["thread"]["messages"][-1]["text"] == \
    "Which window should the reindex use, 02:00 or 03:00?", call
assert "reply_state" not in call["state"]["thread"], call
print("ok")
PY
  ) || fail "the explicit question did not reach the judge as the newest message: $out"
  post "$home" "$M1" followup 5 "I merged the fix. Deployment is still blocked on the vendor credential."
  post "$home" "$M1" followup 6 "I merged the fix. Deployment is queued."
  out=$(py "$home" <<'PY'
with only("followup.5"):
    assert deliver() == ["sent"]
assert jev_calls()[-1]["state"]["thread"]["messages"][-1]["text"] == (
    "I merged the fix. Deployment is still blocked on the vendor credential."
)
assert deliver() == ["sent"]
assert jev_calls()[-1]["state"]["thread"]["messages"][-1]["text"] == "I merged the fix. Deployment is queued."
print("ok")
PY
  ) || fail "the queued deployment did not reach the judge as the newest message: $out"
  pass "the judge request carries the done-only closing rule and the open-question rule for a wait on the captain, and each shape reaches it as the newest message"
}

# --- 16. a reply Discord split is judged as one reply --------------------------------
#
# A long close-out becomes two Discord chunks. Both carry the same reply id, and
# the criteria tell the judge to read the newest reply through all its chunks, so
# a final chunk that only notes a gate ends done instead of standing alone.

test_16_a_split_reply_is_judged_as_one_reply() {
  local home="$TMP_ROOT/t16" out
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  local text=$'Deployment handed off. Closing this thread.\n\nExternal gate still awaits vendor approval.'
  FM_EXT_DISCORD_REPLY_MAX_CHARS=50
  export FM_EXT_DISCORD_REPLY_MAX_CHARS
  post "$home" "$M1" followup 2 "$text" --thread-state "done"
  out=$(py "$home" <<'PY'
(thread,) = threads()
os.environ["FM_TEST_SPLIT_JUDGE"] = "1"
assert deliver() == ["sent"]
sent = jev_calls()[-1]["state"]["thread"]
texts = [m["text"] for m in sent["messages"]]
assert len(texts) == 3 and texts[0] == "Looking at the reindex schedule now.", texts
assert "Closing this thread." in texts[1], texts
assert texts[2] == "External gate still awaits vendor approval.", texts
assert sent["reply_state"] == "done", sent
assert sent["messages"][1]["reply"] == sent["messages"][2]["reply"], sent["messages"]
assert {m["reply"] for m in sent["messages"]} == {1, 2}, sent["messages"]
tick(0)
assert name(thread) == "✅ Aceh · nightly reindex", name(thread)
usable = [entry for entry in verdicts(thread) if not entry.get("audit_only")]
assert usable[-1]["judged"]["messages"] == 3, usable[-1]
print("ok")
PY
  ) || fail "the split reply did not reach the judge as one reply or did not end done: $out"
  unset FM_EXT_DISCORD_REPLY_MAX_CHARS
  post "$home" "$M1" followup 3 "External gate still awaits vendor approval."
  out=$(py "$home" <<'PY'
(thread,) = threads()
set_clock(T0 + 601)
os.environ["FM_TEST_SPLIT_JUDGE"] = "1"
assert deliver() == ["sent"]
tick(601)
usable = [entry for entry in verdicts(thread) if not entry.get("audit_only")]
assert usable[-1]["status"] == "blocked", usable[-1]
assert usable[-1]["message_id"] == load()["threads"][thread]["messages"][-1]["id"]
print("ok")
PY
  ) || fail "the same gate note sent alone did not produce a blocked verdict: $out"

  home="$TMP_ROOT/t16long"
  setup_home "$home"
  new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
  local padding
  printf -v padding ' routine log entry %.0s' {1..450}
  post "$home" "$M1" followup 2 "Deployment handed off. Closing this thread.$padding External gate still awaits vendor approval."
  out=$(py "$home" <<'PY'
from driver import _append

(thread,) = threads()
os.environ["FM_TEST_SPLIT_JUDGE"] = "1"
os.environ["FM_TEST_SPLIT_DRIFT"] = "1"
os.environ["FM_TEST_NAME"] = "Aceh · deployment handoff"
accepted = []
def busy_send(payload):
    receipt = send(payload)
    accepted.append(receipt["discord_message_id"])
    if len(accepted) == 1:
        for _ in range(41):
            _append(thread, os.environ["FM_TEST_CAPTAIN"], "A separate discussion.")
    return receipt

with patch.object(autoname, "after_post"):
    assert poster.drain_outbox(send=busy_send, home=HOME, react=lambda *args: None) == ["sent"]
assert autoname.judge_scan(HOME) == [thread]
messages = jev_calls()[-1]["state"]["thread"]["messages"]
published = [m["content"] for m in load()["threads"][thread]["messages"] if m["id"] in accepted]
assert len(accepted) == 5 and sum(map(len, published)) > 8000, accepted
assert [m["text"] for m in messages if m.get("reply") == messages[-1]["reply"]] == published
assert any(v.get("status") == "done" and not v.get("audit_only") for v in verdicts(thread)), verdicts(thread)
prompt = (CAPTURE / "namer.txt").read_text().partition("--- conversation ---\n")[2]
assert "Closing this thread." not in prompt and "routine log entry" in prompt, prompt
assert sum(len(line.partition(": ")[2]) for line in prompt.splitlines() if not line.startswith("current name:")) <= 8000
print("ok")
PY
  ) || fail "the latest reply lost chunks outside the optional history limits: $out"
  pass "split close-outs keep their full text and the judge distinguishes a standalone gate note"
}

# --- 17. a drift rename may move to another known project label ----------------------
#
# An approved public label may be used before a project has its own thread.
# Prior titles cannot authorize a switch. Test 7 owns captain-name protection.

test_17_a_drift_rename_may_move_to_another_known_project_label() {
  local home="$TMP_ROOT/t17a" out
  setup_home "$home"
  new_thread "$home" "$M1" "Hybrid Search Engine · log check" "Search latency is back to normal."
  post "$home" "$M1" followup 2 "Moving on to the Firstmate thread-title judge you asked about."
  out=$(py "$home" <<'PY'
first = next(t for t in threads() if "log check" in name(t))
os.environ["FM_TEST_NAME"] = "Firstmate · thread title judge fix"
assert deliver("drift") == ["sent"]
assert verdicts(first)[-1]["topic_fits"] is False, verdicts(first)
tick(0)
assert name(first) == "⏳ Firstmate · thread title judge fix", name(first)
prompt = (CAPTURE / "namer.txt").read_text()
assert "--- known project labels ---" in prompt, prompt
assert "--- known project labels ---\nFirstmate\n" in prompt, prompt
assert "Keep the current project label unless the conversation has clearly moved" in prompt, prompt
assert not record(first).get("manual_base"), record(first)
print("ok")
PY
  ) || fail "a drift rename did not move to another known project label: $out"

  home="$TMP_ROOT/t17b"
  setup_home "$home"
  mkdir -p "$home/data"
  printf '%s\n' '- aceh-repo [direct-PR +yolo] - registered project (added 2026-11-23)' \
    '- private-client - registered project (added 2026-11-23)' > "$home/data/projects.md"
  printf 'aceh-repo\tAceh\nunregistered\tGhost Project\nprivate-client\t/build/private\n' \
    > "$home/config/ext-project-labels"
  new_thread "$home" "$M1" "Hybrid Search Engine · log check" "Search latency is back to normal."
  post "$home" "$M1" followup 2 "Another pass over the same log."
  out=$(py "$home" <<'PY'
(thread,) = threads()
os.environ["FM_TEST_NAME"] = "Hybrid Search Engine · log check follow-up"
assert deliver("drift") == ["sent"]
tick(0)
assert name(thread) == "⏳ Hybrid Search Engine · log check follow-up", name(thread)
prompt = (CAPTURE / "namer.txt").read_text()
assert "--- known project labels ---\nAceh\nFirstmate\n" in prompt, prompt
assert "Keep the current project label unless the conversation has clearly moved" in prompt, prompt
assert all(label not in prompt for label in ("aceh-repo", "private-client", "Ghost Project", "/build/private")), prompt
print("ok")
PY
  ) || fail "a drift rename that keeps the thread project did not keep its prefix: $out"
  post "$home" "$M1" followup 3 "Moving to Aceh ingestion."
  out=$(py "$home" <<'PY'
(thread,) = threads()
set_clock(T0 + 601)
os.environ["FM_TEST_NAME"] = "Aceh · ingestion checks"
assert deliver("drift") == ["sent"]
tick(601)
assert name(thread) == "⏳ Aceh · ingestion checks", name(thread)
print("ok")
PY
  ) || fail "a registered project's configured public label did not authorize a switch: $out"

  home="$TMP_ROOT/t17c"
  local M2=444444444444444442
  setup_home "$home"
  new_thread "$home" "$M1" "Hybrid Search Engine · log check" "Search latency is back to normal."
  new_thread "$home" "$M2" "Ghost Project · prior title" "A previous discussion."
  post "$home" "$M1" followup 2 "Another pass over the same log."
  out=$(py "$home" <<'PY'
thread = next(t for t in threads() if "log check" in name(t))
os.environ["FM_TEST_NAME"] = "Ghost Project · invented prefix"
assert deliver("drift") == ["sent"]
tick(0)
assert name(thread) == "Hybrid Search Engine · log check", name(thread)
assert not any("Ghost" in p["name"] for p in patches(thread)), patches(thread)
assert "Ghost Project" not in (CAPTURE / "namer.txt").read_text()
print("ok")
PY
  ) || fail "an unknown project label was not refused: $out"
  pass "a drift rename moves to another known project label, keeps the thread label otherwise, and refuses an unknown prefix"
}

test_unjudgeable_replies_hold_the_marker() {
  local scenario home text out
  for scenario in deleted oversized; do
    home="$TMP_ROOT/skip-$scenario"
    setup_home "$home"
    new_thread "$home" "$M1" "Aceh · nightly reindex" "Looking at the reindex schedule now."
    case "$scenario" in
      deleted) text=$'Deployment handed off. Closing this thread.\n\nExternal gate still awaits vendor approval.' ;;
      oversized) printf -v text ' ordinary log entry %.0s' {1..2450} ;;
    esac
    post "$home" "$M1" followup 2 "$text"
    post "$home" "$M1" followup 3 "The reindex finished."
    out=$(FM_TEST_SKIP_CASE="$scenario" py "$home" <<'PY'
(thread,) = threads()
use("running")
assert autoname.judge_scan(HOME, retry_failed=True) == [thread]
tick(0)
previous = name(thread)
assert previous == "⏳ Aceh · nightly reindex", previous
set_clock(T0 + 601)
scenario = os.environ["FM_TEST_SKIP_CASE"]
if scenario == "deleted":
    os.environ["FM_EXT_DISCORD_REPLY_MAX_CHARS"] = "50"
    reason = "incomplete reply, chunk deleted"
else:
    os.environ["FM_EXT_DISCORD_THREAD_MAX"] = "30"
    reason = "reply too long to judge"
with patch.object(autoname, "after_post"), only("followup.2"):
    assert deliver() == ["sent"]
data = load()
messages = data["threads"][thread]["messages"][1:]
latest = messages[-1]["id"]
if scenario == "deleted":
    assert len(messages) == 2, messages
    del data["threads"][thread]["messages"][1]
    save(data)
else:
    assert sum(len(m["content"]) for m in messages) > 47500

calls = len(jev_calls())
use("done")
assert autoname.judge_scan(HOME, retry_failed=True) == []
tick(601)
reads = list(load()["gets"])
assert autoname.judge_scan(HOME, retry_failed=True) == []
assert load()["gets"] == reads and len(jev_calls()) == calls
skips = [v for v in verdicts(thread) if v.get("skip_reason")]
assert len(skips) == 1 and skips[0]["audit_only"], skips
assert (skips[0]["skip_reason"], skips[0]["message_id"]) == (reason, latest), skips
assert name(thread) == previous, name(thread)

assert deliver("done") == ["sent"]
tick(601)
assert len(jev_calls()) == calls + 1 and name(thread) == "✅ Aceh · nightly reindex", verdicts(thread)
print("ok")
PY
    ) || fail "the $scenario reply did not stay skipped until a newer reply: $out"
  done
  pass "deleted and oversized replies each log one skip and hold the current marker"
}

test_1_only_the_reconciler_writes_titles
test_2_marker_precedence_follows_recorded_verdicts
test_3_explicit_states_drive_markers_when_judging_is_off
test_4_pacing_obeys_our_pace_and_discord_limits
test_5_done_during_a_decision_lands_after_closure
test_6_stale_verdicts_are_dropped
test_7_manual_renames_keep_the_captains_words
test_8_catch_up_resumes_after_restart
test_9_judging_never_delays_replies_and_failures_keep_the_title
test_10_title_request_limits_survive_a_slow_response_and_lost_ack
test_11_partial_posts_are_judged_and_private_labels_stay_private
test_12_legacy_intent_and_unclear_checks_keep_the_title
test_13_a_raced_write_is_corrected_without_waiting
test_get_cooldowns_gate_compare_and_history
test_14_the_judge_reads_the_reply_state_and_logs_each_call
test_15_the_judge_criteria_keep_a_closing_note_and_a_question_apart
test_16_a_split_reply_is_judged_as_one_reply
test_17_a_drift_rename_may_move_to_another_known_project_label
test_unjudgeable_replies_hold_the_marker
