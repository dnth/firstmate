"""Where the Firstmate tools this plugin runs come from.

Every Firstmate script this plugin runs is a subprocess of whatever process
loaded the plugin, so it inherits that process's ``PATH``. Inside a Hermes
gateway that is the systemd unit's fixed value, not the captain's own shell
environment: the toolchain directories a profile manager, ``pixi``, or a
version manager adds in the account's rc files are missing, and a
``tasks-axi`` installed there becomes invisible. A click then cannot read the
decision it was made on.

``firstmate_env`` is the one place that builds the environment for those
subprocesses. It keeps the loader's own ``PATH`` in front, adds the
directories ``FM_EXT_TOOL_PATH`` names, and finally asks the account's login
shell for the directories it would have. A tool that still cannot be found is
not papered over here: the script that needs it fails by name, and the plugin
shows that name.
"""

from __future__ import annotations

import logging
import os
import shutil
import subprocess

logger = logging.getLogger(__name__)

# PATH-style list of extra tool directories. An operator or a test sets it when
# the account's shell cannot be asked (a container, a locked-down service).
TOOL_PATH_ENV = "FM_EXT_TOOL_PATH"

# The login-shell probe brackets the PATH it prints with this sentinel, so a
# shell that also prints a banner or a greeting cannot be mistaken for one.
_MARKER = "__FM_TOOL_PATH__"
# A shell's rc files can do anything, including wait on input; the probe is
# bounded and gets no terminal.
PROBE_TIMEOUT_SECS = 5.0

# One probe per shell per process: the answer cannot change under a running
# gateway often enough to be worth asking twice.
_shell_dirs: dict[str, tuple[str, ...]] = {}


def firstmate_env(home, root, needs) -> dict[str, str]:
    """The environment for one Firstmate subprocess.

    ``home`` is the Firstmate home, ``root`` the checkout its scripts live in,
    and ``needs`` the tools that call's script cannot run without. Stating
    ``needs`` is what lets an ordinary launch skip the shell probe.
    """
    env = os.environ.copy()
    env["FM_HOME"] = str(home)
    env["FM_ROOT_OVERRIDE"] = str(root)
    env["PATH"] = tool_path(needs, base=env.get("PATH", os.defpath))
    return env


def tool_path(needs, base: str | None = None) -> str:
    """``base`` PATH, extended so every tool in ``needs`` can be found.

    The loader's entries stay in front, so a tool the gateway already resolves
    is the one its scripts keep running. The account's shell directories are
    appended only when one of ``needs`` is missing from what is already there.
    """
    entries = _split(os.environ.get(TOOL_PATH_ENV, ""))
    entries += _split(base if base is not None else os.environ.get("PATH", os.defpath))
    entries = _unique(entries)
    if needs and not _resolves(needs, entries):
        entries = _unique(entries + list(shell_tool_dirs()))
    return os.pathsep.join(entries)


def shell_tool_dirs() -> tuple[str, ...]:
    """Directories only the account's own login shell knows about, in order.

    The tools Firstmate bootstrap requires are installed wherever the account's
    shell puts them, which is exactly what a systemd unit's ``PATH`` does not
    inherit. Asking that shell once per process recovers the same directories a
    Firstmate session runs with. The shell is invoked as an interactive login
    shell because PATH additions usually live in the rc file that mode reads.
    """
    shell = login_shell()
    cached = _shell_dirs.get(shell)
    if cached is not None:
        return cached
    dirs = _probe(shell)
    _shell_dirs[shell] = dirs
    if dirs:
        logger.info(
            "firstmate-comms: added %d tool directories from %s", len(dirs), shell
        )
    return dirs


def login_shell() -> str:
    """The account's own shell: ``SHELL`` when it is usable, else the passwd one.

    ``SHELL`` is usually unset under a systemd unit, so the password database is
    what decides there; that is what makes the probe the captain's shell rather
    than whatever launched the gateway.
    """
    for candidate in (_env_shell(), _passwd_shell()):
        if candidate:
            return candidate
    return "/bin/sh"


def _probe(shell: str) -> tuple[str, ...]:
    if not os.access(shell, os.X_OK):
        return ()
    script = 'printf "%s%s%s" ' + _MARKER + ' "$PATH" ' + _MARKER
    try:
        result = subprocess.run(
            [shell, "-l", "-i", "-c", script],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=PROBE_TIMEOUT_SECS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        logger.debug("firstmate-comms: %s could not report its PATH: %s", shell, exc)
        return ()
    parts = (result.stdout or "").split(_MARKER)
    if len(parts) < 3:
        logger.debug(
            "firstmate-comms: %s did not report its PATH (exit %s)", shell, result.returncode
        )
        return ()
    return tuple(_split(parts[1]))


def _env_shell() -> str:
    shell = os.environ.get("SHELL", "")
    return shell if shell and os.path.isabs(shell) else ""


def _passwd_shell() -> str:
    try:
        import pwd
    except ImportError:  # not POSIX
        return ""
    try:
        return pwd.getpwuid(os.getuid()).pw_shell or ""
    except KeyError:
        return ""


def _split(path: str) -> list[str]:
    return [entry for entry in (path or "").split(os.pathsep) if entry]


def _unique(entries: list[str]) -> list[str]:
    """Drop duplicates, keeping the first place an entry appears."""
    seen = set()
    kept = []
    for entry in entries:
        key = os.path.realpath(entry)
        if key in seen:
            continue
        seen.add(key)
        kept.append(entry)
    return kept


def _resolves(needs, entries: list[str]) -> bool:
    search = os.pathsep.join(entries)
    return all(shutil.which(tool, path=search) for tool in needs)
