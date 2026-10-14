#!/usr/bin/env python3
"""Did a differential corpus actually EXECUTE the code a change touched?  Companion to qdiff.py.

For each source file (default: the HOME compiler and its symbol table), every instruction line that
differs between tree A and tree B, plus the first instruction after each deletion, is located in
B's listing (build/test_basic.lst, or --listing) and checked against an executed-address list
(qdiff.py's coverage_b.json, from ZEsarUX's cpu-code-coverage).  Every conditional jr/jp in or next
to the changed lines is also checked both ways: its target AND its fall-through must have run.

  python3 tools/qual/qcov_changed.py TREE_A TREE_B coverage_b.json [--file rom/x.asm ...]

Exit status 1 if anything was not executed -- write a targeted program for it and run qdiff again.
"""
import argparse
import difflib
import json
import os
import re
import sys

DEFAULT_FILES = ("rom/exrom_v2_compiler.asm", "rom/exrom_v2_symtab.asm")


def listing_lines(lst):
    """(file basename, source line) -> (address, bytes), from the `# file opened/closed` markers."""
    stack, out = [], {}
    for line in open(lst, encoding="latin-1"):
        if line.startswith("# file opened:"):
            stack.append(os.path.basename(line.split(":", 1)[1].strip()))
        elif line.startswith("# file closed:"):
            stack.pop()
        else:
            m = re.match(r"^\s*(\d+)\+*\s+([0-9A-F]{4})\s+((?:[0-9A-F]{2} ?)+)", line)
            if m and stack:
                out[(stack[-1], int(m.group(1)))] = (int(m.group(2), 16), bytes.fromhex(m.group(3).replace(" ", "")))
    return out


def code_of(s):
    return s.split(";")[0].strip()


def is_instruction(s):
    c = code_of(s)
    return bool(c) and not c.endswith(":") and not re.match(r"^[A-Z_.][\w.]*:?\s+equ\b", c, re.I)


def changed_lines(a_lines, b_lines):
    """B line numbers (1-based): changed/inserted instructions, and the next instruction after each
    deletion; plus a 2-line tail after every hunk for the branch check."""
    sm = difflib.SequenceMatcher(None, [code_of(x) for x in a_lines], [code_of(x) for x in b_lines], autojunk=False)
    must, near = {}, set()
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        rng = range(j1, j2) if tag in ("replace", "insert") else range(0)
        for j in rng:
            if is_instruction(b_lines[j]):
                must[j + 1] = "changed"
        removed_code = any(is_instruction(a_lines[i]) for i in range(i1, i2))
        if removed_code and not any(is_instruction(b_lines[j]) for j in rng):
            j = j2
            while j < len(b_lines) and not is_instruction(b_lines[j]):
                j += 1
            if j < len(b_lines):
                must.setdefault(j + 1, "after deletion")
        near |= set(range(j1 + 1, j2 + 3))
    return must, near


def branch_target(addr, by):
    if by[0] in (0x20, 0x28, 0x30, 0x38) and len(by) == 2:            # jr cc,e
        return (addr + 2 + (by[1] - 256 if by[1] > 127 else by[1])) & 0xFFFF
    if by[0] in (0xC2, 0xCA, 0xD2, 0xDA, 0xE2, 0xEA, 0xF2, 0xFA) and len(by) == 3:   # jp cc,nn
        return by[1] | by[2] << 8
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tree_a")
    ap.add_argument("tree_b")
    ap.add_argument("coverage")
    ap.add_argument("--file", action="append", help="source file(s) to compare (default: %s)" % ", ".join(DEFAULT_FILES))
    ap.add_argument("--listing", default="build/test_basic.lst", help="B's listing, relative to tree B")
    a = ap.parse_args()
    cov = set(json.load(open(a.coverage)))
    lmap = listing_lines(os.path.join(a.tree_b, a.listing))
    n_must = n_hit = n_br = n_br_ok = 0
    gaps = []
    for f in a.file or DEFAULT_FILES:
        al = open(os.path.join(a.tree_a, f), encoding="utf-8", errors="replace").read().split("\n")
        bl = open(os.path.join(a.tree_b, f), encoding="utf-8", errors="replace").read().split("\n")
        must, near = changed_lines(al, bl)
        base = os.path.basename(f)
        for ln in sorted(must):
            hit = lmap.get((base, ln))
            if hit is None:
                continue                          # not assembled (an IFDEF branch this build does not take)
            n_must += 1
            if hit[0] in cov:
                n_hit += 1
            else:
                gaps.append("NOT RUN    %s:%d  $%04X  (%s)  %s" % (base, ln, hit[0], must[ln], code_of(bl[ln - 1])))
        for ln in sorted(near):
            hit = lmap.get((base, ln))
            if hit is None:
                continue
            tgt = branch_target(*hit)
            if tgt is None:
                continue
            n_br += 1
            fall = hit[0] + len(hit[1])
            ok = hit[0] in cov and tgt in cov and fall in cov
            n_br_ok += ok
            if not ok:
                gaps.append("ONE-WAY    %s:%d  $%04X  %-30s taken=%s fall-through=%s"
                            % (base, ln, hit[0], code_of(bl[ln - 1]), tgt in cov, fall in cov))
    print("changed instructions (and first after each deletion): %d, executed: %d" % (n_must, n_hit))
    print("conditional branches in or next to the changes: %d, both directions executed: %d" % (n_br, n_br_ok))
    for g in gaps:
        print("  " + g)
    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main())
