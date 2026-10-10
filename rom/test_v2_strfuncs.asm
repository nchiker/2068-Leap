; ============================================================================
; rom/test_v2_strfuncs.asm — Architecture B, R8.5 Group 6 (string-result
; functions) smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's extended
; BUILTIN_FN_TABLE (CHR$/STR$/UPPER$/LOWER$/LEFT$/RIGHT$/INKEY$ rows,
; fn_index 13-19) and rom/exrom_v2_vm_core.asm's new BUILTIN_FN_CHR/STR/
; UPPER/LOWER/LEFT/RIGHT/INKEY handlers -- the first built-in functions
; whose RESULT is a string, not numeric. Also exercises: the per-
; position argtype-bitmask generalization, the compile-time name-
; collision disambiguation between COMPILE_FACTOR.ident/COMPILE_STR_
; FACTOR.ident, and DECOMP_STR_OPERAND's letter-prefix passthrough (a
; nested string-result call used as another string function's own
; argument). NOT wired into the production BASIC dispatch or the
; shipping EXROM build. Built on the shared production-shaped test
; harness (rom/test_v2_harness_home_head.inc/_tail.inc + rom/
; test_v2_harness_exrom.asm) -- see that harness's own header for why
; (post-semantic-milestone test-infrastructure fix, docs/v2/
; POST_R9_TEST_INFRASTRUCTURE.md).
;
; Source program compiled and executed:
;
;   A$ = "HELLO"                        -- source for LEFT$/RIGHT$ below
;   B$ = CHR$(65)
;   C$ = STR$(123)
;   D$ = LOWER$(UPPER$("mixedCase"))    -- nested string-result call
;   J = LEN(LEFT$(A$,3))
;   K = CODE(LEFT$(A$,3))
;   L = LEN(RIGHT$(A$,3))
;   M = CODE(RIGHT$(A$,3))
;   N = LEN(LEFT$(A$,100))              -- n > source length, clamps
;   O = LEN(RIGHT$(A$,0))               -- n=0, empty result
;   P = LEN(INKEY$())                  -- 0-arg builtin calls still
;                                          require "()"
;
; Only 4 named string variables (A$-D$) are used, matching STRTAB_MAX_
; VARS's own real 4-slot capacity exactly -- LEFT$/RIGHT$'s own results
; are deliberately verified via LEN()/CODE() on the call EXPRESSION
; directly (no named variable needed).
; ============================================================================

    DEFINE TEST_V2_NEEDS_DECOMPILE
    DEFINE TEST_V2_CHECK_DECOMPILED_TEXT
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

SOURCE_TEXT:
    db 'A$="HELLO":B$=CHR$(65):C$=STR$(123):'
    db 'D$=LOWER$(UPPER$("mixedCase")):'
    db 'J=LEN(LEFT$(A$,3)):K=CODE(LEFT$(A$,3)):'
    db 'L=LEN(RIGHT$(A$,3)):M=CODE(RIGHT$(A$,3)):'
    db 'N=LEN(LEFT$(A$,100)):O=LEN(RIGHT$(A$,0)):P=LEN(INKEY$())', 0

EXP_B: db 1, "A"
EXP_C: db 3, "123"
EXP_D: db 9, "mixedcase"

; ============================================================================
; TEST_CHECK_RESULT — String symbol declaration order (STRSYM_FIND_OR_
; CREATE, first appearance): 0=A$ 1=B$ 2=C$ 3=D$. Numeric (CSYM_FIND_OR_
; CREATE): 0=J 1=K 2=L 3=M 4=N 5=O 6=P.
; ============================================================================
TEST_CHECK_RESULT:
    TSTR_ADDR 1*32  ; B$ = CHR$(65) = "A"
    ld   de, EXP_B
    call CHECK_STR
    jp   c, .fail

    TSTR_ADDR 2*32  ; C$ = STR$(123) = "123"
    ld   de, EXP_C
    call CHECK_STR
    jp   c, .fail

    TSTR_ADDR 3*32  ; D$ = LOWER$(UPPER$("mixedCase"))
    ld   de, EXP_D
    call CHECK_STR
    jp   c, .fail

    call CHECK_NUM3                     ; J (idx 0): LEN(LEFT$(A$,3))=3
    db   0, 3
    jp   c, .fail

    call CHECK_NUM3                     ; K (idx 1): CODE(LEFT$(A$,3))
    db   1, 'H'                           ; = CODE("HEL") = 'H' = 72
    jp   c, .fail

    call CHECK_NUM3                     ; L (idx 2): LEN(RIGHT$(A$,3))=3
    db   2, 3
    jp   c, .fail

    call CHECK_NUM3                     ; M (idx 3): CODE(RIGHT$(A$,3))
    db   3, 'L'                           ; = CODE("LLO") = 'L' = 76
    jp   c, .fail

    call CHECK_NUM3                     ; N (idx 4): LEN(LEFT$(A$,100))
    db   4, 5                             ; clamped to source len = 5
    jp   c, .fail

    call CHECK_NUM3                     ; O (idx 5): LEN(RIGHT$(A$,0))=0
    db   5, 0
    jp   c, .fail

    call CHECK_NUM3                     ; P (idx 6): LEN(INKEY$) -- stub
    db   6, 0                             ; always "nothing pressed"
    jp   c, .fail
    ret
.fail:
    scf
    ret

; CHECK_STR -- input: HL = a real STRTAB record's own address, DE = an
; expected [len:1][content:len] block's own address. Out: carry set on
; any mismatch (length or content), clear on an exact match. Destroys:
; AF, BC, DE, HL.
CHECK_STR:
    ld   a, (de)
    cp   (hl)
    scf
    ret  nz
    ld   c, a
    or   a
    jr   z, .done
    inc   hl
    inc   de
.cmp:
    ld   a, (de)
    cp   (hl)
    scf
    ret  nz
    inc  hl
    inc  de
    dec  c
    jr   nz, .cmp
.done:
    or   a
    ret

; CHECK_NUM3 -- checks a numeric CSYM's real runtime value. Called with
; an inline [symtab_index:1][expected_low_byte:1] pair immediately
; following the `call` (read via the return address, then skipped over
; before returning). Out: carry set on any mismatch, clear on a match.
; Destroys: AF, BC, DE, HL.
CHECK_NUM3:
    pop  hl              ; HL = return address -> inline [index][expected]
    ld   a, (hl)
    inc  hl
    ld   c, (hl)
    inc  hl
    push hl                ; adjusted return address, past the inline pair
    ld   l, a
    ld   h, 0
    ld   d, h
    ld   e, l
    add  hl, hl              ; *2
    add  hl, de               ; *3
    ld   de, (RT_SYMTAB_PTR)
    inc  de
    add  hl, de
    ld   a, (hl)
    cp   c
    scf
    ret  nz
    inc  hl
    ld   a, (hl)
    or   a
    scf
    ret  nz
    or   a
    ret

; ============================================================================
; TEST_CHECK_DECOMPILED — byte-for-byte against a real captured-then-
; verified rendering. S0$/V0-V6 are the compiler's real generated names
; for A$/J-P. Every string literal argument decompiles unchanged; every
; variable reference (S0$) and numeric literal (3/100/0) shows the
; per-position argtype fix's own real correctness.
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
    db 'S0$ = "HELLO"',13
    db "S1$ = CHR$(65)",13
    db "S2$ = STR$(123)",13
    db 'S3$ = LOWER$(UPPER$("mixedCase"))',13
    db "V0 = LEN(LEFT$(S0$,3))",13
    db "V1 = CODE(LEFT$(S0$,3))",13
    db "V2 = LEN(RIGHT$(S0$,3))",13
    db "V3 = CODE(RIGHT$(S0$,3))",13
    db "V4 = LEN(LEFT$(S0$,100))",13
    db "V5 = LEN(RIGHT$(S0$,0))",13
    db "V6 = LEN(INKEY$())",13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

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
; SOUND/PAUSE/real INPUT/keyboard-blocking-wait, and never registers or
; calls a loadable extension.
SOUND_BEEP:
    ret
SOUND_EXROM:
    or a
    ret
IO_READ_KEY:
    xor a
    ret
; R8.5 Group 6 -- INKEY$ needs kernel/io/io.asm's real IO_READ_KEY_
; NONBLOCK; deterministic "no key currently pressed" stub.
IO_READ_KEY_NONBLOCK:
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

    INCLUDE "rom/test_v2_harness_home_tail.inc"
