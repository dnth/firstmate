#!/usr/bin/env bash
# Answer Firstmate's Discord decision posts by button, and keep those posts
# showing the outcome.
#
# Usage:
#   fm-ext-decision.sh click --post-id <id> --option <n>|discuss [--key <key>]
#     --guild-id <id> --chat-id <id> --interaction-id <id> --author <id>
#     [--author-name <name>] --secret-file <path> [--confirmed]
#   fm-ext-decision.sh posts [--settled-only]
#   fm-ext-decision.sh finalized --post <stem>
#
# A decision post is an outbox reply that bin/fm-ext-emit.sh published with a
# decision; the gateway poster copies that decision into the post's
# chunk-progress record, state/ext-outbox/<stem>.progress.json, together with
# the Discord ids it posted, whether the last chunk carried buttons, and when.
# The decision itself lives only in Firstmate's ledgers - fm-captain-hold.sh for
# a captain call (hold:<task-id>), the task's status log for a worker's keyed
# decision (key:<task-id>:<slug>). Each post is bound to the lifecycle of its
# decision that was open when it was posted (the decision's occurrence), so a
# re-held call or a reopened key is a different decision to it. This script
# records an answer only through the ledgers and keeps no copy of decision
# state; its own files describe posts: <stem>.settled.json, the outcome line a
# post shows once it is settled; <stem>.finalized, once Discord shows that
# line; and <stem>.notify.json, a recorded answer's request that has not reached
# Firstmate yet.
#
# Outcome lines, where <time> is a Discord timestamp of when this script saw
# the outcome:
#   ✅ <label> chosen by <name> <time>    a click, naming the clicker
#   ✅ <label> chosen by the captain <time>
#                                        an answer recorded on another channel
#                                        that names exactly one option, by a
#                                        standalone number or its label
#   ✅ Decided <time>                    any other recorded answer, including
#                                        one naming several options
#   Closed - no longer needed <time>     closed with no captain answer: the
#                                        task's terminal outcome, moved to a
#                                        captain call, reconciled as moot, gone,
#                                        or a later lifecycle of the same key
#   Replaced by a newer post <time>      a later button post for the same key,
#                                        including one a click just answered
# The answer recorded elsewhere comes from the ledgers through
# fm_ext_decision_key_outcome in bin/fm-ext-lib.sh; a post asks the captain,
# so an answer that names one of its options is shown as the captain's choice.
# The answer text itself is never shown, because it may not be public-safe.
#
# click
#   The gateway plugin runs this for every button click. --post-id is the
#   clicked decision post; --key is the key the button's custom_id carried and
#   must match the post's decision; a confirmation click passes --confirmed and
#   no --key. Checks run in this order, and the first that fails decides the
#   exit code; stdout is always the ephemeral notice the clicker sees.
#     6  no such decision post here: unknown or expired post, another
#        destination, a key that does not match the post, or an unknown option
#     3  not authorised: the author has no <guild>:<channel>:<author> allowlist
#        rule; nothing is recorded (Discuss included)
#     4  no-op: the post already recorded an answer whose request has not
#        reached Firstmate (the click retries only that request), the post is
#        settled, a newer post replaced it, or the ledgers report its own
#        lifecycle closed; a decision found closed also settles the post
#     0  Discuss, on an open decision only: one request through
#        bin/fm-ext-intake.sh --origin button so Firstmate picks the decision
#        up in the thread; nothing is decided, and a repeat click on the same
#        post adds no second request
#     5  confirmation needed: the option needs a second click and --confirmed
#        was not given; prints "Confirm: <label>?" and records nothing
#     0  recorded: under a per-key lock, and only if the post's lifecycle is
#        still open, answers it through `fm-captain-hold.sh answers` (hold:) or
#        `fm-send.sh --resolve-key` (key:, whose own per-key lock also covers
#        typed answers), with who, when, key, option, and any confirmation in
#        the recorded provenance; settles the post with the clicker's outcome
#        line and any older live post of the key as replaced; and sends one
#        request through bin/fm-ext-intake.sh --origin button so Firstmate
#        wakes and acts on the recorded answer. An fm-send verdict that the
#        answer is durable but unconfirmed (exit 4-7, or "do not resend") still
#        counts as recorded, is never resent, and is flagged to Firstmate as
#        delivery "unconfirmed"; a request that fails to reach Firstmate is kept
#        and retried, and the notice says so.
#   Exit 1 means nothing was recorded; exit 2 is bad usage.
#
# posts
#   Prints one JSON line per button post whose outcome Discord does not show
#   yet: {post, channel_id, message_id, content, key, options}. Without
#   --settled-only it first retries every pending request for Firstmate, then
#   settles every unsettled live post that a newer post for the same key
#   replaced, or whose own lifecycle the ledgers report closed.
#
# finalized
#   Marks a post's outcome as shown on Discord, so posts lists it no more.
#
# Post records expire with the bridge retention window, so their buttons
# expire with them. Discord text is untrusted and never reaches a shell
# command: every value here is an id, a key, a number, or text Firstmate wrote.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
# shellcheck source=bin/fm-ext-lib.sh
. "$SCRIPT_DIR/fm-ext-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-ext-decision.sh click --post-id <id> --option <n>|discuss [--key <key>]
         --guild-id <id> --chat-id <id> --interaction-id <id> --author <id>
         [--author-name <name>] --secret-file <path> [--confirmed]
       fm-ext-decision.sh posts [--settled-only]
       fm-ext-decision.sh finalized --post <stem>
EOF
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-ext-decision: %s\n' "$1" >&2; exit "${2:-2}"; }

# notice <exit-code> <text>: the ephemeral reply a clicker sees, then exit.
notice() { printf '%s\n' "$2"; exit "$1"; }

NOT_AUTHORISED="Firstmate: not authorised to answer this decision. Nothing was recorded."
EXPIRED="This decision post is no longer open - this click changed nothing."

OUTBOX=$(fm_ext_outbox_dir)
NOW=${FM_EXT_NOW_OVERRIDE:-$(date +%s)}
case "$NOW" in
  ''|*[!0-9]*) die "could not read the current time" 1 ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required" 1

utc_iso() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# A Discord timestamp renders in each reader's own time zone.
discord_time() { printf '<t:%s:f>' "$1"; }

# Names shown in a public post: no control characters or mention syntax.
safe_name() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177<>@`' | cut -c1-64
}

post_stem_valid() {
  case "$1" in
    *[!0-9a-z.]*|'') return 1 ;;
  esac
  fm_ext_slug_valid "${1%%.*}"
}

# progress_files: every chunk-progress record that belongs to a decision post.
# A plain-text grep keeps the many ordinary reply records out of the jq reads.
progress_files() {
  local file
  [ -d "$OUTBOX" ] && [ ! -L "$OUTBOX" ] || return 0
  while IFS= read -r file; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    printf '%s\n' "$file"
  done < <(find "$OUTBOX" -maxdepth 1 -type f -name '*.progress.json' -print0 2>/dev/null \
    | xargs -0 grep -l -F '"decision"' 2>/dev/null)
}

# post_for_message <message-id>: the stem of the decision post that carries it.
post_for_message() {
  local file
  while IFS= read -r file; do
    if jq -e --arg id "$1" \
      '.decision.key and ((.discord_message_ids // []) | index($id))' "$file" >/dev/null 2>&1; then
      basename "$file" .progress.json
      return 0
    fi
  done < <(progress_files)
  return 1
}

post_field() {  # <stem> <jq filter>
  jq -r "($2) // empty | tostring" "$OUTBOX/$1.progress.json" 2>/dev/null
}

settled() { [ -f "$OUTBOX/$1.settled.json" ]; }
finalized() { [ -f "$OUTBOX/$1.finalized" ]; }
settle_text() { jq -r '.text // empty' "$OUTBOX/$1.settled.json" 2>/dev/null; }

# settle_post <stem> <kind> <text>: the post's outcome line, written once.
settle_post() {
  jq -cn --arg kind "$2" --arg text "$3" --argjson at "$NOW" \
    '{kind:$kind, text:$text, at:$at}' \
    | fm_ext_private_artifact_publish_stdin_once "$OUTBOX" "$1.settled.json" 600
  [ "$?" -le 1 ]
}

# live_posts <key>: unsettled button posts of a key, as "<posted_at>\t<stem>".
live_posts() {
  local file stem
  while IFS= read -r file; do
    stem=$(basename "$file" .progress.json)
    settled "$stem" && continue
    jq -r --arg key "$1" --arg stem "$stem" \
      'select(.decision.key == $key and .buttons == true) | "\(.posted_at // 0)\t\($stem)"' \
      "$file" 2>/dev/null
  done < <(progress_files)
}

# newer_post <stem>: true when a later button post exists for the same key.
newer_post() {
  local stem=$1 key posted file
  key=$(post_field "$stem" '.decision.key')
  posted=$(post_field "$stem" '.posted_at')
  while IFS= read -r file; do
    [ "$(basename "$file" .progress.json)" = "$stem" ] && continue
    if jq -e --arg key "$key" --argjson posted "${posted:-0}" \
      '.decision.key == $key and .buttons == true and ((.posted_at // 0) > $posted)' \
      "$file" >/dev/null 2>&1; then
      return 0
    fi
  done < <(progress_files)
  return 1
}

# answer_option <stem> <answer>: the id of the one option a recorded answer
# names, by a standalone option number or an option label as whole words.
# Every reference counts, so an answer naming two options ("1 or 2", "North,
# not South") names none. Prints nothing unless exactly one option is named.
answer_option() {
  local stem=$1 answer=$2 ids='' word id label
  local -a words
  [ -n "$answer" ] || return 0
  read -r -a words <<< "$(printf '%s' "$answer" | LC_ALL=C tr -c '[:alnum:]' ' ')"
  for word in "${words[@]+"${words[@]}"}"; do
    case "$word" in
      [1-9])
        [ -z "$(post_field "$stem" ".decision.options[] | select(.id == $word) | .label")" ] \
          || ids="$ids$word"$'\n'
        ;;
    esac
  done
  while IFS=$'\t' read -r id label; do
    [ -n "$label" ] || continue
    if printf '%s\n' "$answer" | grep -qiwF -- "$label"; then
      ids="$ids$id"$'\n'
    fi
  done < <(jq -r '.decision.options[] | "\(.id)\t\(.label)"' "$OUTBOX/$stem.progress.json" 2>/dev/null)
  ids=$(printf '%s' "$ids" | sort -u)
  case "$ids" in
    [1-9]) printf '%s\n' "$ids" ;;
  esac
}

# outcome_text <stem> <state> <answer>: the outcome line for a decision found
# closed in the ledgers rather than by a click on this post.
outcome_text() {
  local stem=$1 state=$2 answer=$3 option label
  case "$state" in
    decided)
      option=$(answer_option "$stem" "$answer")
      label=
      [ -z "$option" ] || label=$(post_field "$stem" ".decision.options[] | select(.id == $option) | .label")
      if [ -n "$label" ]; then
        printf '✅ %s chosen by the captain %s' "$label" "$(discord_time "$NOW")"
      else
        printf '✅ Decided %s' "$(discord_time "$NOW")"
      fi
      ;;
    *) printf 'Closed - no longer needed %s' "$(discord_time "$NOW")" ;;
  esac
}

# post_outcome <stem>: the ledger outcome for this post's own lifecycle of its
# decision, as "<state>\t<answer>".
post_outcome() {
  fm_ext_decision_key_outcome "$(post_field "$1" '.decision.key')" "$(post_field "$1" '.decision.occurrence')"
}

# settle_clicked <stem> <option-id> <name>: the clicked post shows the choice;
# every other live post of its key is an older post it replaced, so it shows
# that rather than being read through its own, possibly different, options.
settle_clicked() {
  local stem=$1 option=$2 name=$3 _posted other label
  label=$(post_field "$stem" ".decision.options[] | select(.id == $option) | .label")
  settle_post "$stem" chosen "✅ $label chosen by $name $(discord_time "$NOW")" || return 1
  while IFS=$'\t' read -r _posted other; do
    [ -n "$other" ] && [ "$other" != "$stem" ] || continue
    settle_post "$other" superseded "Replaced by a newer post $(discord_time "$NOW")" || return 1
  done < <(live_posts "$(post_field "$stem" '.decision.key')")
}

lock_key() {  # <key>: serialize answers to one decision across clicks
  local sha waited=0 mtime
  sha=$(printf '%s' "$1" | fm_ext_sha256) || return 1
  LOCK="$OUTBOX/.decision-$sha.lock"
  while ! mkdir "$LOCK" 2>/dev/null; do
    mtime=$(fm_ext_file_mtime "$LOCK" 2>/dev/null) || mtime=$NOW
    if [ $(( $(date +%s) - mtime )) -gt 900 ]; then
      rmdir "$LOCK" 2>/dev/null || true
      continue
    fi
    [ "$waited" -lt 3000 ] || return 1
    sleep 0.2
    waited=$((waited + 1))
  done
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}

# send_request <stem> <request-message-id> <author> <text> <decision-json>:
# one request through the same intake every Discord path uses, at the
# clicker's own authority. The request id is fixed by its caller, so sending
# it again is idempotent.
send_request() {
  local stem=$1 message=$2 author=$3 dir rc request rest guild channel thread
  request=$(post_field "$stem" '.request_id')
  rest=${request#discord:}
  guild=${rest%%:*}
  rest=${rest#*:}
  channel=${rest%%:*}
  rest=${rest#*:}
  thread=${rest%%:*}
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-ext-decision.XXXXXX") || return 1
  printf '%s\n' "$4" > "$dir/text"
  printf '%s\n' "$5" > "$dir/decision.json"
  "$SCRIPT_DIR/fm-ext-intake.sh" \
    --request-id "discord:$guild:$channel:$thread:$message" \
    --guild-id "$guild" --channel-id "$channel" --thread-id "$thread" \
    --message-id "$message" --author "$author" --secret-file "$(fm_ext_secret_path "$FM_HOME")" \
    --text-file "$dir/text" --origin button --decision-file "$dir/decision.json" >/dev/null 2>&1
  rc=$?
  rm -rf -- "$dir"
  return "$rc"
}

# The request telling Firstmate an answer was recorded is written as
# <stem>.notify.json before it is sent and removed once intake accepts it, so
# an answer is never recorded without Firstmate eventually hearing of it: a
# later click on the post and every posts sweep send it again, under the same
# request id, until intake accepts it.
notify_pending() { [ -f "$OUTBOX/$1.notify.json" ]; }

notify_retry() {  # <stem>
  local file="$OUTBOX/$1.notify.json"
  [ -f "$file" ] || return 0
  send_request "$1" "$(jq -r '.message_id' "$file")" "$(jq -r '.author' "$file")" \
    "$(jq -r '.text' "$file")" "$(jq -c '.decision' "$file")" || return 1
  fm_ext_private_artifact_remove "$OUTBOX" "$1.notify.json" 600
}

notify_answer() {  # <stem> <message-id> <author> <text> <decision-json>
  jq -cn --arg message_id "$2" --arg author "$3" --arg text "$4" --argjson decision "$5" \
    '{message_id:$message_id, author:$author, text:$text, decision:$decision}' \
    | fm_ext_private_artifact_publish_stdin "$OUTBOX" "$1.notify.json" 600 || return 1
  notify_retry "$1"
}

command_click() {
  local key='' confirmed=0 stem request rest state label needs_confirm prompt name
  local task slug mode when audit out via choice_json outcome rc delivery err recorded
  POST_ID='' OPTION='' GUILD_ID='' CHAT_ID='' INTERACTION_ID='' AUTHOR='' SECRET_FILE='' name=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --post-id) shift; POST_ID=${1:-} ;;
      --option) shift; OPTION=${1:-} ;;
      --key) shift; key=${1:-} ;;
      --guild-id) shift; GUILD_ID=${1:-} ;;
      --chat-id) shift; CHAT_ID=${1:-} ;;
      --interaction-id) shift; INTERACTION_ID=${1:-} ;;
      --author) shift; AUTHOR=${1:-} ;;
      --author-name) shift; name=${1:-} ;;
      --secret-file) shift; SECRET_FILE=${1:-} ;;
      --confirmed) confirmed=1 ;;
      *) usage; exit 2 ;;
    esac
    shift || true
  done
  [ -n "$POST_ID" ] && [ -n "$OPTION" ] && [ -n "$GUILD_ID" ] && [ -n "$CHAT_ID" ] \
    && [ -n "$INTERACTION_ID" ] && [ -n "$AUTHOR" ] && [ -n "$SECRET_FILE" ] \
    || { usage; exit 2; }
  case "$POST_ID$GUILD_ID$CHAT_ID$INTERACTION_ID$AUTHOR" in
    *[!0-9]*) die "post, guild, chat, interaction, and author must be Discord ids" ;;
  esac
  case "$OPTION" in
    [1-9]|discuss) ;;
    *) die "option must be 1-9 or discuss" ;;
  esac
  [ -z "$key" ] || fm_ext_decision_key_valid "$key" || die "malformed decision key"
  name=$(safe_name "$name")
  [ -n "$name" ] || name="Discord user $AUTHOR"

  fm_ext_active "$FM_HOME" || die "local ext-bridge is not active" 1
  fm_ext_secret_matches "$(fm_ext_secret_path "$FM_HOME")" "$SECRET_FILE" \
    || die "presented secret does not match the home secret" 1

  stem=$(post_for_message "$POST_ID") || notice 6 "$EXPIRED"
  request=$(post_field "$stem" '.request_id')
  fm_ext_request_id_valid "$request" || notice 6 "$EXPIRED"
  rest=${request#discord:}
  [ "${rest%%:*}" = "$GUILD_ID" ] || notice 6 "$EXPIRED"
  rest=${rest#*:}
  CHANNEL=${rest%%:*}
  rest=${rest#*:}
  [ "${rest%%:*}" = "$CHAT_ID" ] || notice 6 "$EXPIRED"
  DECISION_KEY=$(post_field "$stem" '.decision.key')
  fm_ext_decision_key_valid "$DECISION_KEY" || notice 6 "$EXPIRED"
  [ -z "$key" ] || [ "$key" = "$DECISION_KEY" ] || notice 6 "$EXPIRED"

  [ "$(fm_ext_authority "$(fm_ext_allowlist_path "$FM_HOME")" "$GUILD_ID" "$CHANNEL" "$AUTHOR")" = standing ] \
    || notice 3 "$NOT_AUTHORISED"

  # An answer this post recorded earlier whose request never reached Firstmate:
  # any click retries that request and nothing else.
  if notify_pending "$stem"; then
    if notify_retry "$stem"; then
      notice 4 "Already decided: $(settle_text "$stem"). Firstmate has it now; this click changed nothing else."
    fi
    notice 4 "Already decided: $(settle_text "$stem"). Firstmate has not been told yet and keeps retrying; this click changed nothing else."
  fi

  # Stale, replaced, superseded, and already-decided posts answer nothing,
  # Discuss included.
  if settled "$stem"; then
    notice 4 "Already decided: $(settle_text "$stem") - this click changed nothing."
  fi
  if newer_post "$stem"; then
    settle_post "$stem" superseded "Replaced by a newer post $(discord_time "$NOW")" || true
    notice 4 "A newer post replaced this decision - use that one. This click changed nothing."
  fi
  outcome=$(post_outcome "$stem")
  state=${outcome%%$'\t'*}
  case "$state" in
    open) ;;
    unknown) die "could not read whether the decision is still open" 1 ;;
    *)
      settle_post "$stem" "$state" "$(outcome_text "$stem" "$state" "${outcome#*$'\t'}")" || true
      notice 4 "Already decided: $(settle_text "$stem") - this click changed nothing."
      ;;
  esac

  if [ "$OPTION" = discuss ]; then
    choice_json=$(jq -cn --arg key "$DECISION_KEY" --arg text "$(post_field "$stem" '.decision.text')" \
      --arg by "$name" --arg at "$(utc_iso "$NOW")" \
      '{key:$key, choice:"discuss", text:$text, by:$by, at:$at}') || die "could not build the request" 1
    # Keyed by the post, so a double click is one request.
    send_request "$stem" "$POST_ID" "$AUTHOR" \
      "Discuss requested on a decision post: talk it through before anything is decided." \
      "$choice_json" || die "could not record the Discuss request" 1
    notice 0 "Firstmate will pick this up in the thread. Nothing was decided."
  fi

  label=$(post_field "$stem" ".decision.options[] | select(.id == $OPTION) | .label")
  [ -n "$label" ] || notice 6 "$EXPIRED"
  needs_confirm=$(post_field "$stem" ".decision.options[] | select(.id == $OPTION) | .confirm")
  prompt="Confirm: $label?"
  if [ "$needs_confirm" = true ] && [ "$confirmed" = 0 ]; then
    notice 5 "$prompt"
  fi

  lock_key "$DECISION_KEY" || die "another answer to this decision is still being recorded" 1
  # A click that waited on the lock re-reads what the winner recorded.
  if settled "$stem"; then
    notice 4 "Already decided: $(settle_text "$stem") - this click changed nothing."
  fi
  outcome=$(post_outcome "$stem")
  state=${outcome%%$'\t'*}
  case "$state" in
    open) ;;
    unknown) die "could not read whether the decision is still open" 1 ;;
    *)
      settle_post "$stem" "$state" "$(outcome_text "$stem" "$state" "${outcome#*$'\t'}")" || true
      notice 4 "Already decided: $(settle_text "$stem") - this click changed nothing."
      ;;
  esac

  when=$(utc_iso "$NOW")
  audit="Discord button: option $OPTION \"$label\" chosen by $name ($AUTHOR) at $when for $DECISION_KEY"
  [ "$confirmed" = 0 ] || audit="$audit, confirmed by clicking \"$prompt\""
  task=$(fm_ext_decision_key_task "$DECISION_KEY")
  delivery=confirmed
  recorded=0
  case "$DECISION_KEY" in
    hold:*)
      mode=$(post_field "$stem" '.decision.mode')
      out=$(printf '%s\t%s\t%s\t%s\n' "$task" "$label" "$OPTION. $label" "${mode:-done}" \
        | "$SCRIPT_DIR/fm-captain-hold.sh" answers --source "$audit" 2>&1)
      case "$out" in
        *"closed: $task"*) recorded=1 ;;
      esac
      via="fm-captain-hold.sh answers"
      ;;
    key:*)
      slug=${DECISION_KEY##*:}
      err=$("$SCRIPT_DIR/fm-send.sh" "$task" --resolve-key "$slug" \
        "Decision answer: $label ($audit)" 2>&1 >/dev/null)
      rc=$?
      if [ "$rc" = 0 ]; then
        recorded=1
      else
        case "$rc:$err" in
          # fm-send's durable-but-unconfirmed verdicts: the worker's copy may
          # already be on its way, so the answer stands and is never resent.
          4:*|5:*|6:*|7:*|*[Dd]o\ not\ resend*) recorded=1; delivery=unconfirmed ;;
        esac
      fi
      via="fm-send.sh --resolve-key"
      ;;
  esac
  if [ "$recorded" = 0 ]; then
    # Nothing was delivered. Another channel may have answered in between.
    outcome=$(post_outcome "$stem")
    state=${outcome%%$'\t'*}
    case "$state" in
      decided|superseded)
        settle_post "$stem" "$state" "$(outcome_text "$stem" "$state" "${outcome#*$'\t'}")" || true
        notice 4 "Already decided: $(settle_text "$stem") - this click changed nothing."
        ;;
    esac
    die "the decision did not record the answer; nothing was decided: $(printf '%s' "${err:-${out:-}}" | tail -n 3 | tr '\n' ' ')" 1
  fi

  # From here the answer stands, so nothing below may report it as unrecorded.
  settle_clicked "$stem" "$OPTION" "$name" \
    || printf 'fm-ext-decision: recorded, but a post could not be settled\n' >&2
  choice_json=$(jq -cn --arg key "$DECISION_KEY" --argjson option_id "$OPTION" \
    --arg option "$label" --arg text "$(post_field "$stem" '.decision.text')" \
    --argjson confirmed "$([ "$confirmed" = 1 ] && echo true || echo false)" \
    --arg prompt "$prompt" --arg via "$via" --arg delivery "$delivery" \
    --arg by "$name" --arg at "$when" \
    '{key:$key, choice:"option", option_id:$option_id, option:$option, text:$text,
      confirmed:$confirmed, recorded_via:$via, delivery:$delivery, by:$by, at:$at}
     + if $confirmed then {confirm_prompt:$prompt} else {} end') || choice_json=
  out="Decision answered by button: $label"
  [ "$confirmed" = 0 ] || out="$out (confirmed)"
  if [ -z "$choice_json" ] || ! notify_answer "$stem" "$INTERACTION_ID" "$AUTHOR" "$out" "$choice_json"; then
    notice 0 "Recorded: $label. Firstmate has not been told yet and keeps retrying; there is no need to click again."
  fi
  if [ "$delivery" = unconfirmed ]; then
    notice 0 "Recorded: $label. Its delivery to the worker is not confirmed yet, so Firstmate will follow up; there is no need to click again."
  fi
  notice 0 "Recorded: $label. Firstmate has it."
}

command_posts() {
  local settled_only=0 file stem outcome state thread
  [ "${1:-}" != --settled-only ] || settled_only=1
  while IFS= read -r file; do
    stem=$(basename "$file" .progress.json)
    # A recorded answer whose request has not reached Firstmate yet is sent
    # again on every sweep until intake accepts it.
    if [ "$settled_only" = 0 ] && notify_pending "$stem"; then
      notify_retry "$stem" || printf 'fm-ext-decision: Firstmate still has not been told about post %s\n' "$stem" >&2
    fi
    finalized "$stem" && continue
    jq -e '.decision.key and .buttons == true' "$file" >/dev/null 2>&1 || continue
    if ! settled "$stem"; then
      [ "$settled_only" = 0 ] || continue
      if newer_post "$stem"; then
        settle_post "$stem" superseded "Replaced by a newer post $(discord_time "$NOW")" || continue
      else
        outcome=$(post_outcome "$stem") || continue
        state=${outcome%%$'\t'*}
        case "$state" in
          decided|superseded)
            settle_post "$stem" "$state" "$(outcome_text "$stem" "$state" "${outcome#*$'\t'}")" || continue
            ;;
          *) continue ;;
        esac
      fi
    fi
    thread=$(post_field "$stem" '.request_id')
    thread=${thread#discord:*:*:}
    thread=${thread%%:*}
    jq -cn --arg post "$stem" --arg channel "$thread" \
      --arg message "$(post_field "$stem" '.discord_message_ids[-1]')" \
      --arg content "$(settle_text "$stem")" \
      --slurpfile progress "$file" \
      '{post:$post, channel_id:$channel, message_id:$message, content:$content,
        key:$progress[0].decision.key, options:$progress[0].decision.options}'
  done < <(progress_files)
}

command_finalized() {
  local stem=''
  [ "${1:-}" = --post ] && stem=${2:-}
  post_stem_valid "$stem" || die "finalized needs --post <stem>"
  [ -f "$OUTBOX/$stem.progress.json" ] || die "no such post: $stem" 1
  printf '%s\n' "$NOW" | fm_ext_private_artifact_publish_stdin_once "$OUTBOX" "$stem.finalized" 600
  [ "$?" -le 1 ] || die "could not mark the post finalized" 1
}

case "${1:-}" in
  click) shift; command_click "$@" ;;
  posts) shift; command_posts "$@" ;;
  finalized) shift; command_finalized "$@" ;;
  --help|-h) help ;;
  *) usage; exit 2 ;;
esac
