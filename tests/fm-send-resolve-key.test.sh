#!/usr/bin/env bash
# fm-send answerer-closes (--resolve-key) behavior.
#
# These tests drive the real fm-send executable over stubbed transports and
# assert closure through the real OPEN DECISIONS consumer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-resolve-key)

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
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
      if [ -n "${FM_FAKE_APPEND_FAILURE_STATUS:-}" ]; then
        chmod 444 "$FM_FAKE_APPEND_FAILURE_STATUS"
      fi
      if [ -n "${FM_FAKE_PENDING_FAILURE_DIR:-}" ]; then
        chmod 500 "$FM_FAKE_PENDING_FAILURE_DIR"
      fi
    fi
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*)
          if [ "${FM_FAKE_TMUX_QUEUED_UNCONFIRMED:-0}" = 1 ]; then printf '2\n'; else printf '1\n'; fi
          exit 0 ;;
        *pane_current_command*)
          if [ "${FM_FAKE_TMUX_OMP_IDENTITY:-0}" = 1 ]; then printf 'bun\n'; else printf 'fakepane\n'; fi
          exit 0 ;;
        *pane_pid*) printf '4242\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_QUEUED_UNCONFIRMED:-0}" = 1 ]; then
      printf 'Working… ⟦esc⟧\n╭────────╮\n│ answer │\n╰────────╯\n'
    elif [ "${FM_FAKE_TMUX_UNCONFIRMED:-0}" = 1 ]; then
      printf '╭────╮\n│ answer still here │\n╰────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0
    ;;
  list-windows)
    if [ -n "${FM_FAKE_TMUX_WINDOW:-}" ]; then printf '%s\n' "$FM_FAKE_TMUX_WINDOW"; fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *tpgid=*) printf '4242\n' ;;
  *args=*) printf '%s %s --auto-approve\n' "$FM_FAKE_OMP_BUN" "$FM_FAKE_OMP_BIN" ;;
esac
SH
  chmod +x "$fb/ps"
  cat > "$fb/lsof" <<'SH'
#!/usr/bin/env bash
printf 'n%s\n' "$FM_FAKE_OMP_BUN"
SH
  chmod +x "$fb/lsof"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "$FM_SSH_LOG"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

run_send() {
  local fb=$1 home=$2 log=$3
  shift 3
  : > "$log"
  if [ -n "${FM_SEND_ERR:-}" ]; then
    : > "$FM_SEND_ERR"
  fi
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_TMUX_SEND_FAIL="${FM_FAKE_TMUX_SEND_FAIL:-0}" \
    FM_FAKE_TMUX_UNCONFIRMED="${FM_FAKE_TMUX_UNCONFIRMED:-0}" \
    FM_FAKE_TMUX_QUEUED_UNCONFIRMED="${FM_FAKE_TMUX_QUEUED_UNCONFIRMED:-0}" \
    FM_FAKE_APPEND_FAILURE_STATUS="${FM_FAKE_APPEND_FAILURE_STATUS:-}" \
    FM_FAKE_PENDING_FAILURE_DIR="${FM_FAKE_PENDING_FAILURE_DIR:-}" \
    FM_FAKE_TMUX_OMP_IDENTITY="${FM_FAKE_TMUX_OMP_IDENTITY:-0}" \
    FM_FAKE_TMUX_WINDOW="${FM_FAKE_TMUX_WINDOW:-}" \
    FM_FAKE_OMP_BUN="${FM_FAKE_OMP_BUN:-}" FM_FAKE_OMP_BIN="${FM_FAKE_OMP_BIN:-}" \
    "$SEND" "$@" 2>"${FM_SEND_ERR:-/dev/null}"
}

setup_home() {  # <name> -> echoes a fresh home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

drain_out() {  # <home>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null
}

test_answer_send_closes_open_decision() {
  local dir fb log home rc out
  dir="$TMP_ROOT/closes"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  home=$(setup_home closes)
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$home/state/t1.status"
  printf 'working: kept busy on an unrelated stream\n' >> "$home/state/t1.status"

  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "precondition: the buried decision should list as open before the answer"

  run_send "$fb" "$home" "$log" t1 --resolve-key api-shape "go with REST"
  rc=$?
  expect_code 0 "$rc" "an answer send with --resolve-key should succeed"
  assert_contains "$(cat "$log")" "go with REST" "the answer text should reach the worker"
  assert_grep 'resolved [key=api-shape]: answered: go with REST' "$home/state/t1.status" \
    "fm-send did not append the closing resolved line"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision still lists as open: $out"
  fi
  pass "fm-send --resolve-key closes the open decision at answer time"
}
test_answer_starts_work_never_orphans() {
  local dir fb log home rc out
  dir="$TMP_ROOT/starts-work"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  home=$(setup_home starts-work)
  fm_write_meta "$home/state/t2.meta" "window=sess:fm-t2" "kind=ship"
  printf 'needs-decision [key=rollout]: big-bang or phased\n' > "$home/state/t2.status"

  run_send "$fb" "$home" "$log" t2 --resolve-key rollout "phased, gate each region"
  rc=$?
  expect_code 0 "$rc" "the rollout answer send should succeed"
  printf 'working [key=phased-impl]: building region gates\n' >> "$home/state/t2.status"
  printf 'done [key=phased-impl]: PR up\n' >> "$home/state/t2.status"

  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered decision orphaned after the answer started work: $out"
  fi
  pass "an answer that starts a different workstream leaves no orphaned decision"
}

test_send_without_flag_and_progress_never_closes() {
  local dir fb log home rc out
  dir="$TMP_ROOT/routine"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  home=$(setup_home routine)
  fm_write_meta "$home/state/t3.meta" "window=sess:fm-t3" "kind=ship"
  printf 'needs-decision [key=schema]: split or embed\n' > "$home/state/t3.status"

  run_send "$fb" "$home" "$log" t3 "unrelated nudge, keep going --resolve-key is documentation"
  rc=$?
  expect_code 0 "$rc" "a routine steer should still succeed"
  printf 'working: resumed\n' >> "$home/state/t3.status"
  printf 'done: unrelated milestone\n' >> "$home/state/t3.status"

  assert_no_grep 'resolved' "$home/state/t3.status" \
    "a send without --resolve-key wrote a resolved line"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=schema]' >/dev/null \
    || fail "a routine steer or later working/done line cleared an unanswered decision"
  pass "a send without --resolve-key and working/done never close a decision"
}

test_not_open_key_refuses_before_send() {
  local dir fb log home err rc out
  dir="$TMP_ROOT/not-open"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  err="$dir/send.err"
  home=$(setup_home not-open)
  fm_write_meta "$home/state/t4.meta" "window=sess:fm-t4" "kind=ship"
  printf 'needs-decision [key=real-key]: choose\n' > "$home/state/t4.status"

  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t4 --resolve-key mistyped "the answer" >/dev/null 2>"$err"
  rc=$?
  [ "$rc" -ne 0 ] || fail "a not-open key should refuse"
  assert_contains "$(cat "$err")" "--resolve-key 'mistyped'" "the refusal should name the bad key"
  assert_contains "$(cat "$err")" "nothing was sent" "the refusal should state nothing was sent"
  [ ! -s "$log" ] || fail "a refused answer still typed text: $(cat "$log")"
  assert_no_grep 'resolved' "$home/state/t4.status" "a refused answer still closed something"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=real-key]' >/dev/null \
    || fail "the real decision disappeared after a refused answer"
  pass "a key that is not open refuses before anything is sent"
}

test_failed_send_does_not_close() {
  local dir fb log home rc out
  dir="$TMP_ROOT/send-fail"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  home=$(setup_home send-fail)
  fm_write_meta "$home/state/t5.meta" "window=sess:fm-t5" "kind=ship"
  printf 'blocked [key=creds]: need the deploy token\n' > "$home/state/t5.status"

  : > "$log"
  env PATH="$fb:$PATH" FM_FAKE_TMUX_SEND_FAIL=1 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" t5 --resolve-key creds "token is in the vault now" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a failed backend send should exit nonzero"
  assert_no_grep 'resolved' "$home/state/t5.status" "a failed send still closed the decision"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=creds]' >/dev/null \
    || fail "the blocker vanished after a failed send"
  pass "a failed send never closes the decision"
}

test_unconfirmed_send_does_not_close() {
  local dir fb log home rc out
  dir="$TMP_ROOT/unconfirmed"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  home=$(setup_home unconfirmed)
  fm_write_meta "$home/state/t6.meta" "window=sess:fm-t6" "kind=ship"
  printf 'needs-decision [key=confirm]: verify the release\n' > "$home/state/t6.status"

  FM_FAKE_TMUX_UNCONFIRMED=1 run_send "$fb" "$home" "$log" t6 --resolve-key confirm "release is verified"
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed backend send should exit nonzero"
  assert_no_grep 'resolved' "$home/state/t6.status" "an unconfirmed send still closed the decision"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=confirm]' >/dev/null \
    || fail "the decision vanished after an unconfirmed send"
  pass "an unconfirmed send never closes the decision"
}

test_busy_omp_queued_unconfirmed_does_not_close() {
  local dir fb log err home project worktree omp bun rc out
  dir="$TMP_ROOT/queued-unconfirmed"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  err="$dir/send.err"
  home=$(setup_home queued-unconfirmed)
  project="$dir/project"
  worktree="$dir/worktree"
  mkdir -p "$project" "$worktree"
  bun=$(fm_test_realpath "$(command -v bun)")
  omp="$dir/omp"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$omp"
  chmod +x "$omp"
  omp=$(fm_test_realpath "$omp")
  fm_write_meta "$home/state/tq.meta" "window=sess:fm-tq" "endpoint_task_id=tq" \
    "worktree=$worktree" "project=$project" "kind=ship" "harness=omp" \
    "omp_bin=$omp" "omp_bun=$bun"
  printf 'needs-decision [key=queue-proof]: verify the queued answer\n' > "$home/state/tq.status"

  FM_FAKE_TMUX_QUEUED_UNCONFIRMED=1 FM_FAKE_TMUX_OMP_IDENTITY=1 \
    FM_FAKE_TMUX_WINDOW=fm-tq FM_FAKE_OMP_BUN="$bun" FM_FAKE_OMP_BIN="$omp" \
    FM_SEND_ERR="$err" \
    run_send "$fb" "$home" "$log" \
    tq --resolve-key queue-proof "answer may only be queued"
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the existing busy OMP queued steer path should still succeed: $(cat "$err")"
  assert_no_grep 'resolved' "$home/state/tq.status" \
    "a queued-unconfirmed OMP send closed the decision"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=queue-proof]' >/dev/null \
    || fail "the decision vanished after a queued-unconfirmed OMP send"
  pass "a busy OMP queued-unconfirmed send leaves the decision open"
}

test_multiple_keys_close_together() {
  local dir fb log home rc out
  dir="$TMP_ROOT/multi"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  home=$(setup_home multi)
  fm_write_meta "$home/state/t7.meta" "window=sess:fm-t7" "kind=ship"
  {
    printf 'needs-decision [key=k1]: first\n'
    printf 'blocked [key=k2]: second\n'
    printf 'needs-decision [key=k3]: third, unanswered\n'
  } > "$home/state/t7.status"

  run_send "$fb" "$home" "$log" t7 --resolve-key k1 --resolve-key k2 \
    "one answer covering both"
  rc=$?
  expect_code 0 "$rc" "an answer resolving two keys should succeed"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=k3]' >/dev/null \
    || fail "the unanswered third decision must stay open"
  if printf '%s' "$out" | grep -E '\[key=k1\]|\[key=k2\]' >/dev/null; then
    fail "an answered key is still open after a multi-key answer"
  fi
  pass "one answer closes each named key and only those keys"
}

test_local_secondmate_answer_is_marked_and_closed() {
  local dir fb log home rc got closing out
  dir="$TMP_ROOT/local-secondmate"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  home=$(setup_home local-secondmate)
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  printf 'needs-decision [key=fleet-split]: shard by team or by repo\n' > "$home/state/domain.status"

  run_send "$fb" "$home" "$log" fm-domain --resolve-key fleet-split "shard by team"
  rc=$?
  expect_code 0 "$rc" "a local secondmate answer should succeed"
  got=$(cat "$log")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "the secondmate answer lost its marker/corr framing" ;;
  esac
  closing=$(grep -F 'resolved [key=fleet-split]' "$home/state/domain.status" || true)
  [ -n "$closing" ] || fail "the local secondmate decision was not closed"
  assert_not_contains "$closing" "corr=" "the closing line leaked the corr token"
  assert_not_contains "$closing" "$FM_FROMFIRST_SEPARATOR" "the closing line leaked marker bytes"
  assert_contains "$closing" "shard by team" "the closing line should carry the plain answer"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered local secondmate decision still lists as open"
  fi
  pass "a marked local secondmate answer closes the same local ledger with plain text"
}

setup_remote_home() {  # <name> -> echoes a remote-secondmate fixture home
  local home
  home=$(setup_home "$1")
  mkdir -p "$home/data"
  fm_write_meta "$home/state/rsm.meta" \
    "window=fm-remote:w1:p1" "endpoint_task_id=rsm" "harness=claude" \
    "kind=secondmate" "mode=secondmate" "yolo=off" \
    "remote_host=remote-mac" "remote_root=/remote/root" \
    "remote_backend=herdr" "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  printf '%s\n' '- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)' > "$home/data/secondmates.md"
  printf '%s\n' "$home"
}

test_remote_secondmate_answer_closes_locally() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-ok"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  ssh_log="$dir/ssh.log"
  : > "$ssh_log"
  home=$(setup_remote_home remote-ok)
  printf 'needs-decision [key=upgrade-window]: tonight or the weekend\n' > "$home/state/rsm.status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=0 \
    "$SEND" rsm --resolve-key upgrade-window "the weekend, freeze Friday" >/dev/null 2>&1
  rc=$?
  expect_code 0 "$rc" "a remote secondmate answer should succeed"
  assert_grep 'fm-remote-entrypoint.sh' "$ssh_log" "the answer should cross the remote transport"
  assert_grep 'resolved [key=upgrade-window]: answered: the weekend, freeze Friday' "$home/state/rsm.status" \
    "the remote answer should close the local ledger"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the answered remote decision still lists as open"
  fi
  pass "a remote secondmate answer closes the same local ledger"
}

test_remote_transport_failure_does_not_close() {
  local dir fb log home ssh_log rc out
  dir="$TMP_ROOT/remote-fail"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  ssh_log="$dir/ssh.log"
  : > "$ssh_log"
  home=$(setup_remote_home remote-fail)
  printf 'blocked [key=quota]: remote host is out of runway\n' > "$home/state/rsm.status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$fb/fake-ssh" FM_SSH_LOG="$ssh_log" FM_FAKE_SSH_RC=1 \
    "$SEND" rsm --resolve-key quota "quota refreshed, resume" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a failed remote transport should exit nonzero"
  assert_no_grep 'resolved' "$home/state/rsm.status" "a failed remote send still closed the decision"
  out=$(drain_out "$home")
  printf '%s' "$out" | grep -F '[key=quota]' >/dev/null \
    || fail "the remote blocker vanished after a failed transport"
  pass "a failed remote transport never closes the decision"
}

test_append_failure_reports_every_safe_manual_close() {
  local dir fb log home err commands rc out
  dir="$TMP_ROOT/append-failure"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  err="$dir/send.err"
  home="$TMP_ROOT/append failure; safe-$RANDOM"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/t8.meta" "window=sess:fm-t8" "kind=ship"
  {
    printf 'needs-decision [key=manual-one]: choose the release window\n'
    printf 'blocked [key=manual-two]: choose the fallback window\n'
  } > "$home/state/t8.status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_APPEND_FAILURE_STATUS="$home/state/t8.status" \
    "$SEND" t8 --resolve-key manual-one --resolve-key manual-two "ship Friday" >/dev/null 2>"$err"
  rc=$?
  chmod 644 "$home/state/t8.status"
  [ "$rc" -ne 0 ] || fail "an append failure after delivery should exit nonzero"
  [ "$(grep -c '^manual close:' "$err")" -eq 2 ] \
    || fail "append failure did not report one command for every open key: $(cat "$err")"
  assert_no_grep 'resolved' "$home/state/t8.status" "append failure silently closed the decision"
  commands="$dir/manual-commands"
  sed -n 's/^manual close: //p' "$err" > "$commands"
  bash "$commands" || fail "the reported manual close commands were not shell-safe"
  assert_grep 'resolved [key=manual-one]: answered: ship Friday' "$home/state/t8.status" \
    "the first manual close command did not close its key"
  assert_grep 'resolved [key=manual-two]: answered: ship Friday' "$home/state/t8.status" \
    "the second manual close command did not close its key"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "a key remained open after running the reported manual close commands: $out"
  fi
  pass "append failure reports every shell-safe manual close command"
}

test_secondmate_closes_before_pending_reply_commit_failure() {
  local dir fb log home pending_dir err rc out
  dir="$TMP_ROOT/pending-failure"
  mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/send.log"
  err="$dir/send.err"
  home=$(setup_home pending-failure)
  pending_dir="$home/state/pending-replies"
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  printf 'needs-decision [key=commit-order]: answer before ancillary commit\n' > "$home/state/domain.status"

  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_FAKE_PENDING_FAILURE_DIR="$pending_dir" \
    "$SEND" domain --resolve-key commit-order "use the confirmed answer" >/dev/null 2>"$err"
  rc=$?
  chmod 700 "$pending_dir"
  [ "$rc" -ne 0 ] || fail "a pending-reply commit failure should still exit nonzero"
  assert_grep 'pending-reply delivery commit' "$err" \
    "the fixture did not reach the pending-reply commit failure"
  assert_grep 'resolved [key=commit-order]: answered: use the confirmed answer' \
    "$home/state/domain.status" \
    "confirmed delivery did not close before ancillary pending-reply bookkeeping failed"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F 'OPEN DECISIONS' >/dev/null; then
    fail "the confirmed secondmate answer remained open after pending-reply commit failure"
  fi
  pass "confirmed secondmate delivery closes before pending-reply bookkeeping"
}

test_answer_send_closes_open_decision
test_answer_starts_work_never_orphans
test_send_without_flag_and_progress_never_closes
test_not_open_key_refuses_before_send
test_failed_send_does_not_close
test_unconfirmed_send_does_not_close
test_busy_omp_queued_unconfirmed_does_not_close
test_multiple_keys_close_together
test_local_secondmate_answer_is_marked_and_closed
test_remote_secondmate_answer_closes_locally
test_remote_transport_failure_does_not_close
test_append_failure_reports_every_safe_manual_close
test_secondmate_closes_before_pending_reply_commit_failure
