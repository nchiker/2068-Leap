#!/usr/bin/env python3
"""T-states of one ROM routine: called from the booted snapshot with the given registers, returning
to a `jr $` trap (the frame interrupt runs as it falls). For routine-level measurements such as
5.8's (GFX_CLEAR_ROW 33,205 -> 7,527 T) and the scroll (GFX_SCROLL_OUTPUT_UP).

  python3 tools/qual/qrtime.py [--tree . | --root DIR cfg] ROUTINE [REG=VALUE ...] [--poke ADDR=BYTE ...]
  e.g. qrtime.py --tree . GFX_CLEAR_ROW BC=0x1700        qrtime.py --tree . GFX_PUTCHAR AF=0x4100 BC=0x0503
(ADDR may be a symbol: --poke GFX_SCROLL_DST_ROW=3)
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine, HARNESS_RET_SLOT  # noqa: E402

TRAP = 0xFE00


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("words", nargs="+", help="[cfg] ROUTINE [REG=VALUE ...]")
    ap.add_argument("--tree", default=None)
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                                   "build", "qual-builds"))
    ap.add_argument("--port", type=int, default=10980)
    ap.add_argument("--poke", action="append", default=[])
    a = ap.parse_args()
    words = list(a.words)
    cfgdir = os.path.abspath(a.tree) if a.tree else os.path.join(a.root, words.pop(0))
    routine, regs = words[0], [w.split("=", 1) for w in words[1:]]
    m = Machine(cfgdir, a.port).start()
    try:
        m.restore()
        for p in a.poke:
            addr, val = p.split("=", 1)
            m.write(m.sym(addr) if not addr[0].isdigit() else int(addr, 0), int(val, 0))
        m.write(TRAP, b"\x18\xFE")
        m.write(HARNESS_RET_SLOT, struct.pack("<H", TRAP))
        m.setreg("SP", HARNESS_RET_SLOT)
        for r, v in regs:
            m.setreg(r.upper(), int(v, 0))
        m.setreg("PC", m.sym(routine))
        m.set_bps([TRAP])
        m.cmd("reset-tstates-partial")
        m.run(50_000_000)
        if m.pc() != TRAP:
            print("%s did not return (PC=%04X)" % (routine, m.pc()))
            return 1
        print("%s: %d T" % (routine, int(m.cmd("get-tstates-partial").strip())))
    finally:
        m.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
