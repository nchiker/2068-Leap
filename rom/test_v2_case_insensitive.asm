; ============================================================================
; rom/test_v2_case_insensitive.asm — R10.7 phase 2b smoke test: BASIC
; case-insensitivity (keywords, identifiers, built-in functions, numeric
; and string arrays, PROC/CALL, DEF FN). Covers the real fix: rom/exrom_
; v2_compiler.asm's LEX_SCAN_IDENT (lowercase letters are now valid
; identifier/keyword characters at all) and its new FOLD_UPPER routine,
; used by LEX_CLASSIFY_KEYWORD, BUILTIN_FN_FIND, and every symbol table's
; own FIND_OR_CREATE/LOOKUP (CSYM/STRSYM/ARRSYM/STRARRSYM/LABELTAB), plus
; kernel/extensions/ext_registry.asm's own local EXT2_FOLD_UPPER copy.
;
; Each check below calls the REAL compiler lookup routine itself (CSYM_
; FIND_OR_CREATE/STRSYM_FIND_OR_CREATE) with a known name, rather than
; predicting the compiler's own first-use index assignment order by
; hand -- this is both simpler and a second, independent exercise of the
; same fold logic the compiler used while compiling SOURCE_TEXT. A
; mismatched case spelling that accidentally created a SEPARATE symbol
; (the exact bug class this phase fixes) would show up here either as a
; wrong value (two different storage slots silently diverged) or as a
; wrong *_COUNT (more distinct symbols than names actually used).
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

DECOMP_END_ADDR: equ $9900

TEST_CUSTOM_MAIN:
    ld   hl, PROG_AREA_START
    ld   (PROG_END), hl
    ld   (ARRAYS_END), hl
    ld   hl, V2_SOURCE_END
    ld   (VARS_START), hl

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

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    call CHECK_RESULT
    jp   c, TEST_FAIL

    jp   TEST_PASS

; counter/COUNTER -- plain numeric scalar case identity (-> 6).
; a1/A1 -- a digit-containing name (proves FOLD_UPPER's conditional
;   range check doesn't corrupt digits the way a blind "and $DF" did --
;   a real regression this session's own regression suite caught).
; if/then/else lowercase, ENDIF uppercase -- mixed-case keywords in one
;   statement (-> flag=1).
; upper$ lowercase built-in function name, b$="ab" -> c$="AB".
; dim arr(3)/ARR(1) -- numeric array name case identity (-> y=8).
; dim s$(2)/S$(0) -- string array name case identity (-> z$="hi").
; PROC Add1/CALL add1 -- PROC/CALL name case identity via LABELTAB
;   (-> r=10).
; DEF FN Sq/FN SQ -- DEF FN name case identity via LABELTAB (-> w=25).
SOURCE_TEXT:
    db "counter=5:COUNTER=COUNTER+1:", 13
    db "a1=10:A1=A1+5:", 13
    db "if COUNTER=6 then flag=1 else flag=2 ENDIF:", 13
    db 'b$="ab":c$=upper$(b$):', 13
    db "dim arr(3):arr(1)=7:ARR(1)=ARR(1)+1:y=arr(1):", 13
    db 'dim s$(2):s$(0)="hi":z$=S$(0):', 13
    db "PROC Add1(n):n=n+1:r=n:ENDP:", 13
    db "CALL add1(9):", 13
    db "DEF FN Sq(x)=x*x:", 13
    db "w=fn SQ(5)", 0

; ============================================================================
; CHECK_RESULT -- each numeric scalar is located via a real CSYM_FIND_OR_
; CREATE call (HL=name, B=len), each string scalar via STRSYM_FIND_OR_
; CREATE, both using the UPPERCASE spelling regardless of which case the
; source used to create them -- the whole point being proven. Carry set
; on any mismatch.
; ============================================================================
CHECK_RESULT:
    ; counter (expect 6)
    ld   hl, NM_COUNTER
    ld   b, NM_COUNTER_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 6
    call CHECK_NUM_EQ2
    ret  c

    ; a1 (expect 15)
    ld   hl, NM_A1
    ld   b, NM_A1_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 15
    call CHECK_NUM_EQ2
    ret  c

    ; flag (expect 1)
    ld   hl, NM_FLAG
    ld   b, NM_FLAG_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 1
    call CHECK_NUM_EQ2
    ret  c

    ; y (expect 8, proves numeric array name case identity)
    ld   hl, NM_Y
    ld   b, NM_Y_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 8
    call CHECK_NUM_EQ2
    ret  c

    ; r (expect 10, proves PROC/CALL name case identity)
    ld   hl, NM_R
    ld   b, NM_R_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 10
    call CHECK_NUM_EQ2
    ret  c

    ; w (expect 25, proves DEF FN name case identity)
    ld   hl, NM_W
    ld   b, NM_W_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 25
    call CHECK_NUM_EQ2
    ret  c

    ; c$ (expect "AB", proves lowercase built-in function name lookup)
    ld   hl, NM_C
    ld   b, NM_C_LEN
    call STRSYM_FIND_OR_CREATE
    call VM_STR_ADDR
    ld   de, EXPECT_AB
    call STRCHECK_CMP
    ret  c

    ; z$ (expect "hi", proves string array name case identity)
    ld   hl, NM_Z
    ld   b, NM_Z_LEN
    call STRSYM_FIND_OR_CREATE
    call VM_STR_ADDR
    ld   de, EXPECT_HI
    call STRCHECK_CMP
    ret  c

    ; Sanity: exactly as many distinct symbols as distinct names used --
    ; a wrong (too-high) count would mean some case variant failed to
    ; fold and silently created a second, separate symbol.
    ld   a, (CSYM_COUNT)         ; counter,a1,flag,n,r,y,x,w = 8
    cp   8
    jr   nz, .bad
    ld   a, (STRSYM_COUNT)       ; b,c,z = 3
    cp   3
    jr   nz, .bad
    ld   a, (ARRSYM_COUNT)       ; arr = 1
    cp   1
    jr   nz, .bad
    ld   a, (STRARRSYM_COUNT)    ; s = 1
    cp   1
    jr   nz, .bad
    or   a
    ret
.bad:
    scf
    ret

; CHECK_NUM_EQ -- input: A = CSYM index (from CSYM_FIND_OR_CREATE).
; Output: HL = that symbol's own runtime value (SYMTAB_BASE+idx*3+1).
; Destroys: AF, DE, HL.
CHECK_NUM_EQ:
    ld   l, a
    ld   h, 0
    ld   d, h
    ld   e, l
    add  hl, hl              ; *2
    add  hl, de               ; *3
    ld   de, (RT_SYMTAB_PTR)
    inc  de
    add  hl, de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    ret

; CHECK_NUM_EQ2 -- input: HL = actual value, DE = expected value. Output:
; carry set on mismatch. Destroys: AF, HL.
CHECK_NUM_EQ2:
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; STRCHECK_CMP -- HL -> live [len:1][content] record, DE -> expected
; [len:1][content] fixture. Carry set on any length/content mismatch.
STRCHECK_CMP:
    ld   a, (de)
    cp   (hl)
    scf
    ret  nz
    ld   b, a
    or   a
    ret  z
.loop:
    inc  hl
    inc  de
    ld   a, (de)
    cp   (hl)
    scf
    ret  nz
    djnz .loop
    or   a
    ret

NM_COUNTER: db "COUNTER"
NM_COUNTER_LEN: equ $-NM_COUNTER
NM_A1: db "A1"
NM_A1_LEN: equ $-NM_A1
NM_FLAG: db "FLAG"
NM_FLAG_LEN: equ $-NM_FLAG
NM_Y: db "Y"
NM_Y_LEN: equ $-NM_Y
NM_R: db "R"
NM_R_LEN: equ $-NM_R
NM_W: db "W"
NM_W_LEN: equ $-NM_W
NM_C: db "C"
NM_C_LEN: equ $-NM_C
NM_Z: db "Z"
NM_Z_LEN: equ $-NM_Z

EXPECT_AB: db 2, "AB"
EXPECT_HI: db 2, "hi"

; Test-only stubs: this program never exercises PRINT/LPRINT/BEEP/
; SOUND/PAUSE/INPUT/extensions/real screen bitmap content (same
; discipline as rom/test_v2_dynamic_arrays.asm).
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
