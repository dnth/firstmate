#!/usr/bin/env bash
# Focused OMP capability and exact-runtime contract tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
CAPABILITIES="$ROOT/bin/fm-omp-capabilities.sh"
trap 'rm -rf "$TMP_ROOT"' EXIT

write_fake_omp() {
  local path=$1 omitted=${2:-} dir
  dir=$(dirname "$path")
  cat > "$path" <<SH
#!/usr/bin/env bun
case "\${1:-}" in
  --help)
    cat <<'EOF'
--model=<value>
--thinking=<value>
--auto-approve
--max-time=<value>
--session-dir=<value>
-e, --extension=<value>
-r, --resume=<value>
EOF
    ;;
  --version) printf 'omp/17.1.8\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$path"
  if [ -n "$omitted" ]; then
    grep -Fv -- "$omitted" "$path" > "$path.tmp"
    mv "$path.tmp" "$path"
    chmod +x "$path"
  fi
  cat > "$dir/bun" <<'SH'
#!/usr/bin/env bash
script=$1
shift
exec bash "$script" "$@"
SH
  chmod +x "$dir/bun"
}

write_fake_no_shebang_omp() {
  local path=$1 omitted=${2:-}
  write_fake_omp "$path" "$omitted"
  sed '1d' "$path" > "$path.tmp"
  mv "$path.tmp" "$path"
  chmod +x "$path"
}

# Fake process tree for the launch-boundary marker walk: pid 700 is the spawned
# OMP worker (bun executing an absolute omp entrypoint), pid 500 is a foreign
# harness nested inside it, and every other pid is a plain tool process whose
# parent is FM_TEST_HARNESS_PARENT.
make_marker_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
self_dir=$(cd "$(dirname "$0")" && pwd -P)
if [ "$pid" = 700 ]; then
  case "$field" in
    comm=)
      if [ "${FM_TEST_OMP_SHAPE:-legacy}" = standalone ]; then
        printf '%s\n' "${FM_TEST_OMP_COMM:-omp}"
      else
        printf '%s\n' bun
      fi
      ;;
    args=)
      if [ "${FM_TEST_OMP_SHAPE:-legacy}" = standalone ]; then
        printf '%s\n' "$self_dir/omp --session-dir /tmp/omp-sessions"
      else
        printf '%s %s\n' "$self_dir/bun" "$self_dir/omp --auto-approve"
      fi
      ;;
    ppid=) printf '%s\n' 1 ;;
  esac
  exit 0
fi
case "$pid:$field" in
  500:comm=) printf '%s\n' claude ;;
  500:args=) printf '%s\n' 'claude --resume' ;;
  500:ppid=) printf '%s\n' 700 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash -c firstmate-tool' ;;
  *:ppid=) printf '%s\n' "${FM_TEST_HARNESS_PARENT:-700}" ;;
esac
SH
  chmod +x "$fakebin/ps"
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
set -u
self_dir=$(cd "$(dirname "$0")" && pwd -P)
pid=
while [ "$#" -gt 0 ]; do
  case "$1" in -p) pid=$2; shift 2 ;; *) shift ;; esac
done
if [ "$pid" = 500 ]; then
  printf 'n%s/claude\n' "$self_dir"
else
  printf 'n%s/omp\n' "$self_dir"
fi
SH
  chmod +x "$fakebin/lsof"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/bun"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/omp"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/claude"
  chmod +x "$fakebin/bun" "$fakebin/omp" "$fakebin/claude"
  printf '%s\n' "$fakebin"
}

test_launch_boundary_marker_preserves_exact_omp_identity() {
  local fakebin path out
  fakebin=$(make_marker_fakebin "$TMP_ROOT/marker")
  path="$fakebin:$(dirname "$(command -v node)"):${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

  out=$(PATH="$path" env -u PI_CODING_AGENT -u CLAUDECODE -u GROK_AGENT \
    FM_OMP_HARNESS=omp "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "exact OMP launch marker resolved '$out'"

  out=$(PATH="$path" env -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 \
    FM_OMP_HARNESS=omp "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "OMP worker lost its identity to an inherited claude marker: $out"

  out=$(PATH="$path" env -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 \
    FM_TEST_HARNESS_PARENT=500 FM_OMP_HARNESS=omp "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] \
    || fail "claude nested inside an OMP worker inherited the launch marker: $out"

  out=$(PATH="$path" env -u PI_CODING_AGENT -u CLAUDECODE -u GROK_AGENT \
    FM_OMP_HARNESS=omp FM_OMP_BUN="$fakebin/claude" FM_OMP_BIN="$fakebin/omp" \
    "$ROOT/bin/fm-harness.sh")
  [ "$out" != omp ] || fail "exact OMP ancestry fell back to launch-shape evidence after an identity mismatch"

  out=$(PATH="$path" env -u PI_CODING_AGENT -u CLAUDECODE -u GROK_AGENT \
    FM_OMP_HARNESS=omp-helper "$ROOT/bin/fm-harness.sh")
  [ "$out" != omp ] || fail "inexact OMP launch marker was accepted"
  pass "OMP worker tools preserve the exact launch-boundary harness identity"
}

test_standalone_worker_uses_bound_identity() {
  local fakebin path out omp
  fakebin=$(make_marker_fakebin "$TMP_ROOT/standalone-marker")
  path="$fakebin:$(dirname "$(command -v node)"):${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"
  omp=$(fm_test_realpath "$fakebin/omp")

  out=$(PATH="$path" env -u PI_CODING_AGENT -u CLAUDECODE -u GROK_AGENT \
    FM_TEST_OMP_SHAPE=standalone FM_TEST_OMP_COMM=cli.js FM_OMP_HARNESS=omp \
    FM_OMP_BUN="$omp" FM_OMP_BIN="$omp" \
    "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "standalone OMP worker reported as cli.js lost its bound executable identity: $out"

  out=$(PATH="$path" env -u PI_CODING_AGENT -u CLAUDECODE -u GROK_AGENT \
    FM_TEST_OMP_SHAPE=standalone FM_TEST_OMP_COMM=omp-17.3.8 FM_OMP_HARNESS=omp \
    FM_OMP_BUN="$omp" FM_OMP_BIN="$omp" \
    "$ROOT/bin/fm-harness.sh")
  [ "$out" = omp ] || fail "renamed standalone OMP lost its exact PID-bound identity: $out"

  out=$(PATH="$path" env -u PI_CODING_AGENT -u GROK_AGENT CLAUDECODE=1 \
    FM_TEST_OMP_SHAPE=standalone FM_TEST_HARNESS_PARENT=500 FM_OMP_HARNESS=omp \
    FM_OMP_BUN="$omp" FM_OMP_BIN="$omp" "$ROOT/bin/fm-harness.sh")
  [ "$out" = claude ] || fail "nested claude inherited standalone OMP identity: $out"
  pass "standalone OMP workers require exact bound executable and PID evidence"
}

test_launch_identity_honors_explicit_bun_shebang() {
  local dir runtime omp other out expected_runtime expected_omp
  dir="$TMP_ROOT/explicit-bun"
  runtime="$dir/runtime/bun"
  omp="$dir/omp"
  other="$dir/other"
  mkdir -p "$(dirname "$runtime")" "$other"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$runtime"
  printf '#!%s\nexit 0\n' "$runtime" > "$omp"
  printf '#!/usr/bin/env bash\nexit 99\n' > "$other/bun"
  chmod +x "$runtime" "$omp" "$other/bun"
  out=$(PATH="$other:/usr/bin:/bin" bash -c \
    '. "$1/bin/fm-omp-process-lib.sh"; fm_omp_process_launch_identity "$2"' \
    _ "$ROOT" "$omp")
  expected_runtime=$(fm_test_realpath "$runtime")
  expected_omp=$(fm_test_realpath "$omp")
  [ "$(printf '%s\n' "$out" | sed -n '1p')" = "$expected_runtime" ] \
    || fail "explicit Bun shebang did not bind its interpreter: $out"
  [ "$(printf '%s\n' "$out" | sed -n '2p')" = "$expected_omp" ] \
    || fail "explicit Bun shebang changed the OMP entrypoint identity: $out"
  [ -z "$(printf '%s\n' "$out" | sed -n '3p')" ] \
    || fail "explicit Bun shebang incorrectly requested PATH binding: $out"
  pass "explicit Bun shebangs bind their declared interpreter"
}

test_env_shebang_bare_argv_matches_canonical_runtime() {
  local dir runtime omp
  dir="$TMP_ROOT/env-bun-argv"
  runtime=$(fm_test_realpath "$(command -v bash)")
  omp="$dir/omp"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bun\nexit 0\n' > "$omp"
  chmod +x "$omp"
  omp=$(fm_test_realpath "$omp")
  if ! FM_OMP_PROCESS_EXPECTED_BUN="$runtime" FM_OMP_PROCESS_EXPECTED_BIN="$omp" \
    bash -c '. "$1"; fm_omp_process_matches bun "bun $2" "$$"' \
      _ "$ROOT/bin/fm-omp-process-lib.sh" "$omp"; then
    fail "env-shebang bare bun argv did not retain its canonical runtime identity"
  fi
  if FM_OMP_PROCESS_EXPECTED_BUN="$runtime" FM_OMP_PROCESS_EXPECTED_BIN="$omp" \
    bash -c '. "$1"; fm_omp_process_matches bun "node $2" "$$"' \
      _ "$ROOT/bin/fm-omp-process-lib.sh" "$omp"; then
    fail "foreign bare runtime argv was accepted as env-shebang Bun"
  fi
  pass "env-shebang bare bun argv retains exact PID-bound canonical runtime identity"
}

test_capability_probe_accepts_required_surface() {
  local fakebin out status
  fakebin="$TMP_ROOT/capabilities-ok"
  mkdir -p "$fakebin"
  write_fake_omp "$fakebin/omp"
  out=$(PATH="$fakebin:/usr/bin:/bin" "$CAPABILITIES" --print-binary 2>&1)
  status=$?
  expect_code 0 "$status" "complete OMP capability surface should pass"
  [ "$out" = "$fakebin/omp" ] || fail "capability probe did not print the exact selected OMP executable: $out"
  out=$(PATH="$fakebin:/usr/bin:/bin" "$CAPABILITIES" --require-max-time --print-binary 2>&1)
  status=$?
  expect_code 0 "$status" "complete bounded OMP capability surface should pass"
  [ "$out" = "$fakebin/omp" ] || fail "bounded capability probe did not print the exact selected OMP executable: $out"
  pass "OMP capability probe accepts the required launch and recovery surface"
}

test_capability_probe_accepts_installed_standalone_executable() {
  local lookup entry identity out status=0
  lookup=$(command -v omp 2>/dev/null) || {
    pass "standalone OMP capability probe skipped because omp is unavailable"
    return
  }
  entry=$(fm_test_realpath "$lookup")
  identity=$(bash -c '. "$1"; fm_omp_process_launch_identity "$2"' _ \
    "$ROOT/bin/fm-omp-process-lib.sh" "$entry") || fail "installed OMP has no verifiable launch identity"
  if [ "$(printf '%s\n' "$identity" | sed -n '1p')" != "$entry" ]; then
    pass "standalone OMP capability probe skipped because installed omp is a Bun script"
    return
  fi
  out=$("$CAPABILITIES" --print-binary 2>&1) || status=$?
  expect_code 0 "$status" "installed standalone OMP capability surface should pass"
  [ "$(fm_test_realpath "$out")" = "$entry" ] \
    || fail "standalone capability probe lost the selected OMP executable: $out"
  pass "OMP capability probe accepts an installed standalone native executable"
}

test_capability_probe_rejects_no_shebang_text_wrapper() {
  local fakebin out status
  fakebin="$TMP_ROOT/capabilities-no-shebang"
  mkdir -p "$fakebin"
  write_fake_no_shebang_omp "$fakebin/omp"
  out=$(PATH="$fakebin:/usr/bin:/bin" "$CAPABILITIES" --print-binary 2>&1)
  status=$?
  expect_code 1 "$status" "no-shebang text wrapper should not pass as standalone OMP"
  assert_contains "$out" "neither a Bun script nor a standalone native executable" \
    "no-shebang wrapper refusal did not explain the native identity boundary"
  pass "OMP capability probe rejects no-shebang text wrappers"
}

test_capability_probe_rejects_non_bun_entrypoint() {
  local fakebin out status
  fakebin="$TMP_ROOT/non-bun"
  mkdir -p "$fakebin"
  write_fake_omp "$fakebin/omp"
  sed -i.bak '1s|.*|#!/usr/bin/env bash|' "$fakebin/omp"
  out=$(PATH="$fakebin:/usr/bin:/bin" "$CAPABILITIES" --print-binary 2>&1)
  status=$?
  expect_code 1 "$status" "interpreter-backed non-Bun OMP entrypoint should refuse exact ownership"
  assert_contains "$out" "neither a Bun script nor a standalone native executable" "non-Bun script refusal did not explain the ownership boundary"
  pass "OMP capability probe rejects unsupported interpreter-backed process identity"
}

test_capability_probe_reports_every_missing_requirement() {
  local capability fakebin out status
  for capability in '--model=' '--thinking=' '--auto-approve' '--session-dir=' '--extension=' '--resume='; do
    fakebin="$TMP_ROOT/missing-${capability//[^a-z]/}"
    mkdir -p "$fakebin"
    write_fake_omp "$fakebin/omp" "$capability"
    out=$(PATH="$fakebin:/usr/bin:/bin" "$CAPABILITIES" --print-binary 2>&1)
    status=$?
    expect_code 1 "$status" "OMP missing $capability should refuse"
    assert_contains "$out" "missing required capability" "capability refusal was not actionable"
    assert_contains "$out" "$capability" "capability refusal did not name $capability"
  done
  pass "OMP capability probe names each missing launch or recovery requirement"
}

test_capability_probe_scopes_exact_max_time_to_bounded_launches() {
  local fakebin out status
  fakebin="$TMP_ROOT/max-time-scope"
  mkdir -p "$fakebin"
  write_fake_omp "$fakebin/omp" '--max-time='

  out=$(PATH="$fakebin:/usr/bin:/bin" "$CAPABILITIES" --print-binary 2>&1)
  status=$?
  expect_code 0 "$status" "unbounded OMP capability probe should not require max-time"
  [ "$out" = "$fakebin/omp" ] || fail "unbounded capability probe lost the selected OMP executable: $out"

  out=$(PATH="$fakebin:/usr/bin:/bin" "$CAPABILITIES" --require-max-time --print-binary 2>&1)
  status=$?
  expect_code 1 "$status" "bounded OMP capability probe should require max-time"
  assert_contains "$out" '--max-time=<value>' "bounded capability refusal did not name the exact flag"

  sed -i '/--auto-approve/a --default-max-time=<value>' "$fakebin/omp"
  out=$(PATH="$fakebin:/usr/bin:/bin" "$CAPABILITIES" --require-max-time --print-binary 2>&1)
  status=$?
  expect_code 1 "$status" "prefixed max-time option should not satisfy the exact capability"
  assert_contains "$out" '--max-time=<value>' "prefixed option refusal did not name the exact flag"
  pass "OMP max-time capability is exact and scoped to bounded launch templates"
}

test_capability_probe_never_falls_back_when_omp_is_missing() {
  local empty out status
  empty="$TMP_ROOT/no-omp"
  mkdir -p "$empty"
  out=$(PATH="$empty:/usr/bin:/bin" "$CAPABILITIES" --print-binary 2>&1)
  status=$?
  expect_code 1 "$status" "missing OMP executable should refuse"
  assert_contains "$out" "omp executable not found on PATH" "missing executable error was not concrete"
  assert_contains "$out" "never falls back" "missing executable error did not preserve no-fallback behavior"
  pass "selected OMP refuses instead of falling back to another harness"
}

test_launch_boundary_marker_preserves_exact_omp_identity
test_standalone_worker_uses_bound_identity
test_launch_identity_honors_explicit_bun_shebang
test_env_shebang_bare_argv_matches_canonical_runtime
test_capability_probe_accepts_required_surface
test_capability_probe_accepts_installed_standalone_executable
test_capability_probe_rejects_no_shebang_text_wrapper
test_capability_probe_rejects_non_bun_entrypoint
test_capability_probe_reports_every_missing_requirement
test_capability_probe_scopes_exact_max_time_to_bounded_launches
test_capability_probe_never_falls_back_when_omp_is_missing
