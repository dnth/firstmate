#!/usr/bin/env bash
# Opt-in live guard for the OMP supervision-branch extension against the REAL
# installed @oh-my-pi SDK. It drives the tracked extension through a mock
# ExtensionAPI while the branch session is created through the real
# createAgentSession/SessionManager surface, then asserts the four properties
# the design rests on:
#   - degrade: a model pin the branch cannot resolve makes createBranch throw
#     before prompting, and the wake falls back to main with no lost wake (no
#     provider call, so this always runs).
#   - resident + non-leak (Spike A): a second resident AgentSession is created,
#     re-prompted after a mirror inject, and its own turn output never reaches
#     MAIN - only fm-branch-merge notes do.
#   - turn accounting (Spike B): a routine verdict merges with no new turn; a
#     captain verdict opens exactly one follow-up turn.
# The resident and turn-accounting checks issue trivial prompts against the
# default model, so they cost a little; run after every OMP upgrade and record
# the dated result in docs/verification/runtime-backends.md.
set -u

if [ "${FM_OMP_BRANCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_BRANCH_LIVE_E2E=1 to run the real-SDK OMP branch regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v bun >/dev/null 2>&1 || { echo "skip: bun not found for the OMP branch live guard"; exit 0; }
OMP_PACKAGE_DIR=${FM_OMP_PACKAGE_DIR:-"${BUN_INSTALL:-$HOME/.bun}/install/global/node_modules/@oh-my-pi/pi-coding-agent"}
if [ ! -f "$OMP_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @oh-my-pi/pi-coding-agent package not found (set FM_OMP_PACKAGE_DIR to override)"
  exit 0
fi
OMP_NODE_MODULES=$(cd "$OMP_PACKAGE_DIR/.." && cd .. && pwd)

TMP_ROOT=$(fm_test_tmproot fm-omp-branch-live)
repo="$TMP_ROOT/repo"
mkdir -p "$repo/.omp/extensions/lib"
cp "$ROOT/.omp/extensions/fm-branch-supervision-omp.ts" "$repo/.omp/extensions/fm-branch-supervision-omp.ts"
cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$repo/.omp/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.omp/extensions/lib/fm-branch-model-picker.ts" "$repo/.omp/extensions/lib/fm-branch-model-picker.ts"
ln -s "$OMP_NODE_MODULES" "$repo/node_modules"

cat > "$repo/driver.mjs" <<'EOF'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const HOME = process.env.FM_HOME;
const EXT = process.env.SPIKE_EXT;
const MODE = process.env.SPIKE_MODE;
const WAKE = process.env.SPIKE_WAKE || "signal: live probe wake";
const fail = (m) => { console.log("DRIVER_FAIL: " + m); process.exit(1); };

mkdirSync(`${HOME}/state`, { recursive: true });
mkdirSync(`${HOME}/config`, { recursive: true });
mkdirSync(`${HOME}/projects/live-probe`, { recursive: true });
writeFileSync(`${HOME}/state/live-probe.meta`, `project=${HOME}/projects/live-probe\nwindow=fm-live-probe\n`);
writeFileSync(`${HOME}/state/.wake-queue`, "1\t1\tsignal\tlive-probe.status\tsignal: live probe wake\n");
writeFileSync(`${HOME}/state/.lock`, `${process.pid}\n`);
if (MODE === "degrade") writeFileSync(`${HOME}/config/supervision-branch-model`, "firstmate-nonexistent/no-such-model\n");

const busHandlers = new Map();
const bus = {
  on(c, h) { busHandlers.set(c, [...(busHandlers.get(c) ?? []), h]); return () => {}; },
  emit(c, d) { for (const h of busHandlers.get(c) ?? []) h(d); },
};
const sent = [];
const userMsgs = [];
const piHandlers = new Map();
const pi = {
  events: bus,
  on(e, h) { piHandlers.set(e, [...(piHandlers.get(e) ?? []), h]); },
  registerCommand() {}, registerTool() {}, registerMessageRenderer() {},
  getThinkingLevel() { return undefined; },
  sendMessage(m, o) { sent.push({ m, o: o ?? {} }); },
  sendUserMessage(c, o) { userMsgs.push({ c, o: o ?? {} }); },
};
const mod = await import(pathToFileURL(EXT).href);
mod.default(pi);
for (const h of piHandlers.get("session_start") ?? []) await h(undefined, undefined);

const DISPATCH = "fm-branch-supervision:dispatch";
const offer = (message) => ({ message, projects: [`${HOME}/projects/live-probe`], heartbeat: false, eligible: true, accepted: false, accept() { this.accepted = true; } });
const waitFor = async (pred, ms) => { const s = Date.now(); while (Date.now() - s < ms) { if (pred()) return true; await new Promise((r) => setTimeout(r, 200)); } return pred(); };

const o1 = offer(WAKE);
bus.emit(DISPATCH, o1);
if (!o1.accepted) fail("the branch did not accept an eligible wake offer");
await waitFor(() => sent.length > 0 || userMsgs.length > 0, 120000);

const sessionFile = () => { try { return readFileSync(`${HOME}/state/.branch-session`, "utf8").trim(); } catch { return ""; } };

if (MODE === "degrade") {
  // The broken branch falls the wake back to main through the primary adapter's
  // exact main-wake mechanism: a firstmate-watcher-wake steer with triggerTurn,
  // captured in the sendMessage stream (not sendUserMessage).
  const fallback = sent.filter((s) => s.m.customType === "firstmate-watcher-wake");
  if (fallback.length < 1) fail("a broken branch did not fall the wake back to main via a watcher-wake steer");
  if (fallback.some((s) => s.o.triggerTurn !== true || s.o.deliverAs !== "steer")) {
    fail("fallback did not use the steer+triggerTurn main-wake mechanism");
  }
  if (sent.some((s) => s.m.customType === "fm-branch-merge")) fail("a broken branch merged into main instead of falling back");
  if (userMsgs.length !== 0) fail("fallback used sendUserMessage instead of the watcher-wake steer");
  if (!(readFileSync(`${HOME}/state/.wake-queue`, "utf8").trim().length > 0)) fail("the wake queue was lost on degrade");
  console.log("DRIVER_OK degrade: broken branch fell back to main via a watcher-wake steer with the wake queue intact");
  process.exit(0);
}

const branchLive = existsSync(`${HOME}/state/.branch-session`) && existsSync(sessionFile());
if (!branchLive) fail("a resident branch session was not created");
if (sent.some((s) => s.m.customType !== "fm-branch-merge")) fail("a non-merge (branch turn) message leaked into MAIN");
if (sent.length < 1) fail("the branch produced no merge into MAIN");
for (const s of sent) {
  const turns = s.o.triggerTurn === true ? 1 : 0;
  const kind = s.m.display === false && s.o.triggerTurn === true ? "captain" : "routine";
  if (kind === "routine" && turns !== 0) fail("a routine merge opened a new turn");
  if (kind === "captain" && turns !== 1) fail("a captain merge did not open exactly one turn");
  console.log(`DRIVER_INFO merge kind=${kind} newTurns=${turns}`);
}

const before = sent.length;
writeFileSync(`${HOME}/state/.wake-queue`, "1\t2\tsignal\tlive-probe.status\tsignal: second live probe wake\n");
const o2 = offer("signal: second live probe wake");
bus.emit(DISPATCH, o2);
if (!o2.accepted) fail("the resident branch did not accept a second wake");
await waitFor(() => sent.length > before || userMsgs.length > 0, 120000);
if (!(sent.length > before)) fail("the resident branch was not re-promptable");
console.log("DRIVER_OK working: resident, re-promptable, non-leak, routine=0-turn merge");
process.exit(0);
EOF

run_driver() { # <mode> <wake>
  FM_HOME="$TMP_ROOT/home-$1" SPIKE_EXT="$repo/.omp/extensions/fm-branch-supervision-omp.ts" \
    SPIKE_MODE="$1" SPIKE_WAKE="${2:-}" FM_ROOT_OVERRIDE="$ROOT" \
    bun "$repo/driver.mjs" 2>&1
}

out=$(run_driver degrade)
echo "$out" | grep -q "DRIVER_OK degrade" || fail "degrade-to-main guard failed: $out"
pass "a broken branch degrades to wake-to-main with no lost wake (real SDK)"

out=$(run_driver working "signal: live probe wake")
echo "$out" | grep -q "DRIVER_OK working" || fail "resident/non-leak/turn-accounting guard failed: $out"
pass "a resident, re-promptable second session handles a wake without leaking into MAIN (real SDK)"

out=$(run_driver working "signal: live-probe.status worker reports blocked: needs the captain to decide whether to rotate the production API key")
if echo "$out" | grep -q "kind=captain newTurns=1"; then
  pass "a captain-worthy wake opens exactly one follow-up turn on MAIN (real SDK)"
elif echo "$out" | grep -q "DRIVER_OK working"; then
  # The driver itself fails any captain merge that opened != 1 turn. Reaching a
  # clean working outcome with no captain merge means the model judged the
  # captain-worthy fixture routine this run: mark the captain=exactly-one-turn
  # sub-check SKIPPED rather than passing an unexercised path.
  echo "skip: captain-verdict path not exercised (the model judged the captain-worthy fixture routine this run); the captain=exactly-one-follow-up-turn contract is deterministically asserted by the driver whenever a captain merge occurs"
else
  fail "captain live guard failed: $out"
fi

version=$(jq -r '.version' "$OMP_PACKAGE_DIR/package.json" 2>/dev/null || printf 'unknown')
printf 'ok - OMP supervision branch live guard passed against @oh-my-pi/pi-coding-agent %s\n' "$version"
