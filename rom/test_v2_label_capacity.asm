; ============================================================================
; rom/test_v2_label_capacity.asm -- R10.7 P2 regression test.
;
; The compile-time label/PROC/DEF FN table used to hold 8 entries in total and
; forward references used a second 8-entry fixup table. Labels now live in the
; tagged symbol table (kind 4) and forward references are threaded THROUGH THE
; EMITTED CODE (each unresolved operand holds the previous unresolved operand's
; address; the label record holds the chain head), so there is no table to
; fill. This test exercises far more than the old limit:
;
;   * 24 labels, each forward-referenced TWICE (a 2-long chain) and then
;     reached; every skipped "S=S+1000" must really be skipped      -> S = 24
;   * 12 PROCs defined and called                                    -> + 78
;   * 12 DEF FNs defined and used                                    -> T = 78
;   * a DEF FN called BEFORE its definition (forward reference)      -> U = 10
; so S == 102, T == 78, U == 10 and the compile reports no error.
; A second compile of "GOTO NOWHERE" must report error 7 (undefined label).
; ============================================================================
    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"

DECOMP_END_ADDR: equ $9900

TEST_CUSTOM_MAIN:
    ld   hl, SRC_BIG
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    ld   hl, NM_S
    ld   b, 1
    ld   de, 102
    call CHECK_VAR
    jp   c, TEST_FAIL
    ld   hl, NM_T
    ld   b, 1
    ld   de, 78
    call CHECK_VAR
    jp   c, TEST_FAIL
    ld   hl, NM_U
    ld   b, 1
    ld   de, 10
    call CHECK_VAR
    jp   c, TEST_FAIL

    ld   hl, SRC_UNDEF
    call COMPILE_SRC
    cp   7
    jp   nz, TEST_FAIL
    jp   TEST_PASS

; CHECK_VAR -- HL = name, B = length, DE = expected value. Carry set on mismatch.
CHECK_VAR:
    push de                  ; expected value (VM_SYM_ADDR destroys DE)
    ld   c, SYM_K_NUM
    call SYM_FIND
    jr   c, .bad
    call VM_SYM_ADDR
    inc  hl
    ld   a, (hl)
    inc  hl
    ld   h, (hl)
    ld   l, a
    pop  de
    or   a
    sbc  hl, de
    ret  z
    scf
    ret
.bad:
    pop  de
    scf
    ret

NM_S: db "S"
NM_T: db "T"
NM_U: db "U"

SRC_UNDEF: db "GOTO NOWHERE", 0

; COMPILE_SRC: HL = source text. Out: A = COMPILE_ERROR_CODE (Z if none).
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

SRC_BIG:
    db "S=0:T=0:IF S>-1 THEN GOTO G1:GOTO G1:S=S+1000:G1:S=S+1:IF S>-1 THEN GOTO G2:GOTO G2:S=S+1000:G2:S=S+"
    db "1:IF S>-1 THEN GOTO G3:GOTO G3:S=S+1000:G3:S=S+1:IF S>-1 THEN GOTO G4:GOTO G4:S=S+1000:G4:S=S+1:IF S"
    db ">-1 THEN GOTO G5:GOTO G5:S=S+1000:G5:S=S+1:IF S>-1 THEN GOTO G6:GOTO G6:S=S+1000:G6:S=S+1:IF S>-1 TH"
    db "EN GOTO G7:GOTO G7:S=S+1000:G7:S=S+1:IF S>-1 THEN GOTO G8:GOTO G8:S=S+1000:G8:S=S+1:IF S>-1 THEN GOT"
    db "O G9:GOTO G9:S=S+1000:G9:S=S+1:IF S>-1 THEN GOTO G10:GOTO G10:S=S+1000:G10:S=S+1:IF S>-1 THEN GOTO G"
    db "11:GOTO G11:S=S+1000:G11:S=S+1:IF S>-1 THEN GOTO G12:GOTO G12:S=S+1000:G12:S=S+1:IF S>-1 THEN GOTO G"
    db "13:GOTO G13:S=S+1000:G13:S=S+1:IF S>-1 THEN GOTO G14:GOTO G14:S=S+1000:G14:S=S+1:IF S>-1 THEN GOTO G"
    db "15:GOTO G15:S=S+1000:G15:S=S+1:IF S>-1 THEN GOTO G16:GOTO G16:S=S+1000:G16:S=S+1:IF S>-1 THEN GOTO G"
    db "17:GOTO G17:S=S+1000:G17:S=S+1:IF S>-1 THEN GOTO G18:GOTO G18:S=S+1000:G18:S=S+1:IF S>-1 THEN GOTO G"
    db "19:GOTO G19:S=S+1000:G19:S=S+1:IF S>-1 THEN GOTO G20:GOTO G20:S=S+1000:G20:S=S+1:IF S>-1 THEN GOTO G"
    db "21:GOTO G21:S=S+1000:G21:S=S+1:IF S>-1 THEN GOTO G22:GOTO G22:S=S+1000:G22:S=S+1:IF S>-1 THEN GOTO G"
    db "23:GOTO G23:S=S+1000:G23:S=S+1:IF S>-1 THEN GOTO G24:GOTO G24:S=S+1000:G24:S=S+1:PROC P1(N):S=S+N:EN"
    db "DP:PROC P2(N):S=S+N:ENDP:PROC P3(N):S=S+N:ENDP:PROC P4(N):S=S+N:ENDP:PROC P5(N):S=S+N:ENDP:PROC P6(N"
    db "):S=S+N:ENDP:PROC P7(N):S=S+N:ENDP:PROC P8(N):S=S+N:ENDP:PROC P9(N):S=S+N:ENDP:PROC P10(N):S=S+N:END"
    db "P:PROC P11(N):S=S+N:ENDP:PROC P12(N):S=S+N:ENDP:CALL P1(1):CALL P2(2):CALL P3(3):CALL P4(4):CALL P5("
    db "5):CALL P6(6):CALL P7(7):CALL P8(8):CALL P9(9):CALL P10(10):CALL P11(11):CALL P12(12):DEF FN F1(X)=X"
    db "+1:DEF FN F2(X)=X+2:DEF FN F3(X)=X+3:DEF FN F4(X)=X+4:DEF FN F5(X)=X+5:DEF FN F6(X)=X+6:DEF FN F7(X)"
    db "=X+7:DEF FN F8(X)=X+8:DEF FN F9(X)=X+9:DEF FN F10(X)=X+10:DEF FN F11(X)=X+11:DEF FN F12(X)=X+12:T=T+"
    db "FN F1(0):T=T+FN F2(0):T=T+FN F3(0):T=T+FN F4(0):T=T+FN F5(0):T=T+FN F6(0):T=T+FN F7(0):T=T+FN F8(0):"
    db "T=T+FN F9(0):T=T+FN F10(0):T=T+FN F11(0):T=T+FN F12(0):U=FN LATE(5):DEF FN LATE(X)=X*2"
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
