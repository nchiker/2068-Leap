#!/usr/bin/env bash
# tools/run_all_tests.sh — run every tests/*.txt fixture via
# tools/run_suite_test.sh and report a clean pass/fail summary.
#
# Border-color verdict per fixture (see each tests/<name>.txt for the
# exact program): green = full pass. A handful of fixtures are
# DELIBERATE negative tests (out-of-bounds array access, out-of-memory
# DIM, invalid SOUND register) that are expected to raise a runtime
# error and halt BEFORE reaching their own final green BORDER — for
# those, the border they set right before attempting the failing
# operation (cyan, by convention) IS the pass signal, not a failure.
# See docs/programmers_reference.md's "Verified byte-for-byte" section
# for the origin of this convention. EXPECTED_CYAN below is the list
# of fixtures that use it — add a fixture here only if its own .txt
# explicitly documents "this should error and halt", never just
# because a run happens to come back non-green.
#
# Usage: tools/run_all_tests.sh
set -u
cd "$(dirname "$0")/.."

EXPECTED_CYAN="err1 snd3 ulaplus_bad_mode ulaplus_bad_index ulaplus_bad_value"
EXPECTED_RED="mem2"
EXPECTED_BLACK="extension_unloaded extension_new_clear block_unloaded block_new_clear"

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

make cplot-extension block-extension >/tmp/build_extensions.log 2>&1 || exit 1

pass=0
fail=0
failed_names=()

for f in tests/*.txt; do
    name=$(basename "$f" .txt)
    pkill -9 -x fuse 2>/dev/null
    sleep 0.5
    if [ "$name" = "gfx6" ]; then
        RAM_EXTENSION_BIN=build/extensions/cplot_test.bin \
            bash tools/run_suite_test.sh "$name" > "/tmp/run_${name}.log" 2>&1
    elif [ "$name" = "block" ]; then
        RAM_EXTENSION_BIN=build/extensions/block_test.bin \
            bash tools/run_suite_test.sh "$name" > "/tmp/run_${name}.log" 2>&1
    elif [ "$name" = "block_new_clear" ]; then
        RAM_EXTENSION_BIN=build/extensions/block_clear_test.bin \
        RAM_EXTENSION_CLEAR=1 \
            bash tools/run_suite_test.sh "$name" > "/tmp/run_${name}.log" 2>&1
    elif [ "$name" = "extension_register" ]; then
        RAM_EXTENSION_BIN=build/extensions/cplot_test.bin \
        RAM_EXTENSION_SEED_CACHE=1 \
            bash tools/run_suite_test.sh "$name" > "/tmp/run_${name}.log" 2>&1
    elif [ "$name" = "extension_new_clear" ]; then
        RAM_EXTENSION_BIN=build/extensions/cplot_clear_test.bin \
        RAM_EXTENSION_CLEAR=1 \
            bash tools/run_suite_test.sh "$name" > "/tmp/run_${name}.log" 2>&1
    else
        bash tools/run_suite_test.sh "$name" > "/tmp/run_${name}.log" 2>&1
    fi
    rc=$?
    color="?"
    if [ -f "/tmp/suite_${name}.png" ]; then
        color=$(python3 -c "
from PIL import Image
img = Image.open('/tmp/suite_${name}.png')
print(img.getpixel((10,10)))
")
    fi

    verdict="FAIL"
    if [ "$color" = "(0, 194, 0)" ] || [ "$color" = "(0, 181, 0)" ]; then
        verdict="PASS"
    elif { [ "$color" = "(0, 194, 197)" ] || [ "$color" = "(0, 181, 180)" ]; } && is_expected_cyan "$name"; then
        verdict="PASS (expected cyan)"
    elif [ "$color" = "(180, 0, 0)" ] && is_expected_red "$name"; then
        verdict="PASS (expected pre-run rejection)"
    elif [ "$color" = "(0, 0, 0)" ] && is_expected_black "$name"; then
        verdict="PASS (expected unloaded rejection)"
    fi

    echo "${name}: rc=${rc} border=${color} -> ${verdict}"
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
