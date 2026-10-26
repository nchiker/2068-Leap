#!/usr/bin/env python3
"""RND's generator on the production ROM (docs/V2_LEAPC_BACKPORT_PLAN.md item 1.2).

Runs the real MATH_RND16 under ZEsarUX from RND_STATE = 1, through a small loop written into the
package window ($F400), and checks it against the reference xorshift (HL ^= HL<<7; HL ^= HL>>9;
HL ^= HL<<8):
  - the first 255 states and RND(1000) results equal the reference's;
  - the state first returns to 1 after exactly 65,535 steps (the full period);
  - RND(x) for x <= 0 is 0.

Usage: python3 tools/qual/qrnd.py [--tree DIR] [--port N]
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine          # noqa: E402

LOOP, BUF, N = 0xF400, 0xF500, 255    # the harness code, then [state:2][result:2] x N


def ref_step(x):
    x ^= (x << 7) & 0xFFFF
    x ^= x >> 9
    x ^= (x << 8) & 0xFFFF
    return x


def harness(S):
    """The loop, assembled by sjasmplus: BC counts steps; the first N states and results go to BUF;
    it stops at `done: jr $` when the state is 1 again. Returns (code, address of done)."""
    src = """
    DEVICE ZXSPECTRUM48
    ORG {loop:#x}
    ld hl,1
    ld ({st:#x}),hl
    ld bc,0
    ld ix,{buf:#x}
again:
    push bc
    ld hl,1000
    call {rnd:#x}
    pop bc
    inc bc
    ld a,b
    or a
    jr nz,check            ; only the first 255 steps are recorded (bc < 256)
    ex de,hl
    ld hl,({st:#x})
    ld (ix+0),l
    ld (ix+1),h
    ld (ix+2),e
    ld (ix+3),d
    ld de,4
    add ix,de
check:
    ld hl,({st:#x})
    ld a,h
    or a
    jr nz,again
    ld a,l
    cp 1
    jr nz,again
done:
    jr done
    SAVEBIN "h.bin",{loop:#x},$-{loop:#x}
""".format(loop=LOOP, st=S["RND_STATE"], buf=BUF, rnd=S["MATH_RND16"])
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "h.asm"), "w").write(src)
        subprocess.run(["sjasmplus", "--sym=h.sym", "h.asm"], cwd=d, check=True, capture_output=True)
        code = open(os.path.join(d, "h.bin"), "rb").read()
        done = [int(l.split()[2], 16) for l in open(os.path.join(d, "h.sym")) if l.startswith("done:")][0]
    return code, done


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".")
    ap.add_argument("--port", type=int, default=10890)
    a = ap.parse_args()
    m = Machine(a.tree, a.port, label="qrnd")
    fails = 0
    try:
        m.start()
        m.restore()
        code, done = harness(m.S)
        m.write(LOOP, code)
        m.write(0xFF00, struct.pack("<H", done))
        m.setreg("SP", 0xFF00)
        m.setreg("PC", LOOP)
        m.set_bps([done])
        m.run(400_000_000)
        r = m.regs()
        if r["PC"] != done:
            print("qrnd: FAIL the loop did not finish (PC=%04X)" % r["PC"])
            return 1
        steps = r["BC"]
        ok = steps == 0xFFFF
        fails += not ok
        print("qrnd: period %d (expect 65535): %s" % (steps, "PASS" if ok else "FAIL"))
        buf = m.read(BUF, 4 * N)
        x, bad = 1, 0
        for i in range(N):
            x = ref_step(x)
            st, res = struct.unpack_from("<HH", buf, 4 * i)
            if st != x or res != (x & 0x7FFF) % 1000:
                bad += 1
                if bad <= 5:
                    print("  step %d: state %04X result %d, reference %04X %d" % (i + 1, st, res, x, (x & 0x7FFF) % 1000))
        fails += bad > 0
        print("qrnd: first %d states and RND(1000) results equal the reference: %s" % (N, "PASS" if not bad else "FAIL"))
        for x in (0, -5, -32768):
            m.restore()
            m.write(0xFF00, struct.pack("<H", 0xFF02))
            m.write(0xFF02, b"\x18\xfe")
            m.setreg("SP", 0xFF00)
            m.setreg("HL", x)
            m.setreg("PC", m.sym("MATH_RND16"))
            m.set_bps([0xFF02])
            m.run(1_000_000)
            hl = m.regs()["HL"]
            fails += hl != 0
            print("qrnd: RND(%d) = %d: %s" % (x, hl, "PASS" if hl == 0 else "FAIL"))
    finally:
        m.stop()
    print("qrnd: %d failures" % fails)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
