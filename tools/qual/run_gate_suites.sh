#!/usr/bin/env bash
# run_gate_suites.sh <build-dir> <base-port> <outdir>
# The project's own production suites (gate, Array Store gate, known defects, production checks,
# FILL checks) against one exported build, on private ports/state dirs (runs alongside others).
set -u
b="$1"; port="$2"; out="$3"; mkdir -p "$out"
# run from a frozen private copy: a later re-export of <build-dir> must not change the ROM under a run
rm -rf "$out/tree"; cp -a "$b" "$out/tree"; cat "$out/tree/QUAL_COMMIT" 2>/dev/null > "$out/commit.txt"
cd "$out/tree"
# as tools/run_v2_prod_tests.sh: the FILL checks read the SHAPES package symbols
sjasmplus --sym=build/v2_package_shapes.sym rom/v2_package_shapes.asm >/dev/null || exit 1
rm -f v2_package_shapes.bin
export V2_FILL_NO_REBUILD=1
suite() { # name port cmd...
  local name="$1" p="$2"; shift 2
  mkdir -p "$out/state-$name"
  TS2068_DEBUG_STATE_DIR="$out/state-$name" TS2068_V2_PORT="$p" timeout 7200 "$@" > "$out/$name.log" 2>&1
  echo "$name rc=$?" >> "$out/summary.txt"
  TS2068_DEBUG_STATE_DIR="$out/state-$name" ts2068-debug --json stop >/dev/null 2>&1
}
rm -f "$out/summary.txt"
suite gate $port python3 tools/v2_prod_regress.py &
suite arrays $((port+1)) python3 tools/v2_prod_arrays.py &
suite defects $((port+2)) python3 tools/v2_known_defects.py &
wait
suite prodchecks $((port+3)) python3 tools/v2_production_checks.py &
suite fill $((port+4)) python3 tools/v2_fill_check.py &
wait
for f in gate arrays defects prodchecks fill; do echo "== $f"; tail -3 "$out/$f.log"; done
cat "$out/summary.txt"
