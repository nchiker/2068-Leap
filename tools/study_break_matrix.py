#!/usr/bin/env python3
"""STUDY (not part of the gate): BREAK through the REAL keyboard path.

The R10.9 known-defect case D5 pokes the key latch directly.  This suite presses CAPS SHIFT +
SPACE in the emulated keyboard MATRIX (ZEsarUX `send-keys-event`) while the machine free-runs, so
the real ISR scan -> debounce -> IO_DECODE_KEY -> BREAK request path is exercised.

Run:  TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/study_break_matrix.py
"""
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402

CAPS, SPACE = 135, 128


def start_run(lines):
    P.boot()
    P.put_store(lines)
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_RUN_STORED")))


def press_break(hold=0.35):
    zr("send-keys-event %d 1" % CAPS)
    zr("send-keys-event %d 1" % SPACE)
    time.sleep(hold)
    zr("send-keys-event %d 0" % SPACE)
    zr("send-keys-event %d 0" % CAPS)


def free_run_and_break(lines, settle=1.5, wait=2.5):
    """Start the program, let it run free, press BREAK, pause, report."""
    start_run(lines)
    D("resume")
    time.sleep(settle)
    D("pause")
    running = read(P.sym("VM_HALTED"), 1)[0] == 0
    D("resume")
    press_break()
    time.sleep(wait)
    D("pause")
    back = P.run_to(IOK, 3_000_000)         # the key wait the BREAK message ends in
    return running, back, read(P.sym("VM_ERROR_CODE"), 1)[0], P.pc()


@case("brk-goto-loop", "BREAK interrupts `top: GOTO top` and shows the BREAK message")
def goto_loop():
    run, back, code, _ = free_run_and_break(["top:", "GOTO top"])
    return run and back and code == 66, "running=%s back_at_prompt=%s vm_error=%d pc=%04X" % (run, back, code, _)


@case("brk-for-loop", "BREAK interrupts a long FOR loop")
def for_loop():
    run, back, code, _ = free_run_and_break(["FOR i = 1 TO 30000", "FOR j = 1 TO 30000", "NEXT", "NEXT"])
    return run and back and code == 66, "running=%s back_at_prompt=%s vm_error=%d pc=%04X" % (run, back, code, _)


@case("brk-pause", "BREAK interrupts PAUSE 5000")
def pause_loop():
    run, back, code, _ = free_run_and_break(["PAUSE 5000"], settle=0.8)
    return run and back and code == 66, "running=%s back_at_prompt=%s vm_error=%d pc=%04X" % (run, back, code, _)


@case("brk-recursion-print", "BREAK interrupts a PRINT loop")
def print_loop():
    run, back, code, _ = free_run_and_break(["top:", "PRINT 1", "GOTO top"])
    return run and back and code == 66, "running=%s back_at_prompt=%s vm_error=%d pc=%04X" % (run, back, code, _)


@case("brk-editor-inert", "BREAK in the editor inserts nothing and a following RUN is unaffected")
def editor_inert():
    P.boot()
    D("resume")
    press_break()
    time.sleep(0.8)
    D("pause")
    line = P.edit_line()
    P.put_store(["a = 5"])
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_RUN_STORED")))
    msg = P.to_prompt(40_000_000)
    ve = read(P.sym("VM_ERROR_CODE"), 1)[0]
    tag, val = P.variables(1)[0]
    return line == b"" and ve == 0 and val == 5, "edit_line=%r vm_error=%d a=%d msg=%s" % (line, ve, val, msg)


@case("brk-rerun-after-break", "after a BREAK the program can be run again and finishes")
def rerun():
    run, back, code, _ = free_run_and_break(["top:", "GOTO top"])
    if not (run and back and code == 66):
        return False, "first run did not break (running=%s back=%s code=%d)" % (run, back, code)
    P.put_store(["a = 7"])
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_RUN_STORED")))
    P.to_prompt(40_000_000)
    ve = read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 0 and P.variables(1)[0][1] == 7, "vm_error=%d a=%d" % (ve, P.variables(1)[0][1])


@case("brk-session-vars", "after a BREAK an immediate statement sees the program's variables (session, owner decision 2)")
def session_vars():
    run, back, code, _ = free_run_and_break(["x = 7", "top:", "GOTO top"])
    if not (run and back and code == 66):
        return False, "the run did not break (running=%s back=%s code=%d)" % (run, back, code)
    P.key(KEY_ENTER)                        # dismiss the BREAK message
    P.type_text(":y = x * 2")
    ve = read(P.sym("VM_ERROR_CODE"), 1)[0]
    ce = read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    (_, x), (_, y) = P.variables(2)
    return ce == 0 and ve == 0 and x == 7 and y == 14, "ce=%d ve=%d x=%d y=%d" % (ce, ve, x, y)


if __name__ == "__main__":
    sys.exit(run_cases(sys.argv[1:] or None, "study-break"))
