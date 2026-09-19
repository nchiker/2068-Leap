#!/usr/bin/env bash
# Execute deterministic standalone smoke ROMs and check their border verdict.
#
# Ported from the original Fuse/X11 screenshot-based runner (see git history) to
# ts2068-debug (ZRCP/ZEsarUX): the old version launched a real Fuse window under
# Xvfb, slept a fixed 2.5s guessing when the window would exist, found it via
# xwininfo/Xlib, screenshotted it, and decoded a pixel color at (10, 10). That
# needed a live X11 display and baked in real-time sleeps unrelated to how long
# the ROM actually takes to run. ts2068-debug reads the border color directly off
# the emulated ULA port (no display, no screenshot) and bounds execution by opcode
# count instead of wall-clock sleep.
set -euo pipefail

cd "$(dirname "$0")/.."

STATE_DIR="$(mktemp -d)"
export TS2068_DEBUG_STATE_DIR="$STATE_DIR"
PORT=10050
cleanup() {
    ts2068-debug --json stop >/dev/null 2>&1 || true
    rm -rf "$STATE_DIR"
}
trap cleanup EXIT

tests=(
    test_memory
    test_math
    test_editor_ops
    test_calc_smoke_endcalc
    test_calc_smoke_stackops
    test_calc_smoke_arithmetic
    test_calc_smoke_division
    test_calc_smoke_dupoverflow
    test_calc_smoke_unimpl
)
pass=0
fail=0

for name in "${tests[@]}"; do
    rom_path="build/smoke/${name}.bin"
    combined="build/smoke/${name}_zesarux.bin"

    if [ ! -f "$rom_path" ]; then
        echo "smoke-runtime: missing ${rom_path}; run make smoke-build" >&2
        exit 1
    fi

    # ZEsarUX --romfile wants one concatenated Home+EXROM image (see ts2068-debug's
    # own README/docs/zesarux-analysis.md); each smoke ROM is a standalone 16K Home
    # image that pages into the real production EXROM, same as the ordinary build.
    cat "$rom_path" exrom.bin > "$combined"

    ts2068-debug --json stop >/dev/null 2>&1 || true
    ts2068-debug --json start --rom "$combined" --port "$PORT" >/dev/null

    # Bounded, not a real-time sleep: every smoke ROM either signals PASS/FAIL (a
    # border write) and halts in a tight `jr $`, or hangs. 500,000 opcodes is
    # comfortably more than any of these minimal kernel-primitive tests need to
    # reach that halt.
    ts2068-debug --json run --max-instructions 500000 >/dev/null

    border="$(ts2068-debug --json timex | python3 -c 'import json, sys; print(json.load(sys.stdin).get("border"))')"

    verdict="FAIL"
    if [ "$border" = "4" ]; then
        verdict="PASS"
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
    echo "${name}: border=${border} -> ${verdict}"
done

echo "----------------------------------------"
echo "SMOKE PASS: ${pass}  FAIL: ${fail}"
[ "$fail" -eq 0 ]
