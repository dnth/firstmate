"""Hermes Gateway plugin for the sibling local Firstmate Communication Officer.

Install this directory into a dedicated gateway HERMES_HOME plugins folder.
Do not enable it on a crewmate TUI profile. Crewmate Hermes still launches as
``hermes chat --tui`` and is a separate adapter.

This plugin never calls ``ctx.dispatch_tool("terminal", ...)``.
It execs ``bin/fm-ext-intake.sh`` with ``--text-file`` and watches the local
outbox using ``bin/fm-ext-outbox.sh``.
"""

from __future__ import annotations

try:
    from .intake import handle_fm_command, maybe_intake_from_text
    from .outbox_poster import start_outbox_watcher
except ImportError:
    from intake import handle_fm_command, maybe_intake_from_text
    from outbox_poster import start_outbox_watcher


def register(ctx):
    """Wire the /fm slash command and start the local outbox poster."""
    ctx.register_command(
        "fm",
        handler=handle_fm_command,
        description="Send this request to the local Firstmate Communication Officer",
        args_hint="request",
    )
    start_outbox_watcher()
