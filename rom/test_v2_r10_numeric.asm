; ============================================================================
; rom/test_v2_r10_numeric.asm — R10 correctness-fix regression test.
;
; Standalone ROM image exercising three R10 corrections to
; rom/exrom_v2_vm_core.asm (docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md
; matrix rows 6-8, all previously documented-and-deferred, not fixed
; before R10):
;
;   1. VAL() now parses a decimal point (BUILTIN_FN_VAL), matching the
;      compiler's own LEX_SCAN_NUMBER value/divisor scheme.
;   2. OP_DIV now catches a FLOAT-tagged zero divisor via the new shared
;      VM_FLOAT_TEST_ZERO helper (previously only an INT-tagged zero
;      divisor was caught).
;   3. The full relop set (OP_CMP_LT/LE/GT/GE/EQ/NE) now supports FLOAT
;      operands via the new shared VM_CMP_DISPATCH helper (previously
;      any FLOAT operand raised VM_ERR_FLOAT_NOT_IMPLEMENTED
;      unconditionally).
;
; Built on the shared production-shaped test harness (rom/
; test_v2_harness_home_head.inc/_tail.inc + rom/test_v2_harness_exrom.asm),
; DEFINE TEST_V2_NEEDS_CALC (the real calculator, needed for VAL's/OP_
; DIV's/the relops' float paths) alongside the usual TEST_V2_NEEDS_
; DECOMPILE.
;
; Source program compiled and executed:
;
;   A=VAL("3.14"):PRINT A>3:PRINT A<3.2:
;   B=VAL("-2.5"):PRINT B<-2:PRINT B>-3:
;   PRINT SQR(4)=2:
;   PRINT 1.5<2:PRINT 2<1.5:
;   C=1/VAL("0.0")
;
; The first seven PRINTs must all be TRUE except "PRINT 2<1.5" (the one
; deliberately-false case, proving direction correctness the same way
; rom/test_v2_relational.asm's own header explains) -- so VM_OUTPUT_ROW
; must be exactly 7 after them. The final statement divides by a FLOAT-
; tagged 0.0 (VAL("0.0") with a decimal point present, so it is FLOAT-
; tagged, not INT-tagged -- exercising the new zero-divisor path, not
; the pre-existing INT one) and must halt with VM_ERR_DIVIDE_BY_ZERO
; (error code 5), not silently produce a garbage result.
;
; Symbol declaration order (CSYM_FIND_OR_CREATE, first appearance):
;   0=A 1=B 2=C.
; ============================================================================

    DEFINE TEST_V2_NEEDS_DECOMPILE  ; needed only for DECOMP_END_ADDR's
                                      ; own EQU: COMPILE_PROGRAM writes
                                      ; it unconditionally (since R8.5),
                                      ; even though this test never calls
                                      ; DECOMPILE_PROGRAM itself
    DEFINE TEST_V2_NEEDS_CALC
    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"

SOURCE_TEXT:
    db "A=VAL(\"3.14\"):PRINT A>3:PRINT A<3.2:"
    db "B=VAL(\"-2.5\"):PRINT B<-2:PRINT B>-3:"
    db "PRINT SQR(4)=2:"
    db "PRINT 1.5<2:PRINT 2<1.5:"
    db "C=1/VAL(\"0.0\")", 0

; TEST_CUSTOM_MAIN -- TEST_V2_CUSTOM_CHECKS bypasses the harness's own
; default compile/run/check dispatch entirely (see rom/
; test_v2_harness_home_head.inc's own TEST_COLD_START: `jp
; TEST_CUSTOM_MAIN` when this is defined, not a checked call), so this
; routine must drive COMPILER_INIT/COMPILE_PROGRAM/VM_INIT/VM_RUN itself
; and land on TEST_PASS/TEST_FAIL directly -- same full-driver shape
; rom/test_v2_group6_math.asm's own TEST_CUSTOM_MAIN already
; establishes. Unlike that file, this test's own VM_RUN is EXPECTED to
; halt with a nonzero VM_ERROR_CODE (the final statement's deliberate
; FLOAT-zero divide), so the normal "VM_ERROR_CODE != 0 -> FAIL" check
; does not apply here -- VM_OUTPUT_ROW must be exactly 7 (the seven
; PRINTs before the divide) and VM_ERROR_CODE must be exactly 5
; (VM_ERR_DIVIDE_BY_ZERO) with VM_HALTED set -- not 0 (silently
; succeeded, meaning the FLOAT-zero-divisor gap is still open) and not
; some other error.
TEST_CUSTOM_MAIN:
    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN
    ld   a, (VM_OUTPUT_ROW)
    cp   7
    jp   nz, TEST_FAIL
    ld   a, (VM_ERROR_CODE)
    cp   5
    jp   nz, TEST_FAIL
    ld   a, (VM_HALTED)
    or   a
    jp   z, TEST_FAIL
    jp   TEST_PASS

; Test-only stubs: this file's own test program never exercises LPRINT/
; BEEP/SOUND/PAUSE, and never registers or calls a loadable extension.
BASIC_STMT_LPRINT_EXROM:
    ret
SOUND_BEEP:
    ret
SOUND_EXROM:
    or a
    ret
IO_READ_KEY:
    xor a
    ret
INT_GET_FRAMES:
    ld hl,0
    ret
EXT2_LOOKUP:
    scf
    ret
EXT2_SLOT_ADDR:
    ret
EXT_CALL_ARG0: equ $8B00
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00

GFX_CLS:
    ret
GFX_PAINT_ATTR:
    ret
GFX_SET_BORDER:
    ret
GFX_WRITE_PIXEL:
    ret
GFX_LINE:
    ret
GFX_PRINT_STRING_ATTR:
    ret
GFX_SCROLL_OUTPUT_UP:
    ret
GFX_SET_MODE:
    ret
GFX_SPRITE_CAPTURE:
    or a
    ret
GFX_SPRITE_DRAW:
    or a
    ret
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"
