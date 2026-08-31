#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tools/sjasmplus_strict.sh --sym=rom/test_stack_audit.sym -DSTACK_AUDIT rom/test_suite_inject.asm
STACK_AUDIT=1 python3 tools/fuse_suite_inject.py tools/fixtures/stack_stress.txt /tmp/stack_audit.dbg
pkill -9 -x fuse 2>/dev/null || true
DISPLAY=:1 fuse --no-sound --machine ts2068 \
    --rom-ts2068-0 test_stack_audit.bin --rom-ts2068-1 exrom.bin \
    --debugger-command "$(cat /tmp/stack_audit.dbg)" >/tmp/stack_audit.log 2>&1 &
fuse_pid=$!
trap 'kill -9 "$fuse_pid" 2>/dev/null || true' EXIT
sleep 3
win="$(DISPLAY=:1 xwininfo -root -tree 2>/dev/null | grep -oP '0x[0-9a-f]+(?= "Fuse)' | head -1 || true)"
DISPLAY=:1 python3 - "$win" <<'PYEOF'
import sys
from Xlib import X, display
from PIL import Image
d = display.Display()
w = d.create_resource_object('window', int(sys.argv[1], 16))
raw = w.get_image(0, 0, 640, 480, X.ZPixmap, 0xffffffff)
Image.frombytes('RGBX', (640, 480), raw.data, 'raw', 'BGRX').convert('RGB').save('/tmp/stack_audit.png')
PYEOF
echo "stack audit screenshot: /tmp/stack_audit.png"
