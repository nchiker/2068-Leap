; ============================================================================
; rom/test_calc_div_debug.asm — diagnostic for rom/test_calc_smoke_
; division.asm's step 1 (32761/181=181), which came back RED. Not a
; feature test — pinpoints WHICH of the 5 expected result bytes
; mismatches, via a distinct border color per byte, since there's no
; other output channel available right now.
;
; Colors: blue(1)=byte0 wrong, red(2)=byte1 wrong, magenta(3)=byte2
; wrong, cyan(5)=byte3 wrong, yellow(6)=byte4 wrong, green(4)=all five
; matched (shouldn't happen given the real test failed, but checked
; anyway in case this diagnostic itself has a typo), white(7)=should
; never be reached.
;
; Build:
;   sjasmplus rom/test_calc_div_debug.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_calc_div_debug.bin --rom-ts2068-1 exrom.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE
    INCLUDE "include/exrom_jumptable.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START

    DS   $0028 - $, $FF
RST_28:
    jp   CALC_ENTRY_TRAMPOLINE

    DS   $0038 - $, $FF
RST_38:
    call KBD_ISR_TICK
    ei
    reti

    ORG  KTAB_BASE
    KTAB_LIST
    ASSERT $ <= KTAB_END
    DB   KTAB_MAGIC

    INCLUDE "include/shared_lowrom_data.inc"
    EMIT_SHARED_LOWROM_DATA

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    ld   a, 2
    ld   (CALC_SP), a
    ld   hl, CALC_STACK
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $F9          ; 32761 low byte
    inc  hl
    ld   (hl), $7F          ; 32761 high byte
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $B5          ; 181 low byte
    inc  hl
    ld   (hl), $00
    inc  hl
    ld   (hl), $00

    rst  $28
    DB   $05, $38            ; division, end-calc

    ld   hl, CALC_STACK
    ld   a, (hl)
    cp   $88
    jp   nz, BYTE0_WRONG
    inc  hl
    ld   a, (hl)
    cp   $35
    jp   nz, BYTE1_WRONG
    inc  hl
    ld   a, (hl)
    cp   $00
    jp   nz, BYTE2_WRONG
    inc  hl
    ld   a, (hl)
    cp   $00
    jp   nz, BYTE3_WRONG
    inc  hl
    ld   a, (hl)
    cp   $00
    jp   nz, BYTE4_WRONG

    ld   a, 4                       ; green — all matched
    out  (PORT_ULA), a
.pass_loop:
    jr   .pass_loop

BYTE0_WRONG:
    ld   a, 1                       ; blue
    out  (PORT_ULA), a
.b0_loop:
    jr   .b0_loop
BYTE1_WRONG:
    ld   a, 2                       ; red
    out  (PORT_ULA), a
.b1_loop:
    jr   .b1_loop
BYTE2_WRONG:
    ld   a, 3                       ; magenta
    out  (PORT_ULA), a
.b2_loop:
    jr   .b2_loop
BYTE3_WRONG:
    ld   a, 5                       ; cyan
    out  (PORT_ULA), a
.b3_loop:
    jr   .b3_loop
BYTE4_WRONG:
    ld   a, 6                       ; yellow
    out  (PORT_ULA), a
.b4_loop:
    jr   .b4_loop

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/editor/editor.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_calc_div_debug.bin", $0000, $4000
