#!/usr/bin/env python3
"""SIN_COEFFS of rom/exrom_v2_float_fn.asm (back-port plan 5.10): where they come from.

sin x = x + x^3 R(x^2), x = a * pi/180 for an angle a in degrees, |a| <= 91 (SIN's reduction leaves
|a| < 91); R of degree 4 is the minimax fit of (sin x - x) / x^3 for the relative error of the
result (Remez exchange in 60-digit decimals), each coefficient then rounded to the nearest 5-byte
float. Prints the fit's error and the `db` lines.

--leapc DIR also runs SIN, COS and TAN as the ROM computes them (the reduction, then the series on
the calculator stack: x, x^2, x^3, Horner, x + x^3 P) through Leap-C's bit-exact model of the
calculator's arithmetic (DIR/tools/fpmodel.py, as tools/qual/qcalcround.py --leapc), over the
integers -720..720 and random FLOAT arguments, and scores the results against the exact values in
units of the last place. The ROM's own results: tools/qual/qfndiff.py --exact.

  python3 tools/qual/qsinfit.py [--leapc DIR] [--n N]
"""
import argparse
import importlib.util
import math
import os
import random
import sys
from decimal import Decimal as D, getcontext
from fractions import Fraction

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qcalcround import nearest, value  # noqa: E402
from qfndiff import PI, sin_deg  # noqa: E402

getcontext().prec = 60
DEG = 91


def dsin(x):
    term, total, k = x, x, 1
    while abs(term) > D(10) ** -58:
        term = -term * x * x / ((2 * k) * (2 * k + 1))
        total += term
        k += 1
    return total


def solve(m, b):
    n = len(b)
    m = [row[:] + [b[i]] for i, row in enumerate(m)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(m[r][c]))
        m[c], m[p] = m[p], m[c]
        for r in range(n):
            if r != c:
                f = m[r][c] / m[c][c]
                m[r] = [x - f * y for x, y in zip(m[r], m[c])]
    return [m[i][n] / m[i][i] for i in range(n)]


def fit(deg=4, iters=15, grid=3000):
    """Minimise max |x^3 / sin x * (R(t) - r(t))|, t = x^2, r = (sin x - x) / x^3: R's coefficients, the error."""
    xmax = D(DEG) * PI / 180
    tmax = xmax * xmax

    def r(t):
        x = t.sqrt()
        return (dsin(x) - x) / (x * x * x)

    def w(t):
        x = t.sqrt()
        return x * x * x / dsin(x)

    m = deg + 2
    ref = [tmax * (1 - D(math.cos(math.pi * i / (m - 1)))) / 2 for i in range(m)]
    ref[0] = tmax / 10 ** 6
    pts = [tmax * D(i) / grid for i in range(1, grid + 1)]
    rp, wp = [r(t) for t in pts], [w(t) for t in pts]
    for _ in range(iters):
        sol = solve([[t ** j for j in range(deg + 1)] + [(-1) ** i / w(t)] for i, t in enumerate(ref)],
                    [r(t) for t in ref])
        c = sol[:-1]
        err = [wt * (sum(cj * t ** j for j, cj in enumerate(c)) - rt) for t, rt, wt in zip(pts, rp, wp)]
        ext = [i for i in range(len(err))
               if (i == 0 or abs(err[i]) >= abs(err[i - 1])) and (i + 1 == len(err) or abs(err[i]) >= abs(err[i + 1]))]
        alt = []
        for i in ext:
            if alt and (err[i] > 0) == (err[alt[-1]] > 0):
                if abs(err[i]) > abs(err[alt[-1]]):
                    alt[-1] = i
            else:
                alt.append(i)
        while len(alt) > m:
            alt.pop(0 if abs(err[alt[0]]) < abs(err[alt[-1]]) else -1)
        if len(alt) == m:
            ref = [pts[i] for i in alt]
    return c, max(abs(e) for e in err)


def five(v):
    return nearest(Fraction(v))[0]


class Model:
    """The ROM's SIN/COS/TAN on Leap-C's float model (the same steps, the same roundings)."""
    def __init__(self, leapc, coeffs):
        spec = importlib.util.spec_from_file_location("fpmodel", os.path.join(leapc, "tools", "fpmodel.py"))
        self.fp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.fp)
        self.k, self.c = coeffs[0], coeffs[1:]

    def op(self, o, a, b):
        g = lambda x: self.fp.fri(x[2] | x[3] << 8) if x[0] == 0 else bytes(x)   # noqa: E731 (FUNPK's small form)
        return self.fp.binop(o, g(a), g(b))

    @staticmethod
    def small(v):
        v &= 0xFFFF
        return bytes([0, 0xFF if v & 0x8000 else 0, v & 255, v >> 8, 0])

    def trunc(self, b):
        if b[0] == 0 or b[0] >= 160:
            return bytes(b)
        if b[0] <= 128:
            return bytes(5)
        n = 160 - b[0]
        m = int.from_bytes(b[1:5], "big") & ~((1 << n) - 1)
        return b[:1] + m.to_bytes(4, "big")

    def angle(self, x, shift):
        """x (5 bytes, or an int): (the reference angle a, the sign); None for error 15."""
        if isinstance(x, int):
            k, f = x, bytes(5)
        else:
            kb = self.trunc(x)
            if kb[0] > 143:
                return None
            k = value(kb).numerator
            f = self.op("-", x, kb)
        mod = lambda h: (abs(h) % 360) * (-1 if h < 0 else 1)  # noqa: E731
        r = mod(mod(k) + shift)
        neg = fneg = 0
        if r < 0:
            neg, fneg, r = 1, 1, -r
        if r >= 180:
            r -= 180
            neg ^= 1
        if r >= 91:
            r, fneg = 180 - r, fneg ^ 1
        if r == 0 and f[0] == 0:
            neg = 0
        return self.op("-" if fneg else "+", self.small(r), f), neg

    def sin(self, x, shift=0):
        an = self.angle(x, shift)
        if an is None:
            return None
        a, neg = an
        x1 = self.op("*", a, self.k)
        x2 = self.op("*", x1, x1)
        x3 = self.op("*", x1, x2)
        p = self.c[-1]
        for c in reversed(self.c[:-1]):
            p = self.op("+", c, self.op("*", p, x2))
        s = self.op("+", x1, self.op("*", x3, p))
        return bytes([s[0], s[1] ^ 0x80]) + s[2:] if neg else s

    def cos(self, x):
        return self.sin(x, 90)

    def tan(self, x):
        t = x if not isinstance(x, int) else self.small(x)
        c, s = self.cos(t), self.sin(t)
        if c is None or s is None or (c[0] == 0 and not any(c[2:4])):
            return None
        return self.op("/", s, c)


def score(name, results):
    errs = []
    for x, got in results:
        if got is None:
            continue
        ex = Fraction({"SIN": sin_deg, "COS": lambda v: sin_deg(v + 90),
                       "TAN": lambda v: sin_deg(v) / sin_deg(v + 90)}[name](x))
        want, ulp, _ = nearest(ex)
        g = value(got)
        errs.append((0.0 if ulp is None and g == 0 else abs(float((g - ex) / ulp)) if ulp else float("inf"), value(want) == g))
    n = len(errs)
    print("  %s: %d arguments, %.1f%% correctly rounded, %.1f%% within 1 ulp, largest %.2f ulp, mean %.3f ulp"
          % (name, n, 100.0 * sum(e[1] for e in errs) / n, 100.0 * sum(e[0] <= 1 for e in errs) / n,
             max(e[0] for e in errs), sum(e[0] for e in errs) / n))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--leapc", default=None)
    ap.add_argument("--n", type=int, default=3000, help="random FLOAT arguments for --leapc")
    a = ap.parse_args()
    c, err = fit()
    k = five(PI / 180)
    coeffs = [k] + [five(x) for x in c]
    print("sin x = x + x^3 R(x^2), |x| <= %d degrees: R's relative error %.3e (fit, before rounding)" % (DEG, err))
    print("SIN_COEFFS:")
    for b, name in zip(coeffs, ["pi/180"] + ["c%d" % (2 * j + 3) for j in range(len(c))]):
        print("        db %s       ; %+.12e %s" % (",".join("$%02X" % x for x in b), float(value(b)), name))
    if a.leapc:
        m = Model(a.leapc, coeffs)
        rnd = random.Random(2068)
        ints = list(range(-720, 721))
        floats = []
        for _ in range(a.n):
            v = rnd.uniform(-32767, 32767) if rnd.random() < 0.3 else rnd.uniform(-720, 720)
            floats.append(five(Fraction(v)))
        args = [(Fraction(i), i) for i in ints] + [(value(b), b) for b in floats]
        print("simulated (Leap-C's model), %d integers and %d FLOAT arguments:" % (len(ints), len(floats)))
        score("SIN", [(x, m.sin(b)) for x, b in args])
        score("COS", [(x, m.cos(b)) for x, b in args])
        score("TAN", [(x, m.tan(b)) for x, b in args if (x - 90) % 180 != 0])


if __name__ == "__main__":
    sys.exit(main())
