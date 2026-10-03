# Boat second mates

Boat is an optional compute provider beneath an ordinary [remote second mate](remote-secondmates.md), not a session backend or an ephemeral-worker provider.
A placement belongs to either Boat or RunPod; contradictory records refuse wake and delivery before creating compute.
RunPod keeps its existing lifecycle.

## Requirements and setup

The workstation needs the Boat CLI, an authenticated Boat account, `uv`, Python 3, Node.js, and an SSH identity with a matching `.pub` file.
Boat CLI authentication is read from its mode-600 `${XDG_CONFIG_HOME:-~/.config}/ascii/boat/config.json`, with the CLI's legacy `ascii/box/config.json` fallback when the Boat file is absent.
`FM_BOAT_CONFIG_FILE` selects an explicit file instead of those defaults; a missing or unsafe override is refused rather than falling back.
Never put the API credential in command arguments or tracked files.
Subscription authentication additionally requires Linux cgroup v2, a reachable systemd user manager, and a workstation OMP broker login.
There is no PID-tree fallback on systems without that custody substrate.
Keep the workstation online while subscription-authenticated work is running.
The remote host must meet the installation and readiness requirements in [remote-secondmates.md](remote-secondmates.md#prerequisites); provisioning compute does not install a Firstmate home or a worker runtime.
That includes the full remote-home tool set (`node`, `git`, `gh`, `no-mistakes`, `gh-axi`, `chrome-devtools-axi`, `lavish-axi`, `tasks-axi`, `quota-axi`, `herdr`, `treehouse`, and the selected agent harness such as `omp`) and an entrypoint symlink on a directory the sandbox account's non-interactive SSH `PATH` already searches - `~/.local/bin` where the default account `PATH` covers it, otherwise a searched system location such as `/usr/local/bin`.
Provisioning never installs or copies forge credentials onto a Boat sandbox, and whether the sandbox account authenticates GitHub is the operator's decision.
Crew and project dispatch inside the remote home is gated on `gh auth` there: without it the remote second mate still runs and does local and scratch work, but refuses delegated project work.

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

Sleep is explicit, never an automatic idle action.
A dormant route wakes before a requested delivery or remote launch; health polling, startup convergence, configuration propagation, and reply polling do not wake it.
A compute stop does not keep the second-mate agent, so a wake-on-delivery that finds the remote endpoint absent restores it through the same readiness, launch, and bind gate before anything is delivered, and refuses without delivery when the restore cannot prove a live endpoint.
Sleep refuses pending routed replies, open decisions, undelivered handoffs, or active or unknown remote child work.

| Size | Compute rate per hour |
| --- | ---: |
| small | $0.018 |
| default | $0.036 |
| large | $0.072 |
| xlarge | $0.200 |

These are the adapter's reference rates, not a guarantee of account pricing or storage charges.
Inspect the provider's current pricing before authorizing paid work.
Every allocation and resume has a finite provider TTL; the default is 86,400 seconds, and the adapter accepts 1 through 2,592,000 seconds.
TTL is a server-side cost backstop, not an idle-sleep policy or proof that local credential cleanup succeeded.

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
Sleep and destroy accept an already stopped or archived sandbox without issuing another provider stop; destroy still requires checked credential cleanup before deletion.
Reconcile an unresolved placement or credential record before retrying sleep or destroy; do not delete its records to bypass cleanup.

## Subscription credential boundary

`bin/fm_boat_auth.py` owns credential acquisition, use, rollback, and release.
Each acquisition runs in a generation-specific systemd user service with `KillMode=control-group`.
The service contains the broker it starts, read-only facade, installer, tunnel, and their descendants, including descendants whose leader exits or which create a new session.
Release revokes the generation under kernel flock before stopping the exact service and verifying that its cgroup is empty.
A delayed service request checks the generation under the same lock before consuming credentials.
No PID journal, descendant snapshot, STOP/CONT handshake, or PID fallback selects processes to signal.
This is process custody for adapter helpers, not containment against malicious local programs that can ask the user manager to launch unrelated services.
The worker runtime's crash is not an implicit compute-sleep request; explicitly sleep the placement or rely on its finite provider TTL.

Release removes local bearer files, proves service retirement, then checks remote bearer shred before a sandbox can be deleted or reported stopped.
Partial acquisition failures use that same release path.
Failed cleanup keeps the exact service identity and an unresolved cleanup record so retry can prove retirement instead of guessing.

The shared OMP bearer grammar lives in `bin/fm-omp-auth-token-lib.sh`.
The provider policy lives in `bin/fm-boat-policy.mjs` and is used both before allocation and by facade egress.
It defaults to `openai-codex`; a mode-600 `config/boat/providers.json` may explicitly select other provider names.
A model must name a listed provider and a nonempty model before any sandbox creation.
The scoped facade accepts OAuth entries only, requires an opaque nonnegative integer refresh locator and finite upstream expiry, and reconstructs each entry from explicit fields:

```json
{"provider":"openai-codex","id":2,"identityKey":null,"rotatesInMs":null,"credential":{"type":"oauth","access":"<access>","refresh":"__remote__","expires":4102444800000}}
```

The null fields and `__remote__` refresh marker are protocol constants, never upstream identity or refresh data.
Upstream refresh tokens, API keys, unknown fields or shapes, absent credential arrays, and failed refresh response bodies never leave the facade.
Refresh refuses an ID that the current scoped snapshot cannot vend.

## Verification and opt-in live smoke

`tests/fm-boat-omp-auth.test.sh`, `tests/fm-boat-lifecycle.test.sh`, and `tests/fm-boat-routing.test.sh` use fresh fixture homes and fake Boat, SSH, and credential commands.
The credential suite exercises real systemd cgroups and asserts that no recorded helper identity survives cleanup.
It skips explicitly when the required Linux user manager is absent.

The live entry point is `bin/fm-boat.sh live-smoke --identity <key> --model <provider/model>`.
It refuses without `FM_BOAT_LIVE=1`, serializes one small sandbox, uses the `fm-boat-smoke-` name prefix, and keeps TTL renewals within the original one-sandbox-hour deadline.
It performs two wake/sleep cycles and checked final deletion; an earlier recorded smoke sandbox must be reconciled before another starts.
Provisioning can fail before the provider applies the smoke name; identify that sandbox by the recorded `sandbox_id` from `status`, not by the name prefix alone.
If final cleanup also fails, the smoke reports both its original error and the cleanup error instead of hiding the initiating failure.
Never run paid live smoke as part of the fixture test suite; fixture smoke failure drivers replace the provider, SSH, and credential commands.
