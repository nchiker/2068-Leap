#!/usr/bin/env python3
"""v2.1.2 item D -- SAVE / LOAD / VERIFY "name" CODE on the production ROM (docs/V2_2_STORAGE_RELEASE_PLAN.md 2.3).

Every case runs the real production image through tools/v2_prod.py: commands go through the real
V2_DISPATCH (and so the real V2_PARSE_NAME), SAVEs are captured at the sender's call site
(P.capture_save), LOADs boot a fresh machine with the captured (or synthesised) blocks as the EAR
signal. A CODE tape is header type 3 with the start address in the PROGLEN field and Leap's version
word: it is not a stock CODE tape.

Usage: TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/v2_prod_code.py [substring ...]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402
import tape_synth as TS          # noqa: E402

CODE_TYPE = 3
FMT_WORD = TS._abi().fmt_word
LEAD = P.CPU_BOOT_T + 3_000_000
START, N = 30720, 256                                     # $7800: the users' machine-code RAM
DATA = bytes((i * 29 + 7) & 0xFF for i in range(N))
PROG = ["x = 1", "y = x + 1"]


def typed(cmd, maxi=900_000_000):
    P.poke(P.sym("EDIT_LINE_BUF"), cmd.encode() + b"\0")
    return P.call_prompt("V2_DISPATCH", maxi=maxi)


def replay(blocks, copies=1):
    t = TS.Tape()
    for _ in range(copies):
        for flag, payload in blocks:
            t.block(TS.framed(flag, payload))
        t.silence(0.5)
    return t


def code_tape(name, data, start, word=None, copies=1):
    """A CODE tape as this ROM writes it (header type 3, PROGLEN = start)."""
    t = TS.Tape()
    for _ in range(copies):
        t.block(TS.framed(0, TS.header_payload(CODE_TYPE, name, len(data), autostart=FMT_WORD if word is None else word,
                                               proglen=start)))
        t.block(TS.framed(0xFF, data))
        t.silence(0.5)
    return t


_saved = {}


def saved_blob():
    """The ROM's own SAVE "BLOB" CODE 30720,256 of DATA: (blocks, message)."""
    if "b" not in _saved:
        P.boot()
        P.poke(START, DATA)
        _saved["b"] = P.capture_save('save "BLOB" CODE %d,%d' % (START, N))
    return _saved["b"]


def entry_store():
    """A one-entry Array Store, poked in (the bytes, to check it is untouched)."""
    base = P.sym("ARR2_BASE")
    desc = bytes([1, 2, 0, 5, 0, 6, 0])
    ent = (4 + 1 + len(desc)).to_bytes(2, "little") + bytes([2, 1]) + b"q" + desc
    P.poke(base, ent)
    P.poke16(P.sym("PAS_END"), base + len(ent))
    return base, ent


def registry():
    base = P.sym("EXT2_TABLE")
    out = []
    for i in range(12):
        rec = P.read(base + 14 * i, 14)
        if rec[0]:
            out.append(rec[2:2 + rec[1]].decode())
    return out


@case("code-save-header", "SAVE \"n\" CODE start,length: a type-3 header (length, version word, PROGLEN = start) and the range as data")
def save_header():
    blocks, msg = saved_blob()
    if msg != "SAVED" or len(blocks) != 2:
        return False, "msg=%s blocks=%d" % (msg, len(blocks))
    h = blocks[0][1]
    ok = blocks[0][0] == 0 and h[0] == CODE_TYPE and h[1:11] == b"BLOB      " and int.from_bytes(h[11:13], "little") == N \
        and int.from_bytes(h[13:15], "little") == FMT_WORD and int.from_bytes(h[15:17], "little") == START \
        and blocks[1] == (0xFF, DATA)
    return ok, "header=%s data_same=%s" % (h.hex(), blocks[1][1] == DATA)


@case("code-roundtrip", "LOAD \"n\" CODE after NEW and a RAM wipe puts the range back at the saved address; the session ends, "
                         "the program, the Array Store and packages stay")
def roundtrip():
    blocks, msg = saved_blob()
    P.boot(replay(blocks), lead=LEAD)
    typed("new")
    assert P.install_package("mode")
    P.put_store(PROG)
    P.call_prompt("V2_RUN_STORED")                      # a session
    base, ent = entry_store()
    P.poke(START, bytes(N))                             # the wipe
    sess = P.read(P.sym("SESS_VALID"), 1)[0]
    m = typed('load "BLOB" CODE')
    got = P.read(START, N)
    ok = msg == "SAVED" and sess == 1 and m == "LOADED" and got == DATA and P.read(P.sym("SESS_VALID"), 1)[0] == 0 \
        and P.store() == PROG and P.read(base, len(ent)) == ent and registry() == ["MODE", "ULAPLUS", "PALETTE"]
    return ok, "load=%s range_same=%s session_before=%d after=%d program=%s store_same=%s registry=%s" % (
        m, got == DATA, sess, P.read(P.sym("SESS_VALID"), 1)[0], P.store(), P.read(base, len(ent)) == ent, registry())


@case("code-load-other-start", "LOAD \"n\" CODE start loads at that address instead; the saved address is not written")
def load_other_start():
    blocks, _ = saved_blob()
    P.boot(replay(blocks), lead=LEAD)
    P.poke(START, bytes(N))
    other = START + 512
    P.poke(other, bytes(N))
    m = typed('load "BLOB" CODE %d' % other)
    return m == "LOADED" and P.read(other, N) == DATA and P.read(START, N) == bytes(N), \
        "load=%s at_other=%s saved_address_untouched=%s" % (m, P.read(other, N) == DATA, P.read(START, N) == bytes(N))


@case("code-verify", "VERIFY \"n\" CODE: VERIFIED when the range matches, VERIFY FAILED when one byte differs (nothing written)")
def verify():
    blocks, _ = saved_blob()
    P.boot(replay(blocks, copies=2), lead=LEAD)
    P.poke(START, DATA)
    m1 = typed('verify "BLOB" CODE')
    bad = bytearray(DATA)
    bad[100] ^= 0xFF
    P.poke(START, bytes(bad))
    m2 = typed('verify "BLOB" CODE')
    return m1 == "VERIFIED" and m2 == "VERIFY_FAILED" and P.read(START, N) == bytes(bad) \
        and P.read(P.sym("STORAGE_VERIFY_MODE"), 1)[0] == 0, "pass=%s fail=%s" % (m1, m2)


@case("code-verify-keeps-session", "VERIFY \"n\" CODE writes nothing and keeps the session: after a pass, a mismatch and a "
                                    "missing tape the session, the program, the Array Store and the packages are unchanged")
def verify_keeps_session():
    blocks, _ = saved_blob()
    P.boot(replay(blocks, copies=2), lead=LEAD)
    assert P.install_package("mode")
    base, ent = entry_store()
    P.put_store(PROG)
    P.call_prompt("V2_RUN_STORED")                      # a session (binding the store)
    P.poke(START, DATA)
    out = []

    def state():
        return (P.read(P.sym("SESS_VALID"), 1)[0], P.read(P.sym("STORAGE_VERIFY_MODE"), 1)[0], P.store() == PROG,
                P.read(base, len(ent)) == ent, registry() == ["MODE", "ULAPLUS", "PALETTE"])
    want = (1, 0, True, True, True)
    m = typed('verify "BLOB" CODE')
    out.append(("pass", m, m == "VERIFIED" and state() == want))
    bad = bytearray(DATA)
    bad[7] ^= 0x55
    P.poke(START, bytes(bad))
    m = typed('verify "BLOB" CODE')
    out.append(("mismatch", m, m == "VERIFY_FAILED" and state() == want and P.read(START, N) == bytes(bad)))
    m = typed('verify "BLOB" CODE')                     # the tape has run out
    out.append(("no-tape", m, m == "VERIFY_FAILED" and state() == want))
    return all(g for _, _, g in out), "%s; state after: SESS_VALID, VERIFY_MODE, program, store, registry = %s" % (out, state())


@case("code-verify-empty-name", "VERIFY \"\" CODE is SYNTAX and leaves no compare mode behind: the next LOAD \"PROG\" is an ordinary LOAD")
def verify_empty_name():
    P.boot(TS.program_tape("PROG", TS.source_records(["k = 1"])), lead=LEAD)
    P.put_store(PROG)
    m1 = typed('verify "" CODE')
    vm = P.read(P.sym("STORAGE_VERIFY_MODE"), 1)[0]
    m2 = typed('load "PROG"')
    ok = m1 == "SYNTAX" and vm == 0 and m2 == "LOADED" and P.read(P.sym("STORAGE_VERIFY_MODE"), 1)[0] == 0 \
        and P.store() == ["k = 1"]
    return ok, "verify \"\" CODE=%s verify_mode_after=%d load=%s program=%s" % (m1, vm, m2, P.store())


@case("code-type-isolation", "a CODE tape offered to LOAD \"n\" is skipped (program intact); a program tape offered to LOAD \"n\" CODE is skipped (RAM intact)")
def type_isolation():
    blocks, _ = saved_blob()
    r = P.tape_op(replay(blocks), existing=PROG, name="BLOB")
    t = TS.program_tape("PROG", TS.source_records(["k = 1"]))
    P.boot(t, lead=LEAD)
    P.poke(START, bytes(N))
    m = typed('load "PROG" CODE %d' % START)
    return r["msg"] == "LOAD_FAILED" and r["after"] == r["before"] and m == "LOAD_FAILED" and P.read(START, N) == bytes(N), \
        "plain LOAD of CODE: %s program_intact=%s; LOAD CODE of a program: %s" % (r["msg"], r["after"] == r["before"], m)


@case("code-syntax", "missing or malformed numbers, start + length past 65536, length 0, no quotes: SYNTAX, nothing sent")
def syntax():
    P.boot()
    bad = ['save "X" CODE', 'save "X" CODE 30720', 'save "X" CODE 30720,', 'save "X" CODE ,5', 'save "X" CODE 65535,2',
           'save "X" CODE 70000,1', 'save "X" CODE 30720,0', 'save "X" CODE 0,0', 'save "X" CODE 1 2', 'save X CODE 1,1',
           'save "X" CODE 1,2,3', 'load "X" CODE abc', 'load "X" CODE 30720 junk', 'verify "X" CODE 99999',
           'save "X" CODEX 1,1']
    got = {c: typed(c) for c in bad}
    return all(v == "SYNTAX" for v in got.values()), str({k: v for k, v in got.items() if v != "SYNTAX"} or "all SYNTAX")


@case("code-too-long", "a CODE block longer than the room (65536 - start) is LOAD FAILED with nothing stored, at the tape's or a given start")
def too_long():
    out = []
    # the tape's own start: 65400 + 256 passes 65536 (a tape this ROM would not write; synthesised)
    P.boot(code_tape("HIGH", DATA, 65400), lead=LEAD)
    before = P.read(65400, 136)
    m = typed('load "HIGH" CODE')
    out.append(("tape-start", m, m == "LOAD_FAILED" and P.read(65400, 136) == before))
    blocks, _ = saved_blob()
    P.boot(replay(blocks), lead=LEAD)
    before = P.read(65400, 136)
    m = typed('load "BLOB" CODE 65400')
    out.append(("given-start", m, m == "LOAD_FAILED" and P.read(65400, 136) == before))
    # a block that ends exactly at 65536 fits ($FFF0-$FFFF: above the machine stack, unused by V2)
    P.boot(code_tape("TOP", DATA[:16], 65520), lead=LEAD)
    m = typed('load "TOP" CODE')
    out.append(("ends-at-65536", m, m == "LOADED" and P.read(65520, 16) == DATA[:16]))
    return all(g for _, _, g in out), str(out)


@case("code-bad-version", "a CODE tape with another version word is BAD TAPE VERSION, nothing stored")
def bad_version():
    P.boot(code_tape("BLOB", DATA, START, word=0x8200), lead=LEAD)
    P.poke(START, bytes(N))
    m = typed('load "BLOB" CODE')
    return m == "BAD_VERSION" and P.read(START, N) == bytes(N), "load=%s" % m


if __name__ == "__main__":
    sys.exit(P.run_cases(sys.argv[1:], "prod-code"))
