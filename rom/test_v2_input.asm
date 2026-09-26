; ============================================================================
; rom/test_v2_input.asm — Architecture B, R8.5 Group 2 (INPUT close-out)
; smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; COMPILE_INPUT (numeric and string target grammar) and rom/
; exrom_v2_vm_core.asm's new OP_INPUT_NUM/OP_INPUT_STR (a genuine V2-
; native rewrite on top of kernel/io/io.asm's real IO_READ_KEY, NOT a
; port of rom/exrom_input.asm's own basic.asm-dependent mechanism -- see
; docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R8.5 status note).
; NOT wired into the production BASIC dispatch or the shipping EXROM
; build.
;
; Source program compiled and executed:
;
;   INPUT A
;   INPUT B$
;   PRINT A
;   PRINT B$
;
; IO_READ_KEY is REPLACED here with a scripted mock (TEST_KEY_SCRIPT)
; that returns a fixed sequence of "keystrokes" one call at a time,
; instead of the real keyboard matrix -- the same "stub a platform
; primitive this test doesn't need to re-verify" discipline already
; used throughout this session (BEEP/SOUND/etc.), applied here because
; real ZEsarUX keyboard-matrix injection requires the interactive
; resume/type/pause flow (see the 2068-debug skill's own "keyboard
; injection" gotcha), a materially different harness shape than every
; other bounded free-run test this session uses. This validates the
; REAL OP_INPUT_NUM/OP_INPUT_STR opcode logic (echo sequencing, digit
; parsing, sign handling, STRTAB writing) end to end; it does NOT
; re-verify IO_READ_KEY's own real keyboard-matrix behavior (already
; exercised elsewhere in this codebase, not this milestone's concern).
; Script: "42" ENTER (-> INPUT A) then "HI" ENTER (-> INPUT B$).
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_input.sym \
;       rom/test_v2_input.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_input_zesarux.bin
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

    ld   hl, TEST_KEY_SCRIPT
    ld   (TEST_KEY_PTR), hl

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ; Real-memory verification BEFORE decompiling: A (SYMTAB index 0)
    ; must be TAG_INT/42; B$ (STRTAB index 0) must be "HI".
    call CHECK_INPUT_RESULT
    jp   c, FAIL

    ; VM_OUTPUT_ROW must be 4 -- one line per INPUT/PRINT (0-3): each
    ; INPUT advances a line the same way PRINT does (VM_ADVANCE_OUTPUT_
    ; ROW), on top of the two real PRINTs.
    ld   a, (VM_OUTPUT_ROW)
    cp   4
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
    db "INPUT A:INPUT B$:PRINT A:PRINT B$", 0

TEST_KEY_SCRIPT:
    db "42", 13, "HI", 13
; TEST_KEY_PTR is NOT `dw 0` here -- this whole file's own code/data lives
; in the $0000-$3FFF address range these flat 16K test images occupy,
; which real TS2068 hardware (and this harness) maps as genuine ROM:
; writes there silently no-op. A real, previously-latent bug: rom/
; test_v2_print.asm's own TEST_PROGRAM_END uses this exact "dw 0 in the
; ROM image, write to it later" pattern, but is never read back anywhere
; in that file, so the write silently failing never surfaced. Caught
; here via a real ZEsarUX run + single-stepping: "LD (018D),HL" executed
; with the correct HL, but the very next `mem` read of that address came
; back $0000 -- confirmed by checking test_v2_print.asm's own identical
; pattern is dead code, not a working precedent. Fixed by placing this
; cell in genuine RAM instead (the confirmed-free 32-byte gap between
; ARRTAB's own real end, $85E0, and STRTAB_BASE, $8600).
TEST_KEY_PTR: equ $85E0

; ============================================================================
; CHECK_INPUT_RESULT — direct SYMTAB/STRTAB memory reads. A is the
; compiler's first-registered scalar symbol (index 0); B$ is the first-
; registered string symbol (index 0) -- same "compiler assigns indices
; in first-use order" convention every other test this session already
; relies on.
; ============================================================================
CHECK_INPUT_RESULT:
    ld   a, (SYMTAB_BASE)          ; tag byte
    cp   0                          ; TAG_INT
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE+1)
    ld   de, 42
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, (STRTAB_BASE)           ; B$'s own length byte
    cp   2
    jr   nz, .fail
    ld   a, (STRTAB_BASE+1)
    cp   "H"
    jr   nz, .fail
    ld   a, (STRTAB_BASE+2)
    cp   "I"
    jr   nz, .fail
    ret
.fail:
    scf
    ret

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

; Captured from a real ZEsarUX run of this exact test, independently
; cross-checked against CHECK_INPUT_RESULT's own already-verified real
; values (same two-step discipline as every other decompiler test this
; session). "V0"/"S0$" are the compiler's real generated names for A/B$
; (identifiers are not preserved through compile).
EXPECTED_TEXT:
    db "INPUT V0", 13
    db "INPUT S0$", 13
    db "PRINT V0", 13
    db "PRINT S0$", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stubs: this file's own test program never exercises LPRINT/
; BEEP/SOUND/PAUSE, and never registers or calls a loadable extension --
; same stubbing discipline as every other R8.5 v2 test this session.
BASIC_STMT_LPRINT_EXROM:
    ret
SOUND_BEEP:
    ret
SOUND_EXROM:
    or a
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

; IO_READ_KEY -- REPLACED with the scripted mock described in this
; file's own header (real keyboard-matrix injection needs ZEsarUX's
; interactive resume/type/pause flow, a materially different harness
; shape than this session's other bounded free-run tests). Out: A =
; next scripted character. Destroys: AF, HL.
IO_READ_KEY:
    ld   hl, (TEST_KEY_PTR)
    ld   a, (hl)
    inc  hl
    ld   (TEST_KEY_PTR), hl
    ret

; IO_READ_KEY_NONBLOCK -- R8.5 Group 6 (string-result functions):
; INKEY$'s own dependency, not otherwise exercised by this test's own
; INPUT-focused program. Deterministic "no key currently pressed" stub,
; same pattern this test suite already uses for other platform
; dependencies this file doesn't itself need to exercise.
IO_READ_KEY_NONBLOCK:
    xor a
    ret

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
; rom/exrom_calc.asm (1772 real lines) is NOT included here: this
; test's own program is pure integer/string I/O -- no PUSH_FLOAT_LIT,
; no float PRINT -- so none of the float paths that reach the
; calculator are ever exercised. Same stubbing discipline rom/
; test_v2_save_load.asm's own header already established.
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
CALC_PUSH_PI:
    ret
CALC_PUSH_FP_RAW:
    ret
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test never checks real screen bitmap content (only VM_OUTPUT_ROW,
; SYMTAB/STRTAB memory, and the decompiled text), and every real
; PRINT/INPUT-echo text here is short enough to never wrap/scroll -- so
; a bare `ret` for GFX_PRINT_STRING_ATTR is exactly correct (B/C already
; hold the pre-call row/col, which is exactly what a non-wrapping
; print/echo's own real row/col would still be afterward). Same
; stubbing discipline as rom/test_v2_call_fn.asm/rom/test_v2_print.asm's
; own identical fix.
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
; R8.5 Group 6 -- POINT/ATTR need real GFX_* contracts; this
; test never exercises real pixel/attribute content, so a plain
; deterministic stub (same discipline as every other GFX_*
; stub in this file) satisfies the reference without a real
; bitmap.
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
; kernel/memory/memory.asm is NOT included here -- checked directly:
; neither rom/exrom_v2_vm_core.asm/compiler.asm/decompiler.asm reference
; any MEM_*/PROG_END/PROG_AREA_START/ARRAYS_END/VARS_START symbol, and
; this test never touches the real editor engine.
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_input.bin", $0000, $4000
