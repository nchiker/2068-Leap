; ============================================================================
; rom/test_calc_smoke_division.asm — calculator engine real-hardware
; smoke test: division (literal $05, CALC_TABLE index $0A)
;
; Standalone, same shape as rom/test_calc_smoke_arithmetic.asm (read
; that file's header for the full background) — this file only checks
; the one op that file explicitly doesn't: division, added to
; rom/exrom_calc.asm's CALC_TABLE alongside add/sub/mul, which was
; unimplemented (hung via CALC_OP_UNIMPLEMENTED) before this.
;
; Two cases, chosen for different coverage:
;   1. 32761/181=181 — the exact inverse of test_calc_smoke_arithmetic's
;      own 181*181=32761 multiply check. Its packed-float result should
;      be BYTE-IDENTICAL to how 181 alone encodes (verified in the
;      Python model this was derived from — not just numerically close),
;      and this case exercises CALC_OP_DIV's "preshift" branch (dividend
;      mantissa >= divisor mantissa).
;   2. 1/3=0.333... — a genuinely repeating fraction, not a suspiciously
;      round result, exercising the full 32-iteration shift-subtract
;      loop's actual bit-generation (not just trailing zeros) and the
;      "no preshift" branch (dividend mantissa < divisor mantissa).
;
; Both operands loaded as small-int form (same idiom as test_calc_
; smoke_arithmetic.asm); expected results precomputed by actually
; running this project's own byte-accurate Python simulation of the
; real Z80 instruction sequence (not just Python's native float
; division) before any Z80 was written — see rom/exrom_calc.asm's
; CALC_OP_DIV header for the full algorithm writeup. This distinction
; matters for case 2 below: CALC_OP_DIV TRUNCATES (floors) like every
; other divider in this project (kernel/math's MATH_DIVIDE16 explicitly
; does too), it does not round — an earlier draft of this test computed
; case 2's expected LSB via Python's round(1/3) instead of the
; truncating simulation, off by one ($AB instead of the correct $AA),
; and was caught by the real hardware/Fuse run coming back RED on this
; step while case 1 (an exact, no-rounding-ambiguity result) came back
; GREEN in isolation — see rom/test_calc_div_debug.asm, kept as a
; worked example of bisecting a border-color-only failure by isolating
; one case per run with a distinct color per compared byte.
;
; Sequence and expected state after each step (CALC_SP reset to 2
; before each, since division consumes 2 operands -> 1 result):
;   1. 32761/181=181       -> slot0 = 88 35 00 00 00
;   2. 1/3=0.333... (truncated, not rounded) -> slot0 = 7F 2A AA AA AA
;
; Signal: GREEN if both match, RED on the first mismatch.
;
; Step 1 confirmed on real hardware/Fuse in isolation (rom/test_calc_
; div_debug.asm, green). Step 2's corrected expected byte not yet
; re-run — checked against this project's own tools/check_asm.py and
; tools/check_z80_opcodes.py static linters and assembled clean with
; sjasmplus.
;
; Build:
;   sjasmplus rom/test_calc_smoke_division.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_calc_smoke_division.bin --rom-ts2068-1 exrom.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE
    INCLUDE "include/exrom_jumptable.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START

    DS   $0028 - $, $FF
RST_28:
    jp   CALC_ENTRY_TRAMPOLINE

    DS   $0038 - $, $FF
RST_38:
    call KBD_ISR_TICK
    ei
    reti

    ORG  KTAB_BASE
    KTAB_LIST
    ASSERT $ <= KTAB_END
    DB   KTAB_MAGIC

    INCLUDE "include/shared_lowrom_data.inc"
    EMIT_SHARED_LOWROM_DATA

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    ; ---- step 1: 32761 / 181 = 181 -------------------------------------
    ld   a, 2
    ld   (CALC_SP), a
    ld   hl, CALC_STACK
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $F9          ; 32761 low byte
    inc  hl
    ld   (hl), $7F          ; 32761 high byte
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $B5          ; 181 low byte
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00

    rst  $28
    DB   $05, $38            ; division, end-calc

    ld   hl, CALC_STACK
    ld   a, (hl)
    cp   $88
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $35
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $00
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $00
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $00
    jp   nz, FAIL

    ; ---- step 2: 1 / 3 = 0.333... --------------------------------------
    ld   a, 2
    ld   (CALC_SP), a
    ld   hl, CALC_STACK
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $01          ; 1 low byte
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $03          ; 3 low byte
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00

    rst  $28
    DB   $05, $38            ; division, end-calc

    ld   hl, CALC_STACK
    ld   a, (hl)
    cp   $7F
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $2A
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $AA
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $AA
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $AA
    jp   nz, FAIL

    ; ---- all passed ---------------------------------------------------
    ld   a, 4                       ; green
    out  (PORT_ULA), a
.pass_loop:
    jr   .pass_loop

FAIL:
    ld   a, 2                       ; red
    out  (PORT_ULA), a
.fail_loop:
    jr   .fail_loop

    INCLUDE "rom/calc_smoke_home.inc"

    DS   $4000 - $, $FF

    SAVEBIN "test_calc_smoke_division.bin", $0000, $4000
