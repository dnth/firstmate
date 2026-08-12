# RunPod second mates

RunPod is an optional compute lifecycle provider for a whole-home remote second mate.
It is not a session backend and not a new kind of second mate.
A RunPod second mate is an ordinary remote second mate exactly as [`remote-secondmates.md`](remote-secondmates.md) describes it, whose SSH host happens to be an ephemeral pod that firstmate terminates when the work is done and recreates when there is work again.
Herdr remains its backend in the shared `fm-remote` session, the primary still owns routing and supervision, and every command still reaches it through `fm-on.sh`, `fm-spawn.sh`, `fm-send.sh`, and `fm-teardown.sh`.

Nothing here is active until a home creates a RunPod record, so a fleet with no RunPod second mates behaves exactly as it did before.

## Why a pod instead of a machine

A remote second mate normally needs a machine that is always on.
A RunPod second mate keeps its whole durable state on a network volume and rents compute only while it is working, so an idle domain costs storage alone.

| State | What exists | What it costs |
| ----- | ----------- | ------------- |
| Suspended | The network volume only | Storage: $0.07/GB/month up to 1 TB, $0.05/GB/month beyond |
| Awake | The volume plus one pod | Storage plus the pod's hourly rate, billed by the second |

A 100 GB volume therefore idles at about $7/month with no compute running at all.
`bin/fm-runpod.sh cost <id>` prints that home's real numbers, reading the live pod's current rate rather than a table in this file.

Automatic idle sleep is deliberately not implemented yet: suspension is an explicit operator or firstmate decision, so a second mate is never taken away mid-thought.

## What lives where

One network volume per RunPod second mate, named `fm-sm-<domain>-runpod`, holds every durable thing on that host:

```
/workspace/firstmate            the remote Firstmate code root
/workspace/secondmate-home      the persistent FM_HOME, deliberately separate from the code root
/workspace/persistent-runtime   SSH host keys, boot log, selected caches
```

Project clones and worktrees live under the second mate's own home, as on any other remote host.
Local second mates never get a volume.

The authoritative control plane is local, private, and gitignored:

| Path | Holds |
| ---- | ----- |
| `<FM_HOME>/data/runpod/<id>.meta` | provider, volume id, datacenter, current pod id, current endpoint, compute type, lifecycle state |
| `<FM_HOME>/config/runpod.env` | `RUNPOD_API_KEY=<key>` in ordinary KEY=value form, mode 600 |
| `<FM_HOME>/config/runpod/ssh.d/<alias>.conf` | the generated SSH config fragment for that route |
| `<FM_HOME>/config/runpod/known_hosts` | the pinned host key for each alias |
| `<FM_HOME>/state/.runpod-lifecycle-<id>.lock` | the per-second mate lifecycle lock |

Firstmate's local record is what decides which pod and volume belong to a second mate.
RunPod is asked to confirm or create what that record names; it is never scanned to discover routes this home did not create.

The credential file is parsed, never sourced, so nothing in it can execute.
The key is passed to `curl` through a mode-600 config file, so it never appears in a process listing, in the record, or in any error message.
Every command that needs the API refuses with that exact path and key name before it makes any request, so a missing key never turns into a confusing authorization error from an unauthenticated call.

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

Create the volume and record the placement.
No pod is created, so this costs storage only:

```sh
bin/fm-runpod.sh provision <id> --datacenter EU-RO-1 --size 100
```

Bring the host up:

```sh
bin/fm-runpod.sh wake <id>
```

Then seed the second mate exactly as for any other remote route, using the alias `provision` reported:

```sh
bin/fm-remote-home-seed.sh <id> fm-sm-<id>-runpod /workspace/firstmate /workspace/secondmate-home <project>...
bin/fm-spawn.sh <id> --secondmate
```

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

The primary wakes a suspended route itself when it actually needs the host: `bin/fm-send.sh` wakes before it delivers, and `bin/fm-spawn.sh <id> --secondmate` wakes before the readiness gate.
Both wakes happen strictly before anything is delivered, so a compute failure loses nothing and can be retried; once delivery starts, the existing unknown-completion contract in [`remote-secondmates.md`](remote-secondmates.md) applies unchanged.

Startup health polling, startup convergence, `bin/fm-config-push.sh`, and reply-source arming all skip a suspended route instead.
None of them creates compute, and none of them reports the suspension as a fault.

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

It restores the persisted SSH host key from the volume, starts sshd with the account's authorized key, links the fixed remote entrypoint, and then hands readiness to `bin/fm-remote-doctor.sh --fix`.
The doctor is the single owner of what "ready for a remote second mate" means, and on Linux it starts the remote job worker and the headless Herdr `fm-remote` server itself, with no GUI or Aqua session involved.
That is why a fresh pod recovers a working `fm-remote` server on every wake without anything RunPod-specific in the readiness path: the doctor already owns the whole Linux case, and `bin/fm-spawn.sh <id> --secondmate` passes through that same gate.

On a volume's very first boot there is no code root yet, so the pod stops after sshd and waits for `bin/fm-remote-home-seed.sh` to clone one.

## Verification

The portable tests drive the real provider against a stateful mocked RunPod REST double and a faked SSH boundary, so no account, key, or paid resource is involved:

```sh
bin/fm-test-run.sh tests/fm-runpod-lifecycle.test.sh
bin/fm-test-run.sh tests/fm-runpod-routing.test.sh
```

The lifecycle suite covers idempotent provision and wake, exactly one pod under concurrent wakes, CPU and GPU exclusivity, endpoint refresh with a stable pinned host identity, every sleep guard, volume retention, and the guarded destroy path.
The routing suite covers the supervision, convergence, and delivery wiring, including that an ordinary remote route and a local second mate are unaffected.

Real provisioning against a RunPod account, and the first end-to-end pilot on a genuine pod, remain an operator-run smoke test and are not claimed by the repository tests.
