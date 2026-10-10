; ============================================================================
; rom/test_v2_for_recursion_guard.asm -- R10.7 P0 regression, reworked in P4.
;
; P0 DEFECT: FOR frames lived in a 15-frame fixed table that PROC recursion
; overflowed silently into VM_IP/VM_SP. P0 added a depth guard; P4 replaced
; the fixed table with the unified memory-limited control stack, so the
; guard became "stack meets the arrays".
;
; TEST 1: two nested loops per level, recursion 41 deep (22 B/level, far
;   past the old 15-frame limit): no error, stack empty again, R == 41.
; TEST 2: one loop per level, F(9): R == 10, stack empty.
; TEST 3: unbounded recursion: clean error 6 (STACK OVERFLOW), VM_IP still
;   inside the emitted code, CSP never below ARRAYS_END.
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
    ld   hl, SRC1
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    call CS_EMPTY
    jp   nz, TEST_FAIL
    TSYM_LD16 3*3 + 1  ; R = symbol 3 (N=0, I=1, J=2, R=3)
    ld   de, 41
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL

    ld   hl, SRC2
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    call CS_EMPTY
    jp   nz, TEST_FAIL
    TSYM_LD16 2*3 + 1  ; R = symbol 2 (N=0, I=1, R=2)
    ld   de, 10
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL

    ld   hl, SRC3
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    cp   6
    jp   nz, TEST_FAIL
    ld   hl, (VM_CSP)                ; never below the arrays
    ld   de, (ARRAYS_END)
    or   a
    sbc  hl, de
    jp   c, TEST_FAIL
    ld   hl, (VM_IP)                 ; must not have been overwritten
    ld   de, VM_CODE_BASE
    or   a
    sbc  hl, de
    jp   c, TEST_FAIL
    ld   hl, (VM_IP)
    ld   de, (EMIT_PTR)
    or   a
    sbc  hl, de
    jp   nc, TEST_FAIL
    jp   TEST_PASS

CS_EMPTY:
    ld   hl, (VM_CSP)
    ld   de, (VARS_START)
    or   a
    sbc  hl, de
    ret

SRC1:
    db "PROC F(N):FOR I=1 TO 1:FOR J=1 TO 1:IF N>0 THEN CALL F(N-1) ENDIF:"
    db "NEXT J:NEXT I:R=R+1:ENDP:R=0:CALL F(40)", 0
SRC2:
    db "PROC F(N):FOR I=1 TO 1:IF N>0 THEN CALL F(N-1) ENDIF:NEXT I:R=R+1:ENDP:"
    db "R=0:CALL F(9)", 0
SRC3:
    db "PROC F(N):CALL F(N+1):ENDP:CALL F(0)", 0

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
