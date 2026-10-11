"""Shared helpers for the cost-study prototypes (copied into each worktree's tools/ as needed).

capture_prints(lines): boot the production ROM, store `lines` as the program, RUN it through the real
V2_RUN_STORED and return (list of strings printed via GFX_PRINT_STRING, compile_err, vm_err).
Strings are read at the breakpoint on GFX_PRINT_STRING (HL -> NUL-terminated text)."""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402


def capture_prints(lines, maxi=150_000_000, boot=True, calls=40):
    if boot:
        P.boot()
    P.put_store(lines)
    return capture_run("V2_RUN_STORED", maxi, calls)


def capture_run(routine, maxi=150_000_000, calls=40, **regs):
    out = []
    gps = HSYM["GFX_PRINT_STRING_ATTR"]
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym(routine)))
    D("break", hex(gps), "--index", "3")
    try:
        for _ in range(calls):
            D("run", "--until", hex(IOK), "--max-instructions", str(maxi), t=1800)
            D("pause")
            if P.pc() == gps:
                hl = P.regs()["HL"]
                out.append(read(hl, 40).split(b"\0")[0].decode("latin-1"))
                # step off the breakpoint: clear, step one instruction, re-arm
                D("clear-break", "--index", "3")
                D("step", "--count", "1")
                D("break", hex(gps), "--index", "3")
            else:
                break
    finally:
        try:
            D("clear-break", "--index", "3")
        except Exception:
            pass
    ce = read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    ve = read(P.sym("VM_ERROR_CODE"), 1)[0]
    return out, ce, ve
