# OMP supervision branch

Fleet supervision on the OMP primary harness runs on a second, persistent conversation - the supervision branch - inside the same OMP process as the captain's chat.
Supervision is default-on: once an OMP primary session owns this home's fleet lock, the branch handles eligible task-local rows from ordinary actionable wakes plus heartbeat scans that the cheap bash-level scan flags as possibly captain-relevant, then merges each outcome back by appending a short note to the captain conversation's tail.
Ordinary main-only rows remain on main even when eligible task-local rows share their queue.
An unresolvable row makes the scan unsafe and returns the whole wake to main, and every watcher-failure alarm also stays on main.
Only captain-relevant branch outcomes open a turn on main - that follow-up turn is itself the captain-visible outcome, so OMP never separately prints or renders a captain-facing merge note.

This is a focused fork of the Pi supervision branch onto OMP's coding-agent SDK.
The bash layer and the dispatch handshake are harness-agnostic and shared with the Pi design unchanged; only the TypeScript extension differs, because OMP's model, effort, session-build, and prompt-cache surfaces differ from Pi's.

This feature is OMP-only by construction and changes nothing anywhere else:

- The branch lives in `.omp/extensions/fm-branch-supervision-omp.ts`, which only an OMP primary ever loads; no other harness gains or loses behavior.
- The bash-side additions (leases, the outcome store, the per-actor wake consume) are inert in a home that never runs the branch: no lease files exist, no actor variable is set, every guard passes silently, and the wake drain takes its byte-behavior-identical pre-branch path with no actor state written.
- It does not change which harness is primary and never moves a home to OMP.

## Components and their owners

- Wake dispatch: `.omp/extensions/fm-primary-omp.ts` is the dispatcher (it emits one offer per ordinary actionable wake to the shared event bus through the watcher core's `offerWakeToBranch` seam); `.omp/extensions/lib/fm-branch-dispatch.ts` owns the offer handshake and row eligibility, while the "Per-actor acknowledgement" section below owns the per-actor consume contract.
  A successful row grant transfers ownership of exactly the currently branch-eligible rows to the branch; a check-kind triggering close (merge-confirmation polls, Relay mentions, credential/auth failures, and every other legitimately main-only class) is never offered even when other rows are eligible, no acceptor (extension absent, away mode, branch broken) keeps today's wake-to-main path for that close, and watcher-failure alarms always go to main because only main can repair the watcher cycle.
  A fleet-wide heartbeat keeps its own all-or-nothing rule (see "Heartbeat routing" below): it takes every branch-ownable unread row or none of them.
- The branch itself: `.omp/extensions/fm-branch-supervision-omp.ts` creates and reopens the persistent branch session, serializes wakes, mirrors dialog, and merges outcomes.
  It checks the current extension generation and `state/.lock` ownership before each guarded branch side effect, so a lost lock or a cold-start re-arm cannot let an old continuation mutate the fleet.
  The branch conversation remains resident across ordinary main turns. When main performs `/new`, `/resume`, `/fork`, or reload, OMP emits `session_switch`; the primary watcher retires the prior generation and re-arms its replacement before the next model turn. The mirror re-anchors when main's session file changes, and any actionable close whose delivery overlaps the replacement is carried to the new generation exactly once. `session_shutdown` remains the terminal-process boundary rather than a replacement signal.
  Every accepted path that cannot reach a working branch rejects its settlement to the shared watcher core, which retains delivery ownership until main consumes the follow-up; a broken branch declines later offers so they take that same watcher-owned path directly.
  While a signal or stale prompt is open, `fm_branch_report` accepts only the task ids resolved from that prompt's granted rows, and refuses `fleet` or remembered task ids; heartbeat reviews remain unscoped.
- Branch model and effort selection: the same extension registers `/supervision-model`, which picks the branch's model and then its reasoning effort over OMP's portable select dialog, and saves both as pins applied at the next branch build, never to the branch already running; [configuration.md](configuration.md#omp-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort) owns the full activation boundary, operator-facing schema, and behavior.
  Model resolution reads OMP's live `ModelRegistry` (available models and their configured credentials) with pure lookups, so pinning the branch never moves main's own conversation; effort uses OMP's `Effort` catalog and the shim's `clampThinkingLevel`.
- Branch system prompt: `bin/fm-branch-prompt.sh`; its header owns the byte-stable-prefix contract (no timestamps, no fleet snapshot, no per-wake content).
- Outcome store: `bin/fm-branch-outcome.sh`; its header owns the append-only format and the read cursor.
  Outcomes are written to the store before any note is handed to OMP, and rows that never reach that handoff replay once through the next locked session-start digest.
- Consistency: `bin/fm-lease-lib.sh` owns the per-task lease contract, the main-only role partition, and the deliberate CONFUSED-AGENT-GRADE threat model these guards target (captain-decided; adversarial-grade separation is out of scope and tracked as follow-up design work); `bin/fm-lease.sh` is the command surface.
  The lease liveness gate reads the ambient coding-agent-context marker `PI_CODING_AGENT`; the Pi runtime sets it natively, and the OMP branch extension sets it at load so the byte-identical bash lease layer recognizes both the main and branch actors under OMP.
  The marker alone does not make an ordinary Pi session contend the branch's command lock: `fm_lease_guard` retains that lock only for an explicit `main`/`branch` supervision actor or a task that already has a lease, so a home that never runs the branch stays inert.
  Both OMP actors claim the reserved `backlog` lease around `tasks-axi` and direct backlog writes, with the branch contract in `bin/fm-branch-prompt.sh` and MAIN's matching contract in `docs/supervision-protocols/omp.md`.
  `bin/fm-pr-check.sh` enforces the task lease at its executable entry boundary before PR metadata or watcher publication changes.

## Transitions and what is out of scope

Ownership transitions happen at a clean boundary: a cold `session_start`, an OMP `session_switch` replacement, or killing the process and letting a fresh one re-arm - never by a synchronous handoff from a live or hung branch.
A branch generation serializes each wake through a clean completion boundary, and the next wake re-prompts the same resident conversation; only the first wake in a fresh process reopens the durable branch conversation.
`session_start` and `session_switch` are the clean-boundary arm points. A `session_switch` replacement re-arms automatically without a foreground watcher command or a model turn; the branch itself remains resident unless the process is restarted.

Three capabilities are deliberately out of scope for this port and are a future iteration:

- Mid-flight branch replacement - displacing a live branch and re-arming a replacement inside the same process. This is distinct from the supported main-session `session_switch` replacement above.
- Mid-branch model or effort hot-swap - the branch keeps its model and effort until a fresh process rebuilds it; a `/supervision-model` change is a pin applied at the next branch build, not to the running branch.
- Hung-branch live takeover - a branch stuck inside a model call is recovered by killing the process (its leases and wake-grant rows go stale on death and are swept), not by main taking ownership away from it.

The reason is structural: OMP coordinates the two in-process actors through shared filesystem locks (the wake-queue lock and the lease-command lock), and the offer handshake and shell-spawn hook still use synchronous subprocess calls with no timeout.
A settlement that tried to displace a live or hung branch would have to acquire the very locks that branch's own in-flight work may hold, so it cannot safely perform a live takeover; the delivery path itself uses awaited subprocesses and does not block OMP's event loop.
Making mid-flight handoff safe needs a fenced, nonblocking rework of that shared lock substrate (which Pi and the rest of the fleet also use), so it is tracked separately rather than shipped here.
A broken or unreachable branch still rejects to the watcher-owned main path with no lost wake; a hung branch stalls its own wake queue until the process is killed, and the durable rows survive to be re-presented on the next start.

## Per-actor acknowledgement

Two LLM actors share one firstmate home inside one OMP process: main (the captain's chat) and branch.
`bin/fm-wake-drain.sh` scopes wake presentation and acknowledgement to the current actor (`bin/fm-lease-lib.sh`'s `fm_lease_actor`).
Main claims every unread row not currently granted to the branch, then drains and acknowledges only that claimed set.
The branch drains and acknowledges only the exact row set the extension granted to it, published to `state/.branch-eligible-rows` under the queue lock immediately before every branch prompt.
`.omp/extensions/lib/fm-branch-dispatch.ts`'s `scopeForUnreadWake` is the single owner of which rows are branch-eligible; the drain never reclassifies a row itself, it only consumes that already-computed snapshot.
A row whose sequence number is not in the branch's snapshot is left completely untouched by a branch-actor drain or acknowledgement, no matter its sequence number, so the branch can never swallow a main-owned row still waiting for main.
An acknowledgement that consumes none of the actor's presented rows reports that fact and names the exact current `--ack-through` and `--recovery-generation` command, so retrying an earlier wake cannot re-fire a stale loop.
This scoping engages only while a branch grant is, or recently was, in play: a home that never runs the branch has none of the actor files, so the drain takes its byte-behavior-identical pre-branch path and writes no actor state.

## Main-fallback re-entry limitation

When the supervision branch is unavailable or rejects settlement, the shared watcher core retains eligible wakes and delivers them to MAIN through the ordinary consumption-acknowledged operational notification path.
Per-actor queue ownership prevents MAIN and the branch from double-consuming a row, but it does not serialize fallback notifications while MAIN handles a claimed, unacknowledged row set.
Each valid higher-sequence signal or stale row can therefore inject another priority operational notification during the same handling episode.
OMP can preempt or skip the report reads, current-state reconciliation, cleanup, or generation-bound acknowledgement that would finish the active episode.
The durable queue preserves every row, but that no-loss property does not guarantee forward progress, so a burst can create a re-entry loop until attended recovery breaks it.

The required coalescing invariant is that MAIN has at most one accepted fallback notification in flight for one active handling episode.
Rows appended during that episode remain durable without injecting another operational turn, and the next drain handles them as one aggregate.
After acknowledgement, exactly one successor notification is delivered only when unread MAIN-owned rows remain, while no successor is delivered when the final acknowledgement consumes them.
Real captain messages retain priority and are never coalesced with operational notifications.
Delivery that fails or has indeterminate acceptance remains replayable without losing a row or duplicating an accepted MAIN turn.

Any fix must preserve per-actor row ownership, branch grants, recovery generations, interruption replay, branch-unavailable fallback, and every existing no-lost-wake boundary.
The bounded attended recovery for the current defect is to interrupt the re-entry episode once, drain the durable notifications, reconcile current state, and execute the printed generation-bound `--ack-through` command.
If unread MAIN-owned rows remain after that acknowledgement, allow the single successor notification and stop repeated manual retries rather than extending the loop.

Issue [#82](https://github.com/dnth/firstmate/issues/82) owns this current-notification re-entry defect and its coalescing regression boundary.
Issue [#74](https://github.com/dnth/firstmate/issues/74) instead owns stale advisory freshness after durable state supersedes prose, where delivery-time reconciliation decides whether an advisory is still current.
Suppressing stale prose for #74 does not prevent a current valid signal or stale row from re-entering MAIN, so the two issues require separate invariants and regression scenarios.
The live observation and missing burst regression are recorded in [runtime-backends.md](verification/runtime-backends.md#omp-main-fallback-re-entry).

## How the branch knows what the captain said

Main's captain and assistant text - never tool calls, tool results, operational injections, or the branch's own merged notes - is mirrored into the branch as read-only `fm-main-mirror` messages at main's turn end, before the next wake is handed over.
The mirror cursor is durable (`state/.branch-mirror-cursor`), so a restart replays only the not-yet-mirrored dialog from main's session file, and a replacement main session re-anchors from its start.
The branch prompt frames mirrored text as context for judgment, never as instructions addressed to the branch; an authorization addressed to main (for example "you may merge when green") does not relax the branch's role limits.

## Two-stage noise filter

Stage one is unchanged: the bash watcher absorbs everything provably fine at zero token cost.
Stage two is the branch's verdict on each handled event, reported through its `fm_branch_report` tool: `routine` merges without a follow-up turn, while `captain` merges with exactly one follow-up turn.
The follow-up turn a `captain` verdict opens is itself the captain-visible outcome, so its merge note is delivered silently and never rendered a second time.
A no-change heartbeat outcome explicitly reported with `task=fleet` and `silent=true` is also delivered silently with no rendered note, while every other `routine` outcome stays rendered with its sailboat prefix.
The verdict criteria in the branch prompt mirror the captain-etiquette escalation list; doubt escalates.
Main can read the durable outcome store on demand through its `fm_branch_outcomes` tool.

## Heartbeat routing

The cheap bash-level heartbeat scan absorbs a genuinely no-op pass before it reaches OMP, unchanged from before.
Only a scan already flagged as possibly captain-relevant emits the bare `heartbeat` wake; `.omp/extensions/fm-primary-omp.ts` flags that offer `heartbeat: true`, and the branch accepts it without a project only when every non-check row observed in the unread-queue eligibility check is either heartbeat-kind or a resolvable task-local signal or stale event.
A heartbeat is never vetoed or ridden into main by a co-present check row: a check row is permanently main-owned and is woken for on that check's own watcher cycle, so nothing starves by being left behind.
What all-or-nothing still guarantees is unchanged: the branch takes every branch-ownable unread row or none of them, and an unresolvable task-local row, an unknown row kind, or an unreadable queue still defers the whole review to main.

## Cost model and the byte-stable prefix

The captain accepted the normal provider prompt-caching strategy: a byte-identical branch prefix generated once per firstmate version, the same tool set in the same order on every request, and one shared per-home cache key for all branch sessions; main keeps its own per-session key.
On OMP the key is pinned through the native `providerPromptCacheKey` option (with `providerPromptCacheKeySource: "explicit"`) at branch-session creation - the authoritative mechanism, cleaner than Pi's `before_provider_request` payload rewrite.
A `before_provider_request` hook that rewrites `prompt_cache_key` is kept only as belt-and-suspenders: it rewrites the key only when the provider payload already carries that field, so it is a harmless no-op otherwise.
OMP's payload exposed to that event carries no `prompt_cache_key` field, so the native option is the sole active path under OMP; the committed live guard does not observe server-side cache-read counts, which OMP does not expose to extensions, so no cache-hit-rate claim is made ([docs/verification/runtime-backends.md](verification/runtime-backends.md) owns the dated verification record).
Reuse is best-effort, never guaranteed; any later dynamic content in the branch prefix silently removes most of the cache benefit, which is why `bin/fm-branch-prompt.sh`'s header is the contract's single owner and the golden test pins the output to byte identity.
The branch can also run on a cheaper model and a shallower reasoning effort than main, both pinned with the `/supervision-model` command (the pin applies at the next branch build, not to the branch already running); [configuration.md](configuration.md#omp-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort) owns those pins' operator-facing schema and unpinned behavior.

## Away mode

Away mode carries over unchanged: while `state/.afk` exists the away daemon owns supervision, and the branch declines every wake offer for the duration.
What is new is only the attended path: outside away mode, the branch absorbs the routine majority that previously interrupted the captain's conversation, applying the same escalation etiquette the daemon applies while away.

## Responsiveness port reconciliation

Upstream Pi change #3767 moves supervision outcome subprocesses off Pi's render thread and serializes delivery so durable append, cursor handoff, and visible delivery remain ordered.
The shared bash contracts, including `bin/fm-supervise-daemon.sh`, did not change in #3767 because the away daemon already runs in its own process and does not block the OMP session event loop.
This fork ports the mechanism into `.omp/extensions/lib/fm-async-exec.ts`, makes the OMP grant-script helpers awaitable, adds the OMP branch's `deliveryChain` around ownership checks, outcome append/handoff, and report delivery, and includes the new helper in `bin/fm-primary-watch-version-lib.sh`'s branch marker hash.
OMP retains synchronous ownership reads only where its offer handshake and shell spawn hook must answer without waiting, while every delivery-side process call rechecks ownership through the awaited path.
The existing watcher-continuity implementation in `bin/fm-primary-watch-core.ts` remains the delivery owner for rejected branch settlements and replacement handoffs; this port does not bypass or duplicate that PR #99 contract.
Pi-only processed-outcome reconciliation and Pi renderer/live-TUI guards have no OMP equivalent and are deliberately omitted; OMP's direct append-and-handoff outcome store is covered by the portable OMP regression and strict OMP typecheck.

## Verification

Portable regressions: `tests/fm-omp-branch-supervision.test.sh` covers prompt byte-stability, outcome store append-only, lease actor partition and guards, wake-grant lifecycle, non-branch-home invariance, and responsive ordered async outcome delivery; `tests/fm-omp-primary.test.sh` rejects an accepted branch settlement into the watcher-owned main path across replacement; and the per-actor consume regression in `tests/fm-wake-queue.test.sh` proves branch-scoped acknowledgement never swallows a main-owned row, main excludes branch-granted rows, and the inert pre-branch path.
The versioned branch-marker closure is covered through `tests/fm-session-start.test.sh`, and the secondmate imported-helper trust boundary is covered through `tests/fm-spawn-dispatch-profile.test.sh`.
The strict typecheck in `tests/fm-omp-branch-types.test.sh` pins the extension against the installed `@oh-my-pi/pi-coding-agent` package and fails on any renamed or removed named export or effort-level drift.
Live guard: `FM_OMP_BRANCH_LIVE_E2E=1 tests/fm-omp-branch-live-e2e.test.sh` exercises the real installed OMP SDK; run it after every OMP upgrade and record the dated result in [docs/verification/runtime-backends.md](verification/runtime-backends.md).
