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

EXPECTED_CYAN="err1 mem2 snd3"

is_expected_cyan() {
    local name="$1"
    for n in $EXPECTED_CYAN; do
        [ "$n" = "$name" ] && return 0
    done
    return 1
}

pass=0
fail=0
failed_names=()

for f in tests/*.txt; do
    name=$(basename "$f" .txt)
    pkill -9 -x fuse 2>/dev/null
    sleep 0.5
    bash tools/run_suite_test.sh "$name" > "/tmp/run_${name}.log" 2>&1
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
    if [ "$color" = "(0, 194, 0)" ]; then
        verdict="PASS"
    elif [ "$color" = "(0, 194, 197)" ] && is_expected_cyan "$name"; then
        verdict="PASS (expected cyan)"
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
