#!/usr/bin/env bash
# Run the complete timed showcase and require its final green border.
set -euo pipefail
cd "$(dirname "$0")/.."

sjasmplus rom/test_suite_inject.asm --sym=rom/test_suite_inject.sym
python3 tools/fuse_suite_inject.py demos/showcase.txt /tmp/showcase_validation.dbg
pkill -9 -x fuse 2>/dev/null || true
sleep 1
DISPLAY=:1 nohup fuse --no-sound --machine ts2068 \
    --rom-ts2068-0 test_suite_inject.bin \
    --rom-ts2068-1 exrom.bin \
    --debugger-command "$(< /tmp/showcase_validation.dbg)" \
    >/tmp/fuse_showcase_validation.log 2>&1 &
fuse_pid=$!
# Collision sound pauses make total duration depend on how many sprite
# overlaps occur; allow the worst case plus emulator startup margin.
sleep 35

win="$(DISPLAY=:1 xwininfo -root -tree 2>/dev/null | grep -oP '0x[0-9a-f]+(?= "Fuse)' | head -1 || true)"
if [ -z "$win" ]; then
    echo "showcase: no Fuse window found" >&2
    exit 1
fi

python3 - "$win" <<'PYEOF'
import sys
from Xlib import X, display

d = display.Display()
w = d.create_resource_object("window", int(sys.argv[1], 16))
raw = w.get_image(0, 0, 640, 480, X.ZPixmap, 0xffffffff)
pixel = raw.data[:4]
rgb = (pixel[2], pixel[1], pixel[0])
print(f"showcase: final border={rgb}")
if rgb != (0, 194, 0):
    raise SystemExit(1)
PYEOF

kill -9 "$fuse_pid" 2>/dev/null || true
wait "$fuse_pid" 2>/dev/null || true
