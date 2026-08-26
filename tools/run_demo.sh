#!/usr/bin/env bash
# tools/run_demo.sh — inject a demos/<name>.txt program into the
# reusable rom/demo_inject.bin harness via Fuse debugger scripting and
# launch it, dropped straight into the real interactive editor with
# the program already loaded (LIST/RUN/edit all work normally from
# there) — a screenshot of the loaded state, but the launched Fuse
# window is left running for interactive use rather than killed.
#
# Usage: tools/run_demo.sh <name>
#   reads   demos/<name>.txt
#   builds  rom/demo_inject.bin (once — cached; delete it, or its
#           .sym, to force a rebuild after touching basic.asm/kernel/*)
#   shows   /tmp/demo_<name>.png
#
# See rom/demo_inject.asm and tools/fuse_demo_inject.py's own headers
# for the full "why" — same Fuse-debugger-injection technique tools/
# run_suite_test.sh uses for the regression suite, adapted to drop into
# the real editor instead of running once and hanging. No ROM-baked
# size limit and no tools/fuse_load_inject.py-style 255-byte cap; real
# ceiling is whatever fits the dynamic pool (currently up to 1871
# bytes of program text).
set -e
cd "$(dirname "$0")/.."

name="$1"
if [ -z "$name" ]; then
    echo "usage: $0 <name>  (reads demos/<name>.txt)" >&2
    exit 1
fi

if [ ! -f rom/demo_inject.bin ] || [ ! -f rom/demo_inject.sym ]; then
    sjasmplus rom/demo_inject.asm --sym=rom/demo_inject.sym
fi

python3 tools/fuse_demo_inject.py "demos/${name}.txt" "/tmp/demo_${name}.dbg"

pkill -9 -f fuse 2>/dev/null || true
sleep 1
DISPLAY=:1 nohup fuse --machine ts2068 \
    --rom-ts2068-0 demo_inject.bin \
    --rom-ts2068-1 exrom.bin \
    --debugger-command "$(cat "/tmp/demo_${name}.dbg")" \
    > "/tmp/fuse_demo_${name}.log" 2>&1 &
disown
sleep 2.5

WIN=$(DISPLAY=:1 xwininfo -root -tree 2>/dev/null | grep -oP '0x[0-9a-f]+(?= "Fuse)')
if [ -z "$WIN" ]; then
    echo "no Fuse window found for ${name}" >&2
    exit 1
fi

python3 - "$WIN" "/tmp/demo_${name}.png" <<'PYEOF'
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

echo "screenshot: /tmp/demo_${name}.png"
echo "Fuse is still running (PID $(pgrep -f "fuse --machine ts2068 --rom-ts2068-0 demo_inject.bin" | head -1)) — interact with it directly, or 'pkill -9 -f fuse' when done."
