#!/usr/bin/env bash
# shellcheck shell=bash
# Single owner for RunPod Treehouse-root parsing, physical containment, and
# idempotent managed-directory creation.
#
# The callers intentionally have different historical contracts. Keep each
# entry point's original acceptance, parsing, ordering, and error behavior when
# sharing the underlying implementation here.

fm_treehouse_root_real_directory() {  # <absolute normalized directory>
  local path=$1 physical
  case "$path" in /*) ;; *) return 1 ;; esac
  case "$path/" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  physical=$(cd "$path" 2>/dev/null && pwd -P) || return 1
  [ "$physical" = "$path" ]
}

fm_treehouse_root_validate() {  # <pool-root>
  local root=$1 child
  fm_treehouse_root_real_directory "$root" || return 1
  for child in .treehouse .firstmate-config; do
    fm_treehouse_root_real_directory "$root/$child" || return 1
  done
}

fm_treehouse_root_prepare_existing() {  # <pool-root>
  local root=$1 child
  fm_treehouse_root_real_directory "$root" || return 1
  for child in .treehouse .firstmate-config; do
    if [ ! -e "$root/$child" ] && [ ! -L "$root/$child" ]; then
      mkdir -- "$root/$child" 2>/dev/null || {
        [ -d "$root/$child" ] && [ ! -L "$root/$child" ] || return 1
      }
    fi
  done
  fm_treehouse_root_validate "$root"
}

fm_treehouse_root_prepare_directory() {  # <safe-parent> <child-name>
  local parent=$1 name=$2 path
  fm_treehouse_root_real_directory "$parent" || return 1
  case "$name" in ''|.|..|*/*) return 1 ;; esac
  path="$parent/$name"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    mkdir -- "$path" 2>/dev/null || {
      [ -d "$path" ] && [ ! -L "$path" ] || return 1
    }
  fi
  fm_treehouse_root_real_directory "$path"
}

fm_treehouse_root_config_read_worker() {  # <config>
  local config=$1 roots
  [ -f "$config" ] && [ ! -L "$config" ] || return 1
  roots=$(sed -n 's/^[[:space:]]*root[[:space:]]*=[[:space:]]*"\([^"\\]*\)"[[:space:]]*$/\1/p' "$config") \
    || return 1
  case "$roots" in ''|*$'\n'*) return 1 ;; esac
  printf '%s\n' "$roots"
}

fm_treehouse_root_prepare_overlay() {  # <pool-root> <overlay-key> <repo-name>
  local root=$1 key=$2 repo_name=$3 parent repo
  parent="$root/.firstmate-config/$key"
  fm_treehouse_root_prepare_directory "$root/.firstmate-config" "$key" || return 1
  repo="$parent/$repo_name"
  fm_treehouse_root_prepare_directory "$parent" "$repo_name" || return 1
  printf '%s\n' "$repo"
}

fm_treehouse_root_config_rewrite_overlay() {  # <source> <destination> <pool-root>
  node - "$1" "$2" "$3" <<'NODE'
const fs = require("fs");
const [source, destination, root] = process.argv.slice(2);
const lines = fs.readFileSync(source, "utf8").replace(/^\uFEFF/, "").split(/\r?\n/);
const replacement = `root = ${JSON.stringify(root)}`;
let section = lines.findIndex((line) => /^\s*\[/.test(line));
if (section < 0) section = lines.length;
let rootIndex = -1;
let rootAssignment;
function basicKey(raw) {
  const normalized = raw.replace(/\\U([0-9A-Fa-f]{8})/g, (_, hex) => {
    const point = Number.parseInt(hex, 16);
    if (point > 0x10ffff) process.exit(2);
    const encoded = JSON.stringify(String.fromCodePoint(point));
    return encoded.slice(1, -1);
  });
  try {
    return JSON.parse(`"${normalized}"`);
  } catch {
    process.exit(2);
  }
}
for (let index = 0; index < section; index += 1) {
  const assignment = lines[index].match(/^\s*((?:[A-Za-z0-9_-]+)|(?:"(?:\\.|[^"\\])*")|(?:'[^']*'))\s*=\s*/);
  if (!assignment) continue;
  const rawKey = assignment[1];
  const key = rawKey.startsWith('"')
    ? basicKey(rawKey.slice(1, -1))
    : rawKey.startsWith("'") ? rawKey.slice(1, -1) : rawKey;
  if (key !== "root") continue;
  if (rootIndex !== -1) process.exit(2);
  rootIndex = index;
  rootAssignment = assignment[0];
}
if (rootIndex === -1) {
  lines.splice(section, 0, replacement);
} else {
  const value = lines[rootIndex].slice(rootAssignment.length);
  if (value.startsWith("'''")) {
    let end = value.includes("'''", 3) ? rootIndex : rootIndex + 1;
    while (end < lines.length && !lines[end].includes("'''")) end += 1;
    if (end >= lines.length) process.exit(2);
    lines.splice(rootIndex, end - rootIndex + 1, replacement);
  } else if (value.startsWith('"""')) {
    let end = value.includes('"""', 3) ? rootIndex : rootIndex + 1;
    while (end < lines.length && !lines[end].includes('"""')) end += 1;
    if (end >= lines.length) process.exit(2);
    lines.splice(rootIndex, end - rootIndex + 1, replacement);
  } else {
    lines[rootIndex] = replacement;
  }
}
fs.writeFileSync(destination, lines.join("\n"));
NODE
}

fm_treehouse_root_prepare_runpod_boot() {
  local config_dir="$FM_ACCOUNT_HOME/.config/treehouse" config tmp local_root volume_root
  case "$FM_TREEHOUSE_LOCAL_ROOT" in
    /*) ;;
    *) log "FATAL: the Treehouse pool root must be absolute"; return 1 ;;
  esac
  case "$FM_TREEHOUSE_LOCAL_ROOT" in
    "$FM_VOLUME"|"$FM_VOLUME"/*)
      log "FATAL: the Treehouse pool root must stay off the network volume"
      return 1
      ;;
  esac
  case "$FM_TREEHOUSE_LOCAL_ROOT" in
    *[\"\\]*)
      log "FATAL: the Treehouse pool root contains unsupported characters"
      return 1
      ;;
  esac
  if printf '%s' "$FM_TREEHOUSE_LOCAL_ROOT" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    log "FATAL: the Treehouse pool root contains unsupported characters"
    return 1
  fi
  mkdir -p "$config_dir" "$FM_TREEHOUSE_LOCAL_ROOT" || return 1
  [ ! -L "$FM_TREEHOUSE_LOCAL_ROOT" ] || {
    log "FATAL: the Treehouse pool root must not be a symlink"
    return 1
  }
  local_root=$(cd "$FM_TREEHOUSE_LOCAL_ROOT" && pwd -P) || return 1
  [ "$local_root" = "$FM_TREEHOUSE_LOCAL_ROOT" ] || {
    log "FATAL: the Treehouse pool root has symlinked ancestors"
    return 1
  }
  volume_root=$(cd "$FM_VOLUME" && pwd -P) || return 1
  case "$local_root" in
    "$volume_root"|"$volume_root"/*)
      log "FATAL: the Treehouse pool root must stay off the network volume"
      return 1
      ;;
  esac
  local child
  for child in .treehouse .firstmate-config; do
    if [ ! -e "$FM_TREEHOUSE_LOCAL_ROOT/$child" ] && [ ! -L "$FM_TREEHOUSE_LOCAL_ROOT/$child" ]; then
      mkdir -- "$FM_TREEHOUSE_LOCAL_ROOT/$child" || return 1
    fi
    [ -d "$FM_TREEHOUSE_LOCAL_ROOT/$child" ] && [ ! -L "$FM_TREEHOUSE_LOCAL_ROOT/$child" ] \
      && [ "$(cd "$FM_TREEHOUSE_LOCAL_ROOT/$child" && pwd -P)" = "$FM_TREEHOUSE_LOCAL_ROOT/$child" ] || {
      log "FATAL: the Treehouse pool contains an unsafe managed directory"
      return 1
    }
  done
  config="$config_dir/config.toml"
  [ ! -L "$config" ] || {
    log "FATAL: the Treehouse user config is a symlink"
    return 1
  }
  tmp=$(mktemp "$config_dir/.config.toml.XXXXXX") || return 1
  {
    printf 'root = "%s"\n' "$FM_TREEHOUSE_LOCAL_ROOT"
    [ ! -f "$config" ] || awk '
      function is_root_key(line, first, rest, end, key, tail, quote) {
        sub(/^[[:space:]]*/, "", line)
        first = substr(line, 1, 1)
        quote = sprintf("%c", 39)
        if (first == "\"" || first == quote) {
          rest = substr(line, 2)
          end = index(rest, first)
          if (end == 0) return 0
          key = substr(rest, 1, end - 1)
          tail = substr(rest, end + 1)
          if (tail !~ /^[[:space:]]*=/) return 0
          if (first == "\"") {
            gsub(/\\u0072|\\U00000072/, "r", key)
            gsub(/\\u006[fF]|\\U0000006[fF]/, "o", key)
            gsub(/\\u0074|\\U00000074/, "t", key)
          }
          return key == "root"
        }
        if (line !~ /^[A-Za-z0-9_-]+[[:space:]]*=/) return 0
        key = line
        sub(/[[:space:]]*=.*/, "", key)
        return key == "root"
      }
      !is_root_key($0)
    ' "$config"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$config" || { rm -f -- "$tmp"; return 1; }
  log "configured Treehouse worktrees on local container storage"
}
