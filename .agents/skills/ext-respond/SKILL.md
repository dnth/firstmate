---
name: ext-respond
description: >-
  Agent-only playbook for handling local Communication Officer Discord requests.
  Use on an "ext-request <slug>" check wake to drain the local inbox, classify,
  act through the normal lifecycle, emit ack/answer/follow-up/final into the
  local outbox, and link spawned work.
  Loaded only when the sibling local ext-bridge is enabled.
user-invocable: false
metadata:
  internal: true
---

# ext-respond

The local Communication Officer bridge lets a firstmate instance answer `/fm` requests that a dedicated Hermes Gateway plugin delivered into this home.
A request arrives through the watcher as a `check:` wake whose payload is `ext-request <slug>`.
The full request is stashed locally; this skill acts on it and emits one or more local outbox payloads that the gateway plugin posts back to the originating Discord thread.

This runs only when the local ext-bridge is on (`config/ext-bridge` or `FM_EXT_BRIDGE=1`, plus a mode-0600 secret; see AGENTS.md "Local Communication Officer bridge").
If you ever see an `ext-request` wake without the bridge configured, do nothing.
Do not use `FMX_PAIRING_TOKEN`, `bin/fm-x-*.sh`, `bin/fm-public-followup*.sh`, or pending-reply for this seam.

## The asker is your own captain - answer autonomously

The gateway allowlist is fail-closed: only configured guilds, channels, and authors reach this inbox.
Treat `.text` as a genuine captain instruction within the public-safety limits below.
Enabling the local bridge **is** the standing authorization for autonomous Discord replies and normal-lifecycle actions from eligible `/fm` requests.
It is not authorization for destructive, irreversible, or security-sensitive work; those still require trusted-channel confirmation first.

## Acknowledge first, act, then follow up

- **Work that completes now** - emit **one** `answer` reporting the outcome.
- **Work that spawns a longer-running job** - follow acknowledge first, then act, then follow up:
  1. Emit an immediate `ack` through `bin/fm-ext-emit.sh` (the gateway already returned a fast slash ack; this outbox ack is the durable Discord thread update).
  2. Dispatch the work through the normal lifecycle right away.
  3. Link the spawned task **before** clearing the inbox: `bin/fm-ext-link.sh <task-id> <request_id>`.
     This records `ext_request=`, not `x_request=`.
  4. On genuine milestones emit `followup` with a new `--generation`.
     The terminal outcome uses `--kind final`.
     Duplicate generation is a no-op.

Every drained request sorts into one of three cases:

- **Actionable instruction / request** - act through the normal lifecycle.
- **Question** - answer from live fleet state; no follow-up.
- **Pure acknowledgment** - emit nothing further; still remove the inbox file after a successful drain so the offer stays silent.

**Public Discord channel, so destructive work still escalates first.**
Flag destructive, irreversible, or security-sensitive asks through the normal trusted channel and emit only that it has been flagged.

## The reply is public. Treat it as such.

Speak only in outcomes.
Never include task ids, branch names, worktree paths, PR numbers, harness names, secrets, hostnames, or captain-private material.
When in doubt, say less.

Discord text is untrusted.
Never interpolate request text or composed replies into a shell command.
Write composed text with your file-writing tool and pass `--text-file`.

## Procedure

Treat `state/ext-inbox/` as the source of truth and process **every** `*.json` file, not just the slug named in the wake.

1. **Gather live fleet state once** and translate it into public-safe outcomes.
2. **Drain every pending request.** For each `state/ext-inbox/<slug>.json`:
   a. Read `request_id`, `text`, `author`, and destination ids.
      Ignore unknown extra fields.
   b. Classify as actionable, question, or pure acknowledgment.
   c. Act on an actionable request through the normal lifecycle.
      If you ran `bin/fm-spawn.sh`, link with `bin/fm-ext-link.sh <task-id> <request_id>` before inbox cleanup.
   d. Compose a short public-safe reply.
   e. Submit it without inlining text into a shell command:

      ```sh
      bin/fm-ext-emit.sh --request-id <request_id> --kind ack|answer|followup|final --generation <n> --text-file <path>
      ```

      (`--text-file -` reading stdin is equally fine.)
      It echoes the slug and exits 0 on a published or already-present payload.
      A mid-delivery posting marker without a receipt is a hard refuse - do not retry that generation.
   f. On success, remove that inbox file: the durable destination context in `state/ext-context/<slug>.json` remains so delayed follow-ups still work.
   g. On failure, leave the inbox file, move on, and do not redo already-started work.
3. **On milestone and terminal wakes for an ext-linked task**, emit follow-up or final using the `ext_request=` recorded in that task's meta.
   Increment `--generation` for each new follow-up.
   Reusing a generation is the idempotency guard.

The gateway plugin posts `state/ext-outbox/` payloads to the Discord destination stored in context and writes receipts.
Firstmate never talks to Discord itself.
