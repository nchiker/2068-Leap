#!/usr/bin/env bash
# run_one_standalone.sh <worktree> <test-name> [port] -- build + run ONE standalone component test (migrated group) with the runner's own recipe
set -euo pipefail
wt="$1"; name="$2"; port="${3:-10399}"
cd "$wt"
out_dir=build/smoke/v2-one; mkdir -p "$out_dir"
sjasmplus -DTEST_V2_NEEDS_DECOMPILE rom/test_v2_harness_exrom.asm >/dev/null; mv test_v2_harness_exrom.bin "$out_dir/exrom.bin"
sjasmplus -DTEST_V2_NEEDS_DECOMPILE -DTEST_V2_NEEDS_CALC rom/test_v2_harness_exrom.asm >/dev/null; mv test_v2_harness_exrom.bin "$out_dir/exrom_calc.bin"
ex="$out_dir/exrom.bin"; case "$name" in r10_numeric|run_tables) ex="$out_dir/exrom_calc.bin";; esac
tools/sjasmplus_strict.sh --sym="$out_dir/t.sym" "rom/test_v2_${name}.asm" >/dev/null
mv test_v2_harness_home.bin "$out_dir/home.bin"
cat "$out_dir/home.bin" "$ex" > "$out_dir/t_zesarux.bin"
state="$(mktemp -d)"; export TS2068_DEBUG_STATE_DIR="$state"
ts2068-debug --json start --rom "$out_dir/t_zesarux.bin" --port "$port" >/dev/null
ts2068-debug --json run --max-instructions "${MAXI:-3000000}" >/dev/null
border="$(ts2068-debug --json timex | python3 -c 'import json,sys; print(json.load(sys.stdin).get("border"))')"
ts2068-debug --json stop >/dev/null 2>&1 || true; rm -rf "$state"
echo "$name border=$border $([ "$border" = 4 ] && echo PASS || echo FAIL)"
