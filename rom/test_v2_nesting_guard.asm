; ============================================================================
; rom/test_v2_nesting_guard.asm -- R10.7 P0 regression test.
;
; DEFECT: the compiler recurses on the Z80 stack (parentheses, IF blocks)
; with no guard, so a deeply nested program could run SP down into the
; package window at $F400-$F7FF. FIX: COMPILE_EXPR and COMPILE_STATEMENT_LIST
; call COMPILE_STACK_CHECK; below V2_COMPILE_STACK_FLOOR ($FA00) it raises
; error 60 and the caller returns without recursing; COMPILE_RAISE_ERROR keeps
; the FIRST error.
;
; TEST 1: 40 nested parentheses (well within the guard, ~560 bytes) compile
;   and run: X == 1, no error. The guard must not false-trigger.
; TEST 2: 400 nested parentheses must compile to error 60 (not a crash, not
;   a different cascade error), SP must be exactly balanced afterwards, and
;   nothing at or above the package window base was disturbed (a canary
;   byte placed at $F7FF below the machine stack is intact).
; TEST 3: after the failure a normal program compiles and runs (the compiler
;   recovers; no state leaked).
; ============================================================================
    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

DECOMP_END_ADDR: equ $9900

; COMPILE_SRC: HL = source text. Resets the compiler and compiles it.
; Out: A = COMPILE_ERROR_CODE (Z if none).
COMPILE_SRC:
    push hl
    ld   hl, PROG_AREA_START
    ld   (PROG_END), hl
    ld   (ARRAYS_END), hl
    ld   hl, V2_SOURCE_END
    ld   (VARS_START), hl
    call COMPILER_INIT
    pop  hl
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    or   a
    ret

RUN_PROGRAM:
    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    jp   VM_RUN

CANARY EQU $F7FF

TEST_CUSTOM_MAIN:
    ld   hl, SRC_OK40
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    TSYM_LD16 1  ; X = symbol 0
    ld   de, 1
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL

    ld   a, $A5
    ld   (CANARY), a
    ld   (SAVED_SP), sp
    ld   hl, SRC_DEEP
    call COMPILE_SRC
    cp   60
    jp   nz, TEST_FAIL
    ld   (AFTER_SP), sp
    ld   hl, (SAVED_SP)
    ld   de, (AFTER_SP)
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL
    ld   a, (CANARY)
    cp   $A5
    jp   nz, TEST_FAIL

    ld   hl, SRC_AFTER
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    TSYM_LD16 1
    ld   de, 7
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL
    jp   TEST_PASS

SAVED_SP: dw 0
AFTER_SP: dw 0
SRC_AFTER: db "Y=7", 0
SRC_OK40:  db "X=((((((((((((((((((((((((((((((((((((((((1))))))))))))))))))))))))))))))))))))))))", 0
SRC_DEEP:
    db "X="
    DUP 400
    db "("
    EDUP
    db "1"
    DUP 400
    db ")"
    EDUP
    db 0

; Test-only stubs (same discipline as rom/test_v2_scalar_capacity32.asm).
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
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"
