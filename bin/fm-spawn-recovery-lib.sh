#!/usr/bin/env bash
# Guarded ordinary-worker OMP recovery support for bin/fm-spawn.sh.
# Usage: source bin/fm-spawn-recovery-lib.sh from bin/fm-spawn.sh.
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
  if fm_spawn_recovery_teardown_rollback_pending "$state" "$id"; then
    echo "error: OMP recovery found unfinished ordinary-session teardown rollback state for task $id; preserving task state" >&2
    return 1
  fi
  if fm_spawn_recovery_ref_rollback_pending "$state" "$id"; then
    echo "error: OMP recovery found unresolved branch rollback state for task $id; preserving task state" >&2
    return 1
  fi
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

fm_spawn_recovery_validate_worktree() { # <project> <worktree> <task-id> <expected-branch>
  local project=$1 worktree=$2 id=$3 expected_branch=$4 project_real wt_real wt_top branch default
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
  case "$branch$expected_branch" in ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
  [ -n "$default" ] && [ "$branch" != "$default" ] && [ "$branch" = "$expected_branch" ] || return 1
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

fm_spawn_recovery_collect_direct_sessions() { # <session-dir>
  local session_dir=$1 candidate nullglob_was_set=0
  FM_SPAWN_RECOVERY_DIRECT_SESSIONS=()
  [ -d "$session_dir" ] && [ ! -L "$session_dir" ] \
    && [ -r "$session_dir" ] && [ -x "$session_dir" ] || return 1
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  for candidate in "$session_dir"/*.jsonl; do
    if [ ! -f "$candidate" ] || [ -L "$candidate" ]; then
      [ "$nullglob_was_set" -eq 1 ] || shopt -u nullglob
      return 1
    fi
    FM_SPAWN_RECOVERY_DIRECT_SESSIONS+=("$candidate")
  done
  [ "$nullglob_was_set" -eq 1 ] || shopt -u nullglob
}

fm_spawn_recovery_select_session() { # <state> <tasktmp> <task-id>
  local state=$1 tasktmp=$2 id=$3 session_dir pointer legacy_dir gotmp candidate cleanup_guard
  state=$(cd "$state" 2>/dev/null && pwd -P) || return 1
  local -a candidates=()
  [ "${SPAWN_TASK_LOCK_HELD:-0}" = 1 ] \
    || [ "${FM_SPAWN_RECOVERY_PREFLIGHT_ONLY:-0}" = 1 ] \
    || return 1
  FM_SPAWN_RECOVERY_SESSION_MODE=fresh
  FM_SPAWN_RECOVERY_SESSION_DIR="$state/$id.omp-sessions"
  FM_SPAWN_RECOVERY_SESSION_POINTER="$state/$id.omp-session"
  FM_SPAWN_RECOVERY_RESUME_FILE=
  FM_SPAWN_RECOVERY_FRESH_SESSION_FILE=
  FM_SPAWN_RECOVERY_SESSION_DIR_CREATED=0
  FM_SPAWN_RECOVERY_TASKTMP_CREATED=0
  FM_SPAWN_RECOVERY_GOTMP_CREATED=0
  FM_SPAWN_RECOVERY_SESSION_DIR_WAS_EMPTY=0
  FM_SPAWN_RECOVERY_LEGACY_SESSION_FILE=
  FM_SPAWN_RECOVERY_LEGACY_SESSION_BOUND=0
  FM_SPAWN_RECOVERY_POINTER_BACKUP=
  FM_SPAWN_RECOVERY_POINTER_WAS_ABSENT=0
  session_dir=$FM_SPAWN_RECOVERY_SESSION_DIR
  pointer=$FM_SPAWN_RECOVERY_SESSION_POINTER
  cleanup_guard="$session_dir/.fm-spawn-recovery-cleanup-pending"
  legacy_dir="$tasktmp/omp-sessions"
  gotmp="$tasktmp/gotmp"
  if [ -e "$cleanup_guard" ] || [ -L "$cleanup_guard" ]; then
    [ -f "$cleanup_guard" ] && [ ! -L "$cleanup_guard" ] || return 1
    return 1
  fi
  if [ ! -e "$tasktmp" ] && [ ! -L "$tasktmp" ]; then
    FM_SPAWN_RECOVERY_TASKTMP_CREATED=1
    FM_SPAWN_RECOVERY_GOTMP_CREATED=1
  else
    [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] || return 1
    if [ ! -e "$gotmp" ] && [ ! -L "$gotmp" ]; then
      FM_SPAWN_RECOVERY_GOTMP_CREATED=1
    else
      [ -d "$gotmp" ] && [ ! -L "$gotmp" ] || return 1
    fi
  fi

  if [ -e "$pointer" ] || [ -L "$pointer" ]; then
    [ -f "$pointer" ] && [ ! -L "$pointer" ] \
      && [ "$(wc -l < "$pointer" 2>/dev/null | tr -d '[:space:]')" = 1 ] \
      && [ "$(tail -c 1 "$pointer" 2>/dev/null | od -An -tuC | tr -d '[:space:]')" = 10 ] || return 1
    [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || return 1
    IFS= read -r candidate < "$pointer" || candidate=
    case "$candidate" in "$session_dir"/*.jsonl) ;; *) return 1 ;; esac
    [ "$(cd "$(dirname "$candidate")" && pwd -P)" = "$(cd "$session_dir" && pwd -P)" ] \
      && [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    fm_spawn_recovery_collect_direct_sessions "$session_dir" || return 1
    FM_SPAWN_RECOVERY_SESSION_MODE=resume
    FM_SPAWN_RECOVERY_RESUME_FILE=$candidate
    return 0
  fi

  if [ -e "$session_dir" ] || [ -L "$session_dir" ]; then
    [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || return 1
    fm_spawn_recovery_collect_direct_sessions "$session_dir" || return 1
    candidates=("${FM_SPAWN_RECOVERY_DIRECT_SESSIONS[@]}")
    [ "${#candidates[@]}" -eq 0 ] || return 1
    FM_SPAWN_RECOVERY_SESSION_DIR_WAS_EMPTY=1
  else
    FM_SPAWN_RECOVERY_SESSION_DIR_CREATED=1
  fi

  if [ "$FM_SPAWN_RECOVERY_TASKTMP_CREATED" = 1 ]; then
    return 0
  fi
  [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] || return 1
  if [ ! -e "$legacy_dir" ] && [ ! -L "$legacy_dir" ]; then
    return 0
  fi
  [ -d "$legacy_dir" ] && [ ! -L "$legacy_dir" ] || return 1
  fm_spawn_recovery_collect_direct_sessions "$legacy_dir" || return 1
  candidates=("${FM_SPAWN_RECOVERY_DIRECT_SESSIONS[@]}")
  case "${#candidates[@]}" in
    0) return 0 ;;
    1)
      candidate=${candidates[0]}
      grep -Fq 'FIRSTMATE_OP: v1 launch-brief:' "$candidate" 2>/dev/null || return 1
      FM_SPAWN_RECOVERY_SESSION_MODE=resume
      FM_SPAWN_RECOVERY_LEGACY_SESSION_FILE=$candidate
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_spawn_recovery_teardown_rollback_pending() { # <state> <task-id>
  local state=$1 id=$2 archive nullglob_was_set=0
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  for archive in "$state/.fm-teardown-omp-state-$id."*.tar; do
    [ "$nullglob_was_set" -eq 1 ] || shopt -u nullglob
    return 0
  done
  [ "$nullglob_was_set" -eq 1 ] || shopt -u nullglob
  return 1
}

fm_spawn_recovery_ref_rollback_pending() { # <state> <task-id>
  local state=$1 id=$2 guard
  guard="$state/$id.omp-ref-rollback-pending"
  [ -f "$guard" ] && [ ! -L "$guard" ]
}

fm_spawn_recovery_bind_legacy_session() {
  local source=${FM_SPAWN_RECOVERY_LEGACY_SESSION_FILE:-} session_dir dest mode created=0
  [ -n "$source" ] || return 0
  session_dir=$FM_SPAWN_RECOVERY_SESSION_DIR
  if [ ! -e "$session_dir" ] && [ ! -L "$session_dir" ]; then
    mkdir -p "$session_dir" || return 1
    chmod 0700 "$session_dir" 2>/dev/null || true
    FM_SPAWN_RECOVERY_SESSION_DIR_CREATED=1
    created=1
  fi
  if [ ! -d "$session_dir" ] || [ -L "$session_dir" ]; then
    [ "$created" = 0 ] || rmdir -- "$session_dir" 2>/dev/null || true
    return 1
  fi
  dest="$session_dir/$(basename "$source")"
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    [ "$created" = 0 ] || rmdir -- "$session_dir" 2>/dev/null || true
    return 1
  fi
  mode=$(stat -c %a "$source" 2>/dev/null || true)
  if ! cat -- "$source" > "$dest"; then
    rm -f -- "$dest"
    [ "$created" = 0 ] || rmdir -- "$session_dir" 2>/dev/null || true
    return 1
  fi
  [ -z "$mode" ] || chmod "$mode" "$dest" 2>/dev/null || true
  FM_SPAWN_RECOVERY_RESUME_FILE=$dest
  FM_SPAWN_RECOVERY_LEGACY_SESSION_BOUND=1
}
fm_spawn_recovery_prepare_session_storage() {
  local session_dir=${FM_SPAWN_RECOVERY_SESSION_DIR:-}
  [ -n "$session_dir" ] || return 1
  fm_spawn_recovery_bind_legacy_session || return 1
  if [ ! -e "$session_dir" ] && [ ! -L "$session_dir" ]; then
    mkdir -p "$session_dir" || return 1
    chmod 0700 "$session_dir" 2>/dev/null || true
    FM_SPAWN_RECOVERY_SESSION_DIR_CREATED=1
  fi
  [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || return 1
}


fm_spawn_recovery_backup_session() {
  local source dir mode pointer pointer_backup session_backup
  source=${FM_SPAWN_RECOVERY_RESUME_FILE:-}
  pointer=${FM_SPAWN_RECOVERY_SESSION_POINTER:-}
  FM_SPAWN_RECOVERY_SESSION_BACKUP=
  [ -n "$pointer" ] || return 1
  if [ -e "$pointer" ] || [ -L "$pointer" ]; then
    [ -f "$pointer" ] && [ ! -L "$pointer" ] || return 1
    pointer_backup=$(mktemp "$(dirname "$pointer")/.fm-spawn-recovery-pointer.XXXXXX") || return 1
    if ! cat -- "$pointer" > "$pointer_backup"; then
      rm -f -- "$pointer_backup"
      return 1
    fi
    FM_SPAWN_RECOVERY_POINTER_BACKUP=$pointer_backup
  else
    FM_SPAWN_RECOVERY_POINTER_WAS_ABSENT=1
  fi
  [ "$FM_SPAWN_RECOVERY_SESSION_MODE" = resume ] || return 0
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  dir=$(dirname "$source")
  mode=$(stat -c %a "$source" 2>/dev/null || true)
  session_backup=$(mktemp "$dir/.fm-spawn-recovery-session.XXXXXX") || return 1
  if ! cat -- "$source" > "$session_backup"; then
    rm -f -- "$session_backup"
    return 1
  fi
  [ -z "$mode" ] || chmod "$mode" "$session_backup" 2>/dev/null || true
  FM_SPAWN_RECOVERY_SESSION_BACKUP=$session_backup
}

fm_spawn_recovery_capture_fresh_session() {
  local session_dir=${FM_SPAWN_RECOVERY_SESSION_DIR:-} candidate
  local -a candidates=()
  [ "${FM_SPAWN_RECOVERY_SESSION_MODE:-}" = fresh ] || return 0
  [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || return 0
  fm_spawn_recovery_collect_direct_sessions "$session_dir" || return 1
  candidates=("${FM_SPAWN_RECOVERY_DIRECT_SESSIONS[@]}")
  case "${#candidates[@]}" in
    0) return 0 ;;
    1)
      candidate=${candidates[0]}
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

fm_spawn_recovery_snapshot_worktree() {
  local tasktmp=${FM_SPAWN_RECOVERY_TASKTMP:-} worktree=${FM_SPAWN_RECOVERY_WORKTREE:-}
  local snapshot head branch_ref
  [ -n "$tasktmp" ] && [ -n "$worktree" ] || return 1
  [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  if [ "${FM_SPAWN_RECOVERY_TASKTMP_CREATED:-0}" = 1 ]; then
    [ ! -e "$tasktmp" ] && [ ! -L "$tasktmp" ] || return 1
    mkdir -m 700 -- "$tasktmp" || return 1
  else
    [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] || return 1
  fi
  snapshot=$(mktemp -d "$tasktmp/.fm-spawn-recovery-worktree.XXXXXX") || return 1
  head=$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null) || {
    rm -rf -- "$snapshot"
    return 1
  }
  branch_ref=$(git -C "$worktree" symbolic-ref -q HEAD 2>/dev/null) || {
    rm -rf -- "$snapshot"
    return 1
  }
  case "$branch_ref" in refs/heads/*) ;; *) rm -rf -- "$snapshot"; return 1 ;; esac
  if ! printf '%s\n' "$head" > "$snapshot/head"; then
    rm -rf -- "$snapshot"
    return 1
  fi
  if ! printf '%s\n' "$branch_ref" > "$snapshot/branch-ref"; then
    rm -rf -- "$snapshot"
    return 1
  fi
  if ! git -C "$worktree" for-each-ref --format='%(refname) %(objectname)' refs/heads > "$snapshot/branch-refs" \
     || [ ! -s "$snapshot/branch-refs" ]; then
    rm -rf -- "$snapshot"
    return 1
  fi
  if ! git -C "$worktree" diff --cached --binary > "$snapshot/index.patch"; then
    rm -rf -- "$snapshot"
    return 1
  fi
  if ! git -C "$worktree" diff --binary > "$snapshot/worktree.patch"; then
    rm -rf -- "$snapshot"
    return 1
  fi
  if ! (cd "$worktree" && tar --exclude=.git -cf "$snapshot/worktree.tar" .); then
    rm -rf -- "$snapshot"
    return 1
  fi
  FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT=$snapshot
}

fm_spawn_recovery_snapshot_branch_ref_value() { # <snapshot> <ref>
  awk -v ref="$2" '$1 == ref { count += 1; value = $2 } END { if (count == 1) print value; else exit 1 }' \
    "$1/branch-refs"
}

fm_spawn_recovery_branch_refs_unchanged() { # <snapshot> <worktree>
  local snapshot=$1 worktree=$2
  local ref object extra current_ref current_object saved
  while IFS=' ' read -r ref object extra; do
    current_object=$(git -C "$worktree" rev-parse --verify "$ref" 2>/dev/null || true)
    [ "$current_object" = "$object" ] || return 1
  done < "$snapshot/branch-refs"
  while IFS=' ' read -r current_ref current_object; do
    saved=$(fm_spawn_recovery_snapshot_branch_ref_value "$snapshot" "$current_ref" 2>/dev/null || true)
    [ "$saved" = "$current_object" ] || return 1
  done < <(git -C "$worktree" for-each-ref --format='%(refname) %(objectname)' refs/heads)
}

fm_spawn_recovery_validate_branch_refs() { # <snapshot> <worktree> <branch-ref> <head>
  local snapshot=$1 worktree=$2 branch_ref=$3 head=$4 ref object extra
  [ -f "$snapshot/branch-refs" ] && [ ! -L "$snapshot/branch-refs" ] || return 1
  grep -Fqx -- "$branch_ref $head" "$snapshot/branch-refs" || return 1
  while IFS=' ' read -r ref object extra; do
    [ -n "$ref" ] && [ -n "$object" ] && [ -z "$extra" ] || return 1
    git check-ref-format "$ref" || return 1
    case "$ref" in refs/heads/*) ;; *) return 1 ;; esac
    [ "$(git -C "$worktree" rev-parse --verify "$object^{commit}" 2>/dev/null || true)" = "$object" ] || return 1
  done < "$snapshot/branch-refs"
  fm_spawn_recovery_branch_refs_unchanged "$snapshot" "$worktree"
}

fm_spawn_recovery_snapshot_turnend() { # <state> <task-id>
  local state=$1 id=$2 turnend backup mode
  turnend="$state/$id.turn-ended"
  FM_SPAWN_RECOVERY_TURNEND=$turnend
  FM_SPAWN_RECOVERY_TURNEND_BACKUP=
  FM_SPAWN_RECOVERY_TURNEND_WAS_ABSENT=0
  if [ ! -e "$turnend" ] && [ ! -L "$turnend" ]; then
    FM_SPAWN_RECOVERY_TURNEND_WAS_ABSENT=1
    return 0
  fi
  [ -f "$turnend" ] && [ ! -L "$turnend" ] || return 1
  backup=$(mktemp "$state/.fm-spawn-recovery-turnend.XXXXXX") || return 1
  if ! cat -- "$turnend" > "$backup"; then
    rm -f -- "$backup"
    return 1
  fi
  mode=$(stat -c %a "$turnend" 2>/dev/null || true)
  [ -z "$mode" ] || chmod "$mode" "$backup" 2>/dev/null || true
  FM_SPAWN_RECOVERY_TURNEND_BACKUP=$backup
}

fm_spawn_recovery_restore_turnend() {
  local turnend=${FM_SPAWN_RECOVERY_TURNEND:-} backup=${FM_SPAWN_RECOVERY_TURNEND_BACKUP:-} staged
  [ -n "$turnend" ] || return 0
  if [ -n "$backup" ]; then
    [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
    staged=$(mktemp "$(dirname "$turnend")/.fm-spawn-recovery-turnend-restore.XXXXXX") || return 1
    if ! cat -- "$backup" > "$staged" || ! mv -f -- "$staged" "$turnend"; then
      rm -f -- "$staged"
      return 1
    fi
    return 0
  fi
  [ "${FM_SPAWN_RECOVERY_TURNEND_WAS_ABSENT:-0}" = 1 ] || return 1
  [ ! -L "$turnend" ] || return 1
  rm -f -- "$turnend"
}

fm_spawn_recovery_remove_turnend_backup() {
  local backup=${FM_SPAWN_RECOVERY_TURNEND_BACKUP:-}
  [ -n "$backup" ] || return 0
  [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
  rm -f -- "$backup" || return 1
  FM_SPAWN_RECOVERY_TURNEND_BACKUP=
}

fm_spawn_recovery_restore_worktree() {
  local snapshot=${FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT:-}
  local worktree=${FM_SPAWN_RECOVERY_WORKTREE:-} head branch_ref
  [ -n "$snapshot" ] || return 0
  [ -d "$snapshot" ] && [ ! -L "$snapshot" ] \
    && [ -f "$snapshot/head" ] && [ ! -L "$snapshot/head" ] \
    && [ -f "$snapshot/branch-ref" ] && [ ! -L "$snapshot/branch-ref" ] \
    && [ -f "$snapshot/branch-refs" ] && [ ! -L "$snapshot/branch-refs" ] \
    && [ -f "$snapshot/index.patch" ] && [ ! -L "$snapshot/index.patch" ] \
    && [ -f "$snapshot/worktree.patch" ] && [ ! -L "$snapshot/worktree.patch" ] \
    && [ -f "$snapshot/worktree.tar" ] && [ ! -L "$snapshot/worktree.tar" ] \
    && [ -d "$worktree" ] && [ ! -L "$worktree" ] || return 1
  IFS= read -r head < "$snapshot/head" || return 1
  IFS= read -r branch_ref < "$snapshot/branch-ref" || return 1
  case "$branch_ref" in refs/heads/*) ;; *) return 1 ;; esac
  [ "$(git -C "$worktree" rev-parse --verify "$head^{commit}" 2>/dev/null || true)" = "$head" ] || return 1
  if ! fm_spawn_recovery_validate_branch_refs "$snapshot" "$worktree" "$branch_ref" "$head"; then
    fm_spawn_recovery_mark_ref_rollback_pending || return 1
    return 1
  fi
  git -C "$worktree" read-tree --reset -u "$head" \
    && git -C "$worktree" clean -fdx >/dev/null \
    && { [ ! -s "$snapshot/index.patch" ] || git -C "$worktree" apply --index "$snapshot/index.patch"; } \
    && { [ ! -s "$snapshot/worktree.patch" ] || git -C "$worktree" apply "$snapshot/worktree.patch"; } \
    && tar -xf "$snapshot/worktree.tar" -C "$worktree" || return 1
  if ! fm_spawn_recovery_validate_branch_refs "$snapshot" "$worktree" "$branch_ref" "$head"; then
    fm_spawn_recovery_mark_ref_rollback_pending || return 1
    return 1
  fi
  rm -rf -- "$snapshot" || return 1
  FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT=
}

fm_spawn_recovery_mark_ref_rollback_pending() {
  local guard=${FM_SPAWN_RECOVERY_REF_ROLLBACK_GUARD:-} staged
  [ -n "$guard" ] || return 1
  staged=$(mktemp "$guard.XXXXXX") || return 1
  if ! printf '%s\n' pending > "$staged" || ! mv -f -- "$staged" "$guard"; then
    rm -f -- "$staged"
    return 1
  fi
}

fm_spawn_recovery_prepare() { # <state> <data> <task-id>
  local state=$1 data=$2 id=$3 meta kind harness tasktmp model effort old_backend old_target endpoint_state tmux_session
  local project worktree branch expected_tmp prewalk prewalk_count allow_extensions allow_count
  local traceparent traceparent_count
  meta="$state/$id.meta"
  FM_SPAWN_RECOVERY_ACTIVE=1
  FM_SPAWN_RECOVERY_PUBLISHED=0
  FM_SPAWN_RECOVERY_FINALIZED=0
  FM_SPAWN_RECOVERY_ENDPOINT_CREATED=0
  FM_SPAWN_RECOVERY_CANDIDATE_META=
  FM_SPAWN_RECOVERY_META_SNAPSHOT=
  FM_SPAWN_RECOVERY_NOTE=
  FM_SPAWN_RECOVERY_EXTENSION=
  FM_SPAWN_RECOVERY_READY=
  FM_SPAWN_RECOVERY_STARTED=
  FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT=
  FM_SPAWN_RECOVERY_TURNEND=
  FM_SPAWN_RECOVERY_TURNEND_BACKUP=
  FM_SPAWN_RECOVERY_TURNEND_WAS_ABSENT=0
  FM_SPAWN_RECOVERY_TOOL_GATE_DIR=
  FM_SPAWN_RECOVERY_TOOL_GATE_ACTIVE=
  FM_SPAWN_RECOVERY_REF_ROLLBACK_GUARD="$state/$id.omp-ref-rollback-pending"
  FM_SPAWN_RECOVERY_FINALIZATION_BACKUP=
  FM_SPAWN_RECOVERY_FINALIZATION_ARCHIVE=
  FM_SPAWN_RECOVERY_FINALIZATION_ORIGINAL=
  FM_SPAWN_RECOVERY_TRACEPARENT=
  FM_SPAWN_RECOVERY_TRACEPARENT_PRESENT=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "error: OMP recovery requires regular recorded metadata for task $id; preserving task state" >&2
    return 1
  }
  fm_backend_validate_task_endpoint "$meta" "$id" || return 1
  old_backend=$FM_BACKEND_VALIDATED_BACKEND
  old_target=$FM_BACKEND_VALIDATED_TARGET
  case "$old_backend" in tmux|herdr) ;; *) return 1 ;; esac
  FM_SPAWN_RECOVERY_TMUX_SESSION=
  if [ "$old_backend" = tmux ]; then
    case "$old_target" in
      *:*) tmux_session=${old_target%%:*} ;;
      *) return 1 ;;
    esac
    [ -n "$tmux_session" ] || return 1
    FM_SPAWN_RECOVERY_TMUX_SESSION=$tmux_session
  fi
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
  branch=$(fm_spawn_recovery_exact_meta_value "$meta" branch 2>/dev/null || true)
  fm_spawn_recovery_validate_worktree "$project" "$worktree" "$id" "$branch" || {
    echo "error: OMP recovery could not bind task $id to its exact recorded non-default branch in the isolated worktree; preserving task state" >&2
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
  traceparent_count=$(fm_spawn_recovery_meta_count "$meta" traceparent)
  case "$traceparent_count" in
    0) ;;
    1)
      traceparent=$(fm_spawn_recovery_exact_meta_value "$meta" traceparent 2>/dev/null || true)
      fm_trace_context_valid "$traceparent" || {
        echo "error: OMP recovery found an invalid recorded trace context for task $id; preserving task state" >&2
        return 1
      }
      FM_SPAWN_RECOVERY_TRACEPARENT=$traceparent
      FM_SPAWN_RECOVERY_TRACEPARENT_PRESENT=1
      ;;
    *)
      echo "error: OMP recovery found ambiguous recorded trace context for task $id; preserving task state" >&2
      return 1
      ;;
  esac
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
  if fm_spawn_recovery_teardown_rollback_pending "$state" "$id"; then
    echo "error: OMP recovery found unfinished ordinary-session teardown rollback state for task $id; preserving task state" >&2
    return 1
  fi
  fm_spawn_recovery_select_session "$state" "$tasktmp" "$id" || {
    echo "error: OMP recovery could not select one exact prior task session for $id; preserving task state" >&2
    return 1
  }
  FM_SPAWN_RECOVERY_OMP_BIN=$(fm_spawn_recovery_exact_meta_value "$meta" omp_bin) || return 1
  FM_SPAWN_RECOVERY_OMP_BUN=$(fm_spawn_recovery_exact_meta_value "$meta" omp_bun) || return 1
  if [ "${FM_SPAWN_RECOVERY_PREFLIGHT_ONLY:-0}" = 1 ]; then
    return 0
  fi
  fm_spawn_recovery_prepare_session_storage || {
    echo "error: OMP recovery could not prepare durable session storage for task $id; preserving task state" >&2
    return 1
  }
  fm_spawn_recovery_backup_session || {
    echo "error: OMP recovery could not snapshot the exact prior session for task $id; preserving task state" >&2
    return 1
  }
  FM_SPAWN_RECOVERY_META_SNAPSHOT=$(mktemp "$state/.fm-spawn-recovery-meta.XXXXXX") || return 1
  cat -- "$meta" > "$FM_SPAWN_RECOVERY_META_SNAPSHOT" || return 1
  FM_SPAWN_RECOVERY_TASKTMP=$tasktmp
  fm_spawn_recovery_snapshot_worktree || {
    echo "error: OMP recovery could not snapshot the preserved isolated worktree for task $id; preserving task state" >&2
    return 1
  }
  fm_spawn_recovery_snapshot_turnend "$state" "$id" || {
    echo "error: OMP recovery could not snapshot the preserved turn-end state for task $id; preserving task state" >&2
    return 1
  }
  FM_SPAWN_RECOVERY_META=$meta
  FM_SPAWN_RECOVERY_OLD_BACKEND=$old_backend
  FM_SPAWN_RECOVERY_OLD_TARGET=$old_target
  FM_SPAWN_RECOVERY_KIND=$kind
  FM_SPAWN_RECOVERY_MODEL=$model
  FM_SPAWN_RECOVERY_EFFORT=$effort
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

fm_spawn_recovery_prepare_launch_artifacts() { # <tasktmp> <task-id> <brief>
  local tasktmp=$1 id=$2 brief=$3 old_umask
  [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] || return 1
  old_umask=$(umask)
  umask 077
  FM_SPAWN_RECOVERY_NOTE=$(mktemp "$tasktmp/.fm-spawn-recovery-note.XXXXXX") || { umask "$old_umask"; return 1; }
  FM_SPAWN_RECOVERY_EXTENSION=$(mktemp "$tasktmp/.fm-spawn-recovery-ext.XXXXXX.ts") || { umask "$old_umask"; return 1; }
  FM_SPAWN_RECOVERY_READY=$(mktemp "$tasktmp/.fm-spawn-recovery-ready.XXXXXX") || { umask "$old_umask"; return 1; }
  FM_SPAWN_RECOVERY_STARTED=$(mktemp "$tasktmp/.fm-spawn-recovery-started.XXXXXX") || { umask "$old_umask"; return 1; }
  FM_SPAWN_RECOVERY_TOOL_GATE_DIR=$(mktemp -d "$tasktmp/.fm-spawn-recovery-tool.XXXXXX") || { umask "$old_umask"; return 1; }
  rm -f -- "$FM_SPAWN_RECOVERY_READY" "$FM_SPAWN_RECOVERY_STARTED"
  umask "$old_umask"
  FM_SPAWN_RECOVERY_TOOL_GATE_ACTIVE="$FM_SPAWN_RECOVERY_TOOL_GATE_DIR/active"
  printf '%s\n' pending > "$FM_SPAWN_RECOVERY_TOOL_GATE_ACTIVE" || return 1
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

fm_spawn_recovery_write_session_cleanup_guard() {
  local session_dir=${FM_SPAWN_RECOVERY_SESSION_DIR:-} guard tmp
  [ -d "$session_dir" ] && [ ! -L "$session_dir" ] || return 1
  guard="$session_dir/.fm-spawn-recovery-cleanup-pending"
  if [ -e "$guard" ] || [ -L "$guard" ]; then
    [ -f "$guard" ] && [ ! -L "$guard" ] || return 1
    return 0
  fi
  tmp=$(mktemp "$session_dir/.fm-spawn-recovery-cleanup-pending.XXXXXX") || return 1
  printf '%s\n' pending > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -- "$tmp" "$guard"
}

fm_spawn_recovery_clear_session_cleanup_guard() {
  local session_dir=${FM_SPAWN_RECOVERY_SESSION_DIR:-} guard
  guard="$session_dir/.fm-spawn-recovery-cleanup-pending"
  [ -e "$guard" ] || [ -L "$guard" ] || return 0
  [ -f "$guard" ] && [ ! -L "$guard" ] || return 1
  rm -f -- "$guard"
}

fm_spawn_recovery_remove_fresh_session_artifacts() {
  local session_dir=${FM_SPAWN_RECOVERY_SESSION_DIR:-} file quarantine
  [ "${FM_SPAWN_RECOVERY_SESSION_MODE:-}" = fresh ] || return 0
  file=${FM_SPAWN_RECOVERY_FRESH_SESSION_FILE:-}
  if [ -n "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] \
      && [ "$(cd "$(dirname "$file")" && pwd -P)" = "$(cd "$session_dir" && pwd -P)" ] || return 1
    if ! rm -f -- "$file"; then
      quarantine=$(mktemp "$(dirname "$file")/.fm-spawn-recovery-failed-session.XXXXXX") || return 1
      rm -f -- "$quarantine" || return 1
      mv -- "$file" "$quarantine" || return 1
      return 1
    fi
    [ ! -e "$file" ] && [ ! -L "$file" ] || return 1
  fi
}

fm_spawn_recovery_remove_replacement_scratch() {
  local tasktmp=${FM_SPAWN_RECOVERY_TASKTMP:-} gotmp
  case "${FM_SPAWN_RECOVERY_TASKTMP_CREATED:-0}:${FM_SPAWN_RECOVERY_GOTMP_CREATED:-0}" in
    1:*|*:1) ;;
    *) return 0 ;;
  esac
  [ -n "$tasktmp" ] || return 1
  gotmp="$tasktmp/gotmp"
  if [ "${FM_SPAWN_RECOVERY_GOTMP_CREATED:-0}" = 1 ]; then
    rm -rf -- "$gotmp" || return 1
  fi
  if [ "${FM_SPAWN_RECOVERY_TASKTMP_CREATED:-0}" = 1 ]; then
    rm -rf -- "$tasktmp" || return 1
  fi
}

fm_spawn_recovery_remove_legacy_session_binding() {
  local session_dir=${FM_SPAWN_RECOVERY_SESSION_DIR:-} file=${FM_SPAWN_RECOVERY_RESUME_FILE:-} quarantine
  [ "${FM_SPAWN_RECOVERY_LEGACY_SESSION_BOUND:-0}" = 1 ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] \
    && [ "$(cd "$(dirname "$file")" && pwd -P)" = "$(cd "$session_dir" && pwd -P)" ] || return 1
  if ! rm -f -- "$file"; then
    quarantine=$(mktemp "$(dirname "$file")/.fm-spawn-recovery-failed-session.XXXXXX") || return 1
    rm -f -- "$quarantine" || return 1
    mv -- "$file" "$quarantine" || return 1
    return 1
  fi
  [ ! -e "$file" ] && [ ! -L "$file" ] || return 1
}

fm_spawn_recovery_finish_session_cleanup() {
  local session_dir=${FM_SPAWN_RECOVERY_SESSION_DIR:-}
  if [ "${FM_SPAWN_RECOVERY_SESSION_DIR_CREATED:-0}" = 1 ]; then
    fm_spawn_recovery_clear_session_cleanup_guard || return 1
    if ! rmdir -- "$session_dir"; then
      fm_spawn_recovery_write_session_cleanup_guard || return 1
      return 1
    fi
    return 0
  fi
  fm_spawn_recovery_clear_session_cleanup_guard
}

fm_spawn_recovery_restore_pointer() {
  local pointer=${FM_SPAWN_RECOVERY_SESSION_POINTER:-} session_dir=${FM_SPAWN_RECOVERY_SESSION_DIR:-} value
  [ -n "$pointer" ] || return 1
  if [ -n "${FM_SPAWN_RECOVERY_POINTER_BACKUP:-}" ]; then
    mv -f -- "$FM_SPAWN_RECOVERY_POINTER_BACKUP" "$pointer" || return 1
    FM_SPAWN_RECOVERY_POINTER_BACKUP=
    return 0
  fi
  [ "${FM_SPAWN_RECOVERY_POINTER_WAS_ABSENT:-0}" = 1 ] || return 0
  if [ ! -e "$pointer" ] && [ ! -L "$pointer" ]; then
    return 0
  fi
  [ -f "$pointer" ] && [ ! -L "$pointer" ] \
    && [ "$(wc -l < "$pointer" 2>/dev/null | tr -d '[:space:]')" = 1 ] || return 1
  IFS= read -r value < "$pointer" || value=
  case "$value" in "$session_dir"/*.jsonl) ;; *) return 1 ;; esac
  rm -f -- "$pointer"
}

fm_spawn_recovery_remove_launch_artifacts() {
  [ "${FM_SPAWN_RECOVERY_TEST_FAIL_FINALIZATION:-0}" != 1 ] || return 1
  rm -f -- "${FM_SPAWN_RECOVERY_CANDIDATE_META:-}" \
    "${FM_SPAWN_RECOVERY_NOTE:-}" \
    "${FM_SPAWN_RECOVERY_EXTENSION:-}" \
    "${FM_SPAWN_RECOVERY_READY:-}" \
    "${FM_SPAWN_RECOVERY_STARTED:-}"
  [ ! -e "${FM_SPAWN_RECOVERY_CANDIDATE_META:-}" ] \
    && [ ! -e "${FM_SPAWN_RECOVERY_NOTE:-}" ] \
    && [ ! -e "${FM_SPAWN_RECOVERY_EXTENSION:-}" ] \
    && [ ! -e "${FM_SPAWN_RECOVERY_READY:-}" ] \
    && [ ! -e "${FM_SPAWN_RECOVERY_STARTED:-}" ] || return 1
  FM_SPAWN_RECOVERY_CANDIDATE_META=
  FM_SPAWN_RECOVERY_NOTE=
  FM_SPAWN_RECOVERY_EXTENSION=
  FM_SPAWN_RECOVERY_READY=
  FM_SPAWN_RECOVERY_STARTED=
}

fm_spawn_recovery_cleanup_artifacts() {
  fm_spawn_recovery_remove_launch_artifacts || return 1
  rm -f -- "${FM_SPAWN_RECOVERY_META_SNAPSHOT:-}"
  rm -f -- "${FM_SPAWN_RECOVERY_TURNEND_BACKUP:-}"
  if [ -n "${FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT:-}" ] \
     && [ -d "$FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT" ] \
     && [ ! -L "$FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT" ]; then
    rm -rf -- "$FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT"
  fi
  FM_SPAWN_RECOVERY_META_SNAPSHOT=
  FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT=
  FM_SPAWN_RECOVERY_TURNEND_BACKUP=
  if [ -n "${FM_SPAWN_RECOVERY_TOOL_GATE_DIR:-}" ] \
     && [ -d "$FM_SPAWN_RECOVERY_TOOL_GATE_DIR" ] \
     && [ ! -L "$FM_SPAWN_RECOVERY_TOOL_GATE_DIR" ]; then
    rm -rf -- "$FM_SPAWN_RECOVERY_TOOL_GATE_DIR"
  fi
  FM_SPAWN_RECOVERY_TOOL_GATE_DIR=
  FM_SPAWN_RECOVERY_TOOL_GATE_ACTIVE=
  if [ -n "${FM_SPAWN_RECOVERY_FINALIZATION_BACKUP:-}" ] \
     && [ -d "$FM_SPAWN_RECOVERY_FINALIZATION_BACKUP" ] \
     && [ ! -L "$FM_SPAWN_RECOVERY_FINALIZATION_BACKUP" ]; then
    rm -rf -- "$FM_SPAWN_RECOVERY_FINALIZATION_BACKUP" 2>/dev/null || true
  fi
  if [ -n "${FM_SPAWN_RECOVERY_FINALIZATION_ORIGINAL:-}" ] \
     && [ -d "$FM_SPAWN_RECOVERY_FINALIZATION_ORIGINAL" ] \
     && [ ! -L "$FM_SPAWN_RECOVERY_FINALIZATION_ORIGINAL" ]; then
    rm -rf -- "$FM_SPAWN_RECOVERY_FINALIZATION_ORIGINAL" 2>/dev/null || true
  fi
  rm -f -- "${FM_SPAWN_RECOVERY_FINALIZATION_ARCHIVE:-}" 2>/dev/null || true
  FM_SPAWN_RECOVERY_FINALIZATION_BACKUP=
  FM_SPAWN_RECOVERY_FINALIZATION_ARCHIVE=
  FM_SPAWN_RECOVERY_FINALIZATION_ORIGINAL=
}

fm_spawn_recovery_backup_finalization_state() {
  local tasktmp=${FM_SPAWN_RECOVERY_TASKTMP:-} backup
  [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] || return 1
  backup=$(mktemp -d "$tasktmp/.fm-spawn-recovery-finalize.XXXXXX") || return 1
  if [ -n "${FM_SPAWN_RECOVERY_SESSION_BACKUP:-}" ] \
     && ! cp -p -- "$FM_SPAWN_RECOVERY_SESSION_BACKUP" "$backup/session"; then
    rm -rf -- "$backup"
    return 1
  fi
  if [ -n "${FM_SPAWN_RECOVERY_POINTER_BACKUP:-}" ] \
     && ! cp -p -- "$FM_SPAWN_RECOVERY_POINTER_BACKUP" "$backup/pointer"; then
    rm -rf -- "$backup"
    return 1
  fi
  if [ -n "${FM_SPAWN_RECOVERY_META_SNAPSHOT:-}" ] \
     && ! cp -p -- "$FM_SPAWN_RECOVERY_META_SNAPSHOT" "$backup/meta"; then
    rm -rf -- "$backup"
    return 1
  fi
  if [ -n "${FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT:-}" ] \
     && ! cp -Rp -- "$FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT" "$backup/worktree"; then
    rm -rf -- "$backup"
    return 1
  fi
  if [ -n "${FM_SPAWN_RECOVERY_TURNEND_BACKUP:-}" ] \
     && ! cp -p -- "$FM_SPAWN_RECOVERY_TURNEND_BACKUP" "$backup/turnend"; then
    rm -rf -- "$backup"
    return 1
  fi
  FM_SPAWN_RECOVERY_FINALIZATION_BACKUP=$backup
}

fm_spawn_recovery_restore_finalization_state() {
  local backup=${FM_SPAWN_RECOVERY_FINALIZATION_BACKUP:-}
  [ -d "$backup" ] && [ ! -L "$backup" ] || return 1
  if [ -n "${FM_SPAWN_RECOVERY_SESSION_BACKUP:-}" ]; then
    [ -f "$backup/session" ] && [ ! -L "$backup/session" ] || return 1
    FM_SPAWN_RECOVERY_SESSION_BACKUP=$backup/session
  fi
  if [ -n "${FM_SPAWN_RECOVERY_POINTER_BACKUP:-}" ]; then
    [ -f "$backup/pointer" ] && [ ! -L "$backup/pointer" ] || return 1
    FM_SPAWN_RECOVERY_POINTER_BACKUP=$backup/pointer
  fi
  if [ -n "${FM_SPAWN_RECOVERY_META_SNAPSHOT:-}" ]; then
    [ -f "$backup/meta" ] && [ ! -L "$backup/meta" ] || return 1
    FM_SPAWN_RECOVERY_META_SNAPSHOT=$backup/meta
  fi
  if [ -n "${FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT:-}" ]; then
    [ -d "$backup/worktree" ] && [ ! -L "$backup/worktree" ] || return 1
    FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT=$backup/worktree
  fi
  if [ -n "${FM_SPAWN_RECOVERY_TURNEND_BACKUP:-}" ]; then
    [ -f "$backup/turnend" ] && [ ! -L "$backup/turnend" ] || return 1
    FM_SPAWN_RECOVERY_TURNEND_BACKUP=$backup/turnend
  fi
}

fm_spawn_recovery_archive_finalization_state() {
  local tasktmp=${FM_SPAWN_RECOVERY_TASKTMP:-} backup=${FM_SPAWN_RECOVERY_FINALIZATION_BACKUP:-} archive
  [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] \
    && [ -d "$backup" ] && [ ! -L "$backup" ] || return 1
  archive=$(mktemp "$tasktmp/.fm-spawn-recovery-finalize.XXXXXX.tar") || return 1
  tar -C "$backup" -cf "$archive" . || {
    rm -f -- "$archive"
    return 1
  }
  FM_SPAWN_RECOVERY_FINALIZATION_ARCHIVE=$archive
}

fm_spawn_recovery_restore_finalization_archive() {
  local tasktmp=${FM_SPAWN_RECOVERY_TASKTMP:-} archive=${FM_SPAWN_RECOVERY_FINALIZATION_ARCHIVE:-} backup
  [ -d "$tasktmp" ] && [ ! -L "$tasktmp" ] \
    && [ -f "$archive" ] && [ ! -L "$archive" ] || return 1
  backup=$(mktemp -d "$tasktmp/.fm-spawn-recovery-finalize-restore.XXXXXX") || return 1
  tar -xf "$archive" -C "$backup" || {
    rm -rf -- "$backup"
    return 1
  }
  FM_SPAWN_RECOVERY_FINALIZATION_ORIGINAL=${FM_SPAWN_RECOVERY_FINALIZATION_BACKUP:-}
  FM_SPAWN_RECOVERY_FINALIZATION_BACKUP=$backup
  fm_spawn_recovery_restore_finalization_state
}

fm_spawn_recovery_remove_rollback_artifacts() {
  [ "${FM_SPAWN_RECOVERY_TEST_FAIL_ROLLBACK_FINALIZATION:-0}" != 1 ] || return 1
  fm_spawn_recovery_backup_finalization_state || return 1
  if [ -n "${FM_SPAWN_RECOVERY_SESSION_BACKUP:-}" ] \
     && ! rm -f -- "$FM_SPAWN_RECOVERY_SESSION_BACKUP"; then
    fm_spawn_recovery_restore_finalization_state
    return 1
  fi
  if [ "${FM_SPAWN_RECOVERY_TEST_FAIL_PARTIAL_ROLLBACK_FINALIZATION:-0}" = 1 ]; then
    fm_spawn_recovery_restore_finalization_state
    return 1
  fi
  if [ -n "${FM_SPAWN_RECOVERY_POINTER_BACKUP:-}" ] \
     && ! rm -f -- "$FM_SPAWN_RECOVERY_POINTER_BACKUP"; then
    fm_spawn_recovery_restore_finalization_state
    return 1
  fi
  if [ -n "${FM_SPAWN_RECOVERY_META_SNAPSHOT:-}" ] \
     && ! rm -f -- "$FM_SPAWN_RECOVERY_META_SNAPSHOT"; then
    fm_spawn_recovery_restore_finalization_state
    return 1
  fi
  if [ -n "${FM_SPAWN_RECOVERY_TURNEND_BACKUP:-}" ] \
     && ! rm -f -- "$FM_SPAWN_RECOVERY_TURNEND_BACKUP"; then
    fm_spawn_recovery_restore_finalization_state
    return 1
  fi
  if [ -n "${FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT:-}" ] \
     && [ -d "$FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT" ] \
     && [ ! -L "$FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT" ]; then
    rm -rf -- "$FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT" || {
      fm_spawn_recovery_restore_finalization_state
      return 1
    }
  fi
  fm_spawn_recovery_restore_finalization_state || return 1
}

fm_spawn_recovery_complete() {
  [ "${FM_SPAWN_RECOVERY_PUBLISHED:-0}" = 1 ] || return 1
  fm_spawn_recovery_remove_launch_artifacts || return 1
  fm_spawn_recovery_remove_rollback_artifacts || return 1
  fm_spawn_recovery_archive_finalization_state || return 1
  if [ "${FM_SPAWN_RECOVERY_TEST_FAIL_GATE_RELEASE:-0}" = 1 ] \
     || { [ -n "${FM_SPAWN_RECOVERY_TOOL_GATE_ACTIVE:-}" ] \
          && ! rm -f -- "$FM_SPAWN_RECOVERY_TOOL_GATE_ACTIVE"; }; then
    return 1
  fi
  FM_SPAWN_RECOVERY_FINALIZED=1
  rm -rf -- "$FM_SPAWN_RECOVERY_FINALIZATION_BACKUP" 2>/dev/null || true
  if [ "${FM_SPAWN_RECOVERY_TEST_FAIL_FINALIZATION_ARCHIVE_DELETE:-0}" != 1 ]; then
    rm -f -- "$FM_SPAWN_RECOVERY_FINALIZATION_ARCHIVE" 2>/dev/null || true
  fi
  FM_SPAWN_RECOVERY_FINALIZATION_BACKUP=
  FM_SPAWN_RECOVERY_FINALIZATION_ARCHIVE=
  FM_SPAWN_RECOVERY_FINALIZATION_ORIGINAL=
  FM_SPAWN_RECOVERY_SESSION_BACKUP=
  FM_SPAWN_RECOVERY_POINTER_BACKUP=
  FM_SPAWN_RECOVERY_META_SNAPSHOT=
  FM_SPAWN_RECOVERY_WORKTREE_SNAPSHOT=
  FM_SPAWN_RECOVERY_TURNEND_BACKUP=
  FM_SPAWN_RECOVERY_TOOL_GATE_ACTIVE=
}

fm_spawn_recovery_abort() { # <backend> <target>
  local backend=${1:-} target=${2:-} state pointer_restored=0
  [ "${FM_SPAWN_RECOVERY_ACTIVE:-0}" = 1 ] || return 0
  if [ "${FM_SPAWN_RECOVERY_FINALIZED:-0}" = 1 ]; then
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
  fm_spawn_recovery_restore_worktree || {
    echo "warning: OMP recovery could not restore the preserved isolated worktree snapshot; preserving recovery artifacts and task state" >&2
    return 1
  }
  fm_spawn_recovery_restore_turnend || {
    echo "warning: OMP recovery could not restore its prior turn-end state; preserving recovery artifacts and task state" >&2
    return 1
  }
  if [ "${FM_SPAWN_RECOVERY_PUBLISHED:-0}" = 1 ]; then
    mv -f -- "$FM_SPAWN_RECOVERY_META_SNAPSHOT" "$FM_SPAWN_RECOVERY_META" || {
      echo "warning: OMP recovery could not restore its prior endpoint metadata; preserving recovery artifacts and task state" >&2
      return 1
    }
    FM_SPAWN_RECOVERY_META_SNAPSHOT=
    FM_SPAWN_RECOVERY_PUBLISHED=0
  fi
  if [ "${FM_SPAWN_RECOVERY_LEGACY_SESSION_BOUND:-0}" = 1 ]; then
    fm_spawn_recovery_write_session_cleanup_guard || {
      echo "warning: OMP recovery could not guard its failed legacy-session cleanup; preserving recovery artifacts and task state" >&2
      return 1
    }
    fm_spawn_recovery_restore_pointer || {
      echo "warning: OMP recovery could not restore its durable session pointer; preserving recovery artifacts and task state" >&2
      return 1
    }
    pointer_restored=1
    fm_spawn_recovery_remove_legacy_session_binding || {
      echo "warning: OMP recovery could not remove its failed legacy-session binding; preserving recovery artifacts and task state" >&2
      return 1
    }
    rm -f -- "${FM_SPAWN_RECOVERY_SESSION_BACKUP:-}" || {
      echo "warning: OMP recovery could not remove its failed legacy-session snapshot; preserving recovery artifacts and task state" >&2
      return 1
    }
    FM_SPAWN_RECOVERY_SESSION_BACKUP=
    fm_spawn_recovery_finish_session_cleanup || {
      echo "warning: OMP recovery could not remove its failed legacy-session directory; preserving recovery artifacts and task state" >&2
      return 1
    }
  elif [ -n "${FM_SPAWN_RECOVERY_SESSION_BACKUP:-}" ]; then
    mv -f -- "$FM_SPAWN_RECOVERY_SESSION_BACKUP" "$FM_SPAWN_RECOVERY_RESUME_FILE" || {
      echo "warning: OMP recovery could not restore its exact prior session snapshot; preserving recovery artifacts and task state" >&2
      return 1
    }
    FM_SPAWN_RECOVERY_SESSION_BACKUP=
  else
    fm_spawn_recovery_write_session_cleanup_guard || {
      echo "warning: OMP recovery could not guard its failed fresh-session cleanup; preserving recovery artifacts and task state" >&2
      return 1
    }
    fm_spawn_recovery_restore_pointer || {
      echo "warning: OMP recovery could not restore its durable session pointer; preserving recovery artifacts and task state" >&2
      return 1
    }
    pointer_restored=1
    fm_spawn_recovery_capture_fresh_session || {
      echo "warning: OMP recovery could not identify one fresh failed-attempt session; preserving recovery artifacts and task state" >&2
      return 1
    }
    fm_spawn_recovery_remove_fresh_session_artifacts || {
      echo "warning: OMP recovery could not remove its failed fresh session; preserving recovery artifacts and task state" >&2
      return 1
    }
    fm_spawn_recovery_finish_session_cleanup || {
      echo "warning: OMP recovery could not remove its failed fresh-session directory; preserving recovery artifacts and task state" >&2
      return 1
    }
  fi
  if [ "$pointer_restored" = 0 ]; then
    fm_spawn_recovery_restore_pointer || {
      echo "warning: OMP recovery could not restore its durable session pointer; preserving recovery artifacts and task state" >&2
      return 1
    }
  fi
  fm_spawn_recovery_remove_replacement_scratch || {
    echo "warning: OMP recovery could not remove its replacement scratch; preserving recovery artifacts and task state" >&2
    return 1
  }
  fm_spawn_recovery_remove_turnend_backup || {
    echo "warning: OMP recovery could not retire its turn-end rollback backup; preserving recovery artifacts and task state" >&2
    return 1
  }
  fm_spawn_recovery_cleanup_artifacts
}
