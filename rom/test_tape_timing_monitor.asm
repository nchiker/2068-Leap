; ============================================================================
; test_tape_timing_monitor.asm — LD-BYTES pilot-gap acceptance probe
;
; Starts black, waits for tape playback, then uses the real TS2068
; LD-BYTES edge-counting sequence through the first leader pulse.
; GREEN means the pulse satisfies the loader's B > $C6 test; RED means
; it is measured too short and would make STORAGE_RECEIVE_BLOCK restart
; its leader search.  This is a diagnostic ROM only.
; ============================================================================

    INCLUDE "include/hardware.inc"

EDGE_DELAY      EQU $16
LEADER_PILOT    EQU $9C
LEADER_GAP      EQU $C6

    DEVICE NOSLOT64K

    ORG $0000
    di
    jp   START
    DS   $0100 - $, $FF

START:
    ld   sp, $FF00
    xor  a
    out  (PORT_ULA), a                    ; black while waiting

    ; Same initial EAR-state seed as STORAGE_RECEIVE_BLOCK.
    ld   a, $0f
    out  (PORT_ULA), a
    in   a, (PORT_ULA)
    rra
    and  $20
    or   $02
    ld   c, a

    ; Same entry-to-leader sequence as LD-BYTES.  The first two edges
    ; merely acquire the pilot; B is explicitly reset to $9C for the
    ; pulse whose width the real leader check evaluates.
    call EDGE1
    ld   hl, $0415
.wait:
    djnz .wait
    dec  hl
    ld   a, h
    or   l
    jr   nz, .wait
    call EDGE2

.leader:
    ld   b, LEADER_PILOT
    call EDGE2
    jr   nc, START                       ; lost signal: start again
    ld   a, LEADER_GAP
    cp   b
    jr   nc, .red                        ; B <= $C6: loader rejects it
    ld   a, 4                            ; green: loader accepts it
    out  (PORT_ULA), a
    jr   .leader                         ; keep checking each pulse

.red:
    ld   a, 2                            ; red: measured pilot too short
    out  (PORT_ULA), a
.red_hold:
    jr   .red_hold

EDGE2:
    call EDGE1
    ret  nc
    ret

EDGE1:
    ld   a, EDGE_DELAY
.delay:
    dec  a
    jr   nz, .delay
    and  a
.sample:
    inc  b
    ret  z
    ld   a, $7f
    in   a, (PORT_ULA)
    rra
    ret  nc                              ; SPACE abort, as LD-BYTES
    xor  c
    and  $20
    jr   z, .sample
    ld   a, c
    cpl
    ld   c, a
    and  $07
    or   $08
    out  (PORT_ULA), a
    scf
    ret

    DS   $4000 - $, $FF
    SAVEBIN "test_tape_timing_monitor.bin", $0000, $4000
