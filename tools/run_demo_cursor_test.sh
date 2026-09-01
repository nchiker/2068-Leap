#!/usr/bin/env bash
# Regression for the post-load/editor-entry ghost cursor.  The showcase has
# enough statements, including differing wrap widths around the viewport
# boundary, to expose a stale ROW_COUNT_CACHE: its first cursor draw used to
# target row 0 instead of the blank append line at row 22.
set -euo pipefail
cd "$(dirname "$0")/.."

tools/sjasmplus_strict.sh rom/demo_inject.asm --sym=rom/demo_inject.sym
python3 tools/fuse_demo_inject.py demos/showcase.txt /tmp/demo_cursor_test.dbg

cursor_addr="$(sed -n \
    's/^GFX_INVERT_ATTR: EQU 0x0000\([0-9A-Fa-f]*\)$/\1/p' \
    rom/demo_inject.sym)"
if [ -z "$cursor_addr" ]; then
    echo "demo_cursor: missing GFX_INVERT_ATTR symbol" >&2
    exit 1
fi

cat >>/tmp/demo_cursor_test.dbg <<EOF
breakpoint 0x${cursor_addr}
commands 2
exit (z80:b != 22) || (z80:c != 0)
end
EOF

pkill -9 -x fuse 2>/dev/null || true
if DISPLAY=:1 timeout 20s fuse --machine ts2068 \
    --rom-ts2068-0 demo_inject.bin \
    --rom-ts2068-1 exrom.bin \
    --debugger-command "$(< /tmp/demo_cursor_test.dbg)"; then
    echo "demo_cursor: PASS (first cursor at row 22, column 0)"
else
    status=$?
    echo "demo_cursor: FAIL (Fuse exit $status)" >&2
    exit "$status"
fi
