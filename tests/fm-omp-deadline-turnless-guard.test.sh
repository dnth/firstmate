#!/usr/bin/env bash
# Opt-in provider-free guard for the interactive-OMP expired-deadline contract.
#
# bin/fm-spawn.sh never passes --max-time to a kind=secondmate launch because a
# persistent secondmate must idle indefinitely behind liveness supervision. This
# guard pins WHY: once an interactive OMP Agent's absolute deadline passes, a
# submitted prompt lands in the transcript but no turn opens, no model call
# runs, nothing is thrown, and the process stays alive - turnless while
# supervision still sees a live endpoint (the recurring coordinator stall in
# data/fm-mac-coordinator-recurring-stall-rca/report.md section 3.3). If a
# future OMP upgrade changes any of that, this guard fails instead of letting
# the fix's premise silently rot.
#
# No provider call happens: the fake stream function throws if OMP ever calls
# the model, so a model attempt is an immediate loud failure. The guard drives
# the installed OMP agent core directly through bun.
set -u

if [ "${FM_OMP_DEADLINE_GUARD:-0}" != 1 ]; then
  echo "skip: set FM_OMP_DEADLINE_GUARD=1 to run the provider-free OMP expired-deadline guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUN_BIN=${FM_OMP_DEADLINE_GUARD_BUN:-}
if [ -z "$BUN_BIN" ]; then
  BUN_BIN=$(command -v bun || true)
fi
if { [ -z "$BUN_BIN" ] || [ ! -x "$BUN_BIN" ]; } && [ -x "$HOME/.bun/bin/bun" ]; then
  BUN_BIN=$HOME/.bun/bin/bun
fi
[ -n "$BUN_BIN" ] && [ -x "$BUN_BIN" ] \
  || fail "OMP deadline guard requires a bun runtime (FM_OMP_DEADLINE_GUARD_BUN, PATH, or ~/.bun/bin/bun)"

# The guard imports the pi-agent-core sources backing the installed omp
# executable. FM_OMP_AGENT_CORE overrides the probe; otherwise the canonical
# binary's bun global-install root is tried, then `bun pm bin -g`'s.
AGENT_CORE=${FM_OMP_AGENT_CORE:-}
if [ -z "$AGENT_CORE" ]; then
  OMP_BIN=$("$ROOT/bin/fm-omp-capabilities.sh" --require-max-time --print-binary 2>/dev/null || true)
  if [ -n "$OMP_BIN" ]; then
    candidate="$(dirname "$OMP_BIN")/../install/global/node_modules/@oh-my-pi/pi-agent-core/src/index.ts"
    [ -f "$candidate" ] && AGENT_CORE=$candidate
  fi
fi
if [ -z "$AGENT_CORE" ]; then
  bun_global=$("$BUN_BIN" pm bin -g 2>/dev/null || true)
  candidate="${bun_global%/bin}/install/global/node_modules/@oh-my-pi/pi-agent-core/src/index.ts"
  [ -n "$bun_global" ] && [ -f "$candidate" ] && AGENT_CORE=$candidate
fi
[ -n "$AGENT_CORE" ] && [ -f "$AGENT_CORE" ] \
  || fail "OMP deadline guard could not locate pi-agent-core sources (set FM_OMP_AGENT_CORE)"

TMP_ROOT=$(fm_test_tmproot fm-omp-deadline-turnless)
DRIVER="$TMP_ROOT/deadline-guard.ts"
OUT="$TMP_ROOT/out.txt"
cat > "$DRIVER" <<'TS'
const corePath = process.env.FM_GUARD_AGENT_CORE;
if (!corePath) throw new Error("FM_GUARD_AGENT_CORE is not set");
const { Agent } = await import(corePath);
async function run(label: string, deadline: number | undefined) {
  let modelCalls = 0;
  const events: string[] = [];
  const agent = new Agent({
    initialState: { systemPrompt: "x", model: { id: "fake", name: "fake", provider: "fake", api: "openai-responses", baseUrl: "http://127.0.0.1:9", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 1000, maxTokens: 100 } as any, tools: [] },
    deadline,
    streamFn: (() => { modelCalls += 1; throw new Error("MODEL CALLED"); }) as any,
  });
  agent.subscribe((e: any) => { events.push(e.type + (e.message?.role ? `:${e.message.role}` : "")); });
  try { await agent.prompt(": Firstmate instruction waiting: list ..."); } catch (err) { events.push(`throw:${(err as Error).message}`); }
  console.log(`${label}: modelCalls=${modelCalls} turn_start=${events.includes("turn_start")} events=[${events.join(",")}] transcript=[${agent.state.messages.map((m: any) => m.role).join(",")}] isStreaming=${agent.state.isStreaming}`);
}
await run("expired-deadline", Date.now() - 1000);
await run("future-deadline", Date.now() + 3_600_000);
await run("no-deadline", undefined);
TS

out=$(FM_GUARD_AGENT_CORE="$AGENT_CORE" "$BUN_BIN" "$DRIVER" 2>&1) || {
  printf '%s\n' "$out" >&2
  fail "OMP deadline guard driver did not run to completion"
}
printf '%s\n' "$out" | tee "$OUT"

expired=$(printf '%s\n' "$out" | sed -n 's/^expired-deadline *: //p')
future=$(printf '%s\n' "$out" | sed -n 's/^future-deadline *: //p')
nodeadline=$(printf '%s\n' "$out" | sed -n 's/^no-deadline *: //p')
[ -n "$expired" ] && [ -n "$future" ] && [ -n "$nodeadline" ] \
  || fail "OMP deadline guard produced incomplete output: $out"

# The specimen: an expired absolute deadline swallows the prompt into the
# transcript, skips the turn and the model entirely, stays non-streaming, and
# throws nothing - alive but permanently turnless.
assert_contains "$expired" "modelCalls=0" \
  "expired OMP session called the model - the deadline no longer prevents turns"
assert_contains "$expired" "turn_start=false" \
  "expired OMP session emitted turn_start - the deadline no longer prevents turns"
assert_contains "$expired" "events=[agent_start,message_start:user,message_end:user,agent_end]" \
  "expired OMP session diverged from the alive-but-turnless event sequence"
assert_contains "$expired" "transcript=[user]" \
  "expired OMP session transcript diverged from the user-message-only record"
assert_contains "$expired" "isStreaming=false" \
  "expired OMP session stayed in a streaming state - supervision would misread it"
assert_not_contains "$expired" "throw:" \
  "expired OMP session threw instead of idling - a different failure mode than the stall"

# The controls: a future deadline and no deadline each start a normal turn.
assert_contains "$future" "modelCalls=1" \
  "live-deadline OMP session never called the model - the guard's fake stream was not exercised"
assert_contains "$future" "turn_start=true" \
  "live-deadline OMP session never started a turn"
assert_contains "$nodeadline" "modelCalls=1" \
  "undeadlined OMP session never called the model - the guard's fake stream was not exercised"
assert_contains "$nodeadline" "turn_start=true" \
  "undeadlined OMP session never started a turn"

pass "OMP expired interactive deadline leaves the session alive but turnless; live and absent deadlines still turn"
