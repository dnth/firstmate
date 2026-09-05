import { spawn } from "node:child_process";

// OMP extensions, their tools, and their event handlers share the JavaScript
// thread that drives the active session. A synchronous child-process call in
// supervision delivery therefore stalls prompt handling and rendering for the
// child's whole lifetime.
//
// This helper owns the awaited-spawn replacement. It preserves the status,
// UTF-8 stdout, and UTF-8 stderr shape callers consumed from spawnSync, while
// yielding the OMP event loop until the child exits and its streams drain.
// Ordering that must remain serialized belongs to the caller's queue.

export interface AsyncExecResult {
  /** Exit code, or null when the child was signalled or never started. */
  status: number | null;
  stdout: string;
  stderr: string;
}

export interface AsyncExecOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /** Written to the child's stdin, which is closed either way. */
  input?: string;
  /** Upper bound on each captured output stream. */
  maxBuffer?: number;
}

const DEFAULT_MAX_BUFFER = 1024 * 1024;

export function runCommandAsync(
  command: string,
  args: readonly string[],
  options: AsyncExecOptions = {},
): Promise<AsyncExecResult> {
  return new Promise((resolve) => {
    let stdout = "";
    let stderr = "";
    let stdoutBytes = 0;
    let stderrBytes = 0;
    const maxBuffer = options.maxBuffer ?? DEFAULT_MAX_BUFFER;
    let settled = false;
    const finish = (status: number | null, detail = ""): void => {
      if (settled) return;
      settled = true;
      resolve({ status, stdout, stderr: detail ? `${stderr}${detail}` : stderr });
    };
    let child;
    try {
      child = spawn(command, [...args], {
        cwd: options.cwd,
        env: options.env,
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (error) {
      finish(null, error instanceof Error ? error.message : String(error));
      return;
    }
    child.stdout?.setEncoding("utf8");
    child.stdout?.on("data", (chunk: string) => {
      if (settled) return;
      const bytes = Buffer.byteLength(chunk, "utf8");
      if (stdoutBytes + bytes > maxBuffer) {
        child.kill();
        finish(null, `stdout exceeded ${maxBuffer} bytes`);
        return;
      }
      stdout += chunk;
      stdoutBytes += bytes;
    });
    child.stderr?.setEncoding("utf8");
    child.stderr?.on("data", (chunk: string) => {
      if (settled) return;
      const bytes = Buffer.byteLength(chunk, "utf8");
      if (stderrBytes + bytes > maxBuffer) {
        child.kill();
        finish(null, `stderr exceeded ${maxBuffer} bytes`);
        return;
      }
      stderr += chunk;
      stderrBytes += bytes;
    });
    child.on("close", (code) => finish(code));
    child.on("error", (error: Error) => finish(null, error.message));
    if (child.stdin) {
      child.stdin.on("error", () => {});
      child.stdin.end(options.input ?? "");
    }
  });
}
