# Typed dispatch resolution verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-dispatch-resolve.sh` contract owned by [`../configuration.md`](../configuration.md) ("Typed dispatch resolution") and the declared rule and profile fields owned there under "Crew dispatch profiles".
It records only facts that must be re-established when the typesafe.ai model, its API, or firstmate's dispatch rules change.
Task chronology, the captain's rules, and the briefs themselves stay in private reports.

## The API the tool depends on

Verified upstream 2026-09-16 against `https://api.typesafe.ai` for upstream PR [#4692](https://github.com/kunchenguid/firstmate/pull/4692). The observations below are upstream evidence only; fork-local live behavior has not been re-established.
`GET /v1/models` listed `jev-latest` and `jev-preview`, both released 2026-09-10; a `jev-latest` request answered as `jev-1.13.0`.
`POST /v1/systemone` takes `{model, state, questions}`; a `choice` question returns `{choice, probabilities, confidence}` with the probabilities summing to 1.
Observed error shapes: 401 `authentication_error` for a bad key, 403 when the header is missing, 422 with a `detail[].loc` naming the offending field, 400 `api_usage_error` for an unknown model, 405 on GET.
No rate-limit headers were present on any response; every response carried `x-typesafe-request-id`.

## Live rule match against real briefs

Upstream ran two live verification passes on 2026-09-16 and 2026-09-17 with a key injected for one command at a time, model `jev-latest`, confidence floor 0.6, timeout 5 s, and one `quota-axi --json` snapshot per run.
Rules: the captain's five-rule file with a none option, one `approval: captain` rule, two rule floors on `model:fable`, and declared `provider` on the Pi profiles.
Briefs: 15 real briefs plus 10 synthetic ones written to hit each rule.

| Measure | Run 1 | Run 2 |
| --- | --- | --- |
| Rule matched the hand label | 20 of 25 | 20 of 25 |
| Resolved to the hand-labeled profile | 20 of 25 | 18 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 18 / 1 / 6 / 0 | 17 / 2 / 6 / 0 |
| API errors | 0 | 0 |

A lean request that asks only the rule Choice matched the full request on all 25 briefs, which is why the shipped tool asks one question and keeps every gate in code.
No fork-local live run is claimed here. Rerun a live table by pointing the tool at a brief with the key injected for that one command.

## Offline behavior

`tests/fm-dispatch-resolve.test.sh` drives the public interface with a fake `curl` that records argv, the request body, the header read from file descriptor 3, and whether the secret reached its environment, plus a fake `quota-axi` that performs the same environment check.
It proves the absent key (environment and `.env`) prints one stderr line, nothing on stdout, exits 0, and never invokes `curl` or `quota-axi`.
It proves the key is absent from child environments, never appears on `curl` argv, and arrives only as the bearer header on the descriptor.
It proves the request uses the fixed endpoint and model, carries only the project, brief, and rule Choice with one option per rule plus the fixed neutral none option, and never carries `why`, `use`, or quota.
It proves clear, fixed-floor ambiguous, escalate (approval, unverifiable rule floor, tie, nothing rankable), known rule-floor fall-through, profile-floor evidence and vetoes, explicit-provider and provider-ID enforcement for this fork's multi-provider harnesses, default fallthrough, quota-axi failure, API and transport failure, malformed responses, and malformed configuration behave as the contract states, with configuration errors exiting 2 before any network call.

```console
$ bash tests/fm-dispatch-resolve.test.sh | tail -1
# all fm-dispatch-resolve tests passed
```

A live run needs a key and is not part of the suite.
