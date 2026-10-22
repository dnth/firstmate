#!/usr/bin/env bash
# Verify a GitHub pull request's review manifest and body format, or report
# which counted review items still lack a manifest row.
#
# The PR body is the only record of what a worker did with the reviews it
# received, so this script reads the body, the reviews, and the review threads
# in one GraphQL read and judges that record mechanically.
#
# Counted items. Every review whose state is COMMENTED or CHANGES_REQUESTED,
# from any account including the pull request author's (workers post under the
# captain's account), plus every unresolved review thread (`reviewThreads`
# isResolved false). An inline-only review counts too: its body is empty, but
# its items are the review's, and the row quotes whichever comment answers it.
# Tool-generated items are skipped by their body markers:
# `no-mistakes-pipeline-attestation`, `no-mistakes-pr-appendix`, and
# `fm-worker-note`. A review or thread carrying one of those markers is not a
# review item and needs no row.
#
# Manifest. A `## Review follow-up` section holds one three-column table row per
# item: key | item | disposition. The key cell names the item, either as
# `pullrequestreview-<id>` (or a review URL ending in that anchor) or as the
# thread's node id / `discussion_r<comment-id>` anchor. The disposition cell is
# one of:
#   fixed <sha>            <sha> must be a commit reachable from the PR head
#   declined: <reason>     <reason> must be non-empty
#   deferred: <issue-url>  a github.com issue URL that must resolve
# A row the parser cannot read fails the check rather than being ignored, and a
# counted item with no covering row fails it naming the item's URL.
#
# Body format. The body must carry `## Summary`, `## Evidence`, and
# `## Merge Danger` (the pr skill's template). A no-mistakes delivery must also
# keep a `## Pipeline` section carrying No-Mistakes' own attestation comment
# `<!-- no-mistakes-pipeline-attestation:v1 {...} -->`, whose head_sha must
# equal the PR head; any body that has a `## Pipeline` section has to carry an
# intact attestation whatever its delivery mode.
#
# A forge read that cannot be completed fails verification closed, including on
# a host with no gh: an unread manifest is not evidence that the pull request
# has no reviews. The poll mode stays silent instead, because a silent poll must
# never be read as a result. A merge on a host that cannot read the manifest is
# therefore covered only by the captain's explicit instruction, which
# bin/fm-merge-guard-lib.sh records.
#
# Usage:
#   fm-review-manifest.sh verify <pr-url> --mode <mode> [--worktree <dir>] [--timeout <secs>]
#   fm-review-manifest.sh poll <pr-url> [--timeout <secs>]
#
# verify prints one disclosure line on success when counted items exist:
#   review <url>: N items declared by author; coverage of review text NOT machine-verified
# and prints `error:` lines naming the failed item URL, row, or section on
# failure, exiting 1. A GitLab merge request is out of scope and prints a
# notice on stderr.
#
# poll prints one line when counted items exist that no manifest row covers:
#   review <url> <key> [<key>...]
# and nothing otherwise, always exiting 0.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

RM_TOOL_MARKERS='no-mistakes-pipeline-attestation|no-mistakes-pr-appendix|fm-worker-note'
# shellcheck disable=SC2016  # GraphQL variables are literal query syntax.
RM_QUERY='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){headRefOid body reviews(first:100){pageInfo{hasNextPage} nodes{databaseId state body}} reviewThreads(first:100){pageInfo{hasNextPage} nodes{id isResolved comments(first:1){nodes{databaseId body}}}}}}}'

RM_JSON_FILE=
RM_ERRORS=
RM_BODY=
RM_HEAD=
RM_ITEMS=
RM_ITEM_COUNT=0

rm_cleanup() {
  [ -z "$RM_JSON_FILE" ] || rm -f -- "$RM_JSON_FILE"
  RM_JSON_FILE=
}
trap rm_cleanup EXIT

rm_usage() {
  echo "usage: fm-review-manifest.sh verify <pr-url> --mode <mode> [--worktree <dir>] [--timeout <secs>]" >&2
  echo "       fm-review-manifest.sh poll <pr-url> [--timeout <secs>]" >&2
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

# One bounded forge read. Returns 0 with the response in RM_JSON_FILE, 1 when
# the read is unavailable, and 2 when the provider is out of scope.
rm_read() {
  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  fm_pr_url_parse "$1" || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 2
  RM_JSON_FILE=$(mktemp "${TMPDIR:-/tmp}/.fm-review-manifest.XXXXXX") || {
    RM_JSON_FILE=
    return 1
  }
  if ! fm_run_timed "$RM_TIMEOUT" gh api graphql \
      -f "query=$RM_QUERY" \
      -F "owner=$FM_PR_OWNER" -F "repo=$FM_PR_REPO" -F "number=$FM_PR_NUMBER" \
    > "$RM_JSON_FILE" 2>/dev/null; then
    rm_cleanup
    return 1
  fi
  if ! jq -e '(.data.repository.pullRequest // null) | type == "object"' "$RM_JSON_FILE" >/dev/null 2>&1; then
    rm_cleanup
    return 1
  fi
  return 0
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
    | select(((.body // "") | test("'"$RM_TOOL_MARKERS"'")) | not)
    | "review\tpullrequestreview-\(.databaseId)\t"'
  # shellcheck disable=SC2016  # jq programs read their variables from the document.
  rm_field '
    .data.repository.pullRequest as $pr
    | ($pr.reviewThreads.nodes // [])[]
    | select(.isResolved == false)
    | (.comments.nodes[0] // {}) as $c
    | select(((([$c.body // ""] | join("")) | test("'"$RM_TOOL_MARKERS"'")) | not))
    | "thread\t\(.id)\t" + (if ($c.databaseId // null) == null then "" else "discussion_r\($c.databaseId)" end)'
}

# True when <key> appears in <cell> as a whole token, so review 1 does not
# claim the row for review 12.
rm_key_in_cell() {
  local key=$1 cell=$2 re
  re="(^|[^0-9A-Za-z_-])$key([^0-9A-Za-z0-9_-]|$)"
  [[ "$cell" =~ $re ]]
}

rm_item_covered() {
  local kind=$1 key=$2 alt=$3 row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if rm_key_in_cell "$key" "$row"; then
      return 0
    fi
    if [ -n "$alt" ] && rm_key_in_cell "$alt" "$row"; then
      return 0
    fi
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
  local in_section=0 line row cells cell_count first_cell item disp lineno=0
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
    IFS='|' read -r -a cells <<< "$row"
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
  local lineno=$1 disp=$2 sha url rest owner repo number
  case "$disp" in
    "fixed "*)
      sha=$(rm_trim "${disp#fixed }")
      if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
        rm_error "the Review follow-up row at body line $lineno has an unparseable disposition '$disp'; expected 'fixed <sha>', 'declined: <reason>', or 'deferred: <issue url>'"
        return 0
      fi
      if [ -z "$RM_WORKTREE" ] || [ ! -d "$RM_WORKTREE" ]; then
        rm_error "the Review follow-up row at body line $lineno claims 'fixed $sha', but the task worktree is unavailable, so that commit cannot be proved reachable from the PR head"
        return 0
      fi
      if ! git -C "$RM_WORKTREE" cat-file -e "$sha^{commit}" 2>/dev/null; then
        rm_error "the Review follow-up row at body line $lineno claims 'fixed $sha', but $sha is not a commit in the pull request, so it cannot be reachable from its head"
        return 0
      fi
      if [ -n "$RM_HEAD" ] && ! git -C "$RM_WORKTREE" merge-base --is-ancestor "$sha" "$RM_HEAD" 2>/dev/null; then
        rm_error "the Review follow-up row at body line $lineno claims 'fixed $sha', but $sha is not reachable from the PR head $RM_HEAD"
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
      if ! fm_run_timed "$RM_TIMEOUT" gh api "repos/$owner/$repo/issues/$number" --jq .number >/dev/null 2>&1; then
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
  local section att
  for section in Summary Evidence "Merge Danger"; do
    rm_has_heading "$section" \
      || rm_error "the PR body has no '## $section' section; rewrite it with the pr skill's template before reporting PR-ready"
  done
  if [ "$RM_MODE" = no-mistakes ] || rm_has_heading Pipeline; then
    if ! rm_has_heading Pipeline; then
      rm_error "the PR body has no '## Pipeline' section; keep No-Mistakes' pipeline output, attestation, and test table verbatim"
      return 0
    fi
    att=$(printf '%s\n' "$RM_BODY" \
      | sed -n 's/^<!-- no-mistakes-pipeline-attestation:v1 \(.*\) -->[[:space:]]*$/\1/p' \
      | head -1)
    if [ -z "$att" ]; then
      rm_error "the PR body's '## Pipeline' section carries no intact No-Mistakes attestation (<!-- no-mistakes-pipeline-attestation:v1 {...} -->); keep it verbatim"
      return 0
    fi
    if ! printf '%s' "$att" | jq -e '
        type == "object"
        and (.head_sha | type == "string" and test("^[0-9a-f]{40}$"))
        and (.steps | type == "array" and length > 0)' >/dev/null 2>&1; then
      rm_error "the PR body's No-Mistakes attestation is malformed; keep it verbatim"
      return 0
    fi
    if [ -n "$RM_HEAD" ] && [ "$(printf '%s' "$att" | jq -r '.head_sha')" != "$RM_HEAD" ]; then
      rm_error "the PR body's No-Mistakes attestation is for head $(printf '%s' "$att" | jq -r '.head_sha'), not the PR head $RM_HEAD; keep it verbatim and never edit it by hand"
    fi
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
  local more
  RM_BODY=$(rm_field '.data.repository.pullRequest.body // ""')
  RM_HEAD=$(rm_field '.data.repository.pullRequest.headRefOid // ""')
  more=$(rm_field '.data.repository.pullRequest.reviews.pageInfo.hasNextPage')
  [ "$more" != true ] || rm_error "the pull request has more than 100 reviews, so the review manifest cannot be verified from one read"
  more=$(rm_field '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
  [ "$more" != true ] || rm_error "the pull request has more than 100 review threads, so the review manifest cannot be verified from one read"
  RM_ITEMS=$(rm_items)
  RM_ITEM_COUNT=0
  if [ -n "$RM_ITEMS" ]; then
    RM_ITEM_COUNT=$(printf '%s\n' "$RM_ITEMS" | grep -c .)
  fi
}

rm_verify() {
  local kind key alt url line disp item_word
  rm_load
  rm_check_sections
  rm_parse_table
  if [ "$RM_ITEM_COUNT" -gt 0 ]; then
    item_word=items
    [ "$RM_ITEM_COUNT" -ne 1 ] || item_word=item
    [ -n "$RM_ROW_KEYS" ] \
      || rm_error "the pull request has $RM_ITEM_COUNT review $item_word but the PR body has no '## Review follow-up' table; add one row per item"
    while IFS= read -r kind_pair; do
      [ -n "$kind_pair" ] || continue
      kind=$(printf '%s' "$kind_pair" | cut -f1)
      key=$(printf '%s' "$kind_pair" | cut -f2)
      alt=$(printf '%s' "$kind_pair" | cut -f3)
      if [ -n "$RM_ROW_KEYS" ] && rm_item_covered "$kind" "$key" "$alt"; then
        continue
      fi
      url=$(rm_item_url "$kind" "$key" "$alt")
      rm_error "the review item $url has no row in the '## Review follow-up' table"
    done <<ITEMS
$RM_ITEMS
ITEMS
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    disp=$(printf '%s' "$line" | cut -f2-)
    rm_check_disposition "${line%%$'\t'*}" "$disp"
  done <<DISPOSITIONS
$RM_DISPOSITIONS
DISPOSITIONS
  if [ -n "$RM_ERRORS" ]; then
    while IFS= read -r line; do
      printf 'error: %s\n' "$line" >&2
    done <<ERRORS
$RM_ERRORS
ERRORS
    return 1
  fi
  if [ "$RM_ITEM_COUNT" -gt 0 ]; then
    printf 'review %s: %s %s declared by author; coverage of review text NOT machine-verified\n' \
      "$RM_URL" "$RM_ITEM_COUNT" "$item_word"
  fi
  return 0
}

rm_poll() {
  local kind_pair kind key alt uncovered=0 url
  rm_load
  [ -z "$RM_ERRORS" ] || return 0
  [ "$RM_ITEM_COUNT" -gt 0 ] || return 0
  rm_parse_table
  while IFS= read -r kind_pair; do
    [ -n "$kind_pair" ] || continue
    kind=$(printf '%s' "$kind_pair" | cut -f1)
    key=$(printf '%s' "$kind_pair" | cut -f2)
    alt=$(printf '%s' "$kind_pair" | cut -f3)
    if rm_item_covered "$kind" "$key" "$alt"; then
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
  [ "$uncovered" -eq 0 ] || printf 'review %s\n' "$url"
  return 0
}

RM_MODE=
RM_WORKTREE=
RM_TIMEOUT=${FM_REVIEW_MANIFEST_TIMEOUT:-15}
case "$RM_TIMEOUT" in
  ''|*[!0-9]*|0) RM_TIMEOUT=15 ;;
esac

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
      --worktree)
        [ "$#" -ge 2 ] || { rm_usage; exit 2; }
        RM_WORKTREE=$2
        shift 2
        ;;
      --timeout)
        [ "$#" -ge 2 ] || { rm_usage; exit 2; }
        case "$2" in ''|*[!0-9]*|0) rm_usage; exit 2 ;; esac
        RM_TIMEOUT=$2
        shift 2
        ;;
      *) rm_usage; exit 2 ;;
    esac
  done
  [ -n "$RM_MODE" ] || { rm_usage; exit 2; }
elif [ "$COMMAND" = poll ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout)
        [ "$#" -ge 2 ] || { rm_usage; exit 2; }
        case "$2" in ''|*[!0-9]*|0) rm_usage; exit 2 ;; esac
        RM_TIMEOUT=$2
        shift 2
        ;;
      *) rm_usage; exit 2 ;;
    esac
  done
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
  exit 0
fi

if [ "$COMMAND" = verify ]; then
  rm_verify
  exit $?
fi
rm_poll
exit 0
