---
name: hillclimb
description: >-
  Load before scoping, briefing, or executing sustained improvement of one measurable metric toward a target, such as search latency, retrieval quality on a frozen evaluation set, or a model sweep score.
  Agent-only workflow for repeated experiments with a frozen harness, fixed stop rule, and decision log.
user-invocable: false
metadata:
  internal: true
---

# hillclimb

A hillclimb is a bounded campaign that moves one measured number toward a target through a series of tested changes.
The number decides: every candidate change is measured on a frozen harness rather than argued from the diff.
These rules adapt the ideas in the Poteto hillclimb playbook at <https://github.com/cursor/plugins/blob/main/pstack/skills/poteto-mode/playbooks/hillclimb.md>; the wording and the Firstmate-specific sections here are our own.

## When a hillclimb fits

Use it when one number names the goal and a target can be set for it: p95 search latency, retrieval quality on a frozen query set, a model sweep score, or tokens per answer.
The complaint should recur across a workload, so no single upstream defect would settle it.

Two shapes do not belong here.
A one-off defect with a known cause is an ordinary bug fix, and wrapping it in a campaign only adds ceremony.
A design that keeps leaking review findings is structural, so it needs a design pass or a grill; a hillclimb would chase its symptoms one at a time.

## Set-up before the first change

1. Reproduce the complaint on a concrete case that shows the bad number.
   When no case reproduces it, repair the reproduction first, because a campaign on a case that cannot fail measures nothing.
   This step is done once that case fails on demand.
2. Define one campaign score and its better direction in the brief.
   For a harness with multiple workloads, designate one workload as the score source or fix an aggregation at setup.
   Use that same scalar for acceptance, the decision log, the stop rule, and the final report.
3. Fix the stop rule in the brief before the first attempt.
   Set a target value and a minimum number of attempts with valid before and after measurements.
   Use any values the captain supplied and set the remaining values during setup.
   For example, require latency at least 40 percent below baseline and at least 10 measured attempts.

## Freeze the harness first

Build the measurement before touching the product.
Prove the harness separates a bad case from a good one: run it on the case that reproduces the complaint and on a known-good case, and confirm the numbers differ in the expected direction.
When both read alike, revise the workload or the metric rather than trusting the harness.
Freeze the workload and one repeatable command that prints the metric as the median of N runs and the error and completed-work counts for each run.
Define the expected completed-work count, allowed error count, and noise threshold before testing candidates.
A measurement is valid only if every run completes the expected work and stays within the error limit.
Record the baseline tree, its valid campaign score, and a passing regression gate before changing the product.

For InfoConnect search work, the harness must cover the small corpus and the full corpus in the same frozen command.
The issue 1026 typo spike is the standing warning: it looked clean on the full evaluation bank while rewriting 9 of 103 correct queries on a 15-document subset.
Print both corpus measurements and the campaign score.
Check validity and the regression gate separately for each corpus, and reject a candidate if its per-corpus metric worsens past the noise threshold on either corpus.

## The attempt loop

Each iteration tests a single hypothesis, and the hypothesis names a specific mechanism plus the reason that mechanism should move the metric.
"Try memoizing something" is not a hypothesis; "cache the parsed query so the rewrite step stops re-parsing per request" is.

Measure each attempt in this order.

1. Read the campaign log and measure the starting commit with the frozen harness.
2. Apply and commit the single change on its own local experiment branch.
3. Re-run the frozen harness and the regression gate on that candidate.

An attempt-only scout hands off the results through its report.
The delivery worker applies the following steps to its own attempts and to scout candidates.

1. At acceptance, use the current accepted tip of the delivery branch as the comparison point.
   If the tip differs from the starting commit, replay only the candidate on a new local experiment branch based on the current tip, keep the original branch, and run the frozen harness and gate on both the current tip and the combined result.
2. Keep the candidate only when both measurements are valid, the campaign score improves past noise, and the regression gate passes, including the corpus checks when applicable.
   Reject every other candidate and record why.
3. Return to the delivery branch and advance it only to an accepted, tested commit, with one commit per kept change.

Isolated attempts can run in parallel.
Serialize acceptance and branch advancement so each candidate is checked against the result of the preceding decision.
Use measured results to decide every attempt.
Record the accepted tree with its score and gate result.

### Preserve every attempt

Preserve each attempt on a distinct local experiment branch, for example `hc/<campaign-id>/<attempt-id>`.
Leave rejected commits reachable there and off the delivery branch.
When a change already on the delivery branch must be undone, use a forward revert commit.
Firstmate's hard rules forbid discarding unlanded work, so never reset, never drop a stash, and never force-push attempted work away.

## Keep the decision log

Before briefing workers, Firstmate initializes one `decision.tsv` in the campaign task's private `data/<task-id>/` directory in the Firstmate home.
The tab-separated columns are `id`, `hypothesis`, `change`, `before`, `after`, `delta`, `gate`, `verdict`, and `note`.
After each attempt, the worker reports the attempt ID, hypothesis, change, measurements, gate result, experiment ref and commit SHA, and any measurement failure to Firstmate.
Firstmate records one row per attempt ID from the delivery worker's acceptance decision, using the campaign score for `before`, `after`, and `delta`, including for rejected attempts with valid measurements.
Use `kept` for an accepted change, `rejected` for an attempt left off the delivery branch, and `reverted` when a forward revert undoes the change.
On a forward revert, update that attempt's verdict and record the revert commit in its note.

## Plateau and stop

After a run of rejects, test a different mechanism or test a combination of near-misses as one new hypothesis under the same acceptance rule.
Stop when the current delivery tree has a valid score that reaches the fixed target, its regression gate passes, and the log shows the fixed minimum number of measured attempts.
If only marginal ideas remain before the stop rule is met, report the plateau through the normal status path with the log, the mechanisms already tried, and the ideas still open.

## Running a hillclimb in Firstmate

Firstmate loads this skill before scoping and assigns each attempt a unique campaign-wide ID before briefing the worker.
Dispatch parallel hypotheses to separate workers in separate isolated worktrees using the normal dispatch profiles and their model selection.
Firstmate briefs the worker responsible for ordered acceptance as a ship task and workers assigned only to run attempts as scouts.
Attempt-only scouts return to their starting checkout and use the scout report and completion status from their brief.
The delivery worker returns to the normal delivery branch after each attempt, including rejects.
Before cleanup of any campaign worktree, Firstmate preserves its experiment refs in a complete local Git bundle in the private campaign directory and verifies that the bundle contains the reported refs and commit SHAs.
The delivery worker uses the preserved scout refs for ordered acceptance.
Whenever the delivery tree differs from the last measured tree, the delivery worker reruns the frozen harness and regression gate on the new tree and records its identity and results.
Apply this after a forward revert, a rebase, a review fix, or a merge that changes the tree.
Ship accepted work through the project's normal delivery mode and review pipeline, with current evidence for the tree at handoff.
Use the resulting evidence to recheck the fixed stop rule before claiming the target was met.
If the changed tree fails validation, report the failure through the normal delivery path.
If the tree passes validation but misses the target, continue the campaign while worthwhile hypotheses remain or report a plateau.
If the campaign ends with no accepted changes, use the normal failure status to report that there is no change to ship and include the measured outcome.

Include the following in the delivery worker's final report.

- Metric and target
- Baseline, final score for the verified delivery tree, and percent delta
- Kept and reverted counts, using the campaign log verdicts
- One line per kept change
- Resolved campaign `decision.tsv` path
- Next idea

## Brief section

Firstmate fills the common lines and the line for the worker's role, then pastes them into the task brief.
Resolve the skill and campaign log paths from the worker's environment so both can be read from the isolated worktree.

```markdown
## Hillclimb
- Load the skill from `<absolute hillclimb SKILL.md path>`.
- Improve `<metric and its scored workload or fixed aggregation>` in the `<lower|higher>` direction.
- Stop at `<target>` after at least `<minimum attempts>` measured attempts.
- Run `<frozen harness command>` for the median of `<run count>` runs, using `<expected completed-work count, allowed error count, and noise threshold for each workload>`.
- Run the regression gate with `<gate command>`.
- Read `<absolute campaign decision.tsv path>` before each attempt and report results to Firstmate, who writes the log.
- Use assigned attempt ID `<attempt ID>` on a distinct local experiment branch.
- This brief permits local experiment branches as an exception to any delivery-branch-only rule.
- For an attempt-only scout, return to the starting checkout and use the scaffold's report-based completion with the experiment ref and commit SHA in the report.
- For the delivery worker, return to `<normal delivery branch>` before handoff and follow the skill's delivery-tree verification.
```
