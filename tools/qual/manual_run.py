#!/usr/bin/env python3
"""Run the documentation-example suite against the build in this source tree.

  python3 tools/qual/manual_run.py [--out build/doc-examples] [--filter substr,...] [--workers 3]
                                   [--show] [--write-shots] [--list]

Every example in docs/v2/manual/*.md (see manual_examples.py) is run on the release image in a
headless ZEsarUX; the result of each is PASS or FAIL.  This is NOT part of the 1010-case release
baseline: `make test` / `make qual` neither run nor count these cases, and this runner reports its
own totals.  Exit status is 1 if any example fails.

  --show         print the actual screen text of each selected example (for authoring)
  --write-shots  (re)write images/<name>.png for `shot=` examples instead of comparing them
  --list         list the example ids and exit
"""
import argparse
import json
import multiprocessing as mp
import os
import struct
import sys
import time
import traceback
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import manual_examples as M          # noqa: E402

PALETTE = [(0, 0, 0), (0, 0, 0xCD), (0xCD, 0, 0), (0xCD, 0, 0xCD), (0, 0xCD, 0), (0, 0xCD, 0xCD),
           (0xCD, 0xCD, 0), (0xCD, 0xCD, 0xCD)]
BRIGHT = [(0, 0, 0), (0, 0, 0xFF), (0xFF, 0, 0), (0xFF, 0, 0xFF), (0, 0xFF, 0), (0, 0xFF, 0xFF),
          (0xFF, 0xFF, 0), (0xFF, 0xFF, 0xFF)]


def png_bytes(w, h, rgb_rows):
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"".join(b"\0" + r for r in rgb_rows)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def render_screen(scr, scale=2):
    """256x192 bitmap + attributes (6912 bytes read from $4000) -> PNG bytes (flash shown steady)."""
    rows = []
    for y in range(192):
        base = ((y & 0xC0) << 5) | ((y & 0x07) << 8) | ((y & 0x38) << 2)
        arow = 6144 + (y >> 3) * 32
        px = bytearray()
        for cx in range(32):
            b = scr[base + cx]
            at = scr[arow + cx]
            pal = BRIGHT if at & 0x40 else PALETTE
            ink, paper = pal[at & 7], pal[(at >> 3) & 7]
            for bit in range(7, -1, -1):
                px += bytes(ink if (b >> bit) & 1 else paper) * scale
        for _ in range(scale):
            rows.append(bytes(px))
    return png_bytes(256 * scale, 192 * scale, rows)


def screen_text(r, rows):
    if not rows:
        return r.text
    out = list(r.rows[:rows])
    while out and not out[-1]:
        out.pop()
    return "\n".join(out)


def check_result(r, want_out, err, rows=None):
    """-> (ok, detail).  want_out None = output not checked.  rows = compare only the first N rows."""
    text = screen_text(r, rows)
    if err:
        kind, code = err
        got = r.ce if kind == "ce" else r.ve
        if got != code or (kind == "ce" and r.ve) or (kind == "ve" and r.ce):
            return False, "want %s=%d, got ce=%s ve=%s msg=%s st=%s" % (kind, code, r.ce, r.ve, r.msg, r.status)
        # a compile error leaves the editor screen (the failing line and the status bar): output is not compared
        if kind == "ve" and want_out is not None and text != want_out:
            return False, "output %r, want %r" % (text, want_out)
        return True, "ok"
    if r.ce or r.ve or r.status != "OK":
        return False, "unexpected ce=%s ve=%s msg=%s st=%s out=%r" % (r.ce, r.ve, r.msg, r.status, text)
    if want_out is not None and text != want_out:
        return False, "output %r, want %r" % (text, want_out)
    return True, "ok"


def screen_rows_bold(m, scr):
    """Machine.screen_rows plus bold keywords (the editor draws a keyword's cells as b | b >> 1)."""
    bold = {}
    for cell, ch in m.glyphs.items():
        bold.setdefault(bytes(b | (b >> 1) for b in cell), ch)
    from qharness import cell_from
    rows = []
    for r in range(24):
        line = ""
        for col in range(32):
            cell = cell_from(scr, r, col)
            ch = m.glyphs.get(cell)
            if ch is None:
                ch = bold.get(cell)
            if ch is None:
                inv = bytes(255 - b for b in cell)
                ch = m.glyphs.get(inv)
                ch = ch.lower() if ch and ch.isalpha() else ("~" if ch is None else ch)
            line += ch
        rows.append(line.rstrip())
    return rows


def screen_matches(text, want):
    """Exact comparison, except that a line `...` in `want` stands for any number of blank rows."""
    if "..." not in want.split("\n"):
        return text == want
    pieces, cur = [], []
    for ln in want.split("\n"):
        if ln == "...":
            pieces.append(cur)
            cur = []
        else:
            cur.append(ln)
    pieces.append(cur)
    rows = text.split("\n")
    pos = 0
    for k, piece in enumerate(pieces):
        if k > 0:                               # skip blank rows only
            while pos < len(rows) and rows[pos] == "" and (not piece or rows[pos] != piece[0]):
                pos += 1
        if rows[pos:pos + len(piece)] != piece:
            return False
        pos += len(piece)
    return pos == len(rows)


def run_keys(m, c):
    iok = m.sym("IO_READ_KEY")
    m.restore()
    m.set_bps([iok])
    for k in c.keycodes:
        m.write(m.sym("KBD_LASTK"), k)
        m.write(m.sym("KBD_KEYHIT"), 1)
        m.step()
        m.run(c.maxi)
        if m.pc() != iok:
            raise RuntimeError("key %#x: machine did not return to a key wait (pc=%#06x)" % (k, m.pc()))
    scr = m.read(0x4000, 6912)
    rows = screen_rows_bold(m, scr)
    while rows and not rows[-1]:
        rows.pop()
    return "\n".join(rows), scr


def run_case(m, c, write_shots, show):
    from qharness import Machine  # noqa: F401  (import for type clarity)
    rec = {"id": c.cid, "where": c.where(), "kind": c.kind}
    shot_bytes = None
    if c.kind == "keys":
        text, scr = run_keys(m, c)
        ok = c.out is None or screen_matches(text, c.out)
        detail = "ok" if ok else "screen %r, want %r" % (text, c.out)
        rec["actual"] = text
        if c.shot:
            shot_bytes = render_screen(scr)
    elif c.kind == "tape":
        import manual_tapes
        ok, detail, transcript = manual_tapes.run_tape_case(m, c, m.port + 40)
        rec["actual"] = transcript
    elif c.kind == "run":
        r = m.run_program(c.lines, keys=c.keys, maxi=c.maxi, packages=c.pkgs)
        ok, detail = check_result(r, c.out, c.err, c.rows)
        rec["actual"] = screen_text(r, c.rows)
        if c.shot:
            shot_bytes = render_screen(m.read(0x4000, 6912))
    else:
        m.restore()
        for p in c.pkgs:
            m.install_package(p)
        m.put_store(c.lines)
        ok, detail = True, "ok"
        actual = []
        keys = list(c.keys)
        for cmd, want in c.steps:
            if cmd == "RUN":
                r = m.call_routine("V2_RUN_STORED", keys=keys, maxi=c.maxi)
            elif cmd == "EDIT":
                r = m.call_routine("V2_CLEAR_ARRAYS")
            else:
                m.write(m.sym("EDIT_LINE_BUF"), (cmd if cmd.startswith(":") else cmd).encode("latin-1") + b"\0")
                r = m.call_routine("V2_DISPATCH", keys=keys, maxi=c.maxi)
            actual.append((cmd, r.text, r.ce, r.ve))
            if isinstance(want, tuple):
                k, n = want
                good = (r.ce if k == "ce" else r.ve) == n
                what = "%s=%d" % (k, n)
            elif cmd == "EDIT":
                good, what = True, ""
            else:
                good = r.ce == 0 and r.ve == 0 and r.text == want
                what = repr(want)
            if not good and ok:
                ok = False
                detail = "step %r: got ce=%s ve=%s out=%r, want %s" % (cmd, r.ce, r.ve, r.text, what)
        rec["actual"] = actual
        if c.shot:
            shot_bytes = render_screen(m.read(0x4000, 6912))
    if shot_bytes is not None:
        path = os.path.join(M.IMAGE_DIR, c.shot + ".png")
        if write_shots:
            os.makedirs(M.IMAGE_DIR, exist_ok=True)
            with open(path, "wb") as f:
                f.write(shot_bytes)
        else:
            old = open(path, "rb").read() if os.path.exists(path) else None
            if old != shot_bytes:
                ok = False
                detail += " | screenshot %s differs from the committed image (rerun with --write-shots)" % c.shot
    rec.update(status="PASS" if ok else "FAIL", detail=detail)
    return rec


def worker(cfgdir, port, ids, outpath, q, write_shots, show):
    from qharness import Machine
    cases = {c.cid: c for c in M.CASES}
    m = None

    def boot():
        nonlocal m
        if m:
            try:
                m.stop()
            except Exception:
                pass
        m = Machine(cfgdir, port, label="doc%d" % port).start()
    boot()
    with open(outpath, "a") as fo:
        for cid in ids:
            c = cases[cid]
            t0 = time.time()
            try:
                rec = run_case(m, c, write_shots, show)
            except Exception as e:
                rec = {"id": cid, "where": c.where(), "status": "BLOCKED",
                       "detail": "harness: " + "".join(traceback.format_exception_only(type(e), e)).strip()}
                try:
                    boot()
                except Exception as e2:
                    rec["detail"] += " / reboot failed: %s" % e2
            rec["t"] = round(time.time() - t0, 2)
            fo.write(json.dumps(rec) + "\n")
            fo.flush()
            q.put(rec)
    m.stop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(M.ROOT, "build", "doc-examples"))
    ap.add_argument("--filter", default="")
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--port", type=int, default=10700)
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--write-shots", action="store_true")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    flt = [f for f in a.filter.split(",") if f]
    ids = [c.cid for c in M.CASES if not flt or any(f in c.cid for f in flt)]
    if a.list:
        for c in M.CASES:
            if c.cid in ids:
                print("%-34s %s" % (c.cid, c.where()))
        print("%d examples" % len(ids))
        return 0
    os.makedirs(a.out, exist_ok=True)
    outp = os.path.join(a.out, "results.jsonl")
    if os.path.exists(outp):
        os.remove(outp)
    n = max(1, min(a.workers, len(ids)))
    q = mp.Queue()
    procs = []
    for w in range(n):
        p = mp.Process(target=worker, args=(M.ROOT, a.port + w, ids[w::n], outp, q, a.write_shots, a.show))
        p.start()
        procs.append(p)
    done, counts, t0 = 0, {}, time.time()
    bad = []
    while done < len(ids):
        try:
            rec = q.get(timeout=1200)
        except Exception:
            if not any(p.is_alive() for p in procs):
                break
            continue
        done += 1
        counts[rec["status"]] = counts.get(rec["status"], 0) + 1
        if rec["status"] != "PASS":
            bad.append(rec)
            print("%-8s %-34s %s\n         %s" % (rec["status"], rec["id"], rec["where"], rec["detail"]), flush=True)
        if a.show:
            print("--- %s (%s)\n%s" % (rec["id"], rec["status"], rec.get("actual")), flush=True)
        elif done % 25 == 0:
            print("... %d/%d (%.0fs)" % (done, len(ids), time.time() - t0), flush=True)
    for p in procs:
        p.join()
    print("doc-examples: %s  (%d examples, %.0fs; separate from the 1010-case release baseline)"
          % (json.dumps(counts, sort_keys=True), len(ids), time.time() - t0))
    return 1 if bad or done < len(ids) else 0


if __name__ == "__main__":
    sys.exit(main())
