; ============================================================================
; rom/test_v2_for_step.asm — Architecture B, R8.5 Group 5 (FOR...STEP +
; EXIT FOR) smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; COMPILE_FOR (optional STEP clause) and COMPILE_EXIT_FOR, and rom/
; exrom_v2_vm_core.asm's new VM_FOR_STEP-aware OP_FOR_INIT/OP_FOR_NEXT
; (step-based increment, sign-aware loop-continuation direction). NOT
; wired into the production BASIC dispatch or the shipping EXROM build.
; Built on the shared production-shaped test harness (rom/
; test_v2_harness_home_head.inc/_tail.inc + rom/test_v2_harness_exrom.
; asm) -- see that harness's own header for why (post-semantic-milestone
; test-infrastructure fix, docs/v2/POST_R9_TEST_INFRASTRUCTURE.md).
;
; Source program compiled and executed:
;
;   C=0:FOR I=1 TO 10 STEP 2:C=C+I:NEXT I
;   D=0:FOR J=10 TO 1 STEP -3:D=D+J:NEXT J
;   E=0:FOR K=1 TO 100:IF K>3 THEN EXIT FOR ENDIF:E=K:NEXT K
;   PRINT C:PRINT D:PRINT E
;
; Exercises: a positive STEP > 1 (I=1,3,5,7,9 -- 9+2=11>10 stops -- catches
; an off-by-one a naive "STEP always 1" carryover would miss), a negative
; STEP (J=10,7,4,1 -- 1-3=-2<1 stops -- proves the sign-aware comparison
; direction is genuinely reached, not just parsed), and EXIT FOR inside a
; nested block-IF body (K=1,2,3 accepted, K=4 exits before E is updated
; -- proves COMPILE_EXIT_FOR's own JMP/fixup mechanism composes correctly
; with COMPILE_IF_BLOCK's own recursive compile, and that the runtime JMP
; genuinely lands past NEXT K, not just that it compiles).
; ============================================================================

    DEFINE TEST_V2_NEEDS_DECOMPILE
    DEFINE TEST_V2_CHECK_DECOMPILED_TEXT
    INCLUDE "rom/test_v2_harness_home_head.inc"

SOURCE_TEXT:
    db "C=0:FOR I=1 TO 10 STEP 2:C=C+I:NEXT I:"
    db "D=0:FOR J=10 TO 1 STEP -3:D=D+J:NEXT J:"
    db "E=0:FOR K=1 TO 100:IF K>3 THEN EXIT FOR ENDIF:E=K:NEXT K:"
    db "PRINT C:PRINT D:PRINT E", 0

; ============================================================================
; TEST_CHECK_RESULT — direct SYMTAB memory reads. Compiler assigns
; indices in first-use order: 0=C, 1=I, 2=D, 3=J, 4=E, 5=K. Also checks
; VM_OUTPUT_ROW (must be 3 -- one line per PRINT).
; ============================================================================
TEST_CHECK_RESULT:
    ld   a, (SYMTAB_BASE + 0*3)     ; C's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 0*3 + 1)
    ld   de, 25
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, (SYMTAB_BASE + 2*3)     ; D's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 2*3 + 1)
    ld   de, 22
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, (SYMTAB_BASE + 4*3)     ; E's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 4*3 + 1)
    ld   de, 3
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, (VM_OUTPUT_ROW)
    cp   3
    jr   nz, .fail
    ret
.fail:
    scf
    ret

; ============================================================================
; TEST_CHECK_DECOMPILED — byte-for-byte against a real captured-then-
; verified rendering. "V0"=C, "V1"=I, "V2"=D, "V3"=J, "V4"=E, "V5"=K --
; compiler-generated names, first-use order.
;
; "IF (V5>3) THEN GOTO L82" (not a block "IF...THEN / GOTO / ENDIF"),
; plus a harmless unreferenced "L74:" label right after it -- a real,
; pre-existing decompiler ambiguity, not a new bug: this block IF's own
; THEN-body is exactly one JMP-producing statement (EXIT FOR itself)
; with no ELSE, which makes its bytecode shape (JMPZ, then a bare JMP
; whose own target equals JMPZ's target) byte-for-byte identical to the
; OLD single-line "IF...THEN GOTO" shape the decompiler already
; disambiguates by pattern, not full semantic tracking. Still valid,
; re-parseable, semantically identical V2 source -- the "L74:" label is
; simply never referenced by anything, which is ordinary legal syntax.
; Label numbers L74/L82 (previously L72/L80 pre-nested-FOR/NEXT) shifted
; by +2: OP_FOR_POP (opcode 55, 1 byte, no operand) is emitted once
; after each of this program's two closed single-level loops (NEXT V1,
; NEXT V3), each shifting every later bytecode offset by 1.
; ============================================================================
TEST_CHECK_DECOMPILED:
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
    db "V0 = 0", 13
    db "FOR V1 = 1 TO 10 STEP 2", 13
    db "V0 = (V0+V1)", 13
    db "NEXT V1", 13
    db "V2 = 0", 13
    db "FOR V3 = 10 TO 1 STEP (0-3)", 13
    db "V2 = (V2+V3)", 13
    db "NEXT V3", 13
    db "V4 = 0", 13
    db "FOR V5 = 1 TO 100 STEP 1", 13
    db "IF (V5>3) THEN GOTO L82", 13
    db "L74:", 13
    db "V4 = V5", 13
    db "NEXT V5", 13
    db "L82:", 13
    db "PRINT V0", 13
    db "PRINT V2", 13
    db "PRINT V4", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stubs: this file's own test program never exercises LPRINT/
; BEEP/SOUND/PAUSE/INPUT, and never registers or calls a loadable
; extension.
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
