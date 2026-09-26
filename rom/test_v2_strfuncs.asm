; ============================================================================
; rom/test_v2_strfuncs.asm — Architecture B, R8.5 Group 6 (string-result
; functions) smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's extended
; BUILTIN_FN_TABLE (CHR$/STR$/UPPER$/LOWER$/LEFT$/RIGHT$/INKEY$ rows,
; fn_index 13-19) and rom/exrom_v2_vm_core.asm's new BUILTIN_FN_CHR/STR/
; UPPER/LOWER/LEFT/RIGHT/INKEY handlers -- the first built-in functions
; whose RESULT is a string, not numeric. Also exercises: the per-
; position argtype-bitmask generalization (COMPILE_FACTOR.fn_call and
; .op_call_fn both moved off a single flat flag, needed by LEFT$/
; RIGHT$'s two differently-typed arguments), the compile-time name-
; collision disambiguation between COMPILE_FACTOR.ident/COMPILE_STR_
; FACTOR.ident (BFN_FOUND_ARGTYPE's new bit 7), and DECOMP_STR_OPERAND's
; new letter-prefix passthrough (a nested string-result call used as
; another string function's own argument).
;
; Source program compiled and executed:
;
;   A$ = "HELLO"                        -- source for LEFT$/RIGHT$ below
;   B$ = CHR$(65)
;   C$ = STR$(123)
;   D$ = LOWER$(UPPER$("mixedCase"))    -- nested string-result call,
;                                          exercises DECOMP_STR_OPERAND's
;                                          new letter-prefix passthrough
;   J = LEN(LEFT$(A$,3))
;   K = CODE(LEFT$(A$,3))
;   L = LEN(RIGHT$(A$,3))
;   M = CODE(RIGHT$(A$,3))
;   N = LEN(LEFT$(A$,100))              -- n > source length, clamps
;   O = LEN(RIGHT$(A$,0))               -- n=0, empty result
;   P = LEN(INKEY$())                  -- 0-arg builtin calls still
;                                          require "()" (COMPILE_FACTOR.
;                                          fn_call always expects an
;                                          opening paren after the name)
;
; Only 4 named string variables (A$-D$) are used, matching STRTAB_MAX_
; VARS's own real 4-slot capacity exactly -- LEFT$/RIGHT$'s own results
; are deliberately verified via LEN()/CODE() on the call EXPRESSION
; directly (no named variable needed, exercising the same TEMP-slot
; round-robin allocation OP_STR_CONCAT already relies on) rather than
; assigned to a 5th/6th/7th named string variable, which STRSYM_FIND_
; OR_CREATE would correctly reject (compile error 1, symbol table full)
; once STRSYMTAB_MAX_ENTRIES (also 4, matching STRTAB_MAX_VARS by
; design) is exceeded.
;
; INKEY$ reaches the deterministic stub IO_READ_KEY_NONBLOCK below
; (real keyboard-matrix injection is out of scope for a bounded free-
; run test, same reasoning every other v2 test's own I/O stubs give) --
; this test only proves the compile/dispatch/empty-string-result shape
; is correct, not real keyboard behavior (already covered live via
; kernel/io/io.asm's own IO_READ_KEY, reused unmodified here).
;
; Verification: every result is checked directly against real runtime
; STRTAB/SYMTAB records (real runtime execution, not just decompiled
; source text -- decompiled text only proves the right opcode/argument
; shape compiled, not that VM_STR_ALLOC_TEMP/VM_STR_ADDR/the copy loops
; actually computed the right bytes).
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_strfuncs.sym \
;       rom/test_v2_strfuncs.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_strfuncs_zesarux.bin
;   ts2068-debug run --max-instructions 500000
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

    ; String symbol declaration order (STRSYM_FIND_OR_CREATE, first
    ; appearance): 0=A$ 1=B$ 2=C$ 3=D$ (exactly STRTAB_MAX_VARS's own
    ; 4-slot capacity -- see this file's own header). Numeric (CSYM_
    ; FIND_OR_CREATE): 0=J 1=K 2=L 3=M 4=N 5=O 6=P.

    ld   hl, STRTAB_BASE + 1*32       ; B$ = CHR$(65) = "A"
    ld   de, EXP_B
    call CHECK_STR
    jp   c, FAIL

    ld   hl, STRTAB_BASE + 2*32       ; C$ = STR$(123) = "123"
    ld   de, EXP_C
    call CHECK_STR
    jp   c, FAIL

    ld   hl, STRTAB_BASE + 3*32       ; D$ = LOWER$(UPPER$("mixedCase"))
    ld   de, EXP_D                      ; -- nested string-result call
    call CHECK_STR
    jp   c, FAIL

    call CHECK_NUM3                     ; J (idx 0): LEN(LEFT$(A$,3))=3
    db   0, 3
    jp   c, FAIL

    call CHECK_NUM3                     ; K (idx 1): CODE(LEFT$(A$,3))
    db   1, 'H'                           ; = CODE("HEL") = 'H' = 72
    jp   c, FAIL

    call CHECK_NUM3                     ; L (idx 2): LEN(RIGHT$(A$,3))=3
    db   2, 3
    jp   c, FAIL

    call CHECK_NUM3                     ; M (idx 3): CODE(RIGHT$(A$,3))
    db   3, 'L'                           ; = CODE("LLO") = 'L' = 76
    jp   c, FAIL

    call CHECK_NUM3                     ; N (idx 4): LEN(LEFT$(A$,100))
    db   4, 5                             ; clamped to source len = 5
    jp   c, FAIL

    call CHECK_NUM3                     ; O (idx 5): LEN(RIGHT$(A$,0))=0
    db   5, 0
    jp   c, FAIL

    call CHECK_NUM3                     ; P (idx 6): LEN(INKEY$) -- stub
    db   6, 0                             ; always "nothing pressed"
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
; before returning -- a real 16-bit value is never needed here, every
; expected value in this test is small and non-negative, so only the
; low byte is compared; the high byte is still checked for ==0).
; Out: carry set on any mismatch, clear on a match.
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
    ld   de, SYMTAB_BASE+1
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

; Captured from a real ZEsarUX run of this exact test (same "capture,
; don't guess" discipline every other decompiler test in this session
; follows). S0$/V0-V6 are the compiler's real generated names for
; A$/J-P (identifiers are not preserved through compile). Every string
; literal argument decompiles unchanged; every variable reference
; (S0$) and numeric literal (3/100/0) shows the per-position argtype
; fix's own real correctness -- this exact test caught that fix's
; first, inverted version rendering "LEFT$(0,S3$)" instead.
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
; symbol unconditionally -- same stubbing discipline as every other v2
; test.
BASIC_STMT_LPRINT_EXROM:
    ret

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
; rom/exrom_calc.asm (1772 real lines) is NOT included here: this
; test's own program is pure integer/string work -- no PUSH_FLOAT_LIT,
; no float path is ever exercised.
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
CALC_PUSH_PI:
    ret
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test never touches real screen bitmap content.
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
; calls a loadable extension -- same stubbing discipline as every other
; R8.5 v2 test this session.
SOUND_BEEP:
    ret
SOUND_EXROM:
    or a
    ret
IO_READ_KEY:
    xor a
    ret
; R8.5 Group 6 -- INKEY$ needs kernel/io/io.asm's real IO_READ_KEY_
; NONBLOCK, not included in this flat test image (same scaling limit
; as every other v2 test); deterministic "no key currently pressed"
; stub, same pattern this test suite already uses for other platform
; dependencies (GFX_READ_PIXEL etc). MUST be placed here (after the
; real ORG $0000 code), not before it -- a real bug, found via a real
; ZEsarUX run: placed earlier (before DEVICE/ORG), sjasmplus assembled
; it at whatever address the assembler counter held BEFORE the ORG
; reset (address 0), silently aliasing RST_00's own real code at
; $0000. Every runtime call to INKEY$ then executed "CALL $0000",
; running RST_00's own "di:jp COLD_START" bytes and restarting the
; entire compiled program from scratch -- looked exactly like an
; infinite compile-time hang (COLD_START kept re-triggering) until
; traced via a real ZEsarUX breakpoint at $0000/$0100 and the stack's
; own return address resolving to BUILTIN_FN_INKEY's own "call
; IO_READ_KEY_NONBLOCK" site.
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
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_strfuncs.bin", $0000, $4000
