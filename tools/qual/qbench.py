#!/usr/bin/env python3
"""Emulated T-states of BASIC programs on several builds (ZRCP get-tstates-partial around the real
V2_RUN_STORED; compile + run, until the final key wait).  Usage:
  python3 qbench.py --port 10580 cfgA cfgB ...   (programs are built in)"""
import os, sys, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine
PROGS = {
    "int_loop": ["s = 0", "FOR i = 1 TO 2000", "s = s + i * 3 - 1", "NEXT i"],
    "for_empty": ["FOR i = 1 TO 3000", "NEXT i"],
    "for_nested": ["FOR i = 1 TO 60", "FOR j = 1 TO 50", "NEXT j", "NEXT i"],
    "for_float_step": ["FOR i = 0 TO 1500 STEP 0.5", "NEXT i"],
    "for_int_3001": ["FOR i = 0 TO 3000", "NEXT i"],
    "float_loop": ["x = 0", "FOR i = 1 TO 200", "x = x + 0.5 * 1.5", "NEXT i"],
    "strings": ['a$ = ""', "FOR i = 1 TO 200", 'a$ = LEFT$(a$ + "x", 20)', "NEXT i"],
    "builtins": ["s = 0", "FOR i = 1 TO 500", "s = s + ABS(-i) + MOD(i,7) + SGN(i)", "NEXT i"],
    "compile_only": ["x%d = %d + %d * (%d - 1)" % (k, k, k, k) for k in range(60)],
    # 5.1: a decimal literal alone in a loop; 240 literals compiled but never run (IF 0), against
    # the same lines with integers
    "loop_200": ["x = 0", "FOR i = 1 TO 200", "NEXT i"],
    "float_add_lit": ["x = 0", "FOR i = 1 TO 200", "x = x + 0.5", "NEXT i"],
    # R1: a division in a loop (the arithmetic's slowest operation)
    "float_div": ["x = 0", "FOR i = 1 TO 200", "x = x + i / 7", "NEXT i"],
    "compile_dec": ["IF 0 THEN"] + ["x%d = %d.25 + %d.5 * (0.%d - 1.75)" % (k, k, k, k + 1) for k in range(60)] + ["ENDIF"],
    "compile_int_if": ["IF 0 THEN"] + ["x%d = %d + %d * (%d - 1)" % (k, k, k, k + 1) for k in range(60)] + ["ENDIF"],
    # 5.2-5.4: integer programs that stay integer (int_loop and builtins overflow into FLOAT)
    "int_inc": ["x = 0", "FOR i = 1 TO 2000", "x = x + 1", "NEXT i"],
    "goto_loop": ["i = 0", "top:", "i = i + 1", "IF i < 2000 THEN GOTO top"],
    "if_branch": ["a = 0", "g = 0", "FOR i = 1 TO 2000", "g = 1 - g", "IF g = 0 THEN", "a = a + 1", "ENDIF", "NEXT i"],
    "proc_calls": ["s = 0", "FOR i = 1 TO 500", "CALL p(i)", "NEXT i", "END", "PROC p(n):", "s = s + n", "ENDP"],
    # the sieve of ~/2068-rom-benchmarks (basic-leap/sieve.bas), one pass, in V2's dialect
    "sieve": ["s = 500", "DIM g(501)", "c = 0", "FOR i = 0 TO s", "g(i) = 1", "NEXT i", "FOR i = 0 TO s",
              "IF g(i) = 0 THEN GOTO skip", "r = i + i + 3", "k = i + r", "IF k > s THEN GOTO noclear",
              "clearloop:", "g(k) = 0", "k = k + r", "IF k <= s THEN GOTO clearloop", "noclear:", "c = c + 1",
              "skip:", "NEXT i"],
}
ap = argparse.ArgumentParser(); ap.add_argument("cfgs", nargs="+"); ap.add_argument("--port", type=int, default=10580)
ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "qual-builds"))
a = ap.parse_args()
res = {}
for i, cfg in enumerate(a.cfgs):
    m = Machine(os.path.join(a.root, cfg), a.port + i, label=cfg).start()
    try:
        for name, prog in PROGS.items():
            m.restore(); m.put_store(prog)
            m.cmd("reset-tstates-partial")
            r = m.call_routine("V2_RUN_STORED", maxi=400_000_000)
            t = int(m.cmd("get-tstates-partial").strip())
            res.setdefault(name, {})[cfg] = (t, r.ce, r.ve, r.status)
    finally:
        m.stop()
print("%-14s " % "program" + " ".join("%22s" % c for c in a.cfgs) + "   delta(last vs first)")
for name in PROGS:
    row = res[name]; base = row[a.cfgs[0]][0]
    print("%-14s " % name + " ".join("%14d (%s/%s)" % (row[c][0], row[c][1], row[c][2]) for c in a.cfgs) +
          "   %+.2f%%" % (100.0 * (row[a.cfgs[-1]][0] - base) / base))
