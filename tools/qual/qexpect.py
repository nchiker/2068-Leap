"""Expectation objects and the independent numeric oracle for the qualification corpus.

Every expectation is written from the language's documented/intended behaviour (user manual,
V2 docs, owner decisions, exact mathematics) -- never copied from what the ROM printed.

Number display rule used as the reference (documented by example in the manual and by the
R10.8 matrix: `SQR(2)` -> `1.4142`, `7/2` -> `3.5000`): an INT-typed value prints as a plain
decimal integer; a FLOAT-typed value prints with exactly four decimals.  The four decimals are
the exact value **rounded** (half away from zero).  Truncation instead of rounding is the known
defect D10; a result that matches the truncated form but not the rounded one is classified D10.
"""
from decimal import Decimal, ROUND_HALF_UP, ROUND_DOWN
from fractions import Fraction as Fr


def _dec(v):
    return Decimal(v.numerator) / Decimal(v.denominator) if isinstance(v, Fr) else Decimal(v)


def fmt_float(v, mode=ROUND_HALF_UP):
    d = _dec(Fr(v))
    q = abs(d).quantize(Decimal("0.0001"), rounding=mode)
    s = "%s" % q
    if "." not in s:
        s += ".0000"
    return ("-" + s) if (d < 0 and q != 0) else s


def fmt_trunc(v):
    return fmt_float(v, ROUND_DOWN)


def near_boundary(v):
    d = abs(_dec(Fr(v))) * 10000
    frac = d - int(d)
    return abs(frac - Decimal("0.5")) < Decimal("1e-6") or frac < Decimal("1e-6") or frac > 1 - Decimal("1e-6")


class Expect:
    """check(res) -> (ok, detail, cls).  cls is a defect-class hint (e.g. 'D10') or None."""
    def check(self, r):
        raise NotImplementedError

    def describe(self):
        return self.__class__.__name__


def _clean(r):
    return r.ce == 0 and r.ve == 0 and r.status == "OK"


def _state(r):
    return "ce=%s ve=%s msg=%s st=%s" % (r.ce, r.ve, r.msg, r.status)


class Out(Expect):
    """Clean run; program output (rows 0..23 joined) equals `text` exactly."""
    def __init__(self, text):
        self.text = text

    def check(self, r):
        ok = _clean(r) and r.text == self.text
        return ok, "%s out=%r%s" % (_state(r), r.text, "" if ok else " want=%r" % self.text), None

    def describe(self):
        return "out=%r" % self.text


class Lines(Expect):
    """Clean run; each output line checked by an item: str (exact) or NumV (numeric rule)."""
    def __init__(self, *items):
        self.items = list(items)

    def check(self, r):
        rows = r.text.split("\n") if r.text else []
        if not _clean(r):
            return False, "%s out=%r" % (_state(r), r.text), None
        if len(rows) != len(self.items):
            return False, "out=%r: %d lines, want %d" % (r.text, len(rows), len(self.items)), None
        cls = None
        for got, want in zip(rows, self.items):
            if isinstance(want, NumV):
                ok, c = want.match(got)
                if not ok:
                    return False, "out=%r want %s" % (r.text, [w.describe() if isinstance(w, NumV) else w for w in self.items]), c
            elif got != want:
                return False, "out=%r want %r" % (r.text, self.items), None
        return True, "out=%r" % r.text, cls

    def describe(self):
        return "lines=%s" % [w.describe() if isinstance(w, NumV) else w for w in self.items]


class NumV:
    """A printed number.  kind: 'int' (plain integer text), 'float' (4-decimal rounded),
    'num' (either form accepted when the value is integral)."""
    def __init__(self, value, kind="num"):
        self.v = Fr(value)
        self.kind = kind

    def forms(self):
        f = []
        if self.kind in ("int", "num") and self.v.denominator == 1:
            f.append(str(self.v.numerator))
        if self.kind in ("float", "num"):
            f.append(fmt_float(self.v))
            if near_boundary(self.v):
                f.append(fmt_trunc(self.v))
        return f

    def match(self, got):
        if got in self.forms():
            return True, None
        if self.kind != "int" and got in (fmt_trunc(self.v), fmt_trunc(self.v - Fr(1, 10 ** 7)),
                                          fmt_trunc(self.v + Fr(1, 10 ** 7))):
            return False, "D10"
        return False, None

    def describe(self):
        return "/".join(self.forms())


def Num(value, kind="num"):
    return Lines(NumV(value, kind))


class CErr(Expect):
    """Compile error (code `code`, or any nonzero), nothing executed."""
    def __init__(self, code=None, line=None):
        self.code = code
        self.line = line

    def check(self, r):
        ok = r.ce != 0 and (self.code is None or r.ce == self.code) and r.status == "OK"
        if ok and self.line is not None:
            ok = r.edit_index == self.line
        return ok, "%s line=%s idx=%s" % (_state(r), r.line, r.edit_index), None

    def describe(self):
        return "compile error %s%s" % (self.code if self.code is not None else "(any)",
                                      "" if self.line is None else " at line %d" % self.line)


class RErr(Expect):
    """Compile succeeds, runtime error (code or any), optional output before the error."""
    def __init__(self, code=None, out=None):
        self.code = code
        self.out = out

    def check(self, r):
        ok = r.ce == 0 and r.ve != 0 and (self.code is None or r.ve == self.code) and r.status == "OK"
        if ok and self.out is not None:
            ok = r.text == self.out
        return ok, "%s out=%r" % (_state(r), r.text), None

    def describe(self):
        return "runtime error %s" % (self.code if self.code is not None else "(any)")


class AnyErr(Expect):
    """Either a compile or a runtime error -- the program must not silently succeed."""
    def check(self, r):
        ok = (r.ce != 0 or r.ve != 0) and r.status == "OK"
        return ok, "%s out=%r" % (_state(r), r.text), None

    def describe(self):
        return "an error (compile or runtime)"


class OkOrErr(Expect):
    """Clean run with `text`, OR any error: used where either is a defensible design."""
    def __init__(self, text):
        self.text = text

    def check(self, r):
        if r.ce != 0 or r.ve != 0:
            return r.status == "OK", "%s (error accepted)" % _state(r), None
        ok = r.text == self.text and r.status == "OK"
        return ok, "%s out=%r" % (_state(r), r.text), None

    def describe(self):
        return "out=%r or an error" % self.text


class Pred(Expect):
    def __init__(self, fn, desc):
        self.fn = fn
        self.desc = desc

    def check(self, r):
        ok, detail = self.fn(r)
        return ok, detail, None

    def describe(self):
        return self.desc


class Terminates(Expect):
    """Program must finish (no hang) cleanly; output not checked."""
    def check(self, r):
        return _clean(r), _state(r) + " out=%r" % r.text[:60], None

    def describe(self):
        return "runs to completion"
