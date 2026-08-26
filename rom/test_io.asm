; ============================================================================
; rom/test_io.asm — kernel/io interactive smoke test
;
; NOT an automated pass/fail test like rom/test_memory.asm — keyboard
; input can't be synthesized the way test data was for kernel/memory's
; tests. This is INTERACTIVE: run it in Fuse and press keys on your own
; keyboard. Border goes GREEN while any key is held down, BLACK when
; released. If it does that, IO_ANY_KEY_DOWN (and by extension
; IO_KEY_SCAN_ROW/IO_KEY_SCAN_ALL) are confirmed working against Fuse's
; TS2068 keyboard emulation.
;
; This does NOT test IO_READ_KEY's ASCII translation table, nor the
; CAPS SHIFT+digit cursor/delete combo detection (both need a way to
; display which key was detected, which needs kernel/graphics — not
; written yet). Only confirms the underlying "is anything pressed"
; scan, which everything else in kernel/io is built on.
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR — reviewed-by-eye only,
; same caveat as kernel/io/io.asm itself.
;
; Build:
;   sjasmplus rom/test_io.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_io.bin --rom-ts2068-1 rom1.bin
;   Click into the Fuse window first so it has keyboard focus, then press
;   any key. Expect the border to turn green while held, black when
;   released.
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF     ; same padding convention as main.asm/
                            ; test_memory.asm — RST vectors unused here

COLD_START:
    ld   sp, $FF00

POLL_LOOP:
    call IO_ANY_KEY_DOWN
    jr   c, .key_down
    xor  a                    ; black — nothing pressed
    jr   .set_border
.key_down:
    ld   a, 4                  ; green — something is pressed
.set_border:
    out  (PORT_ULA), a
    jr   POLL_LOOP             ; deliberate infinite poll, not a bug —
                              ; this is meant to run forever, reacting
                              ; live to whatever you're pressing

    INCLUDE "kernel/io/io.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_io.bin", $0000, $4000
