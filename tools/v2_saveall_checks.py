#!/usr/bin/env python3
"""RC -- SAVE "name" ALL / LOAD round trips on the production ROM (owner decision 2).

Every case runs the real ROM: the SAVE goes through V2_DISPATCH and its blocks are captured at
the tape transport (STORAGE_SEND_BLOCK); the LOAD boots a fresh machine with those blocks as the
EAR signal and runs the real V2_LOAD; the restored session is then questioned with immediate
statements. Corruption cases edit the captured block (recomputing the tape parity, and the
block CRC where the point is to get past it) to prove each LOAD check refuses what it should.
Format: docs/V2_SAVE_ALL_FORMAT.md.

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
SEG2 = P.sym("ARR2_BASE")        # v2.2 (item C): segment 2 is $5B00-$77FF (was $E000-$E7FF)
TAIL = K_LEN + 6                 # v2.2: cells, segment-2 CRC, identity CRC, block CRC


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
    _seg[0] = blocks[2][1] if len(blocks) == 3 else b""      # v2.2: SAVE ... ALL sends segment 2 as block 2
    if len(blocks) not in (2, 3):
        return None, None, msg
    return blocks[0][1], blocks[1][1], msg


_seg = [b""]                     # block 2 of the last session_save of a SAVE ... ALL


def proglen(hdr):
    return hdr[15] | hdr[16] << 8


def tape_of(hdr, data, seg=None, seg_kw=None):
    """header + block 1 (+ block 2: `seg`, default the last SAVE ... ALL's segment 2, none for a plain
    tape; seg=False leaves it off)."""
    t = TS.Tape()
    t.block(TS.framed(0, hdr))
    t.block(TS.framed(0xFF, data))
    if seg is None and proglen(hdr) < len(data):
        seg = _seg[0]
    if seg is not False and seg is not None:
        t.silence(4.5)                                          # the SAVE's gap
        fr = bytearray(TS.framed(0xFF, seg))
        if seg_kw and seg_kw.get("bad_parity"):
            fr[-1] ^= 0xFF
        t.block(bytes(fr), **({"truncate_after": seg_kw["truncate_after"]} if seg_kw and "truncate_after" in seg_kw else {}))
    return t


def load(hdr, data, name="ALLT", seg=None, seg_kw=None, prepare=None):
    return P.tape_op(tape_of(hdr, data, seg, seg_kw), name=name, prepare=prepare)


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
    return r["msg"] == "NO_VARS" and pas == SEG2, "load=%s PAS_END=%04X" % (r["msg"], pas)


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


@case("sa-big-store", "v2.2: a store that overflowed segment 2 and a full bytecode area save and load (the old partition rule is gone)")
def sa_big_store():
    # ~2.4K of bytecode and ~6.8K of source, a(1000) fills what is left of the main pool, b(1000) goes to
    # segment 2: the old single block (bytecode + segment 2 + 53 > the code area) said OUT OF MEMORY.
    prog = ["POKE 16384,%d" % (i % 200) for i in range(400)] + ["DIM a(1000)", "DIM b(1000)", "b(999) = 7"]
    hdr, data, msg = session_save(prog)
    seg = len(_seg[0])
    if hdr is None:
        return False, "save failed: %s" % msg
    x = num_of("b(999) + 1")                                      # the session is intact afterwards
    r = load(hdr, data)
    y = num_of("b(999) + 1")
    return msg == "SAVED" and seg > 2000 and x == 8 and r["msg"] == "LOADED" and y == 8, \
        "save=%s seg2=%d after=%s load=%s loaded=%s" % (msg, seg, x, r["msg"], y)


@case("sa-seg2-7k", "v2.2 (item C): a SAVE ALL whose segment 2 holds a 7 KB string array (block 2 over 7,000 bytes, past $6000) round trips")
def sa_seg2_7k():
    prog = ["DIM p(4000)", "DIM s$(100,70)", 's$(1) = "first"', 's$(99) = "last one"', "p(3999) = 9"]
    hdr, data, msg = session_save(prog)
    seg = _seg[0]
    if hdr is None:
        return False, "save failed: %s" % msg
    r = load(hdr, data)
    v = {k: num_of(k) for k in ("LEN(s$(1))", "LEN(s$(99))", "p(3999)")}
    end = P.w16(P.sym("ARR2_END"))
    return msg == "SAVED" and len(seg) >= 7000 and end > P.sym("SECOND_DISPLAY_ADDR") and r["msg"] == "LOADED" \
        and v == {"LEN(s$(1))": 5, "LEN(s$(99))": 8, "p(3999)": 9}, \
        "save=%s seg2=%d ARR2_END=%04X load=%s v=%s" % (msg, len(seg), end, r["msg"], v)


def _prep_entry():
    """A one-entry Array Store poked into the machine before the LOAD: (prepare, entry bytes)."""
    def u16(v):
        return bytes([v & 0xFF, v >> 8])
    desc = bytes([1]) + u16(2) + u16(5) + u16(6)
    ent = u16(4 + 1 + len(desc)) + bytes([2, 1]) + b"Q" + desc
    def prep():
        P.poke(SEG2, ent)
        P.poke16(P.sym("PAS_END"), SEG2 + len(ent))
    return prep, ent


BIGPROG = ["DIM big(3600)", "DIM o(900)", "o(899) = 31", "DIM b(5)", "b(3) = 12"]


@case("sa-two-blocks", "v2.2: SAVE ALL sends the header, block 1 (no segment 2) and block 2 = segment 2 as it is in memory; its CRC is in the tail; the format word is unchanged")
def sa_two_blocks():
    P.boot()
    P.put_store(BIGPROG)
    run()
    n = P.w16(P.sym("ARR2_END")) - SEG2
    mem = P.read(SEG2, n)
    blocks, msg = P.capture_save('SAVE "ALLT" ALL')
    if len(blocks) != 3:
        return False, "msg=%s blocks=%d" % (msg, len(blocks))
    hdr, b1, b2 = blocks[0][1], blocks[1][1], blocks[2][1]
    word = hdr[13] | hdr[14] << 8
    hlen = hdr[11] | hdr[12] << 8
    c2 = b1[len(b1) - 6] | b1[len(b1) - 5] << 8
    c1 = b1[-2] | b1[-1] << 8
    ok = msg == "SAVED" and [f for f, _ in blocks] == [0, 0xFF, 0xFF] and b2 == mem and n > 0 and hlen == len(b1) \
        and c2 == crc16(mem) and c1 == crc16(b1[:-2]) and word == TS._abi().fmt_word and proglen(hdr) < len(b1)
    return ok, "msg=%s seg2=%d b2==mem:%s hdr.len=%d b1=%d crc2:%s crc1:%s word=%04X" % (
        msg, n, b2 == mem, hlen, len(b1), c2 == crc16(mem), c1 == crc16(b1[:-2]), word)


@case("sa-gap", "v2.2: the silence between block 1 and block 2 is 4.5 s (14.9-16.6 million T), and the SAVE still ends SAVED")
def sa_gap():
    P.boot()
    P.put_store(["x = 5"])
    run()
    stamps = []
    def stamp(n):
        stamps.append((n, int(zr("get-tstates-partial"))))
        zr("reset-tstates-partial")
    zr("reset-tstates-partial")
    blocks, msg = P.capture_save('SAVE "ALLT" ALL', on_block=stamp)
    gap = stamps[2][1] if len(stamps) == 3 else 0                  # T from block 1's send to block 2's send
    return msg == "SAVED" and len(blocks) == 3 and 14_900_000 <= gap <= 16_600_000, \
        "msg=%s blocks=%d gap=%d T (%.2f s)" % (msg, len(blocks), gap, gap / 3_500_000)


@case("sa-gap-space", "v2.2: SPACE pressed in the silence between the blocks: ABORTED, block 2 not sent, the session still works")
def sa_gap_space():
    P.boot()
    P.put_store(PROG)
    run()
    def press(n):
        if n == 2:                                                 # block 1 just went out: now inside the gap
            a = P.sym("SA_GAP")
            code = P.read(a, 32)
            i = code.find(bytes([0xDB, 0xFE, 0x1F, 0xD0]))               # in a,($FE) / rra / ret nc
            assert i >= 0, "SA_GAP's SPACE test not found"
            P._space_down_at(a + i + 2, 60_000_000)
    blocks, msg = P.capture_save('SAVE "ALLT" ALL', on_block=press)
    x = num_of("x + 1")
    return msg == "ABORTED" and len(blocks) == 2 and x == 6, "msg=%s blocks=%d x+1=%s" % (msg, len(blocks), x)


@case("sa-minor-rules", "v2.2: an older-minor ALL tape from another ROM loads its program only; a newer-minor tape is BAD TAPE VERSION")
def sa_minor_rules():
    hdr, data, msg = session_save(PROG, IMM)
    old = bytearray(hdr)
    old[13] = TS._abi().fmt_minor - 1                               # the version word's low byte = the minor: an older one
    bad = bytearray(data)
    bad[-4] ^= 0x01                                                 # an older ROM's identity CRC cannot match
    r1 = load(bytes(old), refresh_crc(bad), seg=False)
    new = bytearray(hdr)
    new[13] = TS._abi().fmt_minor + 1                               # a newer one: refused before any byte is received
    r3 = load(bytes(new), data, seg=False)
    return r1["msg"] == "NO_VARS" and r1["after"] == TS.source_records(PROG) and r3["msg"] == "BAD_VERSION", \
        "minor1=%s minor3=%s" % (r1["msg"], r3["msg"])


@case("sa-other-rom-keeps-store", "v2.2: a tape from another ROM loads its program only and the Array Store present is KEPT (block 2 is never read)")
def sa_other_rom_keeps_store():
    hdr, data, msg = session_save(BIGPROG)
    bad = bytearray(data)
    bad[-4] ^= 0x01
    prep, ent = _prep_entry()
    r = load(hdr, refresh_crc(bad), prepare=prep)
    pas = P.w16(P.sym("PAS_END"))
    return r["msg"] == "NO_VARS" and pas == SEG2 + len(ent) and P.read(SEG2, len(ent)) == ent, \
        "load=%s PAS_END=%04X" % (r["msg"], pas)


def _block2_failure(label, **kw):
    hdr, data, msg = session_save(BIGPROG)
    seg = bytearray(_seg[0])
    if kw.pop("flip", False):
        seg[len(seg) // 2] ^= 0x5A                                  # a byte of segment 2; the tape parity is recomputed
    prep, ent = _prep_entry()
    r = load(hdr, data, seg=(False if kw.pop("missing", False) else bytes(seg)), seg_kw=kw or None, prepare=prep)
    pas = P.w16(P.sym("PAS_END"))
    return r, pas


@case("sa-block2-crc", "v2.2: segment 2 damaged on the tape (valid transport parity): NO VARIABLES, the program kept, the Array Store emptied")
def sa_block2_crc():
    r, pas = _block2_failure("crc", flip=True)
    return r["msg"] == "NO_VARS" and r["after"] == TS.source_records(BIGPROG) and pas == SEG2, \
        "load=%s PAS_END=%04X" % (r["msg"], pas)


@case("sa-block2-parity", "v2.2: block 2 with a bad transport checksum: NO VARIABLES, the program kept, the Array Store emptied")
def sa_block2_parity():
    r, pas = _block2_failure("parity", bad_parity=True)
    return r["msg"] == "NO_VARS" and r["after"] == TS.source_records(BIGPROG) and pas == SEG2, \
        "load=%s PAS_END=%04X" % (r["msg"], pas)


@case("sa-block2-missing", "v2.2: the tape ends after block 1: NO VARIABLES after the receiver's 8.6 s, the program kept, the Array Store emptied")
def sa_block2_missing():
    r, pas = _block2_failure("missing", missing=True)
    return r["msg"] == "NO_VARS" and r["after"] == TS.source_records(BIGPROG) and pas == SEG2, \
        "load=%s PAS_END=%04X" % (r["msg"], pas)


def _verify_with(tape, prog=PROG, imm=IMM, probe="x + w"):
    P.boot(tape, P.CPU_BOOT_T + 150_000_000)
    P.put_store(prog)
    run()
    for s_ in imm:
        typed(s_)
    P.set_name("ALLT", 0)
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_VERIFY")))
    m = P.to_prompt(900_000_000)
    return m, num_of(probe)


@case("sa-verify-block2", "v2.2: VERIFY compares block 2 too: a damaged segment 2 or a missing block 2 is VERIFY FAILED, the session intact")
def sa_verify_block2():
    hdr, data, msg = session_save(BIGPROG)
    seg = bytearray(_seg[0])
    seg[len(seg) // 2] ^= 0x01
    out = []
    for label, t in (("damaged", tape_of(hdr, data, bytes(seg))), ("missing", tape_of(hdr, data, False))):
        m, v = _verify_with(t, BIGPROG, (), "o(899)")
        out.append((label, m, v))
    return len(seg) > 0 and all(m == "VERIFY_FAILED" and v == 31 for _, m, v in out), str(out)


@case("sa-verify-block2-ok", "v2.2: VERIFY of a two-block tape whose segment 2 is not empty succeeds, and the session still works")
def sa_verify_block2_ok():
    hdr, data, msg = session_save(BIGPROG)
    m, v = _verify_with(tape_of(hdr, data), BIGPROG, (), "o(899)")
    return len(_seg[0]) > 0 and m == "VERIFIED" and v == 31, "verify=%s o(899)=%s seg2=%d" % (m, v, len(_seg[0]))


@case("sa-store-entries", "the Array Store's entries come back with SAVE ALL (and replace the store present before the LOAD)")
def sa_store_entries():
    def u16(v):
        return bytes([v & 0xFF, v >> 8])
    desc = bytes([1]) + u16(3) + u16(10) + u16(20) + u16(30)
    ent = u16(4 + 1 + len(desc)) + bytes([2, 1]) + b"S" + desc
    def prep():
        P.poke(SEG2, ent)
        P.poke16(P.sym("PAS_END"), SEG2 + len(ent))
    hdr, data, msg = session_save(["DIM s(3)", "s(2) = s(1) + 69"], prepare=prep)
    r = load(hdr, data)
    pas = P.w16(P.sym("PAS_END"))
    v = num_of("s(2)")
    stored = P.read(SEG2 + 2 + 1 + 1 + 1 + 3 + 2 * 2, 2)          # [len][kind][namelen][S][1][count] then s(2)
    return r["msg"] == "LOADED" and pas == SEG2 + len(ent) and v == 89 and stored == u16(89), \
        "load=%s PAS_END=%04X s(2)=%s stored=%s" % (r["msg"], pas, v, stored.hex())


if __name__ == "__main__":
    sys.exit(run_cases(sys.argv[1:] or None, "saveall"))
