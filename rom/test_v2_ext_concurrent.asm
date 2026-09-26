; ============================================================================
; rom/test_v2_ext_concurrent.asm — all 3 loadable packages registered
; concurrently (R8.5 Group 6 ROM reconciliation)
;
; Standalone ROM image proving rom/ext_sprite_module.asm (4 slots),
; rom/ext_mode_module.asm (3 slots), and rom/ext_printer_module.asm (3
; slots -- LPRINT numeric, LPRINT string, LLIST) can all be registered
; into the SAME EXT2_TABLE at once (10 of the now-12 available slots),
; and that the generic typed-argument mechanism (kernel/extensions/
; ext_registry.asm's own EXT2_REC_LEN argtypes bitmask) doesn't disturb
; existing all-numeric extensions when a string-typed one is registered
; alongside them. NOT wired into the production BASIC dispatch or the
; shipping EXROM build.
;
; Source program compiled and executed (after all 3 INSTALL routines
; have run):
;
;   GRAB 0,2,3,2,2
;   SHOW 0,2,3
;   MODE 1
;   A=5
;   LPRINT A
;   HIDE 0
;
; Deliberately interleaves numeric-only extensions from the sprite
; module (GRAB/SHOW), a numeric-only extension from a DIFFERENT module
; (MODE), the new typed extension (LPRINT, numeric branch), and back to
; the first module (HIDE, which needs the sprite actually SHOWn first --
; SHOW included for exactly that reason) -- proves slot/generation
; resolution and argtype dispatch stay correct across modules, not just
; within one.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_ext_concurrent.sym \
;       rom/test_v2_ext_concurrent.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_ext_concurrent_zesarux.bin
;   ts2068-debug run --max-instructions 3000000
;   ts2068-debug timex   (border field)
; ============================================================================
; KNOWN LIMITATION (R8.5 Group 6, DIMN) -- same flat-16K test-harness
; scaling wall rom/test_v2_call_fn.asm and rom/test_v2_print.asm's own
; headers already document (see either for the full reasoning): this
; test includes the full vm_core+compiler+decompiler PLUS all 3
; loadable packages (sprite+mode+printer), already the largest content
; combination in this test suite, and DIMN's own real (if small) growth
; was enough to tip it 97 bytes past $4000 -- sjasmplus_strict.sh
; refuses the truncated image. EXCLUDED from the buildable regression
; set until R9 (V1 removal) or a harness redesign frees real headroom.
; This test's own real coverage last built and passed at commit
; 4ece512 (R8.5 Group 6's string-result-function commit) -- presumed
; still correct, not re-verified since.
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
    call SPR_INSTALL
    jp   c, FAIL
    call MODE_INSTALL
    jp   c, FAIL
    call PRT_INSTALL
    jp   c, FAIL

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

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ; real state checks: sprite's own GRAB+HIDE ran (DEFINED=1, SHOWN=0
    ; -- HIDE ran last -- W/H=2), and LPRINT genuinely reached the
    ; raster layer
    ld   a, (SPRITE_SLOT_DEFINED)
    cp   1
    jp   nz, FAIL
    ld   a, (SPRITE_SLOT_SHOWN)
    or   a
    jp   nz, FAIL
    ld   a, (SPRITE_SLOT_W)
    cp   2
    jp   nz, FAIL
    ld   a, (PRT_RASTER_CALL_COUNT)
    or   a
    jp   z, FAIL

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
    db "GRAB 0,2,3,2,2:SHOW 0,2,3:MODE 1:A=5:LPRINT A:HIDE 0", 0

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
    db "GRAB 0,2,3,2,2", 13
    db "SHOW 0,2,3", 13
    db "MODE 1", 13
    db "V0 = 5", 13
    db "LPRINT V0", 13
    db "HIDE 0", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stubs -- same discipline as every other R8.5 v2 test.
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
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here --
; this flat 16K image doesn't have room for it alongside the full v2
; core + decompiler + 3 loadable modules. GFX_SPRITE_CAPTURE/DRAW are
; real, pre-existing, hardware-validated V1 code already proven by rom/
; test_v2_sprite_module.asm; GFX_CHAR_TO_FONT_OFFSET is stubbed
; deterministically (this test's own job is the CONCURRENT-registration
; mechanism, not re-proving individual modules' own real GFX behavior,
; already covered by their own dedicated tests).
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
; rom/printer_raster.asm is NOT included here -- see rom/test_v2_
; printer_module.asm's own identical header note (real hardware hang
; risk with no printer attached).
; Real RAM, not inline in this ROM image's own code stream. $98D0,
; safely past the relocated EXT2_TABLE's own real end ($98C8 -- 12*14
; bytes from $9820, see kernel/extensions/ext_registry.asm's own
; header) and past SPR_SLOT's own block ($9800-$980B).
PRT_RASTER_CALL_COUNT: equ $98D0
PRINTER_MOTOR_STOP:
    ret
PRINT_RASTER_ROW:
    ld   a, (PRT_RASTER_CALL_COUNT)
    inc  a
    ld   (PRT_RASTER_CALL_COUNT), a
    ret
; kernel/memory/memory.asm is NOT included here -- but EXT2_CLEAR_ALL
; genuinely calls its real MEM_FILL_ZERO.
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
    INCLUDE "rom/ext_sprite_module.asm"
    INCLUDE "rom/ext_mode_module.asm"
    INCLUDE "rom/ext_printer_module.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_ext_concurrent.bin", $0000, $4000
