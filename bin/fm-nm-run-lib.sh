#!/usr/bin/env bash
# Shared no-mistakes axi run attribution primitives.
#
# ONE owner for the no-mistakes run-attribution primitives used by
# fm-crew-state.sh (read-only current-state reporting), fm-teardown.sh
# (pre-teardown run abort, see its "Fix 1" header comment), and
# fm-receipt-check.sh (bound-run completion). Teardown uses only strict
# branch-and-head identity; crew-state additionally permits the active
# pipeline-owned exemption defined below. Getting this wrong in either
# direction is unsafe: a false negative hides a genuinely parked run, and a
# false positive lets teardown act on a run it does not own.
#
# Bounded call to `no-mistakes "$@"` in dir $1, timeout $2 seconds. The bounded
# form preserves stdout, stderr, and exit status; the checked form discards
# stderr, while fm_nm_run keeps the fail-open query contract for read-only callers.
fm_nm_run_bounded() {  # <dir> <timeout_secs> <args...>
  local dir=$1 timeout_secs=$2 have_timeout=none nm_bin=${FM_NO_MISTAKES_BIN:-no-mistakes}
  shift 2
  if command -v timeout >/dev/null 2>&1; then have_timeout=timeout
  elif command -v gtimeout >/dev/null 2>&1; then have_timeout=gtimeout
  elif command -v perl >/dev/null 2>&1; then have_timeout=perl
  fi
  case "$have_timeout" in
    timeout)  ( cd "$dir" && timeout "$timeout_secs" "$nm_bin" "$@" ) ;;
    gtimeout) ( cd "$dir" && gtimeout "$timeout_secs" "$nm_bin" "$@" ) ;;
    perl)     ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout_secs" "$nm_bin" "$@" ) ;;
    *)        return 1 ;;
  esac
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
