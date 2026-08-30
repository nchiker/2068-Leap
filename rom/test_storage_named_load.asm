; Deterministic regression for LOAD "name" filename retention.
; Pair with exrom_storage_test.bin, whose only substitution is the
; tape-pulse receiver beneath the real STORAGE_LOAD implementation.

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

    ; Match the live editor layout: BASIC_DO_LOAD receives the quote at
    ; EDIT_LINE_BUF+5 and copies the name backward into offset zero.
    ld   hl, LOAD_TEXT
    ld   de, EDIT_LINE_BUF + 5
    ld   bc, LOAD_TEXT_LEN
    ldir
    ld   hl, EDIT_LINE_BUF + 5
    call BASIC_DO_LOAD

    ld   a, (TEST_TRANSITIONS)
    cp   %00000111
    jr   nz, .fail_state
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

LOAD_TEXT: DB '"TEST"',0
LOAD_TEXT_LEN EQU $ - LOAD_TEXT
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
    SAVEBIN "test_storage_named_load.bin", $0000, $4000
