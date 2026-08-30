# tmux runtime backend

tmux is Firstmate's verified reference runtime backend and the fully supported baseline for secondmate homes.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Setup

Install tmux with `brew install tmux` or your platform package manager.
The universal harness and toolchain requirements are in [`configuration.md`](configuration.md#toolchain).

tmux is the hard default when no explicit setting or runtime auto-detection selects another backend.
Select it explicitly with local `config/backend` containing `tmux`, with `FM_BACKEND=tmux` for one launch, or by asking Firstmate to use tmux.
An explicit selection is also the opt-out from Herdr or cmux runtime auto-detection.

No provisioning is required before the first task.

## Watching the crew

For the best visible experience, launch the primary harness inside a tmux session:

```sh
tmux new -s firstmate
```

Crew tasks become windows in that session.
`tmux display-message -p '#S'` prints its name.
If the primary harness runs outside tmux, Firstmate creates or reuses a detached session named `firstmate`:

```sh
tmux attach -t firstmate
```

Each task window is named `fm-<id>`.

```sh
tmux list-windows -t <session-name>
tmux select-window -t <session-name>:fm-<id>
```

Typing into an attached task window is authoritative direct intervention.
Routine supervision does not require attachment: `bin/fm-peek.sh <id>` captures a bounded tail and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` steers the recorded endpoint.

Verify setup by spawning a small task and confirming its `fm-<id>` window appears in the selected session.

## Current behavior and safety

### Agent liveness probe

A target-existence check proves only that the pane exists.
The deeper tmux agent-liveness probe first verifies exact window membership, then reads process names to distinguish a running harness from a bare idle shell.
It classifies recognized Claude, Codex, OpenCode, Pi, pi-signed, Grok, and Kimi process names as `alive`, common shells as `dead`, an authoritatively absent window as `missing`, unreadable state as `unreadable`, and every other process as `ambiguous`.
OMP recovery first validates its task-bound metadata and then distinguishes the two supported process shapes.
Legacy Bun-script OMP requires an absolute argv entrypoint equal to `omp_bin`, an actual foreground executable equal to `omp_bun`, and an independent PID executable check for that same Bun runtime.
Standalone OMP requires `omp_bun` and `omp_bin` to be the same absolute executable path, and its exact PID executable check is decisive regardless of the process name exposed by a renamed or symlinked installation.
For legacy env-shebang launches, a bare `bun` argv token or the canonical runtime basename is accepted only when the independent PID executable check proves the recorded Bun binary; a bare OMP token or a fresh `PATH` lookup is never identity evidence.
The canonical `omp_bun` and `omp_bin` identities must be absolute, executable, and whitespace-free because the portable process reader exposes one flattened argument string.
Legacy launches invoke the selected OMP entrypoint directly, with env-based Bun shebangs receiving a launch-local `PATH` binding and explicit absolute Bun shebangs using their declared interpreter, while standalone launches invoke the selected executable directly without passing it through Bun.
The primary adapter refuses unsupported paths before marker publication and replaces its marker atomically so a pre-existing symlink is never followed to its target.
Only `dead` and `missing` authorize recovery because a false dead result could launch a duplicate agent.

For positive attribution, the probe combines two independent name sources rather than making either one load-bearing.
`#{pane_current_command}` and the pane tty foreground process group's kernel `comm` values expose different name fields, and which one retains executable identity is platform-dependent.
The foreground probe also reads argv[0] so an exact harness install-path component can carry the verdict when the other fields expose a rewritten process name.
Either source naming a verified harness is enough for `alive`, because a false `dead` is the one verdict that can start a duplicate agent on a live worktree, while a readable foreground process group settles the negative verdicts.

Scoping the second source to the foreground process group rather than to the pane's descendants is deliberate: a harness-named process left running in the background of an otherwise idle pane must not read as an agent.
The same scoping covers multi-process launchers without a special case, so the Pi Launcher path is attributed through its `pi-signed` wrapper and `pi` engine even though its title is the exact foreground command `pi-launcher`.
Direct executable identities `pi`, `pi-signed`, and `Pi` remain accepted exactly, and similar or prefixed process names are not accepted through those exact Pi-family entries.

The CI-enforced portable regression and opt-in real-harness drift guard follow the split owned by `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
Run the real-harness guard after any harness upgrade and before trusting refreshed evidence.

### Composer, busy state, and delivery

Agent liveness and composer safety are separate checks.
For a bordered composer, the tmux reader locates the complete box structurally and classifies every content row through the shared ANSI and ghost handling in `bin/fm-composer-lib.sh`.
The OMP two-row reader is tried only when the caller-supplied harness identity is OMP, because tmux exposes no native agent identity and another harness that happens to render an OMP-shaped row keeps the generic reader it was verified against.
OMP's independent two-row composer additionally requires exact top/bottom terminal-cell width equality, measured with the canonical runtime and entrypoint identities from validated task metadata through the dispatcher and every submit retry; legacy scripts use `Bun.stringWidth`, while standalone executables use a locale-independent Node fallback guarded by fixed compiled OMP 17.3.8 / Bun 1.3.14 compatibility fixtures.
A fresh `PATH` lookup, a missing binding, a non-executable path, or a runtime/process mismatch cannot authorize geometry and yields `unknown`.
Real text on any content row is pending, while only an unambiguous box with every row empty is proven empty.
Unreadable, incomplete, or structurally ambiguous boxes fail closed, and panes without a bordered composer retain the compatible cursor-row classification.
The shared classifier accepts a shell glyph as an empty agent composer only inside a verified bordered composer.
A bare shell prompt is `unknown`, so away-mode escalation is never injected into a dead shell.

Busy state is not read from rendered text on this backend.
A task's busy, idle, unknown, or dead verdict comes from the semantic busy-state contract owned by `bin/fm-busy-lib.sh`; [architecture](architecture.md#busy-state-is-semantic-per-adapter) owns its boundaries.
The one remaining rendered-tail reader is Grok's isolated fallback inside that contract, which can only classify a Grok task.
The submit acknowledgement and away-mode supervisor-pane busy guard below still consult rendered output, but only to decide whether input can be delivered, never to decide recorded task state.
The supervisor guard selects only the detected primary harness's signature rather than a global union of vendor patterns.

`bin/fm-tmux-lib.sh` owns exact type-and-submit mechanics.
It types a message once and retries Enter only while the backend still permits another safe submission attempt.
A proven empty composer is the ordinary positive delivery acknowledgement.
Text left in established structure remains `pending`, text in ambiguous structure remains unproven, and unreadable or unsafe state remains unknown.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record plus a best-effort constant doorbell line (`bin/fm-task-inbox-lib.sh`).
For a local OMP task, the backend first validates the ready marker owner against the pane foreground process and canonical launch identity, publishes one counted request, and waits for the task extension to acknowledge one `sendMessage` steer with `triggerTurn=true`.
Coalesced process signals cannot merge those requests because the extension drains the request directory, and an absent marker, rejected identity, explicitly failed or cancelled request, or unavailable programmatic surface retains the composer doorbell fallback.
A claimed request becomes ambiguous before `sendMessage`; if acknowledgement is lost, retries remain anchored to the durable inbox and never send that possibly-delivered wake again.
The worker's handled-file move, not the doorbell transport, is the instruction-processing boundary.
Every non-OMP harness uses the composer doorbell path unchanged.
The verdicts above remain delivery-critical for the typed plane, where `fm-send.sh` preserves the fork's submit and OMP/Hermes turn-start verification.

OpenCode 1.18.4 has one busy-queue exception.
While OpenCode is mid-turn, Enter queues the message but leaves its text visible until the turn completes.
After the normal retry budget, only structurally proven pending text in a provably busy pane is accepted as queued, while an idle pane remains `pending` as a genuine swallowed Enter.
Ambiguous pending text never receives the busy-queue conversion.

OMP has one narrower exception, scoped to `harness=omp` alone.
The submit core records whether the pane is busy before typing.
For an already-busy worker, one successfully transported Enter followed by structurally proven pending or empty OMP input returns `queued-unconfirmed` without scraping the rendered steering queue; `fm-send` accepts only that narrow verdict as queued delivery.
An Enter transport failure returns `send-failed`, while an initially idle pane with editable input left pending still fails closed.
For an initially idle OMP pane, an `unknown` composer followed by the exact OMP busy signature remains positive proof that the ordinary turn started.
Every other harness keeps the original behavior of returning `unknown` immediately without further Enter retries.
`tests/fm-tmux-submit-busy.test.sh` covers busy and idle panes with proven, ambiguous, and cleared composers, plus queued OMP delivery, Enter transport failure, malformed captures, and the non-OMP unknown case.

## Limits and regression entry points

- tmux is the reference path and supports secondmate homes.

```sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#tmux) records the active foreground-process and submit evidence.
