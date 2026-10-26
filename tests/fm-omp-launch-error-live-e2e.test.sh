#!/usr/bin/env bash
# Opt-in real OMP native provider-error journal; localhost only, no credentials.
set -u
if [ "${FM_OMP_LAUNCH_ERROR_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_LAUNCH_ERROR_LIVE_E2E=1 to verify real OMP provider-error reporting"
  exit 0
fi
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v bun >/dev/null 2>&1 || fail "bun not found"
OMP_BIN=$("$ROOT/bin/fm-omp-capabilities.sh" --print-binary) || fail "OMP capability check failed"
LAB=$(fm_test_tmproot fm-omp-launch-error-live)
HOME_DIR="$LAB/home"
mkdir -p "$HOME_DIR/agent"
cp -R "$ROOT/bin" "$ROOT/.omp" "$ROOT/AGENTS.md" "$HOME_DIR/"
git -C "$HOME_DIR" init -q -b main
printf 'quota-probe\n' > "$HOME_DIR/.fm-secondmate-home"
printf 'retry:\n  enabled: false\n' > "$HOME_DIR/agent/config.yml"
"$OMP_BIN" --version
FM_OMP_PROBE_HOME="$HOME_DIR" FM_OMP_PROBE_BIN="$OMP_BIN" \
  bun "$ROOT/tests/fm-omp-launch-error-live.mjs" || fail "real OMP provider-error journal failed"
