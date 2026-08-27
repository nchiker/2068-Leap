; ============================================================================
; rom/test_ulaplus.asm — standalone ULAplus palette-port probe
;
; Programs palette entry 8 (paper 0 / border 0 in CLUT 0) bright green,
; programs entry 0 (ink 0) red, enables ULAplus, and displays a checkerboard.
;
; Expected with ULAplus support enabled:
;   bright-green border/background with a red checkerboard.
; Expected without ULAplus support:
;   normal black border/background; the bitmap is also black because the
;   standard attribute selects black ink on black paper.
;
; Build: sjasmplus rom/test_ulaplus.asm
; Run:   fuse --machine ts2068 --rom-ts2068-0 test_ulaplus.bin \
;             --rom-ts2068-1 exrom.bin
; ============================================================================

    INCLUDE "include/hardware.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    ; Make every pixel cell use ink 0 and paper 0. On a stock ULA both
    ; colours are black, making unsupported ULAplus visually unambiguous.
    xor  a
    ld   hl, $5800
    ld   de, $5801
    ld   bc, $02FF
    ld   (hl), a
    ldir

    ; Alternating bitmap bytes produce a strong red/green checkerboard when
    ; the two palette entries below take effect.
    ld   hl, $4000
    ld   bc, $1800
.bitmap_loop:
    ld   (hl), $AA
    inc  hl
    dec  bc
    ld   a, b
    or   c
    jr   nz, .bitmap_loop

    ; Register 0 = ink 0: full red in GGGRRRBB format.
    xor  a
    call ULAPLUS_SELECT
    ld   a, %00011100
    call ULAPLUS_WRITE

    ; Register 8 = paper 0 and border 0: full green.
    ld   a, 8
    call ULAPLUS_SELECT
    ld   a, %11100000
    call ULAPLUS_WRITE

    ; Mode-group register 64, bit 0 = palette mode enabled.
    ld   a, ULAPLUS_MODE_GROUP
    call ULAPLUS_SELECT
    ld   a, 1
    call ULAPLUS_WRITE

    xor  a
    out  (PORT_ULA), a       ; select border 0 after its palette is defined
.hold:
    jr   .hold

ULAPLUS_SELECT:
    ld   bc, PORT_ULAPLUS_SELECT
    out  (c), a
    ret

ULAPLUS_WRITE:
    ld   bc, PORT_ULAPLUS_DATA
    out  (c), a
    ret

    DS   $4000 - $, $FF

    SAVEBIN "test_ulaplus.bin", $0000, $4000

    ; ZEsarUX accepts the TS2068 Home ROM and EXROM as one contiguous 24 KB
    ; image. The probe never pages EXROM, so an inert $FF-filled bank is
    ; sufficient and keeps this test independent of the production EXROM.
    DS   $6000 - $, $FF
    SAVEBIN "test_ulaplus_ts2068.bin", $0000, $6000
