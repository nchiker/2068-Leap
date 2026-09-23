; ============================================================================
; rom/test_v2_mode_ulaplus.asm — Architecture B, R8.5 Group 5 (MODE/
; ULAPLUS/PALETTE) smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; COMPILE_MODE/COMPILE_ULAPLUS/COMPILE_PALETTE and rom/exrom_v2_vm_
; core.asm's new OP_MODE/OP_ULAPLUS/OP_PALETTE -- confirmed via this
; milestone's own reuse audit to reach real, unmodified platform code
; directly (kernel/graphics's real GFX_SET_MODE for MODE; two real
; `out (c),a` port writes for ULAPLUS/PALETTE), NOT rom/
; exrom_ulaplus.asm's own KTAB_-coupled parse code. NOT wired into the
; production BASIC dispatch or the shipping EXROM build.
;
; Source program compiled and executed:
;
;   MODE 1
;   ULAPLUS 1
;   PALETTE 5, 200
;
; Verification: MODE's real effect is checked directly via GFX_MODE
; (the real sysvar GFX_SET_MODE itself writes) -- genuine platform-
; primitive coverage, not just "the opcode ran". ULAPLUS/PALETTE are
; pure `out (c),a` port writes with no readable-back sysvar of their
; own on this hardware/emulator combination; VM_ERROR_CODE=0 plus the
; decompiled text confirms the right opcodes compiled and ran without
; error (the underlying port-write mechanism itself is the same one
; BORDER already exercises and this session has already validated many
; times over).
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_mode_ulaplus.sym \
;       rom/test_v2_mode_ulaplus.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_mode_ulaplus_zesarux.bin
;   ts2068-debug run --max-instructions 3000000
;   ts2068-debug timex   (border field)
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ld   a, (GFX_MODE)
    cp   1
    jp   nz, FAIL

    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

SOURCE_TEXT:
    db "MODE 1:ULAPLUS 1:PALETTE 5,200", 0

; ============================================================================
; CHECK_DECOMPILED_TEXT — byte-for-byte against a real captured-then-
; verified rendering (same discipline as every other decompiler test
; this session).
; ============================================================================
CHECK_DECOMPILED_TEXT:
    ld   hl, (DECOMP_OUT_PTR)
    ld   de, DECOMP_OUT_BUF
    or   a
    sbc  hl, de
    ld   de, EXPECTED_TEXT_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   hl, DECOMP_OUT_BUF
    ld   de, EXPECTED_TEXT
    ld   bc, EXPECTED_TEXT_LEN
.cmp:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    dec  bc
    ld   a, b
    or   c
    jr   nz, .cmp
    ret
.fail:
    scf
    ret

EXPECTED_TEXT:
    db "MODE 1", 13
    db "ULAPLUS 1", 13
    db "PALETTE 5,200", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stubs: this file's own test program never exercises PRINT/
; LPRINT/BEEP/SOUND/PAUSE/INPUT, and never registers or calls a
; loadable extension -- same stubbing discipline as every other R8.5
; v2 test this session.
BASIC_STMT_LPRINT_EXROM:
    ret
SOUND_BEEP:
    ret
SOUND_EXROM:
    or a
    ret
IO_READ_KEY:
    xor a
    ret
INT_GET_FRAMES:
    ld hl,0
    ret
EXT2_LOOKUP:
    scf
    ret
EXT2_SLOT_ADDR:
    ret
EXT_CALL_ARG0: equ $8B00
EXT2_TABLE:    equ $8B00

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
; rom/exrom_calc.asm (1772 real lines) is NOT included here: this
; test's own program is pure integer arithmetic -- no float paths are
; ever exercised.
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
; kernel/graphics/graphics.asm IS included here (real, not stubbed) --
; unlike most other v2 tests, this one genuinely needs GFX_SET_MODE's
; own real effect (GFX_MODE) to verify MODE actually reached it.
    INCLUDE "kernel/graphics/graphics.asm"
; kernel/memory/memory.asm is NOT included here -- checked directly:
; neither rom/exrom_v2_vm_core.asm/compiler.asm/decompiler.asm reference
; any MEM_*/PROG_END/PROG_AREA_START/ARRAYS_END/VARS_START symbol, and
; this test never touches the real editor engine.
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_mode_ulaplus.bin", $0000, $4000
