#!/usr/bin/env bash
# Pixel-level validation for the unified EXT2 GRAPHICS package (CPLOT,
# BLOCK, FRAME, INVERT) — closes the gap flagged in docs/
# R10_7_CAPABILITY_RESTORATION.md section 3: the existing standalone
# suite (rom/test_v2_graphics_module.asm) only proves compile/decompile
# reachability with GFX_WRITE_PIXEL stubbed out; it never checks a real
# bitmap/attribute byte.
#
# WHY THIS ISN'T a plain `tools/sjasmplus_strict.sh` + ts2068-debug run
# like every other standalone v2 test: rom/ext_v2_graphics_module.asm
# declares its own scratch state as plain DB cells with no fixed address
# -- correct for its real deployment (rom/v2_package_graphics.asm, a
# genuine loadable RAM package), but fatal if included directly into the
# shared test harness's HOME image, where those same cells land in real,
# non-writable ROM ($0000-$3FFF on this project's own TS2068 memory
# model). See rom/test_v2_graphics_module_ram.asm's own header for the
# full diagnosis (found and root-caused in the R10.7 GRAPHICS pixel-
# level validation session).
#
# This script instead: (1) builds rom/test_v2_graphics_pixel.asm as the
# HOME side of the usual two-bank harness, with GRAPHICS_INSTALL left as
# a fixed `equ $9000` rather than an inline include; (2) extracts the
# cross-bank constants the real GRAPHICS module needs (EXT2_REGISTER,
# EXT_CALL_ARG0-3, VM_CLAMP_Y191, VM_COMPUTE_PRINT_ATTR, GFX_WRITE_PIXEL,
# CURRENT_OVER) from that build's own .sym file, the same role build/
# v2_crossbank.inc plays for the real package build; (3) assembles the
# real module separately at ORG $9000 (genuine RAM, confirmed clear of
# CURRENT_INK/PAPER/OVER and this test's own tiny K-TAB source lines);
# (4) boots the combined ROM headless via ts2068-debug, injects the
# assembled module bytes into RAM via `mem-write` (the same "load a
# package, then call it" shape the real production LOAD mechanism uses),
# and runs to the test's own PASS/FAIL border-color convention.
set -euo pipefail
cd "$(dirname "$0")/.."

out_dir=build/smoke/graphics-pixel
mkdir -p "$out_dir"

echo "Building HOME side (rom/test_v2_graphics_pixel.asm)..."
tools/sjasmplus_strict.sh --sym="$out_dir/home.sym" rom/test_v2_graphics_pixel.asm
mv test_v2_harness_home.bin "$out_dir/home.bin"

echo "Building shared EXROM side..."
sjasmplus -DTEST_V2_NEEDS_DECOMPILE rom/test_v2_harness_exrom.asm >/dev/null
mv test_v2_harness_exrom.bin "$out_dir/exrom.bin"

cat "$out_dir/home.bin" "$out_dir/exrom.bin" > "$out_dir/combined.bin"

echo "Extracting cross-bank constants..."
python3 - "$out_dir/home.sym" > "$out_dir/crossbank.inc" <<'PYEOF'
import re, sys
needed = ["EXT2_REGISTER", "EXT_CALL_ARG0", "EXT_CALL_ARG1", "EXT_CALL_ARG2",
          "EXT_CALL_ARG3", "VM_CLAMP_Y191", "VM_COMPUTE_PRINT_ATTR",
          "GFX_WRITE_PIXEL", "CURRENT_OVER"]
found = {}
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"(\w+):\s+EQU\s+0x([0-9A-Fa-f]+)", line)
        if m and m.group(1) in needed:
            found[m.group(1)] = int(m.group(2), 16)
missing = [n for n in needed if n not in found]
if missing:
    sys.stderr.write(f"FATAL: missing cross-bank symbols: {missing}\n")
    sys.exit(1)
for name in needed:
    print(f"{name}: equ ${found[name]:04X}")
PYEOF

echo 'Building the real GRAPHICS module at its RAM address ($9000)...'
sjasmplus --sym="$out_dir/module_ram.sym" rom/test_v2_graphics_module_ram.asm

module_size=$(stat -c%s "$out_dir/module_ram.bin")
echo "Module size: $module_size bytes"

port="${TS2068_GFX_TEST_PORT:-10228}"
cleanup() { ts2068-debug --json stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

ts2068-debug --json stop >/dev/null 2>&1 || true
ts2068-debug --json start --rom "$out_dir/combined.bin" --symbols "$out_dir/home.sym" --port "$port" >/dev/null
ts2068-debug --json reset-known-state >/dev/null

module_hex=$(python3 -c "print(open('$out_dir/module_ram.bin','rb').read().hex())")
ts2068-debug --json mem-write 0x9000 "$module_hex" >/dev/null

ts2068-debug --json run --max-instructions 5000000 >/dev/null

border="$(ts2068-debug --json timex | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("border"))')"

if [ "$border" != 4 ]; then
    echo "graphics_pixel: border=${border} -> FAIL" >&2
    echo "COMPILE_ERROR_CODE=$(ts2068-debug --json mem COMPILE_ERROR_CODE 1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["hex"])')" >&2
    echo "VM_ERROR_CODE=$(ts2068-debug --json mem VM_ERROR_CODE 1 | python3 -c 'import json,sys;print(json.load(sys.stdin)["hex"])')" >&2
    exit 1
fi
echo "graphics_pixel: border=${border} -> PASS (CPLOT/BLOCK/FRAME/INVERT pixel-level validated)"
