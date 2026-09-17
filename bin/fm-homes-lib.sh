#!/usr/bin/env bash
# shellcheck shell=bash
# Single owner for "which local Firstmate homes feed a cross-home record scan".
#
# Every destructive or hygiene path that must prove no task record in this or
# any registered local home names a given Treehouse pool slot walks the same
# set of state directories: the scanning home's own state/, the root home's
# state/, and every reachable registered local secondmate's state/. Keeping the
# walk here means fm-teardown.sh and fm-treehouse-sweep.sh cannot drift into two
# different definitions of "every registered home".

FM_HOMES_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_HOMES_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$FM_HOMES_LIB_DIR/fm-secondmate-registry-lib.sh"
unset FM_HOMES_LIB_DIR

canonical_existing_dir() {
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( cd "$target" && pwd -P )
}

collect_local_firstmate_states() {
  local record_state=$1 root home reg line child known existing i=0
  local -a homes
  TREEHOUSE_OWNER_STATES=("$record_state")
  root=$(fm_firstmate_root_home "$FM_HOME") || {
    echo "REFUSED: cannot resolve the root Firstmate home; nothing was changed" >&2
    return 1
  }
  homes=("$root")
  while [ "$i" -lt "${#homes[@]}" ]; do
    home=${homes[$i]}
    i=$((i + 1))
    known=0
    for existing in "${TREEHOUSE_OWNER_STATES[@]}"; do
      [ "$existing" != "$home/state" ] || known=1
    done
    [ "$known" = 1 ] || TREEHOUSE_OWNER_STATES+=("$home/state")
    reg="$home/data/secondmates.md"
    [ ! -e "$reg" ] && [ ! -L "$reg" ] && continue
    [ -f "$reg" ] && [ ! -L "$reg" ] || {
      echo "REFUSED: local Firstmate registry is unsafe at $reg; nothing was changed" >&2
      return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*)
          secondmate_registry_parse_line "$line" || {
            echo "REFUSED: malformed local Firstmate registry entry in $reg; nothing was changed" >&2
            return 1
          }
          [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
          child=$(canonical_existing_dir "$SECONDMATE_REGISTRY_HOME") || {
            echo "REFUSED: registered local Firstmate home is unavailable: $SECONDMATE_REGISTRY_HOME; nothing was changed" >&2
            return 1
          }
          known=0
          for existing in "${homes[@]}"; do
            [ "$existing" != "$child" ] || known=1
          done
          [ "$known" = 1 ] || homes+=("$child")
          ;;
      esac
    done < "$reg"
  done
}
