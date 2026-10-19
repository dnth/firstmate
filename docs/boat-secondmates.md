# Boat second mates

Boat is an optional compute provider beneath an ordinary [remote second mate](remote-secondmates.md), not a session backend or an ephemeral-worker provider.
A placement belongs to either Boat or RunPod; contradictory records refuse wake and delivery before creating compute.
RunPod keeps its existing lifecycle.

## Requirements and setup

The workstation needs the Boat CLI, an authenticated Boat account, `uv`, Python 3, Node.js, and an SSH identity with a matching `.pub` file.
Boat CLI authentication is read from its mode-600 `${XDG_CONFIG_HOME:-~/.config}/ascii/boat/config.json`, with the CLI's legacy `ascii/box/config.json` fallback when the Boat file is absent.
`FM_BOAT_CONFIG_FILE` selects an explicit file instead of those defaults; a missing or unsafe override is refused rather than falling back.
Never put the API credential in command arguments or tracked files.
Brokered OMP authentication additionally requires Linux cgroup v2, a reachable systemd user manager, and a workstation OMP installation with the selected account credentials.
There is no PID-tree fallback on systems without that custody substrate.
The [credential boundary](#subscription-credential-boundary) owns credential sources and the workstation-online requirement.
The remote host must meet the installation and readiness requirements in [remote-secondmates.md](remote-secondmates.md#prerequisites); provisioning compute does not install a Firstmate home or a worker runtime.
The [remote-home prerequisites](remote-secondmates.md#prerequisites) own the neutral forge-credential policy, toolchain, entrypoint `PATH`, and `gh auth` dispatch gate.

With an explicit `FM_HOME`, provision the placement and wake it before following that guide's seed and launch procedure.
`bin/fm-boat.sh --help` owns command options and defaults.
For example:

```bash
export FM_HOME=/absolute/path/to/firstmate-home
bash bin/fm-boat.sh provision ios --identity ~/.ssh/id_ed25519 --model openai-codex/gpt-5.6-sol --size small --ttl 86400 --omp-auth
bash bin/fm-boat.sh wake ios
```

Use the recorded SSH alias when seeding the route.
Add `Include /absolute/path/to/firstmate-home/config/boat/ssh.d/*.conf` at the top of the workstation SSH config so ordinary remote control uses the generated pinned endpoint.
The first successful SSH verification persists the sandbox host key before marking it verified.
Later wakes restore that persisted key and refuse a mismatch rather than replacing the pin.
Fresh endpoints may change IP or port without changing identity.

## Cost and sleep policy

Sleep is explicit unless the placement opts in to idle auto-sleep, which runs this same guarded sleep after a quiet window; [Idle auto-sleep](configuration.md#idle-auto-sleep-configidle-sleep) owns that contract.
A dormant route wakes before a requested delivery or remote launch; health polling, startup convergence, configuration propagation, and reply polling do not wake it.
Wake-on-delivery follows the shared [agent restoration contract](remote-secondmates.md#compute-wake-and-agent-restoration).
The [remote control script](../bin/fm-remote-secondmate-control.sh) owns finished-worker reconciliation before sleep.
Sleep refuses pending routed replies, unhandled captured replies, open decisions, undelivered handoffs, live or unknown remote child work, and any remaining finished ship whose work has not landed.
Sleep and destroy report guard failures, including unresolved routed request identities and phases, unhandled captured reply counts, and unavailable locks or remote checks.
Worker release at PR-ready follows the shared [landing-owner contract](remote-secondmates.md#landing-owner).

| Size | Compute rate per hour |
| --- | ---: |
| small | $0.018 |
| default | $0.036 |
| large | $0.072 |
| xlarge | $0.200 |

These are the adapter's reference rates, not a guarantee of account pricing or storage charges.
Inspect the provider's current pricing before authorizing paid work.
Every allocation and resume has a finite provider TTL; the default is 86,400 seconds, and the adapter accepts 1 through 2,592,000 seconds.
TTL is a server-side cost backstop, not the idle-sleep policy or proof that local credential cleanup succeeded.

```bash
bash bin/fm-boat.sh status ios
bash bin/fm-boat.sh sleep ios
# Removes the sandbox only after confirmed credential retirement and provider stop.
bash bin/fm-boat.sh destroy ios --yes
```

A failed wake compensates by retiring credentials and requesting a confirmed stop.
Failed compensation remains explicitly unresolved and never reports a clean stop.
A failed sleep restores credential and reply availability when the sandbox is still running; incomplete restoration remains unresolved.
A failed bearer shred prevents deletion.
Sleep and destroy do not issue another provider stop for an already stopped or archived sandbox.
For a registered remote route, destroy skips remote reconciliation and child-work checks only when the placement is suspended or provisioned and has durable proof of a successful sleep whose remote checks passed.
Wake clears that proof before transitioning, so a suspended record left by failed-wake compensation does not qualify.
Without proof, dormant destroy refuses before remote checks; wake the placement so destroy can run those checks.
A running placement still requires remote reconciliation and no active or unknown child work.
Dormant destroy rechecks the lifecycle and proof under the lifecycle lock and refuses if either no longer qualifies.
All destroy paths retain the pending-reply, handoff, decision, credential-cleanup, and explicit confirmation guards.
Reconcile an unresolved placement or credential record before retrying sleep or destroy; do not delete its records to bypass cleanup.

## Subscription credential boundary

`bin/fm_boat_auth.py` owns credential acquisition, use, rollback, and release.
Each acquisition runs in a generation-specific systemd user service with `KillMode=control-group`.
The service contains the broker it starts, read-only facade, installer, tunnel, and their descendants, including descendants whose leader exits or which create a new session.
The workstation broker uses a service-private loopback port by default, so wake does not depend on the conventional workstation broker port being available.
The [credential command header](../bin/fm-boat-omp-auth.sh) owns the shared-broker override.
Release revokes the generation under kernel flock before stopping the exact service and verifying that its cgroup is empty.
A delayed service request checks the generation under the same lock before consuming credentials.
No PID journal, descendant snapshot, STOP/CONT handshake, or PID fallback selects processes to signal.
This is process custody for adapter helpers, not containment against malicious local programs that can ask the user manager to launch unrelated services.
The worker runtime's crash is not an implicit compute-sleep request; explicitly sleep the placement or rely on its finite provider TTL.
Opt-in idle auto-sleep still requires the [documented eligibility checks](configuration.md#idle-auto-sleep-configidle-sleep), including authoritative idle.

Release removes local bearer files, proves service retirement, then checks remote bearer shred before a sandbox can be deleted or reported stopped.
Partial acquisition failures use that same release path.
Failed cleanup keeps the exact service identity and an unresolved cleanup record so retry can prove retirement instead of guessing.

The shared OMP bearer grammar lives in `bin/fm-omp-auth-token-lib.sh`.
The provider policy lives in `bin/fm-boat-policy.mjs` and is used both before allocation and by facade egress.
It defaults to `openai-codex`; a mode-600 `config/boat/providers.json` may explicitly select other provider names.
A model must name a listed provider and a nonempty model before any sandbox creation.
OAuth entries require an opaque nonnegative integer refresh locator and finite upstream expiry and are reconstructed from the explicit fields below; upstream refresh data is never exposed:

```json
{"provider":"openai-codex","id":2,"identityKey":null,"rotatesInMs":null,"credential":{"type":"oauth","access":"<access>","refresh":"__remote__","expires":4102444800000}}
```

The null fields and `__remote__` refresh marker are protocol constants, never upstream identity or refresh data.
For `api_key`, the facade reconstructs only `{provider,id,identityKey:null,rotatesInMs:null,credential:{type:'api_key',key}}` and serves it only when its provider is allowlisted and its ID is in that lease's credential-ID scope.
Refresh accepts only OAuth entries vendable in the current scoped snapshot.
Upstream refresh tokens, unknown fields or shapes, absent credential arrays, and failed refresh response bodies never leave the facade.
To use any of `opencode-go-dnth`, `opencode-go-dnth-1`, `opencode-go-neuralengine`, or `opencode-go-neuralengine-1`, include that provider in the captain-private allowlist above; it contains provider names, never keys.

Boat's Python 3 must have PyYAML available for model-configuration installation and checks; API-key resolution uses only the Python standard library.

At lease start, the workstation reads the allowlisted OpenCode Go keys from its mode-600 `~/.local/share/opencode/auth.json` and imports them into the workstation OMP broker.
The lease facade scopes OpenCode Go API-key egress to the selected credential ID for each imported account, excluding unrelated credentials even for the same provider.
The Boat's keyless OMP `models.yml` entries call a remote helper that reads the scoped broker snapshot; this is the only OpenCode Go key path for the Boat secondmate and its workers.
Installation replaces the four Go provider entries while preserving unrelated configuration.
An existing providers mapping must use an unquoted `providers:` block header and two-space provider indentation; unsupported representations, including inline mappings and four-space provider indentation, are refused before writing, leaving the original file unchanged.
Installation and readiness checks parse YAML and reject duplicate keys and malformed configuration.
During a live lease, OMP can hold a routed key in process memory for requests; no key or workstation `auth.json` is written to Boat disk, environment, command line, or logs.
The broker snapshot disk cache is disabled for Boat OMP launches, including relaunches, while generic broker launches retain their existing cache behavior.
Boat launch and relaunch require the installed credential-lease marker and refuse a missing or unsafe marker; restore the lease before retrying.
The workstation must stay online for the lease so the helper can reach the broker.

When an OpenCode key changes, the next lease imports the new value and disables the previously imported broker credential owned by that placement.
Revoke access by rotating or revoking the key at OpenCode; the provider then rejects the old value, including one still held in an active process's memory.

Boat cannot inspect these accounts' quota: quota-axi reads the workstation's `auth.json`, which is not copied to Boat.
The main home selects the account at routing time using current workstation quota evidence and passes its provider/model in the launch profile; Boat must not choose among Go accounts or claim quota-informed selection.

## Verification and opt-in live smoke

`tests/fm-boat-omp-auth.test.sh`, `tests/fm-boat-lifecycle.test.sh`, and `tests/fm-boat-routing.test.sh` use fresh fixture homes and fake Boat, SSH, and credential commands.
The credential suite exercises real systemd cgroups and asserts that no recorded helper identity survives cleanup.
It skips explicitly when the required Linux user manager is absent.
The credential suite also checks that concurrent default leases serve their own credentials and that releasing one does not stop the other.

The live entry point is `bin/fm-boat.sh live-smoke --identity <key> --model <provider/model>`.
It refuses without `FM_BOAT_LIVE=1`, serializes one small sandbox, uses the `fm-boat-smoke-` name prefix, and keeps TTL renewals within the original one-sandbox-hour deadline.
It performs two wake/sleep cycles and checked final deletion; an earlier recorded smoke sandbox must be reconciled before another starts.
Provisioning can fail before the provider applies the smoke name; identify that sandbox by the recorded `sandbox_id` from `status`, not by the name prefix alone.
If final cleanup also fails, the smoke reports both its original error and the cleanup error instead of hiding the initiating failure.
Never run paid live smoke as part of the fixture test suite; fixture smoke failure drivers replace the provider, SSH, and credential commands.
