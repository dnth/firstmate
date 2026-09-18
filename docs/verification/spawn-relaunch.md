# Ship and OMP relaunch recovery

Verified 2026-09-10 against the local Firstmate checkout and ShellCheck 0.11.0.

Commands: `tests/fm-spawn-worktree-settle.test.sh`; `tests/fm-omp-relaunch-guard.test.sh`; `FM_OMP_TMUX_LIVE_E2E=1 tests/fm-omp-relaunch-tmux-live-e2e.test.sh`; `shellcheck --version`.

Output:

```text
ok - a single transient stale pane_current_path read is not accepted as the worktree
ok - an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle
ok - a sandbox relaunch records the isolated copy published by its own acquisition
ok - a bare ship relaunch resumes the recorded worktree and preserves WIP
ok - a bare ship relaunch restores recorded harness, model, and effort
ok - a raw ship relaunch requiring a worktree is refused
ok - a ship relaunch refuses an active tmux endpoint before sending input
ok - a ship relaunch refuses a worktree from an unrelated repository
# all fm-spawn-worktree-settle tests passed
ok - OMP ship relaunch accepts existing task artifacts and preserves profile
ok - OMP ship relaunch preserves explicit prewalk and extension opt-in
ok - fresh OMP spawn refuses existing task artifacts
ok - OMP relaunch refuses an active tmux endpoint
ok - OMP relaunch refuses a recorded endpoint belonging to another task
ok - OMP relaunch refuses a recorded worktree that is missing
# all OMP relaunch guard tests
ok - real tmux OMP relaunch: preserved worktree/inbox, new generation, and resumed acknowledgement
ShellCheck - shell script analysis tool
version: 0.11.0
```

The colocated test drives `bin/fm-spawn.sh <id> --relaunch --mode no-mistakes --yolo off` without a project positional, records a scratch linked worktree in metadata, and verifies the same path remains recorded while an uncommitted file survives.

The OMP relaunch guard test adds a fake-tmux/fake-omp fixture covering the same-task early-artifact guard, mode/yolo/pre-walk recovery, fresh-spawn collision refusal, active endpoint refusal, and endpoint-identity validation.

The live lab runs a real OMP ship on a private tmux socket, exits it, then runs `bin/fm-spawn.sh <id> --relaunch`. It verifies the recorded worktree and a dirty sentinel and pending inbox survive, no second worktree is allocated, the `spawn_gen` changes, and the relaunched worker re-acknowledges.

## Dead-endpoint relaunch recovery (2026-09-18)

Verified 2026-09-18 against the local Firstmate checkout (detached HEAD at the `fm/fm-relaunch-dead-endpoint` work) and ShellCheck 0.11.0, porting upstream herdr commit `3e817d3f` (`recover gone and drifted worker endpoints`, upstream issue `#4091`).

Commands: `tests/fm-spawn-relaunch-dead-endpoint.test.sh`; `tests/fm-backend-herdr.test.sh`; `tests/fm-backend-zellij.test.sh`; `tests/fm-backend-cmux.test.sh`; `tests/fm-spawn-worktree-settle.test.sh`; `tests/fm-omp-relaunch-guard.test.sh`; `tests/fm-secondmate-liveness.test.sh`; `bin/fm-lint.sh`.

Output:

```text
ok - fm-spawn --relaunch: proven-missing tmux endpoint recreates the window in the recorded worktree
ok - fm-spawn --relaunch: a durable fm-<id> Treehouse lease proves worktree ownership
ok - fm-control relaunch: a proven-missing endpoint counts as already stopped and the transaction completes
ok - fm-spawn --relaunch: a live endpoint in a foreign cwd still refuses
ok - fm-spawn --relaunch: a live agent at the recorded endpoint still refuses
ok - fm-spawn --relaunch: an ambiguous endpoint state still refuses
ok - fm-spawn --relaunch: a proven-gone endpoint with a non-pool worktree refuses
ok - fm-spawn --relaunch: a slot claimed by another task refuses
ok - fm-spawn --relaunch: a worktree with no ownership evidence refuses
ok - fm-spawn --relaunch: a worktree leased to another task refuses
ok - fm-spawn --relaunch: a stopped herdr session server recreates the endpoint in the worktree
ok - fm-spawn --relaunch: a drifted herdr shell gets one cd back to the worktree
ok - fm-spawn --relaunch: a herdr shell that cannot return to the worktree refuses
ok - fm-spawn --relaunch: a proven-absent zellij endpoint recreates the tab in the worktree
ok - fm-spawn --relaunch: a live zellij endpoint still refuses
ok - fm-spawn --relaunch: a proven-absent cmux endpoint recreates the workspace in the worktree
ok - fm-spawn --relaunch: a live cmux endpoint still refuses
ok - fm-spawn --relaunch: orca remains refused
ok - all dead-endpoint relaunch tests
# all fm-spawn-worktree-settle tests passed
# all OMP relaunch guard tests
# all fm-secondmate-liveness tests passed
# fm-backend-zellij / fm-backend-cmux / fm-backend-herdr: all assertions passed
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0) - exit 0
```

The e2e drives `bin/fm-spawn.sh <id> --relaunch` and `bin/fm-control.sh <id> relaunch` against fake tmux/herdr/zellij/cmux CLIs.
A proven-gone endpoint - tmux `missing`, herdr `.server.running: false`, zellij or cmux structural absence - recreates the endpoint inside the recorded worktree only after pool-slot or durable-lease ownership is proven, preserving the same brief and progress note.
A drifted live herdr shell receives exactly one `cd` back to the recorded worktree; a shell that will not go refuses.
Live agents, ambiguous, unreadable, unverified, foreign-worktree, and unprovable-ownership outcomes all refuse unchanged, and orca remains refused.

Regression notes: `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` fails at "dead markerless reconciliation notify" identically on the pristine `main` checkout (environmental fake-remote fixture, unrelated to this change); `tests/fm-omp-relaunch-tmux-live-e2e.test.sh` and `tests/fm-backend-cmux-smoke.test.sh` skip without their opt-in env or CLI.
