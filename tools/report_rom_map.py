#!/usr/bin/env python3
"""Generate a top-level, byte-accurate ROM map from sjasmplus listings."""

import re
import sys
from pathlib import Path


INCLUDE_RE = re.compile(
    r'^\s*\d+\s+([0-9A-F]+)\s+INCLUDE\s+"((?:basic|kernel|rom)/[^"]+\.asm)"',
    re.I,
)
PAD_RE = re.compile(
    r"^\s*\d+\s+([0-9A-F]+).*?DS\s+\$[0-9A-F]+\s*-\s*\$", re.I
)


def listing_map(path: Path, origin: int, limit: int, prefixes: tuple[str, ...]):
    starts: list[tuple[int, str]] = []
    padding_start = None
    for line in path.read_text().splitlines():
        match = INCLUDE_RE.match(line)
        if match and match.group(2).startswith(prefixes):
            starts.append((int(match.group(1), 16), match.group(2)))
        pad = PAD_RE.match(line)
        if pad:
            padding_start = int(pad.group(1), 16)
    if padding_start is None:
        raise SystemExit(f"could not find final padding in {path}")
    starts = sorted(dict.fromkeys(starts))
    rows = []
    if not starts or starts[0][0] > origin:
        rows.append((origin, starts[0][0] if starts else padding_start, "ROM driver, vectors and tables"))
    for index, (start, name) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else padding_start
        rows.append((start, end, name))
    return rows, padding_start, limit - padding_start


def print_table(title: str, rows, origin: int, limit: int, used_end: int, free: int):
    print(f"## {title}\n")
    print("| Address range | Bytes | Share | Source |")
    print("|---|---:|---:|---|")
    capacity = limit - origin
    for start, end, name in rows:
        print(f"| `${start:04X}-${end - 1:04X}` | {end - start} | {(end-start)/capacity:5.1%} | `{name}` |")
    if free:
        print(f"| `${used_end:04X}-${limit - 1:04X}` | {free} | {free/capacity:5.1%} | **Unallocated padding** |")
    print(f"\nUsed: **{used_end-origin} / {capacity} bytes**; free: **{free} bytes**.\n")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: report_rom_map.py HOME.lst EXROM.lst", file=sys.stderr)
        return 2
    home, home_end, home_free = listing_map(
        Path(sys.argv[1]), 0x0000, 0x4000, ("basic/", "kernel/")
    )
    exrom, exrom_end, exrom_free = listing_map(
        Path(sys.argv[2]), 0xC000, 0xE000, ("rom/exrom_",)
    )
    print("# Generated ROM space map\n")
    print("Generated from sjasmplus listing addresses; module sizes include code and data.\n")
    print_table("HOME ROM", home, 0x0000, 0x4000, home_end, home_free)
    print_table("EXROM", exrom, 0xC000, 0xE000, exrom_end, exrom_free)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
