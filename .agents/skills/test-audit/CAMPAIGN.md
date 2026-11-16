# Explicit subsystem campaign

Load only after the captain explicitly requests Campaign through [Test audit](SKILL.md).
Its sample-first yield decision, worker contract and [audit reference](references/audit.md) apply to every lane.
Firstmate commissions the stages below through the normal lifecycle; it never edits project tests itself.
Each stage ends on its completion criterion before dependent work begins.

## 1. Baseline

After sample approval, pin the subsystem's base commit and inventory test/support LOC separately from production LOC.
Account for every test file's baseline pass/fail state using focused runs and current authorized CI evidence at that commit; leave broad suite execution to the project's validation owner.
Keep baseline failures in a separate likely-product-defect list; missing execution evidence stays unknown, not passing.
Done when every in-scope file has a baseline result or an explicit evidence gap resolved before cutover.

## 2. Lanes

Partition along production-owner boundaries, including shared-core cases, QA scenarios and live-proof harnesses the subsystem owns.
Assign shared mutable harness/support work to one integration owner; independent lanes may proceed in parallel under the normal dispatch rules.
Done when every file and scenario has exactly one lane and shared ownership is explicit.

## 3. Lane ledgers

Commission a read-only scout per lane with the skill's worker contract, including its bounded mutation exception.
Read every test and parameter table plus owners, entry points, callers, history and CI routing.
Done when every declaration has R/F/C/D evidence and every C/D has the required caught mutation, with uncertain cases retained.

## 4. Layer plans

Commission a second read-only pass from each ledger to find the redundant layer rather than treating marks as an edit list.
Prefer real boundary proof with a controlled external dependency over mocked collaborator echoes.
Correct ledger mistakes and name the keeper per contract, assertions to carry, retired files and seams unlocked.
Done when every lane has a coherent owner plan with preserved contracts and explicit dependencies.

## 5. Cutover

Firstmate presents plans through the skill's visual review and commissions only captain-selected batches as ship work under the project's delivery mode and merge posture.
Workers edit lane by lane, carry assertions before retiring proof, and remove only seams shown obsolete under project conventions.
Update existing CI routing, inventories and line-cap mechanisms where applicable; record durable ownership knowledge through the project's established instructions workflow.
Done when selected plans are applied, focused keepers pass and no experiment edits remain.

## 6. Preservation

Use the selected delivery path's independent validation/review to compare retired coverage against keepers by boundary group; include this question in the ship instructions rather than adding a manual approval gate.
Check for lost sole proof, vacuous negatives and unreachable assertions.
For every restored contract, an authorized worker performs the skill's Mutation experiment and records a caught regression and byte-for-byte restoration.
Done when every reported gap is restored or rejected with source evidence and each restored contract has its caught-mutation receipt.

## 7. Product defects

A baseline failure surviving in a keeper is a likely product bug, not pruning authority.
Firstmate obtains bounded repair authority before commissioning any product fix outside the approved batch.
Keep an authorized repair in a separate commit at its production owner; prove the real user flow with a failing control reverting only that fix and a passing candidate on the same harness.
Record unrelated discrepancies as follow-ups, without expanding the campaign.
Done when every repaired defect has matching control/candidate evidence and all other defects have durable dispositions.

## 8. Reconcile

Follow the project's integration policy and selected delivery path rather than imposing a merge-versus-rebase rule.
When the base branch changes a retired file, port each new independent contract into its keeper and prove it before retaining the deletion.
Rerun focused proof for integration-touched paths and failed CI checks; repeat live proof when merged inputs change its contract, leaving broad regression to authorized CI.
Return baseline/final test and support LOC with production separate, lane/keeper mapping, preservation gaps and mutations, product control/candidate proof, costs and follow-ups.
Done when every new base-branch regression has an owner and evidence, the lane inventory reconciles and the normal delivery path reaches its completion criterion; campaign approval alone never grants merge authority.
