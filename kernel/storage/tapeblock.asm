; ============================================================================
; kernel/storage/tapeblock.asm -- tape block I/O: send one cassette block, receive or verify one
;
; Clean-room code from 2068-Leap-C (MIT; its src/runtime/tapeblock.asm, Phase 11 M11-tape), written
; from a specification of the tape signal alone (Leap-C docs/TAPE_SIGNAL_SPEC.md, docs/
; TAPE_CLEANROOM.md): no part of it comes from the stock Spectrum or TS2068 ROM. It replaced V2's
; port of the stock ROM's SA-BYTES / LD-BYTES (back-port plan item 3.1). The code below is Leap-C's
; unchanged; kernel/storage/storage.asm names it STORAGE_SEND_BLOCK / STORAGE_RECEIVE_BLOCK for its
; callers (STORAGE_SAVE, STORAGE_LOAD), whose contracts it meets.
;
; The signal: half-pulses of a square wave on MIC (port $FE bit 3), the information only in the time
; between level changes: a pilot of 2,168 T half-pulses (8,063 for a flag byte < $80, else 3,223), the
; syncs of 667 and 735 T, then every byte of flag + payload + XOR checksum as eight bits, most
; significant first, each two equal half-pulses of 855 T (0) or 1,710 T (1). A block sent whole ends
; with one closing 0-width half-pulse after the checksum.
;
; Timing. In V2 both routines run from the EXROM (uncontended, as Leap-C's HOME is), with interrupts
; off. T-state counts in the comments are the instructions' nominal ones; contention on the port and
; on a payload byte in $4000-$7FFF can only lengthen them. Measured in Leap-C: SAVE's half-pulses
; within 0-16 T of nominal; the receiver accepts 67 of 71 cases of a tolerance test (speed, bit
; widths, jitter, short pilots, dropouts), including every case the stock-derived receiver accepted.
; ============================================================================

; ---------------------------------------------------------------- the sender's constants
; Every half-pulse ends with the one `out` in TS_HALF. The width of a half-pulse is the time from one
; `out` to the next: 13 * N + 48 + X T, where N is the delay count in B, 48 T the fixed part of
; TS_HALF and its call (after the `out`: out 11, ex 4, ret 10 = 25; before it: call 17, the djnz
; loop's last pass -5, ex 4, xor 7 = 23) and X the caller's own code between the return and the next
; call (including the selection of N). The counts below make each kind of half-pulse land on its
; nominal width or a few T above it; the X of each place is given where it is spent.
TS_MIC          EQU $08             ; port $FE bit 3: MIC (TAPE_SIGNAL_SPEC.md 3.1)
TS_EDGE         EQU TS_MIC | $07    ; flipped at every edge: MIC and the border (bits 0-2), so the border
                                    ;   stripes with the signal (the capture reads MIC only)
TS_HDR_PILOT    EQU 8063            ; pilot half-pulses for a flag < $80 (2.2)
TS_DATA_PILOT   EQU 3223            ; and for a flag >= $80
TS_N_PILOT      EQU 160             ; X 41: 13*160+48+41 = 2,169 T (pilot 2,168)
TS_N_SYNC1      EQU 44              ; X 47: 572+48+47 = 667 T
TS_N_SYNC2      EQU 52              ; X 11: 676+48+11 = 735 T
TS_N1_FIRST     EQU 125             ; a bit's first half, X 20 (19 after the syncs): 1,712 T (1,711)
TS_N0_FIRST     EQU 59              ;   for a 0: 856 T (855)
TS_N1_SECOND    EQU 126             ; a bit's second half, X 8: 1,713 T
TS_N0_SECOND    EQU 60              ;   for a 0: 857 T
TS_N1_BYTE      EQU 116             ; the first half of a byte's first bit, X 137: 1,712 T
TS_N0_BYTE      EQU 49              ;   for a 0: 855 T
TS_N_CLOSE      EQU 57              ; the closing half-pulse after the checksum, X 67: 741+48+67 = 856 T

; ---------------------------------------------------------------- the receiver's constants
; TR_EDGE reads the port once per 63 T pass; B counts the passes. The search's widths are in passes
; between two edges (about (T - 161) / 63: pilot 32, a sync 8-10, a 0 half 11, a 1 half 25); a bit's
; count is the passes over its two half-pulses (about (T - 162) / 63: a 0 25, a 1 52). Each edge's
; handling includes the border stripe's `out` (25 T in TR_EDGE).
TR_PILOT_MIN    EQU 16              ; a pilot half-pulse: 16..49 passes, about 1,150..3,220 T (pilot at
TR_PILOT_MAX    EQU 50              ;   -25% and -224 T is about 1,400 T; a sync at +25% and +224 T about 1,060 T)
TR_LOCK         EQU 0               ; L counts pilot half-pulses down from 0 (256); at 1 it stays: a
                                    ;   short half-pulse then is sync 1 (255 pilot half-pulses or more)
TR_ONE          EQU 34              ; a bit is a 1 when its count is above 34 (about 2,360 T)
TR_B_BIT        EQU 0               ; a bit's starting count (bits 2-8 of a byte)
TR_B_BYTE       EQU 3               ; the first bit after a stored byte: +3 passes for the ~195 T of
                                    ;   storing and checking that are not counted
TR_B_FLAG       EQU 1               ; the flag's first bit (after sync 2): +1 for ~46 T
TR_TICKS        EQU 1870            ; give up after 1,870 overflows of B (256 passes, ~16.2 kT each):
                                    ;   about 30.3 M T = 8.6 s (TAPE_SIGNAL_SPEC.md 4.4)

; ============================================================================
; TAPE_SEND_BLOCK -- send one block: pilot, syncs, the flag, the payload and the XOR checksum
; (TAPE_SIGNAL_SPEC.md 2, 4.1)
; In:  A = the flag byte (the pilot is 8,063 half-pulses if A < $80, else 3,223); IX = the payload;
;      DE = its length (0 sends the flag and the checksum only); interrupts on or off
; Out: carry set = the block was sent whole (the SPACE test after the checksum found SPACE up);
;      carry clear = SPACE stopped it after the byte during which it was found down. Interrupts
;      off; port $FE and PORT_FE_SHADOW = the shadow's border colour and MIC as the block left it
;      (the border stripes during the block: every edge also flips the border bits)
; Destroys: AF, AF', BC, DE, HL, IX
;
; Registers while the bits go out: A = the rest of the byte (shifted left, the next bit in carry),
; L = the bits left in it, H = 1 once the checksum is the byte going out, C = the XOR so far,
; B = TS_HALF's delay, DE = the payload bytes left, IX = the next one, A' = the port $FE image.
; TS_HALF swaps A' in only for its `out`, so A and every flag survive it.
; ============================================================================
TAPE_SEND_BLOCK:
    di
    ld   c, a                          ; C = the XOR so far: the flag
    ld   hl, TS_HDR_PILOT + 1          ; (+1: the first `out` only sets the line's level)
    add  a, a                          ; carry = flag bit 7
    jr   nc, .pilot_len
    ld   hl, TS_DATA_PILOT + 1
.pilot_len:
    ld   a, (PORT_FE_SHADOW)
    xor  TS_EDGE                       ; TS_HALF flips it back: the first `out` writes the port as the
    ex   af, af'                       ;   shadow has it, so no edge starts the block
    ld   b, 1
.pilot:                                ; X 41 between two pilot `out`s:
    call TS_HALF
    ld   b, TS_N_PILOT                 ; 7
    nop                                ; 4
    nop                                ; 4
    dec  hl                            ; 6
    ld   a, h                          ; 4
    or   l                             ; 4
    jr   nz, .pilot                    ; 12
    ld   a, c                          ; 4  (X 47 to sync 1: 7+4+4+6+4+4+7 +4 +7) A = the flag
    ld   b, TS_N_SYNC1                 ; 7
    call TS_HALF                       ; the end of sync 1
    add  a, a                          ; 4  carry = the flag's bit 7 (survives TS_HALF)
    ld   b, TS_N_SYNC2                 ; 7  (X 11)
    call TS_HALF                       ; the end of sync 2
    ld   l, 8                          ; 7  (X 19 to the flag's first half)
    jr   .first                        ; 12
.bit:
    add  a, a                          ; 4  carry = the next bit
.first:                                ;    (X 20 from the previous bit: nop 4, jr 12, add 4)
    ld   b, TS_N1_FIRST                ; 7  the selection: a 1 takes 19 T, a 0 21 T
    jr   c, .half1                     ; 12 / 7
    ld   b, TS_N0_FIRST                ; 7
.half1:
    call TS_HALF                       ; the end of the bit's first half
    dec  l                             ; 4  (X 8, Z kept through TS_HALF for the jr below)
    nop                                ; 4
    ld   b, TS_N1_SECOND               ; 7
    jr   c, .half2                     ; 12 / 7
    ld   b, TS_N0_SECOND               ; 7
.half2:
    call TS_HALF                       ; the end of the bit's second half
    nop                                ; 4
    jr   nz, .bit                      ; 12 / 7
; ---- a byte went out: the next byte's first half-pulse carries all of this (X 137, 63 to .fetch)
    ld   a, $7F                        ; 7  the half-row of SPACE
    in   a, (PORT_ULA)                 ; 11
    rra                                ; 4  carry = bit 0 = SPACE up
    jr   nc, .stop                     ; 7  SPACE down: stop, carry clear
    bit  0, h                          ; 8  was it the checksum?
    jr   nz, .close                    ; 7 / 12 yes: the block is whole, carry set
    ld   a, d                          ; 4
    or   e                             ; 4
    jr   nz, .fetch                    ; 7 / 12
    ld   a, c                          ; 4  no payload left: the checksum is next
    inc  h                             ; 4
    nop                                ; 4
    jr   .both                         ; 12 (31 T, as the payload path's 12 + 19)
.fetch:
    ld   a, (ix+0)                     ; 19 the next payload byte
.both:
    inc  ix                            ; 10 (after the checksum, IX and DE no longer matter)
    dec  de                            ; 6
    ld   b, a                          ; 4
    xor  c                             ; 4
    ld   c, a                          ; 4  the XOR (the checksum's own XOR is not used)
    ld   a, b                          ; 4
    ld   l, 8                          ; 7
    add  a, a                          ; 4  carry = the byte's bit 7
    ld   b, TS_N1_BYTE                 ; 7  a 1 takes 19 T, a 0 33 T to TS_HALF
    jr   c, .half1                     ; 12 / 7
    ld   b, TS_N0_BYTE                 ; 7
    jr   .half1                        ; 12
.close:                                ; the closing pulse: one more 0-width half-pulse after the
    ld   b, TS_N_CLOSE                 ;   checksum (TAPE_SIGNAL_SPEC.md 2.4, amendment); X 67
    call TS_HALF                       ;   (carry still set: SPACE up)
.stop:                                 ; the border back to PORT_FE_SHADOW's colour, MIC as the
    ex   af, af'                       ;   block left it (an `out` that keeps MIC: no edge on tape)
    and  TS_MIC                        ; (the main flags wait in F' and come back)
    ld   b, a
    ld   a, (PORT_FE_SHADOW)
    and  $FF ^ TS_MIC
    or   b
    ld   (PORT_FE_SHADOW), a
    out  (PORT_ULA), a
    ex   af, af'
    ret

; ============================================================================
; TS_HALF -- wait, then end the current half-pulse with a level change on MIC
; In:  B = the delay count (1..255: 13 * B - 5 T); A' = the port $FE image
; Out: A' = the image with MIC and the border bits flipped, written to port $FE; B = 0; A and F
;      unchanged
; Destroys: B
; ============================================================================
TS_HALF:
    djnz TS_HALF                       ; 13 a pass, 8 the last
    ex   af, af'                       ; 4
    xor  TS_EDGE                       ; 7
    out  (PORT_ULA), a                 ; 11 the edge (lcharness tape_capture breaks on every `out`)
    ex   af, af'                       ; 4
    ret                                ; 10

; ============================================================================
; TAPE_RECV_BLOCK -- receive (load) or verify one block (TAPE_SIGNAL_SPEC.md 4.2, 5)
; In:  A = the expected flag byte; carry set = load the payload at IX, carry clear = verify it
;      against the bytes at IX; IX = the destination; DE = the payload length (0..65,535); Z is
;      not used; interrupts on or off
; Out: carry clear = the flag matched, DE payload bytes were stored (or matched) and the checksum
;      is right; DE = 0. Carry set = failure (no pilot within ~8.6 s, SPACE, wrong flag, verify
;      mismatch, a dropout, the checksum); DE = the payload bytes not yet stored. IX = the next
;      byte's address throughout (entry IX + the bytes stored or verified). Interrupts off; port
;      $FE = PORT_FE_SHADOW (during the block every edge seen flips its border bits, MIC kept)
; Destroys: AF, AF', BC, DE, HL, IX; STORAGE_ENTRY_RETRY (the search's budget)
;
; The design. Every wait for an edge goes through TR_EDGE: one read of port $7FFE per 63 T pass
; gives EAR (bit 6) and SPACE (bit 0) together, and B counts the passes up by one, which is what
; Fuse's loader detection looks for (Leap-C TAPE_SIGNAL_SPEC.md 5.8). While searching, B runs free and a
; width is the difference of B at two edges (TR_SEDGE); each overflow of B costs one unit of the
; budget, so silence and noise alike give up after ~8.6 s. A pilot is at least 255 half-pulses in a
; row whose widths lie in the pilot window; the first half-pulse below the window
; is sync 1, the next edge ends sync 2. A bit is decided on its full length (both half-pulses):
; B starts at a small count, counts on through both edges, and a 1 is a count above TR_ONE. The
; flag is compared before anything is stored; each payload byte is stored (load) and then compared
; with the byte at IX either way; all bytes and the checksum XOR to 0. Each edge seen flips the
; border (TR_EDGE), as the sender's do, so a user can see a signal arrive and set the volume.
; Stack: the entry AF (the flag and the mode) and two levels of calls: 8 B at most.
; ============================================================================
TAPE_RECV_BLOCK:
    di
    push af                            ; the expected flag and the mode, for the whole block
    ld   a, (PORT_FE_SHADOW)
    ld   c, a                          ; C = the port image (bit 5: the EAR level seen, TR_EDGE)
    ld   hl, TR_TICKS
    ld   (STORAGE_ENTRY_RETRY), hl
.restart:
    ld   l, TR_LOCK                    ; L = pilot half-pulses still needed to lock (256)
.search:
    call TR_SEDGE
    jr   c, .fail
    cp   TR_PILOT_MAX
    jr   nc, .restart                  ; too long (or silence): search again
    cp   TR_PILOT_MIN
    jr   c, .short
    dec  l                             ; a pilot half-pulse
    jr   nz, .search
    inc  l                             ; locked: L stays 1 from here on
    jr   .search
.short:                                ; shorter than the pilot: sync 1 if locked, else noise
    dec  l
    jr   nz, .restart
    call TR_SEDGE                      ; that was sync 1: this edge ends sync 2
    jr   c, .fail
    ld   b, TR_B_FLAG
    call TR_BYTE                       ; the flag
    jr   c, .fail
    pop  af
    push af
    cp   l
    jr   nz, .fail                     ; another flag: nothing stored, DE as on entry
    ld   a, l
    ex   af, af'                       ; A' = the XOR so far
.byte:
    ld   b, TR_B_BYTE
    call TR_BYTE
    jr   c, .fail
    ex   af, af'
    xor  l
    ex   af, af'
    ld   a, d
    or   e
    jr   z, .sum                       ; no payload left: that was the checksum
    pop  af
    push af
    jr   nc, .compare                  ; verify: compare only
    ld   (ix+0), l
.compare:
    ld   a, (ix+0)
    cp   l
    jr   nz, .fail
    inc  ix                            ; IX moves on once the byte is in place
    dec  de
    jr   .byte
.sum:
    ex   af, af'
    or   a                             ; all bytes XOR to 0; carry clear
    jr   z, .exit
.fail:
    scf
.exit:
    pop  hl
    ld   a, (PORT_FE_SHADOW)           ; the border back to the shadow's colour (MIC as it was)
    out  (PORT_ULA), a
    ret

; ============================================================================
; TR_BYTE -- receive one byte, most significant bit first
; In:  B = the first bit's starting count; C = the EAR level (TR_EDGE)
; Out: carry clear: L = the byte; carry set: a dropout (no edge for ~16 kT) or SPACE
; Destroys: AF, B, H, L
; ============================================================================
TR_BYTE:
    ld   h, 8
.bit:
    call TR_EDGE                       ; the middle of the bit
    ret  c
    call TR_EDGE                       ; its end (B counts on: the count covers both halves)
    ret  c
    ld   a, TR_ONE
    cp   b                             ; carry = B > TR_ONE: a 1
    rl   l
    ld   b, TR_B_BIT
    dec  h
    jr   nz, .bit
    or   a                             ; carry clear
    ret

; ============================================================================
; TR_SEDGE -- the next edge while searching: the width since the previous one
; In:  B = the free-running count, H = its value at the previous edge; C = the EAR level
; Out: carry clear: A = the width in passes (mod 256), H = B. Carry set: SPACE, or the budget in
;      STORAGE_ENTRY_RETRY ran out
; Destroys: AF
; ============================================================================
TR_SEDGE:
    call TR_EDGE
    jr   nc, .edge
    ret  nz                            ; SPACE
    push hl                            ; B overflowed: 256 passes (~16.2 kT) have gone
    ld   hl, (STORAGE_ENTRY_RETRY)
    dec  hl
    ld   (STORAGE_ENTRY_RETRY), hl
    ld   a, h
    or   l
    pop  hl
    jr   nz, TR_SEDGE
    scf                                ; out of budget: give up
    ret
.edge:
    ld   a, b
    sub  h
    ld   h, b
    or   a
    ret

; ============================================================================
; TR_EDGE -- wait for EAR to change, counting the passes in B
; In:  B = the count; C = the port $FE image (bits 0-4), bit 5 = the EAR level last seen (bit 6 of
;      port $FE, after one rra)
; Out: carry clear: an edge; C bit 5 = the new level and the border bits flipped, bits 0-4 written to
;      port $FE (MIC and bit 4 unchanged: the border stripes); B = the count at the read that saw it.
;      Carry set and Z: B overflowed to 0 (no edge for 256 - B passes). Carry set and NZ: SPACE down
; Destroys: AF
; One pass: inc 4, jr 7, ld 7, in 11, rra 4, jr 7, xor 4, and 7, jr 12 = 63 T, B up by one per read.
; ============================================================================
TR_EDGE:
    inc  b
    jr   z, .out                       ; (Z: the overflow)
    ld   a, $7F                        ; the half-row of SPACE
    in   a, (PORT_ULA)
    rra                                ; carry = SPACE up; EAR now in bit 5
    jr   nc, .out                      ; (NZ: B is not 0 here)
    xor  c
    and  $20
    jr   z, TR_EDGE
    xor  $07                           ; 7  A = $27: the level and the border bits
    xor  c                             ; 4  A bit 5 = the new level
    ld   c, a                          ; 4
    and  $1F                           ; 7  (carry clear)
    out  (PORT_ULA), a                 ; 11 the border stripe (after TAPE_RECV_BLOCK: not captured)
    ret
.out:
    scf
    ret
