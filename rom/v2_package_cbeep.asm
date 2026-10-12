; ============================================================================
; rom/v2_package_cbeep.asm -- MAINT (ClassicBEEP study): the original loudspeaker BEEP as a
; loadable package.  The main ROM's BEEP plays on the AY chip; this package brings back the
; TS2068's own speaker (port $FE bit 4), through the very routine V2 used to have in HOME:
; kernel/sound/sound.asm's SOUND_BEEP is assembled into the package unchanged (one cycle =
; 222 + 52 x pitch T-states, interrupts off while it sounds).
;
; Statement (package names are at most 8 characters: CLASSICBEEP cannot be registered):
;
;   CBEEP ms, semitones, border      default build (package ABI 2.0, as released)
;   CBEEP ms, semitones              -DCB_PIN_FE: needs PORT_FE_SHADOW pinned (ABI 2.1, see the study)
;   CBEEP cycles, pitch, border      -DCB_RAW: the old V2 raw BEEP (design A)
;
; ms: 0..32767 milliseconds (package arguments are 16-bit integers: no fractions of a second
; reach a package, so the duration is in thousandths); semitones -60..69 above middle C, as
; Sinclair BEEP.  Out of range, or more than 65535 cycles (4.6 s at +69): error 15.
; border: the border colour to keep while the speaker bit is toggled -- every write to port $FE
; also sets the border, and package ABI 2.0 does not let a package read the border V2 holds
; (PORT_FE_SHADOW is not a pinned cell).
;
; Pitch and length are computed in integers (no calculator: EXROM is paged out while a package
; runs): pitch = ((Q[n] >> octave) - 15) >> 2, cycles = ms x F[n] >> (22 - octave), tables for the
; lowest octave (-60..-49), calibrated for the real TS2068 clock (3.528 MHz).  Bit-exact model and
; accuracy: tools/maint/cbeep_model.py.
; ============================================================================
    INCLUDE "include/hardware.inc"
    INCLUDE "include/v2_package_abi.inc"   ; the ONLY HOME interface a package may use
    PKG_SVC_LIST
    PKG_CONST_LIST
    PKG_PIN_LIST
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    jp   CB_INSTALL

    IFDEF CB_PIN_FE
CB_NARGS EQU 2
    ELSE
CB_NARGS EQU 3
    ENDIF

CB_INSTALL:
    ld   hl, CB_NAME
    ld   de, CB_EXEC
    ld   bc, CB_NARGS << 8              ; B = arguments, C = 0: all numeric
    jp   EXT2_REGISTER                  ; carry clear = installed
CB_NAME:
    DB   "CBEEP", 0

; ---------------------------------------------------------------------------- execute
CB_EXEC:
    IFDEF CB_PIN_FE
    ld   a, (PORT_FE_SHADOW)            ; border (and MIC) as V2 holds them
    ELSE
    ld   a, (EXT_CALL_ARG2)
    and  7                              ; the border colour the program gives
    ENDIF
    ld   (cb.PORT_FE_SHADOW), a
    IFDEF CB_RAW
    ld   de, (EXT_CALL_ARG0)            ; cycles
    ld   bc, (EXT_CALL_ARG1)            ; pitch
    jp   cb.SOUND_BEEP
    ELSE
    ld   de, (EXT_CALL_ARG0)
    bit  7, d
    jr   nz, CB_ERR                     ; a negative duration
    ld   hl, (EXT_CALL_ARG1)
    ld   bc, 60
    add  hl, bc                         ; 0..129 = semitones -60..69
    ld   a, h
    or   a
    jr   nz, CB_ERR
    ld   a, l
    cp   130
    jr   nc, CB_ERR
    ld   b, -1
.octave:
    inc  b
    sub  12
    jr   nc, .octave                    ; B = octave (0..10), A = note - 12
    add  a, a
    add  a, low (CB_TQ + 24)
    ld   l, a
    ld   h, high (CB_TQ + 24)           ; HL -> Q[note] (the tables do not cross a page)
    push bc                             ; octave
    push hl
    ld   a, (hl)
    inc  hl
    ld   h, (hl)
    ld   l, a                           ; HL = Q[note]
    inc  b
    jr   .shift1
.shift:
    srl  h
    rr   l
.shift1:
    djnz .shift                         ; HL = Q >> octave
    ld   bc, -15
    add  hl, bc
    srl  h
    rr   l
    srl  h
    rr   l                              ; HL = pitch (1 or more for every note)
    ex   (sp), hl                       ; keep it; HL -> Q[note]
    ld   bc, 24
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)                        ; BC = F[note]; DE = ms
    ld   hl, 0
    ld   a, 16
.mul:
    add  hl, hl
    rl   e
    rl   d
    jr   nc, .mul1
    add  hl, bc
    jr   nc, .mul1
    inc  de
.mul1:
    dec  a
    jr   nz, .mul                       ; DEHL = ms x F
    pop  bc                             ; BC = pitch
    pop  af                             ; A = octave
    sub  22
    neg                                 ; A = 22 - octave
.down:
    srl  d
    rr   e
    rr   h
    rr   l
    dec  a
    jr   nz, .down                      ; DEHL = cycles
    ld   a, d
    or   e
    jr   nz, CB_ERR                     ; more than 65535 cycles
    ex   de, hl                         ; DE = cycles, BC = pitch
    jp   cb.SOUND_BEEP
    ENDIF

CB_ERR:
    ld   a, 15                          ; as the ROM's BEEP: out of range
    ld   (VM_ERROR_CODE), a
    ld   a, 1
    ld   (VM_HALTED), a
    ret

    IFNDEF CB_RAW
; Q[n] = 4 x 3528000 / (52 f), F[n] = f x 65536 x 64 / 1000, f = the note in the lowest octave
; (two values a line: tools/check_package_abi.py reads a listing line's bytes as one item)
CB_TQ:
    DW   33194, 31331
    DW   29572, 27912
    DW   26346, 24867
    DW   23471, 22154
    DW   20911, 19737
    DW   18629, 17584
CB_TF:
    DW   34292, 36331
    DW   38491, 40780
    DW   43205, 45774
    DW   48496, 51380
    DW   54435, 57672
    DW   61101, 64734
    ASSERT high CB_TQ == high (CB_TF - 1)
    ENDIF

; ---------------------------------------------------------------------------- the beeper
; V2's original HOME routine, unchanged.  Inside the module its PORT_FE_SHADOW is the package's
; own cell below (cb.PORT_FE_SHADOW), not HOME's.
    MODULE cb
    INCLUDE "kernel/sound/sound.asm"
PORT_FE_SHADOW:
    DB   0
    ENDMODULE

V2_PACKAGE_CBEEP_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    IFDEF CB_RAW
    SAVEBIN "build/v2_package_cbeep_raw.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_CBEEP_END-EXTENSION_MODULE_BASE
    ELSE
    IFDEF CB_PIN_FE
    SAVEBIN "build/v2_package_cbeep_pin.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_CBEEP_END-EXTENSION_MODULE_BASE
    ELSE
    SAVEBIN "build/v2_package_cbeep.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_CBEEP_END-EXTENSION_MODULE_BASE
    ENDIF
    ENDIF
