#!/usr/bin/env python3
"""
tools/fuse_suite_inject.py — generates a Fuse debugger script that
injects a regression-suite test program straight into RAM at
rom/test_suite_inject.asm's own INJECT_POINT breakpoint, instead of
preload_gen.py's --autorun approach of baking the encoded program into
the ROM image as a PRELOAD_DATA block.

WHY (2026-08-23): after the Phase 4 dynamic-scalar-pool migration (see
docs/programmers_reference.md), individual test_suite_*.asm builds ran
83-113 bytes over Home ROM's 16K budget even though basic.asm itself
still fits rom/test_basic.asm exactly — the PRELOAD_DATA payload itself
(the raw encoded test program, sitting INSIDE the same ROM image as all
of basic.asm) was the actual cost, not the harness glue code around it.
tools/fuse_load_inject.py already proved the fix for SAVE/LOAD
specifically: Fuse's --debugger-command can poke arbitrary bytes into
RAM at a breakpoint with zero ROM changes. This applies the same
technique to the whole regression suite.

Unlike fuse_load_inject.py's LOAD/SAVE short-circuit (which has to fake
a routine's own successful-return contract — carry/registers/sysvars —
since it's skipping a REAL call's body), this is simpler and safer:
INJECT_POINT (rom/test_suite_inject.asm) is a plain label sitting right
before a REAL `call BASIC_RUN`, reached only after MEM_INIT/KBD_ISR_
INIT/EI have already run for real. The breakpoint only ever pokes DATA
at a natural pause point — PROG_AREA_START (the test program's encoded
bytes) and PROG_END (the pointer just past them) — then lets execution
resume normally into that real, properly stack-balanced call. No PC
redirection, no stack surgery, nothing to get subtly wrong.

Since nothing test-specific is baked into test_suite_inject.asm, it
never needs rebuilding per test — build test_suite_inject.bin ONCE
(tools/run_suite_test.sh does this), reuse it for every fixture; only
the tiny .dbg script this generates changes per test.

Usage:
    python3 tools/fuse_suite_inject.py <program.txt> <out.dbg>

<program.txt>: same plain-text format preload_gen.py/fuse_load_inject.py
take (one BASIC statement per line, blank lines and ';;'-prefixed lines
skipped). `@SYMBOL@` placeholders are replaced with the current decimal
value from the harness symbol table before encoding, so tests can inspect
sysvars without freezing their addresses into the fixture.

Output:
    <out.dbg> — pass to Fuse via --debugger-command "$(cat <out.dbg>)".
"""
import re
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from preload_gen import encode_program  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
HARNESS_ASM = REPO_ROOT / "rom" / "test_suite_inject.asm"
HARNESS_SYM = REPO_ROOT / "rom" / (
    "test_stack_audit.sym" if os.environ.get("STACK_AUDIT") else
    "test_extension_clear_inject.sym" if os.environ.get("RAM_EXTENSION_CLEAR") else
    "test_extension_inject.sym" if os.environ.get("RAM_EXTENSION_BIN") else
    "test_suite_inject.sym"
)

_SYMS = None


def harness_symbols():
    """Reads INJECT_POINT/PROG_AREA_START/PROG_END from the harness's
    own assembled --sym table — read live, not hardcoded, same "a
    future renumbering can't leave this silently poking the wrong
    address" reasoning tools/fuse_load_inject.py's read_equ already
    established. Assumes rom/test_suite_inject.asm has already been
    assembled with --sym=rom/test_suite_inject.sym (tools/
    run_suite_test.sh does this once, not per test)."""
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


def expand_symbols(line, symbols):
    """Replace @NAME@ with the live assembler value in decimal form."""
    def replace(match):
        name = match.group(1)
        if name not in symbols:
            raise ValueError(f"unknown fixture symbol @{name}@")
        return str(symbols[name])

    return re.sub(r"@([A-Za-z_][A-Za-z0-9_]*)@", replace, line)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    src_path, out_path = sys.argv[1], sys.argv[2]

    with open(src_path) as f:
        lines = [l.rstrip('\n') for l in f]
    lines = [l for l in lines if l.strip() and not l.strip().startswith(';;')]

    syms = harness_symbols()
    lines = [expand_symbols(line, syms) for line in lines]
    data = encode_program(lines)

    inject_point = syms['INJECT_POINT']
    prog_area_start = syms['PROG_AREA_START']
    prog_end_addr = syms['PROG_END']

    prog_end_value = prog_area_start + len(data)

    pokes = [
        f"set 0x{prog_area_start + i:04x} {b}"
        for i, b in enumerate(data)
    ]
    pokes.append(f"set 0x{prog_end_addr:04x} {prog_end_value & 0xff}")
    pokes.append(f"set 0x{prog_end_addr + 1:04x} {(prog_end_value >> 8) & 0xff}")

    module_path = os.environ.get("RAM_EXTENSION_BIN")
    if module_path:
        module = Path(module_path).read_bytes()
        module_base = syms['EXTENSION_MODULE_BASE']
        module_limit = syms['EXTENSION_MODULE_LIMIT']
        if module_base + len(module) > module_limit:
            raise ValueError("RAM extension exceeds reserved module window")
        pokes.extend(
            f"set 0x{module_base + i:04x} {b}"
            for i, b in enumerate(module)
        )
        if os.environ.get("RAM_EXTENSION_SEED_CACHE"):
            pokes.append(f"set 0x{syms['STATUS_CHECK_VALID']:04x} 1")

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
