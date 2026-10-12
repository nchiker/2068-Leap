; ============================================================================
; rom/ext_cbeep_module.asm -- MAINT (ClassicBEEP study): the CBEEP package body (install, execute,
; tables, V2's original SOUND_BEEP).  Assembled by rom/v2_package_cbeep.asm, which has the header,
; the ABI includes and the build switches (CB_RAW, CB_PIN_FE).
; ============================================================================
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
CB_NAME: DB "CBEEP", 0

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

