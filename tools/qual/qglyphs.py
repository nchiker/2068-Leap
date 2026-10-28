#!/usr/bin/env python3
"""Q-26 (docs/V2_DEFECT_REGISTER.md): every printable ASCII character has a glyph.

Calls GFX_CHAR_TO_FONT_OFFSET (package service slot 2) for each code 0-255 on the built ROM and
reads the 8 bytes it points to. Each code from ' ' to '~' must give carry clear and the bytes the
font source (kernel/graphics/graphics.asm FONT_TABLE, a `; 'c'` comment before each glyph) gives for
it; 0-31 and 127 carry set. With --ref TREE (a built tree from before the change), every other code
(128-255: block graphics, UDGs, none) must give the same carry and bytes there as here.

Usage: python3 tools/qual/qglyphs.py [--tree DIR] [--ref TREE] [--port N]
"""
import argparse
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine, HARNESS_RET_SLOT          # noqa: E402

SLOT = 0x009C                       # GFX_CHAR_TO_FONT_OFFSET (docs/PACKAGE_ABI.md s3)


def source_glyphs(tree):
    text = open(os.path.join(tree, "kernel", "graphics", "graphics.asm"), encoding="latin-1").read()
    block = text[text.index("\nFONT_TABLE:") + 1:]
    out, want = {}, None
    for line in block.splitlines()[1:]:
        m = re.match(r"\s*;\s*'(.|'|\\\\)'", line)
        if m:
            want = "\\" if m.group(1) == "\\\\" else m.group(1)
            continue
        m = re.match(r"\s*DB\s+(.+)", line)
        if m and want is not None:
            out[want] = bytes(int(x.strip().lstrip("$"), 16) for x in m.group(1).split(";")[0].split(","))
            want = None
        elif re.match(r"\S", line):
            break
    return out


def lookups(tree, port):
    m = Machine(tree, port)
    m.start()
    res = {}
    try:
        for code in range(256):
            m.restore()
            stub = bytes([0x3E, code, 0xCD]) + struct.pack("<H", SLOT) + b"\x18\xFE"
            m.write(0xFE10, stub)
            m.setreg("SP", HARNESS_RET_SLOT)
            m.setreg("PC", 0xFE10)
            m.set_bps([0xFE10 + len(stub) - 2])
            m.run(200_000)
            r = m.regs()
            cf = r["AF"] & 1
            res[code] = (cf, None if cf else m.read(r["HL"], 8))
    finally:
        m.stop()
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=os.getcwd())
    ap.add_argument("--ref")
    ap.add_argument("--port", type=int, default=10350)
    a = ap.parse_args()
    font = source_glyphs(a.tree)
    got = lookups(a.tree, a.port)
    fails = []
    for code in range(256):
        cf, data = got[code]
        if 32 <= code <= 126:
            want = font.get(chr(code))
            if want is None or cf or data != want:
                fails.append("%3d %r: carry %d bytes %s (font source %s)" % (
                    code, chr(code), cf, data.hex() if data else "-", want.hex() if want else "none"))
        elif code < 128 and not cf:
            fails.append("%3d: a glyph where there should be none" % code)
    n = 256
    if a.ref:
        ref = lookups(a.ref, a.port + 1)
        for code in range(128, 256):
            if ref[code] != got[code]:
                fails.append("%3d: differs from the reference (%s / %s)" % (code, ref[code], got[code]))
    for f in fails:
        print("FAIL", f)
    print("qglyphs: %d codes, %d printable with their source glyph, %s; %d problem(s)" % (
        n, sum(1 for c in range(32, 127) if not got[c][0]), "128-255 as the reference" if a.ref else
        "no reference", len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
