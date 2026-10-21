#!/usr/bin/env bash
# Tests for the per-worker No-Mistakes PR guard (bin/fm-nm-pr-guard.sh).
#
# A ship task in no-mistakes mode must let the No-Mistakes pipeline create its
# PR: a worker-created PR predates every run, so fm-pr-check.sh and
# fm-pr-merge.sh have no run to prove. fm-spawn.sh installs task-private `gh`
# and `gh-axi` wrappers and puts them first on the worker's PATH with
# FM_NM_PR_GUARD=1 on the launch command.
#
# The cases below cover the guard's own contract and the spawn wiring that arms
# it: a no-mistakes spawn carries the wrappers and marker, a direct-PR spawn
# carries neither, a worker-initiated `pr create` (gh, gh-axi, and the api
# pulls POST) is refused with the pipeline guidance, and a marker-less
# invocation - the shape of the No-Mistakes daemon's own environment - reaches
# the real tool. tests/fm-nm-pr-unguarded.test.sh owns the detection backstop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT/bin/fm-nm-pr-guard.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-pr-guard)

# make_guard_case <name>: <realbin> holds recording stand-ins for the tools the
# guard execs; <guarddir> is the wrapper directory under test.
make_guard_case() {
  local name=$1 case_dir realbin guarddir
  case_dir="$TMP_ROOT/$name"
  realbin="$case_dir/realbin"
  guarddir="$case_dir/guard"
  mkdir -p "$realbin" "$guarddir" || return 1
  cat > "$realbin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh:%s\n' "$*" >> "${FM_REAL_LOG:?FM_REAL_LOG unset}"
SH
  cat > "$realbin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'gh-axi:%s\n' "$*" >> "${FM_REAL_LOG:?FM_REAL_LOG unset}"
SH
  chmod +x "$realbin/gh" "$realbin/gh-axi" || return 1
  : > "$case_dir/real.log" || return 1
  "$GUARD" install "$guarddir" || return 1
  printf '%s|%s|%s\n' "$case_dir" "$realbin" "$guarddir"
}

read_guard_case() {
  IFS='|' read -r CASE_DIR REALBIN GUARDDIR <<EOF
$1
EOF
}

# run_guarded <tool> <armed 0|1> <args...>: run the wrapper with the guard dir
# first on PATH, capturing stdout+stderr in GUARD_OUT and the exit code in
# GUARD_RC.
run_guarded() {
  local tool=$1 armed=$2
  shift 2
  if [ "$armed" -eq 1 ]; then
    GUARD_OUT=$(PATH="$GUARDDIR:$REALBIN:/usr/bin:/bin" FM_NM_PR_GUARD=1 \
      FM_REAL_LOG="$CASE_DIR/real.log" "$GUARDDIR/$tool" "$@" 2>&1)
  else
    GUARD_OUT=$(PATH="$GUARDDIR:$REALBIN:/usr/bin:/bin" FM_REAL_LOG="$CASE_DIR/real.log" \
      "$GUARDDIR/$tool" "$@" 2>&1)
  fi
  GUARD_RC=$?
}

test_install_writes_wrappers() {
  local rec out
  rec=$(make_guard_case install) || fail "guard install failed"
  read_guard_case "$rec"
  [ -x "$GUARDDIR/gh" ] || fail "install did not write an executable gh wrapper"
  [ -x "$GUARDDIR/gh-axi" ] || fail "install did not write an executable gh-axi wrapper"
  out=$(PATH="$GUARDDIR:$REALBIN:/usr/bin:/bin" FM_REAL_LOG="$CASE_DIR/real.log" \
    "$GUARDDIR/gh" pr list 2>&1) \
    || fail "wrapper did not reach the real gh: $out"
  assert_contains "$(cat "$CASE_DIR/real.log")" "gh:pr list" \
    "wrapper did not exec the real gh"
  pass "install writes gh and gh-axi wrappers that reach the real tools"
}

test_armed_guard_refuses_worker_pr_create() {
  local rec
  rec=$(make_guard_case armed) || fail "guard install failed"
  read_guard_case "$rec"

  run_guarded gh 1 pr create --title 'worker PR'
  [ "$GUARD_RC" -ne 0 ] || fail "armed guard allowed 'gh pr create'"
  assert_contains "$GUARD_OUT" "No-Mistakes pipeline" \
    "refusal did not point the worker at the No-Mistakes pipeline"
  assert_contains "$GUARD_OUT" "blocked:" "refusal was not a one-line block"
  [ ! -s "$CASE_DIR/real.log" ] || fail "refused 'gh pr create' still reached the real gh"

  run_guarded gh-axi 1 pr create --title 'worker PR'
  [ "$GUARD_RC" -ne 0 ] || fail "armed guard allowed 'gh-axi pr create'"
  assert_contains "$GUARD_OUT" "No-Mistakes pipeline" \
    "gh-axi refusal did not point the worker at the No-Mistakes pipeline"

  run_guarded gh 1 api -X POST repos/o/r/pulls -f title=worker
  [ "$GUARD_RC" -ne 0 ] || fail "armed guard allowed an api POST to pulls"
  [ ! -s "$CASE_DIR/real.log" ] || fail "refused api POST still reached the real gh"

  run_guarded gh 1 -R o/r pr create --title 'worker PR'
  [ "$GUARD_RC" -ne 0 ] || fail "armed guard allowed 'gh -R o/r pr create'"
  pass "armed guard refuses gh/gh-axi pr create and the api pulls POST"
}

test_option_placement_preserves_guard() {
  local rec tool option method
  rec=$(make_guard_case options) || fail "guard install failed"
  read_guard_case "$rec"
  for tool in gh gh-axi; do
    for option in -R --repo; do
      run_guarded "$tool" 1 pr "$option" o/r create --fill
      expect_code 2 "$GUARD_RC" "guard allowed $tool pr $option o/r create"
    done
    for option in --repo=o/r -Ro/r; do
      run_guarded "$tool" 1 "$option" pr create --fill
      expect_code 2 "$GUARD_RC" "guard allowed $tool $option pr create"
      run_guarded "$tool" 1 pr "$option" create --fill
      expect_code 2 "$GUARD_RC" "guard allowed $tool pr $option create"
    done
    for option in -H --header --hostname --cache -p --preview -q --jq -t --template; do
      run_guarded "$tool" 1 api "$option" value -X POST repos/o/r/pulls
      expect_code 2 "$GUARD_RC" "guard allowed API creation with $option before endpoint"
      run_guarded "$tool" 1 api "$option" repos/o/r/pulls repos/o/r/issues -X POST
      expect_code 0 "$GUARD_RC" "guard mistook $option value for endpoint"
    done
    for option in -f -F --field --raw-field --input; do
      run_guarded "$tool" 1 api "$option" body repos/o/r/pulls
      expect_code 2 "$GUARD_RC" "guard allowed inferred POST with $option"
    done
    for option in -ftitle=worker -Ftitle=worker --field=title=worker --raw-field=title=worker --input=body; do
      run_guarded "$tool" 1 api "$option" repos/o/r/pulls
      expect_code 2 "$GUARD_RC" "guard allowed inferred POST with $option"
      run_guarded "$tool" 1 api "$option" repos/o/r/pulls --method GET
      expect_code 0 "$GUARD_RC" "guard refused explicit GET with $option"
    done
    for method in -XPOST -X=POST --method=POST; do
      run_guarded "$tool" 1 api "$method" repos/o/r/pulls
      expect_code 2 "$GUARD_RC" "guard allowed API creation with $method"
    done
  done
  pass "option values and attached fields preserve command, endpoint, and method classification"
}

test_armed_guard_allows_reads_and_other_verbs() {
  local rec
  rec=$(make_guard_case reads) || fail "guard install failed"
  read_guard_case "$rec"

  run_guarded gh 1 pr list --state open
  expect_code 0 "$GUARD_RC" "armed guard refused 'gh pr list': $GUARD_OUT"
  run_guarded gh 1 pr view 7 --comments
  expect_code 0 "$GUARD_RC" "armed guard refused 'gh pr view': $GUARD_OUT"
  run_guarded gh-axi 1 pr list --state all
  expect_code 0 "$GUARD_RC" "armed guard refused 'gh-axi pr list': $GUARD_OUT"
  run_guarded gh 1 api repos/o/r/pulls
  expect_code 0 "$GUARD_RC" "armed guard refused an api GET: $GUARD_OUT"
  assert_contains "$(cat "$CASE_DIR/real.log")" "gh:api repos/o/r/pulls" \
    "an api GET did not reach the real gh"
  pass "armed guard allows PR reads, other verbs, and api GET"
}

test_unarmed_guard_is_inert() {
  local rec
  rec=$(make_guard_case inert) || fail "guard install failed"
  read_guard_case "$rec"

  # This is the shape of the No-Mistakes daemon's own environment: the guard
  # directory is not on its PATH and FM_NM_PR_GUARD is absent. Even when a
  # shim dir is explicitly placed first, an unarmed invocation must pass
  # through so the pipeline's own `gh pr create` works.
  run_guarded gh 0 pr create --title 'pipeline PR'
  expect_code 0 "$GUARD_RC" "unarmed guard refused 'gh pr create': $GUARD_OUT"
  assert_contains "$(cat "$CASE_DIR/real.log")" "gh:pr create --title pipeline PR" \
    "unarmed guard did not reach the real gh"

  run_guarded gh-axi 0 pr create --title 'pipeline PR'
  expect_code 0 "$GUARD_RC" "unarmed guard refused 'gh-axi pr create': $GUARD_OUT"
  pass "unarmed guard passes pr create through to the real tool"
}

# --- spawn wiring -----------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir") || return 1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    for a in "$@"; do
      case "$a" in
        touch\ */.fm-launch-probe.*)
          marker=${a#touch }
          marker=${marker#\'}
          marker=${marker%\'}
          : > "$marker"
          ;;
      esac
    done
    for a in "$@"; do
      case "$a" in
        *.fm-launch-*)
          (cd "$FM_FAKE_PANE_PATH" && /bin/bash -c "$a") || exit 1
          ;;
      esac
    done
    exit 0
    ;;
  list-windows|has-session|new-session|new-window|kill-window|kill-pane|list-panes) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" || return 1
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  echo 'codex-cli 0.100.0'
  exit 0
fi
for tool in gh gh-axi; do
  output=$("$tool" pr create --title 'worker PR' 2>&1)
  result=$?
  printf '%s:%s:%s\n' "$tool" "$result" "$output" >> "$FM_FAKE_WORKER_LOG"
done
SH
  chmod +x "$fakebin/codex" || return 1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
  "pr create") printf '%s\n' 'created PR' >> "$FM_FAKE_REAL_LOG"; echo 'created PR' ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
  "pr create") printf '%s\n' 'created PR' >> "$FM_FAKE_REAL_LOG"; echo 'created PR' ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes" || return 1
  printf '%s\n' "$fakebin"
}

# make_spawn_case <name> <task-id>: a fake home and a project clone with a
# local bare origin plus one pooled worktree. Echoes
# "case_dir|home|project|pool|fakebin".
make_spawn_case() {
  local name=$1 id=$2 case_dir home project origin pool fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/treehouse-pool/1/project"
  fakebin=$(make_spawn_fakebin "$case_dir/fake") || return 1

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" || return 1
  printf 'codex\n' > "$home/config/crew-harness" || return 1
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md" || return 1
  touch "$home/state/.last-watcher-beat" || return 1

  mkdir -p "$project" || return 1
  git -C "$project" init --quiet -b main || return 1
  printf 'base\n' > "$project/README.md" || return 1
  git -C "$project" add README.md || return 1
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial || return 1
  git -C "$case_dir" clone --quiet --bare "$project" "$origin" || return 1
  git -C "$project" remote add origin "file://$origin" || return 1
  git -C "$project" worktree add --quiet --detach "$pool" main || return 1
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({worktrees:[{name:"1",path:process.argv[2]}]}))' \
    "$case_dir/treehouse-pool/treehouse-state.json" "$pool" || return 1

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <id> [extra fm-spawn args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$POOL_DIR" \
    FM_FAKE_WORKER_LOG="$CASE_DIR/worker.log" \
    FM_FAKE_REAL_LOG="$CASE_DIR/real.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

test_no_mistakes_spawn_arms_guard() {
  local rec id out status tool
  id='nm-guard-ship-r1'
  rec=$(make_spawn_case ship "$id") || fail "fixture setup failed"
  read_spawn_case "$rec"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  for tool in gh gh-axi; do
    assert_contains "$(cat "$CASE_DIR/worker.log")" "$tool:2:blocked:" \
      "launched worker allowed $tool pr create"
  done
  assert_contains "$(cat "$CASE_DIR/worker.log")" "No-Mistakes pipeline" \
    "worker refusal did not name the pipeline"
  [ ! -s "$CASE_DIR/real.log" ] || fail "blocked worker reached real tool"
  rm -rf "/tmp/fm-$id"
  pass "executed no-mistakes launch refuses worker PR creation through both tools"
}

test_direct_pr_spawn_installs_nothing() {
  local rec id out status tool
  id='nm-guard-direct-r1'
  rec=$(make_spawn_case direct "$id") || fail "fixture setup failed"
  read_spawn_case "$rec"
  out=$(run_spawn "$id" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "spawn failed: $out"
  for tool in gh gh-axi; do
    assert_contains "$(cat "$CASE_DIR/worker.log")" "$tool:0:created PR" \
      "direct-PR worker could not create PR through $tool"
  done
  assert_equals 2 "$(wc -l < "$CASE_DIR/real.log" | tr -d ' ')" \
    "direct-PR worker did not reach both real tools"
  assert_absent "/tmp/fm-$id/nm-pr-guard" \
    "a direct-PR spawn installed the no-mistakes PR guard"
  rm -rf "/tmp/fm-$id"
  pass "executed direct-PR launch allows worker PR creation through both tools"
}

test_install_writes_wrappers
test_armed_guard_refuses_worker_pr_create
test_option_placement_preserves_guard
test_armed_guard_allows_reads_and_other_verbs
test_unarmed_guard_is_inert
test_no_mistakes_spawn_arms_guard
test_direct_pr_spawn_installs_nothing
