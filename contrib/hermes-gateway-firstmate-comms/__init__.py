"""Hermes Gateway plugin for the sibling local Firstmate Communication Officer.

See README.md for installation into a dedicated gateway profile.
Do not enable it on a crewmate TUI profile. Crewmate Hermes still launches as
``hermes chat --tui`` and is a separate adapter.

This plugin never calls ``ctx.dispatch_tool("terminal", ...)``.
It execs ``bin/fm-ext-intake.sh`` with ``--text-file`` for /fm, for messages in
the optional dedicated channel, and for replies to Firstmate's own posts, execs
``bin/fm-ext-decision.sh`` for clicks on Firstmate's decision buttons, and watches
the local outbox using ``bin/fm-ext-outbox.sh``.
"""

from __future__ import annotations

from pathlib import Path

try:
    from .intake import handle_fm_command, maybe_intake_from_text, pre_gateway_dispatch_hook
    from .outbox_poster import configure_bot_identity, start_outbox_watcher
    from .tool_path import set_plugin_hermes_home
except ImportError:
    from intake import handle_fm_command, maybe_intake_from_text, pre_gateway_dispatch_hook
    from outbox_poster import configure_bot_identity, start_outbox_watcher
    from tool_path import set_plugin_hermes_home


def _owning_profile_home(ctx):
    """The Hermes home this plugin was loaded for. The install location is the fallback."""
    try:
        from hermes_constants import get_hermes_home
    except ImportError:
        get_hermes_home = None
    if get_hermes_home is not None:
        return Path(get_hermes_home())
    path = Path(getattr(getattr(ctx, "manifest", None), "path", None) or "")
    plugin_dir = path.parent if path.suffix in (".yaml", ".yml") else path
    if plugin_dir.parent.name == "plugins":
        return plugin_dir.parent.parent
    return None


def register(ctx):
    """Wire /fm and its required dispatch hook, then start the outbox poster.
    The hook also routes dedicated-channel messages and replies to Firstmate.
    """
    ctx.register_command(
        "fm",
        handler=handle_fm_command,
        description="Send this request to the local Firstmate Communication Officer",
        args_hint="request",
    )
    ctx.register_hook("pre_gateway_dispatch", pre_gateway_dispatch_hook)
    profile_home = _owning_profile_home(ctx)
    configure_bot_identity(profile_home)
    # The gateway profile caches inbound media under its own home, which is not
    # always the process HERMES_HOME; carry it into every Firstmate subprocess.
    set_plugin_hermes_home(profile_home)
    start_outbox_watcher()
