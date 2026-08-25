# Evidence receipts and risk routing verification

This record captures the active maintainer evidence for ship-task acceptance receipts and conservative validation routing as of 2026-08-26.
The exact ledger schema, criterion parser, classifier thresholds, metadata fields, and packet commands are owned by the headers and help output of `bin/fm-receipt.sh` and `bin/fm-receipt-check.sh`.

## Guarantees under test

- New ship briefs receive stable acceptance-criterion ids and an empty append-only evidence ledger, while scout and secondmate scaffolds remain outside the receipt contract.
- Every ship completion, including a promoted scout, remains parked until a valid acceptance contract and structurally valid evidence cover every required criterion.
- Low-risk routing is limited to narrow mechanically proven documentation positively classified as non-authoritative prose or allowlisted configuration changes with file-bound proof.
- Medium-risk routing requires an explicit localized-non-sensitive change class and creates a bounded task, evidence, diff, and risky-area audit packet.
- High-risk, broad, sensitive, weakly proven, materially expanded, or uncertain changes retain full No-Mistakes validation.
- `direct-PR` and `local-only` retain the evidence gate without entering No-Mistakes.
- Medium follow-up review requires a fresh localized-non-sensitive classification, a non-empty strict-descendant delta from the latest recorded validation head, and post-boundary replacement receipts for every invalidated criterion.
- Follow-up work without fresh positive safety evidence or with material risk expansion requires a full rerun.
- Initial planning records one `validation_started_at`, and completion requires observed post-plan mechanical evidence, the exact successful No-Mistakes run bound to the latest plan/path/head, forge-observed canonical PR/head metadata, or a clean fast-forward-ready branch.
- Every completion requires path-specific terminal evidence, records its plan path and validated head, invalidates stale completion metadata when the worktree head changes, and refuses completion until the change is replanned or revalidated.
- Planning and completion refuse tracked, staged, or untracked worktree changes.
- Initial planning accepts a caller base only when it equals the repository's authoritative merge boundary, so a later ancestor cannot hide earlier task commits.
- Ordinary No-Mistakes findings at every risk tier return to the original worker through guarded custody return, while only medium-risk follow-up remains bounded.
- PR-ready recording preserves the path-specific completion boundary instead of replacing it with later PR-monitor setup time.

## Verification environment

- Date: 2026-08-26.
- ShellCheck: 0.11.0.
- Git: 2.34.1.
- The receipt and crew-state integration is harness-neutral because every verified harness consumes the same generated brief, task data, status event, and `fm-crew-state.sh` boundary.
- The integration is backend-neutral because it does not change endpoint operations and reads only the common `kind`, `mode`, and `worktree` task metadata recorded for tmux, Herdr, Zellij, Orca, and cmux.

## Commands and results

The focused behavioral suites passed with these exact commands.

```text
$ tests/fm-receipt.test.sh
ok - fm-receipt appends one compact validated receipt
ok - fm-receipt preserves prior records and accepts --result
ok - fm-receipt rejects invalid types, ids, missing results, and undeclared criteria
ok - fm-receipt refuses non-ship tasks and unsafe ledger paths

$ tests/fm-receipt-check.test.sh
ok - fm-receipt-check reports required, evidenced, and missing ids deterministically
ok - fm-receipt-check distinguishes complete evidence from invalid JSONL
ok - invalid ship briefs fail and scout/report behavior stays unchanged
ok - low-risk mechanical changes can skip a full No-Mistakes run
ok - low documentation requires positive non-authoritative prose classification
ok - terminal delivery paths record one completion timestamp at their boundary
ok - completion signals release the validation lock for retry
ok - dirty worktrees cannot be planned or completed
ok - low config requires an allowlisted path and applicable proof
ok - medium-risk work produces a brief, evidence, diff, and risky-area audit packet
ok - security and uncertain changes retain full No-Mistakes validation
ok - direct-PR and local-only retain evidence gates without invoking No-Mistakes
ok - follow-up validation is bounded to the finding, delta, and updated receipts
ok - material follow-up scope changes retain full No-Mistakes validation

$ tests/fm-crew-state.test.sh
ok - ship completion remains parked until every criterion has evidence
ok - ship completion fails closed when the evidence contract is malformed
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

The broader teardown suite passed its unlanded-work refusal cases on this host before reaching its existing content-in-default fixture, which requires `git merge-tree --write-tree` support unavailable in Git 2.34.1.
The unsupported fixture exited nonzero without changing the receipt implementation, and the portable teardown endpoint-safety suite above completed successfully.
