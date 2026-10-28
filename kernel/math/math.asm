; ============================================================================
; kernel/math/math.asm — general-purpose 16-bit integer arithmetic
;
; CURRENT STATUS: assembled into the working ROM and exercised under
; Fuse by the automated math and language regression tests. Both
; foundational algorithms were also verified via a
; Python simulation mirroring the exact planned Z80 register steps —
; MATH_UMUL16 against 32,720 signed multiply cases (as its signed
; wrapper) and MATH_UDIV16 against 16,165 unsigned divide/remainder
; cases, all with zero failures — before any assembly was written,
; matching this project's established discipline for tricky arithmetic
; (the screen address formula, the ink/paper bit-swap, DIV10 itself).
; That verifies the ALGORITHMS; it doesn't substitute for running the
; actual assembled-code coverage now complements that algorithm check.
;
; Owns: multiply and divide, which Z80 has no hardware instructions
; for. Built specifically to support basic/'s expression evaluator,
; but deliberately kept general-purpose and free of any BASIC-specific
; assumptions — this project's own stated principle is that kernel
; modules should be reusable by other future assembly-language
; software, and 16-bit multiply/divide is exactly that kind of
; genuinely generic building block, not something that belongs buried
; inside basic/basic.asm.
;
; basic/'s own DIV10 (division by 10 specifically, for decimal-to-
; string conversion) stays where it is, unchanged — it's a different,
; narrower routine (fixed divisor, combined quotient+remainder output
; tuned for repeated-digit-extraction) serving a different purpose,
; not something this module's MATH_UDIV16 replaces.
;
; Result on overflow: both multiply and divide simply truncate to 16
; bits, matching how this project's other integer arithmetic already
; behaves (BASIC_NUM_TO_STRING, DIV10) — no overflow flag or error
; signal, consistent with there being no error-reporting mechanism
; anywhere else in this codebase yet either.
;
; Divide by zero: MATH_DIVIDE16 returns 0 rather than the nonsense
; result MATH_UDIV16 would otherwise produce (a divisor of 0 means
; "remainder >= divisor" is trivially true every iteration, giving a
; quotient of all 1-bits, i.e. -1) — a deliberate, safe default given
; there's no error-reporting mechanism to surface a real error through
; yet, not an oversight.
; ============================================================================

    IFNDEF MATH_ASM
    DEFINE MATH_ASM

    INCLUDE "include/sysvars.inc"

; ============================================================================
; MATH_UMUL16
; Unsigned 16x16->16 multiply, shift-and-add from the multiplier's top
; bit (HL = HL * 2 (+ DE) per bit), registers only. 2068-Leap-C's RT_UMUL
; (back-port plan item 1.5), replacing a version that pushed and popped
; its counter every step; checked against Python on corpus-scale random
; and edge pairs by tools/qual/qmuldiv.py.
; In:  DE = multiplicand, BC = multiplier
; Out: HL = product (truncated to 16 bits)
; Destroys: AF, BC (DE kept, which the old contract did not promise)
; ============================================================================
MATH_UMUL16:
    ld   hl, 0
    ld   a, 16
.loop:
    add  hl, hl
    rl   c
    rl   b
    jr   nc, .no_add
    add  hl, de
.no_add:
    dec  a
    jr   nz, .loop
    ret

; ============================================================================
; MATH_UDIV16
; Unsigned 16-bit restoring division, 16 steps, registers only: HL holds
; the dividend shifting out at the top while the quotient shifts in at
; the bottom; DE is the remainder. 2068-Leap-C's RT_UDIV (back-port plan
; item 1.5), replacing a version that kept the dividend, quotient and
; counter in memory (DIV_DIVIDEND, DIV_QUOT, DIV_COUNTER, now unused):
; 60000/7 3,584 T -> 1,479 T (measured in Leap-C). No 17th remainder bit
; is needed: before step i the remainder is below 2^(i-1).
; In:  HL = dividend, BC = divisor
; Out: HL = quotient, DE = remainder; HL = DE = 0 if BC = 0 (divide by
;      zero, see this file's header)
; Destroys: AF (BC kept)
; ============================================================================
MATH_UDIV16:
    ld   a, b
    or   c
    jr   nz, .divisor_ok
    ld   h, a
    ld   l, a
    ld   d, a
    ld   e, a
    ret
.divisor_ok:
    ld   de, 0
    ld   a, 16
.loop:
    add  hl, hl
    ex   de, hl
    adc  hl, hl                         ; remainder * 2 + the dividend's next bit
    sbc  hl, bc                         ; (carry is clear: adc cannot overflow, see above)
    jr   nc, .one
    add  hl, bc                         ; restore
    jr   .next
.one:
    inc  e                              ; the quotient's bit (DE is the dividend/quotient here)
.next:
    ex   de, hl
    dec  a
    jr   nz, .loop
    ret

; ============================================================================
; MATH_MULTIPLY16
; Signed wrapper around MATH_UMUL16: determines the result's sign
; (negative iff exactly one operand is negative — the XOR of their
; sign bits), takes absolute values, multiplies unsigned, then applies
; the sign to the result. Verified via Python simulation against
; 32,720 signed value pairs (including -32768, 32767, 0, and many
; negative/positive combinations) before being trusted.
; In:  HL = multiplicand (signed), DE = multiplier (signed)
; Out: HL = product (signed, truncated to 16 bits)
; Destroys: AF, BC, DE
; ============================================================================
; ============================================================================
; MATH_SIGN_PREP (internal)
; Shared prologue for MATH_MULTIPLY16/MATH_DIVIDE16: both operands'
; sign-then-magnitude split is byte-identical between the two (XOR of
; both operands' sign bits into MATH_SIGN, then absolute-value both) —
; confirmed before factoring this out. MATH_MOD16 does NOT share this
; (it isolates only the dividend's sign, not an XOR of both — see that
; routine's own header), only the epilogue below.
; In:  HL, DE (signed operands)
; Out: HL = abs(HL), DE = abs(DE), MATH_SIGN = XOR of both original
;      sign bits (0 = positive result, $80 = negative)
; Destroys: AF
; ============================================================================
MATH_SIGN_PREP:
    ld   a, h
    xor  d
    and  %10000000                 ; isolate just the sign bit of the
    ld   (MATH_SIGN), a              ; XOR — that's the result's sign
                                    ; (0 = positive, $80 = negative)

    call MATH_ABS16                   ; take absolute value of HL

    ex   de, hl                      ; take absolute value of DE (via
    call MATH_ABS16                    ; HL, swapped in/out — HL's own
    ex   de, hl                        ; value survives the round trip)
    ret

; ============================================================================
; MATH_APPLY_SIGN (internal)
; Shared epilogue for MATH_MULTIPLY16/MATH_DIVIDE16/MATH_MOD16: apply
; whatever sign was staged in MATH_SIGN to the unsigned-magnitude
; result already in HL. Byte-identical across all three callers before
; factoring this out.
; In:  HL = unsigned magnitude result, MATH_SIGN set by the caller
; Out: HL = signed result (negated iff MATH_SIGN was $80)
; Destroys: AF
; ============================================================================
MATH_APPLY_SIGN:
    ld   a, (MATH_SIGN)
    or   a
    ret  z                              ; positive result, HL already
                                        ; correct
    jr   MATH_NEGATE16                   ; negate HL (two's complement)
                                        ; and return directly

MATH_MULTIPLY16:
    call MATH_SIGN_PREP

    ld   b, d                        ; BC = abs(multiplier), for
    ld   c, e                          ; MATH_UMUL16's contract
    ex   de, hl                          ; DE = abs(multiplicand), HL =
                                        ; old DE (unused from here)
    call MATH_UMUL16                      ; HL = unsigned product

    jr   MATH_APPLY_SIGN

; ============================================================================
; MATH_DIVIDE16
; Signed wrapper around MATH_UDIV16, same sign-then-magnitude approach
; as MATH_MULTIPLY16. Truncates toward zero (matching typical integer
; BASIC division — e.g. -7/2 = -3, not -4), since the underlying
; unsigned division works on absolute values and the sign is applied
; to the truncated magnitude afterward. Verified via the same Python
; simulation as MATH_MULTIPLY16, 32,720 cases, zero failures.
; In:  HL = dividend (signed), DE = divisor (signed)
; Out: HL = quotient (signed, truncated toward zero); HL = 0 if DE = 0
;      (divide by zero — see this file's header)
; Destroys: AF, BC, DE
; ============================================================================
MATH_DIVIDE16:
    call MATH_SIGN_PREP

    ld   b, d                        ; BC = abs(divisor), for
    ld   c, e                          ; MATH_UDIV16's contract
    call MATH_UDIV16                     ; HL = abs(dividend)/abs(divisor)
                                        ; (dividend, abs(HL), was already
                                        ; in HL from the steps above)

    jr   MATH_APPLY_SIGN

; ============================================================================
; MATH_COMPARE16
; Signed 16-bit comparison, built specifically to support basic/'s new
; IF/ELSEIF relational operators (=, <>, <, >, <=, >=) but kept as
; general-purpose as MATH_MULTIPLY16/DIVIDE16 — no BASIC-specific
; assumptions here either.
;
; Z80 has no signed-comparison instruction, only SBC HL,DE (an
; unsigned-magnitude subtract that still sets the P/V flag as a
; signed-overflow indicator). The standard technique: after "OR A" /
; "SBC HL,DE", the result's sign flag tells you HL-DE's true sign
; UNLESS a signed overflow occurred (P/V set), in which case the sign
; flag is backwards and must be inverted. Overflow only happens when
; HL and DE have different signs and the subtraction result's sign
; matches HL's own original sign the "wrong" way — verified via a
; Python simulation of this exact flag logic (sign-of-HL, sign-of-DE,
; sign-of-result, overflow-if-signs-differ-and-result-doesn't-match)
; against all pairs from a set of edge values (0, ±1, ±5, ±32767,
; ±32768) plus 200,000 random signed pairs, zero failures, before any
; Z80 was written — same discipline as this file's multiply/divide.
; In:  HL = left operand (signed), DE = right operand (signed)
; Out: A = 0 if HL = DE, 1 if HL > DE, $FF if HL < DE
; Destroys: AF, HL (DE is only read, never written, by SBC HL,DE)
; ============================================================================
MATH_COMPARE16:
    or   a
    sbc  hl, de
    jr   z, .equal
    jp   po, .no_overflow           ; P/V clear (parity odd) = no signed
                                    ; overflow — the sign flag already
                                    ; tells the truth
    jp   m, .greater                 ; overflow occurred: sign flag is
                                     ; backwards, so a "negative" result
                                     ; here actually means HL > DE
    jr   .less
.no_overflow:
    jp   m, .less
    jr   .greater
.equal:
    xor  a
    ret
.less:
    ld   a, $FF
    ret
.greater:
    ld   a, 1
    ret

; ============================================================================
; MATH_ADD16 / MATH_SUB16 / MATH_NEGATE16 / MATH_ABS16 / MATH_SGN16
;
; Formalizes arithmetic that basic/'s evaluator (and any future caller)
; was previously doing as bare inline `ADD HL,DE` / `SBC HL,DE` /
; hand-rolled two's-complement negation wherever it came up — no
; behavior change from what already existed ad hoc, just a single
; documented call site instead of the same few instructions retyped
; in multiple places (same duplication concern that motivated the
; KEYWORD_HILITE_TABLE unification).
;
; All five verified via Python simulation (50,011 values: every edge
; case — 0, +-1, +-32767, -32768 — plus 50,000 random signed 16-bit
; values, each ADD/SUB sampled against 3 partners) before any Z80 was
; written, same discipline as this file's multiply/divide/compare.
; Truncates on overflow, same as MATH_MULTIPLY16/MATH_DIVIDE16 — no
; overflow flag, consistent with there being no error-reporting
; mechanism at this layer.
;
; The one genuine edge case: NEGATE16(-32768) and ABS16(-32768) both
; return -32768 unchanged, NOT 32768 — the positive equivalent has no
; representation in signed 16-bit two's complement, so the value
; silently doesn't change sign at that single boundary. Confirmed via
; the same Python simulation, not just reasoned about; matches the
; well-known behavior of two's-complement negation everywhere else
; (Z80, x86, etc.), not a bug specific to this implementation.
; ============================================================================

; ----------------------------------------------------------------------
; MATH_ADD16
; In:  HL, DE
; Out: HL = HL + DE (truncated to 16 bits)
; Destroys: AF
; ----------------------------------------------------------------------
    IFNDEF V2_PRODUCTION          ; RC: only rom/test_math.asm calls MATH_ADD16 / MATH_SUB16
MATH_ADD16:
    add  hl, de
    ret

; ----------------------------------------------------------------------
; MATH_SUB16
; In:  HL, DE
; Out: HL = HL - DE (truncated to 16 bits)
; Destroys: AF
; ----------------------------------------------------------------------
MATH_SUB16:
    or   a
    sbc  hl, de
    ret
    ENDIF

; ----------------------------------------------------------------------
; MATH_NEGATE16
; Two's-complement negate. Same pattern already used inline inside
; MATH_MULTIPLY16/MATH_DIVIDE16's own sign-then-magnitude steps above
; — pulled out here as its own documented, reusable routine rather
; than staying duplicated three times over (those two callers are
; NOT changed to call this — see this routine's own note below).
; In:  HL
; Out: HL = -HL (truncated; -32768 stays -32768 — see file header)
; Destroys: AF
; ----------------------------------------------------------------------
MATH_NEGATE16:
    xor  a
    sub  l
    ld   l, a
    ld   a, 0
    sbc  a, h
    ld   h, a
    ret

; ----------------------------------------------------------------------
; MATH_ABS16
; In:  HL
; Out: HL = absolute value of HL (truncated; ABS(-32768) = -32768 —
;      see file header)
; Destroys: AF
; ----------------------------------------------------------------------
MATH_ABS16:
    ld   a, h
    or   a
    ret  p                  ; sign bit clear (positive or zero) —
                            ; already correct, nothing to do
    jr   MATH_NEGATE16       ; tail-call: negate and return directly
                            ; from there

; ----------------------------------------------------------------------
; MATH_SGN16
; In:  HL
; Out: HL = -1 if HL < 0, 0 if HL = 0, 1 if HL > 0
; Destroys: AF
; ----------------------------------------------------------------------
MATH_SGN16:
    ld   a, h
    or   l
    jr   z, .zero
    ld   a, h
    or   a
    jp   p, .positive
    ld   hl, -1
    ret
.positive:
    ld   hl, 1
    ret
.zero:
    ld   hl, 0
    ret

; ============================================================================
; MATH_MOD16
; Signed 16-bit remainder, matching MATH_DIVIDE16's own truncating-
; toward-zero convention: the remainder takes the DIVIDEND's sign (or
; 0), not the divisor's — e.g. -17 MOD 5 = -2, not 3 (a flooring-
; division language like Python's bare % would give 3; this matches
; C's %, and this project's own -17/5=-3 truncating quotient: -3*5 +
; (-2) = -17, consistent). Unlike MATH_MULTIPLY16/DIVIDE16's dual-
; operand XOR-of-signs, only the dividend's sign matters here — the
; divisor's sign doesn't flip the remainder's sign, only its magnitude
; range (|remainder| < |divisor|, verified below).
;
; Genuinely cheap to add: MATH_UDIV16 already computes the unsigned
; remainder internally (in DE) as a side effect of computing the
; quotient — this wrapper reuses that instead of a second division
; pass, following the same sign-then-magnitude shape as MATH_DIVIDE16
; but reading DE (remainder) instead of HL (quotient) out of
; MATH_UDIV16's result.
;
; Verified via Python simulation before any Z80 was written: 6,048
; cases (edge values -32768/32767/0/±1 plus 2,000 random dividends,
; each checked against 3 random divisors) confirming a = q*b + r,
; |r| < |b|, and r's sign matches the dividend's (or is 0) — plus 10
; concrete hand-checkable cases (17 MOD 5 = 2, -17 MOD 5 = -2, the
; -32768 boundary, etc.), zero failures.
; In:  HL = dividend (signed), DE = divisor (signed)
; Out: HL = remainder (signed; sign matches the dividend, or 0); HL = 0
;      if DE = 0 (matches MATH_DIVIDE16's own divide-by-zero default —
;      see kernel/math/math.asm's file header)
; Destroys: AF, BC, DE, HL
; ============================================================================
MATH_MOD16:
    ld   a, h
    and  %10000000                 ; isolate just the DIVIDEND's sign
    ld   (MATH_SIGN), a              ; bit — unlike MULTIPLY16/DIVIDE16,
                                    ; this is not XORed with the
                                    ; divisor's sign; see this
                                    ; routine's own header

    call MATH_ABS16                   ; take absolute value of HL
                                      ; (dividend)

    ex   de, hl                      ; take absolute value of DE
    call MATH_ABS16                    ; (divisor) via HL, swapped
    ex   de, hl                        ; in/out

    ld   b, d                        ; BC = abs(divisor), for
    ld   c, e                          ; MATH_UDIV16's contract
    call MATH_UDIV16                     ; DE = unsigned remainder
                                        ; (HL = quotient, unused here)
    ex   de, hl                          ; HL = remainder magnitude

    jr   MATH_APPLY_SIGN                 ; apply the dividend's sign
                                        ; (or leaves it positive if
                                        ; divisor was 0, remainder 0
                                        ; either way)

; ============================================================================
; MATH_SQRT16
; Signed 16-bit integer square root, truncating (SQRT16(n) is the
; largest R such that R*R <= n — e.g. SQRT16(15)=3, SQRT16(16)=4).
; Negative input is treated as 0 — no error-reporting mechanism exists
; at this layer, matching this file's own established safe-default
; convention (see MATH_DIVIDE16's own divide-by-zero handling in this
; file's header) — and matching every OTHER routine in kernel/math
; being signed (basic/'s values are all signed 16-bit integers; there
; is no unsigned type at the BASIC level), rather than making this the
; one unsigned exception.
;
; Classic "digit by digit" binary integer square root (see e.g.
; Wikipedia's algorithm of the same name) — the same iterative
; shift/compare/subtract shape as this file's own MATH_UDIV16, just
; extracting result bits 2 input-bits at a time instead of 1. Uses a
; FIXED 8-iteration loop starting from `one=$4000` rather than the
; textbook version's own variable-length leading "shrink `one` until
; it's <= input" loop — Python-verified to be exactly equivalent
; (early iterations naturally contribute nothing when the input is
; small, instead of being skipped), and a fixed trip count is
; considerably simpler to implement as a Z80 loop.
;
; Verified via Python simulation before any Z80 was written, in two
; passes: first the core shift/compare/subtract algorithm alone
; against Python's own math.isqrt for all 65,536 possible UNSIGNED
; 16-bit magnitudes (zero mismatches) — this caught nothing, but did
; NOT by itself verify the actual routine's real behavior, since it
; didn't yet include the negative-input handling below. Combining the
; negative check with the core algorithm and re-verifying the ACTUAL
; end-to-end design against all 65,536 SIGNED 16-bit inputs (negative
; -> 0 expected, non-negative -> its own square root expected) is what
; this routine's real contract needs — done, zero mismatches. (An
; earlier version of this routine's own header claimed the SIGNED
; input was "unsigned," which very nearly shipped as a real, wrong
; sign-check — caught only because tools/z80sim's own broad random
; sample happened to include values with bit 15 set and flagged 243
; failures immediately; see this file's own established practice of
; verifying the ACTUAL combined behavior, not just the core algorithm
; in isolation.) Also checked the largest intermediate values the
; algorithm reaches (max 20,480 for `res+one`, max 65,535 for the
; shrinking working copy) to confirm they fit a 16-bit register.
;
; Uses SQRT_OP/SQRT_RES/SQRT_COUNTER scratch (kernel/math's own, same
; "needs a copy in HL for the compare, but HL is also busy with other
; work that same iteration" reasoning as MATH_UDIV16's own DIV_
; DIVIDEND/DIV_QUOT/DIV_COUNTER right above — see those sysvars' own
; header in include/sysvars.inc). `one` stays in BC the whole loop, so
; the usual DJNZ-in-B trick isn't available for the loop counter,
; hence SQRT_COUNTER instead.
; In:  HL = n (signed; negative treated as 0 — see this header)
; Out: HL = the integer square root of n
; Destroys: AF, BC, DE, HL
; ============================================================================
MATH_SQRT16:
    ld   a, h                        ; negative (as signed) — treat
    or   a                             ; as 0, no error signal at this
    jp   p, .nonneg                      ; layer (see this routine's
    ld   hl, 0                             ; own header) — same sign-
    ret                                     ; check idiom as MATH_ABS16
                                          ; above, not BIT (kept
                                          ; consistent with the rest of
                                          ; this file's style)
.nonneg:
    ld   (SQRT_OP), hl
    ld   hl, 0
    ld   (SQRT_RES), hl
    ld   bc, $4000                     ; 'one' — the highest even
                                      ; power of 4 that fits a 16-bit
                                      ; input (4^7 = 16384)
    ld   a, 8
    ld   (SQRT_COUNTER), a

.loop:
    ld   hl, (SQRT_RES)
    add  hl, bc                        ; HL = candidate = res + one
    ex   de, hl                          ; DE = candidate
    ld   hl, (SQRT_OP)                    ; HL = op
    or   a
    sbc  hl, de                            ; HL = op - candidate;
                                          ; carry set if op < candidate
    jr   c, .no_update                      ; op < candidate — this
                                            ; iteration contributes
                                            ; nothing

    ; op >= candidate: commit the subtraction (HL already holds the
    ; correct new op from the SBC above — no need to recompute it) and
    ; add 2*one to res
    ld   (SQRT_OP), hl
    ld   hl, (SQRT_RES)
    add  hl, bc
    add  hl, bc
    ld   (SQRT_RES), hl

.no_update:
    ld   hl, (SQRT_RES)                    ; res >>= 1
    srl  h
    rr   l
    ld   (SQRT_RES), hl

    srl  b                                   ; one >>= 2
    rr   c
    srl  b
    rr   c

    ld   a, (SQRT_COUNTER)
    dec  a
    ld   (SQRT_COUNTER), a
    jr   nz, .loop

    ld   hl, (SQRT_RES)
    ret

; ============================================================================
; MATH_RND16
; Pseudo-random integer in [0, x-1] for a positive x (matches the
; common BASIC RND(n) convention of "n possible results, 0 to n-1").
; x<=0 (signed) returns 0 — no error mechanism at this layer, same
; safe-default convention as MATH_DIVIDE16's divide-by-zero.
;
; Generator: a 16-bit xorshift, HL ^= HL << 7; HL ^= HL >> 9; HL ^= HL << 8
; (back-port plan item 1.2, the generator of 2068-Leap-C's rand()), period
; 65,535 over the nonzero states. It replaced a one-bit Fibonacci LFSR step,
; whose consecutive states were each the previous one shifted right by one
; bit: consecutive RND results were strongly correlated (from state 1 the
; states ran $8000, $4000, $2000 and RANDOMISE 7 then RND(6) gave 3, 1, 0).
; Checked on the real routine under
; ZEsarUX by tools/qual/qrnd.py: the full 65,535 period from state 1, and
; the first 255 states and results against the reference recurrence.
;
; RND_STATE (a persistent sysvar) is never 0 after a step: 0 is xorshift's
; fixed point. MEM_INIT zeroes it at cold start, and RANDOMISE 0 sets it to
; 0, so 0 means "never seeded yet": the next RND(x) seeds from the Z80 R
; register (it increments on every instruction fetch, so its value depends
; on how many instructions have run since reset; not cryptographically
; random), the low byte OR'd with 1 so the seed is not 0.
;
; Range-scaling: the new state with its top bit cleared (0-32767) is the
; dividend of this file's MATH_MOD16; both operands are non-negative (x's
; sign is checked first), so MOD16's dividend-sign handling never triggers.
; In:  HL = x (signed; x<=0 returns 0)
; Out: HL = pseudo-random value in [0, x-1] (or 0 if x<=0)
; Destroys: AF, BC, DE, HL
; ============================================================================
MATH_RND16:
    ld   a, h
    or   a
    jp   m, .zero_result                ; x negative -> 0
    or   l
    jr   z, .zero_result                ; x = 0 -> 0
    push hl                             ; x, for the MOD below
    ld   hl, (RND_STATE)
    ld   a, h
    or   l
    jr   nz, .step
    ld   a, r                           ; never seeded: seed from R
    or   1
    ld   l, a
    ld   a, r
    ld   h, a
.step:                                  ; HL ^= HL << 7; HL ^= HL >> 9; HL ^= HL << 8
    ld   a, h
    rra
    ld   a, l
    rra
    xor  h
    ld   h, a
    ld   a, l
    rra
    ld   a, h
    rra
    xor  l
    ld   l, a
    xor  h
    ld   h, a
    ld   (RND_STATE), hl
    res  7, h                           ; 0-32767: a non-negative dividend
    pop  de                             ; DE = x
    jp   MATH_MOD16                     ; HL MOD DE (tail call)

.zero_result:
    ld   hl, 0
    ret

; ============================================================================
; MATH_RND_SEED
; Explicitly (re)seeds MATH_RND16's LFSR. HL=0 resets RND_STATE back to
; MATH_RND16's own "never seeded yet" sentinel — the cold-boot value
; MEM_INIT's zeroing already leaves it at — so the very next RND() call
; reseeds from the Z80 R register exactly as it would on a fresh boot,
; not a plain no-op (a genuine LFSR state of 0 is a degenerate fixed
; point that never advances, which is exactly why MATH_RND16 already
; special-cases it — this routine deliberately reuses that same
; special case rather than inventing a second "unseeded" convention). A
; nonzero HL becomes the new deterministic seed directly, in the exact
; state format MATH_RND16's own LFSR step advances — useful for
; reproducible "random" sequences (e.g. testing). Backs BASIC's
; RANDOMISE <n>.
; In:  HL = new seed (0 = reset to unseeded)
; Out: none
; Destroys: none
; ============================================================================
    IFNDEF V2_PRODUCTION          ; RC: production places it in the low-ROM padding (rom/v2_lowrom_fill.asm)
MATH_RND_SEED:
    ld   (RND_STATE), hl
    ret
    ENDIF

    ENDIF
