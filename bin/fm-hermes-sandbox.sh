#!/usr/bin/env bash
# fm-hermes-sandbox.sh - run a Hermes command with its home variables confined
# to a throwaway directory and disconnect user service-manager access.
# Gateway checks must use foreground `gateway run`, never service control.
#
# Why this exists: on a gateway start Hermes rewrites
# `Path.home()/.config/systemd/user/hermes-gateway*.service` when the generated
# definition differs (hermes_cli/gateway.py `refresh_systemd_unit_if_needed`),
# and `gateway install` writes that unit unconditionally. Hermes' own belt only
# rejects /tmp and pytest paths, so a throwaway `HERMES_HOME` under a worktree
# still poisoned the real unit on 2026-10-12 and left the main gateway running
# on a test home.
# `get_systemd_unit_path()` resolves through `Path.home()` (which reads `$HOME`)
# and ignores `XDG_CONFIG_HOME`, so sandboxing `$HOME` is the mechanism that
# keeps that write inside the sandbox. This script refuses to run when it
# cannot prove that.
#
# Usage:
#   fm-hermes-sandbox.sh [--root <dir>] -- <command> [args...]
#
#   --root <dir>   Sandbox root to use. Created if missing, never removed by
#                  this script. Default: a fresh mktemp -d under ${TMPDIR:-/tmp}
#                  removed on exit.
#   -h, --help     print this header.
#
# Environment inside the command:
#   HOME=<root>/home          HERMES_HOME=<root>/hermes
#   XDG_CONFIG_HOME=<root>/config
#   XDG_DATA_HOME, XDG_CACHE_HOME, XDG_STATE_HOME also resolve under <root>.
#   Every inherited value of those variables is replaced, never merged.
#   XDG_RUNTIME_DIR is unset and DBUS_SESSION_BUS_ADDRESS points to /dev/null,
#   disconnecting commands from the real user service manager.
#   `PATH`, `TMPDIR`, and the working directory are unchanged.
#   python3 is required to resolve filesystem destinations before creating them.
#
# Refusals (exit 78):
#   - <root> is or contains the caller's real home or the account's passwd
#     home, or sits inside either home's `.config/systemd/user` directory.
#   - any sandbox variable fails to resolve inside <root>.
#   - python3 is unavailable or the `Path.home()` probe escapes the sandbox home.
#
# Exit status:
#   the command's own status, or 64 for a usage error, 78 for a refusal, and 70
#   when a real user unit directory changed while the command ran.
#
# Tripwire:
#   Every regular file under each watched `<home>/.config/systemd/user` is
#   checksummed before and after the command. Watched homes default to the
#   account's passwd home, or the caller's HOME when that cannot be resolved;
#   `FM_HERMES_SANDBOX_WATCH_HOMES` overrides them with a colon-separated list.
#   The tripwire is skipped when neither `sha256sum` nor `shasum` is installed.
#
# Typical use:
#   bin/fm-hermes-sandbox.sh -- hermes gateway run
#   bin/fm-hermes-sandbox.sh --root /tmp/fm-gw -- hermes gateway run
set -u

PROG=fm-hermes-sandbox

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

refuse() {
  printf '%s: refusing to run: %s\n' "$PROG" "$*" >&2
  exit 78
}

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 64
}

ROOT=
ROOT_GIVEN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -gt 1 ] || die "--root requires a directory"
      ROOT=$2
      ROOT_GIVEN=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      die "unexpected argument '$1' (put the command after --)"
      ;;
  esac
done
[ "$#" -gt 0 ] || die "missing command (put it after --)"
[ -n "${ROOT:-}" ] || [ "$ROOT_GIVEN" -eq 0 ] || die "--root requires a non-empty directory"

CLEANUP=
if [ "$ROOT_GIVEN" -eq 0 ]; then
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-hermes-sandbox.XXXXXX") || die "cannot create a sandbox root"
  CLEANUP=$ROOT
fi
mkdir -p "$ROOT" || die "cannot create sandbox root $ROOT"

ROOT_REAL=$(cd -- "$ROOT" && pwd -P) || die "cannot resolve sandbox root $ROOT"

# shellcheck disable=SC2329 # Registered by the EXIT/INT/TERM traps below.
cleanup() {
  if [ -n "$CLEANUP" ]; then
    rm -rf -- "$CLEANUP"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

passwd_home() {
  if command -v getent >/dev/null 2>&1; then
    getent passwd "$(id -u)" 2>/dev/null | awk -F: 'NR == 1 { print $6; exit }'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null
  fi
}

REAL_HOMES=()
add_real_home() {
  local h=$1 known
  [ -n "$h" ] || return 0
  h=$(cd -- "$h" 2>/dev/null && pwd -P) || return 0
  for known in "${REAL_HOMES[@]+"${REAL_HOMES[@]}"}"; do
    [ "$known" = "$h" ] && return 0
  done
  REAL_HOMES+=("$h")
}

add_real_home "${HOME:-}"
ACCOUNT_HOME=$(passwd_home)
add_real_home "$ACCOUNT_HOME"

# Homes whose `<home>/.config/systemd/user` the after-run tripwire watches.
# Default is the account's passwd home, or the caller's HOME when that home
# cannot be resolved, so a deliberately fake HOME cannot trip the belt.
# FM_HERMES_SANDBOX_WATCH_HOMES overrides it with a colon-separated list.
WATCH_HOMES=()
add_watch_home() {
  local h=$1 known
  [ -n "$h" ] || return 0
  h=$(cd -- "$h" 2>/dev/null && pwd -P) || return 0
  for known in "${WATCH_HOMES[@]+"${WATCH_HOMES[@]}"}"; do
    [ "$known" = "$h" ] && return 0
  done
  WATCH_HOMES+=("$h")
}
if [ -n "${FM_HERMES_SANDBOX_WATCH_HOMES:-}" ]; then
  while IFS= read -r watch_home; do
    add_watch_home "$watch_home"
  done < <(printf '%s\n' "$FM_HERMES_SANDBOX_WATCH_HOMES" | tr ':' '\n')
elif [ -n "$ACCOUNT_HOME" ]; then
  add_watch_home "$ACCOUNT_HOME"
else
  add_watch_home "${HOME:-}"
fi

for home in "${REAL_HOMES[@]+"${REAL_HOMES[@]}"}"; do
  [ "$ROOT_REAL" = "$home" ] && refuse "sandbox root is the real home $home"
  case "$home/" in
    "$ROOT_REAL"/*) refuse "sandbox root $ROOT_REAL contains the real home $home" ;;
  esac
  case "$ROOT_REAL/" in
    "$home/.config/systemd/user"/*) refuse "sandbox root is inside the real user unit directory of $home" ;;
  esac
done

S_HOME=$ROOT_REAL/home
S_CONFIG=$ROOT_REAL/config
S_DATA=$ROOT_REAL/data
S_CACHE=$ROOT_REAL/cache
S_STATE=$ROOT_REAL/state
S_HERMES=$ROOT_REAL/hermes

command -v python3 >/dev/null 2>&1 || refuse "python3 is required to resolve sandbox paths"

resolve_destination() {
  python3 - "$ROOT_REAL" "$1" "${2:-}" "${REAL_HOMES[@]+"${REAL_HOMES[@]}"}" <<'PYTHON'
import pathlib
import sys

root, target = map(pathlib.Path, sys.argv[1:3])
homes = list(map(pathlib.Path, sys.argv[4:]))

def validate(path):
    path = path.resolve()
    if root not in path.parents:
        sys.exit("sandbox destination escapes root: " + str(path))
    for home in homes:
        units = (home / ".config/systemd/user").resolve()
        if path == home or path in home.parents or path == units or units in path.parents:
            sys.exit("sandbox destination overlaps real home or unit directory: " + str(path))
    return path

target = validate(target)
if sys.argv[3] == "tree":
    pending = [target]
    visited = set()
    while pending:
        entry = validate(pending.pop())
        if entry.is_dir() and entry not in visited:
            visited.add(entry)
            pending.extend(entry.iterdir())
print(target)
PYTHON
}

S_HOME=$(resolve_destination "$S_HOME") || refuse "unsafe HOME"
S_CONFIG=$(resolve_destination "$S_CONFIG") || refuse "unsafe XDG_CONFIG_HOME"
S_DATA=$(resolve_destination "$S_DATA") || refuse "unsafe XDG_DATA_HOME"
S_CACHE=$(resolve_destination "$S_CACHE") || refuse "unsafe XDG_CACHE_HOME"
S_STATE=$(resolve_destination "$S_STATE") || refuse "unsafe XDG_STATE_HOME"
S_HERMES=$(resolve_destination "$S_HERMES") || refuse "unsafe HERMES_HOME"
S_UNITS=$(resolve_destination "$S_HOME/.config/systemd/user" tree) || refuse "unsafe user unit directory"

mkdir -p "$S_HOME" "$S_CONFIG" "$S_DATA" "$S_CACHE" "$S_STATE" "$S_HERMES" "$S_UNITS" ||
  die "cannot create the sandbox layout under $ROOT_REAL"
if [ "$ROOT_GIVEN" -eq 0 ]; then
  chmod 700 "$ROOT_REAL" 2>/dev/null || true
fi

probe=$(HOME="$S_HOME" python3 -c 'import pathlib; print(pathlib.Path.home().resolve())' 2>/dev/null) ||
  refuse "the Path.home() probe could not run, so confinement is unproven"
[ "$probe" = "$S_HOME" ] ||
  refuse "Path.home() resolved to $probe outside the sandbox home $S_HOME"

HASH_CMD=()
if command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  HASH_CMD=(shasum -a 256)
fi

unit_snapshot() {  # <user-unit-dir> -> per-file digest lines
  local dir=$1 file
  [ -d "$dir" ] || return 0
  [ "${#HASH_CMD[@]}" -gt 0 ] || return 0
  while IFS= read -r -d '' file; do
    "${HASH_CMD[@]}" "$file"
  done < <(find "$dir" -type f -print0 2>/dev/null) | LC_ALL=C sort
}

real_units_snapshot() {
  local home
  for home in "${WATCH_HOMES[@]+"${WATCH_HOMES[@]}"}"; do
    unit_snapshot "$home/.config/systemd/user"
  done
}

before=$(real_units_snapshot)

printf '%s: HOME=%s HERMES_HOME=%s\n' "$PROG" "$S_HOME" "$S_HERMES" >&2

(
  export HOME="$S_HOME"
  export XDG_CONFIG_HOME="$S_CONFIG"
  export XDG_DATA_HOME="$S_DATA"
  export XDG_CACHE_HOME="$S_CACHE"
  export XDG_STATE_HOME="$S_STATE"
  export HERMES_HOME="$S_HERMES"
  unset XDG_RUNTIME_DIR
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null
  exec "$@"
)
status=$?

after=$(real_units_snapshot)
if [ "$before" != "$after" ]; then
  printf '%s: the real user unit directories changed while the command ran:\n' "$PROG" >&2
  printf '%s\n' "$before" >&2
  printf '%s\n' "$after" >&2
  exit 70
fi

exit "$status"
