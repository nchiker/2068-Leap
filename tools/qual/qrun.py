#!/usr/bin/env python3
"""Run the conformance corpus against one or more configurations, in parallel (one emulator each).

  python3 tools/qual/qrun.py --root ~/2068-Leap-study/qual-builds --out <dir> [--cfg baseline,essential,enhanced]
                            [--filter substr] [--port 10440] [--workers-per-cfg 1]
Writes <out>/<cfg>.jsonl (one record per case) and prints a per-config summary.
Status per case: PASS, FAIL, XFAIL (documented defect reproduced), XPASS (marked defect now correct),
N/A (feature not part of this configuration by design), BLOCKED (harness could not run it).
"""
import argparse
import json
import multiprocessing as mp
import os
import sys
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def worker(cfg, cfgdir, port, case_ids, outpath, q):
    import corpus
    from qharness import Machine
    cases = {c.cid: c for c in corpus.CASES}
    m = None
    with open(outpath, "a") as fo:
        def boot():
            nonlocal m
            if m:
                try:
                    m.stop()
                except Exception:
                    pass
            m = Machine(cfgdir, port, label=cfg).start()
        boot()
        for cid in case_ids:
            c = cases[cid]
            rec = {"cid": cid, "cfg": cfg, "feature": c.feature, "lines": c.lines, "note": c.note,
                   "decision": c.decision, "known": c.known.get(cfg)}
            t0 = time.time()
            if cfg not in c.only:
                rec.update(status="N/A", detail="not applicable to %s" % cfg)
            else:
                exp = c.expect[cfg]
                rec["expect"] = exp.describe()
                try:
                    r = m.run_program(c.lines, keys=c.keys, maxi=c.maxi, packages=c.packages, prepare=c.prepare)
                    ok, detail, cls = exp.check(r)
                    if c.post is not None:
                        pok, pdetail = c.post(m, r)
                        ok = ok and pok
                        detail = detail + " | post: " + pdetail
                    rec.update(result=r.as_dict(), detail=detail, cls=cls)
                    k = c.known.get(cfg)
                    if not ok and not k and cls == "D10":
                        k = rec["known"] = "D10"     # the documented float-display truncation (R10.8 D10)
                    rec["status"] = ("XPASS" if ok else "XFAIL") if k else ("PASS" if ok else "FAIL")
                except Exception as e:
                    rec.update(status="BLOCKED", detail="harness: " + "".join(traceback.format_exception_only(type(e), e)).strip())
                    try:
                        boot()
                    except Exception as e2:
                        rec["detail"] += " / reboot failed: %s" % e2
            rec["t"] = round(time.time() - t0, 2)
            fo.write(json.dumps(rec) + "\n")
            fo.flush()
            q.put((cfg, cid, rec["status"]))
    m.stop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.expanduser("~/2068-Leap-study/qual-builds"))
    ap.add_argument("--out", required=True)
    ap.add_argument("--cfg", default="baseline,essential,enhanced")
    ap.add_argument("--filter", default="")
    ap.add_argument("--port", type=int, default=10440)
    ap.add_argument("--workers-per-cfg", type=int, default=1)
    a = ap.parse_args()
    import corpus
    os.makedirs(a.out, exist_ok=True)
    flt = [f for f in a.filter.split(",") if f]
    ids = [c.cid for c in corpus.CASES if not flt or any(f in c.cid or f in c.feature for f in flt)]
    cfgs = a.cfg.split(",")
    q = mp.Queue()
    procs = []
    port = a.port
    for cfg in cfgs:
        outp = os.path.join(a.out, "%s.jsonl" % cfg)
        if os.path.exists(outp):
            os.remove(outp)
        n = a.workers_per_cfg
        for w in range(n):
            part = ids[w::n]
            p = mp.Process(target=worker, args=(cfg, os.path.join(a.root, cfg), port, part, outp, q))
            port += 1
            p.start()
            procs.append(p)
    total = len(ids) * len(cfgs)
    done, counts, t0 = 0, {}, time.time()
    while done < total:
        try:
            cfg, cid, st = q.get(timeout=1200)
        except Exception:
            if not any(p.is_alive() for p in procs):
                break
            continue
        done += 1
        counts.setdefault(cfg, {}).setdefault(st, 0)
        counts[cfg][st] += 1
        if st in ("FAIL", "XPASS", "BLOCKED"):
            print("%-9s %-7s %s" % (cfg, st, cid), flush=True)
        if done % 50 == 0:
            print("... %d/%d (%.0fs)" % (done, total, time.time() - t0), flush=True)
    for p in procs:
        p.join()
    for cfg in cfgs:
        print(cfg, json.dumps(counts.get(cfg, {}), sort_keys=True))
    print("total %.0fs" % (time.time() - t0))


if __name__ == "__main__":
    main()
