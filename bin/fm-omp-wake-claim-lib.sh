#!/usr/bin/env bash
# Durable OMP primary wake-notification claim.
#
# ONE owner of the claim's file format and of every read, publish, replay
# rebind, and retirement performed on it. The claim records that a watcher wake
# notification is outstanding for the durable wake-queue rows at or below a
# sequence cutoff, so a replacement OMP session or a replacement OMP process
# re-presents that exact batch instead of losing it. The durable queue rows stay
# authoritative; the claim only carries the re-notification.
#
# Format (regular file, mode 0600, never a symlink), one field per line:
#   1  fm-omp-wake-claim-v1
#   2  claim id           minted on every write
#   3  owner instance     per-OMP-process identity: a same-process extension
#                         reload keeps it, a replacement process never does
#   4  owner session      per-OMP-session identity
#   5  cutoff             highest durable wake sequence the claim covers
#   6  content            base64 of the exact notification body to re-present
#
# Every _locked function requires the caller to already hold
# FM_WAKE_QUEUE_LOCK. The claim is published against the queue's own sequence
# counter and retired against the queue's own rows, so publication and
# retirement serialize on the single lock the queue already has instead of
# racing across a second one.
#
# Retirement is bound to acknowledgement, never to delivery: a claim is removed
# only once no durable row at or below its cutoff remains queued, and only
# bin/fm-wake-drain.sh's acknowledgement removes those rows. An interruption
# before that acknowledgement therefore leaves the rows and the claim durable
# for idempotent re-handling.

FM_OMP_WAKE_CLAIM_DIR="${FM_OMP_WAKE_CLAIM_DIR:-$STATE/extensions/omp-primary-watch}"
FM_OMP_WAKE_CLAIM_FILE="${FM_OMP_WAKE_CLAIM_FILE:-$FM_OMP_WAKE_CLAIM_DIR/wake-notification}"

# Populated by fm_omp_wake_claim_read_locked; empty whenever it returns nonzero.
FM_OMP_WAKE_CLAIM_ID=
FM_OMP_WAKE_CLAIM_INSTANCE=
FM_OMP_WAKE_CLAIM_SESSION=
FM_OMP_WAKE_CLAIM_CUTOFF=
FM_OMP_WAKE_CLAIM_CONTENT_B64=

# Owner identities are opaque to this library: it only proves they are single
# safe tokens so a malformed claim can never be mistaken for a bound one.
fm_omp_wake_claim_token_ok() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

fm_omp_wake_claim_new_id() {
  printf '%s.%s.%s\n' "$(fm_current_pid)" "$(date +%s)" "${RANDOM}${RANDOM}"
}

# The highest sequence the durable queue has issued. Read under the queue lock
# so every row already queued is at or below it and every later append is above.
fm_omp_wake_claim_queue_seq_locked() {
  local seq
  seq=$(cat "$STATE/.wake-queue.seq" 2>/dev/null || printf 0)
  case "$seq" in
    ''|*[!0-9]*) seq=0 ;;
  esac
  printf '%s\n' "$seq"
}

fm_omp_wake_claim_read_locked() {
  local version id instance session cutoff content _extra
  FM_OMP_WAKE_CLAIM_ID=
  FM_OMP_WAKE_CLAIM_INSTANCE=
  FM_OMP_WAKE_CLAIM_SESSION=
  FM_OMP_WAKE_CLAIM_CUTOFF=
  FM_OMP_WAKE_CLAIM_CONTENT_B64=
  [ -f "$FM_OMP_WAKE_CLAIM_FILE" ] && [ ! -L "$FM_OMP_WAKE_CLAIM_FILE" ] || return 1
  exec 9< "$FM_OMP_WAKE_CLAIM_FILE" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r id <&9 || { exec 9<&-; return 1; }
  IFS= read -r instance <&9 || { exec 9<&-; return 1; }
  IFS= read -r session <&9 || { exec 9<&-; return 1; }
  IFS= read -r cutoff <&9 || { exec 9<&-; return 1; }
  IFS= read -r content <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-omp-wake-claim-v1 ] || return 1
  fm_omp_wake_claim_token_ok "$id" || return 1
  fm_omp_wake_claim_token_ok "$instance" || return 1
  fm_omp_wake_claim_token_ok "$session" || return 1
  case "$cutoff" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$content" in
    ''|*[!A-Za-z0-9+/=]*) return 1 ;;
  esac
  # shellcheck disable=SC2034 # Read by sourcing callers after a successful read.
  FM_OMP_WAKE_CLAIM_ID=$id
  FM_OMP_WAKE_CLAIM_INSTANCE=$instance
  FM_OMP_WAKE_CLAIM_SESSION=$session
  FM_OMP_WAKE_CLAIM_CUTOFF=$cutoff
  FM_OMP_WAKE_CLAIM_CONTENT_B64=$content
}

fm_omp_wake_claim_write_locked() {  # <id> <instance> <session> <cutoff> <content-b64>
  local id=$1 instance=$2 session=$3 cutoff=$4 content=$5 tmp
  mkdir -p "$FM_OMP_WAKE_CLAIM_DIR" || return 1
  tmp=$(mktemp "$FM_OMP_WAKE_CLAIM_FILE.tmp.XXXXXX") || return 1
  if ! printf 'fm-omp-wake-claim-v1\n%s\n%s\n%s\n%s\n%s\n' \
      "$id" "$instance" "$session" "$cutoff" "$content" > "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! _fm_atomic_replace "$tmp" "$FM_OMP_WAKE_CLAIM_FILE"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Bind one outstanding notification to the caller's process and session. A new
# claim replaces an outstanding one rather than accumulating, because OMP's
# hidden next-turn transport already coalesces every queued notification into
# one continuation turn. The cutoff only ever moves forward, so replacing a
# claim can never shorten the row span its retirement waits for.
fm_omp_wake_claim_publish_locked() {  # <instance> <session> <content-b64>
  local instance=$1 session=$2 content=$3 cutoff
  fm_omp_wake_claim_token_ok "$instance" || return 1
  fm_omp_wake_claim_token_ok "$session" || return 1
  case "$content" in
    ''|*[!A-Za-z0-9+/=]*) return 1 ;;
  esac
  cutoff=$(fm_omp_wake_claim_queue_seq_locked) || return 1
  if fm_omp_wake_claim_read_locked && [ "$FM_OMP_WAKE_CLAIM_CUTOFF" -gt "$cutoff" ]; then
    cutoff=$FM_OMP_WAKE_CLAIM_CUTOFF
  fi
  fm_omp_wake_claim_write_locked "$(fm_omp_wake_claim_new_id)" "$instance" "$session" "$cutoff" "$content"
}

# Decide whether the given owner owes a re-presentation, leaving the claim in
# the read globals when it does. A claim already bound to this process and this
# session is a same-session extension reload and must not be re-presented; any
# other binding is a replacement session or a replacement process.
# 0 a replay is due, 1 invalid owner, 3 nothing to replay.
fm_omp_wake_claim_replay_pending_locked() {  # <instance> <session>
  local instance=$1 session=$2
  fm_omp_wake_claim_token_ok "$instance" || return 1
  fm_omp_wake_claim_token_ok "$session" || return 1
  fm_omp_wake_claim_read_locked || return 3
  [ "$FM_OMP_WAKE_CLAIM_INSTANCE" = "$instance" ] && [ "$FM_OMP_WAKE_CLAIM_SESSION" = "$session" ] && return 3
  return 0
}

# Move the outstanding claim to a new owner, keeping its cutoff and body. This
# is what makes a re-presentation exactly-once per owner: a second replay under
# the same binding finds nothing to hand over. Callers rebind only after the
# body is safely handed to the new owner, so a failure anywhere earlier leaves
# the claim with its previous owner and the replay simply retries.
fm_omp_wake_claim_rebind_locked() {  # <instance> <session>
  local instance=$1 session=$2
  fm_omp_wake_claim_token_ok "$instance" || return 1
  fm_omp_wake_claim_token_ok "$session" || return 1
  fm_omp_wake_claim_read_locked || return 1
  fm_omp_wake_claim_write_locked "$(fm_omp_wake_claim_new_id)" "$instance" "$session" \
    "$FM_OMP_WAKE_CLAIM_CUTOFF" "$FM_OMP_WAKE_CLAIM_CONTENT_B64"
}

# Retire the claim exactly when the durable rows it covers are gone. Actor
# agnostic on purpose: a mixed queue can have main acknowledge some covered
# rows and the supervision branch acknowledge the rest, and the claim must
# survive until whichever acknowledgement clears the last one.
fm_omp_wake_claim_reconcile_locked() {
  fm_omp_wake_claim_read_locked || return 0
  if [ -s "$FM_WAKE_QUEUE" ] && awk -F '\t' -v cutoff="$FM_OMP_WAKE_CLAIM_CUTOFF" '
      NF >= 5 && $2 ~ /^[0-9]+$/ && $2 + 0 <= cutoff + 0 { covered = 1; exit }
      END { exit covered ? 0 : 1 }
    ' "$FM_WAKE_QUEUE" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$FM_OMP_WAKE_CLAIM_FILE" || return 1
}
