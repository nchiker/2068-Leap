#!/usr/bin/env python3
"""Feature-level coverage matrix (docs/v2/V2_LANGUAGE_COVERAGE.csv) and case-level results
(docs/v2/V2_LANGUAGE_CASES.csv) from the inventory, the corpus and one or more run directories.

  python3 tools/qual/qcoverage.py <rundir-with-baseline/essential/enhanced.jsonl> [--fixdir <rundir> --fixcfg costs-ess]
         --features out.csv --cases out.csv
Aggregate status per feature and configuration (worst first): FAIL > BLOCKED > XFAIL > XPASS > PASS > N/A;
no case at all -> UNTESTED; a hardware-class feature is reported with "+HW" (emulator evidence only).
"""
import argparse
import collections
import csv
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus      # noqa: E402
import inventory   # noqa: E402
import defects     # noqa: E402

CFGS = ("baseline", "essential", "enhanced")
ORDER = ["FAIL", "BLOCKED", "XFAIL", "XPASS", "PASS", "N/A"]


def load(rundir, cfg):
    out = {}
    p = os.path.join(rundir, "%s.jsonl" % cfg)
    if os.path.exists(p):
        for l in open(p):
            r = json.loads(l)
            out[r["cid"]] = r
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rundir")
    ap.add_argument("--fixdir")
    ap.add_argument("--fixcfg", default="costs-ess")
    ap.add_argument("--features", required=True)
    ap.add_argument("--cases", required=True)
    a = ap.parse_args()
    res = {c: load(a.rundir, c) for c in CFGS}
    fix = load(a.fixdir, a.fixcfg) if a.fixdir else {}
    cases_by_feature = collections.defaultdict(list)
    for c in corpus.CASES:
        cases_by_feature[c.feature].append(c)
    used = set()
    rows = []
    for item in inventory.rows():
        cids = []
        gates = []
        for key in item["tests"]:
            if key.startswith(("gate:", "study:")):
                gates.append(key)
                continue
            if key.startswith("case:"):
                cids += [c.cid for c in corpus.CASES if c.cid.startswith(key[5:])]
                continue
            for k, lst in cases_by_feature.items():
                if k == key or k.startswith(key + "."):
                    cids += [c.cid for c in lst]
                    used.add(k)
        cids = list(dict.fromkeys(cids))
        row = {"feature_id": item["id"], "kind": item["kind"], "syntax": item["syntax"],
               "configs_with_feature": " ".join(item["cfgs"]), "source": item["source"], "documented_in": item["doc"],
               "classification": item["class"], "test_ids": " ".join(cids), "other_evidence": " ".join(gates)}
        defect_ids = set()
        for cfg in CFGS:
            sts = [res[cfg][cid]["status"] for cid in cids if cid in res[cfg]]
            for cid in cids:
                r = res[cfg].get(cid)
                if r and r.get("known") and r["status"] in ("XFAIL", "FAIL"):
                    defect_ids.add(r["known"])
            if cfg not in item["cfgs"]:
                agg = "N/A"
            elif not sts:
                agg = "UNTESTED" if not gates else "GATE-ONLY"
            else:
                agg = min(sts, key=lambda s: ORDER.index(s) if s in ORDER else 0)
                n = collections.Counter(sts)
                agg += " (%s)" % ", ".join("%d %s" % (v, k) for k, v in sorted(n.items()))
            if item["class"] == "HW" and agg not in ("N/A",):
                agg += " +HW"
            row[cfg] = agg
        if fix:
            sts = [fix[cid]["status"] for cid in cids if cid in fix]
            row["fix_branch"] = (min(sts, key=lambda s: ORDER.index(s) if s in ORDER else 0) + " (%d)" % len(sts)) if sts else ""
        for cid in cids:
            for cfg in CFGS:
                r = res[cfg].get(cid)
                if r and r["status"] == "FAIL" and not r.get("known"):
                    defect_ids.add("UNCLASSIFIED:" + cid)
        row["defects"] = " ".join(sorted(defect_ids))
        sev = [defects.SEVERITY.get(d, "") for d in defect_ids]
        row["worst_severity"] = min((s for s in sev if s), key=lambda s: defects.SEV_ORDER.index(s), default="")
        row["missing_tests"] = "no automated case" if not cids and not gates else ""
        row["note"] = item["note"]
        row["recommendation"] = "; ".join(sorted({defects.FIX.get(d, "") for d in defect_ids if defects.FIX.get(d)}))
        rows.append(row)
    unmapped = sorted(set(cases_by_feature) - used)
    for k in unmapped:
        print("WARNING: corpus feature not in the inventory:", k, file=sys.stderr)
    with open(a.features, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    crow = []
    for c in corpus.CASES:
        d = {"case_id": c.cid, "feature": c.feature, "program": " | ".join(c.lines), "keys": "".join(chr(k) if 32 <= k < 127 else "<%d>" % k for k in c.keys),
             "expected": "", "decision": c.decision or "", "note": c.note}
        for cfg in CFGS:
            r = res[cfg].get(c.cid)
            d[cfg] = r["status"] if r else "NOT RUN"
            d[cfg + "_defect"] = (r or {}).get("known") or ""
            d[cfg + "_observed"] = ((r or {}).get("detail") or "")[:200]
            if r and r.get("expect"):
                d["expected"] = r["expect"]
        if fix:
            r = fix.get(c.cid)
            d["fix_branch"] = r["status"] if r else ""
        crow.append(d)
    with open(a.cases, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(crow[0].keys()))
        w.writeheader()
        w.writerows(crow)
    agg = collections.Counter()
    for r in rows:
        for cfg in CFGS:
            agg[(cfg, r[cfg].split(" ")[0])] += 1
    for cfg in CFGS:
        print(cfg, {k[1]: v for k, v in agg.items() if k[0] == cfg})


if __name__ == "__main__":
    main()
