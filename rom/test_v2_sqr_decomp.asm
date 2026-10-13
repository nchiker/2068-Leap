; ============================================================================
; rom/test_v2_sqr_decomp.asm — Architecture B, R8.5 Group 6 (SQR/PI/
; RAD/DEG/SIN) decompile-only smoke test
;
; Compiles "A=SQR(4):B=PI():C=RAD(90):D=DEG(1):E=SIN(30)..." then
; decompiles it WITHOUT ever calling VM_RUN, covering the BUILTIN_FN_
; TABLE rows for SQR/PI/RAD/DEG/SIN and DECOMP_BUILTIN_FN_TABLE's
; matching entries, including PI()'s own 0-argument shape (reusing
; INKEY$'s own already-fixed 0-arg decompile path). NOT wired into the
; production BASIC dispatch or the shipping EXROM build. Built on the
; shared production-shaped test harness (rom/test_v2_harness_home_head.
; inc/_tail.inc + rom/test_v2_harness_exrom.asm) -- see that harness's
; own header for why (post-semantic-milestone test-infrastructure fix,
; docs/POST_R9_TEST_INFRASTRUCTURE.md). This harness now has real
; TEST_V2_NEEDS_CALC support (unlike the old flat-16K image this test
; predates), so a future milestone could extend this into a genuine
; runtime SQR/SIN value check; not attempted here, to keep this
; migration behavior-preserving.
;
; Source program compiled (bytecode only -- this test never VM_RUNs it):
;
;   A=SQR(4):B=PI():C=RAD(90):D=DEG(1):E=SIN(30):F=SIN(-30):G=SIN(20+10)
;
; Real generated names for A-G are V0-V6. PI() still needs "()" -- see
; INKEY$()'s own established precedent (COMPILE_FACTOR.fn_call always
; expects an opening paren after the name, regardless of argcount). F/G
; exercise a unary-minus argument and a nested-expression argument
; respectively -- generic COMPILE_EXPR/decompile shapes ("(0-X)" for
; unary minus, "(A+B)" for a binary op), not special-cased for SIN.
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    DEFINE TEST_V2_NEEDS_DECOMPILE
    INCLUDE "rom/test_v2_harness_home_head.inc"

TEST_CUSTOM_MAIN:
    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl

    ; Decompile-only check: SQR/SIN's own runtime body needs the real
    ; calculator, but decompiling the COMPILED BYTECODE never touches
    ; it -- skip VM_RUN entirely and verify DECOMPILE_PROGRAM's own
    ; table rows directly.
    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, TEST_FAIL

    jp   TEST_PASS

SOURCE_TEXT:
    db "A=SQR(4):B=PI():C=RAD(90):D=DEG(1):E=SIN(30):"
    db "F=SIN(-30):G=SIN(20+10)", 0

EXPECTED_TEXT:
    db "V0 = SQR(4)", 13
    db "V1 = PI()", 13
    db "V2 = RAD(90)", 13
    db "V3 = DEG(1)", 13
    db "V4 = SIN(30)", 13
    db "V5 = SIN(-30)", 13      ; QUAL: -30 is folded at compile time (Q-05)
    db "V6 = SIN((20+10))", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; ============================================================================
; CHECK_DECOMPILED_TEXT — byte-for-byte against a real captured-then-
; verified rendering.
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

; Test-only stub: this test's own SOURCE_TEXT never calls LPRINT, but
; rom/exrom_v2_vm_core.asm's own OP_LPRINT_NUM/STR still reference the
; symbol unconditionally.
BASIC_STMT_LPRINT_EXROM:
    ret

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
; Test-only stubs: this file's own test program never exercises BEEP/
; SOUND/PAUSE/INPUT, and never registers or calls a loadable extension.
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
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"
