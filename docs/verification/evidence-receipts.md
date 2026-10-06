# Evidence receipts verification

This record captures the active maintainer evidence for ship-task acceptance receipts as of 2026-10-06.
Evidence receipts establish whether the implementing worker accounted for every acceptance criterion the ship brief declares; they certify nothing about review, CI, No-Mistakes completion, or merge readiness.
The exact receipt key and type schema is owned by the header and `--help` output of `bin/fm-receipt-schema.sh`; the criterion parser and accounting contract are owned by `bin/fm-receipt-check.sh`, the writer by `bin/fm-receipt.sh`, and pinned storage by `bin/fm-receipt-store.sh`, each at its executable boundary.
Delivery gates that consume the accounting result are owned by `bin/fm-pr-check.sh` (PR-ready) and `bin/fm-crew-state.sh` (done acceptance); No-Mistakes run attribution and the ask-user decision audit are owned by `bin/fm-nm-run-lib.sh`.

## Guarantees under test

- New ship briefs receive stable acceptance-criterion ids plus an empty append-only evidence ledger and lock through one atomic pinned-directory publication, while scout and secondmate scaffolds remain outside the receipt contract.
- Concurrent ship scaffolds use one exclusive brief identity, so a losing invocation cannot remove the winning brief or evidence contract.
- Ship scaffold output requires replacing both task and acceptance-criterion placeholders, and spawn refuses unresolved task text or criteria before endpoint creation.
- Legacy ship briefs without an acceptance-criteria section may still launch with an explicit migration warning, but done acceptance remains parked until Firstmate installs a valid evidence contract.
- `fm-receipt-check.sh <id>` offers only the default check, `--criterion`, and `--parse-criteria`, emits one `fm-evidence-check.v2` object with `required`, `evidenced`, `accepted_blocked`, `missing`, and `invalid`, refuses every removed validation action as an unknown option, and writes no task metadata.
- The latest structurally valid receipt per criterion decides it: only `outcome=success` evidences a criterion, a later failure receipt revokes an earlier success until a fresh success lands, and `result` stays descriptive so an expected observation such as `401` recorded as success is evidence.
- A receipt naming an undeclared criterion, a malformed record, or a blank line makes the ledger invalid rather than silently disappearing.
- `outcome=accepted-blocked` is valid only with a non-empty `captain_exception` reference recorded verbatim; such a criterion is accounted for without being evidenced and is reported in the distinct always-present `accepted_blocked` list, never in `evidenced`.
- The checker never consults No-Mistakes: a tripwire `no-mistakes` binary records zero invocations across the whole accounting suite.
- Receipt append and check share one executable owner that resolves and pins every raw data-path component inside the store process, opens and verifies the task directory relative to that pinned parent, and then opens relative no-follow brief and single-link ledger paths portably on Linux and macOS.
- Receipt storage physicalizes the trusted Firstmate-home prefix for standard system symlinks, then retains no-follow checks for the data suffix, task directory, and task artifacts.
- Receipt append holds a stable task lock, copies the canonical single-link ledger plus one complete record to a synced mode-0600 single-link temporary file, and atomically renames it over the canonical ledger so concurrent hard-link aliases retain the old inode.
- The writer stamps no commit head onto a receipt; the schema still reads legacy head-stamped records.
- Promotion pins and verifies its scout task directory before reading or replacing the brief and ledger, refuses symlinked or out-of-root task paths before mutation, and distinguishes identity-bound unfinished rollback from committed retirement recovery.
- Receipt append, check, and promotion consume one executable acceptance-criterion parser that requires nonblank descriptions and rejects scaffold placeholder tokens while allowing concrete brace syntax.
- The pinned brief and task metadata must record the same concrete delivery mode before accounting proceeds.
- Every ship PR-ready through `bin/fm-pr-check.sh` requires complete acceptance evidence and names the missing or invalid criteria when it refuses; direct-PR registration never consults No-Mistakes.
- A no-mistakes PR-ready proves the run from No-Mistakes' own `axi status`: branch equal to the task branch, `pr` equal to the URL being armed, full `head_sha` equal to the forge's PR head, and a passed outcome or a green CI log; the run id is recorded as `nm_run_id=` and runs on another branch or PR, foreign heads, failed, cancelled, unfinished, or unobservable runs never arm.
- PR-ready and done acceptance apply the ask-user decision audit owned by `bin/fm-nm-run-lib.sh` against the recorded or attributed run, refusing a self-answered finding until a canonical firstmate `resolved [key=nm-<run>-<step>]: answered:` record exists and failing closed when the run's decision data cannot be read.
- `bin/fm-crew-state.sh` accepts a ship done only with a clean worktree, complete evidence, and `pr=` recorded for the PR modes or a clean checked-out `fm/<id>` branch for local-only.
- `bin/fm-spawn.sh --relaunch` carries `pr=`, `pr_head=`, and `nm_run_id=` into the replacement record, including a restart mid-handoff, and invents none for an unregistered task.
- PR registration publishes canonical PR identity through one compare-bound pinned metadata replacement after the watcher artifacts publish, revokes those artifacts if that replacement fails, serializes per task on `state/.<id>.pr-publication.lock`, and the watcher defers a valid pre-metadata poll only while that lock is fresh.

## Known limitations

- PR registration snapshots and replaces metadata through separate pinned-store processes, so an unsupported concurrent byte-identical state-directory swap can move the transaction to the replacement directory; the single-operator workflow excludes state-directory replacement during registration.
- The ask-user decision audit compares recorded gate responses with status-ledger records; it proves matching process records, not authenticated authorship (`bin/fm-classify-lib.sh` owns that limitation).

## Verification environment

- Date: 2026-10-06.
- ShellCheck: 0.11.0.
- Git: 2.34.1.

## Commands and results

The owning suites passed with these exact commands on 2026-10-06 (each exit 0).

```text
$ bash tests/fm-receipt-check.test.sh
ok - complete evidence reports the fm-evidence-check.v2 shape and exits 0
ok - a missing criterion is named and exits 1
ok - failure never satisfies, expected-negative success does, and the latest receipt per criterion wins
ok - unknown criteria and malformed records make the ledger invalid instead of vanishing
ok - accepted-blocked accounts for its criterion visibly without evidencing it
ok - receipt append, --criterion, and --parse-criteria consume one criterion grammar
ok - fm-receipt-check offers only accounting actions and writes no validation metadata
ok - pinned brief and metadata delivery modes must match exactly
ok - pinned metadata owner rejects hard-linked task records
ok - invalid ship briefs fail and scout/report behavior stays unchanged
ok - early snapshot failures release cleanup without a FIFO reader
ok - snapshot readiness publication failures terminate without waiting
ok - fm-receipt-check pins task evidence and rejects hard-linked ledgers
ok - receipt accounting never consults No-Mistakes

$ bash tests/fm-pr-check-handoff.test.sh
ok - direct-PR handoff proceeds on complete evidence and never consults No-Mistakes
ok - no-mistakes handoff records nm_run_id from a passed run matching branch, PR, and head
ok - an active run whose CI log reads green is PR-ready
ok - runs on another branch or PR, foreign heads, failed, unfinished, or unobservable runs never arm
ok - PR-ready refuses a self-answered ask-user finding until a firstmate decision record exists
ok - unreadable No-Mistakes decision data refuses PR-ready with its own reason

$ bash tests/fm-crew-state.test.sh
ok - ship completion requires complete acceptance evidence
ok - ship completion fails closed when the evidence contract is malformed
ok - PR-mode done requires the PR registered by fm-pr-check and a clean worktree
ok - local-only done requires the clean fm/<id> branch and no PR
ok - done acceptance applies the ask-user decision audit to the recorded run
all fm-crew-state tests passed

$ env -u FM_TASK_ID bash tests/fm-spawn-relaunch-dead-endpoint.test.sh
ok - fm-spawn --relaunch: pr=, pr_head=, and nm_run_id= survive a restart mid-handoff
ok - fm-spawn --relaunch: a task not yet registered gains no empty delivery records

$ env -u FM_TASK_ID bash tests/fm-pr-check-security.test.sh
ok - PR registration serializes on the per-task publication lock and releases it
ok - watcher defers valid pre-metadata polls while the publication lock is held
ok - watcher bounds pre-metadata deferral by publication lock freshness

$ bash tests/fm-receipt.test.sh
ok - fm-receipt writes no commit head while the schema still reads legacy head-stamped records
ok - fm-receipt gates accepted-blocked on a verbatim captain exception
```

`bash tests/fm-brief.test.sh` and `bash tests/fm-task-delivery.test.sh` passed on the same date, asserting that no generated or promoted ship brief instructs a removed receipt-check action or carries a plan generation.
`bin/fm-lint.sh` exited 0 with ShellCheck 0.11.0.

## Line accounting

`git diff --numstat dad3e4a58cac6f3f450523b9dcd72e754d8e1753 -- bin/ tests/` reports the following totals for the reviewed change through `e37e2baab4de89daa412bc8bc3d30db7e3c699aa`.

| Scope | Lines removed | Lines added |
| --- | ---: | ---: |
| Production (`bin/`) | 1,550 | 297 |
| Tests (`tests/`) | 2,892 | 750 |
