#!/usr/bin/env bash
# tools/run_suite_test.sh — inject one tests/<name>.txt program into the
# reusable rom/test_suite_inject.bin harness via Fuse debugger scripting
# and report its border-color verdict (green=pass, red=fail) via a
# screenshot, for the tests/ directory's own suite.
#
# Usage: tools/run_suite_test.sh <name>
#   reads   tests/<name>.txt
#   builds  rom/test_suite_inject.bin (once — cached; delete it, or its
#           .sym, to force a rebuild after touching basic.asm/kernel/*)
#   shows   /tmp/suite_<name>.png
#
# Replaces the original preload_gen.py --autorun approach (2026-08-22),
# which baked the encoded test program straight into the same 16K ROM
# image as basic.asm — after the Phase 4 dynamic-scalar-pool migration
# (2026-08-23), that pushed individual test_suite_*.asm builds 83-113
# bytes over budget even though basic.asm itself still fit rom/
# test_basic.asm exactly. tools/fuse_suite_inject.py's own header has
# the full writeup: the fix is injecting the test program via the Fuse
# debugger (same technique tools/fuse_load_inject.py already proved for
# SAVE/LOAD) instead of embedding it in the ROM image, so ROM budget is
# permanently decoupled from test-program size. The harness binary
# never needs rebuilding per test any more (nothing test-specific is
# baked into it) — only the tiny .dbg injection script changes.
set -e
cd "$(dirname "$0")/.."

name="$1"
if [ -z "$name" ]; then
    echo "usage: $0 <name>  (reads tests/<name>.txt)" >&2
    exit 1
fi

# Always rebuild: the binary and its symbol table include the live product
# sources/sysvar layout, and stale cached outputs can make address-sensitive
# fixtures test yesterday's ROM instead of today's build.
HARNESS_ROM=test_suite_inject.bin
if [ -n "${RAM_EXTENSION_BIN:-}" ]; then
    if [ -n "${RAM_EXTENSION_CLEAR:-}" ]; then
        tools/sjasmplus_strict.sh rom/test_extension_clear_inject.asm \
            --sym=rom/test_extension_clear_inject.sym
        HARNESS_ROM=test_extension_clear_inject.bin
    else
        tools/sjasmplus_strict.sh rom/test_extension_inject.asm \
            --sym=rom/test_extension_inject.sym
        HARNESS_ROM=test_extension_inject.bin
    fi
else
    tools/sjasmplus_strict.sh rom/test_suite_inject.asm --sym=rom/test_suite_inject.sym
fi

python3 tools/fuse_suite_inject.py "tests/${name}.txt" "/tmp/suite_${name}.dbg"

pkill -9 -f fuse 2>/dev/null || true
sleep 1
DISPLAY=:1 nohup fuse --machine ts2068 \
    --no-sound \
    --rom-ts2068-0 "$HARNESS_ROM" \
    --rom-ts2068-1 exrom.bin \
    --debugger-command "$(cat "/tmp/suite_${name}.dbg")" \
    > "/tmp/fuse_${name}.log" 2>&1 &
disown
sleep 2.5

WIN=$(DISPLAY=:1 xwininfo -root -tree 2>/dev/null | grep -oP '0x[0-9a-f]+(?= "Fuse)')
if [ -z "$WIN" ]; then
    echo "no Fuse window found for ${name}" >&2
    exit 1
fi

# liveness check -- see this project's other run_*_test.sh scripts for
# why: a hung/frozen Fuse instance still shows a valid last-rendered
# frame, indistinguishable from a real result by screenshot alone.
FPID=$(pgrep -f "fuse --machine ts2068 --rom-ts2068-0 $HARNESS_ROM" | head -1)
T1=$(ps -p "$FPID" -o time= 2>/dev/null | tr -d ' ')
sleep 1
T2=$(ps -p "$FPID" -o time= 2>/dev/null | tr -d ' ')
if [ "$T1" = "$T2" ]; then
    echo "WARNING: Fuse CPU time not advancing ($T1) -- possibly hung, retrying once" >&2
    pkill -9 -f fuse 2>/dev/null || true
    sleep 1
    DISPLAY=:1 nohup fuse --machine ts2068 \
        --no-sound \
        --rom-ts2068-0 "$HARNESS_ROM" \
        --rom-ts2068-1 exrom.bin \
        --debugger-command "$(cat "/tmp/suite_${name}.dbg")" \
        > "/tmp/fuse_${name}.log" 2>&1 &
    disown
    sleep 2.5
fi

python3 - "$WIN" "/tmp/suite_${name}.png" <<'PYEOF'
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

echo "screenshot: /tmp/suite_${name}.png"
