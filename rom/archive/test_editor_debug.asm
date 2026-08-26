; ============================================================================
; rom/test_editor_debug.asm — editor diagnostic
;
; Not a normal feature test — shows internal state numerically so we can
; see EXACTLY what's happening rather than relying on visual description.
; After every keypress, shows:
;   Row 0:  the line as normally rendered (GFX_PRINT_STRING) — this is
;           where the reported display bug should reproduce
;   Row 2:  "xx" — the raw key code just read from IO_READ_KEY (hex)
;   Row 3:  "xx" — EDIT_BUF_OFFSET (cursor position) in hex
;   Row 4:  "xx" — content length (independently scanned by this file,
;           not reusing kernel/editor's internal EDITOR_SCAN_LEN)
;
; This deliberately does NOT use EDITOR_ENTER/EDITOR_LOOP's normal flow —
; it calls EDITOR_INSERT_CHAR directly in its own minimal loop, so the
; debug rows can be inserted between "insert" and "redraw" without
; touching kernel/editor's actual (already-tested) code.
;
; No cursor movement or delete in this diagnostic — deliberately simple,
; just typing, to isolate the reported bug (which reproduces on plain
; typing already, no need to also exercise movement/delete here).
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR.
;
; Build:
;   sjasmplus rom/test_editor_debug.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_editor_debug.bin --rom-ts2068-1 rom1.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

; ---- RAM scratch for the debug display strings — must be RAM, not ROM
; DB data, since these are written to every keypress ----
KEY_STR    EQU $8000   ; 3 bytes: 2 hex digits + null
OFS_STR    EQU $8010
LEN_STR    EQU $8020
LAST_KEY   EQU $8030   ; 1 byte

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_INIT
    call EDITOR_INIT
    call GFX_CLS

DEBUG_LOOP:
    call IO_READ_KEY
    ld   (LAST_KEY), a               ; stash raw key code for display
                                     ; below (survives the upcoming
                                     ; sub-calls since it's in memory)
    cp   KEY_ENTER
    jr   z, DEBUG_DONE
    or   a
    jr   z, DEBUG_SHOW                ; unmapped key — still show state,
                                      ; just don't insert anything
    call EDITOR_INSERT_CHAR

DEBUG_SHOW:
    call GFX_CLS
    ld   hl, EDIT_LINE_BUF
    ld   b, 0
    ld   c, 0
    call GFX_PRINT_STRING

    ; row 2: raw key code
    ld   a, (LAST_KEY)
    ld   hl, KEY_STR
    call HEX_BYTE_TO_STR
    ld   hl, KEY_STR
    ld   b, 2
    ld   c, 0
    call GFX_PRINT_STRING

    ; row 3: EDIT_BUF_OFFSET (cursor position)
    ld   hl, (EDIT_BUF_OFFSET)
    ld   a, l
    ld   hl, OFS_STR
    call HEX_BYTE_TO_STR
    ld   hl, OFS_STR
    ld   b, 3
    ld   c, 0
    call GFX_PRINT_STRING

    ; row 4: content length — scanned independently here, not reusing
    ; kernel/editor's internal EDITOR_SCAN_LEN, so this is a genuinely
    ; separate check on the buffer's actual state
    ld   hl, EDIT_LINE_BUF
    ld   b, 0
.scan:
    ld   a, b
    cp   EDIT_LINE_BUF_LEN
    jr   z, .scan_done
    ld   a, (hl)
    or   a
    jr   z, .scan_done
    inc  hl
    inc  b
    jr   .scan
.scan_done:
    ld   a, b
    ld   hl, LEN_STR
    call HEX_BYTE_TO_STR
    ld   hl, LEN_STR
    ld   b, 4
    ld   c, 0
    call GFX_PRINT_STRING

    jr   DEBUG_LOOP

DEBUG_DONE:
    ld   a, 6                  ; yellow — session ended
    out  (PORT_ULA), a
    jr   $

; ============================================================================
; HEX_BYTE_TO_STR
; In:  A = byte value, HL = destination (3 bytes: 2 hex digits + null)
; Out: destination filled; HL unchanged (points at the same buffer)
; Destroys: AF, BC, DE
; ============================================================================
HEX_BYTE_TO_STR:
    push hl                    ; save destination pointer
    ld   b, a                   ; B = original byte (survives HEX_CHAR calls)

    ld   a, b
    and  $F0
    rrca
    rrca
    rrca
    rrca
    call HEX_CHAR
    ld   c, a                    ; C = high nibble char

    ld   a, b
    and  $0F
    call HEX_CHAR
    ld   d, a                     ; D = low nibble char

    pop  hl                        ; HL = destination (restored)
    ld   (hl), c
    inc  hl
    ld   (hl), d
    inc  hl
    xor  a
    ld   (hl), a                    ; null terminator
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

    INCLUDE "kernel/editor/editor.asm"
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_editor_debug.bin", $0000, $4000
