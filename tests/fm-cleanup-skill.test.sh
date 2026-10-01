#!/usr/bin/env bash
# Contract tests for the internal /cleanup skill's executable registration surfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILLS_DIR="$ROOT/.agents/skills"
CLEANUP="$SKILLS_DIR/cleanup/SKILL.md"
STOW="$SKILLS_DIR/stow/SKILL.md"
TRIGGER_INDEX="$SKILLS_DIR/agent-skill-trigger-index/SKILL.md"
INVENTORY="$ROOT/docs/documentation-audiences.json"
AGENTS="$ROOT/AGENTS.md"
README="$ROOT/README.md"

test_cleanup_lives_alongside_stow() {
  assert_present "$STOW" "internal stow skill is missing"
  [ -f "$STOW" ] && [ ! -L "$STOW" ] || fail "stow SKILL.md is not a regular file"
  assert_present "$CLEANUP" ".agents/skills/cleanup/SKILL.md is missing"
  [ -f "$CLEANUP" ] && [ ! -L "$CLEANUP" ] || fail "cleanup SKILL.md is not a regular file"
  [ "$(dirname "$CLEANUP")" = "$SKILLS_DIR/cleanup" ] \
    || fail "cleanup skill is not a sibling of stow under .agents/skills/"
  pass "cleanup SKILL.md is a real file directly alongside .agents/skills/stow"
}

test_cleanup_contract_surfaces() {
  "$ROOT/bin/fm-doc-audience-check.sh" >/dev/null \
    || fail "documentation audience consumer rejected the cleanup registration"
  python3 - "$CLEANUP" "$TRIGGER_INDEX" "$INVENTORY" "$AGENTS" "$README" <<'PY' || fail "cleanup contract surfaces are inconsistent"
import json
import re
import sys
from pathlib import Path

cleanup, trigger_index, inventory, agents, readme = map(Path, sys.argv[1:])


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


fields = frontmatter(cleanup)
if fields.get("name") != "cleanup":
    raise SystemExit("frontmatter name is not cleanup")
if fields.get("user-invocable") is not True:
    raise SystemExit("cleanup must be user-invocable")
if fields.get("metadata", {}).get("internal") is not True:
    raise SystemExit("cleanup must be marked internal")
if not fields.get("description") or "/cleanup" not in fields["description"]:
    raise SystemExit("cleanup description is missing or does not state the /cleanup trigger")

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
agent_triggers = [line for line in agent_section if line.startswith("When the captain invokes `/cleanup`, load the `cleanup` skill")]
if len(agent_triggers) != 1:
    raise SystemExit("AGENTS.md must expose one /cleanup load trigger")

readme_lines = readme.read_text(encoding="utf-8").splitlines()
try:
    table_start = next(i for i, line in enumerate(readme_lines) if line == "## Built-in skills")
except StopIteration as exc:
    raise SystemExit("README built-in skills section is missing") from exc
table_rows = [line for line in readme_lines[table_start:] if line.startswith("| `/")]
cleanup_rows = [line.split("|", 2) for line in table_rows if line.split("|", 2)[1].strip() == "`/cleanup`"]
if len(cleanup_rows) != 1 or not cleanup_rows[0][2].strip():
    raise SystemExit("README must contain one non-empty /cleanup built-in skill row")

index_text = trigger_index.read_text(encoding="utf-8")
captain_marker = "# Captain-invocable skills"
if captain_marker not in index_text:
    raise SystemExit("trigger index is missing the captain-invocable skills section")
agent_only_part, captain_part = index_text.split(captain_marker, 1)
agent_only_skills = re.findall(r"^- `([^`]+)` -", agent_only_part, re.MULTILINE)
captain_skills = re.findall(r"^- `([^`]+)` -", captain_part, re.MULTILINE)
if "cleanup" in agent_only_skills:
    raise SystemExit("user-invocable cleanup must not be in the agent-only trigger list")
if "cleanup" not in captain_skills:
    raise SystemExit("cleanup must be indexed in the captain-invocable skills section")

data = json.loads(inventory.read_text(encoding="utf-8"))
entries = [entry for entry in data["surfaces"] if entry.get("path") == ".agents/skills/cleanup/SKILL.md"]
if len(entries) != 1 or entries[0].get("audience") != "agent-runtime":
    raise SystemExit("cleanup must have one agent-runtime inventory entry")
PY
  pass "cleanup registration, trigger pointers, index section, and inventory classification are valid"
}

test_cleanup_lives_alongside_stow
test_cleanup_contract_surfaces
