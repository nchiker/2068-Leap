; ============================================================================
; kernel/sound/sound.asm — speaker/beeper output
;
; Owns: BEEP's underlying hardware mechanism (SOUND_BEEP). Real TS2068/
; Spectrum-family hardware produces sound entirely by alternating bit 4
; ($10) of port $FE (PORT_ULA) — confirmed from the real ROM
; disassembly's BEEPER/PARP routine (see docs/programmers_reference.md
; for the full derivation). Border colour lives in bits 0-2 of the same
; port and must survive untouched; MIC output (bit 3) is forced off for
; the duration of the beep, same as real BEEPER — this project already
; has that exact shadow-register discipline established for BORDER
; (kernel/graphics's GFX_SET_BORDER) and the tape SAVE/LOAD pulse
; (kernel/storage's STORAGE_PULSE), both read-modify-write through the
; shared PORT_FE_SHADOW sysvar rather than assuming what the port
; currently holds — SOUND_BEEP follows the same pattern.
;
; Deliberately NOT a port of the real ROM's BEEPER timing loop: real
; BEEPER computes an exact T-state period via a self-modifying IX-
; relative NOP sled, tuned to a specific note frequency looked up
; through the floating-point calculator's own note table (musical note
; number -> Hz). Replicating that — correctly — would need the full
; note-table/calculator machinery AND a way to confirm the resulting
; pitch sounds right, and this project's own test environment has no
; audio output to verify against (screenshots and register traces can
; confirm the port gets toggled the right number of times, at a
; structurally sound loop, but not that a specific loop length produces
; a specific audible Hz). SOUND_BEEP instead exposes the period/cycle-
; count directly as BASIC-level parameters (BEEP's own header in
; basic/basic.asm has the full reasoning) — narrower than the real
; command, honestly scoped rather than presented as authentic.
; ============================================================================

; ============================================================================
; SOUND_BEEP
; Produces a square-wave tone by toggling the speaker bit (port $FE,
; bit 4) at a fixed rate for a fixed number of cycles.
; In:  BC = pitch — per-half-cycle busy-wait length (larger = slower
;      toggling = lower pitch); 0 wraps to a 65536-iteration countdown
;      (DEC BC runs before the zero check below) rather than an
;      instant half-cycle — effectively "as low a pitch as this loop
;      can produce", not a special case, just what the countdown-then-
;      test order naturally does
;      DE = duration — number of full waveform cycles (0 = no-op)
; Out: none
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
SOUND_BEEP:
    ld   a, d
    or   e
    ret  z                             ; duration 0 -> nothing to do

    push ix
    push bc
    pop  ix                            ; IX = pitch, held constant —
                                       ; reloaded into BC fresh before
                                       ; every half-cycle's countdown
                                       ; below, since BC itself gets
                                       ; decremented to zero each time
    di                                  ; timing-sensitive — an
                                       ; interrupt landing mid-loop
                                       ; would skew whichever half-cycle
                                       ; it interrupted, same reasoning
                                       ; real BEEPER's own DI has
    ld   a, (PORT_FE_SHADOW)
    push af                             ; original shadow byte — bit 4
                                        ; (speaker) restored from this
                                        ; at the end for free, since an
                                        ; even number of toggles (two
                                        ; per full cycle) always lands
                                        ; back on the starting value
.cycle:
    call .half_cycle
    call .half_cycle                    ; two toggles = one full
                                        ; waveform cycle
    dec  de
    ld   a, d
    or   e
    jr   nz, .cycle

    pop  af
    ld   (PORT_FE_SHADOW), a            ; restore MIC (and confirm
    out  (PORT_ULA), a                  ; speaker) to the pre-beep state
    pop  ix
    ei
    ret

.half_cycle:
    ld   a, (PORT_FE_SHADOW)
    xor  $10                            ; toggle the speaker bit
    or   $08                            ; keep MIC forced off for the
                                        ; duration of the beep
    ld   (PORT_FE_SHADOW), a
    out  (PORT_ULA), a
    push ix
    pop  bc                             ; BC = pitch (reloaded fresh
                                        ; from IX every half-cycle)
.delay:
    dec  bc
    ld   a, b
    or   c
    jr   nz, .delay
    ret
