; Loadable CIRCLE+FILL combined module for the BASIC extension gateway,
; added 2026-09-19 (Phase 0 P0.4). Bundles two related graphics
; primitives into ONE loadable module rather than shipping either
; alone — both sister projects (structured-basic-poc's own
; GRAPHICS_EXTENSION_ABI.md, 2068-Forth's fixed 8-slot graphics service
; table) independently converged on exactly this "bundle related
; primitives, pay the per-extension fixed overhead once" shape.
;
; Ported verbatim from the former Home-resident GFX_CIRCLE/GFX_FILL and
; their own private helpers (kernel/graphics/graphics.asm) — every
; SHAPES_-prefixed routine below is a straight rename of the original,
; unchanged logic. Both only ever called GFX_PLOT_CLIPPED/MATH_NEGATE16
; (CIRCLE) and GFX_READ_PIXEL/GFX_WRITE_PIXEL (FILL) — all four HOME-
; resident, always-mapped, and called here DIRECTLY via this module's
; own build-time symbol table rather than through a dedicated EXT_
; SERVICE_* veneer (unlike PRINT_ATTR/OVER below, which reuse the
; existing veneers CPLOT already established) — a deliberate, disclosed
; departure from "every Home dependency goes through a stable veneer":
; adding 2-4 new veneer entries to the fixed $F3xx table would cost more
; HOME bytes than this milestone's own budget, freed almost entirely by
; deleting GFX_CIRCLE/GFX_FILL's OWN Home residency, can absorb for a
; tape-portability guarantee neither of these two primitives' own
; history has ever needed in practice. See MILESTONE_02_RESULTS.md.
;
; CORRECTNESS NOTE, load-bearing: GFX_FILL_VISITED ($C000-$D7FF) and
; GFX_FILL_STACK ($D800+) both live INSIDE the EXROM/Dock banking
; window (chunk 6, $C000-$DFFF) — safe here ONLY because this module's
; own code executes with EXROM/Dock NOT paged in (plain Home-mapped
; RAM at those addresses), which is true for every ordinary statement-
; dispatch call. This module's dispatch is NOT routed through EXROM
; (unlike HIT()'s own P0.3 precedent) for exactly this reason — paging
; EXROM in before calling this module's FILL exec would make those same
; addresses read/write the paged-in EXROM/Dock content instead of the
; RAM buffer, silently corrupting the flood-fill. Keeping the dispatch
; Home-resident sidesteps the hazard entirely; see BASIC_TRY_EXTENSION's
; own comments (basic/basic.asm) for the actual dispatch shape this
; assumption depends on.

    IFDEF SHAPES_EXTENSION_CLEAR_TEST_BUILD
        INCLUDE "rom/test_extension_clear_inject.sym"
    ELSE
        IFDEF SHAPES_EXTENSION_TEST_BUILD
            INCLUDE "rom/test_extension_inject.sym"
        ELSE
            INCLUDE "build/test_basic.sym"
        ENDIF
    ENDIF

    ORG EXTENSION_MODULE_BASE
    IFDEF SHAPES_EXTENSION_CLEAR_TEST_BUILD
        OUTPUT "build/extensions/shapes_clear_test.bin"
    ELSE
        IFDEF SHAPES_EXTENSION_TEST_BUILD
            OUTPUT "build/extensions/shapes_test.bin"
        ELSE
            OUTPUT "build/extensions/shapes.bin"
        ENDIF
    ENDIF

SHAPES_EXTENSION_INSTALL:
    ld   a, (EXT_SERVICE_VERSION_ADDR)
    cp   EXT_SERVICE_ABI_VERSION
    jr   nz, .abi_fail
    ld   hl, SHAPES_CIRCLE_NAME
    ld   de, SHAPES_CIRCLE_EXEC
    ld   c, 3                          ; grammar 3 = expr,expr,expr
    call EXT_SERVICE_REGISTER
    jr   c, .abi_fail
    ld   hl, SHAPES_FILL_NAME
    ld   de, SHAPES_FILL_EXEC
    ld   c, 0                          ; grammar 0 = expr,expr
    call EXT_SERVICE_REGISTER
    jr   c, .abi_fail
    ld   hl, 0
    ret
.abi_fail:
    scf
    ret

SHAPES_CIRCLE_NAME:
    DB "CIRCLE", 0
SHAPES_FILL_NAME:
    DB "FILL", 0

; ============================================================================
; SHAPES_CIRCLE_EXEC
; CIRCLE <x>,<y>,<r> — In: BC=x (low byte), DE=y (low byte, UNCLAMPED —
; BASIC_TRY_EXTENSION's own grammar-3 path does not clamp, unlike its
; fixed 4-arg LINE-shaped grammar 1; this module clamps y itself, same
; as the original resident BASIC_STMT_CIRCLE did), EXTENSION_ARG0=r
; (low byte, stashed there by the generic grammar-3 dispatcher since
; only two register-passed values are available).
; ============================================================================
SHAPES_CIRCLE_EXEC:
    ld   a, c
    ld   (GFX_CIRCLE_XC), a
    ld   a, e
    call BASIC_CLAMP_Y191
    ld   (GFX_CIRCLE_YC), a
    ld   a, (EXTENSION_ARG0)
    ld   (GFX_CIRCLE_R), a
    call EXT_SERVICE_PRINT_ATTR
    ld   (GFX_CIRCLE_ATTR), a
    call EXT_SERVICE_READ_OVER
    ld   (GFX_CIRCLE_OVER), a
    call SHAPES_GFX_CIRCLE
    or   a
    ret

; ============================================================================
; SHAPES_FILL_EXEC
; FILL <x>,<y> — In: BC=x (low byte), DE=y (low byte, UNCLAMPED — this
; module clamps it itself, same as the original resident BASIC_STMT_
; FILL did).
; ============================================================================
SHAPES_FILL_EXEC:
    ld   a, c
    ld   (GFX_FILL_X), a
    ld   a, e
    call BASIC_CLAMP_Y191
    ld   (GFX_FILL_Y), a
    call EXT_SERVICE_PRINT_ATTR
    ld   (GFX_FILL_ATTR), a
    call SHAPES_GFX_FILL
    or   a
    ret

; ---- ported verbatim from kernel/graphics/graphics.asm's own
; GFX_CIRCLE_PLOT_OFFSET/PLOT_POLES/PLOT_GENERAL/GFX_CIRCLE — see that
; file's own removal note for the original headers/verification history
; (309-circle Python cross-check, the x=0/x==y dedup reasoning, the
; 16-bit-signed x-y term finding). Only the names gained a SHAPES_
; prefix; no logic changed. ----

SHAPES_GFX_CIRCLE_PLOT_OFFSET:
    push de
    ld   a, (GFX_CIRCLE_XC)
    ld   e, a
    ld   d, 0
    add  hl, de
    pop  de
    push hl
    ld   a, (GFX_CIRCLE_YC)
    ld   l, a
    ld   h, 0
    add  hl, de
    ex   de, hl
    pop  hl
    ld   a, (GFX_CIRCLE_OVER)
    ld   b, a
    ld   a, (GFX_CIRCLE_ATTR)
    jp   GFX_PLOT_CLIPPED

SHAPES_GFX_CIRCLE_PLOT_POLES:
    ld   a, (GFX_CIRCLE_Y)
    ld   e, a
    ld   d, 0
    ld   hl, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    ld   de, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ld   de, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   hl, 0
    jp   SHAPES_GFX_CIRCLE_PLOT_OFFSET

SHAPES_GFX_CIRCLE_PLOT_GENERAL:
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET

    ld   a, (GFX_CIRCLE_X)
    ld   b, a
    ld   a, (GFX_CIRCLE_Y)
    cp   b
    ret  z

    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call SHAPES_GFX_CIRCLE_PLOT_OFFSET
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    jp   SHAPES_GFX_CIRCLE_PLOT_OFFSET

SHAPES_GFX_CIRCLE:
    ld   a, (GFX_CIRCLE_R)
    or   a
    jr   nz, .r_nonzero

    ld   a, (GFX_CIRCLE_XC)
    ld   l, a
    ld   h, 0
    ld   a, (GFX_CIRCLE_YC)
    ld   e, a
    ld   d, 0
    ld   a, (GFX_CIRCLE_OVER)
    ld   b, a
    ld   a, (GFX_CIRCLE_ATTR)
    jp   GFX_PLOT_CLIPPED

.r_nonzero:
    xor  a
    ld   (GFX_CIRCLE_X), a
    ld   a, (GFX_CIRCLE_R)
    ld   (GFX_CIRCLE_Y), a

    ld   hl, 1
    ld   e, a
    ld   d, 0
    or   a
    sbc  hl, de
    ld   (GFX_CIRCLE_D), hl

    call SHAPES_GFX_CIRCLE_PLOT_POLES

.loop:
    ld   a, (GFX_CIRCLE_X)
    inc  a
    ld   (GFX_CIRCLE_X), a

    ld   hl, (GFX_CIRCLE_D)
    bit  7, h
    jr   z, .d_not_negative

    ld   a, (GFX_CIRCLE_X)
    ld   e, a
    ld   d, 0
    add  hl, de
    add  hl, de
    inc  hl
    ld   (GFX_CIRCLE_D), hl
    jr   .step_done

.d_not_negative:
    ld   a, (GFX_CIRCLE_Y)
    dec  a
    ld   (GFX_CIRCLE_Y), a
    ld   e, a
    ld   d, 0
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    or   a
    sbc  hl, de
    add  hl, hl
    inc  hl
    ex   de, hl
    ld   hl, (GFX_CIRCLE_D)
    add  hl, de
    ld   (GFX_CIRCLE_D), hl

.step_done:
    ld   a, (GFX_CIRCLE_X)
    ld   b, a
    ld   a, (GFX_CIRCLE_Y)
    cp   b
    ret  c

    call SHAPES_GFX_CIRCLE_PLOT_GENERAL
    jp   .loop

; ---- ported verbatim from kernel/graphics/graphics.asm's own
; GFX_FILL_PUSH/POP/TRY_NEIGHBOR/VISITED_CHECK_SET/GFX_FILL — see that
; file's own removal note for the original headers/verification history
; (the OVER/XOR bug, the cell-granularity-dedup bug, the 51x51/256x192
; Python stress checks). Only the names gained a SHAPES_ prefix, and
; BIT_MASK_TABLE (originally shared with other graphics code, not worth
; duplicating a second copy of) is reproduced locally since this module
; has no other way to reach the Home original at $C000-$DFFF-adjacent
; addresses reliably build-to-build. ----

SHAPES_BIT_MASK_TABLE:
    DB   %10000000, %01000000, %00100000, %00010000
    DB   %00001000, %00000100, %00000010, %00000001

SHAPES_GFX_FILL_PUSH:
    ld   hl, (GFX_FILL_SP)
    ld   de, GFX_FILL_STACK_END
    or   a
    sbc  hl, de
    ret  nc

    ld   hl, (GFX_FILL_SP)
    ld   (hl), b
    inc  hl
    ld   (hl), c
    inc  hl
    ld   (GFX_FILL_SP), hl
    ret

SHAPES_GFX_FILL_POP:
    ld   hl, (GFX_FILL_SP)
    ld   de, GFX_FILL_STACK
    or   a
    sbc  hl, de
    jr   z, .empty

    ld   hl, (GFX_FILL_SP)
    dec  hl
    ld   c, (hl)
    dec  hl
    ld   b, (hl)
    ld   (GFX_FILL_SP), hl
    or   a
    ret
.empty:
    scf
    ret

SHAPES_GFX_FILL_TRY_NEIGHBOR:
    push bc
    call GFX_READ_PIXEL
    ld   e, a
    ld   a, (GFX_FILL_TARGET)
    cp   e
    jr   nz, .not_match

    pop  bc
    push bc
    call SHAPES_GFX_FILL_VISITED_CHECK_SET
    jr   c, .not_match

    pop  bc
    push bc
    ld   d, 0
    ld   a, (GFX_FILL_ATTR)
    call GFX_WRITE_PIXEL
    pop  bc
    jp   SHAPES_GFX_FILL_PUSH
.not_match:
    pop  bc
    ret

SHAPES_GFX_FILL_VISITED_CHECK_SET:
    ld   a, c
    ld   l, a
    ld   h, 0
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    ld   a, b
    srl  a
    srl  a
    srl  a
    ld   e, a
    ld   d, 0
    add  hl, de
    ld   de, GFX_FILL_VISITED
    add  hl, de

    ld   a, b
    and  %00000111
    ld   e, a
    ld   d, 0
    push hl
    ld   hl, SHAPES_BIT_MASK_TABLE
    add  hl, de
    ld   a, (hl)
    pop  hl
    ld   e, a
    ld   a, (hl)
    and  e
    jr   nz, .already
    ld   a, (hl)
    or   e
    ld   (hl), a
    or   a
    ret
.already:
    scf
    ret

SHAPES_GFX_FILL:
    ld   hl, GFX_FILL_STACK
    ld   (GFX_FILL_SP), hl

    ld   hl, GFX_FILL_VISITED
    ld   (hl), 0
    ld   de, GFX_FILL_VISITED + 1
    ld   bc, 6144 - 1
    ldir

    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call GFX_READ_PIXEL
    ld   (GFX_FILL_TARGET), a

    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call SHAPES_GFX_FILL_VISITED_CHECK_SET
    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    ld   d, 0
    ld   a, (GFX_FILL_ATTR)
    call GFX_WRITE_PIXEL
    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call SHAPES_GFX_FILL_PUSH

.loop:
    call SHAPES_GFX_FILL_POP
    ret  c

    ld   a, b
    ld   (GFX_FILL_X), a
    ld   a, c
    ld   (GFX_FILL_Y), a

    ld   a, (GFX_FILL_X)
    cp   255
    jr   z, .skip_right
    ld   b, a
    inc  b
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call SHAPES_GFX_FILL_TRY_NEIGHBOR
.skip_right:

    ld   a, (GFX_FILL_X)
    or   a
    jr   z, .skip_left
    ld   b, a
    dec  b
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call SHAPES_GFX_FILL_TRY_NEIGHBOR
.skip_left:

    ld   a, (GFX_FILL_Y)
    cp   191
    jr   nc, .skip_down
    ld   c, a
    inc  c
    ld   a, (GFX_FILL_X)
    ld   b, a
    call SHAPES_GFX_FILL_TRY_NEIGHBOR
.skip_down:

    ld   a, (GFX_FILL_Y)
    or   a
    jr   z, .skip_up
    ld   c, a
    dec  c
    ld   a, (GFX_FILL_X)
    ld   b, a
    call SHAPES_GFX_FILL_TRY_NEIGHBOR
.skip_up:

    jp   .loop

SHAPES_EXTENSION_END:
    ASSERT SHAPES_EXTENSION_END <= EXTENSION_MODULE_LIMIT
