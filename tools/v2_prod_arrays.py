#!/usr/bin/env python3
"""R10.9 Phase 2C -- production-ROM gate for the persistent Array Store (architecture C).

Every case runs on the real production image (`build/ts2068rom_zesarux.bin`: HOME + EXROM as
shipped) through tools/v2_prod.py; see that module and docs/TESTING.md for what is real
(compiler, VM, the EXROM DIM handlers, the Array Store service, the tape receiver reading a
synthesised EAR line) and what is substituted.  These are GATE cases: each must PASS.  The
former known defects D6, D8, D12, D13, D14, D15 and D16 live here now, as the fixed
behaviour, together with the lifecycle / boundary / banking cases of the Phase 2B proposal.

Store layout under test (rom/exrom_v2_arrstore.asm): segment 2 from $E000 to PAS_END,
entry = [len:2][kind:1 (2 numeric | 3 string)][namelen:1][name][descriptor], descriptor = the
tape body verbatim.  "Hand-built" stores are written straight into RAM with PAS_END set.

Usage: python3 tools/v2_prod_arrays.py [substring ...]   (after `make build`)
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402
import tape_synth as TS          # noqa: E402

BASE, LIMIT = 0xE000, 0xE800
ARRAY_TYPE = 8
FMT_WORD = TS._abi().fmt_word
LEAD = P.CPU_BOOT_T + 3_000_000


# ------------------------------------------------------------------ builders
def u16(v):
    return struct.pack("<H", v)


def num(vals):
    return bytes([1]) + u16(len(vals)) + b"".join(u16(v) for v in vals)


def strd(width, elems):
    body = b""
    for e in elems:
        e = e.encode()
        body += bytes([len(e)]) + e + bytes(width - 1 - len(e))
    return bytes([1]) + u16(len(elems)) + bytes([width]) + body


def entry(name, kind, desc):
    nm = name.encode()
    return u16(4 + len(nm) + len(desc)) + bytes([kind, len(nm)]) + nm + desc


def tape(files):
    """files = [(tape name, body, opts)]; opts: length, word, htype, bad_checksum."""
    t = TS.Tape()
    for name, body, kw in files:
        t.block(TS.framed(0, TS.header_payload(kw.get("htype", ARRAY_TYPE), name, kw.get("length", len(body)),
                                               autostart=kw.get("word", FMT_WORD))))
        fr = bytearray(TS.framed(0xFF, body))
        if kw.get("bad_checksum"):
            fr[-1] ^= 0xFF
        t.block(bytes(fr))
        t.silence(0.5)
    return t


def pas_end():
    return P.w16(P.sym("PAS_END"))


def store_state():
    end = pas_end()
    return end, (P.read(BASE, end - BASE) if end > BASE else b"")


def set_store(entries):
    blob = b"".join(entries)
    P.poke(BASE, blob)
    P.poke16(P.sym("PAS_END"), BASE + len(blob))
    return blob


def typed(cmd, maxi=900_000_000):
    P.poke(P.sym("EDIT_LINE_BUF"), cmd.encode() + b"\0")
    return P.call_prompt("V2_DISPATCH", maxi=maxi)


def run_prog(prog, times=1):
    P.put_store(prog)
    for _ in range(times):
        P.call_prompt("V2_RUN_STORED")
    return P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0], P.read(P.sym("VM_ERROR_CODE"), 1)[0]


def vals(n):
    return [v for _, v in P.variables(n)]


def boot_store(entries, prog=None):
    P.boot()
    blob = set_store(entries) if entries else b""
    if prog:
        P.put_store(prog)
    return blob


def slot(kind_string=False, idx=0):
    return P.w16(P.w16(P.sym("RT_STRARRPTR_PTR" if kind_string else "RT_ARRPTR_PTR")) + 2 * idx)


A5 = num([0, 0, 33, 0, 0])


# ===================================================== D6 + bind / adopt / persist
@case("D6-array-load-survives-run", "LOAD ... ARRAY data is still there when the program runs (DIM skipped)")
def d6():
    P.boot(tape([("ARR", A5, {})]), lead=LEAD)
    run_prog(["GOTO s", "DIM a(5)", "s:", "y = a(2)"])            # compile once, as the old defect case did
    m = typed('load "ARR" ARRAY a')
    ce, ve = run_prog(["GOTO s", "DIM a(5)", "s:", "y = a(2)"])
    return m == "LOADED" and ce == 0 and ve == 0 and vals(1)[0] == 33, "load=%s compile_err=%d vm_err=%d y=%d" % (m, ce, ve, vals(1)[0])


@case("arr-coldboot-empty", "a cold boot starts with an empty Array Store (PAS_END = $E000)")
def coldboot():
    P.boot()
    return pas_end() == BASE, "PAS_END=%04X" % pas_end()


@case("arr-load-no-prior-compile", "LOAD ... ARRAY works at the prompt with no earlier RUN; the program's DIM adopts it")
def load_no_compile():
    P.boot(tape([("ARR", A5, {})]), lead=LEAD)
    m = typed('load "ARR" ARRAY a')
    end, st = store_state()
    ce, ve = run_prog(["DIM a(5)", "y = a(2)"])
    return m == "LOADED" and st == entry("a", 2, A5) and ce == 0 and ve == 0 and vals(1)[0] == 33, \
        "msg=%s store_ok=%s vm_err=%d y=%d" % (m, st == entry("a", 2, A5), ve, vals(1)[0])


@case("arr-adopt-numeric", "DIM adopts a stored numeric array without clearing it; the store bytes are untouched by a read")
def adopt_num():
    blob = boot_store([entry("A", 2, A5)], ["DIM a(5)", "y = a(2)"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    after = P.read(BASE, len(blob))
    return ve == 0 and vals(1)[0] == 33 and after == blob and slot() == BASE + 5, \
        "vm_err=%d y=%d store_unchanged=%s slot=%04X (want %04X)" % (ve, vals(1)[0], after == blob, slot(), BASE + 5)


@case("arr-run-repeat-x3", "a value written in one RUN is read by the next RUN and is visible in the store bytes")
def repeat_runs():
    blob = boot_store([entry("A", 2, A5)], ["DIM a(5)", "y = a(2)", "a(2) = 44"])
    ys = []
    for _ in range(3):
        P.call_prompt("V2_RUN_STORED")
        ys.append(vals(1)[0])
    elem2 = P.read(BASE + 4 + 1 + 3 + 4, 2)
    return ys == [33, 44, 44] and elem2 == u16(44), "y per RUN=%s element in store=%s" % (ys, elem2.hex())


@case("arr-adopt-string", "DIM adopts a stored string array; a write persists into the next RUN")
def adopt_str():
    S = strd(6, ["", "abc"])
    boot_store([entry("S", 3, S)], ['DIM s$(2,6)', "y = LEN(s$(1))", 's$(1) = "hello"'])
    ys = []
    for _ in range(2):
        P.call_prompt("V2_RUN_STORED")
        ys.append(vals(1)[0])
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 0 and ys == [3, 5], "vm_err=%d LEN(s$(1)) per RUN=%s" % (ve, ys)


@case("arr-jump-over-dim", "stored arrays are bound even when the program jumps over its DIM (numeric and string)")
def jump_over():
    S = strd(6, ["", "abc"])
    boot_store([entry("a", 2, A5), entry("s", 3, S)],
               ["GOTO t", "DIM a(5)", "DIM s$(2,6)", "t:", "y = a(2)", "z = LEN(s$(1))"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    v = vals(2)
    return ve == 0 and v == [33, 3], "vm_err=%d y,z=%s" % (ve, v)


@case("arr-mismatch-size", "a stored array whose size differs from the DIM stops the RUN at initialisation (error 65), store intact")
def mismatch_size():
    blob = boot_store([entry("A", 2, A5)], ["y = 7", "DIM a(6)", "y = 8"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 65 and vals(1)[0] == 0 and P.read(BASE, len(blob)) == blob, \
        "vm_err=%d y=%d (first statement must not run)" % (ve, vals(1)[0])


@case("arr-mismatch-size-smaller", "stored count larger than the declared size is also refused")
def mismatch_larger():
    blob = boot_store([entry("A", 2, num(list(range(9))))], ["y = 7", "DIM a(5)"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 65 and vals(1)[0] == 0 and P.read(BASE, len(blob)) == blob, "vm_err=%d y=%d" % (ve, vals(1)[0])


@case("arr-mismatch-width", "a stored string array of another width is refused at initialisation (error 65)")
def mismatch_width():
    blob = boot_store([entry("S", 3, strd(7, ["", "abc"]))], ["y = 7", "DIM s$(2,6)"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 65 and vals(1)[0] == 0 and P.read(BASE, len(blob)) == blob, "vm_err=%d y=%d" % (ve, vals(1)[0])


@case("arr-mismatch-jump-over-dim", "a program that jumps over a mismatching DIM is still refused (validation is not bypassable)")
def mismatch_jump():
    blob = boot_store([entry("A", 2, A5)], ["y = 7", "GOTO t", "DIM a(6)", "t:", "z = a(1)"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 65 and vals(2) == [0, 0] and P.read(BASE, len(blob)) == blob, "vm_err=%d vars=%s" % (ve, vals(2))


@case("arr-session-immediate-dim-mismatch", "RC (session): an immediate DIM that mismatches a stored array is refused (65), the session survives")
def session_dim_mismatch():
    blob = boot_store([entry("B", 2, A5)], ["x = 7"])
    P.call_prompt("V2_RUN_STORED")
    typed(":DIM b(6)")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    typed(":y = x * 2")
    ve2 = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 65 and ve2 == 0 and vals(2) == [7, 14] and P.read(BASE, len(blob)) == blob, \
        "dim vm_err=%d then vm_err=%d vars=%s" % (ve, ve2, vals(2))


@case("arr-session-stored-array", "RC (session): an immediate statement reads and writes a stored array; the store keeps the value")
def session_stored_array():
    boot_store([entry("B", 2, A5)], ["DIM b(5)", "x = b(2)"])
    P.call_prompt("V2_RUN_STORED")
    typed(":b(3) = x + 40")
    typed(":y = b(3)")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    stored = P.read(BASE + 4 + 1 + 3 + 2 * 3, 2)
    return ve == 0 and vals(2)[1] == vals(2)[0] + 40 and stored == u16(vals(2)[1]), \
        "vm_err=%d vars=%s stored b(3)=%s" % (ve, vals(2), stored.hex())


@case("arr-message-65", "error 65 is reported as ARRAY SIZE MISMATCH")
def message_65():
    boot_store([entry("A", 2, A5)], ["DIM a(6)"])
    D("break", "V2_SHOW_MESSAGE", "--index", "2")
    try:
        msg = P.call_prompt("V2_RUN_STORED")
    finally:
        D("clear-break", "--index", "2")
    return msg == "ARRAY_SHAPE", "message=%s" % msg


@case("arr-kind-isolation", "a numeric and a string array of the same name are different store entries")
def kind_isolation():
    blob = boot_store([entry("a", 2, A5)], ["DIM a$(2,6)", "n = LEN(a$(1))", "DIM a(5)", "y = a(2)"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 0 and vals(2) == [0, 33] and P.read(BASE, len(blob)) == blob, "vm_err=%d n,y=%s" % (ve, vals(2))


@case("arr-name-case-folded", "store names match the program's identifiers case-insensitively")
def case_fold():
    boot_store([entry("temperature", 2, A5)], ["DIM TEMPERATURE(5)", "y = Temperature(2)"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 0 and vals(1)[0] == 33, "vm_err=%d y=%d" % (ve, vals(1)[0])


@case("arr-unrelated-inert", "an unrelated program ignores the store; its ordinary DIM is zero-filled over dirty RAM (D12)")
def unrelated():
    blob = boot_store([entry("A", 2, A5)], ["DIM b(4)", "y = b(2)"])
    ae = P.w16(P.sym("SYM_END_V")) + 1
    P.poke(ae, bytes([0xA5]) * 64)
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 0 and vals(1)[0] == 0 and P.read(BASE, len(blob)) == blob, "vm_err=%d y=%d" % (ve, vals(1)[0])


@case("arr-immediate-dim", "an immediate `: DIM a(5)` adopts the stored array in the very same way")
def immediate_dim():
    boot_store([entry("a", 2, A5)])
    P.poke(P.sym("EDIT_LINE_BUF"), b": DIM a(5)\0")
    P.call_prompt("V2_DISPATCH")
    s = slot()
    return s == BASE + 4 + 1, "slot=%04X (want %04X)" % (s, BASE + 5)


@case("arr-immediate-read", "an immediate `: y = a(2)` after a DIM reads the stored value")
def immediate_read():
    boot_store([entry("a", 2, A5)])
    P.poke(P.sym("EDIT_LINE_BUF"), b": DIM a(5) : y = a(2)\0")
    P.call_prompt("V2_DISPATCH")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 0 and vals(1)[0] == 33, "vm_err=%d y=%d" % (ve, vals(1)[0])


# ======================================================== coexistence with segment 2
@case("arr-overflow-coexist", "an overflow array placed in segment 2 lands above the store; the store is untouched")
def overflow_coexist():
    for pn in (3850, 3900, 3950):
        blob = boot_store([entry("A", 2, A5)], ["DIM p(%d)" % pn, "DIM q(600)", "q(1) = 9", "y = q(1)"])
        P.call_prompt("V2_RUN_STORED")
        ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
        q = P.w16(P.w16(P.sym("RT_ARRPTR_PTR")) + 2)
        if q >= BASE or ve == 64:
            break
    ok = ve == 0 and q >= BASE + len(blob) and vals(1)[0] == 9 and P.read(BASE, len(blob)) == blob \
        and P.w16(P.sym("ARR2_END")) >= pas_end()
    return ok, "p=%d vm_err=%d q=%04X y=%d ARR2_END=%04X PAS_END=%04X" % (
        pn, ve, q, vals(1)[0], P.w16(P.sym("ARR2_END")), pas_end())


@case("arr-overflow-exhaustion", "an overflow DIM that no longer fits next to a nearly full store fails cleanly, store intact")
def overflow_exhaustion():
    big = entry("big", 2, num([0] * 985))                 # 1,980 B of data: ~58 B of segment 2 left
    blob = boot_store([big], ["DIM p(3900)", "DIM q(600)", "q(1) = 9", "y = 1"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ve == 64 and vals(1)[0] == 0 and P.read(BASE, len(blob)) == blob and P.w16(P.sym("ARR2_END")) >= pas_end(), \
        "vm_err=%d (want 64) y=%d store_intact=%s" % (ve, vals(1)[0], P.read(BASE, len(blob)) == blob)


# ==================================================================== lifecycle
@case("arr-edit-keeps-store", "typing a program line keeps the store")
def edit_keeps():
    boot_store([entry("a", 2, A5)])
    before = store_state()
    P.type_text("q = 1")
    return store_state() == before and P.store() == ["q = 1"], "same=%s" % (store_state() == before)


@case("arr-immediate-keeps-store", "an immediate statement keeps the store")
def immediate_keeps():
    boot_store([entry("a", 2, A5)])
    before = store_state()
    P.poke(P.sym("EDIT_LINE_BUF"), b": q = 1\0")
    P.call_prompt("V2_DISPATCH")
    return store_state() == before, "same=%s" % (store_state() == before)


@case("arr-program-load-keeps-store", "a successful program LOAD keeps the store, and the new program binds it")
def program_load_keeps():
    src = TS.source_records(["DIM a(5)", "y = a(2)"])
    t = TS.Tape()
    t.block(TS.framed(0, TS.header_payload(0, "PROG", len(src), autostart=FMT_WORD)))
    t.block(TS.framed(0xFF, src))
    P.boot(t, lead=LEAD)
    set_store([entry("a", 2, A5)])
    before = store_state()
    m = typed('load "PROG"')
    kept = store_state() == before
    P.call_prompt("V2_RUN_STORED")
    return m == "LOADED" and kept and vals(1)[0] == 33, "msg=%s kept=%s y=%d" % (m, kept, vals(1)[0])


@case("arr-failed-program-load-keeps-store", "a program LOAD that fails mid-block (program wiped) leaves the store alone")
def failed_program_load():
    src = TS.source_records(["x = 5", "y = 6"])
    t = TS.Tape()
    t.block(TS.framed(0, TS.header_payload(0, "PROG", len(src), autostart=FMT_WORD)))
    fr = bytearray(TS.framed(0xFF, src))
    fr[-1] ^= 0xFF
    t.block(bytes(fr))
    P.boot(t, lead=LEAD)
    set_store([entry("a", 2, A5)])
    P.put_store(["k = 1"])
    before = store_state()
    m = typed('load "PROG"')
    wiped = P.w16(P.sym("PROG_END")) == P.sym("PROG_AREA_START")
    return m == "LOAD_FAILED" and store_state() == before and wiped, \
        "msg=%s store_kept=%s program_wiped=%s" % (m, store_state() == before, wiped)


@case("arr-new-clears", "NEW clears the store (and only NEW does)")
def new_clears():
    boot_store([entry("a", 2, A5), entry("b", 2, A5)])
    m = typed("new")
    end, st = store_state()
    ce, ve = run_prog(["DIM a(5)", "y = a(2)"])
    return end == BASE and st == b"" and ce == 0 and ve == 0 and vals(1)[0] == 0, \
        "PAS_END=%04X y after NEW=%d (ordinary zero array)" % (end, vals(1)[0])


# ======================================================================= CLEAR (D8)
@case("D8-clear-resets-scalars", "CLEAR resets scalar variables and keeps the program running")
def d8_scalars():
    ce, ve, msg = P.run_program(["s = 5", "CLEAR", "y = s + 1"])
    v = vals(2)
    return ce == 0 and ve == 0 and v == [0, 1], "compile_err=%d vm_err=%d s,y=%s (want [0, 1])" % (ce, ve, v)


@case("D8-clear-resets-strings", "CLEAR empties string variables")
def d8_strings():
    ce, ve, msg = P.run_program(['a$ = "abc"', "CLEAR", "n = LEN(a$)", "m = 7"])
    v = vals(2)
    return ce == 0 and ve == 0 and v == [0, 7], "compile_err=%d vm_err=%d n,m=%s" % (ce, ve, v)


@case("D8-clear-keeps-package", "CLEAR does not unregister loaded packages")
def d8_pkg():
    P.boot()
    assert P.install_package("shapes")
    P.put_store(["CLEAR", "CIRCLE 100,90,10"])
    P.call_prompt("V2_RUN_STORED")
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    plen = P.w16(P.sym("V2_PACKAGE_LEN"))
    return ce == 0 and ve == 0 and plen != 0, "compile_err=%d vm_err=%d package_len=%d" % (ce, ve, plen)


@case("D8-clear-keeps-symbols", "CLEAR leaves the compile symbol table and run tables valid (later code still works)")
def d8_symbols():
    P.boot()
    P.put_store(["a = 1", "b = 2", "CLEAR", "c = 3", "d = c + 4", 'e$ = "x"', "f = LEN(e$)"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    vs, ve_, vp = P.w16(P.sym("VARS_START")), P.w16(P.sym("SYM_END_V")), P.w16(P.sym("RT_SYMTAB_PTR"))
    v = vals(5)
    return ve == 0 and v == [0, 0, 3, 7, 1], \
        "vm_err=%d vars=%s VARS_START=%04X RT_SYMTAB=%04X" % (ve, v, vs, vp)


@case("arr-clear-keeps-store", "CLEAR keeps the store byte-identical and the stored array stays reachable")
def clear_keeps():
    blob = boot_store([entry("a", 2, A5)], ["DIM a(5)", "a(1) = 5", "CLEAR", "y = a(2)", "z = a(1)"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    store_now = P.read(BASE, len(blob))
    return ve == 0 and vals(2) == [33, 5] and store_now == entry("a", 2, num([0, 5, 33, 0, 0])) \
        and pas_end() == BASE + len(blob) and P.w16(P.sym("ARR2_END")) >= pas_end(), \
        "vm_err=%d y,z=%s (stored data survives CLEAR; write-through preserved)" % (ve, vals(2))


@case("arr-clear-redim-adopts", "after CLEAR a re-executed DIM of a stored name adopts it again, data intact")
def clear_redim():
    # `top:` is jumped back to after CLEAR; the loop counter lives in the stored array f(0) (CLEAR zeroes scalars)
    f = entry("f", 2, num([0, 0, 0]))
    a = entry("a", 2, A5)
    boot_store([f, a], ["DIM f(3)", "top:", "DIM a(5)", "f(f(0) + 1) = a(2)", "a(2) = 9", "f(0) = f(0) + 1", "CLEAR",
                        "IF f(0) < 2 THEN GOTO top"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    store_now = P.read(BASE, pas_end() - BASE)
    want = entry("f", 2, num([2, 33, 9])) + entry("a", 2, num([0, 0, 9, 0, 0]))
    return ve == 0 and store_now == want, "vm_err=%d store_ok=%s store=%s" % (ve, store_now == want, store_now.hex())


@case("arr-clear-ordinary-zeroed", "CLEAR discards an ordinary array: the re-executed DIM yields zeros again")
def clear_ordinary():
    f = entry("f", 2, num([0, 0, 0]))
    boot_store([f], ["DIM f(3)", "top:", "DIM b(4)", "f(f(0) + 1) = b(1)", "b(1) = 8", "f(0) = f(0) + 1", "CLEAR",
                     "IF f(0) < 2 THEN GOTO top"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    store_now = P.read(BASE, pas_end() - BASE)
    want = entry("f", 2, num([2, 0, 0]))
    return ce == 0 and ve == 0 and store_now == want, "compile_err=%d vm_err=%d store=%s (want %s)" % (ce, ve, store_now.hex(), want.hex())


@case("arr-clear-then-read-ordinary", "an ordinary array read straight after CLEAR (no DIM) is the 'never DIM'd' runtime error")
def clear_ordinary_read():
    ce, ve, msg = P.run_program(["DIM b(4)", "b(1) = 8", "CLEAR", "y = b(1)"])
    return ce == 0 and ve != 0, "compile_err=%d vm_err=%d" % (ce, ve)


# ===================================================================== D12 DIM zero
def _run_n(prog, n):
    P.boot()
    P.put_store(prog)
    out = []
    for _ in range(n):
        P.call_prompt("V2_RUN_STORED")
        assert P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0] == 0
        out.append(P.variables(1)[0][1])
    return out


@case("D12-dim-zero-repeat-run", "numeric DIM yields zeros on every RUN")
def d12_num_repeat():
    ys = _run_n(["DIM a(5)", "y = a(2)", "a(2) = 33"], 3)
    return ys == [0, 0, 0], "y per RUN = %s" % ys


@case("D12-dim-zero-dirty-ram", "numeric DIM over dirty RAM yields zeros")
def d12_num_dirty():
    P.boot()
    P.put_store(["DIM a(5)", "y = a(2)", "z = a(0)"])
    lo = P.w16(P.sym("PROG_END")) + 4
    P.poke(lo, bytes([0xA5]) * (0xA000 - lo))
    P.call_prompt("V2_RUN_STORED")
    v = vals(2)
    return P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0] == 0 and v == [0, 0], "a(2),a(0)=%s" % v


@case("D12-dim-str-zero-repeat-run", "string DIM yields empty elements on every RUN")
def d12_str_repeat():
    ns = _run_n(["DIM s$(3)", "n = LEN(s$(1))", 's$(1) = "hello"'], 3)
    return ns == [0, 0, 0], "LEN(s$(1)) per RUN = %s" % ns


@case("D12-dim-str-zero-dirty-ram", "string DIM over dirty RAM yields empty elements")
def d12_str_dirty():
    P.boot()
    P.put_store(["DIM s$(3)", "n = LEN(s$(1))"])
    lo = P.w16(P.sym("PROG_END")) + 4
    P.poke(lo, bytes([0x05]) * (0xA000 - lo))
    P.call_prompt("V2_RUN_STORED")
    n = vals(1)[0]
    return P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0] == 0 and n == 0, "LEN(s$(1))=%d" % n


@case("arr-nested-kind", "an array access whose subscript or value reads an array of the other kind keeps its own kind")
def arr_nested_kind():
    ce, ve, msg = P.run_program([
        "DIM names$(3)", "DIM pick(3)", 'names$(2) = "ccc"', "pick(0) = 2",
        "a = LEN(names$(pick(0)))",
        'names$(pick(0)) = "dddd"', "b = LEN(names$(2))",
        "pick(1) = LEN(names$(pick(0)))", "c = pick(1)",
        "pick(LEN(names$(0)) + 2) = 9", "d = pick(2)",
        "names$(1) = names$(pick(0))", "e = LEN(names$(1))"])
    v = vals(5) if ce == 0 and ve == 0 else None
    return v == [3, 4, 4, 9, 4], "compile_err=%d vm_err=%d msg=%s a..e=%s" % (ce, ve, msg, v)


@case("D12-dim-zero-overflow-segment", "an array placed in segment 2 is zero-filled too (dirty RAM at the segment base)")
def d12_overflow():
    for pn in (3850, 3900, 3950):
        P.boot()
        P.poke(BASE, bytes([0xA5]) * 1536)
        P.put_store(["DIM p(%d)" % pn, "DIM q(600)", "y = q(50)", "z = q(599)"])
        P.call_prompt("V2_RUN_STORED")
        q = P.w16(P.w16(P.sym("RT_ARRPTR_PTR")) + 2)
        ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
        if q >= BASE or ve == 64:
            break
    return ve == 0 and q >= BASE and vals(2)[:2] == [0, 0], "p=%d vm_err=%d q=%04X y,z=%s" % (pn, ve, q, vals(2))


# ================================================================ D13 SAVE ... ARRAY
def _save_live(prog, cmd):
    P.boot()
    P.put_store(prog)
    P.call_prompt("V2_RUN_STORED")
    assert P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0] == 0
    return P.capture_save(cmd)


def _hdr(blocks):
    h = blocks[0][1]
    return h[0], h[1:11], int.from_bytes(h[11:13], "little"), int.from_bytes(h[13:15], "little")


@case("D13-save-array-header-numeric", "SAVE ... ARRAY of a numeric array writes a TYPE-8 header (word $8100, length 3+2n)")
def d13_numeric():
    blocks, msg = _save_live(["DIM a(5)", "a(2) = 33"], 'save "ARR" ARRAY a')
    if msg != "SAVED" or len(blocks) != 2:
        return False, "msg=%s blocks=%d" % (msg, len(blocks))
    typ, name, length, word = _hdr(blocks)
    body = blocks[1][1]
    body_ok = body[:3] == bytes([1, 5, 0]) and body[7:9] == u16(33) and len(body) == 13
    return typ == ARRAY_TYPE and word == FMT_WORD and length == 13 and body_ok, \
        "type=%d word=%04X length=%d body_ok=%s" % (typ, word, length, body_ok)


@case("D13-save-array-header-string", "SAVE ... ARRAY of a string array writes a TYPE-8 header")
def d13_string():
    blocks, msg = _save_live(["DIM a$(2)", 'a$(1) = "hi"'], 'save "ARR" ARRAY a$')
    if msg != "SAVED" or len(blocks) != 2:
        return False, "msg=%s blocks=%d" % (msg, len(blocks))
    typ, name, length, word = _hdr(blocks)
    body = blocks[1][1]
    width = body[3]
    body_ok = body[:3] == bytes([1, 2, 0]) and width >= 2 and len(body) == 4 + 2 * width
    return typ == ARRAY_TYPE and word == FMT_WORD and length == len(body) and body_ok, \
        "type=%d word=%04X length=%d body_ok=%s" % (typ, word, length, body_ok)


def _replay(blocks):
    t = TS.Tape()
    for flag, payload in blocks:
        t.block(TS.framed(flag, payload))
    return t


@case("D13-array-tape-refused-by-plain-load", "an array tape written by SAVE ... ARRAY is REFUSED by plain LOAD (program intact)")
def d13_plain_load():
    blocks, msg = _save_live(["DIM a(5)", "a(2) = 33"], 'save "ARR" ARRAY a')
    prog = ["x = 1", "y = 2"]
    r = P.tape_op(_replay(blocks), existing=prog, name="ARR")
    return msg == "SAVED" and r["msg"] != "LOADED" and r["after"] == r["before"], \
        "plain LOAD msg=%s program_intact=%s header type=%d" % (r["msg"], r["after"] == r["before"], blocks[0][1][0])


@case("D13-own-array-tape-loads-as-array", "a tape written by SAVE ... ARRAY LOADs back with LOAD ... ARRAY into the store")
def d13_roundtrip():
    blocks, msg = _save_live(["DIM a(5)", "a(2) = 33"], 'save "ARR" ARRAY a')
    P.boot(_replay(blocks), lead=LEAD)
    m = typed('load "ARR" ARRAY a')
    end, st = store_state()
    ce, ve = run_prog(["DIM a(5)", "y = a(2)"])
    return msg == "SAVED" and m == "LOADED" and st[4 + 1:] == blocks[1][1] and ve == 0 and vals(1)[0] == 33, \
        "save=%s load=%s vm_err=%d y=%d" % (msg, m, ve, vals(1)[0])


@case("arr-save-from-store", "SAVE ... ARRAY serves a stored array the program has not bound (type-8 header, body = descriptor)")
def save_from_store():
    S = strd(6, ["", "abc"])
    boot_store([entry("temperature", 2, A5), entry("s", 3, S)], ["y = 1"])
    P.call_prompt("V2_RUN_STORED")                      # a program that knows neither array
    b1, m1 = P.capture_save('save "OUT" ARRAY temperature')
    b2, m2 = P.capture_save('save "OUT" ARRAY s$')
    ok = m1 == "SAVED" and m2 == "SAVED" and len(b1) == 2 and len(b2) == 2 and b1[0][1][0] == ARRAY_TYPE \
        and b2[0][1][0] == ARRAY_TYPE and b1[1][1] == A5 and b2[1][1] == S and \
        int.from_bytes(b1[0][1][13:15], "little") == FMT_WORD
    return ok, "m1=%s m2=%s" % (m1, m2)


@case("arr-save-unknown", "SAVE ... ARRAY of a name that is neither live nor stored says ARRAY NOT DIMD")
def save_unknown():
    boot_store([entry("a", 2, A5)], ["y = 1"])
    blocks, msg = P.capture_save('save "OUT" ARRAY nothere')
    return msg == "ARRAY_NOT_DIMD" and blocks == [], "msg=%s blocks=%d" % (msg, len(blocks))


@case("arr-save-live-edited-store", "after an edit a stored array can still be SAVEd by name; the data is what the program wrote")
def save_after_edit():
    boot_store([entry("a", 2, A5)], ["DIM a(5)", "a(3) = 77"])
    P.call_prompt("V2_RUN_STORED")
    P.type_text("q = 1")                                # discards the compile symbols
    blocks, msg = P.capture_save('save "OUT" ARRAY a')
    want = num([0, 0, 33, 77, 0])
    return msg == "SAVED" and len(blocks) == 2 and blocks[1][1] == want, "msg=%s body=%s" % (msg, blocks[1][1].hex() if len(blocks) == 2 else "-")


# ================================================================== D14 long names
LONG31 = "abcdefghijklmnopqrstuvwxyz01234"


def _d14_save(name, ref):
    def fn():
        blocks, msg = _save_live(["DIM %s(5)" % name, "%s(2) = 33" % name], 'save "ARR" ARRAY %s' % ref)
        return msg == "SAVED" and len(blocks) == 2 and blocks[1][1][7:9] == u16(33), \
            "SAVE ARRAY %s (declared %s, %d chars): msg=%s" % (ref, name, len(name), msg)
    return fn


def _d14_load(name, ref):
    def fn():
        P.boot(tape([("ARR", A5, {})]), lead=LEAD)
        m = typed('load "ARR" ARRAY %s' % ref)
        end, st = store_state()
        ce, ve = run_prog(["DIM %s(5)" % name, "y = %s(2)" % name])
        return m == "LOADED" and st[4:4 + len(ref)] == ref.encode() and ve == 0 and vals(1)[0] == 33, \
            "LOAD ARRAY %s (%d chars): msg=%s vm_err=%d y=%d" % (ref, len(ref), m, ve, vals(1)[0])
    return fn


for _n, _t in ((8, "abcdefgh"), (9, "abcdefghi"), (11, "temperature"), (31, LONG31)):
    case("D14-save-name-%d" % _n, "SAVE ARRAY of a %d-character array name" % _n)(_d14_save(_t, _t))
    case("D14-load-name-%d" % _n, "LOAD ARRAY into a %d-character array name (store key, then the program reaches it)" % _n)(
        _d14_load(_t, _t))
case("D14-save-name-mixedcase", "SAVE ARRAY with a mixed-case long name, referenced in another case")(
    _d14_save("MixedCaseLongName", "mixedcaselongname"))
case("D14-load-name-mixedcase", "LOAD ARRAY with a mixed-case long name, referenced in another case")(
    _d14_load("MixedCaseLongName", "MIXEDCASELONGNAME"))


@case("D14-name-32-refused", "an array name over 31 characters is refused (no truncation to a different array)")
def d14_32():
    name = LONG31 + "5"
    P.boot(tape([("ARR", A5, {})]), lead=LEAD)
    before = store_state()
    m = typed('load "ARR" ARRAY %s' % name)
    return m != "LOADED" and store_state() == before, "msg=%s store_unchanged=%s" % (m, store_state() == before)


# ============================================================ D15 descriptor validation
def _load_one(body, cmd='load "ARR" ARRAY a', pre=None, **kw):
    """Boot with [pre-existing array tape] + `body` tape; load pre, then body.  Returns
    (msg, store before, store after)."""
    files = ([("PRE", num([7, 8, 9]), {})] if pre else []) + [("ARR", body, kw)]
    P.boot(tape(files), lead=LEAD)
    if pre:
        typed('load "PRE" ARRAY b')
    before = store_state()
    msg = typed(cmd)
    return msg, before, store_state()


@case("D15-control-numeric", "a well-formed numeric array tape LOADs (positive control)")
def d15_ctl_num():
    m, b, a = _load_one(A5)
    return m == "LOADED" and a[1] == entry("a", 2, A5), "msg=%s" % m


@case("D15-control-string", "a well-formed string array tape LOADs (positive control)")
def d15_ctl_str():
    S = strd(32, ["x", "yy", ""])
    m, b, a = _load_one(S, cmd='load "ARR" ARRAY a$')
    return m == "LOADED" and a[1] == entry("a", 3, S), "msg=%s" % m


def _d15(label, body, cmd='load "ARR" ARRAY a', want="BAD_ARRAY", title=None, **kw):
    @case("D15-" + label, title)
    def fn():
        m, b, a = _load_one(body, cmd=cmd, pre=True, **kw)
        return m == want and a == b, "msg=%s (want %s) store_unchanged=%s" % (m, want, a == b)
    return fn


_d15("dimcount-7", bytes([7]) + A5[1:], title="dim_count 7 is rejected (not rewritten)")
_d15("dimcount-0", bytes([0]) + A5[1:], title="dim_count 0 is rejected")
_d15("count-zero", bytes([1, 0, 0]), title="descriptor count 0")
_d15("len-count-mismatch", bytes([1]) + u16(100) + bytes(8), title="body length != 3+2*count (count 100, 8 data bytes)")
_d15("len-trailing-byte", A5 + b"\0", title="one trailing byte after a valid numeric descriptor")
_d15("len-below-descriptor", bytes([1, 5]), title="body shorter than the 3-byte descriptor header")
_d15("len-one-byte", bytes([1]), title="one-byte body")
_d15("numeric-into-string", num([1, 2, 3]), cmd='load "ARR" ARRAY a$', title="numeric body LOADed as a string array")
_d15("string-into-numeric", strd(4, ["a", "b"]), title="string body LOADed as a numeric array")
_d15("string-width-0", bytes([1]) + u16(2) + bytes([0]) + b"\0\0", cmd='load "ARR" ARRAY a$', title="string element width 0")
_d15("string-width-1", bytes([1]) + u16(2) + bytes([1]) + b"\0\0", cmd='load "ARR" ARRAY a$', title="string element width 1")
_d15("string-count-zero", bytes([1]) + u16(0) + bytes([8]), cmd='load "ARR" ARRAY a$', title="string array count 0")
_d15("string-elem-len-40", bytes([1]) + u16(1) + bytes([60]) + bytes([40]) + bytes(59), cmd='load "ARR" ARRAY a$',
     title="element length 40 (over the 31-character string limit) in a width-60 array")
_d15("string-elem-len-32", bytes([1]) + u16(1) + bytes([40]) + bytes([32]) + bytes(39), cmd='load "ARR" ARRAY a$',
     title="element length 32 (one over the limit)")
_d15("string-elem-len-ge-width", bytes([1]) + u16(1) + bytes([4]) + bytes([4, 1, 2, 3]), cmd='load "ARR" ARRAY a$',
     title="element length equal to the element width (capacity is width-1)")
_d15("string-late-bad-element", bytes([1]) + u16(3) + bytes([4]) + bytes([1, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0]),
     cmd='load "ARR" ARRAY a$', title="only the LAST element has a bad length byte")
_d15("string-body-short", bytes([1]) + u16(3) + bytes([8]) + bytes(8 * 2), cmd='load "ARR" ARRAY a$',
     title="string body shorter than count*width")
_d15("string-body-long", bytes([1]) + u16(2) + bytes([8]) + bytes(8 * 2 + 1), cmd='load "ARR" ARRAY a$',
     title="string body longer than count*width")
_d15("numeric-count-big", bytes([1]) + u16(0x7FFF) + bytes(10), title="count 32767 with a short body (no 16-bit wrap)")
_d15("string-count-wrap", bytes([1]) + u16(0x8000) + bytes([2]) + bytes(8), cmd='load "ARR" ARRAY a$',
     title="count*width wraps 16 bits")


@case("D15-string-boundary-accepted", "element length 31 in a width-33 array and width 255 with short strings are accepted")
def d15_boundary():
    S1 = bytes([1]) + u16(1) + bytes([33]) + bytes([31]) + bytes(b"x" * 31) + bytes(1)
    S2 = strd(255, ["", "abc"])
    P.boot(tape([("S1", S1, {}), ("S2", S2, {})]), lead=LEAD)
    m1 = typed('load "S1" ARRAY a$')
    m2 = typed('load "S2" ARRAY b$')
    end, st = store_state()
    return m1 == "LOADED" and m2 == "LOADED" and st == entry("a", 3, S1) + entry("b", 3, S2), "m1=%s m2=%s" % (m1, m2)


@case("D15-count-short", "descriptor count 2 against DIM a(5): refused at RUN initialisation (error 65), before the first statement")
def d15_short():
    P.boot(tape([("ARR", num([1, 2]), {})]), lead=LEAD)
    m = typed('load "ARR" ARRAY a')
    run_prog(["w = 4", "DIM a(5)", "y = a(4)"])
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return m == "LOADED" and ve == 65 and vals(2) == [0, 0], "load=%s vm_err=%d vars=%s" % (m, ve, vals(2))


@case("D15-count-long", "descriptor count 100 against DIM a(5): refused at RUN initialisation (error 65)")
def d15_long():
    P.boot(tape([("ARR", num(list(range(100))), {})]), lead=LEAD)
    m = typed('load "ARR" ARRAY a')
    run_prog(["w = 4", "DIM a(5)", "y = a(4)"])
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return m == "LOADED" and ve == 65 and vals(2) == [0, 0], "load=%s vm_err=%d vars=%s" % (m, ve, vals(2))


@case("D15-large-numeric", "numeric arrays of 8, 10, 100 and 1000 elements load, bind and read back (count >= 8 regression)")
def d15_large():
    sizes = (8, 10, 100, 255, 256, 1000)
    t = tape([("N%d" % n, num([(i * 3) & 0xFFFF for i in range(n)]), {}) for n in sizes])
    P.boot(t, lead=LEAD)
    ok = True
    d = []
    for n in sizes:
        P.poke16(P.sym("PAS_END"), BASE)
        m = typed('load "N%d" ARRAY a' % n)
        ce, ve = run_prog(["DIM a(%d)" % n, "y = a(%d)" % (n - 1)])
        good = m == "LOADED" and ve == 0 and vals(1)[0] == ((n - 1) * 3) & 0xFFFF
        ok &= good
        d.append("%d:%s" % (n, "ok" if good else (m, ve)))
    return ok, " ".join(str(x) for x in d)


# ============================================================ D16 version handling
@case("D16-array-bad-version", "an array tape with another format word reports BAD TAPE VERSION; the store is untouched")
def d16():
    results = []
    for word in (0x8200, 0x0000, 0x8000 | 0x0200):
        m, b, a = _load_one(A5, pre=True, word=word)
        results.append((m, a == b))
    ok = all(m == "BAD_VERSION" and same for m, same in results)
    return ok, "results=%s" % results


@case("D16-array-minor-ok", "an older/equal minor array format word is accepted (version rule unchanged)")
def d16_ok():
    m, b, a = _load_one(A5, word=FMT_WORD)
    return m == "LOADED", "msg=%s" % m


# ================================================= replacement, compaction, capacity
def _loaded_store(files, cmds):
    P.boot(tape(files), lead=LEAD)
    return [typed(c) for c in cmds]


@case("arr-replace-middle", "same-name LOAD replaces atomically: later entries slide down, the new entry goes last")
def replace_middle():
    A = A5
    B = num([7, 8, 9])
    C = num([4, 4])
    A2 = num([0, 0, 44, 0, 0])
    msgs = _loaded_store([("A", A, {}), ("B", B, {}), ("C", C, {}), ("A", A2, {})],
                         ['load "A" ARRAY a', 'load "B" ARRAY b', 'load "C" ARRAY c', 'load "A" ARRAY a'])
    end, st = store_state()
    want = entry("b", 2, B) + entry("c", 2, C) + entry("a", 2, A2)
    ce, ve = run_prog(["DIM a(5)", "DIM b(3)", "DIM c(2)", "x = a(2)", "y = b(1)", "z = c(0)"])
    return msgs == ["LOADED"] * 4 and st == want and end == BASE + len(want) and vals(3) == [44, 8, 4], \
        "msgs=%s store_ok=%s vals=%s" % (msgs, st == want, vals(3))


@case("arr-replace-sizes", "replacement works for a smaller, an equal and a larger descriptor, and in the last position")
def replace_sizes():
    out = []
    for label, new in (("smaller", num([1, 2])), ("equal", num([9, 9, 9])), ("larger", num(list(range(40))))):
        msgs = _loaded_store([("B", num([7, 8, 9]), {}), ("X", num([5]), {}), ("B", new, {})],
                             ['load "B" ARRAY b', 'load "X" ARRAY x', 'load "B" ARRAY b'])
        end, st = store_state()
        want = entry("x", 2, num([5])) + entry("b", 2, new)
        out.append((label, msgs == ["LOADED"] * 3 and st == want and end == BASE + len(want)))
        P.shutdown()
    msgs = _loaded_store([("B", num([7, 8, 9]), {}), ("B", num([1]), {})], ['load "B" ARRAY b', 'load "B" ARRAY b'])
    end, st = store_state()
    out.append(("only-entry", st == entry("b", 2, num([1])) and end == BASE + len(st)))
    return all(g for _, g in out), str(out)


@case("arr-replace-case-folded", "a same-name LOAD with another case replaces, never duplicates")
def replace_case():
    msgs = _loaded_store([("B", num([7, 8]), {}), ("B", num([1, 2, 3]), {})], ['load "B" ARRAY abc', 'load "B" ARRAY ABC'])
    end, st = store_state()
    return st == entry("ABC", 2, num([1, 2, 3])), "store=%s" % st.hex()


@case("arr-replace-kind-distinct", "a$ and a are different keys: loading one never replaces the other")
def replace_kind():
    S = strd(4, ["a"])
    msgs = _loaded_store([("N", A5, {}), ("S", S, {})], ['load "N" ARRAY a', 'load "S" ARRAY a$'])
    end, st = store_state()
    return st == entry("a", 2, A5) + entry("a", 3, S), "msgs=%s" % msgs


@case("arr-compact-then-run", "after replacing entry 1 of 3, every array binds to its own descriptor (no stale pointers)")
def compact_run():
    B, C = num([7, 8, 9]), num([4, 4])
    msgs = _loaded_store([("A", A5, {}), ("B", B, {}), ("C", C, {}), ("A", num([0, 0, 55, 0, 0]), {})],
                         ['load "A" ARRAY a', 'load "B" ARRAY b', 'load "C" ARRAY c', 'load "A" ARRAY a'])
    ce, ve = run_prog(["GOTO t", "DIM a(5)", "DIM b(3)", "DIM c(2)", "t:", "x = a(2)", "y = b(2)", "z = c(1)",
                       "a(0) = 1", "b(0) = 2", "c(0) = 3"], times=2)
    end, st = store_state()
    good = entry("b", 2, num([2, 8, 9])) + entry("c", 2, num([3, 4])) + entry("a", 2, num([1, 0, 55, 0, 0]))
    return ve == 0 and vals(3) == [55, 9, 4] and st == good, "vm_err=%d vals=%s store_ok=%s" % (ve, vals(3), st == good)


@case("arr-failed-replace-keeps-old", "a replacement tape that fails (checksum / malformed) leaves the old entry and every other entry intact")
def failed_replace():
    B = num([7, 8, 9])
    res = []
    for label, kw, body in (("checksum", {"bad_checksum": True}, num([1])), ("malformed", {}, bytes([1, 0, 0]))):
        msgs = _loaded_store([("A", A5, {}), ("B", B, {}), ("A", body, kw)],
                             ['load "A" ARRAY a', 'load "B" ARRAY b'])
        before = store_state()
        m = typed('load "A" ARRAY a')
        res.append((label, m, store_state() == before))
        P.shutdown()
    return all(m in ("LOAD_FAILED", "BAD_ARRAY") and same for _, m, same in res), str(res)


@case("arr-failed-tape-dropout", "a tape that drops out mid-body leaves the store, the program and the editor untouched")
def failed_dropout():
    t = tape([("PRE", num([7, 8, 9]), {})])
    t.block(TS.framed(0, TS.header_payload(ARRAY_TYPE, "ARR", len(A5), autostart=FMT_WORD)))
    fr = TS.framed(0xFF, A5)
    t.block(fr[:len(fr) // 2])                           # cut short
    P.boot(t, lead=LEAD)
    typed('load "PRE" ARRAY b')
    P.put_store(["k = 1"])
    before = store_state()
    m = typed('load "ARR" ARRAY a')
    return m == "LOAD_FAILED" and store_state() == before and P.store() == ["k = 1"], \
        "msg=%s store_same=%s program=%s" % (m, store_state() == before, P.store())


@case("arr-store-full-header", "no room for the entry header + descriptor: ARRAY STORE FULL, nothing written past the store")
def full_header():
    res = []
    for end in (LIMIT - 5, LIMIT - 4, LIMIT - 1):        # name "a": the descriptor would start at end+5
        P.boot(tape([("ARR", A5, {})]), lead=LEAD)
        guard = bytes([0xC3]) * 64
        P.poke(LIMIT, guard)                              # sprite-buffer side of the boundary
        P.poke16(P.sym("PAS_END"), end)
        m = typed('load "ARR" ARRAY a')
        res.append((hex(end), m, pas_end() == end and P.read(LIMIT, 64) == guard))
        P.shutdown()
    return all(m == "STORE_FULL" and g for _, m, g in res), str(res)


@case("arr-store-full-name31", "a 31-character key name at the end of the store cannot spill past $E800")
def full_name31():
    P.boot(tape([("ARR", A5, {})]), lead=LEAD)
    guard = bytes([0xC3]) * 64
    P.poke(LIMIT, guard)
    P.poke16(P.sym("PAS_END"), LIMIT - 8)
    m = typed('load "ARR" ARRAY %s' % LONG31)
    return m == "STORE_FULL" and pas_end() == LIMIT - 8 and P.read(LIMIT, 64) == guard, \
        "msg=%s guard_intact=%s" % (m, P.read(LIMIT, 64) == guard)


@case("arr-store-full-body", "a tape larger than the free store is refused cleanly, store and sprite buffers untouched")
def full_body():
    P.boot(tape([("ARR", num([1] * 40), {})]), lead=LEAD)
    guard = bytes([0xC3]) * 64
    P.poke(LIMIT, guard)
    P.poke16(P.sym("PAS_END"), LIMIT - 60)               # 60 free: header 5 + 55 for a 83-byte body
    P.poke(LIMIT - 60, bytes(60))
    m = typed('load "ARR" ARRAY a')
    return m in ("LOAD_FAILED", "STORE_FULL") and pas_end() == LIMIT - 60 and P.read(LIMIT, 64) == guard, \
        "msg=%s PAS_END=%04X guard_intact=%s" % (m, pas_end(), P.read(LIMIT, 64) == guard)


@case("arr-store-exact-fit", "an entry that exactly fills the store is accepted; one more element is refused")
def exact_fit():
    n_ok = (2048 - 8) // 2                               # entry = 8 + 2n with a 1-character name
    P.boot(tape([("FIT", num([i & 0xFF for i in range(n_ok)]), {}), ("TOO", num([1] * (n_ok + 1)), {})]), lead=LEAD)
    guard = bytes([0xC3]) * 64
    P.poke(LIMIT, guard)
    m1 = typed('load "FIT" ARRAY a')
    full = pas_end()
    P.poke16(P.sym("PAS_END"), BASE)
    m2 = typed('load "TOO" ARRAY a')
    return m1 == "LOADED" and full == LIMIT and m2 in ("LOAD_FAILED", "STORE_FULL") and pas_end() == BASE \
        and P.read(LIMIT, 64) == guard, "fit=%s end=%04X over=%s PAS_END=%04X" % (m1, full, m2, pas_end())


@case("arr-store-replace-peak", "replacement needs room for old+new together (atomicity): a same-size replace in a full store is refused")
def replace_peak():
    n = (2048 - 8) // 2
    big = num([i & 0xFF for i in range(n)])
    P.boot(tape([("A", big, {}), ("A", big, {})]), lead=LEAD)
    m1 = typed('load "A" ARRAY a')
    before = store_state()
    m2 = typed('load "A" ARRAY a')
    return m1 == "LOADED" and m2 in ("LOAD_FAILED", "STORE_FULL") and store_state() == before, "m1=%s m2=%s same=%s" % (m1, m2, store_state() == before)


# ==================================================================== banking
def _banking(entry_pc, targets):
    out = []
    D("mem-write", "0xFF00", struct.pack("<H", P.RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(entry_pc))
    seen = set()
    for _ in range(24):
        for k, t in enumerate(targets):
            if t not in seen:
                D("break", hex(P.sym(t)), "--index", str(10 + k))
        D("run", "--until", hex(P.IOK), "--max-instructions", "150000000", t=1800)
        D("pause")
        pc = P.pc()
        hit = [t for t in targets if P.sym(t) == pc]
        for k in range(len(targets)):
            try:
                D("clear-break", "--index", str(10 + k))
            except Exception:
                pass
        if pc == P.IOK or not hit:
            break
        seen.add(hit[0])
        out.append("%s depth=%d FF=%02X" % (hit[0], P.read(P.sym("BANK_EXROM_DEPTH"), 1)[0], P.read(P.sym("PORT_FF_SHADOW"), 1)[0]))
        D("step")
    return out


def _mapped(o):
    return all(("depth=1" in x or "depth=2" in x) and "FF=80" in x for x in o)


@case("arr-banking-sites", "EXROM is mapped at every Array Store site: RUN init, DIM, DIM$, CLEAR rebind")
def banking_run():
    boot_store([entry("a", 2, A5)], ["DIM a(5)", "DIM b$(2,8)", "y = a(2)", "CLEAR"])
    o = _banking(P.sym("V2_RUN_STORED"), ["ARR_RUN_INIT", "ARR_OP_DIM", "ARR_OP_DIM_STR", "ARR_DIM", "MEM_CLEAR_V2"])
    names = {x.split()[0] for x in o}
    return {"ARR_RUN_INIT", "ARR_OP_DIM", "ARR_OP_DIM_STR", "MEM_CLEAR_V2"} <= names and _mapped(o), "; ".join(o)


@case("arr-banking-immediate", "EXROM is mapped at the Array Store sites during an immediate statement")
def banking_imm():
    boot_store([entry("a", 2, A5)])
    P.poke(P.sym("EDIT_LINE_BUF"), b": DIM a(5)\0")
    o = _banking(P.sym("V2_DISPATCH"), ["ARR_RUN_INIT", "ARR_OP_DIM", "ARR_DIM"])
    return len(o) >= 2 and _mapped(o), "; ".join(o)


@case("arr-ktab-verify", "ARR_RUN_INIT begins with `call V2_VERIFY_KTAB` (the DIM slots bypass the usual trampoline)")
def ktab_verify():
    P.boot()
    code = P.read(P.sym("ARR_RUN_INIT"), 3)
    target = code[1] | code[2] << 8
    slots = P.read(P.sym("VM_OP_TABLE") + 2 * 63, 4)
    dim_slots = (slots[0] | slots[1] << 8, slots[2] | slots[3] << 8)
    # RC: the slots are the fixed ARRSVC entries (packed, no longer $C0E6/$C0E9); each must be `jp` to its handler
    fixed = (P.sym("V2_EXROM_ARR_DIM_ADDR"), P.sym("V2_EXROM_ARR_DIM_STR_ADDR"))
    jumps = [P.read(a, 3) for a in fixed]
    jp_ok = [j[0] == 0xC3 and (j[1] | j[2] << 8) == P.sym(h) for j, h in zip(jumps, ("ARR_OP_DIM", "ARR_OP_DIM_STR"))]
    return code[0] == 0xCD and target == P.sym("V2_VERIFY_KTAB") and dim_slots == fixed and all(jp_ok), \
        "ARR_RUN_INIT -> %s call %04X (V2_VERIFY_KTAB=%04X); opcode 63/64 slots=%04X/%04X (fixed %04X/%04X, jp ok %s)" % (
            code.hex(), target, P.sym("V2_VERIFY_KTAB"), *dim_slots, *fixed, jp_ok)


if __name__ == "__main__":
    sys.exit(P.run_cases(sys.argv[1:], "prod-arrays"))
