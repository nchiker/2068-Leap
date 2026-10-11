#!/usr/bin/env bash
# R10.9 Phase 1 -- production-ROM regression gate + strict known-defect suite
# (+ R10.9 Phase 2C: the Array Store gate, tools/v2_prod_arrays.py).
#
# All three suites boot the real production image (build/ts2068rom_zesarux.bin) under ZEsarUX
# through ts2068-debug (headless, no Fuse, no X11) many times, so they run concurrently on
# separate ZEsarUX ports and state directories.  Exit status is non-zero if the gate has
# any FAIL, or the known-defect suite has any FAIL or XPASS (a defect that silently
# stopped reproducing).  XFAIL lines are reproduced KNOWN defects, not failures: see
# docs/v2/TESTING.md and docs/v2/R10_9_PHASE1_REPORT.md.
#
# Needs `make build v2-packages` first (the `test` target does that).
set -uo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
cleanup() {
    for d in "$tmp"/state-*; do
        [ -d "$d" ] && TS2068_DEBUG_STATE_DIR="$d" ts2068-debug --json stop >/dev/null 2>&1
    done
    rm -rf "$tmp"
}
trap cleanup EXIT

# Build the SHAPES package + symbols once, before the two suites read them.
sjasmplus --sym=build/v2_package_shapes.sym rom/v2_package_shapes.asm >/dev/null || exit 1
rm -f v2_package_shapes.bin
export V2_FILL_NO_REBUILD=1

run_suite() {   # name port script
    TS2068_DEBUG_STATE_DIR="$tmp/state-$1" TS2068_V2_PORT="$2" python3 "$3" >"$tmp/$1.log" 2>&1
    echo $? >"$tmp/$1.rc"
}
mkdir -p "$tmp/state-gate" "$tmp/state-defects" "$tmp/state-arrays" "$tmp/state-saveall"
run_suite gate 10241 tools/v2_prod_regress.py &
run_suite defects 10242 tools/v2_known_defects.py &
run_suite arrays 10243 tools/v2_prod_arrays.py &
run_suite saveall 10244 tools/v2_saveall_checks.py &     # RC: SAVE ... ALL round trips and refusals
wait

echo "===== production-ROM regression gate (tools/v2_prod_regress.py) ====="
cat "$tmp/gate.log"
echo
echo "===== Array Store gate (tools/v2_prod_arrays.py) ====="
cat "$tmp/arrays.log"
echo
echo "===== known-defect suite, strict expected failures (tools/v2_known_defects.py) ====="
cat "$tmp/defects.log"
echo
echo "===== SAVE ... ALL suite (tools/v2_saveall_checks.py) ====="
cat "$tmp/saveall.log"
rc=0
[ "$(cat "$tmp/gate.rc")" = 0 ] || { echo "GATE FAILED" >&2; rc=1; }
[ "$(cat "$tmp/arrays.rc")" = 0 ] || { echo "ARRAY STORE GATE FAILED" >&2; rc=1; }
[ "$(cat "$tmp/defects.rc")" = 0 ] || { echo "KNOWN-DEFECT SUITE: unexpected result (FAIL or XPASS)" >&2; rc=1; }
[ "$(cat "$tmp/saveall.rc")" = 0 ] || { echo "SAVE ... ALL SUITE FAILED" >&2; rc=1; }
exit $rc
