#!/usr/bin/env bash
# fm-control.sh <task> switch-model: the verb's typed results, the meta it does
# and does not change, and what it reports when the wait expires.
#
# The worker side is the REAL .omp/extensions/lib/fm-task-model-switch.ts driven
# by a fake OMP host (tests/fm-omp-model-switch-host.mjs), started as a
# long-lived process the way a worker's extension is. Only OMP itself and the
# terminal backend are faked. What the installed OMP does with the calls is
# proven by tests/fm-omp-model-switch-live-e2e.test.sh.
#
# Each case protects one consumer-visible bug: meta changed by a refused switch,
# a timeout reported as "unchanged" while the request could still land, a
# cancelled request that applies later, a late acknowledgement that leaves meta
# divergent unreported, or a partial result reported as success.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v bun >/dev/null 2>&1 || { echo "skip: bun not found (required by the OMP identity probe)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-control-switch-model)
CONTROL="$ROOT/bin/fm-control.sh"
HOST="$ROOT/tests/fm-omp-model-switch-host.mjs"
CATALOG='[{"provider":"p","id":"a","efforts":["low","high","max"]},{"provider":"p","id":"b","efforts":["low","medium","high"]},{"provider":"q","id":"c"},{"provider":"locked","id":"d","efforts":["low"]}]'
AVAILABLE='["p/a","p/b","q/c"]'
PIDS="$TMP_ROOT/pids"
: > "$PIDS"

cleanup() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
  done < "$PIDS"
  fm_test_cleanup
}
trap cleanup EXIT

# A real bun process stands in for the pane's agent: the OMP identity probe
# reads /proc/<pid>/exe. The fake tmux and ps answer exactly what the
# agent-state classifier asks for an exact OMP worker.
make_case() {  # <name> [harness] [kind]
  local name=$1 harness=${2:-omp} kind=${3:-ship} omp_bin bun
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  FAKEBIN="$CASE_DIR/fakebin"
  ID="msw-$name"
  STATE_DIR="$HOME_DIR/state"
  META="$STATE_DIR/$ID.meta"
  REQ_DIR="$STATE_DIR/$ID.omp-doorbell-ready.requests"
  CTL_DIR="$CASE_DIR/ctl"
  mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$STATE_DIR" "$FAKEBIN" "$CTL_DIR" "$CASE_DIR/wt" "$CASE_DIR/project"
  bun -e 'setInterval(() => {}, 1000000)' >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$PIDS"
  printf '%s\n' "$!" > "$CASE_DIR/agent.pid"
  ln -sf "$(command -v bun)" "$FAKEBIN/bun"
  printf '#!/usr/bin/env bun\nconsole.log("omp");\n' > "$FAKEBIN/omp"
  chmod +x "$FAKEBIN/omp"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
fmt=
for a in "$@"; do fmt=$a; done
case "${1:-}" in
  list-windows) printf 'fm-%s\n' "${FM_FAKE_TASK:?}" ;;
  display-message)
    case "$fmt" in
      '#{pane_current_command}') printf 'bun\n' ;;
      '#{pane_pid}') printf '4242\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
agent_pid=$(cat "${FM_FAKE_AGENT_PID_FILE:?}" 2>/dev/null || printf '4242')
case "$*" in
  *"-o tpgid="*) printf '%s\n' "$agent_pid" ;;
  *"-o args= -p"*) printf 'bun %s\n' "${FM_FAKE_OMP_BIN:?}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKEBIN/tmux" "$FAKEBIN/ps"
  omp_bin=$(cd "$FAKEBIN" && pwd -P)/omp
  bun=$(readlink -f "$FAKEBIN/bun")
  FAKE_OMP_BIN=$omp_bin
  fm_write_meta "$META" \
    "endpoint_task_id=$ID" "worktree=$CASE_DIR/wt" "project=$CASE_DIR/project" \
    "harness=$harness" "kind=$kind" "mode=no-mistakes" "yolo=off" \
    "model=p/a" "effort=low" "spawn_gen=gen1" \
    "omp_bin=$omp_bin" "omp_bun=$bun" "window=ses-$ID:fm-$ID" "backend=tmux"
}

# start_responder [ENV=value ...]: the worker's extension, answering gen1.
start_responder() {
  env FM_HOST_REQUEST_DIR="$REQ_DIR" FM_HOST_SPAWN_GEN=gen1 FM_HOST_CATALOG="$CATALOG" \
    FM_HOST_AVAILABLE="$AVAILABLE" FM_HOST_CURRENT=p/a FM_HOST_THINKING=low \
    FM_HOST_CONTROL_DIR="$CTL_DIR" FM_HOST_LOG="$CASE_DIR/host.log" "$@" \
    node "$HOST" responder > "$CASE_DIR/host.out" 2>&1 &
  RESPONDER_PID=$!
  printf '%s\n' "$RESPONDER_PID" >> "$PIDS"
  local n=0
  while [ ! -f "$REQ_DIR/model-switch.ready" ]; do
    n=$((n + 1))
    [ "$n" -lt 200 ] || fail "the fake worker never published its model-switch ready marker: $(cat "$CASE_DIR/host.out")"
    sleep 0.05
  done
}

control_env() {
  env PATH="$FAKEBIN:$PATH" TMUX=fake,1,0 FM_HOME="$HOME_DIR" \
    FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log" FM_FAKE_TASK="$ID" \
    FM_FAKE_AGENT_PID_FILE="$CASE_DIR/agent.pid" FM_FAKE_OMP_BIN="$FAKE_OMP_BIN" \
    FM_CONTROL_POLL=0.1 \
    FM_CONTROL_SETTLE_WAIT=1 "$@"
}

run_control() {  # <fm-control args...> -> CONTROL_OUT, CONTROL_RC (stdout and stderr together)
  CONTROL_OUT=$(control_env "$CONTROL" "$ID" "$@" 2>&1)
  CONTROL_RC=$?
}

meta_val() {  # <key>
  grep "^$1=" "$META" | tail -1 | cut -d= -f2-
}

host_calls() {  # prints the host's recorded setModel/setThinkingLevel calls
  [ -f "$CASE_DIR/host.log" ] || return 0
  jq -r 'select(.call != null) | "\(.call) \(.args | join(","))"' "$CASE_DIR/host.log"
}

request_id_of() {  # <output> -> the request=<id> token
  printf '%s' "$1" | sed -n 's/.*request=\([^ ]*\).*/\1/p' | head -1
}

assert_meta() {  # <model> <effort> <label>
  [ "$(meta_val model)" = "$1" ] && [ "$(meta_val effort)" = "$2" ] \
    || fail "$3: meta reads model=$(meta_val model) effort=$(meta_val effort), expected model=$1 effort=$2"
  [ "$(grep -c '^model=' "$META")" -eq 1 ] && [ "$(grep -c '^effort=' "$META")" -eq 1 ] \
    || fail "$3: meta carries a duplicate model= or effort= record"
}

wait_for_file() {  # <path> <label> [tries]
  local n=0
  while [ ! -e "$1" ]; do
    n=$((n + 1))
    [ "$n" -lt "${3:-200}" ] || fail "timed out waiting for $2 ($1)"
    sleep 0.05
  done
}

# The request id is minted by fm-control, so wait for any queued request file.
wait_for_queued_request() {
  local n=0
  while ! ls "$REQ_DIR"/model-switch.ms-*.request.json >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -lt 200 ] || fail "timed out waiting for fm-control to queue its request ($(ls "$REQ_DIR" 2>&1))"
    sleep 0.05
  done
}

# --- success: model and thinking level change, meta follows ------------------

make_case success
start_responder
run_control switch-model --model p/b --effort medium
expect_code 0 "$CONTROL_RC" "switch-model success: $CONTROL_OUT"
case "$CONTROL_OUT" in switched\ "$ID"\ request=ms-*) ;; *) fail "success output is not a typed switched result: $CONTROL_OUT" ;; esac
assert_contains "$CONTROL_OUT" "model=p/a->p/b" "success output omits the model change"
assert_contains "$CONTROL_OUT" "effort=low->medium" "success output omits the thinking-level change"
assert_contains "$CONTROL_OUT" "boundary=idle" "an idle worker did not report the idle boundary"
assert_contains "$CONTROL_OUT" "verified=extension-readback" "success is not tied to the extension's readback"
assert_meta p/b medium "success"
[ "$(host_calls)" = $'setModel p/b\nsetThinkingLevel medium' ] \
  || fail "the worker saw unexpected calls: $(host_calls)"
! grep -q 'send-keys' "$CASE_DIR/tmux.log" || fail "switch-model typed into the terminal: $(cat "$CASE_DIR/tmux.log")"
RID=$(request_id_of "$CONTROL_OUT")
[ -f "$REQ_DIR/model-switch.$RID.ack.json.folded" ] || fail "the folded acknowledgement was not retained as evidence"
pass "switch-model: an idle worker switches model and thinking level, meta follows the verified readback, nothing is typed"

# --- refusals leave meta and the live model alone ----------------------------

for spec in "nowhere/none:unknown-model" "locked/d:no-credentials"; do
  target=${spec%%:*}
  reason=${spec##*:}
  make_case "refuse-${reason}"
  start_responder
  run_control switch-model --model "$target" --effort low
  expect_code 1 "$CONTROL_RC" "switch-model $target must be refused"
  case "$CONTROL_OUT" in refused\ "$ID"\ *) ;; *) fail "refusal is not a typed refused result: $CONTROL_OUT" ;; esac
  assert_contains "$CONTROL_OUT" "reason=$reason" "the refusal did not carry the typed reason $reason"
  assert_contains "$CONTROL_OUT" "meta=unchanged" "the refusal did not say meta is unchanged"
  assert_meta p/a low "refusal $reason"
  [ -z "$(host_calls)" ] || fail "a refused switch still touched the worker's session: $(host_calls)"
  pass "switch-model refused $reason: typed reason, meta unchanged, the worker keeps its model"
done

# --- a request made mid-turn waits for the boundary --------------------------

make_case midturn
start_responder FM_HOST_BUSY=1
( run_control switch-model --model p/b --effort high --wait 20; printf '%s\n%s\n' "$CONTROL_RC" "$CONTROL_OUT" > "$CASE_DIR/midturn.out" ) &
BG_PID=$!
printf '%s\n' "$BG_PID" >> "$PIDS"
wait_for_queued_request
sleep 0.5
[ -z "$(host_calls)" ] || fail "a busy worker's session was touched before it settled: $(host_calls)"
assert_meta p/a low "mid-turn request, before the boundary"
: > "$CTL_DIR/agent_end"
wait "$BG_PID" || true
[ "$(sed -n '1p' "$CASE_DIR/midturn.out")" = 0 ] || fail "the mid-turn switch failed: $(cat "$CASE_DIR/midturn.out")"
assert_contains "$(cat "$CASE_DIR/midturn.out")" "boundary=agent_end" "the mid-turn request was not applied at settled idle"
assert_meta p/b high "mid-turn request, after the boundary"
[ "$(host_calls | head -1)" = "setModel p/b" ] || fail "settling did not apply the model first: $(host_calls)"
[ "$(jq -r 'select(.call == "setModel") | .idle' "$CASE_DIR/host.log")" = true ] \
  || fail "the switch was applied while the session still read busy"
pass "switch-model mid-turn: the in-flight run stays on the old model and the request applies at settled idle"

# --- a timeout before the claim withdraws the request, provably --------------

make_case cancel
start_responder FM_HOST_BUSY=1
run_control switch-model --model p/b --effort medium --wait 01
expect_code 1 "$CONTROL_RC" "a timed-out switch must not succeed"
case "$CONTROL_OUT" in cancelled\ "$ID"\ request=ms-*) ;; *) fail "timeout before the claim is not a typed cancelled result: $CONTROL_OUT" ;; esac
assert_contains "$CONTROL_OUT" "proof=request-withdrawn-before-claim" "the cancellation carries no proof"
assert_contains "$CONTROL_OUT" "meta=unchanged" "cancellation did not say meta is unchanged"
RID=$(request_id_of "$CONTROL_OUT")
[ -f "$REQ_DIR/model-switch.$RID.cancelled" ] && [ ! -e "$REQ_DIR/model-switch.$RID.request.json" ] \
  || fail "the cancelled request is still queued: $(ls "$REQ_DIR")"
assert_meta p/a low "cancelled request"
: > "$CTL_DIR/agent_end"
sleep 0.6
[ -z "$(host_calls)" ] && [ ! -e "$REQ_DIR/model-switch.$RID.ack.json" ] \
  || fail "a later boundary applied a request that was cancelled: $(host_calls)"
run_control switch-model --status
expect_code 0 "$CONTROL_RC" "status after a proven cancellation: $CONTROL_OUT"
assert_contains "$CONTROL_OUT" "unresolved=0" "a withdrawn request is still reported unresolved"
assert_contains "$CONTROL_OUT" "last-state=cancelled" "status does not report the cancellation"
pass "switch-model timeout: the request is withdrawn atomically before the claim, a later boundary applies nothing, and status says so"

# --- a late acknowledgement is reported, then reconciled ---------------------

make_case late
start_responder FM_HOST_SET_DELAY_MS=3500
run_control switch-model --model p/b --effort medium --wait 1
expect_code 1 "$CONTROL_RC" "a switch whose acknowledgement is late must not report success"
case "$CONTROL_OUT" in pending-unknown\ "$ID"\ request=ms-*) ;; *) fail "timeout after the claim is not a typed pending-unknown result: $CONTROL_OUT" ;; esac
RID=$(request_id_of "$CONTROL_OUT")
assert_contains "$CONTROL_OUT" "state=claimed-unacknowledged" "pending-unknown does not say the request was claimed"
assert_contains "$CONTROL_OUT" "switch-model --status" "pending-unknown does not say how to reconcile"
case "$CONTROL_OUT" in *unchanged*) fail "a timeout after the claim claimed nothing changed: $CONTROL_OUT" ;; esac
assert_meta p/a low "late acknowledgement, before it lands"
run_control switch-model --status
expect_code 1 "$CONTROL_RC" "status while the request is unresolved must say so"
assert_contains "$CONTROL_OUT" "unresolved $ID request=$RID state=claimed-unacknowledged" "status does not name the unresolved request"
wait_for_file "$REQ_DIR/model-switch.$RID.ack.json" "the late acknowledgement" 200
run_control switch-model --status
expect_code 0 "$CONTROL_RC" "status after the late acknowledgement: $CONTROL_OUT"
assert_contains "$CONTROL_OUT" "model-switch-reconciled $ID request=$RID outcome=applied" "status did not report the late acknowledgement it folded"
assert_contains "$CONTROL_OUT" "meta-model=p/b" "status did not bring meta to the live model"
assert_contains "$CONTROL_OUT" "reconciled=1 unresolved=0" "status did not count the reconciliation"
assert_meta p/b medium "late acknowledgement, after reconcile"
pass "switch-model late acknowledgement: pending-unknown names the request, status reconciles meta to the live model"

# The next verb call reconciles too, before it acts.
make_case latenext
start_responder FM_HOST_SET_DELAY_MS=3500
run_control switch-model --model p/b --effort high --wait 1
expect_code 1 "$CONTROL_RC" "latenext must time out first"
RID=$(request_id_of "$CONTROL_OUT")
wait_for_file "$REQ_DIR/model-switch.$RID.ack.json" "the late acknowledgement" 200
run_control relaunch
expect_code 1 "$CONTROL_RC" "a relaunch without --note is refused"
assert_contains "$CONTROL_OUT" "model-switch-reconciled $ID request=$RID outcome=applied" "the next verb did not report the late acknowledgement"
assert_meta p/b high "reconcile on the next verb"
pass "switch-model late acknowledgement: the next verb call folds it into meta before acting"

# --- partial: the model switched, the thinking level did not -----------------

make_case partial
start_responder 'FM_HOST_CLAMP={"medium":"low"}'
run_control switch-model --model p/b --effort medium
expect_code 1 "$CONTROL_RC" "a partial switch must not exit 0"
case "$CONTROL_OUT" in partial\ "$ID"\ request=ms-*) ;; *) fail "a clamped thinking level is not a typed partial result: $CONTROL_OUT" ;; esac
assert_contains "$CONTROL_OUT" "model=p/a->p/b" "partial does not report the live model"
assert_contains "$CONTROL_OUT" "effort-requested=medium effort-live=low" "partial does not report both thinking values"
assert_contains "$CONTROL_OUT" "reason=thinking-mismatch" "partial carries no typed reason"
assert_contains "$CONTROL_OUT" "rolled-back=no" "partial claims a rollback that did not happen"
assert_meta p/b low "partial"
[ "$(host_calls | grep -c '^setModel')" -eq 1 ] || fail "a partial result rolled the model back or retried: $(host_calls)"
pass "switch-model partial: both thinking values are reported, nothing is claimed rolled back, meta follows the live state"

# --- a record that changed under the verb is never rewritten -----------------

make_case stalemeta
start_responder FM_HOST_BUSY=1
( run_control switch-model --model p/b --effort medium --wait 20; printf '%s\n%s\n' "$CONTROL_RC" "$CONTROL_OUT" > "$CASE_DIR/stalemeta.out" ) &
printf '%s\n' "$!" >> "$PIDS"
BG_PID=$!
wait_for_queued_request
# A relaunch publishes a new worker generation while the verb is still waiting.
awk '/^spawn_gen=/ { print "spawn_gen=gen2"; next } { print }' "$META" > "$META.new" && mv -f "$META.new" "$META"
: > "$CTL_DIR/agent_end"
wait "$BG_PID" || true
[ "$(sed -n '1p' "$CASE_DIR/stalemeta.out")" = 1 ] || fail "a switch whose record changed underneath it exited 0: $(cat "$CASE_DIR/stalemeta.out")"
assert_contains "$(cat "$CASE_DIR/stalemeta.out")" "meta-stale $ID request=ms-" "a record that could not be updated is not a typed meta-stale result"
assert_contains "$(cat "$CASE_DIR/stalemeta.out")" "live-model=p/b" "meta-stale does not report the live model"
[ "$(meta_val model)" = p/a ] && [ "$(meta_val spawn_gen)" = gen2 ] \
  || fail "a record from another worker generation was rewritten: model=$(meta_val model) spawn_gen=$(meta_val spawn_gen)"
ls "$REQ_DIR"/model-switch.ms-*.ack.json >/dev/null 2>&1 \
  || fail "the unapplied acknowledgement was retired although meta was never updated"
pass "switch-model: a record that changed underneath it is never rewritten, and the unfolded acknowledgement is kept"

# --- a worker the verb cannot reach is refused with the reason ---------------

make_case notomp claude
run_control switch-model --model p/b
expect_code 1 "$CONTROL_RC" "a non-OMP worker must be refused"
assert_contains "$CONTROL_OUT" "has no in-session model-switch channel" "a non-OMP refusal does not name the missing channel"
assert_meta p/a low "non-OMP"

make_case mate omp secondmate
run_control switch-model --model p/b
expect_code 1 "$CONTROL_RC" "an OMP secondmate must be refused"
assert_contains "$CONTROL_OUT" "secondmate runs the primary adapter" "a secondmate refusal does not say why"

make_case nochannel
run_control switch-model --model p/b
expect_code 1 "$CONTROL_RC" "a worker with no channel must be refused"
assert_contains "$CONTROL_OUT" "relaunch it to load the current extension" "a channel-less worker is not told to relaunch"
assert_meta p/a low "no channel"
run_control switch-model --status
expect_code 1 "$CONTROL_RC" "status on a worker with no channel must be refused"
assert_contains "$CONTROL_OUT" "no model-switch channel" "status did not explain the refusal"

make_case deadext
start_responder
: > "$CTL_DIR/quit"
n=0
while kill -0 "$RESPONDER_PID" 2>/dev/null; do n=$((n + 1)); [ "$n" -lt 100 ] || fail "the fake worker did not exit"; sleep 0.05; done
jq -n --argjson pid "$RESPONDER_PID" '{schema:"fm-model-switch.ready.v1", pid:$pid, spawnGen:"gen1"}' > "$REQ_DIR/model-switch.ready"
run_control switch-model --model p/b
expect_code 1 "$CONTROL_RC" "a stale ready marker must be refused"
assert_contains "$CONTROL_OUT" "is not running" "a dead extension is not named"
assert_meta p/a low "dead extension"

make_case othergen
start_responder
jq -n --argjson pid "$RESPONDER_PID" '{schema:"fm-model-switch.ready.v1", pid:$pid, spawnGen:"gen0"}' > "$REQ_DIR/model-switch.ready"
run_control switch-model --model p/b
expect_code 1 "$CONTROL_RC" "another generation's ready marker must be refused"
assert_contains "$CONTROL_OUT" "belongs to worker generation gen0" "a stale generation is not named"
pass "switch-model refuses a non-OMP worker, a secondmate, a worker without the channel, a dead extension, and another generation's marker"

make_case nativeeffort
start_responder FM_HOST_THINKING=off
run_control switch-model --model q/c --wait 08
expect_code 0 "$CONTROL_RC" "a decimal wait with a leading zero must work: $CONTROL_OUT"
assert_contains "$CONTROL_OUT" "effort=off->off" "the result must preserve native thinking readback"
assert_meta q/c off "native thinking outside the launch vocabulary must be recorded"
pass "switch-model records and reports the native thinking level"

make_case reconciliation
start_responder
run_control switch-model --model p/b --effort high
expect_code 0 "$CONTROL_RC" "could not establish the newer switch: $CONTROL_OUT"
jq -n '{schema:"fm-model-switch.ack.v1", id:"ms-older", spawnGen:"gen1", ackSequence:1,
  outcome:"applied", target:{model:"p/a",effort:"low"}, after:{model:"p/a",thinking:"low"}}' \
  > "$REQ_DIR/model-switch.ms-older.ack.json"
jq -n '{schema:"fm-model-switch.ack.v1", id:"ms-mismatch", spawnGen:"gen1", ackSequence:9007199254740991,
  outcome:"applied", target:{model:"p/a",effort:"low"}, after:{model:"q/c",thinking:"low"}}' \
  > "$REQ_DIR/model-switch.ms-mismatch.ack.json"
run_control switch-model --status
expect_code 0 "$CONTROL_RC" "status did not account for both acknowledgements: $CONTROL_OUT"
assert_contains "$CONTROL_OUT" "outcome=refused reason=readback-mismatch" "a divergent readback must be visible"
assert_meta p/b high "an older or unverified receipt must not replace the latest verified switch"
pass "switch-model status preserves newer verified state and reports a divergent readback"

# An acknowledgement without the emitted sequence has no order, so it is never folded.
make_case legacyack
start_responder
jq -n '{schema:"fm-model-switch.ack.v1", id:"ms-legacy", spawnGen:"gen1", ackedAtMs:4102444800000,
  outcome:"applied", target:{model:"q/c",effort:""}, after:{model:"q/c",thinking:"low"}}' \
  > "$REQ_DIR/model-switch.ms-legacy.ack.json"
run_control switch-model --status
expect_code 1 "$CONTROL_RC" "an acknowledgement with no sequence must stay unresolved: $CONTROL_OUT"
assert_contains "$CONTROL_OUT" "unresolved $ID request=ms-legacy state=acknowledged-unfolded" "an unordered acknowledgement was treated as resolved"
assert_meta p/a low "an acknowledgement without a sequence"
pass "switch-model: an acknowledgement without the emitted sequence is left unresolved and never folded"

# --- raced: a provider request prepared while the switch applied ------------

make_case raced
start_responder FM_HOST_SET_DELAY_MS=1500
( run_control switch-model --model p/b --effort medium --wait 20; printf '%s\n%s\n' "$CONTROL_RC" "$CONTROL_OUT" > "$CASE_DIR/raced.out" ) &
BG_PID=$!
printf '%s\n' "$BG_PID" >> "$PIDS"
n=0
while [ -z "$(host_calls)" ]; do
  n=$((n + 1))
  [ "$n" -lt 200 ] || fail "the worker never started applying the switch: $(cat "$CASE_DIR/host.out")"
  sleep 0.05
done
: > "$CTL_DIR/context"
wait "$BG_PID" || true
[ "$(sed -n '1p' "$CASE_DIR/raced.out")" = 1 ] || fail "a raced switch exited 0: $(cat "$CASE_DIR/raced.out")"
case "$(sed -n '2p' "$CASE_DIR/raced.out")" in raced\ "$ID"\ request=ms-*) ;; *) fail "a race is not a typed raced result: $(cat "$CASE_DIR/raced.out")" ;; esac
assert_contains "$(cat "$CASE_DIR/raced.out")" "model=p/a->p/b" "the raced result omits the live model change"
assert_contains "$(cat "$CASE_DIR/raced.out")" "may have used either model" "the raced result does not say what is uncertain"
assert_meta p/b medium "raced: meta follows the verified live state"
pass "switch-model raced: a provider request prepared mid-apply is a typed raced result, not a clean switch, and meta follows the live state"

run_control switch-model --status
expect_code 1 "$CONTROL_RC" "a folded race must remain visible in status: $CONTROL_OUT"
assert_contains "$CONTROL_OUT" "last-state=raced" "status treated a folded race as clean"

make_case laterace
start_responder
jq -n '{schema:"fm-model-switch.ack.v1", id:"ms-late-race", spawnGen:"gen1", ackSequence:1,
  outcome:"partial", raced:true, reason:"thinking-mismatch", target:{model:"p/b",effort:"high"},
  before:{model:"p/a",thinking:"low"}, after:{model:"p/b",thinking:"minimal"}}' \
  > "$REQ_DIR/model-switch.ms-late-race.ack.json"
run_control switch-model --status
expect_code 1 "$CONTROL_RC" "a late raced partial must fail status: $CONTROL_OUT"
assert_contains "$CONTROL_OUT" "raced $ID request=ms-late-race outcome=partial" "status omitted the race or the partial outcome"
assert_contains "$CONTROL_OUT" "last-state=raced" "a late race was classified as clean"
assert_meta p/b minimal "a raced partial still records verified native readback"
jq -n '{schema:"fm-model-switch.ack.v1", id:"ms-late-refusal", spawnGen:"gen1", ackSequence:2,
  outcome:"refused", raced:true, reason:"model-mismatch", target:{model:"p/a"},
  before:{model:"p/b",thinking:"minimal"}, after:{model:"q/c",thinking:null}}' \
  > "$REQ_DIR/model-switch.ms-late-refusal.ack.json"
run_control relaunch
expect_code 1 "$CONTROL_RC" "a relaunch without --note is refused"
assert_contains "$CONTROL_OUT" "raced $ID request=ms-late-refusal outcome=refused" "lifecycle reconciliation omitted a raced refusal"
assert_meta p/b minimal "a raced refusal cannot write unverified readback"
pass "switch-model preserves raced outcomes in status and lifecycle reconciliation"

make_case no_monotonic
start_responder
real_perl=$(command -v perl) || fail "Perl is required by the model-switch verb"
cat > "$FAKEBIN/perl" <<SH
#!/usr/bin/env bash
case "\${1:-}" in -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC) exit 1 ;; esac
exec "$real_perl" "\$@"
SH
chmod +x "$FAKEBIN/perl"
run_control switch-model --model p/b --wait 1
expect_code 1 "$CONTROL_RC" "an unavailable monotonic clock must refuse publication: $CONTROL_OUT"
assert_contains "$CONTROL_OUT" "monotonic clock is unavailable" "the missing clock was not reported"
assert_meta p/a low "no monotonic clock"
run_control switch-model --status
expect_code 0 "$CONTROL_RC" "the refused publication must leave no unresolved request: $CONTROL_OUT"
assert_contains "$CONTROL_OUT" "last-request=none" "the worker channel saw a request without a usable deadline"
pass "switch-model refuses to publish when the monotonic clock is unavailable"

# --- argument contract -------------------------------------------------------

make_case args
start_responder
for bad in "--model nomodel" "--model p/b --effort default" "--model p/b --effort ultra" "--status --model p/b" \
           "--model p/b --wait 00" "--model p/b --wait=3" "--model p/b --wait" "--model p/b --wait 9999" "--model p/ b" "" \
           "--model=p/b" "--model p/b --effort=low"; do
  # shellcheck disable=SC2086 # the cases are deliberately word-split argument lists
  run_control switch-model $bad
  [ "$CONTROL_RC" -ne 0 ] || fail "switch-model accepted the invalid arguments: '$bad'"
done
run_control interrupt --model p/b
[ "$CONTROL_RC" -ne 0 ] || fail "interrupt accepted --model"
assert_contains "$CONTROL_OUT" "apply to 'relaunch' only" "a non-switch verb accepted --model"
run_control interrupt --status
[ "$CONTROL_RC" -ne 0 ] || fail "interrupt accepted --status"
assert_contains "$CONTROL_OUT" "apply to 'switch-model' only" "a non-switch verb accepted --status"
assert_meta p/a low "argument contract"
[ -z "$(host_calls)" ] || fail "an invalid invocation reached the worker"
pass "switch-model: malformed arguments are refused before anything is written"
