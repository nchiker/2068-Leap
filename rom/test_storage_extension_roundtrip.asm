; Deterministic SAVE "name" EXT -> LOAD "name" EXT round-trip.
; Only the tape pulse send/receive layer is replaced; both production command
; parsers, header construction, validation, module copy, and installer execute.

    DEFINE FULL_ENGINE_PRESENT
    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE
    INCLUDE "include/exrom_jumptable.inc"

STORAGE_TEST_CAPTURE_HEADER EQU $E000
STORAGE_TEST_CAPTURE_DATA   EQU $E100
STORAGE_TEST_CAPTURE_FLAGS  EQU $E300

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

    ; Start from a deterministic, fully-padded module window.
    xor  a
    ld   hl, EXTENSION_MODULE_BASE
    ld   (hl), a
    ld   de, EXTENSION_MODULE_BASE + 1
    ld   bc, (EXTENSION_MODULE_LIMIT - EXTENSION_MODULE_BASE) - 1
    ldir
    ld   hl, TEST_MODULE
    ld   de, EXTENSION_MODULE_BASE
    ld   bc, TEST_MODULE_LEN
    ldir
    call EXTENSION_MODULE_BASE
    jp   c, .fail_install

    ld   hl, SAVE_TEXT
    call BASIC_DO_SAVE
    jr   c, .fail_save
    ld   a, (STORAGE_OP_STATE)
    cp   2
    jr   nz, .fail_save

    ; Corrupt the installer entry and clear the registry so LOAD must restore
    ; the saved bytes before it can register the module again. Successful LOAD
    ; also proves the captured header's type, length, and ABI fields validate.
    xor  a
    ld   (EXTENSION_MODULE_BASE), a
    ld   (EXTENSION_MAGIC), a
    ld   (EXTENSION_MAGIC + 1), a
    ld   hl, LOAD_TEXT
    ld   de, EDIT_LINE_BUF + 5
    ld   bc, LOAD_TEXT_LEN
    ldir
    ld   hl, EDIT_LINE_BUF + 5
    call BASIC_DO_LOAD
    jr   c, .fail_load
    ld   hl, (EXTENSION_MAGIC)
    ld   de, EXTENSION_REG_MAGIC
    or   a
    sbc  hl, de
    jr   nz, .fail_load
    ld   a, 4
    jr   .done
.fail_save:
    ld   a, 1
    jr   .done
.fail_load:
    ld   a, 3
    jr   .done
.fail_install:
    ld   a, 6
.done:
    out  (PORT_ULA), a
    jr   $

TEST_PROGRESS_HOOK:
    ret

SAVE_TEXT: DB '"TEST" EXT',0
LOAD_TEXT: DB '"TEST" EXT',0
LOAD_TEXT_LEN EQU $ - LOAD_TEXT

TEST_MODULE:
    DB $21, $10, $F4
    DB $11, $17, $F4
    DB $0E, $00
    DB $CD, LOW EXT_SERVICE_REGISTER, HIGH EXT_SERVICE_REGISTER
    DB $C9
    DS 4, 0
    DB "TSTEXT",0
    DB $B7,$C9
TEST_MODULE_LEN EQU $ - TEST_MODULE

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
    SAVEBIN "test_storage_extension_roundtrip.bin", $0000, $4000
