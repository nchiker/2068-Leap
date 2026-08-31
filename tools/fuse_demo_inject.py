#!/usr/bin/env python3
"""
tools/fuse_demo_inject.py — generates a Fuse debugger script that
injects a demo BASIC program straight into RAM at rom/demo_inject.asm's
own INJECT_POINT breakpoint, then drops into the real interactive
editor (BASIC_COMMAND_LOOP) with it already loaded — LIST/RUN/edit all
work normally from there, exactly as if the program had been typed in
by hand.

WHY: same technique as tools/fuse_suite_inject.py (see that script's
and rom/demo_inject.asm's own headers for the full "why not bake it
into the ROM image" story), applied for demo/showcase purposes instead
of pass/fail regression testing — the harness never rebuilds per demo,
and there's no artificial size cap the way tools/fuse_load_inject.py's
own 255-byte limit is (an artifact of ITS verification harness's 8-bit
compare loop). Real ceiling is whatever fits in the dynamic pool
(PROG_AREA_START..VARS_START, currently up to 15,322 bytes of program
text before the program's own arrays/scalars start eating into the
same space at runtime).

Usage:
    python3 tools/fuse_demo_inject.py <program.txt> <out.dbg>

<program.txt>: same plain-text format the other fuse_*_inject.py tools
take (one BASIC statement per line, blank lines and ';;'-prefixed
lines skipped).

Output:
    <out.dbg> — pass to Fuse via --debugger-command "$(cat <out.dbg>)".
"""
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from preload_gen import encode_program  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
HARNESS_ASM = REPO_ROOT / "rom" / "demo_inject.asm"
HARNESS_SYM = REPO_ROOT / "rom" / "demo_inject.sym"

_SYMS = None


def harness_symbols():
    """Reads INJECT_POINT/PROG_AREA_START/PROG_END/VARS_START from the
    harness's own assembled --sym table — read live, not hardcoded,
    same reasoning tools/fuse_load_inject.py's read_equ and tools/
    fuse_suite_inject.py's harness_symbols already established.
    Assumes rom/demo_inject.asm has already been assembled with
    --sym=rom/demo_inject.sym (tools/run_demo.sh does this once, not
    per demo)."""
    global _SYMS
    if _SYMS is not None:
        return _SYMS
    if not HARNESS_SYM.exists():
        subprocess.run(
            ["sjasmplus", str(HARNESS_ASM), f"--sym={HARNESS_SYM}"],
            cwd=REPO_ROOT, check=True, capture_output=True, text=True,
        )
    symbols = {}
    pat = re.compile(r'^(\S+):\s+EQU\s+0x([0-9A-Fa-f]+)', re.MULTILINE)
    for m in pat.finditer(HARNESS_SYM.read_text()):
        symbols[m.group(1)] = int(m.group(2), 16)
    _SYMS = symbols
    return symbols


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    src_path, out_path = sys.argv[1], sys.argv[2]

    with open(src_path) as f:
        lines = [l.rstrip('\n') for l in f]
    lines = [l for l in lines if l.strip() and not l.strip().startswith(';;')]

    data = encode_program(lines)

    syms = harness_symbols()
    inject_point = syms['INJECT_POINT']
    prog_area_start = syms['PROG_AREA_START']
    prog_end_addr = syms['PROG_END']

    # VARS_START (the dynamic pool's own scalar high-water mark) is a
    # RUNTIME value, not a fixed constant — but at the fresh boot this
    # harness always starts from, it equals PROG_AREA_MAX, so that's
    # the real ceiling to check the injected program text against here.
    max_len = syms['PROG_AREA_MAX'] - prog_area_start
    if len(data) > max_len:
        raise ValueError(
            f"demo program too large ({len(data)} bytes, max {max_len} "
            f"— PROG_AREA_START to PROG_AREA_MAX): shorten it")

    prog_end_value = prog_area_start + len(data)

    pokes = [
        f"set 0x{prog_area_start + i:04x} {b}"
        for i, b in enumerate(data)
    ]
    pokes.append(f"set 0x{prog_end_addr:04x} {prog_end_value & 0xff}")
    pokes.append(f"set 0x{prog_end_addr + 1:04x} {(prog_end_value >> 8) & 0xff}")

    script = (
        f"breakpoint 0x{inject_point:04x}\n"
        f"commands 1\n"
        + "\n".join(pokes) + "\n"
        f"continue\n"
        f"end\n"
    )

    Path(out_path).write_text(script)
    print(f"Wrote {out_path} ({len(data)} program bytes, "
          f"breakpoint at 0x{inject_point:04x})")


if __name__ == "__main__":
    main()
