#!/usr/bin/env bash
# Install or remove Firstmate's guarded Hermes crew lifecycle bridge.
#
# This command is the sole owner of the text-level edit to the active Hermes
# config.yaml. It asks the selected Hermes executable for its profile-scoped
# config path, validates the existing YAML, and adds marker-delimited entries
# to the existing hooks and plugins.enabled mappings without serializing or
# reformatting foreign config. Missing, malformed, symlinked, partially marked,
# or surprising config is refused without a config write.
#
# The shell hook remains the one lifecycle-event handler. The enabled
# firstmate-lifecycle plugin invokes it from persistent TUI gateway turns,
# while classic/headless Hermes can invoke the same handler through config
# hooks. on_session_start records a new resumable session id, pre_llm_call
# acknowledges every initial or resumed turn and marks semantic busy state,
# and on_session_end marks semantic idle and touches state/<id>.turn-ended.
# A worktree token must resolve through the profile-private Firstmate registry
# before any event can act.
#
# Usage:
#   fm-hermes-turnend-hook.sh install
#   fm-hermes-turnend-hook.sh remove
#
# HERMES_BIN may select the exact executable. FM_HERMES_PYTHON is a test-only
# override for the Python interpreter used to validate YAML.
set -u

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,23{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *)
    printf 'usage: %s install|remove\n' "${0##*/}" >&2
    exit 2
    ;;
esac

HERMES_BIN=${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}
if [ -z "$HERMES_BIN" ] || [ ! -x "$HERMES_BIN" ]; then
  printf 'fm-hermes-turnend-hook: refused: Hermes executable is unavailable.\n' >&2
  exit 1
fi
CONFIG=$("$HERMES_BIN" config path 2>/dev/null) || {
  printf 'fm-hermes-turnend-hook: refused: Hermes could not report its config path.\n' >&2
  exit 1
}
case "$CONFIG" in
  /*/config.yaml) ;;
  *)
    printf 'fm-hermes-turnend-hook: refused: Hermes reported an unexpected config path: %s.\n' "$CONFIG" >&2
    exit 1
    ;;
esac
HERMES_HOME=${CONFIG%/config.yaml}

PYTHON_BIN=${FM_HERMES_PYTHON:-}
if [ -z "$PYTHON_BIN" ]; then
  if command -v python3 >/dev/null 2>&1; then
    HERMES_REAL=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$HERMES_BIN" 2>/dev/null || true)
  else
    HERMES_REAL=
  fi
  if [ -n "$HERMES_REAL" ] && [ -x "$(dirname "$HERMES_REAL")/python3" ]; then
    PYTHON_BIN=$(dirname "$HERMES_REAL")/python3
  elif command -v python3 >/dev/null 2>&1 \
    && python3 -c 'import yaml' >/dev/null 2>&1; then
    PYTHON_BIN=$(command -v python3)
  fi
fi
if [ -z "$PYTHON_BIN" ] || [ ! -x "$PYTHON_BIN" ]; then
  printf 'fm-hermes-turnend-hook: refused: no Python interpreter with PyYAML is available.\n' >&2
  exit 1
fi
if ! "$PYTHON_BIN" -c 'import yaml' >/dev/null 2>&1; then
  printf 'fm-hermes-turnend-hook: refused: the selected Python interpreter has no PyYAML.\n' >&2
  exit 1
fi
if [ "$ACTION" = install ] && ! command -v jq >/dev/null 2>&1; then
  printf 'fm-hermes-turnend-hook: refused: jq is required by the installed Hermes lifecycle hook.\n' >&2
  exit 1
fi

"$PYTHON_BIN" - "$ACTION" "$HERMES_HOME" <<'PY'
import json
import os
import re
import shutil
import stat
import sys
import tempfile

import yaml
from yaml.nodes import MappingNode, ScalarNode, SequenceNode

ACTION = sys.argv[1]
HERMES_HOME = sys.argv[2]
CONFIG = os.path.join(HERMES_HOME, "config.yaml")
HOOK = os.path.join(HERMES_HOME, "fm-turn-end.sh")
REGISTRY = os.path.join(HERMES_HOME, "fm-turn-end.d")
PLUGIN_NAME = "firstmate-lifecycle"
PLUGIN_DIR = os.path.join(HERMES_HOME, "plugins", PLUGIN_NAME)
PLUGIN_MANIFEST = os.path.join(PLUGIN_DIR, "plugin.yaml")
PLUGIN_INIT = os.path.join(PLUGIN_DIR, "__init__.py")
TOKEN_NAME = re.compile(r"fm\.[A-Za-z0-9]{12}\Z")
EVENTS = ("on_session_start", "pre_llm_call", "on_session_end")
HOOK_TIMEOUT = 10
TOP_BEGIN = "# BEGIN FIRSTMATE HERMES HOOKS"
TOP_END = "# END FIRSTMATE HERMES HOOKS"
PLUGIN_BEGIN = "# BEGIN FIRSTMATE HERMES PLUGIN ENABLE"
PLUGIN_END = "# END FIRSTMATE HERMES PLUGIN ENABLE"
IDENTIFIER = "FIRSTMATE HERMES"
OWNS_PRECEDING_NEWLINE = " (OWNS PRECEDING NEWLINE)"

HOOK_BYTES = b'''#!/usr/bin/env bash
# Firstmate Hermes crew lifecycle hook. Managed by fm-hermes-turnend-hook.sh.
# Every path is deliberately silent and exits zero.
set +e
exec >/dev/null 2>&1
payload=
IFS= read -r payload || [ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
event=$(jq -er '.hook_event_name | strings | select(. == "on_session_start" or . == "pre_llm_call" or . == "on_session_end")' <<< "$payload" 2>/dev/null) || exit 0
workspace=$(jq -er '.cwd | strings | select(length > 0)' <<< "$payload" 2>/dev/null) || exit 0
session_id=$(jq -er '.session_id | strings | select(length > 0 and length <= 200)' <<< "$payload" 2>/dev/null) || exit 0
pointer="$workspace/.fm-hermes-turnend"
[ -f "$pointer" ] && [ ! -L "$pointer" ] || exit 0
first=
IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || exit 0
case "$first" in token=*) token=${first#token=} ;; *) exit 0 ;; esac
case "$token" in fm.????????????) : ;; *) exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
hermes_home=${HERMES_HOME:-${HOME:-}/.hermes}
[ -n "$hermes_home" ] || exit 0
registry="$hermes_home/fm-turn-end.d/$token"
[ -f "$registry" ] && [ ! -L "$registry" ] || exit 0
turnend=$(jq -er '.turnend | strings' "$registry" 2>/dev/null) || exit 0
session_file=$(jq -er '.session_file | strings' "$registry" 2>/dev/null) || exit 0
started=$(jq -er '.started | strings' "$registry" 2>/dev/null) || exit 0
root=$(jq -er '.root | strings' "$registry" 2>/dev/null) || exit 0
state=$(jq -er '.state | strings' "$registry" 2>/dev/null) || exit 0
id=$(jq -er '.id | strings | select(test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))' "$registry" 2>/dev/null) || exit 0
gen=$(jq -er '.gen | strings | select(test("^[A-Za-z0-9._-]+$"))' "$registry" 2>/dev/null) || exit 0
[ "$turnend" = "$state/$id.turn-ended" ] || exit 0
[ "$session_file" = "$state/$id.hermes-session" ] || exit 0
[ "$started" = "$state/$id.hermes-started" ] || exit 0
[ -x "$root/bin/fm-busy-event.sh" ] || exit 0
session_matches() {
  [ -f "$session_file" ] && [ ! -L "$session_file" ] || return 1
  current=$(cat "$session_file" 2>/dev/null) || return 1
  [ "$current" = "$session_id" ]
}
# A start acknowledgement is compared against a pre-send snapshot by content
# (bin/fm-send.sh), so two consecutive turns of the same task MUST NOT be able
# to produce identical bytes. Session id and event are stable by construction
# for a resumed task and the pid is reusable, so every write carries a fresh
# 128-bit nonce that no other write can repeat.
start_nonce() {
  local n
  n=$(LC_ALL=C od -An -v -tx1 -N 16 /dev/urandom 2>/dev/null | tr -d ' \\n')
  case "$n" in
    ????????????????????????????????) printf '%s' "$n"; return 0 ;;
  esac
  printf '%s.%s.%s.%s' "$$" "${SECONDS:-0}" "${RANDOM:-0}" "${RANDOM:-0}"
}
capture_session() {
  if [ -e "$session_file" ] || [ -L "$session_file" ]; then
    session_matches
    return
  fi
  tmp=$(mktemp "$state/.${id}.hermes-session.XXXXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || true
  if printf '%s\n' "$session_id" > "$tmp" 2>/dev/null \
    && ln "$tmp" "$session_file" 2>/dev/null; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null || true
  session_matches
}
case "$event" in
  on_session_start)
    capture_session || true
    ;;
  pre_llm_call)
    if session_matches \
      && "$root/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" --source hermes-hook --event "$event" >/dev/null 2>&1; then
      started_tmp=$(mktemp "$state/.${id}.hermes-started.XXXXXXXX" 2>/dev/null) || exit 0
      chmod 0600 "$started_tmp" 2>/dev/null || true
      if ! printf '%s:%s:%s:%s\\n' "$session_id" "$event" "$$" "$(start_nonce)" > "$started_tmp" 2>/dev/null \
        || ! mv -f "$started_tmp" "$started" 2>/dev/null; then
        rm -f -- "$started_tmp" 2>/dev/null || true
      fi
    fi
    ;;
  on_session_end)
    session_matches || exit 0
    touch -- "$turnend" 2>/dev/null || true
    "$root/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" --source hermes-hook --event session-end >/dev/null 2>&1 || true
    ;;
esac
exit 0
'''

PLUGIN_MANIFEST_BYTES = b'''name: firstmate-lifecycle
version: "1.0"
description: Guarded Firstmate lifecycle bridge for persistent Hermes TUI crews.
hooks:
  - on_session_start
  - pre_llm_call
  - on_session_end
'''

PLUGIN_INIT_BYTES = b'''"""Guarded Firstmate lifecycle bridge for persistent Hermes TUI crews."""

import json
import os
import subprocess
from pathlib import Path


_EVENTS = ("on_session_start", "pre_llm_call", "on_session_end")


def _forward(event):
    def callback(**kwargs):
        home = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
        hook = home / "fm-turn-end.sh"
        if not hook.is_file() or hook.is_symlink():
            return None
        payload = dict(kwargs)
        payload["hook_event_name"] = event
        payload["cwd"] = str(Path.cwd())
        try:
            subprocess.run(
                [str(hook)],
                input=json.dumps(payload) + "\\n",
                text=True,
                timeout=10,
                check=False,
                env=os.environ.copy(),
            )
        except Exception:
            pass
        return None

    return callback


def register(ctx):
    for event in _EVENTS:
        ctx.register_hook(event, _forward(event))
'''


def refuse(reason: str) -> None:
    print(f"fm-hermes-turnend-hook: refused: {reason}", file=sys.stderr)
    raise SystemExit(1)


def regular_not_symlink(path: str, label: str) -> os.stat_result:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        refuse(f"{label} is missing at {path}.")
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        refuse(f"{label} is not a regular non-symlink file at {path}.")
    return info


def parse_yaml(data: bytes, label: str):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        refuse(f"{label} is not UTF-8: {error}.")
    try:
        parsed = yaml.safe_load(text)
        node = yaml.compose(text, Loader=yaml.SafeLoader)
    except yaml.YAMLError as error:
        refuse(f"{label} is malformed YAML: {error}.")
    if parsed is None:
        parsed = {}
    if not isinstance(parsed, dict) or not isinstance(node, MappingNode):
        refuse(f"{label} must contain a top-level YAML mapping.")
    hooks = parsed.get("hooks")
    if hooks is not None and not isinstance(hooks, dict):
        refuse(f"{label} has an unexpected non-mapping hooks value.")
    return text, parsed, node


def mapping_entries(node: MappingNode):
    result = {}
    for key_node, value_node in node.value:
        if isinstance(key_node, ScalarNode):
            key = str(key_node.value)
            if key in result:
                refuse(f"config.yaml has a duplicate {key!r} mapping key.")
            result[key] = (key_node, value_node)
    return result


def marker_state(lines: list[str]):
    regions = []
    stack = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if "FIRSTMATE HERMES PLUGIN ENABLE" in stripped:
            continue
        if "BEGIN FIRSTMATE HERMES" in stripped:
            if stack is not None:
                refuse("config.yaml has nested Firstmate Hermes region markers.")
            stack = (index, stripped)
        elif "END FIRSTMATE HERMES" in stripped:
            if stack is None:
                refuse("config.yaml has a partial Firstmate Hermes region marker.")
            regions.append((stack[0], index, stack[1], stripped))
            stack = None
        elif IDENTIFIER in stripped:
            refuse("config.yaml has an altered Firstmate Hermes region marker.")
    if stack is not None:
        refuse("config.yaml has a partial Firstmate Hermes region marker.")
    if len(regions) not in (0, 1, 3):
        refuse("config.yaml has duplicated Firstmate Hermes region markers.")
    return regions


def plugin_marker_state(lines: list[str]):
    regions = []
    stack = None
    valid_begins = {
        PLUGIN_BEGIN,
        PLUGIN_BEGIN + OWNS_PRECEDING_NEWLINE,
        PLUGIN_BEGIN + " (OWNS ENABLED)",
        PLUGIN_BEGIN + " (OWNS ENABLED)" + OWNS_PRECEDING_NEWLINE,
    }
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith(PLUGIN_BEGIN):
            if stripped not in valid_begins:
                refuse("config.yaml has an altered Firstmate Hermes plugin marker.")
            if stack is not None:
                refuse("config.yaml has nested Firstmate Hermes plugin markers.")
            stack = (index, stripped)
        elif stripped == PLUGIN_END:
            if stack is None:
                refuse("config.yaml has a partial Firstmate Hermes plugin marker.")
            regions.append((stack[0], index, stack[1], stripped))
            stack = None
        elif "FIRSTMATE HERMES PLUGIN" in stripped:
            refuse("config.yaml has an altered Firstmate Hermes plugin marker.")
    if stack is not None:
        refuse("config.yaml has a partial Firstmate Hermes plugin marker.")
    if len(regions) not in (0, 1):
        refuse("config.yaml has duplicated Firstmate Hermes plugin markers.")
    return regions


def event_marker(event: str, owns_event: bool, begin: bool) -> str:
    edge = "BEGIN" if begin else "END"
    suffix = " (OWNS EVENT)" if owns_event else ""
    return f"# {edge} FIRSTMATE HERMES {event.upper()} HOOK{suffix}"


def event_entry(command: str, indent: str) -> list[str]:
    quoted = json.dumps(command)
    return [
        f"{indent}- command: {quoted}\n",
        f"{indent}  timeout: {HOOK_TIMEOUT}\n",
    ]


def hook_block(command: str, begin_marker: str = TOP_BEGIN) -> list[str]:
    quoted = json.dumps(command)
    return [
        f"{begin_marker}\n",
        "hooks:\n",
        "  on_session_start:\n",
        f"    - command: {quoted}\n",
        f"      timeout: {HOOK_TIMEOUT}\n",
        "  pre_llm_call:\n",
        f"    - command: {quoted}\n",
        f"      timeout: {HOOK_TIMEOUT}\n",
        "  on_session_end:\n",
        f"    - command: {quoted}\n",
        f"      timeout: {HOOK_TIMEOUT}\n",
        f"{TOP_END}\n",
    ]


def verify_installed_config(data: bytes, command: str) -> None:
    _text, parsed, _node = parse_yaml(data, "updated config.yaml")
    hooks = parsed.get("hooks") or {}
    for event in EVENTS:
        entries = hooks.get(event)
        if not isinstance(entries, list):
            refuse(f"updated config.yaml did not retain a list for hooks.{event}.")
        matches = [entry for entry in entries if isinstance(entry, dict) and entry.get("command") == command]
        if len(matches) != 1 or matches[0].get("timeout") != HOOK_TIMEOUT:
            refuse(f"updated config.yaml did not contain exactly one Firstmate hooks.{event} entry.")


def verify_plugin_enabled_config(data: bytes) -> None:
    _text, parsed, _node = parse_yaml(data, "updated config.yaml")
    plugins = parsed.get("plugins") or {}
    if not isinstance(plugins, dict):
        refuse("updated config.yaml did not retain a mapping for plugins.")
    enabled = plugins.get("enabled", [])
    if enabled is None:
        enabled = []
    if not isinstance(enabled, list):
        refuse("updated config.yaml did not retain a list for plugins.enabled.")
    if enabled.count(PLUGIN_NAME) != 1:
        refuse("updated config.yaml did not contain exactly one Firstmate lifecycle plugin enable entry.")
    disabled = plugins.get("disabled", [])
    if disabled is None:
        disabled = []
    if not isinstance(disabled, list):
        refuse("updated config.yaml did not retain a list for plugins.disabled.")
    if PLUGIN_NAME in disabled:
        refuse("config.yaml explicitly disables the Firstmate lifecycle plugin.")


def upgrade_owned_timeouts(original: bytes, regions) -> bytes:
    text = original.decode("utf-8")
    lines = text.splitlines(keepends=True)
    found = 0
    for start, end, _begin, _finish in regions:
        for index in range(start + 1, end):
            body = lines[index].rstrip("\r\n")
            ending = lines[index][len(body):]
            if body.strip() not in ("timeout: 2", f"timeout: {HOOK_TIMEOUT}"):
                continue
            indent = body[: len(body) - len(body.lstrip())]
            lines[index] = f"{indent}timeout: {HOOK_TIMEOUT}{ending}"
            found += 1
    if found != len(EVENTS):
        refuse("config.yaml has an unexpected Firstmate Hermes timeout shape.")
    return "".join(lines).encode()


def install_config(original: bytes, command: str) -> bytes:
    text, _parsed, root = parse_yaml(original, "config.yaml")
    lines = text.splitlines(keepends=True)
    regions = marker_state(lines)
    if regions:
        if len(regions) == 1 and regions[0][2].startswith(TOP_BEGIN) and regions[0][3] == TOP_END:
            candidate = upgrade_owned_timeouts(original, regions)
        elif len(regions) == 3:
            candidate = upgrade_owned_timeouts(original, regions)
        else:
            refuse("config.yaml has an unexpected Firstmate Hermes marker shape.")
        verify_installed_config(candidate, command)
        return candidate

    top = mapping_entries(root)
    if "hooks" not in top:
        owns_newline = bool(original and not original.endswith(b"\n"))
        prefix = b"\n" if owns_newline else b""
        begin_marker = TOP_BEGIN + (OWNS_PRECEDING_NEWLINE if owns_newline else "")
        candidate = original + prefix + "".join(hook_block(command, begin_marker)).encode()
        verify_installed_config(candidate, command)
        return candidate

    _hooks_key, hooks_node = top["hooks"]
    if isinstance(hooks_node, ScalarNode) and hooks_node.tag.endswith(":null"):
        hook_entries = {}
        insertion_default = hooks_node.end_mark.line
    elif isinstance(hooks_node, MappingNode) and not hooks_node.flow_style:
        hook_entries = mapping_entries(hooks_node)
        insertion_default = hooks_node.end_mark.line
    else:
        refuse("config.yaml hooks must use a block-style mapping.")

    additions: dict[int, list[str]] = {}
    for event in EVENTS:
        if event not in hook_entries:
            insertion = insertion_default
            block = [f"  {event_marker(event, True, True)}\n", f"  {event}:\n"]
            block.extend(event_entry(command, "    "))
            block.append(f"  {event_marker(event, True, False)}\n")
        else:
            _key_node, value_node = hook_entries[event]
            if not isinstance(value_node, SequenceNode) or value_node.flow_style:
                refuse(f"config.yaml hooks.{event} must use a block-style list.")
            insertion = value_node.end_mark.line
            block = [f"    {event_marker(event, False, True)}\n"]
            block.extend(event_entry(command, "    "))
            block.append(f"    {event_marker(event, False, False)}\n")
        additions.setdefault(insertion, []).extend(block)

    if text and not text.endswith("\n"):
        final_insertion = len(lines)
        if final_insertion not in additions:
            refuse("config.yaml has no safe line boundary for the Firstmate Hermes hook entries.")
        lines[-1] += "\n"
        additions[final_insertion][0] = additions[final_insertion][0].rstrip("\n") + OWNS_PRECEDING_NEWLINE + "\n"

    for insertion in sorted(additions, reverse=True):
        lines[insertion:insertion] = additions[insertion]
    candidate = "".join(lines).encode()
    verify_installed_config(candidate, command)
    return candidate


def install_plugin_config(original: bytes) -> bytes:
    text, parsed, root = parse_yaml(original, "config.yaml")
    lines = text.splitlines(keepends=True)
    regions = plugin_marker_state(lines)
    plugins = parsed.get("plugins") or {}
    if isinstance(plugins, dict):
        disabled = plugins.get("disabled", [])
        if disabled is None:
            disabled = []
        if not isinstance(disabled, list):
            refuse("config.yaml plugins.disabled must use a list.")
        if PLUGIN_NAME in disabled:
            refuse("config.yaml explicitly disables the Firstmate lifecycle plugin.")
        enabled = plugins.get("enabled", [])
        if enabled is None:
            enabled = []
        if isinstance(enabled, list) and enabled.count(PLUGIN_NAME) == 1:
            if regions:
                verify_plugin_enabled_config(original)
            return original
        if isinstance(enabled, list) and enabled.count(PLUGIN_NAME) > 1:
            refuse("config.yaml contains duplicate Firstmate lifecycle plugin enable entries.")
    if regions:
        refuse("config.yaml has a Firstmate Hermes plugin marker without its enable entry.")

    top = mapping_entries(root)
    additions: dict[int, list[str]] = {}
    if "plugins" not in top:
        owns_newline = bool(original and not original.endswith(b"\n"))
        prefix = b"\n" if owns_newline else b""
        begin = PLUGIN_BEGIN + (OWNS_PRECEDING_NEWLINE if owns_newline else "")
        block = [
            f"{begin}\n",
            "plugins:\n",
            "  enabled:\n",
            f"    - {PLUGIN_NAME}\n",
            f"{PLUGIN_END}\n",
        ]
        candidate = original + prefix + "".join(block).encode()
        verify_plugin_enabled_config(candidate)
        return candidate

    _plugins_key, plugins_node = top["plugins"]
    if isinstance(plugins_node, ScalarNode) and plugins_node.tag.endswith(":null"):
        plugin_entries = {}
        insertion_default = plugins_node.end_mark.line
    elif isinstance(plugins_node, MappingNode) and not plugins_node.flow_style:
        plugin_entries = mapping_entries(plugins_node)
        insertion_default = plugins_node.end_mark.line
    else:
        refuse("config.yaml plugins must use a block-style mapping.")

    if "enabled" not in plugin_entries:
        insertion = insertion_default
        block = [
            f"  {PLUGIN_BEGIN} (OWNS ENABLED)\n",
            "  enabled:\n",
            f"    - {PLUGIN_NAME}\n",
            f"  {PLUGIN_END}\n",
        ]
    else:
        _enabled_key, enabled_node = plugin_entries["enabled"]
        if not isinstance(enabled_node, SequenceNode) or enabled_node.flow_style:
            refuse("config.yaml plugins.enabled must use a block-style list.")
        insertion = enabled_node.end_mark.line
        block = [
            f"    {PLUGIN_BEGIN}\n",
            f"    - {PLUGIN_NAME}\n",
            f"    {PLUGIN_END}\n",
        ]
    additions[insertion] = block

    if text and not text.endswith("\n"):
        final_insertion = len(lines)
        if final_insertion not in additions:
            refuse("config.yaml has no safe line boundary for the Firstmate Hermes plugin entry.")
        lines[-1] += "\n"
        additions[final_insertion][0] = additions[final_insertion][0].rstrip("\n") + OWNS_PRECEDING_NEWLINE + "\n"

    for insertion in sorted(additions, reverse=True):
        lines[insertion:insertion] = additions[insertion]
    candidate = "".join(lines).encode()
    verify_plugin_enabled_config(candidate)
    return candidate


def remove_config(original: bytes) -> bytes:
    text, _parsed, _root = parse_yaml(original, "config.yaml")
    lines = text.splitlines(keepends=True)
    regions = marker_state(lines)
    if not regions:
        return original
    owns_newline_at_eof = any(
        OWNS_PRECEDING_NEWLINE in begin and end == len(lines) - 1
        for _start, end, begin, _finish in regions
    )
    for start, end, _begin, _finish in sorted(regions, reverse=True):
        del lines[start : end + 1]
    candidate = "".join(lines).encode()
    if owns_newline_at_eof and candidate.endswith(b"\n"):
        candidate = candidate[:-1]
    parse_yaml(candidate, "config.yaml after Firstmate hook removal")
    return candidate


def remove_plugin_config(original: bytes) -> bytes:
    text, _parsed, _root = parse_yaml(original, "config.yaml")
    lines = text.splitlines(keepends=True)
    regions = plugin_marker_state(lines)
    if not regions:
        return original
    start, end, begin, _finish = regions[0]
    owns_newline_at_eof = OWNS_PRECEDING_NEWLINE in begin and end == len(lines) - 1
    del lines[start : end + 1]
    candidate = "".join(lines).encode()
    if owns_newline_at_eof and candidate.endswith(b"\n"):
        candidate = candidate[:-1]
    parse_yaml(candidate, "config.yaml after Firstmate plugin removal")
    return candidate


def atomic_write(path: str, data: bytes, mode: int) -> None:
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except Exception:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def validate_plugin_cache() -> None:
    pycache = os.path.join(PLUGIN_DIR, "__pycache__")
    if not os.path.lexists(pycache):
        return
    info = os.lstat(pycache)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        refuse(f"Firstmate Hermes plugin bytecode cache is unexpected at {pycache}.")
    for name in os.listdir(pycache):
        path = os.path.join(pycache, name)
        child = os.lstat(path)
        if not re.fullmatch(r"__init__\..+\.pyc", name) or stat.S_ISLNK(child.st_mode) or not stat.S_ISREG(child.st_mode):
            refuse(f"Firstmate Hermes plugin bytecode cache contains an unexpected entry at {path}.")


def validate_owned_files_for_remove() -> None:
    if os.path.lexists(HOOK):
        info = regular_not_symlink(HOOK, "Firstmate Hermes hook script")
        with open(HOOK, "rb") as stream:
            if stream.read() != HOOK_BYTES:
                refuse(f"Firstmate Hermes hook script has unexpected content at {HOOK}.")
        if stat.S_IMODE(info.st_mode) & 0o077:
            refuse(f"Firstmate Hermes hook script has unexpectedly broad permissions at {HOOK}.")
    if os.path.lexists(REGISTRY):
        info = os.lstat(REGISTRY)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            refuse(f"Firstmate Hermes registry is not a regular directory at {REGISTRY}.")
        for name in os.listdir(REGISTRY):
            path = os.path.join(REGISTRY, name)
            child = os.lstat(path)
            if not TOKEN_NAME.fullmatch(name) or stat.S_ISLNK(child.st_mode) or not stat.S_ISREG(child.st_mode):
                refuse(f"Firstmate Hermes registry contains an unexpected entry at {path}.")
    if os.path.lexists(PLUGIN_DIR):
        info = os.lstat(PLUGIN_DIR)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            refuse(f"Firstmate Hermes plugin is not a regular directory at {PLUGIN_DIR}.")
        expected = {"plugin.yaml": PLUGIN_MANIFEST_BYTES, "__init__.py": PLUGIN_INIT_BYTES}
        names = set(os.listdir(PLUGIN_DIR))
        if names - set(expected) - {"__pycache__"}:
            refuse(f"Firstmate Hermes plugin contains unexpected entries at {PLUGIN_DIR}.")
        for name, content in expected.items():
            path = os.path.join(PLUGIN_DIR, name)
            child = regular_not_symlink(path, f"Firstmate Hermes plugin {name}")
            with open(path, "rb") as stream:
                if stream.read() != content:
                    refuse(f"Firstmate Hermes plugin has unexpected content at {path}.")
            if stat.S_IMODE(child.st_mode) & 0o077:
                refuse(f"Firstmate Hermes plugin has unexpectedly broad permissions at {path}.")
        validate_plugin_cache()


try:
    if not os.path.isdir(HERMES_HOME) or os.path.islink(HERMES_HOME):
        refuse(f"Hermes home is missing or unexpected at {HERMES_HOME}.")
    config_info = regular_not_symlink(CONFIG, "Hermes config")
    with open(CONFIG, "rb") as stream:
        original = stream.read()
    command = HOOK
    if ACTION == "install":
        candidate = install_plugin_config(original)
        candidate = install_config(candidate, command)
        if os.path.lexists(REGISTRY):
            info = os.lstat(REGISTRY)
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                refuse(f"Firstmate Hermes registry is not a regular directory at {REGISTRY}.")
        if os.path.lexists(HOOK):
            regular_not_symlink(HOOK, "Firstmate Hermes hook script")
            with open(HOOK, "rb") as stream:
                existing_hook = stream.read()
            if existing_hook != HOOK_BYTES and not existing_hook.startswith(
                b"#!/usr/bin/env bash\n# Firstmate Hermes crew lifecycle hook."
            ):
                refuse(f"Firstmate Hermes hook path has unexpected content at {HOOK}.")
        os.makedirs(REGISTRY, mode=0o700, exist_ok=True)
        os.chmod(REGISTRY, 0o700)
        plugins_root = os.path.dirname(PLUGIN_DIR)
        if os.path.lexists(plugins_root):
            info = os.lstat(plugins_root)
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                refuse(f"Hermes plugins path is not a regular directory at {plugins_root}.")
        else:
            os.makedirs(plugins_root, mode=0o700)
        if os.path.lexists(PLUGIN_DIR):
            info = os.lstat(PLUGIN_DIR)
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                refuse(f"Firstmate Hermes plugin path is unexpected at {PLUGIN_DIR}.")
            unexpected = set(os.listdir(PLUGIN_DIR)) - {"plugin.yaml", "__init__.py", "__pycache__"}
            if unexpected:
                refuse(f"Firstmate Hermes plugin contains unexpected entries at {PLUGIN_DIR}.")
            validate_plugin_cache()
            pycache = os.path.join(PLUGIN_DIR, "__pycache__")
            if os.path.lexists(pycache):
                shutil.rmtree(pycache)
        else:
            os.makedirs(PLUGIN_DIR, mode=0o700)
        os.chmod(PLUGIN_DIR, 0o700)
        installed_hook = None
        if os.path.exists(HOOK):
            with open(HOOK, "rb") as stream:
                installed_hook = stream.read()
        if installed_hook != HOOK_BYTES or stat.S_IMODE(os.stat(HOOK).st_mode) != 0o700:
            atomic_write(HOOK, HOOK_BYTES, 0o700)
        for path, content in (
            (PLUGIN_MANIFEST, PLUGIN_MANIFEST_BYTES),
            (PLUGIN_INIT, PLUGIN_INIT_BYTES),
        ):
            installed = None
            if os.path.exists(path):
                regular_not_symlink(path, f"Firstmate Hermes plugin {os.path.basename(path)}")
                with open(path, "rb") as stream:
                    installed = stream.read()
            if installed != content or stat.S_IMODE(os.stat(path).st_mode) != 0o600:
                atomic_write(path, content, 0o600)
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
    else:
        validate_owned_files_for_remove()
        candidate = remove_config(original)
        candidate = remove_plugin_config(candidate)
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
        if os.path.lexists(HOOK):
            os.unlink(HOOK)
        if os.path.lexists(REGISTRY):
            shutil.rmtree(REGISTRY)
        if os.path.lexists(PLUGIN_DIR):
            shutil.rmtree(PLUGIN_DIR)
except OSError as error:
    refuse(f"filesystem operation failed: {error}.")
PY
