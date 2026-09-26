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
  /** The child was killed because options.timeoutMs elapsed. */
  timedOut?: boolean;
  /** The child was killed because options.signal aborted. */
  aborted?: boolean;
}

export interface AsyncExecOptions {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /** Written to the child's stdin, which is closed either way. */
  input?: string;
  /** Upper bound on each captured output stream. */
  maxBuffer?: number;
  /** Receives each captured stdout and stderr chunk as the child emits it. */
  onData?: (data: Buffer) => void;
  /** Kills the child and settles when it fires. */
  signal?: AbortSignal;
  /** Kills the child after this many milliseconds. */
  timeoutMs?: number;
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
    let timer: NodeJS.Timeout | undefined;
    let child: ReturnType<typeof spawn>;
    const finish = (status: number | null, detail = "", flags?: { timedOut?: boolean; aborted?: boolean }): void => {
      if (settled) return;
      settled = true;
      if (timer !== undefined) clearTimeout(timer);
      options.signal?.removeEventListener("abort", onAbort);
      resolve({
        status,
        stdout,
        stderr: detail ? `${stderr}${detail}` : stderr,
        ...(flags?.timedOut ? { timedOut: true } : {}),
        ...(flags?.aborted ? { aborted: true } : {}),
      });
    };
    const onAbort = (): void => {
      try {
        child?.kill();
      } catch {}
      finish(null, "", { aborted: true });
    };
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
    if (options.signal) {
      options.signal.addEventListener("abort", onAbort);
      // A signal that fired between spawn and the listener attach would never
      // reach the listener, so the already-aborted state is applied directly.
      if (options.signal.aborted) {
        onAbort();
        return;
      }
    }
    if (options.timeoutMs !== undefined) {
      timer = setTimeout(() => {
        child.kill();
        finish(null, "", { timedOut: true });
      }, options.timeoutMs);
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
      options.onData?.(Buffer.from(chunk, "utf8"));
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
      options.onData?.(Buffer.from(chunk, "utf8"));
    });
    child.on("close", (code) => finish(code));
    child.on("error", (error: Error) => finish(null, error.message));
    if (child.stdin) {
      child.stdin.on("error", () => {});
      child.stdin.end(options.input ?? "");
    }
  });
}

// The OMP legacy shim's BashOperations.exec contract
// (extensibility/legacy-pi-coding-agent-shim.ts): a streaming onData callback,
// an optional AbortSignal, and a timeout in SECONDS, resolving to the exit
// code. The shim's executeLegacyBashOperations maps an "aborted" rejection onto
// its aborted error and a "timeout:<seconds>" rejection onto its timeout error,
// so those exact message shapes are the contract, not local choices.
export interface BashToolExecOptions {
  onData: (data: Buffer) => void;
  signal?: AbortSignal;
  timeout?: number;
  env?: NodeJS.ProcessEnv;
}

// The native bash tool's own default when the model passes no timeout; kept in
// step so a timeout-less branch bash call bounds like the native path did.
const BASH_TOOL_DEFAULT_TIMEOUT_SECONDS = 300;

export async function execBashTool(
  command: string,
  cwd: string,
  options: BashToolExecOptions,
): Promise<{ exitCode: number | null }> {
  const timeoutSeconds = options.timeout ?? BASH_TOOL_DEFAULT_TIMEOUT_SECONDS;
  const result = await runCommandAsync("bash", ["-c", command], {
    cwd,
    env: options.env,
    onData: options.onData,
    signal: options.signal,
    timeoutMs: timeoutSeconds * 1000,
  });
  if (result.aborted) throw new Error("aborted");
  if (result.timedOut) throw new Error(`timeout:${timeoutSeconds}`);
  if (result.status === null) {
    const detail = (result.stderr || result.stdout).trim();
    throw new Error(detail || "bash command could not be executed");
  }
  return { exitCode: result.status };
}

// Handed to createBashToolDefinition's operations seam so the branch bash tool
// executes through this runner with the spawnHook's injected env instead of
// the native execute, which since OMP 18.3.0 rejects env outside service mode
// ("ready and env require a service name."). The seam predates that release, so
// the same wiring is correct on every supported OMP version.
export const bashToolOperations = { exec: execBashTool };
