; ============================================================================
; rom/test_v2_printer_module.asm — loadable LPRINT/LLIST package smoke
; test (R8.5 Group 6 ROM reconciliation)
;
; Standalone ROM image exercising rom/ext_printer_module.asm's LPRINT
; (numeric + string) and LLIST, registered through the EXISTING R7.5
; mechanism (kernel/extensions/ext_registry.asm) exactly like rom/
; ext_sprite_module.asm/rom/ext_mode_module.asm already established --
; see rom/ext_printer_module.asm's own header for the full architecture
; (typed arguments, the streaming LLIST design, the float-LPRINT
; limitation). NOT wired into the production BASIC dispatch or the
; shipping EXROM build. Built on the shared production-shaped test
; harness (rom/test_v2_harness_home_head.inc/_tail.inc + rom/
; test_v2_harness_exrom.asm) -- see that harness's own header for why
; (post-semantic-milestone test-infrastructure fix, docs/
; POST_R9_TEST_INFRASTRUCTURE.md).
;
; Source program compiled and executed (AFTER PRT_INSTALL has already
; registered all 3 operations):
;
;   A = 5
;   LPRINT A
;   LPRINT "HI"
;   LLIST
;
; Exercises: LPRINT's own numeric branch, LPRINT's own string branch,
; and LLIST (argcount=0, streams the whole reconstructed program
; through DECOMP_LINE_CALLBACK). The raw hardware bit-bang layer (rom/
; printer_raster.asm) is stubbed below with a real recording stub (not
; a blind no-op) so the WHOLE real chain actually executes end to end
; under VM_RUN without touching real/emulated printer hardware;
; PRT_RASTER_CALL_COUNT confirms real raster rows were genuinely sent.
;
; A SEPARATE check drives rom/exrom_v2_decompiler.asm's own DECOMP_LINE_
; CALLBACK streaming hook directly (bypassing PRT_LLIST_EXEC/PRT_LINE_
; HOOK entirely) against the SAME compiled bytecode, accumulating each
; streamed line into a test-owned buffer, and confirms it reconstructs
; EXACTLY the same text a normal one-shot DECOMPILE_PROGRAM call
; already produced.
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    DEFINE TEST_V2_NEEDS_DECOMPILE
    INCLUDE "rom/test_v2_harness_home_head.inc"

TEST_CUSTOM_MAIN:
    call EXT2_CLEAR_ALL
    call PRT_INSTALL
    jp   c, TEST_FAIL         ; a real, checked registration failure
                              ; path, not assumed to always succeed

    xor  a
    ld   (PRT_RASTER_CALL_COUNT), a

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    ; COMPILE_PROGRAM sets DECOMP_END_ADDR automatically -- no manual
    ; step here, deliberately, to prove that real end-to-end.

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    ; Real raster rows must have been sent (LPRINT x2 + LLIST's own 4
    ; reconstructed lines, each chunk = 8 rows) -- confirms the whole
    ; chain actually ran, not merely "didn't crash".
    ld   a, (PRT_RASTER_CALL_COUNT)
    or   a
    jp   z, TEST_FAIL

    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, TEST_FAIL

    call CHECK_STREAMING_MATCHES
    jp   c, TEST_FAIL

    jp   TEST_PASS

SOURCE_TEXT:
    db "A=5:LPRINT A:LPRINT ", '"', "HI", '"', ":LLIST", 0

; ============================================================================
; CHECK_DECOMPILED_TEXT — byte-for-byte against a real captured-then-
; verified rendering. LPRINT's string branch decompiles as "LPRINT$
; ..." (the internal registration name, not "LPRINT") -- a real,
; accepted decompile-fidelity quirk this project's own "valid,
; re-lexable, not necessarily byte-identical" bar already covers.
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

EXPECTED_TEXT:
    db "V0 = 5", 13
    db "LPRINT V0", 13
    db 'LPRINT$ "HI"', 13
    db "LLIST ", 13   ; .op_call_ext always emits a trailing space
                        ; after the name before checking argcount==0
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; ============================================================================
; CHECK_STREAMING_MATCHES — drives DECOMP_LINE_CALLBACK directly against
; the same compiled program, accumulating each streamed line into
; STREAM_BUF, and confirms the concatenation matches EXPECTED_TEXT
; exactly.
; ============================================================================
CHECK_STREAMING_MATCHES:
    ld   hl, STREAM_BUF
    ld   (STREAM_PTR), hl
    ld   hl, STREAM_LINE_HOOK
    ld   (DECOMP_LINE_CALLBACK), hl
    call DECOMPILE_PROGRAM
    ld   hl, 0
    ld   (DECOMP_LINE_CALLBACK), hl
    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jr   nz, .fail
    ld   hl, (STREAM_PTR)
    ld   de, STREAM_BUF
    or   a
    sbc  hl, de
    ld   de, EXPECTED_TEXT_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   hl, STREAM_BUF
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

; STREAM_LINE_HOOK -- test-owned DECOMP_LINE_CALLBACK target: copies
; DECOMP_OUT_BUF[0..DECOMP_LINE_LEN) to the next free spot in STREAM_BUF
; instead of printing it. Destroys: AF, BC, DE, HL.
STREAM_LINE_HOOK:
    ld   a, (DECOMP_LINE_LEN)
    ld   c, a
    ld   b, 0
    ld   hl, DECOMP_OUT_BUF
    ld   de, (STREAM_PTR)
.copy:
    ld   a, b
    or   c
    jr   z, .done
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    dec  bc
    jr   .copy
.done:
    ld   (STREAM_PTR), de
    ret

; STREAM_PTR/STREAM_BUF live in real RAM (test-private), NOT inline in
; this ROM image's own code stream: addresses 0-$3FFF are real, write-
; protected ROM on this hardware/emulator. $98D0+, safely past the
; relocated EXT2_TABLE's own real end ($98C8 -- 12*14 bytes from $9820,
; see kernel/extensions/ext_registry.asm's own header).
STREAM_PTR: equ $98D0
STREAM_BUF: equ $98D2

DECOMP_LINE_CALLBACK: equ $BDAC   ; RAM, matches rom/exrom_v2_decompiler.
                                   ; asm's own real equ exactly (checked
                                   ; directly)
DECOMP_LINE_LEN: equ $BDAE

; Test-only stubs: this file's own test program never exercises PRINT/
; BEEP/SOUND/PAUSE/INPUT.
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

; kernel/graphics/graphics.asm (2235 real lines) is NOT included here.
; GFX_CHAR_TO_FONT_OFFSET is stubbed below with a deterministic
; (not real-font) glyph -- this test's own real job is verifying the
; PRINTER module's own register marshalling/chunking/streaming logic,
; not re-proving the real font table.
GFX_CHAR_TO_FONT_OFFSET:
    ld   hl, DUMMY_GLYPH
    or   a
    ret
DUMMY_GLYPH: ds 8, $AA
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
; rom/printer_raster.asm (the real PORT_PRINTER bit-bang layer) is NOT
; included here -- its own real `.wait_paper` poll spins forever with
; no printer attached. This stub records that a raster row was
; genuinely requested (PRT_RASTER_CALL_COUNT, checked above) instead of
; silently doing nothing.
PRT_RASTER_CALL_COUNT: equ $9800
PRINTER_MOTOR_STOP:
    ret
PRINT_RASTER_ROW:
    ld   a, (PRT_RASTER_CALL_COUNT)
    inc  a
    ld   (PRT_RASTER_CALL_COUNT), a
    ret
; kernel/memory/memory.asm is NOT included here -- but EXT2_CLEAR_ALL
; genuinely calls its real MEM_FILL_ZERO, so that one routine needs a
; real (not no-op) stub.
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret
    INCLUDE "rom/ext_printer_module.asm"

    INCLUDE "rom/test_v2_harness_home_tail.inc"
