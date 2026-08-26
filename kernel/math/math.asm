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
; Unsigned 16x16->16 multiply via shift-and-add (Z80 has no hardware
; multiply). Verified via Python simulation against many values before
; being trusted — see this file's header.
; In:  DE = multiplicand, BC = multiplier
; Out: HL = product (truncated to 16 bits)
; Destroys: AF, BC, DE
; ============================================================================
MATH_UMUL16:
    ld   hl, 0
    ld   a, 16
.loop:
    push af
    srl  b                  ; shift BC right by 1; bit0 of B goes into
    rr   c                    ; carry, then into bit7 of C via rr — the
                             ; carry OUT of rr c is BC's original bit0
    jr   nc, .no_add
    add  hl, de                ; result += multiplicand
.no_add:
    sla  e                       ; shift DE (multiplicand) left by 1,
    rl   d                         ; making room for the next bit position
    pop  af
    dec  a
    jr   nz, .loop
    ret

; ============================================================================
; MATH_UDIV16
; Unsigned 16-bit divide via 16-iteration shift-and-subtract (restoring
; division) — generalizes basic/'s own DIV10 to an arbitrary runtime
; divisor rather than a fixed constant. DIV10 could use B/DJNZ for its
; loop counter since 10 never needed a register; here BC is needed for
; the divisor throughout all 16 iterations, so the counter lives in
; memory (DIV_COUNTER) instead. Verified via Python simulation against
; 16,165 dividend/divisor combinations before being trusted — see this
; file's header.
; In:  HL = dividend, BC = divisor
; Out: HL = quotient, DE = remainder; if BC = 0 (divide by zero), HL =
;      DE = 0 rather than the nonsense all-1s quotient the algorithm
;      would otherwise produce — checked explicitly up front
; Destroys: AF
; ============================================================================
MATH_UDIV16:
    ld   a, b
    or   c
    jr   nz, .divisor_ok
    ld   hl, 0                     ; divide by zero — safe default,
    ld   de, 0                       ; see this file's header
    ret
.divisor_ok:
    ld   (DIV_DIVIDEND), hl
    ld   hl, 0
    ld   (DIV_QUOT), hl
    ld   de, 0
    ld   a, 16
    ld   (DIV_COUNTER), a

.loop:
    ld   hl, (DIV_DIVIDEND)
    add  hl, hl                    ; shift dividend left; carry = old bit15
    ld   (DIV_DIVIDEND), hl

    rl   e                          ; shift that bit into the remainder
    rl   d

    ld   hl, (DIV_QUOT)
    add  hl, hl                      ; shift the quotient-in-progress
    ld   (DIV_QUOT), hl                ; left too, making room for this
                                      ; iteration's bit

    push de                            ; copy the remainder into HL for
    pop  hl                              ; the comparison below, without
                                        ; destroying DE (push/pop copies,
                                        ; unlike EX DE,HL which swaps)
    or   a
    sbc  hl, bc                          ; HL = remainder - divisor;
                                        ; carry set if remainder < divisor
    jr   c, .no_sub

    ; remainder >= divisor: commit the subtraction and set this bit
    ex   de, hl                            ; DE = new remainder (HL held
                                          ; remainder-divisor); HL = old
                                          ; DE, unused from here
    ld   hl, (DIV_QUOT)
    inc  hl                                  ; set the quotient's LSB —
                                            ; safe because the shift
                                            ; above guarantees bit0 is
                                            ; currently 0, same reasoning
                                            ; as DIV10's own "inc hl is
                                            ; safe" comment
    ld   (DIV_QUOT), hl

.no_sub:
    ld   a, (DIV_COUNTER)
    dec  a
    ld   (DIV_COUNTER), a
    jr   nz, .loop

    ld   hl, (DIV_QUOT)
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
MATH_MULTIPLY16:
    ld   a, h
    xor  d
    and  %10000000                 ; isolate just the sign bit of the
    ld   (MATH_SIGN), a              ; XOR — that's the result's sign
                                    ; (0 = positive, $80 = negative)

    call MATH_ABS16                   ; take absolute value of HL

    ex   de, hl                      ; take absolute value of DE (via
    call MATH_ABS16                    ; HL, swapped in/out — HL's own
    ex   de, hl                        ; value survives the round trip)

    ld   b, d                        ; BC = abs(multiplier), for
    ld   c, e                          ; MATH_UMUL16's contract
    ex   de, hl                          ; DE = abs(multiplicand), HL =
                                        ; old DE (unused from here)
    call MATH_UMUL16                      ; HL = unsigned product

    ld   a, (MATH_SIGN)
    or   a
    ret  z                              ; positive result, HL already
                                        ; correct

    jr   MATH_NEGATE16                   ; negate HL (two's complement)
                                        ; and return directly

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
    ld   a, h
    xor  d
    and  %10000000
    ld   (MATH_SIGN), a

    call MATH_ABS16                   ; take absolute value of HL
                                      ; (dividend)

    ex   de, hl                      ; take absolute value of DE
    call MATH_ABS16                    ; (divisor) via HL, swapped
    ex   de, hl                        ; in/out

    ld   b, d                        ; BC = abs(divisor), for
    ld   c, e                          ; MATH_UDIV16's contract
    call MATH_UDIV16                     ; HL = abs(dividend)/abs(divisor)
                                        ; (dividend, abs(HL), was already
                                        ; in HL from the steps above)

    ld   a, (MATH_SIGN)
    or   a
    ret  z                              ; positive result, HL already
                                        ; correct

    jr   MATH_NEGATE16                   ; negate HL and return directly

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

    ld   a, (MATH_SIGN)
    or   a
    ret  z                              ; dividend was non-negative
                                        ; (or divisor was 0, giving
                                        ; remainder 0 either way) — HL
                                        ; already correct

    jr   MATH_NEGATE16                   ; negate HL (apply the
                                        ; dividend's sign) and return

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
; Generator: a 16-bit maximal-length Galois-tap-free "Fibonacci form"
; LFSR (feedback = XOR of bit positions 1,2,4,13 of the current state;
; new state = state shifted right 1, with that feedback bit inserted
; at bit 15). Exhaustively verified in Python before any Z80: the taps
; used here were found by a systematic search over candidate tap sets
; (rather than trusting an unverified "standard" constant from memory
; — an earlier attempt using a commonly-cited tap mask, applied as a
; single-mask Galois-style feedback, turned out to have only a
; 73-state cycle, not the full 65,535; a second attempt using several
; textbook-cited Fibonacci tap sets hit the degenerate all-zero state
; entirely, because none of them included tap position 1 — required
; for the transition to be invertible and avoid the zero-trap). The
; tap set actually used here (positions 1,2,4,13) was verified by
; direct simulation to visit all 65,535 nonzero 16-bit states exactly
; once before returning to its start — genuinely maximal length, not
; assumed. The exact register-level bit-extraction sequence below
; (shift-and-mask each tap bit individually, XOR-fold them, then a
; real 16-bit logical shift with a conditional bit-15 set) was then
; separately checked against the reference recurrence for all 65,536
; possible states — zero mismatches — to catch any transcription
; error between the verified design and this Z80 form.
;
; RND_STATE (a persistent sysvar, not a register — must survive
; between separate BASIC statements) is never 0: a maximal-length LFSR
; treats 0 as a degenerate fixed point that never advances. MEM_INIT
; zeroes all of RAM at cold start, so RND_STATE reading as 0 doubles
; as "never seeded yet" — the first RND(x) call seeds it from the Z80
; R register (the classic, well-established technique for this: R
; increments on every instruction fetch, so its value at the moment of
; the call depends on how many instructions have executed since reset
; — genuinely unpredictable from a BASIC program's perspective, though
; NOT cryptographically random) OR'd with 1 to guarantee it isn't 0
; itself. This seeding step is hardware-timing-dependent and can't be
; meaningfully verified by tools/z80sim (which has no real timing
; model — same category of gap as the tape-signal primitives in
; kernel/storage); only the deterministic LFSR step and the range-
; scaling below it were verified there.
;
; Range-scaling: the raw 16-bit LFSR state, with its sign bit masked
; off (0-32767, since the sign bit is just ordinary LFSR noise, not
; meaningful), is fed as the dividend to this file's own MATH_MOD16 —
; already-verified, and safe here since both operands are guaranteed
; non-negative (the mask above; x's own sign already checked before
; this point), so MOD16's dividend-sign handling never triggers.
; In:  HL = x (signed; x<=0 returns 0)
; Out: HL = pseudo-random value in [0, x-1] (or 0 if x<=0)
; Destroys: AF, BC, DE, HL
; ============================================================================
MATH_RND16:
    ld   a, h
    or   a
    jp   m, .zero_result                ; x negative -> 0
    ld   a, h
    or   l
    jr   z, .zero_result                  ; x = 0 -> 0

    push hl                                ; save x across the LFSR
                                          ; step below (no calls happen
                                          ; before the matching pop, so
                                          ; this is a simple balanced
                                          ; save — not the recursive-
                                          ; call-survival case the rest
                                          ; of this project usually
                                          ; means by this comment)

    ld   hl, (RND_STATE)
    ld   a, h
    or   l
    jr   nz, .seeded

    ; never seeded (still 0, from MEM_INIT's cold-start zeroing) —
    ; seed from the R register, guaranteed nonzero via OR 1
    ld   a, r
    or   1
    ld   l, a
    ld   a, r                              ; a second read for the high
    ld   h, a                                ; byte too, for more spread
                                            ; than R's own 128-value
                                            ; cycle alone would give
.seeded:
    ; feedback = bit0(L) ^ bit1(L) ^ bit3(L) ^ bit12(H's bit4)
    ld   a, l
    and  1
    ld   b, a

    ld   a, l
    srl  a
    and  1
    xor  b
    ld   b, a

    ld   a, l
    srl  a
    srl  a
    srl  a
    and  1
    xor  b
    ld   b, a

    ld   a, h
    srl  a
    srl  a
    srl  a
    srl  a
    and  1
    xor  b                                 ; A = feedback bit (0 or 1)
    ld   c, a                                ; stash it — B is about to
                                            ; be overwritten by the
                                            ; actual state shift below

    srl  h                                   ; HL >>= 1 (logical;
    rr   l                                     ; discards old bit0)

    ld   a, c
    or   a
    jr   z, .no_set_bit
    ld   a, h
    or   $80                                 ; set bit 15 (the
    ld   h, a                                  ; feedback bit)
.no_set_bit:
    ld   (RND_STATE), hl                     ; commit the new state

    ld   a, h
    and  $7F                                 ; mask off the sign bit —
    ld   h, a                                  ; it's just ordinary LFSR
                                              ; noise, not meaningful;
                                              ; guarantees a non-
                                              ; negative dividend below

    pop  de                                    ; DE = x (saved earlier)
    call MATH_MOD16                              ; HL MOD DE — both
                                                ; operands non-negative
                                                ; here, so this is a
                                                ; plain modulo, MOD16's
                                                ; dividend-sign handling
                                                ; never triggers
    ret

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
MATH_RND_SEED:
    ld   (RND_STATE), hl
    ret

    ENDIF
