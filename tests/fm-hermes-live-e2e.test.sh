#!/usr/bin/env bash
# Opt-in credentialed Hermes mechanics verification.
#
# This does not call fm-spawn or any runtime backend. It gives the real Hermes
# CLI a temporary isolated profile containing copies of the current config and
# OpenAI Codex auth, installs Firstmate's hook only in that profile, then proves
# top-level -z exit, lifecycle notification, and same-session resume through the
# v0.20.0 quiet chat path.
set -u

if [ "${FM_HERMES_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERMES_LIVE_E2E=1 to run the Hermes mechanics verification"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERMES_BIN=$(command -v hermes) || fail "Hermes executable not found"
REAL_HERMES_HOME=${HERMES_HOME:-${HOME:-}/.hermes}
[ -f "$REAL_HERMES_HOME/config.yaml" ] || fail "Hermes config is missing"
[ -f "$REAL_HERMES_HOME/auth.json" ] || fail "Hermes OpenAI Codex auth store is missing"

LAB=$(fm_test_tmproot fm-hermes-live-e2e)
PROFILE="$LAB/hermes-home"
STATE="$LAB/state"
WORKSPACE="$LAB/workspace"
mkdir -p "$PROFILE/skills/fm-proof" "$STATE" "$WORKSPACE"
chmod 0700 "$PROFILE" "$STATE" "$WORKSPACE"
cp "$REAL_HERMES_HOME/config.yaml" "$PROFILE/config.yaml"
cp "$REAL_HERMES_HOME/auth.json" "$PROFILE/auth.json"
chmod 0600 "$PROFILE/config.yaml" "$PROFILE/auth.json"
printf '%s\n' \
  '---' \
  'name: fm-proof' \
  'description: Prove headless skill preloading.' \
  '---' \
  '# Proof skill' \
  'Reply exactly HERMES-SKILL-OK and do not use tools.' \
  > "$PROFILE/skills/fm-proof/SKILL.md"

HERMES_HOME="$PROFILE" HERMES_BIN="$HERMES_BIN" \
  "$ROOT/bin/fm-hermes-turnend-hook.sh" install \
  || fail "isolated Hermes lifecycle-hook install failed"

GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" manual-hermes) \
  || fail "could not arm isolated Hermes busy state"
TOKEN=fm.manualtest01
jq -n \
  --arg turnend "$STATE/manual-hermes.turn-ended" \
  --arg session_file "$STATE/manual-hermes.hermes-session" \
  --arg started "$STATE/manual-hermes.hermes-started" \
  --arg root "$ROOT" \
  --arg state "$STATE" \
  --arg id manual-hermes \
  --arg gen "$GEN" \
  '{turnend:$turnend,session_file:$session_file,started:$started,root:$root,state:$state,id:$id,gen:$gen}' \
  > "$PROFILE/fm-turn-end.d/$TOKEN"
printf 'token=%s\n' "$TOKEN" > "$WORKSPACE/.fm-hermes-turnend"

HERMES_VERSION=$("$HERMES_BIN" --version | head -1)
# shellcheck disable=SC2016 # These are display-only exact command templates.
ONESHOT_COMMAND='HERMES_HOME="$PROFILE" hermes -z "Remember RESUME-CONTEXT-824 for the next turn and print exactly OK" --provider openai-codex --model gpt-5.6-sol --reasoning low --accept-hooks --yolo --pass-session-id'
printf 'command: %s\n' "$ONESHOT_COMMAND"
(
  cd "$WORKSPACE" || exit 1
  HERMES_HOME="$PROFILE" "$HERMES_BIN" -z \
    "Remember RESUME-CONTEXT-824 for the next turn and print exactly OK" \
    --provider openai-codex --model gpt-5.6-sol --reasoning low \
    --accept-hooks --yolo --pass-session-id
) > "$LAB/oneshot.out" 2> "$LAB/oneshot.err" \
  || fail "Hermes -z mechanics probe failed: $(tail -10 "$LAB/oneshot.err")"
grep -Fx 'OK' "$LAB/oneshot.out" >/dev/null \
  || fail "Hermes -z did not print exactly OK: $(tr '\n' ' ' < "$LAB/oneshot.out")"
assert_present "$STATE/manual-hermes.turn-ended" "Hermes -z did not fire on_session_end"
assert_present "$STATE/manual-hermes.hermes-started" "Hermes -z did not fire on_session_start"
assert_present "$STATE/manual-hermes.hermes-session" "Hermes -z did not publish its session id"
SESSION_ID=$(cat "$STATE/manual-hermes.hermes-session")
BUSY=$(bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux unused hermes manual-hermes "$2"' _ "$ROOT" "$STATE")
[ "$BUSY" = 'idle hermes-hook' ] || fail "Hermes -z lifecycle did not settle idle: $BUSY"
printf 'output: exit=0 stdout=%s turn_end=touched session=present started=touched busy=%s\n' \
  "$(tr '\n' ' ' < "$LAB/oneshot.out" | sed 's/[[:space:]]*$//')" "$BUSY"

rm -f "$STATE/manual-hermes.turn-ended" "$STATE/manual-hermes.hermes-started"
# shellcheck disable=SC2016 # These are display-only exact command templates.
RESUME_COMMAND='HERMES_HOME="$PROFILE" hermes chat -Q --query "Print only the token I asked you to remember" --resume "$SESSION_ID" --no-restore-cwd --provider openai-codex --model gpt-5.6-sol --reasoning low --accept-hooks --yolo --pass-session-id'
printf 'command: %s\n' "$RESUME_COMMAND"
(
  cd "$WORKSPACE" || exit 1
  HERMES_HOME="$PROFILE" "$HERMES_BIN" chat -Q --query \
    "Print only the token I asked you to remember" \
    --resume "$SESSION_ID" --no-restore-cwd \
    --provider openai-codex --model gpt-5.6-sol --reasoning low \
    --accept-hooks --yolo --pass-session-id
) > "$LAB/resume.out" 2> "$LAB/resume.err" \
  || fail "Hermes resume mechanics probe failed: $(tail -10 "$LAB/resume.err")"
grep -Fx 'RESUME-CONTEXT-824' "$LAB/resume.out" >/dev/null \
  || fail "Hermes resume did not retain context: $(tr '\n' ' ' < "$LAB/resume.out")"
[ "$(cat "$STATE/manual-hermes.hermes-session")" = "$SESSION_ID" ] \
  || fail "Hermes resume changed the stable session id"
assert_present "$STATE/manual-hermes.turn-ended" "Hermes resume did not fire on_session_end"
assert_present "$STATE/manual-hermes.hermes-started" "Hermes resume did not fire pre_llm_call"
printf 'output: exit=0 stdout=%s same_session=yes turn_end=touched started=touched\n' \
  "$(tr '\n' ' ' < "$LAB/resume.out" | sed 's/[[:space:]]*$//')"

# shellcheck disable=SC2016 # These are display-only exact command templates.
SKILL_COMMAND='HERMES_HOME="$PROFILE" hermes chat -Q --query "Apply the preloaded skill" --skills fm-proof --provider openai-codex --model gpt-5.6-sol --reasoning low --accept-hooks --yolo --pass-session-id'
printf 'command: %s\n' "$SKILL_COMMAND"
(
  cd "$WORKSPACE" || exit 1
  HERMES_HOME="$PROFILE" "$HERMES_BIN" chat -Q --query \
    "Apply the preloaded skill" --skills fm-proof \
    --provider openai-codex --model gpt-5.6-sol --reasoning low \
    --accept-hooks --yolo --pass-session-id
) > "$LAB/skill.out" 2> "$LAB/skill.err" \
  || fail "Hermes skill-preload mechanics probe failed: $(tail -10 "$LAB/skill.err")"
grep -Fx 'HERMES-SKILL-OK' "$LAB/skill.out" >/dev/null \
  || fail "Hermes did not apply the preloaded skill: $(tr '\n' ' ' < "$LAB/skill.out")"
printf 'output: exit=0 stdout=%s skill_preload=applied\n' \
  "$(tr '\n' ' ' < "$LAB/skill.out" | sed 's/[[:space:]]*$//')"
printf 'ok - %s isolated mechanics: -z exit, lifecycle hook, same-session quiet resume, and skill preload\n' "$HERMES_VERSION"
