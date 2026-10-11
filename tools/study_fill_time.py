#!/usr/bin/env python3
"""STUDY D7: run adversarial FILL scenarios to completion (any length) and report exactness + emulated time."""
import os, sys, struct, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ["V2_FILL_NO_REBUILD"] = "1"
import v2_fill_check as F
import v2_known_defects as K
from v2_headless import *

def run(img, sx, sy, cap_chunks=40):
    F.start()
    D("mem-write", hex(F.BASE), open("build/v2_package_shapes.bin", "rb").read().hex())
    D("mem-write", "0x4000", F.to_bytes(img).hex())
    D("mem-write", hex(HSYM["GFX_FILL_X"]), bytes([sx]).hex()); D("mem-write", hex(HSYM["GFX_FILL_Y"]), bytes([sy]).hex())
    D("mem-write", hex(HSYM["GFX_FILL_ATTR"]), bytes([0x38]).hex())
    w = lambda v: struct.pack("<H", v)
    body = b"\xCD" + w(HSYM["BANK_PAGE_EXROM_OUT"]) + b"\xCD" + w(F.PKG["SHAPES_GFX_FILL"])
    done = 0xFE00 + len(body)
    D("mem-write", "0xFE00", (body + b"\x18\xFE").hex())
    D("set-register", "SP", "0xFDF0"); D("set-register", "PC", "0xFE00")
    from v2_prod import zr
    ts = 0
    for i in range(cap_chunks):
        zr("reset-tstates-partial")
        D("run", "--until", hex(done), "--max-instructions", "100000000", t=1800)
        D("pause")
        t = zr("get-tstates-partial")
        ts += int(t) if t.isdigit() else 999_999_999
        if int(D("regs")["registers"]["PC"]) == done:
            break
    else:
        return None, None, None
    got = F.from_bytes(read(0x4000, 6144))
    D("stop")
    return got, ts, i + 1

def main():
    names = sys.argv[1:]
    sc = K._fill_scenarios()
    for n in names:
        img, sx, sy = sc[n]
        t0 = time.time()
        got, ts, chunks = run(img, sx, sy)
        if got is None:
            print(n, "DID NOT FINISH within cap"); continue
        want = F.flood(img, sx, sy)
        diff = sum(got[y][x] != want[y][x] for y in range(192) for x in range(256))
        print("%s: differing pixels=%d  emulated time=%.1f s (%d T-states, 3.528 MHz)  wall %.0fs" % (n, diff, ts / 3.528e6, ts, time.time() - t0), flush=True)

if __name__ == "__main__":
    main()
