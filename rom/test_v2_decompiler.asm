; ============================================================================
; rom/test_v2_decompiler.asm — Architecture B, R8 Phase 1 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_decompiler.asm's own
; DECOMPILE_PROGRAM entry point against a real program compiled by
; rom/exrom_v2_compiler.asm -- covering every opcode this decompiler's own
; R1-R3 scope claims (PUSH_I8/PUSH_I16, LOAD_VAR/STORE_VAR, ADD/SUB/MUL/
; DIV/CMP_LT/CMP_EQ, JMP/JMPZ via GOTO and IF...THEN GOTO, FOR_INIT/
; FOR_NEXT), a real forward-referenced label, and a real backward-
; referenced FOR loop -- not a full V2 round trip yet, just "does this
; decompiler produce a valid, re-lexable reconstruction of a real
; compiled program." This test never VM_RUNs the program; the decompiler
; works directly on VM_CODE_BASE's own compiled bytes. NOT wired into the
; production BASIC dispatch or the shipping EXROM build. Built on the
; shared production-shaped test harness (rom/test_v2_harness_home_head.
; inc/_tail.inc + rom/test_v2_harness_exrom.asm) -- see that harness's
; own header for why (post-semantic-milestone test-infrastructure fix,
; docs/POST_R9_TEST_INFRASTRUCTURE.md).
;
; Source program compiled (bytecode only):
;
;   A=3+4
;   B=A*2
;   IF B<10 THEN GOTO SKIP
;   A=999
;   SKIP:
;   C=0
;   FOR I=1 TO 3
;   C=C+I
;   NEXT I
;
; Symbol declaration order (CSYM_FIND_OR_CREATE, first appearance):
;   0=A 1=B 2=C 3=I
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
    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    call CHECK_RESULT
    jp   c, TEST_FAIL

    jp   TEST_PASS

; ============================================================================
; CHECK_RESULT — the reconstructed text at DECOMP_OUT_BUF must match
; EXPECTED_TEXT byte-for-byte, and DECOMP_OUT_PTR must land exactly
; EXPECTED_TEXT_LEN bytes past DECOMP_OUT_BUF (no trailing garbage).
; Out: carry clear = pass, carry set = fail
; ============================================================================
CHECK_RESULT:
    ld   hl, (DECOMP_OUT_PTR)
    ld   de, DECOMP_OUT_BUF
    or   a
    sbc  hl, de              ; HL = actual output length
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

SOURCE_TEXT:
    db "A=3+4:B=A*2:IF B<10 THEN GOTO SKIP:A=999:SKIP:"
    db "C=0:FOR I=1 TO 3:C=C+I:NEXT I", 0

; EXPECTED_TEXT — filled in from a real DECOMP_OUT_BUF readback. A/B/C/I
; -> V0/V1/V2/V3 (first-appearance declaration order); L25/L30 are the
; IF...THEN GOTO's own two synthesized branch-target labels -- L25 (the
; JMPZ's own "false" fallthrough, landing exactly on the very next
; statement) is a real, harmless, documented characteristic: pass 1
; records every JMP/JMPZ target it walks over, including this one,
; before pass 2's own IF-pattern collapse decides it needs no separate
; statement of its own -- valid, re-lexable text either way.
EXPECTED_TEXT:
    db "V0 = (3+4)", 13
    db "V1 = (V0*2)", 13
    db "IF (V1<10) THEN GOTO L30", 13
    db "L25:", 13
    db "V0 = 999", 13
    db "L30:", 13
    db "V2 = 0", 13
    db "FOR V3 = 1 TO 3 STEP 1", 13   ; R8.5 Group 5 -- FOR always
                                        ; renders STEP now, even when
                                        ; the source omitted it (a
                                        ; STEP-less FOR compiles a
                                        ; literal step of 1)
    db "V2 = (V2+V3)", 13
    db "NEXT V3", 13
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
EXT_CALL_RESULT: equ $8B00             ; 6.1: OP_CALL_EXT reads it (test stub)
EXT2_TABLE:    equ $8B00

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
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"
