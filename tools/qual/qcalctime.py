#!/usr/bin/env python3
"""T-states of the calculator's four operations (R1, docs/V2_LEAPC_BACKPORT_PLAN.md), and a
differential of CALC_FP_TO_INT.

Timing: each operation's stub (VM_CALC_ADD/SUB/MUL/DIV_STUB, as compiled code and qcalcround.py call
them: RST $28, the dispatcher, the operation, the paging trampolines) over operand pairs of three
classes, through a loop assembled into the package window; the same loop calling a bare `ret`
gives the loop's own cost, subtracted. Classes: "float" (random normalised floats, exponents
98-158, both signs: qcalcround.py's), "int" (both in the small-integer form CALC_INT_TO_FP pushes,
1..999 with either sign), "float,int" (a float in 0.001..1000 with an integer 1..99).

--fptoint FILE: run CALC_FP_TO_INT on 20,000+ values (general and small-integer forms, the edges of
its range) and write HL, the carry, CALC_TRUNC_FLAG, CALC_ERROR_CODE and CALC_SP for each to FILE
(JSON); --cmp FILE compares a second run with it.

Usage: python3 tools/qual/qcalctime.py [--tree DIR] [--port N] [--pairs N] [--fptoint FILE [--cmp FILE]]
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
from qcalcround import general       # noqa: E402

LOOP, TAB = 0xF400, 0x8300
STUBS = [("add", "VM_CALC_ADD_STUB"), ("sub", "VM_CALC_SUB_STUB"), ("mul", "VM_CALC_MUL_STUB"),
         ("div", "VM_CALC_DIV_STUB")]


def small(v):
    return bytes([0, 0xFF if v < 0 else 0, v & 255, v >> 8 & 255, 0])


def classes(n):
    rng = random.Random(2068)
    out = {"float": [], "int": [], "float,int": []}
    for _ in range(n):
        pair = []
        for _ in range(2):
            m = rng.getrandbits(31)
            pair.append(bytes([rng.randint(98, 158), (m >> 24) | rng.choice([0, 0x80]),
                               m >> 16 & 255, m >> 8 & 255, m & 255]))
        out["float"].append(tuple(pair))
        out["int"].append((small(rng.randint(1, 999) * rng.choice([1, -1])),
                           small(rng.randint(1, 999) * rng.choice([1, -1]))))
        out["float,int"].append((general(rng.randint(1, 10 ** 6) / 1000), small(rng.randint(1, 99))))
    return out


def assemble(src):
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "h.asm"), "w").write(src)
        subprocess.run(["sjasmplus", "--sym=h.sym", "h.asm"], cwd=d, check=True, capture_output=True)
        code = open(os.path.join(d, "h.bin"), "rb").read()
        done = [int(l.split()[2], 16) for l in open(os.path.join(d, "h.sym")) if l.startswith("done:")][0]
    return code, done


def time_loop(S, n, target):
    """target: a stub's address, or None for the bare loop."""
    return assemble("""
    DEVICE ZXSPECTRUM48
    ORG {loop:#x}
    ld ix,{tab:#x}
    ld bc,{n}
again:
    push bc
    push ix
    pop hl
    ld de,{cs:#x}
    ld bc,10
    ldir
    ld a,2
    ld ({sp:#x}),a
    xor a
    ld ({err:#x}),a
    push ix
    call {target}
    pop ix
    ld de,10
    add ix,de
    pop bc
    dec bc
    ld a,b
    or c
    jp nz,again
done:
    jr done
bare:
    ret
    SAVEBIN "h.bin",{loop:#x},$-{loop:#x}
""".format(loop=LOOP, tab=TAB, n=n, cs=S["CALC_STACK"], sp=S["CALC_SP"], err=S["CALC_ERROR_CODE"],
           target="bare" if target is None else "%#x" % target))


def run_loop(m, code, done, table):
    m.restore()
    m.write(LOOP, code)
    m.write(TAB, table)
    m.write(0xFF00, struct.pack("<H", done))
    m.setreg("SP", 0xFF00)
    m.setreg("PC", LOOP)
    m.set_bps([done])
    m.cmd("reset-tstates-partial")
    m.run(800_000_000)
    if m.pc() != done:
        raise SystemExit("qcalctime: FAIL the loop did not finish")
    return int(m.cmd("get-tstates-partial").strip())


def timing(m, n):
    S = m.S
    for cls, pairs in classes(n).items():
        table = b"".join(x + y for x, y in pairs)
        base = run_loop(m, *time_loop(S, n, None), table)
        row = []
        for name, stub in STUBS:
            t = run_loop(m, *time_loop(S, n, S[stub]), table)
            row.append("%s %6d" % (name, round((t - base) / n)))
        print("  %-10s T per operation (mean of %d): %s" % (cls, n, ", ".join(row)))


def fptoint_values():
    rng = random.Random(68)
    vals = []
    for _ in range(20000):
        m = rng.getrandbits(31)
        vals.append(bytes([rng.randint(100, 150), (m >> 24) | rng.choice([0, 0x80]), m >> 16 & 255,
                           m >> 8 & 255, m & 255]))
    for e in list(range(0, 3)) + list(range(120, 150)) + [200, 255]:
        for mant in (0, 0x7FFFFFFF, 0x00000001, 0x7FFF8000, 0x00007FFF, rng.getrandbits(31)):
            for s in (0, 0x80):
                vals.append(bytes([e, (mant >> 24) | s, mant >> 16 & 255, mant >> 8 & 255, mant & 255]))
    for _ in range(2000):
        v = rng.getrandbits(16)
        vals.append(bytes([0, rng.choice([0, 0xFF, 0xFF if v & 0x8000 else 0]), v & 255, v >> 8, 0]))
    return vals


def fptoint(m, out, cmp):
    S = m.S
    vals = fptoint_values()
    ent = 11                         # [value 5][L][H][F][TRUNC][ERR][SP]
    per = (0xB600 - TAB) // ent
    res = []
    for i in range(0, len(vals), per):
        batch = vals[i:i + per]
        code, done = assemble("""
    DEVICE ZXSPECTRUM48
    ORG {loop:#x}
    ld ix,{tab:#x}
    ld bc,{n}
again:
    push bc
    push ix
    pop hl
    ld de,{cs:#x}
    ld bc,5
    ldir
    ld a,1
    ld ({sp:#x}),a
    xor a
    ld ({err:#x}),a
    ld a,$AA
    ld ({trunc:#x}),a
    push ix
    call {pin:#x}
    call {fpi:#x}
    push af
    push hl
    call {pout:#x}
    pop hl
    pop bc
    pop ix
    ld (ix+5),l
    ld (ix+6),h
    ld (ix+7),c
    ld a,({trunc:#x})
    ld (ix+8),a
    ld a,({err:#x})
    ld (ix+9),a
    ld a,({sp:#x})
    ld (ix+10),a
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
""".format(loop=LOOP, tab=TAB, n=len(batch), ent=ent, cs=S["CALC_STACK"], sp=S["CALC_SP"],
           err=S["CALC_ERROR_CODE"], trunc=S["CALC_TRUNC_FLAG"], pin=S["BANK_PAGE_EXROM_IN"],
           pout=S["BANK_PAGE_EXROM_OUT"], fpi=S["CALC_FP_TO_INT"]))
        m.restore()
        m.write(LOOP, code)
        m.write(TAB, b"".join(v + bytes(6) for v in batch))
        m.write(0xFF00, struct.pack("<H", done))
        m.setreg("SP", 0xFF00)
        m.setreg("PC", LOOP)
        m.set_bps([done])
        m.run(400_000_000)
        if m.pc() != done:
            raise SystemExit("qcalctime: FAIL the CALC_FP_TO_INT loop did not finish")
        raw = m.read(TAB, ent * len(batch))
        for j, v in enumerate(batch):
            r = raw[ent * j + 5:ent * j + 11]
            res.append([v.hex(), r[0] | r[1] << 8, r[2] & 1, r[3], r[4], r[5]])
    json.dump(res, open(out, "w"))
    print("  CALC_FP_TO_INT: %d values written to %s" % (len(res), out))
    if cmp:
        ref = json.load(open(cmp))
        diff = [(a, b) for a, b in zip(res, ref) if a != b]
        print("  CALC_FP_TO_INT against %s: %d of %d equal" % (cmp, len(res) - len(diff), len(res)))
        for a, b in diff[:10]:
            print("    %s: here %s, there %s" % (a[0], a[1:], b[1:]))
        return 1 if diff or len(res) != len(ref) else 0
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".")
    ap.add_argument("--port", type=int, default=10892)
    ap.add_argument("--pairs", type=int, default=1000)
    ap.add_argument("--fptoint", default=None)
    ap.add_argument("--cmp", default=None)
    a = ap.parse_args()
    m = Machine(a.tree, a.port, label="qcalctime")
    rc = 0
    try:
        m.start()
        print("Calculator (%s):" % os.path.abspath(a.tree))
        if a.fptoint:
            rc = fptoint(m, a.fptoint, a.cmp)
        else:
            timing(m, a.pairs)
    finally:
        m.stop()
    return rc


if __name__ == "__main__":
    sys.exit(main())
