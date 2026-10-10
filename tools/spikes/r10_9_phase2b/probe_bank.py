"""Scratch probe (outside the repo): is EXROM paged in at every HOME hook candidate?
Run from the worktree root: python3 -I? no -- needs tools/ on path."""
import sys, os
sys.path.insert(0, "tools")
import v2_prod as P
from v2_headless import D, read

DEPTH = P.sym("BANK_EXROM_DEPTH")
SHADOW = P.sym("PORT_FF_SHADOW")
TARGETS = ["VM_INIT", "VM_CARVE_TABLES", "OP_DIM", "OP_DIM_STR", "VM_ARR_ADDR", "VM_STRARR_ADDR",
           "OP_CLEAR", "MEM_CLEAR_V2", "V2_CLEAR_ARRAYS", "MEM_INIT_V2"]

def snap(tag):
    d = read(DEPTH, 1)[0]; s = read(SHADOW, 1)[0]
    tx = D("timex")
    return "%-16s depth=%d shadow=%02X  timexFF=%s" % (tag, d, s, [l for l in tx['raw'].split(chr(10)) if 'FF port' in l])

def trace_run(entry, label, maxi=150_000_000):
    """call `entry`, stopping at each target hit once (re-arming), reporting state."""
    out = []
    a = P.sym(entry) if isinstance(entry, str) else entry
    import struct
    D("mem-write", "0xFF00", struct.pack("<H", P.RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(a))
    seen = set()
    for i in range(60):
        idx = 10
        for k, t in enumerate(TARGETS):
            if t not in seen:
                D("break", hex(P.sym(t)), "--index", str(idx + k))
        D("run", "--until", hex(P.IOK), "--max-instructions", str(maxi), t=1800)
        D("pause")
        pc = P.pc()
        hit = [t for t in TARGETS if P.sym(t) == pc]
        for k in range(len(TARGETS)):
            try: D("clear-break", "--index", str(idx + k))
            except Exception: pass
        if pc == P.IOK or not hit:
            break
        seen.add(hit[0])
        out.append(snap(hit[0]))
        # step past the breakpoint
        D("step")
    print("== %s" % label)
    for o in out: print("  ", o)
    print("   end pc=%04X vm_err=%d" % (P.pc(), read(P.sym("VM_ERROR_CODE"),1)[0]))

P.boot()
print("idle prompt:", snap("prompt"))
P.put_store(["DIM a(3)", "a(1) = 5", "DIM b$(2,8)", "y = a(1)", "CLEAR"])
trace_run("V2_RUN_STORED", "RUN (stored program with DIM, DIM$, array access, CLEAR)")
# immediate statement
P.poke(P.sym("EDIT_LINE_BUF"), b": DIM q(4)\0")
ae0 = P.w16(P.sym("ARRAYS_END"))
trace_run("V2_DISPATCH", "immediate statement ': DIM q(4)'")
print("   ARRAYS_END before/after:", hex(ae0), hex(P.w16(P.sym("ARRAYS_END"))), "compile_err", read(P.sym("COMPILE_ERROR_CODE"),1)[0])
P.shutdown()
