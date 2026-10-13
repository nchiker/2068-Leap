#!/usr/bin/env bash
# tools/run_all_tests.sh — run every tests/*.txt fixture via
# tools/debug_suite_run.py and report a clean pass/fail summary.
#
# Ported from Fuse/X11 screenshot-pixel-decoding to ts2068-debug
# (ZRCP/ZEsarUX) headless border-color reads (2026-09-19) -- see
# tools/debug_suite_run.py's own module docstring for the full "why".
# Uses the SAME direct-memory-injection technique the original Fuse-based
# runner did (poke the encoded program into the harness's own
# PROG_AREA_START/PROG_END at its one-shot INJECT_POINT breakpoint) --
# an early attempt to work around a since-fixed ts2068-debug breakpoint-
# timing race by simulating interactive typing instead was abandoned
# once that race was fixed at the source (see ~/ts2068-debug's
# reset_to_known_state()). See tools/run_all_tests_fast.py for a faster,
# harness-grouped variant of this same technique using the Python API
# directly instead of one `ts2068-debug` CLI process per fixture.
#
# Border-color verdict per fixture (see each tests/<name>.txt for the
# exact program), read as ts2068-debug's raw ULA border code (0-7, not an
# RGB pixel tuple): 4 = green = full pass. A handful of fixtures are
# DELIBERATE negative tests (out-of-bounds array access, out-of-memory
# DIM, invalid SOUND register) that are expected to raise a runtime
# error and halt BEFORE reaching their own final green BORDER — for
# those, the border they set right before attempting the failing
# operation (5 = cyan, by convention) IS the pass signal, not a failure.
# See docs/v1/programmers_reference.md's "Verified byte-for-byte" section
# for the origin of this convention. EXPECTED_CYAN below is the list
# of fixtures that use it — add a fixture here only if its own .txt
# explicitly documents "this should error and halt", never just
# because a run happens to come back non-green.
#
# Usage: tools/run_all_tests.sh
set -u
cd "$(dirname "$0")/.."

EXPECTED_CYAN="ayreg_bad_register ayreg_bad_value out_bad_value err1 snd3 ulaplus_bad_mode ulaplus_bad_index ulaplus_bad_value"
EXPECTED_RED="mem2"
# print_str_semicolon (GitHub issue #1 regression: PRINT "X="; T used to
# silently drop "; T" and print only the string half instead of raising
# SYNTAX ERROR) uses the same signal as the extension-unloaded fixtures
# below: rom/test_suite_inject.asm's own INJECT_POINT comment documents
# that a whole-program check-pass failure here leaves the border at its
# untouched boot default rather than a distinct color -- confirmed live
# (2026-09-19) that default is 7 (white) on the current build, not 0
# (black) as originally assumed from an older convention. Confirmed via
# CHECK_ERROR_COUNT reads (nonzero for the plain "_unloaded" fixtures,
# via test_suite_inject.bin) that this really is the checker correctly
# rejecting the unregistered keyword, not a coincidental idle color --
# see docs/milestones/MILESTONE_00_RESULTS.md. Also required fixing a
# real bug in this script itself: a hand-rolled break+run sequence must
# clear the breakpoint before its second run(), or execution that
# legitimately revisits INJECT_POINT's address re-triggers it and runs
# nothing further (tools/debug_suite_run.py now does this).
EXPECTED_BLACK="ayreg_unloaded ayreg_new_clear out_unloaded out_new_clear extension_unloaded extension_new_clear block_unloaded block_new_clear frame_unloaded frame_new_clear invert_unloaded invert_new_clear print_str_semicolon hit_unloaded hit_new_clear circle_unloaded circle_new_clear fill_unloaded fill_new_clear"

is_expected_cyan() {
    local name="$1"
    for n in $EXPECTED_CYAN; do
        [ "$n" = "$name" ] && return 0
    done
    return 1
}

is_expected_red() {
    local name="$1"
    for n in $EXPECTED_RED; do
        [ "$n" = "$name" ] && return 0
    done
    return 1
}

is_expected_black() {
    local name="$1"
    for n in $EXPECTED_BLACK; do
        [ "$n" = "$name" ] && return 0
    done
    return 1
}

make cplot-extension block-extension frame-extension invert-extension ayreg-extension out-extension sprite-extension shapes-extension >/tmp/build_extensions.log 2>&1 || exit 1

pass=0
fail=0
failed_names=()
port=10100

for f in tests/*.txt; do
    name=$(basename "$f" .txt)
    port=$((port + 1))

    env_args=()
    case "$name" in
        gfx6) env_args=(RAM_EXTENSION_BIN=build/extensions/cplot_test.bin) ;;
        gfx4|gfx5) env_args=(RAM_EXTENSION_BIN=build/extensions/shapes_test.bin) ;;
        ayreg|ayreg_bad_register|ayreg_bad_value)
            env_args=(RAM_EXTENSION_BIN=build/extensions/ayreg_test.bin) ;;
        ayreg_new_clear)
            env_args=(RAM_EXTENSION_BIN=build/extensions/ayreg_clear_test.bin RAM_EXTENSION_CLEAR=1) ;;
        out|out_bad_value)
            env_args=(RAM_EXTENSION_BIN=build/extensions/out_test.bin) ;;
        out_new_clear)
            env_args=(RAM_EXTENSION_BIN=build/extensions/out_clear_test.bin RAM_EXTENSION_CLEAR=1) ;;
        block)
            env_args=(RAM_EXTENSION_BIN=build/extensions/block_test.bin) ;;
        block_new_clear)
            env_args=(RAM_EXTENSION_BIN=build/extensions/block_clear_test.bin RAM_EXTENSION_CLEAR=1) ;;
        frame|frame_over)
            env_args=(RAM_EXTENSION_BIN=build/extensions/frame_test.bin) ;;
        frame_new_clear)
            env_args=(RAM_EXTENSION_BIN=build/extensions/frame_clear_test.bin RAM_EXTENSION_CLEAR=1) ;;
        invert)
            env_args=(RAM_EXTENSION_BIN=build/extensions/invert_test.bin) ;;
        invert_new_clear)
            env_args=(RAM_EXTENSION_BIN=build/extensions/invert_clear_test.bin RAM_EXTENSION_CLEAR=1) ;;
        extension_register)
            env_args=(RAM_EXTENSION_BIN=build/extensions/cplot_test.bin RAM_EXTENSION_SEED_CACHE=1) ;;
        extension_new_clear)
            env_args=(RAM_EXTENSION_BIN=build/extensions/cplot_clear_test.bin RAM_EXTENSION_CLEAR=1) ;;
        hit)
            env_args=(RAM_EXTENSION_BIN=build/extensions/sprite_test.bin) ;;
        hit_new_clear)
            env_args=(RAM_EXTENSION_BIN=build/extensions/sprite_clear_test.bin RAM_EXTENSION_CLEAR=1) ;;
        circle_new_clear|fill_new_clear)
            env_args=(RAM_EXTENSION_BIN=build/extensions/shapes_clear_test.bin RAM_EXTENSION_CLEAR=1) ;;
        run_state)
            env_args=(RUN_STATE_TEST=1) ;;
    esac

    out=$(env "${env_args[@]}" python3 tools/debug_suite_run.py "$name" --port "$port" 2>"/tmp/run_${name}.log")
    rc=$?
    border=$(echo "$out" | grep -oP 'border=\K.*')

    verdict="FAIL"
    if [ "$border" = "4" ]; then
        verdict="PASS"
    elif [ "$border" = "5" ] && is_expected_cyan "$name"; then
        verdict="PASS (expected cyan)"
    elif [ "$border" = "2" ] && is_expected_red "$name"; then
        verdict="PASS (expected pre-run rejection)"
    elif [ "$border" = "7" ] && is_expected_black "$name"; then
        verdict="PASS (expected unloaded rejection)"
    fi

    echo "${name}: rc=${rc} border=${border} -> ${verdict}"
    if [[ "$verdict" == PASS* ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failed_names+=("$name")
    fi
done

echo "----------------------------------------"
echo "PASS: ${pass}  FAIL: ${fail}"
if [ "$fail" -gt 0 ]; then
    echo "Failed: ${failed_names[*]}"
    exit 1
fi
exit 0
