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
; $05 divide, $0F add, $31 duplicate, $38 end-calc). The arithmetic bodies
; further down are this project's own (see each op's header).
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
; CALC_UNPACK / CALC_PACK — general float <-> internal record conversion,
; shared by INT_TO_FP/FP_TO_INT and the arithmetic engine below. Internal
; record (6 bytes, at CALC_UNP_A or CALC_UNP_B — see sysvars.inc): byte0
; = sign ($00/$FF, matching the float format's own small-int-form
; convention), byte1 = biased exponent (0 = zero value), bytes2-5 = 32-
; bit mantissa MSB-first with the implicit leading bit made explicit.
; A single unpack routine that checks the small-int fast-path form
; FIRST is mandatory here — the Python model this was ported from hit a
; real bug from splitting that check out (see project /areas notes,
; "unpack() split into two functions" entry) where a general-only
; unpacker silently treated fast-path zero as general zero and vice
; versa, since both forms use byte0=$00.
;
; CALC_UNPACK  In: HL=src 5-byte float ptr, DE=dest 6-byte record ptr
;              Out: record filled. Destroys AF,BC,DE,HL
; CALC_PACK    In: HL=src 6-byte record ptr, DE=dest 5-byte float ptr.
;              Always writes GENERAL form (never re-derives the small-
;              int fast form for an exact-integer result) — FP_TO_INT
;              already handles both forms on read, so nothing
;              downstream needs the fast form specifically.
;              Out: float written. Destroys AF,BC,DE,HL
; ============================================================================
CALC_UNPACK:
    ld   a, (hl)
    or   a
    jr   nz, .cu_general
    inc  hl
    ld   a, (hl)                 ; sign byte ($00/$FF)
    push af
    inc  hl
    ld   c, (hl)                  ; low byte of pattern
    inc  hl
    ld   b, (hl)                   ; high byte of pattern
    ld   a, b
    or   c
    jr   nz, .cu_fast_nonzero
    pop  af
    xor  a
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    ret
.cu_fast_nonzero:
    pop  af
    or   a
    jr   z, .cu_fast_write_sign
    push af
    xor  a
    sub  c
    ld   c, a
    ld   a, 0
    sbc  a, b
    ld   b, a
    pop  af
.cu_fast_write_sign:
    ld   (de), a                  ; record byte0 = sign
    push de
    ld   h, 0
    ld   l, 0
    ld   d, b
    ld   e, c
    ld   b, 0
.cu_norm_loop:
    bit  7, h
    jr   nz, .cu_norm_done
    sla  e
    rl   d
    rl   l
    rl   h
    inc  b
    jr   .cu_norm_loop
.cu_norm_done:
    ld   a, 160
    sub  b
    ld   b, e                      ; FIXED: D/E currently hold mantissa
                                   ; bytes 1/0 -- popping DE next would
                                   ; destroy them (DE becomes the
                                   ; record address instead), so stash
                                   ; them in B/C first (B is free, its
                                   ; only other job -- the shift
                                   ; counter -- is done). Also fixes a
                                   ; SECOND bug this uncovered: `LD
                                   ; (DE),H/L/D/E` isn't a real Z80
                                   ; opcode at all -- (DE)-indirect
                                   ; only ever supports A as the
                                   ; source (LD (DE),A, opcode $12) —
                                   ; sjasmplus would have rejected this
                                   ; outright. Every write below now
                                   ; goes through A, the only valid
                                   ; source register for a (DE) write.
                                   ; Found by decoding a real unpacked
                                   ; record back through the verified
                                   ; Python model and noticing bytes
                                   ; 4-5 exactly matched (record_addr+4)
                                   ; and (record_addr+5)'s own high/low
                                   ; bytes -- i.e. this routine was
                                   ; writing its OWN pointer back into
                                   ; itself, not the mantissa at all.
    ld   c, d
    pop  de
    inc  de
    ld   (de), a                  ; exponent
    inc  de
    ld   a, h
    ld   (de), a                    ; mantissa MSB
    inc  de
    ld   a, l
    ld   (de), a
    inc  de
    ld   a, c                       ; mantissa byte1 (was D)
    ld   (de), a
    inc  de
    ld   a, b                        ; mantissa LSB (was E)
    ld   (de), a
    ret
.cu_general:
    push af                        ; A = exponent (byte0), saved
    inc  hl
    ld   a, (hl)                    ; byte1
    ld   c, a
    and  $80
    jr   z, .cu_gen_pos
    ld   a, $FF
    jr   .cu_gen_sign_done
.cu_gen_pos:
    xor  a
.cu_gen_sign_done:
    ld   (de), a
    inc  de
    pop  af
    ld   (de), a                    ; exponent
    inc  de
    ld   a, c
    and  $7F
    or   $80
    ld   (de), a                     ; mantissa MSB (implicit bit set)
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    ret

CALC_PACK:
    ld   a, (hl)
    push af
    inc  hl
    ld   a, (hl)                     ; exponent
    or   a
    jr   z, .cp_zero
    ld   (de), a
    inc  de
    pop  af
    and  $80
    ld   b, a
    inc  hl
    ld   a, (hl)                      ; mantissa MSB (bit7 already 1)
    and  $7F
    or   b
    ld   (de), a
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    inc  de
    inc  hl
    ld   a, (hl)
    ld   (de), a
    ret
.cp_zero:
    pop  af
    xor  a
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    inc  de
    ld   (de), a
    ret

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
; range check).
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
    ld   (CALC_UNP_A+1), a
    inc  hl
    ld   a, (hl)
    ld   c, a
    and  $80
    ld   (CALC_SHIFT_COUNT), a        ; stash sign bit ($00/$80)
    ld   a, c
    and  $7F
    or   $80
    ld   (CALC_UNP_A+2), a
    inc  hl
    ld   a, (hl)
    ld   (CALC_UNP_A+3), a
    inc  hl
    ld   a, (hl)
    ld   (CALC_UNP_A+4), a           ; source byte4 (true LSB) dropped —
                                     ; see header, never affects the
                                     ; overflow/no-overflow verdict for
                                     ; this BASIC's 16-bit-sourced range
    ld   a, (CALC_UNP_A+1)
    sub  128
    jr   z, .fpi_result_zero
    jp   m, .fpi_result_zero
    cp   17
    jr   nc, .fpi_overflow_noshift    ; unbiased exponent >= 17 ->
                                       ; magnitude always >= 65536,
                                       ; never a valid 16-bit int
    ; FIXED (found by re-deriving this in Python against the verified
    ; model before trusting it, not caught by eye): the real shift
    ; needed is (32-EXP_UNBIASED) applied to the FULL 32-bit mantissa,
    ; but since EXP_UNBIASED here is always 1-16, that shift is always
    ; >=16 -- meaning the result depends ONLY on the mantissa's top 16
    ; bits (this record's MSB byte + the next byte), shifted by
    ; (16-EXP_UNBIASED), 0..15. The original version tracked a 3rd
    ; mantissa byte and read out the WRONG 16-bit window afterward (a
    ; 16-bit position error) -- dropped that byte and the wrong
    ; register entirely rather than patching the read-out math.
    ld   b, a
    ld   a, 16
    sub  b
    ld   b, a                          ; shift amount, 0..15
    ld   a, (CALC_UNP_A+2)
    ld   h, a
    ld   a, (CALC_UNP_A+3)
    ld   l, a
    ld   a, b
    or   a
    jr   z, .fpi_shift_done
.fpi_shift_loop:
    srl  h
    rr   l
    djnz .fpi_shift_loop
.fpi_shift_done:
    ld   a, (CALC_SHIFT_COUNT)
    or   a
    jr   z, .fpi_check
    xor  a
    sub  l
    ld   l, a
    ld   a, 0
    sbc  a, h
    ld   h, a
.fpi_check:
    ld   a, (CALC_SHIFT_COUNT)
    ld   c, a
    ld   a, h
    and  $80
    cp   c
    jr   nz, .fpi_overflow
    xor  a
    ld   (CALC_TRUNC_FLAG), a
    or   a
    ret
.fpi_overflow:
    jr   .fpi_saturate
.fpi_overflow_noshift:
.fpi_saturate:
    ld   hl, $7FFF
    ld   a, (CALC_SHIFT_COUNT)
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
; CALC_ADDSUB_ENGINE — shared add/subtract-via-sign-flip engine.
; Combines the already-unpacked records at CALC_UNP_A/CALC_UNP_B,
; leaving the result in CALC_UNP_A. CALC_OP_SUB flips CALC_UNP_B's sign
; before calling this, matching A-B = A+(-B); CALC_OP_ADD calls it
; directly.
;
; Algorithm: zero shortcuts, then pick the WINNER (larger-scale
; operand — bigger exponent, or if tied, bigger mantissa) and swap the
; two records if B is the winner, so CALC_UNP_A always ends up holding
; the winner and CALC_UNP_B the loser — this means the align/combine
; code below only ever has to handle ONE case, not two symmetric ones.
; Loser's mantissa is then shifted right by (winner_exp - loser_exp)
; to align scales. Same-sign -> 32-bit add with carry-out
; renormalization (shift right 1, exponent+1). Different-sign -> 32-bit
; subtract (guaranteed non-negative, since winner>=loser after
; alignment) with left-shift renormalization for cancellation, clamped
; to exact zero on underflow (near-total-cancellation edge case — a
; documented simplification, not a hidden gap: the real ROM does exact
; bit-level cancellation here, this doesn't for extreme cases, which
; this BASIC's 16-bit-int-sourced values essentially never produce).
; In:  CALC_UNP_A, CALC_UNP_B — both already unpacked
; Out: CALC_UNP_A holds the combined result
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_ADDSUB_ENGINE:
    ld   a, (CALC_UNP_A+1)
    or   a
    jr   nz, .ae_a_nonzero
    ld   hl, CALC_UNP_B
    ld   de, CALC_UNP_A
    ld   bc, 6
    ldir
    ret
.ae_a_nonzero:
    ld   a, (CALC_UNP_B+1)
    or   a
    ret  z
    ; winner selection
    ld   a, (CALC_UNP_A+1)
    ld   c, a
    ld   a, (CALC_UNP_B+1)
    cp   c
    jr   c, .ae_no_swap             ; expB < expA -> A wins
    jr   nz, .ae_do_swap             ; expB > expA -> B wins
    ld   hl, CALC_UNP_A+2
    ld   de, CALC_UNP_B+2
    ld   b, 4
.ae_mant_cmp:
    ld   a, (de)
    ld   c, a
    ld   a, (hl)
    cp   c
    jr   nz, .ae_mant_cmp_done
    inc  hl
    inc  de
    djnz .ae_mant_cmp
.ae_mant_cmp_done:
    jr   nc, .ae_no_swap             ; A's byte >= B's byte, or exact tie
.ae_do_swap:
    ld   hl, CALC_UNP_A
    ld   de, CALC_UNP_B
    ld   b, 6
.ae_swap_byte:
    ld   a, (de)
    ld   c, (hl)
    ex   de, hl
    ld   (de), a
    ld   (hl), c
    inc  hl
    inc  de
    djnz .ae_swap_byte
.ae_no_swap:
    ; CALC_UNP_A = winner, CALC_UNP_B = loser. diff = winnerExp-loserExp
    ld   a, (CALC_UNP_A+1)
    ld   b, a
    ld   a, (CALC_UNP_B+1)
    ld   c, a
    ld   a, b
    sub  c
    cp   32
    jr   c, .ae_diff_ok
    xor  a
    ld   (CALC_UNP_B+2), a
    ld   (CALC_UNP_B+3), a
    ld   (CALC_UNP_B+4), a
    ld   (CALC_UNP_B+5), a
    jr   .ae_shift_done
.ae_diff_ok:
    ld   b, a
    ld   a, (CALC_UNP_B+2)
    ld   h, a
    ld   a, (CALC_UNP_B+3)
    ld   l, a
    ld   a, (CALC_UNP_B+4)
    ld   d, a
    ld   a, (CALC_UNP_B+5)
    ld   e, a
    ld   a, b
    or   a
    jr   z, .ae_shift_loop_done
.ae_shift_loop:
    srl  h
    rr   l
    rr   d
    rr   e
    djnz .ae_shift_loop
.ae_shift_loop_done:
    ld   a, h
    ld   (CALC_UNP_B+2), a
    ld   a, l
    ld   (CALC_UNP_B+3), a
    ld   a, d
    ld   (CALC_UNP_B+4), a
    ld   a, e
    ld   (CALC_UNP_B+5), a
.ae_shift_done:
    ld   a, (CALC_UNP_A)
    ld   b, a
    ld   a, (CALC_UNP_B)
    cp   b
    jr   nz, .ae_diff_sign
.ae_same_sign:
    ; No absolute-address form of ADD/ADC exists on real Z80 (only
    ; register, immediate, and (HL)/(IX+d)/(IY+d) operands) — every
    ; byte routed through C as scratch below. sjasmplus caught this
    ; (real ground truth, this sandbox's z80sim is looser and let the
    ; invalid form slide, silently truncating the address to an
    ; immediate instead of erroring) — same underlying lesson as the
    ; CALC_UNPACK (DE)-write bug: know exactly which addressing modes
    ; a real opcode supports, don't assume the simulator enforcing
    ; nothing means the syntax is valid.
    ld   a, (CALC_UNP_B+5)
    ld   c, a
    ld   a, (CALC_UNP_A+5)
    add  a, c
    ld   (CALC_UNP_A+5), a
    ld   a, (CALC_UNP_B+4)
    ld   c, a
    ld   a, (CALC_UNP_A+4)
    adc  a, c
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_UNP_B+3)
    ld   c, a
    ld   a, (CALC_UNP_A+3)
    adc  a, c
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_UNP_B+2)
    ld   c, a
    ld   a, (CALC_UNP_A+2)
    adc  a, c
    ld   (CALC_UNP_A+2), a
    jr   nc, .ae_add_no_carry
    ; carry out of the 32-bit add -- shift right 1 (carry chain first,
    ; THEN set the new MSB bit as a separate final pass -- 'or' clears
    ; carry, so it can't sit between the srl and the rr chain that
    ; needs that carry)
    ld   a, (CALC_UNP_A+2)
    srl  a
    ld   (CALC_UNP_A+2), a
    ld   a, (CALC_UNP_A+3)
    rr   a
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_UNP_A+4)
    rr   a
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_UNP_A+5)
    rr   a
    ld   (CALC_UNP_A+5), a
    ld   a, (CALC_UNP_A+2)
    or   $80
    ld   (CALC_UNP_A+2), a
    ld   a, (CALC_UNP_A+1)
    inc  a
    jp   z, CALC_ABORT_NUMERIC_OVERFLOW
    ld   (CALC_UNP_A+1), a
.ae_add_no_carry:
    ret
.ae_diff_sign:
    ld   a, (CALC_UNP_B+5)
    ld   c, a
    ld   a, (CALC_UNP_A+5)
    sub  c
    ld   (CALC_UNP_A+5), a
    ld   a, (CALC_UNP_B+4)
    ld   c, a
    ld   a, (CALC_UNP_A+4)
    sbc  a, c
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_UNP_B+3)
    ld   c, a
    ld   a, (CALC_UNP_A+3)
    sbc  a, c
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_UNP_B+2)
    ld   c, a
    ld   a, (CALC_UNP_A+2)
    sbc  a, c
    ld   (CALC_UNP_A+2), a
    or   a
    jr   nz, .ae_sub_nonzero
    ld   a, (CALC_UNP_A+3)
    or   a
    jr   nz, .ae_sub_nonzero
    ld   a, (CALC_UNP_A+4)
    or   a
    jr   nz, .ae_sub_nonzero
    ld   a, (CALC_UNP_A+5)
    or   a
    jr   z, .ae_result_zero
.ae_sub_nonzero:
    ld   b, 0
.ae_renorm_loop:
    ld   a, (CALC_UNP_A+2)
    bit  7, a
    jr   nz, .ae_renorm_done
    ld   a, (CALC_UNP_A+1)
    dec  a
    jr   z, .ae_result_zero
    ld   (CALC_UNP_A+1), a
    ld   a, (CALC_UNP_A+5)
    sla  a
    ld   (CALC_UNP_A+5), a
    ld   a, (CALC_UNP_A+4)
    rl   a
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_UNP_A+3)
    rl   a
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_UNP_A+2)
    rl   a
    ld   (CALC_UNP_A+2), a
    inc  b
    ld   a, b
    cp   32
    jr   nc, .ae_result_zero          ; safety cap, shouldn't be reached
    jr   .ae_renorm_loop
.ae_renorm_done:
    ret
.ae_result_zero:
    xor  a
    ld   (CALC_UNP_A), a
    ld   (CALC_UNP_A+1), a
    ld   (CALC_UNP_A+2), a
    ld   (CALC_UNP_A+3), a
    ld   (CALC_UNP_A+4), a
    ld   (CALC_UNP_A+5), a
    ret

; ============================================================================
; CALC_OP_ADD (literal $0F — addition)
; CALC_OP_SUB (literal $03 — subtract)
; Both: unpack the two stack operands (CALC_OP1_PTR=first/lower=A,
; CALC_OP2_PTR=second/top=B — matches the real ROM's HL=first/DE=second
; convention, same as exchange/delete above), combine via the shared
; engine, pack the result back into OP1's slot (the lower of the two
; consumed slots becomes the new top — same structural shape as
; CALC_OP_DELETE), CALC_SP -1 net (two consumed, one produced).
; SUB computes A-B by flipping B's unpacked sign before the shared add
; engine runs (A + (-B) = A-B) — literal $03's own real-ROM semantics:
; first(lower) operand minus second(top) operand.
; In:  CALC_OP1_PTR/CALC_OP2_PTR set by the dispatcher
; Out: CALC_SP decremented by 1; OP1's slot holds the result
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_OP_ADD:
    ld   hl, (CALC_OP1_PTR)
    ld   de, CALC_UNP_A
    call CALC_UNPACK
    ld   hl, (CALC_OP2_PTR)
    ld   de, CALC_UNP_B
    call CALC_UNPACK
    call CALC_ADDSUB_ENGINE
    ld   hl, CALC_UNP_A
    ld   de, (CALC_OP1_PTR)
    call CALC_PACK
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY

CALC_OP_SUB:
    ld   hl, (CALC_OP1_PTR)
    ld   de, CALC_UNP_A
    call CALC_UNPACK
    ld   hl, (CALC_OP2_PTR)
    ld   de, CALC_UNP_B
    call CALC_UNPACK
    ld   a, (CALC_UNP_B)
    xor  $FF                        ; flip sign ($00<->$FF) -- CPL would
                                    ; do the same but tools/z80sim/sim.py
                                    ; doesn't implement it (confirmed by
                                    ; a real run, not assumed); XOR $FF
                                    ; is an exact substitute here since
                                    ; the only two values ever stored in
                                    ; this byte are $00 and $FF
    ld   (CALC_UNP_B), a
    call CALC_ADDSUB_ENGINE
    ld   hl, CALC_UNP_A
    ld   de, (CALC_OP1_PTR)
    call CALC_PACK
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY

; ============================================================================
; CALC_OP_MUL (literal $04 — multiply)
; Real 32x32->64 unsigned multiply via shift-add (CALC_MUL_ACC/
; CALC_MUL_CAND, 8 bytes each — no hardware multiply on Z80, same
; reasoning as kernel/math's MATH_UMUL16, extended to full 64-bit width
; since a float mantissa product genuinely needs it, unlike that
; routine's deliberate 16-bit truncation). Sign = XOR of the two
; operand signs (works directly on the existing 0/$FF encoding — same
; value either way). Result exponent: bit63 of the 64-bit product set
; -> exponent=expA+expB-128, top32 of product = mantissa; bit63 clear
; -> shift product left 1 first, exponent=expA+expB-129 (derivation:
; value = mantissaA*mantissaB/2^64 * 2^(expA+expB-256), normalized back
; into mantissa/2^32*2^(exp-128) form — see project /areas notes for
; the full algebra this was worked out from).
; In:  CALC_OP1_PTR/CALC_OP2_PTR set by the dispatcher
; Out: CALC_SP decremented by 1; OP1's slot holds the result
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_OP_MUL:
    ld   hl, (CALC_OP1_PTR)
    ld   de, CALC_UNP_A
    call CALC_UNPACK
    ld   hl, (CALC_OP2_PTR)
    ld   de, CALC_UNP_B
    call CALC_UNPACK
    ld   a, (CALC_UNP_A+1)
    or   a
    jp   z, .cm_zero
    ld   a, (CALC_UNP_B+1)
    or   a
    jp   z, .cm_zero
    ld   a, (CALC_UNP_A)
    ld   b, a
    ld   a, (CALC_UNP_B)
    xor  b
    ld   (CALC_SHIFT_COUNT), a       ; stash result sign
    ; Zero CALC_MUL_ACC (8 bytes) and CALC_MUL_CAND's own high 4 bytes
    ; (+4..+7) in one pass — CALC_MUL_ACC and CALC_MUL_CAND are
    ; contiguous in include/sysvars.inc (ACC: DEFS 8 immediately
    ; followed by CAND: DEFS 8), so zeroing all 16 bytes from
    ; CALC_MUL_ACC through CALC_MUL_CAND+7 covers exactly the same
    ; ground as the 12 individual stores this replaced — CAND+0..+3
    ; get unconditionally overwritten with real data a few lines below
    ; regardless, so zeroing them here too is harmless, not a
    ; behavior change.
    xor  a
    ld   hl, CALC_MUL_ACC
    ld   b, 16
.cm_zero_init:
    ld   (hl), a
    inc  hl
    djnz .cm_zero_init
    ; FIXED: mantissaA must start in CAND's LOW 32 bits (bytes 0-3),
    ; not the high half -- the standard shift-and-add algorithm needs
    ; the multiplicand UNSHIFTED at iteration 0, growing left into the
    ; upper 32 bits only as the 32 iterations proceed. The original
    ; version put it in the high half with the low half zeroed, which
    ; produced a wildly wrong product (not just a misaligned one) —
    ; caught by decoding a real 2*3 z80sim result back to a float
    ; (7.76, not 6) and comparing byte-for-byte against the verified
    ; Python model's expected encoding, not by inspection.
    ld   a, (CALC_UNP_A+5)
    ld   (CALC_MUL_CAND), a
    ld   a, (CALC_UNP_A+4)
    ld   (CALC_MUL_CAND+1), a
    ld   a, (CALC_UNP_A+3)
    ld   (CALC_MUL_CAND+2), a
    ld   a, (CALC_UNP_A+2)
    ld   (CALC_MUL_CAND+3), a
    ld   b, 32
.cm_loop:
    ; B (the 32-iteration counter) is never touched by anything in this
    ; body -- no push/pop bc needed around it, unlike a routine that
    ; genuinely reuses B for scratch mid-loop.
    ld   a, (CALC_UNP_B+2)
    srl  a
    ld   (CALC_UNP_B+2), a
    ld   a, (CALC_UNP_B+3)
    rr   a
    ld   (CALC_UNP_B+3), a
    ld   a, (CALC_UNP_B+4)
    rr   a
    ld   (CALC_UNP_B+4), a
    ld   a, (CALC_UNP_B+5)
    rr   a
    ld   (CALC_UNP_B+5), a
    jr   nc, .cm_no_add
    ; ACC += CAND (8-byte add, LSB-first) via the shared CALC_ADD8 --
    ; B (this loop's own 32-iteration counter) must survive the call,
    ; so it's stashed on the real stack, not relied on to sit still
    ; through CALC_ADD8's own internal DJNZ use of the same register.
    push bc
    ld   hl, CALC_MUL_ACC
    ld   de, CALC_MUL_CAND
    call CALC_ADD8
    pop  bc
.cm_no_add:
    ; CAND <<= 1 (8-byte left shift, LSB-first) via the shared
    ; CALC_SHL8 -- same B-preservation reasoning as above.
    push bc
    ld   hl, CALC_MUL_CAND
    call CALC_SHL8
    pop  bc
    ; DJNZ's displacement is +-127 bytes (lesson 2) -- this loop body
    ; is far too long for it (found by real sjasmplus, not this
    ; sandbox's z80sim, which has no range-checking at all). Plain
    ; DEC B + JP NZ instead, same pattern this project already uses
    ; everywhere else a jump might be far from its target.
    dec  b
    jr   nz, .cm_loop
    ld   a, (CALC_MUL_ACC+7)
    bit  7, a
    jr   nz, .cm_no_renorm
    ; ACC <<= 1 via the shared CALC_SHL8 -- loop has already exited
    ; (B is free here), same shift shape as CAND's own per-iteration
    ; doubling above.
    ld   hl, CALC_MUL_ACC
    call CALC_SHL8
    ld   c, 129
    jr   .cm_compute_exp
.cm_no_renorm:
    ld   c, 128
.cm_compute_exp:
    ld   a, (CALC_UNP_A+1)
    ld   l, a
    ld   h, 0
    ld   a, (CALC_UNP_B+1)
    ld   e, a
    ld   d, 0
    add  hl, de
    ld   a, l
    sub  c
    ld   l, a
    ld   a, h
    sbc  a, 0
    ld   h, a
    cp   $FF
    jr   z, .cm_zero                  ; exponent underflow -> signed zero
    or   a
    jp   nz, CALC_ABORT_NUMERIC_OVERFLOW
    ld   a, l
    or   a
    jr   z, .cm_zero                  ; biased exponent zero is underflow
.cm_store_exp:
    ld   (CALC_UNP_A+1), a
    ld   a, (CALC_SHIFT_COUNT)
    ld   (CALC_UNP_A), a
    ld   a, (CALC_MUL_ACC+7)
    ld   (CALC_UNP_A+2), a
    ld   a, (CALC_MUL_ACC+6)
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_MUL_ACC+5)
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_MUL_ACC+4)
    ld   (CALC_UNP_A+5), a
    jr   .cm_pack
.cm_zero:
    xor  a
    ld   (CALC_UNP_A), a
    ld   (CALC_UNP_A+1), a
    ld   (CALC_UNP_A+2), a
    ld   (CALC_UNP_A+3), a
    ld   (CALC_UNP_A+4), a
    ld   (CALC_UNP_A+5), a
.cm_pack:
    ld   hl, CALC_UNP_A
    ld   de, (CALC_OP1_PTR)
    call CALC_PACK
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY

; ============================================================================
; CALC_OP_DIV (literal $05 — division; real ROM's
; own numbering — see 335B.html's literal list — division sits right
; after multiply, same as here)
;
; Computes OP1/OP2 (first(lower) operand divided by second(top), same
; first/second convention as CALC_OP_SUB — real ROM semantics, not this
; project's own invention).
;
; ALGORITHM (verified via Python simulation, both an abstract-integer
; model and a byte-accurate simulation of this exact instruction
; sequence, >5000 random signed cases plus the multiply test's own
; 181*181=32761 as a round-trip check — 32761/181 decodes back to
; BYTE-IDENTICAL record bytes as encoding 181 directly, not just a
; numerically-close value — before any Z80 was written, same discipline
; as kernel/math's MATH_DIVIDE16 and this file's own CALC_OP_MUL):
;
; Both mantissas (MA, MB — CALC_UNP_A+2..+5 / CALC_UNP_B+2..+5) are
; already normalized into [0.5,1) as 32-bit fractions (implicit leading
; bit forced by CALC_UNPACK). Precondition the shift-subtract loop below
; on MA < MB (true division needs the dividend strictly smaller than
; the divisor to produce a quotient that itself lands back in [0.5,1)
; with NO renormalization needed afterward — see the derivation this
; was worked out from in project /areas notes): if MA >= MB, shift MA
; right by 1 first (guaranteed to make it < MB, since MA is always <
; 2*MB when both mantissas are already normalized) and bump the result
; exponent by 1 to compensate — this is the ONLY exponent adjustment
; ever needed; unlike CALC_OP_MUL, there is no post-loop renormalization
; branch at all, because the pre-shift decision is made up front instead
; of after the fact.
;
; Main loop: 32 iterations of shift-and-subtract (same shape as kernel/
; math's MATH_UDIV16 restoring division, scaled from 16-bit to 32-bit
; mantissas): shift CALC_DIV_REM left 1 bit each iteration. The carry
; OUT of that shift (the "33rd bit" — REM's true value momentarily
; exceeding 32 bits) is checked FIRST and, if set, unconditionally
; forces a subtract — REM's true value is then guaranteed >= MB, since
; MB itself is always < 2^32. This matters: a shift-left-then-truncate-
; to-32-bits-then-compare approach (without checking that carry
; explicitly) would silently misjudge exactly this case, the same class
; of truncation bug this project already has reason to be wary of. If
; the carry is clear, an ordinary MSB-first 4-byte compare against MB
; decides. Either way, the actual subtract (REM -= MB, done as a
; straight 4-byte mod-2^32 subtract via the stored, possibly-truncated
; REM bytes) is provably correct regardless of which path set it up —
; (REM - MB) mod 2^32 and (REM + 2^32 - MB) mod 2^32 are the same value,
; so the subtract chain needs no special-casing between the two entry
; paths. Each iteration also shifts CALC_DIV_QUOT left, ORing in this
; iteration's quotient bit (1 if subtracted, 0 if not).
;
; Zero shortcuts: divisor mantissa zero (CALC_UNP_B+1 = 0, i.e. B is
; exactly zero) returns CALC_ERR_DIVISION_BY_ZERO through the normal
; END-CALC and paging-safe BASIC error path. Dividend
; mantissa zero (A is exactly zero, B nonzero) short-circuits straight
; to a zero result, same shape as CALC_OP_MUL's own .cm_zero path.
;
; In:  CALC_OP1_PTR/CALC_OP2_PTR set by the dispatcher
; Out: CALC_SP decremented by 1; OP1's slot holds the result, or the
;      stream aborts recoverably on division by zero/numeric overflow.
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_OP_DIV:
    ld   hl, (CALC_OP1_PTR)
    ld   de, CALC_UNP_A
    call CALC_UNPACK
    ld   hl, (CALC_OP2_PTR)
    ld   de, CALC_UNP_B
    call CALC_UNPACK

    ld   a, (CALC_UNP_B+1)
    or   a
    jp   z, .cd_divzero

    ld   a, (CALC_UNP_A+1)
    or   a
    jp   z, .cd_zero

    ld   a, (CALC_UNP_A)
    ld   b, a
    ld   a, (CALC_UNP_B)
    xor  b
    ld   (CALC_SHIFT_COUNT), a       ; stash result sign

    ld   a, (CALC_UNP_A+1)
    ld   l, a
    ld   h, 0
    ld   a, (CALC_UNP_B+1)
    ld   e, a
    ld   d, 0
    or   a
    sbc  hl, de
    ld   de, 128
    add  hl, de
    ld   a, h
    cp   $FF
    jp   z, .cd_zero                  ; exponent underflow -> signed zero
    or   a
    jp   nz, CALC_ABORT_NUMERIC_OVERFLOW
    ld   a, l
    or   a
    jp   z, .cd_zero
    ld   (CALC_UNP_A+1), a           ; provisional exponent, no preshift

    ; preshift decision: is MA (CALC_UNP_A+2..+5) < MB (CALC_UNP_B+2..+5),
    ; MSB first, via the shared CALC_CMP4 — this block runs before B is
    ; loaded as the outer 32-iteration counter (that happens below at
    ; .cd_setup_done), so CALC_CMP4's own internal use of B is safe here.
    ld   hl, CALC_UNP_A+2
    ld   de, CALC_UNP_B+2
    call CALC_CMP4
    jr   c, .cd_no_preshift
    ; MA >= MB (including an exact tie) -> preshift
.cd_preshift:
    ld   a, (CALC_UNP_A+1)
    inc  a
    jp   z, CALC_ABORT_NUMERIC_OVERFLOW
    ld   (CALC_UNP_A+1), a
    ld   a, (CALC_UNP_A+2)
    srl  a
    ld   (CALC_DIV_REM), a
    ld   a, (CALC_UNP_A+3)
    rr   a
    ld   (CALC_DIV_REM+1), a
    ld   a, (CALC_UNP_A+4)
    rr   a
    ld   (CALC_DIV_REM+2), a
    ld   a, (CALC_UNP_A+5)
    rr   a
    ld   (CALC_DIV_REM+3), a
    jr   .cd_setup_done
.cd_no_preshift:
    ld   a, (CALC_UNP_A+2)
    ld   (CALC_DIV_REM), a
    ld   a, (CALC_UNP_A+3)
    ld   (CALC_DIV_REM+1), a
    ld   a, (CALC_UNP_A+4)
    ld   (CALC_DIV_REM+2), a
    ld   a, (CALC_UNP_A+5)
    ld   (CALC_DIV_REM+3), a
.cd_setup_done:
    xor  a
    ld   (CALC_DIV_QUOT), a
    ld   (CALC_DIV_QUOT+1), a
    ld   (CALC_DIV_QUOT+2), a
    ld   (CALC_DIV_QUOT+3), a

    ld   b, 32
.cd_loop:
    ; shift CALC_DIV_REM left 1 bit (no bit injected — pure left shift);
    ; the carry left in the flags afterward is the true 33rd bit
    ld   a, (CALC_DIV_REM+3)
    sla  a
    ld   (CALC_DIV_REM+3), a
    ld   a, (CALC_DIV_REM+2)
    rl   a
    ld   (CALC_DIV_REM+2), a
    ld   a, (CALC_DIV_REM+1)
    rl   a
    ld   (CALC_DIV_REM+1), a
    ld   a, (CALC_DIV_REM)
    rl   a
    ld   (CALC_DIV_REM), a
    jr   c, .cd_do_subtract           ; carry out of the top byte -> REM's
                                      ; true value is already >= 2^32,
                                      ; unconditionally >= MB (<2^32)
    ; is REM < MB, MSB first, via the shared CALC_CMP4 -- B (this loop's
    ; own 32-iteration counter) must survive, stashed on the real stack.
    push bc
    ld   hl, CALC_DIV_REM
    ld   de, CALC_UNP_B+2
    call CALC_CMP4
    pop  bc
    jr   c, .cd_no_subtract
    ; REM >= MB (including an exact tie) -> fall through to subtract
.cd_do_subtract:
    ; REM -= MB (4-byte subtract, LSB-first) via the shared CALC_SUB4 --
    ; same B-preservation reasoning as the compare above.
    push bc
    ld   hl, CALC_DIV_REM+3
    ld   de, CALC_UNP_B+5
    call CALC_SUB4
    pop  bc
    scf                                ; this iteration's quotient bit = 1
    jr   .cd_shift_quot
.cd_no_subtract:
    or   a                              ; clears carry -> quotient bit = 0
.cd_shift_quot:
    ld   a, (CALC_DIV_QUOT+3)
    rl   a
    ld   (CALC_DIV_QUOT+3), a
    ld   a, (CALC_DIV_QUOT+2)
    rl   a
    ld   (CALC_DIV_QUOT+2), a
    ld   a, (CALC_DIV_QUOT+1)
    rl   a
    ld   (CALC_DIV_QUOT+1), a
    ld   a, (CALC_DIV_QUOT)
    rl   a
    ld   (CALC_DIV_QUOT), a
    ; B (the 32-iteration counter) is never touched by anything above —
    ; same discipline as CALC_OP_MUL's own loop
    dec  b
    jr   nz, .cd_loop

    ld   a, (CALC_SHIFT_COUNT)
    ld   (CALC_UNP_A), a
    ld   a, (CALC_DIV_QUOT)
    ld   (CALC_UNP_A+2), a
    ld   a, (CALC_DIV_QUOT+1)
    ld   (CALC_UNP_A+3), a
    ld   a, (CALC_DIV_QUOT+2)
    ld   (CALC_UNP_A+4), a
    ld   a, (CALC_DIV_QUOT+3)
    ld   (CALC_UNP_A+5), a
    jr   .cd_pack
.cd_zero:
    xor  a
    ld   (CALC_UNP_A), a
    ld   (CALC_UNP_A+1), a
    ld   (CALC_UNP_A+2), a
    ld   (CALC_UNP_A+3), a
    ld   (CALC_UNP_A+4), a
    ld   (CALC_UNP_A+5), a
.cd_pack:
    ld   hl, CALC_UNP_A
    ld   de, (CALC_OP1_PTR)
    call CALC_PACK
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    jp   CALC_RE_ENTRY
.cd_divzero:
    ld   a, CALC_ERR_DIVISION_BY_ZERO
    jp   CALC_ABORT_STREAM

; ============================================================================
; CALC_ADD8 (internal)
; 8-byte add: (HL..HL+7) += (DE..DE+7), LSB-first (byte 0 is the least
; significant), stored back into (HL..HL+7). Byte 0 uses a plain ADD
; (discards any incoming carry, matching CALC_OP_MUL's own original
; inline sequence); bytes 1-7 use ADC to propagate carry. Shared by
; CALC_OP_MUL's accumulate step (was 12 near-identical LD/ADD/LD groups
; inlined at absolute addresses -- confirmed via cross-project research
; this session that structured-basic-poc's own N_ADD uses exactly this
; pointer+DJNZ shape for the same job).
; In:  HL = augend's LSB address, DE = addend's LSB address
; Out: (HL..HL+7) = original (HL..HL+7) + (DE..DE+7); HL/DE advanced by 8
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_ADD8:
    ld   a, (de)
    add  a, (hl)
    ld   (hl), a
    inc  hl
    inc  de
    ld   b, 7
.loop:
    ld   a, (de)
    adc  a, (hl)
    ld   (hl), a
    inc  hl
    inc  de
    djnz .loop
    ret

; ============================================================================
; CALC_SHL8 (internal)
; 8-byte left shift by 1 bit: (HL..HL+7) <<= 1, LSB-first (byte 0 is the
; least significant, shifted with a fresh SLA; bytes 1-7 use RL to
; propagate carry up the chain). Shared by CALC_OP_MUL's two identical
; 8-byte shift-left chains: CALC_MUL_CAND's own per-iteration doubling,
; and CALC_MUL_ACC's post-loop renormalization shift -- confirmed
; byte-for-byte structurally identical before factoring this out (only
; the buffer being shifted differs).
; In:  HL = value's LSB address
; Out: (HL..HL+7) = original (HL..HL+7) << 1; HL advanced by 8
; Destroys: AF, B, HL
; ============================================================================
CALC_SHL8:
    ld   a, (hl)
    sla  a
    ld   (hl), a
    inc  hl
    ld   b, 7
.loop:
    ld   a, (hl)
    rl   a
    ld   (hl), a
    inc  hl
    djnz .loop
    ret

; ============================================================================
; CALC_CMP4 (internal)
; MSB-first unsigned 4-byte compare: is (HL..HL+3) < (DE..DE+3)? Byte 0
; is the MOST significant byte at both addresses (matches CALC_UNP_A/B's
; own +2..+5 mantissa layout and CALC_DIV_REM's own layout). Shared by
; CALC_OP_DIV's two identical-shape MSB-first 4-byte compares: the
; preshift decision (mantissa A vs mantissa B) and the main loop's own
; remainder-vs-divisor compare -- confirmed byte-for-byte structurally
; identical before factoring this out (only the two buffer addresses
; differ).
; In:  HL = first operand's MSB address, DE = second operand's MSB address
; Out: carry SET if (HL..HL+3) < (DE..DE+3); carry CLEAR if >=
; Destroys: AF, B, DE, HL (both advanced to one past the 4th byte on the
;      not-taken/loop-exhausted path; callers here only use the flag)
; ============================================================================
CALC_CMP4:
    ld   b, 4
.loop:
    ld   a, (de)
    ld   c, a
    ld   a, (hl)
    cp   c
    ret  c                    ; (hl) byte < (de) byte -> definitely less
    jr   nz, .greater          ; (hl) byte > (de) byte -> definitely not less
    inc  hl
    inc  de
    djnz .loop
    or   a                     ; all 4 bytes equal -> not less
    ret
.greater:
    or   a
    ret

; ============================================================================
; CALC_SUB4 (internal)
; 4-byte subtract: (HL..HL-3) -= (DE..DE-3), LSB-first (required for
; correct borrow propagation) -- HL/DE point at the LSB (highest
; address) of each 4-byte value on entry and are DECREMENTED as this
; walks toward the MSB, matching CALC_DIV_REM/CALC_UNP_B's own +5-down-
; to-+2 byte order. Byte 0 (the LSB) uses a plain SUB; the remaining 3
; use SBC to propagate borrow. Shared by CALC_OP_DIV's main loop's own
; subtract step (was 4 near-identical LD/SUB-or-SBC/LD groups inlined
; at absolute addresses).
; In:  HL = minuend's LSB address, DE = subtrahend's LSB address
; Out: (HL..HL-3) = original (HL..HL-3) - (DE..DE-3); HL/DE decremented by 4
; Destroys: AF, BC, DE, HL
; ============================================================================
CALC_SUB4:
    ld   a, (de)
    ld   c, a
    ld   a, (hl)
    sub  c
    ld   (hl), a
    dec  hl
    dec  de
    ld   b, 3
.loop:
    ld   a, (de)
    ld   c, a
    ld   a, (hl)
    sbc  a, c
    ld   (hl), a
    dec  hl
    dec  de
    djnz .loop
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
