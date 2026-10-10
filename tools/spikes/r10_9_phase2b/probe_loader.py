"""Functional probe of the prototype store LOADER / SAVER (scratch, outside the repo)."""
import sys, struct
sys.path.insert(0, "tools")
import v2_prod as P
import tape_synth as TS
import v2_known_defects as K
from v2_headless import D, read

BASE = 0xE000
def u16(v): return struct.pack("<H", v)
def num(vals): return bytes([1]) + u16(len(vals)) + b"".join(u16(v) for v in vals)
def strd(width, elems):
    body = b""
    for e in elems:
        e = e.encode(); body += bytes([len(e)]) + e + bytes(width - 1 - len(e))
    return bytes([1]) + u16(len(elems)) + bytes([width]) + body
def tape(files, bad_checksum=None):
    t = TS.Tape()
    for i, (name, body, kw) in enumerate(files):
        t.block(TS.framed(0, TS.header_payload(8, name, kw.get("length", len(body)), autostart=kw.get("word", K.FMT_WORD))))
        fr = bytearray(TS.framed(0xFF, body))
        if kw.get("bad_checksum"): fr[-1] ^= 0xFF
        t.block(bytes(fr))
        t.silence(0.5)
    return t
def store_state():
    end = P.w16(P.sym("PAS_END"))
    return end, (read(BASE, end - BASE) if end > BASE else b"")
def load(cmd, maxi=900_000_000):
    P.poke(P.sym("EDIT_LINE_BUF"), cmd.encode() + b"\0")
    return P.call_prompt("V2_DISPATCH", maxi=maxi)
def run_prog(prog):
    P.put_store(prog)
    P.call_prompt("V2_RUN_STORED")
    return read(P.sym("COMPILE_ERROR_CODE"), 1)[0], read(P.sym("VM_ERROR_CODE"), 1)[0]
def entry(name, kind, desc):
    nm = name.encode(); return u16(4 + len(nm) + len(desc)) + bytes([kind, len(nm)]) + nm + desc
ok = True
def check(name, cond, detail=""):
    global ok; ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + name + ("  " + detail if detail else ""), flush=True)

A = num([0, 0, 33, 0, 0])
# --- L1/L2/L3: load at the prompt, no prior RUN; the program sees it
P.boot(tape([("ARR", A, {}), ("TEMP", A, {})]), lead=K.ARR_LEAD)
end0, _ = store_state()
msg = load('load "ARR" ARRAY a')
end, st = store_state()
check("L1 LOAD ... ARRAY into the store, no prior compile", msg == "LOADED" and end == BASE + 4 + 1 + len(A) and st == entry("a", 2, A), "msg=%s end=%04X (init %04X)" % (msg, end, end0))
ce, ve = run_prog(["DIM a(5)", "y = a(2)"])
check("L1b RUN sees the loaded array (DIM adopts)", ce == 0 and ve == 0 and P.variables(1)[0][1] == 33, "y=%d ve=%d" % (P.variables(1)[0][1], ve))
ce, ve = run_prog(["GOTO s", "DIM a(5)", "s:", "y = a(2)"])
check("L2 D6 shape (DIM skipped) sees the loaded array", ce == 0 and ve == 0 and P.variables(1)[0][1] == 33, "y=%d ve=%d" % (P.variables(1)[0][1], ve))
msg = load('load "TEMP" ARRAY temperature')
end2, st2 = store_state()
check("L3 an 11-character array name loads (D14)", msg == "LOADED" and st2.endswith(entry("temperature", 2, A)), "msg=%s" % msg)
ce, ve = run_prog(["DIM temperature(5)", "y = temperature(2)"])
check("L3b ... and the program reaches it", ve == 0 and P.variables(1)[0][1] == 33)
# --- L7: SAVE from the store (no RUN since an edit) and from the live array
ce, ve = run_prog(["y = 1"])         # a different program: symbol table no longer knows `a`
blocks, msg = P.capture_save('save "OUT" ARRAY a')
hdr = blocks[0][1] if blocks else b""
check("L7 SAVE ... ARRAY served from the store: type-8 header, body = descriptor", msg == "SAVED" and len(blocks) == 2 and hdr[0] == 8 and blocks[1][1] == A and hdr[13:15] == u16(K.FMT_WORD) , "msg=%s type=%s" % (msg, hdr[:1].hex()))
run_prog(["DIM a(5)", "y = a(2)"])
blocks, msg = P.capture_save('save "OUT" ARRAY a')
check("L7b SAVE ... ARRAY of the live (bound) array: type 8, same body", msg == "SAVED" and len(blocks) == 2 and blocks[0][1][0] == 8 and blocks[1][1] == A)
# --- L8: NEW clears the store
msg = load("new")
end, st = store_state()
check("L8 NEW clears the store", end == BASE and st == b"", "end=%04X" % end)
P.shutdown()

# --- L4: replace in the middle keeps order and other entries
B = num([7, 8, 9])
A2 = num([0, 0, 44, 0, 0])
P.boot(tape([("ARR", A, {}), ("BEE", B, {}), ("ARR", A2, {})]), lead=K.ARR_LEAD)
load('load "ARR" ARRAY a'); load('load "BEE" ARRAY b'); e1, s1 = store_state()
msg = load('load "ARR" ARRAY a')
e2, s2 = store_state()
want = entry("b", 2, B) + entry("a", 2, A2)
check("L4 same-name LOAD replaces atomically (others kept, new at the end)", msg == "LOADED" and s2 == want and e2 == BASE + len(want), "msg=%s len=%d want=%d" % (msg, e2 - BASE, len(want)))
ce, ve = run_prog(["DIM a(5)", "DIM b(3)", "y = a(2)", "z = b(1)"])
v = P.variables(2)
check("L4b both arrays bound to the right descriptors after compaction", ve == 0 and v[0][1] == 44 and v[1][1] == 8, "y=%d z=%d" % (v[0][1], v[1][1]))
P.shutdown()

# --- L5: string arrays
S = strd(6, ["", "abc"])
P.boot(tape([("STR", S, {})]), lead=K.ARR_LEAD)
msg = load('load "STR" ARRAY s$')
e, st = store_state()
check("L5 string array loads", msg == "LOADED" and st == entry("s", 3, S), "msg=%s" % msg)
ce, ve = run_prog(["DIM s$(2,6)", "y = LEN(s$(1))"])
check("L5b DIM adopts the string array", ve == 0 and P.variables(1)[0][1] == 3, "y=%d ve=%d" % (P.variables(1)[0][1], ve))
P.shutdown()

# --- L6: corrupt / incompatible tapes: store untouched, distinct messages
cases = [
  ("dim_count 7", ("ARR", bytes([7]) + A[1:], {}), "a", "BAD_ARRAY"),
  ("count 0", ("ARR", bytes([1, 0, 0]), {}), "a", "BAD_ARRAY"),
  ("count 100 but 11 bytes", ("ARR", K.num_desc(100, data_len=8), {}), "a", "BAD_ARRAY"),
  ("length != 3+2n (extra byte)", ("ARR", A + b"\0", {}), "a", "BAD_ARRAY"),
  ("string into numeric", ("ARR", S, {}), "a", "BAD_ARRAY"),
  ("numeric into string", ("ARR", A, {}), "s$", "BAD_ARRAY"),
  ("string width 1", ("ARR", bytes([1]) + u16(2) + bytes([1]) + b"\0\0", {}), "s$", "BAD_ARRAY"),
  ("string element len 40 (> 31)", ("ARR", bytes([1]) + u16(1) + bytes([60]) + bytes([40]) + bytes(59), {}), "s$", "BAD_ARRAY"),
  ("string element len >= width", ("ARR", bytes([1]) + u16(1) + bytes([4]) + bytes([4, 1, 2, 3]), {}), "s$", "BAD_ARRAY"),
  ("bad checksum", ("ARR", A, {"bad_checksum": True}), "a", "LOAD_FAILED"),
  ("unsupported version word", ("ARR", A, {"word": 0x8200}), "a", "BAD_VERSION"),
]
for title, f, nm, want_msg in cases:
    P.boot(tape([("PRE", B, {}), f]), lead=K.ARR_LEAD)
    load('load "PRE" ARRAY b')
    before = store_state()
    msg = load('load "ARR" ARRAY %s' % nm)
    after = store_state()
    check("L6 %-32s -> %s, store untouched" % (title, want_msg), msg == want_msg and after == before, "msg=%s same=%s" % (msg, after == before))
    P.shutdown()

# --- L9: store full
P.boot(tape([("ARR", A, {})]), lead=K.ARR_LEAD)
P.poke16(P.sym("PAS_END"), 0xE800 - 12)
msg = load('load "ARR" ARRAY a')
check("L9 tape larger than the free store -> refused, PAS_END unchanged", msg in ("STORE_FULL", "LOAD_FAILED") and P.w16(P.sym("PAS_END")) == 0xE800 - 12, "msg=%s (transport cannot name 'too long')" % msg)
P.shutdown()
P.boot(tape([("ARR", A, {})]), lead=K.ARR_LEAD)
P.poke16(P.sym("PAS_END"), 0xE800 - 4)
msg = load('load "ARR" ARRAY a')
check("L9b no room even for the entry header -> ARRAY STORE FULL", msg == "STORE_FULL" and P.w16(P.sym("PAS_END")) == 0xE800 - 4, "msg=%s" % msg)
P.shutdown()
print("ALL OK" if ok else "SOME FAILED")
