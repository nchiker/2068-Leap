; ============================================================================
; rom/test_keycode.asm — diagnostic: show IO_READ_KEY's raw return value
;
; Not a feature test — a debugging tool. Loops calling IO_READ_KEY and
; prints the returned code as a 2-digit hex number on screen, so we can
; see EXACTLY what comes back for a given keypress rather than guessing
; from code review. Useful reference values:
;   $61 = 'a' (unshifted lowercase)      $41 = 'A' (CAPS SHIFT+a)
;   $00 = unmapped (nothing detected, or a key with no translation yet)
;   $08 = KEY_DELETE (CAPS SHIFT+0)      $0D = KEY_ENTER
;   $01/$02/$03/$04 = cursor LEFT/DOWN/UP/RIGHT
;
; Press keys one at a time and watch the hex code change. If a key does
; nothing in test_editor.asm, check here what code it's actually
; producing — $00 confirms "nothing detected," anything else means
; detection works but something downstream (editor dispatch) isn't
; handling that code.
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_keycode.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_keycode.bin --rom-ts2068-1 rom1.bin
; ============================================================================

    INCLUDE "include/hardware.inc"

    DEVICE NOSLOT64K

; ---- RAM scratch — must be RAM, not ROM DB data, since this is written
; to every loop iteration (see this project's earlier border-counter-in-
; ROM and test-buffer-in-ROM bugs for why this matters) ----
KEYCODE_BUF  EQU $8000
HEX_STR      EQU $8010     ; 3 bytes: 2 hex digit chars + null terminator

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call GFX_CLS

.loop:
    call IO_READ_KEY
    ld   (KEYCODE_BUF), a

    ; high nibble -> hex char
    ld   a, (KEYCODE_BUF)
    and  $F0
    rrca
    rrca
    rrca
    rrca
    call HEX_CHAR
    ld   (HEX_STR), a

    ; low nibble -> hex char
    ld   a, (KEYCODE_BUF)
    and  $0F
    call HEX_CHAR
    ld   (HEX_STR + 1), a

    xor  a
    ld   (HEX_STR + 2), a      ; null terminator

    ld   hl, HEX_STR
    ld   b, 0
    ld   c, 0
    call GFX_PRINT_STRING
    jr   .loop

; ============================================================================
; HEX_CHAR
; In:  A = nibble value (0-15)
; Out: A = ASCII hex digit character ('0'-'9' or 'A'-'F')
; Destroys: AF
; ============================================================================
HEX_CHAR:
    cp   10
    jr   c, .digit
    add  a, "A" - 10
    ret
.digit:
    add  a, "0"
    ret

    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_keycode.bin", $0000, $4000
