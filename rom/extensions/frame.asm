; Loadable FRAME module. Draws only the outline of the rectangle described by
; grammar 1's x0,y0 TO x1,y1 ABI bytes. Corners are emitted exactly once so
; OVER 1 does not XOR them back off.

    IFDEF FRAME_EXTENSION_CLEAR_TEST_BUILD
        INCLUDE "rom/test_extension_clear_inject.sym"
    ELSE
        IFDEF FRAME_EXTENSION_TEST_BUILD
            INCLUDE "rom/test_extension_inject.sym"
        ELSE
            INCLUDE "build/test_basic.sym"
        ENDIF
    ENDIF

    ORG EXTENSION_MODULE_BASE
    IFDEF FRAME_EXTENSION_CLEAR_TEST_BUILD
        OUTPUT "build/extensions/frame_clear_test.bin"
    ELSE
        IFDEF FRAME_EXTENSION_TEST_BUILD
            OUTPUT "build/extensions/frame_test.bin"
        ELSE
            OUTPUT "build/extensions/frame.bin"
        ENDIF
    ENDIF

FRAME_EXTENSION_INSTALL:
    ld   a, (EXT_SERVICE_VERSION_ADDR)
    cp   EXT_SERVICE_ABI_VERSION
    jr   nz, .abi_fail
    ld   hl, FRAME_EXTENSION_NAME
    ld   de, FRAME_EXTENSION_EXEC
    ld   c, 1
    call EXT_SERVICE_REGISTER
    ld   hl, 0
    ret
.abi_fail:
    scf
    ret

FRAME_EXTENSION_NAME:
    DB "FRAME", 0

FRAME_EXTENSION_EXEC:
    ld   a, (EXTENSION_ARG0)
    ld   b, a
    ld   a, (EXTENSION_ARG2)
    cp   b
    jr   nc, .x_ordered
    ld   (FRAME_XMIN), a
    ld   a, b
    ld   (FRAME_XMAX), a
    jr   .x_done
.x_ordered:
    ld   (FRAME_XMAX), a
    ld   a, b
    ld   (FRAME_XMIN), a
.x_done:
    ld   a, (EXTENSION_ARG1)
    ld   b, a
    ld   a, (EXTENSION_ARG3)
    cp   b
    jr   nc, .y_ordered
    ld   (FRAME_YMIN), a
    ld   a, b
    ld   (FRAME_YMAX), a
    jr   .y_done
.y_ordered:
    ld   (FRAME_YMAX), a
    ld   a, b
    ld   (FRAME_YMIN), a
.y_done:
    call EXT_SERVICE_PRINT_ATTR
    ld   (FRAME_ATTR), a
    call EXT_SERVICE_READ_OVER
    ld   (FRAME_OVER), a

    ld   a, (FRAME_XMIN)
    ld   (FRAME_POS), a
.horizontal:
    ld   a, (FRAME_YMIN)
    call FRAME_PLOT_AT_POS
    ld   a, (FRAME_YMAX)
    ld   b, a
    ld   a, (FRAME_YMIN)
    cp   b
    jr   z, .horizontal_advance
    ld   a, b
    call FRAME_PLOT_AT_POS
.horizontal_advance:
    ld   a, (FRAME_POS)
    ld   b, a
    ld   a, (FRAME_XMAX)
    cp   b
    jr   z, .vertical_setup
    ld   a, b
    inc  a
    ld   (FRAME_POS), a
    jr   .horizontal

.vertical_setup:
    ld   a, (FRAME_YMIN)
    inc  a
    ld   (FRAME_POS), a
.vertical:
    ld   a, (FRAME_YMAX)
    ld   b, a
    ld   a, (FRAME_POS)
    cp   b
    jr   nc, .done
    ld   c, a
    ld   a, (FRAME_XMIN)
    call FRAME_PLOT_X_AT_C
    ld   a, (FRAME_XMAX)
    ld   b, a
    ld   a, (FRAME_XMIN)
    cp   b
    jr   z, .vertical_advance
    ld   a, (FRAME_POS)
    ld   c, a
    ld   a, b
    call FRAME_PLOT_X_AT_C
.vertical_advance:
    ld   a, (FRAME_POS)
    inc  a
    ld   (FRAME_POS), a
    jr   .vertical
.done:
    or   a
    ret

; In: A=y, FRAME_POS=x.
FRAME_PLOT_AT_POS:
    ld   c, a
    ld   a, (FRAME_POS)
; In: A=x, C=y.
FRAME_PLOT_X_AT_C:
    ld   b, a
    ld   a, (FRAME_OVER)
    ld   d, a
    ld   a, (FRAME_ATTR)
    jp   EXT_SERVICE_WRITE_PIXEL

FRAME_XMIN: DB 0
FRAME_XMAX: DB 0
FRAME_YMIN: DB 0
FRAME_YMAX: DB 0
FRAME_POS:  DB 0
FRAME_ATTR: DB 0
FRAME_OVER: DB 0

FRAME_EXTENSION_END:
    ASSERT FRAME_EXTENSION_END <= EXTENSION_MODULE_LIMIT
