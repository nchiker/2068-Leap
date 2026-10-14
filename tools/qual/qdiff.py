#!/usr/bin/env python3
"""Differential compile check between two builds: does a compiler change leave the compiler's whole
effect unchanged?  Stronger than qbytecode.py (which compares the bytecode and the error code only).

Every case is compiled (V2_RUN_STORED up to V2_COMPILE_RUN.compiled or V2_SHOW_MESSAGE) from each
build's own booted snapshot, on two machines in lockstep.  Compared per case:
  * where the compile stopped (compiled / message / anywhere else = a crash or a hang), SP and HL
    there -- an unbalanced push/pop on any path shows up here;
  * all RAM $4000-$BFFF and $E000-$FFFF ($C000-$DFFF reads as the paged-in EXROM): the bytecode,
    symbol tables, error code and line, and every other side effect.
Not compared: dead stack below the final SP ($F800 up), and the cells B deliberately no longer
writes (--auto-exclude derives them from the two source trees: RAM cells A's code references and
B's code does not; --exclude adds more).  Two cells are reported apart as BENIGN unless --strict:
FRAMES (the 50 Hz counter: a faster or slower compile sees one frame more or less) and
EXT2_LOOKUP_NAME (holds the ROM address of the "LPRINT" name string, which moves when HOME code
does).

Corpus: the 667 qualification programs (corpus.py) and/or generated programs aimed at the
compiler's expression, array, function-call, extension, FOR/NEXT, IF/ELSE, INPUT and DIM paths:
valid ones, a mutated copy of each (truncated line or a dropped '(),="$' -- the error paths),
long ones (40-110 statements: tokens across the 264-byte source-chunk refills) and a handwritten
error list.  Coverage of build B is collected with ZEsarUX's cpu-code-coverage; feed it to
qcov_changed.py to show the corpus actually executed every changed instruction.

  tools/qual/build_configs.sh /tmp/qd before=<ref> after=<ref>     # or copy a tree + make build v2-packages
  python3 tools/qual/qdiff.py --root /tmp/qd --a before --b after --auto-exclude --out /tmp/qd/out
  python3 tools/qual/qcov_changed.py /tmp/qd/before /tmp/qd/after /tmp/qd/out/coverage_b.json

~2,700 cases take about 30 minutes with 3 workers (each worker = 2 emulators, ports --port..+5).
Exit status 1 if any case differs (benign cells excepted).
"""
import argparse
import json
import multiprocessing as mp
import os
import random
import re
import struct
import sys
import time
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

RANGES = [(0x4000, 0xC000), (0xE000, 0x10000)]
STACK_FLOOR = 0xF800
BENIGN = {"FRAMES": 1, "EXT2_LOOKUP_NAME": 2}


class Case:
    def __init__(self, cid, lines, packages=()):
        self.cid, self.lines, self.packages = cid, list(lines), tuple(packages)


# ------------------------------------------------------------------ generator
NUM_FN = [("ABS", "n"), ("SGN", "n"), ("MOD", "nn"), ("DIV", "nn"), ("RND", "n"), ("POINT", "nn"),
          ("ATTR", "nn"), ("INT", "n"), ("PEEK", "n"), ("LEN", "s"), ("CODE", "s"), ("VAL", "s"),
          ("SQR", "n"), ("PI", ""), ("RAD", "n"), ("DEG", "n"), ("SIN", "n"), ("FREE", ""), ("FREE", "n"),
          ("COS", "n"), ("TAN", "n"), ("IN", "n"), ("STICK", "n")]
STR_FN = [("CHR$", "n"), ("STR$", "n"), ("UPPER$", "s"), ("LOWER$", "s"), ("LEFT$", "sn"), ("RIGHT$", "sn"),
          ("MID$", "snn"), ("INKEY$", "")]
PKG_STMTS = {"shapes": [("CIRCLE", 3), ("FILL", 2)], "sprite": [("GRAB", 5), ("SHOW", 3), ("MOVE", 3), ("HIDE", 1)],
             "mode": [("MODE", 1), ("PALETTE", 2), ("ULAPLUS", 1)], "printer": []}


class Gen:
    def __init__(self, seed):
        self.r = random.Random(seed)

    def lit(self):
        n = self.r.choice([0, 0, 1, 3, 5, 12, 20, 25, 31])
        return '"' + "".join(self.r.choice("abcXYZ 019") for _ in range(n)) + '"'

    def call(self, name, sig, d):
        return "%s(%s)" % (name, ",".join(self.str(d - 1) if t == "s" else self.num(d - 1) for t in sig))

    def num(self, d):
        r = self.r.random()
        if d <= 0 or r < 0.25:
            return self.r.choice(["0", "1", "2", "3", "5", "9", "255", "2.5", "a", "b", "k"])
        if r < 0.40:
            return "%s(%s)" % (self.r.choice(["n", "m"]), self.num(d - 1))
        if r < 0.70:
            return self.call(*self.r.choice(NUM_FN), d)
        if r < 0.80:
            return "%s %s %s" % (self.num(d - 1), self.r.choice("+-*/"), self.num(d - 1))
        if r < 0.85:
            return "(%s)" % self.num(d - 1)
        if r < 0.90:
            return "DIMN(%s)" % self.r.choice(["n", "m"])
        return self.call(*self.r.choice([f for f in NUM_FN if "s" in f[1]]), d)

    def str(self, d):
        r = self.r.random()
        if d <= 0 or r < 0.25:
            return self.r.choice([self.lit(), "s$", "t$"])
        if r < 0.45:
            return "w$(%s)" % self.num(d - 1)
        if r < 0.85:
            return self.call(*self.r.choice(STR_FN), d)
        return "%s + %s" % (self.str(d - 1), self.str(d - 1))

    def stmt(self, d, pkg, depth=0):
        r = self.r.random()
        if pkg and r < 0.12 and PKG_STMTS[pkg]:
            kw, n = self.r.choice(PKG_STMTS[pkg])
            return ["%s %s" % (kw, ",".join(self.num(d) for _ in range(n)))]
        if pkg == "printer" and r < 0.12:
            return ["LPRINT " + (self.str(d) if self.r.random() < 0.5 else self.num(d))]
        if r < 0.22:
            return ["%s = %s" % (self.r.choice("abk"), self.num(d))]
        if r < 0.34:
            return ["%s = %s" % (self.r.choice(["s$", "t$"]), self.str(d))]
        if r < 0.48:
            return ["%s(%s) = %s" % (self.r.choice("nm"), self.num(d), self.num(d))]
        if r < 0.60:
            return ["w$(%s) = %s" % (self.num(d), self.str(d))]
        if r < 0.68:
            return ["PRINT " + (self.str(d) if self.r.random() < 0.5 else self.num(d))]
        if r < 0.71:
            return [self.r.choice(["INPUT a", "INPUT s$", "INPUT k", "INPUT t$"])]
        if r < 0.82 and depth < 2:
            v = self.r.choice("abk")
            body = sum((self.stmt(d, pkg, depth + 1) for _ in range(self.r.randint(0, 3))), [])
            return ["FOR %s = 1 TO %s" % (v, self.num(d - 1))] + body + [self.r.choice(["NEXT " + v, "NEXT"])]
        if depth < 2:
            out = ["IF %s = %s THEN" % (self.num(d - 1), self.num(d - 1))]
            out += sum((self.stmt(d, pkg, depth + 1) for _ in range(self.r.randint(0, 2))), [])
            if self.r.random() < 0.6:
                out += ["ELSE"] + sum((self.stmt(d, pkg, depth + 1) for _ in range(self.r.randint(0, 2))), [])
            return out + ["ENDIF"]
        return ["a = %s" % self.num(d)]

    def program(self, nstmts, depth, pkg=None):
        lines = ["DIM n(6)", "DIM m(4)", "DIM w$(6)"]
        for _ in range(nstmts):
            lines += self.stmt(depth, pkg)
        return lines

    def mutate(self, lines):
        lines = list(lines)
        i = self.r.randrange(3, len(lines)) if len(lines) > 3 else len(lines) - 1
        l = lines[i]
        if self.r.random() < 0.4 and len(l) > 1:
            lines[i] = l[:self.r.randrange(1, len(l))]                      # truncate the line
        else:
            pos = [j for j, ch in enumerate(l) if ch in '(),="$']
            if pos:
                j = self.r.choice(pos)
                lines[i] = l[:j] + l[j + 1:]                                # drop one punctuation char
            else:
                lines[i] = l + self.r.choice([" )", " ,", " (", " ="])
        return lines


HANDWRITTEN = [
    ["FOR k = 1 TO 3", "NEXT a"], ["NEXT"], ["NEXT k"], ["FOR k = 1 TO 2", "NEXT", "a = k"],
    ["FOR a = 1 TO 2", "FOR b = 1 TO 2", "NEXT", "NEXT a"],
    ['s$ = "' + "x" * 31 + '"'], ['s$ = "' + "x" * 32 + '"'], ['s$ = ""', "a = LEN(s$)"],
    ["a = ABS 3"], ["a = FREE("], ["a = FREE(1"], ["a = FREE(1,2)"], ["a = FREE()"], ["a = PI()"],
    ['s$ = LEFT$("abc" 3)'], ['s$ = LEFT$("abc",3'], ['s$ = MID$("abc",1)'], ['s$ = MID$("abc",1,2,3)'],
    ["a = LEN(5)"], ['a = ABS("x")'], ["a = MOD(5)"], ["a = LEN(UPPER$(LEFT$(s$,2)))"],
    ["DIM n(3)", "a = DIMN(z)"], ["DIM n(3)", "a = DIMN(n"], ["DIM n(3)", "a = DIMN n"], ["DIM n(3)", "a = DIMN(n)"],
    ["DIM n(3)", "n(1 = 2"], ["DIM n(3)", "n(1) 5"], ["DIM n(3)", "a = n(1"], ['z$(1) = "q"'], ["z(1) = 3"],
    ["DIM w$(3)", 'w$(1 = "a"'], ["DIM w$(3)", 'w$(1) "a"'], ["DIM w$(3)", "a = LEN(w$(1)"],
    ["DIM n(3)", "DIM w$(3)", "a = LEN(w$(n(0)))", 'w$(n(0)) = "x"', "n(LEN(w$(0))) = 1",
     "w$(1) = w$(n(0))", "n(1) = LEN(w$(n(0)))"],
    ["a = 1", "IF a = 1 THEN", "b = 2", "ELSE", "b = 3", "ENDIF"], ["IF 1 THEN", "ELSE", "ENDIF"],
    ["IF 1 THEN", "ELSE", "ELSE", "ENDIF"], ["IF 1 THEN", "ELSE"],
    ["IF 1 THEN", "IF 0 THEN", "ELSE", "ENDIF", "ELSE", "IF 1 THEN", "ELSE", "ENDIF", "ENDIF"],
    ["a = "], ["a"], ["a 5"], ["s$ = "], ["s$ 5"], ["INPUT"], ["INPUT 5"], ["DIM n(0)"], ["DIM n(3)", "DIM n(3)"],
    ["DIM w$(3,2)"], ["DIM w$(3,1)"], ["DIM w$(3,"], ["DIM w$(3"], ["DIM w$(3)", "DIM w$(3)"],
]


def build_cases(which, seed, ngen, nlong):
    cases = []
    if which in ("all", "corpus"):
        import corpus
        cases += [Case("corpus:" + c.cid, c.lines, c.packages) for c in corpus.CASES]
    if which in ("all", "gen"):
        g = Gen(seed)
        cases += [Case("hand:%d" % i, l) for i, l in enumerate(HANDWRITTEN)]
        for i in range(ngen):
            pkg = g.r.choice([None, None, None, "shapes", "sprite", "mode", "printer"])
            p = g.program(g.r.randint(1, 8), g.r.randint(1, 4), pkg)
            pk = (pkg,) if pkg else ()
            cases += [Case("gen:%d" % i, p, pk), Case("mut:%d" % i, g.mutate(p), pk)]
        for i in range(nlong):
            pkg = g.r.choice([None, "sprite"])
            p = g.program(g.r.randint(40, 110), g.r.randint(1, 3), pkg)
            pk = (pkg,) if pkg else ()
            cases.append(Case("long:%d" % i, p, pk))
            if i % 2:
                cases.append(Case("longmut:%d" % i, g.mutate(p), pk))
    return cases


# ------------------------------------------------------------- exclusions
SOURCES = ("include/v2_layout.inc", "rom/exrom_v2_compiler.asm", "rom/exrom_v2_symtab.asm", "rom/exrom_v2_vm_core.asm")
WORD_ACCESS = r"ld\s+\(%s(?:\+0)?\)\s*,\s*(?:hl|de|bc|ix|iy|sp)\b|ld\s+(?:hl|de|bc|ix|iy|sp)\s*,\s*\(%s(?:\+0)?\)|\b%s\s*\+\s*1\b"


def _sources(tree):
    for f in SOURCES:
        p = os.path.join(tree, f)
        if os.path.exists(p):
            yield from (l.split(";")[0] for l in open(p, encoding="utf-8", errors="replace"))


def _cells_and_refs(tree):
    cells, refs, code = {}, set(), []
    for line in _sources(tree):
        m = re.match(r"([A-Z_][A-Z0-9_]*):?\s+equ\s+\$([0-9A-Fa-f]{4})\b", line, re.I)
        if m:
            cells[m.group(1)] = int(m.group(2), 16)
        else:
            refs |= set(re.findall(r"\b[A-Z_][A-Z0-9_]*\b", line))
            code.append(line)
    return cells, refs, code


def auto_exclude(tree_a, tree_b):
    """RAM cells A's code uses and B's code no longer references: B leaves them as they were.
    A cell is 2 bytes if A's code ever reads or writes it as a word (ld (X),hl / ld de,(X) / X+1)."""
    ca, ra, code_a = _cells_and_refs(tree_a)
    _, rb, _ = _cells_and_refs(tree_b)
    out = {}
    for n in sorted(set(ca) & ra - rb):
        a = ca[n]
        if a < 0x8000:
            continue
        pat = re.compile(WORD_ACCESS % ((re.escape(n),) * 3), re.I)
        out[n] = [a, a + 1] if any(pat.search(l) for l in code_a) else [a]
    return out


# ------------------------------------------------------------------ runner
def compile_case(m, case, cov):
    from qharness import HARNESS_RET_SLOT
    m.restore()
    for p in case.packages:
        m.install_package(p)
    m.put_store(case.lines)
    done, msg = m.sym("V2_COMPILE_RUN.compiled"), m.sym("V2_SHOW_MESSAGE")
    m.write(HARNESS_RET_SLOT, struct.pack("<H", m.sym("V2_COMMAND_LOOP.loop")))
    m.setreg("SP", HARNESS_RET_SLOT)
    m.setreg("PC", m.sym("V2_RUN_STORED"))
    m.set_bps([done, msg])
    if cov:
        m.cmd("cpu-code-coverage enabled yes")        # snapshot-load (restore) switches it off
        m.cmd("cpu-code-coverage clear")
    m.run(200_000_000)
    pc = m.pc()
    r = m.regs()
    where = "compiled" if pc == done else "message" if pc == msg else "PC=%04X" % pc
    executed = set()
    if cov:
        executed = {int(x, 16) for x in re.findall(r"\b[0-9A-Fa-f]{4}\b", m.cmd("cpu-code-coverage get") or "")}
    ram = b"".join(m.read(a, b - a) for a, b in RANGES)
    return where, r["SP"], r["HL"], ram, executed


def _addr_of(off):
    for a, b in RANGES:
        if off < b - a:
            return a + off
        off -= b - a


def worker(args):
    wid, cases, root, cfg_a, cfg_b, port, exclude, benign = args
    from qharness import Machine
    ma = Machine(os.path.join(root, cfg_a), port, label="qdiff-a%d" % wid).start()
    mb = Machine(os.path.join(root, cfg_b), port + 1, label="qdiff-b%d" % wid).start()
    out, cov = [], set()
    try:
        for c in cases:
            wa, spa, hla, rama, _ = compile_case(ma, c, False)
            wb, spb, hlb, ramb, ex = compile_case(mb, c, True)
            cov |= ex
            diffs, soft = [], []
            if rama != ramb:
                lo = min(spa, spb)
                for off in range(len(rama)):
                    if rama[off] != ramb[off]:
                        ad = _addr_of(off)
                        if ad in exclude or STACK_FLOOR <= ad < lo:
                            continue
                        (soft if ad in benign else diffs).append(ad)
            out.append({"cid": c.cid, "ok": wa == wb and spa == spb and hla == hlb and not diffs,
                        "a": [wa, spa, hla], "b": [wb, spb, hlb], "where": wa,
                        "diffs": ["%04X" % d for d in diffs[:12]], "ndiffs": len(diffs),
                        "benign": sorted({benign[d] for d in soft})})
    finally:
        ma.stop()
        mb.stop()
    return out, sorted(cov)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True, help="directory holding the two configuration trees")
    ap.add_argument("--a", required=True, help="reference configuration (directory name under --root)")
    ap.add_argument("--b", required=True, help="candidate configuration")
    ap.add_argument("--cases", default="all", choices=("all", "corpus", "gen"))
    ap.add_argument("--seed", type=int, default=2068)
    ap.add_argument("--gen", type=int, default=900, help="generated programs (each also mutated once)")
    ap.add_argument("--long", type=int, default=120, help="long programs (chunk-refill boundaries)")
    ap.add_argument("--limit", type=int, default=0, help="run only the first N cases (smoke test)")
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--port", type=int, default=11000, help="first ZRCP port; uses 2 per worker")
    ap.add_argument("--auto-exclude", action="store_true", help="skip the RAM cells B's code no longer references")
    ap.add_argument("--exclude", default="", help="more addresses to skip: AAAA or AAAA-BBBB, comma separated")
    ap.add_argument("--strict", action="store_true", help="count FRAMES / EXT2_LOOKUP_NAME differences as failures")
    ap.add_argument("--out", required=True, help="directory for rows.json and coverage_b.json")
    a = ap.parse_args()

    tree_a, tree_b = os.path.join(a.root, a.a), os.path.join(a.root, a.b)
    exclude = set()
    if a.auto_exclude:
        for n, span in auto_exclude(tree_a, tree_b).items():
            print("excluded (no longer used by %s): %-26s %s" % (a.b, n, " ".join("$%04X" % x for x in span)))
            exclude |= set(span)
    for t in filter(None, a.exclude.split(",")):
        lo, _, hi = t.partition("-")
        exclude |= set(range(int(lo, 16), int(hi or lo, 16) + 1))
    from qharness import load_syms
    syms = load_syms(os.path.join(tree_b, "build", "exrom.sym"), os.path.join(tree_b, "build", "test_basic.sym"))
    benign = {} if a.strict else {syms[n] + i: n for n, w in BENIGN.items() if n in syms for i in range(w)}

    cases = build_cases(a.cases, a.seed, a.gen, a.long)
    if a.limit:
        cases = cases[:a.limit]
    chunks = [cases[i::a.workers] for i in range(a.workers)]
    t0 = time.time()
    with mp.Pool(a.workers) as pool:
        res = pool.map(worker, [(i, ch, a.root, a.a, a.b, a.port + 2 * i, exclude, benign)
                                for i, ch in enumerate(chunks) if ch])
    rows = [r for out, _ in res for r in out]
    cov = sorted(set().union(*(set(c) for _, c in res)))
    os.makedirs(a.out, exist_ok=True)
    json.dump(rows, open(os.path.join(a.out, "rows.json"), "w"), indent=0)
    json.dump(cov, open(os.path.join(a.out, "coverage_b.json"), "w"))
    bad = [r for r in rows if not r["ok"]]
    print("%d cases: %d identical, %d different  (%.0f s)" % (len(rows), len(rows) - len(bad), len(bad), time.time() - t0))
    print("stop points:", dict(Counter(r["where"] for r in rows)))
    soft = Counter(n for r in rows for n in r["benign"])
    if soft:
        print("benign differences (not failures):", dict(soft))
    for r in bad[:40]:
        print("DIFF %-18s A=%s B=%s  %d byte(s), first %s" % (r["cid"], r["a"], r["b"], r["ndiffs"], r["diffs"]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
