; ============================================================================
; rom/test_v2_compiler_r3.asm — Architecture B, R3 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's R3 additions
; (GOTO, IF...THEN GOTO, FOR/NEXT, labels, forward-reference fixups)
; together with R1's real rom/exrom_v2_vm_core.asm — a real, nontrivial,
; BASIC-shaped program, compiled and executed for real, per
; docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R3 success gate. NOT
; wired into the production BASIC dispatch or the shipping EXROM build.
;
; Source program compiled and executed:
;
;   TOTAL=0
;   COUNT=1
;   BOGUS=0
;   LOOP:
;   TOTAL=TOTAL+COUNT
;   COUNT=COUNT+1
;   IF COUNT<6 THEN GOTO LOOP
;   SQUARE=0
;   FOR I=1 TO 3
;   SQUARE=SQUARE+I*I
;   NEXT I
;   GOTO SKIP
;   BOGUS=999
;   SKIP:
;   RESULT=TOTAL+SQUARE
;
; Exercises: a BACKWARD-referenced GOTO inside a real IF...THEN GOTO
; condition (LOOP is defined before the GOTO that targets it — resolved
; immediately, no fixup needed); a FORWARD-referenced unconditional GOTO
; (SKIP is defined AFTER the GOTO that targets it — genuinely tests
; RESOLVE_ALL_FIXUPS' forward-reference patching, the one path Milestone
; 01/R1/R2 never needed); a real FOR/NEXT loop; and a real negative test
; that the GOTO actually skips its target statement (BOGUS stays 0, not
; 999) rather than merely "not crashing."
;
; Hand-computed expected results:
;   TOTAL:  0+1=1, +2=3, +3=6, +4=10, +5=15  (COUNT reaches 6, loop exits) -> 15
;   COUNT:  6
;   BOGUS:  0 (the GOTO must skip "BOGUS=999")
;   SQUARE: 0+1*1=1, +2*2=5, +3*3=14 -> 14
;   I:      4 (one past the FOR loop's limit of 3)
;   RESULT: TOTAL+SQUARE = 15+14 = 29
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_compiler_r3.sym \
;       rom/test_v2_compiler_r3.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_compiler_r3_zesarux.bin
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
; CHECK_RESULT — VM_ERROR_CODE must be 0. Symbol declaration order in the
; source (each is [tag][value_lo][value_hi] at SYMTAB_BASE + index*3):
;   0=TOTAL(15) 1=COUNT(6) 2=BOGUS(0) 3=SQUARE(14) 4=I(4) 5=RESULT(29)
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_RESULT:
    ld   a, (VM_ERROR_CODE)
    or   a
    jr   nz, .fail
    ld   hl, SYMTAB_BASE + 0*SYM_REC_LEN
    ld   de, 15
    call .check_one           ; TOTAL
    jr   c, .fail
    ld   hl, SYMTAB_BASE + 2*SYM_REC_LEN
    ld   de, 0
    call .check_one           ; BOGUS -- the real GOTO-skip negative test
    jr   c, .fail
    ld   hl, SYMTAB_BASE + 3*SYM_REC_LEN
    ld   de, 14
    call .check_one           ; SQUARE
    jr   c, .fail
    ld   hl, SYMTAB_BASE + 5*SYM_REC_LEN
    ld   de, 29
    call .check_one           ; RESULT
    ret
.fail:
    scf
    ret
; .check_one — input: HL=record address, DE=expected value.
; Out: carry clear=pass, carry set=fail.
.check_one:
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .co_fail
    inc  hl
    push de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl               ; HL = actual value
    pop  de                    ; DE = expected value (restored)
    or   a
    sbc  hl, de
    ret  z
.co_fail:
    scf
    ret

SOURCE_TEXT:
    db "TOTAL=0:COUNT=1:BOGUS=0:LOOP:TOTAL=TOTAL+COUNT:COUNT=COUNT+1:"
    db "IF COUNT<6 THEN GOTO LOOP:SQUARE=0:FOR I=1 TO 3:"
    db "SQUARE=SQUARE+I*I:NEXT I:GOTO SKIP:BOGUS=999:SKIP:"
    db "RESULT=TOTAL+SQUARE", 0

; KTAB_CALC_EXIT_TRAMPOLINE -- required once rom/exrom_v2_vm_core.asm
; started calling into rom/exrom_calc.asm (R6's own float support);
; see rom/test_v2_compiler_r6.asm's own header for the full
; explanation. Added retroactively here (R8): this file predates R6/R7/
; R7.5, which each added more unconditional dependencies (calc, then
; graphics/sound/io/interrupt, then the R7.5 extension registry) that
; broke every earlier standalone test harness's own build without
; anyone updating them -- a real, confirmed regression-suite gap found
; while re-running the full V2 suite after an R8 lexer change.
; Test-only stub: rom/exrom_v2_vm_core.asm's own OP_LPRINT_NUM/STR
; reference the real rom/exrom_printer.asm's BASIC_STMT_LPRINT_EXROM
; unconditionally, but pulling in that whole (real-ZX-printer-
; hardware-facing, ~300-line) file pushed this standalone flat 16K
; test image over budget with no LPRINT coverage to show for it (this
; file's own test program never calls LPRINT). A dedicated PRINT/
; LPRINT test (rom/test_v2_print.asm) includes the real file and
; genuinely exercises it; every other test stubs it, same discipline
; as this file's own existing KTAB_CALC_EXIT_TRAMPOLINE stub just below.
BASIC_STMT_LPRINT_EXROM:
    ret

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
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_compiler_r3.bin", $0000, $4000
