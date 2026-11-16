# Audit reference

Read this for every sample, audit lane and pruning batch under [Test audit](../SKILL.md).
The brief preamble owns test authoring rules; use the four questions below as ledger evidence, not a second authoring policy.

## Four-question gate

1. What observable behavior, invariant or independent contract does this protect?
2. What credible regression would make it fail?
3. Why does existing proof miss that regression?
   Identify one primary owner at the strongest boundary; another layer earns its place through a distinct transport or lifecycle risk.
   Identify existing tables or fixtures that could absorb repeated setup without losing cases.
4. Does the proof require an export, flag, wrapper or injection hook with no production caller?
   Identify the real boundary that could own the proof and any documented isolation convention the seam serves.

## Junk patterns

These are investigation leads, not deletion verdicts; apply the retention bar and the skill's mutation requirement.

- Assertion-free probes, self-comparisons, identity copiers and subject-generated expected values.
- Copied inventories, manifests or export lists; exact source, import or wording greps.
- Private predicate or call-shape assertions duplicating boundary proof; provider-local replays of a shared helper.
- Test-only exports, globals, wrappers and production paths with only test callers.
- Mocks implementing the asserted behavior or pretending distinct APIs are equivalent.
- Fixtures fabricating receipts, admission or callback ordering that the owner must produce; persistence assertions against a store the path never writes.
- Capability flags standing in for promised delivery or acknowledgement.
- Negative controls passing at an unrelated guard or an unreachable rejection.
- Names promising behavior the inputs and assertions never exercise.

## Retention bar

Keep independent API, SDK, protocol, configuration, migration, storage, security, platform, meaningful default, prompt-byte, generated-language, package, release, architecture and observable-ordering contracts with credible regressions.
Static or slow does not mean disposable.
A copied-looking value or thin forwarding assertion may be the only proof of a public contract; retain it until a keeper is proven.
Exercise executable parsers, schemas and public interfaces rather than replacing source greps with new implementation-text checks; follow the project's stricter rules.
Treat baseline failures as likely production defects: reproduce and report the owning behavior, preserving human-authoritative tests and golden sets.

## Per-declaration evidence

| Field | Required evidence |
| --- | --- |
| Identity | Stable id, exact declaration and file:line; parameter rows when marks differ |
| Mark | R retain; F fix assertion while retaining contract; C consolidate into a named keeper; D delete |
| Contract and bug | Observable contract and the specific detectable regression; explain a vacuous assertion for F |
| Consumers | Non-test callers of the production/support seam, search scope and missing evidence |
| Remaining proof | Stronger keeper by declaration and boundary, or reason no independent contract appears to exist; the latter does not waive mutation proof |
| History | Why it exists, relevant commits/incidents, searches returning no match, unavailable history |
| Change | Assertions carried first, retired layer/file and production seams or dead support unlocked |
| Risk | Lost-proof risk, distinct layer risk, uncertainty and human-authoritative constraints |
| Validation | Repository-equivalent focused owner/sibling commands, expected result and measured cost |
| Mutation receipt | For C/D, link the complete experiment required by the skill's Mutation contract |

R includes a test moved intact to a better-named owner file, with the move recorded.
F repairs an assertion, not the contract to fit current broken behavior.
C names the keeper and every carried case before the redundant proof can retire.
D names what remains; missing callers, history, keeper or mutation evidence blocks the recommendation.

## Validation and handoff

Discover commands from the project's scripts, CI and scoped instructions rather than importing another repository's runner or numeric line/time budgets.
Use measured runtime and the project's existing fast, integration and release tiers to discuss cost.
After authorized edits, run focused keeper/sibling proof and the project's changed checks, formatting, dead-dependency, unused-file and unused-export equivalents where available.
Account for orphaned helpers and CI inventory/routing after moves; record unavailable checks as limits.
Exercise the owning executable or dry-run when retiring source-text checks.
Report the root causes, retained contracts and false positives, removed seams, proof and cost, separate production/test/support LOC, delivery state and follow-ups.
Refresh owners and rediscover overlap before another batch; commit, push and land only through the authorized project lifecycle.
