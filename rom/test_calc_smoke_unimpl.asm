; ============================================================================
; rom/test_calc_smoke_unimpl.asm — calculator engine (RST $28) real-
; hardware smoke test: unimplemented-op hang path
;
; Standalone, no BASIC keyword needed — see rom/test_calc_smoke_
; endcalc.asm's own header for the full reasoning on file structure,
; the RANDOMIZE USR mistake this corrects, and why the earlier
; approach was wrong. Read that file first; this one only documents
; what's actually different below.
;
; Runs `RST $28 / DB $02` (delete — a real, defined op number, but not
; yet implemented in CALC_TABLE) directly from COLD_START.
;
; EXPECTED OUTCOME IS THE OPPOSITE OF THE OTHER TEST: this one should
; HANG, not return. CALC_TABLE's entry for $02 points at CALC_OP_
; UNIMPLEMENTED, whose whole job is a jr-to-self loop (matches this
; project's own EXROM_VERIFY_KTAB_MAGIC idiom) rather than returning —
; a deliberate "obvious flagged hang beats silent wrong behavior"
; diagnostic (this project's own lesson 10). The border NEVER reaches
; the GREEN line below if that's working correctly. A green border
; here would mean the opposite of a pass: CALC_TABLE's unimplemented
; entries aren't actually routing to the hang stub, a real bug.
;
; This confirms that diagnostic holds under real silicon, not just
; under tools/z80sim/test_calc_dispatcher.py's max_steps stand-in for
; "didn't return" — the simulator can prove the CODE PATH is taken,
; but only real hardware can confirm the machine actually stops
; responding rather than, say, resetting or executing garbage.
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
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

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    xor  a
    inc  a
    ld   (CALC_SP), a           ; CALC_SP = 1
    rst  $28
    DB   $02                    ; delete — unimplemented; EXPECTED to
                                ; hang here and never reach the lines
                                ; below at all
    ; should NEVER execute — see this file's own header
    ld   a, 4                   ; green
    out  (PORT_ULA), a
.loop:
    jr   .loop

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/editor/editor.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_calc_smoke_unimpl.bin", $0000, $4000
