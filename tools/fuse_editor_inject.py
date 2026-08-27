#!/usr/bin/env python3
"""Generate the Fuse debugger script for rom/test_editor_auto.asm."""

import re
import sys
from pathlib import Path


def symbols(path):
    pattern = re.compile(r"^(\S+):\s+EQU\s+0x([0-9A-Fa-f]+)", re.MULTILINE)
    return {m.group(1): int(m.group(2), 16) for m in pattern.finditer(path.read_text())}


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: fuse_editor_inject.py <harness.sym> <out.dbg>")
    table = symbols(Path(sys.argv[1]))
    inject = table["INJECT_POINT"]
    queue = table["TEST_KEY_QUEUE"]
    queue_pos = table["TEST_QUEUE_POS"]
    verified = table["TEST_VERIFIED_FLAG"]
    last_key = table["KBD_LASTK"]
    keys = [ord("A")] * 33 + [0]
    values = [(queue + i, value) for i, value in enumerate(keys)]
    values += [
        (queue_pos, queue & 0xFF),
        (queue_pos + 1, queue >> 8),
        (verified, 0),
        (last_key, 0),
        (last_key + 1, 0),
    ]
    pokes = "\n".join(f"set 0x{address:04x} {value}" for address, value in values)
    Path(sys.argv[2]).write_text(
        f"breakpoint 0x{inject:04x}\ncommands 1\n{pokes}\ncontinue\nend\n"
    )
    print(f"Wrote {sys.argv[2]} ({len(keys)} queue bytes)")


if __name__ == "__main__":
    main()
