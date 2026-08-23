#!/usr/bin/env bash
# Guarded Treehouse acquisition for every pooled Firstmate task.
# It snapshots candidate reflogs before Treehouse runs, contains reset and clean
# through treehouse-git-guard/git, and withholds the acquired path until the
# append-only post-acquisition transition check succeeds.
# The Git guard owns recovery of an interrupted worktree add and removes only
# its exact expected Git-unregistered numbered-slot target.
# --accepted-local-base <full commit SHA> is restricted to a current local default-branch tip and is verified before guarded acquisition.
# --ready-file writes the verified acquired path from this invocation before an
# interactive shell starts, so RunPod relaunch cannot reuse a stale pane cwd.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
REAL_GIT=$(command -v git 2>/dev/null) || {
  echo "error: git is required for guarded Treehouse acquisition" >&2
  exit 1
}
GUARD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-get.XXXXXX") || exit 1
trap 'rm -rf "$GUARD_DIR"' EXIT
# shellcheck source=bin/fm-pool-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pool-lib.sh"

lease_mode=0
ready_file=
accepted_local_base=
accepted_local_base_set=0
treehouse_args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lease)
      lease_mode=1
      treehouse_args+=("$1")
      ;;
    --ready-file)
      shift
      [ "$#" -gt 0 ] || {
        echo "error: --ready-file requires an absolute path" >&2
        exit 2
      }
      ready_file=$1
      case "$ready_file" in
        /*) ;;
        *) echo "error: --ready-file requires an absolute path" >&2; exit 2 ;;
      esac
      ;;
    --accepted-local-base)
      [ "$accepted_local_base_set" -eq 0 ] || {
        echo "error: --accepted-local-base may be specified only once" >&2
        exit 2
      }
      shift
      [ "$#" -gt 0 ] || {
        echo "error: --accepted-local-base requires a full commit SHA" >&2
        exit 2
      }
      accepted_local_base=$1
      accepted_local_base_set=1
      ;;
    --accepted-local-base=*)
      [ "$accepted_local_base_set" -eq 0 ] || {
        echo "error: --accepted-local-base may be specified only once" >&2
        exit 2
      }
      accepted_local_base=${1#--accepted-local-base=}
      accepted_local_base_set=1
      ;;
    *) treehouse_args+=("$1") ;;
  esac
  shift
done
repo=$PWD
interactive_holder="fm-interactive-${BASHPID:-$$}"
synthetic_acquired=
synthetic_verified=0
guard_pool_root=${FM_TREEHOUSE_LOCAL_ROOT:-}

if [ "${IS_SANDBOX:-0}" = 1 ]; then
  [ -n "$guard_pool_root" ] || {
    echo "error: RunPod Treehouse acquisition requires a local pool root" >&2
    exit 1
  }
fi
if [ "$accepted_local_base_set" -eq 1 ]; then
  case "$accepted_local_base" in
    ''|*[!0-9a-f]*)
      echo "error: --accepted-local-base must be a full lowercase hexadecimal commit SHA" >&2
      exit 2
      ;;
  esac
  if [ "${#accepted_local_base}" -lt 40 ] || [ "${#accepted_local_base}" -gt 64 ]; then
    echo "error: --accepted-local-base must be a full 40- to 64-character commit SHA" >&2
    exit 2
  fi
  local_default=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  local_default=${local_default#origin/}
  if [ -z "$local_default" ]; then
    for branch in main master; do
      if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        local_default=$branch
        break
      fi
    done
  fi
  local_head=$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$local_default^{commit}" 2>/dev/null || true)
  resolved_base=$(git -C "$repo" rev-parse --verify --quiet "$accepted_local_base^{commit}" 2>/dev/null || true)
  if [ -z "$local_default" ] || [ "$resolved_base" != "$accepted_local_base" ] || [ "$local_head" != "$accepted_local_base" ]; then
    echo "error: --accepted-local-base must equal the current local default-branch tip" >&2
    exit 2
  fi
fi

# shellcheck disable=SC2329 # Invoked indirectly by the signal trap handlers below.
return_interrupted_synthetic_lease() {
  local path=$synthetic_acquired
  [ "$lease_mode" -eq 0 ] || return 0
  if [ -z "$path" ] && [ -s "$GUARD_DIR/stdout" ]; then
    path=$(sed -n '1p' "$GUARD_DIR/stdout")
  fi
  if [ -z "$path" ]; then
    echo "warning: interrupted guarded Treehouse acquisition preserved the unverified lease held by $interactive_holder" >&2
    return 1
  fi
  if [ "$synthetic_verified" -ne 1 ]; then
    echo "warning: interrupted guarded Treehouse acquisition preserved the unverified lease at $path" >&2
    return 1
  fi
  if ! fm_pool_worktree_clean "$path" || ! fm_pool_worktree_idle "$path"; then
    echo "warning: interrupted guarded Treehouse shell preserved the dirty, live, or unverifiable lease at $path" >&2
    return 1
  fi
  if ! ( cd "$repo" && "$SCRIPT_DIR/fm-treehouse-command.sh" return --if-lease-holder "$interactive_holder" "$path" ); then
    echo "warning: interrupted guarded Treehouse shell could not return its verified clean lease at $path" >&2
    return 1
  fi
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_signal() {
  local signal=$1 status=1
  trap - HUP INT TERM
  return_interrupted_synthetic_lease || true
  case "$signal" in
    HUP) status=129 ;;
    INT) status=130 ;;
    TERM) status=143 ;;
  esac
  exit "$status"
}
trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

if ! "$SCRIPT_DIR/fm-treehouse-status-read-only.sh" --candidates "$PWD" > "$GUARD_DIR/candidates"; then
  echo "error: could not establish a safe Treehouse acquisition boundary" >&2
  exit 1
fi
if [ -n "$accepted_local_base" ]; then
  default_ref=$accepted_local_base
else
  default_ref=$(git -C "$PWD" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -z "$default_ref" ]; then
    default_branch=$(git -C "$PWD" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ -z "$default_branch" ] || default_ref="refs/heads/$default_branch"
  fi
fi
if ! node - "$GUARD_DIR/candidates" "$GUARD_DIR/reflogs.json" "$default_ref" "$REAL_GIT" <<'NODE'
const fs = require("fs");
const { spawnSync } = require("child_process");
const [candidatesPath, snapshotPath, defaultRef, git] = process.argv.slice(2);
const fields = fs.readFileSync(candidatesPath).toString("utf8").split("\0");
const snapshots = [];
for (let index = 0; index + 1 < fields.length; index += 2) {
  const worktree = fields[index + 1];
  if (!worktree) continue;
  const result = spawnSync(git, ["-C", worktree, "rev-parse", "--path-format=absolute", "--git-path", "logs/HEAD"], {encoding:"utf8"});
  if (result.status !== 0) continue;
  const log = result.stdout.trim();
  let prefix = "";
  try {
    prefix = fs.readFileSync(log).toString("base64");
  } catch (error) {
    if (error.code !== "ENOENT") process.exit(1);
  }
  snapshots.push({worktree, defaultRef, log, prefix});
}
fs.writeFileSync(snapshotPath, JSON.stringify(snapshots));
NODE
then
  echo "error: could not snapshot Treehouse candidate reflogs before acquisition" >&2
  exit 1
fi

[ "$lease_mode" -eq 1 ] || treehouse_args+=(--lease --lease-holder "$interactive_holder")
FM_TREEHOUSE_REAL_GIT=$REAL_GIT \
FM_TREEHOUSE_GUARD_ERROR_FILE="$GUARD_DIR/error" \
FM_TREEHOUSE_GUARD_SAFE_FILE="$GUARD_DIR/safe" \
FM_TREEHOUSE_GUARD_COMPLETE_FILE="$GUARD_DIR/complete" \
FM_TREEHOUSE_GUARD_POOL_ROOT="$guard_pool_root" \
PATH="$SCRIPT_DIR/treehouse-git-guard:$PATH" \
  "$SCRIPT_DIR/fm-treehouse-command.sh" get "${treehouse_args[@]}" > "$GUARD_DIR/stdout"
status=$?
if [ "$lease_mode" -eq 0 ] && [ "$status" -eq 0 ]; then
  synthetic_acquired=$(sed -n '1p' "$GUARD_DIR/stdout")
fi
if [ "$status" -ne 0 ] && [ -s "$GUARD_DIR/error" ]; then
  sed -n '1p' "$GUARD_DIR/error" >&2
fi
if ! node - "$GUARD_DIR/reflogs.json" "$REAL_GIT" <<'NODE'
const fs = require("fs");
const { spawnSync } = require("child_process");
const [snapshotPath, git] = process.argv.slice(2);
for (const snapshot of JSON.parse(fs.readFileSync(snapshotPath, "utf8"))) {
  let current;
  try {
    current = fs.readFileSync(snapshot.log);
  } catch {
    process.stderr.write(`error: refusing pooled worktree acquisition at ${snapshot.worktree}: could not verify its post-acquisition reflog\n`);
    process.exit(42);
  }
  const prefix = Buffer.from(snapshot.prefix, "base64");
  if (current.length < prefix.length || !current.subarray(0, prefix.length).equals(prefix)) {
    process.stderr.write(`error: refusing pooled worktree acquisition at ${snapshot.worktree}: its reflog changed outside the append-only containment boundary\n`);
    process.exit(42);
  }
  const appended = current.subarray(prefix.length).toString("utf8").split("\n");
  for (const line of appended) {
    if (!line) continue;
    const [oldCommit, newCommit] = line.split(" ", 2);
    if (!snapshot.defaultRef || !/^[0-9a-f]{40,64}$/.test(oldCommit) || !/^[0-9a-f]{40,64}$/.test(newCommit)) {
      process.stderr.write(`error: refusing pooled worktree acquisition at ${snapshot.worktree}: could not verify a post-acquisition reflog transition\n`);
      process.exit(42);
    }
    if (/^0+$/.test(oldCommit)) continue;
    const oldAncestor = spawnSync(git, ["-C", snapshot.worktree, "merge-base", "--is-ancestor", oldCommit, snapshot.defaultRef]);
    if (oldAncestor.status === 1) {
      process.stderr.write(`error: refusing pooled worktree acquisition at ${snapshot.worktree}: detected an unsafe post-reset condition that discarded ${oldCommit}\n`);
      process.exit(42);
    }
    const newAncestor = spawnSync(git, ["-C", snapshot.worktree, "merge-base", "--is-ancestor", newCommit, snapshot.defaultRef]);
    if (![0, 1].includes(oldAncestor.status) || ![0, 1].includes(newAncestor.status)) {
      process.stderr.write(`error: refusing pooled worktree acquisition at ${snapshot.worktree}: could not verify post-acquisition ancestry\n`);
      process.exit(42);
    }
  }
}
NODE
then
  exit 1
fi
if [ "$status" -eq 0 ] && [ ! -f "$GUARD_DIR/complete" ]; then
  echo "error: refusing pooled worktree acquisition because Treehouse did not complete the guarded reset path" >&2
  exit 1
fi
[ "$status" -eq 0 ] || exit "$status"
acquired=$(sed -n '1p' "$GUARD_DIR/stdout")
[ -n "$acquired" ] || {
  echo "error: refusing pooled worktree acquisition because Treehouse reported no acquired path" >&2
  exit 1
}
synthetic_verified=1
if [ "$lease_mode" -eq 1 ]; then
  printf '%s\n' "$acquired"
  exit 0
fi

shell=${SHELL:-/bin/sh}
(
  cd "$acquired" || exit 1
  if [ -n "$ready_file" ]; then
    ready_dir=$(dirname "$ready_file")
    [ -d "$ready_dir" ] && [ ! -L "$ready_dir" ] && [ ! -L "$ready_file" ] || {
      echo "error: guarded Treehouse ready path is unavailable or unsafe: $ready_file" >&2
      exit 1
    }
    ready_tmp="$ready_dir/.ready.$$"
    printf '%s\n' "$acquired" > "$ready_tmp" || exit 1
    mv -f -- "$ready_tmp" "$ready_file" || exit 1
  fi
  TREEHOUSE_DIR="$acquired" FM_TREEHOUSE_WRAPPER_PID=$$ "$shell"
)
shell_status=$?
if ! ( cd "$repo" && "$SCRIPT_DIR/fm-treehouse-command.sh" return --if-lease-holder "$interactive_holder" "$acquired" ); then
  echo "warning: guarded Treehouse shell exited but its lease at $acquired could not be returned" >&2
  exit 1
fi
exit "$shell_status"
