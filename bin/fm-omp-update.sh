#!/usr/bin/env bash
# Update the machine-wide omp executable through omp's supported update path.
# Usage: fm-omp-update.sh [--check]
#
# A normal update replaces the executable used by every local Firstmate worker.
# It therefore proceeds only after the recovery-grade backend classifier proves
# that every recorded worker in this home and every registered local secondmate
# home has stopped.
# Remote secondmates run on another machine and are outside this local binary's
# update boundary.
# Any live or unclassifiable endpoint, unreadable local home, or unreadable
# registry fails closed.
# --check calls omp's detect-only update check without inspecting or changing
# fleet state.
# This script never forces an update and never manages the shared no-mistakes
# daemon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SECONDMATES_MD="$DATA/secondmates.md"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  printf '%s\n' 'usage: fm-omp-update.sh [--check]' >&2
}

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

meta_is_secondmate() {  # <meta-file>
  grep -qx 'kind=secondmate' "$1" 2>/dev/null
}

meta_is_remote_route() {  # <meta-file>
  grep -q '^remote_host=.' "$1" 2>/dev/null
}

# Print "<class> <reason>" for one durable endpoint record.
# The classes are stopped, running, and unclassified.
# Only the backend owner's recovery-grade dead and missing states prove that an
# executable swap cannot disrupt the recorded worker.
meta_endpoint_class() {  # <meta-file>
  local meta=$1 backend target verdict
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta" || true)
  if [ -z "$target" ]; then
    printf 'unclassified no endpoint is recorded'
    return 0
  fi
  verdict=$(fm_backend_agent_state "$backend" "$target" "$meta" 2>/dev/null || true)
  case "$verdict" in
    dead|missing) printf 'stopped %s' "$verdict" ;;
    alive) printf 'running alive' ;;
    *) printf 'unclassified its %s endpoint reads %s' "$backend" "${verdict:-nothing}" ;;
  esac
}

SWEEP_STATE_DIRS=()
SWEEP_META_PATHS=()
SWEEP_META_OWNERS=()
SWEEP_UNREACHABLE=""
GATE_TMP_ROOT=""
GATE_SEQUENCE=0
GATE_TMP_DIR=""

note_unreachable() {  # <owner-label> <reason>
  SWEEP_UNREACHABLE="$SWEEP_UNREACHABLE$1: $2
"
}

add_sweep_state() {  # <state-dir> <owner-label>
  local dir=$1 owner=$2 resolved seen meta index
  if [ ! -d "$dir" ]; then
    if [ -e "$dir" ] || [ -L "$dir" ]; then
      note_unreachable "${owner:-this home}" \
        "its local records at $dir are not a readable directory"
    fi
    return 0
  fi
  resolved=$(cd "$dir" 2>/dev/null && pwd -P) || {
    note_unreachable "${owner:-this home}" "its local records at $dir cannot be read"
    return 0
  }
  case "$resolved$owner" in
    *$'\t'*|*$'\n'*|*$'\r'*)
      note_unreachable "${owner:-this home}" \
        "its local records use an unsafe path"
      return 0
      ;;
  esac
  for seen in "${SWEEP_STATE_DIRS[@]}"; do
    [ "$seen" != "$resolved" ] || return 0
  done
  if ! command ls -A "$resolved" > /dev/null 2>&1; then
    note_unreachable "${owner:-this home}" \
      "its local records at $resolved cannot be enumerated"
    return 0
  fi
  SWEEP_STATE_DIRS[${#SWEEP_STATE_DIRS[@]}]=$resolved
  for meta in "$resolved"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    index=${#SWEEP_META_PATHS[@]}
    SWEEP_META_PATHS[index]=$meta
    SWEEP_META_OWNERS[index]=$owner
    if [ -L "$meta" ] || [ ! -f "$meta" ]; then
      note_unreachable "${owner:-this home}" "record $meta is not a plain file"
    fi
  done
}

add_sweep_home() {  # <home> <owner-label> [state-dir]
  local home=$1 owner=$2 state=${3:-} resolved
  case "$home" in
    /*) ;;
    *)
      note_unreachable "${owner:-this home}" \
        "its recorded location is not a usable path (${home:-empty})"
      return 0
      ;;
  esac
  resolved=$(cd "$home" 2>/dev/null && pwd -P) || {
    note_unreachable "${owner:-this home}" \
      "its recorded location $home is missing or cannot be read"
    return 0
  }
  add_sweep_state "${state:-$resolved/state}" "$owner"
}

collect_sweep_dirs() {
  local meta id home line endpoint index
  SWEEP_STATE_DIRS=()
  SWEEP_META_PATHS=()
  SWEEP_META_OWNERS=()
  SWEEP_UNREACHABLE=""
  add_sweep_home "$FM_HOME" "" "$STATE"
  for index in "${!SWEEP_META_PATHS[@]}"; do
    [ -z "${SWEEP_META_OWNERS[$index]}" ] || continue
    meta=${SWEEP_META_PATHS[$index]}
    if [ -f "$meta" ] && [ ! -L "$meta" ]; then
      meta_is_secondmate "$meta" || continue
      meta_is_remote_route "$meta" && continue
      id=$(basename "$meta" .meta)
      home=$(fm_meta_get "$meta" home)
      add_sweep_home "$home" "second mate $id's home"
    fi
  done
  if [ -f "$SECONDMATES_MD" ] && [ ! -L "$SECONDMATES_MD" ]; then
    if ! cat "$SECONDMATES_MD" > "$GATE_TMP_DIR/secondmates.md" 2>/dev/null; then
      note_unreachable "the second mate registry" \
        "$SECONDMATES_MD cannot be read"
      return 0
    fi
    if ! secondmate_registry_validate_bindings "$GATE_TMP_DIR/secondmates.md" \
      secondmate_registry_path_key; then
      note_unreachable "the second mate registry" "$SECONDMATE_REGISTRY_ERROR"
      return 0
    fi
  elif [ -e "$SECONDMATES_MD" ] || [ -L "$SECONDMATES_MD" ]; then
    note_unreachable "the second mate registry" \
      "$SECONDMATES_MD is not a plain file"
    return 0
  else
    return 0
  fi
  # shellcheck disable=SC2094 # Validation copies this read-only snapshot to a distinct temporary file.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    endpoint=$STATE/$id.meta
    if [ ! -f "$endpoint" ] || [ -L "$endpoint" ]; then
      note_unreachable "second mate $id" \
        "its registered local endpoint record $endpoint is unavailable or unsafe"
    elif ! meta_is_secondmate "$endpoint" || meta_is_remote_route "$endpoint"; then
      note_unreachable "second mate $id" \
        "its registered local endpoint record does not describe that local second mate"
    else
      if ! secondmate_registry_validate_bindings "$GATE_TMP_DIR/secondmates.md" \
        secondmate_registry_path_key "$id" "$(fm_meta_get "$endpoint" home)"; then
        note_unreachable "second mate $id" "$SECONDMATE_REGISTRY_ERROR"
      fi
    fi
    add_sweep_home "$home" "second mate $id's home"
  done < "$GATE_TMP_DIR/secondmates.md"
}

BLOCK_KIND=""
BLOCK_WHAT=""

find_blocker() {
  local owner meta id class reason label out index
  BLOCK_KIND=""
  BLOCK_WHAT=""
  for index in "${!SWEEP_META_PATHS[@]}"; do
    meta=${SWEEP_META_PATHS[$index]}
    owner=${SWEEP_META_OWNERS[$index]}
    if [ -L "$meta" ] || [ ! -f "$meta" ]; then
      if [ -z "$BLOCK_KIND" ]; then
        BLOCK_KIND=unclassified
        BLOCK_WHAT="record $meta is not a plain file"
      fi
      continue
    fi
    if meta_is_secondmate "$meta" && meta_is_remote_route "$meta"; then
      continue
    fi
    out=$(meta_endpoint_class "$meta" </dev/null)
    class=${out%% *}
    reason=${out#* }
    [ "$class" != stopped ] || continue
    id=$(basename "$meta" .meta)
    if meta_is_secondmate "$meta"; then
      label="second mate $id"
    else
      label="task $id"
    fi
    [ -z "$owner" ] || label="$label in $owner"
    if [ "$class" = running ]; then
      BLOCK_KIND=running
      BLOCK_WHAT=$label
      return 0
    fi
    if [ -z "$BLOCK_KIND" ]; then
      BLOCK_KIND=unclassified
      BLOCK_WHAT="$label: $reason"
    fi
  done
  if [ -z "$BLOCK_KIND" ] && [ -n "$SWEEP_UNREACHABLE" ]; then
    BLOCK_KIND=unclassified
    BLOCK_WHAT=$(printf '%s' "$SWEEP_UNREACHABLE" | sed -n '1p')
  fi
  [ -n "$BLOCK_KIND" ]
}

gate_allows_update() {
  GATE_SEQUENCE=$((GATE_SEQUENCE + 1))
  GATE_TMP_DIR=$GATE_TMP_ROOT/gate.$GATE_SEQUENCE
  mkdir "$GATE_TMP_DIR"
  collect_sweep_dirs
  find_blocker || return 0
  if [ "$BLOCK_KIND" = running ]; then
    printf 'omp: refused: a worker is still running (%s)\n' "$BLOCK_WHAT" >&2
  else
    printf 'omp: refused: could not confirm every worker has stopped (%s)\n' \
      "$BLOCK_WHAT" >&2
  fi
  return 1
}

mode=update
case "$#:${1:-}" in
  0:) ;;
  1:--check) mode=check ;;
  1:--help|1:-h) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac

omp_path=$(command -v omp 2>/dev/null) || {
  printf '%s\n' 'omp: unavailable on PATH' >&2
  exit 1
}
[ -x "$omp_path" ] || {
  printf 'omp: resolved executable is not runnable: %s\n' "$omp_path" >&2
  exit 1
}

before=$("$omp_path" --version 2>/dev/null) || {
  printf 'omp: could not read version from %s\n' "$omp_path" >&2
  exit 1
}
printf 'omp: channel: %s\n' "$omp_path"
printf 'omp: before: %s\n' "$(first_line "$before")"

if [ "$mode" = update ]; then
  GATE_TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-update.XXXXXX") || {
    printf '%s\n' 'omp: could not create fleet validation state' >&2
    exit 1
  }
  trap 'rm -rf -- "$GATE_TMP_ROOT"' EXIT
  gate_allows_update
  gate_allows_update
  if ! output=$("$omp_path" update 2>&1); then
    [ -z "$output" ] || printf '%s\n' "$output"
    printf '%s\n' 'omp: update failed' >&2
    exit 1
  fi
else
  if ! output=$("$omp_path" update --check 2>&1); then
    [ -z "$output" ] || printf '%s\n' "$output"
    printf '%s\n' 'omp: update check failed' >&2
    exit 1
  fi
fi
[ -z "$output" ] || printf '%s\n' "$output"

if [ "$mode" = update ]; then
  after=$("$omp_path" --version 2>/dev/null) || {
    printf 'omp: could not read version after %s from %s\n' "$mode" "$omp_path" >&2
    exit 1
  }
  printf 'omp: after: %s\n' "$(first_line "$after")"
fi
