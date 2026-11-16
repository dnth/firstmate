---
name: cleanup
description: Report-first review of finished scouts and workers, stale working copies, leftover panes or processes, and reclaimable disk space. Use when the captain invokes /cleanup (e.g. "/cleanup", "what can we clean up", "free up disk space") or asks to list or clean up finished scouts, merged or done work, stale working copies, leftover resources, or disk space.
user-invocable: true
metadata:
  internal: true
---

# cleanup

`/cleanup` is a report-first, on-demand review of fleet resources that may be ready to remove: finished scouts and workers still open, stale pooled working copies, leftover panes or processes, and reclaimable disk space.
It removes nothing on its own, never forces, and runs only when the captain asks: it gathers evidence, reports, waits for the captain's word, and then executes only the removals the captain names.

## Safety rules

- Report first, always: no removal happens before the captain has seen the full report.
- Remove only what the captain names, exactly as named; a category-level approval is not a name.
- Never pass `--force` to `bin/fm-teardown.sh`, never use an unguarded removal path, and never bypass or work around a refusal; a task scratch directory under `/tmp` is the one item with no guarded owner, so it is removed only with `rm -rf` on the exact path the captain names.
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
- Give every damaged or orphaned slot one inventory row: measured size, the last owner when a readable claim or a prior state record names one, and whether any content looks recoverable - a working `git status` means readable content, while a broken admin link, a missing backing repository, or an unreadable tree means the content cannot be verified.
- Removal of a damaged copy never goes through a sweep tier: the captain names its exact path, and the removal stays a manual act, because a broken copy can still hold a live foreign consumer.
- Remote second mates' pools are report-only through the existing remote path: `bin/fm-on.sh <secondmate-id> fm-treehouse-sweep.sh --all` for each remote record in `data/secondmates.md`, with no removal through that route.

## Panes and processes

- List herdr workspaces and panes (`herdr workspace list`, `herdr pane list --workspace <id>`; the `herdr` skill owns the CLI) and cross-check each against live task metadata; `bin/fm-fleet-snapshot.sh` supplies the per-task endpoint evidence.
- List other resource users that look fleet-related - Docker stacks, containers, long-running processes - with the ownership evidence for each or the lack of it.
- This category is report-only: a pane or process is stopped only inside a task teardown the captain named, never directly.

## Disk space

This category ranks the reclaimable space on the filesystems the fleet writes to and removes nothing until the captain names an item.

- Start with the headline: `df -h` for `/`, `$HOME`, `/tmp`, and the filesystem holding `docker info --format '{{.DockerRootDir}}'`, plus the pooled-copies root when it lives on another mount.
- Rank the measured buckets largest first in the same four-column table as every other category, and put the measured size, the ownership class, the reclaim figure, and the owning command in the evidence cell.
- Ownership classes: task-owned (a finished task's own record names the path or artifact), tool cache (a tool's own cache directory), captain-personal (anything on the Desktop, `Downloads`, `Hermes`, or outside the Firstmate home).
- State a reclaim figure only when a dry run or the tool's own report measured it, and write `unknown` otherwise.
- Never add two Docker figures together, because one shared layer can sit in more than one bucket; an image size from `docker image ls` includes shared layers, so it is a size and never a reclaim figure.
- Never remove or move a captain-personal folder: report its size and suggest `keep for now`.
- Report-only until the captain names one item or an exact list; then run exactly that item's owning command once and re-measure.

Buckets and their owning commands:

- Docker - report the whole `docker system df` line first, then these as separate rows, each with Docker's own reclaimable figure:
  - unused build cache - tool cache; `docker builder prune`, with `--all` only when the captain names internal and frontend images too; removal costs rebuild time on the next build.
  - dangling images - unowned build leftovers, belonging to no recorded task; `docker image prune`; removal costs only rebuilding them.
  - named images no container uses - task-owned when the name matches a finished task and tool-owned otherwise; list them by name from `docker image ls` against `docker ps -a --format '{{.Image}}'` and the owning project's compose files, for example the `ifc-qa-*` QA stack images, and exclude images belonging to work that is still running; remove one with `docker image rm <image>` only after the captain names that image or that exact list; removal costs a rebuild or re-pull.
  - unused volumes - task-owned only when a finished task's own record proves it, and `not ready` otherwise; `docker volume ls -f dangling=true` and `docker system df -v` give the names and sizes; a volume holds whatever state the stack wrote, so removal is data loss; remove one with `docker volume rm <name>` only after the captain names that name.
- `uv` cache - `du -sh "$(uv cache dir)"`; tool cache; `uv cache prune` drops unreachable objects and `uv cache clean` empties the cache; removal costs re-downloading wheels and interpreters.
- Hugging Face cache - `du -sh ~/.cache/huggingface`, or `$HF_HOME` when it is set; tool cache; `hf cache delete` removes the revisions the captain picks; removal costs re-downloading model weights that run to tens of GB.
- `/tmp` scratch - `du -sh /tmp`, then `du -sh /tmp/* | sort -rh | head -20`; a directory stays `not ready` until a finished task's own record names that exact path, because a `fm-` name alone proves nothing, and a proven one is removed with `rm -rf <exact path>` only after the captain names it.
- Pooled working copies - measure the pool root; the "Stale working copies" category above owns the tiers, the damaged-copy inventory, and the remote pools.

## Report and execution

- Output one short table per category with columns: item, evidence, what removal costs, and a suggestion of `remove`, `keep for now`, or `not ready`.
- Then stop and wait for the captain's word; the report itself changes nothing.
- Execute only the removals the captain names: task teardowns through guarded `bin/fm-teardown.sh`, the approved clean tier through `bin/fm-treehouse-sweep.sh --apply-clean`, dirty or unpushed slots through `--apply-slot <path> --captain-approved`, and each named disk item through the owning command its row names, each under its own existing checks.
- After the named removals, re-run `bin/fm-todo-project.sh --emit` to refresh the session projection.

## What this skill is not

- It is not automatic removal: nothing here runs on a heartbeat, at session start, or as a consequence of a completion.
- It is not disk automation: no prune, threshold alert, or periodic sweep exists in this skill or behind it.
- It is not a new cleanup mechanism: every check and removal goes through the owning scripts and skills named above.
- It widens no authority: an open captain call, an unreadable claim, unprovable occupancy, or a refused check ends in `not ready` with the evidence, never in a workaround.
