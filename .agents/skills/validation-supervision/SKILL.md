---
name: validation-supervision
description: >-
  Agent-only procedure for supervising ship validation. Load on a ship worker's implementation-complete done:, whenever a ship starts or already has an active no-mistakes validation run, including a mid-run requirement change or finding, and before deciding or answering any ask-user finding.
user-invocable: false
metadata:
  internal: true
---

# Validation supervision

On a ship worker's implementation-complete `done:`, follow the evidence and validation lifecycle owned by `bin/fm-receipt-check.sh` before accepting completion, returning missing or invalid criteria to the same worker.
Follow its durably recorded path, keep uncertain classifications high, and keep `direct-PR` and `local-only` outside No-Mistakes.
For high-risk `no-mistakes` work, trigger full validation on the same worker using the harness invocation owned by `harness-adapters`.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated; however, the smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

Outside the ordinary-finding return path below, only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing any code.
The worker then follows `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
Custody recovery settles branch ownership, not content: the worker must replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
Apart from supersession or the ordinary-finding custody-return path, do not hand-edit, commit, restart, or start a second validation run while a run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

An ask-user finding returns as `needs-decision` under the canonical key owned by `bin/fm-nm-run-lib.sh`; firstmate loads `ask-user-authority` and either decides or escalates per that skill.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
PR-ready and completion apply the bound-run decision check owned by `bin/fm-nm-run-lib.sh`, with the process-evidence limitation owned by `bin/fm-classify-lib.sh`.
When that check refuses, decide each named finding per `ask-user-authority` and record the answer through `fm-send`, using the fallback append documented in `bin/fm-nm-run-lib.sh` when no open decision record remains.
Resume fleet supervision immediately after the decision lands.

For ordinary findings from any No-Mistakes tier, steer the original worker to return branch custody through the supported abort and sync sequence, fix the findings itself, and update receipts.
When a finding invalidates a receipt or acceptance claim, use the receipt checker owner to record it before returning branch custody.
After the original worker's fix, return high-risk work to full validation with the updated receipts and delta context.

When a validating run cannot bind because the plan postdates it or the base moved mid-run, replanning is never the fix: a same-content `--plan` refuses while a run is bound, and a new plan would only record the live run as predating it.
Rebind the run through the receipt checker's supported content-identity shape instead - `--bind-run` accepts a run whose reported head tree is byte-identical to the checked-out tree once the run is authoritative (a terminal passed run, or an active run with proven `fm_nm_run_branch_ownership` branch evidence), and `--bind-check` evaluates that same decision read-only before steering the worker.
The checked-out branch must first carry the run's own pushed head, so a diverged lane reconciles to the pipeline head before binding.

Judge validation by the currently attributed run step through `bin/fm-crew-state.sh`, not by shell liveness or the last status event.
Running, fixing, or CI states remain working; parked approval or fix-review states require the worker to follow the active gate help; passed or checks-passed is done; failed or cancelled is failed.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession or ordinary-finding custody-return sequences above; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.
