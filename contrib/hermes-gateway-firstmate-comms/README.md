# Hermes Gateway plugin: Firstmate Communication Officer

Install this directory into a **dedicated Hermes Gateway home**, never the crewmate TUI profile.

Crewmate Hermes is a separate adapter.
Firstmate still launches crewmates with `hermes chat --tui`.
That command is not this Discord gateway.

## Dedicated gateway home

Pick a gateway-only `HERMES_HOME`, for example `~/.hermes-gateway-firstmate`.
Copy or symlink this plugin into `$HERMES_HOME/plugins/firstmate-comms/`.
Enable it in that home's Hermes `config.yaml` `plugins.enabled` list.
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

The plugin registers slash command `fm`.
It writes Discord text to a temp file and execs `bin/fm-ext-intake.sh --text-file`.
It never calls `dispatch_tool("terminal", ...)`.
The slash handler returns a fast ack without waiting for Firstmate to finish the work.

An outbox watcher drains `state/ext-outbox/` through `bin/fm-ext-outbox.sh`.
Unsent payloads retry after a gateway restart.
Oversized replies split with `FM_EXT_DISCORD_REPLY_MAX_CHARS` (default 1900) and post as ordered Discord messages in the same thread.
That split does not use `FMX_PAIRING_TOKEN` or the hosted relay.
A transient definite send failure (HTTP 429 or 5xx) before a successful Discord response deletes the posting marker so that generation can retry.
A permanent 4xx records a terminal failed marker so pending stops retrying that generation.
A posting marker without a receipt is refused so an ambiguous crash or transport error after Discord may have accepted the post cannot double-post.
An exclusive inflight send claim means two gateway processes cannot both post the same remaining chunk after a later-chunk resume.
A dead owner's claim older than `FM_EXT_INFLIGHT_TTL_SECS` (default 30) may be stolen; a live owner is never stolen from.
A generation left in-flight by an ambiguous send is reopened for another attempt once it has been stuck past `FM_EXT_MIDDELIVERY_RECOVERY_SECS` (default 300), and after `FM_EXT_MIDDELIVERY_RECOVERY_MAX` (default 3) attempts it is failed terminally and surfaced to Firstmate, so a network timeout cannot silently truncate a reply.
Delivered payloads are retired as soon as they have a receipt, so poll cost does not grow with the number of replies already sent, and leftover records expire after `FM_EXT_CONTEXT_MAX_AGE_SECS` (default and maximum 7 days).
`FM_EXT_OUTBOX_POLL_SECS` (default 2) sets how often the watcher drains the outbox.
Set `DISCORD_BOT_TOKEN` (or `HERMES_DISCORD_TOKEN`) for Discord REST delivery.
Firstmate core has no Discord library.

See [Local Communication Officer bridge](../../docs/configuration.md#local-communication-officer-bridge-configext-bridge).
