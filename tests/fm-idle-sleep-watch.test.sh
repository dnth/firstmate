#!/usr/bin/env bash
# The watcher drives idle auto-sleep from its own cycle: it calls
# bin/fm-idle-sleep.sh tick only for a home that has config/idle-sleep, and a
# line the tick prints becomes the one actionable wake. The tick itself is a
# fake in a copy of bin/ here; tests/fm-idle-sleep.test.sh owns its decisions.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-idle-sleep-watch)
BIN="$TMP_ROOT/bin"
cp -R "$ROOT/bin" "$BIN"

make_home() { # <name> -> prints the home dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/data"
  cat > "$BIN/fm-idle-sleep.sh" <<SH
#!/usr/bin/env bash
printf 'tick %s\n' "\$*" >> "\${FM_HOME}/ticks"
[ ! -f "\${FM_HOME}/emit" ] || printf 'check: idle-sleep ios refused by the guarded sleep, left awake and not forced: fixture\n'
SH
  chmod +x "$BIN/fm-idle-sleep.sh"
  printf '%s\n' "$dir"
}

run_watch() { # <home> <out>
  env -u FM_TASK_ID FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$BIN/fm-watch.sh" > "$2" 2>&1 &
}

wait_for_file() { # <file> [ticks]
  local n=${2:-100}
  while [ "$n" -gt 0 ]; do [ -s "$1" ] && return 0; n=$((n - 1)); sleep 0.1; done
  return 1
}

# No config/idle-sleep: the tick is never called, so an unopted home pays nothing.
home=$(make_home absent)
run_watch "$home" "$home/out"; pid=$!
n=0; while [ ! -f "$home/state/.last-watcher-beat" ] && [ "$n" -lt 100 ]; do n=$((n + 1)); sleep 0.1; done
sleep 2
kill -0 "$pid" 2>/dev/null || fail "the watcher exited without a wake: $(cat "$home/out")"
stop_pid "$pid"
[ ! -e "$home/ticks" ] || fail "a home without config/idle-sleep still ran the tick"
pass "the watcher skips the idle-sleep tick without config/idle-sleep"

# With the config, every cycle ticks; a quiet tick keeps the watcher blocking.
home=$(make_home quiet)
printf 'ios\n' > "$home/config/idle-sleep"
run_watch "$home" "$home/out"; pid=$!
wait_for_file "$home/ticks" || fail "the watcher never ran the idle-sleep tick"
sleep 1
kill -0 "$pid" 2>/dev/null || fail "a quiet tick woke the watcher: $(cat "$home/out")"
stop_pid "$pid"
assert_grep "tick tick" "$home/ticks" "the watcher must call the tick subcommand"
pass "the watcher ticks idle auto-sleep each cycle without waking on a quiet tick"

# A reported refusal is the one actionable wake.
home=$(make_home refusal)
printf 'ios\n' > "$home/config/idle-sleep"
: > "$home/emit"
run_watch "$home" "$home/out"; pid=$!
n=0; while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 150 ]; do n=$((n + 1)); sleep 0.1; done
kill -0 "$pid" 2>/dev/null && { stop_pid "$pid"; fail "the reported refusal never woke the watcher"; }
assert_grep "check: idle-sleep ios refused" "$home/out" "the wake must carry the refusal line"
pass "a reported refusal wakes the watcher once with its reason"
