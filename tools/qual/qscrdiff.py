#!/usr/bin/env python3
"""Printing programs that scroll, on two builds: the whole screen (6,144 bitmap and 768 attribute
bytes) compared after each. For output changes that must draw the same bytes (5.8 the row clear,
5.11 the scroll copy, 5.13 string printing): colours, BRIGHT/FLASH, INVERSE, OVER, lines that wrap,
commas and semicolons, AT 23, PLOT before a scroll, CLS, the block graphics and UDGs; for 5.13 every
character code, OVER and INVERSE over text, rows of exactly 32, wraps that scroll inside a string,
empty strings and positions off the screen.

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
    # 5.13: strings -- every character code (punctuation, block graphics, UDGs, codes with no glyph),
    # OVER and INVERSE over text, rows of exactly 32, a wrap that scrolls inside a string, empty
    # strings, and positions off the screen (only a POKE of the output cells makes them)
    "chars-all": ["FOR i = 1 TO 255", "PRINT CHR$(i);", "NEXT i", "PRINT", "FOR i = 32 TO 127", "PRINT CHR$(i);",
                  "NEXT i"],
    "over-strings": ['a$ = "Hello, world! 0123"', "FOR i = 0 TO 5", "AT i, i", "PRINT a$", "NEXT i", "OVER 1",
                     "FOR i = 0 TO 5", "AT i, 2 * i", "PRINT a$", "NEXT i", "AT 3, 0", 'PRINT "#####"', "AT 3, 0",
                     'PRINT "#####"', "INVERSE 1", "AT 8, 0", "PRINT a$", "AT 8, 4", "PRINT a$"],
    "inverse-strings": ["INVERSE 1", "INK 2", 'a$ = "inverse text"', "FOR i = 1 TO 30", "PRINT a$; i", "NEXT i"],
    # (a string holds at most 31 characters: "-" and a$ fill the 32 columns)
    "exact-32": ['a$ = "0123456789ABCDEFGHIJ" + "KLMNOPQRSTU"', "FOR i = 1 TO 30", 'PRINT "-"; a$', "NEXT i",
                 "FOR i = 1 TO 5", "PRINT a$;", "NEXT i", 'PRINT "end"', "AT 23, 1", "PRINT a$;", 'PRINT "e"'],
    "wrap-bottom": ['a$ = "0123456789ABCDEFGHIJ" + "KLMNOPQRSTUVWXYZ"', "FOR i = 0 TO 12", "AT 23, i * 2", "PRINT a$;",
                    "NEXT i", "AT 10, 31", 'PRINT "xyz"', "AT 23, 31", 'PRINT "q";', 'PRINT "r"'],
    "empty": ['a$ = ""', "FOR i = 1 TO 30", "PRINT a$", "PRINT a$; i; a$", 'PRINT "";', "NEXT i"],
    "poke-off": ['a$ = "0123456789ABCDEFGHIJ" + "KLMNOPQRSTUVWXYZabcd"', "AT 5, 3", 'PRINT "before"',
                 "POKE {ROW}, 30", "PRINT a$", 'PRINT "after1"', "POKE {COL}, 40", 'PRINT "xyz"', "POKE {COL}, 255",
                 'PRINT "pq"', "POKE {ROW}, 255", "POKE {COL}, 0", "PRINT a$; a$", 'PRINT "after2"'],
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
            cells = {"ROW": m.sym("VM_OUTPUT_ROW"), "COL": m.sym("VM_OUTPUT_COL")}
            for name, prog in PROGRAMS.items():
                r = m.run_program([ln.format(**cells) for ln in prog], maxi=300_000_000)
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
