; ============================================================================
; rom/exrom_calc.asm — calculator engine (RST $28), EXROM-resident
;
; A small stack calculator over 5-byte floating-point values (CALC_STACK, 8
; slots, CALC_SP = depth). RST $28 is followed in the caller's code by a
; stream of one-byte operation codes ("literals") ending in $38; the engine
; runs each in turn and resumes the caller after the $38.
;
; Provenance: the dispatcher (CALC_EXROM_ENTRY / CALC_RE_ENTRY), the table
; format and EXCHANGE were rewritten on 2026-10-26
; (docs/V2_LEAPC_BACKPORT_PLAN.md item 3.2), replacing code whose earlier
; header recorded it as derived from the Spectrum ROM's CALCULATE and
; EXCHANGE. What is kept is the interface only: the literal values and the
; 5-byte number format, so a literal stream means the same as it would to
; the stock calculator ($01 exchange, $02 delete, $03 subtract, $04 multiply,
; $05 divide, $0F add, $31 duplicate, $38 end-calc). The arithmetic (add,
; subtract, multiply, divide) is 2068-Leap-C's float core (MIT, NOTICE.md;
; R1, see its section below); the rest is this project's own.
;
; Dispatch: CALC_TABLE lists each implemented literal with the number of
; stack operands it takes (0, 1 or 2) and its handler. The dispatcher finds
; the literal, refuses it if CALC_SP is below its operand count, points
; CALC_OP1_PTR (and CALC_OP2_PTR for two operands: OP1 the lower slot, OP2
; the top) at the operands, loads B from CALC_BREG and jumps to the handler,
; which ends with `jp CALC_RE_ENTRY` (END-CALC instead leaves). No primed
; registers, no EX (SP),HL: the stream position lives in CALC_LITERAL_PTR,
; and the operand pointers are recomputed from CALC_SP for every literal
; (tools/z80sim, which runs this file in test_calc_dispatcher.py, implements
; neither EXX nor EX (SP),HL).
;
; Errors: an unknown literal, too few operands, a full stack, division by
; zero and overflow all take one recoverable path (CALC_ABORT_STREAM): the
; code goes to CALC_ERROR_CODE, the stack is emptied, the stream is skipped
; to its $38 and the caller resumes normally. CALC_ERR_INVALID_LITERAL is no
; longer produced (every unknown literal is CALC_ERR_UNIMPLEMENTED), and an
; unknown literal is reported as such before any operand-count check.
;
; VALIDATION STATUS: assembled by sjasmplus as part of the production
; HOME/EXROM build and exercised by tools/z80sim/test_calc_dispatcher.py,
; the dedicated calculator smoke ROMs, and the integrated BASIC suite.
; See docs/v1/calculator_review.md for the current coverage and the explicit
; robustness limits that remain before this can be treated as a general-
; purpose replacement for the original ROM calculator.
;
; ENTRY CONTRACT (CALC_EXROM_ENTRY, reached via the $C024 stub — rom/
; exrom_checker.asm): stack top = pointer to the literal-op byte stream
; (RST $28's own return address, untouched by both Home-side trampolines
; — see basic/basic.asm's CALC_ENTRY_TRAMPOLINE/CALC_EXIT_TRAMPOLINE
; headers). B = a parameter for the ops that take one, kept in CALC_BREG
; and reloaded into B for every handler (0 for an ordinary call).
; ============================================================================

CALC_EXROM_ENTRY:
    xor  a
    ld   (CALC_ERROR_CODE), a
    ld   a, b
    ld   (CALC_BREG), a
    pop  hl                         ; the literal stream (the real stack is one
    ld   (CALC_LITERAL_PTR), hl     ; item shorter until END-CALC pushes the resume)

; CALC_RE_ENTRY — run the next literal. Every handler but END-CALC returns here.
CALC_RE_ENTRY:
    ld   hl, (CALC_LITERAL_PTR)
    ld   c, (hl)                    ; C = the literal
    inc  hl
    ld   (CALC_LITERAL_PTR), hl     ; past it: END-CALC's resume address
    ld   hl, CALC_TABLE
.find:
    ld   a, (hl)
    cp   c
    jr   z, .found
    inc  a                          ; $FF ends the table
    jr   z, .unknown
    inc  hl
    inc  hl
    inc  hl
    inc  hl
    jr   .find
.found:
    inc  hl
    ld   b, (hl)                    ; B = the operands it takes
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                    ; DE = the handler
    ld   a, (CALC_SP)
    cp   b
    jr   c, CALC_ABORT_STACK_UNDERFLOW
    push de
    ld   a, b
    or   a
    jr   z, .go                     ; none (END-CALC)
    push af
    call CALC_SP_TO_TOP_PTR         ; HL = CALC_OP1_PTR = the top slot
    pop  af
    dec  a
    jr   z, .go                     ; one: the top
    ld   (CALC_OP2_PTR), hl         ; two: the top is the second operand,
    ld   bc, -5
    add  hl, bc
    ld   (CALC_OP1_PTR), hl         ;   the slot below it the first
.go:
    pop  hl
    ld   a, (CALC_BREG)
    ld   b, a
    jp   (hl)
.unknown:
    ld   a, CALC_ERR_UNIMPLEMENTED
    jr   CALC_ABORT_STREAM

; Recoverable literal-stream failures. Every valid calculator program ends
; in literal $38. Skip the remainder, restore the RST caller's continuation,
; and leave through the normal paging-safe exit. A malformed stream with no
; terminator still cannot be recovered because the bytecode carries no length.
CALC_ABORT_STACK_UNDERFLOW:
    ld   a, CALC_ERR_STACK_UNDERFLOW
    jr   CALC_ABORT_STREAM
CALC_ABORT_NUMERIC_OVERFLOW:
    ld   a, CALC_ERR_NUMERIC_OVERFLOW
CALC_ABORT_STREAM:
    ld   (CALC_ERROR_CODE), a
    xor  a
    ld   (CALC_SP), a
    ld   hl, (CALC_LITERAL_PTR)
.find_end:
    ld   a, (hl)
    inc  hl
    cp   $38
    jr   nz, .find_end
    push hl
    jp   KTAB_CALC_EXIT_TRAMPOLINE

; ----------------------------------------------------------------------
; CALC_SP_TO_TOP_PTR — shared arithmetic: computes CALC_STACK +
; (CALC_SP-1)*5 (the top-of-stack slot) into HL, and stores it into
; CALC_OP1_PTR (correct as-is for the unary caller above; the binary
; caller above immediately relocates it to CALC_OP2_PTR instead, since
; for a binary op the top is the SECOND operand, not the first — see
; that routine's own comment). Destroys: AF, BC, DE, HL
; ----------------------------------------------------------------------
CALC_SP_TO_TOP_PTR:
    ld   a, (CALC_SP)
    dec  a                       ; A = CALC_SP-1 (index of top slot)
    ld   c, a
    ld   b, 0
    ld   hl, 0
    add  hl, bc
    add  hl, hl                  ; HL = index*2
    add  hl, hl                  ; HL = index*4
    add  hl, bc                  ; HL = index*5
    ld   de, CALC_STACK
    add  hl, de
    ld   (CALC_OP1_PTR), hl
    ret

; ----------------------------------------------------------------------
; CALC_SP_TO_NEXT_FREE_PTR — CALC_STACK + CALC_SP*5 (one past the
; current top — where a new push, e.g. duplicate, lands). Returns in
; DE (not HL) since callers typically already hold a source address in
; HL and need DE free for LDIR's destination. Destroys: AF, BC, DE, HL
; ----------------------------------------------------------------------
CALC_SP_TO_NEXT_FREE_PTR:
    ld   a, (CALC_SP)
    ld   c, a
    ld   b, 0
    ld   hl, 0
    add  hl, bc
    add  hl, hl
    add  hl, hl
    add  hl, bc
    ld   de, CALC_STACK
    add  hl, de
    ex   de, hl
    ret

; ============================================================================
; CALC_OP_END_CALC (literal $38 — matches the
; real ROM's own numbering exactly: "The last literal in the list is
; always +38 which leads to an end to the whole operation" — 335B.html)
;
; CALC_LITERAL_PTR already holds the correct resume address at this
; point (advanced past the $38 literal itself by CALC_RE_ENTRY before
; dispatch, same as every other literal) — no separate "true return"
; tracking needed at all in this reworked version, unlike the real
; ROM's own placeholder-stack-slot dance (see file header).
;
; STILL can't page out from here directly — this file is EXROM-
; resident, and paging Home back in changes what's AT this very address
; range if the next fetch is still $C000-$DFFF (see basic/basic.asm's
; Tail-jumps to CALC_EXIT_TRAMPOLINE (Home-resident) via KTAB_CALC_
; EXIT_TRAMPOLINE (include/exrom_jumptable.inc) — not a direct label
; reference, since this file and basic.asm are separate compilation
; units (see this op's own code below for the full reasoning).
; In:  CALC_LITERAL_PTR = the true resume address
; Out: none (tail-jumps toward the true original caller)
; Destroys: AF, HL
; ============================================================================
CALC_OP_END_CALC:
    ld   hl, (CALC_LITERAL_PTR)
    push hl
    jp   KTAB_CALC_EXIT_TRAMPOLINE ; NOT a direct `jp CALC_EXIT_
                                   ; TRAMPOLINE` — this file is a
                                   ; separate compilation unit from
                                   ; basic.asm (assembled via rom/
                                   ; exrom_build.asm, not rom/
                                   ; test_basic.asm), so that label
                                   ; genuinely doesn't exist here.
                                   ; Routed through the KTAB_* jump
                                   ; table (include/exrom_jumptable.
                                   ; inc) instead, same as every other
                                   ; EXROM->Home call in this project —
                                   ; caught by a real sjasmplus "Label
                                   ; not found" error this sandbox
                                   ; can't reproduce; direct-reference
                                   ; version never should have shipped

; ============================================================================
; CALC_OP_EXCHANGE (literal $01): swap the top two 5-byte slots.
; In:  CALC_OP1_PTR = the lower slot, CALC_OP2_PTR = the top (the dispatcher)
; Out: the two slots' contents swapped; CALC_SP unchanged
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_OP_EXCHANGE:
    ld   hl, (CALC_OP1_PTR)
    ld   de, (CALC_OP2_PTR)
    ld   b, 5
.swap:
    ld   c, (hl)
    ld   a, (de)
    ld   (hl), a
    ld   a, c
    ld   (de), a
    inc  hl
    inc  de
    djnz .swap
    jp   CALC_RE_ENTRY

; ============================================================================
; CALC_OP_DELETE (literal $02 — confirmed against
; 335B.html: "delete... contains only the single RET instruction... the
; first number [is] considered as the resulting 'last value' and the
; second number considered as being deleted.")
;
; Real ROM needs no data movement at all — the first operand's slot IS
; already where the shrunk stack's new top belongs. Same is true here,
; for the same reason: CALC_OP1_PTR = CALC_STACK+(CALC_SP-2)*5, which
; equals CALC_STACK+(new_CALC_SP-1)*5 the instant CALC_SP decrements —
; the exact address the dispatcher would compute as "top" on the
; very next dispatch. The only thing our fixed-CALC_SP design needs
; that the real ROM's raw-pointer model didn't: explicitly decrementing
; the depth counter, since nothing else tracks it implicitly here.
;
; In:  CALC_SP >= 2 (a caller invoking a binary op on a shorter stack is
;      a bug this doesn't defend against, same as the real ROM doesn't)
; Out: CALC_SP decremented by 1; no data moved
; Destroys: AF
; ============================================================================
CALC_OP_DELETE:
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY

; ============================================================================
; CALC_OP_DUPLICATE (literal $31 — confirmed
; against skoolkid.github.io/rom/asm/33C0.html, "THE 'MOVE A FLOATING-
; POINT NUMBER' SUBROUTINE (offset +31)": "duplicates the number at the
; top of the calculator stack... thereby extending the stack by five
; bytes." Real body: `CALL TEST_5_SP` (bounds check against free RAM)
; then `LDIR` (5 bytes, HL->DE) then `RET`.
;
; Ours needs a DIFFERENT bounds check — the real ROM's stack grows into
; free RAM and only fails on genuine memory exhaustion; this project's
; CALC_STACK is a fixed 8 slots (see that sysvar's own comment), so an
; 8-deep RPN expression alone can hit the cap, a normal-ish case worth
; its own clear diagnostic (CALC_STACK_OVERFLOW_FLAG) rather than
; silently writing past the array's end.
;
; Literal $31 is >=$18 (unary/manipulatory path, not binary) — matches
; the real ROM's own literal-numbering split — so CALC_OP2_PTR is NOT
; set by dispatch for this op; the destination (next free slot) is
; this routine's own responsibility, same as the real ROM's own DE
; input has to come from somewhere the generic dispatch doesn't provide
; for every manipulatory op (not all of them grow the stack).
;
; In:  CALC_OP1_PTR = top (source) — set by the dispatcher
; Out: CALC_SP incremented by 1; the new top slot is a copy of the old
;      one. Overflow records CALC_ERR_STACK_OVERFLOW and returns through
;      the stream's normal END-CALC/paging exit.
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_OP_DUPLICATE:
    ld   a, (CALC_SP)
    cp   8
    jr   nc, .overflow
    ld   hl, (CALC_OP1_PTR)      ; source = top
    push hl
    call CALC_SP_TO_NEXT_FREE_PTR ; DE = destination = next free slot
    pop  hl
    ld   bc, 5
    ldir
    ld   a, (CALC_SP)
    inc  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY
.overflow:
    ld   (CALC_STACK_OVERFLOW_FLAG), a
    ld   a, CALC_ERR_STACK_OVERFLOW
    jp   CALC_ABORT_STREAM

; ============================================================================
; CALC_INT_TO_FP — boundary converter, NOT a CALC_TABLE literal (the
; real ROM's analog, STACK-A, isn't one either — see project /areas
; notes). Pushes a 16-bit signed int onto CALC_STACK as the small-int
; fast form (always valid for a 16-bit source — no mantissa math
; needed at all).
; In:  HL = signed 16-bit int
; Out: CALC_SP incremented by 1, carry clear. On overflow, stack is
;      unchanged, CALC_ERR_STACK_OVERFLOW is recorded, and carry is set.
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_INT_TO_FP:
    push hl
    ld   a, (CALC_SP)
    cp   8
    jr   nc, .cif_overflow
    call CALC_SP_TO_NEXT_FREE_PTR
    pop  hl
    xor  a
    ld   (de), a
    inc  de
    ld   a, h
    or   a
    jp   p, .cif_pos
    ld   a, $FF
    jr   .cif_sign_done
.cif_pos:
    xor  a
.cif_sign_done:
    ld   (de), a
    inc  de
    ld   a, l
    ld   (de), a
    inc  de
    ld   a, h
    ld   (de), a
    inc  de
    xor  a
    ld   (de), a
    ld   a, (CALC_SP)
    inc  a
    ld   (CALC_SP), a
    or   a
    ret
.cif_overflow:
    pop  hl
    ld   a, (CALC_SP)
    ld   (CALC_STACK_OVERFLOW_FLAG), a
    ld   a, CALC_ERR_STACK_OVERFLOW
    ld   (CALC_ERROR_CODE), a
    scf
    ret
; ============================================================================
; CALC_FP_TO_INT — boundary converter (real ROM's STK-TO-A/STK-TO-BC
; analog), pops the top of CALC_STACK and converts to a signed 16-bit
; int. Handles both the small-int fast form (always exact, no range
; check needed) and the general form (truncate-toward-zero, matching
; the real "truncate" literal $3A's semantics, plus an explicit 16-bit
; range check). The general form is unpacked into FX by FUNPK (R1: the
; float core's layout below); the integer part of a value 1 <= |x| <
; 65536 is the mantissa's top 16 bits shifted right by 16 - (e - 128).
; Out: HL = converted int. Overflow saturates to $7FFF/$8000, sets carry,
;      CALC_TRUNC_FLAG, and CALC_ERR_NUMERIC_OVERFLOW. Exact results clear
;      carry and CALC_TRUNC_FLAG.
;      CALC_SP decremented by 1.
; In:  CALC_SP > 0 (caller bug otherwise, same as every other op here)
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_FP_TO_INT:
    ld   a, (CALC_SP)
    or   a
    jp   z, .fpi_underflow
    dec  a
    ld   (CALC_SP), a
    call CALC_SP_TO_NEXT_FREE_PTR
    ex   de, hl
    ld   a, (hl)
    or   a
    jr   nz, .fpi_general
    inc  hl
    ld   a, (hl)
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    xor  a
    ld   (CALC_TRUNC_FLAG), a
    or   a
    ret
.fpi_general:
    ld   de, FX
    call FUNPK                        ; FX = the sign ($80/0), exponent, mantissa
    ld   a, (FX + U_E)
    sub  128
    jr   z, .fpi_result_zero
    jp   m, .fpi_result_zero
    cp   17
    jr   nc, .fpi_saturate            ; unbiased exponent >= 17 ->
                                      ; magnitude always >= 65536,
                                      ; never a valid 16-bit int
    ld   b, a
    ld   a, 16
    sub  b
    ld   b, a                         ; shift amount, 0..15
    ld   hl, (FX + U_M)
    ld   a, l
    ld   l, h
    ld   h, a                         ; HL = m0 m1, the top 16 bits
    ld   a, b
    or   a
    jr   z, .fpi_shift_done
.fpi_shift_loop:
    srl  h
    rr   l
    djnz .fpi_shift_loop
.fpi_shift_done:
    ld   a, (FX + U_S)
    or   a
    jr   z, .fpi_check
    xor  a
    sub  l
    ld   l, a
    ld   a, 0
    sbc  a, h
    ld   h, a
.fpi_check:
    ld   a, (FX + U_S)
    ld   c, a
    ld   a, h
    and  $80
    cp   c
    jr   nz, .fpi_saturate
    xor  a
    ld   (CALC_TRUNC_FLAG), a
    or   a
    ret
.fpi_saturate:
    ld   hl, $7FFF
    ld   a, (FX + U_S)
    or   a
    jr   z, .fpi_mark_overflow
    ld   hl, $8000
.fpi_mark_overflow:
    ld   a, 1
    ld   (CALC_TRUNC_FLAG), a
    ld   a, CALC_ERR_NUMERIC_OVERFLOW
    ld   (CALC_ERROR_CODE), a
    scf
    ret
.fpi_result_zero:
    ld   hl, 0
    xor  a
    ld   (CALC_TRUNC_FLAG), a
    or   a
    ret
.fpi_underflow:
    ld   hl, 0
    ld   a, 1
    ld   (CALC_TRUNC_FLAG), a
    ld   a, CALC_ERR_STACK_UNDERFLOW
    ld   (CALC_ERROR_CODE), a
    scf
    ret

; ============================================================================
; CALC_PUSH_FP_RAW — boundary converter, same family as CALC_INT_TO_FP/
; CALC_FP_TO_INT above (not a CALC_TABLE literal — nothing in the
; literal stream needs "push an arbitrary constant", every literal
; program built so far only ever pushes plain ints via CALC_INT_TO_FP).
; Added 2026-08-22 for SIN: the degrees->radians conversion needs pi
; itself on the stack, and pi isn't a 16-bit int CALC_INT_TO_FP could
; produce. Copies an already-packed 5-byte float verbatim onto
; CALC_STACK's next free slot — no packing/unpacking at all, since the
; source bytes are already in exactly the on-stack format (same
; overflow-check shape as CALC_INT_TO_FP's own).
; In:  HL = pointer to a 5-byte packed float (ROM or RAM — ordinary
;      data, unaffected by EXROM paging either way)
; Out: CALC_SP incremented by 1
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_PUSH_FP_RAW:
    ld   a, (CALC_SP)
    cp   8
    jr   nc, .overflow
    push hl
    call CALC_SP_TO_NEXT_FREE_PTR   ; DE = dest (next free slot)
    pop  hl
    ld   bc, 5
    ldir
    ld   a, (CALC_SP)
    inc  a
    ld   (CALC_SP), a
    or   a
    ret
.overflow:
    ld   a, (CALC_SP)
    ld   (CALC_STACK_OVERFLOW_FLAG), a
    ld   a, CALC_ERR_STACK_OVERFLOW
    ld   (CALC_ERROR_CODE), a
    scf
    ret

; ============================================================================
; CALC_PUSH_PI — pushes the constant pi (packed float, PI_CONST below)
; via CALC_PUSH_FP_RAW. Its own fixed entry stub (rom/exrom_checker.
; asm) is what basic.asm's CALC_PUSH_PI_HOME actually calls — this
; label itself is EXROM-internal only, same reasoning as every other
; op in this file (see CALC_OP_END_CALC's own header on why EXROM
; can't be called by direct label reference from Home).
; In/Out/Destroys: same as CALC_PUSH_FP_RAW.
; ============================================================================
CALC_PUSH_PI:
    ld   hl, PI_CONST
    jr   CALC_PUSH_FP_RAW

; pi = 3.14159265..., encoded by hand via this project's own documented
; pack algorithm (docs/v1/programmers_reference.md's calculator section)
; and cross-checked in Python before trusting it here: byte0=$82 ->
; unbiased exponent 2 (value = mantissa * 4, mantissa in [0.5,1)); the
; decoded round-trip value differs from math.pi by ~4e-9, negligible
; against the 4-decimal-digit display BASIC_FLOAT_TO_STRING produces.
; These exact bytes also match the real Sinclair ROM's own well-known
; PI constant, a happy confirmation (not a requirement) that the
; encoding is right.
PI_CONST: DB $82, $49, $0F, $DA, $A2
; ============================================================================
; The arithmetic: add, subtract, multiply, divide (literals $0F, $03, $04, $05)
;
; R1 (docs/V2_LEAPC_BACKPORT_PLAN.md, defect Q-34): 2068-Leap-C's float core
; (its src/runtime/fpcore.asm, MIT; NOTICE.md) behind this calculator's
; interface. Its FUNPK, FPACK, FNORM, FADD, FSWAP, FMUL, FDIV, FDONE, FSIGN and
; byte helpers, as Leap-C has them but for the entry and exit and three loops
; made faster with the same results (marked "R1, speed": FADD aligns in
; registers, FMUL takes the multiplier's bits from A, FDIV compares before it
; subtracts and builds the quotient a byte at a time): the numbers are unpacked
; to a 40-bit mantissa (32 bits and a guard byte), worked on with byte loops,
; and rounded to nearest (ties away from zero) on the guard's top bit when
; packed. Leap-C's tools/fpmodel.py is a bit-exact model of every operation
; (tools/qual/qcalcround.py --leapc). The arithmetic it replaces truncated
; (INT(3.1*10) was 30).
;
; Adapted to this calculator: the operands are the two stack slots the
; dispatcher points at (CALC_OP1_PTR the first, CALC_OP2_PTR the second);
; either may be in the small-integer form (CALC_INT_TO_FP's: [0][sign $00/$FF]
; [16 bits, low byte first][0], 0 whatever its sign byte when the 16 bits are
; 0), which FUNPK normalises; the result goes to the first slot in the general
; form (0 as five zero bytes) and CALC_SP drops by one; the errors take this
; calculator's recoverable paths (CALC_ABORT_NUMERIC_OVERFLOW,
; CALC_ERR_DIVISION_BY_ZERO through CALC_ABORT_STREAM). Underflow gives 0.
; ============================================================================
FX      EQU CALC_FX                 ; unpacked: [sign $80/0][exponent][m0 m1 m2 m3][guard]
FY      EQU CALC_FY
FQ      EQU CALC_FQ                 ; 5 bytes: a product or quotient being built, big-endian
U_S     EQU 0
U_E     EQU 1
U_M     EQU 2                       ; m0 (the most significant) .. m3
U_G     EQU 6                       ; the guard byte

; CALC_OP_ADD / SUB / MUL / DIV: the first (lower) slot = first + - * / second
; (top). In: CALC_OP1_PTR, CALC_OP2_PTR. Out: CALC_SP - 1. Destroys: AF, BC, DE, HL
CALC_OP_ADD:
    ld   hl, FADD
    jr   CALC_ARITH
CALC_OP_SUB:
    ld   hl, FSUB
    jr   CALC_ARITH
CALC_OP_MUL:
    ld   hl, FMUL
    jr   CALC_ARITH
CALC_OP_DIV:
    ld   hl, FDIV
CALC_ARITH:                         ; HL = the operation (FX op= FY)
    ld   de, CALC_ARITH_END
    push de
    push hl
    ld   hl, (CALC_OP2_PTR)
    ld   de, FY
    call FUNPK
    ld   hl, (CALC_OP1_PTR)
    ld   de, FX
    jp   FUNPK                      ; returns into the operation, it to CALC_ARITH_END

; CALC_ARITH_END (Leap-C's FPACK): the first slot = FX, rounded to nearest on
; the guard's top bit. Errors: the rounding carries the exponent beyond 255.
CALC_ARITH_END:
    ld   hl, FX + U_G
    bit  7, (hl)
    jr   z, .pack
    ld   b, 4
.rnd:
    dec  hl
    inc  (hl)
    jr   nz, .pack
    djnz .rnd
    ld   (hl), $80                  ; 0.111...1 + 1 ulp = 1.000: the mantissa $80000000, e + 1
    dec  hl
    inc  (hl)
    jp   z, CALC_ABORT_NUMERIC_OVERFLOW
.pack:
    ld   hl, FX + U_E
    ld   de, (CALC_OP1_PTR)
    push de
    ld   bc, 5
    ldir                            ; e, m0 .. m3
    pop  hl
    inc  hl
    ld   a, (hl)
    and  $7F
    ld   b, a
    ld   a, (FX + U_S)
    or   b
    ld   (hl), a                    ; the sign in m0's top bit (a 0 in FX is all zero bytes)
    ld   hl, CALC_SP
    dec  (hl)
    jp   CALC_RE_ENTRY

; ============================================================================
; FUNPK -- unpack the 5-byte number at HL into the 7 bytes at DE; the small-
; integer form too (its 16 bits normalised; 0 as seven zero bytes)
; Destroys: AF, BC, DE, HL
; ============================================================================
FUNPK:
    ld   a, (hl)
    or   a
    jr   z, .small
    push de
    inc  de
    ld   bc, 5
    ldir                            ; [e][sign | m0][m1][m2][m3]
    xor  a
    ld   (de), a                    ; the guard
    pop  hl
    inc  hl
    inc  hl
    ld   a, (hl)
    set  7, (hl)                    ; m0's leading 1
    and  $80
    dec  hl
    dec  hl
    ld   (hl), a                    ; the sign
    ret
.small:                             ; [0][sign $00/$FF][low][high][0]
    inc  hl
    ld   a, (hl)
    inc  hl
    ld   c, (hl)
    inc  hl
    ld   b, (hl)                    ; BC = the 16 bits
    ex   de, hl                     ; HL -> the unpacked sign
    and  $80
    ld   (hl), a
    jr   z, .pos
    xor  a                          ; BC = -BC: the magnitude
    sub  c
    ld   c, a
    sbc  a, a
    sub  b
    ld   b, a
.pos:
    ld   d, 128 + 16                ; 0.(the 16 bits) x 2^16
    ld   a, b
    or   c
    jr   z, .zero
.norm:
    bit  7, b
    jr   nz, .store
    sla  c
    rl   b
    dec  d
    jr   .norm
.store:
    inc  hl
    ld   (hl), d                    ; the exponent
    inc  hl
    ld   (hl), b                    ; m0
    inc  hl
    ld   (hl), c                    ; m1
    inc  hl
    ld   b, 3                       ; m2, m3, the guard
    jr   FZERO
.zero:
    ld   b, 7
    jr   FZERO

; ============================================================================
; FNORM -- FX normalised: the mantissa shifted left until its top bit is set,
; the exponent lowered; 0 when the mantissa is 0 or the exponent falls below 1
; Destroys: AF, BC, HL
; ============================================================================
FNORM:
    ld   hl, FX + U_M
    ld   b, 5
    xor  a
.t:
    or   (hl)
    inc  hl
    djnz .t
    jr   z, FZEROX
.l:
    ld   a, (FX + U_M)
    rla
    ret  c
    ld   hl, FX + U_E
    dec  (hl)
    jr   z, FZEROX
    ld   hl, FX + U_G
    ld   b, 5
    or   a
    call FSHL
    jr   .l

FZEROX:                             ; FX = 0. Destroys: AF, B, HL
    ld   hl, FX
    ld   b, 7
FZERO:                              ; HL -> B bytes = 0. Destroys: AF, B, HL
    xor  a
.z:
    ld   (hl), a
    inc  hl
    djnz .z
    ret

; ============================================================================
; Multi-byte helpers on big-endian numbers
; FSHL -- (HL) = the least significant byte of B bytes: shift them left one
;      bit, carry in and out
; FSHR -- (HL) = the most significant byte of B bytes: shift them right one
;      bit, carry in and out
; FADDN, FSUBN -- (DE) += / -= (HL), B bytes, HL and DE at the least
;      significant bytes: C = the carry or borrow out
; Destroys: F, B, DE, HL (FADDN, FSUBN: and A)
; ============================================================================
FSHL:
    rl   (hl)
    dec  hl
    djnz FSHL
    ret
FSHR:
    rr   (hl)
    inc  hl
    djnz FSHR
    ret
FADDN:
    or   a
.l:
    ld   a, (de)
    adc  a, (hl)
    ld   (de), a
    dec  hl
    dec  de
    djnz .l
    ret
FSUBN:
    or   a
.l:
    ld   a, (de)
    sbc  a, (hl)
    ld   (de), a
    dec  hl
    dec  de
    djnz .l
    ret

; ============================================================================
; FSUB -- FX -= FY; FADD -- FX += FY (signed magnitudes)
; Errors: overflow. Destroys: AF, BC, DE, HL
; ============================================================================
FSUB:
    ld   hl, FY + U_S
    ld   a, (hl)
    xor  $80
    ld   (hl), a
FADD:
    ld   a, (FY + U_E)
    or   a
    ret  z                          ; x + 0
    ld   a, (FX + U_E)
    or   a
    jr   z, .y                      ; 0 + y
    ld   hl, FX + U_E               ; the larger magnitude in FX
    ld   de, FY + U_E
    ld   b, 6
.c:
    ld   a, (de)
    cp   (hl)
    jr   nz, .cd
    inc  hl
    inc  de
    djnz .c
    jr   .al
.cd:
    call nc, FSWAP                  ; FY's is larger
.al:
    ld   a, (FY + U_E)
    ld   b, a
    ld   a, (FX + U_E)
    sub  b                          ; the exponents' difference
    cp   40
    ret  nc                         ; FY lies below the guard byte
    or   a
    jr   z, .same
    ld   b, a
    ld   hl, (FY + U_M)             ; (R1, speed: FY's mantissa shifted in registers; Leap-C
    ld   de, (FY + U_M + 2)         ; shifts it in memory)
    ld   a, (FY + U_G)
.sh:
    srl  l                          ; m0
    rr   h                          ; m1
    rr   e                          ; m2
    rr   d                          ; m3
    rra                             ; the guard
    djnz .sh
    ld   (FY + U_M), hl
    ld   (FY + U_M + 2), de
    ld   (FY + U_G), a
.same:
    ld   a, (FY + U_S)
    ld   hl, FX + U_S
    xor  (hl)
    ld   hl, FY + U_G
    ld   de, FX + U_G
    ld   b, 5
    jr   nz, .sub
    call FADDN
    ret  nc
    ld   hl, FX + U_M               ; a carry: one bit more
    ld   b, 5
    call FSHR                       ; (the carry comes in at the top)
    ld   hl, FX + U_E
    inc  (hl)
    ret  nz
    jp   CALC_ABORT_NUMERIC_OVERFLOW
.sub:
    call FSUBN
    jp   FNORM
.y:
    ld   hl, FY
    ld   de, FX
    ld   bc, 7
    ldir
    ret
FSWAP:                              ; FX <-> FY
    ld   hl, FX
    ld   de, FY
    ld   b, 7
.s:
    ld   a, (de)
    ld   c, (hl)
    ld   (hl), a
    ld   a, c
    ld   (de), a
    inc  hl
    inc  de
    djnz .s
    ret

; ============================================================================
; FMUL -- FX *= FY: 32 x 32 bits, the product's top 40 bits
; FDIV -- FX /= FY: 40 quotient bits by restoring division
; Errors: overflow; FDIV: division by 0. Destroys: AF, BC, DE, HL
; ============================================================================
FMUL:
    ld   a, (FX + U_E)
    or   a
    ret  z
    ld   a, (FY + U_E)
    or   a
    jp   z, FZEROX
    call FSIGN
    add  hl, de
    push hl                         ; ex + ey
    ld   hl, FQ
    ld   b, 5
    call FZERO
    ld   hl, FY + U_M + 3           ; (R1, speed: the multiplier's bits come from A, a byte at
    ld   c, 4                       ; a time; Leap-C shifts FY's mantissa for each bit)
.byte:
    ld   a, (hl)
    scf
    rra                             ; C = its lowest bit, a marker bit above the other seven
.bit:
    push hl
    push af
    jr   nc, .no
    ld   hl, FX + U_M + 3
    ld   de, FQ + 3
    ld   b, 4
    call FADDN                      ; (C = the carry out)
.no:
    ld   hl, FQ
    ld   b, 5
    call FSHR
    pop  af
    pop  hl
    srl  a                          ; C = the multiplier's next bit (Z: the marker is out)
    jr   nz, .bit
    dec  hl
    dec  c
    jr   nz, .byte
    ld   de, -128
    jr   FDONE
FDIV:
    ld   a, (FY + U_E)
    or   a
    jr   nz, .div
    ld   a, CALC_ERR_DIVISION_BY_ZERO
    jp   CALC_ABORT_STREAM
.div:
    ld   a, (FX + U_E)
    or   a
    ret  z
    call FSIGN
    or   a
    sbc  hl, de
    push hl                         ; ex - ey
    ld   hl, FQ                     ; (R1, speed: Q is built a byte at a time in C and R is
    ld   bc, $0501                  ; compared with D before it is subtracted; Leap-C shifts
    or   a                          ; all of Q per bit and adds D back. The same 40 bits.)
.bit:                               ; B = Q's bytes left, C = this byte so far behind a marker
    push bc                         ; bit (out after 8 bits), the carry = R's 33rd bit
    push hl
    jr   c, .sub                    ; R had a 33rd bit: it is larger
    ld   hl, FX + U_M
    ld   de, FY + U_M
    ld   b, 4
.cmp:                               ; the most significant bytes first
    ld   a, (de)
    cp   (hl)
    jr   c, .sub                    ; D < R
    jr   nz, .q                     ; D > R: this bit 0 (C clear)
    inc  hl
    inc  de
    djnz .cmp                       ; (R = D: subtract)
.sub:
    ld   hl, FY + U_M + 3
    ld   de, FX + U_M + 3
    ld   b, 4
    call FSUBN                      ; R -= D
    scf                             ; this bit: 1
.q:
    pop  hl
    pop  bc
    rl   c                          ; the bit into Q's byte
    jr   nc, .r
    ld   (hl), c                    ; 8 bits: Q's next byte
    inc  hl
    ld   c, 1
    dec  b
    jr   z, .end
.r:
    push hl
    push bc
    ld   hl, FX + U_M + 3
    ld   b, 4
    or   a
    call FSHL                       ; R <<= 1, C = its 33rd bit
    pop  bc
    pop  hl
    jr   .bit
.end:
    ld   de, 129                    ; the first bit has the weight 2^0
FDONE:                              ; FX's mantissa = FQ, exponent (SP) + DE
    pop  hl
    add  hl, de
    push hl
    ld   hl, FQ
    ld   de, FX + U_M
    ld   bc, 5
    ldir
    pop  hl
    ld   a, (FX + U_M)              ; at most one place to normalise
    rla
    jr   c, .n
    dec  hl
    push hl
    ld   hl, FX + U_G
    ld   b, 5
    or   a
    call FSHL
    pop  hl
.n:
    ld   a, h
    or   a
    jr   nz, .out
    or   l
    jp   z, FZEROX                  ; below the range: 0
    ld   (FX + U_E), a
    ret
.out:
    jp   m, FZEROX
    jp   CALC_ABORT_NUMERIC_OVERFLOW
; FSIGN -- FX's sign = the product's or quotient's; HL = ex, DE = ey. Destroys: AF, DE, HL
FSIGN:
    ld   hl, FX + U_S
    ld   a, (FY + U_S)
    xor  (hl)
    ld   (hl), a
    ld   a, (FX + U_E)
    ld   l, a
    ld   h, 0
    ld   a, (FY + U_E)
    ld   e, a
    ld   d, h
    ret

; ============================================================================
; CALC_TABLE: one 4-byte entry per implemented literal (the literal, the stack
; operands it takes, its handler), ended by $FF. Any other literal is
; CALC_ERR_UNIMPLEMENTED. EXROM-internal: not part of the fixed entry ABI.
; ============================================================================
CALC_TABLE:
    DB $01, 2
    DW CALC_OP_EXCHANGE
    DB $02, 2
    DW CALC_OP_DELETE
    DB $03, 2
    DW CALC_OP_SUB
    DB $04, 2
    DW CALC_OP_MUL
    DB $05, 2
    DW CALC_OP_DIV
    DB $0F, 2
    DW CALC_OP_ADD
    DB $31, 1
    DW CALC_OP_DUPLICATE
    DB $38, 0
    DW CALC_OP_END_CALC
    DB $FF
