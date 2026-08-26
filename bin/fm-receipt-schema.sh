#!/usr/bin/env bash
# Validate one compact receipt JSON object from stdin.
set -eu
jq -e '
  type == "object"
  and ((keys - ["artifact","command","criterion","file","outcome","result","summary","type"]) | length == 0)
  and (.criterion | type == "string" and test("[^[:space:]]"))
  and (.type | type == "string" and test("^(test|build|lint|typecheck|api|browser|manual|review)$"))
  and (.outcome | type == "string" and test("^(passed|failed)$"))
  and (.summary | type == "string" and test("[^[:space:]]"))
  and (.result | type == "string" and test("[^[:space:]]"))
  and ((has("command") | not) or (.command | type == "string"))
  and ((has("artifact") | not) or (.artifact | type == "string"))
  and ((has("file") | not) or (.file | type == "string"))
' >/dev/null
