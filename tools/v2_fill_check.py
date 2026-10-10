#!/usr/bin/env python3
"""R10.7 P5 FILL checks on the production ROM (headless).

Loads build/v2_package_shapes.bin at EXTENSION_MODULE_BASE, paints a test
bitmap into screen RAM, calls the package's real SHAPES_GFX_FILL, and compares
the resulting bitmap with an independent 4-connected flood fill. Also reports
the fill-stack high-water mark (stack area pre-filled with $EE).
Usage: python3 tools/v2_fill_check.py   (after `make build` and building the package)
"""
import sys, struct
sys.path.insert(0, __import__('os').path.dirname(__file__))
from v2_headless import *

import os, subprocess
subprocess.run(["sjasmplus", "--sym=build/v2_package_shapes.sym", "rom/v2_package_shapes.asm"],
               check=True, capture_output=True)       # also refreshes build/v2_package_shapes.bin
if os.path.exists("v2_package_shapes.bin"): os.remove("v2_package_shapes.bin")
PKG = syms("build/v2_package_shapes.sym")
BASE = HSYM["EXTENSION_MODULE_BASE"]
STK, STK_END = HSYM["GFX_FILL_STACK"], HSYM["GFX_FILL_STACK_END"]

def addr(x, y): return 0x4000 | ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | (x >> 3)

def to_bytes(img):
    m = bytearray(6144)
    for y in range(192):
        for x in range(256):
            if img[y][x]: m[addr(x, y) - 0x4000] |= 0x80 >> (x & 7)
    return bytes(m)

def from_bytes(b):
    return [[(b[addr(x, y) - 0x4000] >> (7 - (x & 7))) & 1 for x in range(256)] for y in range(192)]

def flood(img, sx, sy):
    tgt = img[sy][sx]; out = [r[:] for r in img]; seen = {(sx, sy)}; st = [(sx, sy)]
    while st:
        x, y = st.pop(); out[y][x] = 1
        for nx, ny in ((x+1, y), (x-1, y), (x, y+1), (x, y-1)):
            if 0 <= nx < 256 and 0 <= ny < 192 and (nx, ny) not in seen and img[ny][nx] == tgt:
                seen.add((nx, ny)); st.append((nx, ny))
    return out

def blank(): return [[0]*256 for _ in range(192)]
def rect(img, x0, y0, x1, y1):
    for x in range(x0, x1+1): img[y0][x] = img[y1][x] = 1
    for y in range(y0, y1+1): img[y][x0] = img[y][x1] = 1
def circle(img, cx, cy, r):
    x, y, d = 0, r, 1 - r
    while x <= y:
        for dx, dy in ((x,y),(y,x),(-x,y),(-y,x),(x,-y),(y,-x),(-x,-y),(-y,-x)):
            px, py = cx+dx, cy+dy
            if 0 <= px < 256 and 0 <= py < 192: img[py][px] = 1
        x += 1
        if d < 0: d += 2*x + 1
        else: y -= 1; d += 2*(x-y) + 1

def scenarios():
    s = {}
    img = blank(); rect(img, 40, 30, 120, 80); s["rectangle"] = (img, 80, 50)
    img = blank(); circle(img, 100, 96, 50); s["circle-r50"] = (img, 100, 96)
    img = blank(); circle(img, 100, 96, 30); circle(img, 100, 96, 20); s["ring-between"] = (img, 100, 96 - 25)
    img = blank(); s["whole-screen"] = (img, 5, 5)
    img = blank()
    for x in range(8, 248, 4):                       # comb: many parallel walls
        for y in range(8, 184 if (x // 4) % 2 else 100): img[y][x] = 1
    s["comb"] = (img, 2, 2)
    img = blank()
    for x in range(2, 254, 2):                       # finest comb: 1-pixel corridors
        for y in range(8, 184 if (x // 2) % 2 else 100): img[y][x] = 1
    s["fine-comb"] = (img, 1, 2)
    img = blank()
    for y in range(4, 188, 2):                       # horizontal slats with alternating gaps
        for x in range(0, 256):
            if not (x < 3 and (y // 2) % 2) and not (x > 252 and not (y // 2) % 2): img[y][x] = 1
    s["slats"] = (img, 100, 1)
    img = blank(); rect(img, 0, 0, 255, 191); s["screen-border"] = (img, 100, 100)
    img = blank(); rect(img, 60, 60, 90, 90); s["fill-lit-pixel"] = (img, 60, 70)
    img = blank()
    for y in range(0, 192, 2):                       # serpentine corridor
        for x in range(0, 256): img[y][x] = 1
        img[y][255 if (y // 2) % 2 == 0 else 0] = 0
    s["serpentine"] = (img, 100, 1)
    return s

def run(img, sx, sy):
    start()
    D("mem-write", hex(BASE), open("build/v2_package_shapes.bin", "rb").read().hex())
    D("mem-write", "0x4000", to_bytes(img).hex())
    D("mem-write", hex(HSYM["GFX_FILL_X"]), bytes([sx]).hex())
    D("mem-write", hex(HSYM["GFX_FILL_Y"]), bytes([sy]).hex())
    D("mem-write", hex(HSYM["GFX_FILL_ATTR"]), bytes([0x38]).hex())
    n = STK_END - STK
    w = lambda v: struct.pack("<H", v)
    call = lambda t: b"\xCD" + w(t)
    # trampoline: the VM runs packages with EXROM paged out ($C000-$DFFF is RAM
    # then), so poison the fill stack, run FILL, and copy the stack to $9000
    # for inspection, all while EXROM is out.
    body = (call(HSYM["BANK_PAGE_EXROM_OUT"])
            + b"\x21" + w(STK) + b"\x11" + w(STK + 1) + b"\x01" + w(n - 1) + b"\x36\xEE\xED\xB0"
            + call(PKG["SHAPES_GFX_FILL"]))
    done = 0xFE00 + len(body)
    tramp = body + b"\x18\xFE"                    # jr $ -- stop here, EXROM still out,
    D("mem-write", "0xFE00", tramp.hex())          # so the shell never redraws the screen
    D("set-register", "SP", "0xFDF0")
    D("set-register", "PC", "0xFE00")
    D("run", "--until", hex(done), "--max-instructions", "400000000")
    D("pause")
    got = from_bytes(read(0x4000, 6144))
    stk = read(STK, n)
    used = max((i for i, b in enumerate(stk) if b != 0xEE), default=-1) + 1
    D("stop")
    return got, used

fails = 0
for name, (img, sx, sy) in scenarios().items():
    got, used = run(img, sx, sy)
    want = flood(img, sx, sy)
    diff = sum(got[y][x] != want[y][x] for y in range(192) for x in range(256))
    ok = diff == 0
    fails += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}: differing pixels={diff} fill-stack high-water={used} B")
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
