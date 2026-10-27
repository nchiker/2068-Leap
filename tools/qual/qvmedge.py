#!/usr/bin/env python3
"""Edge cases of the VM's fast paths, items 5.3-5.5 of docs/V2_LEAPC_BACKPORT_PLAN.md: whole-number
FOR/NEXT at the ends of the number range, a loop variable changed in the body, NEXT with no loop, loops
left by GOTO and EXIT FOR; the combined instructions (a comparison with its IF's branch; v = v + k,
v = v - k, v = v + w) beside the forms that must not combine; and the operand stack's limit. The expectations follow the language's
rules (docs/manual): whole numbers -32768 to 32767 are exact and an overflow continues in floating
point; a number that is not a whole number in that range prints with four decimals; a comparison is 1
or 0; NEXT with no loop is run-time error 7. They are not copied from what the ROM printed.

  python3 tools/qual/qvmedge.py --tree . [substr ...]  (the build of a source tree, as `make qual` runs it)
  python3 tools/qual/qvmedge.py cfg [substr ...]       (a configuration under --root)
"""
import argparse
import itertools
import operator
import os
import sys
from fractions import Fraction as Fr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine  # noqa: E402


def num(v):
    """How PRINT shows v: a whole number in -32768..32767 plainly, anything else with four decimals."""
    v = Fr(v)
    if v.denominator == 1 and -32768 <= v <= 32767:
        return str(v.numerator)
    q = abs(v) * 10000
    q = q.numerator * 2 // q.denominator
    q = (q + 1) // 2                                # half away from zero
    return "%s%d.%04d" % ("-" if v < 0 and q else "", q // 10000, q % 10000)


def nums(*vs):
    return [num(v) for v in vs]


CASES = []      # (name, lines, rows, ce, ve)


def case(name, lines, rows, ce=0, ve=0):
    CASES.append((name, list(lines), list(rows), ce, ve))


def for_run(start, limit, step):
    """The values a whole-number FOR passes through, and the variable after the loop."""
    out, v = [], start
    while (v <= limit) if step > 0 else (v >= limit):
        out.append(v)
        v += step
    return out, v


# ---------------------------------------------------------------- 5.3: FOR/NEXT
for name, s, l, st in (("ovf-up", 32760, 32767, 1), ("ovf-down", -32760, -32768, -1), ("step3", 1, 10, 3),
                       ("down3", 10, 1, -3), ("step2-edge", 32765, 32767, 2), ("wide-up", -32768, 32767, 32767),
                       ("wide-down", 32767, -32768, -32768), ("limit-neg", -5, -2, 1), ("start-past", 5, 1, 1)):
    vals, after = for_run(s, l, st)
    case("for-" + name, ["FOR i = %d TO %d%s" % (s, l, "" if st == 1 else " STEP %d" % st), "PRINT i", "NEXT i",
                         "PRINT i"], nums(*vals, after))
case("for-body-mod", ["FOR i = 1 TO 9", "i = i + 1", "PRINT i", "NEXT i", "PRINT i"], nums(2, 4, 6, 8, 10, 11))
case("for-body-float", ["FOR i = 1 TO 3", "i = 2.5", "PRINT i", "NEXT i", "PRINT i"], nums(Fr(5, 2), Fr(7, 2)))
case("for-body-add2", ["FOR i = 1 TO 10", "i = i + 2", "PRINT i", "NEXT i"], nums(3, 6, 9, 12))
case("for-float-limit", ["n = 2.5", "FOR i = 1 TO n", "PRINT i", "NEXT i", "PRINT i"], nums(1, 2, 3))
case("for-float-start", ["FOR i = 0.5 TO 3", "PRINT i", "NEXT i", "PRINT i"],
     nums(Fr(1, 2), Fr(3, 2), Fr(5, 2), Fr(7, 2)))
case("for-goto-out", ["FOR i = 1 TO 4", "FOR j = 1 TO 2", "GOTO nx", "NEXT j", "nx:", "PRINT i; j", "NEXT i",
                      "PRINT i"], ["11", "21", "31", "41", "5"])
case("for-nested", ["FOR i = 1 TO 3", "FOR j = i TO 3", "PRINT i; j", "NEXT j", "NEXT i", "PRINT i; j"],
     ["11", "12", "13", "22", "23", "33", "44"])
case("for-reenter", ["k = 0", "top:", "FOR i = 1 TO 2", "k = k + 1", "IF k = 1 THEN GOTO top", "NEXT i",
                     "PRINT i; k"], ["33"])
case("for-exit", ["FOR i = 1 TO 9", "IF i = 4 THEN", "EXIT FOR", "ENDIF", "NEXT i", "PRINT i"], ["4"])
case("for-step0", ["k = 0", "FOR i = 1 TO 2 STEP 0", "k = k + 1", "IF k = 50 THEN", "EXIT FOR", "ENDIF", "NEXT i",
                   "PRINT i; k"], ["150"])
# NEXT reached with no loop open (a GOTO into the loop), whatever the variable holds; the fast path
# must not take a variable's 0 or another frame for its loop
for name, pre in (("int0", ["x = 0"]), ("float", ["x = 0.5"]), ("other-float", ["y = 0.5", "x = 0"])):
    case("for-nofor-" + name, pre + ["GOTO inside", "FOR x = 1 TO 3", "inside:", "NEXT x", 'PRINT "n"'], [], ve=7)
case("for-nofor-proc", ["FOR i = 1 TO 3", "CALL p(0)", "NEXT i", "END", "PROC p(n):", "NEXT i", "ENDP"], [], ce=56)

# ---------------------------------------------------------------- 5.4: compare and branch
OPS = {"<": operator.lt, "<=": operator.le, "=": operator.eq, ">=": operator.ge, ">": operator.gt,
       "<>": operator.ne}
PAIRS = {"int": ("3", "5"), "flt": ("2.5", "5.5"), "mix": ("3", "3.0"), "neg": ("-7", "2"), "eq": ("4", "4"),
         "big": ("32767", "-32768")}
for (pk, (a, b)), op in itertools.product(PAIRS.items(), OPS):
    f, av, bv = OPS[op], Fr(a), Fr(b)
    case("if-%s-%s" % (pk, op),
         ["a = " + a, "b = " + b, "IF a %s b THEN" % op, 'PRINT "t"', "ELSE", 'PRINT "f"', "ENDIF",
          "IF b %s a THEN" % op, 'PRINT "t2"', "ENDIF", "IF a %s 4 THEN" % op, 'PRINT "t3"', "ENDIF"],
         ["t" if f(av, bv) else "f"] + ["t2"] * f(bv, av) + ["t3"] * f(av, 4))
    case("goto-%s-%s" % (pk, op),
         ["a = " + a, "b = " + b, "IF a %s b THEN GOTO yes" % op, 'PRINT "no"', "GOTO done", "yes:", 'PRINT "yes"',
          "done:", "IF b %s a THEN GOTO y2" % op, 'PRINT "n2"', "y2:", 'PRINT "e"'],
         ["yes" if f(av, bv) else "no"] + ["n2"] * (not f(bv, av)) + ["e"])
case("cmp-and-or", ["a = 1", "b = 2", "IF a < b AND b < 3 THEN", 'PRINT "and"', "ENDIF", "IF a > b OR b = 2 THEN",
                    'PRINT "or"', "ENDIF", "IF NOT a = b THEN", 'PRINT "not"', "ENDIF"], ["and", "or", "not"])
case("cmp-paren", ["a = 1", "b = 2", "IF (a < b) THEN", 'PRINT "p"', "ENDIF", "IF (a > b) THEN GOTO z", 'PRINT "q"',
                   "z:"], ["p", "q"])
case("cmp-value", ["a = 1", "b = 2", "c = a < b", "PRINT c", "PRINT a = b", "IF c THEN", 'PRINT "c"', "ENDIF"],
     ["1", "0", "c"])
case("cmp-str", ['a$ = "x"', 'b$ = "y"', "IF a$ < b$ THEN", 'PRINT "s"', "ENDIF", "IF a$ = b$ THEN GOTO z",
                 'PRINT "u"', "z:"], ["s", "u"])
case("cmp-fn", ["DEF FN f(x) = x + 1", "IF FN f(2) = 3 THEN", 'PRINT "fn"', "ENDIF"], ["fn"])
case("cmp-nested-if", ["a = 2", "IF a > 1 THEN", "IF a < 3 THEN", 'PRINT "in"', "ELSE", 'PRINT "no"', "ENDIF",
                       "ENDIF"], ["in"])
case("cmp-goto-fwd-back", ["n = 0", "top:", "n = n + 1", "IF n = 3 THEN GOTO done", "GOTO top", "done:", "PRINT n"],
     ["3"])
case("cmp-loop-goto", ["i = 0", "top:", "i = i + 1", "IF i < 300 THEN GOTO top", "PRINT i"], ["300"])
case("cmp-loop-block", ["i = 0", "s = 0", "top:", "IF i < 100 THEN", "i = i + 1", "s = s + i", "GOTO top", "ENDIF",
                        "PRINT i; s"], ["1005050"])

# ---------------------------------------------------------------- 5.4: v = v + k, v = v - k, v = v + w
case("add-int", ["x = 5", "x = x + 1", "PRINT x", "x = x - 3", "PRINT x", "x = x + 127", "PRINT x", "x = x - 127",
                 "PRINT x", "x = x + 0", "x = x - 0", "PRINT x"], nums(6, 3, 130, 3, 3))
# a negative constant compiles as 0 minus its magnitude, so none of these combine (the compiler's
# guard against v - (-128) cannot be reached from source); 128 does not fit the 8-bit operand
case("add-k-edge", ["x = 5", "x = x - (-128)", "PRINT x", "x = x + (-128)", "PRINT x", "x = x - 128", "PRINT x",
                    "x = x + 128", "PRINT x", "x = x - -127", "PRINT x"], nums(133, 5, -123, 5, 132))
case("add-ovf", ["x = 32766", "x = x + 1", "PRINT x", "x = x + 1", "PRINT x", "x = x + 1", "PRINT x"],
     nums(32767, 32768, 32769))
case("sub-ovf", ["x = -32767", "x = x - 1", "PRINT x", "x = x - 1", "PRINT x", "x = x - 1", "PRINT x"],
     nums(-32768, -32769, -32770))
case("add-float", ["x = 0.5", "x = x + 1", "PRINT x", "x = x - 2", "PRINT x", "x = x + 3", "PRINT x"],
     nums(Fr(3, 2), Fr(-1, 2), Fr(5, 2)))
# x - 1 is one subtraction however it is written: the combined form (x + -1) and the calculator's own
# subtraction (y - 1 * 1, not combined) give the same number after every rounding
case("sub-float-same", ["x = 0.1", "y = 0.1", "FOR i = 1 TO 30", "x = x + 1", "x = x - 1", "y = y + 1 * 1",
                        "y = y - 1 * 1", "IF x <> y THEN", 'PRINT "d"; i', "ENDIF", "NEXT i", 'PRINT "s"'], ["s"])
case("addvv", ["x = 7", "y = 5", "x = x + y", "PRINT x", "y = -20", "x = x + y", "PRINT x", "x = x + x", "PRINT x"],
     nums(12, -8, -16))
case("addvv-ovf", ["x = 30000", "y = 5000", "x = x + y", "PRINT x", "x = x + y", "PRINT x"], nums(35000, 40000))
case("addvv-float", ["x = 7", "y = 0.25", "x = x + y", "PRINT x", "y = 3", "x = x + y", "PRINT x"],
     nums(Fr(29, 4), Fr(41, 4)))
case("subvv", ["x = 7", "y = 5", "x = x - y", "PRINT x"], nums(2))
case("nofuse-k16", ["x = 5", "x = x + 1000", "PRINT x", "x = x - 1000", "PRINT x"], nums(1005, 5))
# only (x + 1) combines: the brackets emit nothing
case("add-near", ["x = 5", "y = 2", "x = y + 1", "PRINT x", "x = 1 + x", "PRINT x", "x = x * 2", "PRINT x",
                  "x = (x + 1)", "PRINT x", "x = x + 1 + 1", "PRINT x"], nums(3, 4, 8, 9, 11))
case("add-in-proc", ["s = 0", "CALL p(5)", "PRINT s", "END", "PROC p(n):", "s = s + n", "n = n + 1", "s = s + n",
                     "ENDP"], nums(11))


def _sieve(size):
    g, c = [1] * (size + 1), 0
    for i in range(size + 1):
        if g[i]:
            r = i + i + 3
            for k in range(i + r, size + 1, r):
                g[k] = 0
            c += 1
    return c


case("sieve", ["s = 100", "DIM g(101)", "c = 0", "FOR i = 0 TO s", "g(i) = 1", "NEXT i", "FOR i = 0 TO s",
               "IF g(i) = 0 THEN GOTO skip", "r = i + i + 3", "k = i + r", "IF k > s THEN GOTO noclear",
               "clearloop:", "g(k) = 0", "k = k + r", "IF k <= s THEN GOTO clearloop", "noclear:", "c = c + 1",
               "skip:", "NEXT i", "PRINT c"], nums(_sieve(100)))

# ---------------------------------------------------------------- 5.12: IF v <op> k as one instruction
# Each relational operator in an IF block (with ELSE) and in IF ... THEN GOTO, for a variable against a
# constant, one row per form: 1 when the comparison holds. The constants 0-127 are 8-bit literals, 128,
# 1000, 32767 and -1 (the minus folded in) 16-bit ones: all combine; 4.5 (a 5-byte literal) does not. The
# FLOAT variables (2.5, -0.5, 40000, 2.5 + 2.5: a FLOAT whose value is whole) take the fallback.
IFK_VALUES = (("-32767 - 1", -32768), ("-129", -129), ("-1", -1), ("0", 0), ("5", 5), ("127", 127), ("128", 128),
              ("32767", 32767), ("2.5", Fr(5, 2)), ("-0.5", Fr(-1, 2)), ("40000", 40000), ("2.5 + 2.5", 5))
IFK_CONSTS = ("0", "5", "127", "128", "1000", "32767", "-1", "4.5")
for (vi, (vsrc, vv)), (ki, k) in itertools.product(enumerate(IFK_VALUES), enumerate(IFK_CONSTS)):
    lines, blk, gto = ["x = " + vsrc], "", ""
    for j, op in enumerate(OPS):
        lines += ["IF x %s %s THEN" % (op, k), 'PRINT "1";', "ELSE", 'PRINT "0";', "ENDIF"]
        blk += "1" if OPS[op](Fr(vv), Fr(k)) else "0"
    lines.append("PRINT")
    for j, op in enumerate(OPS):
        lines += ["IF x %s %s THEN GOTO y%d" % (op, k, j), 'PRINT "0";', "GOTO n%d" % j, "y%d:" % j, 'PRINT "1";',
                  "n%d:" % j]
    lines.append("PRINT")
    case("ifk-%d-%d" % (vi, ki), lines, [blk, blk])
# the variable made FLOAT, then INT again, inside the loop the IF closes
case("ifk-loop-retag", ["x = 0", "n = 0", "top:", "n = n + 1", "x = x + 0.5", "IF n = 4 THEN", "x = 2", "ENDIF",
                        "IF x < 3 THEN GOTO top", "PRINT n"], ["6"])
case("ifk-loop-down", ["i = 300", "top:", "i = i - 1", "IF i > 5 THEN GOTO top", "PRINT i"], ["5"])
case("ifk-loop-k16", ["i = 0", "top:", "i = i + 7", "IF i <= 2000 THEN GOTO top", "PRINT i"], ["2002"])
# not the whole condition: a sum on either side, the constant first, two variables, AND, an array
case("ifk-near", ["a = 1", "b = 2", "c = 3", "d = 4", "DIM g(3)", "g(1) = 9",
                  "IF c + d < 8 THEN", 'PRINT "a";', "ENDIF", "IF d < 5 + c THEN", 'PRINT "b";', "ENDIF",
                  "IF 5 > d THEN", 'PRINT "c";', "ENDIF", "IF a < d THEN", 'PRINT "d";', "ENDIF",
                  "IF a < 2 AND d > 3 THEN", 'PRINT "e";', "ENDIF", "IF g(1) > 8 THEN", 'PRINT "f";', "ENDIF",
                  "IF (d) = 4 THEN", 'PRINT "g";', "ENDIF", "PRINT"],
     ["abcdefg"])
case("ifk-proc", ["s = 0", "CALL p(1)", "PRINT s", "END", "PROC p(n):", "s = s + n", "IF n < 12 THEN", "CALL p(n + 1)",
                  "ENDIF", "ENDP"], ["78"])

# ---------------------------------------------------------------- 5.5: the operand stack's bounds
# 1+(1+(...)) with n levels holds n + 1 operands at once; the stack has room for 41 ($B604-$B67F, 3 bytes
# each; the manual's limit "about 40"), so 40 levels run and 41 stop with STACK OVERFLOW (run-time 2)
for n, rows, ve in ((40, nums(41), 0), (41, [], 2)):
    case("stack-depth-%d" % n, ["x = " + "1+(" * n + "1" + ")" * n, "PRINT x"], rows, ve=ve)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cfg", nargs="?", default=None)
    ap.add_argument("only", nargs="*")
    ap.add_argument("--tree", default=None, help="the build in this source tree (e.g. .)")
    ap.add_argument("--port", type=int, default=10505)
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                                   "build", "qual-builds"))
    a = ap.parse_args()
    cfgdir = os.path.abspath(a.tree) if a.tree else os.path.join(a.root, a.cfg)
    only = a.only + ([a.cfg] if a.tree and a.cfg else [])      # with --tree every word is a filter
    m = Machine(cfgdir, a.port, label=os.path.basename(cfgdir)).start()
    n = fails = 0
    try:
        for name, lines, rows, ce, ve in CASES:
            if only and not any(s in name for s in only):
                continue
            n += 1
            r = m.run_program(lines, maxi=80_000_000)
            got = list(r.rows[:22])             # the program's rows (23 is the editor's status line)
            while got and not got[-1].strip():
                got.pop()
            ok = r.status == "OK" and r.ce == ce and r.ve == ve and got == rows
            fails += not ok
            if not ok:
                print("FAIL  %-20s ce=%d ve=%d %s screen=%r  want ce=%d ve=%d %r  (program: %s)"
                      % (name, r.ce, r.ve, r.status, got, ce, ve, rows, " | ".join(lines)), flush=True)
    finally:
        m.stop()
    print("qvmedge %s: %d cases, %d PASS, %d FAIL" % (os.path.basename(cfgdir), n, n - fails, fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
