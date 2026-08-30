#!/usr/bin/env python3
"""Validate intentional sysvar aliases and forbidden lifetime overlaps."""

import re
import sys
from pathlib import Path


def load_symbols(path: Path) -> dict[str, int]:
    symbols: dict[str, int] = {}
    pattern = re.compile(r"^([^:]+):\s+EQU\s+0x([0-9A-F]+)$", re.I)
    for line in path.read_text().splitlines():
        match = pattern.match(line.strip())
        if match:
            symbols[match.group(1)] = int(match.group(2), 16)
    return symbols


def span(address: int, size: int) -> range:
    return range(address, address + size)


def overlaps(left: range, right: range) -> bool:
    return left.start < right.stop and right.start < left.stop


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check_ram_aliases.py HOME.sym")
    symbols = load_symbols(Path(sys.argv[1]))

    # These command-phase buffers deliberately share TOKEN_BUF. Tokenization
    # has completed and MEM_LINE_STORE has copied its result before any of the
    # other three consumers become live.
    token = symbols["TOKEN_BUF"]
    for name in ("STATUS_BUF", "EDIT_LABEL_COPY", "MULTI_STMT_BUF"):
        assert symbols[name] == token, f"{name} no longer aliases TOKEN_BUF"

    edit = span(symbols["EDIT_LINE_BUF"], 128)
    status = span(symbols["STATUS_BUF"], 32)
    load_name = span(symbols["STORAGE_LOAD_NAME_BUF"], 10)
    string_pool = span(symbols["STR_FUNC_POOL"], 128)

    # STORAGE_LOAD redraws STATUS_BUF before comparing a named header.
    assert not overlaps(load_name, status), (
        "named LOAD filename overlaps progress-status redraw scratch"
    )
    # Static checking can evaluate string functions while the editor's raw,
    # uncommitted line remains live.
    assert not overlaps(string_pool, edit), (
        "string-function checker scratch overlaps the live edit line"
    )

    print("check_ram_aliases.py: intentional aliases and exclusions validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
