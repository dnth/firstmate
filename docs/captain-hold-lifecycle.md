# Captain-hold lifecycle mechanism

The normative policy is owned by `.agents/skills/captain-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, compatibility contract, and privacy-safe regression evidence.
It was ported from upstream firstmate's `docs/captain-hold-lifecycle.md` for the collapse of the separate decision concept into captain-held tasks; where this fork's machinery differs from upstream's, the section says so explicitly.

## Mechanism

A decision is not a separate thing in this system: it is an ordinary backlog task held for the captain, and the task id is the identity every surface and channel uses.
`bin/fm-captain-hold.sh` is the only lifecycle command layered on that primitive.
The command addresses the active home's configured data directory through `bin/fm-tasks-axi.sh` and the transition library, so the existing backlog remains the only durable work database and a secondmate-owned captain call stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand is the mandatory captain-hold creation path: it uses an existing task or creates one when nothing exists to hold, records its UTC hold-set timestamp as the leading line of the task body, then invokes the underlying tasks-axi hold operation and verifies both records.
Publishing the stamp first ensures a snapshot cannot observe a newly captain-held task without the timestamp that defines its age.
Retries of an active hold preserve its hold-set timestamp, while re-holding released work starts a new timestamped lifecycle; a closed task is refused rather than reopened, and `--until` stores the captain's own deferral date through tasks-axi's date gate.

The `answer` subcommand records the captain's exact words and resolves the call in the same act: it closes a question-shaped call, while `answer --release` frees a captain-gated work item to proceed without completing it.
It requires a non-empty captain decision file of at most 8192 bytes, durably writes a resolution block carrying the decision digest and a `Resolution mode:` while retaining the leading hold-set stamp until the selected `tasks-axi done` or `tasks-axi unhold` transition succeeds, then restores the successful record's resolution-first body ordering (the previous body remains preserved below the block and archived through tasks-axi `--archive-body`).
If the close is interrupted, the still-held task therefore keeps its original age basis.
A matching retry also completes any resolution-first normalization left unfinished after the close itself succeeded.
An exact retry is idempotent only when the requested close mode matches the newest record; a drifted answer or mode mismatch is rejected, while a re-held task accepts a new answer as a new record on top.
On a task closed outside the script, `answer` records the missing block only when the captain-hold annotations tasks-axi preserves through a close prove the captain owned it, and it verifies the task stays closed.
A hold whose `--until` date has passed keeps those annotations while tasks-axi reports it no longer held, so an expired deferral remains answerable.

The `complete` subcommand unions the reviewed captain-held task ids into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable tasks without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, refused while the origin still has a lifecycle-open keyed status decision, and verifies every listed task against tasks-axi before recording completion.
A status-side keyed decision that is still open but covered by no inventoried task refuses completion rather than being marked transferred, preserving this fork's stricter inventory-membership check from the retired `fm-decision-hold.sh`.
With a non-empty inventory it appends a `captain-held [key=<key>]` transfer event naming the reviewed inventory for every still-open keyed status decision, which `bin/fm-classify-lib.sh` recognizes as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the read-only `verify` subcommand after checking for the report and before removing any source state.
`verify` requires the recorded attestation, requires every recorded inventory entry to still be durable (actively captain-held, or carrying a recorded answer), and fails on any keyed status decision that opened after the last `complete`, which makes re-running `complete` the repair.
The `--force` path remains the explicit captain-approved discard escape hatch.

## Cleanup and captain calls

Upstream additionally integrates the pending-close transition machinery (`bin/fm-backlog-transition-lib.sh` close markers, replay, and retain) into `fm-teardown.sh` so an automatic backlog close can never silently retire an open captain call.
This fork's teardown never transitions backlog rows itself - it prints a backlog-refresh reminder and the captain-facing `tasks-axi done` is a separate deliberate act - so no retain guard was needed; the transition library is ported for `fm-captain-hold.sh`'s own backend addressing and marker reads only.
If this fork's teardown ever learns to close rows automatically, adopt upstream's retain wiring rather than re-deriving it.

## Answer-time resolution

"A keyed answer resolves its matching captain-held task" is one capability with one owner.
`answers` is its channel-agnostic entry point: it reads `<task-id>\t<answer>\t<label>[\t<mode>]` lines and resolves each named task through the same `answer` path, so every guard applies identically no matter which channel the answer arrived on.
The optional mode column carries a card-declared close: `done` (default) completes the task and `release` lifts the hold so held work resumes; any other value is skipped.
A key that names no task, names a task that is not captain-held, or names a task already closed is reported as `skipped:` and feeds nothing; a replay whose answer and requested close mode match the newest record is an idempotent `closed:`, while a mode mismatch is skipped; and the command exits nonzero when any key was skipped or a required steer failed.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch.
The Captain's Deck Herdr plugin calls this entry point directly as `answers --source <provenance>`; its answer keys are the captain-held task ids it read from `decisions_open`.
After a key closes, `answers` also steers the owning task through `bin/fm-send.sh` so the captain's words reach the worker as a durable inbox record plus the ordinary doorbell: the owner is the recorded `Origin:` task when the call was minted for another task's review, else the legacy `<origin>-decision-<key>` prefix, else the held task itself, and the first candidate with `state/<id>.meta` wins.
A close with no live owner reports `steer-skipped:`; an fm-send failure after the durable close reports `steer-failed:` and fails the command so the caller retries the same keyed line; fm-send's durable-but-unproven verdicts report `steer-deferred:` because the record exists and the watcher's re-ring ladder owns redelivery.
Each steer message carries a `steer-<digest>` token inside the inbox record, so a replayed keyed line is deduped by the inbox itself (with `state/captain-hold-steers/` as the fast path) and can never double-deliver.
`--no-steer` is the explicit internal exception for a channel that already delivered the answer itself: `bin/fm-send.sh --resolve-key` passes it on its feed so a chat answer lands in the worker's inbox exactly once.

`bind`, `unbind`, and `binding` record that a captured-answer source feeds this intake, as a private record under `state/decision-bindings/`; an unbound source feeds nothing, so the path is opt-in per source, and `bind` deliberately does not require the source to exist yet.
`bind <source-id>` with no origin records an any-origin binding for channels whose keyed lines already carry full task ids.

Three channels feed that one intake today, and all are ordinary callers rather than special cases.
`bin/fm-send.sh --resolve-key` is the chat channel: its status-log close for a key the status log still owns is owned by that script's header, and a key the status log no longer owns is resolved to a still-open captain-held task - the key as a task id, then the legacy derived identity - and fed as one keyed line.
`bin/fm-procevent.sh` is the captured-result channel: after capture, a bound source has its result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>` and whatever that prints is piped into the intake, so any adapter with an `answers` command works and the runner names no adapter, parses no result, and carries no decision rule.
The Captain's Deck plugin is the third: it writes keyed lines itself and calls `answers` directly.
`bin/fm-procevent-lavish.sh answers` is the adapter command for the board; it reads only rows tagged `choice`, relays a card's declared close mode, and can never let freeform captain prose forge a task id or a mode.

## Reconcile: re-check reality, never a blind close

A captain call can stop being a question without the captain ever answering it because the subject lands, the premise turns out to be false, or the choice becomes a matter of fact rather than the captain's to make.
`reconcile` is the standing third option for that case, and its whole point is that it is NOT an answer.
It means "go verify the latest state", and it resolves in exactly one of two ways once that verification has actually been done: close the call with the evidence that made it moot, or leave it open with a note recording that it is genuinely still active.

The value remains reserved at the shared keyed-answer intake, which visibly refuses it from every channel and never passes it to `answer`.
A reconcile value delivered through chat or any ordinary keyed-answer caller therefore cannot complete a task, lift a hold, write a resolution record, or create a reconcile request.

Request creation uses a separate intake, `reconcile-requests --source-id <id> --source <provenance>`, which verifies the named source's binding and the local captain-held task before filing a durable request under `state/reconcile-requests/`, one private record per task, carrying the requesting provenance and a UTC timestamp.
The record exists so the obligation to re-check cannot be lost between the wake that carried the request and the turn that acts on it.
It is idempotent per task: repeating a reconcile keeps one request and its original timestamp.
The supported creators are the process-event runner carrying a board's Reconcile selection (`bin/fm-procevent-lavish.sh reconciles` emits the selected task ids) and the Captain's Deck plugin, which calls the same intake directly.
A remote-secondmate card whose task is absent from the main backlog remains announced but cannot create a main-home request; owner-aware request routing to the authoritative secondmate home is a separate follow-up.

Verification retires a request through one of two outcomes, and each one requires both the pending board-created request and the operator input that supports its claim:

- `reconcile close <task-id> --evidence-file <path>` is the moot outcome.
  It writes a resolution record whose mode is `reconciled` and whose body is the supplied EVIDENCE under a `Reconciliation evidence:` label, then closes the task.
  The distinct mode and label are what keep the record honest: it says the call dissolved against verified evidence, and it never claims the captain answered.
- `reconcile note <task-id> --note-file <path>` is the still-active outcome.
  It appends one dated `Captain hold reconciled:` note to the task body, leaves the hold in place, and retires the request.
  The call stays the captain's, now carrying what the re-check found; a marker bound to the request timestamp, provenance, and note digest lets a matching retry finish retirement without appending again while a later request with the same finding still receives its own dated note.

`reconcile list` is the read-only enumeration of pending requests.
A successful normal answer also retires any pending request, because an answered call has no remaining re-check obligation.
Every retirement is checked: if request removal fails after an answer, close, or note is already durable, the durable outcome stands but the command fails and leaves the pending request visible for retry.
No path here closes a captain call without either the captain's words through `answer` or the evidence through `reconcile close`.

## Card hygiene: a landed subject is not a live call

`bin/fm-bearings-board.sh build` cross-checks every `decision` card before it publishes and drops stale subjects rather than trusting the composed inventory alone.

Three checks run, all on exact identity and none on prose:

- The card's key is the captain-held task id, so `bin/fm-captain-hold.sh open --distinguish-absent` is asked whether that task is still an open captain call.
  Exit 1 - present but closed, or no longer held for the captain - drops the card.
  Exit 2 means the answer could not be established and exit 3 means the task is absent from the main backlog, which includes a home carrying no backlog file at all; both keep the card, because a card wrongly shown is recoverable and a call wrongly hidden is not.
- The payload's own `landed` rows are the recently-landed artifacts.
  A decision card whose task id or `pr_url` appears among them has already shipped its subject, so it drops.
- A version decision can carry a structured `subject` with an artifact and numeric three-part version.
  A landed row carrying the same artifact at that version or a newer one supersedes the card without parsing prose.

Dropped cards are named on stderr as `dropped-landed-card:` lines so a rebuild states what it removed rather than quietly shrinking Captain's Call.
A subject whose state cannot be established is kept, because a wrongly shown card is safer than a wrongly hidden call.

The build additionally writes every surviving `captains_call` card to `state/decision-cards/<task>.json` as an `fm-decision-card.v1` record.
This fork-local store is the durable card lookup the Captain's Deck plugin reads when the live `.lavish/bearings-board.html` payload is absent.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)`, `(hold-kind: ...)`, and `(hold-until: ...)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records and keeps missing blockers unresolved.
`captain_actionable` - waiting on the captain now - requires `state` queued, `kind` and `hold_kind` captain, a hold reason, no unresolved blockers, and no still-future `hold_until`.
Hold reason and body prose are never matched, so no wording can hide, reveal, or reclassify a decision.

`bin/fm-bearings-snapshot.sh` places each captain hold from those structured fields only and inspects no prose of its own.
An actionable hold is a default Captain's Call entry carrying `title`, `reason`, and `summary` fields.
A hold with a pending `state/reconcile-requests/<task>.request` record leaves Captain's Call and renders as a Charted Next gate reading `reconcile requested <timestamp>` until the request is retired.
A still-future `hold-until` hold does the same as a `deferred until <date>` gate and returns to Captain's Call once its date passes.
Upstream's fuller `hold_bucket` projection (`blocked`/`dated`/`aged`/`live`) is not ported; this fork's bucketing covers blocked (unresolved blockers leave a hold unactionable in Charted Next), dated, and reconcile-requested placement, and has no age-based `aged` bucket.
`--all-decisions` reveals every open decision within the bounded projection.

Re-holding through the wrapper with `--until` remains the durable deferral.

## Legacy identity compatibility

`bin/fm-decision-hold.sh` remains as a transitional shim mapping the retired verb surface (`id`, `hold`, `complete`, `verify`, `resolve`, `answer|decline|repair`, `answers`, `bind`, `unbind`, `binding`) onto `bin/fm-captain-hold.sh`; its header owns the exact mapping.
Legacy `<origin>-decision-<key>` backlog rows are ordinary tasks and stay answerable through every path: `answers` resolves an exact task id first and the derived legacy identity second, `open`/`verify`/`complete` accept either identity shape, and a replayed keyed answer stays idempotent because both the current and the pre-collapse record text are digest-recognized.
`tests/fm-captain-hold-lifecycle.test.sh` carries the synthetic-fixture evidence.
