#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the cd-guard PreToolUse seatbelt (docs/cd-guard.md).
#
# bin/fm-cd-command-policy.mjs is the single owner of the block/allow decision;
# it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-cd-pretool-check.sh is the stable transport: it scopes the guard to the
# real primary checkout, then drives all five harness entry forms. This suite
# proves the decision matrix, the harness-output shaping, the primary-checkout
# scoping (including the deliberate secondmate-home difference from the turn-end
# guard), the fail-open transport behavior, the prefilter fast path, the
# end-to-end cwd-leak regression, and the per-harness wiring. No harness is
# spawned; live per-harness evidence lives in docs/cd-guard.md.
set -u

# CDPATH redirects a relative cd, so a caller's value must not leak into these
# fixtures; the CDPATH cases set it explicitly.
unset CDPATH

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-cd-pretool-check)

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/ with
# the transport plus both policy files (fm-cd-command-policy.mjs imports the
# shared classifier from fm-arm-command-policy.mjs). This is what the transport's
# scoping treats as the real primary firstmate checkout.
install_cd_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-cd-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  chmod +x "$dir/bin/fm-cd-pretool-check.sh" "$dir/bin/fm-cd-command-policy.mjs"
}

make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"
  # Targets the home carve-out must allow, and hazards it must keep denying.
  mkdir -p "$dir/data" "$dir/state" "$dir/projects/foo" "$dir/projects/bar"
  ln -s data "$dir/link-to-data"
  ln -s projects/foo "$dir/link-to-project"
  ln -s /tmp "$dir/outside-link"
  printf '%s\n' "$dir"
}

# Same shape as primary plus the .fm-secondmate-home marker: a secondmate's own
# primary session, which the cd-guard DOES guard (unlike the turn-end guard).
make_secondmate_fixture() {
  local dir=$1
  make_primary_fixture "$dir" >/dev/null
  printf 'sm-cd-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree - the shape bin/fm-spawn.sh hands crewmate/scout
# tasks. git-dir and git-common-dir differ, so the guard must be inert.
make_child_worktree_fixture() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/cd-guard-test-branch
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"
  printf '%s\n' "$dir"
}

PRIMARY=$(make_primary_fixture "$TMP_ROOT/primary")
CHECK="$PRIMARY/bin/fm-cd-pretool-check.sh"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

# BLOCK: a persistent top-level cwd change in the parent shell.
matrix_case B01 deny 'cd projects/foo'
matrix_case B02 deny 'cd ..'
matrix_case B03 deny 'cd'
matrix_case B04 deny 'cd -'
matrix_case B05 deny 'cd /abs/path'
matrix_case B06 deny 'pushd projects/foo'
matrix_case B07 deny 'popd'
matrix_case B08 deny 'X=1 cd projects/foo'
matrix_case B09 deny 'cd projects/foo && tasks-axi add x'
matrix_case B10 deny 'echo before; cd projects/foo'
matrix_case B11 deny 'true && cd projects/foo'
matrix_case B12 deny 'tasks-axi done x || cd projects/foo'
matrix_case B13 deny 'cd "projects/foo"'
matrix_case B14 deny '"cd" projects/foo'
matrix_case B15 deny 'sleep 1 & cd projects/foo'
matrix_case B16 deny 'command cd projects/foo'
matrix_case B17 deny 'cd projects/foo >/dev/null'
matrix_case B18 deny $'cd projects/foo\necho done'
matrix_case B19 deny "\$'\\143d' projects/foo"
matrix_case B20 deny "c'd' projects/foo"
matrix_case B21 deny 'c"d" projects/foo'
matrix_case B22 deny 'c\d projects/foo'
matrix_case B23 deny 'builtin cd projects/foo'
matrix_case B24 deny 'command builtin cd projects/foo'
matrix_case B25 deny 'builtin command cd projects/foo'
matrix_case B26 deny 'command -p cd projects/foo'
matrix_case B27 deny 'command -- cd projects/foo'

# BLOCK: a persistent cd that can leave the home - anything in the projects
# tree, a link that resolves out of the home, /tmp, and an unresolvable target.
matrix_case B28 deny "cd $PRIMARY/projects"
matrix_case B29 deny "cd $PRIMARY/projects/foo"
matrix_case B30 deny 'cd data/../projects/foo'
matrix_case B31 deny "cd $PRIMARY/link-to-project"
matrix_case B32 deny "cd $PRIMARY/link-to-project/.."
matrix_case B33 deny "cd $PRIMARY/outside-link"
matrix_case B34 deny 'cd /tmp'
matrix_case B35 deny "cd $TMP_ROOT"
matrix_case B36 deny "cd $PRIMARY/does-not-exist"
matrix_case B37 deny 'cd data && cd state'
matrix_case B38 deny 'CDPATH=/tmp cd data'
# A later node makes the context unprovable, so the exemption stops.
matrix_case B39 deny 'echo hi; cd data'
matrix_case B40 deny 'cd data || cd ..'
# The special - (OLDPWD) and every option stay denied.
matrix_case B41 deny 'cd -'
matrix_case B42 deny 'cd -P data'
matrix_case B43 deny 'cd -- -'
matrix_case B44 deny 'printf x | cat; cd data'
matrix_case B45 deny 'sleep 1 & cd data'
matrix_case B46 deny '(true); cd data'
matrix_case B47 deny '{ true; }; cd data'
matrix_case B48 deny 'if true; then cd data; fi'
matrix_case B49 deny 'for x in a; do cd data; done'
matrix_case B50 deny 'if cd data; then pwd; fi'
matrix_case B51 deny 'while false; do cd data; done'
matrix_case B52 deny 'until true; do cd data; done'
matrix_case B53 deny 'time cd data'
matrix_case B54 deny '! cd data'

# ALLOW: not a persistent top-level cwd change (scoped, data, or non-cd).
matrix_case A01 allow 'git -C projects/foo status'
matrix_case A02 allow 'cat /abs/path/file'
matrix_case A03 allow 'ls projects/foo'
matrix_case A04 allow 'echo "cd projects/foo"'
matrix_case A05 allow 'grep cd file'
matrix_case A06 allow '(cd projects/foo && pwd)'
matrix_case A07 allow "bash -c 'cd projects/foo'"
matrix_case A08 allow 'env -C projects/foo make'
matrix_case A09 allow 'make -C projects/foo build'
matrix_case A10 allow 'find . -execdir cd {} \;'
matrix_case A11 allow 'cd projects/foo | cat'
matrix_case A12 allow 'cat foo | cd bar'
matrix_case A13 allow 'cd projects/foo &'
matrix_case A14 allow 'abcd project'
matrix_case A15 allow 'cdk deploy'
matrix_case A16 allow 'env cd projects/foo'
matrix_case A17 allow 'sudo cd projects/foo'
matrix_case A18 allow 'x=$(cd foo && pwd)'
matrix_case A19 allow 'dirs'
matrix_case A20 allow "echo 'pushd x'"
matrix_case A21 allow 'git checkout main'
matrix_case A22 allow "sh -c 'cd projects/foo && ls'"
matrix_case A23 allow "printf '%s\\n' 'cd projects/foo'"
matrix_case A24 allow 'ls -la'
matrix_case A25 allow './cd projects/foo'
matrix_case A26 allow '/tmp/cd projects/foo'
matrix_case A27 allow '/usr/bin/cd projects/foo'
matrix_case A28 allow './builtin cd projects/foo'
matrix_case A29 allow 'c\d\ projects/foo'
matrix_case A30 allow './command cd projects/foo'
matrix_case A31 allow '/usr/bin/command cd projects/foo'
matrix_case A32 allow '/tmp/builtin cd projects/foo'
matrix_case A33 allow 'command -v cd'
matrix_case A34 allow 'command -V cd'
matrix_case A35 allow 'command -pv cd'
matrix_case A36 allow 'command -vp cd'

# ALLOW: a persistent cd that cannot leave the home - the home itself, or a
# directory inside it outside projects/ and outside any foreign git checkout.
matrix_case A37 allow "cd $PRIMARY"
matrix_case A38 allow "cd $PRIMARY/"
matrix_case A39 allow "cd $PRIMARY/data"
matrix_case A40 allow 'cd data'
matrix_case A41 allow 'cd data/'
matrix_case A42 allow 'cd data/..'
matrix_case A43 allow "cd -- $PRIMARY/state"
matrix_case A44 allow "cd \"$PRIMARY/data\""
matrix_case A45 allow "cd $PRIMARY/link-to-data"
matrix_case A46 allow 'cd ./state'
matrix_case A47 allow "cd $PRIMARY/data && tasks-axi add x"
# An allowed cd updates the tracked cwd, so later nodes resolve from there.
matrix_case A48 allow 'cd data && cd ..'
matrix_case A49 allow 'cd data && cd ../state'
# A semicolon chain of exempt cds stays provable.
matrix_case A50 allow 'cd data; cd ..'
matrix_case A51 allow 'X=1 cd data'
matrix_case A52 allow 'cd data >/dev/null'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-cd-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
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

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[persistent-cd\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry the persistent-cd reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
  done
  pass "cd-guard acceptance matrix: ${#MATRIX_IDS[@]} cases x 5 harness entry forms, block/allow all correct"
}

# --- home carve-out: expansion forms ---------------------------------------

# $FM_HOME, ~, and relative targets must resolve exactly like the absolute
# spelling of the same directory; only the resolved location decides.
test_home_forms_resolve_like_absolute() {
  local elsewhere out rc

  out=$(FM_HOME="$PRIMARY" "$CHECK" --claude --command 'cd $FM_HOME' 2>&1); rc=$?
  expect_code 0 "$rc" 'cd $FM_HOME must resolve to the home and be allowed'
  [ -z "$out" ] || fail "cd \$FM_HOME produced output: $out"

  out=$(FM_HOME="$PRIMARY" "$CHECK" --claude --command 'cd ${FM_HOME}/state' 2>&1); rc=$?
  expect_code 0 "$rc" 'cd ${FM_HOME}/state must resolve inside the home and be allowed'

  out=$(FM_HOME="$PRIMARY" "$CHECK" --claude --command 'cd "$FM_HOME/data"' 2>&1); rc=$?
  expect_code 0 "$rc" 'a quoted $FM_HOME target must resolve the same way'

  # Bash expands an unset variable to the empty string, so this becomes
  # `cd /data`: the policy must not invent a value that widens beyond the home.
  out=$(env -u FM_HOME "$CHECK" --claude --command 'cd $FM_HOME/data' 2>&1); rc=$?
  expect_code 2 "$rc" 'an unset FM_HOME must stay denied rather than resolve to a made-up home'
  assert_contains "$out" '[persistent-cd]' 'unset-FM_HOME deny must carry the reason code'
  out=$(env -u FM_HOME "$CHECK" --claude --command 'cd $FM_HOME' 2>&1); rc=$?
  expect_code 2 "$rc" 'an empty $FM_HOME must not become a return to the home'

  elsewhere="$TMP_ROOT/elsewhere"
  mkdir -p "$elsewhere/data"
  out=$(FM_HOME="$elsewhere" "$CHECK" --claude --command 'cd $FM_HOME/data' 2>&1); rc=$?
  expect_code 2 "$rc" 'an FM_HOME outside the checkout must not become an extra allowed root'
  assert_contains "$out" '[persistent-cd]' 'outside-FM_HOME deny must carry the reason code'

  out=$(FM_HOME="$PRIMARY" "$CHECK" --claude --command 'cd $FM_HOME/projects/foo' 2>&1); rc=$?
  expect_code 2 "$rc" 'cd $FM_HOME/projects/foo must stay denied'

  out=$(HOME="$PRIMARY" "$CHECK" --claude --command 'cd ~' 2>&1); rc=$?
  expect_code 0 "$rc" 'cd ~ must be allowed when ~ resolves to the home'

  out=$(HOME="$PRIMARY" "$CHECK" --claude --command 'cd ~/data' 2>&1); rc=$?
  expect_code 0 "$rc" 'cd ~/data must be allowed when it resolves inside the home'

  # Only the tilde prefix decides expansion, so a quoted suffix still expands.
  out=$(HOME="$PRIMARY" "$CHECK" --claude --command 'cd ~/"data"' 2>&1); rc=$?
  expect_code 0 "$rc" 'an unquoted tilde prefix expands even when the suffix is quoted'

  out=$(HOME="$PRIMARY" "$CHECK" --claude --command 'cd ~/link-to-project' 2>&1); rc=$?
  expect_code 2 "$rc" 'cd ~/link-to-project must stay denied because it resolves into projects/'

  out=$(HOME="$PRIMARY" "$CHECK" --claude --command 'cd ~nobody' 2>&1); rc=$?
  expect_code 2 "$rc" 'a ~user target this policy cannot resolve must stay denied'

  pass 'cd-guard: $FM_HOME, ~, and relative forms resolve like their absolute spellings'
}

# --- home carve-out: CDPATH cannot redirect a relative target --------------

# An inherited CDPATH can send an exempted relative target out of the home.
test_cdpath_denies_relative_targets() {
  local out rc

  out=$(CDPATH=/tmp "$CHECK" --claude --command 'cd data' 2>&1); rc=$?
  expect_code 2 "$rc" 'an inherited CDPATH must deny the relative target it could redirect'
  assert_contains "$out" '[persistent-cd]' 'CDPATH deny must carry the reason code'

  out=$(CDPATH=/tmp "$CHECK" --claude --command 'cd ./data' 2>&1); rc=$?
  expect_code 0 "$rc" 'a ./ target never consults CDPATH and must stay allowed'

  out=$(CDPATH='' "$CHECK" --claude --command 'cd data' 2>&1); rc=$?
  expect_code 0 "$rc" 'an empty CDPATH must not deny a home-relative target'

  pass 'cd-guard: CDPATH denies a relative target that it could redirect out of the home'
}

test_reachable_cwd_and_expansion_regressions() {
  local dir outside command actual out rc
  dir="$TMP_ROOT/reachable-home"
  outside="$TMP_ROOT/cdpath-outside"
  make_primary_fixture "$dir" >/dev/null
  mkdir -p "$dir/data/state" "$dir/data/sub" "$dir/~/data" "$dir/.cache" "$outside/.cache" "$outside/data"
  git init -q "$dir/state"
  git init -q "$dir/~/data"
  ln -s data/sub "$dir/link"

  for command in 'true || cd data; cd state' 'true && cd data; cd state' 'cd link && cd ../state' 'cd data >missing/output; cd state'; do
    actual=$(cd "$dir" && bash --noprofile --norc -c "$command; pwd -P" 2>/dev/null)
    case "$command" in
      'true && cd data; cd state') [ "$dir/data/state" = "$actual" ] || fail 'Bash executes the conditional cd' ;;
      *) [ "$dir/state" = "$actual" ] || fail 'Bash reaches the nested checkout' ;;
    esac
    out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command "$command" 2>&1); rc=$?
    expect_code 2 "$rc" 'every reachable cwd must be safe, including skipped conditional paths'
  done

  for command in "CDPATH=$outside cd .cache" "CDPATH=$outside; cd data" "CDPATH=\$(printf %s $outside) cd data"; do
    actual=$(cd "$dir" && bash --noprofile --norc -c "$command >/dev/null; pwd -P")
    case "$actual" in "$outside/"*) ;; *) fail "Bash CDPATH oracle did not leave the home: $actual" ;; esac
    out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command "$command" 2>&1); rc=$?
    expect_code 2 "$rc" 'CDPATH redirection must deny dot names and changed or unresolved values'
  done

  for command in "FM_HOME=$outside; cd \"\$FM_HOME\"" "HOME=$outside; cd ~/data"; do
    actual=$(cd "$dir" && bash --noprofile --norc -c "$command; pwd -P" 2>/dev/null)
    case "$actual" in "$outside"|"$outside/"*) ;; *) fail "Bash variable oracle did not leave the home: $actual" ;; esac
    out=$(HOME="$dir" FM_HOME="$dir" "$dir/bin/fm-cd-pretool-check.sh" --claude --command "$command" 2>&1); rc=$?
    expect_code 2 "$rc" 'earlier assignments must invalidate expansion context'
  done

  for command in "cd '~/data'" 'cd "~/data"' 'cd \~/data'; do
    actual=$(cd "$dir" && HOME="$dir" bash --noprofile --norc -c "$command; pwd -P" 2>/dev/null)
    [ "$dir/~/data" = "$actual" ] || fail 'Bash keeps quoted and escaped tildes literal'
    out=$(HOME="$dir" "$dir/bin/fm-cd-pretool-check.sh" --claude --command "$command" 2>&1); rc=$?
    expect_code 2 "$rc" 'literal tilde paths into a checkout must deny'
  done
  out=$(CDPATH="$outside" "$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd .cache' 2>&1); rc=$?
  expect_code 2 "$rc" 'inherited CDPATH must also deny dot-prefixed names'
  for command in 'cd data && cd ..' 'cd data; cd state' 'cd ~/data' 'cd ./data'; do
    out=$(HOME="$dir" "$dir/bin/fm-cd-pretool-check.sh" --claude --command "$command" 2>&1); rc=$?
    expect_code 0 "$rc" 'ordinary safe directory changes must remain allowed'
  done
  pass 'cd-guard: reachable cwd and expansion regressions match Bash' 
}

test_exemption_proof_regressions() {
  local dir outside command actual out rc
  dir="$TMP_ROOT/proof-home"
  outside="$TMP_ROOT/proof-outside"
  make_primary_fixture "$dir" >/dev/null
  mkdir -p "$dir/data space/state" "$outside/data"
  git init -q "$dir/state"

  for command in 'cd $FM_HOME; cd state' 'cd ${FM_HOME}; cd state' 'cd $FM_HOME""; cd state' 'cd ""$FM_HOME; cd state'; do
    actual=$(cd "$dir" && FM_HOME="$dir/data space" bash --noprofile --norc -c "$command; pwd -P" 2>/dev/null)
    [ "$actual" = "$dir/state" ] || fail 'Bash rejects the split operand and reaches the checkout from home'
    out=$(FM_HOME="$dir/data space" "$dir/bin/fm-cd-pretool-check.sh" --claude --command "$command" 2>&1); rc=$?
    expect_code 2 "$rc" 'an unquoted expansion that splits cannot prove a cd succeeds'
  done
  for command in 'cd "$FM_HOME"' 'cd "${FM_HOME}/state"'; do
    out=$(FM_HOME="$dir/data space" "$dir/bin/fm-cd-pretool-check.sh" --claude --command "$command" 2>&1); rc=$?
    expect_code 0 "$rc" 'quoting the expansion preserves a single safe operand containing spaces'
  done

  for command in "cd data >\"\${CDPATH:=$outside}/cd-log\"" "X=\${CDPATH:=$outside} cd data"; do
    actual=$(cd "$dir" && CDPATH='' bash --noprofile --norc -c "$command >/dev/null; pwd -P")
    [ "$actual" = "$outside/data" ] || fail 'Bash expands the side effect before resolving cd through CDPATH'
    out=$(CDPATH='' "$dir/bin/fm-cd-pretool-check.sh" --claude --command "$command" 2>&1); rc=$?
    expect_code 2 "$rc" 'non-literal assignment and redirection words withdraw the exemption'
  done
  pass 'cd-guard: split operands and expansion side effects cannot prove a home exemption'
}

test_denies_special_cd_operands() {
  local dir out rc
  dir="$TMP_ROOT/special-operand-home"
  make_primary_fixture "$dir" >/dev/null
  mkdir -p "$dir/-" "$dir/-P"
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd -' 2>&1); rc=$?
  expect_code 2 "$rc" 'cd - must deny even when a directory named - exists in the home'
  assert_contains "$out" '[persistent-cd]' 'special-operand deny must carry the reason code'
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd -P' 2>&1); rc=$?
  expect_code 2 "$rc" 'cd -P must deny even when a directory named -P exists in the home'
  pass 'cd-guard: special cd operands stay denied regardless of same-named directories'
}

# --- home carve-out: kept hazards ------------------------------------------

test_denies_foreign_worktree_target() {
  local base dir out rc
  base="$TMP_ROOT/foreign-base"
  dir="$TMP_ROOT/foreign-wt"
  make_child_worktree_fixture "$base" "$dir" >/dev/null
  mkdir -p "$dir/data"
  out=$("$CHECK" --claude --command "cd $dir/data" 2>&1); rc=$?
  expect_code 2 "$rc" 'cd-guard must deny a cd into a treehouse-shaped task worktree outside the home'
  assert_contains "$out" '[persistent-cd]' 'foreign-worktree deny must carry the reason code'
  pass 'cd-guard: still denies a cd into a foreign worktree'
}

test_denies_nested_checkout_inside_home() {
  local dir nested out rc
  dir="$TMP_ROOT/nested-home"
  make_primary_fixture "$dir" >/dev/null
  nested="$dir/vendor/other-repo"
  mkdir -p "$nested/sub"
  git init -q "$nested"
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command "cd $nested/sub" 2>&1); rc=$?
  expect_code 2 "$rc" 'cd-guard must deny a cd into a nested git checkout inside the home'
  assert_contains "$out" '[persistent-cd]' 'nested-checkout deny must carry the reason code'
  pass 'cd-guard: still denies a cd into a nested checkout other than the home checkout'
}

# --- primary-checkout scoping ----------------------------------------------

test_fires_in_secondmate_home() {
  local dir out rc
  dir=$(make_secondmate_fixture "$TMP_ROOT/secondmate")
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 2 "$rc" "cd-guard must fire in a secondmate's own primary session (unlike the turn-end guard)"
  assert_contains "$out" '[persistent-cd]' "secondmate-home block must carry the reason code"
  pass "cd-guard: fires in a secondmate home (its own primary session is a primary)"
}

test_inert_in_child_worktree() {
  local base dir out rc
  base="$TMP_ROOT/child-base"
  dir="$TMP_ROOT/child-wt"
  make_child_worktree_fixture "$base" "$dir" >/dev/null
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "cd-guard must be inert in a crewmate/scout linked worktree"
  [ -z "$out" ] || fail "cd-guard produced output in a child worktree: $out"
  pass "cd-guard: inert in a crewmate/scout task worktree (linked git worktree)"
}

test_inert_when_not_firstmate_repo() {
  local dir out rc
  dir="$TMP_ROOT/not-firstmate"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  install_cd_scripts "$dir"   # bin/ present but no AGENTS.md
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "cd-guard must be inert without AGENTS.md (not a firstmate checkout)"
  [ -z "$out" ] || fail "cd-guard produced output outside a firstmate checkout: $out"
  pass "cd-guard: inert in a non-firstmate repo (no AGENTS.md)"
}

test_inert_when_not_a_git_repo() {
  local dir out rc
  dir="$TMP_ROOT/no-git"
  mkdir -p "$dir"
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"   # AGENTS.md + bin/ but no git repo
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "cd-guard must be inert when the checkout is not a git repo"
  [ -z "$out" ] || fail "cd-guard produced output in a non-git dir: $out"
  pass "cd-guard: inert when not inside a git repo"
}

# --- end-to-end cwd-leak regression ----------------------------------------

test_e2e_cwd_leak_regression() {
  local sandbox home home_updated leaked out rc
  sandbox="$TMP_ROOT/e2e"
  home="$sandbox/home"
  mkdir -p "$home/data" "$home/projects/clone/data"
  printf '## In flight\n' > "$home/data/backlog.md"

  # Without the guard, the persistent primary shell's cwd leaks: a stray
  # `cd projects/clone` makes the next firstmate-owned backlog write land in the
  # clone, and the home backlog is never updated.
  (
    cd "$home" || fail "cannot enter home"
    cd projects/clone || fail "cannot enter clone"
    printf -- '- [x] demo done\n' >> data/backlog.md
  )
  home_updated=0
  grep -q 'demo done' "$home/data/backlog.md" && home_updated=1
  leaked=0
  grep -q 'demo done' "$home/projects/clone/data/backlog.md" 2>/dev/null && leaked=1
  [ "$home_updated" -eq 0 ] || fail "baseline: home backlog was updated, cwd leak did not reproduce"
  [ "$leaked" -eq 1 ] || fail "baseline: backlog write did not leak into the clone"

  # With the guard, the exact stray command is denied before it can run, so the
  # real harness never lets cwd leave the home.
  out=$("$CHECK" --claude --command 'cd projects/clone' 2>&1); rc=$?
  expect_code 2 "$rc" "guard must deny the stray persistent cd that caused the leak"
  assert_contains "$out" '[persistent-cd]' "leak-preventing block must carry the reason code"
  pass "cd-guard: reproduces the cwd leak and denies the exact command that causes it"
}

# --- fail-open transport behavior ------------------------------------------

test_fail_open_empty_stdin() {
  local out rc
  out=$("$CHECK" < /dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  pass "cd-guard: fails open on empty stdin"
}

test_fail_open_unparseable_json() {
  local out rc
  out=$(printf 'not json at all' | "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"
  pass "cd-guard: fails open on unparseable stdin JSON"
}

test_fail_open_missing_node() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # node deliberately absent from this PATH.
  out=$(PATH="$fakebin" "$CHECK" --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "transport must fail open when node is unavailable"
  [ -z "$out" ] || fail "transport produced output without node: $out"
  pass "cd-guard: fails open (never blocks) when node is missing"
}

test_fail_open_missing_jq_on_stdin() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh git dirname cat printf sed tr node; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # jq deliberately absent: the stdin transport cannot extract the command.
  out=$(printf '{"tool_input":{"command":"cd projects/foo"}}' | PATH="$fakebin" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "transport produced output without jq on the stdin path: $out"
  pass "cd-guard: fails open on the stdin path when jq is missing"
}

# --- prefilter fast path ----------------------------------------------------

test_prefilter_skips_node_without_cd_substring() {
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
  # No cd/pushd/popd substring: the prefilter must fast-allow before scoping or
  # the policy runtime is ever consulted.
  out=$(PATH="$fakebin" "$dir/bin/fm-cd-pretool-check.sh" --command 'git status' 2>&1); rc=$?
  expect_code 0 "$rc" "prefilter must fast-allow a command with no cd/pushd/popd substring"
  [ -z "$out" ] || fail "prefilter fast-allow produced output: $out"
  [ ! -e "$marker" ] || fail "prefilter fast-allow still invoked the node policy owner"
  pass "cd-guard: prefilter fast-allows (skips node) when no cd/pushd/popd substring is present"
}

# --- policy CLI contract ----------------------------------------------------

test_policy_cli_direct() {
  local policy
  policy="$ROOT/bin/fm-cd-command-policy.mjs"
  [ "$(node "$policy" --command 'cd projects/foo' | cut -f1)" = deny ] \
    || fail "policy CLI must deny a bare top-level cd"
  [ "$(node "$policy" --command 'git -C projects/foo status')" = allow ] \
    || fail "policy CLI must allow git -C"
  [ "$(node "$policy" --command '(cd projects/foo && pwd)')" = allow ] \
    || fail "policy CLI must allow a subshell-local cd"
  [ "$(node "$policy")" = allow ] \
    || fail "policy CLI must allow when no command is supplied"
  pass "cd-guard: fm-cd-command-policy.mjs CLI honors the deny/allow output contract"
}

# --- per-harness wiring -----------------------------------------------------

test_scripts_are_shellcheck_clean() {
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  shellcheck "$ROOT/bin/fm-cd-pretool-check.sh" >/dev/null 2>&1 \
    || fail "bin/fm-cd-pretool-check.sh is not shellcheck-clean"
  pass "bin/fm-cd-pretool-check.sh is shellcheck-clean"
}

test_exemption_proof_regressions
test_reachable_cwd_and_expansion_regressions
test_full_acceptance_matrix
test_home_forms_resolve_like_absolute
test_cdpath_denies_relative_targets
test_denies_special_cd_operands
test_denies_foreign_worktree_target
test_denies_nested_checkout_inside_home
test_fires_in_secondmate_home
test_inert_in_child_worktree
test_inert_when_not_firstmate_repo
test_inert_when_not_a_git_repo
test_e2e_cwd_leak_regression
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_node
test_fail_open_missing_jq_on_stdin
test_prefilter_skips_node_without_cd_substring
test_policy_cli_direct
test_scripts_are_shellcheck_clean
