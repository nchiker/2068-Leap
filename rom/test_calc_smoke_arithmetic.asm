; ============================================================================
; rom/test_calc_smoke_arithmetic.asm — calculator engine real-hardware
; smoke test: addition ($0F), subtraction ($03), multiply ($04)
;
; Standalone, no BASIC keyword needed — same shape as rom/test_calc_
; smoke_stackops.asm (read that file's header, and rom/test_calc_
; smoke_endcalc.asm's before it, for the full background on why this
; structure exists). This file only documents what's different.
;
; NOT tested here: CALC_INT_TO_FP/CALC_FP_TO_INT. Both are plain kernel
; routines, not CALC_TABLE literals — they have no RST $28 entry point
; and no KTAB_* trampoline slot yet (that's future LET-assignment
; integration work, not built), so this Home-side test binary has no
; way to reach them at all — EXROM is a separate ROM image
; (exrom_build.asm -> exrom.bin), and only KTAB-routed calls cross that
; boundary. Addition/subtraction/multiply ARE real CALC_TABLE literals
; now, reachable the same way exchange/delete/duplicate/end-calc
; already are, so this test checks them the same way stackops.asm
; checks those: known int operands poked directly into CALC_STACK as
; small-int-form bytes, then the RESULT bytes checked against known-
; good general-form encodings, precomputed from this project's own
; verified Python model (tools/z80sim/test_calc_dispatcher.py's tests
; 10-14 already confirm the same arithmetic in the simulator; this is
; the real-hardware confirmation of that result, not a new check).
;
; Sequence and expected state after each step (CALC_SP always reset to
; 2 before each step, since each op consumes 2 operands -> 1 result):
;   1. 100+250=350  -> slot0 = 89 2F 00 00 00 (addition, $0F)
;   2. 100-250=-150 -> slot0 = 88 96 00 00 00 (subtraction, $03 —
;      first/lower operand MINUS second/top operand)
;   3. 181*181=32761 -> slot0 = 8F 7F F2 00 00 (multiply, $04 — a
;      near-boundary case: 182*182 would NOT fit in 16 bits, so this
;      also exercises the multiply engine's normalization path close
;      to its real operating range, not just a trivially small
;      product)
;
; Signal: GREEN if all three match, RED on the first mismatch.
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_calc_smoke_arithmetic.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_calc_smoke_arithmetic.bin --rom-ts2068-1 exrom.bin
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

    ; ---- step 1: 100 + 250 = 350 -------------------------------------
    ld   a, 2
    ld   (CALC_SP), a
    ld   hl, CALC_STACK
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $64          ; 100 low byte
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $FA          ; 250 low byte
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00

    rst  $28
    DB   $0F, $38            ; addition, end-calc

    ld   hl, CALC_STACK
    ld   a, (hl)
    cp   $89
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $2F
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

    ; ---- step 2: 100 - 250 = -150 ------------------------------------
    ld   a, 2
    ld   (CALC_SP), a
    ld   hl, CALC_STACK
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $64
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $FA
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00

    rst  $28
    DB   $03, $38            ; subtract, end-calc

    ld   hl, CALC_STACK
    ld   a, (hl)
    cp   $88
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $96
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

    ; ---- step 3: 181 * 181 = 32761 -----------------------------------
    ld   a, 2
    ld   (CALC_SP), a
    ld   hl, CALC_STACK
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $B5          ; 181 low byte
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $B5
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00

    rst  $28
    DB   $04, $38            ; multiply, end-calc

    ld   hl, CALC_STACK
    ld   a, (hl)
    cp   $8F
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $7F
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $F2
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $00
    jp   nz, FAIL
    inc  hl
    ld   a, (hl)
    cp   $00
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

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/editor/editor.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_calc_smoke_arithmetic.bin", $0000, $4000
