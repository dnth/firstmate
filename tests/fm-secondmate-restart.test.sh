#!/usr/bin/env bash
# bin/fm-secondmate-restart.sh: persist-then-restart, and the honest fallback.
#
# What these pin, all through the real commands (real fm-send, real durable
# steering inbox, real parent-owned reply expectation, real fm-control
# transaction) against a lifecycle-modelling session-provider stub:
#
#   1. The persist request is a GATE. Nothing is stopped until that mate's own
#      correlated answer lands on the parent channel, and a mate that never
#      answers keeps its agent and gets the re-read message instead.
#   2. The order is persist THEN restart, observable in what reaches the pane.
#   3. The persist request is the task-subset of /stow: it asks for open records
#      and task status, and explicitly not for the memory, learnings, or
#      captain-preference sweeps.
#   4. Every unsafe case says what is known: pre-restart capability and persist
#      failures use the nudge path, while a failed relaunch is reported as an
#      unknown outcome; none is reported as a clean reload.
#   5. A remote mate restarts by running the SAME local control-plane relaunch on
#      its host, over the fm-on transport, with the profile resolved from the
#      PARENT's own pin rather than the remote home's copy of it.
#   6. End to end with bin/fm-update.sh: a live mate whose home needed no
#      fast-forward is still named for restart and genuinely restarted, and one
#      whose runtime cannot prove a restart keeps the honest re-read path with
#      its agent left running.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESTART="$ROOT/bin/fm-secondmate-restart.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-restart)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# A session-provider stub that models the two things this pass depends on: the
# harness exit command stops the agent, a launch brief starts the replacement,
# and - when armed - the live mate ANSWERS a doorbell by doing what the persist
# request asks and reporting it on the parent channel with the correlation token
# the request carried. That answer is a real status append read by the real
# pending-reply machinery, not a stubbed verdict.
make_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    for a in "$@"; do
      case "$a" in
        touch\ */.fm-launch-probe.*)
          marker=${a#touch }
          marker=${marker#\'}
          marker=${marker%\'}
          : > "$marker"
          ;;
      esac
    done
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          if [ -e "$D/remote-relaunch-start" ] && [ ! -e "$D/remote-relaunch-end" ]; then
            : > "$D/local-relaunch-during-remote"
          fi
          if [ -n "${FM_TEST_OWNER_GONE:-}" ]; then : > "$FM_TEST_OWNER_GONE"; fi
          printf 'zsh' > "$D/command.$target"
          ;;
        "/bin/bash "*.fm-launch-*.sh\'*) cat "$D/becomes" > "$D/command.$target" ;;
        ': Firstmate instruction waiting: list '*)
          printf 'doorbell\n' >> "$D/rings"
          if [ -x "$D/on-doorbell" ]; then
            "$D/on-doorbell" "$payload"
          fi
          if [ -f "$D/answer-inbox" ]; then
            # Model the mate: read the newest instruction it was handed and
            # report back on the parent channel, carrying the correlation token
            # the request itself embedded.
            inbox=$(cat "$D/answer-inbox")
            corr=$(cat "$inbox"/*.msg 2>/dev/null \
              | grep -oE 'corr=[0-9a-f]{16}' | head -1)
            if [ -n "$corr" ]; then
              printf 'done [%s]: open records written down\n' "$corr" \
                >> "$(cat "$D/answer-status")"
            fi
          fi
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    target=
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ]; then target=$a; fi
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          if [ -f "$D/command.$target" ]; then cat "$D/command.$target"; else cat "$D/command"; fi
          printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
        *pane_pid*) [ -f "$D/pane-pid" ] && cat "$D/pane-pid"; exit 0 ;;
      esac
      prev=$a
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '> \n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  kill-window|kill-session) : > "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ''|*[!0-9]*) ;;
  *) /bin/sleep 0.01 ;;
esac
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> -> a parent home with a stub session provider.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  printf 'claude\n' > "$dir/home/config/secondmate-harness"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/rings"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_stub "$dir"
  printf '%s\n' "$dir"
}

# add_local_mate <case-dir> <id> [harness] [backend-line]
# OMP local second mates use a persistent git home so the relaunch owner can
# verify the fixture's tracked extension closure against HEAD.
#
add_local_mate() {
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-}
  local home="$dir/home" smhome="$dir/$id-home"
  if [ "$harness" = omp ]; then
    local seed="$dir/local-seed" origin="$dir/local-origin.git" root="$dir/local-primary"
    if [ ! -d "$origin" ]; then
      fm_git_init_commit "$seed"
      printf '/data/\n/state/\n/config/\n/projects/\n/.no-mistakes/\n.fm-secondmate-home\n' \
        > "$seed/.gitignore"
      printf '# agents\n' > "$seed/AGENTS.md"
      git -C "$seed" add .gitignore AGENTS.md
      git -C "$seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
        commit -qm 'persistent home fixture layout'
      fm_git_add_origin "$seed" "$origin"
      git clone --quiet "$origin" "$root"
    fi
    git clone --quiet "$origin" "$smhome"
  else
    fm_git_worktree "$dir/$id-repo" "$smhome" "sm-$id"
    printf '# agents\n' > "$smhome/AGENTS.md"
  fi
  mkdir -p "$smhome/state" "$smhome/data" "$smhome/bin" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
}

# add_repo_backed_mate <case-dir> <id> [harness] [backend-line]
# Like add_local_mate, but the world is the one /updatefirstmate actually runs
# against: a bare origin, a firstmate repo clone on its default branch, and the
# mate's home as a DETACHED worktree of that repo already sitting on origin's tip.
# That "already current" home is the shape the old classifier skipped entirely.
add_repo_backed_mate() {  # <case-dir> <id> [harness] [backend]
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-}
  local home="$dir/home" repo="$dir/fmrepo" smhome="$dir/$id-home"
  if [ ! -d "$repo" ]; then
    git init -q --bare "$dir/origin.git"
    git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
    git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
    mkdir -p "$dir/seed/bin" "$dir/seed/.agents/skills"
    printf '# agents\n' > "$dir/seed/AGENTS.md"
    printf 'echo a\n' > "$dir/seed/bin/tool.sh"
    printf 's1\n' > "$dir/seed/.agents/skills/note.md"
    # The operational dirs a live home carries are gitignored in a real firstmate
    # checkout; without that the home would read as dirty and be skipped.
    printf '/data/\n/state/\n/config/\n/projects/\n/.no-mistakes/\n.fm-secondmate-home\n' \
      > "$dir/seed/.gitignore"
    git -C "$dir/seed" add -A
    git -C "$dir/seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm c1
    git -C "$dir/seed" push -q origin main
    git clone -q "$dir/origin.git" "$repo"
    git -C "$repo" remote set-head origin main >/dev/null 2>&1 || true
    touch "$home/state/.last-watcher-beat"
  fi
  git -C "$repo" worktree add -q --detach "$smhome" main
  mkdir -p "$smhome/state" "$smhome/data" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
}

# run_update_in_case <case-dir>: the real /updatefirstmate mechanics over that world.
run_update_in_case() {
  local dir=$1
  env PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" \
    FM_ROOT_OVERRIDE="$dir/fmrepo" FM_HOME="$dir/home" \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$ROOT/bin/fm-update.sh" 2>/dev/null
}

# arm_answer <case-dir> <id>: make the modelled mate answer the persist request.
arm_answer() {
  local dir=$1 id=$2
  printf '%s' "$dir/home/state/$id.inbox" > "$dir/fake/answer-inbox"
  printf '%s' "$dir/home/state/$id.status" > "$dir/fake/answer-status"
}

run_restart() {  # <case-dir> <args...>
  local dir=$1 root="$ROOT"
  shift
  if [ -d "$dir/fmrepo/.git" ]; then
    root="$dir/fmrepo"
  elif [ -d "$dir/local-primary/.git" ]; then
    root="$dir/local-primary"
  fi
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$root" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 FM_SECONDMATE_PERSIST_POLL=1 \
    FM_SECONDMATE_PERSIST_WAIT="${FM_TEST_PERSIST_WAIT:-30}" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$RESTART" "$@" 2>&1
}

# --- T1: the persist request is the task subset of /stow, and it gates --------
test_persist_gates_and_asks_only_for_open_records() {
  local dir out rc request
  dir=$(new_case gate)
  add_local_mate "$dir" sm1
  # No answer armed: the mate never confirms its open work is written down.
  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" fm-sm1); rc=$?

  expect_code 3 "$rc" "an unconfirmed persist is a fallback, not a success"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "an unconfirmed persist must fall back to the re-read message"
  assert_contains "$out" "its open work is written down" "the fallback must name the missing confirmation"
  assert_not_contains "$out" "restarted: sm1" "a mate that never confirmed must not be restarted"
  assert_contains "$out" "summary: 0 of 1 restarted" "the summary must not claim a reload"
  # The agent is untouched: nothing exited, nothing relaunched.
  assert_no_grep '^/exit$' "$dir/fake/literal" "the agent was stopped without a confirmed persist"
  assert_absent "$dir/home/state/sm1.control-relaunch" \
    "a restart transaction was opened without a confirmed persist"
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=awaiting_report$' \
    || fail "the timed-out persist expectation was closed instead of left to recovery"

  # The request the mate actually received is the open-record half of /stow only.
  request=$(cat "$dir/home/state/sm1.inbox"/*.msg)
  assert_contains "$request" "Open-record persistence" "the request must reuse stow's open-record contract"
  assert_contains "$request" "file a task for each open record" "the request must ask for the unfiled open records"
  assert_contains "$request" "correct any task whose status" "the request must ask for stale task status"
  assert_contains "$request" "captain call you had formed but never registered" \
    "the request must flush an unregistered captain call"
  assert_contains "$request" "Do NOT run the memory, learnings, or captain-preference sweeps" \
    "the request must exclude the memory curation half of stow"
  pass "T1 persist is a gate, and asks for open records and task status only"
}

# --- T2: persist THEN restart, in that order --------------------------------
test_persist_precedes_restart() {
  local dir out rc doorbell_line exit_line
  dir=$(new_case order)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a confirmed persist should restart the mate"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude)" "the mate should be restarted on its pinned runtime"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 nudged, 0 unreached" "the summary should report the reload"
  # The pane transcript orders the two phases: the instruction doorbell first,
  # the harness exit command only after it.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the mate"
  [ -n "$exit_line" ] || fail "the mate was never stopped, so it was not restarted"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  # The reply expectation is settled rather than left open behind the restart.
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=resolved$' \
    || fail "the persist answer did not settle its durable expectation"
  pass "T2 the mate persists before anything is stopped"
}

# --- T2b: an answer delivered at a zero-second bound still releases the gate -
test_arrived_answer_precedes_deadline_check() {
  local dir out rc
  dir=$(new_case arrived-at-bound)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an answer delivered with the request must beat the deadline check"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the arrived persist answer was ignored at the deadline"
  pass "T2b an arrived persist answer is resolved before timeout"
}

# --- T2c: an answer arriving between resolution and timeout wins -------------
test_answer_between_resolution_and_timeout_wins() {
  local dir out rc
  dir=$(new_case answer-at-timeout-decision)
  add_local_mate "$dir" sm1

  # Delay the modelled answer until the first resolution attempt has completed
  # its unsuccessful status scan. The real pending-reply machinery publishes
  # that scan signature with mv; this wrapper appends the correlated answer only
  # after that publication, reproducing the boundary race deterministically.
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
/bin/mv "$@" || exit $?
target=${!#}
case "$target" in
  "${FM_FAKE_DIR%/fake}"/home/state/pending-replies/*)
    if [ ! -e "$FM_FAKE_DIR/answer-after-scan" ] \
      && grep -q '^parent_status_scan_signature=.' "$target"; then
      : > "$FM_FAKE_DIR/answer-after-scan"
      corr=${target##*/}
      status=$(sed -n 's/^parent_status=//p' "$target")
      printf 'done [corr=%s]: open records written down\n' "$corr" >> "$status"
    fi
    ;;
esac
SH
  chmod +x "$dir/fakebin/mv"

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an answer already on disk at the timeout decision must release the gate"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the reply that raced the timeout was ignored"
  assert_not_contains "$out" "nudged: sm1" "a confirmed mate must not take the timeout fallback"
  pass "T2c a reply between the preliminary scan and timeout decision wins"
}

# --- T3: a runtime that cannot prove a restart never gets one ----------------
test_unprovable_runtime_falls_back() {
  local dir out rc
  dir=$(new_case unprovable)
  # zellij has no recovery-grade agent-state classifier, so "the old agent
  # stopped and the replacement came up" can never be established there.
  add_local_mate "$dir" sm1 claude zellij

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unprovable runtime must not report a reload"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "an unprovable runtime must fall back to the re-read message"
  assert_contains "$out" "cannot prove an agent stopped" "the fallback must name the runtime limit"
  assert_not_contains "$out" "restarted: sm1" "an unprovable runtime must not be reported as restarted"
  # It is never even asked to spend a turn persisting, because it could not be
  # restarted afterwards either way; the only thing it was handed is the nudge.
  assert_no_grep 'Open-record persistence' "$dir/home/state/sm1.inbox/001.msg" \
    "a mate that cannot be restarted should not be asked to persist first"
  assert_grep 're-read your AGENTS.md' "$dir/home/state/sm1.inbox/001.msg" \
    "the fallback should hand the mate the ordinary re-read message"
  pass "T3 a runtime that cannot prove a restart falls back to the re-read message"
}

# --- T4: a mate with no durable record in this home --------------------------
test_unknown_mate_is_accounted_for() {
  local dir out rc
  dir=$(new_case unknown)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1 ghost); rc=$?

  expect_code 3 "$rc" "an unknown mate must not pass silently"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the known mate should still be restarted"
  assert_contains "$out" "ghost:" "the unknown mate must be accounted for by name"
  assert_contains "$out" "no durable record" "the unknown mate's reason must be concrete"
  assert_contains "$out" "summary: 1 of 2 restarted, 0 nudged, 1 unreached" "the summary must count both mates"
  pass "T4 every named mate is accounted for, including one this home does not know"
}

# --- T5: a refused restart leaves the mate running and says so ---------------
test_refused_restart_falls_back_without_claiming_a_reload() {
  local dir out rc before
  dir=$(new_case refused)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  # muse is a crewmate-only adapter, so the control plane refuses a secondmate
  # relaunch onto it BEFORE stopping anything.
  printf 'muse\n' > "$dir/home/config/secondmate-harness"
  before=$(cat "$dir/fake/command")

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a refused restart must not be reported as a reload"$'\n'"$out"
  assert_contains "$out" "unreached: sm1:" "a failed restart must be reported as unknown"
  assert_contains "$out" "restart outcome is unknown" "the report must not attribute an ambiguous failure"
  assert_not_contains "$out" "nudged: sm1" "a failed restart must not claim the old agent was nudged"
  assert_not_contains "$out" "restarted: sm1" "a refused restart must not be reported as restarted"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "a refusal before the stop should leave the running agent exactly as it was"
  assert_no_grep '^/exit$' "$dir/fake/literal" "a pre-stop refusal must not have stopped the agent"
  pass "T5 a refused restart leaves the mate running and reports an unknown outcome"
}

# --- T6: a remote mate restarts over the fm-on hop, on the parent's pin -------
# The seam decodes what fm-on.sh actually put on the wire, so this pins the
# host-local command and the profile the PARENT resolved, not a local shortcut.
# The far side also models the live mate: it answers the persist request that
# crossed the same hop, on the parent channel, with that request's own token.
setup_remote_case() {  # <case-dir> <id> <ssh-mode>
  local dir=$1 id=$2 mode=$3
  local fb="$dir/fakebin"
  mkdir -p "$dir/$id-home"
  {
    echo "window=remote:$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/$id-home"
    echo "project=$dir/$id-home"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/$id-home"
    echo "remote_host=remote-mac"
    echo "remote_backend=herdr"
    echo "remote_target=fm-remote:2ndmate-$id"
  } > "$dir/home/state/$id.meta"
  printf -- '- %s - remote domain (host: remote-mac; root: /srv/fm; home: /srv/%s; scope: things; projects: p; added 2026-09-03)\n' \
    "$id" "$id" > "$dir/home/data/secondmates.md"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2  # host, fm-remote-entrypoint.sh
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
printf '%s\n' "${rargs[*]}" >> "$FM_FAKE_SSH_LOG"
case "${FM_FAKE_SSH_MODE:-ok}" in
  unreachable) exit 255 ;;
esac
case "${rargs[1]:-}" in
  send)
    # Model the live remote mate: act on the instruction and report back on the
    # parent channel, carrying the correlation token the request embedded.
    if [ -n "${FM_FAKE_ANSWER_STATUS:-}" ]; then
      corr=$(printf '%s' "${rargs[3]:-}" | grep -oE 'corr=[0-9a-f]{16}' | head -1)
      [ -z "$corr" ] || printf 'done [%s]: open records written down\n' "$corr" \
        >> "$FM_FAKE_ANSWER_STATUS"
    fi
    ;;
  relaunch)
    case "${FM_FAKE_SSH_MODE:-ok}" in
      slow-relaunch)
        : > "$FM_FAKE_DIR/remote-relaunch-start"
        /bin/sleep 2
        : > "$FM_FAKE_DIR/remote-relaunch-end"
        ;;
    esac
    printf 'relaunched %s\n' "${rargs[2]}"
    ;;
esac
exit 0
SH
  chmod +x "$fb/fake-ssh"
  : > "$dir/ssh.log"
  export FM_FAKE_SSH_LOG="$dir/ssh.log"
  export FM_FAKE_SSH_MODE="$mode"
  export FM_TEST_SSH_BIN="$fb/fake-ssh"
}

test_remote_mate_restarts_over_the_transport_hop() {
  local dir out rc relaunch_line
  dir=$(new_case remote)
  setup_remote_case "$dir" sm2 ok
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm2.status"
  # The parent's own pin is what the replacement must run on; the remote home's
  # copy of config/secondmate-harness is a different home's file.
  printf 'codex big-model high\n' > "$dir/home/config/secondmate-harness"

  out=$(run_restart "$dir" fm-sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a remote mate should restart over its transport hop"$'\n'"$out"
  assert_contains "$out" "restarted: sm2 on remote-mac (codex)" \
    "a remote restart should be reported with its host and the parent's pinned runtime"
  relaunch_line=$(grep '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1)
  [ -n "$relaunch_line" ] || fail "no relaunch crossed the transport hop"$'\n'"$(cat "$dir/ssh.log")"
  [ "$relaunch_line" = "fm-remote-secondmate-control.sh relaunch sm2 codex big-model high" ] \
    || fail "the host-local relaunch did not carry the parent's resolved profile: $relaunch_line"
  # The persist request crossed the SAME hop before the restart did.
  [ "$(grep -n '^fm-remote-secondmate-control.sh send' "$dir/ssh.log" | head -1 | cut -d: -f1)" \
     -lt "$(grep -n '^fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" | head -1 | cut -d: -f1)" ] \
    || fail "the remote mate was restarted before it was asked to persist"$'\n'"$(cat "$dir/ssh.log")"
  pass "T6 a remote mate restarts through the host-local control plane over the fm-on hop"
}

# --- T7: an unreachable host is unknown, never a claimed reload --------------
test_unreachable_host_is_reported_unknown() {
  local dir out rc
  dir=$(new_case unreachable)
  setup_remote_case "$dir" sm3 unreachable

  out=$(run_restart "$dir" sm3); rc=$?

  expect_code 3 "$rc" "an unreachable host must not be reported as a reload"$'\n'"$out"
  assert_not_contains "$out" "restarted: sm3" "an unreachable host must not be claimed as restarted"
  assert_contains "$out" "sm3:" "the unreachable mate must still be named"
  assert_contains "$out" "could not be delivered" "an unreachable host must be reported as undelivered, not as reloaded"
  pass "T7 an unreachable host is reported honestly instead of claimed as reloaded"
}

# --- T8: a local restart lands on this home's durable pin, and says which -----
test_local_restart_uses_the_home_pin_and_reports_what_ran() {
  local dir out rc
  dir=$(new_case pin)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'codex\n' > "$dir/home/config/secondmate-harness"
  printf 'codex' > "$dir/fake/becomes"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a pinned local restart should succeed"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (codex)" \
    "the restart should land on this home's pin and report the runtime that actually came up"
  [ "$(grep '^harness=' "$dir/home/state/sm1.meta" | tail -1)" = "harness=codex" ] \
    || fail "the durable record did not follow the replacement onto the pinned runtime"
  pass "T8 a local restart re-resolves this home's pin and reports the runtime that came up"
}

# --- T9: an unrelated concurrent reply cannot release the persist gate -------
test_concurrent_reply_cannot_release_persist_gate() {
  local dir out rc state corr rec
  dir=$(new_case correlation)
  add_local_mate "$dir" sm1
  state="$dir/home/state"
  corr=ffffffffffffffff
  rec="$state/pending-replies/$corr"
  cat > "$dir/fake/on-doorbell" <<SH
#!/usr/bin/env bash
[ ! -e "$dir/fake/concurrent-created" ] || exit 0
: > "$dir/fake/concurrent-created"
mkdir -p "$state/pending-replies"
cat > "$rec" <<EOF
phase=awaiting_report
task_id=sm1
parent_status=$state/sm1.status
parent_status_scan_signature=
delivered_epoch=1
resolved_epoch=
resolved_via=
EOF
printf 'done [corr=$corr]: unrelated request answered\n' >> "$state/sm1.status"
SH
  chmod +x "$dir/fake/on-doorbell"

  out=$(FM_TEST_PERSIST_WAIT=0 run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unrelated concurrent answer must not release the persist gate"$'\n'"$out"
  assert_not_contains "$out" "restarted: sm1" "the unrelated answer authorized a restart"
  assert_no_grep '^/exit$' "$dir/fake/literal" "the unrelated answer stopped the mate"
  pass "T9 the persist gate retains its explicitly allocated correlation"
}

# --- T10: one unanswered mate does not hold a confirmed mate behind it -------
test_persist_waits_are_polled_together() {
  local dir out rc exit_line nudge_line
  dir=$(new_case concurrent-waits)
  add_local_mate "$dir" sm1
  add_local_mate "$dir" sm2
  arm_answer "$dir" sm2

  out=$(FM_TEST_PERSIST_WAIT=3 run_restart "$dir" sm1 sm2); rc=$?

  expect_code 3 "$rc" "the unanswered mate should fall back after the confirmed mate restarts"$'\n'"$out"
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  nudge_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | tail -1 | cut -d: -f1)
  [ -n "$exit_line" ] && [ -n "$nudge_line" ] && [ "$exit_line" -lt "$nudge_line" ] \
    || fail "the first mate's timeout held the confirmed second mate behind it: $out"
  pass "T10 pending persist answers are polled as one fleet"
}

# --- T11: a failed post-stop relaunch is not described as a nudge ------------
test_post_stop_failure_is_reported_unreached() {
  local dir out rc
  dir=$(new_case post-stop)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'zsh' > "$dir/fake/becomes"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a post-stop relaunch failure must remain accounted for"$'\n'"$out"
  assert_contains "$out" "unreached: sm1:" "a stopped mate must be reported as unreached"
  assert_contains "$out" "restart outcome is unknown" "the report must not attribute the failed lifecycle operation"
  assert_not_contains "$out" "nudged: sm1" "a durable enqueue must not masquerade as a running mate's nudge"
  assert_contains "$out" "summary: 0 of 1 restarted, 0 nudged, 1 unreached" \
    "the summary must not claim that a stopped mate remains on older instructions with a message"
  pass "T11 post-stop restart failure is never misreported as a nudge"
}

# --- T12: relaunch work does not stop polling other persist answers ----------
test_relaunches_do_not_block_persist_polling() {
  local dir out rc
  dir=$(new_case relaunch-polling)
  setup_remote_case "$dir" sm1 slow-relaunch
  add_local_mate "$dir" sm2
  printf -- '- sm2 - local domain (home: %s; scope: things; projects: p; added 2026-09-03)\n' \
    "$dir/sm2-home" >> "$dir/home/data/secondmates.md"
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  arm_answer "$dir" sm2

  out=$(FM_TEST_PERSIST_WAIT=5 run_restart "$dir" sm1 sm2); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "both confirmed mates should restart independently"$'\n'"$out"
  assert_present "$dir/fake/local-relaunch-during-remote" \
    "the slow first relaunch blocked lifecycle progress for the second mate"
  assert_contains "$out" "summary: 2 of 2 restarted, 0 nudged, 0 unreached" \
    "parallel relaunches were not both accounted for"
  assert_grep 'fm-remote-secondmate-control.sh relaunch sm1 claude default default' "$dir/ssh.log" \
    "an absent remote model and effort pin were not expressed as explicit defaults"
  pass "T12 relaunch waits do not block fleet persistence polling"
}

# --- T13: a worker that cannot publish its result cannot hang the pass -------
test_unpublished_worker_result_is_accounted_for() {
  local dir out rc_file driver i result_dir deadline
  dir=$(new_case worker-result)
  setup_remote_case "$dir" sm1 slow-relaunch
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  out="$dir/restart.out"
  rc_file="$dir/restart.rc"

  ( run_restart "$dir" sm1 > "$out" 2>&1; printf '%s\n' "$?" > "$rc_file" ) &
  driver=$!
  result_dir=
  deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    result_dir=$(find "$dir/home/state" -maxdepth 1 -type d -name '.secondmate-restart.*' -print -quit)
    [ -e "$dir/fake/remote-relaunch-start" ] && [ -n "$result_dir" ] && break
    /bin/sleep 0.01
  done
  [ -n "$result_dir" ] || { kill "$driver" 2>/dev/null || true; fail "restart result directory never appeared"; }
  rm -rf -- "$result_dir"
  i=0
  while kill -0 "$driver" 2>/dev/null && [ "$i" -lt 400 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  if kill -0 "$driver" 2>/dev/null; then
    kill "$driver" 2>/dev/null || true
    wait "$driver" 2>/dev/null || true
    fail "a terminated restart worker left the parent hung"
  fi
  wait "$driver" 2>/dev/null || true
  unset FM_FAKE_ANSWER_STATUS

  [ "$(cat "$rc_file")" = 3 ] || fail "an unpublished worker result did not fail as accounted"
  assert_contains "$(cat "$out")" "restart worker exited before publishing an outcome" \
    "the missing worker result was not reported"
  assert_contains "$(cat "$out")" "summary: 0 of 1 restarted, 0 nudged, 1 unreached" \
    "the missing worker result was not included in the summary"
  pass "T13 a dead restart worker cannot hang the parent"
}

# --- T14: result publication after the first probe remains authoritative -----
test_result_published_while_reaping_is_honored() {
  local dir out rc
  dir=$(new_case result-race)
  setup_remote_case "$dir" sm1 slow-relaunch
  export FM_FAKE_ANSWER_STATUS="$dir/home/state/sm1.status"
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_FAKE_DIR/remote-relaunch-start" ] && [ ! -e "$FM_FAKE_DIR/result-race-injected" ]; then
  result=$(find "$FM_HOME/state" -maxdepth 2 -name '0.result' -print -quit)
  if [ -z "$result" ]; then
    result_dir=$(find "$FM_HOME/state" -maxdepth 1 -type d -name '.secondmate-restart.*' -print -quit)
    if [ -n "$result_dir" ]; then
      printf 'restarted: sm1 on remote-mac (claude)\n' > "$result_dir/0.result"
      : > "$FM_FAKE_DIR/result-race-injected"
      printf 'Z\n'
      exit 0
    fi
  fi
fi
exec /bin/ps "$@"
SH
  chmod +x "$dir/fakebin/ps"

  out=$(run_restart "$dir" sm1); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a result published while the worker is reaped must remain authoritative"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 on remote-mac (claude)" \
    "the result published during the reap window was replaced with a worker failure"
  assert_not_contains "$out" "exited before publishing" \
    "the parent failed to recheck the worker result after wait"
  pass "T14 a result published during reaping is honored"
}

# --- T15: an already-current mate still restarts, end to end -----------------
# The SSHHIP regression, driven through BOTH real commands rather than either
# one's own idea of the other. The mate's home needs no fast-forward at all, so
# the old instruction-diff classifier left it out of every action set and its
# agent kept running the launch-time wiring it started with. The update pass must
# now name it, and the restart pass must then persist its open records and only
# afterwards replace the agent.
test_already_current_mate_restarts_end_to_end() {
  local dir out restart_line ids rc head_before head_after doorbell_line exit_line
  dir=$(new_case already-current)
  add_repo_backed_mate "$dir" sm1
  arm_answer "$dir" sm1
  head_before=$(git -C "$dir/sm1-home" rev-parse HEAD)

  out=$(run_update_in_case "$dir")

  assert_contains "$out" "secondmate sm1: already current" \
    "the fixture must model a home that needs no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" \
    "an already-current live second mate must still be named for restart"
  assert_contains "$out" "nudge-secondmates: none" \
    "a mate named for restart must not also be steered"

  ids=${restart_line#restart-secondmates: }
  # shellcheck disable=SC2086
  out=$(run_restart "$dir" $ids); rc=$?

  expect_code 0 "$rc" "the mate named by the update pass did not restart"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "an already-current mate must actually be replaced"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 nudged, 0 unreached" \
    "the pass must report the reload it performed"
  # Persist strictly before replace, read off the pane transcript.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the already-current mate"
  [ -n "$exit_line" ] || fail "the already-current mate was never stopped, so it was not restarted"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  # Nothing about the home's git state was touched to buy that restart.
  head_after=$(git -C "$dir/sm1-home" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] || fail "the already-current home's checkout moved"
  [ -z "$(git -C "$dir/sm1-home" status --porcelain)" ] \
    || fail "the restart left the mate's home dirty"
  pass "T15 an already-current live mate is named by the update pass and genuinely restarted"
}

# --- T16: an already-current mate that cannot prove a restart stays honest ----
# Same already-current home, a runtime with no recovery-grade state classifier.
# Unconditional restart must not become an unconditional CLAIM of one: the update
# pass routes it to the re-read steer, and the restart pass reports a nudge with
# the agent still running.
test_already_current_unprovable_mate_stays_on_the_nudge_path() {
  local dir out rc restart_line nudge_line before
  dir=$(new_case already-current-unprovable)
  # zellij can never establish "the old agent stopped and the replacement came up".
  add_repo_backed_mate "$dir" sm1 claude zellij
  arm_answer "$dir" sm1
  before=$(cat "$dir/fake/command")

  out=$(run_update_in_case "$dir")

  assert_contains "$out" "secondmate sm1: already current" \
    "the fixture must model a home that needs no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_not_contains "$restart_line" "sm1" \
    "a mate whose restart cannot be proven must stay out of the restart set"
  assert_contains "$nudge_line" "fm-sm1" \
    "a live mate that cannot be restarted must keep the honest re-read steer"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unprovable restart must not report success"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "the fallback must be reported as a nudge"
  assert_not_contains "$out" "restarted: sm1" "an unprovable mate must never be reported as reloaded"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "the unprovable mate's agent was stopped anyway"
  assert_no_grep '^/exit$' "$dir/fake/literal" "nothing may be stopped on the nudge path"
  pass "T16 an already-current mate with an unprovable runtime keeps the honest nudge path"
}

test_omp_secondmate_is_restart_capable() {
  local dir meta
  dir=$(new_case omp-capability)
  meta="$dir/home/state/sm1.meta"
  cat > "$meta" <<EOF
window=fmses:fm-sm1
endpoint_task_id=sm1
worktree=$dir/sm1-home
project=$dir/sm1-home
harness=omp
kind=secondmate
mode=secondmate
home=$dir/sm1-home
EOF
  mkdir -p "$dir/sm1-home/state"
  if ! result=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" bash -c \
    '. "$1/bin/fm-secondmate-restart-lib.sh"; fm_secondmate_restart_capable "$2"; printf "%s %s" "$FM_SECONDMATE_RESTART_HARNESS" "$FM_SECONDMATE_RESTART_PLACEMENT"' \
    _ "$ROOT" "$meta"); then
    fail "OMP secondmate capability was rejected"
  fi
  [ "$result" = "omp local" ] || fail "OMP secondmate did not resolve to a local restart: $result"
  pass "OMP secondmate capability resolves to the restart path"
}

test_omp_secondmate_prepare_relaunch_clears_owned_markers() {
  local dir smhome state meta marker bash_bin version lock_pid marker_pid invalid_lock out path
  dir=$(new_case omp-prepare)
  smhome="$dir/omp-home"; state="$dir/home/state"; meta="$state/omp1.meta"
  marker="$smhome/state/.omp-primary-extension-loaded"
  mkdir -p "$smhome/state"
  bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_omp_primary_closure_paths' \
    _ "$ROOT" > "$dir/closure-paths"
  while IFS= read -r path; do
    mkdir -p "$smhome/$(dirname "$path")"
    cp "$ROOT/$path" "$smhome/$path"
  done < "$dir/closure-paths"
  bash_bin=$(fm_test_realpath "$(command -v bash)")
  version=$(bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_primary_watch_version "$2/.omp/extensions/fm-primary-omp.ts" "$2"' \
    _ "$ROOT" "$smhome") || fail "could not derive the fixture OMP closure"
  lock_pid=99999998
  marker_pid=99999999
  cat > "$meta" <<EOF
window=fm:omp1
harness=omp
kind=secondmate
omp_bun=$bash_bin
omp_bin=$bash_bin
EOF
  : > "$state/omp1.omp-ext.ts"; : > "$state/omp1.omp-ready"; : > "$state/omp1.omp-started"
  mkdir -p "$smhome/state/omp-sessions"
  printf 'saved session\n' > "$smhome/state/omp-sessions/saved.jsonl"
  printf '%s\n' "$smhome/state/omp-sessions/saved.jsonl" > "$smhome/state/.omp-session"

  write_fixture_marker() {
    printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" > "$marker"
  }
  reset_fixture() {
    : > "$state/omp1.omp-ext.ts"; : > "$state/omp1.omp-ready"; : > "$state/omp1.omp-started"
    rm -f "$marker"
    printf '%s\n' "$lock_pid" > "$smhome/state/.lock"
    write_fixture_marker "$version" "$marker_pid" "$bash_bin" "$bash_bin"
  }
  prepare_fixture() {
    bash -c '
      . "$1/bin/fm-backend.sh" || exit 1
      . "$1/bin/fm-control-lib.sh" || exit 1
      fm_backend_agent_state() { printf missing; }
      fm_backend_kill() { return 0; }
      fm_control_omp_secondmate_prepare_relaunch "$2" omp1 "$3" tmux fm:omp1 "$4"
    ' _ "$ROOT" "$state" "$smhome" "$meta" 2>&1
  }
  assert_preserved() {
    [ -e "$marker" ] || [ -L "$marker" ] || fail "refused OMP relaunch removed the primary marker"
    [ -f "$state/omp1.omp-ext.ts" ] && [ -f "$state/omp1.omp-ready" ] \
      && [ -f "$state/omp1.omp-started" ] \
      || fail "refused OMP relaunch removed session artifacts"
    [ "$(cat "$smhome/state/.omp-session")" = "$smhome/state/omp-sessions/saved.jsonl" ] \
      || fail "refused OMP relaunch changed the saved-session pointer"
    [ "$(cat "$smhome/state/omp-sessions/saved.jsonl")" = 'saved session' ] \
      || fail "refused OMP relaunch changed the saved session"
  }

  reset_fixture
  out=$(prepare_fixture) || fail "OMP preparation rejected two proven-dead marker owners: $out"
  [ "$out" = '' ] || fail "OMP preparation emitted unexpected output: $out"
  [ ! -e "$state/omp1.omp-ext.ts" ] || fail "OMP extension artifact survived preparation"
  [ ! -e "$state/omp1.omp-ready" ] || fail "OMP readiness artifact survived preparation"
  [ ! -e "$state/omp1.omp-started" ] || fail "OMP started marker survived preparation"
  [ ! -e "$marker" ] || fail "OMP primary marker survived preparation"
  [ "$(cat "$smhome/state/.omp-session")" = "$smhome/state/omp-sessions/saved.jsonl" ] \
    || fail "OMP preparation changed the exact saved-session pointer"
  [ "$(cat "$smhome/state/omp-sessions/saved.jsonl")" = 'saved session' ] \
    || fail "OMP preparation changed the saved session"

  # Failed probes do not prove absence: permission errors, unknown errors,
  # and a silent failure must preserve both generations of session artifacts.
  cat > "$dir/uncertain-owner" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -0 ]; then
  if [ "$2" = "$FM_TEST_UNCERTAIN_PID" ]; then
    [ -z "$FM_TEST_PROBE_ERROR" ] || printf '%s\n' "$FM_TEST_PROBE_ERROR" >&2
    exit 1
  fi
  printf 'kill: (%s) - No such process\n' "$2" >&2
  exit 1
fi
printf '%s\n' "$*" >> "$FM_TEST_SIGNAL_LOG"
SH
  chmod +x "$dir/uncertain-owner"
  local uncertain_pid probe_error
  for uncertain_pid in "$marker_pid" "$lock_pid"; do
    for probe_error in 'Operation not permitted' 'Permission denied' 'probe unavailable' ''; do
      reset_fixture
      if out=$(FM_RESTART_STOP_CMD="$dir/uncertain-owner" FM_TEST_UNCERTAIN_PID="$uncertain_pid" \
        FM_TEST_PROBE_ERROR="$probe_error" FM_TEST_SIGNAL_LOG="$dir/uncertain-signals" prepare_fixture); then
        fail "OMP preparation accepted an uncertain owner $uncertain_pid: $probe_error"
      fi
      assert_contains "$out" 'owner is unverifiable' "uncertain owner refusal was not actionable"
      assert_absent "$dir/uncertain-signals" "OMP preparation signaled an uncertain owner"
      assert_preserved
    done
  done

  marker_pid=$BASHPID
  reset_fixture
  if out=$(prepare_fixture); then fail "OMP preparation accepted a live marker owner"; fi
  assert_contains "$out" 'primary marker owner is still live' "live marker-owner refusal was not actionable"
  assert_preserved

  cat > "$dir/stoppable-owner" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -0 ]; then
  [ ! -e "$FM_TEST_SIGNAL_LOG" ]
  exit $?
fi
printf '%s\n' "$1" >> "$FM_TEST_SIGNAL_LOG"
SH
  chmod +x "$dir/stoppable-owner"
  for marker_pid in "$lock_pid" 99999999; do
    reset_fixture
    if out=$(FM_RESTART_STOP_CMD="$dir/stoppable-owner" FM_TEST_SIGNAL_LOG="$dir/signals" prepare_fixture); then
      fail "OMP preparation accepted a live stoppable marker owner $marker_pid"
    fi
    assert_contains "$out" 'primary marker owner is still live' \
      "live stoppable marker-owner refusal was not actionable"
    assert_absent "$dir/signals" "OMP preparation signaled an owner despite a live primary marker"
    assert_preserved
  done

  marker_pid=99999999
  reset_fixture
  write_fixture_marker "$version" "$marker_pid" "$bash_bin" "$dir/foreign-omp"
  if out=$(prepare_fixture); then fail "OMP preparation accepted a foreign OMP runtime marker"; fi
  assert_contains "$out" 'runtime does not match the recorded home' "foreign-runtime refusal was not actionable"
  assert_preserved

  reset_fixture
  printf 'sha256:unrecognized\n%s\n%s\n%s\n' "$marker_pid" "$bash_bin" "$bash_bin" > "$marker"
  if out=$(prepare_fixture); then fail "OMP preparation accepted an unexplained marker version"; fi
  assert_contains "$out" 'refusing relaunch' "unexplained marker-version refusal was not actionable"
  assert_preserved

  reset_fixture
  rm -f "$marker"
  ln -s "$dir/absent-marker-target" "$marker"
  if out=$(prepare_fixture); then fail "OMP preparation accepted a symlink marker"; fi
  assert_contains "$out" 'not an ordinary file' "symlink marker refusal was not actionable"
  assert_preserved

  reset_fixture
  rm -f "$marker"
  mkdir "$marker"
  if out=$(prepare_fixture); then fail "OMP preparation accepted a non-file marker"; fi
  assert_contains "$out" 'not an ordinary file' "non-file marker refusal was not actionable"
  rmdir "$marker"
  write_fixture_marker "$version" "$marker_pid" "$bash_bin" "$bash_bin"
  assert_preserved
  reset_fixture
  rm -f "$marker" "$smhome/state/.lock"
  mv "$smhome/state" "$dir/omp-home-state"
  ln -s "$dir/omp-home-state" "$smhome/state"
  if out=$(prepare_fixture); then fail "OMP preparation accepted a symlink home state directory"; fi
  assert_contains "$out" 'OMP home state is not an ordinary directory' \
    "symlink home-state refusal was not actionable"
  [ -f "$state/omp1.omp-ext.ts" ] && [ -f "$state/omp1.omp-ready" ] \
    && [ -f "$state/omp1.omp-started" ] \
    || fail "symlink home-state refusal removed the task's OMP artifacts"
  rm "$smhome/state"
  mv "$dir/omp-home-state" "$smhome/state"


  for invalid_lock in not-a-pid 0 00 01 1; do
    reset_fixture
    printf '%s\n' "$invalid_lock" > "$smhome/state/.lock"
    if out=$(prepare_fixture); then fail "OMP preparation accepted unverifiable lock owner $invalid_lock"; fi
    assert_contains "$out" 'lock owner is unverifiable' \
      "unverifiable lock refusal was not actionable for PID '$invalid_lock'"
    assert_preserved
  done
  reset_fixture
  printf '%s\n%s\n' "$lock_pid" "$marker_pid" > "$smhome/state/.lock"
  if out=$(prepare_fixture); then fail "OMP preparation accepted a multi-line lock PID"; fi
  assert_contains "$out" 'lock owner is unverifiable' \
    "multi-line lock PID refusal was not actionable"
  assert_preserved


  cat > "$dir/fake-live-lock" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -0 ]; then
  if [ "${2:-}" = "$FM_TEST_LOCK_PID" ] && [ ! -e "$FM_TEST_SIGNAL_LOG" ]; then exit 0; fi
  printf 'kill: (%s) - No such process\n' "${2:-}" >&2
  exit 1
fi
printf '%s\n' "$1" >> "$FM_TEST_SIGNAL_LOG"
SH
  chmod +x "$dir/fake-live-lock"
  for path in present absent; do
    reset_fixture
    [ "$path" = present ] || rm -f "$marker"
    if out=$(FM_RESTART_STOP_CMD="$dir/fake-live-lock" FM_TEST_LOCK_PID="$lock_pid" \
      FM_TEST_SIGNAL_LOG="$dir/lock-signals" prepare_fixture); then
      fail "OMP preparation accepted a live stoppable lock owner with marker $path"
    fi
    assert_contains "$out" 'lock owner is still live' "live lock-owner refusal was not actionable"
    assert_absent "$dir/lock-signals" "OMP preparation signaled the live lock owner"
    if [ "$path" = absent ]; then
      assert_absent "$marker" "refused OMP relaunch created a primary marker"
      write_fixture_marker "$version" "$marker_pid" "$bash_bin" "$bash_bin"
    fi
    assert_preserved
  done
  pass "OMP relaunch preparation accepts only owned dead markers and preserves sessions on every refusal"
}

# --- T17: an OMP mate's restart, driven end to end with both real side effects
#          replaced -------------------------------------------------------------
# The whole chain is real here - bin/fm-secondmate-restart.sh's capability
# decision, real fm-send over the real OMP native doorbell, the parent-owned
# persist gate, and bin/fm-control.sh's relaunch transaction with its OMP
# preparation step. Only the two things that would touch this machine are
# replaced: the signal that stops the home session owner, and the launch owner.
# Both stubs record what the world looked like AT THE MOMENT they ran, which is
# how the order below is asserted rather than assumed: the absence probe sees all
# four session artifacts still on disk (so nothing was deleted while the owner
# might still have been running), and the launch sees none of them (so the launch
# owner could never have accepted a duplicate).
omp_marker_list() {  # <case-dir> <id>
  local dir=$1 id=$2
  printf '%s\n' \
    "$dir/home/state/$id.omp-started" \
    "$dir/home/state/$id.omp-ext.ts" \
    "$dir/home/state/$id.omp-ready" \
    "$dir/$id-home/state/.omp-primary-extension-loaded"
}

# A live OMP mate. Its session is a real process holding the real doorbell
# contract - the pid-bound ready marker and the request directory - so fm-send
# reaches it over the native receive adapter it actually uses for OMP, not over
# the composer. The process receipts each request and then answers the persist
# question on the parent channel, which is the same modelling the tmux stub does
# for every other adapter in this file.
copy_omp_primary_closure() {  # <case-dir> <home>
  local dir=$1 home=$2 path
  bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_omp_primary_closure_paths' \
    _ "$ROOT" > "$dir/closure-paths"
  while IFS= read -r path; do
    mkdir -p "$home/$(dirname "$path")"
    cp "$ROOT/$path" "$home/$path"
  done < "$dir/closure-paths"
}
OMP_LISTENER_PID=
add_omp_mate() {  # <case-dir> <id>
  add_local_mate "$1" "$2" omp
  start_omp_session "$1" "$2"
}

# start_omp_session <case-dir> <id>: bring up that modelled session for a mate
# whose home and durable record already exist. When FM_TEST_OMP_EVENTS names a
# file, each answered persist request is also appended there as one line.
start_omp_session() {  # <case-dir> <id>
  local dir=$1 id=$2 marker requests bash_bin i
  local home="$dir/home"
  printf 'omp' > "$dir/fake/command"
  printf 'omp' > "$dir/fake/becomes"
  bash_bin=$(fm_test_realpath "$(command -v bash)")
  {
    echo "omp_bun=$bash_bin"
    echo "omp_bin=$bash_bin"
  } >> "$home/state/$id.meta"
  marker="$home/state/$id.omp-doorbell-ready"
  requests="$marker.requests"
  mkdir -p "$requests"
  cat > "$dir/omp-session" <<'SH'
#!/usr/bin/env bash
set -u
# The doorbell wakes a real session with SIGUSR2; the real extension installs a
# handler for it, so this stand-in must too or the wake would kill it.
trap ':' USR2
printf '%s\n' "$$" > "$FM_TEST_OMP_MARKER"
while :; do
  for pending in "$FM_TEST_OMP_REQUESTS"/request.*.pending; do
    [ -f "$pending" ] || continue
    corr=$(cat "$FM_TEST_OMP_INBOX"/*.msg 2>/dev/null | grep -oE 'corr=[0-9a-f]{16}' | head -1)
    [ -z "$corr" ] || printf 'done [%s]: open records written down\n' "$corr" \
      >> "$FM_TEST_OMP_STATUS"
    [ -z "$corr" ] || [ -z "$FM_TEST_OMP_EVENTS" ] \
      || printf 'persisted %s\n' "$corr" >> "$FM_TEST_OMP_EVENTS"
    mv -f "$pending" "$pending.delivered"
  done
  /bin/sleep 0.02
done
SH
  chmod +x "$dir/omp-session"
  FM_TEST_OMP_MARKER="$marker" FM_TEST_OMP_REQUESTS="$requests" \
    FM_TEST_OMP_INBOX="$home/state/$id.inbox" FM_TEST_OMP_STATUS="$home/state/$id.status" \
    FM_TEST_OMP_EVENTS="${FM_TEST_OMP_EVENTS:-}" "$bash_bin" "$dir/omp-session" &
  OMP_LISTENER_PID=$!
  i=0
  while [ ! -s "$marker" ] && [ "$i" -lt 200 ]; do /bin/sleep 0.02; i=$((i + 1)); done
  [ -s "$marker" ] || fail "the modelled OMP session did not publish its doorbell marker"
  # The pane's foreground process group is what binds a doorbell to a session;
  # only that mapping is faked, so every other process fact stays real.
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'-o tpgid='*) printf '%s\n' "$FM_FAKE_OMP_PID"; exit 0 ;;
esac
exec /bin/ps "$@"
SH
  chmod +x "$dir/fakebin/ps"
  printf '%s\n' "$OMP_LISTENER_PID" > "$dir/fake/pane-pid"
  export FM_FAKE_OMP_PID="$OMP_LISTENER_PID"
}

stop_omp_mate() {
  [ -z "$OMP_LISTENER_PID" ] || kill -TERM "$OMP_LISTENER_PID" 2>/dev/null || true
  OMP_LISTENER_PID=
  unset FM_FAKE_OMP_PID
}

make_omp_restart_stubs() {  # <case-dir> <id> <owner-pid>
  local dir=$1 id=$2 pid=$3
  local sb="$dir/stub"
  mkdir -p "$sb"
  omp_marker_list "$dir" "$id" > "$dir/markers"
  : > "$dir/stop.log"
  : > "$dir/spawn.log"
  cat > "$sb/stop" <<'SH'
#!/usr/bin/env bash
# Stands in for `kill`: "<cmd> <pid>" stops the owner, "<cmd> -0 <pid>" probes it.
set -u
present=0
while IFS= read -r m; do [ ! -e "$m" ] || present=$((present + 1)); done < "$FM_TEST_MARKERS"
if [ "${1:-}" = "-0" ]; then
  if [ -e "$FM_TEST_OWNER_GONE" ]; then
    printf 'probe %s absent markers_present=%d\n' "${2:-}" "$present" >> "$FM_TEST_STOP_LOG"
    printf 'kill: (%s) - No such process\n' "${2:-}" >&2
    exit 1
  fi
  printf 'probe %s alive markers_present=%d\n' "${2:-}" "$present" >> "$FM_TEST_STOP_LOG"
  exit 0
fi
printf 'stopped %s markers_present=%d\n' "${1:-}" "$present" >> "$FM_TEST_STOP_LOG"
: > "$FM_TEST_OWNER_GONE"
exit 0
SH
  cat > "$sb/spawn" <<'SH'
#!/usr/bin/env bash
# Stands in for bin/fm-spawn.sh: records its argv and the world it was handed,
# then publishes a fresh endpoint into the durable record and brings a pane up
# on it, the way a real launch allocating a new pane would.
set -u
present=0
while IFS= read -r m; do [ ! -e "$m" ] || present=$((present + 1)); done < "$FM_TEST_MARKERS"
printf 'spawn %s markers_present=%d\n' "$*" "$present" >> "$FM_TEST_SPAWN_LOG"
sed 's/^window=.*/window='"$FM_TEST_NEW_WINDOW"'/' "$FM_TEST_META" > "$FM_TEST_META.next"
mv -f "$FM_TEST_META.next" "$FM_TEST_META"
printf '%s\n' "${FM_TEST_NEW_WINDOW##*:}" > "$FM_FAKE_DIR/windows"
printf 'omp' > "$FM_FAKE_DIR/command"
exit 0
SH
  chmod +x "$sb/stop" "$sb/spawn"
  export FM_TEST_MARKERS="$dir/markers"
  export FM_TEST_STOP_LOG="$dir/stop.log"
  export FM_TEST_SPAWN_LOG="$dir/spawn.log"
  export FM_TEST_OWNER_GONE="$dir/owner-gone"
  export FM_TEST_META="$dir/home/state/$id.meta"
  export FM_TEST_NEW_WINDOW="reborn:fm-$id"
  export FM_RESTART_STOP_CMD="$sb/stop"
  export FM_RESTART_SPAWN_CMD="$sb/spawn"
  printf '%s\n' "$pid" > "$dir/$id-home/state/.lock"
}

clear_omp_restart_stubs() {
  unset FM_TEST_MARKERS FM_TEST_STOP_LOG FM_TEST_SPAWN_LOG FM_TEST_OWNER_GONE
  unset FM_TEST_META FM_TEST_NEW_WINDOW FM_RESTART_STOP_CMD FM_RESTART_SPAWN_CMD
}

test_omp_restart_stops_proves_cleans_then_relaunches() {
  local dir out rc owner marker primary_marker stop_probe spawn_line version bash_bin smhome
  dir=$(new_case omp)
  printf 'omp\n' > "$dir/home/config/secondmate-harness"
  add_omp_mate "$dir" sm1
  smhome="$dir/sm1-home"
  copy_omp_primary_closure "$dir" "$dir/local-primary"
  git -C "$dir/local-primary" add -A .omp bin/fm-primary-watch-core.ts
  git -C "$dir/local-primary" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'install the OMP primary closure'
  git -C "$dir/local-primary" push -q origin HEAD
  git -C "$smhome" pull -q --ff-only
  owner=987654
  make_omp_restart_stubs "$dir" sm1 "$owner"
  # Keep the task-owned artifacts live until the recorded session owner is
  # proven absent; the primary marker itself has the real four-line contract.
  while IFS= read -r marker; do
    case "$marker" in
      "$smhome/state/.omp-primary-extension-loaded") ;;
      *) printf 'live\n' > "$marker" ;;
    esac
  done < "$dir/markers"
  version=$(bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_primary_watch_version "$2/.omp/extensions/fm-primary-omp.ts" "$2"' \
    _ "$ROOT" "$smhome") || fail "could not derive the current OMP marker version"
  bash_bin=$(fm_test_realpath "$(command -v bash)")
  primary_marker="$smhome/state/.omp-primary-extension-loaded"
  printf '%s\n%s\n%s\n%s\n' "$version" "$owner" "$bash_bin" "$bash_bin" > "$primary_marker"
  out=$(run_restart "$dir" fm-sm1); rc=$?
  stop_omp_mate
  clear_omp_restart_stubs

  expect_code 0 "$rc" "an OMP mate should restart cleanly"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (omp)" \
    "an OMP restart must be reported as a clean reload naming the runtime that came up"

  # 1 + 2. The owner was stopped, and its absence was PROVEN while every session
  # artifact was still on disk.
  stop_probe=$(sed -n 2p "$dir/stop.log")
  [ "$(sed -n 1p "$dir/stop.log")" = "probe $owner absent markers_present=4" ] \
    || fail "the graceful exit did not retire the marker owner before preparation"
  [ "$stop_probe" = "probe $owner absent markers_present=4" ] \
    || fail "lock-owner absence was not proven before cleanup: '$stop_probe'"$'\n'"$(cat "$dir/stop.log")"
  assert_no_grep '^stopped ' "$dir/stop.log" "relaunch preparation must not signal an owner"

  # 3. Every session artifact the launch owner refuses to launch over is gone.
  while IFS= read -r marker; do
    assert_absent "$marker" "an OMP session artifact survived the restart: $marker"
  done < "$dir/markers"

  # 4. The replacement went to the launch owner, on a world it can accept.
  spawn_line=$(sed -n 1p "$dir/spawn.log")
  [ "$spawn_line" = "spawn sm1 --secondmate --harness omp markers_present=0" ] \
    || fail "the replacement launch was not invoked on a cleaned home: '$spawn_line'"$'\n'"$(cat "$dir/spawn.log")"
  [ "$(wc -l < "$dir/spawn.log" | tr -d '[:space:]')" = 1 ] \
    || fail "the restart launched more than one replacement"$'\n'"$(cat "$dir/spawn.log")"

  # 5. The durable record names the endpoint the launch published, and no longer
  # the retired one.
  assert_grep "window=reborn:fm-sm1" "$dir/home/state/sm1.meta" \
    "the durable record was not reconciled to the endpoint the launch published"
  assert_no_grep "window=fmses:fm-sm1" "$dir/home/state/sm1.meta" \
    "the durable record still names the retired endpoint"
  pass "T17 an OMP restart stops the owner, proves it gone, retires its session artifacts, then relaunches"
}

# --- T18: a local OMP mate restarts after an update changes its loaded closure
# A remote mate's host binding refuses a session whose loaded extension closure
# an update superseded unless a recorded fast-forward explains it. The local
# placement's delivery binds no closure, so the same update must still reach the
# running local session, have it persist, and only then stop and relaunch it.
test_local_omp_restart_after_extension_closure_update() {
  local dir out rc seed repo smhome marker bash_bin loaded tracked persisted_line stop_line owner
  dir=$(new_case local-omp-update)
  printf 'omp\n' > "$dir/home/config/secondmate-harness"
  add_repo_backed_mate "$dir" sm1 omp
  seed="$dir/seed" repo="$dir/fmrepo" smhome="$dir/sm1-home"
  # The firstmate origin ships the OMP primary closure, and the home is on it
  # when its session starts.
  bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_omp_primary_closure_paths' _ "$ROOT" \
    > "$dir/closure-paths"
  while IFS= read -r path; do
    mkdir -p "$seed/$(dirname "$path")"
    cp "$ROOT/$path" "$seed/$path"
  done < "$dir/closure-paths"
  git -C "$seed" add -A
  git -C "$seed" commit -qm 'ship the OMP primary closure'
  git -C "$seed" push -q origin main
  git -C "$repo" pull -q --ff-only
  git -C "$smhome" checkout -q --detach main

  owner=987654
  make_omp_restart_stubs "$dir" sm1 "$owner"
  FM_TEST_OMP_EVENTS="$dir/stop.log" start_omp_session "$dir" sm1
  bash_bin=$(fm_test_realpath "$(command -v bash)")
  loaded=$(bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_primary_watch_version "$2/.omp/extensions/fm-primary-omp.ts" "$2"' \
    _ "$ROOT" "$smhome") || fail "could not derive the session's loaded closure"
  marker="$smhome/state/.omp-primary-extension-loaded"
  printf '%s\n%s\n%s\n%s\n' "$loaded" "$owner" "$bash_bin" "$bash_bin" > "$marker"

  # The update crosses an extension change while that session keeps running.
  printf '// extension change shipped by the update\n' >> "$seed/bin/fm-primary-watch-core.ts"
  git -C "$seed" commit -qam 'change the OMP primary extension closure'
  git -C "$seed" push -q origin main
  out=$(run_update_in_case "$dir")
  assert_contains "$out" "restart-secondmates: fm-sm1" \
    "the update did not name the running local OMP mate for restart"
  tracked=$(bash -c '. "$1/bin/fm-primary-watch-version-lib.sh"; fm_primary_watch_version "$2/.omp/extensions/fm-primary-omp.ts" "$2"' \
    _ "$ROOT" "$smhome") || fail "could not derive the updated tracked closure"
  [ "$(sed -n 1p "$marker")" = "$loaded" ] && [ "$tracked" != "$loaded" ] \
    || fail "the update did not leave the running session on a superseded closure"

  out=$(run_restart "$dir" fm-sm1); rc=$?
  stop_omp_mate
  clear_omp_restart_stubs

  expect_code 0 "$rc" "a local OMP mate should restart after its extension closure changed"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (omp)" \
    "the local OMP restart after the update was not reported as a clean reload"
  assert_contains "$(cat "$dir/home/state/sm1.inbox"/*.msg)" "Open-record persistence" \
    "the superseded local session never received the persist request"
  persisted_line=$(grep -n '^persisted corr=' "$dir/stop.log" | head -1 | cut -d: -f1)
  stop_line=$(grep -n "^probe $owner absent " "$dir/stop.log" | head -1 | cut -d: -f1)
  [ -n "$persisted_line" ] && [ -n "$stop_line" ] && [ "$persisted_line" -lt "$stop_line" ] \
    || fail "the superseded local session was not asked to persist before it stopped"$'\n'"$(cat "$dir/stop.log")"
  pass "T18 a local OMP mate persists and restarts after an update changes its loaded closure"
}

# --- T19: watcher scratch churn in a mate's home never blocks its restart -----
# A live home's watcher keeps creating and removing .hash-*/.count-*/.last-*
# scratch files, so a directory walk of state/ can fail on an entry that vanished
# mid-scan. The relaunch checkpoint's guarantee is that every child *.meta record
# is readable, so a failing walk must not refuse while those records still count.
test_vanished_scratch_file_does_not_block_restart() {
  local dir out rc real_find
  dir=$(new_case findrace)
  add_local_mate "$dir" smf1
  arm_answer "$dir" smf1
  printf 'window=x:fm-c1\n' > "$dir/smf1-home/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smf1-home/state/c2.meta"
  : > "$dir/smf1-home/state/.hash-0"
  : > "$dir/smf1-home/state/.count-0"
  : > "$dir/smf1-home/state/.last-0"
  real_find=$(command -v find)
  cat > "$dir/fakebin/find" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "$dir/smf1-home/state" ]; then
    echo "find: \$arg/.hash-0: No such file or directory" >&2
    exit 1
  fi
done
exec "$real_find" "\$@"
SH
  chmod +x "$dir/fakebin/find"

  out=$(run_restart "$dir" smf1); rc=$?

  expect_code 0 "$rc" "a vanished watcher scratch file must not refuse the restart"$'\n'"$out"
  assert_contains "$out" "restarted: smf1" "readable child records must still allow the replacement launch"
  assert_grep 'children=2' "$dir/home/state/smf1.control-relaunch" \
    "readable child records must still be counted by the checkpoint"
  pass "T19 a vanished watcher scratch file does not block a mate's restart"
}

# --- T20: a mate home whose state cannot be listed still refuses --------------
test_unlistable_state_still_refuses_restart() {
  local dir out rc before
  if [ "$(id -u)" = 0 ]; then
    pass "T20 unlistable state check skipped as root (mode 000 does not restrict root)"
    return 0
  fi
  dir=$(new_case unlistable)
  add_local_mate "$dir" smu1
  arm_answer "$dir" smu1
  printf 'window=x:fm-c1\n' > "$dir/smu1-home/state/c1.meta"
  before=$(cat "$dir/fake/command")
  chmod 000 "$dir/smu1-home/state"

  out=$(run_restart "$dir" smu1); rc=$?
  chmod 755 "$dir/smu1-home/state"

  expect_code 3 "$rc" "an unlistable state directory must not be reported as a reload"$'\n'"$out"
  assert_not_contains "$out" "restarted: smu1" "an unlistable home must not be reported as restarted"
  assert_contains "$out" "no readable state directory" \
    "the refusal should name the unlistable home state directory"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "an unlistable state refusal must leave the running agent exactly as it was"
  assert_no_grep '^/exit$' "$dir/fake/literal" "an unlistable state refusal must not have stopped the agent"
  pass "T20 a mate home whose state cannot be listed still refuses the restart"
}
test_persist_gates_and_asks_only_for_open_records
test_persist_precedes_restart
test_arrived_answer_precedes_deadline_check
test_answer_between_resolution_and_timeout_wins
test_unprovable_runtime_falls_back
test_unknown_mate_is_accounted_for
test_refused_restart_falls_back_without_claiming_a_reload
test_local_restart_uses_the_home_pin_and_reports_what_ran
test_remote_mate_restarts_over_the_transport_hop
test_unreachable_host_is_reported_unknown
test_concurrent_reply_cannot_release_persist_gate
test_persist_waits_are_polled_together
test_post_stop_failure_is_reported_unreached
test_relaunches_do_not_block_persist_polling
test_unpublished_worker_result_is_accounted_for
test_result_published_while_reaping_is_honored
test_already_current_mate_restarts_end_to_end
test_already_current_unprovable_mate_stays_on_the_nudge_path
test_omp_secondmate_is_restart_capable
test_omp_secondmate_prepare_relaunch_clears_owned_markers
test_omp_restart_stops_proves_cleans_then_relaunches
test_local_omp_restart_after_extension_closure_update

test_vanished_scratch_file_does_not_block_restart
test_unlistable_state_still_refuses_restart
echo "# all fm-secondmate-restart tests passed"
