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

# SWEEP_DIRS contains tab-separated "<state-dir><owner-label>" records.
# The empty owner label names the active home.
SWEEP_DIRS=""
SWEEP_SEEN=" "
SWEEP_UNREACHABLE=""

note_unreachable() {  # <owner-label> <reason>
  SWEEP_UNREACHABLE="$SWEEP_UNREACHABLE$1: $2
"
}

add_sweep_state() {  # <state-dir> <owner-label>
  local dir=$1 owner=$2 resolved
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
  case "$SWEEP_SEEN" in *" $resolved "*) return 0 ;; esac
  SWEEP_SEEN="$SWEEP_SEEN$resolved "
  SWEEP_DIRS="$SWEEP_DIRS$resolved	$owner
"
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
  local meta id home line
  SWEEP_DIRS=""
  SWEEP_SEEN=" "
  SWEEP_UNREACHABLE=""
  add_sweep_home "$FM_HOME" "" "$STATE"
  if [ -d "$STATE" ]; then
    for meta in "$STATE"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      if [ -L "$meta" ]; then
        note_unreachable "this home" "record $meta is not a plain file"
        continue
      fi
      [ -f "$meta" ] || continue
      meta_is_secondmate "$meta" || continue
      meta_is_remote_route "$meta" && continue
      id=$(basename "$meta" .meta)
      home=$(fm_meta_get "$meta" home)
      add_sweep_home "$home" "second mate $id's home"
    done
  fi
  if [ -f "$SECONDMATES_MD" ] && [ ! -L "$SECONDMATES_MD" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "- "*) ;; *) continue ;; esac
      if ! secondmate_registry_parse_line "$line"; then
        note_unreachable "the second mate registry" \
          "its entry \"$line\" could not be read"
        continue
      fi
      [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
      add_sweep_home "$SECONDMATE_REGISTRY_HOME" \
        "second mate $SECONDMATE_REGISTRY_ID's home"
    done < "$SECONDMATES_MD"
  elif [ -e "$SECONDMATES_MD" ] || [ -L "$SECONDMATES_MD" ]; then
    note_unreachable "the second mate registry" \
      "$SECONDMATES_MD is not a plain file"
  fi
}

BLOCK_KIND=""
BLOCK_WHAT=""

find_blocker() {
  local dir owner meta id class reason label out
  BLOCK_KIND=""
  BLOCK_WHAT=""
  while IFS=$'\t' read -r dir owner; do
    [ -n "$dir" ] || continue
    for meta in "$dir"/*.meta; do
      [ -e "$meta" ] || [ -L "$meta" ] || continue
      if [ -L "$meta" ]; then
        if [ -z "$BLOCK_KIND" ]; then
          BLOCK_KIND=unclassified
          BLOCK_WHAT="record $meta is not a plain file"
        fi
        continue
      fi
      [ -f "$meta" ] || continue
      meta_is_remote_route "$meta" && continue
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
  done <<EOF
$SWEEP_DIRS
EOF
  if [ -z "$BLOCK_KIND" ] && [ -n "$SWEEP_UNREACHABLE" ]; then
    BLOCK_KIND=unclassified
    BLOCK_WHAT=$(printf '%s' "$SWEEP_UNREACHABLE" | sed -n '1p')
  fi
  [ -n "$BLOCK_KIND" ]
}

gate_allows_update() {
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

after=$("$omp_path" --version 2>/dev/null) || {
  printf 'omp: could not read version after %s from %s\n' "$mode" "$omp_path" >&2
  exit 1
}
printf 'omp: after: %s\n' "$(first_line "$after")"
