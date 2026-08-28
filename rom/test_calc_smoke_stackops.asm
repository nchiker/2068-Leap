; ============================================================================
; rom/test_calc_smoke_stackops.asm — calculator engine real-hardware
; smoke test: exchange ($01), delete ($02), duplicate ($31)
;
; Standalone, no BASIC keyword needed — same shape and reasoning as
; rom/test_calc_smoke_endcalc.asm (read that file's header first for
; the full background: why this structure, the RANDOMIZE USR mistake
; it corrects, why it needs the full basic.asm+kernel+EXROM chain).
; This file only documents what's different: three real ops instead of
; one, each chained with `DB $38` (end-calc) so the machine cleanly
; returns after each and the next check can run — not a single
; all-or-nothing hang/return signal like the endcalc/unimpl pair.
;
; Sets up two known, distinguishable 5-byte patterns directly in
; CALC_STACK (poked as plain data — none of these three ops interpret
; the bytes as a real float, they're pure copy/swap/pointer operations,
; so any pattern works as a marker), then runs each op in turn,
; checking the REAL resulting bytes and CALC_SP against exactly what
; z80sim's tools/z80sim/test_calc_dispatcher.py already confirmed
; (tests 5-8) — this is the real-hardware confirmation of that
; simulator result, not a new/different check.
;
; Sequence and expected state after each step:
;   1. CALC_SP=2, slot0=11 22 33 44 55, slot1=66 77 88 99 AA
;   2. RST $28 / DB $01,$38 (exchange) -> slot0/slot1 swapped, SP still 2
;   3. RST $28 / DB $02,$38 (delete)   -> SP=1, slot0 (the surviving
;      first operand) = what slot0 held after the exchange (66 77 88
;      99 AA)
;   4. RST $28 / DB $31,$38 (duplicate) -> SP=2, slot1 = a copy of
;      slot0 (still 66 77 88 99 AA)
;
; Signal method: same as every other kernel-module test in this
; project — border GREEN if every check above passes, RED on the
; first mismatch (this test has actual intermediate checks to fail,
; unlike the single-outcome endcalc/unimpl pair, so RED is meaningful
; here rather than just "anything but green").
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_calc_smoke_stackops.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_calc_smoke_stackops.bin --rom-ts2068-1 exrom.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE     ; must precede the INCLUDE
                                         ; below — selects the `jp`-
                                         ; emitting branch of KTAB_LIST
    INCLUDE "include/exrom_jumptable.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START

    DS   $0028 - $, $FF
; ---- RST 28: calculator engine entry point — same wiring as rom/
; test_basic.asm's real one; see that file and basic/basic.asm's
; CALC_ENTRY_TRAMPOLINE header for the full reasoning. ----
RST_28:
    jp   CALC_ENTRY_TRAMPOLINE

    DS   $0038 - $, $FF
; ---- RST 38 / IM 1 maskable interrupt entry point ----
RST_38:
    call KBD_ISR_TICK
    ei
    reti

; ---- EXROM call table — single source of truth is include/
; exrom_jumptable.inc's own KTAB_LIST macro; mirrors rom/test_basic.
; asm's own layout exactly. ----
    ORG  KTAB_BASE
    KTAB_LIST
    ASSERT $ <= KTAB_END
    DB   KTAB_MAGIC

    INCLUDE "include/shared_lowrom_data.inc"
    EMIT_SHARED_LOWROM_DATA

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    ; ---- setup: CALC_SP=2, two known 5-byte patterns in CALC_STACK --
    ld   a, 2
    ld   (CALC_SP), a
    ld   hl, CALC_STACK
    ld   (hl), $11
    inc hl
    ld   (hl), $22
    inc hl
    ld   (hl), $33
    inc hl
    ld   (hl), $44
    inc hl
    ld   (hl), $55
    inc hl        ; slot0 = 11 22 33 44 55
    ld   (hl), $66
    inc hl
    ld   (hl), $77
    inc hl
    ld   (hl), $88
    inc hl
    ld   (hl), $99
    inc hl
    ld   (hl), $AA                 ; slot1 = 66 77 88 99 AA

    ; ---- step 1: exchange ------------------------------------------
    rst  $28
    DB   $01, $38                   ; exchange, end-calc

    ; expect: slot0 = 66 77 88 99 AA, slot1 = 11 22 33 44 55
    ld   hl, CALC_STACK
    ld   a, (hl)
    cp $66
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $77
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $88
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $99
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $AA
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $11
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $22
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $33
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $44
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $55
    jp nz, FAIL

    ; ---- step 2: delete ----------------------------------------------
    rst  $28
    DB   $02, $38                   ; delete, end-calc

    ; expect: CALC_SP=1, slot0 unchanged (66 77 88 99 AA)
    ld   a, (CALC_SP)
    cp 1
    jp nz, FAIL
    ld   hl, CALC_STACK
    ld   a, (hl)
    cp $66
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $77
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $88
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $99
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $AA
    jp nz, FAIL

    ; ---- step 3: duplicate --------------------------------------------
    rst  $28
    DB   $31, $38                   ; duplicate, end-calc

    ; expect: CALC_SP=2, slot1 = copy of slot0 (66 77 88 99 AA)
    ld   a, (CALC_SP)
    cp 2
    jp nz, FAIL
    ld   hl, CALC_STACK + 5
    ld   a, (hl)
    cp $66
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $77
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $88
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $99
    jp nz, FAIL
    inc  hl
    ld a, (hl)
    cp $AA
    jp nz, FAIL

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

    SAVEBIN "test_calc_smoke_stackops.bin", $0000, $4000
