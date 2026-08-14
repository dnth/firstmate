#!/usr/bin/env bash
# Seed the durable Claude state required for unattended launches as root.
#
# Usage:
#   fm-claude-headless-setup.sh [--project <absolute-path>]
#
# Claude refuses --dangerously-skip-permissions as root unless IS_SANDBOX=1 is
# present at launch time.
# The caller owns that environment marker; this helper owns the matching
# onboarding, project-trust, bypass-confirmation, and attribution settings.
# Existing JSON keys are preserved, while the safety-critical values below are
# reconciled on every call so a replacement pod cannot regress them.
set -eu

PROJECT=
THEME=${FM_CLAUDE_HEADLESS_THEME:-dark}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) [ "$#" -ge 2 ] || usage; PROJECT=$2; shift 2 ;;
    -h|--help|help) usage ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required to prepare Claude's headless state"
[ -n "${HOME:-}" ] || die "HOME is required to prepare Claude's headless state"
[ -d "$HOME" ] && [ ! -L "$HOME" ] || die "Claude account home is unavailable or unsafe: $HOME"

if [ -n "$PROJECT" ]; then
  case "$PROJECT" in /*) ;; *) die "Claude project trust path must be absolute: $PROJECT" ;; esac
  [ -d "$PROJECT" ] && [ ! -L "$PROJECT" ] \
    || die "Claude project trust path is unavailable or unsafe: $PROJECT"
  PROJECT=$(cd "$PROJECT" && pwd -P) || die "Claude project trust path cannot be resolved: $PROJECT"
fi

STATE_FILE="$HOME/.claude.json"
SETTINGS_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
SETTINGS_FILE="$SETTINGS_DIR/settings.json"

safe_json_input() {  # <path>
  local path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || die "refusing unsafe Claude JSON path: $path"
    jq -e 'type == "object"' "$path" >/dev/null 2>&1 \
      || die "Claude JSON file is not an object: $path"
  else
    printf '{}\n'
  fi
}

write_state() {
  local tmp input
  mkdir -p "$HOME" || die "cannot prepare Claude account home"
  tmp=$(mktemp "$HOME/.claude.json.fm.XXXXXX") || die "cannot stage Claude onboarding state"
  if [ -f "$STATE_FILE" ]; then input=$STATE_FILE; else input=/dev/null; fi
  if [ "$input" = /dev/null ]; then
    safe_json_input "$STATE_FILE" > "$tmp.input" || { rm -f -- "$tmp" "$tmp.input"; exit 1; }
    input="$tmp.input"
  else
    safe_json_input "$STATE_FILE" >/dev/null
  fi
  if ! jq --arg theme "$THEME" --arg project "$PROJECT" '
    .hasCompletedOnboarding = true
    | .theme = (.theme // $theme)
    | if $project == "" then .
      elif ((.projects // {}) | type) != "object" then error("projects is not an object")
      else .projects = ((.projects // {}) + {
        ($project): (((.projects // {})[$project] // {}) + {
          hasTrustDialogAccepted: true,
          hasCompletedProjectOnboarding: true
        })
      })
      end
  ' "$input" > "$tmp"; then
    rm -f -- "$tmp" "$tmp.input"
    die "Claude onboarding state could not be reconciled"
  fi
  rm -f -- "$tmp.input"
  chmod 600 "$tmp" || { rm -f -- "$tmp"; die "Claude onboarding state could not be secured"; }
  mv -f -- "$tmp" "$STATE_FILE" || { rm -f -- "$tmp"; die "Claude onboarding state could not be published"; }
}

write_settings() {
  local tmp input
  if [ -e "$SETTINGS_DIR" ] || [ -L "$SETTINGS_DIR" ]; then
    [ -d "$SETTINGS_DIR" ] && [ ! -L "$SETTINGS_DIR" ] \
      || die "refusing unsafe Claude settings directory: $SETTINGS_DIR"
  else
    mkdir -p "$SETTINGS_DIR" || die "cannot create Claude settings directory"
  fi
  chmod 700 "$SETTINGS_DIR" 2>/dev/null || true
  tmp=$(mktemp "$SETTINGS_DIR/.settings.json.fm.XXXXXX") || die "cannot stage Claude settings"
  if [ -f "$SETTINGS_FILE" ]; then input=$SETTINGS_FILE; else input=/dev/null; fi
  if [ "$input" = /dev/null ]; then
    safe_json_input "$SETTINGS_FILE" > "$tmp.input" || { rm -f -- "$tmp" "$tmp.input"; exit 1; }
    input="$tmp.input"
  else
    safe_json_input "$SETTINGS_FILE" >/dev/null
  fi
  if ! jq '
    .skipDangerousModePermissionPrompt = true
    | if ((.attribution // {}) | type) != "object" then error("attribution is not an object")
      else .attribution = ((.attribution // {}) + {
        commit: "",
        pr: "",
        sessionUrl: false
      })
      end
  ' "$input" > "$tmp"; then
    rm -f -- "$tmp" "$tmp.input"
    die "Claude headless settings could not be reconciled"
  fi
  rm -f -- "$tmp.input"
  chmod 600 "$tmp" || { rm -f -- "$tmp"; die "Claude settings could not be secured"; }
  mv -f -- "$tmp" "$SETTINGS_FILE" || { rm -f -- "$tmp"; die "Claude settings could not be published"; }
}

write_state
write_settings
