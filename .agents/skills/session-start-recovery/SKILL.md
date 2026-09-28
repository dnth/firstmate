---
name: session-start-recovery
description: >-
  Agent-only reference for the session-start digest's composition. Load when the session-start digest reports recovery inputs, board drift, or output requiring interpretation, or before relying on the digest's section order, lock-dependent behavior, or contents.
user-invocable: false
metadata:
  internal: true
---

# Session-start recovery

1. **Lock** - acquires the per-home session lock first, before anything mutates shared state.
2. **Bootstrap** - detect-only checks (tool/version problems, GitHub auth, the worktree-tangle check, harness override, dispatch-profile validation, backlog-backend status) always run, but routine confirmations stay silent by default.
   When the lock could not be acquired, the worktree-tangle check uses read-only advisory wording without a checkout repair command.
   Home-local stale Herdr projection cleanup and the bootstrap MUTATING sweeps - same-home backlog reconciliation, fleet sync, secondmate convergence, secondmate liveness, pending remote handoff retry, X-mode artifact writes, and local ext-bridge artifact writes - run only when this session actually holds the lock from step 1.
   The secondmate liveness sweep deterministically accounts for every registered secondmate: it relaunches only from the recovery-grade `dead` or `missing` states, preserves ambiguous, unreadable, or unreachable remote targets, and reports skipped or failed guarantees as `SECONDMATE_LIVENESS:` lines (`bin/fm-bootstrap.sh`; `bin/fm-backend.sh`'s `fm_backend_agent_state`; `docs/remote-secondmates.md`).
3. **Wake queue** - when locked, presents the durable wake queue and prints the raw records prominently as this turn's first work queue; a clearly labeled status-event annotation may follow a valid `signal` record and includes every status line still unread at the presentation cursor, while the main actor may also receive a bounded `STATUS OUTCOME BACKSTOP` for every captain-facing event still without a recorded delivery receipt, but neither replaces the raw record or current-state reconciliation, and a lapsed watcher chain still surfaces here via the same guard alarm.
   Presented records remain durable until the handling turn runs the generation-bound acknowledgement printed by the drain.
   Every locked drain also prints a bounded fleet-wide `OPEN DECISIONS` section when durable decision records remain open, including when the queue itself is empty; reconcile those entries before continuing.
   The same drain prints every still-unread `note:` line and pending-reply resolution since the last presentation in an unbounded `UNREAD STATUS` section, so an answer buried under a later routine line is not dropped; those lines are not re-printed after that presentation.
   When the lock could not be acquired and verified, the queue is left untouched because no session mutation is authorized, and the guard's tangle/watcher-liveness alarms still print in read-only advisory mode without drain, supervision repair, or checkout repair commands.
4. **Supervision operating instructions** - after the wake queue, the digest emits exactly one operating block for the detected primary harness.
5. **Read-once contract** - before the fleet and context digests, the digest states when their sources may be read again after startup.
6. **Fleet-state digest** - the compact backlog listing owned by `bin/fm-session-start.sh`; every `state/<id>.meta`; a bounded tail of each task's `state/<id>.status` (labeled as wake-EVENT history, not current state, with the full log path printed for a deeper read); the `state/.afk` flag; and one cheap alive/dead read of each task's recorded backend endpoint.
   That liveness line is a fast presence check only, not a full state read - when you need a crew's actual current state (a run-step, not just "is the pane there"), read it with `bin/fm-crew-state.sh <id>` as before; the digest deliberately skips that deeper, slower read for every task so it stays fast and bounded.
7. **Context digest** - the full contents of `data/projects.md`, `data/secondmates.md`, `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md`, each clearly delimited.
   A file that does not exist prints an explicit `ABSENT` marker, never confused with an empty-but-present file: absence is meaningful (`captain.md` absent means use the firstmate repo's built-in defaults, `projects.md` absent means rebuild it from the clones under `projects/`, etc.).
8. **Next step** - after the context digest, the closing reminder points back to the emitted supervision block and preserves only the lock, afk, X-mode, and read-once reminders.
   The script itself never starts supervision; the emitted harness protocol owns the exact wait or wake mechanism.

`secondmate-provisioning` owns startup secondmate sync, liveness, and inherited local-material convergence.
