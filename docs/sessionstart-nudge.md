# Native session-start nudge

AGENTS.md section 3 is the authoritative behavioral contract for session start.
The tracked native adapters inject one instruction and never run the digest, acquire the lock, perform bootstrap work, drain notifications, or arm supervision themselves.
The payload starts with U+2063 and the stable `FIRSTMATE_OP: ` label, carries the current `session-start` protocol kind, and retains exactly ``Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.`` as its body.
The Ahoy skill owns the rule that this marked operational input is never a captain-authored session boundary, including its narrow legacy compatibility cases.

## Shared wrapper and safety

`bin/fm-sessionstart-nudge.sh` is the single command every harness adapter invokes.
It sources `bin/fm-gate-refuse-lib.sh` and stays silent for a no-mistakes gate agent identified by `NO_MISTAKES_GATE` or a `.no-mistakes/repos/*.git` git-common-dir.
It shares `bin/fm-primary-scope-lib.sh` with `bin/fm-turnend-guard.sh`, so the hooks use one primary-detection owner.
The Guard Predicates section of [`turnend-guard.md`](turnend-guard.md#guard-predicates) owns marker validation, plain-checkout detection, and required Firstmate-shaped paths.

Before printing, the wrapper reads `state/.lock` and walks at most eight parents from its own pid in its own separate, hard-coded loop, independent of `bin/fm-lock.sh`'s ancestry walk (`fm_harness_ancestry_pid()` in `bin/fm-session-lock-lib.sh`, which now walks up to sixteen parents and can extend past a claude-named match to a still-more-ancestral one) and of Pi's `lockOwnership()`.
If the lock names a live pid in that ancestry, session start already ran in this harness session and the wrapper stays silent.
Every path exits 0, including malformed state and adapter errors, because a Claude SessionStart exit 2 blocks session initialization.

## Harness transports

| Harness | Tracked transport | Current compatibility |
| --- | --- | --- |
| Claude | `.claude/settings.json` registers `SessionStart` for `startup`, `resume`, and `clear`, excludes `compact`, and invokes the wrapper through `CLAUDE_PROJECT_DIR`. | Native stdout context injection is supported. |
| Codex | `.codex/hooks.json` anchors to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and executes the wrapper. | Native stdout context injection is supported. |
| OpenCode | `.opencode/plugins/fm-primary-sessionstart-nudge.js` listens for `session.created`, runs once per session id, and calls `client.session.promptAsync` only when the wrapper prints a nudge. | Interactive TUI delivery is supported; headless `opencode run` is intentionally fail-open because the process can exit before the queued turn. |
| Pi / pi-signed | `.pi/extensions/fm-primary-turnend-guard.ts` handles `session_start` reasons `startup`, `new`, and `resume`, then injects the wrapper output with `pi.sendMessage`. | The custom message reaches model context without racing an initial positional prompt. |
| OMP | `.omp/extensions/fm-primary-omp.ts` runs the wrapper on native `session_start` and injects the result as one hidden `before_agent_start` message bound to the launch prompt. A native `/new` or `/resume` switch instead appends the same typed instruction to the replacement session's context at once through `sendMessage` without starting a turn: the wrapper stays silent while this session still holds the lock, and the restored watcher's first wake can start an agent-initiated turn that never reaches `before_agent_start`. `/fork` still invokes the wrapper silently under the held lock, and OMP reloads likewise keep that wrapper invocation silent while following the native `resume` switch transport. | The custom message reaches model context without racing the launch prompt or the restored watcher's first wake, and native project discovery loads the adapter without a trust prompt. |
| Grok | `.grok/hooks/fm-primary-sessionstart-nudge.json` registers a project `SessionStart` hook and invokes the wrapper through inline-defaulted `${GROK_WORKSPACE_ROOT:-}`. | The project hook runs when the checkout is trusted, but Grok currently discards hook stdout from model context, so this path is intentionally fail-open. |

The OpenCode nudge runs only on `session.created`.
The watcher-arm and turn-end plugins run later on `session.idle`, and the guard lets the watcher coordinator act first, so the plugins do not race for one lifecycle event.

Grok's guaranteed-loading alternative is a global token-guarded hook like the pattern used by `bin/fm-spawn.sh`.
That alternative expands trust and writes outside this repository, so Firstmate never installs it or grants folder trust automatically.

## Regression coverage

`tests/fm-sessionstart-nudge.test.sh` proves wrapper silence for both gate signals, an unmarked linked worktree, a missing state directory, and an already-owned lock.
It proves exact U+2063 `FIRSTMATE_OP:`-prefixed, `session-start`-typed one-line output for a plain primary and a marked linked secondmate primary.
`tests/fm-pi-primary-live-e2e.test.sh` and `tests/fm-opencode-primary-live-e2e.test.sh` exercise native startup paths with first-message and later-message Ahoy regressions.
`tests/fm-omp-primary.test.sh` proves each in-process `/new` and `/resume` switch appends exactly one instruction without staging a second copy, including a second `/new` with no `before_agent_start` in between, while `/fork` stays silent under the held lock.
`tests/fm-omp-primary-live-e2e.test.sh` covers OMP's native discovery and once-only startup delivery, including two consecutive `/new` switches whose instruction precedes each new session's first assistant turn, and an exact-session resume launch.
`tests/fm-turnend-guard.test.sh`, `tests/fm-pi-watch-extension.test.sh`, and `tests/fm-daemon.test.sh` cover marked guard, monitoring, and away-mode delivery.

[`verification/supervision.md`](verification/supervision.md#native-session-start-delivery) records the active version-scoped transport evidence.
