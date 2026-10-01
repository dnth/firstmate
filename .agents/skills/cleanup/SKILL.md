---
name: cleanup
description: Report-first review of finished scouts and workers, stale working copies, and leftover panes or processes. Use when the captain invokes /cleanup (e.g. "/cleanup", "what can we clean up") or asks to list or clean up finished scouts, merged or done work, stale working copies, or leftover resources.
user-invocable: true
metadata:
  internal: true
---

# cleanup

`/cleanup` is a report-first, on-demand review of fleet resources that may be ready to remove: finished scouts and workers still open, stale pooled working copies, and leftover panes or processes.
It removes nothing on its own, never forces, and runs only when the captain asks: it gathers evidence, reports, waits for the captain's word, and then executes only the removals the captain names.

## Safety rules

- Report first, always: no removal happens before the captain has seen the full report.
- Remove only what the captain names, exactly as named; a category-level approval is not a name.
- Never pass `--force` to `bin/fm-teardown.sh`, never use an unguarded removal path, and never bypass or work around a refusal.
- A `remove` suggestion for a working copy requires a verified read-only inventory of that copy taken in this pass: uncommitted files and commits not on the backing repo's default ref.
- A dirty or unpushed pooled slot is removable only when the captain names its exact path, and then only through `bin/fm-treehouse-sweep.sh --apply-slot <path> --captain-approved`.
- Panes, processes, Docker stacks, and containers are report-only: never stop anything that is not provably task-owned, and never without the captain naming it.
- Missing, unreadable, or unverifiable evidence means `not ready`, never `probably safe`.
- This skill adds no scripts, daemons, heartbeat steps, or automatic triggers; it composes the existing owners named below.

## Finished scouts and workers still open

For each recorded task whose endpoint or working copy may still be live:

- Read current state through `bin/fm-crew-state.sh`, never from a status-log tail.
- Confirm the deliverable exists and is non-empty: `data/<id>/report.md` for a scout, or the recorded PR and acceptance receipts for a ship.
- Confirm the completion's delivery receipt is recorded; `bin/fm-branch-outcome.sh` owns the receipt ledger and `undelivered` lists obligations still owed.
- Check the completion gate shows no open captain call: `bin/fm-captain-hold.sh open <task-id>` is the read-only predicate and `complete` records the attestation; `captain-hold-lifecycle` owns the policy.
- Take a read-only inventory of the working copy: `git status --porcelain` for uncommitted files and the unpushed-commit list against its tracking ref.
- Report existence alone is never enough: removing a scout keeps its report but discards scratch files and live context, so the suggestion must state what removal costs.
- Load `ship-landing` before suggesting or performing any task teardown; it owns the teardown decision procedure.

## Stale working copies for done or merged tasks

- Run `bin/fm-treehouse-sweep.sh --all` for the read-only classification; its header owns the tier definitions.
- Combine each pooled slot with board and PR facts: `bin/fm-tasks-axi.sh show <id>` for the task and `gh-axi` for whether its PR is merged.
- Record the evidence per slot: owning task, PR state, and any commits not on the backing repo's default ref.
- Proven clean slots are removable only through the config-gated `--apply-clean` tier when the captain approves that clean-tier pass wholesale; clean slots are never removed per slot.
- Dirty or unpushed slots are report-only until the captain names the exact path; then remove only through `--apply-slot <path> --captain-approved`. Claimed, meta-named, occupied, or damaged slots remain `not ready`.

## Panes and processes

- List herdr workspaces and panes (`herdr workspace list`, `herdr pane list --workspace <id>`; the `herdr` skill owns the CLI) and cross-check each against live task metadata; `bin/fm-fleet-snapshot.sh` supplies the per-task endpoint evidence.
- List other resource users that look fleet-related - Docker stacks, containers, long-running processes - with the ownership evidence for each or the lack of it.
- This category is report-only: a pane or process is stopped only inside a task teardown the captain named, never directly.

## Report and execution

- Output one short table per category with columns: item, evidence, what removal costs, and a suggestion of `remove`, `keep for now`, or `not ready`.
- Then stop and wait for the captain's word; the report itself changes nothing.
- Execute only the removals the captain names: task teardowns through guarded `bin/fm-teardown.sh`, the approved clean tier through `bin/fm-treehouse-sweep.sh --apply-clean`, and dirty or unpushed slots through `--apply-slot <path> --captain-approved`, each under its own existing checks.
- After the named removals, re-run `bin/fm-todo-project.sh --emit` to refresh the session projection.

## What this skill is not

- It is not automatic removal: nothing here runs on a heartbeat, at session start, or as a consequence of a completion.
- It is not a new cleanup mechanism: every check and removal goes through the owning scripts and skills named above.
- It widens no authority: an open captain call, an unreadable claim, unprovable occupancy, or a refused check ends in `not ready` with the evidence, never in a workaround.
