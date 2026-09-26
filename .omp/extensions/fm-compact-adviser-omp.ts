// Firstmate compact adviser for OMP - attended-primary, hint-only.
//
// Advises the captain to run /compact when a TypeSafe (Jev) judgment says the
// latest unit of work is finished and the context window is filling. It never
// compacts automatically and never injects the hint into model context: the
// hint surface is person-only via ctx.ui.setWidget/setStatus (captain-resolved
// contract; every sendMessage deliverAs variant enters model context).
//
// Judge semantics and privacy budgets are pinned to upstream compact-adviser
// commit b2a27b59ce86af4dc8fb5141e169bfbed1e68cee; the OMP API surface was
// re-verified against @oh-my-pi/pi-coding-agent 18.2.6 source.
//
// Gate chain, all required before any behavior registers:
//   1. COMPACT_ADVISER_DISABLE truthy -> inert (upstream kill switch).
//   2. Explicit spawned-worker identity (FM_OMP_HARNESS=omp or the OMP task
//      markers fm-spawn stamps at launch) -> inert. A worker that inherits the
//      primary's FM_*_OVERRIDE variables must never reach the consent check.
//   3. The extension's own module root is a linked worktree or a secondmate
//      home -> inert. This check runs on the module path itself, BEFORE any
//      operational-directory override is consulted, so an inherited
//      FM_ROOT_OVERRIDE pointing at the primary cannot launder a worker's
//      extension root into a passing scope check.
//   4. Not a Firstmate primary scope -> inert. Ambient OMP discovery loads
//      project extensions into spawned worker sessions too, so exclusion is
//      enforced here by design, not by convention.
//   5. No explicit opt-in record (config/compact-adviser.json absent) -> inert.
//      The file's existence is the consent gate; neither .omp/config.yml nor
//      native WATCHDOG advisor config counts as TypeSafe sharing consent.
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { installAdviser } from "./lib/compact-adviser/adviser.ts";
import { ConfigStore } from "./lib/compact-adviser/config.ts";
import { DISABLE_ENV, disabledByEnv } from "./lib/compact-adviser/disable.ts";

const extensionFile = fileURLToPath(import.meta.url);
const root = resolve(dirname(extensionFile), "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;

// Spawned-worker identity markers stamped by bin/fm-spawn.sh at launch. A
// primary session never carries any of them; a worker or secondmate always
// carries FM_OMP_HARNESS=omp, and the task markers cover the same boundary.
// FM_TASK_ID is the harness-neutral launch-env identity bin/fm-spawn.sh sets
// on every non-secondmate kind.
const WORKER_IDENTITY_ENV = [
  "FM_OMP_HARNESS",
  "FM_OMP_TASK_INBOX_DIR",
  "FM_OMP_TASK_TURN_STARTED",
  "FM_OMP_SESSION_POINTER",
  "FM_TASK_ID",
];

function spawnedWorkerIdentity(): boolean {
  if (process.env.FM_OMP_HARNESS === "omp") return true;
  return WORKER_IDENTITY_ENV.slice(1).some((name) => process.env[name] !== undefined);
}

// Same predicate the primary adapter uses; the shell libs are the contract
// owner (bin/fm-primary-scope-lib.sh, bin/fm-gate-refuse-lib.sh). The module
// root ($3) is checked before the override-resolved root ($1): a linked
// worktree or secondmate home hosting this file is refused outright, so
// inherited FM_*_OVERRIDE values can never activate a worker's copy.
function primaryIntegrationApplies(): boolean {
  const result = spawnSync(
    "bash",
    [
      "-c",
      `
        . "$1/bin/fm-gate-refuse-lib.sh"
        . "$1/bin/fm-primary-scope-lib.sh"
        ! fm_root_is_secondmate_home "$2" || exit 1
        module_git_dir=$(git -C "$2" rev-parse --git-dir 2>/dev/null) || exit 1
        module_git_common_dir=$(git -C "$2" rev-parse --git-common-dir 2>/dev/null) || exit 1
        [ "$module_git_dir" = "$module_git_common_dir" ] || exit 1
        ! fm_is_gate_agent "$1" || exit 1
        ! fm_root_is_secondmate_home "$1" || exit 1
        fm_primary_scope_matches "$1" "$3" && exit 0
        # Only the native OMP owner admits a first plain launch before its
        # canonical state directory exists. Generic hooks remain silent.
        [ "$3" = "$1/state" ] && [ ! -e "$3" ] && [ ! -L "$3" ] || exit 1
        [ -f "$1/AGENTS.md" ] && [ -d "$1/bin" ] || exit 1
        git_dir=$(git -C "$1" rev-parse --git-dir 2>/dev/null) || exit 1
        git_common_dir=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || exit 1
        [ "$git_dir" = "$git_common_dir" ]
      `,
      "fm-omp-primary-scope",
      fmRoot,
      root,
      state,
    ],
    { stdio: "ignore" },
  );
  return result.status === 0;
}

export default function (omp: ExtensionAPI) {
  if (disabledByEnv(process.env[DISABLE_ENV])) return;
  if (spawnedWorkerIdentity()) return;
  if (!primaryIntegrationApplies()) return;
  const store = new ConfigStore(config);
  if (!store.exists()) return;
  installAdviser(omp, { configDir: config, logDir: state });
}

