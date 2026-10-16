"""Discord decision buttons for the local Firstmate Communication Officer.

Firstmate attaches option buttons to a decision post through the outbox. Each
button's custom_id carries the decision key and a 1-based option id,
``fmd:<key>:<n>``, plus ``fmd:<key>:d`` for Discuss while the post is open.
The key is readable by channel members through the Discord API but is never rendered in a label or the post text. The ephemeral
confirmation button for a high-risk option is ``fmc:<post-id>:<n>``.

A click runs ``bin/fm-ext-decision.sh click``, which owns every check and every
notice - the decision post, the allowlist authority, staleness, and the
confirmation step - and files the click as a request through the same intake a
typed reply uses. Nothing here records an answer; Firstmate does, through its
normal decision path. This module only hands the script the click, shows its
notice ephemerally, turns the post's buttons off at once after a sent click,
and hooks the click route into the gateway's live Discord client.

Hermes 0.20.x has no plugin hook for Discord component clicks, so the route is
a discord.py ``DynamicItem`` registered on the Discord adapter's live client,
re-registered whenever the gateway reconnects with a new client. Until that
registration is in place the outbox poster posts decisions without buttons, so
a button is never shown that nothing would answer.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import subprocess
import threading
import weakref

try:
    from .intake import _snowflake, firstmate_home, firstmate_root, secret_path
except ImportError:  # loaded from sys.path in hermetic tests
    from intake import _snowflake, firstmate_home, firstmate_root, secret_path

logger = logging.getLogger(__name__)

_KEY = r"(?:hold:[A-Za-z0-9._-]+|key:[A-Za-z0-9._-]+:[A-Za-z0-9._-]+)"
# Either a post button, fmd:<key>:<n|d>, or a confirmation, fmc:<post-id>:<n>.
CLICK_TEMPLATE = (
    r"(?:fmd:(?P<key>" + _KEY + r"):(?P<option>[1-9]|d)"
    r"|fmc:(?P<post>[0-9]+):(?P<confirm>[1-9]))"
)
_CLICK = re.compile(CLICK_TEMPLATE)

# bin/fm-ext-decision.sh click exit code for "show the confirmation button".
CLICK_CONFIRM = 5
# Exit codes whose stdout is a notice meant for the clicker.
_NOTICE_CODES = {0, 3, 4, 5, 6}

# Discord message component types and button styles.
_ACTION_ROW = 1
_BUTTON = 2
_STYLE_PRIMARY = 1
_STYLE_SECONDARY = 2
_STYLE_SUCCESS = 3
_STYLE_DANGER = 4

DISCUSS_LABEL = "Discuss"
# bin/fm-ext-decision.sh exits 1 only when nothing was sent, so this notice may
# invite another try.
REPLY_FAILED = "Firstmate could not send that click. Nothing was decided; try again, or reply to the post instead."
# A click still filing when the wait ends may yet file its request, so the
# script is left to finish; a second click cannot file a second request.
REPLY_PENDING = (
    "Firstmate is still sending this click. Check the post in a minute; "
    "clicking again cannot send it twice."
)
# How long a click waits for the script, inside Discord's 15-minute window
# for following up on a deferred interaction.
CLICK_WAIT_SECS = 600
# The notice that starts a sent click, after which the post's buttons go off.
SENT_PREFIX = "Sent: "

_attached: weakref.ReferenceType | None = None
_attach_lock = threading.Lock()
_item_class = None
_warned = False


def custom_id(key: str, option) -> str:
    return f"fmd:{key}:{option}"


def confirm_id(post_id: str, option: int) -> str:
    return f"fmc:{post_id}:{option}"


def components_for(
    decision: dict,
    disabled: bool = False,
    selected_option_id: int | str | None = None,
) -> list[dict]:
    """Build decision buttons, showing the recorded choice on a settled post."""
    key = decision["key"]
    options = []
    for option in decision["options"]:
        selected = disabled and str(option["id"]) == str(selected_option_id)
        if disabled:
            style = _STYLE_SUCCESS if selected else _STYLE_SECONDARY
        elif option.get("recommended"):
            style = _STYLE_SUCCESS
        elif option.get("confirm"):
            style = _STYLE_DANGER
        else:
            style = _STYLE_SECONDARY
        label = option["label"]
        if selected:
            label = label[:78].rstrip() + " ✓"
        options.append(
            {
                "type": _BUTTON,
                "style": style,
                "label": label,
                "custom_id": custom_id(key, option["id"]),
                "disabled": disabled,
            }
        )
    discuss = {
        "type": _BUTTON,
        "style": _STYLE_SECONDARY if disabled else _STYLE_PRIMARY,
        "label": DISCUSS_LABEL,
        "custom_id": custom_id(key, "d"),
        "disabled": disabled,
    }
    return [{"type": _ACTION_ROW, "components": options}, {"type": _ACTION_ROW, "components": [discuss]}]


def click_destination(interaction: object) -> dict[str, str]:
    """What a click is checked against, from a discord.py Interaction.
    chat_id is where the clicked message lives (the thread inside a thread),
    message_id is the clicked message, and author_name is how the outcome
    line names the clicker.
    """
    user = getattr(interaction, "user", None)
    message = getattr(interaction, "message", None)
    try:
        name = str(getattr(user, "display_name", "") or getattr(user, "name", "") or "")
    except Exception:
        name = ""
    return {
        "guild_id": _snowflake(getattr(interaction, "guild_id", None)),
        "chat_id": _snowflake(getattr(interaction, "channel_id", None)),
        "interaction_id": _snowflake(getattr(interaction, "id", None)),
        "message_id": _snowflake(getattr(message, "id", None)),
        "author": _snowflake(getattr(user, "id", None)),
        "author_name": name,
    }


def handle_click(dest: dict[str, str], click_id: str) -> dict:
    """Run bin/fm-ext-decision.sh click for one click and map its verdict.
    Returns {"text": <ephemeral notice>, "confirm": <custom_id of the
    confirmation button to offer, or None>}. Never raises.
    """
    match = _CLICK.fullmatch(str(click_id or ""))
    needed = ("guild_id", "chat_id", "interaction_id", "author", "message_id")
    if match is None or not all(dest.get(name) for name in needed):
        return {"text": REPLY_FAILED, "confirm": None}
    if match["post"]:
        post, option, extra = match["post"], match["confirm"], ["--confirmed"]
    else:
        option = "discuss" if match["option"] == "d" else match["option"]
        post, extra = dest["message_id"], ["--key", match["key"]]
    home = firstmate_home()
    env = os.environ.copy()
    env["FM_HOME"] = str(home)
    env["FM_ROOT_OVERRIDE"] = str(firstmate_root())
    args = [
        str(firstmate_root() / "bin" / "fm-ext-decision.sh"),
        "click",
        "--post-id",
        post,
        "--option",
        option,
        "--guild-id",
        dest["guild_id"],
        "--chat-id",
        dest["chat_id"],
        "--interaction-id",
        dest["interaction_id"],
        "--author",
        dest["author"],
        "--author-name",
        dest.get("author_name") or "",
        "--secret-file",
        str(secret_path(home)),
    ] + extra
    try:
        proc = subprocess.Popen(
            args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
    except Exception:
        return {"text": REPLY_FAILED, "confirm": None}
    try:
        out, err = proc.communicate(timeout=CLICK_WAIT_SECS)
    except subprocess.TimeoutExpired:
        # Never kill a click mid-record: let it finish in the background.
        threading.Thread(target=proc.communicate, name="fm-ext-click", daemon=True).start()
        return {"text": REPLY_PENDING, "confirm": None}
    except Exception:
        return {"text": REPLY_PENDING, "confirm": None}
    out = (out or "").strip()
    if proc.returncode not in _NOTICE_CODES or not out:
        logger.warning(
            "firstmate-comms: decision click recorded nothing (exit %s): %s",
            proc.returncode,
            (err or "").strip()[-500:],
        )
        return {"text": REPLY_FAILED, "confirm": None}
    if proc.returncode == CLICK_CONFIRM:
        return {"text": out, "confirm": confirm_id(post, int(option))}
    return {"text": out, "confirm": None}


def click_item_class():
    """The discord.py DynamicItem that routes every decision click here.
    Built on first use so this module imports without discord.py installed.
    """
    global _item_class
    if _item_class is not None:
        return _item_class
    import discord

    class FirstmateDecisionButton(discord.ui.DynamicItem[discord.ui.Button], template=CLICK_TEMPLATE):
        def __init__(self, click_id: str, label: str | None = None) -> None:
            super().__init__(
                discord.ui.Button(
                    label=label or "Confirm",
                    style=discord.ButtonStyle.danger,
                    custom_id=click_id,
                )
            )
            self.click_id = click_id

        @classmethod
        async def from_custom_id(cls, interaction, item, match):
            return cls(match.group(0), getattr(item, "label", None))

        async def callback(self, interaction) -> None:
            await respond_to_click(interaction, self.click_id)

    _item_class = FirstmateDecisionButton
    return _item_class


def _show_sent_posts() -> None:
    """Redraw posts whose click was just sent, so their buttons go off now
    rather than on the next outbox cycle. Best effort: the watcher retries."""
    try:
        try:
            from . import outbox_poster
        except ImportError:  # loaded from sys.path in hermetic tests
            import outbox_poster
        outbox_poster.reconcile_decision_posts(full=False)
    except Exception:
        logger.debug("firstmate-comms: decision post redraw deferred to the outbox watcher")


async def respond_to_click(interaction: object, click_id: str) -> None:
    """Answer one click ephemerally: defer at once, because the checks run a
    local script, then follow up with the notice and, for an option that
    needs it, the confirmation button. A sent click also turns the post's
    buttons off.
    """
    import discord

    dest = click_destination(interaction)
    await interaction.response.defer(ephemeral=True, thinking=True)
    verdict = await asyncio.to_thread(handle_click, dest, click_id)
    kwargs = {"ephemeral": True}
    if verdict.get("confirm"):
        view = discord.ui.View(timeout=None)
        view.add_item(click_item_class()(verdict["confirm"], "Confirm"))
        kwargs["view"] = view
    await interaction.followup.send(verdict["text"], **kwargs)
    if str(verdict.get("text") or "").startswith(SENT_PREFIX):
        await asyncio.to_thread(_show_sent_posts)


def _live_discord_adapter():
    """The gateway's Discord adapter in this process, or None.
    Resolved through the gateway runner's adapter registry, the same route
    Hermes's own platform-action facade uses.
    """
    try:
        from gateway.config import Platform
        from gateway.run import _gateway_runner_ref

        runner = _gateway_runner_ref()
        if runner is None:
            return None
        return getattr(runner, "adapters", {}).get(Platform.DISCORD)
    except Exception:
        return None


def live_discord_client():
    """The Discord adapter's live discord.py client, or None."""
    return getattr(_live_discord_adapter(), "_client", None)


def _adapter_connected(adapter) -> bool:
    try:
        return bool(adapter.is_connected)
    except Exception:
        return False


def _warn_unroutable(reason: str) -> None:
    """Say once, naming the Hermes version, that a connected gateway cannot
    route clicks, so decisions posting without buttons is never silent.
    """
    global _warned
    if _warned:
        return
    _warned = True
    try:
        from hermes_cli import __version__ as hermes_version
    except ImportError:
        hermes_version = "unknown"
    logger.warning(
        "firstmate-comms: decision buttons are off on Hermes %s (%s); decisions post as plain text",
        hermes_version,
        reason,
    )


def ensure_click_route() -> bool:
    """Register the click route on the live client once per client.
    Safe to call from any thread: the registration runs on the client's own
    event loop. Returns whether the current client has the route.
    """
    global _attached
    adapter = _live_discord_adapter()
    if adapter is None:
        return False
    client = getattr(adapter, "_client", None)
    if client is None:
        if _adapter_connected(adapter):
            _warn_unroutable("the connected Discord adapter exposes no client")
        return False
    with _attach_lock:
        if _attached is not None and _attached() is client:
            return True
        try:
            item = click_item_class()
            client.loop.call_soon_threadsafe(client.add_dynamic_items, item)
        except Exception as err:  # the client not started yet, or an incompatible discord.py
            if _adapter_connected(adapter):
                _warn_unroutable(f"{type(err).__name__}: {err}")
            return False
        _attached = weakref.ref(client)
    logger.info("firstmate-comms: decision button clicks routed on the Discord client")
    return True


def buttons_ready() -> bool:
    """True when the gateway's current Discord client routes decision clicks.
    The outbox poster attaches buttons only then.
    """
    client = live_discord_client()
    with _attach_lock:
        return client is not None and _attached is not None and _attached() is client
