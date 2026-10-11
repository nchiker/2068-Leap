; ============================================================================
; rom/test_v2_control_stack.asm -- R10.7 P4 regression test.
;
; The unified typed control stack (FOR / CALL / PARAM frames, growing down
; from VARS_START toward ARRAYS_END):
;   1. 150-deep PROC recursion with a parameter (old limit: 12): R == 11325,
;      stack empty afterwards.
;   2. GOTO out of a FOR loop inside a PROC leaks the FOR frame; UNBIND/RET
;      must skip it and the owner pop must discard it: three calls, R == 3,
;      stack empty (a failed unwind would raise error 7 or corrupt the
;      return address).
;   3. Stack grows into the arrays: DIM A(2000) then unbounded recursion ->
;      error 6, CSP >= ARRAYS_END, and the array's last element is intact.
;   4. Arrays grow into the stack: DIM A(3300) alone fits (no error), the
;      same DIM from 200 levels deep is refused with error 64.
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
    TSYM_LD16 1*3 + 1               ; R = symbol 1 (N=0, R=1)
    ld   de, 11325
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
    TSYM_LD16 2*3 + 1               ; R = symbol 2 (N=0, I=1, R=2)
    ld   de, 3
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
    ld   hl, (VM_CSP)
    ld   de, (ARRAYS_END)
    or   a
    sbc  hl, de
    jp   c, TEST_FAIL
    ld   hl, (ARRAYS_END)
    dec  hl
    dec  hl
    ld   a, (hl)                    ; A(1999) low byte
    cp   9
    jp   nz, TEST_FAIL

    ld   hl, SRC4A
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    ld   hl, SRC4B
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    cp   64
    jp   nz, TEST_FAIL
    jp   TEST_PASS

CS_EMPTY:
    ld   hl, (VM_CSP)
    ld   de, (VARS_START)
    or   a
    sbc  hl, de
    ret

SRC1:
    db "PROC C(N):IF N>0 THEN CALL C(N-1) ENDIF:R=R+N:ENDP:R=0:CALL C(150)", 0
SRC2:
    db "PROC G(N):FOR I=1 TO 5:GOTO FIN:NEXT I:FIN:R=R+1:ENDP:"
    db "R=0:CALL G(0):CALL G(0):CALL G(0)", 0
SRC3:
    db "PROC F(N):CALL F(N+1):ENDP:DIM A(2000):A(1999)=9:CALL F(0)", 0
SRC4A:
    db "PROC F(N):IF N>0 THEN CALL F(N-1) ENDIF:IF N=0 THEN DIM A(3300) ENDIF:ENDP:"
    db "CALL F(0)", 0
SRC4B:
    db "PROC F(N):IF N>0 THEN CALL F(N-1) ENDIF:IF N=0 THEN DIM A(3300) ENDIF:ENDP:"
    db "CALL F(200)", 0

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
