#!/usr/bin/env python3
"""Editor screen and cost after every key of typed scenarios (plan item SH_VIEW, audit ED4).

The program is written into the line store, the editor entered at a chosen line through the real
V2_COMMAND_LOOP.loop, then each key is delivered through the ISR latch (KBD_LASTK/KBD_KEYHIT) and the
machine runs to the next IO_READ_KEY: the key's cost in T-states (ZRCP get-tstates-partial, from the
key's delivery to the next key wait) and the screen (bitmap and attributes) are taken there.

Checks on the build under test (BUILD, default this tree):
  view     the cursor cell (attribute $87) is the only non-text attribute on rows 0-22; the active line
           is whole on rows 0-22, starts at BASIC_ACTIVE_ROW and shows EDIT_LINE_BUF wrapped as
           V2_WRAP_EDIT wraps it (an empty row after a full last row: the cursor's at its end); VIEW_TOP_INDEX and the active row are those of the view rule
           (up to 20 lines above, fewer when they do not fit; modelled here)
  oracle   (--oracle) after every key the screen equals a full redraw's (V2_REDRAW_SCOPE 0, called
           from a snapshot): every selective path draws what the full redraw draws
  diff     (--ref DIR) the screen after every key equals the other build's, for the scenarios marked
           `same` (no line where ED4 matters); the others are reported as a count only
  measure  (--measure N, alone) V2_MEASURE on N random records against EDITOR_WRAP_CALC and the model
  edit row (--edit-row-ref with --ref DIR) DIR has no edit row (ED7): every screen the same except where
           the buffer's last row is full, compared until the two builds' cursor states part

Usage: python3 tools/qual/qeditview.py [--build DIR] [--ref DIR] [--port N] [--oracle] [--json OUT]
                                      [--keys] [--measure N] [scenario-substring ...]
Exit status 1 on any failed check.
"""
import argparse
import json
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine, HARNESS_RET_SLOT, KEY_ENTER, KEY_LEFT, KEY_DOWN, KEY_UP, KEY_RIGHT  # noqa: E402
from qharness import KEY_DELETE, KEY_INSERT_LINE, KEY_DELETE_LINE                                 # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
ATTR_TEXT, ATTR_CURSOR = 0x38, 0x87
U, D, L, R, DEL, ENT, INS, DLN = KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_DELETE, KEY_ENTER, \
    KEY_INSERT_LINE, KEY_DELETE_LINE


# ---------------------------------------------------------------- the model
def wrap(text):
    """EDITOR_WRAP_CALC: rows as (start, length); break at the last space of a 32-character window."""
    rows, start, remain = [], 0, len(text)
    while True:
        if remain <= 32:
            rows.append((start, remain))
            break
        w = text[start:start + 32]
        sp = w.rfind(" ")
        ln, used = (32, 32) if sp < 0 else (sp, sp + 1)
        rows.append((start, ln))
        start += used
        remain -= used
        if len(rows) >= 8 or remain == 0:
            break
    return rows


def wrap_edit(text):
    """The edit buffer's rows (V2_WRAP_EDIT): one more, empty, row after a last row of 32 characters,
    where the cursor after the last character goes (ED7)."""
    rows = wrap(text)
    if rows[-1][1] == 32:
        rows.append((rows[-1][0] + 32, 0))
    return rows


def view_top(heights, idx, h_active):
    """The view rule: up to 20 lines above the cursor's line, fewer while they do not fit on 0-22."""
    top = max(0, idx - 20)
    while sum(heights[top:idx]) + h_active > 23:
        top += 1
    return top


# ---------------------------------------------------------------- scenarios
def T(s):
    return [ord(c) for c in s]


def short(n):
    return ["LET v%d = %d" % (i, i * 7) for i in range(n)]


def two_row(i):
    return "PRINT \"line %d is long enough to wrap\"; i + %d" % (i, i)       # 45-48 characters: 2 rows


def four_row(i):
    return ("REM " + " ".join("word%d" % k for k in range(i, i + 20)))[:120]  # ~120 characters: 4 rows


WORDS = "PRINT a + b * c - d / e ; f , g : LET h = i + j * k - l "  # typed text with spaces


def typed(n):
    return T((WORDS * 4)[:n])


SCENARIOS = [
    # name, same (ED4-free: the old build must draw the same), lines, start index, keys
    ("short-append", True, short(10), 10,
     typed(40) + [ENT] + [U] * 3 + [D] * 3 + typed(5) + [DEL] * 8 + [U, ENT]),
    ("short-middle", True, short(12), 5,
     typed(38) + [DEL] * 10 + [R] * 3 + [L] * 5 + [D, D, U] + typed(30) + [ENT, D, D]),
    ("scrolled-typing", True, short(30), 25,
     typed(75) + [DEL] * 40 + [U, U, D, D, D] + typed(20) + [ENT]),
    ("nav-through-25", True, short(25), 0, [D] * 25 + [U] * 25),
    ("wrapped-fit", True, [two_row(i) for i in range(8)] + short(4), 6,
     [D] * 6 + [U] * 10 + typed(30) + [DEL] * 30 + [D, D, D]),
    ("delete-insert", True, short(15), 7, [INS] + typed(10) + [ENT, DLN, U, DLN, D, DEL]),
    ("near-bottom-fit", True, short(22), 21, typed(60) + [DEL] * 60 + [U, D, D]),
    ("long-program", True, short(200), 150,
     [U] * 6 + [D] * 6 + typed(40) + [DEL] * 10 + [ENT] + [U] * 3),
    # ED7: a last row of exactly 32 characters (the cursor after it used to be at column 32, unseen)
    ("edit-row", False, short(6), 6,
     T("x" * 32) + [L, R] + T("y") + [DEL, DEL, R] + T("zz") + T("w" * 31) + [U, U, D, D, L, R, ENT, U, D]),
    ("edit-row-words", False, short(4), 4,
     typed(32) + T("a" * 32) + [L] * 3 + [R] * 5 + [U, D, D] + [ENT]),              # rows 31 + 32
    ("edit-row-low", False, [two_row(0)] + short(19), 20,                          # line on row 21:
     T("q" * 64) + [L, R, DEL, R] + T("q") + [U, D, U]),                           # the edit row scrolls
    # ED4: the cursor's line used to fall below row 22
    ("ed4a-long-line-low", False, short(25), 20, typed(110) + [DEL] * 110 + [U, D]),
    ("ed4a-scrolled", False, short(30), 25, typed(90) + [DEL] * 40 + [U, U, D, D, D] + [ENT]),
    ("ed4b-wrapped-above", False, [two_row(i) for i in range(24)], 20,
     [U] * 5 + [D] * 8 + typed(70) + [DEL] * 40 + [U] * 21 + [D] * 4),
    ("grow-past-22", False, [two_row(0), two_row(1)] + short(18), 20,
     typed(100) + [DEL] * 100 + [U, D, D]),
    ("nav-across-tall", False, short(15) + [four_row(1)] + short(3) + [four_row(2)] + short(3), 12,
     [D] * 16 + [U] * 16 + [D] * 10),
    ("tall-mix-long", False, [(four_row(i) if i % 7 == 3 else two_row(i) if i % 3 == 0 else "LET q%d = %d" % (i, i))
                             for i in range(120)], 60,
     [U] * 8 + [D] * 12 + typed(50) + [DEL] * 50 + [ENT] + [U] * 3),
    ("shrink-trimmed", False, [four_row(1), four_row(2)] + [two_row(i) for i in range(8)] + short(4), 12,
     typed(70) + [DEL] * 70 + [U] * 4 + [D] * 4),
]


# ---------------------------------------------------------------- driving the editor
class Editor:
    def __init__(self, cfgdir, port):
        self.m = Machine(cfgdir, port).start()
        self.S = self.m.S
        self.oracle_snap = os.path.join(self.m.snapdir, "oracle.zsf")

    def stop(self):
        self.m.stop()

    def enter(self, lines, idx):
        m = self.m
        m.restore()
        m.put_store(lines)
        pos = self.S["PROG_AREA_START"] + sum(len(l) + 3 for l in lines[:idx]) if idx < len(lines) else 0xFFFF
        m.poke16(self.S["CUR_EDIT_INDEX"], idx)
        m.poke16(self.S["CUR_EDIT_POS"], pos)
        m.write(HARNESS_RET_SLOT, struct.pack("<H", self.S["V2_COMMAND_LOOP.loop"]))
        m.setreg("SP", HARNESS_RET_SLOT)
        m.setreg("PC", self.S["V2_COMMAND_LOOP.loop"])
        m.set_bps([self.S["IO_READ_KEY"]])
        m.cmd("reset-tstates-partial")
        m.run(200_000_000)
        assert m.pc() == self.S["IO_READ_KEY"], "editor entry did not reach a key wait"
        return self.state(int(m.cmd("get-tstates-partial").strip()))

    def key(self, k):
        m = self.m
        m.write(self.S["KBD_LASTK"], k)
        m.write(self.S["KBD_KEYHIT"], 1)
        m.cmd("reset-tstates-partial")
        m.step()
        m.run(200_000_000)
        assert m.pc() == self.S["IO_READ_KEY"], "key %d did not come back to a key wait" % k
        return self.state(int(m.cmd("get-tstates-partial").strip()))

    def state(self, t):
        m, S = self.m, self.S
        scr = m.read(0x4000, 6912)
        buf = m.read(S["EDIT_LINE_BUF"], 128).split(b"\0")[0].decode("latin-1")
        return {"t": t, "scr": scr, "buf": buf, "off": m.read(S["EDIT_BUF_OFFSET"], 1)[0],
                "idx": m.w16(S["CUR_EDIT_INDEX"]), "top": m.w16(S["VIEW_TOP_INDEX"]),
                "row": m.read(S["BASIC_ACTIVE_ROW"], 1)[0], "count": self.count_lines()}

    def store(self):
        """The line store's texts (records walked from PROG_AREA_START to PROG_END)."""
        m, S = self.m, self.S
        a, end = S["PROG_AREA_START"], m.w16(S["PROG_END"])
        blob = m.read(a, end - a) if end > a else b""
        out, i = [], 0
        while i < len(blob):
            n = blob[i] | blob[i + 1] << 8
            out.append(blob[i + 2:i + 1 + n].decode("latin-1"))
            i += 2 + n
        return out

    def count_lines(self):
        return len(self.store())

    def full_redraw_screen(self):
        """The screen a full redraw draws from the current state; the machine is put back after."""
        m, S = self.m, self.S
        m.cmd("snapshot-save " + self.oracle_snap)
        r = m.regs()
        sp = r["SP"] - 2
        m.write(sp, struct.pack("<H", 0xFE00))
        m.write(0xFE00, b"\x18\xFE")
        m.write(S["V2_REDRAW_SCOPE"], 0)
        m.setreg("SP", sp)
        m.setreg("PC", S["V2_REDRAW"])
        m.set_bps([0xFE00])
        m.run(200_000_000)
        assert m.pc() == 0xFE00, "full redraw did not return"
        scr = m.read(0x4000, 6912)
        m.cmd("snapshot-load " + self.oracle_snap)
        m._enable_bp()
        m.set_bps([S["IO_READ_KEY"]])
        return scr


# ---------------------------------------------------------------- checks
def row_text(ed, scr, row):
    return ed.m.screen_rows(scr, 24)[row]


def check_view(ed, st):
    """Return a list of problems with the view after a key (empty = fine)."""
    errs = []
    scr, attrs = st["scr"], st["scr"][6144:]
    lines = ed.store()
    idx, buf = st["idx"], st["buf"]
    rows = wrap_edit(buf)
    h = len(rows)
    heights = [len(wrap(l[:127])) for l in lines]
    top = view_top(heights, idx, h)
    want_row = sum(heights[top:idx])
    if st["top"] != top:
        errs.append("VIEW_TOP_INDEX %d, the rule gives %d" % (st["top"], top))
    if st["row"] != want_row:
        errs.append("active row %d, the rule gives %d" % (st["row"], want_row))
    if st["row"] + h > 23:
        errs.append("active line rows %d-%d: not whole on 0-22" % (st["row"], st["row"] + h - 1))
    odd = [(i // 32, i % 32, a) for i, a in enumerate(attrs[:23 * 32]) if a != ATTR_TEXT]
    # the cursor: the offset's row and column (EDITOR_WRAP_OFFSET_TO_ROWCOL)
    off, crow, ccol = st["off"], 0, 0
    for k, (s, ln) in enumerate(rows):
        last = k == len(rows) - 1
        if last or rows[k + 1][0] > off:
            crow, ccol = k, min(off - s, ln)
            break
    want = [(st["row"] + crow, ccol, ATTR_CURSOR)]
    if len(rows) > len(wrap(buf)):
        st["editrow"] = True            # the line's last row is full: the edit row is part of it (ED7)
    if odd != want:
        errs.append("attributes on rows 0-22 %s, expected the cursor only at %s" % (odd[:4], want))
    txt = ed.m.screen_rows(scr, 24)
    for k, (s, ln) in enumerate(rows):
        r = st["row"] + k
        if r < 23 and txt[r] != buf[s:s + ln].rstrip():
            errs.append("row %d shows %r, the buffer's row %d is %r" % (r, txt[r], k, buf[s:s + ln]))
            break
    return errs


def classify(prev, st, k):
    if k in (U, D):
        if st["idx"] == prev["idx"]:
            return "updown-inline"
        return "updown-same-view" if st["top"] == prev["top"] else "updown-scroll"
    if k in (L, R):
        return "leftright"
    if k == ENT:
        return "enter"
    if k in (INS, DLN):
        return "line-key"
    hp, hn = len(wrap_edit(prev["buf"])), len(wrap_edit(st["buf"]))
    if hp == hn:
        return "type-same-height"
    return "height-change" + ("-scroll" if st["top"] != prev["top"] else "")


def run_build(cfgdir, port, names, oracle, want_checks):
    ed = Editor(cfgdir, port)
    out = {}
    try:
        for name, same, lines, idx, keys in SCENARIOS:
            if names and not any(n in name for n in names):
                continue
            t0 = time.time()
            st = ed.enter(lines, idx)
            states, problems = [st], []
            if want_checks:
                for e in check_view(ed, st):
                    problems.append("entry: " + e)
            for n, k in enumerate(keys):
                prev = st
                st = ed.key(k)
                st["class"] = classify(prev, st, k)
                states.append(st)
                if want_checks:
                    for e in check_view(ed, st):
                        problems.append("key %d (%d): %s" % (n + 1, k, e))
                    if oracle and ed.full_redraw_screen() != st["scr"]:
                        problems.append("key %d (%d): the screen differs from a full redraw's" % (n + 1, k))
            out[name] = {"same": same, "states": states, "problems": problems, "secs": time.time() - t0}
            c32 = sum(1 for s in states if s.get("editrow"))
            print("  %-20s %4d keys %5.1f s %s%s" % (name, len(keys), time.time() - t0,
                                                     "PASS" if not problems else "FAIL %d" % len(problems),
                                                     "  (%d with the edit row)" % c32 if c32 else ""),
                  flush=True)
    finally:
        ed.stop()
    return out


def measure_probe(cfgdir, port, n, seed=2068):
    """V2_MEASURE on a stored record against EDITOR_WRAP_CALC on its NUL-terminated copy and the model:
    random texts of 0-127 characters, spaces from none to most, runs and leading/trailing spaces."""
    import random
    rnd = random.Random(seed)
    m = Machine(cfgdir, port).start()
    S = m.S
    rec_at, txt_at, stop = 0x8300, 0x8400, 0xFE00
    bad, hist = [], {}
    try:
        m.write(stop, b"\x18\xFE")
        # the most rows a 127-character line can take: 7 (a window consumes one character at best
        # every other row), so EDITOR_WRAP_CALC's 8-row cap is never reached
        fixed = [((" " + "X" * 31 + " ") * 4)[:127], (" " + "X" * 16) * 8, "X" * 127, " " * 127, ""]
        for i in range(n):
            ln = rnd.choice([rnd.randint(0, 127), rnd.randint(30, 40), rnd.randint(60, 70), rnd.randint(90, 127)])
            p_sp = rnd.choice([0.0, 0.02, 0.1, 0.2, 0.5, 0.9])
            t = "".join(" " if rnd.random() < p_sp else rnd.choice("ABCxyz019=+\"") for _ in range(ln))
            if i < len(fixed):
                t = fixed[i][:127]
                ln = len(t)
            rec = struct.pack("<H", ln + 1) + t.encode() + b"\r"
            m.write(rec_at, rec)
            m.write(txt_at, t.encode() + b"\0")
            out = []
            for routine, hl in (("V2_MEASURE", rec_at), ("EDITOR_WRAP_CALC", txt_at)):
                m.write(HARNESS_RET_SLOT, struct.pack("<H", stop))
                m.setreg("SP", HARNESS_RET_SLOT)
                m.setreg("HL", hl)
                m.setreg("PC", S[routine])
                m.set_bps([stop])
                m.run(2_000_000)
                assert m.pc() == stop, "%s did not return" % routine
                r = m.regs()
                out.append((r["AF"] >> 8, r["HL"]) if routine == "V2_MEASURE" else m.read(S["EDIT_WRAP_COUNT"], 1)[0])
            (rows, nxt), calc = out
            hist[rows] = hist.get(rows, 0) + 1
            if rows != calc or rows != len(wrap(t)) or nxt != rec_at + ln + 3:
                bad.append((t, rows, calc, len(wrap(t)), nxt))
    finally:
        m.stop()
    print("measure: %d texts (rows: %s), %d differ%s" % (n, dict(sorted(hist.items())), len(bad), "".join("\n  %r: V2_MEASURE %d, WRAP_CALC %d, model %d, "
                                                                  "next %04X" % b for b in bad[:8])))
    return len(bad)


def summary(res, ref=None):
    """Mean / max T per key class and scenario."""
    lines = []
    for name, r in res.items():
        cls = {}
        for i, st in enumerate(r["states"][1:], 1):
            c = st["class"]
            tr = ref[name]["states"][i]["t"] if ref and name in ref else None
            cls.setdefault(c, []).append((st["t"], tr))
        for c, v in sorted(cls.items()):
            tn = [a for a, _ in v]
            s = "%-20s %-22s n=%4d  mean %9.0f  max %9.0f" % (name, c, len(v), sum(tn) / len(tn), max(tn))
            if ref and name in ref:
                to = [b for _, b in v]
                s += "   | old mean %9.0f  max %9.0f" % (sum(to) / len(to), max(to))
            lines.append(s)
    return lines


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=ROOT)
    ap.add_argument("--ref")
    ap.add_argument("--port", type=int, default=10251)
    ap.add_argument("--oracle", action="store_true")
    ap.add_argument("--json")
    ap.add_argument("--keys", action="store_true", help="print T per key")
    ap.add_argument("--measure", type=int, metavar="N", help="only the V2_MEASURE probe, N random texts")
    ap.add_argument("--edit-row-ref", action="store_true",
                    help="--ref is a build without the edit row (ED7): every scenario must draw the same "
                         "screens except where the buffer's last row is full (compared until the two "
                         "builds' cursor states part)")
    ap.add_argument("names", nargs="*")
    a = ap.parse_args()
    if a.measure:
        sys.exit(1 if measure_probe(a.build, a.port, a.measure) else 0)
    print("build %s" % a.build)
    res = run_build(a.build, a.port, a.names, a.oracle, True)
    ref = None
    fails = sum(len(r["problems"]) for r in res.values())
    if a.ref and a.edit_row_ref:
        print("ref %s (no edit row)" % a.ref)
        ref = run_build(a.ref, a.port + 1, a.names, False, False)
        for name, r in res.items():
            same = skipped = status = 0
            bad, parted = [], None
            for i, (x, y) in enumerate(zip(r["states"], ref[name]["states"])):
                if (x["idx"], x["buf"], x["off"]) != (y["idx"], y["buf"], y["off"]):
                    parted = i
                    break
                if len(wrap_edit(x["buf"])) > len(wrap(x["buf"])):
                    skipped += 1
                elif x["scr"] != y["scr"]:
                    # the old build's LEFT/RIGHT from a cursor at column 32 of row 22 restored "its" cell:
                    # row 23, column 0 (no bound in .clear_cursor_attr), whitening the status bar's first
                    # cell until the next full redraw; the only difference that symptom of ED7 can leave
                    sc = 6144 + 23 * 32
                    if [k for k in range(6912) if x["scr"][k] != y["scr"][k]] == [sc] and y["scr"][sc] == ATTR_TEXT:
                        status += 1
                    else:
                        bad.append(i)
                else:
                    same += 1
            fails += len(bad)
            print("  diff %-20s %4d identical, %3d with the edit row skipped%s%s%s" % (
                name, same, skipped, ", %d with the old status-cell symptom" % status if status else "",
                "" if parted is None else ", parted at state %d" % parted,
                "" if not bad else "  FAIL at states %s" % bad[:6]))
    elif a.ref:
        print("ref %s" % a.ref)
        ref = run_build(a.ref, a.port + 1, a.names, False, False)
        for name, r in res.items():
            diff = [i for i, (x, y) in enumerate(zip(r["states"], ref[name]["states"])) if x["scr"] != y["scr"]]
            tag = "same" if r["same"] else "ED4"
            ok = not diff or not r["same"]
            if not ok:
                fails += 1
            print("  diff %-20s %-4s %4d of %4d screens differ%s" % (
                name, tag, len(diff), len(r["states"]), "" if ok else "  FAIL (first at key %d)" % diff[0]))
    for name, r in res.items():
        for p in r["problems"][:12]:
            print("  %s: %s" % (name, p))
    print("\n".join(summary(res, ref)))
    if a.keys:
        for name, r in res.items():
            print(name, [(st.get("class"), st["t"]) for st in r["states"]])
    if a.json:
        def strip(d):
            return {n: {"same": r["same"], "problems": r["problems"],
                        "keys": [{k: v for k, v in st.items() if k != "scr"} for st in r["states"]]}
                    for n, r in d.items()}
        json.dump({"build": strip(res), "ref": strip(ref) if ref else None}, open(a.json, "w"), indent=1)
    print("RESULT %s (%d problems)" % ("PASS" if not fails else "FAIL", fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
