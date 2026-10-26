#!/usr/bin/env bash
# fm-ext-inbox removal: the request file leaves the inbox only on a recorded
# delivery disposition.
#
#   a published emit is not a delivery, so a payload-only request survives;
#   a refused / mid-delivery / terminally failed newest generation survives;
#   a true `"ok": true` receipt clears exactly its own slug;
#   a missing receipt refuses loudly instead of passing silently;
#   a pure acknowledgement clears on its recorded no-reply disposition;
#   a long-running request clears on its linked task record;
#   the real emit + outbox receipt path clears only after the receipt lands.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-ext-lib.sh
. "$ROOT/bin/fm-ext-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] || fail "test needs jq"
BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ext-inbox-remove)

REMOVE="$ROOT/bin/fm-ext-inbox.sh"
EMIT="$ROOT/bin/fm-ext-emit.sh"
OUTBOX="$ROOT/bin/fm-ext-outbox.sh"

GUILD=111111111111111111
CHANNEL=222222222222222222
THREAD=333333333333333333
AUTHOR=555555555555555555
RID="discord:${GUILD}:${CHANNEL}:${THREAD}:444444444444444444"
RID2="discord:${GUILD}:${CHANNEL}:${THREAD}:555555555555555555"
SLUG=$(fm_ext_request_slug "$RID") || fail "could not derive the request slug"
SLUG2=$(fm_ext_request_slug "$RID2") || fail "could not derive the second request slug"

setup_home() {
  local home=$1
  (umask 077; mkdir -p "$home/config" "$home/state" "$home/data")
  : > "$home/config/ext-bridge"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
}

inbox_dir() { printf '%s\n' "$1/state/ext-inbox"; }
outbox_dir() { printf '%s\n' "$1/state/ext-outbox"; }

# write_inbox <home> <slug> <request-id>: publish one safe inbox record.
write_inbox() {
  local home=$1 slug=$2 rid=$3 dir file
  dir=$(inbox_dir "$home")
  (umask 077; mkdir -p "$dir")
  chmod 700 "$dir"
  file="$dir/$slug.json"
  jq -cn --arg rid "$rid" --arg slug "$slug" \
    --arg guild "$GUILD" --arg channel "$CHANNEL" --arg thread "$THREAD" \
    --arg message "${rid##*:}" --arg author "$AUTHOR" \
    '{schema_version:1, request_id:$rid, slug:$slug, platform:"discord",
      source:"hermes-gateway", guild_id:$guild, channel_id:$channel,
      thread_id:$thread, message_id:$message, author:$author,
      authority:"standing", origin:"message", text:"status please",
      recorded_at:1}' > "$file" || fail "could not write inbox record"
  chmod 600 "$file"
}

# write_outbox <home> <basename> <json>: publish one safe outbox artifact.
write_outbox() {
  local home=$1 base=$2 json=$3 dir
  dir=$(outbox_dir "$home")
  (umask 077; mkdir -p "$dir")
  chmod 700 "$dir"
  printf '%s\n' "$json" > "$dir/$base" || fail "could not write $base"
  chmod 600 "$dir/$base"
}

run_remove() {  # <home> [args...]
  local home=$1
  shift
  PATH="$BASE_PATH" FM_HOME="$home" bash "$REMOVE" remove "$@"
}

home_env() {  # <home> <command...>
  local home=$1
  shift
  PATH="$BASE_PATH" FM_HOME="$home" "$@"
}

inbox_present() { [ -f "$(inbox_dir "$1")/$2.json" ]; }

# --- a published emit is not a delivery -------------------------------------

home="$TMP_ROOT/a0"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
if out=$(run_remove "$home" --slug "$SLUG" 2>&1); then
  fail "a request with no delivery record must not clear"
fi
assert_contains "$out" "no delivery receipt" "a bare missing receipt must refuse loudly"
inbox_present "$home" "$SLUG" || fail "a bare missing receipt must leave the inbox record"

home="$TMP_ROOT/a"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
write_outbox "$home" "$SLUG.answer.1.json" \
  "{\"schema_version\":1,\"request_id\":\"$RID\",\"slug\":\"$SLUG\",\"kind\":\"answer\",\"generation\":1}"
if out=$(run_remove "$home" --slug "$SLUG" 2>&1); then
  fail "a payload with no receipt must not clear the inbox"
fi
assert_contains "$out" "no delivery receipt" "missing receipt must refuse loudly"
inbox_present "$home" "$SLUG" || fail "a refused clear must leave the inbox record"

# A terminal failed marker for the newest generation also preserves it.
home="$TMP_ROOT/b"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
write_outbox "$home" "$SLUG.answer.1.json" \
  "{\"schema_version\":1,\"request_id\":\"$RID\",\"slug\":\"$SLUG\",\"kind\":\"answer\",\"generation\":1}"
write_outbox "$home" "$SLUG.answer.1.failed.json" '{"ok":false,"reason":"permanent 4xx"}'
if out=$(run_remove "$home" --slug "$SLUG" 2>&1); then
  fail "a terminally failed delivery must not clear the inbox"
fi
assert_contains "$out" "terminal delivery failure" "failed delivery must name the refusal"
inbox_present "$home" "$SLUG" || fail "a failed delivery must leave the inbox record"

# --- mid-delivery marker without a receipt ---------------------------------

home="$TMP_ROOT/c"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
write_outbox "$home" "$SLUG.answer.1.json" \
  "{\"schema_version\":1,\"request_id\":\"$RID\",\"slug\":\"$SLUG\",\"kind\":\"answer\",\"generation\":1}"
write_outbox "$home" "$SLUG.answer.1.posting" '{"claimed_at":1}'
if out=$(run_remove "$home" --slug "$SLUG" 2>&1); then
  fail "a mid-delivery posting marker must not clear the inbox"
fi
assert_contains "$out" "mid-delivery" "mid-delivery must name the refusal"
inbox_present "$home" "$SLUG" || fail "mid-delivery must leave the inbox record"

# A receipt that does not carry ok:true refuses too.
home="$TMP_ROOT/d"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
write_outbox "$home" "$SLUG.answer.1.receipt.json" '{"ok":false}'
if out=$(run_remove "$home" --slug "$SLUG" 2>&1); then
  fail "a receipt without ok:true must not clear the inbox"
fi
assert_contains "$out" "ok: true" "a false receipt must name the refusal"
inbox_present "$home" "$SLUG" || fail "a false receipt must leave the inbox record"

# --- a true receipt clears exactly its own slug -----------------------------

home="$TMP_ROOT/e"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
write_inbox "$home" "$SLUG2" "$RID2"
write_outbox "$home" "$SLUG.answer.1.receipt.json" \
  '{"ok":true,"discord_message_id":"666666666666666666"}'
run_remove "$home" --slug "$SLUG" >/dev/null || fail "a true receipt must clear its request"
inbox_present "$home" "$SLUG" && fail "the receipted inbox record must be gone"
inbox_present "$home" "$SLUG2" || fail "another request's inbox record must remain"

# --- pure acknowledgment ----------------------------------------------------

home="$TMP_ROOT/f"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
run_remove "$home" --slug "$SLUG" --no-reply --reason "pure acknowledgement" >/dev/null \
  || fail "a pure acknowledgement must clear on its recorded disposition"
inbox_present "$home" "$SLUG" && fail "a pure acknowledgement must clear the inbox record"
disposition="$(outbox_dir "$home")/$SLUG.noreply.json"
assert_present "$disposition" "the no-reply disposition must be recorded"
assert_equals "no-reply" "$(jq -r '.disposition' "$disposition")" "disposition must say no-reply"
assert_equals "pure acknowledgement" "$(jq -r '.reason' "$disposition")" "disposition must carry the reason"
pending_out=$(home_env "$home" bash "$OUTBOX" pending 2>/dev/null) \
  || fail "pending must not fail on a no-reply disposition"
[ -z "$pending_out" ] || fail "a no-reply disposition must not surface as a pending payload: $pending_out"

# --no-reply must not mask a real reply record.
home="$TMP_ROOT/g"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
write_outbox "$home" "$SLUG.answer.1.receipt.json" '{"ok":true}'
if out=$(run_remove "$home" --slug "$SLUG" --no-reply 2>&1); then
  fail "--no-reply must refuse a request that already has delivery records"
fi
assert_contains "$out" "delivery records exist" "--no-reply refusal must name the delivery records"
inbox_present "$home" "$SLUG" || fail "--no-reply refusal must leave the inbox record"

# --- long-running acked work requires its linked task record ----------------

home="$TMP_ROOT/h"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
write_outbox "$home" "$SLUG.ack.1.json" \
  "{\"schema_version\":1,\"request_id\":\"$RID\",\"slug\":\"$SLUG\",\"kind\":\"ack\",\"generation\":1}"
printf 'ext_request=%s\next_request_slug=%s\n' "$RID" "$SLUG" > "$home/state/task-one.meta"
printf 'ext_request=%s\next_request_slug=%s\n' "$RID2" "$SLUG2" > "$home/state/task-two.meta"
if out=$(run_remove "$home" --slug "$SLUG" --task task-two 2>&1); then
  fail "an unlinked task must not clear the inbox"
fi
assert_contains "$out" "does not link this request" "an unlinked task must name the refusal"
inbox_present "$home" "$SLUG" || fail "an unlinked task must leave the inbox record"
run_remove "$home" --slug "$SLUG" --task task-one >/dev/null \
  || fail "a linked task must clear its request"
inbox_present "$home" "$SLUG" && fail "the linked task's inbox record must be gone"

# --- missing inbox record refuses ------------------------------------------

home="$TMP_ROOT/i"
setup_home "$home"
(umask 077; mkdir -p "$home/state/ext-inbox")
if out=$(run_remove "$home" --slug "$SLUG" 2>&1); then
  fail "a missing inbox record must refuse rather than pass silently"
fi
assert_contains "$out" "no safe inbox record" "a missing inbox record must name the refusal"

for kind in ack answer followup final; do
  home="$TMP_ROOT/refused-emit-$kind"
  setup_home "$home"
  write_inbox "$home" "$SLUG" "$RID"
  printf 'Reply for the request.\n' > "$TMP_ROOT/refused-reply.txt"
  home_env "$home" bash "$EMIT" --request-id "$RID" --kind "$kind" --generation 1 \
    --text-file "$TMP_ROOT/refused-reply.txt" >/dev/null \
    || fail "$kind emit must publish before delivery starts"
  home_env "$home" bash "$OUTBOX" begin --slug "$SLUG" --kind "$kind" --generation 1 \
    >/dev/null || fail "$kind delivery must begin"
  if out=$(home_env "$home" bash "$EMIT" --request-id "$RID" --kind "$kind" --generation 1 \
    --text-file "$TMP_ROOT/refused-reply.txt" 2>&1); then
    fail "$kind emit must refuse while delivery has no receipt"
  fi
  assert_contains "$out" "refusing a second emit" "$kind emit must diagnose its refusal"
  inbox_present "$home" "$SLUG" || fail "$kind refused emit must preserve inbox"
  if out=$(run_remove "$home" --slug "$SLUG" 2>&1); then
    fail "$kind removal must refuse after a refused emit"
  fi
  assert_contains "$out" "mid-delivery with no receipt" "$kind removal must diagnose missing confirmation"
  inbox_present "$home" "$SLUG" || fail "$kind removal after refused emit must preserve inbox"
done

# --- real emit then real receipt clears only after delivery -----------------

home="$TMP_ROOT/j"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
printf 'Answer for the request.\n' > "$TMP_ROOT/reply.txt"
home_env "$home" bash "$EMIT" --request-id "$RID" --kind answer --generation 1 \
  --text-file "$TMP_ROOT/reply.txt" >/dev/null || fail "emit must publish the payload"
if out=$(run_remove "$home" --slug "$SLUG" 2>&1); then
  fail "an emitted but undelivered reply must not clear the inbox"
fi
assert_contains "$out" "no delivery receipt" "an undelivered emit must refuse on the missing receipt"
inbox_present "$home" "$SLUG" || fail "an undelivered emit must leave the inbox record"
printf '{"ok":true,"queued_at":1,"picked_at":2,"discord_message_id":"777777777777777777"}\n' \
  > "$TMP_ROOT/receipt.json"
home_env "$home" bash "$OUTBOX" receipt --slug "$SLUG" --kind answer --generation 1 \
  --receipt-file "$TMP_ROOT/receipt.json" >/dev/null || fail "the receipt must be recorded"
run_remove "$home" --slug "$SLUG" >/dev/null \
  || fail "a delivered reply must clear the inbox"
inbox_present "$home" "$SLUG" && fail "the delivered reply's inbox record must be gone"

# --- latest generation decides ---------------------------------------------

home="$TMP_ROOT/k"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
write_outbox "$home" "$SLUG.ack.1.receipt.json" '{"ok":true}'
write_outbox "$home" "$SLUG.final.2.posting" '{"claimed_at":1}'
if out=$(run_remove "$home" --slug "$SLUG" 2>&1); then
  fail "an older receipt must not clear a newer mid-delivery generation"
fi
assert_contains "$out" "mid-delivery" "the newest generation must decide"
inbox_present "$home" "$SLUG" || fail "a newer mid-delivery generation must leave the inbox record"

for delivered_kind in ack answer followup final; do
  for pending_kind in ack answer followup final; do
    [ "$delivered_kind" != "$pending_kind" ] || continue
    for marker in json progress.json posting receipt.json failed.json; do
      for mode in receipt task no-reply; do
        home="$TMP_ROOT/mixed-$delivered_kind-$pending_kind-$marker-$mode"
        setup_home "$home"
        write_inbox "$home" "$SLUG" "$RID"
        write_outbox "$home" "$SLUG.$delivered_kind.1.receipt.json" '{"ok":true}'
        write_outbox "$home" "$SLUG.$pending_kind.1.$marker" '{"ok":false}'
        printf 'ext_request_slug=%s\n' "$SLUG" > "$home/state/task-one.meta"
        args=()
        case "$mode" in
          task) args=(--task task-one) ;;
          no-reply) args=(--no-reply) ;;
        esac
        if [ "$mode" = task ] && { [ "$marker" = json ] || [ "$marker" = progress.json ]; }; then
          run_remove "$home" --slug "$SLUG" "${args[@]}" >/dev/null \
            || fail "linked task must allow queued $pending_kind alongside delivered $delivered_kind"
          inbox_present "$home" "$SLUG" && fail "linked task must clear queued work"
        else
          if out=$(run_remove "$home" --slug "$SLUG" "${args[@]}" 2>&1); then
            fail "$mode must not borrow $delivered_kind receipt for $pending_kind $marker"
          fi
          assert_contains "$out" "refusing to remove" "mixed delivery must refuse loudly"
          inbox_present "$home" "$SLUG" || fail "mixed delivery refusal must preserve inbox"
        fi
      done
    done
  done
done

for kind in ack answer followup final; do
  for mode in receipt task; do
    home="$TMP_ROOT/failed-$kind-$mode"
    setup_home "$home"
    write_inbox "$home" "$SLUG" "$RID"
    write_outbox "$home" "$SLUG.$kind.1.receipt.json" '{"ok":true}'
    write_outbox "$home" "$SLUG.$kind.1.failed.json" '{"ok":false}'
    printf 'ext_request_slug=%s\n' "$SLUG" > "$home/state/task-one.meta"
    args=()
    [ "$mode" != task ] || args=(--task task-one)
    if out=$(run_remove "$home" --slug "$SLUG" "${args[@]}" 2>&1); then
      fail "a receipt must not hide a same-kind terminal failure on $mode removal"
    fi
    assert_contains "$out" "terminal delivery failure" "terminal failure must veto removal"
    inbox_present "$home" "$SLUG" || fail "terminal failure must preserve inbox"
  done
done

home="$TMP_ROOT/all-delivered"
setup_home "$home"
write_inbox "$home" "$SLUG" "$RID"
write_inbox "$home" "$SLUG2" "$RID2"
for kind in ack answer followup final; do
  write_outbox "$home" "$SLUG.$kind.1.failed.json" '{"ok":false}'
  write_outbox "$home" "$SLUG.$kind.2.json" '{}'
  write_outbox "$home" "$SLUG.$kind.2.posting" '{}'
  write_outbox "$home" "$SLUG.$kind.2.progress.json" '{}'
  write_outbox "$home" "$SLUG.$kind.2.receipt.json" '{"ok":true}'
done
run_remove "$home" --slug "$SLUG" >/dev/null || fail "matching receipts must clear all newest kinds"
inbox_present "$home" "$SLUG" && fail "all-delivered request must be removed"
inbox_present "$home" "$SLUG2" || fail "all-delivered removal must preserve another slug"

pass "ext-inbox removal clears only on a recorded delivery disposition"
