; Deterministic regression for LOAD "name" filename retention.
; Pair with exrom_storage_test.bin, whose only substitution is the
; tape-pulse receiver beneath the real STORAGE_LOAD implementation.

    DEFINE FULL_ENGINE_PRESENT

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE
    INCLUDE "include/exrom_jumptable.inc"

    DEVICE NOSLOT64K
    ORG $0000

    di
    jp COLD_START
    DS $0028 - $, $FF
    jp CALC_ENTRY_TRAMPOLINE
    DS $0038 - $, $FF
    call KBD_ISR_TICK
    ei
    reti

    ORG KTAB_BASE
    KTAB_LIST
    ASSERT $ <= KTAB_END
    DB KTAB_MAGIC
    DS $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_INIT
    xor  a
    ld   (TEST_TRANSITIONS), a
    ld   hl, TEST_PROGRESS_HOOK
    ld   (STORAGE_PROGRESS_HOOK), hl

    IFDEF STORAGE_TEST_SAVE_MISSING
    ld   hl, SAVE_TEXT
    call BASIC_DO_SAVE
    jr   c, .fail_state
    ld   a, (STORAGE_OP_STATE)
    cp   8
    jr   nz, .fail_state
    call BASIC_FORMAT_STORAGE_STATUS_EXROM
    ld   hl, STATUS_BUF
    ld   de, EXPECTED_SAVE_FAILED
    ld   b, EXPECTED_SAVE_FAILED_LEN
.compare_save_status:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail_content
    inc  de
    inc  hl
    djnz .compare_save_status
    jr   .pass
    ELSE
    ; Match the live editor layout: BASIC_DO_LOAD receives the quote at
    ; EDIT_LINE_BUF+5 and copies the name backward into offset zero.
    ld   hl, LOAD_TEXT
    ld   de, EDIT_LINE_BUF + 5
    ld   bc, LOAD_TEXT_LEN
    ldir
    ld   hl, EDIT_LINE_BUF + 5
    call BASIC_DO_LOAD

    IFDEF STORAGE_TEST_WILDCARD
    jr   nc, .fail_state
    ld   a, (TEST_TRANSITIONS)
    or   a
    jr   nz, .fail_state
    ld   hl, (EXTENSION_MAGIC)
    ld   a, h
    or   l
    jr   nz, .fail_content
    jr   .pass
    ELSE
    ld   a, (TEST_TRANSITIONS)
    cp   %00000111
    jr   nz, .fail_state
    IFDEF STORAGE_TEST_EXTENSION
    IFDEF STORAGE_TEST_INVALID
    ld   a, (STORAGE_OP_STATE)
    cp   6
    jr   nz, .fail_state
    ld   hl, (EXTENSION_MAGIC)
    ld   a, h
    or   l
    jr   nz, .fail_content
    jr   .pass
    ELSE
    ld   hl, (EXTENSION_MAGIC)
    ld   de, EXTENSION_REG_MAGIC
    or   a
    sbc  hl, de
    jr   nz, .fail_content
    ld   hl, (EXTENSION_NAME_PTR)
    ld   a, (hl)
    cp   'T'
    jr   nz, .fail_content
    jr   .pass
    ENDIF
    ELSE
    ld   hl, (PROG_END)
    ld   de, PROG_AREA_START + EXPECTED_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail_length
    ld   hl, PROG_AREA_START
    ld   de, EXPECTED
    ld   b, EXPECTED_LEN
.compare:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail_content
    inc  de
    inc  hl
    djnz .compare

    ; A program LOAD must leave the editor on the append sentinel with its
    ; index equal to the number of statements bulk-loaded.  The canned payload
    ; contains one statement; the old hardcoded-zero reset produced a phantom
    ; cursor on long programs because redraw could not place the sentinel.
    ld   hl, (CUR_EDIT_POS)
    inc  hl
    ld   a, h
    or   l
    jr   nz, .fail_content
    ld   hl, (CUR_EDIT_INDEX)
    ld   de, 1
    or   a
    sbc  hl, de
    jr   nz, .fail_content
    ENDIF
    ENDIF
    ENDIF
.pass:
    ld   a, 4
    jr   .done
.fail_state:
    ld   a, 2
    jr   .done
.fail_length:
    ld   a, 1
    jr   .done
.fail_content:
    ld   a, 3
.done:
    out  (PORT_ULA), a
    jr   $

TEST_PROGRESS_HOOK:
    ld   a, (STORAGE_OP_STATE)
    cp   3
    jr   z, .loading
    cp   7
    jr   z, .found
    cp   4
    jr   nz, .draw
    ld   a, %00000100
    jr   .record
.loading:
    ld   a, %00000001
    jr   .record
.found:
    ld   a, %00000010
.record:
    ld   hl, TEST_TRANSITIONS
    or   (hl)
    ld   (hl), a
.draw:
    jp   BASIC_DRAW_STATUS_LINE

; The fake receiver does not use the real pulse-search retry counter,
; making this production sysvar deterministic test scratch here.
TEST_TRANSITIONS EQU STORAGE_ENTRY_RETRY

    IFDEF STORAGE_TEST_SAVE_MISSING
SAVE_TEXT: DB '"TEST" EXT',0
EXPECTED_SAVE_FAILED: DB "SAVE FAILED",0
EXPECTED_SAVE_FAILED_LEN EQU $ - EXPECTED_SAVE_FAILED
    ELSE
    IFDEF STORAGE_TEST_EXTENSION
    IFDEF STORAGE_TEST_WILDCARD
LOAD_TEXT: DB '"" EXT',0
    ELSE
LOAD_TEXT: DB '"TEST" EXT',0
    ENDIF
    ELSE
LOAD_TEXT: DB '"TEST"',0
    ENDIF
LOAD_TEXT_LEN EQU $ - LOAD_TEXT
    ENDIF
EXPECTED:
    DB $17,$00,$31,$30,$20,$52,$45,$4D,$20,$4E,$41,$4D,$45
    DB $44,$20,$4C,$4F,$41,$44,$20,$54,$45,$53,$54,$0D
EXPECTED_LEN EQU $ - EXPECTED

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"
    DS $4000 - $, $FF
    IFDEF STORAGE_TEST_EXTENSION
    SAVEBIN "test_storage_extension_load.bin", $0000, $4000
    ELSE
    SAVEBIN "test_storage_named_load.bin", $0000, $4000
    ENDIF
