#!/usr/bin/env bash
# Install or remove Firstmate's guarded Devin crew turn-end hook.
set -u
case "${1:-}" in install|remove) ACTION=$1 ;; *) printf 'usage: %s install|remove\n' "${0##*/}" >&2; exit 2 ;; esac
[ -n "${HOME:-}" ] || { printf 'fm-devin-turnend-hook: refused: HOME is unset.\n' >&2; exit 1; }
HOOK_DIR="${DEVIN_HOME:-$HOME/.devin}/hooks"
HOOK="$HOOK_DIR/fm-turn-end.sh"
CONFIG="$HOOK_DIR/fm-turn-end.json"
if [ "$ACTION" = remove ]; then rm -f -- "$HOOK" "$CONFIG"; exit 0; fi
mkdir -p -- "$HOOK_DIR"
cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
set -u
exec >/dev/null 2>&1
payload=; IFS= read -r payload || [ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
workspace=$(jq -er 'select(.hook_event_name == "Stop") | (.cwd // .workspace // .DEVIN_PROJECT_DIR) | strings | select(length > 0)' <<<"$payload" 2>/dev/null) || exit 0
p="$workspace/.fm-devin-turnend"; [ -f "$p" ] || exit 0
first=; IFS= read -r -n 256 first <"$p" 2>/dev/null || [ -n "$first" ] || exit 0
case "$first" in token=*) token=${first#token=} ;; *) exit 0 ;; esac
case "$token" in fm.????????????) ;; *) exit 0 ;; esac
case "$token" in *[!A-Za-z0-9._-]*) exit 0 ;; esac
registry="${HOME:-}/.devin/hooks/fm-turn-end.d/$token"
target= spawn_gen= signal= extra=
IFS= read -r target <"$registry" 2>/dev/null || exit 0
IFS= read -r spawn_gen < <(sed -n '2p' "$registry") || exit 0
IFS= read -r signal < <(sed -n '3p' "$registry") || exit 0
IFS= read -r extra < <(sed -n '4p' "$registry") || true
case "$target" in target=/*.turn-ended) target=${target#target=} ;; *) exit 0 ;; esac
case "$spawn_gen" in spawn_gen=*) spawn_gen=${spawn_gen#spawn_gen=} ;; *) exit 0 ;; esac
case "$signal" in signal=/*/bin/fm-turnend-signal.sh) signal=${signal#signal=} ;; *) exit 0 ;; esac
[ -z "$extra" ] || exit 0
state=${target%/*}; name=${target##*/}; id=${name%.turn-ended}
"$signal" "$state" "$id" "$spawn_gen" || true
EOF
chmod 700 "$HOOK"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash \\\"%s\\\""}]}]}}\n' "$HOOK" > "$CONFIG"
