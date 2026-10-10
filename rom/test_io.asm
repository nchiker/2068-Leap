; ============================================================================
; rom/test_io.asm — kernel/io interactive smoke test
;
; NOT an automated pass/fail test like rom/test_memory.asm — keyboard
; input can't be synthesized the way test data was for kernel/memory's
; tests. This is INTERACTIVE: run it in Fuse and press keys on your own
; keyboard. Border goes GREEN while any key is held down, BLACK when
; released. If it does that, this file's own TEST_ANY_KEY_DOWN (and by
; extension IO_KEY_SCAN_ROW/IO_KEY_SCAN_ALL) are confirmed working
; against Fuse's TS2068 keyboard emulation.
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

; TEST_ANY_KEY_DOWN -- inlined here (R10.7 dormant-ROM audit, docs/v2/
; R10_7_DORMANT_ROM_CONSOLIDATION_AUDIT.md): previously kernel/io/io.asm's
; own IO_ANY_KEY_DOWN, whose own header said it existed "e.g. [for] the
; interactive test in rom/test_io.asm" -- i.e. this file was its only
; real consumer, in production or otherwise. Removed from the shared
; kernel file as dead production code; inlined here instead of deleted,
; so this manual interactive test keeps verifying the same real
; capability (IO_KEY_SCAN_ALL's own underlying keyboard scan) that
; everything else in kernel/io is built on. Out: carry set if at least
; one key is down, carry clear if none are. Destroys: AF, BC, HL.
TEST_ANY_KEY_DOWN:
    call IO_KEY_SCAN_ALL          ; HL = IO_SCAN_TABLE
    ld   b, KEY_ROW_COUNT
.check_loop:
    ld   a, (hl)
    and  $1F                       ; only bits 0-4 are meaningful
    cp   $1F                        ; all 5 bits set = nothing pressed
                                   ; in this row
    jr   nz, .found
    inc  hl
    djnz .check_loop
    or   a                          ; clear carry: nothing found
    ret
.found:
    scf
    ret

POLL_LOOP:
    call TEST_ANY_KEY_DOWN
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
