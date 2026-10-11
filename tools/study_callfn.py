#!/usr/bin/env python3
"""STUDY: CALL p(FN f(x)) -- a nested FN call in a PROC call argument."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from study_util import *
CASES = [
  (["def fn f(x) = x * 2", "proc p(a)", "print a", "endp", "call p(fn f(3))"], ["6"]),
  (["def fn f(x) = x * 2", "proc p(a)", "print a", "endp", "call p(fn f(fn f(5)))"], ["20"]),
  (["def fn f(x) = x * 2", "proc p(a)", "print a", "endp", "call p(fn f(3) + 1)"], ["7"]),
  (["def fn f(x) = x * 2", "call p(fn f(4))", "end", "proc p(a)", "print a", "endp"], ["8"]),   # forward reference
  (["def fn f(x) = x + 1", "def fn g(y) = y * 3", "proc p(a)", "print a", "endp", "call p(fn g(fn f(2)))"], ["9"]),
  (["proc p(a)", "print a", "endp", "call p(7)", "call p(8)"], ["7", "8"]),                                  # unchanged behaviour
  (["def fn f(x) = x * 2", "print fn f(fn f(2))"], ["8"]),                                                     # FN in FN (already worked)
]
def main():
    P.boot(); bad = 0
    for prog, want in CASES:
        out, ce, ve = capture_prints(prog, boot=False)
        ok = out == want and ce == 0 and ve == 0
        bad += not ok
        print("%-5s %-90s -> %s ce=%d ve=%d%s" % ("PASS" if ok else "FAIL", " : ".join(prog), out, ce, ve, "" if ok else "  WANT %s" % want), flush=True)
    D("stop"); return 1 if bad else 0
if __name__ == "__main__":
    sys.exit(main())
