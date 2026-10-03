#!/usr/bin/env bash
# Usage: fm-boat-omp-auth.sh start <id> <alias> <ssh-config> <provider/model>
#        fm-boat-omp-auth.sh stop|status <id>
# One module owns acquisition rollback, facade/tunnel custody and checked shred.
# Linux systemd user services and cgroup v2 are required; no PID fallback exists.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec uv run --no-project "$SCRIPT_DIR/fm-boat.py" auth "$@"
