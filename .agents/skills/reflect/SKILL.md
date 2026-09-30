---
name: reflect
description: Inspect what actually happened in a meaningful run and decide what should change so Firstmate or its workers perform better next time. Use when the captain invokes /reflect (e.g. "/reflect", "reflect on that task", "what should we change about how we work"), or after a completed, difficult, failed, or unusually expensive run when the captain wants a postmortem or improvement review.
user-invocable: true
metadata:
  internal: true
---

# reflect

`/reflect` owns post-run system-improvement analysis: given a run's durable evidence, find the lessons worth encoding and propose where each belongs.
`/stow` remains the owner of durable knowledge retention and knowledge routing; this skill never files memory and never performs a knowledge sweep.
The two skills inspect some of the same evidence and compose in either order without duplicating each other.

## When to invoke

Invoke when the captain asks for it, and otherwise only after a completed, difficult, failed, or unusually expensive run whose evidence plausibly holds a lesson.
Reflection is not limited to failures: a run that worked unusually well can expose a pattern worth making repeatable.
Skip routine clean runs; a run with no friction and no surprise teaches nothing worth encoding.

## Evidence first

Ground every claim in the reflected run's durable records.
Never ingest a whole conversation history, and expand beyond the reflected task only when evidence already found requires it.

For a run identified by task `<id>`, start from:

- the backlog item via `bin/fm-tasks-axi.sh show <id> --full`;
- the generated brief `data/<id>/brief.md` and its acceptance criteria;
- the acceptance ledger `data/<id>/evidence.jsonl`;
- worker status events `state/<id>.status` and current or terminal state through `bin/fm-crew-state.sh`;
- the scout's `data/<id>/report.md` when the run was an investigation;
- validation and review findings, no-mistakes results, and the PR and commits when the run shipped;
- retry, replacement, and captain-intervention records attached to the task;
- project documentation the run touched.

Use the session transcript only to establish something durable state does not already record.

## What to look for

- Brief and contract problems: a worker misunderstood the task, the brief was underspecified, or acceptance criteria were weak, ambiguous, or missing a reproduction or verification step.
- Execution shape: the wrong shape was used, work was serialized unnecessarily, work was parallelized despite a real semantic dependency, parallelism multiplied a bad assumption, or a workflow consumed disproportionate tokens or supervision attention.
- Dispatch: the wrong worker, model, harness, effort, profile, or secondmate was selected.
- Mechanics versus judgment: an agent repeatedly performed deterministic mechanics a script should own, retries repeated for one underlying cause, context was repeatedly rediscovered, or recovery was unnecessarily difficult.
- Structural gaps: a missing invariant allowed an invalid state, a runtime refusal should have existed, a regression test was missing, or validation failed to exercise the real user-facing behavior.
- Instruction health: the same captain correction recurred, an instruction exists but agents repeatedly fail to follow it, or an instruction is stale, ambiguous, duplicated, or filed under the wrong owner.
- Escalation and ownership: Firstmate escalated something it could have resolved experimentally, a project-specific lesson landed in Firstmate instead of the project's knowledge, or machinery accumulated around a bad premise instead of fixing the root cause.
- Repeatable success: a workflow worth making repeatable.

## Diagnose before proposing change

Do not translate a symptom straight into another rule.
For each candidate lesson, answer:

1. What actually happened?
2. What evidence supports it?
3. Was this an isolated incident or part of a recurring pattern?
4. What was the underlying cause?
5. Does an authoritative owner already exist?
6. Was the owner missing, wrong, stale, or simply not followed?
7. Would changing prose actually prevent recurrence?
8. Could the behavior instead be enforced structurally?
9. Is this really a Firstmate problem, a project problem, an external tool problem, or transient noise?
10. Would fixing this add more machinery than the problem justifies?

## Classification

Assign each accepted finding exactly one class and one owner:

- `nothing` - transient noise, one-off circumstance, unsupported inference, or not material enough to encode.
- `learning` - a durable operational fact belonging to an existing knowledge owner; route through AGENTS.md section 6's routing table, never through a new store.
- `preference` - a captain preference or recurring working-style choice; route through the captain-preference owner and authority rules in section 6.
- `project-knowledge` - intrinsic to one project; it lives in that project's knowledge through a normal ship task, never globally in Firstmate.
- `instruction` - an existing instruction or internal skill needs clarification, simplification, movement, or consolidation; prefer editing the current authoritative owner over adding a second instruction.
- `brief` - the task contract should change: better acceptance criteria, task-shape guidance, stronger evidence requirements, a reproduction step, or a missing verification instruction.
- `dispatch` - model, harness, effort, profile, or secondmate routing was wrong; classify here only when evidence shows a real routing problem, never to tune dispatch from one subjective preference unless it reflects an explicit captain preference.
- `mechanic` - a deterministic repeated operation belongs in a script or an existing deterministic mechanism rather than in agent instructions.
- `invariant` - a state or safety property should be enforced structurally: fail closed, refuse an impossible transition, require a field, guard ownership, detect an invalid lifecycle state, or make retry behavior idempotent.
- `regression` - an executable test should prevent recurrence; prefer regression coverage over prose whenever the behavior is objectively testable.
- `workflow` - the execution shape should change: pilot before fan-out, reproduce before fix, baseline before optimization, split or serialize work differently, or use a scout before a ship when uncertainty is material.
- `backlog` - a real improvement that needs meaningful implementation work becomes a separate Firstmate task.

## Prefer structural enforcement

For every accepted finding, choose the strongest appropriate enforcement level:

```text
nothing -> knowledge -> instruction -> brief -> dispatch -> workflow -> script -> invariant -> regression test
```

Weak: "remember not to spawn before X."
Better: `fm-spawn` refuses when X is false.

Weak: "workers should remember to reproduce bugs."
Better: bug-fix briefs carry an explicit reproduction acceptance criterion.

Do not mechanize judgment that genuinely requires understanding.
Scripts own mechanics, agents own judgment.

## Avoid overfitting

A single occurrence earns an encoding only when it exposes a clear invariant, correctness issue, safety boundary, or obviously missing deterministic guard; otherwise look for recurrence in prior related evidence first.
Do not search unrelated projects or histories merely to manufacture recurrence.
Concluding "no structural change is justified" is a successful outcome.

## Rejected lessons

Reflection actively defends Firstmate against accumulating unnecessary policy and machinery.
Record plausible changes that were considered and deliberately rejected, with a one-line reason each: a worker failed once with no general problem, validation caught the issue as designed, a retry succeeded with no invariant violated, the proposed automation outweighs a rare event, an existing owner already covers the case, the issue was project-specific, the prose would duplicate an existing contract, or the root cause was an external outage.

## Authority boundary

`/reflect` analyzes and proposes; it never edits shared tracked material itself.
It must not modify `AGENTS.md`, `.agents/skills/**`, `skills/**`, `bin/**`, tests, dispatch configuration, task-lifecycle contracts, validation behavior, or tracked documentation because it happened to find an improvement.
Tracked improvements go through the normal Firstmate task lifecycle as proposed work, and ordinary private knowledge routes through section 6's owners only where the current authority model already allows the write.
Invoking `/reflect` widens no authority, and the captain's authority remains authoritative.

## Proposed follow-up

Each earned follow-up is filed as a backlog item through `bin/fm-tasks-axi.sh` for the normal lifecycle, never implemented by reflection and never stored in a reflection-specific record.
A proposal names the problem, the evidence, the authoritative owner, the desired behavioral change, the likely files or subsystem, acceptance criteria, the regression requirement, and why the change earned its complexity.
File only findings that earned implementation; never emit a speculative improvement list.

## Report contract

Return a concise captain-facing report.

### What happened

Identify the task or run reflected on and the important outcome without retelling the execution history.

### Lessons

For each accepted lesson, report:

```text
Observation:
Evidence:
Cause:
Classification:
Owner:
Proposed change:
Confidence:
```

Keep each finding concise; confidence reflects evidence quality, not model certainty.

### Rejected

List the plausible changes considered but deliberately not adopted, with a short reason for each.

### Proposed follow-up

List only the structural changes that earned implementation, as the backlog items filed above.
If none did, say exactly:

```text
No follow-up change is justified.
```
