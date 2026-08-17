#!/usr/bin/env bash
# Opt-in real OMP max-time launch-parser guard without a model call.
set -u

if [ "${FM_OMP_MAX_TIME_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_MAX_TIME_LIVE_E2E=1 to run the real OMP max-time parser guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OMP_BIN=$("$ROOT/bin/fm-omp-capabilities.sh" --print-binary) || fail "OMP capability check failed"
OMP_VERSION=$("$OMP_BIN" --version 2>&1 | head -1) || fail "OMP version probe failed for $OMP_BIN"
[ -n "$OMP_VERSION" ] || fail "OMP version probe returned no version"

for duration in 1 1m 1h; do
  output=$("$OMP_BIN" --max-time="$duration" --help 2>&1) \
    || fail "OMP $OMP_VERSION rejected --max-time=$duration"
  assert_contains "$output" '--max-time=<value>' \
    "OMP $OMP_VERSION help lost the max-time capability after parsing --max-time=$duration"
done

pass "OMP $OMP_VERSION accepts max-time seconds, minutes, and hours"
