# Python runner guard PreToolUse seatbelt

This document is the authoritative human-readable contract for the Python runner guard PreToolUse seatbelt.
`bin/fm-python-command-policy.mjs` is the single decision owner.
`bin/fm-python-pretool-check.sh` is the stable harness transport, opt-in gate, primary-checkout scope, and output renderer.
The tracked harness adapters forward command text without classifying it.

It belongs to the same family of primary-session guards as the watcher-arm seatbelt ([`arm-pretool-check.md`](arm-pretool-check.md)), the cd-guard ([`cd-guard.md`](cd-guard.md)), the subagent-shape guard ([`subagent-guard.md`](subagent-guard.md)), and the turn-end supervision guard ([`turnend-guard.md`](turnend-guard.md)).
Those owners remain authoritative for their own contracts.

## Purpose and boundary

The captain's standing rule is "Python runs through uv everywhere, never bare `python3`".
A remembered rule drifts: an agent eventually types `python3 script.py` or `pip install <pkg>` in the primary firstmate shell, and the bare interpreter or installer runs outside uv's environment and lockfile discipline.
The seatbelt denies exactly that class of command before it runs, in an executed command position, and its reason names the uv replacement.

This guard is not a general sandbox and does not manage environments itself.
It classifies shell command positions only; it never evaluates, expands, sources, or runs any byte of the submitted command.
Its threat model is agent mistakes, the same as the other guards in the family: an accidental bare `python3`, not a deliberately obfuscated bypass.

## Opt-in

The guard ships inert and is opt-in per home.
`bin/fm-python-pretool-check.sh` reads `config/python-runner` from the effective home: `FM_CONFIG_OVERRIDE`, else `$FM_HOME/config`, else the primary checkout's `config/`.
The only recognized value is `uv` (whitespace ignored).
An absent file, or any other value, makes the guard a silent no-op, so the shared template imposes nothing on other users.
The file is local and gitignored, like the other `config/` operating choices.

## Scope: plain firstmate checkouts only

The guard fires only in a plain firstmate checkout where git-dir equals git-common-dir.
It is a silent no-op (exit 0, no output) everywhere else, so it never interferes with a crewmate or scout that legitimately runs Python inside its own project or firstmate task worktree.

A plain, non-worktree checkout has `git rev-parse --git-dir` equal to `git rev-parse --git-common-dir`.
A crewmate or scout task worktree - the shape `bin/fm-spawn.sh` always hands out - is a linked git worktree where the two differ, so the guard is inert there.
The checkout must also carry `AGENTS.md` and `bin/`, and any failure to confirm the primary is treated as inert, never as a block.

The guard does not inspect `.fm-secondmate-home`.
It therefore applies in a git-cloned secondmate home where git-dir equals git-common-dir, but remains inert in a treehouse-leased secondmate home that is itself a linked worktree.
Secondmate child crew and scout worktrees are likewise inert under the linked-worktree test.

## Block vs allow

The guard denies a bare Python tooling command only when it occupies an executed command position.
It follows the cd-guard's command-position classification: leading assignments and wrappers (`command`, `env`, `sudo`, `nohup`, `exec`, `timeout`) are skipped to reach the real command word, and every top-level command-list node is inspected, including pipeline stages, backgrounded commands, and newline-separated lists.

| Denied command shape | uv replacement named in the reason |
| --- | --- |
| `python`, `python3`, `python3.X` running a script, `-c` code, `-` stdin, or no argument | `uv run python ...`; `uv run --script <script>` for a script with inline PEP 723 dependency metadata; `uv run --with <pkg> python ...` for a one-off dependency |
| `pip` / `pip3` invocations, including `install` | `uv add <pkg>` in a project, `uv pip install <pkg>` in a venv, `uv pip <subcommand>` for the rest |
| `python -m pip ...` | the same `uv add` / `uv pip install` guidance |
| `pipx run <tool>` | `uvx <tool>` |
| `pipx install <tool>` | `uv tool install <tool>` |
| `python -m <tool>` | `uvx <tool>` (or `uv run python -m <tool>` inside the project environment) |
| `python -m venv ...`, `virtualenv ...` | `uv venv` |

The guard allows everything else, including these safe forms that must never be blocked:

- Every `uv ...` and `uvx ...` form, including `uv run python3 ...`, `uv run --with <pkg> python ...`, `uv add`, `uv pip install`, `uv tool install`, and `uv venv`.
- A bare command word appearing as data: inside a quoted string, an argument, a heredoc body, a comment, or a file path (`echo "python3 script.py"`, `grep python3 README.md`, `ls /usr/bin/python3`, `chmod +x ./python3`).
- A different command whose name merely contains the text, such as `python3.12-config`, or a path-qualified interpreter such as `./python3`.
- Other pipx subcommands (`pipx list`), which the guard leaves alone because only `run` and `install` have the specified uv replacements.

### Accepted non-goals

Consistent with the agent-mistake threat model, the guard deliberately does not chase every indirect or obfuscated launch:

- A Python command inside a subshell or brace group, a command substitution, a `bash -c` payload, `eval`, `xargs`, or `find -exec` is not inspected; those are indirect launches outside the cd-guard-style command-position boundary.
- A path-qualified interpreter or installer (`./python3`, `.venv/bin/python`) is not denied; only a bare command word is, which is the literal scope of "never bare `python3`".
- Deliberate byte-level obfuscation is out of scope; ordinary quoted or escaped command words (`"python3"`, `p"ython"3`, `py\thon3`) are still classified through the shared lexer.
- Malformed or untokenizable syntax fails open (allow), matching the cd-guard: zero false blocks wins over catching a malformed bypass.

If a genuinely ambiguous command shape is found that risks a false block, the guard is not extended by guesswork; the ambiguity is escalated and the guard stays precise rather than over-eager.

## Stable reason codes

Every deny carries one stable code in square brackets before its prose reason.

| Code | Meaning |
| --- | --- |
| `bare-python` | A bare Python interpreter invocation, including a `-m` module that is not pip or venv. |
| `bare-pip` | A bare `pip`/`pip3` invocation, including `python -m pip`. |
| `bare-pipx` | A bare `pipx run` or `pipx install` invocation. |
| `bare-virtualenv` | Bare venv creation through `python -m venv` or `virtualenv`. |

## Transport and fail-open behavior

`bin/fm-python-pretool-check.sh` supports all five transport shapes used by the tracked adapters, with pi-signed and OMP sharing Pi's CLI shape:

- Claude sends stdin JSON at `.tool_input.command` and adds `--claude` to preserve Claude's stderr-only deny requirement.
- Codex sends stdin JSON at `.tool_input.command` without `--claude`.
- Grok sends stdin JSON at `.toolInput.command`.
- OpenCode sends the exact command string through `--command <exact string>`.
- Pi, pi-signed, and OMP send the exact command string through `--command <exact string>`.

Processing order is cheapest-first: a strict-superset prefilter, then the primary-checkout scope, then the opt-in gate, then the Node policy owner.
The prefilter removes ordinary single quotes, double quotes, backslashes, carriage returns, and newlines before fast-allowing any command that carries no `python`, `pip`, or `virtualenv` substring and no quoting-decoder marker (`$'` ANSI-C or `$"` locale), so quoted or escaped command-word fragments delegate to the policy while most commands never pay for the git scoping calls or the Node process.
The quoting-decoder marker set is coupled to the classifier's decoder set in `bin/fm-arm-command-policy.mjs`: adding any new quote or expansion form the classifier decodes requires extending the prefilter marker set in the same change, or it stops being a strict superset.

Empty stdin, unparseable JSON, missing `jq` on the stdin path, missing Node, a missing policy owner, or an invalid policy response all fail open with exit 0 and no output.
A broken hook must never deny every shell tool call.

## Output contract

Identical in shape to `docs/cd-guard.md`:

- Allow (and inert-outside-primary or opt-in-absent) returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[bare-python] reason"}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[bare-python] reason"}` to stdout for Grok.
- `--claude` suppresses stdout completely because Claude ignores a PreToolUse deny when stdout is nonempty.
- Codex blocks on exit 2 and displays stderr.
- OpenCode throws only when the checker exits 2.
- Pi, pi-signed, and OMP return `{ block: true }` only when the checker exits 2.

## Shared classifier ownership

`bin/fm-python-command-policy.mjs` imports the shell tokenizer and command-position analysis (`Lexer`, `splitProgram`, `commandPosition`) from `bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification.
The Python guard never duplicates shell lexing; it adds only the Python-tooling decision on top of that shared classifier.
`bin/fm-arm-command-policy.mjs` runs its own CLI entry point only when invoked directly, never on import, so the policies stay independent CLIs over one parser.

## Harness wiring

| Harness | Entry | Adapter behavior on checker exit 2 |
| --- | --- | --- |
| Claude | `.claude/settings.json` PreToolUse Bash hook forwarding stdin with `--claude` | Blocks the tool call; stderr deny object, stdout empty. |
| Codex | `.codex/hooks.json` PreToolUse hook that anchors from `pwd -P`, verifies the hook-loaded firstmate root, and forwards the payload | Blocks on exit 2 and displays stderr. |
| Grok | `.grok/hooks/fm-primary-python-check.json` PreToolUse hook anchored on `${GROK_WORKSPACE_ROOT:-}` | Consumes the stdout `decision=deny` object. |
| OpenCode | `.opencode/plugins/fm-primary-python-check.js` `tool.execute.before` | Throws, which surfaces as the failed tool result. |
| Pi | `.pi/extensions/fm-primary-turnend-guard.ts` `tool_call` handler | Returns `{ block: true }`; piggybacks on the already-loaded primary extension so no extra `-e` flag is needed. |
| OMP | `.omp/extensions/fm-primary-omp.ts` `tool_call` handler | Returns `{ block: true }`; piggybacks on the natively discovered primary extension. |

Each harness runs the Python guard alongside the watcher-arm and cd guards; the checks are independent, and either deny blocks the command.
Every shell variable reference in the Grok hook command carries an inline default (`${GROK_WORKSPACE_ROOT:-}`) because Grok expands the raw hook command before `bash -lc` runs it, the same requirement documented in `docs/arm-pretool-check.md`.

## Automated validation

`tests/fm-python-pretool-check.test.sh` owns the acceptance matrix.
Every block and allow case runs through Codex-shaped stdin, Claude-shaped stdin, Grok-shaped stdin, OpenCode-shaped CLI, and Pi-shaped CLI entry forms.
The suite also proves the opt-in gate (absent, unrecognized, and `FM_CONFIG_OVERRIDE`-selected), the primary-checkout scoping (fires in a git-cloned secondmate fixture, inert in a crewmate/scout linked worktree, inert outside a firstmate checkout, inert outside a git repo), the fail-open transport behavior, the prefilter fast path, the policy CLI output contract, the tracked Claude/Codex/Grok hook wiring, and the OpenCode and Pi adapters forwarding the checker.
`tests/fm-omp-primary.test.sh` verifies OMP's native field forwarding and exit-2 mapping through the public adapter.

Run:

```sh
bash -n bin/fm-python-pretool-check.sh
shellcheck bin/fm-python-pretool-check.sh tests/fm-python-pretool-check.test.sh
node --check bin/fm-python-command-policy.mjs
node --check bin/fm-arm-command-policy.mjs
tests/fm-python-pretool-check.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-omp-primary.test.sh
```
