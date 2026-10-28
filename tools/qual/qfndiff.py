#!/usr/bin/env python3
"""A numeric built-in function on two builds, result by result: `v = F(arg)` for ~1,900 arguments
(integers 0-599 and to 32767, decimals of 1-4 places, 10^6 and 10^-6 scales, products past 32767,
and for any function but SQR their negatives), every result's tag and 5 bytes compared. For changes
that must keep a function's results (5.7 SQR, 5.9 the built-ins moved to the EXROM), or to list what
a change that may alter the last bits (5.10) does.

--exact also scores each build's results against the exact value of the function at the argument as
the ROM holds it (read back from `v = (arg)` on cfgA), as tools/qual/qcalcround.py scores the
arithmetic: the share correctly rounded (the exact value rounded to the nearest 5-byte float), within
1 ulp, the largest error in units of the last place and where, and the mean; an exact 0 counts as
correct only when the result is 0. SIN, COS, TAN (degrees) and SQR.

  python3 tools/qual/qfndiff.py [--root DIR] cfgA cfgB FN [--port N] [--show N] [--exact]
"""
import argparse
import os
import random
import sys
from decimal import Decimal, getcontext
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine  # noqa: E402
from qcalcround import value, nearest  # noqa: E402

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


PI = Decimal("3.14159265358979323846264338327950288419716939937510582097494459230781640628620899863")


def dec(q):
    return Decimal(q.numerator) / Decimal(q.denominator)


def sin_deg(x):
    """sin(x degrees), x a Fraction, to ~60 digits (the angle reduced exactly first)."""
    if x % 180 == 0:
        return Decimal(0)
    r = dec(x % 360) * PI / 180
    term, total, k = r, r, 1
    while abs(term) > Decimal(10) ** -70:
        term = -term * r * r / ((2 * k) * (2 * k + 1))
        total += term
        k += 1
    return total


EXACT = {"SIN": sin_deg, "COS": lambda x: sin_deg(x + 90),
         "TAN": lambda x: sin_deg(x) / sin_deg(x + 90), "SQR": lambda x: dec(x).sqrt()}


def score(fn, argvals, res, show):
    """Each result against the exact value: (correctly rounded, within 1 ulp, scored, max |ulp|, its argument,
    mean |ulp|); and the worst few printed."""
    getcontext().prec = 80
    errs = []
    for (a, t, v), x in zip(res, argvals):
        if v is None or x is None:
            continue
        got = value(bytes.fromhex(v)) if t == 1 else Fraction(v - 65536 if v > 32767 else v)
        ex = EXACT[fn.upper()](x)
        q = Fraction(ex)
        want, ulp, _ = nearest(q)
        if ulp is None:
            errs.append((a, 0.0 if got == 0 else float("inf"), got == 0))
            continue
        errs.append((a, float((got - q) / ulp), value(want) == got))
    n = len(errs)
    worst = sorted(errs, key=lambda e: -abs(e[1]))
    for a, e, _ in worst[:show]:
        print("    %-24s %+.2f ulp" % (a, e))
    return (sum(1 for e in errs if e[2]), sum(1 for e in errs if abs(e[1]) <= 1), n,
            abs(worst[0][1]) if n else 0, worst[0][0] if n else "", sum(abs(e[1]) for e in errs) / max(n, 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("fn")
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                                   "build", "qual-builds"))
    ap.add_argument("--port", type=int, default=10930)
    ap.add_argument("--show", type=int, default=8)
    ap.add_argument("--exact", action="store_true")
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
    if a.exact:
        xs = [None if v is None else value(bytes.fromhex(v)) if t == 1 else Fraction(v - 65536 if v > 32767 else v)
              for _, t, v in run(os.path.join(a.root, a.a), a.port, "", args)]
        for cfg, res in ((a.a, ra), (a.b, rb)):
            print("  %s, the largest errors:" % cfg)
            ok, one, n, worst, where, mean = score(a.fn, xs, res, a.show)
            print("qfndiff --exact %s on %s: %d results, %d correctly rounded (%.1f%%), %d within 1 ulp, "
                  "largest %.2f ulp (%s), mean %.3f ulp" % (a.fn, cfg, n, ok, 100.0 * ok / max(n, 1), one,
                                                          worst, where, mean))
    return 1 if diff else 0


if __name__ == "__main__":
    sys.exit(main())
