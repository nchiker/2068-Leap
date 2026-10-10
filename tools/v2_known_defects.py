#!/usr/bin/env python3
"""R10.9 Phase 1 -- known-defect suite (strict expected failures, production ROM).

Each case asserts the CORRECT behaviour.  Cases marked `xfail=` demonstrate a defect
recorded in docs/v2/R10_8_GAP_ANALYSIS.md and are EXPECTED to fail until the fix lands;
they report XFAIL.  If one starts passing it reports XPASS and the run fails, so a fix
cannot silently change this suite -- the marker must be removed in the same change and
the case then becomes a normal gate test.  Cases WITHOUT `xfail=` are positive controls
(behaviour that is already correct and must stay so) placed next to the defect they
bracket.

Everything runs on the production image `build/ts2068rom_zesarux.bin`; see
tools/v2_prod.py for what is real (key latch, tape EAR line, all production code) and
what is not (analogue tape, physical keyboard, contention).

Usage: python3 tools/v2_known_defects.py [substring ...]   (after `make build`)
"""
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402
import tape_synth as TS          # noqa: E402

PROG = ["x = 1", "y = 2", "z = x + y", "w = z * 2", "q = w + 1"]
SRC = TS.source_records(PROG)
OLD = ["a = 7", "b = 8", "c = a + b", "d = c * 3", "e = d + 9"]       # same record sizes as PROG


# D1 / D2 (cassette LOAD/VERIFY failure semantics) were FIXED in R10.9 Phase 2A and their
# cases moved, as gate tests, to tools/v2_prod_regress.py ("tape failure semantics").

# ------------------------------------------------------------------------ D3
# Anything that is not a valid program must be a compile error, not a silent stop.
D3_FAMILIES = {
    "stray-ENDIF": ["x = 1", "ENDIF", "y = 2"],
    "stray-ELSE": ["x = 1", "ELSE", "y = 2"],
    "stray-THEN": ["x = 1", "THEN", "y = 2"],
    "stray-rparen": ["x = 1", ")", "y = 2"],
    "stray-TO": ["x = 1", "TO", "y = 2"],
    "stray-ENDP": ["x = 1", "ENDP", "y = 2"],
    "leading-line-number": ["10 x = 5", "y = 2"],
    "missing-colon": ["x = 1 y = 2", "z = 3"],
    "trailing-rparen": ["x = (1))", "y = 2"],
    "infix-MOD": ["x = 7 MOD 2", "y = 2"],
    "print-semicolon-list": ["x = 1", "PRINT x; x", "y = 2"],
    "print-comma-list": ["x = 1", "PRINT x, x", "y = 2"],
    "chained-compare": ["x = 1 < 2 < 3", "y = 2"],
    "string-slice": ['a$ = "abcdef"', "b$ = a$(2 TO 3)", "y = 2"],
    "apostrophe-comment": ["x = 1 ' c", "y = 2"],
    "embedded-quote": ['a$ = "a""b"', "y = 2"],
    "unclosed-paren": ["x = (1 + 2", "y = 2"],
    "FOR-without-NEXT": ["for i = 1 to 3", "x = i", "y = 2"],
}
D3_ALREADY_CORRECT = {
    "incomplete-expression": ["x = 1 +", "y = 2"],
    "unknown-statement-word": ["FROBNICATE 1", "y = 2"],
}


def _d3(prog):
    def fn():
        ce, ve, msg = P.run_program(prog)
        return ce != 0, "compile_err=%d vm_err=%d msg=%s" % (ce, ve, msg)
    return fn


for _n, _p in D3_FAMILIES.items():
    case("D3-" + _n, "malformed program must be a compile error",
         xfail="D3: compiler silently stops at the first unrecognised token")(_d3(_p))
for _n, _p in D3_ALREADY_CORRECT.items():
    case("D3-ok-" + _n, "malformed program is a compile error (positive control)")(_d3(_p))


@case("D3-ok-valid-colon-line", "valid multi-statement line compiles (positive control)")
def d3_valid():
    ce, ve, msg = P.run_program(["x = 1 : y = 2", "z = x + y"])
    v = P.variables(3)
    return ce == 0 and ve == 0 and v[2][1] == 3, "compile_err=%d vals=%s" % (ce, v)


# ------------------------------------------------------------------------ D4
# A compile error must put the cursor on the source line that contains it.
def _d4_prog(length_stmts, k):
    ok = " : ".join(["x = 1"] * length_stmts)
    bad = " : ".join(["x = 1"] * (length_stmts - 1) + ["x = )"])
    return [bad if i == k else ok for i in range(20)]


# Observed at the R10.7 baseline (6151b64): every error line except the last lands on a
# later line (the lexer's look-ahead record); the last line is correct only because there is
# nothing after it.  The ASSERTION is always "cursor == the line containing the error".
D4_KNOWN_BAD = {(n, k) for n in (1, 4, 9) for k in (0, 2, 5, 10)}


def _d4(n, k):
    def fn():
        ce, ve, msg = P.run_program(_d4_prog(n, k))
        idx = P.cur_index()
        return ce != 0 and idx == k, "compile_err=%d cursor_line=%d want=%d" % (ce, idx, k)
    return fn


for _n in (1, 4, 9):                         # ~5, ~29, ~69 characters per line
    for _k in (0, 2, 5, 10, 19):
        case("D4-len%d-line%d" % (_n * 8 - 3, _k), "compile error lands on its own source line",
             xfail=("D4: cursor placed from the lexer look-ahead record, not the failing line"
                    if (_n, _k) in D4_KNOWN_BAD else None))(_d4(_n, _k))


# ------------------------------------------------------------------------ D5
@case("D5b-break-key-editor", "BREAK key (CAPS SHIFT+SPACE) must not insert a character",
      xfail="D5b: EDITOR_LOOP inserts the $10 control character")
def d5b():
    P.boot()
    P.key(KEY_BREAK)
    line = P.edit_line()
    return line == b"", "edit buffer=%r" % line


@case("D5-break-running-loop", "BREAK must interrupt `top: GOTO top` and return to the editor",
      xfail="D5: the VM never polls the keyboard")
def d5():
    P.boot()
    P.put_store(["top:", "GOTO top"])
    before = P.read(P.sym("PROG_AREA_START"), P.w16(P.sym("PROG_END")) - P.sym("PROG_AREA_START"))
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_RUN_STORED")))
    D("run", "--max-instructions", "2000000", t=600)
    D("pause")
    running = P.pc() != IOK
    P.poke(P.sym("KBD_LASTK"), KEY_BREAK)
    P.poke(P.sym("KBD_KEYHIT"), 1)
    back = P.run_to(IOK, 8_000_000)
    after = P.read(P.sym("PROG_AREA_START"), P.w16(P.sym("PROG_END")) - P.sym("PROG_AREA_START"))
    return running and back and after == before, \
        "loop_running=%s returned_to_editor=%s source_intact=%s" % (running, back, after == before)


# ------------------------------------------------------------------------ D6
@case("D6-array-load-survives-run", "LOAD ... ARRAY data must still be there when the program runs",
      xfail="D6: RUN re-carves the tables and zeroes the loaded array pointer (array persistence is intentional; repair follows the architecture audit)")
def d6():
    desc = bytes([1]) + (5).to_bytes(2, "little") + b"".join(v.to_bytes(2, "little") for v in (0, 0, 33, 0, 0))
    t = TS.Tape()
    t.block(TS.framed(0, TS.header_payload(STORAGE_ARRAY_TYPE, "ARR", len(desc),
                                                 autostart=TS._abi().fmt_word)))
    t.block(TS.framed(0xFF, desc))
    P.boot(t, lead=P.CPU_BOOT_T + 3_000_000)
    prog = ["GOTO s", "DIM a(5)", "s:", "y = a(2)"]
    P.put_store(prog)
    P.call_prompt("V2_RUN_STORED")                       # compile once so `a` is a known symbol
    line = b'load "ARR" ARRAY a\0'
    P.poke(P.sym("EDIT_LINE_BUF"), line)
    m1 = P.call_prompt("V2_DISPATCH")
    ptr_after_load = P.w16(P.w16(P.sym("RT_ARRPTR_PTR")))
    # Preconditions: the XFAIL must come from the RUN lifecycle, never from an early
    # failure (rejected tape version, failed receive, no symbol).  A violated
    # precondition is a harness FAIL, not an expected failure.
    if m1 != "LOADED" or ptr_after_load == 0:
        raise AssertionError("D6 precondition: LOAD ARRAY did not complete (msg=%s ptr=%04X)" % (m1, ptr_after_load))
    P.call_prompt("V2_RUN_STORED")
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    if ce != 0:
        raise AssertionError("D6 precondition: the program no longer compiles (compile_err=%d)" % ce)
    y = P.variables(1)[0][1]
    return ve == 0 and y == 33, "load_msg=%s ptr_after_load=%04X then RUN: vm_err=%d y=%d" % (m1, ptr_after_load, ve, y)


STORAGE_ARRAY_TYPE = 8


# ------------------------------------------------------------- D12 .. D15 (R10.9 Phase 2A)
# Array defects found by the R10.9 array-persistence audit (docs/v2/R10_9_ARRAY_PERSISTENCE_AUDIT.md
# s3.2).  Phase 2A only establishes the regression coverage; nothing here is repaired yet.
# Each case asserts the CORRECT behaviour and is XFAIL on the current ROM.
FMT_WORD = TS._abi().fmt_word


def num_desc(count, data_len=None, dim=1):
    n = 2 * count if data_len is None else data_len
    return bytes([dim]) + count.to_bytes(2, "little") + bytes((i * 7 + 1) & 0xFF for i in range(n))


def str_desc(count, width, data_len=None, dim=1):
    n = count * width if data_len is None else data_len
    return bytes([dim]) + count.to_bytes(2, "little") + bytes([width]) + bytes((i * 5 + 3) & 0xFF for i in range(n))


def array_tape(body, name="ARR", htype=STORAGE_ARRAY_TYPE, length=None, word=None):
    """A type-8 array tape: header (+version word) and one data block carrying `body`."""
    t = TS.Tape()
    t.block(TS.framed(0, TS.header_payload(htype, name, len(body) if length is None else length,
                                           autostart=FMT_WORD if word is None else word)))
    t.block(TS.framed(0xFF, body))
    return t


ARR_LEAD = P.CPU_BOOT_T + 3_000_000


def array_load(prog, cmd, tape, string=False):
    """Compile `prog` (so its array names are known symbols), then run the typed
    `cmd` (a LOAD ... ARRAY) against `tape`.  Returns the observations."""
    P.boot(tape, lead=ARR_LEAD)
    P.put_store(prog)
    P.call_prompt("V2_RUN_STORED")
    ae0 = P.w16(P.sym("ARRAYS_END"))
    P.poke(P.sym("EDIT_LINE_BUF"), cmd.encode() + b"\0")
    msg = P.call_prompt("V2_DISPATCH", maxi=900_000_000)
    ae1 = P.w16(P.sym("ARRAYS_END"))
    slot = P.w16(P.w16(P.sym("RT_STRARRPTR_PTR" if string else "RT_ARRPTR_PTR")))
    return {"msg": msg, "ae0": ae0, "ae1": ae1, "slot": slot}


NUM_PROG = ["GOTO s", "DIM a(5)", "s:", "y = a(2)"]
STR_PROG = ["GOTO s", "DIM a$(3)", "s:", "y = LEN(a$(1))"]


def _refused(r):
    return r["msg"] != "LOADED" and r["slot"] == 0 and r["ae1"] == r["ae0"]


def _fmt(r):
    return "msg=%s slot=%04X arrays_end %04X->%04X (+%d)" % (r["msg"], r["slot"], r["ae0"], r["ae1"], r["ae1"] - r["ae0"])


# ---- D12: DIM does not zero-fill
def _run_n(prog, n, reader):
    P.boot()
    P.put_store(prog)
    out = []
    for _ in range(n):
        P.call_prompt("V2_RUN_STORED")
        ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
        assert ce == 0, "program does not compile (compile_err=%d)" % ce
        out.append(reader())
    return out


@case("D12-dim-zero-repeat-run", "numeric DIM yields zeros on every RUN (a(2) written in run 1 must read 0 in run 2/3)",
      xfail="D12: DIM does not zero-fill; the previous RUN's array bytes reappear")
def d12_num_repeat():
    ys = _run_n(["DIM a(5)", "y = a(2)", "a(2) = 33"], 3, lambda: P.variables(1)[0][1])
    return ys == [0, 0, 0], "y per RUN = %s (want [0, 0, 0])" % ys


@case("D12-dim-zero-dirty-ram", "numeric DIM over dirty RAM yields zeros",
      xfail="D12: DIM does not zero-fill; the arena keeps whatever RAM held")
def d12_num_dirty():
    P.boot()
    P.put_store(["DIM a(5)", "y = a(2)", "z = a(0)"])
    lo = P.w16(P.sym("PROG_END")) + 4
    P.poke(lo, bytes([0xA5]) * (0xA000 - lo))
    P.call_prompt("V2_RUN_STORED")
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    assert ce == 0, "compile_err=%d" % ce
    v = P.variables(2)
    return v[0][1] == 0 and v[1][1] == 0, "a(2)=%d a(0)=%d (want 0, 0)" % (v[0][1], v[1][1])


@case("D12-dim-str-zero-repeat-run", "string DIM yields empty elements on every RUN",
      xfail="D12: DIM does not zero-fill; stale string lengths/contents reappear")
def d12_str_repeat():
    ns = _run_n(["DIM s$(3)", "n = LEN(s$(1))", 's$(1) = "hello"'], 3, lambda: P.variables(1)[0][1])
    return ns == [0, 0, 0], "LEN(s$(1)) per RUN = %s (want [0, 0, 0])" % ns


@case("D12-dim-str-zero-dirty-ram", "string DIM over dirty RAM yields empty elements",
      xfail="D12: DIM does not zero-fill; the arena keeps whatever RAM held")
def d12_str_dirty():
    P.boot()
    P.put_store(["DIM s$(3)", "n = LEN(s$(1))"])
    lo = P.w16(P.sym("PROG_END")) + 4
    P.poke(lo, bytes([0x05]) * (0xA000 - lo))
    P.call_prompt("V2_RUN_STORED")
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    assert ce == 0, "compile_err=%d" % ce
    n = P.variables(1)[0][1]
    return n == 0, "LEN(s$(1))=%d (want 0)" % n


# ---- D13: SAVE ... ARRAY header
def _save_array(prog, cmd):
    P.boot()
    P.put_store(prog)
    P.call_prompt("V2_RUN_STORED")
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    assert ce == 0, "program does not compile (compile_err=%d)" % ce
    return P.capture_save(cmd)


def _hdr(blocks):
    h = blocks[0][1]
    return h[0], h[1:11], int.from_bytes(h[11:13], "little"), int.from_bytes(h[13:15], "little")


@case("D13-save-array-header-numeric", "SAVE ... ARRAY of a numeric array writes a TYPE-8 header (word $8100, length 3+2n)",
      xfail="D13: V2_SAVE_ARRAY never sets the header type: the tape is written as type 0 (a PROGRAM)")
def d13_numeric():
    blocks, msg = _save_array(["DIM a(5)", "a(2) = 33"], 'save "ARR" ARRAY a')
    if msg != "SAVED" or len(blocks) != 2:
        raise AssertionError("D13 precondition: SAVE ARRAY did not reach the transport (msg=%s blocks=%d)" % (msg, len(blocks)))
    typ, name, length, word = _hdr(blocks)
    body = blocks[1][1]
    body_ok = body[:3] == bytes([1, 5, 0]) and body[7:9] == (33).to_bytes(2, "little") and len(body) == 13
    return typ == STORAGE_ARRAY_TYPE and word == FMT_WORD and length == 13 and body_ok, \
        "header type=%d (want 8) word=%04X length=%d body_ok=%s" % (typ, word, length, body_ok)


@case("D13-save-array-header-string", "SAVE ... ARRAY of a string array writes a TYPE-8 header",
      xfail="D13: V2_SAVE_ARRAY never sets the header type: the tape is written as type 0 (a PROGRAM)")
def d13_string():
    blocks, msg = _save_array(["DIM a$(2)", 'a$(1) = "hi"'], 'save "ARR" ARRAY a$')
    if msg != "SAVED" or len(blocks) != 2:
        raise AssertionError("D13 precondition: SAVE ARRAY did not reach the transport (msg=%s blocks=%d)" % (msg, len(blocks)))
    typ, name, length, word = _hdr(blocks)
    body = blocks[1][1]
    width = body[3]
    body_ok = body[:3] == bytes([1, 2, 0]) and width >= 2 and len(body) == 4 + 2 * width
    return typ == STORAGE_ARRAY_TYPE and word == FMT_WORD and length == len(body) and body_ok, \
        "header type=%d (want 8) word=%04X length=%d body_ok=%s" % (typ, word, length, body_ok)


@case("D13-array-tape-refused-by-plain-load", "an array tape written by SAVE ... ARRAY is REFUSED by plain LOAD (program intact)",
      xfail="D13: the type-0 array tape is accepted as a program and replaces the source with array bytes")
def d13_plain_load():
    blocks, msg = _save_array(["DIM a(5)", "a(2) = 33"], 'save "ARR" ARRAY a')
    if msg != "SAVED" or len(blocks) != 2:
        raise AssertionError("D13 precondition: SAVE ARRAY did not reach the transport (msg=%s blocks=%d)" % (msg, len(blocks)))
    t = TS.Tape()                                  # replay exactly what the ROM handed the transport
    t.block(TS.framed(blocks[0][0], blocks[0][1]))
    t.block(TS.framed(blocks[1][0], blocks[1][1]))
    r = P.tape_op(t, existing=PROG, name="ARR")
    return r["msg"] != "LOADED" and r["after"] == r["before"], \
        "plain LOAD msg=%s program_intact=%s (header type was %d)" % (r["msg"], r["after"] == r["before"], blocks[0][1][0])


@case("D13-own-array-tape-loads-as-array", "a tape written by SAVE ... ARRAY LOADs back with LOAD ... ARRAY",
      xfail="D13: the type-0 header never matches LOAD ARRAY's type-8 search")
def d13_roundtrip():
    blocks, msg = _save_array(["DIM a(5)", "a(2) = 33"], 'save "ARR" ARRAY a')
    if msg != "SAVED" or len(blocks) != 2:
        raise AssertionError("D13 precondition: SAVE ARRAY did not reach the transport (msg=%s blocks=%d)" % (msg, len(blocks)))
    t = TS.Tape()
    t.block(TS.framed(blocks[0][0], blocks[0][1]))
    t.block(TS.framed(blocks[1][0], blocks[1][1]))
    r = array_load(NUM_PROG, 'load "ARR" ARRAY a', t)
    return r["msg"] == "LOADED" and r["slot"] != 0, _fmt(r)


# ---- D14: array names longer than 8 characters
LONG31 = "abcdefghijklmnopqrstuvwxyz01234"


def _d14_save(name, ref):
    def fn():
        blocks, msg = _save_array(["DIM %s(5)" % name, "%s(2) = 33" % name], 'save "ARR" ARRAY %s' % ref)
        return msg == "SAVED" and len(blocks) == 2, "SAVE ARRAY %s (declared %s, %d chars): msg=%s" % (ref, name, len(name), msg)
    return fn


def _d14_load(name, ref):
    def fn():
        r = array_load(["GOTO s", "DIM %s(5)" % name, "s:", "y = %s(2)" % name],
                       'load "ARR" ARRAY %s' % ref, array_tape(num_desc(5)))
        return r["msg"] == "LOADED" and r["slot"] != 0, "LOAD ARRAY %s (%d chars): %s" % (ref, len(name), _fmt(r))
    return fn


case("D14-save-name-8", "SAVE ARRAY with an 8-character name works (positive control)")(_d14_save("abcdefgh", "abcdefgh"))
case("D14-load-name-8", "LOAD ARRAY with an 8-character name works (positive control)")(_d14_load("abcdefgh", "abcdefgh"))
for _n, _t in ((9, "abcdefghi"), (11, "temperature"), (31, LONG31)):
    case("D14-save-name-%d" % _n, "SAVE ARRAY of a valid %d-character array name" % _n,
         xfail="D14: V2_SCAN_ARRAY_NAME clamps the name to 8 characters; the symbol keeps up to 31")(_d14_save(_t, _t))
    case("D14-load-name-%d" % _n, "LOAD ARRAY into a valid %d-character array name" % _n,
         xfail="D14: V2_SCAN_ARRAY_NAME clamps the name to 8 characters; the symbol keeps up to 31")(_d14_load(_t, _t))
case("D14-save-name-mixedcase", "SAVE ARRAY with a mixed-case long name, referenced in another case",
     xfail="D14: V2_SCAN_ARRAY_NAME clamps the name to 8 characters; the symbol keeps up to 31")(
    _d14_save("MixedCaseLongName", "mixedcaselongname"))
case("D14-load-name-mixedcase", "LOAD ARRAY with a mixed-case long name, referenced in another case",
     xfail="D14: V2_SCAN_ARRAY_NAME clamps the name to 8 characters; the symbol keeps up to 31")(
    _d14_load("MixedCaseLongName", "MIXEDCASELONGNAME"))
case("D14-save-name-8-mixedcase", "SAVE ARRAY name case-folds within 8 characters (positive control)")(
    _d14_save("TempData", "tempdata"))


# ---- D15: LOAD ... ARRAY descriptor validation
# Every malformed body must be REFUSED with nothing registered and the arena unchanged.
# (Sizes are small and well inside the free arena so a currently-accepting ROM cannot
# corrupt anything outside it.)
@case("D15-control-numeric", "well-formed numeric array tape LOADs (positive control)")
def d15_ctl_num():
    r = array_load(NUM_PROG, 'load "ARR" ARRAY a', array_tape(num_desc(5)))
    return r["msg"] == "LOADED" and r["slot"] != 0 and r["ae1"] == r["ae0"] + 13, _fmt(r)


@case("D15-control-string", "well-formed string array tape LOADs (positive control)")
def d15_ctl_str():
    r = array_load(STR_PROG, 'load "ARR" ARRAY a$', array_tape(str_desc(3, 32)), string=True)
    return r["msg"] == "LOADED" and r["slot"] != 0 and r["ae1"] == r["ae0"] + 4 + 3 * 32, _fmt(r)


@case("D15-dimcount-normalised", "dim_count != 1 is accepted and rewritten to 1 (audit s5.1; positive control)")
def d15_dimcount():
    r = array_load(NUM_PROG, 'load "ARR" ARRAY a', array_tape(num_desc(5, dim=7)))
    first = P.read(r["slot"], 1)[0] if r["slot"] else None
    return r["msg"] == "LOADED" and first == 1, _fmt(r) + " dim_byte=%s" % first


def _d15(label, prog, cmd, body, string=False, length=None, title=None, why=None):
    @case("D15-" + label, title, xfail="D15: LOAD ... ARRAY accepts it: " + why)
    def fn():
        r = array_load(prog, cmd, array_tape(body, length=length), string=string)
        return _refused(r), _fmt(r) + " (want refused, nothing registered, arena unchanged)"
    return fn


NUMLOAD = (NUM_PROG, 'load "ARR" ARRAY a')
STRLOAD = (STR_PROG, 'load "ARR" ARRAY a$')
_d15("count-short", *NUMLOAD, num_desc(2), title="descriptor count 2 into a DIM a(5) target",
     why="declared 5 vs received 2: element access checks the DECLARED size, so a(2..4) would run past the descriptor")
_d15("count-long", *NUMLOAD, num_desc(100), title="descriptor count 100 into a DIM a(5) target",
     why="declared 5 vs received 100: the arena silently grows by 203 bytes")
_d15("count-zero", *NUMLOAD, num_desc(0), title="descriptor count 0 (compile rejects DIM a(0))",
     why="a zero-length array is registered")
_d15("len-count-mismatch", *NUMLOAD, num_desc(100, data_len=10), length=13,
     title="header length 13 but the descriptor claims 100 elements (body length != 3+2*count)",
     why="the arena advances 190 bytes past the received data; stale RAM becomes array contents")
_d15("len-below-descriptor", *NUMLOAD, bytes([1, 5]), title="header length 2 (shorter than the 3-byte descriptor)",
     why="the count is read from bytes that were never received")
_d15("numeric-into-string", *STRLOAD, num_desc(3), string=True,
     title="a numeric-array body LOADed into a string-array target (kind swap)",
     why="no kind check: 9 received bytes are registered as a string array")
_d15("string-into-numeric", *NUMLOAD, str_desc(2, 4), title="a string-array body LOADed into a numeric-array target (kind swap)",
     why="no kind check: 12 received bytes are registered as a numeric array")
_d15("string-width-0", *STRLOAD, str_desc(2, 0), string=True, title="string descriptor with element width 0",
     why="width must be >= 2 (length byte + one character)")
_d15("string-width-1", *STRLOAD, str_desc(2, 1), string=True, title="string descriptor with element width 1",
     why="width must be >= 2 (length byte + one character)")


# ------------------------------------------------------------------------ D8
@case("D8-clear-resets-scalars", "CLEAR must reset scalar variables",
      xfail="D8: OP_CLEAR only resets the array arena/registry")
def d8():
    ce, ve, msg = P.run_program(["DIM a(5)", "a(1) = 7", "s = 5", "CLEAR", "DIM b(5)", "b(1) = 9",
                                 "x = a(1)", "y = s"])
    v = P.variables(3)
    return ce == 0 and v[2][1] == 0, "compile_err=%d vm_err=%d s->y=%d (want 0) a(1)->x=%d" % (ce, ve, v[2][1], v[1][1])


@case("D8-clear-keeps-package", "CLEAR must not unregister loaded packages",
      xfail="D8: MEM_CLEAR_V2 clears the extension registry")
def d8_pkg():
    P.boot()
    assert P.install_package("shapes")
    P.put_store(["CLEAR", "CIRCLE 100,90,10"])
    P.call_prompt("V2_RUN_STORED")
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return ce == 0 and ve == 0, "compile_err=%d vm_err=%d" % (ce, ve)


# ------------------------------------------------------------------------ D9
@case("D9-edit-survives-navigation", "an uncommitted edit must not be discarded by UP/DOWN",
      xfail="D9a: V2_NAV reloads EDIT_LINE_BUF from the stored record")
def d9a():
    P.boot()
    P.type_text("a = 1")
    P.type_text("b = 2")
    P.key(KEY_UP)                                  # cursor on "b = 2"
    P.key(ord("9"))                                # uncommitted edit
    edited = P.edit_line()
    P.key(KEY_UP)
    P.key(KEY_DOWN)
    now = P.edit_line()
    return b"9" in now and b"9" in edited, "edited=%r after UP,DOWN=%r stored=%s" % (edited, now, P.store())


@case("D9-nav-plain", "UP/DOWN without an edit load the neighbouring line (positive control)")
def d9_plain():
    P.boot()
    P.type_text("a = 1")
    P.type_text("b = 2")
    P.key(KEY_UP)
    up = P.edit_line()
    P.key(KEY_UP)
    up2 = P.edit_line()
    P.key(KEY_DOWN)
    dn = P.edit_line()
    return (up, up2, dn) == (b"b = 2", b"a = 1", b"b = 2"), "got %r %r %r" % (up, up2, dn)


@case("D9-program-full-keeps-text", "PROGRAM FULL must leave the typed line in the edit buffer",
      xfail="D9b: the command loop re-runs EDITOR_INIT/V2_LOAD_EDIT and the line is lost")
def d9b():
    P.boot()
    start, limit = P.sym("PROG_AREA_START"), P.sym("V2_SOURCE_END")
    room = limit - 4 - start                        # leave 4 bytes: a 10-byte record cannot fit
    recs, used = [], 0
    while room - used >= 8 + 3:
        recs.append("x = 1")
        used += 2 + 5 + 1
    recs.append("x" * (room - used - 3))
    P.put_store(recs)
    P.type_text("y = 123456", enter=False)
    typed = P.edit_line()
    m = P.key(KEY_ENTER)                 # stops in the PROGRAM FULL message's key wait
    P.key(0x20)                          # dismiss it; the command loop then re-enters the editor
    after = P.edit_line()
    return m == "FULL" and after == typed and typed == b"y = 123456", \
        "message=%s typed=%r after dismissing=%r" % (m, typed, after)


# ----------------------------------------------------------------------- D11
def _d11(prog, label):
    def fn():
        ce, ve, msg = P.run_program(prog)
        tag, val = P.variables(1)[0]
        ok = ce != 0 or ve != 0 or tag == 1          # error, or promoted to a float
        return ok, "%s: compile_err=%d vm_err=%d tag=%d value16=%d" % (label, ce, ve, tag, val)
    return fn


for _id, _p in (("mul", ["a = 30000 * 3"]), ("add", ["a = 32767 + 1"]),
                ("sub", ["a = -32768 - 1"]), ("literal", ["a = 100000"])):
    case("D11-" + _id, "integer overflow / oversized literal must not wrap silently",
         xfail="D11: 16-bit arithmetic and literals wrap with no error")(_d11(_p, _id))


@case("D11-ok-in-range", "in-range integer arithmetic is exact (positive control)")
def d11_ok():
    ce, ve, msg = P.run_program(["a = 30000 + 2767", "b = 181 * 181", "c = -32767 - 1"])
    v = P.variables(3)
    return (ce, ve) == (0, 0) and v[0][1] == 32767 and v[1][1] == 32761 and v[2][1] == 0x8000, \
        "vals=%s" % v


# ------------------------------------------------------------------------ D7
def _fill_scenarios():
    s = {}
    rng = random.Random(2068)

    def noise(p):
        img = F.blank()
        for y in range(192):
            for x in range(256):
                if rng.random() < p:
                    img[y][x] = 1
        img[5][5] = 0
        return img, 5, 5
    s["noise-10pct"] = noise(0.10)
    s["noise-25pct"] = noise(0.25)
    s["noise-40pct"] = noise(0.40)
    img = F.blank()
    for y in range(0, 192, 2):                       # staggered dots: every other pixel on every other row,
        for x in range(((y // 2) % 2), 256, 2):      # alternate rows offset by one
            img[y][x] = 1
    s["staggered-dots"] = (img, 1, 1)
    img = F.blank()
    for x in range(0, 256, 2):                       # ladder: 1-pixel teeth hanging from a top rail
        for y in range(8, 184):
            if (y // 2) % 2 == 0:
                img[y][x] = 1
    s["ladder-1px-teeth"] = (img, 1, 100)
    img = F.blank()
    for x in range(0, 256, 3):                       # ladder: 2-pixel-wide rails with alternating rungs
        for y in range(0, 192):
            if (x // 3 + y // 2) % 2 == 0:
                img[y][x] = 1
                if x + 1 < 256:
                    img[y][x + 1] = 1
    s["ladder-2px"] = (img, 2, 3)
    return s


try:
    import v2_fill_check as F        # builds build/v2_package_shapes.bin as a side effect
    FILL_KNOWN_BAD = {"noise-10pct", "noise-25pct", "staggered-dots", "ladder-1px-teeth", "ladder-2px"}

    def _d7(name):
        def fn():
            img, sx, sy = _fill_scenarios()[name]
            got, used = F.run(img, sx, sy)
            want = F.flood(img, sx, sy)
            diff = sum(got[y][x] != want[y][x] for y in range(192) for x in range(256))
            return diff == 0, "differing pixels=%d fill-stack high-water=%d B" % (diff, used)
        return fn
    for _n in _fill_scenarios():
        case("D7-fill-" + _n, "FILL must produce the exact flood fill",
             xfail=("D7: seed stack overflow drops seeds with no indication" if _n in FILL_KNOWN_BAD else None))(_d7(_n))
except Exception as _e:               # pragma: no cover - reported, never hidden
    print("D7 scenarios unavailable:", _e)


# ------------------------------------------------------------------- U6 / MODE
@case("U6-mode1-return", "after a program sets MODE 1 the editor must come back in the normal video mode",
      xfail="U6: nothing resets the video mode on return to the editor")
def u6():
    P.boot()
    assert P.install_package("mode")
    P.put_store(["MODE 1"])
    P.call_prompt("V2_RUN_STORED")
    in_prog = P.read(P.sym("PORT_FF_SHADOW"), 1)[0] & 7
    P.key(0x20)                                    # dismiss the end-of-run key wait -> editor redraws
    back = P.read(P.sym("PORT_FF_SHADOW"), 1)[0] & 7
    return back == 0, "video mode bits while program ended=%d, in editor=%d" % (in_prog, back)


if __name__ == "__main__":
    sys.exit(P.run_cases(sys.argv[1:], "known-defects"))
