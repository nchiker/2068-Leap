#!/usr/bin/env bash
# Run a non-production spike image headless. usage: run_spike.sh <bin> <result_addr_hex>
# border 4 = PASS, 2 = FAIL; result byte = number of the last test started.
set -euo pipefail
cd "$(dirname "$0")/../.."
bin="$1"; addr="$2"
state_dir="$(mktemp -d)"; export TS2068_DEBUG_STATE_DIR="$state_dir"
trap 'ts2068-debug --json stop >/dev/null 2>&1 || true; rm -rf "$state_dir"' EXIT
ts2068-debug --json stop >/dev/null 2>&1 || true
ts2068-debug --json start --rom "$bin" --port 10241 >/dev/null
ts2068-debug --json run --max-instructions 3000000 >/dev/null
border="$(ts2068-debug --json timex | python3 -c 'import json,sys;print(json.load(sys.stdin).get("border"))')"
res="$(ts2068-debug --json mem "$addr" 1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["hex"])')"
echo "$(basename "$bin"): border=$border last_test=0x$res -> $([ "$border" = 4 ] && echo PASS || echo FAIL)"
