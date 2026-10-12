; ============================================================================
; rom/v2_ay_beep.asm -- MAINT (AY BEEP): Sinclair-style `BEEP seconds,semitones` on the AY-3-8912.
;
; Included by both images (rom/v2_home.asm with V2_KTAB_HOME defined, rom/v2_exrom.asm without).
; OP_BEEP (HOME, rom/exrom_v2_vm_core.asm) turns the seconds into display frames and calls the
; EXROM slot AY_BEEP with HL = semitones, DE = frames. AY_BEEP = AY_BEEP_PERIOD then AY_BEEP_PLAY.
; Where each piece lives is a build choice (only to balance the two ROM budgets; the code is the
; same): V2_MAINT_AYB_PERIOD_HOME puts AY_BEEP_PERIOD and its table in HOME, V2_MAINT_AYB_PLAY_HOME
; puts AY_BEEP_PLAY in HOME, V2_MAINT_AYB_WAIT_HOME puts AY_WAIT_FRAMES in HOME. EXROM code calls
; HOME pieces directly (build/v2_crossbank.inc); HOME reaches EXROM only through the slot.
;
; The startup chime (rom/exrom_v2_shell.asm) shares AY_BEEP_PLAY / AY_WAIT_FRAMES.
; ============================================================================

AY_BEEP_VOLUME EQU 15           ; channel A's fixed level while a BEEP sounds (no envelope)

    IFDEF V2_MAINT_SHARED_WAIT      ; MAINT (shared wait): PAUSE, BEEP and the chime share one wait,
    IFNDEF V2_MAINT_AYB_WAIT_HOME   ; which must then be in HOME (OP_PAUSE is HOME code)
    DEFINE V2_MAINT_AYB_WAIT_HOME
    ENDIF
    ENDIF

; ----------------------------------------------------------------------------
; AY_BEEP_PERIOD -- HL = semitones above middle C (-60..69, else error 15) -> HL = the AY tone
; period 110250 / f, f = 261.63 * 2^(semitones/12), rounded (AY clock 1.764 MHz = the TS2068's
; 3.528 MHz / 2; tone = clock / 16 / period). The 12-bit period register cannot go below
; 27.5 Hz: semitones -60..-40 play -39 (A0). Destroys AF, BC; DE (the frames) is kept.
; ----------------------------------------------------------------------------
    MACRO AY_BEEP_PERIOD_TABLE
; 16 * 110250 / f for the 12 notes from semitone -39 (A0, 27.5 Hz).
AY_BEEP_TABLE:
    dw   64145,60545,57147,53940,50912,48055,45358,42812,40409,38141,36000,33980
    ENDM

    MACRO AY_BEEP_PERIOD_HEAD
    ld   bc, 60
    add  hl, bc                       ; HL = semitones + 60: 0..129 is the stock ROM's range
    ld   a, h
    or   a
    jp   nz, VM_ERR_RANGE
    ld   a, l
    cp   130
    jp   nc, VM_ERR_RANGE
    sub  21                           ; A = semitones + 39
    jr   nc, .in_range
    xor  a                            ; below the AY's range: A0
.in_range:
    ld   b, 3
.octave:
    inc  b
    sub  12
    jr   nc, .octave                  ; B = octave + 4, A = note - 12
    add  a, a
    IF ((AY_BEEP_TABLE + 24) & $FF) >= 24
    add  a, (AY_BEEP_TABLE + 24) & $FF   ; the table does not cross a 256-byte page
    ld   l, a
    ld   h, (AY_BEEP_TABLE + 24) >> 8
    ELSE
    add  a, (AY_BEEP_TABLE + 24) & $FF   ; A = 2 * note - 24, a negative offset: no DE (the
    ld   l, a                            ; frames) used
    ld   a, ((AY_BEEP_TABLE + 24) >> 8) - 1
    adc  a, 0
    ld   h, a
    ENDIF
    ld   a, (hl)
    inc  hl
    ld   h, (hl)
    ld   l, a                         ; HL = the note's entry
.shift:
    srl  h
    rr   l
    djnz .shift                       ; HL = entry / 2^(octave + 4); carry = the half bit
    ENDM

; ----------------------------------------------------------------------------
; AY_BEEP_PLAY -- the note on the AY's channel A.
; In:  HL = tone period (R1:R0), DE = duration in display frames (0 = nothing at all)
; Out: channel A silent (R8 = 0), its period left in R0/R1; the mixer (R7) has tone A on and noise
;      A off, its other bits as they were; channels B and C, the noise period, the envelope and the
;      I/O ports untouched. Interrupts stay enabled: the frames are counted by HALT.
; Destroys: AF, C, DE (B and HL kept)
; ----------------------------------------------------------------------------
    MACRO AY_BEEP_PLAY_BODY
AY_BEEP_PLAY:
    ld   a, d
    or   e
    ret  z                            ; under half a frame: nothing (the stock ROM is silent too)
    ; No wait for a frame first: notes played one after another then follow each other without a
    ; gap (a BEEP ends just after an interrupt), at the cost of an isolated note's first frame
    ; being partial (DE - 1 to DE frames).
    ld   c, PORT_AY_DATA
    IFDEF V2_MAINT_AYB_RESTORE        ; (measured alternative: channel A given back afterwards)
    xor  a
    call .ay_read
    push af                           ; R0
    ld   a, 1
    call .ay_read
    push af                           ; R1
    ld   a, 7
    call .ay_read
    push af                           ; R7
    ld   a, 8
    call .ay_read
    push af                           ; R8
    ENDIF
    xor  a
    out  (PORT_AY_REG), a
    out  (c), l                       ; R0 = period, fine
    inc  a
    out  (PORT_AY_REG), a
    out  (c), h                       ; R1 = period, coarse
    ld   a, 7
    out  (PORT_AY_REG), a
    in   a, (c)
    and  $FE                          ; tone A on
    or   $08                          ; noise A off
    out  (c), a
    ld   a, 8
    out  (PORT_AY_REG), a
    ld   a, AY_BEEP_VOLUME
    out  (c), a                       ; R8 = fixed level
    call AY_WAIT_FRAMES
    IFDEF V2_MAINT_AYB_RESTORE
    pop  af
    ld   b, 8
    call .ay_write                    ; R8, R7, R1, R0 as they were
    pop  af
    dec  b
    call .ay_write
    pop  af
    ld   b, 1
    call .ay_write
    pop  af
    dec  b
    call .ay_write
    ret
.ay_write:
    push af
    ld   a, b
    out  (PORT_AY_REG), a
    pop  af
    out  (c), a
    ret
.ay_read:
    out  (PORT_AY_REG), a
    in   a, (c)
    ret
    ELSE
    IFDEF V2_MAINT_SHARED_WAIT
    xor  a                            ; (the wait returns A <> 0 when BREAK ended it)
    ENDIF
    out  (c), a                       ; R8 (still selected) = 0
    ret
    ENDIF
    ENDM

; AY_WAIT_FRAMES -- waits DE (1..65535) display interrupts. Out: A = 0, DE = 0. Needs interrupts
; enabled (as PAUSE and the editor do). Destroys AF, DE only.
; MAINT (shared wait): also PAUSE n's wait; returns early, A <> 0, once BREAK has halted the
; program (VM_HALTED, set by the ISR); the caller's `jp (iy)` then stops the VM.
    MACRO AY_WAIT_FRAMES_BODY
AY_WAIT_FRAMES:
    IFDEF V2_MAINT_SHARED_WAIT
    ld   a, (VM_HALTED)
    or   a
    ret  nz                           ; BREAK
    ENDIF
    halt
    dec  de
    ld   a, d
    or   e
    jr   nz, AY_WAIT_FRAMES
    ret
    ENDM

    IFDEF V2_KTAB_HOME
; ------------------------------------------------------------------ HOME pieces
    IFDEF V2_MAINT_AYB_PERIOD_HOME
    AY_BEEP_PERIOD_TABLE
AY_BEEP_PERIOD:
    AY_BEEP_PERIOD_HEAD
    ret  nc
    inc  hl                           ; rounded to the nearest
    ret
    ENDIF
    IFDEF V2_MAINT_AYB_PLAY_HOME
    AY_BEEP_PLAY_BODY
    ENDIF
    IFDEF V2_MAINT_AYB_WAIT_HOME
    AY_WAIT_FRAMES_BODY
    ENDIF

    ELSE
; ------------------------------------------------------------------ EXROM pieces
; AY_BEEP -- the slot target: HL = semitones, DE = frames.
    IFDEF V2_MAINT_AYB_PERIOD_HOME
AY_BEEP:
    call AY_BEEP_PERIOD
        IFDEF V2_MAINT_AYB_PLAY_HOME
    jp   AY_BEEP_PLAY
        ENDIF
    ELSE
    AY_BEEP_PERIOD_TABLE
AY_BEEP:
    AY_BEEP_PERIOD_HEAD
    jr   nc, .rounded
    inc  hl                           ; rounded to the nearest
.rounded:
        IFDEF V2_MAINT_AYB_PLAY_HOME
    jp   AY_BEEP_PLAY
        ENDIF
    ENDIF
    IFNDEF V2_MAINT_AYB_PLAY_HOME
    AY_BEEP_PLAY_BODY                 ; (AY_BEEP falls into it)
    ENDIF
    IFNDEF V2_MAINT_AYB_WAIT_HOME
    AY_WAIT_FRAMES_BODY
    ENDIF
    ENDIF
