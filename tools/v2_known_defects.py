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


# ------------------------------------------------------------------- D1 / D2
# Real STORAGE_LOAD / STORAGE_RECEIVE_BLOCK fed an EAR stream.  The correct result of
# any failed or incomplete receive is "LOAD FAILED" (or "VERIFY FAILED"), never LOADED.
@case("D1-dropout", "tape drops out mid data block -> LOAD must fail",
      xfail="D1: failure exits return carry clear (reported as success)")
def d1_dropout():
    t = TS.program_tape("TEST", SRC, dropout=(20, 12))
    r = P.tape_op(t, existing=OLD)
    return r["msg"] == "LOAD_FAILED", "msg=%s op_state=%d" % (r["msg"], r["op_state"])


@case("D1-truncated", "tape ends mid data block -> LOAD must fail",
      xfail="D1: failure exits return carry clear (reported as success)")
def d1_truncated():
    t = TS.program_tape("TEST", SRC, truncate_after=24)
    r = P.tape_op(t, existing=OLD)
    return r["msg"] == "LOAD_FAILED", "msg=%s op_state=%d" % (r["msg"], r["op_state"])


@case("D1-space-abort", "SPACE held mid data block -> LOAD must fail",
      xfail="D1: failure exits return carry clear (reported as success)")
def d1_space():
    t = TS.program_tape("TEST", SRC)

    def interfere():
        assert P.wait_in_data(16), "never reached the data block"
        P.hold_space_for_one_sample()
    r = P.tape_op(t, existing=OLD, interfere=interfere)
    return r["msg"] == "LOAD_FAILED", "msg=%s op_state=%d" % (r["msg"], r["op_state"])


@case("D1-flag-mismatch", "data block carries the wrong flag byte -> LOAD must fail",
      xfail="D1: failure exits return carry clear (reported as success)")
def d1_flag():
    t = TS.program_tape("TEST", SRC, data_flag=0x00)
    r = P.tape_op(t, existing=OLD)
    return r["msg"] == "LOAD_FAILED", "msg=%s op_state=%d" % (r["msg"], r["op_state"])


@case("D1-checksum", "bad checksum -> LOAD FAILED (already correct; positive control)")
def d1_checksum():
    t = TS.program_tape("TEST", SRC, bad_checksum=True)
    r = P.tape_op(t, existing=OLD)
    return r["msg"] == "LOAD_FAILED", "msg=%s" % r["msg"]


@case("D2-verify-mismatch", "VERIFY of a different program must report VERIFY FAILED, program intact",
      xfail="D1/D2: verify content mismatch is reported as VERIFIED")
def d2_mismatch():
    t = TS.program_tape("TEST", TS.source_records(OLD))             # tape differs from the program
    r = P.tape_op(t, existing=PROG, routine="V2_VERIFY")
    ok = r["msg"] == "VERIFY_FAILED" and r["after"] == r["before"]
    return ok, "msg=%s intact=%s" % (r["msg"], r["after"] == r["before"])


@case("D2-verify-checksum", "VERIFY with a bad checksum must not erase the program",
      xfail="D2: failed VERIFY runs NEW (PROG_END reset)")
def d2_checksum():
    t = TS.program_tape("TEST", SRC, bad_checksum=True)
    r = P.tape_op(t, existing=PROG, routine="V2_VERIFY")
    ok = r["msg"] == "VERIFY_FAILED" and r["after"] == r["before"]
    return ok, "msg=%s intact=%s prog_end=%04X" % (r["msg"], r["after"] == r["before"], r["prog_end"])


@case("D2-verify-identical", "VERIFY of an identical program -> VERIFIED, program intact (positive control)")
def d2_identical():
    t = TS.program_tape("TEST", SRC)
    r = P.tape_op(t, existing=PROG, routine="V2_VERIFY")
    ok = r["msg"] == "VERIFIED" and r["after"] == r["before"]
    return ok, "msg=%s intact=%s" % (r["msg"], r["after"] == r["before"])


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
    P.call_prompt("V2_RUN_STORED")
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    y = P.variables(1)[0][1]
    return ve == 0 and y == 33, "load_msg=%s ptr_after_load=%04X then RUN: vm_err=%d y=%d" % (m1, ptr_after_load, ve, y)


STORAGE_ARRAY_TYPE = 8


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
