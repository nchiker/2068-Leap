#!/usr/bin/env python3
"""Merge per-config run results into the coverage matrix (CSV) and a markdown summary.

  python3 tools/qual/qmatrix.py <rundir> [--csv out.csv] [--md out.md] [--inventory inventory.py]
"""
import argparse
import collections
import csv
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
CFGS = ("baseline", "essential", "enhanced")


def load(rundir):
    res = collections.defaultdict(dict)
    meta = {}
    for cfg in CFGS:
        p = os.path.join(rundir, "%s.jsonl" % cfg)
        if not os.path.exists(p):
            continue
        for l in open(p):
            r = json.loads(l)
            res[r["cid"]][cfg] = r
            meta.setdefault(r["cid"], r)
    return res, meta


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rundir")
    ap.add_argument("--csv")
    ap.add_argument("--md")
    a = ap.parse_args()
    import corpus
    order = [c.cid for c in corpus.CASES]
    cases = {c.cid: c for c in corpus.CASES}
    res, meta = load(a.rundir)
    counts = {c: collections.Counter() for c in CFGS}
    rows = []
    for cid in order:
        if cid not in res:
            continue
        c = cases[cid]
        row = {"case_id": cid, "feature": c.feature, "program": " | ".join(c.lines)[:200],
               "expected": next((r.get("expect", "") for r in res[cid].values() if r.get("expect")), ""),
               "note": c.note, "decision": c.decision or ""}
        for cfg in CFGS:
            r = res[cid].get(cfg)
            st = r["status"] if r else "NOT RUN"
            counts[cfg][st] += 1
            row[cfg] = st
            row[cfg + "_known"] = (r or {}).get("known") or ""
            row[cfg + "_actual"] = ((r or {}).get("detail") or "")[:240]
        rows.append(row)
    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
    for cfg in CFGS:
        print("%-9s %s" % (cfg, dict(sorted(counts[cfg].items()))))
    if a.md:
        with open(a.md, "w") as f:
            f.write("| config | " + " | ".join(("PASS", "FAIL", "XFAIL", "XPASS", "N/A", "BLOCKED")) + " |\n|---|" + "---:|" * 6 + "\n")
            for cfg in CFGS:
                f.write("| %s | %s |\n" % (cfg, " | ".join(str(counts[cfg].get(k, 0)) for k in ("PASS", "FAIL", "XFAIL", "XPASS", "N/A", "BLOCKED"))))
            f.write("\n\n| case | feature | baseline | essential | enhanced | detail (first failing config) |\n|---|---|---|---|---|---|\n")
            for row in rows:
                if all(row[c] in ("PASS", "N/A") for c in CFGS):
                    continue
                det = next((row[c + "_actual"] for c in CFGS if row[c] not in ("PASS", "N/A")), "")
                f.write("| `%s` | %s | %s | %s | %s | %s |\n" % (row["case_id"], row["feature"],
                        *(row[c] + ("(" + row[c + "_known"] + ")" if row[c + "_known"] else "") for c in CFGS),
                        det.replace("|", "\\|")[:160]))


if __name__ == "__main__":
    main()
