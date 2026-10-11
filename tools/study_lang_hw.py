#!/usr/bin/env python3
"""STUDY: OUT / IN / STICK through the real compiler and VM (core-ROM variant)."""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from study_util import *

def runv(lines, n):
    """run, return first n numeric variables (value16, signed) + (compile_err, vm_err)"""
    P.boot()
    P.put_store(lines)
    out, ce, ve = capture_run("V2_RUN_STORED")
    vals = [v for _, v in P.variables(n)]
    return [x - 65536 if x >= 32768 else x for x in vals], ce, ve

def check(name, ok, detail):
    print("%-5s %-44s %s" % ("PASS" if ok else "FAIL", name, detail), flush=True)
    return ok

def main():
    bad = 0
    # 1. AY register round trip through full 16-bit ports ($F5 select, $F6 data) -- OUT then IN
    v, ce, ve = runv(["OUT 245,8", "OUT 246,5", "OUT 245,8", "a = IN(246)", "OUT 245,8", "OUT 246,12", "OUT 245,8", "b = IN(246)"], 2)
    bad += not check("OUT/IN AY register round trip", (ce, ve) == (0, 0) and v == [5, 12], "a=%s b=%s ce=%d ve=%d" % (v[0], v[1], ce, ve))
    # 2. 16-bit port: keyboard half-rows differ by the HIGH byte only (IN(63486)=$F7FE row 1-5, IN(65278)=$FEFE row 0)
    P.boot()
    zr("send-keys-event 49 1")                       # key '1' down in the emulated matrix
    P.put_store(["a = IN(63486)", "b = IN(65278)", "c = IN(65022)", "d = IN(254)"])
    out, ce, ve = capture_run("V2_RUN_STORED")
    v = [x for _, x in P.variables(4)]
    zr("send-keys-event 49 0")
    bad += not check("IN uses the full 16-bit port (key '1' down)", (ce, ve) == (0, 0) and (v[0] & 31) == 30 and (v[1] & 31) == 31 and (v[2] & 31) == 31,
                     "IN($F7FE)=%02X IN($FEFE)=%02X IN($FDFE)=%02X IN(254)=%02X ce=%d ve=%d" % (v[0], v[1], v[2], v[3], ce, ve))
    # 3. STICK idle
    v, ce, ve = runv(["a = STICK(1)", "b = STICK(2)"], 2)
    bad += not check("STICK idle returns 0", (ce, ve) == (0, 0) and v == [0, 0], "STICK(1)=%s STICK(2)=%s" % (v[0], v[1]))
    # 4. OUT port 254 border (no crash) and statement errors
    v, ce, ve = runv(["OUT 254,2", "a = 7"], 1)
    bad += not check("OUT 254,2 runs", (ce, ve) == (0, 0) and v == [7], "a=%s" % v)
    v, ce, ve = runv(["OUT 254"], 1)
    bad += not check("OUT with one argument is a compile error", ce == 22, "ce=%d" % ce)
    v, ce, ve = runv(["a = IN()"], 1)
    bad += not check("IN() without argument is a compile error", ce != 0, "ce=%d" % ce)
    D("stop")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
