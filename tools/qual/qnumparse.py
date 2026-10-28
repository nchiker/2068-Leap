#!/usr/bin/env python3
"""The shared number parser on the production ROM (docs/V2_LEAPC_BACKPORT_PLAN.md item 5.1).

Runs the real NUM_PARSE_CALC (decimal literals, VAL, INPUT) under ZEsarUX over random number texts
(signs, spaces, 0-20 digits, 0-12 decimals, a second '.', trailing text; length B given or 255),
through a loop assembled into the package window, and writes [text, B, 5 bytes, CALC_SP, NP_FRAC,
characters used, calculator error] per text as JSON. --ref FILE compares with an earlier run (another
build's): a result may differ only in form (the small-integer form of a value without fraction digits),
never in value, fraction digits or characters used.

Usage: python3 tools/qual/qnumparse.py [--tree DIR] [--port N] [--out FILE] [--ref FILE] [--texts N]
"""
import argparse
import json
import os
import random
import struct
import subprocess
import sys
import tempfile
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine          # noqa: E402

LOOP, TAB, ENT = 0xF400, 0x8300, 32   # harness; entries [text 20][B][5 bytes][sp][frac][err][used]
MAXN = (0xB600 - TAB) // ENT          # below the VM/compiler cells at $B6xx


def texts(n):
    rng = random.Random(51)
    out = ["", " ", "-", "+", ".", "0", "1.", "-0", "-.5", ".5", "1..5", "1.2.3", "  -12.5x", "+3",
           "32767", "32768", "65535", "65536", "3275.9", "3276.1", "32759", "32760", "999999999",
           "4294967295", "4294967296", "1.000000001", "0.0000000001", "123456789012", "3.14159265358979"]
    for d in range(1, 13):
        out += ["1" + "0" * d, "9" * d, "0." + "0" * (d - 1) + "1"]
    while len(out) < n:
        s = " " * rng.choice([0, 0, 0, 1, 2]) + rng.choice(["", "", "", "-", "+"])
        s += "".join(rng.choice("0123456789") for _ in range(rng.choice([0, 1, 1, 2, 3, 4, 4, 5, 5, 6, 8, 10, 12, 15, 20])))
        if rng.random() < 0.7:
            s += "." + "".join(rng.choice("0123456789") for _ in range(rng.choice([0, 1, 2, 3, 4, 5, 6, 9, 10, 12])))
        s += rng.choice(["", "", ":", ")", " ", "e5", ".7", "x"])
        out.append(s[:19])
    return out[:n]


def value(h):
    """The calculator's 5 bytes as an exact fraction (small-integer or general form)."""
    b = bytes.fromhex(h)
    if b[0] == 0:
        v = b[2] | b[3] << 8
        return Fraction(v - 65536 if b[1] else v)
    m = int.from_bytes(b[1:5], "big")
    return (-1 if m >> 31 else 1) * Fraction(m | 0x80000000) * Fraction(2) ** (b[0] - 160)


def harness(S, n):
    src = """
    DEVICE ZXSPECTRUM48
    ORG {loop:#x}
    ld ix,{tab:#x}
    ld bc,{n}
again:
    push bc
    push ix
    xor a
    ld ({err:#x}),a
    push ix
    pop hl
    ld b,(ix+20)
    call {parse:#x}
    pop ix
    push ix
    push ix
    pop de
    or a
    sbc hl,de
    ld (ix+29),l
    ld a,({sp:#x})
    ld (ix+26),a
    ld a,({frac:#x})
    ld (ix+27),a
    ld a,({err:#x})
    ld (ix+28),a
    push ix
    pop hl
    ld de,21
    add hl,de
    ex de,hl
    ld hl,{stack:#x}
    ld bc,5
    ldir
    pop ix
    ld de,{ent}
    add ix,de
    pop bc
    dec bc
    ld a,b
    or c
    jr nz,again
done:
    jr done
    SAVEBIN "h.bin",{loop:#x},$-{loop:#x}
""".format(loop=LOOP, tab=TAB, n=n, ent=ENT, parse=S["NUM_PARSE_CALC"], sp=S["CALC_SP"],
           stack=S["CALC_STACK"], err=S["CALC_ERROR_CODE"], frac=S["NP_FRAC"])
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "h.asm"), "w").write(src)
        subprocess.run(["sjasmplus", "--sym=h.sym", "h.asm"], cwd=d, check=True, capture_output=True)
        code = open(os.path.join(d, "h.bin"), "rb").read()
        done = [int(l.split()[2], 16) for l in open(os.path.join(d, "h.sym")) if l.startswith("done:")][0]
    return code, done


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".")
    ap.add_argument("--port", type=int, default=10894)
    ap.add_argument("--out", default=None)
    ap.add_argument("--ref", default=None)
    ap.add_argument("--texts", type=int, default=5000)
    a = ap.parse_args()
    rng = random.Random(7)
    cases = [(t, rng.choice([len(t), 255])) for t in texts(a.texts)]
    m = Machine(a.tree, a.port, label="qnumparse")
    rows = []
    try:
        m.start()
        for i in range(0, len(cases), MAXN):
            batch = cases[i:i + MAXN]
            m.restore()
            code, done = harness(m.S, len(batch))
            m.write(LOOP, code)
            m.write(TAB, b"".join((t.encode() + b"\r").ljust(20, b"\r") + bytes([b]) + bytes(11) for t, b in batch))
            m.write(0xFF00, struct.pack("<H", done))
            m.setreg("SP", 0xFF00)
            m.setreg("PC", LOOP)
            m.set_bps([done])
            m.run(400_000_000)
            if m.pc() != done:
                print("qnumparse: FAIL the loop did not finish (batch at %d)" % i)
                return 1
            raw = m.read(TAB, ENT * len(batch))
            for j, (t, b) in enumerate(batch):
                e = raw[ENT * j:ENT * (j + 1)]
                rows.append([t, b, e[21:26].hex(), e[26], e[27], e[29], e[28]])
    finally:
        m.stop()
    bad = sum(1 for r in rows if r[3] != 1 or r[6])
    print("qnumparse: %d texts, one result each and no calculator error: %s" % (len(rows), "PASS" if not bad else "FAIL (%d)" % bad))
    if a.out:
        json.dump(rows, open(a.out, "w"))
    if a.ref:
        ref = json.load(open(a.ref))
        diff = [(r, s) for r, s in zip(rows, ref) if r != s]
        form = [(r, s) for r, s in diff if r[:2] == s[:2] and r[3:] == s[3:] and r[4] == 0 and value(r[2]) == value(s[2])]
        other = [d for d in diff if d not in form]
        for r, s in other[:5]:
            print("  differs: %r, reference %r" % (r, s))
        print("qnumparse: against the reference run: %d identical, %d in another form of the same value, %s" % (
            len(rows) - len(diff), len(form), "PASS" if not other and len(ref) == len(rows) else "FAIL (%d)" % len(other)))
        bad += len(other)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
