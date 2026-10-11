; ============================================================================
; rom/test_v2_builtin_roundtrip.asm -- built-in function decompile round trip.
;
; For every built-in function the compiler supports (BUILTIN_FN_TABLE, fn_index
; 0-29, including FREE() vs FREE(1)), and for nested calls of them:
;   1. compile the source;                    -> bytecode B1 (saved)
;   2. run it, snapshot the run-time tables   -> S1     (deterministic programs)
;   3. DECOMPILE_PROGRAM -> text;
;   4. compile the decompiled text;           -> bytecode B2
;   5. B1 == B2 byte for byte (same ops, same operands, same argument counts),
;      and (when run) running B2 gives tables identical to S1.
; It also asserts the exact decompiled text of the FREE() / FREE(1) pair. (Table
; agreement is checked statically by tools/check_builtin_tables.py in make check.)
; The float functions (SQR PI RAD DEG SIN COS TAN) are compared at bytecode level only:
; the calculator and the decompiler do not fit in the harness EXROM together.
; (Before this test the decompiler's name table stopped at fn_index 24.)
; ============================================================================
    DEFINE TEST_V2_NEEDS_DECOMPILE
    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"

BYTES1:        equ $8800        ; saved bytecode of the first compile (<= 1 KB)
SNAP1:         equ $8C00        ; saved run-time tables of the first run (<= 2 KB)
ATTR_TEST_BUF: equ $9400        ; stub attribute RAM for ATTR() (768 bytes)

TEST_V2_RESUME_ADDR: equ $
    ORG $0004
USR_TEST_ROUTINE:               ; USR(4) target, as in test_v2_group6_math
    ld   hl, 4321
    ret
    ORG TEST_V2_RESUME_ADDR

PT:     equ $8B20               ; (RAM) next program-table entry
RUNF:   equ $8B22               ; this program is deterministic: run and compare
LEN1:   equ $8B23               ; bytes in B1
SNLEN:  equ $8B25               ; bytes in S1

; program table: dw source, db run ; terminated by dw 0.
; (The decompiler rebuilds each expression in a 31-byte fragment, so nested expressions here
; stay under 31 characters; longer ones give clean DECOMP error 4 -- an existing limit.)
; Variables are named as the decompiler writes them (V0.. / S0$..): FREE() depends on the
; compile symbol-table size, so the recompiled program must use same-length names.
PROGS:
    dw P_INT    : db 1
    dw P_STR    : db 1
    dw P_FLOAT  : db 0              ; float functions need the calculator, which
                                    ; does not fit beside the decompiler in the
                                    ; harness EXROM: byte-for-byte round trip only
    dw P_FREE   : db 1
    dw P_STRV   : db 1
    dw P_VAL    : db 0
    dw P_NEST   : db 1
    dw P_NESTF  : db 0
    dw P_RND    : db 0
    dw P_USR    : db 1
    dw 0

P_INT:   db "A=ABS(-5):B=SGN(-3):C=MOD(17,5):D=DIV(17,5):E=INT(7):F=PEEK(0):G=POINT(5,10):H=ATTR(2,3)", 0
P_STR:   db "Z$=\"HI\":L=LEN(Z$):M=CODE(Z$):A$=CHR$(65):B$=STR$(42):C$=UPPER$(\"abC\")"
         db ":D$=LOWER$(\"AbC\"):E$=LEFT$(\"HELLO\",2):F$=RIGHT$(\"HELLO\",3):G$=MID$(\"HELLO\",2,3):H$=INKEY$()", 0
P_STRV:  db "S0$=\"HELLO\":S1$=MID$(S0$,2,3):S2$=LEFT$(S0$,2):S3$=RIGHT$(S0$,2):S4$=UPPER$(S0$)"
         db ":S5$=LOWER$(S0$):V1=CODE(S0$):V2=LEN(MID$(S0$,1,2))", 0
P_VAL:   db "S0$=\"123\":V0=VAL(S0$):V1=VAL(\"123\")", 0   ; RC: VAL parses with the calculator -> bytecode-level only
                                             ; (its value: test_v2_group6_math_run, the corpus)
P_FLOAT: db "A=SQR(16):B=PI():C=RAD(90):D=DEG(1):E=SIN(30):F=COS(60):G=TAN(45)", 0
P_FREE:  db "V0=FREE():V1=FREE(1):V2=FREE(0)", 0   ; names as the decompiler writes them: FREE()
                                              ; depends on the symbol-table size
P_NEST:  db "V0=ABS(MOD(DIV(100,7),5)):S0$=LEFT$(UPPER$(\"hello\"),3):S1$=MID$(LOWER$(\"ABCDEF\"),2,3)"
         db ":V1=LEN(RIGHT$(STR$(12345),3)):V2=FREE(MOD(2,3)-1):V3=LEN(CHR$(CODE(\"A\")))", 0
P_NESTF: db "V0=INT(SQR(ABS(-81))):V1=SIN(COS(0))+TAN(0):V2=DEG(RAD(SIN(PI())))", 0
P_RND:   db "A=RND(10):B=RND(255)+RND(2)", 0
P_USR:   db "K=USR(4)", 0

; RT_COMPILE -- HL = zero-terminated source. Fails the test on a compile error.
RT_COMPILE:
    push hl
    call COMPILER_INIT
    pop  hl
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    ret

; RUN_PROGRAM -- run the compiled bytecode; fails the test on a runtime error.
RUN_PROGRAM:
    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    ret

; TABLE_BOUNDS -- HL = start of the carved run-time tables, BC = their length.
TABLE_BOUNDS:
    ld   hl, (VARS_START)
    ld   de, V2_SOURCE_END
    ex   de, hl
    or   a
    sbc  hl, de             ; HL = length
    ld   b, h
    ld   c, l
    ex   de, hl             ; HL = start
    ret

TEST_CUSTOM_MAIN:
    ld   hl, ATTR_TEST_BUF          ; seed the stub attribute RAM
    ld   de, ATTR_TEST_BUF + 1
    ld   bc, 767
    ld   (hl), 0
    ldir
    ld   a, 42
    ld   (ATTR_TEST_BUF + 2*32 + 3), a

    call CHECK_FREE_TEXT            ; exact decompiled text of FREE()/FREE(1)

    ld   hl, PROGS
    ld   (PT), hl
.next:
    ld   hl, (PT)
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    inc  hl
    ld   a, (hl)
    inc  hl
    ld   (PT), hl
    ld   (RUNF), a
    ld   a, d
    or   e
    jp   z, TEST_PASS
    ex   de, hl
    call RT_COMPILE
    ; save B1
    ld   hl, (EMIT_PTR)
    ld   de, VM_CODE_BASE
    or   a
    sbc  hl, de
    ld   (LEN1), hl
    ld   b, h
    ld   c, l
    ld   hl, VM_CODE_BASE
    ld   de, BYTES1
    ldir
    ; run + snapshot
    ld   a, (RUNF)
    or   a
    jr   z, .decomp
    call RUN_PROGRAM
    call TABLE_BOUNDS
    ld   (SNLEN), bc
    ld   de, SNAP1
    ldir
.decomp:
    ld   hl, (LEN1)
    ld   de, VM_CODE_BASE
    add  hl, de
    ld   (DECOMP_END_ADDR), hl
    call DECOMPILE_PROGRAM
    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    ld   hl, (DECOMP_OUT_PTR)
    ld   (hl), 0
    ld   hl, DECOMP_OUT_BUF
    call RT_COMPILE                 ; recompile the decompiled text
    ld   hl, (EMIT_PTR)
    ld   de, VM_CODE_BASE
    or   a
    sbc  hl, de
    ld   de, (LEN1)
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL              ; same length
    ld   bc, (LEN1)
    ld   hl, VM_CODE_BASE
    ld   de, BYTES1
    call MEMCMP
    jp   nz, TEST_FAIL              ; same bytes
    ld   a, (RUNF)
    or   a
    jp   z, .next
    call RUN_PROGRAM
    call TABLE_BOUNDS
    push hl
    ld   hl, (SNLEN)
    or   a
    sbc  hl, bc
    pop  hl
    jp   nz, TEST_FAIL              ; same table size
    ld   de, SNAP1
    call MEMCMP
    jp   nz, TEST_FAIL              ; same run-time state
    jp   .next

; MEMCMP -- compare BC bytes at (HL) and (DE). Z if equal.
MEMCMP:
    ld   a, b
    or   c
    ret  z
.l:
    ld   a, (de)
    cp   (hl)
    ret  nz
    inc  hl
    inc  de
    dec  bc
    ld   a, b
    or   c
    jr   nz, .l
    ret                             ; Z

; CHECK_FREE_TEXT -- "A=FREE():B=FREE(1)" must decompile to text that contains
; "V0 = FREE()" and "V1 = FREE(1)" exactly.
CHECK_FREE_TEXT:
    ld   hl, SRC_FREE_PAIR
    call RT_COMPILE
    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl
    call DECOMPILE_PROGRAM
    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL
    ld   hl, (DECOMP_OUT_PTR)
    ld   (hl), 0
    ld   hl, DECOMP_OUT_BUF
    ld   de, EXPECT_FREE_TEXT
    ld   bc, EXPECT_FREE_TEXT_END - EXPECT_FREE_TEXT
    call MEMCMP
    jp   nz, TEST_FAIL
    ld   hl, (DECOMP_OUT_PTR)
    ld   de, DECOMP_OUT_BUF
    or   a
    sbc  hl, de
    ld   de, EXPECT_FREE_TEXT_END - EXPECT_FREE_TEXT
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL              ; and nothing extra
    ret
SRC_FREE_PAIR: db "A=FREE():B=FREE(1)", 0
EXPECT_FREE_TEXT:
    db "V0 = FREE()", 13, "V1 = FREE(1)", 13
EXPECT_FREE_TEXT_END:

; Test-only stubs (same discipline as test_v2_r10_numeric / group6_math).
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
GFX_READ_PIXEL:                     ; (x+y)&1, as in test_v2_group6_math
    ld a,b
    add a,c
    and 1
    ret
GFX_CELL_ATTR_ADDR:                 ; row*32+col into ATTR_TEST_BUF
    ld a,b
    cp 24
    jr nc,.oor
    ld a,c
    cp 32
    jr nc,.oor
    ld h,0
    ld l,b
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld d,0
    ld e,c
    add hl,de
    ld de,ATTR_TEST_BUF
    add hl,de
    or a
    ret
.oor:
    scf
    ret
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"
