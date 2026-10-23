#!/usr/bin/env bash
# Verify a GitHub pull request's review manifest and body format, or report
# which counted review items lack a valid manifest disposition.
#
# The PR body is the only record of what a worker did with the reviews it
# received, so this script reads the body, the reviews, and the review threads
# and judges that record mechanically.
#
# Counted items. Every review whose state is COMMENTED or CHANGES_REQUESTED,
# from any account including the pull request author's (workers post under the
# captain's account), plus every unresolved review thread (`reviewThreads`
# isResolved false). An inline-only review counts too: its body is empty, but
# its items are the review's, and the row quotes whichever comment answers it.
# Only complete generated-note envelopes are skipped, using these markers:
# `no-mistakes-pipeline-attestation`, `no-mistakes-pr-appendix`, and
# `fm-worker-note`. Mentioning a marker in human text does not exempt an item.
# A thread is skipped only when all its comments are generated envelopes;
# a human follow-up still requires a row.
#
# Manifest. A `## Review follow-up` section holds one three-column table row per
# item: key | item | disposition. The key cell contains exactly one canonical
# `pullrequestreview-<id>` or `PRRT_...` thread node id, never a comment anchor.
# The item cell must be nonempty; escaped pipes stay within the same cell.
# With no counted reviews or threads, no table is required.
# The disposition cell is
# one of:
#   fixed <sha>            <sha> must be a commit reachable from the PR head
#   declined: <reason>     <reason> must be non-empty
#   deferred: <issue-url>  a github.com issue URL that must resolve
# Reachability uses local ancestry when proved; otherwise a bounded forge
# comparison must prove it, including when pipeline commits are absent from
# an existing worker worktree's object store.
# A row the parser cannot read fails the check rather than being ignored, and a
# counted item with no covering row fails it naming the item's URL.
#
# Body format. The body must carry `## Summary`, `## Evidence`, and
# `## Merge Danger` (the pr skill's template). A no-mistakes delivery must also
# keep a `## Pipeline` section carrying No-Mistakes' own attestation comment
# `<!-- no-mistakes-pipeline-attestation:v1 {...} -->`, whose head_sha must
# equal the PR head, with a nonempty steps array whose entries have nonempty
# step and status strings, and a test table in that same section.
# Any body that has a `## Pipeline` section must satisfy these checks whatever
# its delivery mode. The local No-Mistakes record must resolve the PR head and
# PR URL to a run with the same ordered step names; transient statuses are not
# compared. Successful verify emits pipeline_sha256=<digest> for the exact
# Pipeline block, including its heading and whitespace. PR-ready stores it in
# task metadata; --pipeline-digest requires that saved digest at merge. A
# missing digest or unavailable local record refuses verification. This is
# post-ready integrity only: edits to statuses or test results before PR-ready
# are not detected and become the trusted fingerprint. Workers must preserve
# the pipeline output verbatim.
#
# A forge read that cannot be completed fails verification closed, including on
# a host with no gh: an unread manifest is not evidence that the pull request
# has no reviews. A merge on a host that cannot read the manifest is
# therefore covered only by the captain's explicit instruction, which
# bin/fm-merge-guard-lib.sh records.
# Pagination includes reviews, threads, and thread comments; an incomplete page
# refuses the read. All forge reads, including disposition evidence, share one
# deadline of at most 15 seconds, reduced to half FM_CHECK_TIMEOUT when smaller.
#
# Usage:
#   fm-review-manifest.sh verify <pr-url> --mode <mode> [--worktree <dir>] [--pipeline-digest <sha256>]
#   fm-review-manifest.sh poll <pr-url>
#
# verify prints one disclosure line on success when counted items exist:
#   review <url>: N items declared by author; coverage of review text NOT machine-verified
# N counts declared table rows, not review or thread containers.
# and prints `error:` lines naming the failed item URL, row, or section on
# failure, exiting 1. A GitLab merge request is out of scope and prints a
# notice on stderr.
#
# poll shares verify's table parser and disposition validator, without checking
# body headings. It prints one line for uncovered items or invalid rows:
#   review <url> <key> [<key>...]
# or `review <url> invalid` when invalid rows exist without counted items.
# Any parser or disposition error leaves all counted items uncovered.
# A valid covered manifest prints nothing; an unreadable evidence read exits 1.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

RM_TOOL_PATTERN='^\\s*<!-- (no-mistakes-pipeline-attestation:v1 [^\\r\\n]*|no-mistakes-pr-appendix[^\\r\\n]*|fm-worker-note) -->\\s*$'
# shellcheck disable=SC2016
RM_QUERY='query($owner:String!,$repo:String!,$number:Int!,$reviewsCursor:String,$threadsCursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){headRefOid body reviews(first:100,after:$reviewsCursor){pageInfo{hasNextPage endCursor} nodes{databaseId state body}} reviewThreads(first:100,after:$threadsCursor){pageInfo{hasNextPage endCursor} nodes{id isResolved comments(first:100){pageInfo{hasNextPage endCursor} nodes{databaseId body}}}}}}}'
# shellcheck disable=SC2016
RM_THREAD_QUERY='query($id:ID!,$cursor:String!){node(id:$id){... on PullRequestReviewThread{comments(first:100,after:$cursor){pageInfo{hasNextPage endCursor} nodes{databaseId body}}}}}'

RM_JSON_FILE=
RM_PAGE_FILE=
RM_ERRORS=
RM_BODY=
RM_HEAD=
RM_ITEMS=
RM_CONTAINER_COUNT=0
RM_DEADLINE=0
RM_READ_FAILED=0

# shellcheck disable=SC2329 # Registered by the EXIT trap below.
rm_cleanup() {
  [ -z "$RM_JSON_FILE" ] || rm -f -- "$RM_JSON_FILE"
  [ -z "$RM_PAGE_FILE" ] || rm -f -- "$RM_PAGE_FILE"
  RM_JSON_FILE=
  RM_PAGE_FILE=
}
trap rm_cleanup EXIT
trap 'exit 1' HUP INT TERM

rm_usage() {
  echo "usage: fm-review-manifest.sh verify <pr-url> --mode <mode> [--worktree <dir>] [--pipeline-digest <sha256>]" >&2
  echo "       fm-review-manifest.sh poll <pr-url>" >&2
}

rm_error() {
  if [ -n "$RM_ERRORS" ]; then
    RM_ERRORS="$RM_ERRORS"$'\n'"$1"
  else
    RM_ERRORS=$1
  fi
}

rm_trim() {
  local s=${1-}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

rm_forge_read() {
  local remaining=$((RM_DEADLINE - SECONDS))
  [ "$remaining" -gt 0 ] || return 1
  fm_run_timed "$remaining" gh "$@"
}

# Returns 0 with the response in RM_JSON_FILE, 1 when
# the read is unavailable, and 2 when the provider is out of scope.
rm_read() {
  fm_pr_url_parse "$1" || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 2
  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  RM_JSON_FILE=$(mktemp "${TMPDIR:-/tmp}/.fm-review-manifest.XXXXXX") || {
    RM_JSON_FILE=
    return 1
  }
  local page reviews_cursor='' threads_cursor='' next_reviews next_threads merged thread cursor next reviews_done=0 threads_done=0
  local read_limit=$RM_TIMEOUT watch_limit=${FM_CHECK_TIMEOUT:-30}
  case "$watch_limit" in ''|*[!0-9]*) watch_limit=30 ;; esac
  watch_limit=$((10#$watch_limit / 2))
  [ "$watch_limit" -ge "$read_limit" ] || read_limit=$watch_limit
  RM_DEADLINE=$((SECONDS + read_limit))
  RM_PAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/.fm-review-page.XXXXXX") || return 1
  page=$RM_PAGE_FILE
  while :; do
    if ! rm_forge_read api graphql -f "query=$RM_QUERY" \
        -F "owner=$FM_PR_OWNER" -F "repo=$FM_PR_REPO" -F "number=$FM_PR_NUMBER" \
        ${reviews_cursor:+-f "reviewsCursor=$reviews_cursor"} \
        ${threads_cursor:+-f "threadsCursor=$threads_cursor"} > "$page" 2>/dev/null; then
      rm -f "$page"
      return 1
    fi
    if ! jq -e '(.errors // [] | length == 0) and (.data.repository.pullRequest |
        type == "object" and (.reviews.nodes | type == "array") and (.reviewThreads.nodes | type == "array")
        and (.reviews.pageInfo.hasNextPage | type == "boolean")
        and (.reviewThreads.pageInfo.hasNextPage | type == "boolean"))' "$page" >/dev/null 2>&1; then
      rm -f "$page"
      return 1
    fi
    next_reviews=$(jq -r '.data.repository.pullRequest.reviews.pageInfo | if .hasNextPage then .endCursor // "" else "" end' "$page")
    next_threads=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo | if .hasNextPage then .endCursor // "" else "" end' "$page")
    [ "$reviews_done" -eq 0 ] || next_reviews=
    [ "$threads_done" -eq 0 ] || next_threads=
    if ! jq -e '.data.repository.pullRequest | [.reviews,.reviewThreads] | all(.[]; (.pageInfo.hasNextPage == false) or (.pageInfo.endCursor | type == "string" and length > 0))' "$page" >/dev/null \
        || { [ -n "$next_reviews" ] && [ "$next_reviews" = "$reviews_cursor" ]; } \
        || { [ -n "$next_threads" ] && [ "$next_threads" = "$threads_cursor" ]; }; then
      rm -f "$page"
      return 1
    fi
    if [ ! -s "$RM_JSON_FILE" ]; then
      cp "$page" "$RM_JSON_FILE"
    else
      merged=$(jq -s '.[0] as $old | .[1] | .data.repository.pullRequest.reviews.nodes += $old.data.repository.pullRequest.reviews.nodes | .data.repository.pullRequest.reviewThreads.nodes += $old.data.repository.pullRequest.reviewThreads.nodes | .data.repository.pullRequest.reviews.nodes |= unique_by(.databaseId) | .data.repository.pullRequest.reviewThreads.nodes |= unique_by(.id)' "$RM_JSON_FILE" "$page") || return 1
      printf '%s\n' "$merged" > "$RM_JSON_FILE"
    fi
    [ -n "$next_reviews" ] || reviews_done=1
    [ -n "$next_threads" ] || threads_done=1
    reviews_cursor=$next_reviews
    threads_cursor=$next_threads
    [ -n "$reviews_cursor$threads_cursor" ] || break
  done
  while IFS=$'\t' read -r thread cursor; do
    [ -n "$thread" ] || continue
    [ -n "$cursor" ] && [ "$cursor" != null ] || { rm -f "$page"; return 1; }
    while :; do
      if ! rm_forge_read api graphql \
          -f "query=$RM_THREAD_QUERY" \
          -f "id=$thread" -f "cursor=$cursor" > "$page" 2>/dev/null; then
        rm -f "$page"
        return 1
      fi
      if ! jq -e '(.errors // [] | length == 0) and (.data.node.comments | (.nodes | type == "array") and (.pageInfo.hasNextPage | type == "boolean"))' "$page" >/dev/null 2>&1; then
        rm -f "$page"
        return 1
      fi
      merged=$(jq -s --arg id "$thread" '.[1].data.node.comments as $c | .[0] | (.data.repository.pullRequest.reviewThreads.nodes[] | select(.id == $id) | .comments) |= {nodes:(.nodes + $c.nodes),pageInfo:$c.pageInfo}' "$RM_JSON_FILE" "$page") || return 1
      printf '%s\n' "$merged" > "$RM_JSON_FILE"
      [ "$(jq -r '.data.node.comments.pageInfo.hasNextPage' "$page")" = true ] || break
      next=$(jq -r '.data.node.comments.pageInfo.endCursor // ""' "$page")
      if [ -z "$next" ] || [ "$next" = "$cursor" ]; then rm -f "$page"; return 1; fi
      cursor=$next
    done
  done < <(jq -r '.data.repository.pullRequest.reviewThreads.nodes[] | select(.comments.pageInfo.hasNextPage == true) | [.id,.comments.pageInfo.endCursor] | @tsv' "$RM_JSON_FILE")
  rm -f "$page"
  [ "$SECONDS" -lt "$RM_DEADLINE" ]
}

rm_field() {
  jq -r "$1" "$RM_JSON_FILE" 2>/dev/null
}

# Prints one line per counted item: kind<TAB>key<TAB>alternate-key
rm_items() {
  # shellcheck disable=SC2016  # jq programs read their variables from the document.
  rm_field '
    .data.repository.pullRequest as $pr
    | ($pr.reviews.nodes // [])[]
    | select(.state == "COMMENTED" or .state == "CHANGES_REQUESTED")
    | select(((.body // "") | test("'"$RM_TOOL_PATTERN"'")) | not)
    | "review\tpullrequestreview-\(.databaseId)\t"'
  # shellcheck disable=SC2016  # jq programs read their variables from the document.
  rm_field '
    .data.repository.pullRequest as $pr
    | ($pr.reviewThreads.nodes // [])[]
    | select(.isResolved == false)
    | (.comments.nodes[0] // {}) as $c
    | select((.comments.nodes | length == 0) or any(.comments.nodes[]; ((.body // "") | test("'"$RM_TOOL_PATTERN"'")) | not))
    | "thread\t\(.id)\t" + (if ($c.databaseId // null) == null then "" else "discussion_r\($c.databaseId)" end)'
}

rm_item_covered() {
  local key=$1 row
  while IFS= read -r row; do
    [ "$row" != "$key" ] || return 0
  done <<ROWS
$RM_ROW_KEYS
ROWS
  return 1
}

# Parse the `## Review follow-up` table out of the body into RM_ROW_KEYS
# (newline-separated first cells) and RM_DISPOSITIONS
# (newline-separated "<line-number><TAB><disposition>"). Unparseable rows are
# appended to RM_ERRORS naming the line number.
rm_parse_table() {
  local in_section=0 line row cell_count first_cell item disp lineno=0 i char cell escaped
  local -a cells
  RM_ROW_KEYS=
  RM_DISPOSITIONS=
  while IFS= read -r line; do
    lineno=$((lineno + 1))
    if [ "$in_section" -eq 0 ]; then
      [[ "$line" =~ ^##[[:space:]]+Review[[:space:]]+follow-up[[:space:]]*$ ]] && in_section=1
      continue
    fi
    if [[ "$line" =~ ^##[[:space:]] ]]; then
      in_section=0
      continue
    fi
    [[ "$line" =~ ^[[:space:]]*\| ]] || continue
    if [[ "$line" =~ ^[[:space:]]*\|[[:space:]]*:?-+ ]]; then
      continue
    fi
    row=$(rm_trim "$line")
    row=${row#|}
    row=${row%|}
    cells=()
    cell='' escaped=0
    for ((i=0; i<${#row}; i++)); do
      char=${row:i:1}
      if [ "$char" = '|' ] && [ "$escaped" -eq 0 ]; then
        cells+=("$cell")
        cell=
      else
        cell="$cell$char"
      fi
      if [ "$char" = "\\" ] && [ "$escaped" -eq 0 ]; then escaped=1; else escaped=0; fi
    done
    cells+=("$cell")
    cell_count=${#cells[@]}
    if [ "$cell_count" -ne 3 ]; then
      rm_error "the Review follow-up row at body line $lineno has $cell_count cells; it needs exactly 3 (key | item | disposition)"
      continue
    fi
    first_cell=$(rm_trim "${cells[0]}")
    item=$(rm_trim "${cells[1]}")
    disp=$(rm_trim "${cells[2]}")
    if [ "$(printf '%s' "$disp" | tr '[:upper:]' '[:lower:]')" = disposition ]; then
      continue
    fi
    if ! [[ "$first_cell" =~ ^(pullrequestreview-[0-9]+|PRRT_[A-Za-z0-9_-]+)$ ]]; then
      rm_error "the Review follow-up row at body line $lineno needs exactly one canonical review or thread key"
      continue
    fi
    if [ -z "$item" ]; then
      rm_error "the Review follow-up row at body line $lineno has an empty item cell; quote the review item it answers"
      continue
    fi
    RM_ROW_KEYS="${RM_ROW_KEYS:+$RM_ROW_KEYS$'\n'}$first_cell"
    RM_DISPOSITIONS="${RM_DISPOSITIONS:+$RM_DISPOSITIONS$'\n'}${lineno}"$'\t'"$disp"
  done <<BODY
$RM_BODY
BODY
}

# A disposition has to be one of the three the format allows; `fixed` and
# `deferred` carry evidence this function proves.
rm_check_disposition() {
  local lineno=$1 disp=$2 sha url owner repo number compare issue
  case "$disp" in
    "fixed "*)
      sha=$(rm_trim "${disp#fixed }")
      if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
        rm_error "the Review follow-up row at body line $lineno has an unparseable disposition '$disp'; expected 'fixed <sha>', 'declined: <reason>', or 'deferred: <issue url>'"
        return 0
      fi
      if [ -n "$RM_WORKTREE" ] && [ -d "$RM_WORKTREE" ] \
          && [ -n "$RM_HEAD" ] \
          && git -C "$RM_WORKTREE" cat-file -e "$sha^{commit}" 2>/dev/null \
          && git -C "$RM_WORKTREE" cat-file -e "$RM_HEAD^{commit}" 2>/dev/null \
          && git -C "$RM_WORKTREE" merge-base --is-ancestor "$sha" "$RM_HEAD" 2>/dev/null; then
        return 0
      elif ! compare=$(rm_forge_read api "repos/$FM_PR_OWNER/$FM_PR_REPO/compare/$sha...$RM_HEAD" 2>/dev/null); then
        RM_READ_FAILED=1
        rm_error "the Review follow-up row at body line $lineno claims 'fixed $sha', but forge reachability from the PR head $RM_HEAD could not be proved"
      elif ! printf '%s' "$compare" | jq -es 'length == 1 and (.[0] | (.status | type == "string") and (.merge_base_commit.sha | type == "string"))' >/dev/null 2>&1; then
        RM_READ_FAILED=1
        rm_error "the Review follow-up row at body line $lineno has an unreadable forge comparison"
      elif ! printf '%s' "$compare" | jq -es --arg sha "$sha" 'length == 1 and (.[0] | (.status == "ahead" or .status == "identical") and (.merge_base_commit.sha | startswith($sha)))' >/dev/null 2>&1; then
        rm_error "the Review follow-up row at body line $lineno claims 'fixed $sha', but forge reachability from the PR head $RM_HEAD could not be proved"
      fi
      ;;
    "declined:"|"declined: "*)
      [ -n "$(rm_trim "${disp#declined:}")" ] \
        || rm_error "the Review follow-up row at body line $lineno declines an item with no reason; use 'declined: <reason>'"
      ;;
    "deferred: "*)
      url=$(rm_trim "${disp#deferred: }")
      if ! [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)/issues/([1-9][0-9]*)$ ]]; then
        rm_error "the Review follow-up row at body line $lineno defers an item without a github.com issue URL; use 'deferred: https://github.com/<owner>/<repo>/issues/<n>'"
        return 0
      fi
      owner=${BASH_REMATCH[1]}
      repo=${BASH_REMATCH[2]}
      number=${BASH_REMATCH[3]}
      if ! issue=$(rm_forge_read api "repos/$owner/$repo/issues/$number" --jq .number 2>/dev/null) \
          || ! [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
        RM_READ_FAILED=1
        rm_error "the Review follow-up row at body line $lineno defers to $url, which does not resolve"
      fi
      ;;
    deferred:*)
      rm_error "the Review follow-up row at body line $lineno has an unparseable disposition '$disp'; expected 'deferred: <issue url>'"
      ;;
    *)
      rm_error "the Review follow-up row at body line $lineno has an unparseable disposition '$disp'; expected 'fixed <sha>', 'declined: <reason>', or 'deferred: <issue url>'"
      ;;
  esac
}

rm_has_heading() {
  printf '%s\n' "$RM_BODY" | grep -qxE "##[[:space:]]+$1[[:space:]]*"
}

rm_check_sections() {
  local section detail
  for section in Summary Evidence "Merge Danger"; do
    rm_has_heading "$section" \
      || rm_error "the PR body has no '## $section' section; rewrite it with the pr skill's template before reporting PR-ready"
  done
  if ! command -v python3 >/dev/null 2>&1; then
    rm_error "python3 is required to verify the Pipeline block"
    return 0
  fi
  if detail=$(fm_run_timed "$RM_TIMEOUT" python3 "$SCRIPT_DIR/fm-pipeline-verify.py" \
      "$RM_JSON_FILE" "$RM_MODE" "$RM_WORKTREE" "$RM_URL" "$RM_CHECK_DIGEST" "$RM_EXPECTED_DIGEST" 2>&1); then
    RM_PIPELINE_DIGEST=$detail
  else
    rm_error "${detail:-the Pipeline verification could not be completed}"
  fi
}

rm_item_url() {
  local kind=$1 key=$2 alt=$3
  case "$kind" in
    review) printf '%s#%s' "$RM_URL" "$key" ;;
    thread)
      if [ -n "$alt" ]; then
        printf '%s#%s' "$RM_URL" "$alt"
      else
        printf '%s' "$RM_URL"
      fi
      ;;
  esac
}

rm_load() {
  RM_BODY=$(rm_field '.data.repository.pullRequest.body // ""')
  RM_HEAD=$(rm_field '.data.repository.pullRequest.headRefOid // ""')
  RM_ITEMS=$(rm_items)
  RM_CONTAINER_COUNT=0
  if [ -n "$RM_ITEMS" ]; then
    RM_CONTAINER_COUNT=$(printf '%s\n' "$RM_ITEMS" | grep -c .)
  fi
}

rm_check_rows() {
  local line disp
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    disp=$(printf '%s' "$line" | cut -f2-)
    rm_check_disposition "${line%%$'\t'*}" "$disp"
  done <<DISPOSITIONS
$RM_DISPOSITIONS
DISPOSITIONS
  if [ "$SECONDS" -ge "$RM_DEADLINE" ]; then
    RM_READ_FAILED=1
    rm_error "the review evidence read deadline was exhausted"
  fi
}

rm_verify() {
  local kind key alt url line item_word declared
  rm_load
  rm_check_sections
  rm_parse_table
  if [ "$RM_CONTAINER_COUNT" -gt 0 ]; then
    item_word=items
    [ "$RM_CONTAINER_COUNT" -ne 1 ] || item_word=item
    [ -n "$RM_ROW_KEYS" ] \
      || rm_error "the pull request has $RM_CONTAINER_COUNT review $item_word but the PR body has no '## Review follow-up' table; add one row per item"
    while IFS= read -r kind_pair; do
      [ -n "$kind_pair" ] || continue
      kind=$(printf '%s' "$kind_pair" | cut -f1)
      key=$(printf '%s' "$kind_pair" | cut -f2)
      alt=$(printf '%s' "$kind_pair" | cut -f3)
      if [ -n "$RM_ROW_KEYS" ] && rm_item_covered "$key"; then
        continue
      fi
      url=$(rm_item_url "$kind" "$key" "$alt")
      rm_error "the review item $url has no row in the '## Review follow-up' table"
    done <<ITEMS
$RM_ITEMS
ITEMS
  fi
  rm_check_rows
  if [ -n "$RM_ERRORS" ]; then
    while IFS= read -r line; do
      printf 'error: %s\n' "$line" >&2
    done <<ERRORS
$RM_ERRORS
ERRORS
    return 1
  fi
  [ -z "$RM_PIPELINE_DIGEST" ] || printf 'pipeline_sha256=%s\n' "$RM_PIPELINE_DIGEST"
  if [ "$RM_CONTAINER_COUNT" -gt 0 ]; then
    declared=$(printf '%s\n' "$RM_ROW_KEYS" | grep -c .)
    item_word=items
    [ "$declared" -ne 1 ] || item_word=item
    printf 'review %s: %s %s declared by author; coverage of review text NOT machine-verified\n' \
      "$RM_URL" "$declared" "$item_word"
  fi
  return 0
}

rm_poll() {
  local kind_pair key uncovered=0 url
  rm_load
  rm_parse_table
  rm_check_rows
  [ "$RM_READ_FAILED" -eq 0 ] || return 1
  while IFS= read -r kind_pair; do
    [ -n "$kind_pair" ] || continue
    key=$(printf '%s' "$kind_pair" | cut -f2)
    if [ -z "$RM_ERRORS" ] && rm_item_covered "$key"; then
      continue
    fi
    if [ "$uncovered" -eq 0 ]; then
      url="$RM_URL $key"
    else
      url="$url $key"
    fi
    uncovered=$((uncovered + 1))
  done <<ITEMS
$RM_ITEMS
ITEMS
  if [ "$uncovered" -gt 0 ]; then
    printf 'review %s\n' "$url"
  elif [ -n "$RM_ERRORS" ]; then
    printf 'review %s invalid\n' "$RM_URL"
  fi
  return 0
}

RM_MODE=
RM_WORKTREE=
RM_PIPELINE_DIGEST=
RM_EXPECTED_DIGEST=
RM_CHECK_DIGEST=0
RM_TIMEOUT=15

COMMAND=${1:-}
[ "$#" -ge 2 ] || { rm_usage; exit 2; }
RM_URL=$2
shift 2
if [ "$COMMAND" = verify ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        [ "$#" -ge 2 ] || { rm_usage; exit 2; }
        RM_MODE=$2
        shift 2
        ;;
      --pipeline-digest)
        [ "$#" -ge 2 ] || { rm_usage; exit 2; }
        RM_CHECK_DIGEST=1
        RM_EXPECTED_DIGEST=$2
        shift 2
        ;;
      --worktree)
        [ "$#" -ge 2 ] || { rm_usage; exit 2; }
        RM_WORKTREE=$2
        shift 2
        ;;
      *) rm_usage; exit 2 ;;
    esac
  done
  [ -n "$RM_MODE" ] || { rm_usage; exit 2; }
elif [ "$COMMAND" = poll ]; then
  [ "$#" -eq 0 ] || { rm_usage; exit 2; }
else
  rm_usage
  exit 2
fi

rm_read "$RM_URL"
rc=$?
if [ "$rc" -ne 0 ]; then
  if [ "$rc" -eq 2 ]; then
    echo "notice: review manifest verification covers GitHub pull requests only; $RM_URL is not one" >&2
    exit 0
  fi
  if [ "$COMMAND" = verify ]; then
    printf 'error: the reviews, threads, and body of %s could not be read, so the review manifest cannot be verified\n' "$RM_URL" >&2
    exit 1
  fi
  printf 'error: the reviews, threads, and body of %s could not be read completely\n' "$RM_URL" >&2
  exit 1
fi

if [ "$COMMAND" = verify ]; then
  rm_verify
  exit $?
fi
rm_poll
exit $?
