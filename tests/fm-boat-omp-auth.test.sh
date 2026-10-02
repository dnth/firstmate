#!/usr/bin/env bash
# Fixture-only credential matrix and actual Linux systemd cgroup custody proofs.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [ "$(uname)" != Linux ] || ! systemctl --user show --property=ControlGroup >/dev/null 2>&1; then
  printf 'skip: Boat credential custody requires a Linux systemd user manager\n'
  exit 0
fi
uv run --no-project "$ROOT/tests/boat-auth-cases.py" "$ROOT"
