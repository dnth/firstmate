#!/usr/bin/env bash
# Tests for the OMP supervision branch's fleet-record layer
# (docs/omp-supervision-branch.md): the byte-stable branch prompt generator
# (bin/fm-branch-prompt.sh), the append-only outcome store
# (bin/fm-branch-outcome.sh), the per-task lease contract (bin/fm-lease.sh,
# bin/fm-lease-lib.sh), the role-partition and lease guards wired into the
# mutating entrypoints, and the proof that a home which never runs the branch is
# untouched by all of it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-branch-supervision)

# --- byte-stable branch prompt ------------------------------------------------

test_branch_prompt_is_byte_stable_and_above_cache_floor() {
  local home_a home_b out_a out_b out_c size
  home_a="$TMP_ROOT/prompt-home-a"
  home_b="$TMP_ROOT/prompt-home-b"
  mkdir -p "$home_a/state" "$home_b/state"
  # Two homes with deliberately different fleet state and clock context: a
  # byte-stable prompt must absorb none of it.
  printf 'signal: task-1 done\n' > "$home_a/state/task-1.status"
  printf 'window=x\nharness=omp\n' > "$home_a/state/task-1.meta"

  out_a=$(cd "$TMP_ROOT" && FM_HOME="$home_a" TZ=UTC "$ROOT/bin/fm-branch-prompt.sh") \
    || fail "branch prompt generator failed for home A"
  out_b=$(cd / && FM_HOME="$home_b" TZ=Australia/Eucla "$ROOT/bin/fm-branch-prompt.sh") \
    || fail "branch prompt generator failed for home B"
  sleep 1
  out_c=$("$ROOT/bin/fm-branch-prompt.sh") || fail "branch prompt generator failed on re-run"

  [ "$out_a" = "$out_b" ] || fail "branch prompt differs across homes/cwd/timezone: prefix stability broken"
  [ "$out_a" = "$out_c" ] || fail "branch prompt differs across runs at different times: prefix stability broken"

  # Below the provider's caching minimum a branch prompt gets no reuse at all,
  # so hold a comfortable byte floor.
  size=${#out_a}
  [ "$size" -ge 5000 ] || fail "branch prompt is only $size bytes - below the provider caching minimum"
  case "$out_a" in
    "You are the SUPERVISION BRANCH"*) ;;
    *) fail "branch prompt lost its role preamble" ;;
  esac
  case "$out_a" in
    *"stuck-crewmate-recovery"*) ;;
    *) fail "branch prompt lost the inlined recovery playbook" ;;
  esac
  # The port names OMP, not Pi, and references no fork-absent fm-control.sh.
  case "$out_a" in *"one Pi process"*) fail "branch prompt still names a Pi process" ;; esac
  case "$out_a" in *"fm-control.sh"*) fail "branch prompt references fork-absent bin/fm-control.sh" ;; esac
  pass "branch prompt is byte-stable across homes, cwd, timezone, and time, above the cache floor, OMP-named"
}

# --- append-only outcome store ------------------------------------------------

test_outcome_store_is_append_only_with_cursor_reads() {
  local home store snapshot seq1 seq2 unread replay out status
  home="$TMP_ROOT/store-home"
  mkdir -p "$home/state"
  store="$home/state/branch-outcomes.jsonl"

  seq1=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict routine --summary 'worker healthy, "quoted" text kept' --wake 'signal: working') \
    || fail "first append failed"
  [ "$seq1" = 1 ] || fail "first outcome seq was $seq1, not 1"
  seq2=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict captain --summary 'PR https://example.com/pr/2 checks green') \
    || fail "second append failed"
  [ "$seq2" = 2 ] || fail "second outcome seq was $seq2, not 2"

  python3 - "$store" <<'PY' || fail "outcome store holds invalid JSON"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert [row["seq"] for row in rows] == [1, 2], rows
assert rows[0]["verdict"] == "routine" and rows[1]["verdict"] == "captain", rows
assert rows[0]["summary"] == 'worker healthy, "quoted" text kept', rows[0]
assert rows[0]["silent"] is False and rows[1]["silent"] is False, rows
PY

  snapshot=$(cat "$store")
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" mark-read --through 1 || fail "mark-read failed"
  unread=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread) || fail "unread failed"
  case "$unread" in
    '{"seq":2,'*) ;;
    *) fail "unread did not return exactly the records above the cursor: $unread" ;;
  esac
  [ "$(cat "$store")" = "$snapshot" ] || fail "mark-read rewrote the append-only store"

  replay=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay) || fail "startup-replay failed"
  assert_contains "$replay" "BRANCH OUTCOMES" "replay lost its section header"
  assert_contains "$replay" "https://example.com/pr/2" "replay lost the unread outcome"
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay)" ] \
    || fail "startup-replay re-presented already-read outcomes"

  printf '{"seq":4,"epoch":' >> "$store"
  snapshot=$(cat "$store")
  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-5 --verdict captain --summary 'must remain unrecorded' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "append accepted a malformed outcome-store tail"
  assert_contains "$out" "malformed final record" "torn-tail refusal lost its diagnostic"
  [ "$(cat "$store")" = "$snapshot" ] || fail "failed append changed the torn outcome store"
  pass "outcome store is append-only and refuses sequence reuse after a torn tail"
}

test_outcome_startup_replay_preserves_silence() {
  local home replay
  home="$TMP_ROOT/store-silent-home"
  mkdir -p "$home/state"

  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task fleet --verdict routine --summary 'fleet reviewed, nothing changed' --silent true >/dev/null \
    || fail "silent outcome append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict routine --summary 'worker recovered automatically' >/dev/null \
    || fail "visible outcome append failed"

  replay=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay) || fail "mixed startup replay failed"
  assert_not_contains "$replay" "fleet reviewed, nothing changed" "startup replay printed a silent outcome"
  assert_contains "$replay" "worker recovered automatically" "startup replay lost a visible routine outcome"
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" ] \
    || fail "startup replay did not mark the silent and visible rows read"
  pass "startup replay skips silent outcomes and preserves visible rows"
}

test_outcome_live_handoff_requires_contiguous_sequence() {
  local home out status replay unread
  home="$TMP_ROOT/store-contiguous-home"
  mkdir -p "$home/state"

  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-1 --verdict routine --summary 'first durable outcome' >/dev/null \
    || fail "first contiguous-handoff append failed"
  FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-2 --verdict routine --summary 'second durable outcome' >/dev/null \
    || fail "second contiguous-handoff append failed"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" handoff-next --seq 2 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "live handoff skipped unread seq 1 and advanced through seq 2"
  assert_contains "$out" "not the next unread record" "gap refusal lost its diagnostic"
  unread=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread) || fail "unread after gap refusal failed"
  assert_contains "$unread" '"seq":1' "gap refusal lost unread seq 1"
  assert_contains "$unread" '"seq":2' "gap refusal lost unread seq 2"

  replay=$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" startup-replay) || fail "startup replay after gap refusal failed"
  assert_contains "$replay" "first durable outcome" "startup replay lost the earlier unread outcome"
  assert_contains "$replay" "second durable outcome" "startup replay lost the later unread outcome"
  [ -z "$(FM_HOME="$home" "$ROOT/bin/fm-branch-outcome.sh" unread)" ] \
    || fail "startup replay did not acknowledge the complete unread prefix"
  pass "live outcome handoff refuses gaps and leaves the complete unread prefix for startup replay"
}

# --- lease contract -----------------------------------------------------------

test_lease_exclusivity_release_stale_and_sweep() {
  local home out status
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/lease-home"
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"

  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 --actor branch \
    || fail "branch claim failed"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-1) || fail "check missed a held lease"
  case "$out" in
    "branch $$ "*" live") ;;
    *) fail "check misreported the lease: $out" ;;
  esac
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 2>&1)
  status=$?
  [ "$status" -eq 6 ] || fail "cross-actor claim exited $status, not the lease refusal 6"
  assert_contains "$out" "leased to the branch supervision actor" "refusal did not name the holder"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-1 \
    || fail "same-actor refresh was refused"

  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release task-1 --actor branch || fail "release failed"
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-1 >/dev/null && fail "released lease still reported"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-lease.sh" release task-1 --actor branch || fail "idempotent release failed"

  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-dead \
    || fail "stale lease blocked a live claim"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-lease.sh" check task-dead)
  case "$out" in "main $$ "*) ;; *) fail "stale lease was not taken over: $out" ;; esac
  printf 'branch\t999999\t123\n' > "$home/state/.lease-task-dead2"
  FM_HOME="$home" "$ROOT/bin/fm-lease.sh" sweep || fail "sweep failed"
  [ ! -e "$home/state/.lease-task-dead2" ] || fail "sweep left a provably stale lease"
  [ -e "$home/state/.lease-task-dead" ] || fail "sweep removed a live lease"

  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim backlog --actor branch \
    || fail "backlog lease claim failed"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim backlog 2>&1)
  [ $? -eq 6 ] || fail "backlog lease did not enforce exclusivity"
  pass "lease exclusivity, same-actor refresh, release, staleness, and sweep hold"
}

# --- role-partition guards ----------------------------------------------------

test_role_partition_refuses_the_branch_actor() {
  local home status out
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/partition-home"
  mkdir -p "$home/state"

  # fm-pr-merge and fm-merge-local refuse the branch outright (before any work).
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-pr-merge.sh" task-x 'https://github.com/o/r/pull/1' >/dev/null 2>&1
  [ $? -eq 6 ] || fail "fm-pr-merge did not refuse the branch actor"
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-merge-local.sh" task-x >/dev/null 2>&1
  [ $? -eq 6 ] || fail "fm-merge-local did not refuse the branch actor"
  # fm-spawn refuses a fresh spawn by the branch.
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-spawn.sh" task-x "$home" --secondmate >/dev/null 2>&1
  [ $? -eq 6 ] || fail "fm-spawn did not refuse a branch fresh spawn"
  # Forced teardown discards work and is refused for the branch.
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$ROOT/bin/fm-teardown.sh" task-x --force 2>&1)
  [ $? -eq 6 ] || fail "forced teardown did not refuse the branch actor"
  assert_contains "$out" "cannot discard work" "forced-teardown refusal lost its diagnostic"

  # Main (no actor set) passes every guard: each fails later for its ordinary
  # reason (invalid args / missing task), never the lease refusal 6.
  FM_HOME="$home" "$ROOT/bin/fm-pr-merge.sh" >/dev/null 2>&1
  [ $? -ne 6 ] || fail "fm-pr-merge refused main"
  FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" task-x --force >/dev/null 2>&1
  status=$?
  [ "$status" -ne 6 ] || fail "forced teardown refused main"
  pass "the role partition refuses the branch actor from merge, land, fresh spawn, and forced discard"
}

test_send_lease_guard_serializes_a_held_task() {
  local home window out status
  local -x PI_CODING_AGENT=true
  home="$TMP_ROOT/send-guard-home"
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  window="fm-send-guard"
  # A meta the target resolver resolves to a real backend target, so the guard
  # is actually reached (a resolution that fails before the guard would let a
  # broken guard pass green).
  printf 'window=%s\nbackend=tmux\n' "$window" > "$home/state/task-guard.meta"
  # First prove the resolver reaches the guard at all: with NO branch lease, the
  # same steer must NOT be refused with the lease-refusal exit 6. This fails if
  # the resolver rejects the target before the guard, so a green result below
  # cannot come from an unresolved target.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-send.sh" task-guard "hello" 2>&1)
  [ "$?" -ne 6 ] || fail "fm-send refused with the lease exit before any lease was held: $out"
  # Branch holds the task's lease.
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID=$$ "$ROOT/bin/fm-lease.sh" claim task-guard --actor branch \
    || fail "branch lease claim failed"
  # Main's steer of the same task is now refused by the wired fm-send guard with
  # exit 6 and the holder diagnostic, before any backend delivery (the guard
  # runs before the delivery code, so exit 6 is proof of no delivery side effect).
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main "$ROOT/bin/fm-send.sh" task-guard "hello" 2>&1)
  [ "$?" -eq 6 ] || fail "fm-send did not refuse a main steer while the branch holds the lease: $out"
  assert_contains "$out" "leased to the branch supervision actor" "fm-send refusal lost the holder"
  out=$(FM_HOME="$home" FM_SUPERVISION_ACTOR=main "$ROOT/bin/fm-teardown.sh" task-guard 2>&1)
  [ "$?" -eq 6 ] || fail "fm-teardown did not refuse main while the branch holds the task lease: $out"
  assert_contains "$out" "leased to the branch supervision actor" "fm-teardown refusal lost the holder"
  [ ! -e "$home/state/.fm-lease-command.lock" ] || fail "a refused main mutation left the lease-command lock behind"
  pass "main steer and teardown refuse before mutation while the branch holds the task lease"
}

# --- inert in a home that never runs the branch -------------------------------

test_non_branch_home_is_untouched() {
  local home out status
  home="$TMP_ROOT/inert-home"
  mkdir -p "$home/state"

  # No actor variable, no PI_CODING_AGENT: every guard is a silent no-op and
  # main's ordinary failures come through unchanged.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-teardown.sh" task-none 2>&1)
  status=$?
  [ "$status" -ne 6 ] || fail "a non-branch teardown hit the lease refusal"
  assert_not_contains "$out" "cannot discard work" "a non-branch teardown hit the branch-discard refusal"
  assert_not_contains "$out" "supervision actor" "a non-branch teardown hit a lease refusal"

  STATE="$home/state" PI_CODING_AGENT=true FM_SUPERVISION_ACTOR=main bash -c '
    . "$1"
    fm_lease_guard task-none "OMP main steer"
    [ "$FM_LEASE_GUARD_LOCK" = "$STATE/.fm-lease-command.lock" ]
    [ -e "$STATE/.fm-lease-command.lock" ]
    fm_lease_guard_release
    [ ! -e "$STATE/.fm-lease-command.lock" ]
  ' _ "$ROOT/bin/fm-lease-lib.sh" || fail "an explicit OMP main actor did not retain and release the lease-command lock"

  # Pi sets PI_CODING_AGENT in ordinary sessions too. Without an explicit
  # supervision actor or an existing task lease, that ambient marker alone must
  # not retain the OMP branch's global command lock.
  STATE="$home/state" PI_CODING_AGENT=true bash -c '
    . "$1"
    fm_lease_guard task-none "plain Pi steer"
    [ -z "$FM_LEASE_GUARD_LOCK" ]
    [ ! -e "$STATE/.fm-lease-command.lock" ]
  ' _ "$ROOT/bin/fm-lease-lib.sh" || fail "a bare Pi coding-agent marker retained the OMP lease-command lock"

  # A plain main wake drain writes no branch/actor state at all.
  local lib="$ROOT/bin/fm-wake-lib.sh"
  FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_wake_append "$2" "$3" "$4"' _ "$lib" check "p.check.sh" "check: p" \
    || fail "wake append failed"
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || fail "plain main drain failed"
  [ ! -e "$home/state/.main-eligible-rows" ] || fail "inert home drain wrote .main-eligible-rows"
  [ ! -e "$home/state/.branch-eligible-rows" ] || fail "inert home drain wrote .branch-eligible-rows"
  local leases
  leases=$(find "$home/state" -maxdepth 1 -name '.lease-*' 2>/dev/null)
  [ -z "$leases" ] || fail "inert home has lease files: $leases"
  pass "a home that never runs the branch has no lease files, no actor state, no retained command lock, and silent guards"
}

test_omp_extension_establishes_main_actor_context() {
  local fixture package_dir out
  fixture="$TMP_ROOT/extension-main-actor"
  package_dir="$fixture/node_modules/@oh-my-pi/pi-coding-agent"
  mkdir -p "$fixture/.omp/extensions/lib" "$package_dir"
  cp "$ROOT/.omp/extensions/fm-branch-supervision-omp.ts" "$fixture/.omp/extensions/fm-branch-supervision-omp.ts"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-branch-model-picker.ts" "$fixture/.omp/extensions/lib/fm-branch-model-picker.ts"
  printf '%s\n' '{"type":"module","exports":{".":"./index.js","./extensibility/legacy-pi-coding-agent-shim":"./coding-shim.js","./extensibility/legacy-pi-ai-shim":"./ai-shim.js"}}' > "$package_dir/package.json"
  printf '%s\n' 'export function createAgentSession() {} export class SessionManager {}' > "$package_dir/index.js"
  printf '%s\n' 'export function createBashToolDefinition() {} export const Type = {};' > "$package_dir/coding-shim.js"
  printf '%s\n' 'export function clampThinkingLevel(_model, level) { return level; }' > "$package_dir/ai-shim.js"

  out=$(env -u PI_CODING_AGENT -u FM_SUPERVISION_ACTOR \
    EXTENSION_PATH="$fixture/.omp/extensions/fm-branch-supervision-omp.ts" bun -e '
      await import(process.env.EXTENSION_PATH);
      if (process.env.PI_CODING_AGENT !== "true") throw new Error("coding-agent marker missing");
      if (process.env.FM_SUPERVISION_ACTOR !== "main") throw new Error("main supervision actor missing");
      console.log("main actor established");
    ' 2>&1) || fail "OMP extension load did not establish the main actor context: $out"
  assert_contains "$out" "main actor established" "OMP extension actor probe did not complete"
  pass "OMP extension load establishes the main supervision actor context"
}

test_branch_prompt_is_byte_stable_and_above_cache_floor
test_outcome_store_is_append_only_with_cursor_reads
test_outcome_startup_replay_preserves_silence
test_outcome_live_handoff_requires_contiguous_sequence
test_lease_exclusivity_release_stale_and_sweep
test_role_partition_refuses_the_branch_actor
test_send_lease_guard_serializes_a_held_task
test_non_branch_home_is_untouched
test_omp_extension_establishes_main_actor_context
