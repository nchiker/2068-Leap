#!/usr/bin/env python3
"""STUDY: editor redraw evidence on the REAL production ROM.

Per key of scripted sessions it records (a) T-states from key delivery to the next key wait (ZRCP get-tstates-partial),
(b) how many times the full-screen clear GFX_CLS, the per-line draw V2_DRAW_TEXT and the per-row GFX_CLEAR_ROW_TEXT run
(breakpoint hits), and (c) with --diff, whether the screen (bitmap+attributes, 6912 B) after the key equals the screen a
FULL redraw produces from the same editor state (differential oracle: selective == full).
Run in a worktree after `make build`:
   TS2068_DEBUG_STATE_DIR=<d> TS2068_V2_PORT=<p> python3 tools/study_flicker.py [--diff] [--json out.json] [scenario ...]
"""
import json
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402

LEFT, RIGHT, UP, DOWN, DEL = KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_DELETE
SCREEN = 0x4000


def prog(n, width=24):
    base = ["total = total + item * 2", "FOR k = 1 TO 10", "x = x + k", "PRINT x", "IF x > 20 THEN GOTO done",
            "y = (x * 3) / 2 + 7", "NEXT k", "done:", "count = count + 1", "z = x + y"]
    out = []
    for i in range(n):
        out.append(base[i % len(base)])
    return out


def seq(s):
    return [ord(c) for c in s]


SCENARIOS = {
    # name: (program lines, start index, keys)
    "type-10lines":   (prog(10), 5, seq("abc = abc + 1") + [DEL] * 4),
    "type-20lines":   (prog(20), 10, seq("abc = abc + 1") + [DEL] * 4),
    "type-wrapchg":   (["a = 1", "x = 'a very long line that is going to wrap onto the second screen row'", "b = 2"], 1,
                       seq("0123456789012345") + [DEL] * 3),
    "lr-10lines":     (prog(10), 5, [RIGHT] * 6 + [LEFT] * 6),
    "updown-10lines": (prog(10), 5, [DOWN, DOWN, UP, UP, UP, DOWN]),
    "updown-20lines": (prog(20), 10, [DOWN, DOWN, UP, UP, UP, DOWN]),
    # edge cases for the differential oracle
    "updown-ends":    (prog(6), 0, [UP, DOWN, DOWN, DOWN, DOWN, DOWN, DOWN, DOWN, UP, UP, UP, UP, UP, UP, UP, UP]),
    "updown-wrapped": (["short", "x = 'a very long line that is going to wrap onto the second screen row and then a third one maybe'",
                        "mid line", "y = 'another long one: padding padding padding padding padding padding'", "end"], 0,
                       [DOWN, DOWN, DOWN, DOWN, DOWN, UP, UP, UP, UP, UP, UP, DOWN, RIGHT, RIGHT, DOWN, DOWN, UP]),
    "updown-typed":   (prog(8), 3, seq("zz") + [DOWN, UP, UP] + seq("q") + [DOWN]),
    "updown-deep":    (prog(26), 18, [DOWN, DOWN, DOWN, DOWN, UP, UP, UP, UP, UP]),
    "mixed-session":  (prog(10), 4, seq("a") + [UP, DOWN] + seq("bb") + [DEL, LEFT, DOWN, RIGHT] + seq("c") + [UP, UP, DOWN]),
}


def tstates():
    return int(zr("get-tstates-partial"))


class Counter:
    """Counts hits of a few routines while a key is processed."""
    SPEC = [("cls", "GFX_CLS"), ("drawtext", "V2_DRAW_TEXT"), ("rowclr", "GFX_CLEAR_ROW_TEXT")]

    def __init__(self):
        self.addr = {}
        for i, (n, s) in enumerate(self.SPEC):
            self.addr[n] = (P.sym(s), 3 + i)

    def run_key(self, code, maxi=80_000_000):
        P.poke(P.sym("KBD_LASTK"), code)
        P.poke(P.sym("KBD_KEYHIT"), 1)
        hits = {n: 0 for n, _ in self.SPEC}
        for n, (a, idx) in self.addr.items():
            D("break", hex(a), "--index", str(idx))
        zr("reset-tstates-partial")
        try:
            for _ in range(400):
                D("run", "--until", hex(IOK), "--max-instructions", str(maxi), t=1800)
                D("pause")
                p = P.pc()
                if p == IOK:
                    break
                for n, (a, idx) in self.addr.items():
                    if p == a:
                        hits[n] += 1
                        D("clear-break", "--index", str(idx))
                        D("step", "--count", "1")
                        D("break", hex(a), "--index", str(idx))
                        break
        finally:
            for n, (a, idx) in self.addr.items():
                try:
                    D("clear-break", "--index", str(idx))
                except Exception:
                    pass
        return hits, tstates()


def screen():
    return read(SCREEN, 6912)


def full_redraw_reference():
    """Screen a FULL redraw of the current editor state produces (V2_REDRAW with scope 0).  The editor stays
    parked in its key wait: registers are saved and restored, the redraw runs on a stack frame below SP."""
    r = regs()
    saved = screen()
    stub = 0xF800
    P.poke(stub, b"\x18\xFE")                                  # jr $
    sp = r["SP"] - 2
    P.poke(sp, struct.pack("<H", stub))
    if "V2_REDRAW_SCOPE" in SYM:
        P.poke(P.sym("V2_REDRAW_SCOPE"), 0)
    D("set-register", "SP", hex(sp))
    D("set-register", "PC", hex(P.sym("V2_REDRAW")))
    assert P.run_to(stub, 80_000_000), "reference redraw did not return"
    ref = screen()
    for k in ("AF", "BC", "DE", "HL", "IX", "IY", "SP", "PC"):
        D("set-register", k, hex(r[k]))
    return saved, ref


def run_scenario(name, do_diff, use_counter=True):
    lines, start, keys = SCENARIOS[name]
    P.boot()
    P.put_store(lines)
    P.poke16(P.sym("CUR_EDIT_INDEX"), start)
    P.call_prompt("V2_SET_EDIT_FROM_INDEX")
    ctr = Counter() if use_counter else None
    rows, mism = [], 0
    for k in keys:
        if ctr:
            hits, t = ctr.run_key(k)
        else:
            zr("reset-tstates-partial")
            P.key(k)
            hits, t = {}, tstates()
        row = {"key": k, "tstates": t, **hits}
        if do_diff:
            a, b = full_redraw_reference()
            row["screen_equals_full"] = (a == b)
            mism += (a != b)
        rows.append(row)
    D("stop")
    return rows, mism


def summarise(name, rows):
    n = len(rows)
    tot = sum(r["tstates"] for r in rows)
    keys = {k: sum(r.get(k, 0) for r in rows) for k in ("cls", "drawtext", "rowclr")}
    mx = max(r["tstates"] for r in rows)
    return {"scenario": name, "keys": n, "tstates_total": tot, "tstates_mean": tot // n, "tstates_max": mx, **keys}


def main():
    args = sys.argv[1:]
    do_diff = "--diff" in args
    out = None
    if "--json" in args:
        out = args[args.index("--json") + 1]
    names = [a for a in args if a in SCENARIOS] or list(SCENARIOS)
    res = {}
    for nme in names:
        rows, mism = run_scenario(nme, do_diff)
        s = summarise(nme, rows)
        s["diff_mismatches"] = mism if do_diff else None
        res[nme] = {"summary": s, "rows": rows}
        print(json.dumps(s), flush=True)
    if out:
        json.dump(res, open(out, "w"), indent=1)


if __name__ == "__main__":
    main()
