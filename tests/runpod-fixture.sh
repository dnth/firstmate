#!/usr/bin/env bash
# tests/runpod-fixture.sh - the deterministic mocked RunPod boundary.
#
# bin/fm-runpod.sh reaches RunPod through exactly one seam: a curl invocation
# driven by a generated config file. This fixture replaces that curl with a
# stateful fake that serves the same REST shapes the published API documents,
# so the provider's real request bodies, status handling, and polling loops are
# exercised without an account, an API key, or a paid resource.
#
# It also fakes the two SSH-side tools wake depends on:
#   ssh-keyscan  - returns the host key that "lives on" the attached volume, so
#                  a replaced pod presents the SAME key and pinning survives.
#   ssh          - answers the readiness probe, and speaks fm-on.sh's transport
#                  shape so remote control calls can be answered or failed with
#                  a real SSH status 255.
#
# Everything is keyed off files under one fixture root, so parallel test files
# never share state.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# runpod_fixture_init <state-file>: start an empty RunPod account.
runpod_fixture_init() {
  printf '%s\n' '{"volumes":[],"pods":[],"seq":0,"hostkeys":{}}' > "$1"
}

# install_fake_runpod <fakebin> : drop the fake curl, ssh-keyscan, and ssh.
# The caller exports FM_FAKE_RUNPOD_STATE, FM_FAKE_RUNPOD_LOG, and optionally
# FM_FAKE_RUNPOD_INIT_POLLS, FM_FAKE_RUNPOD_FAIL, FM_FAKE_RUNPOD_UNREACHABLE,
# FM_FAKE_REMOTE_CHILDREN, and FM_FAKE_SSH_MODE.
install_fake_runpod() {
  local fakebin=$1

  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
# Stateful RunPod REST double. Reads the same generated curl config the provider
# writes, so the request method, URL, body, and bearer header are all real.
set -u
cfg=
while [ "$#" -gt 0 ]; do
  case "$1" in --config) shift; cfg=${1:-} ;; esac
  shift || break
done
[ -n "$cfg" ] && [ -f "$cfg" ] || { printf 'fake curl: no --config\n' >&2; exit 2; }

method=$(sed -n 's/^request = "\(.*\)"$/\1/p' "$cfg" | head -1)
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$cfg" | head -1)
bodyfile=$(sed -n 's/^data-binary = "@\(.*\)"$/\1/p' "$cfg" | head -1)
auth=$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p' "$cfg" | head -1)
connect_timeout=$(sed -n 's/^connect-timeout = "\{0,1\}\([^" ]*\)"\{0,1\}$/\1/p' "$cfg" | head -1)
total_timeout=$(sed -n 's/^max-time = "\{0,1\}\([^" ]*\)"\{0,1\}$/\1/p' "$cfg" | head -1)
path=${url#https://rest.runpod.io/v1}
printf '%s %s\n' "$method" "$path" >> "${FM_FAKE_RUNPOD_LOG:-/dev/null}"

if [ "${FM_FAKE_ENDPOINT_API_BLOCK:-0}" = 1 ]; then
  case "$method $path" in
    "GET /pods/"*)
      if [ -z "$connect_timeout" ] || [ -z "$total_timeout" ]; then
        sleep 10
        exit 28
      fi
      sleep "$total_timeout"
      exit 28
      ;;
  esac
fi
# An unreachable API is a curl transport failure, not an HTTP status.
[ -z "${FM_FAKE_RUNPOD_UNREACHABLE:-}" ] || { printf 'fake curl: could not resolve host\n' >&2; exit 6; }

emit() { printf '%s\n%s' "$1" "$2"; exit 0; }
[ -n "$auth" ] || emit '{"error":"missing bearer"}' 401

if [ -n "${FM_FAKE_RUNPOD_FAIL:-}" ]; then
  case "$method $path" in
    $FM_FAKE_RUNPOD_FAIL) emit '{"error":"injected failure"}' 500 ;;
  esac
fi

state=${FM_FAKE_RUNPOD_STATE:?}
lock="$state.lock"
tries=0
while ! mkdir "$lock" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 2000 ] || { printf 'fake curl: state lock timeout\n' >&2; exit 7; }
  sleep 0.01
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

body=
[ -z "$bodyfile" ] || body=$(cat "$bodyfile")
init_polls=${FM_FAKE_RUNPOD_INIT_POLLS:-0}

apply() {  # <jq-filter> [--argjson/--arg pairs...]
  local filter=$1
  shift
  jq "$@" "$filter" "$state" > "$state.next" && mv -f "$state.next" "$state"
}

case "$method $path" in
  "GET /networkvolumes")
    emit "$(jq -c '.volumes' "$state")" 200
    ;;
  "POST /networkvolumes")
    name=$(printf '%s' "$body" | jq -r '.name')
    size=$(printf '%s' "$body" | jq -r '.size')
    dc=$(printf '%s' "$body" | jq -r '.dataCenterId')
    apply '.seq += 1' || exit 7
    seq=$(jq -r '.seq' "$state")
    vol=$(jq -nc --arg id "vol-$seq" --arg n "$name" --argjson s "$size" --arg dc "$dc" \
      '{id:$id,name:$n,size:$s,dataCenterId:$dc}')
    apply '.volumes += [$v]' --argjson v "$vol" || exit 7
    emit "$vol" 200
    ;;
  "DELETE /networkvolumes/"*)
    vid=${path#/networkvolumes/}
    if [ "$(jq -r --arg v "$vid" '[.volumes[] | select(.id == $v)] | length' "$state")" = 0 ]; then
      emit '{"error":"not found"}' 404
    fi
    apply 'del(.volumes[] | select(.id == $v))' --arg v "$vid" || exit 7
    emit '{}' 200
    ;;
  "POST /pods")
    vol=$(printf '%s' "$body" | jq -r '.networkVolumeId // ""')
    compute=$(printf '%s' "$body" | jq -r '.computeType // "CPU"')
    name=$(printf '%s' "$body" | jq -r '.name // ""')
    boot=$(printf '%s' "$body" | jq -r '.env.FM_POD_BOOT_B64 // ""')
    if [ -n "$vol" ] && [ "$(jq -r --arg v "$vol" '[.volumes[] | select(.id == $v)] | length' "$state")" = 0 ]; then
      emit '{"error":"no such network volume"}' 400
    fi
    # One network volume can back at most one live pod.
    if [ -n "$vol" ] && [ "$(jq -r --arg v "$vol" '[.pods[] | select(.networkVolume.id == $v)] | length' "$state")" != 0 ]; then
      emit '{"error":"network volume is already attached to a running pod"}' 409
    fi
    apply '.seq += 1' || exit 7
    seq=$(jq -r '.seq' "$state")
    # The host key belongs to the VOLUME, so a replaced pod restores it.
    if [ -n "$vol" ] && [ "$(jq -r --arg v "$vol" '.hostkeys[$v] // ""' "$state")" = "" ]; then
      apply '.hostkeys[$v] = $k' --arg v "$vol" --arg k "AAAAC3NzaC1lZDI1NTE5AAAAI$(printf '%s' "$vol" | tr -c 'A-Za-z0-9' 'x')key" || exit 7
    fi
    cost=0.04
    [ "$compute" != GPU ] || cost=0.79
    gpus=$(printf '%s' "$body" | jq -c '.gpuTypeIds // []')
    pod=$(jq -nc --arg id "pod-$seq" --arg n "$name" --arg c "$compute" --arg b "$boot" \
      --argjson cost "$cost" --argjson polls "$init_polls" --argjson seq "$seq" \
      --argjson gpus "$gpus" \
      --argjson v "$(jq -c --arg v "$vol" '[.volumes[] | select(.id == $v)][0] // null' "$state")" \
      '{id:$id,name:$n,computeType:$c,desiredStatus:"RUNNING",costPerHr:$cost,
        lastStartedAt:"2026-08-12T00:00:00.000Z",bootScript:$b,requestedGpuTypeIds:$gpus,
        remainingInitPolls:$polls,seq:$seq,networkVolume:$v,
        publicIp:null,portMappings:null}')
    apply '.pods += [$p]' --argjson p "$pod" || exit 7
    emit "$pod" 201
    ;;
  "GET /pods/"*)
    pid=${path#/pods/}
    if [ "$(jq -r --arg p "$pid" '[.pods[] | select(.id == $p)] | length' "$state")" = 0 ]; then
      emit '{"error":"not found"}' 404
    fi
    # Model initialization: the endpoint appears only after the configured
    # number of polls, exactly as a real pod publishes no IP while booting.
    apply '(.pods[] | select(.id == $p) | .remainingInitPolls) |= (if . > 0 then . - 1 else 0 end)
           | (.pods[] | select(.id == $p)) |= (if .remainingInitPolls == 0
                then .publicIp = ("10.0.0." + (.seq | tostring))
                   | .portMappings = {"22": (20000 + .seq)}
                else . end)' --arg p "$pid" || exit 7
    emit "$(jq -c --arg p "$pid" '[.pods[] | select(.id == $p)][0]' "$state")" 200
    ;;
  "POST /pods/"*"/start")
    pid=${path#/pods/}
    pid=${pid%/start}
    apply '(.pods[] | select(.id == $p) | .desiredStatus) = "RUNNING"' --arg p "$pid" || exit 7
    emit "$(jq -c --arg p "$pid" '[.pods[] | select(.id == $p)][0]' "$state")" 200
    ;;
  "POST /pods/"*"/stop")
    pid=${path#/pods/}
    pid=${pid%/stop}
    apply '(.pods[] | select(.id == $p) | .desiredStatus) = "EXITED"' --arg p "$pid" || exit 7
    emit "$(jq -c --arg p "$pid" '[.pods[] | select(.id == $p)][0]' "$state")" 200
    ;;
  "DELETE /pods/"*)
    pid=${path#/pods/}
    if [ "$(jq -r --arg p "$pid" '[.pods[] | select(.id == $p)] | length' "$state")" = 0 ]; then
      emit '{"error":"not found"}' 404
    fi
    apply 'del(.pods[] | select(.id == $p))' --arg p "$pid" || exit 7
    emit '{}' 200
    ;;
esac
emit '{"error":"unrouted"}' 404
SH

  cat > "$fakebin/ssh-keyscan" <<'SH'
#!/usr/bin/env bash
# The scanned key is the ATTACHED VOLUME's key, so a replaced pod scans the same
# bytes and the pinned HostKeyAlias entry keeps verifying.
set -u
scan_timeout=20
port=
host=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -T) shift; scan_timeout=${1:-20} ;;
    -p) shift; port=${1:-} ;;
    *) host=$1 ;;
  esac
  shift || break
done
state=${FM_FAKE_RUNPOD_STATE:?}
if [ "${FM_FAKE_KEYSCAN_BLOCK:-0}" = 1 ]; then
  sleep "$scan_timeout"
  exit 1
fi
if [ -n "${FM_FAKE_KEYSCAN_ATTEMPTS:-}" ]; then
  attempts=$(cat "$FM_FAKE_KEYSCAN_ATTEMPTS" 2>/dev/null || printf '0')
  attempts=$((attempts + 1))
  printf '%s\n' "$attempts" > "$FM_FAKE_KEYSCAN_ATTEMPTS"
  [ "$attempts" -gt "${FM_FAKE_KEYSCAN_FAILS:-0}" ] || exit 1
fi
if [ -n "${FM_FAKE_KEYSCAN_BARRIER_DIR:-}" ]; then
  mkdir -p "$FM_FAKE_KEYSCAN_BARRIER_DIR"
  : > "$FM_FAKE_KEYSCAN_BARRIER_DIR/$host"
  while [ "$(find "$FM_FAKE_KEYSCAN_BARRIER_DIR" -type f | wc -l | tr -d ' ')" -lt 2 ]; do
    sleep 0.01
  done
fi
key=$(jq -r --arg h "$host" --argjson p "${port:-0}" \
  '(.pods[] | select(.publicIp == $h and (.portMappings["22"] == $p)) | .networkVolume.id) as $v
   | .hostkeys[$v] // ""' "$state" 2>/dev/null | head -1)
[ -n "$key" ] || exit 1
printf '%s ssh-ed25519 %s\n' "$host" "$key"
SH

  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
# Two roles: fm-runpod's readiness probe, and fm-on.sh's transport.
set -u
args=("$@")
transport=0
target_host=
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  if [ "${args[$i]}" = fm-remote-entrypoint.sh ]; then
    transport=1
    [ "$i" -eq 0 ] || target_host=${args[$((i - 1))]}
  fi
  i=$((i + 1))
done

if [ "$transport" -eq 0 ]; then
  # Readiness probe: SSH plus the boot script's successful handoff marker.
  conf=
  alias=
  readiness=0
  i=0
  connect_timeout=10
  while [ "$i" -lt "${#args[@]}" ]; do
    case "${args[$i]}" in
      -o)
        i=$((i + 1))
        case "${args[$i]}" in ConnectTimeout=*) connect_timeout=${args[$i]#*=} ;; esac
        i=$((i + 1))
        continue
        ;;
      -F) i=$((i + 1)); conf=${args[$i]} ;;
      test|-f) ;;
      /workspace/persistent-runtime/boot.ready) readiness=1 ;;
      *) [ -n "$alias" ] || alias=${args[$i]} ;;
    esac
    i=$((i + 1))
  done
  [ -n "$conf" ] && [ -f "$conf" ] || exit 255
  if [ "${FM_FAKE_SSH_PROBE_BLOCK:-0}" = 1 ]; then
    sleep "$connect_timeout"
    exit 255
  fi
  [ "$readiness" -eq 0 ] || [ "${FM_FAKE_BOOT_INCOMPLETE:-0}" != 1 ] || exit 255
  host=$(sed -n 's/^ *HostName *//p' "$conf" | head -1)
  port=$(sed -n 's/^ *Port *//p' "$conf" | head -1)
  state=${FM_FAKE_RUNPOD_STATE:?}
  live=$(jq -r --arg h "$host" --argjson p "${port:-0}" \
    '[.pods[] | select(.publicIp == $h and (.portMappings["22"] == $p))] | length' "$state" 2>/dev/null)
  [ "$live" = 1 ] || exit 255
  exit 0
fi

# Transport: ... -- <host> fm-remote-entrypoint.sh <proto> <root> <home> <argv>
[ "${FM_FAKE_SSH_MODE:-normal}" != unreachable ] || exit 255
argv_b64=${args[${#args[@]}-1]}
decode_b64() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
mapfile -t decoded < <(decode_b64 "$argv_b64" | tr '\0' '\n')
command_name=${decoded[0]:-}
action=${decoded[1]:-}
printf '%s %s %s\n' "$target_host" "$command_name" "$action" >> "${FM_FAKE_REMOTE_LOG:-/dev/null}"
if [ "$command_name" = fm-remote-secondmate-control.sh ] \
   && [ "$action" = send ] \
   && [ "${FM_FAKE_SSH_MODE:-normal}" = post-delivery-255 ]; then
  exit 255
fi
case "$command_name" in
  fm-remote-secondmate-control.sh)
    case "$action" in
      children)
        [ "${FM_FAKE_CHILDREN_MODE:-normal}" != unreachable ] || exit 255
        [ "${FM_FAKE_CHILDREN_MODE:-normal}" != error ] || { printf 'error: unreadable\n' >&2; exit 1; }
        printf 'children=%s\n' "${FM_FAKE_REMOTE_CHILDREN:-0}"
        exit 0
        ;;
      state) printf 'alive\n'; exit 0 ;;
      route)
        printf 'schema=fm-remote-secondmate-control.v1\nbackend=herdr\ntarget=fm-remote:w1:p1\nherdr_session=fm-remote\nharness=codex\nmodel=default\neffort=default\n'
        exit 0
        ;;
      launch)
        if [ "${FM_FAKE_REMOTE_LAUNCH_SUCCESS:-}" = 1 ]; then
          printf 'backend=herdr\ntarget=fm-remote:w1:p1\nherdr_session=fm-remote\nharness=codex\nmodel=default\neffort=default\n'
        fi
        exit 0
        ;;
    esac
    exit 0
    ;;
  fm-remote-doctor.sh)
    if [ -n "${FM_FAKE_DOCTOR_READY:-}" ]; then
      : > "$FM_FAKE_DOCTOR_READY"
      while [ ! -e "${FM_FAKE_DOCTOR_RELEASE:?}" ]; do sleep 0.01; done
    fi
    # fresh-pod models what a brand-new container really looks like to the
    # readiness gate: the headless Herdr fm-remote server is not running yet,
    # the read-only run tags it fixable, and --fix starts it. The doctor's own
    # Linux behavior is owned by tests/fm-remote-doctor.test.sh; this only
    # models the verdict sequence a caller sees.
    if [ "${FM_FAKE_DOCTOR_MODE:-normal}" = fresh-pod ]; then
      marker=${FM_FAKE_DOCTOR_FIXED:-/dev/null}
      if [ "$action" = --fix ]; then
        [ "$marker" = /dev/null ] || : > "$marker"
        printf 'fix herdr-server=applied: started the herdr server for session fm-remote\n'
        printf 'check herdr-server=ok: session fm-remote is running\n'
        printf 'ok: remote second-mate readiness confirmed on this host\n'
        exit 0
      fi
      if [ ! -f "$marker" ]; then
        printf 'check herdr-server=fixable: the herdr server for session fm-remote is not running\n'
        printf 'error: this host is not ready for a remote second mate; unresolved: herdr-server\n' >&2
        exit 1
      fi
    fi
    if [ "${FM_FAKE_DOCTOR_MODE:-normal}" = unready ]; then
      printf 'error: injected readiness refusal\n' >&2
      exit 1
    fi
    printf 'check herdr=ok: /usr/bin/herdr\nok: remote second-mate readiness confirmed on this host\n'
    exit 0
    ;;
esac
exit 0
SH

  chmod +x "$fakebin/curl" "$fakebin/ssh-keyscan" "$fakebin/ssh"
}

# runpod_env <fixture-root> -- <command>: run a command with the fixture wired in.
# The caller still owns FM_HOME and any per-case override it wants to add.
runpod_pod_count() {  # <state-file>
  jq -r '.pods | length' "$1"
}

runpod_volume_count() {  # <state-file>
  jq -r '.volumes | length' "$1"
}

runpod_api_calls() {  # <log> <method-and-path>
  grep -cxF -- "$2" "$1" 2>/dev/null || printf '0\n'
}

# Write a remote secondmate registry line plus its task metadata, so the
# supervision seams see a genuine remote route.
runpod_seed_remote_route() {  # <home> <id> <alias> <root> <remote-home> [projects]
  local home=$1 id=$2 alias=$3 root=$4 remote_home=$5 projects=${6:-alpha}
  mkdir -p "$home/data" "$home/state"
  printf -- '- %s - %s domain. (host: %s; root: %s; home: %s; scope: %s work; projects: %s; added 2026-08-12)\n' \
    "$id" "$id" "$alias" "$root" "$remote_home" "$id" "$projects" >> "$home/data/secondmates.md"
  fm_write_meta "$home/state/$id.meta" \
    "window=remote:$id" \
    "endpoint_task_id=$id" \
    "worktree=$remote_home" \
    "project=$root" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$remote_home" \
    "projects=$projects" \
    "remote_host=$alias" \
    "remote_root=$root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
}
