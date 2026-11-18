---
name: cleanup
description: Report-first review of finished scouts and workers, stale pooled working copies on local and remote second mates, leftover panes or processes, and reclaimable disk space. Use when the captain invokes /cleanup or /cleanup sweep (e.g. "/cleanup", "/cleanup sweep", "sweep the finished copies", "sweep once", "what can we clean up", "free up disk space") or asks to list or clean up finished scouts, merged or done work, stale working copies, remote second-mate pool copies, leftover resources, or disk space.
user-invocable: true
metadata:
  internal: true
---

# cleanup

`/cleanup` is a report-first, on-demand review of fleet resources that may be ready to remove: finished scouts and workers still open, stale pooled working copies, leftover panes or processes, and reclaimable disk space.
It removes nothing on its own, never forces, and runs only when the captain asks: it gathers evidence, reports, waits for the captain's word, and then executes only the removals the captain names.
`/cleanup sweep` is the narrow on-demand mode: it reports only pooled working copies, then runs the approved local clean-tier pass once.

## Safety rules

- Report first, always: no removal happens before the captain has seen the full report.
- Remove only what the captain names, exactly as named; a category-level approval is not a name.
- Never pass `--force` to `bin/fm-teardown.sh`, never use an unguarded removal path, and never bypass or work around a refusal; a task scratch directory under `/tmp` and a damaged or orphaned pooled slot are the items with no guarded removal owner, so each is removed only with `rm -rf` on the exact path the captain names.
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

## Pooled working copies (slots)

This section is the single owner of the local and remote slot-clearing procedure.
`bin/fm-treehouse-sweep.sh`'s header owns the tier definitions, the ownership proof, the exact flags, and the refusal mechanics; this section owns the evidence to gather, what the captain must name, and how to report and stop a pass.

### Inventory and evidence

- Run `bin/fm-treehouse-sweep.sh --all` for the read-only classification, and keep its slot rows; its header owns the tier definitions.
- Combine each pooled slot with board and PR facts: `bin/fm-tasks-axi.sh show <id>` for the task and `gh-axi` for whether its PR is merged.
- Record the evidence per slot: owning task, PR state, and any commits not on the backing repo's default ref.
- Give every damaged or orphaned slot one inventory row: measured size, the last owner when a readable claim or a prior state record names one, whether any content looks recoverable, and the ignored-but-large content described below.
  A working `git status` means readable content, while a broken admin link, a missing backing repository, or an unreadable tree means the content cannot be verified.
- A tracked-file comparison against the backing repo's origin default ref may be recorded in that row as evidence only.
  It covers only the slot's non-ignored tree.
  It cannot prove the absence of unlanded local history, ignored-file data such as `.scratch/` or test-data snapshots, or a live foreign consumer.
  It never reclassifies a damaged slot as clean or safe, and it never substitutes for the captain naming the exact path.
- Every damaged or orphaned row must also name the slot's ignored-but-large content: its measured size and its top-level entries that do not appear in the tracked comparison, so the captain sees that content before deciding.
  Measure the slot with `du -sk <path>` and name the top-level entries with their sizes, for example `.scratch/`, test-data directories, caches, or snapshots.

### Removal tiers

- Proven clean slots are removable locally only through the config-gated `--apply-clean` tier when the captain approves that clean-tier pass wholesale; clean slots are never removed per slot.
- Dirty or unpushed slots are report-only until the captain names the exact path; then remove only through `--apply-slot <path> --captain-approved`.
  Claimed, meta-named, occupied, or damaged slots remain `not ready`.
- Removal of a damaged or orphaned copy never goes through a sweep tier, because a broken copy can still hold a live foreign consumer.
  The captain names its exact path, and the removal stays a manual act on the host that owns the pool: `rm -rf <exact path>`, then remove only that path's entry from the pool's `treehouse-state.json` when one exists.
  Back up the state file, then remove only the entry whose `path` matches the exact slot, for example: `jq --arg p '<exact path>' '.worktrees |= map(select((.path // "") != $p))' treehouse-state.json > treehouse-state.json.new && mv treehouse-state.json.new treehouse-state.json`.
  Touch no other entry.
- Every sweep-tier removal above is a tracked command run on the host that owns the pool; the damaged-slot act is the documented manual exception.
  Never send a removal as a free-text steer to a local worker or a remote second mate.

### Remote second mates

- Report each remote pool through `bin/fm-on.sh <secondmate-id> fm-treehouse-sweep.sh --all`, for each remote record in `data/secondmates.md`.
- A remote dirty slot is removed only when the captain names its exact path, through `bin/fm-on.sh <secondmate-id> fm-treehouse-sweep.sh --apply-slot <path> --captain-approved`.
  Run one named path per invocation; never send the removal as a free-text steer to the remote agent.
  Remote clean slots remain report-only; there is no remote bulk removal route.
- A remote damaged or orphaned slot is `not ready` for the tracked route, because `--apply-slot` refuses it.
  Report the exact host commands from the removal tiers for the captain to approve and run on that host; never send them as a free-text steer.

### Stopping an in-flight removal

- A running local `--apply-clean` pass checks the home's `state/treehouse-sweep-stop` marker before the first slot and between every slot.
  Request the local stop with `bin/fm-treehouse-sweep.sh --stop`.
  The pass consumes the marker, names the slots it removed and the slots it did not attempt, and exits with its stopped status; its header owns the exact output and code.
  A marker left by a crashed pass makes the next apply pass stop before removing anything; it is consumed once, and the pass is re-run only after the captain's approval still stands.
- A single-slot `--apply-slot` pass consumes a marker before it removes anything and refuses with nothing changed.
- The marker is honored only between slots.
  A slot already inside `treehouse destroy` finishes, or an external kill can leave it partly removed; the marker cannot interrupt it.
- A remote invocation is synchronous and not preemptible through `bin/fm-on.sh`.
  On a stop request, issue no further per-path invocation; the in-flight path finishes or is left partial and must be measured.
  Do not queue `--stop` behind the remote invocation as an interruption mechanism.
- After any stop, before saying "stopped", "paused", or naming what survived, re-measure every named path on the host that owns the pool: path existence, `du -sk`, and a fresh read-only classification.
  Use `bin/fm-treehouse-sweep.sh --measure <path>` locally, repeating `--measure <path>` for every named path.
  On a remote host, use `bin/fm-on.sh <secondmate-id> fm-treehouse-sweep.sh --measure <path>` with the same repeated arguments, never a local copy of the paths.
  Preserve the before-removal measurements for comparison; existence, size, and classification alone cannot prove surviving content is unchanged.
  If measurement refuses or fails, report the stop as unverified.
  Report each named path as fully removed (the path is gone), partly removed (the path exists and its content is incomplete or unverifiable), or untouched (unchanged).
  An acknowledged steer is never evidence of a stop, and a pass's own removed/untouched list is a starting point, not the host measurement.

## Sweep mode

`/cleanup sweep` is the narrow on-demand mode: it reports only pooled working copies, then runs the approved local clean-tier pass once.
Remote pools follow "Remote second mates" above; this mode runs a clean-tier removal pass only locally.
It composes the "Pooled working copies (slots)" rules above and adds no authority; that section still owns the tiers, the ownership proof, and every guard.

- Check the opt-in flag first: when the `config/treehouse-sweep-clean` flag under the Firstmate home is absent, say so, name the flag, and stop, because `--apply-clean` refuses without it.
- Run `bin/fm-treehouse-sweep.sh --all` for the read-only classification and keep its slot rows; its header owns the tier definitions, and no row's tier is re-decided here.
- Measure each listed copy with `du -sk <path>`: the clean-tier reclaim figure is the sum of the measured clean rows, because treehouse's own reclaim line covers its whole stale set rather than this clean tier.
- For each `clean` row, run `find <path> ! -user "$(id -u)" -print -quit 2>/dev/null`; flag a printed path as foreign-owned and a potential deletion obstacle, without predicting failure or recommending sudo removal before a failure occurs.
- Show one short table with columns tier, path, measured size, and suggestion; the clean rows total is the reclaim figure for the pass.
- Clean rows suggest the `--apply-clean` pass; every other row is report-only with the existing suggestion - `not ready` for skipped, damaged, claimed, leased, occupied, or unverifiable copies, and for a dirty slot only `bin/fm-treehouse-sweep.sh --apply-slot <path> --captain-approved` with the exact path, which this mode never runs.
- Stop and wait for one word: that word approves the clean-tier pass wholesale, which is the approval the "Pooled working copies (slots)" rules already require, and it never authorizes a per-slot removal.
- On that word, capture `df -h` and `df -k` for each filesystem holding pooled copies, then run `bin/fm-treehouse-sweep.sh --apply-clean` once and preserve its exit status and output.
- If the pass stops between slots, follow "Stopping an in-flight removal" before reporting the partial result.
- Whether the pass succeeds, refuses, or fails partway, repeat those filesystem measurements and the `--all` classification, then report which copies were removed and every copy left behind, comparing the before and after available blocks to report the observed filesystem space change, including partial deletion within surviving copies.
- Report a refusal or a failed slot plainly and stop: no retry, no second pass, no `--force`, no workaround.
- When a failed or partly deleted copy holds paths the current user does not own, list each one as an exact `sudo rm -rf <path>` line for the captain to run; firstmate never runs sudo.

## Panes and processes

- List herdr workspaces and panes (`herdr workspace list`, `herdr pane list --workspace <id>`; the `herdr` skill owns the CLI) and cross-check each against live task metadata; `bin/fm-fleet-snapshot.sh` supplies the per-task endpoint evidence.
- List other resource users that look fleet-related - Docker stacks, containers, long-running processes - with the ownership evidence for each or the lack of it.
- This category is report-only: a pane or process is stopped only inside a task teardown the captain named, never directly.

## Disk space

This category ranks the reclaimable space on the filesystems the fleet writes to and removes nothing until the captain names an item.

- Start with the headline: `df -h` for `/`, `$HOME`, `/tmp`, and the filesystem holding `docker info --format '{{.DockerRootDir}}'`, plus the pooled-copies root when it lives on another mount.
- Rank the measured buckets largest first in the same four-column table as every other category, and put the measured size, the ownership class, the reclaim figure, and the owning command in the evidence cell.
- Ownership classes: task-owned (a finished task's own record names the path or artifact), tool cache (a tool's own cache directory), captain-personal (`Downloads`, `Hermes`, and anything on the Desktop outside the Firstmate home).
- State a reclaim figure only when a dry run or the tool's own report measured it, and write `unknown` otherwise.
- Never add two Docker figures together, because one shared layer can sit in more than one bucket; an image size from `docker image ls` includes shared layers, so it is a size and never a reclaim figure.
- Never remove or move a captain-personal folder: report its size and suggest `keep for now`.
- Report-only until the captain names one item or an exact list; then run exactly that item's owning command once and re-measure.

Buckets and their owning commands:

- Docker - report the whole `docker system df` line first, then these as separate rows, each with Docker's own reclaimable figure:
  - unused build cache - tool cache; `docker builder prune` removes only dangling build cache; use `docker builder prune --all` only when the captain approves the whole unused build cache; removal costs rebuild time on the next build.
  - dangling images - unowned build leftovers, belonging to no recorded task; `docker image prune`; removal costs only rebuilding them.
  - named images no container uses - task-owned when the name matches a finished task and tool-owned otherwise; resolve each candidate tag to its immutable image ID and compare those IDs against every container's image, because several tags can share one ID and a tag can look unused while a stopped container still references that image; exclude images belonging to work that is still running; remove one with `docker image rm <image>` only after the captain names that image or that exact list, say when removing one alias of a shared ID only untags it and reclaims nothing, and count the cost as a rebuild or re-pull.
  - unused volumes - task-owned only when a finished task's own record proves it, and `not ready` otherwise; `docker volume ls -f dangling=true` and `docker system df -v` give the names and sizes; a volume holds whatever state the stack wrote, so removal is data loss; remove one with `docker volume rm <name>` only after the captain names that name.
- `uv` cache - `du -sh "$(uv cache dir)"`; tool cache; `uv cache prune` drops unreachable objects and `uv cache clean` empties the cache; removal costs re-downloading wheels and interpreters.
- Hugging Face cache - `du -sh ~/.cache/huggingface`, or `$HF_HOME` when it is set; tool cache; confirm the exposed form with `hf cache --help` before naming the removal command in the report: `hf cache delete` below huggingface_hub v1.0, or `hf cache rm <revision...>` from v1.0, for only the revisions the captain picks; removal costs re-downloading model weights that run to tens of GB.
- `/tmp` scratch - `du -sh /tmp`, then `du -sh /tmp/* | sort -rh | head -20`; a directory stays `not ready` until a finished task's own record names that exact path, because a `fm-` name alone proves nothing, and a proven one is removed with `rm -rf <exact path>` only after the captain names it.
- Pooled working copies - measure the pool root; the "Pooled working copies (slots)" section above owns the tiers, the damaged-copy inventory, and the remote pools.

## Report and execution

- Output one short table per category with columns: item, evidence, what removal costs, and a suggestion of `remove`, `keep for now`, or `not ready`.
- Then stop and wait for the captain's word; the report itself changes nothing.
- Execute only the removals the captain names: task teardowns through guarded `bin/fm-teardown.sh`, the approved clean tier through `bin/fm-treehouse-sweep.sh --apply-clean`, dirty or unpushed slots through `--apply-slot <path> --captain-approved`, and each named disk item through the owning command its row names, each under its own existing checks.
  A remote second mate's removal follows "Remote second mates" above, one exact captain-named dirty path per tracked invocation.
- After the named removals, re-run `bin/fm-todo-project.sh --emit` to refresh the session projection.

## What this skill is not

- It is not automatic removal: nothing here runs on a heartbeat, at session start, or as a consequence of a completion.
- It is not disk automation: no prune, threshold alert, or periodic sweep exists in this skill or behind it.
- It is not a new cleanup mechanism: every check and removal goes through the owning scripts and skills named above.
- It widens no authority, local or remote: an open captain call, an unreadable claim, unprovable occupancy, or a refused check ends in `not ready` with the evidence, never in a workaround.
