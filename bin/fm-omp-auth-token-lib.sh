#!/usr/bin/env bash
# Single OMP broker bearer grammar, shared by producers and remote consumers.
# Source and call fm_omp_auth_token_valid <token>, or execute with stdin.
fm_omp_auth_token_valid() {
  [ -n "${1:-}" ] && [ "${#1}" -le 512 ] || return 1
  case "$1" in *[!A-Za-z0-9_-]*) return 1 ;; esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --validate-token ]; then
  token=$(LC_ALL=C head -c 513) || exit 1
  fm_omp_auth_token_valid "$token"
fi
