; ============================================================================
; rom/test_calc_smoke_endcalc.asm — calculator engine (RST $28) real-
; hardware smoke test: end-calc round trip
;
; Standalone, no BASIC keyword needed — the pass/fail signal convention
; (COLD_START runs the check directly, border GREEN on pass) matches
; rom/test_math.asm and this project's other kernel-primitive smoke
; tests. The FILE STRUCTURE itself (full basic.asm+kernel includes,
; KTAB table, real EXROM paging) instead matches the rom/test_preload_
; *.asm family, since — unlike test_math.asm's pure kernel-only
; routines — CALC_ENTRY_TRAMPOLINE lives in basic.asm and this test
; genuinely needs the real EXROM paging chain, not a trimmed-down one.
;
; An earlier version of this test tried to trigger the calculator via
; `RANDOMIZE USR <addr>` from the BASIC REPL; this project's BASIC has
; neither RANDOMIZE nor USR implemented (confirmed against basic.asm's
; own keyword table, not assumed) — that was a real mistake, corrected
; here by using established patterns instead of inventing one.
;
; Runs the real, unmodified `RST $28 / DB $38` (end-calc, the only
; implemented calculator op) directly from COLD_START — the actual Z80
; opcode, exercising the complete production chain: RST vector, both
; Home-side trampolines (CALC_ENTRY_TRAMPOLINE/CALC_EXIT_TRAMPOLINE,
; basic/basic.asm), real EXROM paging, CALC_EXROM_ENTRY's dispatch
; loop, the real CALC_TABLE data, CALC_OP_END_CALC, and the KTAB_
; CALC_EXIT_TRAMPOLINE routing fixed after the first real sjasmplus
; run caught a "Label not found" error (see include/exrom_jumptable.
; inc's own history).
;
; Signal method: same as every other kernel-module test in this
; project — border goes GREEN if the whole chain returns correctly.
; Anything short of that (frozen machine, wrong color, reset) means
; the chain broke somewhere between RST $28 and here — genuinely new
; information a symbolic simulator can't provide, since it has no
; paging model at all (see tools/z80sim/test_calc_dispatcher.py's own
; header for what it could and couldn't cover).
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_calc_smoke_endcalc.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_calc_smoke_endcalc.bin --rom-ts2068-1 exrom.bin
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

    xor  a
    inc  a
    ld   (CALC_SP), a           ; CALC_SP = 1, enough for the unary
                                ; operand-pointer computation to run
                                ; without crashing (end-calc doesn't
                                ; actually touch operand data)
    rst  $28
    DB   $38                    ; end-calc — the real Z80 RST opcode
                                ; pushes the return address (the byte
                                ; right after this DB) automatically
    ; only reached if the full chain returned correctly
    ld   a, 4                   ; green = pass
    out  (PORT_ULA), a
.loop:
    jr   .loop

    INCLUDE "rom/calc_smoke_home.inc"

    DS   $4000 - $, $FF

    SAVEBIN "test_calc_smoke_endcalc.bin", $0000, $4000
