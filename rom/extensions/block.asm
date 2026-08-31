; Loadable BLOCK module. The resident grammar parser places
; x0,y0,x1,y1 in the stable EXTENSION_ARG0..3 ABI bytes.

    IFDEF BLOCK_EXTENSION_CLEAR_TEST_BUILD
        INCLUDE "rom/test_extension_clear_inject.sym"
    ELSE
        IFDEF BLOCK_EXTENSION_TEST_BUILD
            INCLUDE "rom/test_extension_inject.sym"
        ELSE
            INCLUDE "build/test_basic.sym"
        ENDIF
    ENDIF

    ORG EXTENSION_MODULE_BASE
    IFDEF BLOCK_EXTENSION_CLEAR_TEST_BUILD
        OUTPUT "build/extensions/block_clear_test.bin"
    ELSE
        IFDEF BLOCK_EXTENSION_TEST_BUILD
            OUTPUT "build/extensions/block_test.bin"
        ELSE
            OUTPUT "build/extensions/block.bin"
        ENDIF
    ENDIF

BLOCK_EXTENSION_INSTALL:
    ld   a, (EXT_SERVICE_VERSION_ADDR)
    cp   EXT_SERVICE_ABI_VERSION
    jr   nz, .abi_fail
    ld   hl, BLOCK_EXTENSION_NAME
    ld   de, BLOCK_EXTENSION_EXEC
    ld   c, 1                         ; LINE-shaped expr,expr TO expr,expr
    call EXT_SERVICE_REGISTER
    ld   hl, 0
    ret
.abi_fail:
    scf
    ret

BLOCK_EXTENSION_NAME:
    DB "BLOCK", 0

BLOCK_EXTENSION_EXEC:
    ld   a, (EXTENSION_ARG0)
    ld   b, a
    ld   a, (EXTENSION_ARG2)
    cp   b
    jr   nc, .x_ordered
    ld   (BLOCK_XMIN), a
    ld   a, b
    ld   (BLOCK_XMAX), a
    jr   .x_done
.x_ordered:
    ld   (BLOCK_XMAX), a
    ld   a, b
    ld   (BLOCK_XMIN), a
.x_done:
    ld   a, (EXTENSION_ARG1)
    ld   b, a
    ld   a, (EXTENSION_ARG3)
    cp   b
    jr   nc, .y_ordered
    ld   (BLOCK_YMIN), a
    ld   a, b
    ld   (BLOCK_YMAX), a
    jr   .y_done
.y_ordered:
    ld   (BLOCK_YMAX), a
    ld   a, b
    ld   (BLOCK_YMIN), a
.y_done:
    call EXT_SERVICE_PRINT_ATTR
    ld   (BLOCK_ATTR), a
    call EXT_SERVICE_READ_OVER
    ld   (BLOCK_OVER), a
    ld   a, (BLOCK_YMIN)
    ld   (BLOCK_Y), a
.row:
    ld   a, (BLOCK_XMIN)
    ld   (BLOCK_X), a
.pixel:
    ld   a, (BLOCK_X)
    ld   b, a
    ld   a, (BLOCK_Y)
    ld   c, a
    ld   a, (BLOCK_OVER)
    ld   d, a
    ld   a, (BLOCK_ATTR)
    call EXT_SERVICE_WRITE_PIXEL
    ld   a, (BLOCK_X)
    ld   b, a
    ld   a, (BLOCK_XMAX)
    cp   b
    jr   z, .row_done
    ld   a, b
    inc  a
    ld   (BLOCK_X), a
    jr   .pixel
.row_done:
    ld   a, (BLOCK_Y)
    ld   b, a
    ld   a, (BLOCK_YMAX)
    cp   b
    jr   z, .done
    ld   a, b
    inc  a
    ld   (BLOCK_Y), a
    jr   .row
.done:
    or   a
    ret

BLOCK_XMIN: DB 0
BLOCK_XMAX: DB 0
BLOCK_YMIN: DB 0
BLOCK_YMAX: DB 0
BLOCK_X:    DB 0
BLOCK_Y:    DB 0
BLOCK_ATTR: DB 0
BLOCK_OVER: DB 0

BLOCK_EXTENSION_END:
    ASSERT BLOCK_EXTENSION_END <= EXTENSION_MODULE_LIMIT
