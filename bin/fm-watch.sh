#!/usr/bin/env bash
# Usage: fm-watch.sh
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes.
# The no-verb signal and stale path is absorb-only-on-positive-evidence: a wake
# is absorbed only when the crew shows it is still working through an actively
# running no-mistakes step or a backend busy signal. A home that opts in with
# config/turnend-churn-absorb lets a bare turn-end also use bounded pane churn
# since the previous poll. Every other no-verb wake surfaces, so a crew
# that finishes (or stops and waits) is never silently swallowed. A declared
# external-wait pause is the separate idle absorb case and re-surfaces only on its
# long bounded cadence, although its initial no-verb status signal still surfaces
# in normal mode.
# While state/.afk exists, the daemon owns triage and this watcher queues and exits
# on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal lacks
#                          positive execution evidence, unless afk is active
#   stale: <window>        a provably-working stale is ALWAYS absorbed (with a wedge
#                          timer) regardless of what the status log says - an active
#                          run-step or busy pane outranks even a captain-relevant log
#                          line, since the crew's own log gets no new entry once
#                          firstmate hands it to a no-mistakes validation. A declared
#                          external-wait pause is absorbed instead with its own long
#                          re-surface cadence, never as a wedge. Only when neither
#                          absorb class applies does the log's last line decide:
#                          terminal (captain-relevant) or non-terminal (no verb),
#                          both surfaced at once. A provably-working stale past the
#                          wedge threshold also surfaces, with an "escalation N"
#                          count in the reason; at FM_WEDGE_DEMAND_INSPECT_COUNT
#                          consecutive escalations on the SAME pane, the reason
#                          also carries a "demand-deep-inspection" marker so the
#                          wake payload itself, not just repetition, forces a
#                          closer look instead of another routine supervision
#                          resume. Unless afk is active. A pane whose own task
#                          worktree was written during the quiet window is
#                          deferred rather than escalated (wedge_defer_writing),
#                          because files appearing there are liveness the pane and
#                          the run step cannot show; that deferral still
#                          re-surfaces once per PAUSE_RESURFACE_SECS, and a pane
#                          that writes nothing keeps the unchanged schedule
#                          subject to the decision and captain-hold deferrals
#                          owned by docs/configuration.md.
#                          A genuinely busy pane
#                          (window_is_busy true) is exempt from the above, but
#                          only up to BUSY_TURN_MAX_SECS with no completed turn
#                          (the live generation's state/<id>.turn-ended.<spawn_gen>,
#                          or the spawn record before any
#                          turn completes). Past that bound, a declared external
#                          wait or verified captain-held transfer uses the long
#                          pause recheck cadence, and, in a home that armed
#                          config/wedge-defer-parked-gate, so does a validation
#                          gate of the crew's own awaiting the supervisor's
#                          still-unanswered decision for that run; every other
#                          pane goes through the same wedge timer and surfaces
#                          with the identical "stale: ..." reason, escalation
#                          count, and demand-deep-inspection marker, for human
#                          inspection only - never an automatic interrupt,
#                          signal, or restart of the worker or its tool process.
#                          The separate steering-inbox path invokes
#                          fm-stall-recovery.sh before publishing its stale wake;
#                          that helper owns its custody-checked, bounded relaunch
#                          exception for a positively missing endpoint only - a
#                          live worker is never interrupted and escalates here.
#                          An idle secondmate that is neither paused nor captain-held
#                          is also absorbed while its home watcher beacon is fresh
#                          within the wedge threshold; conclusive stale evidence
#                          follows the ordinary stale and possible-wedge path.
#                          Inconclusive remote evidence uses the consecutive-probe
#                          bound documented below. A RunPod route in a recognized
#                          no-host lifecycle is dormant instead and uses the long
#                          pause cadence without probing its absent endpoint.
#                          A stale escalation whose endpoint is covered by an
#                          open captain call linked through
#                          bin/fm-captain-hold.sh backs off instead of firing
#                          once per cycle: the first episode still escalates at
#                          once, later reminders double up to a cap, each
#                          suppressed repeat is counted and logged, and the next
#                          reminder names the folded count. docs/configuration.md
#                          "Linked captain-decision backoff" owns the contract;
#                          held_alert_tick and held_alert_release_tick own the
#                          mechanics.
#   check: <script>: <out> authenticated check output, always actionable
#   check: open decision overdue: <task> key=<key> age=<seconds>s
#                          opt-in config/open-decision-reminders backstop;
#                          open_decision_reminder_tick owns persisted backoff
#   check: process-event result captured: <keys>
#                          a durably captured process-to-event result is queued
#                          and has not been surfaced yet; reported once per
#                          captured generation, never again while that record
#                          stays queued and never once it is acknowledged
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   check: no-mistakes task <id> has open PR <url> but no No-Mistakes run on <branch>
#                          an open PR exists without a branch run, indicating
#                          a possible worker bypass of pipeline PR creation;
#                          bin/fm-nm-pr-guard.sh is the prevention gate
#                          and this is the detection backstop. One wake per
#                          task and PR while the branch has no run.
#   check: secondmate wake-loop stalled: mate=<id> row=<seq> idle=<seconds>s
#                          an actionable row in an endpoint-recorded local
#                          secondmate home's durable wake queue did not advance
#                          between observations for FM_SECONDMATE_WAKE_STALL_SECS
#                          while the mate was not in an active turn; declared
#                          external-wait pause rows do not feed this escalation,
#                          observation is read-only, and one parent notification
#                          covers each no-progress episode
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# One alert that is NOT a printed reason: main_wake_undelivered_tick fires a
# wedge alarm through the channels in docs/wedge-alarm.md when the oldest
# main-owned durable wake row stays unpresented for
# FM_MAIN_WAKE_UNDELIVERED_ALARM_SECS (default 300s) - read-only, once per
# oldest-row episode, and skipped while state/.afk hands delivery to the
# away-mode daemon.
# FM_WATCH_REMOTE_TIMEOUT bounds each remote beacon probe in seconds, accepts
# integers from 1 through 15, defaults to 5, and falls back to 5 when invalid;
# probes prefer timeout, then gtimeout, then a Perl fallback. The timeout tools
# force-kill after one additional second when TERM is ignored. Perl starts the
# probe in its own process group, sends TERM at the bound, and sends KILL after
# a 0.2-second grace. With none of those tools, the probe returns missing evidence.
# A remote probe is either conclusive (a numeric beacon age, fresh or stale) or
# inconclusive (deadline hit, no answer, non-numeric output, or no deadline tool).
# Inconclusive evidence is never a stale verdict by itself: a slow SSH round trip
# on a healthy host is normal. Consecutive inconclusive probes are counted per
# route in state/.remote-inconclusive-<key>, and only
# FM_REMOTE_INCONCLUSIVE_MAX of them (positive integer, default 3, also used
# for invalid values) enter the ordinary stale path.
# A conclusive stale age, or a live fresh age, resets the
# count and takes its own path immediately.
# For normal supervision, resume the session-start primary-harness protocol
# after each printed reason. Direct duplicate invocations of this script still
# no-op through the watcher singleton lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
mkdir -p "$STATE"

# The native event fast-path and only its true dependencies have one narrow
# production owner. The Herdr event-wait smoke test consumes this same owner
# without sourcing the entire watcher graph.
# The shared transition owner is a canonical lint root itself. Stop duplicate
# source-graph expansion here: following its backend graph from this large
# runtime can exceed the bounded CI lint worker while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-push-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# Single owner of durable merge-outcome publication, shared with
# bin/fm-pr-merge.sh so self and poll origins use the same role-routed outcome.
# The watcher still owns immediate delivery of its actionable poll result and
# poll retirement.
# This library is a canonical lint root in its own right, and it reaches the
# wake queue, PR identity, and secondmate parent libraries. Keep it an analysis
# boundary here for the same reason as the transition and inbox owners above and
# below: following its graph from this large runtime exceeds the bounded CI lint
# worker while adding no uncovered file.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-merge-outcome-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"
# Unanswered Communication Officer requests: which request
# is overdue, the reminder cadence, and the ack-only-with-live-task exemption.
# shellcheck source=bin/fm-ext-overdue-lib.sh
. "$SCRIPT_DIR/fm-ext-overdue-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# No-Mistakes run attribution primitives (bounded axi calls, TOON field reads),
# shared with fm-crew-state.sh, fm-teardown.sh, and fm-pr-check.sh. The
# nm_pr_unguarded_tick backstop reads a task's run existence through this owner.
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# Reminder scanning must not treat the secondmate's parent reply channel as its own work.
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-compute-lib.sh
. "$SCRIPT_DIR/fm-compute-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# Wedge-alarm channel resolution and delivery for the undelivered main-wake
# alarm (docs/wedge-alarm.md).
# shellcheck source=bin/fm-wedge-alarm-lib.sh
. "$SCRIPT_DIR/fm-wedge-alarm-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
ON_BIN=${FM_ON_BIN:-$SCRIPT_DIR/fm-on.sh}
REMOTE_TIMEOUT=${FM_WATCH_REMOTE_TIMEOUT:-5}
case "$REMOTE_TIMEOUT" in
  ''|*[!0-9]*|0) REMOTE_TIMEOUT=5 ;;
  *) [ "$REMOTE_TIMEOUT" -le 15 ] || REMOTE_TIMEOUT=5 ;;
esac
REMOTE_INCONCLUSIVE_MAX=${FM_REMOTE_INCONCLUSIVE_MAX:-3}
case "$REMOTE_INCONCLUSIVE_MAX" in
  ''|*[!0-9]*|0) REMOTE_INCONCLUSIVE_MAX=3 ;;
esac
WATCHER_DOWNTIME_MARKER="$STATE/.watcher-down"
PR_PUBLICATION_LOCK_STALE_SECS=30
# The singleton-lock acquisition, EXIT trap, and the blocking supervision loop
# all live below the source guard at the very bottom of this file (see "Main
# entry"). Sourcing this file for unit tests therefore loads the functions -
# including the event-wait splice below - and returns before acquiring the lock
# or starting the loop. Running it as a script executes the runtime exactly as
# before, byte-for-byte.

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
#
# stat_sig must distinguish consecutive in-place touches of the same per-generation
# turn-ended marker (state/<id>.turn-ended.<spawn_gen>) within one epoch second;
# whole-second inode:size:mtime is identical across touches, so sub-second mtime
# must differ.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }             # epoch seconds of mtime
  stat_sig()   { stat -f '%i:%z:%Fm' "$1" 2>/dev/null; }    # inode:size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%i:%s:%.9Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
# The liveness beacon is touched once per cycle, immediately before the
# terminal wait below (event_wait_or_sleep) as well as at the top of the next
# one, so a healthy cycle's beacon can legitimately age up to POLL seconds
# between touches. fm_poll_derived_grace (bin/fm-wake-lib.sh, already sourced
# transitively above) is the single owner of the max(300, poll+60)
# derivation - see docs/turnend-guard.md "Guard grace and the poll cadence".
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-$(fm_poll_derived_grace "$POLL")}}
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
TURNEND_CHURN_ABSORB_SECS=${FM_TURNEND_CHURN_ABSORB_SECS:-900}  # longest a task's
                                      # bare turn-ends may be deferred on pane-churn
                                      # evidence alone (signal_turnend_panes_churned)
# Busy state is decided by the semantic contract in bin/fm-busy-lib.sh, which
# is the single owner of per-harness sources, source attribution, and the one
# remaining rendered-text fallback (Grok only). OMP, like every other harness
# without a rendered fallback, is classified from its recorded turn state
# there; its delivery-only footer lives in bin/fm-tmux-lib.sh.
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb signal
# / stale path is absorb-only-on-positive-evidence. The shared proof is an actively
# running no-mistakes step or a busy pane via crew_is_provably_working over
# fm-crew-state.sh; where config/turnend-churn-absorb opts in, a bare turn-end alone
# may also use bounded pane churn since the previous poll.
# Every other crew that stopped its turn is SURFACED, so a finish reported
# only through interactive pane menus (no done: status) is never swallowed. An
# ACTIONABLE wake (a captain-relevant signal, a no-verb signal without either
# eligible proof, any check, a stale pane whose crew is not provably working, a
# provably-working stale past the threshold, or anything unknown) is written to
# the durable queue and exits. That wakes the LLM through the background-task
# completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a provably-working stale escalates as a possible wedge
# A busy pane is unconditional proof of liveness with no built-in duration bound,
# so a hung foreground call can remain hidden even while its rendered busy
# footer changes every poll. BUSY_TURN_MAX_SECS bounds how long any busy pane
# may go with no completed turn: once its task's
# live-generation state/<id>.turn-ended.<spawn_gen> marker (or, before any turn has completed, the task's
# spawn record) is this old, busy_turn_over_age routes the pane through
# busy_turn_bound_check, which hands a crossed bound to the same
# STALE_ESCALATE_SECS-paced wedge_timer_check used for a provably-working
# non-busy stale - so it escalates via the existing stale reason, escalation
# counter, and demand-deep-inspection marker for human inspection only, never an
# automatic interrupt, signal, or restart - unless the crew declared the wait
# itself, which takes the long pause cadence instead. A completed turn publishes
# the live-generation turn-ended marker and resets the age. Set generously above any legitimate interval
# between completed turns, including long tool calls, builds, or test runs.
BUSY_TURN_MAX_SECS=${FM_BUSY_TURN_MAX_SECS:-3600}
# A crew that declared a pause is idling on a known external wait, so its stale
# pane is absorbed rather than wedge-escalated.
# A captain-held or paused crew whose agent has confidently exited uses the same
# bounded cadence, while a live or ambiguously read agent surfaces on first sight
# and is then held to that same cadence; a secondmate earns the cadence on its
# declaration alone, because its endpoint liveness is deliberately never read
# (pause_state_class owns that split).
# These cases re-surface once for a recheck every PAUSE_RESURFACE_SECS - far
# longer than the wedge threshold, but finite so a forgotten hold cannot rot invisibly.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
# An endpoint whose fate already waits on an open captain decision must not
# re-alert once per watcher cycle: nothing about an unreachable endpoint changes
# until that decision is answered. A stale escalation for a linked endpoint still
# fires at once for the first episode and after every real change; later repeats
# double this interval up to the cap, and each suppressed repeat increments a
# persisted counter that the next reminder reports. The ledger is
# state/.held-alert-<window-key>; docs/configuration.md owns the behavior.
HELD_ALERT_BACKOFF_SECS=${FM_HELD_ALERT_BACKOFF_SECS:-3600}
case "$HELD_ALERT_BACKOFF_SECS" in ''|0*|*[!0-9]*|??????????*) HELD_ALERT_BACKOFF_SECS=3600 ;; esac
HELD_ALERT_BACKOFF_MAX_SECS=${FM_HELD_ALERT_BACKOFF_MAX_SECS:-21600}
case "$HELD_ALERT_BACKOFF_MAX_SECS" in ''|0*|*[!0-9]*|??????????*) HELD_ALERT_BACKOFF_MAX_SECS=21600 ;; esac
[ "$HELD_ALERT_BACKOFF_MAX_SECS" -ge "$HELD_ALERT_BACKOFF_SECS" ] \
  || HELD_ALERT_BACKOFF_MAX_SECS=$HELD_ALERT_BACKOFF_SECS
# How often the per-poll release check may re-read the linked call while a
# backoff ledger is active, so an answered, released, or re-held decision lifts
# the suppression promptly without a backlog read on every poll. 0 checks every
# poll; invalid values fall back to 60.
HELD_ALERT_RELEASE_CHECK_SECS=${FM_HELD_ALERT_RELEASE_CHECK_SECS:-60}
case "$HELD_ALERT_RELEASE_CHECK_SECS" in ''|*[!0-9]*) HELD_ALERT_RELEASE_CHECK_SECS=60 ;; esac
# Completion-reporting bound for a turn that ends while the task's board row is
# still in flight (the worker-facing contract is generated by bin/fm-brief.sh,
# which quotes this same number): a pane left idle past it with no new status
# line escalates as `idle-with-open-work`. The check is time-anchored, so a
# ticking idle pane whose hash changes every poll cannot dodge it the way it
# dodges stable-hash staleness.
IDLE_OPEN_WORK_SECS=${FM_IDLE_OPEN_WORK_SECS:-$FM_IDLE_OPEN_WORK_SECS_DEFAULT}
case "$IDLE_OPEN_WORK_SECS" in ''|0|*[!0-9]*) IDLE_OPEN_WORK_SECS=$FM_IDLE_OPEN_WORK_SECS_DEFAULT ;; esac
# A local secondmate's foreign queue is checked on every poll, but only after this
# bounded interval with no drain progress can it produce a parent notification.
# A healthy mate drains its queue between turns, not inside one, so this default
# sits above a real turn; it is only the backstop behind the active-turn gate in
# secondmate_wake_stall_tick, never a substitute for it.
SECONDMATE_WAKE_STALL_SECS=${FM_SECONDMATE_WAKE_STALL_SECS:-}
case "$SECONDMATE_WAKE_STALL_SECS" in ''|*[!0-9]*|0) SECONDMATE_WAKE_STALL_SECS=180 ;; esac
# Oldest age (seconds) an undelivered main-owned durable wake row may reach
# before the watcher raises one wedge alarm per oldest-row episode
# (docs/wedge-alarm.md). Empty, zero, or non-numeric falls back to 300.
MAIN_WAKE_UNDELIVERED_ALARM_SECS=${FM_MAIN_WAKE_UNDELIVERED_ALARM_SECS:-}
case "$MAIN_WAKE_UNDELIVERED_ALARM_SECS" in ''|*[!0-9]*|0) MAIN_WAKE_UNDELIVERED_ALARM_SECS=300 ;; esac
MAIN_WAKE_UNDELIVERED_MARKER="$STATE/.main-wake-undelivered"
# Consecutive event-path failures (fm_backend_wait_transition returning 2 -
# connect/subscribe failure) before the push fast-path is disabled for the rest
# of this watcher process and the loop reverts to pure polling (report section
# 5c trigger 3: proven-unreliable-at-runtime). A watcher restart re-probes
# capability, so a transient herdr hiccup self-heals on the next cycle chain.
EVENT_CAP_FAIL_MAX=${FM_EVENT_CAP_FAIL_MAX:-3}
# Per-process memo for the push-capability probe (fm_backend_events_capable runs
# a ~220KB `herdr api schema` read, too heavy to repeat every poll). Keyed by
# "<backend>:<session>"; re-probed only when that key changes.
_event_cap_key=""
_event_cap_ok=0
_event_cap_fails=0

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

hash_pane() {
  if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi
}

# window_is_busy: 0 (busy) iff the task's harness is PROVABLY working, through
# the semantic busy-state contract (bin/fm-busy-lib.sh). Only an exact busy
# verdict returns 0: idle, unknown, and dead all return 1, so a converted
# adapter whose semantic state is missing, malformed, stale, or unverified is
# treated as not-provably-working and surfaces rather than being absorbed.
# <tail40> is the same bounded capture already read for hashing and is
# consumed only by the Grok-scoped fallback inside the contract.
window_is_busy() {  # <window> <tail40>
  local w=$1 tail40=$2 task meta verdict
  task=$(window_to_task "$w" "$STATE")
  meta="$STATE/$task.meta"
  if [ -n "$task" ] && [ -f "$meta" ]; then
    verdict=$(fm_busy_classify_meta "$meta" "$task" "$STATE" "$tail40")
  else
    verdict=$(fm_busy_classify "$(window_backend "$w")" "$w" "$(window_harness "$w")" \
      "${task:-unknown}" "$STATE" "$tail40")
  fi
  [ "${verdict%% *}" = busy ]
}

window_kind() {
  local w=$1 meta kind
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    echo "$kind"
    return 0
  fi
  echo unknown
}

# window_backend: the backend recorded in the meta whose window= matches <w>,
# defaulting to tmux (absent backend= means tmux; the P1 compatibility
# contract) when no matching meta carries the field, or none matches at all.
window_backend() {
  local w=$1 meta backend
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    backend=$(grep '^backend=' "$meta" | cut -d= -f2- || true)
    [ -n "$backend" ] || backend=tmux
    echo "$backend"
    return 0
  fi
  echo tmux
}

window_harness() {
  local w=$1 meta
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  grep '^harness=' "$meta" | cut -d= -f2- || true
}

window_label() {
  local w=$1 task
  task=$(window_to_task "$w" "$STATE")
  [ -n "$task" ] && printf 'fm-%s' "$task"
}

inbox_steer_inbox_error() {  # <window> <task>
  local w=$1 task=$2 reason
  reason="stale: $w (the steering inbox for $task is unreadable; durable instructions cannot be verified, so inspect the inbox)"
  fm_wake_append stale "$w" "$reason" || exit 1
  wake "$reason"
}

# Surface one stale wake for an unhandled steer whose endpoint is positively
# dead or missing: the doorbell was never typed, so the record goes straight to
# recovery instead of walking the re-ring ladder. The marker write happens after
# the durable queue append, so a crash between them can only produce a rare
# duplicate, never a lost wake.
inbox_steer_escalate_unavailable() {  # <window> <task> <record>
  local w=$1 task=$2 rec=$3 reason rc
  reason="stale: $w (unread firstmate instruction: $rec is unhandled and the worker's agent has exited or its endpoint is missing, so the doorbell was not typed; recover the worker)"
  if [ ! -d "${rec%/*}" ] || [ ! -f "$rec" ]; then
    if fm_task_inbox_due_action "$STATE" "$task" >/dev/null; then
      :
    else
      rc=$?
      [ "$rc" -eq 2 ] && inbox_steer_inbox_error "$w" "$task"
    fi
    return 0
  fi
  if inbox_steer_attempt_recovery "$w" "$task" "$rec" "endpoint-unavailable"; then
    return 0
  fi
  [ -z "$INBOX_RECOVERY_DETAIL" ] || reason="$reason [auto-recovery: $INBOX_RECOVERY_DETAIL]"
  fm_wake_append stale "$w" "$reason" || exit 1
  if ! fm_task_inbox_record_escalated "$STATE" "$task" "$rec"; then
    echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
    exit 1
  fi
  wake "$reason"
}

# Custody-checked bounded auto-recovery for a stalled worker, owned by
# bin/fm-stall-recovery.sh. Runs BEFORE the stale wake is published: a
# deferred verdict (record handled meanwhile, or a missing-endpoint relaunch
# just published with the episode still pending) suppresses the escalation
# entirely, while an escalate verdict - including a live endpoint, any helper
# failure, or a missing verdict - keeps the ordinary stale wake with the
# helper's reason appended. Returns 0 when the wake is suppressed, 1 when the
# caller should escalate.
FM_STALL_RECOVERY_BIN="${FM_STALL_RECOVERY_BIN:-$SCRIPT_DIR/fm-stall-recovery.sh}"
INBOX_RECOVERY_DETAIL=
inbox_steer_attempt_recovery() {  # <window> <task> <record> <trigger>
  local task=$2 record=$3 trigger=$4 out rc=0
  INBOX_RECOVERY_DETAIL=
  [ -x "$FM_STALL_RECOVERY_BIN" ] || { INBOX_RECOVERY_DETAIL="recovery helper missing"; return 1; }
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$FM_STALL_RECOVERY_BIN" "$task" "$record" "$trigger" 2>/dev/null) || rc=$?
  case "$out" in
    verdict=recovered*|verdict=deferred*)
      INBOX_RECOVERY_DETAIL=${out#*detail=}
      triage_log "steer-inbox stall recovery: $task ${record##*/} $out"
      return 0
      ;;
    verdict=escalate*)
      INBOX_RECOVERY_DETAIL=${out#*detail=}
      triage_log "steer-inbox stall recovery escalates: $task ${record##*/} $out"
      return 1
      ;;
    *)
      INBOX_RECOVERY_DETAIL="recovery helper returned no verdict (rc=$rc)"
      triage_log "steer-inbox stall recovery failed: $task ${record##*/} rc=$rc out=${out:-none}"
      return 1
      ;;
  esac
}

inbox_steer_check() {  # <window> <task>
  local window=$1 task=$2 action verb record count tail40 reason ring_rc rc
  local meta backend label harness omp_runtime omp_bin agent_state
  if action=$(fm_task_inbox_due_action "$STATE" "$task" 2>/dev/null); then
    :
  else
    rc=$?
    [ "$rc" -eq 2 ] && inbox_steer_inbox_error "$window" "$task"
    return 0
  fi
  verb=${action%% *}
  [ "$verb" != quiet ] || return 0
  record=${action#* }
  count=
  if [ "$verb" = escalate ]; then
    count=${record##* }
    record=${record% *}
  fi
  meta=$(fm_backend_meta_for_window "$window" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 0
  backend=$(fm_backend_of_meta "$meta")
  label=$(window_label "$window")
  harness=$(fm_meta_get "$meta" harness)
  omp_runtime=$(fm_meta_get "$meta" omp_bun)
  omp_bin=$(fm_meta_get "$meta" omp_bin)
  agent_state=$(fm_backend_agent_state "$backend" "$window" 2>/dev/null || true)
  case "$agent_state" in
    dead|missing)
      inbox_steer_escalate_unavailable "$window" "$task" "$record"
      return 0
      ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$window" 40 "$label" 2>/dev/null) || tail40=
  window_is_busy "$window" "$tail40" && return 0
  case "$verb" in
    ring)
      ring_rc=0
      fm_task_inbox_ring "$backend" "$window" "$record" "$label" \
        "$harness" "$omp_runtime" "$omp_bin" || ring_rc=$?
      if [ "$ring_rc" -eq 6 ]; then
        inbox_steer_escalate_unavailable "$window" "$task" "$record"
        return 0
      fi
      if ! fm_task_inbox_record_ring "$STATE" "$task" "$record"; then
        if [ ! -f "$record" ]; then
          if fm_task_inbox_due_action "$STATE" "$task" >/dev/null; then
            :
          else
            rc=$?
            [ "$rc" -eq 2 ] && inbox_steer_inbox_error "$window" "$task"
          fi
          return 0
        fi
        if [ -d "${record%/*}" ]; then
          reason="stale: $window (steering-inbox ladder bookkeeping unwritable: ${record%/*}/.ring-state cannot be written while $record stays unhandled; inspect the inbox directory)"
          fm_wake_append stale "$window" "$reason" || exit 1
          wake "$reason"
        fi
      fi
      triage_log "steer-inbox delivery attempt: $task ${record##*/} result=$ring_rc"
      ;;
    escalate)
      reason="stale: $window (unread firstmate instruction: $record still unhandled after $count doorbell delivery attempts with an idle pane; inspect the worker)"
      if [ ! -d "${record%/*}" ] || [ ! -f "$record" ]; then
        if fm_task_inbox_due_action "$STATE" "$task" >/dev/null; then
          :
        else
          rc=$?
          [ "$rc" -eq 2 ] && inbox_steer_inbox_error "$window" "$task"
        fi
        return 0
      fi
      if inbox_steer_attempt_recovery "$window" "$task" "$record" "ladder-exhausted"; then
        return 0
      fi
      [ -z "$INBOX_RECOVERY_DETAIL" ] || reason="$reason [auto-recovery: $INBOX_RECOVERY_DETAIL]"
      fm_wake_append stale "$window" "$reason" || exit 1
      if ! fm_task_inbox_record_escalated "$STATE" "$task" "$record"; then
        echo "error: stale wake was queued for $task but its inbox escalation marker could not be written" >&2
        exit 1
      fi
      wake "$reason"
      ;;
  esac
}

# 0 (benign/absorb) if EVERY task in a no-verb "signal:" wake has positive work
# evidence; 1 otherwise. Each task may satisfy the authoritative working proof,
# or an eligible bare turn-end may use the opt-in pane-churn proof below.
#
# OFF unless the home creates config/turnend-churn-absorb. The first two proofs
# read a verdict the harness itself vouches for; this one infers execution from
# rendered bytes, which is weaker, so widening the absorb is a home's choice to
# make rather than a default every fleet inherits. With the flag absent this
# delegates to the unchanged all-tasks authoritative proof.
#
# It exists because the first two are unreachable for a harness whose semantic
# busy state has no verified source: bin/fm-crew-state.sh can only answer unknown
# for such an adapter, crew_is_provably_working is therefore never satisfiable,
# and every worker turn boundary surfaced a wake with nothing to act on - the cost
# scaling with the number of workers in flight. Pane churn needs no harness
# cooperation, so it restores the absorb branch for those adapters without
# fabricating a busy verdict any adapter has not earned.
#
# The evidence is the one the pane-staleness backbone below already trusts for
# liveness: this compares a fresh capture against the .hash- marker that backbone
# recorded on the previous poll, which is why the derivation lives here with the
# marker format rather than in the shared classifier. Absorbing here DEFERS a wake
# rather than swallowing it, and the deferral is BOUNDED: a task's turn-ends may
# ride churn evidence for at most FM_TURNEND_CHURN_ABSORB_SECS, tracked per window
# in .churn-since-, after which the wake surfaces and the window restarts. The
# bound is what keeps churn from muting supervision outright. A pane that renders
# continuously - a clock, a spinner, a shell heartbeat, a harness that leaves a
# background renderer alive after its agent yields - never presents the two
# identical consecutive hashes the staleness backbone needs either, so without the
# bound a worker that had genuinely stopped behind such a renderer would be
# deferred here forever with no fallback path left to surface it. Churn and
# staleness read the same pane, so neither can be the other's only backstop.
# Within the bound, an ordinary crew that stops renders nothing more, its pane
# hash stops moving, and the staleness backbone surfaces it within a couple of
# polls; any captain-relevant status verb still surfaces immediately through
# signal_files_actionable. That is why this widens the proof instead of
# bounding the wake rate, which would have suppressed genuinely stopped workers.
#
# Every negative outcome returns 1, so absence of evidence surfaces exactly as
# before: any batch that references a secondmate, an unresolvable task, a task
# with no uniquely attributable recorded endpoint, no previous hash to compare
# against (nothing has been polled yet), a capture that fails or comes back empty,
# an exhausted deferral bound, and of course an unchanged pane. Any .status file
# also returns 1: an authored append is content the
# supervisor may need to read, so only the mechanical turn-end marker gets the
# fallback.
#
# NOT a pure read: one bounded pane capture per referenced task that lacks
# authoritative proof. Once EVERY task passes, each churn-proven pane's prior
# .stale- classification and wedge-escalation count are cleared because churn
# begins a new quiet interval; retaining either would make the new interval
# inherit the prior one. Reached only for a non-afk, no-captain-verb signal, so
# it never runs on the ordinary per-wake path.
signal_turnend_panes_churned() {  # <file> ...
  [ -e "$CONFIG/turnend-churn-absorb" ] || return 1
  local f base task meta kind w key backend label terminal prev now since now_s absorb_secs marker age
  local rec_task task_index i j count hash_file hash_bytes created
  local max_absorb_secs=9223372036854775807
  local -a signal_tasks=() snapshot_tasks=() snapshot_kinds=()
  local -a snapshot_windows=() snapshot_keys=() snapshot_backends=() snapshot_labels=()
  local -a signal_indexes=() churn_indexes=() churned_keys=() missing_keys=() created_keys=()
  [ "$#" -gt 0 ] || return 1
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)      return 1 ;;
      # Both marker generations are eligible: bare .turn-ended (legacy) and the
      # per-incarnation .turn-ended.<spawn_gen> every publisher writes today.
      # Missing the latter would make the whole proof unreachable in production.
      *.turn-ended)   task=${base%.turn-ended} ;;
      *.turn-ended.*) task=${base%.turn-ended.*} ;;
      *)              return 1 ;;
    esac
    [ -n "$task" ] || return 1
    task_index=-1
    for ((i = 0; i < ${#signal_tasks[@]}; i++)); do
      [ "${signal_tasks[$i]}" = "$task" ] && { task_index=$i; break; }
    done
    if [ "$task_index" -lt 0 ]; then
      signal_tasks+=("$task")
    fi
  done
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    rec_task=${meta##*/}
    rec_task=${rec_task%.meta}
    kind=$(fm_meta_get "$meta" kind)
    backend=$(fm_backend_of_meta "$meta")
    if [ "$backend" = orca ]; then
      terminal=$(fm_meta_get "$meta" terminal)
      w=${terminal:-$(fm_meta_get "$meta" window)}
    else
      w=$(fm_meta_get "$meta" window)
    fi
    key=
    [ -n "$w" ] && key=$(window_key "$w")
    label="fm-$rec_task"
    snapshot_tasks+=("$rec_task")
    snapshot_kinds+=("$kind")
    snapshot_windows+=("$w")
    snapshot_keys+=("$key")
    snapshot_backends+=("$backend")
    snapshot_labels+=("$label")
  done
  # These linear lookups deliberately support stock macOS Bash 3.2.57, enforced
  # by macos-stock-bash, and this repository uses no associative arrays in bin/
  # or tests/. A batch is normally one to three tasks and captures dominate its
  # cost; indexed lookup is the upgrade path if coalesced batches grow large.
  for task in "${signal_tasks[@]}"; do
    task_index=-1
    for ((i = 0; i < ${#snapshot_tasks[@]}; i++)); do
      [ "${snapshot_tasks[$i]}" = "$task" ] && { task_index=$i; break; }
    done
    [ "$task_index" -ge 0 ] || return 1
    w=${snapshot_windows[$task_index]}
    key=${snapshot_keys[$task_index]}
    [ -n "$w" ] && [ -n "$key" ] || return 1
    count=0
    for ((j = 0; j < ${#snapshot_keys[@]}; j++)); do
      [ "${snapshot_keys[$j]}" = "$key" ] && count=$((count + 1))
    done
    [ "$count" -eq 1 ] || return 1
    signal_indexes+=("$task_index")
  done
  for task_index in "${signal_indexes[@]}"; do
    [ "${snapshot_kinds[$task_index]}" != secondmate ] || return 1
  done
  for ((i = 0; i < ${#signal_tasks[@]}; i++)); do
    task=${signal_tasks[$i]}
    crew_is_provably_working "$task" && continue
    task_index=${signal_indexes[$i]}
    churn_indexes+=("$task_index")
  done
  [ "${#churn_indexes[@]}" -gt 0 ] || return 0
  [[ $TURNEND_CHURN_ABSORB_SECS =~ ^[1-9][0-9]*$ ]] || return 1
  if [ "${#TURNEND_CHURN_ABSORB_SECS}" -gt "${#max_absorb_secs}" ] \
    || { [ "${#TURNEND_CHURN_ABSORB_SECS}" -eq "${#max_absorb_secs}" ] \
      && [[ $TURNEND_CHURN_ABSORB_SECS -gt $max_absorb_secs ]]; }; then
    return 1
  fi
  absorb_secs=$((10#$TURNEND_CHURN_ABSORB_SECS))
  for task_index in "${churn_indexes[@]}"; do
    w=${snapshot_windows[$task_index]}
    key=${snapshot_keys[$task_index]}
    backend=${snapshot_backends[$task_index]}
    label=${snapshot_labels[$task_index]}
    hash_file="$STATE/.hash-$key"
    hash_bytes=$(LC_ALL=C wc -c 2>/dev/null < "$hash_file") || return 1
    hash_bytes=${hash_bytes//[[:space:]]/}
    [ "$hash_bytes" = 32 ] || return 1
    prev=$(cat "$hash_file" 2>/dev/null) || return 1
    [[ $prev =~ ^[0-9a-f]{32}$ ]] || return 1
    now=$(fm_backend_capture "$backend" "$w" 40 "$label" 2>/dev/null) || return 1
    [ -n "$now" ] || return 1
    [ "$(printf '%s' "$now" | hash_pane)" != "$prev" ] || return 1
    churned_keys+=("$key")
  done
  # Enforce the deferral bound BEFORE any .stale- state is touched, so a wake that
  # surfaces here leaves the staleness backbone's own classification alone.
  now_s=$(date +%s)
  for key in "${churned_keys[@]}"; do
    marker="$STATE/.churn-since-$key"
    if [ ! -e "$marker" ]; then
      [ ! -L "$marker" ] || return 1
      missing_keys+=("$key")
      continue
    fi
    since=$(cat "$marker" 2>/dev/null) || return 1
    [[ $since =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    if [ "${#since}" -gt "${#now_s}" ] \
      || { [ "${#since}" -eq "${#now_s}" ] && [[ $since > $now_s ]]; }; then
      return 1
    fi
    age=$((10#$now_s - 10#$since))
    if [ "$age" -ge "$absorb_secs" ]; then
      rm -f "$marker"
      return 1
    fi
  done
  for key in "${missing_keys[@]}"; do
    marker="$STATE/.churn-since-$key"
    if (set -C; printf '%s' "$now_s" > "$marker") 2>/dev/null; then
      created_keys+=("$key")
      continue
    fi
    for created in "${created_keys[@]}"; do
      rm -f "$STATE/.churn-since-$created"
    done
    return 1
  done
  for key in "${churned_keys[@]}"; do
    if ! rm -f "$STATE/.stale-$key" "$STATE/.wedge-escalations-$key"; then
      for created in "${created_keys[@]}"; do
        rm -f "$STATE/.churn-since-$created"
      done
      return 1
    fi
  done
  return 0
}

# The ONE derivation of a window's per-window marker key: `:`, `/` and `.` become
# `_` so a window name is usable as a filename suffix. Every per-window file the
# watcher keeps is named by it (.hash-, .count-, .stale-, .stale-since-,
# .wedge-escalations-, .paused-*, .writing-*), and live homes hold those markers on
# disk under the current format, so the format lives here alone: a second copy is
# how a future change to it silently orphans a window's markers instead of clearing
# them. The helpers below take the derived key rather than re-deriving it, so one
# poll of one window derives it once.
window_key() {  # <window>
  local key=${1//:/_}
  key=${key//\//_}
  printf '%s' "${key//./_}"
}

recorded_windows() {
  local meta w seen=
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(fm_backend_target_of_meta "$meta")
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

# Print the oldest structurally valid ACTIONABLE row in a local secondmate's
# foreign queue. A stale recheck that explicitly identifies itself as a declared
# external-wait pause is not evidence that the mate's wake loop is stuck: the
# pause cadence already owns that bounded visibility, and blocked waits remain
# actionable because they do not carry this declaration. This is a read-only
# observation: the receiving home owns acknowledgement and this parent never
# changes the row or the foreign queue.
secondmate_oldest_queue_row() {  # <queue-path>
  local queue=$1
  [ -f "$queue" ] && [ ! -L "$queue" ] || return 0
  awk -F '\t' '
    function declared_external_pause(kind, payload) {
      return kind == "stale" \
        && payload ~ /^stale: .*\(paused [0-9]+s, awaiting external - declared (pause,|paused\))/
    }
    NF >= 5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ \
      && !declared_external_pause($3, $5) {
      if (!found || $2 < seq) {
        found = 1
        seq = $2
        row = $0
      }
    }
    END { if (found) print row }
  ' "$queue" 2>/dev/null || true
}

# 0 iff <task> is demonstrably inside an active turn, through the watcher's own
# busy-state knowledge: an exact busy verdict from the semantic contract, bounded
# by the same BUSY_TURN_MAX_SECS that stops a busy pane from proving liveness
# forever. A mate mid-turn has not stopped draining its queue - it simply drains
# between turns - so this gate, not the elapsed interval, is what separates a
# healthy mate from a frozen wake loop. Any absence of proof (no window, a failed
# capture, an idle or unknown verdict, a busy pane past the bound) is NOT an
# active turn, so a frozen queue still escalates.
secondmate_in_active_turn() {  # <task> <window>
  local task=$1 w=$2 tail40
  [ -n "$w" ] || return 1
  ! busy_turn_over_age "$task" || return 1
  tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || return 1
  window_is_busy "$w" "$tail40"
}

# Surface one durable parent check when the foreign queue's drain position has
# not moved for the bounded interval. The progress marker records that position
# as the same epoch-sequence row identity the stall receipts use, so the timer
# restarts whenever a different row becomes the oldest actionable one - as the
# mate drains, and as a queue reprovisioned under the same task id starts its
# own generation of rows at whatever sequence it restarts, and neither is a
# continued no-progress episode; row creation time belongs to that identity but
# never to the interval. A moved position ends an alerted episode and starts a
# new observation interval, so a newly-oldest row cannot alert immediately while
# a later genuine freeze remains visible. A mate demonstrably inside an active
# turn never escalates, so the interval is only the backstop behind that gate.
# Receipts close the append-before-marker crash window without changing the
# foreign queue.
secondmate_wake_stall_tick() {
  local now=$(( $(date +%s) )) threshold=$SECONDMATE_WAKE_STALL_SECS
  local meta task kind remote_host home queue row epoch seq row_key marker progress_marker progress observed_at observed_key
  local receipt receipt_dir notify_key queued idle reason episode_alerted
  # Endpoint metadata admits this queue-loop check; secondmate-liveness owns registered mates whose endpoint is missing or dead.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] || continue
    remote_host=$(fm_meta_get "$meta" remote_host)
    [ -z "$remote_host" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    case "$task" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    home=$(fm_meta_get "$meta" home)
    [ -n "$home" ] || continue
    [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] || continue
    [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)" = "$task" ] || continue
    queue="$home/state/.wake-queue"
    row=$(secondmate_oldest_queue_row "$queue")
    marker="$STATE/.secondmate-wake-stall-$task"
    progress_marker="$STATE/.secondmate-wake-progress-$task"
    receipt_dir="$STATE/.secondmate-wake-stall-receipts/$task"
    if [ -z "$row" ]; then
      rm -f "$marker" "$progress_marker"
      if [ -e "$receipt_dir" ] || [ -L "$receipt_dir" ]; then
        [ -d "$receipt_dir" ] && [ ! -L "$receipt_dir" ] || return 1
        rm -rf -- "$receipt_dir" || return 1
      fi
      continue
    fi
    IFS=$(printf '\t') read -r epoch seq _row_kind _row_key _row_payload <<EOF
$row
EOF
    case "$epoch" in ''|*[!0-9]*) continue ;; esac
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    row_key="$epoch-$seq"
    episode_alerted=0
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
      episode_alerted=1
    fi
    progress=$(cat "$progress_marker" 2>/dev/null || true)
    observed_at=${progress%%[[:space:]]*}
    observed_key=${progress#*[[:space:]]}
    if [ "$observed_at" = "$progress" ]; then
      observed_key=
    else
      observed_key=${observed_key%%[[:space:]]*}
    fi
    case "$observed_at" in ''|*[!0-9]*) observed_at= ;; esac
    case "$observed_key" in ''|*[!0-9-]*) observed_key= ;; esac
    if [ -z "$observed_at" ] || [ -z "$observed_key" ] \
      || [ "$now" -lt "$observed_at" ] || [ "$row_key" != "$observed_key" ]; then
      fm_wake_secondmate_progress_marker_write "$task" "$now" "$row_key" || return 1
      [ "$episode_alerted" -eq 0 ] || rm -f "$marker" || return 1
      continue
    fi
    [ "$episode_alerted" -eq 0 ] || continue
    idle=$((now - observed_at))
    [ "$idle" -ge "$threshold" ] || continue
    ! secondmate_in_active_turn "$task" "$(fm_backend_target_of_meta "$meta")" || continue
    receipt="$receipt_dir/$row_key"
    if [ "$(cat "$receipt" 2>/dev/null || true)" = "$row_key" ]; then
      fm_wake_secondmate_stall_marker_write "$task" "$row_key" || return 1
      continue
    fi
    notify_key="secondmate-wake-loop-$task-$row_key"
    reason="check: secondmate wake-loop stalled: mate=$task row=$seq idle=${idle}s"
    queued=$(fm_wake_queued_keys check)
    if ! printf '%s\n' "$queued" | grep -Fx "$notify_key" >/dev/null 2>&1; then
      fm_wake_append check "$notify_key" "$reason" || return 1
    fi
    fm_wake_secondmate_stall_receipt_write "$task" "$row_key" || return 1
    fm_wake_secondmate_stall_marker_write "$task" "$row_key" || return 1
    wake "$reason"
  done
  return 0
}

# Undelivered main-wake alarm: the queue-layer backstop for the
# accepted-but-unconsumed delivery wedge (a main-bound notification whose in-
# flight marker outlives FM_WATCH_MAIN_WAKE_INFLIGHT_BOUND_MS - see
# bin/fm-primary-watch-core.ts - and every later wake coalesced behind it).
# While the oldest main-owned durable row sits unpresented past
# FM_MAIN_WAKE_UNDELIVERED_ALARM_SECS, one wedge alarm fires per oldest-row
# episode, strictly read-only against the queue and skipped while state/.afk
# hands delivery to the away daemon (its own wedge alarm owns that interval).
# The marker's first line records the alarmed sequence so a tick cannot re-fire
# inside one episode, while a newer oldest row opens a fresh episode. The tick
# never enqueues a wake and never prints a wake reason: the alarm channel is
# the notification.
main_wake_undelivered_tick() {
  local rows candidate epoch seq row marker_seq age now marker_tmp
  afk_present && return 0
  rows=$(fm_wake_actor_pending_rows main 2>/dev/null) || return 0
  row=
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$candidate" in
      *$'\t'*$'\t'*$'\t'*$'\t'*) ;;
      *) continue ;;
    esac
    epoch=${candidate%%$'\t'*}
    seq=${candidate#*$'\t'}
    seq=${seq%%$'\t'*}
    case "$epoch" in ''|*[!0-9]*|0) continue ;; esac
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    row=$candidate
    break
  done <<EOF
$rows
EOF
  if [ -z "$row" ]; then
    rm -f -- "$MAIN_WAKE_UNDELIVERED_MARKER"
    return 0
  fi
  marker_seq=
  if [ -f "$MAIN_WAKE_UNDELIVERED_MARKER" ] && [ ! -L "$MAIN_WAKE_UNDELIVERED_MARKER" ]; then
    marker_seq=$(head -n 1 "$MAIN_WAKE_UNDELIVERED_MARKER" 2>/dev/null || true)
    case "$marker_seq" in ''|*[!0-9]*) marker_seq= ;; esac
  fi
  if [ -n "$marker_seq" ] && [ "$marker_seq" != "$seq" ]; then
    rm -f -- "$MAIN_WAKE_UNDELIVERED_MARKER" || return 1
    marker_seq=
  fi
  now=$(( $(date +%s) ))
  age=$((now - epoch))
  [ "$age" -ge "$MAIN_WAKE_UNDELIVERED_ALARM_SECS" ] || return 0
  [ "$marker_seq" = "$seq" ] && return 0
  marker_tmp=$(mktemp "$STATE/.main-wake-undelivered.tmp.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$seq" \
    "undelivered for ${age}s at $(date -u '+%Y-%m-%dT%H:%M:%SZ'); main has not drained its wake rows; see docs/wedge-alarm.md" \
    > "$marker_tmp" \
    || ! chmod 0600 "$marker_tmp" \
    || ! mv -f -- "$marker_tmp" "$MAIN_WAKE_UNDELIVERED_MARKER"; then
    rm -f -- "$marker_tmp"
    return 1
  fi
  triage_log "main-owned wake row seq $seq undelivered for ${age}s; wedge alarm fired once - see $MAIN_WAKE_UNDELIVERED_MARKER"
  WEDGE_ALARM_TITLE="firstmate: main wakes UNDELIVERED" \
    wedge_alarm_notify "main-owned wake row seq $seq undelivered for ${age}s - see $MAIN_WAKE_UNDELIVERED_MARKER" "$MAIN_WAKE_UNDELIVERED_MARKER" || true
  return 0
}

# No-Mistakes PR-guard backstop. A no-mistakes ship task's branch must get its
# PR from the No-Mistakes pipeline; a worker-created PR predates every run, so
# fm-pr-check.sh and fm-pr-merge.sh have no run to prove. bin/fm-nm-pr-guard.sh
# refuses that creation in the worker's environment, and this tick detects a
# bypass (absolute path, another API client, a cleared marker) by asking
# whether the branch already has an open PR while it has no run.
# The open-PR lookup is GitHub's `gh pr list`, run in the task worktree; a
# project on another forge fails that lookup inconclusively and stays silent
# rather than alerting on an unreadable PR state.
# Cost is bounded: one `gh pr list` per eligible task, plus one local
# `axi status` read only when a PR exists, both no more often than
# CHECK_INTERVAL.
# Tasks with a recorded pr= or nm_run_id= are outside this missing-run scan.
# An explicit `repo not initialized` response counts as no run; other failed
# or malformed status reads are inconclusive and preserve the current marker.
# Failed PR lookups likewise preserve it, so recovery cannot repeat an alert.
# One durable check wake per task and PR; the per-task marker clears when a run
# appears or the PR closes, so a later episode alerts again.
nm_pr_unguarded_tick() {
  local meta task kind mode worktree recorded_pr recorded_run branch marker pr_line number url
  local status_out runs reason notify_key queued
  [ "$(age_of "$STATE/.last-nm-pr-scan")" -ge "$CHECK_INTERVAL" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = ship ] || continue
    mode=$(fm_meta_get "$meta" mode)
    [ "$mode" = no-mistakes ] || continue
    recorded_pr=$(fm_meta_get "$meta" pr)
    [ -z "$recorded_pr" ] || continue
    recorded_run=$(fm_meta_get "$meta" nm_run_id)
    [ -z "$recorded_run" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    case "$task" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    worktree=$(fm_meta_get "$meta" worktree)
    [ -n "$worktree" ] && [ -d "$worktree" ] || continue
    branch=$(git -C "$worktree" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=
    [ -n "$branch" ] && [ "$branch" != HEAD ] || continue
    marker="$STATE/.nm-pr-unguarded-$task"
    pr_line=$(fm_nm_cmd_bounded "$worktree" 15 gh pr list --state open \
      --head "$branch" --limit 1 --json number,url \
      --jq '.[] | "\(.number)\t\(.url)"' 2>/dev/null) || continue
    number=$(printf '%s\n' "$pr_line" | head -1 | cut -f1)
    url=$(printf '%s\n' "$pr_line" | head -1 | cut -f2)
    if [ -z "$number" ] || [ -z "$url" ]; then
      rm -f "$marker"
      continue
    fi
    if status_out=$(fm_nm_run_bounded "$worktree" 15 axi status 2>&1); then
      runs=$(fm_nm_field "$status_out" runs_on_current_branch)
    else
      case "$status_out" in
        *"repo not initialized"*) runs=0 ;;
        *) continue ;;
      esac
    fi
    case "$runs" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$runs" -ne 0 ]; then
      rm -f "$marker"
      continue
    fi
    [ "$(cat "$marker" 2>/dev/null || true)" = "$number $url" ] && continue
    notify_key="nm-pr-unguarded-$task-$number"
    reason="check: no-mistakes task $task has open PR $url but no No-Mistakes run on $branch (worker opened it; the pipeline must own the PR)"
    queued=$(fm_wake_queued_keys check) || queued=
    if ! printf '%s\n' "$queued" | grep -Fx "$notify_key" >/dev/null 2>&1; then
      fm_wake_append check "$notify_key" "$reason" || return 1
    fi
    printf '%s\n' "$number $url" > "$marker" || return 1
    touch "$STATE/.last-nm-pr-scan"
    wake "$reason"
  done
  touch "$STATE/.last-nm-pr-scan"
  return 0
}

# Local Communication Officer doorbell. The gateway's intake and outbox poster
# append durable ext rows (keys ext-request:<slug>, ext-delivery-failed:<slug>)
# from another process, which cannot wake this watcher, so without this a
# request waited for some unrelated wake. Each new such row rings once from
# here: the wake carries the rows' own payloads and appends nothing, because
# the rows are already durable (the same contract as an ext poll that owns its
# wake). Persisting the highest rung sequence in EXT_DOORBELL_MARKER prevents
# routine replay after restart; a failed marker write allows another ring.
# The drain's inbox-derived section
# keeps an unanswered request presented after its row is acknowledged.
EXT_DOORBELL_MARKER="$STATE/.ext-doorbell-rung"

ext_doorbell_rung() {
  local rung=0
  if [ -f "$EXT_DOORBELL_MARKER" ] && [ ! -L "$EXT_DOORBELL_MARKER" ]; then
    rung=$(head -n 1 "$EXT_DOORBELL_MARKER" 2>/dev/null || true)
    case "$rung" in ''|*[!0-9]*) rung=0 ;; esac
  fi
  printf '%s\n' "$rung"
}

# Prints "<seq>\t<payload>" for every pending main-owned ext row above the mark.
ext_doorbell_rows() {
  local rung
  rung=$(ext_doorbell_rung)
  fm_wake_actor_pending_rows main 2>/dev/null | awk -F '\t' -v rung="$rung" '
    NF >= 5 && $2 ~ /^[0-9]+$/ && $2 + 0 > rung + 0 \
      && ($4 ~ /^ext-request:/ || $4 ~ /^ext-delivery-failed:/) { print $2 "\t" $5 }'
}

ext_doorbell_mark() {  # <rows>: record the highest sequence in <rows> as rung
  local rows=$1 max tmp
  max=$(printf '%s\n' "$rows" | awk -F '\t' '$1 + 0 > max { max = $1 + 0 } END { print max + 0 }')
  [ "$max" -gt 0 ] || return 0
  tmp=$(mktemp "$STATE/.ext-doorbell-rung.tmp.XXXXXX") || return 1
  if ! printf '%s\n' "$max" > "$tmp" || ! mv -f -- "$tmp" "$EXT_DOORBELL_MARKER"; then
    rm -f -- "$tmp"
    return 1
  fi
}

ext_doorbell_tick() {
  local rows reason count
  fm_ext_bridge_opted_in "$FM_HOME" 2>/dev/null || return 0
  rows=$(ext_doorbell_rows) || return 0
  [ -n "$rows" ] || return 0
  count=$(printf '%s\n' "$rows" | grep -c .)
  reason="check: $(printf '%s\n' "$rows" | head -n 3 | awk -F '\t' '{ printf "%s%s", sep, $2; sep = "; " }')"
  [ "$count" -le 3 ] || reason="$reason; +$((count - 3)) more (see EXT REQUESTS AWAITING ANSWER in the drain)"
  ext_doorbell_mark "$rows" || triage_log "ext doorbell: could not record the rung sequence; a later cycle may ring again"
  wake "$reason"
}

# Unanswered-request backstop, including requests already presented by a drain.
# bin/fm-ext-overdue-lib.sh owns eligibility and cadence; this cycle appends the
# durable row and rings it.
ext_overdue_tick() {
  local payload slug
  fm_ext_overdue_remind_secs > /dev/null
  payload=$(fm_ext_overdue_ring "$FM_HOME" "$STATE") || return 0
  [ -n "$payload" ] || return 0
  slug=${payload#ext-request-overdue }
  slug=${slug%% *}
  fm_wake_append check "ext-request-overdue:$slug" "$payload" || return 1
  triage_log "ext overdue: $slug re-surfaced"
  wake "check: $payload"
}

# Converge state/ext-watch.check.sh with config/ext-bridge every cycle, so a
# bridge switched on or off mid-session needs no restart; fm-ext-lib.sh owns the
# arm and remove rules. Logs only when the shim appears or disappears.
ext_bridge_converge_tick() {
  local shim before=0 after=0 verdict
  shim=$(fm_ext_watch_shim_path "$FM_HOME") || return 0
  { [ -e "$shim" ] || [ -L "$shim" ]; } && before=1
  verdict=$(fm_ext_watch_shim_converge "$FM_HOME" "$FM_ROOT" 2>/dev/null) || return 0
  { [ -e "$shim" ] || [ -L "$shim" ]; } && after=1
  [ "$before" = "$after" ] || triage_log "ext bridge: inbox poll shim converged ($verdict)"
}

# Consecutive wedge-escalation count for a window past FM_WEDGE_DEMAND_INSPECT_COUNT
# (default 3): a pane that keeps re-wedging on the SAME stale hash - each
# escalation gets absorbed again as "still validating" one poll later, since the
# hash never changes - can otherwise repeat forever with no signal that this is
# no longer a one-off. At the threshold, wedge_timer_check appends a
# "demand-deep-inspection" marker to the wake payload so the wake reason itself
# (not just repetition the supervisor has to notice on its own) forces a closer
# look instead of another routine supervision resume. Reset wherever a window's
# pane/hash state resets to genuinely active (see the two rm-on-reset call sites
# below).
FM_WEDGE_DEMAND_INSPECT_COUNT=${FM_WEDGE_DEMAND_INSPECT_COUNT:-3}

# One bounded re-surface for a pane the watcher is deliberately absorbing, so no
# absorb can rot invisibly. <age> is how long the current absorb has held and
# <throttle> is the per-window marker whose mtime records the last re-surface, so
# once past PAUSE_RESURFACE_SECS the pane wakes once per window rather than every
# poll. An optional <scope> binds that cadence to its current declaration; callers
# without a scoped declaration keep the timestamp body. Shared by the
# declared-pause absorb and the worktree-write deferral so the two cadences cannot
# drift apart; each caller owns its own marker and reason.
# Returns without waking while either the absorb or the throttle is inside the
# window; wake() itself exits the cycle, exactly as it does inline. [min-age]
# lowers the first re-surface threshold for a wait with no written start (a
# parked gate), whose first threshold should recheck once rather than wait out a
# cadence that has no honest starting point; the throttle still bounds repeats.
resurface_absorbed() {  # <window> <throttle-marker> <age> <reason> [scope] [min-age]
  local win=$1 throttle=$2 age=$3 reason=$4 scope=${5-} min_age=${6:-$PAUSE_RESURFACE_SECS}
  if [ -z "$scope" ] || [ ! -e "$throttle" ] \
    || [ "$(cat "$throttle" 2>/dev/null || true)" = "$scope" ]; then
    [ "$age" -ge "$min_age" ] || return 0
    [ "$(age_of "$throttle")" -ge "$PAUSE_RESURFACE_SECS" ] || return 0   # 999999 when no prior re-surface
  fi
  fm_wake_append stale "$win" "$reason" || exit 1
  if [ -n "$scope" ]; then printf '%s' "$scope" > "$throttle"; else date +%s > "$throttle"; fi
  wake "$reason"
}

# Defer ONE wedge escalation for a pane that went quiet while its own task
# worktree is demonstrably still being written (crew_worktree_written_since in
# fm-classify-lib.sh). The pane and the run step both say nothing is happening;
# the worktree says otherwise, and files appearing in it is the harder signal to
# fake, so the escalation is deferred rather than fired. Deliberately a DEFERRAL,
# not a cancellation: the idle timer restarts, so the next window probes again,
# and a .writing-since-<key> marker ages the whole deferral chain so the pane
# still re-surfaces once every PAUSE_RESURFACE_SECS through the shared
# resurface_absorbed above - literally the same bounded cadence a declared pause
# uses, throttled by its own .writing-resurfaced-<key> marker - and a crew whose
# worktree churns without real progress cannot stay invisible. The escalation
# counter is left alone: it is neither advanced (this is not an escalation) nor
# reset (a later genuine escalation must still carry the demand-deep-inspection
# history it had already earned).
wedge_defer_writing() {  # <window> <since-file> <triage-label> <idle-age>
  local win=$1 since_file=$2 label=$3 age=$4 key wsf wage
  key=$(window_key "$win")
  wsf="$STATE/.writing-since-$key"
  [ -e "$wsf" ] || date +%s > "$wsf"
  wage=$(age_of "$wsf")
  date +%s > "$since_file"
  resurface_absorbed "$win" "$STATE/.writing-resurfaced-$key" "$wage" \
    "stale: $win (idle ${age}s, writing its worktree for ${wage}s, rechecked on a long cadence not a wedge; confirm the writes are real progress)"
  triage_log "absorbed $label (worktree written since the idle window opened, idle ${age}s): $win"
}

# Decide whether this task currently has a captain hold using the backlog's
# authoritative reader; unreadable backlog state is not treated as a hold.
task_captain_call_open() {  # <task>
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" open "$1" \
    >/dev/null 2>&1
}

# One wait record, carrying every field a recheck needs to be correct. Emitting
# them together is the point: a recheck that names the wrong human, or asks for
# an action that does not clear the lane, points the reader away from the only
# person who can end the wait, so a new kind of evidence must not be able to
# reach wedge_defer_wait without deciding all of them.
#   <kind>       what the evidence IS, as the recheck names it.
#   <subject>    WHO the wait is on, in the recheck's own words.
#   <whom>       `captain` when that subject is the captain, `supervisor` when
#                it is firstmate itself, `external` otherwise; this is what
#                applies the away-posture rule below, which only `captain` takes.
#   <action>     the one thing that clears the lane.
#   <age-record> the file whose mtime is when this wait started, or EMPTY when
#                the wait has no written record. Empty is a real answer, not a
#                degraded one: a gate the pipeline parked was never written down
#                by the worker, so there is no honest age to publish and the
#                deferral publishes none.
# The fields are joined with US (\037) rather than TAB because TAB is an IFS
# WHITESPACE character: consecutive tabs collapse under `read`, so a record with
# an empty middle field would not fail to parse, it would SHIFT every later field
# left into another field's position. US is not IFS whitespace, so consecutive
# delimiters yield genuinely empty fields and the record either parses as written
# or fails the deferral's guard.
wait_record() {  # <kind> <subject> <whom> <action> <age-record>
  printf '%s\037%s\037%s\037%s\037%s' "$1" "$2" "$3" "$4" "$5"
}

# The evidence that a quiet pane is a BOUNDED WAIT rather than a wedge suspect,
# read at the one moment it decides anything: when an escalation is about to
# fire. Two records answer it, and they are independent: the worker's own status
# line - a declared `paused:` external wait, or a verified `captain-held`
# transfer - and, when that line explains nothing, the crew's authoritative
# current state.
#
# The generated brief promises that declaring one buys the long recheck cadence
# instead of a wedge, and the wedge timer is reachable while that declaration
# stands - so the declaration is consulted here too rather than trusted to have
# been caught by the earlier classification.
#
# This fork's status contract has no structured clearing time on a paused line, so
# an open `paused:` declaration is the whole record; a later status verb replaces
# it. The records are read in this order rather than pooled because the routing
# already guarantees it is the right one: a pane whose last line is `paused:` or
# `captain-held:` reaches this timer only through pause_state_class answering
# `working`, so its crew state is a running step, never a parked gate.
#
# The second record is OFF unless the home creates config/wedge-defer-parked-gate,
# and that one guard is what makes an unconfigured home's behaviour identical to
# having no second record at all: it is read before the fold, so no fold or
# crew-state read is spent, no wait record exists to defer on, no recheck wording
# is reachable, and the lane keeps the unchanged escalation schedule, reason and
# demand-deep-inspection wording. Unlike the status line, which is the worker's
# own declaration about its own silence, this record is derived from a pipeline's
# gate state, so which lanes lose the ladder for it is a home's choice to make
# rather than a default every fleet inherits - the same reason
# config/turnend-churn-absorb gates its own widened absorb.
#
# The second record takes TWO signals, and needs both. The crew's authoritative
# current state must be a no-mistakes gate whose answer is owed by a HUMAN
# (crew_gate_awaits_human_decision in fm-classify-lib.sh, minted from the
# findings table's `action` column by position), AND the task's own decision fold
# must still hold an open `needs-decision` record whose key is `nm-<run>-<step>`
# for the run that verdict reports. The gate's table alone says only that the
# answer is owed by a human; the open decision bound to that run is the positive
# evidence that firstmate was actually told about THIS gate and has not answered
# yet, which is what makes the lane's quiet a wait rather than a suspected wedge.
# An open decision under any other key - an unrelated question never closed - is
# not that evidence, and neither is a verdict that names no run. The wait is owed
# by firstmate, not the captain: ask-user findings are routed to firstmate, which
# decides most of them itself, and one it escalates becomes a captain-held
# transfer that the first record above already catches. Away-mode triage stays
# daemon-owned: wedge_defer_wait suppresses watcher recheck output while .afk
# exists, leaving the daemon to route the supervisor-owned answer.
# The two signals come apart in both directions, and the ladder is kept in each:
#   - the decision was ANSWERED and the crewmate has not yet relayed it with
#     `axi respond`: the gate is still reported parked and still carries the
#     ask-user row, but `fm-send --resolve-key` wrote the closing `resolved` line
#     at answer time, so the fold is empty and what is outstanding is the
#     crewmate's OWN next move;
#   - the crewmate parked at a human-owed gate and went quiet before escalating
#     it at all: nobody was ever told, so there is no wait to defer to.
# A `blocked` record does not count: a blocker is not an unanswered gate decision
# and a different action clears it. A gate awaiting the CREWMATE's own answer is
# deliberately NOT evidence either: a crewmate that goes quiet before answering
# its own gate is exactly the wedge this ladder exists to catch, so those keep
# the unchanged schedule, reason and demand-deep-inspection wording.
# Nothing here weakens detection for a pane with no wait at all - their
# escalation schedule, reason and wording are untouched, and every way this
# signal can come back empty (an unreadable status file, a fold with nothing
# open, a key convention nobody followed) escalates on the unchanged schedule
# rather than losing the ladder. The status-line and fold reads are file reads;
# the crew-state read is the costly one (it may make a bounded no-mistakes call),
# so it is taken only behind a first fold read that finds some open
# `needs-decision` at all, and only in the at-threshold branch - at most once per
# window per STALE_ESCALATE_SECS, never on an ordinary poll.
wedge_wait_evidence() {  # <task> -> one wait_record on stdout
  local task=$1 last statusf run
  [ -n "$task" ] || return 1
  statusf="$STATE/$task.status"
  last=$(last_status_line "$statusf")
  if status_is_captain_held "$last"; then
    wait_record 'captain-held' 'awaiting the captain - verified hold transfer' \
      captain 'answer the held decision or release the hold' "$statusf"
    return 0
  fi
  if status_is_paused "$last"; then
    # An active run-step outranks a stale paused line: the crew resumed after
    # appending it, so the old declaration no longer explains the quiet. This is
    # the same precedence pause_state_class applies before the timer.
    local line
    line=$("$FM_CREW_STATE_BIN" "$task" 2>/dev/null) || true
    case "$line" in
      "state: working"*"source: run-step"*) return 1 ;;
    esac
    wait_record 'declared wait' 'awaiting external' \
      external 'confirm the wait still holds' "$statusf"
    return 0
  fi
  [ -e "$CONFIG/wedge-defer-parked-gate" ] || return 1
  if status_has_open_needs_decision "$statusf" \
    && run=$(crew_gate_awaits_human_decision "$task") \
    && status_has_open_needs_decision "$statusf" "$run"; then
    wait_record 'verified wait at a parked gate' "awaiting firstmate's ask-user decision" \
      supervisor "decide the gate's ask-user finding and relay the decision to the crewmate" ''
    return 0
  fi
  return 1
}

# Defer ONE wedge escalation for a pane whose wait record explains the quiet
# (wedge_wait_evidence above). Deliberately the same shape as
# wedge_defer_writing: a DEFERRAL, not a cancellation, so the idle timer restarts
# and the next window probes the evidence again - a wait that ends is escalating
# again within one STALE_ESCALATE_SECS, which is why the worst-case detection
# time for a pane that stops waiting does not move.
# Every word of the recheck that could be wrong per kind of evidence - the human
# it names, the action it asks for, the age it publishes - is READ FROM THE
# RECORD rather than re-derived here, so this function cannot word one kind of
# wait as another.
# A wait with a written record is aged from that file, which is when the worker
# wrote the line - anchored there rather than on a per-window marker for the same
# reason handle_paused_stale is: an idle pane churns its display (a clock, a
# token counter), and a marker this deferral kept touching would let that churn
# reset the cadence. A wait with NO written record publishes no age at all: the
# quiet window is the only clock in hand and this deferral resets it on every
# pass, so a number read from it would never grow and would tell a supervisor
# that a day-old gate opened four minutes ago. The bounded re-surface still
# fires, governed by its own throttle instead of by a wait age.
# A CAPTAIN-facing wait is not rechecked at all while the away-posture record
# exists: the one human who can answer it is away, the return brief already lists
# it, and every other captain-facing path in this file absorbs it silently for
# that reason (handle_paused_stale, surface_nonterminal_stale,
# captain_call_stale_bound). That absorb arms no throttle and deliberately
# leaves the idle timer alone. The costly parked-gate consult is owed to the
# supervisor instead, never silenced here, and its own deferral restarts the
# timer below.
# The escalation counter is left alone, exactly as the write deferral leaves it:
# this is not an escalation, and a later genuine one must keep the
# demand-inspection history it had already earned.
wedge_defer_wait() {  # <window> <since-file> <triage-label> <idle-age> <wait-record> [min-age]
  local win=$1 since_file=$2 label=$3 age=$4 record=$5 min_age=${6:-$PAUSE_RESURFACE_SECS}
  local kind subject whom action anchor key marker agefile mtime wait_age waited wage us ok
  us=$(printf '\037')
  IFS=$us read -r kind subject whom action anchor <<EOF
$record
EOF
  # Enforce the whole of the record's own contract here, which the US delimiter
  # now makes checkable: `kind`, `subject`, `whom` and `action` are each a field
  # the recheck prints and must be non-empty, `whom` is exactly one of the three
  # values the record contract names, only `anchor` may legitimately
  # be empty, and the record holds exactly four delimiters - a surplus one is
  # visible because `read` puts everything past the last field into `anchor`.
  # A record that fails any of these is refused rather than deferred: deferring
  # is what takes the ladder away, so the unparseable case must fall back to the
  # escalation the caller was about to make.
  ok=1
  case "$whom" in
    captain|supervisor|external) ;;
    *) ok=0 ;;
  esac
  case "$anchor" in
    *"$us"*) ok=0 ;;
  esac
  if [ -z "$kind" ] || [ -z "$subject" ] || [ -z "$action" ]; then ok=0; fi
  if [ "$ok" -eq 0 ]; then
    triage_log "refused a malformed wait record for $label: $win"
    return 1
  fi
  if [ "$whom" = captain ] && afk_present; then
    triage_log "absorbed $label ($kind, never rechecked while the away-posture record exists): $win"
    return 0
  fi
  key=$(window_key "$win")
  marker="$STATE/.wait-resurfaced-$key"
  agefile="$STATE/.wait-since-$key"
  [ -e "$agefile" ] || date +%s > "$agefile"
  wait_age=$(age_of "$agefile")
  waited=''
  if [ -n "$anchor" ]; then
    mtime=$(stat_mtime "$anchor")
    if [ -n "$mtime" ] && [ "$mtime" -gt 0 ] 2>/dev/null; then
      wage=$(( $(date +%s) - mtime ))
      [ "$wage" -ge 0 ] || wage=0
      waited=", waiting ${wage}s"
      # The wait's own written age bounds the re-surface too, so a long wait
      # cannot be reported inside a cadence that started only after a restart.
      [ "$wait_age" -lt "$wage" ] && wait_age=$wage
    fi
  fi
  date +%s > "$since_file"
  if ! afk_present; then
    # A wait that has no written record (a parked gate) publishes no age, so its
    # first threshold delivers one recheck immediately rather than waiting out a
    # cadence that has no honest starting point; the throttle owns every repeat.
    resurface_absorbed "$win" "$marker" "$wait_age" \
      "stale: $win (idle ${age}s${waited} - $kind, $subject, rechecked on a long cadence not a wedge; $action)" \
      '' "$min_age"
  fi
  triage_log "absorbed $label ($kind, $subject, idle ${age}s): $win"
  return 0
}

# Drop a window's write-deferral chain wherever its stale bookkeeping resets, so
# the bounded re-surface cadence is measured from the CURRENT quiet stretch and a
# long-finished one cannot make the next deferral resurface immediately. The
# held-alert backoff ledger is episode-scoped in the same way: a real pane,
# status, or decision change drops it here so the unchanged path resumes at once.
clear_wedge_deferral_tracking() {  # <window-key>
  local key=$1
  rm -f "$STATE/.writing-since-$key" "$STATE/.writing-resurfaced-$key" \
    "$STATE/.wait-since-$key" "$STATE/.wait-resurfaced-$key" \
    "$STATE/.held-alert-$key" "$STATE/.held-alert-check-$key"
}

# --- linked captain-decision backoff -----------------------------------------
#
# An endpoint (a secondmate id or an ordinary task id) can be linked to a
# captain call through bin/fm-captain-hold.sh, whose header owns the record
# format and the `endpoint-open` predicate. While that call is open and the
# endpoint's stale condition is unchanged, repeat wedge escalations back off
# instead of firing once per cycle. The ledger
# state/.held-alert-<window-key> holds
#   <hold-task>\t<hold-identity>\t<folds>\t<last-reminder-epoch>\t<interval>
# so the schedule and the folded-repeat count survive a watcher restart. The
# first escalation of an episode always fires; later reminders double <interval>
# from HELD_ALERT_BACKOFF_SECS up to HELD_ALERT_BACKOFF_MAX_SECS. A real change
# (pane hash, linked call answered/released/re-held, or the endpoint reachable
# again) drops the ledger through the ordinary reset paths; a status change
# always surfaces its own signal wake, so it never waits on this backoff. The
# next cycle then uses the unchanged escalation ladder.
# docs/configuration.md owns the behavior contract.

# The open captain call linked to <endpoint>, as "<task-id>\t<identity>", or
# nonzero when none is open. The hold script's `endpoint-open` is the single
# owner of link parsing and of the open-call test; its exit 2 (unreadable
# record) is read as not-held here so an unreadable record never suppresses an
# alert.
held_endpoint_decision() {  # <endpoint>
  local out
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" \
    endpoint-open "$1" --identity 2>/dev/null) || return 1
  case "$out" in
    *$'\t'*) printf '%s\n' "$out" ;;
    *) return 1 ;;
  esac
}

# Is <task-id> still an open captain call at exactly <identity>? A re-held call
# keeps its task id but changes the lifecycle identity, which makes it a new
# decision rather than the same wait.
held_decision_still_open() {  # <task-id> <identity>
  local out
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" \
    open "$1" --identity 2>/dev/null) || return 1
  [ "$out" = "$2" ]
}

# Atomically write the backoff ledger. Returns 1 on a write failure; the caller
# treats that as "cannot track", which falls through to the ordinary path rather
# than silently absorbing an alert.
write_held_alert_ledger() {  # <path> <hold> <identity> <folds> <last> <interval>
  local path=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.held-alert.XXXXXX") || return 1
  if ! printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" > "$tmp" \
    || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# The backoff gate for a stale window whose endpoint is covered by an open
# captain call. Returns 0 when it handled the wake (folded a repeat or emitted a
# reminder); 1 when no linked call is open, so the caller keeps the unchanged
# escalation ladder. <since-file> is re-armed on every handled call, so the
# backlog read behind held_endpoint_decision runs once per threshold, never on
# an ordinary poll.
held_alert_tick() {  # <window> <endpoint> <age> <since-file> [now]
  local win=$1 endpoint=$2 age=$3 since_file=$4 now_arg=${5-} now
  now=${now_arg:-$(date +%s)}
  local key ledger decision hold identity old_hold old_identity folds last interval reason
  key=$(window_key "$win")
  ledger="$STATE/.held-alert-$key"
  decision=$(held_endpoint_decision "$endpoint") || { rm -f "$ledger"; return 1; }
  hold=${decision%%$'\t'*}
  identity=${decision#*$'\t'}
  folds=0
  last=0
  interval=$HELD_ALERT_BACKOFF_SECS
  if [ -f "$ledger" ] && [ ! -L "$ledger" ]; then
    IFS=$(printf '\t') read -r old_hold old_identity folds last interval < "$ledger" || true
    case "$folds" in ''|*[!0-9]*) folds=0 ;; esac
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    case "$interval" in ''|0*|*[!0-9]*) interval=$HELD_ALERT_BACKOFF_SECS ;; esac
    [ "$interval" -ge "$HELD_ALERT_BACKOFF_SECS" ] || interval=$HELD_ALERT_BACKOFF_SECS
    [ "$interval" -le "$HELD_ALERT_BACKOFF_MAX_SECS" ] || interval=$HELD_ALERT_BACKOFF_MAX_SECS
    # A different call, or a re-held one, is a new decision: the first
    # escalation of the new episode must not inherit the old schedule.
    if [ "$old_hold" != "$hold" ] || [ "$old_identity" != "$identity" ]; then
      folds=0
      last=0
      interval=$HELD_ALERT_BACKOFF_SECS
    fi
  fi
  if [ "$last" -ne 0 ] && [ "$now" -ge "$last" ] && [ "$((now - last))" -lt "$interval" ]; then
    folds=$((folds + 1))
    write_held_alert_ledger "$ledger" "$hold" "$identity" "$folds" "$last" "$interval" \
      || return 1
    date +%s > "$since_file"
    triage_log "absorbed stale (captain decision $hold open, $folds repeats folded, next reminder in $((interval - (now - last)))s): $win"
    return 0
  fi
  reason="stale: $win (idle ${age}s - captain decision $hold is open, awaiting the captain, ${folds} repeats folded since the last reminder, rechecked on a backed-off cadence not a wedge; captain to answer or release the decision)"
  fm_wake_append stale "$win" "$reason" || exit 1
  # Anchor the interval at the ledger write, not the tick start: the durable
  # append above can be slow under load, and measuring from the start would
  # shorten the next interval by that delay. A caller-supplied clock is kept
  # verbatim so the gate stays deterministically testable.
  [ -n "$now_arg" ] || now=$(date +%s)
  if [ "$last" -ne 0 ]; then
    interval=$((interval * 2))
    [ "$interval" -le "$HELD_ALERT_BACKOFF_MAX_SECS" ] || interval=$HELD_ALERT_BACKOFF_MAX_SECS
  fi
  write_held_alert_ledger "$ledger" "$hold" "$identity" 0 "$now" "$interval" || exit 1
  # The idle timer and the ledger share one instant, so the next threshold can
  # never report the interval elapsed while the idle age still says otherwise.
  printf '%s\n' "$now" > "$since_file"
  wake "$reason"
}

# Per-poll release check while a backoff ledger exists: the moment the linked
# call is answered, released, closed, or re-held, the suppression no longer
# applies, so the ledger is dropped and the wedge timer is backdated to make the
# unchanged escalation path fire on this cycle. A still-current call keeps the
# backoff. The read is bounded to one per HELD_ALERT_RELEASE_CHECK_SECS so a
# long held wait does not pay a backlog read every poll.
held_alert_release_tick() {  # <window> <since-file> [now]
  local win=$1 since_file=$2 now=${3:-$(date +%s)}
  local key ledger check hold identity
  key=$(window_key "$win")
  ledger="$STATE/.held-alert-$key"
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || return 0
  check="$STATE/.held-alert-check-$key"
  if [ "$HELD_ALERT_RELEASE_CHECK_SECS" -gt 0 ] \
    && [ "$(age_of "$check")" -lt "$HELD_ALERT_RELEASE_CHECK_SECS" ]; then
    return 0
  fi
  hold=''
  identity=''
  IFS=$(printf '\t') read -r hold identity _ < "$ledger" || true
  date +%s > "$check"
  if [ -n "$hold" ] && held_decision_still_open "$hold" "$identity"; then
    return 0
  fi
  rm -f "$ledger" "$check"
  printf '%s\n' "$(( now - STALE_ESCALATE_SECS ))" > "$since_file"
  triage_log "released held-alert backoff (linked captain decision changed or closed): $win"
  return 0
}

# Repeat-poll wedge-timer bookkeeping for an already-classified stale hash
# absorbed as provably-working - repairs a missing/corrupt timer (self-heals a
# watcher restart between recording the hash and recording the timer), or
# escalates once STALE_ESCALATE_SECS have elapsed. Never re-reads the crew
# state (the costly check already ran once, at classification time). Shared by
# both places a hash can be absorbed this way: the plain non-terminal path,
# and the stale_is_terminal-overridden path (a captain-relevant status-log
# line that an active run/busy pane outranked).
# The wait-evidence consult (wedge_wait_evidence), the worktree write probe, and
# the opt-in worker-wait/captain-hold records run ONLY here, inside the
# at-threshold branch that is about to escalate: at most one each per window per
# STALE_ESCALATE_SECS, never on an ordinary poll. The crew-state read
# wedge_wait_evidence may take under config/wedge-defer-parked-gate keeps that
# same bound however long the wait lasts, because the deferral it feeds restarts
# the idle timer like every other deferral below; an unconfigured home never
# reaches that read at all. The one exception is the linked-decision release
# check: while a backoff ledger exists it re-reads the linked call at most once
# per HELD_ALERT_RELEASE_CHECK_SECS, because an answered or released decision
# must restore alerting on the next cycle rather than at the next threshold.
wedge_timer_check() {  # <window> <since-file> <triage-label> <escalation-count-file> <task>
  local win=$1 since_file=$2 label=$3 escalation_file=$4 task=$5 since age n reason wait_key evidence wait_min_age
  # An answered, released, or re-held decision lifts the linked-decision
  # backoff before the threshold is read, so the unchanged escalation path
  # fires on this cycle instead of waiting out a suppression that no longer
  # applies.
  held_alert_release_tick "$win" "$since_file"
  since=$(cat "$since_file" 2>/dev/null || true)
  case "$since" in
    ''|*[!0-9]*)
      date +%s > "$since_file"
      clear_wedge_deferral_tracking "$(window_key "$win")"
      triage_log "absorbed $label timer reset: $win"
      ;;
    *)
      age=$(( $(date +%s) - since ))
      if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
        # Escalation boundary: a run that finished while its wedge timer was
        # running is done, not wedged. Absorb on the authoritative run-step
        # state instead of escalating an idle-by-definition pane.
        if ! afk_present && crew_is_run_step_done "$task"; then
          rm -f "$since_file" "$escalation_file"
          clear_wedge_deferral_tracking "$(window_key "$win")"
          triage_log "absorbed $label timer expiry (run-step done, awaiting merge/landing): $win"
          return 0
        fi
        if evidence=$(wedge_wait_evidence "$task"); then
          wait_min_age=$PAUSE_RESURFACE_SECS
          # The parked-gate record is the one wait with no written starting point;
          # its first threshold earns one immediate recheck (throttled thereafter).
          case "$evidence" in
            "verified wait at a parked gate"*) wait_min_age=0 ;;
          esac
          if wedge_defer_wait "$win" "$since_file" "$label" "$age" "$evidence" "$wait_min_age"; then
            return 0
          fi
        fi
        if [ -e "$CONFIG/wedge-defer-worker-wait" ] \
          && verb=$(status_worker_wait_verb "$STATE/$task.status"); then
          if [ "$verb" = blocked ]; then
            evidence=$(wait_record 'worker blocker' 'awaiting the supervisor' \
              supervisor 'firstmate to clear and resolve the blocker' "$STATE/$task.status")
          else
            evidence=$(wait_record 'worker decision' 'awaiting the supervisor' \
              supervisor 'firstmate to answer the decision' "$STATE/$task.status")
          fi
          if wedge_defer_wait "$win" "$since_file" "$label" "$age" "$evidence"; then
            return 0
          fi
        fi
        if [ -n "$task" ] && task_captain_call_open "$task"; then
          evidence=$(wait_record 'backlog captain hold' 'awaiting the captain' \
            captain 'captain to answer or release the hold' '')
          if wedge_defer_wait "$win" "$since_file" "$label" "$age" "$evidence"; then
            return 0
          fi
        fi
        # A captain call can cover an endpoint other than its own task id (a
        # secondmate id, for example). While that linked call is open and the
        # endpoint is unchanged, repeats back off instead of escalating once per
        # cycle; no link leaves this path untouched.
        if [ -n "$task" ] && held_alert_tick "$win" "$task" "$age" "$since_file"; then
          return 0
        fi
        wait_key=$(window_key "$win")
        rm -f "$STATE/.wait-since-$wait_key" "$STATE/.wait-resurfaced-$wait_key"
        if crew_worktree_written_since "$task" "$STATE" "$since_file"; then
          wedge_defer_writing "$win" "$since_file" "$label" "$age"
          return 0
        fi
        n=$(( $(cat "$escalation_file" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$escalation_file"
        reason="stale: $win (idle ${age}s, possible wedge, escalation $n)"
        if [ "$n" -ge "$FM_WEDGE_DEMAND_INSPECT_COUNT" ]; then
          reason="stale: $win (idle ${age}s, possible wedge, escalation $n, demand-deep-inspection: same pane has wedge-escalated $n times in a row - do not re-absorb on the run-step/pane state alone)"
        fi
        fm_wake_append stale "$win" "$reason" || exit 1
        rm -f "$since_file"
        clear_wedge_deferral_tracking "$(window_key "$win")"
        wake "$reason"
      fi
      ;;
  esac
}

# busy_turn_over_age: 0 iff <task>'s latest completed-turn marker is at least
# BUSY_TURN_MAX_SECS old. Ages the per-task live-generation turn-ended marker,
# the harness-neutral signal every verified harness's turn-end hook publishes; before any turn has
# completed, ages the task's spawn record instead so a fresh task still gets a
# bound. The caller checks that the pane is busy and routes a crossed bound
# through busy_turn_bound_check, never anything that touches the worker itself.
busy_turn_over_age() {  # <task>
  local task=$1 f
  f=$(fm_wake_turnend_live_marker "$STATE" "$task" 2>/dev/null || true)
  { [ -n "$f" ] && [ -e "$f" ]; } || f="$STATE/$task.meta"
  [ "$(age_of "$f")" -ge "$BUSY_TURN_MAX_SECS" ]
}

# board_row_in_flight: 0 iff <task>'s row sits under "## In flight" in
# data/backlog.md - the durable board bin/fm-todo-project.sh treats as the
# single source of truth for open work. A read-only section scan using the same
# heading/item grammar as bin/fm-backlog-handoff.sh's backlog_key_section; the
# row key is the first whitespace-separated token after the checkbox. Returns 1
# when the file or the row is absent.
board_row_in_flight() {  # <task>
  local task=$1 backlog="$DATA/backlog.md"
  [ -f "$backlog" ] || return 1
  awk -v key="$task" '
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "", section)
      sub(/[[:space:]]+$/, "", section)
      next
    }
    section == "In flight" && /^- \[[ x]\] / {
      id = $0
      sub(/^- \[[ x]\] +/, "", id)
      sub(/[ \t].*/, "", id)
      if (id == key) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$backlog"
}

# idle_open_work_tick: one bounded completion-boundary probe for a pane that is
# NOT provably busy this poll. The generated status contract (bin/fm-brief.sh)
# requires a terminal or paused status within IDLE_OPEN_WORK_SECS of turn-end
# while the task's board row is in flight; a pane still silent past it -
# including a ticking pane whose hash never repeats, which the stable-hash
# stale path below can never catch - escalates as `idle-with-open-work`.
#
# Gates, cheapest first, each guarding the more expensive reads behind it:
#   - a declared pause/captain-held last line already owns a bounded cadence;
#   - a terminal last line already discharged the boundary contract, so a row
#     still in flight then is a firstmate-side matter, not worker silence;
#   - the .idle-open-work-probe-<window-key>-<task-key> marker caps this probe - and so the one
#     costly crew-state read - at once per bound, whether it fires or absorbs;
#   - the status file's mtime is the last-arrival time, so its age IS "no
#     status line within the bound" (a missing file reads as infinitely old);
#   - the bound runs from the live-generation turn-end marker when one exists,
#     else the spawn record - the same anchor busy_turn_over_age uses - so a
#     crew still inside its turn keeps its full reporting window;
#   - the board row must be in flight: a queued or done row owes no boundary
#     report.
# Under away mode the daemon owns triage, so the wake fires without the costly
# crew-state reads (the same convention the other stale paths keep); always-on,
# a provably-working crew absorbs the probe because a running pipeline
# legitimately sits silent, and a run-step-done crew absorbs it because a
# finished pipeline idles by definition while its row awaits merge/landing.
idle_open_work_tick() {  # <window> <task>
  local win=$1 task=$2 key task_key probe statusf last anchor reason
  key=$(window_key "$win")
  task_key=$(window_key "$task")
  statusf="$STATE/$task.status"
  last=$(last_status_line "$statusf")
  status_is_paused_or_captain_held "$last" && return 0
  # A standing terminal status already discharged the boundary contract; a row
  # still in flight after that is a firstmate-side matter, not worker silence.
  status_is_terminal_verb "$last" && return 0
  probe="$STATE/.idle-open-work-probe-${key}-${task_key}"
  [ "$(age_of "$probe")" -ge "$IDLE_OPEN_WORK_SECS" ] || return 0
  [ "$(age_of "$statusf")" -ge "$IDLE_OPEN_WORK_SECS" ] || return 0
  anchor=$(fm_wake_turnend_live_marker "$STATE" "$task" 2>/dev/null || true)
  { [ -n "$anchor" ] && [ -e "$anchor" ]; } || anchor="$STATE/$task.meta"
  [ "$(age_of "$anchor")" -ge "$IDLE_OPEN_WORK_SECS" ] || return 0
  board_row_in_flight "$task" || return 0
  # A run-step-done crew already finished its pipeline (checks green awaiting
  # merge, run completed); an idle pane is the expected shape, not wedge
  # evidence. Absorb on the authoritative crew state, not the status log's
  # last line, which a trailing resolved event can push off-terminal.
  if ! afk_present && crew_is_run_step_done "$task"; then
    touch "$probe"
    triage_log "absorbed idle-with-open-work probe (run-step done, awaiting merge/landing): $win"
    return 0
  fi
  if ! afk_present && crew_is_provably_working "$task"; then
    touch "$probe"
    triage_log "absorbed idle-with-open-work probe (provably working): $win"
    return 0
  fi
  reason="stale: $win (idle-with-open-work: pane idle, board row in flight, no status within ${IDLE_OPEN_WORK_SECS}s of turn-end)"
  fm_wake_append stale "$win" "$reason" || exit 1
  touch "$probe"
  wake "$reason"
}

# Absorb a stale pane under a declared external-wait pause (paused:) or a
# dead-agent captain-held transfer, and re-surface it once every
# PAUSE_RESURFACE_SECS for a recheck so it cannot rot invisibly. Called on any
# stale poll once pause_state_class permits the bounded cadence, so it must be
# cheap: it NEVER re-reads crew state. The re-surface age is anchored on the
# status file mtime, not a per-hash marker, so a churny idle pane (a ticking
# clock, a token counter) cannot keep resetting the cadence the way a hash-tied
# timer would. The bounded re-surface itself is the shared resurface_absorbed
# above, throttled by this window's own .paused-resurfaced-<key> marker. Advances
# the stale suppressor to <hash> and flags the key paused.
handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key statusf mtime age declaration
  key=$(window_key "$win")
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  clear_wedge_deferral_tracking "$key"
  statusf="$STATE/$task.status"
  mtime=$(stat_mtime "$statusf")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  reason="paused ${age}s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds"
  declaration="declared:$(stat_sig "$statusf" || true)"
  resurface_absorbed "$win" "$STATE/.paused-resurfaced-$key" "$age" "stale: $win ($reason)" "$declaration"
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}

# Apply the busy-pane completed-turn bound to a window whose bound has already
# crossed, honoring the worker's own declared external wait. Prints or queues
# nothing itself; it only chooses which absorber owns the crossed bound.
# Returns 0 when the declared-pause cadence took the pane and 1 when the wedge
# timer did.
#
# A busy pane past BUSY_TURN_MAX_SECS is normally a wedge suspect because a hung
# foreground call can hide behind a busy signature. A paused declaration or
# verified captain-held transfer instead identifies that live foreground call as
# the expected external wait. The caller has already confirmed liveness through
# the busy verdict, so this exception does not suppress undeclared wedges or
# alter the separate non-busy classification. handle_paused_stale keeps the
# exception bounded by re-surfacing it once per PAUSE_RESURFACE_SECS. Away mode
# remains daemon-owned and receives the ordinary wedge path for its own triage.
busy_turn_bound_check() {  # <window> <task> <hash> <since-file> <escalation-file>
  local win=$1 task=$2 h=$3 since_file=$4 escalation_file=$5
  if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
    handle_paused_stale "$win" "$task" "$h"
    return 0
  fi
  wedge_timer_check "$win" "$since_file" "busy (no completed turn)" "$escalation_file" "$task"
  return 1
}

# A RunPod route with a recognized no-host lifecycle is deliberately dormant,
# not an unresponsive agent.
# Anchor its bounded recheck cadence on the provider lifecycle record rather
# than a status line, because sleep and provision are lifecycle operations and
# do not fabricate a crewmate pause event.
handle_compute_dormant_stale() {  # <window> <task>
  local win=$1 task=$2 key record lifecycle h mtime age rf rf_age reason
  key=$(window_key "$win")
  record=$(fm_compute_meta_path "$DATA" "$task") || return 1
  lifecycle=$(fm_compute_lifecycle "$DATA" "$task")
  h=$(printf 'compute dormant: %s:%s' "$task" "$lifecycle" | hash_pane)
  printf '%s' "$h" > "$STATE/.stale-$key"
  : > "$STATE/.paused-$key"
  rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
  clear_wedge_deferral_tracking "$key"
  mtime=$(stat_mtime "$record")
  case "$mtime" in ''|*[!0-9]*) mtime=$(date +%s) ;; esac
  age=$(( $(date +%s) - mtime ))
  rf="$STATE/.paused-resurfaced-$key"
  rf_age=$(age_of "$rf")
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$rf_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (compute lifecycle=$lifecycle dormant ${age}s, rechecked on a long cadence not a wedge; confirm scale-to-zero should continue)"
    fm_wake_append stale "$win" "$reason" || exit 1
    date +%s > "$rf"
    wake "$reason"
  fi
  triage_log "absorbed stale (compute lifecycle=$lifecycle, dormant age ${age}s): $win"
}

clear_pause_state() {  # <window-key>
  local key=$1
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" "$STATE/.paused-resurfaced-$key"
}

# The hash-scoped half of clear_pause_tracking: the stale suppressor, its wedge
# timer and escalation count, and the write-deferral chain. Split out so a caller
# that must keep a window's DECLARATION-scoped pause state - its .paused-* flag,
# recheck, and re-surface throttle - can still reset the per-hash half alone.
clear_stale_hash_tracking() {  # <window-key>
  local key=$1
  clear_wedge_deferral_tracking "$key"
  rm -f "$STATE/.stale-$key" "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key" \
    "$STATE/.remote-inconclusive-$key"
}

clear_pause_tracking() {  # <window-key>
  local key=$1
  clear_pause_state "$key"
  clear_stale_hash_tracking "$key"
}

# Reconcile a declared pause or captain-held status with authoritative crew state.
# Only a confidently dead ordinary crew may recover paused classification after
# fm-crew-state has fallen back to stopped or unknown.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck_file class agent_alive
  key=$(window_key "$win")
  last=$(last_status_line "$STATE/$task.status")
  recheck_file="$STATE/.paused-rechecked-$key"
  if ! status_is_paused_or_captain_held "$last"; then
    rm -f "$recheck_file"
    crew_absorb_class "$task"
    return
  fi
  if [ -e "$STATE/.paused-$key" ] && [ "$(age_of "$recheck_file")" -lt "$STALE_ESCALATE_SECS" ]; then
    if [ "$(window_kind "$win")" != secondmate ]; then
      agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
      if [ "$agent_alive" != dead ]; then
        rm -f "$recheck_file"
        printf 'none'
        return
      fi
    fi
    printf 'paused'
    return
  fi
  class=$(crew_absorb_class "$task")
  if [ "$class" = working ]; then
    rm -f "$recheck_file"
    printf 'working'
    return
  fi
  if [ "$(window_kind "$win")" != secondmate ]; then
    agent_alive=$(fm_backend_agent_alive "$(window_backend "$win")" "$win" 2>/dev/null) || agent_alive=unknown
    if [ "$agent_alive" != dead ]; then
      rm -f "$recheck_file"
      printf 'none'
      return
    fi
  fi
  [ "$class" = none ] && [ "${agent_alive:-unknown}" = dead ] && class=paused
  case "$class" in
    paused) date +%s > "$recheck_file" ;;
    *) rm -f "$recheck_file" ;;
  esac
  printf '%s' "$class"
}

# Surface a stale pane no classifier could resolve, so firstmate inspects it: it
# may have finished through an interactive menu that wrote no status, be waiting on
# a decision, or be wedged. pause_state_class deliberately answers `none` for a
# still-LIVE agent even under a declared wait, so a worker genuinely waiting on a
# decision is never silenced - which routes every parked-but-live worker here, on
# first sight of each distinct stale hash.
#
# So a declared wait bounds this path to the same once-per-PAUSE_RESURFACE_SECS
# cadence resurface_absorbed owns for the absorbed paths, throttled by this
# window's own .paused-resurfaced-<key> marker: an idle parked pane still churns
# its hash (a clock, a token counter), and each new hash re-enters this path, so
# without that bound one declared wait re-alarms firstmate for its whole duration.
# The FIRST sight still wakes, keeping the inspect-an-inconclusive-state intent,
# and the throttle is read BEFORE anything is queued and advanced only by a wake
# that really fires - a throttle written by the wake it should have prevented, or
# read after that wake was already appended, bounds nothing.
surface_nonterminal_stale() {  # <window> <hash>
  local win=$1 h=$2 key task last declaration='' declared=1 throttled=1
  key=$(window_key "$win")
  task=$(window_to_task "$win" "$STATE")
  # A run-step-done crew finished its pipeline while its board row still sits
  # in flight; the log tail may read non-terminal (a trailing resolved event)
  # even though there is nothing left to inspect. Absorb on the authoritative
  # crew state instead of surfacing an inconclusive-state wake per hash.
  if ! afk_present && crew_is_run_step_done "$task"; then
    printf '%s' "$h" > "$STATE/.stale-$key"
    rm -f "$STATE/.stale-since-$key" "$STATE/.wedge-escalations-$key"
    clear_wedge_deferral_tracking "$key"
    triage_log "absorbed non-terminal stale (run-step done, awaiting merge/landing): $win"
    return 0
  fi
  last=$(last_status_line "$STATE/$task.status")
  if status_is_paused_or_captain_held "$last"; then
    declared=0
    declaration="declared:$(stat_sig "$STATE/$task.status" || true)"
    if [ "$(cat "$STATE/.paused-resurfaced-$key" 2>/dev/null || true)" = "$declaration" ] \
      && [ "$(age_of "$STATE/.paused-resurfaced-$key")" -lt "$PAUSE_RESURFACE_SECS" ]; then
      throttled=0
    fi
  fi
  if [ "$throttled" -ne 0 ]; then
    fm_wake_append stale "$win" "stale: $win" || exit 1
  fi
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  clear_wedge_deferral_tracking "$key"
  if [ "$declared" -eq 0 ]; then
    : > "$STATE/.paused-$key"
    date +%s > "$STATE/.paused-rechecked-$key"
    [ "$throttled" -eq 0 ] || printf '%s' "$declaration" > "$STATE/.paused-resurfaced-$key"
  else
    clear_pause_state "$key"
  fi
  if [ "$throttled" -eq 0 ]; then
    triage_log "absorbed non-terminal stale (declared wait already re-surfaced this window): $win"
    return 0
  fi
  wake "stale: $win"
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
# A fresh secondmate-home watcher beacon is positive evidence that the secondmate
# supervisor is still alive, even when its own pane is idle between child polls.
# The beacon is written by this same watcher process at the top of every cycle,
# and the parent uses the wedge threshold as its maximum acceptable age. A
# missing or stale beacon deliberately falls through to the ordinary stale path,
# preserving wedge detection for an unresponsive supervisor.
run_with_deadline() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=1 "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --kill-after=1 "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    # shellcheck disable=SC2016
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 124
  fi
}

# 0 = alive (a fresh beacon), 1 = conclusive stale (an answer that is missing,
# stale, or shaped wrong for a local home), and 2 = inconclusive remote evidence:
# the probe hit its deadline, returned no answer, or emitted non-numeric output.
# Only the caller may turn 2 into a stale verdict, and only after the route's
# consecutive-inconclusive bound.
secondmate_supervision_is_alive() {  # <window> <meta> <remote-host>
  local win=$1 meta=$2 remote_host=$3 home beat task age
  [ -n "$meta" ] || return 1
  if [ -n "$remote_host" ]; then
    task=$(window_to_task "$win" "$STATE")
    age=$(run_with_deadline "$REMOTE_TIMEOUT" "$ON_BIN" "$task" \
      fm-remote-secondmate-control.sh beacon-age "$task" </dev/null 2>/dev/null) || return 2
    case "$age" in ''|*[!0-9]*) return 2 ;; esac
    [ "$age" -ge 0 ] && [ "$age" -lt "$STALE_ESCALATE_SECS" ] && return 0
    return 1
  fi
  home=$(grep '^home=' "$meta" | cut -d= -f2- || true)
  [ -n "$home" ] || return 1
  beat="$home/state/.last-watcher-beat"
  [ -f "$beat" ] && [ ! -L "$beat" ] || return 1
  age=$(age_of "$beat")
  case "$age" in ''|*[!0-9]*) return 1 ;; esac
  [ "$age" -ge 0 ] && [ "$age" -lt "$STALE_ESCALATE_SECS" ]
}

age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted inode:size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended.* "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

# Classify every newly appended status event, not only the latest line.  A
# later working: note must not hide an earlier needs-decision/blocked/done event
# in the same append span.  The offset sidecar is advanced only after the wake
# has either been surfaced or deliberately absorbed.
# Also populates FM_SIGNAL_NEEDS_DECISION_FILES (space-separated status-file
# paths) with exactly the files whose newly classified span carries one of the
# decision-owned classes defined by the status-span contract, so the caller can
# route those - and only those - signal rows as main-only
# (docs/omp-supervision-branch.md). Stale and heartbeat rows retain their
# existing eligibility rules.
signal_files_actionable() {  # <status-file> ...
  local f record needs_decision rc start endpoint ident rest found=1
  FM_SIGNAL_SURFACE_ENDPOINTS=''
  FM_SIGNAL_NEEDS_DECISION_FILES=''
  for f in "$@"; do
    case "$f" in *.status) ;; *) continue ;; esac
    [ -e "$f" ] || [ -L "$f" ] || continue
    start=$(fm_wake_signal_seen_size "$STATE" "$f")
    record=''; needs_decision=0
    status_span_first_actionable_record "$f" "$start" record needs_decision
    rc=$?
    [ "$rc" -eq 1 ] && [ -z "$record" ] && continue
    if [ "$rc" -eq 2 ]; then
      found=0
      continue
    fi
    endpoint=${record%%$'\t'*}
    rest=${record#*$'\t'}
    ident=${rest%%$'\t'*}
    FM_SIGNAL_SURFACE_ENDPOINTS="${FM_SIGNAL_SURFACE_ENDPOINTS}${f}"$'\t'"${endpoint}"$'\t'"${ident}"$'\n'
    if [ "$needs_decision" -eq 1 ]; then
      FM_SIGNAL_NEEDS_DECISION_FILES="${FM_SIGNAL_NEEDS_DECISION_FILES} ${f}"
    fi
    if [ "$rc" -eq 0 ] || [ "$needs_decision" -eq 1 ]; then
      found=0
    fi
  done
  return "$found"
}

# Deliver a classified action-worthy signal set: one durable row per file, the
# per-file decision-owned payload retained, every .seen signature advanced, every
# classified span endpoint committed, and the exact reason line printed once.
# Shared by the immediate path and the batching fallback so the two can never
# diverge on marker or payload semantics.
deliver_pending_signals() {  # <pending-tsv> <reason>
  local pending=$1 reason=$2 sf sig f file_reason files=''
  while IFS=$(printf '\t') read -r sf sig f; do
    [ -n "$sf" ] || continue
    case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
  done <<EOF
$pending
EOF
  while IFS=$(printf '\t') read -r sf sig f; do
    [ -n "$sf" ] || continue
    file_reason="$reason"
    case " $FM_SIGNAL_NEEDS_DECISION_FILES " in *" $f "*) file_reason="needs-decision:$files" ;; esac
    fm_wake_append signal "$(basename "$f")" "$file_reason" || exit 1
  done <<EOF
$pending
EOF
  while IFS=$(printf '\t') read -r sf sig f; do
    [ -n "$sf" ] || continue
    printf '%s' "$sig" > "$sf"
  done <<EOF
$pending
EOF
  while IFS=$(printf '\t') read -r f surface_end surface_ident; do
    [ -n "$f" ] || continue
    fm_wake_status_seen_commit "$STATE" "$f" "$surface_end" "$surface_ident" || true
    mark_surfaced "$f"
  done <<EOF
$FM_SIGNAL_SURFACE_ENDPOINTS
EOF
  wake "$reason"
}

# --- Echo batching -----------------------------------------------------------
# Eligible status-only and bare turn-end signals share a batching window; they
# need not already have been delivered. This defers them and delivers
# the group as ONE wake - one enqueue group, one printed reason, one supervisor
# turn - which is the larger saving the 2026-11-06 replay measured (the
# SIGNAL_GRACE coalescing above already merges only near-simultaneous signals).
#
# IMMEDIATE classes are never deferred: any `check:` wake (Discord ext-request,
# merged-PR, process-event, usage), any `stale:` wake, a heartbeat backstop, the
# away-mode daemon's triage (it owns classification, so this watcher must stay
# one-shot), and any status event whose span verb is needs-decision, blocked,
# done, or failed. Decision-owned rows are immediate for the same reason they
# are main-only: a branch-held decision must not sit behind a batch. Anything
# the captain types never enters this path at all. A pending batch is flushed
# into the durable queue immediately before any other wake is delivered, so an
# urgent wake carries the deferred rows with it instead of making the supervisor
# wait out the window.
#
# The window opens at the first deferred echo, defaults to 120 s, and is tunable
# through config/wake-echo-batch: a whole number of seconds in [60,300], or
# `off`. An invalid value falls back to 120 and logs once per
# watcher process. The batch is persisted at state/.echo-batch as
# `<deferred-epoch>\t<signal-file>` lines, so a watcher restart cannot lose it;
# an overdue batch is flushed at the top of the next cycle.
#
# Two drop rules, both evaluated only when the whole batch is bare turn-ended
# markers (a status-bearing batch is always delivered), and both requiring an
# ACTIVE rendered blocking marker - the worker is visibly blocked on a live
# call, so its turn boundary carries nothing:
#   answered-gate (R2 in the replay): every task is parked at a no-mistakes
#     gate whose current run and step key has a resolved event after its latest
#     needs-decision opening, so what is outstanding is the crewmate's own relay.
#   no-change (R3): every task's fm-crew-state line is byte-identical to the
#     line recorded when its last wake was delivered, the pane is actively
#     blocked, and firstmate has not steered the task since that delivery.
# Every near miss - unanswered gate, changed crew-state line, no recorded
# baseline, idle pane, a steer since the last wake - delivers the batch
# unchanged. Each deferral, flush, and drop is recorded in state/.watch-triage.log
# with its rule name, so what was held or skipped is auditable.
ECHO_BATCH_DEFAULT_SECS=120
ECHO_BATCH_MIN_SECS=60
ECHO_BATCH_MAX_SECS=300
ECHO_BATCH_FILE="$STATE/.echo-batch"
ECHO_BATCH_IN_FLUSH=0
ECHO_BATCH_RESOLVED=

# Resolve the window ONCE into ECHO_BATCH_RESOLVED (seconds, 0 = disabled).
# Resolving in a command substitution would lose the one-warning guard and re-read
# the config on every poll, so this sets the global and every caller reads it.
# Invalid input is never silently reinterpreted as "off": it falls back to the
# documented default and warns once, because a typo must not disable the feature
# unnoticed.
echo_batch_resolve() {
  local raw valid
  [ -n "$ECHO_BATCH_RESOLVED" ] && return 0
  if [ -e "$CONFIG/wake-echo-batch" ] && [ ! -L "$CONFIG/wake-echo-batch" ]; then
    raw=$(head -1 "$CONFIG/wake-echo-batch" 2>/dev/null || true)
  else
    ECHO_BATCH_RESOLVED=$ECHO_BATCH_DEFAULT_SECS
    return 0
  fi
  raw=$(printf '%s' "$raw" | tr -d '[:space:]')
  case "$raw" in
    off)
      ECHO_BATCH_RESOLVED=0
      return 0
      ;;
  esac
  valid=1
  case "$raw" in
    [1-9][0-9]|[1-9][0-9][0-9]) ;;
    *) valid=0 ;;
  esac
  if [ "$valid" -eq 1 ] && { [ "$raw" -lt "$ECHO_BATCH_MIN_SECS" ] || [ "$raw" -gt "$ECHO_BATCH_MAX_SECS" ]; }; then
    valid=0
  fi
  if [ "$valid" -eq 1 ]; then
    ECHO_BATCH_RESOLVED=$raw
  else
    ECHO_BATCH_RESOLVED=$ECHO_BATCH_DEFAULT_SECS
    triage_log "echo-batch config invalid (expected ${ECHO_BATCH_MIN_SECS}-${ECHO_BATCH_MAX_SECS} or off); using ${ECHO_BATCH_DEFAULT_SECS}s"
  fi
  return 0
}

echo_batch_enabled() {
  echo_batch_resolve
  [ "$ECHO_BATCH_RESOLVED" -gt 0 ]
}

# 0 when the newly appended span of any referenced status file carries an event
# verb that must never wait for the window.
signal_batch_must_deliver() {  # <file> ...
  local f start
  [ -z "$FM_SIGNAL_NEEDS_DECISION_FILES" ] || return 0
  for f in "$@"; do
    case "$f" in *.status) ;; *) continue ;; esac
    [ -e "$f" ] || continue
    start=$(fm_wake_signal_seen_size "$STATE" "$f")
    status_span_has_immediate_verb "$f" "$start" && return 0
  done
  return 1
}

# Append one deferred entry unless that exact file is already in the window.
# Lines are appended (not rewritten) so a crash can only duplicate an entry,
# which the flush deduplicates by file; the window's opening epoch stays the
# first line's, so a repeated turn boundary never extends the window.
echo_batch_add() {  # <file> ...
  local f now
  now=$(date +%s)
  for f in "$@"; do
    [ -n "$f" ] || continue
    [ -e "$f" ] || continue
    if [ -f "$ECHO_BATCH_FILE" ] \
      && awk -F '\t' -v f="$f" '$2 == f { found=1 } END { exit found ? 0 : 1 }' "$ECHO_BATCH_FILE"; then
      continue
    fi
    printf '%s\t%s\n' "$now" "$f" >> "$ECHO_BATCH_FILE" || return 1
  done
  return 0
}

# Defer a classified action-worthy pending set instead of delivering it. Writes
# the durable batch BEFORE advancing any marker, so a crash between the two can
# duplicate an entry but never lose one. Advances the same .seen signatures and
# classified span endpoints the delivery path would, so the deferred event is
# not re-classified on the next status append, and marks its captain-relevant
# line surfaced so the heartbeat backstop does not pre-empt the window. A marker
# write failure returns 1 and the caller delivers immediately (safe direction);
# a duplicated queue row later is possible only in that crash window.
echo_batch_defer() {  # <pending-tsv>
  local pending=$1 sf sig f status=0 window logged=''
  echo_batch_resolve
  window=$ECHO_BATCH_RESOLVED
  while IFS=$(printf '\t') read -r sf sig f; do
    [ -n "$sf" ] || continue
    echo_batch_add "$f" || status=1
  done <<EOF
$pending
EOF
  [ "$status" -eq 0 ] || return 1
  while IFS=$(printf '\t') read -r sf sig f; do
    [ -n "$sf" ] || continue
    printf '%s' "$sig" > "$sf" || status=1
  done <<EOF
$pending
EOF
  while IFS=$(printf '\t') read -r f surface_end surface_ident; do
    [ -n "$f" ] || continue
    fm_wake_status_seen_commit "$STATE" "$f" "$surface_end" "$surface_ident" || status=1
    mark_surfaced "$f"
  done <<EOF
$FM_SIGNAL_SURFACE_ENDPOINTS
EOF
  while IFS=$(printf '\t') read -r sf sig f; do
    [ -n "$sf" ] || continue
    case " $logged " in *" $f "*) continue ;; esac
    logged="$logged $f"
    triage_log "echo-batch defer rule=window window=${window}s file=$(basename "$f")"
  done <<EOF
$pending
EOF
  return "$status"
}

# 0 when the persisted batch's window has elapsed (or batching is now disabled,
# or the batch's opening epoch is unreadable - in every case waiting longer
# cannot help).
echo_batch_due() {
  local first now
  [ -s "$ECHO_BATCH_FILE" ] || return 1
  [ ! -e "$STATE/.afk" ] || return 0
  echo_batch_resolve
  [ "$ECHO_BATCH_RESOLVED" -gt 0 ] || return 0
  first=$(awk -F '\t' 'NF >= 2 && $1 ~ /^[0-9]+$/ { print $1; exit }' "$ECHO_BATCH_FILE")
  case "$first" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  [ "$now" -ge "$((first + ECHO_BATCH_RESOLVED))" ]
}

echo_batch_flush_due() {
  echo_batch_due || return 0
  echo_batch_flush due
}

# Record <task>'s delivered-wake baseline: the epoch of the wake that was just
# delivered and the exact crew-state line at that moment. R3 compares against
# this pair and nothing else, so it is written only on a real delivery.
echo_batch_record_delivered() (  # <epoch> <task> ...
  local epoch=$1 task line gen tmp
  shift
  fm_lock_try_acquire "$STATE/.echo-baseline.lock" || return 0
  trap 'fm_lock_release "$STATE/.echo-baseline.lock"' EXIT
  for task in "$@"; do
    [ -n "$task" ] || continue
    line=$("$FM_CREW_STATE_BIN" "$task" 2>/dev/null || true)
    line=$(printf '%s' "$line" | tr '\t\r\n' '   ')
    # The incarnation is part of the baseline: a relaunch under the same task id
    # must never inherit its predecessor's "nothing changed" evidence.
    gen=$(fm_meta_get "$STATE/$task.meta" spawn_gen 2>/dev/null || true)
    gen=$(printf '%s' "$gen" | tr '\t\r\n' '   ')
    tmp="$STATE/.last-delivered-$task.tmp.$$"
    if printf '%s\t%s\t%s\n' "$epoch" "$gen" "$line" > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$STATE/.last-delivered-$task" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  done
)

# Map a delivered reason line back to the task baselines it covers. Called for
# every wake, so only the two reason grammars that name task-owned files are
# parsed; every other class records no baseline and therefore can never license
# a drop.
echo_batch_note_delivery() {  # <reason>
  local reason=$1 now f task seen=''
  now=$(date +%s)
  case "$reason" in
    signal:*)
      for f in ${reason#signal:}; do
        task=${f##*/}
        case "$task" in
          *.status) task=${task%.status} ;;
          *.turn-ended) task=${task%.turn-ended} ;;
          *.turn-ended.*) task=${task%.turn-ended.*} ;;
          *) continue ;;
        esac
        case " $seen " in *" $task "*) continue ;; esac
        seen="$seen $task"
        echo_batch_record_delivered "$now" "$task"
      done
      ;;
    stale:*)
      # shellcheck disable=SC2086 # deliberate word split: window then detail text
      set -- ${reason#stale: }
      task=
      [ -n "${1:-}" ] && task=$(window_to_task "$1" "$STATE")
      [ -z "$task" ] || echo_batch_record_delivered "$now" "$task"
      ;;
  esac
}

gate_decision_recorded() {  # <status-file> <key>
  local statusf=$1 key=$2 line untimed verb k opened=0 answered=0
  [ -f "$statusf" ] && [ -r "$statusf" ] && [ ! -L "$statusf" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    _fm_status_untimed "$line" untimed
    verb=$(status_line_verb "$untimed")
    k=$(_fm_decision_key "$untimed") || continue
    [ "$k" = "$key" ] || continue
    case "$verb" in
      needs-decision) opened=1; answered=0 ;;
      resolved) [ "$opened" -eq 0 ] || answered=1 ;;
    esac
  done < "$statusf"
  [ "$answered" -eq 1 ]
}

# 0 when the window's pane renders an ACTIVE blocking marker. This is a rendered
# surface, so it is deliberately a positive-only signal: OMP renders "<glyph>
# Blocking..." while a tool call is live, and no other supported harness is
# claimed here. A harness that renders nothing matching simply never licenses a
# drop, which is the safe direction; the glyph and intent are matched as two
# independent facts on one line rather than one exact vendor string.
pane_is_blocking() {  # <window>
  local w=$1 tail40 recent
  tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || return 1
  [ -n "$tail40" ] || return 1
  # Active means CURRENT: the rendered status line sits immediately above the
  # footer, so only the newest non-blank rows carry the verdict. Matching the
  # whole capture would let a scrolled-away line license a drop long after the
  # call finished.
  recent=$(printf '%s\n' "$tail40" | grep -v '^[[:space:]]*$' | tail -n 10)
  [ -n "$recent" ] || return 1
  printf '%s\n' "$recent" | grep -F '⎋' 2>/dev/null | grep -F 'Blocking' >/dev/null 2>&1
}

pane_is_blocking_for_task() {  # <task>
  local task=$1 meta w
  [ -n "$task" ] || return 1
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || return 1
  w=$(fm_backend_target_of_meta "$meta" 2>/dev/null) || return 1
  [ -n "$w" ] || return 1
  pane_is_blocking "$w"
}

# R2 answered-gate drop: every task is parked at a no-mistakes gate, its gate key
# already has a recorded firstmate decision, and its pane is actively blocked.
echo_batch_answered_gate_drop() {  # <task> ...
  local task statusf key line rest part run step
  [ "$#" -gt 0 ] || return 1
  for task in "$@"; do
    [ -n "$task" ] || return 1
    line=$("$FM_CREW_STATE_BIN" "$task" 2>/dev/null) || return 1
    case "$line" in 'state: parked · source: run-step · '*) ;; *) return 1 ;; esac
    run=; step=; rest="$line · "
    while [ -n "$rest" ]; do
      part=${rest%% · *}
      rest=${rest#* · }
      case "$part" in
        'run: '*) run=${part#run: } ;;
        'parked at '*) step=${part#parked at }; step=${step%%:*} ;;
      esac
    done
    case "$run" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    case "$step" in ''|*[!a-zA-Z0-9_-]*) return 1 ;; esac
    key="nm-$run-$step"
    statusf="$STATE/$task.status"
    gate_decision_recorded "$statusf" "$key" || return 1
    pane_is_blocking_for_task "$task" || return 1
  done
  return 0
}

# R3 no-change drop: every task's crew-state line is byte-identical to the line
# at its last delivered wake, the pane is actively blocked, and firstmate has not
# steered it since that wake. No recorded baseline, an empty/unreadable line, or
# an unreadable inbox all fail closed to delivery.
echo_batch_no_change_drop() (  # <task> ...
  local task baseline epoch gen stored line current_gen rec m
  shopt -s nullglob
  fm_lock_try_acquire "$STATE/.echo-baseline.lock" || return 1
  trap 'fm_lock_release "$STATE/.echo-baseline.lock"' EXIT
  [ "$#" -gt 0 ] || return 1
  for task in "$@"; do
    [ -n "$task" ] || return 1
    baseline="$STATE/.last-delivered-$task"
    [ -f "$baseline" ] && [ ! -L "$baseline" ] || return 1
    epoch=$(awk -F '\t' 'NR == 1 { print $1 }' "$baseline")
    gen=$(awk -F '\t' 'NR == 1 { print $2 }' "$baseline")
    stored=$(awk -F '\t' 'NR == 1 { sub(/^[^\t]*\t[^\t]*\t/, ""); print }' "$baseline")
    case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$stored" ] || return 1
    # A relaunched incarnation starts a fresh baseline, so an old "unchanged"
    # line from its predecessor is not evidence about this one.
    current_gen=$(fm_meta_get "$STATE/$task.meta" spawn_gen 2>/dev/null || true)
    [ "$current_gen" = "$gen" ] || return 1
    line=$("$FM_CREW_STATE_BIN" "$task" 2>/dev/null) || return 1
    [ -n "$line" ] || return 1
    [ "$line" = "$stored" ] || return 1
    pane_is_blocking_for_task "$task" || return 1
    for rec in "$STATE/$task.inbox"/*.msg "$STATE/$task.inbox/handled"/*.msg; do
      [ -e "$rec" ] || return 1
      m=$(stat_mtime "$rec") || return 1
      case "$m" in ''|*[!0-9]*) return 1 ;; esac
      [ "$m" -lt "$epoch" ] || return 1
    done
  done
  rm -f -- "$ECHO_BATCH_FILE"
)

# Deliver the persisted batch, applying the two drop rules first. <mode> is
# `due` (the window elapsed; one wake is printed) or `immediate` (another wake is
# about to print; only the queue rows are appended). Returns 0 when the batch was
# delivered or intentionally dropped, 1 when it must stay for a retry.
echo_batch_flush() {  # <due|immediate>
  local mode=$1 window tmp epoch file base task reason files='' count=0 rc=0
  local all_turnend=1 seen=''
  local -a tasks=()
  [ -s "$ECHO_BATCH_FILE" ] || return 0
  echo_batch_resolve
  window=$ECHO_BATCH_RESOLVED
  ECHO_BATCH_IN_FLUSH=1
  tmp="$ECHO_BATCH_FILE.tmp.$$"
  if ! awk -F '\t' 'NF >= 2 && $2 != "" && !seen[$2]++ { print $1 "\t" $2 }' "$ECHO_BATCH_FILE" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    ECHO_BATCH_IN_FLUSH=0
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    rm -f "$tmp" "$ECHO_BATCH_FILE"
    ECHO_BATCH_IN_FLUSH=0
    return 0
  fi
  while IFS=$(printf '\t') read -r epoch file; do
    [ -n "$file" ] || continue
    base=${file##*/}
    case "$base" in
      *.turn-ended) task=${base%.turn-ended} ;;
      *.turn-ended.*) task=${base%.turn-ended.*} ;;
      *) all_turnend=0; continue ;;
    esac
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    tasks+=("$task")
  done < "$tmp"
  if [ ! -e "$STATE/.afk" ] && [ "$all_turnend" -eq 1 ] && [ "${#tasks[@]}" -gt 0 ] && [ "$window" -gt 0 ]; then
    if echo_batch_answered_gate_drop "${tasks[@]}"; then
      while IFS=$(printf '\t') read -r epoch file; do
        [ -n "$file" ] || continue
        triage_log "echo-batch drop rule=answered-gate file=$(basename "$file")"
      done < "$tmp"
      rm -f "$tmp" "$ECHO_BATCH_FILE"
      ECHO_BATCH_IN_FLUSH=0
      return 0
    fi
    if echo_batch_no_change_drop "${tasks[@]}"; then
      while IFS=$(printf '\t') read -r epoch file; do
        [ -n "$file" ] || continue
        triage_log "echo-batch drop rule=no-change file=$(basename "$file")"
      done < "$tmp"
      rm -f "$tmp"
      ECHO_BATCH_IN_FLUSH=0
      return 0
    fi
  fi
  while IFS=$(printf '\t') read -r epoch file; do
    [ -n "$file" ] || continue
    files="$files $file"
    count=$((count + 1))
  done < "$tmp"
  reason="signal:$files"
  while IFS=$(printf '\t') read -r epoch file; do
    [ -n "$file" ] || continue
    if ! fm_wake_append signal "${file##*/}" "$reason"; then
      rc=1
      break
    fi
  done < "$tmp"
  if [ "$rc" -eq 0 ]; then
    echo_batch_record_delivered "$(date +%s)" ${tasks[@]+"${tasks[@]}"}
    rm -f "$tmp" "$ECHO_BATCH_FILE"
    if [ "$mode" = due ]; then
      triage_log "echo-batch flush rule=window entries=$count reason=signal"
    else
      triage_log "echo-batch flush rule=immediate-flush entries=$count reason=signal"
    fi
  else
    rm -f "$tmp"
    triage_log "echo-batch flush failed; batch retained for retry"
  fi
  ECHO_BATCH_IN_FLUSH=0
  if [ "$rc" -eq 0 ] && [ "$mode" = due ]; then
    wake "$reason"
  fi
  return "$rc"
}

# The pre-wake hook (FM_WAKE_PRE_OUTPUT_ACTION): record this delivery's task
# baselines and flush a pending batch into the queue, so no deferred row waits
# out its window behind an urgent wake. Recursion is impossible: the batch file
# is cleared before the due flush calls wake.
echo_batch_before_wake() {  # <reason>
  echo_batch_note_delivery "$1"
  [ "${ECHO_BATCH_IN_FLUSH:-0}" -eq 0 ] || return 0
  [ -s "$ECHO_BATCH_FILE" ] || return 0
  echo_batch_flush immediate || true
}

# Consumer-side incarnation gate. Turn-end markers are per generation
# (state/<id>.turn-ended.<spawn_gen>), written by bin/fm-turnend-signal.sh; a
# torn-down or relaunched id can leave stale-gen markers behind. Fire only the
# live incarnation's gen marker (fm-wake-lib.sh's fm_wake_turnend_marker_is_stale,
# comparing the marker's gen against live metadata); for any other-gen marker,
# advance its .seen signature so it is not re-scanned and drop it from this cycle -
# .seen is per-file, so ignoring an old gen never advances the live gen's seen
# state. Status files and the live gen's marker pass through unchanged. Reads the
# pending TSV on its argument and prints the survivors.
filter_stale_turnend_markers() {  # <pending-tsv>
  local pending=$1 sf sig f base rest id gen
  while IFS=$(printf '\t') read -r sf sig f; do
    [ -n "$sf" ] || continue
    case "$f" in
      *.turn-ended)
        base=$(basename "$f")
        id=${base%.turn-ended}
        if fm_wake_turnend_bare_marker_is_stale "$STATE" "$id"; then
          printf '%s' "$sig" > "$sf"
          continue
        fi
        ;;
      *.turn-ended.*)
        base=$(basename "$f")
        id=${base%.turn-ended.*}
        rest=${base#"$id".turn-ended.}
        gen=$rest
        if fm_wake_turnend_marker_is_stale "$STATE" "$id" "$gen"; then
          printf '%s' "$sig" > "$sf"
          continue
        fi
        ;;
    esac
    printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
  done <<EOF
$pending
EOF
}

# Deliver a durably queued process-event result to firstmate. Publication is
# owned by bin/fm-procevent.sh - by the runner at capture time and by reconcile's
# re-announcement - so this decides only whether a queued check record has been
# surfaced yet, then reports it through the same actionable exit every other wake
# uses. Without it a captured result sits on the queue until something else
# happens to wake firstmate, which is exactly the missed delivery this repairs.
# Dedup uses the same .seen-* discipline as scan_signals: the durable record is
# always written before its marker, so nothing is suppressed before it is queued,
# and re-announcement, drain-time deduplication, and the handled acknowledgement
# keep their existing owners untouched.
procevent_surfaced_marker() {  # <queue-key>
  printf '%s/.seen-procevent-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C od -An -tx1 | tr -d ' \n')"
}

procevent_surface_after_output() {
  local output_status=$1 key marker tmp status=0
  if [ "$output_status" -eq 0 ]; then
    for key in $PROCEVENT_SURFACED; do
      marker=$(procevent_surfaced_marker "$key")
      tmp=$(umask 077; mktemp "$STATE/.seen-procevent.XXXXXX") || { status=1; continue; }
      if ! mv -f -- "$tmp" "$marker"; then
        rm -f -- "$tmp"
        status=1
      fi
    done
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

procevent_surface_queued() {
  local key reason
  PROCEVENT_SURFACED=
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  while :; do
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
    PROCEVENT_SURFACED=
    while IFS= read -r key; do
      case "$key" in procevent:*) ;; *) continue ;; esac
      [ -e "$(procevent_surfaced_marker "$key")" ] && continue
      PROCEVENT_SURFACED="$PROCEVENT_SURFACED $key"
    done < <(fm_wake_queued_keys_locked check)
    if [ -z "$PROCEVENT_SURFACED" ]; then
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 0
    fi
    [ -s "$ECHO_BATCH_FILE" ] || break
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    echo_batch_flush immediate || return 1
  done
  reason="check: process-event result captured:$PROCEVENT_SURFACED"
  # shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
  FM_WAKE_POST_OUTPUT_ACTION=procevent_surface_after_output
  wake "$reason"
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop is owned by
# fm-push-transition-lib.sh because push and poll paths must write one format.
# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f task last
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
  done < <(scan_captain_relevant_statuses "$STATE")
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# event_wait_or_sleep: the terminal wait of each supervision cycle. For a home
# with push-capable windows (herdr), it replaces the blind `sleep POLL` with a
# bounded wait on the backend's native transition stream, so a crew going
# `blocked` wakes the supervisor sub-second instead of after the stale-pane
# wedge timer. For every other home - no push-capable window, backend not
# capable, or the event path proven unreliable this process - it sleeps POLL,
# byte-for-byte today's behavior. The poll loop above still runs every cycle, so
# this only ever SHORTENS latency; it can never drop an escalation (the poll
# loop is the permanent fail-closed backstop). This preserves the single live
# supervision cycle: the reader is a short-lived subprocess of THIS watcher, not
# a second watcher, so every guard/beacon/arm/turn-end mechanism is unchanged.
event_wait_or_sleep() {
  local w b session first_backend="" first_session="" rec rc
  local windows=()
  while IFS= read -r w; do
    b=$(window_backend "$w")
    fm_backend_has_push "$b" || continue
    # Secondmate endpoints are supervised via status writes, not pane/agent
    # state (an idle or blocked secondmate agent pane is healthy by design), so
    # they are excluded from the fast escalation exactly as the stale loop skips
    # them.
    [ "$(window_kind "$w")" = secondmate ] && continue
    session=${w%%:*}
    if [ -z "$first_backend" ]; then first_backend=$b; first_session=$session; fi
    # One socket connection covers one backend+session; a home normally has a
    # single herdr session. A window in a different backend/session stays on the
    # poll path this cycle.
    if [ "$b" != "$first_backend" ] || [ "$session" != "$first_session" ]; then
      continue
    fi
    windows+=("$w")
  done < <(recorded_windows)

  if [ "${#windows[@]}" -eq 0 ]; then
    sleep "$POLL"
    return
  fi

  # Memoized capability probe (fm_backend_events_capable runs a heavy schema
  # read); re-probed only when the backend/session key changes.
  if [ "$_event_cap_key" != "$first_backend:$first_session" ]; then
    _event_cap_key="$first_backend:$first_session"
    if fm_backend_events_capable "$first_backend" "$first_session"; then
      _event_cap_ok=1
    else
      _event_cap_ok=0
    fi
    _event_cap_fails=0
  fi
  if [ "$_event_cap_ok" != 1 ]; then
    sleep "$POLL"
    return
  fi

  rec=$(FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 fm_backend_wait_transition "$first_backend" "$first_session" "$POLL" "$STATE" "${windows[@]}")
  rc=$?
  case "$rc" in
    0)
      _event_cap_fails=0
      handle_push_transition "$first_backend" "$first_session" "$rec"
      ;;
    2)
      # Event path unusable this cycle (connect/subscribe failure). Sleep the
      # budget and count toward the runtime-disable threshold; past it, drop to
      # pure polling for the rest of this watcher process.
      _event_cap_fails=$((_event_cap_fails + 1))
      [ "$_event_cap_fails" -ge "$EVENT_CAP_FAIL_MAX" ] && _event_cap_ok=0
      sleep "$POLL"
      ;;
    *)
      # 1: a clean full-budget wait with no actionable edge - the reader already
      # blocked ~POLL, so just continue; the next cycle re-scans.
      _event_cap_fails=0
      ;;
  esac
}

# Remind firstmate of overdue worker-owned keyed decisions independently of the
# supervision signal fold. The timed incremental fold preserves opened-at ages;
# this ledger bounds repeated wakes across watcher restarts.
open_decision_reminder_tick() {
  local lock="$STATE/.status-presentation-lock" rc=0
  OPEN_DECISION_REMINDER=
  [ -e "$CONFIG/open-decision-reminders" ] || return 0
  fm_lock_acquire_wait "$lock" || return 1
  _open_decision_reminder_tick_locked "$@" || rc=$?
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

_open_decision_reminder_tick_locked() {
  local now=${1:-$(date +%s)} threshold=${FM_OPEN_DECISION_OVERDUE_SECS:-1800}
  local cap=${FM_OPEN_DECISION_BACKOFF_MAX_SECS:-14400} value f task kind open key verb opened note
  local ledger old='' rows='' old_task old_key old_opened old_last old_delay last delay
  local due_task='' due_key='' due_opened='' due_delay='' tmp reason exclude
  for value in "$threshold" "$cap"; do
    case "$value" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#value}" -le 9 ] || return 1
  done
  [ "$cap" -ge "$threshold" ] || return 1
  ledger="$STATE/.open-decision-reminders"
  exclude=''
  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    exclude=$(fm_parent_channel_destination "$FM_HOME" "$STATE") || return 1
  fi
  if [ -e "$ledger" ] || [ -L "$ledger" ]; then
    [ -f "$ledger" ] && [ -r "$ledger" ] && [ ! -L "$ledger" ] || return 1
    old=$(cat "$ledger") || return 1
  fi
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    task=${f##*/}; task=${task%.status}
    [ "$f" != "$exclude" ] || continue
    kind=$(_fm_status_kind "$f")
    case "$kind" in ship|scout|secondmate) ;; *) continue ;; esac
    open=$(status_open_decisions_incremental "$f" '' timed "$now") || return 1
    [ -n "$open" ] || continue
    while IFS=$'\t' read -r key verb opened note; do
      _fm_decision_key_worker_owned "$key" || continue
      case "$opened" in ''|*[!0-9]*) continue ;; esac
      last=0; delay=$threshold
      while IFS=$'\t' read -r old_task old_key old_opened old_last old_delay; do
        [ "$old_task" = "$task" ] && [ "$old_key" = "$key" ] \
          && [ "$old_opened" = "$opened" ] || continue
        case "$old_last:$old_delay" in *[!0-9:]*) continue ;; esac
        [ -n "$old_last" ] && [ "${#old_last}" -le 12 ] \
          && [ -n "$old_delay" ] && [ "${#old_delay}" -le 9 ] || continue
        last=$((10#$old_last)); delay=$((10#$old_delay))
        [ "$delay" -ge "$threshold" ] || delay=$threshold
        [ "$delay" -le "$cap" ] || delay=$cap
        break
      done <<EOF
$old
EOF
      rows="$rows$task"$'\t'"$key"$'\t'"$opened"$'\t'"$last"$'\t'"$delay"$'\n'
      [ "$now" -ge "$opened" ] && [ "$((now - opened))" -ge "$threshold" ] || continue
      [ "$last" -eq 0 ] || [ "$((now - last))" -ge "$delay" ] || continue
      status_is_paused_or_captain_held "$(last_status_line "$f")" && continue
      task_captain_call_open "$task" && continue
      if [ -z "$due_opened" ] || [ "$opened" -lt "$due_opened" ]; then
        due_task=$task; due_key=$key; due_opened=$opened; due_delay=$delay
        if [ "$last" -ne 0 ]; then
          due_delay=$((delay * 2))
          [ "$due_delay" -le "$cap" ] || due_delay=$cap
        fi
      fi
    done <<EOF
$open
EOF
  done
  if [ -n "$due_task" ]; then
    reason="check: open decision overdue: $due_task key=$due_key age=$((now - due_opened))s"
    fm_wake_append check "open-decision:$due_task:$due_key" "$reason" || return 1
    old=''
    while IFS=$'\t' read -r old_task old_key old_opened old_last old_delay; do
      [ -n "$old_task" ] || continue
      [ "$old_task" = "$due_task" ] && [ "$old_key" = "$due_key" ] \
        && [ "$old_opened" = "$due_opened" ] && continue
      old="$old$old_task"$'\t'"$old_key"$'\t'"$old_opened"$'\t'"$old_last"$'\t'"$old_delay"$'\n'
    done <<EOF
$rows
EOF
    rows="$old$due_task"$'\t'"$due_key"$'\t'"$due_opened"$'\t'"$now"$'\t'"$due_delay"$'\n'
    OPEN_DECISION_REMINDER=$reason
  fi
  tmp=$(mktemp "$STATE/.open-decision-reminders.XXXXXX") || return 1
  if ! printf '%s' "$rows" > "$tmp" || ! mv -f "$tmp" "$ledger"; then
    rm -f -- "$tmp"
    return 1
  fi
}
# --- Main entry: the runtime below runs only when this file is executed as a
# script. When sourced (unit tests loading the functions above), return here
# before acquiring the singleton lock or entering the blocking loop.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# A process inside an fm-spawn task worker's launch environment (FM_TASK_ID)
# is never a firstmate home owner: refuse before the singleton lock so a
# worker cannot run supervision against a home it does not own.
if fm_env_is_task_worker; then
  echo "watcher: FAILED - refusing to run the watcher from an fm-spawn task worker environment (FM_TASK_ID=$FM_TASK_ID)" >&2
  exit 1
fi

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
WATCHER_RECOVERY_PENDING=0
if [ -n "${FM_LOCK_RECOVERED_PID:-}" ]; then
  WATCHER_RECOVERY_PENDING=1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" != 1 ]; then
  if ! fm_recovery_marker_reopen_announced "$WATCHER_DOWNTIME_MARKER"; then
    echo "watcher: recovery state could not be reopened safely; retaining stale lock evidence" >&2
    exit 1
  fi
fi
if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
  echo "watcher: recovery state could not be consumed safely; retaining stale lock evidence" >&2
  exit 1
fi
if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
  WATCHER_RECOVERY_PENDING=0
elif [ "$FM_RECOVERY_MARKER_ACTION" = recover ]; then
  WATCHER_RECOVERY_PENDING=1
fi
watcher_cleanup() {
  local cleanup_status=0 owns_lock=0 transition=release-lock
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" = "${WATCHER_PID:-}" ]; then
    owns_lock=1
    if [ "${WATCHER_RECOVERY_PENDING:-0}" -eq 1 ] \
      && [ "${FM_WATCH_DELIVERED_REASON:-}" = "check: rearm-resurface" ]; then
      transition=release-lock-existing
    fi
  fi
  fm_active_check_stop || cleanup_status=1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  if [ "$owns_lock" -eq 1 ] \
    && ! fm_recovery_transition "$WATCHER_DOWNTIME_MARKER" "$transition" "$WATCH_LOCK" downtime; then
    echo "watcher: recovery state could not be persisted; retaining stale lock evidence" >&2
    cleanup_status=1
  fi
  return "$cleanup_status"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
# This watcher's own pid, as recorded in the lock by fm_lock_claim (which writes
# ${BASHPID:-$$} from this same main shell). Read directly, never via a command
# substitution, so it matches the stored holder pid for the self-eviction check.
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
# shellcheck disable=SC2034 # Consumed by wake() in the separately linted transition owner.
FM_WATCH_DELIVERY_PID=$WATCHER_PID
FM_WATCH_DELIVERY_IDENTITY=$(fm_pid_identity "$WATCHER_PID" 2>/dev/null || true)
printf '%s\n' "$FM_WATCH_DELIVERY_IDENTITY" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true
# Echo batching's delivery hook lives in the shared transition owner's wake():
# it records task baselines and flushes a pending batch into the queue before any
# other wake is printed, so an urgent wake never waits behind the window.
# shellcheck disable=SC2034 # Read by wake() in the separately linted transition owner.
FM_WAKE_PRE_OUTPUT_ACTION=echo_batch_before_wake

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal.
# Finish only identity-bound retirement receipts before any check can run.
if ! fm_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$FM_PR_POLL_RETIREMENT_REJECTED"
  fm_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

idle_sleep_tick() {
  local reason
  [ -f "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/idle-sleep" ] || return 0
  reason=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-idle-sleep.sh" tick 2>/dev/null | head -1) || true
  [ -n "$reason" ] || return 0
  triage_log "$reason"
  wake "$reason"
}

resurface_after_downtime() {
  local reason
  # Handling successors already have a predecessor-delivered wake on the way.
  # Re-announcing from this cycle is what turned a lost handshake into an
  # unbounded recovery loop; stay in the poll loop and supervise instead.
  if [ "${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ]; then
    return 0
  fi
  if [ "$WATCHER_RECOVERY_PENDING" -ne 1 ]; then
    if ! fm_recovery_marker_arm_check "$WATCHER_DOWNTIME_MARKER"; then
      echo "watcher: recovery state could not be consumed safely" >&2
      exit 1
    fi
    [ "$FM_RECOVERY_MARKER_ACTION" = recover ] || return 0
  fi
  if [ "${FM_RECOVERY_RESURFACE_BOUND:-0}" = 1 ]; then
    # The announcement's only consumer has missed a whole unacknowledged streak
    # (fm-wake-lib.sh's FM_WATCH_RESURFACE_* bound): exiting here again would
    # suspend pane supervision forever. Surface the resurface once through the
    # durable queue with the guard-level diagnostic, keep the announced marker
    # ackable, and resume the pane loop. Clearing WATCHER_RECOVERY_PENDING lets
    # the next cycle arm-check again, so an acknowledgement or a fresh episode
    # is still observed from inside this same watcher.
    WATCHER_RECOVERY_PENDING=0
    if [ "${FM_RECOVERY_RESURFACE_SURFACED:-0}" != 1 ]; then
      reason="check: rearm-resurface (daemon scan stale + watcher in resurface loop: ${FM_RECOVERY_RESURFACE_COUNT} unacknowledged downtime announcements; resumed pane-loop supervision)"
      fm_wake_append check rearm-resurface "$reason" || exit 1
      _fm_recovery_resurface_mark_surfaced "$WATCHER_DOWNTIME_MARKER" || exit 1
      triage_log "$reason"
      watch_delivery_publish "$reason" || true
      FM_WATCH_DELIVERED_REASON=$reason
    fi
    return 0
  fi
  wake "check: rearm-resurface"
}


while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  # A persisted echo batch whose window elapsed - including one inherited from a
  # watcher that restarted mid-window - is delivered before any other cycle work,
  # so it can never be held past its window by a quiet fleet or a restart.
  echo_batch_flush_due || true

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true
  open_decision_reminder_tick '' || {
    echo 'watcher: open-decision reminder check failed' >&2
    exit 1
  }
  [ -z "$OPEN_DECISION_REMINDER" ] || wake "$OPEN_DECISION_REMINDER"

  # A live secondmate endpoint does not prove that its own wake loop is alive.
  # Observe the foreign queue before the rest of this cycle so an aged row wakes
  # the parent without consuming or rewriting the receiving home's record.
  secondmate_wake_stall_tick || {
    echo "watcher: secondmate wake-loop observation failed" >&2
    exit 1
  }

  # Undelivered main-wake alarm: strictly read-only and best-effort, so a
  # marker or channel failure can never interrupt the watch loop.
  main_wake_undelivered_tick || true

  # No-Mistakes PR-guard backstop: a no-mistakes ship whose worker opened its
  # own PR has no run to prove, so surface it once while the branch has none.
  nm_pr_unguarded_tick || {
    echo "watcher: no-mistakes PR guard scan failed" >&2
    exit 1
  }

  # Local Communication Officer: converge the inbox poll shim with the opt-in,
  # then ring once for any bridge row the gateway recorded since the last ring.
  ext_bridge_converge_tick || true
  ext_doorbell_tick
  # An unanswered request whose close was coalesced away earns a bounded
  # reminder rather than waiting for some unrelated wake.
  ext_overdue_tick

  # Process-to-event liveness repair. Remote-reply routes converge first:
  # ensure-armed registers any live route that lost its source (without SSH),
  # so a registration it creates is started by the reconcile right below in
  # this same cycle. This never discovers a result by polling: each registered
  # source has its own child blocking on that source, and this only
  # republishes results already captured durably and restarts a source whose
  # owner is gone. It is a no-op with nothing registered.
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent-remote-reply.sh" ensure-armed >/dev/null 2>&1 || true
  if [ -d "$STATE/procevent" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
  fi
  # Then deliver any queued-but-unsurfaced result, including one a runner
  # published while this watcher was between cycles.
  procevent_surface_queued

  # Opt-in idle auto-sleep (config/idle-sleep). The tick reads only local
  # records and detaches any guarded sleep attempt, so it never blocks this
  # cycle; it prints reasons for previously unreported refusals or malformed lines.
  idle_sleep_tick

  # A process-event result carries richer adapter-owned wake context than the
  # generic recovery reason, so give that owner first refusal.
  resurface_after_downtime

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      is_pr_poll=0
      # A check that appends its own durable wake records before it consumes
      # the work they describe; this loop then nudges without appending again.
      check_owns_wake=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      elif [ "$(basename "$c")" = ext-watch.check.sh ]; then
        if fm_ext_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-ext-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-ext-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-ext-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
          check_owns_wake=1
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          is_pr_poll=1
          provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
          url=$FM_PR_POLL_SNAPSHOT_URL
          host=$FM_PR_POLL_SNAPSHOT_HOST
          path=$FM_PR_POLL_SNAPSHOT_PATH
          number=$FM_PR_POLL_SNAPSHOT_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif [ -d "$STATE/.$id.pr-publication.lock" ] \
          && [ ! -L "$STATE/.$id.pr-publication.lock" ] \
          && publication_lock_age=$(fm_path_age "$STATE/.$id.pr-publication.lock") \
          && [ "$publication_lock_age" -ge 0 ] \
          && [ "$publication_lock_age" -lt "$PR_PUBLICATION_LOCK_STALE_SECS" ] \
          && fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" defer-metadata; then
          # fm-pr-check publishes the authenticated poll tuple before its
          # atomic metadata replacement while holding its publication lock.
          # Retry on the next cycle instead of surfacing that brief, valid
          # pre-metadata state as an unauthenticated check.
          continue
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ "$is_pr_poll" -eq 1 ] && [ "$out" = "review $url clear" ]; then
        fm_pr_poll_review_notified_remove "$STATE" "$id" || exit 1
        out=
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          # One role-routed durable outcome for a merge this home detected:
          # bin/fm-merge-outcome-lib.sh publishes the captain-facing row (main
          # home) or the upward parent reply plus a local row (secondmate
          # home) before the poll retires, and absorbs a repeat detection of
          # an identity already recorded. A record that cannot be written
          # keeps the poll armed and exits loudly rather than retiring the
          # only evidence of the merge.
          merge_outcome_rc=0
          fm_merge_outcome_report "$FM_HOME" "$STATE" "$id" "$url" poll \
            || merge_outcome_rc=$?
          if [ "$merge_outcome_rc" -ne 0 ]; then
            triage_log "merge outcome for $id could not be recorded (rc=$merge_outcome_rc)"
            exit 1
          fi
          if fm_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" "$out"; then
            fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
              || triage_log "merged PR poll retirement remains recoverable for $id"
          else
            triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
          fi
          touch "$STATE/.last-check"
          if [ "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true ]; then
            triage_log "absorbed duplicate merged PR poll result for $id"
            continue
          fi
          wake "$reason"
        fi
        if [ "$is_pr_poll" -eq 1 ]; then
          # Deduplicate review wakes under bin/fm-pr-lib.sh's marker contract;
          # bin/fm-pr-poll.sh owns the review-result protocol.
          case "$out" in
            review\ *)
              if fm_pr_poll_review_notified "$STATE" "$id" "$out"; then
                touch "$STATE/.last-check"
                continue
              fi
              ;;
          esac
        fi
        if [ "$check_owns_wake" -eq 1 ]; then
          # fm-ext-poll.sh already made one record durable per claimed request,
          # and released the claim again for any record it could not append.
          # Appending here as well would double every request, and the rows it
          # appended are rung by this wake, so the doorbell must not ring them.
          touch "$STATE/.last-check"
          if ! { ext_rows=$(ext_doorbell_rows) && ext_doorbell_mark "$ext_rows"; }; then
            triage_log "ext doorbell: could not record the poll's rows as rung"
          fi
          wake "$reason"
          continue
        fi
        fm_wake_append check "$c" "$reason" || exit 1
        if [ "$is_pr_poll" -eq 1 ]; then
          case "$out" in
            review\ *)
              fm_pr_poll_review_mark "$STATE" "$id" "$out" \
                || triage_log "unanswered-review wake for $id was not marked delivered"
              ;;
          esac
        fi
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    # Gate turn-end markers to the live incarnation before they can wake firstmate:
    # a stale (torn-down or relaunched) marker is discarded here, with its .seen
    # advanced so it never re-fires. If every pending signal was a stale marker,
    # there is nothing left to surface.
    pending=$(filter_stale_turnend_markers "$pending")
  fi
  if [ -n "$pending" ]; then
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file gained a captain-relevant event since its last
    #     classified byte, even when a later routine line is now the latest;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) with no
    #     positive evidence the crew is still executing - the crew stopped its turn
    #     with no actively-running pipeline and no busy pane, so it may be done
    #     (even via an interactive menu that wrote no done: status), waiting on a
    #     decision, or wedged. Absorbing such a turn-end is exactly the
    #     swallowed-finish this change guards against.
    # Positive evidence is either an authoritative provably-working verdict or, in a
    # home that opts in with config/turnend-churn-absorb and for a BARE turn-end
    # alone, a pane that rendered something since the previous poll
    # (signal_turnend_panes_churned) - the only proof available to a harness whose
    # busy state has no verified semantic source, bounded so it cannot defer that
    # task's turn-ends forever. Absorb stays evidence-driven: with neither proof the
    # wake surfaces exactly as before.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew is still executing) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. Both evidence
    # checks are costly (a bounded no-mistakes call, then a pane capture), so the ||
    # ordering evaluates them ONLY for a non-afk signal with no captain-relevant
    # status span, and the capture only once the authoritative verdict comes up short.
    # shellcheck disable=SC2086 # files is the deliberate space-separated status-path list.
    signal_files_actionable $files
    signal_actionable=$?
    # A decision-owned file's queued row payload is marked "needs-decision:"
    # instead of the ordinary reason below (other files in the same batch keep
    # the ordinary payload). The wake reason line itself, and every
    # harness-arm consumer that pattern-matches it, stays byte-identical -
    # only the per-row payload changes, which is what the supervision-branch
    # dispatcher reads to keep a decision-owned row off the branch
    # (fm-branch-dispatch.ts, fm-primary-omp.ts). Every other harness and
    # script keeps seeing the exact same "signal:$files" wake it always has.
    # An action-worthy signal still may be an echo: when batching is enabled and
    # this batch carries no immediate class (check/stale never reach here; a
    # needs-decision/blocked/done/failed span or a decision-owned row forces
    # delivery), it joins the persisted window instead of waking the supervisor
    # now. Everything about the deferral - markers, span endpoints, surfaced
    # line, audit - is the delivery path's own bookkeeping, so the event can
    # neither re-fire nor be lost, and a failed deferral falls through to the
    # immediate delivery below.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || [ "$signal_actionable" -eq 0 ] \
      || { ! signal_crew_provably_working $files && ! signal_turnend_panes_churned $files; }; then
      signal_deferred=0
      if ! afk_present && echo_batch_enabled && ! signal_batch_must_deliver $files; then
        echo_batch_defer "$pending" && signal_deferred=1
      fi
      [ "$signal_deferred" -eq 1 ] || deliver_pending_signals "$pending" "$reason"
    else
      signal_commit_error=0
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      # Even an absorbed routine wake advances the classified endpoint.  This
      # prevents a routine append from being replayed while preserving any
      # actionable event already reported in the same captured span.
      while IFS=$(printf '\t') read -r f surface_end surface_ident; do
        [ -n "$f" ] || continue
        fm_wake_status_seen_commit "$STATE" "$f" "$surface_end" "$surface_ident" || signal_commit_error=1
      done <<EOF
$FM_SIGNAL_SURFACE_ENDPOINTS
EOF
      if [ "${signal_commit_error:-0}" -ne 0 ]; then
        while IFS=$(printf '\t') read -r sf sig f; do
          [ -n "$sf" ] || continue
          fm_wake_append signal "$(basename "$f")" "$reason" || exit 1
        done <<EOF
$pending
EOF
        wake "$reason"
      fi
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  while IFS= read -r w; do
    kind=$(window_kind "$w")
    task=$(window_to_task "$w" "$STATE")
    [ -z "$task" ] || inbox_steer_check "$w" "$task"
    key=$(window_key "$w")
    last=$(last_status_line "$STATE/$task.status")
    meta=
    remote_host=
    if [ "$kind" = secondmate ]; then
      meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
      remote_host=$(grep '^remote_host=' "$meta" | cut -d= -f2- || true)
      if [ -n "$remote_host" ] && fm_compute_is_dormant "$DATA" "$task"; then
        handle_compute_dormant_stale "$w" "$task"
        continue
      fi
    fi
    if ! status_is_paused_or_captain_held "$last" && [ -e "$STATE/.paused-$key" ]; then
      clear_pause_tracking "$key"
    fi
    secondmate_stale=0
    if [ "$kind" = secondmate ]; then
      if ! status_is_paused_or_captain_held "$last"; then
        secondmate_supervision_is_alive "$w" "$meta" "$remote_host"
        probe_rc=$?
        if [ "$probe_rc" -eq 0 ]; then
          clear_pause_tracking "$key"
          continue
        fi
        icf="$STATE/.remote-inconclusive-$key"
        if [ "$probe_rc" -eq 2 ]; then
          # Inconclusive evidence (deadline, no answer, unusable output) is not a
          # stale verdict: count it per route and absorb until the documented
          # consecutive-probe bound, so one slow SSH round trip on a live host
          # never wakes firstmate.
          icn=$(( $(cat "$icf" 2>/dev/null || echo 0) + 1 ))
          [ "$icn" -le "$REMOTE_INCONCLUSIVE_MAX" ] || icn=$REMOTE_INCONCLUSIVE_MAX
          printf '%s\n' "$icn" > "$icf"
          if [ "$icn" -lt "$REMOTE_INCONCLUSIVE_MAX" ]; then
            triage_log "absorbed inconclusive remote beacon probe ($icn/$REMOTE_INCONCLUSIVE_MAX): $w"
            continue
          fi
          triage_log "inconclusive remote beacon probes reached the bound ($icn/$REMOTE_INCONCLUSIVE_MAX): $w"
        else
          # A conclusive answer (fresh or stale) resets the inconclusive count.
          rm -f "$icf"
        fi
      fi
      secondmate_stale=1
    fi
    if [ "$secondmate_stale" -eq 1 ]; then
      if [ -n "$remote_host" ]; then
        tail40="remote secondmate watcher beacon missing or stale: $w"
      else
        tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) \
          || tail40="secondmate pane capture unavailable: $w"
      fi
      h=$(printf 'secondmate watcher beacon missing or stale: %s' "$w" | hash_pane)
    else
      tail40=$(fm_backend_capture "$(window_backend "$w")" "$w" 40 "$(window_label "$w")" 2>/dev/null) || continue
      h=$(printf '%s' "$tail40" | hash_pane)
    fi
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    ewf="$STATE/.wedge-escalations-$key"
    pf="$STATE/.paused-$key"   # flag: this key's stale is using the bounded pause cadence
    prev=$(cat "$hf" 2>/dev/null || true)
    # Busy match: a backend's native semantic state when available (herdr), else
    # the last 6 non-blank lines only (the TUI footer area, where every verified
    # harness renders its busy indicator) so busy-looking strings in displayed
    # content cannot suppress stale detection. Read once per window per poll and
    # reused below so a busy verdict is consistent within one cycle.
    if [ "$secondmate_stale" -eq 0 ] && window_is_busy "$w" "$tail40"; then busy_now=0; else busy_now=1; fi
    # Completion-boundary probe (idle-with-open-work): runs for every not-busy
    # pane BEFORE the hash comparison so a ticking idle pane - whose hash never
    # repeats and so never enters the stale path - is still held to the bounded
    # reporting contract while its board row is in flight.
    if [ "$secondmate_stale" -eq 0 ] && [ "$busy_now" -ne 0 ] && [ -n "$task" ]; then
      idle_open_work_tick "$w" "$task"
    fi
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && [ "$busy_now" -ne 0 ]; then
        # The pane is idle/stale at hash $h. Triage decides whether this wakes
        # firstmate. Detection itself is unchanged from above.
        if afk_present; then
          # Daemon owns triage: one-shot per distinct stale hash, as before.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          # The log's last line is captain-relevant - but that alone is not
          # proof the crew is actually done: a crew's own status log gets no
          # new entry once firstmate hands it to a no-mistakes validation
          # (AGENTS.md's sparse status-reporting contract), so the log can
          # keep showing a "done:"/needs-decision/blocked leftover from
          # BEFORE that validation started for the run's entire (possibly
          # many-minutes) duration, while stale_is_terminal - which has no
          # run-step awareness - keeps reporting it as still-current on every
          # poll. Root cause of the 2026-07 herdr false-surface incidents: a
          # validating crew was surfaced as stale every few minutes despite an
          # actively-running pipeline, purely because of this stale leftover
          # line. On a NEW hash, give an active run/busy pane (the same
          # authoritative source fm-crew-state.sh itself already prioritizes
          # over the log) a chance to override before trusting the log.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              clear_wedge_deferral_tracking "$key"
              triage_log "absorbed stale (provably working, overriding a stale captain-relevant status): $w"
            elif ! afk_present && crew_is_run_step_done "$(window_to_task "$w" "$STATE")"; then
              printf '%s' "$h" > "$sf"
              rm -f "$ssf" "$ewf"
              clear_wedge_deferral_tracking "$key"
              triage_log "absorbed stale (run-step done, completion already reported): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              clear_wedge_deferral_tracking "$key"
              mark_surfaced "$STATE/$(window_to_task "$w" "$STATE").status"
              wake "stale: $w"
            fi
          elif [ -e "$ssf" ]; then
            # This exact hash was already overridden as provably-working (a
            # wedge timer is running for it) - keep treating it that way
            # without re-reading the crew state every poll, and without
            # letting the still-captain-relevant log line re-surface it.
            wedge_timer_check "$w" "$ssf" "stale (overridden terminal status)" "$ewf" "$task"
          fi
          # else: already surfaced as genuinely terminal on a prior poll of
          # this same hash - nothing left to do (matches the original,
          # unmodified terminal-status behavior).
        else
          # Non-terminal stale: a crew gone quiet without a captain-relevant status.
          # Decided once per distinct stale hash (the costly state reads run only
          # on first sight, never every poll) via pause_state_class, which returns:
          #   - working: an actively-running pipeline legitimately sits on a static
          #     pane (e.g. waiting on CI), so absorb and start the wedge timer so a
          #     genuinely frozen run still escalates past STALE_ESCALATE_SECS;
          #   - paused: the crew declared an external wait, or a declared pause or
          #     captain hold is paired with a confidently dead agent, so absorb on
          #     the long PAUSE_RESURFACE_SECS cadence instead of wedge-escalating;
          #   - none: no running pipeline, no exact busy verdict, no declared pause.
          #     Surface immediately so firstmate inspects the inconclusive state
          #     (it may be done via an interactive menu that wrote no done: status,
          #     waiting on a decision, or wedged) instead of leaving the finish to
          #     wait out the timer.
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            task=$(window_to_task "$w" "$STATE")
            case "$(pause_state_class "$w" "$task")" in
              working)
                clear_pause_tracking "$key"
                printf '%s' "$h" > "$sf"
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale (provably working): $w"
                ;;
              paused)
                handle_paused_stale "$w" "$task" "$h"
                ;;
              *)
                surface_nonterminal_stale "$w" "$h"
                ;;
            esac
          else
            task=$(window_to_task "$w" "$STATE")
            if [ -e "$pf" ] || status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")"; then
              case "$(pause_state_class "$w" "$task")" in
                paused)  handle_paused_stale "$w" "$task" "$h" ;;
                working) clear_pause_state "$key"
                         printf '%s' "$h" > "$sf"
                         wedge_timer_check "$w" "$ssf" "non-terminal stale (provably working after a declared pause)" "$ewf" "$task"
                         triage_log "absorbed non-terminal stale (provably working): $w" ;;
                *)       handle_paused_stale "$w" "$task" "$h" ;;
              esac
            else
              wedge_timer_check "$w" "$ssf" "non-terminal stale" "$ewf" "$task"
            fi
          fi
        fi
      else
        # Pane busy or not yet stably stale: reset pending escalation bookkeeping,
        # unless a genuinely busy pane has gone too long with no completed turn -
        # then route it through busy_turn_bound_check, which hands the crossed
        # bound to the same wedge timer unless the crew declared the wait itself.
        paused_bound=1
        if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
          busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" && paused_bound=0
        else
          rm -f "$ssf" "$ewf"
          clear_wedge_deferral_tracking "$key"
        fi
        # A busy pane normally means real work resumed, so stale pause bookkeeping
        # is cleared - but not in the same poll the declared-pause cadence just
        # recorded it, or the re-surface throttle it depends on would be erased.
        if [ "$paused_bound" -ne 0 ] && [ -e "$pf" ] && { [ "$n" -ge 2 ] || ! status_is_paused_or_captain_held "$(last_status_line "$STATE/$(window_to_task "$w" "$STATE").status")"; }; then
          clear_pause_tracking "$key"
        fi
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      paused_bound=1
      if [ "$busy_now" -eq 0 ] && busy_turn_over_age "$task"; then
        busy_turn_bound_check "$w" "$task" "$h" "$ssf" "$ewf" && paused_bound=0
      else
        rm -f "$ssf" "$ewf"
        clear_wedge_deferral_tracking "$key"
      fi
      task=$(window_to_task "$w" "$STATE")
      if ! afk_present && status_is_paused_or_captain_held "$(last_status_line "$STATE/$task.status")" && [ "$busy_now" -ne 0 ]; then
        case "$(pause_state_class "$w" "$task")" in
          paused) handle_paused_stale "$w" "$task" "$h" ;;
          # Inconclusive, but the declared wait itself still stands, so only the
          # per-hash bookkeeping resets. The re-surface throttle bounds the
          # DECLARATION, not the pane hash: an idle parked pane whose display
          # ticks (a clock, a token counter) changes hash without changing what
          # is being waited on, and clearing the throttle here would hand that
          # same wait a fresh window on every tick - the first sight of each new
          # hash reaches surface_nonterminal_stale below, so the whole declared
          # wait would re-alarm far inside PAUSE_RESURFACE_SECS.
          none)   clear_stale_hash_tracking "$key" ;;
          *)      clear_pause_tracking "$key" ;;
        esac
      elif [ "$paused_bound" -ne 0 ] && [ -e "$pf" ]; then
        # Same rule as the stable-hash branch: never clear pause bookkeeping the
        # declared-pause cadence recorded on this very poll.
        clear_pause_tracking "$key"
      fi
    fi
  done < <(recorded_windows)

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      fm_wake_append heartbeat heartbeat heartbeat || exit 1
      touch "$STATE/.last-heartbeat"
      mark_all_captain_relevant_surfaced
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  # Terminal wait: a bounded native-event wait for push-capable homes (herdr),
  # else the blind poll sleep. See event_wait_or_sleep.
  event_wait_or_sleep
done
