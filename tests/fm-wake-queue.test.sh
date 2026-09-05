#!/usr/bin/env bash
# tests/fm-wake-queue.test.sh - wake-queue losslessness (the queue safety matrix):
# concurrent append/drain, bounded structural enrichment, interruption safety,
# signal catch-up while no watcher runs, stale/check enqueue-before-suppressor
# ordering, atomic double-drain, duplicate collapse, and liveness assertion.
# Nothing is lost and nothing is double-consumed. General watcher/lock liveness
# lives in fm-watcher-lock.test.sh; daemon classification/injection in
# fm-daemon.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-tests)

# Wait briefly for <file> to become non-empty.
wait_for_file_content() {  # <file>
  local file=$1 i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$file" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}


test_concurrent_append_and_drain() {
  local dir state out1 out2 pids i pid count unique malformed sequence generation
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" &
    pids="$pids $!"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent append/drain subprocess failed"
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" 2> "$dir/drain-two.err" || fail "final drain failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out2")
  [ "$count" -eq 40 ] || fail "expected final replay of 40 durable records, got $count"
  malformed=$(awk -F '\t' 'NF && NF != 5 { bad++ } END { print bad + 0 }' "$out2")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' 'NF == 5 { keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$out2")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  [ -s "$state/.wake-queue" ] || fail "concurrent drain consumed records before handling acknowledgement"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/drain-two.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/drain-two.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "final replay omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "concurrent records could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged concurrent records remained queued"
  pass "concurrent append plus drain preserves durable records through acknowledgement"
}

test_signal_catchup_without_running_watcher() {
  local dir state fakebin out drain_out drain_err status_file sequence generation
  dir=$(make_case signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  status_file="$state/task.status"
  # The durable-queue catch-up contract applies to ACTIONABLE wakes (the always-on
  # watcher can absorb no-verb working: notes when the crew is provably working).
  # Use a captain-relevant verb so the wake is surfaced and the catch-up path is
  # tested.
  printf 'blocked: first\n' > "$status_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for first signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print first signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" || fail "drain after first signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "first signal was not queued"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "first signal handling acknowledgement failed"

  printf 'done: second\n' >> "$status_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for second signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "signal written with no watcher was not caught"
  pass "signal written while no watcher runs is caught on next run"
}

test_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stale"
  printf 'idle prompt' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stale.meta"
  # A stale pane sitting on a captain-relevant status is actionable when the crew
  # is not provably working, so give the window one and prime the .seen-* marker
  # to its current signature so the per-poll signal scan does not pre-empt the
  # stale wake with a signal wake.
  printf 'done: ready in branch fm/stale\n' > "$state/stale.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%i:%z:%Fm' "$state/stale.status"); else sig=$(stat -c '%i:%s:%.9Y' "$state/stale.status"); fi
  printf '%s' "$sig" > "$state/.seen-stale_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for stale pane"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not written"
  pass "stale wake is queued before suppressor state is advanced"
}

# Absorb-only-when-provably-working adds a new actionable wake: a non-terminal stale
# whose crew is NOT provably working is surfaced immediately. That new path must keep
# the queue-safety invariant - enqueue the stale wake BEFORE advancing the .stale-*
# suppressor - so a watcher killed between the two never swallows the surfaced finish.
test_not_working_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale-stopped)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (no captain-relevant verb); prime .seen-* so the per-poll
  # signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%i:%z:%Fm' "$state/stopped.status"); else sig=$(stat -c '%i:%s:%.9Y' "$state/stopped.status"); fi
  printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # NOT provably working: no running pipeline, idle pane. (make_case installed the
  # fake fm-crew-state.sh the watcher reads via FM_CREW_STATE_BIN.)
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not surface a not-provably-working stale"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after the immediate stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced after the enqueue"
  unset FM_FAKE_CREW_STATE
  pass "a not-provably-working stale wake is queued before its suppressor is advanced"
}

test_check_output_is_queued() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register queue custom check"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for check output"
  grep -F "check: $check_file: merged: https://example.test/pr/1" "$out" >/dev/null || fail "watcher did not print check wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after check wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/1' >/dev/null || fail "check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not written after queue append"
  pass "registered custom check output is queued before cadence suppression"
}

test_atomic_double_drain() {
  local dir state out1 out2 count1 count2 sequence generation leftover
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" 2> "$dir/drain-one.err" &
  pid1=$!
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" 2> "$dir/drain-two.err" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  count1=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out1")
  count2=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out2")
  [ "$count1" -eq 3 ] && [ "$count2" -eq 3 ] \
    || fail "unacknowledged concurrent drains did not replay all three records"
  cmp -s "$out1" "$out2" || fail "concurrent pre-ack replays were not deterministic"
  [ -s "$state/.wake-queue" ] || fail "concurrent drains consumed records before acknowledgement"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/drain-two.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/drain-two.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "concurrent replay omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "concurrent replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement did not consume replayed records"
  leftover=$(FM_STATE_OVERRIDE="$state" "$DRAIN" | awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "acknowledged records replayed again"
  pass "concurrent drains replay until one post-handling acknowledgement consumes records"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

# The drain runs at the top of every wake-handling turn, so it also asserts
# watcher liveness via fm-guard.sh: a lapsed re-arm chain then surfaces even on a
# plain drain-and-handle turn that runs no other supervision script. It must warn
# when work is in flight with no live watcher, and stay silent right after a
# normal fire from a live watcher with a fresh beacon, so it never false-alarms.
test_drain_asserts_watcher_liveness() {
  local dir state err identity
  dir=$(make_case drain-liveness)
  state="$dir/state"
  err="$dir/drain.err"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || fail "drain failed while asserting liveness"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "drain did not surface the watcher-down banner with work in flight and no live watcher"
  : > "$err"
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
    || fail "could not identify the live watcher fixture"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$DRAIN" >/dev/null 2> "$err" \
    || fail "drain failed with a live watcher and fresh beacon"
  if grep -F 'WATCHER DOWN' "$err" >/dev/null; then
    fail "drain false-alarmed with a live watcher and fresh beacon"
  fi
  pass "drain asserts watcher liveness: warns on a lapse, stays silent for a live watcher with a fresh beacon"
}

test_structural_signal_enrichment_preserves_raw_rows() {
  local dir state out expected actual annotation_count outside perl_bin
  dir=$(make_case enrichment)
  state="$dir/state"
  out="$dir/drain.out"
  expected="$dir/expected.out"
  actual="$dir/actual.out"
  outside="$dir/outside-secret"
  printf 'working: first\n\ndone: latest event\n' > "$state/task.status"
  printf 'working: old turn-end context\n' > "$state/turn-only.status"
  printf 'must-not-be-read\n' > "$outside"
  ln -s "$outside" "$state/escape.status"
  perl_bin=$(command -v perl) || fail "perl is required for safe status reads"
  cat > "$dir/fakebin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -MFcntl=:DEFAULT ]; then
  for arg in "$@"; do
    if [ "$arg" = "${FM_WAKE_ENRICH_SWAP_PATH:-}" ]; then
      rm -f "$arg"
      ln -s "$FM_WAKE_ENRICH_SWAP_TARGET" "$arg"
      break
    fi
  done
fi
exec "$FM_WAKE_ENRICH_REAL_PERL" "$@"
SH
  chmod +x "$dir/fakebin/perl"

  append_wake "$state" signal task.status "signal: $outside" || fail "direct status wake append failed"
  append_wake "$state" signal task.turn-ended "signal: $outside" || fail "coalesced turn-end wake append failed"
  append_wake "$state" signal turn-only.turn-ended "signal: $outside" || fail "bare turn-end wake append failed"
  append_wake "$state" signal escape.status "signal: $outside" || fail "symlink status wake append failed"
  append_wake "$state" signal arbitrary-key "signal: $outside" || fail "non-status signal wake append failed"
  append_wake "$state" check task.check.sh "check: complete payload" || fail "check wake append failed"
  append_wake "$state" stale test:fm-task "stale: test:fm-task" || fail "stale wake append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat wake append failed"

  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_print_deduped "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue" > "$expected"
  if PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_SWAP_PATH="$state/task.status" \
    FM_WAKE_ENRICH_SWAP_TARGET="$outside" FM_WAKE_ENRICH_REAL_PERL="$perl_bin" "$DRAIN" > "$out" 2>/dev/null; then
    fail "structural enrichment drain did not fail closed after the status-file swap"
  fi
  awk -F '\t' 'NF == 5 { print }' "$out" > "$actual"
  cmp -s "$expected" "$actual" || fail "enrichment changed or reordered an authoritative raw row"

  annotation_count=$(grep -c '^wake annotation:' "$out" || true)
  [ "$annotation_count" -eq 1 ] || fail "expected only the unreadable-race-safe status annotation, got $annotation_count"
  if grep -E '^wake annotation:.*: task\.status:' "$out" >/dev/null; then
    fail "replaced status file produced an annotation"
  fi
  grep -F 'latest wake-EVENT observed at drain, not current state; historical / not necessarily the triggering event: turn-only.status:' "$out" >/dev/null \
    || fail "bare turn-end mapping did not carry the historical warning"
  if grep -F 'must-not-be-read' "$out" >/dev/null; then
    fail "drain trusted a payload path or followed an out-of-state status symlink"
  fi
  [ -s "$state/.wake-queue" ] || fail "the failed-closed enrichment consumed durable wake rows"
  pass "structural signal enrichment fails closed on a status-file swap without consuming durable rows"
}

test_enrichment_preserves_all_unread_lines_and_status_file_failures() {
  local dir state out i raw_count expected
  dir=$(make_case complete-enrichment)
  state="$dir/state"
  out="$dir/drain.out"
  awk 'BEGIN { printf "done: "; for (i = 0; i < 20000; i++) printf "x"; printf "\n" }' > "$state/huge.status"
  append_wake "$state" signal huge.status "signal: huge" || fail "huge status wake append failed"
  i=1
  while [ "$i" -le 8 ]; do
    awk -v n="$i" 'BEGIN { printf "working-%d: ", n; for (j = 0; j < 3000; j++) printf "y"; printf "\n" }' > "$state/many-$i.status"
    append_wake "$state" signal "many-$i.status" "signal: many-$i" || fail "many-status wake append failed"
    i=$((i + 1))
  done
  : > "$state/empty.status"
  append_wake "$state" signal empty.status "signal: empty" || fail "empty status wake append failed"
  append_wake "$state" signal missing.status "signal: missing" || fail "missing status wake append failed"
  mkdir "$state/malformed.status"
  append_wake "$state" signal malformed.status "signal: malformed" || fail "malformed status wake append failed"
  printf 'done: unreadable\n' > "$state/unreadable.status"
  chmod 000 "$state/unreadable.status"
  append_wake "$state" signal unreadable.status "signal: unreadable" || fail "unreadable status wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "complete enrichment drain failed"
  raw_count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out")
  [ "$raw_count" -eq 13 ] || fail "missing, unreadable, malformed, empty, or oversized status input hid a raw row"

  expected="wake annotation: latest wake-EVENT observed at drain, not current state: huge.status: $(cat "$state/huge.status")"
  grep -Fx "$expected" "$out" >/dev/null \
    || fail "the oversized unread status line was truncated or omitted"
  i=1
  while [ "$i" -le 8 ]; do
    expected="wake annotation: latest wake-EVENT observed at drain, not current state: many-$i.status: $(cat "$state/many-$i.status")"
    grep -Fx "$expected" "$out" >/dev/null \
      || fail "readable status many-$i was truncated or omitted"
    i=$((i + 1))
  done
  if grep -E '^wake annotation:.*(truncated|omitted)' "$out" >/dev/null; then
    fail "complete unread annotation output still reported dropped content"
  fi
  if grep -E ': (empty|missing|malformed|unreadable)\.status:' "$out" >/dev/null; then
    fail "missing, unreadable, malformed, or empty status file produced an annotation"
  fi
  pass "every readable unread status line is annotated in full while invalid status files preserve their raw wakes"
}

wait_for_file_text() {  # <file> <fixed-text>
  local file=$1 expected=$2 i=0
  while [ "$i" -lt 100 ]; do
    grep -F "$expected" "$file" >/dev/null 2>&1 && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_slow_annotation_does_not_block_append_and_deleted_file_fails_closed() {
  local dir state out1 out2 pid
  dir=$(make_case slow-annotation)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  printf 'done: disappears before bounded read\n' > "$state/slow.status"
  append_wake "$state" signal slow.status "signal: slow" || fail "slow status wake append failed"

  FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_TEST_DELAY=3 "$DRAIN" > "$out1" &
  pid=$!
  wait_for_file_text "$out1" "$(printf '\tsignal\tslow.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "slow drain did not commit its raw row"; }
  printf 'done: appended while first drain annotates\n' > "$state/next.status"
  append_wake "$state" signal next.status "signal: next" || fail "append blocked or failed during annotation"
  kill -0 "$pid" 2>/dev/null || fail "slow annotation finished before the concurrent append proved lock independence"
  rm -f "$state/slow.status"
  if wait "$pid"; then
    fail "deleted status file did not make status presentation fail closed"
  fi
  grep -F "$(printf '\tsignal\tslow.status\t')" "$out1" >/dev/null || fail "deleted status file hid the committed raw row"
  if grep -F ': slow.status:' "$out1" >/dev/null; then
    fail "status deleted during annotation still produced an annotation"
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "follow-up drain after concurrent append failed"
  grep -F "$(printf '\tsignal\tnext.status\t')" "$out2" >/dev/null || fail "concurrent append was not left for the next drain"
  pass "slow annotation releases the append lock and a deleted status file fails closed for retry"
}

test_wake_publish_requires_atomic_recovery_evidence() {
  local dir state fakebin real_mv rc out
  dir=$(make_case wake-publish-recovery-evidence)
  state="$dir/state"
  fakebin="$dir/fakebin"
  real_mv=$(command -v mv) || fail "could not locate mv for recovery publication fixture"
  printf 'pending:handling:existing\n' > "$state/.watcher-down"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "${FM_TEST_PUBLISH_MARKER:-}" ]; then
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_PUBLISH_MARKER="$state/.watcher-down" \
    append_wake "$state" signal task.status "signal: publish failure"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "recovery publication failure allowed wake append to succeed"
  [ "$(cat "$state/.watcher-down")" = 'pending:handling:existing' ] \
    || fail "failed atomic publication erased existing recovery evidence"
  [ ! -s "$state/.wake-queue" ] \
    || fail "wake became durable before its recovery evidence"

  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" \
    append_wake "$state" signal task.status "signal: recovered retry" \
    || fail "wake retry did not publish durable recovery evidence"
  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake retry did not drain"
  grep -F "signal: recovered retry" "$out" >/dev/null \
    || fail "retried wake was not recovered by the durable drain"
  pass "wake append publishes atomic recovery evidence before durable rows"
}

test_legacy_generationless_wake_is_adopted() {
  local dir state row sequence generation
  dir=$(make_case legacy-generationless-wake)
  state="$dir/state"
  row=$(printf '1700000000\t7\tcheck\tlegacy-process-event\tcheck: legacy process-event')
  printf '%s\n' "$row" > "$state/.wake-queue"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "generation-less legacy wake could not be adopted"
  grep -F "$row" "$dir/first.out" >/dev/null \
    || fail "adopted legacy wake was not presented"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/first.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/first.err")
  [ "$sequence" = 7 ] && [ -n "$generation" ] \
    || fail "legacy wake adoption omitted its generation-bound acknowledgement"
  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "pending:handling:$generation" ] \
    || fail "legacy wake was not adopted into durable handling recovery"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay.out" 2> "$dir/replay.err" \
    || fail "unacknowledged adopted wake could not be re-drained"
  grep -F "$row" "$dir/replay.out" >/dev/null \
    || fail "unacknowledged adopted wake was lost"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" \
    || fail "adopted legacy wake could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged legacy wake remained queued"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/after-ack.out" 2> "$dir/after-ack.err" \
    || fail "post-acknowledgement legacy drain failed"
  ! grep -F "$row" "$dir/after-ack.out" >/dev/null \
    || fail "acknowledged legacy wake was consumed more than once"
  pass "wake drain: generation-less legacy wakes are adopted and acknowledged"
}

# Pin the recovery acknowledgement contract from docs/watcher-continuity.md at
# the queue-library boundary.
test_stale_recovery_generation_cannot_touch_a_newer_episode() {
  local dir state first_err replay_err sequence generation handling_marker
  local newer_marker newer_sequence newer_generation rc
  dir=$(make_case stale-recovery-generation)
  state="$dir/state"

  append_wake "$state" check first 'check: first generation' \
    || fail "first generation wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "first generation drain failed"
  first_err="$dir/first.err"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$first_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$first_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "first drain did not emit a generation-bound acknowledgement"

  append_wake "$state" check second 'check: same episode' \
    || fail "first same-episode wake append failed"
  append_wake "$state" check third 'check: same episode again' \
    || fail "second same-episode wake append failed"
  handling_marker=$(cat "$state/.watcher-down")
  [ "${handling_marker##*:}" = "$generation" ] \
    || fail "repeated publications replaced the outstanding recovery generation"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" > "$dir/handled-ack.out" 2> "$dir/handled-ack.err" \
    || fail "a publication during handling invalidated the printed acknowledgement"
  ! grep "$(printf '\tcheck\tfirst\t')" "$state/.wake-queue" >/dev/null \
    || fail "the handled row was not consumed"
  grep "$(printf '\tcheck\tsecond\t')" "$state/.wake-queue" >/dev/null \
    || fail "a row above the acknowledged sequence was consumed"
  grep "$(printf '\tcheck\tthird\t')" "$state/.wake-queue" >/dev/null \
    || fail "the second row above the acknowledged sequence was consumed"
  case "$(cat "$state/.watcher-down")" in
    pending:*) ;;
    *) fail "an episode with rows still queued was retired" ;;
  esac

  # Retire that episode, then let a genuinely newer one open.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay.out" 2> "$dir/replay.err" \
    || fail "remaining wake could not be re-drained"
  replay_err="$dir/replay.err"
  grep "$(printf '\tcheck\tsecond\t')" "$dir/replay.out" >/dev/null \
    || fail "remaining wake did not re-surface"
  grep "$(printf '\tcheck\tthird\t')" "$dir/replay.out" >/dev/null \
    || fail "second remaining wake did not re-surface"
  newer_sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  newer_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$newer_sequence" \
    --recovery-generation "$newer_generation" \
    || fail "the handled episode could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement left durable wakes queued"

  append_wake "$state" check fourth 'check: newer recovery generation' \
    || fail "newer generation wake append failed"
  newer_marker=$(cat "$state/.watcher-down")
  [ "${newer_marker##*:}" != "$generation" ] \
    || fail "a retired episode did not open a new recovery generation"

  rc=0
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" > "$dir/stale-ack.out" 2> "$dir/stale-ack.err" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a stale acknowledgement failed instead of degrading safely: $(cat "$dir/stale-ack.err")"
  if ! grep -F 'WAKE_ACK_REQUIRED' "$dir/stale-ack.err" >/dev/null \
    || ! grep -F 're-run' "$dir/stale-ack.err" >/dev/null; then
    fail "a stale acknowledgement did not name its own remedy: $(cat "$dir/stale-ack.err")"
  fi
  [ "$(cat "$state/.watcher-down")" = "$newer_marker" ] \
    || fail "a stale acknowledgement retired the newer recovery episode"
  grep "$(printf '\tcheck\tfourth\t')" "$state/.wake-queue" >/dev/null \
    || fail "a stale acknowledgement consumed the newer durable wake"
  pass "wake drain: a stale acknowledgement cannot retire or consume a newer recovery episode"
}

test_recovery_ack_failure_is_reported() {
  local dir state fakebin real_mv rc generation
  dir=$(make_case recovery-ack-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  real_mv=$(command -v mv) || fail "could not locate mv for recovery acknowledgement fixture"
  printf 'pending:handling:fixture\n' > "$state/.watcher-down"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/initial.out" 2> "$dir/initial.err" \
    || fail "initial recovery drain failed"
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through 0 --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/initial.err")
  [ -n "$generation" ] || fail "initial recovery drain omitted its generation"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "${FM_TEST_ACK_MARKER:-}" ]; then
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_ACK_MARKER="$state/.watcher-down" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 0 --recovery-generation "$generation" \
      > "$dir/drain.out" 2> "$dir/drain.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "recovery acknowledgement failure was reported as success"
  grep -F 'recovery episode could not be retired safely' "$dir/drain.err" >/dev/null \
    || fail "recovery acknowledgement failure had no explicit diagnostic"
  grep -F 'WAKE_ACK_REQUIRED' "$dir/drain.err" >/dev/null \
    || fail "recovery acknowledgement failure did not name its own remedy"
  [ "$(cat "$state/.watcher-down")" = "pending:handling:$generation" ] \
    || fail "failed acknowledgement corrupted the pending recovery marker"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 0 --recovery-generation "$generation" \
    > "$dir/retry.out" 2> "$dir/retry.err" \
    || fail "recovery acknowledgement did not succeed on retry"
  [ "$(cat "$state/.watcher-down")" = "acked:handling:$generation" ] \
    || fail "successful retry did not acknowledge pending recovery state"
  pass "wake drain: recovery acknowledgement failures are explicit and retryable"
}

test_interruption_before_and_after_raw_commit() {
  local dir state before_out after_out replay_out empty_out pid rc count i sequence generation
  dir=$(make_case interruption)
  state="$dir/state"
  before_out="$dir/before.out"
  after_out="$dir/after.out"
  replay_out="$dir/replay.out"
  empty_out="$dir/empty.out"
  printf 'done: interruption fixture\n' > "$state/task.status"
  append_wake "$state" signal task.status "signal: task" || fail "pre-commit interruption wake append failed"

  FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT=5 "$DRAIN" > "$before_out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.wake-queue.lock" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$state/.wake-queue.lock" ] || { kill "$pid" 2>/dev/null || true; fail "pre-commit drain never entered its serialized read boundary"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain before raw commitment"
  set +e
  wait "$pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "pre-commit interruption unexpectedly succeeded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" 2> "$dir/replay.err" || fail "restored pre-commit wake did not drain"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$replay_out")
  [ "$count" -eq 1 ] || fail "pre-commit interruption lost or duplicated the durable row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/replay.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/replay.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "pre-commit replay acknowledgement failed"

  append_wake "$state" signal task.status "signal: task after commit" || fail "post-commit interruption wake append failed"
  FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_TEST_DELAY=5 "$DRAIN" > "$after_out" &
  pid=$!
  wait_for_file_text "$after_out" "$(printf '\tsignal\ttask.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "post-commit drain did not print its raw row"; }
  [ -s "$state/.wake-queue" ] \
    || { kill "$pid" 2>/dev/null || true; fail "post-commit drain consumed its raw row before handling acknowledgement"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain after raw presentation"
  set +e
  wait "$pid"
  set -e
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$empty_out" 2> "$dir/after-replay.err" \
    || fail "drain after post-presentation interruption failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$empty_out")
  [ "$count" -eq 1 ] || fail "interrupted handling did not replay its durable row exactly once"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/after-replay.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/after-replay.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "post-interruption replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged interrupted wake remained durable"
  pass "interruptions preserve durable rows until post-handling acknowledgement"
}

# bin/fm-watch.sh's EXIT trap performs a recovery-marker transition, and a signal
# can fire that trap while an interrupted frame is still inside a marker critical
# section. Waiting there for a lock this same process already holds can never be
# satisfied: the watcher would spin forever, ignore every later signal, and pin
# the durable queue's lock with it. Drive that exact shape - hold the marker lock,
# then run the transitions the EXIT trap uses - and require each to finish.
test_marker_transitions_survive_reentry_from_an_exiting_frame() {
  local dir state rc holder
  dir=$(make_case marker-lock-reentry)
  state="$dir/state"
  printf 'pending:downtime:reentry-generation\n' > "$state/.watcher-down"
  chmod 0600 "$state/.watcher-down"

  set +e
  # shellcheck disable=SC2016 # Expansion belongs to the inner bash, not this shell.
  FM_STATE_OVERRIDE="$state" timeout 20 bash -c '
    . "$1/bin/fm-wake-lib.sh"
    marker="$2/.watcher-down"
    watch_lock="$2/.watch.lock"
    fm_lock_try_acquire "$marker.lock" || exit 20
    fm_lock_try_acquire "$watch_lock" || exit 21
    fm_lock_held_by_self "$marker.lock" || exit 22
    fm_recovery_transition "$marker" release-lock "$watch_lock" downtime || exit 23
    [ ! -e "$watch_lock" ] || exit 24
    fm_lock_held_by_self "$marker.lock" || exit 25
    fm_lock_try_acquire "$watch_lock" || exit 26
    fm_recovery_transition "$marker" release-lock-existing "$watch_lock" || exit 27
    [ ! -e "$watch_lock" ] || exit 28
    fm_recovery_marker_publish "$marker" downtime || exit 29
  ' _ "$ROOT" "$state"
  rc=$?
  set -e
  [ "$rc" -ne 124 ] || fail "a marker transition reentered from an exiting frame deadlocked on its own lock"
  [ "$rc" -eq 0 ] || fail "reentrant marker transitions failed with status $rc"
  case "$(cat "$state/.watcher-down")" in
    pending:downtime:reentry-generation) ;;
    *) fail "reentrant publication lost the outstanding recovery episode: $(cat "$state/.watcher-down")" ;;
  esac

  # The exiting process abandons the marker lock rather than releasing one an
  # outer frame still owns, so the next process reclaims it as a dead owner.
  # shellcheck disable=SC2016 # Expansion belongs to the inner bash, not this shell.
  FM_STATE_OVERRIDE="$state" timeout 20 bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2/.watcher-down.lock"
    fm_lock_release "$2/.watcher-down.lock"
  ' _ "$ROOT" "$state" || fail "an abandoned marker lock was not reclaimed from its dead owner"

  # Exclusion still holds for everyone else: a LIVE foreign holder is not
  # mistaken for reentry, so the bounded append reports exhaustion rather than
  # writing a durable row behind that holder's back.
  # shellcheck disable=SC2016 # Expansion belongs to the inner bash, not this shell.
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$2/.watcher-down.lock" || exit 1
    printf ready > "$2/.reentry-holder"
    sleep 30
  ' _ "$ROOT" "$state" &
  holder=$!
  wait_for_file_content "$state/.reentry-holder" || {
    kill "$holder" 2>/dev/null || true
    fail "foreign marker-lock holder never started"
  }
  set +e
  # shellcheck disable=SC2016 # Expansion belongs to the inner bash, not this shell.
  FM_STATE_OVERRIDE="$state" timeout 20 bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_held_by_self "$2/.watcher-down.lock" && exit 30
    fm_wake_append signal reentry.status "signal: bounded append" 3
  ' _ "$ROOT" "$state"
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 30 ] || fail "a live foreign marker-lock holder was reported as self-held"
  [ "$rc" -eq 3 ] || fail "bounded append did not report marker-lock exhaustion, got status $rc"
  [ ! -s "$state/.wake-queue" ] || fail "a wake became durable while another process held the marker lock"

  pass "recovery-marker transitions reenter safely without breaking exclusion"
}

test_handling_confirmation_is_bounded_by_foreign_marker_lock() {
  local dir state holder rc marker_before
  dir=$(make_case handling-confirmation-lock)
  state="$dir/state"
  printf 'pending:downtime:bounded-generation\n' > "$state/.watcher-down"
  chmod 0600 "$state/.watcher-down"
  marker_before=$(cat "$state/.watcher-down")

  # shellcheck disable=SC2016 # Expansion belongs to the inner bash, not this shell.
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    mkdir "$2/.watch.lock" || exit 1
    printf "%s\n" "$BASHPID" > "$2/.watch.lock/pid"
    printf "%s\n" "$3" > "$2/.watch.lock/fm-home"
    printf "%s\n" "$1/bin/fm-watch.sh" > "$2/.watch.lock/watcher-path"
    fm_pid_identity "$BASHPID" > "$2/.watch.lock/pid-identity" || exit 2
    fm_lock_try_acquire "$2/.watcher-down.lock" || exit 3
    printf ready > "$2/.handling-holder"
    while [ ! -e "$2/.release-handling-holder" ]; do sleep 0.05; done
    fm_lock_release "$2/.watcher-down.lock"
    printf released > "$2/.handling-holder-released"
    sleep 30
  ' _ "$ROOT" "$state" "$dir" &
  holder=$!
  wait_for_file_content "$state/.handling-holder" || {
    kill "$holder" 2>/dev/null || true
    fail "foreign handling-confirmation lock holder never started"
  }

  set +e
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" timeout 5 "$ROOT/bin/fm-watch-arm.sh" \
    --handling-delivered bounded-generation --watcher-pid "$holder" >/dev/null 2> "$dir/handling.err"
  rc=$?
  set -e
  [ "$rc" -ne 124 ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "handling confirmation hung behind a live foreign marker-lock holder"
  }
  [ "$rc" -eq 3 ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "bounded handling confirmation reported status $rc instead of marker-lock exhaustion"
  }
  [ "$(cat "$state/.watcher-down")" = "$marker_before" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "handling confirmation modified the recovery marker behind a foreign lock holder"
  }

  : > "$state/.release-handling-holder"
  wait_for_file_content "$state/.handling-holder-released" || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "foreign handling-confirmation lock holder did not release its lock"
  }
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" timeout 5 "$ROOT/bin/fm-watch-arm.sh" \
    --handling-delivered bounded-generation --watcher-pid "$holder" >/dev/null 2> "$dir/uncontended.err" \
    || {
      kill "$holder" 2>/dev/null || true
      wait "$holder" 2>/dev/null || true
      fail "ordinary uncontended handling confirmation failed"
    }
  [ "$(cat "$state/.watcher-down")" = "pending:handling:bounded-generation" ] \
    || {
      kill "$holder" 2>/dev/null || true
      wait "$holder" 2>/dev/null || true
      fail "ordinary uncontended handling confirmation did not transition the recovery episode"
    }
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  pass "handling confirmation is bounded without bypassing foreign marker-lock exclusion"
}

# Per-actor consume (docs/omp-supervision-branch.md "Per-actor acknowledgement").
# The core no-swallow property: a branch-scoped drain and ack touch only the
# rows the extension granted, never a main-owned row below the branch's cutoff.
test_branch_actor_scoped_ack_never_swallows_a_main_owned_row() {
  local dir state grant sequence generation
  grant="$ROOT/bin/fm-wake-grant.sh"
  dir=$(make_case branch-actor-scope)
  state="$dir/state"
  append_wake "$state" check "some-poll.check.sh" "check: some-poll" || fail "check append failed"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  append_wake "$state" stale "fm-window" "stale: fm-window" || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$grant" activate "$$" actor-scope || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$grant" publish actor-scope 2 3 || fail "branch grant publication failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/branch.out" 2> "$dir/branch.err" \
    || fail "branch-scoped drain failed: $(cat "$dir/branch.err")"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$dir/branch.out" || fail "branch drain omitted its eligible signal row"
  grep -Fq "$(printf '\tstale\tfm-window\t')" "$dir/branch.out" || fail "branch drain omitted its eligible stale row"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$dir/branch.out" && fail "branch drain presented the main-owned row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/branch.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/branch.err")
  [ "$sequence" = 3 ] || fail "branch ack cutoff must be the max eligible seq (3), got '$sequence'"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch-scoped ack failed"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$state/.wake-queue" \
    || fail "branch's scoped ack swallowed the main-owned row (seq 1) below its own cutoff"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$state/.wake-queue" \
    && fail "branch's own eligible signal row was not consumed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" || fail "main drain failed: $(cat "$dir/main.err")"
  [ "$(awk -F '\t' 'NF == 5 { c++ } END { print c + 0 }' "$dir/main.out")" -eq 1 ] \
    || fail "main's later drain should see exactly the one remaining main-owned row: $(cat "$dir/main.out")"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$dir/main.out" || fail "main's later drain lost the main-owned row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/main.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/main.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" || fail "main's ack failed"
  [ ! -s "$state/.wake-queue" ] || fail "the main-owned row survived main's own ack"
  pass "a branch-actor scoped ack never swallows an unacked main-owned row, and main's later drain sees exactly what remains"
}

# A row already granted to the branch is excluded from a concurrent main drain,
# and main's ack binds only its own presented rows.
test_main_drain_excludes_rows_already_granted_to_branch() {
  local dir state grant sequence generation
  grant="$ROOT/bin/fm-wake-grant.sh"
  dir=$(make_case main-excludes-granted)
  state="$dir/state"
  append_wake "$state" check "some-poll.check.sh" "check: some-poll" || fail "check append failed"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  FM_STATE_OVERRIDE="$state" "$grant" activate "$$" main-excludes || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$grant" publish main-excludes 2 || fail "branch grant publication failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" || fail "main drain failed: $(cat "$dir/main.err")"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$dir/main.out" || fail "main drain omitted its main-owned row"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$dir/main.out" && fail "main drain presented a branch-granted row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/main.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/main.err")
  [ "$sequence" = 1 ] || fail "main acknowledgement did not bind only its presented row (seq 1), got '$sequence'"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" || fail "main acknowledgement failed"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$state/.wake-queue" \
    || fail "main acknowledgement consumed the branch-granted row"
  pass "a main drain excludes a branch-granted row and acknowledges only its own presented rows"
}

test_branch_owner_activation_rollback_stops_after_publication() {
  local dir state grant status=0
  grant="$ROOT/bin/fm-wake-grant.sh"
  dir=$(make_case branch-activation-rollback)
  state="$dir/state"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"

  FM_STATE_OVERRIDE="$state" "$grant" activate "$$" rollback-empty || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$grant" deactivate "$$" rollback-empty >/dev/null 2>&1 && \
    fail "removed deactivate surface still accepted an owner deletion"
  [ -e "$state/.branch-eligible-owner" ] || fail "removed deactivate surface deleted the branch owner"
  FM_STATE_OVERRIDE="$state" "$grant" rollback-activation "$$" rollback-empty \
    || fail "pre-publication activation rollback failed"
  [ ! -e "$state/.branch-eligible-owner" ] || fail "pre-publication rollback retained the branch owner"

  FM_STATE_OVERRIDE="$state" "$grant" activate "$$" rollback-published || fail "second branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$grant" publish rollback-published 1 || fail "branch row publication failed"
  FM_STATE_OVERRIDE="$state" "$grant" rollback-activation "$$" rollback-published >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "activation rollback deleted an owner after rows were published"
  [ -e "$state/.branch-eligible-owner" ] || fail "refused activation rollback deleted the active owner"
  [ -e "$state/.branch-eligible-rows" ] || fail "refused activation rollback deleted the published rows"
  pass "branch activation rollback succeeds before publication and preserves every active grant"
}

# A stale acknowledgement for an earlier presented wake must not re-feed the
# same wake loop: it consumes nothing, names the current wake, and prints the
# exact generation-bound command that closes that current presentation.
test_stale_acknowledgement_names_current_presented_wake() {
  local dir state grant first_seq first_gen second_seq second_gen
  dir=$(make_case stale-ack-current-wake)
  state="$dir/state"
  grant="$ROOT/bin/fm-wake-grant.sh"
  append_wake "$state" signal task-a.status "signal: first wake" || fail "first wake append failed"
  FM_STATE_OVERRIDE="$state" "$grant" activate "$$" stale-ack || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$grant" publish stale-ack 1 || fail "first grant publication failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" || fail "first drain failed"
  first_seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$dir/first.err")
  first_gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/first.err")
  [ -n "$first_seq" ] && [ -n "$first_gen" ] || fail "first drain omitted its acknowledgement command"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$first_seq" --recovery-generation "$first_gen" || fail "first acknowledgement failed"
  FM_STATE_OVERRIDE="$state" "$grant" release stale-ack || fail "first grant release failed"

  append_wake "$state" stale fm-window-b "stale: second wake" || fail "second wake append failed"
  FM_STATE_OVERRIDE="$state" "$grant" publish stale-ack 2 || fail "second grant publication failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/second.out" 2> "$dir/second.err" || fail "second drain failed"
  second_seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$dir/second.err")
  second_gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/second.err")
  [ "$second_seq" -gt "$first_seq" ] || fail "second drain did not present a newer wake"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$first_seq" --recovery-generation "$first_gen" \
    > "$dir/stale.out" 2> "$dir/stale.err" || fail "stale acknowledgement failed unsafely"
  grep -F "nothing was acknowledged through $first_seq" "$dir/stale.err" >/dev/null \
    || fail "stale acknowledgement did not report that it consumed nothing: $(cat "$dir/stale.err")"
  grep -F "the current wake is row $second_seq" "$dir/stale.err" >/dev/null \
    || fail "stale acknowledgement did not name the current wake: $(cat "$dir/stale.err")"
  ! grep -F 're-run bin/fm-wake-drain.sh' "$dir/stale.err" >/dev/null \
    || fail "stale acknowledgement invited the old drain loop: $(cat "$dir/stale.err")"
  grep -F "run bin/fm-wake-drain.sh --ack-through $second_seq --recovery-generation $second_gen" "$dir/stale.err" >/dev/null \
    || fail "stale acknowledgement omitted the exact current command: $(cat "$dir/stale.err")"
  grep -F "$(printf '\tstale\tfm-window-b\t')" "$state/.wake-queue" >/dev/null \
    || fail "stale acknowledgement consumed the current wake"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$second_seq" --recovery-generation "$second_gen" \
    || fail "the printed current-wake command failed"
  [ ! -s "$state/.wake-queue" ] || fail "the current wake remained queued after its exact acknowledgement"
  pass "a stale acknowledgement is bounded and names the current presented wake"
}

# Consumer-side incarnation gate for turn-end markers (fm-wake-lib.sh).
# bin/fm-turnend-signal.sh writes state/<id>.turn-ended lock-free and
# unconditionally, stamped with the firing spawn_gen. The consumer discards a
# marker whose stamp is not the live incarnation's, so a torn-down or relaunched
# id never re-fires even though a stale marker exists.
test_turnend_marker_consumer_incarnation_gate() {
  local case_root turnend_id turnend_state turnend_meta
  case_root="$TMP_ROOT/turnend-consumer"
  turnend_id=cons-x1
  turnend_state="$case_root/state"
  turnend_meta="$turnend_state/$turnend_id.meta"
  mkdir -p "$turnend_state"

  # Gate the per-generation marker <state>/<id>.turn-ended.<gen> for one gen.
  gate() {  # <gen> -> STALE (ignore) or FIRE (surface)
    ( . "$ROOT/bin/fm-wake-lib.sh" && fm_wake_turnend_marker_is_stale "$turnend_state" "$turnend_id" "$1" ) \
      && printf 'STALE' || printf 'FIRE'
  }

  # Live incarnation g2 publishes; a DELAYED older-incarnation g1 hook then publishes
  # into its OWN gen file (no clobber). The consumer FIRES only the live gen and
  # IGNORES the stale gen - the delayed-old-gen-vs-live-gen regression.
  printf 'endpoint_task_id=%s\nspawn_gen=g2\n' "$turnend_id" > "$turnend_meta"
  "$ROOT/bin/fm-turnend-signal.sh" "$turnend_state" "$turnend_id" g2
  "$ROOT/bin/fm-turnend-signal.sh" "$turnend_state" "$turnend_id" g1
  assert_present "$turnend_state/$turnend_id.turn-ended.g2" "the live incarnation's marker is missing"
  assert_present "$turnend_state/$turnend_id.turn-ended.g1" "the delayed old incarnation clobbered the live marker"
  [ "$(gate g2)" = FIRE ] || fail "the consumer discarded the live incarnation's completion"
  [ "$(gate g1)" = STALE ] || fail "the consumer surfaced a superseded incarnation's stale marker"

  # Torn down: meta gone, every gen marker remains -> all STALE (never re-fires).
  rm -f -- "$turnend_meta"
  [ "$(gate g2)" = STALE ] || fail "a torn-down id's marker was surfaced"
  [ "$(gate g1)" = STALE ] || fail "a torn-down id's marker was surfaced"

  # Metadata that records no gen yet cannot gate -> FIRE rather than drop a completion.
  printf 'endpoint_task_id=%s\n' "$turnend_id" > "$turnend_meta"
  [ "$(gate g2)" = FIRE ] || fail "the consumer dropped a completion for metadata with no recorded gen"

  unset -f gate
  rm -rf -- "$case_root"
  pass "consumer fires only the live gen marker and ignores stale gens, so a delayed old gen never overwrites or drops a live completion"
}

test_turnend_marker_consumer_incarnation_gate
test_stale_acknowledgement_names_current_presented_wake
test_concurrent_append_and_drain
test_signal_catchup_without_running_watcher
test_stale_enqueue_before_suppressor
test_not_working_stale_enqueue_before_suppressor
test_check_output_is_queued
test_atomic_double_drain
test_drain_dedupes_obvious_duplicates
test_drain_asserts_watcher_liveness
test_structural_signal_enrichment_preserves_raw_rows
test_enrichment_preserves_all_unread_lines_and_status_file_failures
test_slow_annotation_does_not_block_append_and_deleted_file_fails_closed
test_wake_publish_requires_atomic_recovery_evidence
test_legacy_generationless_wake_is_adopted
test_stale_recovery_generation_cannot_touch_a_newer_episode
test_recovery_ack_failure_is_reported
test_interruption_before_and_after_raw_commit
test_marker_transitions_survive_reentry_from_an_exiting_frame
test_handling_confirmation_is_bounded_by_foreign_marker_lock
test_branch_actor_scoped_ack_never_swallows_a_main_owned_row
test_main_drain_excludes_rows_already_granted_to_branch
test_branch_owner_activation_rollback_stops_after_publication
