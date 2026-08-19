#!/usr/bin/env bash
# Verify the selected OMP executable has Firstmate's required lifecycle and exact process-ownership surface.
# Usage: fm-omp-capabilities.sh [--print-binary] [--require-max-time]
# Success is silent unless --print-binary prints the resolved executable path.
# Capability checks, rather than a semantic-version floor, own compatibility.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-omp-process-lib.sh
. "$SCRIPT_DIR/fm-omp-process-lib.sh"

PRINT_BINARY=0
REQUIRE_MAX_TIME=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print-binary) PRINT_BINARY=1 ;;
    --require-max-time) REQUIRE_MAX_TIME=1 ;;
    -h|--help)
      sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

binary=$(command -v omp 2>/dev/null || true)
if [ -z "$binary" ]; then
  echo "error: omp executable not found on PATH; install a capability-complete OMP build or select a different verified harness; selected omp never falls back to pi or another harness" >&2
  exit 1
fi
case "$binary" in
  /*) ;;
  *)
    dir=$(cd "$(dirname "$binary")" 2>/dev/null && pwd -P) || {
      echo "error: omp executable path cannot be resolved: $binary" >&2
      exit 1
    }
    binary="$dir/$(basename "$binary")"
    ;;
esac
if [ ! -x "$binary" ]; then
  echo "error: resolved omp executable is not runnable: $binary" >&2
  exit 1
fi

entrypoint=$(fm_omp_process_resolve_path "$binary") || {
  echo "error: omp executable path cannot be canonicalized: $binary" >&2
  exit 1
}
if ! fm_omp_process_launch_identity "$entrypoint" >/dev/null; then
  echo "error: omp entrypoint is neither a Bun script nor a standalone executable with a verifiable launch identity: $entrypoint" >&2
  exit 1
fi

if help=$("$binary" --help 2>&1); then
  :
else
  status=$?
  echo "error: omp capability check could not read '$binary --help' (exit $status); update or repair the selected OMP installation" >&2
  exit 1
fi

missing=
require_help_token() {
  local token=$1 label=$2
  printf '%s\n' "$help" | grep -F -- "$token" >/dev/null 2>&1 || missing="${missing}${missing:+, }$label"
}
require_help_token '--model=' '--model=<value>'
require_help_token '--thinking=' '--thinking=<value>'
require_help_token '--auto-approve' '--auto-approve'
require_help_token '--session-dir=' '--session-dir=<value>'
require_help_token '--extension=' '--extension=<value>'
require_help_token '--resume=' '--resume=<value>'
if [ "$REQUIRE_MAX_TIME" -eq 1 ]; then
  printf '%s\n' "$help" | grep -E -- '(^|[[:space:],])--max-time=' >/dev/null 2>&1 \
    || missing="${missing}${missing:+, }--max-time=<value>"
fi

if [ -n "$missing" ]; then
  echo "error: omp missing required capability(s): $missing; update OMP before selecting harness=omp" >&2
  exit 1
fi

[ "$PRINT_BINARY" -eq 0 ] || printf '%s\n' "$binary"
