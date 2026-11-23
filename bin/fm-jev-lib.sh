#!/usr/bin/env bash
# fm-jev-lib.sh - the one typesafe.ai System One (Jev) client for firstmate.
#
# Sourced by every firstmate caller that asks Jev a typed question, so the
# endpoint, model, timeout, opt-in gate, and transport live in one place:
#   bin/fm-dispatch-resolve.sh   dispatch-profile resolution
#   bin/fm-ext-thread-judge.sh   topic-thread status and name fit
#
# Opt-in gate (the one key-presence check): TYPESAFE_API_KEY non-empty in the
# caller's environment, else a non-empty TYPESAFE_API_KEY= value in
# $FM_HOME/.env read with fmx_env_get (bin/fm-env-lib.sh). The environment
# wins. Callers copy an environment key into the non-exported _FM_JEV_KEY and
# unset TYPESAFE_API_KEY before sourcing, so no child process inherits it.
# The key reaches curl through a header file descriptor, never argv.
#
# Defines:
#   FM_JEV_BASE      https://api.typesafe.ai
#   FM_JEV_MODEL     jev-latest
#   FM_JEV_TIMEOUT   5 seconds
#   fm_jev_load_key  read the home key if the caller captured no environment key
#   fm_jev_available true when a key is loaded
#   fm_jev_post <response-file>
#                    POST stdin as the JSON body and print
#                    "<http> <latency_ms>" (000 on a transport failure), for
#                    `read -r HTTP FM_JEV_LATENCY_MS <<< "$(fm_jev_post ...)"`.
#                    A non-200 body is left in response-file for the caller to
#                    report.
#
# Callers own their question shape and validate every answer field they
# consume; this library never interprets a response.
set -u

: "${FM_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${FM_HOME:=$FM_ROOT}"
[ -n "${FM_HOME:-}" ] || FM_HOME=$FM_ROOT

# shellcheck source=bin/fm-env-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-env-lib.sh"

FM_JEV_BASE=https://api.typesafe.ai
# shellcheck disable=SC2034  # read by sourcing callers
FM_JEV_MODEL=jev-latest
FM_JEV_TIMEOUT=5

fm_jev_load_key() {
  [ -n "${_FM_JEV_KEY:-}" ] || _FM_JEV_KEY=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
}

fm_jev_available() {
  [ -n "${_FM_JEV_KEY:-}" ]
}

# Millisecond clock without fm-timing-lib: prefer GNU date %3N, fall back to
# whole seconds so latency stays a number.
_fm_jev_now_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null) || ms=''
  case "$ms" in
    *[!0-9]*|'') printf '%s000\n' "$(date +%s)" ;;
    *) printf '%s\n' "$ms" ;;
  esac
}

fm_jev_post() {
  local response=$1 t0 t1 http
  command -v curl >/dev/null 2>&1 || { printf '000 null\n'; return 0; }
  [ -n "${_FM_JEV_KEY:-}" ] || { printf '000 null\n'; return 0; }
  t0=$(_fm_jev_now_ms)
  http=$(curl -sS --max-time "$FM_JEV_TIMEOUT" -o "$response" -w '%{http_code}' \
    -X POST "$FM_JEV_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$_FM_JEV_KEY") \
    --data-binary @- 2>/dev/null) || http=000
  t1=$(_fm_jev_now_ms)
  printf '%s %s\n' "$http" "$(( t1 - t0 ))"
}
