#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Promotion also installs the ship acceptance-criterion
# scaffold and evidence ledger before changing kind=, so every ship path reaches
# the same fail-closed completion gate. bin/fm-brief.sh's delivery renderer owns
# the per-mode worker contract reused here. Firstmate resolves the posture after
# reading the scout report (AGENTS.md section 7); this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Usage: fm-promote.sh <task-id> --mode <mode> --yolo <on|off> --criterion 'AC1: outcome' [--criterion ...]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
POS=()
CRITERIA=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
      criterion) CRITERIA+=("$a") ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    --criterion) want_value=criterion ;;
    --criterion=*) CRITERIA+=("${a#--criterion=}") ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> --criterion 'AC1: outcome' [--criterion ...]" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's merge authority, not a project lookup" >&2
  exit 1
}
[ "${#CRITERIA[@]}" -gt 0 ] || { echo "error: promotion requires at least one concrete --criterion 'AC1: outcome'" >&2; exit 1; }
for criterion in "${CRITERIA[@]}"; do
  case "$criterion" in *$'\n'*|*$'\r'*) echo "error: invalid promotion criterion" >&2; exit 1 ;; esac
done
CRITERIA_BLOCK=$(printf -- '- %s\n' "${CRITERIA[@]}")
if ! printf '# Acceptance criteria\n%s\n# End acceptance criteria\n' "$CRITERIA_BLOCK" \
  | "$FM_ROOT/bin/fm-receipt-check.sh" --parse-criteria - >/dev/null 2>&1; then
  echo "error: invalid promotion acceptance criteria" >&2
  exit 1
fi
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

"$FM_ROOT/bin/fm-guard.sh" || true
ID=${POS[0]}

absolute_lexical_path() {
  local path=$1 component normalized='' components=()
  case "$path" in
    *$'\n'*|*$'\r'*) return 1 ;;
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  IFS=/ read -r -a components <<< "$path"
  for component in "${components[@]}"; do
    case "$component" in
      ''|.) ;;
      ..) return 1 ;;
      *) normalized="$normalized/$component" ;;
    esac
  done
  [ -n "$normalized" ] || normalized=/
  printf '%s\n' "$normalized"
}
FM_HOME=$(absolute_lexical_path "$FM_HOME") \
  || { echo "error: Firstmate home path contains unsafe traversal" >&2; exit 1; }
STATE=$(absolute_lexical_path "$STATE") \
  || { echo "error: state path contains unsafe traversal" >&2; exit 1; }
DATA=$(absolute_lexical_path "$DATA") \
  || { echo "error: data path contains unsafe traversal" >&2; exit 1; }

exec env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  "$FM_ROOT/bin/fm-receipt-store.sh" "$ID" promote \
  "$SCRIPT_DIR/fm-promote-transaction.sh" "$ID" "$MODE" "$YOLO" "$CRITERIA_BLOCK"
