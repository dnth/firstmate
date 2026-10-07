#!/usr/bin/env bash
# Behavior tests for main-owned landing records of a remote second mate's PRs
# (bin/fm-landing.sh) and the guards that keep a second mate's own id from ever
# owning a PR poll. The remote side is a fixture: a handcrafted relay delta
# through the real ingest, a fake `gh` forge, and recording stand-ins for the
# notifier and the clone refresh.
#
#   (a) a relayed `done ... PR <url>` files one landing record and arms its poll
#       under a main-owned id, idempotently, and never under the mate's own id
#   (b) a merge wakes main through the real watcher; the reconcile then
#       refreshes the clone, tells the mate once, and retires the record
#   (c) a PR closed without merging is settled the same way, without a refresh
#   (d) a mate that cannot be told keeps the record; the next sweep retries
#   (e) a non-reconcile check only reports
#   (f) PRs the forge already shows settled, non-PR lines, and unregistered
#       mates file nothing
#   (h) custody crosses the relay: the mate's own PR-ready gate reports it, main's
#       landing record keeps it after the worker is released, and the merge
#       through fm-pr-merge on the landing id keeps its guards - complete
#       evidence merges, an accepted-blocked criterion or missing custody refuses
#       standing authority, and the captain's instruction overrides with a record
#   (g) fm-pr-check refuses a second mate's id and arms nothing; the arming
#       library refuses it too; a landing id re-arms through fm-pr-check
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

LANDING="$ROOT/bin/fm-landing.sh"
RELAY="$ROOT/bin/fm-procevent-remote-reply.sh"
PROJECT="$ROOT/bin/fm-todo-project.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-landing)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
URL7=https://github.com/acme/alpha/pull/7
URL8=https://github.com/acme/alpha/pull/8
URL9=https://github.com/acme/alpha/pull/9

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# A parent home with one registered remote second mate (ios), one project clone
# whose origin is acme/alpha, and fakes for the forge, notifier, and clone sync.
make_home() {  # <name> -> echoes home dir
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  fakebin="$home/fakebin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/forge" "$fakebin" "$home/projects"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf -- '- ios - iOS delivery (host: remote-mac; root: %s; home: %s/remote; scope: iOS work; projects: alpha; added 2026-08-02)\n' \
    "$ROOT" "$home" > "$home/data/secondmates.md"
  git init -q "$home/projects/alpha"
  git -C "$home/projects/alpha" remote add origin https://github.com/acme/alpha.git
  # gh answers the one read the poll and the sweep make: the forge state of a
  # PR, from forge/<number> (OPEN when absent).
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") number=${3##*/} ;;
  "pr checks") echo '[]'; exit 0 ;;
  "api graphql")
    f="$FM_TEST_FORGE/merged-by-main"
    if [ -f "$f" ]; then
      printf 'state=MERGED\nmerged=true\nqueued=false\nbase=main\n'
    else
      printf 'state=OPEN\nmerged=false\nqueued=false\nbase=main\n'
    fi
    exit 0
    ;;
  *) exit 2 ;;
esac
f="$FM_TEST_FORGE/$number"
if [ -f "$f" ]; then cat "$f"; else echo OPEN; fi
SH
  # The merge itself: gh-axi records the call and flips the forge to merged.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_FORGE/gh-axi.log"
if [ "${1:-} ${2:-}" = "pr merge" ]; then
  echo MERGED > "$FM_TEST_FORGE/${3}"
  : > "$FM_TEST_FORGE/merged-by-main"
fi
exit 0
SH
  cat > "$fakebin/send" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >> "$FM_TEST_SEND_LOG"
[ ! -e "$FM_TEST_SEND_FAIL" ]
SH
  cat > "$fakebin/sync" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_TEST_SYNC_LOG"
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/send" "$fakebin/sync"
  : > "$home/send.log"
  : > "$home/sync.log"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

home_env() {  # <home> <command...>
  local home=$1
  shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_TEST_FORGE="$home/forge" FM_TEST_SEND_LOG="$home/send.log" FM_TEST_SEND_FAIL="$home/send.fail" \
    FM_TEST_SYNC_LOG="$home/sync.log" \
    FM_LANDING_SEND_BIN="$home/fakebin/send" FM_LANDING_FLEET_SYNC_BIN="$home/fakebin/sync" \
    PATH="$home/fakebin:$BASE_PATH" "$@"
}

write_remote_delta() {  # <result-path> <status-line>
  local result=$1 line=$2 payload empty bytes hash empty_hash
  payload="$result.payload"
  empty="$result.empty"
  printf '%s\n' "$line" > "$payload"
  : > "$empty"
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d '[:space:]')
  hash=$(sha256_file "$payload")
  empty_hash=$(sha256_file "$empty")
  {
    printf 'schema=fm-remote-delta.v1\nstatus=delta\npath=state/parent-replies.status\n'
    printf 'from_offset=0\nto_offset=%s\nfrom_prefix_sha256=%s\nto_prefix_sha256=%s\n' "$bytes" "$empty_hash" "$hash"
    printf 'payload_sha256=%s\npayload_bytes=%s\nreason=fixture\n\n' "$hash" "$bytes"
    cat "$payload"
  } > "$result"
  rm -f "$payload" "$empty"
}

relay_line() {  # <home> <status-line>
  local home=$1 result="$1/delta.result"
  rm -f "$home/state/remote-replies/ios.cursor" "$home/state/remote-replies/ios.cursor.hash"
  write_remote_delta "$result" "$2"
  home_env "$home" "$RELAY" ingest ios "$result" >/dev/null
}

landing_ids() {  # <home>
  local meta
  for meta in "$1"/state/land-*.meta; do
    [ -e "$meta" ] || continue
    basename "$meta" .meta
  done
}

assert_one_landing() {  # <home> <url> -> echoes the id
  local home=$1 url=$2 ids
  ids=$(landing_ids "$home")
  [ "$(printf '%s\n' "$ids" | grep -c .)" -eq 1 ] || fail "expected one landing record, found: ${ids:-none}"
  grep -qx 'kind=landing' "$home/state/$ids.meta" || fail "landing record has the wrong kind"
  grep -qx 'secondmate=ios' "$home/state/$ids.meta" || fail "landing record does not name the second mate"
  grep -qxF "pr=$url" "$home/state/$ids.meta" || fail "landing record does not name the PR"
  printf '%s\n' "$ids"
}

assert_no_mate_poll() {  # <home>
  local f
  for f in "$1"/state/ios.check.sh "$1"/state/ios.pr-poll*; do
    [ ! -e "$f" ] && [ ! -L "$f" ] || fail "a poll artifact exists under the second mate's own id: $f"
  done
}

run_watcher_bounded() {  # <home>
  local home=$1
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env -u FM_TASK_ID FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=2 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      FM_WATCH_RESURFACE_MAX_ANNOUNCEMENTS=999999 FM_WATCH_RESURFACE_MAX_SECS=999999 \
      FM_TEST_FORGE="$home/forge" PATH="$home/fakebin:$BASE_PATH" "$WATCH"
}

test_relayed_pr_ready_files_a_main_owned_landing_and_a_merge_settles_it() {
  local home id out rc
  home=$(make_home relay-merge)
  # The mate's keyed PR-ready report crosses the real relay ingest.
  relay_line "$home" "done [key=pr-ready]: validated - PR $URL7 checks green"
  grep -qxF "done [key=pr-ready]: validated - PR $URL7 checks green" "$home/state/ios.status" \
    || fail "the relay did not append the mate's report"
  id=$(assert_one_landing "$home" "$URL7")
  fm_pr_poll_artifacts_valid "$home/state" "$id" "$POLL" || fail "the landing record has no valid merge poll"
  assert_no_mate_poll "$home"

  # Replaying the same report (the mate repeats itself) files nothing new.
  relay_line "$home" "done [key=pr-ready]: validated - PR $URL7 checks green"
  assert_one_landing "$home" "$URL7" >/dev/null
  home_env "$home" "$LANDING" register ios "$URL7" | grep -qx "landing: $id" \
    || fail "register was not idempotent on the same PR"

  # The mate has been put to sleep and is gone; the forge merges the PR.
  printf 'MERGED\n' > "$home/forge/7"
  set +e
  out=$(run_watcher_bounded "$home" 2> "$home/watch.err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the watcher did not report the merge: $(cat "$home/watch.err")"
  case "$out" in *"$id"*merged*) ;; *) fail "the watcher wake did not name the landing merge: $out" ;; esac
  grep -qF "merge landed: $id $URL7" "$home/state/.wake-queue" || fail "the merge left no durable wake for main"

  # Main's reconcile finishes the landing: refresh the clone, tell the mate, retire.
  out=$(home_env "$home" "$PROJECT" --check --reconcile)
  case "$out" in *"landing-merged: $id"*) ;; *) fail "reconcile did not settle the merged landing: $out" ;; esac
  [ "$(cat "$home/sync.log")" = alpha ] || fail "the project clone was not refreshed: $(cat "$home/sync.log")"
  [ "$(wc -l < "$home/send.log" | tr -d ' ')" -eq 1 ] || fail "the second mate was not told exactly once"
  grep -q "^ios	.*$URL7.*merged" "$home/send.log" || fail "the mate's notice does not name the merged PR"
  [ -z "$(landing_ids "$home")" ] || fail "the settled landing record survived"
  for f in "$home/state/$id".*; do
    [ ! -e "$f" ] || fail "settled landing left $f"
  done
  out=$(home_env "$home" "$PROJECT" --check --reconcile)
  case "$out" in *"DRIFT landing"*) fail "a settled landing reported again: $out" ;; esac
  [ "$(wc -l < "$home/send.log" | tr -d ' ')" -eq 1 ] || fail "the second mate was told twice"
  pass "AC1: a relayed PR-ready report is tracked by main, and a merge wakes main, refreshes its clone, and tells the mate"
}

test_main_merges_through_the_landing_record_and_settles_it() {
  local home id out
  home=$(make_home main-merge)
  relay_line "$home" "done [key=pr-ready]: PR $URL7 checks green"
  report_custody_through_the_relay "$home" "$(make_mate_home "$home" no)"
  id=$(assert_one_landing "$home" "$URL7")
  # The mate's worker is gone, so only main's record can carry the merge.
  out=$(home_env "$home" "$ROOT/bin/fm-pr-merge.sh" "$id" "$URL7" -- --squash 2>&1) \
    || fail "fm-pr-merge refused the landing record: $out"
  grep -qxF 'pr merge 7 --repo acme/alpha --squash' "$home/forge/gh-axi.log" \
    || fail "the merge did not go through the guarded gh-axi call"
  grep -qF "merge landed: $id $URL7" "$home/state/.wake-queue" || fail "the main merge left no durable outcome"
  out=$(home_env "$home" "$PROJECT" --check --reconcile)
  case "$out" in *"landing-merged: $id"*) ;; *) fail "reconcile did not settle after the main merge: $out" ;; esac
  [ -z "$(landing_ids "$home")" ] || fail "the landing record survived the main merge"
  pass "main merges a second mate's PR through its landing record with the ordinary guards, then settles it"
}

test_a_pr_closed_without_merging_settles_without_a_refresh() {
  local home id out
  home=$(make_home closed)
  relay_line "$home" "done: PR $URL8"
  id=$(assert_one_landing "$home" "$URL8")
  printf 'CLOSED\n' > "$home/forge/8"
  out=$(home_env "$home" "$PROJECT" --check --reconcile)
  case "$out" in *"landing-closed: $id"*) ;; *) fail "reconcile did not settle the closed landing: $out" ;; esac
  [ ! -s "$home/sync.log" ] || fail "a closed PR refreshed the clone"
  grep -q "^ios	.*$URL8.*closed without merging" "$home/send.log" || fail "the mate was not told the PR closed"
  [ -z "$(landing_ids "$home")" ] || fail "the closed landing record survived"
  pass "AC1: a PR closed without merging is settled and the mate is told"
}

test_an_untold_mate_keeps_the_record_until_it_can_be_told() {
  local home id out
  home=$(make_home untold)
  relay_line "$home" "done: PR $URL7"
  id=$(assert_one_landing "$home" "$URL7")
  printf 'MERGED\n' > "$home/forge/7"
  : > "$home/send.fail"
  out=$(home_env "$home" "$PROJECT" --check --reconcile)
  case "$out" in *"landing-notify-failed: $id"*) ;; *) fail "an untold mate was not reported: $out" ;; esac
  assert_one_landing "$home" "$URL7" >/dev/null
  rm -f "$home/send.fail"
  out=$(home_env "$home" "$PROJECT" --check --reconcile)
  case "$out" in *"landing-merged: $id"*) ;; *) fail "the retry did not settle: $out" ;; esac
  [ -z "$(landing_ids "$home")" ] || fail "the landing record survived the retry"
  pass "a mate that cannot be told keeps the landing record for retry"
}

test_a_plain_check_reports_without_settling() {
  local home id out
  home=$(make_home report-only)
  relay_line "$home" "done: PR $URL7"
  id=$(assert_one_landing "$home" "$URL7")
  printf 'MERGED\n' > "$home/forge/7"
  out=$(home_env "$home" "$PROJECT" --check)
  case "$out" in *"landing-merged: $id"*"requires verified mutation authority"*) ;; *) fail "a plain check did not report the landing: $out" ;; esac
  assert_one_landing "$home" "$URL7" >/dev/null
  [ ! -s "$home/send.log" ] && [ ! -s "$home/sync.log" ] || fail "a plain check mutated state"
  pass "a check without reconcile authority reports a landed PR and changes nothing"
}

test_nothing_is_filed_for_settled_prs_other_lines_or_unregistered_mates() {
  local home out
  home=$(make_home refusals)
  printf 'MERGED\n' > "$home/forge/9"
  relay_line "$home" "done: PR $URL9"
  [ -z "$(landing_ids "$home")" ] || fail "an already merged PR was filed"
  out=$(home_env "$home" "$LANDING" register ios "$URL9")
  case "$out" in *"skipped"*"already merged"*) ;; *) fail "register did not skip a merged PR: $out" ;; esac
  relay_line "$home" "working: PR $URL7 is being validated"
  relay_line "$home" "done [key=merged-x]: merged x $URL7"
  relay_line "$home" "done: no pull request here"
  [ -z "$(landing_ids "$home")" ] || fail "a line that is not a PR-ready report was filed"
  if home_env "$home" "$LANDING" register nobody "$URL7" >/dev/null 2>&1; then
    fail "an unregistered second mate got a landing record"
  fi
  if home_env "$home" "$LANDING" register ios "https://example.com/not/a/pr" >/dev/null 2>&1; then
    fail "a non-PR URL got a landing record"
  fi
  [ -z "$(landing_ids "$home")" ] || fail "a refused registration left a record"
  pass "settled PRs, non-report lines, unregistered mates, and non-PR URLs file nothing"
}

test_a_second_mate_id_never_owns_a_pr_poll_and_a_landing_id_rearms() {
  local home id rc out
  home=$(make_home mate-id)
  fm_write_meta "$home/state/ios.meta" "kind=secondmate" "home=$home/remote" "remote_host=remote-mac"
  set +e
  out=$(home_env "$home" "$PR_CHECK" ios "$URL7" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fm-pr-check accepted a second mate's id"
  case "$out" in *"ios is a second mate"*"landing"*) ;; *) fail "fm-pr-check gave no clear refusal: $out" ;; esac
  assert_no_mate_poll "$home"
  # The arming library refuses the same id for any caller.
  if ( . "$ROOT/bin/fm-pr-lib.sh"
       fm_pr_url_parse "$URL7" \
         && fm_pr_poll_prepare "$home/state" ios github "$URL7" github.com acme/alpha 7 "$POLL" ); then
    fail "fm-pr-lib armed a poll for a second mate's id"
  fi
  assert_no_mate_poll "$home"
  # A status line naming a PR under the mate's id arms nothing either.
  printf 'done: PR %s checks green\n' "$URL7" > "$home/state/ios.status"
  out=$(home_env "$home" "$PROJECT" --check --reconcile)
  assert_no_mate_poll "$home"

  # A landing record re-arms through fm-pr-check, so fm-pr-merge works on it.
  relay_line "$home" "done: PR $URL7"
  id=$(assert_one_landing "$home" "$URL7")
  rm -f "$home/state/$id.check.sh" "$home/state/$id.pr-poll" "$home/state/$id.pr-poll-registration"
  out=$(home_env "$home" "$PR_CHECK" "$id" "$URL7")
  [ "$out" = "armed: state/$id.check.sh" ] || fail "fm-pr-check did not re-arm the landing record: $out"
  fm_pr_poll_artifacts_valid "$home/state" "$id" "$POLL" || fail "the re-armed landing poll is invalid"
  assert_no_mate_poll "$home"
  pass "AC3: fm-pr-check refuses a second mate's id, nothing arms a poll under it, and a landing id re-arms"
}


HEAD40=0123456789abcdef0123456789abcdef01234567

# A remote second mate's home holding one validated worker for URL7: the worker's
# task record, brief, and evidence ledger, plus the seeded identity and remote
# parent binding that make its PR-ready gate report upward.
make_mate_home() {  # <home> <blocked: yes|no> -> echoes the mate home
  local home=$1 mate="$1/mate" ledger
  mkdir -p "$mate/state" "$mate/data/worker-1"
  printf 'ios\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$mate/.fm-secondmate-parent"
  fm_write_meta "$mate/state/worker-1.meta" "kind=ship" "mode=no-mistakes" "yolo=0" \
    "pr=$URL7" "pr_head=$HEAD40" "nm_run_id=run-1"
  printf '# Task\nFixture.\n\n# Acceptance criteria\n- AC1: First.\n- AC2: Second.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' \
    > "$mate/data/worker-1/brief.md"
  ledger="$mate/data/worker-1/evidence.jsonl"
  printf '%s\n' '{"criterion":"AC1","type":"test","outcome":"success","summary":"ok","result":"pass"}' > "$ledger"
  if [ "$2" = yes ]; then
    printf '%s\n' '{"criterion":"AC2","type":"test","outcome":"accepted-blocked","summary":"no env","result":"blocked","captain_exception":"2026-10-07 captain: ship without AC2"}' >> "$ledger"
  else
    printf '%s\n' '{"criterion":"AC2","type":"test","outcome":"success","summary":"ok","result":"pass"}' >> "$ledger"
  fi
  : > "$mate/data/worker-1/.evidence.lock"
  printf '%s\n' "$mate"
}

# The mate's PR-ready gate reports custody; the line crosses the main relay.
report_custody_through_the_relay() {  # <main-home> <mate-home>
  local home=$1 mate=$2 line
  FM_HOME="$mate" FM_ROOT_OVERRIDE="$ROOT" "$LANDING" report worker-1 >/dev/null \
    || fail "the mate's PR-ready gate could not report custody"
  line=$(grep -F ' custody task=worker-1 ' "$mate/state/parent-replies.status" | tail -1)
  [ -n "$line" ] || fail "the mate reported no custody line"
  relay_line "$home" "$line"
}

merge_through_the_guards() {  # <home> <id> [extra fm-pr-merge args]
  local home=$1 id=$2
  shift 2
  : > "$home/forge/gh-axi.log"
  home_env "$home" "$ROOT/bin/fm-pr-merge.sh" "$id" "$URL7" "$@" 2>&1
}

test_custody_survives_the_workers_release_and_the_guards_hold_at_merge() {
  local home mate id out meta want
  # Complete evidence, nothing accepted-blocked: the owner merges after release.
  home=$(make_home custody-clean)
  mate=$(make_mate_home "$home" no)
  report_custody_through_the_relay "$home" "$mate"
  rm -f "$mate/state/worker-1.meta"   # the mate releases its worker
  id=$(assert_one_landing "$home" "$URL7")
  meta="$home/state/$id.meta"
  for want in "pr_head=$HEAD40" nm_run_id=run-1 custody_task=worker-1 custody_mode=no-mistakes \
    custody_evidence=complete custody_blocked=none; do
    grep -qx "$want" "$meta" || fail "the landing record lost the mate's custody ($want): $(cat "$meta")"
  done
  fm_pr_poll_artifacts_valid "$home/state" "$id" "$POLL" || fail "recording custody broke the landing poll"
  out=$(merge_through_the_guards "$home" "$id" -- --squash) || fail "the owner could not merge after release: $out"
  grep -qxF 'pr merge 7 --repo acme/alpha --squash' "$home/forge/gh-axi.log" || fail "the guarded merge never reached the forge"
  # The report is idempotent, and a report that repeats changes nothing.
  FM_HOME="$mate" FM_ROOT_OVERRIDE="$ROOT" "$LANDING" report worker-1 >/dev/null
  [ "$(grep -cF ' custody task=worker-1 ' "$mate/state/parent-replies.status")" -eq 1 ] \
    || fail "a repeated PR-ready report duplicated the custody line"

  # An accepted-blocked criterion refuses standing authority and names it.
  home=$(make_home custody-blocked)
  mate=$(make_mate_home "$home" yes)
  report_custody_through_the_relay "$home" "$mate"
  rm -f "$mate/state/worker-1.meta"
  id=$(assert_one_landing "$home" "$URL7")
  grep -qx 'custody_blocked=AC2' "$home/state/$id.meta" || fail "the accepted-blocked criterion was not carried: $(cat "$home/state/$id.meta")"
  if out=$(merge_through_the_guards "$home" "$id" -- --squash); then
    fail "an accepted-blocked landing merged on standing authority"
  fi
  case "$out" in *"accepted as blocked: AC2"*"--captain-instruction"*) ;; *) fail "the refusal did not name the criterion and the override: $out" ;; esac
  [ ! -s "$home/forge/gh-axi.log" ] || fail "a refused merge reached the forge"
  # Only the captain's explicit word merges it, and the override is recorded.
  out=$(merge_through_the_guards "$home" "$id" --captain-instruction "captain 2026-10-07: merge it despite AC2" -- --squash) \
    || fail "the captain's instruction did not merge the accepted-blocked landing: $out"
  grep -qxF 'pr merge 7 --repo acme/alpha --squash' "$home/forge/gh-axi.log" || fail "the overridden merge never reached the forge"
  grep -q 'captain 2026-10-07: merge it despite AC2' "$home/data/$id/captain-merge-instructions.jsonl" \
    || fail "the captain's override left no durable record"

  # No custody at all (a bare PR-ready report) cannot rule an exception out.
  home=$(make_home custody-missing)
  relay_line "$home" "done [key=pr-ready]: PR $URL7 checks green"
  id=$(assert_one_landing "$home" "$URL7")
  if out=$(merge_through_the_guards "$home" "$id" -- --squash); then
    fail "a landing with no custody merged on standing authority"
  fi
  case "$out" in *"no complete acceptance evidence"*) ;; *) fail "the missing-custody refusal was not explained: $out" ;; esac
  [ ! -s "$home/forge/gh-axi.log" ] || fail "a refused merge reached the forge"

  # A mate whose evidence is incomplete reports it, and that refuses too.
  home=$(make_home custody-incomplete)
  mate=$(make_mate_home "$home" no)
  : > "$mate/data/worker-1/evidence.jsonl"
  report_custody_through_the_relay "$home" "$mate"
  id=$(assert_one_landing "$home" "$URL7")
  grep -qx 'custody_evidence=incomplete' "$home/state/$id.meta" || fail "incomplete evidence was not carried"
  if merge_through_the_guards "$home" "$id" -- --squash >/dev/null; then
    fail "a landing with incomplete evidence merged on standing authority"
  fi
  pass "AC5: custody crosses the relay and survives the worker's release, and the owner's merge keeps every guard"
}

test_the_mates_pr_check_reports_custody_when_it_passes() {
  local home mate out
  home=$(make_home mate-pr-check)
  mate=$(make_mate_home "$home" no)
  # An unregistered direct-PR worker: its first PR-ready check runs the real gates.
  fm_write_meta "$mate/state/worker-1.meta" "kind=ship" "mode=direct-PR" "yolo=0"
  sed -i.bak 's/mode=no-mistakes/mode=direct-PR/' "$mate/data/worker-1/brief.md" && rm -f "$mate/data/worker-1/brief.md.bak"
  mkdir -p "$home/root/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/root/bin/fm-guard.sh"
  out=$(env -u FM_TASK_ID FM_HOME="$mate" FM_ROOT_OVERRIDE="$home/root" PATH="$home/fakebin:$BASE_PATH" "$PR_CHECK" worker-1 "$URL7" 2>&1) \
    || fail "the mate's PR-ready check failed: $out"
  grep -qxF "working [key=pr-custody-$(printf '%s' "$URL7" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-8)]: PR $URL7 custody task=worker-1 head=none run=none mode=direct-PR evidence=complete blocked=none" \
    "$mate/state/parent-replies.status" || fail "the passing PR-ready check reported no custody: $(cat "$mate/state/parent-replies.status" 2>/dev/null)"
  pass "a remote second mate's passing PR-ready check reports custody upward"
}

test_a_non_mate_home_reports_no_custody() {
  local home out
  home=$(make_home plain-home)
  fm_write_meta "$home/state/task-a.meta" "kind=ship" "mode=direct-PR" "pr=$URL7"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LANDING" report task-a)
  [ -z "$out" ] && [ ! -e "$home/state/parent-replies.status" ] || fail "an ordinary home reported custody: $out"
  pass "an ordinary or locally routed home reports no custody"
}

test_relayed_pr_ready_files_a_main_owned_landing_and_a_merge_settles_it
test_custody_survives_the_workers_release_and_the_guards_hold_at_merge
test_the_mates_pr_check_reports_custody_when_it_passes
test_a_non_mate_home_reports_no_custody
test_main_merges_through_the_landing_record_and_settles_it
test_a_pr_closed_without_merging_settles_without_a_refresh
test_an_untold_mate_keeps_the_record_until_it_can_be_told
test_a_plain_check_reports_without_settling
test_nothing_is_filed_for_settled_prs_other_lines_or_unregistered_mates
test_a_second_mate_id_never_owns_a_pr_poll_and_a_landing_id_rearms
