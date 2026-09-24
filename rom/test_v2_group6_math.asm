; ============================================================================
; rom/test_v2_group6_math.asm — Architecture B, R8.5 Group 6 (SGN/MOD/DIV/
; RND) smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's extended
; BUILTIN_FN_TABLE (SGN/MOD/DIV/RND rows added alongside the existing ABS)
; and rom/exrom_v2_vm_core.asm's new BUILTIN_FN_SGN/MOD/DIV/RND handlers --
; confirmed via this milestone's own reuse audit to be thin integer-only
; wrappers over real, unmodified kernel/math/math.asm primitives
; (MATH_SGN16/MATH_MOD16/MATH_DIVIDE16/MATH_RND16), matching V1's own
; documented "pure-integer BASIC" behavior for this function family
; exactly. NOT wired into the production BASIC dispatch or the shipping
; EXROM build. Reuses the SAME CALL_FN mechanism R8.5 Group 1 (ABS)
; established -- BUILTIN_FN_TABLE grows, BUILTIN_FN_FIND/COMPILE_FACTOR's
; own grammar do not change.
;
; Source program compiled and executed:
;
;   A = SGN(-5)
;   B = SGN(0)
;   C = SGN(5)
;   D = MOD(17,5)
;   E = DIV(17,5)
;   F = RND(10)
;   G = POINT(5,10)
;   H = ATTR(2,3)
;   I = INT(7)
;   J = PEEK(0)
;   K = USR(4)
;   Z$ = "HI"
;   L = LEN(Z$)
;   M = CODE(Z$)
;   N = VAL("123")
;
; PEEK(0) reads this very ROM image's own RST_00 byte (DI = $F3 = 243).
; USR(4) calls USR_TEST_ROUTINE, placed at the fixed address $0004
; right after RST_00's own "di:jp COLD_START" (4 bytes), which loads
; HL=4321 and returns -- the real CALL/USR convention basic.asm's own
; BASIC_CALL_USR documents (tail-jump via `jp (hl)`, reached through a
; `call` so the user routine's own RET returns control to the caller).
;
; L/M/N exercise the first built-ins whose argument is a STRING
; expression, not numeric (rom/exrom_v2_compiler.asm's own BUILTIN_FN_
; TABLE argtype column routes their argument through COMPILE_STR_EXPR
; instead of COMPILE_EXPR) -- L/M read back a real string VARIABLE
; (proving the decompiler's own DECOMP_STR_OPERAND reinterpretation
; fires correctly for a built-in function argument, not just PRINT/
; assignment), N reads back a string LITERAL directly.
;
; Verification: A-E, G-N are checked directly against their real, hand-
; computable expected values by reading their SYMTAB_BASE record (real
; runtime variable storage, not just decompiled source text -- this
; milestone's own math is worth checking for real, since decompiled text
; only proves the right opcode/argument-count compiled, not that the
; underlying kernel/math/math.asm/kernel/graphics/graphics.asm call
; actually computed the right answer). F (RND) is only range-checked
; (0 <= F <= 10) since its real value is nondeterministic by design --
; same bar rom/test_v2_call_fn.asm's own header already applies to
; unverifiable real hardware behavior.
;
; GFX_READ_PIXEL/GFX_CELL_ATTR_ADDR are stubbed below with small
; deterministic substitutes (real kernel/graphics/graphics.asm doesn't
; fit alongside the full v2 core in this flat 16K image, same scaling
; limit as every other v2 test) -- this test's real job is proving
; BUILTIN_FN_POINT/ATTR correctly marshal B/C into whatever GFX_*
; contract those real routines already have and correctly read back
; the result, not re-proving GFX_READ_PIXEL's own real pixel math
; (unmodified, out of scope here). The stub GFX_CELL_ATTR_ADDR keeps
; the real address-formula/bounds-check shape (row*32+col, carry set
; if out of range) against a private ATTR_TEST_BUF instead of the real
; ATTR_ADDR screen memory, pre-seeded with a known byte at (row=2,col=3)
; before VM_RUN so H's real value round-trips through a real memory
; read, not a hand-picked constant.
;
; Symbol declaration order (CSYM_FIND_OR_CREATE, first appearance):
;   0=A 1=B 2=C 3=D 4=E 5=F 6=G 7=H 8=I 9=J 10=K 11=L 12=M 13=N.
;   String symbols (STRSYMTAB, separate namespace): 0=Z$.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_group6_math.sym \
;       rom/test_v2_group6_math.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_group6_math_zesarux.bin
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
USR_TEST_ROUTINE:              ; fixed address $0004 -- real CALL/USR
    ld   hl, 4321                ; convention: ends in its own RET,
    ret                           ; result left in HL
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

    ; Seed ATTR_TEST_BUF at (row=2,col=3) with a known byte, exactly
    ; the address BUILTIN_FN_ATTR's real GFX_CELL_ATTR_ADDR call (via
    ; the stub below) will compute for ATTR(2,3) in SOURCE_TEXT.
    ld   a, 42
    ld   (ATTR_TEST_BUF + 2*32+3), a

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ; A (index 0): SGN(-5) = -1
    ld   hl, SYMTAB_BASE + 0*3 + 1
    ld   a, (hl)
    cp   $FF
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $FF
    jp   nz, FAIL

    ; B (index 1): SGN(0) = 0
    ld   hl, SYMTAB_BASE + 1*3 + 1
    ld   a, (hl)
    or   a
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, FAIL

    ; C (index 2): SGN(5) = 1
    ld   hl, SYMTAB_BASE + 2*3 + 1
    ld   a, (hl)
    cp   1
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, FAIL

    ; D (index 3): MOD(17,5) = 2
    ld   hl, SYMTAB_BASE + 3*3 + 1
    ld   a, (hl)
    cp   2
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, FAIL

    ; E (index 4): DIV(17,5) = 3
    ld   hl, SYMTAB_BASE + 4*3 + 1
    ld   a, (hl)
    cp   3
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, FAIL

    ; F (index 5): RND(10) -- range check only: 0 <= F <= 10, high byte
    ; must be 0 (a value in this range never sets it).
    ld   hl, SYMTAB_BASE + 5*3 + 2
    ld   a, (hl)
    or   a
    jp   nz, FAIL
    dec  hl
    ld   a, (hl)
    cp   11
    jp   nc, FAIL

    ; G (index 6): POINT(5,10) -- stub GFX_READ_PIXEL below returns
    ; (x+y)&1; 5+10=15, odd -> 1
    ld   hl, SYMTAB_BASE + 6*3 + 1
    ld   a, (hl)
    cp   1
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, FAIL

    ; H (index 7): ATTR(2,3) -- real memory read back from the seeded
    ; ATTR_TEST_BUF byte via the stub GFX_CELL_ATTR_ADDR below
    ld   hl, SYMTAB_BASE + 7*3 + 1
    ld   a, (hl)
    cp   42
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, FAIL

    ; I (index 8): INT(7) = 7 (true no-op)
    ld   hl, SYMTAB_BASE + 8*3 + 1
    ld   a, (hl)
    cp   7
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, FAIL

    ; J (index 9): PEEK(0) -- this ROM's own RST_00 byte (DI = $F3 = 243)
    ld   hl, SYMTAB_BASE + 9*3 + 1
    ld   a, (hl)
    cp   243
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, FAIL

    ; K (index 10): USR(4) -- USR_TEST_ROUTINE loads HL=4321 and RETs
    ld   hl, SYMTAB_BASE + 10*3 + 1
    ld   a, (hl)
    cp   (4321 & $FF)
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   (4321 >> 8)
    jp   nz, FAIL

    ; L (index 11): LEN(Z$) where Z$="HI" -> 2
    ld   hl, SYMTAB_BASE + 11*3 + 1
    ld   a, (hl)
    cp   2
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, FAIL

    ; M (index 12): CODE(Z$) where Z$="HI" -> ASCII 'H' = 72
    ld   hl, SYMTAB_BASE + 12*3 + 1
    ld   a, (hl)
    cp   'H'
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, FAIL

    ; N (index 13): VAL("123") -> 123
    ld   hl, SYMTAB_BASE + 13*3 + 1
    ld   a, (hl)
    cp   123
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    or   a
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
    db "A=SGN(-5):B=SGN(0):C=SGN(5):D=MOD(17,5):E=DIV(17,5):F=RND(10):"
    db "G=POINT(5,10):H=ATTR(2,3):I=INT(7):J=PEEK(0):K=USR(4):"
    db 'Z$="HI":L=LEN(Z$):M=CODE(Z$):N=VAL("123")', 0

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

; Captured from a real ZEsarUX run of this exact test. "((0-5))" is
; unary minus's own established "(0-X)" form (no dedicated unary-minus
; opcode) wrapped in CALL_FN's own "NAME(<arg>)" form, same as ABS's
; own test. V0-V5 are the compiler's real generated names for A-F
; (identifiers are not preserved through compile).
EXPECTED_TEXT:
    db "V0 = SGN((0-5))",13
    db "V1 = SGN(0)",13
    db "V2 = SGN(5)",13
    db "V3 = MOD(17,5)",13
    db "V4 = DIV(17,5)",13
    db "V5 = RND(10)",13
    db "V6 = POINT(5,10)",13
    db "V7 = ATTR(2,3)",13
    db "V8 = INT(7)",13
    db "V9 = PEEK(0)",13
    db "V10 = USR(4)",13
    db 'S0$ = "HI"',13
    db "V11 = LEN(S0$)",13
    db "V12 = CODE(S0$)",13
    db 'V13 = VAL("123")',13
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
; rom/exrom_calc.asm (1772 real lines) is NOT included here: this test's
; own program is pure integer arithmetic -- no float path is ever
; exercised (SGN/MOD/DIV/RND are deliberately integer-only, matching
; V1's own "pure-integer BASIC" comment for this function family).
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
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
; Deterministic substitutes for BUILTIN_FN_POINT/ATTR's own two real
; GFX_* dependencies (real kernel/graphics/graphics.asm doesn't fit
; here -- see this file's own header). GFX_READ_PIXEL: real contract is
; B=x/C=y -> A=0/1; this stub returns (x+y)&1, exercising the real
; contract shape without needing a real bitmap. GFX_CELL_ATTR_ADDR:
; real contract is B=row/C=col -> carry clear+HL=address or carry set
; if row>=24/col>=32; this stub keeps the identical row*32+col formula
; and bounds check, just against ATTR_TEST_BUF instead of real screen
; attribute memory.
GFX_READ_PIXEL:
    ld a,b
    add a,c
    and 1
    ret
ATTR_TEST_BUF: equ $9800   ; real RAM, well past VM_CODE_BASE ($9000) --
                            ; this test's own tiny compiled program never
                            ; reaches anywhere near here. NOT placed
                            ; inline in this ROM image's own code stream:
                            ; addresses 0-16383 are real, write-
                            ; protected ROM on this hardware/emulator
                            ; (the exact bug class rom/test_v2_input.asm's
                            ; own TEST_KEY_PTR fix already documents).
GFX_CELL_ATTR_ADDR:
    ld a,b
    cp 24
    jr nc,.oor
    ld a,c
    cp 32
    jr nc,.oor
    ld h,0
    ld l,b
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,ATTR_TEST_BUF
    add hl,de
    ld d,0
    ld e,c
    add hl,de
    or a
    ret
.oor:
    scf
    ret
; Test-only stubs: this file's own test program never exercises BEEP/
; SOUND/PAUSE/INPUT, and never registers or calls a loadable extension --
; same stubbing discipline as every other R8.5 v2 test this session.
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
; kernel/memory/memory.asm is NOT included here -- checked directly:
; neither rom/exrom_v2_vm_core.asm/compiler.asm/decompiler.asm reference
; any MEM_*/PROG_END/PROG_AREA_START/ARRAYS_END/VARS_START symbol, and
; this test never touches the real editor engine.
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_group6_math.bin", $0000, $4000
