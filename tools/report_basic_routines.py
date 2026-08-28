#!/usr/bin/env python3
"""Rank BASIC global blocks by assembled size and textual reference count."""

import re
import sys
from pathlib import Path


LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$")
SYM_RE = re.compile(r"^([^:]+):\s+EQU\s+0x([0-9A-F]+)$", re.I)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: report_basic_routines.py basic/basic.asm HOME.sym", file=sys.stderr)
        return 2
    source_path, sym_path = map(Path, sys.argv[1:])
    lines = source_path.read_text().splitlines()
    symbols = {}
    for line in sym_path.read_text().splitlines():
        match = SYM_RE.match(line)
        if match:
            symbols[match.group(1)] = int(match.group(2), 16)

    try:
        basic_start = symbols["BASIC_TOKENIZE_LINE"]
        basic_end = symbols["MEM_INIT"]
    except KeyError as error:
        print(f"required boundary symbol missing: {error.args[0]}", file=sys.stderr)
        return 1

    labels = []
    for lineno, line in enumerate(lines, 1):
        match = LABEL_RE.match(line)
        if match and match.group(1) in symbols:
            name = match.group(1)
            address = symbols[name]
            if basic_start <= address < basic_end:
                kind = "data" if re.match(r"(?:DB|DW|DEFB|DEFW)\b", match.group(2), re.I) else "code"
                labels.append((address, lineno, name, kind))
    labels.sort()

    source_without_comments = "\n".join(line.split(";", 1)[0] for line in lines)
    rows = []
    for index, (address, lineno, name, kind) in enumerate(labels):
        end = labels[index + 1][0] if index + 1 < len(labels) else basic_end
        refs = len(re.findall(rf"\b{re.escape(name)}\b", source_without_comments)) - 1
        rows.append((end - address, address, end, lineno, refs, kind, name))

    print("| Bytes | Address range | Refs | Kind | Line | Global block |")
    print("|---:|---|---:|---|---:|---|")
    for size, address, end, lineno, refs, kind, name in sorted(rows, reverse=True):
        print(f"| {size} | `${address:04X}-${end-1:04X}` | {refs} | {kind} | {lineno} | `{name}` |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
