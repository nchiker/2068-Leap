#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

sjasmplus -DSTORAGE_TEST_FAKE_RECEIVE rom/exrom_build.asm
sjasmplus -DEDITOR_AUTO_OMIT_DEF_FN rom/test_storage_named_load.asm
pkill -9 -x fuse 2>/dev/null || true
DISPLAY=:1 fuse --no-sound --machine ts2068 \
    --rom-ts2068-0 test_storage_named_load.bin \
    --rom-ts2068-1 exrom_storage_test.bin >/tmp/storage_named_load.log 2>&1 &
fuse_pid=$!
trap 'kill -9 "$fuse_pid" 2>/dev/null || true' EXIT
sleep 2.5
win="$(DISPLAY=:1 xwininfo -root -tree 2>/dev/null | grep -oP '0x[0-9a-f]+(?= "Fuse)' | head -1 || true)"
if [ -z "$win" ]; then
    win="$(DISPLAY=:1 python3 - <<'PYEOF'
from Xlib import X, display
d = display.Display()
for w in d.screen().root.query_tree().children:
    g = w.get_geometry()
    if w.get_attributes().map_state == X.IsViewable and (g.width, g.height) == (640, 480):
        print(hex(w.id))
        break
PYEOF
)"
fi
test -n "$win"
color="$(python3 - "$win" <<'PYEOF'
import sys
from Xlib import X, display
d = display.Display()
w = d.create_resource_object('window', int(sys.argv[1], 16))
raw = w.get_image(0, 0, 640, 480, X.ZPixmap, 0xffffffff)
from PIL import Image
image = Image.frombytes('RGBX', (640, 480), raw.data, 'raw', 'BGRX').convert('RGB')
print(image.getpixel((10, 10)))
PYEOF
)"
if [ "$color" != "(0, 194, 0)" ] && [ "$color" != "(0, 181, 0)" ]; then
    echo "storage_named_load: border=${color} -> FAIL"
    exit 1
fi
echo "storage_named_load: border=${color} -> PASS"
