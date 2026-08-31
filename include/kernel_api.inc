; ============================================================================
; kernel_api.inc — public kernel entry points
;
; RULE: basic/ and any future assembly-language software call ONLY these
; labels (or the equivalents defined by other kernel/* modules as they're
; built). Nothing outside kernel/ touches hardware ports or system variable
; addresses directly. This file is the contract; docs/rom_api.md is the
; prose version of the same contract and must be kept in sync.
; ============================================================================

    IFNDEF KERNEL_API_INC
    DEFINE KERNEL_API_INC

; ---- kernel/editor (see kernel/editor/editor.asm's own header) ----
; No longer EXTERN-declared here (2026-08-22): the whole module moved
; to EXROM (rom/exrom_editor.asm) in a ROM-shrink pass, so it's no
; longer part of the Home-resident "basic/ calls kernel/ directly by
; label" contract this file exists to declare. basic/basic.asm reaches
; it instead through its own BASIC_EDITOR_*_EXROM wrappers (page in,
; call a fixed EXROM entry stub, page out) — an internal basic/
; mechanism, not a kernel API call, so it doesn't belong in this file
; any more than BASIC_SOUND_EXROM/BASIC_STRFUNC_EXROM's own targets do.

; ---- kernel/memory (see kernel/memory/memory.asm) ----
    EXTERN MEM_INIT             ; set program area + label table to empty
    EXTERN MEM_FILL_ZERO        ; HL = start, BC = count — zero-fill
    EXTERN MEM_FILL             ; HL = start, BC = count, A = fill byte
    EXTERN MEM_SHIFT_UP         ; HL = start, BC = length, DE = shift amount
    EXTERN MEM_SHIFT_DOWN       ; HL = start, BC = length, DE = shift amount
    EXTERN MEM_LINE_FIRST       ; -> HL = first statement, or 0 if empty
    EXTERN MEM_LINE_NEXT        ; HL = statement -> HL = next, or 0 if last
    EXTERN MEM_LINE_STORE       ; HL = position, DE = new statement text
    EXTERN MEM_LINE_INSERT      ; HL = position, DE = new statement text
                                 ; — inserts without replacing
    EXTERN MEM_LINE_DELETE_RANGE ; HL = first position, DE = last position
    EXTERN MEM_LABEL_LOOKUP     ; HL = name, B = name length -> DE = position
    EXTERN MEM_LABEL_ADD        ; HL = name, B = name length, DE = position
    EXTERN MEM_LABEL_REMOVE     ; HL = name, B = name length
    EXTERN MEM_LABEL_TABLE_CLEAR ; resets just the label table, leaves
                                 ; the program itself untouched
    EXTERN MEM_FREE_BYTES       ; -> HL = free bytes in the program area
                                 ; (PROG_AREA_MAX - PROG_END) — backs
                                 ; BASIC's FREE()

; ---- kernel/io (see kernel/io/io.asm) ----
    EXTERN IO_KEY_SCAN_ROW      ; A = row-select byte -> A = row state
    EXTERN IO_KEY_SCAN_ALL      ; -> HL = IO_SCAN_TABLE, filled
    EXTERN IO_ANY_KEY_DOWN      ; -> carry set if any key is down
    EXTERN IO_READ_KEY          ; blocking -> A = ASCII code (0 if unmapped)
    EXTERN IO_READ_KEY_NONBLOCK ; non-blocking -> A = ASCII code, or 0
                                 ; if nothing is currently latched —
                                 ; backs BASIC's INKEY$
    EXTERN IO_CHECK_BREAK       ; non-blocking -> carry set if CAPS
                                 ; SHIFT+SPACE (BREAK) currently held
    EXTERN STICK_READ           ; HL = device (1 or 2) -> HL = stick
                                 ; value — backs BASIC's STICK()

; ---- kernel/interrupt (see kernel/interrupt/interrupt.asm) ----
    EXTERN INT_GET_FRAMES       ; -> HL = FRAMES (free-running tick
                                 ; counter, one per real 50/60Hz
                                 ; interrupt) — backs BASIC's PAUSE <n>

; ---- kernel/graphics (see kernel/graphics/graphics.asm) ----
    EXTERN GFX_CLS              ; clear screen bitmap + attributes
    EXTERN GFX_PAINT_ATTR       ; A = attribute byte — repaints the whole
                                 ; attribute area to it, bitmap untouched
                                 ; (distinct from the GFX_FILL_ATTR
                                 ; sysvar FILL's own flood-fill uses)
    EXTERN GFX_SET_BORDER       ; A = colour (0-7) — sets the border
                                 ; via the ULA port, low 3 bits only
    EXTERN GFX_SCROLL_TEXT_UP   ; shifts the 23-row program view up one
                                 ; text row (row 22 left for the caller
                                 ; to draw) — real screen bytes, not a
                                 ; re-render
    EXTERN GFX_SCROLL_TEXT_DOWN ; mirror of GFX_SCROLL_TEXT_UP — shifts
                                 ; down one row (row 0 left for the
                                 ; caller to draw)
    EXTERN GFX_PUTCHAR          ; A = char, B = row, C = column
    EXTERN GFX_PUTCHAR_BOLD     ; A = char, B = row, C = column — bold
                                 ; (widened strokes, for highlighting)
    EXTERN GFX_PRINT_STRING     ; HL = null-terminated string, B = row, C = column
    EXTERN GFX_PRINT_STRING_ATTR ; HL = null-terminated string, B = row,
                                 ; C = column, A = attribute byte — same
                                 ; as GFX_PRINT_STRING but also sets the
                                 ; attribute cell under each character
    EXTERN GFX_INVERT_ATTR      ; B = row, C = column — cursor indicator
                                 ; (blinks, via hardware FLASH)
    EXTERN GFX_INVERT_ATTR_STATIC ; B = row, C = column — static
                                 ; inverted highlight, doesn't blink
    EXTERN GFX_SET_ATTR         ; A = attribute byte, B = row, C = column
                                 ; — sets outright, doesn't swap
    EXTERN GFX_CLEAR_ROW        ; B = row — clears just that row
                                 ; (bitmap + attribute), not the whole
                                 ; screen
    EXTERN GFX_CLEAR_ROW_TEXT   ; B = row — clears just that row's
                                 ; bitmap, leaves the attribute
                                 ; untouched
    EXTERN GFX_WRITE_PIXEL      ; B = x (0-255), C = y (0-191, caller
                                 ; clamps), A = attribute byte, D = OVER
                                 ; flag (0 = set, nonzero = XOR-toggle)
                                 ; — sets/toggles the pixel AND colors
                                 ; its covering 8x8 attribute cell
    EXTERN GFX_READ_PIXEL       ; B = x, C = y -> A = 1 if set, 0 if not
    EXTERN GFX_LINE             ; no register args — reads GFX_LINE_X0/
                                 ; Y0/X1/Y1/ATTR/OVER (sysvars.inc),
                                 ; caller fills these in first — draws
                                 ; an absolute-coordinate line via
                                 ; Bresenham's algorithm
                                 ; XMIN/XMAX/YMIN/YMAX/ATTR/OVER
                                 ; (sysvars.inc; caller normalizes
                                 ; corner order first) — fills a
                                 ; rectangle
    EXTERN GFX_CIRCLE           ; no register args — reads GFX_CIRCLE_
                                 ; XC/YC/R/ATTR/OVER (sysvars.inc) —
                                 ; draws a circle outline (midpoint
                                 ; circle algorithm)
    EXTERN GFX_FILL             ; no register args — reads GFX_FILL_X/
                                 ; Y/ATTR (sysvars.inc) — 4-connected
                                 ; flood fill from that seed point,
                                 ; using an explicit bounded stack
                                 ; (GFX_FILL_STACK, 2048 entries — see
                                 ; that sysvar's own comment for why
                                 ; that size and how it was measured)
    EXTERN GFX_SET_MODE         ; A = mode (0 = Normal, 1 = High
                                 ; Resolution Graphics) — MODE's
                                 ; mechanism; real port $FF write via
                                 ; PORT_FF_SHADOW, plus clears the
                                 ; relevant Second Display File region
                                 ; on first entry to mode 1

; ---- kernel/sound (see kernel/sound/sound.asm) ----
    EXTERN SOUND_BEEP           ; BC = pitch (per-half-cycle busy-wait
                                 ; length), DE = duration (full
                                 ; waveform cycles) — BEEP's mechanism;
                                 ; real port $FE bit 4 toggle, same
                                 ; PORT_FE_SHADOW discipline as
                                 ; GFX_SET_BORDER

; ---- kernel/math (see kernel/math/math.asm) ----
    EXTERN MATH_MULTIPLY16      ; HL = multiplicand, DE = multiplier
                                 ; -> HL = product (signed, truncated)
    EXTERN MATH_DIVIDE16        ; HL = dividend, DE = divisor
                                 ; -> HL = quotient (signed, truncated
                                 ; toward zero; 0 if DE = 0)
    EXTERN MATH_RND_SEED        ; HL = new seed (0 = reset to
                                 ; unseeded — reseeds from the Z80 R
                                 ; register on the next RND() call) —
                                 ; backs BASIC's RANDOMISE <n>

; ---- kernel/storage (see kernel/storage/storage.asm) ----
; Tape SAVE/LOAD, ported from the real TS2068 ROM's own cassette
; routines (2026-08-24) — see storage.asm's own header for the full
; protocol design and why (kernel/storage/archive/README.md covers the
; previous from-scratch design this replaced).
    EXTERN STORAGE_SEND_BLOCK   ; A = STORAGE_TYPE_HEADER or _DATA, IX =
                                 ; data pointer, DE = data length —
                                 ; sends one block: leader tone, sync,
                                 ; every byte MSB-first, trailing
                                 ; checksum. Destroys AF, AF', BC, DE,
                                 ; HL, IX.
    EXTERN STORAGE_RECEIVE_BLOCK ; A = STORAGE_TYPE_HEADER or _DATA,
                                 ; carry set on entry = load (clear =
                                 ; verify, unused by this project's own
                                 ; callers), IX = destination pointer,
                                 ; DE = expected length -> carry set =
                                 ; failure (timeout, SPACE pressed,
                                 ; wrong type, or checksum mismatch),
                                 ; carry clear = success. Destroys AF,
                                 ; AF', BC, DE, HL, IX.
    EXTERN STORAGE_SAVE         ; HL = filename pointer, B = filename
                                 ; length, IX = data pointer, DE = data
                                 ; length — builds the header, sends it
                                 ; once, then sends the data block
                                 ; TWICE (see storage.asm's own header,
                                 ; "IMPROVEMENT"). Carry always clear.
    EXTERN STORAGE_LOAD         ; IX = destination pointer, HL =
                                 ; filename to match, B = its length (0
                                 ; = wildcard, LOAD ""), DE = max
                                 ; allowed data length -> DE = actual
                                 ; data length received, A = 1 if the
                                 ; data block's backup copy was needed
                                 ; (0 = clean first-copy load). Carry
                                 ; set = total failure (no matching
                                 ; header found, header's claimed
                                 ; length exceeds the caller's bound,
                                 ; or both data copies failed).
    EXTERN STORAGE_REPORT_PROGRESS ; no input — calls STORAGE_PROGRESS_
                                 ; HOOK if one is set, so the status bar
                                 ; can be redrawn once at the start of a
                                 ; SAVE/LOAD (this ROM has no
                                 ; interrupts). Destroys nothing.

    ENDIF
