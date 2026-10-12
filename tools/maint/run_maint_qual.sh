#!/usr/bin/env bash
# V2 maintenance qualification (make qual-maint, part of make test): the BEEP / SOUND / PAUSE /
# CBEEP suites of the maintenance release, on this tree's production image (build/, after
# `make build v2-packages`). Headless (ZEsarUX through ts2068-debug, as make qual). The four
# suites run concurrently on separate emulator ports; logs and JSON in build/maint-qual/.
#   tools/maint/ay_beep_tests.py   AY BEEP (all 130 semitones), SOUND 0..17, BEEP/SOUND sharing,
#                                  BREAK during BEEP and PAUSE, PAUSE across the FRAMES rollover
#   tools/maint/cbeep_tests.py     the cbeep package: pitch/cycles model, timing, border, errors
#   tools/maint/cbeep_tape_test.py the cbeep package through the real tape receiver
#   tools/maint/di_wait_tests.py   PAUSE/BEEP/CBEEP with the frame interrupt unavailable
set -uo pipefail
cd "$(dirname "$0")/../.."
out=build/maint-qual
rm -rf "$out"; mkdir -p "$out"
state=$(mktemp -d)
trap 'TS2068_DEBUG_STATE_DIR="$state" ts2068-debug --json stop >/dev/null 2>&1; rm -rf "$state"' EXIT
python3 tools/maint/ay_beep_tests.py . --port 10960 --json "$out/ay_beep.json" >"$out/ay_beep.log" 2>&1 &
p1=$!
python3 tools/maint/cbeep_tests.py . --port 11010 --json "$out/cbeep.json" >"$out/cbeep.log" 2>&1 &
p2=$!
python3 tools/maint/di_wait_tests.py . --port 11050 --json "$out/di_wait.json" >"$out/di_wait.log" 2>&1 &
p3=$!
TS2068_DEBUG_STATE_DIR="$state" TS2068_V2_PORT=11020 python3 tools/maint/cbeep_tape_test.py >"$out/cbeep_tape.log" 2>&1 &
p4=$!
rc=0
for x in "ay_beep:$p1" "cbeep:$p2" "di_wait:$p3" "cbeep_tape:$p4"; do
    n=${x%%:*}; pid=${x##*:}
    if wait "$pid"; then s=PASS; else s=FAIL; rc=1; fi
    echo "maint-qual $n: $s -- $(tail -1 "$out/$n.log")"
done
[ $rc -eq 0 ] || grep -h "^FAIL" "$out"/*.log
exit $rc
