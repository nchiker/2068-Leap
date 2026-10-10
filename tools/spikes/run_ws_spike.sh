#!/usr/bin/env bash
# Build and run the Workspace Manager spike (non-production). border 4 = PASS.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/spikes
tools/sjasmplus_strict.sh tools/spikes/ws_manager_spike.asm | grep -E "^> WS|rror"
state_dir="$(mktemp -d)"; export TS2068_DEBUG_STATE_DIR="$state_dir"
trap 'ts2068-debug --json stop >/dev/null 2>&1 || true; rm -rf "$state_dir"' EXIT
ts2068-debug --json stop >/dev/null 2>&1 || true
ts2068-debug --json start --rom build/spikes/ws_manager_spike.bin --port 10240 >/dev/null
ts2068-debug --json run --max-instructions 200000 >/dev/null
border="$(ts2068-debug --json timex | python3 -c 'import json,sys;print(json.load(sys.stdin).get("border"))')"
res="$(ts2068-debug --json mem 0x8010 1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["hex"])')"
echo "ws_manager_spike: border=$border last_test_hex=$res -> $([ "$border" = 4 ] && echo PASS || echo FAIL)"
