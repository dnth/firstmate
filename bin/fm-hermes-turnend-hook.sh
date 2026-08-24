#!/usr/bin/env bash
# Install or remove Firstmate's guarded Hermes crew lifecycle hooks.
#
# This command is the sole owner of the text-level edit to the active Hermes
# config.yaml. It asks the selected Hermes executable for its profile-scoped
# config path, validates the existing YAML, and adds marker-delimited entries
# to the existing hooks mapping without serializing or reformatting foreign
# config. Missing, malformed, symlinked, partially marked, or surprising config
# is refused without a config write.
#
# The installed hook is passive and always exits zero. on_session_start records
# a new resumable session id, pre_llm_call acknowledges every initial or resumed
# turn and marks semantic busy state, and on_session_end marks semantic idle and
# touches state/<id>.turn-ended. A worktree token must resolve through the
# profile-private Firstmate registry before any event can act.
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
TOKEN_NAME = re.compile(r"fm\.[A-Za-z0-9]{12}\Z")
EVENTS = ("on_session_start", "pre_llm_call", "on_session_end")
TOP_BEGIN = "# BEGIN FIRSTMATE HERMES HOOKS"
TOP_END = "# END FIRSTMATE HERMES HOOKS"
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
case "$event" in
  on_session_start|pre_llm_call)
    tmp=$(mktemp "$state/.${id}.hermes-session.XXXXXXXX" 2>/dev/null) || exit 0
    chmod 0600 "$tmp" 2>/dev/null || true
    if printf '%s\n' "$session_id" > "$tmp" 2>/dev/null && mv -f "$tmp" "$session_file" 2>/dev/null; then
      started_tmp=$(mktemp "$state/.${id}.hermes-started.XXXXXXXX" 2>/dev/null) || exit 0
      chmod 0600 "$started_tmp" 2>/dev/null || true
      if ! printf '%s:%s:%s\n' "$session_id" "$event" "$$" > "$started_tmp" 2>/dev/null \
        || ! mv -f "$started_tmp" "$started" 2>/dev/null; then
        rm -f -- "$started_tmp" 2>/dev/null || true
      fi
      "$root/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" --source hermes-hook --event "$event" >/dev/null 2>&1 || true
    else
      rm -f -- "$tmp" 2>/dev/null || true
    fi
    ;;
  on_session_end)
    current=$(cat "$session_file" 2>/dev/null) || exit 0
    [ "$current" = "$session_id" ] || exit 0
    touch -- "$turnend" 2>/dev/null || true
    "$root/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" --source hermes-hook --event session-end >/dev/null 2>&1 || true
    ;;
esac
exit 0
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


def event_marker(event: str, owns_event: bool, begin: bool) -> str:
    edge = "BEGIN" if begin else "END"
    suffix = " (OWNS EVENT)" if owns_event else ""
    return f"# {edge} FIRSTMATE HERMES {event.upper()} HOOK{suffix}"


def event_entry(command: str, indent: str) -> list[str]:
    quoted = json.dumps(command)
    return [
        f"{indent}- command: {quoted}\n",
        f"{indent}  timeout: 2\n",
    ]


def hook_block(command: str, begin_marker: str = TOP_BEGIN) -> list[str]:
    quoted = json.dumps(command)
    return [
        f"{begin_marker}\n",
        "hooks:\n",
        "  on_session_start:\n",
        f"    - command: {quoted}\n",
        "      timeout: 2\n",
        "  pre_llm_call:\n",
        f"    - command: {quoted}\n",
        "      timeout: 2\n",
        "  on_session_end:\n",
        f"    - command: {quoted}\n",
        "      timeout: 2\n",
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
        if len(matches) != 1 or matches[0].get("timeout") != 2:
            refuse(f"updated config.yaml did not contain exactly one Firstmate hooks.{event} entry.")


def install_config(original: bytes, command: str) -> bytes:
    text, _parsed, root = parse_yaml(original, "config.yaml")
    lines = text.splitlines(keepends=True)
    regions = marker_state(lines)
    if regions:
        if len(regions) == 1 and regions[0][2].startswith(TOP_BEGIN) and regions[0][3] == TOP_END:
            verify_installed_config(original, command)
            return original
        if len(regions) == 3:
            verify_installed_config(original, command)
            return original
        refuse("config.yaml has an unexpected Firstmate Hermes marker shape.")

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


try:
    if not os.path.isdir(HERMES_HOME) or os.path.islink(HERMES_HOME):
        refuse(f"Hermes home is missing or unexpected at {HERMES_HOME}.")
    config_info = regular_not_symlink(CONFIG, "Hermes config")
    with open(CONFIG, "rb") as stream:
        original = stream.read()
    command = HOOK
    if ACTION == "install":
        candidate = install_config(original, command)
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
        installed_hook = None
        if os.path.exists(HOOK):
            with open(HOOK, "rb") as stream:
                installed_hook = stream.read()
        if installed_hook != HOOK_BYTES or stat.S_IMODE(os.stat(HOOK).st_mode) != 0o700:
            atomic_write(HOOK, HOOK_BYTES, 0o700)
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
    else:
        validate_owned_files_for_remove()
        candidate = remove_config(original)
        if candidate != original:
            atomic_write(CONFIG, candidate, stat.S_IMODE(config_info.st_mode))
        if os.path.lexists(HOOK):
            os.unlink(HOOK)
        if os.path.lexists(REGISTRY):
            shutil.rmtree(REGISTRY)
except OSError as error:
    refuse(f"filesystem operation failed: {error}.")
PY
