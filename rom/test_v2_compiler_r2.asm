; ============================================================================
; rom/test_v2_compiler_r2.asm — Architecture B, R2 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm AND R1's real
; rom/exrom_v2_vm_core.asm together — the actual "compile-then-execute
; round-trip" R2's own success gate requires, not a hand-assembled bytecode
; test like R1's milestone used (there was no compiler yet at that point).
; Follows this project's established isolated-module-test pattern (see
; rom/test_math.asm, tools/build_smoke_roms.sh). NOT wired into the
; production BASIC dispatch or the shipping EXROM build.
;
; Source program compiled and executed (real multi-character identifiers,
; per this milestone's own required verification — SCORE/TOTAL, not just
; single letters):
;
;   SCORE=3+4*2:TOTAL=SCORE+10:SCORE=SCORE+1
;
; Expected: SCORE=3+(4*2)=11 after statement 1, TOTAL=SCORE+10=21 after
; statement 2 (using SCORE's value at that point, 11 — also a real test
; that re-referencing an existing multi-character name resolves to the
; SAME compile-time symbol index rather than creating a duplicate), then
; SCORE=SCORE+1=12 after statement 3. Final: SCORE=12, TOTAL=21.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_compiler_r2.sym \
;       rom/test_v2_compiler_r2.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_compiler_r2_zesarux.bin
;   ts2068-debug run --max-instructions 500000
;   ts2068-debug timex   (border field)
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    call CHECK_RESULT
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; ============================================================================
; CHECK_RESULT — VM_ERROR_CODE must be 0; symbol 0 (SCORE) must be (INT) 12;
; symbol 1 (TOTAL) must be (INT) 21.
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_RESULT:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail
    ; SCORE (symbol 0): [tag][value_lo][value_hi] at SYMTAB_BASE+0
    ld   hl, SYMTAB_BASE
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .fail
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   hl, 12
    or   a
    sbc  hl, de
    jr   nz, .fail
    ; TOTAL (symbol 1): SYMTAB_BASE + 1*SYM_REC_LEN
    ld   hl, SYMTAB_BASE + SYM_REC_LEN
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .fail
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   hl, 21
    or   a
    sbc  hl, de
    ret  z
.fail:
    scf
    ret

SOURCE_TEXT:
    db "SCORE=3+4*2:TOTAL=SCORE+10:SCORE=SCORE+1", 0

; KTAB_CALC_EXIT_TRAMPOLINE -- required once rom/exrom_v2_vm_core.asm
; started calling into rom/exrom_calc.asm (R6's own float support);
; see rom/test_v2_compiler_r6.asm's own header for the full
; explanation. Added retroactively here (R8): this file predates R6/R7/
; R7.5, which each added more unconditional dependencies (calc, then
; graphics/sound/io/interrupt, then the R7.5 extension registry) that
; broke every earlier standalone test harness's own build without
; anyone updating them -- a real, confirmed regression-suite gap found
; while re-running the full V2 suite after an R8 lexer change.
KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_calc.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "rom/exrom_sound.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_compiler_r2.bin", $0000, $4000
