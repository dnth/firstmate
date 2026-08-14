#!/usr/bin/env bash
# Mocked regressions for the RunPod OMP auth-broker client, read-only facade,
# and workstation-owned reverse-tunnel lifecycle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOT="$ROOT/bin/fm-runpod-pod-boot.sh"
CONTROL="$ROOT/bin/fm-remote-secondmate-control.sh"
AUTH="$ROOT/bin/fm-runpod-omp-auth.sh"
PROXY="$ROOT/bin/fm-omp-auth-broker-readonly-proxy.mjs"
TMP_ROOT=$(fm_test_tmproot fm-runpod-omp-auth)
UPSTREAM_PID=
PROXY_PID=
TUNNEL_PID=

cleanup() {
  for pid in "$TUNNEL_PID" "$PROXY_PID" "$UPSTREAM_PID"; do
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "$TUNNEL_PID" "$PROXY_PID" "$UPSTREAM_PID"; do
    [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

mode_of() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

wait_for_file() {  # <path> <label>
  local i=0
  while [ ! -s "$1" ]; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || fail "$2 did not become ready"
    sleep 0.05
  done
}

help=$(FM_VOLUME="$TMP_ROOT/help-volume" FM_PERSIST="$TMP_ROOT/help-persist" bash "$BOOT" --help)
assert_contains "$help" 'fm-runpod-pod-boot.sh --install-omp-auth-broker-token < token-file' \
  "pod boot help omitted the bearer installation control"
assert_contains "$help" 'fm-runpod-pod-boot.sh --check-omp-auth-broker-client' \
  "pod boot help omitted the broker client readiness control"
assert_absent "$TMP_ROOT/help-persist" "pod boot help mutated the persistent runtime"
pass "pod boot help documents both OMP broker controls without touching pod state"

# --- pod boot installs and exports the bearer without exposing it ------------

POD="$TMP_ROOT/pod"
PERSIST="$POD/persistent-runtime"
FAKEBIN="$TMP_ROOT/fakebin"
ENV_LOG="$TMP_ROOT/client-env.log"
mkdir -p "$POD" "$FAKEBIN"

printf '%s' 'dummy_pod_broker_token_123' \
  | FM_VOLUME="$POD" FM_PERSIST="$PERSIST" bash "$BOOT" --install-omp-auth-broker-token >/dev/null \
  || fail "the pod boot token-install interface failed"
TOKEN_FILE="$PERSIST/omp-auth-broker.token"
assert_present "$TOKEN_FILE" "the pod boot interface did not publish the broker token"
[ "$(mode_of "$TOKEN_FILE")" = 600 ] || fail "the pod broker token mode is $(mode_of "$TOKEN_FILE"), expected 600"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf 'url=%s\nfile=%s\ntoken_set=%s\n' \
  "$OMP_AUTH_BROKER_URL" "$FM_OMP_AUTH_BROKER_TOKEN_FILE" "${OMP_AUTH_BROKER_TOKEN:+yes}" \
  > "$FM_FAKE_CLIENT_ENV_LOG"
exit 0
SH
chmod +x "$FAKEBIN/curl"
out=$(PATH="$FAKEBIN:$PATH" FM_FAKE_CLIENT_ENV_LOG="$ENV_LOG" \
  OMP_AUTH_BROKER_URL=http://127.0.0.1:8765 \
  FM_VOLUME="$POD" FM_PERSIST="$PERSIST" bash "$BOOT" --check-omp-auth-broker-client 2>&1)
assert_contains "$out" 'auth-broker=ready mode=credential-read-only' \
  "the pod boot client check did not report the read-only broker path ready"
assert_grep 'url=http://127.0.0.1:8765' "$ENV_LOG" \
  "the pod boot client did not export OMP_AUTH_BROKER_URL"
assert_grep "file=$TOKEN_FILE" "$ENV_LOG" \
  "the pod boot client did not retain the mode-600 token-file path"
assert_grep 'token_set=yes' "$ENV_LOG" \
  "the pod boot client did not export OMP_AUTH_BROKER_TOKEN"
assert_not_contains "$out" 'dummy_pod_broker_token_123' "the pod boot client printed the broker bearer"
pass "pod boot stores the broker bearer at mode 0600 and exports the OMP client environment without printing it"

# --- remote control passes only safe broker launch inputs to fm-spawn --------

CONTROL_ROOT="$TMP_ROOT/control-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
CONTROL_LOG="$TMP_ROOT/control-launch.log"
RUNPOD_MARKER="$TMP_ROOT/runpod-root-sandbox"
mkdir -p "$CONTROL_ROOT/bin" "$REMOTE_HOME/bin" "$REMOTE_HOME/state" "$REMOTE_HOME/data" "$REMOTE_HOME/config"
cp "$CONTROL" "$CONTROL_ROOT/bin/fm-remote-secondmate-control.sh"
printf '# Firstmate fixture\n' > "$REMOTE_HOME/AGENTS.md"
printf 'podmate\n' > "$REMOTE_HOME/.fm-secondmate-home"
printf 'runpod-root-sandbox-v1\n' > "$RUNPOD_MARKER"

cat > "$CONTROL_ROOT/bin/fm-backend.sh" <<'SH'
#!/usr/bin/env bash
fm_meta_get() { sed -n "s/^$2=//p" "$1" | head -1; }
fm_backend_meta_exact_value() { fm_meta_get "$1" "$2"; }
fm_backend_validate_task_endpoint() {
  [ -f "$1" ] || return 1
  FM_BACKEND_VALIDATED_BACKEND=$(fm_meta_get "$1" backend)
  FM_BACKEND_VALIDATED_TARGET=$(fm_meta_get "$1" target)
}
fm_backend_agent_state() { printf 'missing\n'; }
fm_backend_kill() { return 0; }
SH
cat > "$CONTROL_ROOT/bin/fm-pending-reply-lib.sh" <<'SH'
#!/usr/bin/env bash
fm_pending_reply_backend_observation() { printf 'idle'; }
SH
cat > "$CONTROL_ROOT/bin/fm-quota-axi-lib.sh" <<'SH'
#!/usr/bin/env bash
fm_quota_secondmate_fallback_reason() { return 1; }
SH
cat > "$CONTROL_ROOT/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf 'url=%s\nfile=%s\ntoken=%s\n' \
  "${FM_OMP_AUTH_BROKER_URL:-}" "${FM_OMP_AUTH_BROKER_TOKEN_FILE:-}" "${OMP_AUTH_BROKER_TOKEN:-}" \
  > "$FM_FAKE_CONTROL_LOG"
id=$1
mkdir -p "$FM_STATE_OVERRIDE"
printf '%s\n' \
  'backend=herdr' 'target=fm-remote:w1:p1' 'herdr_session=fm-remote' \
  'harness=omp' 'model=default' 'effort=high' \
  > "$FM_STATE_OVERRIDE/$id.meta"
printf 'spawned\n'
SH
chmod +x "$CONTROL_ROOT/bin/"*.sh

FM_FAKE_CONTROL_LOG="$CONTROL_LOG" FM_ROOT_OVERRIDE="$CONTROL_ROOT" FM_HOME="$REMOTE_HOME" \
  FM_RUNPOD_SANDBOX_MARKER="$RUNPOD_MARKER" \
  FM_RUNPOD_OMP_AUTH_BROKER_TOKEN_FILE="$TOKEN_FILE" \
  FM_RUNPOD_OMP_AUTH_BROKER_URL=http://127.0.0.1:8765 \
  "$CONTROL_ROOT/bin/fm-remote-secondmate-control.sh" \
  launch podmate omp - high herdr - - - >/dev/null \
  || fail "the remote secondmate launch rejected the RunPod OMP broker environment"
assert_grep 'url=http://127.0.0.1:8765' "$CONTROL_LOG" \
  "remote secondmate control did not pass the loopback broker URL to fm-spawn"
assert_grep "file=$TOKEN_FILE" "$CONTROL_LOG" \
  "remote secondmate control did not pass the safe token-file path to fm-spawn"
grep -Fx 'token=' "$CONTROL_LOG" >/dev/null \
  || fail "remote secondmate control expanded the broker bearer before the pane launch seam"
assert_no_grep 'dummy_pod_broker_token_123' "$CONTROL_LOG" \
  "remote secondmate control leaked bearer bytes into its launch log"
pass "remote secondmate launch passes the broker URL and token-file path without putting bearer bytes in argv"

# --- credential-read-only facade blocks every client write ------------------

BASE_PORT=$((22000 + ($$ % 10000) * 2))
UPSTREAM_PORT=$BASE_PORT
PROXY_PORT=$((BASE_PORT + 1))
UPSTREAM_LOG="$TMP_ROOT/upstream.log"
UPSTREAM_READY="$TMP_ROOT/upstream.ready"
UPSTREAM_SCRIPT="$TMP_ROOT/upstream.mjs"
PROXY_TOKEN="$TMP_ROOT/proxy.token"
printf '%s' 'dummy_proxy_token_456' > "$PROXY_TOKEN"
chmod 600 "$PROXY_TOKEN"

cat > "$UPSTREAM_SCRIPT" <<'JS'
import { createServer } from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";
const server = createServer((request, response) => {
  appendFileSync(process.env.UPSTREAM_LOG, `${request.method} ${new URL(request.url, "http://x").pathname}\n`);
  request.resume();
  request.on("end", () => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(request.url.includes("refresh")
      ? '{"entry":{"id":1,"provider":"anthropic","credential":{"type":"oauth","access":"redacted"}}}'
      : '{"generation":1,"credentials":[]}');
  });
});
server.listen(Number(process.env.UPSTREAM_PORT), "127.0.0.1", () => writeFileSync(process.env.UPSTREAM_READY, "ready\n"));
for (const signal of ["SIGINT", "SIGTERM"]) server.once(signal, () => server.close(() => process.exit(0)));
JS
UPSTREAM_LOG="$UPSTREAM_LOG" UPSTREAM_READY="$UPSTREAM_READY" UPSTREAM_PORT="$UPSTREAM_PORT" \
  node "$UPSTREAM_SCRIPT" >/dev/null 2>&1 &
UPSTREAM_PID=$!
wait_for_file "$UPSTREAM_READY" "the fake canonical broker"

FM_OMP_AUTH_BROKER_TOKEN_FILE="$PROXY_TOKEN" \
  FM_OMP_AUTH_BROKER_UPSTREAM_URL="http://127.0.0.1:$UPSTREAM_PORT" \
  FM_OMP_AUTH_BROKER_PROXY_BIND="127.0.0.1:$PROXY_PORT" \
  node "$PROXY" > "$TMP_ROOT/proxy.log" 2>&1 &
PROXY_PID=$!
for _ in $(seq 1 100); do
  curl -fsS --max-time 1 "http://127.0.0.1:$PROXY_PORT/v1/healthz" >/dev/null 2>&1 && break
  sleep 0.05
done
kill -0 "$PROXY_PID" 2>/dev/null || fail "the read-only broker facade exited during startup"

CURL_CFG="$TMP_ROOT/proxy-curl.cfg"
{
  printf 'silent\nshow-error\n'
  printf 'header = "Authorization: Bearer dummy_proxy_token_456"\n'
} > "$CURL_CFG"
chmod 600 "$CURL_CFG"
curl --config "$CURL_CFG" -fsS "http://127.0.0.1:$PROXY_PORT/v1/snapshot" >/dev/null \
  || fail "the read-only facade rejected a broker snapshot read"
mutation_code=$(curl --config "$CURL_CFG" -sS -o /dev/null -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PROXY_PORT/v1/credential")
[ "$mutation_code" = 403 ] || fail "credential upload returned HTTP $mutation_code, expected 403"
disable_code=$(curl --config "$CURL_CFG" -sS -o /dev/null -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PROXY_PORT/v1/credential/1/disable")
[ "$disable_code" = 403 ] || fail "credential disable returned HTTP $disable_code, expected 403"
curl --config "$CURL_CFG" -fsS -X POST \
  "http://127.0.0.1:$PROXY_PORT/v1/credential/1/refresh" >/dev/null \
  || fail "the facade rejected broker-side OAuth refresh"
assert_grep 'GET /v1/snapshot' "$UPSTREAM_LOG" "snapshot reads did not reach the canonical broker"
assert_grep 'POST /v1/credential/1/refresh' "$UPSTREAM_LOG" \
  "broker-side OAuth refresh did not reach the canonical workstation writer"
! grep -Fx 'POST /v1/credential' "$UPSTREAM_LOG" >/dev/null \
  || fail "the pod credential-upload mutation reached the canonical broker"
assert_no_grep 'POST /v1/credential/1/disable' "$UPSTREAM_LOG" \
  "the pod credential-disable mutation reached the canonical broker"
pass "the pod-facing facade permits reads and workstation refresh while credential mutations never reach the broker"

kill -TERM "$PROXY_PID" "$UPSTREAM_PID" 2>/dev/null || true
wait "$PROXY_PID" 2>/dev/null || true
wait "$UPSTREAM_PID" 2>/dev/null || true
PROXY_PID=
UPSTREAM_PID=

# --- reverse tunnel uses keepalives and restarts after drops -----------------

TUNNEL_HOME="$TMP_ROOT/tunnel-home"
TUNNEL_BIN="$TMP_ROOT/tunnel-bin"
TUNNEL_LOG="$TMP_ROOT/tunnel.log"
TUNNEL_COUNT="$TMP_ROOT/tunnel.count"
mkdir -p "$TUNNEL_HOME/state" "$TUNNEL_HOME/config" "$TUNNEL_BIN"
printf 'Host pod-alias\n' > "$TMP_ROOT/pod.conf"
cat > "$TUNNEL_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"ok":true,"mode":"credential-read-only"}'
SH
cat > "$TUNNEL_BIN/ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_TUNNEL_COUNT" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_TUNNEL_COUNT"
printf '%s\n' "$*" >> "$FM_FAKE_TUNNEL_LOG"
[ "$count" -ge 3 ] || exit 255
trap 'exit 0' INT TERM
while :; do sleep 1; done
SH
chmod +x "$TUNNEL_BIN/curl" "$TUNNEL_BIN/ssh"

FM_HOME="$TUNNEL_HOME" FM_STATE_OVERRIDE="$TUNNEL_HOME/state" \
  FM_RUNPOD_OMP_CURL_BIN="$TUNNEL_BIN/curl" FM_RUNPOD_OMP_SSH_BIN="$TUNNEL_BIN/ssh" \
  FM_RUNPOD_OMP_PROXY_BIND=127.0.0.1:18766 FM_RUNPOD_OMP_REMOTE_BIND=127.0.0.1:8765 \
  FM_RUNPOD_OMP_RESTART_DELAY=0.05 FM_FAKE_TUNNEL_COUNT="$TUNNEL_COUNT" \
  FM_FAKE_TUNNEL_LOG="$TUNNEL_LOG" \
  "$AUTH" tunnel-run podmate pod-alias "$TMP_ROOT/pod.conf" >/dev/null 2>&1 &
TUNNEL_PID=$!
for _ in $(seq 1 100); do
  [ "$(cat "$TUNNEL_COUNT" 2>/dev/null || printf '0')" -ge 3 ] && break
  sleep 0.05
done
[ "$(cat "$TUNNEL_COUNT" 2>/dev/null || printf '0')" -ge 3 ] \
  || fail "the tunnel supervisor did not restart SSH after injected drops"
kill -TERM "$TUNNEL_PID" 2>/dev/null || true
wait "$TUNNEL_PID" 2>/dev/null || true
TUNNEL_PID=

[ "$(wc -l < "$TUNNEL_LOG" | tr -d ' ')" -ge 3 ] \
  || fail "the tunnel log did not record the initial connection and two restarts"
assert_grep 'ExitOnForwardFailure=yes' "$TUNNEL_LOG" "the reverse tunnel did not fail closed when forwarding setup failed"
assert_grep 'ServerAliveInterval=15' "$TUNNEL_LOG" "the reverse tunnel did not arm server keepalives"
assert_grep 'ServerAliveCountMax=3' "$TUNNEL_LOG" "the reverse tunnel did not bound missed keepalives"
assert_grep '-R 127.0.0.1:8765:127.0.0.1:18766' "$TUNNEL_LOG" \
  "the pod loopback endpoint did not forward to the workstation read-only facade"
pass "the SSH reverse tunnel is loopback-scoped, keepalive-bounded, and automatically restarted after drops"

echo "# all fm-runpod-omp-auth tests passed"
