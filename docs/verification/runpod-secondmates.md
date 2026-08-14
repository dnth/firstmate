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
bin/fm-test-run.sh tests/fm-remote-doctor.test.sh
bin/fm-test-run.sh tests/fm-remote-job.test.sh
bin/fm-test-run.sh tests/fm-remote-entrypoint.test.sh
bin/fm-test-run.sh tests/fm-secondmate-harness.test.sh
```

The exact new lifecycle results are:

```text
ok - ordinary wake cannot replace a failed never-ready paid attempt without acknowledgement
ok - endpoint stalls report provider state and never-ready pods have a guarded recovery path
ok - recover-stuck probes a current-only endpoint and refuses SSH-reachable compute
ok - recover-stuck probes recorded-only endpoints and refuses reachable or indeterminate results
ok - stuck recovery never weakens unknown-completion safety after readiness
```

The exact new routing results are:

```text
ok - RunPod remote homes route crews through a Codex primary and predictive Claude fallback
ok - the watcher absorbs suspended RunPod routes on the long dormant cadence
ok - an ordinary remote route keeps its existing liveness probe unchanged
ok - every RunPod remote launch converges its provider-owned crew routing after inheritance
```

The exact new boot and doctor results are:

```text
ok - login, interactive, and non-interactive pod processes inherit the durable tool PATH and sandbox marker
ok - Claude onboarding, bypass confirmation, and git attribution are preseeded on the volume
ok - replacement pods restore ephemeral prerequisites and reuse the durable toolchain
ok - RunPod parity reports the observed OMP OAuth limitation without failing readiness
ok - the provider-owned RunPod marker crosses the worker child environment
ok - provider-owned RunPod markers cross doctor bootstrap without changing ordinary hosts
ok - C11 crew routing uses the configured fallback only for a supported trigger
```

## Validation boundary

The provider double returns independently modeled `desiredStatus` and `status` fields, delays endpoint publication, records every pod deletion, and retains network volumes separately from pods.
The SSH double separates boot readiness, host-key scanning, and remote command delivery, so a successful provider response cannot stand in for successful SSH bootstrap.
No command above reads a real RunPod key, creates a real pod, or exercises a paid resource.
The precise OMP `EADDRINUSE` root cause remains unverified because the task explicitly prohibited waking the suspended live pod.
