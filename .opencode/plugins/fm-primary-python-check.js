import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { spawn } from "node:child_process";

// PreToolUse seatbelt for OpenCode: block bare Python tooling in the primary
// firstmate checkout before the agent's bash tool runs it (see
// bin/fm-python-pretool-check.sh and docs/python-guard.md).
// This mirrors fm-primary-cd-check.js, calling the Python runner guard owner
// instead of the cd-guard one. tool.execute.before can block by throwing
// (verified 2026-07-09 against OpenCode 1.17.15 for the watcher-arm plugin; the
// same mechanism carries this guard). The owner script is itself inert outside
// the real primary checkout, and inert without the local opt-in file, so a
// crewmate/scout worktree is never affected.

function runProcess(command, args) {
  return new Promise((resolvePromise) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolvePromise({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolvePromise({ code: code ?? 0, stdout, stderr }));
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

export const FmPrimaryPythonCheck = async ({ directory, worktree }) => {
  const root = worktree ? (() => {
    try {
      return realpathSync(worktree);
    } catch {
      return resolve(worktree);
    }
  })() : await resolveRoot(directory);

  return {
    "tool.execute.before": async (input, output) => {
      if (!root || input?.tool !== "bash") return;
      const command = output?.args?.command;
      if (!command || typeof command !== "string") return;

      const result = await runProcess(`${root}/bin/fm-python-pretool-check.sh`, ["--command", command]);
      if (result.code !== 2) return;

      const reason = result.stderr.trim() || "denied by the python-guard PreToolUse seatbelt";
      throw new Error(reason);
    },
  };
};
