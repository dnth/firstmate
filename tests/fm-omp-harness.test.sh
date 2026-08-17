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
    comm=) printf '%s\n' bun ;;
    args=) printf '%s %s\n' "$self_dir/bun" "$self_dir/omp --auto-approve" ;;
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
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/bun"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/omp"
  chmod +x "$fakebin/bun" "$fakebin/omp"
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
    FM_OMP_HARNESS=omp-helper "$ROOT/bin/fm-harness.sh")
  [ "$out" != omp ] || fail "inexact OMP launch marker was accepted"
  pass "OMP worker tools preserve the exact launch-boundary harness identity"
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
  pass "OMP capability probe accepts the required launch and recovery surface"
}

test_capability_probe_rejects_non_bun_entrypoint() {
  local fakebin out status
  fakebin="$TMP_ROOT/non-bun"
  mkdir -p "$fakebin"
  write_fake_omp "$fakebin/omp"
  sed -i.bak '1s|.*|#!/usr/bin/env bash|' "$fakebin/omp"
  out=$(PATH="$fakebin:/usr/bin:/bin" "$CAPABILITIES" --print-binary 2>&1)
  status=$?
  expect_code 1 "$status" "non-Bun OMP entrypoint should refuse exact ownership"
  assert_contains "$out" "entrypoint is not Bun-backed" "non-Bun OMP refusal did not explain the ownership boundary"
  pass "OMP capability probe enforces the Bun process identity used by session ownership"
}

test_capability_probe_reports_every_missing_requirement() {
  local capability fakebin out status
  for capability in '--model=' '--thinking=' '--auto-approve' '--max-time=' '--session-dir=' '--extension=' '--resume='; do
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
test_capability_probe_accepts_required_surface
test_capability_probe_rejects_non_bun_entrypoint
test_capability_probe_reports_every_missing_requirement
test_capability_probe_never_falls_back_when_omp_is_missing
