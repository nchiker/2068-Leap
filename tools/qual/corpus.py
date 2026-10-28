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
T("lit.float.too_big", "literal.range", ["PRINT 1" + "0" * 40], CErr(64), note="RC: beyond the float range (about 1.7E38)")
T("lit.float.1e38", "literal.range", ["PRINT 1" + "0" * 38 + " / 1" + "0" * 37], Num(10))
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
# RC: results beyond the 5-byte float range (about 1.7E38) are runtime error 67; they used to leave an
# operand behind as the result (4294967296^4 printed 2^96).
T("arith.overflow.mul", "expr.overflow", ["a = 4294967296", "PRINT a * a * a * a"], RErr(67))
T("arith.overflow.add", "expr.overflow", ["a = 4294967296", "b = a * a * a * (a / 4)", "PRINT b + b"], RErr(67))
T("arith.overflow.sub", "expr.overflow", ["a = 4294967296", "b = a * a * a * (a / 4)", "PRINT 0 - b - b"], RErr(67))
T("arith.overflow.div", "expr.overflow", ["a = 4294967296", "b = a * a * a * (a / 4)", "PRINT b / 0.5"], RErr(67))
T("arith.big.ok", "expr.overflow", ["a = 4294967296", "b = a * a * a * (a / 4)", "PRINT b / b"], Num(1))
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
T("fn.div.min_m1", "fn.DIV", ["PRINT DIV(-32767-1,-1)"], Num(32768), known=D11X,
  note="cost study: still wraps in both variants. RC oracle correction: 32768 is not an INT, so its correct display is 32768.0000 (was OkOrErr('32768'))")
T("fn.int.big", "fn.INT", ["PRINT INT(30000*3+0.5)"], Num(90000), known=D11X)
T("fn.int.neg_trunc", "fn.INT", ["PRINT INT(-3.5)"], Num(-3, "int"),
  note="V2 design (R10.8 L6): INT truncates toward zero; stock Sinclair BASIC floors (-4)")
T("fn.mod.neg_trunc", "fn.MOD", ["PRINT MOD(-7,3)"], Num(-1, "int"), note="V2 design (R10.8 L6): truncated division")
T("fn.div.neg_trunc", "fn.DIV", ["PRINT DIV(-7,2)"], Num(-3, "int"), note="V2 design (R10.8 L6): truncated division")
T("fn.mod.zero", "fn.MOD", ["PRINT MOD(5,0)"], RErr(5), note="manual: DIVISION BY ZERO for /, MOD, DIV")
T("fn.div.zero", "fn.DIV", ["PRINT DIV(5,0)"], RErr(5))
T("fn.sqr.neg", "fn.SQR", ["PRINT SQR(-4)"], AnyErr(), note="square root of a negative number")
T("fn.tan.90", "fn.TAN", ["PRINT TAN(90)"], RErr(5))
T("fn.cos.int_big", "fn.COS", ["PRINT COS(32687)"], Num(Fr(29237170, 10 ** 8), "float"),
  note="cos 287 degrees; 5.10 (Q-35): the 90 of COS(x) = SIN(x + 90) was added before the reduction, in 16 bits")
T("fn.cos.float_big", "fn.COS", ["PRINT COS(32767.9)"], Num(Fr(99050946, 10 ** 8), "float"), note="cos 7.9 degrees (Q-35)")
T("fn.tan.float_big", "fn.TAN", ["PRINT TAN(32700.5)"], Num(Fr(-169766312, 10 ** 8), "float"), note="tan 300.5 degrees (Q-35)")
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
T("str.instr", "fn.INSTR", ['PRINT INSTR("hello","ll")'], CErr(),
  note="V2 decision (RC, L-INSTR): INSTR is not in the V2 ROM (no room; the V1 manual entry is withdrawn); search with MID$ in a loop")
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
T("if.elseif_kw", "stmt.IF.elseif", ["x = 2", "IF x = 1 THEN", 'PRINT "one"', "ELSEIF x = 2 THEN", 'PRINT "two"', "ENDIF"], CErr(),
  note="V2 decision (RC, L-ELIF): no ELSEIF keyword (the V1 manual entry is withdrawn); ELSE + a nested IF does the same")
T("if.else_if_nested", "stmt.IF.elseif", ["x = 2", "IF x = 1 THEN", 'PRINT "one"', "ELSE", "IF x = 2 THEN", 'PRINT "two"', "ENDIF",
  "ENDIF"], Out("two"), note="the V2 spelling of ELSEIF")
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
  note="jumping into a FOR body: NEXT without an active loop", maxi=12_000_000)
T("for.next_in_if", "stmt.FOR.structure", ["c = 0", "IF c THEN", "FOR i = 1 TO 3", "ENDIF", "NEXT i", 'PRINT "x"'], AnyErr(),
  note="FOR opened inside an IF block, NEXT outside it (structure crossing)", maxi=12_000_000)
T("for.var_modified", "stmt.FOR", ["n = 0", "FOR i = 1 TO 10", "i = i + 1", "n = n + 1", "NEXT i", "PRINT n"], Num(5, "int"))
T("for.var_float_body", "stmt.FOR.float", ["n = 0", "FOR i = 1 TO 4", "i = i + 0.5", "n = n + 1", "NEXT i", "PRINT n"], OkOrErr("3"),
  note="the body makes the loop variable a float", maxi=12_000_000)
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
T("arr.str_default_width", "array.string", ['DIM n$(2)', 'n$(0) = "' + "w" * 20 + '"', "PRINT LEN(n$(0))"], Num(15, "int"),
  note="V2 design (R10.7 s11.1): DIM n$(n) elements are 16 bytes, 15 characters; DIM n$(n,32) holds 31. "
       "DD-1 was the manual's error (corrected), not the ROM's")
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


T("crash.and_float", "expr.logical.float", ["x = 0.5", "IF x AND 1 THEN", 'PRINT "y"', "ENDIF"], Lines("y"), post=_post_store_intact,
  note="AND with a float operand: nonzero is true (V2_LANGUAGE_REFERENCE); never a reset")
T("crash.or_float", "expr.logical.float", ["IF 0.5 OR 0 THEN", 'PRINT "y"', "ENDIF"], Lines("y"), post=_post_store_intact)
T("crash.and_float_rhs", "expr.logical.float", ["PRINT 1 AND 2.5"], Num(1, "int"), post=_post_store_intact)
T("crash.not_float", "expr.logical.float", ["PRINT NOT 2.5"], Num(0, "int"), post=_post_store_intact)
# RC (2026-10-11): the four crash.* logical cases above accepted only "an error" -- the safe outcome
# while a FLOAT operand of AND/OR crashed the machine (Q-03) and V2 had no rule for a FLOAT truth
# value. The V2 rule is now specified (any nonzero number is true; AND/OR/NOT give 0/1), so each case
# expects exactly that value, with the program kept; an error or a wrong value fails.
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

# =====================================================================================
# 18. FOR frames after GOTO out of an inner loop; packages
# =====================================================================================
T("for.goto_out_inner", "stmt.FOR.goto", ["c = 0", "FOR i = 1 TO 3", "FOR j = 1 TO 10", "IF j = 2 THEN GOTO nexti", "NEXT j", "nexti:",
                                          "c = c + 1", "NEXT i", "PRINT c"], Num(3, "int"),
  note="the outer NEXT must use its own limit/step, not the abandoned inner loop's")
T("for.goto_out_inner_step", "stmt.FOR.goto", ["c = 0", "FOR i = 1 TO 3", "FOR j = 1 TO 10 STEP 5", "IF j > 0 THEN GOTO nexti", "NEXT j", "nexti:",
                                               "c = c + 1", "NEXT i", "PRINT c"], Num(3, "int"))
T("for.exit_inner_ok", "stmt.EXIT", ["c = 0", "FOR i = 1 TO 3", "FOR j = 1 TO 10", "IF j = 2 THEN", "EXIT FOR", "ENDIF", "NEXT j", "c = c + 1",
                                      "NEXT i", "PRINT c"], Num(3, "int"))
T("for.goto_loop_many", "stmt.FOR.goto", ["n = 0", "again:", "FOR i = 1 TO 10", "IF i = 2 THEN GOTO quit", "NEXT i", "quit:", "n = n + 1",
                                          "IF n < 1500 THEN GOTO again", "PRINT n"], OkOrErr("1500"), maxi=60_000_000,
  note="1500 abandoned FOR frames: must not corrupt anything (an error is acceptable)")

T("pkg.unloaded", "pkg.unloaded", ["CIRCLE 100,100,20"], CErr(2))
T("pkg.unloaded_mode", "pkg.unloaded", ["MODE 1"], CErr(2))
T("pkg.shapes.circle", "pkg.SHAPES", ["CIRCLE 128,96,40", "p = POINT(168,96) + POINT(128,56) + POINT(128,96)", "CLS", "PRINT p"], Num(2, "int"),
  packages=("shapes",), note="two points on the circle, the centre stays clear")
T("pkg.shapes.fill", "pkg.SHAPES", ["CIRCLE 128,96,20", "FILL 128,96", "p = POINT(128,96) + POINT(130,98)", "CLS", "PRINT p"], Num(2, "int"),
  packages=("shapes",), maxi=60_000_000)
T("pkg.shapes.argc", "pkg.SHAPES", ["CIRCLE 1,2"], CErr(28), packages=("shapes",))
T("pkg.mode.toggle", "pkg.MODE", ["MODE 1", "MODE 0", 'PRINT "m"'], Out("m"), packages=("mode",))
T("pkg.mode.bad", "pkg.MODE", ["MODE 5"], RErr(), packages=("mode",), note="INVALID MODE")
T("pkg.mode.palette", "pkg.MODE", ["ULAPLUS 1", "PALETTE 0,255", "ULAPLUS 0", 'PRINT "u"'], Out("u"), packages=("mode",))
T("pkg.sprite.cycle", "pkg.SPRITE", ["PLOT 4,4", "GRAB 0,0,0,1,1", "SHOW 0,5,5", "MOVE 0,6,6", "HIDE 0", 'PRINT "s"'], Out("s"), packages=("sprite",))
T("pkg.sprite.badslot", "pkg.SPRITE", ["HIDE 9"], RErr(), packages=("sprite",))
T("pkg.graphics.all", "pkg.GRAPHICS", ["CPLOT 2,2", "BLOCK 1,1,2,2", "FRAME 3,3,4,4", "INVERT 0,0,2,2", 'PRINT "g"'], Terminates(), packages=("graphics",))
T("pkg.printer.lprint", "pkg.PRINTER", ['LPRINT "hello"', "LPRINT 42", 'PRINT "p"'], Out("p"), packages=("printer",),
  note="printer output itself needs hardware; the statements must run")
T("pkg.printer.unloaded", "pkg.PRINTER", ['LPRINT "x"'], CErr(32))

# =====================================================================================
# Defects first found by this study (Q-*), assigned after investigation of the first full runs.
# Strict accounting: the case reports XFAIL while the defect reproduces, XPASS once fixed.
# A run on a fix branch passes --fixed Q-..,.. so those markers are dropped (PASS/FAIL then
# shows whether the fix holds).
# =====================================================================================
KNOWN_Q = {
    "Q-01": ["str.cmp_case", "str.cmp_lt"] + ["strcmp.eq.%d" % k for k in (0, 2, 5)] + ["strcmp.lt.%d" % k for k in (0, 3, 4, 5)] + ["strcmp.inkey_idiom"],
    "Q-02": ["arith.f.prec", "arith.f.temps2", "arith.f.temps3", "arith.f.temps4", "arith.f.temps7", "arith.f.temps8",
             "str.temps.assign", "str.temps.fn2", "str.temps.fn_fn_fn", "str.temps.fn_lit_fn", "str.temps.lit_fn",
             "str.temps.lit_fn_lit", "str.temps.nested"],
    "Q-03": ["crash.and_float", "crash.and_float_rhs", "crash.or_float", "log.float"],
    "Q-04": ["arr.dim_huge", "dim.big.8000", "dim.big.16000", "dim.big.16500", "dim.big.20000", "dim.big.32767",
             "dim.bigstr.1000x32", "dim.bigstr.3000x32", "dim.bigstr.300x255"],
    "Q-05": ["lit.int.neg32768"],
    "Q-06": ["if.float_cond", "if.float_lit_cond"],
    "Q-07": ["for.zero_trip", "for.zero_trip_neg"],
    "Q-08": ["for.float_limit", "for.float_start", "for.float_step", "for.float_var_limit", "for.var_float_body"],
    "Q-09": ["lit.dec.0p00001", "lit.dec.0p000001", "lit.dec.16zeros"],
    "Q-10": ["fn.deg.pi", "fn.rad.f", "fn.sgn.f_small", "fn.sgn.f_neg_small", "fn.sin.f", "fn.sqr.f", "fn.sqr.f2", "fn.mod.float"],
    "Q-11": ["proc.nested_def", "proc.deffn_inside"],
    "Q-12": ["label.dup"],
    "Q-13": ["fn.mod.zero", "fn.div.zero"],
    "Q-14": ["print.cls"],
    "Q-15": ["input.decimal"],
    "Q-16": ["input.big"],
    "Q-17": ["str.val_stop", "str.val_big"],
    "Q-18": ["mem.oob_write_end", "mem.oob_write_end2", "mem.oob_write_neg", "mem.oob_neg_big", "mem.float_store",
             "mem.strarr_oob_end", "mem.strarr_oob_neg"],
    "Q-19": ["for.goto_into", "for.next_in_if"],
    "Q-20": ["for.goto_out_inner", "for.goto_out_inner_step"],
    "Q-21": ["clear.loop"],
    "Q-22": ["fn.sqr.neg"],
    "Q-23": ["hw.stick_bad"],
    "Q-24": ["proc.goto_label"],
    "Q-25": ["str.cmp_and"],
    "Q-26": ["print.font_brackets"],
    "DD-1": ["arr.str_default_width"],
    "DEC-PLOT": ["gfx.plot_clamp"],
    "Q-35": ["fn.cos.int_big", "fn.cos.float_big", "fn.tan.float_big"],
}
_case = {c.cid: c for c in CASES}
for qid, ids in KNOWN_Q.items():
    for cid in ids:
        c = _case[cid]
        for cfg in c.only:
            c.known.setdefault(cfg, qid)
# baseline-only D11 FOR counter wrap (cost study B.4 "FOR counter wraps")
for cid in ("for.step_big", "for.to_m32768"):
    _case[cid].known.setdefault("baseline", "D11")
# oracle correction: SQR(32767) = 181.01657..., the printed 181.0165 is D10 truncation (auto-classified)
_case["fn.sqr.32767"].expect = {c: Num(Fr(1810166, 10000), "float") for c in CFGS}
# L-A (documented): an over-precise decimal literal may be rejected with error 64; a wrong value is Q-09
for cid in KNOWN_Q["Q-09"]:
    _case[cid].expect = {c: Pred(lambda r: ((r.ce == 64) or (r.ce == 0 and r.ve == 0 and r.text in ("1.0000", "1")),
                                            "ce=%s out=%r" % (r.ce, r.text)), "1.0000, or error 64 (L-A)") for c in CFGS}

# =====================================================================================
# 19. String record terminators (found while fixing Q-02)
# =====================================================================================
T("strrec.stale_tail", "string.record", ['a$ = "abcdefgh"', 'PRINT LEFT$("q",1)'], Out("q"),
  note="a string function result must not show the tail of an earlier string")
T("strrec.stale_tail_var", "string.record", ['x$ = "zzzzzzzz"', 'y$ = "w"', 'b$ = LEFT$(y$,1)', "PRINT b$"], Out("w"),
  note="the stale tail is copied into b$ by the 32-byte assignment")
T("strrec.31_vs_array", "string.record.memsafety", ["DIM a(3)", "a(0) = 7", 's$ = "x"', 't$ = "' + "A" * 31 + '"', "PRINT a(0)"], Num(7, "int"),
  note="a 31-character literal must not touch the array pointer table")
T("strrec.31_vs_array_write", "string.record.memsafety", ["DIM a(3)", "DIM b(3)", "b(0) = 5", 's$ = "x"', 't$ = "' + "A" * 31 + '"',
                                                          "a(0) = 9", "PRINT b(0)"], Num(5, "int"),
  note="after the pointer corruption a write to a() lands elsewhere")
T("strrec.31_concat", "string.record.memsafety", ["DIM a(3)", "a(0) = 7", 's$ = "x"', 't$ = "A" + "' + "B" * 30 + '"', "PRINT a(0)"], Num(7, "int"))
KNOWN_Q2 = {"Q-27": ["strrec.stale_tail", "strrec.stale_tail_var"], "Q-28": ["strrec.31_vs_array", "strrec.31_concat"],
            "Q-29": ["pkg.sprite.cycle", "pkg.sprite.move_restore"]}
# Q-05 is an edge of the L-A literal rule: Essential/Enhanced only (Baseline's wrap happens to print -32768)
[c for c in CASES if c.cid == "lit.int.neg32768"][0].known.pop("baseline", None)
T("pkg.sprite.move_restore", "pkg.SPRITE", ["PLOT 4,4", "GRAB 0,0,0,1,1", "SHOW 0,5,5", "MOVE 0,6,6",
                                            "p = POINT(44,44) * 100 + POINT(52,52) * 10 + POINT(4,4)", "CLS", "PRINT p"], Num(11, "int"),
  packages=("sprite",), note="MOVE must restore the old position (44,44 clear), draw the new one (52,52 set), leave the source (4,4)")
for qid, ids in KNOWN_Q2.items():
    for cid in ids:
        _c = [c for c in CASES if c.cid == cid][0]
        for cfg in _c.only:
            _c.known.setdefault(cfg, qid)

# =====================================================================================
# 20. Intentionally unsupported / absent keywords must be rejected (not silently ignored)
# =====================================================================================
for cid, line in (("gosub", "GOSUB x"), ("return", "RETURN"), ("data", "DATA 1,2"), ("read", "READ a"), ("let", "LET a = 1"),
                  ("merge", 'MERGE "x"'), ("pow", "x = 2 ^ 3"), ("infixmod", "x = 7 MOD 2"), ("hit", "x = HIT(1,2)"),
                  ("atn", "x = ATN(1)"), ("exp", "x = EXP(1)"), ("screen", 'a$ = SCREEN$(1,1)'), ("draw", "DRAW 10,10"),
                  ("randomize", "RANDOMIZE 3"), ("elseif", "IF 1 THEN : ELSEIF 2 THEN : ENDIF")):
    T("ns." + cid, "ns.keywords", [line], CErr(), note="absent or intentionally unsupported: must be a compile error")

# =====================================================================================
# 21. Remaining tag-check suspicions from the code review (VM_POP without coercion)
# =====================================================================================
T("tag.pause_float", "stmt.PAUSE", ["x = 1", "PAUSE 1/2", 'PRINT "x"'],
  Pred(lambda r: ((r.ce == 0 and r.ve == 0 and ((r.status == "OK" and r.text == "x") or (r.status == "WAIT" and r.text == ""))) or (r.ce or r.ve),
                  "ce=%s ve=%s st=%s out=%r" % (r.ce, r.ve, r.status, r.text)), "out='x', or a key wait (PAUSE 0 after truncation), or an error"),
  maxi=8_000_000,
  note="oracle correction: under the documented truncation of FLOAT arguments 1/2 is 0, and PAUSE 0 waits for a key")
T("tag.chr_float", "fn.CHR", ["PRINT CHR$(65.6) + CHR$(130/2)"], OkOrErr("AA"),
  note="CHR$ pops without coercion (65.6 -> slot index); 130/2 is an exact INT 65")
T("tag.mid_bigstart", "fn.MID", ['PRINT "<" + MID$("hello",257,1) + ">"'], Out("<>"), note="start uses the low byte only")
T("tag.border_float", "stmt.BORDER", ["BORDER 2.5", 'PRINT "b"'], OkOrErr("b"))
T("tag.pause_float0", "stmt.PAUSE", ["PAUSE 0.5", 'PRINT "p"'],
  Pred(lambda r: ((r.ce == 0 and r.ve == 0 and ((r.status == "OK" and r.text == "p") or (r.status == "WAIT" and r.text == ""))) or (r.ce or r.ve),
                  "ce=%s ve=%s st=%s out=%r" % (r.ce, r.ve, r.status, r.text)), "out='p', or a key wait (PAUSE 0 after truncation), or an error"),
  maxi=8_000_000, note="truncation makes PAUSE 0.5 = PAUSE 0 (the slot-index defect gives the same result here; see tag.pause_frames)")
T("tag.pause_frames", "stmt.PAUSE", ["y = 2.5", "t = PEEK(33141)", "PAUSE 20.5", "d = PEEK(33141) - t", "IF d < 0 THEN", "d = d + 256", "ENDIF", "PRINT d"],
  Pred(lambda r: (r.ce == 0 and r.ve == 0 and r.status == "OK" and r.text.strip().lstrip("-").isdigit() and 19 <= int(r.text) <= 23,
                  "ce=%s ve=%s st=%s out=%r" % (r.ce, r.ve, r.status, r.text)), "about 20 frames elapse (FRAMES low byte at $8175)"),
  maxi=12_000_000, note="PAUSE 20.5 must pause ~20 frames, not its FLOAT slot index")
T("tag.left_float", "fn.LEFT", ['n = 5 / 2', 'a$ = LEFT$("hello", n)', 'PRINT "<" + a$ + ">"'], Out("<he>"),
  note="LEFT$(s$, LEN(s$)/2) idiom: a FLOAT count is truncated like every other integer argument")
T("tag.mid_bigstart_var", "fn.MID", ['a$ = MID$("hello",257,1)', 'PRINT "<" + a$ + ">"'], Out("<>"),
  note="as tag.mid_bigstart without the Q-02 temporaries (start 257 must not mean 1)")
# Q-30: CHR$ and PAUSE pop a FLOAT without coercion (its slot index is used); Q-31: MID$ start uses its low byte.
# ns.return in the baseline is the documented bare-word acceptance N-2 (RETURN is not a keyword there).
for _cid, _q in (("tag.chr_float", "Q-30"), ("tag.pause_frames", "Q-30"), ("tag.left_float", "Q-30"), ("tag.mid_bigstart", "Q-31"), ("tag.mid_bigstart_var", "Q-31")):
    _c = [c for c in CASES if c.cid == _cid][0]
    for cfg in _c.only:
        _c.known.setdefault(cfg, _q)
[c for c in CASES if c.cid == "ns.return"][0].known.setdefault("baseline", "N-2")

# =====================================================================================
# 22. Floating-point FOR (owner decision 1, 2026-10-11). Documented behaviour to implement:
# FOR stores the start like an assignment; NEXT adds the step with the VM's own ADD rules (INT + INT
# stays INT, promoting on overflow; any FLOAT gives FLOAT) and compares with the limit like the
# relational operators; the loop ends when the variable is past the limit in the step's direction;
# STEP 0 counts as ascending (manual: an intentional infinite loop). Expected values are exact.
# These cases are marked Q-08 on every configuration where they fail (decision 1 not implemented).
# Iteration counts (owner decision F11, 2026-10-26: follow the standard): the loop of ECMA-55 §13.4 /
# ANSI X3.113 §8.3.4 -- v = v + step, each sum rounded to the nearest 5-byte float as the calculator
# does since R1, and the exact end test (v - limit) * SGN(step) > 0; the literals are their nearest
# 5-byte values. Not the exact decimal count: FOR i = 0 TO 1 STEP 0.1 runs 10 times (ten rounded
# additions of 0.1, itself just above 0.1, end one ulp above 1). Before R1 the arithmetic truncated,
# which biased every sum low, and these counts happened to equal the decimal ones.
# =====================================================================================
def _r5(q):
    """q rounded to the nearest 5-byte float (32-bit mantissa, ties away from zero)."""
    if q == 0:
        return q
    a = abs(q)
    e = a.numerator.bit_length() - a.denominator.bit_length()
    while a >= Fr(2) ** e:
        e += 1
    while a < Fr(2) ** (e - 1):
        e -= 1
    ulp = Fr(2) ** (e - 32)
    m = int(a / ulp + Fr(1, 2))
    return (m * ulp) if q > 0 else -(m * ulp)


def _cnt(a, b, s):
    a, b, s = _r5(Fr(a)), _r5(Fr(b)), _r5(Fr(s))
    n = 0
    v = a
    while (v <= b) if s >= 0 else (v >= b):
        n += 1
        v = _r5(v + s)
    return n, v


for _a, _b, _s in (("0", "1", "0.1"), ("1", "0", "-0.1"), ("0", "0.3", "0.1"), ("0", "2", "0.2"), ("0", "10", "0.25"),
                   ("-1", "1", "0.1"), ("0", "6.3", "0.7"), ("2", "0", "-0.2"), ("0", "5", "0.1")):
    _n, _ = _cnt(_a, _b, _s)
    T("ffor.count.%s_%s_%s" % (_a, _b, _s), "stmt.FOR.float", ["n = 0", "FOR i = %s TO %s STEP %s" % (_a, _b, _s), "n = n + 1", "NEXT i", "PRINT n"],
      Lines(I(_n)), note="iteration count = the standard's loop with rounded sums (F11)")
T("ffor.count.long", "stmt.FOR.float", ["n = 0", "FOR i = 0 TO 10 STEP 0.01", "n = n + 1", "NEXT i", "PRINT n"],
  Lines(I(_cnt("0", "10", "0.01")[0])), maxi=400_000_000,
  note="the standard's loop: accumulated additions of 0.01, rounded (F11)")
T("ffor.values.down_quarter", "stmt.FOR.float", ["FOR x = 1 TO 0 STEP -0.25", "PRINT x", "NEXT x"],
  Lines(I(1), F(Fr(3, 4)), F(Fr(1, 2)), F(Fr(1, 4)), F(0)), note="INT start; FLOAT values after the first NEXT")
T("ffor.values.int_limit_float", "stmt.FOR.float", ["FOR i = 1 TO 2.5", "PRINT i", "NEXT i"], Lines(I(1), I(2)),
  note="INT start and step stay INT; only the limit is FLOAT")
T("ffor.values.float_start_int_step", "stmt.FOR.float", ["FOR i = 0.5 TO 3", "PRINT i", "NEXT i"], Lines(F(Fr(1, 2)), F(Fr(3, 2)), F(Fr(5, 2))))
T("ffor.values.down_float_step", "stmt.FOR.float", ["FOR i = 10 TO 1 STEP -2.5", "PRINT i", "NEXT i"], Lines(I(10), F(Fr(15, 2)), F(5), F(Fr(5, 2))))
T("ffor.values.promote", "stmt.FOR.float", ["m = 32767 + 3", "FOR i = 32760 TO m STEP 4", "PRINT i", "NEXT i"],
  Lines(I(32760), I(32764), F(32768)), note="the INT variable promotes past 32767 (D11) and keeps going to a FLOAT limit")
T("ffor.values.big_steps", "stmt.FOR.float", ["m = 25000 * 4", "FOR i = 32766 TO m STEP 16384", "PRINT i", "NEXT i"],
  Lines(I(32766), F(49150), F(65534), F(81918), F(98302)),
  note="oracle correction: the first version used 50000 * 2, but under L-A the literal 50000 is the pattern -15536 (zero-trip is correct)")
T("ffor.after.float", "stmt.FOR.float", ["FOR i = 0.5 TO 2", "NEXT i", "PRINT i"], Lines(F(Fr(5, 2))), note="after the loop: one step past the limit")
T("ffor.after.int", "stmt.FOR.float", ["FOR i = 1 TO 3", "NEXT i", "PRINT i"], Lines(I(4)))
T("ffor.nested", "stmt.FOR.float", ["FOR i = 1 TO 2", "FOR j = 0.5 TO 1 STEP 0.5", "PRINT i * 10 + j", "NEXT j", "NEXT i"],
  Lines(F(Fr(21, 2)), F(11), F(Fr(41, 2)), F(21)))
T("ffor.exit", "stmt.FOR.float", ["FOR i = 0.5 TO 9", "IF i > 2 THEN", "EXIT FOR", "ENDIF", "NEXT i", "PRINT i"], Lines(F(Fr(5, 2))))
T("ffor.goto_out", "stmt.FOR.float", ["FOR i = 0.5 TO 9", "IF i > 2 THEN", "GOTO done", "ENDIF", "NEXT i", "done:", "FOR k = 1 TO 2", "PRINT k", "NEXT k"],
  Lines(I(1), I(2)), note="an abandoned float frame must not disturb a later loop")
T("ffor.body_assign", "stmt.FOR.float", ["FOR i = 1 TO 10", "i = i + 2.5", "PRINT i", "NEXT i"], Lines(F(Fr(7, 2)), F(7), F(Fr(21, 2))),
  note="the body makes an INT loop variable FLOAT; NEXT continues with the FLOAT value")
T("ffor.reuse_var", "stmt.FOR.float", ["x = 1.5", "FOR x = 1 TO 2", "PRINT x", "NEXT x"], Lines(I(1), I(2)), note="the start assignment retypes the variable")
T("ffor.zero_trip", "stmt.FOR.float", ["FOR i = 2.5 TO 1", "PRINT i", "NEXT i", 'PRINT "z"'], Out("z"))
T("ffor.zero_trip_down", "stmt.FOR.float", ["FOR i = 0.5 TO 1 STEP -0.5", "PRINT i", "NEXT i", 'PRINT "z"'], Out("z"))
T("ffor.step0.int", "stmt.FOR.float", ["n = 0", "FOR i = 1 TO 2 STEP 0", "n = n + 1", "IF n > 5 THEN", "EXIT FOR", "ENDIF", "NEXT i", "PRINT n"], Lines(I(6)),
  note="manual: STEP 0 never advances (BREAK or EXIT FOR ends it)")
T("ffor.step0.float", "stmt.FOR.float", ["n = 0", "FOR i = 1.5 TO 2 STEP 0.0", "n = n + 1", "IF n > 5 THEN", "EXIT FOR", "ENDIF", "NEXT i", "PRINT n"], Lines(I(6)))
T("ffor.step0.past", "stmt.FOR.float", ["n = 0", "FOR i = 3 TO 2 STEP 0", "n = n + 1", "NEXT i", "PRINT n"], Lines(I(0)), note="STEP 0 counts as ascending")
T("ffor.expr_bounds", "stmt.FOR.float", ["a = 1 / 4", "b = 3 / 4", "s = 1 / 4", "FOR i = a TO b STEP s", "PRINT i", "NEXT i"],
  Lines(F(Fr(1, 4)), F(Fr(1, 2)), F(Fr(3, 4))))
T("ffor.in_proc", "stmt.FOR.float", ["CALL p(1)", "END", "PROC p(a):", "FOR i = a TO a + 1 STEP 0.5", "PRINT i", "NEXT i", "ENDP"],
  Lines(I(1), F(Fr(3, 2)), F(2)))
for _c in CASES:
    if _c.cid.startswith("ffor.") and _c.cid not in ("ffor.after.int", "ffor.goto_out", "ffor.reuse_var", "ffor.step0.int"):
        for cfg in CFGS:
            _c.known.setdefault(cfg, "Q-07" if _c.cid == "ffor.step0.past" else "Q-08")

# =====================================================================================
# 23. Found during the owner-decision review (2026-10-11)
# Q-32: D11 promotion makes address arithmetic above 32767 a FLOAT, and POKE/PEEK/USR/IN/OUT saturated
#       it to 32767 (Essential/Enhanced; the baseline's wrap happened to give the right address).
#       Byte 33370 ($825A, PROG_AREA_START in every build) is the first line's length + 1.
# Q-33: package statement arguments ignore the FLOAT tag (OP_CALL_EXT pops raw): the slot index arrives.
# =====================================================================================
T("addr.promoted_peek", "fn.PEEK", ["a = 30000", "b = a + 3370", "PRINT PEEK(b)"], Num(10, "int"),
  note="the address 33370 is a FLOAT after D11 promotion; it must not become 32767")
T("addr.promoted_poke", "stmt.POKE", ["a = 30000", "POKE a + 3370, 77", "PRINT PEEK(33370)"], Num(77, "int"),
  note="POKE to a promoted address wrote to 32767")
T("addr.usr_unsigned", "fn.USR", ["POKE 61440,33", "POKE 61441,64", "POKE 61442,156", "POKE 61443,201", "PRINT USR(61440)"], Num(40000),
  known=LA, note="ld hl,40000 / ret (V2's USR returns HL): mathematically 40000 (L-A returns the 16-bit pattern -25536). "
                 "Oracle correction: the first version loaded BC")
T("pkg.shapes.float_radius", "pkg.SHAPES", ["r = 33 / 2", "CIRCLE 128,96,r", "p = POINT(144,96)", "CLS", "PRINT p"], Num(1, "int"),
  packages=("shapes",), note="radius 16.5 truncates to 16: the circle passes through (144,96)")
for _cid in ("addr.promoted_peek", "addr.promoted_poke"):
    _c = [c for c in CASES if c.cid == _cid][0]
    for cfg in ("essential", "enhanced"):
        _c.known.setdefault(cfg, "Q-32")
[c for c in CASES if c.cid == "pkg.shapes.float_radius"][0].known.update({c: "Q-33" for c in CFGS})
for _v in (32769, 40000):
    T("lit.int.neg%d" % _v, "literal.integer.large", ["PRINT -%d" % _v], Num(-_v), known=LA,
      decision="literal rule L-A/L-C",
      note="L-A: 0 - <the 16-bit pattern> prints a positive number (-40000 -> 25536); L-C: the value")
T("lit.int.pattern_arith", "literal.integer.large", ["x = 40000", "PRINT x + 1"], Num(40001), known=LA,
  decision="literal rule L-A/L-C", note="L-A: pattern arithmetic, -25535")
