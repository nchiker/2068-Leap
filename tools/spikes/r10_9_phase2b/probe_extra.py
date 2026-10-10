"""Lifecycle + banking probes for the tightened C prototype (scratch)."""
import sys, struct
sys.path.insert(0, "tools")
import v2_prod as P
import tape_synth as TS
import v2_known_defects as K
from v2_headless import D, read
import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe_common.py")).read())

A = num([0, 0, 33, 0, 0])
def banking_probe(entry_cmd, label, targets, setup=None):
    out = []
    import struct as S
    D("mem-write", "0xFF00", S.pack("<H", P.RET).hex()); D("set-register", "SP", "0xFF00"); D("set-register", "PC", hex(entry_cmd))
    seen = set()
    for _ in range(20):
        for k, t in enumerate(targets):
            if t not in seen: D("break", hex(P.sym(t)), "--index", str(10 + k))
        D("run", "--until", hex(P.IOK), "--max-instructions", "150000000", t=1800); D("pause")
        pc = P.pc()
        hit = [t for t in targets if P.sym(t) == pc]
        for k in range(len(targets)):
            try: D("clear-break", "--index", str(10 + k))
            except Exception: pass
        if pc == P.IOK or not hit: break
        seen.add(hit[0])
        out.append("%s depth=%d FF=%02X" % (hit[0], read(P.sym("BANK_EXROM_DEPTH"),1)[0], read(P.sym("PORT_FF_SHADOW"),1)[0]))
        D("step")
    print("   ", label, "->", "; ".join(out))
    return out

# ---- banking on the NEW code, RUN and immediate
P.boot(); P.poke(0xE000, entry("a", 2, A)); P.poke16(P.sym("PAS_END"), 0xE000 + 4 + 1 + len(A))
P.put_store(["DIM a(5)", "DIM b$(2,8)", "y = a(2)", "CLEAR"])
o = banking_probe(P.sym("V2_RUN_STORED"), "RUN", ["ARR_RUN_INIT", "ARR_OP_DIM", "ARR_OP_DIM_STR", "ARR_DIM", "MEM_CLEAR_V2"])
check("B1 EXROM mapped (depth>=1, port FF bit7) at every new HOME->EXROM site during RUN", len(o) >= 4 and all("depth=1" in x or "depth=2" in x for x in o) and all("FF=80" in x for x in o), "; ".join(o))
P.poke(P.sym("EDIT_LINE_BUF"), b": DIM a(5)\0")
o = banking_probe(P.sym("V2_DISPATCH"), "immediate", ["ARR_RUN_INIT", "ARR_OP_DIM", "ARR_DIM"])
check("B2 same for an immediate statement", len(o) >= 2 and all(("depth=1" in x or "depth=2" in x) and "FF=80" in x for x in o), "; ".join(o))
slot = P.w16(P.w16(P.sym("RT_ARRPTR_PTR")))
check("B2b immediate `: DIM a(5)` adopts the stored array", slot == 0xE000 + 4 + 1, "slot=%04X" % slot)
P.shutdown()

# ---- CLEAR in a running program keeps the store
P.boot(); P.poke(0xE000, entry("a", 2, A)); P.poke16(P.sym("PAS_END"), 0xE000 + 4 + 1 + len(A))
before = store_state()
run_prog(["DIM a(5)", "y = a(2)", "CLEAR", "z = 7"])
after = store_state()
check("C1 CLEAR leaves the store intact", after == before and P.w16(P.sym("ARR2_END")) >= after[0], "ARR2_END=%04X PAS_END=%04X" % (P.w16(P.sym("ARR2_END")), after[0]))
# ---- editing a line keeps the store
P.type_text("q = 1")
check("C2 typing a program line keeps the store", store_state() == before)
run_prog(["DIM a(5)", "y = a(2)", "a(2) = 77"])
check("C3 repeated RUN: write persists", True)
run_prog(["DIM a(5)", "y = a(2)"])
check("C3b ...and is seen by the next RUN", P.variables(1)[0][1] == 77, "y=%d" % P.variables(1)[0][1])
P.shutdown()

# ---- program LOAD keeps the store
src = TS.source_records(["x = 5", "y = 6"])
t = tape([("ARR", A, {})])
t.block(TS.framed(0, TS.header_payload(0, "PROG", len(src), autostart=K.FMT_WORD))); t.block(TS.framed(0xFF, src))
P.boot(t, lead=K.ARR_LEAD)
load('load "ARR" ARRAY a'); before = store_state()
msg = load('load "PROG"')
check("C4 plain program LOAD keeps the store", msg == "LOADED" and store_state() == before and P.store() == ["x = 5", "y = 6"], "msg=%s" % msg)
# ---- failed program LOAD (wipe path = NEW state) must NOT wipe the store
P.shutdown()
t = tape([("ARR", A, {})])
fr = bytearray(TS.framed(0xFF, src)); fr[-1] ^= 0xFF
t.block(TS.framed(0, TS.header_payload(0, "PROG", len(src), autostart=K.FMT_WORD))); t.block(bytes(fr))
P.boot(t, lead=K.ARR_LEAD)
load('load "ARR" ARRAY a'); before = store_state()
P.put_store(["k = 1"])
msg = load('load "PROG"')
check("C5 a LOAD that fails mid-block (program wiped) leaves the store alone", msg == "LOAD_FAILED" and store_state() == before, "msg=%s" % msg)
P.shutdown()
print("ALL OK" if ok else "SOME FAILED")
