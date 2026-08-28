#!/usr/bin/env bash
# Guarded ordinary-worker OMP recovery support for bin/fm-spawn.sh.
#
# This library owns recovery-only identity validation, session selection, staged
# endpoint metadata, and rollback cleanup.  fm-spawn owns argument parsing,
# verified adapter launch templates, and acknowledgement waiting.
#
# Recovery accepts an existing task identity only.  It never allocates or
# freshens a worktree, changes a branch, or rewrites the task record before the
# replacement OMP turn has acknowledged.  The only supported harness/runtime
# combinations are harness=omp on tmux or Herdr.
# shellcheck disable=SC2034 # fm-spawn consumes this module's recovery-state exports.

fm_spawn_recovery_exact_meta_value() { # <meta> <key>
  local meta=$1 key=$2 value
  value=$(fm_backend_meta_exact_value "$meta" "$key") || return 1
  case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_spawn_recovery_meta_count() { # <meta> <key>
  grep -c "^$2=" "$1" 2>/dev/null || true
}

fm_spawn_recovery_preselect() { # <state> <task-id>
  local state=$1 id=$2 meta harness kind backend_count backend
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "error: OMP recovery requires regular recorded metadata for task $id; preserving task state" >&2
    return 1
  }
  harness=$(fm_spawn_recovery_exact_meta_value "$meta" harness 2>/dev/null || true)
  if [ "$harness" != omp ]; then
    echo "error: ordinary-worker recovery supports only recorded harness=omp tasks; task $id records harness=${harness:-unknown}; refusing before mutation" >&2
    return 1
  fi
  kind=$(fm_spawn_recovery_exact_meta_value "$meta" kind 2>/dev/null || true)
  case "$kind" in
    ship|scout) ;;
    *) echo "error: OMP recovery supports only recorded ordinary ship or scout tasks; task $id records kind=${kind:-unknown}; refusing before mutation" >&2; return 1 ;;
  esac
  fm_spawn_recovery_validate_delivery "$meta" "$kind" || {
    echo "error: OMP recovery found inconsistent recorded delivery identity for task $id; refusing before mutation" >&2
    return 1
  }
  backend_count=$(fm_spawn_recovery_meta_count "$meta" backend)
  case "$backend_count" in
    0) backend=tmux ;;
    1) backend=$(fm_spawn_recovery_exact_meta_value "$meta" backend 2>/dev/null || true) ;;
    *) backend= ;;
  esac
  case "$backend" in
    tmux|herdr) printf '%s\n' "$backend" ;;
    *)
      echo "error: OMP ordinary-worker recovery is verified only on tmux or Herdr; task $id records backend=${backend:-ambiguous}; refusing before mutation" >&2
      return 1
      ;;
  esac
}

fm_spawn_recovery_validate_delivery() { # <meta> <kind>
  local meta=$1 kind=$2 mode yolo mode_count yolo_count
  case "$kind" in
    ship)
      mode=$(fm_spawn_recovery_exact_meta_value "$meta" mode 2>/dev/null || true)
      yolo=$(fm_spawn_recovery_exact_meta_value "$meta" yolo 2>/dev/null || true)
      case "$mode" in no-mistakes|direct-PR|local-only) ;; *) return 1 ;; esac
      case "$yolo" in on|off) ;; *) return 1 ;; esac
      ;;
    scout)
      mode_count=$(fm_spawn_recovery_meta_count "$meta" mode)
      yolo_count=$(fm_spawn_recovery_meta_count "$meta" yolo)
      [ "$mode_count" -eq 0 ] && [ "$yolo_count" -eq 0 ] || return 1
      ;;
    *) return 1 ;;
  esac
}

fm_spawn_recovery_validate_worktree() { # <project> <worktree> <task-id>
  local project=$1 worktree=$2 id=$3 project_real wt_real wt_top branch default
  project_real=$(cd "$project" 2>/dev/null && pwd -P) || return 1
  wt_real=$(cd "$worktree" 2>/dev/null && pwd -P) || return 1
  wt_top=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null || true)
  wt_top=$(cd "$wt_top" 2>/dev/null && pwd -P || true)
  [ -n "$wt_top" ] && [ "$wt_real" = "$wt_top" ] && [ "$wt_real" != "$project_real" ] || return 1
  git -C "$project_real" worktree list --porcelain 2>/dev/null | awk -v worktree="$wt_real" '
    $1 == "worktree" && substr($0, 10) == worktree { matches += 1 }
    END { exit matches == 1 ? 0 : 1 }
  ' || return 1
  branch=$(git -C "$wt_real" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  default=$(default_branch "$project_real" 2>/dev/null || true)
  case "$branch" in ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  [ -n "$default" ] && [ "$branch" != "$default" ] || return 1
  FM_SPAWN_RECOVERY_PROJECT=$project_real
  FM_SPAWN_RECOVERY_WORKTREE=$wt_real
  FM_SPAWN_RECOVERY_BRANCH=$branch
}

fm_spawn_recovery_validate_lease() { # <project> <worktree> <task-id>
  local project=$1 worktree=$2 id=$3 inventory
  inventory=$(cd "$project" && "$SCRIPT_DIR/fm-treehouse-command.sh" status --json 2>/dev/null) || return 1
  printf '%s\n' "$inventory" | jq -e --arg path "$worktree" --arg holder "fm-$id" '
    [ .[] | select(.path == $path) ] as $slots
    | ($slots | length) == 1
    and $slots[0].status == "leased"
    and $slots[0].lease_holder == $holder
    and (($slots[0].lease_id // "") | type == "string" and length > 0)
  ' >/dev/null 2>&1
}

fm_spawn_recovery_select_session() { # <tasktmp> <task-id>
  local tasktmp=$1 id=$2 session_dir candidate_count candidate
  local -a candidates=()
  [ "${SPAWN_TASK_LOCK_HELD:-0}" = 1 ] \
    || [ "${FM_SPAWN_RECOVERY_PREFLIGHT_ONLY:-0}" = 1 ] \
    || return 1
  FM_SPAWN_RECOVERY_SESSION_MODE=fresh
  FM_SPAWN_RECOVERY_SESSION_DIR="$tasktmp/omp-sessions"
  FM_SPAWN_RECOVERY_RESUME_FILE=
  FM_SPAWN_RECOVERY_FRESH_SESSION_FILE=
  FM_SPAWN_RECOVERY_SESSION_DIR_CREATED=0
  FM_SPAWN_RECOVERY_TASKTMP_CREATED=0
  FM_SPAWN_RECOVERY_SESSION_DIR_WAS_EMPTY=0
  if [ ! -e "$tasktmp" ] && [ ! -L "$tasktmp" ]; then
    FM_SPAWN_RECOVERY_TASKTMP_CREATED=1
    return 0
  fi
  [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] || return 1
  session_dir=$FM_SPAWN_RECOVERY_SESSION_DIR
  if [ ! -e "$session_dir" ] && [ ! -L "$session_dir" ]; then
    FM_SPAWN_RECOVERY_SESSION_DIR_CREATED=1
    return 0
  fi
  [ -d "$session_dir" ] && [ ! -L "$session_dir" ] \
    && [ -r "$session_dir" ] && [ -x "$session_dir" ] || return 1
  mapfile -t candidates < <(
    shopt -s nullglob
    for candidate in "$session_dir"/*.jsonl; do
      printf '%s\n' "$candidate"
    done
  )
  candidate_count=${#candidates[@]}
  case "$candidate_count" in
    0)
      FM_SPAWN_RECOVERY_SESSION_DIR_WAS_EMPTY=1
      return 0
      ;;
    1)
      candidate=${candidates[0]}
      [ "$(cd "$(dirname "$candidate")" && pwd -P)" = "$(cd "$session_dir" && pwd -P)" ] || return 1
      grep -Fq 'FIRSTMATE_OP: v1 launch-brief:' "$candidate" 2>/dev/null || return 1
      FM_SPAWN_RECOVERY_SESSION_MODE=resume
      FM_SPAWN_RECOVERY_RESUME_FILE=$candidate
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_spawn_recovery_backup_session() {
  local source dir mode
  source=${FM_SPAWN_RECOVERY_RESUME_FILE:-}
  FM_SPAWN_RECOVERY_SESSION_BACKUP=
  [ "$FM_SPAWN_RECOVERY_SESSION_MODE" = resume ] || return 0
  dir=$(dirname "$source")
  mode=$(stat -c %a "$source" 2>/dev/null || true)
  FM_SPAWN_RECOVERY_SESSION_BACKUP=$(mktemp "$dir/.fm-spawn-recovery-session.XXXXXX") || return 1
  cat -- "$source" > "$FM_SPAWN_RECOVERY_SESSION_BACKUP" || return 1
  [ -z "$mode" ] || chmod "$mode" "$FM_SPAWN_RECOVERY_SESSION_BACKUP" 2>/dev/null || true
}

fm_spawn_recovery_capture_fresh_session() {
  local session_dir=${FM_SPAWN_RECOVERY_SESSION_DIR:-} candidate_count candidate
  local -a candidates=()
  [ "${FM_SPAWN_RECOVERY_SESSION_MODE:-}" = fresh ] || return 0
  [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || return 0
  [ -r "$session_dir" ] && [ -x "$session_dir" ] || return 1
  mapfile -t candidates < <(
    shopt -s nullglob
    for candidate in "$session_dir"/*.jsonl; do
      printf '%s\n' "$candidate"
    done
  )
  candidate_count=${#candidates[@]}
  case "$candidate_count" in
    0) return 0 ;;
    1)
      candidate=${candidates[0]}
      [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
      [ "$(cd "$(dirname "$candidate")" && pwd -P)" = "$(cd "$session_dir" && pwd -P)" ] || return 1
      if [ -n "${FM_SPAWN_RECOVERY_FRESH_SESSION_FILE:-}" ] \
         && [ "$FM_SPAWN_RECOVERY_FRESH_SESSION_FILE" != "$candidate" ]; then
        return 1
      fi
      FM_SPAWN_RECOVERY_FRESH_SESSION_FILE=$candidate
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_spawn_recovery_prepare() { # <state> <data> <task-id>
  local state=$1 data=$2 id=$3 meta kind harness tasktmp model effort old_backend old_target endpoint_state
  local project worktree expected_tmp prewalk prewalk_count allow_extensions allow_count
  meta="$state/$id.meta"
  FM_SPAWN_RECOVERY_ACTIVE=1
  FM_SPAWN_RECOVERY_PUBLISHED=0
  FM_SPAWN_RECOVERY_ENDPOINT_CREATED=0
  FM_SPAWN_RECOVERY_CANDIDATE_META=
  FM_SPAWN_RECOVERY_META_SNAPSHOT=
  FM_SPAWN_RECOVERY_NOTE=
  FM_SPAWN_RECOVERY_EXTENSION=
  FM_SPAWN_RECOVERY_READY=
  FM_SPAWN_RECOVERY_STARTED=
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "error: OMP recovery requires regular recorded metadata for task $id; preserving task state" >&2
    return 1
  }
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  old_backend=$FM_BACKEND_VALIDATED_BACKEND
  old_target=$FM_BACKEND_VALIDATED_TARGET
  case "$old_backend" in tmux|herdr) ;; *) return 1 ;; esac
  FM_SPAWN_RECOVERY_HERDR_SESSION=
  FM_SPAWN_RECOVERY_HERDR_WORKSPACE_ID=
  FM_SPAWN_RECOVERY_HERDR_TAB_ID=
  FM_SPAWN_RECOVERY_HERDR_PANE_ID=
  if [ "$old_backend" = herdr ]; then
    FM_SPAWN_RECOVERY_HERDR_SESSION=$(fm_spawn_recovery_exact_meta_value "$meta" herdr_session) || return 1
    FM_SPAWN_RECOVERY_HERDR_WORKSPACE_ID=$(fm_spawn_recovery_exact_meta_value "$meta" herdr_workspace_id) || return 1
    FM_SPAWN_RECOVERY_HERDR_TAB_ID=$(fm_spawn_recovery_exact_meta_value "$meta" herdr_tab_id) || return 1
    FM_SPAWN_RECOVERY_HERDR_PANE_ID=$(fm_spawn_recovery_exact_meta_value "$meta" herdr_pane_id) || return 1
  fi
  kind=$(fm_spawn_recovery_exact_meta_value "$meta" kind 2>/dev/null || true)
  case "$kind" in ship|scout) ;; *) echo "error: OMP recovery refuses non-ordinary task kind=${kind:-unknown}; preserving task state" >&2; return 1 ;; esac
  harness=$(fm_spawn_recovery_exact_meta_value "$meta" harness 2>/dev/null || true)
  [ "$harness" = omp ] || { echo "error: ordinary-worker recovery supports only recorded harness=omp tasks; refusing before mutation" >&2; return 1; }
  fm_spawn_recovery_validate_delivery "$meta" "$kind" || {
    echo "error: OMP recovery found inconsistent recorded delivery identity for task $id; preserving task state" >&2
    return 1
  }
  FM_SPAWN_RECOVERY_MODE=
  FM_SPAWN_RECOVERY_YOLO=
  if [ "$kind" = ship ]; then
    FM_SPAWN_RECOVERY_MODE=$(fm_spawn_recovery_exact_meta_value "$meta" mode)
    FM_SPAWN_RECOVERY_YOLO=$(fm_spawn_recovery_exact_meta_value "$meta" yolo)
  fi
  project=$(fm_spawn_recovery_exact_meta_value "$meta" project 2>/dev/null || true)
  worktree=$(fm_spawn_recovery_exact_meta_value "$meta" worktree 2>/dev/null || true)
  fm_spawn_recovery_validate_worktree "$project" "$worktree" "$id" || {
    echo "error: OMP recovery could not bind task $id to one non-default branch in its recorded isolated worktree; preserving task state" >&2
    return 1
  }
  fm_spawn_recovery_validate_lease "$FM_SPAWN_RECOVERY_PROJECT" "$FM_SPAWN_RECOVERY_WORKTREE" "$id" || {
    echo "error: OMP recovery could not prove the recorded Treehouse lease belongs to task $id and its isolated worktree; preserving task state" >&2
    return 1
  }
  tasktmp=$(fm_spawn_recovery_exact_meta_value "$meta" tasktmp 2>/dev/null || true)
  expected_tmp="/tmp/fm-$id"
  [ "$tasktmp" = "$expected_tmp" ] || {
    echo "error: OMP recovery found an unexpected task temp root for $id; preserving task state" >&2
    return 1
  }
  model=$(fm_spawn_recovery_exact_meta_value "$meta" model 2>/dev/null || true)
  effort=$(fm_spawn_recovery_exact_meta_value "$meta" effort 2>/dev/null || true)
  [ -n "$model" ] && [ -n "$effort" ] || {
    echo "error: OMP recovery found incomplete recorded launch identity for task $id; preserving task state" >&2
    return 1
  }
  prewalk_count=$(fm_spawn_recovery_meta_count "$meta" prewalk_into)
  case "$prewalk_count" in
    0) prewalk= ;;
    1) prewalk=$(fm_spawn_recovery_exact_meta_value "$meta" prewalk_into 2>/dev/null || true) ;;
    *) prewalk=__ambiguous__ ;;
  esac
  case "$prewalk" in __ambiguous__|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  FM_SPAWN_RECOVERY_PREWALK_INTO=$prewalk
  allow_count=$(fm_spawn_recovery_meta_count "$meta" allow_project_omp_extensions)
  case "$allow_count" in
    0) allow_extensions=0 ;;
    1)
      allow_extensions=$(fm_spawn_recovery_exact_meta_value "$meta" allow_project_omp_extensions 2>/dev/null || true)
      [ "$allow_extensions" = 1 ] || return 1
      ;;
    *) return 1 ;;
  esac
  FM_SPAWN_RECOVERY_ALLOW_PROJECT_OMP_EXTENSIONS=$allow_extensions
  [ -f "$data/$id/brief.md" ] && [ ! -L "$data/$id/brief.md" ] || {
    echo "error: OMP recovery requires the preserved regular brief for task $id; preserving task state" >&2
    return 1
  }
  endpoint_state=$(fm_backend_agent_state "$old_backend" "$old_target" "$meta" 2>/dev/null || printf 'unreadable')
  case "$endpoint_state" in
    dead|missing) ;;
    alive|ambiguous|unreadable|unverified|*)
      echo "error: OMP recovery requires a definitely dead or missing endpoint for task $id (observed $endpoint_state); preserving task state" >&2
      return 1
      ;;
  esac
  FM_SPAWN_RECOVERY_ENDPOINT_STATE=$endpoint_state
  fm_spawn_recovery_select_session "$tasktmp" "$id" || {
    echo "error: OMP recovery could not select one exact prior task session for $id; preserving task state" >&2
    return 1
  }
  FM_SPAWN_RECOVERY_OMP_BIN=$(fm_spawn_recovery_exact_meta_value "$meta" omp_bin) || return 1
  FM_SPAWN_RECOVERY_OMP_BUN=$(fm_spawn_recovery_exact_meta_value "$meta" omp_bun) || return 1
  if [ "${FM_SPAWN_RECOVERY_PREFLIGHT_ONLY:-0}" = 1 ]; then
    return 0
  fi
  fm_spawn_recovery_backup_session || {
    echo "error: OMP recovery could not snapshot the exact prior session for task $id; preserving task state" >&2
    return 1
  }
  FM_SPAWN_RECOVERY_META_SNAPSHOT=$(mktemp "$state/.fm-spawn-recovery-meta.XXXXXX") || return 1
  cat -- "$meta" > "$FM_SPAWN_RECOVERY_META_SNAPSHOT" || return 1
  FM_SPAWN_RECOVERY_META=$meta
  FM_SPAWN_RECOVERY_OLD_BACKEND=$old_backend
  FM_SPAWN_RECOVERY_OLD_TARGET=$old_target
  FM_SPAWN_RECOVERY_KIND=$kind
  FM_SPAWN_RECOVERY_MODEL=$model
  FM_SPAWN_RECOVERY_EFFORT=$effort
  FM_SPAWN_RECOVERY_TASKTMP=$tasktmp
}

fm_spawn_recovery_preflight() { # <state> <data> <task-id>
  FM_SPAWN_RECOVERY_PREFLIGHT_ONLY=1
  if fm_spawn_recovery_prepare "$@"; then
    FM_SPAWN_RECOVERY_PREFLIGHT_ONLY=0
    return 0
  fi
  FM_SPAWN_RECOVERY_PREFLIGHT_ONLY=0
  return 1
}

fm_spawn_recovery_prepare_launch_artifacts() { # <state> <task-id> <brief>
  local state=$1 id=$2 brief=$3 old_umask
  old_umask=$(umask)
  umask 077
  FM_SPAWN_RECOVERY_NOTE=$(mktemp "$state/.fm-spawn-recovery-note.XXXXXX") || { umask "$old_umask"; return 1; }
  FM_SPAWN_RECOVERY_EXTENSION=$(mktemp "$state/.fm-spawn-recovery-ext.XXXXXX.ts") || { umask "$old_umask"; return 1; }
  FM_SPAWN_RECOVERY_READY=$(mktemp "$state/.fm-spawn-recovery-ready.XXXXXX") || { umask "$old_umask"; return 1; }
  FM_SPAWN_RECOVERY_STARTED=$(mktemp "$state/.fm-spawn-recovery-started.XXXXXX") || { umask "$old_umask"; return 1; }
  rm -f -- "$FM_SPAWN_RECOVERY_READY" "$FM_SPAWN_RECOVERY_STARTED"
  umask "$old_umask"
  cat -- "$brief" > "$FM_SPAWN_RECOVERY_NOTE" || return 1
  printf '\n\nRecovery continuation: Firstmate restarted this proven-dead OMP worker in the preserved isolated copy. Re-read the brief above, inspect the current branch and uncommitted work, then continue the task without resetting, checking out another branch, or discarding work.\n' >> "$FM_SPAWN_RECOVERY_NOTE" || return 1
}

fm_spawn_recovery_stage_candidate_meta() { # <state> <task-id> <backend> <target> <herdr-session> <herdr-workspace> <herdr-tab> <herdr-pane>
  local state=$1 id=$2 backend=$3 target=$4 session=$5 workspace=$6 tab=$7 pane=$8 tmp
  [ -n "${FM_SPAWN_RECOVERY_META_SNAPSHOT:-}" ] || return 1
  tmp=$(mktemp "$state/.fm-spawn-recovery-candidate.XXXXXX") || return 1
  if ! awk -v target="$target" -v id="$id" -v backend="$backend" \
      -v session="$session" -v workspace="$workspace" -v tab="$tab" -v pane="$pane" '
    /^window=/ { print "window=" target; next }
    /^endpoint_task_id=/ { print "endpoint_task_id=" id; next }
    /^backend=/ { if (backend != "tmux") print "backend=" backend; next }
    /^herdr_session=/ { if (backend == "herdr") print "herdr_session=" session; next }
    /^herdr_workspace_id=/ { if (backend == "herdr") print "herdr_workspace_id=" workspace; next }
    /^herdr_tab_id=/ { if (backend == "herdr") print "herdr_tab_id=" tab; next }
    /^herdr_pane_id=/ { if (backend == "herdr") print "herdr_pane_id=" pane; next }
    { print }
  ' "$FM_SPAWN_RECOVERY_META_SNAPSHOT" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_backend_validate_task_endpoint "$tmp" "$id" \
    || [ "$FM_BACKEND_VALIDATED_BACKEND" != "$backend" ] \
    || [ "$FM_BACKEND_VALIDATED_TARGET" != "$target" ]; then
    rm -f -- "$tmp"
    return 1
  fi
  FM_SPAWN_RECOVERY_CANDIDATE_META=$tmp
}

fm_spawn_recovery_publish_candidate() { # <state> <task-id> <backend> <target>
  local state=$1 id=$2 backend=$3 target=$4
  if [ -z "${FM_SPAWN_RECOVERY_CANDIDATE_META:-}" ] \
     || [ ! -f "$FM_SPAWN_RECOVERY_CANDIDATE_META" ] \
     || [ -z "${FM_SPAWN_RECOVERY_META_SNAPSHOT:-}" ] \
     || ! cmp -s "$FM_SPAWN_RECOVERY_META" "$FM_SPAWN_RECOVERY_META_SNAPSHOT"; then
    echo "error: OMP recovery metadata changed during replacement launch; preserving the prior durable record" >&2
    return 1
  fi
  if ! fm_backend_validate_task_endpoint "$FM_SPAWN_RECOVERY_CANDIDATE_META" "$id" \
     || [ "$FM_BACKEND_VALIDATED_BACKEND" != "$backend" ] \
     || [ "$FM_BACKEND_VALIDATED_TARGET" != "$target" ]; then
    echo "error: OMP recovery could not validate replacement endpoint metadata; preserving the prior durable record" >&2
    return 1
  fi
  mv -f -- "$FM_SPAWN_RECOVERY_CANDIDATE_META" "$state/$id.meta" || {
    echo "error: OMP recovery could not publish replacement endpoint metadata atomically; preserving the prior durable record" >&2
    return 1
  }
  FM_SPAWN_RECOVERY_CANDIDATE_META=
  FM_SPAWN_RECOVERY_PUBLISHED=1
}

fm_spawn_recovery_remove_fresh_session_artifacts() {
  local session_dir=${FM_SPAWN_RECOVERY_SESSION_DIR:-} tasktmp=${TASK_TMP:-} file
  [ "${FM_SPAWN_RECOVERY_SESSION_MODE:-}" = fresh ] || return 0
  file=${FM_SPAWN_RECOVERY_FRESH_SESSION_FILE:-}
  if [ -n "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] \
      && [ "$(cd "$(dirname "$file")" && pwd -P)" = "$(cd "$session_dir" && pwd -P)" ] \
      && rm -f -- "$file"
  fi
  if [ "${FM_SPAWN_RECOVERY_TASKTMP_CREATED:-0}" = 1 ]; then
    rmdir -- "$tasktmp/gotmp" 2>/dev/null || true
    rmdir -- "$session_dir" 2>/dev/null || true
    rmdir -- "$tasktmp" 2>/dev/null || true
    return 0
  fi
  if [ "${FM_SPAWN_RECOVERY_SESSION_DIR_CREATED:-0}" = 1 ]; then
    rmdir -- "$session_dir" 2>/dev/null || true
  fi
}

fm_spawn_recovery_cleanup_artifacts() {
  rm -f -- "${FM_SPAWN_RECOVERY_CANDIDATE_META:-}" \
    "${FM_SPAWN_RECOVERY_META_SNAPSHOT:-}" \
    "${FM_SPAWN_RECOVERY_NOTE:-}" \
    "${FM_SPAWN_RECOVERY_EXTENSION:-}" \
    "${FM_SPAWN_RECOVERY_READY:-}" \
    "${FM_SPAWN_RECOVERY_STARTED:-}"
  FM_SPAWN_RECOVERY_CANDIDATE_META=
  FM_SPAWN_RECOVERY_META_SNAPSHOT=
  FM_SPAWN_RECOVERY_NOTE=
  FM_SPAWN_RECOVERY_EXTENSION=
  FM_SPAWN_RECOVERY_READY=
  FM_SPAWN_RECOVERY_STARTED=
}

fm_spawn_recovery_complete() {
  [ "${FM_SPAWN_RECOVERY_PUBLISHED:-0}" = 1 ] || return 1
  rm -f -- "${FM_SPAWN_RECOVERY_SESSION_BACKUP:-}"
  FM_SPAWN_RECOVERY_SESSION_BACKUP=
  fm_spawn_recovery_cleanup_artifacts
}

fm_spawn_recovery_abort() { # <backend> <target>
  local backend=${1:-} target=${2:-} state
  [ "${FM_SPAWN_RECOVERY_ACTIVE:-0}" = 1 ] || return 0
  if [ "${FM_SPAWN_RECOVERY_PUBLISHED:-0}" = 1 ]; then
    rm -f -- "${FM_SPAWN_RECOVERY_SESSION_BACKUP:-}"
    FM_SPAWN_RECOVERY_SESSION_BACKUP=
    fm_spawn_recovery_cleanup_artifacts
    return 0
  fi
  if [ "${FM_SPAWN_RECOVERY_ENDPOINT_CREATED:-0}" = 1 ] \
     && [ -n "$backend" ] && [ -n "$target" ]; then
    # This target was either newly created after a missing endpoint or accepted
    # the replacement launch after a proven-dead endpoint. It is therefore
    # replacement-owned even when process identity sampling is unavailable.
    fm_backend_kill "$backend" "$target" || true
    state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
    if [ "$state" != missing ]; then
      echo "warning: OMP recovery could not prove its failed replacement endpoint stopped; preserving recovery artifacts and task state" >&2
      return 1
    fi
  fi
  if [ -n "${FM_SPAWN_RECOVERY_SESSION_BACKUP:-}" ]; then
    mv -f -- "$FM_SPAWN_RECOVERY_SESSION_BACKUP" "$FM_SPAWN_RECOVERY_RESUME_FILE" || {
      echo "warning: OMP recovery could not restore its exact prior session snapshot; preserving recovery artifacts and task state" >&2
      return 1
    }
    FM_SPAWN_RECOVERY_SESSION_BACKUP=
  else
    # The task lock and empty pre-launch session directory bind at most one
    # newly observed session file to this fresh replacement attempt.
    fm_spawn_recovery_capture_fresh_session || {
      echo "warning: OMP recovery could not identify one fresh failed-attempt session; preserving recovery artifacts and task state" >&2
      return 1
    }
    fm_spawn_recovery_remove_fresh_session_artifacts
  fi
  fm_spawn_recovery_cleanup_artifacts
}
