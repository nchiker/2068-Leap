#!/usr/bin/env bash
# COMPONENT TEST, NOT a V2 production-integration test: this boots the
# OLD V1 command loop (rom/test_editor_auto.asm includes basic/basic.asm
# and calls BASIC_COMMAND_LOOP directly) against a V1-derived EXROM
# (rom/exrom_build.asm -DEDITOR_TEST_EXROM -> exrom_editor_test.bin).
# It is a legitimate regression test of the shared, still-used generic
# editor engine, but its PASS does NOT prove rom/v2_home.asm/rom/
# v2_exrom.asm (the real V2 production ROM) boots or works -- see
# docs/POST_R9_TEST_INFRASTRUCTURE.md for the full test-target
# classification. This is also the test that visibly shows the OLD V1
# editor in a real Fuse window, which is expected here (it IS a V1
# harness), not a bug.
set -e
cd "$(dirname "$0")/.."

sjasmplus -DEDITOR_TEST_EXROM rom/exrom_build.asm
sjasmplus -DEDITOR_AUTO_OMIT_DEF_FN --sym=build/test_editor_auto.sym rom/test_editor_auto.asm
case_name="${1:-wrap}"
python3 tools/fuse_editor_inject.py build/test_editor_auto.sym /tmp/editor_auto.dbg "$case_name"

pkill -9 -f fuse 2>/dev/null || true
sleep 1
DISPLAY=:1 nohup fuse --machine ts2068 \
    --rom-ts2068-0 test_editor_auto.bin \
    --rom-ts2068-1 exrom_editor_test.bin \
    --debugger-command "$(< /tmp/editor_auto.dbg)" \
    > /tmp/fuse_editor_auto.log 2>&1 &
disown
sleep 3

WIN=$(DISPLAY=:1 xwininfo -root -tree 2>/dev/null | grep -oP '0x[0-9a-f]+(?= "Fuse)' | head -1)
if [ -z "$WIN" ]; then
    echo "no Fuse window found" >&2
    exit 1
fi

python3 - "$WIN" <<'PYEOF'
import sys
from Xlib import X, display

d = display.Display()
w = d.create_resource_object("window", int(sys.argv[1], 16))
raw = w.get_image(0, 0, 640, 480, X.ZPixmap, 0xffffffff)
pixel = raw.data[0:4]
# Fuse's border fills the top-left pixel; BGRX values used by the suite.
rgb = (pixel[2], pixel[1], pixel[0])
if rgb in ((0, 194, 0), (0, 181, 0)):
    print("editor_auto: PASS")
elif rgb == (194, 0, 0):
    print("editor_auto: FAIL (red border)")
    raise SystemExit(1)
else:
    print(f"editor_auto: FAIL (unexpected border {rgb})")
    raise SystemExit(1)
PYEOF
