#!/usr/bin/env bash
# OMP primary identity and native extension behavior tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-primary)
trap 'rm -rf "$TMP_ROOT"' EXIT
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_process_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
self_dir=$(cd "$(dirname "$0")" && pwd)
expected_bun=${FM_TEST_EXPECTED_BUN:-$self_dir/bun}
expected_omp=${FM_TEST_EXPECTED_OMP:-$self_dir/omp}
if [ -n "${FM_TEST_OWNER_PID:-}" ] && [ "$pid" = "$FM_TEST_OWNER_PID" ]; then
  case "$field" in
    comm=) printf '%s\n' bun ;;
    args=) printf '%s %s\n' "$expected_bun" "$expected_omp --model openai-codex/gpt-5.6-luna" ;;
    ppid=) printf '%s\n' 1 ;;
  esac
  exit 0
fi
omp_pid=${FM_TEST_OMP_PID:-2147483647}
if [ "$pid" = "$omp_pid" ]; then
  case "$field" in
    comm=) printf '%s\n' "${FM_TEST_OMP_COMM:-bun}" ;;
    args=)
      case "${FM_TEST_OMP_SHAPE:-exact}" in
        exact) printf '%s %s\n' "$expected_bun" "$expected_omp --model openai-codex/gpt-5.6-luna" ;;
        helper) printf '%s %s\n' "$expected_bun" "$self_dir/omp-helper --model test" ;;
        prefixed) printf '%s %s\n' "$expected_bun" "$self_dir/xomp --model test" ;;
        incidental) printf '%s %s\n' "$expected_bun" "$self_dir/tool.js --label omp" ;;
      esac
      ;;
    ppid=) printf '%s\n' 1 ;;
  esac
  exit 0
fi
case "$pid:$field" in
  500:comm=) printf '%s\n' "${FM_TEST_NESTED_COMM:-claude}" ;;
  500:args=) printf '%s\n' "${FM_TEST_NESTED_COMM:-claude} --resume" ;;
  500:ppid=) printf '%s\n' 2147483647 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash -c firstmate-tool' ;;
  *:ppid=) printf '%s\n' "${FM_TEST_HARNESS_PARENT:-2147483647}" ;;
esac
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
self_dir=$(cd "$(dirname "$0")" && pwd)
printf 'n%s\n' "${FM_TEST_EXPECTED_BUN:-$self_dir/bun}"
SH
  chmod +x "$fakebin/lsof"
  for name in bun omp omp-helper xomp tool.js; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$name"
    chmod +x "$fakebin/$name"
  done
  printf '%s\n' "$fakebin"
}

test_resolve_path_uses_node_when_readlink_f_is_unavailable() {
  local fixture fakebin expected resolved
  fixture="$TMP_ROOT/resolve-path"
  fakebin=$(fm_fakebin "$fixture")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/target"
  chmod +x "$fixture/target"
  ln -s "$fixture/target" "$fixture/link"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/readlink"
  chmod +x "$fakebin/readlink"
  expected=$(fm_test_realpath "$fixture/link")
  resolved=$(PATH="$fakebin:$(dirname "$(command -v node)"):$BASE_PATH" \
    bash -c '. "$0/bin/fm-omp-process-lib.sh"; fm_omp_process_resolve_path "$1"' \
      "$ROOT" "$fixture/link") || fail "Node realpath fallback did not resolve a symlink"
  [ "$resolved" = "$expected" ] \
    || fail "Node realpath fallback returned '$resolved', expected '$expected'"
  pass "OMP path resolution stays canonical when readlink -f is unavailable"
}

test_exact_bun_omp_primary_identity() {
  local fakebin got shape
  fakebin=$(make_process_fakebin "$TMP_ROOT/process")
  export FM_OMP_PROCESS_EXPECTED_BUN="$fakebin/bun"
  export FM_OMP_PROCESS_EXPECTED_BIN="$fakebin/omp"

  got=$(PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid' "$ROOT")
  [ "$got" = 2147483647 ] || fail "exact bun-launched OMP ancestry resolved '$got', expected 2147483647"
  PATH="$fakebin:$BASE_PATH" bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 2147483647' "$ROOT" \
    || fail "exact bun-launched OMP lock owner was rejected"

  got=$(PATH="$fakebin:$BASE_PATH" PI_CODING_AGENT=true CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$got" = omp ] || fail "exact OMP ancestry did not outrank inherited foreign markers: $got"

  got=$(PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_COMM=omp bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid' "$ROOT")
  [ "$got" = 2147483647 ] || fail "OMP process-title comm with exact Bun argv resolved '$got', expected 2147483647"
  PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_COMM=omp bash -c \
    '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 2147483647' "$ROOT" \
    || fail "OMP process-title comm with exact Bun argv was rejected"

  for shape in helper prefixed incidental; do
    if PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_SHAPE="$shape" bash -c \
      '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 2147483647' "$ROOT"; then
      fail "inexact bun OMP shape was accepted: $shape"
    fi
    got=$(PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_SHAPE="$shape" \
      PI_CODING_AGENT=true CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
    [ "$got" != omp ] || fail "inexact OMP ancestry was classified as OMP: $shape"
    if PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_COMM=omp FM_TEST_OMP_SHAPE="$shape" bash -c \
      '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 2147483647' "$ROOT"; then
      fail "OMP process-title comm bypassed the Bun argv boundary: $shape"
    fi
  done
  unset FM_OMP_PROCESS_EXPECTED_BUN FM_OMP_PROCESS_EXPECTED_BIN
  pass "OMP primary identity requires launch-bound Bun and OMP realpaths plus the exact argv boundary"
}

test_standalone_omp_primary_identity() {
  local fakebin got
  fakebin=$(make_process_fakebin "$TMP_ROOT/standalone-process")
  export FM_OMP_PROCESS_EXPECTED_BUN="$fakebin/omp"
  export FM_OMP_PROCESS_EXPECTED_BIN="$fakebin/omp"

  got=$(PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_COMM=omp FM_TEST_EXPECTED_BUN="$fakebin/omp" \
    bash -c '. "$0/bin/fm-session-lock-lib.sh"; fm_harness_ancestry_pid' "$ROOT")
  [ "$got" = 2147483647 ] || fail "standalone OMP ancestry resolved '$got', expected 2147483647"
  PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_COMM=omp FM_TEST_EXPECTED_BUN="$fakebin/omp" \
    bash -c '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 2147483647' "$ROOT" \
    || fail "standalone OMP lock owner was rejected"

  if PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_COMM=omp FM_TEST_EXPECTED_BUN="$fakebin/xomp" \
    bash -c '. "$0/bin/fm-session-lock-lib.sh"; kill() { return 0; }; fm_harness_pid_alive 2147483647' "$ROOT"; then
    fail "standalone OMP accepted a PID running a different executable"
  fi
  if PATH="$fakebin:$BASE_PATH" FM_TEST_OMP_COMM=omp FM_TEST_EXPECTED_BUN="$fakebin/omp" \
    bash -c '. "$0/bin/fm-omp-process-lib.sh"; fm_omp_process_matches omp "omp --model test"' "$ROOT"; then
    fail "standalone OMP identity was accepted without a PID"
  fi

  unset FM_OMP_PROCESS_EXPECTED_BUN FM_OMP_PROCESS_EXPECTED_BIN
  pass "standalone OMP identity requires the launch-bound PID executable"
}

test_nested_foreign_harness_keeps_its_own_identity() {
  local fakebin got
  fakebin=$(make_process_fakebin "$TMP_ROOT/nested")
  export FM_OMP_PROCESS_EXPECTED_BUN="$fakebin/bun"
  export FM_OMP_PROCESS_EXPECTED_BIN="$fakebin/omp"

  got=$(PATH="$fakebin:$BASE_PATH" FM_TEST_HARNESS_PARENT=500 \
    env -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$got" = claude ] \
    || fail "claude nested inside an OMP tree resolved '$got', expected claude"

  got=$(PATH="$fakebin:$BASE_PATH" FM_TEST_HARNESS_PARENT=500 FM_TEST_NESTED_COMM=codex \
    env -u PI_CODING_AGENT -u CLAUDECODE -u GROK_AGENT "$ROOT/bin/fm-harness.sh")
  [ "$got" = codex ] \
    || fail "markerless codex nested inside an OMP tree resolved '$got', expected codex"

  got=$(PATH="$fakebin:$BASE_PATH" \
    env -u PI_CODING_AGENT -u CLAUDECODE -u GROK_AGENT "$ROOT/bin/fm-harness.sh")
  [ "$got" = omp ] || fail "direct OMP ancestry resolved '$got', expected omp"

  unset FM_OMP_PROCESS_EXPECTED_BUN FM_OMP_PROCESS_EXPECTED_BIN
  got=$(PATH="$fakebin:$BASE_PATH" FM_STATE_OVERRIDE="$TMP_ROOT/nested/no-state" \
    env -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$got" = claude ] \
    || fail "absent OMP identity evidence resolved '$got', expected claude"
  pass "exact-OMP ancestry stops at the innermost foreign harness ancestor"
}

test_primary_scope_requires_canonical_state() {
  local fixture external out
  fixture="$TMP_ROOT/fresh-primary-scope"
  external="$TMP_ROOT/external-state"
  mkdir -p "$fixture/bin" "$external"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  if FM_TEST_ROOT="$fixture" FM_TEST_STATE="$fixture/state" bash -c \
    '. "$0/bin/fm-primary-scope-lib.sh"; fm_primary_scope_matches "$FM_TEST_ROOT" "$FM_TEST_STATE"' "$ROOT"; then
    fail "generic primary scope admitted a checkout with absent canonical state"
  fi
  [ ! -e "$fixture/state" ] || fail "primary scope predicate created state instead of leaving creation to the extension core"
  if FM_TEST_ROOT="$fixture" FM_TEST_STATE="$external/missing" bash -c \
    '. "$0/bin/fm-primary-scope-lib.sh"; fm_primary_scope_matches "$FM_TEST_ROOT" "$FM_TEST_STATE"' "$ROOT"; then
    fail "primary scope accepted an absent state override outside the checkout"
  fi
  ln -s "$external" "$fixture/state"
  if FM_TEST_ROOT="$fixture" FM_TEST_STATE="$fixture/state" bash -c \
    '. "$0/bin/fm-primary-scope-lib.sh"; fm_primary_scope_matches "$FM_TEST_ROOT" "$FM_TEST_STATE"' "$ROOT"; then
    fail "primary scope accepted a symlinked canonical state path"
  fi
  rm "$fixture/state"
  mkdir -p "$fixture/.omp/extensions" "$fixture/state"
  printf 'marker-target-must-stay-unchanged\n' > "$external/marker-target"
  ln -s "$external/marker-target" "$fixture/state/.omp-primary-extension-loaded"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  mkdir -p "$fixture/.omp/extensions/lib"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$fixture/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fixture/bin/fm-gate-refuse-lib.sh"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_HOME="$fixture" \
    FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" node --input-type=module 2>&1 <<'JS'
import { lstatSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
process.argv[1] = process.execPath;
let registrations = 0;
const api = {
  zod: { object: () => ({}) },
  on() { registrations += 1; },
  registerCommand() { registrations += 1; },
  registerTool() { registrations += 1; },
  sendUserMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?fresh=${Date.now()}`);
extension.default(api);
const marker = `${process.env.FM_STATE_OVERRIDE}/.omp-primary-extension-loaded`;
const lines = readFileSync(marker, "utf8").trim().split("\n");
if (registrations < 8) throw new Error(`fresh extension registered only ${registrations} lifecycle surfaces`);
if (lines.length !== 4 || lines[1] !== String(process.pid)) throw new Error(`fresh marker shape ${lines.join("|")}`);
if (!lstatSync(marker).isFile() || lstatSync(marker).isSymbolicLink()) throw new Error("primary marker remained a symlink");
if (readFileSync(`${process.env.FM_HOME}/../external-state/marker-target`, "utf8") !== "marker-target-must-stay-unchanged\n") {
  throw new Error("primary marker publication overwrote the symlink target");
}

console.log("fresh-lifecycle-ok");
JS
  ) || fail "fresh plain-checkout OMP primary lifecycle did not initialize: $out"
  assert_contains "$out" fresh-lifecycle-ok "fresh OMP lifecycle did not publish its four-line identity marker"
  pass "OMP fresh primary lifecycle creates canonical state and atomically replaces a marker symlink without following it"
}

test_native_omp_fresh_checkout_nudges_once() {
  local fixture out status=0
  fixture="$TMP_ROOT/native-fresh"
  mkdir -p "$fixture/.omp/extensions" "$fixture/bin" "$fixture/config"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  mkdir -p "$fixture/.omp/extensions/lib"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$fixture/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fixture/bin/fm-gate-refuse-lib.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$fixture/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$fixture/bin/fm-sessionstart-nudge.sh"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  chmod +x "$fixture/bin/"*.sh

  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const api = {
  zod: { object: () => ({}) },
  on(name, handler) { handlers.set(name, handler); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage() {},
};
process.argv[1] = process.env.EXTENSION;
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?fresh-native=${Date.now()}`);
extension.default(api);
const context = { sessionManager: { getSessionFile: () => "" } };
await handlers.get("session_start")({ type: "session_start" }, context);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start" }, {});
const second = await handlers.get("before_agent_start")({ type: "before_agent_start" }, {});
if (first?.message?.customType !== "firstmate-sessionstart-nudge" || !first.message.content.includes("fm-session-start.sh")) {
  throw new Error(`fresh native OMP did not receive its startup instruction: ${JSON.stringify(first)}`);
}
if (second !== undefined) throw new Error("fresh native OMP repeated its startup instruction");
console.log("fresh-native-nudge-once");
JS
  ) || status=$?
  expect_code 0 "$status" "fresh native OMP startup"
  assert_contains "$out" fresh-native-nudge-once "fresh native OMP did not deliver exactly one startup instruction"
  pass "native OMP alone admits a fresh plain checkout and delivers one startup instruction"
}

test_native_identity_handles_virtual_entrypoint() {
  local out status=0
  out=$(CORE="$ROOT/bin/fm-primary-watch-core.ts" node --input-type=module 2>&1 <<'JS'
import { realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { ompNativeProcessIdentity } = await import(`${pathToFileURL(process.env.CORE).href}?identity=${Date.now()}`);
const original = process.argv[1];
try {
  process.argv[1] = process.env.CORE;
  const legacy = ompNativeProcessIdentity();
  if (legacy.bunPath !== realpathSync(process.execPath) || legacy.ompPath !== realpathSync(process.env.CORE)) {
    throw new Error(`physical OMP identity changed: ${JSON.stringify(legacy)}`);
  }
  process.argv[1] = "/$bunfs/root/packages/coding-agent/src/cli.js";
  const standalone = ompNativeProcessIdentity();
  if (standalone.bunPath !== realpathSync(process.execPath) || standalone.ompPath !== standalone.bunPath) {
    throw new Error(`standalone OMP identity was not executable-bound: ${JSON.stringify(standalone)}`);
  }
  process.argv[1] = "/firstmate-missing-legacy-omp-entrypoint";
  let missingRejected = false;
  try {
    ompNativeProcessIdentity();
  } catch {
    missingRejected = true;
  }
  if (!missingRejected) {
    throw new Error("missing physical OMP entrypoint was downgraded to standalone identity");
  }
  console.log("native-identity-shapes-ok");
} finally {
  process.argv[1] = original;
}
JS
  ) || status=$?
  expect_code 0 "$status" "OMP native process identity shapes"
  assert_contains "$out" native-identity-shapes-ok "OMP identity did not support both physical and virtual entrypoints"
  pass "OMP native identity supports physical Bun scripts and known compiled virtual entrypoints"
}

test_primary_marker_refuses_whitespace_identity() {
  local fixture entry out
  fixture="$TMP_ROOT/whitespace-primary"
  entry="$fixture/omp entry.ts"
  mkdir -p "$fixture/.omp/extensions" "$fixture/bin" "$fixture/state"
  cp "$ROOT/AGENTS.md" "$fixture/AGENTS.md"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  mkdir -p "$fixture/.omp/extensions/lib"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$fixture/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fixture/bin/fm-gate-refuse-lib.sh"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  : > "$entry"
  git init -q -b main "$fixture"
  set +e
  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" OMP_ENTRY="$entry" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
    node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
process.argv[1] = process.env.OMP_ENTRY;
const api = {
  zod: { object: () => ({}) },
  on() {},
  registerCommand() {},
  registerTool() {},
  sendUserMessage() {},
};
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?space=${Date.now()}`);
extension.default(api);
JS
  )
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "OMP primary marker accepted a whitespace-bearing entrypoint"
  assert_contains "$out" 'OMP primary identity paths containing whitespace are unsupported' \
    "OMP primary whitespace refusal was not actionable"
  [ ! -e "$fixture/state/.omp-primary-extension-loaded" ] \
    || fail "OMP primary published a marker for a whitespace-bearing identity"
  pass "OMP primary refuses whitespace-bearing identity before marker publication"
}

test_native_primary_extension_contract() {
  local fixture inert out status
  fixture="$TMP_ROOT/extension"
  mkdir -p "$fixture/.omp/extensions" "$fixture/bin" "$fixture/home/state/secondmate.inbox" "$fixture/home/config"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  mkdir -p "$fixture/.omp/extensions/lib"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  chmod +x "$fixture/.omp/extensions/fm-primary-omp.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  cat > "$fixture/bin/fm-gate-refuse-lib.sh" <<'SH'
fm_is_gate_agent() { [ "${FM_TEST_GATE_AGENT:-0}" = 1 ]; }
SH
  cat > "$fixture/bin/fm-primary-scope-lib.sh" <<'SH'
fm_primary_scope_matches() { [ "${FM_TEST_PRIMARY_SCOPE:-1}" = 1 ]; }
SH
  cat > "$fixture/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
kind=$2
content=$(cat)
printf 'encoded:%s:%s' "$kind" "$content"
SH
  cat > "$fixture/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
[ -e "${FM_STATE_OVERRIDE:?}/.lock" ] || printf 'OMP_PRIMARY_STARTUP_NUDGE\n'
SH
  cat > "$fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
state=${FM_STATE_OVERRIDE:?}
count=$(cat "$state/watch-count" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$state/watch-count"
[ ! -e "$state/watch-trigger-consumed" ] || : > "$state/watch-successor-ready"
while [ ! -e "$state/watch-ready" ]; do sleep 0.02; done
printf 'watcher: started pid=%s\n' "$$"
trap 'exit 0' TERM INT
if [ ! -e "$state/watch-trigger-consumed" ]; then
  while [ ! -e "$state/watch-trigger" ]; do sleep 0.02; done
  mv "$state/watch-trigger" "$state/watch-trigger-consumed"
  printf 'signal: omp-actionable\n'
  exit 0
fi
while :; do sleep 1; done
SH
  cat > "$fixture/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> "${FM_TEST_GUARD_PAYLOADS:?}"
printf 'guard says supervision is absent\n' >&2
exit 2
SH
  cat > "$fixture/bin/fm-subagent-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
[ "${2:-}" != task ] || { printf 'delegation denied\n' >&2; exit 2; }
exit 0
SH
  cat > "$fixture/bin/fm-cd-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in *'cd projects/'*) printf 'directory denied\n' >&2; exit 2 ;; esac
exit 0
SH
  cat > "$fixture/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in *fm-watch-arm.sh*) printf 'watcher arm denied\n' >&2; exit 2 ;; esac
exit 0
SH
  chmod +x "$fixture/bin/"*.sh

  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FIXTURE="$fixture" \
    FM_HOME="$fixture/home" FM_ROOT_OVERRIDE="$fixture" \
    FM_STATE_OVERRIDE="$fixture/home/state" FM_CONFIG_OVERRIDE="$fixture/home/config" \
    FM_TEST_GUARD_PAYLOADS="$fixture/guard-payloads" FM_OMP_ARM_READY_TIMEOUT_MS=500 \
    FM_OMP_SESSION_POINTER="$fixture/home/state/.omp-session" \
    FM_OMP_TASK_INBOX_DIR="$fixture/home/state/secondmate.inbox" \
    FM_OMP_TASK_DOORBELL_READY="$fixture/home/state/secondmate.omp-doorbell-ready" \
    node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const commands = new Map();
const tools = new Map();
const customMessages = [];
const watcherMessages = [];
const api = {
  zod: { object: () => ({}) },
  on(name, handler) { handlers.set(name, handler); },
  registerCommand(name, value) { commands.set(name, value); },
  registerTool(value) { tools.set(value.name, value); },
  sendMessage(message, options) { watcherMessages.push({ message, options }); },
  sendUserMessage(content, options) { customMessages.push({ content, options }); },
};
process.argv[1] = process.env.EXTENSION;
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?test=${Date.now()}`);
await extension.default(api);
for (const required of ["session_start", "session_switch", "before_agent_start", "session_stop", "tool_call", "session_shutdown"]) {
  if (!handlers.has(required)) throw new Error(`missing OMP native handler ${required}`);
}
if (!commands.has("fm-watch-arm-omp") || !tools.has("fm_watch_arm_omp")) {
  throw new Error("OMP watcher arm command/tool was not registered");
}

const marker = `${process.env.FM_STATE_OVERRIDE}/.omp-primary-extension-loaded`;
let markerLines = readFileSync(marker, "utf8").trim().split("\n");
if (markerLines.length !== 4 || markerLines[1] !== String(process.pid)) {
  throw new Error(`invalid OMP primary marker ${markerLines.join("|")}`);
}
const extensionContext = { sessionManager: { getSessionFile: () => `${process.env.FIXTURE}/omp-session.jsonl` } };
if (existsSync(process.env.FM_OMP_TASK_DOORBELL_READY)) {
  throw new Error("OMP primary doorbell published readiness before session initialization");
}
await handlers.get("session_start")({ type: "session_start" }, extensionContext);
if (readFileSync(process.env.FM_OMP_SESSION_POINTER, "utf8").trim() !== `${process.env.FIXTURE}/omp-session.jsonl`) {
  throw new Error("OMP primary integration did not publish the exact secondmate session pointer");
}
if (readFileSync(process.env.FM_OMP_TASK_DOORBELL_READY, "utf8") !== `${process.pid}\n`) {
  throw new Error("OMP primary integration did not publish secondmate doorbell readiness at session start");
}
const primaryRequest = `${process.env.FM_OMP_TASK_DOORBELL_READY}.requests/primary.pending`;
writeFileSync(primaryRequest, `Firstmate instruction waiting: list ${process.env.FM_OMP_TASK_INBOX_DIR}/*.msg and, in numeric order, read and act on each, then mv each handled file to ${process.env.FM_OMP_TASK_INBOX_DIR}/handled/.`);
process.emit("SIGUSR2");
if (
  watcherMessages.length !== 1 ||
  watcherMessages[0].message.customType !== "firstmate-task-inbox-doorbell" ||
  watcherMessages[0].options?.deliverAs !== "steer" ||
  watcherMessages[0].options?.triggerTurn !== true ||
  !existsSync(`${primaryRequest}.delivered`)
) {
  throw new Error(`OMP primary secondmate doorbell was not acknowledged exactly once: ${JSON.stringify(watcherMessages)}`);
}
watcherMessages.length = 0;
const startup = await handlers.get("before_agent_start")({ type: "before_agent_start" }, {});
if (startup?.message?.customType !== "firstmate-sessionstart-nudge" || startup.message.content !== "OMP_PRIMARY_STARTUP_NUDGE" || startup.message.attribution !== "agent") {
  throw new Error(`startup nudge was not bound to the first provider turn: ${JSON.stringify(startup)}`);
}
if (await handlers.get("before_agent_start")({ type: "before_agent_start" }, {}) !== undefined) {
  throw new Error("startup nudge repeated within one OMP session");
}
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);
await handlers.get("session_switch")({ type: "session_switch", reason: "new" }, extensionContext);
const newStartup = await handlers.get("before_agent_start")({ type: "before_agent_start" }, {});
if (newStartup?.message?.customType !== "firstmate-sessionstart-nudge" || newStartup.message.attribution !== "agent") {
  throw new Error(`in-process OMP /new lost its once-only startup instruction: ${JSON.stringify(newStartup)}`);
}
if (await handlers.get("before_agent_start")({ type: "before_agent_start" }, {}) !== undefined) {
  throw new Error("in-process OMP /new repeated its startup instruction");
}
await handlers.get("session_switch")({ type: "session_switch", reason: "resume" }, extensionContext);
const resumeStartup = await handlers.get("before_agent_start")({ type: "before_agent_start" }, {});
if (resumeStartup?.message?.customType !== "firstmate-sessionstart-nudge" || resumeStartup.message.attribution !== "agent") {
  throw new Error(`in-process OMP /resume lost its once-only startup instruction: ${JSON.stringify(resumeStartup)}`);
}
if (await handlers.get("before_agent_start")({ type: "before_agent_start" }, {}) !== undefined) {
  throw new Error("in-process OMP /resume repeated its startup instruction");
}

const signal = new AbortController().signal;
const stop = await handlers.get("session_stop")({
  type: "session_stop",
  messages: [],
  turn_id: 1,
  session_id: "omp-session",
  stop_hook_active: false,
  signal,
});
if (stop?.continue !== true || !stop.additionalContext.includes("encoded:turn-end-guard:TURN WOULD END BLIND")) {
  throw new Error(`OMP session_stop did not request one guarded continuation: ${JSON.stringify(stop)}`);
}
const bounded = await handlers.get("session_stop")({
  type: "session_stop",
  messages: [],
  turn_id: 2,
  session_id: "omp-session",
  stop_hook_active: true,
  signal,
});
if (bounded !== undefined) throw new Error("OMP session_stop recursed after stop_hook_active");

const delegation = await handlers.get("tool_call")({ type: "tool_call", toolName: "task", input: {} });
if (delegation?.block !== true || !delegation.reason.includes("delegation denied")) {
  throw new Error("OMP delegation-shaped tool was not blocked");
}
const directory = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "cd projects/demo" } });
if (directory?.block !== true || !directory.reason.includes("directory denied")) {
  throw new Error("OMP persistent directory change was not blocked");
}
const foregroundArm = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh" } });
if (foregroundArm?.block !== true || !foregroundArm.reason.includes("watcher arm denied")) {
  throw new Error("OMP foreground watcher arm was not blocked");
}

let toolSettled = false;
const toolPromise = tools.get("fm_watch_arm_omp").execute().then((result) => {
  toolSettled = true;
  return result;
});
await new Promise(resolve => setTimeout(resolve, 80));
if (toolSettled) throw new Error("OMP watcher tool reported success before watcher readiness");
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/watch-ready`, "ready\n");
const toolResult = await toolPromise;
if (!toolResult.details.ok || !toolResult.content[0].text.includes("OMP extension")) {
  throw new Error(`OMP watcher tool did not route through the shared core: ${JSON.stringify(toolResult)}`);
}
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/watch-trigger`, "go\n");
for (let i = 0; i < 100 && watcherMessages.length === 0; i += 1) {
  await new Promise(resolve => setTimeout(resolve, 20));
}
if (watcherMessages.length !== 1 || !watcherMessages[0].message.content.includes("signal: omp-actionable")) {
  throw new Error(`OMP actionable watcher close was not delivered once: ${JSON.stringify(watcherMessages)}`);
}
if (
  watcherMessages[0].message.customType !== "firstmate-watcher-wake" ||
  watcherMessages[0].message.display !== false ||
  watcherMessages[0].options?.deliverAs !== "nextTurn" ||
  watcherMessages[0].options?.triggerTurn !== true
) {
  throw new Error(`OMP watcher notification was not a hidden next-turn continuation: ${JSON.stringify(watcherMessages[0])}`);
}
if (!existsSync(`${process.env.FM_STATE_OVERRIDE}/watch-successor-ready`)) {
  throw new Error("OMP actionable notification arrived before successor readiness");
}
await handlers.get("session_shutdown")({ type: "session_shutdown" }, {});
await new Promise(resolve => setTimeout(resolve, 80));
console.log(JSON.stringify({ startupMessages: 3, guarded: true, tools: tools.size, watcherMessages: watcherMessages.length, customMessages: customMessages.length }));
JS
)
  status=$?
  expect_code 0 "$status" "OMP native primary extension contract"
  assert_contains "$out" '"startupMessages":3' "OMP primary runtime result lost once-only startup delivery across start, new, and resume"
  assert_contains "$out" '"guarded":true' "OMP primary runtime result lost stop guard evidence"
  assert_contains "$out" '"watcherMessages":1' "OMP watcher wake was not delivered exactly once"

  local contended_fakebin contended
  contended_fakebin=$(make_process_fakebin "$TMP_ROOT/contended-process")
  cat > "$contended_fakebin/kill" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$contended_fakebin/kill"
  printf 'owner-marker\n' > "$fixture/home/state/.omp-primary-extension-loaded"
  contended=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" \
    FM_HOME="$fixture/home" FM_ROOT_OVERRIDE="$fixture" \
    FM_STATE_OVERRIDE="$fixture/home/state" FM_CONFIG_OVERRIDE="$fixture/home/config" \
    FM_TEST_PROJECT_ROOT="$ROOT" PATH="$contended_fakebin:$PATH" node --input-type=module 2>&1 <<'JS'
import { readFileSync, realpathSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const api = { zod: { object: () => ({}) }, on() {}, registerCommand() {}, registerTool() {} };
const expectedBun = realpathSync(process.execPath);
const expectedBin = realpathSync(process.env.EXTENSION);
const owner = spawn(process.execPath, ["-e", "setInterval(() => {}, 60000)"], { stdio: "ignore" });
if (!owner.pid) throw new Error("could not start a real lock-holder process");
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${owner.pid}\n`);
try {
  process.argv[1] = process.env.EXTENSION;
  const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?contended=${Date.now()}`);
  extension.default(api);
if (process.env.FM_OMP_PROCESS_EXPECTED_BUN !== expectedBun || process.env.FM_OMP_PROCESS_EXPECTED_BIN !== expectedBin) {
  throw new Error(`native OMP did not publish its process identity: ${process.env.FM_OMP_PROCESS_EXPECTED_BUN}|${process.env.FM_OMP_PROCESS_EXPECTED_BIN}`);
}
if (readFileSync(`${process.env.FM_STATE_OVERRIDE}/.omp-primary-extension-loaded`, "utf8") !== "owner-marker\n") {
  throw new Error("contended OMP replaced the live owner's canonical marker");
}
  const childEnv = {
  ...process.env,
  FM_ROOT_OVERRIDE: process.env.FM_TEST_PROJECT_ROOT,
  FM_TEST_OWNER_PID: String(owner.pid),
  FM_TEST_OMP_PID: "970000",
  FM_TEST_EXPECTED_BUN: expectedBun,
  FM_TEST_EXPECTED_OMP: expectedBin,
  CLAUDECODE: "1",
  PI_CODING_AGENT: "true",
  FM_TEST_HARNESS_PARENT: "970000",
};
  const direct = spawnSync(`${process.env.FM_TEST_PROJECT_ROOT}/bin/fm-harness.sh`, { env: childEnv, encoding: "utf8" });
if (direct.stdout.trim() !== "omp") throw new Error(`contended direct OMP resolved ${direct.stdout.trim()}`);
  const inner = spawnSync(`${process.env.FM_TEST_PROJECT_ROOT}/bin/fm-harness.sh`, {
  env: { ...childEnv, FM_TEST_HARNESS_PARENT: "500" }, encoding: "utf8",
});
if (inner.stdout.trim() !== "claude") throw new Error(`nearer Claude ancestor resolved ${inner.stdout.trim()}`);
  const lock = spawnSync(`${process.env.FM_TEST_PROJECT_ROOT}/bin/fm-lock.sh`, { env: childEnv, encoding: "utf8" });
  if (lock.status !== 1 || !lock.stderr.includes("another live firstmate session holds the lock")) {
    throw new Error(`contended OMP lock result ${lock.status}: ${lock.stderr}`);
  }
  if (readFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, "utf8") !== `${owner.pid}\n`) {
    throw new Error("contended OMP changed the live owner's lock");
  }
  console.log("contended-native-identity-ok");
} finally {
  owner.kill();
}
JS
  ) || status=$?
  expect_code 0 "$status" "contended native OMP identity"
  assert_contains "$contended" contended-native-identity-ok "contended OMP did not preserve exact identity, nearest harness precedence, and lock refusal"

  rm -f "$fixture/home/state/.omp-primary-extension-loaded"
  inert=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_TEST_PRIMARY_SCOPE=0 \
    FM_HOME="$fixture/home" FM_ROOT_OVERRIDE="$fixture" \
    FM_STATE_OVERRIDE="$fixture/home/state" FM_CONFIG_OVERRIDE="$fixture/home/config" \
    node --input-type=module 2>&1 <<'JS'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
let handlers = 0;
let tools = 0;
const api = {
  zod: { object: () => ({}) },
  on() { handlers += 1; },
  registerCommand() { tools += 1; },
  registerTool() { tools += 1; },
};
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?inert=${Date.now()}`);
extension.default(api);
if (handlers !== 0 || tools !== 0) throw new Error(`out-of-scope adapter registered handlers=${handlers} tools=${tools}`);
if (existsSync(`${process.env.FM_STATE_OVERRIDE}/.omp-primary-extension-loaded`)) {
  throw new Error("out-of-scope adapter published a primary loaded marker");
}
console.log("inert-scope-ok");
JS
)
  status=$?
  expect_code 0 "$status" "OMP native extension primary-scope guard"
  assert_contains "$inert" "inert-scope-ok" "OMP linked-task scope did not stay inert"

  inert=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_TEST_GATE_AGENT=1 \
    FM_HOME="$fixture/home" FM_ROOT_OVERRIDE="$fixture" \
    FM_STATE_OVERRIDE="$fixture/home/state" FM_CONFIG_OVERRIDE="$fixture/home/config" \
    node --input-type=module 2>&1 <<'JS'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";
let registrations = 0;
const api = {
  zod: { object: () => ({}) },
  on() { registrations += 1; },
  registerCommand() { registrations += 1; },
  registerTool() { registrations += 1; },
};
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?gate=${Date.now()}`);
extension.default(api);
if (registrations !== 0) throw new Error(`gate-agent adapter registered ${registrations} surfaces`);
if (existsSync(`${process.env.FM_STATE_OVERRIDE}/.omp-primary-extension-loaded`)) {
  throw new Error("gate-agent adapter published a primary loaded marker");
}
console.log("inert-gate-ok");
JS
)
  status=$?
  expect_code 0 "$status" "OMP native extension gate-agent guard"
  assert_contains "$inert" "inert-gate-ok" "OMP gate-agent scope did not stay inert"
  pass "OMP primary extension binds secondmate doorbells after session readiness"
}

# The shared core delivers the recovery handshake for every runtime bound to it,
# so OMP must confirm a handling delivery exactly like Pi and OpenCode do: start
# and verify the successor, run fm-watch-arm.sh --handling-delivered for the
# generation the successor reported, and only then schedule the hidden next-turn
# notification. Upstream covers Pi and OpenCode; this pins the fork's OMP binding
# of the same contract so a future adapter change cannot silently drop it.
test_native_omp_confirms_recovery_handling_delivery() {
  local fixture out status=0
  fixture="$TMP_ROOT/native-handling-delivery"
  mkdir -p "$fixture/.omp/extensions" "$fixture/bin" "$fixture/config" "$fixture/state"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  mkdir -p "$fixture/.omp/extensions/lib"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$fixture/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fixture/bin/fm-gate-refuse-lib.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$fixture/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$fixture/bin/fm-sessionstart-nudge.sh"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  cat > "$fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$fixture/bin/"*.sh

  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
    FM_ARM_LOG="$TMP_ROOT/native-handling-delivery.log" \
    FM_STOP_FILE="$TMP_ROOT/native-handling-delivery.stop" \
    node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armRows = () => (existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : []);

let tool = null;
let steers = 0;
let rowsAtDelivery = -1;
let deliveryOptions = null;
const api = {
  zod: { object: () => ({}) },
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendMessage(_message, options) {
    steers += 1;
    deliveryOptions = options;
    rowsAtDelivery = armRows().filter((row) => row.startsWith("arm=")).length;
  },
};
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?handling=${Date.now()}`);
extension.default(api);
if (!tool) throw new Error("OMP did not register its watcher arm tool");
await tool.execute();
for (let i = 0; i < 400 && !armRows().some((row) => row.startsWith("confirmed ")); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
const rows = armRows();
const arms = rows.filter((row) => row.startsWith("arm="));
if (arms.length !== 2) throw new Error(`expected one successor arm, got ${arms.length}: ${rows.join(" | ")}`);
if (steers !== 1) throw new Error(`expected exactly one wake notification, got ${steers}`);
if (deliveryOptions?.deliverAs !== "nextTurn" || deliveryOptions?.triggerTurn !== true) {
  throw new Error(`wake was not delivered as a turn-triggering next-turn continuation: ${JSON.stringify(deliveryOptions)}`);
}
if (rowsAtDelivery !== 2) throw new Error(`wake delivery began before successor establishment (${rowsAtDelivery} arm rows)`);
const confirmations = rows.filter((row) => row.startsWith("confirmed "));
if (confirmations.length !== 1) {
  throw new Error(`handling delivery was not confirmed exactly once: ${rows.join(" | ")}`);
}
if (!confirmations[0].includes("generation=fixture-generation")) {
  throw new Error(`handling delivery confirmed the wrong generation: ${confirmations[0]}`);
}
if (rows.indexOf(confirmations[0]) < rows.lastIndexOf(arms[1])) {
  throw new Error(`handling delivery was confirmed before its successor arm: ${rows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
console.log("omp-handling-delivery-ok");
JS
  ) || status=$?
  printf 'stop\n' > "$TMP_ROOT/native-handling-delivery.stop" 2>/dev/null || true
  expect_code 0 "$status" "OMP recovery handling delivery"
  assert_contains "$out" omp-handling-delivery-ok "OMP did not confirm recovery handling before its next-turn notification"
  pass "OMP confirms the recovery handling handshake before its hidden next-turn notification"
}

# A refused handling handshake must be classified and surfaced exactly once
# rather than swallowed, or OMP would deliver a wake whose recovery episode was
# never handed off. Upstream pins this for Pi; the shared core makes the same
# guarantee OMP's, so pin it here too.
test_native_omp_refused_handling_delivery_is_typed_once() {
  local fixture out status=0
  fixture="$TMP_ROOT/native-handling-refused"
  mkdir -p "$fixture/.omp/extensions" "$fixture/bin" "$fixture/config" "$fixture/state"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  mkdir -p "$fixture/.omp/extensions/lib"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$fixture/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fixture/bin/fm-gate-refuse-lib.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$fixture/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$fixture/bin/fm-sessionstart-nudge.sh"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  cat > "$fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'refused generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  echo "watcher: invalid handling delivery confirmation" >&2
  exit 1
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$fixture/bin/"*.sh

  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
    FM_ARM_LOG="$TMP_ROOT/native-handling-refused.log" \
    FM_STOP_FILE="$TMP_ROOT/native-handling-refused.stop" \
    node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const armRows = () => (existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : []);

let tool = null;
let steer = "";
let steers = 0;
const api = {
  zod: { object: () => ({}) },
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendMessage(message) {
    steers += 1;
    steer += String(message?.content ?? "");
  },
};
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?refused=${Date.now()}`);
extension.default(api);
if (!tool) throw new Error("OMP did not register its watcher arm tool");
await tool.execute();
for (let i = 0; i < 400 && !steer.includes("handling delivery confirmation was rejected"); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
if (!steer.includes("FIRSTMATE WATCHER WAKE")) throw new Error(`missing follow-up: ${steer}`);
if (!steer.includes("handling delivery confirmation was rejected")) {
  throw new Error(`refused handshake was swallowed: ${steer}`);
}
if (steers !== 1) throw new Error(`refused handshake was not a single typed notification, got ${steers}`);
const refusals = armRows().filter((row) => row.startsWith("refused "));
if (refusals.length < 1) throw new Error(`handling-delivered was never attempted: ${armRows().join(" | ")}`);
console.log("omp-refused-handshake-ok");
JS
  ) || status=$?
  printf 'stop\n' > "$TMP_ROOT/native-handling-refused.stop" 2>/dev/null || true
  expect_code 0 "$status" "OMP refused handling delivery"
  assert_contains "$out" omp-refused-handshake-ok "OMP swallowed a refused handling handshake"
  pass "OMP surfaces a refused handling handshake as one hidden notification"
}

# OMP's hidden next-turn queue retains custom messages while a prompt unwinds.
# This fixture drives successive durable wake batches through the native primary
# adapter and verifies the core contributes one continuation until OMP begins
# that next turn.
# It proves a same-session reload retains that continuation and a replacement
# primary re-notifies the exact unacknowledged batch without retiring its rows.
test_native_omp_coalesces_pending_next_turn_notifications() {
  local fixture out status=0
  fixture="$TMP_ROOT/native-next-turn-batching"
  mkdir -p "$fixture/.omp/extensions" "$fixture/bin" "$fixture/config" "$fixture/state"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  mkdir -p "$fixture/.omp/extensions/lib"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$fixture/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fixture/bin/fm-gate-refuse-lib.sh"
  cp "$ROOT/bin/fm-operational-input.sh" "$fixture/bin/fm-operational-input.sh"
  cp "$ROOT/bin/fm-sessionstart-nudge.sh" "$fixture/bin/fm-sessionstart-nudge.sh"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  cat > "$fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_STATE_OVERRIDE:?}
if [ "${1:-}" = --handling-delivered ]; then
  printf 'handling generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  if [ -e "$state/reject-confirmation" ]; then
    echo "watcher: recovery generation mismatch" >&2
    exit 1
  fi
  exit 0
fi
count=$(cat "$state/arm-count" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$state/arm-count"
printf 'arm=%s count=%s\n' "$$" "$count" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$state/watch-trigger-$count" ]; do sleep 0.01; done
rm -f "$state/watch-trigger-$count"
printf 'signal: synthetic durable batch %s\n' "$count"
SH
  cat > "$fixture/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fixture/bin/"*.sh

  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" \
    FM_ARM_LOG="$TMP_ROOT/native-next-turn-batching.log" \
    FM_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh" \
    FM_WAKE_DRAIN="$ROOT/bin/fm-wake-drain.sh" \
    FM_OMP_TASK_INBOX_DIR="" FM_OMP_TASK_DOORBELL_READY="" \
    node --input-type=module 2>&1 <<'JS'
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const eventHandlers = new Map();
const notifications = [];
let tool = null;
let sendAttempts = 0;
let failNextNotification = false;
const state = process.env.FM_STATE_OVERRIDE;
const armRows = () => (existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : []);
const armCount = () => armRows().filter((row) => row.startsWith("arm=")).length;
const waitFor = async (predicate, description) => {
  for (let attempt = 0; attempt < 400; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${description}`);
};
const api = {
  zod: { object: () => ({}) },
  on(name, handler) { handlers.set(name, handler); },
  events: {
    on(name, handler) { eventHandlers.set(name, handler); },
    emit(name, data) { eventHandlers.get(name)?.(data); },
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_omp") tool = candidate;
  },
  sendMessage(message, options) {
    sendAttempts += 1;
    if (failNextNotification) {
      failNextNotification = false;
      throw new Error("synthetic next-turn submission failure");
    }
    notifications.push({ message, options });
  },
};
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?batching=${Date.now()}`);
extension.default(api);
if (!tool) throw new Error("OMP did not register its watcher arm tool");
const dispatch = await import(new URL("./lib/fm-branch-dispatch.ts", pathToFileURL(process.env.EXTENSION)).href);

const queue = `${state}/.wake-queue`;
const queueRows = [
  "1\t1\tsignal\tworker.status\tsignal: worker first",
  "2\t2\tsignal\tworker.status\tsignal: worker latest",
  "3\t3\tstale\tworker\tstale: worker",
].join("\n") + "\n";
writeFileSync(queue, queueRows);
const deduped = spawnSync(
  "bash",
  ["-c", '. "$1"; fm_wake_print_deduped "$2"', "bash", process.env.FM_WAKE_LIB, queue],
  { encoding: "utf8", env: { ...process.env, FM_STATE_OVERRIDE: state } },
);
if (deduped.status !== 0 || deduped.stdout.trim().split("\n").length !== 2) {
  throw new Error(`durable batch was not deduplicated: ${deduped.stderr || deduped.stdout}`);
}

const firstSession = `${state}/first-session.jsonl`;
const replacementSession = `${state}/replacement-session.jsonl`;
const startSession = async (sessionFile) => {
  await handlers.get("session_start")(
    { type: "session_start" },
    { sessionManager: { getSessionFile: () => sessionFile } },
  );
};
const startNextTurn = async () => {
  const notification = notifications.at(-1);
  if (notification) {
    await handlers.get("message_start")(
      { type: "message_start", message: { ...notification.message, role: "custom" } },
      {},
    );
  }
  await handlers.get("before_agent_start")({ type: "before_agent_start" }, {});
};
const trigger = async (count, messageCount) => {
  writeFileSync(`${state}/watch-trigger-${count}`, "go\n");
  await waitFor(() => armCount() >= count + 1, `successor ${count + 1}`);
  if (messageCount !== undefined) {
    await waitFor(() => notifications.length >= messageCount, `notification ${messageCount}`);
  }
};
const triggerCurrent = async (messageCount) => trigger(armCount(), messageCount);
const reloadExtension = async (label, sessionFile, arm = true) => {
  const reloaded = await import(`${pathToFileURL(process.env.EXTENSION).href}?${label}=${Date.now()}`);
  reloaded.default(api);
  if (!tool) throw new Error(`OMP did not register its watcher arm tool after ${label}`);
  await startSession(sessionFile);
  if (arm) await tool.execute();
};


try {
  await startSession(firstSession);
  await tool.execute();
  await waitFor(() => armCount() === 1, "initial watcher");
  await trigger(1, 1);
  if (readFileSync(queue, "utf8") !== queueRows) {
    throw new Error("hidden notification acknowledged durable wake rows");
  }
  const first = notifications[0];
  if (
    first?.message?.customType !== "firstmate-watcher-wake" ||
    first.message?.display !== false ||
    first.options?.deliverAs !== "nextTurn" ||
    first.options?.triggerTurn !== true
  ) {
    throw new Error(`first notification was not hidden next-turn delivery: ${JSON.stringify(first)}`);
  }
  await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "unrelated turn" }, {});
  const fallback = dispatch.createPrimaryWatcherWake("fallback batch", "branch-fallback");
  api.events.emit(dispatch.FM_PRIMARY_WATCHER_WAKE_EVENT, fallback);
  if (!fallback.accepted || notifications.length !== 1) {
    throw new Error(`branch fallback did not share the pending next-turn notification: ${JSON.stringify(notifications)}`);
  }

  await reloadExtension("same-session-reload", firstSession);
  await waitFor(() => armCount() >= 3, "same-session reload watcher");
  await triggerCurrent();
  await new Promise((resolve) => setTimeout(resolve, 40));
  if (notifications.length !== 1) {
    throw new Error(`same-session reload duplicated a pending notification: ${JSON.stringify(notifications)}`);
  }

  await startNextTurn();
  await handlers.get("session_switch")(
    { type: "session_switch", reason: "new" },
    { sessionManager: { getSessionFile: () => replacementSession } },
  );
  await waitFor(() => notifications.length >= 2, "original batch replay after session switch");
  if (readFileSync(queue, "utf8") !== queueRows) {
    throw new Error("session-switch replay retired durable wake rows");
  }
  if (notifications[1].message.content !== first.message.content) {
    throw new Error("session switch did not re-notify the exact unacknowledged durable batch");
  }

  delete globalThis.firstmateOmpPrimaryNotificationInstance;
  await reloadExtension("process-restart", replacementSession, false);
  await waitFor(() => notifications.length >= 3, "original batch replay after restart");
  if (readFileSync(queue, "utf8") !== queueRows) {
    throw new Error("process-restart replay retired durable wake rows");
  }
  if (notifications[2].message.content !== first.message.content) {
    throw new Error("process restart did not re-notify the exact unacknowledged durable batch");
  }
  if (sendAttempts !== 3) {
    throw new Error(`process restart did not make exactly one original-batch replay attempt: ${sendAttempts}`);
  }

  await tool.execute();
  await waitFor(() => armCount() >= 5, "restart watcher");
  await startNextTurn();
  failNextNotification = true;
  await triggerCurrent(4);
  if (sendAttempts !== 5 || !notifications[3].message.content.includes("could not deliver an actionable wake")) {
    throw new Error(`failed next-turn submission did not surface one replayable failure: ${JSON.stringify(notifications)}`);
  }
  if (readFileSync(queue, "utf8") !== queueRows) {
    throw new Error("failed next-turn submission retired durable wake rows");
  }

  await startNextTurn();
  await triggerCurrent(5);
  if (!notifications[4].message.content.includes("signal: synthetic durable batch")) {
    throw new Error("durable wake did not replay after next-turn submission failure");
  }

  await startNextTurn();
  writeFileSync(`${state}/reject-confirmation`, "reject\n");
  await triggerCurrent(6);
  const mismatch = notifications[5];
  if (!mismatch.message.content.includes("recovery generation mismatch")) {
    throw new Error(`generation-mismatched handoff was not surfaced: ${JSON.stringify(mismatch)}`);
  }
  if (readFileSync(queue, "utf8") !== queueRows) {
    throw new Error("generation-mismatched handoff retired durable wake rows");
  }
  if (!notifications.every((notification) =>
    notification.options?.deliverAs === "nextTurn" &&
    notification.options?.triggerTurn === true &&
    notification.message?.display === false,
  )) {
    throw new Error(`notification mode drifted across recovery: ${JSON.stringify(notifications)}`);
  }
  const handling = armRows().filter((row) => row.startsWith("handling "));
  if (!handling.every((row) => row.includes("generation=fixture-generation"))) {
    throw new Error(`handling confirmation lost its recovery generation: ${handling.join(" | ")}`);
  }
  await startNextTurn();
  const acknowledgedFollowUp = dispatch.createPrimaryWatcherWake("acknowledged follow-up", "branch-fallback");
  api.events.emit(dispatch.FM_PRIMARY_WATCHER_WAKE_EVENT, acknowledgedFollowUp);
  if (!acknowledgedFollowUp.accepted || notifications.length !== 7) {
    throw new Error(`in-flight wake did not accept one pending follow-up: ${JSON.stringify(notifications)}`);
  }
  writeFileSync(`${state}/.watcher-down`, "pending:handling:fixture-generation\n");
  const acknowledged = spawnSync(process.env.FM_WAKE_DRAIN, ["--ack-through", "3", "--recovery-generation", "fixture-generation"], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: process.env.FM_HOME, FM_STATE_OVERRIDE: state },
  });
  if (acknowledged.status !== 0 || !existsSync(`${state}/.omp-primary-nextturn-ack`)) {
    throw new Error(`durable wake acknowledgement did not retire its notification claim: ${acknowledged.stderr}`);
  }
  const notificationsBeforeAcknowledgedSwitch = notifications.length;
  await handlers.get("session_switch")(
    { type: "session_switch", reason: "resume" },
    { sessionManager: { getSessionFile: () => `${state}/acknowledged-session.jsonl` } },
  );
  await new Promise((resolve) => setTimeout(resolve, 40));
  if (notifications.length !== notificationsBeforeAcknowledgedSwitch) {
    throw new Error(`acknowledged durable wake replayed after replacement: ${JSON.stringify(notifications)}`);
  }
  console.log("omp-next-turn-batching-ok");
} finally {
  writeFileSync(`${state}/watch-trigger-${armCount()}`, "stop\n");
  await handlers.get("session_shutdown")({ type: "session_shutdown" }, {});
}
JS
  ) || status=$?
  expect_code 0 "$status" "OMP next-turn durable wake batching"
  assert_contains "$out" omp-next-turn-batching-ok "OMP did not coalesce hidden next-turn wake notifications"
  pass "OMP batches durable wake rows into replayable hidden next-turn notifications"
}

test_resolve_path_uses_node_when_readlink_f_is_unavailable
test_exact_bun_omp_primary_identity
test_standalone_omp_primary_identity
test_nested_foreign_harness_keeps_its_own_identity
test_primary_scope_requires_canonical_state
test_native_identity_handles_virtual_entrypoint
test_native_omp_fresh_checkout_nudges_once
test_primary_marker_refuses_whitespace_identity
test_native_primary_extension_contract
test_native_omp_confirms_recovery_handling_delivery
test_native_omp_refused_handling_delivery_is_typed_once
test_native_omp_coalesces_pending_next_turn_notifications
