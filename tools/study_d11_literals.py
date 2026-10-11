#!/usr/bin/env python3
"""STUDY D11 literal policy L-A: address literals keep working, silent wraps are errors."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from study_util import *
CASES = [  # (program, want printed, want compile error)
  (["POKE 65000, 42", "PRINT PEEK(65000)"], ["42"], 0),
  (["POKE 61440, 33", "POKE 61441, 5", "POKE 61442, 0", "POKE 61443, 201", "PRINT USR(61440)"], ["5"], 0),
  (["PRINT 32767"], ["32767"], 0),
  (["PRINT 65535"], ["-1"], 0),                      # still a 16-bit pattern (documented): addresses
  (["PRINT 65536"], [], 64),
  (["PRINT 100000"], [], 64),
  (["x = 99999999"], [], 64),
  (["PRINT 3000.5"], ["3000.5000"], 0),
  (["PRINT 12345.5"], ["12345.5000"], 0),            # mantissa 123455 > 32767 -> now an error, was garbage
  (["PRINT 3276.7"], ["3276.7000"], 0),
  (["PRINT 3276.8"], [], 64),                         # mantissa 32768 would be negative
  (["PRINT 0.5"], ["0.5000"], 0),
  (["PRINT 7"], ["7"], 0),
]
def main():
    P.boot(); bad = 0
    for prog, want, wce in CASES:
        out, ce, ve = capture_prints(prog, boot=False)
        ok = (ce == wce) and (wce != 0 or (out == want and ve == 0))
        bad += not ok
        print("%-5s %-60s -> %s ce=%d ve=%d%s" % ("PASS" if ok else "FAIL", " : ".join(prog), out, ce, ve, "" if ok else "  WANT %s ce=%d" % (want, wce)), flush=True)
    D("stop"); return 1 if bad else 0
if __name__ == "__main__":
    sys.exit(main())
