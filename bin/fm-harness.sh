#!/usr/bin/env bash
# Detect the agent harness this process tree runs on.
# Usage: fm-harness.sh                  print own harness: claude|codex|opencode|pi|pi-signed|omp|grok|kimi|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; "default" resolves to own)
#        fm-harness.sh secondmate       print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> own. "default" or absent
#                                        defers to the crew resolution, so an unset
#                                        secondmate-harness behaves exactly as the crew
#                                        harness did before this knob existed.
#        fm-harness.sh secondmate-model    print the optional MODEL token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh secondmate-effort   print the optional EFFORT token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh secondmate-fallback-harness
#                                        print the configured fallback harness,
#                                        or empty when absent/default.
#        fm-harness.sh secondmate-fallback-model
#                                        print the fallback MODEL token, or empty.
#        fm-harness.sh secondmate-fallback-effort
#                                        print the fallback EFFORT token, or empty.
#        fm-harness.sh crew-fallback-profile
#                                        validate and print the complete fallback profile.
# config/secondmate-harness and config/secondmate-harness-fallback each use the
# same single-line "<harness> [<model>] [<effort>]" parser, while the fallback
# accessors read only the fallback file.
# Detection layers: verified environment markers first, then process ancestry.
# Record each newly verified env marker here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-omp-process-lib.sh
. "$SCRIPT_DIR/fm-omp-process-lib.sh"

# OMP ancestry probe. Innermost wins, exactly like the layer-2 walk below: the
# moment a nearer ancestor is itself a harness process, this stops and reports
# no match, so a foreign harness nested inside an OMP tree (an agent started
# from OMP's bash tool) keeps its own identity instead of inheriting the OMP
# marker from further up the chain.
# Two evidence modes. `exact` requires the launch-bound runtime and OMP realpaths
# published by the native primary (env pair or the loaded marker bound to the
# PID); standalone OMP publishes the same executable in both paths.
# `launch-shape` proves only that the innermost harness ancestor is a legacy
# Bun-script OMP process launched the way firstmate launches one - an absolute
# Bun executable followed by an absolute `omp` entrypoint - which is the evidence
# a spawned OMP worker's own tree carries; it never runs on its own, only to
# qualify the inherited FM_OMP_HARNESS launch-boundary marker.
omp_launch_argv_shape() {  # <args>
  local first second rest bun_path omp_path
  read -r first second rest <<EOF
$1
EOF
  [ -n "${first:-}" ] && [ -n "${second:-}" ] || return 1
  case "$first" in /*) ;; *) return 1 ;; esac
  case "$second" in */omp) ;; *) return 1 ;; esac
  [ "$(basename -- "$first")" = bun ] || return 1
  bun_path=$(fm_omp_process_resolve_path "$first") || return 1
  omp_path=$(fm_omp_process_resolve_path "$second") || return 1
  fm_omp_process_identity_path_valid "$bun_path" \
    && fm_omp_process_identity_path_valid "$omp_path"
}

omp_ancestry_matches() {  # <exact|launch-shape>
  local mode=$1 pid=$$ comm args bc
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    bc=$(basename -- "$comm")
    if [ "$mode" = exact ]; then
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      fm_omp_process_matches "$comm" "$args" "$pid" && return 0
    fi
    case "$bc" in
      bun|omp|cli.js)
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        [ "$mode" = launch-shape ] && omp_launch_argv_shape "$args" && return 0
        ;;
      *claude*|*codex*|*opencode*|*grok*|kimi|pi|pi-signed) return 1 ;;
      node*|python*)
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*|*codex*|*opencode*|*grok*|*" pi "*|*/pi) return 1 ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# The exact walk is skipped outright when this home holds no OMP identity
# evidence, so non-OMP harnesses pay no ps forks on this frequently called path.
omp_ancestry_is_exact() {
  if [ -n "${FM_OMP_BUN:-}" ] && [ -n "${FM_OMP_BIN:-}" ]; then
    FM_OMP_PROCESS_EXPECTED_BUN="$FM_OMP_BUN" \
      FM_OMP_PROCESS_EXPECTED_BIN="$FM_OMP_BIN" \
      omp_ancestry_matches exact
    return
  fi
  fm_omp_process_identity_available || return 1
  omp_ancestry_matches exact
}

detect_own() {
  # Layer 1: environment markers for verified harnesses.
  # Keep marker detection before the layer-2 command-name walk as an explicit
  # precedence rule. The single exception is the exact-OMP ancestry probe, which
  # runs first because an OMP session carries inherited foreign markers of its
  # own; it is bounded to the innermost harness ancestor, so it can only claim a
  # process that has no nearer harness of another identity above it.
  # Only claude, pi, and grok set verified markers of their own; Firstmate adds
  # the exact FM_OMP_HARNESS=omp marker at a verified OMP worker launch boundary.
  # That marker is a command-prefix assignment, so every descendant of an OMP
  # worker inherits it, including a foreign harness started from the worker's
  # bash tool. It therefore never claims a process on its own: it is qualified
  # by the same innermost-harness walk, so a nested claude/codex keeps its own
  # identity while a genuine OMP worker still outranks inherited foreign markers.
  # Codex, OpenCode, and Kimi are markerless, so a foreign marker retained in a terminal
  # multiplexer's stored environment can silently misidentify one of them before
  # ancestry is consulted. This is a precedence hazard, not evidence that
  # CLAUDECODE inheritance into a kimi child was observed; it was not observed.
  if [ "${FM_OMP_HARNESS:-}" = "omp" ]; then
    omp_ancestry_is_exact && { echo omp; return; }
    if [ -z "${FM_OMP_BUN:-}" ] && [ -z "${FM_OMP_BIN:-}" ]; then
      omp_ancestry_matches launch-shape && { echo omp; return; }
    fi
  fi
  omp_ancestry_is_exact && { echo omp; return; }
  [ "${CLAUDECODE:-}" = "1" ] && { echo claude; return; }
  if [ "${PI_CODING_AGENT:-}" = "true" ]; then
    if [ "${FM_PI_HARNESS:-}" = pi-signed ]; then echo pi-signed; else echo pi; fi
    return
  fi
  # grok sets GROK_AGENT=1 for its child/tool processes (verified, grok 0.2.73).
  # It does NOT set CLAUDECODE despite being Claude-Code-compatible, so this marker
  # is unambiguous when firstmate runs natively on grok.
  [ "${GROK_AGENT:-}" = "1" ] && { echo grok; return; }
  # Layer 2: walk the parent chain and match the command name.
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "$(basename -- "$comm")" in
      *claude*) echo claude; return ;;
      *codex*) echo codex; return ;;
      *opencode*) echo opencode; return ;;
      *grok*) echo grok; return ;;
      kimi) echo kimi; return ;;
      pi-signed) echo pi; return ;;
      pi) echo pi; return ;;
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        case "$args" in
          *claude*) echo claude; return ;;
          *codex*) echo codex; return ;;
          *opencode*) echo opencode; return ;;
          *grok*) echo grok; return ;;
          *" pi "*|*/pi) echo pi; return ;;
        esac ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      break
    fi
  done
  echo unknown
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name) wins; absent or "default" mirrors firstmate's own harness.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then detect_own; else echo "$crew"; fi
}

# Print the first non-empty, non-comment line of a configured profile file,
# trimming leading/trailing whitespace. An absent file or one holding only
# blank/comment lines produces no output.
configured_profile_line() {
  local file=$1 line
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$file"
}

# Print the first non-empty, non-comment line of config/secondmate-harness.
secondmate_line() {
  configured_profile_line "$CONFIG/secondmate-harness"
}

# Print the first non-empty, non-comment line of
# config/secondmate-harness-fallback.
secondmate_fallback_line() {
  configured_profile_line "$CONFIG/secondmate-harness-fallback"
}

crew_fallback_line() {
  configured_profile_line "$CONFIG/crew-harness-fallback"
}

crew_fallback_profile() {
  local line harness model effort
  local -a fields
  line=$(crew_fallback_line)
  [ -n "$line" ] || return 0
  read -r -a fields <<< "$line"
  [ "${#fields[@]}" -le 3 ] || {
    printf 'error: config/crew-harness-fallback must contain at most <harness> [<model>] [<effort>]\n' >&2
    return 1
  }
  harness=${fields[0]:-}
  model=${fields[1]:--}
  effort=${fields[2]:--}
  case "$effort" in
    -|low|medium|high|xhigh|max) ;;
    *)
      printf "error: config/crew-harness-fallback effort token '%s' is invalid\n" "$effort" >&2
      return 1
      ;;
  esac
  [ "$harness" != default ] || return 0
  printf '%s\t%s\t%s\n' "$harness" "$model" "$effort"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort)
# from a configured profile line, or nothing when that field is absent.
configured_profile_field() {
  local line=$1 idx=$2
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort)
# of the resolved secondmate_line, or nothing if the line or that field is absent.
secondmate_field() {
  configured_profile_field "$(secondmate_line)" "$1"
}

# Print the 1-based whitespace-separated token from the fallback profile only.
secondmate_fallback_field() {
  configured_profile_field "$(secondmate_fallback_line)" "$1"
}

secondmate_fallback_harness() {
  local sm
  sm=$(secondmate_fallback_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  printf '%s\n' "$sm"
}

secondmate_fallback_model() {
  local sm
  sm=$(secondmate_fallback_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_fallback_field 2
}

secondmate_fallback_effort() {
  local sm
  sm=$(secondmate_fallback_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_fallback_field 3
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> own.
resolve_secondmate() {
  local sm
  sm=$(secondmate_field 1)
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; else echo "$sm"; fi
}

# Print the optional model token (2nd field) from config/secondmate-harness, or
# empty when the harness token is absent/"default" or no model token is present.
resolve_secondmate_model() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2
}

# Print the optional effort token (3rd field) from config/secondmate-harness.
resolve_secondmate_effort() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3
}

case "${1:-}" in
  crew) resolve_crew ;;
  secondmate) resolve_secondmate ;;
  secondmate-model) resolve_secondmate_model ;;
  secondmate-effort) resolve_secondmate_effort ;;
  secondmate-fallback-harness) secondmate_fallback_harness ;;
  secondmate-fallback-model) secondmate_fallback_model ;;
  secondmate-fallback-effort) secondmate_fallback_effort ;;
  crew-fallback-profile) crew_fallback_profile ;;
  *) detect_own ;;
esac
