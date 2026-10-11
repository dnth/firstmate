#!/usr/bin/env bash
# Behavior tests for one Discord thread per topic: the first reply to a
# top-level request creates a thread on its message, and every later reply for
# that request posts into the same thread.
#
# Hermetic: no Discord network, no real token, no gateway process. The poster's
# thread-create call and message sender are both injected; the intake half runs
# the real bin/fm-ext-intake.sh and bin/fm-ext-topic.sh against fixture homes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH="$PYTHON_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ext-topic-threads)

INTAKE="$ROOT/bin/fm-ext-intake.sh"
EMIT="$ROOT/bin/fm-ext-emit.sh"
LINK="$ROOT/bin/fm-ext-link.sh"
PLUGIN="$ROOT/contrib/hermes-gateway-firstmate-comms"

GUILD=111111111111111111
CHANNEL=222222222222222222
THREAD=333333333333333333
MESSAGE=444444444444444444
AUTHOR=555555555555555555
DENIED=666666666666666666
RID="discord:${GUILD}:${CHANNEL}:${CHANNEL}:${MESSAGE}"

setup_home() {
  local home=$1
  mkdir -p "$home/config"
  : > "$home/config/ext-bridge"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
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

write_text() {
  local file=$1
  shift
  printf '%s' "$*" > "$file"
}

intake_as() {
  local home=$1 text=$2 message=$3 thread=$4 origin=$5 textfile
  textfile="$home/text-$message.txt"
  write_text "$textfile" "$text"
  home_env "$home" "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:${thread}:${message}" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$thread" \
    --message-id "$message" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" \
    --text-file "$textfile" --origin "$origin"
}

slug_of() {
  printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}' \
    || printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

deliver() {
  local home=$1
  shift
  home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$@" <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home = Path(sys.argv[1])
os.environ["FM_HOME"] = str(home)
extra = [json.loads(a) for a in sys.argv[2:]]
threads = {item["request"]: item for item in extra if item.get("kind") == "thread"}
sends = []
def fake_create(payload, name):
    item = threads.get(payload["request_id"], {})
    if item.get("fail"):
        raise RuntimeError("discord refused the thread create")
    tid = item.get("thread_id", "777777777777777777")
    sends.append({"create": [payload["channel_id"], payload["message_id"], name]})
    return {"ok": True, "thread_id": tid}
posted = []
def send(payload):
    posted.append({"thread": payload["thread_id"], "text": payload["text"]})
    return {"ok": True, "discord_message_id": "9%09d" % len(posted)}
results = outbox_poster.drain_outbox(send=send, home=home, create_thread=fake_create)
print("results=" + ",".join(sorted(results)))
for entry in sends:
    print("thread-create=%s" % "/".join(entry["create"]))
for entry in posted:
    print("posted-to=%s %s" % (entry["thread"], entry["text"]))
PY
}

# --- 1. a top-level request gets its replies in one new thread ---------------
#
# The first reply creates a thread on the request's message and posts there;
# every later ack/followup/final for that request reuses the same thread,
# including work linked to it after the inbox is gone.

test_1_top_level_replies_share_one_thread() {
  local home slug out creates
  home="$TMP_ROOT/c1"
  setup_home "$home"
  slug=$(intake_as "$home" "ship the login fix" "$MESSAGE" "$CHANNEL" message)
  [ "$(jq -r '.topic' "$home/state/ext-context/$slug.json")" = "fm ship login fix" ] \
    || fail "the destination context must carry the public-safe topic name"
  write_text "$home/ack.txt" "On it."
  write_text "$home/ans.txt" "All shipshape."
  write_text "$home/fol.txt" "Halfway there."
  write_text "$home/fin.txt" "Landed."
  home_env "$home" "$EMIT" --request-id "$RID" --kind ack --generation 1 \
    --text-file "$home/ack.txt" >/dev/null
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  home_env "$home" "$EMIT" --request-id "$RID" --kind followup --generation 1 \
    --text-file "$home/fol.txt" >/dev/null
  home_env "$home" "$EMIT" --request-id "$RID" --kind final --generation 1 \
    --text-file "$home/fin.txt" >/dev/null
  out=$(deliver "$home" '{"kind":"thread","request":"'"$RID"'","thread_id":"777777777777777777"}')
  assert_contains "$out" "thread-create=$CHANNEL/$MESSAGE/fm ship login fix" \
    "the first reply must create one thread on the request message"
  creates=$(printf '%s\n' "$out" | grep -c '^thread-create=')
  [ "$creates" = 1 ] || fail "one request must create exactly one thread, got $creates"
  [ "$(printf '%s\n' "$out" | grep -c '^posted-to=777777777777777777 ')" = 4 ] \
    || fail "every later reply for the request must post into the same thread: $out"
  # Work linked to the request after the inbox is gone keeps the same thread.
  rm -f "$home/state/ext-inbox/$slug.json"
  fm_write_meta "$home/state/ship-login.meta" "window=firstmate:fm-ship-login" "harness=echo" "kind=ship"
  home_env "$home" "$LINK" ship-login "$RID" >/dev/null
  write_text "$home/fol2.txt" "Linked followup."
  home_env "$home" "$EMIT" --request-id "$RID" --kind followup --generation 2 \
    --text-file "$home/fol2.txt" >/dev/null
  out=$(deliver "$home" '{"kind":"thread","request":"'"$RID"'","thread_id":"777777777777777777"}')
  assert_contains "$out" "posted-to=777777777777777777 Linked followup." \
    "a linked follow-up must reuse the request thread"
  [ "$(printf '%s\n' "$out" | grep -c '^thread-create=')" = 0 ] \
    || fail "a linked follow-up must not create a second thread: $out"
  pass "1 a top-level request gets its replies in one new thread"
}

# --- 2. in-thread requests stay put; /fm keeps its current behaviour --------
#
# A request that arrives inside a thread is answered in that thread with no
# thread create. A /fm slash request keeps working: its replies post to its
# originating thread, which is the channel for a top-level interaction.

test_2_in_thread_stays_and_slash_keeps_working() {
  local home slug out rid2 slug2
  home="$TMP_ROOT/c2"
  setup_home "$home"
  slug=$(intake_as "$home" "and the notes" 555555555555555555 "$THREAD" message)
  [ "$(jq -r 'has("topic")' "$home/state/ext-context/$slug.json")" = false ] \
    || fail "an in-thread request records no topic name"
  write_text "$home/ans.txt" "Noted."
  home_env "$home" "$EMIT" \
    --request-id "discord:${GUILD}:${CHANNEL}:${THREAD}:555555555555555555" \
    --kind answer --generation 1 --text-file "$home/ans.txt" >/dev/null
  out=$(deliver "$home")
  assert_contains "$out" "posted-to=$THREAD Noted." \
    "an in-thread request must be answered in that thread"
  [ "$(printf '%s\n' "$out" | grep -c '^thread-create=')" = 0 ] \
    || fail "an in-thread request must not create a thread: $out"
  rid2="discord:${GUILD}:${CHANNEL}:${CHANNEL}:666666666666666666"
  slug2=$(intake_as "$home" "status please" 666666666666666666 "$CHANNEL" slash)
  [ "$(jq -r 'has("topic")' "$home/state/ext-context/$slug2.json")" = false ] \
    || fail "a slash request records no topic name"
  write_text "$home/slash.txt" "Aye, all shipshape."
  home_env "$home" "$EMIT" --request-id "$rid2" --kind answer --generation 1 \
    --text-file "$home/slash.txt" >/dev/null
  out=$(deliver "$home" '{"kind":"thread","request":"'"$rid2"'","thread_id":"888888888888888888"}')
  assert_contains "$out" "posted-to=$CHANNEL Aye, all shipshape." \
    "a slash request must keep working with its reply in its thread"
  [ "$(printf '%s\n' "$out" | grep -c '^thread-create=')" = 0 ] \
    || fail "a slash request must not attempt thread creation: $out"
  pass "2 an in-thread request stays put and /fm keeps working"
}

# --- 3. thread-create failure posts in place without loss or duplication -----
#
# A refused thread create (missing permission, archived parent) falls back to
# the current post-in-place behaviour: the reply still posts once to the
# originating thread, and a later generation retries the create.

test_3_thread_failure_falls_back_without_loss() {
  local home slug out
  home="$TMP_ROOT/c3"
  setup_home "$home"
  slug=$(intake_as "$home" "ship the docs fix" "$MESSAGE" "$CHANNEL" message)
  write_text "$home/ans.txt" "Docs are up."
  write_text "$home/fin.txt" "Done for real."
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  out=$(deliver "$home" '{"kind":"thread","request":"'"$RID"'","fail":true}')
  assert_contains "$out" "results=sent" "a failed thread create must still deliver the reply"
  assert_contains "$out" "posted-to=$CHANNEL Docs are up." \
    "the fallback must post in place without losing the reply"
  home_env "$home" "$EMIT" --request-id "$RID" --kind final --generation 1 \
    --text-file "$home/fin.txt" >/dev/null
  out=$(deliver "$home" '{"kind":"thread","request":"'"$RID"'","thread_id":"777777777777777777"}')
  assert_contains "$out" "thread-create=$CHANNEL/$MESSAGE/fm ship docs fix" \
    "a later generation must retry the thread create"
  assert_contains "$out" "posted-to=777777777777777777 Done for real." \
    "the retried reply must post into the new thread"
  [ -f "$home/state/ext-outbox/$slug.answer.1.receipt.json" ] \
    || fail "the fallback reply must still record its receipt"
  pass "3 a thread-create failure falls back without losing the reply"
}

# --- 4. topic names stay bounded and public-safe; threads admit nobody ------
#
# Thread names keep the bounded sanitized form, and a thread message from an
# author the allowlist refuses is still ignored: the thread never widens who
# may instruct Firstmate.

test_4_topic_names_bounded_and_threads_admit_nobody() {
  local home slug topic out
  home="$TMP_ROOT/c4"
  setup_home "$home"
  slug=$(intake_as "$home" "Fix login BUG #42: see /home/u/secret TOKEN=abc host-1.2.3.4!!!   " "$MESSAGE" "$CHANNEL" message)
  topic=$(jq -r '.topic' "$home/state/ext-context/$slug.json")
  [ "$topic" = "fm fix login bug" ] \
    || fail "only vocabulary words may survive, got $topic"
  for leak in home secret TOKEN abc 42 /home/u 1.2.3.4; do
    case "$topic" in
      *"$leak"*) fail "the topic must not carry request values, got $topic" ;;
    esac
  done
  slug=$(intake_as "$home" "Please approve the release plan soon" 555555555555555556 "$CHANNEL" message)
  topic=$(jq -r '.topic' "$home/state/ext-context/$slug.json")
  [ "$topic" = "fm please approve release plan" ] \
    || fail "safe words in order, got $topic"
  slug=$(intake_as "$home" "$(printf 'w%.0s' $(seq 1 200))" 555555555555555557 "$CHANNEL" message)
  [ "$(jq -r '.topic' "$home/state/ext-context/$slug.json")" = "fm request" ] \
    || fail "a request with no safe word must fall back"
  slug=$(intake_as "$home" "!!! ???" 555555555555555558 "$CHANNEL" message)
  [ "$(jq -r '.topic' "$home/state/ext-context/$slug.json")" = "fm request" ] \
    || fail "punctuation alone must fall back"
  out=$(GUILD="$GUILD" CHANNEL="$CHANNEL" THREAD="$THREAD" AUTHOR="$DENIED" \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$ROOT" <<'PY'
import os, sys
from types import SimpleNamespace
sys.path.insert(0, os.environ["PYTHONPATH"])
import intake
os.environ["FM_HOME"] = sys.argv[1]
os.environ["FM_ROOT_OVERRIDE"] = sys.argv[2]
G, C, T = os.environ["GUILD"], os.environ["CHANNEL"], os.environ["THREAD"]
source = SimpleNamespace(platform=SimpleNamespace(value="discord"),
    chat_id=T, chat_type="thread", user_id=os.environ["AUTHOR"], user_name="stranger",
    thread_id=T, parent_chat_id=C, scope_id=G, guild_id=G, message_id="560000000000000001")
raw = SimpleNamespace(id=560000000000000001, guild_id=int(G), channel_id=int(T),
    type=SimpleNamespace(value=0),
    author=SimpleNamespace(id=int(os.environ["AUTHOR"]), bot=False, system=False),
    webhook_id=None, edited_at=None, reference=None)
event = SimpleNamespace(text="do the thing", source=source, raw_message=raw,
    message_id="560000000000000001", reply_to_message_id=None, reply_to_text=None)
Path = __import__("pathlib").Path
Path(sys.argv[1], "config", "ext-channel").write_text(C + "\n")
result = intake.pre_gateway_dispatch_hook(event) or {}
print("action=%s" % result.get("action"))
print("inbox=%d" % len(list(Path(sys.argv[1], "state", "ext-inbox").glob("*.json"))))
print("refused=%s" % ("560000000000000001" in "".join(str(q) for q in Path(sys.argv[1], "state", "ext-inbox").glob("*.json"))))
PY
  )
  assert_contains "$out" "action=skip" "a refused thread message must stay withheld from the general agent"
  assert_contains "$out" "inbox=4" "earlier requests stay; only the refused message must add nothing"
  assert_contains "$out" "refused=False" "a refused thread message must record no request: the thread never widens the allowlist"
  pass "4 topic names stay bounded and public-safe; threads admit nobody"
}

test_5_thread_record_expires_with_retention() {
  local home slug
  home="$TMP_ROOT/c5"
  setup_home "$home"
  slug=$(intake_as "$home" "ship the login fix" "$MESSAGE" "$CHANNEL" message)
  write_text "$home/ans.txt" "On it."
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  out=$(deliver "$home" '{"kind":"thread","request":"'"$RID"'","thread_id":"777777777777777777"}')
  assert_contains "$out" "thread-create=$CHANNEL/$MESSAGE/fm ship login fix" \
    "the reply must create the thread first"
  [ -f "$home/state/ext-outbox/$slug.thread.json" ] \
    || fail "the thread id must be recorded request-wide"
  # The record survives while other files for its slug remain (delivered
  # generations retire their payload but leave posting/progress/receipt
  # markers), then expires on the same retention window once they are gone.
  # Marker mtimes are real time, so backdate them instead of moving the clock.
  touch -d "8 days ago" "$home/state/ext-outbox/$slug.answer.1.posting" \
    "$home/state/ext-outbox/$slug.answer.1.progress.json" "$home/state/ext-outbox/$slug.answer.1.receipt.json"
  PATH="$BASE_PATH" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c 'source "$0/bin/fm-ext-lib.sh" && fm_ext_outbox_prune "$1/state"' "$ROOT" "$home"
  [ -f "$home/state/ext-outbox/$slug.thread.json" ] \
    || fail "the thread record must survive while its generation markers remain"
  rm -f "$home/state/ext-outbox/$slug.answer.1.posting" \
    "$home/state/ext-outbox/$slug.answer.1.progress.json" "$home/state/ext-outbox/$slug.answer.1.receipt.json"
  touch -d "8 days ago" "$home/state/ext-outbox/$slug.thread.json"
  PATH="$BASE_PATH" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-ext-poll.sh" >/dev/null 2>&1 || true
  PATH="$BASE_PATH" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c 'source "$0/bin/fm-ext-lib.sh" && fm_ext_outbox_prune "$1/state"' "$ROOT" "$home"
  [ ! -f "$home/state/ext-outbox/$slug.thread.json" ] \
    || fail "the thread record must expire on the retention window once its work is done"
  pass "5 the thread record expires with retention"
}

test_6_sensitive_tokens_never_name_threads() {
  local home slug text out message=700000000000000000
  for text in ship-login-fix password=please-approve-release-plan 'fix1 login/fix login\fix login_fix login.fix login:fix login@fix'; do
    message=$((message + 1))
    home="$TMP_ROOT/c6-$message"
    setup_home "$home"
    slug=$(intake_as "$home" "$text" "$message" "$CHANNEL" message)
    [ "$(jq -r '.topic' "$home/state/ext-context/$slug.json")" = "fm request" ] \
      || fail "sensitive tokens must yield the neutral topic"
    write_text "$home/ans.txt" "Noted."
    home_env "$home" "$EMIT" --request-id "discord:${GUILD}:${CHANNEL}:${CHANNEL}:${message}" \
      --kind answer --generation 1 --text-file "$home/ans.txt" >/dev/null
    out=$(deliver "$home")
    assert_contains "$out" "thread-create=$CHANNEL/$message/fm request" \
      "sensitive request tokens must not reach the creator"
    home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$slug" "$text" <<'PY'
import io, json, os, sys
from pathlib import Path
from unittest.mock import patch
import outbox_poster as poster
home, slug, text = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
context_path = home / "state/ext-context" / (slug + ".json")
payload = json.loads(context_path.read_text())
payload["topic"] = "fm " + text
context_path.write_text(json.dumps(payload))
assert poster.thread_name_for(payload, home) == "fm request"
os.environ["DISCORD_BOT_TOKEN"] = "fixture"
def respond(request, **kwargs):
    assert json.loads(request.data)["name"] == "fm request"
    return io.BytesIO(b'{"id":"777777777777777777"}')
with patch.object(poster.urllib.request, "urlopen", respond):
    assert poster.discord_create_thread(payload, text)["thread_id"] == "777777777777777777"
PY
    [ "$?" = 0 ] || fail "poster and API must enforce whole-word safety"
  done
  pass "6 sensitive tokens never name threads"
}

test_7_resumed_chunks_keep_their_destination() {
  local home slug
  home="$TMP_ROOT/c7"
  setup_home "$home"
  slug=$(intake_as "$home" "fix the docs" "$MESSAGE" "$CHANNEL" message)
  write_text "$home/ans.txt" "$(printf 'word %.0s' {1..600})"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$slug" <<'PY'
import errno, json, os, sys, tempfile
from pathlib import Path
from unittest.mock import patch
import outbox_poster as poster
home, slug = Path(sys.argv[1]), sys.argv[2]
path = home / "state/ext-outbox" / (slug + ".answer.1.json")
payload = json.loads(path.read_text())
posted = []
def fail_create(payload, name):
    raise RuntimeError("no permission")
def partial_send(payload):
    if posted:
        raise poster.DiscordSendError("transient", "retry")
    posted.append(payload["thread_id"])
    return {"discord_message_id": "900000000000000001"}
assert poster.deliver_one(path, send=partial_send, home=home, create_thread=fail_create) == "failed"
assert posted == [payload["channel_id"]]
progress = poster.load_progress(payload, home)
assert progress["posted_count"] == 1
creates = []
def create(payload, name):
    creates.append(name)
    return {"thread_id": "777777777777777777"}
def send(payload):
    posted.append(payload["thread_id"])
    return {"discord_message_id": str(900000000000000001 + len(posted))}
assert poster.deliver_one(path, send=send, home=home, create_thread=create) == "sent"
assert not creates
assert len(posted) > 1 and set(posted) == {payload["channel_id"]}
real_mkstemp = tempfile.mkstemp
allocations = []
def mkstemp(*args, **kwargs):
    if kwargs.get("prefix") == "fm-ext-thread.":
        assert Path(kwargs["dir"]) == home / "state/ext-outbox"
        allocations.append(kwargs["dir"])
    return real_mkstemp(*args, **kwargs)
with patch.object(tempfile, "mkstemp", mkstemp), patch.object(os, "link", side_effect=OSError(errno.EXDEV, "different filesystem")):
    assert poster.ensure_topic_thread(payload, {"posted_count": 0}, home, create) == "777777777777777777"
assert allocations
assert poster.load_request_thread(payload, home) == "777777777777777777"
assert poster.ensure_topic_thread(payload, {"posted_count": 0}, home, create) == "777777777777777777"
assert len(creates) == 1
assert poster.ensure_topic_thread(payload, progress, home, create) == ""
assert poster.ensure_topic_thread(payload, {"posted_count": 1, "topic_thread_id": "777777777777777777"}, home, create) == "777777777777777777"
record = poster.request_progress_path(payload, home)
assert record.stat().st_mode & 0o777 == 0o600
assert record.stat().st_nlink == 1
assert not list(record.parent.glob("fm-ext-thread.*"))
payload["origin"] = "slash"
assert poster.ensure_topic_thread(payload, {"posted_count": 0}, home, create) == ""
PY
  [ "$?" = 0 ] || fail "partial replies stay put and thread records publish locally"
  pass "7 resumed chunks stay put and thread records publish locally"
}

test_8_pending_skips_thread_records() {
  local home
  home="$TMP_ROOT/c8"
  setup_home "$home"
  mkdir -p "$home/state/ext-outbox" "$home/fakebin"
  printf '{}\n' > "$home/state/ext-outbox/topic.thread.json"
  printf '#!/usr/bin/env bash\nprintf "called\\n" >> "%s"\nexit 1\n' "$home/jq-calls" > "$home/fakebin/jq"
  chmod +x "$home/fakebin/jq"
  PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash "$ROOT/bin/fm-ext-outbox.sh" pending > "$home/pending"
  [ "$?" = 0 ] && [ ! -s "$home/pending" ] && [ ! -e "$home/jq-calls" ] \
    || fail "thread markers must bypass payload validation entirely"
  pass "8 pending skips thread records without invoking jq"
}

test_1_top_level_replies_share_one_thread
test_2_in_thread_stays_and_slash_keeps_working
test_3_thread_failure_falls_back_without_loss
test_4_topic_names_bounded_and_threads_admit_nobody
test_5_thread_record_expires_with_retention

test_6_sensitive_tokens_never_name_threads
test_7_resumed_chunks_keep_their_destination
test_8_pending_skips_thread_records

echo "all fm-ext-topic-threads tests passed"
