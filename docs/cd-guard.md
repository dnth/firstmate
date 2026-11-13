# cd-guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the cd-guard PreToolUse seatbelt.
`bin/fm-cd-command-policy.mjs` is the single decision owner.
`bin/fm-cd-pretool-check.sh` is the stable harness transport, primary-checkout scope, and output renderer.
The tracked harness adapters forward command text without classifying it.

It is one of a family of primary-session guards that share the same cross-harness hook machinery:
the watcher-arm PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`, `docs/arm-pretool-check.md`), the cd-guard, the Python runner guard (`bin/fm-python-pretool-check.sh`, `docs/python-guard.md`), the subagent-shape guard (`bin/fm-subagent-pretool-check.sh`, `docs/subagent-guard.md`), and the turn-end supervision guard (`bin/fm-turnend-guard.sh`, `docs/turnend-guard.md`).

## Purpose and boundary

The primary firstmate shell persists its working directory across tool calls.
A stray persistent top-level `cd projects/<clone>` therefore silently relocates the shell, so the next firstmate-owned command - a backlog write, an `fm-*` lifecycle call, `tasks-axi` - runs inside a project clone instead of the home.
That has actually happened: a persistent top-level `cd` caused a firstmate-owned backlog write to execute inside a project clone rather than the home.
The seatbelt checks persistent directory changes before they run; the home exemption below owns the destination and proof requirements.

This guard is not a general sandbox.
It classifies shell command positions only; it never evaluates, sources, or runs any byte of the submitted command, and it resolves only the operand forms described in the home exemption below.
Its threat model is agent mistakes, the same as the watcher-arm seatbelt: an accidental bare `cd projects/foo`, not a deliberately obfuscated bypass.

## Scope: plain firstmate checkouts only

The guard fires only in a plain firstmate checkout where git-dir equals git-common-dir.
It is a silent no-op (exit 0, no output) everywhere else, so it never interferes with a crewmate or scout that legitimately works inside its own project or firstmate task worktree.

`bin/fm-cd-pretool-check.sh` owns its checkout detection; the turn-end guard's marker-aware scope is a separate contract (`docs/turnend-guard.md`).
A plain, non-worktree checkout has `git rev-parse --git-dir` equal to `git rev-parse --git-common-dir`.
A crewmate or scout task worktree - the shape `bin/fm-spawn.sh` always hands out - is a linked git worktree where the two differ, so the guard is inert there.
The checkout must also carry `AGENTS.md` and `bin/`, and any failure to confirm the primary is treated as inert, never as a block.

The cd-guard does not inspect `.fm-secondmate-home`.
It therefore applies in a git-cloned secondmate home where git-dir equals git-common-dir, but remains inert in a treehouse-leased secondmate home that is itself a linked worktree.
Secondmate child crew and scout worktrees are likewise inert under the linked-worktree test.

## Block vs allow

The discriminator is persistence to the parent shell's cwd combined with where the target resolves, not the mere presence of the token `cd`.

Top-level directory-changing builtins are blocked unless they qualify for [the home exemption](#the-home-exemption).
The following forms do not execute a directory-changing builtin in the parent shell and are allowed outside the keyword-compound refusal described below:

- A command that reaches a target without changing the shell's own cwd: `git -C <dir> ...`, `make -C <dir> ...`, or an absolute path on the command itself.
- A directory change that does not persist to the parent shell: a subshell `(cd x && ...)`, a `bash -c 'cd ...'` / `sh -c` / `zsh -c` payload, an `env -C <dir> ...`, a `find ... -execdir` runner, a pipeline stage (`cd x | cmd`), or a backgrounded `cd x &`.
- A `cd` behind a forking or exec'ing wrapper (`env`, `sudo`, `nohup`, `timeout`, `gtimeout`, `exec`), which runs in a child and never persists (and generally just fails, since `cd` is a builtin with no external program).
- A path-qualified external command named `cd`, `command`, or `builtin`, such as `./cd`, `/usr/bin/cd`, `./command`, `/usr/bin/command`, or `./builtin`, because it runs as a child process and cannot change the parent shell's cwd.
- A `command` query such as `command -v cd`, `command -V cd`, or a clustered form such as `command -pv cd`, because it reports command resolution without executing the named builtin.
- The token `cd` appearing as data: quoted text (`echo "cd projects/foo"`), a comment, a substring of another word (`cdk`, `abcd`, `record`), a `printf` payload, or any later argument word.

### The home exemption

A top-level `cd` is allowed when its single target resolves into the home - the home itself, or a directory inside the home that is outside the `projects/` tree and outside any git checkout other than the home's own - and when the `cd` needs no expansion the policy cannot prove.
An exempt operand is one of exactly these forms:

- A literal path, absolute or relative.
- A leading `~` or `~/...` whose tilde prefix is unquoted and unescaped, expanded from `HOME`.
- A quoted `$FM_HOME` or `${FM_HOME}` prefix, expanded from the shell's own value.

A quoted expansion is neither word-split nor pathname-expanded, so its value reaches `cd` as one operand.
Relative targets resolve from a tracked logical/physical directory pair that starts at the home and advances through allowed directory changes.
`bin/fm-cd-pretool-check.sh` passes the physical primary checkout as `--home` and the shell's actual `FM_HOME` value as `--fm-home`; without `--home` no target is exempt, and an empty `--fm-home` denies every `$FM_HOME` form.
The policy lexically normalizes non-empty `FM_HOME` and `HOME` inputs to absolute paths before resolving operands.
Bash consults `CDPATH` for every relative operand except those whose first component is exactly `.` or `..`, so a non-empty `CDPATH` denies such a target.
Both path rules must land inside the home: logical, where a `..` is collapsed lexically first as under Bash's default `cd`, and physical, where symlinks are followed component by component as under `cd -P`.
The destination must also be an existing, searchable directory, so an exempt `cd` is certain to succeed; a symlink inside the home that points into `projects/`, at a nested checkout, or out of the home is therefore denied, and so is any target that cannot be resolved.

#### The proof requirement

An exemption is granted only when nothing about the `cd` depends on shell behaviour the policy cannot prove.
The command before it must be empty or an exempt `cd` chain joined by `;`, a newline, or `&&`, and the `cd` node itself must carry no redirection, heredoc, or leading assignment, so no expansion can run before the builtin or change what a later relative target means.
This is a deliberate fail-closed boundary, and these shapes are refused even though their target may be safe:

- `cmd; cd data` and `cmd && cd data` after any non-`cd` command, and `cd a || cd b`.
- A pipeline, background job, subshell, or brace group before the `cd`.
- Any command containing a shell keyword at a command position and a `cd`, `pushd`, or `popd` word, including quoted builtin words, keywords after the `cd`, and queries such as `if command -v cd; then :; fi`.
- Any redirection, heredoc, or leading assignment on the `cd` node.
- The unquoted `$FM_HOME` and `${FM_HOME}` forms, which could be split or pathname-expanded.
- A `cd` carrying an empty operand, more than one operand, any option other than the permitted `--` separator, or the special `-` operand (which uses `OLDPWD`).
- An operand containing a double-quoted backslash before an ordinary character, including in a quoted `$FM_HOME` suffix, because the shared lexer drops that backslash while Bash preserves it.
- An unquoted glob or brace expansion, a command substitution, a variable other than a quoted `$FM_HOME`, or further expansion syntax in a `$FM_HOME` suffix.

A protected leading tilde stays literal path text: `'~/data'`, `"~/data"`, and `\~/data` are checked as literal paths rather than expanded from `HOME`.
An unprotected prefix still expands with a quoted suffix, as in `~/"data"`.
`/tmp` stays denied on purpose: a firstmate command run from there resolves the wrong home.
Every `pushd` and `popd` stays denied.
The exemption widens nothing beyond the home: an `FM_HOME` that points somewhere else does not become a second allowed root.

### Known limit

The tracked directory pair starts at the home for every tool call, because the guard cannot observe the shell's cwd from an earlier call.
If the primary shell already sits in a subdirectory of the home when a command arrives, a relative target is still resolved from the home, so a nested checkout reachable only from that deeper directory is not detected.
Passing the hook process's own cwd is deliberately not used: whether it equals the persistent shell's cwd is harness-dependent and unproven, and a wrong value would allow rather than deny.
A cross-call cwd fact needs live per-harness evidence before the guard may rely on it.

### Accepted non-goals

Consistent with the agent-mistake threat model, the guard deliberately does not chase every obfuscated bypass:

- A `cd` reconstructed by a command substitution (`$(echo c)d x`) or hidden inside a brace group (`{ cd x; }`) is not blocked. Brace-group recursion is avoided because this classifier cannot reliably tell a brace group `{ cd; }` from brace expansion `{cd,foo}`, and a false block there is worse than the missed exotic bypass.
- Malformed or untokenizable syntax fails open (allow). Unlike the watcher-arm seatbelt, which fails closed on unclassifiable protected commands, the cd-guard prioritizes zero false blocks over catching a malformed bypass, because a blocked backlog write is a correctness hazard while a missed exotic `cd` is only the pre-existing status quo.

If a genuinely ambiguous command shape is found that risks a false block, the guard is not extended by guesswork; the ambiguity is escalated and the guard stays precise rather than over-eager.

## Stable reason code

Every deny carries one stable code in square brackets before its prose reason.

| Code | Meaning |
| --- | --- |
| `persistent-cd` | A directory-changing builtin did not qualify for the home exemption above. |

The reason directs the caller to reach the target without moving the shell by using `git -C <dir>`, placing an absolute path on the intended command itself, or scoping the `cd` to a subshell.

## Transport and fail-open behavior

`bin/fm-cd-pretool-check.sh` supports all five transport shapes used by the tracked adapters, with pi-signed and OMP sharing Pi's CLI shape:

- Claude sends stdin JSON at `.tool_input.command` and adds `--claude` to preserve Claude's stderr-only deny requirement.
- Codex sends stdin JSON at `.tool_input.command` without `--claude`.
- Grok sends stdin JSON at `.toolInput.command`.
- OpenCode sends the exact command string through `--command <exact string>`.
- Pi, pi-signed, and OMP send the exact command string through `--command <exact string>`.

Processing order is cheapest-first: a strict-superset prefilter, then the primary-checkout scope, then the Node policy owner.
The policy receives the home context described above without the transport expanding the submitted command.
The prefilter removes ordinary single quotes, double quotes, backslashes, carriage returns, and newlines before fast-allowing any command that carries no `cd`, `pushd`, or `popd` substring and no quoting-decoder marker (`$'` ANSI-C or `$"` locale), so quoted or escaped command-word fragments delegate to the policy while most commands never pay for the git scoping calls or the Node process.
The quoting-decoder marker set is coupled to the classifier's decoder set in `bin/fm-arm-command-policy.mjs`: adding any new quote or expansion form the classifier decodes requires extending the prefilter marker set in the same change, or it stops being a strict superset.

Empty stdin, unparseable JSON, missing `jq` on the stdin path, missing Node, a missing policy owner, or an invalid policy response all fail open with exit 0 and no output.
A broken hook must never deny every shell tool call.

## Output contract

Identical in shape to `docs/arm-pretool-check.md`:

- Allow (and inert-outside-primary) returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[persistent-cd] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[persistent-cd] reason"}` to stdout for Grok.
- `--claude` suppresses stdout completely because Claude ignores a PreToolUse deny when stdout is nonempty.
- Codex blocks on exit 2 and displays stderr.
- OpenCode throws only when the checker exits 2.
- Pi, pi-signed, and OMP return `{ block: true }` only when the checker exits 2.

## Shared classifier ownership

`bin/fm-cd-command-policy.mjs` imports the shell tokenizer and command-position analysis (`Lexer`, `splitProgram`, `commandPosition`) from `bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification.
`basename` remains a private helper of the shared arm classifier because the cd policy identifies shell builtins by exact cooked-word identity.
The cd-guard never duplicates shell lexing; it adds only the cd-specific decision on top of that shared classifier.
`bin/fm-arm-command-policy.mjs` runs its own CLI entry point only when invoked directly, never on import, so the two policies stay independent CLIs over one parser.

## Harness wiring

| Harness | Entry | Adapter behavior on checker exit 2 |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse Bash hook forwarding stdin with `--claude` | Blocks the tool call; stderr deny object, stdout empty. |
| Codex | `.codex/hooks.json` PreToolUse hook that anchors from `pwd -P`, verifies the hook-loaded firstmate root, and forwards the payload | Blocks on exit 2 and displays stderr. |
| Grok | `.grok/hooks/fm-primary-cd-check.json` PreToolUse hook anchored on `${GROK_WORKSPACE_ROOT:-}` | Consumes the stdout `decision=deny` object. |
| OpenCode | `.opencode/plugins/fm-primary-cd-check.js` `tool.execute.before` | Throws, which surfaces as the failed tool result. |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` `tool_call` handler | Returns `{ block: true }`; piggybacks on the already-loaded primary extension so no extra `-e` flag is needed. |
| OMP | `.omp/extensions/fm-primary-omp.ts` `tool_call` handler | Returns `{ block: true }`; piggybacks on the natively discovered primary extension. |

Each harness runs the cd-guard alongside the watcher-arm seatbelt; the two are independent checks, and either deny blocks the command.
Every shell variable reference in the Grok hook command carries an inline default (`${GROK_WORKSPACE_ROOT:-}`) because Grok expands the raw hook command before `bash -lc` runs it, the same requirement documented in `docs/arm-pretool-check.md`.

## Automated validation

`tests/fm-cd-pretool-check.test.sh` owns the acceptance matrix.
Every case in that matrix runs through Codex-shaped stdin, Claude-shaped stdin, Grok-shaped stdin, OpenCode-shaped CLI, and Pi-shaped CLI entry forms.
The suite covers the home exemption and its deliberate refusals above, Bash-oracle expansion regressions, the end-to-end cwd-leak regression, checkout scoping, fail-open transport behavior, the prefilter fast path, the policy CLI output contract, and per-harness wiring.
The expansion-specific fixtures supplement the five-entry-form acceptance matrix.
`tests/fm-omp-primary.test.sh` verifies OMP's native field forwarding and exit-2 mapping through the public adapter.

Run:

```sh
bash -n bin/fm-cd-pretool-check.sh
shellcheck bin/fm-cd-pretool-check.sh tests/fm-cd-pretool-check.test.sh
node --check bin/fm-cd-command-policy.mjs
node --check bin/fm-arm-command-policy.mjs
tests/fm-cd-pretool-check.test.sh
tests/fm-arm-pretool-check.test.sh
```

## Live validation record, 2026-07-11

Each harness ran against a scratch primary-shaped firstmate checkout: a plain git repo with `AGENTS.md`, `bin/` holding the real `fm-cd-pretool-check.sh`, `fm-cd-command-policy.mjs`, and `fm-arm-command-policy.mjs` plus a no-op dummy `fm-arm-pretool-check.sh`, a `projects/foo/` stand-in clone, and the tracked harness hook config.
No live watcher, fleet state, or the captain's real primary checkout was involved.
Each harness was told to run, as separate tool calls, a top-level `cd projects/foo && touch <abs>/BLOCKED` (must be denied) and a subshell `(cd projects/foo && touch <abs>/ALLOWED)` (must run), with the sentinel files as the observable.

Harness versions and outcomes:

- **Claude Code 2.1.207** - blocked. Claude reported the top-level command "denied by the `PreToolUse` hook (`fm-cd-pretool-check.sh`)", the `BLOCKED` sentinel was absent, and the subshell form was permitted to run. A prior control `touch` proved the harness executed commands.
- **codex-cli 0.144.0** - blocked. Codex logged `error=Command blocked by PreToolUse hook: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[persistent-cd] a persistent top-level directory change ..."}`, the `BLOCKED` sentinel was absent, and the subshell `ALLOWED` sentinel was created. Both the arm and cd PreToolUse hooks ran per command (two `hook: PreToolUse Completed` lines), confirming Codex re-feeds the payload to each hook in the array.
- **OpenCode 1.17.18** - blocked. `opencode run` printed `✗ cd projects/foo && touch ... failed` with `Error: {"hookSpecificOutput":...,"permissionDecision":"deny"},"systemMessage":"[persistent-cd] ..."}`, the `BLOCKED` sentinel was absent, and the subshell `ALLOWED` sentinel was created.
- **Pi 0.80.6** - blocked. The `BLOCKED` sentinel was absent while the subshell `ALLOWED` sentinel was created; that differential (top-level denied, subshell run, in the same session) can only come from the guard.
- **grok 0.2.93** - inconclusive live run: the Grok Build API returned `402 Payment Required: Grok Build usage balance exhausted`, so the model never issued the probe commands. The grok cd hook (`.grok/hooks/fm-primary-cd-check.json`) is structurally identical to the arm-seatbelt grok hook already live-validated on 2026-07-09 (`docs/arm-pretool-check.md`) - same `${GROK_WORKSPACE_ROOT:-}` anchoring and same PreToolUse deny consumption - and the grok-shaped stdin path (`.toolInput.command` in, `{"decision":"deny"}` out) is covered by `tests/fm-cd-pretool-check.test.sh`. Re-run once the Grok balance is restored to close the live gap.

The launch commands mirrored `docs/arm-pretool-check.md`'s validation:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode run --print-logs --log-level INFO "$PROMPT"
pi -p -e .pi/extensions/fm-primary-turnend-guard.ts --no-context-files --no-session "$PROMPT"
grok --trust -p "$PROMPT" --permission-mode bypassPermissions --output-format plain
```
