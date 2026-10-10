#!/usr/bin/env bash
# Build and execute the standalone V2 regression ROMs.
set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Post-R9 test-infrastructure milestone (docs/v2/POST_R9_TEST_INFRASTRUCTURE.
# md): the post-R9 semantic-completion milestone added roughly 850 bytes to
# rom/exrom_v2_compiler.asm + rom/exrom_v2_vm_core.asm (all real, necessary
# product code), plus further growth in rom/exrom_v2_decompiler.asm -- and
# every one of these tests used to bundle the full vm_core+compiler(+
# decompiler) into ONE flat, hard-capped 16K image, so 14 of them overflowed.
#
# Fix: these 14 tests are now built on a shared two-bank, production-shaped
# harness (rom/test_v2_harness_home_head.inc/_tail.inc + rom/
# test_v2_harness_exrom.asm) that mirrors the REAL rom/v2_home.asm/rom/
# v2_exrom.asm HOME+EXROM split and the real BANK_PAGE_EXROM_IN/OUT paging
# primitives, instead of one flat bank -- giving ~24K combined capacity
# instead of 16K. Each test's own HOME file supplies TEST_CHECK_RESULT (or
# TEST_V2_CUSTOM_CHECKS + TEST_CUSTOM_MAIN) and is concatenated with one of
# the two shared EXROM builds below, chosen by whether the test also defines
# TEST_V2_NEEDS_CALC (originally none of the 14 did -- all needed only
# TEST_V2_NEEDS_DECOMPILE, one shared EXROM build sufficed. R10 added the
# first CALC-needing member of this migrated set, r10_numeric, so there are
# now two shared EXROM variants instead of one).
#
# This is TEST scaffolding only -- it does not change BASIC semantics, and
# it is separate from rom/exrom_build.asm/rom/v2_exrom.asm, the real
# production EXROM build (see docs/v2/POST_R9_TEST_INFRASTRUCTURE.md for the
# full test-target classification: which targets are component tests vs
# genuine production-integration tests, and which are V1-derived vs V2).
# ---------------------------------------------------------------------------
migrated_names=(
    arrays block_if decompiler for_nested for_step group6_math input
    mode_module printer_module proc_recursion relational save_load
    sqr_decomp strfuncs shapes_circle graphics_module dynamic_arrays
    string_arrays ext_demo array_save_load case_insensitive
    identifier_length scalar_capacity32 recursion_depth12
    for_recursion_guard control_stack builtin_roundtrip identifier_toolong nesting_guard label_capacity
)

# Migrated tests that also need the real calculator (TEST_V2_NEEDS_CALC),
# paired with a separate shared EXROM build below instead of the plain
# TEST_V2_NEEDS_DECOMPILE-only one every other migrated test uses.
calc_migrated_names=(
    r10_numeric run_tables
)

# ---------------------------------------------------------------------------
# These two still fit the original flat-16K single-bank convention
# (concatenated with the real production build/exrom.bin purely to pad to
# ZEsarUX's expected memory size -- their own test bodies never call into
# the real EXROM's own code) and did not need migration. ext_demo was a
# third member of this group until the Dynamic Data Phase 2 string-array
# work grew vm_core+compiler enough to overflow its own flat image (190
# bytes over, zero TRIADD-relevant content to show for it) -- migrated
# onto the shared two-bank harness above, same as rom/test_v2_shapes_
# circle.asm/rom/test_v2_graphics_module.asm already were for the same
# EXT2-registry-needing reason.
# ---------------------------------------------------------------------------
legacy_names=(
    deffn vm_milestone01
    chunk_refill_boundary chunk_boundary_values for_first_token chunk_array_reads
)

out_dir=build/smoke/v2-standalone
mkdir -p "$out_dir"

# One shared EXROM build for every plain migrated test (needs only
# TEST_V2_NEEDS_DECOMPILE -- see header above), plus a second shared EXROM
# build for the calc_migrated_names subset (needs TEST_V2_NEEDS_CALC too).
sjasmplus -DTEST_V2_NEEDS_DECOMPILE rom/test_v2_harness_exrom.asm >/dev/null
mv test_v2_harness_exrom.bin "$out_dir/test_v2_harness_exrom.bin"

sjasmplus -DTEST_V2_NEEDS_DECOMPILE -DTEST_V2_NEEDS_CALC \
    rom/test_v2_harness_exrom.asm >/dev/null
mv test_v2_harness_exrom.bin "$out_dir/test_v2_harness_exrom_calc.bin"

for name in "${migrated_names[@]}"; do
    tools/sjasmplus_strict.sh \
        --sym="$out_dir/test_v2_${name}.sym" \
        "rom/test_v2_${name}.asm"
    mv "test_v2_harness_home.bin" "$out_dir/test_v2_${name}_home.bin"
    cat "$out_dir/test_v2_${name}_home.bin" "$out_dir/test_v2_harness_exrom.bin" \
        > "$out_dir/test_v2_${name}_zesarux.bin"
done

for name in "${calc_migrated_names[@]}"; do
    tools/sjasmplus_strict.sh \
        --sym="$out_dir/test_v2_${name}.sym" \
        "rom/test_v2_${name}.asm"
    mv "test_v2_harness_home.bin" "$out_dir/test_v2_${name}_home.bin"
    cat "$out_dir/test_v2_${name}_home.bin" "$out_dir/test_v2_harness_exrom_calc.bin" \
        > "$out_dir/test_v2_${name}_zesarux.bin"
done

for name in "${legacy_names[@]}"; do
    tools/sjasmplus_strict.sh \
        --sym="$out_dir/test_v2_${name}.sym" \
        "rom/test_v2_${name}.asm"
    mv "test_v2_${name}.bin" "$out_dir/test_v2_${name}.bin"
    cat "$out_dir/test_v2_${name}.bin" build/exrom.bin \
        > "$out_dir/test_v2_${name}_zesarux.bin"
done

names=("${migrated_names[@]}" "${calc_migrated_names[@]}" "${legacy_names[@]}")

state_dir="$(mktemp -d)"
export TS2068_DEBUG_STATE_DIR="$state_dir"
port="${TS2068_V2_TEST_PORT:-10220}"
cleanup() {
    ts2068-debug --json stop >/dev/null 2>&1 || true
    rm -rf "$state_dir"
}
trap cleanup EXIT

pass=0
for name in "${names[@]}"; do
    ts2068-debug --json stop >/dev/null 2>&1 || true
    ts2068-debug --json start \
        --rom "$out_dir/test_v2_${name}_zesarux.bin" --port "$port" >/dev/null
    ts2068-debug --json run --max-instructions 3000000 >/dev/null
    border="$(ts2068-debug --json timex | python3 -c \
        'import json,sys; print(json.load(sys.stdin).get("border"))')"
    if [ "$border" != 4 ]; then
        echo "${name}: border=${border} -> FAIL" >&2
        exit 1
    fi
    echo "${name}: border=${border} -> PASS"
    pass=$((pass + 1))
done

echo "V2 standalone: ${pass}/${#names[@]} PASS (component tests -- see docs/v2/POST_R9_TEST_INFRASTRUCTURE.md; these do NOT boot the real production EXROM build)"
