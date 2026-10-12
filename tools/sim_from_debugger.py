#!/usr/bin/env python3
"""Turn a live ts2068-debug session's state into a z80sim snapshot for source-level replay.

The two shared tools meet here: ts2068-debug (ZEsarUX, real ROM, real failure) captures the
registers and the memory ranges that matter; z80sim replays the routine's own source from that exact
state with per-instruction source-line tracing (tools/z80sim/replay_snapshot.py).

    ts2068-debug --json start --rom build/ts2068rom_zesarux.bin --symbols build/test_basic.sym
    ... reproduce the failure, stop at the routine's entry (break / run --until) ...
    python3 tools/sim_from_debugger.py --symbols build/test_basic.sym --entry MATH_UMUL16 \
        --range 0xF100:64 --out /tmp/case.json
    python3 tools/z80sim/extract_routine.py kernel/math/math.asm MATH_UMUL16 MATH_UDIV16 \
        --with-locations > /tmp/routine.asm
    python3 tools/z80sim/replay_snapshot.py /tmp/routine.asm /tmp/case.json \
        --symbols build/test_basic.sym --listing build/test_basic.lst -o /tmp/replay.json

The debugger is driven through its CLI (`ts2068-debug --json regs|mem`), the stable interface, so
TS2068_DEBUG_STATE_DIR selects the session exactly as it does for the debugger itself.

Limits (z80sim's, see tools/z80sim/README.md): the simulator keeps a logical stack, so the real stack
bytes are not replayed -- a HALT sentinel is pushed instead (SP in the snapshot is the debugger's SP minus 2) and the
routine's outermost RET ends the run. Alternate BC'/DE'/HL' are not modelled (AF' is). Only the memory ranges you name are captured.
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "z80sim"))

from sim import Z80Sim  # noqa: E402
from snapshot import capture_state  # noqa: E402

# Z80 F register bit -> z80sim flag name
FLAG_BITS = {"S": 0x80, "Z": 0x40, "H": 0x10, "PV": 0x04, "N": 0x02, "C": 0x01}


def apply_registers(sim, regs):
    """Load a ts2068-debug `regs` JSON ("registers": {...16-bit values...}) into a Z80Sim."""
    need = ("AF", "BC", "DE", "HL", "IX", "IY", "SP")
    missing = [r for r in need if r not in regs]
    if missing:
        raise ValueError(f"debugger registers missing {missing}: {sorted(regs)}")
    sim.regs["A"], f = regs["AF"] >> 8, regs["AF"] & 0xFF
    sim.regs["B"], sim.regs["C"] = regs["BC"] >> 8, regs["BC"] & 0xFF
    sim.regs["D"], sim.regs["E"] = regs["DE"] >> 8, regs["DE"] & 0xFF
    sim.regs["H"], sim.regs["L"] = regs["HL"] >> 8, regs["HL"] & 0xFF
    sim.regs["IX"], sim.regs["IY"], sim.regs["SP"] = regs["IX"], regs["IY"], regs["SP"]
    for name, bit in FLAG_BITS.items():
        sim.flags[name] = 1 if f & bit else 0
    if "AF'" in regs:
        sim.alt_a = regs["AF'"] >> 8
        for name, bit in FLAG_BITS.items():
            sim.alt_flags[name] = 1 if regs["AF'"] & bit else 0


def parse_range(text, symbols=None):
    """'ADDR:LEN' with ADDR numeric (0x..) or a symbol from --symbols -> (start, length)."""
    addr, _, length = text.partition(":")
    if not length:
        raise ValueError(f"range {text!r} must be ADDR:LEN")
    try:
        start = int(addr, 0)
    except ValueError:
        start = symbols.address_of(addr) if symbols else None
        if start is None:
            raise ValueError(f"unknown symbol {addr!r} in range {text!r} (pass --symbols)") from None
    return start, int(length, 0)


def build_state(regs, memory, entry_scope, entry_label):
    """regs: debugger registers dict; memory: [(start, bytes)]. Returns a z80sim-state dict."""
    sim = Z80Sim()
    apply_registers(sim, regs)
    for start, data in memory:
        sim.mem[start:start + len(data)] = data
    sim.push(("HALT", None))
    return capture_state(sim, entry_scope, entry_label, [(s, len(d)) for s, d in memory])


def _debugger(*args):
    r = subprocess.run(["ts2068-debug", "--json", *args], capture_output=True, text=True, timeout=120)
    try:
        out = json.loads(r.stdout)
    except ValueError:
        raise SystemExit(f"ts2068-debug {' '.join(args)} failed: {r.stderr.strip() or r.stdout.strip()}")
    if out.get("status") != "ok":
        raise SystemExit(f"ts2068-debug {' '.join(args)}: {out.get('error')}")
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--entry", required=True, help="global label of the routine to replay (the simulator's entry scope)")
    ap.add_argument("--label", default=None, help="local label inside --entry to start at (default: the global label)")
    ap.add_argument("--range", action="append", default=[], dest="ranges", metavar="ADDR:LEN",
                    help="memory to capture; ADDR numeric or a symbol (repeatable)")
    ap.add_argument("--symbols", default=None, help=".sym file, for symbol names in --range")
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)

    symbols = None
    if args.symbols:
        sys.path.insert(0, "")  # ts2068_debug is an installed package; nothing local needed
        from ts2068_debug.symbols import SymbolTable
        symbols = SymbolTable()
        symbols.load(args.symbols)
    try:
        ranges = [parse_range(r, symbols) for r in args.ranges]
    except ValueError as exc:
        ap.error(str(exc))
    regs = _debugger("regs")["registers"]
    memory = [(s, bytes.fromhex(_debugger("mem", str(s), str(n))["hex"])) for s, n in ranges]
    state = build_state(regs, memory, args.entry, args.label)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)
        fh.write("\n")
    print(f"wrote {args.out}: {args.entry}{args.label or ''} PC={regs.get('PC', 0):04X} "
          f"{len(memory)} memory range(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
