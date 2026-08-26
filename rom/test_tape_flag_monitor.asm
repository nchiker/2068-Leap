; ============================================================================
; LD-BYTES header probe. Green = the complete known header in export/test
; decodes correctly; red = pilot/sync worked but a header byte differs.
; ============================================================================
    INCLUDE "include/hardware.inc"
EDGE_DELAY EQU $16
LEADER_PILOT EQU $9C
LEADER_GAP EQU $A0
SYNC_TIMING EQU $C9
SYNC_GAP_MAX EQU $D4
; Diagnostic candidate: Fuse measures this Direct Recording's pulses
; below the real-ROM classification boundary ($CB).
BIT_COMPARE EQU $B7
BIT_RESET EQU $B0
    DEVICE NOSLOT64K
    ORG $0000
    di
    jp START
    DS $0100-$,$FF
START:
    ld sp,$ff00
    xor a
    out (PORT_ULA),a
    ld a,$0f
    out (PORT_ULA),a
    in a,(PORT_ULA)
    rra
    and $20
    or $02
    ld c,a
.entry:
    call EDGE1
    jr nc,.entry
    ld hl,$0415
.wait:
    djnz .wait
    dec hl
    ld a,h
    or l
    jr nz,.wait
    call EDGE2
    jr nc,.entry
.leader:
    ld b,LEADER_PILOT
    call EDGE2
    jr nc,.entry
    ld a,LEADER_GAP
    cp b
    jr nc,.entry
    inc h
    jr nz,.leader
.sync:
    ld b,SYNC_TIMING
    call EDGE1
    jr nc,.entry
    ld a,b
    cp SYNC_GAP_MAX
    jr nc,.sync
    call EDGE1
    jr nc,.entry
    ld ix,$9000
    ld d,14                              ; flag + 12-byte header + XOR
.byte:
    ld b,BIT_RESET
    ld l,1
.bits:
    call EDGE2
    jr nc,.entry
    ld a,BIT_COMPARE
    cp b
    rl l
    ld b,BIT_RESET
    jp nc,.bits
    ld (ix+0),l
    inc ix
    dec d
    jr nz,.byte
    ld hl,$9000
    ld de,EXPECTED
    ld b,14
    ld c,0
.compare:
    ld a,(de)
    cp (hl)
    jr nz,.mismatch
    inc de
    inc hl
    inc c
    djnz .compare
.green:
    ld a,4
    jr .show
.mismatch:
    ld a,c
    or a
    jr z,.blue                            ; type flag (byte 0)
    cp 5
    jr c,.red                             ; filename letters (1-4)
    cp 11
    jr c,.yellow                          ; filename padding (5-10)
    cp 13
    jr c,.cyan                            ; length (11-12)
    ld a,3                                ; checksum (13): magenta
    jr .show
.blue:
    ld a,1
    jr .show
.red:
    ld a,2
    jr .show
.yellow:
    ld a,6
    jr .show
.cyan:
    ld a,5
.show:
    out (PORT_ULA),a
.hold:
    jr .hold
EXPECTED:
    DB $00,"test      ",$25,$00,$33
EDGE2:
    call EDGE1
    ret nc
    ret
EDGE1:
    ld a,EDGE_DELAY
.delay:
    dec a
    jr nz,.delay
    and a
.sample:
    inc b
    ret z
    ld a,$7f
    in a,(PORT_ULA)
    rra
    ret nc
    xor c
    and $20
    jr z,.sample
    ld a,c
    cpl
    ld c,a
    and $07
    or $08
    out (PORT_ULA),a
    scf
    ret
    DS $4000-$,$FF
    SAVEBIN "test_tape_flag_monitor.bin",$0000,$4000
