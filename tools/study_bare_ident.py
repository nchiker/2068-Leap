#!/usr/bin/env python3
"""STUDY: an identifier alone on a line is not a label definition (it used to be silently accepted)."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from study_util import *
CASES = [  # (program, want printed, want compile error)
  (["foo"], [], 64), (["PRNT"], [], 64), (["x = 1", "CLEARR", "PRINT x"], [], 64), (["x"], [], 64),
  (["CONT"], [], 64), (["COPY"], [], 64), (["RESTORE"], [], 64),
  (["foo:", "x = 3", "PRINT x"], ["3"], 0),                      # a real label still works
  (["a:", "x = 1", "IF x = 1 THEN GOTO b", "b:", "PRINT x"], ["1"], 0),
  (["GOTO a", "PRINT 9", "a:", "PRINT 7"], ["7"], 0),
  (["proc p(a)", "print a", "endp", "call p(5)"], ["5"], 0),
  (["x = 1:", "PRINT x"], ["1"], 0),
  (["l1:", "PRINT 1", "GOTO l1x"], [], 7),                        # undefined label unchanged
]
def main():
    P.boot(); bad = 0
    for prog, want, wce in CASES:
        out, ce, ve = capture_prints(prog, boot=False, maxi=20_000_000, calls=6)
        ok = (ce == wce) and (wce != 0 or (out == want and ve == 0))
        bad += not ok
        print("%-5s %-58s -> %s ce=%d ve=%d%s" % ("PASS" if ok else "FAIL", " : ".join(prog), out, ce, ve, "" if ok else "  WANT %s ce=%d" % (want, wce)), flush=True)
    D("stop"); return 1 if bad else 0
if __name__ == "__main__":
    sys.exit(main())
