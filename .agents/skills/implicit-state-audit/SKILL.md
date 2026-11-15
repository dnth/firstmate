---
name: implicit-state-audit
description: >-
  Audit a project module's implicit state machines with a Fable-only read-only scout,
  then review concrete fixes visually.
user-invocable: true
disable-model-invocation: true
metadata:
  internal: true
---

# Implicit state audit

Invoke `/implicit-state-audit` with a project and module scope; this procedure runs only at the captain's request.

## Firstmate procedure

1. **Scope.** Resolve the project and owning home through `AGENTS.md` section 7; consult existing reports before commissioning another audit.
   Fill project, module paths, audited ref (default current `origin/main`) and optional focus from the request and repository; ask only for unresolved scope.
   Done when the inputs identify one project, bounded paths and a ref, with prior evidence accounted for.
2. **Commission.** File the scout work item and use `bin/fm-brief.sh --scout` per its `--help`; paste the template below into the scaffold's `# Task` section and replace every placeholder.
   Preserve the scaffold's isolation, status and report-delivery contract.
   Load `harness-adapters` and apply `AGENTS.md` section 4's dispatch resolution to the written brief in the same turn.
   **Fable only:** invoking this skill is the captain's approval for Fable on this audit, an explicit per-task captain override of dispatch routing.
   Select an available Fable profile using the configured profiles and the selected harness's authoritative model catalog; record the override reason in the task note and brief.
   Pass that profile's concrete axes to `bin/fm-spawn.sh --scout` using its current `--help`, even if dispatch resolution recommends a different family.
   If no Fable profile is available, stop and report the missing requirement to the captain; never fall back to another model family.
   Done when the scout is processing the completed brief on the verified Fable profile, or the missing-profile blocker has been reported.
3. **Read.** On completion load `scout-completion` and read the whole report against the template's completion criterion.
   Return missing evidence or misclassified findings to the scout before presenting them as audit conclusions.
   Done when every kept finding meets that criterion and the report records scope, commit and limits.
4. **Review.** Firstmate runs the `lavish-axi` review, not the scout.
   Consult current help and the matching explanation, comparison, diagram, table and input playbooks before authoring the review surface; follow its design-source rules.
   Lead with the ranked table, then large before/after pairs and short finding cards; preserve the report's classes, severity, legend and evidence links.
   Translate Mermaid graphs faithfully to inline SVG for the review unless the captain requests an editable whiteboard, in which case use Lavish's Mermaid path.
   Verify the rendered surface through `chrome-devtools-axi`, then use Lavish's completion-aware feedback loop to collect Ship now / Next / Later / Drop per machine.
   Load `captain-hold-lifecycle` before treating the investigation or review as complete; use that owner to record actual answers and carry every unresolved choice in the owning backlog.
   Done when every machine has a recorded choice or is included in that owner's unresolved-choice inventory, and its completion check passes.
5. **Route.** Treat Ship now as implementation authority only when the captain's answer authorizes the concrete fix spec.
   Apply `scout-completion` for promotion through `bin/fm-promote.sh --help` and `AGENTS.md` section 7 for delivery posture; an audit approval is not merge authority.
   For multiple independent selected fixes, promote the existing scout for one and file bounded ship tasks for the others, each linked to its machine and fix spec.
   Record Next as queued work, Later through the decision owner's deferral path, and Drop with the captain's reason if given.
   Done when every answer has its durable disposition and every authorized ship has its selected spec and delivery posture.

## Scout task template

Paste the following into the generated brief's `# Task` section.
The surrounding scaffold owns launch and completion mechanics.

```markdown
Audit **implicit state machines** in {PROJECT}: lifecycle or mode logic encoded by scattered booleans, nullable fields, status strings, cache keys, flag combinations or ordering assumptions rather than named states and allowed transitions.
Keep only machines where making the state explicit removes a concrete bug class, impossible state, race, conflicting reader behaviour or dead code, or enables a test of a concrete invariant.

Inputs:
- Project: {PROJECT}
- Module paths: {MODULE_PATHS} (example: src/search/ and src/jobs/)
- Audited ref: {AUDITED_REF}; default current origin/main
- Optional focus: {FOCUS_OR_NONE}
- Report: {REPORT_PATH_FROM_SCAFFOLD}

Read-only: no source or test edits, branches, commits, PRs, servers or mutations of external services.
Write only the assigned report and scaffold-required operational records.
Use existing tests or in-memory probes for reproduction; record commands, inputs and observed outputs.

### 1. Map

Resolve the audited ref to its full commit SHA and verify the inspected source and any executed code match it.
If they differ, report the mismatch to Firstmate rather than silently auditing a different commit.
Trace writers, readers, transition guards and callers across the bounded module's interfaces.
Delegate broad searching to native read-only scout subagents; retain judgment and report authorship.
Done when the report names the SHA, inspected paths, state carriers and search coverage, including unavailable evidence sources.

### 2. Triage

Aim for the strongest 4-8 candidates, ranked by value / effort; report fewer when fewer meet the evidence bar.
Drop candidates whose only gain is cleaner code.
For every kept finding:

- **Class.** Live bug requires a failing existing test or a command you ran on the audited commit that reproduces the actual bad transition and user-visible effect.
  Record the preconditions and entry path; an isolated helper result or fabricated state alone does not prove reachability.
  Latent bug class is unreachable today: cite the current guard or caller invariant and the plausible next change and code path that would break it.
  Never describe a latent class as reachable today.
  Put suspected current bugs without reproduction, or uncertain current reachability, in the dropped/inconclusive table with the missing proof; do not relabel them latent.
- **Severity.** Rate Critical / High / Medium / Low from worst user impact multiplied by likelihood; state both and justify the rating.
  Distinguish data exposure, deleted data resurfacing, wrong answers and wrong status; for latent classes assess likelihood conditional on the named next change and say so.
  Keep prevention value separate from claims about current incidents.
- **Tracker.** Search the project's issue tracker and git history for this machine, symptom and prior fixes; use `gh-axi` first for GitHub, consulting current help.
  Link related incidents, duplicate issues and relevant commits, explaining whether the finding is already fixed on the audited SHA.
  If neither search finds a match, write "none found" and the searches used; if a source is unavailable, name the limit rather than claiming no matches.
- **Fix spec.** State the proposed change, observable acceptance criteria and proving test with expected before/after verdicts.
  A live bug needs a regression test that fails on the audited commit for the reproduced reason; name the ran reproduction and the proposed test if they differ.
  A latent class needs a compile/type rejection or transition-table test proving the forbidden combination or edge is excluded.
  Include size S/M/L, change risk and root fix vs band-aid, with rationale.

Done when every kept finding has a supported class, severity, tracker/history search, code citations and ready-to-build fix spec; every other investigated candidate has a drop reason or missing-proof entry.

### 3. Present

Write fewer words, big visuals:

- Open with a one-screen table sorted by value / effort: rank, machine, class, severity, concrete gain, size, risk, root fix vs band-aid and evidence link.
- Give each machine a stable id and a standalone section: before/after Mermaid `stateDiagram-v2` pair first, at most about 10 states each, then at most 5 short bullets covering the triage fields.
  Put detailed command outputs and searches in a linked evidence appendix.
- Use a colour legend: red = illegal reachable, amber = ambiguous, grey dashed = dead, green = proposed.
  Add text labels so colour is not the only signal.
  Before shows current reachability; mark a latent counterfactual as hypothetical in a note, not as an existing reachable red edge.
- Tag claims ran / cited / inferred / guess: ran names the command and output; cited names file:line ranges or a linked artifact; inferred names its premises; guess names the uncertainty.
- End with the dropped/inconclusive candidates table and limits.

Done when every retained machine has both diagrams and its complete fix spec, the ranked table agrees with the finding sections, and all evidence links and diagrams have been checked.
Return the report to Firstmate for the captain's visual review; implementation choices belong there.
```
