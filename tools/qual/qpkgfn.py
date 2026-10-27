#!/usr/bin/env python3
"""6.1 prototype (docs/V2_LEAPC_BACKPORT_PLAN.md): package functions, package ABI 2.1.

Installs the test package rom/v2_package_fntest.asm (build/v2_package_fntest.bin: registered through
its export table, EXT2_EXPORTS) into the production ROM and runs small programs through V2_RUN_STORED:
numeric and string functions, their values in expressions, nesting (a function in a function's
arguments, in a statement's, in LPRINT-shaped string concatenation), five arguments with a string
among them, an error raised by a function, the binding rules (a name binds only where its kind fits;
the ROM's built-ins win) and the compile errors of a wrong call. Then the shipped ABI 2.0 packages
(statements only) are installed and one statement of each is run.

Usage: python3 tools/qual/qpkgfn.py [--tree DIR] [--port N]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine          # noqa: E402

PKG = ("fntest",)

# (name, program, expected output rows (None: not checked), expected ce, expected ve)
CASES = [
    ("int result", ["PRINT ADD3(1, 2, 3)"], ["6"], 0, 0),
    ("in an expression", ["a = ADD3(1, 2, 3) * 2 + SEVEN()", "PRINT a"], ["19"], 0, 0),
    ("no arguments", ["PRINT SEVEN() - 1"], ["6"], 0, 0),
    ("nested in its own arguments",
     ["PRINT ADD3(ADD3(1, 1, 1), SEVEN(), ADD3(SEVEN(), 0, 0))"], ["17"], 0, 0),
    ("negative and 16-bit", ["PRINT ADD3(-5, 2, 0)"], ["-3"], 0, 0),
    ("string result", ["a$ = HEX$(48879)", "PRINT a$"], ["BEEF"], 0, 0),
    ("string result concatenated", ['PRINT "x" + HEX$(255) + REV$("abc")'], ["x00FFcba"], 0, 0),
    ("string argument", ['PRINT SLEN("hello")'], ["5"], 0, 0),
    ("string in string in number", ["PRINT SLEN(REV$(HEX$(1)))"], ["4"], 0, 0),
    ("empty string result", ['a$ = REV$("")', "PRINT LEN(a$)"], ["0"], 0, 0),
    ("31-character string result", ['a$ = REV$("abcdefghijklmnopqrstuvwxyz01234")', "PRINT LEN(a$)", "PRINT a$"],
     ["31", "43210zyxwvutsrqponmlkjihgfedcba"], 0, 0),
    ("two string temps live", ['PRINT REV$("ab") + REV$("cd") + REV$("ef")'], ["badcfe"], 0, 0),
    ("five arguments, a string third", ['PRINT MIX(1, 2, "abc", 4, 5)'], ["55"], 0, 0),
    ("statement with a function argument", ["SETR ADD3(1, 2, SEVEN())", "PRINT GETR()"], ["10"], 0, 0),
    ("function in IF and FOR", ["s = 0", "FOR i = 1 TO SEVEN()", "IF ADD3(i, 0, 0) > 5 THEN", "s = s + i",
                                "ENDIF", "NEXT i", "PRINT s"], ["13"], 0, 0),
    ("function in IF ... THEN GOTO", ["IF SEVEN() = 7 THEN GOTO yes", "PRINT 0", "yes:", "PRINT 1"], ["1"], 0, 0),
    ("built-in string function inside", ['PRINT SLEN(STR$(ADD3(100, 20, 3)))'], ["3"], 0, 0),
    ("error from a function", ["PRINT 1", "a = BAD(1)", "PRINT 2"], ["1"], 0, 15),
    ("no error from a function", ["PRINT BAD(0) + 1"], ["1"], 0, 0),
    # binding: the ROM's ABS wins over the package's
    ("built-in wins", ["PRINT ABS(-5)"], ["5"], 0, 0),
    # a variable may share a function's name (a statement is looked up as a statement only)
    ("variable named like a function", ["SEVEN = 3", "PRINT SEVEN + SEVEN()"], None, 29, 0),
    ("assignment to that name compiles", ["SEVEN = 3"], [], 0, 0),
    # compile errors of a wrong call
    ("function at statement start", ["SEVEN()"], None, -1, 0),
    ("statement used as a function", ["a = SETR(1)"], None, -1, 0),
    ("numeric function as a string", ["a$ = ADD3$(1, 2, 3)"], None, -1, 0),
    ("string function as a number", ["a = HEX(1)"], None, -1, 0),
    ("too few arguments", ["a = ADD3(1, 2)"], None, 30, 0),
    ("too many arguments", ["a = ADD3(1, 2, 3, 4)"], None, 31, 0),
    ("no parentheses", ["a = ADD3 1, 2, 3"], None, 29, 0),
    ("string argument given a number", ["a = SLEN(5)"], None, -1, 0),
    ("numeric argument given a string", ['a = ADD3("a", 2, 3)'], None, -1, 0),
]

# without the package, the same names are not functions
UNLOADED = [
    ("unloaded: SEVEN()", ["a = SEVEN()"], None, -1, 0),
    ("unloaded: HEX$()", ["a$ = HEX$(1)"], None, -1, 0),
]

# ABI 2.0 packages (statements only) still register and run (only row 0, the PRINT, is checked)
OLD = [
    ("shapes: CIRCLE", "shapes", ["CIRCLE 128, 96, 20", "PRINT 1"], ["1"], 0, 0),
    ("graphics: a statement", "graphics", ["PLOT 1, 1", "PRINT 1"], ["1"], 0, 0),
    ("mode: MODE 0", "mode", ["MODE 0", "PRINT 1"], ["1"], 0, 0),
    ("sprite: GRAB", "sprite", ["GRAB 0, 2, 3, 2, 2", "PRINT 1"], ["1"], 0, 0),
    ("cbeep: CBEEP", "cbeep", ["CBEEP 10, 0, 7", "PRINT 1"], ["1"], 0, 0),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=os.getcwd())
    ap.add_argument("--port", type=int, default=10310)
    a = ap.parse_args()
    m = Machine(a.tree, a.port)
    fails = []

    def run(name, lines, rows, ce, ve, pkgs, nrows=22):
        r = m.run_program(lines, packages=pkgs, maxi=80_000_000)
        got = [x.strip() for x in r.rows[:nrows]]
        while got and not got[-1]:
            got.pop()
        ok = r.status == "OK" and r.ve == ve and (r.ce == ce if ce >= 0 else r.ce != 0)
        if rows is not None:
            ok = ok and got == rows
        print("%s  %-40s ce=%-3d ve=%-3d %s" % ("PASS" if ok else "FAIL", name, r.ce, r.ve,
                                                 "" if ok else "out=%r status=%s" % (got, r.status)))
        if not ok:
            fails.append(name)

    m.start()
    try:
        for name, lines, rows, ce, ve in CASES:
            run(name, lines, rows, ce, ve, PKG)
        for name, lines, rows, ce, ve in UNLOADED:
            run(name, lines, rows, ce, ve, ())
        for name, pkg, lines, rows, ce, ve in OLD:
            run(name, lines, rows, ce, ve, (pkg,), nrows=1)
    finally:
        m.stop()
    n = len(CASES) + len(UNLOADED) + len(OLD)
    print("qpkgfn: %d/%d PASS" % (n - len(fails), n))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
