#!/usr/bin/env bash
# Behavior tests for Discord decision buttons on the local Communication
# Officer bridge: bin/fm-ext-emit.sh --decision-file, bin/fm-ext-decision.sh,
# the button origin of bin/fm-ext-intake.sh, and the gateway plugin's decisions
# module and outbox poster.
#
# Hermetic by default: no Discord network, no token, no gateway process. Clicks
# go through the plugin's own click handler, which runs the real decision
# script and files requests through the real intake; the tests then play
# Firstmate's part and record those requests through the real keyed decision
# path (bin/fm-send.sh against a stub tmux, and bin/fm-captain-hold.sh against a
# real tasks-axi backlog when tasks-axi is installed); posts and edits go to
# local stand-ins for Discord's REST edge. Case 10 routes synthetic Discord
# clicks through the installed Hermes gateway's Discord adapter and its real
# discord.py client when that Python is available (FM_TEST_HERMES_PYTHON, or
# the default Hermes install), and skips with a printed reason otherwise.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH="$PYTHON_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ext-decision)

INTAKE="$ROOT/bin/fm-ext-intake.sh"
EMIT="$ROOT/bin/fm-ext-emit.sh"
POLL="$ROOT/bin/fm-ext-poll.sh"
PLUGIN="$ROOT/contrib/hermes-gateway-firstmate-comms"
FIXTURES="$TMP_ROOT/fixtures"

GUILD=111111111111111111
CHANNEL=222222222222222222
THREAD=333333333333333333
CAPTAIN=555555555555555555
MEMBER=666666666666666666
STRANGER=777777777777777777
REQUEST_MESSAGE=444444444444444444
POST=700000000000000001
TASK=route-fix

# The captain holds the author-scoped rule; the channel rule admits every other
# member of the channel at confirm authority only. Every home also carries a
# stub tmux so bin/fm-send.sh can ring a worker's doorbell.
setup_home() {
  local home=$1 fakebin
  mkdir -p "$home/config" "$home/state"
  : > "$home/config/ext-bridge"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$CAPTAIN" "$GUILD:$CHANNEL" > "$home/config/ext-allowlist"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) echo 1; exit 0 ;;
        *pane_pid*) echo 4242; exit 0 ;;
      esac
    done
    echo fakepane
    exit 0
    ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

home_env() {
  local home=$1
  shift
  PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0 "$@"
}

# Run a Python snippet from stdin against the plugin with this home.
plugin_py() {
  local home=$1
  shift
  home_env "$home" env PYTHONPATH="$PLUGIN:$FIXTURES" GUILD="$GUILD" CHANNEL="$CHANNEL" \
    "$PYTHON_BIN" - "$home" "$ROOT" "$@"
}

# A typed request from the captain, which every decision post answers. With a
# thread argument the request came from a thread under the channel.
open_request() {
  local home=$1 thread=${2:-$CHANNEL}
  printf 'what needs me?' > "$home/request.txt"
  home_env "$home" "$INTAKE" --request-id "discord:$GUILD:$CHANNEL:$thread:$REQUEST_MESSAGE" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$thread" \
    --message-id "$REQUEST_MESSAGE" --author "$CAPTAIN" \
    --secret-file "$home/config/ext-secret" --text-file "$home/request.txt" \
    --no-wake >/dev/null || fail "the typed request fixture was refused"
}

# A live worker with an open keyed decision.
open_key() {
  local home=$1 key=$2
  [ -f "$home/state/$TASK.meta" ] \
    || fm_write_meta "$home/state/$TASK.meta" "window=sess:fm-$TASK" "kind=ship"
  printf 'needs-decision [key=%s]: pick a route\n' "$key" >> "$home/state/$TASK.status"
}

# Emit one decision post into the request's thread; prints the payload path.
emit_decision() {
  local home=$1 generation=$2 decision=$3 thread=${4:-$CHANNEL} slug
  printf '%s' "$decision" > "$home/decision.json"
  printf 'Which way should the fix go?\n1. North ⭐\n2. South\nReply to this message with the number.' \
    > "$home/post.txt"
  slug=$(home_env "$home" "$EMIT" --request-id "discord:$GUILD:$CHANNEL:$thread:$REQUEST_MESSAGE" \
    --kind followup --generation "$generation" \
    --text-file "$home/post.txt" --decision-file "$home/decision.json") \
    || fail "emit refused a valid decision post: $decision"
  printf '%s\n' "$home/state/ext-outbox/$slug.followup.$generation.json"
}

# Deliver pending posts as Discord message <id> with buttons routed.
deliver() {
  local home=$1 id=$2
  plugin_py "$home" "$id" >/dev/null <<'PY' || fail "the poster could not deliver the decision post"
import sys
from pathlib import Path
import decisions, outbox_poster
decisions.buttons_ready = lambda: True
def send(p):
    return {"ok": True, "discord_message_id": str(int(sys.argv[3]) + int(p.get("chunk_index", 0))),
            "buttons": bool(p.get("decision"))}
outbox_poster.drain_outbox(send=send, home=Path(sys.argv[1]))
PY
}

# One click through the plugin's handler; prints its verdict JSON.
# Usage: click <home> <custom_id> <author> <interaction> [message-id] [name]
click() {
  local home=$1
  shift
  plugin_py "$home" "$@" <<'PY'
import json, sys, fmdecide
fmdecide.setup()
args = sys.argv[3:] + [None] * 6
custom, author, interaction, message, name = args[0], args[1], args[2], args[3], args[4]
print(json.dumps(fmdecide.click(custom, author, interaction, message, name), ensure_ascii=False))
PY
}

# Show settled posts on a stand-in Discord edge; prints each PATCH.
reconcile() {
  local home=$1 full=${2:-True}
  plugin_py "$home" "$full" <<'PY'
import json, sys
from pathlib import Path
import outbox_poster
def edit(channel, message, content, components):
    print(json.dumps({"channel": channel, "message": message, "content": content,
                      "components": components}))
outbox_poster.reconcile_decision_posts(home=Path(sys.argv[1]), full=sys.argv[3] == "True", edit=edit)
PY
}

button_requests() {
  local home=$1 file n=0
  for file in "$home"/state/ext-inbox/*.json; do
    [ -e "$file" ] || continue
    [ "$(jq -r '.origin' "$file")" = button ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

button_request() {  # <home> <choice>
  local home=$1 file
  for file in "$home"/state/ext-inbox/*.json; do
    [ -e "$file" ] || continue
    if [ "$(jq -r '.decision.choice // empty' "$file")" = "$2" ]; then
      cat "$file"
      return 0
    fi
  done
  return 1
}

resolved_lines() {  # <home> <key-slug>
  grep -c "^resolved \[key=$2\]" "$1/state/$TASK.status" || true
}

# What Firstmate does with a button request, per the ext-respond skill: check
# that the request's decision is still the open lifecycle it was clicked for,
# then record the option through the decision's own normal path, quoting the
# click's audit. Prints the still-open verdict; records only on "open".
record_as_firstmate() {  # <home> <inbox-record-json>
  local home=$1 record=$2 key option id by author at audit task mode verdict
  key=$(jq -r '.decision.key' <<<"$record")
  verdict=$(home_env "$home" "$ROOT/bin/fm-ext-decision.sh" still-open --key "$key" \
    --occurrence "$(jq -r '.decision.occurrence' <<<"$record")")
  printf '%s\n' "$verdict"
  [ "$verdict" = open ] || return 0
  option=$(jq -r '.decision.option' <<<"$record")
  id=$(jq -r '.decision.option_id' <<<"$record")
  by=$(jq -r '.decision.by' <<<"$record")
  author=$(jq -r '.decision.author' <<<"$record")
  at=$(jq -r '.decision.at' <<<"$record")
  audit="Discord button: option $id \"$option\" chosen by $by ($author) at $at for $key"
  if [ "$(jq -r '.decision.confirmed' <<<"$record")" = true ]; then
    audit="$audit, confirmed by clicking \"$(jq -r '.decision.confirm_prompt' <<<"$record")\""
  fi
  case "$key" in
    hold:*)
      task=${key#hold:}
      mode=$(jq -r '.decision.mode // "done"' <<<"$record")
      printf '%s\t%s\t%s\t%s\n' "$task" "$option" "$id. $option" "$mode" \
        | home_env "$home" "$ROOT/bin/fm-captain-hold.sh" answers --source "$audit" >/dev/null \
        || fail "fm-captain-hold.sh answers refused the button answer"
      ;;
    key:*)
      task=${key#key:}
      home_env "$home" "$ROOT/bin/fm-send.sh" "${task%%:*}" --resolve-key "${key##*:}" \
        "Decision answer: $option ($audit)" >/dev/null 2>&1 || fail "fm-send refused the button answer"
      ;;
  esac
}

mkdir -p "$FIXTURES"
cat > "$FIXTURES/fmdecide.py" <<'PY'
"""Click helpers and a local POST edge for the decision-button tests."""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

G, C = os.environ["GUILD"], os.environ["CHANNEL"]
POST = "700000000000000001"


def setup():
    os.environ["FM_HOME"] = sys.argv[1]
    os.environ["FM_ROOT_OVERRIDE"] = sys.argv[2]


def click(custom_id, author, interaction, message=None, name=None, chat=None):
    """One click through the plugin's handler; returns its verdict."""
    import decisions
    dest = {"guild_id": G, "chat_id": chat or os.environ.get("CHAT", C),
            "interaction_id": str(interaction), "message_id": str(message or POST),
            "author": str(author), "author_name": name or "Dana"}
    return decisions.handle_click(dest, custom_id)


class PostEdge:
    """Local stand-in for Discord's REST edge; records each message POST."""

    def __init__(self):
        self.posts = []
        edge = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                edge.posts.append({"path": self.path, "body": json.loads(self.rfile.read(length) or b"{}")})
                body = json.dumps({"id": str(900000000000000000 + len(edge.posts)),
                                   "channel_id": C}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = "http://127.0.0.1:%d/api/v10" % self.server.server_address[1]
PY

KEY="key:$TASK:pick"

# --- 1. buttons carry the key and option ids, in the request's thread -----

test_1_buttons_carry_key_and_option_ids_in_the_thread() {
  local home payload out
  home="$TMP_ROOT/c1"
  setup_home "$home"
  open_request "$home" "$THREAD"
  open_key "$home" pick
  payload=$(emit_decision "$home" 1 \
    '{"key":"'"$KEY"'","options":[{"label":"North"},{"label":"Merge it"}]}' "$THREAD")
  jq -e --arg key "$KEY" '.decision.key == $key and .decision.mode == "done"
    and .decision.options == [{"id":1,"label":"North","confirm":false},{"id":2,"label":"Merge it","confirm":true}]' \
    "$payload" >/dev/null || fail "the decision payload lost its key or numbered options: $(cat "$payload")"

  # A long post: buttons ride on its last chunk only.
  printf 'needs-decision [key=again]: second\n' >> "$home/state/$TASK.status"
  printf '{"key":"key:%s:again","options":[{"label":"Yes"},{"label":"No"}]}' "$TASK" > "$home/decision.json"
  printf 'line %s of a long decision post. ' 1 2 3 4 5 6 > "$home/post.txt"
  home_env "$home" "$EMIT" --request-id "discord:$GUILD:$CHANNEL:$THREAD:$REQUEST_MESSAGE" \
    --kind followup --generation 2 --text-file "$home/post.txt" --decision-file "$home/decision.json" \
    >/dev/null || fail "emit refused the long decision post"
  out=$(FM_EXT_DISCORD_REPLY_MAX_CHARS=120 plugin_py "$home" <<'PY'
import json, os, sys
from pathlib import Path
import fmdecide, decisions, outbox_poster
fmdecide.setup()
os.environ["DISCORD_BOT_TOKEN"] = "test-bot-token"
edge = fmdecide.PostEdge()
outbox_poster.DISCORD_API_BASE = edge.base
decisions.buttons_ready = lambda: True
outbox_poster.drain_outbox(home=Path(sys.argv[1]))
print(json.dumps(edge.posts))
PY
  ) || fail "the poster could not drain the decision posts"
  printf '%s' "$out" | jq -e --arg key "$KEY" --arg path "/api/v10/channels/$THREAD/messages" '
    all(.[]; .path == $path)
    and (map(select(.body.content | startswith("Which way"))) | length == 1)
    and (map(select(.body.content | startswith("Which way")))[0].body.components == [
          {"type":1,"components":[
            {"type":2,"style":2,"label":"North","custom_id":("fmd:" + $key + ":1"),"disabled":false},
            {"type":2,"style":4,"label":"Merge it","custom_id":("fmd:" + $key + ":2"),"disabled":false}]},
          {"type":1,"components":[
            {"type":2,"style":1,"label":"Discuss","custom_id":("fmd:" + $key + ":d"),"disabled":false}]}])
    and (all(.[1:-1][]; .body | has("components") | not))
    and (.[-1].body.components | length == 2)
    and all(.[]; .body.content | contains("route-fix") | not)
  ' >/dev/null || fail "buttons must carry the key and option ids, on the last chunk, in the request's thread: $out"

  # Without a routed click handler the same decision posts as plain text.
  home="$TMP_ROOT/c1-plain"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[{"label":"North"}]}' >/dev/null
  out=$(plugin_py "$home" <<'PY'
import json, os, sys
from pathlib import Path
import fmdecide, outbox_poster
fmdecide.setup()
os.environ["DISCORD_BOT_TOKEN"] = "test-bot-token"
edge = fmdecide.PostEdge()
outbox_poster.DISCORD_API_BASE = edge.base
outbox_poster.drain_outbox(home=Path(sys.argv[1]))
print(json.dumps(edge.posts))
PY
  )
  printf '%s' "$out" | jq -e --arg path "/api/v10/channels/$CHANNEL/messages" \
    'length == 1 and .[0].path == $path and (.[0].body | has("components") | not)' >/dev/null \
    || fail "a decision posted buttons that nothing in the gateway would answer: $out"
  pass "1 buttons carry the decision key and option ids, ride the last chunk, and post into the request's thread or channel"
}

# --- 2. a standing click files one request; Firstmate records it -----------

test_2_standing_click_files_one_request_for_a_worker_key() {
  local home out record
  home="$TMP_ROOT/c2"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" "$POST"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmd:$KEY:1" "$CAPTAIN" 880000000000000001)
  assert_contains "$out" '"text": "Sent: North. Firstmate will record it, and the post updates when it does."' \
    "the captain's click was not sent"
  [ "$(resolved_lines "$home" pick)" = 0 ] || fail "the plugin recorded the answer itself"
  [ ! -d "$home/state/$TASK.inbox" ] || fail "the plugin delivered the answer to the worker itself"
  [ "$(button_requests "$home")" = 1 ] || fail "one click must file exactly one request"
  record=$(button_request "$home" option)
  printf '%s' "$record" | jq -e --arg key "$KEY" --arg captain "$CAPTAIN" '
    .authority == "standing" and .origin == "button" and .author == $captain
    and .text == "Decision answer by button: North"
    and .decision.key == $key and .decision.occurrence == "1"
    and .decision.option_id == 1 and .decision.option == "North" and .decision.confirmed == false
    and .decision.by == "Dana" and .decision.author == $captain and .decision.at == "2026-10-11T12:00:00Z"
    and (.decision.text | startswith("Which way"))' >/dev/null \
    || fail "the request lost the key, option, decision text, audit, or authority: $record"
  assert_grep "ext-request $(jq -r .slug <<<"$record")" "$home/state/.wake-queue" \
    "the click request must wake Firstmate like any other request"

  # The post's buttons go off at once with the sent line.
  out=$(reconcile "$home" False)
  printf '%s' "$out" | jq -e --arg key "$KEY" --arg msg "$POST" \
    --arg expected $'**⏳ North sent by Dana <t:1791720000:f> - waiting for Firstmate to record it**\n\nWhich way should the fix go?\n1. North ⭐\n2. South\nReply to this message with the number.' '
    .message == $msg and .content == $expected
    and ([.components[].components[] | .disabled] | all)
    and .components[0].components[0].style == 3
    and .components[0].components[0].label == "North ✓"
    and .components[0].components[1].style == 2
    and .components[1].components[0].style == 2
    and (.components[0].components[0].custom_id == ("fmd:" + $key + ":1"))' >/dev/null \
    || fail "a sent click must keep its question visible and highlight only its disabled choice: $out"
  [ -z "$(reconcile "$home" True)" ] || fail "an unchanged sent post was edited again"

  # Firstmate records the request through its normal path; the post follows.
  [ "$(record_as_firstmate "$home" "$record")" = open ] || fail "Firstmate found the clicked decision no longer open"
  [ "$(resolved_lines "$home" pick)" = 1 ] || fail "Firstmate's normal path did not record the answer"
  out=$(FM_EXT_NOW_OVERRIDE=1791720100 reconcile "$home" True)
  printf '%s' "$out" | jq -e --arg msg "$POST" \
    --arg expected $'**✅ North chosen by Dana <t:1791720000:f>**\n\nWhich way should the fix go?\n1. North ⭐\n2. South\nReply to this message with the number.' '
    .message == $msg and .content == $expected
    and ([.components[].components[] | .disabled] | all)
    and .components[0].components[0].style == 3
    and .components[0].components[0].label == "North ✓"
    and .components[0].components[1].style == 2
    and .components[1].components[0].style == 2' >/dev/null \
    || fail "the post must preserve its question and mark only the recorded choice: $out"
  [ -z "$(reconcile "$home" True)" ] || fail "a post Discord already shows was edited again"
  pass "2 a standing click files one request with key, option, text, and audit, turns the buttons off, and shows the choice once Firstmate records it"
}

# --- 3. a captain call: the click is a request; the board owns the answer ---

test_3_captain_call_click_is_a_request_the_board_records() {
  local home id out show fakebin record pair options label generation
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: 3 needs tasks-axi for the captain-call board"; return 0; }
  # tasks-axi and its runtime live outside the minimal test PATH.
  local BASE_PATH
  BASE_PATH="$(dirname "$(command -v tasks-axi)"):${FM_TEST_BASE_PATH:-$PYTHON_DIR:/usr/bin:/bin:/usr/sbin:/sbin}"
  [ -z "$JQ_DIR" ] || BASE_PATH="$JQ_DIR:$BASE_PATH"
  home="$TMP_ROOT/c3"
  setup_home "$home"
  id=pick-route-call
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  mkdir -p "$home/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin="$home/fakebin"
  fm_fake_exit0 "$fakebin" treehouse no-mistakes gh gh-axi
  ln -sf "$(command -v tasks-axi)" "$fakebin/tasks-axi"
  (cd "$home" && tasks-axi add "$id" "Pick the route" --kind captain --repo sample >/dev/null) \
    || fail "could not create the captain-call fixture"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason "route pending" --repo sample \
    >/dev/null || fail "could not hold the captain call"
  open_request "$home"
  emit_decision "$home" 1 '{"key":"hold:'"$id"'","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" "$POST"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmd:hold:$id:2" "$CAPTAIN" 880000000000000002)
  assert_contains "$out" "Sent: South." "the click on the captain call was not sent"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" open "$id" >/dev/null \
    || fail "the plugin closed the captain call itself"
  record=$(button_request "$home" option)
  printf '%s' "$record" | jq -e --arg key "hold:$id" '.decision.key == $key and .decision.mode == "done"
    and (.decision.occurrence | endswith("#0"))' >/dev/null \
    || fail "the request lost the call's key, close mode, or lifecycle: $record"
  [ "$(record_as_firstmate "$home" "$record")" = open ] || fail "Firstmate found the clicked decision no longer open"
  show=$(cd "$home" && tasks-axi show "$id" --full)
  assert_contains "$show" "state: done" "Firstmate's normal path did not close the call"
  assert_contains "$show" "Answer: South" "the recorded call lost the chosen option"
  assert_contains "$show" "chosen by Dana ($CAPTAIN) at 2026-10-11T12:00:00Z for hold:$id" \
    "the recorded call lost who, when, and key"
  out=$(click "$home" "fmd:hold:$id:1" "$CAPTAIN" 880000000000000003)
  assert_contains "$out" "Already sent" "a second click on a sent captain call must file nothing"
  [ "$(button_requests "$home")" = 1 ] || fail "a second click filed another request"

  # A captain call answered on the board, not by button: the post reads the
  # recorded answer and names the option it chose.
  (cd "$home" && tasks-axi add "$id-2" "Pick the route again" --kind captain --repo sample >/dev/null) \
    || fail "could not create the second captain-call fixture"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id-2" --reason "route pending" --repo sample \
    >/dev/null || fail "could not hold the second captain call"
  emit_decision "$home" 2 '{"key":"hold:'"$id"'-2","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000006
  printf 'South, please.\n' > "$home/answer.txt"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" answer "$id-2" --decision-file "$home/answer.txt" \
    >/dev/null || fail "could not answer the second captain call on the board"

  # A call closed with no captain answer is superseded, not decided.
  (cd "$home" && tasks-axi add "$id-3" "Pick a third route" --kind captain --repo sample >/dev/null) \
    || fail "could not create the third captain-call fixture"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id-3" --reason "route pending" --repo sample \
    >/dev/null || fail "could not hold the third captain call"
  emit_decision "$home" 3 '{"key":"hold:'"$id"'-3","options":[{"label":"North"}]}' >/dev/null
  deliver "$home" 700000000000000007
  (cd "$home" && tasks-axi 'done' "$id-3" >/dev/null 2>&1) || fail "could not close the third call without an answer"

  # A released call re-held for a new question: the old post must not answer it.
  (cd "$home" && tasks-axi add "$id-4" "Pick a fourth route" --kind captain --repo sample >/dev/null) \
    || fail "could not create the fourth captain-call fixture"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id-4" --reason "route pending" --repo sample \
    >/dev/null || fail "could not hold the fourth captain call"
  emit_decision "$home" 4 '{"key":"hold:'"$id"'-4","options":[{"label":"North"}]}' >/dev/null
  deliver "$home" 700000000000000008
  printf 'Hold on, North for now.\n' > "$home/answer.txt"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" answer "$id-4" --decision-file "$home/answer.txt" --release \
    >/dev/null || fail "could not release the fourth captain call"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id-4" --reason "a new question" --repo sample \
    >/dev/null || fail "could not re-hold the fourth captain call"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmd:hold:$id-4:1" "$CAPTAIN" 880000000000000004 700000000000000008)
  assert_contains "$out" "Already decided: Closed - no longer needed <t:1791720000:f> - this click changed nothing." \
    "a post must not answer a later lifecycle of its captain call"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" open "$id-4" >/dev/null \
    || fail "a stale click closed the re-held captain call"
  [ "$(button_requests "$home")" = 1 ] || fail "a stale click filed a request"

  # A captain-call click still queued when the call is released and re-held
  # for a new question must not answer the new question either.
  (cd "$home" && tasks-axi add "$id-5" "Pick a fifth route" --kind captain --repo sample >/dev/null) \
    || fail "could not create the fifth captain-call fixture"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id-5" --reason "route pending" --repo sample \
    >/dev/null || fail "could not hold the fifth captain call"
  emit_decision "$home" 5 '{"key":"hold:'"$id"'-5","options":[{"label":"North"}]}' >/dev/null
  deliver "$home" 700000000000000009
  click "$home" "fmd:hold:$id-5:1" "$CAPTAIN" 880000000000000005 700000000000000009 >/dev/null
  record=$(jq -s 'map(select(.decision.key == "hold:'"$id"'-5")) | .[0]' "$home"/state/ext-inbox/*.json)
  printf 'Wait - release it for now.\n' > "$home/answer.txt"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" answer "$id-5" --decision-file "$home/answer.txt" --release \
    >/dev/null || fail "could not release the fifth captain call"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id-5" --reason "a new question" --repo sample \
    >/dev/null || fail "could not re-hold the fifth captain call"
  [ "$(record_as_firstmate "$home" "$record")" = superseded ] \
    || fail "a request queued before a release and re-hold must not be still open"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" open "$id-5" >/dev/null \
    || fail "the queued request closed the re-held captain call"

  (cd "$home" && tasks-axi add "$id-6" "Pick a sixth route" --kind captain --repo sample >/dev/null) || fail "could not create the sixth call"
  FM_CAPTAIN_HOLD_NOW=2026-10-11T10:00:00Z home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id-6" --reason "route pending" --repo sample >/dev/null || fail "could not hold the sixth call"
  emit_decision "$home" 6 '{"key":"hold:'"$id"'-6","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000010
  printf 'South\n' > "$home/answer.txt"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" answer "$id-6" --decision-file "$home/answer.txt" --release >/dev/null || fail "could not release the sixth call"
  FM_CAPTAIN_HOLD_NOW=2026-10-11T11:00:00Z home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id-6" --reason "new question" --repo sample >/dev/null || fail "could not re-hold the sixth call"
  (cd "$home" && tasks-axi 'done' "$id-6" >/dev/null) || fail "could not close the sixth call without answering"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
  printf '%s\n' "$out" | jq -se '
    (map({(.message): .content}) | add) as $shown
    | ($shown["700000000000000001"] | startswith("**✅ South chosen by Dana <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000006"] | startswith("**✅ South chosen by the captain <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000007"] | startswith("**Closed - no longer needed <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000008"] | startswith("**Closed - no longer needed <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000010"] | startswith("**Closed - no longer needed <t:1791720000:f>**\n\nWhich way"))' \
    >/dev/null || fail "button, board, unanswered, and re-held calls must each show their own outcome: $out"
  for pair in digits overlap; do
    case "$pair" in
      digits) options='[{"label":"Wait 2 days","recommended":true},{"label":"Proceed"}]'; label='Wait 2 days'; generation=8 ;;
      overlap) options='[{"label":"Approve"},{"label":"Approve with changes","recommended":true}]'; label='Approve with changes'; generation=9 ;;
    esac
    (cd "$home" && tasks-axi add "$id-$pair" "Pick the route" --kind captain --repo sample >/dev/null) \
      || fail "could not create the recommended captain-call fixture"
    home_env "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id-$pair" --reason "route pending" --repo sample >/dev/null \
      || fail "could not hold the recommended captain call"
    emit_decision "$home" "$generation" '{"key":"hold:'"$id-$pair"'","options":'"$options"'}' >/dev/null
    deliver "$home" "70000000000000001$generation"
    printf '%s\n' "$label, please." > "$home/answer.txt"
    home_env "$home" "$ROOT/bin/fm-captain-hold.sh" answer "$id-$pair" --decision-file "$home/answer.txt" >/dev/null \
      || fail "could not record the undecorated captain-call answer"
    out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
    jq -e --arg expected "✅ ⭐ $label chosen by the captain <t:1791720000:f>" \
      '.content | startswith("**" + $expected + "**\n\nWhich way")' <<<"$out" >/dev/null \
      || fail "the recommended captain-call outcome picked the wrong label or lost its question: $out"
  done
  pass "3 a captain-call click files a request the board records; board answers, unanswered closes, and re-holds show their own outcome"
}

# --- 4. everyone else is not authorised and records nothing ----------------

test_4_others_are_not_authorised() {
  local home out rc typed
  home="$TMP_ROOT/c4"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[{"label":"North"}]}' >/dev/null
  deliver "$home" "$POST"
  for who in "$MEMBER" "$STRANGER"; do
    for button in 1 d; do
      out=$(click "$home" "fmd:$KEY:$button" "$who" 880000000000000010)
      assert_contains "$out" "Firstmate: not authorised to answer this decision. Nothing was sent." \
        "author $who must not be able to use button $button"
    done
  done
  [ "$(resolved_lines "$home" pick)" = 0 ] || fail "a refused click answered the decision"
  [ "$(button_requests "$home")" = 0 ] || fail "a refused click reached Firstmate's inbox"
  [ -z "$(ls "$home"/state/ext-outbox/*.settled.json 2>/dev/null)" ] || fail "a refused click settled the post"

  # The member's typed message is admitted only at confirm authority, so a
  # click is never stronger than typing: it is refused outright instead.
  printf 'merge it' > "$home/member.txt"
  home_env "$home" "$INTAKE" --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:880000000000000013" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$CHANNEL" \
    --message-id 880000000000000013 --author "$MEMBER" \
    --secret-file "$home/config/ext-secret" --text-file "$home/member.txt" --no-wake >/dev/null \
    || fail "the member's typed message fixture was refused"
  typed=$(jq -r 'select(.author == "'"$MEMBER"'") | .authority' "$home"/state/ext-inbox/*.json)
  [ "$typed" = confirm ] || fail "the member's typed message must carry confirm authority, got '$typed'"
  printf '{"key":"%s","occurrence":"1","choice":"discuss","text":"t","by":"m","author":"%s","at":"now"}' \
    "$KEY" "$MEMBER" > "$home/forged.json"
  set +e
  home_env "$home" "$INTAKE" --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:880000000000000014" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$CHANNEL" \
    --message-id 880000000000000014 --author "$MEMBER" \
    --secret-file "$home/config/ext-secret" --text-file "$home/member.txt" \
    --origin button --decision-file "$home/forged.json" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 3 "$rc" "intake must refuse a button request below standing authority"
  [ "$(button_requests "$home")" = 0 ] || fail "intake wrote a confirm-authority button request"

  out=$(click "$home" "fmd:$KEY:1" "$CAPTAIN" 880000000000000015)
  assert_contains "$out" "Sent: North." "refusals must not use up the decision"
  pass "4 confirm-rule and unlisted authors get not authorised and file nothing; a click is never stronger than typing"
}

# --- 5. high-risk options need a confirmation step --------------------------

test_5_high_risk_options_need_a_confirmation_step() {
  local home payload out record
  home="$TMP_ROOT/c5"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  payload=$(emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[
    {"label":"Approve","confirm":true},{"label":"Deploy to prod"},{"label":"Delete the branch"},
    {"label":"Pay the invoice"},{"label":"Hold"}]}')
  jq -e '[.decision.options[].confirm] == [true,true,true,true,false]' "$payload" >/dev/null \
    || fail "declared and high-risk options must need confirmation: $(cat "$payload")"
  deliver "$home" "$POST"
  printf 'needs-decision [key=creds]: rotate?\n' >> "$home/state/$TASK.status"
  printf '{"key":"key:%s:creds","options":[{"label":"Rotate credentials"},{"label":"Merge"}]}' "$TASK" \
    > "$home/decision.json"
  home_env "$home" "$EMIT" --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:$REQUEST_MESSAGE" \
    --kind followup --generation 2 --text-file "$home/post.txt" --decision-file "$home/decision.json" >/dev/null
  jq -e '[.decision.options[].confirm] == [true,true]' "$home"/state/ext-outbox/*.followup.2.json >/dev/null \
    || fail "credential and merge options must need confirmation"
  deliver "$home" 700000000000000005

  out=$(click "$home" "fmd:$KEY:2" "$CAPTAIN" 880000000000000021)
  assert_contains "$out" "{\"text\": \"Confirm: Deploy to prod?\", \"confirm\": \"fmc:$POST:2\"}" \
    "a prod deploy must ask for a confirmation click"
  [ "$(resolved_lines "$home" pick)" = 0 ] || fail "an unconfirmed high-risk click answered the decision"
  [ "$(button_requests "$home")" = 0 ] || fail "an unconfirmed high-risk click woke Firstmate"

  out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmc:$POST:2" "$CAPTAIN" 880000000000000022 880000000000000099)
  assert_contains "$out" "Sent: Deploy to prod." "the confirmation click was not sent"
  [ "$(resolved_lines "$home" pick)" = 0 ] || fail "the plugin recorded the confirmed answer itself"
  record=$(button_request "$home" option)
  printf '%s' "$record" | jq -e '.decision.confirmed == true and .decision.confirm_prompt == "Confirm: Deploy to prod?"
    and .decision.option == "Deploy to prod"
    and .text == "Decision answer by button: Deploy to prod (confirmed)"' >/dev/null \
    || fail "the request must carry the confirmation verbatim: $record"
  [ "$(record_as_firstmate "$home" "$record")" = open ] || fail "Firstmate found the clicked decision no longer open"
  grep -qF 'confirmed by clicking "Confirm: Deploy to prod?"' "$home/state/$TASK.inbox/001.msg" \
    || fail "the recorded answer must show its confirmation"
  pass "5 merge, prod deploy, deletion, money, and credential options need a confirmation click before anything is sent, and the record shows it"
}

# --- 6. answered anywhere: no-ops with a notice, and the post shows it -----

test_6_answered_anywhere_settles_posts_and_clicks_are_no_ops() {
  local home out pids n record
  home="$TMP_ROOT/c6"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" "$POST"

  # Double clicks: exactly one request, every other click a no-op.
  pids=
  for n in 1 2 3; do
    FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmd:$KEY:1" "$CAPTAIN" "88000000000000003$n" > "$home/dup.$n" &
    pids="$pids $!"
  done
  # shellcheck disable=SC2086  # one pid per word
  wait $pids
  [ "$(button_requests "$home")" = 1 ] || fail "double clicks filed $(button_requests "$home") requests"
  [ "$(grep -l 'Sent: North' "$home"/dup.* | wc -l | tr -d ' ')" = 1 ] \
    || fail "exactly one double click may report it was sent"
  [ "$(grep -l 'Already sent' "$home"/dup.* | wc -l | tr -d ' ')" = 2 ] \
    || fail "every other double click must be a no-op with a notice: $(cat "$home"/dup.*)"
  [ "$(record_as_firstmate "$home" "$(button_request "$home" option)")" = open ] || fail "Firstmate found the clicked decision no longer open"

  # Answered on other channels: Firstmate relays a typed reply through the real
  # keyed path, and the post reads the ledger.
  printf 'needs-decision [key=typed]: typed\n' >> "$home/state/$TASK.status"
  emit_decision "$home" 2 '{"key":"key:'"$TASK"':typed","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000002
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key typed "The captain picked South." \
    >/dev/null 2>&1 || fail "fm-send could not relay the typed answer"
  printf 'needs-decision [key=num]: numbered\n' >> "$home/state/$TASK.status"
  emit_decision "$home" 3 '{"key":"key:'"$TASK"':num","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000003
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key num "2" \
    >/dev/null 2>&1 || fail "fm-send could not relay the numbered answer"
  printf 'needs-decision [key=chat]: chat\n' >> "$home/state/$TASK.status"
  emit_decision "$home" 4 '{"key":"key:'"$TASK"':chat","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000004
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key chat "Take whichever way is faster." \
    >/dev/null 2>&1 || fail "fm-send could not relay the free-form answer"
  # An answer naming two options names none.
  printf 'needs-decision [key=amb]: ambiguous\n' >> "$home/state/$TASK.status"
  emit_decision "$home" 6 '{"key":"key:'"$TASK"':amb","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000007
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key amb "1 or 2, whichever is faster" \
    >/dev/null 2>&1 || fail "fm-send could not relay the ambiguous answer"
  # A click sent North, but the captain typed South before Firstmate recorded
  # the click: the post shows what Firstmate actually recorded.
  printf 'needs-decision [key=change]: change\n' >> "$home/state/$TASK.status"
  emit_decision "$home" 7 '{"key":"key:'"$TASK"':change","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000006
  click "$home" "fmd:key:$TASK:change:1" "$CAPTAIN" 880000000000000043 700000000000000006 >/dev/null
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key change "South after all" \
    >/dev/null 2>&1 || fail "fm-send could not relay the changed answer"
  # Superseded by the task's terminal outcome.
  printf 'needs-decision [key=late]: late\n' >> "$home/state/$TASK.status"
  emit_decision "$home" 5 '{"key":"key:'"$TASK"':late","options":[{"label":"North"}]}' >/dev/null
  deliver "$home" 700000000000000005
  printf 'done: shipped without it\n' >> "$home/state/$TASK.status"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmd:key:$TASK:late:1" "$CAPTAIN" 880000000000000042 700000000000000005)
  assert_contains "$out" "Already decided: Closed - no longer needed <t:1791720000:f> - this click changed nothing." \
    "a superseded decision must be a no-op with a notice"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
  printf '%s\n' "$out" | jq -se '
    (map({(.message): .content}) | add) as $shown
    | ($shown["700000000000000001"] | startswith("**✅ North chosen by Dana <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000002"] | startswith("**✅ South chosen by the captain <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000003"] | startswith("**✅ South chosen by the captain <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000004"] | startswith("**✅ Decided <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000005"] | startswith("**Closed - no longer needed <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000006"] | startswith("**✅ South chosen by the captain <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000007"] | startswith("**✅ Decided <t:1791720000:f>**\n\nWhich way"))
      and (map(select(.message == "700000000000000002"))[0]
        | .components[0].components[0].style == 2
          and .components[0].components[1].style == 3
          and .components[0].components[1].label == "South ✓"
          and .components[1].components[0].style == 2)
      and (map(select(.message == "700000000000000004"))[0].components
        | [.[].components[] | .style] | all(. == 2))
      and all(.[]; [.components[].components[].disabled] | all)' >/dev/null \
    || fail "every answered or superseded post must be disabled and show its outcome from the ledger: $out"
  out=$(click "$home" "fmd:key:$TASK:typed:1" "$CAPTAIN" 880000000000000041 700000000000000002)
  assert_contains "$out" "Already decided: ✅ South chosen by the captain <t:1791720000:f> - this click changed nothing." \
    "a decision answered by typed reply must be a no-op with a notice"
  [ "$(button_requests "$home")" = 2 ] || fail "a click on an answered or closed decision filed a request"
  pass "6 double clicks file one request, and a decision answered by button, typed reply, or terminal outcome is a no-op that the post shows"
}

# --- 7. stale posts: replaced by a newer post, or expired -------------------

test_7_stale_posts_are_no_ops() {
  local home out record
  home="$TMP_ROOT/c7"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[{"label":"North"}]}' >/dev/null
  deliver "$home" "$POST"
  emit_decision "$home" 2 '{"key":"'"$KEY"'","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000002
  out=$(click "$home" "fmd:$KEY:1" "$CAPTAIN" 880000000000000051 "$POST")
  assert_contains "$out" "A newer post replaced this decision - use that one. This click changed nothing." \
    "a click on a replaced post must be a no-op with a notice"
  out=$(click "$home" "fmd:key:$TASK:other:1" "$CAPTAIN" 880000000000000052 700000000000000002)
  assert_contains "$out" "This decision post is no longer open" "a custom_id key that does not match the post must be a no-op"
  [ "$(button_requests "$home")" = 0 ] || fail "a stale click filed a request"

  # A replacement that reorders the options: the click names its own option,
  # and the older post shows it was replaced instead of reading the same index.
  printf 'needs-decision [key=swap]: swap\n' >> "$home/state/$TASK.status"
  emit_decision "$home" 3 '{"key":"key:'"$TASK"':swap","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000010
  emit_decision "$home" 4 '{"key":"key:'"$TASK"':swap","options":[{"label":"South"},{"label":"North"}]}' >/dev/null
  deliver "$home" 700000000000000011
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmd:key:$TASK:swap:1" "$CAPTAIN" 880000000000000054 700000000000000011)
  assert_contains "$out" "Sent: South." "the replacement post's option 1 must send its own label"
  [ "$(record_as_firstmate "$home" "$(button_request "$home" option)")" = open ] || fail "Firstmate found the clicked decision no longer open"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
  printf '%s\n' "$out" | jq -se --arg url "https://discord.com/channels/$GUILD/$CHANNEL/700000000000000011" '
    (map({(.message): .content}) | add) as $shown
    | ($shown["700000000000000011"] | startswith("**✅ South chosen by Dana <t:1791720000:f>**\n\nWhich way"))
      and ($shown["700000000000000010"] | startswith("♻️ **Replaced by a newer question** ([open](" + $url + "))\n\nWhich way"))' >/dev/null \
    || fail "the newer post must show its own choice and the replaced post must link to it: $out"

  # A worker key answered and then reopened for a new question: the old post
  # belongs to the first question and must not answer the second.
  printf 'needs-decision [key=again]: first question\n' >> "$home/state/$TASK.status"
  emit_decision "$home" 5 '{"key":"key:'"$TASK"':again","options":[{"label":"North"}]}' >/dev/null
  deliver "$home" 700000000000000012
  printf 'resolved [key=again]: answered: north\n' >> "$home/state/$TASK.status"
  printf 'needs-decision [key=again]: second question\n' >> "$home/state/$TASK.status"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmd:key:$TASK:again:1" "$CAPTAIN" 880000000000000055 700000000000000012)
  assert_contains "$out" "Already decided: Closed - no longer needed <t:1791720000:f> - this click changed nothing." \
    "a post must not answer a later lifecycle of its worker key"
  [ "$(button_requests "$home")" = 1 ] || fail "a click on a reopened key's old post filed a request"

  # A click whose request is still queued when its question is answered on
  # another channel and reopened for a new question: when Firstmate gets to
  # it, the request must not answer the new question.
  printf 'needs-decision [key=queued]: first question\n' >> "$home/state/$TASK.status"
  emit_decision "$home" 6 '{"key":"key:'"$TASK"':queued","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000013
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmd:key:$TASK:queued:1" "$CAPTAIN" 880000000000000056 700000000000000013)
  assert_contains "$out" "Sent: North." "the click on the first question was not sent"
  record=$(jq -s 'map(select(.decision.key == "key:'"$TASK"':queued")) | .[0]' "$home"/state/ext-inbox/*.json)
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key queued "South, typed before the click was handled" \
    >/dev/null 2>&1 || fail "fm-send could not relay the typed answer"
  printf 'needs-decision [key=queued]: second question\n' >> "$home/state/$TASK.status"
  [ "$(record_as_firstmate "$home" "$record")" = superseded ] \
    || fail "a request queued before an answer and reopen must not be still open"
  [ "$(resolved_lines "$home" queued)" = 1 ] || fail "the queued request answered the reopened question"
  [ "$(grep -c 'North' "$home/state/$TASK.inbox/"*.msg | awk -F: '{s += $NF} END {print s + 0}')" = 0 ] \
    || fail "the worker received the queued North answer for the new question"
  home_env "$home" "$ROOT/bin/fm-ext-decision.sh" still-open --key "key:$TASK:queued" \
    --occurrence 2 >/dev/null || fail "the new question must stay open"

  FM_EXT_NOW_OVERRIDE=$(( $(date +%s) + 700000 )) home_env "$home" "$POLL" >/dev/null
  out=$(click "$home" "fmd:$KEY:2" "$CAPTAIN" 880000000000000053 700000000000000002)
  assert_contains "$out" "This decision post is no longer open - this click changed nothing." \
    "a click on an expired post must be a no-op with a notice"
  [ "$(button_requests "$home")" = 2 ] || fail "a click on an expired post filed a request"
  pass "7 clicks on a replaced, reopened, mismatched, or expired post are no-ops, and a request queued before its question was answered and reopened never answers the new one"
}

# --- 8. Discuss and typed replies always work -------------------------------

test_8_discuss_and_typed_replies_stay_as_fallbacks() {
  local home out record
  home="$TMP_ROOT/c8"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[{"label":"North"}]}' >/dev/null
  deliver "$home" "$POST"
  out=$(click "$home" "fmd:$KEY:d" "$CAPTAIN" 880000000000000061)
  assert_contains "$out" "Firstmate will pick this up in the thread. Nothing was decided." "Discuss was not accepted"
  click "$home" "fmd:$KEY:d" "$CAPTAIN" 880000000000000062 >/dev/null
  [ "$(button_requests "$home")" = 1 ] || fail "a double Discuss click must be one request"
  record=$(button_request "$home" discuss)
  printf '%s' "$record" | jq -e --arg key "$KEY" '.authority == "standing" and .decision.key == $key
    and (.decision.text | endswith("Reply to this message with the number."))' >/dev/null \
    || fail "the Discuss request lost its decision context: $record"
  [ "$(resolved_lines "$home" pick)" = 0 ] || fail "Discuss decided something"
  [ -z "$(reconcile "$home" True)" ] || fail "Discuss turned the post's buttons off"

  # Discuss is for open decisions only: a replaced or decided post is a no-op.
  emit_decision "$home" 2 '{"key":"'"$KEY"'","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" 700000000000000002
  out=$(click "$home" "fmd:$KEY:d" "$CAPTAIN" 880000000000000064 "$POST")
  assert_contains "$out" "A newer post replaced this decision" "Discuss on a replaced post must be a no-op"
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key pick "North" >/dev/null 2>&1 \
    || fail "fm-send could not answer the decision"
  out=$(click "$home" "fmd:$KEY:d" "$CAPTAIN" 880000000000000065 700000000000000002)
  assert_contains "$out" "Already decided" "Discuss on a decided post must be a no-op"
  [ "$(button_requests "$home")" = 1 ] || fail "a stale Discuss woke Firstmate"

  # A typed reply to the button post still reaches Firstmate with the post's
  # numbered text, which is how the numbered-reply rule answers it.
  out=$(plugin_py "$home" "$CAPTAIN" "$POST" <<'PY'
import os, sys
from types import SimpleNamespace
import fmdecide, intake
fmdecide.setup()
source = SimpleNamespace(platform=SimpleNamespace(value="discord"), chat_id=os.environ["CHANNEL"],
    chat_type="group", user_id=sys.argv[3], user_name="u", thread_id=None,
    scope_id=os.environ["GUILD"], guild_id=os.environ["GUILD"], message_id="880000000000000063", is_bot=False)
raw = SimpleNamespace(id=880000000000000063, guild_id=int(os.environ["GUILD"]),
    channel_id=int(os.environ["CHANNEL"]), type=SimpleNamespace(value=19),
    author=SimpleNamespace(id=int(sys.argv[3]), bot=False, system=False), webhook_id=None,
    edited_at=None, reference=SimpleNamespace(message_id=int(sys.argv[4]),
    resolved=SimpleNamespace(id=int(sys.argv[4]), content="Which way?\n1. North")))
event = SimpleNamespace(text="1", source=source, raw_message=raw, message_id="880000000000000063",
    reply_to_message_id=sys.argv[4], reply_to_text="Which way?\n1. North")
print(intake.route_message_event(event))
PY
  ) || fail "the typed reply fixture failed"
  assert_contains "$out" "skip" "a typed reply to a button post must become a request"
  jq -s -e --arg post "$POST" 'map(select(.message_id == "880000000000000063"))
    | length == 1 and .[0].text == "1" and .[0].reply_to.message_id == $post' \
    "$home"/state/ext-inbox/*.json >/dev/null || fail "the typed numbered reply lost its reply context"
  pass "8 Discuss and a typed numbered reply remain fallbacks for an open decision, and a stale Discuss is a no-op"
}

# --- 9. emit refuses unsafe or closed decision posts ------------------------

test_9_emit_refuses_unsafe_or_closed_decisions() {
  local home decision text rc long
  home="$TMP_ROOT/c9"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  printf 'resolved [key=closed]: done\n' >> "$home/state/$TASK.status"
  long=$(printf 'k%.0s' $(seq 1 90))
  while IFS='|' read -r decision text; do
    printf '%s' "$decision" > "$home/decision.json"
    printf '%s' "$text" > "$home/post.txt"
    set +e
    home_env "$home" "$EMIT" --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:$REQUEST_MESSAGE" \
      --kind followup --generation 1 --text-file "$home/post.txt" --decision-file "$home/decision.json" \
      >/dev/null 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "emit accepted an unsafe or closed decision: $decision / $text"
  done <<EOF
{"key":"key:$TASK:never","options":[{"label":"North"}]}|Pick one
{"key":"key:$TASK:closed","options":[{"label":"North"}]}|Pick one
{"key":"key:$TASK:pick","options":[{"label":"Ship $TASK"}]}|Pick one
{"key":"key:$TASK:pick","options":[{"label":"North"}]}|Should $TASK go north?
{"key":"key:$TASK:pick","options":[{"label":"A"},{"label":"B"},{"label":"C"},{"label":"D"},{"label":"E"},{"label":"F"}]}|Pick one
{"key":"key:$TASK:pick","options":[{"label":"North"},{"label":"north"}]}|Pick one
{"key":"key:$TASK:pick","mode":"release","options":[{"label":"North"}]}|Pick one
{"key":"key:$TASK:$long","options":[{"label":"North"}]}|Pick one
{"key":"$TASK","options":[{"label":"North"}]}|Pick one
EOF
  [ -z "$(ls -A "$home/state/ext-outbox" 2>/dev/null)" ] || fail "a refused decision still published an outbox payload"
  pass "9 emit refuses closed keys, the key or task id in public text, oversize keys, and malformed options"
}

# --- 10. the real discord.py client routes clicks to the handler ------------

test_10_real_discord_client_routes_clicks() {
  local home py out
  py=${FM_TEST_HERMES_PYTHON:-$HOME/.hermes/hermes-agent/venv/bin/python}
  mkdir -p "$TMP_ROOT/hermes-probe"
  if [ ! -x "$py" ] || ! HERMES_HOME="$TMP_ROOT/hermes-probe" "$py" -c \
    'import discord.ui, gateway.run, gateway.config, plugins.platforms.discord.adapter; discord.ui.DynamicItem' \
    >/dev/null 2>&1; then
    echo "skip: 10 needs the Hermes gateway Python with discord.py (set FM_TEST_HERMES_PYTHON)"
    return 0
  fi
  home="$TMP_ROOT/c10"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[{"label":"North"},{"label":"Merge it"}]}' >/dev/null
  deliver "$home" "$POST"
  mkdir -p "$home/hermes"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" GUILD="$GUILD" CHANNEL="$CHANNEL" AUTHOR="$CAPTAIN" \
    HERMES_HOME="$home/hermes" KEY="$KEY" POST="$POST" \
    "$py" - <<'PY'
import asyncio, json, os, sys
from types import SimpleNamespace
import discord
from discord.ext import commands
from discord.webhook import async_ as webhook
import decisions

G, C, A = os.environ["GUILD"], os.environ["CHANNEL"], os.environ["AUTHOR"]
BOT = "424242424242424242"
calls = []


def component_click(iid, message_id, custom_id, label, ephemeral):
    """A Discord INTERACTION_CREATE for one button click, as the gateway delivers it."""
    user = {"id": A, "username": "dana", "discriminator": "0", "avatar": None, "global_name": "Dana"}
    return {
        "id": str(iid), "application_id": BOT, "type": 3, "token": "itok-%s" % iid, "version": 1,
        "guild_id": G, "channel_id": C,
        "channel": {"id": C, "type": 0, "guild_id": G, "name": "firstmate", "position": 0,
                    "permission_overwrites": [], "nsfw": False, "parent_id": None},
        "member": {"user": user, "roles": [], "joined_at": "2026-10-11T00:00:00+00:00",
                   "deaf": False, "mute": False, "flags": 0, "permissions": "0"},
        "app_permissions": "0", "locale": "en-US", "guild_locale": "en-US",
        "authorizing_integration_owners": {"0": G}, "context": 0, "entitlements": [],
        "attachment_size_limit": 8388608,
        "message": {
            "id": str(message_id), "channel_id": C, "type": 0, "content": "Which way should the fix go?",
            "author": {"id": BOT, "username": "fm", "discriminator": "0", "avatar": None, "bot": True},
            "embeds": [], "attachments": [], "mentions": [], "mention_roles": [],
            "mention_everyone": False, "pinned": False, "tts": False,
            "timestamp": "2026-10-11T00:00:00+00:00", "edited_timestamp": None,
            "flags": 64 if ephemeral else 0,
            "components": [{"type": 1, "id": 1, "components": [
                {"type": 2, "id": 2, "style": 2, "label": label, "custom_id": custom_id}]}],
        },
        "data": {"custom_id": custom_id, "component_type": 2, "id": 2},
    }


async def recorded_request(self, route, session=None, *, payload=None, multipart=None, **_kw):
    body = payload
    for part in multipart or []:
        if part.get("name") == "payload_json":
            body = json.loads(part["value"])
    calls.append({"method": route.method, "path": route.path, "body": body})
    if route.path.endswith("/callback"):
        return {"interaction": {"id": "1", "type": 3}}
    return {"id": "990000000000000099", "channel_id": C, "type": 0, "content": "",
            "author": {"id": BOT, "username": "fm", "discriminator": "0", "avatar": None},
            "embeds": [], "attachments": [], "mentions": [], "mention_roles": [],
            "mention_everyone": False, "pinned": False, "tts": False,
            "timestamp": "2026-10-11T00:00:00+00:00", "edited_timestamp": None,
            "flags": 64, "components": []}


async def settle(count):
    for _ in range(1200):
        if len(calls) >= count:
            return
        await asyncio.sleep(0.05)


async def main():
    bot = commands.Bot(command_prefix="!", intents=discord.Intents.none())
    await bot._async_setup_hook()
    bot._connection.user = discord.ClientUser(state=bot._connection, data={
        "id": BOT, "username": "fm", "discriminator": "0", "avatar": None,
        "bot": True, "verified": True, "mfa_enabled": False})
    # The installed Hermes gateway's own adapter registry and Discord adapter,
    # connected the way the adapter's connect() does it: by setting its client.
    from gateway import run as gateway_run
    from gateway.config import Platform, PlatformConfig
    from plugins.platforms.discord.adapter import DiscordAdapter
    adapter = DiscordAdapter(PlatformConfig(enabled=True, token="test-token"))
    runner = SimpleNamespace(adapters={Platform.DISCORD: adapter})
    gateway_run._gateway_runner_ref = lambda: runner
    webhook.AsyncWebhookAdapter.request = recorded_request

    print("routed-unconnected=%s" % decisions.ensure_click_route())
    adapter._client = bot
    print("ready-before=%s" % decisions.buttons_ready())
    print("routed=%s" % decisions.ensure_click_route())
    await asyncio.sleep(0.1)
    print("ready-after=%s" % decisions.buttons_ready())

    bot._connection.parse_interaction_create(component_click(
        970000000000000001, os.environ["POST"], decisions.custom_id(os.environ["KEY"], 2), "Merge it", False))
    await settle(2)
    confirm = calls[1]["body"]["components"][0]["components"][0]["custom_id"]
    bot._connection.parse_interaction_create(component_click(
        970000000000000003, 970000000000000004, confirm, "Confirm", True))
    await settle(4)
    for call in calls:
        print(json.dumps(call))


asyncio.run(main())
PY
  ) || fail "the real discord.py routing run failed: $out"
  assert_contains "$out" "routed-unconnected=False" "a Discord adapter with no client yet cannot route clicks"
  assert_contains "$out" "ready-before=False" "buttons must not be offered before the click route exists"
  assert_contains "$out" "routed=True" "the click route did not attach to the Hermes Discord adapter's client"
  assert_contains "$out" "ready-after=True" "buttons were not offered once the click route existed"
  [ "$(grep -c '"path": "/interactions/{webhook_id}/{webhook_token}/callback", "body": {"type": 5, "data": {"flags": 64}}' <<<"$out")" = 2 ] \
    || fail "each click must be deferred ephemerally at once: $out"
  assert_contains "$out" "\"content\": \"Confirm: Merge it?\", \"components\": [{\"type\": 1, \"components\": [{\"type\": 2, \"style\": 4, \"disabled\": false, \"label\": \"Confirm\", \"custom_id\": \"fmc:$POST:2\"}]}], \"tts\": false, \"flags\": 64}" \
    "a merge click must answer with an ephemeral confirmation button"
  assert_contains "$out" '"content": "Sent: Merge it. Firstmate will record it, and the post updates when it does.", "tts": false, "flags": 64' \
    "the confirmation click must be sent and answered ephemerally"
  [ "$(resolved_lines "$home" pick)" = 0 ] || fail "the routed click recorded the answer itself"
  [ "$(button_requests "$home")" = 1 ] || fail "the routed click did not file exactly one request"
  button_request "$home" option | jq -e '.decision.confirmed == true and .decision.by == "Dana"' >/dev/null \
    || fail "the routed request lost its confirmation or the clicker's name"
  pass "10 the real discord.py client routes decision clicks to the handler with ephemeral notices and a confirmation step"
}

# --- 11. a click that cannot be sent leaves nothing behind -------------------

test_11_unsent_click_releases_its_claim() {
  local home out
  home="$TMP_ROOT/c11"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  deliver "$home" "$POST"
  # Intake cannot publish while its inbox path is not a directory.
  mv "$home/state/ext-inbox" "$home/state/ext-inbox.saved"
  : > "$home/state/ext-inbox"
  out=$(click "$home" "fmd:$KEY:2" "$CAPTAIN" 880000000000000071)
  assert_contains "$out" "Firstmate could not send that click. Nothing was decided; try again, or reply to the post instead." \
    "a click that could not be filed must say nothing was decided"
  [ -z "$(reconcile "$home" False)" ] || fail "an unsent click turned the post's buttons off"
  rm -f "$home/state/ext-inbox"
  mv "$home/state/ext-inbox.saved" "$home/state/ext-inbox"
  out=$(click "$home" "fmd:$KEY:2" "$CAPTAIN" 880000000000000072)
  assert_contains "$out" "Sent: South." "a click after an unsent one must be sent"
  [ "$(button_requests "$home")" = 1 ] || fail "the retried click must file exactly one request"
  [ "$(resolved_lines "$home" pick)" = 0 ] || fail "the plugin recorded the answer itself"
  pass "11 a click that cannot be filed says nothing was decided and leaves the post open for another click"
}

# --- 12. a decision post in a request's topic thread -------------------------

test_12_topic_thread_posts_take_clicks_there() {
  local home out topic=999999999999999999 record
  home="$TMP_ROOT/c12"
  setup_home "$home"
  printf '%s\n' "$CHANNEL" > "$home/config/ext-channel"
  printf 'which route should the fix take?' > "$home/request.txt"
  home_env "$home" "$INTAKE" --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:$REQUEST_MESSAGE" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$CHANNEL" \
    --message-id "$REQUEST_MESSAGE" --author "$CAPTAIN" --origin message \
    --secret-file "$home/config/ext-secret" --text-file "$home/request.txt" \
    --no-wake >/dev/null || fail "the dedicated-channel request fixture was refused"
  open_key "$home" pick
  emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
  out=$(TOPIC="$topic" plugin_py "$home" <<'PY'
import json, os, sys
from pathlib import Path
import decisions, outbox_poster
decisions.buttons_ready = lambda: True
sent = []
def send(p):
    sent.append(p["thread_id"])
    return {"ok": True, "discord_message_id": "700000000000000001", "buttons": bool(p.get("decision"))}
outbox_poster.drain_outbox(send=send, home=Path(sys.argv[1]),
                           create_thread=lambda p, name: {"ok": True, "thread_id": os.environ["TOPIC"]})
print(json.dumps(sent))
PY
  ) || fail "the poster could not deliver the decision post"
  [ "$out" = "[\"$topic\"]" ] || fail "the decision post must land in the request's topic thread: $out"

  out=$(click "$home" "fmd:$KEY:2" "$CAPTAIN" 880000000000000081)
  assert_contains "$out" "This decision post is no longer open - this click changed nothing." \
    "a click reported from the parent channel does not come from the post's topic thread"
  out=$(CHAT="$topic" click "$home" "fmd:$KEY:2" "$CAPTAIN" 880000000000000082)
  assert_contains "$out" "Sent: South." "a click in the post's topic thread was not sent"
  record=$(button_request "$home" option) || fail "the topic-thread click filed no request"
  jq -e --arg ch "$CHANNEL" --arg th "$topic" \
    '.channel_id == $ch and .thread_id == $th and (.request_id | endswith(":" + $th + ":880000000000000082"))' \
    <<<"$record" >/dev/null || fail "the click request must come from the post's topic thread: $record"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" False)
  printf '%s\n' "$out" | jq -se --arg th "$topic" \
    'length == 1 and .[0].channel == $th and .[0].message == "700000000000000001"' >/dev/null \
    || fail "the sent line must edit the post in its topic thread: $out"
  pass "12 a decision post in a request's topic thread takes clicks there, files them there, and is edited there"
}

test_13_published_requests_retry_the_original_identity() {
  local home choice option interaction out record original request stem
  for choice in option discuss; do
    home="$TMP_ROOT/c13-$choice"
    setup_home "$home"
    open_request "$home"
    open_key "$home" pick
    emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
    deliver "$home" "$POST"
    mv "$home/state/ext-context" "$home/state/ext-context.saved"
    : > "$home/state/ext-context"
    option=2
    [ "$choice" != discuss ] || option=d
    interaction=880000000000000091
    out=$(click "$home" "fmd:$KEY:$option" "$CAPTAIN" "$interaction")
    assert_contains "$out" "notification needs recovery" "a published request must not be reported unsent"
    original=$(button_request "$home" "$choice") || fail "intake did not publish before context failed"
    request=$(jq -r '.request_id' <<<"$original")
    if [ "$choice" = option ]; then
      stem=$(basename "$(ls "$home"/state/ext-outbox/*.sent.json)" .sent.json)
      [ "$(jq -r '.request_id' "$home/state/ext-outbox/$stem.sent.json")" = "$request" ] || fail "the claim lost its request identity"
      out=$(reconcile "$home" False)
      assert_contains "$out" "South sent by Dana" "a published request must keep the post showing sent"
      option=1
    fi
    out=$(click "$home" "fmd:$KEY:$option" "$CAPTAIN" 880000000000000092 "$POST" Other)
    assert_contains "$out" "notification needs recovery" "a failed retry must preserve its durable request"
    [ "$(button_requests "$home")" = 1 ] || fail "retry filed a second request"
    rm "$home/state/ext-context"
    mv "$home/state/ext-context.saved" "$home/state/ext-context"
    out=$(click "$home" "fmd:$KEY:$option" "$CAPTAIN" 880000000000000093 "$POST" Other)
    [ "$(button_requests "$home")" = 1 ] || fail "recovery filed a second request"
    record=$(button_request "$home" "$choice")
    [ "$record" = "$original" ] || fail "retry changed the original choice or audit"
    [ -f "$home/state/ext-context/$(jq -r '.slug' <<<"$record").offered.json" ] || fail "retry did not offer the original request"
    [ "$(resolved_lines "$home" pick)" = 0 ] || fail "retry recorded an answer itself"
  done
  pass "13 option and Discuss retries preserve published request identity and payload after notification failure"
}

test_14_audit_metadata_does_not_match_options() {
  local home out record
  home="$TMP_ROOT/c14"
  setup_home "$home"
  open_request "$home"
  open_key "$home" merge
  emit_decision "$home" 1 '{"key":"key:'"$TASK"':merge","options":[{"label":"Merge"},{"label":"Hold"}]}' >/dev/null
  deliver "$home" "$POST"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmd:key:$TASK:merge:2" "$CAPTAIN" 880000000000000094)
  assert_contains "$out" "Sent: Hold." "the Hold click was not sent"
  record=$(button_request "$home" option)
  [ "$(record_as_firstmate "$home" "$record")" = open ] || fail "the Hold decision was not recorded"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
  assert_contains "$out" "Hold chosen by Dana" "the audit's merge key must not match the Merge option"
  open_key "$home" ambiguous-audit
  emit_decision "$home" 2 '{"key":"key:'"$TASK"':ambiguous-audit","options":[{"label":"Merge"},{"label":"Hold"}]}' >/dev/null
  deliver "$home" 700000000000000011
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key ambiguous-audit 'Decision answer: Merge or Hold (Discord button: option 2 Hold)' >/dev/null 2>&1 || fail "could not record the ambiguous answer"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
  jq -e '.content | startswith("**✅ Merge chosen by the captain <t:1791720000:f>**\n\nWhich way")' \
    <<<"$out" >/dev/null || fail "a full label prefix must win after audit removal and preserve the question"
  pass "14 option matching ignores appended audit metadata and gives the full label prefix precedence"
}

test_15_full_labels_keep_digits_and_overlaps_together() {
  local home pair options option label shown variant slug key post out record mode answer expected gen=0
  home="$TMP_ROOT/c15"
  setup_home "$home"
  open_request "$home"
  for pair in digits overlap; do
    case "$pair" in
      digits) options='[{"label":"Wait 2 days"},{"label":"Proceed"}]'; option=1; label='Wait 2 days' ;;
      overlap) options='[{"label":"Approve"},{"label":"Approve with changes"}]'; option=2; label='Approve with changes' ;;
    esac
    for variant in plain recommended; do
      shown=$label
      if [ "$variant" = recommended ]; then
        options=$(jq -c --argjson id "$option" '.[$id - 1].recommended = true' <<<"$options")
        shown="⭐ $label"
      fi
      for mode in click typed starred numbered prefix fallback; do
        gen=$((gen + 1))
        slug="$pair-$variant-$mode"
        key="key:$TASK:$slug"
        post="70000000000000002$gen"
        open_key "$home" "$slug"
        emit_decision "$home" "$gen" '{"key":"'"$key"'","options":'"$options"'}' >/dev/null
        deliver "$home" "$post"
        if [ "$mode" = click ]; then
          out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmd:$key:$option" "$CAPTAIN" "88000000000000010$gen" "$post")
          assert_contains "$out" "Sent: $shown." "the full-label click was not sent"
          record=$(jq -c --arg key "$key" 'select(.decision.key == $key and .decision.choice == "option")' "$home"/state/ext-inbox/*.json)
          [ "$(resolved_lines "$home" "$slug")" = 0 ] || fail "the plugin recorded the full-label answer itself"
          [ "$(home_env "$home" "$ROOT/bin/fm-ext-decision.sh" still-open --key "$key" --occurrence "$(jq -r '.decision.occurrence' <<<"$record")")" = open ] || fail "the full-label request is no longer open"
          answer="Decision answer: $shown, check again in 2 days (Discord button: option $option \"$shown\" chosen by Dana ($CAPTAIN) at 2026-10-11T12:00:00Z for $key)"
          home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key "$slug" "$answer" >/dev/null 2>&1 || fail "could not record the full-label click with trailing text"
          expected="✅ $shown chosen by Dana <t:1791720000:f>"
        else
          if [ "$mode" = typed ]; then
            answer="Decision answer: $label, please."
            expected="✅ $shown chosen by the captain <t:1791720000:f>"
          elif [ "$mode" = starred ]; then
            answer="Decision answer: $shown, please."
            expected="✅ $shown chosen by the captain <t:1791720000:f>"
          elif [ "$mode" = numbered ]; then
            answer="Decision answer: $option"
            expected="✅ $shown chosen by the captain <t:1791720000:f>"
          elif [ "$mode" = prefix ]; then
            case "$pair" in
              digits) answer='Decision answer: Wait 2 days or Proceed' ;;
              overlap) answer='Decision answer: Approve with changes or Approve' ;;
            esac
            expected="✅ $shown chosen by the captain <t:1791720000:f>"
          else
            case "$pair" in
              digits) answer='Decision answer: Choose Wait 2 days or Proceed' ;;
              overlap) answer='Decision answer: Choose Approve with changes or Approve' ;;
            esac
            expected='✅ Decided <t:1791720000:f>'
          fi
          home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key "$slug" "$answer" >/dev/null 2>&1 || fail "could not record the typed full-label answer"
        fi
        out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
        jq -e --arg expected "$expected" \
          '.content | startswith("**" + $expected + "**\n\nWhich way")' <<<"$out" >/dev/null \
          || fail "the full-label outcome lost its choice, attribution, fallback ambiguity, or original question: $out"
      done
    done
  done
  pass "15 the longest full label prefix wins over trailing references, with ambiguity detection only in the fallback"
}

test_16_recommended_option_renders_green_with_a_single_star() {
  local home payload out record rc long
  home="$TMP_ROOT/c16"
  setup_home "$home"
  open_request "$home"
  open_key "$home" pick
  payload=$(emit_decision "$home" 1 '{"key":"'"$KEY"'","options":[
    {"label":"North","recommended":true},{"label":"Merge it"}]}')
  jq -e --arg key "$KEY" '.decision.key == $key
    and .decision.options == [{"id":1,"label":"⭐ North","confirm":false,"recommended":true},{"id":2,"label":"Merge it","confirm":true}]' \
    "$payload" >/dev/null || fail "the recommended payload lost its star or flags: $(cat "$payload")"
  out=$(plugin_py "$home" "$payload" <<'PY'
import json, sys
import decisions
payload = json.load(open(sys.argv[3]))
print(json.dumps(decisions.components_for(payload["decision"])))
PY
) || fail "the renderer refused the recommended decision"
  printf '%s' "$out" | jq -e --arg key "$KEY" '
    .[0].components[0] == {"type":2,"style":3,"label":"⭐ North","custom_id":("fmd:" + $key + ":1"),"disabled":false}
    and .[0].components[1] == {"type":2,"style":4,"label":"Merge it","custom_id":("fmd:" + $key + ":2"),"disabled":false}' \
    >/dev/null || fail "the recommended button must be green and the other keeps its style: $out"
  out=$(plugin_py "$home" <<'PY'
import json, decisions
decision = {"key": "key:route-fix:limit", "options": [
    {"id": 1, "label": "x" * 80}, {"id": 2, "label": "Other"}]}
print(json.dumps(decisions.components_for(
    decision, disabled=True, selected_option_id=1)))
PY
  ) || fail "the renderer refused a maximum-length selected label"
  printf '%s' "$out" | jq -e '
    .[0].components[0].style == 3
    and .[0].components[0].label == (("x" * 78) + " ✓")
    and (.[0].components[0].label | length == 80)
    and .[0].components[1].style == 2
    and .[1].components[0].style == 2
    and all(.[].components[]; .disabled)' >/dev/null \
    || fail "the selected marker must fit the Discord label limit and leave other buttons grey: $out"
  deliver "$home" "$POST"
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key pick 'Decision answer: Choose North' >/dev/null 2>&1 \
    || fail "could not record the undecorated recommended label fallback"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
  jq -e '.content | startswith("**✅ ⭐ North chosen by the captain <t:1791720000:f>**\n\nWhich way")' \
    <<<"$out" >/dev/null \
    || fail "the recommended label fallback lost its display label or original question: $out"
  open_key "$home" confirm-rec
  payload=$(emit_decision "$home" 2 '{"key":"key:'"$TASK"':confirm-rec","options":[
    {"label":"Merge it","confirm":true,"recommended":true},{"label":"Hold"}]}')
  out=$(plugin_py "$home" "$payload" <<'PY'
import json, sys
import decisions
payload = json.load(open(sys.argv[3]))
print(json.dumps(decisions.components_for(payload["decision"])))
PY
) || fail "the renderer refused the confirm-plus-recommended decision"
  printf '%s' "$out" | jq -e '.[0].components[0].style == 3 and .[0].components[1].style == 2' \
    >/dev/null || fail "confirm-plus-recommended renders green and other options keep their styles: $out"
  deliver "$home" 700000000000000031
  out=$(click "$home" "fmd:key:$TASK:confirm-rec:1" "$CAPTAIN" 880000000000000101 700000000000000031)
  assert_contains "$out" '{"text": "Confirm: ⭐ Merge it?", "confirm": "fmc:700000000000000031:1"}' \
    "a confirm-plus-recommended option must still ask for a confirmation click"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 click "$home" "fmc:700000000000000031:1" "$CAPTAIN" 880000000000000102 700000000000000031)
  assert_contains "$out" "Sent: ⭐ Merge it." "the confirmed recommended click was not sent"
  record=$(button_request "$home" option)
  [ "$(record_as_firstmate "$home" "$record")" = open ] || fail "Firstmate found the recommended decision no longer open"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
  printf '%s' "$out" | jq -e --arg expected "✅ ⭐ Merge it chosen by Dana <t:1791720000:f>" \
    '.content | startswith("**" + $expected + "**\n\nWhich way")' >/dev/null \
    || fail "the recorded answer label or original question was lost: $out"
  open_key "$home" pre-starred
  deliver "$home" 700000000000000032
  payload=$(emit_decision "$home" 3 '{"key":"key:'"$TASK"':pre-starred","options":[
    {"label":"⭐ North","recommended":true},{"label":"South"}]}')
  jq -e '[.decision.options[0].label] == ["⭐ North"]' "$payload" >/dev/null \
    || fail "a pre-starred label must not be doubled: $(cat "$payload")"
  open_key "$home" two-rec
  set +e
  printf '{"key":"key:%s:two-rec","options":[{"label":"North","recommended":true},{"label":"South","recommended":true}]}' \
    "$TASK" > "$home/decision.json"
  printf 'Pick one' > "$home/post.txt"
  home_env "$home" "$EMIT" --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:$REQUEST_MESSAGE" \
    --kind followup --generation 4 --text-file "$home/post.txt" --decision-file "$home/decision.json" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "emit accepted two recommended options"
  open_key "$home" star-limit
  long=$(printf 'x%.0s' $(seq 1 79))
  set +e
  printf 'Pick one' > "$home/post.txt"
  printf '{"key":"key:%s:star-limit","options":[{"label":"%s","recommended":true},{"label":"South"}]}' \
    "$TASK" "$long" > "$home/decision.json"
  home_env "$home" "$EMIT" --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:$REQUEST_MESSAGE" \
    --kind followup --generation 5 --text-file "$home/post.txt" --decision-file "$home/decision.json" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "emit accepted a recommended label whose star prefix exceeds the length limit"
  pass "16 the recommended option renders green with a single star, still confirms when risky, and emit refuses two recommended options"
}

# --- 17. settled edits preserve sections and fit legacy posts ---------------

test_17_outcome_headers_fit_reserved_and_legacy_posts() {
  local home question explanation option_text cue full slug progress payload original out repeat legacy last_message
  local old_payload new_payload old_progress new_progress
  home="$TMP_ROOT/c17"
  setup_home "$home"
  open_request "$home"

  open_key "$home" near-limit
  question=$(printf '%*s' 1800 '' | tr ' ' Q)
  option_text=$'1. North\n2. South'
  cue='Tap a button, or reply with the number.'
  full=$(printf '%s\n\n%s\n%s' "$question" "$option_text" "$cue")
  printf '%s' "$full" > "$home/post.txt"
  jq -n --arg key "key:$TASK:near-limit" --arg question "$question" \
    --arg options "$option_text" --arg cue "$cue" \
    '{key:$key, options:[{label:"North"},{label:"South"}],
      sections:{question:$question, explanation:"", options:$options, cue:$cue}}' \
    > "$home/decision.json"
  slug=$(home_env "$home" "$EMIT" --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:$REQUEST_MESSAGE" \
    --kind followup --generation 1 --text-file "$home/post.txt" \
    --decision-file "$home/decision.json") || fail "emit refused structured near-limit decision"
  payload="$home/state/ext-outbox/$slug.followup.1.json"
  deliver "$home" 700000000000000101
  progress="${payload%.json}.progress.json"
  jq -e '.decision.sections.structured == true
    and .decision.sections.explanation == ""
    and (.texts | length == 2)
    and .discord_message_ids == ["700000000000000101", "700000000000000102"]
    and (.limit as $limit | all(.texts[]; length <= $limit))
    and (.texts[-1] | contains("1. North\n2. South\nTap a button, or reply with the number."))' \
    "$progress" >/dev/null || fail "the decision split lost its options or header reserve"
  original=$(jq -r '.texts[-1]' "$progress")
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key near-limit North >/dev/null 2>&1 \
    || fail "could not settle the near-limit decision"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
  printf '%s\n' "$out" | jq -se --arg original "$original" '
    length == 1
    and .[0].message == "700000000000000102"
    and .[0].content == ("**✅ North chosen by the captain <t:1791720000:f>**\n\n" + $original)
    and (.[0].content | length <= 2000)
    and ([.[0].components[].components[] | .disabled] | all)
    and .[0].components[0].components[0].style == 3
    and .[0].components[0].components[0].label == "North ✓"
    and .[0].components[0].components[1].style == 2
    and .[0].components[1].components[0].style == 2' >/dev/null \
    || fail "only the last chunk must be edited, with its original text and selected button preserved: $out"


  open_key "$home" explanation-overflow
  question='Which option should the team record?'
  explanation=$(printf '%*s' 2300 '' | tr ' ' E)
  full=$(printf '%s\n\n%s\n\n%s\n%s' "$question" "$explanation" "$option_text" "$cue")
  printf '%s' "$full" > "$home/post.txt"
  jq -n --arg key "key:$TASK:explanation-overflow" --arg question "$question" \
    --arg explanation "$explanation" --arg options "$option_text" --arg cue "$cue" \
    '{key:$key, options:[{label:"North"},{label:"South"}],
      sections:{question:$question, explanation:$explanation, options:$options, cue:$cue}}' \
    > "$home/decision.json"
  slug=$(home_env "$home" "$EMIT" --request-id "discord:$GUILD:$CHANNEL:$CHANNEL:$REQUEST_MESSAGE" \
    --kind followup --generation 2 --text-file "$home/post.txt" \
    --decision-file "$home/decision.json") || fail "emit refused the structured explanation fixture"
  payload="$home/state/ext-outbox/$slug.followup.2.json"
  deliver "$home" 700000000000000110
  progress="${payload%.json}.progress.json"
  last_message=$(jq -r '.discord_message_ids[-1]' "$progress")
  if ! jq --arg full "$full" '.texts[-1] = $full' "$progress" \
    > "$home/explanation-progress.json"; then
    fail "could not force the explanation overflow fixture"
  fi
  mv "$home/explanation-progress.json" "$progress" \
    || fail "could not install the explanation overflow fixture"
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key explanation-overflow North \
    >/dev/null 2>&1 || fail "could not settle the explanation overflow"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
  printf '%s' "$out" | jq -e --arg message "$last_message" --arg question "$question" \
    --arg option_text "$option_text" --arg cue "$cue" '
    .message == $message
    and (.content | startswith("**✅ North chosen by the captain <t:1791720000:f>**\n\n" + $question + "\n\nE"))
    and (.content | contains("(trimmed)\n\n" + $option_text + "\n" + $cue))' >/dev/null \
    || fail "overflow must trim only the explanation tail and retain the full question and options: $out"

  open_key "$home" legacy-overflow
  payload=$(emit_decision "$home" 3 '{"key":"key:'"$TASK"':legacy-overflow","options":[{"label":"North"},{"label":"South"}]}')
  deliver "$home" 700000000000000120
  progress="${payload%.json}.progress.json"
  legacy=$(printf '%*s' 1900 '' | tr ' ' L)
  if ! jq --arg legacy "$legacy" '.texts[-1] = $legacy
      | .decision.options[0].label = ("North" * 16) | del(.decision.sections)' \
    "$progress" > "$home/legacy-progress.json"; then
    fail "could not build the legacy overflow fixture"
  fi
  mv "$home/legacy-progress.json" "$progress" \
    || fail "could not install the legacy overflow fixture"
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key legacy-overflow \
    "$(printf 'North%.0s' {1..16})" >/dev/null 2>&1 || fail "could not settle the legacy decision"
  out=$(FM_EXT_NOW_OVERRIDE=1791720000 reconcile "$home" True)
  printf '%s' "$out" | jq -e '
    .message == "700000000000000120" and .content == null
    and ([.components[].components[] | .disabled] | all)
    and .components[0].components[0].style == 3
    and (.components[0].components[0].label | endswith(" ✓"))
    and .components[0].components[1].style == 2
    and .components[1].components[0].style == 2' >/dev/null \
    || fail "legacy overflow must settle its buttons without a text edit: $out"
  jq -e --arg legacy "$legacy" '.texts[-1] == $legacy' "$progress" >/dev/null \
    || fail "legacy overflow changed the original text"
  [ -f "${payload%.json}.settled.json" ] || fail "legacy overflow lost its settlement"
  jq -e '.components_only == true and .final == true and .selected_option_id == 1' \
    "${payload%.json}.finalized" >/dev/null || fail "legacy button settlement was not receipted"

  open_key "$home" replace-fallback
  old_payload=$(emit_decision "$home" 4 \
    '{"key":"key:'"$TASK"':replace-fallback","options":[{"label":"North"}]}')
  deliver "$home" 700000000000000130
  new_payload=$(emit_decision "$home" 5 \
    '{"key":"key:'"$TASK"':replace-fallback","options":[{"label":"South"}]}')
  deliver "$home" 700000000000000140
  old_progress="${old_payload%.json}.progress.json"
  new_progress="${new_payload%.json}.progress.json"
  if ! jq '.posted_at = 1000' "$old_progress" > "$home/old-progress.json"; then
    fail "could not order the old post fixture"
  fi
  mv "$home/old-progress.json" "$old_progress" || fail "could not install old-post ordering"
  if ! jq '.posted_at = 1001 | .discord_message_ids = []' "$new_progress" \
    > "$home/new-progress.json"; then
    fail "could not hide the newer message id"
  fi
  mv "$home/new-progress.json" "$new_progress" || fail "could not install missing newer message id"
  out=$(reconcile "$home" True)
  printf '%s' "$out" | jq -e '
    .message == "700000000000000130"
    and (.content | startswith("**Replaced by a newer question**\n\nWhich way should the fix go?"))
    and (.content | length <= 2000)
    and ([.components[].components[] | .disabled] | all)
    and ([.components[].components[] | .style] | all(. == 2))' >/dev/null \
    || fail "the replacement fallback must keep the question and disable the old buttons: $out"
  repeat=$(reconcile "$home" True)
  [ -z "$repeat" ] || fail "settled overflow and replacement edits must not retry unchanged posts"
  pass "17 reserved chunks settle without trimming, only the last chunk is edited, and legacy overflow settles buttons without changing text"
}

test_18_decision_plans_preserve_questions_and_legacy_boundaries() {
  local home mode length slug payload
  for mode in structured unstructured; do
    home="$TMP_ROOT/c18-$mode"
    setup_home "$home"
    open_request "$home"
    open_key "$home" capped
    payload=$(emit_decision "$home" 1 '{"key":"key:'"$TASK"':capped","options":[{"label":"North"},{"label":"South"}]}')
    plugin_py "$home" "$payload" "$mode" <<'PYTEST' || fail "capped $mode decision lost protected text"
import json, sys
from pathlib import Path
import outbox_poster as poster

home, path, mode = Path(sys.argv[1]), Path(sys.argv[3]), sys.argv[4]
payload = json.loads(path.read_text())
question = "Q" * 1800
options = "1. North\n2. South"
cue = "Tap a button, or reply with the number."
text = question + "\n\n" + options + "\n" + cue
payload["text"] = text
payload["decision"]["sections"] = dict(question=question, explanation="", options=options,
                                        cue=cue, structured=mode == "structured")
path.write_text(json.dumps(payload))
poster.reply_limits = lambda home: {"limit": 1900, "cap": 1}
sent = []
def send(chunk):
    sent.append(chunk["text"])
    return {"discord_message_id": str(1800 + chunk["chunk_index"]), "buttons": True}

assert poster.deliver_one(path, send=send, home=home) == "failed"
assert sent == []
assert poster.load_progress(payload, home) is None
poster.reply_limits = lambda home: {"limit": 1900, "cap": 2}
assert poster.deliver_one(path, send=send, home=home) == "sent"
assert len(sent) == 2
assert "".join(sent) == text
assert sent[-1].endswith(options + "\n" + cue)
assert all(len(chunk) <= 1744 for chunk in sent)
PYTEST
  done
  for length in 3200 3600; do
    home="$TMP_ROOT/c18-resume-$length"
    setup_home "$home"
    open_request "$home"
    open_key "$home" resume
    slug=$(emit_decision "$home" 1 '{"key":"key:'"$TASK"':resume","options":[{"label":"North"},{"label":"South"}]}')
    plugin_py "$home" "$slug" "$length" <<'PYTEST' || fail "legacy decision resume changed chunk boundaries"
import json, sys
from pathlib import Path
import outbox_poster as poster

home, path, length = Path(sys.argv[1]), Path(sys.argv[3]), int(sys.argv[4])
payload = json.loads(path.read_text())
payload["text"] = "0123456789" * (length // 10)
if length == 3600:
    payload["decision"].pop("sections", None)
path.write_text(json.dumps(payload))
plan = poster.split_reply(payload["text"], home=home, limit=1900, cap=25, legacy=True)
assert len(plan["texts"]) == 2
original = poster.split_decision_reply
poster.split_decision_reply = lambda payload, **kwargs: plan
sent = []
def partial(chunk):
    if chunk["chunk_index"]:
        raise poster.DiscordSendError("transient", "retry later")
    sent.append(chunk["text"])
    return {"discord_message_id": "1801"}
assert poster.deliver_one(path, send=partial, home=home) == "failed"
progress = poster.load_progress(payload, home)
assert progress["posted_count"] == 1
assert progress["limit"] == 1900
progress.pop("texts")
poster.write_progress(payload, progress, home)
poster.split_decision_reply = original
def resume(chunk):
    sent.append(chunk["text"])
    return {"discord_message_id": "1802", "buttons": True}
assert poster.deliver_one(path, send=resume, home=home) == "sent"
assert sent == plan["texts"], sent
assert poster.load_progress(payload, home)["posted_count"] == 2
assert "sections" not in poster.load_progress(payload, home)["decision"]
PYTEST
  done
  pass "18 capped decisions refuse text loss and legacy resumes retain original chunks"
}

assert_legacy_edit() {
  local home=$1 payload=$2 selected=$3 final=$4
  plugin_py "$home" "$payload" "$selected" "$final" <<'PYTEST' || fail "legacy buttons did not settle without changing text"
import io, json, sys
from pathlib import Path
from unittest.mock import patch
import outbox_poster as poster

home, path = Path(sys.argv[1]), Path(sys.argv[3])
selected = None if sys.argv[4] == "none" else int(sys.argv[4])
final = sys.argv[5] == "true"
state_path = home / "discord.json"
state = json.loads(state_path.read_text())
original = state["content"].encode()
earlier = state["earlier"].encode()
requests = []
settled = path.parent / (path.stem + ".settled.json")
ledger = settled.read_bytes() if settled.exists() else None
def http(request, timeout):
    body = json.loads(request.data)
    requests.append((request.get_method(), request.full_url, body))
    if "content" in body:
        state["content"] = body["content"]
    state["components"] = body["components"]
    return io.BytesIO(b"{}")
with patch.object(poster, "_bot_token", return_value="test-token"), patch.object(
    poster.urllib.request, "urlopen", side_effect=http,
):
    result = poster.reconcile_decision_posts(home=home)
    assert result == [path.stem], (result, requests)
    assert len(requests) == 1, requests
    method, url, body = requests[0]
    assert method == "PATCH" and url.endswith("/messages/700000000000000001"), requests
    assert set(body) == {"components", "allowed_mentions"}, body
    assert state["content"].encode() == original
    assert state["earlier"].encode() == earlier
    buttons = [button for row in body["components"] for button in row["components"]]
    assert all(button["disabled"] for button in buttons), buttons
    for index, button in enumerate(buttons, 1):
        chosen = index == selected
        assert button["style"] == (3 if chosen else 2), buttons
        assert button["label"].endswith(" ✓") == chosen, buttons
    receipt = json.loads((path.parent / (path.stem + ".finalized")).read_text())
    assert receipt == dict(components_only=True, final=final, selected_option_id=selected), receipt
    assert poster.reconcile_decision_posts(home=home) == []
    assert len(requests) == 1
if ledger is not None:
    assert settled.read_bytes() == ledger
state_path.write_text(json.dumps(state))
PYTEST
}

test_19_legacy_buttons_settle_in_every_outcome_state() {
  local home state payload out record selected
  for state in waiting chosen captain ambiguous closed replaced; do
    home="$TMP_ROOT/c19-$state"
    setup_home "$home"
    open_request "$home"
    open_key "$home" legacy
    payload=$(emit_decision "$home" 1 '{"key":"key:'"$TASK"':legacy","options":[{"label":"North"},{"label":"South"}]}')
    deliver "$home" "$POST"
    plugin_py "$home" "$payload" "$state" <<'PYTEST' || fail "could not prepare legacy decision"
import json, sys
from pathlib import Path
import outbox_poster as poster

home, path, state = Path(sys.argv[1]), Path(sys.argv[3]), sys.argv[4]
progress_path = path.parent / (path.stem + ".progress.json")
progress = json.loads(progress_path.read_text())
progress["decision"]["options"][0]["label"] = "North" * 16
prefix = "Original question?\n1. " + "North" * 16 + "\n2. South\n\n"
original = prefix + "E" * (1900 - len(prefix) - 4) + " \n\t\n"
assert len(original) == 1900
progress["texts"] = [original]
if state != "captain":
    progress["decision"].pop("sections", None)
if state in ("captain", "ambiguous", "closed"):
    progress.pop("texts")
slug, kind, generation = path.stem.rsplit(".", 2)
poster.write_progress(dict(slug=slug, kind=kind, generation=int(generation)), progress, home)
path.unlink(missing_ok=True)
(home / "discord.json").write_text(json.dumps(dict(content=original, earlier="Earlier chunk\n")))
PYTEST
    selected=none
    case "$state" in
      waiting|chosen)
        out=$(click "$home" "fmd:key:$TASK:legacy:1" "$CAPTAIN" 880000000000000191)
        assert_contains "$out" "Sent:" "the legacy click was not filed"
        selected=1
        if [ "$state" = chosen ]; then
          record=$(button_request "$home" option)
          [ "$(record_as_firstmate "$home" "$record")" = open ] || fail "could not record legacy choice"
        fi
        ;;
      captain)
        home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key legacy \
          "$(printf 'North%.0s' {1..16})" >/dev/null 2>&1 || fail "could not record captain legacy choice"
        selected=1
        ;;
      ambiguous)
        home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key legacy \
          "No preference" >/dev/null 2>&1 || fail "could not record ambiguous legacy choice"
        ;;
      closed) printf 'done: no longer needed\n' >> "$home/state/$TASK.status" ;;
      replaced)
        emit_decision "$home" 2 '{"key":"key:'"$TASK"':legacy","options":[{"label":"North"},{"label":"South"}]}' >/dev/null
        deliver "$home" 700000000000000002
        ;;
    esac
    if [ "$state" = waiting ]; then
      assert_legacy_edit "$home" "$payload" "$selected" false
      record=$(button_request "$home" option)
      [ "$(record_as_firstmate "$home" "$record")" = open ] || fail "could not finalize waiting legacy choice"
    fi
    assert_legacy_edit "$home" "$payload" "$selected" true
  done
  pass "19 every legacy outcome settles buttons with 1900-character text and 80-character options unchanged"
}

test_20_legacy_waiting_receipts_need_no_original_or_payload() {
  local home payload out
  home="$TMP_ROOT/c20"
  setup_home "$home"
  open_request "$home"
  open_key "$home" legacy-waiting
  payload=$(emit_decision "$home" 1 '{"key":"key:'"$TASK"':legacy-waiting","options":[{"label":"North"},{"label":"South"}]}')
  deliver "$home" "$POST"
  out=$(click "$home" "fmd:key:$TASK:legacy-waiting:1" "$CAPTAIN" 880000000000000201)
  assert_contains "$out" "Sent: North" "the legacy waiting click was not filed"
  plugin_py "$home" "$payload" <<'PYTEST' || fail "could not prepare legacy waiting receipt"
import json, sys
from pathlib import Path
import outbox_poster as poster

home, path = Path(sys.argv[1]), Path(sys.argv[3])
progress = json.loads((path.parent / (path.stem + ".progress.json")).read_text())
progress.pop("texts")
progress["decision"].pop("sections", None)
slug, kind, generation = path.stem.rsplit(".", 2)
poster.write_progress(dict(slug=slug, kind=kind, generation=int(generation)), progress, home)
path.unlink(missing_ok=True)
waiting = "⏳ North sent by Dana - waiting for Firstmate to record it"
finalized = path.parent / (path.stem + ".finalized")
finalized.write_text(waiting)
finalized.chmod(0o600)
(home / "discord.json").write_text(json.dumps(dict(content=waiting, earlier="Earlier chunk\n")))
(home / "old-receipt.txt").write_text(waiting)
PYTEST
  home_env "$home" "$ROOT/bin/fm-send.sh" "$TASK" --resolve-key legacy-waiting South \
    >/dev/null 2>&1 || fail "could not record the legacy waiting answer"
  plugin_py "$home" "$payload" <<'PYTEST' || fail "legacy component retry changed its receipt"
import io, json, sys, urllib.error
from pathlib import Path
from unittest.mock import patch
import outbox_poster as poster

home, path = Path(sys.argv[1]), Path(sys.argv[3])
finalized = path.parent / (path.stem + ".finalized")
before = finalized.read_bytes()
settled = path.parent / (path.stem + ".settled.json")
def http(request, timeout):
    body = json.loads(request.data)
    assert "content" not in body
    raise urllib.error.HTTPError(request.full_url, 429, "retry", {}, None)
with patch.object(poster, "_bot_token", return_value="test-token"), patch.object(
    poster.urllib.request, "urlopen", side_effect=http,
):
    assert poster.reconcile_decision_posts(home=home) == []
assert finalized.read_bytes() == before
assert settled.is_file()
assert not path.exists()
PYTEST
  assert_legacy_edit "$home" "$payload" 2 true
  pass "20 legacy waiting receipts retry and re-settle buttons after an answer without text recovery"
}


test_1_buttons_carry_key_and_option_ids_in_the_thread
test_2_standing_click_files_one_request_for_a_worker_key
test_3_captain_call_click_is_a_request_the_board_records
test_4_others_are_not_authorised
test_5_high_risk_options_need_a_confirmation_step
test_6_answered_anywhere_settles_posts_and_clicks_are_no_ops
test_7_stale_posts_are_no_ops
test_8_discuss_and_typed_replies_stay_as_fallbacks
test_9_emit_refuses_unsafe_or_closed_decisions
test_10_real_discord_client_routes_clicks
test_11_unsent_click_releases_its_claim
test_12_topic_thread_posts_take_clicks_there

test_13_published_requests_retry_the_original_identity
test_14_audit_metadata_does_not_match_options

test_15_full_labels_keep_digits_and_overlaps_together

test_16_recommended_option_renders_green_with_a_single_star
test_17_outcome_headers_fit_reserved_and_legacy_posts
test_18_decision_plans_preserve_questions_and_legacy_boundaries
test_19_legacy_buttons_settle_in_every_outcome_state
test_20_legacy_waiting_receipts_need_no_original_or_payload
