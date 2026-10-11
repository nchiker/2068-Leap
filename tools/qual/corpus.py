"""V2 language conformance corpus (qualification study).

Each case: id, feature (inventory key), program lines, expectation (qexpect), optional per-config
expectations / known-defect markers / applicability.  Expectations come from the user manual,
the V2 design documents and owner decisions, or exact mathematics (Python Fractions) -- see
qexpect.py.  `known` marks a defect that was ALREADY documented before this study (strict
XFAIL accounting); defects first found by this study are given Q-* ids in KNOWN_Q below after
investigation, and are reported separately.
"""
from fractions import Fraction as Fr
from qexpect import (Out, Lines, NumV, Num, CErr, RErr, AnyErr, OkOrErr, Pred, Terminates)

CFGS = ("baseline", "essential", "enhanced")
CASES = []


class Case:
    def __init__(self, cid, feature, lines, expect, keys=(), known=None, only=None, note="",
                 maxi=60_000_000, packages=(), decision=None, prepare=None, post=None):
        self.cid, self.feature, self.lines, self.keys = cid, feature, list(lines), list(keys)
        self.expect = expect if isinstance(expect, dict) else {c: expect for c in CFGS}
        if known is None:
            known = {}
        elif isinstance(known, str):
            known = {c: known for c in CFGS}
        self.known = known
        self.only = tuple(only) if only else CFGS
        self.note, self.maxi, self.packages, self.decision, self.prepare = note, maxi, tuple(packages), decision, prepare
        self.post = post      # post(machine, result) -> (ok, detail): extra state check after the run


def T(*a, **k):
    CASES.append(Case(*a, **k))


def per(b=None, e=None, x=None):
    """Per-config expectation; x (enhanced) defaults to e (essential), e defaults to b."""
    e = b if e is None else e
    x = e if x is None else x
    return {"baseline": b, "essential": e, "enhanced": x}


OLD = ("baseline",)
NEW = ("essential", "enhanced")
ENH = ("enhanced",)
D11B = {"baseline": "D11"}                 # baseline wraps silently on integer overflow
LA = {"baseline": "D11", "essential": "L-A", "enhanced": "L-A"}   # literal rule L-A (decision pending)
D11X = {"baseline": "D11", "essential": "D11-EXT", "enhanced": "D11-EXT"}  # extremes not covered (cost study B.4)
I, F = (lambda v: NumV(v, "int")), (lambda v: NumV(v, "float"))

# =====================================================================================
# 1. Literals and lexical structure
# =====================================================================================
for v in (0, 1, 7, 127, 128, 255, 256, 1000, 32766, 32767):
    T("lit.int.%d" % v, "literal.integer", ["PRINT %d" % v], Num(v, "int"))
T("lit.int.neg1", "literal.integer", ["PRINT -1"], Num(-1, "int"))
T("lit.int.neg32767", "literal.integer", ["PRINT -32767"], Num(-32767, "int"))
T("lit.int.neg32768", "literal.integer", ["PRINT -32768"], Lines(NumV(-32768)),
  note="-32768 = 0 - 32768: the literal 32768 is outside the signed range")
for v in (32768, 40000, 65535):
    T("lit.int.%d" % v, "literal.integer.large", ["PRINT %d" % v], Num(v),
      known={"baseline": "D11", "essential": "L-A", "enhanced": "L-A"},
      decision="literal rule L-A/L-C (cost study G.1)",
      note="mathematically %d; L-A keeps it as a 16-bit address pattern (prints negative)" % v)
for v in (65536, 99999, 100000):
    T("lit.int.%d" % v, "literal.integer.large", ["PRINT %d" % v], Num(v), known=LA,
      note="L-A: compile error 64 (documented policy); baseline wraps")
T("lit.addr.poke", "literal.integer.address", ["POKE 65000,77", "PRINT PEEK(65000)"], Num(77, "int"),
  note="address literal > 32767 (test corpus relies on it)")
T("lit.dec.0p5", "literal.decimal", ["PRINT 0.5"], Num(Fr(1, 2), "float"))
T("lit.dec.1p25", "literal.decimal", ["PRINT 1.25"], Num(Fr(5, 4), "float"))
T("lit.dec.10p5", "literal.decimal", ["PRINT 10.5"], Num(Fr(21, 2), "float"))
T("lit.dec.3p1416", "literal.decimal", ["PRINT 3.1416"], Num(Fr(31416, 10000), "float"))
T("lit.dec.0p0001", "literal.decimal", ["PRINT 0.0001*10000"], Num(1, "float"))
T("lit.dec.0p00001", "literal.decimal.precision", ["PRINT 0.00001*10000*10"], Num(1, "float"),
  note="5 fractional digits: the decimal divisor 10^5 exceeds 16 bits")
T("lit.dec.0p000001", "literal.decimal.precision", ["PRINT 0.000001*10000*10*10"], Num(1, "float"))
T("lit.dec.16zeros", "literal.decimal.precision", ["PRINT 0.0000000000000001+1"], Num(1, "float"),
  note="divisor 10^16 mod 65536 == 0")
T("lit.dec.trailing0", "literal.decimal", ["PRINT 1.5000"], Num(Fr(3, 2), "float"))
T("lit.dec.3p14159", "literal.decimal.precision", ["PRINT 3.14159"], Num(Fr(314159, 100000), "float"),
  known=LA, note="6 significant digits (mantissa 314159 > 32767)")
T("lit.dec.12345p678", "literal.decimal.precision", ["PRINT 12345.678"], Num(Fr(12345678, 1000), "float"), known=LA)
T("lit.dec.9999p5", "literal.decimal.precision", ["PRINT 9999.5"], Num(Fr(19999, 2), "float"), known=LA)
T("lit.dec.3276p7", "literal.decimal", ["PRINT 3276.7"], Num(Fr(32767, 10), "float"), known="D10")
T("lit.dec.2p0", "literal.decimal", ["PRINT 2.0"], Num(2, "num"))
T("lit.dec.trailing_dot", "literal.decimal", ["PRINT 5."], Num(5, "num"))
T("lit.dec.leading_dot", "literal.decimal", ["PRINT .5"], OkOrErr("0.5000"))
T("lit.hex", "literal.hex", ["PRINT $FF"], CErr(), note="hex literals intentionally unsupported")
T("lit.exp", "literal.exponent", ["PRINT 1E3"], CErr(), note="exponent literals unsupported (1E3 = ident E3?)")
T("lit.str.empty", "literal.string", ['PRINT ""', 'PRINT "x"'], Out("\nx"))
T("lit.str.basic", "literal.string", ['PRINT "Hello, World!"'], Out("Hello, World!"))
T("lit.str.31", "literal.string", ['PRINT "' + "A" * 31 + '"'], Out("A" * 31))
T("lit.str.32", "literal.string.limit", ['PRINT "' + "B" * 32 + '"'], OkOrErr("B" * 32), known="L3",
  note="string values are capped at 31 characters (decided); a longer literal should not be silently cut")
T("lit.str.keywords", "literal.string", ['PRINT "PRINT : GOTO x REM"'], Out("PRINT : GOTO x REM"))
T("lit.str.unterminated", "literal.string", ['PRINT "abc'], CErr(64))
T("lit.str.quote_in", "literal.string", ['PRINT "a""b"'], CErr(), note="no doubled-quote escape")
T("lex.case.keywords", "lexer.case", ["print 5", "Print 6", "pRiNt 7"], Out("5\n6\n7"))
T("lex.case.vars", "lexer.case", ["abc = 3", "PRINT ABC + Abc"], Num(6, "int"))
T("lex.ident.digits", "identifier", ["a1 = 4", "b22c = 5", "PRINT a1 * b22c"], Num(20, "int"))
T("lex.ident.31", "identifier.length", ["%s = 9" % ("v" * 31), "PRINT %s" % ("v" * 31)], Num(9, "int"))
T("lex.ident.32", "identifier.length", ["%s = 9" % ("v" * 32)], CErr(61))
T("lex.ident.underscore", "identifier", ["my_var = 1"], CErr())
T("lex.ident.kwprefix", "identifier", ["tomato = 2", "to1 = 3", "format = 4", "PRINT tomato + to1 + format"], Num(9, "int"))
T("lex.ident.keyword", "identifier.reserved", ["print = 3"], CErr())
T("lex.ident.builtin_as_var", "identifier.reserved", ["abs = 3", "PRINT abs"], CErr(),
  note="a built-in function name used as a plain variable")
T("lex.rem", "statement.REM", ["REM hello : PRINT 1", 'PRINT "after"'], Out("after"))
T("lex.rem.trailing", "statement.REM", ["x = 1 : REM comment", "PRINT x"], Num(1, "int"))
T("lex.rem.colon_end", "statement.REM", ["REM ends with colon:", 'PRINT "next"'], Out("next"))
T("lex.colon.sep", "statement.separator", ["x = 1 : y = 2 : PRINT x + y"], Num(3, "int"))
T("lex.colon.cont", "statement.separator", ["x = 1 :", "PRINT x"], Num(1, "int"))
T("lex.apostrophe", "lexer.comment", ["x = 1 ' comment"], CErr(64))
T("lex.linenum", "lexer", ["10 PRINT 1"], CErr())
T("lex.bareword", "statement.bareword", ["PRNT"], CErr(), known={"baseline": "N-2"})
T("lex.bareword2", "statement.bareword", ['PRINT "a"', "CONT", 'PRINT "b"'], CErr(), known={"baseline": "N-2"})
T("lex.bareword3", "statement.bareword", ["x"], CErr(), known={"baseline": "N-2"})
T("lex.junk", "compile.strict", ["x = 1 2"], CErr(64))
T("lex.unknown_char", "lexer", ["x = 1 ? 2"], CErr())

# =====================================================================================
# 2. Integer arithmetic (exact oracle)
# =====================================================================================
def arith(cid, expr, value, kind="int", known=None, note=""):
    T("arith." + cid, "expr.arith", ["PRINT " + expr], Num(value, kind), known=known, note=note)


arith("add", "2+3", 5)
arith("sub", "2-7", -5)
arith("mul", "6*7", 42)
arith("div.exact", "84/4", 21)
arith("div.inexact", "7/2", Fr(7, 2), "float")
arith("div.neg", "-7/2", Fr(-7, 2), "float")
arith("div.third", "1/3", Fr(1, 3), "float")
arith("div.twothirds", "2/3", Fr(2, 3), "float")
arith("prec.1", "2+3*4", 14)
arith("prec.2", "(2+3)*4", 20)
arith("prec.3", "20-6-4", 10)
arith("prec.4", "100/10/5", 2)
arith("prec.5", "2*3+4*5-6/3", 24)
arith("prec.unary", "-2*3", -6)
arith("prec.unary2", "2*-3", -6)
arith("prec.unary3", "2--3", 5)
arith("prec.unary4", "-(2+3)", -5)
arith("prec.unary5", "--5", 5)
arith("paren.deep", "((((((((((1+2))))))))))*3", 9)
arith("max", "32767", 32767)
arith("min", "-32767-1", -32768)
arith("ovf.add", "32767+1", 32768, "float", known=D11B)
arith("ovf.sub", "-32767-2", -32769, "float", known=D11B)
arith("ovf.mul", "30000*3", 90000, "float", known=D11B)
arith("ovf.mul2", "181*182", 32942, "float", known=D11B)
arith("ovf.mul3", "-256*128", -32768, "num")
arith("ovf.mul4", "-256*129", -33024, "float", known=D11B)
arith("ovf.big", "32767*32767", 32767 * 32767, "float", known=D11B)
arith("ovf.big2", "32767*32767*32767", 32767 ** 3, "float", known={"baseline": "D11", "essential": "D11-DISP", "enhanced": "D11-DISP"},
      note="35 trillion: beyond 2^32, where the big-float display saturates")
arith("ovf.chain", "32767+1-1", 32767, "num", note="exact even when wrapping")
arith("neg.min_div", "(-32767-1)/-1", 32768, "num", known=D11X, note="-32768 / -1")
arith("neg.min_neg", "-(-32767-1)", 32768, "num", known=D11B)
arith("neg.min_mul", "(-32767-1)*-1", 32768, "num", known=D11B)
T("arith.div0", "expr.div0", ["PRINT 1/0"], RErr(5))
T("arith.div0.var", "expr.div0", ["z = 0", "PRINT 5/z"], RErr(5))
T("arith.div0.float", "expr.div0", ["PRINT 1.5/0"], RErr(5))
T("arith.div0.float2", "expr.div0", ["z = 0.0", "PRINT 2/z"], RErr(5))
T("arith.assign_chain", "expr.assign", ["a = 5", "b = a * 2", "a = b - a", "PRINT a", "PRINT b"], Lines(I(5), I(10)))
T("arith.selfref", "expr.assign", ["x = 1", "x = x + x + x", "PRINT x"], Num(3, "int"))
T("arith.uninit", "variable.default", ["PRINT q + 1"], Num(1, "int"), note="unassigned numeric scalar reads 0")

# random integer grid against Python (all within range)
import random as _r
_rr = _r.Random(2068)
for k in range(24):
    a, b, c = _rr.randint(-200, 200), _rr.randint(-100, 100), _rr.randint(1, 50)
    expr = "%d*%d+%d-(%d)" % (a, b, c, b)
    arith("grid.%02d" % k, expr.replace("+-", "-").replace("--", "+"), a * b + c - b)

# =====================================================================================
# 3. Float arithmetic, mixed types, float temporaries
# =====================================================================================
arith("f.add", "0.5+0.25", Fr(3, 4), "float")
arith("f.mixed", "1+0.5", Fr(3, 2), "float")
arith("f.mixed2", "0.5*4", 2, "num")
arith("f.sub", "1.5-2.75", Fr(-5, 4), "float")
arith("f.neg", "-0.5", Fr(-1, 2), "float")
arith("f.neg_small", "-0.0625", Fr(-1, 16), "float")
arith("f.d10.sum", "0.1+0.2", Fr(3, 10), "float", known="D10")
arith("f.d10.third", "1/3*3", 1, "num")
arith("f.prec", "1.5+2.5*3.5", Fr(41, 4), "float")
arith("f.temps2", "1.5*2.5+3.5*4.5", Fr(39, 2), "float", note="two float products live at once")
arith("f.temps3", "1.5*2.5+3.5*4.5+5.5*6.5", Fr(221, 4), "float")
arith("f.temps4", "(1.5+2.5)*(3.5+4.5)", 32, "num")
arith("f.temps5", "1/2+1/4", Fr(3, 4), "float")
arith("f.temps6", "1/2+1/4+1/8", Fr(7, 8), "float")
arith("f.temps7", "(1/2)*(1/4)+(1/8)*(1/16)", Fr(1, 8) + Fr(1, 128), "float")
arith("f.temps8", "2.5*(1.5+0.5*3.5)", Fr(65, 8), "float")
arith("f.cmp_lt", "(0.5<0.75)", 1, "int")
arith("f.cmp_eq", "(0.5=0.5)", 1, "int")
arith("f.cmp_mix", "(1<1.5)", 1, "int")
arith("f.cmp_ge", "(2.5>=2.5)", 1, "int")
arith("f.big", "40000.5", Fr(80001, 2), "float", known=LA)
arith("f.big_frac", "30000*3+0.5", Fr(180001, 2), "float", known={"baseline": "D11", "essential": "D11-DISP", "enhanced": "D11-DISP"},
      note="fraction of a float >= 32768 (cost study: 'fraction not shown')")
arith("f.big_neg", "-30000*3", -90000, "float", known=D11B)
T("f.var", "variable.float", ["x = 2.5", "y = x * 2", "PRINT y", "PRINT x"], Lines(NumV(5), F(Fr(5, 2))))
T("f.var_reassign_int", "variable.float", ["x = 2.5", "x = 3", "PRINT x + 1"], Num(4, "int"))
T("f.var_many", "variable.float", ["a = 0.5", "b = 0.25", "c = 0.125", "PRINT a + b + c"], Num(Fr(7, 8), "float"))
T("f.loop_accum", "variable.float", ["x = 0", "FOR i = 1 TO 10", "x = x + 0.5", "NEXT i", "PRINT x"], Num(5, "num"))

# =====================================================================================
# 4. Relational and logical operators
# =====================================================================================
for op, f in (("<", lambda a, b: a < b), ("<=", lambda a, b: a <= b), ("=", lambda a, b: a == b),
              (">=", lambda a, b: a >= b), (">", lambda a, b: a > b), ("<>", lambda a, b: a != b)):
    for a, b in ((1, 2), (2, 2), (3, 2), (-32768, 32767), (32767, -32768)):
        sa = "(-32767-1)" if a == -32768 else str(a)
        sb = "(-32767-1)" if b == -32768 else str(b)
        T("rel.%s.%d.%d" % ({"<": "lt", "<=": "le", "=": "eq", ">=": "ge", ">": "gt", "<>": "ne"}[op], a, b),
          "expr.relational", ["x = (%s %s %s)" % (sa, op, sb), "PRINT x"], Num(1 if f(a, b) else 0, "int"))
T("rel.chain", "expr.relational", ["x = 1 < 2 < 3"], CErr(), note="non-associative relational")
T("log.and", "expr.logical", ["PRINT (1 AND 1) + (1 AND 0) * 2 + (0 AND 1) * 4"], Num(1, "int"))
T("log.or", "expr.logical", ["PRINT (1 OR 0) + (0 OR 0) * 2 + (0 OR 1) * 4"], Num(5, "int"))
T("log.not", "expr.logical", ["PRINT (NOT 0) + (NOT 1) * 2 + (NOT 5) * 4"], Num(1, "int"))
T("log.nonbool", "expr.logical", ["PRINT 5 AND 3"], Num(1, "int"))
T("log.prec", "expr.logical", ["a = 1 : b = 2", "IF NOT a = b AND b = 2 THEN", 'PRINT "y"', "ENDIF"], Out("y"))
T("log.prec2", "expr.logical", ["IF 1 = 1 OR 1 = 2 AND 2 = 3 THEN", 'PRINT "y"', "ENDIF"], Out("y"),
  note="AND binds tighter than OR")
T("log.float", "expr.logical", ["PRINT 1.5 AND 1"], OkOrErr("1"), note="AND on a float operand")
T("log.shortcircuit", "expr.logical.shortcircuit", ["y = 0", "IF y <> 0 AND 10 / y > 1 THEN", 'PRINT "x"', "ENDIF", 'PRINT "ok"'],
  Out("ok"), known="L-SC", note="spec: AND/OR short-circuit MUST HAVE; documented not implemented (R10.8)")

# =====================================================================================
# 5. Built-in numeric functions
# =====================================================================================
for cid, expr, val, kind in (
        ("abs.pos", "ABS(5)", 5, "int"), ("abs.neg", "ABS(-5)", 5, "int"), ("abs.zero", "ABS(0)", 0, "int"),
        ("abs.f", "ABS(-2.5)", Fr(5, 2), "float"), ("abs.f2", "ABS(2.5)", Fr(5, 2), "float"),
        ("sgn.pos", "SGN(7)", 1, "int"), ("sgn.neg", "SGN(-7)", -1, "int"), ("sgn.zero", "SGN(0)", 0, "int"),
        ("sgn.f_small", "SGN(0.5)", 1, "int"), ("sgn.f_neg_small", "SGN(-0.3)", -1, "int"),
        ("mod.pos", "MOD(17,5)", 2, "int"), ("mod.neg", "MOD(-17,5)", -2, "int"), ("mod.negdiv", "MOD(17,-5)", 2, "int"),
        ("mod.min", "MOD(-32767-1,3)", -2, "int"), ("mod.exact", "MOD(20,5)", 0, "int"),
        ("div.pos", "DIV(17,5)", 3, "int"), ("div.neg", "DIV(-17,5)", -3, "int"), ("div.negneg", "DIV(-17,-5)", 3, "int"),
        ("div.min", "DIV(-32767-1,2)", -16384, "int"),
        ("int.pos", "INT(7)", 7, "int"), ("int.f", "INT(2.7)", 2, "int"), ("int.fneg", "INT(-2.7)", -2, "int"),
        ("int.half", "INT(7/2)", 3, "int"), ("int.small", "INT(0.9999)", 0, "int"),
        ("sqr.4", "SQR(4)", 2, "num"), ("sqr.2", "SQR(2)", Fr(14142136, 10000000), "float"),
        ("sqr.10000", "SQR(10000)", 100, "num"), ("sqr.0", "SQR(0)", 0, "num"),
        ("sqr.f", "SQR(2.25)", Fr(3, 2), "float"), ("sqr.f2", "SQR(0.25)", Fr(1, 2), "float"),
        ("sqr.32767", "SQR(32767)", Fr(1810193, 10000), "float"),
        ("pi", "PI()", Fr(31415927, 10000000), "float"),
        ("rad.180", "RAD(180)", Fr(31415927, 10000000), "float"), ("deg.pi", "DEG(PI())", 180, "num"),
        ("deg.1", "DEG(1)", Fr(572957795, 10000000), "float"), ("rad.f", "RAD(0.5)*1000", Fr(87266, 10000), "float"),
        ("sin.0", "SIN(0)", 0, "num"), ("sin.30", "SIN(30)", Fr(1, 2), "float"), ("sin.90", "SIN(90)", 1, "num"),
        ("sin.270", "SIN(270)", -1, "num"), ("sin.m30", "SIN(-30)", Fr(-1, 2), "float"),
        ("sin.390", "SIN(390)", Fr(1, 2), "float"), ("cos.60", "COS(60)", Fr(1, 2), "float"),
        ("cos.0", "COS(0)", 1, "num"), ("cos.180", "COS(180)", -1, "num"), ("tan.45", "TAN(45)", 1, "num"),
        ("sin.f", "SIN(30.5)", Fr(50754, 100000), "float")):
    T("fn." + cid, "fn." + cid.split(".")[0].upper(), ["PRINT " + expr], Num(val, kind))
T("fn.abs.min", "fn.ABS", ["PRINT ABS(-32767-1)"], Num(32768, "num"), known=D11X, note="cost study: still wraps in both variants")
T("fn.div.min_m1", "fn.DIV", ["PRINT DIV(-32767-1,-1)"], OkOrErr("32768"), known=D11X, note="cost study: still wraps in both variants")
T("fn.int.big", "fn.INT", ["PRINT INT(30000*3+0.5)"], Num(90000), known=D11X)
T("fn.mod.zero", "fn.MOD", ["PRINT MOD(5,0)"], RErr(5), note="manual: DIVISION BY ZERO for /, MOD, DIV")
T("fn.div.zero", "fn.DIV", ["PRINT DIV(5,0)"], RErr(5))
T("fn.sqr.neg", "fn.SQR", ["PRINT SQR(-4)"], AnyErr(), note="square root of a negative number")
T("fn.tan.90", "fn.TAN", ["PRINT TAN(90)"], RErr(5))
T("fn.mod.float", "fn.MOD", ["PRINT MOD(7.5,2)"], OkOrErr("1.5000"), decision="MOD/DIV on floats")
T("fn.rnd.range", "fn.RND", ["RANDOMISE 7", "ok = 1", "FOR i = 1 TO 200", "r = RND(6)", "IF r < 0 OR r > 5 THEN", "ok = 0", "ENDIF", "NEXT i", "PRINT ok"],
  Num(1, "int"))
T("fn.rnd.covers", "fn.RND", ["RANDOMISE 11", "DIM h(6)", "FOR i = 1 TO 300", "r = RND(6)", "h(r) = h(r) + 1", "NEXT i",
                              "n = 0", "FOR i = 0 TO 5", "IF h(i) > 0 THEN", "n = n + 1", "ENDIF", "NEXT i", "PRINT n"], Num(6, "int"))
T("fn.rnd.repeat", "fn.RND", ["RANDOMISE 5", "a = RND(1000)", "b = RND(1000)", "RANDOMISE 5", "c = RND(1000)", "d = RND(1000)",
                              "PRINT (a = c) AND (b = d)"], Num(1, "int"))
T("fn.rnd.zero", "fn.RND", ["PRINT RND(0) + RND(-5) + RND(1)"], Num(0, "int"))
T("fn.peek", "fn.PEEK", ["POKE 40000,123", "PRINT PEEK(40000)"], Num(123, "int"), note="40000 is an address literal > 32767")
T("fn.peek.rom", "fn.PEEK", ["PRINT PEEK(0)"], Num(0xF3, "int"), note="HOME ROM byte 0 = di")
T("fn.poke.trunc", "stmt.POKE", ["POKE 30000,300", "PRINT PEEK(30000)"], Num(44, "int"), decision="POKE value > 255 truncates (V1 errored?)")
T("fn.usr", "fn.USR", ["POKE 30000,33 : POKE 30001,57 : POKE 30002,48 : POKE 30003,201", "PRINT USR(30000)"], Num(12345, "int"),
  note="ld hl,12345 / ret")
T("fn.free", "fn.FREE", ["x = FREE()", "PRINT x > 1000"], Num(1, "int"))
T("fn.free1", "fn.FREE", ["x = FREE(1)", "PRINT x > 100"], Num(1, "int"))
T("fn.free.noparen", "fn.FREE", ["PRINT FREE"], CErr(29))
T("fn.pi.noparen", "fn.PI", ["PRINT PI"], CErr(29))
T("fn.argc.abs0", "fn.argcount", ["PRINT ABS()"], CErr())
T("fn.argc.abs2", "fn.argcount", ["PRINT ABS(1,2)"], CErr())
T("fn.argc.mod1", "fn.argcount", ["PRINT MOD(5)"], CErr())
T("fn.argc.mod3", "fn.argcount", ["PRINT MOD(5,2,1)"], CErr())
T("fn.argc.pi1", "fn.argcount", ["PRINT PI(1)"], CErr())
T("fn.argc.left1", "fn.argcount", ['PRINT LEFT$("abc")'], CErr())
T("fn.argc.mid2", "fn.argcount", ['PRINT MID$("abc",2)'], CErr(), decision="MID$ with 2 args (classic: rest of string)")
T("fn.argtype.len_num", "fn.argtype", ["PRINT LEN(5)"], CErr())
T("fn.argtype.abs_str", "fn.argtype", ['PRINT ABS("x")'], CErr())
T("fn.argtype.left_num", "fn.argtype", ["PRINT LEFT$(5,1)"], CErr())
T("fn.nested", "fn.nesting", ["PRINT ABS(SGN(-5)*MOD(17,5)+DIV(9,2))"], Num(2, "int"))
T("fn.nested2", "fn.nesting", ["PRINT LEN(STR$(ABS(-123))+CHR$(65))"], Num(4, "int"))

# =====================================================================================
# 6. Strings
# =====================================================================================
def strt(cid, lines, out, known=None, note="", feature=None):
    T("str." + cid, feature or "string", lines, Out(out), known=known, note=note)


strt("assign", ['a$ = "hello"', "PRINT a$"], "hello")
strt("concat", ['a$ = "foo"', 'b$ = a$ + "bar"', "PRINT b$"], "foobar")
strt("concat3", ['PRINT "a" + "b" + "c"'], "abc")
strt("concat_vars", ['a$ = "x" : b$ = "y" : c$ = "z"', "PRINT a$ + b$ + c$ + a$"], "xyzx")
strt("concat_cap", ['a$ = "' + "a" * 20 + '"', "b$ = a$ + a$", "PRINT LEN(b$)"], "31")
strt("empty", ['a$ = ""', "PRINT LEN(a$)"], "0")
strt("uninit", ["PRINT LEN(z$)"], "0")
strt("len", ['PRINT LEN("foobar")'], "6")
strt("code", ['PRINT CODE("A")'], "65")
strt("code_empty", ['PRINT CODE("")'], "0")
strt("chr", ["PRINT CHR$(72) + CHR$(105)"], "Hi")
strt("str_int", ["PRINT STR$(-123) + \"!\""], "-123!")
strt("str_float", ['PRINT STR$(2.5)'], "2.5000")
strt("val_int", ['PRINT VAL("123") + 1'], "124")
strt("val_neg", ['PRINT VAL("-45")'], "-45")
strt("val_float", ['PRINT VAL("1.5") * 2'], "3.0000")
strt("val_stop", ['PRINT VAL("12abc34")'], "12", note="manual: VAL stops at the first non-digit")
strt("val_empty", ['PRINT VAL("")'], "0")
T("str.val_big", "fn.VAL", ['PRINT VAL("99999")'], Num(99999), note="5-digit value above 32767")
strt("upper", ['PRINT UPPER$("Hello 1!")'], "HELLO 1!")
strt("lower", ['PRINT LOWER$("Hello 1!")'], "hello 1!")
strt("left", ['PRINT LEFT$("abcdef",3)'], "abc")
strt("left_clamp", ['a$ = LEFT$("abc",10)', 'b$ = LEFT$("abc",0)', 'c$ = LEFT$("abc",-2)', 'PRINT a$ + "!" + b$ + "!" + c$ + "!"'], "abc!!!")
strt("right", ['PRINT RIGHT$("abcdef",2)'], "ef")
strt("right_clamp", ['PRINT RIGHT$("abc",9)'], "abc")
strt("mid", ['PRINT MID$("hello",2,3)'], "ell")
strt("mid_clamp", ['PRINT MID$("hello",4,10)'], "lo")
T("str.mid_start0", "fn.MID", ['PRINT MID$("hello",0,2)'], OkOrErr("he"), decision="MID$ start 0: clamp to 1 or error")
strt("mid_past", ['m$ = MID$("hello",9,2)', 'PRINT "<" + m$ + ">"'], "<>")
strt("temps.lit_fn_lit", ['PRINT "<" + MID$("hello",2,3) + ">"'], "<ell>", note="font has no [ ] | glyphs: < > used")
strt("temps.fn_lit_fn", ['PRINT LEFT$("abc",10) + "!" + LEFT$("abc",1)'], "abc!a")
strt("temps.fn2", ['PRINT UPPER$("a") + LOWER$("B")'], "Ab", note="two string-function results live at once")
strt("temps.lit_fn", ['PRINT "a" + UPPER$("b")'], "aB")
strt("temps.fn_fn_fn", ['PRINT LEFT$("xyz",1) + MID$("xyz",2,1) + RIGHT$("xyz",1)'], "xyz")
strt("temps.chr3", ["PRINT CHR$(65) + CHR$(66) + CHR$(67)"], "ABC")
strt("temps.nested", ['PRINT LEFT$("ab" + "cd",3) + RIGHT$("ef" + "gh",2)'], "abcgh")
strt("temps.strs", ["PRINT STR$(1) + STR$(2) + STR$(3)"], "123")
strt("temps.assign", ['a$ = UPPER$("q") + LOWER$("R") + "s"', "PRINT a$"], "Qrs")
strt("cmp_eq", ['a$ = "abc"', 'IF a$ = "abc" THEN', 'PRINT "eq"', "ENDIF"], "eq")
strt("cmp_lt", ['IF "abc" < "abd" THEN', 'PRINT "lt"', "ENDIF"], "lt")
strt("cmp_lt_prefix", ['IF "ab" < "abc" THEN', 'PRINT "lt"', "ENDIF"], "lt")
strt("cmp_lt_false", ['IF "b" < "a" THEN', 'PRINT "wrong"', "ELSE", 'PRINT "ok"', "ENDIF"], "ok")
strt("cmp_case", ['IF "a" = "A" THEN', 'PRINT "same"', "ELSE", 'PRINT "diff"', "ENDIF"], "diff")
for op in ("<>", ">", "<=", ">="):
    T("str.cmp_op_%s" % {"<>": "ne", ">": "gt", "<=": "le", ">=": "ge"}[op], "string.compare.ordering",
      ['IF "b" %s "a" THEN' % op, 'PRINT "t"', "ELSE", 'PRINT "f"', "ENDIF"],
      Out("t" if op in ("<>", ">", ">=") else "f"), known="L-STR",
      note="spec MUST HAVE (V2_LANGUAGE_SPEC); probe: error 3 (cost study)")
T("str.cmp_in_expr", "string.compare", ['x = ("a" = "a")', "PRINT x"], OkOrErr("1"),
  note="string comparison as a value outside IF")
T("str.cmp_and", "string.compare", ['a$ = "x"', 'IF a$ = "x" AND 1 = 1 THEN', 'PRINT "y"', "ENDIF"], Out("y"),
  note="string comparison combined with AND")
T("str.instr", "fn.INSTR", ['PRINT INSTR("hello","ll")'], Num(3, "int"), known="L-INSTR", note="documented in the manual, absent in V2")
T("str.slice", "string.slice", ['a$ = "hello"', "PRINT a$(2 TO 3)"], CErr(), note="slicing unsupported (MID$)")
T("str.chr_range", "fn.CHR", ["PRINT CHR$(256)"], RErr(15))
T("str.chr_neg", "fn.CHR", ["PRINT CHR$(-1)"], RErr(15))
T("str.num_to_str_var", "string.type", ['a$ = 5'], CErr())
T("str.str_to_num_var", "string.type", ['a = "x"'], CErr())
T("str.inkey_none", "fn.INKEY", ['k$ = INKEY$()', "PRINT LEN(k$)"], Num(0, "int"))
T("str.inkey_noparen", "fn.INKEY", ['k$ = INKEY$'], CErr(29))
T("str.many_vars", "string.variables", ['a$="1":b$="2":c$="3":d$="4":e$="5":f$="6"', "PRINT a$+b$+c$+d$+e$+f$"], Out("123456"))

# =====================================================================================
# 7. PRINT and screen statements
# =====================================================================================
T("print.num", "stmt.PRINT", ["PRINT 42"], Out("42"))
T("print.neg", "stmt.PRINT", ["PRINT -42"], Out("-42"))
T("print.expr_str", "stmt.PRINT", ['PRINT "a" + "b"'], Out("ab"))
T("print.lines", "stmt.PRINT", ['PRINT "1"', 'PRINT "2"', 'PRINT "3"'], Out("1\n2\n3"))
T("print.wrap", "stmt.PRINT", ['a$ = "' + "x" * 20 + '"', "PRINT a$ + a$", 'PRINT "y"'],
  Pred(lambda r: (r.ce == 0 and r.ve == 0 and r.rows[0] == "x" * 31 and "y" in r.text, "rows=%r" % r.rows[:3]), "31 chars on line 1, y later"))
T("print.scroll", "stmt.PRINT", ["FOR i = 1 TO 30", "PRINT i", "NEXT i"],
  Pred(lambda r: (r.ce == 0 and r.ve == 0 and r.rows[22] == "30" and r.rows[0] == "8" and r.rows[23] == "",
                  "rows0=%r rows22=%r rows23=%r" % (r.rows[0], r.rows[22], r.rows[23])), "scrolls: row 0 = 8, row 22 = 30"))
T("print.semicolon", "stmt.PRINT.multi", ['PRINT "a"; 1; "b"; 2'], per(b=CErr(64), x=Out("a1b2")))
T("print.comma", "stmt.PRINT.multi", ['PRINT "ab", "cd"'], per(b=CErr(64), x=Out("ab".ljust(16) + "cd")))
T("print.trailing_semi", "stmt.PRINT.multi", ['PRINT "x";', 'PRINT "y"'], per(b=CErr(64), x=Out("xy")))
T("print.bare", "stmt.PRINT.multi", ['PRINT "a"', "PRINT", 'PRINT "b"'], per(b=CErr(), x=Out("a\n\nb")))
T("print.comma_wrap", "stmt.PRINT.multi", ['PRINT "a", "b", "c"'], per(b=CErr(64), x=Out("a".ljust(16) + "b\nc")))
T("print.multi_float", "stmt.PRINT.multi", ["PRINT 1.5; 2"], per(b=CErr(64), x=Out("1.50002")))
T("print.multi_in_if", "stmt.PRINT.multi", ["IF 1 THEN", 'PRINT "y"; 1', "ELSE", 'PRINT "n"', "ENDIF"], per(b=CErr(64), x=Out("y1")))
T("print.multi_temps", "stmt.PRINT.multi", ['PRINT UPPER$("a"); LOWER$("B"); 1.5*2.5; 3.5*4.5'],
  per(b=CErr(64), x=Out("Ab3.750015.7500")))
T("print.at", "stmt.AT", ["AT 5,10", 'PRINT "X"'], Pred(lambda r: (r.ce == 0 and r.rows[5] == " " * 10 + "X", "row5=%r" % r.rows[5]), "X at row 5 col 10"))
T("print.at_clamp", "stmt.AT", ["AT 30,40", 'PRINT "Z"'], Pred(lambda r: (r.ce == 0 and r.ve == 0 and "Z" in r.text, "rows=%r" % r.rows[20:]), "clamped, no crash"))
T("print.tab", "stmt.TAB", ["TAB 7", 'PRINT "T"'], Pred(lambda r: (r.ce == 0 and r.rows[0] == " " * 7 + "T", "row0=%r" % r.rows[0]), "T at col 7"))
T("print.at_inline", "stmt.PRINT.AT", ['PRINT AT 1,1; "x"'], CErr(), note="PRINT AT item unsupported (missing feature)")
T("print.cls", "stmt.CLS", ['PRINT "gone"', "CLS", 'PRINT "kept"'], Out("kept"))
T("print.ink_attr", "stmt.INK", ["INK 2", "PAPER 5", 'PRINT "c"'],
  Pred(lambda r: (r.ce == 0 and r.attrs[0] == (5 << 3) | 2, "attr0=%02X" % r.attrs[0]), "attr = paper5/ink2"))
T("print.bright_flash", "stmt.BRIGHT", ["BRIGHT 1", "FLASH 1", 'PRINT "c"'],
  Pred(lambda r: (r.ce == 0 and r.attrs[0] & 0xC0 == 0xC0, "attr0=%02X" % r.attrs[0]), "bright+flash bits"))
T("print.inverse", "stmt.INVERSE", ["INVERSE 1", 'PRINT "A"'],
  Pred(lambda r: (r.ce == 0 and r.attrs[0] == 0x07, "attr0=%02X row=%r" % (r.attrs[0], r.rows[0])), "inverse swaps ink/paper (attr $07)"))
T("print.over", "stmt.OVER", ["PLOT 0,191", "OVER 1", "PLOT 0,191", "PRINT POINT(0,191)"], Num(0, "int"), note="OVER 1 XORs")
T("print.border", "stmt.BORDER", ["BORDER 3", 'PRINT "b"'], Out("b"))
T("print.ink_range", "stmt.INK", ["INK 9", 'PRINT "i"'], OkOrErr("i"), decision="INK 9 (stock: contrast) is masked to 1")

# =====================================================================================
# 8. Graphics
# =====================================================================================
T("gfx.plot_point", "stmt.PLOT", ["PLOT 10,20", "p = POINT(10,20) + POINT(11,20)", "CLS", "PRINT p"], Num(1, "int"))
T("gfx.line", "stmt.LINE", ["LINE 0,0 TO 100,50", "p = POINT(0,0) + POINT(100,50) + POINT(50,25)", "CLS", "PRINT p"], Num(3, "int"))
T("gfx.plot_clamp", "stmt.PLOT", ["PLOT 255,300", "p = POINT(255,191)", "CLS", "PRINT p"], OkOrErr("1"),
  decision="out-of-range PLOT coordinates: clamp (y>191) / wrap mod 256 / error")
T("gfx.point_range", "fn.POINT", ["PRINT POINT(0,500)"], Num(0, "int"))
T("gfx.attr_fn", "fn.ATTR", ["INK 4", "PAPER 1", "AT 3,4", 'PRINT "q"', "x = ATTR(3,4)", "AT 10,0", "PRINT x"],
  Pred(lambda r: (r.ce == 0 and r.rows[10] == str((1 << 3) | 4), "row10=%r" % r.rows[10]), "ATTR reads 12"))
T("gfx.attr_oob", "fn.ATTR", ["PRINT ATTR(30,40)"], Num(0, "int"))
T("gfx.argc_plot", "stmt.PLOT", ["PLOT 1"], CErr(22))
T("gfx.line_noto", "stmt.LINE", ["LINE 1,2,3,4"], CErr(24))

# =====================================================================================
# 9. Control flow
# =====================================================================================
T("if.goto", "stmt.IF.goto", ["x = 1", "IF x = 1 THEN GOTO yes", 'PRINT "no"', "END", "yes:", 'PRINT "yes"'], Out("yes"))
T("if.goto_false", "stmt.IF.goto", ["x = 0", "IF x = 1 THEN GOTO yes", 'PRINT "no"', "END", "yes:", 'PRINT "yes"'], Out("no"))
T("if.block", "stmt.IF.block", ["x = 5", "IF x > 3 THEN", 'PRINT "big"', "ELSE", 'PRINT "small"', "ENDIF"], Out("big"))
T("if.block_else", "stmt.IF.block", ["x = 1", "IF x > 3 THEN", 'PRINT "big"', "ELSE", 'PRINT "small"', "ENDIF"], Out("small"))
T("if.block_noelse", "stmt.IF.block", ["IF 0 THEN", 'PRINT "x"', "ENDIF", 'PRINT "after"'], Out("after"))
T("if.nested", "stmt.IF.block", ["a = 1 : b = 2", "IF a = 1 THEN", "IF b = 2 THEN", 'PRINT "11"', "ELSE", 'PRINT "12"', "ENDIF", "ELSE",
                                  'PRINT "2"', "ENDIF"], Out("11"))
T("if.elseif_chain", "stmt.IF.elseif", ["x = 2", "IF x = 1 THEN", 'PRINT "one"', "ELSE IF x = 2 THEN", 'PRINT "two"', "ELSE", 'PRINT "other"',
                                         "ENDIF", "ENDIF"], Out("two"))
T("if.elseif_kw", "stmt.IF.elseif", ["x = 2", "IF x = 1 THEN", 'PRINT "one"', "ELSEIF x = 2 THEN", 'PRINT "two"', "ENDIF"], Out("two"),
  known="L-ELIF", note="V1/manual ELSEIF; V2 error")
T("if.single_line", "stmt.IF.single", ["IF 1 THEN PRINT 5", 'PRINT "after"'], CErr(9),
  note="V2 decision (R10.8 L1): IF is always a block; the V1 manual documents single-line IF")
T("if.single_line_endif", "stmt.IF.block", ['IF 1 THEN PRINT "y" ENDIF'], OkOrErr("y"), note="a block IF on one line")
T("if.colon_body", "stmt.IF.block", ['IF 1 THEN : PRINT "y" : ENDIF'], Out("y"))
T("if.missing_endif", "stmt.IF.block", ["IF 1 THEN", 'PRINT "x"'], CErr(9))
T("if.missing_then", "stmt.IF", ["IF 1 PRINT 1"], CErr(8))
T("if.stray_else", "stmt.IF", ['PRINT "a"', "ELSE"], CErr(64))
T("if.float_cond", "stmt.IF.condition", ["x = 0.5", "IF x THEN", 'PRINT "true"', "ELSE", 'PRINT "false"', "ENDIF"], Out("true"),
  note="a nonzero float condition")
T("if.float_cond0", "stmt.IF.condition", ["x = 2.5", "y = 0.25", "IF y THEN", 'PRINT "true"', "ELSE", 'PRINT "false"', "ENDIF"], Out("true"))
T("if.float_lit_cond", "stmt.IF.condition", ["IF 0.5 THEN", 'PRINT "true"', "ELSE", 'PRINT "false"', "ENDIF"], Out("true"))
T("goto.fwd_back", "stmt.GOTO", ["n = 0", "top:", "n = n + 1", "IF n < 5 THEN GOTO top", "PRINT n"], Num(5, "int"))
T("goto.undef", "stmt.GOTO", ["GOTO nowhere"], CErr(7))
T("goto.num", "stmt.GOTO", ["GOTO 10"], CErr(12))
T("label.dup", "label", ["a:", "a:", "PRINT 1"], CErr(), note="duplicate label definition")
T("label.with_stmt", "label", ["start: PRINT 1"], Out("1"))
T("label.same_as_var", "label", ["x = 3", "x:", "PRINT x"], Num(3, "int"), note="labels and variables are separate namespaces")
T("for.basic", "stmt.FOR", ["s = 0", "FOR i = 1 TO 10", "s = s + i", "NEXT i", "PRINT s"], Num(55, "int"))
T("for.final_value", "stmt.FOR", ["FOR i = 1 TO 3", "NEXT i", "PRINT i"], Num(4, "int"))
T("for.step2", "stmt.FOR.step", ["FOR i = 1 TO 10 STEP 3", "PRINT i", "NEXT i"], Out("1\n4\n7\n10"))
T("for.step_neg", "stmt.FOR.step", ["s = 0", "FOR i = 10 TO 1 STEP -3", "s = s + i", "NEXT i", "PRINT s"], Num(22, "int"))
T("for.zero_trip", "stmt.FOR.zerotrip", ["FOR i = 5 TO 1", 'PRINT "body"', "NEXT i", 'PRINT "done"'], Out("done"),
  note="manual: classic entry semantics -- the body never runs")
T("for.zero_trip_neg", "stmt.FOR.zerotrip", ["FOR i = 1 TO 5 STEP -1", 'PRINT "body"', "NEXT i", 'PRINT "done"'], Out("done"))
T("for.single", "stmt.FOR", ["FOR i = 3 TO 3", "PRINT i", "NEXT i"], Out("3"))
T("for.to_32767", "stmt.FOR.limit", ["n = 0", "FOR i = 32765 TO 32767", "n = n + 1", "NEXT i", "PRINT n"], Num(3, "int"), known=D11B,
  maxi=8_000_000)
T("for.to_m32768", "stmt.FOR.limit", ["n = 0", "FOR i = -32766 TO -32767-1 STEP -1", "n = n + 1", "NEXT i", "PRINT n"], Num(3, "int"),
  maxi=8_000_000)
T("for.step_big", "stmt.FOR.limit", ["n = 0", "FOR i = 0 TO 32767 STEP 20000", "n = n + 1", "NEXT i", "PRINT n"], Num(2, "int"),
  maxi=8_000_000, note="0, 20000; the next value 40000 overflows")
T("for.float_limit", "stmt.FOR.float", ["FOR i = 1 TO 2.5", "PRINT i", "NEXT i"], Out("1\n2"))
T("for.float_step", "stmt.FOR.float", ["n = 0", "FOR i = 1 TO 3 STEP 0.5", "n = n + 1", "NEXT i", "PRINT n"], Num(5, "int"), maxi=8_000_000)
T("for.float_start", "stmt.FOR.float", ["FOR i = 0.5 TO 2", "PRINT i", "NEXT i"], Lines(F(Fr(1, 2)), F(Fr(3, 2))))
T("for.float_var_limit", "stmt.FOR.float", ["m = 5/2", "n = 0", "FOR i = 1 TO m", "n = n + 1", "NEXT i", "PRINT n"], Num(2, "int"))
T("for.limit_expr_once", "stmt.FOR", ["n = 3", "c = 0", "FOR i = 1 TO n", "n = 10", "c = c + 1", "NEXT i", "PRINT c"], Num(3, "int"),
  note="limit evaluated once")
T("for.nested", "stmt.FOR.nesting", ["s = 0", "FOR i = 1 TO 3", "FOR j = 1 TO 4", "s = s + i * j", "NEXT j", "NEXT i", "PRINT s"], Num(60, "int"))
T("for.nested9", "stmt.FOR.nesting", ["FOR a = 1 TO 1", "FOR b = 1 TO 1", "FOR c = 1 TO 1", "FOR d = 1 TO 1", "FOR e = 1 TO 1", "FOR f = 1 TO 1",
                                      "FOR g = 1 TO 1", "FOR h = 1 TO 1", "FOR k = 1 TO 1", 'PRINT "deep"', "NEXT k", "NEXT h", "NEXT g", "NEXT f",
                                      "NEXT e", "NEXT d", "NEXT c", "NEXT b", "NEXT a"], OkOrErr("deep"),
  note="R10.8: nesting limited by memory, manual says 8")
T("for.next_mismatch", "stmt.NEXT", ["FOR i = 1 TO 2", "NEXT j"], CErr(56))
T("for.next_without_for", "stmt.NEXT", ["NEXT i"], CErr())
T("for.without_next", "stmt.FOR", ["FOR i = 1 TO 2", 'PRINT "x"'], CErr(65))
T("for.bare_next", "stmt.NEXT.bare", ["FOR i = 1 TO 2", "PRINT i", "NEXT"], Out("1\n2"), known="L-NEXT",
  note="manual: NEXT variable optional; probe error 10 (cost study)")
T("for.exit", "stmt.EXIT", ["FOR i = 1 TO 100", "IF i > 3 THEN", "EXIT FOR", "ENDIF", "PRINT i", "NEXT i", 'PRINT "out"'], Out("1\n2\n3\nout"))
T("for.exit_nested", "stmt.EXIT", ["FOR i = 1 TO 2", "FOR j = 1 TO 5", "IF j = 2 THEN", "EXIT FOR", "ENDIF", "PRINT i * 10 + j", "NEXT j", "NEXT i"],
  Out("11\n21"))
T("for.exit_none", "stmt.EXIT", ["EXIT FOR"], CErr())
T("for.goto_out_repeat", "stmt.FOR.goto", ["n = 0", "again:", "FOR i = 1 TO 10", "IF i = 2 THEN GOTO quit", "NEXT i", "quit:", "n = n + 1",
                                            "IF n < 50 THEN GOTO again", "PRINT n"], Num(50, "int"),
  note="leaving a FOR by GOTO 50 times must not exhaust the loop stack")
T("for.goto_into", "stmt.FOR.goto", ["GOTO inside", "FOR i = 1 TO 3", "inside:", 'PRINT "in"', "NEXT i"], AnyErr(),
  note="jumping into a FOR body: NEXT without an active loop")
T("for.next_in_if", "stmt.FOR.structure", ["c = 0", "IF c THEN", "FOR i = 1 TO 3", "ENDIF", "NEXT i", 'PRINT "x"'], AnyErr(),
  note="FOR opened inside an IF block, NEXT outside it (structure crossing)")
T("for.var_modified", "stmt.FOR", ["n = 0", "FOR i = 1 TO 10", "i = i + 1", "n = n + 1", "NEXT i", "PRINT n"], Num(5, "int"))
T("for.var_float_body", "stmt.FOR.float", ["n = 0", "FOR i = 1 TO 4", "i = i + 0.5", "n = n + 1", "NEXT i", "PRINT n"], OkOrErr("3"),
  note="the body makes the loop variable a float")
T("end.stmt", "stmt.END", ['PRINT "a"', "END", 'PRINT "b"'], Out("a"))
T("stop.stmt", "stmt.STOP", ['PRINT "a"', "STOP", 'PRINT "b"'], Out("a"))

# =====================================================================================
# 10. Procedures and user functions
# =====================================================================================
T("proc.basic", "stmt.PROC", ["CALL greet(3)", "END", "PROC greet(n):", "PRINT n * 2", "ENDP"], Out("6"))
T("proc.param_restore", "stmt.PROC.scope", ["n = 7", "CALL p(1)", "PRINT n", "END", "PROC p(n):", "PRINT n", "ENDP"], Out("1\n7"))
T("proc.global", "stmt.PROC.scope", ["g = 1", "CALL p(5)", "PRINT g", "END", "PROC p(x):", "g = g + x", "ENDP"], Num(6, "int"))
T("proc.recursion", "stmt.PROC.recursion", ["s = 0", "CALL r(10)", "PRINT s", "END", "PROC r(n):", "s = s + n", "IF n > 0 THEN", "CALL r(n - 1)",
                                             "ENDIF", "ENDP"], Num(55, "int"))
T("proc.param_after_recursion", "stmt.PROC.recursion", ["CALL r(3)", "END", "PROC r(n):", "IF n > 0 THEN", "CALL r(n - 1)", "ENDIF", "PRINT n", "ENDP"],
  Out("0\n1\n2\n3"))
T("proc.deep", "stmt.PROC.recursion", ["CALL r(150)", 'PRINT "ok"', "END", "PROC r(n):", "IF n > 0 THEN", "CALL r(n - 1)", "ENDIF", "ENDP"], Out("ok"))
T("proc.runaway", "stmt.PROC.recursion", ["CALL r(1)", "END", "PROC r(n):", "CALL r(n + 1)", "ENDP"],
  Pred(lambda r: (r.ce == 0 and r.ve in (2, 6) and r.msg == "STACK", "ve=%s msg=%s" % (r.ve, r.msg)), "STACK OVERFLOW"), maxi=60_000_000)
T("proc.float_arg", "stmt.PROC", ["CALL p(2.5)", "END", "PROC p(x):", "PRINT x * 2", "ENDP"], Num(5, "num"))
T("proc.expr_arg", "stmt.PROC", ["a = 3", "CALL p(a * a + 1)", "END", "PROC p(x):", "PRINT x", "ENDP"], Num(10, "int"))
T("proc.fn_arg", "stmt.PROC.nesting", ["DEF FN f(x) = x * 10", "CALL p(FN f(4))", "END", "PROC p(v):", "PRINT v", "ENDP"], Num(40, "int"),
  known={"baseline": "N-1"})
T("proc.fn_arg2", "stmt.PROC.nesting", ["DEF FN sq(x) = x * x", "CALL show(FN sq(3) + FN sq(4))", "END", "PROC show(v):", "PRINT v", "ENDP"],
  Num(25, "int"), known={"baseline": "N-1"})
T("proc.no_endp", "stmt.PROC", ["PROC p(x):", "PRINT x"], CErr(16))
T("proc.two_params", "stmt.PROC", ["PROC p(a,b):", "ENDP"], CErr(20))
T("proc.no_params", "stmt.PROC", ["PROC p():", "ENDP"], CErr(19))
T("proc.call_undef", "stmt.CALL", ["CALL nope(1)"], CErr(7))
T("proc.call_noparen", "stmt.CALL", ["CALL p", "END", "PROC p(x):", "ENDP"], CErr(14))
T("proc.fallthrough", "stmt.PROC", ['PRINT "a"', "PROC p(x):", 'PRINT "in"', "ENDP", 'PRINT "b"'], Out("a\nb"),
  note="a PROC body is skipped when reached by normal flow")
T("proc.goto_label", "stmt.CALL", ["CALL lbl(1)", 'PRINT "back"', "END", "lbl:", 'PRINT "at label"'], AnyErr(),
  note="CALL of a plain label (no PROC): stack discipline")
T("proc.goto_proc", "stmt.GOTO", ["GOTO p", "END", "PROC p(x):", "PRINT x", "ENDP"], AnyErr(),
  note="GOTO into a PROC: PARAM_BIND/RET without a CALL")
T("proc.nested_def", "stmt.PROC.nesting", ["CALL outer(1)", 'PRINT "end"', "END", "PROC outer(a):", "PROC inner(b):", "PRINT b", "ENDP",
                                           "PRINT a", "ENDP"], OkOrErr("1\nend"), note="PROC defined inside a PROC body")
T("proc.deffn_inside", "stmt.PROC.nesting", ["CALL p(5)", 'PRINT "end"', "END", "PROC p(a):", "DEF FN d(x) = x * 2", "PRINT FN d(a)", "ENDP"],
  OkOrErr("10\nend"), note="DEF FN inside a PROC body")
T("proc.endp_in_if", "stmt.PROC", ["CALL p(1)", "END", "PROC p(x):", "IF x THEN", "ENDP", "ENDIF"], CErr())
T("fn.def_basic", "stmt.DEF FN", ["DEF FN dbl(x) = x * 2", "PRINT FN dbl(21)"], Num(42, "int"))
T("fn.def_float", "stmt.DEF FN", ["DEF FN half(x) = x / 2", "PRINT FN half(5)"], Num(Fr(5, 2), "float"))
T("fn.def_nested_call", "stmt.DEF FN", ["DEF FN a(x) = x + 1", "DEF FN b(x) = FN a(x) * 2", "PRINT FN b(3)"], Num(8, "int"))
T("fn.def_recursive", "stmt.DEF FN", ["DEF FN fact(n) = n", "PRINT FN fact(5)"], Num(5, "int"))
T("fn.def_param_restore", "stmt.DEF FN.scope", ["x = 100", "DEF FN f(x) = x + 1", "PRINT FN f(1)", "PRINT x"], Out("2\n100"))
T("fn.def_global", "stmt.DEF FN.scope", ["k = 3", "DEF FN f(x) = x * k", "PRINT FN f(5)"], Num(15, "int"))
T("fn.def_undef", "stmt.DEF FN", ["PRINT FN nope(1)"], CErr(7))
T("fn.def_two_args", "stmt.DEF FN", ["DEF FN f(a,b) = a + b"], CErr())
T("fn.def_string", "stmt.DEF FN", ['DEF FN s$(x) = "a"'], CErr(), note="string-valued DEF FN unsupported")
T("fn.def_in_expr", "stmt.DEF FN", ["DEF FN sq(x) = x * x", "PRINT FN sq(3) + FN sq(4) * 2"], Num(41, "int"))
T("fn.def_arg_fn", "stmt.DEF FN", ["DEF FN inc(x) = x + 1", "PRINT FN inc(FN inc(FN inc(0)))"], Num(3, "int"))
T("fn.def_mod_param", "stmt.DEF FN", ["DEF FN t(n) = MOD(n,15)", "PRINT FN t(20)"], Num(5, "int"))
T("fn.def_array_param_collision", "namespace.array_scalar", ["DIM n(3)", "DEF FN t(n) = MOD(n,15)", "PRINT FN t(20)"], Num(5, "int"),
  known="N-4", note="showcase.txt pattern: array n and parameter n")

# =====================================================================================
# 11. Arrays
# =====================================================================================
T("arr.basic", "array.numeric", ["DIM a(5)", "a(0) = 10", "a(4) = 40", "PRINT a(0) + a(4)"], Num(50, "int"))
T("arr.zero_init", "array.numeric", ["DIM a(4)", "PRINT a(0) + a(1) + a(2) + a(3)"], Num(0, "int"))
T("arr.nested_index", "array.numeric", ["DIM a(5)", "a(1) = 3", "a(a(1)) = 99", "PRINT a(3)"], Num(99, "int"))
T("arr.expr_index", "array.numeric", ["DIM a(10)", "i = 2", "a(i * 3 + 1) = 7", "PRINT a(7)"], Num(7, "int"))
T("arr.oob_read", "array.bounds", ["DIM a(5)", "PRINT a(5)"], RErr(10))
T("arr.oob_read_neg", "array.bounds", ["DIM a(5)", "PRINT a(-1)"], RErr(10))
T("arr.oob_write", "array.bounds", ["DIM a(5)", "a(5) = 1"], RErr(10))
T("arr.oob_write_neg", "array.bounds", ["DIM a(5)", "a(-1) = 1"], RErr(10))
T("arr.float_index", "array.type", ["DIM a(5)", "a(1.5) = 3"], AnyErr(), note="non-integer subscript")
T("arr.float_value", "array.type", ["DIM a(5)", "a(1) = 2.5", "PRINT a(1)"], OkOrErr("2.5000"),
  decision="numeric arrays hold 16-bit integers (R10.8); a float value must not be stored silently")
T("arr.promoted_value", "array.type", ["DIM a(2)", "a(0) = 30000 * 3"], AnyErr(), only=NEW, note="D11 promotion result stored into an int array")
T("arr.redim", "array.numeric", ["DIM a(3)", "DIM a(3)"], CErr(38))
T("arr.undeclared", "array.numeric", ["b(1) = 2"], CErr(42))
T("arr.undeclared_read", "array.numeric", ["PRINT q(1)"], CErr(), note="read of a never-DIMd array name")
T("arr.dim_var", "array.dim", ["n = 5", "DIM a(n)"], CErr(34))
T("arr.dim_zero", "array.dim", ["DIM a(0)"], CErr(35))
T("arr.dim_2d", "array.dim", ["DIM a(3,3)"], CErr())
T("arr.dim_huge", "array.dim", ["DIM a(30000)"], RErr(64), note="OUT OF MEMORY at run time")
T("arr.dimn", "fn.DIMN", ["DIM scores(12)", "PRINT DIMN(scores)"], Num(12, "int"))
T("arr.dimn_str", "fn.DIMN", ["DIM n$(7)", "PRINT DIMN(n$)"], OkOrErr("7"), note="manual: DIMN(name$) for a string array")
T("arr.dimn_bad", "fn.DIMN", ["PRINT DIMN(nope)"], CErr(47))
T("arr.name_scalar_collision", "namespace.array_scalar", ["DIM a(3)", "a = 5", "PRINT a"], OkOrErr("5"),
  note="array a and scalar a")
T("arr.many", "array.numeric", ["DIM a(2)", "DIM b(2)", "DIM c(2)", "DIM d(2)", "DIM e(2)", "a(1)=1:b(1)=2:c(1)=3:d(1)=4:e(1)=5",
                                 "PRINT a(1)+b(1)+c(1)+d(1)+e(1)"], Num(15, "int"))
T("arr.str_basic", "array.string", ['DIM n$(3)', 'n$(0) = "RED"', 'n$(2) = UPPER$("blue")', "PRINT n$(0) + n$(2)"], Out("REDBLUE"))
T("arr.str_default_width", "array.string", ['DIM n$(2)', 'n$(0) = "' + "w" * 20 + '"', "PRINT LEN(n$(0))"], Num(20, "int"),
  note="manual: each element can hold 31 characters (implementation default width 16 -> 15)")
T("arr.str_width", "array.string", ['DIM n$(2,5)', 'n$(1) = "abcdefgh"', "PRINT n$(1)"], Out("abcd"))
T("arr.str_width_big", "array.string", ['DIM n$(2,32)', 'n$(1) = "' + "z" * 31 + '"', "PRINT LEN(n$(1))"], Num(31, "int"))
T("arr.str_width1", "array.string", ['DIM n$(2,1)'], CErr(34))
T("arr.str_width_200", "array.string", ['DIM n$(2,200)', 'n$(0) = "ok"', "PRINT n$(0)"], OkOrErr("ok"))
T("arr.str_oob", "array.string.bounds", ['DIM n$(2)', 'n$(2) = "x"'], RErr(10))
T("arr.str_oob_neg", "array.string.bounds", ['DIM n$(2)', 'n$(-1) = "x"'], RErr(10))
T("arr.str_empty_elem", "array.string", ['DIM n$(2)', "PRINT LEN(n$(1))"], Num(0, "int"))
T("arr.in_proc", "array.numeric", ["DIM a(3)", "CALL p(2)", "PRINT a(2)", "END", "PROC p(i):", "a(i) = i * 11", "ENDP"], Num(22, "int"))
T("arr.in_fn", "array.numeric", ["DIM a(3)", "a(1) = 8", "DEF FN g(i) = a(i) * 2", "PRINT FN g(1)"], Num(16, "int"))
T("arr.loop_fill", "array.numeric", ["DIM a(20)", "FOR i = 0 TO 19", "a(i) = i * i", "NEXT i", "s = 0", "FOR i = 0 TO 19", "s = s + a(i)", "NEXT i",
                                      "PRINT s"], Num(sum(i * i for i in range(20)), "int"))

# =====================================================================================
# 12. INPUT (keys through the ISR latch)
# =====================================================================================
def K(s, enter=True):
    return [ord(c) for c in s] + ([13] if enter else [])


T("input.num", "stmt.INPUT", ["INPUT a", "PRINT a * 2"], Lines("21", I(42)), keys=K("21"))
T("input.neg", "stmt.INPUT", ["INPUT a", "PRINT a"], Lines("-5", I(-5)), keys=K("-5"))
T("input.str", "stmt.INPUT", ["INPUT a$", 'PRINT a$ + "!"'], Out("hi there\nhi there!"), keys=K("hi there"))
T("input.empty_num", "stmt.INPUT", ["INPUT a", "PRINT a + 1"], Out("\n1"), keys=[13])
T("input.big", "stmt.INPUT.range", ["INPUT a", "PRINT a"], Pred(lambda r: (r.ce == 0 and r.ve == 0 and r.text.split("\n")[-1] in ("99999", "99999.0000"),
                                                                              "out=%r" % r.text), "99999 kept or an error"),
  keys=K("99999"), note="5 digits above 32767")
T("input.decimal", "stmt.INPUT.decimal", ["INPUT a", "PRINT a * 2"], Pred(lambda r: (r.ce == 0 and r.text.split("\n")[-1] == "3.0000",
                                                                                    "out=%r" % r.text), "1.5 doubled = 3.0000"),
  keys=K("1.5"), note="decimal input")
T("input.prompt", "stmt.INPUT.prompt", ['INPUT "N? "; n', "PRINT n + 1"], per(b=CErr(), x=Out("N? 4\n5")), keys=K("4"))
T("input.prompt_comma", "stmt.INPUT.prompt", ['INPUT "V", v$', "PRINT v$"], per(b=CErr(), x=Out("Vab\nab")), keys=K("ab"))
T("input.array", "stmt.INPUT", ["DIM a(2)", "INPUT a(1)"], CErr(), note="INPUT into an array element unsupported")
T("input.two", "stmt.INPUT", ["INPUT a", "INPUT b", "PRINT a + b"], Lines("3", "4", I(7)), keys=K("3") + K("4"))

# =====================================================================================
# 13. Hardware-facing statements (emulator-observable part only)
# =====================================================================================
T("hw.beep", "stmt.BEEP", ["BEEP 1,0", 'PRINT "b"'], Out("b"))
T("hw.sound", "stmt.SOUND", ["SOUND 8,15", "SOUND 8,0", 'PRINT "s"'], Out("s"))
T("hw.sound_badreg", "stmt.SOUND", ["SOUND 20,1"], RErr(8))
T("hw.pause", "stmt.PAUSE", ["PAUSE 2", 'PRINT "p"'], Out("p"))
T("hw.pause0", "stmt.PAUSE", ["PAUSE 0", 'PRINT "k"'], Out("k"), keys=[ord("x")], note="PAUSE 0 waits for a key")
T("hw.randomise", "stmt.RANDOMISE", ["RANDOMISE 1", "RANDOMISE 0", 'PRINT "r"'], Out("r"))
T("hw.randomize", "stmt.RANDOMISE", ["RANDOMIZE 1"], CErr(), note="spelled RANDOMISE")
T("hw.out_ay", "stmt.OUT", ["OUT 245,7", "OUT 246,62", "OUT 245,7", "PRINT IN(246)"], Num(62, "int"), only=NEW,
  note="AY register 7 round trip through the 16-bit port path")
T("hw.out_args", "stmt.OUT", ["OUT 1"], CErr(22), only=NEW)
T("hw.in_noarg", "fn.IN", ["PRINT IN()"], CErr(), only=NEW)
T("hw.in_kbd", "fn.IN", ["PRINT IN(65278) > 0"], Num(1, "int"), only=NEW)
T("hw.stick_idle", "fn.STICK", ["PRINT STICK(1) + STICK(2)"], Num(0, "int"), only=NEW)
T("hw.stick_bad", "fn.STICK", ["PRINT STICK(5)"], AnyErr(), only=NEW, note="manual: INVALID ARGUMENT for STICK")
T("hw.out_baseline", "stmt.OUT", ["OUT 245,7"], CErr(), only=OLD, note="baseline has no OUT (package V1 only)")
T("hw.in_baseline", "fn.IN", ["PRINT IN(254)"], CErr(), only=OLD)
T("hw.out_reserved", "identifier.reserved", ["out = 1"], CErr(), only=NEW, note="core OUT reserves the word")
T("hw.in_reserved", "identifier.reserved", ["in = 1", "PRINT in"], CErr(), only=NEW)

# =====================================================================================
# 14. CLEAR, END/STOP, repeated execution, immediate statements
# =====================================================================================
T("clear.vars", "stmt.CLEAR", ["x = 5", 'a$ = "q"', "CLEAR", "PRINT x", "PRINT LEN(a$)"], Out("0\n0"))
T("clear.arrays", "stmt.CLEAR", ["DIM a(3)", "a(1) = 5", "CLEAR", "DIM a(3)", "PRINT a(1)"], OkOrErr("0"),
  note="after CLEAR a non-stored array is gone; re-DIM gives zeros")
T("clear.loop", "stmt.CLEAR", ["FOR i = 1 TO 3", "CLEAR", "NEXT i", 'PRINT "x"'], OkOrErr("x"), note="CLEAR inside a FOR loop", maxi=8_000_000)
T("stmt.label_only_program", "program", ["start:"], Out(""))
T("stmt.empty_program", "program", [], Out(""))
T("stmt.blank_lines", "program", ["", 'PRINT "a"', "", "", 'PRINT "b"', ""], Out("a\nb"))
T("stmt.indent", "program", ['   PRINT "a"', '      PRINT "b"'], Out("a\nb"))
T("stmt.long_line", "program", ["x = " + "+".join(["1"] * 40), "PRINT x"], Num(40, "int"))
T("stmt.many_lines", "program", ["s = 0"] + ["s = s + %d" % k for k in range(1, 151)] + ["PRINT s"], Num(sum(range(1, 151)), "int"),
  note="150 lines through the chunked source window")
T("stmt.many_vars", "variable.capacity", ["v%d = %d" % (k, k) for k in range(60)] + ["PRINT v59 + v0 + v30"], Num(89, "int"))

# =====================================================================================
# 15. Compile-error position and message classes
# =====================================================================================
T("err.line0", "compile.errorline", ["x = (1", 'PRINT "a"'], CErr(66, line=0))
T("err.line3", "compile.errorline", ["a = 1", "b = 2", "c = 3", "d = 4 4", "e = 5"], CErr(64, line=3))
T("err.eof_for", "compile.errorline", ["a = 1", "FOR i = 1 TO 3", "b = 2"], per(b=CErr(65, line=3), x=CErr(65, line=1)),
  note="end-of-source FOR: append line (Phase 2D) / FOR line (N-3, Enhanced)")
T("err.eof_proc", "compile.errorline", ["a = 1", "PROC p(x):", "b = 2"], CErr(16, line=3))
T("err.eof_if", "compile.errorline", ["a = 1", "IF a THEN", "b = 2"], CErr(9, line=3))
T("err.undef_label_line", "compile.errorline", ["a = 1", "GOTO nope", "b = 2"], CErr(7))
T("rt.err_msg", "runtime.error", ["x = 1/0"], Pred(lambda r: (r.ve == 5 and r.msg is not None, "msg=%s" % r.msg), "a message is shown"))


# =====================================================================================
# 16. Memory-safety probes (post-run RAM inspection through the harness)
# =====================================================================================
def _arr_desc(m, idx=0):
    tbl = m.w16(m.sym("RT_ARRPTR_PTR"))
    return m.w16(tbl + 2 * idx)


def _arr_words(m, idx=0, n=6):
    d = _arr_desc(m, idx)
    if not d:
        return None, None
    raw = m.read(d, 3 + 2 * n)
    return raw[1] | raw[2] << 8, [raw[3 + 2 * k] | raw[4 + 2 * k] << 8 for k in range(n)]


def _post_arr_intact(want_count, want_vals):
    def f(m, r):
        cnt, vals = _arr_words(m, 0, len(want_vals))
        ok = cnt == want_count and vals == want_vals
        return ok, "descriptor count=%s elements=%s (want %s %s)" % (cnt, vals, want_count, want_vals)
    return f


T("mem.oob_write_end", "array.bounds.memsafety", ["DIM a(5)", "a(0) = 7", "a(5) = 99"], RErr(10),
  post=_post_arr_intact(5, [7, 0, 0, 0, 0]), note="the failing store must not write anywhere")
T("mem.oob_write_end2", "array.bounds.memsafety", ["DIM a(5)", "a(2) = 7", "a(7) = 99"], RErr(10),
  post=_post_arr_intact(5, [0, 0, 7, 0, 0]))
T("mem.oob_write_neg", "array.bounds.memsafety", ["DIM a(5)", "a(1) = 3", "a(-1) = 2"], RErr(10),
  post=_post_arr_intact(5, [0, 3, 0, 0, 0]), note="a(-1) must not overwrite the descriptor's count")
T("mem.float_store", "array.type.memsafety", ["x = 1 : y = 2 : z = 3", "DIM a(3)", "a(1) = 2.5"], OkOrErr(""),
  post=lambda m, r: ((r.ve == 0) or _arr_words(m, 0, 3)[1] == [0, 0, 0],
                     "elements=%s ve=%s" % (_arr_words(m, 0, 3)[1], r.ve)),
  note="if the store is rejected, the element must be unchanged")


def _post_strarr(want):
    def f(m, r):
        tbl = m.w16(m.sym("RT_STRARRPTR_PTR"))
        d = m.w16(tbl)
        if not d:
            return False, "no descriptor"
        raw = m.read(d, 4)
        cnt, width = raw[1] | raw[2] << 8, raw[3]
        data = m.read(d + 4, cnt * width)
        els = [data[k * width + 1: k * width + 1 + data[k * width]].decode("latin-1") for k in range(cnt)]
        nxt = m.read(d + 4 + cnt * width, 8)
        return els == want, "count=%d width=%d elements=%s next=%s (want %s)" % (cnt, width, els, nxt.hex(), want)
    return f


T("mem.strarr_oob_end", "array.string.memsafety", ['DIM n$(2,4)', 'n$(0) = "ab"', 'n$(2) = "XYZ"'], RErr(10),
  post=_post_strarr(["ab", ""]))
T("mem.strarr_oob_neg", "array.string.memsafety", ['DIM n$(2,4)', 'n$(1) = "cd"', 'n$(-1) = "XYZ"'], RErr(10),
  post=_post_strarr(["", "cd"]))
T("mem.oob_neg_big", "array.bounds.memsafety", ["DIM a(3)", "DIM b(3)", "b(0) = 5", "a(-1) = 30000"], RErr(10),
  post=lambda m, r: (lambda c: (c[0] == 3, "a count=%s (a(-1)=30000 must not resize a)" % c[0]))(_arr_words(m, 0, 1)))


# =====================================================================================
# 17. Follow-up probes for defects found in the first full run
# =====================================================================================
for k, (a, b, eq) in enumerate((("abc", "xyz", 0), ("abc", "abc", 1), ("y", "n", 0), ("ab", "abc", 0), ("", "", 1), ("A", "a", 0))):
    T("strcmp.eq.%d" % k, "string.compare", ['a$ = "%s"' % a, 'IF a$ = "%s" THEN' % b, 'PRINT "T"', "ELSE", 'PRINT "F"', "ENDIF"], Out("T" if eq else "F"))
for k, (a, b) in enumerate((("abc", "abd"), ("abd", "abc"), ("b", "a"), ("a", "b"), ("zz", "aaa"), ("aaa", "zz"), ("ab", "abc"), ("abc", "ab"))):
    T("strcmp.lt.%d" % k, "string.compare", ['a$ = "%s"' % a, 'b$ = "%s"' % b, "IF a$ < b$ THEN", 'PRINT "T"', "ELSE", 'PRINT "F"', "ENDIF"],
      Out("T" if a < b else "F"))
T("strcmp.inkey_idiom", "string.compare", ['k$ = "n"', 'IF k$ = "y" THEN', 'PRINT "quit"', "ELSE", 'PRINT "stay"', "ENDIF"], Out("stay"))


def _post_store_intact(m, r):
    pe = m.w16(m.sym("PROG_END"))
    return pe > m.sym("PROG_AREA_START"), "PROG_END=%04X (program store %s)" % (pe, "kept" if pe > m.sym("PROG_AREA_START") else "EMPTIED")


T("crash.and_float", "expr.logical.float", ["x = 0.5", "IF x AND 1 THEN", 'PRINT "y"', "ENDIF"], AnyErr(), post=_post_store_intact,
  note="AND with a float operand: an error is acceptable, a reset is not")
T("crash.or_float", "expr.logical.float", ["IF 0.5 OR 0 THEN", 'PRINT "y"', "ENDIF"], AnyErr(), post=_post_store_intact)
T("crash.and_float_rhs", "expr.logical.float", ["PRINT 1 AND 2.5"], AnyErr(), post=_post_store_intact)
T("crash.not_float", "expr.logical.float", ["PRINT NOT 2.5"], AnyErr(), post=_post_store_intact)
for n in (8000, 16000, 16500, 20000, 32767):
    T("dim.big.%d" % n, "array.dim.capacity", ["DIM a(%d)" % n, "a(%d) = 7" % (n - 1), "PRINT a(%d)" % (n - 1)], OkOrErr("7"),
      post=_post_store_intact, maxi=20_000_000, note="large DIM: OUT OF MEMORY or success, never corruption")
for n, w in ((1000, 32), (3000, 32), (2100, 32), (300, 255)):
    T("dim.bigstr.%dx%d" % (n, w), "array.dim.capacity", ["DIM s$(%d,%d)" % (n, w), 's$(%d) = "end"' % (n - 1), "PRINT s$(%d)" % (n - 1)], OkOrErr("end"),
      post=_post_store_intact, maxi=20_000_000, note="count*width product: overflow must not under-allocate")
T("fn.sqr.1000", "fn.SQR", ["PRINT SQR(1000)"], Num(Fr(316227766, 10000000), "float"))
T("fn.sqr.30000", "fn.SQR", ["PRINT SQR(30000)"], Num(Fr(1732050808, 10000000), "float"))
T("fn.sqr.99", "fn.SQR", ["PRINT SQR(99)"], Num(Fr(99498744, 10000000), "float"))
T("print.font_brackets", "display.font", ["PRINT CHR$(91) + CHR$(93) + CHR$(124)"],
  Pred(lambda r: (r.ce == 0 and r.text.strip() != "", "out=%r" % r.text), "[ ] | have visible glyphs"))
