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
    ld   hl, STORAGE_TEST_PROGRAM
    ld   bc, STORAGE_TEST_PROGRAM_LEN
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
    DB STORAGE_PROGRAM_TYPE
    DB 'TEST      '
    DW STORAGE_TEST_PROGRAM_LEN
    DW STORAGE_NO_AUTOSTART
    DW STORAGE_TEST_PROGRAM_LEN

STORAGE_TEST_PROGRAM:
    DB $17,$00,$31,$30,$20,$52,$45,$4D,$20,$4E,$41,$4D,$45
    DB $44,$20,$4C,$4F,$41,$44,$20,$54,$45,$53,$54,$0D
STORAGE_TEST_PROGRAM_LEN EQU $ - STORAGE_TEST_PROGRAM
