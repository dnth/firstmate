#!/usr/bin/env bash
# Cheap compute placement facade. Provider records remain owned by each adapter.
# Duplicate claims count as managed/dormant to prevent remote probing; wake
# refuses the contradiction before any provider or remote operation.
# shellcheck source=bin/fm-runpod-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-runpod-lib.sh"
fm_boat_is_managed() {
  fm_runpod_id_safe "$2" || return 1
  [ -f "$1/boat/$2.meta" ] && [ ! -L "$1/boat/$2.meta" ]
}
fm_compute_provider() {
  local boat=0 runpod=0
  fm_boat_is_managed "$1" "$2" && boat=1
  fm_runpod_is_managed "$1" "$2" && runpod=1
  if [ "$boat" -eq 1 ] && [ "$runpod" -eq 1 ]; then
    printf 'error: contradictory Boat and RunPod ownership for %s\n' "$2" >&2
    return 2
  fi
  if [ "$boat" -eq 1 ]; then printf 'boat\n'; elif [ "$runpod" -eq 1 ]; then printf 'runpod\n'; else return 1; fi
}
fm_compute_is_managed() { fm_boat_is_managed "$1" "$2" || fm_runpod_is_managed "$1" "$2"; }
fm_compute_meta_path() {
  local provider
  provider=$(fm_compute_provider "$1" "$2") || return $?
  printf '%s/%s/%s.meta\n' "$1" "$provider" "$2"
}
fm_compute_field() {
  local provider count path
  provider=$(fm_compute_provider "$1" "$2") || return $?
  if [ "$provider" = runpod ]; then fm_runpod_field "$@"; return $?; fi
  path="$1/boat/$2.meta"
  count=$(grep -c "^$3=" "$path") || return 1
  [ "$count" = 1 ] || return 1
  sed -n "s/^$3=//p" "$path"
}
fm_compute_lifecycle() { fm_compute_field "$1" "$2" lifecycle; }
fm_compute_is_dormant() {
  local provider rc=0
  provider=$(fm_compute_provider "$1" "$2") || rc=$?
  [ "$rc" -ne 2 ] || return 0
  [ "$rc" -eq 0 ] || return 1
  if [ "$provider" = runpod ]; then fm_runpod_is_dormant "$@"; return $?; fi
  case "$(fm_compute_lifecycle "$1" "$2")" in provisioned|waking|suspending|suspended) return 0 ;; esac
  return 1
}
