#!/usr/bin/env bash
# Validate one compact receipt JSON object from stdin.
#
# Usage: fm-receipt-schema.sh
#
# The input must be one JSON object with required criterion, type, outcome,
# summary, and result string fields; optional command, artifact, file, and head
# strings; no unknown keys; type set to test, build, lint, typecheck, api,
# browser, manual, or review; outcome set to success, failure, negative, zero,
# skipped, empty, placeholder, weak, passed, or failed; and a 40- or 64-hex
# head when head is present.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -eq 0 ] || { usage >&2; exit 2; }

jq -e '
  type == "object"
  and ((keys - ["artifact","command","criterion","file","head","outcome","result","summary","type"]) | length == 0)
  and (.criterion | type == "string" and test("[^[:space:]]"))
  and (.type | type == "string" and test("^(test|build|lint|typecheck|api|browser|manual|review)$"))
  and (.outcome | type == "string" and test("^(success|failure|negative|zero|skipped|empty|placeholder|weak|passed|failed)$"))
  and (.summary | type == "string" and test("[^[:space:]]"))
  and (.result | type == "string" and test("[^[:space:]]"))
  and ((has("command") | not) or (.command | type == "string"))
  and ((has("artifact") | not) or (.artifact | type == "string"))
  and ((has("file") | not) or (.file | type == "string"))
  and ((has("head") | not) or (.head | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")))
' >/dev/null
