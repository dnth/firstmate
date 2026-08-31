#!/usr/bin/env bash
# Host-local lifecycle control for the remote secondmate home selected by fm-on.
#
# Usage:
#   fm-remote-secondmate-control.sh launch <id> <harness> <model|-> <effort|-> herdr <fallback-harness|-> <fallback-model|-> <fallback-effort|-> [traceparent]
#   fm-remote-secondmate-control.sh state <id>
#   fm-remote-secondmate-control.sh beacon-age <id>
#   fm-remote-secondmate-control.sh route <id>
#   fm-remote-secondmate-control.sh send <id> <message>
#   fm-remote-secondmate-control.sh key <id> <key>
#   fm-remote-secondmate-control.sh capture <id> [lines]
#   fm-remote-secondmate-control.sh observe <id>
#   fm-remote-secondmate-control.sh children <id>
#   fm-remote-secondmate-control.sh sleep-reconcile <id>
#   fm-remote-secondmate-control.sh runpod-crews <id>
#   fm-remote-secondmate-control.sh sync <id>
#   fm-remote-secondmate-control.sh update <id>
#   fm-remote-secondmate-control.sh retire <id> [--force]
#
# Remote placement ends here, but the second-mate agent always runs on the
# Herdr backend in the dedicated fm-remote session, so launch refuses any other
# selection rather than reading this home's config/backend. The interactive
# default session remains for the user's work.
# fm-spawn/fm-send/fm-teardown keep owning the local endpoint mechanics.
# The home's own workers keep their ordinary backend selection.
# bin/fm-remote-doctor.sh owns that host's readiness for Herdr.
# Remote OMP text delivery reselects the exact endpoint task, writes only that
# task's canonical inbox, and requires the loaded primary extension to send its
# programmatic doorbell with a bound turn-start marker. Exit 6 means that durable
# inbox record could not notify an unavailable extension, 7 that its request
# acknowledgement is ambiguous, 8 that no bound turn started, and 9 that an
# exact home, task, session, extension, or process binding refused before
# notification. Every nonzero result names a no-resend state.
# docs/remote-secondmates.md owns why.
# A private parent-route state directory stores only the remote secondmate
# agent's endpoint record; the home's own
# state/*.meta remains reserved for workers the secondmate supervises.
# Retirement closes only this secondmate's panes or workspace and never
# stops fm-remote or removes a sibling secondmate's workspace or panes.
#
# The optional launch traceparent is the per-task W3C trace-context carrier the
# PARENT home resolved for this secondmate; this host only delivers it to the
# pane, and fm-spawn validates it (bin/fm-trace-context-lib.sh). Omitting it is
# the default-off path. print_route echoes the carrier the endpoint actually
# holds, including for an already-alive endpoint that was not relaunched, so the
# parent records the identity the agent really received rather than an intent.
# On a RunPod host, launch also supplies the workstation auth-broker URL and a
# mode-600 bearer-file path to fm-spawn.
# fm-spawn expands that file only inside an OMP pane's launch command, so bearer
# bytes never enter this control command's argv, output, metadata, or logs.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_HOME=${FM_HOME:?FM_HOME is required}
CONTROL_STATE="$TARGET_HOME/state/parent-route"
CONTROL_DATA="$TARGET_HOME/data/.parent-route"
REMOTE_HERDR_SESSION=fm-remote
FM_RUNPOD_SANDBOX_MARKER=${FM_RUNPOD_SANDBOX_MARKER:-/workspace/persistent-runtime/runpod-root-sandbox}
FM_RUNPOD_OMP_AUTH_BROKER_TOKEN_FILE=${FM_RUNPOD_OMP_AUTH_BROKER_TOKEN_FILE:-/workspace/persistent-runtime/omp-auth-broker.token}
FM_RUNPOD_OMP_AUTH_BROKER_URL=${FM_RUNPOD_OMP_AUTH_BROKER_URL:-http://127.0.0.1:8765}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-primary-watch-version-lib.sh
. "$SCRIPT_DIR/fm-primary-watch-version-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
validate_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $1" ;; esac; }

mode_600() {
  if [ "$(uname)" = Darwin ]; then
    [ "$(stat -f %Lp "$1" 2>/dev/null || true)" = 600 ]
  else
    [ "$(stat -c %a "$1" 2>/dev/null || true)" = 600 ]
  fi
}

configure_runpod_omp_auth_launch() {
  local token port
  [ -f "$FM_RUNPOD_SANDBOX_MARKER" ] && [ ! -L "$FM_RUNPOD_SANDBOX_MARKER" ] || return 0
  if [ ! -f "$FM_RUNPOD_OMP_AUTH_BROKER_TOKEN_FILE" ] \
     || [ -L "$FM_RUNPOD_OMP_AUTH_BROKER_TOKEN_FILE" ] \
     || ! mode_600 "$FM_RUNPOD_OMP_AUTH_BROKER_TOKEN_FILE"; then
    die "RunPod omp auth-broker token is missing, unsafe, or not mode 0600"
  fi
  token=$(cat "$FM_RUNPOD_OMP_AUTH_BROKER_TOKEN_FILE") || die "RunPod omp auth-broker token is unreadable"
  [ -n "$token" ] && [ "${#token}" -le 512 ] || die "RunPod omp auth-broker token is invalid"
  case "$token" in *[!A-Za-z0-9_-]*) die "RunPod omp auth-broker token is invalid" ;; esac
  case "$FM_RUNPOD_OMP_AUTH_BROKER_URL" in http://127.0.0.1:[0-9]*|http://localhost:[0-9]*) ;;
    *) die "RunPod omp auth-broker URL must be a loopback HTTP endpoint" ;;
  esac
  port=${FM_RUNPOD_OMP_AUTH_BROKER_URL##*:}
  case "$port" in ''|*[!0-9]*) die "RunPod omp auth-broker URL has an invalid port" ;; esac
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "RunPod omp auth-broker URL has an invalid port"
  FM_OMP_AUTH_BROKER_URL=$FM_RUNPOD_OMP_AUTH_BROKER_URL
  FM_OMP_AUTH_BROKER_TOKEN_FILE=$FM_RUNPOD_OMP_AUTH_BROKER_TOKEN_FILE
  export FM_OMP_AUTH_BROKER_URL FM_OMP_AUTH_BROKER_TOKEN_FILE
}

validate_home() { # <id> [allow-absent]
  local id=$1 allow_absent=${2:-no} marker
  if [ ! -e "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] && [ "$allow_absent" = yes ]; then return 2; fi
  [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "remote secondmate home is unavailable or unsafe"
  [ -f "$TARGET_HOME/.fm-secondmate-home" ] && [ ! -L "$TARGET_HOME/.fm-secondmate-home" ] \
    || die "remote home is not a seeded secondmate home"
  marker=$(cat "$TARGET_HOME/.fm-secondmate-home")
  [ "$marker" = "$id" ] || die "remote home belongs to $marker, not $id"
  [ -f "$TARGET_HOME/AGENTS.md" ] && [ -d "$TARGET_HOME/bin" ] || die "remote home is not a Firstmate checkout"
}

meta_path() { printf '%s/%s.meta\n' "$CONTROL_STATE" "$1"; }

remote_endpoint_load() {
  local id=$1 herdr_session
  REMOTE_ENDPOINT_ERROR=
  REMOTE_ENDPOINT_META=$(meta_path "$id")
  if ! fm_backend_validate_task_endpoint "$REMOTE_ENDPOINT_META" "$id" 2>/dev/null; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint metadata is invalid; refusing access until it is explicitly migrated"
    return 1
  fi
  REMOTE_ENDPOINT_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  REMOTE_ENDPOINT_TARGET=$FM_BACKEND_VALIDATED_TARGET
  if [ "$REMOTE_ENDPOINT_BACKEND" != herdr ]; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded on backend '$REMOTE_ENDPOINT_BACKEND', expected 'herdr'; refusing access until it is explicitly migrated"
    return 1
  fi
  herdr_session=$(fm_backend_meta_exact_value "$REMOTE_ENDPOINT_META" herdr_session 2>/dev/null || true)
  if [ "$herdr_session" != "$REMOTE_HERDR_SESSION" ]; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded in Herdr session '${herdr_session:-missing}', expected '$REMOTE_HERDR_SESSION'; refusing access until it is explicitly migrated"
    return 1
  fi
  case "$REMOTE_ENDPOINT_TARGET" in
    "$REMOTE_HERDR_SESSION":?*) ;;
    *)
      REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint target '$REMOTE_ENDPOINT_TARGET' is outside Herdr session '$REMOTE_HERDR_SESSION'; refusing access until it is explicitly migrated"
      return 1
      ;;
  esac
}

remote_endpoint_require() {
  remote_endpoint_load "$1" || die "$REMOTE_ENDPOINT_ERROR"
}

remote_omp_delivery_refuse() { # <reason>
  printf 'error: remote-omp-binding-refused: %s; no remote notification was sent; do not resend\n' "$1" >&2
  exit 9
}

remote_omp_delivery_binding() { # <id>
  local id=$1 harness session_dir session_dir_real pointer session session_parent
  local primary_marker doorbell_marker expected_version path
  harness=$(fm_meta_get "$REMOTE_ENDPOINT_META" harness)
  [ "$harness" = omp ] || remote_omp_delivery_refuse "endpoint harness is '$harness', not omp"
  [ "$(fm_meta_get "$REMOTE_ENDPOINT_META" kind)" = secondmate ] \
    || remote_omp_delivery_refuse "endpoint metadata is not a persistent secondmate"
  fm_backend_agent_record_identity "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$REMOTE_ENDPOINT_META" \
    || remote_omp_delivery_refuse "endpoint task or OMP launch identity is stale or malformed"

  for path in \
    .omp/extensions/fm-primary-omp.ts \
    .omp/extensions/lib/fm-branch-dispatch.ts \
    .omp/extensions/lib/fm-task-inbox-doorbell.ts \
    bin/fm-primary-watch-core.ts; do
    if ! { [ -f "$TARGET_HOME/$path" ] && [ ! -L "$TARGET_HOME/$path" ] \
      && [ -f "$FM_ROOT/$path" ] && [ ! -L "$FM_ROOT/$path" ] \
      && cmp -s "$TARGET_HOME/$path" "$FM_ROOT/$path"; }; then
      remote_omp_delivery_refuse "loaded OMP extension closure differs from the remote tracked code"
    fi
  done

  session_dir="$TARGET_HOME/state/omp-sessions"
  pointer="$TARGET_HOME/state/.omp-session"
  [ -d "$session_dir" ] && [ ! -L "$session_dir" ] \
    || remote_omp_delivery_refuse "OMP session directory is unavailable or unsafe"
  session_dir_real=$(cd "$session_dir" && pwd -P) \
    || remote_omp_delivery_refuse "OMP session directory cannot be resolved"
  [ -f "$pointer" ] && [ ! -L "$pointer" ] \
    && [ "$(wc -l < "$pointer" 2>/dev/null | tr -d '[:space:]')" = 1 ] \
    || remote_omp_delivery_refuse "OMP session pointer is unavailable or malformed"
  IFS= read -r session < "$pointer" || session=
  case "$session" in "$session_dir_real"/*.jsonl) ;; *)
    remote_omp_delivery_refuse "OMP session pointer is outside the exact secondmate session directory"
    ;;
  esac
  session_parent=$(cd "$(dirname "$session")" 2>/dev/null && pwd -P || true)
  [ "$session_parent" = "$session_dir_real" ] && [ -f "$session" ] && [ ! -L "$session" ] \
    || remote_omp_delivery_refuse "OMP session pointer does not bind one regular direct-child session"

  expected_version=$(fm_primary_watch_version "$TARGET_HOME/.omp/extensions/fm-primary-omp.ts" "$TARGET_HOME") \
    || remote_omp_delivery_refuse "OMP primary extension version cannot be verified"
  primary_marker="$TARGET_HOME/state/.omp-primary-extension-loaded"
  fm_omp_primary_marker_read "$primary_marker" \
    || remote_omp_delivery_refuse "OMP primary extension readiness is unavailable or malformed"
  [ "$FM_OMP_MARKER_VERSION" = "$expected_version" ] \
    || remote_omp_delivery_refuse "loaded OMP primary extension does not match its tracked closure"
  [ "$FM_OMP_MARKER_BUN" = "$(fm_meta_get "$REMOTE_ENDPOINT_META" omp_bun)" ] \
    && [ "$FM_OMP_MARKER_BIN" = "$(fm_meta_get "$REMOTE_ENDPOINT_META" omp_bin)" ] \
    || remote_omp_delivery_refuse "loaded OMP primary extension does not match the endpoint launch identity"

  doorbell_marker="$CONTROL_STATE/$id.omp-doorbell-ready"
  fm_omp_task_doorbell_marker_read "$doorbell_marker" \
    || remote_omp_delivery_refuse "OMP task doorbell extension is inactive"
  [ "$FM_OMP_TASK_DOORBELL_PID" = "$FM_OMP_MARKER_PID" ] \
    || remote_omp_delivery_refuse "OMP task doorbell and primary extension belong to different process instances"
}

state_value() { # <id>; prints recovery-grade state
  local id=$1 meta
  meta=$(meta_path "$id")
  [ -f "$meta" ] && [ ! -L "$meta" ] || { printf 'missing\n'; return 0; }
  if ! remote_endpoint_load "$id"; then
    printf 'error: %s\n' "$REMOTE_ENDPOINT_ERROR" >&2
    printf 'unverified\n'
    return 0
  fi
  fm_backend_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable\n'
}

beacon_age() {
  local id=$1 beat mtime now
  validate_id "$id"
  validate_home "$id"
  beat="$TARGET_HOME/state/.last-watcher-beat"
  [ -f "$beat" ] && [ ! -L "$beat" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$beat" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$beat" 2>/dev/null) || return 1
  fi
  now=$(date +%s)
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  [ "$mtime" -le "$now" ] || return 1
  printf '%s\n' "$((now - mtime))"
}

print_route() { # <id>
  local id=$1 harness model effort model_source fallback_reason traceparent
  remote_endpoint_require "$id"
  harness=$(fm_meta_get "$REMOTE_ENDPOINT_META" harness)
  model=$(fm_meta_get "$REMOTE_ENDPOINT_META" model)
  effort=$(fm_meta_get "$REMOTE_ENDPOINT_META" effort)
  model_source=$(fm_meta_get "$REMOTE_ENDPOINT_META" secondmate_model_source)
  fallback_reason=$(fm_meta_get "$REMOTE_ENDPOINT_META" secondmate_fallback_reason)
  traceparent=$(fm_meta_get "$REMOTE_ENDPOINT_META" traceparent)
  printf 'schema=fm-remote-secondmate-control.v1\n'
  printf 'backend=%s\n' "$REMOTE_ENDPOINT_BACKEND"
  printf 'target=%s\n' "$REMOTE_ENDPOINT_TARGET"
  printf 'herdr_session=%s\n' "$REMOTE_HERDR_SESSION"
  printf 'harness=%s\n' "$harness"
  printf 'model=%s\n' "$model"
  printf 'effort=%s\n' "$effort"
  [ -z "$model_source" ] || printf 'secondmate_model_source=%s\n' "$model_source"
  [ -z "$fallback_reason" ] || printf 'secondmate_fallback_reason=%s\n' "$fallback_reason"
  [ -z "$traceparent" ] || printf 'traceparent=%s\n' "$traceparent"
}

cmd_route() {
  local id=$1 meta
  validate_id "$id"
  validate_home "$id"
  meta=$(meta_path "$id")
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    die "remote secondmate has no endpoint metadata"
  fi
  print_route "$id"
}

cmd_launch() {
  local id=$1 harness=$2 model=$3 effort=$4 selected_backend=$5
  local fallback_harness=$6 fallback_model=$7 fallback_effort=$8 traceparent=${9:-}
  local current meta out herdr_session reason model_source tmp

  validate_id "$id"
  validate_home "$id"
  case "$harness" in omp|claude|codex|opencode|pi|pi-signed|grok|kimi) ;; *) die "unverified remote secondmate harness: $harness" ;; esac
  case "$effort" in -|low|medium|high|xhigh|max) ;; *) die "invalid remote secondmate effort: $effort" ;; esac
  case "$fallback_harness" in -|omp|claude|codex|opencode|pi|pi-signed|grok|kimi) ;; *) die "unverified remote secondmate fallback harness: $fallback_harness" ;; esac
  case "$fallback_effort" in -|low|medium|high|xhigh|max) ;; *) die "invalid remote secondmate fallback effort: $fallback_effort" ;; esac
  # Herdr is required on this host, not merely preferred: its server belongs to
  # the Aqua login session on macOS or runs headlessly in the account runtime on
  # Linux, so the endpoint survives every SSH disconnection that a remote route
  # depends on. bin/fm-remote-doctor.sh is the readiness owner.
  case "$selected_backend" in herdr) ;; *) die "a remote secondmate runs only on the herdr backend, not '$selected_backend'" ;; esac
  mkdir -p "$CONTROL_STATE" "$CONTROL_DATA"
  meta=$(meta_path "$id")
  if [ -f "$meta" ]; then
    remote_endpoint_require "$id"
    current=$(fm_backend_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable\n')
    case "$current" in
      alive)
        print_route "$id"
        return 0
        ;;
      dead)
        fm_backend_kill "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null \
          || die "could not remove the confirmed agent-less endpoint"
        ;;
      missing) ;;
      *) die "remote endpoint state is $current; refusing duplicate launch" ;;
    esac
  fi
  model_source=
  reason=
  if [ "$fallback_harness" != - ]; then
    model_source=primary
    reason=$(fm_quota_secondmate_fallback_reason "$harness" "${model#-}" || true)
    case "$reason" in
      provider_unavailable|quota_exhausted)
        harness=$fallback_harness
        model=$fallback_model
        effort=$fallback_effort
        model_source=fallback
        ;;
      *) reason= ;;
    esac
  fi
  ARGS=("$id" "$TARGET_HOME" --secondmate --harness "$harness" --backend "$selected_backend")
  [ "$model" = - ] || ARGS+=(--model "$model")
  [ "$effort" = - ] || ARGS+=(--effort "$effort")
  [ -z "$traceparent" ] || ARGS+=(--traceparent "$traceparent")
  configure_runpod_omp_auth_launch
  if ! out=$(HERDR_SESSION="$REMOTE_HERDR_SESSION" FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_SKIP_SECONDMATE_INHERIT=1 \
    "$SCRIPT_DIR/fm-spawn.sh" "${ARGS[@]}" 2>&1); then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    die "remote host-local secondmate launch failed"
  fi
  [ -f "$meta" ] || die "remote launch returned without endpoint metadata"
  herdr_session=$(fm_meta_get "$meta" herdr_session)
  [ "$herdr_session" = "$REMOTE_HERDR_SESSION" ] \
    || die "remote launch recorded Herdr session '${herdr_session:-missing}', expected '$REMOTE_HERDR_SESSION'"
  if [ -n "$model_source" ]; then
    tmp="$meta.tmp.$$"
    awk '$0 !~ /^secondmate_model_source=/ && $0 !~ /^secondmate_fallback_reason=/' "$meta" > "$tmp"
    printf 'secondmate_model_source=%s\n' "$model_source" >> "$tmp"
    [ "$model_source" != fallback ] || printf 'secondmate_fallback_reason=%s\n' "$reason" >> "$tmp"
    mv -f -- "$tmp" "$meta"
  fi
  print_route "$id"
}

cmd_send() {
  local id=$1 message=$2 harness relay_body
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  harness=$(fm_meta_get "$REMOTE_ENDPOINT_META" harness)
  if [ "$harness" = omp ]; then
    fm_message_from_firstmate "$message" \
      || remote_omp_delivery_refuse "relay request lacks the parent-owned from-firstmate carrier"
    fm_operational_input_body "$message" relay_body \
      || remote_omp_delivery_refuse "relay request carrier cannot be parsed"
    if [[ "$relay_body" =~ ^corr=[[:xdigit:]]{16}[[:space:]]+(/.*)$ ]]; then
      relay_body=${BASH_REMATCH[1]}
    fi
    if [[ "$relay_body" = /* ]]; then
      # Slash commands retain the pre-inbox typed control path. In particular,
      # /exit must not be converted into a durable ordinary-text steer or carry
      # secondmate correlation syntax into the harness command parser.
      FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
        "$SCRIPT_DIR/fm-send.sh" "$REMOTE_ENDPOINT_TARGET" "$relay_body"
      return
    fi
    remote_omp_delivery_binding "$id"
    FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$CONTROL_STATE" \
      FM_DATA_OVERRIDE="$CONTROL_DATA" FM_SEND_PRESERVE_INBOUND_FROM_FIRSTMATE=1 \
      FM_TASK_INBOX_OMP_REQUIRE_PROGRAMMATIC=1 FM_SEND_OMP_INBOX_REQUIRE_TURN_START=1 \
      "$SCRIPT_DIR/fm-send.sh" "$id" "$message"
  else
    FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
      "$SCRIPT_DIR/fm-send.sh" "$REMOTE_ENDPOINT_TARGET" "$message"
  fi
}

cmd_key() {
  local id=$1 key=$2
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
    "$SCRIPT_DIR/fm-send.sh" "$REMOTE_ENDPOINT_TARGET" --key "$key"
}

cmd_capture() {
  local id=$1 lines=${2:-20}
  validate_id "$id"
  validate_home "$id"
  case "$lines" in ''|*[!0-9]*|0) die "capture line count must be positive" ;; esac
  [ "$lines" -le 100 ] || die "capture line count exceeds 100"
  remote_endpoint_require "$id"
  fm_backend_capture "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$lines" "fm-$id" | head -c 65536
}

cmd_observe() {
  local id=$1 harness
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  harness=$(fm_meta_get "$REMOTE_ENDPOINT_META" harness)
  fm_pending_reply_backend_observation "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "fm-$id" "$harness"
  printf '\n'
}

# Read-only count of the work this home supervises, so a caller can ask whether
# the host is idle without retiring anything. It counts exactly what teardown's
# child sweep walks: the home's own state/*.meta records. The secondmate agent's
# own endpoint record lives under state/parent-route/ and is deliberately not
# one of them.
cmd_children() {
  local id=$1 meta count=0
  validate_id "$id"
  validate_home "$id"
  for meta in "$TARGET_HOME/state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    count=$((count + 1))
  done
  printf 'children=%s\n' "$count"
}

cmd_sleep_reconcile() {
  local id=$1 meta child mode kind state reconciled=0
  validate_id "$id"
  validate_home "$id"
  for meta in "$TARGET_HOME/state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    child=${meta##*/}
    child=${child%.meta}
    mode=$(fm_meta_get "$meta" mode)
    kind=$(fm_meta_get "$meta" kind)
    [ "$mode" = direct-PR ] && [ "$kind" = ship ] || continue
    state=$(FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$TARGET_HOME/state" FM_DATA_OVERRIDE="$TARGET_HOME/data" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$child" 2>/dev/null || true)
    case "$state" in
      'state: done'|'state: done '*) ;;
      *) continue ;;
    esac
    FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$TARGET_HOME/state" FM_DATA_OVERRIDE="$TARGET_HOME/data" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" \
      "$SCRIPT_DIR/fm-teardown.sh" "$child" >/dev/null \
      || die "finished direct-PR child $child could not be torn down safely"
    reconciled=$((reconciled + 1))
  done
  printf 'reconciled=%s\n' "$reconciled"
}

# RunPod's OMP OAuth callback is not usable in the current headless container,
# while Codex and Claude subscription authentication both survive on the
# durable account home.
# This provider-owned layer is applied after ordinary inherited configuration,
# so the secondmate agent remains on its separately selected harness but
# every crew dispatch has a working GPT route by default.
cmd_runpod_crews() {
  local id=$1 config harness_tmp fallback_tmp path
  validate_id "$id"
  validate_home "$id"
  config="$TARGET_HOME/config"
  if [ -e "$config" ] || [ -L "$config" ]; then
    [ -d "$config" ] && [ ! -L "$config" ] || die "remote config directory is unavailable or unsafe"
  else
    mkdir -p "$config" || die "remote config directory could not be created"
  fi
  for path in "$config/crew-harness" "$config/crew-harness-fallback" "$config/crew-dispatch.json"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ -f "$path" ] && [ ! -L "$path" ] || die "refusing unsafe RunPod crew-routing path: $path"
    fi
  done
  harness_tmp=$(mktemp "$config/.crew-harness.runpod.XXXXXX") \
    || die "RunPod crew harness could not be staged"
  fallback_tmp=$(mktemp "$config/.crew-harness-fallback.runpod.XXXXXX") \
    || { rm -f -- "$harness_tmp"; die "RunPod crew dispatch could not be staged"; }
  printf 'codex\n' > "$harness_tmp" || {
    rm -f -- "$harness_tmp" "$fallback_tmp"
    die "RunPod crew harness could not be written"
  }
  printf 'claude\n' > "$fallback_tmp" || {
      rm -f -- "$harness_tmp" "$fallback_tmp"
      die "RunPod crew fallback could not be written"
    }
  chmod 600 "$harness_tmp" "$fallback_tmp" || {
    rm -f -- "$harness_tmp" "$fallback_tmp"
    die "RunPod crew routing could not be secured"
  }
  mv -f -- "$harness_tmp" "$config/crew-harness" || {
    rm -f -- "$harness_tmp" "$fallback_tmp"
    die "RunPod crew harness could not be published"
  }
  mv -f -- "$fallback_tmp" "$config/crew-harness-fallback" || {
    rm -f -- "$fallback_tmp"
    die "RunPod crew fallback could not be published"
  }
  rm -f -- "$config/crew-dispatch.json" || die "RunPod crew dispatch override could not be retired"
  printf 'runpod-crews: codex default with claude fallback\n'
}

cmd_sync() {
  local id=$1 target dirty head current
  validate_id "$id"
  validate_home "$id"
  target=$TARGET_HOME
  dirty=$(git -C "$target" status --porcelain 2>/dev/null | awk '$0 != "?? .fm-secondmate-home" { print; exit }')
  [ -z "$dirty" ] || die "remote secondmate checkout is dirty; sync skipped"
  head=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null) || die "remote code root HEAD is unreadable"
  current=$(git -C "$target" rev-parse HEAD 2>/dev/null) || die "remote home HEAD is unreadable"
  if [ "$current" = "$head" ]; then
    printf 'current: %s\n' "$head"
    return 0
  fi
  if ! git -C "$target" cat-file -e "$head^{commit}" 2>/dev/null; then
    git -C "$target" fetch --quiet --no-tags "$FM_ROOT" "$head" \
      || die "remote home could not import the code-root commit"
  fi
  git -C "$target" cat-file -e "$head^{commit}" 2>/dev/null || die "remote home does not contain the code-root commit"
  git -C "$target" merge-base --is-ancestor HEAD "$head" || die "remote secondmate checkout is not a fast-forward"
  git -C "$target" checkout --detach -q "$head" || die "remote secondmate fast-forward failed"
  printf 'synced: %s\n' "$head"
}

cmd_update() {
  local id=$1 update_out root_status
  validate_id "$id"
  validate_home "$id"
  if ! update_out=$(FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-update.sh" 2>&1); then
    [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
    die "remote code root update failed"
  fi
  root_status=$(printf '%s\n' "$update_out" | grep '^firstmate:' | tail -1)
  case "$root_status" in
    'firstmate: updated '*|'firstmate: already current'*) ;;
    *)
      [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
      die "remote code root did not complete a safe origin update"
      ;;
  esac
  cmd_sync "$id"
}

cmd_retire() {
  local id=$1 force=${2:-} rc
  validate_id "$id"
  validate_home "$id" yes || rc=$?
  if [ "${rc:-0}" -eq 2 ]; then
    printf 'already-retired: %s\n' "$id"
    return 0
  fi
  [ -z "$force" ] || [ "$force" = --force ] || usage
  remote_endpoint_require "$id"
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" "$SCRIPT_DIR/fm-guard.sh" || true
  if [ -n "$force" ]; then
    FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/fm-teardown.sh" "$id" --force
  else
    FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/fm-teardown.sh" "$id"
  fi
}

case "${1:-}" in
  launch) shift; [ "$#" -ge 8 ] && [ "$#" -le 9 ] || usage; cmd_launch "$@" ;;
  state) shift; [ "$#" -eq 1 ] || usage; validate_id "$1"; validate_home "$1"; state_value "$1" ;;
  beacon-age) shift; [ "$#" -eq 1 ] || usage; beacon_age "$1" ;;
  route) shift; [ "$#" -eq 1 ] || usage; cmd_route "$1" ;;
  send) shift; [ "$#" -eq 2 ] || usage; cmd_send "$@" ;;
  key) shift; [ "$#" -eq 2 ] || usage; cmd_key "$@" ;;
  capture) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_capture "$@" ;;
  observe) shift; [ "$#" -eq 1 ] || usage; cmd_observe "$@" ;;
  children) shift; [ "$#" -eq 1 ] || usage; cmd_children "$@" ;;
  sleep-reconcile) shift; [ "$#" -eq 1 ] || usage; cmd_sleep_reconcile "$@" ;;
  runpod-crews) shift; [ "$#" -eq 1 ] || usage; cmd_runpod_crews "$@" ;;
  sync) shift; [ "$#" -eq 1 ] || usage; cmd_sync "$@" ;;
  update) shift; [ "$#" -eq 1 ] || usage; cmd_update "$@" ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
