; ============================================================================
; rom/test_v2_block_if.asm — Architecture B, R8.5 Group 3 block IF test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; COMPILE_IF_BLOCK (IF <cond> THEN <body> [ELSE <body>] ENDIF), built on
; top of COMPILE_STATEMENT_LIST's own recursive reuse (same mechanism
; already proven for PROC bodies). NOT wired into the production BASIC
; dispatch or the shipping EXROM build. Built on the shared production-
; shaped test harness (rom/test_v2_harness_home_head.inc/_tail.inc + rom/
; test_v2_harness_exrom.asm) -- see that harness's own header for why
; (post-semantic-milestone test-infrastructure fix, docs/v2/
; POST_R9_TEST_INFRASTRUCTURE.md).
;
; Source program compiled and executed:
;
;   A=5:B=3:C=0:D=0:E=0
;   IF A>B THEN C=1:D=2 ENDIF              -- taken (true): C=1, D=2
;   IF A<B THEN C=99 ENDIF                 -- NOT taken: C stays 1
;   IF A<B THEN E=1 ELSE E=2 ENDIF         -- ELSE taken: E=2
;   IF A>B THEN
;     IF B>0 THEN E=3 ENDIF                -- nested block IF inside a
;   ENDIF                                    ; THEN-body: both true, E=3
;   PRINT C:PRINT D:PRINT E
;
; Exercises: a taken THEN-body with multiple statements (proves the
; recursive COMPILE_STATEMENT_LIST call compiles more than one
; statement, not just the first), a not-taken THEN-only IF (the
; skipped body's own side effect, C=99, must NOT happen), a taken
; ELSE-body, and IF nested directly inside another IF's own THEN-body
; (proves COMPILE_IF_BLOCK's own recursion through COMPILE_STATEMENT_
; LIST -> COMPILE_IF -> COMPILE_IF_BLOCK works, not just one level).
;
; Expected final values: C=1, D=2, E=3.
; ============================================================================

    DEFINE TEST_V2_NEEDS_DECOMPILE
    DEFINE TEST_V2_CHECK_DECOMPILED_TEXT
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

SOURCE_TEXT:
    db "A=5:B=3:C=0:D=0:E=0:"
    db "IF A>B THEN C=1:D=2 ENDIF:"
    db "IF A<B THEN C=99 ENDIF:"
    db "IF A<B THEN E=1 ELSE E=2 ENDIF:"
    db "IF A>B THEN IF B>0 THEN E=3 ENDIF ENDIF:"
    db "PRINT C:PRINT D:PRINT E", 0

; ============================================================================
; TEST_CHECK_RESULT — VM_OUTPUT_ROW must be 3 (one line per PRINT), then
; direct SYMTAB memory reads. Symbol declaration order (first
; appearance): 0=A 1=B 2=C 3=D 4=E.
; ============================================================================
TEST_CHECK_RESULT:
    ld   a, (VM_OUTPUT_ROW)
    cp   3
    jr   nz, .fail
    TSYM_ADDR 2*SYM_REC_LEN
    ld   de, 1
    call CHECK_SYM               ; C == 1
    jr   c, .fail
    TSYM_ADDR 3*SYM_REC_LEN
    ld   de, 2
    call CHECK_SYM               ; D == 2
    jr   c, .fail
    TSYM_ADDR 4*SYM_REC_LEN
    ld   de, 3
    call CHECK_SYM               ; E == 3
    ret
.fail:
    scf
    ret

; ============================================================================
; CHECK_SYM — In: HL = SYMTAB record address, DE = expected value.
; Out: carry clear = pass, carry set = fail.
; ============================================================================
CHECK_SYM:
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .fail
    inc  hl
    ld   a, (hl)
    inc  hl
    ld   h, (hl)
    ld   l, a
    or   a
    sbc  hl, de
    ret  z
.fail:
    scf
    ret

; ============================================================================
; TEST_CHECK_DECOMPILED — byte-for-byte against a real captured-then-
; verified rendering. "V0".."V4" are the compiler's real generated names
; for A..E (identifiers are not preserved through compile).
; ============================================================================
TEST_CHECK_DECOMPILED:
    ld   hl, (DECOMP_OUT_PTR)
    ld   de, DECOMP_OUT_BUF
    or   a
    sbc  hl, de
    ld   de, EXPECTED_TEXT_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   hl, DECOMP_OUT_BUF
    ld   de, EXPECTED_TEXT
    ld   bc, EXPECTED_TEXT_LEN
.cmp:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    dec  bc
    ld   a, b
    or   c
    jr   nz, .cmp
    ret
.fail:
    scf
    ret

EXPECTED_TEXT:
    db "V0 = 5", 13
    db "V1 = 3", 13
    db "V2 = 0", 13
    db "V3 = 0", 13
    db "V4 = 0", 13
    db "IF (V0>V1) THEN", 13
    db "V2 = 1", 13
    db "V3 = 2", 13
    db "ENDIF", 13
    db "IF (V0<V1) THEN", 13
    db "V2 = 99", 13
    db "ENDIF", 13
    db "IF (V0<V1) THEN", 13
    db "V4 = 1", 13
    db "ELSE", 13
    db "V4 = 2", 13
    db "ENDIF", 13
    db "IF (V0>V1) THEN", 13
    db "IF (V1>0) THEN", 13
    db "V4 = 3", 13
    db "ENDIF", 13
    db "ENDIF", 13
    db "PRINT V2", 13
    db "PRINT V3", 13
    db "PRINT V4", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

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
