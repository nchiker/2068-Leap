#!/usr/bin/env bash
# tools/run_storage_roundtrip_test.sh — build + run the SAVE/LOAD
# regression test (tools/fuse_load_inject.py's *_roundtrip.asm output)
# and report its border-color verdict (green=pass, red=fail) via a
# screenshot. Same shape as tools/run_suite_test.sh, adapted for the
# one difference this test needs: Fuse must be launched with the
# matching --debugger-command script, or SAVE/LOAD hit the real
# (currently unreliable, see Track B) pulse-timing path instead of the
# Track A injection this test is actually checking.
#
# Usage: tools/run_storage_roundtrip_test.sh <name>
#   reads   tests/<name>.txt
#   builds  rom/test_<name>_roundtrip.asm / .bin (+ .dbg, _check.asm —
#           byproducts of the same generator, not used by this script)
#   shows   /tmp/roundtrip_<name>.png
#
# Assumes exrom.bin is already built and current (sjasmplus rom/
# exrom_build.asm) — same assumption tools/run_suite_test.sh makes for
# rom1.bin, not rebuilt here on every run.
set -e
cd "$(dirname "$0")/.."

name="$1"
if [ -z "$name" ]; then
    echo "usage: $0 <name>  (reads tests/<name>.txt)" >&2
    exit 1
fi

python3 tools/fuse_load_inject.py "tests/${name}.txt" "rom/test_${name}"
sjasmplus "rom/test_${name}_roundtrip.asm"

pkill -9 -f fuse 2>/dev/null || true
sleep 1
DISPLAY=:1 nohup fuse --machine ts2068 \
    --rom-ts2068-0 "test_${name}_roundtrip.bin" \
    --rom-ts2068-1 exrom.bin \
    --debugger-command "$(cat "rom/test_${name}.dbg")" \
    > "/tmp/fuse_roundtrip_${name}.log" 2>&1 &
disown
sleep 2.5

WIN=$(DISPLAY=:1 xwininfo -root -tree 2>/dev/null | grep -oP '0x[0-9a-f]+(?= "Fuse)')
if [ -z "$WIN" ]; then
    echo "no Fuse window found for ${name}" >&2
    exit 1
fi

# liveness check -- see tools/run_suite_test.sh's own comment on why:
# a hung/frozen Fuse instance still shows a valid last-rendered frame,
# indistinguishable from a real result by screenshot alone.
FPID=$(pgrep -f "fuse --machine ts2068 --rom-ts2068-0 test_${name}_roundtrip.bin" | head -1)
T1=$(ps -p "$FPID" -o time= 2>/dev/null | tr -d ' ')
sleep 1
T2=$(ps -p "$FPID" -o time= 2>/dev/null | tr -d ' ')
if [ "$T1" = "$T2" ]; then
    echo "WARNING: Fuse CPU time not advancing ($T1) -- possibly hung, retrying once" >&2
    pkill -9 -f fuse 2>/dev/null || true
    sleep 1
    DISPLAY=:1 nohup fuse --machine ts2068 \
        --rom-ts2068-0 "test_${name}_roundtrip.bin" \
        --rom-ts2068-1 exrom.bin \
        --debugger-command "$(cat "rom/test_${name}.dbg")" \
        > "/tmp/fuse_roundtrip_${name}.log" 2>&1 &
    disown
    sleep 2.5
fi

python3 - "$WIN" "/tmp/roundtrip_${name}.png" <<'PYEOF'
import sys
from Xlib import display, X
from PIL import Image

win_id = int(sys.argv[1], 16)
out = sys.argv[2]
d = display.Display()
win = d.create_resource_object('window', win_id)
raw = win.get_image(0, 0, 640, 480, X.ZPixmap, 0xffffffff)
img = Image.frombytes('RGBX', (640, 480), raw.data, 'raw', 'BGRX')
img.convert('RGB').save(out)
PYEOF

echo "screenshot: /tmp/roundtrip_${name}.png"
