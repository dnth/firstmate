# Ship relaunch worktree recovery

Verified 2026-09-07 against the local Firstmate checkout and ShellCheck 0.11.0.

Commands: `tests/fm-spawn-worktree-settle.test.sh`; `shellcheck --version`.

Output:

```text
ok - a single transient stale pane_current_path read is not accepted as the worktree
ok - an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle
ok - a sandbox relaunch records the isolated copy published by its own acquisition
ok - a bare ship relaunch resumes the recorded worktree and preserves WIP
ok - a raw ship relaunch requiring a worktree is refused
# all fm-spawn-worktree-settle tests passed
ShellCheck - shell script analysis tool
version: 0.11.0
```

The colocated test drives `bin/fm-spawn.sh <id> --relaunch --mode no-mistakes --yolo off` without a project positional, records a scratch linked worktree in metadata, and verifies the same path remains recorded while an uncommitted file survives.
