; ============================================================================
; rom/test_v2_block_if.asm — Architecture B, R8.5 Group 3 block IF test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; COMPILE_IF_BLOCK (IF <cond> THEN <body> [ELSE <body>] ENDIF), built on
; top of COMPILE_STATEMENT_LIST's own recursive reuse (same mechanism
; already proven for PROC bodies). NOT wired into the production BASIC
; dispatch or the shipping EXROM build.
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
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_block_if.sym \
;       rom/test_v2_block_if.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_block_if_zesarux.bin
;   ts2068-debug run --max-instructions 3000000
;   ts2068-debug timex   (border field)
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ld   a, (VM_OUTPUT_ROW)
    cp   3
    jp   nz, FAIL

    ; Symbol declaration order (first appearance): 0=A 1=B 2=C 3=D 4=E.
    ld   hl, SYMTAB_BASE + 2*SYM_REC_LEN
    ld   de, 1
    call CHECK_SYM               ; C == 1
    jp   c, FAIL
    ld   hl, SYMTAB_BASE + 3*SYM_REC_LEN
    ld   de, 2
    call CHECK_SYM               ; D == 2
    jp   c, FAIL
    ld   hl, SYMTAB_BASE + 4*SYM_REC_LEN
    ld   de, 3
    call CHECK_SYM               ; E == 3
    jp   c, FAIL

    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

SOURCE_TEXT:
    db "A=5:B=3:C=0:D=0:E=0:"
    db "IF A>B THEN C=1:D=2 ENDIF:"
    db "IF A<B THEN C=99 ENDIF:"
    db "IF A<B THEN E=1 ELSE E=2 ENDIF:"
    db "IF A>B THEN IF B>0 THEN E=3 ENDIF ENDIF:"
    db "PRINT C:PRINT D:PRINT E", 0

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
; CHECK_DECOMPILED_TEXT — byte-for-byte against a real captured-then-
; verified rendering (same discipline as every other decompiler test
; this session).
; ============================================================================
CHECK_DECOMPILED_TEXT:
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

; Captured from a real ZEsarUX run of this exact test, after fixing two
; real bugs this test's own first run found (both documented at length
; in rom/exrom_v2_compiler.asm's own COMPILE_IF_BLOCK header and rom/
; exrom_v2_decompiler.asm's own DECOMP_CHECK_ENDIF_HERE header): (1)
; IF_SKIP_PATCH_TMP/IF_ELSE_SKIP_PATCH_TMP being single shared memory
; cells clobbered by a nested IF's own recursive compile, leaving the
; outer IF's own JMPZ target unpatched (stuck at placeholder 0); (2)
; two ENDIF markers landing at the exact same address (the nested-IF
; case below, where the inner IF is the outer's only THEN-body
; statement) concatenating into the un-reparseable "ENDIFENDIF" instead
; of two separate lines. "V0".."V4" are the compiler's real generated
; names for A..E (identifiers are not preserved through compile,
; matching every other decompiler test this session).
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
; BEEP/SOUND/PAUSE, and never registers or calls a loadable extension --
; same stubbing discipline (and same real contracts) already established
; for the other R8.5 v2 tests this session.
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
EXT2_TABLE:    equ $8B00

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
; rom/exrom_calc.asm (1772 real lines) is NOT included here: this test's
; own program is pure integer block-IF/relational arithmetic -- no
; PUSH_FLOAT_LIT, no float PRINT -- so none of the float paths that
; reach the calculator are ever exercised. R8.5 Group 4's own real ROM
; growth pushed this flat 16K image over budget with the real
; calculator included; same stubbing discipline rom/test_v2_save_load.
; asm's own header already established for this exact tradeoff.
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test never checks real screen bitmap content (only SYMTAB memory
; and the decompiled text). R8.5 Group 5's own real ROM growth pushed
; this flat 16K image over budget with graphics.asm included; same
; stubbing discipline as rom/test_v2_call_fn.asm's own identical fix.
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
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_block_if.bin", $0000, $4000
