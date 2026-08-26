; ============================================================================
; test_tape_pilot_gauge_fine.asm — fine LD-BYTES pilot-count gauge.
;
; Use after test_tape_pilot_gauge reported BLUE (B <= $B8):
;   blue    B <= $A0       cyan    $A1-$A8
;   green   $A9-$B0        yellow  $B1-$B4
;   magenta $B5-$B6        white   $B7-$B8
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
    cp $A1
    jr c, .blue
    cp $A9
    jr c, .cyan
    cp $B1
    jr c, .green
    cp $B5
    jr c, .yellow
    cp $B7
    jr c, .magenta
    ld a, 7
    jr .show
.blue:
    ld a, 1
    jr .show
.cyan:
    ld a, 5
    jr .show
.green:
    ld a, 4
    jr .show
.yellow:
    ld a, 6
    jr .show
.magenta:
    ld a, 3
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
    SAVEBIN "test_tape_pilot_gauge_fine.bin", $0000, $4000
