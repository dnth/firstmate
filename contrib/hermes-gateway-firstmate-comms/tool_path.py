"""Where the Firstmate tools this plugin runs come from.

Every Firstmate script this plugin runs is a subprocess of whatever process
loaded the plugin, so it inherits that process's ``PATH``. Inside a Hermes
gateway that is the systemd unit's fixed value, not the captain's own shell
environment: the toolchain directories a profile manager, ``pixi``, or a
version manager adds in the account's rc files are missing, and a
``tasks-axi`` installed there becomes invisible. A click then cannot read the
decision it was made on.

``firstmate_env`` is the one place that builds the environment for those
subprocesses. It keeps the loader's own ``PATH`` in front and asks the
account's login shell for the directories it would have. A tool that still
cannot be found is not papered over here: the script that needs it fails by name, and the plugin
shows that name.

It also carries the Hermes home this plugin was loaded for as
``FM_EXT_HERMES_HOME``. A dedicated gateway profile caches inbound media under
its own home while the process's ``HERMES_HOME`` still names the base Hermes
home, so a subprocess reading ``HERMES_HOME`` alone would refuse the captain's
own images. The home is recorded once at registration from the profile Hermes
loaded the plugin for, never guessed from the environment here.
"""

from __future__ import annotations

import logging
import os
import subprocess
from pathlib import Path

logger = logging.getLogger(__name__)

# The Hermes home this plugin was loaded for, recorded by register().
_plugin_hermes_home: Path | None = None

# The login-shell probe brackets the PATH it prints with this sentinel, so a
# shell that also prints a banner or a greeting cannot be mistaken for one.
_MARKER = "__FM_TOOL_PATH__"
# A shell's rc files can do anything, including wait on input; the probe is
# bounded and gets no terminal.
PROBE_TIMEOUT_SECS = 5.0

# One probe per shell per process: the answer cannot change under a running
# gateway often enough to be worth asking twice.
_shell_dirs: dict[str, tuple[str, ...]] = {}


def set_plugin_hermes_home(home) -> None:
    """Record the Hermes home this plugin was loaded for.

    register() passes the home Hermes resolved for the profile it loaded this
    plugin into. Pass None to leave it unrecorded (standalone runs and tests),
    which keeps a subprocess's own HERMES_HOME as the only attachment root.
    """
    global _plugin_hermes_home
    _plugin_hermes_home = Path(home) if home else None


def firstmate_env(home, root) -> dict[str, str]:
    """The environment for every Firstmate subprocess."""
    env = os.environ.copy()
    env["FM_HOME"] = str(home)
    env["FM_ROOT_OVERRIDE"] = str(root)
    # Only a home recorded at registration may name attachment roots; an
    # inherited value is dropped so registration stays the single authority.
    # Unrecorded, the subprocess's own HERMES_HOME stands.
    if _plugin_hermes_home is not None:
        env["FM_EXT_HERMES_HOME"] = str(_plugin_hermes_home)
    else:
        env.pop("FM_EXT_HERMES_HOME", None)
    env["PATH"] = tool_path(base=env.get("PATH", os.defpath))
    return env


def tool_path(base: str | None = None) -> str:
    """Keep the loader's PATH first, then append the cached shell directories."""
    entries = _split(base if base is not None else os.environ.get("PATH", os.defpath))
    return os.pathsep.join(_unique(entries + list(shell_tool_dirs())))


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
