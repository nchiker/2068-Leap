#!/usr/bin/env python3
"""Numeric literals end to end (docs/V2_LEAPC_BACKPORT_PLAN.md item 5.1).

Compiles and runs programs of `vN = <literal>` lines on the production ROM (edge forms such as "2.0",
"1.", "0.0001", "32767.5", "65535.5", "4294967296", plus random short decimals) and reads each
variable's tag and value (an INT, or a FLOAT's 5 bytes from RT_FLOATTAB_PTR). Writes
[literal, tag, value] per literal as JSON; --ref FILE compares with an earlier run (another build's):
PASS when every tag and value is identical.

Usage: python3 tools/qual/qliterals.py [--tree DIR] [--port N] [--out FILE] [--ref FILE] [--random N]
"""
import argparse
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine          # noqa: E402

EDGE = ["2.0", "0.0001", "32767.5", "3276.7", "1.", "5.", "10.", "0.", "0.5", "1.5000", "0.00001", "3.14159",
        "12345.678", "9999.5", "65535.5", "65536", "100000", "4294967296", "1.0", "0.0", "00.5", "007.25",
        "3275.95", "3276.5", "32759.1", "32760.1", "32767.9999", "3.2767", "0.0005", "6553.5", "65535",
        "32768", "32767", "1.25", "10.5", "3.1416", "0.1", "0.2", "0.3", "2.25", "1000.25", "3.14159265"]
PER_PROGRAM = 50


def literals(n):
    rng = random.Random(2068)
    out = list(EDGE)
    for _ in range(n):
        k = rng.randint(1, 4)
        s = str(rng.randrange(32768)).rjust(k + 1, "0")
        out.append(s[:-k] + "." + s[-k:])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".")
    ap.add_argument("--port", type=int, default=10898)
    ap.add_argument("--out", default=None)
    ap.add_argument("--ref", default=None)
    ap.add_argument("--random", type=int, default=1500)
    a = ap.parse_args()
    lits = literals(a.random)
    m = Machine(a.tree, a.port, label="qliterals")
    rows = []
    bad = 0
    try:
        m.start()
        for i in range(0, len(lits), PER_PROGRAM):
            chunk = lits[i:i + PER_PROGRAM]
            r = m.run_program(["v%d = %s" % (j, l) for j, l in enumerate(chunk)])
            if r.ce or r.ve or r.status != "OK":
                print("  program at literal %d: compile error %d, run-time error %d, %s" % (i, r.ce, r.ve, r.status))
                bad += 1
                continue
            ft = m.w16(m.sym("RT_FLOATTAB_PTR"))
            for l, (tag, v) in zip(chunk, m.scalars(len(chunk))):
                rows.append([l, tag, m.read(ft + 5 * v, 5).hex() if tag == 1 else v])
    finally:
        m.stop()
    print("qliterals: %d literals compiled and run: %s" % (len(rows), "PASS" if not bad else "FAIL (%d programs)" % bad))
    if a.out:
        json.dump(rows, open(a.out, "w"))
    if a.ref:
        ref = json.load(open(a.ref))
        diff = [(r, s) for r, s in zip(rows, ref) if r != s]
        for r, s in diff[:10]:
            print("  differs: %r, reference %r" % (r, s))
        print("qliterals: every tag and value equals the reference run's: %s" % (
            "PASS" if not diff and len(ref) == len(rows) else "FAIL (%d)" % len(diff)))
        bad += len(diff)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
