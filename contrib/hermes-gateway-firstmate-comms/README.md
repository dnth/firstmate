# Hermes Gateway plugin: Firstmate Communication Officer

Install this directory into a **dedicated Hermes Gateway profile**, never the crewmate TUI profile.
Supported Hermes gateway range is 0.20.0 and newer, verified against 0.20.5.

Crewmate Hermes is a separate adapter.
Firstmate still launches crewmates with `hermes chat --tui`.
That command is not this Discord gateway.

## Dedicated gateway profile

Use a profile home, for example `~/.hermes/profiles/fmcomms`, which gets its own `hermes-gateway-fmcomms.service`.
Installing a gateway from an arbitrary `HERMES_HOME` path reuses and rewrites the default `hermes-gateway.service` on Hermes 0.20.5, so prefer the profile path.
Copy or symlink this plugin into the profile's `plugins/firstmate-comms/` directory.
Enable it in that profile's Hermes `config.yaml` `plugins.enabled` list.
Do not add this plugin to a crewmate profile that Firstmate's Hermes turn-end hook manages.
The gateway process is `hermes gateway`, not `hermes chat --tui`.

## Local Firstmate bridge

Point the gateway at the Firstmate home with `FM_HOME` in the gateway environment.
Firstmate opt-in is `config/ext-bridge` plus `config/ext-secret` (mode 0600) and `config/ext-allowlist`.
Creating `config/ext-bridge` is the only way to turn the bridge on: this plugin cannot activate a home that has not opted in, and `FM_EXT_BRIDGE` only ever disables a configured bridge.

If the plugin is copied rather than symlinked into `$HERMES_HOME`, also set `FM_ROOT_OVERRIDE` to the Firstmate checkout, because a copied plugin cannot find `bin/fm-ext-intake.sh` by walking up from its own path.

Allowlist lines are fail-closed, and how narrow the rule is decides what a request may do:

```
<guild>                      # admitted, but every project change waits for the captain
<guild>:<channel>            # admitted, but every project change waits for the captain
<guild>:<channel>:<author>   # recommended: standing authority to act on normal work
```

Prefer the three-component form.
A `<guild>` rule does **not** hand every member of that Discord server command authority over the machine: those requests are answered and investigated, but anything that changes a project needs the captain's confirmation first.
A rule with an empty component (`<guild>:`) or a fourth component is malformed and is ignored, so a typo cannot widen a grant.
The allowlist decision lives in `bin/fm-ext-intake.sh`, which this plugin calls; the plugin keeps no copy of the rule grammar and reports the refusal that script returns.

## Sending a request

In the [dedicated Firstmate channel](#dedicated-firstmate-channel), just write the request as an ordinary message; every message an allowlisted author sends there, or in a thread under it, is a request.
Anywhere the gateway listens, a Discord reply to one of Firstmate's own messages is a request too, and Firstmate sees the message you replied to, so a reply of "yes" answers that message's question.
Outside the dedicated channel, keep the reply's mention on (Discord's default), because the gateway only hears messages that mention the bot there.
A message request uses the [delivery reactions](../../docs/configuration.md#delivery-reactions) instead of a text acknowledgement.
See the [topic-thread contract](../../docs/configuration.md#topic-threads-one-thread-per-request) for dedicated-channel conversations and routing elsewhere, including unchanged `/fm` replies.

Anywhere else, send `/fm` from Discord's command pop-up: type `/fm`, pick this bot's `/fm` entry when the pop-up shows it, put the request in its box, and send.
For files attached to ordinary message requests, see the [attachment handling contract](../../docs/configuration.md#discord-attachments).
Outside the dedicated channel, typing `/fm hello` and pressing Enter before the pop-up appears sends ordinary chat text instead of the command, and the gateway ignores ordinary text that does not @mention the bot.
A slash command is a Discord interaction rather than a message, so it cannot take reactions; `/fm` answers with the short text "Aye, captain - Firstmate has it." instead.
For thread authorization, reply routing, and the exact rules for the channel, replies, and reactions, see the [local bridge configuration reference](../../docs/configuration.md#local-communication-officer-bridge-configext-bridge).

## Dedicated Firstmate channel

The dedicated channel is off until you set it.

1. In Discord, create a text channel for Firstmate, for example `#firstmate`, in the server the bot is in.
2. Check that the bot can View Channel, Send Messages, Read Message History, Add Reactions, Create Public Threads, and Send Messages in Threads there.
3. With Developer Mode on (User Settings, Advanced), right-click the channel and pick Copy Channel ID.
4. In the Firstmate home, write that id on its own line to `config/ext-channel`, and add a `<guild>:<channel>:<author>` line for it to `config/ext-allowlist` so your messages there carry standing authority.
5. In the gateway profile's `.env`, add the channel id to `DISCORD_FREE_RESPONSE_CHANNELS` so Hermes hands this plugin messages that do not mention the bot, and set `DISCORD_REACTIONS=false` so Hermes's own processing reactions do not mark a message done before Firstmate has answered it.
6. Restart the gateway service so it reads the new `.env`; `config/ext-channel` itself is read per message and needs no restart.

Only the allowlist decides who may instruct Firstmate in that channel; anyone it refuses is ignored there.
`DISCORD_REACTIONS=false` also stops the 👀 and ✅ Hermes adds to messages its general agent handles in this gateway profile.

## How it works

The plugin registers slash command `fm` and the `pre_gateway_dispatch` hook.
Hermes 0.20.x dispatches plugin commands as `handler(user_args)` with no event, so the hook binds each inbound `/fm` MessageEvent destination task-locally before dispatch and the handler consumes it in the same task.
Concurrent identical `/fm` texts never share a destination: the binding is task-local, never a shared cache.
The same hook turns a dedicated-channel message or a reply to a Firstmate post into a request and returns Hermes's skip action for it, so the general agent never answers it as well.
It recognises Firstmate's posts by the Discord ids the outbox poster recorded, not by the bot's author id, because the general agent posts as the same bot.
Message and reply cases are covered by [the destination regression test](../../tests/fm-ext-plugin-dest.test.sh).
It writes Discord text to a temp file and execs `bin/fm-ext-intake.sh --text-file`.
For a message carrying attachments it passes the adapter's cached paths as `--attachment-manifest`.
It prefers `raw_message.content`, including an empty string, so the adapter's attachment-enriched text is not used when raw content is available.
If raw content is unavailable, it preserves `event.text` unchanged; it never cuts human text using attachment-content markers.
It never calls `dispatch_tool("terminal", ...)`.
The slash handler returns a fast ack without waiting for Firstmate to finish the work.
When the destination cannot be resolved the handler answers that the Discord destination is incomplete and names the running Hermes version (`unknown` if the version cannot be imported), never a silent drop.
The [local bridge configuration reference](../../docs/configuration.md#local-communication-officer-bridge-configext-bridge) owns request identity and reply destination fields.
Destination isolation, originating-thread and parent-channel routing, version diagnostics, and required hook registration are covered by [the destination regression test](../../tests/fm-ext-plugin-dest.test.sh).

An outbox watcher drains `state/ext-outbox/` through `bin/fm-ext-outbox.sh`.
For the optional pinned waiting message and its separate delivery contract, see the [local bridge configuration reference](../../docs/configuration.md#local-communication-officer-bridge-configext-bridge).
The following posting-marker, chunk-progress, and receipt rules apply to ordinary request replies.
Unsent payloads retry after a gateway restart.
Oversized replies split with `FM_EXT_DISCORD_REPLY_MAX_CHARS` (default 1900) and post as ordered Discord messages in the same thread.
That split does not use `FMX_PAIRING_TOKEN` or the hosted relay.
A transient definite send failure (HTTP 429 or 5xx) before a successful Discord response deletes the posting marker so that generation can retry.
A permanent 4xx records a terminal failed marker so pending stops retrying that generation.
A posting marker without a receipt is refused so an ambiguous crash or transport error after Discord may have accepted the post cannot double-post.
An exclusive inflight send claim means two gateway processes cannot both post the same remaining chunk after a later-chunk resume.
A dead owner's claim older than `FM_EXT_INFLIGHT_TTL_SECS` (default 30) may be stolen; a live owner is never stolen from.
A generation left in-flight by an ambiguous send is reopened for another attempt once it has had no claim or progress heartbeat for longer than `FM_EXT_MIDDELIVERY_RECOVERY_SECS` (default 300), and after `FM_EXT_MIDDELIVERY_RECOVERY_MAX` (default 3) attempts it is failed terminally and surfaced to Firstmate, so an active poster is not interrupted and a network timeout cannot silently truncate a reply.
Delivered payloads are retired as soon as they have a receipt, so poll cost does not grow with the number of replies already sent, and leftover records expire after `FM_EXT_CONTEXT_MAX_AGE_SECS` (default and maximum 7 days).
`FM_EXT_OUTBOX_POLL_SECS` (default 2) sets how often the watcher drains the outbox.
Set `DISCORD_BOT_TOKEN` (or `HERMES_DISCORD_TOKEN`) for Discord REST delivery.
The [local bridge configuration reference](../../docs/configuration.md#local-communication-officer-bridge-configext-bridge) owns the poster's User-Agent requirement and real-sender regression coverage.
Firstmate core has no Discord library.

See [Local Communication Officer bridge](../../docs/configuration.md#local-communication-officer-bridge-configext-bridge).
