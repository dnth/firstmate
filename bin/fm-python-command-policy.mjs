#!/usr/bin/env node
// Semantic policy for the Python runner guard: does a shell command invoke bare
// Python tooling that must run through uv instead?
//
// The rule is "Python runs through uv everywhere, never bare python3". This
// policy denies exactly that class of command in an executed command position
// and names the uv replacement; the local opt-in gate and the primary-checkout
// scoping live in the bin/fm-python-pretool-check.sh transport, not here.
// See docs/python-guard.md for the full contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, expands, sources, or runs any byte of the submitted command;
// it inspects lexical command positions only.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const REASONS = {
  python:
    "run Python through uv instead of bare python or python3: `uv run python <script>` (use `uv run --script <script>` when the script carries inline PEP 723 dependency metadata), `uv run python -c '<code>'`, or `uv run --with <pkg> python ...` for a one-off dependency.",
  pip:
    "manage Python packages through uv instead of bare pip: `uv add <pkg>` in a project, or `uv pip install <pkg>` in a venv.",
  pipxRun:
    "run a Python tool through uv instead of pipx: `uvx <tool>`.",
  pipxInstall:
    "install a Python tool through uv instead of pipx: `uv tool install <tool>`.",
  venv:
    "create virtual environments with `uv venv` instead of bare venv tooling.",
  module:
    "run that Python module through uv instead of `python -m`: `uvx <tool>` (or `uv run python -m <module>` when it must run inside the project environment).",
};

// Bare interpreter names: python, python3, python3.12, python3.12.4, python2.
const PYTHON_NAME = /^python(?:\d+(?:\.\d+)*)?$/;
// Bare pip entry points: pip, pip3, pip3.12. pipx is a separate tool family.
const PIP_NAME = /^pip(?:\d+(?:\.\d+)*)?$/;
// `python -m pip...` variants, including a private submodule path.
const MODULE_PIP_NAME = /^pip(?:\.[A-Za-z0-9_]+)*$/;
const MODULE_VENV_NAME = "venv";
const MODULE_VIRTUALENV_NAME = "virtualenv";

function deny(code, reason) {
  return { decision: "deny", code, reason };
}

function argsAfter(position, wordIndex) {
  return position.words.slice(wordIndex + 1);
}

function firstNonOption(words) {
  for (const word of words) {
    if (word.value === "--") continue;
    if (word.value.startsWith("-")) continue;
    return word.value;
  }
  return "";
}

// Classify the interpreter's leading options only: a `-m <module>` intent, a
// `-c`/`-` intent, or a script/bare invocation. Anything after the script word
// belongs to the script, not to the interpreter.
function pythonIntent(words) {
  for (let index = 0; index < words.length; index += 1) {
    const value = words[index].value;
    if (value === "-c" || value === "-") return { kind: "inline" };
    if (value === "-m") return { kind: "module", module: words[index + 1]?.value ?? "" };
    const attached = value.match(/^-m([A-Za-z0-9_.]+)$/);
    if (attached) return { kind: "module", module: attached[1] };
    if (value === "-W" || value === "-X") {
      index += 1;
      continue;
    }
    if (value === "--") return { kind: "script" };
    if (value.startsWith("-")) continue;
    return { kind: "script" };
  }
  return { kind: "script" };
}

function pythonDecision(words) {
  const intent = pythonIntent(words);
  if (intent.kind !== "module") return deny("bare-python", REASONS.python);
  const module = intent.module;
  if (!module) return deny("bare-python", REASONS.python);
  if (MODULE_PIP_NAME.test(module)) return deny("bare-pip", REASONS.pip);
  if (module === MODULE_VENV_NAME || module === MODULE_VIRTUALENV_NAME) return deny("bare-virtualenv", REASONS.venv);
  return deny("bare-python", REASONS.module);
}

function pipxDecision(words) {
  const subcommand = firstNonOption(words);
  if (subcommand === "install") return deny("bare-pipx", REASONS.pipxInstall);
  if (subcommand === "run") return deny("bare-pipx", REASONS.pipxRun);
  return { decision: "allow" };
}

function decision(command) {
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize, matching the cd-guard:
  // the threat model is agent mistakes, so zero false blocks wins over catching
  // a malformed or deliberately obfuscated bypass.
  if (lexed.error) return { decision: "allow" };

  const { nodes } = splitProgram(lexed.tokens);
  for (const tokens of nodes) {
    // commandPosition ignores subshell/brace groups, quoted data, comments, and
    // substitutions (they contribute no top-level command word), and skips
    // leading assignments and wrappers to find the executed command word.
    const position = commandPosition(tokens);
    let commandPrefix = false;
    const query = position.words.slice(position.prefixAssignments, position.index).some((word) => {
      if (word.value === "command") commandPrefix = true;
      return commandPrefix && /^-[^-]*[vV]/.test(word.value);
    });
    if (query) continue;
    let command = position.command;
    let wordIndex = position.index;
    while (command && (command.value === "builtin" || command.value === "command")) {
      wordIndex += 1;
      command = position.words[wordIndex];
    }
    if (!command) continue;
    const value = command.value;
    const args = argsAfter(position, wordIndex);
    if (PYTHON_NAME.test(value)) return pythonDecision(args);
    if (PIP_NAME.test(value) && firstNonOption(args) === "install") return deny("bare-pip", REASONS.pip);
    if (value === "pipx") {
      const result = pipxDecision(args);
      if (result.decision === "deny") return result;
    }
    if (value === "virtualenv") return deny("bare-virtualenv", REASONS.venv);
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
