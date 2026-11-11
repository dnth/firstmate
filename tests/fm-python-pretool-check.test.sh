#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the Python runner guard PreToolUse seatbelt (docs/python-guard.md).
#
# bin/fm-python-command-policy.mjs owns the block/allow decision on top of the
# shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-python-pretool-check.sh is the stable transport: it requires the local
# opt-in file, scopes the guard to the real primary checkout, and drives all
# five harness entry forms. This suite proves the decision matrix, the opt-in
# gate, the primary-checkout scoping, the fail-open transport behavior, the
# prefilter fast path, and the tracked harness wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-python-pretool-check)

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/ with
# the transport plus both policy files (fm-python-command-policy.mjs imports the
# shared classifier from fm-arm-command-policy.mjs).
install_python_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-python-pretool-check.sh" "$dir/bin/fm-python-pretool-check.sh"
  cp "$ROOT/bin/fm-python-command-policy.mjs" "$dir/bin/fm-python-command-policy.mjs"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  chmod +x "$dir/bin/fm-python-pretool-check.sh" "$dir/bin/fm-python-command-policy.mjs"
}

enable_python_guard() {
  mkdir -p "$1/config"
  printf 'uv\n' > "$1/config/python-runner"
}

make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_python_scripts "$dir"
  enable_python_guard "$dir"
  printf '%s\n' "$dir"
}

# Same shape without the opt-in file: the guard must be inert.
make_disabled_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_python_scripts "$dir"
  printf '%s\n' "$dir"
}

# Same shape as primary plus the .fm-secondmate-home marker: a secondmate's own
# primary session, which the guard does guard (like the cd-guard).
make_secondmate_fixture() {
  local dir=$1
  make_primary_fixture "$dir" >/dev/null
  printf 'sm-python-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree - the shape bin/fm-spawn.sh hands crewmate/scout
# tasks. git-dir and git-common-dir differ, so the guard must be inert even with
# the opt-in file present.
make_child_worktree_fixture() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/python-guard-test-branch
  : > "$dir/AGENTS.md"
  install_python_scripts "$dir"
  enable_python_guard "$dir"
  printf '%s\n' "$dir"
}

PRIMARY=$(make_primary_fixture "$TMP_ROOT/primary")
CHECK="$PRIMARY/bin/fm-python-pretool-check.sh"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_TOKEN=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_TOKEN+=("$3")
  MATRIX_COMMANDS+=("$4")
}

# DENY: bare Python tooling in an executed command position.
matrix_case D01 deny 'uv run python' 'python3 script.py'
matrix_case D02 deny 'uv run python' 'python3 -c "print(1)"'
matrix_case D03 deny 'uv run python' $'python3 - <<\'PY\'\nprint(1)\nPY'
matrix_case D04 deny 'uv run python' 'python3.12 script.py'
matrix_case D05 deny 'uv run python' 'python script.py'
matrix_case D06 deny 'uv add' 'pip install requests'
matrix_case D07 deny 'uv pip install' 'pip3 install -r requirements.txt'
matrix_case D08 deny 'uv add' 'python3 -m pip install requests'
matrix_case D09 deny 'uvx' 'pipx run ruff check .'
matrix_case D10 deny 'uv tool install' 'pipx install black'
matrix_case D11 deny 'uv venv' 'python3 -m venv .venv'
matrix_case D12 deny 'uv venv' 'virtualenv .venv'
matrix_case D13 deny 'uvx' 'python3 -m http.server 8000'
matrix_case D14 deny 'uv run python' 'X=1 python3 script.py'
matrix_case D15 deny 'uv run python' 'echo before; python3 script.py'
matrix_case D16 deny 'uv run python' 'python3 script.py && ls'
matrix_case D17 deny 'uv run python' 'command python3 script.py'
matrix_case D18 deny 'uv run python' 'sudo python3 script.py'
matrix_case D19 deny 'uv run python' 'cat data | python3 -'
matrix_case D20 deny 'uv run python' '"python3" script.py'
matrix_case D21 deny 'uv run python' 'builtin python3 script.py'
matrix_case D22 deny 'uv run python' 'python3 script.py > out.log'
matrix_case D23 deny 'uv run python' 'p"ython"3 script.py'
matrix_case D24 deny 'uv run python' 'py\thon3 script.py'
matrix_case D25 deny 'uv add' 'pip --quiet install requests'
matrix_case D26 deny 'uv pip install' 'pip3 --quiet install requests'
matrix_case D27 deny 'uv venv' 'python3 -m virtualenv .venv'

# ALLOW: uv tooling, data, arguments, paths, and non-executed occurrences.
matrix_case A01 allow '' 'uv run python3 script.py'
matrix_case A02 allow '' 'uvx ruff check .'
matrix_case A03 allow '' 'uv add requests'
matrix_case A04 allow '' 'uv pip install requests'
matrix_case A05 allow '' 'uv venv .venv'
matrix_case A06 allow '' 'uv tool install black'
matrix_case A07 allow '' 'uv run --with requests python script.py'
matrix_case A08 allow '' 'uv run python -c "print(1)"'
matrix_case A09 allow '' 'uvx --from ruff ruff check .'
matrix_case A10 allow '' 'echo "python3 script.py"'
matrix_case A11 allow '' 'grep python3 README.md'
matrix_case A12 allow '' $'cat <<\'EOF\'\npython3 script.py\nEOF'
matrix_case A13 allow '' 'ls /usr/bin/python3'
matrix_case A14 allow '' 'chmod +x ./python3'
matrix_case A15 allow '' 'npm install python3'
matrix_case A16 allow '' 'pipx list'
matrix_case A17 allow '' './python3 script.py'
matrix_case A18 allow '' 'python3.12-config --cflags'
matrix_case A19 allow '' "echo 'pip install requests'"
matrix_case A20 allow '' 'git log --grep python3'
matrix_case A21 allow '' 'printf "%s\n" python3'
matrix_case A22 allow '' 'pip list'
matrix_case A23 allow '' 'pip3 show requests'
matrix_case A24 allow '' 'pip --version'
matrix_case A25 allow '' 'pip uninstall requests'

for separator in ';' $'\n' '|' '|&' '&&' '||' '&'; do
  for invocation in 'python3 script.py' 'pip install requests' 'pipx run ruff' 'pipx install ruff' 'virtualenv .venv'; do
    matrix_case "list-${#MATRIX_IDS[@]}" deny 'uv' "pipx list $separator $invocation"
  done
done
for prefix in 'command -v' 'command -V' 'env command -v' 'sudo command -V' 'timeout 2 command -v' 'builtin command -v'; do
  for tool in python3 pip pipx virtualenv; do
    matrix_case "query-${#MATRIX_IDS[@]}" allow '' "$prefix $tool"
  done
done
matrix_case query-list deny 'uv run python' 'command -v python3; python3 script.py'
matrix_case pip-list deny 'uv run python' 'pip list; python3 script.py'
for option in '-W ignore' '-X dev' '-Wignore' '-Xdev' '-W ignore -X dev'; do
  matrix_case "venv-options-${#MATRIX_IDS[@]}" deny 'uv venv' "python3 $option -m venv .venv"
  matrix_case "virtualenv-options-${#MATRIX_IDS[@]}" deny 'uv venv' "python3 $option -m virtualenv .venv"
  matrix_case "pip-options-${#MATRIX_IDS[@]}" deny 'uv add' "python3 $option -m pip install requests"
  matrix_case "module-options-${#MATRIX_IDS[@]}" deny 'uvx' "python3 $option -m http.server"
  matrix_case "script-options-${#MATRIX_IDS[@]}" deny 'uv run python' "python3 $option script.py -m venv"
done

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-python-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

run_matrix_entry() {
  local id=$1 expected=$2 token=$3 entry=$4 cmd=$5 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  assert_matrix_result "$id" "$expected" "$token" "$entry" "$rc" "$out_file" "$err_file"
}

assert_matrix_result() {
  local id=$1 expected=$2 token=$3 entry=$4 rc=$5 out_file=$6 err_file=$7
  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[bare-(python|pip|pipx|virtualenv)\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry a bare-tooling reason code on stderr: $(cat "$err_file")"
  jq -e --arg token "$token" '.systemMessage | contains($token)' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must name the uv replacement '$token': $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  else
    jq -e --arg token "$token" '.decision == "deny" and (.reason | contains($token))' "$out_file" >/dev/null 2>&1 \
      || fail "$id via $entry deny must carry decision=deny and uv guidance on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "${MATRIX_TOKEN[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "python-guard acceptance matrix: ${#MATRIX_IDS[@]} cases x 5 harness entry forms, block/allow all correct"
}

# --- opt-in gate ------------------------------------------------------------

test_inert_without_opt_in() {
  local dir out rc
  dir=$(make_disabled_fixture "$TMP_ROOT/disabled")
  out=$("$dir/bin/fm-python-pretool-check.sh" --claude --command 'python3 script.py' 2>&1); rc=$?
  expect_code 0 "$rc" "python-guard must be inert without config/python-runner"
  [ -z "$out" ] || fail "python-guard produced output without the opt-in file: $out"
  pass "python-guard: silent no-op when the opt-in file is absent"
}

test_inert_with_unrecognized_opt_in_value() {
  local dir out rc
  dir=$(make_disabled_fixture "$TMP_ROOT/bad-opt-in")
  mkdir -p "$dir/config"
  printf 'python3\n' > "$dir/config/python-runner"
  out=$("$dir/bin/fm-python-pretool-check.sh" --claude --command 'python3 script.py' 2>&1); rc=$?
  expect_code 0 "$rc" "python-guard must stay inert for an unrecognized config/python-runner value"
  [ -z "$out" ] || fail "python-guard produced output for an unrecognized opt-in value: $out"
  pass "python-guard: silent no-op unless config/python-runner names uv"
}

test_opt_in_honors_config_override() {
  local dir cfg out rc
  dir=$(make_disabled_fixture "$TMP_ROOT/config-override")
  cfg="$TMP_ROOT/config-override-config"
  mkdir -p "$cfg"
  printf 'uv\n' > "$cfg/python-runner"
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$dir/bin/fm-python-pretool-check.sh" --claude --command 'python3 script.py' 2>&1); rc=$?
  expect_code 2 "$rc" "python-guard must read the opt-in file from FM_CONFIG_OVERRIDE"
  assert_contains "$out" '[bare-python]' "config-override block must carry the reason code"
  pass "python-guard: FM_CONFIG_OVERRIDE selects the opt-in config directory"
}

# --- primary-checkout scoping ----------------------------------------------

test_inert_in_child_worktree() {
  local base dir out rc
  base="$TMP_ROOT/child-base"
  dir="$TMP_ROOT/child-wt"
  make_child_worktree_fixture "$base" "$dir" >/dev/null
  out=$("$dir/bin/fm-python-pretool-check.sh" --claude --command 'python3 script.py' 2>&1); rc=$?
  expect_code 0 "$rc" "python-guard must be inert in a crewmate/scout linked worktree"
  [ -z "$out" ] || fail "python-guard produced output in a child worktree: $out"
  pass "python-guard: inert in a crewmate/scout task worktree (linked git worktree)"
}

test_fires_in_secondmate_home() {
  local dir out rc
  dir=$(make_secondmate_fixture "$TMP_ROOT/secondmate")
  out=$("$dir/bin/fm-python-pretool-check.sh" --claude --command 'python3 script.py' 2>&1); rc=$?
  expect_code 2 "$rc" "python-guard must fire in a secondmate's own primary session"
  assert_contains "$out" '[bare-python]' "secondmate-home block must carry the reason code"
  pass "python-guard: fires in a secondmate home (its own primary session is a primary)"
}

test_inert_when_not_firstmate_repo() {
  local dir out rc
  dir="$TMP_ROOT/not-firstmate"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  install_python_scripts "$dir"   # bin/ present but no AGENTS.md
  enable_python_guard "$dir"
  out=$("$dir/bin/fm-python-pretool-check.sh" --claude --command 'python3 script.py' 2>&1); rc=$?
  expect_code 0 "$rc" "python-guard must be inert without AGENTS.md (not a firstmate checkout)"
  [ -z "$out" ] || fail "python-guard produced output outside a firstmate checkout: $out"
  pass "python-guard: inert in a non-firstmate repo (no AGENTS.md)"
}

test_inert_when_not_a_git_repo() {
  local dir out rc
  dir="$TMP_ROOT/no-git"
  mkdir -p "$dir"
  : > "$dir/AGENTS.md"
  install_python_scripts "$dir"   # AGENTS.md + bin/ but no git repo
  enable_python_guard "$dir"
  out=$("$dir/bin/fm-python-pretool-check.sh" --claude --command 'python3 script.py' 2>&1); rc=$?
  expect_code 0 "$rc" "python-guard must be inert when the checkout is not a git repo"
  [ -z "$out" ] || fail "python-guard produced output in a non-git dir: $out"
  pass "python-guard: inert when not inside a git repo"
}

# --- fail-open transport behavior ------------------------------------------

test_fail_open_empty_stdin() {
  local out rc
  out=$("$CHECK" < /dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  pass "python-guard: fails open on empty stdin"
}

test_fail_open_unparseable_json() {
  local out rc
  out=$(printf 'not json at all' | "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"
  pass "python-guard: fails open on unparseable stdin JSON"
}

test_fail_open_missing_node() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # node deliberately absent from this PATH.
  out=$(PATH="$fakebin" "$CHECK" --command 'python3 script.py' 2>&1); rc=$?
  expect_code 0 "$rc" "transport must fail open when node is unavailable"
  [ -z "$out" ] || fail "transport produced output without node: $out"
  pass "python-guard: fails open (never blocks) when node is missing"
}

test_fail_open_missing_jq_on_stdin() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh git dirname cat printf sed tr node; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # jq deliberately absent: the stdin transport cannot extract the command.
  out=$(printf '{"tool_input":{"command":"python3 script.py"}}' | PATH="$fakebin" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "transport produced output without jq on the stdin path: $out"
  pass "python-guard: fails open on the stdin path when jq is missing"
}

# --- prefilter fast path ---------------------------------------------------

test_prefilter_skips_node_without_python_substring() {
  local dir fakebin marker tool tool_path out rc
  dir="$TMP_ROOT/prefilter"
  make_primary_fixture "$dir" >/dev/null
  fakebin=$(fm_fakebin "$TMP_ROOT/prefilter-fake")
  marker="$TMP_ROOT/prefilter-node-called"
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/node" <<EOF
#!/usr/bin/env bash
: > "$marker"
exit 0
EOF
  chmod +x "$fakebin/node"
  # No python/pip/virtualenv substring: the prefilter must fast-allow before
  # scoping or the policy runtime is ever consulted.
  out=$(PATH="$fakebin" "$dir/bin/fm-python-pretool-check.sh" --command 'git status' 2>&1); rc=$?
  expect_code 0 "$rc" "prefilter must fast-allow a command with no python/pip/virtualenv substring"
  [ -z "$out" ] || fail "prefilter fast-allow produced output: $out"
  [ ! -e "$marker" ] || fail "prefilter fast-allow still invoked the node policy owner"
  pass "python-guard: prefilter fast-allows (skips node) when no python/pip/virtualenv substring is present"
}

# --- policy CLI contract ---------------------------------------------------

test_policy_cli_direct() {
  local policy
  policy="$ROOT/bin/fm-python-command-policy.mjs"
  [ "$(node "$policy" --command 'python3 script.py' | cut -f1)" = deny ] \
    || fail "policy CLI must deny a bare python3 invocation"
  [ "$(node "$policy" --command 'uv run python3 script.py')" = allow ] \
    || fail "policy CLI must allow uv run python3"
  [ "$(node "$policy" --command 'echo "python3 script.py"')" = allow ] \
    || fail "policy CLI must allow python3 inside quoted data"
  [ "$(node "$policy")" = allow ] \
    || fail "policy CLI must allow when no command is supplied"
  pass "python-guard: fm-python-command-policy.mjs CLI honors the deny/allow output contract"
}

# --- per-harness wiring -----------------------------------------------------

test_stdio_harness_wiring() {
  local repo entry config cmd expected payload hook rc blocked out_file err_file
  repo=$(make_primary_fixture "$TMP_ROOT/stdio-hooks")
  mkdir -p "$repo/.claude" "$repo/.codex" "$repo/.grok/hooks"
  cp "$ROOT/.claude/settings.json" "$repo/.claude/settings.json"
  cp "$ROOT/.codex/hooks.json" "$repo/.codex/hooks.json"
  cp "$ROOT/.grok/hooks/fm-primary-python-check.json" "$repo/.grok/hooks/fm-primary-python-check.json"
  cp "$ROOT/bin/fm-arm-pretool-check.sh" "$ROOT/bin/fm-cd-pretool-check.sh" "$ROOT/bin/fm-cd-command-policy.mjs" "$repo/bin/"
  for entry in claude codex grok; do
    case "$entry" in
      claude) config="$repo/.claude/settings.json" ;;
      codex) config="$repo/.codex/hooks.json" ;;
      grok) config="$repo/.grok/hooks/fm-primary-python-check.json" ;;
    esac
    for expected in deny allow; do
      cmd='python3 script.py'
      [ "$expected" != allow ] || cmd='uv run python3 script.py'
      if [ "$entry" = grok ]; then
        payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      else
        payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      fi
      blocked=0
      while IFS= read -r hook; do
        out_file="$MATRIX_TMP/hook-$entry.out"
        err_file="$MATRIX_TMP/hook-$entry.err"
        (
          cd "$repo" || exit 1
          export CLAUDE_PROJECT_DIR="$repo" GROK_WORKSPACE_ROOT="$repo" FM_HOME="$repo"
          unset FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE
          printf '%s' "$payload" | bash -c "$hook"
        ) >"$out_file" 2>"$err_file"
        rc=$?
        if [ "$rc" -eq 2 ] && [ "$expected" = deny ]; then
          assert_matrix_result hook deny 'uv run python' "$entry" "$rc" "$out_file" "$err_file"
          blocked=1
        else
          assert_matrix_result hook allow '' "$entry" "$rc" "$out_file" "$err_file"
        fi
      done < <(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.type == "command") | .command' "$config")
      [ "$expected" != deny ] || [ "$blocked" -eq 1 ] || fail "$entry configured hooks must deny bare Python"
    done
  done
  pass "python-guard: configured Claude, Codex, and Grok hooks deny bare Python and silently allow uv"
}

test_opencode_plugin_forwards_and_blocks() {
  local repo out status
  repo="$TMP_ROOT/opencode"
  mkdir -p "$repo/bin"
  cat > "$repo/bin/fm-python-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in python3*|pip*|virtualenv*) printf 'python denied\n' >&2; exit 2 ;; esac
exit 0
SH
  chmod +x "$repo/bin/fm-python-pretool-check.sh"
  out=$(PLUGIN="$ROOT/.opencode/plugins/fm-primary-python-check.js" REPO="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const factory = mod.FmPrimaryPythonCheck;
if (typeof factory !== "function") throw new Error("plugin does not export FmPrimaryPythonCheck");
const plugin = await factory({ worktree: process.env.REPO });
let blocked = "";
try {
  await plugin["tool.execute.before"]({ tool: "bash" }, { args: { command: "python3 script.py" } });
} catch (error) {
  blocked = String(error?.message ?? error);
}
if (!blocked.includes("python denied")) throw new Error(`python3 was not blocked: ${blocked}`);
await plugin["tool.execute.before"]({ tool: "bash" }, { args: { command: "uv run python3 script.py" } });
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must block a bare python3 command and allow uv"
  [ -z "$out" ] || fail "OpenCode python-guard plugin test printed output: $out"
  pass ".opencode primary plugin: forwards bash commands to the python guard and surfaces its deny"
}

test_pi_extension_forwards_and_blocks() {
  local repo ext out status
  repo="$TMP_ROOT/pi"
  ext="$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  mkdir -p "$repo/.pi/extensions/lib" "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$ext"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cat > "$repo/bin/fm-python-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in python3*|pip*|virtualenv*) printf 'python denied\n' >&2; exit 2 ;; esac
exit 0
SH
  for script in fm-cd-pretool-check.sh fm-arm-pretool-check.sh; do
    cat > "$repo/bin/$script" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  done
  chmod +x "$repo/bin/"*.sh
  out=$(PLUGIN="$ext" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  sendMessage() {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const toolCall = handlers.get("tool_call");
if (!toolCall) throw new Error("pi extension did not register a tool_call handler");
const blocked = await toolCall({ type: "tool_call", toolName: "bash", input: { command: "python3 script.py" } });
if (blocked?.block !== true || !String(blocked.reason).includes("python denied")) {
  throw new Error(`python3 was not blocked: ${JSON.stringify(blocked)}`);
}
const allowed = await toolCall({ type: "tool_call", toolName: "bash", input: { command: "uv run python3 script.py" } });
if (allowed?.block === true) throw new Error(`uv was blocked: ${JSON.stringify(allowed)}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension must block a bare python3 command and allow uv"
  [ -z "$out" ] || fail "Pi python-guard extension test printed output: $out"
  pass ".pi primary extension: forwards bash commands to the python guard and surfaces its deny"
}

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$ROOT/bin/fm-python-pretool-check.sh" "$ROOT/tests/fm-python-pretool-check.test.sh" >/dev/null 2>&1 \
    || fail "python-guard transport or its test is not shellcheck-clean"
  pass "bin/fm-python-pretool-check.sh and its test are shellcheck-clean"
}

test_full_acceptance_matrix
test_inert_without_opt_in
test_inert_with_unrecognized_opt_in_value
test_opt_in_honors_config_override
test_inert_in_child_worktree
test_fires_in_secondmate_home
test_inert_when_not_firstmate_repo
test_inert_when_not_a_git_repo
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_node
test_fail_open_missing_jq_on_stdin
test_prefilter_skips_node_without_python_substring
test_policy_cli_direct
test_stdio_harness_wiring
test_opencode_plugin_forwards_and_blocks
test_pi_extension_forwards_and_blocks
test_scripts_are_shellcheck_clean
