#!/usr/bin/env python3
"""Short decimal literals, exhaustively (docs/V2_LEAPC_BACKPORT_PLAN.md item 5.1).

Every literal of the old value/divisor form (mantissa 0..32767 with 1..4 decimals: "0.5", "3276.7",
"3.2767") goes through the real LEX_SCAN_NUMBER and, on the same build, through the calculator
sequence the old run-time literal used (VM_DIV_VIA_FLOAT: int->fp(m), int->fp(10^k), divide). PASS
when every literal is one TOK_FLOAT5 token, consumes all of its characters, and holds exactly the old
sequence's 5 bytes. --step N takes every Nth mantissa (a quick run); --out FILE writes
[m, k, token, characters used, lexer bytes, old-sequence bytes] per literal.

Usage: python3 tools/qual/qdecimals.py [--tree DIR] [--port N] [--step N] [--out FILE]
"""
import argparse
import json
import os
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine          # noqa: E402

LOOP, TAB, ENT = 0xF400, 0x8300, 24   # entries [text 8][m][10^k][lexer 5][old 5][token][used]
MAXN = (0xB600 - TAB) // ENT          # below the VM/compiler cells at $B6xx
TOK_FLOAT5 = 67


def harness(S, n):
    src = """
    DEVICE ZXSPECTRUM48
    ORG {loop:#x}
    ld ix,{tab:#x}
    ld bc,{n}
again:
    push bc
    push ix
    push ix
    pop hl
    ld ({src:#x}),hl
    call {lex:#x}
    pop ix
    push ix
    push ix
    pop hl
    ld de,12
    add hl,de
    ex de,hl
    ld hl,{buf:#x}
    ld bc,5
    ldir
    ld hl,({src:#x})
    push ix
    pop de
    or a
    sbc hl,de
    ld (ix+23),l
    ld a,({tok:#x})
    ld (ix+22),a
    xor a
    ld ({sp:#x}),a
    ld l,(ix+8)
    ld h,(ix+9)
    call {itofp:#x}
    pop ix
    push ix
    ld l,(ix+10)
    ld h,(ix+11)
    call {itofp:#x}
    call {div:#x}
    pop ix
    push ix
    push ix
    pop hl
    ld de,17
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
""".format(loop=LOOP, tab=TAB, n=n, ent=ENT, src=S["SRC_PTR"], lex=S["LEX_SCAN_NUMBER"],
           buf=S["TOK_FLOAT5_BUF"], tok=S["TOK_TYPE"], sp=S["CALC_SP"], stack=S["CALC_STACK"],
           itofp=S["CALC_INT_TO_FP"], div=S["VM_CALC_DIV_STUB"])
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "h.asm"), "w").write(src)
        subprocess.run(["sjasmplus", "--sym=h.sym", "h.asm"], cwd=d, check=True, capture_output=True)
        code = open(os.path.join(d, "h.bin"), "rb").read()
        done = [int(l.split()[2], 16) for l in open(os.path.join(d, "h.sym")) if l.startswith("done:")][0]
    return code, done


def text(m, k):
    s = str(m).rjust(k + 1, "0")
    return s[:-k] + "." + s[-k:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".")
    ap.add_argument("--port", type=int, default=10896)
    ap.add_argument("--step", type=int, default=1)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    cases = [(m, k) for k in (1, 2, 3, 4) for m in range(0, 32768, a.step)]
    m_ = Machine(a.tree, a.port, label="qdecimals")
    rows = []
    try:
        m_.start()
        exrom = open(os.path.join(a.tree, "build", "exrom.bin"), "rb").read()
        if m_.read(0xC000, 64) != exrom[:64]:
            print("qdecimals: FAIL EXROM is not paged in at the boot snapshot")
            return 1
        for i in range(0, len(cases), MAXN):
            batch = cases[i:i + MAXN]
            m_.restore()
            code, done = harness(m_.S, len(batch))
            m_.write(LOOP, code)
            m_.write(TAB, b"".join((text(m, k) + ":").encode().ljust(8, b":") + struct.pack("<HH", m, 10 ** k) + bytes(12)
                                   for m, k in batch))
            m_.write(0xFF00, struct.pack("<H", done))
            m_.setreg("SP", 0xFF00)
            m_.setreg("PC", LOOP)
            m_.set_bps([done])
            m_.run(400_000_000)
            if m_.pc() != done:
                print("qdecimals: FAIL the loop did not finish (batch at %d)" % i)
                return 1
            raw = m_.read(TAB, ENT * len(batch))
            for j, (m, k) in enumerate(batch):
                e = raw[ENT * j:ENT * (j + 1)]
                rows.append([m, k, e[22], e[23], e[12:17].hex(), e[17:22].hex()])
    finally:
        m_.stop()
    bad = [r for r in rows if r[2] != TOK_FLOAT5 or r[3] != len(text(r[0], r[1])) or r[4] != r[5]]
    for r in bad[:5]:
        print("  %s: token %d, %d characters used, lexer %s, old sequence %s" % (text(r[0], r[1]), r[2], r[3], r[4], r[5]))
    print("qdecimals: %d literals, each the old run-time value bit for bit: %s" % (len(rows), "PASS" if not bad else "FAIL (%d)" % len(bad)))
    if a.out:
        json.dump(rows, open(a.out, "w"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
