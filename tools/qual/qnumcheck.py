#!/usr/bin/env python3
"""Literal and parser values against Leap-C's float model (R1, docs/V2_LEAPC_BACKPORT_PLAN.md).

With R1 the calculator rounds, so a value NUM_PARSE_CALC computes may change in its last bit against
a build before R1 (qliterals.py / qnumparse.py --ref report those as differences). This checks such a
run against the expected values instead: NUM_PARSE_CALC's own sequence of operations (digits in 16
bits while x < 3276, then x * 10 + d in the calculator; up to 9 fraction digits; 10^k built in 16 bits
up to 10^4, then * 10; one division; 0 - x for a '-') replayed through Leap-C's bit-exact model
(DIR/tools/fpmodel.py, the arithmetic R1 brought in). A FLOAT must have the model's value; an INT, the
model's integer; tags, fraction digits, characters used and errors must equal the reference run's.

Usage: python3 tools/qual/qnumcheck.py --leapc DIR (--literals RUN.json | --numparse RUN.json) [--ref OLD.json]
"""
import argparse
import importlib.util
import json
import os
import sys
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qcalcround import value, general       # noqa: E402


def model(fp, text):
    """NUM_PARSE_CALC on text (all of it available) -> (5 bytes, fraction digits, characters used)."""
    def g(v):
        return general(v) if v else bytes(5)
    i, n = 0, len(text)
    while i < n and text[i] == " ":
        i += 1
    neg = False
    if i < n and text[i] in "+-":
        neg = text[i] == "-"
        i += 1
    x, xf, frac, dot = 0, None, 0, False
    while i < n:
        ch = text[i]
        if ch == ".":
            if dot:
                break
            dot = True
            i += 1
            continue
        if not "0" <= ch <= "9":
            break
        d = ord(ch) - 48
        i += 1
        if dot:
            if frac >= 9:
                continue
            frac += 1
        if xf is None and x < 3276:
            x = x * 10 + d
        else:
            if xf is None:
                xf = g(x)
            xf = fp.binop("+", fp.binop("*", xf, g(10)), g(d))
    if xf is None:
        xf = g(x)
    if frac:
        p = g(10 ** min(frac, 4))
        for _ in range(max(0, frac - 4)):
            p = fp.binop("*", p, g(10))
        xf = fp.binop("/", xf, p)
    if neg:
        xf = fp.binop("-", g(0), xf)
    return xf, frac, i


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--leapc", required=True)
    ap.add_argument("--literals", default=None)
    ap.add_argument("--numparse", default=None)
    ap.add_argument("--ref", default=None)
    a = ap.parse_args()
    spec = importlib.util.spec_from_file_location("fpmodel", os.path.join(a.leapc, "tools", "fpmodel.py"))
    fp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fp)
    ref = json.load(open(a.ref)) if a.ref else None
    bad = []
    if a.literals:
        rows = json.load(open(a.literals))
        for k, (lit, tag, v) in enumerate(rows):
            want, _, _ = model(fp, lit)
            if tag == 1:
                ok = value(bytes.fromhex(v)) == value(want)
            else:
                ok = Fraction(v - 65536 if v > 32767 else v) == value(want) or Fraction(v) == value(want)
            if ref and ref[k][:2] != [lit, tag]:
                ok = False
            if not ok:
                bad.append((lit, tag, v, want.hex()))
        changed = sum(1 for r, s in zip(rows, ref) if r != s) if ref else None
        name = "qnumcheck literals"
    else:
        rows = json.load(open(a.numparse))
        for k, (text, b, v, sp, frac, used, err) in enumerate(rows):
            want, wfrac, wused = model(fp, text if b == 255 else text[:b])
            ok = value(bytes.fromhex(v)) == value(want) and err == 0 and sp == 1
            if ref and ref[k][:2] + ref[k][3:] != [text, b, sp, frac, used, err]:
                ok = False
            if not ok:
                bad.append((text, b, v, want.hex(), frac, wfrac, used, wused))
        changed = sum(1 for r, s in zip(rows, ref) if value(bytes.fromhex(r[2])) != value(bytes.fromhex(s[2]))) \
            if ref else None
        name = "qnumcheck numparse"
    for row in bad[:10]:
        print("  differs:", row)
    print("%s: %d values, %s; every value the model's: %s (%d)" % (
        name, len(rows), "%d changed against the reference" % changed if ref else "no reference",
        "PASS" if not bad else "FAIL", len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
