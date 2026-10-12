#!/usr/bin/env python3
"""Report current ROM and integrated R9 source/code/workspace budgets."""

import re
import sys
from pathlib import Path


def end_before_padding(path: Path, limit: int) -> int:
    text = path.read_text()
    # The final padding expression may use a symbolic end address (the
    # integrated V2 images do); capture its assembled start address instead
    # of requiring a literal `$HEX` expression.
    pattern = re.compile(r"^\s*\d+\s+([0-9A-F]+).*?DS\s+.*-\s*\$", re.M | re.I)
    matches = [int(m.group(1), 16) for m in pattern.finditer(text)]
    if not matches:
        raise SystemExit(f"could not find final padding directive in {path}")
    end = matches[-1]
    if end > limit:
        raise SystemExit(f"assembled address {end:#x} exceeds limit {limit:#x}")
    return end


def symbols(path: Path) -> dict[str, int]:
    result = {}
    for line in path.read_text().splitlines():
        match = re.match(r"([^:]+):\s+EQU\s+0x([0-9A-F]+)", line, re.I)
        if match:
            result[match.group(1)] = int(match.group(2), 16)
    return result


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: report_budget.py HOME.lst EXROM.lst HOME.sym", file=sys.stderr)
        return 2
    home_end = end_before_padding(Path(sys.argv[1]), 0x4000)
    exrom_end = end_before_padding(Path(sys.argv[2]), 0xE000)
    syms = symbols(Path(sys.argv[3]))
    program_start = syms["PROG_AREA_START"]
    source_end = syms["V2_SOURCE_END"]
    stage_start = syms["V2_SOURCE_STAGE"]
    code_start = syms["VM_CODE_BASE"]
    code_end = syms["V2_CODE_LIMIT"]
    zone_size = syms["V2_ZONE_SIZE"]
    fixed_end = syms["PROG_AREA_MAX"]
    print(f"Home ROM: {home_end:#06x}/0x4000 used, {0x4000-home_end} bytes free")
    print(f"EXROM:    {exrom_end:#06x}/0xe000 end, {0xE000-exrom_end} bytes free")
    print(
        f"Source:   {program_start:#06x}-{source_end-1:#06x}, "
        f"{source_end-program_start} bytes"
    )
    print(f"Bytecode: {code_start:#06x}-{code_end-1:#06x}, {code_end-code_start} bytes")
    print(
        f"Fixed V2: {code_end:#06x}-{fixed_end-1:#06x}, {fixed_end-code_end} bytes "
        f"(incl. compile zone {stage_start:#06x}-{stage_start+zone_size-1:#06x}, {zone_size} bytes)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
