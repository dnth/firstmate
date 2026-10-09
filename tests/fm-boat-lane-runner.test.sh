#!/usr/bin/env bash
# Portable fake-provider regression for the disposable Boat lane runner.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
uv run --no-project "$ROOT/tests/boat-lane-runner-cases.py" "$ROOT"
