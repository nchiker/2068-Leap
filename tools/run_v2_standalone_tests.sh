#!/usr/bin/env bash
# Build and execute the currently supported standalone V2 regression ROMs.
set -euo pipefail

cd "$(dirname "$0")/.."

names=(
    arrays block_if decompiler ext_demo for_step group6_math input
    mode_module printer_module relational save_load sqr_decomp strfuncs
    vm_milestone01
)
out_dir=build/smoke/v2-standalone
mkdir -p "$out_dir"

for name in "${names[@]}"; do
    tools/sjasmplus_strict.sh \
        --sym="$out_dir/test_v2_${name}.sym" \
        "rom/test_v2_${name}.asm"
    mv "test_v2_${name}.bin" "$out_dir/test_v2_${name}.bin"
    cat "$out_dir/test_v2_${name}.bin" build/exrom.bin \
        > "$out_dir/test_v2_${name}_zesarux.bin"
done

state_dir="$(mktemp -d)"
export TS2068_DEBUG_STATE_DIR="$state_dir"
port="${TS2068_V2_TEST_PORT:-10220}"
cleanup() {
    ts2068-debug --json stop >/dev/null 2>&1 || true
    rm -rf "$state_dir"
}
trap cleanup EXIT

pass=0
for name in "${names[@]}"; do
    ts2068-debug --json stop >/dev/null 2>&1 || true
    ts2068-debug --json start \
        --rom "$out_dir/test_v2_${name}_zesarux.bin" --port "$port" >/dev/null
    ts2068-debug --json run --max-instructions 3000000 >/dev/null
    border="$(ts2068-debug --json timex | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("border"))')"
    if [ "$border" != 4 ]; then
        echo "${name}: border=${border} -> FAIL" >&2
        exit 1
    fi
    echo "${name}: border=${border} -> PASS"
    pass=$((pass + 1))
done

echo "V2 standalone: ${pass}/${#names[@]} PASS"
