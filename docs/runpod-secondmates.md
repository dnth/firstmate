# RunPod second mates

RunPod is an optional compute lifecycle provider for a whole-home remote second mate.
It is not a session backend and not a new kind of second mate.
A RunPod second mate is an ordinary remote second mate exactly as [`remote-secondmates.md`](remote-secondmates.md) describes it, whose SSH host happens to be an ephemeral pod that firstmate can terminate when the work is done and recreate when there is work again.
Herdr remains its backend in the shared `fm-remote` session, the primary still owns routing and supervision, and every command still reaches it through `fm-on.sh`, `fm-spawn.sh`, `fm-send.sh`, and `fm-teardown.sh`.

Nothing here is active until a home creates a RunPod record, so a fleet with no RunPod second mates behaves exactly as it did before.

## Why a pod instead of a machine

A remote second mate normally needs a machine that is always on.
A RunPod second mate keeps its whole durable state on a network volume and rents compute only while the operator leaves it awake, so a suspended domain costs storage alone.

| State | What exists | What it costs |
| ----- | ----------- | ------------- |
| Suspended | The network volume only | Storage: $0.07/GB/month up to 1 TB, $0.05/GB/month beyond |
| Awake | The volume plus one pod | Storage plus the pod's hourly rate, billed by the second |

A 100 GB volume therefore idles at about $7/month with no compute running at all.
`bin/fm-runpod.sh cost <id>` prints that home's real numbers, reading the live pod's current rate rather than a table in this file.

Automatic idle sleep is deliberately not implemented yet: suspension is an explicit operator or firstmate decision, so a second mate is never taken away mid-thought.

## Durable pod storage

One network volume per RunPod second mate, named `fm-sm-<id>-runpod`, holds every durable thing on that host:

```
/workspace/firstmate            the remote Firstmate code root
/workspace/secondmate-home      the persistent FM_HOME, deliberately separate from the code root
/workspace/persistent-runtime   SSH host keys, boot state, and the durable toolchain
/workspace/home                 the account home: every completed login and runtime config
```

The account home is on the volume on purpose.
Claude, Codex, other pod-local worker runtimes, and `gh` write their credentials under the account home, so on a container-local home each login would die with the pod and setup would be once per pod.
OMP is the deliberate exception because its subscription credentials remain in the workstation auth broker described below.
Boot rewrites the account's entry in the pod's own `/etc/passwd` so an SSH login lands there, and writes the volume path to `/etc/firstmate/durable-root` so `bin/fm-remote-doctor.sh --parity` can verify it.
That single move covers every runtime at once instead of one credential-directory variable per tool.

Project clones live under the second mate's durable home, while Treehouse task worktrees live in a pool on the pod's local container storage so checkout activity never wedges on the network volume.
The local Treehouse pool is disposable: replacing or suspending the pod removes its checked-out copies, while landed commits, task records, credentials, and every other durable Firstmate record remain on the network volume.
Each pod has a disposable 40 GB container disk, the maximum RunPod accepts.
Local second mates never get a volume.
[`configuration.md`](configuration.md#runpod-compute-lifecycle-configrunpodenv-configrunpod-datarunpod) owns the local control-plane paths, record contents, credential contract, and generated SSH state.

## SSH identity across pod replacement

A replaced pod gets a new IP and a new external port, so the connection details change on every wake.
The identity must not.

Each wake regenerates the alias fragment with the pod's current `HostName` and `Port`, and a fixed `HostKeyAlias`.
The pod's SSH host key is stored on the network volume, so a fresh pod restores the same key the primary already pinned under that alias.
`StrictHostKeyChecking` stays on, always.

The key is pinned once, on the first wake of a volume that has no persisted key yet.
After that, a key that does not match is a real failure and the connection is refused rather than re-pinned.

Wire the generated fragments into your own SSH config once, at the very top of `~/.ssh/config` so it precedes any matching `Host` block:

```
Include /absolute/path/to/firstmate-home/config/runpod/ssh.d/*.conf
```

## Operator sequence

Everything below is run from the primary home.

Put the API key in place once, before anything else:

```sh
printf 'RUNPOD_API_KEY=%s\n' "$YOUR_KEY" > "$FM_HOME/config/runpod.env"
chmod 600 "$FM_HOME/config/runpod.env"
```

Configure the RunPod account to inject the primary's SSH public key as `PUBLIC_KEY` or `SSH_PUBLIC_KEY` before the first wake.
When the primary uses a non-default private key, pass its absolute path with `provision --identity` and inject the matching public key.

Create the volume and record the placement.
No pod is created, so this costs storage only:

```sh
bin/fm-runpod.sh provision <id> --datacenter EU-RO-1 --size 100 \
  --code-origin https://github.com/<owner>/firstmate.git
```

`--code-origin` is required for a fresh volume and names the git URL the pod clones its Firstmate code root from on first boot; without it or an existing clone, wake refuses and records no satisfied toolchain marker.
Add `--harness-npm <package>` only for an extra harness beyond the parity set the pod installs anyway.

Bring the host up with the CPU default:

```sh
bin/fm-runpod.sh wake <id>
```

Wake obtains the workstation's existing `omp auth-broker token` without rotating it, starts or reuses the loopback broker, starts the credential-read-only facade, installs a mode-600 bearer on the pod, and starts the supervised SSH reverse tunnel.
It does not place the bearer in the RunPod environment or any command argument.
The pod does not reach readiness until it can read a broker snapshot through that tunnel.

Alternatively, request GPU compute, optionally with a minimum VRAM floor:

```sh
bin/fm-runpod.sh wake <id> --gpu
bin/fm-runpod.sh wake <id> --min-vram 24
```

After a volume's first wake reaches ready, log each pod-local runtime in once: use `bin/fm-runpod.sh ssh <id>`, run the Claude and Codex login flows, run any other selected harness's login, and run `gh auth login`.
Do not run OMP login, logout, import, or migrate on the pod.
OMP reads the workstation's existing Claude and GPT subscription credentials through the broker instead.
SSH also becomes available before toolchain provisioning finishes, so it can be used from another terminal to diagnose a wake that is still waiting.
Boot places `$HOME/.local/bin` first in the durable account's `.profile` and `.bashrc`, and reconciles retained `.bash_profile` or `.bash_login` files that take precedence for Bash login shells, so bare SSH login and interactive shells resolve the same installed harnesses as the fixed remote entrypoint.
Conventional startup-file symlinks whose resolved regular-file targets remain inside the durable account home are preserved and reconciled at their targets; broken links, non-regular targets, and links escaping that home are refused.
Readiness verifies executable presence and the durable account home, but deliberately neither detects nor gates vendor login state.
Those logins land on the volume, so later wakes and replacement pods need none of it again.
If provisioning or a later boot step fails, the pod stays running and wake remains unready; connect from another terminal with `bin/fm-runpod.sh ssh <id>` and inspect `/workspace/persistent-runtime/boot.log`.
RunPod's REST API has no log or console endpoint, so that SSH session and volume-backed log are the diagnostic path for failures after sshd starts.

Seed the persistent home exactly as for any other remote route, using the alias `provision` reported:

```sh
bin/fm-remote-home-seed.sh <id> fm-sm-<id>-runpod /workspace/firstmate /workspace/secondmate-home <project>...
bin/fm-spawn.sh <id> --secondmate
```

The first wake provisions the toolchain before this step, so the code root and required tools are already in place.
Every RunPod home converges its crew dispatch after inherited configuration lands.
Its `config/crew-harness` selects Codex as the genuine primary, and `config/crew-harness-fallback` selects Claude only when the supported predictive fallback trigger proves Codex unavailable or at zero effective headroom.
That provider-owned layer affects crews only; the remote second-mate agent stays on the separately configured secondmate harness and may now use OMP on this host.

From here it is an ordinary remote second mate.
Route work to it, steer it, and hand it backlog with the normal commands.

Suspend it when the work is done:

```sh
bin/fm-runpod.sh sleep <id>
```

Inspect it at any time:

```sh
bin/fm-runpod.sh status           # every RunPod-backed second mate in this home
bin/fm-runpod.sh cost <id>        # idle storage cost, live rate, pod uptime
bin/fm-runpod.sh doctor <id>      # the normal readiness check, waking the host first
bin/fm-runpod.sh ssh <id>         # an interactive shell on the pod
```

`bin/fm-runpod.sh`'s own header owns every flag, including GPU selection, the account name, the identity file, and the container image.

### Waking is automatic where it matters

The primary wakes a dormant route itself when it actually needs the host: `bin/fm-send.sh` wakes before it delivers, and `bin/fm-spawn.sh <id> --secondmate` wakes before the readiness gate.
Both wakes happen strictly before anything is delivered, so a compute failure loses nothing and can be retried; once delivery starts, the existing unknown-completion contract in [`remote-secondmates.md`](remote-secondmates.md) applies unchanged.

The provider treats `provisioned`, `waking`, `suspending`, and `suspended` as dormant because none is ready for ordinary remote work; a waking pod may expose SSH only for bootstrap diagnostics.
Startup health polling, startup convergence, `bin/fm-config-push.sh`, and reply-source arming all skip a dormant route instead.
None of them creates compute, and none of them reports the deliberate no-host state as a fault.
An unrecognized lifecycle value is not dormant, so corrupt metadata surfaces as an ordinary route failure instead of repeatedly creating compute.
The parent watcher also recognizes those lifecycle records directly and absorbs a dormant route on the long pause cadence without probing its absent beacon or escalating it as a possible wedge.

### Endpoint stalls and never-ready recovery

Wake uses one 20-minute default deadline for volume verification, endpoint publication, host-key discovery, and SSH bootstrap.
`FM_RUNPOD_WAKE_TIMEOUT` can override that bound for tests or an operator with a known provider environment.
When RunPod does not publish an SSH endpoint before the deadline, the error reports both the provider's `desiredStatus` and `status`, preserves the pod for inspection, and names the guarded recovery command.

If that volume has never reached ready, terminate the stuck billable pod while retaining the volume:

```sh
bin/fm-runpod.sh recover-stuck <id> --yes
```

The command requires `ever_ready=0`, explicit `--yes` confirmation, a provider endpoint read, and bounded SSH checks against both the published endpoint and any endpoint retained in the local record.
It prints the provider, current-endpoint, recorded-endpoint, and SSH evidence before acting, and it refuses when any endpoint is reachable or indeterminate.
SSH exit 255 is indeterminate because it can represent authentication, host-key, configuration, or transport failure; it is never accepted as proof of unreachability.
RunPod can publish an endpoint between any provider read and a later deletion, so this human-gated command does not claim race-free endpoint proof; ambiguity refusal and explicit confirmation are the accepted safety boundary rather than additional automated polling.
Only after those guards does it delete the recorded pod, clear its stale endpoint, and return the retained volume to `provisioned`.
It refuses once the volume has ever reached ready because an unreachable ready host may contain running or completed work whose outcome is unknown.
Use the ordinary `sleep` path only after reconciling that work on the same host.
Wake does not automatically create a replacement after an endpoint stall, even when the failed never-ready pod later becomes `TERMINATED` or absent, because the failed paid resource and its provider state remain the operator's evidence.
Run `recover-stuck --yes` to acknowledge and clear that attempt before another ordinary wake can create replacement compute.

## Suspending safely

Before evaluating these guards, `sleep` reconciles handled correlated replies and sends each finished delivered direct-PR child through the ordinary landed-work teardown guard.
That cleanup removes only work already proven safe to tear down; unlanded or otherwise unsafe children remain and block suspension.

`sleep` refuses, and leaves the pod running, while any of these is true:

- The remote home still supervises workers.
- A backlog handoff to that second mate is still undelivered.
- A routed reply is still unresolved.
- A captured reply is still unhandled.
- A decision opened by that second mate is still open.
- The host cannot be reached, so its remote work is unknown.

These are the same conditions `bin/fm-teardown.sh` refuses a remote retirement for, and the last one is the same unknown-completion rule: an unreachable host is reconciled on that host, never assumed idle.

Sleep is not retirement.
The route, the registry record, the reply cursor, the local records, and the volume all survive it, and the next wake resumes the reply relay from exactly the offset it stopped at.

## Retiring and destroying

Retire the second mate the normal way, while it is awake:

```sh
bin/fm-teardown.sh <id>
```

That removes the remote home and the route but leaves the volume, because the volume is a separate, permanently destructive thing to remove.
Deleting it is its own explicitly authorized command, and it refuses while a pod is running or the route is still registered:

```sh
bin/fm-runpod.sh destroy <id> --yes
```

Everything on the volume is gone at that point, including the second mate's projects, backlog, and history.
Treat it exactly like any other irreversible action.

## The pod's boot contract

`bin/fm-runpod-pod-boot.sh` and its shared Treehouse-root helper are tracked as one combined shell payload, sent to every pod base64-encoded in one environment variable and run as its start command.
The container image needs nothing from this repo preinstalled, and the boot contract is versioned with the code that creates the pod.

Boot first establishes the diagnostic SSH channel:

1. Install base packages: `git`, `jq`, `curl`, `ca-certificates`, `unzip`, and `openssh-server`.
2. Restore or create the volume-backed SSH host key, refusing to expose a container-local replacement if that identity cannot be persisted.
3. Authorize the configured account key and start sshd.

Boot also writes the durable login-shell PATH, the `IS_SANDBOX=1` shell environment, and a root-owned provider marker that the empty-environment doctor and remote-job boundaries validate before propagating `IS_SANDBOX=1`.

Only after sshd starts does first boot provision the remaining noninteractive prerequisites:

1. Install a current Node LTS and `bun`, the runtimes the rest of the toolchain needs.
2. Clone the Firstmate code root from `--code-origin` when the volume has none.
3. Install `herdr` and `treehouse` through this repository's own pinned, checksum-verified installers, `bin/fm-install-herdr.sh` and `bin/fm-install-treehouse.sh`, so a pod runs the exact builds CI verifies rather than a floating latest.
4. Install the parity toolchain below.

A RunPod second mate is contracted to reach full parity with a local one, so the pod installs everything a local second mate and the crews it spawns use: the `omp`, `claude`, and `codex` worker harnesses, the universal toolchain owned by [`configuration.md`](configuration.md#toolchain) (`no-mistakes`, `gh`, `gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `quota-axi`, `tasks-axi`), the CodeGraph CLI, and a headless Chrome for browser work.
All of it installs under the volume, so the cost is paid once per volume rather than once per pod.
`bin/fm-remote-doctor.sh --parity` is the single owner of what that set is; the boot script installs toward it and the tests check the two lists against each other.

The browser's shared libraries are the exception: they are container-local system packages, re-ensured on every boot and deliberately kept out of the set that gates sshd, so a browser dependency can never cost the pod its only diagnostic channel.
Boot publishes the durable browser at `/usr/bin/google-chrome` through a wrapper and then runs it, because a browser that exists but cannot start is a failure that belongs at provisioning time rather than in the middle of a worker's page.
The wrapper adds `--no-sandbox --disable-dev-shm-usage` only when the pod runs as root, which keeps root-only Chrome startup policy at the launch seam without changing non-root calls.

It then links the durable tools and fixed remote entrypoint, prepares Claude's durable unattended root state, and hands readiness to `bin/fm-remote-doctor.sh --fix --parity`.
Claude setup preserves unrelated operator JSON keys while setting completed onboarding and a theme, accepting each launched worktree's trust and project-onboarding prompts, accepting the bypass-permissions warning, and disabling commit, PR, and session-URL attribution.
Every Claude launch in the pod carries `IS_SANDBOX=1` into the long-lived backend pane, including the remote second mate and any Claude fallback crew.
The doctor is the single owner of what "ready for a remote second mate" means, and on Linux it starts the remote job worker and the headless Herdr `fm-remote` server itself, with no GUI or Aqua session involved.
Nothing in the boot script re-states the doctor's verdict; it installs toward that set and lets the doctor decide.
Every failure after sshd starts is written to the volume-backed boot log and leaves the pod open for inspection.
Wake still requires the separate `boot.ready` sentinel written only after provisioning and the doctor handoff succeed, so SSH alone can never make an unfinished or failed bootstrap report ready.

Durable provisioning is idempotent and volume-scoped.
A marker records only the volume-resident contract, while every replacement pod re-ensures its container-local system packages before trusting it.
A contract-current retained checkout that predates a newly required tracked boot helper is cleanly fast-forwarded to obtain that helper without changing the installed-tool contract.
A raised contract version re-provisions the durable tools exactly once.
`bin/fm-runpod-pod-boot.sh --check` prints the plan as one `ensure=<item>` line per step and touches nothing, which is how the contract is tested with no pod.

The pod image must provide glibc 2.34 or newer.
The pinned default is an official RunPod Ubuntu 22.04 base for that reason: the pinned treehouse build requires GLIBC_2.34, so an Ubuntu 20.04 image downloads it successfully and then cannot execute it, which fails first-boot provisioning.
Override the image only with one that meets that floor.

Every pod-local worker harness other than OMP, and `gh`, still needs its own interactive login as a human step.
Those credentials are never copied from the primary or injected as pod environment variables: each runtime is logged in once over `bin/fm-runpod.sh ssh <id>`, and the durable account home is what keeps that login across pod replacement.
The doctor checks that the account home is under the declared durable root, which is the structural guarantee that a completed login is once per volume.
It deliberately does not try to read or report whether a given harness is logged in: that verdict would come from vendor-specific credential files this repository cannot prove against the real harnesses, and a check that cannot be proven is worse than an honest human step.

OMP's interactive OAuth callback remains unusable on the current headless pod image, so OMP is configured as a remote broker client instead of being logged in on the pod.
The live pilot's `EADDRINUSE` observation remains evidence about the rejected pod-local login path, not a dependency of the broker design.

## OMP subscription auth through the workstation

The workstation is the only credential writer and runs `omp auth-broker serve` against its already logged-in Claude and GPT subscription credentials.
`bin/fm-runpod-omp-auth.sh` supervises that broker, a credential-read-only loopback facade, and one `ssh -R` tunnel per awake pod.
The reverse tunnel publishes `http://127.0.0.1:8765` only on the pod and forwards it to the workstation facade, not directly to the unrestricted broker port.
The SSH client uses `ExitOnForwardFailure=yes`, `ServerAliveInterval=15`, and `ServerAliveCountMax=3`, and its supervisor restarts the connection after every drop.
Pod sshd accepts remote forwarding only, keeps `GatewayPorts` off, and permits only the broker loopback listener.

The workstation bearer copy is `<FM_HOME>/config/runpod/omp-auth-broker.token` and the pod copy is `/workspace/persistent-runtime/omp-auth-broker.token`.
Both are regular mode-600 files.
The bearer never appears in RunPod pod environment fields, SSH arguments, generated SSH fragments, endpoint metadata, logs, or tracked files.
The remote second-mate agent's OMP launch receives `OMP_AUTH_BROKER_URL` and expands `OMP_AUTH_BROKER_TOKEN` from the mode-600 file inside the backend pane, after the literal command has crossed the terminal transport.
Descendant OMP crews retain the safe token-file path and repeat the same launch-time expansion.

Installed OMP exposes remote credential-write hooks in addition to the local synchronous methods that throw on a `RemoteAuthCredentialStore`.
The facade therefore enforces the required operational read-only boundary rather than relying on a client convention.
It permits snapshot and usage reads plus `POST /v1/credential/<id>/refresh`, because refresh executes on the workstation broker and the refresh token never leaves that process.
It rejects credential upload, replacement, disable, login, logout, import, and migrate requests before they reach the canonical broker.
This leaves one OAuth refresh writer on the workstation and avoids the dual-writer rotation lockout.

This design has a hard workstation-online dependency.
If the workstation sleeps, shuts down, loses its network path, stops the broker, or loses the tunnel, the pod's OMP loses Claude and GPT auth until that path returns.
An in-process tunnel supervisor reconnects automatically after an ordinary SSH or network drop.
After a workstation reboot, run `bin/fm-runpod.sh wake <id>` again to recreate the workstation supervisors and tunnel for an already-running pod.
The pod remains billable while boot waits for this dependency, so do not leave a first wake unattended with the workstation about to go offline.
Claude and Codex pod-local logins are independent of this dependency and continue to use the durable account home.

Inspect the workstation side without revealing the bearer:

```sh
bin/fm-runpod-omp-auth.sh status <id>
```

The expected state is `broker=running`, `proxy=running`, and `tunnel-<id>=running`.

### Live end-to-end verification

The portable suite does not wake a pod or spend RunPod compute.
Use this runbook during the next approved awake window:

1. On the workstation, run `curl -fsS --max-time 2 http://127.0.0.1:8765/v1/healthz >/dev/null`; reuse that single canonical writer when the command succeeds, or run `omp auth-broker serve --bind=127.0.0.1:8765` in a dedicated terminal and leave it running for the verification window when the command fails.
2. In another workstation terminal, run `bin/fm-runpod.sh wake <id>` and wait for the `ready:` line.
3. Run `bin/fm-runpod-omp-auth.sh status <id>` and confirm the broker, facade, and named tunnel all report `running`.
4. Connect with `bin/fm-runpod.sh ssh <id>` and run `/workspace/persistent-runtime/fm-runpod-pod-boot.sh --check-omp-auth-broker-client`.
5. In that pod shell, run `OMP_AUTH_BROKER_URL=http://127.0.0.1:8765 OMP_AUTH_BROKER_TOKEN="$(cat /workspace/persistent-runtime/omp-auth-broker.token)" omp auth-broker status --json` and confirm the JSON reports usable Claude and GPT subscription credentials without printing the token.
6. Configure the primary home's `config/secondmate-harness` for OMP, launch with `bin/fm-spawn.sh <id> --secondmate`, and send the second mate this bounded request:

```text
Spawn exactly two crews through the ordinary guarded lifecycle.
Launch the first with harness `omp`, model `anthropic/claude-opus-4-8`, and effort `low`; ask it to reply exactly `claude-broker-ok` and then stop.
Launch the second with harness `omp`, model `openai-codex/gpt-5.6-sol`, and effort `low`; ask it to reply exactly `gpt-broker-ok` and then stop.
Report both task ids and responses without launching any native Claude or Codex crew.
```

7. Confirm the two OMP task records retain their explicit model selectors and both crews reach their first turn with the requested response.
8. Land or tear down both crews through the normal guarded lifecycle before running `bin/fm-runpod.sh sleep <id>`.

The runbook is intentionally operator-run during an approved awake window because waking a pod solely for validation incurs cost.

`--harness-npm` remains available for an optional extra npm harness beyond the parity set; the parity set is installed either way, so leaving it unset is the normal case.

## Verification

[`verification/runpod-secondmates.md`](verification/runpod-secondmates.md) records the dated portable and approved live evidence plus the validation boundary.
That record owns the exact results and coverage; this operator guide owns the reusable live runbook.
