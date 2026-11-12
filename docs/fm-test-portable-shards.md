# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current candidate timings came from the 2026-07-29 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.

| duration_ms | script |
|---:|---|
| 52939 | `tests/fm-x-mode.test.sh` |
| 48294 | `tests/fm-backend-herdr.test.sh` |
| 46788 | `tests/fm-arm-pretool-check.test.sh` |
| 34207 | `tests/fm-cd-pretool-check.test.sh` |
| 30771 | `tests/fm-captain-hold-lifecycle.test.sh` |
| 25365 | `tests/fm-crew-state.test.sh` |
| 15674 | `tests/fm-test-run.test.sh` |
| 15422 | `tests/fm-herdr-lab.test.sh` |
| 9065 | `tests/fm-composer-ghost.test.sh` |
| 8564 | `tests/fm-pr-merge.test.sh` |
| 6251 | `tests/fm-grok-harness.test.sh` |
| 5644 | `tests/fm-send-popup-settle.test.sh` |
| 5237 | `tests/fm-lint.test.sh` |
| 4816 | `tests/fm-tmux-submit-busy.test.sh` |
| 2945 | `tests/fm-pi-primary-types.test.sh` |
| 2911 | `tests/fm-send-settle.test.sh` |
| 2875 | `tests/fm-review-diff.test.sh` |
| 2747 | `tests/fm-send-strict.test.sh` |
| 2224 | `tests/fm-brief.test.sh` |
| 855 | `tests/fm-spawn-batch.test.sh` |
| 703 | `tests/fm-supervision-instructions.test.sh` |
| 581 | `tests/fm-ensure-agents-md.test.sh` |
| 248 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-composer-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 162436 ms (~162.4 s) |
| `portable-parallel-2` | 13 | 162754 ms (~162.8 s) |
| imbalance | | 318 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
The portable-serial test set is derived rather than enumerated, so a newly added test lands here by default.
The per-shard membership snapshot below records the generated assignment for the current timing hints.

## Portable serial CI shards

The current hints are the per-script maximum measured across the three most recent green CI runs: main [42768866128](https://github.com/dnth/firstmate/actions/runs/42768866128), main [42557971268](https://github.com/dnth/firstmate/actions/runs/42557971268), and PR [42756772678](https://github.com/dnth/firstmate/actions/runs/42756772678).
Runs 42768866128 and 42756772678 each completed all 178 current serial scripts, totaling 102m39.455s and 101m57.902s respectively.
Run 42557971268 completed 177 scripts totaling 102m06.361s; it omits `tests/fm-remote-herdr-launch.test.sh`, whose hint comes from the other two runs.
Taking each script's maximum puts the hint sum at 6,461,201 ms (107m41.201s), so the projected shard totals sit at or above every observed run.
`portable-serial-<k>of<n>` splits that remainder across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` builds each lane name from `strategy.job-total`, which equals the length of its `matrix.shard` list, so changing the shard count in either file without the other is refused loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.

### Why the cap needs eight shards

The 20-minute cap is a hang tripwire, not a budget.
The serial lane is wall-clock bound because every one of its scripts runs strictly serially in each shard, so a slow shard tracks its own aggregate work rather than one hanging test.
Seven shards cannot meet the 15-minute target any more: the 107m41.201s hint sum projects 15m23s per shard.
Eight shards project 13m27.438s-13m29.087s and hold that bound when replayed against any one source run.

Evidence from the superseded seven-shard layout: on main run [42768866128](https://github.com/dnth/firstmate/actions/runs/42768866128), shard 2 ran 06:55:23-07:14:43 UTC, 19m20s wall for 19m06s of scripts, one minute under the cap.
Its slowest script was `fm-watch-triage.test.sh` at 775,401 ms (12m55.401s) of that 19m06s, and the remaining scripts consumed the rest, so the overrun was aggregate growth rather than a hung test.
Job setup costs about 15s: that shard's run step started 8s after the job and the job completed 4s after the run step.
Earlier cancellations under six and seven shards had the same shape, with the 20-minute limit reached by different tests on different attempts ([38753521432](https://github.com/dnth/firstmate/actions/runs/38753521432) reached it in `fm-on`, `fm-watch-checkpoint`, and `fm-wake-drain-unread-status` across its three attempts).
Test assertions and the 20-minute cap are unchanged.

### Required test fix

`resolve_ios_pending` in [fm-remote-secondmate-lifecycle-e2e.test.sh](../tests/fm-remote-secondmate-lifecycle-e2e.test.sh) now selects the captured acknowledgement by the pending request's correlation ID.
The previous selection excluded the first three result files and picked the last sorted result filename, which did not reliably identify the reply for that request.
Handling an unrelated result could leave an inheritance acknowledgement unresolved before the merged-PR reply assertion.
[Run 38770719267](https://github.com/dnth/firstmate/actions/runs/38770719267) failed that assertion without the correlation-ID selection; [run 38785253557](https://github.com/dnth/firstmate/actions/runs/38785253557) passed with it.
The fix preserves the assertions and changes only which captured reply is handled.

### Rebalanced duration profile

The eight-shard LPT assignment spreads 1.649s across the eight bins under the refreshed hints.
The per-run columns below replay the same membership against each source run's own measurements.
Run 42557971268's shard-7 value and total are partial observed sums, excluding the missing `tests/fm-remote-herdr-launch.test.sh` measurement; the projections use measurements across all three runs and cover all 178 scripts.

| Shard | Scripts | Projected script sum | 42768866128 | 42557971268 | 42756772678 |
|---|---:|---:|---:|---:|---:|
| 1 of 8 | 1 | 13m29.087s | 12m38.664s | 13m29.087s | 11m30.367s |
| 2 of 8 | 13 | 13m27.452s | 13m22.846s | 13m24.085s | 12m50.182s |
| 3 of 8 | 26 | 13m27.438s | 12m30.552s | 12m29.994s | 12m53.481s |
| 4 of 8 | 27 | 13m27.443s | 13m04.737s | 11m58.559s | 13m18.846s |
| 5 of 8 | 27 | 13m27.441s | 12m13.634s | 12m36.273s | 12m35.718s |
| 6 of 8 | 28 | 13m27.443s | 12m53.088s | 12m23.964s | 13m01.901s |
| 7 of 8 | 29 | 13m27.452s | 12m51.760s | 12m41.121s (partial) | 12m57.059s |
| 8 of 8 | 27 | 13m27.445s | 13m04.174s | 13m03.278s | 12m50.348s |
| Total | 178 | 107m41.201s | 102m39.455s | 102m06.361s (177 scripts) | 101m57.902s |

The longest measured script is `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` at 809,087 ms (13m29.087s).
It sets shard 1 and is the single-script lower bound for any shard count, so finer splits cannot push the maximum below it.

The current shard memberships below are generated from the same hints.

### Current shard membership

#### `portable-serial-1of8` - 1 script

```text
tests/fm-remote-secondmate-lifecycle-e2e.test.sh
```

#### `portable-serial-2of8` - 13 scripts

```text
tests/fm-watch-triage.test.sh
tests/fm-ext-plugin-dest.test.sh
tests/fm-backend-zellij.test.sh
tests/fm-treehouse-sweep.test.sh
tests/fm-busy-state.test.sh
tests/fm-runpod-omp-auth.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-operational-input.test.sh
tests/fm-codex-continuity-live-e2e.test.sh
tests/fm-claude-stop-autoarm-live-e2e.test.sh
tests/fm-omp-primary-live-e2e.test.sh
tests/fm-omp-compact-adviser-live-e2e.test.sh
```

#### `portable-serial-3of8` - 26 scripts

```text
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-ext-ask.test.sh
tests/fm-boat-omp-auth.test.sh
tests/fm-procevent.test.sh
tests/fm-runpod-lifecycle.test.sh
tests/fm-secondmate-restart.test.sh
tests/fm-public-followup.test.sh
tests/fm-remote-secondmate-update-restart.test.sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-wake-drain-open-decisions-cursor.test.sh
tests/fm-ext-inbox-remove.test.sh
tests/fm-turnend-guard.test.sh
tests/fm-shared-captain-inheritance.test.sh
tests/fm-send-turn-start.test.sh
tests/fm-inbox.test.sh
tests/fm-herdr-session-cleanup.test.sh
tests/fm-omp-relaunch-guard.test.sh
tests/fm-merge-local.test.sh
tests/fm-afk-return.test.sh
tests/fm-supervision-events.test.sh
tests/fm-reflect-skill.test.sh
tests/fm-send-secondmate-marker-herdr-e2e.test.sh
tests/fm-stall-recovery.test.sh
tests/fm-omp-relaunch-tmux-live-e2e.test.sh
tests/fm-grok-continuity-live-e2e.test.sh
tests/fm-remote-omp-update-restart-live-e2e.test.sh
```

#### `portable-serial-4of8` - 27 scripts

```text
tests/fm-ext-decision.test.sh
tests/fm-ext-waiting-pin.test.sh
tests/fm-session-start.test.sh
tests/fm-bootstrap.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-send-inbox.test.sh
tests/fm-runpod-pod-boot.test.sh
tests/fm-dispatch-resolve.test.sh
tests/fm-spawn-pool-base-freshen.test.sh
tests/fm-task-delivery.test.sh
tests/fm-send-resolve-key.test.sh
tests/fm-wake-drain-open-decisions.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-idle-sleep.test.sh
tests/fm-tangle-guard.test.sh
tests/fm-receipt-check.test.sh
tests/fm-secondmate-lifecycle-e2e.test.sh
tests/fm-hermes-sandbox.test.sh
tests/fm-backend-cmux.test.sh
tests/fm-remote-secondmate-sleep-reconcile.test.sh
tests/fm-omp-update.test.sh
tests/fm-check-unregister.test.sh
tests/fm-treehouse-orphan-recovery.test.sh
tests/fm-pi-compatible-family.test.sh
tests/fm-backend-herdr-focus-flash-e2e.test.sh
tests/fm-omp-branch-live-e2e.test.sh
tests/fm-omp-worker-tmux-live-e2e.test.sh
```

#### `portable-serial-5of8` - 27 scripts

```text
tests/fm-pr-check-security.test.sh
tests/fm-ext-topic-threads.test.sh
tests/fm-remote-reply.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-omp-harness.test.sh
tests/fm-secondmate-safety.test.sh
tests/fm-main-ci-watch.test.sh
tests/fm-ext-media.test.sh
tests/fm-fleet-sync.test.sh
tests/fm-boat-routing.test.sh
tests/fm-secondmate-liveness.test.sh
tests/fm-omp-task-inbox-doorbell.test.sh
tests/fm-tasks-axi.test.sh
tests/fm-pending-reply.test.sh
tests/fm-spawn-worktree-settle.test.sh
tests/fm-todo-project.test.sh
tests/fm-nm-pr-guard.test.sh
tests/fm-guard-stale-banner.test.sh
tests/fm-backlog-handoff.test.sh
tests/fm-omp-compact-adviser.test.sh
tests/fm-calm-pi-extension.test.sh
tests/fm-devin-adapter.test.sh
tests/fm-pending-reply-sleep-reconcile.test.sh
tests/fm-gitignore-config.test.sh
tests/fm-opencode-primary-live-e2e.test.sh
tests/fm-grok-stop-live-e2e.test.sh
tests/fm-quota-array-dispatch-live-e2e.test.sh
```

#### `portable-serial-6of8` - 28 scripts

```text
tests/fm-secondmate-harness.test.sh
tests/fm-teardown.test.sh
tests/fm-watch-arm.test.sh
tests/fm-backlog-atomicity.test.sh
tests/fm-watch-recovery-loop.test.sh
tests/fm-remote-secondmate-trace-context.test.sh
tests/fm-landing.test.sh
tests/fm-wake-drain-unread-status.test.sh
tests/fm-spawn-relaunch-dead-endpoint.test.sh
tests/fm-ext-thread-context.test.sh
tests/fm-prepush-guard.test.sh
tests/fm-backend-orca.test.sh
tests/fm-pr-check-handoff.test.sh
tests/fm-fleet-snapshot-view.test.sh
tests/fm-ext-needs-you-buttons.test.sh
tests/fm-ext-watch.test.sh
tests/fm-startup-memory-budget.test.sh
tests/fm-nm-pr-unguarded.test.sh
tests/fm-backend-herdr-server-detach.test.sh
tests/fm-session-lock-ancestry.test.sh
tests/fm-test-fixture-cleanup.test.sh
tests/fm-remote-entrypoint.test.sh
tests/fm-ask-user-authority.test.sh
tests/fm-nm-run-lib.test.sh
tests/fm-backend-cmux-smoke.test.sh
tests/fm-backend-zellij-smoke.test.sh
tests/fm-omp-herdr-exit-live-e2e.test.sh
tests/fm-pi-primary-live-e2e.test.sh
```

#### `portable-serial-7of8` - 29 scripts

```text
tests/fm-hermes-harness.test.sh
tests/fm-boat-lane-runner.test.sh
tests/fm-ext-bridge.test.sh
tests/fm-bearings-snapshot.test.sh
tests/fm-wake-daemon-lifecycle-e2e.test.sh
tests/fm-daemon.test.sh
tests/fm-vendor-auth-probe.test.sh
tests/fm-task-inbox.test.sh
tests/fm-runpod-routing.test.sh
tests/fm-pi-watch-extension.test.sh
tests/fm-procevent-when.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-remote-backlog-handoff.test.sh
tests/fm-ext-ack-guard.test.sh
tests/fm-inbox-result.test.sh
tests/fm-send-secondmate-marker.test.sh
tests/fm-watch-checkpoint.test.sh
tests/fm-remote-herdr-launch.test.sh
tests/fm-omp-fleet-hooks.test.sh
tests/fm-gotmp.test.sh
tests/fm-documentation-audiences.test.sh
tests/fm-test-isolation-proof.test.sh
tests/fm-afk-pi-herdr-return-e2e.test.sh
tests/fm-cleanup-skill.test.sh
tests/fm-omp-branch-bash.test.sh
tests/fm-herdr-submit-confirm-live-e2e.test.sh
tests/fm-devin-herdr-live-e2e.test.sh
tests/fm-omp-secondmate-live-e2e.test.sh
tests/fm-omp-herdr-live-e2e.test.sh
```

#### `portable-serial-8of8` - 27 scripts

```text
tests/fm-omp-secondmate.test.sh
tests/fm-pr-review-manifest.test.sh
tests/fm-wake-queue.test.sh
tests/fm-omp-primary.test.sh
tests/fm-boat-lifecycle.test.sh
tests/fm-remote-job.test.sh
tests/fm-trace-context-spawn.test.sh
tests/fm-secondmate-sync.test.sh
tests/fm-omp-branch-supervision.test.sh
tests/fm-afk-inject-e2e.test.sh
tests/fm-backend.test.sh
tests/fm-pane-autoclose.test.sh
tests/fm-on.test.sh
tests/fm-remote-secondmate-parent-binding.test.sh
tests/fm-gate-refuse.test.sh
tests/fm-update.test.sh
tests/fm-remote-doctor.test.sh
tests/fm-idle-sleep-watch.test.sh
tests/fm-trace-context-lib.test.sh
tests/fm-receipt.test.sh
tests/fm-classify-decision-key.test.sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-treehouse-status-read-only.test.sh
tests/fm-hermes-live-e2e.test.sh
tests/fm-omp-branch-types.test.sh
tests/fm-omp-launch-error-live-e2e.test.sh
tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

To refresh after green runs, take the per-script maximum across the recent green runs you are using, replace the full hint table with those pairs, and regenerate the membership snapshot above from the same hints.
Taking the maximum rather than one run's value keeps the projections at or above every observed run.
Copy the generated assignments into the snapshot and run the partition guard.

```sh
for run_id in 42768866128 42557971268 42756772678; do
  gh-axi run download "$run_id" -R dnth/firstmate \
    --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run_id"
done
jq -sr '[.[].scripts[]] | group_by(.path)[] | [.[0].path, (map(.duration_ms) | max)] | @tsv' \
  /tmp/fm-serial/*/*/*.json | LC_ALL=C sort
for i in 1 2 3 4 5 6 7 8; do
  printf 'portable-serial-%sof8\n' "$i"
  bin/fm-test-run.sh --list --lane "portable-serial-${i}of8"
done
bin/fm-test-run.sh --check-coverage
```

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.

## Timing artifacts

Portable shards, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Job | timeout-minutes | Rationale |
|---|---:|---|
| portable parallel 1/2 | 10 | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1-8 | 20 | The eight-shard assignment projects 13m27.438s-13m29.087s from the refreshed hints, leaving about 6m30.913s for setup and runner-load variance while keeping the timeout as a hang tripwire. |
| Herdr | 40 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
