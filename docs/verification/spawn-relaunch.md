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
