#!/usr/bin/env python3
"""Rounding of the calculator's four operations (docs/V2_LEAPC_BACKPORT_PLAN.md, the divide review item).

Runs the production ROM's add, subtract, multiply and divide (VM_CALC_*_STUB, the calculator's
literals $0F/$03/$04/$05) under ZEsarUX over random operand pairs, through a loop assembled into the
package window, and scores every 5-byte result against the exact result rounded to the nearest 5-byte
float (32-bit mantissa, ties away from zero): per operation, the share correctly rounded, the error in
units of the last place (ulp) and its direction. Operands: random normalised floats (exponents 98-158,
both signs) and decimal-literal pairs m / 10^k (m 1..32767, k 1..4, as CALC_INT_TO_FP pushes them).
--leapc DIR scores Leap-C's float core on the same operands through its bit-exact model
(DIR/tools/fpmodel.py, which Leap-C's own float suite checks against its ROM).

Usage: python3 tools/qual/qcalcround.py [--tree DIR] [--port N] [--pairs N] [--leapc DIR] [--out FILE]
"""
import argparse
import importlib.util
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

LOOP, TAB, ENT = 0xF400, 0x8300, 30   # entries [a 5][b 5][a+b][a-b][a*b][a/b]
MAXN = (0xB600 - TAB) // ENT          # below the VM/compiler cells at $B6xx
OPS = [("add", "VM_CALC_ADD_STUB", lambda a, b: a + b), ("sub", "VM_CALC_SUB_STUB", lambda a, b: a - b),
       ("mul", "VM_CALC_MUL_STUB", lambda a, b: a * b), ("div", "VM_CALC_DIV_STUB", lambda a, b: a / b)]


def value(b):
    """5 bytes (small-integer or general form) -> exact Fraction."""
    if b[0] == 0:
        v = b[2] | b[3] << 8
        return Fraction(v - 65536 if b[1] else v)
    m = (b[1] | 0x80) << 24 | b[2] << 16 | b[3] << 8 | b[4]
    return (-1 if b[1] & 0x80 else 1) * Fraction(m) * Fraction(2) ** (b[0] - 160)


def nearest(q):
    """The exact value q -> (5 bytes rounded to nearest, ties away from zero; the ulp; a tie?)."""
    if q == 0:
        return bytes(5), None, False
    s = 0x80 if q < 0 else 0
    a = abs(q)
    e = 128
    while a >= Fraction(2) ** (e - 128):
        e += 1
    while a < Fraction(2) ** (e - 129):
        e -= 1
    ulp = Fraction(2) ** (e - 160)
    t = a / ulp                                    # in [2^31, 2^32)
    m, r = divmod(t.numerator, t.denominator)
    tie = 2 * r == t.denominator
    if 2 * r >= t.denominator:
        m += 1
        if m == 1 << 32:
            m, e, ulp = 1 << 31, e + 1, ulp * 2
    return bytes([e, (m >> 24 & 0x7F) | s, m >> 16 & 255, m >> 8 & 255, m & 255]), ulp, tie


def general(v):
    """An exactly representable value -> its general (normalised) 5 bytes."""
    return nearest(Fraction(v))[0]


def operands(n):
    rng = random.Random(2068)
    out = []
    for i in range(n):
        if i % 4 == 3:                             # a decimal literal's division, as before 5.1
            k = rng.randint(1, 4)
            m = rng.randint(1, 32767)
            out.append((bytes([0, 0, m & 255, m >> 8, 0]), bytes([0, 0, 10 ** k & 255, 10 ** k >> 8, 0])))
            continue
        pair = []
        for _ in range(2):
            e = rng.randint(98, 158)
            m = rng.getrandbits(31)
            pair.append(bytes([e, (m >> 24) | rng.choice([0, 0x80]), m >> 16 & 255, m >> 8 & 255, m & 255]))
        out.append(tuple(pair))
    return out


def harness(S, n):
    body = ""
    for i, (_, stub, _f) in enumerate(OPS):
        body += """
    push ix
    pop hl
    ld de,{cs:#x}
    ld bc,10
    ldir
    ld a,2
    ld ({sp:#x}),a
    xor a
    ld ({err:#x}),a
    call {stub:#x}
    pop ix
    push ix
    push ix
    pop hl
    ld de,{off}
    add hl,de
    ex de,hl
    ld hl,{cs:#x}
    ld bc,5
    ldir
""".format(cs=S["CALC_STACK"], sp=S["CALC_SP"], err=S["CALC_ERROR_CODE"], stub=S[stub], off=10 + 5 * i)
    src = """
    DEVICE ZXSPECTRUM48
    ORG {loop:#x}
    ld ix,{tab:#x}
    ld bc,{n}
again:
    push bc
    push ix
{body}
    pop ix
    ld de,{ent}
    add ix,de
    pop bc
    dec bc
    ld a,b
    or c
    jp nz,again
done:
    jr done
    SAVEBIN "h.bin",{loop:#x},$-{loop:#x}
""".format(loop=LOOP, tab=TAB, n=n, ent=ENT, body=body)
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "h.asm"), "w").write(src)
        subprocess.run(["sjasmplus", "--sym=h.sym", "h.asm"], cwd=d, check=True, capture_output=True)
        code = open(os.path.join(d, "h.bin"), "rb").read()
        done = [int(l.split()[2], 16) for l in open(os.path.join(d, "h.sym")) if l.startswith("done:")][0]
    return code, done


def score(name, rows):
    """rows: (exact, result bytes) -> one summary line."""
    ok = ties = 0
    errs = []
    for q, res in rows:
        want, ulp, tie = nearest(q)
        ties += tie
        if res == want:
            ok += 1
        if ulp is not None:
            errs.append((value(res) - q) / ulp)
    toward_zero = sum(1 for (q, res), e in zip(rows, errs) if e and (e < 0) == (q > 0))
    away = sum(1 for (q, res), e in zip(rows, errs) if e and (e < 0) != (q > 0))
    mx = max(abs(e) for e in errs) if errs else 0
    return "%-4s %5d cases: %5.1f%% correctly rounded, max error %.2f ulp, inexact toward zero %d, away %d" % (
        name, len(rows), 100.0 * ok / len(rows), float(mx), toward_zero, away)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".")
    ap.add_argument("--port", type=int, default=10890)
    ap.add_argument("--pairs", type=int, default=4000)
    ap.add_argument("--leapc", default=None)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    pairs = operands(a.pairs)
    m = Machine(a.tree, a.port, label="qcalcround")
    res = []
    try:
        m.start()
        for i in range(0, len(pairs), MAXN):
            batch = pairs[i:i + MAXN]
            m.restore()
            code, done = harness(m.S, len(batch))
            m.write(LOOP, code)
            m.write(TAB, b"".join(x + y + bytes(20) for x, y in batch))
            m.write(0xFF00, struct.pack("<H", done))
            m.setreg("SP", 0xFF00)
            m.setreg("PC", LOOP)
            m.set_bps([done])
            m.run(400_000_000)
            if m.pc() != done:
                print("qcalcround: FAIL the loop did not finish (batch at %d)" % i)
                return 1
            raw = m.read(TAB, ENT * len(batch))
            res += [[raw[ENT * j + 10 + 5 * k:ENT * j + 15 + 5 * k] for k in range(4)] for j in range(len(batch))]
    finally:
        m.stop()
    print("V2 calculator (%s):" % os.path.abspath(a.tree))
    for k, (name, _, f) in enumerate(OPS):
        print("  " + score(name, [(f(value(x), value(y)), r[k]) for (x, y), r in zip(pairs, res)]))
    dec = [(value(x) / value(y), r[3]) for (x, y), r in zip(pairs, res) if x[0] == 0]
    print("  " + score("m/10^k", dec))
    if a.leapc:
        spec = importlib.util.spec_from_file_location("fpmodel", os.path.join(a.leapc, "tools", "fpmodel.py"))
        fp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fp)
        print("Leap-C float core (its model, %s):" % os.path.join(a.leapc, "tools", "fpmodel.py"))
        sym = {"add": "+", "sub": "-", "mul": "*", "div": "/"}
        norm = [(general(value(x)), general(value(y))) for x, y in pairs]
        for name, _, f in OPS:
            print("  " + score(name, [(f(value(x), value(y)), fp.binop(sym[name], x, y)) for x, y in norm]))
        print("  " + score("m/10^k", [(value(x) / value(y), fp.binop("/", gx, gy))
                                      for (x, y), (gx, gy) in zip(pairs, norm) if x[0] == 0]))
    if a.out:
        json.dump([[x.hex(), y.hex()] + [b.hex() for b in r] for (x, y), r in zip(pairs, res)], open(a.out, "w"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
