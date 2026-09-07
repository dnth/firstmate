#!/usr/bin/env bash
# Install or remove Firstmate's guarded Devin crew turn-end hook.
#
# Devin reads native project-local hooks from <worktree>/.devin/config.local.json
# and expects the lifecycle map under its top-level "hooks" key.
# This helper owns that whole local file and refuses to overwrite any pre-existing content.
# The registered command points at one user-level Firstmate hook script under
# ${XDG_CONFIG_HOME:-$HOME/.config}/devin and a sibling private task registry.
#
# Usage:
#   fm-devin-turnend-hook.sh install <absolute-worktree>
#   fm-devin-turnend-hook.sh remove <absolute-worktree>
set -u

case "${1:-}" in
  install|remove) ACTION=$1 ;;
  -h|--help)
    sed -n '2,13{s/^# \{0,1\}//;p;}' "$0"
    exit 0
    ;;
  *) printf 'usage: %s install|remove <absolute-worktree>\n' "${0##*/}" >&2; exit 2 ;;
esac

WORKTREE=${2:-}
case "$WORKTREE" in
  /*) ;;
  *) printf 'fm-devin-turnend-hook: refused: worktree must be absolute.\n' >&2; exit 1 ;;
esac
[ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || {
  printf 'fm-devin-turnend-hook: refused: worktree is unavailable or unsafe: %s.\n' "$WORKTREE" >&2
  exit 1
}
[ -n "${HOME:-}" ] || { printf 'fm-devin-turnend-hook: refused: HOME is unset.\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || {
  printf 'fm-devin-turnend-hook: refused: jq is required.\n' >&2
  exit 1
}

DEVIN_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
case "$DEVIN_CONFIG_HOME" in
  /*) ;;
  *) printf 'fm-devin-turnend-hook: refused: Devin config home must be absolute.\n' >&2; exit 1 ;;
esac
DEVIN_HOME_DIR="$DEVIN_CONFIG_HOME/devin"
HOOK="$DEVIN_HOME_DIR/fm-turn-end.sh"
REGISTRY="$DEVIN_HOME_DIR/fm-turn-end.d"
PROJECT_CONFIG_DIR="$WORKTREE/.devin"
PROJECT_CONFIG="$PROJECT_CONFIG_DIR/config.local.json"
HOOK_COMMAND="bash \"$HOOK\""

expected_config() {
  jq -n --arg command "$HOOK_COMMAND" '{
    hooks: {
      Stop: [
        {
          matcher: "",
          hooks: [
            {type: "command", command: $command, timeout: 5}
          ]
        }
      ]
    }
  }'
}

config_is_owned() {
  [ -f "$PROJECT_CONFIG" ] && [ ! -L "$PROJECT_CONFIG" ] || return 1
  jq -e --arg command "$HOOK_COMMAND" '. == {
    hooks: {
      Stop: [
        {
          matcher: "",
          hooks: [
            {type: "command", command: $command, timeout: 5}
          ]
        }
      ]
    }
  }' "$PROJECT_CONFIG" >/dev/null 2>&1
}

if [ "$ACTION" = remove ]; then
  if [ -e "$PROJECT_CONFIG" ] || [ -L "$PROJECT_CONFIG" ]; then
    config_is_owned || {
      printf 'fm-devin-turnend-hook: refused: project-local config is not Firstmate-owned: %s.\n' "$PROJECT_CONFIG" >&2
      exit 1
    }
    rm -f -- "$PROJECT_CONFIG"
  fi
  exit 0
fi

if [ -e "$PROJECT_CONFIG" ] || [ -L "$PROJECT_CONFIG" ]; then
  config_is_owned || {
    printf 'fm-devin-turnend-hook: refused: project-local config already exists and is not Firstmate-owned: %s.\n' "$PROJECT_CONFIG" >&2
    exit 1
  }
fi
if [ -e "$PROJECT_CONFIG_DIR" ] || [ -L "$PROJECT_CONFIG_DIR" ]; then
  [ -d "$PROJECT_CONFIG_DIR" ] && [ ! -L "$PROJECT_CONFIG_DIR" ] || {
    printf 'fm-devin-turnend-hook: refused: project-local config directory is unsafe: %s.\n' "$PROJECT_CONFIG_DIR" >&2
    exit 1
  }
else
  mkdir -p -- "$PROJECT_CONFIG_DIR"
fi
if [ -e "$DEVIN_HOME_DIR" ] || [ -L "$DEVIN_HOME_DIR" ]; then
  [ -d "$DEVIN_HOME_DIR" ] && [ ! -L "$DEVIN_HOME_DIR" ] || {
    printf 'fm-devin-turnend-hook: refused: Devin config directory is unsafe: %s.\n' "$DEVIN_HOME_DIR" >&2
    exit 1
  }
else
  mkdir -p -- "$DEVIN_HOME_DIR"
fi
if [ -e "$REGISTRY" ] || [ -L "$REGISTRY" ]; then
  [ -d "$REGISTRY" ] && [ ! -L "$REGISTRY" ] || {
    printf 'fm-devin-turnend-hook: refused: registry directory is unsafe: %s.\n' "$REGISTRY" >&2
    exit 1
  }
else
  mkdir -p -- "$REGISTRY"
fi
chmod 700 "$DEVIN_HOME_DIR" "$REGISTRY" 2>/dev/null || true

hook_tmp=$(mktemp "$DEVIN_HOME_DIR/.fm-turn-end.sh.XXXXXXXX") || {
  printf 'fm-devin-turnend-hook: refused: could not stage the hook script.\n' >&2
  exit 1
}
cat > "$hook_tmp" <<'EOF'
#!/usr/bin/env bash
# Firstmate Devin crew turn-end hook. Managed by fm-devin-turnend-hook.sh.
# Every path is deliberately silent and exits zero.
set +e
exec >/dev/null 2>&1
payload=
IFS= read -r payload || [ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'select(.hook_event_name == "Stop")' <<< "$payload" >/dev/null 2>&1 || exit 0
workspace=${DEVIN_PROJECT_DIR:-}
if [ -z "$workspace" ]; then
  workspace=$(jq -er '(.cwd // .workspace) | strings | select(length > 0)' <<< "$payload" 2>/dev/null) || exit 0
fi
case "$workspace" in /*) ;; *) exit 0 ;; esac
pointer="$workspace/.fm-devin-turnend"
[ -f "$pointer" ] && [ ! -L "$pointer" ] || exit 0
first=
IFS= read -r -n 256 first < "$pointer" 2>/dev/null || [ -n "$first" ] || exit 0
case "$first" in token=*) token=${first#token=} ;; *) exit 0 ;; esac
case "$token" in fm.????????????) ;; *) exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
devin_config_home=${XDG_CONFIG_HOME:-${HOME:-}/.config}
case "$devin_config_home" in /*) ;; *) exit 0 ;; esac
registry="$devin_config_home/devin/fm-turn-end.d/$token"
[ -f "$registry" ] && [ ! -L "$registry" ] || exit 0
target= spawn_gen= signal= extra=
IFS= read -r target < "$registry" 2>/dev/null || exit 0
IFS= read -r spawn_gen < <(sed -n '2p' "$registry") || exit 0
IFS= read -r signal < <(sed -n '3p' "$registry") || exit 0
IFS= read -r extra < <(sed -n '4p' "$registry") || true
case "$target" in target=/*.turn-ended) target=${target#target=} ;; *) exit 0 ;; esac
case "$spawn_gen" in spawn_gen=*) spawn_gen=${spawn_gen#spawn_gen=} ;; *) exit 0 ;; esac
case "$signal" in signal=/*/bin/fm-turnend-signal.sh) signal=${signal#signal=} ;; *) exit 0 ;; esac
[ -z "$extra" ] || exit 0
state=${target%/*}
name=${target##*/}
id=${name%.turn-ended}
"$signal" "$state" "$id" "$spawn_gen" || true
exit 0
EOF
chmod 700 "$hook_tmp"
if [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
  if [ ! -f "$HOOK" ] || [ -L "$HOOK" ] || ! cmp -s "$hook_tmp" "$HOOK"; then
    rm -f -- "$hook_tmp"
    printf 'fm-devin-turnend-hook: refused: hook path has non-Firstmate content: %s.\n' "$HOOK" >&2
    exit 1
  fi
fi
mv -f -- "$hook_tmp" "$HOOK"

tmp=$(mktemp "$PROJECT_CONFIG_DIR/.config.local.json.fm.XXXXXXXX") || {
  printf 'fm-devin-turnend-hook: refused: could not stage project-local config.\n' >&2
  exit 1
}
if ! expected_config > "$tmp"; then
  rm -f -- "$tmp"
  printf 'fm-devin-turnend-hook: refused: could not render project-local config.\n' >&2
  exit 1
fi
chmod 600 "$tmp"
mv -f -- "$tmp" "$PROJECT_CONFIG"
