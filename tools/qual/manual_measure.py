#!/usr/bin/env python3
"""Reproduces the timing figures quoted in docs/v2/manual (concept "Speed").

Each figure is T-states per pass of a loop body, measured on the release image in the headless
emulator with ZRCP get-tstates-partial around the real RUN: (T(2000 passes) - T(1000 passes)) / 1000, so
the compile time and the loop set-up cancel out.  Not part of the documentation-example suite (the
numbers are measurements, not examples); run it to refresh the table.

    python3 tools/qual/manual_measure.py [--port 10990]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine          # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

BODIES = [
    ("empty FOR/NEXT pass", [], []),
    ("i = i (assignment)", ["a = 0"], ["a = i"]),
    ("whole-number add and multiply", ["a = 0"], ["a = i * 2 + 1"]),
    ("floating-point multiply", ["a = 1.5"], ["a = a * 1.0001"]),
    ("array store and load (whole numbers)", ["DIM t(10)"], ["t(3) = i", "x = t(3)"]),
    ("string join and LEFT$", ['a$ = ""'], ['a$ = LEFT$(a$ + "x", 20)']),
    ("PRINT of a whole number, screen scrolling", [], ["PRINT 7"]),
    ("PRINT of a whole number, no scrolling", ["AT 0, 0"], ["AT 5, 0", "PRINT 7;"]),
    ("PLOT", [], ["PLOT 100, 100"]),
    ("a PROC call and return", [], ["CALL p(1)"]),
]


def tstates(m, lines):
    m.restore()
    m.put_store(lines)
    m.cmd("reset-tstates-partial")
    r = m.call_routine("V2_RUN_STORED", maxi=900_000_000)
    assert r.ce == 0 and r.ve == 0, (lines, r.ce, r.ve)
    return int(m.cmd("get-tstates-partial").strip())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=10990)
    a = ap.parse_args()
    m = Machine(ROOT, a.port, label="measure").start()
    try:
        for name, pre, body in BODIES:
            res = []
            for n in (1000, 2000):
                prog = pre + ["FOR i = 1 TO %d" % n] + body + ["NEXT i"]
                if name.startswith("a PROC"):
                    prog += ["END", "PROC p(n):", "ENDP"]
                res.append(tstates(m, prog))
            per = (res[1] - res[0]) / 1000.0
            print("%-44s %8.0f T-states  (%5.0f passes/s at 3.5 MHz)" % (name, per, 3_500_000 / per))
    finally:
        m.stop()


if __name__ == "__main__":
    main()
