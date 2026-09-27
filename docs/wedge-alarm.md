# Wedge alarms

Firstmate raises two distinct wedge alarms through one shared channel owner (`bin/fm-wedge-alarm-lib.sh`): the away-mode injection wedge and the watcher's undelivered main-wake alarm.

## Away-mode injection wedge alarm

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and injects them into Firstmate's own pane.
When injection cannot confirm a submit past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The active alert is pane-independent because a tmux status-line flash has no cross-backend equivalent and cannot reach an unattended captain reliably.
The durable marker and tmux flash remain as additional signals.

## Undelivered main-wake alarm

The always-on watcher (`bin/fm-watch.sh`) checks its own durable queue once per poll: when the oldest main-owned row has sat unpresented for `FM_MAIN_WAKE_UNDELIVERED_ALARM_SECS` (default 300 s), it raises one wedge alarm and writes `state/.main-wake-undelivered`.
The marker's first line records the alarmed sequence so a tick cannot re-fire inside one episode; a different row becoming oldest retires the marker and opens a fresh episode.
This is the wall-clock backstop behind the OMP fallback's in-flight bound (`FM_WATCH_MAIN_WAKE_INFLIGHT_BOUND_MS`, see [omp-supervision-branch.md](omp-supervision-branch.md#main-fallback-re-entry-coalescing)): a forced re-delivery may still go unread, and the queue row is the durable evidence that nothing drained it.
While `state/.afk` exists the away daemon owns delivery and carries its own wedge alarm, so the watcher stays silent.
Rows reserved by a live branch grant are not main-owned and never feed this alarm.
The alarm is strictly read-only against the queue and fires on the same channels as the injection wedge; on Linux, `auto` has no OS channel, so `config/wedge-alarm` needs `herdr` or `command:` for an active alert.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert while retaining the durable marker and tmux flash.
- `auto` or `default` resolves to `osascript` on macOS.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal pane.
- `herdr` calls `herdr notification show` outside the supervised pane.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS.
This is deliberate because the injection alarm fires only after a genuine max-defer wedge and is rate-limited to at most once per max-defer window, while the undelivered main-wake alarm fires once per oldest-row episode.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the caller.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, `herdr`, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`, which lives in `bin/fm-wedge-alarm-lib.sh` - the single owner both callers share.
`tests/lib.sh` defaults that seam to `discard`, so no executed watcher or daemon can post a real notification, and a sourced daemon keeps its own `discard` default on top.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
`tests/fm-wake-queue.test.sh` covers the undelivered main-wake alarm's once-per-episode, read-only, afk-skipped, and grant-aware behavior.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual macOS and Herdr channel proof.
