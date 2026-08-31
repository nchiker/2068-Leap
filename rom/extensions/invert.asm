; Loadable INVERT module. XORs every pixel in the inclusive rectangle
; described by grammar 1's x0,y0 TO x1,y1 ABI bytes. Applying the same
; rectangle twice restores the original bitmap.

    IFDEF INVERT_EXTENSION_CLEAR_TEST_BUILD
        INCLUDE "rom/test_extension_clear_inject.sym"
    ELSE
        IFDEF INVERT_EXTENSION_TEST_BUILD
            INCLUDE "rom/test_extension_inject.sym"
        ELSE
            INCLUDE "build/test_basic.sym"
        ENDIF
    ENDIF

    ORG EXTENSION_MODULE_BASE
    IFDEF INVERT_EXTENSION_CLEAR_TEST_BUILD
        OUTPUT "build/extensions/invert_clear_test.bin"
    ELSE
        IFDEF INVERT_EXTENSION_TEST_BUILD
            OUTPUT "build/extensions/invert_test.bin"
        ELSE
            OUTPUT "build/extensions/invert.bin"
        ENDIF
    ENDIF

INVERT_EXTENSION_INSTALL:
    ld   a, (EXT_SERVICE_VERSION_ADDR)
    cp   EXT_SERVICE_ABI_VERSION
    jr   nz, .abi_fail
    ld   hl, INVERT_EXTENSION_NAME
    ld   de, INVERT_EXTENSION_EXEC
    ld   c, 1
    call EXT_SERVICE_REGISTER
    ld   hl, 0
    ret
.abi_fail:
    scf
    ret

INVERT_EXTENSION_NAME:
    DB "INVERT", 0

INVERT_EXTENSION_EXEC:
    ld   a, (EXTENSION_ARG0)
    ld   b, a
    ld   a, (EXTENSION_ARG2)
    cp   b
    jr   nc, .x_ordered
    ld   (INVERT_XMIN), a
    ld   a, b
    ld   (INVERT_XMAX), a
    jr   .x_done
.x_ordered:
    ld   (INVERT_XMAX), a
    ld   a, b
    ld   (INVERT_XMIN), a
.x_done:
    ld   a, (EXTENSION_ARG1)
    ld   b, a
    ld   a, (EXTENSION_ARG3)
    cp   b
    jr   nc, .y_ordered
    ld   (INVERT_YMIN), a
    ld   a, b
    ld   (INVERT_YMAX), a
    jr   .y_done
.y_ordered:
    ld   (INVERT_YMAX), a
    ld   a, b
    ld   (INVERT_YMIN), a
.y_done:
    call EXT_SERVICE_PRINT_ATTR
    ld   (INVERT_ATTR), a
    ld   a, (INVERT_YMIN)
    ld   (INVERT_Y), a

.row:
    ld   a, (INVERT_XMIN)
    ld   (INVERT_X), a
.pixel:
    ld   b, a
    ld   a, (INVERT_Y)
    ld   c, a
    ld   d, 1
    ld   a, (INVERT_ATTR)
    call EXT_SERVICE_WRITE_PIXEL

    ld   a, (INVERT_X)
    ld   b, a
    ld   a, (INVERT_XMAX)
    cp   b
    jr   z, .next_row
    ld   a, b
    inc  a
    ld   (INVERT_X), a
    jr   .pixel

.next_row:
    ld   a, (INVERT_Y)
    ld   b, a
    ld   a, (INVERT_YMAX)
    cp   b
    jr   z, .done
    ld   a, b
    inc  a
    ld   (INVERT_Y), a
    jr   .row
.done:
    or   a
    ret

INVERT_XMIN: DB 0
INVERT_XMAX: DB 0
INVERT_YMIN: DB 0
INVERT_YMAX: DB 0
INVERT_X:    DB 0
INVERT_Y:    DB 0
INVERT_ATTR: DB 0

INVERT_EXTENSION_END:
    ASSERT INVERT_EXTENSION_END <= EXTENSION_MODULE_LIMIT
