; R9 production HOME image. The V1 interpreter is held in Git at cd2f1df.
    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
    INCLUDE "include/sysvars.inc"
    INCLUDE "include/v2_layout.inc"
    DEFINE V2_PRODUCTION
    DEFINE V2_KTAB_HOME
    INCLUDE "include/v2_ktab.inc"
    DEFINE PKG_ABI_HOME          ; R10.9: emit the package service table / assert the pins
    INCLUDE "include/v2_package_abi.inc"
    DEVICE NOSLOT64K
    ORG $0000
    di
    jp V2_COLD_START
    INCLUDE "rom/v2_rst_vectors.inc"
    jp V2_CALC_ENTRY
    INCLUDE "rom/v2_rst30.inc"
V2_RST_38:
    call KBD_ISR_TICK
    ei
    reti
    ORG V2_KTAB_BASE
; RC: no KTAB jump table in production (include/v2_ktab.inc); the space holds the CRC routines of
; SAVE ... ALL instead.
    INCLUDE "rom/v2_saveall_crc.asm"
    ASSERT $ <= V2_KTAB_MAGIC_ADDR
    DS V2_KTAB_MAGIC_ADDR - $, $FF
    DB V2_KTAB_MAGIC
; R10.9 Phase 1: versioned package service table (docs/PACKAGE_ABI.md), in what used
; to be unused $FF padding -- zero HOME-budget cost.  Header, the `jp` slots, the reserved slots
; (append-only; each a trap, 6.4), then the one slot that needs a few bytes of code of its own.
    ASSERT $ == PKG_SVC_HEADER
    DB PKG_SVC_MAGIC, PKG_ABI_MAJOR, PKG_ABI_MINOR, PKG_SVC_COUNT
    ASSERT $ == PKG_SVC_ENTRIES
    PKG_SVC_LIST
    ASSERT PKG_SVC_INDEX == PKG_SVC_COUNT
    ASSERT $ == PKG_SVC_ENTRIES + 3*PKG_SVC_COUNT
    ASSERT $ <= PKG_SVC_MAX_END
; 6.4: each reserved slot traps: a package calling a service this ROM does not have stops with
; runtime error 9 (as a package name that is gone does), instead of running the $FF padding.
    ASSERT (PKG_SVC_CODE - $) % 3 == 0
    DUP (PKG_SVC_CODE - $) / 3
    jp VM_ERR_EXTENSION_NOT_FOUND
    EDUP
    ASSERT $ == PKG_SVC_CODE
; VM_NUM_TO_TEXT ends in a jump to EXROM code (BASIC_NUM_TO_STRING_EXROM, $C09C), but a
; package runs with chunk 6 paged to RAM (OP_CALL_EXT), so calling it directly executes
; whatever RAM is at $C09C.  This slot pages EXROM in around the call (nest-safe: BANK_*
; keep a depth count) and restores the caller's view.  In/Out as VM_NUM_TO_TEXT.
PKG_NUM_TO_TEXT_SAFE:
    push af
    call BANK_PAGE_EXROM_IN
    pop af
    call VM_NUM_TO_TEXT
    push hl
    call BANK_PAGE_EXROM_OUT
    pop hl
    ret
    ASSERT $ <= $0100
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
    ld a,2
    ld (V2_VER_FLAG),a               ; VER: the version stays for the boot draw and the editor's first redraw
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
COMPILE_FUSE_ADD EQU V2_EXROM_FUSE_ADD_ADDR     ; 5.4 (rom/exrom_v2_fuse.asm)
COMPILE_FUSE_CMP EQU V2_EXROM_FUSE_CMP_ADDR
COMPILE_FUSE_GOTO EQU V2_EXROM_FUSE_GOTO_ADDR
BUILTIN_FN_SIN EQU V2_EXROM_FN_SIN_ADDR         ; 5.9 (rom/exrom_v2_float_fn.asm)
BUILTIN_FN_COS EQU V2_EXROM_FN_COS_ADDR
BUILTIN_FN_TAN EQU V2_EXROM_FN_TAN_ADDR
    IFDEF V2_MAINT_AY_BEEP
AY_BEEP EQU V2_EXROM_AY_BEEP_ADDR        ; MAINT (AY BEEP)
    ENDIF

    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    IFNDEF V2_MAINT_AY_BEEP              ; MAINT (AY BEEP): the port-$FE beeper is not used
    INCLUDE "kernel/sound/sound.asm"
    ENDIF
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    IFDEF V2_MAINT_AY_BEEP
    INCLUDE "rom/v2_ay_beep.asm"            ; MAINT (AY BEEP): the HOME pieces
    ENDIF
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/v2_saveall.asm"            ; RC: SAVE ... ALL (owner decision 2)
    INCLUDE "rom/v2_session_undo.asm"
    INCLUDE "rom/v2_version.asm"            ; VER: the ROM's version on the status row at power-on
    INCLUDE "rom/v2_pkg_fp.asm"             ; 6.2: FP_OP, package service 17
; R10.9: the package ABI pins -- every package-visible sysvar / constant must still live
; where include/v2_package_abi.inc says (a mismatch fails the build).
    INCLUDE "rom/v2_lowrom_fill.asm"        ; RC shrink: small routines in the RST-slot padding
    PKG_CONST_LIST
    PKG_PIN_LIST
    DS V2_HOME_IMAGE_END - $, $FF
    SAVEBIN "v2_home.bin", $0000, V2_HOME_IMAGE_END
