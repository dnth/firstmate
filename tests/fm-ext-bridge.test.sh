#!/usr/bin/env bash
# Behavior tests for the sibling local Communication Officer bridge.
#
# Hermetic: no Discord network. The gateway plugin's Discord sender is injected.
# Captain cases 1-12 plus bootstrap activation, transient-send retry,
# mid-delivery refuse, permanent 4xx, and wake-append offer recovery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH="$PYTHON_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ext-bridge)

INTAKE="$ROOT/bin/fm-ext-intake.sh"
EMIT="$ROOT/bin/fm-ext-emit.sh"
LINK="$ROOT/bin/fm-ext-link.sh"
POLL="$ROOT/bin/fm-ext-poll.sh"
OUTBOX="$ROOT/bin/fm-ext-outbox.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
PLUGIN="$ROOT/contrib/hermes-gateway-firstmate-comms"

GUILD=111111111111111111
CHANNEL=222222222222222222
THREAD=333333333333333333
MESSAGE=444444444444444444
AUTHOR=555555555555555555
RID="discord:${GUILD}:${CHANNEL}:${THREAD}:${MESSAGE}"

setup_home() {
  local home=$1 extra_allow=${2-}
  mkdir -p "$home/config"
  : > "$home/config/ext-bridge"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD" > "$home/config/ext-allowlist"
  [ -z "$extra_allow" ] || printf '%s\n' "$extra_allow" >> "$home/config/ext-allowlist"
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

intake_ok() {
  local home=$1 text=$2 message=${3:-$MESSAGE} out rc textfile
  textfile="$home/text.txt"
  write_text "$textfile" "$text"
  out=$(home_env "$home" "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:${THREAD}:${message}" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$THREAD" \
    --message-id "$message" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" \
    --text-file "$textfile")
  rc=$?
  expect_code 0 "$rc" "intake exit"
  printf '%s\n' "$out"
}

slug_of() {
  printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}' \
    || printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

# --- 1. allowlisted intake writes inbox; non-/fm does not -------------------

test_1_allowlisted_intake_and_non_fm() {
  local home slug inbox out
  home="$TMP_ROOT/c1"
  setup_home "$home"
  slug=$(intake_ok "$home" "/fm ship the login fix")
  inbox="$home/state/ext-inbox/${slug}.json"
  assert_present "$inbox" "allowlisted /fm intake must write the inbox"
  assert_grep "$RID" "$inbox" "inbox must keep canonical request_id colons"
  assert_grep "ship the login fix" "$inbox" "inbox must store the request text"
  assert_present "$home/state/ext-context/${slug}.offered.json" "intake must claim the offer"

  out=$(
    GUILD="$GUILD" CHANNEL="$CHANNEL" THREAD="$THREAD" AUTHOR="$AUTHOR" \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
import intake
os.environ["FM_HOME"] = sys.argv[1]
os.environ["FM_ROOT_OVERRIDE"] = sys.argv[2]
os.environ["FM_EXT_BRIDGE"] = "1"
ctx = {
    "platform": "discord",
    "guild_id": os.environ["GUILD"],
    "channel_id": os.environ["CHANNEL"],
    "thread_id": os.environ["THREAD"],
    "message_id": "999999999999999999",
    "user_id": os.environ["AUTHOR"],
}
print("nonfm=" + repr(intake.maybe_intake_from_text("hello from discord", ctx)))
print("fm=" + intake.maybe_intake_from_text("/fm look into the login bug", ctx)[:3])
PY
  )
  assert_contains "$out" "nonfm=None" "non-/fm must not intake"
  assert_contains "$out" "fm=Aye" " /fm must ack"
  [ "$(find "$home/state/ext-inbox" -name '*.json' | wc -l | tr -d ' ')" = 2 ] \
    || fail "exactly one extra inbox for the /fm plugin path"
  pass "1 allowlisted intake writes inbox; non-/fm does not"
}

# --- 2. correlation persists across a new shell -----------------------------

test_2_correlation_persists() {
  local home slug
  home="$TMP_ROOT/c2"
  setup_home "$home"
  slug=$(intake_ok "$home" "file this on the backlog")
  # New shell: only FM_HOME, no leftover functions.
  # shellcheck disable=SC2016 # child expands FM_HOME; slug and rid are positional
  home_env "$home" bash -c '
    set -u
    slug=$1
    rid=$2
    test -f "$FM_HOME/state/ext-inbox/$slug.json" || exit 1
    test -f "$FM_HOME/state/ext-context/$slug.json" || exit 1
    test -f "$FM_HOME/state/ext-context/$slug.offered.json" || exit 1
    grep -F "$rid" "$FM_HOME/state/ext-inbox/$slug.json" >/dev/null
  ' _ "$slug" "$RID" || fail "correlation artifacts must survive a new shell"
  pass "2 correlation persists across a new shell"
}

# --- 3. immediate ack without waiting for Firstmate work --------------------

test_3_immediate_ack() {
  local home out
  home="$TMP_ROOT/c3"
  setup_home "$home"
  out=$(
    GUILD="$GUILD" CHANNEL="$CHANNEL" THREAD="$THREAD" AUTHOR="$AUTHOR" \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$ROOT" <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["PYTHONPATH"])
import intake
os.environ["FM_HOME"] = sys.argv[1]
os.environ["FM_ROOT_OVERRIDE"] = sys.argv[2]
os.environ["FM_EXT_BRIDGE"] = "1"
ctx = {
    "platform": "discord",
    "guild_id": os.environ["GUILD"],
    "channel_id": os.environ["CHANNEL"],
    "thread_id": os.environ["THREAD"],
    "message_id": "444444444444444444",
    "user_id": os.environ["AUTHOR"],
}
start = time.time()
ack = intake.handle_fm_command("summarize the fleet", ctx)
elapsed = time.time() - start
print(ack)
print("elapsed=%.3f" % elapsed)
PY
  )
  assert_contains "$out" "Aye, captain" "slash handler must return a fast ack"
  [ -z "$(find "$home/state/ext-outbox" -name '*.json' 2>/dev/null)" ] \
    || fail "fast ack must not wait on an outbox emit from Firstmate"
  pass "3 immediate ack without waiting for Firstmate work"
}

# --- 4. delayed follow-up after link when inbox is gone ---------------------

test_4_followup_after_inbox_gone() {
  local home slug meta
  home="$TMP_ROOT/c4"
  setup_home "$home"
  slug=$(intake_ok "$home" "ship the redirect fix")
  meta="$home/state/ship-login.meta"
  fm_write_meta "$meta" "window=firstmate:fm-ship-login" "harness=echo" "kind=ship"
  home_env "$home" "$LINK" ship-login "$RID" >/dev/null
  assert_grep "ext_request=$RID" "$meta" "link must record canonical ext_request="
  assert_no_grep "x_request=" "$meta" "link must not write x_request="
  rm -f "$home/state/ext-inbox/${slug}.json"
  write_text "$home/followup.txt" "the redirect fix is ready for review"
  home_env "$home" "$EMIT" --request-id "$RID" --kind followup --generation 1 \
    --text-file "$home/followup.txt" >/dev/null
  assert_present "$home/state/ext-outbox/${slug}.followup.1.json" \
    "follow-up must emit after the inbox is gone"
  pass "4 delayed follow-up after link when inbox is gone"
}

# --- 5. multiple follow-ups; duplicate generation is a no-op ----------------

test_5_multiple_followups_duplicate_generation() {
  local home slug first second
  home="$TMP_ROOT/c5"
  setup_home "$home"
  slug=$(intake_ok "$home" "look into the timeout")
  write_text "$home/a.txt" "investigation started"
  write_text "$home/b.txt" "investigation finished"
  home_env "$home" "$EMIT" --request-id "$RID" --kind followup --generation 1 \
    --text-file "$home/a.txt" >/dev/null
  home_env "$home" "$EMIT" --request-id "$RID" --kind followup --generation 2 \
    --text-file "$home/b.txt" >/dev/null
  first=$(cat "$home/state/ext-outbox/${slug}.followup.1.json")
  home_env "$home" "$EMIT" --request-id "$RID" --kind followup --generation 1 \
    --text-file "$home/b.txt" >/dev/null
  second=$(cat "$home/state/ext-outbox/${slug}.followup.1.json")
  [ "$first" = "$second" ] || fail "duplicate generation must not replace the first payload"
  assert_present "$home/state/ext-outbox/${slug}.followup.2.json" "generation 2 must exist"
  pass "5 multiple follow-ups; duplicate generation is a no-op"
}

# --- 6. idempotent intake + emit --------------------------------------------

test_6_idempotent_intake_and_emit() {
  local home slug1 slug2 wakes
  home="$TMP_ROOT/c6"
  setup_home "$home"
  slug1=$(intake_ok "$home" "add a backlog item")
  wakes=$(grep -c "ext-request $slug1" "$home/state/.wake-queue" || true)
  slug2=$(intake_ok "$home" "add a backlog item")
  [ "$slug1" = "$slug2" ] || fail "same message id must reuse the slug"
  [ "$(grep -c "ext-request $slug1" "$home/state/.wake-queue")" = "$wakes" ] \
    || fail "re-intake must not append a second wake"
  write_text "$home/ack.txt" "on it"
  home_env "$home" "$EMIT" --request-id "$RID" --kind ack --generation 1 \
    --text-file "$home/ack.txt" >/dev/null
  home_env "$home" "$EMIT" --request-id "$RID" --kind ack --generation 1 \
    --text-file "$home/ack.txt" >/dev/null
  [ "$(find "$home/state/ext-outbox" -name "${slug1}.ack.1.json" | wc -l | tr -d ' ')" = 1 ] \
    || fail "re-emit must not duplicate the payload file"
  pass "6 idempotent intake and emit"
}

# --- 7. Hermes restart: unsent outbox + receipt once ------------------------

test_7_unsent_outbox_receipt_once() {
  local home slug sent
  home="$TMP_ROOT/c7"
  setup_home "$home"
  slug=$(intake_ok "$home" "status please")
  write_text "$home/ans.txt" "calm seas"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  sent="$home/sent.log"
  : > "$sent"
  home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" >/dev/null <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": "1"}
print(",".join(outbox_poster.drain_outbox(send=send, home=__import__("pathlib").Path(home))))
PY
  assert_grep "calm seas" "$sent" "unsent outbox must deliver after a new shell"
  assert_present "$home/state/ext-outbox/${slug}.answer.1.receipt.json" "delivery must write a receipt"
  : > "$sent"
  home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" >/dev/null <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write("AGAIN\n")
    return {"ok": True, "discord_message_id": "2"}
print(",".join(outbox_poster.drain_outbox(send=send, home=__import__("pathlib").Path(home))))
PY
  [ ! -s "$sent" ] || fail "receipted outbox must not send again after restart"
  pass "7 Hermes restart: unsent outbox delivers once, receipt sticks"
}

# --- 8. Firstmate restart: inbox+offer; one wake per offer ------------------

test_8_restart_one_wake_per_offer() {
  local home slug wakes poll
  home="$TMP_ROOT/c8"
  setup_home "$home"
  slug=$(intake_ok "$home" "what is underway")
  wakes=$(grep -c "ext-request $slug" "$home/state/.wake-queue")
  [ "$wakes" = 1 ] || fail "first intake must wake once, got $wakes"
  # shellcheck disable=SC2016 # child expands FM_HOME; slug is positional
  home_env "$home" bash -c '
    set -u
    slug=$1
    test -f "$FM_HOME/state/ext-inbox/$slug.json" || exit 1
    test -f "$FM_HOME/state/ext-context/$slug.offered.json" || exit 1
  ' _ "$slug" || fail "inbox and offer must survive a new shell"
  poll=$(home_env "$home" "$POLL")
  [ -z "$poll" ] || fail "poll must stay silent for an already claimed offer (got: $poll)"
  intake_ok "$home" "what is underway" >/dev/null
  [ "$(grep -c "ext-request $slug" "$home/state/.wake-queue")" = 1 ] \
    || fail "restart plus re-intake must not add a second wake"
  pass "8 Firstmate restart: inbox+offer persist; one wake per offer"
}

# --- 9. Discord send retry / mid-send refuse or CAS receipt -----------------

test_9_mid_send_refuse_and_cas_receipt() {
  local home slug rc err
  home="$TMP_ROOT/c9"
  setup_home "$home"
  slug=$(intake_ok "$home" "ping")
  write_text "$home/ans.txt" "pong"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 >/dev/null
  err="$home/mid.err"
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
    >/dev/null 2>"$err"; rc=$?
  expect_code 3 "$rc" "second begin while posting"
  assert_grep "mid-delivery" "$err" "mid-send must refuse"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "emit during mid-delivery"
  write_text "$home/receipt.json" '{"ok":true,"discord_message_id":"9"}'
  home_env "$home" "$OUTBOX" receipt --slug "$slug" --kind answer --generation 1 \
    --receipt-file "$home/receipt.json" >/dev/null
  home_env "$home" "$OUTBOX" receipt --slug "$slug" --kind answer --generation 1 \
    --receipt-file "$home/receipt.json" >/dev/null
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 >/dev/null; rc=$?
  expect_code 1 "$rc" "begin after receipt is idempotent success"
  pass "9 mid-send refuse and CAS receipt"
}

# --- 10. unauthorized / missing allowlist writes no inbox -------------------

test_10_unauthorized_and_missing_allowlist() {
  local home rc err
  home="$TMP_ROOT/c10"
  setup_home "$home"
  printf '%s\n' "${GUILD}:999999999999999999" > "$home/config/ext-allowlist"
  write_text "$home/text.txt" "should not land"
  err="$home/deny.err"
  home_env "$home" "$INTAKE" \
    --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
    --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "unauthorized intake"
  [ ! -d "$home/state/ext-inbox" ] || [ -z "$(ls -A "$home/state/ext-inbox" 2>/dev/null)" ] \
    || fail "unauthorized intake must not write inbox files"
  rm -f "$home/config/ext-allowlist"
  home_env "$home" "$INTAKE" \
    --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
    --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "missing allowlist"
  pass "10 unauthorized and missing allowlist write no inbox"
}

# --- 11. Hermes crewmate spawn string + TUI gating unchanged ----------------

test_11_hermes_tui_launch_gating_unchanged() {
  local spawn_src
  spawn_src=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$spawn_src" "chat --tui" \
    "crewmate Hermes launch template must still be hermes chat --tui"
  assert_contains "$spawn_src" "supports persistent TUI spawns only on tmux and herdr" \
    "hermes crew launch must still be TUI-gated"
  pass "11 Hermes crewmate TUI launch gating unchanged"
}

# --- 12. hermes refused as secondmate ---------------------------------------

test_12_hermes_refused_as_secondmate() {
  local home out rc crew second spawn_src harness_src
  home="$TMP_ROOT/c12"
  mkdir -p "$home/config" "$home/not-a-secondmate"
  printf 'hermes\n' > "$home/config/crew-harness"
  spawn_src=$(cat "$ROOT/bin/fm-spawn.sh")
  harness_src=$(cat "$ROOT/bin/fm-harness.sh")
  assert_contains "$spawn_src" "harness=hermes is verified for crewmates and scouts only" \
    "secondmate hermes must keep the crew-only diagnostic"
  assert_contains "$harness_src" "crew_only_harness" \
    "implicit secondmate resolution must still filter crew-only hermes"
  out=$(home_env "$home" "$SPAWN" hermes-secondmate-x2 "$home/not-a-secondmate" \
    --secondmate --harness hermes 2>&1) || rc=$?
  rc=${rc:-0}
  [ "$rc" -ne 0 ] || fail "explicit hermes secondmate must still be refused"
  assert_contains "$out" "crewmates and scouts only" "spawn must still refuse hermes as a secondmate"
  assert_not_contains "$out" "unknown harness" "crew-only hermes must not look like an unknown adapter"
  crew=$(home_env "$home" "$HARNESS" crew)
  [ "$crew" = hermes ] || fail "crew-harness=hermes must still resolve for crewmates (got '$crew')"
  second=$(home_env "$home" "$HARNESS" secondmate)
  [ "$second" != hermes ] || fail "crew-only hermes must still be filtered from implicit secondmate resolution"
  pass "12 hermes refused as secondmate"
}

# --- 13. transient 5xx/429 clears posting and allows retry ------------------

test_13_transient_http_clears_posting_and_retries() {
  local home slug posting receipt sent out
  home="$TMP_ROOT/c13"
  setup_home "$home"
  slug=$(intake_ok "$home" "retry after discord blip")
  write_text "$home/ans.txt" "retryable answer"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  receipt="$home/state/ext-outbox/${slug}.answer.1.receipt.json"
  sent="$home/sent.log"
  : > "$sent"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import io, os, sys, urllib.error
from email.message import EmailMessage
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(_payload):
    raise urllib.error.HTTPError(
        "https://discord.test/messages", 503, "unavailable",
        EmailMessage(), io.BytesIO(b""),
    )
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "failed" "transient 5xx must return failed"
  assert_absent "$posting" "transient 5xx must delete the posting marker"
  assert_absent "$receipt" "transient 5xx must not write a receipt"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": "13"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "sent" "cleared posting marker must allow a later send"
  assert_grep "retryable answer" "$sent" "retry after transient 5xx must deliver once"
  assert_present "$receipt" "successful retry must write a receipt"

  write_text "$home/ans2.txt" "rate limited then retry"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 2 \
    --text-file "$home/ans2.txt" >/dev/null
  posting="$home/state/ext-outbox/${slug}.answer.2.posting"
  receipt="$home/state/ext-outbox/${slug}.answer.2.receipt.json"
  : > "$sent"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import io, os, sys, urllib.error
from email.message import EmailMessage
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home = sys.argv[1]
os.environ["FM_HOME"] = home
def send(_payload):
    raise urllib.error.HTTPError(
        "https://discord.test/messages", 429, "too many requests",
        EmailMessage(), io.BytesIO(b""),
    )
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "failed" "HTTP 429 must return failed"
  assert_absent "$posting" "HTTP 429 must delete the posting marker"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": "13b"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "sent" "cleared posting marker after 429 must allow a later send"
  assert_grep "rate limited then retry" "$sent" "retry after 429 must deliver once"
  assert_present "$receipt" "successful 429 retry must write a receipt"
  pass "13 transient 5xx/429 clears posting marker and allows retry"
}

# --- 14. mid-delivery still refuses automatic plugin repost -----------------

test_14_mid_delivery_refuses_plugin_repost() {
  local home slug posting sent out
  home="$TMP_ROOT/c14"
  setup_home "$home"
  slug=$(intake_ok "$home" "do not double post")
  write_text "$home/ans.txt" "ambiguous answer"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 >/dev/null
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  sent="$home/sent.log"
  : > "$sent"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" \
    "$home/state/ext-outbox/${slug}.answer.1.json" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent, path = sys.argv[1], sys.argv[2], sys.argv[3]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write("SHOULD_NOT_SEND\n")
    raise RuntimeError("send must not run during mid-delivery")
print(outbox_poster.deliver_one(Path(path), send=send, home=Path(home)))
PY
  )
  assert_contains "$out" "mid-delivery" "plugin must refuse automatic repost while posting has no receipt"
  [ ! -s "$sent" ] || fail "mid-delivery must not invoke send"
  assert_present "$posting" "ambiguous mid-delivery must keep the posting marker"
  pass "14 mid-delivery still refuses automatic plugin repost"
}

# --- 15. wake failure does not leave a silent offered marker ----------------

test_15_wake_failure_does_not_leave_silent_offered() {
  local home slug rc err offered inbox wakes
  home="$TMP_ROOT/c15"
  setup_home "$home"
  slug=$(slug_of "$RID")
  offered="$home/state/ext-context/${slug}.offered.json"
  inbox="$home/state/ext-inbox/${slug}.json"
  write_text "$home/text.txt" "wake me later"
  err="$home/wake.err"
  home_env "$home" env FM_WAKE_QUEUE=/dev/full "$INTAKE" \
    --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
    --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    >/dev/null 2>"$err"; rc=$?
  expect_code 1 "$rc" "intake must fail when the wake cannot be appended"
  assert_grep "could not append the wake" "$err" "intake must name the wake failure"
  assert_present "$inbox" "wake failure must keep the inbox so retry is possible"
  assert_absent "$offered" "wake failure must not leave a claimed offer marker"
  intake_ok "$home" "wake me later" >/dev/null
  assert_present "$offered" "re-intake after wake failure must claim the offer"
  wakes=$(grep -c "ext-request $slug" "$home/state/.wake-queue")
  [ "$wakes" = 1 ] || fail "re-intake after wake failure must wake once, got $wakes"
  pass "15 wake failure does not leave a permanently silent offered marker"
}

# --- 16. ambiguous timeout/URLError keeps posting and refuses retry ---------

test_16_ambiguous_urlerror_keeps_mid_delivery() {
  local home slug posting receipt failed sent out
  home="$TMP_ROOT/c16"
  setup_home "$home"
  slug=$(intake_ok "$home" "maybe it landed")
  write_text "$home/ans.txt" "ambiguous timeout"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  receipt="$home/state/ext-outbox/${slug}.answer.1.receipt.json"
  failed="$home/state/ext-outbox/${slug}.answer.1.failed.json"
  sent="$home/sent.log"
  : > "$sent"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import os, sys, urllib.error
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home = sys.argv[1]
os.environ["FM_HOME"] = home
def send(_payload):
    raise urllib.error.URLError("timed out")
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "mid-delivery" "timeout after possible accept must stay mid-delivery"
  assert_present "$posting" "ambiguous URLError must keep the posting marker"
  assert_absent "$receipt" "ambiguous URLError must not write a receipt"
  assert_absent "$failed" "ambiguous URLError must not write a terminal failed marker"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write("SHOULD_NOT_RETRY\n")
    return {"ok": True, "discord_message_id": "16"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "mid-delivery" "later drain must refuse automatic retry"
  [ ! -s "$sent" ] || fail "ambiguous mid-delivery must not invoke send again"
  assert_present "$posting" "ambiguous mid-delivery must keep the posting marker after the second drain"
  pass "16 ambiguous timeout/URLError keeps mid-delivery and refuses automatic retry"
}

# --- 17. permanent 4xx is terminal failed, not endless retry ----------------

test_17_permanent_4xx_is_terminal_failed() {
  local home slug posting receipt failed sent out pending
  home="$TMP_ROOT/c17"
  setup_home "$home"
  slug=$(intake_ok "$home" "too long for discord")
  write_text "$home/ans.txt" "permanent client error"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  receipt="$home/state/ext-outbox/${slug}.answer.1.receipt.json"
  failed="$home/state/ext-outbox/${slug}.answer.1.failed.json"
  sent="$home/sent.log"
  : > "$sent"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import io, os, sys, urllib.error
from email.message import EmailMessage
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home = sys.argv[1]
os.environ["FM_HOME"] = home
def send(_payload):
    raise urllib.error.HTTPError(
        "https://discord.test/messages", 400, "bad request",
        EmailMessage(), io.BytesIO(b""),
    )
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "terminal-failed" "permanent 4xx must return terminal-failed"
  assert_present "$failed" "permanent 4xx must write a terminal failed marker"
  assert_absent "$posting" "permanent 4xx must not leave a posting marker that looks mid-delivery"
  assert_absent "$receipt" "permanent 4xx must not write a success receipt"
  pending=$(home_env "$home" "$OUTBOX" pending)
  [ -z "$pending" ] || fail "pending must not list a terminal-failed payload, got: $pending"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" \
    "$home/state/ext-outbox/${slug}.answer.1.json" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent, path = sys.argv[1], sys.argv[2], sys.argv[3]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write("SHOULD_NOT_RETRY\n")
    return {"ok": True, "discord_message_id": "17"}
print("drain=" + ",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
print("one=" + outbox_poster.deliver_one(Path(path), send=send, home=Path(home)))
PY
  )
  assert_contains "$out" "drain=" "second drain must run"
  [ "$(printf '%s\n' "$out" | awk -F= '/^drain=/{print $2}')" = "" ] \
    || fail "pending drain must not retry a terminal-failed payload"
  assert_contains "$out" "one=terminal-failed" "direct deliver_one must refuse after terminal 4xx"
  [ ! -s "$sent" ] || fail "permanent 4xx must not invoke send again"
  pass "17 permanent 4xx is terminal failed, not endless retry"
}

# --- bootstrap opt-in -------------------------------------------------------

test_bootstrap_arms_ext_watch_shim() {
  local home out
  home="$TMP_ROOT/boot"
  setup_home "$home"
  out=$(home_env "$home" "$BOOTSTRAP" 2>/dev/null || true)
  assert_contains "$out" "EXT: local bridge on" "bootstrap must announce the local bridge"
  assert_present "$home/state/ext-watch.check.sh" "bootstrap must drop the ext poll shim"
  assert_grep "fm-ext-poll.sh" "$home/state/ext-watch.check.sh" "shim must exec fm-ext-poll.sh"
  home_env "$home" "$BOOTSTRAP" >/dev/null 2>&1 || true
  pass "bootstrap arms the ext-watch identity shim"
}

test_poll_noop_when_inactive() {
  local home out
  home="$TMP_ROOT/poll-off"
  mkdir -p "$home"
  out=$(home_env "$home" "$POLL")
  [ -z "$out" ] || fail "inactive poll must be silent, got: $out"
  pass "poll is a hard no-op when the bridge is off"
}

# Plugin must not dispatch the terminal tool.
test_plugin_has_no_terminal_dispatch() {
  if grep -R -n --include='*.py' 'dispatch_tool(' "$PLUGIN" | grep -v 'never' >/dev/null 2>&1; then
    fail "gateway plugin must not dispatch_tool(terminal)"
  fi
  pass "gateway plugin does not dispatch the terminal tool"
}

export GUILD CHANNEL THREAD AUTHOR
test_1_allowlisted_intake_and_non_fm
test_2_correlation_persists
test_3_immediate_ack
test_4_followup_after_inbox_gone
test_5_multiple_followups_duplicate_generation
test_6_idempotent_intake_and_emit
test_7_unsent_outbox_receipt_once
test_8_restart_one_wake_per_offer
test_9_mid_send_refuse_and_cas_receipt
test_10_unauthorized_and_missing_allowlist
test_11_hermes_tui_launch_gating_unchanged
test_12_hermes_refused_as_secondmate
test_13_transient_http_clears_posting_and_retries
test_14_mid_delivery_refuses_plugin_repost
test_15_wake_failure_does_not_leave_silent_offered
test_16_ambiguous_urlerror_keeps_mid_delivery
test_17_permanent_4xx_is_terminal_failed
test_bootstrap_arms_ext_watch_shim
test_poll_noop_when_inactive
test_plugin_has_no_terminal_dispatch

echo "all fm-ext-bridge tests passed"
