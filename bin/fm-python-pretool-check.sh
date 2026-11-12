#!/usr/bin/env bash
# Stable PreToolUse transport for the Python runner guard command policy.
#
# The rule is "Python runs through uv everywhere, never bare python3". This
# seatbelt denies bare Python interpreter invocations, pip installs, pipx
# runs/installs, and virtualenv invocations in the PRIMARY firstmate shell
# before they run, and names the uv replacement.
# bin/fm-python-command-policy.mjs is the sole owner of the block/allow
# decision; it reuses the shell classifier owned by
# bin/fm-arm-command-policy.mjs. This wrapper only requires the local opt-in
# file, scopes the guard to the real primary checkout, acquires the harness
# payload, invokes that policy, and renders the established harness responses.
# It never executes, sources, evaluates, or expands the command.
# See docs/python-guard.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-python-pretool-check.sh
#   bin/fm-python-pretool-check.sh --command '<cmd>'
#
# Stdin mode extracts .toolInput.command for Grok or .tool_input.command for
# Claude and Codex. CLI mode is used by OpenCode, Pi, and OMP after their adapters
# extract the exact command string.
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - opt-in absent, or not the real primary checkout (a crewmate/scout
#           task worktree or a non-firstmate repo): exit 0 with no output.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport,
#               missing Node or policy owner, or an invalid policy response.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode, Pi, and OMP consume exit 2 plus stderr.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-python-pretool-check.sh [--command <cmd>] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Fires only when the effective home's config/python-runner opt-in file names uv,
and only in the real primary firstmate checkout; it is a silent no-op
otherwise.
Exits 0 to allow and 2 to deny bare Python tooling that must run through uv.
The deny reason is written to stderr, with a Grok decision object on stdout
unless --claude is supplied.
Malformed transport and an unavailable classifier runtime fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

# Strict-superset prefilter (transport only; owns zero classification
# semantics). Strip syntax bytes that the classifier joins within a shell word
# before looking for python/pip/virtualenv, so ordinary quoted or escaped
# fragments cannot hide a bare invocation from the policy owner. A
# quoting-decoder marker - a $ immediately followed by a single quote (ANSI-C
# $'...') or a double quote (bash locale $"...") - delegates too, because the
# classifier decodes those and can reconstruct a bare command from bytes this
# substring test cannot see. This marker set is COUPLED to the classifier's
# decoder set in bin/fm-arm-command-policy.mjs: adding any new quote/expansion
# form the classifier decodes REQUIRES extending it here in the same change, or
# the prefilter stops being a strict superset. Deliberate deeper obfuscation is
# out of scope by the same agent-mistake threat model the policy uses.
PREFILTER=$CMD
PREFILTER=${PREFILTER//\\/}
PREFILTER=${PREFILTER//\"/}
PREFILTER=${PREFILTER//\'/}
PREFILTER=${PREFILTER//$'\n'/}
PREFILTER=${PREFILTER//$'\r'/}
case "$CMD" in
  *"\$'"*|*'$"'*) ;;
  *)
    case "$PREFILTER" in
      *python*|*pip*|*virtualenv*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
ACTIVE_HOME=${FM_HOME:-$FM_ROOT}
CONFIG_DIR=${FM_CONFIG_OVERRIDE:-$ACTIVE_HOME/config}

# Scope to a plain, non-worktree firstmate checkout, where git-dir equals
# git-common-dir. A crewmate/scout task worktree - the shape bin/fm-spawn.sh
# always hands out - is a linked git worktree where the two differ. This guard
# does not inspect .fm-secondmate-home, so it applies in a git-cloned secondmate
# home but remains inert when the secondmate home is itself a treehouse-leased
# linked worktree. docs/python-guard.md owns this scope. Any failure to confirm
# the primary is inert (exit 0), never a block, so a broken environment never
# denies a shell command.
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0

# Opt-in: a private, gitignored config file in the effective home. Its only
# recognized value is `uv`; anything else (or an absent file) leaves the guard
# inert, so the shared template imposes nothing on other users.
OPT_IN="$CONFIG_DIR/python-runner"
[ -f "$OPT_IN" ] || exit 0
OPT_IN_VALUE=$(tr -d '[:space:]' < "$OPT_IN" 2>/dev/null) || exit 0
[ "$OPT_IN_VALUE" = "uv" ] || exit 0

POLICY="$FM_ROOT/bin/fm-python-command-policy.mjs"
command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0

POLICY_OUTPUT=$(node "$POLICY" --command "$CMD" 2>/dev/null) || exit 0
[ -n "$POLICY_OUTPUT" ] || exit 0

TAB=$(printf '\t')
DECISION=${POLICY_OUTPUT%%"$TAB"*}
[ "$DECISION" = "deny" ] || exit 0
REST=${POLICY_OUTPUT#*"$TAB"}
[ "$REST" != "$POLICY_OUTPUT" ] || exit 0
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

DETAIL="[$CODE] $REASON"
ESCAPED=$(json_escape "$DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
