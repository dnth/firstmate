#!/usr/bin/env bash
# fm-runpod-lib.sh - the dependency-free RunPod placement predicate.
#
# Source this file and call:
#   fm_runpod_meta_path <data-dir> <secondmate-id>
#   fm_runpod_field <data-dir> <secondmate-id> <key>
#   fm_runpod_lifecycle <data-dir> <secondmate-id>
#   fm_runpod_is_managed <data-dir> <secondmate-id>
#   fm_runpod_is_dormant <data-dir> <secondmate-id>
#   fm_runpod_lifecycle_lock_path <state-dir> <secondmate-id>
#
# bin/fm-runpod.sh owns the record format, every lifecycle transition, and every
# RunPod call; this file is only the cheap read side that supervision, routing,
# and delivery need before deciding whether a route has a host to reach at all.
# It deliberately sources nothing, so a hot path can load it without pulling in
# the backend, lock, or registry libraries.
#
# Lifecycle values, written only by bin/fm-runpod.sh:
#   provisioned - the volume exists and no pod has ever been created.
#   waking      - a locked wake is creating or verifying the pod right now.
#   ready       - a pod is up, its endpoint is recorded, and SSH answered.
#   suspending  - a locked sleep is quiescing and terminating the pod.
#   suspended   - the pod is terminated on purpose and the volume is retained.
#
# fm_runpod_is_dormant is true for every state except ready, because none of the
# others has a host that can be reached right now. Probing one would report a
# broken route rather than the deliberate scale-to-zero state it actually is,
# and the correct response to needing that host is a wake, which serializes on
# the same lifecycle lock - so a route caught mid-wake, or left in waking by an
# interrupted one, converges instead of being reported as unreachable.
# An unrecognized value is NOT dormant: a corrupt record must surface as an
# ordinary route failure rather than silently creating compute in a loop.

fm_runpod_id_safe() {  # <secondmate-id>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_runpod_meta_path() {  # <data-dir> <secondmate-id>
  local data=${1:-} id=${2:-}
  [ -n "$data" ] || return 1
  fm_runpod_id_safe "$id" || return 1
  printf '%s/runpod/%s.meta\n' "$data" "$id"
}

# Exactly-one-match read, so a duplicated or absent key is an error rather than
# a silently chosen line.
fm_runpod_field() {  # <data-dir> <secondmate-id> <key>
  local path key=${3:-} count
  [ -n "$key" ] || return 1
  path=$(fm_runpod_meta_path "${1:-}" "${2:-}") || return 1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  count=$(grep -c "^$key=" "$path" 2>/dev/null || printf 0)
  [ "$count" = 1 ] || return 1
  sed -n "s/^$key=//p" "$path"
}

fm_runpod_is_managed() {  # <data-dir> <secondmate-id>
  local path
  path=$(fm_runpod_meta_path "${1:-}" "${2:-}") || return 1
  [ -f "$path" ] && [ ! -L "$path" ]
}

fm_runpod_lifecycle() {  # <data-dir> <secondmate-id>
  fm_runpod_field "${1:-}" "${2:-}" lifecycle 2>/dev/null || true
}

fm_runpod_is_dormant() {  # <data-dir> <secondmate-id>
  case "$(fm_runpod_lifecycle "${1:-}" "${2:-}")" in
    provisioned|waking|suspending|suspended) return 0 ;;
  esac
  return 1
}

fm_runpod_lifecycle_lock_path() {  # <state-dir> <secondmate-id>
  local state=${1:-} id=${2:-}
  [ -n "$state" ] || return 1
  fm_runpod_id_safe "$id" || return 1
  printf '%s/.runpod-lifecycle-%s.lock\n' "$state" "$id"
}
