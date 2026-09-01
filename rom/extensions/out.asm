; Loadable OUT module. Performs the Z80 OUT (C),A operation using a full
; 16-bit port address and one data byte. This is intentionally a low-level,
; advanced command: the caller is responsible for choosing a safe port.

    IFDEF OUT_EXTENSION_CLEAR_TEST_BUILD
        INCLUDE "rom/test_extension_clear_inject.sym"
    ELSE
        IFDEF OUT_EXTENSION_TEST_BUILD
            INCLUDE "rom/test_extension_inject.sym"
        ELSE
            INCLUDE "build/test_basic.sym"
        ENDIF
    ENDIF

    ORG EXTENSION_MODULE_BASE
    IFDEF OUT_EXTENSION_CLEAR_TEST_BUILD
        OUTPUT "build/extensions/out_clear_test.bin"
    ELSE
        IFDEF OUT_EXTENSION_TEST_BUILD
            OUTPUT "build/extensions/out_test.bin"
        ELSE
            OUTPUT "build/extensions/out.bin"
        ENDIF
    ENDIF

OUT_EXTENSION_INSTALL:
    ld   a, (EXT_SERVICE_VERSION_ADDR)
    cp   EXT_SERVICE_ABI_VERSION
    jr   nz, .abi_fail
    ld   hl, OUT_EXTENSION_NAME
    ld   de, OUT_EXTENSION_EXEC
    ld   c, 0                         ; expr,expr
    call EXT_SERVICE_REGISTER
    ld   hl, 0
    ret
.abi_fail:
    scf
    ret

OUT_EXTENSION_NAME:
    DB "OUT", 0

; In: BC=16-bit port expression, DE=data expression (grammar 0 ABI).
; Validate data before touching hardware. Every BC value is a legitimate Z80
; port address; policy restrictions belong in documentation because hardware
; add-ons may intentionally decode addresses the base TS2068 does not.
OUT_EXTENSION_EXEC:
    ld   a, d
    or   a
    jr   nz, .range_fail             ; data must fit in one byte
    ld   a, e
    out  (c), a                      ; Z80 places the complete BC on the bus
    or   a
    ret
.range_fail:
    scf
    ret

OUT_EXTENSION_END:
    ASSERT OUT_EXTENSION_END <= EXTENSION_MODULE_LIMIT
