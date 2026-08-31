#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

extra_defs=()
home_rom=test_storage_named_load.bin
home_source=rom/test_storage_named_load.asm
test_name=storage_named_load
case "${1:-program}" in
    program) ;;
    extension)
        extra_defs=(-DSTORAGE_TEST_EXTENSION)
        home_rom=test_storage_extension_load.bin
        test_name=storage_extension_load
        ;;
    extension_bad_length)
        extra_defs=(-DSTORAGE_TEST_EXTENSION -DSTORAGE_TEST_INVALID -DSTORAGE_TEST_BAD_LENGTH)
        home_rom=test_storage_extension_load.bin
        test_name=storage_extension_bad_length
        ;;
    extension_bad_version)
        extra_defs=(-DSTORAGE_TEST_EXTENSION -DSTORAGE_TEST_INVALID -DSTORAGE_TEST_BAD_VERSION)
        home_rom=test_storage_extension_load.bin
        test_name=storage_extension_bad_version
        ;;
    extension_wildcard)
        extra_defs=(-DSTORAGE_TEST_EXTENSION -DSTORAGE_TEST_WILDCARD)
        home_rom=test_storage_extension_load.bin
        test_name=storage_extension_wildcard
        ;;
    extension_save_missing)
        extra_defs=(-DSTORAGE_TEST_EXTENSION -DSTORAGE_TEST_SAVE_MISSING)
        home_rom=test_storage_extension_load.bin
        test_name=storage_extension_save_missing
        ;;
    extension_roundtrip)
        extra_defs=(-DSTORAGE_TEST_EXTENSION -DSTORAGE_TEST_ROUNDTRIP -DSTORAGE_TEST_FAKE_SEND)
        home_rom=test_storage_extension_roundtrip.bin
        home_source=rom/test_storage_extension_roundtrip.asm
        test_name=storage_extension_roundtrip
        ;;
    autorun_roundtrip)
        extra_defs=(-DSTORAGE_TEST_ROUNDTRIP -DSTORAGE_TEST_FAKE_SEND)
        home_rom=test_storage_autorun_roundtrip.bin
        home_source=rom/test_storage_autorun_roundtrip.asm
        test_name=storage_autorun_roundtrip
        ;;
    autorun_zero|autorun_trailing|autorun_out_of_range)
        extra_defs=(-DSTORAGE_TEST_ROUNDTRIP -DSTORAGE_TEST_FAKE_SEND)
        case "$1" in
            autorun_zero) extra_defs+=(-DSTORAGE_TEST_AUTORUN_INVALID -DSTORAGE_TEST_AUTORUN_ZERO) ;;
            autorun_trailing) extra_defs+=(-DSTORAGE_TEST_AUTORUN_INVALID -DSTORAGE_TEST_AUTORUN_TRAILING) ;;
            autorun_out_of_range) extra_defs+=(-DSTORAGE_TEST_AUTORUN_OUT_OF_RANGE) ;;
        esac
        home_rom=test_storage_autorun_roundtrip.bin
        home_source=rom/test_storage_autorun_roundtrip.asm
        test_name="storage_$1"
        ;;
    *)
        echo "unknown storage test mode: $1" >&2
        exit 2
        ;;
esac
tools/sjasmplus_strict.sh -DSTORAGE_TEST_FAKE_RECEIVE "${extra_defs[@]}" rom/exrom_build.asm
tools/sjasmplus_strict.sh -DEDITOR_AUTO_OMIT_DEF_FN "${extra_defs[@]}" "$home_source"
pkill -9 -x fuse 2>/dev/null || true
DISPLAY=:1 fuse --no-sound --machine ts2068 \
    --rom-ts2068-0 "$home_rom" \
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
    echo "${test_name}: border=${color} -> FAIL"
    exit 1
fi
echo "${test_name}: border=${color} -> PASS"
