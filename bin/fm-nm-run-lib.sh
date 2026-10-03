#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting), fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment), and
# fm-receipt-check.sh (bound-run completion). Teardown uses only strict
# branch-and-head identity; crew-state additionally permits the active
# pipeline-owned exemption defined below, and receipt-check's active-advance
# ownership proof is fm_nm_run_branch_ownership. Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
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

# Print the authoritative full commit identity for a run head in worktree $1.
# Git accepts abbreviated identities only after resolving them against the
# repository object database; callers must never compare the presentation form
# emitted by `axi status` directly with a full local SHA.
fm_nm_resolve_head() {  # <worktree> <run-head>
  [ -n "$2" ] || return 1
  git -C "$1" rev-parse --verify "${2}^{commit}" 2>/dev/null
}

# 0 when $3 is a strict descendant of $2 after both identities are resolved by
# Git in worktree $1.
fm_nm_head_descends_from() {  # <worktree> <ancestor> <descendant>
  local wt=$1 ancestor=$2 descendant=$3 ancestor_full descendant_full
  ancestor_full=$(fm_nm_resolve_head "$wt" "$ancestor") || return 1
  descendant_full=$(fm_nm_resolve_head "$wt" "$descendant") || return 1
  [ "$ancestor_full" != "$descendant_full" ] \
    && git -C "$wt" merge-base --is-ancestor "$ancestor_full" "$descendant_full" 2>/dev/null
}

# 0 when $3 is a faithful restamp of the validated chain from $2 in worktree $1.
# The base must be an ancestor of both heads, their commit counts must match, and
# each pair of commits in base-to-head order must carry the same tree object.
fm_nm_head_is_faithful_restamp() {  # <worktree> <base> <validated-head> <candidate-head>
  local wt=$1 base=$2 validated=$3 candidate=$4 base_full validated_full candidate_full
  local validated_list candidate_list validated_trees candidate_trees commit
  base_full=$(fm_nm_resolve_head "$wt" "$base") || return 1
  validated_full=$(fm_nm_resolve_head "$wt" "$validated") || return 1
  candidate_full=$(fm_nm_resolve_head "$wt" "$candidate") || return 1
  git -C "$wt" merge-base --is-ancestor "$base_full" "$validated_full" 2>/dev/null || return 1
  git -C "$wt" merge-base --is-ancestor "$base_full" "$candidate_full" 2>/dev/null || return 1
  validated_list=$(git -C "$wt" rev-list --reverse "$base_full..$validated_full") || return 1
  candidate_list=$(git -C "$wt" rev-list --reverse "$base_full..$candidate_full") || return 1
  validated_trees=$(printf '%s\n' "$validated_list" | while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    git -C "$wt" rev-parse --verify "${commit}^{tree}" || exit 1
  done) || return 1
  candidate_trees=$(printf '%s\n' "$candidate_list" | while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    git -C "$wt" rev-parse --verify "${commit}^{tree}" || exit 1
  done) || return 1
  [ "$validated_trees" = "$candidate_trees" ]
}

# 0 when $4 is accounted for by the validated chain in worktree $1.
# It matches the validated head itself, a faithful restamp of the validated
# chain from $2, a strict descendant of $3, or a strict descendant of a faithful
# restamp of the validated chain.
fm_nm_head_is_accounted() {  # <worktree> <base> <validated-head> <candidate-head>
  local wt=$1 base=$2 validated=$3 candidate=$4
  local base_full validated_full candidate_full validated_count prefix_head prefix_count
  base_full=$(fm_nm_resolve_head "$wt" "$base") || return 1
  validated_full=$(fm_nm_resolve_head "$wt" "$validated") || return 1
  candidate_full=$(fm_nm_resolve_head "$wt" "$candidate") || return 1
  [ "$candidate_full" = "$validated_full" ] && return 0
  fm_nm_head_is_faithful_restamp "$wt" "$base_full" "$validated_full" "$candidate_full" && return 0
  fm_nm_head_descends_from "$wt" "$validated_full" "$candidate_full" && return 0
  # Pipeline restamps can be followed by additional owned commits; the leading
  # segment must be a faithful restamp of the validated chain from the base.
  validated_count=$(git -C "$wt" rev-list --count "$base_full..$validated_full" 2>/dev/null) || return 1
  [ "$validated_count" -gt 0 ] || return 1
  prefix_head=$(git -C "$wt" rev-list --first-parent --reverse "$base_full..$candidate_full" 2>/dev/null | head -n "$validated_count" | tail -1) || return 1
  [ -n "$prefix_head" ] || return 1
  prefix_count=$(git -C "$wt" rev-list --count "$base_full..$prefix_head" 2>/dev/null) || return 1
  [ "$prefix_count" -eq "$validated_count" ] || return 1
  fm_nm_head_is_faithful_restamp "$wt" "$base_full" "$validated_full" "$prefix_head" || return 1
  git -C "$wt" merge-base --is-ancestor "$prefix_head" "$candidate_full" 2>/dev/null || return 1
  [ "$prefix_head" != "$candidate_full" ] || return 1
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

# Print the proven branch-ownership state for an ACTIVE run, or nothing.
# `pipeline_owned` in captured `axi status` output $3 means the pipeline still
# holds the branch, so the head it reports is run-owned evidence. When `axi
# status` omits branch_sync, `axi sync --check` supplies the same proof: state
# pipeline_owned again, or state synchronized once the pipeline pushed its head
# back and the branch converged while the run stays active only to monitor its
# PR. The converged state is accepted only on the full sync evidence: the same
# run id, submitted_head resolving to expected head $5, current_head and the
# reported local head both resolving to the run's observed head $6, relation
# equal, and safety already_synchronized. Anything missing, stale, or
# mismatched prints nothing so callers keep refusing unproven advances.
fm_nm_run_branch_ownership() {  # <worktree> <timeout-secs> <status-out> <run-id> <expected-submitted> <expected-current>
  local wt=$1 timeout_secs=$2 status_out=$3 run_id=$4 submitted=$5 current=$6
  local state sync_out sync_state sync_run sync_submitted sync_current sync_local
  state=$(fm_nm_branch_sync_state "$status_out")
  if [ "$state" = pipeline_owned ]; then
    printf 'pipeline_owned'
    return 0
  fi
  sync_out=$(fm_nm_run_checked "$wt" "$timeout_secs" axi sync --check) || sync_out=
  [ -n "$sync_out" ] || return 1
  sync_state=$(fm_nm_branch_sync_state "$sync_out")
  case "$sync_state" in pipeline_owned|synchronized) ;; *) return 1 ;; esac
  sync_run=$(fm_nm_field "$sync_out" run)
  [ -n "$sync_run" ] && [ "$sync_run" = "$run_id" ] || return 1
  sync_submitted=$(fm_nm_field "$sync_out" submitted_head)
  sync_current=$(fm_nm_field "$sync_out" current_head)
  if [ -n "$sync_submitted" ]; then
    [ "$(fm_nm_resolve_head "$wt" "$sync_submitted" || true)" = "$submitted" ] || return 1
  fi
  if [ -n "$sync_current" ]; then
    [ "$(fm_nm_resolve_head "$wt" "$sync_current" || true)" = "$current" ] || return 1
  fi
  if [ "$sync_state" = synchronized ]; then
    [ "$(fm_nm_field "$sync_out" relation)" = equal ] || return 1
    [ "$(fm_nm_field "$sync_out" safety)" = already_synchronized ] || return 1
    [ -n "$sync_submitted" ] && [ -n "$sync_current" ] || return 1
    sync_local=$(fm_nm_resolve_head "$wt" "$(fm_nm_field "$sync_out" head)" || true)
    [ -n "$sync_local" ] && [ "$sync_local" = "$current" ] || return 1
  fi
  printf '%s' "$sync_state"
}

# 0 when captured `axi status` shows a run that reached a terminal PASSED state.
# A terminal run has released the branch, so branch_sync no longer reports
# pipeline_owned and fm_nm_run_is_pipeline_owned_active above correctly rejects
# it. Its OWN reported head is then the authority for the commits that run
# produced, including the review and doc commits its pipeline landed after the
# validated head. Callers must therefore still require that reported head to be
# the current worktree head: that is exactly what refuses foreign commits landed
# after the run finished, which the run never reports as its head.
fm_nm_run_is_terminal_passed() {  # <toon-output>
  local status outcome
  if fm_nm_run_is_active "$1"; then return 1; fi
  status=$(fm_nm_field "$1" status)
  outcome=$(fm_nm_field "$1" outcome)
  case "$outcome:$status" in
    passed:*|checks-passed:*|*:passed|*:checks-passed) return 0 ;;
  esac
  return 1
}

# During no-mistakes' ci monitor, top-level status and outcome stay running after
# checks turn green until the PR merges, while the append-only ci log records the
# transition. The most recent recognized log marker is therefore authoritative:
# green remains ready unless a later running, failed, issue, or re-arm marker
# supersedes it.
fm_nm_ci_checks_state() {  # <worktree> <timeout-secs> <run-id>
  local wt=$1 timeout_secs=$2 run_id=$3 log_tail marker
  [ -n "$run_id" ] || { printf 'unknown'; return 0; }
  log_tail=$(fm_nm_run "$wt" "$timeout_secs" axi logs --step ci --run "$run_id")
  [ -n "$log_tail" ] || { printf 'unknown'; return 0; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' \
    | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}

# The canonical status-ledger key for a parked no-mistakes ask-user gate:
# nm-<run>-<step>. A worker escalates such a gate as
# `needs-decision [key=nm-<run>-<step>]` (the generated ship brief owns that
# wording), and firstmate's answer lands as `resolved [key=nm-<run>-<step>]: answered:`
# through `fm-send --resolve-key` or an equivalent firstmate-authored append.
# fm_nm_ask_user_decisions below compares the run's recorded gate resolutions
# against those resolved records at completion time.
fm_nm_ask_user_key() {  # <run-id> <step>
  printf 'nm-%s-%s' "$1" "$2"
}

# Read a bound run's recorded ask-user gate resolutions from the daemon's
# append-only state database and print one TAB-separated row per finding each
# response resolved: <step>\t<event>\t<finding-id>\t<action>.
#
# No `axi` read command exposes per-finding gate decisions, so this is a
# read-only sqlite3 evidence query (mode=ro) rather than a CLI call - the same
# bounded, side-effect-free channel the upstream copy of this library already
# uses for run inventory. NM_HOME selects the no-mistakes home; it defaults to
# ~/.no-mistakes, and a relative NM_HOME resolves against dir $1.
#
# Resolution model (internal/pipeline/executor.go): a `fix` response records
# selection_source=user and the selected finding ids on the gate's last round;
# an approve, skip, or abort records selection_source=user_declined with an
# empty selection. On review, an unselected ask-user finding stays outstanding
# and re-parks; on every other step it is implicitly declined. A completed or
# skipped step that still reports an ask-user finding no recorded decision
# covered is emitted as a step-level event so a decision write failure or a
# reconciled gate can never read as a clean pass.
#
# Exit 0 prints the resolutions (possibly none). Any other exit means the run
# data could not be read; the concrete missing requirement is written to
# stderr so callers can fail closed without inventing an unrelated refusal.
fm_nm_ask_user_resolutions() {  # <dir> <timeout_secs> <run-id>
  local dir=$1 timeout_secs=$2 run_id=$3
  command -v python3 >/dev/null 2>&1 \
    || { echo "error: python3 with sqlite3 is required to read no-mistakes gate decisions" >&2; return 1; }
  fm_nm_cmd_bounded "$dir" "$timeout_secs" python3 - "$run_id" "$dir" <<'PY'
import json
import os
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

run_id, worktree = sys.argv[1], sys.argv[2]

root = Path(os.environ.get("NM_HOME") or Path.home() / ".no-mistakes")
if not root.is_absolute():
    root = Path(worktree) / root
db_path = root / "state.sqlite"
if not db_path.is_file():
    sys.stderr.write(f"missing no-mistakes state database at {db_path}\n")
    sys.exit(1)


def missing(msg):
    sys.stderr.write(f"no-mistakes run data for {run_id} is unreadable: {msg}\n")
    sys.exit(1)


try:
    db = sqlite3.connect(db_path.as_uri() + "?mode=ro", uri=True, timeout=30)
    with closing(db):
        tables = {r[0] for r in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        for table in ("runs", "step_results", "step_rounds"):
            if table not in tables:
                missing(f"table {table} is absent")
        if not db.execute("SELECT 1 FROM runs WHERE id = ?", (run_id,)).fetchone():
            missing(f"run {run_id} is absent")
        s_cols = {r[1] for r in db.execute("PRAGMA table_info(step_results)")}
        if not {"id", "run_id", "step_name", "step_order", "status", "findings_json"} <= s_cols:
            missing("step_results lacks its base columns")
        opt = ",".join(c if c in s_cols else "NULL" for c in
                       ("approval_reason", "override_reason", "skip_reason"))
        steps = db.execute(
            "SELECT id, step_name, step_order, status, findings_json, " + opt +
            " FROM step_results WHERE run_id = ? ORDER BY step_order",
            (run_id,)).fetchall()
        r_cols = {r[1] for r in db.execute("PRAGMA table_info(step_rounds)")}
        if not {"step_result_id", "round", "selection_source",
                "selected_finding_ids", "findings_json", "user_findings_json"} <= r_cols:
            missing("step_rounds lacks its gate-decision columns")
        rounds = db.execute(
            "SELECT step_result_id, round, selection_source, selected_finding_ids,"
            " findings_json, user_findings_json FROM step_rounds"
            " WHERE step_result_id IN (SELECT id FROM step_results WHERE run_id = ?)"
            " ORDER BY step_result_id, round",
            (run_id,)).fetchall()
except sqlite3.Error as exc:
    missing(str(exc))


def serialized(js, step, field):
    if js is None or js == "":
        return None
    try:
        return json.loads(js)
    except (TypeError, ValueError) as exc:
        missing(f"step {step} field {field}: invalid JSON ({exc})")


def finding_actions(js, step, field):
    data = serialized(js, step, field)
    if data is None and (js is None or js == ""):
        return {}
    items = data.get("findings") if isinstance(data, dict) else data
    if not isinstance(items, list):
        missing(f"step {step} field {field}: findings must be an array")
    actions = {}
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str) or not item["id"].strip():
            missing(f"step {step} field {field}: finding requires a nonempty string id")
        if item.get("action") not in ("ask-user", "auto-fix", "no-op"):
            missing(f"step {step} field {field}: finding {item['id']} has invalid action")
        if item["id"] in actions:
            missing(f"step {step} field {field}: duplicate finding id {item['id']}")
        actions[item["id"]] = item["action"]
    return actions


def selected_ids(js, step, field):
    data = serialized(js, step, field)
    if data is None and (js is None or js == ""):
        return []
    if not isinstance(data, list) or any(not isinstance(i, str) or not i.strip() for i in data):
        missing(f"step {step} field {field}: selection must be an array of nonempty string ids")
    return data


rounds_by_step = {}
for row in rounds:
    rounds_by_step.setdefault(row[0], []).append(row)

for (step_result_id, step, _order, status, step_findings,
     approval, override, skip_reason) in steps:
    step_actions = finding_actions(step_findings, step, "step_results.findings_json")
    resolved = {}
    events = []
    for (_sr, rnd, src, sel_js, fj, ufj) in rounds_by_step.get(step_result_id, []):
        presented = finding_actions(fj, step, f"step_rounds.findings_json round {rnd}")
        captured = finding_actions(ufj, step, f"step_rounds.user_findings_json round {rnd}")
        selection = selected_ids(sel_js, step, f"step_rounds.selected_finding_ids round {rnd}")
        if src not in ("user", "user_declined"):
            continue
        ask_user = [fid for fid in list(presented) + [i for i in captured if i not in presented]
                    if presented.get(fid) == "ask-user" or captured.get(fid) == "ask-user"]
        if not ask_user:
            continue
        resolved_now = {}
        if src == "user":
            sel = set(selection)
            for fid in ask_user:
                if fid in sel:
                    resolved_now[fid] = "fix"
            if step != "review":
                for fid in ask_user:
                    resolved_now.setdefault(fid, "skip")
        else:
            if approval or override:
                action = "approve"
            elif status == "skipped" or skip_reason:
                action = "skip"
            elif status == "failed":
                action = "abort"
            else:
                action = "approve"
            for fid in ask_user:
                resolved_now[fid] = action
        if resolved_now:
            events.append((f"round {rnd}", resolved_now))
            resolved.update(resolved_now)
    leftovers = [fid for fid, action in step_actions.items()
                 if action == "ask-user" and fid not in resolved]
    if leftovers and status in ("completed", "skipped"):
        if approval or override:
            action = "approve"
        elif status == "skipped" or skip_reason:
            action = "skip"
        else:
            action = "unresolved"
        events.append(("step", {fid: action for fid in leftovers}))
    for marker, res in events:
        for fid, action in res.items():
            print(f"{step}\t{marker}\t{fid}\t{action}")
PY
}

# Verify that every ask-user resolution event recorded in run $3 has a matching
# canonical `resolved [key=nm-<run>-<step>]: answered:` record in task status file $4,
# one record per gate response: each parked gate must be escalated and decided
# again, so presence alone is not enough.
#
# Returns 0 silently when the run resolved no ask-user findings or every
# decision is matched. Returns 1 and prints a per-step refusal detail (finding
# id and action) on stdout when the task status file holds too few matching
# resolved records. Returns 2 when the run's decision data cannot be read;
# fm_nm_ask_user_resolutions then names the concrete missing requirement on
# stderr. Callers must source bin/fm-classify-lib.sh for the status grammar.
fm_nm_ask_user_decisions() {  # <dir> <timeout_secs> <run-id> <status-file>
  local dir=$1 timeout_secs=$2 run_id=$3 status_file=$4
  local rows steps step need have bad=
  declare -F status_resolved_key_count >/dev/null 2>&1 \
    || { echo "error: bin/fm-classify-lib.sh is required to read firstmate decision records" >&2; return 2; }
  rows=$(fm_nm_ask_user_resolutions "$dir" "$timeout_secs" "$run_id") || return 2
  [ -n "$rows" ] || return 0
  steps=$(printf '%s\n' "$rows" | cut -f1 | sort -u)
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    need=$(printf '%s\n' "$rows" | awk -F '\t' -v s="$step" \
      '$1 == s { if (!($2 in m)) { m[$2] = 1; n++ } } END { print n + 0 }')
    have=$(status_resolved_key_count "$status_file" "$(fm_nm_ask_user_key "$run_id" "$step")")
    if [ "$have" -lt "$need" ] 2>/dev/null; then
      printf 'step %s: %d recorded ask-user gate decision(s) but only %s resolved [key=%s] record(s):\n' \
        "$step" "$need" "$have" "$(fm_nm_ask_user_key "$run_id" "$step")"
      printf '%s\n' "$rows" | awk -F '\t' -v s="$step" \
        '$1 == s { print "  finding " $3 " resolved as " $4 " (" $2 ")" }' | sort -u
      bad=1
    fi
  done <<EOF
$steps
EOF
  [ -z "$bad" ]
}
