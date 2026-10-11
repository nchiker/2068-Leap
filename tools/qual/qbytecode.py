#!/usr/bin/env python3
"""Bytecode identity check between two builds: compile every corpus program (no run) on build A and on
build B and compare the emitted bytecode (VM_CODE_BASE .. EMIT_PTR) and the compile error code.

  python3 tools/qual/qbytecode.py <cfgA> <cfgB> [--port N] [--filter substr]
Used to show that a compiler shrink (e.g. apply_emit_inline.py) leaves the generated code unchanged.
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus                                   # noqa: E402
from qharness import Machine, HARNESS_RET_SLOT  # noqa: E402


def compile_only(m, case):
    m.restore()
    for p in case.packages:
        m.install_package(p)
    m.put_store(case.lines)
    if case.prepare:
        case.prepare(m)
    done = m.sym("V2_COMPILE_RUN.compiled")
    msg = m.sym("V2_SHOW_MESSAGE")
    m.write(HARNESS_RET_SLOT, struct.pack("<H", m.sym("V2_COMMAND_LOOP.loop")))
    m.setreg("SP", HARNESS_RET_SLOT)
    m.setreg("PC", m.sym("V2_RUN_STORED"))
    m.set_bps([done, msg])
    m.run(200_000_000)
    ce = m.read(m.sym("COMPILE_ERROR_CODE"), 1)[0]
    base, end = m.sym("VM_CODE_BASE"), m.w16(m.sym("EMIT_PTR"))
    code = m.read(base, end - base) if m.pc() == done and base <= end < base + 8192 else b""
    return ce, m.pc() == done, code


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--port", type=int, default=10520)
    ap.add_argument("--filter", default="")
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "qual-builds"))
    a = ap.parse_args()
    cases = [c for c in corpus.CASES if not a.filter or any(f in c.cid for f in a.filter.split(","))]
    res = {}
    for i, cfg in enumerate((a.a, a.b)):
        m = Machine(os.path.join(a.root, cfg), a.port + i, label=cfg).start()
        try:
            res[cfg] = {c.cid: compile_only(m, c) for c in cases}
        finally:
            m.stop()
    same = diff = 0
    nbytes = 0
    for c in cases:
        ra, rb = res[a.a][c.cid], res[a.b][c.cid]
        if ra == rb:
            same += 1
            nbytes += len(ra[2])
        else:
            diff += 1
            print("DIFF %-36s A: ce=%s compiled=%s %dB  B: ce=%s compiled=%s %dB" % (c.cid, ra[0], ra[1], len(ra[2]), rb[0], rb[1], len(rb[2])))
    print("%d programs: %d identical (%d bytes of bytecode compared), %d different" % (len(cases), same, nbytes, diff))
    return 1 if diff else 0


if __name__ == "__main__":
    sys.exit(main())
