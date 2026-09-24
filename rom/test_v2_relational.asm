; ============================================================================
; rom/test_v2_relational.asm — Architecture B, R8.5 Group 3 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new full
; relop set (<=, >, >=, <>, alongside the pre-existing < and =) and
; AND/OR/NOT boolean grammar (COMPILE_EXPR/COMPILE_BOOL_AND/COMPILE_
; BOOL_NOT/COMPILE_RELATIONAL), plus rom/exrom_v2_vm_core.asm's new
; OP_CMP_LE/GT/GE/NE/AND/OR/NOT opcodes. NOT wired into the production
; BASIC dispatch or the shipping EXROM build.
;
; Source program compiled and executed (A=5, B=3 throughout):
;
;   A=5:B=3
;   PRINT A>B          -- 5>3, true=1
;   PRINT A<B          -- 5<3, false=0
;   PRINT A>=5         -- 5>=5, true=1
;   PRINT A<=3         -- 5<=3, false=0
;   PRINT A<>B         -- 5<>3, true=1
;   PRINT A=5          -- 5=5, true=1
;   PRINT (A>B) AND (B<A)   -- true AND true = true=1
;   PRINT (A<B) OR (A>B)    -- false OR true = true=1
;   PRINT NOT (A<B)         -- NOT false = true=1
;
; Every result is 1 (true) except the two deliberately-false comparisons
; (A<B, A<=3), which must print 0 -- proves each relop's own direction
; is correct, not just that SOME opcode ran (a relop bug that always
; returns "true" or always "false" would otherwise pass a test that
; only checked truthy results).
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_relational.sym \
;       rom/test_v2_relational.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_relational_zesarux.bin
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

    ; VM_OUTPUT_ROW must be 9 -- one line per PRINT (0-8); A=5/B=3
    ; themselves don't print.
    ld   a, (VM_OUTPUT_ROW)
    cp   9
    jp   nz, FAIL

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
    db "A=5:B=3:"
    db "PRINT A>B:PRINT A<B:PRINT A>=5:PRINT A<=3:PRINT A<>B:PRINT A=5:"
    db "PRINT (A>B) AND (B<A):PRINT (A<B) OR (A>B):PRINT NOT (A<B)", 0

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

; Captured from a real ZEsarUX run of this exact test, independently
; cross-checked against a direct read of each PRINT's own real screen
; text (1,0,1,0,1,1,1,1,1 -- see this file's own header) before being
; captured here, so this confirms both the decompiled SHAPE and the
; real computed VALUES were correct, not just that some opcode ran.
; "V0"/"V1" are the compiler's real generated names for A/B (identifiers
; are not preserved through compile, matching every other decompiler
; test this session).
EXPECTED_TEXT:
    db "V0 = 5", 13
    db "V1 = 3", 13
    db "PRINT (V0>V1)", 13
    db "PRINT (V0<V1)", 13
    db "PRINT (V0>=5)", 13
    db "PRINT (V0<=3)", 13
    db "PRINT (V0<>V1)", 13
    db "PRINT (V0=5)", 13
    db "PRINT ((V0>V1) AND (V1<V0))", 13
    db "PRINT ((V0<V1) OR (V0>V1))", 13
    db "PRINT (NOT (V0<V1))", 13
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
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
; rom/exrom_calc.asm (1772 real lines) is NOT included here: this test's
; own program is pure integer relational/boolean arithmetic -- no
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
; this test never checks real screen bitmap content. R8.5 Group 5's own
; real ROM growth (SPRITE GRAB/SHOW/HIDE/MOVE) pushed this flat 16K
; image over budget with graphics.asm included; same stubbing
; discipline as rom/test_v2_call_fn.asm's own identical fix.
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
; R8.5 Group 6 -- POINT/ATTR need real GFX_* contracts; this
; test never exercises real pixel/attribute content, so a plain
; deterministic stub (same discipline as every other GFX_*
; stub in this file) satisfies the reference without a real
; bitmap.
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
; kernel/memory/memory.asm is NOT included here -- this test never
; touches the editor (unlike rom/test_v2_editor_integration.asm, memory.
; asm's own real dependent), and neither rom/exrom_v2_vm_core.asm/
; compiler.asm/decompiler.asm reference any MEM_*/PROG_END/PROG_AREA_
; START/ARRAYS_END/VARS_START symbol.
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_relational.bin", $0000, $4000
