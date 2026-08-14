#!/usr/bin/env bash
# fm-remote-entrypoint.sh installs as a PATH symlink under ~/.local/bin
# (docs/remote-secondmates.md). SCRIPT_DIR must resolve to the real bin/
# directory so it can source its sibling fm-remote-job-lib.sh, not to the
# symlink's own directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-entrypoint)
REAL_BIN="$TMP_ROOT/real-root/bin"
LOCAL_BIN="$TMP_ROOT/local-bin"
mkdir -p "$REAL_BIN" "$LOCAL_BIN"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" "$REAL_BIN/"
chmod +x "$REAL_BIN/fm-remote-entrypoint.sh"
ln -s "$REAL_BIN/fm-remote-entrypoint.sh" "$LOCAL_BIN/fm-remote-entrypoint.sh"

run_entrypoint() { # <path> <stdout-file> <stderr-file>
  local path=$1 out=$2 err=$3 code
  "$path" >"$out" 2>"$err"
  code=$?
  printf '%s' "$code"
}

test_symlink_invocation_resolves_sibling_lib() {
  local out err code
  out="$TMP_ROOT/symlink.stdout"
  err="$TMP_ROOT/symlink.stderr"
  code=$(run_entrypoint "$LOCAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  # A wrong SCRIPT_DIR fails while sourcing the sibling lib, before argv is
  # even checked, with a "No such file or directory" source error and exit 1.
  # Reaching the die() for missing protocol args proves the sibling lib
  # sourced from the real bin/, not from the symlink's own directory.
  assert_no_grep 'No such file or directory' "$err" \
    "invoking fm-remote-entrypoint.sh through a symlink failed to source its sibling lib"
  expect_code 64 "$code" "symlink invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "symlink invocation did not reach argument validation past sibling-lib sourcing"
  pass "fm-remote-entrypoint.sh invoked via a PATH symlink resolves SCRIPT_DIR to the real bin/ directory"
}

test_direct_invocation_still_works() {
  # Control: the same real script invoked directly (no symlink) must behave
  # identically, so the symlink coverage above is proven by contrast.
  local out err code
  out="$TMP_ROOT/direct.stdout"
  err="$TMP_ROOT/direct.stderr"
  code=$(run_entrypoint "$REAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  expect_code 64 "$code" "direct invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "direct invocation did not reach argument validation"
  pass "fm-remote-entrypoint.sh invoked directly still resolves SCRIPT_DIR correctly"
}

test_runpod_marker_reaches_doctor_bootstrap() {
  local home marker root_b64 home_b64 argv_b64 out err code
  home="$TMP_ROOT/remote-home"
  marker="$TMP_ROOT/runpod-root-sandbox"
  mkdir -p "$home"
  printf 'fixture\n' > "$TMP_ROOT/real-root/AGENTS.md"
  cat > "$REAL_BIN/fm-remote-doctor.sh" <<'SH'
#!/usr/bin/env bash
printf 'sandbox=%s\n' "${IS_SANDBOX:-}"
SH
  chmod +x "$REAL_BIN/fm-remote-doctor.sh"
  git -C "$TMP_ROOT/real-root" init -q -b main
  git -C "$TMP_ROOT/real-root" -c user.name=Test -c user.email=test@example.invalid \
    add AGENTS.md bin
  git -C "$TMP_ROOT/real-root" -c user.name=Test -c user.email=test@example.invalid \
    commit -qm fixture
  printf 'runpod-root-sandbox-v1\n' > "$marker"
  root_b64=$(printf '%s' "$TMP_ROOT/real-root" | base64 | tr -d '\n')
  home_b64=$(printf '%s' "$home" | base64 | tr -d '\n')
  argv_b64=$(printf 'fm-remote-doctor.sh\0--parity\0' | base64 | tr -d '\n')
  out="$TMP_ROOT/doctor.stdout"
  err="$TMP_ROOT/doctor.stderr"
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    FM_REMOTE_JOB_SANDBOX_MARKER_OVERRIDE="$marker" \
    "$REAL_BIN/fm-remote-entrypoint.sh" 1 "$root_b64" "$home_b64" "$argv_b64" \
    > "$out" 2> "$err"
  code=$?
  expect_code 0 "$code" "RunPod doctor bootstrap exit code: $(cat "$err")"
  assert_grep 'sandbox=1' "$out" \
    "the provider-owned RunPod marker did not cross the doctor env -i boundary"
  rm -f "$marker"
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    FM_REMOTE_JOB_SANDBOX_MARKER_OVERRIDE="$marker" \
    "$REAL_BIN/fm-remote-entrypoint.sh" 1 "$root_b64" "$home_b64" "$argv_b64" \
    > "$out" 2> "$err"
  code=$?
  expect_code 0 "$code" "ordinary doctor bootstrap exit code: $(cat "$err")"
  [ "$(cat "$out")" = 'sandbox=' ] \
    || fail "an ordinary remote doctor received the RunPod sandbox marker: $(cat "$out")"
  pass "provider-owned RunPod markers cross doctor bootstrap without changing ordinary hosts"
}

test_symlink_invocation_resolves_sibling_lib
test_direct_invocation_still_works
test_runpod_marker_reaches_doctor_bootstrap
