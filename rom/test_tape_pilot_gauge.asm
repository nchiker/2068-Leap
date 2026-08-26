; ============================================================================
; test_tape_pilot_gauge.asm — shows the LD-BYTES B count for one pilot pulse.
;
; BLACK waits for tape. Once a leader pulse is measured using the exact
; LD-BYTES entry sequence, the border latches one of these ranges:
;   blue    B <= $B8       cyan    $B9-$C0
;   yellow  $C1-$C4        green   $C5-$C6
;   white   $C7-$C8        red     B >= $C9
; The current real-ROM limit ($C6) accepts only white or red.
; ============================================================================

    INCLUDE "include/hardware.inc"

EDGE_DELAY   EQU $16
LEADER_PILOT EQU $9C

    DEVICE NOSLOT64K
    ORG $0000
    di
    jp START
    DS $0100 - $, $FF

START:
    ld sp, $FF00
    xor a
    out (PORT_ULA), a
    ld a, $0f
    out (PORT_ULA), a
    in a, (PORT_ULA)
    rra
    and $20
    or $02
    ld c, a
    call EDGE1
    ld hl, $0415
.wait:
    djnz .wait
    dec hl
    ld a, h
    or l
    jr nz, .wait
    call EDGE2
    ld b, LEADER_PILOT
    call EDGE2
    jr nc, START

    ld a, b
    cp $B9
    jr c, .blue
    cp $C1
    jr c, .cyan
    cp $C5
    jr c, .yellow
    cp $C7
    jr c, .green
    cp $C9
    jr c, .white
    ld a, 2
    jr .show
.blue:
    ld a, 1
    jr .show
.cyan:
    ld a, 5
    jr .show
.yellow:
    ld a, 6
    jr .show
.green:
    ld a, 4
    jr .show
.white:
    ld a, 7
.show:
    out (PORT_ULA), a
.hold:
    jr .hold

EDGE2:
    call EDGE1
    ret nc
    ret
EDGE1:
    ld a, EDGE_DELAY
.delay:
    dec a
    jr nz, .delay
    and a
.sample:
    inc b
    ret z
    ld a, $7f
    in a, (PORT_ULA)
    rra
    ret nc
    xor c
    and $20
    jr z, .sample
    ld a, c
    cpl
    ld c, a
    and $07
    or $08
    out (PORT_ULA), a
    scf
    ret

    DS $4000 - $, $FF
    SAVEBIN "test_tape_pilot_gauge.bin", $0000, $4000
