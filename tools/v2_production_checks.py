#!/usr/bin/env python3
"""R10.7 production-ROM checks (headless, ts2068-debug).

Boots build/ts2068rom_zesarux.bin (the real HOME+EXROM image), writes a
program straight into the line store, runs the real V2_RUN_STORED, and checks
the compile/run error codes and variable values. Run from the repo root after
`make build`.  Exit status is non-zero if any case fails.
"""
import sys
sys.path.insert(0, __import__('os').path.dirname(__file__))
from v2_headless import *

fails = 0
def case(name, lines, ce=0, ve=0, vals=None, extra=None, times=1):
    global fails
    c, e, v = run(lines, times=times)
    ok = (c == ce and e == ve)
    got = {}
    for i, want in (vals or {}).items():
        got[i] = v(i); ok &= got[i] == want
    note = ""
    if extra:
        r = extra(v) if extra.__code__.co_argcount else extra(); ok &= r[0]; note = r[1]
    print(f"{'PASS' if ok else 'FAIL'} {name}: compile_err={c} vm_err={e}"
          + (f" vals={got}" if vals else "") + (f" {note}" if note else ""))
    if not ok: fails += 1
    D("stop")

# 1. deep recursion with a parameter (old limit 12)
case("recursion-150", ["proc c(n)", "if n > 0 then call c(n - 1)", "endif", "r = r + n", "endp",
                       "r = 0", "call c(150)"], vals={1: 11325})
# 2. nested FOR/NEXT, three levels
case("nested-for", ["s = 0", "for i = 1 to 10", "for j = 1 to 10", "for k = 1 to 3", "s = s + 1",
                    "next k", "next j", "next i"], vals={0: 300})
# 3. GOTO out of a loop inside a PROC (leaked FOR frame), three calls
case("goto-out-of-for", ["proc g(n)", "for i = 1 to 5", "goto fin", "next i", "fin:", "r = r + 1", "endp",
                         "r = 0", "call g(0)", "call g(0)", "call g(0)"], vals={2: 3})
# 4. identifiers: 31 significant characters stay distinct; 32 is an explicit error
a = "abcdefghijklmnopqrstuvwxyz01234"
case("ident-31", [f"{a} = 5", f"{a[:-1]}5 = 9", f"t = {a} + {a[:-1]}5"], vals={0: 5, 1: 9, 2: 14})
case("ident-32", [f"{a}x = 5"], ce=61)
# 5. many labels / PROCs / DEF FNs
lines = ["s = 0", "t = 0"]
for k in range(1, 21):
    lines += [f"proc p{k}(n)", "s = s + n", "endp"]
for k in range(1, 21):
    lines += [f"def fn f{k}(x) = x + {k}"]
for k in range(1, 21):
    lines += [f"call p{k}({k})", f"t = t + fn f{k}(1)", f"goto l{k}", "s = s + 1000", f"l{k}:"]
case("labels-procs-fns", lines, vals={0: 210})
# 6. stack into arrays: clean error, array data intact
def arr_intact():
    e = w16(HSYM["ARRAYS_END"]); b = read(e - 2, 2)
    return (b[0] == 9, f"A(1999)@{e-2:04X}={b[0]}")
case("stack-into-arrays", ["proc f(n)", "call f(n + 1)", "endp", "dim a(2000)", "a(1999) = 9", "call f(0)"],
     ve=6, extra=arr_intact)
# 7. arrays into stack: fits alone, refused when 200 frames deep
dimprog = lambda d: ["proc f(n)", "if n > 0 then call f(n - 1)", "endif", "if n = 0 then dim a(3300)",
                     "endif", "endp", f"call f({d})"]
case("dim-alone", dimprog(0))
case("dim-under-recursion", dimprog(200), ve=64)
# 7b. second array segment ($E000-$E7FF): used only when the main pool is full
def seg2(idx, want_seg2, end_after=None):
    def f():
        p = w16(HSYM["RT_ARRPTR_PTR"]) if idx[0] == "n" else w16(HSYM["RT_STRARRPTR_PTR"])
        ptr = w16(p + 2 * idx[1])
        ok = (0xE000 <= ptr < 0xE800) == want_seg2
        if end_after is not None: ok &= w16(HSYM["ARR2_END"]) == end_after
        ok &= w16(HSYM["ARRAYS_END"]) < w16(HSYM["VM_CSP"])        # swapped back
        return ok, f"ptr={ptr:04X} ARR2_END={w16(HSYM['ARR2_END']):04X}"
    return f
case("seg2-numeric", ["dim a(3600)", "dim b(900)", "a(3599) = 7", "b(899) = 9", "b(0) = 3",
                      "x = b(899) + a(3599) + b(0)"], vals={0: 19}, extra=seg2(("n", 1), True, 0xE000 + 1803))
case("seg2-main-first", ["dim a(100)", "a(99) = 5", "x = a(99)"], vals={0: 5}, extra=seg2(("n", 0), False, 0xE000))
# RAM efficiency: the pool grew by 814 bytes, so a(3600) no longer leaves too little room for s$(10,100);
# a(4000) (still in the main pool, whose limit is now 4443 elements) keeps the string array overflowing.
case("seg2-string", ["dim a(4000)", "dim s$(10,100)", "s$(9) = \"hello\"", "t$ = s$(9)", "n = len(t$)"],
     vals={0: 5}, extra=seg2(("s", 0), True))
case("seg2-exhausted", ["dim a(3600)", "dim b(900)", "dim c(900)"], ve=64)
case("seg2-reset-on-rerun", ["dim a(3600)", "dim b(900)", "b(899) = 4", "x = b(899)"], vals={0: 4},
     extra=seg2(("n", 1), True, 0xE000 + 1803), times=2)
# RC: the main pool is 154 bytes smaller than in R10.7 (this program: 967 -> 813 free), both measured:
# 74 = two more string temps (2 x 32) and two more float temps (2 x 5) -- QUAL Q-02, temporaries are
# never reused while referenced (817667f); 80 = SESS_GAP, room for the symbols that immediate statements
# add to a session (owner decision 2). The bounds are the old ones moved by exactly that 154.
# RAM efficiency (docs/v2/RAM_EFFICIENCY_RESULTS.md): the pool is 814 bytes larger (813 -> 1627 free,
# measured); the bounds move up by exactly that.
case("free-1", ["x = free(1)", "dim a(3600)", "dim b(900)", "y = free(1)", "z = free()", "w = free(0)"],
     vals={0: 2048, 1: 2048 - 1803},
     extra=lambda v: (v(2) == v(3) and 900 - 154 + 814 < v(2) < 1100 - 154 + 814, f"free()={v(2)} free(0)={v(3)}"))
case("free-expr-arg", ["n = 1", "x = free(n)"], vals={1: 2048})
# RAM efficiency (docs/v2/RAM_EFFICIENCY_RESULTS.md): the pool runs straight into the bytecode area and
# the compile zone moved to the fixed V2 area. pool-814-program: 38 units of procedures, loops, strings and
# IFs (6,472 source bytes) compile and run; the v2.0.1 release ran out of memory (error 64) above 34.
# Its run-time tables sit directly below the code they run, and the compile stack started there too.
_unit = ["PROC p{k}(n)", "  s{k} = 0", "  FOR i = 1 TO n", "    s{k} = s{k} + i * 2", "  NEXT i",
         "  t{k}$ = \"unit \" + STR$(s{k})", "ENDP", "CALL p{k}(3)", "IF s{k} > 5 THEN", "  c = c + 1", "ENDIF"]
case("pool-814-program", ["c = 0"] + [l.format(k=k) for k in range(38) for l in _unit] + ["q = c"],
     vals={0: 38})
# pool-top-array: the largest numeric array the main pool holds (4,443 elements, was 4,036); its last
# element ends a few bytes below the run-time tables, which end at the first bytecode byte.
case("pool-top-array", ["dim a(4443)", "a(4442) = 5", "a(0) = 2", "x = a(4442) + a(0)"], vals={0: 7},
     extra=seg2(("n", 0), False, 0xE000))
# the compile zone (chunk buffer, LEX_LINE, identifier buffer) lies outside the pool and the bytecode
case("zone-outside-pool", ["x = 1"], vals={0: 1},
     extra=lambda: (HSYM["V2_SOURCE_END"] == HSYM["VM_CODE_BASE"]
                    and HSYM["V2_ZONE_BASE"] >= HSYM["V2_CODE_LIMIT"]
                    and HSYM["CHUNK_BUF"] == HSYM["V2_ZONE_BASE"],
                    f"pool end {HSYM['V2_SOURCE_END']:04X} code {HSYM['VM_CODE_BASE']:04X}-"
                    f"{HSYM['V2_CODE_LIMIT'] - 1:04X} zone {HSYM['V2_ZONE_BASE']:04X}"))
# 8. capacity: 251 numeric variables ok, 252nd a clean compile error. RC: the cap is 255 minus the float
# temporaries (SYM_CAPS), which QUAL Q-02 raised from 2 to 4 (817667f) -- it was 253.
case("251-vars", [f"w{i} = {i % 100}" for i in range(1, 252)])
c, e, v = run([f"w{i} = {i % 100}" for i in range(1, 253)])
print(f"{'PASS' if c in (1, 39) else 'FAIL'} 252-vars: compile_err={c} vm_err={e}")
fails += c not in (1, 39); D("stop")
# 9. ordinary program
case("plain", ["s = 0", "for i = 1 to 3", "s = s + i", "next i"], vals={0: 6})
print("FAILURES:", fails)
sys.exit(1 if fails else 0)
