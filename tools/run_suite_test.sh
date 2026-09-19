#!/usr/bin/env bash
# tools/run_suite_test.sh — inject one tests/<name>.txt program into the
# ordinary interactive ROM and report its border-color verdict, via
# ts2068-debug (ZRCP/ZEsarUX). Thin wrapper around
# tools/debug_suite_run.py for interactive single-fixture use; see that
# script's own module docstring for the full "why" (ported off Fuse/X11
# screenshots and the old poke-at-a-one-shot-breakpoint injection
# technique, 2026-09-19).
#
# Usage: tools/run_suite_test.sh <name>
#   reads   tests/<name>.txt
#   prints  "<name>: border=<0-7>"
#
# Same environment variables as before: RAM_EXTENSION_BIN,
# RAM_EXTENSION_CLEAR, RAM_EXTENSION_SEED_CACHE, RUN_STATE_TEST.
# (STACK_AUDIT is not yet ported -- see tools/run_stack_audit.sh.)
set -e
cd "$(dirname "$0")/.."

name="$1"
if [ -z "$name" ]; then
    echo "usage: $0 <name>  (reads tests/${name}.txt)" >&2
    exit 1
fi

if [ ! -f build/test_basic.bin ] || [ ! -f build/test_basic.sym ]; then
    echo "build/test_basic.bin or .sym missing -- run 'make build' first" >&2
    exit 1
fi

python3 tools/debug_suite_run.py "$name" --port "${TS2068_SUITE_PORT:-10060}"
