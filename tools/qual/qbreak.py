#!/usr/bin/env python3
"""BREAK qualification for the poll rule of item 5.2 (docs/V2_LEAPC_BACKPORT_PLAN.md): one case per
loop form and per wait. Each program runs from V2_RUN_STORED until it is inside its loop (or wait);
then CAPS SHIFT + SPACE is pressed in the emulated keyboard matrix (the real ISR path: debounce,
KEY_BREAK, VM_HALTED / error 66), held for a few frames and released. PASS: the run ends with error
66, the line after the loop never printed `n`, and the BREAK came while the program was still
running. Also prints the T-states from the key's acceptance (the ISR's write of VM_HALTED, a ZEsarUX
write watchpoint) to the BREAK message: the poll's latency plus the shell's constant unwind to the
message (a key held for a few more frames adds nothing: the run has stopped by then).

  python3 tools/qual/qbreak.py [--root DIR] [--port N] cfg [substr ...]
(cfg is a configuration directory under --root, as tools/qual/build_configs.sh makes them.)
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine, HARNESS_RET_SLOT, KEY_ENTER   # noqa: E402

N = 'PRINT "n"'
# (name, program, keys after the BREAK (INPUT: it waits for ENTER), instructions run before the BREAK)
CASES = [
    ("goto-self", ["top:", "GOTO top", N], (), 300_000),
    ("if-goto", ["i = 0", "top:", "i = i + 1", "IF i < 30000 THEN GOTO top", N], (), 300_000),
    ("if-goto-var", ["i = 0", "s = 30000", "top:", "i = i + 1", "IF i <= s THEN GOTO top", N], (), 300_000),
    ("if-block-goto", ["i = 0", "top:", "IF i < 30000 THEN", "i = i + 1", "GOTO top", "ENDIF", N], (), 300_000),
    ("for-int-empty", ["FOR i = 1 TO 30000", "NEXT i", N], (), 300_000),
    ("for-int-body", ["x = 0", "FOR i = 1 TO 30000", "x = x + 1", "NEXT i", N], (), 300_000),
    ("for-int-down", ["FOR i = 30000 TO 1 STEP -1", "NEXT i", N], (), 300_000),
    ("for-int-step0", ["FOR i = 1 TO 2 STEP 0", "NEXT i", N], (), 300_000),
    ("for-float-step", ["FOR i = 0 TO 30000 STEP 0.5", "NEXT i", N], (), 300_000),
    ("for-float-limit", ["FOR i = 1 TO 30000.5", "NEXT i", N], (), 300_000),
    ("for-float-var", ["FOR i = 0.5 TO 30000", "NEXT i", N], (), 300_000),
    ("for-not-top", ["FOR i = 1 TO 30000", "FOR j = 1 TO 2", "GOTO nx", "NEXT j", "nx:", "NEXT i", N], (), 300_000),
    ("for-nested", ["FOR i = 1 TO 300", "FOR j = 1 TO 100", "NEXT j", "NEXT i", N], (), 300_000),
    ("proc-recursion", ["CALL t(18)", N, "END", "PROC t(n):", "IF n > 0 THEN", "CALL t(n - 1)",
                        "CALL t(n - 1)", "ENDIF", "ENDP"], (), 300_000),
    ("fn-loop", ["DEF FN f(x) = x + 1", "i = 0", "top:", "i = FN f(i)", "IF i < 30000 THEN GOTO top", N], (), 300_000),
    ("pause-0", ["PAUSE 0", N], (), 300_000),
    ("pause-n", ["PAUSE 3000", N], (), 300_000),
    ("beep", ["BEEP 20,0", N], (), 300_000),
    ("input", ["INPUT a", N], (KEY_ENTER,), 300_000),
]


def run_case(m, prog, keys, pre):
    m.restore()
    m.put_store(prog)
    msg, ret = m.sym("V2_SHOW_MESSAGE"), m.sym("V2_COMMAND_LOOP.loop")
    m.write(HARNESS_RET_SLOT, struct.pack("<H", ret))
    m.setreg("SP", HARNESS_RET_SLOT)
    m.setreg("PC", m.sym("V2_RUN_STORED"))
    m.set_bps([msg, ret])
    m.run(pre)
    halted = m.read(m.sym("VM_HALTED"), 1)[0]
    if m.pc() in (msg, ret) or halted:
        return False, "the program ended before the BREAK (halted=%d ve=%d)" % (
            halted, m.read(m.sym("VM_ERROR_CODE"), 1)[0])
    # CAPS SHIFT + SPACE in the emulated matrix; a write watchpoint on VM_HALTED stops the run when
    # the ISR accepts the key (debounce), from where the T-states to the BREAK message are counted
    m.cmd("send-keys-event 135 1")
    m.cmd("send-keys-event 128 1")
    m.cmd("set-breakpoint 3 MWA=%04XH" % m.sym("VM_HALTED"))
    m.run(600_000)
    seen = m.read(m.sym("VM_HALTED"), 1)[0] != 0
    m.cmd("set-breakpoint 3")
    m.cmd("reset-tstates-partial")
    m.run(100_000)                          # a few more frames with the key down, then release
    m.cmd("send-keys-event 128 0")
    m.cmd("send-keys-event 135 0")
    for k in keys:                          # INPUT keeps waiting for ENTER after a BREAK
        m.write(m.sym("KBD_LASTK"), k)
        m.write(m.sym("KBD_KEYHIT"), 1)
    if m.pc() not in (msg, ret):
        m.run(60_000_000)
    lat = int(m.cmd("get-tstates-partial").strip())
    p = m.pc()
    ve = m.read(m.sym("VM_ERROR_CODE"), 1)[0]
    rows = m.screen_rows()
    printed = any(r.strip() == "n" for r in rows[:23])
    ok = p == msg and ve == 66 and not printed and seen
    return ok, "ve=%d stop=%s n_printed=%s key_seen=%s T(key -> message)=%s" % (
        ve, "message" if p == msg else ("return" if p == ret else "%04X" % p), printed, seen,
        lat if seen and p == msg else "-")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cfg")
    ap.add_argument("only", nargs="*")
    ap.add_argument("--port", type=int, default=10620)
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                                   "build", "qual-builds"))
    a = ap.parse_args()
    m = Machine(os.path.join(a.root, a.cfg), a.port, label=a.cfg).start()
    fails = 0
    n = 0
    try:
        for name, prog, keys, pre in CASES:
            if a.only and not any(s in name for s in a.only):
                continue
            n += 1
            ok, why = run_case(m, prog, keys, pre)
            fails += not ok
            print("%s %-16s %s" % ("PASS" if ok else "FAIL", name, why), flush=True)
    finally:
        m.stop()
    print("qbreak %s: %d cases, %d PASS, %d FAIL" % (a.cfg, n, n - fails, fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
