#!/usr/bin/env python3
"""Where the run time goes, on one build (back-port plan, "Phase 5 follow-ups").

Default: a per-instruction profile of a set of workloads. A breakpoint at VM_RUN.next (every dispatch)
charges the T-states since the previous stop to the instruction dispatched there: dispatch, handler and
the BREAK poll; the frame interrupts land on whatever runs. Each workload runs in its own emulator.
Prints, per workload, the share of the dispatch and the top instructions, then every instruction's
share with all workloads weighted equally, and its mean T.

--statements: what one statement adds to a FOR loop, (T(2N passes) - T(N passes)) / N less an empty
pass (as tools/qual/manual_measure.py), for the built-in functions, float operations and output.

  python3 tools/qual/qprofile.py [--tree . | --root DIR cfg] [--statements] [--port N] [name ...]
"""
import argparse
import collections
import multiprocessing as mp
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine, HARNESS_RET_SLOT  # noqa: E402

DISPATCH_T = 151        # VM_RUN.next to the handler (143 T) + the handler's `jp (iy)` (8 T)

WORKLOADS = {
    "goto_loop": ["i = 0", "top:", "i = i + 1", "IF i < 300 THEN GOTO top"],
    "if_branch": ["a = 0", "g = 0", "FOR i = 1 TO 300", "g = 1 - g", "IF g = 0 THEN", "a = a + 1", "ENDIF", "NEXT i"],
    "sieve": ["s = 100", "DIM g(101)", "c = 0", "FOR i = 0 TO s", "g(i) = 1", "NEXT i", "FOR i = 0 TO s",
              "IF g(i) = 0 THEN GOTO skip", "r = i + i + 3", "k = i + r", "IF k > s THEN GOTO noclear",
              "clearloop:", "g(k) = 0", "k = k + r", "IF k <= s THEN GOTO clearloop", "noclear:", "c = c + 1",
              "skip:", "NEXT i"],
    "int_expr": ["s = 0", "FOR i = 1 TO 300", "s = s + i * 3 - 1", "NEXT i"],
    "proc_calls": ["s = 0", "FOR i = 1 TO 100", "CALL p(i)", "NEXT i", "END", "PROC p(n):", "s = s + n", "ENDP"],
    "builtins": ["s = 0", "FOR i = 1 TO 100", "s = s + ABS(-i) + MOD(i,7) + SGN(i)", "NEXT i"],
    "strings": ['a$ = ""', "FOR i = 1 TO 100", 'a$ = LEFT$(a$ + "x", 20)', "NEXT i"],
    "float_loop": ["x = 0", "FOR i = 1 TO 100", "x = x + 0.5 * 1.5", "NEXT i"],
    # ~/2068-rom-benchmarks' basic-leap pixel (chaos game), string and float (SQR) programs in V2's dialect
    "pixel": ["DIM x(3)", "DIM y(3)", "x(0) = 128", "y(0) = 8", "x(1) = 16", "y(1) = 150", "x(2) = 240",
              "y(2) = 150", "a = 128", "b = 96", "i = 0", "loop:", "v = RND(3)", "a = DIV(a + x(v), 2)",
              "b = DIV(b + y(v), 2)", "INK v + 1", "PLOT a, b", "i = i + 1", "IF i < 150 THEN GOTO loop"],
    "string_build": ["m = 0", "FOR i = 1 TO 150", 'a$ = "TS2068-"', "a$ = a$ + STR$(i)", 'a$ = a$ + "-BENCH"',
                     "IF LEN(a$) > 4 THEN", "m = m + 1", "ENDIF", "NEXT i"],
    "float_sqr": ["a = 0", "i = 0", "loop:", "a = a + SQR(i + 1)", "i = i + 1", "IF i < 40 THEN GOTO loop"],
}

# (name, lines before the loop, loop body); the slow ones run fewer passes
STATEMENTS = [
    ("empty FOR/NEXT pass", [], []),
    ("x = SQR(i)", [], ["x = SQR(i)"]), ("x = SQR(2.5)", [], ["x = SQR(2.5)"]),
    ("x = SIN(i)", [], ["x = SIN(i)"]), ("x = COS(i)", [], ["x = COS(i)"]), ("x = TAN(i)", [], ["x = TAN(i)"]),
    ("x = SIN(2.5)", [], ["x = SIN(2.5)"]), ("x = COS(2.5)", [], ["x = COS(2.5)"]),
    ("x = RND(3)", [], ["x = RND(3)"]), ("x = DIV(i, 7)", [], ["x = DIV(i, 7)"]),
    ("x = MOD(i, 7)", [], ["x = MOD(i, 7)"]), ("x = ABS(i)", [], ["x = ABS(i)"]),
    ("x = INT(2.5)", [], ["x = INT(2.5)"]), ("a$ = STR$(i)", [], ["a$ = STR$(i)"]),
    ('x = VAL("12")', [], ['x = VAL("12")']), ("x = i / 7", [], ["x = i / 7"]),
    ("x = i * 0.5", [], ["x = i * 0.5"]), ("x = 2.5 + i", [], ["x = 2.5 + i"]),
    ("PRINT 7 (scrolls)", [], ["PRINT 7"]), ("AT 5, 0: PRINT 7;", [], ["AT 5, 0", "PRINT 7;"]),
]
SLOW = ("SQR", "SIN", "COS", "TAN", "scrolls")


def opnames(cfgdir):
    src = open(os.path.join(cfgdir, "rom", "exrom_v2_vm_core.asm")).read()
    names = []
    for line in src[src.index("VM_OP_TABLE:"):].split("\n")[1:]:
        m = re.match(r"\s+dw\s+(\w+)", line)
        if m:
            names.append(m.group(1).replace("OP_", "", 1))
        elif line.strip() and not line.strip().startswith(";"):
            break
    return names


def profile_one(args):
    cfgdir, port, name = args
    names = opnames(cfgdir)
    m = Machine(cfgdir, port, label=name).start()
    try:
        nxt, iok, msg, ret = (m.sym(s) for s in ("VM_RUN.next", "IO_READ_KEY", "V2_SHOW_MESSAGE",
                                                 "V2_COMMAND_LOOP.loop"))
        vmip = m.sym("VM_IP")
        m.restore()
        m.put_store(WORKLOADS[name])
        m.write(HARNESS_RET_SLOT, struct.pack("<H", ret))
        m.setreg("SP", HARNESS_RET_SLOT)
        m.setreg("PC", m.sym("V2_RUN_STORED"))
        m.set_bps([nxt, iok, msg, ret])
        m.cmd("reset-tstates-partial")
        cost = collections.defaultdict(lambda: [0, 0])
        prev, tprev, compile_t = None, 0, 0
        while True:
            m.run(60_000_000)
            p = m.pc()
            t = int(m.cmd("get-tstates-partial").strip())
            if prev is None:
                compile_t = t
            else:
                cost[prev][0] += 1
                cost[prev][1] += t - tprev
            if p != nxt:
                break
            op = m.read(m.w16(vmip), 1)[0]
            prev, tprev = (names[op] if op < len(names) else "op%d" % op), t
            m.step()
        ce = m.read(m.sym("COMPILE_ERROR_CODE"), 1)[0]
        ve = m.read(m.sym("VM_ERROR_CODE"), 1)[0]
    finally:
        m.stop()
    return name, ce, ve, compile_t, dict(cost)


def statements(cfgdir, port, only):
    m = Machine(cfgdir, port).start()
    try:
        def t(pre, body, n):
            m.restore()
            m.put_store(pre + ["FOR i = 1 TO %d" % n] + body + ["NEXT i"])
            m.cmd("reset-tstates-partial")
            r = m.call_routine("V2_RUN_STORED", maxi=900_000_000)
            assert r.ce == 0 and r.ve == 0, (body, r.ce, r.ve)
            return int(m.cmd("get-tstates-partial").strip())
        empty = None
        for name, pre, body in STATEMENTS:
            if only and empty is not None and not any(s in name for s in only):
                continue
            n = 30 if any(s in name for s in SLOW) else 200
            per = (t(pre, body, 2 * n) - t(pre, body, n)) / n
            if empty is None:
                empty = per
                print("%-22s %9.0f T  (a pass)" % (name, per), flush=True)
            else:
                print("%-22s %9.0f T  (added)" % (name, per - empty), flush=True)
    finally:
        m.stop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cfg", nargs="?", default=None)
    ap.add_argument("only", nargs="*")
    ap.add_argument("--tree", default=None, help="the build in this source tree (e.g. .)")
    ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                                   "build", "qual-builds"))
    ap.add_argument("--port", type=int, default=10600)
    ap.add_argument("--statements", action="store_true")
    a = ap.parse_args()
    cfgdir = os.path.abspath(a.tree) if a.tree else os.path.join(a.root, a.cfg)
    only = a.only + ([a.cfg] if a.tree and a.cfg else [])
    if a.statements:
        return statements(cfgdir, a.port, only)
    todo = [n for n in WORKLOADS if not only or any(s in n for s in only)]
    with mp.Pool(len(todo)) as pool:
        res = pool.map(profile_one, [(cfgdir, a.port + 2 * i, n) for i, n in enumerate(todo)])
    share = collections.defaultdict(float)
    count = collections.Counter()
    total = collections.Counter()
    print("%-13s %5s %9s %5s %6s  top instructions (share of run time, mean T)"
          % ("workload", "ops", "run T", "T/op", "disp."))
    for name, ce, ve, compile_t, cost in res:
        run = sum(v[1] for v in cost.values())
        ops = sum(v[0] for v in cost.values())
        if ce or ve or not ops:
            print("%-13s ce=%d ve=%d: not profiled" % (name, ce, ve))
            continue
        top = sorted(cost.items(), key=lambda kv: -kv[1][1])[:5]
        print("%-13s %5d %9d %5.0f %5.1f%%  %s" % (name, ops, run, run / ops, 100.0 * DISPATCH_T * ops / run,
              ", ".join("%s %.0f%% (%.0f)" % (k, 100.0 * v[1] / run, v[1] / v[0]) for k, v in top)))
        for k, v in cost.items():
            share[k] += v[1] / run / len(res)
            count[k] += v[0]
            total[k] += v[1]
    print("\nall workloads weighted equally:")
    for k, v in sorted(share.items(), key=lambda kv: -kv[1])[:30]:
        print("  %-16s %5.1f%%   mean %7.0f T  (n=%d)" % (k, 100.0 * v, total[k] / count[k], count[k]))


if __name__ == "__main__":
    sys.exit(main())
