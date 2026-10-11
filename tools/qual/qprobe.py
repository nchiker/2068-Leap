#!/usr/bin/env python3
"""Run ad-hoc BASIC programs on one configuration (investigation helper).
  python3 tools/qual/qprobe.py <cfg> [--port N] [--keys "text"] [--maxi N] -- "line 1" "line 2" ... [/// "prog2 line1" ...]
Programs are separated by '///'.  Prints ce/ve/msg/status and the screen text."""
import os, sys, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine
ap = argparse.ArgumentParser()
ap.add_argument("cfg"); ap.add_argument("--port", type=int, default=10470)
ap.add_argument("--keys", default=None); ap.add_argument("--maxi", type=int, default=20_000_000)
ap.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "qual-builds"))
ap.add_argument("lines", nargs="*")
a, extra = ap.parse_known_args()
a.lines = a.lines + [x for x in extra if x != "--"]
progs, cur = [], []
for l in a.lines:
    if l == "///":
        progs.append(cur); cur = []
    else:
        cur.append(l)
progs.append(cur)
keys = ([ord(c) for c in a.keys] + [13]) if a.keys is not None else []
m = Machine(os.path.join(a.root, a.cfg), a.port, label=a.cfg).start()
try:
    for p in progs:
        r = m.run_program(p, keys=keys, maxi=a.maxi)
        print("== %s\n   ce=%s ve=%s msg=%s status=%s line=%s idx=%s t=%.1fs\n   out=%r" % (p, r.ce, r.ve, r.msg, r.status, r.line, r.edit_index, r.t, r.text))
finally:
    m.stop()
