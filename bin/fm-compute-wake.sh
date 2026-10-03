#!/usr/bin/env bash
# Usage: fm-compute-wake.sh <secondmate-id>
# Dispatch exactly one placement claim; contradictory claims never create compute.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(dirname "$SCRIPT_DIR")}}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
# shellcheck source=bin/fm-compute-lib.sh
. "$SCRIPT_DIR/fm-compute-lib.sh"
[ "$#" -eq 1 ] || exit 2
provider=$(fm_compute_provider "$DATA" "$1")
exec "$SCRIPT_DIR/fm-$provider.sh" wake "$1"
