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

The refreshed hints use all 166 completed serial-script measurements from PR run [38774522507](https://github.com/dnth/firstmate/actions/runs/38774522507), totaling 5,461,112 ms (91m01.112s).
The measured durations replace the older estimates and default weights in `portable_serial_weight_hints`.
`portable-serial-<k>of<n>` splits that remainder across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.

### Timeout diagnosis

The recent 20-minute cancellations came from aggregate serial work, not a hanging `fm-watch-checkpoint.test.sh`.
The cancelled PR run is [38753521432](https://github.com/dnth/firstmate/actions/runs/38753521432).
Its first attempt ended during `fm-on.test.sh` after the job reached its timeout, before the checkpoint test began.
Its second attempt reached the checkpoint test about five seconds before cancellation, after the preceding serial scripts consumed the available job time.
Its third attempt ended during `fm-wake-drain-unread-status.test.sh` after its wake acknowledgement, about ten seconds after that test began.
On main run [38746979839 attempt 1](https://github.com/dnth/firstmate/actions/runs/38746979839/attempts/1), all 28 scripts emitted a 19m55.325s summary before the job was cancelled near its 20-minute limit.
The passing main attempt completed the same shard's 28 scripts in 17m20.456s.

| Run / attempt | Measured shard-3 script spans (UTC) | Result |
|---|---|---|
| [Main 38746979839 attempt 1](https://github.com/dnth/firstmate/actions/runs/38746979839/attempts/1), cancelled | `fm-watch-triage`: 13:56:29–14:03:33 (423,952 ms); `fm-ext-decision`: 14:10:55–14:13:28 (153,704 ms); `fm-watch-checkpoint`: 14:16:03–14:16:10 (5,993 ms). | All scripts completed; the 19m55.325s suite summary preceded cancellation. |
| [PR 38753521432 attempt 1](https://github.com/dnth/firstmate/actions/runs/38753521432/attempts/1), cancelled | `fm-watch-triage`: 14:40:54–14:48:14 (440,356 ms); `fm-ext-decision`: 14:55:56–14:58:39 (163,088 ms); `fm-on` began 15:00:52 and the job cancelled at 15:01:00. | Cancelled in the final `fm-on` test; checkpoint did not start. |
| [PR 38753521432 attempt 2](https://github.com/dnth/firstmate/actions/runs/38753521432/attempts/2), cancelled | `fm-watch-triage`: 15:05:34–15:12:49 (435,200 ms); `fm-ext-decision`: 15:20:20–15:22:55 (155,491 ms); `fm-watch-checkpoint` began at 15:25:32 and the job cancelled at 15:25:37. | The checkpoint log reached its wake acknowledgement before cancellation; no test-end marker was emitted. |
| [PR 38753521432 attempt 3](https://github.com/dnth/firstmate/actions/runs/38753521432/attempts/3), cancelled | `fm-watch-triage`: 15:30:20–15:37:47 (446,890 ms); `fm-ext-decision`: 15:45:36–15:48:25 (169,627 ms); `fm-wake-drain-unread-status` began at 15:50:11 and the job cancelled at 15:50:21. | Cancelled after the wake acknowledgement in `fm-wake-drain-unread-status`. |
| [Main 38746979839 attempt 2](https://github.com/dnth/firstmate/actions/runs/38746979839/attempts/2), passed | `fm-watch-triage`: 14:22:32–14:29:22 (410,055 ms); `fm-ext-decision`: 14:35:28–14:37:25 (116,759 ms); `fm-watch-checkpoint`: 14:39:36–14:39:41 (5,271 ms). | All 28 scripts completed in 17m20.456s. |
| [PR 38774522507](https://github.com/dnth/firstmate/actions/runs/38774522507), passing six-shard run | `fm-spawn-dispatch-profile`: 17:06:27–17:10:37 (249,954 ms); `fm-ext-decision`: 17:10:37–17:13:18 (161,682 ms); `fm-ext-topic-threads`: 17:13:18–17:14:59 (100,660 ms); `fm-watch-arm`: 17:14:59–17:16:25 (85,430 ms). | The 30 scripts summed to 1,022,126 ms (17m02.126s); job wall time was 17m17s. |

The checkpoint completed in 5.271s and 5.993s on the passing and cancelled main attempts, respectively.
All three cancelled PR attempts reached the 20-minute limit in different tests: `fm-on`, `fm-watch-checkpoint`, and `fm-wake-drain-unread-status`, so no single test hung.
The six-shard PR run 38774522507 completed every script, but its 91m01.112s total exceeds six times the ~14-minute budget (84 minutes); shard 3 summed to 17m02.126s and took 17m17s wall time.
The slowest script in shard 3 was `fm-spawn-dispatch-profile.test.sh` at 249,954 ms (4m09.954s), so the shard overrun is aggregate growth, not a single hung test.
Seven shards are required to keep the refreshed per-script assignment near the documented budget; test assertions and the 20-minute cap remain unchanged.

Recent green `fm-watch-triage.test.sh` measurements provide the comparison for attempt 3's 446,890 ms:

| Passing run | Duration (ms) |
|---|---:|
| [38540024417](https://github.com/dnth/firstmate/actions/runs/38540024417) | 406,842 |
| [38546582306](https://github.com/dnth/firstmate/actions/runs/38546582306) | 414,725 |
| [38551009549](https://github.com/dnth/firstmate/actions/runs/38551009549) | 419,614 |
| [38535146206](https://github.com/dnth/firstmate/actions/runs/38535146206) | 421,505 |
| [38746979839 attempt 2](https://github.com/dnth/firstmate/actions/runs/38746979839/attempts/2) | 410,055 |
| [PR 38774522507](https://github.com/dnth/firstmate/actions/runs/38774522507) | 428,164 |

The 446,890 ms result exceeds the latest passing measurement in this table, 428,164 ms, by 18,726 ms (about 4.4%), so it is not a large outlier.
PR run 38774522507 measured `fm-watch-triage.test.sh` at 428,164 ms (7m08.164s), within the observed range.
Separately, [run 38759616524](https://github.com/dnth/firstmate/actions/runs/38759616524) failed the stale-suppressor assertion after 100,083 ms.
That is a separate correctness signal, not evidence that a 447-second `fm-watch-triage` run caused the timeout; the test assertions remain unchanged.

### Rebalanced duration profile

The six-shard PR run measured 5,461,112 ms (91m01.112s) across 166 serial scripts, averaging 15m10.185s per shard.
Seven shards are needed because six shards cannot fit that measured total within the ~14-minute budget.

PR run 38774522507 measured `fm-watch-triage.test.sh` at 428,164 ms (7m08.164s); the earlier PR attempt 3 measured 446,890 ms (7m26.890s).
If `fm-watch-triage.test.sh` reaches 446,890 ms again, shard 2 rises by only 18,726 ms to 798,888 ms (13m18.888s), still within the ~14-minute budget.
The seven-shard assignment covers the observed variation without raising the 20-minute hang tripwire.

| Shard | Scripts | Measured six-shard script sum | Six-shard CI job wall |
|---|---:|---:|---:|
| 1 of 6 | 23 | 14:28.264 | 14:46 |
| 2 of 6 | 27 | 15:27.115 | 15:44 |
| 3 of 6 | 30 | 17:02.126 | 17:17 |
| 4 of 6 | 30 | 14:58.449 | 15:13 |
| 5 of 6 | 26 | 13:22.769 | 13:36 |
| 6 of 6 | 30 | 15:42.389 | 15:59 |
| Total | 166 | 91:01.112 | — |

The seven-shard LPT assignment uses those same per-script measurements and balances within 15 ms.

| Shard | Scripts | Projected script time |
|---|---:|---:|
| 1 of 7 | 17 | 13:00.156 |
| 2 of 7 | 23 | 13:00.162 |
| 3 of 7 | 23 | 13:00.151 |
| 4 of 7 | 25 | 13:00.154 |
| 5 of 7 | 26 | 13:00.161 |
| 6 of 7 | 26 | 13:00.162 |
| 7 of 7 | 26 | 13:00.166 |
| Total | 166 | 91:01.112 |

The longest measured script is `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` at 657,637 ms (10m57.637s), which is the single-script lower bound for any shard count.

The current shard memberships below are generated from the same hints.

### Current shard membership

#### `portable-serial-1of7` — 17 scripts

```text
tests/fm-remote-secondmate-lifecycle-e2e.test.sh
tests/fm-wake-drain-unread-status.test.sh
tests/fm-pi-watch-extension.test.sh
tests/fm-backend-orca.test.sh
tests/fm-pr-check-handoff.test.sh
tests/fm-gate-refuse.test.sh
tests/fm-todo-project.test.sh
tests/fm-secondmate-lifecycle-e2e.test.sh
tests/fm-treehouse-sweep.test.sh
tests/fm-omp-compact-adviser.test.sh
tests/fm-runpod-omp-auth.test.sh
tests/fm-test-isolation-proof.test.sh
tests/fm-operational-input.test.sh
tests/fm-cleanup-skill.test.sh
tests/fm-send-inbox-doorbell-live-e2e.test.sh
tests/fm-omp-branch-live-e2e.test.sh
tests/fm-omp-herdr-exit-live-e2e.test.sh
```

#### `portable-serial-2of7` — 23 scripts

```text
tests/fm-watch-triage.test.sh
tests/fm-omp-harness.test.sh
tests/fm-runpod-lifecycle.test.sh
tests/fm-main-ci-watch.test.sh
tests/fm-task-inbox.test.sh
tests/fm-secondmate-restart.test.sh
tests/fm-backend.test.sh
tests/fm-procevent-when.test.sh
tests/fm-task-delivery.test.sh
tests/fm-wake-drain-open-decisions.test.sh
tests/fm-tangle-guard.test.sh
tests/fm-ext-plugin-dest.test.sh
tests/fm-guard-stale-banner.test.sh
tests/fm-busy-state.test.sh
tests/fm-receipt.test.sh
tests/fm-gotmp.test.sh
tests/fm-check-unregister.test.sh
tests/fm-ask-user-authority.test.sh
tests/fm-afk-pi-herdr-return-e2e.test.sh
tests/fm-omp-branch-bash.test.sh
tests/fm-omp-branch-types.test.sh
tests/fm-omp-secondmate-live-e2e.test.sh
tests/fm-omp-primary-live-e2e.test.sh
```

#### `portable-serial-3of7` — 23 scripts

```text
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-ext-topic-threads.test.sh
tests/fm-bearings-snapshot.test.sh
tests/fm-backlog-atomicity.test.sh
tests/fm-secondmate-safety.test.sh
tests/fm-trace-context-spawn.test.sh
tests/fm-runpod-routing.test.sh
tests/fm-fleet-sync.test.sh
tests/fm-boat-routing.test.sh
tests/fm-remote-backlog-handoff.test.sh
tests/fm-tasks-axi.test.sh
tests/fm-fleet-snapshot-view.test.sh
tests/fm-inbox.test.sh
tests/fm-ext-watch.test.sh
tests/fm-omp-relaunch-guard.test.sh
tests/fm-send-secondmate-marker.test.sh
tests/fm-remote-secondmate-sleep-reconcile.test.sh
tests/fm-supervision-events.test.sh
tests/fm-calm-pi-extension.test.sh
tests/fm-treehouse-orphan-recovery.test.sh
tests/fm-backend-cmux-smoke.test.sh
tests/fm-codex-continuity-live-e2e.test.sh
tests/fm-remote-omp-update-restart-live-e2e.test.sh
```

#### `portable-serial-4of7` — 25 scripts

```text
tests/fm-secondmate-harness.test.sh
tests/fm-ext-waiting-pin.test.sh
tests/fm-watch-arm.test.sh
tests/fm-bootstrap.test.sh
tests/fm-session-start.test.sh
tests/fm-remote-job.test.sh
tests/fm-public-followup.test.sh
tests/fm-runpod-pod-boot.test.sh
tests/fm-omp-branch-supervision.test.sh
tests/fm-afk-inject-e2e.test.sh
tests/fm-omp-task-inbox-doorbell.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-shared-captain-inheritance.test.sh
tests/fm-on.test.sh
tests/fm-herdr-session-cleanup.test.sh
tests/fm-watch-checkpoint.test.sh
tests/fm-backlog-handoff.test.sh
tests/fm-afk-return.test.sh
tests/fm-documentation-audiences.test.sh
tests/fm-classify-decision-key.test.sh
tests/fm-pending-reply-sleep-reconcile.test.sh
tests/fm-pi-compatible-family.test.sh
tests/fm-herdr-submit-confirm-live-e2e.test.sh
tests/fm-grok-stop-live-e2e.test.sh
tests/fm-grok-continuity-live-e2e.test.sh
```

#### `portable-serial-5of7` — 26 scripts

```text
tests/fm-pr-check-security.test.sh
tests/fm-omp-secondmate.test.sh
tests/fm-wake-queue.test.sh
tests/fm-wake-daemon-lifecycle-e2e.test.sh
tests/fm-boat-omp-auth.test.sh
tests/fm-remote-secondmate-trace-context.test.sh
tests/fm-boat-lifecycle.test.sh
tests/fm-send-inbox.test.sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-remote-secondmate-update-restart.test.sh
tests/fm-prepush-guard.test.sh
tests/fm-remote-secondmate-parent-binding.test.sh
tests/fm-pending-reply.test.sh
tests/fm-inbox-result.test.sh
tests/fm-backend-zellij.test.sh
tests/fm-remote-doctor.test.sh
tests/fm-backend-cmux.test.sh
tests/fm-session-lock-ancestry.test.sh
tests/fm-omp-update.test.sh
tests/fm-devin-adapter.test.sh
tests/fm-remote-entrypoint.test.sh
tests/fm-stall-recovery.test.sh
tests/fm-backend-herdr-focus-flash-e2e.test.sh
tests/fm-devin-herdr-live-e2e.test.sh
tests/fm-omp-compact-adviser-live-e2e.test.sh
tests/fm-omp-herdr-live-e2e.test.sh
```

#### `portable-serial-6of7` — 26 scripts

```text
tests/fm-ext-decision.test.sh
tests/fm-boat-lane-runner.test.sh
tests/fm-ext-bridge.test.sh
tests/fm-procevent.test.sh
tests/fm-omp-primary.test.sh
tests/fm-daemon.test.sh
tests/fm-landing.test.sh
tests/fm-secondmate-sync.test.sh
tests/fm-spawn-relaunch-dead-endpoint.test.sh
tests/fm-send-resolve-key.test.sh
tests/fm-turnend-guard.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-spawn-worktree-settle.test.sh
tests/fm-send-turn-start.test.sh
tests/fm-dispatch-resolve.test.sh
tests/fm-idle-sleep-watch.test.sh
tests/fm-omp-fleet-hooks.test.sh
tests/fm-trace-context-lib.test.sh
tests/fm-subagent-pretool-check.test.sh
tests/fm-reflect-skill.test.sh
tests/fm-treehouse-status-read-only.test.sh
tests/fm-send-secondmate-marker-herdr-e2e.test.sh
tests/fm-gitignore-config.test.sh
tests/fm-pi-primary-live-e2e.test.sh
tests/fm-opencode-primary-live-e2e.test.sh
tests/fm-omp-relaunch-tmux-live-e2e.test.sh
```

#### `portable-serial-7of7` — 26 scripts

```text
tests/fm-hermes-harness.test.sh
tests/fm-teardown.test.sh
tests/fm-remote-reply.test.sh
tests/fm-watch-recovery-loop.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-ext-ask.test.sh
tests/fm-watcher-lock.test.sh
tests/fm-vendor-auth-probe.test.sh
tests/fm-spawn-pool-base-freshen.test.sh
tests/fm-wake-drain-open-decisions-cursor.test.sh
tests/fm-secondmate-liveness.test.sh
tests/fm-ext-thread-context.test.sh
tests/fm-idle-sleep.test.sh
tests/fm-update.test.sh
tests/fm-startup-memory-budget.test.sh
tests/fm-receipt-check.test.sh
tests/fm-backend-herdr-server-detach.test.sh
tests/fm-merge-local.test.sh
tests/fm-test-fixture-cleanup.test.sh
tests/fm-sessionstart-nudge.test.sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-hermes-live-e2e.test.sh
tests/fm-backend-zellij-smoke.test.sh
tests/fm-claude-stop-autoarm-live-e2e.test.sh
tests/fm-omp-worker-tmux-live-e2e.test.sh
tests/fm-quota-array-dispatch-live-e2e.test.sh
```

To refresh after a green run, replace the full hint table with measured per-script pairs and regenerate the membership snapshot above from the same hints.
Copy the generated assignments into the snapshot and run the partition guard.

```sh
gh run download <run-id> -R dnth/firstmate --pattern 'fm-test-timing-portable-serial-*' -D /tmp/fm-serial
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*.json | LC_ALL=C sort
for i in 1 2 3 4 5 6 7; do
  printf 'portable-serial-%sof7\n' "$i"
  bin/fm-test-run.sh --list --lane "portable-serial-${i}of7"
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
| portable serial 1-7 | 20 | The seven-shard assignment projects 13m00.151s–13m00.166s from PR run 38774522507, leaving about 6m59.834s for setup and runner-load variance while keeping the timeout as a hang tripwire. |
| Herdr | 40 | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
