# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
The backend guides own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.

## tmux

Foreground-process behavior was verified on 2026-07-07 with tmux 3.6a on macOS.

```sh
tmux new-session -d -s fmtest -n testwin
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin 'sleep 30' Enter
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin C-c
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
```

Observed output:

```text
zsh
sleep
zsh
```

A persistent parent shell waiting for a child remained reported as the parent process, while a shell that directly execed a simple command changed identity with the process itself.
Pi and pi-signed 0.82.0 were reverified on 2026-07-27 through real isolated `fm-spawn.sh` launches.

### Agent liveness name sources

The earlier record that every harness is observed under its own `#{pane_current_command}` no longer holds and has been replaced by the per-harness evidence below.
In this macOS run that reading reflected a rewritable process title rather than stable executable identity, so it is now one of two independent name sources rather than the sole basis of a verdict.

All seven verified adapters were relaunched on 2026-08-03 with tmux 3.6a on macOS 26.5.2 arm64, each on a private socket in an isolated lab.

```sh
tmux -L "$socket" new-window -d -t "$session:" -n "$harness" -c "$wt" -- "$bin"
tmux -L "$socket" display-message -p -t "$session:$harness" '#{pane_current_command}'
ps -t "${tty#/dev/}" -o pgid=,tpgid=,comm=      # rows where pgid = tpgid
```

Observed identities, and the resulting verdict:

| Harness | Version | `#{pane_current_command}` | Foreground `comm` | Verdict |
| --- | --- | --- | --- | --- |
| claude | 2.1.220 | `2.1.220` | `claude` | alive |
| codex | codex-cli 0.146.0 | `codex` | `codex` | alive |
| opencode | 1.18.11 | `opencode` | `opencode` | alive |
| pi | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| pi-signed | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| grok | 0.2.118 | `grok-0.2.118-ma` | `grok` | alive |
| kimi | 0.31.1 | `kimi` | `kimi` | alive |

Claude Code is the harness whose title no longer attributes it at all; every other adapter is currently attributed by both sources.
Codex reported `codex-aarch64-a` at 0.145.0 and `codex` at 0.146.0, and Kimi Code reported `kimi-code` as its foreground `comm` at 0.29.1 and `kimi` at 0.31.1, so these identities move between ordinary patch releases in both directions.
That is the evidence for treating any single process name as a surface under vendor control rather than a stable contract.

`#{pane_current_command}` and foreground `ps -o comm=` read different name fields, but which one preserves executable identity is platform-dependent.
On macOS the pane command reflected the rewritable title while the full install path could survive in `ps -o comm=`; in the Linux portable regression those roles reversed for the version-named native executable, with the identifying path retained in argv[0].
The classifier therefore accepts a harness basename first, then an exact harness path component in the full executable path, then the same component in argv[0], without depending on which field carries it on a given platform.

The portable regression is CI-enforced, while the real-harness drift guard is opt-in under the policy in `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
Run the live guard after any harness upgrade and before trusting or refreshing the table above:

```sh
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

Bounded output from the run that produced the table:

```text
ok - harness liveness: claude 2.1.220 (Claude Code) classifies alive
# claude 2.1.220 (Claude Code): title='2.1.220' foreground=[claude ]
# checked 7 installed harness(es)
```

Installed-wrapper checks:

```sh
basename "$(command -v pi-signed)"
pi-signed --version
pi --version
```

Observed bounded output:

```text
pi-signed
0.82.0
0.82.0
```

The isolated process and endpoint checks used:

```sh
tmux display-message -p -t "$target" '#{pane_current_command}'
ps -o comm= -p "$wrapper_pid"
ps -o comm= -p "$engine_pid"
FM_HOME="$fixture_home" bin/fm-crew-state.sh "$task_id"
```

Observed bounded shapes:

```text
pi-launcher
.../pi-signed
.../Pi Launcher.app/Contents/Resources/pi/pi
state: done ...
```

Both launches executed a submitted tool instruction and touched the generated `turn_end` marker.
The pi-signed launch retained `harness=pi-signed`, while the plain comparison retained `harness=pi`.
The exact wrapper ancestry was `pi-signed` parent to Pi engine child, and the plain Pi Launcher path also traversed the signed wrapper on this installation.
That shared plain-Pi path is retained as disconfirming evidence against using ancestry as runtime-selection authority.
Firstmate therefore sets the exact `FM_PI_HARNESS` selection marker on both worker launch paths, while an unmarked Pi-family process remains `pi`.
Both recorded runtime identities now classify the exact `pi-launcher` foreground command as `alive`.

### Hermes crewmate mechanics

Hermes Agent v0.20.0 was verified on 2026-08-25 against `gpt-5.6-sol` through the OpenAI Codex provider.
The tmux E2E used a private `TMUX_TMPDIR`, a temporary mode-700 `HERMES_HOME`, a temporary Firstmate home, and disposable git worktrees.
The Herdr E2E used only the guarded `fm-herdr-lab.sh` interface and the named session `fm-lab-hermes-tui-adapt-1672570-30455`.
The lab helper's before-and-after tripwire preserved the running `default` session, and the pre-existing stray `default:w80:p2` pane was never addressed.

```sh
FM_HERMES_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-hermes-live-e2e.test.sh

FM_HOME="$FM_LIVE_HOME" HERMES_HOME="$PROFILE" \
  bin/fm-spawn.sh hermes-live-worker "$PROJECT" \
  --harness hermes --backend tmux --model gpt-5.6-sol --effort low \
  --mode local-only --yolo off

FM_HOME="$FM_LIVE_HOME" HERMES_HOME="$PROFILE" \
  bin/fm-send.sh hermes-live-worker \
  'Use terminal_tool to run sleep 5, then reply exactly HERMES-TUI-STEER-OK.'

FM_HOME="$FM_LIVE_HOME" HERMES_HOME="$PROFILE" \
  bin/fm-send.sh hermes-live-worker /fmnative

FM_HOME="$FM_LIVE_HOME" HERMES_HOME="$PROFILE" \
  bin/fm-send.sh hermes-live-worker --key C-c

FM_HOME="$FM_LIVE_HOME" HERMES_HOME="$PROFILE" \
  bin/fm-send.sh hermes-live-worker /exit
```

Observed bounded output:

```text
command: fm-spawn hermes-live-worker --harness hermes --backend tmux --model gpt-5.6-sol --effort low
output: persistent=yes session=20260825_022814_bd8c33 turn_end=touched busy=idle hermes-hook
command: fm-send hermes-live-worker "Use terminal_tool to run sleep 5 ..."
output: submit=verified busy=busy hermes-hook idle=idle hermes-hook turn_end=touched
command: fm-send hermes-live-worker /fmnative
output: native_skill=/fmnative send=0 busy=busy hermes-hook idle=idle hermes-hook turn_end=touched
command: fm-send hermes-live-worker "sleep 20"; fm-send hermes-live-worker --key C-c
output: interrupt=C-c state=idle fm-interrupt turn_end=touched
command: fm-send hermes-live-worker /exit
output: exit=0 foreground=shell
command: fm-spawn hermes-live-worker ... --resume 20260825_022814_bd8c33 (from task state)
output: same_session=yes context=HERMES-TUI-RESUME-825
command: fm-spawn hermes-live-scout --scout --harness hermes --backend tmux
output: scout_persistent=yes turn_end=touched
ok - Hermes Agent v0.20.0 (2026.8.3) persistent Hermes TUI: crew/scout launch, composer steer, native skill turn, busy->idle, turn-end, interrupt, exit, and exact-session resume
```

The persistent-TUI and lifecycle facts remain current, while the ordinary-text transport shown in this dated transcript was superseded by the local steering inbox; [Local steering inbox](#local-steering-inbox) below owns the current general live record-to-ack proof, `tests/fm-hermes-harness.test.sh` covers Hermes routing deterministically, and the native skill remains the typed-composer proof.
The live busy surface had two independent positive signals: `Ctrl+C to interrupt…` in the composer and the status rule's `· <elapsed>` segment.
The structural `─ ready │` rule proved idle after both normal completion and interruption.
Those two rendered signals are what the missing-record fallback reads; they are not what the transcript above sampled. A valid trusted lifecycle record decides classification in both directions, and the rendered tail is captured only after the record read finds no valid record, so every sample above - taken once the bridge had already published a record - reports `hermes-hook` in both states. That ordering is what keeps a lagging busy redraw from letting `--key C-c` reach an already-idle TUI and exit it, and it is why no `hermes-tui` verdict appears in a record-backed sample.
A native profile skill (`$HERMES_HOME/skills/fmnative/SKILL.md`, typed as the bare `/fmnative`) started a real model turn: `fm-send` exited 0 on its `pre_llm_call` turn-start proof, the busy surface appeared, the turn-end marker fired, and the model spoke the skill's token.
That is the fail-closed contract holding for the native branch - a slash command that Hermes handled locally instead would have produced a `delivered-no-turn` failure rather than success.
The `firstmate-lifecycle` profile plugin forwarded `on_session_start`, `pre_llm_call`, and `on_session_end` from the TUI gateway worker into the guarded shell handler, which captured the exact durable session and touched every turn-end marker.
Direct config shell hooks were disconfirming evidence for the TUI path: v0.20.0 logged them as registered in the wrapper process but did not invoke them from gateway turns.
The CLI `--reasoning low` value was also disconfirming by itself because v0.20.0's Python TUI launcher dropped it and initially rendered the profile's `high` value.
The session-scoped `/reasoning low` setup command changed the live footer to `gpt 5.6 sol low` without changing the global reasoning setting.
That local slash command does not start an agent turn, so its launch-time submission uses structural composer clearing instead of Herdr's ordinary working-state proof.
The tmux probe also proved that Hermes' busy placeholder must classify as empty composer content, because a false pending verdict sends a second empty Enter and Hermes interprets the double Enter as an interrupt.
The named Herdr lab ran once on 2026-08-25 under the earlier classification ordering and has not been rerun; its verdicts are recorded here as captured. It independently produced `spawned ... window=fm-lab-hermes-tui-adapt-1672570-30455:w1:p6`, `busy hermes-tui`, `idle hermes-tui` (both rendered verdicts predate the record-first precedence change - under the shipped ordering the same samples report `hermes-hook`, as the rerun tmux transcript above shows), `HERMES-HERDR-STEER-OK`, an `interrupted` transcript line after `C-c`, `HERDR-RESUME-825` after relaunch on `w1:p7`, and `HERMES-HERDR-SCOUT-OK` on `w1:p9`.
The Herdr `/exit` path required a bounded process-exit wait because the TUI can spend tens of seconds shutting down MCP and child resources after the slash command clears its composer.

### Hermes task-owned process teardown

Hermes Agent v0.20.0 and Herdr 0.7.3 were verified on 2026-08-25 against the ownership selector at head `aa25fee3`.
Both probes ran from the no-mistakes gate worktree at that exact head, so the results below are the selector as it merges.
The commits after that head touch only documentation, tests, code comments, and two added stderr lines on the unproven-ownership warning path, so the ownership selector this record proves is unchanged.
The tmux verification used the live adapter test's private Hermes profile and tmux server, and tore down an active scout whose persistent TUI was still running.
The Herdr verification used only `fm-herdr-lab.sh` for session lifecycle, with the generated non-default session `fm-lab-fm-hermes-final-3715267-15309`.
The Herdr probe set the test-only `FM_GATE_REFUSE_BYPASS=1` because the code under test ran from the gate worktree.
The default Herdr session remained running with the same fleet identity before and after the probe.

```sh
FM_HERMES_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-hermes-live-e2e.test.sh

HERDR_LAB_HELPER=/home/dnth/Desktop/firstmate/bin/fm-herdr-lab.sh
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-hermes-final)
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID \
  -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$FM_LIVE_HOME" HERMES_HOME="$PROFILE" \
  bin/fm-spawn.sh hermes-herdr-final-live "$PROJECT" \
  --harness hermes --backend herdr --model gpt-5.6-sol --effort low \
  --mode local-only --yolo off

env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID \
  -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$FM_LIVE_HOME" HERMES_HOME="$PROFILE" \
  bin/fm-teardown.sh hermes-herdr-final-live --force
```

Observed bounded output:

```text
tmux:
output: marker_scan_selfcheck=ok unreadable_procfs_fallthrough=ps
command: fm-teardown hermes-live-scout (persistent TUI still running, no /exit)
teardown: reaping leaked worktree process(es) for hermes-live-scout: 3589231 3589232 3590357 3590605 3590652 3591036 3591038 3591040 3591042 3591044 3591046 3591047 3591051 3591210 3591250 3591297 3591412 3591558 3591566 3591568 3591571 3591572 3591595 3591600 3591613 3591638 3591639
output: active_teardown=yes pane_root=3588600 owned_before=3588600 3588977 3589231 3589232 3590357 3590605 3590652 3591036 3591038 3591040 3591042 3591044 3591046 3591047 3591051 3591210 3591250 3591297 3591412 3591558 3591566 3591568 3591571 3591572 3591595 3591600 3591613 3591638 3591639 tracked_survivors=0 survivors=0
ok - Hermes Agent v0.20.0 (2026.8.3) persistent Hermes TUI: crew/scout launch, composer steer, native skill turn, busy->idle, turn-end, interrupt, exit, and exact-session resume
output: cleanup_owned_processes=0 cleanup_temp_dirs=0
FM_TEST_END ... exit=0 duration_ms=161567

Herdr:
spawned hermes-herdr-final-live ... window=fm-lab-fm-hermes-final-3715267-15309:w1:p2
output: active=yes marker_roots=3729447 3729989 3730043 3730100 3730101 owned_count=25 roles=MainThread,bun,chrome,git,git-remote-http,hermes,hound,python,python3,tradingview-mcp,uv
teardown: reaping leaked worktree process(es) for hermes-herdr-final-live: 3726376 3726377 3729447 3729989 3730043 3730100 3730101 3731196 3731198 3731201 3731204 3731220 3731221 3731223 3731227 3731505 3731549 3731744 3731941 3732033 3732042 3732044 3732047 3732048 3732071 3732076 3732117 3732141 3732142
output: captured_survivors=0 marker_survivors=0 personal_unchanged=4
output: session_state={"lab":[],"default":[{"name":"default","running":true}]}
ok - final-head guarded Herdr active teardown removed only the captured task tree
```

Both probes tore down a live persistent tree: neither sent `/exit` first, so the Python launcher, the Node `ui-tui` child, the gateway, the detached MCP watchdog and server branches, and their descendants were all running when teardown was invoked.
The owner set was derived from the exact `FM_HERMES_TASK_TOKEN` recorded in task metadata, expanded through the kernel parent tree from those token roots, and unioned with the flat set of processes whose cwd is the task worktree, before any signal was sent.
One teardown invocation removed every task-owned process on both backends without a `REFUSED` retry.
The tmux survivor proof is independent of that selector: it pins the birth identity of the pane-rooted tree while it is still intact and requires every captured identity to be gone the moment the single teardown invocation returns, with no settle window.
The Herdr probe reported `captured_survivors=0` and `marker_survivors=0` on the same immediate basis.
Four unrelated personal Hermes processes retained the same kernel start identity across the Herdr probe, proving the shared personal profile was never used as a kill selector.
The default Herdr session was still running with an unchanged fleet identity after the lab session was torn down, which is the tripwire for lab isolation.
The live tmux test's EXIT, INT, and TERM cleanup trap independently reaps the isolated profile and temp-root ownership set, then asserts zero owned processes and zero `/tmp/fm-hermes-live-e2e.*` directories before returning on both success and failure.
An explicit `Ctrl+C` during an earlier run on the same day returned 130 only after that same zero-process and zero-directory assertion printed, which proves the interrupt path rather than inferring it from the normal EXIT path.
The full personal MCP configuration produced 25 task-owned processes in the Herdr probe.
A smaller crew-specific MCP profile remains a follow-up because no supported isolated tool configuration was verified, and changing the captain's profile or silently removing crew tools is outside this fix.

### OMP lifecycle

The complete tmux role matrix reran on 2026-07-31 against OMP 17.1.8 using separate private tmux sockets, temporary homes, and disposable git worktrees:
The ordinary-text steering transport described in the dated OMP role-matrix records below was superseded by the local steering inbox; [Local steering inbox](#local-steering-inbox) owns the current record-to-ack proof, while slash commands, keys, explicit targets, and remote secondmates retain the typed transport those records exercise.

```sh
omp --version
FM_OMP_PRIMARY_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh
FM_OMP_TMUX_LIVE_E2E=1 tests/fm-omp-worker-tmux-live-e2e.test.sh
FM_OMP_SECONDMATE_LIVE_E2E=1 tests/fm-omp-secondmate-live-e2e.test.sh
```

Observed bounded output:

```text
omp/17.1.8
ok - OMP omp/17.1.8 primary E2E proved fresh no-state and ordinary native discovery, exact ownership, once-only startup, guarded watcher startup, /new continuity, shutdown, resume, and away-mode delivery
ok - real tmux OMP worker/scout lifecycle: launch, exact identity, worker and scout idle/busy steering, interrupt, skill, exit, and resume
ok - real isolated tmux OMP secondmate launch, idle health, marked replies, exit, same-session resume, context, and duplicate refusal
```

The runs retained exact `harness=omp`, forwarded the selected model and thinking level, delivered each initial instruction once, and used `/skill:<name>` for the real skill turn.
Normal `/exit` stopped each OMP process without killing the private tmux server, exact session resume restored prior context, and cleanup removed every generated extension, session, task temp root, worktree, and socket-owned endpoint.
The guarded primary, worker/scout, and secondmate owners reran on 2026-08-01 at head `491bc809a38a84f5ea651fd051b509cb511149a1` and returned four green results.
The OMP 17.2.10 watcher-input regression passed on 2026-08-07 with the editable draft intact; the exact command and bounded output are recorded in [`supervision.md`](supervision.md#native-session-start-delivery).

The OMP max-time deadline guard passed on 2026-08-17 against OMP 17.3.4 using `openai-codex/gpt-5.6-sol` as the explicit live-test model; the current fixture default is `openai-codex/gpt-5.6-luna`:

```sh
omp --version
FM_OMP_MAX_TIME_LIVE_E2E=1 tests/fm-omp-max-time-live-e2e.test.sh
```

Observed bounded output:

```text
omp/17.3.4
evidence: OMP omp/17.3.4 max-time=5 elapsed=6s stopReason=aborted errorMessage=Deadline exceeded
ok - OMP omp/17.3.4 aborts an active session within the 5-15s deadline bound
```

The guard starts a real headless OMP turn with `--max-time=5`, requires the deadline-specific aborted assistant event and terminal runtime event, rejects unrelated errors, and measures the full process lifetime including shutdown against the documented bound.

OMP 17.3.8 standalone-executable compatibility was verified on 2026-08-20.

```sh
omp --version
bin/fm-omp-capabilities.sh --require-max-time --print-binary
FM_OMP_PRIMARY_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh
```

Observed relevant output:

```text
omp/17.3.8
ok - OMP omp/17.3.8 primary E2E proved fresh no-state and ordinary native discovery, exact ownership, once-only startup, guarded watcher startup, /new continuity, shutdown, resume, and away-mode delivery
ok - OMP omp/17.3.8 primary E2E proved watcher delivery with an intact editable draft
```

The capability probe returned the canonical selected executable path, which is omitted here because it is host-local.
The installed OMP was a Bun-compiled executable whose embedded `argv[1]` was not a filesystem object.
The live primary check loaded the tracked extension in an ordinary disposable Firstmate checkout, required the four-line marker to bind both runtime and entrypoint identities to the compiled executable, and then proved PID ownership, startup, watcher, restart, shutdown, resume, and away-delivery behavior.

The native Prewalk launch surface was checked on 2026-08-11 against OMP 17.2.11 without starting a model call:

```sh
omp --version
omp --prewalk --prewalk-into=openai-codex/gpt-5.6-luna:xhigh --help
omp models openai-codex --json | jq -r '.models[] | select(.selector == "openai-codex/gpt-5.6-luna") | [.selector, (.thinking | join(","))] | @tsv'
```

Observed relevant output:

```text
omp/17.2.11
      --prewalk                       Switch from the active model to a fast/cheap model at the first edit/write after the plan's todo list exists (default off; see prewalk.enabled)
      --prewalk-into=<value>          Target model for prewalk (default the "smol" role)
openai-codex/gpt-5.6-luna	low,medium,high,xhigh,max
```

The zero-exit help parse confirms that the CLI accepts the `:xhigh` effort suffix on the Prewalk target, while the model catalog independently confirms that GPT-5.6 Luna supports xhigh.
This evidence covers launch parsing and catalog validation only; it does not claim a live model handoff.
### OMP project-extension discovery

The project-extension launch surface was verified on 2026-08-12 against OMP 17.2.11.
The CLI identifies `--extension` as an explicit extension-file load and separately enables extension discovery unless `--no-extensions` is passed.
The installed source resolves project extension directories and project settings roots from the launch cwd, follows top-level extension-directory symlinks, and discovers supported non-hidden top-level files, one-level index entries, and declared extension manifests.
The source also resolves profile-scoped extensions from the OMP home, which is a separate surface from the project worktree.

```sh
omp --version
omp --help
OMP_PACKAGE=$(cd "$(dirname "$(readlink -f "$(command -v omp)")")/.." && pwd -P)
rg -n 'Direct files:|Subdirectory with index:|Subdirectory with package.json:|symlinked extension' "$OMP_PACKAGE/src/discovery/helpers.ts"
rg -n 'const result = await glob.*hidden: false' "$OMP_PACKAGE/src/discovery/helpers.ts"
rg -n 'Project `<cwd>/.omp/settings.json#extensions`|if \(!Array.isArray\(raw\)\)|return raw.filter' "$OMP_PACKAGE/src/discovery/omp-extension-roots.ts"
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-omp-secondmate.test.sh
```

Observed bounded output:

```text
omp/17.2.11
--extension=<value>             Load an extension file (can be used multiple times)
--no-extensions                 Disable extension discovery (explicit -e paths still work)
625: * 1. Direct files: `extensions/*.ts` or `*.js` → load
626: * 2. Subdirectory with index: `extensions/<ext>/index.ts` or `index.js` → load
627: * 3. Subdirectory with package.json: `extensions/<ext>/package.json` with "omp"/"pi" field → load declared paths
640: // Detect top-level symlinked directories and synthesize the equivalent subdir matches
333:		const result = await glob({ pattern, path: dir, gitignore: true, hidden: false, fileType, recursive });
144:	if (!Array.isArray(raw)) return [];
145:	return raw.filter((entry): entry is string => typeof entry === "string" && entry.length > 0);
176: * 2. Project `<cwd>/.omp/settings.json#extensions`
ok - OMP refuses tracked project extensions without explicit opt-in
ok - OMP allows tracked project extensions only with an auditable opt-in
ok - OMP projects without tracked extensions launch unchanged
ok - non-OMP harnesses ignore tracked OMP project extensions
ok - OMP refuses tracked settings extension roots
ok - OMP refuses tracked extension-directory symlinks
ok - OMP root symlinks use the shared opt-in boundary
ok - OMP ignores hidden direct extension files
ok - OMP ignores unusable settings extension entries
ok - OMP ignores unsupported root extension manifests
ok - OMP restricts the primary adapter exemption to secondmate homes
ok - OMP secondmates trust exact primary and fleet extensions while inspecting staged code
ok - OMP secondmate launch and recovery use the isolated adapter and an exact home-owned session pointer
```

The deterministic spawn checks prove that an OMP launch refuses a git-tracked project extension without the explicit override, records the override when passed, and leaves projects without tracked extensions unchanged.
The secondmate integration checks reran on 2026-08-27 and prove that the exact Firstmate primary and fleet-hook extensions remain permitted in the persistent home without allowing modified or unrelated tracked extension code.
Live firing of the fleet hook's `tool_result`, `todo_reminder`, and `session.compacting` handlers is PENDING firstmate scratch OMP verification before merge; deterministic extension and spawn tests do not claim OMP event delivery.

The Herdr role matrix required each expected turn-end or routed-reply notification to reach the durable queue or the primary follow-up transcript before the fixture drained it.

The deterministic composer, tmux, and Herdr fixtures reran on 2026-08-26 and proved that an already-busy OMP send returns `queued-unconfirmed` only after Enter transport succeeds and the composer either clears or remains proven pending while native state is still working.
The same fixtures proved that a pending OMP composer after native state becomes idle returns `pending`, Enter transport failure returns `send-failed`, and initially idle editable input fails closed.
This is revision-bound source-fixture evidence for the source under review, using Bun 1.3.14 only for terminal-cell measurement; it does not invoke OMP or make an OMP runtime-version claim.

The deterministic fm-send turn-start fixture ran on 2026-08-19 and proved that an initially idle typed-plane OMP submit must become busy or advance its generated turn-start marker after the submit-time baseline before success, while `delivered-no-turn` exits distinctly, queues supervised recovery, and never kills the endpoint.
The same fixture proved bounded recovery wake-lock failure, required recovery-trigger persistence, distinct post-delivery persistence failure, the monotonic deadline, submit-time idle setup, Herdr post-submit check, confirmed busy and blocked compatibility, OMP exit compatibility, normal turn start, already-busy `queued-unconfirmed` exception, remote OMP routing, and unchanged non-OMP behavior.
The tested source is Git revision `6c04b02de758deb82f2448bd258b5e1b72ff0743` plus binary patch SHA-256 `cc336b6d0dd73ca74adc28d665e3a29f28e064764441bda2c9f18c6a402360a5` over this exact file manifest and construction command:

```sh
git diff --binary 6c04b02de758deb82f2448bd258b5e1b72ff0743 -- bin/fm-send.sh bin/fm-wake-lib.sh tests/fm-send-turn-start.test.sh | sha256sum
```

This evidence uses stubbed backend state and process identity only, does not invoke a live OMP runtime, and makes no live OMP claim.

```sh
tests/fm-send-turn-start.test.sh
```

Observed output:

```text
ok - fm-send: confirmed OMP delivery without a turn returns delivered-no-turn and wakes supervised recovery
ok - fm-send: marker persistence failure is distinct and never resends
ok - fm-send: wake persistence failure is distinct and never resends
ok - fm-send: unacquirable wake lock returns bounded failure
ok - fm-send: a real OMP turn start preserves normal success
ok - fm-send: delivered-no-turn never closes an answered decision
ok - fm-send: OMP session activity advancement proves a fast turn start
ok - fm-send: pre-submit activity cannot prove the submitted turn started
ok - fm-send: already-busy OMP ignores idle-only turn-start setup
ok - fm-send: turn-start verification remains scoped to OMP targets
ok - fm-send: the monotonic deadline prevents post-expiry backend probes
ok - fm-send: OMP keys ignore text-only turn-start configuration
ok - fm-send: OMP /exit ignores turn-start-only setup
ok - fm-send: remote OMP metadata routing leaves non-OMP state unchanged
ok - fm-send: Herdr empty still requires post-submit OMP turn proof
ok - fm-send: busy and blocked Herdr ignore idle-only setup
```

```sh
bash -c '
set -e
evidence_dir=$(mktemp -d)
trap "rm -rf \"$evidence_dir\"" EXIT
bun --version > "$evidence_dir/actual.out"
tests/fm-composer-lib.test.sh > "$evidence_dir/composer.out"
tests/fm-tmux-submit-busy.test.sh > "$evidence_dir/tmux.out"
tests/fm-backend-herdr.test.sh > "$evidence_dir/herdr.out"
grep -hE "^(ok - (fm_composer_queued_enter_verdict: pending \+ busy returns empty|fm_composer_queued_enter_verdict: pending \+ idle/unknown stays pending|fm_tmux_submit_enter_core: idle pane \+ pending composer stays pending|fm_tmux_submit_enter_core: busy OMP Enter transport failure|busy OMP mixed Enter transport retains queued delivery|OMP tmux composer keeps queued busy submits|fm_backend_herdr_send_text_submit: busy OMP without proof|fm_backend_herdr_send_text_submit: an OMP steer left pending|fm_backend_herdr_send_text_submit: busy OMP Enter transport failure|fm_backend_herdr_send_text_submit: non-OMP working \+ pending stays pending|fm_backend_herdr_send_text_submit: typed idle-placeholder text stays pending))" "$evidence_dir/composer.out" "$evidence_dir/tmux.out" "$evidence_dir/herdr.out" >> "$evidence_dir/actual.out"
cat > "$evidence_dir/expected.out" <<EOF
1.3.14
ok - fm_composer_queued_enter_verdict: pending + busy returns empty (queued Enter)
ok - fm_composer_queued_enter_verdict: pending + idle/unknown stays pending
ok - fm_tmux_submit_enter_core: idle pane + pending composer stays pending (genuine swallow preserved)
ok - fm_tmux_submit_enter_core: busy OMP Enter transport failure returns send-failed
ok - busy OMP mixed Enter transport retains queued delivery
ok - OMP tmux composer keeps queued busy submits separate from unsubmitted input
ok - fm_backend_herdr_send_text_submit: busy OMP without proof is queued-unconfirmed
ok - fm_backend_herdr_send_text_submit: an OMP steer left pending after the pane becomes idle is not submitted
ok - fm_backend_herdr_send_text_submit: busy OMP Enter transport failure returns send-failed
ok - fm_backend_herdr_send_text_submit: non-OMP working + pending stays pending
ok - fm_backend_herdr_send_text_submit: typed idle-placeholder text stays pending
EOF
diff -u "$evidence_dir/expected.out" "$evidence_dir/actual.out"
cat "$evidence_dir/actual.out"
'
```

Observed bounded output:

```text
1.3.14
ok - fm_composer_queued_enter_verdict: pending + busy returns empty (queued Enter)
ok - fm_composer_queued_enter_verdict: pending + idle/unknown stays pending
ok - fm_tmux_submit_enter_core: idle pane + pending composer stays pending (genuine swallow preserved)
ok - fm_tmux_submit_enter_core: busy OMP Enter transport failure returns send-failed
ok - busy OMP mixed Enter transport retains queued delivery
ok - OMP tmux composer keeps queued busy submits separate from unsubmitted input
ok - fm_backend_herdr_send_text_submit: busy OMP without proof is queued-unconfirmed
ok - fm_backend_herdr_send_text_submit: an OMP steer left pending after the pane becomes idle is not submitted
ok - fm_backend_herdr_send_text_submit: busy OMP Enter transport failure returns send-failed
ok - fm_backend_herdr_send_text_submit: non-OMP working + pending stays pending
ok - fm_backend_herdr_send_text_submit: typed idle-placeholder text stays pending
```

The full OMP contract and both live backend matrices passed together in one clean-environment runner invocation on 2026-08-01 at head `491bc809a38a84f5ea651fd051b509cb511149a1`:

```sh
env -i \
  HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" PATH="$PATH" \
  LC_ALL=C TERM=dumb SHELL=/bin/bash \
  FM_OMP_PRIMARY_LIVE_E2E=1 \
  FM_OMP_TMUX_LIVE_E2E=1 \
  FM_OMP_SECONDMATE_LIVE_E2E=1 \
  FM_OMP_HERDR_LIVE_E2E=1 \
  FM_OMP_HERDR_EXIT_LIVE_E2E=1 \
  HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  bin/fm-test-run.sh \
    tests/fm-omp-harness.test.sh \
    tests/fm-pi-compatible-family.test.sh \
    tests/fm-omp-primary.test.sh \
    tests/fm-omp-secondmate.test.sh \
    tests/fm-backend-herdr.test.sh \
    tests/fm-spawn-dispatch-profile.test.sh \
    tests/fm-tmux-submit-busy.test.sh \
    tests/fm-bootstrap.test.sh \
    tests/fm-secondmate-liveness.test.sh \
    tests/fm-session-start.test.sh \
    tests/fm-send-strict.test.sh \
    tests/fm-fleet-snapshot-view.test.sh \
    tests/fm-omp-primary-live-e2e.test.sh \
    tests/fm-omp-worker-tmux-live-e2e.test.sh \
    tests/fm-omp-secondmate-live-e2e.test.sh \
    tests/fm-omp-herdr-live-e2e.test.sh \
    tests/fm-omp-herdr-exit-live-e2e.test.sh
```

Starting from `env -i` left `FM_BUSY_REGEX` unset.
Bounded output, from the run's first marker through the two Herdr live owners and the final summary:

```text
FM_TEST_BEGIN 2026-08-01T18:58:08Z tests/fm-omp-harness.test.sh family=pure-contract-unit expected_gate_skip=none
...
FM_TEST_BEGIN 2026-08-01T19:10:19Z tests/fm-omp-herdr-live-e2e.test.sh family=live-harness-optin expected_gate_skip=optin-env
ok - real Herdr OMP role matrix: primary, worker/scout idle and busy steering, blocked escalation, secondmate, normal exits, recovery, duplicate refusal, and guarded teardown
FM_TEST_END 2026-08-01T19:22:14Z tests/fm-omp-herdr-live-e2e.test.sh exit=0 duration_ms=715155 gate_skip=false
FM_TEST_BEGIN 2026-08-01T19:22:14Z tests/fm-omp-herdr-exit-live-e2e.test.sh family=live-harness-optin expected_gate_skip=optin-env
warning: herdr task kill could not acquire its session presentation lock; refusing an unlocked pane close
ok - real Herdr OMP /exit: exact native identity, post-offset normal session_exit, pane absence, and guarded tripwire teardown
FM_TEST_END 2026-08-01T19:22:26Z tests/fm-omp-herdr-exit-live-e2e.test.sh exit=0 duration_ms=12188 gate_skip=false
FM_TEST_SUMMARY total=17 failed=0 skipped_gate=0 duration_ms=1458352
FM_TEST_SUMMARY_FAMILY family=backend-dispatch count=3 duration_ms=391929 failed=0
FM_TEST_SUMMARY_FAMILY family=live-harness-optin count=4 duration_ms=861547 failed=0
FM_TEST_SUMMARY_FAMILY family=pure-contract-unit count=3 duration_ms=2106 failed=0
FM_TEST_SUMMARY_FAMILY family=secondmate count=2 duration_ms=41536 failed=0
FM_TEST_SUMMARY_FAMILY family=session-bootstrap count=2 duration_ms=41944 failed=0
FM_TEST_SUMMARY_FAMILY family=snapshot-bearings count=1 duration_ms=21763 failed=0
FM_TEST_SUMMARY_FAMILY family=watcher-wake-lock count=2 duration_ms=97033 failed=0
```

Every listed script ran at that head with no gate skip.
The isolated Herdr role matrix emitted no queued-wake warning.
The final run retained the fresh-beacon, pending-notification, queue-drain, and bounded-delivery assertions in the Herdr fixture.
The focused OMP adapter contract now delivers watcher wakes as a custom steer with `triggerTurn`, preserving the editable draft while retaining idle wake and streaming delivery.
The tmux role fixtures emitted their expected task-copy worktree and missing-fixture-watcher notices.
The Herdr exit fixture refused an unlocked presentation close after proving normal process exit, then completed its named guarded teardown.

Backend applicability was reviewed across every spawn adapter.
Tmux needs the exact `pi-launcher`, `pi-signed`, `pi`, and `Pi` process identities for recovery-grade liveness.
Herdr uses native registered-agent state and needs no process-name branch.
Zellij has no verified recovery-grade agent process probe, while Orca and cmux do not support secondmate spawns, so those three retain their existing generic ordinary-launch semantics without a new liveness matcher.

### Guarded Treehouse entry

The Treehouse-backed ordinary acquisition integration was inspected on 2026-08-12 against the pinned Treehouse v2.1.1 contract.
Tmux, Zellij, and cmux submit the shared guarded acquisition command, then resolve the acquired worktree through their existing current-path adapter only after the wrapper enters its verified lease.
Herdr now uses the acquisition-owned ready-file handoff described in [`herdr-backend.md`](../herdr-backend.md#watching-and-task-containers), with portable coverage in `tests/fm-spawn-dispatch-profile.test.sh` and real-Herdr coverage in `tests/fm-backend-herdr-presentation-e2e.test.sh`.
Orca is not applicable because it owns task worktrees and never invokes Treehouse.

The command and output below preserve the original 2026-08-12 cross-adapter inspection as dated evidence that each adapter exposed a current-path primitive; the Herdr line no longer describes its allocation-authority path.

```sh
for backend in tmux herdr zellij cmux; do grep -q "fm_backend_${backend}_current_path" "bin/backends/$backend.sh" && printf '%s current-path adapter present\n' "$backend"; done
bash tests/fm-spawn-pool-base-freshen.test.sh
```

Bounded output:

```text
tmux current-path adapter present
herdr current-path adapter present
zellij current-path adapter present
cmux current-path adapter present
ok - spawn guards Treehouse reset before non-ancestor acquisition
# all fm-spawn-pool-base-freshen tests passed
```

The structural multi-row composer reader, Kimi pointer-delivery path, and OpenCode 1.18.4 busy-queue behavior are pinned by:

```sh
tests/fm-composer-ghost.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
```

Expected structural matrix: real text on any content row is pending; all-empty complete boxes are empty; unreadable, incomplete, or unsafe boxes are unknown; and non-bordered panes retain cursor-row compatibility.
Expected submit matrix: proven pending plus busy is accepted as queued; proven pending plus idle remains pending; ambiguous pending is never converted by the busy exception; and only a proven empty composer succeeds directly.

### Cleanup endpoint identity

The cleanup identity boundary was validated on 2026-07-28 with tmux 3.6a and metadata fixtures for every supported backend.

```sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-teardown.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-backend-zellij.test.sh
tests/fm-backend-orca.test.sh
tests/fm-backend-cmux.test.sh
```

Bounded output from the incident regression:

```text
ok - fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call
ok - cleanup identity: valid tmux, Herdr, Zellij, Orca, and cmux records validate while every empty backend target refuses
ok - tmux backend: direct empty target returns nonzero without invoking tmux
ok - process cleanup: creation-time PID identity removes only the exact child and preserves the control child
ok - fm-teardown: dedicated-socket invalid cleanup preserves target/control and valid cleanup removes only the exact target
```

The dedicated tmux cell removed ambient tmux variables, required a socket-bound wrapper, kept one target and one independent control window, and proved the wrapper was not called for invalid metadata or a direct empty target.
Valid cleanup removed only the exact task-bound target and left the control window live.
The metadata-only validation covers tmux, Herdr, Zellij, Orca, and cmux before backend dispatch.
Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, and the crewmate-only Hermes adapter share that backend cleanup boundary; their harness-specific hook files and token cleanup run only after it, so no harness needs a separate endpoint parser.

### OMP supervision branch

The OMP supervision-branch concurrency and delivery contract (docs/omp-supervision-branch.md) was verified on 2026-08-27 against @oh-my-pi/pi-coding-agent 17.3.4.
It drives the tracked extension behind a mocked ExtensionAPI host while branch-session creation uses the real createAgentSession and SessionManager SDK surfaces.

```sh
FM_OMP_BRANCH_LIVE_E2E=1 tests/fm-omp-branch-live-e2e.test.sh
```

Observed bounded output:

```text
ok - a broken branch degrades to wake-to-main with no lost wake (real SDK)
ok - a resident, re-promptable second session handles a wake without leaking into MAIN (real SDK)
ok - a captain-worthy wake opens exactly one follow-up turn on MAIN (real SDK)
ok - OMP supervision branch live guard passed against @oh-my-pi/pi-coding-agent 17.3.4
```

The guard proves a broken branch (an unresolvable model pin) falls the wake back to main through the primary adapter's watcher-wake steer with triggerTurn, not sendUserMessage, leaving the wake queue durable.
It proves a resident second AgentSession is created and remains re-promptable on a later wake without its turn output reaching main or replacing main's terminal resume breadcrumb, and that a routine verdict opens no new main turn while a captain verdict opens exactly one follow-up turn.
The captain sub-check is skipped, not passed, on a run where the model judges the captain-worthy fixture routine.

The branch session is built with the native prompt-cache options providerPromptCacheKey and providerPromptCacheKeySource "explicit"; the belt-and-suspenders before_provider_request rewrite hook is retained but inert under OMP, whose extension-facing provider payload carries no prompt_cache_key field.
The committed live guard does not observe server-side cache-read token counts, which OMP does not expose to the extension surface, so no cache-hit-rate claim is made here.

Mid-flight branch replacement, model/effort hot-swap, and hung-branch live takeover are deliberately out of scope for this port (docs/omp-supervision-branch.md), so the guard exercises only the shipped surface: a resident branch with clean-boundary and kill-restart transitions.

## Herdr

The compatibility floor is protocol 14.
The presentation-projection suite's latest active verification uses Herdr 0.8.0 protocol 19 on macOS aarch64, every other section's latest uses Herdr 0.7.5 protocol 17 on macOS aarch64, and earlier 0.7.5 protocol-16, 0.7.4, protocol-14, and 0.7.3 evidence is retained where it defines current behavior or fallbacks.
Protocol 17 keeps every protocol-16 feature gate satisfied; the event and workspace-move floors remain 16.

Core read-only probes:

```sh
herdr --version
herdr status --json | jq -c '{client:.client.protocol,server:.server.protocol}'
herdr api schema --json | jq -c '.schemas.subscription_event["$defs"].SubscriptionEventKind.enum'
```

Observed retained protocol-16 compatibility shapes from the macOS aarch64 projection run:

```text
herdr 0.7.5
{"client":17,"server":17}
["pane.output_matched","pane.agent_status_changed","pane.scroll_changed"]
```

The CLI matrix was checked directly:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Explicit session routing | `herdr <verb> ... --session <name>` | Reached the named session even while another server was running. |
| Literal send | `herdr pane send-text <pane> <text> --session <name>` | Left text unsubmitted until Enter. |
| Keys | `herdr pane send-keys <pane> enter|escape|ctrl+c --session <name>` | Enter and Escape worked; Ctrl-C interrupted foreground work. |
| Capture | `herdr pane read <pane> --source recent --lines N` | Small N could return empty below viewport height; a 200-line request plus local trim was stable. |
| Native state | `herdr agent get <pane>` | Working and done transitions were visible; native `busy` remains positive activity evidence, while native `idle` cannot close a turn and the adapter's semantic lifecycle decides worker state. |
| Restart | guarded named-session stop then start | Workspace, tab, pane, and labels persisted; the agent process and registration did not. |
| Close | `herdr pane close <pane> --session <name>` | The exact one-pane task tab closed; closing a final tab could remove the workspace. |

All destructive verification used `bin/fm-herdr-lab.sh` with a non-default `fm-lab-` name and a byte-identical default-session tripwire.
No ambient `herdr server stop` command is a supported test operation.

### Prune and respawn

The real label-collision reproduction is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-prune-safety-e2e.test.sh
```

Observed guarantee: a pre-existing captain-owned workspace with a seed-shaped tab was adopted for routing but its tab was never eligible for prune because the current create call did not return that seed id.

Restart-husk replacement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-respawn-idem-e2e.test.sh
```

Observed guarantee: a restored no-agent tab was replaced create-before-close, while a registered live agent caused refusal.

### Launcher workspace placement

Herdr exports its pane identity into every process it manages, checked on 2026-07-30 against Herdr 0.7.5 protocol 17 inside a guarded lab pane:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh
"$HERDR_LAB_HELPER" run "$LAB" pane run "$PANE" "sh -c 'env | grep ^HERDR | sort > /tmp/env.txt'"
```

```text
HERDR_ENV=1
HERDR_PANE_ID=w1:p1
HERDR_SESSION=fm-lab-fm-herdr-env-pro-65961-25535
HERDR_SOCKET_PATH=/Users/kunchen/.config/herdr/sessions/fm-lab-fm-herdr-env-pro-65961-25535/herdr.sock
HERDR_TAB_ID=w1:t1
HERDR_WORKSPACE_ID=w1
```

This complete injection shape is verified only for Herdr 0.7.5.
Firstmate requires both `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` before accepting claimed launcher ancestry.

`pane get` reports the pane's current owning tab and workspace, which is what placement resolves from; the injected `HERDR_TAB_ID` and `HERDR_WORKSPACE_ID` are creation-time snapshots and are not read as current identity:

```sh
"$HERDR_LAB_HELPER" run "$LAB" pane get w1:p1 | jq -c '.result.pane | {pane_id,tab_id,workspace_id}'
```

```text
{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}
```

Placement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
```

Observed guarantees on 2026-07-30 against Herdr 0.7.5 protocol 17:

```text
ok - real herdr E2E: with one 'firstmate' workspace and no herdr parent, a crewmate still lands in this home's own workspace without stealing focus
ok - real herdr E2E: the normal unique-label path is unchanged when the launcher's own pane identifies the workspace
ok - real herdr E2E: presentation spaces still create the isolated child workspace and bind it under the launcher's exact parent, without stealing focus
ok - real herdr E2E: with two 'firstmate' workspaces, a worker spawned from inside the second one lands in that exact workspace
ok - real herdr E2E: the duplicate-labeled sibling workspace is left entirely untouched and focus is preserved
ok - real herdr E2E: with a duplicated home label, a projected worker still hangs off the launcher's exact workspace and the sibling stays untouched
ok - real herdr E2E: an ambiguous home label with no launcher identity refuses before any worker endpoint exists
ok - real herdr E2E: a launcher pane that no longer exists refuses before any worker endpoint exists
ok - real herdr E2E: a secondmate launching its own worker gets the same exact-workspace guarantee, and its same-labeled sibling is untouched
ok - real herdr E2E: a --secondmate launch still stands up that secondmate's own workspace instead of inheriting the launcher's
ok - real herdr E2E: teardown closes only the worker's own pane and leaves the launcher, its workspace, and the same-labeled sibling intact
```

That suite's headline case runs `bin/fm-spawn.sh` inside a real Herdr pane, so the parent identity comes from Herdr's own injection rather than a composed environment.
Cross-session and contradictory bindings are covered deterministically in `tests/fm-backend-herdr.test.sh`, which can script a second server's socket without provisioning one.

### Per-home and presentation topology

Per-home behavior is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
```

Observed guarantee: the primary and secondmate used distinct home workspaces, a child launched by the secondmate stayed in that secondmate workspace, list-live remained home-scoped, and exact cleanup did not affect sibling homes.

The complete projection suite ran on 2026-07-21 against Herdr 0.7.4 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed guarantees included:

```text
ok - real Herdr lab: primary and two secondmate homes each own a top-level contiguous child block
ok - real Herdr lab: concurrent primary/A/B spawns stay session-locked with zero focus drift
ok - real Herdr lab: session lock contention from a secondmate home falls back flat with no journal
ok - real Herdr lab: legacy projection labels and flat secondmate tabs are left unmigrated
ok - real Herdr lab: multi-home exact-pane teardowns restore captain focus without workspace close authority
ok - real Herdr lab validation completed on Herdr 0.7.4 with the default-session tripwire intact
```

The suite also covers lost or failed move responses, active-tab refusal, restart husks, missing and duplicate tokens, manual renames, concurrent cleanup, and exact focus restoration.

The mandatory projection suite ran again on 2026-07-24 against Herdr 0.7.5 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed restart-reclaim guarantees:

```text
ok - real Herdr lab: Hi Bit and Wheelhouse-style same-identity restarts reclaim one nested space with exact focus and idempotence
ok - real Herdr lab: secondmate restart binding and reclaim stay isolated to the exact child home and parent
ok - real Herdr lab: concurrent cross-home recoveries replace exact husks under one session lock with no focus drift
ok - real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch
ok - real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact
```

The projection suite ran again on 2026-08-04 against Herdr 0.8.0 protocol 19 for the default-on flip, where an absent `config/herdr-presentation-spaces` enables the projection and only the value `off` opts out:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed default and opt-out guarantees:

```text
ok - real Herdr lab: an opted-out spawn retains the Stage 1 Herdr command sequence with zero ordering calls
ok - real Herdr lab: a home that configured nothing is projected by default
ok - real Herdr lab: the primary presentation setting inherits into real secondmate homes
ok - real Herdr lab validation completed on Herdr 0.8.0 with the default-session tripwire intact
```

The projected spawn in that run used the historical empty opt-in file, so a home that had already enabled the projection keeps it without any migration step.
One concurrent cross-home recovery case refused under contention on a loaded machine and passed on an immediate rerun; recovery-path presentation lock contention is a deliberate hard refusal rather than a flat fallback, which default-on now makes reachable from any Herdr home.

The restored-shell session-start cleanup ran on 2026-07-24 against Herdr 0.7.5 protocol 17:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-herdr-session-cleanup-e2e.test.sh
```

Observed guarantee: one exact home-local, journal-correlated, one-tab and one-pane childless idle shell was closed after restoration while the exact non-target focus and default fleet session remained unchanged, and a repeat run was a no-op.

### OMP lifecycle

The focused Herdr submit guard ran on 2026-08-26 against OMP 18.0.4 and Herdr 0.8.2 in one guarded non-default lab session.
It suppressed the native session-event confirmation inside the production submit function, required the real OMP composer plus current native `working` state to return `queued-unconfirmed`, and independently required the exact steering event to appear afterward.
The fixture verifies the exact trailing `--session <name>` binding, routes the two bare read-only production client reads (`session list --json` and `api schema --json`) through the named lab helper binding so the event fast-path resolves its socket and capability instead of silently degrading to polling, rejects every other `session` subcommand and every `server` operation, and requires the helper's default-session tripwire to survive final teardown.
Every wrapper refusal - unbound, outside the lab session, `server`, and any non-`list` `session` subcommand - is recorded in the wrapper's callers log through one shared refusal path and fails the matrix, so a refused call can no longer pass unnoticed as a poll-path fallback.

```sh
bash -c '
set -e
evidence_dir=$(mktemp -d)
trap "rm -rf \"$evidence_dir\"" EXIT
omp --version > "$evidence_dir/actual.out"
herdr --version >> "$evidence_dir/actual.out"
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  HERDR_LAB_HELPER=/home/dnth/Desktop/firstmate/bin/fm-herdr-lab.sh \
  FM_OMP_HERDR_SUBMIT_LIVE_E2E=1 \
  bin/fm-test-run.sh tests/fm-omp-herdr-live-e2e.test.sh > "$evidence_dir/live.out"
grep -F "ok - real Herdr OMP submit fallback: missing native event used working composer queue proof" "$evidence_dir/live.out" >> "$evidence_dir/actual.out"
cat > "$evidence_dir/expected.out" <<EOF
omp/18.0.4
herdr 0.8.2
ok - real Herdr OMP submit fallback: missing native event used working composer queue proof
EOF
diff -u "$evidence_dir/expected.out" "$evidence_dir/actual.out"
cat "$evidence_dir/actual.out"
'
```

Observed bounded output:

```text
omp/18.0.4
herdr 0.8.2
ok - real Herdr OMP submit fallback: missing native event used working composer queue proof
```

The primary loaded the tracked OMP adapter, acquired its home session lock, completed a guarded turn, and kept its watcher live while the other roles ran.
The worker and scout used production `fm-spawn.sh`, real Treehouse isolation, exact `harness=omp` metadata, generated lifecycle extensions, task-owned native sessions, production `fm-send.sh`, and guarded cleanup of their extensions, task roots, and isolated copies.
Idle steering required an exact post-offset native user event with `steering:false`, and processing steering required the matching event with `steering:true`, for both worker and scout.
A real single-choice OMP question produced native `blocked`, and the watcher queued one escalation naming the exact worker target before the selection was resolved.
The fixture stopped its two exact watcher processes, drained both isolated evidence homes, and required both durable queues to be empty before final lab teardown.
Each normal `/exit` required a post-offset normal `session_exit`; the focused exit check also required an exact pre-send `agent=omp` plus native-session binding and an independent post-exit `pane get` result of `pane_not_found` rather than relying on server health.
The secondmate returned a correlated marked reply, exited, recovered the exact retained session, refused a duplicate live launch, and exited again.
The worker launch assertion observed the exact production call `session list --json --session <lab-session>` and matched the worker's recorded `herdr_workspace_id` to the primary pane's live workspace.
The deterministic adapter suite rejects duplicate matching running session entries before trusting the launcher pane, while preserving the existing missing, malformed, mismatched-socket, symlink-parent, and exact-parent cases.
The role-matrix run emitted queued-wake notices while the isolated evidence homes were being exercised, but it emitted no watcher-down warning, `verdict=unknown`, cleanup ambiguity, missing role, or helper-tripwire failure.
Native OMP Herdr probes remain intentionally quarantined by this fixture, so this record covers real OMP/Herdr Firstmate backend routing and lifecycle behavior rather than unwrapped native probe behavior.
The transcript above is the corrected fixture's isolated 01:41Z lab run: it finished green with an empty callers log, so no production Herdr command was refused, and the event fast-path resolved both its capability read and its control socket instead of degrading to the polling backstop.
Its queued-wake notice predates the event-bound notification drains; the head-bound green rerun of the same two Herdr owners is the combined runner record in the tmux OMP lifecycle section above, whose watcher notices are not evidence about this helper-isolated matrix.

Scope provenance: the OMP implementation and acceptance criteria are [`dnth/firstmate` issues #2-#7](https://github.com/dnth/firstmate/issues/7), while the same-numbered `kunchenguid/firstmate` issues are unrelated historical work.
The upstream [`kunchenguid/firstmate` issue #723](https://github.com/kunchenguid/firstmate/issues/723) is only the originating feature request; issue #7 requires publishing the implementation branch to `dnth/firstmate` without automatically opening an upstream pull request.

Blocked-state parsing, identical non-steering event rejection, unreadable-state preservation, and unsupported-backend preflight remain deterministic contract tests rather than claims about this live role-matrix run.

### Workspace-removal focus safety

The focus-flash regression ran on 2026-07-28 against Herdr 0.7.5 protocol 17 on macOS aarch64:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-focus-flash-e2e.test.sh
```

Observed output:

```text
ok - old path: the explicit last-pane close of a non-focused workspace stole focus (w3	w3:t1 -> w2	w2:t1)
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - mitigation: no explicit close and no corrective focus were needed on the defective release
evidence: herdr=0.7.5 protocol=17 steal_live=1 default-session-tripwire=armed
```

Direct lab probes on the same day established the removal rules the emptying-close plan relies on, each verified with `workspace list` focus reads around one mutation in a guarded `fm-lab-` session:

- An explicit `pane close` that emptied a non-focused workspace moved focus off the focused workspace in both before-focus and after-focus geometries.
- Ending a workspace's lone shell preserved the focused workspace exactly when the dying workspace sat behind it or the focused workspace was last, and moved focus to the focused workspace's right neighbor otherwise.
- The production focus-preserving close in the dangerous geometry repositioned the doomed workspace, ended its proved shell, and left every concurrent focus sample on the exact anchor with no corrective `tab focus` issued.

Two real-hardware conditions were required for the pane-death path to engage and are now encoded in the adapter and its unit fixtures: BSD `ps` reports a login shell's `comm` as `-zsh`, and an idle shell transiently hosts a prompt helper (starship) as a second foreground process immediately after a `workspace.move` relayout, which the bounded settle window absorbs.

The rules match the v0.7.5 tag source (`close_selected_workspace` reassigns focus from the closing workspace's index; `handle_pane_died` only clamps the stale focused index), and the upstream default branch resolves both paths by workspace id (PR #1877, commit `165dca45`, for the explicit close; PR #1912, commit `a979916`, for pane death), so the plan degrades to a harmless reorder-then-remove once a release carries them.

The full projection and restored-shell suites were re-run the same day on the same version with the updated close path; the presentation suite completed with `real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact`, and the restored-shell cleanup guarantee above was unchanged.

The teardown-level record-retention gate was verified on 2026-07-28 with metadata fixtures and a live contending lock holder:

```sh
tests/fm-teardown.test.sh
tests/fm-backend-herdr.test.sh
```

Observed guarantees: a contended presentation lock refused the teardown before the isolated copy was returned, with the task branch, every durable record, and the endpoint intact and no pane close attempted; the retry after the contention cleared returned the copy, closed the pane under the lock, and removed the records; an unknown structured-presence result after an attempted projected close retained the journal and every record with a nonzero exit; and every presence-gate mode accepted only a structured not-found as gone.

The same fixtures verified three further boundaries on 2026-07-29: missing or malformed endpoint identity and an unparseable pane presence refused record removal with everything retained; the SIGKILL escalation re-read the exact pane's process information and refused to signal when a different shell pid owned the pane, falling back to the plain close with the original process untouched; and a reposition whose removal then failed on every path restored the exact original workspace order through a second verified move and reported the close as failed.

The teardown fixture was re-run on 2026-07-31 after extending the same fail-closed boundary through forced secondmate cleanup, including recursive cleanup of a nested secondmate whose Herdr grandchild close remains unconfirmed.

Observed output:

```text
ok - forced secondmate teardown preflights every Herdr child before cleanup mutation
ok - forced secondmate teardown retains Herdr child identity until exact pane disappearance
ok - forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed
```

### Composer and operational input

Real captures verified these active distinctions:

- Claude and Codex use bare `❯` and `›` agent composers.
- Pi uses content between complete separator rows and requires exact native Pi identity.
- Dim or faint suggestion text is ghost content, while normally styled text is pending input.
- Grok dark truecolor placeholders are ghost content, while bright truecolor typed input remains pending.
- A bare shell prompt has no safe agent-composer container and is unknown.

`tests/fm-composer-ghost.test.sh`, `tests/fm-composer-lib.test.sh`, and the Herdr composer cases pin the exact captured ANSI bytes.
The U+2063 operational and routed-request separators were exercised through a real Pi-on-Herdr path; the byte-exact active regression is:

```sh
FM_SEND_MARKER_HERDR_E2E=1 \
  tests/fm-send-secondmate-marker-herdr-e2e.test.sh
```

### Native blocked event

The protocol-16 event path was measured on 2026-07-11 with Herdr 0.7.3 and Python 3.13:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-eventwait-smoke.test.sh
```

Observed output:

```text
ok - real herdr: events.subscribe capability gate passes
ok - real herdr: a driven idle->blocked transition returns the blocked record in 0.129s
ok - real herdr: the watcher fast-path enqueues a stale wake naming the task window
```

Polling remained active and is covered as the fallback for capability, connect, subscribe, and repeated reader failure.

### Away-mode transport

The Pi/Herdr return and injection path was reverified on Herdr 0.7.3 and Pi 0.80.7:

```sh
FM_AFK_PI_HERDR_E2E=1 HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Observed guarantees: pending composer input refused injection and raised one alert; idle Pi accepted one marked escalation; the return gate refused ordinary work while a live blocker remained; resolving the blocker allowed the return flow.
The dedicated Herdr daemon workspace topology is covered by `tests/fm-afk-launch.test.sh` and preserves the captain tab's pane count.

On 2026-08-30, an isolated Herdr 0.8.2 protocol-20 lab found no conditional composer admission or reservation primitive: `pane send-text`, `pane send-keys`, and `agent prompt` remain separate operations.
The probe and shipped-path smoke used only named non-default lab sessions:

```sh
lab=$(bin/fm-herdr-lab.sh name afk-atomic-admission-probe)
trap 'bin/fm-herdr-lab.sh teardown "$lab"' EXIT
bin/fm-herdr-lab.sh provision "$lab"
bin/fm-herdr-lab.sh run "$lab" status --json
bin/fm-herdr-lab.sh run "$lab" pane send-text --help
bin/fm-herdr-lab.sh run "$lab" pane send-keys --help
bin/fm-herdr-lab.sh run "$lab" agent prompt --help
bin/fm-herdr-lab.sh run "$lab" api schema
tests/fm-afk-herdr-atomic-admission-smoke.test.sh
```

Observed output:

```text
ok - named Herdr lab smoke: the shipped atomic-admission path deferred without typing into its isolated composer (deferred-unknown)
```

The adapter therefore preserves the durable escalation and returns a deferral instead of injecting typed supervisor text; it does not claim that a recheck or process-local lock is atomic.

## OMP applicability outside tmux and Herdr

Zellij, Orca, and cmux were inspected on 2026-07-30 without claiming live OMP execution.
Zellij's submit verifier has only plain content-delta acknowledgement and no ANSI composer or native agent-state signal.
Orca and cmux use generic bordered composer readers, expose no native OMP state, and already refuse secondmate spawns.
None can establish OMP's exact busy-steering event, normal-exit event, blocked-state, or recovery contract.
`fm-spawn.sh` therefore uses an explicit `tmux|herdr` OMP allowlist and rejects all three before backend runtime checks, endpoint creation, metadata, or launch delivery.

```sh
tests/fm-spawn-dispatch-profile.test.sh
tests/fm-backend-zellij.test.sh
tests/fm-backend-orca.test.sh
tests/fm-backend-cmux.test.sh
```

The focused OMP refusal cases verify zero endpoint calls and no launch text for every unsupported backend.
This is source and contract inspection only, not live OMP verification.

## Zellij

The current compatibility floor and latest verification are Zellij 0.44.0 with `jq` on macOS aarch64.
All real tests use a uniquely named session and `tests/zellij-test-safety.sh`; they never touch a session named `firstmate` or call all-session deletion.

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Headless session | `zellij attach -b <name>` without a TTY | Created a persistent background session and returned. |
| Session list | `zellij list-sessions --short --no-formatting` | Returned one plain name per line without starting a session. |
| Create tab | `zellij action new-tab --cwd <dir> --name <title>` | Returned a numeric tab id and focused the new tab when a client was attached. |
| Pane discovery | `zellij action list-panes --json` | Included terminal pane id, tab id, plugin flag, and top-level `pane_cwd`. |
| Literal send | `zellij action paste --pane-id <id> -- <text>` | Left text unsubmitted. |
| Keys | `send-keys --pane-id <id> Enter`, `Esc`, and one argument `Ctrl c` | All three shared operations worked. |
| Capture | `dump-screen --pane-id <id>` or `--full` | Worked with no attached client; no line-bound flag exists. |
| Close | `close-tab-by-id <id>` | Removed the live task pane and tab together. |
| Failure exit | actions against missing targets | Returned exit 0, requiring structural preflight and output-shape validation. |

`pane_cwd` stayed frozen when a foreground subshell changed directory.
The marker-delimited `pwd` probe returned the live nested cwd and is covered by the real smoke.
The focus mitigation restored the previously active tab after `new-tab`, with the unavoidable narrow race documented in the operator guide.

```sh
tests/fm-backend-zellij.test.sh
tests/fm-backend-zellij-smoke.test.sh
```

The real lifecycle smoke proved spawn, metadata, nested-subshell worktree discovery, send, capture, unlanded-work refusal, approved local landing, exact tab cleanup, and session cleanup without retaining task-specific ids or branch names here.

## Orca

Real readiness was verified against `/usr/local/bin/orca` with `/Applications/Orca.app` bundle version 1.4.116.

```sh
orca status --json
```

Observed fields:

```text
result.runtime.reachable=true
result.runtime.state=ready
```

`orca terminal create --json` returned `result.terminal.handle`.
`orca worktree create` returned `result.worktree.id` and `result.worktree.path`.
Speculative bare ids and nested terminal fields were deliberately rejected.

```sh
tests/fm-backend-orca.test.sh
tests/fm-backend.test.sh
tests/fm-bootstrap.test.sh
```

The fake-Orca suite covers readiness, registration, create response parsing, metadata routing, popup-safe submit, and path-matched release refusal.

## cmux

The current compatibility floor is cmux 0.64, and the active live evidence uses 0.64.17 build 97 on macOS aarch64.
Real tests use only exact `fm-test-` workspaces guarded by `tests/cmux-test-safety.sh` and never quit or relaunch the captain's app.

```sh
cmux version
cmux ping
```

Observed version:

```text
cmux 0.64.17 (97) [9ed29d81a]
```

Source and live checks established the five control modes:

- `off` starts no listener.
- `cmuxOnly` rejects an external Firstmate process by ancestry.
- `automation` uses an owner-only 0600 socket with no handshake.
- `password` uses the same 0600 socket plus `auth <password>`.
- `allowAll` uses a 0666 socket with no authentication.

The live default rejection was `Access denied - only processes started inside cmux can connect`.
The live password challenge was `Authentication required - send auth <password> first`.
The app configuration writer did not retain a hand-added socket password, which is why the operator guide requires Settings and a local Firstmate password source.

Current active CLI findings:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Create | `new-workspace --name <title> --cwd <dir> --focus false --id-format uuids` | Created one workspace with one surface without focusing it. |
| Fresh readiness | `list-panes --workspace <id> --json --id-format uuids` | Found a brand-new surface before content existed. |
| Fresh read counterexample | `read-screen` before any write | Returned `internal_error: Failed to read terminal text`. |
| Literal send | `send --workspace <id> --surface <id> -- <text>` | Left text unsubmitted. |
| Keys | `send-key ... enter|escape|ctrl-c` | All shared key operations worked. |
| Nested cwd | `current_directory` plus foreground subshell | Structured cwd froze; the marker-delimited `pwd` probe found the live cwd. |
| Last surface | `close-surface` on the only surface | Refused with `invalid_state: Cannot close the last surface`. |
| Last workspace | `close-workspace` on the only workspace in a window | Printed success but left the workspace present. |

The last-workspace workaround was reverified on 2026-07-10 in Automation mode.
After creating one unfocused unnamed sibling in the same window, `close-workspace` removed the exact task workspace and left only cmux's default sibling.
A selected non-last workspace closed directly, proving that window cardinality rather than selection is the trigger.

Source inspection confirmed each workspace constructor creates a new UUID with no restored-id input.
Recovery therefore remains title-based.
The bundled Claude wrapper was observed stripping `CMUX_*` variables on its failed socket-probe path while retaining the app bundle id, supporting the macOS-only bundle-id and ancestry fallbacks.

```sh
tests/fm-backend-cmux.test.sh
tests/fm-backend-cmux-smoke.test.sh
```

The real smoke proves socket access, fresh readiness, current-path probing, send and keys, bounded capture, title identity, and guarded exact cleanup.

## Local steering inbox

The durable local steering-inbox path was verified live on 2026-08-28 against Codex CLI 0.149.1 and OMP 18.0.4 in isolated neutral-project tmux sessions.
For each harness, `fm-send.sh` published an ordinary steer as a sequenced `state/<id>.inbox/*.msg` record and submitted only the constant doorbell to the terminal at that revision.
The real worker read the record, performed the requested file action, and acknowledged delivery by moving the record into `state/<id>.inbox/handled/`.
This acceptance guard is scoped to the required Codex and OMP proof; adapter-specific compatibility remains owned by each harness's existing live guard.

```sh
FM_SEND_INBOX_LIVE_E2E=1 \
  FM_SEND_INBOX_LIVE_HARNESSES='codex omp' \
  FM_SEND_INBOX_LIVE_TIMEOUT=180 \
  bash tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

Observed result:

```text
ok - codex (codex-cli 0.149.1): real worker acted on and acknowledged the durable record
ok - omp (omp/18.0.4): real worker acted on and acknowledged the durable record
ok - live steering-inbox doorbell guard: 2 harnesses verified
```

The OMP wake transport was changed on 2026-08-30 from terminal submission to an acknowledged programmatic extension request on tmux and Herdr.
The deterministic extension and primary-adapter fixtures cover canonical counted requests, `triggerTurn=true`, post-retirement signal safety, exact-identity revalidation for pending retries, pre-call payload failure fallback, ambiguous-claim inbox anchoring without resend, ordinary non-OMP composer routing, ordinary worker wiring, and secondmate wiring through the primary extension.
The required live OMP-under-Herdr smoke is intentionally deferred until after Firstmate updates; no live Herdr or OMP lifecycle was driven from this worktree.

```sh
set -o pipefail
tests/fm-omp-task-inbox-doorbell.test.sh | grep -E '^ok - (OMP extension drains|doorbell routing selects|OMP pending retries|fm-send and both)'
tests/fm-omp-primary.test.sh | grep -F 'ok - OMP primary extension binds secondmate doorbells after session readiness'
```

Observed result:

```text
ok - OMP extension drains canonical counted requests and safely retires signal readiness
ok - doorbell routing selects OMP programmatic wake and preserves both composer branches
ok - OMP pending retries revalidate identity while ambiguous claims suppress resend
ok - fm-send and both tmux/Herdr adapters preserve task-bound OMP programmatic doorbells
ok - OMP primary extension binds secondmate doorbells after session readiness
```

## Codex App host tools

A reusable Desktop host-tool smoke ran on 2026-07-06 against Codex Desktop bundle version 26.623.101652, build 4674, bundle id `com.openai.codex`.
Local paths and task-specific ids are intentionally not retained here.

The host-tool sequence was:

1. list a saved project;
2. create a Desktop-owned worktree thread;
3. recover and read the thread while active and after completion;
4. verify the thread appended a Firstmate status line and wrote its report;
5. send a follow-up to the same thread;
6. read the completed follow-up;
7. archive the exact thread;
8. read the archived transcript with state `notLoaded`.

Observed guarantee: a Desktop-owned thread can write Firstmate lifecycle files when the prompt provides an authorized absolute path, and create, send, read, and archive work at the Desktop host-tool layer.
The missing guarantee remains a supported shell-callable bridge that lets Firstmate perform those operations against the same visible Desktop endpoint.
App-server partial methods and raw socket experiments do not satisfy that bridge contract.
