; Test-only deterministic replacement for the tape pulse receiver.
; STORAGE_LOAD itself remains unmodified: header search, filename matching,
; progress callbacks, data handling, and state transitions all execute.

STORAGE_TEST_RECEIVE_BLOCK:
    cp   STORAGE_TYPE_HEADER
    jr   z, .header
    cp   STORAGE_TYPE_DATA
    jr   nz, .fail
    push ix
    pop  de
    IFDEF STORAGE_TEST_EXTENSION
    ld   hl, STORAGE_TEST_MODULE
    ld   bc, STORAGE_TEST_MODULE_LEN
    ELSE
    ld   hl, STORAGE_TEST_PROGRAM
    ld   bc, STORAGE_TEST_PROGRAM_LEN
    ENDIF
    ldir
    or   a
    ret
.header:
    push ix
    pop  de
    ld   hl, STORAGE_TEST_HEADER
    ld   bc, STORAGE_HEADER_PAYLOAD_LEN
    ldir
    or   a
    ret
.fail:
    scf
    ret

STORAGE_TEST_HEADER:
    IFDEF STORAGE_TEST_EXTENSION
    DB STORAGE_EXTENSION_TYPE
    ELSE
    DB STORAGE_PROGRAM_TYPE
    ENDIF
    DB 'TEST      '
    IFDEF STORAGE_TEST_EXTENSION
    IFDEF STORAGE_TEST_BAD_LENGTH
    DW (EXTENSION_MODULE_LIMIT - EXTENSION_MODULE_BASE) - 1
    ELSE
    DW EXTENSION_MODULE_LIMIT - EXTENSION_MODULE_BASE
    ENDIF
    IFDEF STORAGE_TEST_BAD_VERSION
    DW EXT_SERVICE_ABI_VERSION + 1
    ELSE
    DW EXT_SERVICE_ABI_VERSION
    ENDIF
    DW EXTENSION_MODULE_LIMIT - EXTENSION_MODULE_BASE
    ELSE
    DW STORAGE_TEST_PROGRAM_LEN
    DW STORAGE_NO_AUTOSTART
    DW STORAGE_TEST_PROGRAM_LEN
    ENDIF

STORAGE_TEST_PROGRAM:
    DB $17,$00,$31,$30,$20,$52,$45,$4D,$20,$4E,$41,$4D,$45
    DB $44,$20,$4C,$4F,$41,$44,$20,$54,$45,$53,$54,$0D
STORAGE_TEST_PROGRAM_LEN EQU $ - STORAGE_TEST_PROGRAM

    IFDEF STORAGE_TEST_EXTENSION
STORAGE_TEST_MODULE:
    DB $21, $10, $F4                 ; ld hl,$F410 (name)
    DB $11, $17, $F4                 ; ld de,$F417 (exec)
    DB $CD, LOW EXT_SERVICE_REGISTER, HIGH EXT_SERVICE_REGISTER
    DB $C9                           ; ret
    DS 6, 0
    DB "TSTEXT",0
    DB $B7,$C9                       ; or a / ret
STORAGE_TEST_MODULE_LEN EQU $ - STORAGE_TEST_MODULE
    ENDIF
