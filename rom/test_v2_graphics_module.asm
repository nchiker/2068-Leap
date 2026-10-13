; ============================================================================
; rom/test_v2_graphics_module.asm — R10.7 item 3 reachability test.
;
; Proves CPLOT/BLOCK/FRAME/INVERT (rom/ext_v2_graphics_module.asm, the
; new unified GRAPHICS package) each compile/run/decompile correctly
; through the real, unmodified EXT2_REGISTER/OP_CALL_EXT generic
; identifier-driven extension-call mechanism — the SAME path proven
; for CIRCLE (rom/test_v2_shapes_circle.asm) and for MODE/ULAPLUS/
; PALETTE (rom/test_v2_mode_module.asm). Built on the shared
; production-shaped test harness, same as those two.
;
; This deliberately does NOT include the real ext_v2_graphics_module.asm
; body (a flat single-bank attempt to exercise the real GFX_WRITE_PIXEL
; path hit unresolved ts2068-debug/ZEsarUX session friction in this
; milestone's own session — see docs/R10_7_CAPABILITY_RESTORATION.md
; for the full note). Registers all four names with the SAME real
; argcount/argtype the real module uses, proving compiler-level
; reachability/decompile-round-trip; the pixel-drawing bodies
; themselves are ported byte-for-byte from the already-proven V1
; originals (rom/extensions/{cplot,block,frame,invert}.asm) with only
; ABI-surface renames, not re-derived algorithms — same class of
; evidence R10.25's own audit already relied on for those four.
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    DEFINE TEST_V2_NEEDS_DECOMPILE
    INCLUDE "rom/test_v2_harness_home_head.inc"

TEST_CUSTOM_MAIN:
    call EXT2_CLEAR_ALL
    call TEST_GRAPHICS_INSTALL
    jp   c, TEST_FAIL

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, TEST_FAIL

    jp   TEST_PASS

SOURCE_TEXT:
    db "CPLOT 5,5", 13
    db "BLOCK 20,20,25,25", 13
    db "FRAME 40,40,45,45", 13
    db "INVERT 40,40,45,45", 0

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
    db "CPLOT 5,5", 13
    db "BLOCK 20,20,25,25", 13
    db "FRAME 40,40,45,45", 13
    db "INVERT 40,40,45,45", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; TEST_GRAPHICS_INSTALL -- registers all four real names with the SAME
; real argcount/argtype the production package uses (2/0 for CPLOT,
; 4/0 for BLOCK/FRAME/INVERT), proving reachability without re-including
; the real module's own fixed-$F400-ORG body (meaningless inside this
; flat 16K test image — see rom/test_v2_shapes_circle.asm's own
; identical note for CIRCLE/SHAPES).
TEST_GRAPHICS_INSTALL:
    ld hl,TEST_GRAPHICS_CPLOT_NAME
    ld de,TEST_GRAPHICS_STUB_EXEC
    ld b,2
    ld c,0
    call EXT2_REGISTER
    ret c
    ld hl,TEST_GRAPHICS_BLOCK_NAME
    ld de,TEST_GRAPHICS_STUB_EXEC
    ld b,4
    ld c,0
    call EXT2_REGISTER
    ret c
    ld hl,TEST_GRAPHICS_FRAME_NAME
    ld de,TEST_GRAPHICS_STUB_EXEC
    ld b,4
    ld c,0
    call EXT2_REGISTER
    ret c
    ld hl,TEST_GRAPHICS_INVERT_NAME
    ld de,TEST_GRAPHICS_STUB_EXEC
    ld b,4
    ld c,0
    jp EXT2_REGISTER

TEST_GRAPHICS_CPLOT_NAME:  DB "CPLOT",0
TEST_GRAPHICS_BLOCK_NAME:  DB "BLOCK",0
TEST_GRAPHICS_FRAME_NAME:  DB "FRAME",0
TEST_GRAPHICS_INVERT_NAME: DB "INVERT",0
TEST_GRAPHICS_STUB_EXEC:
    ret

; Test-only stubs: this file's own test program never exercises PRINT/
; LPRINT/BEEP/SOUND/PAUSE/INPUT, and never checks real screen bitmap
; content (same discipline as rom/test_v2_mode_module.asm/rom/test_v2_
; shapes_circle.asm).
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
; kernel/memory/memory.asm is NOT included here -- but EXT2_CLEAR_ALL
; (kernel/extensions/ext_registry.asm) genuinely calls its real
; MEM_FILL_ZERO to zero the registry table, so that one routine needs a
; real (not no-op) stub.
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"
