#!/usr/bin/env bash
# tests/fm-tmux-submit-busy.test.sh - regression: busy pane + pending composer
# after Enter retries must return "empty" (message queued), not "pending".
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-submit-busy.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# Override fm_pane_is_busy for testing: FM_FAKE_PANE_BUSY=1 means busy.
fm_pane_is_busy() {
  [ "${FM_FAKE_PANE_BUSY:-0}" = 1 ]
}

make_submit_mock() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_CURSOR_Y:-1}"; exit 0 ;; esac
    done
    exit 0 ;;
  capture-pane) cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-keys)
    shift; is_enter=0; is_literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift ;; -l) is_literal=1 ;; Enter) is_enter=1 ;; esac; shift
    done
    if [ "$is_enter" = 1 ] && [ -n "${FM_FAKE_ENTER_ATTEMPTS:-}" ]; then
      printf 'Enter\n' >> "$FM_FAKE_ENTER_ATTEMPTS"
      enter_attempt=$(wc -l < "$FM_FAKE_ENTER_ATTEMPTS")
      if [ -n "${FM_FAKE_ENTER_FAIL_AFTER:-}" ] \
         && [ "$enter_attempt" -gt "$FM_FAKE_ENTER_FAIL_AFTER" ]; then
        exit 1
      fi
    fi
    if [ "$is_enter" = 1 ] && [ "${FM_FAKE_ENTER_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    if [ "$is_literal" = 1 ] && [ -n "${FM_FAKE_AFTER_LITERAL_COMPOSER:-}" ]; then
      cp "$FM_FAKE_AFTER_LITERAL_COMPOSER" "$COMPOSER"
    fi
    if [ "$is_enter" = 1 ]; then
      [ -z "${FM_FAKE_SENT:-}" ] || printf 'Enter\n' >> "$FM_FAKE_SENT"
      [ -z "${FM_FAKE_BUSY_AFTER_ENTER:-}" ] || : > "$FM_FAKE_BUSY_AFTER_ENTER"
      [ -z "${FM_FAKE_AFTER_ENTER_COMPOSER:-}" ] || cp "$FM_FAKE_AFTER_ENTER_COMPOSER" "$COMPOSER"
      if [ -n "${FM_FAKE_SWALLOW:-}" ] && [ -f "$FM_FAKE_SWALLOW" ]; then
        [ "${FM_FAKE_PERSIST_SWALLOW:-0}" = 1 ] || rm -f "$FM_FAKE_SWALLOW"
      else
        printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$COMPOSER"
      fi
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_busy_pane_pending_returns_empty() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-accepted"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  # Pre-check: composer state should be pending (via function, not $()).
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "pre-check: composer state expected pending, got '$(cat "$vfile")'"
  # Now test the submit - write verdict to file to avoid nested $().
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane pending should return empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "proven pending should consume the configured Enter retry budget"
  pass "fm_tmux_submit_enter_core: busy pane + pending composer returns empty (message queued)"
}

test_idle_pane_pending_returns_pending() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-swallow"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] || fail "idle-pane pending should return pending, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane + pending composer stays pending (genuine swallow preserved)"
}

test_busy_omp_enter_transport_failure_returns_send_failed() {
  local dir fakebin composer vfile
  dir="$TMP_ROOT/omp-enter-fail"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > queued   │\n╰────────────╯\n' > "$composer"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_ENTER_FAIL=1 \
    FM_FAKE_PANE_BUSY=1 fm_tmux_submit_enter_core "win" 1 0 omp 1 \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = send-failed ] \
    || fail "a failed busy OMP Enter transport must return send-failed, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: busy OMP Enter transport failure returns send-failed"
}

test_busy_omp_mixed_enter_transport_retains_queued_delivery() {
  local dir fakebin composer sent attempts vfile bun top width
  if ! command -v bun >/dev/null 2>&1; then
    pass "busy OMP mixed Enter transport fixture skipped because bun is unavailable"
    return
  fi
  dir="$TMP_ROOT/omp-enter-mixed"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  attempts="$dir/attempts.log"
  vfile="$dir/verdict"
  bun=$(command -v bun)
  top='╭── ⬢ GPT-5.6-Luna · ◔ low ▶ 🌳 project ▶ ⑂ branch ▶──╮'
  width=$(fm_composer_terminal_width "$top" "$bun") \
    || fail "could not measure mixed Enter fixture width"
  printf '%s\n' "$top" > "$composer"
  printf '╰─%-*s─╯\n' "$((width - 4))" ' queued OMP steer' >> "$composer"
  : > "$sent"
  : > "$attempts"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_ENTER_ATTEMPTS="$attempts" FM_FAKE_ENTER_FAIL_AFTER=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    FM_FAKE_PANE_BUSY=1 fm_tmux_submit_enter_core "win" 3 0 omp 1 "$bun" \
    > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = queued-unconfirmed ] \
    || fail "one successful busy OMP Enter must survive later transport failures, got '$(cat "$vfile")'"
  [ "$(wc -l < "$attempts")" -eq 3 ] && [ "$(wc -l < "$sent")" -eq 1 ] \
    || fail "mixed Enter fixture did not produce one success followed by two failures"
  pass "busy OMP mixed Enter transport retains queued delivery"
}

test_busy_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "busy-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: busy pane clears composer on first Enter - returns empty"
}

test_idle_pane_composer_clears_first_try() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/idle-clear"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$composer"
  : > "$sent"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] || fail "idle-pane with cleared composer should return empty, got '$(cat "$vfile")'"
  pass "fm_tmux_submit_enter_core: idle pane clears composer on first Enter - returns empty as before"
}

test_busy_pane_unknown_stays_unknown() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-unknown"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  printf '│ > unbounded\n' > "$composer"
  : > "$sent"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown ] \
    || fail "a busy pane must not convert an unsafe composer to empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 1 ] \
    || fail "an unreadable non-OMP composer must not consume the Enter retry budget"
  pass "fm_tmux_submit_enter_core: busy conversion is limited to proven pending input"
}

test_busy_pane_ambiguous_pending_retries_without_conversion() {
  local dir fakebin composer sent vfile
  dir="$TMP_ROOT/busy-ambiguous-pending"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  : > "$sent"
  printf '╭────────────╮\n│ > fix  │\n╰────────────╯\n' > "$composer"
  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" fm_tmux_composer_state "win" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending-unproven ] \
    || fail "ambiguous composer text should be pending-unproven, got '$(cat "$vfile")'"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" FM_FAKE_PANE_BUSY=1 \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending-unproven ] \
    || fail "a busy pane must not convert pending-unproven to empty, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 3 ] \
    || fail "pending-unproven should consume the configured Enter retry budget"
  pass "fm_tmux_submit_enter_core: pending-unproven retries without busy conversion"
}

test_unrecognized_state_skips_busy_conversion() {
  local dir fakebin composer busy_called vfile
  dir="$TMP_ROOT/unrecognized-state"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  busy_called="$dir/busy-called"
  vfile="$dir/verdict"
  printf '╭─────╮\n│ >   │\n╰─────╯\n' > "$composer"
  (
    # shellcheck disable=SC2329
    fm_tmux_composer_state() { printf 'future-state'; }
    # shellcheck disable=SC2329
    fm_pane_is_busy() { touch "$busy_called"; return 0; }
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      fm_tmux_submit_enter_core "win" 3 0.05 > "$vfile" 2>/dev/null
  ) || fail "unrecognized-state submit check failed"
  [ "$(cat "$vfile")" = future-state ] \
    || fail "unrecognized state should be preserved, got '$(cat "$vfile")'"
  [ ! -e "$busy_called" ] \
    || fail "unrecognized state must not trigger busy conversion"
  pass "fm_tmux_submit_enter_core: unrecognized states skip busy conversion"
}

test_omp_composer_and_submission_use_verified_two_row_structure() {
  local dir fakebin composer sent vfile top width bun
  if ! command -v bun >/dev/null 2>&1; then
    pass "OMP tmux composer subtest skipped: bun not found"
    return
  fi
  bun=$(command -v bun)
  dir="$TMP_ROOT/omp-composer"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  sent="$dir/sent.log"
  vfile="$dir/verdict"
  : > "$sent"
  top='╭── ⬢ GPT-5.6-Luna · ◔ low ▶ 🌳 project ▶ ⑂ branch ▶──╮'
  width=$(fm_composer_terminal_width "$top" "$bun") \
    || fail "could not measure OMP fixture width"

  printf '%s\n' "$top" > "$composer"
  printf '╰─%-*s─╯\n' "$((width - 4))" ' ' >> "$composer"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
    fm_tmux_composer_state omp omp "$bun" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] \
    || fail "verified empty OMP composer should be empty, got '$(cat "$vfile")'"

  printf '%s\n' "$top" > "$composer"
  printf '╰─%-*s─╯\n' "$((width - 4))" ' queued OMP steer' >> "$composer"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
    fm_tmux_composer_state omp omp "$bun" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] \
    || fail "verified OMP composer text should be pending, got '$(cat "$vfile")'"

  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    FM_FAKE_PANE_BUSY=1 \
    fm_tmux_submit_core omp queued 1 0.01 0 omp "$bun" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = queued-unconfirmed ] \
    || fail "busy OMP submit should preserve queued-unconfirmed, got '$(cat "$vfile")'"
  [ "$(grep -c '^Enter$' "$sent" 2>/dev/null || true)" -eq 1 ] \
    || fail "busy OMP queued submit retried Enter"

  touch "$dir/.swallow"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
    FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
    FM_FAKE_PANE_BUSY=0 \
    fm_tmux_submit_core omp unsubmitted 1 0.01 0 omp "$bun" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = pending ] \
    || fail "idle OMP unsubmitted composer should remain pending, got '$(cat "$vfile")'"

  printf '%s\n╰─ malformed ─╯\n' "$top" > "$composer"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
    fm_tmux_composer_state omp omp "$bun" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown ] \
    || fail "malformed OMP composer geometry should be unknown, got '$(cat "$vfile")'"
  pass "OMP tmux composer keeps queued busy submits separate from unsubmitted input"
}

test_standalone_omp_composer_uses_shell_width_boundary() {
  local dir fakebin composer standalone called top width vfile bun legacy_width locale_name utility
  dir="$TMP_ROOT/omp-standalone-composer"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  standalone="$dir/omp"
  called="$dir/omp-called"
  vfile="$dir/verdict"
  cat > "$standalone" <<SH
#!/usr/bin/env bash
: > '$called'
exit 1
SH
  chmod +x "$standalone"
  for utility in fold wc; do
    cat > "$fakebin/$utility" <<'SH'
#!/usr/bin/env bash
exit 64
SH
    chmod +x "$fakebin/$utility"
  done
  top='╭── ⬢ GPT-5.6-Luna · ◔ low ▶ 🌳 project ▶ ⑂ branch ▶──╮'
  if bun=$(command -v bun 2>/dev/null); then
    legacy_width=$(LC_ALL=C fm_composer_terminal_width "$top" "$bun") \
      || fail "legacy Bun width boundary could not measure the structural row"
  fi
  for locale_name in C POSIX; do
    width=$(PATH="$fakebin:$PATH" LC_ALL="$locale_name" fm_composer_terminal_width "$top" "$standalone" "$standalone") \
      || fail "standalone OMP width boundary could not measure the structural row without fold or wc under $locale_name"
    [ -z "${legacy_width:-}" ] || [ "$width" = "$legacy_width" ] \
      || fail "standalone width boundary disagreed with Bun under $locale_name: $width vs $legacy_width"
  done
  width=$(PATH="$fakebin:$PATH" LC_ALL=C fm_composer_terminal_width "$top" "$standalone" "$standalone") \
    || fail "standalone OMP width boundary could not measure the structural row without fold or wc"
  {
    printf '%s\n' "$top"
    printf '╰─%-*s─╯\n' "$((width - 4))" ' '
  } > "$composer"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
    fm_tmux_composer_state omp omp "$standalone" "$standalone" > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = empty ] \
    || fail "standalone OMP composer should classify matching shell-width rows as empty, got '$(cat "$vfile")'"
  [ ! -e "$called" ] || fail "standalone OMP composer passed the extension -e option to the compiled executable"
  pass "standalone OMP composer measures width without invoking the compiled executable"
}

test_omp_idle_to_busy_preserved_and_busy_without_queue_fails_closed() {
  local dir fakebin composer busy_marker vfile
  dir="$TMP_ROOT/omp-idle-to-busy"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  busy_marker="$dir/busy"
  vfile="$dir/verdict"
  printf '│ > unbounded\n' > "$composer"
  touch "$dir/.swallow"
  (
    # shellcheck disable=SC2329
    fm_pane_is_busy() { [ -f "$busy_marker" ]; }
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_BUSY_AFTER_ENTER="$busy_marker" \
      FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
      fm_tmux_submit_core win message 1 0.01 0 omp > "$vfile" 2>/dev/null
  ) || fail "OMP idle-to-busy submit check failed"
  [ "$(cat "$vfile")" = empty ] \
    || fail "an initially idle OMP pane should confirm its busy onset, got '$(cat "$vfile")'"

  : > "$busy_marker"
  (
    # shellcheck disable=SC2329
    fm_pane_is_busy() { [ -f "$busy_marker" ]; }
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      FM_FAKE_SWALLOW="$dir/.swallow" FM_FAKE_PERSIST_SWALLOW=1 \
      fm_tmux_submit_core win message 1 0.01 0 omp > "$vfile" 2>/dev/null
  ) || fail "OMP already-busy submit check failed"
  [ "$(cat "$vfile")" = unknown ] \
    || fail "an already-busy OMP pane must not prove a new submission, got '$(cat "$vfile")'"
  pass "OMP submit preserves idle-to-busy proof and requires queue proof when already busy"
}

test_omp_busy_signature_is_exact_and_scoped() {
  printf ' ⠸ Working… ⟦esc⟧\n' | fm_busy_lines_match omp \
    || fail "live OMP Working capture should classify busy"
  printf ' ⠙ Running requested sleep ⟦esc⟧\n' | fm_busy_lines_match omp \
    || fail "live OMP Running-tool capture should classify busy"
  printf ' ⠦ Waiting thirty seconds ⟦esc⟧\n' | fm_busy_lines_match omp \
    || fail "live OMP Waiting-tool capture should classify busy"
  printf '╭── ⬢ GPT-5.6-Luna · ◔ low ▶ 🌳 project/worker-wt ▶ ⑂ fm/omp-live-worker ▶────╮\n' \
    | fm_busy_lines_match omp \
    && fail "live OMP idle status bar must not classify busy"
  printf 'Working...\n' | fm_busy_lines_match omp \
    && fail "OMP must not borrow Pi's ASCII Working signature"
  printf ' ⠸ Working… ⟦esc⟧\n' | fm_busy_lines_match pi \
    && fail "Pi must not borrow OMP's Unicode Working signature"
  printf ' ⠙ Running requested sleep ⟦esc⟧\n' | fm_busy_lines_match pi \
    && fail "Pi must not borrow OMP's Running-tool signature"
  printf 'Running requested sleep ⟦esc⟧\n' | fm_busy_lines_match omp \
    && fail "OMP Running-tool status requires its exact Braille-spinner row"
  printf ' ⠙ Running requested sleep ⟦esc⟧ trailing\n' | fm_busy_lines_match omp \
    && fail "OMP Running-tool status must stay anchored at the row end"
  printf ' ⠦ Waiting thirty seconds ⟦esc⟧ trailing\n' | fm_busy_lines_match omp \
    && fail "OMP Waiting-tool status must stay anchored at the row end"
  printf ' ⠸ Working… ⟦esc⟧\n ⠙ Running requested sleep ⟦esc⟧\n ⠦ Waiting thirty seconds ⟦esc⟧\n' \
    | fm_busy_lines_match \
    || fail "no-harness compatibility fallback should include verified OMP busy states"
  pass "OMP busy detection uses its verified Unicode status rows without widening Pi"
}

test_claude_busy_signature_uses_real_capture_shapes() {
  local dir fakebin composer
  dir="$TMP_ROOT/claude-signature"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"
  pane_busy() {
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_pane_is_busy "$2" "$3"' \
      _ "$ROOT" "$1" "${2:-}"
  }

  # Live Claude 2.1.220 capture 1: spinner glyph and word from one turn.
  printf '✢ Pollinating… (16s · ↓ 1.1k tokens · thought for 1s)\n' > "$composer"
  pane_busy live claude || fail "Claude capture 1 should be busy"

  # Live Claude 2.1.220 capture 2: a later turn with a changed glyph and word.
  printf '✽ Proofing… (5s · thinking with high effort)\n' > "$composer"
  pane_busy live claude || fail "Claude capture 2 should be busy"

  # Real idle Claude capture shape from the verified pane sample.
  printf '✻ Worked for 31s\n' > "$composer"
  pane_busy idle claude && fail "Claude Worked-for capture must be idle"

  # The new signature is Claude-scoped and must not widen the shared default.
  printf '✢ Pollinating… (16s · ↓ 1.1k tokens)\n' > "$composer"
  pane_busy live && fail "Claude signature must not match without the Claude harness"

  # Each verified harness must use only its own signature.
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy cross claude && fail "Claude must ignore Grok's cancel footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross claude && fail "Claude must ignore OpenCode's interrupt footer"
  printf 'Working...\n' > "$composer"
  pane_busy cross codex && fail "Codex must ignore Pi's Working footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross codex && fail "Codex must ignore OpenCode's interrupt footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy cross opencode && fail "OpenCode must ignore Grok's cancel footer"
  printf 'esc interrupt\n' > "$composer"
  pane_busy cross pi && fail "Pi must ignore OpenCode's interrupt footer"
  printf 'esc to interrupt\n' > "$composer"
  pane_busy cross grok && fail "Grok must ignore Claude's legacy interrupt footer"
  printf 'esc to interrupt\n' > "$composer"
  pane_busy own codex || fail "Codex's escape footer should be busy"
  printf 'esc interrupt\n' > "$composer"
  pane_busy own opencode || fail "OpenCode's interrupt footer should be busy"

  # No harness keeps the historical combined-pattern compatibility fallback.
  printf 'Working...\n' > "$composer"
  pane_busy fallback || fail "no-harness fallback should retain Pi's shared signature"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy fallback || fail "no-harness fallback should retain Grok's shared signature"

  # A supplied harness must never use another harness's signature. This is
  # particularly important for Kimi: its idle key-tip rotation can include the
  # same cancel token Grok uses to mean busy.
  printf 'Working...\n' > "$composer"
  pane_busy unknown kimi && fail "Kimi must ignore Pi's Working footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy unknown kimi && fail "idle Kimi must ignore Grok's cancel footer"

  # Older Claude Code and the existing Pi and Grok signatures remain unchanged.
  printf 'esc to interrupt\n' > "$composer"
  pane_busy old-claude claude || fail "older Claude escape footer should be busy"
  printf 'Working...\n' > "$composer"
  pane_busy pi pi || fail "Pi Working footer should be busy"
  pane_busy pi-signed pi-signed || fail "pi-signed should share Pi's exact Working footer"
  printf 'Ctrl+c:cancel\n' > "$composer"
  pane_busy grok grok || fail "Grok cancel footer should be busy"
  pass "fm_pane_is_busy: Claude spinner is scoped, multi-frame, and backward-compatible"
}

test_busy_pane_pending_returns_empty
test_idle_pane_pending_returns_pending
test_busy_omp_enter_transport_failure_returns_send_failed
test_busy_omp_mixed_enter_transport_retains_queued_delivery
test_busy_pane_composer_clears_first_try
test_idle_pane_composer_clears_first_try
test_busy_pane_unknown_stays_unknown
test_busy_pane_ambiguous_pending_retries_without_conversion
test_unrecognized_state_skips_busy_conversion
test_omp_composer_and_submission_use_verified_two_row_structure
test_standalone_omp_composer_uses_shell_width_boundary
test_omp_idle_to_busy_preserved_and_busy_without_queue_fails_closed
test_omp_busy_signature_is_exact_and_scoped
test_claude_busy_signature_uses_real_capture_shapes
