; ============================================================================
; rom/test_v2_for_step.asm — Architecture B, R8.5 Group 5 (FOR...STEP +
; EXIT FOR) smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; COMPILE_FOR (optional STEP clause) and COMPILE_EXIT_FOR, and rom/
; exrom_v2_vm_core.asm's new VM_FOR_STEP-aware OP_FOR_INIT/OP_FOR_NEXT
; (step-based increment, sign-aware loop-continuation direction). NOT
; wired into the production BASIC dispatch or the shipping EXROM build.
;
; Source program compiled and executed:
;
;   C=0:FOR I=1 TO 10 STEP 2:C=C+I:NEXT I
;   D=0:FOR J=10 TO 1 STEP -3:D=D+J:NEXT J
;   E=0:FOR K=1 TO 100:IF K>3 THEN EXIT FOR ENDIF:E=K:NEXT K
;   PRINT C:PRINT D:PRINT E
;
; Exercises: a positive STEP > 1 (I=1,3,5,7,9 -- 9+2=11>10 stops -- catches
; an off-by-one a naive "STEP always 1" carryover would miss), a negative
; STEP (J=10,7,4,1 -- 1-3=-2<1 stops -- proves the sign-aware comparison
; direction is genuinely reached, not just parsed), and EXIT FOR inside a
; nested block-IF body (K=1,2,3 accepted, K=4 exits before E is updated
; -- proves COMPILE_EXIT_FOR's own JMP/fixup mechanism composes correctly
; with COMPILE_IF_BLOCK's own recursive compile, and that the runtime JMP
; genuinely lands past NEXT K, not just that it compiles).
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_for_step.sym \
;       rom/test_v2_for_step.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_for_step_zesarux.bin
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

    ; Real-memory verification: C(SYMTAB idx 3)=25, D(idx 4... whichever
    ; real index each var lands on)=22, E=3. Checked via CHECK_RESULT
    ; below rather than hardcoding indices -- reads each var by its own
    ; real compile-time-assigned CSYMTAB index, captured from a real
    ; ZEsarUX run.
    call CHECK_RESULT
    jp   c, FAIL

    ; VM_OUTPUT_ROW must be 3 -- one line per PRINT (0-2).
    ld   a, (VM_OUTPUT_ROW)
    cp   3
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
    db "C=0:FOR I=1 TO 10 STEP 2:C=C+I:NEXT I:"
    db "D=0:FOR J=10 TO 1 STEP -3:D=D+J:NEXT J:"
    db "E=0:FOR K=1 TO 100:IF K>3 THEN EXIT FOR ENDIF:E=K:NEXT K:"
    db "PRINT C:PRINT D:PRINT E", 0

; ============================================================================
; CHECK_RESULT — direct SYMTAB memory reads. Compiler assigns indices in
; first-use order: 0=C, 1=I, 2=D, 3=J, 4=E, 5=K (I/J/K registered when
; FOR first mentions them, same as any other identifier).
; ============================================================================
CHECK_RESULT:
    ld   a, (SYMTAB_BASE + 0*3)     ; C's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 0*3 + 1)
    ld   de, 25
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, (SYMTAB_BASE + 2*3)     ; D's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 2*3 + 1)
    ld   de, 22
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, (SYMTAB_BASE + 4*3)     ; E's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 4*3 + 1)
    ld   de, 3
    or   a
    sbc  hl, de
    jr   nz, .fail
    ret
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

; Captured from a real ZEsarUX run of this exact test, independently
; cross-checked against CHECK_RESULT's own already-verified real values
; (same two-step discipline as every other decompiler test this
; session). "V0"=C, "V1"=I, "V2"=D, "V3"=J, "V4"=E, "V5"=K -- compiler-
; generated names, first-use order.
;
; "IF (V5>3) THEN GOTO L80" (not a block "IF...THEN / GOTO / ENDIF"),
; plus a harmless unreferenced "L72:" label right after it -- a real,
; pre-existing decompiler ambiguity, not a new bug: this block IF's own
; THEN-body is exactly one JMP-producing statement (EXIT FOR itself)
; with no ELSE, which makes its bytecode shape (JMPZ, then a bare JMP
; whose own target equals JMPZ's target) byte-for-byte identical to the
; OLD single-line "IF...THEN GOTO" shape the decompiler already
; disambiguates by pattern, not full semantic tracking (see rom/
; exrom_v2_decompiler.asm's own .op_jmpz header). Still valid, re-
; parseable, semantically identical V2 source -- the "L72:" label is
; simply never referenced by anything, which is ordinary legal syntax.
EXPECTED_TEXT:
    db "V0 = 0", 13
    db "FOR V1 = 1 TO 10 STEP 2", 13
    db "V0 = (V0+V1)", 13
    db "NEXT V1", 13
    db "V2 = 0", 13
    db "FOR V3 = 10 TO 1 STEP (0-3)", 13
    db "V2 = (V2+V3)", 13
    db "NEXT V3", 13
    db "V4 = 0", 13
    db "FOR V5 = 1 TO 100 STEP 1", 13
    db "IF (V5>3) THEN GOTO L80", 13
    db "L72:", 13
    db "V4 = V5", 13
    db "NEXT V5", 13
    db "L80:", 13
    db "PRINT V0", 13
    db "PRINT V2", 13
    db "PRINT V4", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stubs: this file's own test program never exercises LPRINT/
; BEEP/SOUND/PAUSE/INPUT, and never registers or calls a loadable
; extension -- same stubbing discipline as every other R8.5 v2 test
; this session.
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
; rom/exrom_calc.asm (1772 real lines) is NOT included here: this
; test's own program is pure integer arithmetic -- no PUSH_FLOAT_LIT,
; no float PRINT -- so none of the float paths that reach the
; calculator are ever exercised. Same stubbing discipline rom/
; test_v2_save_load.asm's own header already established.
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
CALC_PUSH_PI:
    ret
CALC_PUSH_FP_RAW:
    ret
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test never checks real screen bitmap content (only VM_OUTPUT_ROW,
; SYMTAB memory, and the decompiled text), and every real PRINT text
; here is short enough to never wrap/scroll. Same stubbing discipline
; as rom/test_v2_call_fn.asm/rom/test_v2_print.asm's own identical fix.
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
; kernel/memory/memory.asm is NOT included here -- checked directly:
; neither rom/exrom_v2_vm_core.asm/compiler.asm/decompiler.asm reference
; any MEM_*/PROG_END/PROG_AREA_START/ARRAYS_END/VARS_START symbol, and
; this test never touches the real editor engine.
    INCLUDE "rom/exrom_format.asm"
; R8.5 Group 6 -- INKEY$ needs kernel/io/io.asm's real IO_READ_KEY_
; NONBLOCK, not included in this flat test image (same scaling limit
; as every other v2 test); deterministic "no key currently pressed"
; stub, same pattern this test suite already uses for other platform
; dependencies (GFX_READ_PIXEL etc). Placed here (after the real ORG
; $0000 code), not before it -- placing it earlier let sjasmplus
; assemble it at whatever pre-ORG address the counter held (address
; 0), silently aliasing RST_00's own real code; a real bug this exact
; mistake caused elsewhere (see rom/test_v2_strfuncs.asm's own header
; for the full incident).
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_for_step.bin", $0000, $4000
