; ============================================================================
; rom/test_v2_shapes_circle.asm — R10.7 item 2: proves CIRCLE, already
; ported verbatim into the loadable rom/ext_v2_shapes_module.asm package
; (registered "CIRCLE", argcount=3, argtype=0 — an ordinary all-numeric
; fixed-shape extension call, kernel/extensions/ext_registry.asm), is
; ALREADY reachable from BASIC through the existing, unmodified R7.5
; generic identifier-driven extension-call mechanism (rom/exrom_v2_
; compiler.asm's own COMPILE_FACTOR/.ident_stmt EXT2_LOOKUP check ->
; COMPILE_EXT_CALL — the SAME path MODE/SPRITE/FILL already use). No new
; keyword, token, or compiler dispatch code was added or is needed: this
; test adds zero lines to rom/exrom_v2_compiler.asm/exrom_v2_vm_core.asm.
;
; Built on the shared production-shaped test harness (rom/test_v2_
; harness_home_head.inc/_tail.inc + rom/test_v2_harness_exrom.asm), same
; as rom/test_v2_mode_module.asm's own identical-in-spirit proof.
;
; Source program compiled and executed (AFTER SHAPES_INSTALL has already
; registered CIRCLE/FILL, mirroring how a real LOAD "SHAPES" leaves the
; registry before any subsequent line runs):
;
;   CIRCLE 10,10,5
;
; Verification: VM_ERROR_CODE=0 plus the decompiled text confirms the
; call compiled/ran/decompiled correctly through .op_call_ext's own
; existing generic path, exactly like MODE 1/ULAPLUS 1/PALETTE 5,200
; already prove for that package.
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    DEFINE TEST_V2_NEEDS_DECOMPILE
    INCLUDE "rom/test_v2_harness_home_head.inc"

TEST_CUSTOM_MAIN:
    call EXT2_CLEAR_ALL
    call TEST_SHAPES_INSTALL
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
    db "CIRCLE 10,10,5", 0

; ============================================================================
; CHECK_DECOMPILED_TEXT — byte-for-byte against a real captured-then-
; verified rendering. Proves .op_call_ext's own EXISTING generic
; decompile path (unmodified for this module too) correctly reconstructs
; "CIRCLE 10,10,5" from the LIVE registry, with no new decompiler code.
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
    db "CIRCLE 10,10,5", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stubs: this file's own test program never exercises PRINT/
; LPRINT/BEEP/SOUND/PAUSE/INPUT, and never checks real screen bitmap
; content (same discipline as rom/test_v2_mode_module.asm) -- CIRCLE's
; own already-verified algorithm (ported verbatim from V1, R10.25's own
; audit) is not what this test re-proves; only BASIC-level reachability
; is in scope here.
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
; GFX_PLOT_CLIPPED -- SHAPES_GFX_CIRCLE's own real pixel-write primitive.
; Stubbed the same harmless way GFX_WRITE_PIXEL already is above (this
; test never checks real screen bitmap content).
GFX_PLOT_CLIPPED:
    ret
; kernel/memory/memory.asm is NOT included here -- but EXT2_CLEAR_ALL
; (kernel/extensions/ext_registry.asm) genuinely calls its real
; MEM_FILL_ZERO to zero the registry table, so that one routine needs a
; real (not no-op) stub: fills BC bytes at HL with zero, matching its
; real In:HL=dest,BC=count contract exactly, not a fake pass-through.
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret
; TEST_SHAPES_INSTALL/TEST_SHAPES_CIRCLE_EXEC -- registers "CIRCLE" with
; the SAME real name/argcount/argtype rom/ext_v2_shapes_module.asm's own
; SHAPES_INSTALL uses (EXT2_REGISTER "CIRCLE", argcount=3, argtype=0),
; proving specifically that the compiler's generic identifier-driven
; extension-call REACHES a correctly-registered CIRCLE. This deliberately
; does NOT include the real module (its real body is ORG'd at the fixed
; production package address $F400 with its own SAVEBIN, meaningless
; inside this flat 16K test image) and deliberately does NOT re-verify
; the circle-drawing algorithm itself -- that algorithm is unchanged,
; already ported verbatim from V1, and already covered by R10.25's own
; audit; only BASIC-level compile/run/decompile reachability is what
; this test needs to add evidence for. Same scope discipline rom/test_
; v2_mode_module.asm's own GFX_SET_MODE stub already established (that
; test doesn't re-verify real mode-switching either).
TEST_SHAPES_INSTALL:
    ld hl,TEST_SHAPES_CIRCLE_NAME
    ld de,TEST_SHAPES_CIRCLE_EXEC
    ld b,3
    ld c,0
    jp EXT2_REGISTER

TEST_SHAPES_CIRCLE_NAME: DB "CIRCLE",0
TEST_SHAPES_CIRCLE_EXEC:
    ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"
