#!/usr/bin/env python3
"""
tools/debug_suite_run.py — inject one tests/<name>.txt program into the
reusable rom/test_suite_inject.bin harness (or its RAM_EXTENSION_BIN/
RUN_STATE_TEST variants) and report its border-color verdict, via
ts2068-debug (ZRCP/ZEsarUX) instead of Fuse/X11.

This is the ORIGINAL injection technique (tools/fuse_suite_inject.py's:
poke the encoded program directly into PROG_AREA_START/PROG_END at the
harness's one-shot INJECT_POINT breakpoint, right before its own
`call BASIC_RUN`), ported to ts2068-debug rather than reinvented --
after an earlier attempt in this same session to simulate a real user
TYPING the program through the ordinary interactive editor turned out
to be unnecessary. That detour existed only because ts2068-debug's
breakpoint arming reliably raced past a one-shot target early in a
short, linear boot sequence -- confirmed root-caused and FIXED at the
source in ts2068-debug itself (reset_to_known_state(), 2026-09-19; see
~/ts2068-debug/skill/references/gotchas.md "Reset does not mean what it
sounds like"). With that fixed, the original poke-based design is
simply correct again, and it is both simpler and faster than typing:
no keyboard-scan timing, no per-line whole-program-checker cost, no
editor state to worry about between fixtures.

Confirmed live, repeatedly, in the same long-lived ZEsarUX session
(no cross-fixture contamination): each fixture's own encoded program
completely overwrites PROG_AREA_START/PROG_END, and `BASIC_RUN` itself
(called fresh by the harness after every reset_to_known_state() +
re-armed breakpoint) reinitializes runtime state the same way a real
interactive RUN does.

Usage:
    python3 tools/debug_suite_run.py <name> [--port PORT]
    reads   tests/<name>.txt
    prints  "<name>: border=<0-7>" to stdout

Same environment variables as before: RAM_EXTENSION_BIN,
RAM_EXTENSION_CLEAR, RAM_EXTENSION_SEED_CACHE, RUN_STATE_TEST.
(STACK_AUDIT is not yet ported -- see tools/run_stack_audit.sh.)
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

MAX_INSTRUCTIONS_TO_INJECT_POINT = 2_000_000
MAX_INSTRUCTIONS_AFTER_INJECT = 2_000_000

_SYMS_CACHE = {}


def harness_symbols(sym_path):
    """Reads NAME: EQU 0xHHHH pairs from an assembled .sym file. Cached
    per path since the same harness variant is reused across many
    fixtures in one run."""
    if sym_path not in _SYMS_CACHE:
        symbols = {}
        pat = re.compile(r'^(\S+):\s+EQU\s+0x([0-9A-Fa-f]+)', re.MULTILINE)
        for m in pat.finditer(Path(sym_path).read_text()):
            symbols[m.group(1)] = int(m.group(2), 16)
        _SYMS_CACHE[sym_path] = symbols
    return _SYMS_CACHE[sym_path]


def expand_symbols(line, symbols):
    def replace(match):
        name = match.group(1)
        if name not in symbols:
            raise ValueError(f"unknown fixture symbol @{name}@")
        return str(symbols[name])
    return re.sub(r"@([A-Za-z_][A-Za-z0-9_]*)@", replace, line)


def encode_program(lines):
    """[len:2][content][$0D] concatenated format -- this project's own,
    unchanged from tools/preload_gen.py's encode_program()."""
    out = bytearray()
    for line in lines:
        content = line.encode("ascii")
        length = len(content) + 1
        out += bytes([length & 0xFF, (length >> 8) & 0xFF])
        out += content
        out += b"\x0D"
    return bytes(out)


def harness_for(name):
    """Returns (home_rom_relpath, sym_relpath) for a fixture name,
    matching the old tools/fuse_suite_inject.py's own selection logic."""
    if os.environ.get("RUN_STATE_TEST"):
        return "test_run_state_inject.bin", "rom/test_run_state_inject.sym"
    if os.environ.get("RAM_EXTENSION_BIN"):
        if os.environ.get("RAM_EXTENSION_CLEAR"):
            return "test_extension_clear_inject.bin", "rom/test_extension_clear_inject.sym"
        return "test_extension_inject.bin", "rom/test_extension_inject.sym"
    return "test_suite_inject.bin", "rom/test_suite_inject.sym"


def run_debug(*args, allow_fail=False):
    cmd = ["ts2068-debug", "--json", *args]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        if allow_fail:
            return {}
        raise RuntimeError(f"ts2068-debug {' '.join(args)} failed: {result.stderr.strip()}")
    text = result.stdout.strip()
    return json.loads(text) if text else {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("name")
    ap.add_argument("--port", type=int, default=10060)
    args = ap.parse_args()
    name = args.name

    src_path = REPO_ROOT / "tests" / f"{name}.txt"
    lines = [l.rstrip("\n") for l in src_path.read_text().splitlines()]
    lines = [l for l in lines if l.strip() and not l.strip().startswith(";;")]

    home_rom, sym_path = harness_for(name)
    syms = harness_symbols(REPO_ROOT / sym_path)
    lines = [expand_symbols(line, syms) for line in lines]
    data = encode_program(lines)

    prog_area_start = syms["PROG_AREA_START"]
    prog_end_addr = syms["PROG_END"]
    prog_end_value = prog_area_start + len(data)

    combined = REPO_ROOT / "build" / f"suite_{name}_zesarux.bin"
    combined.write_bytes((REPO_ROOT / home_rom).read_bytes() + (REPO_ROOT / "exrom.bin").read_bytes())

    port = str(args.port)
    state_dir = tempfile.mkdtemp(prefix="ts2068_suite_")
    os.environ["TS2068_DEBUG_STATE_DIR"] = state_dir

    run_debug("stop", allow_fail=True)
    border = None
    try:
        run_debug("start", "--rom", str(combined), "--port", port, "--symbols", str(REPO_ROOT / sym_path))
        run_debug("reset-known-state")
        run_debug("break", "INJECT_POINT")
        run_debug("run", "--max-instructions", str(MAX_INSTRUCTIONS_TO_INJECT_POINT))

        def poke(addr, byte_list):
            if byte_list:
                run_debug("mem-write", f"0x{addr:04x}", "".join(f"{b:02X}" for b in byte_list))

        poke(prog_area_start, list(data))
        poke(prog_end_addr, [prog_end_value & 0xFF, (prog_end_value >> 8) & 0xFF])

        module_path = os.environ.get("RAM_EXTENSION_BIN")
        if module_path:
            module = Path(module_path).read_bytes()
            module_base = syms["EXTENSION_MODULE_BASE"]
            module_limit = syms["EXTENSION_MODULE_LIMIT"]
            if module_base + len(module) > module_limit:
                raise ValueError("RAM extension exceeds reserved module window")
            poke(module_base, list(module))
            if os.environ.get("RAM_EXTENSION_SEED_CACHE"):
                poke(syms["STATUS_CHECK_VALID"], [1])

        run_debug("run", "--max-instructions", str(MAX_INSTRUCTIONS_AFTER_INJECT))
        timex = run_debug("timex")
        border = timex.get("border")
    finally:
        run_debug("stop", allow_fail=True)
        import shutil
        shutil.rmtree(state_dir, ignore_errors=True)
        combined.unlink(missing_ok=True)

    print(f"{name}: border={border}")
    return border


if __name__ == "__main__":
    b = main()
    sys.exit(0 if b is not None else 1)
