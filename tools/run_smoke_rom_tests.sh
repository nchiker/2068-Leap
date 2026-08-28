#!/usr/bin/env bash
# Execute deterministic standalone smoke ROMs and check their border verdict.
set -euo pipefail

cd "$(dirname "$0")/.."

tests=(
    test_memory
    test_math
    test_editor_ops
    test_calc_smoke_endcalc
    test_calc_smoke_stackops
    test_calc_smoke_arithmetic
    test_calc_smoke_division
    test_calc_smoke_dupoverflow
    test_calc_smoke_unimpl
)
pass=0
fail=0

for name in "${tests[@]}"; do
    rom_path="build/smoke/${name}.bin"
    screenshot="/tmp/smoke_${name}.png"
    log_path="/tmp/fuse_smoke_${name}.log"

    if [ ! -f "$rom_path" ]; then
        echo "smoke-runtime: missing ${rom_path}; run make smoke-build" >&2
        exit 1
    fi

    pkill -9 -x fuse 2>/dev/null || true
    sleep 1
    DISPLAY=:1 nohup fuse --no-sound --machine ts2068 \
        --rom-ts2068-0 "$rom_path" \
        --rom-ts2068-1 exrom.bin \
        > "$log_path" 2>&1 &
    fuse_pid=$!
    sleep 2.5

    win="$(DISPLAY=:1 xwininfo -root -tree 2>/dev/null | grep -oP '0x[0-9a-f]+(?= "Fuse)' | head -1 || true)"
    if [ -z "$win" ]; then
        # SDL2/X11 can expose a mapped Fuse surface without a WM title.
        # Fall back to the emulator's exact configured 640x480 window.
        win="$(DISPLAY=:1 python3 - <<'PYEOF'
from Xlib import display, X
d = display.Display()
for w in d.screen().root.query_tree().children:
    g = w.get_geometry()
    if w.get_attributes().map_state == X.IsViewable and (g.width, g.height) == (640, 480):
        print(hex(w.id))
        break
PYEOF
)"
    fi
    if [ -z "$win" ]; then
        echo "${name}: no Fuse window found -> FAIL"
        fail=$((fail + 1))
        kill -9 "$fuse_pid" 2>/dev/null || true
        wait "$fuse_pid" 2>/dev/null || true
        continue
    fi

    color="$(python3 - "$win" "$screenshot" <<'PYEOF'
import sys
from Xlib import X, display
from PIL import Image

window_id = int(sys.argv[1], 16)
output = sys.argv[2]
connection = display.Display()
window = connection.create_resource_object("window", window_id)
raw = window.get_image(0, 0, 640, 480, X.ZPixmap, 0xFFFFFFFF)
image = Image.frombytes("RGBX", (640, 480), raw.data, "raw", "BGRX").convert("RGB")
image.save(output)
print(image.getpixel((10, 10)))
PYEOF
)"

    verdict="FAIL"
    if [ "$color" = "(0, 194, 0)" ] || [ "$color" = "(0, 181, 0)" ]; then
        verdict="PASS"
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
    echo "${name}: border=${color} -> ${verdict}"
    kill -9 "$fuse_pid" 2>/dev/null || true
    wait "$fuse_pid" 2>/dev/null || true
done

echo "----------------------------------------"
echo "SMOKE PASS: ${pass}  FAIL: ${fail}"
[ "$fail" -eq 0 ]
