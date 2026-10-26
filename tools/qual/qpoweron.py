#!/usr/bin/env python3
"""Power-on RAM check of the production ROM (docs/V2_LEAPC_BACKPORT_PLAN.md item 0.6).

A real TS2068 powers on with whatever its DRAM holds, and its reset button keeps the RAM; every other
suite boots ZEsarUX from zeroed RAM. Here the machine boots from a pattern written over $4000-$FFFF
(and over the registers a Z80 reset leaves undefined) after `reset-cpu`, which keeps ZEsarUX's RAM.
After 2068-Leap-C's tools/poweron.py, which found its UDG table was never cleared.

Patterns: zero (the reference), ones ($FF), alt ($55/$AA), addr (each byte its address's low byte),
random:N (bytes and registers from random.Random(N)).

Checked against the zero boot (FAIL on a difference): the boot reaches the editor's key wait with the
same SP; the RAM V2 defines at that point is byte-identical: the display file, the system variables,
main pool, bytecode area and fixed V2 area ($8000-$BFFF), the UDG table, the edit line, the package
registry's markers and the live stack. Reported only (INFO): the areas V2 leaves undefined until it
writes them (listed in areas()), so a difference there is a lead to read, not a failure.

First run (2026-10-25, v2.0.2-emu.1): the UDG table fails under every pattern (plan item 2.2); all else
matches.

Usage: python3 tools/qual/qpoweron.py [--tree DIR] [--port N] [PATTERN ...]
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine          # noqa: E402

RAM_BASE, RAM_SIZE = 0x4000, 0xC000
PATTERNS = ("ones", "alt", "addr", "random:1", "random:2", "random:3")
FREE_REGS = ("AF", "BC", "DE", "HL", "IX", "IY", "SP", "AF'", "BC'", "DE'", "HL'")


def ram_bytes(name):
    if name == "zero":
        return bytes(RAM_SIZE), None
    if name == "ones":
        return bytes([0xFF]) * RAM_SIZE, None
    if name == "alt":
        return bytes([0x55, 0xAA]) * (RAM_SIZE // 2), None
    if name == "addr":
        return bytes(a & 0xFF for a in range(RAM_BASE, RAM_BASE + RAM_SIZE)), None
    if name.startswith("random:"):
        rng = random.Random(int(name.split(":", 1)[1]))
        return rng.randbytes(RAM_SIZE), {r: rng.randrange(0x10000) for r in FREE_REGS}
    raise ValueError("unknown RAM pattern %r" % name)


def areas(m, sp):
    """[(name, address, length, must_match)] at the editor's key wait."""
    S = m.sym
    return [("display file + attributes", 0x4000, 0x1B00, True),
            ("system variables, pool, bytecode, fixed V2 area", 0x8000, 0x4000, True),
            ("UDG table", S("UDG_TABLE"), S("EDIT_LINE_BUF") - S("UDG_TABLE"), True),
            ("edit-line buffer", S("EDIT_LINE_BUF"), 128, True),
            ("package registry markers", S("EXTENSION_MAGIC"), 2, True),
            ("package slot count", S("EXTENSION_SLOT_COUNT"), 1, True),
            ("live stack", sp, 0xFF00 - sp, True),
            # Written before they are read, or unused by V2: the LOAD-name / detokeniser half of the
            # edit buffer, segment 2 (PAS_END marks the store empty at cold start), the sprite store
            # (slot DEFINED/SHOWN zeroed by MEM_INIT), V1 leftover and line-drawing cells, the window.
            ("edit buffer, LOAD-name / detokeniser half", S("EDIT_LINE_BUF") + 128, 128, False),
            ("segment 2 (Array Store)", 0xE000, 0x0800, False),
            ("sprite store", 0xE800, 0x0900, False),
            ("misc cells $F328-$F3FF", 0xF328, 0x00D8, False),
            ("package window", 0xF400, 0x0400, False)]


def boot(m, name):
    m.restore()                       # a known machine, then a reset that keeps the RAM
    m.cmd("reset-cpu")
    data, regs = ram_bytes(name)
    m.write(RAM_BASE, data)
    for r, v in (regs or {}).items():
        m.setreg(r, v)
    m.set_bps([m.sym("IO_READ_KEY")])
    m.run(80_000_000)
    r = m.regs()
    out = dict(reached=r["PC"] == m.sym("IO_READ_KEY"), sp=r["SP"], pc=r["PC"], areas={})
    if out["reached"]:
        for what, a, n, must in areas(m, r["SP"]):
            out["areas"][what] = (a, m.read(a, n), must)
    return out


def ranges(a, b, base):
    out, start = [], None
    for i in range(len(a) + 1):
        diff = i < len(a) and a[i] != b[i]
        if diff and start is None:
            start = i
        elif not diff and start is not None:
            out.append("$%04X-$%04X" % (base + start, base + i - 1) if i - 1 > start else "$%04X" % (base + start))
            start = None
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".")
    ap.add_argument("--port", type=int, default=10870)
    ap.add_argument("patterns", nargs="*", default=list(PATTERNS))
    a = ap.parse_args()
    m = Machine(a.tree, a.port, label="poweron")
    failed = 0
    try:
        m.start()
        ref = boot(m, "zero")
        assert ref["reached"], "the zero boot did not reach IO_READ_KEY"
        print("zero: SP=%04X" % ref["sp"])
        for name in a.patterns:
            st = boot(m, name)
            if not st["reached"]:
                failed += 1
                print("%-9s %-52s FAIL PC=%04X" % (name, "reaches the editor key wait", st["pc"]))
                continue
            ok = st["sp"] == ref["sp"]
            failed += not ok
            print("%-9s %-52s %s" % (name, "SP as from zeroed RAM", "PASS" if ok else "FAIL %04X" % st["sp"]))
            for what, (addr, data, must) in st["areas"].items():
                raddr, rdata, _ = ref["areas"][what]
                same = raddr == addr and rdata == data
                where = "" if same or raddr != addr else " differs at " + ", ".join(ranges(rdata, data, addr)[:10])
                verdict = "PASS" if same else ("FAIL" if must else "INFO")
                failed += must and not same
                print("%-9s %-52s %s%s" % (name, what, verdict, where))
    finally:
        m.stop()
    print("qpoweron: %d failures" % failed)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
