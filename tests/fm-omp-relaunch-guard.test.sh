#!/usr/bin/env bash
# Regression tests for the same-task OMP ship/scout relaunch guard in fm-spawn.sh.
#
# These tests exercise the early artifact guard and the relaunch profile recovery
# with a fake tmux pane and a real isolated git worktree. No real OMP agent or
# tmux server is required: the fake tmux and ps classify the recorded endpoint,
# and the fake omp/bun satisfy the launch-template identity checks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-relaunch-guard)

make_relaunch_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
  *"#{pane_current_command}"*)
    if [ "${FM_FAKE_TMUX_ACTIVE:-0}" = 1 ]; then
      printf '%s\n' 'codex'
    else
      printf '%s\n' 'bash'
    fi
    exit 0
    ;;
  *"#{pane_pid}"*)
    printf '4242\n'
    exit 0
    ;;
esac
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_path*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
      *pane_pid*) printf '4242\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0 ;;
  list-windows)
    if [ "${FM_FAKE_TMUX_ACTIVE:-0}" = 1 ] && [ -n "${FM_FAKE_LIST_WINDOWS:-}" ]; then
      printf '%s\n' "$FM_FAKE_LIST_WINDOWS"
    fi
    exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
      if case "$*" in *Enter*) true ;; *) false ;; esac \
         && grep -Fq 'FM_OMP_HARNESS=omp' "$FM_FAKE_LAUNCH_LOG" 2>/dev/null; then
        if [ -n "${FM_FAKE_OMP_ACK:-}" ]; then
          while IFS= read -r ack; do
            [ -z "$ack" ] || : > "$ack"
          done <<EOF
$FM_FAKE_OMP_ACK
EOF
        fi
      fi
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"-o tpgid="*) printf '4242\n' ;;
  *"-p 4242 -o comm="*)
    if [ "${FM_FAKE_TMUX_ACTIVE:-0}" = 1 ]; then printf 'codex\n'; else printf 'bash\n'; fi
    ;;
  *"-p 4242 -o args="*)
    if [ "${FM_FAKE_TMUX_ACTIVE:-0}" = 1 ]; then printf 'codex --task\n'; else printf 'bash\n'; fi
    ;;
  *"-axo pid=,pgid=,ppid=") printf '4242 4242 1\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = get ] && printf '%s\n' "$*" | grep -Eq '(^| )--lease( |$)'; then
  printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"

  cat > "$fakebin/bun" <<'SH'
#!/usr/bin/env bash
set -u
script=$1
shift
exec bash "$script" "$@"
SH
  chmod +x "$fakebin/bun"

  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bun
set -u
case "${1:-}" in
  --help)
    printf '%s\n' '--model=<value>' '--thinking=<value>' '--auto-approve' '--max-time=<value>' '--session-dir=<value>' '-e, --extension=<value>' '-r, --resume=<value>' '--prewalk native-switch' '--prewalk-into=<value>' '--config=<value>' '--no-prewalk'
    ;;
  --version) printf 'omp/18.1.14\n' ;;
  config)
    printf '{"key":"prewalk.enabled","value":%s,"type":"boolean"}\n' "${FM_FAKE_OMP_PREWALK_ENABLED:-false}"
    ;;
  models)
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-5.6-luna","selector":"openai-codex/gpt-5.6-luna","thinking":["low","medium","high","xhigh","max"]}]}'
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/omp"

  printf '%s\n' "$fakebin"
}

make_relaunch_case() {
  local name=$1 id=$2
  local case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_relaunch_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'omp\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'Delivery contract: mode=no-mistakes\nomp relaunch brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_relaunch_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

write_omp_meta() {
  local file=$1 id=$2 wt=$3 proj=$4 fakebin=$5
  shift 5
  local extra="$*"
  local omp_bin bun
  omp_bin=$(cd "$fakebin" && pwd)/omp
  bun=$(cd "$fakebin" && pwd)/bun
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$proj"
    printf 'harness=omp\n'
    printf 'kind=ship\n'
    printf 'mode=no-mistakes\n'
    printf 'yolo=off\n'
    printf 'tasktmp=\n'
    printf 'model=openai-codex/gpt-5.6-luna\n'
    printf 'effort=high\n'
    printf 'spawn_gen=gen1\n'
    printf 'omp_bin=%s\n' "$omp_bin"
    printf 'omp_bun=%s\n' "$bun"
    [ -z "$extra" ] || printf '%s\n' "$extra"
  } > "$file"
}

create_prior_artifacts() {
  local state=$1 id=$2 tasktmp=$3
  : > "$state/$id.status"
  : > "$state/$id.omp-ext.ts"
  : > "$state/$id.omp-ready"
  : > "$state/$id.omp-started"
  : > "$state/$id.omp-doorbell-ready"
  mkdir -p "$state/$id.omp-doorbell-ready.requests"
  [ -z "$tasktmp" ] || mkdir -p "$tasktmp"
}

test_omp_ship_relaunch_accepts_existing_artifacts() {
  local rec id out status
  id=omp-relaunch-accept-z1
  rec=$(make_relaunch_case relaunch-accept "$id")
  read_relaunch_record "$rec"
  write_omp_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR" "$FAKEBIN_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id" "/tmp/fm-$id"

  FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_OMP_ACK="$FM_TEST_OMP_ACK" \
    FM_FAKE_OMP_NO_PREWALK=1 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  expect_code 0 "$status" "OMP ship relaunch with existing artifacts should succeed"
  assert_contains "$out" "spawned $id" "OMP relaunch did not report success"
  assert_grep "mode=no-mistakes" "$HOME_DIR/state/$id.meta" "relaunch did not preserve mode"
  assert_grep "yolo=off" "$HOME_DIR/state/$id.meta" "relaunch did not preserve yolo"
  assert_grep "model=openai-codex/gpt-5.6-luna" "$HOME_DIR/state/$id.meta" "relaunch did not preserve model"
  assert_grep "effort=high" "$HOME_DIR/state/$id.meta" "relaunch did not preserve effort"
  pass "OMP ship relaunch accepts existing task artifacts and preserves profile"
}

test_omp_ship_relaunch_preserves_prewalk_and_extension_opt_in() {
  local rec id out status
  id=omp-relaunch-prewalk-z2
  rec=$(make_relaunch_case relaunch-prewalk "$id")
  read_relaunch_record "$rec"
  write_omp_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" \
    "prewalk_into=openai-codex/gpt-5.6-luna:xhigh" \
    "allow_project_omp_extensions=1"
  create_prior_artifacts "$HOME_DIR/state" "$id" "/tmp/fm-$id"

  FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_OMP_ACK="$FM_TEST_OMP_ACK" \
    FM_FAKE_OMP_NO_PREWALK=1 \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  expect_code 0 "$status" "OMP ship relaunch with prewalk and extension opt-in should succeed"
  assert_grep "prewalk_into=openai-codex/gpt-5.6-luna:xhigh" "$HOME_DIR/state/$id.meta" \
    "relaunch did not preserve prewalk target"
  assert_grep "allow_project_omp_extensions=1" "$HOME_DIR/state/$id.meta" \
    "relaunch did not preserve project extension opt-in"
  pass "OMP ship relaunch preserves explicit prewalk and extension opt-in"
}

test_omp_relaunch_refuses_symlinked_runtime_artifact() {
  local rec id out status sentinel
  id=omp-relaunch-symlink-z7
  rec=$(make_relaunch_case relaunch-symlink "$id")
  read_relaunch_record "$rec"
  write_omp_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR" "$FAKEBIN_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id" "/tmp/fm-$id"
  sentinel="$HOME_DIR/sentinel"
  printf 'keep\n' > "$sentinel"
  rm -f "$HOME_DIR/state/$id.omp-ext.ts"
  ln -s "$sentinel" "$HOME_DIR/state/$id.omp-ext.ts"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "symlinked OMP artifact relaunch unexpectedly succeeded"
  assert_contains "$out" "unsafe artifact path" \
    "symlinked OMP artifact relaunch did not refuse the unsafe path"
  assert_grep "keep" "$sentinel" \
    "symlinked OMP artifact relaunch modified the symlink target"
  pass "OMP relaunch refuses symlinked runtime artifacts"
}

test_omp_relaunch_refuses_symlinked_request_directory() {
  local rec id out status target_dir
  id=omp-relaunch-request-symlink-z8
  rec=$(make_relaunch_case relaunch-request-symlink "$id")
  read_relaunch_record "$rec"
  write_omp_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR" "$FAKEBIN_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id" "/tmp/fm-$id"
  rm -rf "$HOME_DIR/state/$id.omp-doorbell-ready.requests"
  target_dir="$HOME_DIR/request-target"
  mkdir -p "$target_dir"
  ln -s "$target_dir" "$HOME_DIR/state/$id.omp-doorbell-ready.requests"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "symlinked OMP request directory relaunch unexpectedly succeeded"
  assert_contains "$out" "unsafe artifact path" \
    "symlinked OMP request directory relaunch did not refuse the unsafe path"
  [ -z "$(find "$target_dir" -mindepth 1 -print -quit)" ] || \
    fail "symlinked OMP request directory relaunch wrote through the symlink"
  pass "OMP relaunch refuses symlinked request directories"
}

test_omp_fresh_spawn_refuses_existing_artifacts() {
  local rec id out status
  id=omp-fresh-collision-z3
  rec=$(make_relaunch_case fresh-collision "$id")
  read_relaunch_record "$rec"
  write_omp_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR" "$FAKEBIN_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id" "/tmp/fm-$id"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness omp --mode no-mistakes --yolo off 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "fresh OMP spawn with existing artifacts unexpectedly succeeded"
  assert_contains "$out" "already has artifacts" \
    "fresh OMP spawn did not refuse an artifact collision"
  pass "fresh OMP spawn refuses existing task artifacts"
}

test_omp_relaunch_refuses_active_tmux_endpoint() {
  local rec id out status
  id=omp-relaunch-active-z4
  rec=$(make_relaunch_case relaunch-active "$id")
  read_relaunch_record "$rec"
  write_omp_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR" "$FAKEBIN_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id" "/tmp/fm-$id"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_TMUX_ACTIVE=1 FM_FAKE_LIST_WINDOWS="fm-$id" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "active tmux OMP relaunch unexpectedly succeeded"
  assert_contains "$out" "still has a live agent" \
    "active tmux relaunch did not refuse a live endpoint"
  pass "OMP relaunch refuses an active tmux endpoint"
}

test_omp_relaunch_refuses_mismatched_endpoint_identity() {
  local rec id out status
  id=omp-relaunch-identity-z5
  rec=$(make_relaunch_case relaunch-identity "$id")
  read_relaunch_record "$rec"
  write_omp_meta "$HOME_DIR/state/$id.meta" "$id" "$WT_DIR" "$PROJ_DIR" "$FAKEBIN_DIR"
  sed -i 's/^endpoint_task_id=.*/endpoint_task_id=other-task/' "$HOME_DIR/state/$id.meta"
  create_prior_artifacts "$HOME_DIR/state" "$id" "/tmp/fm-$id"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "mismatched-identity OMP relaunch unexpectedly succeeded"
  assert_contains "$out" "does not match this task" \
    "mismatched-identity relaunch did not refuse with a clear reason"
  pass "OMP relaunch refuses a recorded endpoint belonging to another task"
}

test_omp_relaunch_refuses_missing_worktree() {
  local rec id out status
  id=omp-relaunch-missing-wt-z6
  rec=$(make_relaunch_case relaunch-missing-wt "$id")
  read_relaunch_record "$rec"
  write_omp_meta "$HOME_DIR/state/$id.meta" "$id" "/no/such/worktree" "$PROJ_DIR" "$FAKEBIN_DIR"
  create_prior_artifacts "$HOME_DIR/state" "$id" "/tmp/fm-$id"

  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "missing-worktree OMP relaunch unexpectedly succeeded"
  assert_contains "$out" "recorded worktree is missing" \
    "missing-worktree relaunch did not refuse"
  pass "OMP relaunch refuses a recorded worktree that is missing"
}

# Run tests in an order that lets each test own its isolated fixture.
test_omp_ship_relaunch_accepts_existing_artifacts
test_omp_ship_relaunch_preserves_prewalk_and_extension_opt_in
test_omp_relaunch_refuses_symlinked_runtime_artifact
test_omp_relaunch_refuses_symlinked_request_directory
test_omp_fresh_spawn_refuses_existing_artifacts
test_omp_relaunch_refuses_active_tmux_endpoint
test_omp_relaunch_refuses_mismatched_endpoint_identity
test_omp_relaunch_refuses_missing_worktree

pass "all OMP relaunch guard tests"
