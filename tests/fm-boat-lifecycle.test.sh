#!/usr/bin/env bash
# Fresh fixture homes; no live Boat, credentials, remote host or inference.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
uv run --no-project "$ROOT/tests/boat-lifecycle-cases.py" "$ROOT"
