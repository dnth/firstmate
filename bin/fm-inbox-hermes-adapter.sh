#!/usr/bin/env bash
# Explicit adapter from Firstmate inbox result envelopes to Hermes messaging.
# Reuses `hermes send`; it does not read platform credentials or call remote APIs.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-inbox-result-lib.sh
. "$BIN_DIR/fm-inbox-result-lib.sh"

target=
key=
payload=
usage() {
  printf 'usage: fm-inbox-hermes-adapter.sh --target <hermes:platform:chat[:thread]> --idempotency-key <key> --payload-file <result.json>\n' >&2
  exit 64
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) [ "$#" -ge 2 ] || usage; target=$2; shift 2 ;;
    --idempotency-key) [ "$#" -ge 2 ] || usage; key=$2; shift 2 ;;
    --payload-file) [ "$#" -ge 2 ] || usage; payload=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$target" ] && [ -n "$key" ] && [ -n "$payload" ] || usage
[[ "$target" =~ ^hermes:[a-z][a-z0-9_-]*:[A-Za-z0-9@#%+._-]+(:[A-Za-z0-9@#%+._-]+)?$ ]] || usage
fm_inbox_artifact_safe "$payload" || usage
command -v jq >/dev/null 2>&1 || usage
fm_inbox_reply_target_authorized "$target" || {
  printf 'reply target is not authorized\n' >&2
  exit 64
}
jq -e --arg key "$key" --arg target "$target" \
  '.schema == "firstmate.inbox-result.v1" and .note_id == $key and
   (.request_note_id | type == "string") and
   (.correlation_id | type == "string") and
   .reply_target == $target and
   (.status == "completed" or .status == "failed" or .status == "needs-input") and
   (.summary | type == "string") and
   (.artifacts | type == "array" and length <= 20 and all(.[]; type == "string"))' \
  "$payload" >/dev/null \
  || usage
while IFS= read -r artifact; do
  fm_inbox_artifact_safe "$artifact" || usage
done < <(jq -r '.artifacts[]' "$payload")

HERMES_BIN=${HERMES_BIN:-hermes}
command -v "$HERMES_BIN" >/dev/null 2>&1 || {
  printf 'hermes executable is unavailable\n' >&2
  exit 64
}
destination=${target#hermes:}
message=$(mktemp "${TMPDIR:-/tmp}/fm-inbox-result.XXXXXX") || exit 70
# shellcheck disable=SC2329 # Invoked by the traps below.
cleanup() { rm -f -- "$message"; }
trap cleanup EXIT INT TERM
chmod 0600 "$message"
{
  printf 'FirstMate result: %s\n' "$(jq -r '.status' "$payload")"
  printf 'Correlation: %s\n' "$(jq -r '.correlation_id' "$payload")"
  printf 'Request note: %s\n\n' "$(jq -r '.request_note_id' "$payload")"
  jq -r '.summary' "$payload"
  if [ "$(jq '.artifacts | length' "$payload")" -gt 0 ]; then
    printf '\nArtifacts:\n'
    jq -r '.artifacts[] | "- " + .' "$payload"
  fi
} > "$message"

set +e
output=$("$HERMES_BIN" send --to "$destination" --json --file "$message" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  if printf '%s\n' "$output" | jq -e \
      'type == "object" and .success == true and (.skipped != true) and (.error == null)' \
      >/dev/null 2>&1; then
    printf '%s\n' "$output" | jq --arg key "$key" \
      '. + {ok:true, idempotency_key:$key}'
    exit 0
  fi
  printf 'Hermes returned an unconfirmed delivery result: %s\n' "$output" >&2
  exit 70
fi
printf '%s\n' "$output" >&2
# A usage/config error is a definite permanent no-send. Platform/network failure
# is conservatively ambiguous: the provider may have accepted the message before
# the process observed its error, so Firstmate will not retry without confirmation.
[ "$rc" -eq 2 ] && exit 64
exit 70
