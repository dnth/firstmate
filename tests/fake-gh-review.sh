#!/usr/bin/env bash
# Shared fixture responder for bin/fm-review-manifest.sh's single GraphQL read.
#
# Fake `gh` scripts that have to answer that read (bin/fm-pr-check.sh verifies
# the review manifest and body format at PR-ready, and bin/fm-pr-merge.sh
# re-verifies them before merging) delegate here instead of re-rolling the
# response shape. The response carries a valid pr-skill body with no counted
# reviews or threads, so a case that does not care about review coverage passes
# the checks without inventing its own table.
#
# Usage: fake-gh-review.sh [head] [mode]
#   head  the PR head the caller's own `gh pr view --json headRefOid` reports;
#         the Pipeline attestation is written for this head, so a
#         `no-mistakes` delivery passes the attestation check.
#   mode  delivery mode; `no-mistakes` always appends the `## Pipeline`
#         section, any other mode leaves it out.
set -u

head=${1:-0123456789abcdef0123456789abcdef01234567}
mode=${2:-direct-PR}

body=$(printf '## Summary\n\nfixture\n\n## Evidence\n\n- **Before:** none\n  **After:** none\n\n## Merge Danger\n\n**Door:** two-way.\n**Blast Radius:** low.\n')
if [ "$mode" = no-mistakes ]; then
  body="$body"$'\n'"$(printf '## Pipeline\n\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":[{"step":"review","status":"completed"}]} -->\n\n| Test | Result |\n| --- | --- |\n| fixture | passed |\n' "$head")"
fi

jq -n --arg head "$head" --arg body "$body" \
  '{data:{repository:{pullRequest:{
      headRefOid:$head,
      body:$body,
      reviews:{pageInfo:{hasNextPage:false},nodes:[]},
      reviewThreads:{pageInfo:{hasNextPage:false},nodes:[]}}}}}'
