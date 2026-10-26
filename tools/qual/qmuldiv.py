#!/usr/bin/env python3
"""16-bit multiply and divide on the production ROM (docs/V2_LEAPC_BACKPORT_PLAN.md item 1.5).

Runs the real MATH_UMUL16, MATH_UDIV16 and the signed MATH_MULTIPLY16, MATH_DIVIDE16 and MATH_MOD16
under ZEsarUX over the same operand pairs (edge values and random ones), through a loop assembled into
the package window, and writes [a, b, udiv quotient, udiv remainder, umul, mul, div, mod] per pair as
JSON. The unsigned results are checked against Python; --ref FILE also compares every result with an
earlier run (another build's), the differential check used when a routine is replaced.

Usage: python3 tools/qual/qmuldiv.py [--tree DIR] [--port N] [--out FILE] [--ref FILE] [--pairs N]
"""
import argparse
import json
import os
import random
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine          # noqa: E402

LOOP, PAIRS, RES = 0xF400, 0x8300, 0x9200     # harness; [a][b] pairs; 6 result words a pair
MAX_PAIRS = 900                               # pairs below RES, results below $C000 (chunk 6)
EDGE = [0, 1, 2, 3, 7, 10, 127, 128, 255, 256, 1000, 32767, 32768, 32769, 60000, 65534, 65535]


def pairs(n):
    rng = random.Random(2068)
    out = [(a, b) for a in EDGE for b in EDGE]
    while len(out) < n:
        out.append((rng.randrange(65536), rng.randrange(65536) >> rng.randrange(16)))
    return out[:n]


def harness(S, n):
    src = """
    DEVICE ZXSPECTRUM48
    ORG {loop:#x}
    ld ix,{pairs:#x}
    ld iy,{res:#x}
    ld bc,{n}
again:
    push bc
    ld l,(ix+0)
    ld h,(ix+1)
    ld c,(ix+2)
    ld b,(ix+3)
    call {udiv:#x}               ; HL / BC
    ld (iy+0),l
    ld (iy+1),h
    ld (iy+2),e
    ld (iy+3),d
    ld e,(ix+0)
    ld d,(ix+1)
    ld c,(ix+2)
    ld b,(ix+3)
    call {umul:#x}               ; DE * BC
    ld (iy+4),l
    ld (iy+5),h
    ld l,(ix+0)
    ld h,(ix+1)
    ld e,(ix+2)
    ld d,(ix+3)
    call {mul:#x}                ; signed HL * DE
    ld (iy+6),l
    ld (iy+7),h
    ld l,(ix+0)
    ld h,(ix+1)
    ld e,(ix+2)
    ld d,(ix+3)
    call {div:#x}                ; signed HL / DE
    ld (iy+8),l
    ld (iy+9),h
    ld l,(ix+0)
    ld h,(ix+1)
    ld e,(ix+2)
    ld d,(ix+3)
    call {mod:#x}                ; signed HL MOD DE
    ld (iy+10),l
    ld (iy+11),h
    ld de,4
    add ix,de
    ld de,12
    add iy,de
    pop bc
    dec bc
    ld a,b
    or c
    jr nz,again
done:
    jr done
    SAVEBIN "h.bin",{loop:#x},$-{loop:#x}
""".format(loop=LOOP, pairs=PAIRS, res=RES, n=n, udiv=S["MATH_UDIV16"], umul=S["MATH_UMUL16"],
           mul=S["MATH_MULTIPLY16"], div=S["MATH_DIVIDE16"], mod=S["MATH_MOD16"])
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "h.asm"), "w").write(src)
        subprocess.run(["sjasmplus", "--sym=h.sym", "h.asm"], cwd=d, check=True, capture_output=True)
        code = open(os.path.join(d, "h.bin"), "rb").read()
        done = [int(l.split()[2], 16) for l in open(os.path.join(d, "h.sym")) if l.startswith("done:")][0]
    return code, done


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".")
    ap.add_argument("--port", type=int, default=10892)
    ap.add_argument("--out", default=None)
    ap.add_argument("--ref", default=None)
    ap.add_argument("--pairs", type=int, default=600)
    a = ap.parse_args()
    if a.pairs > MAX_PAIRS:
        ap.error("--pairs: at most %d (the tables must stay below $C000)" % MAX_PAIRS)
    ps = pairs(a.pairs)
    m = Machine(a.tree, a.port, label="qmuldiv")
    try:
        m.start()
        m.restore()
        code, done = harness(m.S, len(ps))
        m.write(LOOP, code)
        m.write(PAIRS, b"".join(struct.pack("<HH", x, y) for x, y in ps))
        m.write(0xFF00, struct.pack("<H", done))
        m.setreg("SP", 0xFF00)
        m.setreg("PC", LOOP)
        m.set_bps([done])
        m.run(200_000_000)
        if m.pc() != done:
            print("qmuldiv: FAIL the loop did not finish")
            return 1
        raw = m.read(RES, 12 * len(ps))
    finally:
        m.stop()
    rows = [[x, y] + list(struct.unpack_from("<6H", raw, 12 * i)) for i, (x, y) in enumerate(ps)]
    bad = 0
    for x, y, q, r, p, *_ in rows:
        want = (x // y, x % y) if y else (0, 0)
        if (q, r) != want or p != (x * y) & 0xFFFF:
            bad += 1
            if bad <= 5:
                print("  %d, %d: udiv %d r %d, umul %d; want %d r %d, %d" % (x, y, q, r, p, want[0], want[1], (x * y) & 0xFFFF))
    print("qmuldiv: %d pairs, unsigned results against Python: %s" % (len(rows), "PASS" if not bad else "FAIL (%d)" % bad))
    if a.out:
        json.dump(rows, open(a.out, "w"))
    if a.ref:
        ref = json.load(open(a.ref))
        diff = [(r, s) for r, s in zip(rows, ref) if r != s]
        for r, s in diff[:5]:
            print("  differs: %r, reference %r" % (r, s))
        print("qmuldiv: every result equals the reference run's: %s" % ("PASS" if not diff and len(ref) == len(rows) else "FAIL (%d)" % len(diff)))
        bad += len(diff)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
