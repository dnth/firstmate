#!/usr/bin/env bash
# fm-send from-firstmate marker for secondmate targets.
#
# A secondmate is itself a firstmate, so a request relayed to it lands in its own
# chat - which the main firstmate never reads (the only channel back is the terse
# status file). fm-send therefore prepends a from-firstmate marker
# (bin/fm-marker-lib.sh) when, and only when, the resolved target is a task
# selector whose meta records kind=secondmate, so the secondmate can recognize
# the request and route its reply via the status path. The marker now travels
# inside the durable inbox record's body (the payload is never typed; only the
# doorbell is). These tests pin that behavior hermetically (stubbed tmux, no
# real agent):
#   1. Exact-id and stable-label kind=secondmate selectors prepend the marker
#      to the recorded steer, never to the typed doorbell.
#   2. Exact-id and stable-label ordinary crewmate selectors stay unmarked.
#   3. Explicit endpoints stay unmarked and typed, with or without local meta.
#   4. The --key path never carries the marker and never enqueues a record.
#   5. Direct captain text stays unmarked, and already-marked text is idempotent.
#   6. The marker is the label plus terminal-safe U+2063 INVISIBLE SEPARATOR.
#   7. An OMP secondmate steer with no native receipt is refused loudly and
#      keeps its marked record and undelivered expectation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-marker)

# A fake tmux that (a) records the literal text of every `send-keys -l` to
# FM_SEND_LOG and (b) renders a captured busy OMP layout whose editable
# composer remains visible after Enter, so a case that asserts nothing was
# typed cannot pass merely because the composer looked unusable.
# display-message yields a numeric cursor_y; the non-OMP path returns an empty
# bordered composer so fm_tmux_composer_state reads "empty" on the first Enter.
# Only the literal (-l) text is logged; Enter retries and --key sends are not.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    elif [ "${1:-}" = Enter ] && [ -n "${FM_SEND_ENTERED:-}" ]; then
      : > "$FM_SEND_ENTERED"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*)
          if [ "${FM_SEND_OMP_BUSY:-0}" = 1 ]; then printf '5\n'; else printf '1\n'; fi
          exit 0 ;;
        *pane_current_command*)
          if [ "${FM_SEND_OMP:-0}" = 1 ]; then printf 'bun\n'; else printf 'fakepane\n'; fi
          exit 0 ;;
        *pane_pid*)
          if [ "${FM_SEND_OMP:-0}" = 1 ]; then printf '4242\n'; else printf 'fakepane\n'; fi
          exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_SEND_OMP_BUSY:-0}" = 1 ]; then
      if [ -f "${FM_SEND_ENTERED:-/nonexistent}" ]; then
        cat "$FM_SEND_OMP_AFTER"
      else
        cat "$FM_SEND_OMP_BEFORE"
      fi
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    if [ "${FM_SEND_OMP:-0}" = 1 ]; then printf 'fm-domain\n'; fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <send-log> -- <fm-send args...>
# Runs fm-send.sh with the stubs on PATH against the given home (which holds
# state/<id>.meta). FM_ROOT_OVERRIDE points at the same non-repo home so
# fm-guard's tangle check stays silent; guard noise goes to stderr (discarded).
# FM_SEND_SETTLE=0 keeps the run fast. Truncates the log first; returns fm-send's
# exit code.
run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  run_send_err "$fb" "$home" "$log" /dev/null "$@"
}

# run_send_err <fakebin> <home> <send-log> <err-file> -- <fm-send args...>
# The same run, keeping fm-send's stderr for the cases that assert its verdict.
run_send_err() {
  local fb=$1 home=$2 log=$3 err=$4; shift 4
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SEND_OMP_BUSY="${FM_SEND_OMP_BUSY:-0}" FM_SEND_OMP="${FM_SEND_OMP:-0}" \
    FM_SEND_ENTERED="${FM_SEND_ENTERED:-}" FM_SEND_OMP_BEFORE="${FM_SEND_OMP_BEFORE:-}" \
    FM_SEND_OMP_AFTER="${FM_SEND_OMP_AFTER:-}" \
    "$SEND" "$@" 2>"$err"
}

# setup_home <name> -> echoes a fresh home dir with an empty state/.
setup_home() {
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

# The exact enqueued text of one inbox record, read through the production
# owner (bin/fm-task-inbox-lib.sh). Command substitution strips trailing
# newlines, so byte-exact trailing assertions read the raw record instead.
record_body() {  # <record-path>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

test_secondmate_target_is_marked() {
  local dir fb log home rc got corr
  dir="$TMP_ROOT/sm"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "fm-domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to a secondmate target should succeed"
  got=$(record_body "$home/state/domain.inbox/001.msg")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=[a-f0-9][a-f0-9]*) : ;;
    *) fail "secondmate send: the recorded steer should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  case "$got" in
    *audit\ the\ build) : ;;
    *) fail "secondmate send lost the request body"$'\n'"$got" ;;

  esac
  case "$(cat "$log")" in
    *"$FM_FROMFIRST_MARK"*) fail "the marker must ride the record, never the typed doorbell" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$got")
  [ -f "$(fm_pending_reply_path "$home/state" "$corr")" ] \
    || fail "marked secondmate send should create a parent pending-reply record"
  pass "fm-send: a kind=secondmate target gets the from-firstmate marker and corr prepended"
}
test_unreceipted_omp_secondmate_steer_preserves_expectation() {
  local dir fb log err home rc got corr rec omp
  dir="$TMP_ROOT/sm-unreceipted"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  err="$dir/send.err"
  home=$(setup_home sm-unreceipted)
  omp="$dir/omp"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$omp"
  chmod +x "$omp"
  omp=$(fm_test_realpath "$omp")
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain" alpha omp
  printf 'omp_bin=%s\nomp_bun=%s\n' "$omp" "$omp" >> "$home/state/domain.meta"
  FM_SEND_OMP=1 run_send_err "$fb" "$home" "$log" "$err" "domain" "queue the steer"; rc=$?
  expect_code 6 "$rc" "an OMP secondmate steer with no native receive adapter must not report success"
  assert_contains "$(cat "$err")" 'omp-native-refused:' \
    "the unreachable OMP secondmate adapter did not produce an explicit refusal"
  [ ! -s "$log" ] || fail "an unreceipted OMP secondmate steer typed into the composer: $(cat "$log")"
  got=$(record_body "$home/state/domain.inbox/001.msg")
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$got")
  [ -n "$corr" ] || fail "a refused OMP secondmate steer lost its durable marked record"
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  [ -f "$rec" ] || fail "a refused OMP secondmate steer discarded its pending-reply expectation"
  [ -z "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "an unreceipted OMP secondmate steer claimed confirmed delivery"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "a refused OMP secondmate steer left its expectation in an unexpected phase"
  pass "fm-send: an unreceipted OMP secondmate steer stays bounded and keeps its expectation undelivered"
}

test_exact_secondmate_task_id_is_marked() {
  local dir fb log home rc got already_marked corr
  dir="$TMP_ROOT/sm-exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-exact)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "domain" "audit the build"; rc=$?
  expect_code 0 "$rc" "send to an exact secondmate task id should succeed"
  got=$(record_body "$home/state/domain.inbox/001.msg")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=[a-f0-9]*) : ;;
    *) fail "exact secondmate send: the recorded steer should be marker+corr+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$got")
  # Resend with the same corr already present: embed is idempotent for that corr.
  already_marked="${FM_FROMFIRST_MARK}corr=${corr} already routed"
  run_send "$fb" "$home" "$log" "domain" "$already_marked"; rc=$?
  expect_code 0 "$rc" "send of already-marked exact-id content should succeed"
  got=$(record_body "$home/state/domain.inbox/002.msg")
  case "$got" in
    "${FM_FROMFIRST_MARK}corr=${corr} already routed") : ;;
    *) fail "exact secondmate send altered already-correlated content"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -tx1)" ;;
  esac
  pass "fm-send: an exact kind=secondmate task id is marked with corr exactly once"
}

test_crewmate_target_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/crew"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home crew)
  fm_write_meta "$home/state/build.meta" \
    "window=sess:fm-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  run_send "$fb" "$home" "$log" "fm-build" "fix the test"; rc=$?
  expect_code 0 "$rc" "send to a stable-label crewmate target should succeed"
  got=$(record_body "$home/state/build.inbox/001.msg")
  [ "$got" = "fix the test" ] \
    || fail "stable-label crewmate send: expected bare recorded text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  run_send "$fb" "$home" "$log" "build" "fix the exact test"; rc=$?
  expect_code 0 "$rc" "send to an exact-id crewmate target should succeed"
  got=$(record_body "$home/state/build.inbox/002.msg")
  [ "$got" = "fix the exact test" ] \
    || fail "exact-id crewmate send: expected bare recorded text, got marker or other"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "fm-send: exact-id and stable-label kind=ship selectors are sent unmarked"
}

test_explicit_window_is_not_marked() {
  local dir fb log home rc got
  dir="$TMP_ROOT/explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home explicit)
  # An explicit endpoint is not a task selector, so even matching secondmate
  # metadata must not make fm-send guess the caller's intent and mark it.
  fm_write_secondmate_meta "$home/state/win.meta" "$home" "other:win"
  run_send "$fb" "$home" "$log" "other:win" "ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with matching meta should succeed"
  got=$(cat "$log")
  [ "$got" = "ping" ] \
    || fail "explicit session:window send with meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"

  home=$(setup_home explicit-no-meta)
  run_send "$fb" "$home" "$log" "outside:window" "outside ping"; rc=$?
  expect_code 0 "$rc" "send to an explicit window with no local meta should succeed"
  got=$(cat "$log")
  [ "$got" = "outside ping" ] \
    || fail "explicit session:window send without meta: expected bare text, got marker"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)"
  pass "fm-send: explicit endpoints stay unmarked with or without local metadata"
}

test_key_path_is_not_marked() {
  local dir fb log home rc
  dir="$TMP_ROOT/key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home key)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  run_send "$fb" "$home" "$log" "fm-domain" --key Escape; rc=$?
  expect_code 0 "$rc" "--key send to a secondmate should succeed"
  [ ! -s "$log" ] \
    || fail "--key path logged a literal send (marker leaked into a keypress)"$'\n'"--- bytes ---"$'\n'"$(od -An -c "$log")"
  [ ! -d "$home/state/domain.inbox" ] \
    || fail "--key path must never enqueue an inbox record"
  pass "fm-send: the --key path carries no marker (no literal text is typed)"
}

test_marker_is_label_plus_invisible_separator() {
  local separator hex
  separator=$(printf '\342\201\243')
  [ "$FM_FROMFIRST_MARK" = "[fm-from-firstmate]$separator" ] \
    || fail "marker is not the expected label + U+2063 sequence"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$FM_FROMFIRST_MARK" | od -An -tx1)"
  hex=$(printf '%s' "$FM_FROMFIRST_MARK" | od -An -tx1 | tr -d ' \n')
  case "$hex" in
    *e281a3) : ;;
    *) fail "marker does not end in UTF-8 U+2063 bytes e2 81 a3; bytes were: $hex" ;;
  esac
  fm_message_from_firstmate "${FM_FROMFIRST_MARK}do the work" \
    || fail "detector should recognize a marked message"
  fm_message_from_firstmate "do the work" \
    && fail "direct captain input must remain unmarked"
  fm_message_from_firstmate "[fm-from-firstmate]do the work" \
    && fail "detector must reject the label without U+2063"
  pass "fm-send: the marker is '[fm-from-firstmate]' + terminal-safe U+2063, while direct captain text stays unmarked"
}

test_marker_transformation_is_idempotent() {
  local once twice
  fm_message_mark_from_firstmate "do the work" once
  fm_message_mark_from_firstmate "$once" twice
  [ "$once" = "$twice" ] \
    || fail "already-marked content was double-prefixed"$'\n'"--- once ---"$'\n'"$(printf '%s' "$once" | od -An -tx1)"$'\n'"--- twice ---"$'\n'"$(printf '%s' "$twice" | od -An -tx1)"
  [ "$once" = "${FM_FROMFIRST_MARK}do the work" ] \
    || fail "marker transformation did not prefix bare content exactly once"
  pass "fm-marker: from-firstmate transformation is idempotent"
}

test_marked_send_preserves_trailing_newlines() {
  local dir fb log home rc payload corr expected actual expected_message
  dir="$TMP_ROOT/sm-trailing-newlines"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_home sm-trailing-newlines)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  payload=$'audit the build\n\n'
  run_send "$fb" "$home" "$log" "domain" "$payload"; rc=$?
  expect_code 0 "$rc" "marked send with trailing newlines should succeed"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  corr=$(fm_pending_reply_extract_corr "$(record_body "$home/state/domain.inbox/001.msg")")
  [ -n "$corr" ] || fail "marked send should embed a corr id"
  fm_pending_reply_embed_corr "$payload" "$corr" expected_message
  expected="$dir/expected.body"
  actual="$dir/actual.body"
  printf '%s' "$expected_message" > "$expected"
  record_body "$home/state/domain.inbox/001.msg" > "$actual"
  cmp -s "$expected" "$actual" \
    || fail "the marked record did not preserve trailing newline bytes exactly"
  pass "fm-send: marked secondmate payload preserves trailing newline bytes in its record"
}

test_secondmate_target_is_marked
test_unreceipted_omp_secondmate_steer_preserves_expectation
test_exact_secondmate_task_id_is_marked
test_crewmate_target_is_not_marked
test_explicit_window_is_not_marked
test_key_path_is_not_marked
test_marker_is_label_plus_invisible_separator
test_marker_transformation_is_idempotent
test_marked_send_preserves_trailing_newlines
