---
name: test-audit
description: >-
  Audit a project's test value, review mutation-proven pruning batches, or commission an explicit subsystem campaign.
user-invocable: true
disable-model-invocation: true
metadata:
  internal: true
---

# Test audit

Invoke `/test-audit` with a project and module, package or test-directory scope.
Audit is the default; Prune requires captain-picked batches; Campaign requires an explicit captain request.
Firstmate commissions the work and runs the visual review; workers own project edits and experiments.
Adapted from [openclaw's MIT-licensed test-audit skill](https://github.com/openclaw/openclaw/tree/main/.agents/skills/test-audit); [third-party notice](THIRD_PARTY_NOTICES.md) covers the adapted files.

## Firstmate procedure

1. **Scope.** Resolve project, owning home and prior reports through `AGENTS.md` section 7.
   Pin the audited ref to a full commit and identify bounded paths, production owners and the requested mode.
   Load [the audit reference](references/audit.md) before writing the worker's instructions; load [Campaign](CAMPAIGN.md) only for that mode.
   Done when one project, commit, scope and mode are recorded, with existing evidence accounted for.
2. **Sample.** Commission a small representative owner sample before a full Audit or Campaign, using the normal scout lifecycle and `bin/fm-brief.sh --scout` scaffold.
   Bound the sample by named files and declarations, not a deletion target; include likely overlap and an independent-contract area.
   Supply the worker contract below, preserving the scaffold's isolation and report requirements.
   Load `harness-adapters` and resolve dispatch on the written instructions through `AGENTS.md` section 4.
   Done when the scout returns a complete sample ledger, measured read/run cost, R/F/C/D counts, mutation withdrawals and expected payoff with uncertainty.
3. **Yield.** Relay the sample's yield before expanding scope; a disciplined suite may offer almost nothing worth pruning.
   Recommend stopping when the cost exceeds the likely gain; obtain the captain's choice to stop, expand Audit, or proceed with the explicitly requested Campaign.
   Use existing equivalent sample evidence only when its commit and scope still apply.
   Done when the expansion choice and its exact scope are recorded; silence does not authorize expansion.
4. **Audit.** For an approved expansion, commission coverage of every in-scope declaration under the worker contract.
   On completion load `scout-completion`; return missing evidence to the scout before presenting a recommendation.
   Done when scope and ledger reconcile, every C/D has caught-mutation proof, and all limits and likely product bugs are explicit.
5. **Review.** Firstmate runs `lavish-axi`, consulting current help, design-source rules and the explanation, comparison, table and input playbooks.
   Show yield, ranked owner batches, keeper contracts, mutations, risks, baseline failures and production versus test/support LOC separately.
   Verify the rendered surface with `chrome-devtools-axi`; collect Ship / Defer / Drop per concrete batch using Lavish's completion-aware feedback loop.
   Load `captain-hold-lifecycle` before closing the review or investigation; record answers and carry every unresolved choice through that owner.
   Done when each batch has a recorded disposition or a durable unresolved choice and that owner's completion check passes.
6. **Prune.** Treat a Ship choice as authority only for its named batch and spec, not merge approval.
   Apply `scout-completion` for promotion and `AGENTS.md` section 7 for the project's delivery mode and merge posture.
   Commission coherent production-owner batches with the ledger, keeper mapping and mutation receipts as acceptance evidence; do not chase deletion counts.
   Recheck current owners and history after branch changes; invalidate stale recommendations rather than blindly applying them.
   Workers run focused owner/sibling proof and repository-equivalent changed, lint, dead-support and CI-routing checks; the selected delivery path owns broader validation and review.
   Done when authorized batches reach that path's completion criterion and the report separates production, test and support LOC, retained contracts, removed seams, actual cost and follow-ups.

## Scout worker contract

Copy this contract into the generated task section with concrete project, commit, scope, sample bounds and report destination.
Attach the audit reference as required reading; the scaffold and brief preamble remain the owners of authoring and lifecycle rules.

- **Inventory.** Read every assigned test in full, including parameter rows, and its production owner, entry points, callers/callees, siblings, CI routing and history.
  Inspect dependency source/types for dependency-backed claims.
  Record search coverage, missing sources and the project's focused validation commands.
  Keep out-of-sample paths explicit; declaration names alone do not count as reading.
- **Baseline.** Run the focused owner tests at the pinned commit; treat baseline failures as likely product bugs, not deletion candidates.
  Record command, inputs, output and limits; leave full-suite execution to the project's authorized validation path.
- **Ledger.** Give every declaration an R / F / C / D mark using the reference's evidence schema.
  A parameterized declaration is one entry unless rows need different marks; then account for each row.
  Judge assertions rather than names; unresolved deletion evidence means R with uncertainty, not a recommendation.
- **Mutation.** Discovery is read-only except for this bounded experiment: in the scout's isolated disposable copy, temporarily mutate the production owner to introduce the named regression and run the remaining keeper without the candidate's assertions.
  First record the keeper passing on clean source; then require it to turn red for the intended regression, not a syntax/import/setup failure.
  For C, a proposed keeper that does not exist yet is insufficient: defer the recommendation until an authorized worker constructs and proves it.
  Record the exact patch, keeper command and before/red/restored outputs plus before/after source hashes.
  Restore source byte for byte even on failure, verify the keeper passes again and confirm no experiment edits remain.
  Every C/D needs one caught production mutation before recommendation; if no meaningful mutation or keeper can be demonstrated, retain the test and report the missing proof, even when it looks like junk or has no apparent contract.
  Leave tracked tests, commits, PRs, shared services and external state untouched; use an untracked isolated runner if excluding the candidate requires one.
- **Layer plan.** Re-read the ledger by production boundary to name the keeper per contract, assertions to carry, retired files and test-only production seams unlocked.
  Trace non-test consumers before calling a seam obsolete; respect documented isolation, clock and port conventions rather than purging them mechanically.
- **Report.** Deliver a per-declaration ledger and ranked coherent batches with stable ids, citations and linked mutation outputs.
  Include retained false positives, likely product defects, baseline failures, measured versus estimated costs, separate production/test/support LOC and scope limits.
  Mark claims ran / cited / inferred / guess with their command, source or premise.
  Done when inventory totals match the ledger, every recommendation meets the evidence bar and the report returns to Firstmate for captain selection without project changes.
