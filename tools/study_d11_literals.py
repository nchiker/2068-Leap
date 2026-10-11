#!/usr/bin/env python3
"""STUDY D11 literal policy, final rules (L-C): address literals keep working, large and decimal literals are exact."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from study_util import *
CASES = [  # (program, want printed, want compile error)
  # RC (final rules): literal rule L-C (owner decision 3) -- 32768..65535 are positive FLOAT values and
  # still work as addresses; larger literals and decimals are exact 5-byte floats (Q-15/Q-16, D10); only a
  # literal beyond the float range (about 1.7E38) is error 64. The L-A/D11 expectations this tool had
  # (65535 -> -1, 65536 -> error 64, 3276.7 -> 3276.6999) are superseded.
  (["POKE 65000, 42", "PRINT PEEK(65000)"], ["42"], 0),
  (["POKE 61440, 33", "POKE 61441, 5", "POKE 61442, 0", "POKE 61443, 201", "PRINT USR(61440)"], ["5"], 0),
  (["PRINT 32767"], ["32767"], 0),
  (["PRINT 65535"], ["65535.0000"], 0),              # L-C: positive; a FLOAT prints 4 decimals
  (["PRINT 65536"], ["65536.0000"], 0),
  (["PRINT 100000"], ["100000.0000"], 0),
  (["x = 99999999", "PRINT x"], ["99999999.0000"], 0),
  (["PRINT 3000.5"], ["3000.5000"], 0),
  (["PRINT 12345.5"], ["12345.5000"], 0),
  (["PRINT 3276.7"], ["3276.7000"], 0),              # D10 fixed: rounded, not truncated
  (["PRINT 3276.8"], ["3276.8000"], 0),
  (["PRINT 1" + "0" * 40], [], 64),                   # beyond the float range
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
