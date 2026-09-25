#!/usr/bin/env bash
# End-to-end tests for durable captain-held tasks discovered by investigations
# and visual reviews, covering both bin/fm-captain-hold.sh's collapsed surface
# and the bin/fm-decision-hold.sh compatibility shim (run_decisions drives the
# shim so every retired verb is exercised against the new owner).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}


run_bearings() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

# Count files matching a glob without ls|grep (SC2010): the glob expands
# inside the function's own positional parameters.
count_glob() {  # <glob-pattern>
  # shellcheck disable=SC2086  # the pattern must expand as a glob here
  set -- $1
  [ -e "$1" ] || { printf '0\n'; return 0; }
  printf '%s\n' "$#"
}

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved decision is report prose,
# no held backlog item or open status exists, and the authoritative Bearings view
# correctly omits it. Completion must now refuse before teardown can erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-scratch" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "spawn_gen=decision-hold-test-g1"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-decision regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved decision"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved decision is reproduced and completion refuses before loss"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_decisions() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

# The new owner, called directly with the collapsed surface (task ids, not
# <origin> <key> pairs).
run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=decision-hold-test-$id-g1"
}

test_structured_holds_survive_teardown_and_route_resolution() {
  local home id route_hold access_hold before after json open show
  home=$(make_home durable-lifecycle)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
done: report and visual review complete
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_decisions "$home" complete "$id" route access > "$home/early-complete.out" 2> "$home/early-complete.err"; then
    fail "completion succeeded before unresolved decisions had captain holds"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"

  route_hold=$(run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample) \
    || fail "could not register route hold"
  [ "$route_hold" = "$id-decision-route" ] || fail "route hold identity was not deterministic: $route_hold"
  run_decisions "$home" hold "$id" route \
    --title "Choose the sample route" --reason "captain route choice pending" --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  if run_decisions "$home" complete "$id" route access > "$home/partial-complete.out" 2> "$home/partial-complete.err"; then
    fail "completion succeeded while one of two distinct decisions lacked a hold"
  fi
  access_hold=$(run_decisions "$home" hold "$id" access \
    --title "Choose the sample access level" --reason "captain access choice pending" --repo sample) \
    || fail "could not register access hold"
  [ "$access_hold" = "$id-decision-access" ] || fail "access hold identity was not distinct: $access_hold"
  [ "$(grep -cE "^- \[ \] $route_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the route hold"
  [ "$(grep -cE "^- \[ \] $access_hold -" "$home/data/backlog.md")" = 1 ] \
    || fail "second decision did not retain one distinct backlog identity"

  run_decisions "$home" complete "$id" route access >/dev/null \
    || fail "shared investigation completion gate failed"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=$id-decision-access,$id-decision-route" "$home/state/$id.meta" \
    "decision inventory was not recorded as deterministic task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close duplicate live status decisions: $open"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with captain-held decisions"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold" and .owner == "(main)"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == $route or .id == $access) | not)
  ' >/dev/null || fail "Bearings did not surface structured captain holds: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  ! grep -E "^- \[[ x]\] $id -" "$home/data/backlog.md" >/dev/null \
    || fail "origin remained in the live backlog after archival"
  grep -E "^- \[x\] $id -" "$home/data/done-archive.md" >/dev/null \
    || fail "origin was not durably archived"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route and .verb == "captain-hold"))
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held decision: $json"

  tasks_in "$home" add sample-route-implementation "Apply the selected sample route" \
    --kind ship --repo sample >/dev/null \
    || fail "could not create dependent work fixture"
  printf 'Use route north for the sample system.\n' > "$home/route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation > "$home/early-resolve.out" 2> "$home/early-resolve.err"; then
    fail "captain hold closed before dependent work had a durable routing edge"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: queued" "failed routing attempt closed the hold"
  assert_contains "$show" "held: yes" "failed routing attempt released the hold"
  tasks_in "$home" block sample-route-implementation --by "$route_hold" >/dev/null \
    || fail "could not route dependent work behind the decision hold"
  tasks_in "$home" add sample-route-followup "Check the selected sample route" \
    --kind ship --repo sample --blocked-by "$route_hold" >/dev/null \
    || fail "could not create second dependent work fixture"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "the routed close path failed with both edges in place"
  # A done blocker never holds dependent work back, so closing the call released
  # both routed edges with no separate unblock act.
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "a resolved captain call did not release its routed work"
  show=$(tasks_in "$home" show sample-route-followup --full)
  assert_contains "$show" "blocked: no" "a resolved captain call did not release its second dependent"
  run_decisions "$home" resolve "$id" route --decision-file "$home/route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup >/dev/null \
    || fail "identical resolution retry was not idempotent"
  printf 'Use route south for the sample system.\n' > "$home/changed-route-decision.txt"
  if run_decisions "$home" resolve "$id" route --decision-file "$home/changed-route-decision.txt" \
    --routed-to sample-route-implementation --routed-to sample-route-followup \
    > "$home/drifted-decision.out" 2> "$home/drifted-decision.err"; then
    fail "resolution retry accepted a different captain decision"
  fi
  show=$(tasks_in "$home" show "$route_hold" --full)
  assert_contains "$show" "state: done" "resolved hold did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "resolved hold lost the decision record"
  show=$(tasks_in "$home" show sample-route-implementation --full)
  assert_contains "$show" "blocked: no" "recorded decision did not release dependent work"
  json=$(run_bearings "$home") || fail "Bearings failed after decision resolution"
  printf '%s' "$json" | jq -e --arg route "$route_hold" --arg access "$access_hold" '
    (.decisions_open | any(.id == $route) | not)
      and (.decisions_open | any(.id == $access and .verb == "captain-hold"))
      and (.gates | any(.id == "sample-route-implementation"))
      and (.decisions_open | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "resolved or decision-like report prose produced a false hold: $json"
  pass "captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close"
}

test_scout_teardown_always_requires_inventory_verification() {
  local home id
  home=$(make_home unconditional-teardown)
  id=sample-absent-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample absent review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  if run_teardown "$home" "$id" > "$home/absent-teardown.out" 2> "$home/absent-teardown.err"; then
    fail "scout teardown skipped verification when its backlog task was absent"
  fi
  assert_present "$home/state/$id.meta" "refused absent-task teardown removed metadata"

  home=$(make_home unavailable-teardown)
  id=sample-unavailable-review
  mkdir -p "$home/data/$id"
  write_origin_meta "$home" "$id"
  printf '# Sample unavailable review\n\nNo decision inventory was recorded.\n' > "$home/data/$id/report.md"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$home/fakebin/tasks-axi"
  if run_teardown "$home" "$id" > "$home/unavailable-teardown.out" 2> "$home/unavailable-teardown.err"; then
    fail "scout teardown skipped verification when tasks-axi was unavailable"
  fi
  assert_present "$home/state/$id.meta" "refused unavailable-task teardown removed metadata"
  pass "non-forced scout teardown always requires durable inventory verification"
}

test_origin_slug_validation_precedes_path_construction() {
  local home escaped
  home=$(make_home origin-validation)
  escaped="$home/escaped-origin.meta"
  printf 'sentinel=unchanged\n' > "$escaped"
  if run_decisions "$home" complete ../escaped-origin --none \
    > "$home/invalid-complete.out" 2> "$home/invalid-complete.err"; then
    fail "completion accepted an origin path traversal"
  fi
  if run_decisions "$home" verify ../escaped-origin \
    > "$home/invalid-verify.out" 2> "$home/invalid-verify.err"; then
    fail "verification accepted an origin path traversal"
  fi
  [ "$(cat "$escaped")" = "sentinel=unchanged" ] \
    || fail "invalid origin changed metadata outside the state directory"
  pass "completion and verification validate origins before constructing paths"
}

test_visual_review_uses_shared_completion_owner() {
  local home id hold json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete - report at data/%s/report.md\n' "$id" > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  hold=$(run_decisions "$home" hold "$id" layout \
    --title "Choose the sample layout" --reason "captain layout choice pending" --repo sample) \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_decisions "$home" complete "$id" layout >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  [ "$hold" = "$id-decision-layout" ] || fail "visual review used a separate identity policy"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.id == $hold and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same decision-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-decision inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-decision inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false hold: $json"
  pass "resolved findings and decision-like prose do not create false holds"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'needs-decision [key=default]: choose route A or route B\ndone: report complete - report at data/%s/report.md\n' \
    "$id" > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  assert_contains "$open" "default" "fixture must retain the raw stale status decision"
  run_decisions "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'needs-decision [key=route]: choose route A or route B\ndone: heartbeat complete\n' \
    > "$home/state/$secondmate.status"
  if run_decisions "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate origin hold json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  cp "$ROOT/.tasks.toml" "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete - report at data/%s/report.md\n' "$origin" > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  hold=$(run_decisions "$mate" hold "$origin" release \
    --title "Choose the sample release" --reason "captain release choice pending" --repo sample) \
    || fail "secondmate-owned hold creation failed"
  run_decisions "$mate" complete "$origin" release >/dev/null \
    || fail "secondmate-owned completion failed"
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null

  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  json=$(run_bearings "$parent") || fail "parent Bearings could not read secondmate hold"
  printf '%s' "$json" | jq -e --arg hold "$hold" '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold" and (.id | endswith($hold)))
  ' >/dev/null || fail "secondmate captain hold did not surface with authoritative owner: $json"
  assert_no_grep "$hold" "$parent/data/backlog.md" "secondmate hold leaked into the main backlog"
  assert_grep "$hold" "$mate/data/backlog.md" "secondmate hold left its authoritative backlog"
  pass "main-home and secondmate-home captain holds remain correctly routed"
}

# tasks-axi quotes multi-entry blocked_by values as "a,b,c". resolve must strip
# those surrounding quotes before comma-boundary membership so the first and last
# list elements match, not only middle elements.
test_resolve_matches_quoted_blocked_by_edges() {
  local home origin hold_first hold_mid hold_last hold_absent show
  home=$(make_home quoted-blocked-by-edges)
  origin=sample-quote-review
  mkdir -p "$home/data/$origin"
  tasks_in "$home" add "$origin" "Quoted blocked_by edge review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create quote-edge origin"
  write_origin_meta "$home" "$origin"
  printf 'done: report complete\n' > "$home/state/$origin.status"
  printf '# Quote edge review\n\nThree edge decisions and one absent control.\n' > "$home/data/$origin/report.md"

  hold_first=$(run_decisions "$home" hold "$origin" edge-first \
    --title "First edge decision" --reason "captain first pending" --repo sample) \
    || fail "could not register first-edge hold"
  hold_mid=$(run_decisions "$home" hold "$origin" edge-mid \
    --title "Middle edge decision" --reason "captain mid pending" --repo sample) \
    || fail "could not register mid-edge hold"
  hold_last=$(run_decisions "$home" hold "$origin" edge-last \
    --title "Last edge decision" --reason "captain last pending" --repo sample) \
    || fail "could not register last-edge hold"
  hold_absent=$(run_decisions "$home" hold "$origin" edge-absent \
    --title "Absent edge decision" --reason "captain absent pending" --repo sample) \
    || fail "could not register absent-edge hold"

  tasks_in "$home" add pad-a "Pad A" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-a blocker"
  tasks_in "$home" add pad-b "Pad B" --kind ship --repo sample >/dev/null \
    || fail "could not create pad-b blocker"

  tasks_in "$home" add dep-first "Dep first position" --kind ship --repo sample >/dev/null \
    || fail "could not create first-position dependent"
  tasks_in "$home" block dep-first --by "$hold_first" >/dev/null || fail "could not block dep-first by first hold"
  tasks_in "$home" block dep-first --by pad-a >/dev/null || fail "could not block dep-first by pad-a"
  tasks_in "$home" block dep-first --by pad-b >/dev/null || fail "could not block dep-first by pad-b"
  show=$(tasks_in "$home" show dep-first --full)
  assert_contains "$show" "blocked_by: \"$hold_first,pad-a,pad-b\"" \
    "first-position fixture must quote multi-entry blocked_by"
  printf 'Decide first edge.\n' > "$home/d-first.txt"
  if ! run_decisions "$home" resolve "$origin" edge-first --decision-file "$home/d-first.txt" \
    --routed-to dep-first > "$home/first.out" 2> "$home/first.err"; then
    fail "resolve failed when hold id is FIRST in quoted blocked_by: $(cat "$home/first.err")"
  fi

  tasks_in "$home" add dep-mid "Dep mid position" --kind ship --repo sample >/dev/null \
    || fail "could not create mid-position dependent"
  tasks_in "$home" block dep-mid --by pad-a >/dev/null || fail "could not block dep-mid by pad-a"
  tasks_in "$home" block dep-mid --by "$hold_mid" >/dev/null || fail "could not block dep-mid by mid hold"
  tasks_in "$home" block dep-mid --by pad-b >/dev/null || fail "could not block dep-mid by pad-b"
  show=$(tasks_in "$home" show dep-mid --full)
  assert_contains "$show" "blocked_by: \"pad-a,$hold_mid,pad-b\"" \
    "middle-position fixture must quote multi-entry blocked_by"
  printf 'Decide mid edge.\n' > "$home/d-mid.txt"
  if ! run_decisions "$home" resolve "$origin" edge-mid --decision-file "$home/d-mid.txt" \
    --routed-to dep-mid > "$home/mid.out" 2> "$home/mid.err"; then
    fail "resolve failed when hold id is MIDDLE in quoted blocked_by: $(cat "$home/mid.err")"
  fi

  tasks_in "$home" add dep-last "Dep last position" --kind ship --repo sample >/dev/null \
    || fail "could not create last-position dependent"
  tasks_in "$home" block dep-last --by pad-a >/dev/null || fail "could not block dep-last by pad-a"
  tasks_in "$home" block dep-last --by pad-b >/dev/null || fail "could not block dep-last by pad-b"
  tasks_in "$home" block dep-last --by "$hold_last" >/dev/null || fail "could not block dep-last by last hold"
  show=$(tasks_in "$home" show dep-last --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b,$hold_last\"" \
    "last-position fixture must quote multi-entry blocked_by"
  printf 'Decide last edge.\n' > "$home/d-last.txt"
  if ! run_decisions "$home" resolve "$origin" edge-last --decision-file "$home/d-last.txt" \
    --routed-to dep-last > "$home/last.out" 2> "$home/last.err"; then
    fail "resolve failed when hold id is LAST in quoted blocked_by: $(cat "$home/last.err")"
  fi

  tasks_in "$home" add dep-absent "Dep absent control" --kind ship --repo sample >/dev/null \
    || fail "could not create absent-control dependent"
  tasks_in "$home" block dep-absent --by pad-a >/dev/null || fail "could not block dep-absent by pad-a"
  tasks_in "$home" block dep-absent --by pad-b >/dev/null || fail "could not block dep-absent by pad-b"
  show=$(tasks_in "$home" show dep-absent --full)
  assert_contains "$show" "blocked_by: \"pad-a,pad-b\"" \
    "absent-control fixture must quote multi-entry blocked_by without the hold id"
  printf 'Decide absent edge.\n' > "$home/d-absent.txt"
  if run_decisions "$home" resolve "$origin" edge-absent --decision-file "$home/d-absent.txt" \
    --routed-to dep-absent > "$home/absent.out" 2> "$home/absent.err"; then
    fail "resolve succeeded when hold id is genuinely absent from blocked_by"
  fi
  assert_grep "not durably blocked by" "$home/absent.err" \
    "absent id must fail with durable-block error"
  show=$(tasks_in "$home" show "$hold_absent" --full)
  assert_contains "$show" "state: queued" "failed absent resolve must leave the hold open"
  assert_contains "$show" "held: yes" "failed absent resolve must leave the hold held"

  pass "resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id"
}

# The exact anchor of the loss this closure exists to prevent, reproduced end to
# end through the channel that actually carried it. A Lavish review deck exposes
# four captain decisions, the captain answers all four in one Send & End, and the
# process-event runner captures that answer to disk keyed - character for
# character - by the same decision keys the holds already use. Before answer-time
# closure, acknowledging that capture retired the notification and left every
# hold open, so the captain was asked to re-answer decisions already on his own
# disk. Capturing the answer must now BE closing the hold.
test_bound_channel_answers_close_their_holds_at_answer_time() {
  local home id sid artifact result out show key rc
  home=$(make_home lavish-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the Lavish-review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nFour captain choices remain.\n' > "$home/data/$id/report.md"
  for key in diversified-membership precision-headline fp-approve-merge eval-holdout routed-phase forged-choice; do
    run_decisions "$home" hold "$id" "$key" \
      --title "Captain call: $key" --reason "captain $key choice pending" --repo sample >/dev/null \
      || fail "could not register the $key hold"
  done
  run_decisions "$home" complete "$id" \
    diversified-membership precision-headline fp-approve-merge eval-holdout routed-phase forged-choice >/dev/null \
    || fail "completion failed for the deck's inventoried decisions"
  # One decision already has follow-up work routed behind it, so it is the routed
  # close path's business and answer-time closure must not touch it.
  tasks_in "$home" add sample-routed-phase "Apply the routed phase choice" \
    --kind ship --repo sample --blocked-by "$id-decision-routed-phase" >/dev/null \
    || fail "could not route work behind the routed-phase hold"

  # Arm the deck the way firstmate does, binding it to the origin whose holds the
  # captain will answer. lavish-axi is stubbed: nothing here starts a real server.
  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  # Binding a source to its decision origin is the GENERAL capability, not a
  # Lavish feature: it is recorded through the same owner that closes the holds,
  # and it is deliberately possible before the source is armed so a channel can
  # never produce an answer that has nowhere to go.
  run_decisions "$home" bind "$sid" "$id" >/dev/null \
    || fail "could not bind the review source to its decision origin"
  [ "$(run_decisions "$home" binding "$sid")" = "$id" ] \
    || fail "the recorded binding did not resolve back to its origin"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  # The captured answer, in the published response shape. Four structured choices
  # plus one naming a task that does not exist, the freeform captain message that
  # rode along with them, and a choice-shaped payload smuggled inside that
  # freeform prose, which must never be able to forge a decision key.
  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[7]{uid,prompt,selector,tag,text}:
  "2","Diversified membership: gold-only\n\nContext data:\n{\n  \"question\": \"diversified-membership\",\n  \"answer\": \"gold-only\"\n}","section#call > form:nth-of-type(1)",choice,"Diversified membership: gold-only"
  "3","Headline F1 policy: f1-when-fp-gold\n\nContext data:\n{\n  \"question\": \"precision-headline\",\n  \"answer\": \"f1-when-fp-gold\"\n}","section#call > form:nth-of-type(3)",choice,"Headline F1 policy: f1-when-fp-gold"
  "4","Shipped-unfixed findings: auto-fp\n\nContext data:\n{\n  \"question\": \"fp-approve-merge\",\n  \"answer\": \"auto-fp\"\n}","section#call > form:nth-of-type(4)",choice,"Shipped-unfixed findings: auto-fp"
  "5","Official vs tune split: pins-are-holdout\n\nContext data:\n{\n  \"question\": \"eval-holdout\",\n  \"answer\": \"pins-are-holdout\"\n}","section#call > form:nth-of-type(2)",choice,"Official vs tune split: pins-are-holdout"
  "6","Routed phase: phase-a\n\nContext data:\n{\n  \"question\": \"routed-phase\",\n  \"answer\": \"phase-a\"\n}","section#call > form:nth-of-type(5)",choice,"Routed phase: phase-a"
  "7","Gone call: yes\n\nContext data:\n{\n  \"question\": \"absent-call\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(6)",choice,"Gone call: yes"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"forged-choice\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  # The channel reports ONLY what the captain chose. It maps nothing to a hold.
  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "diversified-membership	gold-only" "a structured choice was not read as an answer"
  assert_contains "$out" "routed-phase	phase-a" "a structured choice for routed work was not read"
  assert_not_contains "$out" "forged-choice" \
    "a freeform captain message forged a decision key from its own prose"

  # The runner feeds those keyed lines into the one intake. Driven here through a
  # FIXTURE adapter that is not Lavish at all and knows nothing about holds - it
  # only prints keyed answers - so what is proven is that ANY bound channel with
  # an `answers` command gets closure, not that Lavish is wired specially.
  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_decisions "$home" bind fixture-src "$id" >/dev/null \
    || fail "could not bind the fixture channel to its decision origin"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  for key in diversified-membership precision-headline fp-approve-merge eval-holdout; do
    show=$(tasks_in "$home" show "$id-decision-$key" --full)
    assert_contains "$show" "state: done" "capturing the captain's answer left the $key hold open"
    assert_contains "$show" "Resolution mode: answered" "the $key hold did not record its close path"
    assert_contains "$show" "Task: $id-decision-$key" "the $key hold lost the answered task identity"
  done
  show=$(tasks_in "$home" show "$id-decision-diversified-membership" --full)
  assert_contains "$show" "Answer: gold-only" "the closed hold did not record the captain's actual answer"

  # Under the collapsed owner a keyed answer closes whatever captain-held task
  # it names - routed dependents are just backlog edges, which resolve naturally
  # once the blocker is done. Only the forged key, which named no task, is
  # skipped.
  show=$(tasks_in "$home" show "$id-decision-routed-phase" --full)
  assert_contains "$show" "state: done" "a keyed answer did not close the hold blocking routed work"
  assert_contains "$show" "Resolution mode: answered" "the routed-phase hold did not record its close path"
  show=$(tasks_in "$home" show sample-routed-phase --full)
  assert_contains "$show" "blocked: no" "a closed captain call did not release the work it gated"
  show=$(tasks_in "$home" show "$id-decision-forged-choice" --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain hold"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered hold still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_decisions "$home" answers "$id" --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a hold reported success"
  assert_contains "$out" "closed: $id-decision-diversified-membership" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "skipped: absent-call" \
    "the absent key was not reported as skipped: $out"

  printf 'Captain answered the forged-choice decision directly.\n' > "$home/forged-choice-decision.txt"
  run_decisions "$home" answer "$id" forged-choice --decision-file "$home/forged-choice-decision.txt" >/dev/null \
    || fail "could not close the untouched hold through the answer path"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "answered decisions did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain holds at answer time"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_decisions "$home" hold "$id" only-choice \
    --title "Captain call: only-choice" --reason "captain only-choice pending" --repo sample >/dev/null \
    || fail "could not register the unbound hold"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"only-choice\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_decisions "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a decision origin"
  [ -z "$out" ] || fail "an unbound source printed an origin: $out"
  show=$(tasks_in "$home" show "$id-decision-only-choice" --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain hold"
  assert_contains "$show" "held: yes" "an unbound review released a captain hold"
  pass "a channel source with no decision binding closes nothing"
}

# The answer verb is the hold ledger's answer-time closure primitive, so it must
# carry every guard the unrouted close path already had. Weakening any of them to
# reach closure would trade the loss this fixes for a worse one.
test_answer_preserves_every_unrouted_close_guard() {
  local home id hold show
  home=$(make_home answer-guards)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" guard-choice \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample) \
    || fail "could not register the guarded hold"
  run_decisions "$home" complete "$id" guard-choice >/dev/null \
    || fail "completion failed for the guarded hold"

  printf '' > "$home/empty.txt"
  if run_decisions "$home" answer "$id" guard-choice --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_decisions "$home" answer "$id" guard-choice > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  if run_decisions "$home" answer "$id" absent-choice --decision-file "$home/empty.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a decision that has no hold"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "a refused answer closed the hold"
  assert_contains "$show" "held: yes" "a refused answer released the hold"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_decisions "$home" answer "$id" guard-choice --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close a hold that routes no work"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "an answered hold did not close"
  assert_contains "$show" "Resolution mode: answered" "an answered hold did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "an answered hold did not record the captain decision text"
  run_decisions "$home" answer "$id" guard-choice --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_decisions "$home" answer "$id" guard-choice --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "an answered decision did not satisfy the completion gate"
  pass "the answer path keeps every guard the unrouted close path already had"
}


# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does. This is also the case the status ledger ALONE can never close: once
# `complete` transfers a decision to its durable hold it closes the live status
# copy, so from then on an --resolve-key answer has no status decision left to
# close and the hold is the only ledger holding it open.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id hold fb show
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  hold=$(run_decisions "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample) \
    || fail "could not register the chat hold"
  run_decisions "$home" complete "$id" chat-choice >/dev/null \
    || fail "completion failed for the chat hold"
  # The transfer really did close the live status copy, so only the hold is open.
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its hold"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
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
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows)
    [ -n "${FM_HOME:-}" ] && sed -n 's/^window=[^:]*://p' "$FM_HOME"/state/*.meta 2>/dev/null
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred decision was refused by the chat channel"
  # A local task target receives the answer as a durable steering-inbox record
  # plus a doorbell; the record is what the worker reads.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  assert_contains "$(cat "$home/send.log")" "Firstmate instruction waiting" "the answer doorbell was never rung"
  # fm-send already delivered the answer itself, so its intake feed passes
  # --no-steer and the hold close must not produce a second inbox record.
  [ "$(count_glob "$home/state/$id.inbox/"*.msg)" = 1 ] \
    || fail "the chat answer was delivered to the worker's inbox twice"

  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "a chat answer left its captain hold open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered hold did not record its close path"
  assert_contains "$show" "Answer: go with option A" "the chat-answered hold lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered hold lost its channel provenance"
  run_decisions "$home" verify "$id" >/dev/null \
    || fail "a chat-answered decision did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}


# The collapsed surface: a captain call is an ordinary task held for the
# captain, keyed by its own task id. The Captain's Deck plugin drives exactly
# this path: `answers --source <provenance>` with keyed lines and no origin.
test_deck_style_answers_close_plain_task_id_holds() {
  local home id show out fb
  home=$(make_home deck-answers)
  id=deck-gate-task
  tasks_in "$home" add "$id" "Pick the deploy order" --kind captain --repo sample >/dev/null \
    || fail "could not create the plain task fixture"
  run_captain "$home" hold "$id" --reason "deploy order pending" --repo sample >/dev/null \
    || fail "could not hold the plain task for the captain"
  run_captain "$home" open "$id" >/dev/null || fail "a held task did not report open"
  [ "$(run_decisions "$home" id "$id" key)" = "$id-decision-key" ] \
    || fail "the shim's id verb did not compose the legacy identity"

  # The Deck's write path must also steer the owning task through fm-send:
  # give the held task live metadata and a tmux double that records the
  # doorbell, so the durable inbox record is observable.
  write_origin_meta "$home" "$id" ship
  fb="$home/fakebin"
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
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows)
    [ -n "${FM_HOME:-}" ] && sed -n 's/^window=[^:]*://p' "$FM_HOME"/state/*.meta 2>/dev/null
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  : > "$home/send.log"

  printf '%s\t%s\t%s\n' "$id" "ship-api-first" "Ship API first" \
    | FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
      run_captain "$home" answers --source "herdr-firstmate-flow captain's deck" \
      > "$home/answers.out" 2> "$home/answers.err" \
    || fail "a Deck-style keyed answer did not close the plain task hold"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: done" "the Deck-style answer left the hold open"
  assert_contains "$show" "Resolution mode: answered" "the Deck answer did not record its close path"
  assert_contains "$show" "Answer: ship-api-first" "the Deck answer lost the captain's choice"
  assert_contains "$show" "Answer as shown to the captain: Ship API first" "the Deck answer lost its label"
  assert_contains "$show" "herdr-firstmate-flow" "the Deck answer lost its provenance"
  assert_contains "$show" "Task: $id" "the Deck answer did not name its task id"
  # The owning task was steered: the answer text reached its durable inbox
  # record and the doorbell was rung through the recorded tmux endpoint.
  assert_contains "$(cat "$home/answers.err")" "steered: $id -> $id" \
    "the Deck answer did not report steering the owning task"
  grep -qF "ship-api-first" "$home/state/$id.inbox/001.msg" \
    || fail "the Deck answer never reached the owning task's durable inbox record"
  assert_contains "$(cat "$home/send.log")" "Firstmate instruction waiting" \
    "the Deck answer's doorbell was never rung"
  # Idempotent replay of the identical answer does NOT re-steer: the durable
  # delivery token inside the first inbox record dedupes it, so the inbox
  # still holds exactly one record.
  printf '%s\t%s\t%s\n' "$id" "ship-api-first" "Ship API first" \
    | FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
      run_captain "$home" answers --source "herdr-firstmate-flow captain's deck" \
      > "$home/replay.out" 2> "$home/replay.err" \
    || fail "an identical Deck answer replay was not idempotent"
  assert_contains "$(cat "$home/replay.err")" "already delivered" \
    "the replayed Deck answer did not report its deduped steer"
  [ "$(count_glob "$home/state/$id.inbox/"*.msg)" = 1 ] \
    || fail "a replayed Deck answer duplicated the owning task's inbox record"
  # An absent key is skipped and the run reports nonzero.
  if printf 'no-such-task\tyes\tYes\n' | run_captain "$home" answers --source herdr-firstmate-flow \
      > "$home/absent.out" 2>&1; then
    fail "an answer naming no task reported success"
  fi
  assert_contains "$(cat "$home/absent.out")" "skipped: no-such-task" "an absent key was not reported"
  pass "Deck-style keyed answers close plain task-id holds with provenance and steer the owning task"
}

# The Deck's Reconcile path: a durable request under state/reconcile-requests/
# that never closes the hold, plus the two evidence-backed outcomes that retire
# it.
test_reconcile_requests_and_outcomes() {
  local home id sid show out json
  home=$(make_home reconcile-flow)
  id=reconcile-me
  tasks_in "$home" add "$id" "Confirm the cached index is stale" --kind captain --repo sample >/dev/null \
    || fail "could not create the reconcile fixture"
  run_captain "$home" hold "$id" --reason "staleness check pending" >/dev/null \
    || fail "could not hold the reconcile fixture"

  sid=herdr-firstmate-flow
  run_captain "$home" bind "$sid" >/dev/null || fail "could not bind the deck source"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the deck binding did not resolve to the any-origin marker"

  printf '%s\t%s\n' "$id" "re-check the published index" \
    | run_captain "$home" reconcile-requests --source-id "$sid" \
        --source "herdr-firstmate-flow captain's deck" >/dev/null \
    || fail "reconcile-requests refused a bound source"
  [ -f "$home/state/reconcile-requests/$id.request" ] \
    || fail "no durable reconcile request was recorded"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: queued" "a reconcile request closed the hold"
  assert_contains "$show" "held: yes" "a reconcile request released the hold"
  out=$(run_captain "$home" reconcile list) || fail "reconcile list failed"
  assert_contains "$out" "$id" "the pending request did not list"
  # Idempotent: a second request keeps one record and its original timestamp.
  printf '%s\n' "$id" | run_captain "$home" reconcile-requests --source-id "$sid" \
      --source "herdr-firstmate-flow captain's deck" >/dev/null \
    || fail "a repeated reconcile request was not idempotent"
  [ "$(count_glob "$home/state/reconcile-requests/$id.request")" = 1 ] \
    || fail "a repeated reconcile request duplicated the record"
  # The request moved the hold out of Captain's Call into a disclosed gate.
  json=$(run_bearings "$home") || fail "Bearings failed with a pending reconcile request"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id) | not)
      and (.gates | any(.id == $id and (.reason | test("reconcile requested"))))
  ' >/dev/null || fail "a pending reconcile request did not move the hold to the gate bucket: $json"
  # An unbound source cannot file one.
  if printf '%s\n' "$id" | run_captain "$home" reconcile-requests --source-id stranger \
      --source "unbound" > "$home/unbound.out" 2>&1; then
    fail "reconcile-requests accepted an unbound source"
  fi
  # The reserved reconcile value can never ride the keyed-answer intake.
  if printf '%s\treconcile\tReconcile\n' "$id" | run_captain "$home" answers \
      --source test > "$home/rec-ans.out" 2>&1; then
    fail "the keyed-answer intake accepted a reconcile value"
  fi
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: queued" "a reconcile value closed the hold through answers"

  # Outcome one: genuinely still open - the note path retires the request and
  # leaves the call the captain's.
  printf 'Verified: the index is still stale and still needs the captain.\n' > "$home/note.txt"
  run_captain "$home" reconcile note "$id" --note-file "$home/note.txt" >/dev/null \
    || fail "reconcile note refused a pending request"
  [ ! -e "$home/state/reconcile-requests/$id.request" ] \
    || fail "the applied reconcile note left its request pending"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: queued" "a reconcile note closed the hold"
  assert_contains "$show" "Captain hold reconciled:" "the note left no record"

  # Outcome two: moot - the evidence close retires a fresh request and closes
  # the task with the reconciled mode, never claiming a captain answer.
  printf '%s\n' "$id" | run_captain "$home" reconcile-requests --source-id "$sid" \
      --source "herdr-firstmate-flow captain's deck" >/dev/null \
    || fail "could not file the second reconcile request"
  printf 'The index regenerated cleanly at 2026-09-25T00:00Z; nothing to choose.\n' > "$home/evidence.txt"
  run_captain "$home" reconcile close "$id" --evidence-file "$home/evidence.txt" >/dev/null \
    || fail "reconcile close refused a pending request"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: done" "a reconcile close left the hold open"
  assert_contains "$show" "Resolution mode: reconciled" "a reconcile close claimed a captain answer"
  assert_contains "$show" "Reconciliation evidence:" "a reconcile close lost its evidence"
  [ ! -e "$home/state/reconcile-requests/$id.request" ] \
    || fail "the applied reconcile close left its request pending"
  run_captain "$home" unbind "$sid" >/dev/null || fail "could not unbind the deck source"
  pass "reconcile requests stay durable, never close, and retire through evidence or a note"
}

# The reserved reconcile selection also stays out of the adapter's keyed-answer
# rows and reaches only the reconcile feed.
test_lavish_reconcile_selections_split_from_answers() {
  local home result out
  home=$(make_home lavish-reconcile)
  result="$home/result.txt"
  cat > "$result" <<'EOF'
session:
  file: /board.html
  status: feedback
prompts[3]{uid,prompt,selector,tag,text}:
  "1","Call one: option-a\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"call-one\",\n  \"selection\": \"option-a\",\n  \"note\": \"\"\n}","section#call > form",choice,"Call one"
  "2","Call two: re-check\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"call-two\",\n  \"selection\": \"reconcile\",\n  \"note\": \"check the latest build\"\n}","section#call > form",choice,"Reconcile"
  "3","Old call: reconcile - verify\n\nContext data:\n{\n  \"question\": \"call-three\",\n  \"answer\": \"reconcile - verify\"\n}","section#call > form",choice,"Old reconcile"
EOF
  out=$(run_lavish "$home" answers "$result") || fail "the adapter refused a versioned result"
  assert_contains "$out" "call-one	option-a" "the versioned answer row was not emitted"
  assert_not_contains "$out" "call-two" "a reconcile selection leaked into keyed answers"
  assert_not_contains "$out" "call-three" "a legacy reconcile-shaped value reached keyed answers"
  out=$(run_lavish "$home" reconciles "$result") || fail "the adapter refused reconciles"
  [ "$out" = "$(printf 'call-two\tcheck the latest build')" ] \
    || fail "the reconcile feed lost or invented a task id: $out"
  pass "the adapter splits reconcile selections from keyed answers"
}

# A status-side resolved line over a still-open captain hold is the divergence
# the wake drain surfaces without closing anything.
test_diverged_reports_status_close_over_open_hold() {
  local home id out home2 id2
  home=$(make_home divergence)
  id=div-call
  tasks_in "$home" add "$id" "Two records disagree" --kind captain --repo sample >/dev/null \
    || fail "could not create the divergence fixture"
  run_captain "$home" hold "$id" --reason "pending" >/dev/null || fail "could not hold the fixture"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=%s]: pick one\nworking: mid-flight\n' "$id" > "$home/state/$id.status"

  out=$(run_captain "$home" diverged) || fail "diverged failed on a clean home"
  [ -z "$out" ] || fail "diverged reported a contradiction on a clean home: $out"

  printf 'resolved [key=%s]: the status log says the captain ruled\n' "$id" >> "$home/state/$id.status"
  out=$(run_captain "$home" diverged) || fail "diverged failed on the contradictory home"
  assert_contains "$out" "$id" "a resolved status line over an open hold was not flagged"

  # A verified captain-held transfer close is NOT a divergence.
  home2=$(make_home no-divergence)
  id2=held-call
  tasks_in "$home2" add "$id2" "Consistent records" --kind captain --repo sample >/dev/null \
    || fail "could not create the agreement fixture"
  run_captain "$home2" hold "$id2" --reason "pending" >/dev/null || fail "could not hold the fixture"
  write_origin_meta "$home2" "$id2" ship
  printf 'needs-decision [key=%s]: pick one\ncaptain-held [key=%s]: tracked by %s\n' \
    "$id2" "$id2" "$id2" > "$home2/state/$id2.status"
  out=$(run_captain "$home2" diverged) || fail "diverged failed on the agreeing home"
  [ -z "$out" ] || fail "a captain-held transfer was misread as divergence: $out"
  pass "a status close over an open hold surfaces through diverged"
}

# A --until deferral leaves Captain's Call until its date, then returns.
test_deferred_hold_leaves_captains_call_until_due() {
  local home id json
  home=$(make_home deferred-call)
  id=deferred-call
  tasks_in "$home" add "$id" "Pick after the freeze" --kind captain --repo sample >/dev/null \
    || fail "could not create the deferral fixture"
  run_captain "$home" hold "$id" --reason "after the freeze" --until 2027-01-15 >/dev/null \
    || fail "could not record a deferred hold"
  json=$(run_bearings "$home") || fail "Bearings failed with a deferred hold"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id) | not)
      and (.gates | any(.id == $id and (.reason | test("deferred until 2027-01-15"))))
  ' >/dev/null || fail "a deferred hold did not leave Captain's Call: $json"
  json=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2027-01-16T00:00:00Z \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      "$ROOT/bin/fm-bearings-snapshot.sh" --json) \
    || fail "Bearings failed after the deferral date"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id))
      and (.gates | any(.id == $id) | not)
  ' >/dev/null || fail "an expired deferral did not return to Captain's Call: $json"
  pass "a --until deferral gates until its date and resurfaces after"
}

# The board build writes the durable per-card store beside the board payload.
test_board_build_writes_decision_cards() {
  local home card_id payload board
  home=$(make_home board-cards)
  card_id='board-call'
  tasks_in "$home" add "$card_id" "Pick the board option" --kind captain --repo sample >/dev/null \
    || fail "could not create the board fixture"
  run_captain "$home" hold "$card_id" --reason "board pending" >/dev/null || fail "could not hold the fixture"
  payload="$home/board.json"
  cat > "$payload" <<EOF
{"schema":"fm-bearings-board.v1","home":"board-cards","generated":"2026-09-25T00:00:00Z","prs_live":false,
 "captains_call":[{"key":"$card_id","type":"decision","repo":"sample","title":"Pick the board option",
   "about":"context","decide":"the option",
   "options":[{"value":"a","label":"Option A"},{"value":"b","label":"Option B"}]}],
 "underway":[],"landed":[],"charted":[]}
EOF
  fm_fake_exit0 "$home/fakebin" lavish-axi
  # Whether or not lavish-axi exists on this host, the build must have published
  # the board and the durable card store before the session step can fail.
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ROOT/bin/fm-bearings-board.sh" build "$payload" > "$home/build.out" 2>&1 || true
  board="$home/.lavish/bearings-board.html"
  [ -f "$board" ] || fail "the board file was not published: $(cat "$home/build.out")"
  [ -f "$home/state/decision-cards/$card_id.json" ] \
    || fail "the durable decision card was not written"
  jq -e --arg id "$card_id" '
    .schema == "fm-decision-card.v1" and .card.key == $id
      and ([.card.options[].value] | index("reconcile") != null)
  ' "$home/state/decision-cards/$card_id.json" >/dev/null \
    || fail "the stored card is not a reconcile-carrying fm-decision-card.v1 record"
  sed -n '/<script id="bearings-data" type="application\/json">/,/<\/script>/p' "$board" \
    | sed '1d;$d' | jq -e --arg id "$card_id" '.captains_call | any(.key == $id)' >/dev/null \
    || fail "the built board lost its decision card"
  pass "the board build writes fm-bearings-board.v1 plus durable fm-decision-card.v1 records"
}

# Out-of-band closes stay recordable: when a held task was closed by hand, the
# captain's words still land durably instead of being refused as absent.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home oob-close)
  id=oob-call
  tasks_in "$home" add "$id" "Call closed by hand" --kind captain --repo sample >/dev/null \
    || fail "could not create the out-of-band fixture"
  run_captain "$home" hold "$id" --reason "pending" >/dev/null || fail "could not hold the fixture"
  tasks_in "$home" "done" "$id" >/dev/null || fail "could not close the fixture out of band"
  printf 'Captain already said go.\n' > "$home/oob-decision.txt"
  run_captain "$home" answer "$id" --decision-file "$home/oob-decision.txt" >/dev/null \
    || fail "an out-of-band close refused the captain's recorded words"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: done" "the recording pass reopened a closed task"
  assert_contains "$show" "Resolution mode: repaired" "the out-of-band record lost its repair close path"
  assert_contains "$show" "Captain already said go." "the out-of-band record lost the captain's words"
  pass "an out-of-band close stays recordable through answer"
}

test_uninventoried_report_decision_refuses_completion

test_scout_teardown_always_requires_inventory_verification
test_structured_holds_survive_teardown_and_route_resolution
test_origin_slug_validation_precedes_path_construction
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_resolve_matches_quoted_blocked_by_edges
test_bound_channel_answers_close_their_holds_at_answer_time
test_unbound_source_closes_no_hold
test_answer_preserves_every_unrouted_close_guard
test_chat_channel_feeds_the_same_keyed_answer_intake
test_deck_style_answers_close_plain_task_id_holds
test_reconcile_requests_and_outcomes
test_lavish_reconcile_selections_split_from_answers
test_diverged_reports_status_close_over_open_hold
test_deferred_hold_leaves_captains_call_until_due
test_board_build_writes_decision_cards
test_out_of_band_close_is_recordable
