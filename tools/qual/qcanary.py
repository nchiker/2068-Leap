#!/usr/bin/env python3
"""RAM canary probe over the qualification corpus (docs/RAM_EFFICIENCY_RESULTS.md).

Before every case: restore the booted snapshot, fill the RAM spans believed unused (the dead parts of the
fixed V2 area and of chunk 7) and the machine-stack headroom with a canary byte, then install the case's
packages and run it exactly as qrun does.  After it: report every canary byte that changed, the lowest
stack byte touched (SP starts at $FF00, as in qharness), and the source / bytecode sizes.  A write into a
"dead" span means the span is not dead: do not reuse it.  Not part of make test (about 10 minutes).

  python3 tools/qual/qcanary.py . build/qcanary.jsonl [--workers 4] [--port 10700] [--filter s]
      [--spans B6EE-B791,...] [--banking]

--banking (docs/V2_LEAPC_BACKPORT_PLAN.md item 0.7, after 2068-Leap-C's tools/memguard.py) also arms
ZEsarUX breakpoint conditions, evaluated after every instruction, in slots the harness does not use; the
first that holds stops the case, which is then reported with the invariant's name:
  - the stack in chunk 6 ($C000-$DFFF);
  - a write to chunk 6 while the EXROM is paged in (it would be lost: the EXROM is ROM);
  - a paging depth other than 1 when the VM dispatches an op (VM_RUN.next; VM_RUN.loop before 5.2): the
    VM runs with the EXROM in, and a package call (depth 0) has returned before the next op;
  - an EXROM entry slot (V2_EXROM_CALCULATE_ADDR up to V2_EXROM_ARRSVC_ADDR: the calculator, the
    compiler's peepholes, the float built-ins of 5.9, ...) entered with the EXROM paged out (depth 0).
"""
import argparse, json, multiprocessing as mp, os, sys

# Dead spans of the layout after the RAM-efficiency change (the compile zone is $B850-$B97D; $B400-$B5FF
# became bytecode).  The first audit (pre-change) probed $B400-$B4DF, $B4EA-$B5FF, $B6E4-$B791,
# $B7A8-$B7FF, $B84C-$B9E8, $B9ED-$B9FF, $BA5E-$BD9E, $BDA1-$BDCF, $BDE1-$BE6F: no writes in 667 cases.
SPANS = [(0xB6EE, 0xB791), (0xB7A8, 0xB7FF), (0xB84C, 0xB84F), (0xB97E, 0xB9E8), (0xB9ED, 0xB9FF),
         (0xBA5E, 0xBDCF), (0xBDE1, 0xBE6F), (0xF100, 0xF17F), (0xF328, 0xF3AE)]
STACK = (0xF800, 0xFEFF)
CAN = 0xA5
INV_SLOTS = (9, 10, 11, 12)


def invariants(S):
    d = S("BANK_EXROM_DEPTH")
    return [("the stack in chunk 6", "SP>BFFFH and SP<E000H"),
            ("a write to chunk 6 with the EXROM paged in", "MWA>BFFFH and MWA<E000H and PEEK(%04XH)<>0" % d),
            ("a paging depth other than 1 at the VM's dispatch",
             "PC=%04XH and PEEK(%04XH)<>1" % (dispatch(S), d)),
            ("an EXROM entry slot entered with the EXROM paged out",
             "PC>%04XH and PC<%04XH and PEEK(%04XH)=0" % (S("V2_EXROM_CALCULATE_ADDR") - 1, S("V2_EXROM_ARRSVC_ADDR"), d))]


def dispatch(S):
    """Every op passes VM_RUN.next since 5.2 (VM_RUN.loop, the BREAK poll, falls into it); before, .loop."""
    try:
        return S("VM_RUN.next")
    except KeyError:
        return S("VM_RUN.loop")


def arm(m):
    for slot, (_, cond) in zip(INV_SLOTS, invariants(m.sym)):
        m.cmd("set-breakpoint %d %s" % (slot, cond))


def fired(m):
    out = []
    for name, cond in invariants(m.sym):
        try:
            if int(m.cmd("evaluate " + cond).strip().split()[0]):
                out.append(name)
        except (ValueError, IndexError):
            pass
    return out


def worker(tree, port, cids, outp, spans, banking=False):
    sys.path.insert(0, os.path.join(tree, "tools", "qual"))
    import corpus
    from qharness import Machine
    cases = {c.cid: c for c in corpus.CASES}
    m = Machine(tree, port, label="qcanary%d" % port).start()
    S = m.sym
    with open(outp, "a") as fo:
        for cid in cids:
            c = cases[cid]
            rec = {"cid": cid}
            try:
                m.restore()
                for a, b in spans + [STACK]:
                    m.write(a, bytes([CAN]) * (b - a + 1))
                for p in c.packages:
                    m.install_package(p)
                m.put_store(c.lines)
                if c.prepare:
                    c.prepare(m)
                if banking:
                    arm(m)
                r = m.call_routine("V2_RUN_STORED", keys=c.keys, maxi=c.maxi)
                if banking:
                    rec["invariants"] = fired(m) if r.status == "HUNG" else []
                hits = []
                for a, b in spans:
                    d = m.read(a, b - a + 1)
                    hits += ["%04X" % (a + i) for i, x in enumerate(d) if x != CAN]
                st = m.read(STACK[0], STACK[1] - STACK[0] + 1)
                low = next((STACK[0] + i for i, x in enumerate(st) if x != CAN and STACK[0] + i not in (0xFE00, 0xFE01)), None)
                pas, pe = S("PROG_AREA_START"), m.w16(S("PROG_END"))
                rec.update(status=r.status, ce=r.ce, ve=r.ve, hits=hits[:40], nhits=len(hits),
                           stack_low="%04X" % low if low is not None else None,
                           src=pe - pas, code=m.w16(S("EMIT_PTR")) - S("V2_CODE_BASE"),
                           arrays_end=m.w16(S("ARRAYS_END")), csp=m.w16(S("VM_CSP")),
                           vars_start=m.w16(S("VARS_START")))
            except Exception as e:
                rec["error"] = repr(e)
                try:
                    m.stop()
                except Exception:
                    pass
                m = Machine(tree, port, label="qcanary%d" % port).start()
            fo.write(json.dumps(rec) + "\n")
            fo.flush()
    m.stop()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tree")
    ap.add_argument("out")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--port", type=int, default=10700)
    ap.add_argument("--filter", default="")
    ap.add_argument("--spans", default="", help="lo-hi,lo-hi (hex) instead of the default list")
    ap.add_argument("--banking", action="store_true", help="also check the banking invariants (see above)")
    a = ap.parse_args()
    tree = os.path.abspath(a.tree)
    sys.path.insert(0, os.path.join(tree, "tools", "qual"))
    import corpus
    spans = SPANS
    if a.spans:
        spans = [tuple(int(x, 16) for x in s.split("-")) for s in a.spans.split(",")]
    ids = [c.cid for c in corpus.CASES if a.filter in c.cid or a.filter in c.feature]
    if os.path.exists(a.out):
        os.remove(a.out)
    ps = [mp.Process(target=worker, args=(tree, a.port + w, ids[w::a.workers], a.out, spans, a.banking))
          for w in range(a.workers)]
    for p in ps:
        p.start()
    for p in ps:
        p.join()
    recs = [json.loads(l) for l in open(a.out)]
    bad = [r for r in recs if r.get("nhits")]
    err = [r for r in recs if "error" in r]
    lows = [int(r["stack_low"], 16) for r in recs if r.get("stack_low")]
    inv = [r for r in recs if r.get("invariants")]
    print("cases %d  canary-hits %d  errors %d  banking-violations %d" % (len(recs), len(bad), len(err), len(inv)))
    for r in inv[:30]:
        print("  BANKING", r["cid"], "; ".join(r["invariants"]))
    for r in bad[:30]:
        print("  HIT", r["cid"], r["nhits"], r["hits"][:8])
    if lows:
        print("lowest stack byte touched: %04X (%d bytes below $FF00)" % (min(lows), 0xFF00 - min(lows)))
    return 1 if (bad or err or inv) else 0


if __name__ == "__main__":
    sys.exit(main())
