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


# ------------------------------------- the cursor's line whole on screen (plan item SH_VIEW, ED4)
# The view: up to 20 lines above the cursor's line, fewer when they do not fit on rows 0-22 with it.
# tools/qual/qeditview.py runs the long scenarios (every key, a full-redraw oracle, timings).
def _rows(text, edit=False):
    """Screen rows of a line as EDITOR_WRAP_CALC wraps it (at the last space of 32 characters); the
    edit buffer (`edit`) has one more, empty, row after a last row of 32 characters (V2_WRAP_EDIT, ED7)."""
    n = 1
    while len(text) > 32 and n < 8:
        sp = text[:32].rfind(" ")
        text = text[32:] if sp < 0 else text[sp + 1:]
        n += 1
    return n + (edit and len(text) == 32)


def _edit_at(lines, idx):
    """Boot, store `lines`, enter the editor on line `idx` (the append line when idx = len(lines))."""
    P.boot()
    P.put_store(lines)
    pos = sym("PROG_AREA_START") + sum(len(l) + 3 for l in lines[:idx]) if idx < len(lines) else 0xFFFF
    P.poke16(sym("CUR_EDIT_INDEX"), idx)
    P.poke16(sym("CUR_EDIT_POS"), pos)
    return P.call(RET)


def _view(keys=()):
    """After the entry and after each key: the view rule's top and active row, the line whole, the
    cursor cell the only inverted attribute on rows 0-22, in the line's rows."""
    seen = []
    for k in (None,) + tuple(keys):
        if k is not None:
            P.key(k)
        h = [_rows(l) for l in P.store()]
        idx, ha = P.cur_index(), _rows(P.edit_line().decode("latin-1"), True)
        top = max(0, idx - 20)
        while sum(h[top:idx]) + ha > 23:
            top += 1
        row = sum(h[top:idx])
        got = (w16(sym("VIEW_TOP_INDEX")), read(sym("BASIC_ACTIVE_ROW"), 1)[0])
        cur = [i // 32 for i, a in enumerate(read(0x5800, 23 * 32)) if a != 0x38]
        seen.append("%d:%d@%d%s" % (idx, got[0], got[1], cur))
        if got != (top, row) or row + ha > 23 or len(cur) != 1 or not row <= cur[0] < row + ha:
            return False, "line %d: top/row %s (want %d/%d), cursor rows %s; %s" % (idx, got, top, row, cur,
                                                                                  " ".join(seen))
    return True, " ".join(seen)


SHORT = ["v%d = %d" % (i, i) for i in range(20)]
WRAP2 = ["PRINT \"line %d is long enough to wrap\"; %d" % (i, i) for i in range(20)]   # 2 rows each


@case("ED4-long-line-low", "a 4-row line starting on row 20 scrolls the view to show it whole")
def ed4_long_line_low():
    _edit_at(SHORT + ["x" * 100, "y = 1"], 20)
    return _view([KEY_DOWN] * 4 + [KEY_UP])        # three rows down inside it, then the line below


@case("ED4-wrapped-above", "20 two-row lines above: lines are dropped from the top until the cursor's fits")
def ed4_wrapped_above():
    _edit_at(WRAP2 + ["y = 1"], 20)
    return _view([KEY_UP, KEY_UP, KEY_DOWN, KEY_DOWN])


@case("ED4-grow-past-22", "typing that makes a line on rows 20-22 a 4th row scrolls; DELETE scrolls it back")
def ed4_grow_past_22():
    _edit_at(SHORT + ["x" * 96], 20)
    return _view([ord("z"), KEY_DELETE])


@case("ED4-down-onto-tall", "DOWN onto a 4-row line on row 20 scrolls the view to show it whole")
def ed4_down_onto_tall():
    _edit_at(SHORT + ["x" * 100], 19)
    return _view([KEY_DOWN, KEY_UP])


# ED7: the cursor after a last row of exactly 32 characters was at column 32, off the screen (and LEFT
# from there whitened the first cell of the row below).  The edit buffer now has an empty row after it.
def _cursor_cell():
    cells = [(i // 32, i % 32) for i, a in enumerate(read(0x5800, 23 * 32)) if a != 0x38]
    return cells[0] if len(cells) == 1 else cells


@case("ED7-cursor-after-32", "after 32 typed characters the cursor shows at the start of the line's next row")
def ed7_cursor_after_32():
    P.boot()
    for ch in "x" * 32:
        P.key(ord(ch))
    row = read(sym("BASIC_ACTIVE_ROW"), 1)[0]
    at32 = _cursor_cell()
    P.key(KEY_LEFT)
    left = _cursor_cell()
    P.key(KEY_RIGHT)
    right = _cursor_cell()
    P.key(ord("y"))
    at33 = _cursor_cell()
    ok = (at32, left, right, at33) == ((row + 1, 0), (row, 31), (row + 1, 0), (row + 1, 1))
    return ok, "row %d: cursor at 32 %s, LEFT %s, RIGHT %s, at 33 %s" % (row, at32, left, right, at33)


@case("ED7-edit-row-low", "a 64-character line on rows 21-22: its edit row does not fit, so the view scrolls")
def ed7_edit_row_low():
    _edit_at(WRAP2[:1] + SHORT[:19] + ["q" * 63], 20)
    for _ in range(63):
        P.key(KEY_RIGHT)
    return _view([ord("q"), KEY_DELETE, KEY_UP, KEY_DOWN])


# ED3: a command typed over a program line ran nowhere and replaced the line (only the last line
# dispatched commands).  Now ENTER carries a command out on any line and the line keeps its text.
def _over_line(lines, idx, command):
    """Edit `lines`, go to line `idx`, delete its text, type `command` and ENTER."""
    P.boot()
    for t in lines:
        P.type_text(t)
    for _ in range(len(lines) - idx):
        P.key(KEY_UP)
    for _ in lines[idx]:
        P.key(KEY_RIGHT)
    for _ in lines[idx]:
        P.key(KEY_DELETE)
    return P.type_text(command)


ED3_PROG = ["x = 5", "y = x * 2", "z = y + 1"]


@case("ED3-run-over-a-line", "RUN typed over line 1 runs the program; line 1 keeps its text")
def ed3_run():
    _over_line(ED3_PROG, 0, "run")
    v = P.variables(3)
    P.key(0x20)                              # the run's end: any key back to the editor
    st, idx, line = P.store(), P.cur_index(), P.edit_line()
    ok = [x[1] for x in v] == [5, 10, 11] and st == ED3_PROG and idx == 0 and line == b"x = 5"
    return ok, "vars=%s store=%s cursor=%d line=%r" % (v, st, idx, line)


@case("ED3-list-over-a-line", "LIST typed over line 2 lists; the program is unchanged")
def ed3_list():
    _over_line(ED3_PROG, 1, "LIST")
    shown = read(0x5800, 1) is not None
    P.key(0x20)
    st, idx, line = P.store(), P.cur_index(), P.edit_line()
    return shown and st == ED3_PROG and idx == 1 and line == b"y = x * 2", \
        "store=%s cursor=%d line=%r" % (st, idx, line)


@case("ED3-immediate-over-a-line", "`: statement` typed over a line runs it; the line keeps its text")
def ed3_immediate():
    _over_line(ED3_PROG, 2, ": q = 7")
    P.key(0x20)
    st, idx, line = P.store(), P.cur_index(), P.edit_line()
    return st == ED3_PROG and idx == 2 and line == b"z = y + 1", "store=%s cursor=%d line=%r" % (st, idx, line)


@case("ED3-new-over-a-line", "NEW typed over a line wipes the program, as on the last line")
def ed3_new():
    _over_line(ED3_PROG, 1, "new")
    return P.store() == [] and P.cur_index() == 0, "store=%s cursor=%d" % (P.store(), P.cur_index())


@case("ED3-text-still-stored", "text that is not a command (`run = 4`, `listing = 2`) still replaces the line")
def ed3_text():
    _over_line(ED3_PROG, 0, "run = 4")
    P.key(KEY_UP)
    for _ in "run = 4":
        P.key(KEY_RIGHT)
    for _ in "run = 4":
        P.key(KEY_DELETE)
    P.type_text("listing = 2")
    st = P.store()
    return st == ["listing = 2", "y = x * 2", "z = y + 1"], "store=%s" % st


# ------------------------------------------------------------- tape (LOAD/VERIFY)
@case("tape-load-ok", "a well-formed program tape LOADs through the real receiver")
def tape_load_ok():
    r = P.tape_op(TS.program_tape("TEST", SRC), existing=OLD)
    data = P.read(P.sym("PROG_AREA_START"), len(SRC))
    return r["msg"] == "LOADED" and data == SRC and r["prog_end"] == P.sym("PROG_AREA_START") + len(SRC), \
        "msg=%s prog_end=%04X" % (r["msg"], r["prog_end"])


# ------------------------------------------- tape failure semantics (R10.9 Phase 2A, D1/D2)
# Policy under test (docs/R10_9_PHASE2A_REPORT.md s3):
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
        D("set-register", "AF", hex(r["AF"] | 1))  # the real sender's success: carry set (STORAGE_SAVE stops on carry clear)
        D("set-register", "PC", hex(ret[0] | ret[1] << 8))
    msg = P.to_prompt()
    hdr = blocks[0][1]
    src = P.read(P.sym("PROG_AREA_START"), len(SRC))
    ok = (blocks[0][0] == 0x00 and blocks[1][0] == 0xFF and len(hdr) == 17 and hdr[0] == 0
          and hdr[1:11] == b"PROG      " and int.from_bytes(hdr[11:13], "little") == len(SRC)
          and int.from_bytes(hdr[13:15], "little") == ABI.fmt_word
          and blocks[1][1] == src and msg == "SAVED")
    return ok, "msg=%s header=%s word=%04X" % (msg, hdr.hex(), int.from_bytes(hdr[13:15], "little"))


def _save_with_space(blocks_before):
    """A real SAVE through the dispatcher and the real sender; SPACE goes down in the emulated
    keyboard matrix once `blocks_before` + 1 blocks have started. Returns (message, a later block
    started)."""
    P.boot()
    P.put_store(PROG)
    P.poke(P.sym("EDIT_LINE_BUF"), b'save "PROG"\0')
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_DISPATCH")))
    send = P.sym("STORAGE_SEND_BLOCK")
    for _ in range(blocks_before + 1):
        assert P.run_to(send, 40_000_000), "STORAGE_SEND_BLOCK not reached"
        D("step")
    P.zr("send-keys-event 128 1")                   # SPACE down
    try:
        D("break", "V2_SHOW_MESSAGE", "--index", "2")
        D("break", hex(send), "--index", "3")
        D("run", "--until", hex(IOK), "--max-instructions", "200000000", t=1800)
        D("pause")
        at = P.pc()
        msg = P.msg_name(P.regs()["HL"]) if at == P.sym("V2_SHOW_MESSAGE") else None
    finally:
        P.zr("send-keys-event 128 0")
        D("clear-break", "--index", "2")
        D("clear-break", "--index", "3")
    return msg, at == send


@case("save-space-abort-header", "SPACE during SAVE's header -> ABORTED, the data block is never sent")
def save_space_header():
    msg, later = _save_with_space(0)
    return msg == "ABORTED" and not later, "msg=%s data block started=%s" % (msg, later)


@case("save-space-abort-data", "SPACE during SAVE's data block -> ABORTED, not SAVED")
def save_space_data():
    msg, later = _save_with_space(1)
    return msg == "ABORTED" and not later, "msg=%s another block started=%s" % (msg, later)


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
        D("set-register", "AF", hex(r["AF"] | 1))  # the real sender's success: carry set (STORAGE_SAVE stops on carry clear)
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


# 6.1: "newer" is the ROM's own package word + 1 (ABI 2.1 now), as for the program format below
_PKG_WORDS = {"v1-unversioned-0001": 0x0001, "zero": 0x0000, "future-major": 0x8300,
              "newer-minor": ABI.pkg_word + 1, "no-tag-bit": 0x0200, "program-word": 0x8100}
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


# RC: the program-format minor is 1 (SAVE ALL), so "newer" is the ROM's own word + 1, not $8101
_PROG_WORDS = {"stock-no-autostart-8000": 0x8000, "unversioned-0000": 0x0000, "package-word-8200": 0x8200,
               "newer-minor-%04x" % (ABI.fmt_word + 1): ABI.fmt_word + 1, "no-tag-bit-0100": 0x0100}


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


@case("abi-prog-load-older-minor", "a program tape with an older minor of the same major (minor 0, $8100) still LOADs")
def abi_prog_older_minor():
    r = P.tape_op(TS.program_tape("TEST", SRC, autostart=0x8100), existing=OLD)
    data = P.read(P.sym("PROG_AREA_START"), len(SRC))
    return ABI.fmt_word > 0x8100 and r["msg"] == "LOADED" and data == SRC, \
        "rom word=%04X msg=%s program-loaded=%s" % (ABI.fmt_word, r["msg"], data == SRC)


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


# ----------------------------------------------------- strict compilation (R10.9 2D)
# D3: anything that is not a valid program is a compile error, never a silent stop.  Compile error
# codes: 64 unexpected token, 65 FOR without NEXT, 66 missing ')' (docs/R10_9_PHASE2D_REPORT.md).
D3_FAMILIES = {
    "stray-ENDIF": (["x = 1", "ENDIF", "y = 2"], 64),
    "stray-ELSE": (["x = 1", "ELSE", "y = 2"], 64),
    "stray-THEN": (["x = 1", "THEN", "y = 2"], 64),
    "stray-rparen": (["x = 1", ")", "y = 2"], 64),
    "stray-TO": (["x = 1", "TO", "y = 2"], 64),
    "stray-ENDP": (["x = 1", "ENDP", "y = 2"], 64),
    "leading-line-number": (["10 x = 5", "y = 2"], 64),
    "missing-colon": (["x = 1 y = 2", "z = 3"], 64),
    "trailing-rparen": (["x = (1))", "y = 2"], 64),
    "infix-MOD": (["x = 7 MOD 2", "y = 2"], 64),
    # STUDY (Enhanced): `PRINT x; x` and `PRINT x, x` are valid statements now (multi-item PRINT)
    "chained-compare": (["x = 1 < 2 < 3", "y = 2"], 64),
    "string-slice": (['a$ = "abcdef"', "b$ = a$(2 TO 3)", "y = 2"], 64),
    "apostrophe-comment": (["x = 1 ' c", "y = 2"], 64),
    "embedded-quote": (['a$ = "a""b"', "y = 2"], 64),
    "unclosed-paren": (["x = (1 + 2", "y = 2"], 66),
    "FOR-without-NEXT": (["for i = 1 to 3", "x = i", "y = 2"], 65),
}
D3_ALREADY_CORRECT = {            # these were already compile errors before Phase 2D
    "incomplete-expression": (["x = 1 +", "y = 2"], 3),
    "unknown-statement-word": (["FROBNICATE 1", "y = 2"], 2),
}


def _d3(prog, code):
    def fn():
        ce, ve, msg = P.run_program(prog)
        ran = P.variables(1)[0][1] == 1                 # `x = 1` must never have executed
        return ce == code and ve == 0 and not ran, \
            "compile_err=%d (want %d) vm_err=%d msg=%s executed=%s" % (ce, code, ve, msg, ran)
    return fn


for _n, (_p, _c) in D3_FAMILIES.items():
    case("D3-" + _n, "malformed program is a compile error and nothing runs")(_d3(_p, _c))
for _n, (_p, _c) in D3_ALREADY_CORRECT.items():
    case("D3-ok-" + _n, "malformed program is a compile error (positive control)")(_d3(_p, _c))


@case("D3-ok-valid-colon-line", "valid multi-statement line compiles (positive control)")
def d3_valid():
    ce, ve, msg = P.run_program(["x = 1 : y = 2", "z = x + y"])
    v = P.variables(3)
    return ce == 0 and ve == 0 and v[2][1] == 3, "compile_err=%d vals=%s" % (ce, v)


KITCHEN_SINK = [
    "REM strict compile control: every closer and separator form",
    "n = 0 : t = 0",
    "DEF FN sq(x) = x * x",
    "PROC addn(k):",
    "t = t + k",
    "ENDP",
    "FOR i = 1 TO 4 STEP 1",
    "IF i > 2 THEN",
    "CALL addn(i * i)",
    "ELSE",
    "n = n + 1",
    "ENDIF",
    "NEXT i",
    'a$ = "hi: there"',
    'IF a$ = "hi: there" THEN n = n + 10 : t = t + FN sq(0) ENDIF',
    "top:",
    "n = n + 100",
    "IF n < 100 THEN GOTO top",
    "REM trailing comment:",
    "done: n = n + (1 + 2) * 3 : IF NOT (n < 0) AND n > 0 THEN n = n + 1 ENDIF",
]


@case("D3-ok-valid-program", "a program using every closer, ':' continuation and REM compiles and runs")
def d3_kitchen_sink():
    ce, ve, msg = P.run_program(KITCHEN_SINK)
    v = P.variables(2)
    return (ce, ve) == (0, 0) and v[0][1] == 122 and v[1][1] == 25, \
        "compile_err=%d vm_err=%d n,t=%s want (122, 25)" % (ce, ve, v)


@case("D3-message", "an unexpected token is reported as UNEXPECTED TOKEN")
def d3_message():
    ce, ve, msg = P.run_program(["x = 1 2"])
    return ce == 64 and msg == "UNEXPECTED", "compile_err=%d msg=%s" % (ce, msg)


@case("D3-unterminated-string", "an unterminated string literal is an error on its own line, not the rest of the program")
def d3_string():
    ce, ve, msg = P.run_program(["x = 1", 'a$ = "abc', "y = 2"])
    return ce == 64 and msg == "UNEXPECTED" and P.cur_index() == 1, \
        "compile_err=%d msg=%s cursor=%d" % (ce, msg, P.cur_index())


@case("D3-unterminated-string-print", "an unterminated string after PRINT is an error on its own line")
def d3_string_print():
    ce, ve, msg = P.run_program(["x = 1", "y = 2", 'PRINT "abc', "z = 3"])
    return ce == 64 and P.cur_index() == 2, "compile_err=%d cursor=%d" % (ce, P.cur_index())


@case("D3-ok-colon-in-string", "':' and keywords inside a string literal are text")
def d3_colon_string():
    ce, ve, msg = P.run_program(['a$ = "x: THEN ENDIF )"', "n = LEN(a$)"])
    v = P.variables(1)
    return ce == 0 and v[0][1] == 15, "compile_err=%d n=%s" % (ce, v)


@case("D3-rem-ending-colon", "a REM line ending in ':' ends at its line instead of commenting out the next line")
def d3_rem_colon():
    ce, ve, msg = P.run_program(["REM a note:", "x = )"])
    return ce == 3 and P.cur_index() == 1, "compile_err=%d cursor=%d" % (ce, P.cur_index())


@case("D3-failed-compile-then-good", "a failed compile leaves no program behind and the next compile starts clean")
def d3_recompile():
    ce1, ve1, msg1 = P.run_program(["x = 5", "y = 1 2"])
    ran = P.variables(1)[0][1] == 5
    P.put_store(["x = 5", "y = 6"])
    msg2 = P.call_prompt("V2_RUN_STORED")
    ce2 = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    v = P.variables(2)
    return ce1 == 64 and not ran and ce2 == 0 and v[0][1] == 5 and v[1][1] == 6, \
        "first: compile_err=%d executed=%s; second: compile_err=%d vals=%s msg=%s" % (ce1, ran, ce2, v, msg2)


# ------------------------------------------------------ compile-error line (R10.9 2D)
# D4: a compile error puts the cursor on the source line that contains it.
def _d4_prog(length_stmts, k):
    ok = " : ".join(["x = 1"] * length_stmts)
    bad = " : ".join(["x = 1"] * (length_stmts - 1) + ["x = )"])
    return [bad if i == k else ok for i in range(20)]


def _d4(n, k):
    def fn():
        ce, ve, msg = P.run_program(_d4_prog(n, k))
        idx = P.cur_index()
        return ce != 0 and idx == k, "compile_err=%d cursor_line=%d want=%d" % (ce, idx, k)
    return fn


for _n in (1, 4, 9):                         # ~5, ~29, ~69 characters per line
    for _k in (0, 2, 5, 10, 19):
        case("D4-len%d-line%d" % (_n * 8 - 3, _k), "compile error lands on its own source line")(_d4(_n, _k))


def _line_case(cid, title, prog, want_line, want_code):
    @case(cid, title)
    def fn():
        ce, ve, msg = P.run_program(prog)
        idx = P.cur_index()
        return ce == want_code and idx == want_line, \
            "compile_err=%d (want %d) cursor_line=%d (want %d)" % (ce, want_code, idx, want_line)


# error on the last token of a line, on a line that ends in ':' (no CR token), after continuation lines
_line_case("D4-continuation-before", "line count includes lines that end in ':'",
           ["a = 1:", "b = 2:", "c = 3", "d = )", "e = 5"], 3, 3)
_line_case("D4-continuation-on", "error on a line that ends in ':'",
           ["a = 1:", "b = ):", "c = 3"], 1, 3)
_line_case("D4-junk-last-line", "trailing junk on the last line", ["x = 1", "y = 2", "z = 3 4"], 2, 64)
_line_case("D4-junk-first-line", "trailing junk on the first of several lines", ["x = 1 2", "y = 2", "z = 3"], 0, 64)
_line_case("D4-eol-incomplete", "an expression cut off at the end of its line is that line's error",
           ["x = 1", "y = 2 +", "z = 3"], 1, 3)
_line_case("D4-blank-lines", "blank and REM lines count", ["", "REM c", "", "x = )", ""], 3, 3)
_line_case("D4-after-label", "a label line counts as a line", ["start:", "x = 1", "GOTO start 5"], 2, 64)
# Errors that can only be detected at end of source leave the cursor on the append position (the empty
# line after the last one, index == number of lines), where the missing NEXT / ENDP / ENDIF / label goes.
_line_case("D4-eof-for", "STUDY (N-3): an unterminated FOR puts the cursor on the FOR", ["FOR i = 1 TO 3", "x = i"], 0, 65)
_line_case("D4-eof-proc", "an unterminated PROC puts the cursor at the end of the program",
           ["PROC p(a):", "x = 1", "y = 2"], 3, 16)
_line_case("D4-eof-if", "an unterminated block IF puts the cursor at the end of the program", ["IF 1 THEN", "x = 1"], 2, 9)
_line_case("D4-undefined-label", "an undefined label (checked at the end) puts the cursor at the end of the program",
           ["GOTO nowhere", "x = 1", "y = 2"], 3, 7)
_line_case("D4-eof-trailing-colon", "STUDY (N-3): end-of-source error after a last line that ends in ':' reports the FOR", ["FOR i = 1 TO 3", "x = i:"], 0, 65)
_line_case("D4-stray-endif-late", "a stray ENDIF names its own line", ["x = 1", "y = 2", "z = 3", "ENDIF", "w = 4"], 3, 64)
_line_case("D4-unclosed-paren", "an unclosed parenthesis names its own line", ["x = 1", "y = (1 + 2", "z = 3"], 1, 66)


@case("D4-typed-run-path", "typing `run` at the prompt lands the editor on the failing line with its text loaded")
def d4_typed():
    P.boot()
    for t in ("x = 1", "y = 2 3", "z = 4"):
        P.type_text(t)
    P.type_text("run")
    P.key(0x20)                              # dismiss the message
    idx, line = P.cur_index(), P.edit_line()
    return idx == 1 and line == b"y = 2 3", "cursor=%d edit line=%r" % (idx, line)


if __name__ == "__main__":
    sys.exit(P.run_cases(sys.argv[1:], "prod-regress"))
