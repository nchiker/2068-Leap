#!/usr/bin/env python3
"""Find candidate RAM scratch cells that a register could replace (a HOME-budget shrink aid).

Lists, for the given sources (default: the HOME compiler and its symbol table):
  (1) RAM cells whose code references all sit in ONE routine -- typically a value parked across a
      call.  Check what runs between the store and the load: `rst $08` (LEX_NEXT_TOKEN) preserves
      BC/DE; `rst $20` (EMIT_BYTE) preserves A/BC/DE; CHK_ERR and CSTK_TOP preserve BC; a recursive
      COMPILE_EXPR/COMPILE_STR_EXPR preserves nothing (use push/pop -- reentrancy).
  (2) cells with exactly one writing routine and one (other) reading routine -- a value passed
      from caller to callee (or a lookup's output) in RAM, where a register may already hold it.
These are candidates only: verify every one by reading the code, then prove the change with
qbytecode.py / qdiff.py / qcov_changed.py.  A cell read by another bank (EXROM, through
build/v2_crossbank.inc) or by a test is not a candidate even if it shows up here.

  python3 tools/qual/scan_scratch_cells.py [file.asm ...]
"""
import re
import sys
from collections import defaultdict

FILES = ["rom/exrom_v2_compiler.asm", "rom/exrom_v2_symtab.asm"]
LAYOUT = ["include/v2_layout.inc", "rom/exrom_v2_compiler.asm", "rom/exrom_v2_vm_core.asm"]


def main():
    files = sys.argv[1:] or FILES
    cells = {}
    for f in LAYOUT:
        for line in open(f, encoding="utf-8", errors="replace"):
            m = re.match(r"([A-Z_][A-Z0-9_]*):?\s+equ\s+\$([0-9A-Fa-f]{4})\b", line.split(";")[0], re.I)
            if m and int(m.group(2), 16) >= 0x8000:
                cells[m.group(1)] = int(m.group(2), 16)
    refs, writers, readers = defaultdict(list), defaultdict(set), defaultdict(set)
    for f in files:
        routine = "?"
        for i, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
            code = line.split(";")[0].rstrip()
            m = re.match(r"([A-Z_][A-Z0-9_]*):", code)
            if m and not re.search(r"\bequ\b", code, re.I):
                routine = m.group(1)
            body = re.sub(r"^\S*:\s*", "", code).strip() if code[:1] not in " \t" else code.strip()
            if not body or re.search(r"\bequ\b", body, re.I):
                continue
            for name in set(re.findall(r"\b[A-Z_][A-Z0-9_]*\b", body)) & set(cells):
                refs[name].append((i, routine, body))
                if re.match(r"ld \(%s\)," % name, body):
                    writers[name].add(routine)
                elif re.match(r"ld \w+,\(%s\)" % name, body):
                    readers[name].add(routine)
    print("(1) cells referenced from exactly one routine")
    for name, rs in sorted(refs.items(), key=lambda kv: kv[1][0][0]):
        if len({r for _, r, _ in rs}) == 1:
            print("  %-26s $%04X  %-28s %s" % (name, cells[name], rs[0][1], "  |  ".join("%d:%s" % (i, b) for i, _, b in rs)))
    print("(2) cells with one writing routine and one other reading routine")
    for name in sorted(set(writers) | set(readers)):
        if len(writers[name]) == 1 and len(readers[name]) == 1 and writers[name] != readers[name]:
            print("  %-26s written in %-28s read in %s" % (name, next(iter(writers[name])), next(iter(readers[name]))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
