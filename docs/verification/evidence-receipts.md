# Evidence receipts and risk routing verification

This record captures the active maintainer evidence for ship-task acceptance receipts and conservative validation routing as of 2026-08-26.
The exact ledger schema, criterion parser, classifier thresholds, metadata fields, and lifecycle commands are owned by the headers and help output of `bin/fm-receipt.sh` and `bin/fm-receipt-check.sh`.

## Guarantees under test

- New ship briefs receive stable acceptance-criterion ids and an empty append-only evidence ledger, while scout and secondmate scaffolds remain outside the receipt contract.
- Every ship completion, including a promoted scout, remains parked until a valid acceptance contract and structurally valid evidence cover every required criterion.
- Low-risk routing is limited to narrow non-command CHANGELOG prose with file-bound mechanical proof for every changed file, while every other change defaults high.
- High-risk, broad, sensitive, weakly proven, materially expanded, or uncertain changes retain full No-Mistakes validation.
- `direct-PR` and `local-only` retain the evidence gate without entering No-Mistakes.
- Initial planning records one `validation_started_at`, and completion requires observed post-plan mechanical evidence, the exact No-Mistakes run created with the latest unguessable plan generation and bound to its path and head with current checks-green status or CI-log evidence, forge-observed canonical PR/head metadata, or a clean fast-forward-ready branch.
- Receipt appends open the canonical task directory and original single-link ledger through portable no-follow descriptors before validation, so concurrent path replacement cannot redirect evidence.
- Receipt checks snapshot the pinned non-symlink task contract and single-link ledger before parsing, so task replacement and external hard links cannot redirect completion evidence.
- Receipt append, check, and promotion consume one executable acceptance-criterion parser that requires nonblank descriptions.
- Structurally valid receipts with explicit failure inflections, negative, empty, equivalent zero-test orderings, or skip results remain recorded but leave their criteria unevidenced, while zero-failure success summaries and descriptive expected results such as `401` remain eligible.
- Normal and promoted ship briefs consume the same executable acceptance-evidence and per-mode delivery renderer.
- The pinned brief and task metadata must record the same concrete delivery mode before validation can proceed.
- Findings that invalidate a receipt or acceptance claim append one idempotent finding-to-criterion marker to task metadata.
- Successful exact-head runs can bind after reaching checks-passed or passed, while failed and cancelled runs remain ineligible.
- No-Mistakes status, intent, and CI-log observations use the shared bounded call boundary.
- Every completion requires path-specific terminal evidence, records its plan path and validated head, invalidates stale completion metadata when the worktree head changes, and refuses completion until the change is replanned or revalidated.
- Planning and completion refuse tracked, staged, or untracked worktree changes.
- Initial planning accepts a caller base only when it equals the repository's authoritative merge boundary, so a later ancestor cannot hide earlier task commits.
- Ordinary No-Mistakes findings return to the original worker through guarded custody return and then full revalidation.
- Direct-PR registration publishes its watcher before recording completion, while other paths preserve their earlier path-specific completion boundary.

## Verification environment

- Date: 2026-08-26.
- ShellCheck: 0.11.0.
- Git: 2.34.1.

## Commands and results

The focused behavioral suites passed with these exact commands.

```text
$ tests/fm-receipt.test.sh
ok - fm-receipt appends one compact validated receipt
ok - fm-receipt preserves prior records and accepts --result
ok - fm-receipt rejects invalid types, ids, missing results, and undeclared criteria
ok - fm-receipt refuses non-ship tasks and unsafe ledger paths
ok - fm-receipt rejects task-directory replacement before its no-follow open
ok - fm-receipt appends only through the ledger descriptor opened before validation

$ tests/fm-receipt-check.test.sh
ok - fm-receipt-check help renders an executable generation-bound bind command
ok - fm-receipt-check reports required, evidenced, and missing ids deterministically
ok - fm-receipt-check distinguishes complete evidence from invalid JSONL
ok - failed, skipped, empty, and zero-test results stay unevidenced while 401 counts
ok - pinned brief and metadata delivery modes must match exactly
ok - invalid ship briefs fail and scout/report behavior stays unchanged
ok - fm-receipt-check pins task evidence and rejects hard-linked ledgers
ok - receipt append and check consume one criterion grammar
ok - exact bound runs complete from the shared current CI-log readiness predicate
ok - finding-to-criterion invalidations remain inspectable in task metadata
ok - low-risk mechanical changes can skip a full No-Mistakes run
ok - low risk requires safe changelog prose and file-bound mechanical evidence
ok - successful terminal runs bind while failed runs remain rejected
ok - No-Mistakes status, intent, and CI-log observations are bounded
ok - authoritative documentation remains high
ok - terminal delivery paths record one completion timestamp at their boundary
ok - completion signals release the validation lock for retry
ok - replanning invalidates prior run and completion bindings
ok - dirty worktrees cannot be planned or completed
ok - direct and local plans never invoke No-Mistakes
ok - local completion requires fast-forward readiness
ok - security and uncertain changes retain full No-Mistakes validation
ok - direct-PR and local-only retain evidence gates without invoking No-Mistakes

$ tests/fm-crew-state.test.sh
ok - ship completion remains parked until every criterion has evidence
ok - ship completion fails closed when the evidence contract is malformed
ok - run-step done requires current-generation validation completion
ok - status-log done requires existing plan completion
all fm-crew-state tests passed

$ tests/fm-brief.test.sh
ok - fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly
ok - fm-brief: scout and secondmate code paths still scaffold well-formed briefs

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
exit 0
```

The named safety regressions also passed.

```text
$ tests/fm-watch-triage.test.sh
exit 0

$ bash tests/fm-ask-user-authority.test.sh
ok - primary workers and secondmates receive the authority rule through generated instructions

$ tests/fm-tangle-guard.test.sh
ok - fm-brief: ship brief asserts worktree isolation before the branch step
ok - fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree

$ tests/fm-pr-merge.test.sh
ok - fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge
ok - fm-pr-merge refuses before merging when task meta is missing

$ tests/fm-pr-check-security.test.sh
ok - valid direct and merge flows record exact metadata and reject multiline head metadata
exit 0

$ tests/fm-task-delivery.test.sh
ok - fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created
ok - fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree
ok - fm-promote: promotion installs a fail-closed ship evidence contract
# all fm-task-delivery tests passed

$ tests/fm-teardown-endpoint-safety.test.sh
ok - fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call
```
