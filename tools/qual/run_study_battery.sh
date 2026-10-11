#!/usr/bin/env bash
# run_study_battery.sh <build-export> <base-port> <outdir> -- re-run the cost study's own prototype
# tools (tools/study_*.py present in that export) on a FROZEN copy of the export, one emulator per
# tool (ports base..base+N), logs in <outdir>/<tool>.log, rc per tool in <outdir>/summary.txt.
# Example: tools/qual/run_study_battery.sh ~/2068-Leap-study/qual-builds/enhanced 10800 ~/2068-Leap-study/qual-runs/a3-enhanced
set -u
b="$1"; port="$2"; out="$3"; mkdir -p "$out"
rm -rf "$out/tree"; cp -a "$b" "$out/tree"; cat "$out/tree/QUAL_COMMIT" 2>/dev/null > "$out/commit.txt"
cd "$out/tree"
sjasmplus --sym=build/v2_package_shapes.sym rom/v2_package_shapes.asm >/dev/null || exit 1
rm -f v2_package_shapes.bin
export V2_FILL_NO_REBUILD=1
rm -f "$out/summary.txt"
one() { # name port cmd...
  local name="$1" p="$2"; shift 2
  mkdir -p "$out/state-$name"
  TS2068_DEBUG_STATE_DIR="$out/state-$name" TS2068_V2_PORT="$p" timeout 5400 "$@" > "$out/$name.log" 2>&1
  echo "$name rc=$?" >> "$out/summary.txt"
  TS2068_DEBUG_STATE_DIR="$out/state-$name" ts2068-debug --json stop >/dev/null 2>&1
}
i=0
for t in bare_ident callfn d11_literals d11_print eof_for lang_hw lang_print u6 edit_preserve break_matrix fill_break; do
  [ -f "tools/study_$t.py" ] || continue
  one "$t" $((port + i)) python3 "tools/study_$t.py" &
  i=$((i + 1))
  if [ $((i % 4)) -eq 0 ]; then wait; fi
done
wait
[ -f tools/study_flicker.py ] && one flicker $((port + i)) python3 tools/study_flicker.py --diff --json "$out/flicker.json"
i=$((i + 1))
if [ -f tools/study_vm_oracle.py ]; then
  # the oracle checks error 67 on overflow unless ORACLE_PROMOTE=1 (the D11 promotion builds, marked by
  # FLOAT_BIG_TO_STRING); without it every overflow pair of a promotion build is reported as a mismatch
  grep -q '^FLOAT_BIG_TO_STRING:' build/exrom.sym && export ORACLE_PROMOTE=1
  for m in mul add sub mulop; do one "vm_oracle_$m" $((port + i)) python3 tools/study_vm_oracle.py "$m" 3000 & i=$((i + 1)); done
  wait
fi
for f in "$out"/*.log; do echo "== $(basename "$f")"; tail -2 "$f"; done
cat "$out/summary.txt"
