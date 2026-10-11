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

# ------------------------------------------------------------------------ D3, D4
# FIXED in R10.9 Phase 2D (strict compilation, exact error-line reporting).  All 18 `D3-*` cases, the
# `D3-ok-*` positive controls and the whole `D4-*` matrix are gate cases in tools/v2_prod_regress.py
# now ("strict compilation" / "compile-error line"), with the Phase 2D boundary cases beside them.

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


# ------------------------------------------------------------------------ D6, D8, D12-D16
# FIXED in R10.9 Phase 2C (persistent Array Store).  D6 (array persistence across RUN), D8 (CLEAR
# lifecycle), D12 (DIM zero-fill), D13 (array tape header type), D14 (array names > 8 characters),
# D15 (descriptor validation) and D16 (array tape BAD TAPE VERSION) are now gate cases in
# tools/v2_prod_arrays.py.  The two D15 declared-size cases (`count-short`, `count-long`) were
# retargeted, as approved in Phase 2B (docs/v2/R10_9_PHASE2B_REPORT.md s8.1), from the LOAD to the
# start of RUN.

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
