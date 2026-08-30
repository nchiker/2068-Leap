#!/usr/bin/env python3
"""Generate the Fuse debugger script for rom/test_editor_auto.asm."""

import re
import sys
from pathlib import Path


def symbols(path):
    pattern = re.compile(r"^(\S+):\s+EQU\s+0x([0-9A-Fa-f]+)", re.MULTILINE)
    return {m.group(1): int(m.group(2), 16) for m in pattern.finditer(path.read_text())}


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: fuse_editor_inject.py <harness.sym> <out.dbg> <wrap|insert>")
    table = symbols(Path(sys.argv[1]))
    inject = table["INJECT_POINT"]
    queue = table["TEST_KEY_QUEUE"]
    queue_pos = table["TEST_QUEUE_POS"]
    verified = table["TEST_VERIFIED_FLAG"]
    test_case = table["TEST_CASE"]
    settle = table["TEST_SETTLE_COUNT"]
    last_key = table["KBD_LASTK"]
    extra_values = []
    case = sys.argv[3]
    if case == "wrap":
        keys = [ord("A")] * 33 + [0]
        case_id = 0
    elif case == "insert":
        # Preload two committed statement records after MEM_INIT, avoiding
        # the intentional Enter/new-session race described by the harness.
        start = table["PROG_AREA_START"]
        prog_end_var = table["PROG_END"]
        records = []
        for content in (b"REM test\r", b'PRINT "hello"\r'):
            records += [len(content) & 0xFF, len(content) >> 8, *content]
        extra_values = [(start + i, value) for i, value in enumerate(records)]
        end = start + len(records)
        extra_values += [(prog_end_var, end & 0xFF), (prog_end_var + 1, end >> 8)]
        keys = [0x03, 0x0B, 0]  # KEY_CURSOR_UP, KEY_INSERT_LINE
        case_id = 1
    else:
        raise SystemExit(f"unknown editor test case: {case}")
    values = [(queue + i, value) for i, value in enumerate(keys)]
    values += extra_values + [
        (queue_pos, queue & 0xFF),
        (queue_pos + 1, queue >> 8),
        (verified, 0),
        (test_case, case_id),
        (settle, 0),
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
