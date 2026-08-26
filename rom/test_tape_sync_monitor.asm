; ============================================================================
; test_tape_sync_monitor.asm — LD-BYTES leader + sync acceptance probe
;
; BLACK: waiting for a usable signal.  GREEN: 256 valid pilot pulses
; followed by both sync pulses were accepted by the real LD-BYTES logic.
; This is a diagnostic ROM only; its receive path is copied through the
; point where STORAGE_RECEIVE_BLOCK enters .marker to avoid changing the
; timing under test.
; ============================================================================

    INCLUDE "include/hardware.inc"

EDGE_DELAY      EQU $16
LEADER_PILOT    EQU $9C
; Match the Fuse-calibrated threshold currently used by STORAGE_LOAD.
LEADER_GAP      EQU $A0
SYNC_TIMING     EQU $C9
SYNC_GAP_MAX    EQU $D4

    DEVICE NOSLOT64K

    ORG $0000
    di
    jp   START
    DS   $0100 - $, $FF

START:
    ld   sp, $FF00
    xor  a
    out  (PORT_ULA), a
    ld   a, $0f
    out  (PORT_ULA), a
    in   a, (PORT_ULA)
    rra
    and  $20
    or   $02
    ld   c, a

.entry_start:
    call EDGE1
    jr   nc, .entry_start
    ld   hl, $0415
.wait:
    djnz .wait
    dec  hl
    ld   a, h
    or   l
    jr   nz, .wait
    call EDGE2
    jr   nc, .entry_start
.leader:
    ld   b, LEADER_PILOT
    call EDGE2
    jr   nc, .entry_start
    ld   a, LEADER_GAP
    cp   b
    jr   nc, .entry_start
    inc  h
    jr   nz, .leader
.sync:
    ld   b, SYNC_TIMING
    call EDGE1
    jr   nc, .entry_start
    ld   a, b
    cp   SYNC_GAP_MAX
    jr   nc, .sync
    call EDGE1
    jr   nc, .entry_start

    ld   a, 4                            ; synchronized successfully
    out  (PORT_ULA), a
.latched:
    jr   .latched

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
    ret  nc
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
    SAVEBIN "test_tape_sync_monitor.bin", $0000, $4000
