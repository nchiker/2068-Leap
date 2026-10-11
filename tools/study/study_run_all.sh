#!/usr/bin/env bash
# study_run_all.sh <worktree> <port> <outdir> [enhanced]
# Runs every focused study suite against the build in <worktree> (after `make build v2-packages`).
set -u
wt="$1"; port="$2"; out="$3"; enh="${4:-}"
mkdir -p "$out" "$out/state"
cd "$wt"
export TS2068_DEBUG_STATE_DIR="$out/state" TS2068_V2_PORT="$port"
run() { echo "===== $*"; timeout 5400 "$@" 2>&1 | cut -c1-260; echo "rc=${PIPESTATUS[0]}"; }
run python3 tools/study_break_matrix.py
run python3 tools/study_edit_preserve.py
run python3 tools/study_u6.py
run python3 tools/study_callfn.py
run python3 tools/study_d11_print.py
run python3 tools/study_d11_literals.py
run python3 tools/study_lang_hw.py
if [ -n "$enh" ]; then run python3 tools/study_eof_for.py; run python3 tools/study_lang_print.py; fi
export ORACLE_PROMOTE=1
run python3 tools/study_vm_oracle.py add 4000
run python3 tools/study_vm_oracle.py sub 4000
run python3 tools/study_vm_oracle.py mulop 4000
run python3 tools/study_vm_oracle.py mul 4000
run python3 tools/study_flicker.py --diff --json "$out/flicker.json"
echo "ALL DONE"
