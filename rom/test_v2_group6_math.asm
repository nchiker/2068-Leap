; ============================================================================
; rom/test_v2_group6_math.asm — Architecture B, R8.5 Group 6 (SGN/MOD/DIV/
; RND) smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's extended
; BUILTIN_FN_TABLE (SGN/MOD/DIV/RND rows added alongside the existing ABS)
; and rom/exrom_v2_vm_core.asm's new BUILTIN_FN_SGN/MOD/DIV/RND handlers --
; thin integer-only wrappers over real, unmodified kernel/math/math.asm
; primitives (MATH_SGN16/MATH_MOD16/MATH_DIVIDE16/MATH_RND16), matching
; V1's own documented "pure-integer BASIC" behavior for this function
; family exactly. NOT wired into the production BASIC dispatch or the
; shipping EXROM build. Built on the shared production-shaped test
; harness (rom/test_v2_harness_home_head.inc/_tail.inc + rom/
; test_v2_harness_exrom.asm) -- see that harness's own header for why
; (post-semantic-milestone test-infrastructure fix, docs/v2/
; POST_R9_TEST_INFRASTRUCTURE.md).
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
; PEEK(0) reads this very ROM image's own RST vector byte (DI = $F3 =
; 243). USR(4) calls USR_TEST_ROUTINE, placed at the fixed address $0004
; right after the harness's own "di:jp TEST_COLD_START" (4 bytes), which
; loads HL=4321 and returns -- the real CALL/USR convention (tail-jump
; via `jp (hl)`, reached through a `call` so the user routine's own RET
; returns control to the caller).
;
; L/M/N exercise the first built-ins whose argument is a STRING
; expression, not numeric -- L/M read back a real string VARIABLE, N
; reads back a string LITERAL directly.
;
; Verification: A-E, G-N are checked directly against their real, hand-
; computable expected values by reading their SYMTAB_BASE record. F
; (RND) is only range-checked (0 <= F <= 10) since its real value is
; nondeterministic by design.
;
; Symbol declaration order (CSYM_FIND_OR_CREATE, first appearance):
;   0=A 1=B 2=C 3=D 4=E 5=F 6=G 7=H 8=I 9=J 10=K 11=L 12=M 13=N.
;   String symbols (STRSYMTAB, separate namespace): 0=Z$.
; ============================================================================

    DEFINE TEST_V2_NEEDS_DECOMPILE
    DEFINE TEST_V2_CHECK_DECOMPILED_TEXT
    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

; Capture exactly where the harness head left off before jumping
; backward to patch in USR_TEST_ROUTINE, then resume from that exact
; saved address afterward -- NOT a hardcoded address. A first version
; of this hardcoded ORG $0100 instead, silently overlapping (and
; corrupting) the harness head's own TEST_CALC_ENTRY/TEST_COLD_START
; code that already lives there; caught via a real ZEsarUX run (SP
; underflowed to 3, PC ended up deep in kernel code -- consistent with
; a corrupted RST $28/RST $38 vector).
TEST_V2_RESUME_ADDR: equ $
    ORG $0004
USR_TEST_ROUTINE:              ; fixed address $0004 -- real CALL/USR
    ld   hl, 4321                ; convention: ends in its own RET,
    ret                           ; result left in HL
    ORG TEST_V2_RESUME_ADDR

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

    ; RC: VAL parses with the calculator (the shared number parser), and the harness's 8K EXROM
    ; holds either the calculator or the decompiler, not both. So this file is built twice: here
    ; (decompiler EXROM) it checks the decompiled text, and through rom/test_v2_group6_math_run.asm
    ; (TEST_V2_PHASE_RUN, calculator EXROM) it runs the program and checks every value. Every
    ; check below runs in one of the two images.
    IFDEF TEST_V2_PHASE_RUN
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
    jp   nz, TEST_FAIL

    ; A (index 0): SGN(-5) = -1
    TSYM_ADDR 0*3 + 1
    ld   a, (hl)
    cp   $FF
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    cp   $FF
    jp   nz, TEST_FAIL

    ; B (index 1): SGN(0) = 0
    TSYM_ADDR 1*3 + 1
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL

    ; C (index 2): SGN(5) = 1
    TSYM_ADDR 2*3 + 1
    ld   a, (hl)
    cp   1
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL

    ; D (index 3): MOD(17,5) = 2
    TSYM_ADDR 3*3 + 1
    ld   a, (hl)
    cp   2
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL

    ; E (index 4): DIV(17,5) = 3
    TSYM_ADDR 4*3 + 1
    ld   a, (hl)
    cp   3
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL

    ; F (index 5): RND(10) -- range check only: 0 <= F <= 10, high byte
    ; must be 0 (a value in this range never sets it).
    TSYM_ADDR 5*3 + 2
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL
    dec  hl
    ld   a, (hl)
    cp   11
    jp   nc, TEST_FAIL

    ; G (index 6): POINT(5,10) -- stub GFX_READ_PIXEL below returns
    ; (x+y)&1; 5+10=15, odd -> 1
    TSYM_ADDR 6*3 + 1
    ld   a, (hl)
    cp   1
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL

    ; H (index 7): ATTR(2,3) -- real memory read back from the seeded
    ; ATTR_TEST_BUF byte via the stub GFX_CELL_ATTR_ADDR below
    TSYM_ADDR 7*3 + 1
    ld   a, (hl)
    cp   42
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL

    ; I (index 8): INT(7) = 7 (an int argument passes through unchanged)
    TSYM_ADDR 8*3 + 1
    ld   a, (hl)
    cp   7
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL

    ; J (index 9): PEEK(0) -- this ROM's own RST vector byte (DI = $F3 = 243)
    TSYM_ADDR 9*3 + 1
    ld   a, (hl)
    cp   243
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL

    ; K (index 10): USR(4) -- USR_TEST_ROUTINE loads HL=4321 and RETs
    TSYM_ADDR 10*3 + 1
    ld   a, (hl)
    cp   (4321 & $FF)
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    cp   (4321 >> 8)
    jp   nz, TEST_FAIL

    ; L (index 11): LEN(Z$) where Z$="HI" -> 2
    TSYM_ADDR 11*3 + 1
    ld   a, (hl)
    cp   2
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL

    ; M (index 12): CODE(Z$) where Z$="HI" -> ASCII 'H' = 72
    TSYM_ADDR 12*3 + 1
    ld   a, (hl)
    cp   'H'
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL

    ; N (index 13): VAL("123") -> 123
    TSYM_ADDR 13*3 + 1
    ld   a, (hl)
    cp   123
    jp   nz, TEST_FAIL
    inc  hl
    ld   a, (hl)
    or   a
    jp   nz, TEST_FAIL
    ELSE

    call DECOMPILE_PROGRAM
    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    call TEST_CHECK_DECOMPILED
    jp   c, TEST_FAIL
    ENDIF

    jp   TEST_PASS

SOURCE_TEXT:
    db "A=SGN(-5):B=SGN(0):C=SGN(5):D=MOD(17,5):E=DIV(17,5):F=RND(10):"
    db "G=POINT(5,10):H=ATTR(2,3):I=INT(7):J=PEEK(0):K=USR(4):"
    db 'Z$="HI":L=LEN(Z$):M=CODE(Z$):N=VAL("123")', 0

; ============================================================================
; TEST_CHECK_DECOMPILED — byte-for-byte against a real captured-then-
; verified rendering. "((0-5))" is unary minus's own established "(0-X)"
; form wrapped in CALL_FN's own "NAME(<arg>)" form. V0-V13 are the
; compiler's real generated names for A-N.
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
    db "V0 = SGN(-5)",13       ; QUAL: -5 is folded at compile time (Q-05)
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
; symbol unconditionally.
BASIC_STMT_LPRINT_EXROM:
    ret

; Deterministic substitutes for BUILTIN_FN_POINT/ATTR's own two real
; GFX_* dependencies. GFX_READ_PIXEL: real contract is B=x/C=y -> A=0/1;
; this stub returns (x+y)&1, exercising the real contract shape without
; needing a real bitmap. GFX_CELL_ATTR_ADDR: real contract is B=row/
; C=col -> carry clear+HL=address or carry set if row>=24/col>=32; this
; stub keeps the identical row*32+col formula and bounds check, just
; against ATTR_TEST_BUF instead of real screen attribute memory.
GFX_READ_PIXEL:
    ld a,b
    add a,c
    and 1
    ret
ATTR_TEST_BUF: equ $9800   ; real RAM, well past VM_CODE_BASE ($A455) --
                            ; this test's own tiny compiled program never
                            ; reaches anywhere near here.
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
