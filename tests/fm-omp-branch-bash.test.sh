#!/usr/bin/env bash
# Regression for the OMP 18.3.x branch-bash break
# (docs/omp-supervision-branch.md). OMP 18.3.0 moved the bash tool's env
# parameter behind service mode ("ready and env require a service name."), but
# its legacy createBashToolDefinition shim still forwards the spawnHook's env
# into the native bash tool's execute, so every branch bash call threw before
# spawning. The extension now hands the shim a BashOperations runner
# (lib/fm-async-exec.ts's bashToolOperations), so the branch tool executes
# through firstmate's own spawn with the injected actor environment and never
# reaches the removed env path.
#
# These probes run the REAL installed omp binary: each loads a probe extension
# that builds the branch bash tool through the same two seams the extension
# uses - the repo's bashToolOperations export (undefined where the seam does
# not exist, so an unfixed tree takes the shim's native env path and fails
# with the reported throw) plus the branch spawnHook's actor-injection shape -
# then invokes the tool's execute directly in a scratch home. A machine
# without omp skips explicitly; on pre-18.3 OMP the native env path works, so
# the probes are green there either way.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OMP_BIN=$(command -v omp 2>/dev/null || true)
[ -n "$OMP_BIN" ] || { echo "skip: omp executable not found for the OMP branch bash regression"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-omp-branch-bash)

# The probe extension mirrors fm-branch-supervision-omp.ts's exact wiring: the
# shim gets the repo's operations runner plus a spawnHook that injects the
# confused-agent-grade actor env (FM_SUPERVISION_ACTOR=branch,
# FM_LEASE_HOLDER_PID, and the scriptEnv home overrides) behind the readonly
# prelude. The bash command comes from FM_PROBE_COMMAND; the outcome lands in
# FM_PROBE_OUT as "OK\n<tool output>" or "ERR <message>".
write_probe_extension() { # <path>
  cat > "$1" <<'EOF'
import { writeFileSync } from "node:fs";
import { createBashToolDefinition } from "@oh-my-pi/pi-coding-agent/extensibility/legacy-pi-coding-agent-shim";
import * as asyncExec from "__FM_ASYNC_EXEC__";

const out = process.env.FM_PROBE_OUT ?? "/dev/null";
const home = process.env.FM_PROBE_HOME ?? process.cwd();
const command = process.env.FM_PROBE_COMMAND ?? "true";
const fmRoot = "__FM_ROOT__";

export default function () {
  void (async () => {
    const tool = createBashToolDefinition(fmRoot, {
      operations: asyncExec.bashToolOperations,
      spawnHook: (context) => ({
        ...context,
        command: `readonly FM_SUPERVISION_ACTOR FM_LEASE_HOLDER_PID\n(\n${context.command}\n)`,
        env: {
          ...context.env,
          PI_CODING_AGENT: "true",
          FM_HOME: home,
          FM_ROOT_OVERRIDE: fmRoot,
          FM_STATE_OVERRIDE: `${home}/state`,
          FM_CONFIG_OVERRIDE: `${home}/config`,
          FM_SUPERVISION_ACTOR: "branch",
          FM_LEASE_HOLDER_PID: String(process.pid),
        },
      }),
    });
    try {
      const result = await tool.execute("call-1", { command }, undefined, undefined);
      const text = (result.content ?? []).map((part) => part.text ?? "").join("");
      writeFileSync(out, `OK\n${text}\n`);
    } catch (error) {
      writeFileSync(out, `ERR ${error instanceof Error ? error.message : String(error)}\n`);
    }
    process.exit(0);
  })();
}
EOF
  sed -i.bak \
    -e "s|__FM_ASYNC_EXEC__|$ROOT/.omp/extensions/lib/fm-async-exec.ts|" \
    -e "s|__FM_ROOT__|$ROOT|" "$1" || return 1
  rm -f -- "$1.bak" || return 1
}

# A bound on the whole probe invocation: the extension exits the process once
# it lands the outcome, so the ceiling only guards a probe that never runs.
TIMEOUT_CMD=
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=gtimeout
fi

# run_probe <home> <command>: run the probe under the real omp and print the
# outcome file. Fails the test when the probe never produced an outcome.
run_probe() { # <home> <command>
  local home=$1 command=$2 probe out
  probe="$home/probe.ts"
  out="$home/probe-out.txt"
  write_probe_extension "$probe" || fail "probe extension write failed"
  rm -f -- "$out"
  local -a bound=()
  [ -z "$TIMEOUT_CMD" ] || bound=("$TIMEOUT_CMD" 120)
  (cd "$home" && env \
    FM_PROBE_OUT="$out" FM_PROBE_HOME="$home" FM_PROBE_COMMAND="$command" \
    ${bound[@]+"${bound[@]}"} "$OMP_BIN" --no-extensions -e "$probe" -p "noop") >"$home/omp-stdout.txt" 2>&1 || true
  [ -s "$out" ] || fail "probe produced no outcome file: $(tail -5 "$home/omp-stdout.txt" 2>/dev/null)"
  cat "$out"
}

test_branch_bash_executes_with_injected_actor_env() {
  local home out
  home="$TMP_ROOT/env-home"
  mkdir -p "$home/state" "$home/config"
  # shellcheck disable=SC2016 # The command is evaluated inside the probe's tool shell, not this script.
  out=$(run_probe "$home" 'printf "ACTOR=%s\nHOLDER=%s\nHOME=%s\nROOT=%s\n" "$FM_SUPERVISION_ACTOR" "$FM_LEASE_HOLDER_PID" "$FM_HOME" "$FM_ROOT_OVERRIDE"')
  case "$out" in OK*) ;; *) fail "branch bash call did not execute: $out" ;; esac
  assert_contains "$out" "ACTOR=branch" "the branch actor identity was not injected"
  case "$out" in
    *"HOLDER="[0-9]*) ;;
    *) fail "the lease holder pid was not injected" ;;
  esac
  assert_contains "$out" "HOME=$home" "FM_HOME was not injected"
  assert_contains "$out" "ROOT=$ROOT" "FM_ROOT_OVERRIDE was not injected"
  pass "the branch bash tool executes its command with the injected branch actor environment"
}

test_branch_bash_actor_env_cannot_be_overridden() {
  local home out
  home="$TMP_ROOT/readonly-home"
  mkdir -p "$home/state" "$home/config"
  # shellcheck disable=SC2016 # The command is evaluated inside the probe's tool shell, not this script.
  out=$(run_probe "$home" 'FM_SUPERVISION_ACTOR=main; printf "UNREACHABLE\n"')
  case "$out" in ERR*) ;; *) fail "a branch bash override of the actor env was not refused: $out" ;; esac
  assert_contains "$out" "readonly variable" "the readonly guard did not fire on an actor-env override"
  assert_not_contains "$out" "UNREACHABLE" "the command continued past the refused override"
  pass "an in-shell override of the injected actor env fails loudly on the readonly guard"
}

test_branch_actor_drains_and_acks_granted_wake_end_to_end() {
  local home state drain_script out main_out
  home="$TMP_ROOT/e2e-home"
  state="$home/state"
  mkdir -p "$state" "$home/config"
  printf 'signal: task-a\n' > "$state/task-a.status"
  printf 'project=project-a\nwindow=default:wA:p1\n' > "$state/task-a.meta"
  printf '1\t1\tsignal\ttask-a.status\tsignal: task-a\n' > "$state/.wake-queue"

  # Grant the queued row to the branch exactly the way the extension does:
  # this test shell's PID is the live owner for the grant's whole lifetime.
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" activate $$ e2e-gen \
    || fail "branch grant activation failed"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" publish e2e-gen 1 \
    || fail "branch grant publish failed"

  # While the grant is live a main-actor drain must not present the row or
  # claim an acknowledgement for it - it only sees the held notice.
  main_out=$(env -u FM_SUPERVISION_ACTOR FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" 2>&1 || true)
  assert_contains "$main_out" "WAKE ROWS HELD BY SUPERVISION BRANCH" "a main drain did not report the branch-held row"
  assert_not_contains "$main_out" "WAKE_ACK_REQUIRED" "a main drain claimed an acknowledgement over branch-held rows"

  # The branch bash tool runs the drain and the acknowledgement it prints,
  # end to end, under the injected branch actor env.
  drain_script=$(cat <<EOS
drain_out=\$("$ROOT/bin/fm-wake-drain.sh" 2>&1) || { printf 'DRAIN_FAILED\n%s\n' "\$drain_out"; exit 1; }
printf '%s\n' "\$drain_out"
seq=\$(printf '%s\n' "\$drain_out" | sed -n 's/.*--ack-through \([0-9][0-9]*\).*/\1/p' | head -1)
gen=\$(printf '%s\n' "\$drain_out" | sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\).*/\1/p' | head -1)
[ -n "\$seq" ] && [ -n "\$gen" ] || { printf 'NO_ACK_COMMAND\n'; exit 1; }
"$ROOT/bin/fm-wake-drain.sh" --ack-through "\$seq" --recovery-generation "\$gen" 2>&1
EOS
)
  out=$(run_probe "$home" "$drain_script")
  case "$out" in OK*) ;; *) fail "the branch-actor wake drain did not execute: $out" ;; esac
  assert_contains "$out" "signal: task-a" "the branch drain did not present its granted row"
  assert_contains "$out" "WAKE_ACK_REQUIRED" "the branch drain printed no acknowledgement command"
  [ ! -s "$state/.wake-queue" ] || fail "the branch acknowledgement left rows in the wake queue: $(cat "$state/.wake-queue")"
  assert_absent "$state/.branch-eligible-rows" "the consumed branch grant was not retired"
  pass "a granted wake row is presented and acknowledged by the branch actor end to end, not left for main"
}

test_branch_bash_executes_with_injected_actor_env
test_branch_bash_actor_env_cannot_be_overridden
test_branch_actor_drains_and_acks_granted_wake_end_to_end
