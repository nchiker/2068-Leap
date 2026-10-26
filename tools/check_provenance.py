#!/usr/bin/env python3
"""Provenance check of the production images against the stock ROMs.

Every run of MIN (12) or more bytes that a production image (build/test_basic.bin = HOME,
build/exrom.bin = EXROM) shares byte for byte with a stock ROM is listed with its place in the image
(the routine, from the .sym labels) and in the stock ROM. A run is accepted only if it is recorded in
ALLOWED below with a reason, or is mostly one byte repeated (an $FF fill, which the stock ROMs have too).
Only offsets and lengths are reported, never the stock bytes. The stock ROMs are read from
$V2_STOCK_ROMS (default ~/fuse-build/roms) and are never stored in this repository: 48.rom (Spectrum
48K), tc2068-0.rom and tc2068-1.rom (the TS2068's HOME ROM and EXROM).

Ported from 2068-Leap-C's tools/provenance.py (docs/V2_LEAPC_BACKPORT_PLAN.md item 0.5).

Exit status 0 when every run is accepted, 1 otherwise, 2 when the stock ROMs are not there (make check
then skips the check, saying so).

Usage: check_provenance.py [--build DIR] [--min N] [--roms DIR]
"""
import argparse
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIN = 12
STOCK = ("48.rom", "tc2068-0.rom", "tc2068-1.rom")
IMAGES = (("test_basic.bin", "test_basic.sym", 0x0000),
          ("exrom.bin", "exrom.sym", 0xC000))
# (image, routine containing the run's first byte, length) -> reason. These are known stock-derived
# code that the back-port plan replaces with clean-room code (item 3.1; item 1.3's glyph runs are gone); when it lands, the
# entry is reported as no longer found and is deleted here.
_TAPE = "stock SA-BYTES / LD-BYTES port (kernel/storage/storage.asm header): replaced in plan item 3.1"
ALLOWED = {
    ("exrom.bin", "STORAGE_SEND_BLOCK", 33): _TAPE,     # (NOTICE.md records these)
    ("exrom.bin", "STORAGE_SEND_BLOCK", 19): _TAPE,
    ("exrom.bin", "STORAGE_SEND_BLOCK", 22): _TAPE,
    ("exrom.bin", "STORAGE_SEND_BLOCK", 13): _TAPE,
    ("exrom.bin", "STORAGE_RECEIVE_BLOCK", 31): _TAPE,
    ("exrom.bin", "STORAGE_RECEIVE_BLOCK", 32): _TAPE,
}


def runs(img, rom, n):
    """[(image offset, rom offset, length)] of the maximal common runs of at least n bytes."""
    index = {}
    for j in range(len(rom) - n + 1):
        w = rom[j:j + n]
        if w.count(w[0]) != n:                              # (one byte repeated: fill, see trimmed())
            index.setdefault(w, []).append(j)
    out = []
    for i in range(len(img) - n + 1):
        for j in index.get(img[i:i + n], ()):
            if i > 0 and j > 0 and img[i - 1] == rom[j - 1]:
                continue                                    # (inside a run already found)
            k = n
            while i + k < len(img) and j + k < len(rom) and img[i + k] == rom[j + k]:
                k += 1
            out.append((i, j, k))
    return out


def trimmed(data):
    """The run without the repeated bytes at either end (the image's or the stock ROM's fill)."""
    a, z = 0, len(data)
    while a + 1 < z and data[a] == data[a + 1]:
        a += 1
    while z - 1 > a and data[z - 1] == data[z - 2]:
        z -= 1
    return data[a:z]


def labels(sym, lo, hi):
    """[(address, name)] of the routine labels (no local `.x` labels) inside [lo, hi), sorted."""
    out = []
    for line in open(sym):
        p = line.split()
        if len(p) >= 3 and p[1] == "EQU" and "." not in p[0]:
            a = int(p[2], 16)
            if lo <= a < hi:
                out.append((a, p[0].rstrip(":")))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default=os.path.join(ROOT, "build"))
    ap.add_argument("--min", type=int, default=MIN)
    ap.add_argument("--roms", default=os.environ.get("V2_STOCK_ROMS", os.path.expanduser("~/fuse-build/roms")))
    a = ap.parse_args()
    roms = {}
    for r in STOCK:
        p = os.path.join(a.roms, r)
        if not os.path.exists(p):
            print("provenance: SKIPPED: the stock ROMs are not in %s (set V2_STOCK_ROMS)" % a.roms)
            return 2
        roms[r] = open(p, "rb").read()
    bad = total = 0
    used = set()
    for img_name, sym, base in IMAGES:
        img = open(os.path.join(a.build, img_name), "rb").read()
        labs = labels(os.path.join(a.build, sym), base, base + len(img))
        for rom_name, rom in roms.items():
            for i, j, k in runs(img, rom, a.min):
                total += 1
                addr = base + i
                where = max((x for x in labs if x[0] <= addr), default=(base, "?"))
                fill = len(trimmed(img[i:i + k])) < a.min
                key = (img_name, where[1], k)
                why = ALLOWED.get(key) or ("one byte repeated (fill)" if fill else None)
                if key in ALLOWED:
                    used.add(key)
                print("provenance: %s $%04X (%s+%d) = %s $%04X, %d bytes: %s" % (
                    img_name, addr, where[1], addr - where[0], rom_name, j, k, why or "NOT ACCOUNTED FOR"))
                bad += why is None
    for key in ALLOWED:
        if key not in used:
            print("provenance: note: the recorded run %s %s (%d bytes) is no longer found" % key)
    print("provenance: %d common runs of %d bytes or more, %d not accounted for" % (total, a.min, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
