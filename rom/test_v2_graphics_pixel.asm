; ============================================================================
; rom/test_v2_graphics_pixel.asm — closes the pixel-level validation gap
; flagged in docs/R10_7_CAPABILITY_RESTORATION.md section 3 and
; docs/R10_7_CAPACITY_ARCHITECTURE_AUDIT.md's graphics follow-up: proves
; CPLOT/BLOCK/FRAME/INVERT (rom/ext_v2_graphics_module.asm) write the exact
; expected bitmap/attribute bytes through the REAL production call path —
; EXT2_REGISTER -> OP_CALL_EXT -> GRAPHICS_*_EXEC -> the real
; kernel/graphics/graphics.asm GFX_WRITE_PIXEL/GFX_SET_ATTR — not a stub.
;
; Earlier attempts (see docs/R10_7_CAPABILITY_RESTORATION.md section 3)
; used either a flat single-bank image (too small to host vm_core+compiler+
; the real graphics.asm together) or the shared two-bank harness WITH
; GFX_WRITE_PIXEL stubbed out (rom/test_v2_graphics_module.asm — proves only
; compile/decompile reachability, never real pixel output). This file is
; built on the SAME proven two-bank harness (rom/test_v2_harness_home_head.
; inc/_tail.inc + rom/test_v2_harness_exrom.asm) as every other v2 test, but
; includes kernel/graphics/graphics.asm and kernel/extensions/ext_registry.
; asm for REAL (not stubbed), plus the real rom/ext_v2_graphics_module.asm
; body — the missing piece, not a new harness mechanism.
;
; All expected byte/attribute values below were computed independently in
; Python from the documented, independently-verified standard ZX Spectrum
; screen-addressing formula (kernel/graphics/graphics.asm's own header:
; "$4000 | (y&$C0)<<5 | (y&$07)<<8 | (y&$38)<<2 | x>>3", attribute =
; $5800 + row*32 + col), not copied from this ROM's own output — an
; independent oracle, not a tautology.
;
; Test attribute fixed at CURRENT_INK=2, CURRENT_PAPER=5, FLASH/BRIGHT/
; INVERSE/OVER=0 for BLOCK/FRAME/CPLOT (OVER is irrelevant to the OR-vs-XOR
; bitmap question when starting from an all-zero bitmap, since OR and XOR
; against 0 are identical — the real discriminator tested is INVERT forcing
; GFX_G_OVER=1 regardless of CURRENT_OVER, proven by the double-INVERT
; restore check below). VM_COMPUTE_PRINT_ATTR's real formula (rom/exrom_v2_
; vm_core.asm) for these inputs: (PAPER<<3)|INK = (5<<3)|2 = $2A (42).
;
; GFX_CLS (real routine) is used between sub-tests both to clear the bitmap
; to 0 and to re-paint attributes to ATTR_DEFAULT ($38) — distinct from the
; test attribute ($2A), so every observed $2A in the fixture tables below is
; proof the operation under test wrote it, not a pre-existing value.
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    DEFINE TEST_V2_NEEDS_DECOMPILE
    INCLUDE "rom/test_v2_harness_home_head.inc"

TEST_CUSTOM_MAIN:
    xor  a
    ld   (GFX_MODE),a          ; force standard (non-extended) video mode
    ld   a,2
    ld   (CURRENT_INK),a
    ld   a,5
    ld   (CURRENT_PAPER),a
    xor  a
    ld   (CURRENT_FLASH),a
    ld   (CURRENT_BRIGHT),a
    ld   (CURRENT_INVERSE),a
    ld   (CURRENT_OVER),a

    call EXT2_CLEAR_ALL
    call GRAPHICS_INSTALL      ; the REAL package entry point
    jp   c,TEST_FAIL

    ; --- CPLOT 1,1 -> coarse block (4,4)-(7,7) -------------------------
    call GFX_CLS
    ld   hl,SRC_CPLOT1
    call RUN_ONE_LINE
    jp   c,TEST_FAIL
    ld   hl,CPLOT1_EXPECT_TABLE
    ld   b,CPLOT1_EXPECT_COUNT
    call CHECK_BYTE_TABLE
    jp   c,TEST_FAIL

    ; --- CPLOT 70,50 -> clamped to coarse (63,47), screen's bottom-right
    ;     corner (also exercises CPLOT's own clamp path) ----------------
    call GFX_CLS
    ld   hl,SRC_CPLOT2
    call RUN_ONE_LINE
    jp   c,TEST_FAIL
    ld   hl,CPLOT2_EXPECT_TABLE
    ld   b,CPLOT2_EXPECT_COUNT
    call CHECK_BYTE_TABLE
    jp   c,TEST_FAIL

    ; --- BLOCK 10,10,20,20 -> filled rectangle -------------------------
    call GFX_CLS
    ld   hl,SRC_BLOCK
    call RUN_ONE_LINE
    jp   c,TEST_FAIL
    ld   hl,BLOCK_EXPECT_TABLE
    ld   b,BLOCK_EXPECT_COUNT
    call CHECK_BYTE_TABLE
    jp   c,TEST_FAIL

    ; --- FRAME 10,10,20,20 -> outline only (must differ from BLOCK's
    ;     filled pattern at the same coordinates) -----------------------
    call GFX_CLS
    ld   hl,SRC_FRAME
    call RUN_ONE_LINE
    jp   c,TEST_FAIL
    ld   hl,FRAME_EXPECT_TABLE
    ld   b,FRAME_EXPECT_COUNT
    call CHECK_BYTE_TABLE
    jp   c,TEST_FAIL

    ; --- INVERT 10,10,20,20 once -> matches BLOCK's own bitmap pattern
    ;     (XOR against an all-zero bitmap equals OR) --------------------
    call GFX_CLS
    ld   hl,SRC_INVERT
    call RUN_ONE_LINE
    jp   c,TEST_FAIL
    ld   hl,INVERT1_EXPECT_TABLE
    ld   b,INVERT1_EXPECT_COUNT
    call CHECK_BYTE_TABLE
    jp   c,TEST_FAIL

    ; --- INVERT 10,10,20,20 AGAIN (no CLS in between) -> every pixel bit
    ;     XORed a second time restores the original (all-zero) bitmap;
    ;     the attribute is unconditionally re-set both times (GFX_WRITE_
    ;     PIXEL's own documented always-set-attr behavior), so it stays
    ;     $2A rather than reverting to ATTR_DEFAULT -------------------
    ld   hl,SRC_INVERT
    call RUN_ONE_LINE
    jp   c,TEST_FAIL
    ld   hl,INVERT2_EXPECT_TABLE
    ld   b,INVERT2_EXPECT_COUNT
    call CHECK_BYTE_TABLE
    jp   c,TEST_FAIL

    jp   TEST_PASS

; RUN_ONE_LINE -- HL = zero-terminated source line. Compiles and runs it
; through the real compiler/VM (same call sequence every other v2 test
; uses). Out: carry set on any compile or runtime error.
RUN_ONE_LINE:
    ld   (SRC_PTR),hl
    call COMPILER_INIT
    ld   hl,VM_CODE_BASE
    ld   (EMIT_PTR),hl
    call COMPILE_PROGRAM
    ld   a,(COMPILE_ERROR_CODE)
    or   a
    jr   nz,.fail
    call VM_INIT
    ld   hl,VM_CODE_BASE
    ld   (VM_IP),hl
    call VM_RUN
    ld   a,(VM_ERROR_CODE)
    or   a
    jr   nz,.fail
    or   a
    ret
.fail:
    scf
    ret

; CHECK_BYTE_TABLE -- HL = table of [addr_lo, addr_hi, expected] triples,
; B = entry count. Carry set on the first mismatch (table pointer and
; register contents are then stale -- caller bails out immediately, same
; discipline as every other v2 test's own CHECK_* routines).
CHECK_BYTE_TABLE:
.loop:
    ld   a,b
    or   a
    ret  z
    ld   e,(hl)
    inc  hl
    ld   d,(hl)
    inc  hl
    ld   c,(hl)
    inc  hl
    ld   a,(de)
    cp   c
    jr   nz,.fail
    dec  b
    jr   .loop
.fail:
    scf
    ret

SRC_CPLOT1: db "CPLOT 1,1",0
SRC_CPLOT2: db "CPLOT 70,50",0
SRC_BLOCK:  db "BLOCK 10,10,20,20",0
SRC_FRAME:  db "FRAME 10,10,20,20",0
SRC_INVERT: db "INVERT 10,10,20,20",0

; ----------------------------------------------------------------------
; Expected-value fixtures. Each triple is [addr_lo, addr_hi, expected
; byte]. Computed independently in Python from the documented standard
; ZX Spectrum screen-addressing formula (see this file's own header) --
; an external oracle, not derived from this ROM's own code.
; ----------------------------------------------------------------------

CPLOT1_EXPECT_COUNT: equ 6
CPLOT1_EXPECT_TABLE:
    DB $00,$44,$0F
    DB $00,$45,$0F
    DB $00,$46,$0F
    DB $00,$47,$0F
    DB $00,$58,$2A   ; attr cell (row0,col0)
    DB $00,$40,$00   ; nearby unaffected: same char cell, scanline 0

CPLOT2_EXPECT_COUNT: equ 5
CPLOT2_EXPECT_TABLE:
    DB $FF,$54,$0F
    DB $FF,$55,$0F
    DB $FF,$56,$0F
    DB $FF,$57,$0F
    DB $FF,$5A,$2A   ; attr cell (row23,col31) -- last attribute byte

BLOCK_EXPECT_COUNT: equ 28
BLOCK_EXPECT_TABLE:
    DB $41,$40,$3F
    DB $42,$40,$F8
    DB $41,$41,$3F
    DB $42,$41,$F8
    DB $21,$42,$3F
    DB $22,$42,$F8
    DB $41,$42,$3F
    DB $42,$42,$F8
    DB $21,$43,$3F
    DB $22,$43,$F8
    DB $41,$43,$3F
    DB $42,$43,$F8
    DB $21,$44,$3F
    DB $22,$44,$F8
    DB $41,$44,$3F
    DB $42,$44,$F8
    DB $21,$45,$3F
    DB $22,$45,$F8
    DB $21,$46,$3F
    DB $22,$46,$F8
    DB $21,$47,$3F
    DB $22,$47,$F8
    DB $21,$58,$2A
    DB $22,$58,$2A
    DB $41,$58,$2A
    DB $42,$58,$2A
    DB $20,$47,$00   ; nearby unaffected: x=9 column, inside y range
    DB $61,$41,$00   ; nearby unaffected: x=15,y=25, outside y range

FRAME_EXPECT_COUNT: equ 26
FRAME_EXPECT_TABLE:
    DB $41,$40,$20
    DB $42,$40,$08
    DB $41,$41,$20
    DB $42,$41,$08
    DB $21,$42,$3F
    DB $22,$42,$F8
    DB $41,$42,$20
    DB $42,$42,$08
    DB $21,$43,$20
    DB $22,$43,$08
    DB $41,$43,$20
    DB $42,$43,$08
    DB $21,$44,$20
    DB $22,$44,$08
    DB $41,$44,$3F
    DB $42,$44,$F8
    DB $21,$45,$20
    DB $22,$45,$08
    DB $21,$46,$20
    DB $22,$46,$08
    DB $21,$47,$20
    DB $22,$47,$08
    DB $21,$58,$2A
    DB $22,$58,$2A
    DB $41,$58,$2A
    DB $42,$58,$2A

INVERT1_EXPECT_COUNT: equ 26
INVERT1_EXPECT_TABLE:
    DB $41,$40,$3F
    DB $42,$40,$F8
    DB $41,$41,$3F
    DB $42,$41,$F8
    DB $21,$42,$3F
    DB $22,$42,$F8
    DB $41,$42,$3F
    DB $42,$42,$F8
    DB $21,$43,$3F
    DB $22,$43,$F8
    DB $41,$43,$3F
    DB $42,$43,$F8
    DB $21,$44,$3F
    DB $22,$44,$F8
    DB $41,$44,$3F
    DB $42,$44,$F8
    DB $21,$45,$3F
    DB $22,$45,$F8
    DB $21,$46,$3F
    DB $22,$46,$F8
    DB $21,$47,$3F
    DB $22,$47,$F8
    DB $21,$58,$2A
    DB $22,$58,$2A
    DB $41,$58,$2A
    DB $42,$58,$2A

INVERT2_EXPECT_COUNT: equ 26
INVERT2_EXPECT_TABLE:
    DB $41,$40,$00
    DB $42,$40,$00
    DB $41,$41,$00
    DB $42,$41,$00
    DB $21,$42,$00
    DB $22,$42,$00
    DB $41,$42,$00
    DB $42,$42,$00
    DB $21,$43,$00
    DB $22,$43,$00
    DB $41,$43,$00
    DB $42,$43,$00
    DB $21,$44,$00
    DB $22,$44,$00
    DB $41,$44,$00
    DB $42,$44,$00
    DB $21,$45,$00
    DB $22,$45,$00
    DB $21,$46,$00
    DB $22,$46,$00
    DB $21,$47,$00
    DB $22,$47,$00
    DB $21,$58,$2A
    DB $22,$58,$2A
    DB $41,$58,$2A
    DB $42,$58,$2A

; GRAPHICS_INSTALL / CPLOT / BLOCK / FRAME / INVERT are NOT included inline
; here. Real root cause found during this validation session: rom/ext_v2_
; graphics_module.asm declares its own scratch state (GFX_G_XMIN etc.) as
; plain DB cells with no fixed address, matching its own header comment
; ("costs nothing from the permanent kernel RAM budget") -- correct for its
; REAL deployment (rom/v2_package_graphics.asm, ORG EXTENSION_MODULE_BASE =
; $F400, genuine RAM). Including the module directly into THIS harness's
; HOME image instead places those same scratch cells somewhere in $0000-
; $3FFF, which is real, non-writable ROM on this project's own TS2068
; memory model (V2_HOME_IMAGE_END=$4000, confirmed empirically: a write to
; one of these cells silently failed, read back as 0 forever, causing
; GRAPHICS_CPLOT_EXEC's own DX/DY loop counters to never advance past 0/1,
; an apparent "hang" that was actually this harness's own construction
; defect, not a GRAPHICS or VM defect -- see docs/
; R10_7_CAPACITY_ARCHITECTURE_AUDIT.md's graphics-validation section for
; the full diagnosis). Fix: the real module is assembled SEPARATELY at a
; genuine RAM address (tools/build_graphics_pixel_test.sh does this,
; mirroring rom/v2_package_graphics.asm's own real ORG/placement) and
; injected into this session's RAM via ts2068-debug mem-write before
; TEST_CUSTOM_MAIN runs -- the same "load a package into RAM, then call
; it" shape the real production LOAD mechanism uses, not a new one invented
; for this test.
GRAPHICS_INSTALL: equ $9000

; Test-only stubs: this file's own test program never exercises PRINT/
; LPRINT/BEEP/SOUND/PAUSE/INPUT, and never registers or calls any
; extension beyond GRAPHICS itself.
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

    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"
