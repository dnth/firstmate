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
# The Discord splitter is Python, which bin/fm-ext-outbox.sh runs through uv the
# same way bin/fm-boat.sh does.
UV_BIN=$(command -v uv) || fail "test needs uv to run the Discord splitter"
UV_DIR=$(dirname "$UV_BIN")
BASE_PATH="$UV_DIR:$BASE_PATH"
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
DRAIN="$ROOT/bin/fm-wake-drain.sh"

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
  local home=$1 text=$2 message=${3:-$MESSAGE} origin=${4:-slash} out rc textfile
  textfile="$home/text.txt"
  write_text "$textfile" "$text"
  out=$(home_env "$home" "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:${THREAD}:${message}" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$THREAD" \
    --message-id "$message" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" \
    --text-file "$textfile" --origin "$origin")
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
  local home slug sent out n
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
  grep -Eq '\([0-9]+/[0-9]+\)' "$sent" \
    && fail "Discord chunks must not carry a (k/n) counter: $(cat "$sent")"
  # The reply is one over-long line, so it splits on word boundaries; no word
  # may be lost or reordered across the chunks.
  [ "$(tr '\n' ' ' < "$sent" | tr -s ' ' | sed 's/ $//')" = "$(cat "$home/ans.txt")" ] \
    || fail "word-boundary split must keep every word: $(cat "$sent")"
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
def changed_splitter(*args, **kwargs):
    raise AssertionError("resuming stored chunks must not invoke a changed splitter")
outbox_poster.split_reply = changed_splitter
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
  jq 'del(.texts)' "$progress" > "$home/legacy-progress.json"
  home_env "$home" "$OUTBOX" progress --slug "$slug" --kind answer --generation 1 \
    --progress-file "$home/legacy-progress.json" >/dev/null
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
  (
    # shellcheck source=bin/fm-ext-lib.sh
    . "$ROOT/bin/fm-ext-lib.sh"
    FM_EXT_INFLIGHT_TTL_SECS=0
    FM_EXT_NOW_OVERRIDE=$(fm_ext_file_mtime "$home/state/ext-outbox/$lockbase") \
      || fail "could not read the steal-lock fixture mtime"
    if fm_ext_outbox_inflight_steallock_stale "$home/state/ext-outbox" "$lockbase"; then
      fail "a fresh steal-lock must not be reclaimable when claim TTL is 0"
    fi
    FM_EXT_NOW_OVERRIDE=$((FM_EXT_NOW_OVERRIDE + 1))
    fm_ext_outbox_inflight_steallock_stale "$home/state/ext-outbox" "$lockbase" \
      || fail "a steal-lock at the one-second floor must be reclaimable when claim TTL is 0"
  ) || fail "steal-lock TTL boundary checks failed"

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

# --- 34. the real sender passes Discord's edge User-Agent rule --------------
#
# Every other outbox case injects its own sender, so nothing exercised the
# request discord_send really builds. Discord's Cloudflare edge answers a
# request whose User-Agent is not a DiscordBot agent with HTTP 403 and the
# plain-text body "error code: 1010" before the API sees it; urllib's default
# agent is refused that way. The stub below applies the same rule, and the real
# sender is pointed at it through the module's API base.

test_34_real_sender_passes_discord_edge_user_agent_rule() {
  local home slug out
  home="$TMP_ROOT/c34"
  setup_home "$home"
  slug=$(intake_ok "$home" "real sender")
  write_text "$home/ans.txt" "Aye, all shipshape."
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  out=$(home_env "$home" env DISCORD_BOT_TOKEN=test-bot-token PYTHONPATH="$PLUGIN" \
    "$PYTHON_BIN" - "$home" <<'PY'
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home = sys.argv[1]
os.environ["FM_HOME"] = home
if not hasattr(outbox_poster, "DISCORD_API_BASE"):
    # Never let this case reach the real Discord API.
    print("result=no-api-base")
    sys.exit(0)
seen = []
class Edge(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        agent = self.headers.get("User-Agent", "")
        seen.append((self.path, agent, self.headers.get("Authorization", ""), json.loads(body)))
        if agent.startswith("DiscordBot ("):
            code, ctype = 200, "application/json"
            reply = json.dumps({"id": "34", "channel_id": "333333333333333333"}).encode()
        else:
            code, ctype, reply = 403, "text/plain; charset=UTF-8", b"error code: 1010\n"
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)
    def log_message(self, *_args):
        pass
server = ThreadingHTTPServer(("127.0.0.1", 0), Edge)
threading.Thread(target=server.serve_forever, daemon=True).start()
outbox_poster.DISCORD_API_BASE = "http://127.0.0.1:%d/api/v10" % server.server_address[1]
result = outbox_poster.drain_outbox(home=Path(home))
server.shutdown()
print("result=" + ",".join(result))
for path, agent, auth, body in seen:
    print("path=" + path)
    print("agent=" + agent)
    print("auth=" + auth)
    print("content=" + body.get("content", ""))
PY
  )
  assert_contains "$out" "result=sent" "the real sender must pass the edge User-Agent rule (got: $out)"
  assert_contains "$out" "path=/api/v10/channels/$THREAD/messages" "the real sender must post to the destination thread"
  assert_contains "$out" "agent=DiscordBot (" "the real sender must identify as a DiscordBot agent"
  assert_contains "$out" "auth=Bot test-bot-token" "the real sender must authenticate as the bot"
  assert_contains "$out" "content=Aye, all shipshape." "the real sender must post the answer text"
  assert_present "$home/state/ext-outbox/${slug}.answer.1.receipt.json" "a passed edge must write a receipt"
  [ ! -e "$home/state/ext-outbox/${slug}.answer.1.failed.json" ] \
    || fail "a passed edge must not record a terminal failure"
  pass "34 the real sender passes Discord's edge User-Agent rule"
}

# --- 35. every request presents its own wake row ----------------------------
#
# The drain dedupes queued rows on kind+key. Bridge rows used to share the
# check key ext-watch.check.sh, so several pending requests presented as one
# line while the acknowledgement consumed them all.

test_35_each_request_presents_its_own_wake_row() {
  local home slug1 slug2 out rows
  home="$TMP_ROOT/c35"
  setup_home "$home"
  slug1=$(intake_ok "$home" "first order" 350000000000000001)
  slug2=$(intake_ok "$home" "second order" 350000000000000002)
  out=$(home_env "$home" env -u FM_SUPERVISION_ACTOR "$DRAIN" 2>/dev/null)
  rows=$(printf '%s\n' "$out" | grep -E '^[0-9]+	[0-9]+	check	' || true)
  assert_contains "$rows" "ext-request $slug1" "the first pending request must present its own wake row"
  assert_contains "$rows" "ext-request $slug2" "the second pending request must present its own wake row"
  pass "35 every pending request presents its own wake row"
}

# --- 36. unanswered requests stay presented until answered ------------------
#
# A drain read through grep -v -E '^[0-9]{10}\s' deletes every raw row, and the
# acknowledgement then consumes the unseen rows, so requests were lost. The
# inbox record is the durable truth, so the drain lists every unanswered
# request in a section a row filter cannot remove and an
# acknowledgement cannot consume.

drain_ack() {  # <home> <drain-stderr>
  local home=$1 err=$2 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "drain printed no acknowledgement command"
  home_env "$home" env -u FM_SUPERVISION_ACTOR "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1 || fail "acknowledgement must succeed"
}

test_36_unanswered_requests_survive_filtered_drains_until_answered() {
  local home slug out
  home="$TMP_ROOT/c36"
  setup_home "$home"
  slug=$(intake_ok "$home" "what is waiting on me" 360000000000000001)
  out=$(home_env "$home" env -u FM_SUPERVISION_ACTOR "$DRAIN" 2>"$home/drain.err" \
    | grep -v -E '^[0-9]{10}\s')
  assert_contains "$out" "EXT REQUESTS AWAITING ANSWER" "a row-filtered drain must still present the request section"
  assert_contains "$out" "ext-request $slug" "a row-filtered drain must still name the pending request"
  drain_ack "$home" "$home/drain.err"
  out=$(home_env "$home" env -u FM_SUPERVISION_ACTOR "$DRAIN" 2>/dev/null)
  assert_contains "$out" "ext-request $slug" "an acknowledged but unanswered request must still be presented"
  mv "$home/config/ext-bridge" "$home/config/ext-bridge.off"
  out=$(home_env "$home" env -u FM_SUPERVISION_ACTOR "$DRAIN" 2>/dev/null)
  case "$out" in
    *"EXT REQUESTS AWAITING ANSWER"*) fail "a bridge that is switched off must not present requests" ;;
  esac
  mv "$home/config/ext-bridge.off" "$home/config/ext-bridge"
  # ext-respond removes the inbox record once the request is answered.
  rm -f "$home/state/ext-inbox/$slug.json"
  out=$(home_env "$home" env -u FM_SUPERVISION_ACTOR "$DRAIN" 2>/dev/null)
  case "$out" in
    *"EXT REQUESTS AWAITING ANSWER"*|*"ext-request $slug"*) fail "an answered request must leave the drain" ;;
  esac
  pass "36 unanswered requests survive filtered and acknowledged drains until answered"
}

test_37_every_pending_request_is_listed_without_limit() {
  local home slug out message i
  local slugs=()
  home="$TMP_ROOT/c37"
  setup_home "$home"
  for ((i = 1; i <= 22; i++)); do
    printf -v message '370000000000000%03d' "$i"
    slug=$(intake_ok "$home" "pending request $i" "$message")
    slugs+=("$slug")
  done
  out=$(home_env "$home" env -u FM_SUPERVISION_ACTOR "$DRAIN" 2>"$home/drain.err" \
    | grep -v -E '^[0-9]{10}\s')
  assert_contains "$out" "EXT REQUESTS AWAITING ANSWER" "the drain must present the request section"
  for slug in "${slugs[@]}"; do
    printf '%s\n' "$out" | grep -Fx "ext-request $slug" >/dev/null \
      || fail "every pending request must have a plain ext-request line: $slug"
  done
  drain_ack "$home" "$home/drain.err"
  out=$(home_env "$home" env -u FM_SUPERVISION_ACTOR "$DRAIN" 2>/dev/null)
  for slug in "${slugs[@]}"; do
    printf '%s\n' "$out" | grep -Fx "ext-request $slug" >/dev/null \
      || fail "every unanswered request must remain listed after acknowledgement: $slug"
  done
  pass "37 every pending request is listed without a limit"
}

# --- 38. delivery reactions follow the reply outcome -------------------------
#
# A request that arrived as an ordinary Discord message gets a check mark once
# its answer or final reply has posted and a warning when a reply fails for
# good. An ack is not the answer, and a slash command is an interaction with no
# message to react to.

test_38_delivery_reactions_follow_the_reply_outcome() {
  local home out rid2 rid3 n
  home="$TMP_ROOT/c38"
  setup_home "$home"
  rid2="discord:${GUILD}:${CHANNEL}:${THREAD}:380000000000000002"
  rid3="discord:${GUILD}:${CHANNEL}:${THREAD}:380000000000000003"
  intake_ok "$home" "status please" "$MESSAGE" message >/dev/null
  intake_ok "$home" "slash status" 380000000000000002 >/dev/null
  intake_ok "$home" "doomed status" 380000000000000003 message >/dev/null
  write_text "$home/ack.txt" "On it."
  write_text "$home/ans.txt" "All shipshape."
  home_env "$home" "$EMIT" --request-id "$RID" --kind ack --generation 1 \
    --text-file "$home/ack.txt" >/dev/null
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  home_env "$home" "$EMIT" --request-id "$rid2" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  home_env "$home" "$EMIT" --request-id "$rid3" --kind final --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" <<'PY'
import io, os, sys, urllib.error
from email.message import EmailMessage
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home = sys.argv[1]
os.environ["FM_HOME"] = home
names = {outbox_poster.REACT_SEEN: "seen", outbox_poster.REACT_DONE: "done",
         outbox_poster.REACT_FAILED: "failed"}
def send(payload):
    if payload["message_id"] == "380000000000000003":
        raise urllib.error.HTTPError("https://discord.test/messages", 403, "forbidden",
                                     EmailMessage(), io.BytesIO(b""))
    return {"ok": True, "discord_message_id": "38" + payload["kind"]}
def react(channel, message, emoji):
    print("react=%s/%s/%s" % (channel, message, names.get(emoji, emoji)))
results = outbox_poster.drain_outbox(send=send, home=Path(home), react=react)
print("results=" + ",".join(sorted(results)))
PY
  )
  assert_contains "$out" "react=$THREAD/$MESSAGE/done" "a posted answer must mark the captain's message done"
  assert_contains "$out" "react=$THREAD/380000000000000003/failed" \
    "a terminal post failure must mark the captain's message with a warning"
  n=$(printf '%s\n' "$out" | grep -c '^react=')
  [ "$n" = 2 ] || fail "only the posted answer and the terminal failure may react, got $n: $out"
  assert_contains "$out" "results=sent,sent,sent,terminal-failed" "every reply must still reach its outcome"
  pass "38 delivery reactions follow the reply outcome"
}

# --- 39. a failed reaction never blocks or repeats a reply -------------------

test_39_reaction_failure_never_blocks_or_repeats_a_reply() {
  local home slug sent out n
  home="$TMP_ROOT/c39"
  setup_home "$home"
  slug=$(intake_ok "$home" "status please" "$MESSAGE" message)
  write_text "$home/ans.txt" "All shipshape."
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
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
    return {"ok": True, "discord_message_id": "39"}
def react(*_args):
    raise RuntimeError("discord refused the reaction")
print("first=" + ",".join(outbox_poster.drain_outbox(send=send, home=Path(home), react=react)))
print("second=" + ",".join(outbox_poster.drain_outbox(send=send, home=Path(home), react=react)))
PY
  )
  assert_contains "$out" "first=sent" "a failed reaction must not fail the reply"
  [ "$(printf '%s\n' "$out" | sed -n 's/^second=//p')" = "" ] \
    || fail "a failed reaction must not leave the reply pending: $out"
  n=$(wc -l < "$sent" | tr -d ' ')
  [ "$n" = 1 ] || fail "a failed reaction must not repeat the reply, posted $n times"
  assert_present "$home/state/ext-outbox/${slug}.answer.1.receipt.json" "the reply must still be receipted"
  pass "39 a failed reaction never blocks or repeats a reply"
}

# --- 40. a reply stuck past its recovery budget warns ------------------------

test_40_recovery_exhausted_reply_warns() {
  local home out
  home="$TMP_ROOT/c40"
  setup_home "$home"
  intake_ok "$home" "never resolves" "$MESSAGE" message >/dev/null
  write_text "$home/ans.txt" "permanently ambiguous"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  out=$(home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" <<'PY'
import os, sys, time, urllib.error
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home = sys.argv[1]
os.environ["FM_HOME"] = home
reactions = []
def send(_payload):
    raise urllib.error.URLError("timed out")
def react(_channel, _message, emoji):
    reactions.append("failed" if emoji == outbox_poster.REACT_FAILED else emoji)
print("first=" + ",".join(outbox_poster.drain_outbox(send=send, home=Path(home), react=react)))
print("after-first=" + ",".join(reactions))
os.environ["FM_EXT_NOW_OVERRIDE"] = str(int(time.time()) + 4000)
os.environ["FM_EXT_MIDDELIVERY_RECOVERY_MAX"] = "0"
print("second=" + ",".join(outbox_poster.drain_outbox(send=send, home=Path(home), react=react)))
print("reactions=" + ",".join(reactions))
PY
  )
  assert_contains "$out" "first=mid-delivery" "an ambiguous send must stay mid-delivery"
  assert_contains "$out" "after-first=" "an ambiguous send is not yet a failure"
  [ "$(printf '%s\n' "$out" | sed -n 's/^after-first=//p')" = "" ] \
    || fail "an ambiguous send must not warn before its recovery budget is spent: $out"
  assert_contains "$out" "second=recovery-exhausted" "a spent recovery budget must fail the reply"
  assert_contains "$out" "reactions=failed" "a reply failed after recovery must warn exactly once"
  pass "40 a reply stuck past its recovery budget warns on the captain's message"
}

# --- 41. the real reaction goes through Discord's REST edge -----------------

test_41_real_reaction_uses_discord_rest_edge() {
  local home out
  home="$TMP_ROOT/c41"
  setup_home "$home"
  intake_ok "$home" "real reaction" "$MESSAGE" message >/dev/null
  write_text "$home/ans.txt" "All shipshape."
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  out=$(home_env "$home" env DISCORD_BOT_TOKEN=test-bot-token PYTHONPATH="$PLUGIN" \
    "$PYTHON_BIN" - "$home" <<'PY'
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster
home = sys.argv[1]
os.environ["FM_HOME"] = home
seen = []
class Edge(BaseHTTPRequestHandler):
    def _answer(self, ok_code, ok_body):
        agent = self.headers.get("User-Agent", "")
        seen.append((self.command, self.path, agent, self.headers.get("Authorization", "")))
        if agent.startswith("DiscordBot ("):
            code, body = ok_code, ok_body
        else:
            code, body = 403, b"error code: 1010\n"
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self._answer(200, json.dumps({"id": "41", "channel_id": "333333333333333333"}).encode())
    def do_PUT(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self._answer(204, b"")
    def log_message(self, *_args):
        pass
server = ThreadingHTTPServer(("127.0.0.1", 0), Edge)
threading.Thread(target=server.serve_forever, daemon=True).start()
outbox_poster.DISCORD_API_BASE = "http://127.0.0.1:%d/api/v10" % server.server_address[1]
print("result=" + ",".join(outbox_poster.drain_outbox(home=Path(home))))
server.shutdown()
for command, path, agent, auth in seen:
    print("%s %s agent=%s auth=%s" % (command, path, agent, auth))
PY
  )
  assert_contains "$out" "result=sent" "the real sender must post the answer (got: $out)"
  assert_contains "$out" "PUT /api/v10/channels/$THREAD/messages/$MESSAGE/reactions/%E2%9C%85/@me agent=DiscordBot (" \
    "the real reaction must PUT the check mark on the captain's message as a DiscordBot agent"
  assert_contains "$out" "auth=Bot test-bot-token" "the real reaction must authenticate as the bot"
  pass "41 the real reaction goes through Discord's REST edge"
}

# --- 42. intake records origin and a bounded reply context ------------------

intake_reply() {  # <home> <message> <reply-text-file> [extra intake args...]
  local home=$1 message=$2 reply_file=$3
  shift 3
  home_env "$home" "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:${THREAD}:${message}" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$THREAD" \
    --message-id "$message" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" \
    --text-file "$home/text.txt" --origin message \
    --reply-to-message-id 420000000000000900 --reply-to-request-id "$RID" \
    --reply-to-text-file "$reply_file" "$@"
}

test_42_intake_records_origin_and_bounded_reply_context() {
  local home rc slug inbox i
  home="$TMP_ROOT/c42"
  setup_home "$home"
  write_text "$home/text.txt" "yes"
  home_env "$home" "$INTAKE" --request-id "$RID" --guild-id "$GUILD" \
    --channel-id "$CHANNEL" --thread-id "$THREAD" --message-id "$MESSAGE" \
    --author "$AUTHOR" --secret-file "$home/config/ext-secret" \
    --text-file "$home/text.txt" --origin bogus >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown origin must be refused"
  home_env "$home" "$INTAKE" --request-id "$RID" --guild-id "$GUILD" \
    --channel-id "$CHANNEL" --thread-id "$THREAD" --message-id "$MESSAGE" \
    --author "$AUTHOR" --secret-file "$home/config/ext-secret" \
    --text-file "$home/text.txt" --reply-to-text-file "$home/text.txt" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "reply text without a replied-to message must be refused"
  [ ! -d "$home/state/ext-inbox" ] || [ -z "$(ls -A "$home/state/ext-inbox")" ] \
    || fail "a refused intake must record nothing"

  : > "$home/q1000.txt"
  for ((i = 0; i < 1000; i++)); do printf '\303\251' >> "$home/q1000.txt"; done
  cp "$home/q1000.txt" "$home/q1001.txt"
  printf 'Z' >> "$home/q1001.txt"
  slug=$(intake_reply "$home" 420000000000000001 "$home/q1000.txt") || fail "a reply request must be recorded"
  inbox="$home/state/ext-inbox/$slug.json"
  [ "$(jq -r '.origin' "$inbox")" = message ] || fail "a message request must record its origin"
  [ "$(jq -r '.reply_to.message_id + " " + .reply_to.request_id' "$inbox")" = "420000000000000900 $RID" ] \
    || fail "the reply context must name the replied-to message and its request"
  [ "$(jq -r '.reply_to.text | length' "$inbox")" = 1000 ] \
    || fail "a 1000-character replied-to text must be kept whole"
  [ "$(jq -r '.reply_to.text | endswith("\u2026")' "$inbox")" = false ] \
    || fail "a kept-whole text must not be marked as cut"
  slug=$(intake_reply "$home" 420000000000000002 "$home/q1001.txt") || fail "a long reply request must be recorded"
  inbox="$home/state/ext-inbox/$slug.json"
  [ "$(jq -r '.reply_to.text | length' "$inbox")" = 1001 ] \
    || fail "a longer replied-to text must be cut to 1000 characters plus the cut mark"
  [ "$(jq -r '.reply_to.text | endswith("\u00e9\u2026")' "$inbox")" = true ] \
    || fail "the cut must keep the first 1000 characters and mark the cut"

  slug=$(intake_ok "$home" "plain slash request" 420000000000000003)
  [ "$(jq -r '.origin + " " + (has("reply_to") | tostring)' "$home/state/ext-inbox/$slug.json")" = "slash false" ] \
    || fail "a slash request must record its origin and no reply context"
  [ "$(jq -r '.origin' "$home/state/ext-context/$slug.json")" = slash ] \
    || fail "the destination context must carry the origin for the poster"
  pass "42 intake records origin and a bounded reply context"
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
test_34_real_sender_passes_discord_edge_user_agent_rule
test_35_each_request_presents_its_own_wake_row
test_36_unanswered_requests_survive_filtered_drains_until_answered
test_37_every_pending_request_is_listed_without_limit
test_38_delivery_reactions_follow_the_reply_outcome
test_39_reaction_failure_never_blocks_or_repeats_a_reply
test_40_recovery_exhausted_reply_warns
test_41_real_reaction_uses_discord_rest_edge
test_42_intake_records_origin_and_bounded_reply_context

# --- 43. cached attachments are copied into a private per-request folder ---

test_43_intake_copies_cached_attachments() {
  local home slug inbox dir mode
  home="$TMP_ROOT/c43 Hermes Profile"
  setup_home "$home"
  mkdir -p "$home/cache/images" "$home/cache/documents"
  printf 'IMGDATA' > "$home/cache/images/pic.png"
  printf 'DOCDATA' > "$home/cache/documents/notes.txt"
  write_text "$home/text.txt" "see the attached files"
  "$PYTHON_BIN" - "$home/cache/images/pic.png" "$home/cache/documents/notes.txt" "$home/manifest.json" <<'PY'
import json, sys
pic, doc, out = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump([
  {"path": pic, "media_type": "image/png", "name": "pic.png"},
  {"path": doc, "media_type": "", "name": "notes.txt"},
], open(out, "w"))
PY
  slug=$(home_env "$home" env HERMES_HOME="$home" \
    "$INTAKE" \
    --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
    --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" \
    --text-file "$home/text.txt" --attachment-manifest "$home/manifest.json")
  inbox="$home/state/ext-inbox/${slug}.json"
  assert_present "$inbox" "an attachment request must write the inbox"
  dir="$home/state/ext-attachments/${slug}"
  [ -d "$dir" ] || fail "copied attachments must live in a per-request folder"
  if [ "$(uname)" = Darwin ]; then mode=$(stat -f %Lp "$dir"); else mode=$(stat -c %a "$dir"); fi
  [ "$mode" = 700 ] || fail "the attachment folder must be mode 0700, got $mode"
  [ "$(jq -r '.attachments | length' "$inbox")" = 2 ] \
    || fail "the inbox must list each copied file"
  [ "$(jq -r '.attachments[0].name' "$inbox")" = pic.png ] \
    || fail "the inbox must record the attachment name"
  [ "$(jq -r '.attachments[0].media_type' "$inbox")" = image/png ] \
    || fail "the inbox must record the media type"
  [ "$(jq -r '.attachments[0].bytes' "$inbox")" = 7 ] \
    || fail "the inbox must record the byte count"
  case "$(jq -r '.attachments[0].path' "$inbox")" in
    "$dir"/*) ;;
    *) fail "the inbox path must point inside the per-request folder" ;;
  esac
  [ "$(jq -r '.attachments[1].media_type' "$inbox")" = application/octet-stream ] \
    || fail "an unknown media type must be kept as application/octet-stream"
  [ "$(jq -r '.skipped_attachments | length' "$inbox")" = 0 ] \
    || fail "a clean manifest must skip nothing"
  if [ "$(uname)" = Darwin ]; then fmode=$(stat -f %Lp "$dir/0-pic.png"); else fmode=$(stat -c %a "$dir/0-pic.png"); fi
  [ "$fmode" = 600 ] || fail "a copied attachment must be mode 0600"
  cmp -s "$home/cache/images/pic.png" "$dir/0-pic.png" \
    || fail "the copied bytes must match the cached file"
  pass "43 cached attachments are copied into a private per-request folder"
}

# --- 44. oversize, over-count, uncached, symlink, and unsafe names skip -----

test_44_intake_skips_uncopyable_attachments() {
  local home slug inbox dir want skipped_name skipped_reason
  home="$TMP_ROOT/c44"
  setup_home "$home"
  mkdir -p "$home/cache/images" "$home/evil-real"
  printf '1234567' > "$home/cache/images/ok.png"
  printf '0123456789abcdef0123456789abcdef' > "$home/cache/images/big.png"
  printf 'EVIL' > "$home/evil-real/evil.png"
  ln -s "$home/evil-real" "$home/cache/images/evildir"
  ln -s "$home/cache/images/ok.png" "$home/cache/images/link.png"
  write_text "$home/text.txt" "mixed attachments"
  "$PYTHON_BIN" - "$home/cache/images/ok.png" "$home/cache/images/link.png" \
    "$home/cache/images/evildir/evil.png" "$home/cache/images/missing.png" \
    "$home/cache/images/big.png" "$home/manifest.json" <<'PY'
import json, sys
ok, link, evildir, missing, big, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
json.dump([
  {"path": ok, "media_type": "image/png", "name": "ok.png"},
  {"path": "https://cdn.discordapp.com/x.png", "media_type": "image/png", "name": "cdn.png"},
  {"path": link, "media_type": "image/png", "name": "link.png"},
  {"path": evildir, "media_type": "image/png", "name": "evil.png"},
  {"path": missing, "media_type": "image/png", "name": "missing.png"},
  {"path": ok, "media_type": "image/png", "name": "../evil2.png"},
  {"path": big, "media_type": "image/png", "name": "big.png"},
  {"path": ok, "media_type": "image/png", "name": "tiny.png"},
  {"path": ok, "media_type": "image/png", "name": "extra.png"},
], open(out, "w"))
PY
  slug=$(home_env "$home" env HERMES_HOME="$home" \
    FM_EXT_ATTACHMENT_MAX_BYTES=8 FM_EXT_ATTACHMENT_MAX_COUNT=2 \
    "$INTAKE" \
    --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
    --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" \
    --text-file "$home/text.txt" --attachment-manifest "$home/manifest.json")
  inbox="$home/state/ext-inbox/${slug}.json"
  dir="$home/state/ext-attachments/${slug}"
  [ "$(jq -r '.attachments | length' "$inbox")" = 2 ] \
    || fail "two files fit the count cap"
  [ "$(jq -r '.attachments[0].name' "$inbox")" = ok.png ] \
    || fail "the kept file must be the first cache entry"
  for want in "cdn.png uncached" "link.png not-found" "evil.png not-found" \
      "missing.png not-found" "../evil2.png unsafe-name" "big.png too-large" "extra.png over-count"; do
    read -r skipped_name skipped_reason <<< "$want"
    [ "$(jq -r --arg n "$skipped_name" '.skipped_attachments[] | select(.name == $n) | .reason' "$inbox")" = "$skipped_reason" ] \
      || fail "skipped $skipped_name must be listed as $skipped_reason, got: $(jq -c '.skipped_attachments' "$inbox")"
  done
  [ "$(jq -r '.attachments[1].name' "$inbox")" = tiny.png ] \
    || fail "the second kept file must be tiny.png"
  [ "$(find "$dir" -type f | wc -l | tr -d ' ')" = 2 ] \
    || fail "only the kept files may be copied"
  pass "44 oversize, over-count, uncached, symlink, and unsafe names are skipped and listed"
}

# --- 45. allowlist, text-only, attachment-only, and retention ---------------

test_45_attachment_admission_and_retention() {
  local home slug inbox rc future dir denied_msg
  home="$TMP_ROOT/c45"
  setup_home "$home"
  mkdir -p "$home/cache/images"
  printf 'IMG' > "$home/cache/images/a.png"
  "$PYTHON_BIN" - "$home/cache/images/a.png" "$home/manifest.json" <<'PY'
import json, sys
json.dump([{"path": sys.argv[1], "media_type": "image/png", "name": "a.png"}], open(sys.argv[2], "w"))
PY
  # A non-allowlisted author copies nothing and records nothing.
  denied_msg=700000000000000001
  write_text "$home/text.txt" "denied with a file"
  home_env "$home" env HERMES_HOME="$home" \
    "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:${THREAD}:${denied_msg}" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$THREAD" \
    --message-id "$denied_msg" --author 999999999999999999 \
    --secret-file "$home/config/ext-secret" \
    --text-file "$home/text.txt" --attachment-manifest "$home/manifest.json" \
    >/dev/null 2>&1; rc=$?
  expect_code 3 "$rc" "a denied author with attachments must be refused"
  [ -z "$(find "$home/state" -mindepth 1 2>/dev/null)" ] \
    || fail "a refused intake must copy no file and record nothing"
  # A text-only request is byte-for-byte the original shape: no attachment fields.
  write_text "$home/text.txt" "plain hello"
  slug=$(home_env "$home" env FM_EXT_NOW_OVERRIDE=1700000000 \
    "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:${THREAD}:700000000000000002" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$THREAD" \
    --message-id 700000000000000002 --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" \
    --text-file "$home/text.txt")
  inbox="$home/state/ext-inbox/$slug.json"
  jq -e 'has("attachments") | not' "$inbox" >/dev/null \
    || fail "a text-only request must not gain an attachments field"
  jq -e 'has("skipped_attachments") | not' "$inbox" >/dev/null \
    || fail "a text-only request must not gain a skipped_attachments field"
  "$PYTHON_BIN" - "$inbox" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
record.pop("recorded_at", None)
got = json.dumps(record, sort_keys=True)
want = json.dumps({
  "schema_version": 1,
  "request_id": "discord:111111111111111111:222222222222222222:333333333333333333:700000000000000002",
  "slug": record["slug"],
  "platform": "discord",
  "source": "hermes-gateway",
  "guild_id": "111111111111111111",
  "channel_id": "222222222222222222",
  "thread_id": "333333333333333333",
  "message_id": "700000000000000002",
  "author": "555555555555555555",
  "authority": "standing",
  "origin": "slash",
  "text": "plain hello",
}, sort_keys=True)
assert got == want, "text-only inbox differs from the original shape: " + got
PY
  # An attachment-only message with empty text still becomes a request.
  : > "$home/text.txt"
  slug=$(home_env "$home" env HERMES_HOME="$home" \
    "$INTAKE" \
    --request-id "discord:${GUILD}:${CHANNEL}:${THREAD}:700000000000000003" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$THREAD" \
    --message-id 700000000000000003 --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" \
    --text-file "$home/text.txt" --attachment-manifest "$home/manifest.json")
  inbox="$home/state/ext-inbox/$slug.json"
  [ "$(jq -r '.text' "$inbox")" = "" ] \
    || fail "an attachment-only request keeps its empty text"
  [ "$(jq -r '.attachments | length' "$inbox")" = 1 ] \
    || fail "an attachment-only message must still record its file"
  # The folder follows the bridge retention window with the other records.
  dir="$home/state/ext-attachments/$slug"
  assert_present "$dir/0-a.png" "the attachment copy must exist before retention"
  rm -f "$home/state/ext-inbox/$slug.json"
  future=$(( $(date +%s) + 604800 + 86400 ))
  home_env "$home" env FM_EXT_NOW_OVERRIDE="$future" "$POLL" >/dev/null
  assert_absent "$dir" "the attachment folder must expire with the request records"
  pass "45 allowlist, text-only, attachment-only, and retention hold"
}


test_43_intake_copies_cached_attachments
test_44_intake_skips_uncopyable_attachments
test_45_attachment_admission_and_retention
test_46_attachment_recovery() {
  local home slug inbox dir rc failure
  for failure in wake context; do
    home="$TMP_ROOT/c46-$failure"
    setup_home "$home"
    mkdir -p "$home/cache/documents"
    printf 'original attachment' > "$home/cache/documents/doc.txt"
    write_text "$home/text.txt" "read the file"
    jq -cn --arg path "$home/cache/documents/doc.txt" \
      '[{path:$path, name:"doc.txt", media_type:"text/plain"}]' > "$home/manifest.json"
    slug=$(slug_of "$RID")
    inbox="$home/state/ext-inbox/$slug.json"
    dir="$home/state/ext-attachments/$slug"
    mkdir -p "$dir"
    chmod 700 "$home/state" "$home/state/ext-attachments" "$dir"
    printf 'partial' > "$dir/0-doc.txt"
    chmod 600 "$dir/0-doc.txt"
    if [ "$failure" = context ]; then
      mkdir -p "$home/state/ext-context/$slug.json"
      chmod 700 "$home/state/ext-context"
    fi
    home_env "$home" env HERMES_HOME="$home" FM_WAKE_QUEUE=/dev/full "$INTAKE" \
      --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
      --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
      --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
      --attachment-manifest "$home/manifest.json" >"$home/out" 2>"$home/err"
    rc=$?
    expect_code 1 "$rc" "intake must expose the $failure failure"
    jq -e '.attachments | length == 1' "$inbox" >/dev/null \
      || fail "retrying interrupted staging must retain the attachment"
    cmp -s "$home/cache/documents/doc.txt" "$dir/0-doc.txt" \
      || fail "a published attachment must survive $failure failure with complete bytes"
    cp "$inbox" "$home/published.json"
    rm "$home/cache/documents/doc.txt"
    if [ "$failure" = context ]; then
      rmdir "$home/state/ext-context/$slug.json"
    else
      home_env "$home" "$POLL" >"$home/poll.out"
      assert_present "$home/state/ext-context/$slug.offered.json" "poll must recover the published attachment request"
    fi
    home_env "$home" env HERMES_HOME="$home" "$INTAKE" \
      --request-id "$RID" --guild-id "$GUILD" --channel-id "$CHANNEL" \
      --thread-id "$THREAD" --message-id "$MESSAGE" --author "$AUTHOR" \
      --secret-file "$home/config/ext-secret" --text-file "$home/text.txt" \
      --attachment-manifest "$home/manifest.json" >/dev/null \
      || fail "intake must recover after $failure failure"
    cmp -s "$inbox" "$home/published.json" \
      || fail "retry must preserve the published request when cache files disappear"
    [ "$(cat "$dir/0-doc.txt")" = 'original attachment' ] \
      || fail "retry must preserve published attachment bytes"
  done
  printf 'oversized replacement' > "$home/cache/documents/doc.txt"
  # shellcheck disable=SC2016 # Positional arguments expand in the child shell.
  home_env "$home" bash -c '
    . "$1/bin/fm-ext-lib.sh"
    fm_ext_attachment_copy_nofollow "$2/cache/documents" doc.txt "$3/0-doc.txt" 1
  ' _ "$ROOT" "$home" "$dir" >/dev/null 2>&1
  rc=$?
  expect_code 11 "$rc" "oversized replacement must fail"
  [ "$(cat "$dir/0-doc.txt")" = 'original attachment' ] \
    || fail "failed copying must not remove an earlier destination"
  pass "46 interrupted staging and published attachment recovery preserve files"
}

test_46_attachment_recovery

# --- 47. the Discord splitter keeps line structure, fences, and the budget -

test_47_discord_splitter_keeps_structure() {
  local home out tight
  home="$TMP_ROOT/c47"
  mkdir -p "$home"
  # The shape of a real metrics-list post: a 21-item numbered list, headings,
  # nested bullets, inline code, bold labels, and a fenced code block.
  cat > "$home/post.md" <<'TXT'
**Evaluation readiness** - the numbers an acceptance test still needs.

Answer quality:
1. Answer correctness: "the answer matches the source", target >=99%
2. Faithfulness: every claim traces to a cited passage, target >=99%
3. Fabrication rate, target <=1%
4. Retrieval hit rate: must be reported with the scored set
5. Mean reciprocal rank: must be reported with the scored set
6. Scan accuracy: "the scan was read", target >=95%

Citations:
7. Citation correctness: the cited passage matches and its link resolves, target 100%
8. Citation coverage: at least one citation in every answer

Pipeline checks that need a scored set to prove them:
9. Chunking fidelity: every chunk matches the source text
10. Retrieval correctness: the executor returns the expected chunk for the query, ranked first
11. Router intent accuracy: picks the right intent, with no hard-coded intent list anywhere
12. Planner tool selection: picks the right tools for the request
13. Score per answer: the check must output a valid score for each answer
14. Conversation memory: answers stay correct on follow-up questions, including pronouns from an earlier turn
15. Policy guard: off-topic questions blocked, with no false blocks on legitimate questions
16. Prompt-injection guard: attack prompts blocked
17. Response time within 8 s for a single question
18. Search within 4 s
19. Upload within 25 s
20. Login within 2 s
21. Concurrency: 10 / 25 / 50 / 100 users pass with no failed request

Ownership and status:
- **Owner:** platform team, with one reviewer per section
- **Status:** the scored set is still missing
  - the runner starts the scored set
  - the report lands in the evaluation folder
  - the runner writes one report per run
  - the report lists every failed case

Next step: agree a measurable target, then run the scored set end to end before the next rehearsal.

Fix the runner first:

```bash
bin/eval-run.sh --set golden --report out/report.json
```
TXT
  [ "$(wc -c < "$home/post.md")" -gt 1900 ] \
    || fail "the fixture must exceed the default Discord budget"

  # The alignment checker: every original line recurs byte-for-byte and in
  # order, allowing only dropped blank lines at chunk edges and fence lines the
  # splitter adds when a code block spans chunks.
  cat > "$home/check.py" <<'PY'
import json
import sys

original, split_path, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
expected = open(original, encoding="utf-8").read().strip().split("\n")
texts = json.load(open(split_path, encoding="utf-8"))["texts"]
assert len(texts) > 1, "a reply over the limit must split: %r" % (texts,)
for chunk in texts:
    assert len(chunk) <= limit, "chunk over the %d limit: %d" % (limit, len(chunk))
    assert sum(line.startswith("```") for line in chunk.split("\n")) % 2 == 0, (
        "unbalanced fences in chunk: %r" % chunk
    )
for chunk in texts:
    assert not any(
        part.startswith("(") and part.endswith(")") and "/" in part
        for part in chunk.split(" ")
    ), "Discord chunks must not carry a (k/n) counter: %r" % chunk

def edge_trim(lines):
    start, end = 0, len(lines)
    while start < end and lines[start] == "":
        start += 1
    while end > start and lines[end - 1] == "":
        end -= 1
    return lines[start:end]

index = 0
for position, chunk in enumerate(texts):
    if position:
        while index < len(expected) and expected[index] == "":
            index += 1
    for line in edge_trim(chunk.split("\n")):
        if index < len(expected) and expected[index] == line:
            index += 1
            continue
        assert line.startswith("```"), (
            "line missing or reordered at chunk %d: %r (expected %r)"
            % (position, line, expected[index] if index < len(expected) else None)
        )
while index < len(expected) and expected[index] == "":
    index += 1
assert index == len(expected), "split lost %d line(s)" % (len(expected) - index)
PY

  out=$(home_env "$home" "$OUTBOX" split < "$home/post.md") \
    || fail "split refused the metrics post"
  printf '%s' "$out" > "$home/split.json"
  [ "$(jq -r '.limit' "$home/split.json")" = 1900 ] \
    || fail "split must report the default limit"
  "$PYTHON_BIN" "$home/check.py" "$home/post.md" "$home/split.json" 1900 \
    || fail "a split reply must keep every line: $out"
  # The nested sub-items keep their two-space indent and the fence stays whole.
  jq -r '.texts[]' "$home/split.json" | grep -Fqx '  - the runner starts the scored set' \
    || fail "nested bullets must keep their indent"
  jq -r '.texts[]' "$home/split.json" | grep -Fq '```bash
bin/eval-run.sh --set golden --report out/report.json
```' || fail "a fenced code block that fits must stay intact"
  pass "47 a long Discord reply splits on its own lines without renumbering"

  # A code block longer than one chunk is closed and reopened with its own
  # fence line, and stays within the limit.
  {
    printf 'Here is the log:\n\n```bash\n'
    printf 'step %s of the deploy\n' 1 2 3 4 5 6
    printf '```\n\nDone.\n'
  } > "$home/code.md"
  tight=$(home_env "$home" "$OUTBOX" split --max 60 < "$home/code.md") \
    || fail "split refused the code post"
  printf '%s' "$tight" > "$home/tight.json"
  [ "$(jq -r '.texts | length' "$home/tight.json")" -gt 2 ] \
    || fail "a code block over the budget must span chunks: $tight"
  jq -r '.texts[]' "$home/tight.json" > "$home/tight.txt"
  jq -e 'all(.texts[]; length <= 60)' "$home/tight.json" > /dev/null \
    || fail "every chunk must stay within the tight budget: $(cat "$home/tight.txt")"
  jq -e 'all(.texts[]; (split("\n") | map(select(startswith("```"))) | length) % 2 == 0)' \
    "$home/tight.json" > /dev/null \
    || fail "every chunk must carry balanced fences: $(cat "$home/tight.txt")"
  [ "$(grep -c '^```bash$' "$home/tight.txt")" -gt 1 ] \
    || fail "a reopened code block must keep its language tag: $(cat "$home/tight.txt")"
  grep -Fqx '```' "$home/tight.txt" \
    || fail "a split code block must be closed: $(cat "$home/tight.txt")"

  # One line longer than the limit still splits safely.
  "$PYTHON_BIN" -c 'print("a" * 200)' > "$home/word.md"
  out=$(home_env "$home" "$OUTBOX" split --max 60 < "$home/word.md") \
    || fail "split refused an over-long single line"
  printf '%s' "$out" > "$home/word.json"
  "$PYTHON_BIN" - "$home/word.json" <<'PY'
import json, sys
texts = json.load(open(sys.argv[1], encoding="utf-8"))["texts"]
assert all(len(chunk) <= 60 for chunk in texts), "chunk over the 60 limit: %r" % texts
assert "".join(texts) == "a" * 200, "a hard split must not lose characters: %r" % texts
PY

  # A reply under the limit is posted untouched.
  printf 'Aye, all shipshape.\n\n- one\n- two\n' > "$home/short.md"
  out=$(home_env "$home" "$OUTBOX" split < "$home/short.md") || fail "split refused a short reply"
  [ "$(printf '%s' "$out" | jq -r '.texts | length')" = 1 ] \
    || fail "an under-limit reply must be one message: $out"
  printf '%s' "$out" > "$home/short.json"
  "$PYTHON_BIN" - "$home/short.md" "$home/short.json" <<'PY' \
    || fail "an under-limit reply must be untouched: $out"
import json, pathlib, sys
assert json.loads(pathlib.Path(sys.argv[2]).read_text())["texts"] == [
    pathlib.Path(sys.argv[1]).read_text()
]
PY
  pass "47 fences stay balanced across chunks and short replies pass through"
}

test_47_discord_splitter_keeps_structure
# --- 48. splitter boundary regressions -------------------------------------

test_48_discord_splitter_boundaries() {
  local home
  home="$TMP_ROOT/c48"
  mkdir -p "$home"
  home_env "$home" uv run --no-project python3 - "$OUTBOX" <<'PYTEST' || fail "splitter boundary regressions"
import json
import os
import subprocess
import sys


def split(text, limit=60, cap=25):
    result = subprocess.run(
        [sys.argv[1], "split", "--max", str(limit), "--cap", str(cap)],
        input=text, text=True, capture_output=True, check=True,
    )
    chunks = json.loads(result.stdout)["texts"]
    assert all(len(chunk) <= limit for chunk in chunks), chunks
    assert all(sum(line.startswith("```") for line in chunk.split("\n")) % 2 == 0
               for chunk in chunks), chunks
    return chunks

for use_flags in (False, True):
    env = dict(os.environ, FM_EXT_DISCORD_REPLY_MAX_CHARS="050",
               FM_EXT_DISCORD_THREAD_MAX="025")
    flags = ["--max", "050", "--cap", "025"] if use_flags else []
    limits = subprocess.run([sys.argv[1], "limits"] + flags,
                            env=env, text=True, capture_output=True, check=True)
    assert json.loads(limits.stdout) == {"limit": 50, "cap": 25}, limits.stdout
    for legacy in (False, True):
        result = subprocess.run(
            [sys.argv[1], "split"] + flags + (["--legacy"] if legacy else []),
            env=env, input="x" * 100, text=True, capture_output=True, check=True,
        )
        plan = json.loads(result.stdout)
        assert plan["limit"] == 50 and plan["cap"] == 25, plan
        assert all(len(chunk) <= 50 for chunk in plan["texts"]), plan

assert split("x" * 30 + "\n## Title\n" + "y" * 45) == [
    "x" * 30 + "\n## Title", "y" * 45
]

line = '  print("a  b")  ' * 12
assert "".join(split(line)) == line
code = "```python\n" + line + "\n```"
chunks = split(code)
assert "".join("\n".join(chunk.split("\n")[1:-1]) for chunk in chunks) == line
text = "  first  line\n \t \n  second  line\n\n" + "z" * 60
chunks = split(text)
assert chunks[0] == "  first  line\n \t \n  second  line", chunks
assert split("  short  line\n \t \n  end  ") == ["  short  line\n \t \n  end  "]

bullets = "- 12345678\n- abcdefgh\n- ijklmnop"
assert split("p" * 1875 + "\n\n" + bullets, 1900) == ["p" * 1875, bullets]
item = "- parent\n  - child\n  - sibling"
chunks = split("a" * 45 + "\n" + item)
assert item in chunks, chunks

code = "```bash\n" + "\n".join(["x" * 20] * 6) + "\n```"
chunks = split(code, cap=1)
assert len(chunks) == 1 and chunks[0].endswith("…\n```"), chunks
assert split("x" * 120, cap=1) == ["x" * 59 + "…"]

for opener, expected in [
    ('```typescript title="src/components/Example.tsx"', "```typescript"),
    ("```" + "x" * 100, "```"),
]:
    chunks = split(opener + "\n" + "a" * 100 + "\n```", limit=50)
    assert all(chunk.split("\n")[0] == expected for chunk in chunks), chunks
    assert "".join("\n".join(chunk.split("\n")[1:-1]) for chunk in chunks) == "a" * 100
print("ok - 48 whitespace, paragraphs, capped fences, and long openers")
PYTEST
}

test_49_split_plan_survives_restart() {
  local home slug mode
  for mode in current legacy; do
    home="$TMP_ROOT/c49-$mode"
    setup_home "$home"
    slug=$(intake_ok "$home" "resume original split plan")
    "$PYTHON_BIN" -c 'print("0123456789" * 200, end="")' > "$home/ans.txt"
    home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
      --text-file "$home/ans.txt" >/dev/null
    home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$slug" "$mode" <<'PYTEST' \
      || fail "resume must preserve the $mode split plan"
import json
import sys
from pathlib import Path
import outbox_poster as poster

home, slug, mode = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
path = home / "state" / "ext-outbox" / f"{slug}.answer.1.json"
text = (home / "ans.txt").read_text()
original_split = poster.split_reply
plan = original_split(text, home=home, legacy=mode == "legacy")["texts"]
if mode == "legacy":
    def old_split(*args, **kwargs):
        kwargs["legacy"] = True
        return original_split(*args, **kwargs)
    poster.split_reply = old_split

sent = []
def send(payload):
    if payload["chunk_index"] > 0:
        raise poster.DiscordSendError("transient", "retry later")
    sent.append(payload["text"])
    return {"discord_message_id": "490"}

assert poster.deliver_one(path, send=send, home=home) == "failed"
assert sent == plan[:1]
payload = json.loads(path.read_text())
progress = poster.load_progress(payload, home)
assert progress["texts"] == plan
if mode == "legacy":
    del progress["texts"]
    poster.write_progress(payload, progress, home)
(home / "sent.json").write_text(json.dumps(sent))
(home / "plan.json").write_text(json.dumps(plan))
PYTEST
    home_env "$home" env PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" "$slug" "$mode" <<'PYTEST' \
      || fail "restart must complete the $mode split plan"
import json
import re
import sys
from pathlib import Path
import outbox_poster as poster

home, slug, mode = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
path = home / "state" / "ext-outbox" / f"{slug}.answer.1.json"
sent = json.loads((home / "sent.json").read_text())
plan = json.loads((home / "plan.json").read_text())
original_split = poster.split_reply
def changed_split(*args, **kwargs):
    assert mode == "legacy" and kwargs.get("legacy"), "must not recompute stored chunks"
    return original_split(*args, **kwargs)
poster.split_reply = changed_split

def send(payload):
    progress = poster.load_progress(json.loads(path.read_text()), home)
    assert progress["texts"] == plan
    sent.append(payload["text"])
    return {"discord_message_id": str(490 + payload["chunk_index"])}

assert poster.deliver_one(path, send=send, home=home) == "sent"
assert sent == plan
content = [re.sub(r" \(\d+/\d+\)$", "", chunk) for chunk in sent] if mode == "legacy" else sent
assert "".join(content) == (home / "ans.txt").read_text()
print("ok - 49", mode, "split plan survives restart without content loss or duplication")
PYTEST
  done
}

# --- 50. generated replies hold every splitter invariant -------------------

test_50_discord_splitter_properties() {
  local home
  home="$TMP_ROOT/c50"
  mkdir -p "$home"
  cat > "$home/sweep.py" <<'PY'
"""Seeded property sweep over the Discord reply splitter."""
import random
import sys

sys.path.insert(0, sys.argv[1])
from discord_split import split_discord


def delimiters(lines):
    """Independent fence state machine: True when a line is a fence delimiter."""
    flags = []
    state = None
    for line in lines:
        stripped = line.lstrip(" \t")
        char = stripped[0] if stripped else ""
        length = 0
        while length < len(stripped) and char in "`~" and stripped[length] == char:
            length += 1
        info = stripped[length:]
        fence = char in "`~" and length >= 3 and not (char == "`" and "`" in info)
        if not fence:
            flags.append(False)
            continue
        if state is None:
            state = (char, length)
            flags.append(True)
        elif char == state[0] and length >= state[1] and info.strip() == "":
            state = None
            flags.append(True)
        else:
            flags.append(False)
    return flags


def balance_ok(chunk):
    lines = chunk.split("\n")
    state = None
    for line, fence in zip(lines, delimiters(lines)):
        if not fence:
            continue
        stripped = line.lstrip(" \t")
        char = stripped[0]
        length = 0
        while length < len(stripped) and stripped[length] == char:
            length += 1
        if state is None:
            state = (char, length)
        elif char == state[0] and length >= state[1]:
            state = None
    return state is None


def content(lines):
    return [line for line, fence in zip(lines, delimiters(lines)) if not fence]


def edges_trimmed(lines):
    lines = list(lines)
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return lines


def check_message(text, limit, cap):
    chunks = split_discord(text, limit, cap)
    if len(text) <= limit:
        assert chunks == [text], ("untouched reply", repr(text), chunks)
        return
    if not text.strip():
        assert chunks == [], ("whitespace-only reply", chunks)
        return
    assert chunks, "a non-empty reply must produce chunks"
    assert len(chunks) <= cap, ("cap", cap, chunks)
    for chunk in chunks:
        assert len(chunk) <= limit, ("limit", limit, len(chunk), chunk)
        assert not any(
            part.startswith("(") and part.endswith(")") and "/" in part
            for part in chunk.split(" ")
        ), ("counter", chunk)
        assert balance_ok(chunk), ("fences", limit, repr(chunk))
    want = content(edges_trimmed(text.split("\n")))
    have = []
    for chunk in chunks:
        have.extend(content(edges_trimmed(chunk.split("\n"))))
    truncated = len(chunks) == cap and "\u2026" in chunks[-1]
    i = j = 0
    while i < len(want):
        expected = want[i]
        if j < len(have) and have[j] == expected:
            i += 1
            j += 1
            continue
        if not expected.strip():
            i += 1
            continue
        accumulated = ""
        while len(accumulated) < len(expected) and j < len(have):
            accumulated += have[j]
            j += 1
            if accumulated == expected:
                break
        if accumulated == expected:
            i += 1
            continue
        if truncated and have and "\u2026" in have[-1] and j >= len(have):
            break
        raise AssertionError("content mismatch at %d: %r vs %r" % (i, expected, have[j:j + 2]))
    while j < len(have) and not have[j].strip():
        j += 1
    if truncated and have[j:] == ["…"]:
        j += 1
    assert j >= len(have), ("extra content", have[j:], chunks)


FRAGMENTS = [
    "**Label:** short text", "- bullet one", "  - nested bullet", "    - deeper bullet",
    "1. numbered item", "  2. nested number", "`inline code`", "    indented code line",
    "```python", "```bash", "```", "~~~", "~~~~", "```literal", "text after fence",
    "# Heading", "## Sub heading", "### Third level",
    "plain paragraph line that has a fair number of words in it " * 3,
    "x" * 90, "  leading spaces and  double  spaces  ", " \t ", "", "",
    "- item with a long tail " * 2, '  print("a  b")  ' * 3,
    "```" + " " * 50 + "literal", "~~~" + " " * 50 + "literal",
    "x" * 60 + "```example", "x" * 60 + "~~~example",
    "```   ", "~~~   ", "````text", "~~~~text", "`````   ", "~~~~~   ",
    "`" * 61, "~" * 61, "```" + "long_info" * 30,
    "~~~" + "long_info" * 30, "`" * 30, "~" * 30,
    "x" * 10 + "`" * 20 + "x" * 10,
    "x" * 10 + "~" * 20 + "x" * 10,
]

def regression_truncation_exposes_closer():
    text = "```\na\n```\n" + "y" * 50 + "\n\n" + "z" * 60
    check_message(text, 60, 1)
    assert balance_ok(split_discord(text, 60, 1)[0])


def regression_split_boundaries_do_not_create_fences():
    for fence in ("```", "~~~"):
        for text in (
            fence + "text\n" + fence + " " * 50 + "literal\n" + fence,
            "x" * 60 + fence + "example",
        ):
            check_message(text, 60, 25)


def regression_oversized_fence_line():
    for fence in ("`", "~"):
        for body in ("", "content\n"):
            text = fence * 3 + "\n" + body + fence * 61
            check_message(text, 60, 25)
            chunks = split_discord(text, 60, 25)
            assert all(balance_ok(chunk) for chunk in chunks), chunks
            assert any(body.rstrip("\n") in chunk for chunk in chunks), chunks


def regression_minimal_valid_delimiters():
    for char in ("`", "~"):
        delimiter = char * 30
        text = delimiter + "\n" + char * 3 + "\n" + delimiter
        chunks = split_discord(text, 60)
        assert len(chunks) == 1, chunks
        assert chunks[0].split("\n")[1:-1] == [char * 3], chunks
        assert len(chunks[0].split("\n")[0]) == 4, chunks
        assert chunks[0].split("\n")[-1] == delimiter, chunks
        check_message(text, 60, 25)
        for body in ("x" * 40, "x" * 10 + char * 5 + "x" * 10):
            text = delimiter + "\n" + body + "\n" + delimiter
            chunks = split_discord(text, 60)
            assert len(chunks) == 1, chunks
            assert chunks[0].split("\n")[1:-1] == [body], chunks
            expected = max(3, 6 if char in body else 3)
            assert chunks[0].split("\n")[0] == char * expected, chunks
            assert chunks[0].split("\n")[-1] == char * expected, chunks
            check_message(text, 60, 25)
        opener, closer = char * 3 + "python  ", "  " + char * 5 + "  "
        text = opener + "\n" + "\n".join(["x" * 20] * 4) + "\n" + closer
        chunks = split_discord(text, 60)
        assert all(chunk.split("\n")[0] == opener for chunk in chunks), chunks
        assert all(chunk.split("\n")[-1] == closer for chunk in chunks), chunks
        check_message(text, 60, 25)
        text = delimiter + "\n" + "x" * 50 + "\n" + delimiter
        chunks = split_discord(text, 60)
        assert chunks == [char * 3 + "\n" + "x" * 50 + "\n" + char * 3], chunks
        check_message(text + "\n\n" + "y" * 60, 60, 1)


def regression_exact_passthrough_and_opener():
    for text in ("\nhi\n", " \t ", "", "```python  \na\n```\n"):
        assert split_discord(text, 60) == [text]
    text = "```python  \n" + "x" * 100 + "\n```"
    chunks = split_discord(text, 60)
    assert all(chunk.startswith("```python  \n") for chunk in chunks), chunks
    check_message(text, 60, 25)


regression_truncation_exposes_closer()
regression_split_boundaries_do_not_create_fences()
regression_oversized_fence_line()
regression_minimal_valid_delimiters()
regression_exact_passthrough_and_opener()

total = 0
for seed in (1, 7, 20261015, 424242, 999983):
    rng = random.Random(seed)
    for _ in range(600):
        text = "\n".join(rng.choice(FRAGMENTS) for _ in range(rng.randint(1, 14)))
        if rng.random() < 0.3:
            text = "# Heading\n\n" + text
        check_message(text, rng.choice([60, 200, 1900]), rng.choice([1, 2, 3, 25]))
        total += 1

# The shapes the review findings named, kept as deterministic cases.
check_message("```python\n" + '  print("a  b")  ' * 8 + "\n```", 60, 25)
check_message("  first  line\n \t \n  second  line\n\n" + "z" * 200, 60, 25)
check_message("a" * 45 + "\n" + "- parent\n  - child\n  - sibling", 60, 25)
check_message("p" * 1875 + "\n\n" + "- 12345678\n- abcdefgh\n- ijklmnop", 1900, 25)
check_message('```typescript title="src/components/Example.tsx"\n' + "a" * 100 + "\n```", 50, 25)
check_message("```text\n```literal\n" + "x" * 80 + "\n```", 60, 25)
check_message("x" * 52 + "\n```\n```\n\nz", 60, 1)
check_message("x" * 120, 60, 1)
print("ok - 50 %d generated replies hold every splitter invariant" % total)
PY
  home_env "$home" uv run --no-project python3 "$home/sweep.py" "$PLUGIN" \
    || fail "the generated-reply invariant sweep must pass"
  pass "50 generated replies keep their lines, limits, fences, and content"
}

# --- 51. delivery does not wait for a reconciliation sweep -----------------

test_51_delivery_survives_a_long_sweep() {
  local home slug stem staged out
  home="$TMP_ROOT/c51-watcher"
  setup_home "$home"
  slug=$(intake_ok "$home" "reply while the sweep runs")
  write_text "$home/ans.txt" "queued mid-sweep"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  stem="$slug.answer.1"
  # Stage the payload outside the outbox so it is queued only once the sweep
  # is already running.
  staged="$home/staged-$stem.json"
  mv "$home/state/ext-outbox/$stem.json" "$staged"

  out=$(home_env "$home" env STEM="$stem" STAGED="$staged" PYTHONPATH="$PLUGIN" \
    "$PYTHON_BIN" - "$home" <<'PY'
import os, sys, threading, time
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster as poster
home = Path(sys.argv[1])
outbox = home / "state" / "ext-outbox"
stem = os.environ["STEM"]
payload = outbox / f"{stem}.json"
staged = Path(os.environ["STAGED"])
receipt = outbox / f"{stem}.receipt.json"
sweeping = threading.Event()

def send(chunk):
    return {"ok": True, "discord_message_id": "900000000000000001",
            "buttons": bool(chunk.get("decision"))}

def blocking_sweep(full=False):
    sweeping.set()
    # Stands in for a sweep whose ledger and edit passes take minutes.
    time.sleep(30)

real_drain = poster.drain_outbox
poster.drain_outbox = lambda **kwargs: real_drain(send=send, home=home)
poster.reconcile_decision_posts = blocking_sweep
poster.reconcile_thread_states = lambda **kwargs: []
poster.decisions.ensure_click_route = lambda: False

os.environ["FM_EXT_OUTBOX_POLL_SECS"] = "0.05"
poster.start_outbox_watcher()
if not sweeping.wait(10):
    print("no-sweep")
    sys.stdout.flush()
    os._exit(0)
os.replace(staged, payload)
deadline = time.monotonic() + 3.0
while time.monotonic() < deadline and not receipt.exists():
    time.sleep(0.05)
print("delivered" if receipt.exists() else "queued")
sys.stdout.flush()
os._exit(0)
PY
)
  [ "$out" = "delivered" ] \
    || fail "a payload queued during a long sweep must still be delivered within a few poll ticks (got '$out')"
  assert_present "$home/state/ext-outbox/$stem.receipt.json" \
    "the mid-sweep reply must be receipted while the sweep is still running"
  pass "51 a queued reply is delivered while a reconciliation sweep is blocked"
}

# --- 52. concurrent thread-record writes lose neither update ---------------

test_52_thread_record_writes_are_serialized() {
  local home slug out
  home="$TMP_ROOT/c52-thread-record"
  setup_home "$home"
  slug=$(printf 'd%.0s' $(seq 1 64))
  out=$(home_env "$home" env SLUG="$slug" RID="$RID" THREAD="$THREAD" \
    PYTHONPATH="$PLUGIN" "$PYTHON_BIN" - "$home" <<'PY'
import json, os, sys, tempfile, threading, time
from pathlib import Path
sys.path.insert(0, os.environ["PYTHONPATH"])
import outbox_poster as poster
home = Path(sys.argv[1])
outbox = home / "state" / "ext-outbox"
outbox.mkdir(mode=0o700, parents=True, exist_ok=True)
path = outbox / f"{os.environ['SLUG']}.thread.json"

# Hold every writer at the point just before it publishes its record. Two
# writers that read the same prior therefore both write from it unless the
# records are serialized, which is how the delivery and sweep paths raced.
real_mkstemp = tempfile.mkstemp
def gated_mkstemp(*args, **kwargs):
    time.sleep(0.05)
    return real_mkstemp(*args, **kwargs)
poster.tempfile.mkstemp = gated_mkstemp

updates = [
    {"topic_name": "Name One"},
    {"thread_state": "needs-you"},
    {"creating_title": "Title Three"},
    {"retitle": "Retitle Four"},
    {"creator": "firstmate"},
    {"state_at": 1234.5},
    {"rename": {"name": "Name Seven", "at": 1, "outcome": "applied"}},
    {"marked_open": True},
]

def writer(update):
    poster.save_thread_record(path, os.environ["RID"], os.environ["THREAD"], **update)

threads = [threading.Thread(target=writer, args=(update,)) for update in updates]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()

record = json.loads(path.read_text())
missing = [key for key in dict.fromkeys(k for update in updates for k in update)
           if key not in record]
poster.thread_name_for = lambda payload, home: poster._read_thread_record(path).get("retitle") or "Topic"
poster.dedicated_channel = lambda home: os.environ["RID"].split(":")[2]
renamed = []
remote = {}
def rename(thread, name):
    renamed.append(name)
    remote[thread] = name

def seed(state="needs-you", failed=None):
    poster.save_thread_record(path, os.environ["RID"], os.environ["THREAD"],
        topic_name="Topic", thread_state=state, creator="firstmate",
        state_at=1, marked_open=True, retitle="", rename=failed or {"outcome": "applied"})

def summaries(home):
    poster.save_thread_record(path, os.environ["RID"], os.environ["THREAD"],
                              thread_state="done", state_at=3)
    return {os.environ["THREAD"]: {"open": 0, "closed": 1, "last_posted_at": 2}}

real_summaries = poster.decision_threads
seed()
poster.decision_threads = summaries
poster.reconcile_thread_states(home, rename_thread=rename)
assert poster._read_thread_record(path)["thread_state"] == "done"
assert not renamed

seed("done", {"outcome": "failed", "retryable": True})
real_apply = poster.apply_thread_state
def interleaved_apply(recorded, *args, **kwargs):
    poster.save_thread_record(path, os.environ["RID"], os.environ["THREAD"],
                              thread_state="needs-you", state_at=4)
    return real_apply(recorded, *args, **kwargs)
poster.apply_thread_state = interleaved_apply
poster.reconcile_thread_states(home, rename_thread=rename)
assert poster._read_thread_record(path)["thread_state"] == "needs-you"
assert not renamed
poster.apply_thread_state = real_apply

for operation in ("read", "rename"):
    seed()
    entered, release, saved = threading.Event(), threading.Event(), threading.Event()
    def block(*args):
        entered.set()
        assert release.wait(5)
        if len(args) == 2:
            rename(*args)
        return "Topic"
    def deliver():
        assert real_apply(poster._read_thread_record(path), "done", home,
                          retitle="Delivered title", rename_thread=rename) == "applied"
        saved.set()
    sweep = threading.Thread(target=real_apply,
        args=(poster._read_thread_record(path), "none", home),
        kwargs={"read_thread": block if operation == "read" else lambda tid: "",
                "rename_thread": block if operation == "rename" else rename,
                "require_current": True})
    sweep.start()
    assert entered.wait(3)
    delivery = threading.Thread(target=deliver)
    delivery.start()
    try:
        assert saved.wait(1), "Discord work blocked a delivery record save"
    finally:
        release.set()
        sweep.join(5)
        delivery.join(5)
    assert poster._read_thread_record(path)["thread_state"] == "done"
    assert poster._read_thread_record(path)["retitle"] == "Delivered title"
    assert remote[os.environ["THREAD"]] == "✅ Delivered title"
    assert poster._read_thread_record(path)["topic_name"] == remote[os.environ["THREAD"]]

seed()
entered, release = threading.Event(), threading.Event()
def delivery_rename(*args):
    entered.set()
    assert release.wait(5)
    rename(*args)
delivery = threading.Thread(target=real_apply,
    args=(poster._read_thread_record(path), "done", home),
    kwargs={"rename_thread": delivery_rename, "state_at": 10})
delivery.start()
assert entered.wait(3)
try:
    assert real_apply(poster._read_thread_record(path), "none", home,
        rename_thread=rename, read_thread=lambda tid: "other",
        require_current=True) == "applied"
finally:
    release.set()
    delivery.join(5)
assert poster._read_thread_record(path)["thread_state"] == "done"
assert poster._read_thread_record(path)["state_at"] == 10
assert remote[os.environ["THREAD"]] == "✅ Topic"

assert real_apply(poster._read_thread_record(path), "needs-you", home,
                  rename_thread=rename) == "applied"
assert poster._read_thread_record(path)["thread_state"] == "needs-you"

(home / "state" / "route-fix.status").write_text("needs-decision [key=publication]: pick a route\n")
publication = {"slug": os.environ["SLUG"], "kind": "followup", "generation": 2}
progress = {"request_id": os.environ["RID"], "topic_thread_id": os.environ["THREAD"],
            "decision": {"key": "key:route-fix:publication"},
            "buttons": True, "discord_message_ids": ["900000000000000001"], "posted_at": 2}
closed = dict(publication, generation=1)
poster.write_progress(closed, dict(progress, posted_at=1), home)
(outbox / f"{os.environ['SLUG']}.followup.1.settled.json").write_text('{"kind":"decided"}')
published_path = outbox / f"{os.environ['SLUG']}.followup.2.progress.json"

def publish():
    poster.write_progress(publication, progress, home)

for phase in ("summary", "apply", "rename"):
    published_path.unlink(missing_ok=True)
    seed()
    renamed.clear()
    remote[os.environ["THREAD"]] = "❓ Topic"
    def snapshot(home):
        summary = real_summaries(home)
        assert summary[os.environ["THREAD"]]["open"] == 0
        if phase == "summary":
            publish()
        return summary
    poster.decision_threads = snapshot
    def publish_before_apply(*args, **kwargs):
        publish()
        return real_apply(*args, **kwargs)
    poster.apply_thread_state = publish_before_apply if phase == "apply" else real_apply
    entered, release = threading.Event(), threading.Event()
    def clearing_rename(*args):
        entered.set()
        assert release.wait(5)
        rename(*args)
    if phase == "rename":
        sweep = threading.Thread(target=poster.reconcile_thread_states, args=(home,),
            kwargs={"rename_thread": clearing_rename, "read_thread": lambda tid: "other"})
        sweep.start()
        assert entered.wait(3)
        try:
            publish()
        finally:
            release.set()
            sweep.join(5)
        assert not sweep.is_alive()
    else:
        poster.reconcile_thread_states(home, rename_thread=rename,
                                       read_thread=lambda tid: "other")
        assert not renamed
    assert real_summaries(home)[os.environ["THREAD"]]["open"] == 1
    assert poster._read_thread_record(path)["thread_state"] == "needs-you"
    assert remote[os.environ["THREAD"]] == "❓ Topic"
    assert poster._read_thread_record(path)["marked_open"]
poster.apply_thread_state = real_apply
poster.decision_threads = real_summaries

print(json.dumps({"missing": missing, "record": record}))
PY
) || fail "thread-record concurrency regression failed"
  printf '%s\n' "$out" | jq -e '.missing == []' >/dev/null \
    || fail "concurrent thread-record writers must lose no update: $out"
  printf '%s\n' "$out" | jq -e '
    .record.topic_name == "Name One" and .record.thread_state == "needs-you"
    and .record.creator == "firstmate" and .record.marked_open == true' >/dev/null \
    || fail "concurrent thread-record writers must keep every value: $out"
  pass "52 concurrent sweeps and deliveries keep every thread-record update"
}

# --- 53. a delivery receipt carries its queue times ------------------------

test_53_delivery_receipt_carries_queue_times() {
  local home slug stem recorded out journal receipt
  home="$TMP_ROOT/c53-receipt"
  setup_home "$home"
  slug=$(intake_ok "$home" "time my pickup")
  write_text "$home/ans.txt" "delivered with timing"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  stem="$slug.answer.1"
  recorded=$(jq -r '.recorded_at' "$home/state/ext-outbox/$stem.json")
  journal="$home/journal.log"
  out=$(home_env "$home" env STEM="$stem" PYTHONPATH="$PLUGIN" \
    "$PYTHON_BIN" - "$home" "$stem" 2>"$journal" <<'PY'
import sys
from pathlib import Path
import outbox_poster as poster
home, stem = Path(sys.argv[1]), sys.argv[2]
def send(chunk):
    return {"ok": True, "discord_message_id": "910000000000000001", "buttons": False}
print(poster.deliver_one(home / "state" / "ext-outbox" / f"{stem}.json",
                         send=send, home=home))
PY
)
  assert_equals "sent" "$out" "the queued reply must deliver"
  receipt="$home/state/ext-outbox/$stem.receipt.json"
  assert_present "$receipt" "a delivered generation must record its receipt"
  jq -e --argjson recorded "$recorded" \
    '.queued_at == $recorded and .picked_at >= .queued_at and .picked_at > 0' \
    "$receipt" >/dev/null \
    || fail "the receipt must carry queued_at/picked_at: $(cat "$receipt")"
  assert_contains "$(cat "$journal")" "fm-ext-poster: delivered ${slug:0:12} answer.1 queued=" \
    "the delivery must log one journal line with its queue times"
  assert_contains "$(cat "$journal")" "wait=" "the journal line must report the queue wait"
  assert_contains "$(cat "$journal")" "post=" "the journal line must report the post time"
  assert_contains "$(cat "$journal")" "chunks=1" "the journal line must report the chunk count"
  pass "53 delivery receipts carry queued_at/picked_at and the journal line is emitted"
}

# --- 54. pending ignores decision markers ----------------------------------

test_54_pending_skips_terminal_markers() {
  local home slug stem i listed expected ms
  home="$TMP_ROOT/c54-pending-markers"
  setup_home "$home"
  slug=$(intake_ok "$home" "list me")
  write_text "$home/ans.txt" "pending payload"
  home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation 1 \
    --text-file "$home/ans.txt" >/dev/null
  write_text "$home/two.txt" "second pending payload"
  home_env "$home" "$EMIT" --request-id "$RID" --kind followup --generation 1 \
    --text-file "$home/two.txt" >/dev/null
  # 120 delivered decision posts leave a settled marker and a sent marker each.
  # Neither can ever be a payload, and scanning them made every poll pay for
  # the whole decision history.
  for i in $(seq 1 120); do
    stem="$home/state/ext-outbox/$(printf '%064d' "$i").followup.$i"
    printf '{"kind":"replaced","text":"gone","at":1}\n' > "$stem.settled.json"
    printf '{"request_id":"%s","option":"1","at":1}\n' "$RID" > "$stem.sent.json"
    chmod 600 "$stem.settled.json" "$stem.sent.json"
  done
  expected=$(printf '%s\n%s\n' "$home/state/ext-outbox/$slug.answer.1.json" \
    "$home/state/ext-outbox/$slug.followup.1.json" | sort)
  listed=$(home_env "$home" "$OUTBOX" pending | sort)
  assert_equals "$expected" "$listed" \
    "pending must list exactly the undelivered payloads beside settled/sent markers"
  ms=$(steady_pending_ms "$home")
  printf 'pending with 240 terminal markers: %sms\n' "$ms"
  [ "$ms" -lt 2000 ] || fail "settled/sent markers must not cost a launch each, got ${ms}ms"
  pass "54 pending skips settled and sent markers and lists the same payloads"
}

# --- 55. retention completes inside the poll and never starves the claim ----

test_55_retention_prune_completes_without_starving_the_claim() {
  local home slug offered ctx out rc start elapsed i
  local stale fresh_recorded no_recorded young_mtime pinned late fresh_marker old_marker
  local old_thread kept_thread
  home="$TMP_ROOT/c55-prune"
  setup_home "$home"
  slug=$(intake_ok "$home" "claim me before you prune")
  offered="$home/state/ext-context/${slug}.offered.json"
  # An unclaimed offer is exactly what the poll exists to pick up.
  rm -f "$offered"
  : > "$home/state/.wake-queue"
  ctx="$home/state/ext-context"
  mkdir -p "$ctx" "$home/state/ext-outbox"
  chmod 700 "$ctx" "$home/state/ext-outbox"

  # Thousands of records past the retention window: one jq launch per file made
  # this prune outlast the watcher's 30-second check timeout, so it never
  # finished and the claim behind it never ran.
  for i in $(seq 1 2000); do
    printf '{"request_id":"%s","recorded_at":1}\n' "$RID" > "$ctx/$(printf '%064x' "$i").json"
  done

  # Every rule variant the prune must keep or drop.
  stale="$ctx/$(printf 'a%.0s' $(seq 1 64)).json"
  printf '{"request_id":"%s","recorded_at":1}\n' "$RID" > "$stale"
  fresh_recorded="$ctx/$(printf 'b%.0s' $(seq 1 64)).json"
  printf '{"request_id":"%s","recorded_at":%s}\n' "$RID" "$(date +%s)" > "$fresh_recorded"
  touch -t 202001010000.00 "$fresh_recorded"
  no_recorded="$ctx/$(printf 'c%.0s' $(seq 1 64)).json"
  printf '{}\n' > "$no_recorded"
  touch -t 202001010000.00 "$no_recorded"
  young_mtime="$ctx/$(printf 'd%.0s' $(seq 1 64)).json"
  printf '{}\n' > "$young_mtime"
  pinned="$ctx/$slug.json"
  printf '{"request_id":"%s","recorded_at":1}\n' "$RID" > "$pinned"
  fresh_marker="$home/state/ext-outbox/$(printf 'e%.0s' $(seq 1 64)).followup.1.progress.json"
  printf '{"decision":{}}\n' > "$fresh_marker"
  old_marker="$home/state/ext-outbox/$(printf 'f%.0s' $(seq 1 64)).followup.1.settled.json"
  printf '{"kind":"replaced","text":"gone","at":1}\n' > "$old_marker"
  touch -t 202001010000.00 "$old_marker"
  # A thread record whose request left no other record expires with them; one
  # whose request still has a live record stays.
  old_thread="$home/state/ext-outbox/$(printf '1%.0s' $(seq 1 64)).thread.json"
  printf '{"request_id":"discord:1:2:3:4","topic_thread_id":"5"}\n' > "$old_thread"
  touch -t 202001010000.00 "$old_thread"
  kept_thread="$home/state/ext-outbox/$(printf '2%.0s' $(seq 1 64)).thread.json"
  printf '{"request_id":"discord:1:2:3:4","topic_thread_id":"5"}\n' > "$kept_thread"
  touch -t 202001010000.00 "$kept_thread"
  printf '{"decision":{}}\n' > "$home/state/ext-outbox/$(printf '2%.0s' $(seq 1 64)).followup.9.progress.json"

  start=$(date +%s)
  out=$(home_env "$home" "$POLL" 2>/dev/null)
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 0 "$rc" "the poll must finish"
  assert_contains "$out" "ext-request $slug" "the queued offer must be claimed"
  assert_present "$offered" "a successful poll must claim the offer"
  [ "$elapsed" -lt 25 ] \
    || fail "the retention prune must finish inside the watcher's 30s check timeout, took ${elapsed}s"

  assert_absent "$stale" "a record past the window must expire"
  assert_absent "$no_recorded" "a record with no recorded_at must expire on its mtime"
  assert_absent "$old_marker" "a retired generation's old marker must expire"
  assert_absent "$old_thread" "a thread record with no surviving record must expire"
  assert_present "$kept_thread" "a thread record with a live record left must stay"
  assert_present "$fresh_recorded" "recorded_at decides over a newer file mtime"
  assert_present "$young_mtime" "a young mtime must survive the window"
  assert_present "$pinned" "a request still waiting in the inbox pins its records"
  assert_present "$fresh_marker" "a fresh marker must never be pruned"

  # The prune is rate-limited, so a poll inside the interval leaves new work
  # for the next due pass instead of repeating the walk.
  late="$ctx/$(printf '9%.0s' $(seq 1 64)).json"
  printf '{"request_id":"%s","recorded_at":1}\n' "$RID" > "$late"
  home_env "$home" "$POLL" >/dev/null
  assert_present "$late" "a poll inside the prune interval must not prune again"
  home_env "$home" env FM_EXT_PRUNE_INTERVAL_SECS=0 "$POLL" >/dev/null
  assert_absent "$late" "the next due prune must remove the expired record"
  pass "55 retention completes inside the poll, drops exactly the expired records, and never starves the claim"
}

test_48_discord_splitter_boundaries
test_49_split_plan_survives_restart
test_50_discord_splitter_properties
test_51_delivery_survives_a_long_sweep
test_52_thread_record_writes_are_serialized
test_53_delivery_receipt_carries_queue_times
test_54_pending_skips_terminal_markers
test_55_retention_prune_completes_without_starving_the_claim
echo "all fm-ext-bridge tests passed"
