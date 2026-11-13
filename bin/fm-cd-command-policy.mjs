#!/usr/bin/env node
// Semantic policy for the cd-guard: does a shell command persistently change the
// PRIMARY firstmate shell's own working directory?
//
// A stray persistent top-level `cd projects/<clone>` silently relocates the
// primary shell, so the next firstmate-owned command (a backlog write, an
// fm-* lifecycle call, tasks-axi) runs inside a project clone instead of the
// home. This policy blocks exactly that class of command; the environmental
// scoping to the real primary checkout lives in the bin/fm-cd-pretool-check.sh
// transport, not here. See docs/cd-guard.md for the full contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification, so this guard never duplicates shell lexing. This policy
// never evaluates, sources, or runs any byte of the submitted command;
// it inspects lexical command positions and resolves only the operand forms
// documented in docs/cd-guard.md.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { accessSync, constants, existsSync, realpathSync, statSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REASONS = {
  "persistent-cd":
    "a persistent top-level directory change that would leave the primary firstmate home is blocked; it would move the shell out of the home so a later firstmate-owned command runs inside a project clone. A cd that stays inside the home is allowed. Reach any other target without moving the shell - use git -C <dir> or an absolute path on the command itself - or scope the cd to a subshell like (cd <dir> && ...).",
};

// Directory-changing builtins that mutate the calling shell's own cwd.
const CD_BUILTINS = new Set(["cd", "pushd", "popd"]);

// Shell keywords introduce a compound whose command position this lexical
// classifier does not model.
const SHELL_KEYWORDS = new Set([
  "if", "then", "else", "elif", "fi",
  "for", "do", "done", "while", "until",
  "case", "esac", "select", "function", "time", "!",
]);

// Wrappers that fork or exec a child before reaching the builtin, so a cd behind
// them never persists to the parent shell (and generally just fails, since cd is
// a builtin with no external program). `command` is deliberately NOT here: it
// runs the builtin in the current shell, so `command cd x` still persists.
const FORKING_WRAPPERS = new Set(["env", "sudo", "nohup", "timeout", "gtimeout", "exec"]);

function isPipe(separator) {
  return separator === "|" || separator === "|&";
}

// A top-level command-list node persists its cwd change to the parent shell
// unless it runs in a subshell context: backgrounded with a trailing `&`, or a
// stage of a pipeline (bash runs every pipeline stage in a subshell).
function nodePersists(separators, index) {
  if (separators[index] === "&") return false;
  if (isPipe(separators[index]) || isPipe(separators[index - 1])) return false;
  return true;
}

function deny(code) {
  return { decision: "deny", code, reason: REASONS[code] };
}

function hasPathQualifiedCommandPrefix(position) {
  return position.words
    .slice(position.prefixAssignments, position.index)
    .some((word) => word.value.includes("/") && word.value.split("/").at(-1) === "command");
}

function hasCommandQueryPrefix(position) {
  let commandPrefix = false;
  for (const word of position.words.slice(position.prefixAssignments, position.index)) {
    if (word.value === "command") {
      commandPrefix = true;
      continue;
    }
    if (commandPrefix && /^-[^-]*[vV]/.test(word.value)) return true;
  }
  return false;
}

// Resolve one target under both path rules. Logical collapses `..` lexically
// first, like Bash's default `cd`; physical follows symlinks component by
// component, like `cd -P`. Either failure means the target cannot be resolved.
function resolvedPaths(cwd, target) {
  const logical = resolve(cwd.logical, target);
  const physicalInput = target.startsWith("/") ? target : `${cwd.physical}/${target}`;
  try {
    return {
      logical,
      logicalDestination: realpathSync(logical),
      physical: realpathSync.native(physicalInput),
    };
  } catch {
    return null;
  }
}

function isInside(home, path) {
  return path === home || path.startsWith(`${home}/`);
}

function isProjectsTree(home, path) {
  return path === `${home}/projects` || path.startsWith(`${home}/projects/`);
}

// The home's own checkout is the only git worktree a shell may sit in, so a
// nested checkout below the home (a vendored clone or a linked worktree) is
// still out of bounds.
function isForeignCheckout(home, path) {
  let dir = path;
  while (dir !== home) {
    if (existsSync(join(dir, ".git"))) return true;
    const parent = dirname(dir);
    if (parent === dir) return true;
    dir = parent;
  }
  return false;
}

function expandTilde(value, userHome) {
  if (!value.startsWith("~")) return value;
  if (!userHome) return null;
  if (value === "~") return userHome;
  if (value.startsWith("~/")) return userHome + value.slice(1);
  return null; // ~user names a directory this policy cannot know.
}

const VARIABLE_WORD = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$/;

// The exempt argument is one word: a literal path, `~/...`, or a single
// `$FM_HOME` prefix this policy can expand from its own inputs. Any
// substitution, glob, or further expansion is a value this policy cannot know,
// so it is never resolved.
function expandTarget(word, context) {
  if (word.subs.length > 0 || word.droppedDoubleQuoteBackslash) return null;
  if (word.literal) {
    if (word.unquotedExpansion) return null;
    if (!word.value.startsWith("~") || word.firstProtected) return word.value;
    return expandTilde(word.value, context.userHome);
  }
  const match = VARIABLE_WORD.exec(word.value);
  if (!match) return null;
  // A variable operand is exempt only when the expansion is quoted: a quoted
  // expansion is neither word-split nor pathname-expanded, so its value reaches
  // cd as one literal path.
  if (!word.quoted || word.unquotedVariable) return null;
  const rest = match[3];
  if (rest.includes("$") || /[*?[\]{}]/.test(rest)) return null;
  const name = match[1] ?? match[2];
  if (name !== "FM_HOME" || !context.fmHome) return null;
  // The expansion context is normalized by decision() before it reaches here.
  if (!context.fmHome.startsWith("/")) return null;
  return context.fmHome + rest;
}

// An exempt cd must be certain to succeed: Bash's logical and physical rules
// must land on a searchable directory inside the home, outside projects/ and
// outside every foreign checkout. Only then can the next command be assumed to
// start there, and only then can an earlier cd prove it changed nothing else.
function exemptDirectory(home, path) {
  if (!isInside(home, path)) return false;
  if (isProjectsTree(home, path)) return false;
  if (isForeignCheckout(home, path)) return false;
  try {
    if (!statSync(path).isDirectory()) return false;
    accessSync(path, constants.X_OK);
  } catch {
    return false;
  }
  return true;
}

// The one operand a cd may carry. A leading `-` covers the special `-`
// (OLDPWD) and every option, which this policy does not model.
function cdOperand(position, wordIndex, context) {
  const args = position.words.slice(wordIndex + 1);
  if (args[0]?.value === "--" && args[0].literal && args[0].subs.length === 0) args.shift();
  if (args.length !== 1) return null;
  const target = expandTarget(args[0], context);
  if (target === null || target === "" || target.startsWith("-")) return null;
  const first = target.split("/")[0];
  if (!target.startsWith("/") && first !== "." && first !== ".." && context.cdpath !== "") return null;
  return target;
}

// One exempt cd, resolved under both path rules.
// Returns the destination pair, or null when the cd is not exempt.
function cdDestination(node, position, wordIndex, context, cwd) {
  if (!context.home) return null;
  // A redirection, heredoc body, or leading assignment can expand something
  // before the builtin runs and change what a later relative target means, so
  // an exempt cd carries none of them.
  if (position.prefixAssignments > 0) return null;
  if (node.some((token) => token.type === "redir")) return null;
  const target = cdOperand(position, wordIndex, context);
  if (target === null) return null;
  const resolved = resolvedPaths(cwd, target);
  if (resolved === null) return null;
  for (const path of [resolved.logical, resolved.logicalDestination, resolved.physical]) {
    if (!exemptDirectory(context.home, path)) return null;
  }
  return { logical: resolved.logical, physical: resolved.physical };
}

function decision(command, context = {}) {
  // The transport supplies the physical checkout root and the raw FM_HOME.
  // Normalize non-empty path inputs before containment and operand checks.
  const userHome = context.userHome ?? process.env.HOME ?? "";
  const settings = {
    home: context.home ? resolve(context.home) : "",
    fmHome: context.fmHome ? resolve(context.fmHome) : "",
    userHome: userHome ? resolve(userHome) : "",
    cdpath: context.cdpath ?? process.env.CDPATH ?? "",
  };
  const lexed = new Lexer(command).tokenize();
  // Fail open on syntax this classifier cannot tokenize. The cd-guard's threat
  // model is agent mistakes - an accidental bare `cd projects/foo` always
  // tokenizes - so we prioritize zero false blocks over catching malformed or
  // deliberately obfuscated bypasses, which stay out of scope by design.
  if (lexed.error) return { decision: "allow" };

  const { nodes, separators } = splitProgram(lexed.tokens);
  const positions = nodes.map(commandPosition);
  const hasKeyword = positions.some(({ command }) => command && command.literal && !command.quoted && !command.firstProtected && SHELL_KEYWORDS.has(command.value));
  if (hasKeyword && positions.some(({ words }) => words.some((word) => CD_BUILTINS.has(word.value)))) {
    return deny("persistent-cd");
  }
  let cwd = { logical: settings.home, physical: settings.home };
  // True while every earlier node is an exempt cd. Such a cd always succeeds
  // and mutates nothing, so nothing earlier can have changed HOME, FM_HOME, or
  // CDPATH, and no conditional separator can have skipped a node. Any other
  // node makes a later exemption unprovable: a builtin or function could have
  // reassigned those variables, which this lexical policy cannot enumerate.
  let provable = true;
  for (let index = 0; index < nodes.length; index += 1) {
    if (!nodePersists(separators, index)) {
      provable = false;
      continue;
    }
    // commandPosition ignores subshell/brace groups, quoted data, comments, and
    // substitutions (they contribute no top-level command word), and skips
    // leading assignments and wrappers to find the executed command word.
    const position = positions[index];
    if (hasPathQualifiedCommandPrefix(position) || hasCommandQueryPrefix(position)) {
      provable = false;
      continue;
    }
    let command = position.command;
    let wordIndex = position.index;
    while (command && (command.value === "builtin" || command.value === "command")) {
      wordIndex += 1;
      command = position.words[wordIndex];
    }
    if (!command || !CD_BUILTINS.has(command.value)) {
      provable = false;
      continue;
    }
    if (position.wrappers.some((wrapper) => FORKING_WRAPPERS.has(wrapper))) {
      provable = false;
      continue;
    }
    // A `||` before this cd means the previous command had to fail; an exempt
    // predecessor never fails, so that cd cannot run and its destination is
    // unprovable.
    if (!provable || separators[index - 1] === "||") return deny("persistent-cd");
    const destination = command.value === "cd" ? cdDestination(nodes[index], position, wordIndex, settings, cwd) : null;
    if (destination === null) return deny("persistent-cd");
    cwd = destination;
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, home: "", fmHome: "" };
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
    if (name === "--home") {
      if (i + 1 >= argv.length) throw new Error("--home requires a value");
      result.home = argv[i + 1];
      i += 1;
      continue;
    }
    if (name === "--fm-home") {
      if (i + 1 >= argv.length) throw new Error("--fm-home requires a value");
      result.fmHome = argv[i + 1];
      i += 1;
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
      const result = decision(args.command, { home: args.home, fmHome: args.fmHome });
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
