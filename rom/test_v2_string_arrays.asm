; ============================================================================
; rom/test_v2_string_arrays.asm — Dynamic Data Phase 2 smoke test: string
; arrays (DIM A$(n,w)). Covers: DIM with an explicit width, array-element
; assignment (with truncation to the declared width), array-element read
; into a plain string variable, and a second independent string array.
; Built on the shared production-shaped harness, same pattern as
; rom/test_v2_dynamic_arrays.asm. Does NOT exercise DECOMPILE_PROGRAM
; (same known, reported gap as the numeric-array test).
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"

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

; A$ is a 3-element, width-8 string array ([len:1][content:7] per
; element -- enough to hold "HELLO" and "WORLD" whole, but NOT the
; 10-character literal assigned to A$(2), which must come back
; truncated to 7 content bytes ("TRUNCAT"). B$ is a second, independent
; string array (proving STRARR_PTR_TABLE slot independence, the string-
; array twin of test_v2_dynamic_arrays.asm's own A/B numeric check).
; C$/D$/E$ are plain scalar string variables used to read array
; elements back out where CHECK_RESULT can inspect them via STRSYM_
; FIND_OR_CREATE's own compile-time index order (C$=0, D$=1, E$=2).
SOURCE_TEXT:
    db "DIM A$(3,8)", 13
    db "DIM B$(2)", 13
    db 'A$(0)="HELLO"', 13
    db 'A$(1)="WORLD"', 13
    db 'A$(2)="TRUNCATEDTEXT"', 13
    db 'B$(0)="X"', 13
    db "C$=A$(0)", 13
    db "D$=A$(2)", 13
    db "E$=B$(0)", 13
    db 0

; ============================================================================
; CHECK_RESULT — reads C$/D$/E$'s own STRSYM-assigned STRTAB records
; directly (compile-time creation order: C$=index 0, D$=index 1, E$=
; index 2 -- A$/B$ are string ARRAYS, a separate symbol table that never
; touches STRSYMTAB's own index counter). Expects C$="HELLO", D$=
; "TRUNCAT" (13-char literal truncated to width-1=7 content bytes),
; E$="X". Carry set on any mismatch.
; ============================================================================
CHECK_RESULT:
    xor  a                   ; C$ = STRTAB index 0
    call VM_STR_ADDR
    ld   de, EXPECT_HELLO
    call STRCHECK_CMP
    ret  c

    ld   a, 1                 ; D$ = STRTAB index 1
    call VM_STR_ADDR
    ld   de, EXPECT_TRUNCAT
    call STRCHECK_CMP
    ret  c

    ld   a, 2                 ; E$ = STRTAB index 2
    call VM_STR_ADDR
    ld   de, EXPECT_X
    call STRCHECK_CMP
    ret

; STRCHECK_CMP — HL -> live [len:1][content] record, DE -> expected
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

EXPECT_HELLO:   db 5, "HELLO"
EXPECT_TRUNCAT: db 7, "TRUNCAT"
EXPECT_X:       db 1, "X"

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
