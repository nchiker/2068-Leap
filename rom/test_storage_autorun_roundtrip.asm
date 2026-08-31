; Deterministic SAVE "name" LINE 2 -> LOAD "name" autorun round-trip.
; Only physical tape pulse I/O is replaced by the EXROM test transport.

    DEFINE FULL_ENGINE_PRESENT
    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE
    INCLUDE "include/exrom_jumptable.inc"

STORAGE_TEST_CAPTURE_HEADER EQU $E000

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
    ld   hl, TEST_PROGRESS_HOOK
    ld   (STORAGE_PROGRESS_HOOK), hl

    ld   hl, TEST_PROGRAM
    ld   de, PROG_AREA_START
    ld   bc, TEST_PROGRAM_LEN
    ldir
    ld   hl, PROG_AREA_START + TEST_PROGRAM_LEN
    ld   (PROG_END), hl

    ld   hl, SAVE_TEXT
    call BASIC_DO_SAVE
    IFDEF STORAGE_TEST_AUTORUN_INVALID
    jr   nc, .fail_save
    ld   a, 4
    jr   .done
    ENDIF
    jr   c, .fail_save
    ld   hl, (STORAGE_TEST_CAPTURE_HEADER + 13)
    IFDEF STORAGE_TEST_AUTORUN_OUT_OF_RANGE
    ld   de, 3
    ELSE
    ld   de, 2
    ENDIF
    or   a
    sbc  hl, de
    jr   nz, .fail_header

    xor  a
    ld   (TEST_MARKER), a
    ld   hl, LOAD_TEXT
    ld   de, EDIT_LINE_BUF + 5
    ld   bc, LOAD_TEXT_LEN
    ldir
    ld   hl, EDIT_LINE_BUF + 5
    call BASIC_DO_LOAD
    jr   c, .fail_load
    ld   a, (TEST_MARKER)
    IFDEF STORAGE_TEST_AUTORUN_OUT_OF_RANGE
    or   a
    jr   nz, .fail_run
    ld   a, (STORAGE_REQUEST_TYPE)
    or   a
    jr   nz, .fail_target
    jr   .pass
    ENDIF
    cp   90
    jr   z, .pass
    ld   hl, (CHECK_ERROR_COUNT)
    ld   a, h
    or   l
    jr   nz, .fail_check
    ld   hl, (CUR_EXEC_STMT)
    ld   de, PROG_AREA_START + 6
    or   a
    sbc  hl, de
    jr   nz, .fail_target
    jr   .fail_run
.pass:
    ld   a, 4
    jr   .done
.fail_save:
    ld   a, 1
    jr   .done
.fail_header:
    ld   a, 2
    jr   .done
.fail_load:
    ld   a, 3
    jr   .done
.fail_run:
    ld   a, 6
    jr   .done
.fail_check:
    ld   a, 5
    jr   .done
.fail_target:
    ld   a, 7
.done:
    out  (PORT_ULA), a
    jr   $

TEST_PROGRESS_HOOK:
    ret

SAVE_TEXT:
    IFDEF STORAGE_TEST_AUTORUN_ZERO
    DB '"TEST" LINE 0',0
    ELSE
    IFDEF STORAGE_TEST_AUTORUN_TRAILING
    DB '"TEST" LINE 2 EXTRA',0
    ELSE
    IFDEF STORAGE_TEST_AUTORUN_OUT_OF_RANGE
    DB '"TEST" LINE 3',0
    ELSE
    DB '"TEST" LINE 2',0
    ENDIF
    ENDIF
    ENDIF
LOAD_TEXT: DB '"TEST"',0
LOAD_TEXT_LEN EQU $ - LOAD_TEXT

; Two ordinary stored statements. Autorun index 2 must skip the REM and
; execute only the POKE marker statement.
TEST_PROGRAM:
    DW 4
    DB "REM",$0D
    DW 14
    DB "POKE 59648,90",$0D
TEST_PROGRAM_LEN EQU $ - TEST_PROGRAM
TEST_MARKER EQU $E900

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"
    ASSERT $ <= $4000
    IF $ < $4000
        DS $4000 - $, $FF
    ENDIF
    SAVEBIN "test_storage_autorun_roundtrip.bin", $0000, $4000
