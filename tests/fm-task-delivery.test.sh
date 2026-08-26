#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> [<recorded-mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Task\nConcrete fixture task.\n\n# Acceptance criteria\n- AC1: Fixture outcome is concrete.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

test_spawn_refuses_unresolved_brief_placeholders() {
  local rec home proj fakebin out status
  rec=$(make_home placeholders)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" unresolved-task no-mistakes
  printf '\n{TASK}\n' >> "$home/data/unresolved-task/brief.md"
  out=$(run_spawn "$home" "$fakebin" unresolved-task "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an unresolved task placeholder"
  assert_contains "$out" "still contains {TASK}" "spawn did not identify the task placeholder"

  write_brief "$home" unresolved-criterion no-mistakes
  sed 's/Fixture outcome is concrete/{ACCEPTANCE CRITERION}/' \
    "$home/data/unresolved-criterion/brief.md" > "$home/data/unresolved-criterion/brief.tmp"
  mv "$home/data/unresolved-criterion/brief.tmp" "$home/data/unresolved-criterion/brief.md"
  out=$(run_spawn "$home" "$fakebin" unresolved-criterion "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an unresolved criterion placeholder"
  assert_contains "$out" "still contain placeholders" "spawn did not identify the criterion placeholder"

  write_brief "$home" concrete-braces no-mistakes
  sed 's/Fixture outcome is concrete/API returns {"ok":true}/' \
    "$home/data/concrete-braces/brief.md" > "$home/data/concrete-braces/brief.tmp"
  mv "$home/data/concrete-braces/brief.tmp" "$home/data/concrete-braces/brief.md"
  out=$(run_spawn "$home" "$fakebin" concrete-braces "$proj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "acceptance criteria are missing" "spawn rejected concrete brace syntax"
  pass "fm-spawn: unresolved task and criterion placeholders refuse before launch"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta brief ledger out status check_out check_status fakebin real_mv brief_before meta_before leftovers recovery expected_delivery actual_delivery
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state" "$home/data/promote-d1"
  meta="$home/state/promote-d1.meta"
  brief="$home/data/promote-d1/brief.md"
  ledger="$home/data/promote-d1/evidence.jsonl"

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
    cat > "$brief" <<'EOF'
# Task
Investigate the fixture and report a recommendation.

# Setup
This heading and the requirement after it belong to the task description.
Preserve this requirement when the scout becomes a ship task.

# Definition of done
Write a report.

# Setup
Scout-only setup instructions begin here.
EOF
    rm -f "$ledger"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing merge posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off --criterion 'AC1: Fixture works' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on \
    --criterion 'AC1: {TODO}' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted a placeholder criterion"
  assert_grep 'kind=scout' "$meta" "invalid criterion changed scout metadata"
  [ ! -e "$ledger" ] || fail "invalid criterion created an evidence ledger"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on \
    --criterion 'AC1: First outcome' --criterion 'AC1: Duplicate outcome' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted duplicate criterion ids"
  assert_grep 'kind=scout' "$meta" "duplicate criteria changed scout metadata"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on \
    --criterion 'AC1:    ' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted an all-whitespace criterion description"
  assert_grep 'kind=scout' "$meta" "whitespace criterion changed scout metadata"

  brief_before="$home/brief.before"
  meta_before="$home/meta.before"
  cp "$brief" "$brief_before"
  cp "$meta" "$meta_before"
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<EOF
#!/bin/sh
case "\$1" in
  ./.brief.promote.*) exit 71 ;;
  ./.brief.restore.*) [ "\${FM_FAIL_RESTORE:-0}" != 1 ] || exit 72 ;;
esac
exec "$real_mv" "\$@"
EOF
  chmod +x "$fakebin/mv"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-d1 --mode direct-PR --yolo on --criterion 'AC1: Fixture works' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion unexpectedly survived a metadata replacement failure"
  cmp -s "$brief_before" "$brief" || fail "failed promotion changed the original scout brief"
  cmp -s "$meta_before" "$meta" || fail "failed promotion changed the original scout metadata"
  [ ! -e "$ledger" ] || fail "failed promotion left a partial evidence ledger"
  leftovers=$(find "$home/data/promote-d1" "$home/state" -maxdepth 1 \
    \( -name '*.promote.*' -o -name '*.original.*' \) -print)
  [ -z "$leftovers" ] || fail "failed promotion left temporary artifacts: $leftovers"

  out=$(FM_FAIL_RESTORE=1 PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-d1 --mode direct-PR --yolo on --criterion 'AC1: Fixture works' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion unexpectedly survived a rollback failure"
  assert_contains "$out" "recovery copy retained" "rollback failure was not reported loudly"
  recovery=$(find "$home/state" -maxdepth 1 -name '.promote-d1.meta.original.*' -print)
  [ -f "$recovery" ] || fail "rollback failure destroyed the metadata recovery copy"
  "$real_mv" "$recovery" "$meta"
  cmp -s "$meta_before" "$meta" || fail "retained metadata recovery copy was not original"
  [ ! -e "$ledger" ] || fail "rollback failure left a partial evidence ledger"

  out=$(FM_PROMOTE_PINNED=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-d1 --mode direct-PR --yolo on --criterion 'AC1: API returns {"ok":true}' 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided merge posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  assert_present "$ledger" "promotion did not install the evidence ledger"
  assert_present "$home/data/promote-d1/.evidence.lock" "promotion did not install the evidence lock"
  assert_no_grep 'Never push to any remote' "$brief" "promoted direct-PR brief retained scout push prohibition"
  assert_grep 'Preserve this requirement when the scout becomes a ship task.' "$brief" "promotion truncated task content at an embedded setup heading"
  assert_grep "fm-receipt-check.sh promote-d1 --plan" "$brief" "promoted direct-PR brief omitted validation planning"
  assert_grep 'done: PR {url}' "$brief" "promoted direct-PR brief omitted its terminal sequence"
  assert_grep 'AC1: API returns {"ok":true}' "$brief" "promotion rejected concrete brace syntax"
  expected_delivery=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" --render-ship-delivery promote-d1 direct-PR)
  actual_delivery=$(awk '/^# Acceptance evidence$/{delivery=""; emit=1} emit{delivery=delivery $0 ORS} END{printf "%s", delivery}' "$brief")
  [ "$actual_delivery" = "$expected_delivery" ] || fail "promotion did not reuse fm-brief's direct-PR delivery renderer"
  check_out=$(FM_HOME="$home" "$ROOT/bin/fm-receipt-check.sh" promote-d1 2>&1)
  check_status=$?
  expect_code 1 "$check_status" "promoted concrete criteria require receipts"
  assert_contains "$check_out" '"missing":["AC1"]' "promoted contract did not install concrete acceptance criteria"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"

  mkdir -p "$home/data/promote-nm"
  printf 'window=fm-promote-nm\nkind=scout\nworktree=/tmp/wt\n' > "$home/state/promote-nm.meta"
  cat > "$home/data/promote-nm/brief.md" <<'EOF'
# Task
Implement the promoted No-Mistakes fixture.

# Setup
Scout-only setup instructions begin here.
EOF
  out=$(cd "$TMP_ROOT/promote" && FM_HOME=./home FM_STATE_OVERRIDE=./home/./state FM_DATA_OVERRIDE=./home/./data \
    "$PROMOTE" promote-nm --mode no-mistakes --yolo off --criterion 'AC1: Fixture works' 2>&1)
  status=$?
  expect_code 0 "$status" "a No-Mistakes promotion should succeed"
  assert_grep 'Firstmate-Validation-Generation: <plan-generation>' "$home/data/promote-nm/brief.md" "promoted No-Mistakes brief omitted generation-bound run creation"
  assert_grep 'fm-receipt-check.sh promote-nm --bind-run <run-id> --generation <plan-generation>' "$home/data/promote-nm/brief.md" "promoted No-Mistakes brief omitted run binding"
  assert_grep 'fm-receipt-check.sh promote-nm --complete --terminal-evidence no-mistakes-passed' "$home/data/promote-nm/brief.md" "promoted No-Mistakes brief omitted completion recording"
  assert_grep 'done: PR {url} checks green' "$home/data/promote-nm/brief.md" "promoted No-Mistakes brief omitted its CI-ready terminal status"
  expected_delivery=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" --render-ship-delivery promote-nm no-mistakes)
  actual_delivery=$(awk '/^# Acceptance evidence$/{delivery=""; emit=1} emit{delivery=delivery $0 ORS} END{printf "%s", delivery}' "$home/data/promote-nm/brief.md")
  [ "$actual_delivery" = "$expected_delivery" ] || fail "promotion did not reuse fm-brief's No-Mistakes delivery renderer"
  pass "fm-promote: promotion installs a fail-closed ship evidence contract"
}

test_promote_rejects_symlinked_task_directory() {
  local home outside before out status
  home="$TMP_ROOT/promote-symlink/home"
  outside="$TMP_ROOT/promote-symlink/outside"
  mkdir -p "$home/state" "$home/data" "$outside"
  printf 'window=fm-promote-link\nkind=scout\nworktree=/tmp/wt\n' > "$home/state/promote-link.meta"
  printf '# Task\nOutside scout.\n\n# Setup\nScout setup.\n' > "$outside/brief.md"
  before=$(cksum "$outside/brief.md")
  ln -s "$outside" "$home/data/promote-link"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-link --mode direct-PR --yolo off \
    --criterion 'AC1: Concrete outcome' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted a symlinked task directory"
  assert_contains "$out" "task directory is missing or unsafe" "promotion did not identify the unsafe task directory"
  [ "$(cksum "$outside/brief.md")" = "$before" ] || fail "refused promotion changed the outside brief"
  [ ! -e "$outside/evidence.jsonl" ] || fail "refused promotion created an outside ledger"
  pass "fm-promote: symlinked task directories refuse before mutation"
}

test_promote_rejects_symlinked_data_override() {
  local home outside before out status
  home="$TMP_ROOT/promote-data-symlink/home"
  outside="$TMP_ROOT/promote-data-symlink/outside"
  mkdir -p "$home/state" "$outside/promote-link"
  printf 'window=fm-promote-link\nkind=scout\nworktree=/tmp/wt\n' > "$home/state/promote-link.meta"
  printf '# Task\nOutside scout.\n\n# Setup\nScout setup.\n' > "$outside/promote-link/brief.md"
  before=$(cksum "$outside/promote-link/brief.md")
  ln -s "$outside" "$home/data-link"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data-link" \
    "$PROMOTE" promote-link --mode direct-PR --yolo off --criterion 'AC1: Concrete outcome' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted a symlinked data override"
  assert_contains "$out" "data path component is missing or unsafe" "promotion hid the configured data symlink before pinning"
  [ "$(cksum "$outside/promote-link/brief.md")" = "$before" ] || fail "refused data override changed the outside brief"
  [ ! -e "$outside/promote-link/evidence.jsonl" ] || fail "refused data override created an outside ledger"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data-link/../data-link" \
    "$PROMOTE" promote-link --mode direct-PR --yolo off --criterion 'AC1: Concrete outcome' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted lexical parent traversal"
  assert_contains "$out" "data path contains unsafe traversal" "promotion did not reject lexical parent traversal"
  pass "fm-promote: configured data symlinks remain visible to no-follow pinning"
}

test_concurrent_promotion_preserves_winner_lock() {
  local home id=promote-race first second successes=0
  home="$TMP_ROOT/promote-race/home"
  mkdir -p "$home/state" "$home/data/$id"
  printf 'window=fm-promote-race\nkind=scout\nworktree=/tmp/wt\n' > "$home/state/$id.meta"
  printf '# Task\nRace promotion.\n\n# Setup\nScout setup.\n' > "$home/data/$id/brief.md"
  FM_HOME="$home" "$PROMOTE" "$id" --mode direct-PR --yolo off --criterion 'AC1: Concrete outcome' \
    > "$home/first.out" 2>&1 &
  first=$!
  FM_HOME="$home" "$PROMOTE" "$id" --mode direct-PR --yolo off --criterion 'AC1: Concrete outcome' \
    > "$home/second.out" 2>&1 &
  second=$!
  if wait "$first"; then successes=$((successes + 1)); fi
  if wait "$second"; then successes=$((successes + 1)); fi
  [ "$successes" -eq 1 ] || fail "concurrent promotion did not produce exactly one winner"
  assert_present "$home/data/$id/.evidence.lock" "losing promotion removed the winner's evidence lock"
  assert_present "$home/data/$id/evidence.jsonl" "winning promotion did not retain its evidence ledger"
  assert_grep 'kind=ship' "$home/state/$id.meta" "winning promotion did not retain ship metadata"
  pass "fm-promote: concurrent losers cannot remove the winner lock"
}

test_signaled_promotion_transaction_fails() {
  local home id=promote-signal transaction status
  home="$TMP_ROOT/promote-signal/home"
  transaction="$home/signaled-transaction.sh"
  mkdir -p "$home/data/$id" "$home/state"
  printf '# Task\nSignal fixture.\n' > "$home/data/$id/brief.md"
  cat > "$transaction" <<'SH'
#!/bin/sh
kill -TERM "$$"
SH
  chmod +x "$transaction"
  FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-receipt-store.sh" "$id" promote "$transaction" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "signal-terminated promotion transaction reported success"
  pass "fm-promote: signal-terminated transactions fail closed"
}

test_interrupted_replacements_roll_back() {
  local stage home id fakebin real_mv trigger brief_before meta_before status leftovers
  real_mv=$(command -v mv)
  for stage in brief; do
    id="promote-interrupt-$stage"
    home="$TMP_ROOT/$id/home"
    fakebin="$home/fakebin"
    trigger="$home/kill-trigger"
    mkdir -p "$home/data/$id" "$home/state" "$fakebin"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$home/state/$id.meta"
    printf '# Task\nInterrupted promotion.\n\n# Setup\nScout setup.\n' > "$home/data/$id/brief.md"
    brief_before="$home/brief.before"
    meta_before="$home/meta.before"
    cp "$home/data/$id/brief.md" "$brief_before"
    cp "$home/state/$id.meta" "$meta_before"
    : > "$trigger"
    cat > "$fakebin/mv" <<EOF
#!/bin/sh
source_path=\$1
destination_path=\$2
should_kill=0
case "$stage:\$source_path:\$destination_path" in
  brief:./.brief.promote.*:./brief.md) should_kill=1 ;;
esac
"$real_mv" "\$@" || exit
if [ "\$should_kill" -eq 1 ] && [ -f "$trigger" ]; then
  rm -f "$trigger"
  kill -KILL "\$PPID"
fi
EOF
    chmod +x "$fakebin/mv"
    PATH="$fakebin:$PATH" FM_HOME="$home" "$PROMOTE" "$id" --mode direct-PR --yolo off \
      --criterion 'AC1: Concrete outcome' >/dev/null 2>&1
    status=$?
    [ "$status" -ne 0 ] || fail "$stage replacement interruption reported success"
    cmp -s "$brief_before" "$home/data/$id/brief.md" || fail "$stage interruption did not restore the scout brief"
    cmp -s "$meta_before" "$home/state/$id.meta" || fail "$stage interruption did not restore scout metadata"
    [ ! -e "$home/data/$id/evidence.jsonl" ] || fail "$stage interruption retained a partial evidence ledger"
    leftovers=$(find "$home/data/$id" "$home/state" -maxdepth 1 \
      \( -name '*.promote.*' -o -name '*.original.*' -o -name '.promotion.*' \) -print)
    [ -z "$leftovers" ] || fail "$stage interruption left transaction artifacts: $leftovers"
  done
  pass "fm-promote: interrupted task replacement rolls back atomically"
}

test_store_signals_roll_back_before_commit() {
  local stage home id wrapper brief_before meta_before status leftovers
  for stage in brief meta; do
    id="promote-store-signal-$stage"
    home="$TMP_ROOT/$id/home"
    wrapper="$home/transaction-wrapper.sh"
    mkdir -p "$home/data/$id" "$home/state"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$home/state/$id.meta"
    printf '# Task\nStore signal fixture.\n\n# Setup\nScout setup.\n' > "$home/data/$id/brief.md"
    brief_before="$home/brief.before"
    meta_before="$home/meta.before"
    cp "$home/data/$id/brief.md" "$brief_before"
    cp "$home/state/$id.meta" "$meta_before"
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -eu
phase=\$1
"$ROOT/bin/fm-promote-transaction.sh" "\$@"
case "$stage:\$phase" in
  brief:prepare|meta:precommit) kill -TERM "\$PPID" ;;
esac
EOF
    chmod +x "$wrapper"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      "$ROOT/bin/fm-receipt-store.sh" "$id" promote "$wrapper" "$id" direct-PR off '- AC1: Concrete outcome' \
      >/dev/null 2>&1
    status=$?
    [ "$status" -ne 0 ] || fail "$stage-boundary store signal reported success"
    cmp -s "$brief_before" "$home/data/$id/brief.md" || fail "$stage-boundary store signal did not restore the brief"
    cmp -s "$meta_before" "$home/state/$id.meta" || fail "$stage-boundary store signal did not restore metadata"
    [ ! -e "$home/data/$id/evidence.jsonl" ] || fail "$stage-boundary store signal retained evidence"
    leftovers=$(find "$home/data/$id" "$home/state" -maxdepth 1 \
      \( -name '*.promote.*' -o -name '*.original.*' -o -name '.promotion.*' \) -print)
    [ -z "$leftovers" ] || fail "$stage-boundary store signal left transaction artifacts: $leftovers"
  done
  pass "fm-promote: store signals before commit roll back both replacements"
}

test_promote_rejects_intermediate_state_symlink() {
  local home outside before out status id=promote-state-link
  home="$TMP_ROOT/promote-state-link/home"
  outside="$TMP_ROOT/promote-state-link/outside"
  mkdir -p "$home/data/$id" "$outside/tasks"
  printf '# Task\nState symlink fixture.\n\n# Setup\nScout setup.\n' > "$home/data/$id/brief.md"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$outside/tasks/$id.meta"
  before=$(cksum "$outside/tasks/$id.meta")
  ln -s "$outside" "$home/state-link"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state-link/tasks" FM_DATA_OVERRIDE="$home/data" \
    "$PROMOTE" "$id" --mode direct-PR --yolo off --criterion 'AC1: Concrete outcome' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted an intermediate state symlink"
  assert_contains "$out" "state path component is missing or unsafe" "promotion did not identify the state symlink"
  [ "$(cksum "$outside/tasks/$id.meta")" = "$before" ] || fail "refused state symlink changed outside metadata"
  [ ! -e "$home/data/$id/evidence.jsonl" ] || fail "refused state symlink created evidence"
  pass "fm-promote: intermediate state symlinks fail closed"
}

test_state_path_replacement_cannot_redirect_promotion() {
  local home moved outside wrapper id=promote-state-race
  home="$TMP_ROOT/promote-state-race/home"
  moved="$TMP_ROOT/promote-state-race/moved-state"
  outside="$TMP_ROOT/promote-state-race/outside-state"
  wrapper="$home/transaction-wrapper.sh"
  mkdir -p "$home/data/$id" "$home/state" "$outside"
  printf '# Task\nState replacement fixture.\n\n# Setup\nScout setup.\n' > "$home/data/$id/brief.md"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$home/state/$id.meta"
  printf 'outside=unchanged\n' > "$outside/$id.meta"
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -eu
phase=\$1
"$ROOT/bin/fm-promote-transaction.sh" "\$@"
if [ "\$phase" = prepare ]; then
  mv "$home/state" "$moved"
  ln -s "$outside" "$home/state"
fi
EOF
  chmod +x "$wrapper"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-receipt-store.sh" "$id" promote "$wrapper" "$id" direct-PR off '- AC1: Concrete outcome' \
    >/dev/null || fail "pinned state replacement promotion failed"
  assert_grep 'kind=ship' "$moved/$id.meta" "promotion did not update the pinned state directory"
  assert_grep 'outside=unchanged' "$outside/$id.meta" "promotion redirected metadata into the replacement state path"
  assert_no_grep 'kind=ship' "$outside/$id.meta" "replacement state metadata was mutated"
  pass "fm-promote: state path replacement cannot redirect metadata"
}

test_crashed_promotion_recovers_on_retry() {
  local home wrapper id=promote-crash-retry status
  home="$TMP_ROOT/promote-crash-retry/home"
  wrapper="$home/crash-wrapper.sh"
  mkdir -p "$home/data/$id" "$home/state"
  printf '# Task\nCrash recovery fixture.\n\n# Setup\nScout setup.\n' > "$home/data/$id/brief.md"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$home/state/$id.meta"
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -eu
phase=\$1
"$ROOT/bin/fm-promote-transaction.sh" "\$@"
if [ "\$phase" = prepare ]; then
  kill -KILL "\$PPID"
fi
EOF
  chmod +x "$wrapper"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-receipt-store.sh" "$id" promote "$wrapper" "$id" direct-PR off '- AC1: Concrete outcome' \
    >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "crashed promotion unexpectedly reported success"
  FM_HOME="$home" "$PROMOTE" "$id" --mode direct-PR --yolo off --criterion 'AC1: Concrete outcome' \
    >/dev/null || fail "retry did not recover and complete the unfinished promotion"
  assert_grep 'kind=ship' "$home/state/$id.meta" "recovered promotion did not commit ship metadata"
  assert_present "$home/data/$id/evidence.jsonl" "recovered promotion did not commit evidence"
  pass "fm-promote: retry recovers an identity-bound crashed transaction"
}

test_report_failure_preserves_committed_promotion() {
  local home wrapper id=promote-report-failure
  home="$TMP_ROOT/promote-report-failure/home"
  wrapper="$home/report-wrapper.sh"
  mkdir -p "$home/data/$id" "$home/state"
  printf '# Task\nReport failure fixture.\n\n# Setup\nScout setup.\n' > "$home/data/$id/brief.md"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$home/state/$id.meta"
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
set -eu
[ "\$1" != report ] || exit 9
exec "$ROOT/bin/fm-promote-transaction.sh" "\$@"
EOF
  chmod +x "$wrapper"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-receipt-store.sh" "$id" promote "$wrapper" "$id" direct-PR off '- AC1: Concrete outcome' \
    >/dev/null 2>&1 || fail "post-commit report failure changed promotion success"
  assert_grep 'kind=ship' "$home/state/$id.meta" "report failure lost committed ship metadata"
  assert_present "$home/data/$id/evidence.jsonl" "report failure lost committed evidence"
  pass "fm-promote: post-commit reporting cannot reverse success"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_spawn_refuses_unresolved_brief_placeholders
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_promote_rejects_symlinked_task_directory
test_promote_rejects_symlinked_data_override
test_concurrent_promotion_preserves_winner_lock
test_signaled_promotion_transaction_fails
test_interrupted_replacements_roll_back
test_store_signals_roll_back_before_commit
test_promote_rejects_intermediate_state_symlink
test_state_path_replacement_cannot_redirect_promotion
test_crashed_promotion_recovers_on_retry
test_report_failure_preserves_committed_promotion
test_project_mode_maps_the_conditional_policy
echo "# all fm-task-delivery tests passed"
