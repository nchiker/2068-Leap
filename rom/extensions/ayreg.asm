; Loadable AYREG module. Writes a native AY-3-8912 register number (0-15)
; and one data byte (0-255) through the TS2068's $F5/$F6 port pair.

    IFDEF AYREG_EXTENSION_CLEAR_TEST_BUILD
        INCLUDE "rom/test_extension_clear_inject.sym"
    ELSE
        IFDEF AYREG_EXTENSION_TEST_BUILD
            INCLUDE "rom/test_extension_inject.sym"
        ELSE
            INCLUDE "build/test_basic.sym"
        ENDIF
    ENDIF

    ORG EXTENSION_MODULE_BASE
    IFDEF AYREG_EXTENSION_CLEAR_TEST_BUILD
        OUTPUT "build/extensions/ayreg_clear_test.bin"
    ELSE
        IFDEF AYREG_EXTENSION_TEST_BUILD
            OUTPUT "build/extensions/ayreg_test.bin"
        ELSE
            OUTPUT "build/extensions/ayreg.bin"
        ENDIF
    ENDIF

AYREG_EXTENSION_INSTALL:
    ld   a, (EXT_SERVICE_VERSION_ADDR)
    cp   EXT_SERVICE_ABI_VERSION
    jr   nz, .abi_fail
    ld   hl, AYREG_EXTENSION_NAME
    ld   de, AYREG_EXTENSION_EXEC
    ld   c, 0                         ; expr,expr
    call EXT_SERVICE_REGISTER
    ld   hl, 0
    ret
.abi_fail:
    scf
    ret

AYREG_EXTENSION_NAME:
    DB "AYREG", 0

; In: BC=register expression, DE=data expression (grammar 0 ABI).
; Reject both full 16-bit values before the first OUT, so a malformed data
; value cannot select a register and leave the PSG in a partial operation.
AYREG_EXTENSION_EXEC:
    ld   a, b
    or   a
    jr   nz, .range_fail             ; register >255 or negative
    ld   a, c
    cp   16
    jr   nc, .range_fail             ; native AY register is 0-15
    ld   a, d
    or   a
    jr   nz, .range_fail             ; data must fit in one byte

    ld   a, c
    out  (PORT_AY_REG), a
    ld   a, e
    out  (PORT_AY_DATA), a
    or   a
    ret
.range_fail:
    scf
    ret

AYREG_EXTENSION_END:
    ASSERT AYREG_EXTENSION_END <= EXTENSION_MODULE_LIMIT
