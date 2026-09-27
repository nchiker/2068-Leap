#!/usr/bin/env python3
"""Emit the small RAM ABI consumed by the separately assembled V2 EXROM."""

import re
import sys
from pathlib import Path


NAMES = (
    "SRC_PTR",
    "EMIT_PTR",
    "COMPILE_ERROR_CODE",
    "VM_CODE_BASE",
    "VM_IP",
    "VM_ERROR_CODE",
    "VM_HALTED",
    "EXT2_REGISTER",
    "EXT_CALL_ARG0",
    "EXT_CALL_ARG1",
    "EXT_CALL_ARG2",
    "EXT_CALL_ARG3",
    "EXT_CALL_ARG4",
    "GFX_SET_MODE",
    "GFX_CHAR_TO_FONT_OFFSET",
    "GFX_SPRITE_CAPTURE",
    "GFX_SPRITE_DRAW",
    "MEM_LINE_FIRST",
    "MEM_LINE_NEXT",
    "MATH_MULTIPLY16",
    "MATH_NEGATE16",
    "GFX_PLOT_CLIPPED",
    "GFX_READ_PIXEL",
    "GFX_WRITE_PIXEL",
    "VM_NUM_TO_TEXT",
    "VM_STR_ADDR",
    "TAG_INT",
    "VM_CLAMP_Y191",
    "VM_COMPUTE_PRINT_ATTR",
)


def main() -> None:
    symbols = {}
    for line in Path(sys.argv[1]).read_text().splitlines():
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*): EQU 0x([0-9A-Fa-f]+)", line)
        if match:
            symbols[match.group(1)] = int(match.group(2), 16)
    missing = set(NAMES) - symbols.keys()
    if missing:
        raise SystemExit(f"missing HOME exports: {sorted(missing)}")
    out = Path(sys.argv[2])
    out.write_text("; Generated from assembled V2 HOME symbols. Do not edit.\n" + "".join(
        f"{name} EQU ${symbols[name]:04X}\n" for name in NAMES
    ))


if __name__ == "__main__":
    main()
