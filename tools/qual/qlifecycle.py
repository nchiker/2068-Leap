#!/usr/bin/env python3
"""Variable-session lifecycle test (owner decision 2, final semantics -- docs/V2_SESSION_VARIABLES.md).
Unlike qrun/qprobe, the machine is NOT restored between the steps of one scenario.

  python3 tools/qual/qlifecycle.py <cfg> [--port N] [--root DIR] [--verbose]
  python3 tools/qual/qlifecycle.py --tree .            (the build of a source tree)

Each scenario: a stored program, then steps. A step is (action, expected):
  action  "RUN"            V2_RUN_STORED (the RUN command)
          ":<statement>"   an immediate statement (EDIT_LINE_BUF, through V2_DISPATCH)
          "NEW"            the NEW command (through V2_DISPATCH)
          "EDIT"           any edit of the stored program (V2_CLEAR_ARRAYS, the routine every
                           ENTER-store / LOAD / NEW runs)
  expected  a string = the exact screen text (rows joined by newlines) with no compile/runtime error;
            ("ce", n) = compile error n;  ("ve", n) = runtime error n (n None = any nonzero);
            None = not checked.
Exit status 1 if any step differs from its expectation.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine  # noqa: E402

GAP_FILL = ":" + " : ".join("v%02d = %d" % (i, i) for i in range(24))

SCENARIOS = [
    ("RUN starts with fresh variables", ["x = x + 1", "PRINT x"],
     [("RUN", "1"), ("RUN", "1")]),
    ("an immediate statement sees the stopped program's variables", ["x = 5", 'y$ = "hi"'],
     [("RUN", ""), (":PRINT x", "5"), (':PRINT y$ + "!"', "hi!")]),
    ("an immediate assignment is seen by the next immediate statement", ["x = 5"],
     [("RUN", ""), (":x = x + 2", ""), (":PRINT x", "7")]),
    ("RUN after an immediate assignment starts fresh", ["PRINT x"],
     [(":x = 7", ""), ("RUN", "0")]),
    ("immediate statements create variables, zero or empty", ["x = 2"],
     [("RUN", ""), (":z = 40", ""), (":PRINT z + x", "42"), (':n$ = "ab"', ""), (':PRINT n$ + "c"', "abc"),
      (":PRINT q", "0"), (':PRINT e$ + "!"', "!")]),
    ("immediate statements without a RUN use the current program's session", ["PRINT x"],
     [(":x = 3", ""), (":PRINT x * 2", "6")]),
    ("an empty program still has a session", [],
     [(":x = 3", ""), (":PRINT x", "3")]),
    ("variables survive a runtime error", ["x = 9", "y = x / 0", "x = 1"],
     [("RUN", ("ve", None)), (":PRINT x", "9")]),
    ("variables survive STOP", ["x = 3", "STOP", "x = 4"],
     [("RUN", ""), (":PRINT x", "3")]),
    ("variables survive END and a FOR loop's exit", ["FOR i = 1 TO 3", "s = s + i", "NEXT i", "END"],
     [("RUN", ""), (":PRINT s", "6"), (":PRINT i", "4")]),
    (": GOTO label starts at the label with the session's values",
     ["n = 0", "top:", "n = n + 1", "PRINT n", "IF n < 3 THEN GOTO top", "END", "more:", "PRINT n * 10"],
     [("RUN", "1\n2\n3"), (":GOTO more", "30"), (":GOTO top", "4"), (":PRINT n", "4")]),
    (": GOTO an unknown label is a compile error and the session survives", ["x = 1"],
     [("RUN", ""), (":GOTO nowhere", ("ce", 7)), (":PRINT x", "1")]),
    ("CLEAR resets ordinary variables and keeps the program", ["x = 5"],
     [("RUN", ""), (":CLEAR", ""), (":PRINT x", "0"), ("RUN", ""), (":PRINT x", "5")]),
    ("an edit ends the session", ["x = 5"],
     [("RUN", ""), ("EDIT", None), (":PRINT x", "0")]),
    ("NEW ends the session", ["x = 5"],
     [("RUN", ""), ("NEW", None), (":PRINT x", "0")]),
    ("ordinary arrays survive and immediate statements can DIM new ones", ["DIM a(3)", "a(1) = 5"],
     [("RUN", ""), (":PRINT a(1)", "5"), (":a(2) = 6", ""), (":PRINT a(1) + a(2)", "11"), (":DIM b(2)", ""),
      (":b(1) = 3", ""), (":PRINT b(1) + a(1)", "8"), (":PRINT a(1)", "5")]),
    ("string arrays survive", ['DIM n$(3)', 'n$(1) = "red"'],
     [("RUN", ""), (':PRINT n$(1) + "!"', "red!"), (':n$(2) = "blue"', ""), (":PRINT n$(1) + n$(2)", "redblue")]),
    ("an immediate FOR loop", ["x = 10"],
     [("RUN", ""), (":FOR i = 1 TO 3 : PRINT i + x : NEXT i", "11\n12\n13"), (":PRINT i", "4")]),
    ("a compile error in an immediate statement leaves the session unchanged", ["x = 5"],
     [("RUN", ""), (":y = z +", ("ce", None)), (":PRINT x", "5"), (":y = 2", ""), (":PRINT y + z", "2")]),
    ("an immediate statement cannot define a label or PROC (error 71)", ["x = 1"],
     [("RUN", ""), (":here: PRINT 2", ("ce", 71)), (":PROC p(n): PRINT n : ENDP", ("ce", 71)), (":PRINT x", "1")]),
    ("a program's PROC can be called from an immediate statement",
     ["g = 1", "END", "PROC add(n):", "g = g + n", "ENDP"],
     [("RUN", ""), (":CALL add(4)", ""), (":PRINT g", "5")]),
    ("new variables beyond the session gap are refused, old ones keep working", ["x = 1"],
     [("RUN", ""), (GAP_FILL, ("ce", None)), (":PRINT x", "1"), (":w = 2", ""), (":PRINT w + x", "3")]),
    ("a program that does not compile: immediate statements run alone", ["PRINT ("],
     [(":x = 3", ""), (":PRINT x", "0")]),
]


def check(r, exp):
    if exp is None:
        return True
    if isinstance(exp, tuple):
        kind, code = exp
        got = r.ce if kind == "ce" else r.ve
        return got != 0 if code is None else got == code
    return r.ce == 0 and r.ve == 0 and r.text == exp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cfg", nargs="?", default=None)
    ap.add_argument("--tree", default=None, help="the build in this source tree (e.g. .)")
    ap.add_argument("--port", type=int, default=10495)
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "qual-builds"))
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()
    cfgdir = os.path.abspath(a.tree) if a.tree else os.path.join(a.root, a.cfg)
    m = Machine(cfgdir, a.port, label=os.path.basename(cfgdir)).start()
    npass = nfail = 0
    try:
        for title, prog, steps in SCENARIOS:
            m.restore()
            m.put_store(prog)
            bad = False
            log = []
            for st, exp in steps:
                if st == "RUN":
                    r = m.call_routine("V2_RUN_STORED")
                elif st == "EDIT":
                    r = m.call_routine("V2_CLEAR_ARRAYS")
                else:
                    m.write(m.sym("EDIT_LINE_BUF"), st.encode("latin-1") + b"\0")
                    r = m.call_routine("V2_DISPATCH")
                ok = check(r, exp)
                bad = bad or not ok
                log.append("   %-44s -> ce=%s ve=%s screen=%r  want %r%s"
                           % (st[:44], r.ce, r.ve, r.text, exp, "" if ok else "  <-- FAIL"))
            if bad:
                nfail += 1
                print("FAIL  %s  (program: %s)" % (title, " | ".join(prog)))
                print("\n".join(log))
            else:
                npass += 1
                print("PASS  %s" % title)
                if a.verbose:
                    print("\n".join(log))
    finally:
        m.stop()
    print("lifecycle: %d PASS %d FAIL" % (npass, nfail))
    return 1 if nfail else 0


if __name__ == "__main__":
    sys.exit(main())
