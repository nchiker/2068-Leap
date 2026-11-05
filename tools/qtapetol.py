#!/usr/bin/env python3
"""Tape tolerance of the production receiver (docs/V2_LEAPC_BACKPORT_PLAN.md item 3.1).

After 2068-Leap-C's tools/tapetol.py (which runs on Fuse), on ZEsarUX's real-tape input instead: one
program tape is LOADed through the real STORAGE_LOAD / STORAGE_RECEIVE_BLOCK under each distortion
below, and the case passes when the program arrives intact (LOADED). The stream is point-sampled at
15,600 Hz (226 T a sample), so every case also carries up to one sample of edge jitter.

  speed F     every pulse (pilot, syncs, bits) times F: a tape running slow (F > 1) or fast
  bits F      the bit half-pulses only times F
  jitter P    every half-pulse moved by a random -P%..+P% (seeded)
  pilot N     a pilot of N half-pulses instead of the standard count
  gap MS      a dropout of MS milliseconds in the middle of the data block's pilot

v2.2 (item C): the "all-seg2 ..." cases load a SAVE ... ALL tape whose block 2 (segment 2, an 808-byte
Array Store entry) the real LOAD receives straight into $5B00+, the contended RAM segment 2 occupies since
item C, under a subset of the same distortions. The tape is the ROM's own SAVE (captured once at the sender's
call site, tools/v2_prod.capture_save) re-synthesised with the distortion, the 4.5 s gap between block 1 and
block 2 kept as the SAVE makes it (not scaled by `speed`). A case passes when the program, segment 2's bytes
and PAS_END come back (LOADED).

v2.2 (item D): the "code ..." cases load a CODE tape (header type 3, PROGLEN = the start, 512 bytes for
$7800) through the real LOAD "TCODE" CODE path (V2_LOAD with request type 3, no start given: the address
comes from the header) under a subset of the same distortions; a case passes when the range arrives
intact (LOADED). Filter "code" runs only these.

Usage: TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/qtapetol.py [--out FILE] [substr]
       (substr "all-seg2" runs only the segment-2 cases, "code" only the CODE cases, "speed" every speed case)
Exit status: 0 always (a report, not a gate); --out writes {case: passed} as JSON.
"""
import argparse
import json
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402
import tape_synth as TS          # noqa: E402
import make_extension_tzx as M   # noqa: E402

PROG = ["x = 1", "y = 2", "z = x + y", "w = z * 2", "q = w + 1"]
SRC = TS.source_records(PROG)
CASES = ([("speed %.2f" % f, dict(speed=f)) for f in (0.75, 0.8, 0.85, 0.9, 0.95, 1.05, 1.1, 1.15, 1.2, 1.25)]
         + [("bits %.2f" % f, dict(bits=f)) for f in (0.8, 0.9, 1.1, 1.2)]
         + [("jitter %d%%" % p, dict(jitter=p)) for p in (10, 20, 30)]
         + [("pilot %d" % n, dict(pilot=n)) for n in (400, 1000, 2000)]
         + [("gap %dms" % g, dict(gap=g)) for g in (10, 50, 200)])


class DistortedTape(TS.Tape):
    def __init__(self, speed=1.0, bits=1.0, jitter=0, pilot=None, gap=0, seed=2068):
        super().__init__()
        self.speed, self.bits, self.jitter, self.pilot, self.gap = speed, bits, jitter, pilot, gap
        self.rng = random.Random(seed)

    def _w(self, t, bit=False):
        t *= self.speed * (self.bits if bit else 1.0)
        if self.jitter:
            t *= 1 + self.rng.uniform(-self.jitter, self.jitter) / 100.0
        return int(t)

    def block(self, data, gap_here=False):
        self.flat(M.SILENCE_SAMPLES * TS.SAMPLE_T)
        n = M.PILOT_PULSES if self.pilot is None else self.pilot
        for i in range(n):
            if gap_here and self.gap and i == n // 2:
                self.flat(int(self.gap * TS.CPU_HZ / 1000))
            self._run(self._w(M.PILOT_SAMPLES * TS.SAMPLE_T))
        for w in M.SYNC_SAMPLES:
            self._run(self._w(w * TS.SAMPLE_T))
        for value in data:
            for shift in range(7, -1, -1):
                w = (M.ONE_SAMPLES if value & (1 << shift) else M.ZERO_SAMPLES) * TS.SAMPLE_T
                self._run(self._w(w, True))
                self._run(self._w(w, True))
        self._run(self._w(M.ZERO_SAMPLES * TS.SAMPLE_T))


SEG_N = 400                      # the segment-2 array: an 808-byte store entry at ARR2_BASE
SEG_DESC = bytes([1]) + SEG_N.to_bytes(2, "little") + b"".join(((i * 37 + 11) & 0xFFFF).to_bytes(2, "little")
                                                                for i in range(SEG_N))
SEG_ENTRY = (4 + 1 + len(SEG_DESC)).to_bytes(2, "little") + bytes([2, 1]) + b"a" + SEG_DESC
ALL_CASES = [("all-seg2 nominal", {})] + [("all-seg2 " + n, o) for n, o in CASES if n in (
    "speed 0.80", "speed 0.90", "speed 1.10", "speed 1.20", "bits 0.90", "bits 1.10", "jitter 20%", "pilot 1000",
    "gap 50ms")]
_all = {}


def all_blocks():
    """The ROM's own SAVE "ALLT" ALL of PROG with SEG_ENTRY in the Array Store: [(flag, payload)] x 3."""
    if "blocks" not in _all:
        P.boot()
        P.put_store(PROG)
        base = P.sym("ARR2_BASE")
        P.poke(base, SEG_ENTRY)
        P.poke16(P.sym("PAS_END"), base + len(SEG_ENTRY))
        blocks, msg = P.capture_save('SAVE "ALLT" ALL')
        assert msg == "SAVED" and len(blocks) == 3 and blocks[2][1] == SEG_ENTRY, \
            "SAVE ALL capture: msg=%s blocks=%d" % (msg, len(blocks))
        _all["blocks"] = blocks
        _all["src"] = blocks[1][1][:blocks[0][1][15] | blocks[0][1][16] << 8]   # the program part (PROGLEN)
    return _all["blocks"]


def all_tape_for(opts):
    (_, hdr), (_, b1), (_, b2) = all_blocks()
    t = DistortedTape(**opts)
    t.block(TS.framed(0x00, hdr))
    t.block(TS.framed(0xFF, b1))
    t.flat(max(0, int(4.5 * TS.CPU_HZ) - M.SILENCE_SAMPLES * TS.SAMPLE_T))   # the SAVE's gap (block() adds the rest)
    t.block(TS.framed(0xFF, b2), gap_here=True)
    return t


def all_check():
    base = P.sym("ARR2_BASE")
    return P.read(base, len(SEG_ENTRY)) == SEG_ENTRY and P.w16(P.sym("PAS_END")) == base + len(SEG_ENTRY)


CODE_START, CODE_DATA = 30720, bytes((i * 29 + 7) & 0xFF for i in range(512))
CODE_CASES = [("code nominal", {})] + [("code " + n, o) for n, o in CASES if n in (
    "speed 0.80", "speed 0.90", "speed 1.10", "speed 1.20", "bits 0.90", "bits 1.10", "jitter 20%", "pilot 1000",
    "gap 50ms")]


def code_tape_for(opts):
    t = DistortedTape(**opts)
    t.block(TS.framed(0x00, TS.header_payload(3, "TCODE", len(CODE_DATA), autostart=P_ABI_WORD, proglen=CODE_START)))
    t.block(TS.framed(0xFF, CODE_DATA), gap_here=True)
    return t


def code_prepare():
    """As V2_PARSE_NAME leaves LOAD "TCODE" CODE: no start, no length (tape_op sets the name and type 3)."""
    P.poke16(P.sym("V2_CODE_START"), 0)
    P.poke16(P.sym("V2_CODE_LEN"), 0)
    P.poke(CODE_START, bytes(len(CODE_DATA)))


def tape_for(opts):
    t = DistortedTape(**opts)
    t.block(TS.framed(0x00, TS.header_payload(0, "TEST", len(SRC), autostart=P_ABI_WORD)))
    t.block(TS.framed(0xFF, SRC), gap_here=True)
    return t


def main():
    global P_ABI_WORD
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("filter", nargs="?", default="")
    a = ap.parse_args()
    import v2_abi
    P_ABI_WORD = v2_abi.load().fmt_word
    res = {}
    try:
        for name, opts in CASES + ALL_CASES + CODE_CASES:
            if a.filter not in name:
                continue
            t0 = time.time()
            if name.startswith("all-seg2"):
                tape = all_tape_for(opts)
                r = P.tape_op(tape, existing=["k = 9"], name="ALLT")
                ok = r["msg"] == "LOADED" and r["after"] == _all["src"] and all_check()
            elif name.startswith("code"):
                r = P.tape_op(code_tape_for(opts), existing=["k = 9"], name="TCODE", request_type=3, prepare=code_prepare)
                ok = r["msg"] == "LOADED" and P.read(CODE_START, len(CODE_DATA)) == CODE_DATA and r["after"] == r["before"]
            else:
                r = P.tape_op(tape_for(opts), existing=["k = 9"])
                ok = r["msg"] == "LOADED" and r["after"] == SRC
            res[name] = ok
            print("%-5s %-12s msg=%s  (%ds)" % ("PASS" if ok else "FAIL", name, r["msg"], time.time() - t0), flush=True)
    finally:
        P.shutdown()
    print("qtapetol: %d of %d accepted" % (sum(res.values()), len(res)))
    if a.out:
        json.dump(res, open(a.out, "w"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
