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

try:
    from .intake import handle_fm_command, maybe_intake_from_text, pre_gateway_dispatch_hook
    from .outbox_poster import start_outbox_watcher
except ImportError:
    from intake import handle_fm_command, maybe_intake_from_text, pre_gateway_dispatch_hook
    from outbox_poster import start_outbox_watcher


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
    start_outbox_watcher()
