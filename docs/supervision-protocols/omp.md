Mode: OMP native extension background wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   After handling all emitted wakes and reconciling open decisions and unread status lines, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`; until then the work remains durable for idempotent re-handling after interruption.
2. Confirm plain `omp` auto-loaded `__FM_OMP_PRIMARY_EXT__` from the repository's native `.omp/extensions/` directory.
3. If native discovery is unavailable, restart with `omp -e __FM_OMP_PRIMARY_EXT__`.
4. First cycle only: make the one required `fm_watch_arm_omp` tool call.
   Use `/fm-watch-arm-omp` only as a human-entered fallback.
   Never run `bin/fm-watch-arm.sh` through OMP's bash tool because the primary safety check denies that foreground shape and extension-owned cleanup would be bypassed.
5. If the extension says no live session holds the lock, run `bin/fm-session-start.sh` to reclaim the session lock, then call `fm_watch_arm_omp` again.
6. The extension starts `bin/fm-watch-arm.sh --restart`, keeps the child attached to the live OMP process, and owns every later successor launch.
   The tool and the fallback command return only after that child reports readiness, so a `watcher: FAILED` readiness timeout is a real failure to handle under step 11 rather than a slow success.
7. OMP `/new` and `/resume` events inject the session-start instruction exactly once for the new conversation, replace the prior extension generation, and restore the watcher without a foreground watcher command.
8. After an actionable child close, the shared watcher core rechecks session-lock ownership and verifies one successor before it delivers the follow-up notification.
9. Ordinary work, turn completion, and ordinary notification handling must not call `fm_watch_arm_omp` again because continuity is extension-owned.
10. An unexpected child close enters bounded exponential retry, and an exhausted retry or lost session lock is surfaced as a watcher failure.
11. Missing, failed, or unhealthy cycle only: drain queued notifications, inspect the failure, call `fm_watch_arm_omp`, and restart with the explicit `-e` fallback if the integration is missing or stale.
12. Never use shell `&` for watcher supervision.
13. While the supervision branch is active, MAIN must claim the reserved backlog lease before every `tasks-axi` or direct `data/backlog.md` mutation, then release it after the mutation: `bin/fm-lease.sh claim backlog`, mutate, `bin/fm-lease.sh release backlog`.

For a persistent secondmate, the watcher in that secondmate home touches `state/.last-watcher-beat` at the start of every cycle.
The parent watcher treats a fresh, non-future secondmate-home beacon as positive liveness evidence when the secondmate is neither paused nor captain-held and its pane is idle between child polls, reading remote beacon age through a short bounded call with a forced-kill grace on the configured host route.
The parent watcher uses `FM_STALE_ESCALATE_SECS` (default 240 seconds) as the beacon-age bound, so a missing or stale beacon still enters normal stale and wedge detection.
Remote timeout, beacon read failure, and unavailable pane capture are missing evidence and drive the same stale timer.

The integrated startup, blocking stop, primary safety, watcher, follow-up, and shutdown adapter lives at `__FM_OMP_PRIMARY_EXT__`.
Plain OMP discovers this tracked project extension natively from `.omp/extensions/` without Pi project trust or Pi event semantics.
`bin/fm-session-start.sh` validates the primary adapter marker and the supervision-branch marker against the live session-lock owner and their complete versioned extension/helper closures, then prints the exact restart fallback when either validation fails.

On an OMP primary that owns the fleet lock, a persistent in-process supervision branch absorbs the routine majority of eligible wakes and merges only captain-worthy outcomes back as one follow-up turn; it is default-on and inert when unused, and a broken branch degrades to today's wake-to-main path, so ordinary supervision handling here is unchanged (design: `docs/omp-supervision-branch.md`).
