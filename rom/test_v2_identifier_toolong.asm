; ============================================================================
; rom/test_v2_identifier_toolong.asm -- R10.7 P0 regression test.
;
; DEFECT: identifiers were silently truncated to 8 characters, so two
; distinct long names with the same first 8 characters merged into ONE
; variable (variable1 = 5 : variable2 = 9 : total = variable1 + variable2
; gave 18, not 14). Approved product rule: never silently merge distinct
; identifiers; an over-long name is an explicit compile error (code 61).
; (The limit is IDENT_MAX_LEN = 31 since P2; it was 8 before. P0 made the
; truncation an error; P2 raised the limit so ordinary long names just work.)
;
; Each over-length case (32 characters) compiles on its own and must report
; exactly error 61; a 31-character name compiles cleanly; and the original
; defect program (variable1/variable2) now yields three distinct variables and
; total = 14.
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

TEST_CUSTOM_MAIN:
    ld   hl, SRC_NUM
    call COMPILE_SRC
    cp   61
    jp   nz, TEST_FAIL
    ld   hl, SRC_DIM
    call COMPILE_SRC
    cp   61
    jp   nz, TEST_FAIL
    ld   hl, SRC_STR
    call COMPILE_SRC
    cp   61
    jp   nz, TEST_FAIL
    ld   hl, SRC_COLLIDE
    call COMPILE_SRC
    cp   61
    jp   nz, TEST_FAIL

    ld   hl, SRC_OK                  ; exactly 31 characters is allowed
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    ld   a, (CSYM_COUNT)
    cp   2                           ; the 31-character name and Z
    jp   nz, TEST_FAIL

    ld   hl, SRC_NINE                ; the original defect: now THREE variables
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    ld   a, (CSYM_COUNT)
    cp   3                           ; variable1, variable2, total
    jp   nz, TEST_FAIL
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    TSYM_LD16 2*3 + 1  ; total = symbol 2
    ld   de, 14                      ; 5 + 9 (it used to be 18)
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL
    jp   TEST_PASS

; 32 characters (one over the limit) / 31 characters (the limit)
SRC_NUM:     db "ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEF=1", 0
SRC_DIM:     db "DIM ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEF(3)", 0
SRC_STR:     db 'ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEF$="x"', 0
SRC_COLLIDE: db "ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEF1=5:ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEF2=9", 0
SRC_OK:      db "ABCDEFGHIJKLMNOPQRSTUVWXYZABCDE=1:Z=2", 0
SRC_NINE:    db "variable1=5:variable2=9:total=variable1+variable2", 0

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
