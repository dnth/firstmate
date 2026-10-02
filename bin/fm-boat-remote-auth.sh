#!/usr/bin/env bash
# Host-local Boat OMP bearer controls. Installed with the shared token grammar.
# Usage: fm-boat-remote-auth.sh --install | --check | --shred
# The bearer travels only on stdin; release checks shred and absence before stop.
set -euo pipefail
if ! declare -F fm_omp_auth_token_valid >/dev/null; then
  # shellcheck source=bin/fm-omp-auth-token-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-omp-auth-token-lib.sh"
fi
BASE=${FM_BOAT_REMOTE_AUTH_DIR:-/home/user/.fm}
TOKEN="$BASE/omp-auth-broker.token"
case "${1:-}" in
  --install)
    token=$(LC_ALL=C head -c 513)
    fm_omp_auth_token_valid "$token" || { printf 'error: invalid broker bearer\n' >&2; exit 1; }
    [ ! -L "$BASE" ] || exit 1
    mkdir -p "$BASE"
    chmod 700 "$BASE"
    [ ! -L "$TOKEN" ] && [ ! -L "$BASE/boat-auth.marker" ] || exit 1
    tmp=$(mktemp "$BASE/.token.XXXXXX")
    trap 'rm -f -- "$tmp"' EXIT
    printf '%s' "$token" > "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$TOKEN"
    printf 'boat-auth-v1\n' > "$BASE/boat-auth.marker"
    chmod 600 "$BASE/boat-auth.marker"
    ;;
  --shred)
    [ ! -L "$BASE" ] && [ ! -L "$TOKEN" ] || exit 1
    if [ -f "$TOKEN" ]; then
      shred -u -- "$TOKEN" || { printf 'error: bearer unshredded\n' >&2; exit 1; }
    fi
    [ ! -e "$TOKEN" ] || exit 1
    rm -f -- "$BASE/boat-auth.marker"
    ;;
  --check)
    [ -f "$TOKEN" ] && [ ! -L "$TOKEN" ] && [ "$(stat -c %a "$TOKEN")" = 600 ] || exit 1
    token=$(cat "$TOKEN")
    fm_omp_auth_token_valid "$token" || exit 1
    headers=$(mktemp "$BASE/.headers.XXXXXX")
    trap 'rm -f -- "$headers"' EXIT
    {
      printf 'silent\nfail\nmax-time = "2"\n'
      printf 'url = "http://127.0.0.1:8765/v1/snapshot"\n'
      printf 'header = "Authorization: Bearer %s"\n' "$token"
    } | curl --config - --dump-header "$headers" --output /dev/null
    # Readiness cannot bless a tunnel mis-cabled directly to the canonical store.
    grep -qi '^x-fm-auth-broker-facade:[[:space:]]*credential-read-only' "$headers"
    ;;
  *) printf 'Usage: fm-boat-remote-auth.sh --install|--check|--shred\n' >&2; exit 2 ;;
esac
