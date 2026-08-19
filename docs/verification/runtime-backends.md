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

### OMP lifecycle

The complete tmux role matrix reran on 2026-07-31 against OMP 17.1.8 using separate private tmux sockets, temporary homes, and disposable git worktrees:

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

The OMP max-time deadline guard passed on 2026-08-17 against OMP 17.3.4 using the default `openai-codex/gpt-5.6-sol` live-test model:

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
ok - OMP secondmates inspect staged live extensions
ok - OMP secondmate launch and recovery use the isolated adapter and an exact home-owned session pointer
```

The deterministic spawn checks prove that an OMP launch refuses a git-tracked project extension without the explicit override, records the override when passed, and leaves projects without tracked extensions unchanged.
The secondmate integration checks prove that the exact Firstmate primary extension remains loadable from the persistent home without being treated as untrusted project code.

The Herdr role matrix required each expected turn-end or routed-reply notification to reach the durable queue or the primary follow-up transcript before the fixture drained it.

The deterministic tmux and Herdr fixtures reran on 2026-08-09 and proved that an already-busy OMP send returns `queued-unconfirmed` only after Enter transport succeeds, without reading a rendered steering count, while Enter transport failure returns `send-failed` and initially idle editable input remains pending and fails closed.
This is revision-bound source-fixture evidence for the source under review, using Bun 1.3.14 only for terminal-cell measurement; it does not invoke OMP or make an OMP runtime-version claim.

The deterministic fm-send turn-start fixture ran on 2026-08-19 and proved that an initially idle OMP submit must become busy or advance its generated turn-start marker after the submit-time baseline before success, while `delivered-no-turn` exits distinctly, queues supervised recovery, and never kills the endpoint.
The same fixture proved the monotonic deadline, Herdr post-submit check, normal turn start, already-busy `queued-unconfirmed` exception, remote OMP routing, and unchanged non-OMP behavior.
The tested source is Git revision `6c72c63e902b020b051aa825f99e8581d41601c4` plus source-bundle SHA-256 `4b651ac05194a231d87fdd8a9e85b09eedc9da34c3dc845ec521e244d51f1e1c` over the changed delivery implementation and fixture files.
This evidence uses stubbed backend state and process identity only, does not invoke a live OMP runtime, and makes no live OMP claim.

```sh
tests/fm-send-turn-start.test.sh
```

Observed output:

```text
ok - fm-send: confirmed OMP delivery without a turn returns delivered-no-turn and wakes supervised recovery
ok - fm-send: a real OMP turn start preserves normal success
ok - fm-send: delivered-no-turn never closes an answered decision
ok - fm-send: OMP session activity advancement proves a fast turn start
ok - fm-send: pre-submit activity cannot prove the submitted turn started
ok - fm-send: the already-busy OMP queued-Enter exception is unchanged
ok - fm-send: turn-start verification remains scoped to OMP targets
ok - fm-send: the monotonic deadline prevents post-expiry backend probes
ok - fm-send: OMP keys ignore text-only turn-start configuration
ok - fm-send: remote OMP metadata routing leaves non-OMP state unchanged
ok - fm-send: Herdr empty still requires post-submit OMP turn proof
```

```sh
bash -c '
set -e
evidence_dir=$(mktemp -d)
trap "rm -rf \"$evidence_dir\"" EXIT
command -v bun >/dev/null
bun --version > "$evidence_dir/actual.out"
tests/fm-tmux-submit-busy.test.sh > "$evidence_dir/tmux.out"
tests/fm-backend-herdr.test.sh > "$evidence_dir/herdr.out"
grep -hE "^(ok - (fm_tmux_submit_enter_core: idle pane \\+ pending composer stays pending|fm_tmux_submit_enter_core: busy OMP Enter transport failure|busy OMP mixed Enter transport retains queued delivery|OMP tmux composer keeps queued busy submits|fm_backend_herdr_send_text_submit: busy OMP without proof|fm_backend_herdr_send_text_submit: busy OMP Enter transport failure))" "$evidence_dir/tmux.out" "$evidence_dir/herdr.out" >> "$evidence_dir/actual.out"
cat > "$evidence_dir/expected.out" <<EOF
1.3.14
ok - fm_tmux_submit_enter_core: idle pane + pending composer stays pending (genuine swallow preserved)
ok - fm_tmux_submit_enter_core: busy OMP Enter transport failure returns send-failed
ok - busy OMP mixed Enter transport retains queued delivery
ok - OMP tmux composer keeps queued busy submits separate from unsubmitted input
ok - fm_backend_herdr_send_text_submit: busy OMP without proof is queued-unconfirmed
ok - fm_backend_herdr_send_text_submit: busy OMP Enter transport failure returns send-failed
EOF
diff -u "$evidence_dir/expected.out" "$evidence_dir/actual.out"
cat "$evidence_dir/actual.out"
'
```

Observed bounded output:

```text
1.3.14
ok - fm_tmux_submit_enter_core: idle pane + pending composer stays pending (genuine swallow preserved)
ok - fm_tmux_submit_enter_core: busy OMP Enter transport failure returns send-failed
ok - busy OMP mixed Enter transport retains queued delivery
ok - OMP tmux composer keeps queued busy submits separate from unsubmitted input
ok - fm_backend_herdr_send_text_submit: busy OMP without proof is queued-unconfirmed
ok - fm_backend_herdr_send_text_submit: busy OMP Enter transport failure returns send-failed
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
Tmux, Herdr, Zellij, and cmux all submit the shared guarded acquisition command, then resolve the acquired worktree through their existing current-path adapter only after the wrapper enters its verified lease.
Orca is not applicable because it owns task worktrees and never invokes Treehouse.

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
Claude, Codex, OpenCode, Pi, pi-signed, Grok, and Kimi share that backend cleanup boundary; their harness-specific hook files and token cleanup run only after it, so no harness needs a separate endpoint parser.

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

The complete Herdr role matrix reran on 2026-08-01 against OMP 17.1.8 and Herdr 0.7.5 protocol 17 in one guarded non-default lab session.
The fixture verifies the exact trailing `--session <name>` binding, routes the two bare read-only production client reads (`session list --json` and `api schema --json`) through the named lab helper binding so the event fast-path resolves its socket and capability instead of silently degrading to polling, rejects every other `session` subcommand and every `server` operation, and requires the helper's default-session tripwire to survive final teardown.
Every wrapper refusal - unbound, outside the lab session, `server`, and any non-`list` `session` subcommand - is recorded in the wrapper's callers log through one shared refusal path and fails the matrix, so a refused call can no longer pass unnoticed as a poll-path fallback.

```sh
omp --version
herdr --version
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
  HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  FM_OMP_HERDR_LIVE_E2E=1 \
  bin/fm-test-run.sh tests/fm-omp-herdr-live-e2e.test.sh
env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" PATH="$PATH" LC_ALL=C TERM=dumb SHELL=/bin/bash \
  FM_OMP_HERDR_EXIT_LIVE_E2E=1 HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  bin/fm-test-run.sh tests/fm-omp-herdr-exit-live-e2e.test.sh
```

Observed bounded output:

```text
omp/17.1.8
herdr 0.7.5
{"client":17,"server":17}
FM_TEST_BEGIN 2026-08-01T01:41:56Z tests/fm-omp-herdr-live-e2e.test.sh family=live-harness-optin expected_gate_skip=optin-env
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.
ok - real Herdr OMP role matrix: primary, worker/scout idle and busy steering, blocked escalation, secondmate, normal exits, recovery, duplicate refusal, and guarded teardown
FM_TEST_END 2026-08-01T01:46:07Z tests/fm-omp-herdr-live-e2e.test.sh exit=0 duration_ms=251807 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=251880
FM_TEST_BEGIN 2026-08-01T01:46:33Z tests/fm-omp-herdr-exit-live-e2e.test.sh family=live-harness-optin expected_gate_skip=optin-env
ok - real Herdr OMP /exit: exact native identity, post-offset normal session_exit, pane absence, and guarded tripwire teardown
FM_TEST_END 2026-08-01T01:46:51Z tests/fm-omp-herdr-exit-live-e2e.test.sh exit=0 duration_ms=18266 gate_skip=false
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=18323
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
