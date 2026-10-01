---
name: agent-skill-trigger-index
description: >-
  Complete trigger index for agent-only and captain-invocable skills. Load only when auditing or maintaining the complete skill trigger index.
user-invocable: false
metadata:
  internal: true
---

# Agent-only reference skills

These skills are not captain-invocable; load them only at their precise triggers.
- `bootstrap-diagnostics` - load whenever the session-start digest's bootstrap section prints an actionable diagnostic line (`MISSING:`, `MISSING_MANUAL:`, `BACKEND_INVALID:`, `NEEDS_GH_AUTH`, `TANGLE:`, `STARTUP_MEMORY_BUDGET:`, `CREW_DISPATCH: invalid`, `FLEET_SYNC:`, `BACKLOG_RECONCILE:`, `SECONDMATE_SYNC:`, `SECONDMATE_LIVENESS:`, `SECONDMATE_HANDOFF:`, `NUDGE_SECONDMATES:`, `TREEHOUSE_POOL:`, `FMX:`, or `EXT:`); silence and `BOOTSTRAP_INFO:` need no load.
- `diagnostic-reasoning` - load before scoping a reported bug and before acting on a diagnostic report.
- `ask-user-authority` - load before deciding any ask-user finding.
- `quota-array-dispatch` - load before choosing among a matched crew-dispatch profile array from current quota-axi output.
- `harness-adapters` - load before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, verifying a new harness adapter, or sending a captain-requested Cloud Devin `/handoff` to a live Devin CLI crew.
- `firstmate-orca` - load before switching to Orca, spawning or supervising Orca-backed work, smoke-testing Orca backend behavior, debugging Orca task state, or reconciling Orca-backed task metadata.
- `project-management` - load before adding, creating, removing, or initializing a project.
  Cloning or registering a project is add intake and uses the same trigger.
- `stuck-crewmate-recovery` - load when the session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window, or after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, a failed ordinary-worker steer, or an ordinary-worker `delivered-no-turn` or `delivered-no-turn-persistence-failed` verdict.
- `secondmate-provisioning` - load before creating, seeding, validating, launching, handing backlog to, recovering, pushing inherited local material into, or retiring a secondmate home, before editing `data/secondmates.md`, and on either verdict from a secondmate.
- `captain-hold-lifecycle` - load before treating an investigation or visual review as complete, before ending a visual review that exposed a captain decision, when recording or routing the captain's answer, and on any RECORD DIVERGENCE line the wake drain prints (`decision-hold-lifecycle` is a one-release redirect stub to it).
- `process-event-sources` - load before arming a long-polling source, before registering a deterministic condition->action watch (do X as soon as Y is true), and on any `procevent <adapter> <source-id> <sequence>` check wake.
  Never run a registered source's blocking command yourself in a conversational turn.
- `fmx-respond` - load on an `x-mention <request_id>` `check:` wake to handle the mention, on an `x-mode-error ...` `check:` wake to report the X-mode configuration blocker, on a `public-followup ...` `check:` wake or a startup-surfaced public commitment, and on any milestone or terminal wake for an X-mode-linked task before posting its completion follow-up; relevant only when X mode is on.
- `ext-respond` - load on an `ext-request <slug>` `check:` wake to drain the local Communication Officer inbox, classify, act through the normal lifecycle, and emit follow-ups into the local outbox; relevant only when the local ext-bridge is on.
- `firstmate-codexapp` - load before coordinating a visible Codex Desktop thread, evaluating a Codex App backend request, or reconciling Codex Desktop host-tool smoke evidence for Firstmate work.
- `firstmate-coding-guidelines` - load before changing firstmate's shared, tracked material, as defined by section 1's list, whether editing directly or briefing a crewmate for a firstmate-repo task.
- `operational-home-layout` - load when locating, interpreting, or changing Firstmate home, config, data, state, project, or generated runtime paths, and before touching any state/ file, since it marks which runtime records must never be touched.
- `session-start-recovery` - load when the session-start digest reports recovery inputs, board drift, or output requiring interpretation, or before relying on the digest's section order, lock-dependent behavior, or contents.
- `validation-supervision` - load on a ship worker's implementation-complete done:, whenever a ship starts or already has an active no-mistakes validation run, including a mid-run requirement change or finding, and before deciding or answering any ask-user finding.
- `ship-landing` - load on every PR-ready or ready-branch signal before reporting it, when deciding or monitoring landing, before writing or retiring a custom state check, and before any task teardown or secondmate retirement.
- `scout-completion` - load when a scout reports completion or is being considered for promotion to implementation.
- `away-quiet-supervision` - load together with /afk whenever the captain invokes /afk or says they are going afk, state/.afk exists, an incoming message starts with FM_INJECT_MARK or the away-supervisor operational prefix, or any state/.subsuper-* marker is involved.
- `agent-skill-trigger-index` - load only when auditing or maintaining the complete agent-only skill trigger index.

## Captain-invocable skills

These skills run only when the captain invokes them; this index records their load triggers for audit.
- `cleanup` - load when the captain invokes `/cleanup` or asks to list or clean up finished scouts, merged or done work, stale working copies, or leftover resources.
