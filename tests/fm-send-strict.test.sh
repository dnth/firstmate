#!/usr/bin/env bash
# fm-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

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
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-bun}"; exit 0 ;;
      *pane_pid*) printf '%s\n' "${FM_FAKE_TMUX_PID:-4242}"; exit 0 ;;
    esac
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '1\n'; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_TMUX_CAPTURE_FILE:-}" ]; then
      if [ "${FM_FAKE_TMUX_BUSY_AFTER_ENTER:-0}" = 1 ] \
        && grep -Fq 'literal=0 arg=Enter' "$FM_TMUX_LOG"; then
        printf 'Working… ⟦esc⟧\n'
      fi
      cat "$FM_FAKE_TMUX_CAPTURE_FILE"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_TMUX_INVENTORY:-}" ]; then
      printf '%s\n' "$FM_FAKE_TMUX_INVENTORY"
    else
      printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:-/dev/null}"
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"client":{"version":"0.7.5","protocol":17},"server":{"running":true}}' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-keys") : ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_fm_prefixed_herdr_explicit_target_matches_recorded_window() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-fm-session"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdrfmsession); err="$dir/send.err"; log="$dir/herdr.log"; : > "$log"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_HERDR_LOG="$log" \
    "$SEND" fm-lab-proof:w1:p2 --key Escape >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "fm-prefixed Herdr explicit target should verify without metadata"
  assert_contains "$(cat "$log")" 'pane send-keys w1:p2 escape' \
    "fm-prefixed Herdr explicit target did not reach the recorded pane"
  pass "fm-send strict: fm-prefixed live Herdr targets reach explicit endpoint verification before label refusal"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_omp_send_uses_metadata_bound_bun_and_rejects_process_mismatch() {
  local dir fb home err log rc got actual_bun omp project worktree capture top width before
  if ! command -v bun >/dev/null 2>&1; then
    pass "fm-send strict: OMP bound-Bun subtest skipped because bun is unavailable"
    return
  fi
  dir="$TMP_ROOT/omp-bound"; mkdir -p "$dir"
  actual_bun=$(fm_test_realpath "$(command -v bun)")
  fb=$(make_stubs "$dir"); home=$(setup_home ompbound); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  project="$dir/project"; worktree="$dir/worktree"; capture="$dir/composer"; omp="$dir/omp-entry"
  mkdir -p "$project" "$worktree"
  printf '#!/usr/bin/env bun\n' > "$omp"; chmod +x "$omp"
  omp=$(fm_test_realpath "$omp")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/bun"; chmod +x "$fb/bun"
  cat > "$fb/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *tpgid=*) printf '4242\n' ;;
  *args=*) printf '%s %s --auto-approve\n' '$actual_bun' '$omp' ;;
  *comm=*) printf 'bun\n' ;;
esac
SH
  cat > "$fb/lsof" <<SH
#!/usr/bin/env bash
printf 'n%s\n' '$actual_bun'
SH
  chmod +x "$fb/ps" "$fb/lsof"
  top='╭── ⬢ GPT-5.6-Luna · ◔ low ▶ 🌳 project ▶ ⑂ branch ▶──╮'
  width=$("$actual_bun" -e 'process.stdout.write(String(Bun.stringWidth(process.argv[1])))' "$top")
  printf '%s\n' "$top" > "$capture"
  printf '╰─%-*s─╯\n' "$((width - 4))" ' ' >> "$capture"
  fm_write_meta "$home/state/omp-bound.meta" \
    "window=sess:fm-omp-bound" "endpoint_task_id=omp-bound" \
    "worktree=$worktree" "project=$project" "harness=omp" "kind=ship" \
    "mode=no-mistakes" "yolo=off" "tasktmp=/tmp/fm-omp-bound" \
    "omp_bin=$omp" "omp_bun=$actual_bun"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_INVENTORY=fm-omp-bound FM_FAKE_TMUX_CAPTURE_FILE="$capture" \
    FM_FAKE_TMUX_BUSY_AFTER_ENTER=1 FM_SEND_SETTLE=0 \
    "$SEND" omp-bound "bound geometry" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "OMP send without a native bridge should refuse despite a valid metadata-bound Bun"
  got=$(cat "$log")
  assert_not_contains "$got" "literal=1 arg=bound geometry" \
    "OMP send typed into the composer before finding its missing native bridge"
  assert_contains "$(cat "$err")" "no live native send bridge" \
    "OMP missing native bridge refusal did not name the task-bound binding"

  before=$(wc -l < "$log" | tr -d ' ')
  awk -v bad="$fb/bun" 'BEGIN{FS=OFS="="} $1=="omp_bun"{$2=bad} {print}' \
    "$home/state/omp-bound.meta" > "$home/state/omp-bound.meta.next"
  mv "$home/state/omp-bound.meta.next" "$home/state/omp-bound.meta"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_INVENTORY=fm-omp-bound FM_FAKE_TMUX_CAPTURE_FILE="$capture" FM_SEND_SETTLE=0 \
    "$SEND" omp-bound "must refuse" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "OMP send accepted metadata Bun that mismatched the live process"
  assert_contains "$(cat "$err")" "does not match a live task-bound Bun/OMP process" \
    "OMP mismatched-Bun refusal did not name the identity failure"
  [ "$(wc -l < "$log" | tr -d ' ')" = "$before" ] \
    || fail "OMP mismatched-Bun refusal typed into the pane"
  pass "fm-send strict: OMP validates metadata identity and refuses composer fallback without native binding"
}

test_fm_prefixed_herdr_session_is_an_explicit_target() {
  local dir fb home err log herdr_log rc
  dir="$TMP_ROOT/fm-remote-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home fmremote); err="$dir/send.err"; log="$dir/tmux.log"; herdr_log="$dir/herdr.log"
  : > "$log"
  : > "$herdr_log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" fm-remote:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an fm-prefixed Herdr session target should be accepted as explicit"
  assert_grep 'pane get w1:p2 --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not verified in its session"
  assert_grep 'pane send-keys w1:p2 enter --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not sent its key in its session"
  assert_no_grep '--session default' "$herdr_log" "fm-prefixed Herdr target fell back to the default session"
  pass "fm-send strict: fm-prefixed Herdr sessions remain explicit backend targets"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

test_exact_lane_id_send_still_works
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_fm_prefixed_herdr_explicit_target_matches_recorded_window
test_unmatched_single_colon_target_must_exist
test_omp_send_uses_metadata_bound_bun_and_rejects_process_mismatch
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
