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
Firstmate opt-in is `config/ext-bridge` or `FM_EXT_BRIDGE=1` plus `config/ext-secret` (mode 0600) and `config/ext-allowlist`.

Allowlist lines are fail-closed:

```
<guild>
<guild>:<channel>
<guild>:<channel>:<author>
```

The plugin registers slash command `fm`.
It writes Discord text to a temp file and execs `bin/fm-ext-intake.sh --text-file`.
It never calls `dispatch_tool("terminal", ...)`.
The slash handler returns a fast ack without waiting for Firstmate to finish the work.

An outbox watcher drains `state/ext-outbox/` through `bin/fm-ext-outbox.sh`.
Unsent payloads retry after a gateway restart.
A transient definite send failure (HTTP 429 or 5xx) before a successful Discord response deletes the posting marker so that generation can retry.
A permanent 4xx records a terminal failed marker so pending stops retrying that generation.
A posting marker without a receipt is refused so an ambiguous crash or transport error after Discord may have accepted the post cannot double-post.
Set `DISCORD_BOT_TOKEN` (or `HERMES_DISCORD_TOKEN`) for Discord REST delivery.
Firstmate core has no Discord library.

See [Local Communication Officer bridge](../../docs/configuration.md#local-communication-officer-bridge-configext-bridge).
