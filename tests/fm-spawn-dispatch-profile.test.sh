#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)
PROFILE_RUN_TOKEN="t$$-${RANDOM:-0}"
profile_id() { printf '%s-%s' "$1" "$PROFILE_RUN_TOKEN"; }
cleanup() {
  local data_dir id home meta tasktmp
  while IFS= read -r data_dir; do
    id=$(basename "$data_dir")
    home=$(dirname "$(dirname "$data_dir")")
    meta="$home/state/$id.meta"
    tasktmp=$(sed -n 's/^tasktmp=//p' "$meta" 2>/dev/null)
    [ -n "$tasktmp" ] || tasktmp=$(sed -n 's/^tasktmp=//p' "$meta.test-owner" 2>/dev/null)
    case "$id:$tasktmp" in
      profile-*:/tmp/fm-"$id") rm -rf "$tasktmp" ;;
    esac
  done < <(find "$TMP_ROOT" -type d -path '*/home/data/profile-*' 2>/dev/null)
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session) exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'kill-window %s\n' "$*" >> "$FM_FAKE_ENDPOINT_LOG"
    exit 0 ;;
  new-window)
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'new-window\n' >> "$FM_FAKE_ENDPOINT_LOG"
    exit 0 ;;
  send-keys)
    for a in "$@"; do
      case "$a" in
        *fm-treehouse-get.sh*' --ready-file '*)
          ready_file=${a##* --ready-file }
          printf '%s\n' "$FM_FAKE_PANE_PATH" > "$ready_file"
          ;;
      esac
    done
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
      case "$*" in
        *Enter*)
          if grep -Fq 'FM_OMP_HARNESS=omp' "$FM_FAKE_LAUNCH_LOG" 2>/dev/null; then
            if [ -n "${FM_FAKE_OMP_ACK:-}" ]; then
              while IFS= read -r ack; do
                [ -z "$ack" ] || : > "$ack"
              done <<EOF
$FM_FAKE_OMP_ACK
EOF
            fi
            if [ "${FM_FAKE_OMP_DYNAMIC_ACK:-0}" = 1 ]; then
              for extension in "$FM_FAKE_OMP_ACK_DIR"/*.omp-ext.ts; do
                [ -e "$extension" ] || continue
                : > "${extension%.omp-ext.ts}.omp-started"
              done
            fi
            if [ -n "${FM_FAKE_OMP_META_TAMPER:-}" ]; then
              cp "$FM_FAKE_OMP_META_TAMPER" "$FM_FAKE_OMP_META_TAMPER.test-owner"
              printf 'window=unrelated:retry\n' > "$FM_FAKE_OMP_META_TAMPER"
            fi
          fi
          ;;
      esac
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
cmd=${1:-}
sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.7.5","protocol":17},"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/fm-profile-herdr.sock"}]}'
    ;;
  "workspace list")
    if [ "${FM_FAKE_HERDR_PARTIAL_PROJECTION:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","active_tab_id":"w1:t1","focused":true}]}}'
    elif [ "${FM_FAKE_HERDR_AMBIGUOUS_RECLAIM:-0}" = 1 ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","active_tab_id":"w1:t1","focused":true},{"workspace_id":"w2","label":"%s","active_tab_id":"w2:t2","focused":false}]}}\n' \
        "$FM_FAKE_HERDR_RECLAIM_WORKSPACE_LABEL"
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}'
    fi
    ;;
  "tab list")
    if [ "${FM_FAKE_HERDR_PARTIAL_PROJECTION:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","focused":true}]}}'
    elif [ "${FM_FAKE_HERDR_AMBIGUOUS_RECLAIM:-0}" = 1 ]; then
      case "$*" in
        *"--workspace w2"*)
          printf '{"result":{"tabs":[{"tab_id":"w2:t2","workspace_id":"w2","label":"%s","focused":false}]}}\n' \
            "$FM_FAKE_HERDR_RECLAIM_TASK_LABEL"
          ;;
        *)
          printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","focused":true}]}}'
          ;;
      esac
    else
      printf '%s\n' '{"result":{"tabs":[]}}'
    fi
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"w2:p2","tab_id":"w2:t2"}]}}'
    ;;
  "workspace create")
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'workspace create\n' >> "$FM_FAKE_ENDPOINT_LOG"
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"w2"}}}'
    ;;
  "tab create")
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'tab create\n' >> "$FM_FAKE_ENDPOINT_LOG"
    if [ "${FM_FAKE_HERDR_AMBIGUOUS_RECLAIM:-0}" = 1 ] \
       && [ "$(grep -c '^tab create$' "$FM_FAKE_ENDPOINT_LOG")" = 1 ]; then
      printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t3"}}}'
    elif [ "${FM_FAKE_HERDR_PARTIAL_CREATE:-0}" != 0 ]; then
      if [ "$FM_FAKE_HERDR_PARTIAL_CREATE" = pane-only ]; then
        printf '%s\n' '{"result":{"root_pane":{"pane_id":"w1:p2"}}}'
      else
        printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"}}}'
      fi
    else
      printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
    fi
    ;;
  "pane process-info")
    if [ -n "${FM_FAKE_HERDR_NESTED_SHELL_FLAG:-}" ] && [ -f "$FM_FAKE_HERDR_NESTED_SHELL_FLAG" ]; then
      if [ "${FM_FAKE_HERDR_REFUSE_NESTED_SHELL:-0}" = 1 ]; then
        printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_process_group_id":4343,"foreground_processes":[{"pid":4343,"name":"sleep","argv0":"sleep"}]}}}'
      else
        printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_process_group_id":4343,"foreground_processes":[{"pid":4343,"name":"fish","argv0":"fish"}]}}}'
      fi
    else
      printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"fish","argv0":"fish"}]}}}'
    fi
    ;;
  "pane get")
    if [ -n "${FM_FAKE_HERDR_PANE_FLAG:-}" ] && [ ! -f "$FM_FAKE_HERDR_PANE_FLAG" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "${3:-w1:p2}" "${FM_FAKE_PANE_PATH:-}"
    ;;
  "pane run")
    if printf '%s' "${4:-}" | grep -Fq 'fm-treehouse-get.sh'; then
      [ -z "${FM_FAKE_HERDR_NESTED_SHELL_FLAG:-}" ] || : > "$FM_FAKE_HERDR_NESTED_SHELL_FLAG"
    fi
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      printf '%s\n' "${4:-}" >> "$FM_FAKE_LAUNCH_LOG"
      if printf '%s' "${4:-}" | grep -Fq 'FM_OMP_HARNESS=omp'; then
        [ -z "${FM_FAKE_OMP_ACK:-}" ] || : > "$FM_FAKE_OMP_ACK"
        if [ "${FM_FAKE_OMP_DYNAMIC_ACK:-0}" = 1 ]; then
          ack=$(printf '%s\n' "${4:-}" | sed -n "s/.* -e '\([^']*\)\.omp-ext\.ts'.*/\1.omp-started/p")
          [ -z "$ack" ] || : > "$ack"
        fi
      fi
    fi
    ;;
  "pane send-text")
    [ -z "${FM_FAKE_LAUNCH_LOG:-}" ] || printf '%s\n' "${4:-}" >> "$FM_FAKE_LAUNCH_LOG"
    ;;
  "pane send-keys")
    case "${4:-}" in
      enter)
        if grep -Fq 'FM_OMP_HARNESS=omp' "${FM_FAKE_LAUNCH_LOG:-/dev/null}" 2>/dev/null; then
          [ -z "${FM_FAKE_OMP_ACK:-}" ] || : > "$FM_FAKE_OMP_ACK"
        fi
        ;;
    esac
    ;;
  "pane close")
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'pane close %s\n' "${3:-}" >> "$FM_FAKE_ENDPOINT_LOG"
    if [ "${FM_FAKE_HERDR_REFUSE_CLOSE:-0}" = 1 ]; then
      exit 0
    fi
    [ -z "${FM_FAKE_HERDR_PANE_FLAG:-}" ] || rm -f "$FM_FAKE_HERDR_PANE_FLAG"
    ;;
  "agent get")
    if [ "${FM_FAKE_HERDR_AMBIGUOUS_RECLAIM:-0}" = 1 ]; then
      printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
      exit 1
    fi
    if [ -n "${FM_FAKE_HERDR_PANE_FLAG:-}" ] && [ ! -f "$FM_FAKE_HERDR_PANE_FLAG" ]; then
      printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"agent":{"agent":"omp","agent_status":"idle"}}}'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  cat > "$fakebin/herdr-ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-axo pid=,ppid=")
    if [ -n "${FM_FAKE_HERDR_NESTED_SHELL_FLAG:-}" ] && [ -f "$FM_FAKE_HERDR_NESTED_SHELL_FLAG" ]; then
      printf '%s\n' '4242 1' '4300 4242' '4343 4300'
    else
      printf '%s\n' '4242 1'
    fi
    ;;
  "-p 4242 -o stat="|"-p 4343 -o stat=") printf '%s\n' 'S' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr-ps"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_TREEHOUSE_LOG:-}" ] || printf '%s|%s\n' "$PWD" "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
if [ "${1:-}" = get ] && printf '%s\n' "$*" | grep -Eq '(^| )--lease( |$)'; then
  if [ -n "${FM_TREEHOUSE_GUARD_COMPLETE_FILE:-}" ]; then
    ( cd "$FM_FAKE_PANE_PATH" \
      && git status --porcelain --untracked-files=all >/dev/null \
      && git checkout --detach --force HEAD >/dev/null \
      && git reset --hard HEAD >/dev/null \
      && git clean -fd >/dev/null ) || exit $?
  fi
  printf '%s\n' "$FM_FAKE_PANE_PATH"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_DESCENDANT_SPAWN:-}" ]; then
  "$FM_FAKE_DESCENDANT_SPAWN" "$FM_FAKE_DESCENDANT_ID" "$FM_FAKE_DESCENDANT_PROJECT" \
    --harness omp --backend tmux --model openai-codex/gpt-5.6-luna --effort high \
    --mode no-mistakes --yolo off
fi
SH
  chmod +x "$fakebin/codex"
  cat > "$fakebin/mkdir" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_FAKE_MKDIR_FAIL_PATH:-}" ] && [ "$arg" = "$FM_FAKE_MKDIR_FAIL_PATH" ]; then
    printf 'injected mkdir failure for %s\n' "$arg" >&2
    exit 1
  fi
done
exec /bin/mkdir "$@"
SH
  chmod +x "$fakebin/mkdir"
  fm_fake_exit0 "$fakebin" pi-signed
  cat > "$fakebin/omp" <<'SH'
#!/usr/bin/env bun
case "${1:-}" in
  --help)
    printf '%s\n' '--model=<value>' '--thinking=<value>' '--auto-approve' '--max-time=<value>' '--session-dir=<value>' '-e, --extension=<value>' '-r, --resume=<value>' '--prewalk native-switch' '--prewalk-into=<value>' '--config=<value>'
    [ "${FM_FAKE_OMP_NO_PREWALK:-1}" != 1 ] || printf '%s\n' '--no-prewalk'
    ;;
  --version) printf 'omp/17.2.11\n' ;;
  config)
    printf '{"key":"prewalk.enabled","value":%s,"type":"boolean"}\n' "${FM_FAKE_OMP_PREWALK_ENABLED:-false}"
    ;;
  models)
    if [ -n "${FM_FAKE_OMP_CATALOG_DIR:-}" ] && [ "$PWD" = "$FM_FAKE_OMP_CATALOG_DIR" ]; then
      printf '%s\n' '{"models":[{"provider":"ollama","id":"gemma3:12b","selector":"ollama/gemma3:12b","thinking":[]}]}'
    else
      printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-5.6-terra","selector":"openai-codex/gpt-5.6-terra","thinking":["low","medium","high","xhigh","max"]},{"provider":"openai-codex","id":"gpt-5.6-luna","selector":"openai-codex/gpt-5.6-luna","thinking":["low","medium","high","xhigh","max"]}]}'
    fi
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/omp"
  cat > "$fakebin/bun" <<'SH'
#!/usr/bin/env bash
script=$1
shift
exec bash "$script" "$@"
SH
  chmod +x "$fakebin/bun"
  printf '%s\n' "$fakebin"
}

install_replacing_od() {
  local fakebin=$1
  cat > "$fakebin/od" <<'SH'
#!/usr/bin/env bash
"$FM_FAKE_OD_REAL" "$@"
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
target=${!#}
if [ -n "${FM_FAKE_OD_REPLACE_FILE:-}" ] && [ "$target" = "$FM_FAKE_OD_REPLACE_FILE" ]; then
  printf 'off\0' > "$target.replacement"
  mv "$target.replacement" "$target"
fi
SH
  chmod +x "$fakebin/od"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    [ ! -e "/tmp/fm-$id" ] && [ ! -L "/tmp/fm-$id" ] \
      || fail "refusing fixture task-id collision at /tmp/fm-$id"
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}
commit_project_omp_extension() {
  local proj=$1 wt=$2 source=${3:-}
  mkdir -p "$proj/.omp/extensions"
  if [ -n "$source" ]; then
    cp "$source" "$proj/.omp/extensions/fm-primary-omp.ts"
  else
    printf '%s\n' 'throw new Error("project extension executed");' > "$proj/.omp/extensions/project.ts"
  fi
  git -C "$proj" add .omp/extensions
  sync_project_commit "$proj" "$wt" 'add omp extension'
}
sync_project_commit() {
  local proj=$1 wt=$2 message=$3 branch
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "$message"
  branch=$(git -C "$proj" branch --show-current)
  git -C "$proj" push -q origin "$branch"
  git -C "$wt" fetch -q origin
  git -C "$wt" merge --ff-only "origin/$branch" >/dev/null
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 endpointlog treehouselog herdrpaneflag herdrshellflag rc meta tasktmp
  shift 4
  endpointlog="${launchlog%/*}/endpoint.log"
  treehouselog="${launchlog%/*}/treehouse.log"
  herdrpaneflag="${launchlog%/*}/herdr-pane"
  herdrshellflag="${launchlog%/*}/herdr-nested-shell"
  : > "$launchlog"
  : > "$endpointlog"
  : > "$treehouselog"
  : > "$herdrpaneflag"
  rm -f "$herdrshellflag"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it
  # explicitly (empty by default) instead of leaking the invoking shell's value,
  # which would make launch assertions depend on the developer's environment.
  # A test opts in to the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    HERDR_ENV='' HERDR_PANE_ID='' HERDR_SESSION='' HERDR_SOCKET_PATH='' \
    HERDR_TAB_ID='' HERDR_WORKSPACE_ID='' \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    HOME="${FM_TEST_HOME_OVERRIDE:-$HOME}" IS_SANDBOX="${FM_TEST_IS_SANDBOX:-}" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_OMP_AUTH_BROKER_URL="${FM_TEST_OMP_AUTH_BROKER_URL:-}" \
    FM_OMP_AUTH_BROKER_TOKEN_FILE="${FM_TEST_OMP_AUTH_BROKER_TOKEN_FILE:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_ENDPOINT_LOG="$endpointlog" \
    FM_FAKE_TREEHOUSE_LOG="$treehouselog" FM_FAKE_OMP_ACK="${FM_TEST_OMP_ACK:-}" \
    FM_FAKE_OMP_DYNAMIC_ACK="${FM_TEST_OMP_DYNAMIC_ACK:-0}" FM_FAKE_OMP_ACK_DIR="$home/state" \
    FM_FAKE_OMP_NO_PREWALK="${FM_TEST_OMP_NO_PREWALK:-1}" \
    FM_FAKE_OMP_PREWALK_ENABLED="${FM_TEST_OMP_PREWALK_ENABLED:-false}" \
    FM_FAKE_OMP_CATALOG_DIR="${FM_TEST_OMP_CATALOG_DIR:-}" \
    FM_FAKE_MKDIR_FAIL_PATH="${FM_TEST_MKDIR_FAIL_PATH:-}" \
    FM_FAKE_HERDR_PARTIAL_CREATE="${FM_TEST_HERDR_PARTIAL_CREATE:-0}" \
    FM_FAKE_HERDR_PARTIAL_PROJECTION="${FM_TEST_HERDR_PARTIAL_PROJECTION:-0}" \
    FM_FAKE_HERDR_AMBIGUOUS_RECLAIM="${FM_TEST_HERDR_AMBIGUOUS_RECLAIM:-0}" \
    FM_FAKE_HERDR_RECLAIM_WORKSPACE_LABEL="${FM_TEST_HERDR_RECLAIM_WORKSPACE_LABEL:-}" \
    FM_FAKE_HERDR_RECLAIM_TASK_LABEL="${FM_TEST_HERDR_RECLAIM_TASK_LABEL:-}" \
    FM_FAKE_HERDR_PANE_FLAG="$herdrpaneflag" \
    FM_FAKE_HERDR_NESTED_SHELL_FLAG="$herdrshellflag" \
    FM_FAKE_HERDR_REFUSE_NESTED_SHELL="${FM_TEST_HERDR_REFUSE_NESTED_SHELL:-0}" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS="${FM_TEST_HERDR_IDLE_SHELL_PROOF_POLLS:-}" \
    FM_FAKE_HERDR_REFUSE_CLOSE="${FM_TEST_HERDR_REFUSE_CLOSE:-0}" \
    FM_FAKE_OMP_META_TAMPER="${FM_TEST_OMP_META_TAMPER:-}" \
    FM_HERDR_PS_BIN="$fakebin/herdr-ps" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    for meta in "$home/state"/*.meta; do
      [ -f "$meta" ] || continue
      tasktmp=$(sed -n 's/^tasktmp=//p' "$meta")
      case "$tasktmp" in /tmp/fm-profile-*) rm -rf "$tasktmp" ;; esac
    done
  fi
  return "$rc"
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

test_no_profile_keeps_claude_profile_defaults() {
  local rec id out status expected launch
  id=$(profile_id profile-off-z1)
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real
  id=$(profile_id profile-relative-paths-z1b)
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
  : > "$LAUNCH_LOG"

  out=$(
    cd "$CASE_DIR" || exit 1
    CDPATH="$CASE_DIR/cdpath" FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=home/data \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative home overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$id/brief.md'" \
    "relative FM_DATA_OVERRIDE leaked into the cross-process brief path"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home
  relative_id=$(profile_id profile-relative-home-defaults-z1c)
  absolute_id=$(profile_id profile-absolute-home-defaults-z1d)
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  : > "$LAUNCH_LOG"
  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$relative_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$relative_id/brief.md'" \
    "relative FM_HOME leaked into the default cross-process brief path"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$absolute_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/brief.md'" \
    "absolute FM_HOME spelling changed in the default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home
  id=$(profile_id profile-absolute-paths-z1c)
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE="$linked_home/state" FM_DATA_OVERRIDE="$linked_home/data" \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$id/brief.md'" \
    "absolute FM_DATA_OVERRIDE spelling changed in the cross-process brief path"
  pass "absolute override spellings are preserved in spawn launch paths"
}

test_unresolvable_relative_overrides_fail_loudly() {
  local rec id out status
  id=$(profile_id profile-unresolvable-paths-z1d)
  rec=$(make_spawn_case profile-unresolvable-paths pi "$id")
  read_case_record "$rec"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=missing-home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative home should fail"
  assert_contains "$out" "FM_HOME directory cannot be resolved: missing-home" \
    "spawn did not name the unresolvable FM_HOME"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=missing-state FM_DATA_OVERRIDE=home/data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative state override should fail"
  assert_contains "$out" "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" \
    "spawn did not name the unresolvable FM_STATE_OVERRIDE"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=missing-data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative data override should fail"
  assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" \
    "spawn did not name the unresolvable FM_DATA_OVERRIDE"
  pass "unresolvable relative spawn overrides fail with named diagnostics"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=$(profile_id profile-required-ship-z11)
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=$(profile_id profile-required-scout-z12)
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id=$(profile_id profile-explicit-z13)
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=$(profile_id profile-positional-z14)
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=$(profile_id profile-raw-z15)
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  printf 'invalid-for-omp\n' > "$HOME_DIR/config/omp-max-time"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag __OMPMAXTIME__")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag __OMPMAXTIME__" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile leaves the raw launch-command escape hatch unchanged"
}

test_raw_omp_launch_does_not_require_max_time_capability() {
  local rec id out status launch
  id=$(profile_id profile-raw-omp-z15b)
  rec=$(make_spawn_case profile-raw-omp claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  printf 'invalid-for-omp\n' > "$HOME_DIR/config/omp-max-time"
  sed -i "s/ '--max-time=<value>'//" "$FAKEBIN_DIR/omp"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "omp --legacy __OMPMAXTIME__")
  status=$?
  expect_code 0 "$status" "raw OMP launch should not require the max-time capability"
  assert_contains "$out" "spawned $id harness=omp" "spawn did not retain raw OMP identity"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "FM_OMP_HARNESS=omp omp --legacy __OMPMAXTIME__" ] \
    || fail "raw OMP launch changed"$'\n'"actual: $launch"
  pass "raw OMP launches ignore max-time configuration and capability checks"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=$(profile_id profile-claude-z2)
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=$(profile_id profile-codex-z3)
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_omits_invalid_max_effort() {
  local rec id out status launch
  id=$(profile_id profile-codex-max-z4)
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with unsupported max effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "model_reasoning_effort" "codex launch must omit unsupported max reasoning effort"
  pass "codex omits unsupported max effort instead of passing a bad config value"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id=$(profile_id profile-grok-z5)
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id=$(profile_id profile-grok-max-z6)
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported max reasoning effort"
}

test_grok_omits_invalid_xhigh_reasoning_effort() {
  local rec id out status launch
  id=$(profile_id profile-grok-xhigh-z6b)
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported xhigh reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 xhigh
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when xhigh effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported xhigh reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported xhigh reasoning effort"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=$(profile_id profile-opencode-z7)
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=$(profile_id profile-pi-z8)
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-luna max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi pi --model 'openai-codex/gpt-5.6-luna' --thinking 'max' -e" \
    "pi launch did not thread the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_pi_signed_threads_shared_pi_profile_and_preserves_identity() {
  local rec id out status launch
  id=$(profile_id profile-pi-signed-z8b)
  rec=$(make_spawn_case profile-pi-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort max)
  status=$?
  expect_code 0 "$status" "pi-signed spawn with max effort should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" "pi-signed spawn did not preserve its visible identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5.6-luna max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed pi-signed --model 'openai-codex/gpt-5.6-luna' --thinking 'max' -e" \
    "pi-signed launch did not share Pi's model, thinking, and extension semantics"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi-signed launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.pi-ext.ts" "pi-signed launch did not install Pi's turn-end extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" "pi-signed spawn did not arm the busy-state contract"
  assert_contains "$(cat "$HOME_DIR/state/$id.busy-state")" "state=busy source=fm-spawn" \
    "pi-signed spawn did not seed the busy-state record from the launch brief"
  local ext gen
  ext=$(cat "$HOME_DIR/state/$id.pi-ext.ts")
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  assert_contains "$ext" 'pi.on("agent_start"' "pi extension lost the semantic agent_start busy edge"
  assert_contains "$ext" 'pi.on("agent_settled"' "pi extension lost the semantic agent_settled idle edge"
  assert_contains "$ext" 'ctx.isIdle()' "pi extension no longer confirms idle with ctx.isIdle()"
  assert_contains "$ext" "\"--gen\", \"$gen\"" "pi extension does not carry the armed incarnation gen"
  assert_contains "$ext" '"--source", "pi-ext"' "pi extension does not attribute its semantic source"
  assert_contains "$ext" 'pi.on("turn_end"' "pi extension lost the turn-end notification touch"
  pass "pi-signed shares Pi launch semantics while preserving its configured and recorded identity"
}

test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=$(profile_id profile-pi-signed-missing-z8c)
  rec=$(make_spawn_case profile-pi-signed-missing pi-signed "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/pi-signed"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing pi-signed executable should refuse the spawn"
  assert_contains "$out" "pi-signed executable not found on PATH" \
    "missing pi-signed refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing pi-signed refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing pi-signed refusal typed a launch command"
  pass "pi-signed refuses safely and actionably when the selected executable is unavailable"
}

test_omp_threads_exact_identity_model_and_every_thinking_level() {
  local effort rec id out status launch expected_bin expected_bun
  for effort in low medium high xhigh max; do
    id=$(profile_id "profile-omp-${effort}-z8o")
    rec=$(make_spawn_case "profile-omp-$effort" omp "$id")
    read_case_record "$rec"
    export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model openai-codex/gpt-5.6-luna --effort "$effort")
    status=$?
    expect_code 0 "$status" "OMP spawn with $effort thinking should succeed"
    assert_contains "$out" "spawned $id harness=omp kind=ship" "OMP spawn did not preserve exact identity"
    assert_meta_profile "$HOME_DIR/state/$id.meta" omp openai-codex/gpt-5.6-luna "$effort"
    launch=$(cat "$LAUNCH_LOG")
    expected_bin=$(cd "$FAKEBIN_DIR" && pwd -P)/omp
    expected_bun=$(cd "$FAKEBIN_DIR" && pwd -P)/bun
    assert_contains "$launch" "FM_OMP_BUN=" "OMP launch omitted its canonical Bun runtime identity"
    assert_contains "$launch" "$expected_bun" "OMP launch omitted its canonical Bun runtime path"
    assert_contains "$launch" "$expected_bin" "OMP launch omitted its canonical entrypoint path"
    assert_contains "$launch" "/bin/bash -c" "OMP launch did not use its Bash-owned command wrapper"
    # shellcheck disable=SC2016 # The literal expansion must never reach the pane shell.
    assert_not_contains "$launch" '${PATH:+' "OMP launch exposed POSIX parameter expansion to the pane shell"
    assert_contains "$launch" "$expected_bin" \
      "OMP launch did not execute the canonical entrypoint with unattended mode, model, thinking, and extension"
    assert_grep "omp_bun=$expected_bun" "$HOME_DIR/state/$id.meta" \
      "OMP launch metadata did not bind the same Bun executable used by the literal pane command"
    assert_not_contains "$launch" "--prewalk" "ordinary OMP launch must not enable Prewalk without explicit opt-in"
    assert_no_grep '^prewalk_into=' "$HOME_DIR/state/$id.meta" \
      "ordinary OMP metadata must not add a prewalk target"
    [ "$(grep -Fo "encode launch-brief" "$LAUNCH_LOG" | wc -l | tr -d ' ')" = 1 ] \
      || fail "OMP launch did not deliver exactly one positional launch brief"
    assert_present "$HOME_DIR/state/$id.omp-ext.ts" "OMP launch did not create the external turn extension"
    unset FM_TEST_OMP_ACK
  done
  pass "OMP invokes its canonical entrypoint directly and records its runtime identity"
}

test_omp_threads_configurable_max_time() {
  local rec id out status launch corrupt_case corrupt_payload config_hex

  id=$(profile_id profile-omp-max-time-default-z8oa)
  rec=$(make_spawn_case profile-omp-max-time-default omp "$id")
  read_case_record "$rec"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "OMP spawn without max-time config should use the default"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--auto-approve --max-time=3h -e" \
    "unconfigured OMP launch did not receive the three-hour default"

  id=$(profile_id profile-omp-max-time-override-z8oa)
  rec=$(make_spawn_case profile-omp-max-time-override omp "$id")
  read_case_record "$rec"
  printf '# bounded workers\n  10m  \n' > "$HOME_DIR/config/omp-max-time"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "OMP spawn with a max-time override should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--auto-approve --max-time=10m -e" \
    "configured OMP launch did not receive the max-time override"

  id=$(profile_id profile-omp-max-time-snapshot-z8oa)
  rec=$(make_spawn_case profile-omp-max-time-snapshot omp "$id")
  read_case_record "$rec"
  printf '10m\n' > "$HOME_DIR/config/omp-max-time"
  install_replacing_od "$FAKEBIN_DIR"
  export FM_FAKE_OD_REAL
  FM_FAKE_OD_REAL=$(command -v od)
  export FM_FAKE_OD_REPLACE_FILE="$HOME_DIR/config/omp-max-time"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  unset FM_FAKE_OD_REPLACE_FILE FM_FAKE_OD_REAL
  expect_code 0 "$status" "OMP max-time launch should use its validated byte snapshot"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--auto-approve --max-time=10m -e" \
    "atomic config replacement changed the validated max-time snapshot"
  config_hex=$(od -An -tx1 "$HOME_DIR/config/omp-max-time" | tr -d ' \n')
  [ "$config_hex" = 6f666600 ] || fail "snapshot regression did not replace the live config with off plus NUL"

  id=$(profile_id profile-omp-max-time-off-z8oa)
  rec=$(make_spawn_case profile-omp-max-time-off omp "$id")
  read_case_record "$rec"
  printf 'off\n' > "$HOME_DIR/config/omp-max-time"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "OMP spawn with max-time disabled should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--max-time" \
    "config/omp-max-time=off did not restore an unbounded OMP launch"

  id=$(profile_id profile-omp-max-time-invalid-z8oa)
  rec=$(make_spawn_case profile-omp-max-time-invalid omp "$id")
  read_case_record "$rec"
  printf '10s\n' > "$HOME_DIR/config/omp-max-time"
  unset FM_TEST_OMP_ACK
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "invalid OMP max-time config should refuse"
  assert_contains "$out" "config/omp-max-time must contain off or a positive integer" \
    "invalid max-time refusal did not explain the accepted values"
  [ ! -s "$CASE_DIR/endpoint.log" ] || fail "invalid max-time config created a backend endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "invalid max-time config typed an OMP launch command"

  for corrupt_case in nul control; do
    id=$(profile_id "profile-omp-max-time-$corrupt_case-z8oa")
    rec=$(make_spawn_case "profile-omp-max-time-$corrupt_case" omp "$id")
    read_case_record "$rec"
    case "$corrupt_case" in
      nul) corrupt_payload='off\0' ;;
      control) corrupt_payload='off\001' ;;
    esac
    printf '%b' "$corrupt_payload" > "$HOME_DIR/config/omp-max-time"
    unset FM_TEST_OMP_ACK
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "OMP max-time config containing $corrupt_case bytes should refuse"
    assert_contains "$out" "config/omp-max-time must contain text only" \
      "binary max-time refusal did not explain the text-only contract"
    [ ! -s "$CASE_DIR/endpoint.log" ] || fail "binary max-time config created a backend endpoint"
    [ ! -s "$LAUNCH_LOG" ] || fail "binary max-time config typed an OMP launch command"
  done

  id=$(profile_id profile-omp-max-time-dangling-z8oa)
  rec=$(make_spawn_case profile-omp-max-time-dangling omp "$id")
  read_case_record "$rec"
  ln -s missing "$HOME_DIR/config/omp-max-time"
  unset FM_TEST_OMP_ACK
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "dangling OMP max-time config should refuse"
  assert_contains "$out" "config/omp-max-time must be a regular file" \
    "dangling max-time refusal did not identify the invalid path"
  [ ! -s "$CASE_DIR/endpoint.log" ] || fail "dangling max-time config created a backend endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "dangling max-time config typed an OMP launch command"

  id=$(profile_id profile-omp-max-time-unreadable-z8oa)
  rec=$(make_spawn_case profile-omp-max-time-unreadable omp "$id")
  read_case_record "$rec"
  printf '10m\n' > "$HOME_DIR/config/omp-max-time"
  chmod 000 "$HOME_DIR/config/omp-max-time"
  unset FM_TEST_OMP_ACK
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "unreadable OMP max-time config should refuse"
  assert_contains "$out" "config/omp-max-time could not be read" \
    "unreadable max-time refusal did not explain the failure"
  [ ! -s "$CASE_DIR/endpoint.log" ] || fail "unreadable max-time config created a backend endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "unreadable max-time config typed an OMP launch command"

  id=$(profile_id profile-claude-ignores-omp-max-time-z8oa)
  rec=$(make_spawn_case profile-claude-ignores-omp-max-time claude "$id")
  read_case_record "$rec"
  printf 'invalid-for-omp\n' > "$HOME_DIR/config/omp-max-time"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "non-OMP spawn should ignore config/omp-max-time"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--max-time" "OMP max-time config leaked into another harness"
  pass "OMP max-time defaults to 3h, supports override and off, fails closed, and stays OMP-only"
}

test_omp_broker_env_uses_mode_600_file_without_exposing_bearer() {
  local rec id out status launch token_file
  id=$(profile_id profile-omp-broker-z8ob)
  rec=$(make_spawn_case profile-omp-broker omp "$id")
  read_case_record "$rec"
  token_file="$CASE_DIR/omp-auth-broker.token"
  printf '%s' 'dummy_broker_token_123' > "$token_file"
  chmod 600 "$token_file"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  export FM_TEST_OMP_AUTH_BROKER_URL=http://127.0.0.1:8765
  export FM_TEST_OMP_AUTH_BROKER_TOKEN_FILE="$token_file"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort high)
  status=$?
  expect_code 0 "$status" "OMP spawn with a mode-600 broker token file should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "OMP_AUTH_BROKER_URL=" "OMP launch did not receive the pod-loopback broker URL"
  assert_contains "$launch" "http://127.0.0.1:8765" "OMP launch did not retain the broker URL"
  assert_contains "$launch" "\$(cat" "OMP launch did not defer bearer-file expansion to its Bash-owned command wrapper"
  assert_contains "$launch" "FM_OMP_AUTH_BROKER_TOKEN_FILE=" "OMP launch did not retain the safe bearer-file path for descendant OMP crews"
  assert_contains "$launch" "$token_file" "OMP launch did not retain the safe bearer-file path"
  assert_not_contains "$launch" 'dummy_broker_token_123' \
    "OMP bearer bytes leaked into the literal backend launch command"

  id=$(profile_id profile-omp-broker-mode-z8obm)
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  chmod 644 "$token_file"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort high)
  status=$?
  expect_code 1 "$status" "OMP spawn must refuse a broker token file broader than mode 0600"
  assert_contains "$out" 'OMP auth-broker token file must have mode 0600' \
    "unsafe OMP broker token refusal did not name the required mode"
  [ ! -s "$LAUNCH_LOG" ] || fail "unsafe OMP broker token mode typed a backend launch command"

  unset FM_TEST_OMP_ACK FM_TEST_OMP_AUTH_BROKER_URL FM_TEST_OMP_AUTH_BROKER_TOKEN_FILE
  pass "OMP broker launch env reads a mode-600 file inside the pane and never exposes bearer bytes"
}

test_secondmate_descendant_omp_inherits_complete_broker_pair() {
  local rec id child sm out status launch token_file tasktmp
  id=$(profile_id profile-codex-secondmate-broker-z8obs)
  child=$(profile_id profile-omp-descendant-broker-z8obd)
  rec=$(make_spawn_case profile-secondmate-descendant-broker codex "$id")
  read_case_record "$rec"
  printf '%s\n' codex > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  mkdir -p "$sm/config" "$sm/data/$child" "$sm/projects" "$sm/state"
  printf 'brief for %s\n' "$child" > "$sm/data/$child/brief.md"
  printf 'off\n' > "$sm/config/herdr-presentation-spaces"
  touch "$sm/state/.last-watcher-beat"
  token_file="$CASE_DIR/omp-auth-broker.token"
  printf '%s' 'dummy_descendant_broker_token_456' > "$token_file"
  chmod 600 "$token_file"
  export FM_TEST_OMP_AUTH_BROKER_URL=http://127.0.0.1:8765
  export FM_TEST_OMP_AUTH_BROKER_TOKEN_FILE="$token_file"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "Codex secondmate spawn with the safe broker pair should succeed"
  launch=$(tail -n 1 "$LAUNCH_LOG")
  assert_contains "$launch" "FM_OMP_AUTH_BROKER_URL='http://127.0.0.1:8765'" \
    "non-OMP secondmate did not inherit the broker URL"
  assert_contains "$launch" "FM_OMP_AUTH_BROKER_TOKEN_FILE='$token_file'" \
    "non-OMP secondmate did not inherit the broker token-file path"
  assert_not_contains "$launch" 'dummy_descendant_broker_token_456' \
    "secondmate launch exposed broker bearer bytes"

  FM_FAKE_DESCENDANT_SPAWN="$SPAWN" FM_FAKE_DESCENDANT_ID="$child" \
    FM_FAKE_DESCENDANT_PROJECT="$PROJ_DIR" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$WT_DIR" TMUX='fake,1,0' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_ENDPOINT_LOG="$CASE_DIR/endpoint.log" FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    FM_FAKE_OMP_ACK="$sm/state/$child.omp-started" FM_FAKE_OMP_NO_PREWALK=1 \
    HOME="$HOME" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" >/dev/null
  status=$?
  expect_code 0 "$status" "secondmate should launch its OMP descendant with broker auth"
  launch=$(tail -n 1 "$LAUNCH_LOG")
  assert_contains "$launch" "OMP_AUTH_BROKER_URL=" "descendant OMP launch did not receive the broker client URL"
  assert_contains "$launch" "http://127.0.0.1:8765" "descendant OMP launch did not retain the broker URL"
  assert_contains "$launch" "\$(cat" "descendant OMP launch did not defer bearer expansion to its Bash-owned command wrapper"
  assert_contains "$launch" "FM_OMP_AUTH_BROKER_TOKEN_FILE=" "descendant OMP launch did not retain the broker token-file identity"
  assert_contains "$launch" "$token_file" "descendant OMP launch did not retain the broker token-file path"
  assert_not_contains "$launch" 'dummy_descendant_broker_token_456' \
    "descendant OMP launch exposed broker bearer bytes"

  tasktmp=$(sed -n 's/^tasktmp=//p' "$sm/state/$child.meta")
  case "$tasktmp" in /tmp/fm-profile-*) rm -rf "$tasktmp" ;; esac
  unset FM_TEST_OMP_AUTH_BROKER_URL FM_TEST_OMP_AUTH_BROKER_TOKEN_FILE
  pass "secondmate-launched OMP descendants inherit the complete broker pair without bearer exposure"
}

test_omp_prewalk_threads_native_target_and_metadata() {
  local rec id out status launch target
  id=$(profile_id profile-omp-prewalk-z8op)
  rec=$(make_spawn_case profile-omp-prewalk omp "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  target=openai-codex/gpt-5.6-luna:xhigh

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --harness omp --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  expect_code 0 "$status" "OMP spawn with a valid native Prewalk target should succeed"
  assert_contains "$out" "spawned $id harness=omp kind=ship" \
    "OMP Prewalk spawn did not preserve exact OMP identity"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--prewalk" "OMP launch did not enable native Prewalk"
  assert_contains "$launch" "$target" "OMP launch did not retain the exact native Prewalk target"
  assert_grep "prewalk_into=$target" "$HOME_DIR/state/$id.meta" \
    "OMP Prewalk metadata did not record the exact effort-qualified target"
  unset FM_TEST_OMP_ACK
  pass "OMP profiles opt into native Prewalk with an effort-qualified target"
}

test_omp_unusable_prewalk_target_keeps_full_starting_model_trajectory() {
  local rec id out status launch target
  id=$(profile_id profile-omp-prewalk-invalid-z8oq)
  rec=$(make_spawn_case profile-omp-prewalk-invalid omp "$id")
  read_case_record "$rec"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  target=openai-codex/not-listed:xhigh

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  expect_code 0 "$status" "an unusable Prewalk target should keep the full starting-model launch"
  assert_contains "$out" "warning: OMP prewalk target '$target' will not be used" \
    "unusable OMP Prewalk target did not produce a clear warning"
  assert_contains "$out" "continuing the full trajectory on starting model 'openai-codex/gpt-5.6-luna' without prewalk" \
    "unusable OMP Prewalk target did not explain the safe full-trajectory fallback"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model" "unusable Prewalk target did not preserve the frontier starting model"
  assert_contains "$launch" "--thinking" "unusable Prewalk target did not preserve the requested thinking level"
  assert_contains "$launch" "--no-prewalk" "unusable Prewalk target did not disable native Prewalk"
  assert_not_contains "$launch" "--prewalk --prewalk-into" \
    "unusable OMP target still enabled native Prewalk"
  assert_no_grep '^prewalk_into=' "$HOME_DIR/state/$id.meta" \
    "unusable OMP target was recorded as an enabled Prewalk target"
  unset FM_TEST_OMP_ACK
  pass "unusable OMP Prewalk targets warn and keep the full starting-model trajectory"
}

test_omp_prewalk_accepts_colon_selector_from_launch_worktree_catalog() {
  local rec id out status launch target
  id=$(profile_id profile-omp-prewalk-colon-z8ot)
  rec=$(make_spawn_case profile-omp-prewalk-colon omp "$id")
  read_case_record "$rec"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  export FM_TEST_OMP_CATALOG_DIR="$WT_DIR"
  target=ollama/gemma3:12b

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  expect_code 0 "$status" "a colon-bearing selector from the launch worktree catalog should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--prewalk" "OMP split a native colon-bearing selector as an effort suffix"
  assert_contains "$launch" "$target" "OMP launch lost a native colon-bearing selector"
  assert_grep "prewalk_into=$target" "$HOME_DIR/state/$id.meta" \
    "OMP did not record the worktree-scoped colon-bearing selector"
  unset FM_TEST_OMP_CATALOG_DIR FM_TEST_OMP_ACK
  pass "OMP validates native colon selectors in the launch worktree catalog"
}

test_omp_prewalk_fallback_omits_unsupported_disable_flag() {
  local rec id out status launch target
  id=$(profile_id profile-omp-prewalk-no-disable-z8ou)
  rec=$(make_spawn_case profile-omp-prewalk-no-disable omp "$id")
  read_case_record "$rec"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  export FM_TEST_OMP_NO_PREWALK=0
  target=openai-codex/not-listed:xhigh

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  expect_code 0 "$status" "fallback should not emit an unsupported native disable flag"
  assert_contains "$out" "model 'openai-codex/not-listed' is not listed by OMP" \
    "invalid target did not produce a clear fallback warning"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--prewalk" \
    "fallback emitted a Prewalk flag that the selected OMP executable does not support"
  assert_no_grep '^prewalk_into=' "$HOME_DIR/state/$id.meta" \
    "unsupported native flags were recorded as an enabled Prewalk target"
  unset FM_TEST_OMP_NO_PREWALK FM_TEST_OMP_ACK
  pass "OMP fallback omits unsupported native disable flags"
}

test_omp_valid_prewalk_does_not_require_disable_flag() {
  local rec id out status launch target
  id=$(profile_id profile-omp-prewalk-enable-only-z8ov)
  rec=$(make_spawn_case profile-omp-prewalk-enable-only omp "$id")
  read_case_record "$rec"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
  export FM_TEST_OMP_NO_PREWALK=0
  export FM_TEST_OMP_PREWALK_ENABLED=true
  target=openai-codex/gpt-5.6-luna:xhigh

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  expect_code 0 "$status" "valid native Prewalk should not require --no-prewalk support"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--prewalk" "valid native Prewalk was suppressed because --no-prewalk was unavailable"
  assert_contains "$launch" "$target" "valid native Prewalk lost its target"
  unset FM_TEST_OMP_PREWALK_ENABLED FM_TEST_OMP_NO_PREWALK FM_TEST_OMP_ACK
  pass "valid OMP Prewalk does not require its disable flag"
}

test_omp_unsafe_fallback_refuses_before_endpoint() {
  local rec id out status endpoint_log treehouse_log target
  id=$(profile_id profile-omp-prewalk-unsafe-z8ow)
  rec=$(make_spawn_case profile-omp-prewalk-unsafe omp "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoint.log"
  treehouse_log="$CASE_DIR/treehouse.log"
  export FM_TEST_OMP_NO_PREWALK=0
  export FM_TEST_OMP_PREWALK_ENABLED=true
  export FM_TEST_OMP_CATALOG_DIR="$WT_DIR"
  target=openai-codex/gpt-5.6-luna:xhigh

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  expect_code 1 "$status" "unsafe fallback should refuse before endpoint creation"
  assert_contains "$out" "use an OMP build with --no-prewalk or set prewalk.enabled=false" \
    "unsafe fallback refusal was not actionable"
  [ ! -s "$endpoint_log" ] || fail "unsafe fallback created an endpoint before refusing"
  assert_grep "get --lease --lease-holder fm-$id" "$treehouse_log" \
    "unsafe fallback did not validate from the authoritative leased worktree"
  assert_grep "$PROJ_DIR|return $WT_DIR" "$treehouse_log" \
    "unsafe fallback did not return its pre-endpoint worktree lease"
  unset FM_TEST_OMP_CATALOG_DIR FM_TEST_OMP_PREWALK_ENABLED FM_TEST_OMP_NO_PREWALK
  pass "unsafe OMP fallback refuses before endpoint creation"
}

test_omp_prewalk_live_runtime_refusal_preserves_lease() {
  local rec id out status treehouse_log target exclude
  id=$(profile_id profile-omp-prewalk-live-runtime-z8owb)
  rec=$(make_spawn_case profile-omp-prewalk-live-runtime omp "$id")
  read_case_record "$rec"
  treehouse_log="$CASE_DIR/treehouse.log"
  target=openai-codex/gpt-5.6-luna:xhigh
  exclude=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  printf '/state/\n' >> "$exclude"
  mkdir -p "$WT_DIR/state"
  printf '%s\n' "$$" > "$WT_DIR/state/.lock"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  expect_code 1 "$status" "live OMP runtime ownership should refuse Prewalk reuse"
  assert_contains "$out" 'previous OMP session is still live' \
    "Prewalk reuse did not report the live prior occupant"
  assert_no_grep 'return' "$treehouse_log" \
    "Prewalk runtime refusal returned a lease with a live occupant"
  assert_present "$WT_DIR/state/.lock" "Prewalk runtime refusal removed the live occupant marker"
  pass "Prewalk preserves a lease when prior occupant liveness remains"
}

test_omp_prewalk_premetadata_failure_cleans_endpoint_and_lease() {
  local rec id out status endpoint_log treehouse_log target tasktmp
  id=$(profile_id profile-omp-prewalk-premeta-z8ox)
  rec=$(make_spawn_case profile-omp-prewalk-premeta omp "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoint.log"
  treehouse_log="$CASE_DIR/treehouse.log"
  target=openai-codex/gpt-5.6-luna:xhigh
  tasktmp="/tmp/fm-$id"
  export FM_TEST_MKDIR_FAIL_PATH="$tasktmp/gotmp"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  unset FM_TEST_MKDIR_FAIL_PATH
  expect_code 1 "$status" "a post-endpoint Prewalk setup failure should abort"
  assert_contains "$out" "injected mkdir failure for $tasktmp/gotmp" \
    "post-endpoint Prewalk setup did not reach the expected refusal"
  assert_grep 'kill-window' "$endpoint_log" \
    "post-endpoint Prewalk failure left its owned endpoint alive"
  assert_grep "$PROJ_DIR|return --force $WT_DIR" "$treehouse_log" \
    "post-endpoint Prewalk failure did not return its unchanged worktree lease"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "post-endpoint Prewalk failure published durable metadata"
  assert_absent "$tasktmp" \
    "post-endpoint Prewalk failure left its rejected task temp root"
  pass "Prewalk setup failures clean their endpoint and worktree lease"
}

test_omp_prewalk_ambiguous_herdr_creation_preserves_lease() {
  local rec id out status endpoint_log treehouse_log target
  id=$(profile_id profile-omp-prewalk-herdr-partial-z8oy)
  rec=$(make_spawn_case profile-omp-prewalk-herdr-partial omp "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoint.log"
  treehouse_log="$CASE_DIR/treehouse.log"
  target=openai-codex/gpt-5.6-luna:xhigh
  export FM_TEST_HERDR_PARTIAL_CREATE=1

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backend herdr --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  unset FM_TEST_HERDR_PARTIAL_CREATE
  expect_code 1 "$status" "ambiguous Herdr endpoint creation should abort"
  assert_contains "$out" "could not parse tab/pane id from herdr tab create output" \
    "ambiguous Herdr creation did not report its malformed ownership response"
  assert_contains "$out" "preserving its leased worktree because backend endpoint creation was ambiguous" \
    "ambiguous Herdr creation did not explain why its worktree lease was preserved"
  assert_grep 'tab create' "$endpoint_log" \
    "ambiguous Herdr fixture did not reach endpoint creation"
  assert_no_grep 'return' "$treehouse_log" \
    "ambiguous Herdr creation returned a worktree that may still have a live endpoint"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "ambiguous Herdr creation published durable task metadata"
  pass "ambiguous Herdr creation preserves its Prewalk lease"
}

test_ordinary_herdr_partial_create_preserves_response_known_pane() {
  local rec id out status endpoint_log
  id=$(profile_id profile-ordinary-herdr-partial-z8oyb)
  rec=$(make_spawn_case profile-ordinary-herdr-partial claude "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoint.log"
  export FM_TEST_HERDR_PARTIAL_CREATE=pane-only

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backend herdr)
  status=$?
  unset FM_TEST_HERDR_PARTIAL_CREATE
  expect_code 1 "$status" "ordinary Herdr partial creation should retain its prior failure"
  assert_contains "$out" "could not parse tab/pane id from herdr tab create output" \
    "ordinary Herdr partial creation did not report its malformed response"
  assert_no_grep 'pane close w1:p2' "$endpoint_log" \
    "ordinary Herdr partial creation transactionally removed its response-known pane"
  pass "ordinary Herdr partial creation preserves its response-known pane"
}

test_omp_prewalk_partial_create_cleans_response_known_pane() {
  local rec id out status endpoint_log treehouse_log target
  id=$(profile_id profile-prewalk-herdr-known-pane-z8oyc)
  rec=$(make_spawn_case profile-prewalk-herdr-known-pane omp "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoint.log"
  treehouse_log="$CASE_DIR/treehouse.log"
  target=openai-codex/gpt-5.6-luna:xhigh
  export FM_TEST_HERDR_PARTIAL_CREATE=pane-only

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backend herdr --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  unset FM_TEST_HERDR_PARTIAL_CREATE
  expect_code 1 "$status" "Prewalk Herdr partial creation should abort after cleanup"
  assert_contains "$out" "could not parse tab/pane id from herdr tab create output" \
    "Prewalk Herdr partial creation did not report its malformed response"
  assert_grep 'pane close w1:p2' "$endpoint_log" \
    "Prewalk Herdr partial creation did not remove its response-known pane"
  assert_grep "$PROJ_DIR|return $WT_DIR" "$treehouse_log" \
    "Prewalk Herdr partial creation did not return its lease after confirmed endpoint cleanup"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "Prewalk Herdr partial creation published durable metadata"
  pass "Prewalk Herdr partial creation cleans its response-known pane"
}

test_omp_prewalk_ambiguous_herdr_projection_preserves_lease() {
  local rec id out status endpoint_log treehouse_log target
  id=$(profile_id profile-omp-prewalk-herdr-projection-z8oz)
  rec=$(make_spawn_case profile-omp-prewalk-herdr-projection omp "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoint.log"
  treehouse_log="$CASE_DIR/treehouse.log"
  target=openai-codex/gpt-5.6-luna:xhigh
  printf 'on\n' > "$HOME_DIR/config/herdr-presentation-spaces"
  export FM_TEST_HERDR_PARTIAL_PROJECTION=1

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backend herdr --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  unset FM_TEST_HERDR_PARTIAL_PROJECTION
  expect_code 1 "$status" "ambiguous Herdr projection creation should abort"
  assert_contains "$out" "workspace create returned incomplete IDs" \
    "ambiguous Herdr projection did not report its malformed ownership response"
  assert_contains "$out" "preserving its leased worktree because backend endpoint creation was ambiguous" \
    "ambiguous Herdr projection did not explain why its worktree lease was preserved"
  assert_grep 'workspace create' "$endpoint_log" \
    "ambiguous Herdr projection fixture did not reach endpoint creation"
  assert_no_grep 'return' "$treehouse_log" \
    "ambiguous Herdr projection returned a worktree that may still have a live endpoint"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "ambiguous Herdr projection published durable task metadata"
  pass "ambiguous Herdr projection preserves its Prewalk lease"
}

write_ambiguous_reclaim_fixture() {
  local home=$1 id=$2 token=$3 workspace_label=$4 task_label=$5
  printf 'on\n' > "$home/config/herdr-presentation-spaces"
  {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
    printf 'home=%s\n' "$home"
    printf 'session=default\n'
    printf 'workspace_id=w2\n'
    printf 'tab_id=w2:t2\n'
    printf 'pane_id=w2:p2\n'
    printf 'parent_workspace_id=w1\n'
    printf 'parent_label=firstmate\n'
    printf 'workspace_label=%s\n' "$workspace_label"
    printf 'task_label=%s\n' "$task_label"
  } > "$home/state/$id.herdr-presentation"
  {
    printf 'window=default:w2:p2\n'
    printf 'harness=claude\n'
    printf 'backend=herdr\n'
    printf 'herdr_session=default\n'
    printf 'herdr_workspace_id=w2\n'
    printf 'herdr_tab_id=w2:t2\n'
    printf 'herdr_pane_id=w2:p2\n'
  } > "$home/state/$id.meta"
}

test_ordinary_herdr_ambiguous_reclaim_keeps_flat_fallback() {
  local rec id out status endpoint_log token workspace_label task_label
  id=$(profile_id profile-ordinary-herdr-reclaim-z8pa)
  rec=$(make_spawn_case profile-ordinary-herdr-reclaim claude "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoint.log"
  token=0123456789abcdefghijkl
  workspace_label="└ $id · p:$token"
  task_label="fm-$id"
  write_ambiguous_reclaim_fixture "$HOME_DIR" "$id" "$token" "$workspace_label" "$task_label"
  export FM_TEST_HERDR_AMBIGUOUS_RECLAIM=1
  export FM_TEST_HERDR_RECLAIM_WORKSPACE_LABEL="$workspace_label"
  export FM_TEST_HERDR_RECLAIM_TASK_LABEL="$task_label"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backend herdr)
  status=$?
  unset FM_TEST_HERDR_AMBIGUOUS_RECLAIM
  unset FM_TEST_HERDR_RECLAIM_WORKSPACE_LABEL
  unset FM_TEST_HERDR_RECLAIM_TASK_LABEL
  expect_code 0 "$status" "ordinary ambiguous Herdr reclaim should retain flat fallback"
  assert_contains "$out" "spawned $id harness=claude" \
    "ordinary ambiguous Herdr reclaim did not continue into a normal launch"
  [ "$(grep -c '^tab create$' "$endpoint_log")" = 2 ] \
    || fail "ordinary ambiguous Herdr reclaim did not attempt replacement then flat spawn"
  assert_grep 'herdr_workspace_id=w1' "$HOME_DIR/state/$id.meta" \
    "ordinary ambiguous Herdr reclaim did not land in the flat home workspace"
  assert_no_grep 'prewalk_into=' "$HOME_DIR/state/$id.meta" \
    "ordinary ambiguous Herdr reclaim unexpectedly enabled Prewalk"
  pass "ordinary ambiguous Herdr reclaim retains flat fallback"
}

test_non_omp_prewalk_refuses_without_changing_normal_claude_launch() {
  local rec bad_id normal_id out status launch endpoint_log target
  bad_id=$(profile_id profile-claude-prewalk-bad-z8or)
  normal_id=$(profile_id profile-claude-prewalk-normal-z8os)
  rec=$(make_spawn_case profile-claude-prewalk claude "$bad_id" "$normal_id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  endpoint_log="$CASE_DIR/endpoint.log"
  target=openai-codex/gpt-5.6-luna:xhigh

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$bad_id" "$PROJ_DIR" --harness claude --model sonnet --effort high --prewalk-into "$target")
  status=$?
  expect_code 1 "$status" "non-OMP harness with --prewalk-into should refuse"
  assert_contains "$out" "--prewalk-into is supported only with harness=omp (resolved harness=claude)" \
    "non-OMP refusal did not name the OMP-only contract"
  assert_absent "$HOME_DIR/state/$bad_id.meta" "non-OMP Prewalk refusal wrote task metadata"
  [ ! -s "$endpoint_log" ] || fail "non-OMP Prewalk refusal created a backend endpoint"
  [ ! -s "$LAUNCH_LOG" ] || fail "non-OMP Prewalk refusal typed a launch command"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$normal_id" "$PROJ_DIR" --harness claude --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "ordinary Claude launch should remain unaffected"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "ordinary Claude launch changed after adding the OMP-only profile axis"
  assert_not_contains "$launch" "--prewalk" "ordinary Claude launch received OMP Prewalk flags"
  assert_no_grep '^prewalk_into=' "$HOME_DIR/state/$normal_id.meta" \
    "ordinary Claude metadata gained an OMP-only Prewalk field"
  pass "non-OMP Prewalk refuses while ordinary Claude profile launches remain unchanged"
}

test_omp_herdr_worker_and_scout_launch_with_exact_identity_and_ack() {
  local kind rec id out status launch
  local -a dispatch_args
  for kind in worker scout; do
    id=$(profile_id "profile-omp-herdr-$kind-z8ph")
    rec=$(make_spawn_case "profile-omp-herdr-$kind" omp "$id")
    read_case_record "$rec"
    export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"
    dispatch_args=(--mode no-mistakes --yolo off)
    [ "$kind" != scout ] || dispatch_args=(--scout)

    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --backend herdr --model openai-codex/gpt-5.6-luna --effort low "${dispatch_args[@]}")
    status=$?
    expect_code 0 "$status" "OMP Herdr $kind launch should succeed after turn-start acknowledgement"
    assert_contains "$out" "spawned $id harness=omp" "OMP Herdr $kind launch lost exact runtime identity"
    assert_grep 'backend=herdr' "$HOME_DIR/state/$id.meta" "OMP Herdr $kind metadata lost its backend"
    assert_grep 'herdr_session=default' "$HOME_DIR/state/$id.meta" "OMP Herdr $kind metadata lost its named session"
    assert_grep 'herdr_pane_id=w1:p2' "$HOME_DIR/state/$id.meta" "OMP Herdr $kind metadata lost its exact pane"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "GOTMPDIR=" \
      "OMP Herdr $kind launch did not bind GOTMPDIR to its agent command"
    assert_contains "$launch" "/bin/bash -c" "OMP Herdr $kind launch did not use its Bash-owned command wrapper"
    # shellcheck disable=SC2016 # The literal expansion must never reach the pane shell.
    assert_not_contains "$launch" '${PATH:+' "OMP Herdr $kind launch exposed POSIX parameter expansion to the pane shell"
    assert_contains "$launch" "$(cd "$FAKEBIN_DIR" && pwd -P)/omp" \
      "OMP Herdr $kind launch did not retain its canonical executable"
    assert_contains "$launch" "--session-dir" "OMP Herdr $kind launch omitted its isolated session directory"
    assert_contains "$launch" "$HOME_DIR/state/$id.omp-ext.ts" "OMP Herdr $kind launch omitted its acknowledgement extension"
    unset FM_TEST_OMP_ACK
  done
  pass "OMP Herdr workers and scouts preserve exact identity, isolated sessions, metadata, and launch acknowledgement"
}

test_herdr_launch_refuses_after_nested_shell_timeout() {
  local rec id out status
  id=$(profile_id profile-herdr-required-export-z8pi)
  rec=$(make_spawn_case profile-herdr-required-export claude "$id")
  read_case_record "$rec"
  export FM_TEST_HERDR_REFUSE_NESTED_SHELL=1
  export FM_TEST_HERDR_IDLE_SHELL_PROOF_POLLS=1

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backend herdr)
  status=$?
  unset FM_TEST_HERDR_REFUSE_NESTED_SHELL
  unset FM_TEST_HERDR_IDLE_SHELL_PROOF_POLLS
  expect_code 1 "$status" "Herdr spawn should refuse when the nested worktree shell is not provably idle"
  assert_contains "$out" "launch pane did not reach a proven idle shell" \
    "Herdr nested-shell timeout did not identify the refused atomic launch"
  assert_contains "$(cat "$LAUNCH_LOG")" "fm-treehouse-get.sh" \
    "Herdr readiness fixture did not enter its nested Treehouse shell"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "claude --dangerously-skip-permissions" \
    "Herdr spawn launched the agent without a proven idle nested shell"
  pass "Herdr atomic launch refuses when the nested worktree shell never proves idle"
}

test_omp_refuses_unverified_backends_before_endpoint_creation() {
  local backend rec id out status endpoint_log
  for backend in zellij orca cmux; do
    id=$(profile_id "profile-omp-unverified-$backend-z8pu")
    rec=$(make_spawn_case "profile-omp-unverified-$backend" omp "$id")
    read_case_record "$rec"
    endpoint_log="$CASE_DIR/endpoint.log"
    : > "$endpoint_log"

    out=$(FM_FAKE_ENDPOINT_LOG="$endpoint_log" \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --backend "$backend")
    status=$?
    expect_code 1 "$status" "OMP should refuse unverified backend $backend"
    assert_contains "$out" "verified only on backend=tmux or backend=herdr" \
      "OMP $backend refusal did not name the supported backend allowlist"
    assert_absent "$HOME_DIR/state/$id.meta" "OMP $backend refusal wrote task metadata"
    [ ! -s "$endpoint_log" ] || fail "OMP $backend refusal created an endpoint"
    [ ! -s "$LAUNCH_LOG" ] || fail "OMP $backend refusal typed a launch command"
  done
  pass "OMP refuses every backend outside the verified tmux/herdr allowlist before endpoint creation"
}

test_omp_scout_uses_external_turn_extension() {
  local rec id out status
  id=$(profile_id profile-omp-scout-z8p)
  rec=$(make_spawn_case profile-omp-scout omp "$id")
  read_case_record "$rec"
  export FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "OMP scout spawn should succeed"
  assert_contains "$out" "spawned $id harness=omp kind=scout" "OMP scout did not preserve exact identity"
  assert_grep 'kind=scout' "$HOME_DIR/state/$id.meta" "OMP scout metadata lost delivery semantics"
  assert_present "$HOME_DIR/state/$id.omp-ext.ts" "OMP scout did not receive the external turn extension"
  rm -f "$HOME_DIR/state/$id.omp-ready" "$HOME_DIR/state/$id.omp-started" "$HOME_DIR/state/$id.turn-ended"
  PLUGIN="$HOME_DIR/state/$id.omp-ext.ts" READY="$HOME_DIR/state/$id.omp-ready" \
    STARTED="$HOME_DIR/state/$id.omp-started" TURNENDED="$HOME_DIR/state/$id.turn-ended" \
    node --input-type=module <<'JS'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
const handlers = new Map();
const extension = await import(pathToFileURL(process.env.PLUGIN).href);
extension.default({ on(name, handler) { handlers.set(name, handler); } });
await handlers.get("session_start")?.();
await handlers.get("turn_start")?.();
await handlers.get("turn_end")?.();
for (let i = 0; i < 50 && (!existsSync(process.env.READY) || !existsSync(process.env.STARTED) || !existsSync(process.env.TURNENDED)); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.READY)) throw new Error("OMP session_start did not report readiness");
if (!existsSync(process.env.STARTED)) throw new Error("OMP turn_start did not acknowledge launch");
if (!existsSync(process.env.TURNENDED)) throw new Error("OMP turn_end did not publish completion");
JS
  unset FM_TEST_OMP_ACK
  pass "OMP scouts retain scout semantics and external per-turn notification"
}

test_omp_whitespace_identity_paths_refuse_before_endpoint() {
  local mode rec id out status spaced path
  for mode in omp bun; do
    id=$(profile_id "omp-space-$mode")
    rec=$(make_spawn_case "omp-space-$mode" omp "$id")
    read_case_record "$rec"
    spaced="$CASE_DIR/$mode identity"
    mkdir -p "$spaced"
    cp "$FAKEBIN_DIR/$mode" "$spaced/$mode"
    chmod +x "$spaced/$mode"
    path="$spaced:$FAKEBIN_DIR"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$path" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "OMP should refuse a whitespace-bearing $mode identity"
    assert_contains "$out" 'neither a Bun script nor a standalone native executable' \
      "OMP whitespace-bearing $mode refusal was not actionable"
    [ ! -s "$CASE_DIR/endpoint.log" ] || fail "OMP whitespace-bearing $mode identity created an endpoint"
    [ ! -s "$LAUNCH_LOG" ] || fail "OMP whitespace-bearing $mode identity typed a launch command"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "OMP whitespace-bearing $mode identity published metadata"
  done
  pass "OMP and Bun whitespace-bearing identity paths refuse before endpoint creation"
}

test_omp_missing_binary_or_capability_refuses_before_endpoint_and_metadata() {
  local mode rec id out status endpoint_log
  for mode in missing-binary missing-thinking missing-max-time existing-artifact; do
    id=$(profile_id "profile-omp-$mode-z8q")
    rec=$(make_spawn_case "profile-omp-$mode" omp "$id")
    read_case_record "$rec"
    endpoint_log="$CASE_DIR/endpoint.log"
    : > "$endpoint_log"
    case "$mode" in
      missing-binary) rm -f "$FAKEBIN_DIR/omp" ;;
      missing-thinking) sed -i '/thinking/d' "$FAKEBIN_DIR/omp" ;;
      missing-max-time) sed -i "s/ '--max-time=<value>'//" "$FAKEBIN_DIR/omp" ;;
      existing-artifact) : > "$HOME_DIR/state/$id.status" ;;
    esac

    out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      FM_FAKE_ENDPOINT_LOG="$endpoint_log" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
    status=$?
    expect_code 1 "$status" "OMP $mode should refuse before launch"
    assert_contains "$out" "omp" "OMP preflight refusal did not name the selected runtime"
    [ "$mode" != missing-max-time ] || assert_contains "$out" "--max-time=<value>" \
      "OMP max-time capability refusal did not name the missing flag"
    assert_absent "$HOME_DIR/state/$id.meta" "OMP $mode refusal wrote task metadata"
    [ ! -s "$endpoint_log" ] || fail "OMP $mode refusal created a backend endpoint"
    [ ! -s "$LAUNCH_LOG" ] || fail "OMP $mode refusal typed a launch command"
  done
  pass "OMP missing binary and capability failures occur before endpoint or metadata publication"
}

test_omp_launch_requires_observable_turn_start_acknowledgement() {
  local rec id out status endpointlog treehouselog
  id=$(profile_id profile-omp-unacked-z8r)
  rec=$(make_spawn_case profile-omp-unacked omp "$id")
  read_case_record "$rec"
  printf 'pool-local-config\n' > "$WT_DIR/treehouse.toml"

  out=$(FM_OMP_LAUNCH_ACK_POLLS=2 FM_OMP_LAUNCH_ACK_INTERVAL=0.01 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "unacknowledged OMP launch should fail"
  assert_contains "$out" "initial instruction was not acknowledged" \
    "OMP unacknowledged launch did not report its concrete postcondition"
  endpointlog="$CASE_DIR/endpoint.log"
  treehouselog="$CASE_DIR/treehouse.log"
  assert_grep 'kill-window' "$endpointlog" "OMP unacknowledged launch left its owned endpoint alive"
  assert_grep "return --force $WT_DIR" "$treehouselog" "OMP unacknowledged launch did not return its unchanged worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "OMP unacknowledged launch left owned metadata"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "OMP unacknowledged launch left its extension"
  assert_absent "/tmp/fm-$id" "OMP unacknowledged launch left its task temp root"
  pass "OMP spawn requires acknowledgement and returns a predicate-clean launch"
}

test_omp_herdr_unacked_launch_cleans_owned_endpoint_worktree_and_artifacts() {
  local rec id out status endpointlog treehouselog
  id=$(profile_id profile-omp-herdr-unacked-z8rh)
  rec=$(make_spawn_case profile-omp-herdr-unacked omp "$id")
  read_case_record "$rec"

  out=$(FM_OMP_LAUNCH_ACK_POLLS=2 FM_OMP_LAUNCH_ACK_INTERVAL=0.01 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --backend herdr)
  status=$?
  expect_code 1 "$status" "unacknowledged OMP Herdr launch should fail"
  assert_contains "$out" "initial instruction was not acknowledged" \
    "OMP Herdr unacknowledged launch did not reach the observable acknowledgement gate"
  endpointlog="$CASE_DIR/endpoint.log"
  treehouselog="$CASE_DIR/treehouse.log"
  assert_grep 'pane close w1:p2' "$endpointlog" "OMP Herdr unacknowledged launch left its owned endpoint alive"
  assert_grep "return --force $WT_DIR" "$treehouselog" "OMP Herdr unacknowledged launch did not return its unchanged worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "OMP Herdr unacknowledged launch left owned metadata"
  assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "OMP Herdr unacknowledged launch left its extension"
  assert_absent "/tmp/fm-$id" "OMP Herdr unacknowledged launch left its task temp root"
  pass "OMP Herdr spawn failure cleans its proven endpoint, unchanged worktree, and task artifacts"
}

test_omp_herdr_refused_close_preserves_worktree_and_artifacts() {
  local rec id out status endpointlog treehouselog
  id=$(profile_id profile-omp-herdr-refused-z8rr)
  rec=$(make_spawn_case profile-omp-herdr-refused omp "$id")
  read_case_record "$rec"

  out=$(FM_OMP_LAUNCH_ACK_POLLS=2 FM_OMP_LAUNCH_ACK_INTERVAL=0.01 \
    FM_TEST_HERDR_REFUSE_CLOSE=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --backend herdr)
  status=$?
  expect_code 1 "$status" "unacknowledged OMP Herdr launch should fail"
  assert_contains "$out" "could not confirm its owned endpoint stopped" \
    "OMP Herdr cleanup trusted a refused pane close as a stopped endpoint"
  endpointlog="$CASE_DIR/endpoint.log"
  treehouselog="$CASE_DIR/treehouse.log"
  assert_grep 'pane close w1:p2' "$endpointlog" "OMP Herdr cleanup never attempted its owned close"
  assert_no_grep 'return --force' "$treehouselog" \
    "OMP Herdr cleanup returned the worktree without a confirmed endpoint stop"
  assert_present "$HOME_DIR/state/$id.meta" "OMP Herdr cleanup deleted metadata for a still-live endpoint"
  assert_present "$HOME_DIR/state/$id.omp-ext.ts" "OMP Herdr cleanup deleted the extension for a still-live endpoint"
  assert_present "/tmp/fm-$id" "OMP Herdr cleanup deleted the task temp root for a still-live endpoint"
  pass "OMP Herdr cleanup preserves the worktree and task artifacts when its close is refused"
}

test_omp_ack_cleanup_preserves_artifacts_when_ownership_changes() {
  local rec id out status endpointlog treehouselog
  id=$(profile_id profile-omp-unacked-owner-z8s)
  rec=$(make_spawn_case profile-omp-unacked-owner omp "$id")
  read_case_record "$rec"

  out=$(FM_OMP_LAUNCH_ACK_POLLS=2 FM_OMP_LAUNCH_ACK_INTERVAL=0.01 \
    FM_TEST_OMP_META_TAMPER="$HOME_DIR/state/$id.meta" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ownership-changed OMP launch should fail"
  assert_contains "$out" "could not prove ownership" \
    "OMP ownership-changed abort did not explain why cleanup was refused"
  endpointlog="$CASE_DIR/endpoint.log"
  treehouselog="$CASE_DIR/treehouse.log"
  assert_no_grep 'kill-window' "$endpointlog" "OMP abort killed an endpoint after metadata ownership changed"
  assert_no_grep 'return --force' "$treehouselog" "OMP abort returned a worktree after metadata ownership changed"
  [ -f "$HOME_DIR/state/$id.meta" ] || fail "OMP abort removed metadata after ownership changed"
  [ "$(cat "$HOME_DIR/state/$id.meta")" = 'window=unrelated:retry' ] \
    || fail "OMP abort did not preserve the intentionally tampered metadata"
  [ -d "/tmp/fm-$id" ] || fail "OMP abort removed task temp after ownership changed"
  [ "$(sed -n 's/^tasktmp=//p' "$HOME_DIR/state/$id.meta.test-owner")" = "/tmp/fm-$id" ] \
    || fail "the pre-tamper metadata did not prove test ownership of /tmp/fm-$id"
  rm -rf "/tmp/fm-$id"
  pass "OMP spawn abort preserves endpoint, worktree, and artifacts unless ownership is proven"
}
test_omp_refuses_tracked_project_extensions_without_opt_in() {
  local rec id out status
  id=$(profile_id profile-omp-project-ext-refuse-z20)
  rec=$(make_spawn_case profile-omp-project-ext-refuse omp "$id")
  read_case_record "$rec"
  commit_project_omp_extension "$PROJ_DIR" "$WT_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "OMP spawn with tracked project extension should refuse without opt-in"
  assert_contains "$out" ".omp/extensions/project.ts" \
    "OMP refusal did not name the tracked project extension"
  assert_contains "$out" "--allow-project-omp-extensions" \
    "OMP refusal did not explain the explicit opt-in"
  assert_no_grep 'new-window|new-session' "$CASE_DIR/endpoint.log" \
    "OMP project-extension refusal created an endpoint"
  [ ! -e "$HOME_DIR/state/$id.meta" ] \
    || fail "OMP project-extension refusal published task metadata"
  pass "OMP refuses tracked project extensions without explicit opt-in"
}

test_omp_allows_tracked_project_extensions_with_audited_opt_in() {
  local rec id out status
  id=$(profile_id profile-omp-project-ext-allow-z21)
  rec=$(make_spawn_case profile-omp-project-ext-allow omp "$id")
  read_case_record "$rec"
  commit_project_omp_extension "$PROJ_DIR" "$WT_DIR"

  out=$(FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --allow-project-omp-extensions)
  status=$?
  expect_code 0 "$status" "OMP spawn with explicit project-extension opt-in should succeed"
  assert_contains "$out" "spawned $id harness=omp" \
    "OMP opt-in spawn did not launch the worker"
  assert_grep 'allow_project_omp_extensions=1' "$HOME_DIR/state/$id.meta" \
    "OMP opt-in was not recorded in task metadata"
  pass "OMP allows tracked project extensions only with an auditable opt-in"
}

test_omp_project_without_tracked_extensions_is_unchanged() {
  local rec id out status
  id=$(profile_id profile-omp-project-ext-clean-z22)
  rec=$(make_spawn_case profile-omp-project-ext-clean omp "$id")
  read_case_record "$rec"

  out=$(FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "OMP spawn without project extensions should remain unchanged"
  assert_contains "$out" "spawned $id harness=omp" \
    "OMP spawn without project extensions did not launch the worker"
  assert_no_grep 'allow_project_omp_extensions=' "$HOME_DIR/state/$id.meta" \
    "clean OMP spawn recorded an opt-in that was not passed"
  pass "OMP projects without tracked extensions launch unchanged"
}

test_non_omp_ignores_tracked_project_extensions() {
  local rec id out status
  id=$(profile_id profile-claude-project-ext-z24)
  rec=$(make_spawn_case profile-claude-project-ext claude "$id")
  read_case_record "$rec"
  commit_project_omp_extension "$PROJ_DIR" "$WT_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "non-OMP spawn should ignore tracked OMP project extensions"
  assert_contains "$out" "spawned $id harness=claude" \
    "non-OMP spawn did not launch with a tracked OMP project extension"
  pass "non-OMP harnesses ignore tracked OMP project extensions"
}

test_omp_refuses_tracked_settings_extension_roots() {
  local rec id out status
  id=$(profile_id profile-omp-settings-ext-z25)
  rec=$(make_spawn_case profile-omp-settings-ext omp "$id")
  read_case_record "$rec"
  mkdir -p "$PROJ_DIR/.omp"
  printf '%s\n' 'export default function () {}' > "$PROJ_DIR/project-extension.ts"
  printf '%s\n' '{"extensions":["project-extension.ts"]}' > "$PROJ_DIR/.omp/settings.json"
  git -C "$PROJ_DIR" add .omp/settings.json project-extension.ts
  sync_project_commit "$PROJ_DIR" "$WT_DIR" 'add configured omp extension'

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "OMP spawn with a tracked settings extension should refuse"
  assert_contains "$out" ".omp/settings.json#extensions" \
    "OMP refusal did not name the tracked settings extension selector"
  assert_no_grep 'new-window|new-session' "$CASE_DIR/endpoint.log" \
    "OMP settings-extension refusal created an endpoint"
  pass "OMP refuses tracked settings extension roots"
}

test_omp_refuses_tracked_extension_directory_symlinks() {
  local rec id out status
  id=$(profile_id profile-omp-symlink-ext-z26)
  rec=$(make_spawn_case profile-omp-symlink-ext omp "$id")
  read_case_record "$rec"
  mkdir -p "$PROJ_DIR/.omp/extensions" "$PROJ_DIR/.omp/linked-extension"
  printf '%s\n' 'export default function () {}' > "$PROJ_DIR/.omp/linked-extension/index.ts"
  ln -s ../linked-extension "$PROJ_DIR/.omp/extensions/linked"
  git -C "$PROJ_DIR" add .omp
  sync_project_commit "$PROJ_DIR" "$WT_DIR" 'add linked omp extension'

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "OMP spawn with a tracked extension-directory symlink should refuse"
  assert_contains "$out" ".omp/extensions/linked" \
    "OMP refusal did not name the tracked extension-directory symlink"
  assert_no_grep 'new-window|new-session' "$CASE_DIR/endpoint.log" \
    "OMP linked-extension refusal created an endpoint"
  pass "OMP refuses tracked extension-directory symlinks"
}

test_omp_root_symlink_uses_shared_opt_in_boundary() {
  local rec id out status
  id=$(profile_id profile-omp-root-symlink-z30)
  rec=$(make_spawn_case profile-omp-root-symlink omp "$id")
  read_case_record "$rec"
  mkdir -p "$PROJ_DIR/omp-root/extensions"
  printf '%s\n' 'export default function () {}' > "$PROJ_DIR/omp-root/extensions/project.ts"
  ln -s omp-root "$PROJ_DIR/.omp"
  git -C "$PROJ_DIR" add .omp omp-root
  sync_project_commit "$PROJ_DIR" "$WT_DIR" 'add linked omp root'

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "OMP spawn with a tracked root symlink should refuse without opt-in"
  assert_contains "$out" "  .omp" "OMP root-symlink refusal did not name the exact offender"
  assert_contains "$out" "--allow-project-omp-extensions" \
    "OMP root-symlink refusal omitted the shared opt-in guidance"
  assert_no_grep 'new-window|new-session' "$CASE_DIR/endpoint.log" \
    "OMP root-symlink refusal created an endpoint"

  out=$(FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --allow-project-omp-extensions)
  status=$?
  expect_code 0 "$status" "OMP root symlink should launch with explicit opt-in"
  assert_grep 'allow_project_omp_extensions=1' "$HOME_DIR/state/$id.meta" \
    "OMP root-symlink opt-in was not recorded in task metadata"
  pass "OMP root symlinks use the shared opt-in boundary"
}

test_omp_ignores_hidden_direct_extension_files() {
  local rec id out status
  id=$(profile_id profile-omp-hidden-ext-z31)
  rec=$(make_spawn_case profile-omp-hidden-ext omp "$id")
  read_case_record "$rec"
  mkdir -p "$PROJ_DIR/.omp/extensions"
  printf '%s\n' 'export default function () {}' > "$PROJ_DIR/.omp/extensions/.disabled.ts"
  git -C "$PROJ_DIR" add .omp/extensions/.disabled.ts
  sync_project_commit "$PROJ_DIR" "$WT_DIR" 'add hidden inactive omp extension'

  out=$(FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "hidden direct OMP extension files should remain undiscovered"
  assert_contains "$out" "spawned $id harness=omp" \
    "hidden direct OMP extension file changed clean-project launch behavior"
  pass "OMP ignores hidden direct extension files"
}

test_omp_ignores_unusable_settings_extension_entries() {
  local rec id out status
  id=$(profile_id profile-omp-settings-object-z32)
  rec=$(make_spawn_case profile-omp-settings-object omp "$id")
  read_case_record "$rec"
  mkdir -p "$PROJ_DIR/.omp"
  printf '%s\n' '{"extensions":{"path":"project.ts"}}' > "$PROJ_DIR/.omp/settings.json"
  git -C "$PROJ_DIR" add .omp/settings.json
  sync_project_commit "$PROJ_DIR" "$WT_DIR" 'add non-array omp extensions setting'

  out=$(FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "non-array OMP extensions settings should be ignored"
  assert_contains "$out" "spawned $id harness=omp" \
    "non-array OMP extensions setting changed clean-project launch behavior"

  id=$(profile_id profile-omp-settings-filtered-z33)
  rec=$(make_spawn_case profile-omp-settings-filtered omp "$id")
  read_case_record "$rec"
  mkdir -p "$PROJ_DIR/.omp"
  printf '%s\n' '{"extensions":[null,""]}' > "$PROJ_DIR/.omp/settings.json"
  git -C "$PROJ_DIR" add .omp/settings.json
  sync_project_commit "$PROJ_DIR" "$WT_DIR" 'add unusable omp extension entries'

  out=$(FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "unusable OMP extension entries should be filtered"
  assert_contains "$out" "spawned $id harness=omp" \
    "unusable OMP extension entries changed clean-project launch behavior"
  pass "OMP ignores unusable settings extension entries"
}

test_omp_ignores_unsupported_root_extension_manifest() {
  local rec id out status
  id=$(profile_id profile-omp-root-manifest-z27)
  rec=$(make_spawn_case profile-omp-root-manifest omp "$id")
  read_case_record "$rec"
  mkdir -p "$PROJ_DIR/.omp/extensions"
  printf '%s\n' 'export default function () {}' > "$PROJ_DIR/.omp/project.ts"
  printf '%s\n' '{"omp":{"extensions":["../project.ts"]}}' > "$PROJ_DIR/.omp/extensions/package.json"
  git -C "$PROJ_DIR" add .omp
  sync_project_commit "$PROJ_DIR" "$WT_DIR" 'add unsupported root omp manifest'

  out=$(FM_TEST_OMP_ACK="$HOME_DIR/state/$id.omp-started" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "OMP root extension manifest should not be treated as executable"
  assert_contains "$out" "spawned $id harness=omp" \
    "OMP launch with only an unsupported root manifest did not remain unchanged"
  pass "OMP ignores unsupported root extension manifests"
}

test_omp_does_not_trust_copied_primary_adapter_in_projects() {
  local rec id out status
  id=$(profile_id profile-omp-copied-primary-z28)
  rec=$(make_spawn_case profile-omp-copied-primary omp "$id")
  read_case_record "$rec"
  commit_project_omp_extension "$PROJ_DIR" "$WT_DIR" "$ROOT/.omp/extensions/fm-primary-omp.ts"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ordinary OMP projects must not inherit the secondmate adapter exemption"
  assert_contains "$out" ".omp/extensions/fm-primary-omp.ts" \
    "OMP refusal did not name the copied primary adapter"
  pass "OMP restricts the primary adapter exemption to secondmate homes"
}

test_omp_secondmate_inspects_staged_live_extensions() {
  local rec id sm out status
  id=$(profile_id profile-omp-secondmate-staged-z29)
  rec=$(make_spawn_case profile-omp-secondmate-staged omp "$id")
  read_case_record "$rec"
  printf '%s\n' omp > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  mkdir -p "$sm/.omp/extensions" "$sm/state" "$sm/config" "$sm/projects"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$sm/.omp/extensions/fm-primary-omp.ts"
  cp "$ROOT/.omp/extensions/fm-fleet-hooks.ts" "$sm/.omp/extensions/fm-fleet-hooks.ts"
  git -C "$sm" init -q
  git -C "$sm" add .
  git -C "$sm" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'seed secondmate home'
  printf '%s\n' 'export default function () {}' > "$sm/.omp/extensions/staged.ts"
  git -C "$sm" add .omp/extensions/staged.ts

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 1 "$status" "OMP secondmate should inspect staged live extension content"
  assert_contains "$out" ".omp/extensions/staged.ts" \
    "OMP secondmate refusal inspected committed content instead of the live index and worktree"
  assert_not_contains "$out" ".omp/extensions/fm-primary-omp.ts" \
    "OMP secondmate refusal incorrectly flagged Firstmate's exact tracked primary extension"
  assert_not_contains "$out" ".omp/extensions/fm-fleet-hooks.ts" \
    "OMP secondmate refusal incorrectly flagged Firstmate's exact tracked fleet hooks"
  assert_no_grep 'new-window|new-session' "$CASE_DIR/endpoint.log" \
    "OMP staged secondmate-extension refusal created an endpoint"
  pass "OMP secondmates trust exact primary and fleet extensions while inspecting staged code"
}

test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity() {
  local rec id sm out status launch
  id=$(profile_id profile-pi-signed-secondmate-z8d)
  rec=$(make_spawn_case profile-pi-signed-secondmate codex "$id")
  read_case_record "$rec"
  printf '%s\n' pi-signed > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed pi-signed -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not share Pi's primary extension launch shape"
  pass "pi-signed is a distinct persistent secondmate runtime with shared Pi supervision semantics"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_batch_forwards_omp_prewalk_target() {
  local rec id1 id2 out status target
  id1=$(profile_id profile-batch-prewalk-a-z11)
  id2=$(profile_id profile-batch-prewalk-b-z12)
  rec=$(make_spawn_case profile-batch-prewalk omp "$id1" "$id2")
  read_case_record "$rec"
  target=openai-codex/gpt-5.6-luna:xhigh
  export FM_TEST_OMP_DYNAMIC_ACK=1
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness omp \
    --model openai-codex/gpt-5.6-luna --effort xhigh --prewalk-into "$target")
  status=$?
  unset FM_TEST_OMP_DYNAMIC_ACK
  expect_code 0 "$status" "batch OMP spawn with a shared Prewalk target should succeed"
  assert_contains "$out" "spawned $id1 harness=omp" "first batch task did not use OMP"
  assert_contains "$out" "spawned $id2 harness=omp" "second batch task did not use OMP"
  assert_grep "prewalk_into=$target" "$HOME_DIR/state/$id1.meta" \
    "first batch task did not record the shared Prewalk target"
  assert_grep "prewalk_into=$target" "$HOME_DIR/state/$id2.meta" \
    "second batch task did not record the shared Prewalk target"
  [ "$(grep -Fc -- "--prewalk" "$LAUNCH_LOG")" = 2 ] \
    || fail "batch OMP launch did not forward the native Prewalk target exactly twice"
  pass "batch dispatch forwards the shared OMP Prewalk target to every pair"
}

test_claude_forwards_firstmate_config_dir_when_set() {
  local rec id out status launch
  id=$(profile_id profile-claude-cfgdir-z17)
  rec=$(make_spawn_case profile-claude-cfgdir claude "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='/opt/test/claude-work' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "claude launch did not forward firstmate's CLAUDE_CONFIG_DIR to the crewmate pane"
  pass "claude forwards firstmate's CLAUDE_CONFIG_DIR so the crewmate uses the same credential store"
}

test_claude_omits_config_dir_prefix_when_unset() {
  local rec id out status launch
  id=$(profile_id profile-claude-nocfgdir-z18)
  rec=$(make_spawn_case profile-claude-nocfgdir claude "$id")
  read_case_record "$rec"

  # run_spawn pins CLAUDE_CONFIG_DIR empty by default, exercising the single-store
  # default path where fm-spawn adds no prefix.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without CLAUDE_CONFIG_DIR should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "claude launch must not add a config-dir prefix when firstmate has no CLAUDE_CONFIG_DIR set"
  pass "claude omits the config-dir prefix when firstmate runs with the single-store default"
}

test_claude_root_sandbox_launch_is_unattended() {
  local rec id out status launch sandbox_home project_key
  id=$(profile_id profile-claude-root-sandbox-z18b)
  rec=$(make_spawn_case profile-claude-root-sandbox claude "$id")
  read_case_record "$rec"
  sandbox_home="$CASE_DIR/account-home"
  mkdir -p "$sandbox_home"

  out=$(FM_TEST_HOME_OVERRIDE="$sandbox_home" FM_TEST_IS_SANDBOX=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "sandboxed Claude spawn should succeed"$'\n'"$out"$'\n'"$(cat "$LAUNCH_LOG")"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "IS_SANDBOX=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "sandboxed Claude launch did not carry the root bypass marker into the pane"
  project_key=$(cd "$WT_DIR" && pwd -P)
  jq -e --arg project "$project_key" '
    .hasCompletedOnboarding == true
    and .projects[$project].hasTrustDialogAccepted == true
    and .projects[$project].hasCompletedProjectOnboarding == true
  ' "$sandbox_home/.claude.json" >/dev/null \
    || fail "sandboxed Claude spawn did not pre-accept the isolated project trust/onboarding prompts"
  jq -e '
    .skipDangerousModePermissionPrompt == true
    and .attribution.commit == ""
    and .attribution.pr == ""
    and .attribution.sessionUrl == false
  ' "$sandbox_home/.claude/settings.json" >/dev/null \
    || fail "sandboxed Claude spawn did not pre-accept bypass mode and disable attribution"
  pass "sandboxed Claude launches carry IS_SANDBOX and preseed every first-run prompt"
}

test_non_claude_harness_ignores_config_dir() {
  local rec id out status launch
  id=$(profile_id profile-codex-nocfgdir-z19)
  rec=$(make_spawn_case profile-codex-nocfgdir codex "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "non-claude harness launch must not receive the claude-specific config-dir prefix"
  pass "non-claude harnesses do not receive the claude CLAUDE_CONFIG_DIR prefix"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=$(profile_id profile-secondmate-z16)
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

test_no_profile_keeps_claude_profile_defaults
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_raw_omp_launch_does_not_require_max_time_capability
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_model_and_max_effort
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_omp_threads_exact_identity_model_and_every_thinking_level
test_omp_threads_configurable_max_time
test_omp_broker_env_uses_mode_600_file_without_exposing_bearer
test_secondmate_descendant_omp_inherits_complete_broker_pair
test_omp_prewalk_threads_native_target_and_metadata
test_omp_unusable_prewalk_target_keeps_full_starting_model_trajectory
test_omp_prewalk_accepts_colon_selector_from_launch_worktree_catalog
test_omp_prewalk_fallback_omits_unsupported_disable_flag
test_omp_valid_prewalk_does_not_require_disable_flag
test_omp_unsafe_fallback_refuses_before_endpoint
test_omp_prewalk_live_runtime_refusal_preserves_lease
test_omp_prewalk_premetadata_failure_cleans_endpoint_and_lease
test_omp_prewalk_ambiguous_herdr_creation_preserves_lease
test_ordinary_herdr_partial_create_preserves_response_known_pane
test_omp_prewalk_partial_create_cleans_response_known_pane
test_omp_prewalk_ambiguous_herdr_projection_preserves_lease
test_ordinary_herdr_ambiguous_reclaim_keeps_flat_fallback
test_non_omp_prewalk_refuses_without_changing_normal_claude_launch
test_omp_herdr_worker_and_scout_launch_with_exact_identity_and_ack
test_omp_refuses_unverified_backends_before_endpoint_creation
test_herdr_launch_refuses_after_nested_shell_timeout
test_omp_scout_uses_external_turn_extension
test_omp_whitespace_identity_paths_refuse_before_endpoint
test_omp_missing_binary_or_capability_refuses_before_endpoint_and_metadata
test_omp_launch_requires_observable_turn_start_acknowledgement
test_omp_herdr_unacked_launch_cleans_owned_endpoint_worktree_and_artifacts
test_omp_herdr_refused_close_preserves_worktree_and_artifacts
test_omp_ack_cleanup_preserves_artifacts_when_ownership_changes
test_omp_refuses_tracked_project_extensions_without_opt_in
test_omp_allows_tracked_project_extensions_with_audited_opt_in
test_omp_project_without_tracked_extensions_is_unchanged
test_non_omp_ignores_tracked_project_extensions
test_omp_refuses_tracked_settings_extension_roots
test_omp_refuses_tracked_extension_directory_symlinks
test_omp_root_symlink_uses_shared_opt_in_boundary
test_omp_ignores_hidden_direct_extension_files
test_omp_ignores_unusable_settings_extension_entries
test_omp_ignores_unsupported_root_extension_manifest
test_omp_does_not_trust_copied_primary_adapter_in_projects
test_omp_secondmate_inspects_staged_live_extensions
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_batch_forwards_omp_prewalk_target
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_claude_root_sandbox_launch_is_unattended
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
