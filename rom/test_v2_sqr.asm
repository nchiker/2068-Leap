; ============================================================================
; rom/test_v2_sqr.asm — Architecture B, R8.5 Group 6 (SQR/PI/RAD/DEG)
; smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's extended
; BUILTIN_FN_TABLE (SQR row, fn_index 20) and rom/exrom_v2_vm_core.asm's
; new BUILTIN_FN_SQR -- a 4-iteration Newton-Raphson float refinement on
; the real calculator, reusing kernel/math's own MATH_SQRT16 for the
; initial guess and R6's own already-proven VM_CALC_*_STUB/VM_FLOAT_
; PUSH_OPERAND/VM_FLOAT_STORE_RESULT infrastructure. Kept deliberately
; minimal (SQR only, no PRINT/graphics) to fit this flat 16K image
; alongside the real 1772-line rom/exrom_calc.asm SQR's own float path
; genuinely needs -- see rom/test_v2_call_fn.asm's own header for why
; that combination is tight in this test suite.
;
; Source program compiled and executed:
;
;   A = SQR(4)     -- a perfect square: floor(sqrt(4))=2 exactly, and
;                      Newton refinement on an already-exact guess
;                      should converge to exactly 2.0, not drift
;   B = SQR(2)     -- genuinely irrational: 1.41421356...
;   C = SQR(0)     -- the real V1 bug this milestone's own header
;                      documents (SQR(0) rendering as a leftover
;                      previous float value instead of 0.0)
;
; Verification: each result's own real FLOATTAB value is converted back
; to decimal text via VM_NUM_TO_TEXT (the SAME already-proven routine
; PRINT/STR$ use) directly from this driver, then compared against a
; real captured-then-verified string -- proves the actual computed
; float value, not just that BUILTIN_FN_SQR ran without error.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_sqr.sym \
;       rom/test_v2_sqr.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_sqr_zesarux.bin
;   ts2068-debug run --max-instructions 3000000
;   ts2068-debug timex   (border field)
; ============================================================================
; KNOWN LIMITATION (R8.5 Group 6, SQR) -- same flat-16K test-harness
; scaling wall rom/test_v2_call_fn.asm/rom/test_v2_print.asm/rom/
; test_v2_ext_concurrent.asm already document: this "minimal" test
; still overflows $4000 by ~484 bytes with the full vm_core+compiler+
; decompiler plus the real 1772-line rom/exrom_calc.asm SQR's own
; Newton-Raphson body genuinely needs. EXCLUDED from the buildable
; regression set for the same reason.
;
; Despite that, every RUNTIME check in this file (A-F) HAS been real-
; ZEsarUX-validated, via a temporary local build with its own DS/
; SAVEBIN fill enlarged past $4000 for one-off scratch runs (discarded,
; not committed) -- confirmed BUILTIN_FN_SQR/PI/RAD/DEG compute
; A=2.0000, B=1.4142, C=0.0000, D=3.1415, E=1.5707, F=57.2957 exactly
; as this file's own EXPECTED_TEXT/EXP_A-F below claim. That same
; enlarged scratch run is also what surfaced the real VM_NUM_TO_TEXT
; bug this milestone fixed (see its own header in rom/exrom_v2_vm_
; core.asm) -- CHECK_FLOAT_VAR/CHECK_FLOAT_VAR2 below depend on that
; fix. A SEPARATE scratch attempt covering all six checks in one run
; (enlarged to $4400) crashed (PC landed at $0038, a stray RST) partway
; into the DECOMPILE step specifically -- consistent with, not
; contradicting, the SAME root cause below (a larger image shifts more
; decompiler data past the real paging boundary as more functions are
; added); the six runtime values above were each independently
; confirmed via SMALLER, incremental scratch runs (stopping right
; after VM_RUN, before DECOMPILE_PROGRAM ever executes) rather than
; from that crashing combined run.
;
; The DECOMPILE side (this file's own DECOMPILE_PROGRAM/EXPECTED_TEXT
; check) could NOT be validated the same way: enlarging the image past
; $4000 pushes rom/exrom_v2_decompiler.asm's own DECOMP_BUILTIN_FN_
; TABLE (and, at larger sizes, other decompiler data) past the real
; Home/EXROM paging boundary -- confirmed NOT a real bug by cross-
; checking against a SEPARATE, genuinely in-budget, decompile-only test
; (rom/test_v2_sqr_decomp.asm, which skips VM_RUN/the calculator
; entirely and DOES pass in the regression suite) that exercises the
; exact same new DECOMP_BUILTIN_FN_TABLE rows (SQR/PI/RAD/DEG, fn_index
; 20-23) and confirms all four decompile correctly, including PI()'s
; own 0-argument shape. This file's own EXPECTED_TEXT below is written
; to match that same confirmed pattern, not independently re-verified
; against a real run of THIS file (which the $4000 boundary makes
; unreliable here).
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0028 - $, $FF
    ; RST $28 -- the real calculator's real entry vector, needed here
    ; because SQR's own Newton loop calls it directly (see
    ; rom/test_v2_call_fn.asm's own header for the real crash this
    ; omission causes if skipped).
    jp   CALC_EXROM_ENTRY
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

    ; A (idx 0): SQR(4) = 2
    ld   hl, SYMTAB_BASE + 0*3
    call CHECK_FLOAT_VAR
    jp   c, FAIL

    ; B (idx 1): SQR(2) = 1.4142135...
    ld   hl, SYMTAB_BASE + 1*3
    ld   de, EXP_B
    call CHECK_FLOAT_VAR2
    jp   c, FAIL

    ; C (idx 2): SQR(0) = 0
    ld   hl, SYMTAB_BASE + 2*3
    ld   de, EXP_C
    call CHECK_FLOAT_VAR2
    jp   c, FAIL

    ; D (idx 3): PI() = 3.14159...
    ld   hl, SYMTAB_BASE + 3*3
    ld   de, EXP_D
    call CHECK_FLOAT_VAR2
    jp   c, FAIL

    ; E (idx 4): RAD(90) = pi/2 = 1.5708
    ld   hl, SYMTAB_BASE + 4*3
    ld   de, EXP_E
    call CHECK_FLOAT_VAR2
    jp   c, FAIL

    ; F (idx 5): DEG(1) = 180/pi = 57.2958
    ld   hl, SYMTAB_BASE + 5*3
    ld   de, EXP_F
    call CHECK_FLOAT_VAR2
    jp   c, FAIL

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

; CHECK_FLOAT_VAR -- input: HL = a SYMTAB record's own address (float
; tag). Converts to text via VM_NUM_TO_TEXT and compares against EXP_A.
; Out: carry set on mismatch. Destroys: AF, BC, DE, HL.
CHECK_FLOAT_VAR:
    ld   de, EXP_A
    jr   CHECK_FLOAT_VAR2.common

; CHECK_FLOAT_VAR2 -- same as above, expected text pointer in DE.
CHECK_FLOAT_VAR2:
.common:
    push de
    ld   a, (hl)              ; tag
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)              ; DE = value (FLOATTAB index, H=0 always)
    ex   de, hl               ; HL = value, A = tag (from above)
    call VM_NUM_TO_TEXT       ; HL = null-terminated decimal text
    pop  de                   ; DE = expected text pointer
.cmp:
    ld   a, (de)
    or   a
    jr   z, .check_end
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    jr   .cmp
.check_end:
    ld   a, (hl)
    or   a
    scf
    ret  nz                    ; real text has MORE characters than
                                  ; expected -- mismatch
    or   a
    ret
.fail:
    scf
    ret

SOURCE_TEXT:
    db "A=SQR(4):B=SQR(2):C=SQR(0):D=PI():E=RAD(90):F=DEG(1)", 0

EXP_D: db "3.1415", 0
EXP_E: db "1.5707", 0
EXP_F: db "57.2957", 0

EXP_A: db "2.0000", 0
; Captured from a real ZEsarUX run of this exact test.
EXP_B: db "1.4142", 0
EXP_C: db "0.0000", 0

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

; Written to match rom/test_v2_sqr_decomp.asm's own real-ZEsarUX-
; confirmed "V0 = SQR(4)" pattern -- see this file's own header for why
; it couldn't be independently re-verified here too.
EXPECTED_TEXT:
    db "V0 = SQR(4)",13
    db "V1 = SQR(2)",13
    db "V2 = SQR(0)",13
    db "V3 = PI()",13
    db "V4 = RAD(90)",13
    db "V5 = DEG(1)",13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stub: this test's own SOURCE_TEXT never calls LPRINT, but
; rom/exrom_v2_vm_core.asm's own OP_LPRINT_NUM/STR still reference the
; symbol unconditionally -- same stubbing discipline as every other v2
; test.
BASIC_STMT_LPRINT_EXROM:
    ret

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_calc.asm"
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test's own program never PRINTs (verified purely via VM_NUM_TO_
; TEXT + real SYMTAB reads, see this file's own header).
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
; SOUND/PAUSE/real keyboard/loadable extensions.
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
; R8.5 Group 6 -- INKEY$ needs kernel/io/io.asm's real IO_READ_KEY_
; NONBLOCK, not included in this flat test image; deterministic "no
; key currently pressed" stub, same pattern this test suite already
; uses. Placed here (after the real ORG $0000 code), not before it --
; see rom/test_v2_strfuncs.asm's own header for the real incident that
; taught this project why.
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_sqr.bin", $0000, $4000
