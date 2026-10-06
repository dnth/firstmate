---
name: operational-home-layout
description: >-
  Agent-only reference for the Firstmate operational-home layout. Load when locating, interpreting, or changing Firstmate home, config, data, state, project, or generated runtime paths, and before touching any state/ file, since it marks which runtime records must never be touched.
user-invocable: false
metadata:
  internal: true
---

# Operational home layout

`docs/configuration.md` owns the top-level layout contract; this listing is the path-level map, and each producing script's header owns exact child fields.

```
AGENTS.md            always-loaded supervisor contract (CLAUDE.md is a real @AGENTS.md pointer to it)
CONTRIBUTING.md      contributor workflow and repo conventions
README.md            public overview and development notes
.github/workflows/   shared CI and PR enforcement, committed
.tasks.toml          tracked tasks-axi markdown backend config for the default backlog backend (AGENTS.md section 10)
.agents/skills/      firstmate-loaded internal skills, committed; each carries metadata.internal=true for installers
.claude/skills       symlink to .agents/skills for claude compatibility
skills/              standalone public installer-facing skills, committed; not loaded by firstmate
bin/                 helper scripts, committed; read each script's header before first use
.env                 optional X-mode pairing token (presence-gates AGENTS.md section 14) and typed dispatch resolution key TYPESAFE_API_KEY (presence-gates bin/fm-dispatch-resolve.sh; docs/configuration.md "Typed dispatch resolution"); LOCAL, gitignored
config/crew-harness  crewmate harness override; LOCAL, gitignored; absent or "default" = same as firstmate. Inherited as the literal file: a concrete primary adapter value also controls a secondmate home's own crewmates (AGENTS.md section 4)
config/crew-harness-fallback  optional predictive crewmate fallback profile; LOCAL, gitignored; format and selection are owned by docs/configuration.md
config/crew-dispatch.json  optional crewmate dispatch profiles; LOCAL, gitignored; firstmate-maintained but human-editable natural-language rules that choose a per-task launch profile (AGENTS.md section 4; schema in docs/configuration.md). Inherited by secondmate homes
config/secondmate-harness  harness the PRIMARY uses to launch SECONDMATE agents, optionally followed by a model and effort token on the same line ("<harness> [<model>] [<effort>]"; AGENTS.md section 4); LOCAL, gitignored; absent or "default" harness falls back to config/crew-harness then firstmate's own. The primary's own setting; NOT inherited into secondmate homes (secondmates do not spawn secondmates)
config/secondmate-harness-fallback  optional primary-to-fallback secondmate profile with the same one-line format; LOCAL, gitignored; quota-aware resolution and metadata are owned by docs/configuration.md and secondmate-provisioning
config/backlog-backend  backlog backend override; LOCAL, gitignored; absent or "tasks-axi" = default tasks-axi backend, "manual" = force routine backlog updates to hand-editing; inherited by secondmate homes (AGENTS.md section 10)
config/backend  runtime session-provider backend override for new tasks; LOCAL, gitignored; absent = falls through to runtime auto-detection (the runtime firstmate itself is executing inside), then tmux; tmux is the verified reference backend (docs/tmux-backend.md), while herdr, zellij, orca, and cmux are experimental spawn backends (docs/herdr-backend.md, docs/zellij-backend.md, docs/orca-backend.md, docs/cmux-backend.md) - herdr and cmux can also be selected by runtime auto-detection, zellij and orca never are (always explicit), and codex-app is not accepted; see docs/codex-app-backend.md; inherited by secondmate homes under the primary-authoritative contract in secondmate-provisioning
config/calm     Pi Calm presentation preference; LOCAL, gitignored, and not inherited; see docs/configuration.md "Pi Calm preference"
config/startup-memory-budget     primary-authoritative per-home startup-memory budget; LOCAL, gitignored, materialized as 7,500 estimated tokens by locked primary bootstrap and inherited into secondmate homes; see docs/configuration.md "Startup memory budget"
config/herdr-presentation-spaces  optional "off" opt-out from Herdr's default-on disposable single-task visual projection; LOCAL, gitignored; inherited by secondmate homes; see docs/herdr-backend.md "Presentation spaces"
config/trace-context  optional presence flag enabling default-off native W3C trace-context propagation to spawned agents; LOCAL, gitignored; inherited by secondmate homes; see docs/configuration.md "Trace context propagation" and docs/trace-context.md
config/cmux-socket-password  optional cmux control-socket password; LOCAL, gitignored; read fresh on every cmux CLI call and passed through without ever overriding an operator's own ambient CMUX_SOCKET_PASSWORD when absent (docs/cmux-backend.md "Setup")
config/treehouse-sweep-clean  optional presence flag enabling bin/fm-treehouse-sweep.sh --apply-clean; LOCAL, gitignored, and not inherited; see docs/configuration.md "Treehouse pool sweep"
config/wedge-alarm  optional away-mode wedge-alarm active-alert directives; LOCAL, gitignored; absent means auto (macOS Notification Center when available); see docs/wedge-alarm.md
config/x-mode.env    generated X-mode watcher cadence; LOCAL, gitignored; source before arming watcher when present
config/ext-bridge    optional presence flag enabling the sibling local Communication Officer bridge; LOCAL, gitignored, and not inherited; see docs/configuration.md "Local Communication Officer bridge"
config/ext-secret    local ext-bridge shared secret; LOCAL, gitignored, mode 0600, not inherited
config/ext-allowlist fail-closed Discord guild/channel/author allowlist for the local ext-bridge; LOCAL, gitignored, not inherited
config/inbox-result-targets  mode-0600 exact Hermes reply-target allowlist for trusted-local inbox results; LOCAL, gitignored, not inherited; see docs/configuration.md "Trusted-local inbox results"
config/runpod.env    RUNPOD_API_KEY for the optional RunPod compute lifecycle beneath a remote secondmate; LOCAL, gitignored, parsed never sourced, not inherited; see docs/runpod-secondmates.md
config/runpod/       generated SSH state plus the mode-600 workstation OMP broker bearer for RunPod-backed remote routes; LOCAL, gitignored, written only by bin/fm-runpod.sh and bin/fm-runpod-omp-auth.sh
data/                personal fleet records; LOCAL, gitignored as a whole
  backlog.md         task queue, dependencies, history
  captain.md         this home's domain-local captain preferences and working style; LOCAL, gitignored, canonical even if harness memory mirrors it, and updated with inspect-then-update
  captain-shared.md  main-authoritative shared captain preferences propagated read-only to secondmate homes; LOCAL, gitignored, owned by secondmate-provisioning
  learnings.md       fleet-local operational facts and gotchas; LOCAL, gitignored; dated, evidence-backed, curated, and updated with inspect-then-update - rewrite and prune rather than append forever, the same contract as captain.md; created lazily, absent until this home has a learning to store
  projects.md        thin fleet navigation registry recording each project's standing delivery posture; firstmate-private, parsed for mechanical sync and seeding by fm-project-mode.sh (AGENTS.md section 6)
  secondmates.md      local and remote secondmate routing table; firstmate-private, maintained by the secondmate seed helpers (AGENTS.md section 6)
  runpod/<id>.meta   authoritative local RunPod placement and lifecycle record for one remote secondmate; firstmate-private, written only by bin/fm-runpod.sh
  <id>/brief.md      per-task crewmate brief, or per-secondmate charter brief when kind=secondmate
  <id>/report.md     scout task deliverable, written by the crewmate; survives teardown
projects/            cloned repos; gitignored; read-only except under hard rule 1's concrete captain-approved project operation exception
state/               volatile runtime signals; gitignored
  <id>.status        appended by crewmates: "<state>: <note>" wake-event lines, not current-state truth
  <id>.turn-ended.<spawn_gen>  per-generation turn-end wake notification, written lock-free by bin/fm-turnend-signal.sh; the consumer (bin/fm-wake-lib.sh, via the watcher) fires only the live incarnation's gen and ignores the rest; teardown removes all gens
  <id>.grok-turnend-token   firstmate-owned grok hook registry token for the task; removed by teardown
  <id>.kimi-turnend-token   firstmate-owned Kimi hook registry token for the task; removed by teardown
  <id>.devin-turnend-token  firstmate-owned Devin hook registry token for the task; removed by teardown
  <id>.devin-config.json  firstmate-owned per-worker Devin config written by bin/fm-devin-config.sh and passed via --config; removed by teardown
  <id>.hermes-turnend-token <id>.hermes-session <id>.hermes-started   firstmate-owned Hermes hook registry token plus the task's stable session id and per-turn start acknowledgement; removed by teardown
  <id>.omp-ext.ts <id>.omp-ready <id>.omp-started <id>.omp-doorbell-ready <id>.omp-doorbell-failed   firstmate-generated OMP task extension plus its session-start and first-turn acknowledgement markers; .omp-ready publishes only after the inbox doorbell activates, and a lost handshake journals its reason to .omp-doorbell-failed (docs/architecture.md; bin/fm-task-inbox-lib.sh); removed by teardown
  <id>.inbox/          durable steering inbox: sequenced firstmate instruction records the worker acknowledges by moving them into its handled/ subdirectory; written by fm-send, re-rung and escalated by the watcher, removed by teardown (bin/fm-task-inbox-lib.sh)
  <id>.stall-recovery  append-only custody and bounded-attempt verdict journal for watcher-triggered stall recovery (bin/fm-stall-recovery.sh); audit evidence, never recovery authority
  <id>.backlog-close  the exact backlog transition a teardown recorded before removing the task's record, so an interrupted cleanup can still be finished at the next session start; bin/fm-backlog-transition-lib.sh owns its format and replay, and a landed transition removes it
  inbox/               trusted-local orchestrator notes written by bin/fm-inbox.sh; pending mode-0600 *.note records move to handled/ on acknowledgement, and failed wake publication leaves the note durable (docs/architecture.md)
  inbox-results/       trusted-local terminal result envelopes and delivery state written by bin/fm-inbox-result.sh; result, posting, receipt, failure, and retry-confirmation records remain mode-0600 across restarts (docs/architecture.md)
  <id>.meta          written by fm-spawn: window=, endpoint_task_id=, worktree=, project=, harness=, model=, effort=, kind=, mode=, yolo=, tasktmp=; optional grok_turnend_dir=, kimi_turnend_dir=, and devin_turnend_dir= persist harness registry ownership for teardown; optional prewalk_into= records an effective OMP Prewalk target; optional allow_project_omp_extensions=1 records explicit approval for tracked project extensions on an OMP launch (docs/configuration.md "OMP project extensions"); an optional traceparent= only when trace context is enabled (docs/configuration.md "Trace context propagation"); kind=secondmate also records home= and projects=, plus remote_host=/remote_root=/remote_backend=/remote_herdr_session=/remote_target= for a remote route; a non-default runtime backend records further backend-specific fields (docs/configuration.md "Runtime backend"; bin/fm-backend.sh, AGENTS.md section 8); fm-pr-check, including through fm-pr-merge, records one canonical pr= and the forge's pr_head= when available (GitHub pull requests and GitLab merge requests; docs/gitlab-merge-watch.md); fm-x-link appends x_request=, x_request_ts=, x_followups=, and optional x_platform=/x_reply_max_chars= for an X-mode-originated task (AGENTS.md section 14)
  <id>.herdr-presentation  quarantinable attempt and restart-binding journal for Herdr's optional visual projection; never task or endpoint authority; see docs/herdr-backend.md "Presentation spaces"
  <id>.check.sh      authenticated slow poll; the watcher dispatches validated PR data and the byte-identified X shim through trusted repository scripts, runs registered custom checks from hash-validated private snapshots, and rejects every other state check without execution
  <id>.check-trust   private content binding created by fm-check-register.sh for an intentional custom check
  <id>.pr-poll       private validated data sidecar for the byte-static PR merge poll
  <id>.pr-poll-registration  private transactional provenance record binding the task, canonical metadata identity, sidecar, and static poll publication
  <id>.pr-poll-retirement  private identity-bound crash-recovery receipt for one exact validated merged result; removed after its poll artifacts retire
  <id>.pr-poll-merge-notified  canonical PR identity of the last merge outcome delivered for this task; bin/fm-pr-lib.sh owns the marker format and identity mechanics, while bin/fm-merge-outcome-lib.sh owns locked publication, duplicate suppression, and replacement; removed by teardown
  x-watch.check.sh   generated X-mode relay poll shim; present only when opted in (AGENTS.md section 14)
  ext-watch.check.sh generated local Communication Officer poll shim; present only when the ext-bridge is opted in
  pending-replies/   parent-owned secondmate pending-reply records (correlation id, delivery vs reply, recovery, escalation); fm-pending-reply-lib.sh
  remote-replies/    remote-secondmate reply cursors, per-capture ingest receipts, private rejected-line quarantine, continuity pins, and automatic-handling failure counters; written by fm-procevent-remote-reply.sh
  procevent/         registered process-to-event sources, one private record per canonical source id; written by bin/fm-procevent.sh or an adapter through the shared registration publisher, and their presence alone keeps supervision required (see `process-event-sources`)
  procevent-inbox/   private captured results and their durable handled-acknowledgement markers; source output lives here and never in an event line
  decision-bindings/ private bindings from a captured-answer source id to the captain-hold origin its keyed answers close (or `(any)` for task-id-keyed channels); written only by bin/fm-captain-hold.sh bind, dropped by unbind and by source retirement (see `captain-hold-lifecycle`; docs/captain-hold-lifecycle.md)
  reconcile-requests/ private pending board-created reconcile requests, one record per captain-held task id; written only by bin/fm-captain-hold.sh reconcile-requests and retired by answer or reconcile close/note (docs/captain-hold-lifecycle.md)
  decision-cards/    durable fm-decision-card.v1 board cards per captain-held task id; written only by bin/fm-bearings-board.sh build (docs/captain-hold-lifecycle.md)
  captain-hold-steers/ private per-answer delivery markers deduping the keyed-answer intake's fm-send steer; written only by bin/fm-captain-hold.sh answers (docs/captain-hold-lifecycle.md)
  when/              private condition->action watch specs, their trust bindings, and single-fire markers; written only by bin/fm-procevent-when.sh (the `process-event-sources` skill's trigger)
  x-inbox/           generated X-mode pending mention payloads; fmx-respond drains it (AGENTS.md section 14)
  x-context/         generated X-mode durable per-request reply context and one-wake offer markers, keyed by request_id; survives inbox cleanup and expires within seven days (AGENTS.md section 14; bin/fm-x-lib.sh)
  x-outbox/          generated X-mode dry-run reply and dismiss previews; inspect it when FMX_DRY_RUN is set (AGENTS.md section 14)
  ext-inbox/         generated local Communication Officer pending request payloads; ext-respond drains it when the ext-bridge is on
  ext-context/       generated local Communication Officer destination context and one-wake offer markers, keyed by request slug
  ext-outbox/        generated local Communication Officer outbound ack/answer/followup/final payloads plus posting markers, receipts, terminal-failure markers, and chunk-progress records
  public-followup/   generated private transport for promised public replies: commitment registrations, typed terminal-result inbox, accepted/rejected ledgers (AGENTS.md section 14; bin/fm-public-followup.sh)
  x-poll.error x-poll.claim-error  generated X-mode relay and offer-claim diagnostic dedupe markers
  .wake-queue        durable queued wakes retained until post-handling acknowledgement: epoch<TAB>seq<TAB>kind<TAB>key<TAB>payload
  .watcher-down      private generation-bound recovery state coupling watcher downtime, durable wake presentation, and post-handling acknowledgement; never touch
  .watcher-down.resurface  private unacknowledged-announcement streak sidecar ("count<TAB>first-unacked-epoch<TAB>surfaced") bounding and deduplicating the downtime resurface; deleted by the generation-bound acknowledgement; never touch
  .omp-primary-extension-loaded  this home's OMP primary adapter identity marker; published by the adapter, validated by fm-session-start.sh, never hand-edited (docs/configuration.md "Harness support")
  .<id>.open-decisions-cursor  per-task byte cursor and folded open-decision set bounding the OPEN DECISIONS scan's cost to new status-log appends; written only by fm-classify-lib.sh's status_open_decisions_incremental, removed by teardown, safe to delete (forces one full re-fold)
  .status-presentation-cursor .status-presentation-lock  fleet-wide per-task status identity/byte-offset manifest (including the separate STATUS OUTCOME BACKSTOP delivered-frontier offset) and serialization lock preventing already-presented status lines from being replayed as new; owned by fm-classify-lib.sh, with each task's row retired by teardown
  .runpod-lifecycle-<id>.lock  per-secondmate RunPod provider lifecycle lock; never touch
  .<id>.pr-publication.lock  per-task PR registration transaction lock held by fm-pr-check.sh while it publishes poll artifacts and replaces pr=/pr_head=/nm_run_id=; fm-watch.sh defers a pre-metadata poll only while it is fresh; never touch
  runpod-omp-auth/  workstation OMP broker, read-only facade, and per-pod tunnel supervisor records and logs; never touch
  .afk               durable away-mode flag; present = sub-supervisor may inject escalations (set by /afk, cleared on user return)
  .watch.lock .wake-queue.lock watcher singleton and queue serialization locks
  .claude-autoarm.lock .claude-autoarm-epoch .claude-autoarm-failure-notified .claude-autoarm-failure-alarmed .turnend-claude-blocks .turnend-claude-blocks.lock   Claude Stop auto-arm single-flight, epoch, failure-episode, attended-alarm, guard-budget, and budget-lock records; never touch
  .hash-* .count-* .stale-* .stale-since-* .paused-* .wedge-escalations-* .writing-* .seen-* .hb-surfaced-* .last-* .heartbeat-streak   watcher internals; never touch
  .watch-triage.log  watcher's absorbed-wake debug log (size-capped); never relied on, safe to delete
  .last-watcher-beat watcher liveness beacon, touched every poll (including while absorbing benign wakes); guard scripts and parent secondmate supervision read it
  .subsuper-* .supervise-daemon.*   sub-supervisor internals; never touch
.no-mistakes/        local validation state and evidence; gitignored
```
