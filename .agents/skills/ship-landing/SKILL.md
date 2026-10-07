---
name: ship-landing
description: >-
  Agent-only procedure for PR-ready, landing, and cleanup. Load on every PR-ready or ready-branch signal before reporting it, when deciding or monitoring landing, before writing or retiring a custom state check, and before any task teardown or secondmate retirement.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.
On every PR-ready signal, immediately run `bin/fm-pr-check.sh <id> <PR url>` before reporting the result - it owns the PR-ready gates, metadata publication, and merge-poll arming, while lock-owning reconciliation through `bin/fm-todo-project.sh --check --reconcile` is the recovery backstop for a skipped arm.
When it refuses, relay its named reason (missing criteria, a run on another branch or PR, a head the pipeline did not validate, an unfinished run, or an unmatched ask-user decision) and steer the worker or decide the finding; never hand-edit task metadata to pass it.
Tell the captain the PR's full URL, always the complete `https://...` link rather than a bare `#number`, a concise outcome summary, and the observed CI result when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
For a remote second mate's PR, follow the [primary-owned landing procedure](../../../docs/remote-secondmates.md#landing-owner) before releasing its finished worker at PR-ready; the ordinary teardown proofs still apply.
On the captain's merge word for such a PR, use the primary's landing id with `bin/fm-pr-merge.sh` (its header owns the invocation); relay any custody refusal and use only the captain's exact words for an override.
Never run `bin/fm-pr-check.sh` on a second mate's own id; it refuses.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, re-evaluate queued work whose blockers and time gates have cleared, and re-project the session todo as section 10 requires.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
