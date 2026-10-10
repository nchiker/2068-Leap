; ============================================================================
; rom/test_v2_identifier_length.asm — R10.7 dormant-ROM audit bug-fix
; test: the >8-character identifier-length inconsistency (docs/v2/
; R10_7_DORMANT_ROM_CONSOLIDATION_AUDIT.md). Before this fix, COMPILE_DIM
; clamped an array name to 8 significant characters before registering
; it, but COMPILE_FACTOR.ident's array-read path, COMPILE_ARRAY_ASSIGN,
; COMPILE_DIMN, COMPILE_STR_ASSIGN_CONTINUED (string SCALARS -- a wider
; gap than the audit originally reported, found during this fix's own
; verification), and COMPILE_STRARR_ASSIGN all passed the FULL, unclamped
; length to their own ARRSYM_LOOKUP/STRARRSYM_LOOKUP/STRSYM_FIND_OR_
; CREATE calls -- a long name could DIM/assign successfully but then fail
; to be found again (error 42 "never DIM'd") or silently auto-vivify as
; a different, wrong symbol. All 5 sites now call the existing shared
; CLAMP_LEN8 routine, the same rule every other FIND_OR_CREATE/LOOKUP
; call site in this file already followed.
;
; SEMANTICS (R10.7, approved product decision): identifiers are significant to
; IDENT_MAX_LEN = 31 characters; two distinct names are NEVER silently merged and
; a name longer than 31 is an explicit compile error (61), see rom/
; test_v2_identifier_toolong.asm. (Until P2 the limit was 8 and a longer name was
; silently truncated -- longpfxaa/longpfxab used to collide into ONE variable.)
; This test exercises long names (9..21 characters) for numeric/string scalars
; and numeric/string arrays, case-varying DIM/assign/read, DIMN, and the
; longpfxaa/longpfxab pair, which must now be TWO distinct variables.
;
; This test also covers DIMN's own case-insensitivity fix (rom/exrom_v2_
; compiler.asm's COMPILE_FACTOR.ident, the hand-rolled "DIMN" keyword
; compare that was missed when every other name-compare site in that
; file got FOLD_UPPER) -- exercised here with both a lowercase "dimn"
; and a mixed-case array-name argument, together with the length-clamp
; fix, since COMPILE_DIMN itself also had the missing-clamp bug.
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

; verylongarrayname/VERYLONGARRAYNAME -- numeric array DIM'd then assigned/read
;   under different case -> a=42.
; longstrarrayname$/LONGSTRARRAYNAME$ -- string array, same case-varying
;   DIM/assign/read -> b$="hi".
; longstringscalarname$/LONGSTRINGSCALARNAME$ -- string SCALAR -> c$="xyz".
; longpfxaa/longpfxab (9 chars, same 8-character prefix) -- TWO different
;   variables: f=longpfxaa must read 11 (it used to read 22, via the merge).
; d/e: DIMN(name) with mixed keyword/array-name case -> 5.
; g: two 17-character DEF FN names, one nested as the other's argument: the
;   call parks the whole 32-byte name buffer across the nested expression
;   (R10.7 P2 -- it used to park only 8 bytes) -> g = (4+1)*2 = 10.
SOURCE_TEXT:
    db "dim verylongarrayname(5):VERYLONGARRAYNAME(2)=42:", 13
    db "a=verylongarrayname(2):", 13
    db 'dim longstrarrayname$(3):LONGSTRARRAYNAME$(1)="hi":', 13
    db "b$=longstrarrayname$(1):", 13
    db 'longstringscalarname$="xyz":', 13
    db "c$=LONGSTRINGSCALARNAME$:", 13
    db "longpfxaa=11:longpfxab=22:", 13
    db "f=longpfxaa:", 13
    db "d=dimn(VeryLongArrayName):", 13
    db "e=DIMN(verylongarrayname):", 13
    db "def fn longfunctionname1(x)=x+1:", 13
    db "def fn longfunctionname2(x)=x*2:", 13
    db "g=fn longfunctionname2(fn longfunctionname1(4))", 0

; ============================================================================
; CHECK_RESULT -- each numeric scalar is located via a real CSYM_FIND_OR_
; CREATE call (HL=name, B=len, already clamped to 8 here in the test's
; own fixture data to mirror what the compiler itself stores), each
; string scalar via STRSYM_FIND_OR_CREATE. Carry set on any mismatch.
; ============================================================================
CHECK_RESULT:
    ; a (expect 42, numeric array name >8 chars, case-varying)
    ld   hl, NM_A
    ld   b, NM_A_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 42
    call CHECK_NUM_EQ2
    ret  c

    ; f (expect 11: longpfxaa and longpfxab are two distinct variables)
    ld   hl, NM_F
    ld   b, NM_F_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 11
    call CHECK_NUM_EQ2
    ret  c

    ; longpfxab must still hold its own 22
    ld   hl, NM_PFXAB
    ld   b, NM_PFXAB_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 22
    call CHECK_NUM_EQ2
    ret  c

    ; g (expect 10: nested long-named DEF FN calls)
    ld   hl, NM_G
    ld   b, NM_G_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 10
    call CHECK_NUM_EQ2
    ret  c

    ; d (expect 5, DIMN with mixed-case array name)
    ld   hl, NM_D
    ld   b, NM_D_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 5
    call CHECK_NUM_EQ2
    ret  c

    ; e (expect 5, lowercase "dimn" keyword)
    ld   hl, NM_E
    ld   b, NM_E_LEN
    call CSYM_FIND_OR_CREATE
    call CHECK_NUM_EQ
    ld   de, 5
    call CHECK_NUM_EQ2
    ret  c

    ; b$ (expect "hi", string array name >8 chars, case-varying)
    ld   hl, NM_B
    ld   b, NM_B_LEN
    call STRSYM_FIND_OR_CREATE
    call VM_STR_ADDR
    ld   de, EXPECT_HI
    call STRCHECK_CMP
    ret  c

    ; c$ (expect "xyz", string SCALAR name >8 chars, case-varying)
    ld   hl, NM_C
    ld   b, NM_C_LEN
    call STRSYM_FIND_OR_CREATE
    call VM_STR_ADDR
    ld   de, EXPECT_XYZ
    call STRCHECK_CMP
    ret  c

    ; Sanity: exactly the distinct symbols the source declares. CSYM_COUNT:
    ; a, longpfxaa, longpfxab, f, d, e, x, g = 8. STRSYM_COUNT: b, longstringscalar
    ; name, c = 3.
    ld   a, (CSYM_COUNT)
    cp   8
    jr   nz, .bad
    ld   a, (STRSYM_COUNT)
    cp   3
    jr   nz, .bad
    ld   a, (ARRSYM_COUNT)         ; verylongarrayname = 1
    cp   1
    jr   nz, .bad
    ld   a, (STRARRSYM_COUNT)      ; longstrarrayname = 1
    cp   1
    jr   nz, .bad
    or   a
    ret
.bad:
    scf
    ret

; CHECK_NUM_EQ -- input: A = CSYM index. Output: HL = that symbol's own
; runtime value (SYMTAB_BASE+idx*3+1). Destroys: AF, DE, HL.
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

NM_A: db "A"
NM_A_LEN: equ $-NM_A
NM_PFXAB: db "LONGPFXAB"
NM_PFXAB_LEN: equ $-NM_PFXAB
NM_G: db "G"
NM_G_LEN: equ $-NM_G
NM_F: db "F"
NM_F_LEN: equ $-NM_F
NM_D: db "D"
NM_D_LEN: equ $-NM_D
NM_E: db "E"
NM_E_LEN: equ $-NM_E
NM_B: db "B"
NM_B_LEN: equ $-NM_B
NM_C: db "C"
NM_C_LEN: equ $-NM_C

EXPECT_HI: db 2, "hi"
EXPECT_XYZ: db 3, "xyz"

; Test-only stubs: this program never exercises PRINT/LPRINT/BEEP/
; SOUND/PAUSE/INPUT/extensions/real screen bitmap content (same
; discipline as rom/test_v2_case_insensitive.asm).
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
