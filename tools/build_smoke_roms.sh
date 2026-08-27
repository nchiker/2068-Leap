#!/usr/bin/env bash
# Assemble the small standalone kernel/boot ROMs to catch interface drift.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build/smoke

sources=(
    rom/main.asm
    rom/test_memory.asm
    rom/test_math.asm
    rom/test_graphics.asm
    rom/test_io.asm
    rom/test_editor.asm
    rom/test_editor_ops.asm
    rom/test_port_monitor.asm
    rom/test_ulaplus.asm
)

outputs=(
    rom0.bin
    test_memory.bin
    test_math.bin
    test_graphics.bin
    test_io.bin
    test_editor.bin
    test_editor_ops.bin
    test_port_monitor.bin
    test_ulaplus.bin
)

for index in "${!sources[@]}"; do
    source_path="${sources[$index]}"
    name="$(basename "$source_path" .asm)"
    echo "smoke-build: ${source_path}"
    sjasmplus \
        --lst="build/smoke/${name}.lst" \
        --sym="build/smoke/${name}.sym" \
        "$source_path"
    mv -f "${outputs[$index]}" "build/smoke/${name}.bin"
done

mv -f test_ulaplus_ts2068.bin build/smoke/test_ulaplus_ts2068.bin

echo "smoke-build: ${#sources[@]} standalone ROMs assembled"
