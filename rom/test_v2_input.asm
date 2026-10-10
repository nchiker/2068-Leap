; ============================================================================
; rom/test_v2_input.asm — Architecture B, R8.5 Group 2 (INPUT close-out)
; smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; COMPILE_INPUT (numeric and string target grammar) and rom/
; exrom_v2_vm_core.asm's new OP_INPUT_NUM/OP_INPUT_STR (a genuine V2-
; native rewrite on top of kernel/io/io.asm's real IO_READ_KEY, NOT a
; port of rom/exrom_input.asm's own basic.asm-dependent mechanism). NOT
; wired into the production BASIC dispatch or the shipping EXROM build.
; Built on the shared production-shaped test harness (rom/
; test_v2_harness_home_head.inc/_tail.inc + rom/test_v2_harness_exrom.
; asm) -- see that harness's own header for why (post-semantic-milestone
; test-infrastructure fix, docs/v2/POST_R9_TEST_INFRASTRUCTURE.md).
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
; instead of the real keyboard matrix. This validates the REAL OP_INPUT_
; NUM/OP_INPUT_STR opcode logic (echo sequencing, digit parsing, sign
; handling, STRTAB writing) end to end; it does NOT re-verify IO_READ_
; KEY's own real keyboard-matrix behavior. Script: "42" ENTER (-> INPUT
; A) then "HI" ENTER (-> INPUT B$).
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    DEFINE TEST_V2_NEEDS_DECOMPILE
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

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

    ld   hl, TEST_KEY_SCRIPT
    ld   (TEST_KEY_PTR), hl

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    ; Real-memory verification BEFORE decompiling: A (SYMTAB index 0)
    ; must be TAG_INT/42; B$ (STRTAB index 0) must be "HI".
    call CHECK_INPUT_RESULT
    jp   c, TEST_FAIL

    ; VM_OUTPUT_ROW must be 4 -- one line per INPUT/PRINT (0-3): each
    ; INPUT advances a line the same way PRINT does.
    ld   a, (VM_OUTPUT_ROW)
    cp   4
    jp   nz, TEST_FAIL

    call DECOMPILE_PROGRAM
    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, TEST_FAIL

    jp   TEST_PASS

SOURCE_TEXT:
    db "INPUT A:INPUT B$:PRINT A:PRINT B$", 0

TEST_KEY_SCRIPT:
    db "42", 13, "HI", 13
; TEST_KEY_PTR is real RAM (the confirmed-free 32-byte gap between
; ARRTAB's own real end, $85E0, and STRTAB_BASE, $8600) -- this whole
; file's own code/data lives in the ROM-mapped $0000-$3FFF range, where
; writes silently no-op.
TEST_KEY_PTR: equ $85E0

; ============================================================================
; CHECK_INPUT_RESULT — direct SYMTAB/STRTAB memory reads. A is the
; compiler's first-registered scalar symbol (index 0); B$ is the first-
; registered string symbol (index 0).
; ============================================================================
CHECK_INPUT_RESULT:
    TSYM_LD8 0  ; tag byte
    cp   0                          ; TAG_INT
    jr   nz, .fail
    TSYM_LD16 1
    ld   de, 42
    or   a
    sbc  hl, de
    jr   nz, .fail
    TSTR_LD8 0  ; B$'s own length byte
    cp   2
    jr   nz, .fail
    TSTR_LD8 1
    cp   "H"
    jr   nz, .fail
    TSTR_LD8 2
    cp   "I"
    jr   nz, .fail
    ret
.fail:
    scf
    ret

; ============================================================================
; CHECK_DECOMPILED_TEXT — byte-for-byte against a real captured-then-
; verified rendering. "V0"/"S0$" are the compiler's real generated names
; for A/B$.
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
    db "INPUT V0", 13
    db "INPUT S0$", 13
    db "PRINT V0", 13
    db "PRINT S0$", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stubs: this file's own test program never exercises LPRINT/
; BEEP/SOUND/PAUSE, and never registers or calls a loadable extension.
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
; file's own header. Out: A = next scripted character. Destroys: AF, HL.
IO_READ_KEY:
    ld   hl, (TEST_KEY_PTR)
    ld   a, (hl)
    inc  hl
    ld   (TEST_KEY_PTR), hl
    ret

IO_READ_KEY_NONBLOCK:
    xor a
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
    INCLUDE "rom/exrom_format.asm"

    INCLUDE "rom/test_v2_harness_home_tail.inc"
