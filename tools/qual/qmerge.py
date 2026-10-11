#!/usr/bin/env python3
"""Merge run directories case by case (a later directory overrides an earlier one for the same case id)
and list corpus cases that no directory ran.

  python3 tools/qual/qmerge.py --out <merged> --cfg baseline,essential,enhanced <rundir> [<rundir> ...]
  (a cfg may be given as name=srcname, e.g. costs=costs-ess4, to merge <rundir>/costs-ess4.jsonl as costs)
Writes <merged>/<cfg>.jsonl, <merged>/SOURCES.txt and prints per-config status counts.
"""
import argparse
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--cfg", default="baseline,essential,enhanced")
    ap.add_argument("dirs", nargs="+")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    order = [c.cid for c in corpus.CASES]
    with open(os.path.join(a.out, "SOURCES.txt"), "w") as f:
        f.write("merged in this order (later overrides earlier, per case id):\n" + "\n".join(a.dirs) + "\n")
    for spec in a.cfg.split(","):
        name, _, src = spec.partition("=")
        src = src or name
        recs = {}
        origin = {}
        for d in a.dirs:
            p = os.path.join(d, src + ".jsonl")
            if not os.path.exists(p):
                continue
            for line in open(p):
                r = json.loads(line)
                recs[r["cid"]] = r
                origin[r["cid"]] = d
        stale = sorted(set(recs) - set(order))
        missing = [cid for cid in order if cid not in recs]
        with open(os.path.join(a.out, name + ".jsonl"), "w") as f:
            for cid in order:
                if cid in recs:
                    r = dict(recs[cid])
                    r["run_dir"] = os.path.basename(origin[cid].rstrip("/"))
                    f.write(json.dumps(r) + "\n")
        n = collections.Counter(recs[c]["status"] for c in order if c in recs)
        print("%-10s %d cases %s  missing=%d %s  dropped(no longer in corpus)=%s"
              % (name, sum(n.values()), dict(sorted(n.items())), len(missing), missing[:12], stale))


if __name__ == "__main__":
    main()
