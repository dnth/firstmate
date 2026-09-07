# Ship relaunch worktree recovery

Verified 2026-09-07 against the local Firstmate checkout and ShellCheck 0.11.0.

Command: `tests/fm-spawn-worktree-settle.test.sh`.

Output: `ok - a bare ship relaunch resumes the recorded worktree and preserves WIP`.

The colocated test drives `bin/fm-spawn.sh <id> --relaunch --mode no-mistakes --yolo off` without a project positional, records a scratch linked worktree in metadata, and verifies the same path remains recorded while an uncommitted file survives.
