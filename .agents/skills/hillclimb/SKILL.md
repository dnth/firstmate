---
name: hillclimb
description: >-
  Agent-only workflow that turns one measurable metric into a repeatable experiment loop: a fixed stop rule, a frozen measurement harness, one hypothesis per attempt, a decision log, and an experiment branch for every attempt.
  Load before scoping, briefing, or executing a task whose goal is sustained improvement of one measurable metric toward a target, such as search latency, retrieval quality on a frozen evaluation set, or a model sweep score; one-off bug fixes and leaking designs do not belong here.
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
3. Write the stop rule as a checkable pair: a target value plus a minimum number of measured attempts.
   The rule is checkable when a reader can answer yes or no from the harness output and the attempt log.
   The pair prevents both a lucky early result from ending the campaign and an unlucky streak from running without bound.
   One example shape is "at least 40 percent below baseline, across at least 10 measured attempts".
   Use the captain's numbers when they exist; otherwise agree them with the captain before the first attempt.

## Freeze the harness first

Build the measurement before touching the product.
Prove the harness separates a bad case from a good one: run it on the case that reproduces the complaint and on a known-good case, and confirm the numbers differ in the expected direction.
When both read alike, revise the workload or the metric rather than trusting the harness.
Freeze the result as one repeatable command that prints three things: the metric as the median of N runs, its error count, and its work count.
The median clears run-to-run noise; the error count proves the measurement completed; the work count proves the case did the same amount of work before and after.
Record the baseline, plus one passing run of the gate, before changing anything.

For InfoConnect search work, the harness must cover the small corpus and the full corpus in the same frozen command.
The issue 1026 typo spike is the standing warning: it looked clean on the full evaluation bank while rewriting 9 of 103 correct queries on a 15-document subset.
A harness that watches only one corpus scale will pass a change that damages the other.

## The attempt loop

Each iteration tests a single hypothesis, and the hypothesis names a specific mechanism plus the reason that mechanism should move the metric.
"Try memoizing something" is not a hypothesis; "cache the parsed query so the rewrite step stops re-parsing per request" is.

For each attempt:

1. Record the current metric from the frozen harness.
2. Apply the single change on its own experiment branch.
3. Re-run the frozen harness and the regression gate.
4. Keep the change only when the metric clears noise and the gate passes; any other result is a reject.
5. Commit one kept change per commit, containing only that change, and land kept commits on the delivery branch in order.

Keep one change in flight at a time, because two unmeasured changes in the same result cannot be attributed to either.
An unmeasured change is unfinished, and a diff that reads well proves nothing.
Only the harness and the gate can call a win.

### Preserve every attempt

A reject is evidence, not garbage.
Commit each attempt on its own experiment branch named `hc/<id>/<n>`, so it stays preserved and off the delivery branch; a later idea can then read it, combine it, or retry it.
Keep the delivery branch for kept changes only.
When a rejected change already landed on the delivery branch, undo it with a forward revert commit.
Firstmate's hard rules forbid discarding unlanded work, so never reset, never drop a stash, and never force-push attempted work away.

## Keep the decision log

The campaign keeps a `decision.tsv` in the task's private `data/<id>/` directory in the Firstmate home, never in the project tree.
Its header is: id, hypothesis, change, before, after, delta, gate, verdict, note.
Use one tab-separated row per attempt, kept or rejected.
Read the log before each attempt, so the next hypothesis starts from what the log already proved or killed.
The log keeps numbers for rejects too, and a run of reject rows is the plateau signal.

## Plateau and stop

A run of rejects means the current category is exhausted, not that the hill is climbed.
Pivot to a different mechanism category, or combine near-misses whose effects may stack.
Behavior and simplicity come first: a gain that breaks behavior goes back, while a simpler implementation that keeps the number stays.
Stop at the stop rule, or when every remaining idea costs more than the next increment is worth.
The stop rule is fixed at set-up; tighten it only with a new captain decision, and never loosen it to declare victory.
When you are stuck, report it with evidence: the log, the categories already tried, and the ideas still open.
Surface that through the normal status path rather than spinning.

## Running a hillclimb in Firstmate

Firstmate loads this skill at intake to recognize the task shape, set up its brief, and choose the dispatch shape.
Each parallel hypothesis goes to its own worker in its own isolated worktree, so two attempts never share a checkout.
Dispatch uses the normal dispatch profiles and the model they select; this skill pins no model.
Workers measure inside their own worktree with the frozen harness and preserve their attempts on `hc/<id>/<n>` branches.
Kept work lands through the project's normal delivery mode and review pipeline, never through a side path around it.

The worker's final report carries:

- the metric and its target;
- the baseline and final values, with the percent delta;
- the count of kept and rejected attempts;
- one line per kept change;
- the `decision.tsv` path;
- the best idea for a further push.

## Brief section

Firstmate pastes this block into the task brief and fills every placeholder; the worker then has everything needed to start measuring.

```markdown
## Hillclimb
- Load the `hillclimb` skill and follow it for every attempt.
- Metric: `<name>`; better means `<lower|higher>`.
- Stop rule: target `<value>` and at least `<N>` measured attempts.
- Harness: `<frozen command>` (median of `<N>` runs; prints `errors=<n>` and `work=<n>`).
- Gate: `<regression command>` (green before any attempt is kept).
- Decision log: `data/<id>/decision.tsv`.
- Experiment branches: `hc/<id>/<n>`; the delivery branch carries kept commits only.
```
