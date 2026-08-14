# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.

FM_QUOTA_AXI_MIN=0.1.17

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    if command -v timeout >/dev/null 2>&1; then
      output=$(timeout "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
    elif command -v gtimeout >/dev/null 2>&1; then
      output=$(gtimeout "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
    elif command -v perl >/dev/null 2>&1; then
      output=$(perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
    else
      return 1
    fi
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

# Map a provider identifier to quota-axi's provider family.
fm_quota_provider_family() {
  local prefix=$1
  case "$prefix" in
    anthropic|claude) printf '%s\n' claude ;;
    openai|openai-codex|codex) printf '%s\n' codex ;;
    grok|xai) printf '%s\n' grok ;;
    kimi|kimi-coding|moonshot) printf '%s\n' kimi ;;
    *) printf '%s\n' "$prefix" ;;
  esac
}

# Resolve the provider family from the complete launch profile. Standalone
# harnesses own their aliases; multi-provider harnesses require a qualified
# model and otherwise remain unresolved.
fm_quota_provider_for_profile() {
  local harness=$1 model=$2 prefix
  case "$harness" in
    claude) printf '%s\n' claude; return 0 ;;
    codex) printf '%s\n' codex; return 0 ;;
    grok) printf '%s\n' grok; return 0 ;;
    kimi) printf '%s\n' kimi; return 0 ;;
  esac
  case "$model" in
    */*) prefix=${model%%/*} ;;
    *) return 0 ;;
  esac
  fm_quota_provider_family "$prefix"
}

# Print the quota-axi authentication sources used by a profile when that
# credential surface is known. No output means source-level status is unresolved.
fm_quota_auth_sources_for_profile() {
  local harness=$1 model=$2 provider
  provider=$(fm_quota_provider_for_profile "$harness" "$model")
  case "$harness:$provider" in
    claude:claude) printf '%s\n' oauth-file keychain ;;
    codex:codex) printf '%s\n' auth-json cli-rpc ;;
    grok:grok) printf '%s\n' auth-json ;;
    kimi:kimi) printf '%s\n' kimi-code-cli ;;
    pi:grok|pi-signed:grok) printf '%s\n' pi:xai ;;
    pi:kimi|pi-signed:kimi) printf '%s\n' pi:kimi-coding ;;
    pi:codex|pi-signed:codex) printf '%s\n' auth-json cli-rpc ;;
  esac
}

# Print the predictive configured-profile fallback reason for <harness> <model>, or nothing when
# quota data is missing, unresolved, usable, or otherwise cannot prove a trigger.
fm_quota_profile_fallback_reason() {
  local harness=$1 model=$2 provider sources auth_json auth_reason json
  provider=$(fm_quota_provider_for_profile "$harness" "$model")
  [ -n "$provider" ] || return 0
  command -v quota-axi >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  sources=$(fm_quota_auth_sources_for_profile "$harness" "$model")
  if [ -n "$sources" ]; then
    auth_json=$(quota-axi auth --json 2>/dev/null || true)
    auth_reason=$(printf '%s\n' "$auth_json" | jq -r \
      --arg provider "$provider" \
      --arg sources "$sources" '
        def unusable:
          . == "auth_required" or
          . == "unavailable" or
          . == "error" or
          . == "expired" or
          . == "missing";
        (if type == "array" then . else (.auth // []) end)
        | map(select(.provider == $provider))
        | [.[].sources[]? | select(.source as $source | ($sources | split("\n") | index($source)) != null)] as $matched
        | if ($matched | length) == 0 or any($matched[]; .status == "available") then
            empty
          elif all($matched[]; (.status | unusable)) then
            "provider_unavailable"
          else
            empty
          end
      ' 2>/dev/null || true)
    [ "$auth_reason" != provider_unavailable ] || {
      printf '%s\n' "$auth_reason"
      return 0
    }
  fi
  json=$(quota-axi --provider "$provider" --json 2>/dev/null) || return 0
  printf '%s\n' "$json" | jq -r \
    --arg provider "$provider" \
    --arg model "$model" '
      def unusable:
        . == "auth_required" or
        . == "unavailable" or
        . == "error" or
        . == "expired";
      def numeric:
        if type == "number" then .
        elif type == "string" then (tonumber? // empty)
        else empty
        end;
      .providers[]?
      | select(.provider == $provider)
      | if ([
          .status?,
          .authStatus?,
          .state.status?,
          .state.authStatus?,
          .auth.status?
        ] | any(.[]; unusable)) then
          "provider_unavailable"
        else
          (.quotaSemantics.effectiveAvailability // .effectiveAvailability // []) as $effective
          | ([ $effective[]?
                | select(.scope == ("model:" + $model)
                         or .scope == ("model:" + ($model | split("/")[-1])))
              ]) as $model_scope
          | (if ($model_scope | length) > 0
             then $model_scope
             else [ $effective[]? | select(.scope == "all_models") ]
             end) as $scope
          | [ $scope[]?.effectivePercentRemaining? | numeric ] as $headroom
          | if any($headroom[]; . <= 0) then
              "quota_exhausted"
            else
              empty
            end
        end
    ' 2>/dev/null
}

fm_quota_secondmate_fallback_reason() {
  fm_quota_profile_fallback_reason "$@"
}
