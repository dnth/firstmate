---
name: away-quiet-supervision
description: >-
  Agent-only away-mode safety facts. Load together with /afk whenever the captain invokes /afk or says they are going afk, state/.afk exists, an incoming message starts with FM_INJECT_MARK or the away-supervisor operational prefix, or any state/.subsuper-* marker is involved.
user-invocable: false
metadata:
  internal: true
---

# Away supervision safety

This fork has no quiet mode; the skill keeps upstream's name so ports stay aligned, and covers away mode only.
The `/afk` skill owns the daemon procedure; these safety facts apply whenever away mode is active or being entered:

- Every current daemon injection uses the `away-supervisor` kind from `bin/fm-operational-input.sh` after `FM_OPERATIONAL_PREFIX` (U+2063 INVISIBLE SEPARATOR followed by `FIRSTMATE_OP: `), while the `/afk` skill owns legacy bare-marker compatibility.
- While `state/.afk` exists, the daemon owns supervision; do not arm a separate watcher.
- A marked message while away mode is active is internal escalation and does not exit away mode.
- A message beginning `/afk` refreshes away mode.
- Any other unmarked message means the captain returned; load `/afk`, run the return owner, and do not process that message as ordinary work until its durable catch-up gate clears.
- Bias ambiguous input toward exit because a present captain takes precedence.
- `AGENTS.md` section 8 keeps the away-mode authority boundary inline: away mode never changes merge authority, finding-decision policy, or the captain boundaries.
