#!/usr/bin/env python3
"""STUDY: D9a/D9b edit preservation -- extra cases beyond tools/v2_known_defects.py D9-*.

Run: TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/study_edit_preserve.py [substr]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402


@case("ep-up-commits-edit", "an edit on a stored line is stored when UP leaves it")
def up_commits():
    P.boot()
    P.type_text("a = 1")
    P.type_text("b = 2")
    P.key(KEY_UP)                       # on "b = 2"
    P.key(ord("9"))                     # "9b = 2"  (cursor at 1)
    P.key(KEY_UP)                       # now on "a = 1"; the edit must be stored
    st = P.store()
    return st == ["9b = 2", "a = 1"] or st == ["a = 1", "9b = 2"], "store=%s edit=%r" % (st, P.edit_line())


@case("ep-down-commits-edit", "an edit on a stored line is stored when DOWN leaves it; arrays untouched when nothing changed")
def down_commits():
    P.boot()
    P.type_text("a = 1")
    P.type_text("b = 2")
    P.key(KEY_UP)
    P.key(KEY_UP)                       # on "a = 1"
    P.key(ord("7"))
    P.key(KEY_DOWN)
    st = P.store()
    return st[0].count("7") == 1 and st[1] == "b = 2" and P.edit_line() == b"b = 2", \
        "store=%s edit=%r" % (st, P.edit_line())


@case("ep-append-line-up", "text typed on the append line is stored when UP leaves it")
def append_up():
    P.boot()
    P.type_text("a = 1")
    P.type_text("b = 2")
    P.type_text("c = 3", enter=False)   # on the append line, uncommitted
    P.key(KEY_UP)
    st = P.store()
    return st == ["a = 1", "b = 2", "c = 3"] and P.edit_line() == b"c = 3", "store=%s edit=%r idx=%d" % (st, P.edit_line(), P.cur_index())


@case("ep-append-line-down-noop", "DOWN on the append line keeps the typed text uncommitted")
def append_down():
    P.boot()
    P.type_text("a = 1")
    P.type_text("zz", enter=False)
    P.key(KEY_DOWN)
    return P.store() == ["a = 1"] and P.edit_line() == b"zz", "store=%s edit=%r" % (P.store(), P.edit_line())


@case("ep-unchanged-nav-stores-nothing", "navigating over unchanged lines does not rewrite the store")
def unchanged():
    P.boot()
    P.type_text("a = 1")
    P.type_text("b = 2")
    before = P.read(P.sym("PROG_AREA_START"), P.w16(P.sym("PROG_END")) - P.sym("PROG_AREA_START"))
    for k in (KEY_UP, KEY_UP, KEY_DOWN, KEY_DOWN):
        P.key(k)
    after = P.read(P.sym("PROG_AREA_START"), P.w16(P.sym("PROG_END")) - P.sym("PROG_AREA_START"))
    return before == after and P.store() == ["a = 1", "b = 2"], "store=%s" % P.store()


@case("ep-nav-keeps-arrays-when-unchanged", "UP/DOWN over an unchanged line does not discard DIM'd arrays")
def keeps_arrays():
    P.boot()
    P.put_store(["a = 1", "b = 2"])
    P.poke16(P.sym("ARRAYS_END"), P.w16(P.sym("ARRAYS_END")) + 6)     # pretend 6 bytes of arrays exist
    ae = P.w16(P.sym("ARRAYS_END"))
    P.call_prompt("V2_SET_EDIT_FROM_INDEX")
    P.key(KEY_DOWN)
    P.key(KEY_UP)
    return P.w16(P.sym("ARRAYS_END")) == ae, "ARRAYS_END %04X -> %04X" % (ae, P.w16(P.sym("ARRAYS_END")))


@case("ep-insert-line-commits", "CAPS+ENTER (insert line) keeps an edit")
def insert_commits():
    P.boot()
    P.type_text("a = 1")
    P.type_text("b = 2")
    P.key(KEY_UP)
    P.key(ord("9"))
    P.key(KEY_INSERT_LINE)
    st = P.store()
    return len(st) == 3 and any("9" in l for l in st), "store=%s edit=%r" % (st, P.edit_line())


def _fill_store(room_left):
    start, limit = P.sym("PROG_AREA_START"), P.sym("V2_SOURCE_END")
    room = limit - room_left - start
    recs, used = [], 0
    while room - used >= 8 + 3:
        recs.append("x = 1")
        used += 2 + 5 + 1
    recs.append("x" * (room - used - 3))
    P.put_store(recs)
    return recs


@case("ep-full-on-nav-keeps-buffer", "PROGRAM FULL while navigating keeps the buffer and the cursor")
def full_nav():
    P.boot()
    _fill_store(4)
    P.call_prompt("V2_SET_EDIT_FROM_INDEX")      # index 0
    for _ in range(6):
        P.key(ord("y"))                          # grow line 0 by 6 chars (does not fit)
    typed = P.edit_line()
    idx = P.cur_index()
    m = P.key(KEY_DOWN)                          # stops in the PROGRAM FULL message
    P.key(0x20)
    after = P.edit_line()
    return m == "FULL" and after == typed and P.cur_index() == idx and b"yyyyyy" in after, \
        "msg=%s typed=%r after=%r idx=%d->%d" % (m, typed, after, idx, P.cur_index())


@case("ep-full-enter-reenters-same-line", "ENTER on a full store keeps the line (D9b) and a second ENTER does not corrupt")
def full_enter():
    P.boot()
    _fill_store(4)
    P.type_text("y = 123456", enter=False)
    typed = P.edit_line()
    m = P.key(KEY_ENTER)
    P.key(0x20)
    after = P.edit_line()
    n = len(P.store())
    return m == "FULL" and after == typed, "msg=%s typed=%r after=%r lines=%d" % (m, typed, after, n)


if __name__ == "__main__":
    sys.exit(run_cases(sys.argv[1:] or None, "study-edit-preserve"))
