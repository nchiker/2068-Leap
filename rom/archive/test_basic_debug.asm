; ============================================================================
; rom/test_basic_debug.asm — variable storage diagnostic
;
; Same REPL workflow as test_basic.asm (type a statement, ENTER, type
; RUN, ENTER), but after every RUN, ALSO shows VAR_TABLE's raw stored
; value for variable X as a 4-digit hex number at row 20 — fixed,
; always visible, completely independent of whatever PRINT did or
; didn't display at row 0+. Pauses there (press any key to continue)
; so the value doesn't get immediately wiped by the next EDITOR_ENTER
; session's own screen clear — an earlier draft of this file didn't
; pause, so the value flashed and vanished before it could be read.
;
; This directly answers: after "x=5" then RUN, does X's actual stored
; value read back as 0005? If yes, the bug is in PRINT's display path,
; not storage — if no, storage itself is still wrong despite the
; earlier BASIC_TRY_ASSIGNMENT fix.
;
; Try: x=5, ENTER, RUN, ENTER (check row 20 — should read 0005, press
; any key to continue), then PRINT x, ENTER, RUN, ENTER (check row 20
; AGAIN — should still read 0005; check row 0 for whether "5" appeared
; there too).
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_basic_debug.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_basic_debug.bin --rom-ts2068-1 rom1.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

; ---- RAM scratch for the debug display string ----
VARX_STR   EQU $8000   ; 5 bytes: 4 hex digits + null

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_INIT

DEBUG_LOOP:
    call EDITOR_INIT
    ld   hl, PROG_AREA_START
    call EDITOR_ENTER

    ld   hl, EDIT_LINE_BUF
    ld   de, KW_RUN
    call BASIC_MATCH_KEYWORD
    jr   c, .not_run

.check_trailing:
    ld   a, (hl)
    or   a
    jr   z, .is_run
    cp   " "
    jr   nz, .not_run
    inc  hl
    jr   .check_trailing

.is_run:
    call BASIC_RUN
    call SHOW_VAR_X          ; show X's raw stored value regardless of
                             ; whatever RUN did or didn't PRINT
    call WAIT_FOR_KEY          ; pause here — without this, the very
                              ; next EDITOR_ENTER call (top of the
                              ; loop) immediately clears the screen via
                              ; GFX_CLS before there's any chance to
                              ; actually read row 20. This was a real
                              ; gap in the diagnostic itself, caught
                              ; only by the value being reported as
                              ; "flashing and disappearing" rather than
                              ; readable.
    jr   DEBUG_LOOP

.not_run:
    call BASIC_TOKENIZE_LINE
    ex   de, hl
    ld   hl, (EDIT_PROGRAM_POS)
    call MEM_LINE_STORE
    jr   DEBUG_LOOP

; ============================================================================
; WAIT_FOR_KEY
; Blocks until a key is pressed and released — consumes the whole
; press+release cycle (not via IO_READ_KEY, which would try to
; translate it into a character) so nothing leaks into the next
; EDITOR_ENTER session as an unwanted inserted character.
; ============================================================================
WAIT_FOR_KEY:
.wait_press:
    call IO_ANY_KEY_DOWN
    jr   nc, .wait_press
.wait_release:
    call IO_ANY_KEY_DOWN
    jr   c, .wait_release
    ret

; ============================================================================
; SHOW_VAR_X
; Displays VAR_TABLE's raw stored value for variable X, as 4 hex
; digits, at a fixed row (20) — independent of BASIC_OUTPUT_ROW or
; anything PRINT does, so it can never be scrolled/overwritten by
; normal program output during this diagnostic.
; ============================================================================
SHOW_VAR_X:
    ld   a, "X"
    call BASIC_VAR_ADDR
    ld   e, (hl)
    inc  hl
    ld   d, (hl)               ; DE = X's raw stored value

    ld   a, d
    ld   hl, VARX_STR
    call HEX_BYTE_TO_STR
    ld   a, e
    ld   hl, VARX_STR + 2
    call HEX_BYTE_TO_STR

    ld   hl, VARX_STR
    ld   b, 20
    ld   c, 0
    call GFX_PRINT_STRING
    ret

; ============================================================================
; HEX_BYTE_TO_STR
; In:  A = byte value, HL = destination (3 bytes: 2 hex digits + null)
; Out: destination filled; HL unchanged (points at the same buffer)
; Destroys: AF, BC, DE
; ============================================================================
HEX_BYTE_TO_STR:
    push hl
    ld   b, a

    ld   a, b
    and  $F0
    rrca
    rrca
    rrca
    rrca
    call HEX_CHAR
    ld   c, a

    ld   a, b
    and  $0F
    call HEX_CHAR
    ld   d, a

    pop  hl
    ld   (hl), c
    inc  hl
    ld   (hl), d
    inc  hl
    xor  a
    ld   (hl), a
    ret

; ============================================================================
; HEX_CHAR
; In:  A = nibble (0-15)
; Out: A = ASCII hex digit
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

    INCLUDE "basic/basic.asm"
    INCLUDE "kernel/editor/editor.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_basic_debug.bin", $0000, $4000
