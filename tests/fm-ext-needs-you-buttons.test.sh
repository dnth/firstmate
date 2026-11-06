#!/usr/bin/env bash
# Behavior tests for the captain's standing button rules on the local
# Communication Officer bridge:
#   - bin/fm-ext-emit.sh refuses an answer, followup, or final marked
#     --thread-state needs-you unless it carries --decision-file or
#     --no-buttons "<reason>", and bin/fm-ext-open.sh passes both through;
#   - bin/fm-ext-ask.sh refuses two or more options with no --recommended
#     unless --no-recommendation "<reason>" records why none is starred.
# Hermetic: no Discord network, no gateway process. The ask cases need
# tasks-axi for the captain-call board and skip with a printed reason without
# it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ext-needs-you-buttons)

INTAKE="$ROOT/bin/fm-ext-intake.sh"
EMIT="$ROOT/bin/fm-ext-emit.sh"
ASK="$ROOT/bin/fm-ext-ask.sh"
OPEN="$ROOT/bin/fm-ext-open.sh"
HOLD="$ROOT/bin/fm-captain-hold.sh"

GUILD=111111111111111111
CHANNEL=222222222222222222
THREAD=333333333333333333
MESSAGE=444444444444444444
AUTHOR=555555555555555555
RID="discord:${GUILD}:${CHANNEL}:${THREAD}:${MESSAGE}"

setup_home() {
  local home=$1
  mkdir -p "$home/config" "$home/state"
  : > "$home/config/ext-bridge"
  printf '%s\n' "$CHANNEL" > "$home/config/ext-channel"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$AUTHOR" > "$home/config/ext-allowlist"
  fm_fakebin "$home" >/dev/null
  printf 'What needs me?' > "$home/request.txt"
  home_env "$home" "$INTAKE" --request-id "$RID" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$THREAD" \
    --message-id "$MESSAGE" --author "$AUTHOR" \
    --secret-file "$home/config/ext-secret" --text-file "$home/request.txt" \
    --no-wake >/dev/null || fail "the request fixture was refused"
}

setup_board() {
  local home=$1
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  mkdir -p "$home/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  ln -sf "$(command -v tasks-axi)" "$home/fakebin/tasks-axi"
  fm_fake_exit0 "$home/fakebin" treehouse no-mistakes gh gh-axi
}

home_env() {
  local home=$1
  shift
  PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$@"
}

write_text() {
  local file=$1
  shift
  printf '%s' "$*" > "$file"
}

payload_of() {
  local home=$1 kind=$2 generation=$3 f=
  for f in "$home"/state/ext-outbox/*."$kind.$generation.json"; do break; done
  [ -n "$f" ] && [ -f "$f" ] || fail "no $kind payload for generation $generation"
  printf '%s\n' "$f"
}

outbox_count() {
  local f
  set -- "$1"/state/ext-outbox/*.json
  [ -e "$1" ] || { printf '0\n'; return; }
  for f in "$@"; do [ -f "$f" ] && printf 'x\n'; done | grep -c x
}

# emit_as <home> <kind> <generation> <state-or-empty> [extra args...]; sets
# OUT and RC. The text is ordinary prose, so only the needs-you rule can
# refuse it.
emit_as() {
  local home=$1 kind=$2 generation=$3 state=$4 textfile
  shift 4
  textfile="$home/emit-$kind-$generation.txt"
  write_text "$textfile" "Here is where that request stands."
  local args=(--request-id "$RID" --kind "$kind" --generation "$generation" --text-file "$textfile")
  [ -z "$state" ] || args+=(--thread-state "$state")
  OUT=$(home_env "$home" "$EMIT" "${args[@]}" "$@" 2>&1)
  RC=$?
}

open_as() {
  local home=$1 key=$2 state=$3 textfile
  shift 3
  textfile="$home/open-$key.txt"
  write_text "$textfile" "Here is where that tracked item stands."
  OUT=$(home_env "$home" "$OPEN" --key "$key" --thread-title "InfoConnect · $key" \
    --text-file "$textfile" --thread-state "$state" "$@" 2>&1)
  RC=$?
}

open_payload() {
  local home=$1 key=$2 rid slug
  rid=$(home_env "$home" "$OPEN" --key "$key" --lookup 2>/dev/null | head -1) \
    || fail "no recorded open for $key"
  slug=$(printf '%s' "$rid" | sha256sum 2>/dev/null | awk '{print $1}')
  [ -n "$slug" ] || slug=$(printf '%s' "$rid" | shasum -a 256 | awk '{print $1}')
  printf '%s\n' "$home/state/ext-outbox/$slug.answer.1.json"
}

# A worker's open keyed decision in this home's own task status log.
open_decision_key() {
  printf 'needs-decision [key=%s]: pick a route\n' "$2" >> "$1/state/route-fix.status"
}

# decision_file <home> <label-a> <label-b> [--recommended]; echoes its path.
decision_file() {
  local home=$1 a=$2 b=$3 recommended=${4:-} file="$1/decision-$$-${RANDOM}.json"
  jq -cn --arg a "$a" --arg b "$b" --arg recommended "$recommended" \
    '{key: "key:route-fix:north-south", mode: "done",
      options: [{label: $a}, ({label: $b} + (if $recommended == "" then {} else {recommended: true} end))]}' \
    > "$file" || fail "could not write the decision file"
  printf '%s\n' "$file"
}

# --- 1. a needs-you reply must carry buttons or a reason -------------------

test_1_needs_you_replies_need_buttons_or_a_reason() {
  local home=$TMP_ROOT/c1 decision before
  setup_home "$home"
  open_decision_key "$home" north-south

  # A refused post publishes and records nothing at all.
  before=$(outbox_count "$home")
  emit_as "$home" answer 1 needs-you
  [ "$RC" -ne 0 ] || fail "emit posted a needs-you answer with no buttons"
  assert_contains "$OUT" "bin/fm-ext-ask.sh" "the refusal must name the ask script"
  assert_contains "$OUT" "--no-buttons" "the refusal must name the escape"
  [ "$(outbox_count "$home")" = "$before" ] || fail "a refused needs-you answer recorded a payload"
  [ ! -e "$home/state/ext-outbox" ] || [ -z "$(ls -A "$home/state/ext-outbox")" ] \
    || fail "a refused needs-you answer left outbox files behind"

  # --no-buttons records the reason and posts.
  emit_as "$home" answer 1 needs-you --no-buttons "status reminder, no choice asked"
  [ "$RC" -eq 0 ] || fail "emit refused a needs-you answer with --no-buttons: $OUT"
  jq -e '.thread_state == "needs-you"
    and .no_buttons_reason == "status reminder, no choice asked"
    and (has("decision") | not)' "$(payload_of "$home" answer 1)" >/dev/null \
    || fail "the --no-buttons needs-you payload is wrong"

  # A decision file posts the buttons instead.
  decision=$(decision_file "$home" "North" "South")
  emit_as "$home" followup 1 needs-you --decision-file "$decision"
  [ "$RC" -eq 0 ] || fail "emit refused a needs-you followup with --decision-file: $OUT"
  jq -e '.thread_state == "needs-you"
    and .decision.key == "key:route-fix:north-south"
    and ([.decision.options[].label] == ["North","South"])' \
    "$(payload_of "$home" followup 1)" >/dev/null \
    || fail "the decision-file needs-you payload is wrong"

  # An ack marked needs-you asks for nothing and stays exempt.
  emit_as "$home" ack 1 needs-you
  [ "$RC" -eq 0 ] || fail "emit refused a needs-you ack, which asks no choice: $OUT"

  pass "1 needs-you answers, followups, and finals need buttons or a recorded reason"
}

# --- 2. done, none, and unstatted replies are unchanged --------------------

test_2_other_thread_states_are_unaffected() {
  local home=$TMP_ROOT/c2 out
  setup_home "$home"
  emit_as "$home" answer 1 "done"
  [ "$RC" -eq 0 ] || fail "emit refused a done answer: $OUT"
  jq -e '.thread_state == "done" and (has("no_buttons_reason") | not)' \
    "$(payload_of "$home" answer 1)" >/dev/null || fail "the done payload changed"
  emit_as "$home" answer 2 none
  [ "$RC" -eq 0 ] || fail "emit refused a none answer: $OUT"
  emit_as "$home" followup 1 ""
  [ "$RC" -eq 0 ] || fail "emit refused an unstatted followup: $OUT"
  jq -e 'has("thread_state") | not' "$(payload_of "$home" followup 1)" >/dev/null \
    || fail "an unstatted followup gained a thread state"
  emit_as "$home" final 1 "done"
  [ "$RC" -eq 0 ] || fail "emit refused a done final: $OUT"
  pass "2 done, none, and unstatted replies post exactly as before"
}

# --- 3. an ask of two or more options needs a starred recommendation -------

test_3_ask_requires_a_recommendation_or_a_reason() {
  local home=$TMP_ROOT/c3 out rc body
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: 3 needs tasks-axi for the captain-call board"; return 0; }
  BASE_PATH="$(dirname "$(command -v tasks-axi)"):$BASE_PATH"
  setup_home "$home"
  setup_board "$home"
  write_text "$home/body.txt" "The fix can go two ways."

  # Refused before any hold or post.
  out=$(home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 1 \
    --task tie-call --title "Tie call" --repo sample --reason "needs a call" --mode "done" \
    --text-file "$home/body.txt" --option "North" --option "South" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "ask accepted two options with no recommendation"
  assert_contains "$out" "--recommended" "the refusal must name --recommended"
  assert_contains "$out" "--no-recommendation" "the refusal must name the escape"
  if home_env "$home" "$HOLD" open tie-call >/dev/null 2>&1; then
    fail "a refused ask must not leave a hold behind"
  fi
  [ ! -e "$home/state/ext-outbox" ] || [ -z "$(ls -A "$home/state/ext-outbox")" ] \
    || fail "a refused ask published a payload"

  # The recorded reason posts the tie and reaches the payload.
  home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 2 \
    --task tie-call --title "Tie call" --repo sample --reason "needs a call" --mode "done" \
    --text-file "$home/body.txt" --option "North" --option "South" \
    --no-recommendation "both routes cost the same" >/dev/null \
    || fail "ask refused a tie with a recorded reason"
  jq -e '.no_recommendation_reason == "both routes cost the same"
    and .decision.options[0].recommended == null
    and .decision.options[0].label == "North"
    and (has("no_buttons_reason") | not)' \
    "$(payload_of "$home" answer 2)" >/dev/null \
    || fail "the no-recommendation reason did not reach the payload"

  # A recommendation still stars the option and records no reason.
  home_env "$home" "$ASK" --request-id "$RID" --kind followup --generation 1 \
    --task star-call --title "Star call" --repo sample --reason "needs a call" --mode "done" \
    --text-file "$home/body.txt" --option "North" --recommended --option "South" >/dev/null \
    || fail "ask refused a recommended choice"
  jq -e '.decision.options[0].recommended == true
    and .decision.options[0].label == "⭐ North"
    and (has("no_recommendation_reason") | not)' \
    "$(payload_of "$home" followup 1)" >/dev/null \
    || fail "the recommended payload changed"

  # A single option needs neither.
  home_env "$home" "$ASK" --request-id "$RID" --kind final --generation 1 \
    --task one-call --title "One call" --repo sample --reason "needs a call" --mode "done" \
    --text-file "$home/body.txt" --option "Only route" >/dev/null \
    || fail "ask refused a single-option choice"
  jq -e '(.decision.options | length) == 1 and .decision.options[0].label == "Only route"
    and (has("no_recommendation_reason") | not)' \
    "$(payload_of "$home" final 1)" >/dev/null || fail "the single-option payload changed"

  # A blank or multi-line reason is refused before holding anything.
  if out=$(home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 3 \
    --task tie-call --reason "needs a call" --mode "done" --text-file "$home/body.txt" \
    --option "North" --option "South" --no-recommendation "" 2>&1); then
    fail "ask accepted an empty --no-recommendation reason"
  fi
  assert_contains "$out" "--no-recommendation needs a reason" "the refusal must name the missing reason"
  if out=$(home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 4 \
    --task tie-call --reason "needs a call" --mode "done" --text-file "$home/body.txt" \
    --option "North" --option "South" --no-recommendation $'two\nlines' 2>&1); then
    fail "ask accepted a multi-line --no-recommendation reason"
  fi
  assert_contains "$out" "one line" "the refusal must say the reason is one line"
  if out=$(home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 5 \
    --task tie-call --reason "needs a call" --mode "done" --text-file "$home/body.txt" \
    --option "North" --recommended --option "South" --no-recommendation "not needed" 2>&1); then
    fail "ask accepted a reason alongside a recommendation"
  fi
  assert_contains "$out" "cannot accompany" "the refusal must say the two flags conflict"

  pass "3 a two-option ask needs a starred recommendation or a recorded reason"
}

# --- 4. an opened needs-you thread carries buttons or a reason -------------

test_4_open_needs_you_passes_buttons_or_a_reason() {
  local home=$TMP_ROOT/c4 decision payload
  setup_home "$home"
  open_decision_key "$home" north-south

  open_as "$home" needs-you-item needs-you
  [ "$RC" -ne 0 ] || fail "open created a needs-you thread with no buttons"
  assert_contains "$OUT" "bin/fm-ext-ask.sh" "the refusal must name the ask script"
  assert_contains "$OUT" "--no-buttons" "the refusal must name the escape"

  open_as "$home" needs-you-item needs-you --no-buttons "tracked item needs attention, no choice"
  [ "$RC" -eq 0 ] || fail "open refused a needs-you thread with --no-buttons: $OUT"
  payload=$(open_payload "$home" needs-you-item)
  jq -e '.thread_state == "needs-you" and .thread_title == "InfoConnect · needs-you-item"
    and .no_buttons_reason == "tracked item needs attention, no choice"' "$payload" >/dev/null \
    || fail "the opened needs-you payload is wrong: $(jq -c . "$payload")"

  decision=$(decision_file "$home" "North" "South")
  open_as "$home" buttoned-item needs-you --decision-file "$decision"
  [ "$RC" -eq 0 ] || fail "open refused a needs-you thread with --decision-file: $OUT"
  payload=$(open_payload "$home" buttoned-item)
  jq -e '.thread_state == "needs-you"
    and .decision.key == "key:route-fix:north-south"
    and ([.decision.options[].label] == ["North","South"])' "$payload" >/dev/null \
    || fail "the opened decision payload is wrong: $(jq -c . "$payload")"

  # An open that marks no needs-you state is unaffected.
  open_as "$home" plain-item none
  [ "$RC" -eq 0 ] || fail "open refused a plain opened thread: $OUT"
  jq -e '.thread_state == "none"' "$(open_payload "$home" plain-item)" >/dev/null \
    || fail "the plain opened payload changed"

  pass "4 an opened needs-you thread carries buttons or a recorded reason"
}

test_1_needs_you_replies_need_buttons_or_a_reason
test_2_other_thread_states_are_unaffected
test_3_ask_requires_a_recommendation_or_a_reason
test_4_open_needs_you_passes_buttons_or_a_reason
