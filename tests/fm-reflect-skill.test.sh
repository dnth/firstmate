#!/usr/bin/env bash
# Contract tests for the internal /reflect skill's executable registration surfaces.
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

test_reflect_lives_alongside_stow() {
  assert_present "$STOW" "internal stow skill is missing"
  [ -f "$STOW" ] && [ ! -L "$STOW" ] || fail "stow SKILL.md is not a regular file"
  assert_present "$REFLECT" ".agents/skills/reflect/SKILL.md is missing"
  [ -f "$REFLECT" ] && [ ! -L "$REFLECT" ] || fail "reflect SKILL.md is not a regular file"
  [ "$(dirname "$REFLECT")" = "$SKILLS_DIR/reflect" ] \
    || fail "reflect skill is not a sibling of stow under .agents/skills/"
  pass "reflect SKILL.md is a real file directly alongside .agents/skills/stow"
}

test_reflect_contract_surfaces() {
  "$ROOT/bin/fm-doc-audience-check.sh" >/dev/null \
    || fail "documentation audience consumer rejected the reflect registration"
  python3 - "$REFLECT" "$TRIGGER_INDEX" "$INVENTORY" "$AGENTS" "$README" <<'PY' || fail "reflect contract surfaces are inconsistent"
import json
import re
import sys
from pathlib import Path

reflect, trigger_index, inventory, agents, readme = map(Path, sys.argv[1:])


def scalar(value):
    value = value.strip()
    if value in {"true", "false"}:
        return value == "true"
    return value.strip("'\"")


def frontmatter(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        raise SystemExit("skill frontmatter must start with ---")
    fields = {}
    nested = {}
    closing = None
    for index, line in enumerate(lines[1:], start=1):
        if line == "---":
            closing = index
            break
        if not line.strip() or line.startswith(" "):
            match = re.match(r"^\s{2}([\w-]+):\s*(.+)$", line)
            if match:
                nested[match.group(1)] = scalar(match.group(2))
            continue
        match = re.match(r"^([\w-]+):\s*(.*)$", line)
        if not match:
            raise SystemExit(f"invalid frontmatter line: {line!r}")
        key, value = match.groups()
        fields[key] = scalar(value) if value not in {">", ">-", "|", "|-"} else value
    if closing is None:
        raise SystemExit("skill frontmatter is missing its closing ---")
    if fields.get("description") in {">", ">-", "|", "|-"}:
        fields["description"] = "block"
    fields["metadata"] = nested
    return fields


fields = frontmatter(reflect)
if fields.get("name") != "reflect":
    raise SystemExit("frontmatter name is not reflect")
if fields.get("user-invocable") is not True:
    raise SystemExit("reflect must be user-invocable")
if fields.get("metadata", {}).get("internal") is not True:
    raise SystemExit("reflect must be marked internal")
if not fields.get("description"):
    raise SystemExit("reflect description is missing")

agent_lines = agents.read_text(encoding="utf-8").splitlines()
try:
    section_start = next(i for i, line in enumerate(agent_lines) if line.startswith("## 6."))
    section_end = next(
        (i for i in range(section_start + 1, len(agent_lines)) if agent_lines[i].startswith("## ")),
        len(agent_lines),
    )
except StopIteration as exc:
    raise SystemExit("AGENTS.md section 6 is missing") from exc
agent_section = agent_lines[section_start:section_end]
agent_triggers = [line for line in agent_section if line.startswith("When the captain invokes `/reflect`, load the `reflect` skill")]
if len(agent_triggers) != 1:
    raise SystemExit("AGENTS.md must expose one /reflect load trigger")

readme_lines = readme.read_text(encoding="utf-8").splitlines()
try:
    table_start = next(i for i, line in enumerate(readme_lines) if line == "## Built-in skills")
except StopIteration as exc:
    raise SystemExit("README built-in skills section is missing") from exc
table_rows = [line for line in readme_lines[table_start:] if line.startswith("| `/")]
reflect_rows = [line.split("|", 2) for line in table_rows if line.split("|", 2)[1].strip() == "`/reflect`"]
if len(reflect_rows) != 1 or not reflect_rows[0][2].strip():
    raise SystemExit("README must contain one non-empty /reflect built-in skill row")

indexed_skills = re.findall(r"^- `([^`]+)` -", trigger_index.read_text(encoding="utf-8"), re.MULTILINE)
if "reflect" in indexed_skills:
    raise SystemExit("user-invocable reflect must not be in the agent-only trigger index")

data = json.loads(inventory.read_text(encoding="utf-8"))
entries = [entry for entry in data["surfaces"] if entry.get("path") == ".agents/skills/reflect/SKILL.md"]
if len(entries) != 1 or entries[0].get("audience") != "agent-runtime":
    raise SystemExit("reflect must have one agent-runtime inventory entry")
PY
  pass "reflect registration, trigger pointers, index exclusion, and inventory classification are valid"
}

test_reflect_lives_alongside_stow
test_reflect_contract_surfaces
