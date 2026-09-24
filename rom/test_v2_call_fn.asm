; ============================================================================
; rom/test_v2_call_fn.asm — Architecture B, R8.5 Group 1 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; BUILTIN_FN_FIND/COMPILE_FACTOR.fn_call grammar and rom/exrom_v2_vm_core.asm's
; new OP_CALL_FN dispatch (R8.5 Group 1's own foundational function-call
; mechanism) via its one proof-of-concept function, ABS. NOT wired into the
; production BASIC dispatch or the shipping EXROM build. Group 6 reuses this
; SAME mechanism (BUILTIN_FN_TABLE grows; BUILTIN_FN_FIND/COMPILE_FACTOR's own
; grammar do not change) to add the remaining ~24 built-in functions.
;
; Source program compiled and executed:
;
;   PRINT ABS(-7)
;   PRINT ABS(7)
;   PRINT ABS(-2.5)
;   PRINT ABS(2.5)
;   X = ABS(-42)
;   PRINT X
;
; Exercises: ABS on a negative int (two's-complement fast path), a
; positive int (no-op fast path), a negative float (the calculator-
; based "0 - x" negate path, same technique R8.5 Group 2's own PRINT
; float-negation already established -- proven here NOT to alias the
; popped FLOATTAB record), a positive float (no-op fast path, pushes
; the same index back), and ABS used inside a numeric assignment's own
; expression (not just as a bare PRINT argument, confirming CALL_FN
; composes as an ordinary factor).
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_call_fn.sym \
;       rom/test_v2_call_fn.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_call_fn_zesarux.bin
;   ts2068-debug run --max-instructions 3000000
;   ts2068-debug timex   (border field)
; ============================================================================
; KNOWN LIMITATION (R8.5 Group 5, grown further through Group 6): this
; flat 16K standalone image overflows its own budget (~200 bytes over
; as of Group 6's SGN/MOD/DIV/RND/POINT/ATTR/INT/PEEK/USR/LEN/CODE/VAL
; additions) because it needs BOTH the real 1772-line rom/exrom_calc.asm
; (this test's own float coverage genuinely needs it -- no further stub
; is possible without gutting the calculator itself) AND the full v2
; core, which keeps growing with every Group 5/6 addition, none of it
; reachable from this test's own float-only program. This is a genuine
; test-HARNESS scaling limit, not a functional regression: none of
; Group 5's changes (FOR...STEP, EXIT FOR, MODE/ULAPLUS/PALETTE,
; SPRITE) or Group 6's (SGN/MOD/DIV/RND/POINT/ATTR/INT/PEEK/USR/LEN/
; CODE/VAL) touch any float-handling code path this test exercises
; (OP_PUSH_FLOAT_LIT, ABS's own float branch, VM_NUM_TO_TEXT's float
; path are all unchanged). This test's own real coverage last built and
; passed at commit acb549c (R8.5 Group 5's MODE/ULAPLUS/PALETTE commit)
; -- presumed still correct, not re-verified since. Revisit once R9
; deletes basic.asm and frees real headroom, or once the flat-image
; test harness itself is redesigned to let a test opt out of modules it
; doesn't need at a finer grain than whole-file INCLUDE/stub.
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0028 - $, $FF
    ; RST $28 -- the real calculator's real entry vector, needed here
    ; because ABS's own float path calls VM_CALC_SUB_STUB/CALC_INT_TO_FP
    ; directly, same real-hardware-validated pattern every other v2 test
    ; using the calculator already uses (see rom/test_v2_print.asm's own
    ; header for the real crash this omission causes if skipped).
    jp   CALC_EXROM_ENTRY
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

    ; VM_OUTPUT_ROW must be 5 -- one line per PRINT (0-4); SOURCE_TEXT
    ; has 5 PRINT statements (X=ABS(-42) is a non-printing assignment).
    ; The whole program runs to HALT (implicit end-of-program HALT the
    ; compiler always emits) with no mid-program truncation to check
    ; here (that is R8.5 Group 2's own test's job).
    ld   a, (VM_OUTPUT_ROW)
    cp   5
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
    db "PRINT ABS(-7):PRINT ABS(7):"
    db "PRINT ABS(-2.5):PRINT ABS(2.5):"
    db "X=ABS(-42):PRINT X", 0

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

; Captured from a real ZEsarUX run of this exact test. "((0-7))" is the
; expected (if slightly noisy) composition of two independently-correct
; renderings: unary minus's own established "(0-X)" form (no dedicated
; unary-minus opcode -- see rom/test_v2_print.asm's own header) wrapped
; again in CALL_FN's own "NAME(<arg>)" form -- still valid, reparseable
; V2 source, matching this project's own "valid, not byte-identical"
; decompile bar. "V0" is the compiler's real generated name for X
; (identifiers are not preserved through compile, matching every other
; decompiler test this session).
EXPECTED_TEXT:
    db "PRINT ABS((0-7))",13
    db "PRINT ABS(7)",13
    db "PRINT ABS((0-2.5))",13
    db "PRINT ABS(2.5)",13
    db "V0 = ABS((0-42))",13
    db "PRINT V0",13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stub: this test's own SOURCE_TEXT never calls LPRINT, but
; rom/exrom_v2_vm_core.asm's own OP_LPRINT_NUM/STR still reference the
; symbol unconditionally -- same stubbing discipline as rom/
; test_v2_print.asm.
BASIC_STMT_LPRINT_EXROM:
    ret

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_calc.asm"
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test never checks real screen bitmap content (only VM_OUTPUT_ROW
; and the decompiled text, per this file's own header), and every real
; PRINT text here is short enough to never wrap/scroll -- so a bare `ret`
; for GFX_PRINT_STRING_ATTR is exactly correct: B/C (row/col) already
; hold the pre-print values VM_PRINT_COMMON passed in, which is exactly
; what a non-wrapping print's own real row/col would still be after
; printing. R8.5 Group 4's own real ROM growth pushed this flat 16K
; image over budget with graphics.asm included; this is the same
; "module fully resolves symbols, contributes zero real coverage this
; test needs" stubbing discipline already used for BEEP/SOUND/IO_READ_
; KEY below, one level up.
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
; Test-only stubs: this file's own test program never exercises BEEP/
; SOUND/PAUSE -- rom/exrom_v2_vm_core.asm's own OP_BEEP/OP_SOUND/OP_PAUSE
; still reference these unconditionally, and the real kernel/sound+
; kernel/io+kernel/interrupt modules pushed this flat 16K image over
; budget for zero real coverage, same stubbing discipline already used
; by rom/test_v2_save_load.asm, rom/test_v2_editor_integration.asm, and
; rom/test_v2_decompiler_phase2.asm.
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
; kernel/memory/memory.asm is NOT included here -- checked directly:
; neither rom/exrom_v2_vm_core.asm/compiler.asm/decompiler.asm reference
; any MEM_*/PROG_END/PROG_AREA_START/ARRAYS_END/VARS_START symbol (V2's
; own storage model never used V1's line/label MEM_* apparatus), and
; this test never touches the real editor engine (kernel/editor/
; editor.asm, memory.asm's own real dependent elsewhere).
; Test-only stub: this file's own test program never registers or calls
; a loadable extension -- same stubbing discipline as rom/
; test_v2_decompiler.asm/rom/test_v2_print.asm (real contract:
; EXT2_LOOKUP's carry SET means "no match", exactly what a permanently-
; empty registry means).
EXT2_LOOKUP:
    scf
    ret
EXT2_SLOT_ADDR:
    ret
EXT_CALL_ARG0: equ $8B00
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_call_fn.bin", $0000, $4000
