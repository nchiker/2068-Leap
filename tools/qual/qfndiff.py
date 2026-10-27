#!/usr/bin/env python3
"""A numeric built-in function on two builds, result by result: `v = F(arg)` for ~1,900 arguments
(integers 0-599 and to 32767, decimals of 1-4 places, 10^6 and 10^-6 scales, products past 32767,
and for any function but SQR their negatives), every result's tag and 5 bytes compared. For changes
that must keep a function's results (5.7 SQR, 5.9 the built-ins moved to the EXROM), or to list what
a change that may alter the last bits (5.10) does.

  python3 tools/qual/qfndiff.py [--root DIR] cfgA cfgB FN [--port N] [--show N]
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine  # noqa: E402

PER_PROGRAM = 24


def arguments(fn):
    rnd = random.Random(2068)
    args = [str(i) for i in range(0, 600)] + [str(rnd.randint(600, 32767)) for _ in range(300)]
    args += ["%d.%0*d" % (rnd.randint(0, 999), k, rnd.randint(0, 10 ** k - 1)) for k in (1, 2, 3, 4) for _ in range(150)]
    args += ["%d.%d * 1000000" % (rnd.randint(1, 9999), rnd.randint(0, 99)) for _ in range(150)]
    args += ["0.%04d / 1000000" % rnd.randint(1, 9999) for _ in range(150)]
    args += ["%d * %d * 1000" % (rnd.randint(100, 30000), rnd.randint(100, 30000)) for _ in range(100)]
    f = fn.upper()
    if f != "SQR":
        args += ["-(%s)" % a for a in args[1:600:3]]
    # (the arguments are this script's own arithmetic, valid Python as written)
    if f in ("SIN", "COS", "TAN"):          # degrees: 32768 or more is error 15
        args = [a for a in args if abs(eval(a)) < 32768]
    if f == "TAN":                          # an odd multiple of 90 degrees is error 5
        args = [a for a in args if eval(a) % 180 != 90]
    return args


def run(cfgdir, port, fn, args):
    m = Machine(cfgdir, port).start()
    out = []
    try:
        for i in range(0, len(args), PER_PROGRAM):
            chunk = args[i:i + PER_PROGRAM]
            r = m.run_program(["v%d = %s(%s)" % (j, fn, a) for j, a in enumerate(chunk)])
            if r.ce or r.ve or r.status != "OK":
                out += [(a, "error ce=%d ve=%d %s" % (r.ce, r.ve, r.status), None) for a in chunk]
                continue
            ft = m.w16(m.sym("RT_FLOATTAB_PTR"))
            out += [(a, t, m.read(ft + 5 * v, 5).hex() if t == 1 else v)
                    for a, (t, v) in zip(chunk, m.scalars(len(chunk)))]
    finally:
        m.stop()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("fn")
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                                   "build", "qual-builds"))
    ap.add_argument("--port", type=int, default=10930)
    ap.add_argument("--show", type=int, default=8)
    a = ap.parse_args()
    args = arguments(a.fn)
    ra = run(os.path.join(a.root, a.a), a.port, a.fn, args)
    rb = run(os.path.join(a.root, a.b), a.port + 1, a.fn, args)
    errors = sum(1 for x in ra if x[2] is None)
    diff = [(x, y) for x, y in zip(ra, rb) if x != y]
    for x, y in diff[:a.show]:
        print("  %-24s %s: %s %s   %s: %s %s" % (x[0], a.a, x[1], x[2], a.b, y[1], y[2]))
    print("qfndiff %s: %d arguments (%d in programs that stopped, on %s), %d results differ"
          % (a.fn, len(args), errors, a.a, len(diff)))
    return 1 if diff else 0


if __name__ == "__main__":
    sys.exit(main())
