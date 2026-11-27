#!/usr/bin/env bash
# fm-ext-thread-judge.sh - ask Jev to judge one Communication Officer topic
# thread's status and whether its name still fits the conversation.
#
# Usage:
#   fm-ext-thread-judge.sh --state-file <json>
#   fm-ext-thread-judge.sh --check
#
# --check is the one "is judging on" test the gateway asks. It prints one word
# and exits 0: "inactive" when the local ext-bridge is not active, "on" when
# the shared Jev key gate in bin/fm-jev-lib.sh finds a key, "off" when the key
# is confirmed absent, and "unknown" when the home's .env cannot be read.
# It makes no network call and reads no state file.
#
# Input file (message text and the judged reply's own declared state; no
# attachments, images, filenames, or Discord ids):
#   {"thread": {"name": "<current base name, marker stripped>",
#               "project": "<Project or empty>",
#               "reply_state": "needs-you|done|none",
#               "messages": [{"role": "firstmate|captain|participant",
#                             "text": "...",
#                             "reply": 1}]}}
# reply_state is optional: it is the thread state the judged reply itself
# declared, and it is omitted when the reply declared no state.
# reply is a request-local integer shared by the chunks of one Firstmate
# reply. A message without it stands alone.
# This tool adds nothing but the two questions below and never reads Discord.
#
# Output (stdout, one JSON object, exit 0):
#   {"status": "open-question|running|done|blocked",
#    "confidence": 0.0-1.0,
#    "topic_fits": true|false}
# status is one Choice and confidence is the model's own for that choice;
# topic_fits is a Noul thresholded at 0.5 by
# TOPIC_FIT_THRESHOLD in this script, so code - never prose - decides the bool.
#
# Opt-in and transport: bin/fm-jev-lib.sh owns the TYPESAFE_API_KEY gate,
# endpoint, model, timeout, and POST. Exit 2 when the key is absent, so a
# caller can treat that as "off" rather than a failure; exit 1 on any HTTP,
# transport, or answer-shape failure, with one reason on stderr.
# docs/configuration.md "Thread title reconciler" owns when callers ask.
set -u

unset _FM_JEV_KEY TYPESAFE_API_KEY_PRIVATE
_FM_JEV_KEY=${TYPESAFE_API_KEY:-}
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"

TOPIC_FIT_THRESHOLD=0.5

usage() {
  echo "usage: fm-ext-thread-judge.sh --state-file <json> | --check" >&2
}

die() {
  printf 'fm-ext-thread-judge: %s\n' "$1" >&2
  exit 1
}

helptext() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

STATE_FILE='' CHECK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --state-file) shift; STATE_FILE=${1:-} ;;
    --check) CHECK=1 ;;
    --help|-h) helptext; exit 0 ;;
    *) usage; exit 2 ;;
  esac
  shift || true
done
if [ "$CHECK" = 1 ]; then
  if ! fm_ext_active "$FM_HOME"; then
    echo inactive
    exit 0
  fi
  fm_jev_load_key
  case "$FM_JEV_KEY_STATE" in
    present) echo on ;;
    absent) echo off ;;
    *) echo unknown ;;
  esac
  exit 0
fi
[ -n "$STATE_FILE" ] || { usage; exit 2; }
[ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || die "state file not found: $STATE_FILE"
command -v jq >/dev/null 2>&1 || die "jq required"

fm_ext_active "$FM_HOME" || die "local ext-bridge is not active"
fm_jev_load_key
fm_jev_available || { printf 'fm-ext-thread-judge: off (TYPESAFE_API_KEY absent)\n' >&2; exit 2; }

WORK=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
RESPONSE="$WORK/response.json"

REQUEST=$(jq -n --slurpfile state "$STATE_FILE" --arg model "$FM_JEV_MODEL" '
  ($state[0]) as $s |
  {
    model: $model,
    state: {thread: $s.thread},
    questions: {
      status: {
        type: "choice",
        instructions: "What is the current status of the work described in `thread.messages`, read from its newest reply? Messages that share a non-empty `reply` value are chunks of one Firstmate reply that Discord split; judge the newest reply with all its chunks read together as one message. A message without a `reply` value stands alone.",
        criteria: {
          "open-question": "The newest reply needs the captain to answer, decide, or approve something before the work in this thread can proceed. This applies even if it reports a completed step or has no question mark, as in `I merged the change. Production deployment needs your approval before I can proceed`. A reply that closes out the work and only notes a pending approval, an external gate, a recorded decision, or a deferred item has no such dependency.",
          running: "The newest reply leaves work open and says it is under way or queued. The work can proceed without a response, decision, or approval from the captain, and remains under way or queued without an obstacle stopping it.",
          done: "The newest reply closes the work in this thread, and no response, decision, or approval from the captain is required for that work to proceed. A completed step such as a merge or handoff qualifies only if it closes the work in this thread. Work that remains under way, queued, or stopped by an obstacle is still open. Apply both conditions regardless of `thread.reply_state`. This includes a closing reply that only notes a pending approval, an external gate, a recorded decision, or a deferred item.",
          blocked: "The newest reply leaves work open and stopped because it failed or is waiting on an external dependency, permission, credential, or other obstacle. Continuing the work does not require a response, decision, or approval from the captain."
        }
      },
      topic_fits: {
        type: "noul",
        instructions: "Does `thread.name` still name the topic the team is working on in `thread.messages`?",
        criteria: {
          true: "The name still describes the main subject, task, or problem in the conversation, even if the details moved on.",
          false: "The conversation has moved to a different subject, task, or problem, so the name now describes something the thread is no longer about."
        }
      }
    }
  }') || die "could not build the Jev request"

read -r HTTP LAT_MS <<< "$(fm_jev_post "$RESPONSE" <<< "$REQUEST")"
[ "$HTTP" = 200 ] || die "http $HTTP after ${LAT_MS} ms"

jq -ce --argjson threshold "$TOPIC_FIT_THRESHOLD" '
  def statuses: ["open-question", "running", "done", "blocked"];
  (.answers.status.choice) as $choice |
  if
    (.answers.status | type) == "object" and
    .answers.status.type == "choice" and
    ($choice | type) == "string" and
    (statuses | index($choice)) != null and
    (.answers.status.confidence | type) == "number" and
    .answers.status.confidence >= 0 and .answers.status.confidence <= 1 and
    (.answers.status.probabilities | type) == "object" and
    ((.answers.status.probabilities | keys | sort) == (statuses | sort)) and
    all(.answers.status.probabilities[]; type == "number" and . >= 0 and . <= 1) and
    (.answers.topic_fits | type) == "object" and
    .answers.topic_fits.type == "noul" and
    (.answers.topic_fits.noul | type) == "number" and
    .answers.topic_fits.noul >= 0 and .answers.topic_fits.noul <= 1
  then
    {
      status: $choice,
      confidence: .answers.status.confidence,
      topic_fits: (.answers.topic_fits.noul >= $threshold)
    }
  else empty end
' "$RESPONSE" || die "response is not a status Choice plus topic Noul answer"
