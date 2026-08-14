# RunPod second-mate verification

Audience: maintainer verification.

This record supports the current deterministic guarantees in [`runpod-secondmates.md`](../runpod-secondmates.md).
It records the portable provider and SSH boundary only.
Real provisioning, vendor authentication, and Claude or OMP prompt behavior on a paid pod remain operator smoke tests.

## Portable lifecycle and routing matrix

Verified 2026-08-14 against the stateful RunPod REST double in `tests/runpod-fixture.sh` and the fake SSH boundary in that same fixture.

```sh
bin/fm-test-run.sh tests/fm-runpod-lifecycle.test.sh
bin/fm-test-run.sh tests/fm-runpod-routing.test.sh
bin/fm-test-run.sh tests/fm-runpod-pod-boot.test.sh
bin/fm-test-run.sh tests/fm-runpod-omp-auth.test.sh
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh
bin/fm-test-run.sh tests/fm-remote-doctor.test.sh
bin/fm-test-run.sh tests/fm-remote-job.test.sh
bin/fm-test-run.sh tests/fm-remote-entrypoint.test.sh
bin/fm-test-run.sh tests/fm-secondmate-harness.test.sh
bin/fm-test-run.sh tests/fm-spawn-dispatch-profile.test.sh
```

The recorded lifecycle results are:

```text
ok - ordinary wake cannot replace a failed never-ready paid attempt without acknowledgement
ok - endpoint stalls report provider state and never-ready pods have a guarded recovery path
ok - recover-stuck probes a current-only endpoint and refuses SSH-reachable compute
ok - recover-stuck prints recorded evidence and refuses reachable or SSH-255 ambiguity
ok - stuck recovery never weakens unknown-completion safety after readiness
```

The recorded routing results are:

```text
ok - RunPod remote homes route crews through a Codex primary and predictive Claude fallback
ok - the watcher absorbs suspended RunPod routes on the long dormant cadence
ok - an ordinary remote route keeps its existing liveness probe unchanged
ok - every RunPod remote launch converges its provider-owned crew routing after inheritance
```

The recorded boot, doctor, and harness results are:

```text
ok - the plan clones the code root, makes the account home durable, and prepares unattended shells
ok - login, interactive, and non-interactive pod processes inherit the durable tool PATH and sandbox marker
ok - Claude onboarding, bypass confirmation, and git attribution are preseeded on the volume
ok - replacement pods restore ephemeral prerequisites and reuse the durable toolchain
ok - replacement boot preserves in-home startup symlinks and refuses escaping targets
ok - RunPod parity reports the observed OMP OAuth limitation without failing readiness
ok - the provider-owned RunPod marker crosses the worker child environment
ok - provider-owned RunPod markers cross doctor bootstrap without changing ordinary hosts
ok - C11 crew routing uses the configured fallback only for a supported trigger
ok - C12 malformed crew fallback profiles fail before quota evaluation or launch
ok - sandboxed Claude launches carry IS_SANDBOX and preseed every first-run prompt
```

## Validation boundary

The provider double returns independently modeled `desiredStatus` and `status` fields, delays endpoint publication, records every pod deletion, and retains network volumes separately from pods.
The SSH double separates boot readiness, host-key scanning, and remote command delivery, so a successful provider response cannot stand in for successful SSH bootstrap.
No command above reads a real RunPod key, creates a real pod, or exercises a paid resource.
The precise OMP `EADDRINUSE` root cause remains unverified and requires a future operator reproduction on a live pod.

## OMP broker surface and read-only boundary

Verified 2026-08-14 against installed `omp/17.2.11` at `/home/dnth/.bun/bin/omp`.

```sh
omp --version
omp auth-broker --help
omp auth-broker serve --help
omp auth-broker token --help
nl -ba /home/dnth/.bun/install/global/node_modules/@oh-my-pi/pi-ai/src/auth-broker/discover.ts \
  | sed -n '199p;200p;217p;218p;219p;220p;222p;226p;289p;290p;291p;295p;299p;300p'
nl -ba /home/dnth/.bun/install/global/node_modules/@oh-my-pi/pi-ai/src/auth-broker/remote-store.ts \
  | sed -n '647p;648p;649p;653p;654p;655p;659p;660p;661p;672p;673p;684p;691p;704p;716p;720p'
```

The bounded help output was:

```text
omp/17.2.11
USAGE
  $ omp auth-broker [ACTION] [SOURCE] [FLAGS]
ARGUMENTS
  ACTION   Sub-command (serve|token|login|logout|import|migrate|status|list)
FLAGS
  -b, --bind=<value>      Bind address for `serve` (host:port)
EXAMPLES
    omp auth-broker serve
    omp auth-broker serve --bind=127.0.0.1:9000
    omp auth-broker token
```

The bounded discovery output was:

```text
199     const envUrl = process.env.OMP_AUTH_BROKER_URL;
200     const envToken = process.env.OMP_AUTH_BROKER_TOKEN;
217     const token =
218             (envToken && envToken.length > 0 ? envToken : undefined) ?? configToken ?? (await readTokenFile()) ?? undefined;
219     if (!token) {
220             throw new AIError.MissingApiKeyError(
222                     `OMP_AUTH_BROKER_URL is set (${url}) but no bearer token is available. ` +
226     return { url, token };
289     const store = new RemoteAuthCredentialStore({
290             client,
291             initialSnapshot,
295     const storage = new AuthStorage(store, {
299     await storage.reload();
300     return storage;
```

The bounded mutation-boundary output was:

```text
647     replaceAuthCredentialsForProvider(_provider: string, _credentials: AuthCredential[]): StoredAuthCredential[] {
648             throw new AIError.AuthBrokerError(
649                     "RemoteAuthCredentialStore is read-only on the client. Use `omp auth-broker login <provider>` to mutate credentials.",
653     upsertAuthCredentialForProvider(_provider: string, _credential: AuthCredential): StoredAuthCredential[] {
654             throw new AIError.AuthBrokerError(
655                     "RemoteAuthCredentialStore is read-only on the client. Use `omp auth-broker login <provider>` to mutate credentials.",
659     deleteAuthCredentialsForProvider(_provider: string, _disabledCause: string): void {
660             throw new AIError.AuthBrokerError(
661                     "RemoteAuthCredentialStore is read-only on the client. Use `omp auth-broker logout <provider>` to mutate credentials.",
672     async upsertAuthCredentialRemote(provider: string, credential: AuthCredential): Promise<StoredAuthCredential[]> {
673             const { entries } = await this.#client.uploadCredential(provider, credential);
684     async replaceAuthCredentialsRemote(
691                     await this.#client.disableCredential(entry.id, "replaced by newer credential");
704             const { entries } = await this.#client.uploadCredential(provider, credential);
716     async deleteAuthCredentialsRemote(provider: string, disabledCause: string): Promise<void> {
720                     await this.#client.disableCredential(entry.id, disabledCause);
```

The installed broker uses one bearer allow-list for both reads and writes, so the token itself has no credential-read-only scope.
That evidence is why the RunPod tunnel terminates at `bin/fm-omp-auth-broker-readonly-proxy.mjs` instead of the unrestricted broker port.

The mocked regression suite proves the active boundary without a live pod or network account.
It installs the pod bearer through the boot script's public interface and checks mode 0600, exercises the public remote launch path and OMP pane-launch construction, verifies that credential upload and disable never reach the fake canonical broker, permits broker-side refresh, and forces two SSH drops before confirming a third tunnel attempt with the required keepalive flags.
The live pod end-to-end runbook remains documented in [`runpod-secondmates.md`](../runpod-secondmates.md#live-end-to-end-verification-at-the-next-pod-awake-window) and was not executed because the pod was suspended and waking it solely for validation would incur cost.
