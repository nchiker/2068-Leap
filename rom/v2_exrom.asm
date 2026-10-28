; R9 production EXROM: retained platform services and V2 interactive shell.
    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
    DEFINE V2_PRODUCTION        ; RC: leave out the legacy-only routines (as rom/v2_home.asm)
    DEFINE V2_FAST_REDRAW       ; STUDY: selective redraw of the active line while typing
V2_RD_WRAPS     EQU $BEC1       ; STUDY: wrap-row count of the active line at the last full/selective redraw
V2_RD_INDEX     EQU $BEC2       ; STUDY: CUR_EDIT_INDEX at the last redraw (2 bytes)
V2_RD_NEWROW    EQU $BEC4       ; STUDY: scratch of the two-line path
V2_RD_NEWH      EQU $BEC5
    INCLUDE "include/sysvars.inc"
    INCLUDE "include/v2_layout.inc"
    INCLUDE "build/v2_crossbank.inc"
    INCLUDE "include/keys.inc"
    INCLUDE "include/v2_ktab.inc"
    INCLUDE "include/v2_package_abi.inc"   ; R10.9: version words (macros are not expanded here)
    DEFINE STORAGE_VERSIONED               ; R10.9: stamp and check the tape version word
    V2_KTAB_LIST
    DEVICE NOSLOT64K
    ORG V2_EXROM_ENTRY_ADDR
V2_EXROM_ENTRY:
    ld hl,ARR2_BASE
    ld (PAS_END),hl              ; cold start: the Array Store is empty
    jp V2_COMMAND_LOOP

; RC: the packed entry slots (include/v2_ktab.inc). Each checks the HOME/EXROM contract first.
    MACRO V2_EXROM_SLOT slotaddr, target
    ASSERT $ == slotaddr
    call V2_VERIFY_KTAB
    jp target
    ENDM
    V2_EXROM_SLOT V2_EXROM_CALCULATE_ADDR, CALC_EXROM_ENTRY
    V2_EXROM_SLOT V2_EXROM_INT_TO_FP_ADDR, CALC_INT_TO_FP
    V2_EXROM_SLOT V2_EXROM_FP_TO_INT_ADDR, CALC_FP_TO_INT
    V2_EXROM_SLOT V2_EXROM_PUSH_PI_ADDR, CALC_PUSH_PI
    V2_EXROM_SLOT V2_EXROM_PUSH_FP_RAW_ADDR, CALC_PUSH_FP_RAW
    V2_EXROM_SLOT V2_EXROM_SOUND_ADDR, SOUND_EXROM
    V2_EXROM_SLOT V2_EXROM_NUM_TO_STRING_ADDR, BASIC_NUM_TO_STRING_EXROM
    V2_EXROM_SLOT V2_EXROM_FLOAT_TO_STRING_ADDR, BASIC_FLOAT_TO_STRING_EXROM
    V2_EXROM_SLOT V2_EXROM_SP_TO_PTR_ADDR, CALC_SP_TO_NEXT_FREE_PTR
    V2_EXROM_SLOT V2_EXROM_CLEAR_ADDR, MEM_CLEAR_V2
    IFDEF V2_MAINT_AY_BEEP
    V2_EXROM_SLOT V2_EXROM_AY_BEEP_ADDR, AY_BEEP
    ENDIF
    V2_EXROM_SLOT V2_EXROM_FUSE_ADD_ADDR, COMPILE_FUSE_ADD_X    ; 5.4
    V2_EXROM_SLOT V2_EXROM_FUSE_CMP_ADDR, COMPILE_FUSE_CMP_X
    V2_EXROM_SLOT V2_EXROM_FUSE_GOTO_ADDR, COMPILE_FUSE_GOTO_X
    V2_EXROM_SLOT V2_EXROM_FN_SIN_ADDR, BUILTIN_FN_SIN          ; 5.9
    V2_EXROM_SLOT V2_EXROM_FN_COS_ADDR, BUILTIN_FN_COS
    V2_EXROM_SLOT V2_EXROM_FN_TAN_ADDR, BUILTIN_FN_TAN
    ASSERT $ == V2_EXROM_ARRSVC_ADDR
    INCLUDE "rom/exrom_v2_arrstore.asm"
; V2_VERIFY_KTAB -- the HOME/EXROM contract check every entry slot makes first.
V2_VERIFY_KTAB:
    ld a, (V2_KTAB_MAGIC_ADDR)
    cp V2_KTAB_MAGIC
    ret z
.mismatch:
    jr .mismatch

    INCLUDE "rom/exrom_v2_fuse.asm"        ; 5.4: the compiler's combined-opcode peepholes
    INCLUDE "kernel/storage/storage.asm"
    IFDEF STORAGE_TEST_FAKE_RECEIVE
        INCLUDE "rom/exrom_storage_test.asm"
    ELSE
        IFDEF STORAGE_TEST_FAKE_SEND
            INCLUDE "rom/exrom_storage_test.asm"
        ENDIF
    ENDIF
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_calc.asm"
    INCLUDE "rom/exrom_v2_float_fn.asm"    ; 5.9: the float built-ins
    INCLUDE "rom/exrom_sound.asm"
    IFDEF V2_MAINT_AY_BEEP
    INCLUDE "rom/v2_ay_beep.asm"            ; MAINT (AY BEEP): the EXROM pieces
    ENDIF
    INCLUDE "rom/exrom_editor.asm"
    INCLUDE "rom/exrom_v2_shell.asm"
    DS V2_EXROM_IMAGE_END - $, $FF
    SAVEBIN "v2_exrom.bin", V2_EXROM_ENTRY_ADDR, V2_EXROM_IMAGE_SIZE
