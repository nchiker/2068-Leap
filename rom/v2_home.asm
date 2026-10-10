; R9 production HOME image. The V1 interpreter is held in Git at cd2f1df.
    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
    INCLUDE "include/sysvars.inc"
    INCLUDE "include/v2_layout.inc"
    DEFINE V2_PRODUCTION
    DEFINE V2_KTAB_HOME
    INCLUDE "include/v2_ktab.inc"
    DEVICE NOSLOT64K
    ORG $0000
    di
    jp V2_COLD_START
    DS $0028 - $, $FF
    jp V2_CALC_ENTRY
    DS $0038 - $, $FF
V2_RST_38:
    call KBD_ISR_TICK
    ei
    reti
    ORG V2_KTAB_BASE
    V2_KTAB_LIST
    ASSERT $ == V2_KTAB_END
    DB V2_KTAB_MAGIC
    DS $0100 - $, $FF

V2_COLD_START:
    ld sp, V2_MACHINE_STACK_TOP
    call MEM_COLD_INIT
    xor a
    ld (PORT_FF_SHADOW), a
    out (PORT_SCLD), a
    call MEM_INIT
    ld hl, V2_SOURCE_END
    ld (VARS_START), hl
    call EXT2_CLEAR_ALL
    call KBD_ISR_INIT
    im 1
    ei
    call BANK_PAGE_EXROM_IN
    jp V2_EXROM_ENTRY_ADDR           ; EXROM resident production shell

V2_CALC_ENTRY:
    call BANK_PAGE_EXROM_IN
    jp V2_EXROM_CALCULATE_ADDR       ; calculator entry, EXROM
CALC_EXIT_TRAMPOLINE:
    jp BANK_PAGE_EXROM_OUT

; The source ceiling comes from the integrated R8.9 ledger. The line store
; checks VARS_START before growing; this is its first production setting.
; VM helper references formerly resolved inside standalone single-bank
; harnesses. These fixed EXROM entries preserve the same call contracts.
CALC_INT_TO_FP EQU V2_EXROM_INT_TO_FP_ADDR
CALC_FP_TO_INT EQU V2_EXROM_FP_TO_INT_ADDR
CALC_PUSH_PI EQU V2_EXROM_PUSH_PI_ADDR
CALC_PUSH_FP_RAW EQU V2_EXROM_PUSH_FP_RAW_ADDR
CALC_SP_TO_NEXT_FREE_PTR EQU V2_EXROM_SP_TO_PTR_ADDR
SOUND_EXROM EQU V2_EXROM_SOUND_ADDR
BASIC_NUM_TO_STRING_EXROM EQU V2_EXROM_NUM_TO_STRING_ADDR
BASIC_FLOAT_TO_STRING_EXROM EQU V2_EXROM_FLOAT_TO_STRING_ADDR
DECOMP_END_ADDR EQU V2_DECOMP_END_ADDR
MEM_CLEAR_V2 EQU V2_EXROM_CLEAR_ADDR

    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    DS V2_HOME_IMAGE_END - $, $FF
    SAVEBIN "v2_home.bin", $0000, V2_HOME_IMAGE_END
