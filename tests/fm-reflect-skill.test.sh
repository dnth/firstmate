#!/usr/bin/env bash
# Structural registration and boundary tests for the internal /reflect skill.
# These pin the discovery, separation, and authority contracts through the
# surfaces a harness actually reads - the file layout, YAML frontmatter, and
# the documented owner pointers - not the skill's prose body.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILLS_DIR="$ROOT/.agents/skills"
REFLECT="$SKILLS_DIR/reflect/SKILL.md"
STOW="$SKILLS_DIR/stow/SKILL.md"
TRIGGER_INDEX="$SKILLS_DIR/agent-skill-trigger-index/SKILL.md"
INVENTORY="$ROOT/docs/documentation-audiences.json"
AGENTS="$ROOT/AGENTS.md"
README="$ROOT/README.md"

# Print the lines strictly inside a SKILL.md's opening YAML frontmatter block;
# fails when the file does not open with a --- fence. Frontmatter is the
# registration interface the agent's skill loader consumes.
skill_frontmatter() {  # <skill-file>
  awk 'NR == 1 { if ($0 != "---") exit 1; next } $0 == "---" { exit } { print }' "$1"
}

test_reflect_lives_alongside_stow() {
  assert_present "$STOW" "internal stow skill is missing"
  [ -f "$STOW" ] && [ ! -L "$STOW" ] || fail "stow SKILL.md is not a regular file"
  assert_present "$REFLECT" ".agents/skills/reflect/SKILL.md is missing"
  [ -f "$REFLECT" ] && [ ! -L "$REFLECT" ] || fail "reflect SKILL.md is not a regular file"
  [ "$(dirname "$REFLECT")" = "$SKILLS_DIR/reflect" ] \
    || fail "reflect skill is not a sibling of stow under .agents/skills/"
  pass "reflect SKILL.md is a real file directly alongside .agents/skills/stow"
}

test_reflect_frontmatter_registers_internal_user_invocable() {
  local fm
  fm=$(skill_frontmatter "$REFLECT") || fail "reflect SKILL.md lacks a YAML frontmatter block"
  assert_contains "$fm" "name: reflect" "reflect frontmatter lost its skill name"
  assert_contains "$fm" "user-invocable: true" "reflect is not registered user-invocable"
  assert_contains "$fm" "internal: true" "reflect lost the internal metadata flag that hides it from installers"
  pass "reflect frontmatter registers an internal user-invocable skill named reflect"
}

test_reflect_trigger_surfaces_stay_consistent() {
  # The always-loaded owner pointer in AGENTS.md section 6 is the load trigger
  # for harnesses that never surface skill descriptions.
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the pattern.
  assert_grep '`/reflect`' "$AGENTS" "AGENTS.md lost the /reflect trigger pointer"
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the pattern.
  assert_grep 'load the `reflect` skill' "$AGENTS" \
    "AGENTS.md /reflect trigger does not name the skill to load"
  # User-invocable built-ins are listed in the README table.
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the pattern.
  assert_grep '| `/reflect`' "$README" "README built-in skills table lost the /reflect row"
  # The agent-only index indexes only non-captain-invocable skills; listing a
  # user-invocable skill there would misclassify it.
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the pattern.
  assert_no_grep '- `reflect`' "$TRIGGER_INDEX" \
    "agent-only trigger index listed the user-invocable reflect skill"
  # The maintained-prose inventory classifies the skill exactly once as
  # agent-runtime, which fm-doc-audience-check.sh enforces for every tracked .md.
  python3 - "$INVENTORY" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
entries = [s for s in data["surfaces"] if s["path"] == ".agents/skills/reflect/SKILL.md"]
if len(entries) != 1:
    sys.exit("inventory must classify .agents/skills/reflect/SKILL.md exactly once")
if entries[0]["audience"] != "agent-runtime":
    sys.exit("reflect SKILL.md must be classified agent-runtime")
PY
  pass "/reflect trigger surfaces: AGENTS.md pointer, README row, agent-only index exclusion, inventory entry"
}

test_reflect_and_stow_keep_separate_responsibilities() {
  # reflect names /stow as the durable-knowledge owner instead of claiming it.
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the pattern.
  assert_grep '`/stow` remains the owner of durable knowledge retention' "$REFLECT" \
    "reflect stopped delegating knowledge retention to /stow"
  assert_grep 'never performs a knowledge sweep' "$REFLECT" \
    "reflect claimed knowledge-sweep responsibility"
  # stow must not absorb reflection: the two loops stay complementary.
  assert_no_grep 'reflect' "$STOW" \
    "stow absorbed reflection responsibility; the skills must stay separate"
  pass "reflect owns system-improvement analysis while stow keeps knowledge retention"
}

test_reflect_grants_no_tracked_mutation_authority() {
  assert_grep 'it never edits shared tracked material itself' "$REFLECT" \
    "reflect lost its no-tracked-mutation boundary"
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the pattern.
  assert_grep 'It must not modify `AGENTS.md`' "$REFLECT" \
    "reflect stopped enumerating the tracked surfaces it cannot touch"
  assert_grep 'normal Firstmate task lifecycle' "$REFLECT" \
    "reflect no longer routes tracked improvements through the ordinary lifecycle"
  pass "reflect analyzes and proposes only; tracked changes stay behind the normal lifecycle"
}

test_reflect_lives_alongside_stow
test_reflect_frontmatter_registers_internal_user_invocable
test_reflect_trigger_surfaces_stay_consistent
test_reflect_and_stow_keep_separate_responsibilities
test_reflect_grants_no_tracked_mutation_authority
