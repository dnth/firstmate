#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  out=$(LC_ALL=C classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph must read empty under LC_ALL=C, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(LC_ALL=C classify 0 '❯ déployer 🚢'); [ "$out" = pending ] || fail "real Unicode text after a prompt glyph must remain pending under LC_ALL=C, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

assert_standalone_width_expected() {
  local runtime=$1 label=$2 expected=$3 row=$4 actual
  actual=$(fm_composer_terminal_width "$row" "$runtime" "$runtime") \
    || fail "standalone width failed for $label"
  [ "$actual" = "$expected" ] \
    || fail "standalone width for $label was $actual, expected $expected"
}

assert_standalone_width_matches_bun() {
  local bun=$1 label=$2 row=$3 expected actual
  expected=$("$bun" -e 'process.stdout.write(String(Bun.stringWidth(process.argv[1])))' "$row")
  actual=$(fm_composer_terminal_width "$row" "$bun" "$bun") \
    || fail "standalone width failed for $label"
  [ "$actual" = "$expected" ] \
    || fail "standalone width for $label was $actual, Bun.stringWidth returned $expected"
}

test_standalone_width_has_fixed_unicode_contract() {
  local node_bin case_spec label expected row
  node_bin=$(command -v node 2>/dev/null) || fail "standalone width contract requires node"
  local cases=(
    $'VS15 text presentation\t1\t❤︎'
    $'VS16 emoji presentation\t2\t❤️'
    $'digit plus VS16\t1\t0️'
    $'unqualified keycap\t2\t1⃣'
    $'qualified keycap\t2\t1️⃣'
    $'combining mark\t1\té'
    $'bare ZWJ\t0\t‍'
    $'dangling emoji ZWJ\t2\t❤‍'
    $'lone regional indicator\t1\t🇮'
    $'regional-indicator flag\t2\t🇮🇳'
    $'emoji modifier base\t2\t✍🏻'
    $'valid emoji modifier\t2\t👍🏻'
    $'invalid ASCII modifier\t3\ta🏻'
    $'CJK\t2\t界'
    $'decomposed Hangul Jamo\t3\t하'
    $'precomposed Hangul plus trailing Jamo\t3\t각'
    $'genuine family ZWJ emoji\t2\t👩‍👩‍👧‍👦'
    $'Unicode 17 unassigned emoji candidate\t1\t🫩'
    $'OMP status row\t55\t╭── ⬢ GPT-5.6-Luna · ◔ low ▶ 🌳 project ▶ ⑂ branch ▶──╮'
  )
  for case_spec in "${cases[@]}"; do
    IFS=$'\t' read -r label expected row <<< "$case_spec"
    assert_standalone_width_expected "$node_bin" "$label" "$expected" "$row"
  done
  pass "standalone width has deterministic compiled-OMP-compatible Unicode fixtures"
}

test_standalone_width_matches_bun_for_unicode_graphemes() {
  local bun case_spec label row
  if ! bun=$(command -v bun 2>/dev/null); then
    pass "optional standalone width parity skipped because bun is unavailable"
    return
  fi
  local cases=(
    $'VS15 text presentation\t❤︎'
    $'VS16 emoji presentation\t❤️'
    $'digit plus VS16\t0️'
    $'unqualified keycap\t1⃣'
    $'qualified keycap\t1️⃣'
    $'combining mark\té'
    $'bare ZWJ\t‍'
    $'dangling emoji ZWJ\t❤‍'
    $'lone regional indicator\t🇮'
    $'regional-indicator flag\t🇮🇳'
    $'emoji modifier base\t✍🏻'
    $'valid emoji modifier\t👍🏻'
    $'invalid ASCII modifier\ta🏻'
    $'CJK\t界'
    $'decomposed Hangul Jamo\t하'
    $'precomposed Hangul plus trailing Jamo\t각'
    $'genuine family ZWJ emoji\t👩‍👩‍👧‍👦'
    $'Unicode 17 unassigned emoji candidate\t🫩'
    $'OMP status row\t╭── ⬢ GPT-5.6-Luna · ◔ low ▶ 🌳 project ▶ ⑂ branch ▶──╮'
  )
  for case_spec in "${cases[@]}"; do
    IFS=$'\t' read -r label row <<< "$case_spec"
    assert_standalone_width_matches_bun "$bun" "$label" "$row"
  done
  pass "standalone width matches installed Bun.stringWidth for Unicode fixtures and the OMP status row"
}

test_queued_enter_verdict_busy_pending_is_empty() {
  local out
  out=$(fm_composer_queued_enter_verdict pending busy)
  [ "$out" = empty ] || fail "busy + proven pending must be queued delivery (empty), got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + busy returns empty (queued Enter)"
}

test_queued_enter_verdict_idle_pending_stays_pending() {
  local out
  out=$(fm_composer_queued_enter_verdict pending idle)
  [ "$out" = pending ] || fail "idle + proven pending must stay a genuine swallow, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending unknown)
  [ "$out" = pending ] || fail "unknown busy is not proof of a queue, got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + idle/unknown stays pending"
}

test_queued_enter_verdict_does_not_convert_other_states() {
  local state out
  for state in empty pending-unproven unknown send-failed future-state; do
    out=$(fm_composer_queued_enter_verdict "$state" busy)
    [ "$out" = "$state" ] || fail "busy must not convert '$state', got '$out'"
    out=$(fm_composer_queued_enter_verdict "$state" idle)
    [ "$out" = "$state" ] || fail "idle must not convert '$state', got '$out'"
  done
  pass "fm_composer_queued_enter_verdict: only proven pending is converted"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_standalone_width_has_fixed_unicode_contract
test_standalone_width_matches_bun_for_unicode_graphemes
test_queued_enter_verdict_busy_pending_is_empty
test_queued_enter_verdict_idle_pending_stays_pending
test_queued_enter_verdict_does_not_convert_other_states
