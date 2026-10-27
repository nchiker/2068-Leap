#!/usr/bin/env python3
"""Printing programs that scroll, on two builds: the whole screen (6,144 bitmap and 768 attribute
bytes) compared after each. For output changes that must draw the same bytes (5.8 the row clear,
5.11 the scroll copy, 5.13 string printing): colours, BRIGHT/FLASH, INVERSE, OVER, lines that wrap,
commas and semicolons, AT 23, PLOT before a scroll, CLS, the block graphics and UDGs.

  python3 tools/qual/qscrdiff.py [--root DIR] cfgA cfgB [--port N]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine  # noqa: E402


def lines(n):
    return ["FOR i = 1 TO %d" % n, "PRINT i", "NEXT i"]


PROGRAMS = {
    "plain": lines(40),
    "colours": ["INK 2", "PAPER 6"] + lines(30),
    "bright-flash": ["BRIGHT 1", "FLASH 1", "INK 1"] + lines(30),
    "inverse": ["INVERSE 1"] + lines(30),
    "over": ["OVER 1"] + lines(30),
    "mixed": ["FOR i = 1 TO 30", "INK i - 7 * DIV(i, 7)", "PAPER 7 - i + 7 * DIV(i, 7)", 'PRINT "line"; i', "NEXT i"],
    "long-lines": ['a$ = "0123456789ABCDEFGHIJ" + "KLMNOPQRSTUVWXYZabcdefgh"', "FOR i = 1 TO 20", "PRINT a$",
                   "NEXT i"],
    "strings": ['a$ = "The quick brown fox jumps"', "FOR i = 1 TO 30", "PRINT a$; i", "NEXT i"],
    "commas": ["FOR i = 1 TO 30", "PRINT i, i * 2", "NEXT i"],
    "semicolons": ["FOR i = 1 TO 200", "PRINT i;", "NEXT i"],
    "at-bottom": ["FOR i = 1 TO 10", "AT 23, 0", "PRINT i", "NEXT i"],
    "at-strings": ["FOR i = 0 TO 23", "AT i, i", 'PRINT "AT"; i;', "NEXT i"],
    "plot-scroll": ["FOR x = 0 TO 255", "PLOT x, 100", "NEXT x"] + lines(10),
    "cls-scroll": lines(30) + ["CLS"] + lines(28),
    "udg-block": ["FOR i = 128 TO 164", "PRINT CHR$(i);", "NEXT i"] + lines(24),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                                   "build", "qual-builds"))
    ap.add_argument("--port", type=int, default=10940)
    a = ap.parse_args()
    res = {}
    for k, cfg in enumerate((a.a, a.b)):
        m = Machine(os.path.join(a.root, cfg), a.port + k).start()
        try:
            res[cfg] = {}
            for name, prog in PROGRAMS.items():
                r = m.run_program(prog, maxi=300_000_000)
                res[cfg][name] = (r.ce, r.ve, r.status, m.read(0x4000, 6912))
        finally:
            m.stop()
    bad = 0
    for name in PROGRAMS:
        x, y = res[a.a][name], res[a.b][name]
        same = x == y
        bad += not same or y[0] or y[1] or y[2] != "OK"
        print("%s %-13s ce=%d ve=%d %s" % ("SAME" if same else "DIFF", name, y[0], y[1], y[2]))
        if not same:
            d = [i for i in range(6912) if x[3][i] != y[3][i]]
            print("   %d bytes differ, the first at %04X" % (len(d), 0x4000 + d[0]) if d else
                  "   codes differ: %s against %s" % (x[:3], y[:3]))
    print("qscrdiff: %d programs, %d differ or did not run cleanly" % (len(PROGRAMS), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
