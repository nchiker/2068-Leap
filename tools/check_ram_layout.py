#!/usr/bin/env python3
"""V2 RAM layout guard (docs/RAM_EFFICIENCY_RESULTS.md).

The main pool runs straight into the bytecode area and the compile zone lives in the fixed V2 area,
in space nothing else uses.  This check proves that from the production listings, so a cell added
later in the wrong place fails `make check` instead of corrupting a program at run time:

* the pool ends exactly where the bytecode begins, and the bytecode area keeps V2_CODE_SIZE bytes;
* no RAM cell referenced by emitted HOME or EXROM code lies inside the pool + bytecode range
  (PROG_AREA_START .. V2_CODE_LIMIT) other than the region boundaries themselves;
* no such cell lies inside the compile zone other than the zone's own cells;
* the zone does not overlap the bytecode area, the package scratch or a pinned package cell.

A cell counts as "referenced" when its name appears in an emitted (not conditionally skipped) code
line of build/test_basic.lst or build/exrom.lst, or in the definition of such a name (EQU closure).
Packages may only use pinned cells (tools/check_package_abi.py), and those are checked here too.

    python3 tools/check_ram_layout.py build/test_basic.lst build/exrom.lst build/test_basic.sym build/exrom.sym
"""
import re
import sys

POOL_BOUNDS = {"PROG_AREA_START", "V2_SOURCE_END", "VM_CODE_BASE", "V2_CODE_BASE", "V2_CODE_LIMIT"}
ZONE_CELLS = {"V2_ZONE_BASE", "V2_SOURCE_STAGE", "CHUNK_BUF", "CHUNK_NEXT_REC", "CHUNK_FILL_PTR",
              "LEX_LINE", "STMT_IDENT_NAME_BUF"}

LINE = re.compile(r"^\s*\d+\+*\s+([0-9A-F]{4})\s?(~?)\s*((?:[0-9A-F]{2} )*)\s*(.*)$")
IDENT = re.compile(r"[A-Za-z_.][A-Za-z0-9_.]*")


def symbols(paths):
    out = {}
    for path in paths:
        for line in open(path):
            m = re.match(r"(\S+?):\s+EQU\s+0x([0-9A-Fa-f]+)", line)
            if m:
                out.setdefault(m.group(1), int(m.group(2), 16))
    return out


def referenced(listings):
    used, deps = set(), {}
    for path in listings:
        for raw in open(path, errors="replace"):
            m = LINE.match(raw)
            if not m or m.group(2):
                continue
            addr, code = int(m.group(1), 16), m.group(4).split(";", 1)[0]
            d = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*):?\s+(?i:equ)\s+(.*)", code)
            if d:
                deps.setdefault(d.group(1), set()).update(IDENT.findall(d.group(2)))
                continue
            if m.group(3).strip() and (addr < 0x4000 or 0xC000 <= addr < 0xE000):
                used.update(IDENT.findall(re.sub(r"^\s*[A-Za-z_.][A-Za-z0-9_.]*:", "", code)))
    work = list(used)
    while work:
        for t in deps.get(work.pop(), ()):
            if t not in used:
                used.add(t)
                work.append(t)
    return used


def pins():
    out = []
    for line in open("include/v2_package_abi.inc"):
        m = re.match(r"\s*PKG_PIN\s+(\w+),\s*\$([0-9A-Fa-f]+),\s*(\d+)", line)
        if m:
            out.append((m.group(1), int(m.group(2), 16), int(m.group(3))))
    return out


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: check_ram_layout.py HOME.lst EXROM.lst HOME.sym EXROM.sym")
    S = symbols(sys.argv[3:5])
    used = referenced(sys.argv[1:3])
    errors = []

    pool_lo, code, limit = S["PROG_AREA_START"], S["VM_CODE_BASE"], S["V2_CODE_LIMIT"]
    zone_lo = S["V2_ZONE_BASE"]
    zone_hi = zone_lo + S["V2_ZONE_SIZE"]
    if S["V2_SOURCE_END"] != code:
        errors.append("the pool no longer ends at the bytecode base")
    if limit - code != S["V2_CODE_SIZE"]:
        errors.append("bytecode area is %d bytes, not V2_CODE_SIZE" % (limit - code))
    if zone_lo < limit:
        errors.append("compile zone %04X overlaps the pool or the bytecode area" % zone_lo)

    ram = {n: a for n, a in S.items() if n in used and 0x8000 <= a < 0x10000}
    for n, a in sorted(ram.items(), key=lambda x: x[1]):
        if pool_lo <= a < limit and n not in POOL_BOUNDS:
            errors.append("%s ($%04X) is inside the pool/bytecode range" % (n, a))
        if zone_lo <= a < zone_hi and n not in ZONE_CELLS:
            errors.append("%s ($%04X) is inside the compile zone" % (n, a))

    reserved = [(n, a, s) for n, a, s in pins()]
    reserved.append(("PKG_SCRATCH", S.get("PKG_SCRATCH_BASE", 0xBFB0), 11))
    for n, a, s in reserved:
        if a < zone_hi and zone_lo < a + s:
            errors.append("pinned %s overlaps the compile zone" % n)
        if a < limit and pool_lo < a + s:
            errors.append("pinned %s overlaps the pool/bytecode range" % n)

    if errors:
        for e in errors:
            print("check_ram_layout.py: " + e, file=sys.stderr)
        return 1
    print("check_ram_layout.py: pool $%04X-$%04X (%d B) -> bytecode $%04X-$%04X (%d B); zone $%04X-$%04X; "
          "%d referenced RAM cells outside both" % (pool_lo, code - 1, code - pool_lo, code, limit - 1,
                                                    limit - code, zone_lo, zone_hi - 1, len(ram)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
