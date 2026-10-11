#!/usr/bin/env python3
"""STUDY D11: promoted results and float display, end to end through the real compiler/VM/PRINT."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from study_util import *

CASES = [  # (program, expected printed strings or None)
    (["PRINT 30000 * 3"], ["90000.0000"]),
    (["PRINT 32767 + 1"], ["32768.0000"]),
    (["a = -32767", "PRINT a - 2"], ["-32769.0000"]),
    (["PRINT 181 * 181"], ["32761"]),
    (["PRINT 182 * 182"], ["33124.0000"]),
    (["a = 32767", "PRINT a * a"], ["1073676289.0000"]),
    (["a = -32767 - 1", "PRINT a * a"], ["1073741824.0000"]),
    (["a = -32767 - 1", "PRINT 0 - a"], ["32768.0000"]),
    (["a = 30000 * 3", "PRINT a + 10"], ["90010.0000"]),
    (["a = 30000 * 3", "PRINT a / 3"], ["30000.0000"]),
    (["a = 1000", "b = a * a", "PRINT b"], ["1000000.0000"]),
    (["a = 1000", "b = a * a", "c = b * a", "PRINT c"], ["1000000000.0000"]),
    (["a = 30000 * 3", "b = a - 30000 - 30000 - 20000", "PRINT b"], ["10000.0000"]),
    (["PRINT 200 * 100"], ["20000"]),
    (["FOR i = 32765 TO 32767", "PRINT i", "NEXT i", "PRINT 99"], ["32765", "32766", "32767", "99"]),
]

def main():
    P.boot()
    bad = 0
    for prog, want in CASES:
        out, ce, ve = capture_prints(prog, boot=False)
        ok = (out == want) and ce == 0 and ve == 0
        bad += not ok
        print("%-5s %-60s -> %s (ce=%d ve=%d)%s" % ("PASS" if ok else "FAIL", " : ".join(prog), out, ce, ve, "" if ok else "   WANT %s" % want))
    D("stop")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
