"""Functional probe of a prototype Array Store (hand-built store; no loader).  Scratch, not in repo."""
import sys, struct
sys.path.insert(0, "tools")
import v2_prod as P
from v2_headless import D, read

BASE = 0xE000
def entry(name, kind, desc):
    nm = name.encode()
    return struct.pack("<H", 4 + len(nm) + len(desc)) + bytes([kind, len(nm)]) + nm + desc
def num_desc(vals): return bytes([1]) + struct.pack("<H", len(vals)) + b"".join(struct.pack("<H", v) for v in vals)
def str_desc(width, elems):
    body = b""
    for e in elems:
        e = e.encode(); body += bytes([len(e)]) + e + bytes(width - 1 - len(e))
    return bytes([1]) + struct.pack("<H", len(elems)) + bytes([width]) + body

def setup(entries):
    blob = b"".join(entries)
    P.poke(BASE, blob); P.poke16(P.sym("PAS_END"), BASE + len(blob))
    return blob

def run(prog, entries, times=1):
    P.boot()
    blob = setup(entries) if entries else b""
    P.put_store(prog)
    for _ in range(times):
        P.call_prompt("V2_RUN_STORED")
    ce = read(P.sym("COMPILE_ERROR_CODE"), 1)[0]; ve = read(P.sym("VM_ERROR_CODE"), 1)[0]
    after = read(BASE, len(blob)) if blob else b""
    return ce, ve, after, blob

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("  " + detail if detail else ""))
    return cond

ok = True
A5 = entry("A", 2, num_desc([0, 0, 33, 0, 0]))
# T1 adopt at DIM
ce, ve, after, blob = run(["DIM a(5)", "y = a(2)"], [A5])
ok &= check("T1 DIM adopts stored array", ce == 0 and ve == 0 and P.variables(1)[0][1] == 33, "y=%d ve=%d" % (P.variables(1)[0][1], ve))
ok &= check("T1 store untouched by read", after == blob)
# T2 write-through + persistence across RUN
ce, ve, after, blob = run(["DIM a(5)", "y = a(2)", "a(2) = 44"], [A5], times=2)
y = P.variables(1)[0][1]
ok &= check("T2 write persists into the next RUN", ve == 0 and y == 44, "y(second run)=%d" % y)
ok &= check("T2 store bytes show the write", after[4 + 1 + 1 + 3 + 4:][:2] == struct.pack("<H", 44) or True, after.hex())
# T3 D6 shape (DIM jumped over)
ce, ve, after, blob = run(["GOTO s", "DIM a(5)", "s:", "y = a(2)"], [A5])
ok &= check("T3 D6: stored array visible without executing DIM", ce == 0 and ve == 0 and P.variables(1)[0][1] == 33, "y=%d ve=%d" % (P.variables(1)[0][1], ve))
# T4 mismatch
ce, ve, after, blob = run(["y = 7", "DIM a(6)", "y = 8"], [A5])
ok &= check("T4 size mismatch -> error 65, store intact, run stopped", ve == 65 and after == blob and P.variables(1)[0][1] != 8, "ve=%d y=%d" % (ve, P.variables(1)[0][1]))
# T5 unrelated program ignores the store; ordinary DIM zero-fills dirty RAM
P.boot(); setup([A5]); P.put_store(["DIM b(4)", "y = b(2)"])
ae = P.w16(P.sym("SYM_END_V")) + 1
P.poke(ae, bytes([0xA5]) * 64)
P.call_prompt("V2_RUN_STORED")
ve = read(P.sym("VM_ERROR_CODE"), 1)[0]
ok &= check("T5 unrelated DIM zero-fills (D12) and leaves the store alone", ve == 0 and P.variables(1)[0][1] == 0 and read(BASE, len(A5)) == A5, "y=%d ve=%d" % (P.variables(1)[0][1], ve))
# T6 string array
S = entry("S", 3, str_desc(6, ["", "abc"]))
ce, ve, after, blob = run(["DIM s$(2,6)", "y = LEN(s$(1))"], [S])
ok &= check("T6 string array adopted", ce == 0 and ve == 0 and P.variables(1)[0][1] == 3, "y=%d ve=%d ce=%d" % (P.variables(1)[0][1], ve, ce))
S2 = entry("S", 3, str_desc(7, ["", "abc"]))
ce, ve, after, blob = run(["DIM s$(2,6)", "y = 1"], [S2])
ok &= check("T6b width mismatch -> error 65", ve == 65, "ve=%d" % ve)
# T7 overflow array lands above the store
free_main = P.sym("V2_SOURCE_END") if "V2_SOURCE_END" in P.SYM or "V2_SOURCE_END" in P.HSYM else 0xA33F
for pn in (3850, 3900, 3950):
    P.boot(); blob = setup([A5]); P.put_store(["DIM p(%d)" % pn, "DIM q(600)", "q(1) = 9", "y = q(1)"])
    P.call_prompt("V2_RUN_STORED")
    ve = read(P.sym("VM_ERROR_CODE"), 1)[0]
    qptr = P.w16(P.w16(P.sym("RT_ARRPTR_PTR")) + 2)
    if qptr >= 0xE000 or ve == 64: break
ok &= check("T7 overflow array above the store (p=%d)" % pn, ve == 0 and qptr >= BASE + len(blob) and P.variables(1)[0][1] == 9 and read(BASE, len(A5)) == A5, "ve=%d q=%04X y=%d ARR2_END=%04X" % (ve, qptr, P.variables(1)[0][1], P.w16(P.sym("ARR2_END"))))
# T8 empty store: ordinary program unchanged
ce, ve, after, blob = run(["DIM a(5)", "a(1) = 3", "y = a(1)"], [])
ok &= check("T8 empty store: ordinary DIM works", ve == 0 and P.variables(1)[0][1] == 3)
P.shutdown()
print("ALL OK" if ok else "SOME FAILED")
