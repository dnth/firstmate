---
name: updatefirstmate
description: >-
  Self-update a running firstmate and its secondmates to the latest from origin.
  Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate").
  Fast-forwards this firstmate repo's default branch and every local or remote secondmate through its guarded update path (never forced, never disruptive), then re-reads AGENTS.md and restarts every live second mate through the persist-gated restart, with a fallback re-read nudge only where a restart cannot be proven.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (`AGENTS.md`, `bin/`, `.agents/skills/`, and public `skills/`) reaches `main` and then sits there until each running firstmate pulls it.
Only `AGENTS.md`, `bin/`, and `.agents/skills/` are a running firstmate instruction surface; public `skills/` is installer-facing and is not loaded by firstmate.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

Pulling files is only half of the update.
A running agent freezes AGENTS.md, loaded skills, and launch-time wiring at startup, so every live second mate left on the target commit is restarted, including one already current.
The updater leaves skipped homes untouched and routes any runtime that cannot prove a restart to an honest fallback nudge.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
For a remote route, it updates the configured Firstmate code root on that host from its own origin, then guardedly fast-forwards the persistent home to that code-root commit.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin, then updates every registered local or remote secondmate home through its placement-specific guarded path.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by three action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `restart-secondmates: fm-<id>...|none`
   - `nudge-secondmates: fm-<id>...|none`

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a real `@AGENTS.md` pointer to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Restart every second mate listed for restart.**
   Pass the whole `restart-secondmates:` list to one command (skip this step when it says `none`):
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-secondmate-restart.sh <fm-id>...
   ```
   The command first asks each mate to persist open conversational work, then relaunches only after its correlated answer arrives.
   Read `restarted:`, `nudged:`, and `unreached:` lines plus the closing `summary:` as the outcome, and never call a nudge a clean reload.

4. **Nudge the residual set.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that secondmate picks up its new instructions too:
   ```sh
   FM_HOME=<this-firstmate-home> bin/fm-send.sh <id> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   ```
   Include `FM_HOME=<this-firstmate-home>` unless `FM_HOME` is already set to the active firstmate home.
   This is a gentle steer, not an interruption: the secondmate already got a safe tracked-files fast-forward, and the nudge never forces, tears down, or discards its work.
   A secondmate that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

5. **Refresh the installed omp harness when present.**
   When `command -v omp` succeeds, run:
   ```sh
   bin/fm-omp-update.sh
   ```
   This invokes omp's supported update path for the executable already resolved on `PATH`; it never installs a second copy and never forces.
   Because that executable is shared by every local omp worker, the helper refuses unless the existing recovery-grade endpoint checks prove that every worker recorded in this home and every registered local secondmate home has stopped.
   A remote secondmate runs on another machine and is outside this local executable's update boundary.
   Relay any refusal without bypassing it, and leave the executable unchanged.
   When omp is absent, report it as not installed and skip this step.
   For detect-only use outside this attended update path, run `bin/fm-omp-update.sh --check`; it reports the current and available versions without inspecting or changing fleet state.

6. **Report to the captain in plain outcomes.**
   Summarize what landed under `AGENTS.md` section 9 without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both second mates are now on the latest."
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **The omp executable changes only after a stopped-fleet proof.**
  A live or unclassifiable local worker, unreadable local secondmate home, or unreadable registry is a refusal, and neither the skill nor its helper offers a force override.
  The helper never stops, restarts, or otherwise manages the shared no-mistakes daemon.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Nothing with work in it is disrupted.**
  A local or remote second mate gets a tracked-files fast-forward only when its own checkout is safe to advance.
  Restart replaces the agent in the same home and endpoint after open conversational work is persisted, and never forces or discards work.
  A skipped or unprovable target remains on the honest no-restart path.
