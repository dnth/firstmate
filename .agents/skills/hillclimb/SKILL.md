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
2. Name the metric, and state which direction is an improvement on it.
   Fix the campaign to that single number rather than a bundle, so a result can be attributed.
   Write both into the brief, so no later attempt redefines them.
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
Record a valid baseline and a passing run of the regression gate before changing the product.

For InfoConnect search work, the harness must cover the small corpus and the full corpus in the same frozen command.
The issue 1026 typo spike is the standing warning: it looked clean on the full evaluation bank while rewriting 9 of 103 correct queries on a 15-document subset.
Check measurement validity and the regression gate separately for each corpus, and reject a candidate if the metric worsens past the noise threshold on either corpus.

## The attempt loop

Each iteration tests a single hypothesis, and the hypothesis names a specific mechanism plus the reason that mechanism should move the metric.
"Try memoizing something" is not a hypothesis; "cache the parsed query so the rewrite step stops re-parsing per request" is.

For each attempt:

1. Read the campaign log and measure the starting commit with the frozen harness.
2. Apply and commit the single change on its own local experiment branch.
3. Re-run the frozen harness and the regression gate on that candidate.
4. At acceptance, use the current accepted tip of the delivery branch as the comparison point.
   If the tip differs from the starting commit, replay only the candidate on a new local experiment branch based on the current tip, keep the original branch, and run the frozen harness and gate on both the current tip and the combined result.
5. Keep the candidate only when both measurements are valid, the metric improves past noise, and the regression gate passes, including the corpus checks when applicable.
   Reject every other candidate and record why.
6. Return to the delivery branch and advance it only to an accepted, tested commit, with one commit per kept change.

Isolated attempts can run in parallel.
Serialize acceptance and branch advancement so each candidate is checked against the result of the preceding decision.
Use measured results to decide every attempt.

### Preserve every attempt

Preserve each attempt on a distinct local experiment branch, for example `hc/<campaign-id>/<attempt-id>`.
Leave rejected commits reachable there and off the delivery branch.
When a change already on the delivery branch must be undone, use a forward revert commit.
Firstmate's hard rules forbid discarding unlanded work, so never reset, never drop a stash, and never force-push attempted work away.

## Keep the decision log

Before briefing workers, Firstmate initializes one `decision.tsv` in the campaign task's private `data/<task-id>/` directory in the Firstmate home.
The tab-separated columns are `id`, `hypothesis`, `change`, `before`, `after`, `delta`, `gate`, `verdict`, and `note`.
After each attempt, the worker reports those fields to Firstmate, including the experiment commit and any measurement failure.
Firstmate records one row per attempt ID using the evidence from the acceptance decision, including the measurements for rejected attempts.
Use `kept` for an accepted change, `rejected` for an attempt left off the delivery branch, and `reverted` when a forward revert undoes the change.
On a forward revert, update that attempt's verdict and record the revert commit in its note.

## Plateau and stop

After a run of rejects, test a different mechanism or test a combination of near-misses as one new hypothesis under the same acceptance rule.
Stop when the accepted metric reaches the fixed target and the log shows the fixed minimum number of measured attempts.
If only marginal ideas remain before both conditions hold, report the plateau through the normal status path with the log, the mechanisms already tried, and the ideas still open.

## Running a hillclimb in Firstmate

Firstmate loads this skill before scoping and assigns each attempt a unique campaign-wide ID before briefing the worker.
Dispatch parallel hypotheses to separate workers in separate isolated worktrees using the normal dispatch profiles and their model selection.
Firstmate designates a delivery worker to apply the ordered acceptance step and makes the preserved candidate commits available to that worker.
Workers return to their normal delivery branch before handing back an attempt, including when every attempt was rejected.
Send experiment results to Firstmate without claiming delivery of the experiment branch.
The delivery worker ships accepted work through the project's normal delivery mode and review pipeline.

Include the following in the worker's final report.

- Metric and target
- Baseline, final value, and percent delta
- Kept and reverted counts, using the campaign log verdicts
- One line per kept change
- Resolved campaign `decision.tsv` path
- Next idea

## Brief section

Firstmate fills every placeholder and pastes this block into the task brief.
Resolve the skill and campaign log paths from the worker's environment so both can be read from the isolated worktree.

```markdown
## Hillclimb
- Load the skill from `<absolute hillclimb SKILL.md path>`.
- Improve `<metric>` in the `<lower|higher>` direction.
- Stop at `<target>` after at least `<minimum attempts>` measured attempts.
- Run `<frozen harness command>` for the median of `<run count>` runs, using `<expected completed-work count, allowed error count, and noise threshold for each workload>`.
- Run the regression gate with `<gate command>`.
- Read `<absolute campaign decision.tsv path>` before each attempt and report results to Firstmate, who writes the log.
- Use assigned attempt ID `<attempt ID>` on a distinct local experiment branch.
- This brief permits local experiment branches as an exception to any delivery-branch-only rule.
- Return to `<normal delivery branch>` before handoff and use that branch for normal delivery.
```
