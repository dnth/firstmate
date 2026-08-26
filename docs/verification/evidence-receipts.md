# Evidence receipts and risk routing verification

This record captures the active maintainer evidence for ship-task acceptance receipts and conservative validation routing as of 2026-08-26.
The exact receipt key and type schema is owned by the header and `--help` output of `bin/fm-receipt-schema.sh`; the criterion parser, classifier thresholds, metadata fields, and lifecycle commands are owned by the headers and help output of `bin/fm-receipt-check.sh`, `bin/fm-receipt.sh`, and `bin/fm-receipt-store.sh` at their respective executable boundaries.

## Guarantees under test

- New ship briefs receive stable acceptance-criterion ids plus an empty append-only evidence ledger and lock through one atomic pinned-directory publication, while scout and secondmate scaffolds remain outside the receipt contract.
- Concurrent ship scaffolds use one exclusive brief identity, so a losing invocation cannot remove the winning brief or evidence contract.
- Ship scaffold output requires replacing both task and acceptance-criterion placeholders, and spawn refuses unresolved task text or criteria before endpoint creation.
- Every ship completion, including a promoted scout, remains parked until a valid acceptance contract and structurally valid evidence cover every required criterion.
- Low-risk routing is limited to CHANGELOG formatting or reflow changes whose non-whitespace byte sequence is identical and which have file-bound mechanical proof, while every content-byte or uncertain change defaults high.
- High-risk, broad, sensitive, weakly proven, materially expanded, or uncertain changes retain full No-Mistakes validation.
- `direct-PR` and `local-only` retain the evidence gate and current-state reconciliation without entering No-Mistakes.
- The explicit implementation-complete action records one current timestamp for the current clean commit, refreshes that timestamp when the head changes, remains idempotent for the same head, and supplies the plan interval origin.
- Completion requires observed post-plan mechanical evidence, the exact No-Mistakes run created with the latest unguessable plan generation and bound to its path and head with current checks-green status or CI-log evidence, a GitHub PR with forge-observed exact-head metadata, a supported non-GitHub direct-PR with the existing canonical HTTPS PR URL predicate and no head observation, or a clean fast-forward-ready branch.
- Receipt append and check share one executable owner that resolves and pins every raw data-path component inside the store process, opens and verifies the task directory relative to that pinned parent, and then opens relative no-follow brief and single-link ledger paths portably on Linux and macOS.
- Receipt storage physicalizes the trusted Firstmate-home prefix for standard system symlinks, then retains no-follow checks for the data suffix, task directory, and task artifacts.
- Promotion pins and verifies its scout task directory before reading or replacing the brief and ledger, and refuses symlinked or out-of-root task paths before mutation.
- Promotion retries distinguish identity-bound unfinished rollback from committed retirement recovery, while post-commit reporting cannot reverse durable success.
- Planning retains the pinned shared ledger lock through metadata publication, so only receipts appended after the published plan boundary qualify as fresh mechanical evidence.
- The checker parent owns a read/write release descriptor before snapshot spawn, so early child failures cannot block cleanup waiting for a FIFO reader.
- Snapshot readiness status is checked and terminal on publication failure; hold documents ready `0`, refusal `1`, missing-ledger `3`, and pinned non-ship `4` statuses.
- Receipt append, check, and promotion consume one executable acceptance-criterion parser that requires nonblank descriptions.
- Structurally valid receipts require non-whitespace summary and result strings plus an explicit structured outcome; only `outcome=success` evidences a criterion, while failure, negative, zero, skipped, empty, placeholder, weak, and legacy outcomes remain unevidenced and `result` stays descriptive so expected observations such as `401` are unambiguous.
- Receipt append holds a stable task lock, copies the canonical single-link ledger plus one complete record to a synced mode-0600 single-link temporary file, and atomically renames it over the canonical ledger so concurrent hard-link aliases retain the old inode.
- Criterion parsing rejects known scaffold placeholder tokens in balanced or unmatched brace forms while allowing concrete brace syntax such as JSON examples.
- One shared cleanliness predicate requires `git status` with submodule ignores disabled to succeed with empty tracked, staged, untracked, and submodule output for implementation completion, planning, binding, terminal completion, and final done acceptance.
- Every plan requires a resolved authoritative base and commit diff before it can publish any delivery path.
- Every diff input, including the special-mode summary probe, must execute successfully before risk classification.
- Normal and promoted ship briefs consume the same executable acceptance-evidence and per-mode delivery renderer.
- The pinned brief and task metadata must record the same concrete delivery mode before validation can proceed.
- Ship state requires exactly one valid recorded delivery mode before any No-Mistakes lookup.
- Findings that invalidate a receipt or acceptance claim atomically bind one generation-scoped idempotent finding-to-criterion marker to the invalidation-time head and receipt boundary, then require a strict non-empty descendant delta and a later successful receipt bound to the new head before replanning or completion.
- One pinned state-directory owner snapshots single-link no-follow metadata and performs compare-bound atomic replacements for every validation metadata update.
- PR registration publishes canonical PR identity and its validation publication generation through one compare-bound pinned metadata replacement after the watcher artifacts publish, and revokes those artifacts if that replacement fails.
- Successful exact-head runs can bind after reaching checks-passed or passed, while failed and cancelled runs remain ineligible.
- No-Mistakes status, intent, and CI-log observations use the shared bounded call boundary.
- Every completion requires path-specific terminal evidence, records its plan path and validated head, invalidates stale completion metadata when the worktree head changes, and refuses completion until the change is replanned or revalidated.
- Local-only readiness and guarded landing consume one fail-closed executable default-branch resolver.
- Planning and completion refuse tracked, staged, or untracked worktree changes.
- Initial planning accepts a caller base only when it equals the repository's authoritative merge boundary, so a later ancestor cannot hide earlier task commits.
- Ordinary No-Mistakes findings return to the original worker through guarded custody return and then full revalidation.
- Direct-PR registration publishes its watcher before recording completion, while other paths preserve their earlier path-specific completion boundary.

## Known limitations

- Claim invalidation reads the worktree head immediately before acquiring the validation metadata lock, so an unsupported concurrent ref mutation can bind the marker to the earlier head; the single-operator workflow excludes that mutation during validation.
- PR registration snapshots and replaces metadata through separate pinned-store processes, so an unsupported concurrent byte-identical state-directory swap can move the transaction to the replacement directory; the single-operator workflow excludes state-directory replacement during validation.
- Backlog task `evidence-race-restructure` tracks a possible future single-owner transaction redesign if these concurrency assumptions change.

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
ok - fm-receipt appends complete large JSONL records
ok - fm-receipt rejects invalid types, ids, missing results, and undeclared criteria
ok - fm-receipt uses portable paths and rolls back incomplete appends
ok - fm-receipt refuses non-ship tasks and unsafe ledger paths
ok - fm-receipt rejects task-directory replacement before its no-follow open
ok - fm-receipt rejects data-directory replacement before its pinned open
ok - fm-receipt rejects regular data replacement after pinning
ok - fm-receipt atomically replaces the ledger without mutating hard-link aliases
ok - fm-receipt physicalizes trusted home prefixes but rejects data symlinks

$ tests/fm-receipt-check.test.sh
ok - fm-receipt-check help renders an executable generation-bound bind command
ok - fm-receipt-check reports required, evidenced, and missing ids deterministically
ok - fm-receipt-check distinguishes complete evidence from invalid JSONL
ok - structured success and negative outcomes control criterion evidence
ok - pinned brief and metadata delivery modes must match exactly
ok - pinned metadata owner rejects hard-linked validation records
ok - invalid ship briefs fail and scout/report behavior stays unchanged
ok - early snapshot failures release cleanup without a FIFO reader
ok - snapshot readiness publication failures terminate without waiting
ok - fm-receipt-check pins task evidence and rejects hard-linked ledgers
ok - receipt append and check consume one criterion grammar
ok - exact bound runs complete from the shared current CI-log readiness predicate
ok - finding-to-criterion invalidations remain inspectable in task metadata
ok - low-risk mechanical changes can skip a full No-Mistakes run
ok - low risk requires safe changelog prose and file-bound mechanical evidence
ok - implementation completion refreshes per head and remains idempotent
ok - plan publication holds the pinned ledger boundary against concurrent receipts
ok - diff summary errors fail closed before risk classification
ok - successful terminal runs bind while failed runs remain rejected
ok - No-Mistakes status, intent, and CI-log observations are bounded
ok - authoritative documentation remains high
ok - terminal delivery paths record one completion timestamp at their boundary
ok - completion signals release the validation lock for retry
ok - replanning invalidates prior run and completion bindings
ok - dirty worktrees cannot be planned or completed
ok - git status errors fail implementation, planning, and completion cleanliness gates
ok - shared cleanliness inspects ignored submodules
ok - direct and local plans never invoke No-Mistakes
ok - local completion requires fast-forward readiness
ok - local readiness and landing share one fail-closed default resolver
ok - security and uncertain changes retain full No-Mistakes validation
ok - direct-PR and local-only retain evidence gates without invoking No-Mistakes

$ tests/fm-crew-state.test.sh
ok - ship completion remains parked until every criterion has evidence
ok - ship completion fails closed when the evidence contract is malformed
ok - run-step done requires current-generation validation completion
ok - status-log done requires existing plan completion
ok - final done requires a clean inspectable worktree
ok - LOW validation remains parked until PR completion
ok - direct-PR and local-only state reads skip No-Mistakes
ok - ship state requires one valid mode before run lookup
all fm-crew-state tests passed

$ tests/fm-brief.test.sh
ok - fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly
ok - fm-brief: scout and secondmate code paths still scaffold well-formed briefs
ok - fm-brief: concurrent ship scaffolds preserve one complete owner
ok - fm-brief: ship evidence publication is atomic and retryable

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
ok - PR registration serializes with validation planning
ok - fast PR registration completes and keeps its watcher armed
ok - PR metadata publication rejects post-snapshot redirection
exit 0

$ tests/fm-task-delivery.test.sh
ok - fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created
ok - fm-promote-transaction: help renders successfully
ok - fm-spawn: unresolved task and criterion placeholders refuse before launch
ok - fm-spawn: scout and secondmate spawns refuse ship delivery flags
ok - fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree
ok - fm-spawn: a rigor downgrade against the registered posture is announced, never blocked
ok - fm-spawn: a scout spawn resolves no delivery posture from the registry
ok - fm-promote: promotion installs a fail-closed ship evidence contract
ok - fm-promote: symlinked task directories refuse before mutation
ok - fm-promote: configured data symlinks remain visible to no-follow pinning
ok - fm-promote: concurrent losers cannot remove the winner lock
ok - fm-promote: signal-terminated transactions fail closed
ok - fm-promote: interrupted task replacement rolls back atomically
ok - fm-promote: store signals before commit roll back both replacements
ok - fm-promote: intermediate state symlinks fail closed
ok - fm-promote: state path replacement cannot redirect metadata
ok - fm-promote: retry recovers an identity-bound crashed transaction
ok - fm-promote: post-commit reporting cannot reverse success
ok - fm-promote: committed retirement recovery preserves ship state
ok - fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw
# all fm-task-delivery tests passed

$ tests/fm-teardown-endpoint-safety.test.sh
ok - fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call
```
