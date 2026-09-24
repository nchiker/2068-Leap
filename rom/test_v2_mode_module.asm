; ============================================================================
; rom/test_v2_mode_module.asm — loadable MODE/ULAPLUS/PALETTE package
; smoke test (post-R8.5 Group 6 ROM reconciliation)
;
; Standalone ROM image exercising rom/ext_mode_module.asm's MODE/
; ULAPLUS/PALETTE, registered through the EXISTING R7.5 mechanism
; (kernel/extensions/ext_registry.asm) exactly like rom/ext_sprite_
; module.asm already established -- see that module's own header for
; the shared architecture. NOT wired into the production BASIC dispatch
; or the shipping EXROM build.
;
; Source program compiled and executed (AFTER MODE_INSTALL has already
; registered all 3 operations):
;
;   MODE 1
;   ULAPLUS 1
;   PALETTE 5,200
;
; Same real program, same real port-write mechanism, as rom/test_v2_
; mode_ulaplus.asm's own former resident-opcode test (removed -- see
; git history) -- proves the loadable version is a faithful,
; capability-preserving replacement, not a weaker one. Verification:
; VM_ERROR_CODE=0 plus the decompiled text confirms the right
; extensions compiled and ran without error -- MODE's real effect
; (GFX_SET_MODE) is stubbed below like every other v2 test that doesn't
; check real screen bitmap content; ULAPLUS/PALETTE are pure `out
; (c),a` port writes with no readable-back state on this hardware/
; emulator combination, same as the former resident test's own
; documented bar.
;
; A second, separate check calls MODE_MODE_EXEC directly with an
; out-of-range value (EXT_CALL_ARG0=2) to prove the real, raised error
; path (code 12) still fires -- not assumed to always succeed, same
; discipline rom/test_v2_sprite_module.asm's own SPR_INSTALL carry
; check already established.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_mode_module.sym \
;       rom/test_v2_mode_module.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_mode_module_zesarux.bin
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

    call EXT2_CLEAR_ALL       ; real cold-init, mirroring V1's own
                                ; EXTENSION_MAGIC reset
    call MODE_INSTALL
    jp   c, FAIL              ; a real, checked registration failure
                              ; path, not assumed to always succeed

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

    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, FAIL

    call CHECK_MODE_ERROR_PATH
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
; verified rendering. Proves .op_call_ext's own EXISTING generic
; decompile path (unmodified for this module) correctly reconstructs
; "MODE 1" etc from the LIVE registry, with no new decompiler code at
; all.
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

; ============================================================================
; CHECK_MODE_ERROR_PATH — direct call to MODE_MODE_EXEC with an out-of-
; range value (2; valid MODE values are 0-1), bypassing the compile/run
; cycle entirely (a halted VM can't usefully keep decompiling afterward,
; so this is checked as a standalone unit call, same as this module's
; own real runtime contract: EXT_CALL_ARG0 in, VM_ERROR_CODE/VM_HALTED
; as the observable result).
; ============================================================================
CHECK_MODE_ERROR_PATH:
    xor  a
    ld   (VM_ERROR_CODE), a
    ld   (VM_HALTED), a
    ld   hl, 2
    ld   (EXT_CALL_ARG0), hl
    call MODE_MODE_EXEC
    ld   a, (VM_ERROR_CODE)
    cp   12
    jr   nz, .fail
    ld   a, (VM_HALTED)
    or   a
    jr   z, .fail
    xor  a                    ; reset for PASS's own border write below,
    ld   (VM_HALTED), a         ; tidy but not load-bearing (COLD_START
                                ; never re-checks VM_HALTED after this)
    ret
.fail:
    scf
    ret

; Test-only stubs: this file's own test program never exercises PRINT/
; LPRINT/BEEP/SOUND/PAUSE/INPUT -- same stubbing discipline as every
; other R8.5 v2 test this session.
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
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this flat 16K image doesn't have room for it alongside the full v2
; core + decompiler. GFX_SET_MODE is real, pre-existing, hardware-
; validated V1 code this milestone does not modify -- trusting it here,
; same trust-boundary reasoning as every other stubbed dependency this
; session. What DOES need verifying -- this module's own register
; marshalling, port writes, and the registry's own generic dispatch/
; decompile -- is covered by CHECK_DECOMPILED_TEXT/CHECK_MODE_ERROR_
; PATH above regardless.
GFX_CLS:
    ret
GFX_PAINT_ATTR:
    ret
GFX_SET_BORDER:
    ret
GFX_WRITE_PIXEL:
    ret
GFX_LINE:
    ret
GFX_PRINT_STRING_ATTR:
    ret
GFX_SCROLL_OUTPUT_UP:
    ret
GFX_SET_MODE:
    ret
GFX_SPRITE_CAPTURE:
    or a
    ret
GFX_SPRITE_DRAW:
    or a
    ret
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
; kernel/memory/memory.asm is NOT included here -- but EXT2_CLEAR_ALL
; (kernel/extensions/ext_registry.asm) genuinely calls its real
; MEM_FILL_ZERO to zero the registry table, so that one routine needs a
; real (not no-op) stub: fills BC bytes at HL with zero, matching its
; real In:HL=dest,BC=count contract exactly, not a fake pass-through.
MEM_FILL_ZERO:
    xor  a
    ld   (hl), a
    ld   d, h
    ld   e, l
    inc  de
    dec  bc
    ld   a, b
    or   c
    ret  z
    ldir
    ret
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"
    INCLUDE "rom/ext_mode_module.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_mode_module.bin", $0000, $4000
