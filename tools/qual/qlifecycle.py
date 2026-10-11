#!/usr/bin/env python3
"""Variable-lifecycle probes (owner decision 2): what RUN, immediate ':' statements, CLEAR and a second
RUN do to a program's variables today. Unlike qrun/qprobe, the machine is NOT restored between the
steps of one scenario.

  python3 tools/qual/qlifecycle.py <cfg> [--port N]
Each scenario: a stored program, then a list of steps; a step is "RUN" or ":<immediate statement>".
The screen after each step is printed (the ROM's own font), plus compile/runtime error codes.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine  # noqa: E402

SCENARIOS = [
    ("RUN twice: scalars start from zero each RUN", ["x = x + 1", "PRINT x"], ["RUN", "RUN"]),
    ("after RUN, an immediate statement does not see the program's variables", ["x = 5", "y$ = \"hi\""], ["RUN", ":PRINT x", ":PRINT y$ + \"!\""]),
    ("an immediate assignment is not visible to the next RUN", ["PRINT x"], [":x = 7", "RUN"]),
    ("CLEAR inside a program zeroes scalars and strings", ["x = 5", "s$ = \"abc\"", "CLEAR", "PRINT x", "PRINT s$ + \"|\""], ["RUN"]),
    ("CLEAR discards an ordinary array", ["DIM a(3)", "a(1) = 5", "CLEAR", "PRINT a(1)"], ["RUN"]),
    ("an ordinary array starts from zero each RUN", ["DIM a(3)", "a(1) = a(1) + 1", "PRINT a(1)"], ["RUN", "RUN"]),
    ("immediate statements run in their own scope", [], [":x = 3", ":PRINT x"]),
]


def screen(m):
    return "\\n".join(r for r in m.screen_rows() if r.strip()) or "(blank)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cfg")
    ap.add_argument("--port", type=int, default=10495)
    ap.add_argument("--root", default=os.path.expanduser("~/2068-Leap-study/qual-builds"))
    a = ap.parse_args()
    m = Machine(os.path.join(a.root, a.cfg), a.port, label=a.cfg).start()
    try:
        for title, prog, steps in SCENARIOS:
            print("== %s" % title)
            print("   program: %s" % " | ".join(prog))
            m.restore()
            m.put_store(prog)
            for st in steps:
                if st == "RUN":
                    r = m.call_routine("V2_RUN_STORED")
                else:
                    m.write(m.sym("EDIT_LINE_BUF"), st.encode("latin-1") + b"\0")
                    r = m.call_routine("V2_DISPATCH")
                print("   %-22s -> ce=%s ve=%s msg=%s status=%s screen=%r" % (st, r.ce, r.ve, r.msg, r.status, r.text))
    finally:
        m.stop()


if __name__ == "__main__":
    main()
