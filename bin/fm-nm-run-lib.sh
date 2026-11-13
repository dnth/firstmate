#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (current-state reporting and the done-time
# ask-user decision audit), fm-teardown.sh (pre-teardown run abort, see its
# "Fix 1" header comment), and fm-pr-check.sh (PR-ready run identity and the
# decision-evidence audit). Teardown uses only strict branch-and-head identity;
# crew-state additionally permits the active pipeline-owned exemption defined
# below. Getting this wrong in either direction is unsafe: a false negative
# hides a genuinely parked run, and a false positive lets teardown act on a run
# it does not own. No helper here reconstructs what the pipeline validated
# from the worker's object store: run identity is the branch, PR URL, full
# head SHA, status, and outcome that `axi status --run` reports, and each
# ask-user decision event with its answering origin is what
# `axi rounds --json` reports.
#
# Bounded command in dir $1, timeout $2 seconds. The bounded form preserves
# stdout, stderr, and exit status; the checked form discards stderr, while
# fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_cmd_bounded() {  # <dir> <timeout_secs> <cmd...>
  local dir=$1 timeout_secs=$2 have_timeout=none
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" "$@" ) ;;
    *)        return 1 ;;
  esac
}

fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 nm_bin=${FM_NO_MISTAKES_BIN:-no-mistakes}
  shift 2
  fm_nm_cmd_bounded "$dir" "$timeout_secs" "$nm_bin" "$@"
}

fm_nm_run_checked() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_bounded "$@" 2>/dev/null
}

fm_nm_run() {  # <dir> <timeout_secs> <args...>
  fm_nm_run_checked "$@" || true
}

fm_nm_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

fm_nm_strip_quotes() {
  local s
  s=$(fm_nm_trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  fm_nm_trim "$s"
}

# Scalar value of a TOON key in captured `axi status` output $1.
fm_nm_field() {  # <toon-output> <key>
  local value
  value=$(printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1)
  fm_nm_strip_quotes "$value"
}

# 0 if run head $2 matches worktree $1's code identity, per the same rule
# everywhere this attribution is needed:
#   - missing/empty head: cannot bind; reject
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip past local HEAD)
#   - run head is a strict ancestor of worktree HEAD, or diverged: no match
#     (local work advanced outside the run, or the branch tip was rewritten)
# fm_nm_run_is_pipeline_owned_active below carries the one exemption: a live
# run whose pipeline currently owns the branch binds without head equality.
fm_nm_head_matches_worktree() {  # <worktree> <run_head>
  local wt=$1 run_head=$2 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  git -C "$wt" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null
}

# 0 when a run's branch presentation identifies the checked-out branch. The
# no-mistakes CLI renders Firstmate's slash branch names with a hyphen, so both
# authoritative spellings are accepted and no other branch is normalized.
fm_nm_branch_matches_worktree() {  # <worktree> <run-branch>
  local wt=$1 run_branch=$2 current_branch hyphenated
  [ -n "$run_branch" ] || return 1
  current_branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ "$run_branch" = "$current_branch" ] && return 0
  hyphenated=${current_branch//\//-}
  [ "$run_branch" = "$hyphenated" ]
}

fm_nm_branch_sync_state() {  # <toon-output>
  awk '
    /^branch_sync:[[:space:]]*$/ { in_sync=1; next }
    in_sync && /^[^[:space:]][^:]*:/ { in_sync=0 }
    in_sync && /^[[:space:]]+state:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]+state:[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' <<<"$1"
}

# 0 when captured `axi status` has not reached a terminal state.
fm_nm_run_is_active() {  # <toon-output>
  local status outcome
  status=$(fm_nm_field "$1" status)
  outcome=$(fm_nm_field "$1" outcome)
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}

# 0 if head $2 resolves to a commit object in worktree $1 at all. This
# distinguishes a PROVEN mismatch (resolvable but not current: a historical or
# diverged head fm_nm_head_matches_worktree correctly rejects) from UNKNOWN
# attribution (unresolvable: e.g. a pipeline-owned lane head that never
# reached this worktree). A caller scanning run rows newest-first must stop on
# unknown attribution rather than surface an older, superseded run.
fm_nm_head_resolvable() {  # <worktree> <head>
  [ -n "$2" ] || return 1
  git -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1
}

# The one exemption to the head rule above: while the pipeline OWNS the branch
# (branch_sync.state=pipeline_owned), the daemon's own branch attribution IS
# the attribution for an ACTIVE run, and head equality must not be required -
# the pipeline's lane head is routinely not a git object in the task worktree
# (rebase and fix commits that were never pushed back), so the head rule
# rejects exactly the run that is most current. The exemption never applies to
# a terminal run: a terminal run has released the branch, and binding one by
# branch name alone is the historical reused-branch misattribution the head
# rule exists to prevent. fm_nm_branch_sync_state above reads the scalar
# directly under the top-level `branch_sync:` block; it is empty when the block
# is absent (no run on the current branch, another branch's run, or a CLI
# without branch sync).
fm_nm_run_is_pipeline_owned_active() {  # <toon-output>
  [ "$(fm_nm_branch_sync_state "$1")" = pipeline_owned ] || return 1
  fm_nm_run_is_active "$1"
}

# 0 when captured `axi status` shows a run that reached a terminal PASSED state.
# A terminal run has released the branch, so branch_sync no longer reports
# pipeline_owned and fm_nm_run_is_pipeline_owned_active above correctly rejects
# it. Its OWN reported head_sha is then the authority for the commits that run
# produced, including the review and doc commits its pipeline landed; the
# PR-ready owner compares that head with the forge's live PR head, which is
# exactly what refuses foreign commits pushed after the run finished.
# passed-with-override is a terminal pass carrying a Firstmate-approved test
# exception; it does not by itself mean every forge check is green.
fm_nm_run_is_terminal_passed() {  # <toon-output>
  local status outcome
  if fm_nm_run_is_active "$1"; then return 1; fi
  status=$(fm_nm_field "$1" status)
  outcome=$(fm_nm_field "$1" outcome)
  case "$outcome:$status" in
    passed:*|passed-with-override:*|checks-passed:*|*:passed|*:passed-with-override|*:checks-passed) return 0 ;;
  esac
  return 1
}

# During no-mistakes' ci monitor, top-level status and outcome stay running after
# checks turn green until the PR merges, while the append-only ci log records the
# transition. The most recent recognized log marker is therefore authoritative:
# green remains ready unless a later running, failed, issue, or re-arm marker
# supersedes it.
# A marker reporting no CI checks - a PR nothing has run a check against, or a
# repository that declares no_ci - reads no-checks, never green: no check has
# verified the PR, so it is not ready for review and a crew's own checks-green
# report is not promoted over it. Consumers must treat no-checks as unverified
# and still monitoring, not as a failure.
fm_nm_ci_checks_state() {  # <worktree> <timeout-secs> <run-id>
  local wt=$1 timeout_secs=$2 run_id=$3 log_tail marker
  [ -n "$run_id" ] || { printf 'unknown'; return 0; }
  log_tail=$(fm_nm_run "$wt" "$timeout_secs" axi logs --step ci --run "$run_id")
  [ -n "$log_tail" ] || { printf 'unknown'; return 0; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|repository declares no CI \(no_ci: true\)|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    # The no_ci sentence also says "treating as all checks passed", so it must
    # be matched before the generic checks-passed marker.
    *"repository declares no CI (no_ci: true)"*) printf 'no-checks' ;;
    *"no CI checks reported - still monitoring"*) printf 'no-checks' ;;
    *"checks passed"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}

# 0 when captured `axi status` output $3 for run $4 is PR-ready: a terminal
# passed run, or an active run whose ci step has turned green per the CI log.
# PR-ready is the handoff point for landing, not proof that the run has
# terminated; merge-time green belongs to the merge owner.
fm_nm_run_is_pr_ready() {  # <worktree> <timeout-secs> <status-out> <run-id>
  local status
  fm_nm_run_is_terminal_passed "$3" && return 0
  status=$(fm_nm_field "$3" status)
  case "$status" in ci|running) ;; *) return 1 ;; esac
  [ "$(fm_nm_ci_checks_state "$1" "$2" "$4")" = green ]
}

# Step names from a captured `axi status` document $1, in pipeline order.
# `axi rounds --step` requires a step name and no `axi` command lists them, so
# the run's own steps table is the enumeration source for the decision audit.
fm_nm_status_steps() {  # <toon-output>
  awk '
    function lead(s) { match(s, /^ */); return RLENGTH }
    /^[ ]*steps\[[0-9]+\]\{[^}]*\}:[ ]*$/ {
      header = $0
      sub(/.*\{/, "", header)
      sub(/\}.*/, "", header)
      n = split(header, cols, ",")
      step_col = 1
      for (i = 1; i <= n; i++) if (cols[i] == "step") step_col = i
      block = lead($0)
      in_steps = 1
      next
    }
    in_steps {
      if ($0 == "" || lead($0) <= block) { in_steps = 0; next }
      line = $0
      sub(/^ */, "", line)
      if (index(line, ",") == 0) next
      m = split(line, f, ",")
      if (step_col <= m && f[step_col] != "") print f[step_col]
    }
  ' <<<"$1"
}

# The canonical status-ledger key for a parked no-mistakes ask-user gate:
# nm-<run>-<step>. A worker escalates such a gate as
# `needs-decision [key=nm-<run>-<step>]` (the generated ship brief owns that
# wording), and firstmate's answer lands as `resolved [key=nm-<run>-<step>]: answered:`
# through `fm-send --resolve-key`. When retroactively deciding a finding with
# no open record left to close, firstmate appends
# `resolved [key=nm-<run>-<step>]: answered: <action> <finding-ids>` itself
# for the first gate response; later recovery appends use the -r<round> key.
# A re-parked gate or a finding-specific decision may key on a suffixed form
# (`-r<round>` or `-detail`), which bin/fm-classify-lib.sh accepts for the
# same step. fm_nm_ask_user_decisions below compares the pipeline's recorded
# decision events against those resolved records at PR-ready
# (bin/fm-pr-check.sh) and at done acceptance (bin/fm-crew-state.sh).
fm_nm_ask_user_key() {  # <run-id> <step>
  printf 'nm-%s-%s' "$1" "$2"
}

# One step's ask-user decision events from the `axi rounds --json` document in
# stdin. Prints one TAB-separated row per decision event:
# <step>\t<round N>\t<finding-id>\t<action>\t<response-origin>.
# With include-unresolved=1, rows also carry finding identity and round-context
# JSON for the decision audit below; rounds without decision events emit a
# context row so a newer covered answer can supersede carried authority.
#
# The pipeline records a gate response on the answered round: a `fix` response
# stores selection_source=user with the selected finding ids, an approve, skip,
# or abort stores selection_source=user_declined with an empty selection, and
# auto-fix rounds carry selection_source=auto_fix and are the pipeline's own
# work, never a decision event. A finding whose stored action is ask-user, or
# empty (the pipeline default), is an ask-user finding; on review an unselected
# one stays outstanding and re-parks, while on every other step it is
# implicitly declined.
#
# response_origin is the pipeline's record of who answered the gate:
# interactive and auto_yes are recorded answers. Missing, empty, and unknown
# are ORIGIN UNPROVEN, not a refusal: no-mistakes v1.106.1 records an approve,
# skip, or abort response's origin on the step result only and stores the
# answered round as a decline with the column default `unknown`, so the round's
# origin says nothing about the responder for those forms. The decision audit
# below then requires both a matching firstmate decision record and agreement
# between that decision and the round's recorded actions. Any other origin
# string refuses rather than guessing, so the audit never silently falls back
# to counting status-ledger text alone.
#
# Exit 0 prints the events (possibly none). Any other exit prints the concrete
# missing requirement on stdout and means the run data could not be read.
fm_nm_rounds_events() {  # <run-id> <step> [<include-unresolved>]
  local run_id=$1 step=$2 include_unresolved=${3:-0}
  python3 -c "$(cat <<'PY'
import json
import sys

run_id, step, include_unresolved = sys.argv[1:]


def unreadable(msg):
    print(f"no-mistakes axi rounds --run {run_id} --step {step}: {msg}")
    sys.exit(1)


raw = sys.stdin.read()
if not raw.strip():
    unreadable("returned no data, so its ask-user decisions cannot be read")
try:
    doc = json.loads(raw)
except ValueError as exc:
    unreadable(f"returned unparseable JSON ({exc})")
if not isinstance(doc, dict):
    unreadable("did not return a JSON document")
if doc.get("schema_version") != 1:
    unreadable(f"reports schema_version {doc.get('schema_version')!r}, not the supported 1")
rounds = doc.get("rounds")
if not isinstance(rounds, list):
    unreadable("reports no rounds array, so its ask-user decisions cannot be read")


def finding_actions(items, where):
    if items is None:
        return {}
    if not isinstance(items, list):
        unreadable(f"{where} is not an array")
    actions = {}
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not item["id"].strip():
            unreadable(f"{where} has a finding without a nonempty string id")
        action = item.get("action")
        if action in (None, ""):
            action = None
        elif action not in ("ask-user", "auto-fix", "no-op"):
            action = "ask-user"
        if item["id"] in actions:
            unreadable(f"{where} repeats finding id {item['id']}")
        actions[item["id"]] = action
    return actions


def selected_ids(value, where):
    if value is None:
        return []
    if not isinstance(value, list) or any(not isinstance(i, str) or not i.strip() for i in value):
        unreadable(f"{where} is not an array of nonempty string ids")
    return value


events = []
for rnd in rounds:
    if not isinstance(rnd, dict):
        unreadable("has a round that is not an object")
    label = rnd.get("round")
    source = rnd.get("selection_source")
    if source not in ("user", "user_declined"):
        continue
    if not isinstance(label, int) or isinstance(label, bool) or label < 1:
        unreadable("records a decision without a positive integer round")
    where = f"round {label}"
    presented = finding_actions(rnd.get("findings"), f"{where} findings")
    captured = finding_actions(rnd.get("user_findings"), f"{where} user_findings")
    selection = selected_ids(rnd.get("selected_finding_ids"), f"{where} selected_finding_ids")
    parked = list(presented) + [i for i in captured if i not in presented]
    parked += [i for i in selection if i not in presented and i not in captured]
    ask_user = []
    for fid in parked:
        pa, ca = presented.get(fid), captured.get(fid)
        if "ask-user" in (pa, ca) \
                or (fid in presented and pa is None) \
                or (fid not in presented and fid in captured and ca is None) \
                or (fid not in presented and fid not in captured):
            ask_user.append(fid)
    if not ask_user and include_unresolved != "1":
        continue
    origin = rnd.get("response_origin")
    if origin in (None, ""):
        origin = "unknown"
    if ask_user and origin not in ("interactive", "auto_yes", "unknown"):
        unreadable(f"{where} records an unrecognized response_origin {origin!r}, so who answered it cannot be verified")
    if source == "user":
        chosen = set(selection)
        resolved = {fid: "fix" for fid in ask_user if fid in chosen}
        if step != "review":
            for fid in ask_user:
                resolved.setdefault(fid, "skip")
    else:
        resolved = {fid: "declined" for fid in ask_user}
    identities = {}
    if include_unresolved == "1":
        for item in (rnd.get("findings") or []) + (rnd.get("user_findings") or []):
            if isinstance(item.get("description"), str) and item["description"].strip():
                identity = json.dumps(
                    [item.get(field) for field in ("description", "severity", "file", "line")],
                    ensure_ascii=True,
                )
                identities.setdefault(item["id"], set()).add(identity)
    round_identities = {
        fid: next(iter(identities[fid])) if len(identities.get(fid, set())) == 1 else "null"
        for fid in ask_user
    }
    context = json.dumps({
        "ids": parked,
        "unresolved": {fid: identity for fid, identity in round_identities.items() if fid not in resolved},
    })
    if include_unresolved == "1" and not resolved:
        events.append(f"{step}\t{where}\t-\tcontext\t{origin}\tnull\t{context}")
    for fid, action in resolved.items():
        event = f"{step}\t{where}\t{fid}\t{action}\t{origin}"
        if include_unresolved == "1":
            event += f"\t{round_identities[fid]}\t{context}"
        events.append(event)
# Buffered so a failure part-way through the document prints only what is
# missing, never a partial event list a caller could mistake for the audit.
for line in events:
    print(line)
sys.exit(0)
PY
)" "$run_id" "$step" "$include_unresolved"
}

# Read a bound run's recorded ask-user decision events from the pipeline's own
# `axi rounds --json` record, one bounded call per step the run's status
# document lists. The status document may be passed as arg 4 when the caller
# already captured the same run's `axi status`; otherwise it is read here with
# `axi status --run`. Prints one TAB-separated row per event:
# <step>\t<round N>\t<finding-id>\t<action>\t<response-origin>.
# The optional include-unresolved argument requests the extended rows owned by
# fm_nm_rounds_events above.
#
# Exit 0 prints the events (possibly none). Any other exit prints the concrete
# missing requirement on stdout - failed status or rounds call, a status
# document with no steps table, empty or unparseable rounds JSON, an
# unsupported schema_version, or an unrecognized response_origin - so callers
# fail closed naming exactly what is missing. It never falls back to the
# status-log text audit.
fm_nm_ask_user_resolutions() {  # <dir> <timeout_secs> <run-id> [<status-doc>] [<include-unresolved>]
  local dir=$1 timeout_secs=$2 run_id=$3 status=${4:-} include_unresolved=${5:-0} steps step json out rc acc=''
  command -v python3 >/dev/null 2>&1 \
    || { echo "python3 is required to read no-mistakes ask-user decisions"; return 1; }
  if [ -z "$status" ]; then
    status=$(fm_nm_run_checked "$dir" "$timeout_secs" axi status --run "$run_id") \
      || { echo "no-mistakes axi status --run $run_id failed, so its steps and ask-user decisions cannot be read"; return 1; }
  fi
  steps=$(fm_nm_status_steps "$status")
  [ -n "$steps" ] \
    || { echo "no-mistakes axi status --run $run_id reports no steps table, so its ask-user decisions cannot be read"; return 1; }
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    json=$(fm_nm_run_checked "$dir" "$timeout_secs" axi rounds --run "$run_id" --step "$step" --json) \
      || { echo "no-mistakes axi rounds --run $run_id --step $step failed, so its ask-user decisions cannot be read"; return 1; }
    rc=0
    out=$(fm_nm_rounds_events "$run_id" "$step" "$include_unresolved" <<<"$json") || rc=$?
    if [ "$rc" -ne 0 ]; then
      [ -n "$out" ] || out="no-mistakes axi rounds --run $run_id --step $step produced no readable output, so its ask-user decisions cannot be read"
      printf '%s\n' "$out"
      return 1
    fi
    [ -z "$out" ] || acc+=$out$'\n'
  done <<EOF
$steps
EOF
  [ -z "$acc" ] || printf '%s' "$acc"
}

# Verify that every ask-user decision event the pipeline recorded for run $3
# has a matching status record in task status file $4, one per gate response:
# presence alone is not enough. bin/fm-classify-lib.sh owns the status-line
# envelope grammar, its accepted step-key suffixes, and its process-evidence
# limitation. One answer binds the whole response; origin-unproven rounds also
# require the per-finding content check below.
# Round keys bind explicitly; bare and detail keys bind the current gate,
# initially the first response, and retain it until a new opening. A new opening
# after an answered gate advances to the next recorded response; repeated
# openings while pending and surplus answers do not advance it.
# Explicit round recovery answers do not change the current implicit gate.
# Review rounds with only unresolved ask-user findings do not consume implicit
# record occurrences, but an explicit round answer can update carried authority.
#
# A round whose response_origin is missing or unknown is ORIGIN UNPROVEN: the
# no-mistakes version Firstmate supports records approve, skip, and abort
# round declines without an origin, so the round alone cannot show who answered.
# Such a round passes only with BOTH
#   1. a matching firstmate `resolved` record for its occurrence (the same
#      binding above), or, when a later round of the same step re-raises a
#      finding on an origin-unproven round, a firstmate decision for that exact
#      finding in an earlier round of the step; and
#   2. agreement between what firstmate decided for the finding and the action
#      the round recorded: FIX requires a recorded fix, and IGNORE, APPROVE,
#      SKIP, or DECLINE requires a recorded decline or skip.
# Carry-forward requires matching description, severity, file, and line, with
# a nonempty description and no conflicting identity for that id in the round.
# A newer covered answer supersedes earlier authority for every presented id,
# including auto-fix, no-op, and unresolved findings, even when unreadable.
# Only eligible ask-user findings acquire new carried authority.
# A disagreement refuses naming the finding, the decided action, and the
# recorded action; an excerpt with no readable decision refuses as unverifiable.
# Interactive and auto_yes rounds keep the record-only rule: their origin is
# the pipeline's own record of a real answer, and requirement 2 is skipped.
#
# A firstmate `resolved` record's answer is read in its canonical form:
#   [Firstmate decision ...: | Captain decision ...:] <VERB> <ids>
#     [{';'|','|'and'} <VERB> <ids>]...
# VERB is FIX, IGNORE, DECLINE, SKIP, or APPROVE (case-insensitive) and ids are
# finding ids the gate round presented. Other prose prefixes authorize nothing.
# The first clause ends at the first '(',
# '.', ' Reason', or end of text, and everything after it is reason prose that is ignored, including
# parenthesised asides like "(with R1 and R2 as auto-fix)". A bare APPROVE,
# IGNORE, DECLINE, or SKIP with no ids declines every finding the round
# presented; ordinary reason prose may contain action words, numbers, or
# hyphenated words, but unknown finding-id-shaped labels and additional directives refuse.
# After a decline-class verb, the id list ends at the first token that is not
# a finding id or list separator, and the remaining first-clause text is prose:
# `APPROVE test-1 without live validation` declines test-1.
# After FIX ids, trailing prose remains unreadable, so
# `FIX test-1 is not what I want` authorizes nothing.
# A bare FIX is prose and refuses. Named findings bind their own
# verb, every other presented finding is the pipeline's implicit decline, and
# one finding bound to fix and decline classes is ambiguous and refuses;
# IGNORE, DECLINE, SKIP, and APPROVE are equivalent decline verbs. Firstmate
# must keep writing this form; docs/configuration.md states it for operators.
#
# Returns 0 silently when the run recorded no ask-user decision events or every
# event is matched. Returns 1 and prints a per-step refusal detail (run, step,
# finding, round, and answering origin or unproven origin) on stdout when a
# gate response has no matching resolved record or contradicts firstmate's
# decision. Returns 2 and prints the concrete missing requirement on stdout when
# the run's decision data cannot be read; callers must surface that detail
# rather than substituting a generic refusal.
# Callers must source bin/fm-classify-lib.sh for the status grammar.
fm_nm_ask_user_decisions() {  # <dir> <timeout_secs> <run-id> <status-file> [<status-doc>]
  local dir=$1 timeout_secs=$2 run_id=$3 status_file=$4 status_doc=${5:-}
  local rows steps step report rc bad=
  declare -F status_resolved_step_records >/dev/null 2>&1 \
    || { echo "bin/fm-classify-lib.sh is required to read firstmate decision records" >&2; return 2; }
  rows=$(fm_nm_ask_user_resolutions "$dir" "$timeout_secs" "$run_id" "$status_doc" 1) || {
    [ -z "$rows" ] || printf '%s\n' "$rows"
    return 2
  }
  [ -n "$rows" ] || return 0
  steps=$(printf '%s\n' "$rows" | cut -f1 | sort -u)
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    rc=0
    report=$({
      printf '%s\n' "$rows" | awk -F '\t' -v s="$step" '$1 == s { print "event\t" $0 }'
      status_resolved_step_records "$status_file" "$(fm_nm_ask_user_key "$run_id" "$step")"
    } | python3 -c "$(cat <<'PY'
import json
import re
import sys

run_id, step, key = sys.argv[1:]
events, records = [], []
for line in sys.stdin:
    fields = line.rstrip("\n").split("\t")
    if fields[0] == "event":
        events.append(fields[1:])
    else:
        records.append(fields)
if not events:
    sys.exit(0)

rounds = sorted({int(event[1][len("round "):]) for event in events if event[3] != "context"})
current = rounds[0] if rounds else 1
pending = None
bindings = {}
covered = set()
round_answer = {}
for fields in records:
    kind, record_key = fields[0], fields[1]
    answer = fields[2] if len(fields) > 2 else ""
    if record_key.startswith(key + "-r"):
        bound = int(record_key[len(key + "-r"):])
        if kind == "open" and bound in rounds:
            current = bound
    elif kind == "open":
        if pending is not None:
            current = pending
        elif current in covered:
            current = next((rnd for rnd in rounds if rnd > current), current + 1)
        bound = current
    else:
        bound = bindings.get(record_key, current)
    bindings[record_key] = bound
    if kind == "open":
        if bound in rounds:
            pending = bound
    else:
        covered.add(bound)
        round_answer[bound] = answer
        if pending == bound:
            pending = None

LABEL = {"fix": "fix", "nonfix": "decline/approve"}
VERBS = ("fix", "ignore", "decline", "skip", "approve")


def action_of(keyword):
    return "fix" if keyword.lower().startswith("fix") else "nonfix"


def decided_actions(answer, finding_ids):
    # Parse the canonical first-clause contract in the enclosing shell header.
    text = answer or ""
    id_alts = sorted((re.escape(fid) for fid in finding_ids), key=len, reverse=True)
    verb_re = re.compile(r"(?<![\w-])(?P<verb>" + "|".join(VERBS) + r")(?![\w-])", re.IGNORECASE)
    first = verb_re.search(text)
    if not first:
        return {}
    prefix = text[:first.start()]
    if prefix.strip() and not re.match(r"(?is)^(?:firstmate|captain)\s+decision\b[^:]*:\s*$", prefix.strip()):
        return {}
    clause_end = len(text)
    for pattern in (r"\(", r"\.", r"(?i:\breason\b)"):
        match = re.search(pattern, text[first.start():])
        if match:
            clause_end = min(clause_end, first.start() + match.start())
    clause = text[first.start():clause_end]

    id_re = re.compile(r"(?<![\w-])(?P<id>" + "|".join(id_alts) + r")(?![\w-])") if id_alts else None
    joiner_re = re.compile(r"(?:[;,]|\band\b)\s*", re.IGNORECASE)
    finding_label_re = re.compile(r"\b(?=[A-Za-z0-9-]*\d)[A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)*\b")

    pos = 0
    groups = []
    current = None
    trailing = False
    trailing_prose_ok = False
    while pos < len(clause):
        if clause[pos].isspace():
            pos += 1
            continue
        match = id_re.match(clause, pos) if id_re else None
        if match:
            if current is None:
                return {}
            current[1].append(match.group("id"))
            pos = match.end()
            continue
        match = joiner_re.match(clause, pos)
        if match and match.end() > pos:
            pos = match.end()
            match = verb_re.match(clause, pos)
            if match:
                current = [action_of(match.group("verb")), []]
                groups.append(current)
                pos = match.end()
            continue
        match = verb_re.match(clause, pos) if current is None else None
        if not match:
            trailing = True
            # After a decline-class verb the id list ends at the first
            # non-list token and the rest of the clause is prose; after FIX the
            # same shape stays unreadable, so a qualified fix never authorizes.
            trailing_prose_ok = current is not None and current[0] == "nonfix"
            break
        current = [action_of(match.group("verb")), []]
        groups.append(current)
        pos = match.end()

    if not groups:
        return {}
    if trailing and trailing_prose_ok:
        remainder = clause[pos:]
        for match in verb_re.finditer(remainder):
            suffix = remainder[match.end():].lstrip()
            if (id_re and id_re.match(suffix)) or finding_label_re.match(suffix):
                return {}
        if any(verb_re.match(part.lstrip()) for part in remainder.split(";")[1:]):
            return {}
    if len(groups) == 1 and not groups[0][1]:
        # A single decline verb with no ids is the gate-wide form; prose after
        # it is the reason (`APPROVE proceeding without live validation ...`).
        # A bare FIX stays unreadable: without ids it is prose, not a directive.
        gate = groups[0][0]
        if gate != "nonfix":
            return {}
        remainder = clause[pos:]
        if finding_label_re.search(remainder):
            return {}
        return {fid: gate for fid in finding_ids}
    if trailing and not trailing_prose_ok:
        return {}
    decided = {}
    for value, ids in groups:
        if not ids:
            return {}
        for fid in ids:
            if fid in decided and decided[fid] != value:
                return {}
            decided[fid] = value
    for fid in finding_ids:
        decided.setdefault(fid, "nonfix")
    return decided


def agrees(decided, recorded):
    if decided == "fix":
        return recorded == "fix"
    return recorded in ("declined", "skip")


by_round = {}
round_findings = {}
round_context = {}
for _, rnd, fid, action, origin, identity, context in events:
    number = int(rnd[len("round "):])
    context = json.loads(context)
    round_findings.setdefault(number, {}).update(context["unresolved"])
    if action != "context":
        by_round.setdefault(number, []).append((fid, action, origin, identity))
        round_findings[number][fid] = identity
    round_context[number] = context["ids"]

decisions = {}
missing = []
problems = []
for rnd in sorted(round_context):
    round_events = by_round.get(rnd, [])
    decided = {}
    if rnd in covered:
        decided = decided_actions(round_answer[rnd], round_context[rnd])
        decided = {fid: value for fid, value in decided.items() if fid in round_findings[rnd]}
    for fid, action, origin, identity in round_events:
        if origin != "unknown":
            if rnd not in covered:
                missing.append((fid, rnd, action, origin))
            continue
        verdict = decided.get(fid)
        if rnd not in covered:
            previous_identity, previous_verdict = decisions.get(fid, (None, None))
            verdict = previous_verdict if previous_identity == identity else None
        if verdict is None:
            if rnd in covered:
                problems.append((fid, rnd, "unreadable", action))
            else:
                missing.append((fid, rnd, action, origin))
        elif not agrees(verdict, action):
            problems.append((fid, rnd, verdict, action))
    if rnd in covered:
        for fid in round_context[rnd]:
            decisions.pop(fid, None)
        for fid, identity in round_findings[rnd].items():
            if decided.get(fid) is not None and identity != "null":
                decisions[fid] = (identity, decided[fid])


def report_problems(out):
    if not problems:
        return
    out.write(f"run {run_id} step {step}: origin-unproven decision disagrees with firstmate's record:\n")
    for fid, rnd, verdict, action in problems:
        label = LABEL[verdict] if verdict in LABEL else "no readable action"
        out.write(f"  finding {fid} (round {rnd}): firstmate decided {label}, but the pipeline recorded {action}\n")


if missing or problems:
    if missing:
        print(f"run {run_id} step {step}: missing matching resolved [key={key}] record(s):")
        for fid, rnd, action, origin in missing:
            if origin == "unknown":
                print(f"  finding {fid} resolved as {action} (round {rnd}, origin unproven)")
            else:
                print(f"  finding {fid} resolved as {action} (round {rnd}, answered {origin})")
    report_problems(sys.stdout)
    sys.exit(1)
PY
)" "$run_id" "$step" "$(fm_nm_ask_user_key "$run_id" "$step")") || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '%s\n' "$report"
      bad=1
    fi
  done <<EOF
$steps
EOF
  [ -z "$bad" ]
}
