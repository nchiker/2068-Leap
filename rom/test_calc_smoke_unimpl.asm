; ============================================================================
; rom/test_calc_smoke_unimpl.asm — calculator engine (RST $28) real-
; hardware smoke test: recoverable unimplemented-op path
;
; Standalone, no BASIC keyword needed — see rom/test_calc_smoke_
; endcalc.asm's own header for the full reasoning on file structure,
; the RANDOMIZE USR mistake this corrects, and why the earlier
; approach was wrong. Read that file first; this one only documents
; what's actually different below.
;
; Runs `RST $28 / DB $06,$38`. Literal $06 is unavailable; the expected
; result is a normal return with CALC_ERR_UNIMPLEMENTED and an empty
; calculator stack, not a diagnostic freeze.
;
; Build:
;   sjasmplus rom/test_calc_smoke_unimpl.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_calc_smoke_unimpl.bin --rom-ts2068-1 exrom.bin
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

    ld   a, 2
    ld   (CALC_SP), a           ; binary-path operand depth is valid
    rst  $28
    DB   $06, $38              ; unavailable op, then normal terminator
    ld   a, (CALC_ERROR_CODE)
    cp   CALC_ERR_UNIMPLEMENTED
    jr   nz, .fail
    ld   a, (CALC_SP)
    or   a
    jr   nz, .fail
    ld   a, 4                   ; green
    out  (PORT_ULA), a
.loop:
    jr   .loop
.fail:
    ld   a, 2
    out  (PORT_ULA), a
    jr   .fail

    INCLUDE "rom/calc_smoke_home.inc"

    DS   $4000 - $, $FF

    SAVEBIN "test_calc_smoke_unimpl.bin", $0000, $4000
