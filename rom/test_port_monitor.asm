; ============================================================================
; rom/test_port_monitor.asm — minimal EAR-bit oscilloscope
;
; Purpose: after many rounds of debugging LOAD failures where every
; environmental variable we could think of (Fuse version, tape traps,
; accelerate loaders, detect loaders, emulation speed, debugger
; interaction) has been individually ruled out or has given
; inconsistent results, this steps back to the simplest possible
; question: is the EAR bit (port $FE, bit 6) changing AT ALL during a
; normal, hands-off run — independent of STORAGE_WAIT_EDGE/_PILOT's
; own timing logic, thresholds, or search budget, any of which could
; themselves be adding confusion on top of the real answer.
;
; This does ONE thing: sample port $FE bit 6 in a tight loop and latch
; the border green on the first sampled change. No timeout, no
; threshold, no tape-format interpretation.
;
; HOW TO READ THE RESULT:
;   - Border turns GREEN and stays green while a tape plays: real
;     signal IS reaching the CPU during a normal run. A latch is used
;     because a pilot tone changes too quickly to judge by eye at the
;     display frame rate. If green appears, the bug is somewhere in
;     STORAGE_RECEIVE_BLOCK after raw EAR sampling.
;   - Border remains BLACK while a tape plays:
;     conclusive, code-independent proof that no real signal is
;     reaching the CPU during a normal run — points squarely at a
;     Fuse/environment issue, not this ROM's SAVE/LOAD code, since
;     this test has none of that code in it at all.
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_port_monitor.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_port_monitor.bin --rom-ts2068-1 rom1.bin
; Then: open a tape, press Play, and just watch the border — no need
; to type anything at all, this runs from cold boot.
; ============================================================================

    INCLUDE "include/hardware.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    ld   a, 0                    ; start on black border, arbitrary
    out  (PORT_ULA), a

    ld   c, PORT_ULA
    ld   b, 0                    ; B fixed at 0 throughout — matches
                                 ; kernel/storage's own STORAGE_WAIT_
                                 ; EDGE convention, never touched again
    in   a, (c)
    and  %01000000
    ld   e, a                    ; E = last-known EAR state, seeded
                                 ; from a real initial read

.loop:
    in   a, (c)
    and  %01000000
    cp   e
    jr   z, .loop                ; unchanged -- keep sampling, no
                                 ; delay of any kind
    ld   a, 4                    ; green = at least one EAR transition
    out  (PORT_ULA), a
.latched:
    jr   .latched

    DS   $4000 - $, $FF

    SAVEBIN "test_port_monitor.bin", $0000, $4000
