#!/usr/bin/env bash
# Tests for the per-copy pre-push guard bin/fm-spawn.sh installs into every
# ship and scout working copy (implementation: bin/fm-prepush-guard.sh).
#
# The guard refuses pushes whose destination ref is main, master, or the
# repository's resolved default branch when the push targets the spawned
# copy's repository (matched by canonical git common dir). It is installed
# through command-scope GIT_CONFIG_* environment on the launch command, so no
# repository config, shared hooks dir, or sibling worktree is ever written;
# fm-teardown's tasktmp removal retires it.
#
# Fixture discipline (post-incident rule): everything lives under a fresh
# fm_test_tmproot root, every git call uses `git -C`, init/cd failures abort
# the case, remotes are local bare repositories inside the root only, commit
# identity comes from fm_git_identity's environment or inline `-c` (never
# `git config user.*`), and nothing here can reach a real remote.
#
# Every refused-push assertion first makes the push a REAL ref update (a
# commit ahead of the remote or a ref creation/deletion): git skips hooks
# entirely on "Everything up-to-date" pushes, so a no-op push would pass the
# test without the guard ever running.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-prepush-guard)

# Run a git command the way the spawned worker would see it: the launch env
# carries command-scope core.hooksPath pointing at the task's guard dir.
worker_git() {  # <hooks-dir> <repo-dir> <git args...>
  local hooks=$1 repo=$2
  shift 2
  env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$hooks" \
    git -C "$repo" "$@"
}

wt_commit() {  # <repo> <message>: an empty commit, inline identity only
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m "$2"
}

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
    [ -z "${FM_FAKE_SEND_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_SEND_LOG"
    exit 0
    ;;
  list-windows|has-session|new-session|new-window|kill-window|kill-pane|list-panes) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" || return 1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>` and any other invocation: succeed silently.
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
# Hermetic stub: `axi status` reports no active run; everything else is a no-op.
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes" || return 1
  printf '%s\n' "$fakebin"
}

# make_case <name> <task-id> [default-branch]: a fake home, a project clone
# with a local bare origin, one pooled worktree (the spawn target) and one
# sibling worktree. Echoes "case_dir|home|project|origin|pool|sibling|fakebin".
make_case() {
  local name=$1 id=$2 default=${3:-main}
  local case_dir home project origin pool sibling fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/treehouse-pool/1/project"
  sibling="$case_dir/sibling"
  fakebin=$(make_spawn_fakebin "$case_dir/fake") || return 1

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" || return 1
  printf 'codex\n' > "$home/config/crew-harness" || return 1
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md" || return 1
  touch "$home/state/.last-watcher-beat" || return 1

  mkdir -p "$project" || return 1
  git -C "$project" init --quiet -b "$default" || return 1
  printf 'base\n' > "$project/README.md" || return 1
  git -C "$project" add README.md || return 1
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial || return 1
  git -C "$case_dir" clone --quiet --bare "$project" "$origin" || return 1
  git -C "$project" remote add origin "file://$origin" || return 1
  git -C "$project" worktree add --quiet --detach "$pool" "$default" || return 1
  git -C "$project" worktree add --quiet --detach "$sibling" "$default" || return 1
  printf 'pool-local-config\n' > "$pool/treehouse.toml" || return 1
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({worktrees:[{name:"1",path:process.argv[2]}]}))' \
    "$case_dir/treehouse-pool/treehouse-state.json" "$pool" || return 1

  printf '%s\n' "$case_dir|$home|$project|$origin|$pool|$sibling|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR ORIGIN_DIR POOL_DIR SIBLING_DIR FAKEBIN_DIR <<EOF
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
    FM_FAKE_SEND_LOG="$CASE_DIR/send.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" "$@" 2>&1
}

run_teardown() {  # <home> <id>: uses FAKEBIN_DIR from read_case_record
  local home=$1 id=$2
  # The fixture fakes must win PATH; a wrong path silently falls through to
  # host tools like real treehouse/tmux, which CI runners do not have.
  [ -x "$FAKEBIN_DIR/treehouse" ] || { echo "error: missing fake treehouse at $FAKEBIN_DIR" >&2; return 1; }
  [ "$(PATH="$FAKEBIN_DIR:$PATH" command -v treehouse)" = "$FAKEBIN_DIR/treehouse" ] \
    || { echo "error: fake treehouse does not win PATH" >&2; return 1; }
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" 2>&1
}

# Extract the hooks dir the launch command carries, from the fake send log.
send_log_hooks_dir() {  # <send-log>
  sed -n "s/.*GIT_CONFIG_VALUE_0='\([^']*\)'.*/\1/p" "$1" | head -1
}

test_spawn_installs_guard_and_blocks_default_branch_pushes() {
  local rec id out status hooks_dir recorded_common
  id='prepush-ship-r1'
  rec=$(make_case ship-block "$id") || fail "fixture setup failed"
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn failed: $out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_contains "$(cat "$CASE_DIR/send.log")" "GIT_CONFIG_KEY_0=core.hooksPath" \
    "launch command did not inject core.hooksPath"
  hooks_dir=$(send_log_hooks_dir "$CASE_DIR/send.log")
  assert_equals "/tmp/fm-$id/prepush-guard" "$hooks_dir" \
    "launch env did not point at the task-local hooks dir"
  assert_present "$hooks_dir/pre-push" "pre-push wrapper was not installed"
  [ -x "$hooks_dir/pre-push" ] || fail "pre-push wrapper is not executable"
  recorded_common=$(cd "$(git -C "$POOL_DIR" rev-parse --git-common-dir)" && pwd -P) \
    || fail "could not canonicalize the pool's git common dir"
  assert_grep "$recorded_common" "$hooks_dir/common-dir" \
    "guard did not record the spawned copy's git common dir"

  # Real updates only: a detached-HEAD commit ahead of origin/main.
  wt_commit "$POOL_DIR" 'worker work' || fail "fixture commit failed"
  # Advance the shared local main too, so the `push origin main` form is a
  # real update rather than a hookless no-op.
  wt_commit "$PROJECT_DIR" 'main ahead' || fail "local-main advance failed"

  out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin HEAD:main 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "push origin HEAD:main was not refused"
  assert_contains "$out" "fm-prepush-guard" "refusal did not name the guard"
  assert_contains "$out" "--no-verify" "refusal did not name the deliberate bypass"
  assert_contains "$out" "main" "refusal did not name the protected ref"

  if out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin main 2>&1); then
    fail "push origin main was not refused"
  fi
  assert_contains "$out" "fm-prepush-guard" "main push refusal did not name the guard"

  if out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin HEAD:master 2>&1); then
    fail "push origin HEAD:master was not refused"
  fi

  if out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin :main 2>&1); then
    fail "deletion of origin/main was not refused"
  fi

  out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin "HEAD:refs/heads/fm/$id" 2>&1)
  status=$?
  expect_code 0 "$status" "task-branch push was refused: $out"
  git -C "$ORIGIN_DIR" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null \
    || fail "task-branch push did not reach the local bare remote"

  # A multi-ref push is refused as a whole when any destination is protected.
  if out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin \
      "HEAD:refs/heads/fm/$id-multi" HEAD:main 2>&1); then
    fail "multi-ref push containing main was not refused"
  fi
  ! git -C "$ORIGIN_DIR" rev-parse --verify --quiet "refs/heads/fm/$id-multi" >/dev/null \
    || fail "the unprotected ref in a refused multi-ref push still landed"

  # The named deliberate bypass works.
  out=$(worker_git "$hooks_dir" "$POOL_DIR" push --no-verify origin HEAD:main 2>&1)
  status=$?
  expect_code 0 "$status" "--no-verify bypass was refused: $out"
  [ "$(git -C "$ORIGIN_DIR" rev-parse main)" = "$(git -C "$POOL_DIR" rev-parse HEAD)" ] \
    || fail "--no-verify push did not update origin/main"

  rm -rf "/tmp/fm-$id"
  pass "spawned copy refuses main/master/default pushes, allows fm/<task>, honors --no-verify"
}

test_guard_blocks_nonstandard_default_branch() {
  local rec id out hooks_dir
  id='prepush-trunk-r1'
  rec=$(make_case trunk-block "$id" trunk) || fail "fixture setup failed"
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "trunk spawn failed: $out"
  hooks_dir=$(send_log_hooks_dir "$CASE_DIR/send.log")
  [ -n "$hooks_dir" ] || fail "no hooks dir in launch env"

  wt_commit "$POOL_DIR" 'worker work' || fail "fixture commit failed"
  if out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin HEAD:trunk 2>&1); then
    fail "push to the resolved default branch 'trunk' was not refused"
  fi
  assert_contains "$out" "fm-prepush-guard" "trunk refusal did not name the guard"

  rm -rf "/tmp/fm-$id"
  pass "a non-main default branch resolved from origin/HEAD is refused"
}

test_guard_uses_pushurl_default_branch() {
  local rec id out hooks_dir push_origin
  id='prepush-pushurl-r1'
  rec=$(make_case pushurl-block "$id") || fail "fixture setup failed"
  read_case_record "$rec"

  push_origin="$CASE_DIR/push-origin.git"
  mkdir -p "$push_origin" || fail "push remote directory failed"
  git -C "$push_origin" init -q --bare || fail "push remote init failed"
  git -C "$PROJECT_DIR" push -q origin HEAD:refs/heads/trunk || fail "push remote seed failed"
  git -C "$push_origin" symbolic-ref HEAD refs/heads/trunk || fail "push remote HEAD failed"
  git -C "$PROJECT_DIR" remote set-url --push origin "file://$push_origin" \
    || fail "pushurl setup failed"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "pushurl spawn failed: $out"
  hooks_dir=$(send_log_hooks_dir "$CASE_DIR/send.log")
  wt_commit "$POOL_DIR" 'worker work' || fail "fixture commit failed"
  if out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin HEAD:trunk 2>&1); then
    fail "push to the pushurl default branch 'trunk' was not refused"
  fi
  assert_contains "$out" "fm-prepush-guard" "pushurl refusal did not name the guard"

  rm -rf "/tmp/fm-$id"
  pass "pushurl default branch is protected"
}

test_guard_scopes_to_spawned_repo_only() {
  local rec id out hooks_dir scratch scratch_origin status
  id='prepush-scope-r1'
  rec=$(make_case scope "$id") || fail "fixture setup failed"
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "spawn failed: $out"
  hooks_dir=$(send_log_hooks_dir "$CASE_DIR/send.log")

  # An unrelated repository under the same worker env is never guarded:
  # scratch fixture pushes to its own local bare main keep working.
  scratch="$CASE_DIR/scratch"
  scratch_origin="$CASE_DIR/scratch-origin.git"
  mkdir -p "$scratch_origin" || fail "scratch origin directory failed"
  git -C "$scratch_origin" init -q --bare || fail "scratch origin init failed"
  git -C "$scratch_origin" symbolic-ref HEAD refs/heads/main || fail "scratch origin HEAD failed"
  mkdir -p "$scratch" || fail "scratch directory failed"
  git -C "$scratch" init -q -b main || fail "scratch init failed"
  printf 'scratch\n' > "$scratch/README.md" || fail "scratch seed write failed"
  git -C "$scratch" add README.md || fail "scratch add failed"
  git -C "$scratch" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm scratch || fail "scratch commit failed"
  git -C "$scratch" remote add origin "file://$scratch_origin" || fail "scratch remote add failed"
  out=$(worker_git "$hooks_dir" "$scratch" push origin HEAD:main 2>&1)
  status=$?
  expect_code 0 "$status" "unrelated scratch repo push was refused: $out"

  # The guard is keyed on the repository's common dir, not the process cwd:
  # pushes to the SAME repository through its sibling worktree or the primary
  # checkout are still refused under the worker's environment.
  wt_commit "$PROJECT_DIR" 'main ahead' || fail "local-main advance failed"
  if out=$(worker_git "$hooks_dir" "$SIBLING_DIR" push origin main 2>&1); then
    fail "sibling-worktree push to main was not refused"
  fi
  if out=$(worker_git "$hooks_dir" "$PROJECT_DIR" push origin main 2>&1); then
    fail "primary-checkout push to main was not refused"
  fi

  rm -rf "/tmp/fm-$id"
  pass "guard is keyed to the spawned repository's common dir; foreign repos stay pushable"
}

test_guard_leaves_sibling_and_shared_config_untouched() {
  local rec id out hooks_dir config_before config_after sibling_gitdir_before sibling_gitdir_after
  id='prepush-isolation-r1'
  rec=$(make_case isolation "$id") || fail "fixture setup failed"
  read_case_record "$rec"

  config_before=$(git -C "$PROJECT_DIR" config --list --show-origin) || fail "could not read shared config"
  sibling_gitdir_before=$(find "$(git -C "$SIBLING_DIR" rev-parse --git-dir)" -type f -print | sort) \
    || fail "could not inventory the sibling git dir"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "spawn failed: $out"
  hooks_dir=$(send_log_hooks_dir "$CASE_DIR/send.log")
  assert_present "$hooks_dir/pre-push" "guard hooks dir missing after spawn"

  config_after=$(git -C "$PROJECT_DIR" config --list --show-origin) || fail "could not re-read shared config"
  [ "$config_before" = "$config_after" ] || fail "spawn changed the shared repository config"
  sibling_gitdir_after=$(find "$(git -C "$SIBLING_DIR" rev-parse --git-dir)" -type f -print | sort) \
    || fail "could not re-inventory the sibling git dir"
  [ "$sibling_gitdir_before" = "$sibling_gitdir_after" ] \
    || fail "spawn wrote into the sibling worktree's git dir"

  # Without the worker's launch env, git sees no hooksPath in any copy.
  [ -z "$(git -C "$POOL_DIR" config --get core.hooksPath || true)" ] \
    || fail "spawn wrote core.hooksPath into the spawned copy's repo config"
  [ -z "$(git -C "$SIBLING_DIR" config --get core.hooksPath || true)" ] \
    || fail "spawn wrote core.hooksPath into the sibling's repo config"

  # A plain push from the sibling (no worker env) still reaches main.
  wt_commit "$SIBLING_DIR" 'sibling work' || fail "sibling commit failed"
  out=$(git -C "$SIBLING_DIR" push origin HEAD:main 2>&1)
  expect_code 0 "$?" "plain sibling push to main failed outside the worker env: $out"

  rm -rf "/tmp/fm-$id"
  pass "install is per-copy env only: shared config and sibling worktrees are byte-identical"
}

test_existing_repo_hooks_still_run() {
  local rec id out hooks_dir common hooks custom_hooks
  id='prepush-chain-r1'
  rec=$(make_case chain "$id") || fail "fixture setup failed"
  read_case_record "$rec"

  # A project hook in the default shared location, and a hook reached through
  # a configured core.hooksPath, must both survive the guard's override.
  common=$(git -C "$POOL_DIR" rev-parse --git-common-dir) || fail "could not resolve common dir"
  hooks="$common/hooks"
  mkdir -p "$hooks" || fail "could not create repo hooks dir"
  cat > "$hooks/pre-push" <<SH
#!/bin/sh
printf 'repo-pre-push\n' >> '$CASE_DIR/repo-hook-ran'
SH
  cat > "$hooks/pre-commit" <<SH
#!/bin/sh
printf 'repo-pre-commit\n' >> '$CASE_DIR/repo-hook-ran'
SH
  chmod +x "$hooks/pre-push" "$hooks/pre-commit" || fail "repo hook chmod failed"
  custom_hooks="$CASE_DIR/custom-hooks"
  mkdir -p "$custom_hooks" || fail "custom hooks dir failed"
  cat > "$custom_hooks/pre-push" <<SH
#!/bin/sh
printf 'configured-pre-push\n' >> '$CASE_DIR/configured-hook-ran'
SH
  chmod +x "$custom_hooks/pre-push" || fail "custom hook chmod failed"
  git -C "$PROJECT_DIR" config core.hooksPath "$custom_hooks" || fail "could not set repo hooksPath"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "spawn failed: $out"
  hooks_dir=$(send_log_hooks_dir "$CASE_DIR/send.log")

  wt_commit "$POOL_DIR" 'worker work' || fail "fixture commit failed"
  out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin "HEAD:refs/heads/fm/$id" 2>&1)
  expect_code 0 "$?" "allowed push failed under the guard: $out"
  assert_grep 'configured-pre-push' "$CASE_DIR/configured-hook-ran" \
    "the repo's configured core.hooksPath pre-push was not chained"
  assert_absent "$CASE_DIR/repo-hook-ran" \
    "the default hooks dir ran even though a configured hooksPath should win"

  # A refused push stops before the repository hook runs.
  if out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin HEAD:main 2>&1); then
    fail "main push was not refused"
  fi
  [ "$(wc -l < "$CASE_DIR/configured-hook-ran")" -eq 1 ] \
    || fail "the repository pre-push still ran for a refused push"

  # A non-push hook is dispatched through to the repository too: commit in the
  # worktree must still trigger the project's pre-commit even though the
  # effective hooks dir is the guard's.
  git -C "$PROJECT_DIR" config --unset core.hooksPath || fail "could not unset repo hooksPath"
  printf 'work\n' > "$POOL_DIR/commit-check.txt" || fail "commit fixture write failed"
  git -C "$POOL_DIR" add commit-check.txt || fail "commit fixture add failed"
  out=$(worker_git "$hooks_dir" "$POOL_DIR" \
      -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit -qm chain-check 2>&1)
  expect_code 0 "$?" "commit failed under the guard env: $out"
  assert_grep 'repo-pre-commit' "$CASE_DIR/repo-hook-ran" \
    "the repo's own pre-commit did not run under the guard's hooks dir"

  rm -rf "/tmp/fm-$id"
  pass "the guard's hooks dir chains every hook to the repository's own hooks"
}

test_teardown_retires_the_guard() {
  local rec id out hooks_dir
  id='prepush-teardown-r1'
  rec=$(make_case teardown "$id") || fail "fixture setup failed"
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "spawn failed: $out"
  hooks_dir=$(send_log_hooks_dir "$CASE_DIR/send.log")
  assert_present "$hooks_dir/pre-push" "guard hooks dir missing after spawn"
  assert_grep "tasktmp=/tmp/fm-$id" "$HOME_DIR/state/$id.meta" \
    "task meta did not record the task temp root the guard lives under"

  out=$(run_teardown "$HOME_DIR" "$id")
  expect_code 0 "$?" "teardown failed: $out"
  assert_absent "/tmp/fm-$id" "teardown left the task temp root (and the guard) behind"

  # The returned slot carries no guard: a plain push to main succeeds, and a
  # stale copy of the retired env is a no-op rather than a refusal (git treats
  # a missing hooksPath dir as no hooks).
  wt_commit "$POOL_DIR" 'post-teardown' || fail "post-teardown commit failed"
  out=$(git -C "$POOL_DIR" push origin HEAD:main 2>&1)
  expect_code 0 "$?" "post-teardown push to main failed: $out"
  wt_commit "$POOL_DIR" 'post-teardown 2' || fail "second post-teardown commit failed"
  out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin HEAD:main 2>&1)
  expect_code 0 "$?" "push under a retired hooks dir failed: $out"
  [ "$(git -C "$ORIGIN_DIR" rev-parse main)" = "$(git -C "$POOL_DIR" rev-parse HEAD)" ] \
    || fail "the retired-guard push did not update origin/main"

  pass "teardown removes the guard's hooks dir; the reused slot pushes freely"
}

test_scout_spawn_also_installs_the_guard() {
  local rec id out hooks_dir
  id='prepush-scout-r1'
  rec=$(make_case scout "$id") || fail "fixture setup failed"
  read_case_record "$rec"

  out=$(run_spawn "$id" --scout)
  expect_code 0 "$?" "scout spawn failed: $out"
  hooks_dir=$(send_log_hooks_dir "$CASE_DIR/send.log")
  assert_equals "/tmp/fm-$id/prepush-guard" "$hooks_dir" \
    "scout launch env did not point at the task-local hooks dir"
  wt_commit "$POOL_DIR" 'scout work' || fail "fixture commit failed"
  if out=$(worker_git "$hooks_dir" "$POOL_DIR" push origin HEAD:main 2>&1); then
    fail "scout working copy push to main was not refused"
  fi

  rm -rf "/tmp/fm-$id"
  pass "scout working copies get the same guard"
}

test_spawn_installs_guard_and_blocks_default_branch_pushes
test_guard_blocks_nonstandard_default_branch
test_guard_uses_pushurl_default_branch
test_guard_scopes_to_spawned_repo_only
test_guard_leaves_sibling_and_shared_config_untouched
test_existing_repo_hooks_still_run
test_teardown_retires_the_guard
test_scout_spawn_also_installs_the_guard
printf 'all pre-push guard tests passed\n'
