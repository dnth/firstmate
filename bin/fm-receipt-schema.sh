#!/usr/bin/env bash
# Validate one compact receipt JSON object from stdin.
#
# Usage: fm-receipt-schema.sh
#
# The input must be one JSON object with required criterion, type, outcome,
# summary, and result string fields; optional command, artifact, and file
# strings; an optional 40- or 64-hex head string that older ledgers carry and no
# current writer emits; no unknown keys; type set to test, build, lint,
# typecheck, api, browser, manual, or review; outcome set to success, failure,
# negative, zero, skipped, empty, placeholder, weak, passed, failed, or
# accepted-blocked; and a non-whitespace captain_exception string present
# exactly when the outcome is accepted-blocked.
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
  and ((keys - ["artifact","captain_exception","command","criterion","file","head","outcome","result","summary","type"]) | length == 0)
  and (.criterion | type == "string" and test("[^[:space:]]"))
  and (.type | type == "string" and test("^(test|build|lint|typecheck|api|browser|manual|review)$"))
  and (.outcome | type == "string" and test("^(success|failure|negative|zero|skipped|empty|placeholder|weak|passed|failed|accepted-blocked)$"))
  and (if .outcome == "accepted-blocked"
       then (.captain_exception | type == "string" and test("[^[:space:]]"))
       else (has("captain_exception") | not) end)
  and (.summary | type == "string" and test("[^[:space:]]"))
  and (.result | type == "string" and test("[^[:space:]]"))
  and ((has("command") | not) or (.command | type == "string"))
  and ((has("artifact") | not) or (.artifact | type == "string"))
  and ((has("file") | not) or (.file | type == "string"))
  and ((has("head") | not) or (.head | type == "string"
    and ((length == 40 or length == 64) and test("^[0-9a-f]+$"))))
' >/dev/null
