#!/usr/bin/env bash
# Behavior tests for asking the captain a choice on the local Communication
# Officer bridge: bin/fm-ext-ask.sh (hold, decision file, post) and the choice
# guard of bin/fm-ext-emit.sh (refuse choice-shaped text without buttons, the
# --no-buttons escape). Hermetic: no Discord network, no gateway process. The
# hold test needs tasks-axi and skips with a printed reason without it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
JQ_DIR=$(command -v jq 2>/dev/null) && JQ_DIR=$(dirname "$JQ_DIR") || JQ_DIR=
[ -n "$JQ_DIR" ] && BASE_PATH="$JQ_DIR:$BASE_PATH"
TMP_ROOT=$(fm_test_tmproot fm-ext-ask)

INTAKE="$ROOT/bin/fm-ext-intake.sh"
EMIT="$ROOT/bin/fm-ext-emit.sh"
ASK="$ROOT/bin/fm-ext-ask.sh"

GUILD=111111111111111111
CHANNEL=222222222222222222
CAPTAIN=555555555555555555
REQUEST_MESSAGE=444444444444444444
RID="discord:$GUILD:$CHANNEL:$CHANNEL:$REQUEST_MESSAGE"
TASK=route-fix

setup_home() {
  local home=$1
  mkdir -p "$home/config" "$home/state"
  : > "$home/config/ext-bridge"
  printf 'test-secret\n' > "$home/config/ext-secret"
  chmod 600 "$home/config/ext-secret"
  printf '%s\n' "$GUILD:$CHANNEL:$CAPTAIN" > "$home/config/ext-allowlist"
  fm_fakebin "$home" >/dev/null
  printf 'what needs me?' > "$home/request.txt"
  home_env "$home" "$INTAKE" --request-id "$RID" \
    --guild-id "$GUILD" --channel-id "$CHANNEL" --thread-id "$CHANNEL" \
    --message-id "$REQUEST_MESSAGE" --author "$CAPTAIN" \
    --secret-file "$home/config/ext-secret" --text-file "$home/request.txt" \
    --no-wake >/dev/null || fail "the request fixture was refused"
}

home_env() {
  local home=$1
  shift
  PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$@"
}

payload_of() {
  local home=$1 kind=$2 generation=$3 f
  for f in "$home"/state/ext-outbox/*."$kind.$generation.json"; do break; done
  [ -f "$f" ] || fail "no $kind payload for generation $generation"
  printf '%s\n' "$f"
}

# emit_text <home> <generation> <text> [extra emit args...]; sets OUT and RC.
emit_text() {
  local home=$1 generation=$2 text=$3
  shift 3
  printf '%s' "$text" > "$home/post.txt"
  OUT=$(home_env "$home" "$EMIT" --request-id "$RID" --kind answer --generation "$generation" \
    --text-file "$home/post.txt" "$@" 2>&1)
  RC=$?
}

CHOICE=$'Which route should the fix take?\n1. North\n2. South\nReply with the number.'
STATUS_LIST=$'Where things stand:\n1. Ingest finished\n2. Eval running\n3. Report queued\nReply with the number if you want details on one.'

# --- 1. fm-ext-ask holds, writes the decision, and posts matching buttons ---

test_1_ask_holds_and_posts_buttons_in_text_order() {
  local home=$TMP_ROOT/c1 slug payload show
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: 1 needs tasks-axi for the captain-call board"; return 0; }
  BASE_PATH="$(dirname "$(command -v tasks-axi)"):$BASE_PATH"
  setup_home "$home"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  mkdir -p "$home/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  ln -sf "$(command -v tasks-axi)" "$home/fakebin/tasks-axi"
  fm_fake_exit0 "$home/fakebin" treehouse no-mistakes gh gh-axi
  printf 'The fix can go two ways.' > "$home/body.txt"
  printf 'North takes less time; South keeps the existing API.' > "$home/explanation.txt"

  slug=$(home_env "$home" "$ASK" --request-id "$RID" --kind followup --generation 1 \
    --task "$TASK" --title "Pick the route" --repo sample --reason "route pending" --mode "done" \
    --text-file "$home/body.txt" --explanation-file "$home/explanation.txt" \
    --option "North" --recommended --option "South" --option "Merge it" \
    --option "Hold" --confirm) || fail "fm-ext-ask refused a valid choice"
  [ -n "$slug" ] || fail "fm-ext-ask printed no slug"

  show=$(cd "$home" && PATH="$home/fakebin:$BASE_PATH" tasks-axi show "$TASK" --full)
  assert_contains "$show" "route pending" "the hold reason was not recorded"
  home_env "$home" "$ROOT/bin/fm-captain-hold.sh" open "$TASK" >/dev/null \
    || fail "the call is not held open for the captain"

  payload=$(payload_of "$home" followup 1)
  jq -e --arg key "hold:$TASK" '.thread_state == "needs-you"
    and .decision.key == $key and .decision.mode == "done"
    and ([.decision.options[] | .id] == [1,2,3,4])
    and ([.decision.options[] | .label] == ["⭐ North","South","Merge it","Hold"])
    and ([.decision.options[] | .confirm] == [false,false,true,true])
    and .decision.options[0].recommended == true
    and .decision.sections == {
      "question":"The fix can go two ways.",
      "explanation":"North takes less time; South keeps the existing API.",
      "options":"1. ⭐ North\n2. South\n3. Merge it\n4. Hold",
      "cue":"Tap a button, or reply with the number.",
      "structured":true
    }' "$payload" >/dev/null \
    || fail "wrong decision block or structured post sections: $(jq -c .decision "$payload")"
  # The numbered lines in the text follow the buttons, label for label.
  jq -r '.text' "$payload" | grep -E '^[0-9]+\. ' | sed -E 's/^[0-9]+\. //' > "$home/text-labels"
  jq -r '.decision.options[].label' "$payload" > "$home/button-labels"
  diff "$home/text-labels" "$home/button-labels" >/dev/null \
    || fail "text options and buttons differ: $(cat "$home/text-labels") vs $(cat "$home/button-labels")"
  jq -r '.text' "$payload" | grep -n -E '^[0-9]+\. ' | cut -d: -f2 | cut -d. -f1 | paste -sd, - \
    | grep -qx '1,2,3,4' || fail "text option numbers are not 1..4 in order"
  jq -e '.text | startswith("The fix can go two ways.")' "$payload" >/dev/null \
    || fail "the post text lost its body"
  assert_not_contains "$(jq -r .text "$payload")" "$TASK" "the task id leaked into the text"

  # A repeat of the same identity is a no-op; a refresh with a new generation re-holds cleanly.
  home_env "$home" "$ASK" --request-id "$RID" --kind followup --generation 1 \
    --task "$TASK" --reason "route pending" --mode "done" --text-file "$home/body.txt" \
    --option "North" --option "South" >/dev/null || fail "an exact repeat must succeed"
  home_env "$home" "$ASK" --request-id "$RID" --kind followup --generation 2 \
    --task "$TASK" --reason "still pending" --mode "done" --text-file "$home/body.txt" \
    --option "North" --option "South" >/dev/null || fail "refreshing an active hold must succeed"
  jq -e '.decision.options | length == 2' "$(payload_of "$home" followup 2)" >/dev/null \
    || fail "the refreshed post lost its buttons"
  # A choice post may also retitle the thread it lands in.
  home_env "$home" "$ASK" --request-id "$RID" --kind followup --generation 3 \
    --task "$TASK" --reason "still pending" --mode "done" --text-file "$home/body.txt" \
    --option "North" --option "South" --thread-retitle "InfoConnect · route decision" >/dev/null \
    || fail "a retitle on a choice post must pass through to the emit"
  jq -e '.thread_retitle == "InfoConnect · route decision" and .thread_state == "needs-you"' \
    "$(payload_of "$home" followup 3)" >/dev/null || fail "the choice post lost its retitle"
  pass "1 fm-ext-ask holds the call, writes the decision, and posts buttons that match the numbered text"
}

# --- 2. mode default and refusals before any hold ---

test_2_mode_is_required_and_pre_hold_refusals() {
  local home=$TMP_ROOT/c2 out rc show
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: 2 needs tasks-axi for the captain-call board"; return 0; }
  BASE_PATH="$(dirname "$(command -v tasks-axi)"):$BASE_PATH"
  setup_home "$home"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  mkdir -p "$home/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  ln -sf "$(command -v tasks-axi)" "$home/fakebin/tasks-axi"
  fm_fake_exit0 "$home/fakebin" treehouse no-mistakes gh gh-axi
  printf 'Pick one.' > "$home/body.txt"

  # No default mode: a missing --mode refuses before any hold or post.
  out=$(home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 1 \
    --task no-mode --title "No mode" --repo sample --reason "needs a call" \
    --text-file "$home/body.txt" --option "A" --option "B" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "ask accepted a missing --mode"
  assert_contains "$out" "--mode is required" "the refusal must name --mode"
  assert_contains "$out" "release = lift the hold" "the refusal must explain done and release"
  if home_env "$home" "$ROOT/bin/fm-captain-hold.sh" open no-mode >/dev/null 2>&1; then
    fail "a refused ask must not leave a hold behind"
  fi
  if out=$(home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 1 \
    --task no-mode --title "No mode" --repo sample --reason "needs a call" --mode close \
    --text-file "$home/body.txt" --option "A" --option "B" 2>&1); then
    fail "ask accepted an unknown mode"
  fi

  home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 2 \
    --task idle-call --title "Idle call" --repo sample --reason "needs a call" --mode "done" \
    --text-file "$home/body.txt" --option "A" --option "B" >/dev/null \
    || fail "ask refused a done-mode choice"
  jq -e '.decision.mode == "done"' "$(payload_of "$home" answer 2)" >/dev/null \
    || fail "--mode done must reach the decision block"

  # A held, queued ship task has no worker metadata yet and must stay open.
  (cd "$home" && PATH="$home/fakebin:$BASE_PATH" tasks-axi add queued-ship "Queued ship" --repo sample >/dev/null) \
    || fail "could not create the queued ship task"
  [ ! -e "$home/state/queued-ship.meta" ] || fail "fixture must have no worker metadata"
  home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 3 \
    --task queued-ship --reason "build waits on a call" --mode release \
    --text-file "$home/body.txt" --option "North" --option "South" >/dev/null \
    || fail "ask refused a release-mode choice on a queued ship"
  jq -e '.decision.mode == "release"' "$(payload_of "$home" answer 3)" >/dev/null \
    || fail "--mode release must reach the decision block"
  printf '%s\t%s\t%s\t%s\n' queued-ship "North" "1. North" release \
    | home_env "$home" "$ROOT/bin/fm-captain-hold.sh" answers --source "test button click" >/dev/null \
    || fail "recording the release answer failed"
  show=$(cd "$home" && PATH="$home/fakebin:$BASE_PATH" tasks-axi show queued-ship --full)
  assert_contains "$show" "state: queued" "a release answer must leave the queued ship open"
  assert_contains "$show" "held: no" "a release answer must lift the hold"
  if home_env "$home" "$ROOT/bin/fm-captain-hold.sh" open queued-ship >/dev/null 2>&1; then
    fail "the hold must be lifted after a release answer"
  fi

  printf 'Pick for idle-leak.' > "$home/leak.txt"
  out=$(home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 4 \
    --task idle-leak --title "Leaky" --repo sample --reason "needs a call" --mode "done" \
    --text-file "$home/leak.txt" --option "A" --option "B" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "ask accepted text that names the task id"
  assert_contains "$out" "task id" "the refusal must say why"
  if home_env "$home" "$ROOT/bin/fm-captain-hold.sh" open idle-leak >/dev/null 2>&1; then
    fail "a refused ask must not leave a hold behind"
  fi
  out=$(home_env "$home" "$ASK" --request-id "$RID" --kind answer --generation 5 \
    --task idle-six --title "Six" --repo sample --reason "needs a call" --mode "done" \
    --text-file "$home/body.txt" --option a --option b --option c --option d --option e --option f 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "ask accepted six options"
  pass "2 --mode is required, release keeps a held queued ship open, and leaking text or too many options are refused before holding"
}

# --- 3. the emit guard ---

test_3_emit_refuses_a_choice_without_buttons() {
  local home=$TMP_ROOT/c3
  setup_home "$home"
  emit_text "$home" 1 "$CHOICE"
  [ "$RC" -ne 0 ] || fail "emit accepted a choice-shaped post without buttons"
  assert_contains "$OUT" "fm-ext-ask.sh" "the refusal must name fm-ext-ask"
  ls "$home"/state/ext-outbox/*.answer.1.json >/dev/null 2>&1 && fail "a refused choice must publish nothing"

  emit_text "$home" 2 $'Pick one of these:\nA1. keep it\nB2. drop it'
  [ "$RC" -ne 0 ] || fail "emit accepted coded option lines with a cue"
  emit_text "$home" 3 $'Reply to this with the code.'
  [ "$RC" -ne 0 ] || fail "emit accepted a bare reply-with-the-code line"
  pass "3 emit refuses a choice-shaped post without a decision file and names fm-ext-ask"
}

test_4_no_buttons_posts_a_deliberate_plain_list() {
  local home=$TMP_ROOT/c4
  setup_home "$home"
  emit_text "$home" 1 "$STATUS_LIST"
  [ "$RC" -ne 0 ] || fail "a status list with a reply cue should be refused without --no-buttons"
  emit_text "$home" 2 "$STATUS_LIST" --no-buttons "status list, not a choice"
  [ "$RC" -eq 0 ] || fail "--no-buttons must let the list through: $OUT"
  jq -e '.no_buttons_reason == "status list, not a choice" and (has("decision") | not)' \
    "$(payload_of "$home" answer 2)" >/dev/null || fail "the reason was not recorded in the payload"
  emit_text "$home" 3 "$STATUS_LIST" --no-buttons ""
  [ "$RC" -ne 0 ] || fail "--no-buttons needs a reason"
  emit_text "$home" 4 "$STATUS_LIST" --no-buttons "x" --decision-file "$home/none.json"
  [ "$RC" -ne 0 ] || fail "--no-buttons must not combine with a decision file"
  pass "4 --no-buttons posts a plain list and records its reason"
}

test_5_ordinary_text_is_unaffected() {
  local home=$TMP_ROOT/c5 text generation=0
  setup_home "$home"
  for text in \
    $'Two jobs are running.\n1. Ingest finished\n2. Eval running\nThe report lands tonight.' \
    'All 12 tests passed. 5 files changed, 3 added.' \
    'Say all 3 tests passed' \
    'PR 562 merged; 3 of 5 cases pass' \
    'steps 1, 2 and 3 are done' \
    $'Options:\n1. Only one possible route.' \
    $'1. First finding\n2. Second finding'; do
    generation=$((generation + 1))
    emit_text "$home" "$generation" "$text"
    [ "$RC" -eq 0 ] || fail "ordinary text triggered the choice guard: $text: $OUT"
  done
  jq -e 'has("no_buttons_reason") | not' "$(payload_of "$home" answer 1)" >/dev/null \
    || fail "a normal post must not carry a no-buttons reason"
  pass "5 status prose and numbered lists without a choice cue or heading post unchanged"
}

test_6_choice_with_a_decision_file_is_unaffected() {
  local home=$TMP_ROOT/c6
  setup_home "$home"
  fm_write_meta "$home/state/$TASK.meta" "window=sess:fm-$TASK" "kind=ship"
  printf 'needs-decision [key=route]: pick a route\n' >> "$home/state/$TASK.status"
  printf '{"key":"key:%s:route","options":[{"label":"North"},{"label":"South"}]}' "$TASK" > "$home/decision.json"
  emit_text "$home" 1 "$CHOICE" --decision-file "$home/decision.json"
  [ "$RC" -eq 0 ] || fail "a choice with a decision file must post: $OUT"
  jq -e '.decision.options | length == 2' "$(payload_of "$home" answer 1)" >/dev/null \
    || fail "the decision block is missing"
  pass "6 a choice posted with a decision file is unaffected by the guard"
}

test_7_settled_ask_retries_preserve_state() {
  local home=$TMP_ROOT/c7 kind mode task generation=0 slug payload out rc
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: 7 needs tasks-axi for the captain-call board"; return 0; }
  BASE_PATH="$(dirname "$(command -v tasks-axi)"):$BASE_PATH"
  setup_home "$home"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  mkdir -p "$home/data"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  ln -sf "$(command -v tasks-axi)" "$home/fakebin/tasks-axi"
  fm_fake_exit0 "$home/fakebin" treehouse no-mistakes gh gh-axi
  printf 'Pick a route.' > "$home/body.txt"
  for kind in answer followup final; do
    for mode in "done" release; do
      generation=$((generation + 1))
      task="retry-$kind-$mode"
      slug=$(home_env "$home" "$ASK" --request-id "$RID" --kind "$kind" --generation "$generation" \
        --task "$task" --title "Pick route" --repo sample --reason "needs a call" --mode "$mode" \
        --text-file "$home/body.txt" --option "North" --option "South") || fail "initial $kind/$mode ask failed"
      payload=$(payload_of "$home" "$kind" "$generation")
      printf '%s\t%s\t%s\t%s\n' "$task" "North" "1. North" "$mode" \
        | home_env "$home" "$ROOT/bin/fm-captain-hold.sh" answers --source "test button click" >/dev/null \
        || fail "settling $kind/$mode failed"
      cp "$home/data/backlog.md" "$home/backlog-before"
      cp "$payload" "$home/payload-before"
      out=$(home_env "$home" "$ASK" --request-id "$RID" --kind "$kind" --generation "$generation" \
        --task "$task" --reason "retry pending" --mode "$mode" --text-file "$home/body.txt" \
        --option "North" --option "South") || fail "payload retry of $kind/$mode failed"
      [ "$out" = "$slug" ] || fail "payload retry changed slug"
      cmp "$payload" "$home/payload-before" || fail "retry changed the existing payload"
      cmp "$home/data/backlog.md" "$home/backlog-before" || fail "payload retry mutated the settled task"
      printf '{}\n' > "${payload%.json}.posting"
      chmod 600 "${payload%.json}.posting"
      out=$(home_env "$home" "$ASK" --request-id "$RID" --kind "$kind" --generation "$generation" \
        --task "$task" --reason "retry pending" --mode "$mode" --text-file "$home/body.txt" \
        --option "North" --option "South" 2>&1)
      rc=$?
      [ "$rc" -ne 0 ] || fail "mid-delivery $kind/$mode retry succeeded"
      assert_contains "$out" "mid-delivery" "retry must preserve emit's posting refusal"
      cmp "$home/data/backlog.md" "$home/backlog-before" || fail "posting retry mutated the settled task"
      rm "$payload"
      if out=$(home_env "$home" "$ASK" --request-id "$RID" --kind "$kind" --generation "$generation" \
        --task "$task" --reason "retry pending" --mode "$mode" --text-file "$home/body.txt" \
        --option "North" --option "South" 2>&1); then
        fail "posting-only $kind/$mode retry succeeded"
      fi
      assert_contains "$out" "mid-delivery" "posting-only retry must preserve emit's refusal"
      cmp "$home/data/backlog.md" "$home/backlog-before" || fail "posting-only retry mutated the settled task"
      printf '{}\n' > "${payload%.json}.receipt.json"
      chmod 600 "${payload%.json}.receipt.json"
      out=$(home_env "$home" "$ASK" --request-id "$RID" --kind "$kind" --generation "$generation" \
        --task "$task" --reason "retry pending" --mode "$mode" --text-file "$home/body.txt" \
        --option "North" --option "South") || fail "receipt must beat posting for $kind/$mode"
      [ "$out" = "$slug" ] || fail "receipt retry changed slug"
      cmp "$home/data/backlog.md" "$home/backlog-before" || fail "receipt retry mutated the settled task"
      [ ! -e "$payload" ] || fail "receipt retry republished the ask"
      rm "${payload%.json}.posting"
      home_env "$home" "$ASK" --request-id "$RID" --kind "$kind" --generation "$generation" \
        --task "$task" --reason "retry pending" --mode "$mode" --text-file "$home/body.txt" \
        --option "North" --option "South" >/dev/null || fail "receipt-only retry failed"
      cmp "$home/data/backlog.md" "$home/backlog-before" || fail "receipt-only retry mutated the settled task"
    done
  done
  pass "7 settled asks preserve task state across payload, posting, and receipt retries"
}

test_8_choice_cues_match_whole_words() {
  local home=$TMP_ROOT/c8 text generation=0
  setup_home "$home"
  for text in \
    $'1. Build passed\n2. Tests passed\nI will send the report after optional checks finish.' \
    $'1. Build passed\n2. Tests passed\nThe types of options are documented.' \
    $'1. Build passed\n2. Tests passed\nWe will send the decoded report.' \
    $'1. Build passed\n2. Tests passed\nWe will send the renumbered report.' \
    'Reply with the newsletter attached.' \
    'Reply without the number.' \
    'Preply with the number.' \
    'Reply using the codeset.' \
    $'1. Build passed\n2. Tests passed\nSend the choicescript tomorrow.' \
    $'1. Build passed\n2. Tests passed\nWhich ones passed?'; do
    generation=$((generation + 1))
    emit_text "$home" "$generation" "$text"
    [ "$RC" -eq 0 ] || fail "ordinary words triggered the choice guard: $text: $OUT"
  done
  for text in \
    $'1. North\n2. South\nSend an OPTION.' \
    $'1. North\n2. South\nWhich option?' \
    $'1. North\n2. South\nWhich options?' \
    $'1. North\n2. South\nChoose one.' \
    'Reply using a LETTER.' \
    'Reply with the code.'; do
    generation=$((generation + 1))
    emit_text "$home" "$generation" "$text"
    [ "$RC" -ne 0 ] || fail "whole-word choice cue bypassed the guard: $text"
    assert_contains "$OUT" "fm-ext-ask.sh" "choice refusal must name ask"
  done
  pass "8 cue verbs and nouns match whole words while genuine choices remain guarded"
}

test_9_plural_choice_cues_require_buttons() {
  local home=$TMP_ROOT/c9 kind noun cue text out rc generation=0
  setup_home "$home"
  for kind in answer followup final; do
    for noun in options choices numbers codes letters; do
      for cue in "Choose from these $noun:" "Reply using the $noun." "Reply with the $noun."; do
        generation=$((generation + 1))
        case "$cue" in
          Choose*) text=$(printf '%s\n1. Merge\n2. Hold' "$cue") ;;
          *) text=$cue ;;
        esac
        printf '%s' "$text" > "$home/post.txt"
        out=$(home_env "$home" "$EMIT" --request-id "$RID" --kind "$kind" --generation "$generation" \
          --text-file "$home/post.txt" 2>&1)
        rc=$?
        [ "$rc" -ne 0 ] || fail "plural $kind choice bypassed the guard: $text"
        assert_contains "$out" "fm-ext-ask.sh" "plural choice refusal must name ask"
        if compgen -G "$home/state/ext-outbox/*.$kind.$generation.json" >/dev/null; then
          fail "refused plural choice published a payload"
        fi
      done
    done
  done
  pass "9 plural options, choices, numbers, codes, and letters require buttons for every guarded post kind"
}

test_10_digit_choice_cues_and_headings_require_buttons() {
  local home=$TMP_ROOT/c10 text generation=0
  setup_home "$home"
  for text in \
    $'Options:\n1. **Restart only the eval service on today\'s production build** ... (Recommended)\n2. Report only the search-only retrieval scores we already have ...\n3. Wait until tomorrow.\n\nReply 1, 2 or 3.' \
    $'Options:\n1. Keep them here (recommended, already running).\n2. Keep them here, but run their heavier live tests ...\n3. Fix the Boat second mate first ...\n\nReply 2 or 3 if you want either. 1 needs nothing.' \
    $'**Your call:**\n1. Restart the service.\n2. Wait until tomorrow.\n3. Skip this change.' \
    $'1. North\n2. South\nReply 1, 2 or 3.' \
    $'1. North\n2. South\nPick 2 or 3.' \
    $'1. North\n2. South\nChoose 1/2.' \
    $'1. North\n2. South\nSelect 1 or 2.' \
    $'1. North\n2. South\nSay 1 or 2.' \
    'Reply 1 or 2.'; do
    generation=$((generation + 1))
    emit_text "$home" "$generation" "$text"
    [ "$RC" -ne 0 ] || fail "choice escaped without buttons: $text"
    assert_contains "$OUT" "fm-ext-ask.sh" "choice refusal must name ask"
    emit_text "$home" "$generation" "$text" --no-buttons "deliberate plain choice list"
    [ "$RC" -eq 0 ] || fail "--no-buttons did not allow a deliberate plain list: $OUT"
    jq -e '.no_buttons_reason == "deliberate plain choice list"' \
      "$(payload_of "$home" answer "$generation")" >/dev/null \
      || fail "--no-buttons reason was not recorded for: $text"
  done
  pass "10 digit choice cues and choice headings require buttons unless --no-buttons is explicit"
}

test_11_bold_headings_allow_colons_inside_or_outside() {
  local home=$TMP_ROOT/c11 kind heading marker title text out rc generation=0
  setup_home "$home"
  for kind in answer followup final; do
    for heading in Option Options 'Your call' Choose; do
      for marker in '**' '__'; do
        for title in "$marker$heading:$marker" "$marker$heading$marker:" "$marker$heading$marker"; do
          generation=$((generation + 1))
          text=$(printf '%s\n1. North\n2. South' "$title")
          printf '%s' "$text" > "$home/post.txt"
          out=$(home_env "$home" "$EMIT" --request-id "$RID" --kind "$kind" --generation "$generation" \
            --text-file "$home/post.txt" 2>&1)
          rc=$?
          [ "$rc" -ne 0 ] || fail "$kind choice bypassed the guard: $title"
          assert_contains "$out" "fm-ext-ask.sh" "heading refusal must name ask"
          if compgen -G "$home/state/ext-outbox/*.$kind.$generation.json" >/dev/null; then
            fail "refused heading choice published a payload"
          fi
          out=$(home_env "$home" "$EMIT" --request-id "$RID" --kind "$kind" --generation "$generation" \
            --text-file "$home/post.txt" --no-buttons 'deliberate plain choice list' 2>&1)
          rc=$?
          [ "$rc" -eq 0 ] || fail "--no-buttons refused $title: $out"
          jq -e '.no_buttons_reason == "deliberate plain choice list"' \
            "$(payload_of "$home" "$kind" "$generation")" >/dev/null \
            || fail "heading escape reason was not recorded"
        done
      done
    done
  done
  pass "11 bold choice headings require buttons with colons inside, outside, or omitted"
}

test_1_ask_holds_and_posts_buttons_in_text_order
test_2_mode_is_required_and_pre_hold_refusals
test_3_emit_refuses_a_choice_without_buttons
test_4_no_buttons_posts_a_deliberate_plain_list
test_5_ordinary_text_is_unaffected
test_6_choice_with_a_decision_file_is_unaffected
test_7_settled_ask_retries_preserve_state
test_8_choice_cues_match_whole_words
test_9_plural_choice_cues_require_buttons
test_10_digit_choice_cues_and_headings_require_buttons
test_11_bold_headings_allow_colons_inside_or_outside
