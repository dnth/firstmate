#!/usr/bin/env bash
# Opt-in live guard for the OMP compact-adviser idle deferral, run against the
# real installed OMP.
#
# This is the harness-dependent half of the pair: the portable regression in
# tests/fm-omp-compact-adviser.test.sh pins the deferral logic with fakes, while
# this guard proves the vendor's real ordering (agent_end fires while the owning
# prompt is still in flight, idle one macrotask later) and that the shipped
# adviser therefore renders its person-only hint.
# It refuses to pass without a real OMP, and names the harness version on failure.
#
#   FM_OMP_COMPACT_ADVISER_LIVE_E2E=1 bash tests/fm-omp-compact-adviser-live-e2e.test.sh
#
# Optional: FM_OMP_COMPACT_ADVISER_LIVE_MODEL (default anthropic/claude-haiku-4-5),
# FM_OMP_COMPACT_ADVISER_LIVE_TIMEOUT (seconds, default 120).
set -u

if [ "${FM_OMP_COMPACT_ADVISER_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_COMPACT_ADVISER_LIVE_E2E=1 to run the real-OMP compact-adviser guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODEL=${FM_OMP_COMPACT_ADVISER_LIVE_MODEL:-anthropic/claude-haiku-4-5}
WAIT_SECONDS=${FM_OMP_COMPACT_ADVISER_LIVE_TIMEOUT:-120}
HINT_FRAGMENT="Run /compact to save tokens"

command -v omp >/dev/null 2>&1 \
  || fail "no installed OMP binary: this guard proves the OMP harness only and refuses to pass without it"
command -v tmux >/dev/null 2>&1 \
  || fail "the compact-adviser live guard requires tmux"
command -v node >/dev/null 2>&1 \
  || fail "the compact-adviser live guard requires node"
OMP_VERSION=$(omp --version 2>&1 | head -1) || fail "OMP version probe failed"
[ -n "$OMP_VERSION" ] || fail "OMP version probe returned no version"

LAB=$(fm_test_tmproot fm-omp-compact-adviser-live)
PROJECT="$LAB/project"
TRACE="$LAB/trace.jsonl"
SOCKET="fm-omp-compact-adviser-live-$$"
REAL_TMUX=$(command -v tmux)

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

# The lab is a throwaway home: the shipped adviser library, an opt-in record with
# no API key, and a lab-only extension that installs the SHIPPED adviser with a
# stubbed judge (no TypeSafe key is needed or read). Nothing here is copied from a
# live home, and the lab never touches the captain's session, config, or state.
mkdir -p "$PROJECT/.omp/extensions/lib" "$PROJECT/config" "$PROJECT/state" "$PROJECT/sessions"
cp -R "$ROOT/.omp/extensions/lib/compact-adviser" "$PROJECT/.omp/extensions/lib/"
printf '{"version":1,"mode":"hint","minContextTokens":1000,"logRequests":false}\n' \
  > "$PROJECT/config/compact-adviser.json"

cat > "$PROJECT/.omp/extensions/lab-adviser.ts" <<'TS'
// Lab-only extension: records OMP's real agent_end ordering and installs the
// shipped compact adviser with a stubbed judge, so the guard needs no API key.
import { appendFileSync } from "node:fs";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { installAdviser } from "./lib/compact-adviser/adviser.ts";
import { ConfigStore } from "./lib/compact-adviser/config.ts";

const trace = process.env.FMCA_LAB_TRACE;
function note(o: Record<string, unknown>): void {
  if (!trace) return;
  try {
    appendFileSync(trace, `${JSON.stringify({ t: new Date().toISOString(), ...o })}\n`);
  } catch {
    /* tracing must never break the lab */
  }
}

export default function (omp: ExtensionAPI): void {
  note({ ev: "lab-load" });
  omp.on("agent_end", (event, ctx) => {
    if (event.willContinue === true) return;
    note({ ev: "agent_end", idle: ctx.isIdle(), pending: ctx.hasPendingMessages() });
    setTimeout(() => {
      try {
        note({ ev: "agent_end+macrotask", idle: ctx.isIdle() });
      } catch (error) {
        note({ ev: "agent_end+macrotask-error", message: String(error) });
      }
    }, 0);
  });
  const api = omp as unknown as { appendEntry: (type: string, data: unknown) => unknown };
  const realAppend = api.appendEntry.bind(omp);
  api.appendEntry = (type: string, data: unknown) => {
    if (type === "compact-adviser:state") {
      const d = (data ?? {}) as Record<string, unknown>;
      note({ ev: "state", completed: d.completed, lastHintKey: d.lastHintKey, failures: d.failures });
    }
    return realAppend(type, data);
  };

  const configDir = `${process.cwd()}/config`;
  const store = new ConfigStore(configDir);
  if (!store.exists()) {
    note({ ev: "lab-no-optin" });
    return;
  }
  installAdviser(omp, {
    configDir,
    logDir: `${process.cwd()}/state`,
    key: () => "lab-stub-key",
    evaluate: async () => {
      note({ ev: "stub-judge-called" });
      return {
        done: {
          choice: "finished",
          probabilities: { finished: 0.99, not_finished: 0.005, unclear: 0.005 },
          confidence: 0.99,
        },
        shape: {
          choice: "hands_on",
          probabilities: { hands_on: 0.99, coordinating: 0.005, unclear: 0.005 },
          confidence: 0.99,
        },
        model: "lab-stub",
        inputTokens: 0,
        outputTokens: 0,
      };
    },
  });
  note({ ev: "lab-installed" });
}
TS

# The adviser only judges a checkpoint whose conversation snapshot clears its
# coarse 20k-token skip, so the guarded turn carries filler the way a real
# primary session would.
node -e 'process.stdout.write("context ".repeat(12000) + "reply with the single word ok")' \
  > "$LAB/prompt.txt" || fail "could not build the live-guard prompt"

# env -i keeps the launch clean of any inherited FM_* worker identity; HOME is
# preserved only so the installed OMP can authenticate its model.
{
  printf '#!/usr/bin/env bash\ncd %q\nexec env -i \\\n' "$PROJECT"
  printf '  HOME=%q USER=%q LOGNAME=%q PATH=%q \\\n' \
    "$HOME" "${USER:-user}" "${LOGNAME:-${USER:-user}}" "$PATH"
  printf '  TERM=xterm-256color LANG=%q SHELL=/bin/bash \\\n' "${LANG:-C.UTF-8}"
  printf '  FMCA_LAB_TRACE=%q \\\n' "$TRACE"
  printf '  omp --model %q --thinking low --session-dir %q \\\n' "$MODEL" "$PROJECT/sessions"
  # shellcheck disable=SC2016 # "$(cat ...)" expands in the lab launcher, not here.
  printf '  --no-extensions -e %q "$(cat %q)"\n' \
    "$PROJECT/.omp/extensions/lab-adviser.ts" "$LAB/prompt.txt"
} > "$LAB/launch.sh"
chmod +x "$LAB/launch.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s lab -x 220 -y 50 -c "$PROJECT" "bash '$LAB/launch.sh'"

deadline=$((SECONDS + WAIT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  # The adviser persists state for every settled checkpoint, so a state line is
  # the earliest reliable "the guarded turn settled" marker. Give the deferred
  # settled check a short grace to finish before judging the outcome, so a
  # missing hint fails in seconds instead of burning the whole timeout.
  if grep -qF '"ev":"state"' "$TRACE" 2>/dev/null; then
    sleep 3
    break
  fi
  "$REAL_TMUX" -L "$SOCKET" has-session -t lab 2>/dev/null || break
  sleep 1
done
sleep 1
PANE=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t lab 2>/dev/null || true)

[ -s "$TRACE" ] \
  || fail "OMP $OMP_VERSION produced no compact-adviser live trace within ${WAIT_SECONDS}s, so this guard checked nothing"
assert_grep '"ev":"lab-load"' "$TRACE" "OMP $OMP_VERSION did not load the lab extension"
assert_grep '"ev":"lab-installed"' "$TRACE" "OMP $OMP_VERSION loaded the lab but never installed the adviser"

END_LINE=$(grep -m1 -F '"ev":"agent_end"' "$TRACE" || true)
[ -n "$END_LINE" ] \
  || fail "OMP $OMP_VERSION never emitted agent_end for the guarded turn, so the guard could not observe the ordering: $(tail -3 "$TRACE")"
case "$END_LINE" in
  *'"idle":false'*) : ;;
  *)
    fail "OMP $OMP_VERSION reported an already-idle session inside agent_end ($END_LINE); the deferral premise no longer holds, so re-verify the adapter instead of shipping this guard"
    ;;
esac

MACRO_LINE=$(grep -m1 -F '"ev":"agent_end+macrotask"' "$TRACE" || true)
[ -n "$MACRO_LINE" ] \
  || fail "OMP $OMP_VERSION never completed a macrotask after agent_end ($END_LINE)"
case "$MACRO_LINE" in
  *'"idle":true'*) : ;;
  *)
    fail "OMP $OMP_VERSION still reported the prompt in flight one macrotask after agent_end ($MACRO_LINE); the bounded retry, not one macrotask, must carry this harness now"
    ;;
esac

assert_grep '"ev":"stub-judge-called"' "$TRACE" \
  "OMP $OMP_VERSION: the deferred settled check never reached the judge"
assert_grep '"lastHintKey":"' "$TRACE" \
  "OMP $OMP_VERSION: the deferred checkpoint judged but never persisted a hint"
case "$PANE" in
  *"$HINT_FRAGMENT"*) : ;;
  *)
    fail "OMP $OMP_VERSION: the hint was decided and persisted but never rendered above the composer"
    ;;
esac

pass "compact-adviser live: $OMP_VERSION defers the settled check to idle and shows the /compact hint"
