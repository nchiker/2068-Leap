; ============================================================================
; rom/test_editor.asm — kernel/editor interactive test
;
; INTERACTIVE, like rom/test_io.asm — type on your real keyboard and
; watch it appear live on screen. Tests EDITOR_INSERT_CHAR,
; EDITOR_DELETE_CHAR, EDITOR_MOVE_CURSOR (LEFT/RIGHT/HOME/END), and
; EDITOR_REDRAW_SCREEN together, via the real EDITOR_ENTER/EDITOR_LOOP —
; not synthetic test data, actual keyboard-to-screen editing.
;
; What to try: type some letters/digits, use CAPS SHIFT+5/6/7/8 to move
; the cursor left/right within the line (see docs/hardware_notes.md —
; CAPS SHIFT held with 5/6/7/8, not dedicated cursor keys), CAPS SHIFT+0
; to delete forward, and confirm the line on screen matches what you'd
; expect after each edit. Press ENTER to exit (border turns yellow —
; EDITOR_EXIT does NOT commit anything to program storage yet, see that
; routine's own comment for why; this test only exercises live text
; editing, not saving it).
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR — reviewed-by-eye and hand-
; traced only (see kernel/editor/editor.asm's INSERT_CHAR/DELETE_CHAR
; comments for the traces).
;
; Build:
;   sjasmplus rom/test_editor.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_editor.bin --rom-ts2068-1 rom1.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call MEM_INIT
    call EDITOR_INIT

    ld   hl, PROG_AREA_START    ; EDITOR_ENTER's "program position" input
                                ; — doesn't do much yet since EDITOR_EXIT
                                ; doesn't act on it either (see that
                                ; routine's comment), but this is the
                                ; sensible value to pass regardless
    call EDITOR_ENTER
    ; falls through here once ENTER is pressed inside the editor loop

    ld   a, 6                    ; yellow — editor session ended
    out  (PORT_ULA), a
    jr   $

    INCLUDE "kernel/editor/editor.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"      ; graphics LINE/CIRCLE helpers

    DS   $4000 - $, $FF

    SAVEBIN "test_editor.bin", $0000, $4000
