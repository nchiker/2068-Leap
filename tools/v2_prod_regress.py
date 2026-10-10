#!/usr/bin/env python3
"""R10.9 Phase 1 -- production-ROM regression gate (editor, tape, packages, ABI).

Every case must PASS.  The cases run on the real production image
(`build/ts2068rom_zesarux.bin`) through the real editor key latch, command
dispatcher, compiler, VM, tape receiver (EAR-line input via ZEsarUX "real tape") and
the real package entry; see tools/v2_prod.py for the exact list of what is and is not
real.  Known defects live in tools/v2_known_defects.py (strict expected failures);
nothing here is allowed to be a known failure.

Usage: python3 tools/v2_prod_regress.py [substring ...]   (after `make build v2-packages`)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402
import tape_synth as TS          # noqa: E402
import v2_abi                    # noqa: E402

ABI = v2_abi.load()

PROG = ["x = 1", "y = 2", "z = x + y", "w = z * 2", "q = w + 1"]
OLD = ["a = 7", "b = 8", "c = a + b", "d = c * 3", "e = d + 9"]
SRC = TS.source_records(PROG)


def pixel_addr(x, y):
    return 0x4000 | ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | (x >> 3)


# ------------------------------------------------------------------- editor
@case("editor-type-store", "typed lines reach the line store through the real key path")
def editor_type_store():
    P.boot()
    P.type_text("x = 5")
    P.type_text("y = x * 2")
    return P.store() == ["x = 5", "y = x * 2"], "store=%s" % P.store()


@case("editor-run-typed", "`run` typed at the prompt compiles and runs the stored program")
def editor_run_typed():
    P.boot()
    P.type_text("x = 5")
    P.type_text("y = x * 2")
    P.type_text("run")
    v = P.variables(2)
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    return ce == 0 and v[0][1] == 5 and v[1][1] == 10, "compile_err=%d vars=%s" % (ce, v)


@case("editor-delete-line", "CAPS SHIFT+1 deletes the current line")
def editor_delete_line():
    P.boot()
    for t in ("a = 1", "b = 2", "c = 3"):
        P.type_text(t)
    P.key(KEY_UP)
    P.key(KEY_UP)                       # on "b = 2"
    P.key(KEY_DELETE_LINE)
    return P.store() == ["a = 1", "c = 3"], "store=%s" % P.store()


# ------------------------------------------------------------- tape (LOAD/VERIFY)
@case("tape-load-ok", "a well-formed program tape LOADs through the real receiver")
def tape_load_ok():
    r = P.tape_op(TS.program_tape("TEST", SRC), existing=OLD)
    data = P.read(P.sym("PROG_AREA_START"), len(SRC))
    return r["msg"] == "LOADED" and data == SRC and r["prog_end"] == P.sym("PROG_AREA_START") + len(SRC), \
        "msg=%s prog_end=%04X" % (r["msg"], r["prog_end"])


# ------------------------------------------- tape failure semantics (R10.9 Phase 2A, D1/D2)
# Policy under test (docs/v2/R10_9_PHASE2A_REPORT.md s3):
#   * a failed receive is NEVER reported as LOADED / VERIFIED;
#   * failure BEFORE any destination byte was stored  -> program intact;
#   * failure AFTER the first destination byte         -> known-safe empty program (as NEW);
#   * VERIFY never modifies anything (it cannot touch the destination);
#   * unsupported version -> BAD TAPE VERSION, nothing touched;  SPACE -> ABORTED.

def _empty(r):
    """The known-safe empty state after a destructive failure."""
    return (r["prog_end"] == P.sym("PROG_AREA_START") and r["edit_pos"] == 0xFFFF
            and r["edit_index"] == 0 and r["verify_mode"] == 0)


def _intact(r):
    return r["after"] == r["before"] and r["verify_mode"] == 0


def _d(r):
    return "msg=%s intact=%s empty=%s prog_end=%04X verify_mode=%d" % (
        r["msg"], r["after"] == r["before"], _empty(r), r["prog_end"], r["verify_mode"])


@case("D1-dropout", "tape drops out mid data block -> LOAD FAILED, program wiped (destination was touched)")
def d1_dropout():
    r = P.tape_op(TS.program_tape("TEST", SRC, dropout=(20, 12)), existing=OLD)
    return r["msg"] == "LOAD_FAILED" and r["op_state"] == 6 and _empty(r), _d(r)


@case("D1-truncated", "tape ends mid data block -> LOAD FAILED, program wiped")
def d1_truncated():
    r = P.tape_op(TS.program_tape("TEST", SRC, truncate_after=24), existing=OLD)
    return r["msg"] == "LOAD_FAILED" and r["op_state"] == 6 and _empty(r), _d(r)


@case("D1-flag-mismatch", "data block carries the wrong flag byte -> LOAD FAILED before any store: program intact")
def d1_flag():
    r = P.tape_op(TS.program_tape("TEST", SRC, data_flag=0x00), existing=OLD)
    return r["msg"] == "LOAD_FAILED" and _intact(r), _d(r)


@case("D1-dropout-before-data", "dropout over the flag byte -> LOAD FAILED before any store: program intact")
def d1_dropout_early():
    r = P.tape_op(TS.program_tape("TEST", SRC, dropout=(0, 2)), existing=OLD)
    return r["msg"] == "LOAD_FAILED" and _intact(r), _d(r)


@case("D1-checksum", "bad checksum -> LOAD FAILED; every byte was stored, so the program is wiped")
def d1_checksum():
    r = P.tape_op(TS.program_tape("TEST", SRC, bad_checksum=True), existing=OLD)
    return r["msg"] == "LOAD_FAILED" and _empty(r), _d(r)


@case("D1-space-abort", "SPACE held mid data block -> ABORTED, program wiped (destination was touched)")
def d1_space():
    def interfere():
        assert P.wait_in_data(16), "never reached the data block"
        P.press_space()
    r = P.tape_op(TS.program_tape("TEST", SRC), existing=OLD, interfere=interfere)
    return r["msg"] == "ABORTED" and r["op_state"] == 6 and _empty(r), _d(r)


@case("D1-space-abort-header", "SPACE while waiting for a header -> ABORTED at once, program intact")
def d1_space_header():
    def interfere():
        P.press_space()
    r = P.tape_op(TS.program_tape("TEST", SRC), existing=OLD, interfere=interfere)
    return r["msg"] == "ABORTED" and _intact(r), _d(r)


@case("D1-recovers", "after a failed (wiping) LOAD the editor works and a second LOAD of a good copy succeeds")
def d1_recovers():
    hdr = TS.framed(0x00, TS.header_payload(0, "TEST", len(SRC), ABI.fmt_word))
    t = TS.Tape()
    t.block(hdr)
    t.block(TS.framed(0xFF, SRC), truncate_after=24)          # first copy: cut short
    t.block(hdr)
    t.block(TS.framed(0xFF, SRC))                             # second copy: good
    r = P.tape_op(t, existing=OLD)
    if not (r["msg"] == "LOAD_FAILED" and _empty(r)):
        return False, "first LOAD: " + _d(r)
    m2 = P.call_prompt("V2_LOAD", maxi=900_000_000)
    ok2 = m2 == "LOADED" and P.store() == PROG and P.read(P.sym("STORAGE_VERIFY_MODE"), 1)[0] == 0
    P.key(KEY_LEFT)                                           # the first key only dismisses the message
    P.type_text("k = 9")
    return ok2 and P.store() == PROG + ["k = 9"], "second LOAD msg=%s store=%s" % (m2, P.store())


@case("D1-wrong-name", "tape carries another file's name -> LOAD FAILED, program intact")
def d1_wrong_name():
    r = P.tape_op(TS.program_tape("OTHER", SRC), existing=OLD)
    return r["msg"] == "LOAD_FAILED" and _intact(r), _d(r)


@case("D1-wrong-type", "tape holds a header of another type (4 = package) -> LOAD FAILED, program intact")
def d1_wrong_type():
    r = P.tape_op(TS.program_tape("TEST", SRC, htype=4), existing=OLD)
    return r["msg"] == "LOAD_FAILED" and _intact(r), _d(r)


@case("D1-header-truncated", "header block cut short -> LOAD FAILED, program intact")
def d1_header_truncated():
    t = TS.Tape()
    t.block(TS.framed(0x00, TS.header_payload(0, "TEST", len(SRC), ABI.fmt_word)), truncate_after=9)
    r = P.tape_op(t, existing=OLD)
    return r["msg"] == "LOAD_FAILED" and _intact(r), _d(r)


@case("D2-verify-identical", "VERIFY of an identical program -> VERIFIED, program intact")
def d2_identical():
    r = P.tape_op(TS.program_tape("TEST", SRC), existing=PROG, routine="V2_VERIFY")
    return r["msg"] == "VERIFIED" and _intact(r), _d(r)


@case("D2-verify-mismatch", "VERIFY of a different program (valid checksum) -> VERIFY FAILED, program intact")
def d2_mismatch():
    r = P.tape_op(TS.program_tape("TEST", TS.source_records(OLD)), existing=PROG, routine="V2_VERIFY")
    return r["msg"] == "VERIFY_FAILED" and _intact(r), _d(r)


@case("D2-verify-last-byte", "VERIFY where only the final text byte differs -> VERIFY FAILED")
def d2_last_byte():
    other = bytearray(SRC)
    other[-2] ^= 0x01                              # last character before the CR
    r = P.tape_op(TS.program_tape("TEST", bytes(other)), existing=PROG, routine="V2_VERIFY")
    return r["msg"] == "VERIFY_FAILED" and _intact(r), _d(r)


@case("D2-verify-checksum", "VERIFY with a bad checksum -> VERIFY FAILED, program NOT erased")
def d2_checksum():
    r = P.tape_op(TS.program_tape("TEST", SRC, bad_checksum=True), existing=PROG, routine="V2_VERIFY")
    return r["msg"] == "VERIFY_FAILED" and _intact(r), _d(r)


@case("D2-verify-truncated", "VERIFY of a tape cut mid data block -> VERIFY FAILED, program intact")
def d2_truncated():
    r = P.tape_op(TS.program_tape("TEST", SRC, truncate_after=24), existing=PROG, routine="V2_VERIFY")
    return r["msg"] == "VERIFY_FAILED" and _intact(r), _d(r)


@case("D2-verify-dropout", "VERIFY with a dropout mid data block -> VERIFY FAILED, program intact")
def d2_dropout():
    r = P.tape_op(TS.program_tape("TEST", SRC, dropout=(20, 12)), existing=PROG, routine="V2_VERIFY")
    return r["msg"] == "VERIFY_FAILED" and _intact(r), _d(r)


@case("D2-verify-shorter-tape", "VERIFY where the tape is a PREFIX of the program -> VERIFY FAILED")
def d2_shorter():
    r = P.tape_op(TS.program_tape("TEST", TS.source_records(PROG[:3])), existing=PROG, routine="V2_VERIFY")
    return r["msg"] == "VERIFY_FAILED" and _intact(r), _d(r)


@case("D2-verify-longer-tape", "VERIFY where the tape extends past the program (stale RAM matches) -> VERIFY FAILED")
def d2_longer():
    keep = len(TS.source_records(PROG[:3]))

    def shrink():                                  # program = first 3 lines; the deleted lines linger in RAM
        P.poke16(P.sym("PROG_END"), P.sym("PROG_AREA_START") + keep)
    r = P.tape_op(TS.program_tape("TEST", SRC), existing=PROG, routine="V2_VERIFY", prepare=shrink)
    return r["msg"] == "VERIFY_FAILED" and _intact(r), _d(r)


@case("D2-verify-wrong-type", "VERIFY against a package-type tape -> VERIFY FAILED, program intact")
def d2_wrong_type():
    r = P.tape_op(TS.program_tape("TEST", SRC, htype=4), existing=PROG, routine="V2_VERIFY")
    return r["msg"] == "VERIFY_FAILED" and _intact(r), _d(r)


@case("D2-verify-wrong-name", "VERIFY against another file's tape -> VERIFY FAILED, program intact")
def d2_wrong_name():
    r = P.tape_op(TS.program_tape("OTHER", SRC), existing=PROG, routine="V2_VERIFY")
    return r["msg"] == "VERIFY_FAILED" and _intact(r), _d(r)


@case("D2-verify-space-abort", "SPACE during VERIFY -> ABORTED, program intact, VERIFY mode cleared")
def d2_space():
    def interfere():
        assert P.wait_in_data(16), "never reached the data block"
        P.press_space()
    r = P.tape_op(TS.program_tape("TEST", SRC), existing=PROG, routine="V2_VERIFY", interfere=interfere)
    return r["msg"] == "ABORTED" and _intact(r), _d(r)


@case("save-header", "SAVE hands the transport the program text under a type-0 header")
def save_header():
    P.boot()
    P.put_store(PROG)
    P.poke(P.sym("EDIT_LINE_BUF"), b'save "PROG"\0')
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_DISPATCH")))
    blocks = []
    send = P.sym("STORAGE_SEND_BLOCK")
    for _ in range(2):
        assert P.run_to(send, 20_000_000), "STORAGE_SEND_BLOCK not reached"
        r = P.regs()
        flag, ix, de = r["AF"] >> 8, r["IX"], r["DE"]
        blocks.append((flag, P.read(ix, de)))
        sp = r["SP"]
        ret = P.read(sp, 2)
        D("set-register", "SP", hex(sp + 2))
        D("set-register", "PC", hex(ret[0] | ret[1] << 8))
    msg = P.to_prompt()
    hdr = blocks[0][1]
    src = P.read(P.sym("PROG_AREA_START"), len(SRC))
    ok = (blocks[0][0] == 0x00 and blocks[1][0] == 0xFF and len(hdr) == 17 and hdr[0] == 0
          and hdr[1:11] == b"PROG      " and int.from_bytes(hdr[11:13], "little") == len(SRC)
          and int.from_bytes(hdr[13:15], "little") == ABI.fmt_word
          and blocks[1][1] == src and msg == "SAVED")
    return ok, "msg=%s header=%s word=%04X" % (msg, hdr.hex(), int.from_bytes(hdr[13:15], "little"))


# ----------------------------------------------------------------- packages
def _pkg_run(pkg, lines):
    P.boot()
    assert P.install_package(pkg), "package %s install failed" % pkg
    P.put_store(lines)
    P.call_prompt("V2_RUN_STORED")
    return P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0], P.read(P.sym("VM_ERROR_CODE"), 1)[0]


def _registry_names():
    base = P.sym("EXT2_TABLE")
    out = []
    for i in range(12):
        rec = P.read(base + 14 * i, 14)
        if rec[0]:
            out.append(rec[2:2 + rec[1]].decode())
    return out


@case("pkg-shapes", "SHAPES: CIRCLE then FILL paints the disc (pixel checks)")
def pkg_shapes():
    ce, ve = _pkg_run("shapes", ["CIRCLE 128,96,40", "FILL 128,96"])
    centre = P.read(pixel_addr(128, 96), 1)[0]
    rim = P.read(pixel_addr(128, 96 - 40), 1)[0] & 0x80
    outside = P.read(pixel_addr(128, 96 + 60), 1)[0]
    return (ce, ve) == (0, 0) and centre == 0xFF and rim and outside == 0, \
        "compile_err=%d vm_err=%d centre=%02X rim=%02X outside=%02X" % (ce, ve, centre, rim, outside)


@case("pkg-sprite", "SPRITE: GRAB/SHOW/MOVE/HIDE run; SHOW without GRAB and a bad slot raise 17 / 15")
def pkg_sprite():
    ce, ve = _pkg_run("sprite", ["GRAB 0,0,0,1,1", "SHOW 0,2,2", "MOVE 0,7,8", "HIDE 0"])
    ok_run = (ce, ve) == (0, 0)
    _, ve2 = _pkg_run("sprite", ["SHOW 1,2,2"])
    _, ve3 = _pkg_run("sprite", ["GRAB 9,0,0,1,1"])
    return ok_run and ve2 == 17 and ve3 == 15, "run=(%d,%d) show-without-grab=%d slot-9=%d" % (ce, ve, ve2, ve3)


@case("pkg-mode-errors", "MODE package: out-of-range MODE/ULAPLUS/PALETTE raise 12/13/14")
def pkg_mode_errors():
    got = []
    for stmt in ("MODE 5", "ULAPLUS 3", "PALETTE 64,0"):
        got.append(_pkg_run("mode", [stmt])[1])
    return got == [12, 13, 14], "errors=%s" % got


@case("pkg-mode-return", "MODE 1 then MODE 0 inside a program leaves the normal video mode")
def pkg_mode_return():
    ce, ve = _pkg_run("mode", ["MODE 1", "MODE 0"])
    shadow = P.read(P.sym("PORT_FF_SHADOW"), 1)[0] & 7
    return (ce, ve) == (0, 0) and shadow == 0, "compile_err=%d vm_err=%d video-mode-bits=%d" % (ce, ve, shadow)


@case("pkg-graphics", "GRAPHICS: BLOCK fills, FRAME outlines, INVERT toggles, CPLOT plots a coarse block")
def pkg_graphics():
    ce, ve = _pkg_run("graphics", ["BLOCK 8,8,15,15", "FRAME 40,40,63,55", "CPLOT 20,20", "INVERT 8,8,15,9"])
    blk_full = P.read(pixel_addr(8, 12), 1)[0] == 0xFF
    inverted = P.read(pixel_addr(8, 8), 1)[0] == 0x00
    frame_top = P.read(pixel_addr(40, 40), 1)[0] == 0xFF
    frame_hole = P.read(pixel_addr(48, 48), 1)[0] == 0x00
    cplot = P.read(pixel_addr(80, 80), 1)[0] & 0xF0 == 0xF0
    return (ce, ve) == (0, 0) and blk_full and inverted and frame_top and frame_hole and cplot, \
        "errs=(%d,%d) block=%s invert=%s frame=%s hole=%s cplot=%s" % (ce, ve, blk_full, inverted, frame_top,
                                                                     frame_hole, cplot)


@case("pkg-printer-install", "PRINTER: install registers LPRINT, LPRINT$ and LLIST")
def pkg_printer():
    P.boot()
    ok = P.install_package("printer")
    names = _registry_names()
    return ok and names == ["LPRINT", "LPRINT$", "LLIST"], "install_ok=%s registry=%s" % (ok, names)


@case("pkg-printer-lprint-number", "PRINTER: `LPRINT 123` returns to the editor without executing stray RAM",
      )
def pkg_printer_num():
    P.boot()
    assert P.install_package("printer")
    P.put_store(["LPRINT 123"])
    msg = P.call_prompt("V2_RUN_STORED", 30_000_000)
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return msg is None and P.pc() == IOK and ve == 0, "message=%s pc=%04X vm_err=%d" % (msg, P.pc(), ve)


@case("pkg-printer-lprint-string-llist", "PRINTER: LPRINT of a string and LLIST of the source return to the editor")
def pkg_printer_str():
    out = []
    for prog in (['a$ = "hi"', "LPRINT a$"], ["x = 1", "LLIST"]):
        P.boot()
        assert P.install_package("printer")
        P.put_store(prog)
        out.append((P.call_prompt("V2_RUN_STORED", 60_000_000), P.pc() == IOK,
                    P.read(P.sym("VM_ERROR_CODE"), 1)[0]))
    return all(m is None and back and ve == 0 for m, back, ve in out), "results=%s" % out


@case("pkg-registry-cleared-by-new", "NEW clears the package registry and window length")
def pkg_new():
    P.boot()
    P.install_package("shapes")
    before = _registry_names()
    P.poke(P.sym("EDIT_LINE_BUF"), b"new\0")
    P.call_prompt("V2_DISPATCH")
    after = _registry_names()
    ln = P.w16(P.sym("V2_PACKAGE_LEN"))
    return before == ["CIRCLE", "FILL"] and after == [] and ln == 0, "before=%s after=%s len=%d" % (before, after, ln)


# ------------------------------------------------------------------ package ABI 2.0
def _capture_save(command, prepare):
    """Run a SAVE command on the real dispatcher; return the two blocks the transport
    would have sent as [(flag, payload_bytes)] and the message shown."""
    P.boot()
    prepare()
    P.poke(P.sym("EDIT_LINE_BUF"), command.encode() + b"\0")
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_DISPATCH")))
    blocks = []
    send = P.sym("STORAGE_SEND_BLOCK")
    for _ in range(2):
        assert P.run_to(send, 20_000_000), "STORAGE_SEND_BLOCK not reached"
        r = P.regs()
        blocks.append((r["AF"] >> 8, P.read(r["IX"], r["DE"])))
        sp = r["SP"]
        ret = P.read(sp, 2)
        D("set-register", "SP", hex(sp + 2))
        D("set-register", "PC", hex(ret[0] | ret[1] << 8))
    return blocks, P.to_prompt()


def pkg_tape(name, blob, word):
    t = TS.Tape()
    t.block(TS.framed(0, TS.header_payload(4, name, len(blob), autostart=word)))
    t.block(TS.framed(0xFF, blob))
    return t


@case("abi-service-table", "the shipped ROM carries the ABI header and a `jp` for every slot")
def abi_table():
    P.boot()
    tbl = P.read(ABI.header, 4 + 3 * ABI.count)
    ok = list(tbl[:4]) == [ABI.magic, ABI.major, ABI.minor, ABI.count]
    bad = []
    for i, (pkg, home) in enumerate(ABI.services):
        slot = tbl[4 + 3 * i:7 + 3 * i]
        want = P.sym(home)
        if slot != bytes([0xC3, want & 0xFF, want >> 8]):
            bad.append(pkg)
    return ok and not bad, "header=%s bad slots=%s" % (tbl[:4].hex(), bad)


@case("abi-num-to-text-slot", "the NUM_TO_TEXT slot works with EXROM paged out and leaves the paging as it found it")
def abi_num_to_text():
    P.boot()
    slot = ABI.service_addr("VM_NUM_TO_TEXT")
    code = (b"\xCD" + struct.pack("<H", P.sym("BANK_PAGE_EXROM_OUT"))
            + b"\x21\x7B\x00\x3E\x00\xCD" + struct.pack("<H", slot) + b"\x18\xFE")
    P.poke(0xFE10, code)
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", "0xFE10")
    reached = P.run_to(0xFE10 + len(code) - 2, 2_000_000)
    r = P.regs()
    text = P.read(r["HL"], 4) if reached else b""
    depth = P.read(P.sym("BANK_EXROM_DEPTH"), 1)[0]
    return reached and text == b"123\0" and depth == 0, "reached=%s text=%r bank-depth=%d" % (reached, text, depth)


_PKG_WORDS = {"v1-unversioned-0001": 0x0001, "zero": 0x0000, "future-major": 0x8300,
              "newer-minor": 0x8201, "no-tag-bit": 0x0200, "program-word": 0x8100}
_PKG_BLOB = open("build/v2_package_shapes.bin", "rb").read()


def _pkg_load(word, name="SHAPES"):
    P.boot(pkg_tape(name, _PKG_BLOB, word))
    P.poke(P.sym("EXTENSION_MODULE_BASE"), b"\xEE" * 16)            # a marker the loader must not disturb on rejection
    P.poke(P.sym("EDIT_LINE_BUF"), b'load "%s" EXT\0' % name.encode())
    msg = P.call_prompt("V2_DISPATCH")
    return msg, _registry_names(), P.w16(P.sym("V2_PACKAGE_LEN")), P.read(P.sym("EXTENSION_MODULE_BASE"), 16)


@case("abi-pkg-load-shapes-tape", "a current-ABI package tape LOADs EXT through the real receiver, installs and runs")
def abi_pkg_tape_ok():
    msg, names, ln, _ = _pkg_load(ABI.pkg_word)
    P.put_store(["CIRCLE 128,96,40", "FILL 128,96"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    centre = P.read(pixel_addr(128, 96), 1)[0]
    return msg == "LOADED" and names == ["CIRCLE", "FILL"] and ln == len(_PKG_BLOB) and ve == 0 and centre == 0xFF, \
        "msg=%s registry=%s len=%d vm_err=%d centre=%02X" % (msg, names, ln, ve, centre)


@case("D1-pkg-truncated", "a package tape cut mid block -> LOAD FAILED, nothing executed, registry and window length cleared")
def d1_pkg_truncated():
    t = TS.Tape()
    t.block(TS.framed(0, TS.header_payload(4, "SHAPES", len(_PKG_BLOB), autostart=ABI.pkg_word)))
    t.block(TS.framed(0xFF, _PKG_BLOB), truncate_after=200)
    P.boot(t)
    P.poke(P.sym("EDIT_LINE_BUF"), b'load "SHAPES" EXT\0')
    msg = P.call_prompt("V2_DISPATCH", maxi=900_000_000)
    names, ln = _registry_names(), P.w16(P.sym("V2_PACKAGE_LEN"))
    return msg == "LOAD_FAILED" and names == [] and ln == 0, "msg=%s registry=%s len=%d" % (msg, names, ln)


@case("D1-pkg-space-abort", "SPACE during a package LOAD -> ABORTED, registry and window length cleared")
def d1_pkg_space():
    P.boot(pkg_tape("SHAPES", _PKG_BLOB, ABI.pkg_word))
    P.poke(P.sym("EDIT_LINE_BUF"), b'load "SHAPES" EXT\0')
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_DISPATCH")))
    assert P.wait_in_data(16, dest=P.sym("EXTENSION_MODULE_BASE")), "never reached the package data block"
    P.press_space()
    msg = P.to_prompt(900_000_000)
    names, ln = _registry_names(), P.w16(P.sym("V2_PACKAGE_LEN"))
    return msg == "ABORTED" and names == [] and ln == 0, "msg=%s registry=%s len=%d" % (msg, names, ln)


def _mk_reject_pkg(label, word):
    def fn():
        msg, names, ln, win = _pkg_load(word)
        return msg == "BAD_VERSION" and names == [] and ln == 0 and win == b"\xEE" * 16, \
            "word=%04X msg=%s registry=%s len=%d window-untouched=%s" % (word, msg, names, ln, win == b"\xEE" * 16)
    return fn


for _l, _w in _PKG_WORDS.items():
    case("abi-pkg-reject-" + _l, "package tape with header word %04X is refused before any byte reaches the window" % _w)(
        _mk_reject_pkg(_l, _w))


_PROG_WORDS = {"stock-no-autostart-8000": 0x8000, "unversioned-0000": 0x0000, "package-word-8200": 0x8200,
               "newer-minor-8101": 0x8101, "no-tag-bit-0100": 0x0100}


def _mk_reject_prog(label, word, verify):
    def fn():
        r = P.tape_op(TS.program_tape("TEST", SRC, autostart=word), existing=OLD,
                      routine="V2_VERIFY" if verify else "V2_LOAD")
        return r["msg"] == "BAD_VERSION" and r["after"] == r["before"] and r["op_state"] == 6, \
            "word=%04X msg=%s program-untouched=%s" % (word, r["msg"], r["after"] == r["before"])
    return fn


for _l, _w in _PROG_WORDS.items():
    case("abi-prog-reject-" + _l, "program tape with header word %04X is refused (LOAD), program untouched" % _w)(
        _mk_reject_prog(_l, _w, False))
case("abi-prog-reject-verify", "VERIFY of an unversioned tape reports BAD TAPE VERSION, program untouched")(
    _mk_reject_prog("verify", 0x0000, True))


@case("abi-save-stamps-program", "SAVE stamps the program-format word (type 0)")
def abi_save_program():
    blocks, msg = _capture_save('save "PROG"', lambda: P.put_store(PROG))
    hdr = blocks[0][1]
    return hdr[0] == 0 and int.from_bytes(hdr[13:15], "little") == ABI.fmt_word and msg == "SAVED", \
        "word=%04X" % int.from_bytes(hdr[13:15], "little")


@case("abi-save-stamps-package", "SAVE ... EXT stamps the package ABI word and saves the resident window")
def abi_save_package():
    def prep():
        assert P.install_package("shapes")
    blocks, msg = _capture_save('save "SH" EXT', prep)
    hdr, body = blocks[0][1], blocks[1][1]
    return hdr[0] == 4 and int.from_bytes(hdr[13:15], "little") == ABI.pkg_word and body == _PKG_BLOB \
        and msg == "SAVED", "type=%d word=%04X body=%d bytes" % (hdr[0], int.from_bytes(hdr[13:15], "little"), len(body))


@case("abi-save-load-roundtrip", "a program SAVEd by the ROM (blocks captured at the transport) LOADs back on a fresh boot")
def abi_roundtrip():
    prog = ["a = 3", "b = a * a", "c = b + 1"]
    blocks, msg = _capture_save('save "ROUND"', lambda: P.put_store(prog))
    t = TS.Tape()
    for flag, payload in blocks:
        t.block(TS.framed(flag, payload))
    r = P.tape_op(t, existing=OLD, name="ROUND")
    return r["msg"] == "LOADED" and r["after"] == TS.source_records(prog), "msg=%s" % r["msg"]


@case("abi-pkg-save-load-roundtrip", "a package SAVEd by the ROM LOADs back with LOAD EXT and still runs")
def abi_pkg_roundtrip():
    def prep():
        assert P.install_package("mode")
    blocks, msg = _capture_save('save "MD" EXT', prep)
    t = TS.Tape()
    for flag, payload in blocks:
        t.block(TS.framed(flag, payload))
    P.boot(t)
    P.poke(P.sym("EDIT_LINE_BUF"), b'load "MD" EXT\0')
    m = P.call_prompt("V2_DISPATCH")
    names = _registry_names()
    P.put_store(["MODE 5"])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    return m == "LOADED" and names == ["MODE", "ULAPLUS", "PALETTE"] and ve == 12, \
        "msg=%s registry=%s MODE 5 -> vm_err=%d" % (m, names, ve)


if __name__ == "__main__":
    sys.exit(P.run_cases(sys.argv[1:], "prod-regress"))
