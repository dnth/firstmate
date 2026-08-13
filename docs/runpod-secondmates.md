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
Every worker runtime and `gh` writes its credential under the account home, so on a container-local home each login would die with the pod and setup would be once per pod.
Boot rewrites the account's entry in the pod's own `/etc/passwd` so an SSH login lands there, and writes the volume path to `/etc/firstmate/durable-root` so `bin/fm-remote-doctor.sh --parity` can verify it.
That single move covers every runtime at once instead of one credential-directory variable per tool.

Project clones and worktrees live under the second mate's own home, as on any other remote host.
Each pod also has a disposable 40 GB container disk, the maximum RunPod accepts; reducing or replacing that disk loses no Firstmate state because everything durable lives on the network volume.
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

Alternatively, request GPU compute, optionally with a minimum VRAM floor:

```sh
bin/fm-runpod.sh wake <id> --gpu
bin/fm-runpod.sh wake <id> --min-vram 24
```

After a volume's first wake reaches ready, log each runtime in once: use `bin/fm-runpod.sh ssh <id>`, run each harness's own login, and run `gh auth login`.
SSH also becomes available before toolchain provisioning finishes, so it can be used from another terminal to diagnose a wake that is still waiting.
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

## Suspending safely

`sleep` refuses, and changes nothing, while any of these is true:

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

`bin/fm-runpod-pod-boot.sh` is the tracked boot script, sent to every pod base64-encoded in one environment variable and run as its start command.
The container image needs nothing from this repo preinstalled, and the boot contract is versioned with the code that creates the pod.

Boot first establishes the diagnostic SSH channel:

1. Install base packages: `git`, `jq`, `curl`, `ca-certificates`, `unzip`, and `openssh-server`.
2. Restore or create the volume-backed SSH host key, refusing to expose a container-local replacement if that identity cannot be persisted.
3. Authorize the configured account key and start sshd.

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

It then links the durable tools and fixed remote entrypoint and hands readiness to `bin/fm-remote-doctor.sh --fix --parity`.
The doctor is the single owner of what "ready for a remote second mate" means, and on Linux it starts the remote job worker and the headless Herdr `fm-remote` server itself, with no GUI or Aqua session involved.
Nothing in the boot script re-states the doctor's verdict; it installs toward that set and lets the doctor decide.
Every failure after sshd starts is written to the volume-backed boot log and leaves the pod open for inspection.
Wake still requires the separate `boot.ready` sentinel written only after provisioning and the doctor handoff succeed, so SSH alone can never make an unfinished or failed bootstrap report ready.

Durable provisioning is idempotent and volume-scoped.
A marker records only the volume-resident contract, while every replacement pod re-ensures its container-local system packages before trusting it.
A raised contract version re-provisions the durable tools exactly once.
`bin/fm-runpod-pod-boot.sh --check` prints the plan as one `ensure=<item>` line per step and touches nothing, which is how the contract is tested with no pod.

The pod image must provide glibc 2.34 or newer.
The pinned default is an official RunPod Ubuntu 22.04 base for that reason: the pinned treehouse build requires GLIBC_2.34, so an Ubuntu 20.04 image downloads it successfully and then cannot execute it, which fails first-boot provisioning.
Override the image only with one that meets that floor.

Every worker harness, and `gh`, still needs its own interactive login as a human step.
Credentials are never copied from the primary, never injected as pod environment variables, and never API keys: each runtime is logged in once over `bin/fm-runpod.sh ssh <id>`, and the durable account home is what keeps that login across pod replacement.
The doctor checks that the account home is under the declared durable root, which is the structural guarantee that a completed login is once per volume.
It deliberately does not try to read or report whether a given harness is logged in: that verdict would come from vendor-specific credential files this repository cannot prove against the real harnesses, and a check that cannot be proven is worse than an honest human step.

`--harness-npm` remains available for an optional extra npm harness beyond the parity set; the parity set is installed either way, so leaving it unset is the normal case.

## Verification

The portable tests drive the real provider against a stateful mocked RunPod REST double and a faked SSH boundary, so no account, key, or paid resource is involved:

```sh
bin/fm-test-run.sh tests/fm-runpod-lifecycle.test.sh
bin/fm-test-run.sh tests/fm-runpod-routing.test.sh
bin/fm-test-run.sh tests/fm-runpod-pod-boot.test.sh
```

The lifecycle suite covers idempotent provision and wake, exactly one pod under concurrent wakes, CPU and GPU exclusivity, RunPod's 40 GB container-disk limit, endpoint refresh with a stable pinned host identity, every sleep guard, volume retention, and the guarded destroy path.
The routing suite covers the supervision, convergence, and delivery wiring, including that an ordinary remote route and a local second mate are unaffected.

Real provisioning against a RunPod account remains an operator-run smoke test and is not claimed by the repository tests.
