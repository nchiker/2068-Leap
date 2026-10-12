#!/usr/bin/env python3
"""Replay a saved source-level Z80 state and write a JSON trace/result."""
import argparse
import hashlib
import json
import os

from sim import Halt, Interp, Program
from snapshot import capture_state, load_snapshot


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("assembly", help="assembly source parsed by z80sim")
    parser.add_argument("snapshot", help="versioned z80sim-state JSON input")
    parser.add_argument("-o", "--output", required=True, help="JSON run result path")
    parser.add_argument("--symbols", help="optional SjASMPlus .sym file for label annotations")
    parser.add_argument("--listing", help="optional SjASMPlus .lst file for exact source-line addresses")
    parser.add_argument("--max-steps", type=int, default=200000)
    parser.add_argument("--max-trace", type=int, default=5000)
    args = parser.parse_args(argv)
    if args.max_steps < 1:
        parser.error("--max-steps must be positive")
    if args.max_trace < 1:
        parser.error("--max-trace must be positive")
    for artifact_name, artifact_path in (("assembly", args.assembly), ("snapshot", args.snapshot),
                                         ("symbols", args.symbols), ("listing", args.listing)):
        if artifact_path is not None and not os.path.isfile(artifact_path):
            parser.error(f"{artifact_name} file not found: {artifact_path}")

    try:
        program = Program()
        program.load_file(args.assembly)
        symbol_info = None
        symbol_hash = None
        if args.symbols:
            symbol_info = program.load_symbols(args.symbols)
            symbol_hash = sha256_file(args.symbols)
        listing_info = None
        listing_hash = None
        if args.listing:
            listing_info = program.load_listing(args.listing)
            listing_hash = sha256_file(args.listing)

        sim, (scope, label), memory_ranges = load_snapshot(args.snapshot)
    except (ValueError, KeyError, OSError) as exc:
        parser.error(f"cannot load replay inputs: {exc}")
    interp = Interp(program, sim)
    interp.max_trace = args.max_trace
    outcome = "returned"
    halt_reason = None
    try:
        interp.run(scope, label, max_steps=args.max_steps)
    except Halt as exc:
        halt_reason = str(exc)
        if halt_reason.startswith("clean stop:"):
            outcome = "returned"
        elif halt_reason.startswith("exceeded max_steps"):
            outcome = "step_limit"
        else:
            outcome = "halted"

    trace = []
    for index, ((step_scope, step_label, mnemonic, operands, regs, flags), metadata) in enumerate(
            zip(interp.trace_log, interp.trace_metadata), 1):
        trace.append({
            "trace_index": index,
            "instruction": {
                "scope": step_scope,
                "label": step_label,
                "mnemonic": mnemonic,
                "operands": operands,
            },
            "source": metadata,
            "registers": regs,
            "flags": flags,
        })

    origin_paths = sorted({item["path"] for item in program.source_map if item.get("path")})
    origin_sources = []
    for source_path in origin_paths:
        if os.path.isfile(source_path):
            origin_sources.append({"path": source_path, "sha256": sha256_file(source_path), "status": "available"})
        else:
            origin_sources.append({"path": source_path, "sha256": None, "status": "missing"})

    result = {
        "format": "z80sim-run",
        "version": 1,
        "outcome": outcome,
        "halt_reason": halt_reason,
        "steps": interp.step_count,
        "trace_truncated": interp.trace_dropped > 0,
        "trace_dropped": interp.trace_dropped,
        "trace_limit": args.max_trace,
        "source": {
            "path": args.assembly,
            "sha256": sha256_file(args.assembly),
            "origin_files": origin_sources,
        },
        "symbols": ({
            "path": args.symbols,
            "sha256": symbol_hash,
            "freshness": "unverified against source; compare build inputs/revision before relying on addresses",
            **symbol_info,
        } if symbol_info is not None else {
            "status": "unavailable; pass --symbols to annotate labels with assembled addresses"
        }),
        "listing": ({
            "path": args.listing,
            "sha256": listing_hash,
            "freshness": "exact source-line text checked where mapped; full build/source freshness unverified",
            **listing_info,
        } if listing_info is not None else {
            "status": "unavailable; pass --listing to annotate exact source-line addresses"
        }),
        "initial_state_path": args.snapshot,
        "final_state": capture_state(sim, scope, label, memory_ranges),
        "trace": trace,
    }
    with open(args.output, "w", encoding="utf-8") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
    print(f"{outcome}: {interp.step_count} steps; wrote {os.path.abspath(args.output)}")
    return 0 if outcome == "returned" else 2


if __name__ == "__main__":
    raise SystemExit(main())
