; ============================================================================
; rom/test_math.asm — kernel/math smoke test
;
; Tests MATH_MULTIPLY16, MATH_DIVIDE16, MATH_COMPARE16, and the newer
; MATH_ADD16/MATH_SUB16/MATH_NEGATE16/MATH_ABS16/MATH_SGN16 against a
; representative set of concrete cases (positive*positive,
; negative*positive, negative*negative, zero, truncating division
; toward zero, divide by zero, and each new routine's own boundary
; case) — the underlying algorithms were already verified via a Python
; simulation against tens of thousands of cases, then via tools/z80sim
; against the actual assembled instructions, before any of this file
; was written (see kernel/math/math.asm's own header); this test
; exists to confirm the ACTUAL ASSEMBLED CODE matches that verified
; design, catching any transcription error between the two rather than
; re-verifying the algorithm itself.
;
; Signal method: same as every other kernel-module test in this
; project — border goes GREEN on all tests passing, RED on the first
; failure, no automated pass/fail beyond that (this hardware has no
; other output channel available at this level).
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_math.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_math.bin --rom-ts2068-1 rom1.bin
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

    call TEST_MULTIPLY_POS_POS
    jp   c, FAIL
    call TEST_MULTIPLY_NEG_POS
    jp   c, FAIL
    call TEST_MULTIPLY_NEG_NEG
    jp   c, FAIL
    call TEST_MULTIPLY_ZERO
    jp   c, FAIL
    call TEST_MULTIPLY_BOUNDARY
    jp   c, FAIL
    call TEST_DIVIDE_POS_POS
    jp   c, FAIL
    call TEST_DIVIDE_NEG_POS_TRUNC
    jp   c, FAIL
    call TEST_DIVIDE_NEG_NEG
    jp   c, FAIL
    call TEST_DIVIDE_BY_ZERO
    jp   c, FAIL
    call TEST_COMPARE_EQUAL
    jp   c, FAIL
    call TEST_COMPARE_GREATER
    jp   c, FAIL
    call TEST_COMPARE_LESS
    jp   c, FAIL
    call TEST_COMPARE_NEG_POS
    jp   c, FAIL
    call TEST_COMPARE_BOUNDARY
    jp   c, FAIL
    call TEST_ADD_BASIC
    jp   c, FAIL
    call TEST_SUB_BASIC
    jp   c, FAIL
    call TEST_NEGATE_BOUNDARY
    jp   c, FAIL
    call TEST_ABS_POS
    jp   c, FAIL
    call TEST_ABS_NEG
    jp   c, FAIL
    call TEST_ABS_BOUNDARY
    jp   c, FAIL
    call TEST_SGN_POS
    jp   c, FAIL
    call TEST_SGN_NEG
    jp   c, FAIL
    call TEST_SGN_ZERO
    jp   c, FAIL
    call TEST_MOD_BASIC
    jp   c, FAIL
    call TEST_MOD_NEG_DIVIDEND
    jp   c, FAIL
    call TEST_MOD_NEG_DIVISOR
    jp   c, FAIL
    call TEST_MOD_BY_ZERO
    jp   c, FAIL
    call TEST_SQRT_PERFECT
    jp   c, FAIL
    call TEST_SQRT_NONPERFECT
    jp   c, FAIL
    call TEST_SQRT_ZERO
    jp   c, FAIL
    call TEST_SQRT_NEGATIVE
    jp   c, FAIL
    call TEST_SQRT_BOUNDARY
    jp   c, FAIL
    call TEST_RND_RANGE
    jp   c, FAIL
    call TEST_RND_ZERO
    jp   c, FAIL
    call TEST_RND_NEGATIVE
    jp   c, FAIL
    call TEST_RND_ONE
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $                   ; halt here — deliberate, not a bug

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; ============================================================================
; TEST_MULTIPLY_POS_POS
; 4 * 3 = 12
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MULTIPLY_POS_POS:
    ld   hl, 4
    ld   de, 3
    call MATH_MULTIPLY16
    ld   de, 12
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_MULTIPLY_NEG_POS
; -3 * 4 = -12 (hand-traced in kernel/math/math.asm's design work — see
; that file's commit history/notes — before being trusted; this
; confirms the assembled code matches)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MULTIPLY_NEG_POS:
    ld   hl, -3
    ld   de, 4
    call MATH_MULTIPLY16
    ld   de, -12
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_MULTIPLY_NEG_NEG
; -5 * -6 = 30 (both negative — result should be positive)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MULTIPLY_NEG_NEG:
    ld   hl, -5
    ld   de, -6
    call MATH_MULTIPLY16
    ld   de, 30
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_MULTIPLY_ZERO
; 0 * 100 = 0
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MULTIPLY_ZERO:
    ld   hl, 0
    ld   de, 100
    call MATH_MULTIPLY16
    ld   de, 0
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_MULTIPLY_BOUNDARY
; 32767 * 1 = 32767 (largest positive 16-bit signed value, times one —
; confirms no accidental sign-bit corruption right at the boundary)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MULTIPLY_BOUNDARY:
    ld   hl, 32767
    ld   de, 1
    call MATH_MULTIPLY16
    ld   de, 32767
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_DIVIDE_POS_POS
; 17 / 5 = 3 (truncating, discards the remainder of 2)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_DIVIDE_POS_POS:
    ld   hl, 17
    ld   de, 5
    call MATH_DIVIDE16
    ld   de, 3
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_DIVIDE_NEG_POS_TRUNC
; -17 / 5 = -3 (truncates toward zero, NOT floor division — floor
; would give -4; this confirms the sign-then-magnitude approach
; produces the truncating behavior typical integer BASIC uses)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_DIVIDE_NEG_POS_TRUNC:
    ld   hl, -17
    ld   de, 5
    call MATH_DIVIDE16
    ld   de, -3
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_DIVIDE_NEG_NEG
; -20 / -4 = 5 (both negative — result should be positive)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_DIVIDE_NEG_NEG:
    ld   hl, -20
    ld   de, -4
    call MATH_DIVIDE16
    ld   de, 5
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_DIVIDE_BY_ZERO
; 100 / 0 = 0 (the deliberate safe default — see kernel/math/math.asm's
; header for why, rather than the nonsense -1 the raw algorithm would
; otherwise produce)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_DIVIDE_BY_ZERO:
    ld   hl, 100
    ld   de, 0
    call MATH_DIVIDE16
    ld   de, 0
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_COMPARE_EQUAL
; 7 compared to 7 -> A=0
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_COMPARE_EQUAL:
    ld   hl, 7
    ld   de, 7
    call MATH_COMPARE16
    or   a
    ret  z
    scf
    ret

; ============================================================================
; TEST_COMPARE_GREATER
; 10 compared to 3 -> A=1
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_COMPARE_GREATER:
    ld   hl, 10
    ld   de, 3
    call MATH_COMPARE16
    cp   1
    ret  z
    scf
    ret

; ============================================================================
; TEST_COMPARE_LESS
; 3 compared to 10 -> A=$FF
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_COMPARE_LESS:
    ld   hl, 3
    ld   de, 10
    call MATH_COMPARE16
    cp   $FF
    ret  z
    scf
    ret

; ============================================================================
; TEST_COMPARE_NEG_POS
; -5 compared to 2 -> A=$FF (negative is always less than positive,
; the exact case a naive unsigned SBC HL,DE — with no overflow check —
; would get backwards)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_COMPARE_NEG_POS:
    ld   hl, -5
    ld   de, 2
    call MATH_COMPARE16
    cp   $FF
    ret  z
    scf
    ret

; ============================================================================
; TEST_COMPARE_BOUNDARY
; -32768 compared to 32767 -> A=$FF (the widest possible signed gap —
; exactly where the signed-overflow flag from SBC HL,DE must be
; consulted, since the raw subtraction itself overflows)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_COMPARE_BOUNDARY:
    ld   hl, -32768
    ld   de, 32767
    call MATH_COMPARE16
    cp   $FF
    ret  z
    scf
    ret

; ============================================================================
; TEST_ADD_BASIC
; 100 + 23 = 123
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_ADD_BASIC:
    ld   hl, 100
    ld   de, 23
    call MATH_ADD16
    ld   de, 123
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_SUB_BASIC
; 100 - 23 = 77
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_SUB_BASIC:
    ld   hl, 100
    ld   de, 23
    call MATH_SUB16
    ld   de, 77
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_NEGATE_BOUNDARY
; NEGATE16(-32768) = -32768 (no positive 16-bit representation exists —
; see kernel/math/math.asm's own header for why this is correct, not a
; bug; Python-verified before any Z80 was written)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_NEGATE_BOUNDARY:
    ld   hl, -32768
    call MATH_NEGATE16
    ld   de, -32768
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_ABS_POS
; ABS(17) = 17 (already positive — nothing to do)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_ABS_POS:
    ld   hl, 17
    call MATH_ABS16
    ld   de, 17
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_ABS_NEG
; ABS(-17) = 17
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_ABS_NEG:
    ld   hl, -17
    call MATH_ABS16
    ld   de, 17
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_ABS_BOUNDARY
; ABS(-32768) = -32768 (same two's-complement edge case as NEGATE16)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_ABS_BOUNDARY:
    ld   hl, -32768
    call MATH_ABS16
    ld   de, -32768
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_SGN_POS
; SGN(42) = 1
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_SGN_POS:
    ld   hl, 42
    call MATH_SGN16
    ld   de, 1
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_SGN_NEG
; SGN(-42) = -1
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_SGN_NEG:
    ld   hl, -42
    call MATH_SGN16
    ld   de, -1
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_SGN_ZERO
; SGN(0) = 0
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_SGN_ZERO:
    ld   hl, 0
    call MATH_SGN16
    ld   de, 0
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_MOD_BASIC
; 17 MOD 5 = 2
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MOD_BASIC:
    ld   hl, 17
    ld   de, 5
    call MATH_MOD16
    ld   de, 2
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_MOD_NEG_DIVIDEND
; -17 MOD 5 = -2 (remainder takes the dividend's sign, truncating
; convention — not 3, which a flooring-division language would give)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MOD_NEG_DIVIDEND:
    ld   hl, -17
    ld   de, 5
    call MATH_MOD16
    ld   de, -2
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_MOD_NEG_DIVISOR
; 17 MOD -5 = 2 (divisor's sign doesn't flip the remainder's sign —
; only the dividend's sign matters)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MOD_NEG_DIVISOR:
    ld   hl, 17
    ld   de, -5
    call MATH_MOD16
    ld   de, 2
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_MOD_BY_ZERO
; 100 MOD 0 = 0 (matches MATH_DIVIDE16's own safe default)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_MOD_BY_ZERO:
    ld   hl, 100
    ld   de, 0
    call MATH_MOD16
    ld   de, 0
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_SQRT_PERFECT
; SQRT16(16) = 4 (perfect square)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_SQRT_PERFECT:
    ld   hl, 16
    call MATH_SQRT16
    ld   de, 4
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_SQRT_NONPERFECT
; SQRT16(15) = 3 (truncating — not a perfect square)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_SQRT_NONPERFECT:
    ld   hl, 15
    call MATH_SQRT16
    ld   de, 3
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_SQRT_ZERO
; SQRT16(0) = 0
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_SQRT_ZERO:
    ld   hl, 0
    call MATH_SQRT16
    ld   de, 0
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_SQRT_NEGATIVE
; SQRT16(-5) = 0 (negative input treated as 0, no error mechanism at
; this layer — matches MATH_DIVIDE16's own divide-by-zero convention)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_SQRT_NEGATIVE:
    ld   hl, -5
    call MATH_SQRT16
    ld   de, 0
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_SQRT_BOUNDARY
; SQRT16(32767) = 181 (largest valid signed positive input)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_SQRT_BOUNDARY:
    ld   hl, 32767
    call MATH_SQRT16
    ld   de, 181
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; ============================================================================
; TEST_RND_RANGE
; RND(10) called 5 times in a row — each result must satisfy
; 0 <= r < 10. Doesn't check any specific value (the whole point of
; RND is that it varies) — checks the invariant every call must
; satisfy regardless of what the actual seed turns out to be.
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_RND_RANGE:
    ld   b, 5
.range_loop:
    push bc
    ld   hl, 10
    call MATH_RND16
    ld   a, h
    or   a
    jr   nz, .range_fail                   ; result must fit in one
                                          ; byte for x=10 — if H isn't
                                          ; 0, something's badly wrong
    ld   a, l
    cp   10
    jr   nc, .range_fail                   ; must be < 10
    pop  bc
    djnz .range_loop
    or   a
    ret
.range_fail:
    pop  bc
    scf
    ret

; ============================================================================
; TEST_RND_ZERO
; RND(0) = 0 (x=0 has no valid nonzero range, safe default)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_RND_ZERO:
    ld   hl, 0
    call MATH_RND16
    ld   a, h
    or   l
    ret  z
    scf
    ret

; ============================================================================
; TEST_RND_NEGATIVE
; RND(-5) = 0 (negative x, safe default — no error mechanism at this
; layer, matches MATH_DIVIDE16's own divide-by-zero convention)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_RND_NEGATIVE:
    ld   hl, -5
    call MATH_RND16
    ld   a, h
    or   l
    ret  z
    scf
    ret

; ============================================================================
; TEST_RND_ONE
; RND(1) = 0 (the only value in [0,0] — degenerate but valid range)
; Out: carry clear = pass, carry set = fail
; ============================================================================
TEST_RND_ONE:
    ld   hl, 1
    call MATH_RND16
    ld   a, h
    or   l
    ret  z
    scf
    ret

    INCLUDE "kernel/math/math.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_math.bin", $0000, $4000
