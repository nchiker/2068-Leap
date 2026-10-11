#!/usr/bin/env python3
"""RC -- SAVE "name" ALL / LOAD round trips on the production ROM (owner decision 2).

Every case runs the real ROM: the SAVE goes through V2_DISPATCH and its blocks are captured at
the tape transport (STORAGE_SEND_BLOCK); the LOAD boots a fresh machine with those blocks as the
EAR signal and runs the real V2_LOAD; the restored session is then questioned with immediate
statements. Corruption cases edit the captured block (recomputing the tape parity, and the
block CRC where the point is to get past it) to prove each LOAD check refuses what it should.
Format: docs/v2/V2_SAVE_ALL_FORMAT.md.

Run:  TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/v2_saveall_checks.py [case ...]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402
import tape_synth as TS          # noqa: E402

K_LEN = 0x31                     # the session cells $B800..$B830 (SA_K_LEN)
TAIL = K_LEN + 4


def crc16(data):
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def typed(cmd, maxi=900_000_000):
    P.poke(P.sym("EDIT_LINE_BUF"), cmd.encode() + b"\0")
    return P.call_prompt("V2_DISPATCH", maxi=maxi)


def run():
    return P.call_prompt("V2_RUN_STORED")


def ints(n):
    return [v for _, v in P.variables(n)]


def session_save(prog, immediates=(), command='SAVE "ALLT" ALL', run_first=True, prepare=None):
    """Boot, store `prog`, RUN it, run the immediate statements, SAVE ... ALL.
    Returns (header payload, data payload, message)."""
    P.boot()
    if prepare:
        prepare()
    P.put_store(prog)
    if run_first:
        run()
    for s in immediates:
        typed(s)
    blocks, msg = P.capture_save(command)
    if len(blocks) != 2:
        return None, None, msg
    return blocks[0][1], blocks[1][1], msg


def proglen(hdr):
    return hdr[15] | hdr[16] << 8


def tape_of(hdr, data):
    t = TS.Tape()
    t.block(TS.framed(0, hdr))
    t.block(TS.framed(0xFF, data))
    return t


def load(hdr, data, name="ALLT"):
    return P.tape_op(tape_of(hdr, data), name=name)


def refresh_crc(data):
    data = bytearray(data)
    c = crc16(bytes(data[:-2]))
    data[-2], data[-1] = c & 0xFF, c >> 8
    return bytes(data)


def cell(data, off):
    """Offset (in the data block) of the session cell at $B800+off."""
    return len(data) - TAIL + off


PROG = ["x = 5", 'y$ = "hello"', "z = 2.5", "DIM a(4)", "a(2) = 77", "DIM s$(3)", 's$(1) = "abc"',
        "big = 40000", "END", "again:", "x = x + 1"]
IMM = [":w = 9", ':t$ = "imm"']


_probe = [0]


def num_of(expr):
    """Value of a numeric expression in the current session: an immediate statement assigns it to a
    fresh variable, whose slot (the newest numeric symbol) is read. INT results are returned as
    ints; a FLOAT as ("float", slot)."""
    _probe[0] += 1
    typed(":pv%d = %s" % (_probe[0], expr))
    n = P.read(P.sym("CSYM_COUNT"), 1)[0]
    tag, v = P.variables(n)[n - 1]
    return (v - 65536 if v >= 32768 else v) if tag == 0 else ("float", v)


@case("sa-roundtrip", "SAVE ALL then LOAD on a fresh boot restores scalars, strings, floats, arrays and immediate-created variables")
def sa_roundtrip():
    hdr, data, msg = session_save(PROG, IMM)
    if hdr is None:
        return False, "save failed: %s" % msg
    pl = proglen(hdr)
    r = load(hdr, data)
    got = {k: num_of(k) for k in ("x", "w")}
    for k, e in (("r1", "x + w"), ("r2", "LEN(y$) + LEN(t$)"), ("r3", "INT(z * 4)"),
                 ("r4", "a(2) + LEN(s$(1))"), ("r5", "INT(big - 39990)")):
        got[k] = num_of(e)
    typed(":GOTO again")
    got["x_after_goto"] = num_of("x")
    want = {"x": 5, "w": 9, "r1": 14, "r2": 8, "r3": 10, "r4": 80, "r5": 10, "x_after_goto": 6}
    ok = msg == "SAVED" and pl < len(data) and r["msg"] == "LOADED" and r["after"] == TS.source_records(PROG) and got == want
    return ok, "save=%s proglen=%d data=%d load=%s got=%s" % (msg, pl, len(data), r["msg"], got)


@case("sa-plain-save-unchanged", "SAVE without ALL: PROGLEN = the data length, and LOAD gives no variables")
def sa_plain():
    hdr, data, msg = session_save(PROG, IMM, command='SAVE "ALLT"')
    r = load(hdr, data)
    x = num_of("x")
    return msg == "SAVED" and proglen(hdr) == len(data) and r["msg"] == "LOADED" and x == 0, \
        "proglen=%d data=%d load=%s x=%s" % (proglen(hdr), len(data), r["msg"], x)


@case("sa-store", "SAVE ALL carries the Array Store and the arrays that overflowed into segment 2")
def sa_store():
    prog = ["DIM big(3600)", "DIM o(900)", "o(899) = 31", "DIM b(5)", "b(3) = 12"]
    hdr, data, msg = session_save(prog, [":DIM m(2)", ":m(1) = 4"])
    if hdr is None:
        return False, "save failed: %s" % msg
    r = load(hdr, data)
    v = {k: num_of(k) for k in ("o(899)", "b(3)", "m(1)")}
    return r["msg"] == "LOADED" and v == {"o(899)": 31, "b(3)": 12, "m(1)": 4}, "load=%s v=%s" % (r["msg"], v)


@case("sa-no-session", "SAVE ALL with no RUN since the last edit saves a fresh session (zero variables)")
def sa_no_session():
    hdr, data, msg = session_save(["x = 5"], run_first=False)
    r = load(hdr, data)
    return msg == "SAVED" and r["msg"] == "LOADED" and num_of("x") == 0, "save=%s load=%s" % (msg, r["msg"])


@case("sa-verify", "VERIFY of a SAVE ALL tape on the machine that saved it succeeds, and the session still works after")
def sa_verify():
    hdr, data, msg = session_save(PROG, IMM)
    # the same session again, on a machine whose tape (the saved blocks) starts after the setup
    P.boot(tape_of(hdr, data), P.CPU_BOOT_T + 150_000_000)
    P.put_store(PROG)
    run()
    for s in IMM:
        typed(s)
    P.set_name("ALLT", 0)
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_VERIFY")))
    m = P.to_prompt(900_000_000)
    x = num_of("x + w")
    return m == "VERIFIED" and x == 14, "verify=%s x+w after=%s" % (m, x)


@case("sa-crc-corrupt", "a block whose CRC does not match is refused whole: LOAD FAILED, empty program")
def sa_crc():
    hdr, data, msg = session_save(PROG, IMM)
    bad = bytearray(data)
    bad[proglen(hdr) + 3] ^= 0x5A                                   # a state byte; tape parity recomputed
    r = load(hdr, bytes(bad))
    return r["msg"] == "LOAD_FAILED" and r["prog_end"] == P.sym("PROG_AREA_START"), \
        "load=%s prog_end=%04X" % (r["msg"], r["prog_end"])


@case("sa-other-rom", "a SAVE ALL tape from another ROM build loads its program only (NO VARIABLES)")
def sa_other_rom():
    hdr, data, msg = session_save(PROG, IMM)
    bad = bytearray(data)
    bad[-4] ^= 0x01                                                 # the ROM CRC
    r = load(hdr, refresh_crc(bad))
    return r["msg"] == "NO_VARS" and r["after"] == TS.source_records(PROG) and num_of("x") == 0, \
        "load=%s" % r["msg"]


@case("sa-bad-chain", "cells that break the address chain (ARR2_END past segment 2) are refused; the Array Store is kept")
def sa_bad_chain():
    hdr, data, msg = session_save(["DIM b(5)", "b(1) = 3"])
    bad = bytearray(data)
    o = cell(bad, 0x1B)                                             # ARR2_END
    bad[o], bad[o + 1] = 0x00, 0xF0
    r = load(hdr, refresh_crc(bad))
    pas = P.w16(P.sym("PAS_END"))
    return r["msg"] == "NO_VARS" and pas == 0xE000, "load=%s PAS_END=%04X" % (r["msg"], pas)


@case("sa-bad-pointer", "an array pointer outside the arena and segment 2 is refused (no trusted pointers)")
def sa_bad_pointer():
    hdr, data, msg = session_save(["DIM a(4)", "a(1) = 3"])
    bad = bytearray(data)
    # the run-time tables follow the program, symbol table, gap and arena: RT_ARRPTR_PTR's offset
    # inside them = RT_ARRPTR_PTR - RT_SYMTAB_PTR (both cells are in the tail)
    k = lambda off: bad[cell(bad, off)] | bad[cell(bad, off) + 1] << 8
    ae = k(0x2F)                                                    # SA_AE = ARRAYS_END
    t0 = ae - P.sym("PROG_AREA_START")                              # the tables start here in the block
    o = t0 + (k(0x13) - k(0x0D))                                    # a(): the first array pointer
    bad[o], bad[o + 1] = 0x00, 0x40                                 # -> the screen
    r = load(hdr, refresh_crc(bad))
    return r["msg"] == "NO_VARS", "load=%s (pointer at block+%d was %02X%02X)" % (r["msg"], o, data[o + 1], data[o])


@case("sa-package-mismatch", "a session saved with a package loaded is not restored without it (identity CRC covers the registry)")
def sa_package_mismatch():
    def prep():
        assert P.install_package("shapes")
    hdr, data, msg = session_save(["x = 4", "CIRCLE 128,96,10"], prepare=prep)
    r = load(hdr, data)                                             # fresh boot, no package
    return msg == "SAVED" and r["msg"] == "NO_VARS" and r["after"] == TS.source_records(["x = 4", "CIRCLE 128,96,10"]), \
        "save=%s load=%s" % (msg, r["msg"])


@case("sa-package-same", "with the same package loaded first, the session comes back and its package statements work")
def sa_package_same():
    prog = ["x = 4", "END", "dot:", "CIRCLE 128,96,x * 5"]
    def prep():
        assert P.install_package("shapes")
    hdr, data, msg = session_save(prog, prepare=prep)
    r = P.tape_op(tape_of(hdr, data), name="ALLT", prepare=lambda: P.install_package("shapes"))
    x = num_of("x")
    typed(":GOTO dot")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return r["msg"] == "LOADED" and x == 4 and ve == 0, "load=%s x=%s goto-dot err=%d" % (r["msg"], x, ve)


@case("sa-no-room", "SAVE ALL when the image would pass the bytecode area (bytecode + segment 2 > ~3.9K): OUT OF MEMORY, nothing sent")
def sa_no_room():
    # ~2.4K of bytecode and ~6.8K of source, a(600) fills what is left of the main pool, b(1000) goes
    # to segment 2: bytecode + segment 2 > V2_CODE_LIMIT - VM_CODE_BASE - the tail
    prog = ["POKE 16384,%d" % (i % 200) for i in range(400)] + ["DIM a(600)", "DIM b(1000)"]
    P.boot()
    P.put_store(prog)
    run()
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    seg2 = P.w16(P.sym("ARR2_END")) - 0xE000
    blocks, msg = P.capture_save('SAVE "ALLT" ALL')
    x = num_of("b(999) + 1")                                      # the session is intact afterwards
    return ve == 0 and seg2 > 2000 and msg == "NOMEM" and not blocks and x == 1, \
        "run_err=%d seg2=%d msg=%s blocks=%d after=%s" % (ve, seg2, msg, len(blocks), x)


@case("sa-store-entries", "the Array Store's entries come back with SAVE ALL (and replace the store present before the LOAD)")
def sa_store_entries():
    def u16(v):
        return bytes([v & 0xFF, v >> 8])
    desc = bytes([1]) + u16(3) + u16(10) + u16(20) + u16(30)
    ent = u16(4 + 1 + len(desc)) + bytes([2, 1]) + b"S" + desc
    def prep():
        P.poke(0xE000, ent)
        P.poke16(P.sym("PAS_END"), 0xE000 + len(ent))
    hdr, data, msg = session_save(["DIM s(3)", "s(2) = s(1) + 69"], prepare=prep)
    r = load(hdr, data)
    pas = P.w16(P.sym("PAS_END"))
    v = num_of("s(2)")
    stored = P.read(0xE000 + 2 + 1 + 1 + 1 + 3 + 2 * 2, 2)          # [len][kind][namelen][S][1][count] then s(2)
    return r["msg"] == "LOADED" and pas == 0xE000 + len(ent) and v == 89 and stored == u16(89), \
        "load=%s PAS_END=%04X s(2)=%s stored=%s" % (r["msg"], pas, v, stored.hex())


if __name__ == "__main__":
    sys.exit(run_cases(sys.argv[1:] or None, "saveall"))
