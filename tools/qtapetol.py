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

Usage: TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/qtapetol.py [--out FILE] [substr]
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
        for name, opts in CASES:
            if a.filter not in name:
                continue
            t0 = time.time()
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
