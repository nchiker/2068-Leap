import sys, struct, re
sys.path.insert(0, "tools")
import v2_prod as P
from v2_headless import D, read
def ts_of(r):
    return D("step", "--count", "1")["registers"]["TSTATES"]
def entry(name, count=1):
    nm = name.encode(); desc = bytes([1]) + struct.pack("<H", count) + bytes(2 * count)
    return struct.pack("<H", 4 + len(nm) + len(desc)) + bytes([2, len(nm)]) + nm + desc
def measure(nent, nsym, declare):
    """T-states spent in ARR_RUN_INIT: run it continuously and combine the ISR frame
    counter (FRAMES, +1 per 69,888 T) with the per-frame T-state counter."""
    P.boot()
    blob = b"".join(entry("e%d" % i) for i in range(nent))
    P.poke(0xE000, blob); P.poke16(P.sym("PAS_END"), 0xE000 + len(blob))
    prog = ["DIM e%d(1)" % i for i in range(declare)] + ["v%d = 1" % i for i in range(nsym)]
    P.put_store(prog)
    D("mem-write", "0xFF00", struct.pack("<H", P.RET).hex()); D("set-register", "SP", "0xFF00"); D("set-register", "PC", hex(P.sym("V2_RUN_STORED")))
    D("run", "--until", hex(P.sym("ARR_RUN_INIT")), "--max-instructions", "150000000", t=1800)
    sp = P.regs()["SP"]; ret = struct.unpack("<H", read(sp, 2))[0]
    f0 = P.w16(P.sym("FRAMES")); t0 = D("step", "--count", "1")["registers"]["TSTATES"]
    D("run", "--until", hex(ret), "--max-instructions", "400000000", t=3000)
    f1 = P.w16(P.sym("FRAMES")); t1 = D("step", "--count", "1")["registers"]["TSTATES"]
    ve = read(P.sym("VM_ERROR_CODE"), 1)[0]
    P.shutdown()
    return ((f1 - f0) & 0xFFFF) * 69888 + (t1 - t0), ve
for (ne, ns, dc) in [(0, 10, 0), (3, 10, 3), (20, 120, 5), (100, 200, 0), (100, 200, 100)]:
    t, ve = measure(ne, ns, dc)
    print("entries=%3d symbols=%3d declared=%3d : ARR_RUN_INIT = %8d T-states (%.1f ms @3.528 MHz) vm_err=%d" % (ne, ns, dc, t, t / 3528.0, ve), flush=True)
