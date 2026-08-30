; Loadable CPLOT proof module for the single-slot BASIC extension gateway.
; This PoC is assembled against the exact ROM symbols it targets.

    IFDEF CPLOT_EXTENSION_CLEAR_TEST_BUILD
        INCLUDE "rom/test_extension_clear_inject.sym"
    ELSE
        IFDEF CPLOT_EXTENSION_TEST_BUILD
            INCLUDE "rom/test_extension_inject.sym"
        ELSE
            INCLUDE "build/test_basic.sym"
        ENDIF
    ENDIF

    ORG EXTENSION_MODULE_BASE
    IFDEF CPLOT_EXTENSION_CLEAR_TEST_BUILD
        OUTPUT "build/extensions/cplot_clear_test.bin"
    ELSE
        IFDEF CPLOT_EXTENSION_TEST_BUILD
            OUTPUT "build/extensions/cplot_test.bin"
        ELSE
            OUTPUT "build/extensions/cplot.bin"
        ENDIF
    ENDIF

CPLOT_EXTENSION_INSTALL:
    ld   hl, CPLOT_EXTENSION_NAME
    ld   de, CPLOT_EXTENSION_EXEC
    call BASIC_EXTENSION_REGISTER
    ld   hl, 0
    ret

CPLOT_EXTENSION_NAME:
    DB "CPLOT", 0

; In: BC=coarse x expression, DE=coarse y expression. Clamp exactly like the
; former resident statement and render through the mode-aware pixel primitive.
CPLOT_EXTENSION_EXEC:
    ld   a, c
    cp   64
    jr   c, .x_ok
    ld   a, 63
.x_ok:
    add  a, a
    add  a, a
    ld   (CPLOT_BASE_X), a
    ld   a, e
    cp   48
    jr   c, .y_ok
    ld   a, 47
.y_ok:
    add  a, a
    add  a, a
    ld   (CPLOT_BASE_Y), a
    call BASIC_COMPUTE_PRINT_ATTR
    ld   (CPLOT_ATTR), a
    ld   a, (CURRENT_OVER)
    ld   (CPLOT_OVER), a
    xor  a
    ld   (CPLOT_DY), a
.row:
    xor  a
    ld   (CPLOT_DX), a
.pixel:
    ld   a, (CPLOT_BASE_X)
    ld   b, a
    ld   a, (CPLOT_DX)
    add  a, b
    ld   b, a
    ld   a, (CPLOT_BASE_Y)
    ld   c, a
    ld   a, (CPLOT_DY)
    add  a, c
    ld   c, a
    ld   a, (CPLOT_OVER)
    ld   d, a
    ld   a, (CPLOT_ATTR)
    call GFX_WRITE_PIXEL
    ld   a, (CPLOT_DX)
    inc  a
    ld   (CPLOT_DX), a
    cp   4
    jr   c, .pixel
    ld   a, (CPLOT_DY)
    inc  a
    ld   (CPLOT_DY), a
    cp   4
    jr   c, .row
    or   a
    ret

CPLOT_BASE_X: DB 0
CPLOT_BASE_Y: DB 0
CPLOT_DX:     DB 0
CPLOT_DY:     DB 0
CPLOT_ATTR:   DB 0
CPLOT_OVER:   DB 0

CPLOT_EXTENSION_END:
    ASSERT CPLOT_EXTENSION_END <= EXTENSION_MODULE_LIMIT
