#!/usr/bin/env bash
# Behavior tests for the sibling local Communication Officer bridge.
#
# Hermetic: no Discord network. The gateway plugin's Discord sender is injected.
# Captain cases 1-12 plus bootstrap activation, send-failure classes,
# wake-append offer recovery, Discord reply splitting, exclusive resume
# claim, pre-send inflight release, and stale inflight steal.
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
  # The recommended form: standing authority is author-scoped, so the default
  # fixture models least privilege rather than a guild-wide grant.
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
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
  expect_code 3 "$rc" "unauthorized intake"
  [ ! -d "$home/state/ext-inbox" ] || [ -z "$(ls -A "$home/state/ext-inbox" 2>/dev/null)" ] \
    || fail "unauthorized intake must not write inbox files"
  rm -f "$home/config/ext-allowlist"
  home_env "$home" "$INTAKE" \
    --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
    --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    >/dev/null 2>"$err"; rc=$?
  expect_code 3 "$rc" "missing allowlist"
  pass "10 unauthorized and missing allowlist write no inbox"
}

# --- 11. hermes refused as secondmate ---------------------------------------

test_12_hermes_refused_as_secondmate() {
  local home out rc crew second
  home="$TMP_ROOT/c12"
  mkdir -p "$home/config" "$home/not-a-secondmate"
  printf 'hermes\n' > "$home/config/crew-harness"
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

# --- 16. ambiguous timeout/URLError keeps posting until recovery -------------

test_16_ambiguous_urlerror_keeps_mid_delivery() {
  local home slug posting receipt failed sent out future
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
  future=$(( $(date +%s) + 4000 ))
  out=$(home_env "$home" env FM_EXT_NOW_OVERRIDE="$future" PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
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
  assert_contains "$out" "sent" "later drain past recovery window must retry"
  [ -s "$sent" ] || fail "recovered mid-delivery must invoke send again"
  assert_present "$receipt" "recovered delivery must write a receipt"
  assert_present "$posting" "recovered delivery keeps the posting marker with its receipt"
  pass "16 ambiguous timeout/URLError recovers after the window"
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
  # The terminal failure retires the payload, so a stale path is a no-op rather
  # than an exception that would abort a whole drain pass.
  assert_contains "$out" "one=retired" "direct deliver_one must refuse after terminal 4xx"
  [ ! -s "$sent" ] || fail "permanent 4xx must not invoke send again"
  pass "17 permanent 4xx is terminal failed, not endless retry"
}

# --- 18. text under the Discord budget posts once ---------------------------

test_18_under_limit_is_one_post() {
  local home slug sent out n
  home="$TMP_ROOT/c18"
  setup_home "$home"
  slug=$(intake_ok "$home" "short reply")
  write_text "$home/ans.txt" "Aye, all shipshape."
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  sent="$home/sent.log"
  : > "$sent"
  out=$(home_env "$home" env FM_EXT_DISCORD_REPLY_MAX_CHARS=50 \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": "18"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "sent" "under-limit reply must send"
  n=$(wc -l < "$sent" | tr -d ' ')
  [ "$n" = 1 ] || fail "under-limit reply must be one post, got $n"
  assert_grep "Aye, all shipshape." "$sent" "under-limit post must be the unnumbered text"
  pass "18 text under the Discord budget is one post"
}

# --- 19. text over the budget posts ordered chunks without X pairing --------

test_19_over_limit_posts_chunks_in_order_without_fmx_token() {
  local home slug sent out n first last
  home="$TMP_ROOT/c19"
  setup_home "$home"
  slug=$(intake_ok "$home" "long reply")
  write_text "$home/ans.txt" \
    "The captain has me on a sign-in redirect fix, a docs tidy, and keeping the build green while other jobs run in the background today."
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  sent="$home/sent.log"
  : > "$sent"
  out=$(home_env "$home" env -u FMX_PAIRING_TOKEN -u FMX_RELAY_URL \
    FM_EXT_DISCORD_REPLY_MAX_CHARS=50 PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
os.environ.pop("FMX_PAIRING_TOKEN", None)
os.environ.pop("FMX_RELAY_URL", None)
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": str(payload["chunk_index"])}
print("token=" + os.environ.get("FMX_PAIRING_TOKEN", ""))
print("result=" + ",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "token=" "token probe must print"
  printf '%s\n' "$out" | awk -F= '/^token=/{print $2}' | grep -q . \
    && fail "split must not require FMX_PAIRING_TOKEN"
  assert_contains "$out" "result=sent" "over-limit reply must send after split"
  n=$(wc -l < "$sent" | tr -d ' ')
  [ "$n" -gt 1 ] || fail "over-limit reply must post more than one message, got $n"
  first=$(sed -n '1p' "$sent")
  last=$(tail -n 1 "$sent")
  case "$first" in *" (1/$n)") : ;; *) fail "first chunk must be numbered (1/$n): $first" ;; esac
  case "$last" in *" ($n/$n)") : ;; *) fail "last chunk must be numbered ($n/$n): $last" ;; esac
  awk -v lim=50 'length($0)>lim{exit 1}' "$sent" \
    || fail "every Discord chunk must stay within the 50-character budget"
  assert_present "$home/state/ext-outbox/${slug}.answer.1.receipt.json" \
    "split delivery must write one receipt for the generation"
  pass "19 over-limit text posts ordered chunks without FMX_PAIRING_TOKEN"
}

# --- 20. later-chunk transient failure resumes without reposting ------------

test_20_later_chunk_transient_resumes_without_repost() {
  local home slug sent1 sent2 posting progress inflight out first
  home="$TMP_ROOT/c20"
  setup_home "$home"
  slug=$(intake_ok "$home" "resume split")
  write_text "$home/ans.txt" \
    "The captain has me on a sign-in redirect fix, a docs tidy, and keeping the build green while other jobs run in the background today."
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  sent1="$home/sent1.log"
  sent2="$home/sent2.log"
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  progress="$home/state/ext-outbox/${slug}.answer.1.progress.json"
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  : > "$sent1"
  : > "$sent2"
  out=$(home_env "$home" env FM_EXT_DISCORD_REPLY_MAX_CHARS=50 \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent1" <<'PY'
import io, os, sys, urllib.error
from email.message import EmailMessage
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    if payload["chunk_index"] > 0:
        raise urllib.error.HTTPError(
            "https://discord.test/messages", 503, "unavailable",
            EmailMessage(), io.BytesIO(b""),
        )
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": "20a"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "failed" "later-chunk 503 must return failed"
  assert_present "$posting" "partial success must keep the posting marker for resume"
  assert_present "$progress" "partial success must record chunk progress"
  assert_grep '"posted_count": 1' "$progress" "progress must record the first posted chunk"
  assert_absent "$inflight" "later-chunk 503 must release the exclusive inflight claim so resume can proceed"
  first=$(cat "$sent1")
  [ -n "$first" ] || fail "first chunk must have posted before the later 503"
  out=$(home_env "$home" env FM_EXT_DISCORD_REPLY_MAX_CHARS=50 \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent2" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": "20b"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "sent" "resume after later-chunk 503 must finish the remaining chunks"
  grep -Fqx "$first" "$sent2" && fail "resume must not repost the already sent first chunk"
  [ -s "$sent2" ] || fail "resume must post the remaining chunks"
  pass "20 later-chunk transient failure resumes without reposting earlier chunks"
}

test_20_state_override_preserves_resume_progress() {
  local home state slug first sent out
  home="$TMP_ROOT/c20-state-override"
  state="$home/alternate-state"
  setup_home "$home"
  slug=$(intake_ok "$home" "state override resume")
  write_text "$home/ans.txt" \
    "The captain has me on a sign-in redirect fix, a docs tidy, and keeping the build green while other jobs run today."
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  mkdir -p "$state"
  cp -a "$home/state/ext-outbox" "$state/"
  sent="$home/sent.log"
  : > "$sent"
  out=$(home_env "$home" env FM_STATE_OVERRIDE="$state" FM_EXT_DISCORD_REPLY_MAX_CHARS=50 \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import io, os, sys
from email.message import EmailMessage
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    if payload["chunk_index"] > 0:
        raise __import__("urllib.error", fromlist=["HTTPError"]).HTTPError(
            "https://discord.test/messages", 503, "unavailable", EmailMessage(), io.BytesIO(b""))
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": "20-override-a"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "failed" "state override setup must leave a resumable partial delivery"
  first=$(cat "$sent")
  [ -n "$first" ] || fail "state override setup must post the first chunk"
  out=$(home_env "$home" env FM_STATE_OVERRIDE="$state" FM_EXT_DISCORD_REPLY_MAX_CHARS=50 \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": "20-override-b"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "sent" "state override resume must finish delivery"
  [ "$(grep -Fxc "$first" "$sent")" = 1 ] \
    || fail "state override resume must not repost the first chunk"
  pass "20 state override preserves resume progress"
}

# --- 21. concurrent resume claims: only one poster sends the next chunk -----

_test_21_setup_resumable() {
  local home=$1 slug sent posting progress inflight out
  slug=$(intake_ok "$home" "concurrent resume")
  write_text "$home/ans.txt" \
    "The captain has me on a sign-in redirect fix, a docs tidy, and keeping the build green while other jobs run in the background today."
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  sent="$home/setup-sent.log"
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  progress="$home/state/ext-outbox/${slug}.answer.1.progress.json"
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  : > "$sent"
  out=$(home_env "$home" env FM_EXT_DISCORD_REPLY_MAX_CHARS=50 \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import io, os, sys, urllib.error
from email.message import EmailMessage
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    if payload["chunk_index"] > 0:
        raise urllib.error.HTTPError(
            "https://discord.test/messages", 503, "unavailable",
            EmailMessage(), io.BytesIO(b""),
        )
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": "21a"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "failed" "setup later-chunk 503 must return failed"
  assert_present "$posting" "setup must keep the posting marker for resume"
  assert_present "$progress" "setup must record chunk progress"
  assert_grep '"posted_count": 1' "$progress" "setup must leave posted_count 1"
  assert_absent "$inflight" "setup must leave the inflight claim released"
  printf '%s\n' "$slug" > "$home/setup.slug"
}

test_21_concurrent_resume_exclusive_inflight_claim() {
  local home slug go inflight rc1 rc2 p1 p2 winner losers chunk1
  home="$TMP_ROOT/c21begin"
  setup_home "$home"
  _test_21_setup_resumable "$home"
  slug=$(cat "$home/setup.slug")
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  go="$home/go"
  rm -f "$go" "$home/rc1" "$home/rc2"
  (
    while [ ! -f "$go" ]; do sleep 0.01; done
    home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
      >/dev/null 2>"$home/begin1.err"
    echo $? > "$home/rc1"
  ) &
  p1=$!
  (
    while [ ! -f "$go" ]; do sleep 0.01; done
    home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
      >/dev/null 2>"$home/begin2.err"
    echo $? > "$home/rc2"
  ) &
  p2=$!
  sleep 0.05
  touch "$go"
  wait "$p1" "$p2" || true
  rc1=$(cat "$home/rc1")
  rc2=$(cat "$home/rc2")
  winner=0
  losers=0
  case "$rc1" in
    0) winner=$((winner + 1)) ;;
    3) losers=$((losers + 1)) ;;
    *) fail "concurrent begin child 1 must exit 0 or 3, got $rc1" ;;
  esac
  case "$rc2" in
    0) winner=$((winner + 1)) ;;
    3) losers=$((losers + 1)) ;;
    *) fail "concurrent begin child 2 must exit 0 or 3, got $rc2" ;;
  esac
  [ "$winner" = 1 ] || fail "exactly one concurrent begin must claim the send right (winners=$winner rc1=$rc1 rc2=$rc2)"
  [ "$losers" = 1 ] || fail "the other concurrent begin must be mid-delivery (losers=$losers rc1=$rc1 rc2=$rc2)"
  assert_present "$inflight" "the winning begin must hold the exclusive inflight marker"

  home="$TMP_ROOT/c21send"
  setup_home "$home"
  _test_21_setup_resumable "$home"
  slug=$(cat "$home/setup.slug")
  go="$home/go"
  rm -f "$go" "$home/ready1" "$home/ready2"
  : > "$home/chunks.log"
  home_env "$home" env FM_EXT_DISCORD_REPLY_MAX_CHARS=50 \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$home/chunks.log" "$go" \
    "$home/ready1" "$home/out1" <<'PY' &
import fcntl, os, sys, time
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent, go, ready, out = sys.argv[1:6]
os.environ["FM_HOME"] = home
Path(ready).write_text("1")
while not Path(go).is_file():
    time.sleep(0.01)
def send(payload):
    time.sleep(0.2)
    with open(sent, "a", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.write(str(payload["chunk_index"]) + "\n")
        fcntl.flock(fh, fcntl.LOCK_UN)
    return {"ok": True, "discord_message_id": "21b-%s" % payload["chunk_index"]}
Path(out).write_text(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  p1=$!
  home_env "$home" env FM_EXT_DISCORD_REPLY_MAX_CHARS=50 \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$home/chunks.log" "$go" \
    "$home/ready2" "$home/out2" <<'PY' &
import fcntl, os, sys, time
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent, go, ready, out = sys.argv[1:6]
os.environ["FM_HOME"] = home
Path(ready).write_text("1")
while not Path(go).is_file():
    time.sleep(0.01)
def send(payload):
    time.sleep(0.2)
    with open(sent, "a", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        fh.write(str(payload["chunk_index"]) + "\n")
        fcntl.flock(fh, fcntl.LOCK_UN)
    return {"ok": True, "discord_message_id": "21b-%s" % payload["chunk_index"]}
Path(out).write_text(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  p2=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -f "$home/ready1" ] && [ -f "$home/ready2" ] && break
    sleep 0.05
  done
  [ -f "$home/ready1" ] && [ -f "$home/ready2" ] \
    || fail "both concurrent poster processes must reach the start gate"
  touch "$go"
  wait "$p1" "$p2" || true
  [ -f "$home/out1" ] && [ -f "$home/out2" ] \
    || fail "both concurrent poster processes must finish"
  chunk1=$(grep -c '^1$' "$home/chunks.log" || true)
  [ "$chunk1" = 1 ] || fail "exactly one poster must send the next chunk (chunk 1 count=$chunk1 log=$(tr '\n' ',' < "$home/chunks.log"))"
  grep -q '^0$' "$home/chunks.log" && fail "resume must not repost chunk 0"
  if grep -q . "$home/chunks.log"; then
    sort "$home/chunks.log" | uniq -d | grep -q . \
      && fail "no chunk index may be posted twice (log=$(tr '\n' ',' < "$home/chunks.log"))"
  fi
  pass "21 concurrent resume claims: only one poster sends the next chunk"
}

# --- 22. pre-send failures release inflight; abort drops it first -----------

test_22_presend_release_and_abort_inflight_first() {
  local home slug posting progress inflight payload out rc order inflight_line posting_line
  home="$TMP_ROOT/c22split"
  setup_home "$home"
  _test_21_setup_resumable "$home"
  slug=$(cat "$home/setup.slug")
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  progress="$home/state/ext-outbox/${slug}.answer.1.progress.json"
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  payload="$home/state/ext-outbox/${slug}.answer.1.json"
  out=$(home_env "$home" env FM_EXT_DISCORD_REPLY_MAX_CHARS=50 \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$payload" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, path = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def boom(*_args, **_kwargs):
    raise RuntimeError("forced split failure")
outbox_poster.split_reply = boom
def send(_payload):
    raise AssertionError("send must not run after a pre-send split failure")
print(outbox_poster.deliver_one(Path(path), send=send, home=Path(home)))
PY
  )
  assert_contains "$out" "mid-delivery" "split failure after posted chunks must refuse without sending"
  assert_absent "$inflight" "split failure after posted chunks must release the exclusive inflight claim"
  assert_present "$posting" "split failure after posted chunks must keep posting for resume"
  assert_present "$progress" "split failure after posted chunks must keep progress"
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
    >/dev/null; rc=$?
  expect_code 0 "$rc" "begin after split-failure release"
  assert_present "$inflight" "begin after split-failure release must be able to claim inflight"

  home="$TMP_ROOT/c22mismatch"
  setup_home "$home"
  _test_21_setup_resumable "$home"
  slug=$(cat "$home/setup.slug")
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  progress="$home/state/ext-outbox/${slug}.answer.1.progress.json"
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  payload="$home/state/ext-outbox/${slug}.answer.1.json"
  jq '.total = 99' "$progress" > "$home/bad-progress.json"
  home_env "$home" "$OUTBOX" progress --slug "$slug" --kind answer --generation 1 \
    --progress-file "$home/bad-progress.json" >/dev/null
  out=$(home_env "$home" env FM_EXT_DISCORD_REPLY_MAX_CHARS=50 \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$payload" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, path = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(_payload):
    raise AssertionError("send must not run after a chunk-count mismatch")
print(outbox_poster.deliver_one(Path(path), send=send, home=Path(home)))
PY
  )
  assert_contains "$out" "mid-delivery" "chunk-count mismatch must refuse without sending"
  assert_absent "$inflight" "chunk-count mismatch must release the exclusive inflight claim"
  assert_present "$posting" "chunk-count mismatch must keep posting for resume"
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
    >/dev/null; rc=$?
  expect_code 0 "$rc" "begin after mismatch release"
  assert_present "$inflight" "begin after mismatch release must be able to claim inflight"

  home="$TMP_ROOT/c22abort"
  setup_home "$home"
  _test_21_setup_resumable "$home"
  slug=$(cat "$home/setup.slug")
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  progress="$home/state/ext-outbox/${slug}.answer.1.progress.json"
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 >/dev/null
  assert_present "$inflight" "abort-order fixture must hold inflight before abort"
  rm -f -- "$posting" "$progress"
  assert_absent "$posting" "fixture must drop posting to simulate a mid-abort crash"
  assert_absent "$progress" "fixture must drop progress to simulate a mid-abort crash"
  assert_present "$inflight" "stale inflight must remain until abort runs"
  home_env "$home" "$OUTBOX" abort --slug "$slug" --kind answer --generation 1 >/dev/null
  assert_absent "$inflight" "abort must release leftover inflight even when posting is already gone"
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
    >/dev/null; rc=$?
  expect_code 0 "$rc" "begin after abort cleared leftover inflight"

  home="$TMP_ROOT/c22order"
  setup_home "$home"
  _test_21_setup_resumable "$home"
  slug=$(cat "$home/setup.slug")
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 >/dev/null
  assert_present "$inflight" "abort-order probe must start with a claimed inflight"
  order="$home/abort-order.log"
  (
    # shellcheck source=bin/fm-ext-lib.sh
    . "$ROOT/bin/fm-ext-lib.sh"
    eval "$(declare -f fm_ext_private_artifact_remove | sed '1s/fm_ext_private_artifact_remove/_orig_remove/')"
    fm_ext_private_artifact_remove() {
      printf '%s\n' "$2" >> "$order"
      _orig_remove "$@"
    }
    fm_ext_outbox_abort "$home/state/ext-outbox" "$slug" answer 1
  )
  [ -s "$order" ] || fail "abort must record artifact removals"
  inflight_line=$(grep -n "\.inflight$" "$order" | head -1 | cut -d: -f1)
  posting_line=$(grep -n "\.posting$" "$order" | head -1 | cut -d: -f1)
  [ -n "$inflight_line" ] || fail "abort must remove inflight"
  [ -n "$posting_line" ] || fail "abort must remove posting"
  [ "$inflight_line" -lt "$posting_line" ] \
    || fail "abort must release inflight before removing posting (order=$(tr '\n' ',' < "$order"))"
  pass "22 pre-send failures release inflight; abort drops inflight first"
}

# --- 23. stale inflight steal: dead+TTL only; live concurrent still one -----

_dead_pid() {
  local pid
  true &
  pid=$!
  wait "$pid" || true
  if kill -0 "$pid" 2>/dev/null; then
    fail "could not obtain a dead pid for inflight steal tests"
  fi
  printf '%s\n' "$pid"
}

_rewrite_inflight() {
  local file=$1 pid=$2 recorded_at=$3 tmp
  tmp="${file}.rewrite.$$"
  jq -c --argjson pid "$pid" --argjson recorded_at "$recorded_at" \
    '.pid=$pid | .recorded_at=$recorded_at' "$file" > "$tmp" \
    || fail "could not rewrite inflight claim"
  cat "$tmp" > "$file" || fail "could not replace inflight claim"
  rm -f -- "$tmp"
  chmod 600 "$file" || true
}

test_23_stale_inflight_ttl_and_dead_pid_steal() {
  local home slug inflight posting dead now ttl rc rc1 rc2 p1 p2 go winner losers owner lockbase
  now=100000
  ttl=30
  home="$TMP_ROOT/c23steal"
  setup_home "$home"
  _test_21_setup_resumable "$home"
  slug=$(cat "$home/setup.slug")
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$now" FM_EXT_INFLIGHT_TTL_SECS="$ttl" \
    "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 >/dev/null
  assert_present "$inflight" "begin must record an inflight claim"
  assert_grep '"pid"' "$inflight" "inflight claim must record owner pid"
  owner=$(jq -r '.pid' "$inflight")
  [ "$owner" = "$$" ] || fail "inflight owner pid must be the claiming poster (got $owner want $$)"

  _rewrite_inflight "$inflight" "$owner" "$((now - ttl - 10))"
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$now" FM_EXT_INFLIGHT_TTL_SECS="$ttl" \
    "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
    >/dev/null 2>/dev/null; rc=$?
  expect_code 3 "$rc" "live owner past TTL must still refuse steal"
  assert_present "$inflight" "live-owner refuse must keep the inflight claim"

  dead=$(_dead_pid)
  _rewrite_inflight "$inflight" "$dead" "$now"
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$now" FM_EXT_INFLIGHT_TTL_SECS="$ttl" \
    "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
    >/dev/null 2>/dev/null; rc=$?
  expect_code 3 "$rc" "dead owner inside TTL must refuse steal"

  _rewrite_inflight "$inflight" "$dead" "$((now - ttl - 10))"
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$now" FM_EXT_INFLIGHT_TTL_SECS="$ttl" \
    "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 >/dev/null; rc=$?
  expect_code 0 "$rc" "dead owner past TTL must steal once"
  owner=$(jq -r '.pid' "$inflight")
  [ "$owner" = "$$" ] || fail "stolen inflight must record the new owner pid (got $owner want $$)"
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$now" FM_EXT_INFLIGHT_TTL_SECS="$ttl" \
    "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
    >/dev/null 2>/dev/null; rc=$?
  expect_code 3 "$rc" "after a successful steal, a second begin must refuse"

  home="$TMP_ROOT/c23live"
  setup_home "$home"
  _test_21_setup_resumable "$home"
  slug=$(cat "$home/setup.slug")
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  go="$home/go"
  rm -f "$go" "$home/rc1" "$home/rc2"
  (
    while [ ! -f "$go" ]; do sleep 0.01; done
    home_env "$home" env FM_EXT_INFLIGHT_TTL_SECS=0 \
      "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
      >/dev/null 2>"$home/begin1.err"
    echo $? > "$home/rc1"
    sleep 1
  ) &
  p1=$!
  (
    while [ ! -f "$go" ]; do sleep 0.01; done
    home_env "$home" env FM_EXT_INFLIGHT_TTL_SECS=0 \
      "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
      >/dev/null 2>"$home/begin2.err"
    echo $? > "$home/rc2"
    sleep 1
  ) &
  p2=$!
  sleep 0.05
  touch "$go"
  wait "$p1" "$p2" || true
  rc1=$(cat "$home/rc1")
  rc2=$(cat "$home/rc2")
  winner=0
  losers=0
  case "$rc1" in
    0) winner=$((winner + 1)) ;;
    3) losers=$((losers + 1)) ;;
    *) fail "TTL=0 concurrent begin child 1 must exit 0 or 3, got $rc1" ;;
  esac
  case "$rc2" in
    0) winner=$((winner + 1)) ;;
    3) losers=$((losers + 1)) ;;
    *) fail "TTL=0 concurrent begin child 2 must exit 0 or 3, got $rc2" ;;
  esac
  [ "$winner" = 1 ] || fail "two live concurrent posters must still have one winner under TTL=0 (winners=$winner rc1=$rc1 rc2=$rc2)"
  [ "$losers" = 1 ] || fail "two live concurrent posters must still have one mid-delivery loser under TTL=0 (losers=$losers rc1=$rc1 rc2=$rc2)"
  assert_present "$inflight" "the live winner must still hold inflight"
  assert_present "$posting" "concurrent live refuse must not drop posting"

  home="$TMP_ROOT/c23lock"
  mkdir -p "$home/state/ext-outbox"
  lockbase="probe.answer.1.inflight.lock"
  mkdir "$home/state/ext-outbox/$lockbase"
  if (
    # shellcheck source=bin/fm-ext-lib.sh
    . "$ROOT/bin/fm-ext-lib.sh"
    FM_EXT_INFLIGHT_TTL_SECS=0
    fm_ext_outbox_inflight_steallock_stale "$home/state/ext-outbox" "$lockbase"
  ); then
    fail "a fresh steal-lock must not be reclaimable when claim TTL is 0"
  fi

  home="$TMP_ROOT/c23stealrace"
  setup_home "$home"
  _test_21_setup_resumable "$home"
  slug=$(cat "$home/setup.slug")
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 >/dev/null
  dead=$(_dead_pid)
  _rewrite_inflight "$inflight" "$dead" "$(($(date +%s) - 10))"
  go="$home/go"
  rm -f "$go" "$home/rc1" "$home/rc2"
  (
    while [ ! -f "$go" ]; do sleep 0.01; done
    home_env "$home" env FM_EXT_INFLIGHT_TTL_SECS=0 \
      "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
      >/dev/null 2>"$home/begin1.err"
    echo $? > "$home/rc1"
    sleep 1
  ) &
  p1=$!
  (
    while [ ! -f "$go" ]; do sleep 0.01; done
    home_env "$home" env FM_EXT_INFLIGHT_TTL_SECS=0 \
      "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
      >/dev/null 2>"$home/begin2.err"
    echo $? > "$home/rc2"
    sleep 1
  ) &
  p2=$!
  sleep 0.05
  touch "$go"
  wait "$p1" "$p2" || true
  rc1=$(cat "$home/rc1")
  rc2=$(cat "$home/rc2")
  winner=0
  losers=0
  case "$rc1" in
    0) winner=$((winner + 1)) ;;
    3) losers=$((losers + 1)) ;;
    *) fail "TTL=0 steal-vs-steal child 1 must exit 0 or 3, got $rc1" ;;
  esac
  case "$rc2" in
    0) winner=$((winner + 1)) ;;
    3) losers=$((losers + 1)) ;;
    *) fail "TTL=0 steal-vs-steal child 2 must exit 0 or 3, got $rc2" ;;
  esac
  [ "$winner" = 1 ] || fail "two concurrent TTL=0 stealers must not both win (winners=$winner rc1=$rc1 rc2=$rc2)"
  [ "$losers" = 1 ] || fail "two concurrent TTL=0 stealers must have one mid-delivery loser (losers=$losers rc1=$rc1 rc2=$rc2)"
  pass "23 stale inflight steal requires dead pid and TTL; live concurrent and TTL=0 steal-vs-steal still one winner"
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
  local home out
  home="$TMP_ROOT/plugin-dispatch"
  setup_home "$home"
  out=$(
    GUILD="$GUILD" CHANNEL="$CHANNEL" THREAD="$THREAD" AUTHOR="$AUTHOR" \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
import intake
os.environ["FM_HOME"] = sys.argv[1]
os.environ["FM_ROOT_OVERRIDE"] = sys.argv[2]

dispatch_calls = []
def dispatch_tool(*args, **kwargs):
    dispatch_calls.append((args, kwargs))
    raise AssertionError("terminal dispatch must not be attempted")

ctx = {
    "platform": "discord",
    "guild_id": os.environ["GUILD"],
    "channel_id": os.environ["CHANNEL"],
    "thread_id": os.environ["THREAD"],
    "message_id": "666666666666666666",
    "user_id": os.environ["AUTHOR"],
    "dispatch_tool": dispatch_tool,
}
print(intake.handle_fm_command("dispatch probe", ctx))
print("dispatch_calls=%d" % len(dispatch_calls))
PY
  )
  assert_contains "$out" "Aye, captain" "gateway /fm handler must acknowledge the request"
  assert_contains "$out" "dispatch_calls=0" "gateway /fm handler must not dispatch terminal work"
  pass "gateway /fm handler performs no terminal dispatch"
}

export GUILD CHANNEL THREAD AUTHOR
# --- 24. a wedged ambiguous mid-chunk send is recovered, not stuck forever --

test_24_stuck_middelivery_recovers() {
  local home slug posting receipt failed progress sent out rc future
  home="$TMP_ROOT/c24"
  setup_home "$home"
  slug=$(intake_ok "$home" "recover me")
  write_text "$home/ans.txt" "ambiguous then delivered"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  receipt="$home/state/ext-outbox/${slug}.answer.1.receipt.json"
  failed="$home/state/ext-outbox/${slug}.answer.1.failed.json"
  progress="$home/state/ext-outbox/${slug}.answer.1.progress.json"
  sent="$home/sent.log"
  : > "$sent"

  # Wedge it exactly the way a routine network timeout does.
  out=$(home_env "$home" env FM_EXT_INFLIGHT_OWNER_PID="$$" PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" <<'PY'
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
  assert_contains "$out" "mid-delivery" "ambiguous send must stay mid-delivery"
  assert_present "$posting" "ambiguous send must keep the posting marker"
  [ "$(jq -r '.inflight' "$progress")" = 0 ] \
    || fail "ambiguous send must record the in-flight chunk"

  # Inside the recovery window nothing reopens: the send may still be live.
  home_env "$home" env FM_EXT_INFLIGHT_OWNER_PID="$$" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
    >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "inside the recovery window a wedged generation stays mid-delivery"

  # Past the window the next drain reopens exactly that chunk and delivers it.
  future=$(( $(date +%s) + 4000 ))
  out=$(home_env "$home" env FM_EXT_INFLIGHT_OWNER_PID="$$" FM_EXT_NOW_OVERRIDE="$future" \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$sent" <<'PY'
import os, sys
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home, sent = sys.argv[1], sys.argv[2]
os.environ["FM_HOME"] = home
def send(payload):
    with open(sent, "a", encoding="utf-8") as fh:
        fh.write(payload["text"] + "\n")
    return {"ok": True, "discord_message_id": "24"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "sent" "a wedged generation must eventually be retried"
  [ "$(wc -l < "$sent" | tr -d ' ')" = 1 ] \
    || fail "recovery must re-send exactly the ambiguous chunk once"
  assert_present "$receipt" "recovered delivery must record a receipt"
  assert_absent "$failed" "a recovered delivery must not be marked terminally failed"
  pass "24 a wedged ambiguous mid-chunk send is recovered and delivered"
}

# --- 25. an unrecoverable wedge is failed and surfaced, never silent --------

test_25_stuck_middelivery_surfaces_when_budget_spent() {
  local home slug posting failed out rc future wakes
  home="$TMP_ROOT/c25"
  setup_home "$home"
  slug=$(intake_ok "$home" "never resolves")
  write_text "$home/ans.txt" "permanently ambiguous"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  failed="$home/state/ext-outbox/${slug}.answer.1.failed.json"
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" <<'PY'
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
  assert_contains "$out" "mid-delivery" "ambiguous send must stay mid-delivery"

  # Spend the budget: with no attempts left the next eligible begin must turn
  # the wedge into a terminal, surfaced failure rather than refusing forever.
  future=$(( $(date +%s) + 4000 ))
  out=$(home_env "$home" env FM_EXT_NOW_OVERRIDE="$future" \
    FM_EXT_MIDDELIVERY_RECOVERY_MAX=0 \
    "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 2>&1); rc=$?
  expect_code 5 "$rc" "a spent recovery budget must report recovery-exhausted"
  assert_contains "$out" "recovery-exhausted" "begin must name the exhausted recovery"
  assert_present "$failed" "an unrecoverable wedge must record a terminal failure"
  assert_absent "$posting" "a terminal failure must drop the posting marker"
  assert_grep "mid-delivery-unrecoverable" "$failed" "the failure must record its cause"
  wakes=$(grep -c "ext-delivery-failed $slug" "$home/state/.wake-queue")
  [ "$wakes" = 1 ] \
    || fail "an unrecoverable wedge must wake firstmate once, got $wakes"

  # And it stays terminal instead of retrying forever.
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$future" "$OUTBOX" begin \
    --slug "$slug" --kind answer --generation 1 >/dev/null 2>&1; rc=$?
  expect_code 4 "$rc" "a terminally failed generation must stay terminal"
  pass "25 an unrecoverable wedge is failed and surfaced, never silent"
}

# --- 26. pre-send crash with no progress is recoverable ---------------------

test_26_presend_crash_without_progress_recovers() {
  local home slug posting inflight rc future sent out
  home="$TMP_ROOT/c26-presend"
  setup_home "$home"
  slug=$(intake_ok "$home" "recover before first send")
  write_text "$home/ans.txt" "one clean chunk"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  posting="$home/state/ext-outbox/${slug}.answer.1.posting"
  inflight="$home/state/ext-outbox/${slug}.answer.1.inflight"
  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 >/dev/null
  assert_present "$posting" "pre-send crash fixture must keep posting marker"
  assert_present "$inflight" "pre-send crash fixture must keep inflight claim"
  [ ! -e "$home/state/ext-outbox/${slug}.answer.1.progress.json" ] \
    || fail "pre-send crash fixture must have no progress artifact"

  home_env "$home" "$OUTBOX" begin --slug "$slug" --kind answer --generation 1 \
    >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "pre-send wedge must refuse inside recovery window"

  future=$(( $(date +%s) + 4000 ))
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$future" "$OUTBOX" begin \
    --slug "$slug" --kind answer --generation 1 >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "recovery pass must reopen generation for a fresh claim"
  assert_absent "$posting" "pre-send recovery must remove posting marker"
  assert_absent "$inflight" "pre-send recovery must release inflight claim"

  sent="$home/sent.log"
  : > "$sent"
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
    return {"ok": True, "discord_message_id": "26"}
print(",".join(outbox_poster.drain_outbox(send=send, home=Path(home))))
PY
  )
  assert_contains "$out" "sent" "recovered pre-send generation must deliver"
  [ "$(wc -l < "$sent" | tr -d ' ')" = 1 ] \
    || fail "pre-send recovery must deliver exactly one chunk"
  pass "26 pre-send crash without progress recovers and delivers once"
}

# --- 27. pending stays flat as delivered replies accumulate -----------------

seed_delivered_outbox() {
  # Write <count> already-delivered generations straight into the outbox, the
  # way a home looks after it has answered that many Discord requests.
  local home=$1 slug=$2 count=$3 dir i stem
  dir="$home/state/ext-outbox"
  mkdir -p "$dir"
  chmod 700 "$dir"
  for i in $(seq 1 "$count"); do
    stem="$dir/${slug}.followup.${i}"
    printf '%s\n' "{\"schema_version\":1,\"request_id\":\"$RID\",\"slug\":\"$slug\",\"kind\":\"followup\",\"generation\":$i,\"platform\":\"discord\",\"source\":\"hermes-gateway\",\"guild_id\":\"$GUILD\",\"channel_id\":\"$CHANNEL\",\"thread_id\":\"$THREAD\",\"message_id\":\"$MESSAGE\",\"text\":\"delivered $i\",\"recorded_at\":1}" \
      > "$stem.json"
    printf '{"ok":true,"discord_message_id":"%s"}\n' "$i" > "$stem.receipt.json"
    chmod 600 "$stem.json" "$stem.receipt.json"
  done
}

steady_pending_ms() {
  # Cost of one pending pass after retirement has settled.
  local home=$1 start end
  home_env "$home" "$OUTBOX" pending >/dev/null
  start=$(date +%s%N)
  home_env "$home" "$OUTBOX" pending >/dev/null
  end=$(date +%s%N)
  printf '%s\n' $(( (end - start) / 1000000 ))
}

test_26_pending_stays_flat_as_delivered_grows() {
  local home slug small large listed leftover
  home="$TMP_ROOT/c26-pending"
  setup_home "$home"
  slug=$(intake_ok "$home" "measure me")
  write_text "$home/ans.txt" "still pending"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null

  seed_delivered_outbox "$home" "$slug" 5
  small=$(steady_pending_ms "$home")
  seed_delivered_outbox "$home" "$slug" 60
  large=$(steady_pending_ms "$home")

  # Structural guarantee: delivered payloads are retired, so the scanned set is
  # the pending work alone no matter how many replies were sent before it.
  leftover=$(find "$home/state/ext-outbox" -maxdepth 1 -name '*.followup.*.json' \
    ! -name '*.receipt.json' | wc -l | tr -d ' ')
  [ "$leftover" = 0 ] \
    || fail "delivered payloads must be retired from the scan, $leftover left"
  listed=$(home_env "$home" "$OUTBOX" pending | wc -l | tr -d ' ')
  [ "$listed" = 1 ] \
    || fail "pending must list only genuinely pending work, got $listed"
  assert_present "$home/state/ext-outbox/${slug}.followup.60.receipt.json" \
    "retirement must keep the receipt so a duplicate emit stays idempotent"

  # Measured: 12x the delivered count must not show up as growth. The old
  # full rescan cost ~4 jq spawns per delivered reply on every poll.
  printf 'pending steady-state: 5 delivered=%sms, 60 delivered=%sms\n' "$small" "$large"
  [ "$large" -lt 1500 ] \
    || fail "pending must stay well inside the 2s poll interval, got ${large}ms"
  [ "$large" -lt $(( small * 3 + 400 )) ] \
    || fail "pending cost must stay flat: 5->${small}ms but 60->${large}ms"
  pass "26 pending stays flat as delivered replies accumulate"
}

# --- 27. bridge records expire on the documented retention window -----------

test_27_retention_expires_local_records() {
  local home slug ctx offered stale_ctx stale_offered invalid_ctx invalid_offered
  local symlink_target symlink_inbox future kept_stem
  home="$TMP_ROOT/c27"
  setup_home "$home"
  slug=$(intake_ok "$home" "retain me")
  ctx="$home/state/ext-context/${slug}.json"
  offered="$home/state/ext-context/${slug}.offered.json"

  # A second, older request whose inbox file is already handled and gone.
  stale_ctx="$home/state/ext-context/$(printf 'a%.0s' $(seq 1 64)).json"
  stale_offered="$home/state/ext-context/$(printf 'a%.0s' $(seq 1 64)).offered.json"
  printf '{"request_id":"%s","slug":"x","recorded_at":1}\n' "$RID" > "$stale_ctx"
  printf '{"request_id":"%s","slug":"x","recorded_at":1}\n' "$RID" > "$stale_offered"
  chmod 600 "$stale_ctx" "$stale_offered"

  invalid_ctx="$home/state/ext-context/$(printf 'b%.0s' $(seq 1 64)).json"
  invalid_offered="$home/state/ext-context/$(printf 'b%.0s' $(seq 1 64)).offered.json"
  symlink_target="$home/config/retention-target.json"
  symlink_inbox="$home/state/ext-inbox/$(printf 'b%.0s' $(seq 1 64)).json"
  printf '{"request_id":"%s","slug":"x","recorded_at":1}\n' "$RID" > "$invalid_ctx"
  printf '{"request_id":"%s","slug":"x","recorded_at":1}\n' "$RID" > "$invalid_offered"
  printf '{"not":"an inbox record"}\n' > "$symlink_target"
  mkdir -p "$home/state/ext-inbox"
  ln -s "$symlink_target" "$symlink_inbox"
  chmod 600 "$invalid_ctx" "$invalid_offered" "$symlink_target"

  # A retired outbox generation's leftover marker, and a pending one's.
  kept_stem="$home/state/ext-outbox/${slug}.answer.9"
  mkdir -p "$home/state/ext-outbox"
  chmod 700 "$home/state/ext-outbox"
  printf '{"ok":true}\n' > "$home/state/ext-outbox/${slug}.answer.8.receipt.json"
  printf '{"schema_version":1}\n' > "$kept_stem.json"
  printf '{"ok":true}\n' > "$kept_stem.receipt.json"
  chmod 600 "$home/state/ext-outbox/${slug}.answer.8.receipt.json" \
    "$kept_stem.json" "$kept_stem.receipt.json"

  future=$(( $(date +%s) + 604800 + 86400 ))
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$future" "$POLL" >/dev/null

  assert_absent "$stale_ctx" "context past the retention window must expire"
  assert_absent "$stale_offered" "an offer record with no inbox file must expire"
  assert_absent "$invalid_ctx" "a symlinked inbox must not pin expired context"
  assert_absent "$invalid_offered" "a symlinked inbox must not pin expired offers"
  assert_absent "$home/state/ext-outbox/${slug}.answer.8.receipt.json" \
    "a retired generation's leftover marker must expire"
  assert_present "$offered" \
    "an offer whose request is still unhandled in the inbox must be kept"
  assert_present "$kept_stem.receipt.json" \
    "a generation whose payload is still present must never be pruned"
  assert_present "$ctx" "the live request's destination context must be kept"
  pass "27 bridge records expire on the documented retention window"
}

# --- 28. one allowlist decision: shell and plugin never disagree ------------

shell_allows() {
  # The shell verdict through its real executable interface: 0 admitted, 3 refused.
  local home=$1 message=$2 rc
  write_text "$home/text.txt" "shape probe"
  home_env "$home" "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:${THREAD}:${message}" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$THREAD" \
    --message-id "$message" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) printf 'allow\n' ;;
    3) printf 'deny\n' ;;
    *) printf 'error:%s\n' "$rc" ;;
  esac
}

plugin_allows() {
  local home=$1 message=$2 out
  out=$(
    GUILD="$GUILD" CHANNEL="$CHANNEL" THREAD="$THREAD" AUTHOR="$AUTHOR" \
    MESSAGE_ID="$message" PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
import intake
os.environ["FM_HOME"] = sys.argv[1]
os.environ["FM_ROOT_OVERRIDE"] = sys.argv[2]
ctx = {
    "platform": "discord",
    "guild_id": os.environ["GUILD"],
    "channel_id": os.environ["CHANNEL"],
    "thread_id": os.environ["THREAD"],
    "message_id": os.environ["MESSAGE_ID"],
    "user_id": os.environ["AUTHOR"],
}
reply = intake.handle_fm_command("shape probe", ctx)
print("deny" if "not on the local allowlist" in reply else
      ("allow" if reply.startswith("Aye, captain") else "error:" + reply))
PY
  )
  printf '%s\n' "$out"
}

test_28_allowlist_shell_and_plugin_agree() {
  local home rule shape shell_verdict plugin_verdict message=700000000000000000
  home="$TMP_ROOT/c28"
  setup_home "$home"
  # Every rule shape the grammar can be written in, including the three the two
  # implementations used to disagree on. Discord snowflakes are numeric, so a
  # matching case-variant rule cannot be expressed; these alphabetic rules still
  # exercise both implementations on case-varied input and must deny identically.
  while IFS='|' read -r shape rule; do
    [ -n "$shape" ] || continue
    printf '%s\n' "$rule" > "$home/config/ext-allowlist"
    message=$(( message + 1 ))
    shell_verdict=$(shell_allows "$home" "$message")
    message=$(( message + 1 ))
    plugin_verdict=$(plugin_allows "$home" "$message")
    [ "$shell_verdict" = "$plugin_verdict" ] \
      || fail "allowlist shape $shape disagrees: shell=$shell_verdict plugin=$plugin_verdict"
    case "$shell_verdict" in
      allow|deny) ;;
      *) fail "allowlist shape $shape produced $shell_verdict" ;;
    esac
    printf 'shape %s -> %s\n' "$shape" "$shell_verdict"
  done <<EOF
guild|$GUILD
guild-channel|$GUILD:$CHANNEL
guild-channel-author|$GUILD:$CHANNEL:$AUTHOR
wrong-author|$GUILD:$CHANNEL:999999999999999999
trailing-author-colon|$GUILD:$CHANNEL:
trailing-channel-colon|$GUILD:
four-components|$GUILD:$CHANNEL:$AUTHOR:extra
one-character-off|${GUILD%?}9:$CHANNEL:$AUTHOR
mixed-case-upper|Abc:Def:Ghi
mixed-case-lower|aBC:dEF:gHI
padded|  $GUILD:$CHANNEL:$AUTHOR
commented|# $GUILD:$CHANNEL:$AUTHOR
EOF
  pass "28 shell and plugin reach one identical allowlist decision on every rule shape"
}

# --- 29. least privilege: standing authority needs an author-scoped rule ----

authority_of() {
  local home=$1 message=$2 slug
  slug=$(slug_of "discord:${GUILD}:${CHANNEL}:${THREAD}:${message}")
  jq -r '.authority' "$home/state/ext-inbox/${slug}.json"
}

test_29_least_privilege_authority() {
  local home rc before message=800000000000000000
  home="$TMP_ROOT/c29"
  setup_home "$home"

  printf '%s\n' "$GUILD" > "$home/config/ext-allowlist"
  message=$(( message + 1 ))
  intake_ok "$home" "guild scope" "$message" >/dev/null
  [ "$(authority_of "$home" "$message")" = confirm ] \
    || fail "a guild-wide rule must never grant standing authority"

  printf '%s\n' "$GUILD:$CHANNEL" > "$home/config/ext-allowlist"
  message=$(( message + 1 ))
  intake_ok "$home" "channel scope" "$message" >/dev/null
  [ "$(authority_of "$home" "$message")" = confirm ] \
    || fail "a channel rule must never grant standing authority"

  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
  message=$(( message + 1 ))
  intake_ok "$home" "author scope" "$message" >/dev/null
  [ "$(authority_of "$home" "$message")" = standing ] \
    || fail "an author-scoped rule must grant standing authority"

  # A broad rule alongside the author-scoped one still resolves to standing.
  printf '%s\n%s\n' "$GUILD" "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
  message=$(( message + 1 ))
  intake_ok "$home" "both scopes" "$message" >/dev/null
  [ "$(authority_of "$home" "$message")" = standing ] \
    || fail "the finest-grained matching rule must win"

  # Fail-closed shapes: each must deny outright.
  before=$(find "$home/state/ext-inbox" -name '*.json' | wc -l | tr -d ' ')
  write_text "$home/text.txt" "should not land"
  : > "$home/config/ext-allowlist"
  rc=$(shell_allows "$home" 810000000000000001)
  [ "$rc" = deny ] || fail "an empty allowlist must deny, got $rc"
  printf '# only comments\n\n' > "$home/config/ext-allowlist"
  rc=$(shell_allows "$home" 810000000000000002)
  [ "$rc" = deny ] || fail "a comments-only allowlist must deny, got $rc"
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/real-allowlist"
  rm -f "$home/config/ext-allowlist"
  ln -s "$home/real-allowlist" "$home/config/ext-allowlist"
  rc=$(shell_allows "$home" 810000000000000003)
  [ "$rc" = deny ] || fail "a symlinked allowlist must deny, got $rc"
  rm -f "$home/config/ext-allowlist"
  rc=$(shell_allows "$home" 810000000000000004)
  [ "$rc" = deny ] || fail "a missing allowlist must deny, got $rc"
  [ "$(find "$home/state/ext-inbox" -name '*.json' | wc -l | tr -d ' ')" = "$before" ] \
    || fail "a denied request must never write an inbox file"
  pass "29 standing authority needs an author-scoped rule; broad and broken allowlists deny"
}

try_secret() {
  local home=$1 presented=$2 label=$3 code
  home_env "$home" "$INTAKE" \
    --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
    --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$presented" --text-file "$home/text.txt" \
    >/dev/null 2>&1; code=$?
  expect_code 1 "$code" "$label"
}

# --- 30. the secret gate is closed on every bad shape, not just the good one -

test_30_secret_gate_rejects_every_bad_shape() {
  local home rc secret probe
  home="$TMP_ROOT/c30"
  setup_home "$home"
  secret="$home/config/ext-secret"
  probe="$home/presented"
  write_text "$home/text.txt" "should not land"

  printf 'not-the-secret\n' > "$probe"; chmod 600 "$probe"
  try_secret "$home" "$probe" "a mismatched secret must be refused"

  cp "$secret" "$probe"; chmod 644 "$probe"
  try_secret "$home" "$probe" "a presented secret with mode 0644 must be refused"

  rm -f "$probe"; ln -s "$secret" "$probe"
  try_secret "$home" "$probe" "a symlinked presented secret must be refused"

  rm -f "$probe"; : > "$probe"; chmod 600 "$probe"
  try_secret "$home" "$probe" "an empty presented secret must be refused"

  rm -f "$probe"
  try_secret "$home" "$probe" "a missing presented secret must be refused"

  # The home's own secret is the other half of the same gate.
  cp "$secret" "$probe"; chmod 600 "$probe"
  chmod 644 "$secret"
  try_secret "$home" "$probe" "a home secret with mode 0644 must deactivate the bridge"
  chmod 600 "$secret"
  : > "$secret"
  try_secret "$home" "$probe" "an empty home secret must deactivate the bridge"
  rm -f "$secret"
  try_secret "$home" "$probe" "a missing home secret must deactivate the bridge"

  [ ! -d "$home/state/ext-inbox" ] || [ -z "$(ls -A "$home/state/ext-inbox" 2>/dev/null)" ] \
    || fail "no secret failure may write an inbox file"
  pass "30 the secret gate is closed on mismatched, wrong-mode, symlinked, empty and missing secrets"
}

# --- 31. one opt-in authority: the environment cannot activate a home -------

test_31_optin_is_config_file_only() {
  local home rc out slug
  home="$TMP_ROOT/c31"
  setup_home "$home"
  rm -f "$home/config/ext-bridge"
  write_text "$home/text.txt" "should not land"
  slug=$(slug_of "$RID")

  home_env "$home" "$INTAKE" \
    --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
    --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a home without the opt-in file must refuse intake"

  # The environment used to be able to switch the intake half on by itself,
  # leaving the bootstrap and watcher halves believing the bridge was off.
  home_env "$home" env FM_EXT_BRIDGE=1 "$INTAKE" \
    --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
    --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "the environment must not be able to activate the bridge"

  out=$(plugin_allows "$home" 900000000000000001)
  [ "$out" != allow ] \
    || fail "the gateway plugin must not activate a home that never opted in"
  assert_absent "$home/state/ext-inbox/${slug}.json" \
    "an inactive home must record no request"
  [ ! -s "$home/state/.wake-queue" ] 2>/dev/null \
    || fail "an inactive home must queue no wake"

  # The environment remains a working kill switch for a configured bridge.
  : > "$home/config/ext-bridge"
  home_env "$home" env FM_EXT_BRIDGE=0 "$INTAKE" \
    --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
    --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
    >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "FM_EXT_BRIDGE=0 must still disable a configured bridge"
  intake_ok "$home" "now it works" >/dev/null
  pass "31 config/ext-bridge is the only way to activate; the environment can only disable"
}

# --- 32. the poll never consumes a request without a durable wake -----------

test_32_poll_unclaims_when_wake_fails() {
  local home slug offered out wakes
  home="$TMP_ROOT/c32"
  setup_home "$home"
  slug=$(intake_ok "$home" "poll must not lose me")
  offered="$home/state/ext-context/${slug}.offered.json"
  # A leftover offer is exactly what the poll exists to pick up.
  rm -f "$offered"
  : > "$home/state/.wake-queue"

  out=$(home_env "$home" env FM_WAKE_QUEUE=/dev/full "$POLL" 2>/dev/null)
  [ -z "$out" ] || fail "a poll whose wake cannot be appended must surface nothing"
  assert_absent "$offered" \
    "a poll that could not append its wake must not keep the offer claimed"

  out=$(home_env "$home" "$POLL")
  assert_contains "$out" "ext-request $slug" "the retried poll must surface the request"
  assert_present "$offered" "a successful poll must claim the offer"
  wakes=$(grep -c "ext-request $slug" "$home/state/.wake-queue")
  [ "$wakes" = 1 ] || fail "the poll must make exactly one durable wake, got $wakes"
  out=$(home_env "$home" "$POLL")
  [ -z "$out" ] || fail "an already claimed offer must stay silent"
  pass "32 the poll releases its claim when the wake cannot be made durable"
}

# --- 33. a home that never opts in is untouched -----------------------------

test_33_home_without_optin_is_inert() {
  local home out rc
  home="$TMP_ROOT/c33"
  mkdir -p "$home/config" "$home/state"
  out=$(home_env "$home" "$POLL"); rc=$?
  expect_code 0 "$rc" "the poll must exit 0 in a home with no bridge"
  [ -z "$out" ] || fail "the poll must be silent in a home with no bridge"
  home_env "$home" "$OUTBOX" pending >/dev/null; rc=$?
  expect_code 0 "$rc" "pending must exit 0 in a home with no bridge"
  [ -z "$(find "$home/state" -mindepth 1 2>/dev/null)" ] \
    || fail "a home that never opted in must gain no bridge state"
  pass "33 a home that never opts in gains no bridge state"
}

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
test_12_hermes_refused_as_secondmate
test_13_transient_http_clears_posting_and_retries
test_14_mid_delivery_refuses_plugin_repost
test_15_wake_failure_does_not_leave_silent_offered
test_16_ambiguous_urlerror_keeps_mid_delivery
test_17_permanent_4xx_is_terminal_failed
test_18_under_limit_is_one_post
test_19_over_limit_posts_chunks_in_order_without_fmx_token
test_20_later_chunk_transient_resumes_without_repost
test_20_state_override_preserves_resume_progress
test_21_concurrent_resume_exclusive_inflight_claim
test_22_presend_release_and_abort_inflight_first
test_23_stale_inflight_ttl_and_dead_pid_steal
test_bootstrap_arms_ext_watch_shim
test_poll_noop_when_inactive
test_plugin_has_no_terminal_dispatch
test_24_stuck_middelivery_recovers
test_25_stuck_middelivery_surfaces_when_budget_spent
test_26_presend_crash_without_progress_recovers
test_26_pending_stays_flat_as_delivered_grows
test_27_retention_expires_local_records
test_28_allowlist_shell_and_plugin_agree
test_29_least_privilege_authority
test_30_secret_gate_rejects_every_bad_shape
test_31_optin_is_config_file_only
test_32_poll_unclaims_when_wake_fails
test_33_home_without_optin_is_inert

echo "all fm-ext-bridge tests passed"
