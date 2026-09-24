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
; shipping EXROM build.
;
; Source program compiled and executed (AFTER PRT_INSTALL has already
; registered all 3 operations):
;
;   A = 5
;   LPRINT A
;   LPRINT "HI"
;   LLIST
;
; Exercises: LPRINT's own numeric branch (resolves the internal
; "LPRINT" slot), LPRINT's own string branch (resolves the internal
; "LPRINT$" slot -- proving COMPILE_LPRINT's peek-and-dispatch shell
; picks the right one), and LLIST (argcount=0, streams the whole
; reconstructed program through DECOMP_LINE_CALLBACK). The raw hardware
; bit-bang layer (rom/printer_raster.asm) is stubbed below with a real
; recording stub (not a blind no-op) so the WHOLE real chain --
; PRT_LPRINT_NUM_EXEC/STR_EXEC/LLIST_EXEC -> PRINTER_SEND_TEXT ->
; PRINTER_SEND_CHUNK -> PRINTER_RENDER_ROW (a real GFX_CHAR_TO_FONT_
; OFFSET stub below supplies deterministic glyph data) -> PRINT_RASTER_
; ROW -- actually executes end to end under VM_RUN without touching
; real/emulated printer hardware (PRINT_RASTER_ROW's own real body
; would hang forever with no printer attached -- see rom/printer_
; raster.asm's own header); PRT_RASTER_CALL_COUNT confirms real raster
; rows were genuinely sent, not silently skipped.
;
; A SEPARATE check drives rom/exrom_v2_decompiler.asm's own new
; DECOMP_LINE_CALLBACK streaming hook directly (bypassing PRT_LLIST_
; EXEC/PRT_LINE_HOOK entirely) against the SAME compiled bytecode,
; accumulating each streamed line into a test-owned buffer, and
; confirms it reconstructs EXACTLY the same text a normal one-shot
; DECOMPILE_PROGRAM call already produced -- proving the new streaming
; mechanism (this milestone's own answer to LLIST's 400-byte DECOMP_
; OUT_BUF ceiling) doesn't change WHAT gets reconstructed, only how
; it's delivered.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_printer_module.sym \
;       rom/test_v2_printer_module.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_printer_module_zesarux.bin
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

    call EXT2_CLEAR_ALL
    call PRT_INSTALL
    jp   c, FAIL              ; a real, checked registration failure
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
    jp   nz, FAIL

    ; COMPILE_PROGRAM now sets DECOMP_END_ADDR automatically (rom/
    ; exrom_v2_compiler.asm's own new contract) -- no manual step here,
    ; deliberately, to prove that real end-to-end.

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ; Real raster rows must have been sent (LPRINT x2 + LLIST's own 4
    ; reconstructed lines, each chunk = 8 rows) -- confirms the whole
    ; chain actually ran, not merely "didn't crash".
    ld   a, (PRT_RASTER_CALL_COUNT)
    or   a
    jp   z, FAIL

    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, FAIL

    call CHECK_STREAMING_MATCHES
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
    db "A=5:LPRINT A:LPRINT ", '"', "HI", '"', ":LLIST", 0

; ============================================================================
; CHECK_DECOMPILED_TEXT — byte-for-byte against a real captured-then-
; verified rendering. LPRINT's string branch decompiles as "LPRINT$
; ..." (the internal registration name, not "LPRINT") -- a real,
; accepted decompile-fidelity quirk this project's own "valid,
; re-lexable, not necessarily byte-identical" bar already covers (same
; class as Phase 1's own synthesized L25/L30 GOTO labels): "LPRINT$
; ..." IS valid, re-lexable V2 source (it compiles via the perfectly
; ordinary generic TOK_IDENT/EXT2_LOOKUP/COMPILE_EXT_CALL path, same
; mechanism GRAB/MODE already use), just not textually identical to
; what was originally typed.
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
                        ; (real, pre-existing, unmodified behavior --
                        ; confirmed via a real ZEsarUX run, not
                        ; hand-predicted)
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; ============================================================================
; CHECK_STREAMING_MATCHES — drives DECOMP_LINE_CALLBACK directly against
; the same compiled program, accumulating each streamed line into
; STREAM_BUF, and confirms the concatenation matches EXPECTED_TEXT
; exactly (the same text CHECK_DECOMPILED_TEXT already verified via the
; normal whole-buffer path) -- proves the new streaming mechanism
; reconstructs identical content, not just "doesn't crash".
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
; instead of printing it, so this test can verify the STREAMED content
; independent of rom/ext_printer_module.asm's own PRT_LINE_HOOK.
; Destroys: AF, BC, DE, HL.
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

; STREAM_PTR/STREAM_BUF live in real RAM (test-private, matching rom/
; test_v2_group6_math.asm's own ATTR_TEST_BUF precedent), NOT inline in
; this ROM image's own code stream: addresses 0-$3FFF are real, write-
; protected ROM on this hardware/emulator (the exact bug class rom/
; test_v2_input.asm's own TEST_KEY_PTR fix already documents).
; $98D0+, safely past the relocated EXT2_TABLE's own real end ($98C8
; -- 12*14 bytes from $9820, see kernel/extensions/ext_registry.asm's
; own header) -- an earlier placement here ($9801/$9803) genuinely
; OVERLAPPED the live registry table (confirmed by address arithmetic,
; not just suspected) and happened to pass only by luck (the corrupted
; bytes weren't the ones read before the overlap occurred); fixed
; before it became a real intermittent failure.
STREAM_PTR: equ $98D0
STREAM_BUF: equ $98D2

; Test-only stubs: this file's own test program never exercises PRINT/
; BEEP/SOUND/PAUSE/INPUT -- same stubbing discipline as every other
; R8.5 v2 test this session.
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

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
; rom/exrom_calc.asm (1772 real lines) is NOT included here: this
; test's own program is pure integer arithmetic -- no float paths are
; ever exercised (matches rom/ext_printer_module.asm's own documented
; float-LPRINT limitation -- there is no float value in this program
; to lose in the first place).
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this flat 16K image doesn't have room for it alongside the full v2
; core + decompiler. GFX_CHAR_TO_FONT_OFFSET is stubbed below with a
; deterministic (not real-font) glyph -- this test's own real job is
; verifying the PRINTER module's own register marshalling/chunking/
; streaming logic, not re-proving the real font table (unmodified,
; already hardware-validated V1 code this milestone doesn't touch).
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
; no printer attached (see that file's own header). This stub records
; that a raster row was genuinely requested (PRT_RASTER_CALL_COUNT,
; checked by COLD_START above) instead of silently doing nothing, so a
; broken chain that skipped calling it would still be caught.
; Real RAM, not inline in this ROM image's own code stream -- see
; STREAM_PTR/STREAM_BUF's own identical note above.
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
MEM_FILL_ZERO:
    xor  a
    ld   (hl), a
    ld   d, h
    ld   e, l
    inc  de
    dec  bc
    ld   a, b
    or   c
    ret  z
    ldir
    ret
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"
    INCLUDE "rom/ext_printer_module.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_printer_module.bin", $0000, $4000
