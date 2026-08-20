#!/usr/bin/env bash
# Opt-in real OMP max-time deadline guard.
set -u

if [ "${FM_OMP_MAX_TIME_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_MAX_TIME_LIVE_E2E=1 to run the real OMP max-time deadline guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || fail "OMP max-time live guard requires jq"
OMP_BIN=$("$ROOT/bin/fm-omp-capabilities.sh" --require-max-time --print-binary) || fail "OMP capability check failed"
OMP_VERSION=$("$OMP_BIN" --version 2>&1 | head -1) || fail "OMP version probe failed for $OMP_BIN"
[ -n "$OMP_VERSION" ] || fail "OMP version probe returned no version"
TMP_ROOT=$(fm_test_tmproot fm-omp-max-time-live)
EVENTS="$TMP_ROOT/events.jsonl"
STDERR_LOG="$TMP_ROOT/stderr.log"
MODEL=${FM_OMP_MAX_TIME_LIVE_MODEL:-openai-codex/gpt-5.6-luna}

started=$(date +%s)
OMP_SKIP_SETUP=1 "$OMP_BIN" --model "$MODEL" --thinking low --no-session --no-tools \
  --max-time=5 --mode=json 'Write an exhaustive response of at least ten thousand words about Unix history.' \
  > "$EVENTS" 2> "$STDERR_LOG"
status=$?
elapsed=$(($(date +%s) - started))
expect_code 0 "$status" "OMP $OMP_VERSION max-time session should terminate cleanly"
[ "$elapsed" -ge 5 ] && [ "$elapsed" -le 15 ] \
  || fail "OMP $OMP_VERSION max-time session elapsed ${elapsed}s outside the 5-15s bound"
jq -se '
  any(.[]; .type == "agent_start")
  and any(.[]; .type == "message_start" and .message.role == "user")
  and (.[-1].type == "agent_end" and .[-1].isTerminal == true)
  and ([.[] | select(.type == "message_end" and .message.role == "assistant")] as $assistant
    | any($assistant[]; .message.stopReason == "aborted" and .message.errorMessage == "Deadline exceeded")
      and all($assistant[]; .message.stopReason != "error"))
' "$EVENTS" >/dev/null \
  || fail "OMP $OMP_VERSION did not publish an active deadline-terminated session"
deadline_evidence=$(jq -sr '
  first(.[] | select(
    .type == "message_end"
    and .message.role == "assistant"
    and .message.stopReason == "aborted"
    and .message.errorMessage == "Deadline exceeded"
  ))
  | "stopReason=\(.message.stopReason) errorMessage=\(.message.errorMessage)"
' "$EVENTS") || fail "OMP $OMP_VERSION deadline evidence could not be rendered"
[ -n "$deadline_evidence" ] || fail "OMP $OMP_VERSION deadline evidence was empty"

printf 'evidence: OMP %s max-time=5 elapsed=%ss %s\n' "$OMP_VERSION" "$elapsed" "$deadline_evidence"
pass "OMP $OMP_VERSION aborts an active session within the 5-15s deadline bound"
