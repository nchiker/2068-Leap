#!/usr/bin/env python3
"""LINE and PLOT's pixels and colours against a model and against the previous ROM (v2.1.1).

v2.1.1 replaced V2's GFX_LINE (memory cells, two MATH_COMPARE16 calls and a full address per pixel)
with Leap-C delta D25 (2068-Leap-C 1.2.0; 2068-Forth v2.0's major-axis loop), and fixed the mode 1
colour address (issue #5: a pixel's 8x1 colour byte is its bitmap byte + $2000).

The model: each end moved to the nearest edge (v2.1.1; v2.1.0 took x by its low byte and clamped y's
low byte to 191, so with --ref the off-screen lines are left out of the old-against-new comparisons and
the model of the old ROM uses the old rule), then the points of the e2 form of Bresenham's line (err = dx - dy; e2 = 2 err; x steps when e2 >= -dy,
y when e2 <= dx), both ends drawn. Each point is set (OR; OVER 1: XOR) and colours its cell with the
print attribute: in mode 0 the 8x8 cell at $5800, in mode 1 the 8x1 byte at the bitmap byte + $2000.

Each case is a BASIC program of LINE statements (random ends, the edges, every octant), in mode 0 and
mode 1, OVER 0 and 1, with changing INK, PAPER and BRIGHT. Checks:
  --ref DIR (a tree built from the v2.1.0-emu.1 tag): the model against the old ROM, mode 0 (bitmap
            and attributes) and mode 1 (bitmap only: its colours were the defect), so the model is
            shown to be the old LINE; then the new ROM's bitmap and attributes against the old ROM's.
  always:   the new ROM (--tree, default this tree) against the model: bitmap, attributes and, in mode 1,
            the second display file, byte for byte.
  --plot:   PLOT at every y of a few character rows, in both modes, against the model.

Usage: python3 tools/qual/qlines.py [--tree DIR] [--ref DIR] [--seed N] [--lines N] [--port N]
Exit status 0 when everything matches, 1 otherwise.
"""
import argparse
import math
import os
import random
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from qharness import Machine  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
PER_PROGRAM = 30


OLD_ENDS = False      # --old-ends: v2.1.0's OP_LINE (x by its low byte, y's low byte clamped to 191)


def clamp(v, hi):
    return 0 if v < 0 else hi if v > hi else v


def line_ends(x0, y0, x1, y1):
    """OP_LINE: since v2.1.1 each end is moved to the nearest edge, as PLOT's are."""
    if OLD_ENDS:
        def fy(v):
            v &= 255
            return 191 if v > 191 else v
        return x0 & 255, fy(y0), x1 & 255, fy(y1)
    return clamp(x0, 255), clamp(y0, 191), clamp(x1, 255), clamp(y1, 191)


def line_points(x0, y0, x1, y1):
    x0, y0, x1, y1 = line_ends(x0, y0, x1, y1)
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx - dy
    pts = []
    while True:
        pts.append((x0, y0))
        if x0 == x1 and y0 == y1:
            return pts
        e2 = 2 * err
        if e2 >= -dy:
            err -= dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def pixel_offset(x, y):
    return ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | (x >> 3)


class Screen:
    """After CLS in INK 0, PAPER 7 (and MODE 1: every 8x1 colour byte $38)."""

    def __init__(self):
        self.bitmap = bytearray(6144)
        self.attrs = bytearray([0x38]) * 768
        self.hires = bytearray([0x38]) * 6144

    def point(self, x, y, attr, over, mode):
        o = pixel_offset(x, y)
        mask = 0x80 >> (x & 7)
        self.bitmap[o] = self.bitmap[o] ^ mask if over else self.bitmap[o] | mask
        if mode:
            self.hires[o] = attr
        else:
            self.attrs[(y >> 3) * 32 + (x >> 3)] = attr

    def line(self, ends, attr, over, mode):
        for x, y in line_points(*ends):
            self.point(x, y, attr, over, mode)


def attr_of(ink, paper, bright):
    return bright << 6 | paper << 3 | ink


def gen_lines(rng, n):
    fixed = [(0, 0, 255, 191), (255, 191, 0, 0), (0, 191, 255, 0), (0, 0, 255, 0), (0, 191, 255, 191),
             (0, 0, 0, 191), (255, 0, 255, 191), (128, 96, 128, 96), (0, 0, 0, 0), (255, 191, 255, 191),
             (7, 7, 8, 8), (8, 7, 7, 8), (10, 20, 100, 20), (10, 10, 100, 60), (40, 40, 215, 40),
             (40, 95, 215, 95), (0, 63, 255, 64), (3, 0, 4, 191), (100, 191, 101, 0), (200, 150, 10, 149)]
    for a in range(0, 360, 15):
        fixed.append((128, 96, 128 + round(90 * math.cos(math.radians(a))), 96 + round(90 * math.sin(math.radians(a)))))
    lines = list(fixed)
    while len(lines) < len(fixed) + n:
        if rng.random() < 0.85:
            lines.append((rng.randrange(256), rng.randrange(192), rng.randrange(256), rng.randrange(192)))
        else:   # an end off the screen: moved to the edge (v2.1.0: x wrapped, y's low byte clamped)
            lines.append((rng.randrange(-200, 460), rng.randrange(-50, 300), rng.randrange(-200, 460),
                          rng.randrange(-50, 300)))
    return lines


def on_screen(ln):
    return all(0 <= v <= 255 for v in ln[0::2]) and all(0 <= v <= 191 for v in ln[1::2])


def gen_cases(rng, lines):
    """Lines with every end on the screen and lines with an end off it go in separate programs."""
    groups = (("on", [ln for ln in lines if on_screen(ln)]), ("off", [ln for ln in lines if not on_screen(ln)]))
    cases = []
    for mode in (0, 1):
        for over in (0, 1):
            for tag, group in groups:
                for i in range(0, len(group), PER_PROGRAM):
                    chunk = group[i:i + PER_PROGRAM]
                    cases.append(("mode %d over %d %s-screen lines %d-%d" % (mode, over, tag, i, i + len(chunk) - 1),
                                  mode, over,
                                  [(ln, rng.randrange(8), rng.randrange(8), rng.randrange(2)) for ln in chunk]))
    return cases


def program(mode, over, draws):
    src = ["INK 0", "PAPER 7", "BRIGHT 0", "OVER 0", "CLS"]
    if mode:
        src.append("MODE 1")
    src.append("OVER %d" % over)
    for (x0, y0, x1, y1), ink, paper, bright in draws:
        src += ["INK %d" % ink, "PAPER %d" % paper, "BRIGHT %d" % bright,
                "LINE %d, %d TO %d, %d" % (x0, y0, x1, y1)]
    return src


def model_of(mode, over, draws, old_ends=False):
    global OLD_ENDS
    OLD_ENDS = old_ends
    try:
        return _model_of(mode, over, draws)
    finally:
        OLD_ENDS = False


def _model_of(mode, over, draws):
    s = Screen()
    for ends, ink, paper, bright in draws:
        s.line(ends, attr_of(ink, paper, bright), over, mode)
    return s


def run(m, src, mode):
    """Run, then read the screen at the program's end (before the shell's message)."""
    got = {}
    orig = m.read

    def spy(addr, n):
        b = orig(addr, n)
        if addr == 0x4000 and n == 6912 and "scr" not in got:
            got["scr"] = b
        return b
    m.read = spy
    try:
        r = m.run_program(src, packages=("mode",) if mode else (), maxi=900_000_000)
    finally:
        m.read = orig
    if r.ce or r.ve or r.status != "OK":
        raise RuntimeError("program failed (ce %s ve %s %s):\n%s" % (r.ce, r.ve, r.status, "\n".join(src)))
    scr = got["scr"]
    hires = m.read(0x6000, 6144) if mode else None
    return scr[:6144], scr[6144:], hires


def diff(name, a, b, what):
    bad = [i for i in range(len(a)) if a[i] != b[i]]
    if bad:
        i = bad[0]
        print("  %s: %s differs in %d bytes, first at offset %d (%02X, expected %02X)" % (name, what, len(bad), i, a[i], b[i]))
    return not bad


def check_plot(m):
    ok = True
    for mode in (0, 1):
        draws = []
        for y in list(range(80, 88)) + list(range(0, 8)) + list(range(184, 192)):
            draws.append((3 + (y % 5) * 37, y, (y % 7) + 1))
        src = ["INK 0", "PAPER 7", "BRIGHT 0", "OVER 0", "CLS"] + (["MODE 1"] if mode else [])
        s = Screen()
        for x, y, ink in draws:
            src += ["INK %d" % ink, "PLOT %d, %d" % (x, y)]
            s.point(x, y, attr_of(ink, 7, 0), 0, mode)
        bm, at, hi = run(m, src, mode)
        name = "PLOT mode %d" % mode
        ok &= diff(name, bm, s.bitmap, "bitmap")
        if mode:
            ok &= diff(name, hi, s.hires, "colour bytes ($6000)")
        else:
            ok &= diff(name, at, s.attrs, "attributes")
    print("PLOT: %s" % ("all equal" if ok else "DIFFERENCES"))
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=ROOT)
    ap.add_argument("--ref")
    ap.add_argument("--seed", type=int, default=2068)
    ap.add_argument("--lines", type=int, default=150)
    ap.add_argument("--port", type=int, default=10960)
    ap.add_argument("--plot", action="store_true")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    cases = gen_cases(rng, gen_lines(rng, a.lines))
    ok = True
    new = Machine(a.tree, a.port, label="new").start()
    ref = Machine(a.ref, a.port + 2, label="ref").start() if a.ref else None
    try:
        nref = nnew = noff = 0
        for name, mode, over, draws in cases:
            src = program(mode, over, draws)
            mdl = model_of(mode, over, draws)
            bm, at, hi = run(new, src, mode)
            c = diff(name + " (new vs model)", bm, mdl.bitmap, "bitmap")
            c &= diff(name + " (new vs model)", at, mdl.attrs, "attributes") if not mode else \
                diff(name + " (new vs model)", hi, mdl.hires, "colour bytes ($6000)")
            nnew += c
            ok &= c
            if ref:
                old = model_of(mode, over, draws, old_ends=True)
                rbm, rat, _ = run(ref, src, mode)
                c = diff(name + " (old vs old model)", rbm, old.bitmap, "bitmap")
                if not mode:
                    c &= diff(name + " (old vs old model)", rat, old.attrs, "attributes")
                if old.bitmap == mdl.bitmap and old.attrs == mdl.attrs:   # no end off the screen changed
                    c &= diff(name + " (new vs old)", bm, rbm, "bitmap")
                    if not mode:
                        c &= diff(name + " (new vs old)", at, rat, "attributes")
                else:
                    noff += 1
                nref += c
                ok &= c
        print("LINE: %d programs, %d lines each way; new ROM = model in %d/%d%s" % (
            len(cases), sum(len(c[3]) for c in cases), nnew, len(cases),
            "; old ROM = old model in %d/%d, = new ROM where no end is off the screen (%d programs had one)"
            % (nref, len(cases), noff) if ref else ""))
        if a.plot:
            ok &= check_plot(new)
    finally:
        new.stop()
        if ref:
            ref.stop()
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
