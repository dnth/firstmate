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
//   2. Not a Firstmate primary scope -> inert. Ambient OMP discovery loads
//      project extensions into spawned worker sessions too, so exclusion is
//      enforced here by design, not by convention.
//   3. No explicit opt-in record (config/compact-adviser.json absent) -> inert.
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

// Same predicate the primary adapter uses; the shell libs are the contract
// owner (bin/fm-primary-scope-lib.sh, bin/fm-gate-refuse-lib.sh).
function primaryIntegrationApplies(): boolean {
  const result = spawnSync(
    "bash",
    [
      "-c",
      `
        . "$1/bin/fm-gate-refuse-lib.sh"
        . "$1/bin/fm-primary-scope-lib.sh"
        ! fm_is_gate_agent "$1" || exit 1
        ! fm_root_is_secondmate_home "$1" || exit 1
        fm_primary_scope_matches "$1" "$2" && exit 0
        # Only the native OMP owner admits a first plain launch before its
        # canonical state directory exists. Generic hooks remain silent.
        [ "$2" = "$1/state" ] && [ ! -e "$2" ] && [ ! -L "$2" ] || exit 1
        [ -f "$1/AGENTS.md" ] && [ -d "$1/bin" ] || exit 1
        git_dir=$(git -C "$1" rev-parse --git-dir 2>/dev/null) || exit 1
        git_common_dir=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || exit 1
        [ "$git_dir" = "$git_common_dir" ]
      `,
      "fm-omp-primary-scope",
      fmRoot,
      state,
    ],
    { stdio: "ignore" },
  );
  return result.status === 0;
}

export default function (omp: ExtensionAPI) {
  if (disabledByEnv(process.env[DISABLE_ENV])) return;
  if (!primaryIntegrationApplies()) return;
  const store = new ConfigStore(config);
  if (!store.exists()) return;
  installAdviser(omp, { configDir: config, logDir: state });
}
