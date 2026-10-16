#!/usr/bin/env bash
# Turn Discord decision-button clicks into requests for Firstmate, and keep
# decision posts showing their outcome.
#
# Usage:
#   fm-ext-decision.sh click --post-id <id> --option <n>|discuss [--key <key>]
#     --guild-id <id> --chat-id <id> --interaction-id <id> --author <id>
#     [--author-name <name>] --secret-file <path> [--confirmed]
#   fm-ext-decision.sh posts [--settled-only]
#   fm-ext-decision.sh threads [--thread <id>]
#   fm-ext-decision.sh finalized --post <stem> --content-file <path>
#   fm-ext-decision.sh still-open --key <key> --occurrence <occurrence>
#
# A decision post is an outbox reply that bin/fm-ext-emit.sh published with a
# decision; the gateway poster copies that decision into the post's
# chunk-progress record, state/ext-outbox/<stem>.progress.json, together with
# the Discord ids it posted, whether the last chunk carried buttons, and when.
# The decision itself lives only in Firstmate's ledgers - fm-captain-hold.sh for
# a captain call (hold:<task-id>), the task's status log for a worker's keyed
# decision (key:<task-id>:<slug>) - and only Firstmate records an answer there,
# through its normal path. A click never records anything: it files a request,
# exactly like a typed reply to the post, and Firstmate decides whether and how
# to record it. Each post is bound to the lifecycle of its decision that was
# open when it was posted (the decision's occurrence), so a re-held call or a
# reopened key is a different decision to it.
#
# This script keeps only what a post needs to be found and redrawn:
#   <stem>.sent.json       the click that filed this post's request, written
#                          once, so a second click files nothing
#   <stem>.settled.json    the post's final outcome line, written once
#   <stem>.finalized       the post content Discord shows now
#
# What a post shows, where <time> is a Discord timestamp:
#   ⏳ <label> sent by <name> <time> - waiting for Firstmate to record it
#                                        a click filed a request; buttons off
#   ✅ <label> chosen by <name> <time>    Firstmate recorded the clicked option
#   ✅ <label> chosen by the captain <time>
#                                        Firstmate recorded an answer from
#                                        another channel that names exactly one
#                                        option (see answer_option below)
#   ✅ Decided <time>                    an answer with no unique option match
#   Closed - no longer needed <time>     closed with no captain answer: the
#                                        task's terminal outcome, moved to a
#                                        captain call, reconciled as moot, gone,
#                                        or a later lifecycle of the same key
#   Replaced by a newer post <time>      a later button post for the same key
# The recorded answer comes from the ledgers through
# fm_ext_decision_key_outcome in bin/fm-ext-lib.sh and is never shown itself,
# because it may not be public-safe.
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
#        rule; nothing is filed (Discuss included)
#     4  no-op: the post is settled, already sent a request, was replaced by a
#        newer post, or the ledgers report its own lifecycle closed; a closed
#        or replaced post is also settled with its outcome line
#     0  Discuss: one request (keyed by the post, so a repeat click files
#        nothing new) so Firstmate picks the decision up in the thread; nothing
#        is decided and the buttons stay on
#     5  confirmation needed: the option needs a second click and --confirmed
#        was not given; prints "Confirm: <label>?" and files nothing
#     0  sent: claims the post once, files one request through
#        bin/fm-ext-intake.sh --origin button carrying the key, its occurrence,
#        the option, the decision text, any confirmation, and who and when;
#        the post then shows the sent line with its buttons off
#   Exit 1 means nothing was filed; the claim is released so the click can be
#   tried again. If an inbox request was published but notification failed,
#   exit 0 reports recovery needed; the sent claim remains and retrying uses
#   the original request id. Discuss also retries its original request id.
#   Exit 2 is bad usage.
#
# posts
#   Prints one JSON line per button post whose current content Discord does
#   not show yet: {post, channel_id, message_id, content, final, key,
#   options}; a listed post always shows with its buttons off. Without
#   --settled-only it first settles every live post that a newer post for the
#   same key replaced, or whose own lifecycle the ledgers report closed.
#
# threads [--thread <id>]
#   Prints one JSON line per Discord thread that holds a decision post, with
#   or without buttons: {thread_id, open, closed, last_posted_at}; --thread
#   reads only that thread. Unpublished progress records are ignored.
#   A post is closed once it is settled, replaced by
#   a newer post, or its own lifecycle of its decision is decided or
#   superseded in the ledgers; a decision whose state cannot be read counts
#   as open. last_posted_at is the newest post's posting time (epoch seconds,
#   0 when unknown). The gateway poster reads it when a reply marks a thread
#   needs-you, and again to clear that marker once no decision in the thread
#   is open. Read-only.
#
# finalized
#   Records the content Discord now shows for a post, so posts lists it only
#   when that content changes.
#
# still-open
#   The check Firstmate runs before recording a button request: is the
#   request's decision still open, and still the same lifecycle the clicked
#   post was made for? It compares the request's occurrence with the
#   decision's current one - a captain call's `fm-captain-hold.sh open
#   --identity`, or a worker key's status_key_occurrence - so a request queued
#   before its question was answered and reopened never answers the new
#   question. Prints open, decided, superseded, or unknown; exits 0 only for
#   open, 2 for unknown, and 1 otherwise. Read-only.
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
       fm-ext-decision.sh threads [--thread <id>]
       fm-ext-decision.sh finalized --post <stem> --content-file <path>
       fm-ext-decision.sh still-open --key <key> --occurrence <occurrence>
EOF
}

help() {
  sed -n '2,/^set -u$/p' "$0" | sed '$d; s/^# \{0,1\}//'
}

die() { printf 'fm-ext-decision: %s\n' "$1" >&2; exit "${2:-2}"; }

# notice <exit-code> <text>: the ephemeral reply a clicker sees, then exit.
notice() { printf '%s\n' "$2"; exit "$1"; }

NOT_AUTHORISED="Firstmate: not authorised to answer this decision. Nothing was sent."
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

# post_thread <stem>: the Discord thread or channel the post actually lives in.
# The poster records a topic thread it opened for the request in the post's
# chunk progress; otherwise the post went where the request came from.
post_thread() {
  local thread
  thread=$(post_field "$1" '.topic_thread_id')
  if [ -z "$thread" ]; then
    thread=$(post_field "$1" '.request_id')
    thread=${thread#discord:*:*:}
    thread=${thread%%:*}
  fi
  case "$thread" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$thread"
}

settled() { [ -f "$OUTBOX/$1.settled.json" ]; }
settle_text() { jq -r '.text // empty' "$OUTBOX/$1.settled.json" 2>/dev/null; }
sent() { [ -f "$OUTBOX/$1.sent.json" ]; }
sent_field() { jq -r "($2) // empty | tostring" "$OUTBOX/$1.sent.json" 2>/dev/null; }

sent_text() {  # <stem>
  printf '⏳ %s sent by %s %s - waiting for Firstmate to record it' \
    "$(sent_field "$1" '.option')" "$(sent_field "$1" '.by')" "$(discord_time "$(sent_field "$1" '.at')")"
}

# post_content <stem>: what the post should show now, or nothing while it is
# still an open question.
post_content() {
  if settled "$1"; then
    settle_text "$1"
  elif sent "$1" && request_published "$(sent_field "$1" '.request_id')"; then
    sent_text "$1"
  fi
}

# settle_post <stem> <kind> <text> [selected option id]: write the final
# outcome once, including the option whose button should remain highlighted.
settle_post() {
  jq -cn --arg kind "$2" --arg text "$3" --arg selected "${4:-}" --argjson at "$NOW" \
    '{kind:$kind, text:$text, at:$at}
     + if $selected == "" then {} else {selected_option_id:($selected | tonumber)} end' \
    | fm_ext_private_artifact_publish_stdin_once "$OUTBOX" "$1.settled.json" 600
  [ "$?" -le 1 ]
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

# newer_post_link <stem>: the newest newer button post's jump URL, when known.
newer_post_link() {
  local stem=$1 key posted file candidate candidate_posted best_stem=
  local request guild thread message best_posted=0
  key=$(post_field "$stem" '.decision.key')
  posted=$(post_field "$stem" '.posted_at')
  while IFS= read -r file; do
    candidate=$(basename "$file" .progress.json)
    [ "$candidate" = "$stem" ] && continue
    if jq -e --arg key "$key" --argjson posted "${posted:-0}" --argjson best "$best_posted" \
      '.decision.key == $key and .buttons == true
       and ((.posted_at // 0) > $posted) and ((.posted_at // 0) > $best)' \
      "$file" >/dev/null 2>&1; then
      candidate_posted=$(jq -r '.posted_at // 0' "$file" 2>/dev/null)
      best_posted=$candidate_posted
      best_stem=$candidate
    fi
  done < <(progress_files)
  [ -n "$best_stem" ] || return 0
  file="$OUTBOX/$best_stem.progress.json"
  request=$(jq -r '.request_id // ""' "$file")
  guild=${request#discord:}
  guild=${guild%%:*}
  message=$(jq -r '.discord_message_ids[-1] // empty' "$file")
  case "$guild" in ''|*[!0-9]*) return 0 ;; esac
  case "$message" in ''|*[!0-9]*) return 0 ;; esac
  thread=$(post_thread "$best_stem") || return 0
  printf 'https://discord.com/channels/%s/%s/%s\n' "$guild" "$thread" "$message"
}

# selected_option_id <stem>: the option chosen for this settled or sent post.
selected_option_id() {
  local stem=$1 kind outcome option
  if settled "$stem"; then
    kind=$(jq -r '.kind // empty' "$OUTBOX/$stem.settled.json" 2>/dev/null)
    [ "$kind" = decided ] || return 0
    option=$(jq -r '.selected_option_id // empty' "$OUTBOX/$stem.settled.json" 2>/dev/null)
    if [ -z "$option" ]; then
      outcome=$(post_outcome "$stem") || return 0
      option=$(answer_option "$stem" "${outcome#*$'\t'}")
    fi
  elif sent "$stem"; then
    option=$(sent_field "$stem" '.option_id')
  else
    return 0
  fi
  case "$option" in [1-9]) printf '%s\n' "$option" ;; esac
}

# answer_option <stem> <answer>: ignore the audit suffix, then accept a unique
# longest full label prefix immediately. Only without that prefix, collect
# standalone option numbers and whole-word labels and require one distinct id.
answer_option() {
  local stem=$1 answer=$2 ids='' word id label prefix options
  local -a words
  answer=${answer%%" (Discord button:"*}
  [ -n "$answer" ] || return 0
  answer=${answer#"Decision answer: "}
  options=$(jq -c '[.decision.options[]
    | ., (select(.recommended == true) | .label |= sub("^⭐ *"; "")
          | select(.label | length > 0))]
    | unique_by([.id, .label])' "$OUTBOX/$stem.progress.json" 2>/dev/null)
  prefix=$(jq -r --arg answer "$answer" '
    ($answer | ascii_downcase) as $text
    | [.[] | (.label | ascii_downcase) as $option_label
       | select($text | startswith($option_label))
       | select($text[($option_label | length):] | test("^($|[^[:alnum:]_])"))]
    | if length == 0 then empty else
        (map(.label | length) | max) as $longest
        | map(select((.label | length) == $longest))
        | if length == 1 then .[0].id else empty end
      end' <<<"$options" 2>/dev/null)
  if [ -n "$prefix" ]; then
    printf '%s\n' "$prefix"
    return 0
  fi
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
  done < <(jq -r '.[] | "\(.id)\t\(.label)"' <<<"$options" 2>/dev/null)
  ids=$(printf '%s' "$ids" | sort -u)
  case "$ids" in
    [1-9]) printf '%s\n' "$ids" ;;
  esac
}

# outcome_text <stem> <state> <answer>: the final line for a decision the
# ledgers report closed. A recorded answer naming the option this post's click
# sent credits that clicker at the click's time.
outcome_text() {
  local stem=$1 state=$2 answer=$3 option label
  case "$state" in
    decided)
      option=$(answer_option "$stem" "$answer")
      label=
      [ -z "$option" ] || label=$(post_field "$stem" ".decision.options[] | select(.id == $option) | .label")
      if [ -z "$label" ]; then
        printf '✅ Decided %s' "$(discord_time "$NOW")"
      elif sent "$stem" && [ "$(sent_field "$stem" '.option_id')" = "$option" ]; then
        printf '✅ %s chosen by %s %s' "$label" "$(sent_field "$stem" '.by')" \
          "$(discord_time "$(sent_field "$stem" '.at')")"
      else
        printf '✅ %s chosen by the captain %s' "$label" "$(discord_time "$NOW")"
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

# settle_if_closed <stem>: settle a post whose decision a newer post replaced
# or whose own lifecycle closed. Returns 0 when the post is settled after it,
# 1 while the decision is still open, and 2 when its state cannot be read.
settle_if_closed() {
  local stem=$1 outcome state option
  settled "$stem" && return 0
  if newer_post "$stem"; then
    settle_post "$stem" replaced "Replaced by a newer post $(discord_time "$NOW")" || return 2
    return 0
  fi
  outcome=$(post_outcome "$stem") || return 2
  state=${outcome%%$'\t'*}
  case "$state" in
    open) return 1 ;;
    decided|superseded)
      option=
      [ "$state" != decided ] || option=$(answer_option "$stem" "${outcome#*$'\t'}")
      settle_post "$stem" "$state" "$(outcome_text "$stem" "$state" "${outcome#*$'\t'}")" "$option" \
        || return 2
      return 0
      ;;
  esac
  return 2
}

# send_request <stem> <message-id> <text> <decision-json>: one request through
# the same intake every Discord path uses, at the clicker's own authority,
# filed from the thread the post lives in so Firstmate answers it there, like
# a typed message in that thread. The request id is fixed by its caller, so
# sending it again files nothing new.
request_published() {
  [ -n "$1" ] && [ -f "$(fm_ext_inbox_dir)/$(fm_ext_request_slug "$1").json" ]
}

request_id() {
  local request rest guild channel thread
  request=$(post_field "$1" '.request_id')
  rest=${request#discord:}
  guild=${rest%%:*}
  rest=${rest#*:}
  channel=${rest%%:*}
  thread=$(post_thread "$1") || return 1
  printf 'discord:%s:%s:%s:%s\n' "$guild" "$channel" "$thread" "$2"
}

send_request() {
  local stem=$1 message=$2 dir rc request rest guild channel thread inbox author=$AUTHOR text=$3 decision=$4
  request=$(request_id "$stem" "$message") || return 1
  rest=${request#discord:}
  guild=${rest%%:*}
  rest=${rest#*:}
  channel=${rest%%:*}
  rest=${rest#*:}
  thread=${rest%%:*}
  inbox="$(fm_ext_inbox_dir)/$(fm_ext_request_slug "$request").json"
  if [ -f "$inbox" ]; then
    author=$(jq -r '.author' "$inbox") || return 1
    text=$(jq -r '.text' "$inbox") || return 1
    decision=$(jq -c '.decision' "$inbox") || return 1
  fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-ext-decision.XXXXXX") || return 1
  printf '%s\n' "$text" > "$dir/text"
  printf '%s\n' "$decision" > "$dir/decision.json"
  "$SCRIPT_DIR/fm-ext-intake.sh" \
    --request-id "$request" \
    --guild-id "$guild" --channel-id "$channel" --thread-id "$thread" \
    --message-id "$message" --author "$author" --secret-file "$SECRET_FILE" \
    --text-file "$dir/text" --origin button --decision-file "$dir/decision.json" >/dev/null 2>&1
  rc=$?
  rm -rf -- "$dir"
  return "$rc"
}

command_click() {
  local key='' confirmed=0 stem request rest label needs_confirm prompt name text choice_json rc
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
  [ "$(post_thread "$stem")" = "$CHAT_ID" ] || notice 6 "$EXPIRED"
  DECISION_KEY=$(post_field "$stem" '.decision.key')
  fm_ext_decision_key_valid "$DECISION_KEY" || notice 6 "$EXPIRED"
  [ -z "$key" ] || [ "$key" = "$DECISION_KEY" ] || notice 6 "$EXPIRED"

  [ "$(fm_ext_authority "$(fm_ext_allowlist_path "$FM_HOME")" "$GUILD_ID" "$CHANNEL" "$AUTHOR")" = standing ] \
    || notice 3 "$NOT_AUTHORISED"

  # Answered, superseded, replaced, and stale posts file nothing, Discuss
  # included; a post whose request is already on its way files nothing new.
  if settled "$stem"; then
    notice 4 "Already decided: $(settle_text "$stem") - this click changed nothing."
  fi
  if sent "$stem"; then
    request=$(sent_field "$stem" '.request_id')
    if request_published "$request" && ! fm_ext_private_artifact_file_valid "$(fm_ext_context_dir)" "$(fm_ext_request_slug "$request").offered.json" 600; then
      if send_request "$stem" "${request##*:}" '' '{}'; then
        notice 0 "Sent: $(sent_field "$stem" '.option'). Firstmate will record it, and the post updates when it does."
      fi
      notice 0 "Sent: $(sent_field "$stem" '.option'). The request is filed, but notification needs recovery; retry this click to notify Firstmate."
    fi
    notice 4 "Already sent: $(sent_text "$stem"). This click changed nothing."
  fi
  settle_if_closed "$stem"
  case $? in
    0)
      case "$(jq -r '.kind' "$OUTBOX/$stem.settled.json" 2>/dev/null)" in
        replaced) notice 4 "A newer post replaced this decision - use that one. This click changed nothing." ;;
      esac
      notice 4 "Already decided: $(settle_text "$stem") - this click changed nothing."
      ;;
    1) ;;
    *) die "could not read whether the decision is still open" 1 ;;
  esac

  text=$(post_field "$stem" '.decision.text')
  if [ "$OPTION" = discuss ]; then
    choice_json=$(jq -cn --arg key "$DECISION_KEY" --arg occurrence "$(post_field "$stem" '.decision.occurrence')" \
      --arg text "$text" --arg by "$name" --arg author "$AUTHOR" --arg at "$(utc_iso "$NOW")" \
      '{key:$key, occurrence:$occurrence, choice:"discuss", text:$text, by:$by, author:$author, at:$at}') \
      || die "could not build the request" 1
    # Keyed by the post, so a repeat click files nothing new.
    send_request "$stem" "$POST_ID" \
      "Discuss requested on a decision post: talk it through before anything is decided." \
      "$choice_json" || {
        if request_published "$(request_id "$stem" "$POST_ID")"; then
          notice 0 "Discuss request filed, but notification needs recovery; retry Discuss to notify Firstmate. Nothing was decided."
        fi
        die "could not send the Discuss request; nothing was decided" 1
      }
    notice 0 "Firstmate will pick this up in the thread. Nothing was decided."
  fi

  label=$(post_field "$stem" ".decision.options[] | select(.id == $OPTION) | .label")
  [ -n "$label" ] || notice 6 "$EXPIRED"
  needs_confirm=$(post_field "$stem" ".decision.options[] | select(.id == $OPTION) | .confirm")
  prompt="Confirm: $label?"
  if [ "$needs_confirm" = true ] && [ "$confirmed" = 0 ]; then
    notice 5 "$prompt"
  fi

  # One click per post: the claim is the double-click guard, and it is released
  # again if the request cannot be filed, so nothing is ever claimed unsent.
  jq -cn --argjson option_id "$OPTION" --arg option "$label" --arg by "$name" --arg author "$AUTHOR" \
    --arg interaction "$INTERACTION_ID" --arg request_id "$(request_id "$stem" "$INTERACTION_ID")" --argjson at "$NOW" \
    --argjson confirmed "$([ "$confirmed" = 1 ] && echo true || echo false)" \
    '{option_id:$option_id, option:$option, by:$by, author:$author, interaction:$interaction,
      at:$at, confirmed:$confirmed, request_id:$request_id}' \
    | fm_ext_private_artifact_publish_stdin_once "$OUTBOX" "$stem.sent.json" 600
  rc=$?
  case "$rc" in
    0) ;;
    1) notice 4 "Already sent: $(sent_text "$stem"). This click changed nothing." ;;
    *) die "could not claim the decision post; nothing was sent" 1 ;;
  esac
  choice_json=$(jq -cn --arg key "$DECISION_KEY" --arg occurrence "$(post_field "$stem" '.decision.occurrence')" \
    --arg mode "$(post_field "$stem" '.decision.mode')" \
    --argjson option_id "$OPTION" --arg option "$label" --arg text "$text" \
    --argjson confirmed "$([ "$confirmed" = 1 ] && echo true || echo false)" --arg prompt "$prompt" \
    --arg by "$name" --arg author "$AUTHOR" --arg at "$(utc_iso "$NOW")" \
    '{key:$key, occurrence:$occurrence, choice:"option", option_id:$option_id, option:$option,
      text:$text, confirmed:$confirmed, by:$by, author:$author, at:$at}
     + if $mode == "" then {} else {mode:$mode} end
     + if $confirmed then {confirm_prompt:$prompt} else {} end') || choice_json=
  if [ "$confirmed" = 1 ]; then
    text="Decision answer by button: $label (confirmed)"
  else
    text="Decision answer by button: $label"
  fi
  if [ -z "$choice_json" ] || ! send_request "$stem" "$INTERACTION_ID" "$text" "$choice_json"; then
    if request_published "$(sent_field "$stem" '.request_id')"; then
      notice 0 "Sent: $label. The request is filed, but notification needs recovery; retry this click to notify Firstmate."
    fi
    fm_ext_private_artifact_remove "$OUTBOX" "$stem.sent.json" 600 || true
    die "could not send the click to Firstmate; nothing was sent" 1
  fi
  notice 0 "Sent: $label. Firstmate will record it, and the post updates when it does."
}

# fit_post_content <header> <original text> <progress file>: preserve the
# original last chunk when it fits; structured posts trim only explanation.
fit_post_content() {
  jq -njr --arg header "$1" --arg original "$2" --slurpfile progress "$3" '
    def compose($header; $question; $explanation; $options; $cue):
      ($header + "\n\n") as $base
      | (if $options == "" then "" else "\n\n" + $options end) as $option_suffix
      | (if $cue == "" then "" else "\n" + $cue end) as $cue_suffix
      | ($option_suffix + $cue_suffix) as $suffix
      | "\n\n(trimmed)" as $marker
      | (($base | length) + ($suffix | length)) as $fixed
      | if ($fixed + ($question | length)) > 2000 then
          error("decision header, question, and options exceed the Discord limit")
        else
          (2000 - $fixed - ($question | length)) as $room
          | if $explanation == "" then
              $base + $question + $suffix
            elif (2 + ($explanation | length)) <= $room then
              $base + $question + "\n\n" + $explanation + $suffix
            elif $room >= (2 + ($marker | length)) then
              ($room - 2 - ($marker | length)) as $explanation_room
              | $base + $question + "\n\n"
                + $explanation[0:$explanation_room] + $marker + $suffix
            else
              error("decision header leaves no room for the explanation marker")
            end
        end;
    $progress[0] as $post
    | ($header + "\n\n" + $original) as $whole
    | if ($whole | length) <= 2000 then
        $whole
      else
        ($post.decision.sections // {}) as $sections
        | if $sections.structured == true then
            compose($header; $sections.question; $sections.explanation;
              $sections.options; $sections.cue)
          else
            error("legacy decision text cannot safely fit its outcome header")
          end
      end
  '
}

command_posts() {
  local settled_only=0 file stem thread content original displayed shown final
  local kind header replacement_url selected
  [ "${1:-}" != --settled-only ] || settled_only=1
  while IFS= read -r file; do
    stem=$(basename "$file" .progress.json)
    jq -e '.decision.key and .buttons == true' "$file" >/dev/null 2>&1 || continue
    if [ "$settled_only" = 0 ]; then
      settle_if_closed "$stem" || true
    fi
    content=$(post_content "$stem")
    [ -n "$content" ] || continue
    original=$(jq -j '.texts[-1] // ""' "$file"; printf '\001')
    original=${original%$'\001'}
    selected=$(selected_option_id "$stem")
    replacement_url=
    if settled "$stem"; then
      kind=$(jq -r '.kind // empty' "$OUTBOX/$stem.settled.json" 2>/dev/null)
    else
      kind=waiting
    fi
    if [ "$kind" = replaced ]; then
      replacement_url=$(newer_post_link "$stem")
      if [ -n "$replacement_url" ]; then
        header="♻️ **Replaced by a newer question** ([open]($replacement_url))"
      else
        header="**Replaced by a newer question**"
      fi
    else
      header="**$content**"
    fi
    displayed=$(fit_post_content "$header" "$original" "$file") || continue
    shown=$(cat "$OUTBOX/$stem.finalized" 2>/dev/null; printf '\001') || shown=
    shown=${shown%$'\001'}
    [ "$displayed" != "$shown" ] || continue
    final=false
    settled "$stem" && final=true
    thread=$(post_thread "$stem") || continue
    jq -cn --arg post "$stem" --arg channel "$thread" \
      --arg message "$(post_field "$stem" '.discord_message_ids[-1]')" \
      --arg content "$displayed" --arg selected "$selected" --argjson final "$final" \
      --slurpfile progress "$file" \
      '{post:$post, channel_id:$channel, message_id:$message, content:$content,
        final:$final,
        selected_option_id:(if $selected == "" then null else ($selected | tonumber) end),
        key:$progress[0].decision.key, options:$progress[0].decision.options}'
  done < <(progress_files)
}

command_threads() {
  local only='' file stem thread state posted
  case "${1:-}" in
    '') ;;
    --thread)
      only=${2:-}
      case "$only" in
        ''|*[!0-9]*) die "threads --thread needs a Discord thread id" ;;
      esac
      ;;
    *) usage; exit 2 ;;
  esac
  while IFS= read -r file; do
    stem=$(basename "$file" .progress.json)
    jq -e '.decision.key and ((.discord_message_ids // []) | length > 0)' "$file" >/dev/null 2>&1 || continue
    thread=$(post_thread "$stem") || continue
    [ -z "$only" ] || [ "$thread" = "$only" ] || continue
    if settled "$stem" || newer_post "$stem"; then
      state=closed
    else
      case "$(fm_ext_decision_key_state "$(post_field "$stem" '.decision.key')" \
        "$(post_field "$stem" '.decision.occurrence')")" in
        decided|superseded) state=closed ;;
        *) state=open ;;
      esac
    fi
    posted=$(post_field "$stem" '.posted_at')
    case "$posted" in
      ''|*[!0-9.]*) posted=0 ;;
    esac
    jq -cn --arg thread "$thread" --arg state "$state" --argjson posted "$posted" \
      '{thread_id:$thread, state:$state, posted_at:$posted}'
  done < <(progress_files) \
    | jq -sc 'group_by(.thread_id)[]
        | {thread_id: .[0].thread_id,
           open: (map(select(.state == "open")) | length),
           closed: (map(select(.state == "closed")) | length),
           last_posted_at: (map(.posted_at) | max)}'
}

command_finalized() {
  local stem='' content_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --post) shift; stem=${1:-} ;;
      --content-file) shift; content_file=${1:-} ;;
      *) usage; exit 2 ;;
    esac
    shift || true
  done
  post_stem_valid "$stem" || die "finalized needs --post <stem>"
  [ -f "$content_file" ] && [ ! -L "$content_file" ] || die "finalized needs --content-file <path>"
  [ -f "$OUTBOX/$stem.progress.json" ] || die "no such post: $stem" 1
  fm_ext_private_artifact_publish_stdin "$OUTBOX" "$stem.finalized" 600 < "$content_file" \
    || die "could not record what the post shows" 1
}

# Is a button request's decision still the open question it was posted for?
# Read-only; see "still-open" in the header.
command_still_open() {
  local key='' occurrence='' outcome state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key) shift; key=${1:-} ;;
      --occurrence) shift; occurrence=${1:-} ;;
      *) usage; exit 2 ;;
    esac
    shift || true
  done
  fm_ext_decision_key_valid "$key" || die "still-open needs --key hold:<task-id> or key:<task-id>:<slug>"
  [ -n "$occurrence" ] || die "still-open needs the request's --occurrence"
  outcome=$(fm_ext_decision_key_outcome "$key" "$occurrence") || die "malformed decision key"
  state=${outcome%%$'\t'*}
  printf '%s\n' "$state"
  case "$state" in
    open) exit 0 ;;
    unknown) exit 2 ;;
  esac
  exit 1
}

case "${1:-}" in
  click) shift; command_click "$@" ;;
  posts) shift; command_posts "$@" ;;
  threads) shift; command_threads "$@" ;;
  finalized) shift; command_finalized "$@" ;;
  still-open) shift; command_still_open "$@" ;;
  --help|-h) help ;;
  *) usage; exit 2 ;;
esac
