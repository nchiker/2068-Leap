; ============================================================================
; rom/test_calc_smoke_dupoverflow.asm — calculator engine real-hardware
; smoke test: duplicate ($31) stack-overflow hang path
;
; Standalone, no BASIC keyword needed — see rom/test_calc_smoke_
; endcalc.asm's own header for the full background on file structure.
;
; Sets CALC_SP=8 (the fixed 8-slot cap — see CALC_STACK's own sysvars.
; inc comment) directly, then runs `RST $28 / DB $31` (duplicate).
;
; EXPECTED OUTCOME IS A HANG, same shape as rom/test_calc_smoke_unimpl.
; asm: CALC_OP_DUPLICATE's own bounds check (CALC_SP already at the
; 8-slot cap, confirmed against real hardware here — z80sim's test 8
; already confirmed the code path, this confirms it holds under real
; silicon) should hang via its own local jr-to-self loop rather than
; silently writing a 9th 5-byte slot past CALC_STACK's real 40-byte
; allocation into whatever sysvar happens to sit right after it
; (CALC_SP itself, at $B225 — an actual out-of-bounds write bug this
; check exists specifically to catch, not a hypothetical). Border
; NEVER reaches the GREEN line below if that's working correctly.
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_calc_smoke_dupoverflow.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_calc_smoke_dupoverflow.bin --rom-ts2068-1 exrom.bin
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

    ld   a, 8
    ld   (CALC_SP), a               ; stack already at the 8-slot cap
    rst  $28
    DB   $31                        ; duplicate — EXPECTED to hang here
                                    ; and never reach the lines below
                                    ; at all
    ; should NEVER execute — see this file's own header
    ld   a, 4                       ; green
    out  (PORT_ULA), a
.loop:
    jr   .loop

    INCLUDE "rom/calc_smoke_home.inc"

    DS   $4000 - $, $FF

    SAVEBIN "test_calc_smoke_dupoverflow.bin", $0000, $4000
