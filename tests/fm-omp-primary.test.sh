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
  unset FM_OMP_BUN FM_OMP_BIN

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
    env -u FM_OMP_HARNESS -u FM_OMP_BUN -u FM_OMP_BIN \
      -u FM_OMP_PROCESS_EXPECTED_BUN -u FM_OMP_PROCESS_EXPECTED_BIN \
      -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
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
  cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$fixture/.omp/extensions/lib/fm-async-exec.ts"
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
  cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$fixture/.omp/extensions/lib/fm-async-exec.ts"
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
  cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$fixture/.omp/extensions/lib/fm-async-exec.ts"
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
  # Restore the suite's own mode. Leaving errexit on here would make every later
  # test's command substitution abort the whole script silently instead of
  # reporting its own "not ok" line.
  set +e
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
  cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$fixture/.omp/extensions/lib/fm-async-exec.ts"
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
    FM_OMP_TASK_TURN_STARTED="$fixture/home/state/secondmate.omp-started" \
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
async function waitForWatchCount(expected, label) {
  const file = `${process.env.FM_STATE_OVERRIDE}/watch-count`;
  for (let i = 0; i < 100; i += 1) {
    if (existsSync(file) && Number(readFileSync(file, "utf8").trim()) === expected) return;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}
process.argv[1] = process.env.EXTENSION;
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?test=${Date.now()}`);
await extension.default(api);
for (const required of ["session_start", "turn_start", "session_switch", "before_agent_start", "session_stop", "tool_call", "session_shutdown"]) {
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
await handlers.get("turn_start")({ type: "turn_start" }, extensionContext);
if (readFileSync(process.env.FM_OMP_TASK_TURN_STARTED, "utf8") !== `${process.pid}\n`) {
  throw new Error("OMP primary integration did not publish the task-bound turn-start marker");
}
if (existsSync(`${process.env.FM_STATE_OVERRIDE}/watch-count`)) {
  throw new Error("OMP turn_start armed the watcher before this session owned the lock");
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
// A turn that starts while this session owns the lock but no arm child is live
// re-asserts the watcher cycle at once rather than riding the whole turn
// unsupervised. The re-arm is idempotent: a second turn_start while that arm
// child is still live must not create a second cycle.
await handlers.get("turn_start")({ type: "turn_start" }, extensionContext);
await waitForWatchCount(1, "OMP turn_start watcher re-arm with no live arm child");
await handlers.get("turn_start")({ type: "turn_start" }, extensionContext);
await new Promise((resolve) => setTimeout(resolve, 80));
if (Number(readFileSync(`${process.env.FM_STATE_OVERRIDE}/watch-count`, "utf8").trim()) !== 1) {
  throw new Error("a second OMP turn_start created a second watcher cycle");
}
// A native switch re-arms the watcher at once, and OMP starts its first wake as
// an agent-initiated turn that never emits before_agent_start. The replacement
// nudge therefore has to land in the replacement session context at switch time,
// through sendMessage, and nothing may stay staged for a later before_agent_start.
const switchNudges = () => watcherMessages.filter((entry) => entry.message.customType === "firstmate-sessionstart-nudge");
async function expectSwitchNudge(label, expectedTotal) {
  const nudges = switchNudges();
  if (nudges.length !== expectedTotal) {
    throw new Error(`${label} did not append exactly one startup instruction (${nudges.length} total): ${JSON.stringify(nudges)}`);
  }
  const latest = nudges[nudges.length - 1];
  if (
    latest.message.content !== "encoded:session-start:Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions." ||
    latest.message.attribution !== "agent" ||
    latest.message.display !== false ||
    latest.options?.deliverAs !== "nextTurn" ||
    latest.options?.triggerTurn !== undefined
  ) {
    throw new Error(`${label} startup instruction was not appended as hidden agent context without a turn: ${JSON.stringify(latest)}`);
  }
  for (const attempt of [1, 2]) {
    if (await handlers.get("before_agent_start")({ type: "before_agent_start" }, {}) !== undefined) {
      throw new Error(`${label} staged its startup instruction for before_agent_start too (attempt ${attempt})`);
    }
  }
}
await handlers.get("session_switch")({ type: "session_switch", reason: "new" }, extensionContext);
await waitForWatchCount(2, "in-process OMP /new automatic watcher arm");
await expectSwitchNudge("in-process OMP /new", 1);
// Regression: a second /new with no before_agent_start in between must still
// deliver its own nudge because the replacement turn was agent-initiated.
await handlers.get("session_switch")({ type: "session_switch", reason: "new" }, extensionContext);
await waitForWatchCount(3, "in-process OMP second /new automatic watcher arm");
await expectSwitchNudge("in-process OMP second /new", 2);
await handlers.get("session_switch")({ type: "session_switch", reason: "resume" }, extensionContext);
await waitForWatchCount(4, "in-process OMP /resume automatic watcher arm");
await expectSwitchNudge("in-process OMP /resume", 3);
await handlers.get("session_switch")({ type: "session_switch", reason: "fork" }, extensionContext);
await waitForWatchCount(5, "in-process OMP /fork automatic watcher arm");
if (switchNudges().length !== 3 || await handlers.get("before_agent_start")({ type: "before_agent_start" }, {}) !== undefined) {
  throw new Error("in-process OMP /fork delivered a startup instruction while this session still holds the lock");
}
watcherMessages.length = 0;

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
  watcherMessages[0].options?.deliverAs !== "nextTurn" ||
  watcherMessages[0].options?.triggerTurn !== true
) {
  throw new Error(`OMP watcher notification did not use hidden next-turn delivery: ${JSON.stringify(watcherMessages[0])}`);
}
if (!existsSync(`${process.env.FM_STATE_OVERRIDE}/watch-successor-ready`)) {
  throw new Error("OMP actionable notification arrived before successor readiness");
}
// The successor arm child restored by the actionable close is the one live
// cycle; a turn_start arriving while it is still live must stay a no-op.
const restoredCount = Number(readFileSync(`${process.env.FM_STATE_OVERRIDE}/watch-count`, "utf8").trim());
await handlers.get("turn_start")({ type: "turn_start" }, extensionContext);
await new Promise((resolve) => setTimeout(resolve, 80));
if (Number(readFileSync(`${process.env.FM_STATE_OVERRIDE}/watch-count`, "utf8").trim()) !== restoredCount) {
  throw new Error("OMP turn_start created a second watcher cycle alongside the restored successor");
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

# A handling turn that begins with no live arm child used to ride the whole turn
# unsupervised: the beacon aged past FM_GUARD_GRACE and fm-guard.sh reported
# WATCHER DOWN on a session that was actively handling. turn_start now
# re-asserts the extension-owned cycle. This test drives the REAL arm script,
# watcher, and guard (only the arm entrypoint is wrapped, for a controllable
# outage): session_start arms one cycle, a simulated arm outage plus a dead
# watcher exhausts the continuity retries, the beacon goes stale and the guard
# fires, and the next turn_start restores exactly one cycle that keeps the
# beacon fresh through a turn lasting several grace windows - a >300s turn at
# production scale.
test_omp_turn_start_rearm_survives_long_turn() {
  local fixture state out status=0
  fixture="$TMP_ROOT/turn-start-long-turn"
  state="$fixture/state"
  mkdir -p "$fixture/bin" "$state" "$fixture/config" "$state/task.inbox" \
    "$fixture/.omp/extensions/lib"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$fixture/.omp/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  local f base
  for f in "$ROOT"/bin/*; do
    base=$(basename "$f")
    [ "$base" = fm-watch-arm.sh ] && continue
    ln -s "$f" "$fixture/bin/$base"
  done
  # The outage shim wraps the real arm script through a fixture-local link so
  # SCRIPT_DIR inside the real scripts resolves to this fixture's bin/ - the
  # watcher then records watcher-path under the fixture, matching the path the
  # extension's turn-end guard and the fm-guard.sh call below compare against.
  ln -s "$ROOT/bin/fm-watch-arm.sh" "$fixture/bin/fm-watch-arm-real.sh"
  cat > "$fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
fm_state="${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}"
printf 'arm-invoked %s\n' "$*" >> "$fm_state/arm-invocations"
if [ -f "$fm_state/.arm-fails" ]; then
  printf 'watcher: FAILED - fixture arm outage\n' >&2
  exit 1
fi
exec "$(dirname "$0")/fm-watch-arm-real.sh" "$@"
SH
  chmod +x "$fixture/bin/fm-watch-arm.sh"
  # One in-flight task keeps FM_SUP_NEEDED true so the guard watches this home.
  # Its window deliberately resolves nowhere: capture fails and the pane loop
  # skips it, so the real watcher stays quiet for the test's whole run.
  fm_write_meta "$state/fixturecrew.meta" \
    "window=fmtest-nonexistent:fakecrew" \
    "harness=omp" \
    "kind=ship"

  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" \
    FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$fixture/config" \
    FM_OMP_TASK_INBOX_DIR="$state/task.inbox" \
    FM_OMP_TASK_DOORBELL_READY="$state/task.omp-doorbell-ready" \
    FM_OMP_TASK_TURN_STARTED="$state/task.omp-started" \
    FM_SUPERVISION_MODEL=persistent \
    FM_GUARD_GRACE=8 FM_POLL=2 FM_SIGNAL_GRACE=1 \
    FM_HEARTBEAT=9999 FM_CHECK_INTERVAL=9999 \
    FM_ARM_CONFIRM_TIMEOUT=3 \
    FM_WATCH_REARM_RETRY_BASE_MS=50 FM_WATCH_REARM_RETRY_MAX_MS=150 \
    FM_OMP_ARM_READY_TIMEOUT_MS=30000 \
    node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, statSync, writeFileSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const state = process.env.FM_STATE_OVERRIDE;
const handlers = new Map();
const wakes = [];
const api = {
  zod: { object: () => ({}) },
  on(name, handler) { handlers.set(name, handler); },
  registerCommand() {},
  registerTool() {},
  sendMessage(message) { wakes.push(String(message?.content ?? "")); },
  sendUserMessage() {},
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor(pred, label, tries = 600) {
  for (let i = 0; i < tries; i += 1) {
    if (pred()) return;
    await sleep(100);
  }
  throw new Error(`timeout waiting for ${label}`);
}
const lockPid = () => {
  try { return readFileSync(`${state}/.watch.lock/pid`, "utf8").trim(); } catch { return ""; }
};
const pidAlive = (pid) => {
  if (!/^[0-9]+$/.test(pid)) return false;
  try { process.kill(Number(pid), 0); return true; } catch { return false; }
};
const beaconAgeMs = () => {
  try { return Date.now() - statSync(`${state}/.last-watcher-beat`).mtimeMs; } catch { return Infinity; }
};
const watcherHealthy = () => pidAlive(lockPid()) && beaconAgeMs() < 6000;
// Only the lock-holding watcher beats, so a fresh beacon means a live cycle
// exists; it stays true across a lawful successor handoff while lockPid()
// briefly reads empty between the old watcher's close and the successor's
// lock acquisition.
const beaconFresh = () => beaconAgeMs() < 6000;
const guard = () => spawnSync(`${process.env.FM_ROOT_OVERRIDE}/bin/fm-guard.sh`, [], {
  env: { ...process.env, FM_SUPERVISION_MODEL: "persistent" },
  encoding: "utf8",
});
const guardSaysDown = () => /WATCHER DOWN|watcher still down/.test(guard().stderr || "");
const armInvocations = () => existsSync(`${state}/arm-invocations`)
  ? readFileSync(`${state}/arm-invocations`, "utf8").trim().split("\n").length
  : 0;

process.argv[1] = process.env.EXTENSION;
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?longturn=${Date.now()}`);
extension.default(api);
const context = { sessionManager: { getSessionFile: () => "" } };
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
await handlers.get("session_start")({ type: "session_start" }, context);
await waitFor(watcherHealthy, "initial real watcher cycle");
if (guardSaysDown()) throw new Error("guard reported WATCHER DOWN with a live fresh watcher");
const firstWatcherPid = lockPid();

// Simulate the arm outage the lapse needs: break the arm seam, kill the live
// watcher, and let the bounded continuity retries all fail until the core
// surfaces the failure and gives up - the terminal blind state that used to
// last until the turn-end guard ran.
writeFileSync(`${state}/.arm-fails`, "1\n");
process.kill(Number(firstWatcherPid), "SIGKILL");
await waitFor(
  () => wakes.some((message) => message.includes("watcher: FAILED")),
  "continuity failure surface after the arm outage",
);
if (watcherHealthy()) throw new Error("a watcher stayed healthy through the simulated arm outage");
await waitFor(guardSaysDown, "fm-guard WATCHER DOWN during the blind window");

// The turn that opens on this blind session re-arms once the outage clears.
unlinkSync(`${state}/.arm-fails`);
await handlers.get("turn_start")({ type: "turn_start" }, context);
await waitFor(watcherHealthy, "turn_start watcher re-arm after the outage");
const healedPid = lockPid();
if (healedPid === firstWatcherPid) throw new Error("turn_start re-arm reported the dead watcher as the live cycle");

// Ride a turn spanning several grace windows: a live watcher cycle must keep
// the beacon advancing and the guard must never report WATCHER DOWN. The lock
// pid may legitimately change once - the watcher exits to deliver an
// actionable wake and the core instantly replaces it with a successor - but
// the beacon keeps advancing through that handoff because exactly one cycle
// is ever live.
let firstBeat = 0;
try { firstBeat = statSync(`${state}/.last-watcher-beat`).mtimeMs; } catch { firstBeat = 0; }
for (let i = 0; i < 7; i += 1) {
  await sleep(2000);
  if (guardSaysDown()) throw new Error(`guard reported WATCHER DOWN ${i + 1} grace-fractions into the handling turn`);
  if (!beaconFresh()) throw new Error("no live watcher cycle mid-turn");
}
if (statSync(`${state}/.last-watcher-beat`).mtimeMs <= firstBeat) {
  throw new Error("the live watcher's beacon never advanced during the turn");
}

// Further turn_starts inside a live cycle must not create another arm or
// watcher: the single-cycle invariant holds.
const armsBeforeExtraTurns = armInvocations();
await handlers.get("turn_start")({ type: "turn_start" }, context);
await handlers.get("turn_start")({ type: "turn_start" }, context);
await sleep(300);
if (armInvocations() !== armsBeforeExtraTurns) throw new Error("extra turn_starts spawned more watcher arms");
if (!watcherHealthy()) throw new Error("the live watcher cycle did not survive repeated turn_starts");

// The turn-end guard stays the backstop: healthy supervision lets the turn end.
const stop = await handlers.get("session_stop")({
  type: "session_stop",
  messages: [],
  turn_id: 1,
  session_id: "omp-session",
  stop_hook_active: false,
  signal: new AbortController().signal,
});
if (stop !== undefined) throw new Error(`a healthy turn end was blocked: ${JSON.stringify(stop)}`);
const finalPid = lockPid();
await handlers.get("session_shutdown")({ type: "session_shutdown" }, context);
await waitFor(() => !pidAlive(finalPid), "watcher teardown at session shutdown", 100);
console.log("omp-turn-start-rearm-ok");
JS
  ) || status=$?
  # The fixture's watcher must not outlive the test even on a mid-run failure.
  if [ -f "$state/.watch.lock/pid" ]; then
    kill "$(cat "$state/.watch.lock/pid" 2>/dev/null)" 2>/dev/null || true
  fi
  expect_code 0 "$status" "OMP turn_start rearm across a long turn"
  assert_contains "$out" omp-turn-start-rearm-ok "OMP turn_start did not restore single-cycle supervision through a long turn: $out"
  pass "OMP turn_start re-arms a missing watcher and keeps the guard silent through a long turn"
}

# The shared core delivers the recovery handshake for every runtime bound to it,
# so OMP must confirm a handling delivery exactly like Pi and OpenCode do: start
# and verify the successor, run fm-watch-arm.sh --handling-delivered for the
# generation the successor reported, and only then deliver the wake notification.
# Upstream covers Pi and OpenCode; this pins the fork's OMP binding of the same
# contract so a future adapter change cannot silently drop it.
test_native_omp_confirms_recovery_handling_delivery() {
  local fixture out status=0
  fixture="$TMP_ROOT/native-handling-delivery"
  mkdir -p "$fixture/.omp/extensions" "$fixture/bin" "$fixture/config" "$fixture/state"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  mkdir -p "$fixture/.omp/extensions/lib"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$fixture/.omp/extensions/lib/fm-async-exec.ts"
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
if (steers !== 1) throw new Error(`expected exactly one wake steer, got ${steers}`);
if (deliveryOptions?.deliverAs !== "nextTurn" || deliveryOptions?.triggerTurn !== true) {
  throw new Error(`wake was not delivered as a turn-triggering hidden next-turn message: ${JSON.stringify(deliveryOptions)}`);
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
  assert_contains "$out" omp-handling-delivery-ok "OMP did not confirm its recovery handling delivery after the wake notification"
  pass "OMP confirms the recovery handling handshake after delivering its hidden next-turn wake"
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
  cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$fixture/.omp/extensions/lib/fm-async-exec.ts"
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
if (steers !== 1) throw new Error(`refused handshake was not a single typed steer, got ${steers}`);
const refusals = armRows().filter((row) => row.startsWith("refused "));
if (refusals.length < 1) throw new Error(`handling-delivered was never attempted: ${armRows().join(" | ")}`);
console.log("omp-refused-handshake-ok");
JS
  ) || status=$?
  printf 'stop\n' > "$TMP_ROOT/native-handling-refused.stop" 2>/dev/null || true
  expect_code 0 "$status" "OMP refused handling delivery"
  assert_contains "$out" omp-refused-handshake-ok "OMP swallowed a refused handling handshake"
  pass "OMP surfaces a refused handling handshake as one typed wake"
}

test_native_omp_session_switch_carries_inflight_actionable_close() {
  local fixture out status=0
  fixture="$TMP_ROOT/native-session-replacement"
  mkdir -p "$fixture/.omp/extensions/lib" "$fixture/bin" "$fixture/state" "$fixture/config"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$fixture/.omp/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  cat > "$fixture/bin/fm-gate-refuse-lib.sh" <<'SH'
fm_is_gate_agent() { return 1; }
SH
  cat > "$fixture/bin/fm-primary-scope-lib.sh" <<'SH'
fm_primary_scope_matches() { return 0; }
SH
  cat > "$fixture/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
printf 'encoded:%s:%s' "$2" "$(cat)"
SH
  cat > "$fixture/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
state=${FM_STATE_OVERRIDE:?}
count=$(cat "$state/watch-count" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$state/watch-count"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
if [ "$count" -eq 1 ]; then
  while [ ! -e "$state/watch-trigger" ]; do sleep 0.02; done
  printf 'signal: omp replacement in-flight actionable close\n'
  exit 0
fi
while [ ! -e "$state/watch-stop" ]; do sleep 0.02; done
SH
  cat > "$fixture/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  for script in fm-subagent-pretool-check.sh fm-cd-pretool-check.sh fm-arm-pretool-check.sh; do
    cat > "$fixture/bin/$script" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  done
  chmod +x "$fixture/bin/"*.sh

  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_HOME="$fixture" \
    FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" FM_CONFIG_OVERRIDE="$fixture/config" \
    node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const steers = [];
let withholdConsumption = true;
let rejectNextBranchOffer = true;
const api = {
  zod: { object: () => ({}) },
  events: {
    emit(name, offer) {
      if (name !== "fm-branch-supervision:dispatch" || !rejectNextBranchOffer) return;
      rejectNextBranchOffer = false;
      offer.accept(Promise.reject(new Error("synthetic branch settlement rejection")));
    },
  },
  on(name, handler) { handlers.set(name, handler); },
  registerCommand() {},
  registerTool() {},
  // The runtime accepts each wake for an idle main: the injection opens an
  // agent-initiated turn, which emits turn_start and the custom message's own
  // message_start - never before_agent_start (see the switch-nudge note at the
  // native contract test). Withheld consumption models the runtime dropping
  // every one of those signals.
  sendMessage(message) {
    steers.push(String(message?.content ?? ""));
    if (withholdConsumption) {
      withholdConsumption = false;
      return;
    }
    handlers.get("turn_start")?.({ type: "turn_start" }, context);
    handlers.get("message_start")?.({
      type: "message_start",
      message: { role: "custom", customType: message.customType, content: message.content },
    });
  },
};
const count = () => existsSync(`${process.env.FM_STATE_OVERRIDE}/watch-count`)
  ? Number(readFileSync(`${process.env.FM_STATE_OVERRIDE}/watch-count`, "utf8").trim())
  : 0;
async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}

writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?replacement=${Date.now()}`);
extension.default(api);
const context = { sessionManager: { getSessionFile: () => undefined } };
await handlers.get("session_start")({ type: "session_start" }, context);
await waitFor(() => count() === 1, "initial automatic OMP arm");
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/watch-trigger`, "trigger\n");
await waitFor(() => steers.length === 1 && count() >= 2, "in-flight OMP delivery and successor");

await handlers.get("session_switch")({ type: "session_switch", reason: "new" }, context);
await waitFor(() => count() >= 3, "OMP /new replacement arm");
await waitFor(
  () => steers.filter((message) => message.includes("signal: omp replacement in-flight actionable close")).length === 2,
  "OMP replacement actionable replay",
);
const handoff = `${process.env.FM_STATE_OVERRIDE}/extensions/omp-primary-watch/session-replacement-actionable.json`;
await waitFor(() => !existsSync(handoff), "OMP replacement handoff cleanup");

for (const [reason, label] of [["resume", "/resume"], ["fork", "/fork"], ["resume", "reload"]]) {
  const before = count();
  await handlers.get("session_switch")({ type: "session_switch", reason }, context);
  await waitFor(() => count() > before, `OMP ${label} replacement arm`);
}
if (steers.filter((message) => message.includes("signal: omp replacement in-flight actionable close")).length !== 2) {
  throw new Error(`OMP replacement did not replay exactly once: ${steers.join(" | ")}`);
}
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/watch-stop`, "stop\n");
await handlers.get("session_shutdown")({ type: "session_shutdown" }, context);
console.log("omp-session-replacement-ok");
JS
  ) || status=$?
  expect_code 0 "$status" "OMP session-switch replacement continuity"
  assert_contains "$out" omp-session-replacement-ok "OMP replacement continuity test did not complete"
  pass "OMP /new /resume /fork and reload session_switch paths auto-arm and carry an in-flight actionable close"
}

# A wake that OMP queues into an already-running turn never starts a turn, so
# before_agent_start never acknowledges it. The shared core must bound that wait:
# the next actionable close still has to start its successor instead of parking
# the whole chain behind the first unacknowledged delivery, and its wake is
# coalesced into exactly one successor delivered at the next turn boundary
# while the queue row stays unread.
test_native_omp_unacknowledged_wake_keeps_successor_chain() {
  local fixture out status=0
  fixture="$TMP_ROOT/native-unacknowledged-wake"
  mkdir -p "$fixture/.omp/extensions/lib" "$fixture/bin" "$fixture/state" "$fixture/config"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$fixture/.omp/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  cp "$ROOT/bin/fm-wake-lib.sh" "$fixture/bin/fm-wake-lib.sh"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  cat > "$fixture/bin/fm-gate-refuse-lib.sh" <<'SH'
fm_is_gate_agent() { return 1; }
SH
  cat > "$fixture/bin/fm-primary-scope-lib.sh" <<'SH'
fm_primary_scope_matches() { return 0; }
SH
  cat > "$fixture/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
printf 'encoded:%s:%s' "$2" "$(cat)"
SH
  cat > "$fixture/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
state=${FM_STATE_OVERRIDE:?}
count=$(cat "$state/watch-count" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$state/watch-count"
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "$state/arm-log"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
if [ "$count" -le 2 ]; then
  while [ ! -e "$state/watch-trigger-$count" ]; do sleep 0.02; done
  printf 'signal: omp unacknowledged wake %s\n' "$count"
  exit 0
fi
while [ ! -e "$state/watch-stop" ]; do sleep 0.02; done
SH
  cat > "$fixture/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  for script in fm-subagent-pretool-check.sh fm-cd-pretool-check.sh fm-arm-pretool-check.sh; do
    cat > "$fixture/bin/$script" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  done
  chmod +x "$fixture/bin/"*.sh

  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_HOME="$fixture" \
    FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" FM_CONFIG_OVERRIDE="$fixture/config" \
    FM_WATCH_WAKE_CONSUME_TIMEOUT_MS=300 node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const handlers = new Map();
const steers = [];
const api = {
  zod: { object: () => ({}) },
  on(name, handler) { handlers.set(name, handler); },
  registerCommand() {},
  registerTool() {},
  // The runtime queues every wake as a steer into a running turn: delivery
  // resolves, no turn starts, and before_agent_start is never invoked for it.
  sendMessage(message) {
    const content = String(message?.content ?? "");
    if (content.includes("omp unacknowledged wake")) steers.push(content);
  },
};
const state = process.env.FM_STATE_OVERRIDE;
const bound = Number(process.env.FM_WATCH_WAKE_CONSUME_TIMEOUT_MS);
const count = () => existsSync(`${state}/watch-count`) ? Number(readFileSync(`${state}/watch-count`, "utf8").trim()) : 0;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) {
    if (pred()) return;
    await sleep(10);
  }
  throw new Error(`timeout waiting for ${label}`);
}
const queue = `${state}/.wake-queue`;
const queueRow = "1\t1\tsignal\tcrew.turn-ended\tsignal: durable row\n";
writeFileSync(queue, queueRow);
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const extension = await import(`${pathToFileURL(process.env.EXTENSION).href}?unacknowledged=${Date.now()}`);
extension.default(api);
const context = { sessionManager: { getSessionFile: () => undefined } };
await handlers.get("session_start")({ type: "session_start" }, context);
await waitFor(() => count() === 1, "initial automatic OMP arm");
writeFileSync(`${state}/watch-trigger-1`, "trigger\n");
await waitFor(() => steers.length === 1 && count() === 2, "first OMP delivery and its successor");
writeFileSync(`${state}/watch-trigger-2`, "trigger\n");
await waitFor(() => count() === 3, "third OMP arm after the unacknowledged delivery");
await sleep(bound * 3);
if (steers.length !== 1) throw new Error(`the open episode was re-injected: ${steers.length}`);
if (count() !== 3) throw new Error(`expected exactly three arms, got ${count()}`);
if (!steers[0].includes("signal: omp unacknowledged wake 1")) throw new Error(`delivery did not match its close: ${steers[0]}`);
const armRows = readFileSync(`${state}/arm-log`, "utf8").trim().split("\n");
if (!/predecessor=[0-9]+$/.test(armRows[2])) throw new Error(`third arm lost its predecessor identity: ${armRows.join(" | ")}`);
if (readFileSync(queue, "utf8") !== queueRow) throw new Error("the durable wake queue row was altered by the bounded acknowledgement");
writeFileSync(`${state}/watch-stop`, "stop\n");
await handlers.get("session_shutdown")({ type: "session_shutdown" }, context);
console.log("omp-unacknowledged-wake-ok");
JS
  ) || status=$?
  expect_code 0 "$status" "OMP unacknowledged wake continuity"
  assert_contains "$out" omp-unacknowledged-wake-ok "OMP unacknowledged-wake continuity test did not complete"
  pass "OMP unacknowledged wake delivery keeps the successor chain and delivers once per close"
}

make_omp_queue_fixture() {  # <name>
  local fixture=$TMP_ROOT/$1
  mkdir -p "$fixture/.omp/extensions/lib" "$fixture/bin" "$fixture/state" "$fixture/config"
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$fixture/.omp/extensions/fm-primary-omp.ts"
  cp "$ROOT/.omp/extensions/lib/fm-branch-dispatch.ts" "$fixture/.omp/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.omp/extensions/lib/fm-async-exec.ts" "$fixture/.omp/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.omp/extensions/lib/fm-task-inbox-doorbell.ts" "$fixture/.omp/extensions/lib/fm-task-inbox-doorbell.ts"
  cp "$ROOT/bin/fm-primary-watch-core.ts" "$fixture/bin/fm-primary-watch-core.ts"
  cp "$ROOT/bin/fm-pi-compatible-runtimes" "$fixture/bin/fm-pi-compatible-runtimes"
  cp "$ROOT/bin/fm-wake-lib.sh" "$fixture/bin/fm-wake-lib.sh"
  cat > "$fixture/bin/fm-gate-refuse-lib.sh" <<'SH'
fm_is_gate_agent() { return 1; }
SH
  cat > "$fixture/bin/fm-primary-scope-lib.sh" <<'SH'
fm_primary_scope_matches() { return 0; }
SH
  cat > "$fixture/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
printf 'encoded:%s:%s' "$2" "$(cat)"
SH
  cat > "$fixture/bin/fm-sessionstart-nudge.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fixture/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  for script in fm-subagent-pretool-check.sh fm-cd-pretool-check.sh fm-arm-pretool-check.sh; do
    cat > "$fixture/bin/$script" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  done
  chmod +x "$fixture/bin/"*.sh
  printf '%s\n' "$fixture"
}

write_queue_watcher() {  # <fixture>
  cat > "$1/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
state=${FM_STATE_OVERRIDE:?}
count=$(cat "$state/watch-count" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$state/watch-count"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$state/watch-stop" ]; do sleep 0.02; done
SH
  chmod +x "$1/bin/fm-watch-arm.sh"
}

test_native_omp_durable_queue_session_notifications() {
  local fixture out status=0
  fixture=$(make_omp_queue_fixture native-queue-session)
  write_queue_watcher "$fixture"
  FM_STATE_OVERRIDE="$fixture/state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal task-a.status "signal: task-a"' _ "$fixture" \
    || fail "the OMP queue fixture could not seed a durable wake row"
  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_HOME="$fixture" \
    FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" FM_CONFIG_OVERRIDE="$fixture/config" \
    node --input-type=module 2>&1 <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const state = process.env.FM_STATE_OVERRIDE;
const wakes = [];
const handlers = new Map();
const api = {
  zod: { object: () => ({}) },
  on(name, handler) { handlers.set(name, handler); },
  registerCommand() {},
  registerTool() {},
  sendMessage(message, options) {
    if (message?.customType === "firstmate-watcher-wake") wakes.push({ message, options });
  },
};
const count = () => existsSync(`${state}/watch-count`) ? Number(readFileSync(`${state}/watch-count`, "utf8")) : 0;
async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) { if (pred()) return; await new Promise((r) => setTimeout(r, 10)); }
  throw new Error(`timeout waiting for ${label}`);
}
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const module = await import(`${pathToFileURL(process.env.EXTENSION).href}?queue-session=${Date.now()}`);
module.default(api);
const context = { sessionManager: { getSessionFile: () => undefined, getSessionId: () => "sess-one" } };
await handlers.get("session_start")({ type: "session_start" }, context);
await waitFor(() => count() === 1, "initial arm");
await waitFor(() => wakes.length === 1, "session-start durable wake");
if (wakes[0].options?.deliverAs !== "nextTurn" || wakes[0].options?.triggerTurn !== true) throw new Error("session-start wake used the wrong delivery mode");
await handlers.get("session_switch")({ type: "session_switch", reason: "new" }, context);
await waitFor(() => wakes.length === 2, "session-switch durable wake");
if (wakes.length !== 2) throw new Error(`expected two session-event notifications, got ${wakes.length}`);
writeFileSync(`${state}/watch-stop`, "stop\n");
await handlers.get("session_shutdown")({ type: "session_shutdown" }, {});
console.log("omp-durable-queue-session-notifications-ok");
JS
  ) || status=$?
  printf 'stop\n' > "$fixture/state/watch-stop" 2>/dev/null || true
  expect_code 0 "$status" "OMP durable queue session notifications"
  assert_contains "$out" omp-durable-queue-session-notifications-ok "session events did not re-notify queued durable wakes: $out"
  pass "OMP re-notifies durable wakes once on session start and switch"
}

test_native_omp_empty_queue_suppresses_session_notifications() {
  local fixture out status=0
  fixture=$(make_omp_queue_fixture native-queue-empty)
  write_queue_watcher "$fixture"
  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_HOME="$fixture" \
    FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" FM_CONFIG_OVERRIDE="$fixture/config" \
    node --input-type=module 2>&1 <<'JS'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const state = process.env.FM_STATE_OVERRIDE;
let wakes = 0;
const handlers = new Map();
const api = { zod: { object: () => ({}) }, on(name, handler) { handlers.set(name, handler); }, registerCommand() {}, registerTool() {}, sendMessage(message) { if (message?.customType === "firstmate-watcher-wake") wakes += 1; } };
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const module = await import(`${pathToFileURL(process.env.EXTENSION).href}?queue-empty=${Date.now()}`);
module.default(api);
const context = { sessionManager: { getSessionFile: () => undefined, getSessionId: () => "sess-one" } };
await handlers.get("session_start")({ type: "session_start" }, context);
await handlers.get("session_switch")({ type: "session_switch", reason: "new" }, context);
await new Promise((r) => setTimeout(r, 100));
if (wakes !== 0) throw new Error(`empty queue produced ${wakes} notifications`);
writeFileSync(`${state}/watch-stop`, "stop\n");
await handlers.get("session_shutdown")({ type: "session_shutdown" }, {});
console.log("omp-empty-queue-session-notifications-ok");
JS
  ) || status=$?
  printf 'stop\n' > "$fixture/state/watch-stop" 2>/dev/null || true
  expect_code 0 "$status" "OMP empty queue session notifications"
  assert_contains "$out" omp-empty-queue-session-notifications-ok "empty durable queue produced a session notification: $out"
  pass "OMP suppresses session notifications when the durable queue is empty"
}

test_native_omp_core_handoff_suppresses_queue_notification() {
  local fixture out status=0
  fixture=$(make_omp_queue_fixture native-queue-core-handoff)
  write_queue_watcher "$fixture"
  mkdir -p "$fixture/state/extensions/omp-primary-watch"
  printf '{"version":2,"pending":[{"version":1,"token":"1-2-3","message":"signal: core owned undelivered close","predecessorArmPid":""}]}\n' \
    > "$fixture/state/extensions/omp-primary-watch/session-replacement-actionable.json"
  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_HOME="$fixture" \
    FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" FM_CONFIG_OVERRIDE="$fixture/config" \
    node --input-type=module 2>&1 <<'JS'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const state = process.env.FM_STATE_OVERRIDE;
const wakes = [];
const handlers = new Map();
const api = { zod: { object: () => ({}) }, on(name, handler) { handlers.set(name, handler); }, registerCommand() {}, registerTool() {}, sendMessage(message, options) { if (message?.customType === "firstmate-watcher-wake") wakes.push({ message, options }); } };
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const module = await import(`${pathToFileURL(process.env.EXTENSION).href}?queue-core=${Date.now()}`);
module.default(api);
await handlers.get("session_start")({ type: "session_start" }, { sessionManager: { getSessionFile: () => undefined, getSessionId: () => "sess-one" } });
for (let i = 0; i < 300 && wakes.length === 0; i += 1) await new Promise((r) => setTimeout(r, 10));
if (wakes.length !== 1 || !wakes[0].message.content.includes("core owned undelivered close")) throw new Error(`core handoff delivery was not exclusive: ${JSON.stringify(wakes)}`);
if (wakes[0].options?.deliverAs !== "nextTurn" || wakes[0].options?.triggerTurn !== true) throw new Error("core handoff used the wrong delivery mode");
writeFileSync(`${state}/watch-stop`, "stop\n");
await handlers.get("session_shutdown")({ type: "session_shutdown" }, {});
console.log("omp-core-handoff-queue-notification-ok");
JS
  ) || status=$?
  printf 'stop\n' > "$fixture/state/watch-stop" 2>/dev/null || true
  expect_code 0 "$status" "OMP core handoff queue notification"
  assert_contains "$out" omp-core-handoff-queue-notification-ok "core handoff was duplicated by queue notification: $out"
  pass "OMP core handoff suppresses duplicate durable queue notification"
}

# Issue #82: with the supervision branch unavailable, a burst of actionable
# closes during one claimed, unacknowledged main handling episode must not
# re-inject operational wakes that preempt the handler. The episode ends at a
# main turn boundary, which delivers zero or one successor depending on whether
# unread main-owned queue rows remain.
test_native_omp_main_fallback_coalesces_burst() {
  local fixture out status=0
  fixture=$(make_omp_queue_fixture native-fallback-coalesce)
  cat > "$fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
state=${FM_STATE_OVERRIDE:?}
count=$(cat "$state/watch-count" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$state/watch-count"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$state/watch-stop" ]; do
  if [ -e "$state/wake-now-$count" ]; then
    printf 'signal: burst-close-%s\n' "$count"
    exit 0
  fi
  sleep 0.02
done
SH
  chmod +x "$fixture/bin/fm-watch-arm.sh"
  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_HOME="$fixture" \
    FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" FM_CONFIG_OVERRIDE="$fixture/config" \
    node --input-type=module 2>&1 <<'JS'
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const state = process.env.FM_STATE_OVERRIDE;
const handlers = new Map();
const wakes = [];
const api = {
  zod: { object: () => ({}) },
  on(name, handler) { handlers.set(name, handler); },
  registerCommand() {},
  registerTool() {},
  // The supervision branch is unavailable: no events surface accepts the offer,
  // so every ordinary actionable wake falls back to main.
  sendMessage(message) {
    if (message?.customType === "firstmate-watcher-wake") wakes.push(String(message.content ?? ""));
  },
};
const queue = `${state}/.wake-queue`;
const seqFile = `${state}/.wake-queue.seq`;
let seq = 0;
const rows = new Map();
const appendRow = (kind, key) => {
  seq += 1;
  const line = `0\t${seq}\t${kind}\t${key}\t${kind}: ${key}`;
  rows.set(seq, line);
  writeFileSync(seqFile, `${seq}\n`);
  appendFileSync(queue, `${line}\n`);
};
const ackThrough = (cutoff) => {
  for (const [s, line] of rows) if (s <= cutoff) rows.delete(s);
  writeFileSync(queue, [...rows.values()].map((line) => `${line}\n`).join(""));
};
const count = () => existsSync(`${state}/watch-count`) ? Number(readFileSync(`${state}/watch-count`, "utf8").trim()) : 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) { if (pred()) return; await sleep(10); }
  throw new Error(`timeout waiting for ${label}`);
}
const consumeWake = (content) => handlers.get("message_start")({ message: { role: "user", content } });
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const module = await import(`${pathToFileURL(process.env.EXTENSION).href}?coalesce=${Date.now()}`);
module.default(api);
const context = { sessionManager: { getSessionFile: () => undefined, getSessionId: () => "sess-one" } };
await handlers.get("session_start")({ type: "session_start" }, context);
await waitFor(() => count() === 1, "initial arm");

// Steps 1-2: one task-local row falls back to main; main claims and starts
// handling it (consumes the wake) while the episode stays unacknowledged.
appendRow("signal", "crew-one.turn-ended");
writeFileSync(`${state}/wake-now-1`, "go\n");
await waitFor(() => wakes.length === 1 && count() === 2, "first fallback wake and its successor");
if (!wakes[0].includes("signal: burst-close-1")) throw new Error(`first wake mismatched its close: ${wakes[0]}`);
consumeWake(wakes[0]);

// Steps 3-4: two higher-sequence rows close their watcher cycles mid-episode.
// Both stay durable in the queue and neither may inject a second notification.
appendRow("signal", "crew-two.turn-ended");
writeFileSync(`${state}/wake-now-2`, "go\n");
await waitFor(() => count() === 3, "successor arm after the first burst row");
appendRow("stale", "default:w1:p2");
writeFileSync(`${state}/wake-now-3`, "go\n");
await waitFor(() => count() === 4, "successor arm after the second burst row");
await sleep(300);
if (wakes.length !== 1) throw new Error(`burst re-injected during the open episode: ${wakes.length} wakes`);

// Step 8: a real captain message during handling is not coalesced - it is a
// normal user message, never matched against the wake text or the episode.
consumeWake("captain: stop what you are doing and look at this");
await sleep(150);
if (wakes.length !== 1) throw new Error(`captain interjection produced an operational wake: ${wakes.length}`);

// Steps 5-6: the handler drains the aggregate once and acknowledges the latest
// sequence; with no unread main-owned rows the boundary delivers no successor.
ackThrough(3);
await handlers.get("turn_end")({});
await sleep(300);
if (wakes.length !== 1) throw new Error(`acknowledgement was followed by a redundant successor: ${wakes.length} wakes`);

// Step 7: a new close opens a second episode; acknowledging through it while
// leaving one higher-sequence row unread delivers exactly one successor.
appendRow("signal", "crew-three.turn-ended");
writeFileSync(`${state}/wake-now-4`, "go\n");
await waitFor(() => wakes.length === 2 && count() === 5, "second-episode fallback wake");
consumeWake(wakes[1]);
appendRow("signal", "crew-four.turn-ended");
writeFileSync(`${state}/wake-now-5`, "go\n");
await waitFor(() => count() === 6, "successor arm after the leftover row's close");
ackThrough(4);
await handlers.get("turn_end")({});
await waitFor(() => wakes.length === 3, "exactly one successor for the unread leftover row");
if (!wakes[2].includes("signal: burst-close-5")) throw new Error(`successor wake mismatched its close: ${wakes[2]}`);
await sleep(300);
if (wakes.length !== 3) throw new Error(`the leftover row was notified more than once: ${wakes.length} wakes`);

// Restart recovery: the granted successor is accepted but still unconsumed, so
// a session replacement must persist it and replay it exactly once under the
// new generation - no lost wake, no duplicate accepted turn.
await handlers.get("session_switch")({ type: "session_switch", reason: "new" }, context);
await waitFor(() => wakes.length === 4, "replacement replay of the unconsumed successor");
if (!wakes[3].includes("signal: burst-close-5")) throw new Error(`replacement replayed the wrong close: ${wakes[3]}`);
await sleep(300);
if (wakes.length !== 4) throw new Error(`replacement duplicated the replayed wake: ${wakes.length} wakes`);

writeFileSync(`${state}/watch-stop`, "stop\n");
await handlers.get("session_shutdown")({ type: "session_shutdown" }, context);
console.log("omp-fallback-coalesce-ok");
JS
  ) || status=$?
  printf 'stop\n' > "$fixture/state/watch-stop" 2>/dev/null || true
  expect_code 0 "$status" "OMP main-fallback burst coalescing"
  assert_contains "$out" omp-fallback-coalesce-ok "OMP fallback burst was not coalesced: $out"
  pass "OMP coalesces fallback wakes into one in-flight notification per handling episode"
}

# An idle-main injection opens an agent-initiated turn that emits no
# before_agent_start, so consumption must come from turn_start or the wake's
# own custom-role message_start. Regression for the wedge where one such send
# left mainFallbackWakeInFlight set forever and suppressed every later wake.
test_native_omp_idle_main_wake_consumption_and_stale_bound() {
  local fixture out status=0
  fixture=$(make_omp_queue_fixture native-idle-wake-consume)
  cat > "$fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
state=${FM_STATE_OVERRIDE:?}
count=$(cat "$state/watch-count" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$state/watch-count"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$state/watch-stop" ]; do
  if [ -e "$state/wake-now-$count" ]; then
    printf 'signal: idle-close-%s\n' "$count"
    exit 0
  fi
  sleep 0.02
done
SH
  chmod +x "$fixture/bin/fm-watch-arm.sh"
  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_HOME="$fixture" \
    FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" FM_CONFIG_OVERRIDE="$fixture/config" \
    node --input-type=module 2>&1 <<'JS'
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const state = process.env.FM_STATE_OVERRIDE;
const episodeFile = `${state}/extensions/omp-primary-watch/main-fallback-episode.state`;
const handlers = new Map();
const wakes = [];
// suppressConsume models the runtime surface that reports the wedge: the
// injection is accepted but no turn_start, message_start, or
// before_agent_start ever names it.
let suppressConsume = false;
const context = { sessionManager: { getSessionFile: () => undefined, getSessionId: () => "sess-one" } };
const api = {
  zod: { object: () => ({}) },
  on(name, handler) { handlers.set(name, handler); },
  registerCommand() {},
  registerTool() {},
  sendMessage(message) {
    if (message?.customType !== "firstmate-watcher-wake") return;
    wakes.push(String(message.content ?? ""));
    if (suppressConsume) return;
    // An idle main starts an agent-initiated turn: turn_start and the injected
    // message's own custom-role message_start fire, before_agent_start never
    // does.
    handlers.get("turn_start")?.({ type: "turn_start" }, context);
    handlers.get("message_start")?.({
      type: "message_start",
      message: { role: "custom", customType: "firstmate-watcher-wake", content: message.content },
    });
  },
};
const queue = `${state}/.wake-queue`;
const seqFile = `${state}/.wake-queue.seq`;
let seq = 0;
const rows = new Map();
const appendRow = (kind, key) => {
  seq += 1;
  const line = `0\t${seq}\t${kind}\t${key}\t${kind}: ${key}`;
  rows.set(seq, line);
  writeFileSync(seqFile, `${seq}\n`);
  appendFileSync(queue, `${line}\n`);
};
const drainAll = () => {
  rows.clear();
  writeFileSync(queue, "");
};
const count = () => existsSync(`${state}/watch-count`) ? Number(readFileSync(`${state}/watch-count`, "utf8").trim()) : 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(pred, label) {
  for (let i = 0; i < 500; i += 1) { if (pred()) return; await sleep(10); }
  throw new Error(`timeout waiting for ${label}`);
}
const episodeState = () => existsSync(episodeFile) ? readFileSync(episodeFile, "utf8") : "";
const episodeField = (name) => (episodeState().match(new RegExp(`^${name}=(.*)$`, "m")) || [])[1] ?? "";

writeFileSync(`${state}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const module = await import(`${pathToFileURL(process.env.EXTENSION).href}?idle-consume=${Date.now()}`);
module.default(api);
await handlers.get("session_start")({ type: "session_start" }, context);
await waitFor(() => count() === 1, "initial arm");

// Leg 1: an idle-main wake is consumed by its own turn boundary signals alone
// (no before_agent_start), and the episode mirror lands on disk.
appendRow("signal", "crew-a.turn-ended");
writeFileSync(`${state}/wake-now-1`, "go\n");
await waitFor(() => wakes.length === 1 && count() === 2, "idle-main fallback wake and successor");
if (!wakes[0].includes("signal: idle-close-1")) throw new Error(`first idle wake mismatched its close: ${wakes[0]}`);
await waitFor(() => episodeState() !== "", "persisted episode state");
if (episodeField("in_flight") !== "0") throw new Error(`idle wake was not consumed by turn_start: ${episodeState()}`);
if (Number(episodeField("in_flight_sent_at_ms")) <= 0 || Number(episodeField("last_consume_at_ms")) <= 0) {
  throw new Error(`episode state lost its send/consume timestamps: ${episodeState()}`);
}
drainAll();
await handlers.get("turn_end")({ type: "turn_end" }, context);
await sleep(100);

// Leg 2: wedge - the next idle send is accepted but every consumption signal
// is dropped. The first boundary counts it; the second must clear it and let
// the rows-outlived successor fire.
suppressConsume = true;
appendRow("signal", "crew-b.turn-ended");
writeFileSync(`${state}/wake-now-2`, "go\n");
await waitFor(() => wakes.length === 2 && count() === 3, "wedged idle-main fallback wake");
await sleep(50);
if (episodeField("in_flight") !== "1") throw new Error(`wedged wake was not persisted in-flight: ${episodeState()}`);
await handlers.get("turn_end")({ type: "turn_end" }, context);
await sleep(150);
if (wakes.length !== 2) throw new Error(`a successor fired before the stale bound: ${wakes.length}`);
if (episodeField("in_flight_turn_ends") !== "1") throw new Error(`boundary count was not persisted: ${episodeState()}`);
suppressConsume = false;
await handlers.get("turn_end")({ type: "turn_end" }, context);
await waitFor(() => wakes.length === 3, "stale in-flight bound did not release one successor");
if (!wakes[2].includes("wakes remain queued")) throw new Error(`stale-bound successor carried the wrong wake: ${wakes[2]}`);
drainAll();
await handlers.get("turn_end")({ type: "turn_end" }, context);
await sleep(150);
if (episodeField("in_flight") !== "0") throw new Error(`cleared marker still persisted in-flight: ${episodeState()}`);

// Leg 3: after the wedge clears, an ordinary close must inject again instead
// of staying suppressed behind the stale marker.
appendRow("signal", "crew-c.turn-ended");
writeFileSync(`${state}/wake-now-3`, "go\n");
await waitFor(() => wakes.length === 4 && count() === 4, "post-wedge close injection");
if (!wakes[3].includes("signal: idle-close-3")) throw new Error(`post-wedge wake mismatched its close: ${wakes[3]}`);
drainAll();
await handlers.get("turn_end")({ type: "turn_end" }, context);
await sleep(150);

// Leg 4: a wedged marker over a fully drained queue clears at a single
// boundary and the next close injects immediately.
suppressConsume = true;
appendRow("signal", "crew-d.turn-ended");
writeFileSync(`${state}/wake-now-4`, "go\n");
await waitFor(() => wakes.length === 5 && count() === 5, "second wedged idle-main wake");
drainAll();
await handlers.get("turn_end")({ type: "turn_end" }, context);
await sleep(150);
appendRow("signal", "crew-e.turn-ended");
writeFileSync(`${state}/wake-now-5`, "go\n");
await waitFor(() => wakes.length === 6, "close after a drained-queue wedge was still suppressed");
if (!wakes[5].includes("signal: idle-close-5")) throw new Error(`post-drain wake mismatched its close: ${wakes[5]}`);

writeFileSync(`${state}/watch-stop`, "stop\n");
await handlers.get("session_shutdown")({ type: "session_shutdown" }, context);
console.log("omp-idle-wake-consume-ok");
JS
  ) || status=$?
  printf 'stop\n' > "$fixture/state/watch-stop" 2>/dev/null || true
  expect_code 0 "$status" "OMP idle-main wake consumption"
  assert_contains "$out" omp-idle-wake-consume-ok "OMP idle-main wake stayed suppressed or unbounded: $out"
  pass "OMP idle-main wakes consume at turn_start and a stale in-flight marker is bounded"
}

test_native_omp_delivered_handoff_does_not_suppress_queue_notification() {
  local fixture out status=0
  fixture=$(make_omp_queue_fixture native-queue-delivered-handoff)
  write_queue_watcher "$fixture"
  mkdir -p "$fixture/state/extensions/omp-primary-watch"
  printf '{"version":2,"pending":[{"version":1,"token":"1-2-3","message":"signal: already delivered","predecessorArmPid":"","delivered":true}]}\n' \
    > "$fixture/state/extensions/omp-primary-watch/session-replacement-actionable.json"
  FM_STATE_OVERRIDE="$fixture/state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal task-a.status "signal: task-a"' _ "$fixture" \
    || fail "the delivered-handoff fixture could not seed a durable wake row"
  out=$(EXTENSION="$fixture/.omp/extensions/fm-primary-omp.ts" FM_HOME="$fixture" \
    FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$fixture/state" FM_CONFIG_OVERRIDE="$fixture/config" \
    node --input-type=module 2>&1 <<'JS'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const state = process.env.FM_STATE_OVERRIDE;
const wakes = [];
const handlers = new Map();
const api = { zod: { object: () => ({}) }, on(name, handler) { handlers.set(name, handler); }, registerCommand() {}, registerTool() {}, sendMessage(message, options) { if (message?.customType === "firstmate-watcher-wake") wakes.push({ message, options }); } };
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
process.argv[1] = process.env.EXTENSION;
const module = await import(`${pathToFileURL(process.env.EXTENSION).href}?queue-delivered-handoff=${Date.now()}`);
module.default(api);
await handlers.get("session_start")({ type: "session_start" }, { sessionManager: { getSessionFile: () => undefined, getSessionId: () => "sess-one" } });
for (let i = 0; i < 300 && wakes.length === 0; i += 1) await new Promise((r) => setTimeout(r, 10));
if (wakes.length !== 1) throw new Error(`delivered handoff suppressed or duplicated the queue wake: ${wakes.length}`);
if (wakes[0].options?.deliverAs !== "nextTurn" || wakes[0].options?.triggerTurn !== true) throw new Error("queue wake used the wrong delivery mode");
writeFileSync(`${state}/watch-stop`, "stop\n");
await handlers.get("session_shutdown")({ type: "session_shutdown" }, {});
console.log("omp-delivered-handoff-queue-notification-ok");
JS
  ) || status=$?
  printf 'stop\n' > "$fixture/state/watch-stop" 2>/dev/null || true
  expect_code 0 "$status" "OMP delivered handoff queue notification"
  assert_contains "$out" omp-delivered-handoff-queue-notification-ok "delivered handoff suppressed durable queue notification: $out"
  pass "OMP ignores already-delivered handoffs when notifying queued wakes"
}

# fm-guard.sh reads the persisted episode mirror and must warn exactly when an
# in-flight wake has outlived a recorded turn boundary.
test_fm_guard_warns_on_stale_omp_inflight_wake() {
  local fixture state out
  fixture="$TMP_ROOT/guard-stale-inflight"
  state="$fixture/state"
  mkdir -p "$fixture/bin" "$state/extensions/omp-primary-watch" "$fixture/config"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$fixture/bin/$(basename "$f")"; done
  : > "$fixture/AGENTS.md"
  git init -q -b main "$fixture"
  fm_write_meta "$state/fixturecrew.meta" \
    "window=fmtest-nonexistent:fakecrew" \
    "harness=omp" \
    "kind=ship"
  local episode_state="$state/extensions/omp-primary-watch/main-fallback-episode.state"
  cat > "$episode_state" <<'EOF'
version=1
generation=1
episode=1
in_flight=1
in_flight_token=0123456789abcdef
in_flight_sent_at_ms=1000
in_flight_turn_ends=1
last_consume_at_ms=0
last_turn_start_at_ms=1500
last_turn_end_at_ms=2000
updated_at_ms=2000
EOF
  out=$(FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$fixture/config" "$fixture/bin/fm-guard.sh" 2>&1)
  assert_contains "$out" "main-fallback wake stayed in-flight" \
    "fm-guard did not warn on an in-flight wake older than a turn"
  # A marker with no turn boundary after its send is still within its bound.
  sed -i 's/^in_flight_sent_at_ms=1000/in_flight_sent_at_ms=3000/' "$episode_state"
  out=$(FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$fixture/config" "$fixture/bin/fm-guard.sh" 2>&1)
  assert_not_contains "$out" "stayed in-flight" \
    "fm-guard warned on an in-flight wake younger than a turn"
  # A cleared marker never warns.
  sed -i 's/^in_flight=1/in_flight=0/' "$episode_state"
  out=$(FM_HOME="$fixture" FM_ROOT_OVERRIDE="$fixture" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$fixture/config" "$fixture/bin/fm-guard.sh" 2>&1)
  assert_not_contains "$out" "stayed in-flight" \
    "fm-guard warned on a cleared in-flight marker"
  pass "fm-guard warns only when an OMP in-flight wake outlives a turn boundary"
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
test_omp_turn_start_rearm_survives_long_turn
test_native_omp_confirms_recovery_handling_delivery
test_native_omp_refused_handling_delivery_is_typed_once
test_native_omp_session_switch_carries_inflight_actionable_close
test_native_omp_unacknowledged_wake_keeps_successor_chain
test_native_omp_durable_queue_session_notifications
test_native_omp_empty_queue_suppresses_session_notifications
test_native_omp_core_handoff_suppresses_queue_notification
test_native_omp_main_fallback_coalesces_burst
test_native_omp_idle_main_wake_consumption_and_stale_bound
test_native_omp_delivered_handoff_does_not_suppress_queue_notification
test_fm_guard_warns_on_stale_omp_inflight_wake
