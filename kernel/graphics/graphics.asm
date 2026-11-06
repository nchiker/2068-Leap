; ============================================================================
; kernel/graphics/graphics.asm — text-mode character output
;
; CURRENT STATUS: assembled into the working ROM and exercised under
; Fuse by the automated graphics and language regression tests. Glyph
; appearance still ultimately requires visual judgment; the addressing
; and drawing paths have executable coverage.
;
; CONFIDENCE LEVELS DIFFER within this file, worth being explicit about:
;   - Screen ADDRESSING (ROW_BASE_TABLE, GFX_PUTCHAR's address math) was
;     verified NUMERICALLY with a Python script before any assembly was
;     written — the standard Spectrum-family screen layout formula was
;     checked against 576 spot-check (row, col, scanline) combinations,
;     not just hand-traced. High confidence.
;   - The FONT DATA (FONT_TABLE) has no equivalent numerical check —
;     there's no formula to verify glyph shapes against, only human
;     judgement. Each glyph was designed deliberately as ASCII art (not
;     recalled from a specific ROM's font from memory, to avoid
;     transcription errors) and visually rendered for self-review before
;     conversion to hex, but this is NOT the same confidence level as
;     the addressing math. Treat glyph shapes as needing YOUR visual
;     confirmation once actually on screen — that's the one part of
;     this file I can't self-verify at all.
;
; Owns: the screen bitmap/attribute addressing scheme, and character
; output (GFX_PUTCHAR, GFX_CLS, GFX_PRINT_STRING, GFX_INVERT_ATTR).
; FONT_TABLE covers space, 0-9, A-Z, a-z, and 32 punctuation characters
; (95 glyphs total, all of printable ASCII: " ! @ # $ % & ' ( ) : . , = + - ; / * < > ?,
; and, Q-26, [ \ ] ^ _ ` after 'Z' and { | } ~ after 'z') — grown
; as needed rather than up front. The quote character was added once
; PRINT "..." string literals made it a real blocker; most of the rest
; cover kernel/io's confirmed-confidence subset of SYMBOL SHIFT's
; punctuation table (see that module's header — the full real table is
; more complex, some keys give BASIC keyword tokens instead of symbols,
; only what's independently confirmed is implemented on either side).
; / and * were added once basic/'s expression evaluator actually needed
; them for division and multiplication — this project already shipped
; the "character typed correctly but invisible, no glyph for it" bug
; once (the quote character, early on); adding a SYMBOL SHIFT
; punctuation mapping without also adding its glyph would repeat that
; exact mistake, so both are always added together now.
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

; ---- character grid ----
GFX_ROWS   EQU 24
GFX_COLS   EQU 32
ATTR_DEFAULT EQU $38     ; PAPER 7 (white), INK 0 (black) — this
                        ; project's default attribute, used by both
                        ; GFX_CLS and GFX_CLEAR_ROW; previously a bare
                        ; $38 in just GFX_CLS, promoted to a symbolic
                        ; constant now that a second routine needs the
                        ; same value
ATTR_STATUS_BAR EQU $07   ; PAPER 0 (black), INK 7 (white) — ATTR_
                          ; DEFAULT with ink/paper swapped, i.e. what
                          ; GFX_INVERT_ATTR_STATIC would produce
                          ; starting from ATTR_DEFAULT. Verified
                          ; against GFX_ATTR_SWAP's own bit logic
                          ; (ink bits shifted into paper position,
                          ; paper bits shifted into ink position)
                          ; rather than just asserted. Used by basic/'s
                          ; status bar to set the inverted attribute
                          ; directly (GFX_SET_ATTR) instead of clear-
                          ; then-toggle (GFX_CLEAR_ROW + GFX_INVERT_
                          ; ATTR_STATIC), eliminating a briefly-visible
                          ; non-inverted intermediate state that a
                          ; two-step clear-then-toggle sequence can't
                          ; avoid — found from the user reporting a
                          ; smaller, but still-present, flash even
                          ; after the toggle bug itself was fixed

; Status bar branding swatch — three solid-color cells in the status
; bar's reserved right-hand columns, echoing the red/green/blue bars
; under the real TS2068's "PERSONAL COLOR COMPUTER" logo. PAPER-only
; (INK bits left 0/black) since these attributes are applied to blank
; (space) cells — with no set pixels, only PAPER ever shows, so INK is
; irrelevant here. Standard Spectrum-family color numbering: 1=blue,
; 2=red, 4=green.
ATTR_SWATCH_RED   EQU $10   ; PAPER 2 (red),   INK 0
ATTR_SWATCH_GREEN EQU $20   ; PAPER 4 (green), INK 0
ATTR_SWATCH_BLUE  EQU $08   ; PAPER 1 (blue),  INK 0

BORDER_DEFAULT  EQU 7     ; white — matches ATTR_DEFAULT's white PAPER,
                          ; so a freshly-reset screen has a consistent
                          ; white background top to bottom, border
                          ; included. Used by basic/'s cold-boot setup
                          ; and NEW (both real "start fresh" moments) —
                          ; deliberately NOT applied by GFX_CLS itself,
                          ; since real Sinclair BASIC's CLS clears only
                          ; the text screen and never touches the
                          ; border; folding a border reset into GFX_CLS
                          ; would incorrectly wipe a program's own
                          ; BORDER setting on every ordinary mid-program
                          ; CLS statement, not just at a genuine reset

; ============================================================================
; GFX_CLS
; Clears the screen bitmap to all-off and the attribute area to a
; default (white paper, black ink — INK 0, PAPER 7 = $38).
; In:  none
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_CLS:
    call GFX_SPRITE_INVALIDATE
    ld   hl, SCREEN_ADDR
    ld   de, SCREEN_ADDR + 1
    ld   bc, 6144 - 1           ; bitmap is 6144 bytes ($4000-$57FF)
    xor  a
    ld   (hl), a
    ldir

    ld   a, ATTR_DEFAULT           ; PAPER 7, INK 0 — falls straight
                                   ; into GFX_PAINT_ATTR below for the
                                   ; actual attribute-area fill, same
                                   ; loop, no ROM-budget cost for
                                   ; duplicating it here
; ============================================================================
; GFX_PAINT_ATTR
; Paints the whole attribute area (all 24 rows x 32 columns) to one
; caller-supplied attribute byte — the bitmap itself is untouched, so
; this is purely a re-color, not a clear. GFX_CLS falls straight through
; into this same code (having just set A = ATTR_DEFAULT) rather than
; duplicating the loop, so GFX_CLS's own contract (always resets to
; white paper/black ink, matching its existing callers throughout this
; project) is unchanged for every caller that only ever calls GFX_CLS;
; this label just gives BASIC_STMT_CLS a way to follow a real GFX_CLS
; with a repaint to whatever CURRENT_INK/CURRENT_PAPER (etc.) actually
; says, without touching GFX_CLS's own behavior.
; In:  A = attribute byte to fill every cell with
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_PAINT_ATTR:
    ld   hl, ATTR_ADDR
    ld   de, ATTR_ADDR + 1
    ld   bc, 768 - 1
    ld   (hl), a
    ldir
    ret

; ============================================================================
; GFX_SPRITE_INVALIDATE
; Forget displayed/save-under state before a global screen transformation.
; Captured images and dimensions remain defined and may be SHOWn again.
; In: none
; Out: SPRITE_SLOT_SHOWN[0..7]=0, SPRITE_DISPLAY_DEPTH=0
; Destroys: AF, B, HL
; ============================================================================
GFX_SPRITE_INVALIDATE:
    xor  a
    ld   hl, SPRITE_SLOT_SHOWN
    ld   b, SPRITE_SLOT_MAX
.loop:
    ld   (hl), a
    inc  hl
    djnz .loop
    ld   (SPRITE_DISPLAY_DEPTH), a
    ret

; ============================================================================
; GFX_ROW_BASE_ADDR
; Looks up a text row's bitmap base address (scanline 0, column 0) —
; same ROW_BASE_TABLE[row] lookup GFX_PUTCHAR/GFX_CHAR_SETUP already do
; inline, factored out here so GFX_SCROLL_TEXT_UP/_DOWN (via GFX_COPY_
; ROW_BITMAP) don't duplicate it a third time.
; In:  A = row (0-23, caller's responsibility — no bounds check)
; Out: HL = that row's bitmap base address
; Destroys: AF, DE
; ============================================================================
GFX_ROW_BASE_ADDR:
    ld   h, 0
    ld   l, a
    add  hl, hl                    ; row * 2 (2 bytes per table entry)
    ld   de, ROW_BASE_TABLE
    add  hl, de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    ret

; ============================================================================
; GFX_SCROLL_OUTPUT_UP
; Scrolls all 24 program-output rows up one text row (PRINT, INPUT's echo
; and the newline after a PRINT at the bottom), then clears the new bottom
; row (GFX_CLEAR_ROW: the default attribute, a blank bitmap).
; 5.11 (back-port plan): a scanline of the 23 rows that move is one stream
; through the three screen thirds -- rows 1-7 -> 0-6 inside third 0 (224
; contiguous bytes), row 8 -> 7 across to it (32), rows 9-15 -> 8-14, row
; 16 -> 15, rows 17-23 -> 16-22 -- copied 16 bytes at a time by unrolled
; LDIs (16 T a byte, LDIR's 21), for each of the 8 scanlines; the 23 rows'
; attributes (linear memory) the same way. It was 23 GFX_COPY_ROW_BITMAP
; calls, each 8 LDIRs of 32 bytes. Copies forward (each destination below
; its source), as a memmove must.
; In:  none
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_SCROLL_OUTPUT_UP:
    call GFX_SPRITE_INVALIDATE
    ld   hl, ATTR_ADDR + 32         ; rows 1-23's attributes -> rows 0-22
    ld   de, ATTR_ADDR
    ld   a, 23*32/16
    call .ldi16
    ld   hl, SCREEN_ADDR + 32       ; scanline 0 of row 1
    ld   de, SCREEN_ADDR            ; ... of row 0
.third:                             ; HL, DE on this scanline of a third
    ld   a, 7*32/16                 ; its rows 1-7 -> 0-6
    call .ldi16
    ld   a, h                       ; HL = this third's next scanline:
    cp   HIGH (SCREEN_ADDR + $1100) ; past the last third's ($51-$58)?
    jr   nc, .scanline_done
    add  a, 7                       ; HL -> the next third's row 0
    ld   h, a
    ld   a, 32/16                   ; -> this third's row 7
    call .ldi16
    ld   a, d                       ; DE -> the next third's row 0
    add  a, 7
    ld   d, a
    jr   .third
.scanline_done:                     ; HL = third 2's scanline + 256,
    sub  $10                        ; DE = third 2's row 7 of this scanline
    ld   h, a
    ld   l, 32                      ; HL -> row 1 of the next scanline
    ld   a, d
    sub  $0F
    ld   d, a
    ld   e, 0                       ; DE -> row 0 of the next scanline
    cp   HIGH (SCREEN_ADDR + $0800)
    jr   c, .third                  ; until all 8 scanlines are done
    ld   b, 23
    jp   GFX_CLEAR_ROW
.ldi16:                             ; A x 16 bytes (HL) -> (DE), ascending
    REPT 16
    ldi
    ENDR
    dec  a
    jr   nz, .ldi16
    ret

    IFNDEF V2_PRODUCTION          ; 5.11: unused by the V2 images (GFX_SCROLL_OUTPUT_UP above copies itself)
; ============================================================================
; GFX_COPY_ROW_BITMAP
; Copies one text row's entire 8-scanline bitmap (256 bytes total) from
; one row to another. Non-linear addressing (see ROW_BASE_TABLE's own
; header) means this can't be a single LDIR — each of the 8 scanlines
; lives 256 bytes apart, so it's 8 separate 32-byte block copies,
; stepping both the source and destination base by 256 (one scanline)
; each time. Attribute memory IS linear ($5800 + row*32 + col), so
; GFX_SCROLL_TEXT_UP/_DOWN move it separately, in one shot, rather than
; needing this routine's own per-scanline approach.
; In:  (GFX_SCROLL_DST_ROW), (GFX_SCROLL_SRC_ROW) already set by the
;      caller
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_COPY_ROW_BITMAP:
    ld   a, (GFX_SCROLL_DST_ROW)
    call GFX_ROW_BASE_ADDR          ; HL = dst row base
    push hl
    ld   a, (GFX_SCROLL_SRC_ROW)
    call GFX_ROW_BASE_ADDR          ; HL = src row base
    pop  de                         ; DE = dst row base
    ld   b, 8                       ; 8 scanlines per text row
.scanline_loop:
    push bc
    push hl
    push de
    ld   bc, 32
    ldir
    pop  de
    pop  hl
    ld   a, h                       ; advance both base addresses by
    inc  a                          ; 256 (one scanline) — restoring
    ld   h, a                       ; the PRE-ldir bases from the stack
    ld   a, d                       ; above, then bumping the high byte,
    inc  a                          ; rather than trusting whatever
    ld   d, a                       ; ldir itself left HL/DE pointing at
    pop  bc
    djnz .scanline_loop
    ret

; ============================================================================
; GFX_SCROLL_TEXT_UP
; Scrolls the 23-row program-listing window (rows 0-22 — row 23 is
; always the separately-drawn status line, never touched here) up by
; exactly one text row: row 1's content becomes row 0's, row 2's
; becomes row 1's, ... row 22's becomes row 21's. Row 22 itself is left
; UNTOUCHED — the caller draws whatever newly-scrolled-into-view
; content belongs there. Moves real screen bytes (bitmap + attributes)
; instead of re-rendering characters, so this is much cheaper than a
; full BASIC_REDRAW_PROGRAM pass for the common "scroll by one line"
; case — see BASIC_REDRAW_PROGRAM's own use of this.
;
; Row-pair copies are processed in ASCENDING destination order (0, 1,
; 2, ...) deliberately: row 1's original content must be read (as the
; source for dst=0) before it's overwritten (as the destination when
; dst=1) — the classic memmove "copy forward when dst < src" rule.
; In:  none
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_SCROLL_TEXT_UP:
    call GFX_SPRITE_INVALIDATE
    ld   hl, ATTR_ADDR + 32          ; row 1's attributes (linear memory
    ld   de, ATTR_ADDR               ; — the whole 22-row block moves in
    ld   bc, 22*32                   ; one shot, no per-row loop needed)
    ldir

    xor  a
    ld   (GFX_SCROLL_DST_ROW), a
.row_loop:
    ld   a, (GFX_SCROLL_DST_ROW)
    inc  a
    ld   (GFX_SCROLL_SRC_ROW), a
    call GFX_COPY_ROW_BITMAP
    ld   a, (GFX_SCROLL_DST_ROW)
    inc  a
    ld   (GFX_SCROLL_DST_ROW), a
    cp   22
    jr   c, .row_loop
    ret

    ENDIF

; ============================================================================
; GFX_SCROLL_TEXT_DOWN
; Mirror of GFX_SCROLL_TEXT_UP: scrolls rows 0-22 DOWN by one text row
; instead — row 0's content becomes row 1's, ... row 21's becomes
; row 22's. Row 0 itself is left UNTOUCHED for the caller to draw.
;
; Row-pair copies are processed in DESCENDING destination order (22,
; 21, ..., 1) for the same memmove reasoning as GFX_SCROLL_TEXT_UP's
; own header, mirrored: row 21's content must be read (as the source
; for dst=22) before it's overwritten (as the destination when
; dst=21) — "copy backward when dst > src".
; In:  none
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
    IFNDEF V2_PRODUCTION          ; RC: unused by the V2 images (legacy builds keep it)
GFX_SCROLL_TEXT_DOWN:
    call GFX_SPRITE_INVALIDATE
    ld   hl, ATTR_ADDR + 22*32 - 1   ; last byte of rows 0-21 (source)
    ld   de, ATTR_ADDR + 23*32 - 1   ; last byte of rows 1-22 (dest) —
    ld   bc, 22*32                   ; overlapping, dst > src, needs the
    lddr                             ; backward-copying LDDR, not LDIR

    ld   a, 22
    ld   (GFX_SCROLL_DST_ROW), a
.row_loop:
    ld   a, (GFX_SCROLL_DST_ROW)
    dec  a
    ld   (GFX_SCROLL_SRC_ROW), a
    call GFX_COPY_ROW_BITMAP
    ld   a, (GFX_SCROLL_DST_ROW)
    dec  a
    ld   (GFX_SCROLL_DST_ROW), a
    jr   nz, .row_loop
    ret
    ENDIF

; ============================================================================
; GFX_SET_BORDER
; Sets the screen border colour via the ULA port ($FE) — same
; Spectrum-family hardware convention every other screen routine in
; this file already assumes (see GFX_CLS's attribute-byte layout for
; the sibling INK/PAPER encoding). Only bits 0-2 of the port select
; the border colour; the EAR/MIC bits (used by kernel/storage's tape
; routines) live higher up in the same byte and must NOT be
; disturbed here. REAL BUG FOUND AND FIXED: this used to just mask
; its own colour and write straight to the port, silently zeroing
; bits 3+ every time — the comment promised not to disturb EAR/MIC
; but there was no shadow anywhere for it to preserve them FROM, so
; the promise wasn't actually kept. Now reads PORT_FE_SHADOW
; (updated by both this routine and STORAGE_PULSE), replaces only
; the colour bits, and writes the merged byte back to both the port
; and the shadow.
; In:  A = colour (0-7; only the low 3 bits are used, same 0=black..
;      7=white encoding as every other colour value in this project)
; Out: none
; Destroys: AF, B (B holds the colour bits while the shadow byte is
;      read and merged — checked against all three current call
;      sites, none rely on B surviving, but this must stay accurate
;      for any future caller)
; ============================================================================
GFX_SET_BORDER:
    and  $07                     ; keep only the colour bits — never
                                 ; let stray high bits from the
                                 ; caller reach EAR/MIC
    ld   b, a                    ; stash the new colour bits
    ld   a, (PORT_FE_SHADOW)
    and  $F8                     ; clear the old colour bits, keep
                                 ; everything else (EAR/MIC) as-is
    or   b
    ld   (PORT_FE_SHADOW), a
    out  (PORT_ULA), a
    ret

; ============================================================================
; GFX_CHAR_TO_FONT_OFFSET
; Translates an ASCII character to an absolute pointer to its 8-byte
; glyph bitmap. Despite the name (kept for callers/history), this no
; longer always returns a FONT_TABLE offset — codes 128-143 (block
; graphics) and 144-164 (UDGs) resolve to RAM instead of ROM, so the
; FONT_TABLE base is now folded in here rather than left for the
; caller to add, uniformly across every case (2026-08-22, added
; alongside block-graphics/UDG support).
; In:  A = ASCII character
; Out: carry clear + HL = absolute pointer to the character's 8-byte
;      glyph (FONT_TABLE+offset for ROM glyphs, BLOCK_GFX_SCRATCH for
;      a freshly-generated block-graphics glyph, or UDG_TABLE+offset
;      for a UDG); carry set if the character has no glyph at all
;      (caller's choice what to do — GFX_PUTCHAR treats it as a space)
; Destroys: AF, BC, E, HL — B is NOT preserved (the block-graphics path
;      counts in it; the punctuation scan before 5.14 did too). This was documented wrong
;      for a while (claimed only AF/HL) and caused a real bug in
;      GFX_PUTCHAR, which read B (its row parameter) after this call
;      without saving it first — fixed in GFX_PUTCHAR by protecting BC
;      around this call, not by changing what this routine touches.
;      E is also not preserved: it holds a scratch copy of the input
;      character throughout (see the routine's own first instruction),
;      not whatever the caller had there — this was also previously
;      undocumented (found via cross-project research comparing this
;      routine against a sibling project's own corrected copy of the
;      same lineage, 2026-09-13). D itself is never touched.
; ============================================================================
GFX_CHAR_TO_FONT_OFFSET:
    ; 5.14 (back-port plan): space, the digits and the punctuation from '!' to
    ; '@' through one direct index table (LOW_CHAR_TABLE), the letters by
    ; arithmetic; was a chain of range tests and a linear scan of (char,
    ; index) pairs (439 T for '.', ~1,100 for a code with no glyph). Q-26: the
    ; font has '[' to '`' after 'Z' and '{' to '~' after 'z', so the same
    ; arithmetic covers them.
    ld   e, a                      ; E = the code (the block-graphics path
                                   ; reads it)
    sub  " "
    cp   "@" - " " + 1
    jr   c, .low_table             ; ' '..'@': A = code - ' '
    sub  "a" - " "
    cp   "~" - "a" + 1
    jr   c, .is_lower              ; 'a'..'~': A = code - 'a'
    add  a, "a" - "A"
    cp   "`" - "A" + 1
    jr   c, .is_upper              ; 'A'..'`': A = code - 'A'
    ld   a, e
    cp   128
    jr   c, .not_found              ; 0-31 and 127
    cp   UDG_CODE_BASE                  ; 144
    jr   c, .is_block_graphics          ; 128-143
    cp   UDG_CODE_BASE + UDG_COUNT      ; 165
    jr   c, .is_udg                     ; 144-164
.not_found:                             ; 165+ too
    scf
    ret

.low_table:
    ld   hl, LOW_CHAR_TABLE
    add  a, l
    ld   l, a                      ; (the table does not cross a page)
    ld   a, (hl)                   ; the font index
    jr   .to_offset
.is_lower:
    add  a, 43                     ; 43-72 = 'a'..'~'
    jr   .to_offset
.is_upper:
    add  a, 11                     ; 0 space, 1-10 digits, 11-42 'A'..'`'
.to_offset:
    add  a, a                      ; index x 2 (indices <= 94: fits)
    ld   l, a
    ld   h, 0
    add  hl, hl                    ; x 4
    add  hl, hl                    ; x 8
    ld   bc, FONT_TABLE             ; an absolute pointer from every path
    add  hl, bc                     ; (carry clear: no overflow)
    ret

.is_block_graphics:
    ; Codes 128-143: the glyph is built in BLOCK_GFX_SCRATCH, top half
    ; first. Each half is four identical rows made from two bits of the
    ; code: the low bit selects the right-hand nibble ($0F), the next bit
    ; the left ($F0); E moves down two bits between halves (top = bits
    ; 1,0 of the code, bottom = bits 3,2). Clean-room code from 2068-
    ; Leap-C (its delta D21), written from the screen format alone; it
    ; replaced a version containing the stock ROM's PO-GR-2 sequence
    ; (back-port plan item 1.3). Destroys E, as the service slot's
    ; contract already allows.
    ld   hl, BLOCK_GFX_SCRATCH
    ld   b, 2                        ; two halves
.bg_half:
    ld   a, e
    rra                              ; carry = right quarter
    sbc  a, a                        ; $FF if ink, else $00
    and  $0F
    ld   c, a                        ; right nibble
    ld   a, e
    rra
    rra                              ; carry = left quarter
    sbc  a, a
    and  $F0
    or   c                           ; A = row pattern for this half
    ld   c, 4
.bg_row:
    ld   (hl), a
    inc  hl
    dec  c
    jr   nz, .bg_row
    srl  e
    srl  e                           ; next pair of quarters
    djnz .bg_half
    ld   hl, BLOCK_GFX_SCRATCH
    or   a                           ; carry clear = success
    ret

.is_udg:
    ; Codes 144-164: real hardware stores these as plain RAM, POKE-
    ; defined (PO-T&UDG in the disassembly) — no font data lives in
    ; ROM at all for this range. UDG_TABLE + (code-UDG_CODE_BASE)*8,
    ; same offset math as the ROM FONT_TABLE case above.
    ld   a, e
    sub  UDG_CODE_BASE
    ld   l, a
    ld   h, 0
    add  hl, hl                        ; x2
    add  hl, hl                        ; x4
    add  hl, hl                        ; x8
    ld   bc, UDG_TABLE
    add  hl, bc
    or   a
    ret


; ============================================================================
; GFX_CHAR_SETUP (internal — not in kernel_api.inc)
; Shared address computation for GFX_PUTCHAR and GFX_PUTCHAR_BOLD —
; written once here rather than duplicated in both, given how much
; trouble duplicated addressing logic has already caused in this
; project (the GFX_PUTCHAR/GFX_CHAR_TO_FONT_OFFSET row-clobbering bug).
; Screen addressing verified numerically (see file header) —
; ROW_BASE_TABLE gives the bitmap address of (row, col=0, scanline=0);
; column adds 1 per column (verified), and each scanline down within a
; character adds 256 to the address (verified).
;
; Bounds-checks row/col itself now — previously didn't (this exact gap
; is what let `BASIC_PRINT_LINE_HIGHLIGHTED`'s own missing check corrupt
; memory for any LIST line >=32 columns; that call site got its own fix
; at the time, but this shared routine — PRINT's real runtime path, not
; just LIST's redraw — never did, and a >=32-column PRINT string would
; still walk column past 31 here with nothing to catch it). A caller
; that hits this now gets carry set and simply doesn't draw that
; character, rather than writing past the intended row's own memory
; into whatever's adjacent — same "silently clip rather than corrupt"
; precedent GFX_PLOT_CLIPPED already established for pixel graphics.
; In:  A = ASCII character, B = row (0-23), C = column (0-31)
; Out: carry clear + HL = pointer to the glyph's 8 font bytes, DE =
;      screen address of the character cell's top-left pixel; carry
;      set (HL/DE undefined) if row>=24 or col>=32 — caller must not
;      draw in that case
; Destroys: AF, BC
; ============================================================================
GFX_CHAR_SETUP:
    ld   d, a                      ; stash the character — A is about
                                   ; to be scratch for the bounds check
    ld   a, b
    cp   24
    jr   nc, .out_of_range
    ld   a, c
    cp   32
    jr   nc, .out_of_range
    ld   a, d                      ; restore the character
    push bc                        ; preserve row/col — GFX_CHAR_TO_
                                   ; FONT_OFFSET's punctuation-table
                                   ; scan uses B as its own loop counter
                                   ; internally, which clobbered the row
                                   ; parameter for any punctuation
                                   ; character before this was fixed —
                                   ; see docs/v1/programmers_reference.md's
                                   ; kernel/graphics "Bugs caught" entry
    call GFX_CHAR_TO_FONT_OFFSET
    jr   nc, .have_offset
    ld   hl, FONT_TABLE             ; unmapped character -> render as
                                    ; space (index 0, now an absolute
                                    ; pointer like every other case —
                                    ; see GFX_CHAR_TO_FONT_OFFSET's
                                    ; header, 2026-08-22)
.have_offset:
    pop  bc                          ; restore row/col
    push hl                            ; save glyph pointer

    ; row_base = ROW_BASE_TABLE[B] (2 bytes per entry)
    ld   a, b
    call GFX_ROW_BASE_ADDR
    ex   de, hl                       ; DE = row_base
    ld   a, c
    add  a, e
    ld   e, a
    jr   nc, .no_carry
    inc  d
.no_carry:                             ; DE = row_base + column

    pop  hl                                ; HL = pointer to this
                                          ; glyph's 8 bytes — already
                                          ; absolute (GFX_CHAR_TO_FONT_
                                          ; OFFSET folds in FONT_TABLE/
                                          ; UDG_TABLE/BLOCK_GFX_SCRATCH
                                          ; itself now, 2026-08-22)
    or   a                                ; explicitly clear carry —
                                          ; success
    ret

.out_of_range:
    scf
    ret

; ============================================================================
; GFX_PUTCHAR
; Plots one character at a given character-grid position.
; In:  A = ASCII character, B = row (0-23), C = column (0-31)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_PUTCHAR:
    call GFX_CHAR_SETUP
    ret  c                                 ; out of range — GFX_CHAR_
                                          ; SETUP's own bounds check;
                                          ; silently don't draw rather
                                          ; than write past the
                                          ; intended row's memory
    ld   b, 8                              ; 8 scanlines
.scanline_loop:
    ld   a, (hl)                            ; A = this scanline's font byte
    ex   de, hl                              ; HL = screen address, DE = font ptr
    ld   (hl), a                              ; write font byte to screen
    inc  h                                     ; screen address += 256 (next
                                              ; scanline — verified this is
                                              ; exactly +256, see file header)
    ex   de, hl                                ; HL = font ptr, DE = screen
                                              ; address (advanced)
    inc  hl                                    ; advance font ptr to next byte
    djnz .scanline_loop
    ret

; ============================================================================
; GFX_PUTCHAR_BOLD
; Plots one character with a synthesized bold effect: each scanline
; byte is ORed with itself shifted right by one pixel (via RRCA),
; widening every stroke by a pixel rather than needing a whole second
; font. Verified numerically against representative font bytes before
; writing this — separated strokes (like 'A''s legs) stay separated,
; just each a pixel wider; solid bars extend cleanly; space stays
; blank. Used for keyword highlighting in the editor.
; In:  A = ASCII character, B = row (0-23), C = column (0-31)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_PUTCHAR_BOLD:
    call GFX_CHAR_SETUP
    ret  c                                 ; out of range — see
                                          ; GFX_PUTCHAR's own comment
    ld   b, 8
.scanline_loop:
    ld   a, (hl)
    ld   c, a                    ; C = original byte — B is the scanline
                                 ; counter here, not the row parameter
                                 ; anymore (GFX_CHAR_SETUP already
                                 ; consumed that), so C is free to use
    rrca                          ; shift right 1, wrapping bit0 into
                                 ; bit7 — harmless here since font bytes
                                 ; only use their top 5 bits, bit0 is
                                 ; always 0 in every glyph we have
    or   c                         ; OR with the original -> widened stroke
    ex   de, hl
    ld   (hl), a
    inc  h
    ex   de, hl
    inc  hl
    djnz .scanline_loop
    ret

; ============================================================================
; GFX_PRINT_STRING
; Prints a null-terminated string starting at a character-grid position,
; advancing one column per character. Does not wrap at end of line or
; scroll — caller's responsibility to stay in bounds (TODO for a real
; PRINT statement implementation later).
; In:  HL = pointer to null-terminated string, B = row, C = column
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_PRINT_STRING:
.loop:
    ld   a, (hl)
    or   a
    ret  z
    push hl
    push bc                  ; GFX_PUTCHAR destroys BC entirely (see its
                             ; own header) — without saving it here, the
                             ; row in B would be garbage after the first
                             ; character, corrupting every one after it.
                             ; Caught by checking GFX_PUTCHAR's contract
                             ; against what this loop assumed, not by
                             ; running it.
    call GFX_PUTCHAR
    pop  bc
    pop  hl
    inc  hl
    inc  c
    jr   .loop

; ============================================================================
; GFX_PRINT_STRING_ATTR
; Prints a null-terminated string with BASIC-style attributes (PRINT, and
; INPUT's echo). At column 32 it wraps; past row 23 it scrolls all 24
; output rows and continues on the newly cleared bottom row. Every printed
; cell gets the given attribute byte (INK/PAPER/BRIGHT/FLASH, with INVERSE
; already folded in by the caller); OVER 1 XORs the glyph into the cell.
; The other text callers (HELP, messages, the editor) use GFX_PRINT_STRING
; and keep the cell's attribute.
;
; 5.13 (back-port plan): the screen and attribute addresses are worked out
; once per row and stepped along it, and the glyph's 8 bytes copied
; unrolled (was GFX_PUTCHAR and GFX_SET_ATTR per character: both
; addresses and both range checks each time). A position off the screen
; (row >= 24 or column >= 32: only a POKE of VM_OUTPUT_ROW/COL makes one)
; draws nothing and steps on a character at a time, as before.
; PRINT_ATTR_SCRATCH and PRINT_OVER_SCRATCH are RAM cells (sysvars.inc):
; a `DB` "variable" in this file would be ROM, and a write to it lost (a
; real, shipped bug of an earlier version: every PRINT came out $00).
; In:  HL = pointer to null-terminated string, B = row, C = column,
;      A = attribute byte to set at every printed cell, D = OVER flag
; Out: B/C = row/column immediately after the final character
; Destroys: AF, BC, DE, HL, BC', DE', HL'
; ============================================================================
GFX_PRINT_STRING_ATTR:
    ld   (PRINT_ATTR_SCRATCH), a
    ld   a, d
    ld   (PRINT_OVER_SCRATCH), a
.top:
    ld   a, (hl)
    or   a
    ret  z
    ld   a, b
    cp   24
    jr   nc, .off_screen
    ld   a, c
    cp   32
    jr   c, .run
.off_screen:                        ; nothing drawn; the column moves on
    inc  hl
    inc  c
    ld   a, c
    cp   32
    jr   c, .top
.wrap:
    ld   c, 0
    inc  b
    ld   a, b
    cp   24
    jr   c, .top
    push hl
    call GFX_SCROLL_OUTPUT_UP
    pop  hl
    ld   b, 23
    ld   c, 0
    jr   .top
.run:
    ; a run of characters along row B from column C: B' = the columns left
    ; in the row, C' = the attribute, D' = the row, HL' -> the attribute
    ; cell; DE -> the cell's scanline 0, HL -> the text
    push hl
    ld   a, b
    call GFX_ROW_BASE_ADDR          ; HL = the row's scanline 0, column 0 (BC survives)
    ld   a, l
    add  a, c                       ; (row bases are $xx00-$xxE0: no carry)
    ld   l, a
    push hl
    call GFX_CELL_ATTR_ADDR         ; HL -> the attribute (in range: NC; BC survives)
    ld   a, 32
    sub  c
    push hl
    push bc
    exx
    pop  de                         ; D' = the row
    pop  hl
    ld   b, a
    ld   a, (PRINT_ATTR_SCRATCH)
    ld   c, a
    exx
    pop  de
    pop  hl
.char:
    ld   a, (hl)
    or   a
    jr   z, .run_end
    inc  hl
    push hl
    push de
    call GFX_CHAR_TO_FONT_OFFSET    ; HL -> the glyph (destroys BC, E)
    jr   nc, .glyph
    ld   hl, FONT_TABLE             ; no glyph: a space
.glyph:
    pop  de
    ld   a, (PRINT_OVER_SCRATCH)
    or   a
    jr   nz, .over
    REPT 7
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  d                          ; next scanline (+256)
    ENDR
    ld   a, (hl)
    ld   (de), a
.drawn:
    ld   a, d
    sub  7
    ld   d, a
    inc  e                          ; the next cell
    pop  hl
    exx
    ld   (hl), c                    ; its attribute
    inc  hl
    dec  b
    exx
    jr   nz, .char
    exx
    ld   a, d                       ; column 32: the row is full
    exx
    ld   b, a
    jr   .wrap
.over:                              ; OVER 1: XOR the glyph in
    ld   b, 7
.over_line:
    ld   a, (de)
    xor  (hl)
    ld   (de), a
    inc  hl
    inc  d
    djnz .over_line
    ld   a, (de)
    xor  (hl)
    ld   (de), a
    jr   .drawn
.run_end:                           ; the end of the text inside the row
    exx
    ld   a, 32
    sub  b
    ld   e, a                       ; the column
    push de                         ; D = the row
    exx
    pop  bc
    ret

; ============================================================================
; GFX_ATTR_SWAP (internal — not in kernel_api.inc)
; Shared address computation and ink/paper bit-swap for
; GFX_INVERT_ATTR and GFX_INVERT_ATTR_STATIC — written once here rather
; than duplicated in both, given how much trouble duplicated addressing
; logic has already caused in this project. The bit-swap instruction
; sequence was verified numerically against all 256 possible attribute
; byte values before being trusted — see docs/v1/programmers_reference.md's
; kernel/graphics section.
;
; REAL BUG FOUND AND FIXED (word-wrap cursor investigation): this had
; no bounds check at all, unlike GFX_SET_ATTR's own row*32+col address
; computation (see that routine's own comment — it already documents
; this exact class of gap). EDITOR_WRAP_OFFSET_TO_ROWCOL (kernel/
; editor) legitimately returns column 32 — one past the valid 0-31
; range — whenever the cursor sits exactly at the end of a full 32-
; character wrapped row (a real, ordinary case, not a rare edge
; condition: it happens on every line whose content is ever an exact
; multiple of 32 chars at the cursor's position). Column 32 fed
; straight into row*32+col addressing lands exactly on (row+1,
; column 0) instead — one cell into the START of the next physical
; screen row, silently corrupting whatever's shown there. Traced from
; a real debug.bin dump (word-wrap "phantom cursor block" report):
; row+1's bitmap was blank (correctly cleared) but its column-0
; attribute byte was stuck inverted — exactly what an out-of-range
; write here produces, and exactly why it persisted even after the
; row's own leftover-row cleanup ran earlier in the same redraw pass
; (this call happens AFTER that cleanup, re-dirtying the cell it had
; just cleared). Fixed with the same bounds check GFX_SET_ATTR already
; has, returning early with carry SET on out-of-range — both callers
; below now check `ret c` immediately after this call, before doing
; anything else, so an out-of-range request is a clean no-op instead
; of a silent corruption, matching this project's now-consistent "clip
; rather than corrupt" answer to this class of bug.
; In:  B = row (0-23), C = column (0-31)
; Out: HL = address of the attribute byte, A = swapped ink/paper with
;      FLASH/BRIGHT preserved unchanged (caller decides whether to
;      force FLASH on before writing it back). Carry SET and nothing
;      else valid if B/C were out of range — caller must check this
;      before using HL/A.
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_ATTR_SWAP:
    call GFX_CELL_ATTR_ADDR
    ret  c

    ld   a, (hl)
    ld   b, a                     ; B = original attribute byte

    and  %00000111                 ; A = ink bits (low position)
    rlca
    rlca
    rlca                             ; shift into paper's bit position
    ld   c, a                         ; C = ink bits, now in paper position

    ld   a, b
    and  %00111000                     ; A = paper bits
    rrca
    rrca
    rrca                                 ; shift into ink's bit position
    or   c                                ; combine with the shifted ink
    ld   c, a                              ; C = swapped ink/paper (bits 5-0)

    ld   a, b
    and  %11000000                          ; A = FLASH/BRIGHT, unchanged
    or   c                                    ; A = swapped attribute,
                                             ; FLASH/BRIGHT as they were
    or   a                                    ; explicit carry clear —
                                             ; the last op above (or) is
                                             ; already guaranteed to
                                             ; clear carry, but spelled
                                             ; out for anyone reading
                                             ; this contract without
                                             ; re-deriving it
    ret

; ============================================================================
; GFX_INVERT_ATTR
; Swaps ink and paper in the attribute byte at one character cell AND
; sets the hardware FLASH bit — the ULA itself then auto-blinks that
; cell between inverted and normal colors, ~1.5Hz, entirely in hardware.
; No interrupt or timer code needed on our end (kernel/interrupt doesn't
; exist yet, but this doesn't need it) — offloading blink timing to the
; ULA is the standard Spectrum-family way to do this. Used as the
; editor's cursor indicator specifically — for a STATIC inverted
; highlight that shouldn't blink (e.g. a status bar), use
; GFX_INVERT_ATTR_STATIC instead. Using this routine for
; basic/'s new status line by mistake was a real bug: the whole status
; bar inherited the cursor's blink, which is why it appeared to
; "flash" — caught from a screenshot and fixed by splitting this
; routine's address/swap logic out into GFX_ATTR_SWAP so both variants
; share it rather than duplicating it.
; In:  B = row (0-23), C = column (0-31)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_INVERT_ATTR:
    call GFX_ATTR_SWAP
    ret  c                                    ; out of range — GFX_ATTR_
                                             ; SWAP's own bounds check
                                             ; already fired; nothing to
                                             ; write, HL/A aren't valid
    or   %10000000                            ; force FLASH on — the ULA
                                             ; hardware itself blinks any
                                             ; cell with this bit set,
                                             ; ~1.5Hz, entirely in
                                             ; hardware — no interrupt or
                                             ; timer code needed on our
                                             ; end at all. Combined with
                                             ; the ink/paper swap above,
                                             ; this alternates between
                                             ; inverted and normal colors
                                             ; automatically.
    ld   (hl), a
    ret

; ============================================================================
; GFX_INVERT_ATTR_STATIC
; Same ink/paper swap as GFX_INVERT_ATTR, WITHOUT forcing the hardware
; FLASH bit — a genuinely static inverted highlight, for things like a
; status bar that should stand out visually but not blink like the
; cursor does. FLASH is left exactly as it already was at that cell
; (normally off, since nothing else sets it) rather than forced either
; way.
; In:  B = row (0-23), C = column (0-31)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
    IFNDEF V2_PRODUCTION          ; RC: unused by the V2 images (legacy builds keep it)
GFX_INVERT_ATTR_STATIC:
    call GFX_ATTR_SWAP
    ret  c                                    ; out of range — see
                                             ; GFX_INVERT_ATTR's own
                                             ; identical check just above
    ld   (hl), a
    ret
    ENDIF

; ============================================================================
; GFX_SET_ATTR
; Sets the attribute byte at one character cell to a specific value
; outright — unlike GFX_INVERT_ATTR/GFX_INVERT_ATTR_STATIC, which swap
; ink/paper relative to whatever's already there, this replaces it.
; Built for red-highlighted error lines (basic/'s
; BASIC_REDRAW_PROGRAM), but deliberately general — any caller that
; needs a specific, known color at a specific cell can use this rather
; than reasoning about what to swap from.
;
; Duplicates the same small address-computation sequence
; GFX_ATTR_SWAP already has (row*32+col+ATTR_ADDR), rather than
; refactoring that already-working routine to share it — the
; computation is short enough (5 shifts, two adds) that the
; duplication is cheap, and this project's established preference is
; to leave working, tested code alone rather than touch it for a
; small amount of shared logic.
; In:  A = new attribute byte, B = row (0-23), C = column (0-31)
; Out: none
; Destroys: AF, BC, DE, HL
;
; Bounds-checks row/col itself now — same gap GFX_CHAR_SETUP had and
; got fixed for (see that routine's own comment): nothing stopped a
; caller from passing an out-of-range column here, and unlike the
; bitmap write, there was no separate fix covering this path. Found
; via a real, reproducible case: GFX_PRINT_STRING_ATTR calls this
; unconditionally for every character of a string, including ones
; GFX_PUTCHAR correctly skips once GFX_CHAR_SETUP's own bounds check
; kicks in past column 31 — so a too-long PRINT string's attribute-
; painting kept walking past column 31 even after the bitmap fix
; landed, and since attribute memory is a flat row*32+col array,
; walking col past 31 spills into the NEXT row's attribute bytes,
; silently recoloring cells that belong to a completely different
; line. Verified in Python before writing this fix: a 31-character
; string starting at column 20 lands its overflow at row+1, columns
; 0-18 — a real, traceable corruption, not a hypothetical one.
; Silently does nothing on out-of-range, matching this project's now-
; consistent "clip rather than corrupt" answer to this exact class of
; bug (GFX_PLOT_CLIPPED, GFX_CHAR_SETUP) — no callers currently check
; a return status from this routine, so a silent no-op needs no
; changes anywhere else, unlike GFX_CHAR_SETUP's carry-flag fix.
; ============================================================================
GFX_SET_ATTR:
    push af
    call GFX_CELL_ATTR_ADDR
    jr   c, .discard_attr
    pop  af
    ld   (hl), a
    ret
.discard_attr:
    pop  af
    ret

; ============================================================================
; GFX_SET_ATTR_EXT
; High Resolution Graphics mode's attribute setter — same row*32+col
; formula GFX_SET_ATTR already uses, just with SECOND_DISPLAY_ADDR as
; the base instead of ATTR_ADDR, and B holding a real scanline row
; (0-191, one attribute byte per scanline) instead of a character row
; (0-23, one attribute byte per 8 scanlines). Deliberately its own
; small routine rather than a parameterized version of GFX_SET_ATTR —
; that routine is already tested and hardware-confirmed with a fixed
; base address; changing its calling contract to accept a base
; address risks every existing call site for a small amount of
; arithmetic duplication, which is the worse trade (same reasoning
; kernel/math's MATH_NEGATE16 comment already gives for a near-
; identical situation). Addressing formula verified in Python against
; the manual's own 6144-byte/8x1-resolution figures before any Z80 was
; written — all 6144 (y,col) pairs land on unique addresses inside
; $6000-$77FF, zero collisions, zero out-of-range.
; In:  B = y (0-191, a real scanline row, NOT a character row), C =
;      col (0-31), A = attribute byte
; Out: none
; Destroys: AF, DE, HL
; ============================================================================

; ============================================================================
; GFX_SET_MODE
; Switches between Normal and High Resolution Graphics video modes —
; MODE's mechanism. Real port $FF write, done safely: $FF is a shared,
; multi-function register (see hardware.inc's PORT_SCLD comment for
; the full bit layout), so this always reads PORT_FF_SHADOW, replaces
; only the video-mode bits (0-2), and writes the merged byte back to
; both the shadow and the port — same established pattern as GFX_SET_
; BORDER already uses for port $FE, adopted here from the start rather
; than repeating the bug that pattern exists to prevent (an earlier
; version of GFX_SET_BORDER had no shadow and silently zeroed bits it
; didn't mean to touch).
;
; Entering High Resolution Graphics mode clears its attribute region
; (SECOND_DISPLAY_ADDR, 6144 bytes) to ATTR_DEFAULT first — that
; memory has never been written by anything in this ROM before (real
; hardware-topology consequence of the RAM migration: this region is
; now genuinely unused by anything except this mode, not just
; "probably zero"), so its content is whatever was there at power-on,
; not necessarily zero. Left uninitialized, the first real pixels
; drawn there would render with an unpredictable — possibly identical
; ink/paper — color. Clearing to ATTR_DEFAULT (PAPER 7/INK 0, the same
; default GFX_CLS already uses) rather than to raw zero deliberately
; avoids repeating the exact "invisible white-on-white" class of
; confusion a real test program already hit once with INK/PAPER (see
; docs/v1/programmers_reference.md's Tier-2 session writeup) — zero would
; decode as PAPER 0/INK 0 here, black-on-black, same trap.
; In:  A = mode (0 = Normal, 1 = High Resolution Graphics — this
;      project's own friendly numbering, NOT the raw port $FF value;
;      caller (BASIC_STMT_MODE) validates this is 0 or 1 first)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
; ============================================================================
; GFX_SET_MODE
; Switches video mode via port $FF (PORT_SCLD) — 0 (Normal) or 1 (High
; Resolution Graphics). Mode 2 (64-Column) was removed 2026-08-20 —
; real overhead vs. value trade-off, freed for more core language
; features (see this project's own working memory for the accounting;
; the routine itself, GFX_SET_PALETTE, and the PALETTE statement were
; the only things that existed purely to serve it).
; In:  A = mode (0 or 1 — BASIC_STMT_MODE validates this before
;      calling)
; Out: none
; Destroys: AF, BC, DE, HL
; v2.1.2 (V2 production, item C): MODE 1's attribute file ($6000-$77FF) lies in array segment 2
; ($5B00-$77FF). Entering MODE 1 while the segment reaches above $6000 (ARR2_END > $6000; ARR2_END >=
; PAS_END, so the Array Store is covered) raises run-time error 64 (OUT OF MEMORY) through
; VM_ERR_ARRAY_SPACE before anything changes -- here, not in the MODE package, so every MODE package
; (old tapes included) is held to it. MODE 0 (also the editor's reset) is never refused.
; ============================================================================
GFX_SET_MODE:
    IFDEF V2_PRODUCTION
    dec  a
    jr   nz, .mode_ok               ; not MODE 1 (A is put back below)
    ld   hl, (ARR2_END)
    dec  hl
    ld   a, h
    cp   SECOND_DISPLAY_ADDR >> 8   ; ARR2_END - 1 >= $6000: the segment reaches into the attributes
    jp   nc, VM_ERR_ARRAY_SPACE     ; (unwinds to VM_RUN's caller)
    xor  a
.mode_ok:
    inc  a
    ENDIF
    push af
    call GFX_SPRITE_INVALIDATE
    pop  af
    ld   (GFX_MODE), a
    cp   1
    jr   z, .highres

    ; Normal (or any other value — BASIC_STMT_MODE validates 0-1, so
    ; this path is really just "0"): video byte = 0, bits 0-2 clear
    ld   a, (PORT_FF_SHADOW)
    and  %11111000
    jr   .write_port

.highres:
    ld   a, (PORT_FF_SHADOW)
    and  %11111000                 ; clear bits 0-2, keep 3-7 (ink/
                                   ; paper select, INTEN, EXROM —
                                   ; none of them this project's to
                                   ; disturb)
    or   2

.write_port:
    ld   (PORT_FF_SHADOW), a
    out  (PORT_SCLD), a

    ld   a, (GFX_MODE)
    cp   1
    jr   z, .clear_highres
    ret                              ; Normal mode needs no memory
                                    ; initialization — the primary
                                    ; screen is already maintained by
                                    ; every existing routine

.clear_highres:
    ; clear the High Resolution Graphics attribute region to
    ; ATTR_DEFAULT
    ld   hl, SECOND_DISPLAY_ADDR
    ld   de, SECOND_DISPLAY_ADDR + 1
    ld   bc, 6144 - 1
    ld   a, ATTR_DEFAULT
    ld   (hl), a
    ldir
    ret

; ============================================================================
; GFX_CLEAR_ROW
; Clears one character row (all 32 columns) — bitmap AND attribute —
; back to blank/default, without touching any other row. Built for the
; screen-flicker fix: redrawing the whole screen on every keystroke
; (GFX_CLS + full re-render) is the main source of visible flicker;
; clearing just the one row that actually changed is the first piece
; needed to avoid that.
;
; 5.8 (docs/V2_LEAPC_BACKPORT_PLAN.md, "Phase 5 follow-ups"): the row's 32 attributes are set to
; ATTR_DEFAULT and its bitmap zeroed by GFX_CLEAR_ROW_TEXT -- the same bytes as the 32 GFX_PUTCHAR
; spaces (FONT_TABLE's space is 8 zero bytes) and GFX_SET_ATTR calls this did, ~7 kT instead of ~33
; (every scroll of the output clears its new bottom row here). A row of 24 or more is ignored, as
; before (GFX_CELL_ATTR_ADDR's bounds check).
; In:  B = row (0-23)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_CLEAR_ROW:
    ld   c, 0
    call GFX_CELL_ATTR_ADDR         ; HL = the row's first attribute (B, C kept)
    ret  c                          ; no such row
    ld   a, ATTR_DEFAULT
    ld   c, GFX_COLS
.attr:
    ld   (hl), a
    inc  l                          ; (a row's 32 attributes never cross a page)
    dec  c
    jr   nz, .attr
    ASSERT $ == GFX_CLEAR_ROW_TEXT   ; B = the row: on into its bitmap

; ============================================================================
; GFX_CLEAR_ROW_TEXT
; Clears one character row's BITMAP ONLY (all 32 columns) — leaves the
; attribute byte at every cell completely untouched, unlike
; GFX_CLEAR_ROW, which resets both. Built for basic/'s status bar: it
; needs to erase old text before drawing new text, but always wants
; the row inverted, never briefly at the default attribute in between
; — clearing the attribute too (even just to immediately set it back
; to inverted afterward) means the row visibly passes through a non-
; inverted state for the moment in between, which showed up as a
; smaller, but still-present, flash even after GFX_CLEAR_ROW's own
; earlier fix for the worse, fully-toggling version of this bug.
; Zeroes the row's 8 scanlines directly (the space glyph is all zeros):
; ~6.6 kT per row instead of ~23 kT through 32 GFX_PUTCHAR calls
; (plan item 4.1, after Leap-C's SH_CLEAR_ROW).
; In:  B = row (0-23, caller's responsibility — no bounds check)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_CLEAR_ROW_TEXT:
    ld   a, b
    call GFX_ROW_BASE_ADDR          ; HL = scanline 0, column 0
    ld   e, l                       ; row bases are $xx00-$xxE0: L
    xor  a                          ; never wraps within 32 columns
    ld   c, 8                       ; 8 scanlines
.scanline:
    ld   b, GFX_COLS
.byte:
    ld   (hl), a
    inc  l
    djnz .byte
    ld   l, e                       ; back to column 0,
    inc  h                          ; next scanline (+256)
    dec  c
    jr   nz, .scanline
    ret

; ============================================================================
; Pixel graphics: GFX_PIXEL_AT / GFX_WRITE_PIXEL / GFX_READ_PIXEL /
; GFX_PLOT_CLIPPED / GFX_LINE
;
; Screen addressing (the original GFX_PIXEL_ADDR_SETUP) verified two independent ways before any Z80 was
; written: (1) this file's own already-tested ROW_BASE_TABLE plus a
; row/col/scanline decomposition, and (2) the canonical, independently-
; known ZX Spectrum-family screen address formula
; ($4000 | (y&$C0)<<5 | (y&$07)<<8 | (y&$38)<<2 | x>>3). Checked against
; all 49152 (x,y) pixel positions in the 256x192 space, zero mismatches
; between the two methods, and confirmed every resulting address stays
; within the real 6144-byte bitmap and 768-byte attribute ranges.
;
; PLOT also sets the covering 8x8 attribute cell (mode 1: the 8x1 byte) to the current INK/
; PAPER/FLASH/INVERSE (LINE_ATTR) —
; this is real Sinclair-family hardware behavior (attribute clash is the
; hardware, not a choice this ROM makes), not something invented here.
; ============================================================================

; ============================================================================
; Pixels and lines (v2.1.1): Leap-C delta D25 (2068-Leap-C 1.2.0, b024dbc), itself a port of
; 2068-Forth v2.0's line (its Display speed milestone). V2's GFX_PIXEL_ADDR_SETUP, GFX_WRITE_PIXEL's
; body, GFX_LINE (memory cells, two MATH_COMPARE16 calls and a full address per pixel: about
; 1,400 T a pixel), GFX_SET_ATTR_EXT and BIT_MASK_TABLE are replaced: the major-axis Bresenham loop
; with r, dmin and dmaj in the alternate registers, the address and mask stepped from pixel to
; pixel, the attribute written only where the cell (mode 1: the 8x1 byte, at the bitmap address +
; $2000 -- issue #5) changes. LINE's ends are bytes on the screen (OP_LINE takes x mod 256 and
; clamps y to 191), so the line never leaves the screen. The pixels and attributes are those of the
; old e2 loop for every line (tools/qual/qlines.py). GFX_WRITE_PIXEL and GFX_READ_PIXEL keep V2's
; B = x, C = y contracts (package services 6 and 7) as short adapters; GFX_PLOT_CLIPPED (service 5)
; keeps its own.
;
; LINE's flags, in E while drawing: bit 0 y is the major axis, bit 1 x goes left, bit 2 y goes up,
; bit 3 mode 1 (8x1 colour), bit 4 the attribute is pending, bit 5 over (XOR). The alternate
; registers hold r (HL'), dmin (DE') and dmaj (BC') during GFX_LINE: the interrupt routine does not
; use them, and the float core (the only other user besides GFX_PRINT_STRING_ATTR and the tape
; code) never runs inside LINE.
; ============================================================================
; GFX_PIXEL_AT -- a pixel's bitmap address and bit mask
; In:  C = x (0-255), B = y (0-191; not checked)
; Out: HL = the bitmap byte's address, A = the bit mask (bit 7 = leftmost pixel)
; Destroys: F (BC and DE are kept)
; ============================================================================
GFX_PIXEL_AT:
    ld   a, b
    and  7
    ld   h, a
    ld   a, b
    rra
    rra
    rra
    and  $18
    or   h
    or   HIGH SCREEN_ADDR
    ld   h, a                       ; 010tt sss: the third, the scanline
    ld   a, b
    rla
    rla
    and  $E0
    ld   l, a
    ld   a, c
    rrca
    rrca
    rrca
    and  $1F
    or   l
    ld   l, a                       ; rrr ccccc: the row in the third, the column
    ld   a, c
    and  7
    push bc
    ld   b, a
    inc  b
    ld   a, 1
.mask:
    rrca
    djnz .mask
    pop  bc
    ret
    ASSERT LOW SCREEN_ADDR == 0

; ============================================================================
; GFX_READ_PIXEL -- whether a pixel is set (POINT; package service 6)
; In:  B = x (0-255), C = y (0-191, the caller checks): V2's contract, kept for the packages
; Out: A = 1 if the pixel is set, 0 if not
; Destroys: AF, BC, HL
; ============================================================================
GFX_READ_PIXEL:
    ld   a, b
    ld   b, c
    ld   c, a                       ; C = x, B = y: GFX_PIXEL_AT's order
    call GFX_PIXEL_AT
    and  (hl)
    ret  z
    ld   a, 1
    ret

; ============================================================================
; GFX_WRITE_PIXEL -- one pixel, set (or XORed) and coloured (PLOT; package service 7)
; In:  B = x (0-255), C = y (0-191; a larger y draws nothing), A = the attribute byte,
;      D = over (0: set, else XOR): V2's contract, kept for OP_PLOT and the packages
; Out: none
; Destroys: AF, BC, DE, HL (not the alternate registers: a one-point line never steps)
; ============================================================================
GFX_WRITE_PIXEL:
    ld   l, b
    ld   h, 0                       ; HL = x
    ld   e, c
    ld   b, d                       ; B = over
    ld   d, h                       ; DE = y
                                    ; (falls into GFX_PLOT_CLIPPED with A = the attribute)
; ============================================================================
; GFX_PLOT_CLIPPED -- one pixel, set (or XORed) and coloured; nothing off the screen (service 5)
; In:  HL = x, DE = y (signed 16-bit), A = the attribute byte, B = over (0: set, else XOR)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_PLOT_CLIPPED:
    ld   c, a
    ld   a, h
    or   d
    ret  nz                         ; x or y outside 0-255
    ld   a, e
    cp   192
    ret  nc
    ld   d, c                       ; D = the attribute
    ld   a, b
    or   a
    ld   b, e                       ; B = y
    ld   c, l                       ; C = x
    ld   e, $10                     ; the attribute pending
    jr   z, .set
    ld   e, $30                     ; ... and over
.set:
    ld   a, (GFX_MODE)
    add  a, a
    add  a, a
    add  a, a
    or   e
    ld   e, a                       ; bit 3: mode 1
    call GFX_PIXEL_AT
    ld   c, a
    ld   b, 1                       ; one point: GFX_LINE's loop ends after it
    jr   GFX_LINE.draw

; ============================================================================
; GFX_LINE -- the points of Bresenham's line from (X0, Y0) to (X1, Y1), both ends drawn, each set
; (OR; over: XOR) and giving its cell the attribute. The major axis (the larger of |dx| and |dy|; x
; on a tie) steps at every point, the minor one when the error r (0 to dmaj - 1, from dmaj / 2)
; reaches dmaj after adding dmin: the points of V2's e2 form (err = dx - dy).
; In:  GFX_LINE_X0/Y0/X1/Y1 (bytes, on the screen: OP_LINE puts them there), GFX_LINE_ATTR,
;      GFX_LINE_OVER
; Out: none
; Destroys: AF, BC, DE, HL, BC', DE', HL'
; ============================================================================
GFX_LINE:
    ld   a, (GFX_MODE)
    ld   c, a                       ; becomes bit 3 after the three shifts below
    ld   a, (GFX_LINE_Y0)
    ld   b, a
    ld   a, (GFX_LINE_Y1)
    call LINE_DELTA                 ; A = |dy|, carry: up
    rl   c
    ld   d, a
    ld   a, (GFX_LINE_X0)
    ld   b, a
    ld   a, (GFX_LINE_X1)
    call LINE_DELTA                 ; A = |dx|, carry: left
    rl   c
    ld   e, a
    cp   d                          ; carry: |dx| < |dy|
    rl   c
    bit  0, c
    jr   z, .xmaj
    ld   e, d                       ; E = dmaj = |dy|
    ld   d, a                       ; D = dmin = |dx|
.xmaj:
    ld   b, e                       ; B = dmaj
    push de
    exx
    pop  bc                         ; C = dmaj, B = dmin
    ld   e, b
    xor  a
    ld   d, a                       ; DE' = dmin
    ld   b, a                       ; BC' = dmaj
    ld   a, c
    srl  a
    ld   l, a
    ld   h, d                       ; HL' = r = dmaj / 2
    exx
    ld   a, (GFX_LINE_OVER)
    or   a
    ld   a, c
    jr   z, .flags
    or   $20                        ; over
.flags:
    or   $10                        ; the first point's attribute
    ld   e, a                       ; E = the flags
    ld   a, (GFX_LINE_ATTR)
    ld   d, a                       ; D = the attribute
    inc  b                          ; B = the points: dmaj + 1 (0: 256)
    push bc
    ld   bc, (GFX_LINE_X0)          ; C = x0, B = y0
    call GFX_PIXEL_AT
    pop  bc
    ld   c, a                       ; C = the mask, HL = the address
.draw:
    bit  4, e
    call nz, LINE_ATTR
    ld   a, (hl)
    xor  c
    bit  5, e
    jr   nz, .put                   ; over: XOR
    or   c                          ; else set: (b XOR m) OR m = b OR m
.put:
    ld   (hl), a
    dec  b
    ret  z                          ; the last point
    bit  0, e                       ; the major axis
    call z, LINE_XSTEP
    bit  0, e
    call nz, LINE_YSTEP
    exx                             ; r += dmin; the minor axis steps if r reaches dmaj (r -= dmaj)
    add  hl, de                     ; (r, dmin, dmaj < 256: no carry out, so SBC subtracts exactly)
    sbc  hl, bc
    jr   nc, .minor
    add  hl, bc
    exx
    jr   .draw
.minor:
    exx
    bit  0, e
    call nz, LINE_XSTEP
    bit  0, e
    call z, LINE_YSTEP
    jr   .draw
    ASSERT GFX_LINE_Y0 == GFX_LINE_X0 + 1

; ============================================================================
; LINE_XSTEP, LINE_YSTEP -- the address and mask one pixel on in x (left if E bit 1) or y (up if E
; bit 2); where the byte (mode 1) or the cell (mode 0) changes, E bit 4: the attribute is written
; with the next pixel. The line stays on the screen (its ends are on it), except for a step after
; the last point, which the loop never takes.
; In:  HL = the address, C = the mask, E = LINE's flags
; Destroys: AF
; ============================================================================
LINE_YSTEP:
    bit  2, e
    jr   nz, .up
    inc  h
    ld   a, h
    and  7
    jr   nz, LINE_PEND_HIRES        ; the same cell row
    ld   a, l
    add  a, 32
    ld   l, a
    jr   c, LINE_PEND               ; the next third (H already is)
    ld   a, h
    sub  8
    ld   h, a
    jr   LINE_PEND
.up:
    ld   a, h
    dec  h
    and  7
    jr   nz, LINE_PEND_HIRES
    ld   a, l
    sub  32
    ld   l, a
    jr   c, LINE_PEND               ; the third above (H already is)
    ld   a, h
    add  a, 8
    ld   h, a
    jr   LINE_PEND
LINE_XSTEP:
    bit  1, e
    jr   nz, .left
    rrc  c
    ret  nc
    inc  l
    jr   LINE_PEND
.left:
    rlc  c
    ret  nc
    dec  l
    jr   LINE_PEND
LINE_PEND_HIRES:
    bit  3, e
    ret  z
LINE_PEND:
    set  4, e                       ; the attribute is written with the next pixel
    ret

; ============================================================================
; LINE_ATTR -- colour the bitmap byte at HL with D: mode 0 its cell's attribute, mode 1 (E bit 3)
; its own attribute byte at HL + $2000 (the second display file is laid out like the bitmap)
; In:  HL = the bitmap byte, D = the attribute, E = LINE's flags
; Out: E bit 4 (the attribute pending) clear
; Destroys: AF
; ============================================================================
LINE_ATTR:
    res  4, e
    bit  3, e
    jr   nz, .byte
    push hl
    ld   a, h
    rrca
    rrca
    rrca
    and  3
    or   HIGH ATTR_ADDR
    ld   h, a                       ; the cell: ATTR_ADDR + the third * 256 + L
    ld   (hl), d
    pop  hl
    ret
.byte:
    set  5, h
    ld   (hl), d
    res  5, h
    ret
    ASSERT LOW ATTR_ADDR == 0 && SECOND_DISPLAY_ADDR == SCREEN_ADDR + $2000

; LINE_DELTA -- A = |A - B|, carry if A < B. Destroys: F
LINE_DELTA:
    sub  b
    ret  nc
    neg                             ; (A was not 0: NEG sets the carry)
    ret

; GFX_FILL and GFX_CIRCLE were removed 2026-09-19 (Phase 0 P0.4): CIRCLE and FILL are the shapes
; package (rom/ext_v2_shapes_module.asm), which carries its own SHAPES_BIT_MASK_TABLE.

; ---- screen-row base addresses, computed and verified numerically
; (see file header) rather than derived by hand from the bit-shuffle
; formula ----
    ; The table must not cross a 256-byte page (GFX_CHAR_TO_FONT_OFFSET adds to L only). Every image
    ; that includes this file pads to the next page if it would: 0 bytes in the production HOME
    ; (v2.1.1), where it does not cross; the smoke ROMs (rom/test_editor.asm) may pad.
    IF HIGH $ != HIGH ($ + "@" - " ")
    DS   256 - LOW $, 0
    ENDIF
LOW_CHAR_TABLE:
    ; 5.14: the font index of each code from ' ' to '@' (GFX_CHAR_TO_FONT_OFFSET):
    ; 0 space, 1-10 the digits, 73-94 the punctuation (Q-26: after the letters'
    ; blocks, which now hold [ \ ] ^ _ ` and { | } ~).
    DB   0, 74, 73, 76, 77, 78, 79, 80   ;   ! " # $ % & '
    DB   81, 82, 91, 87, 85, 88, 84, 90   ; ( ) * + , - . /
    DB   1, 2, 3, 4, 5, 6, 7, 8   ; 0 1 2 3 4 5 6 7
    DB   9, 10, 83, 89, 92, 86, 93, 94   ; 8 9 : ; < = > ?
    DB   75   ; @
    ASSERT HIGH LOW_CHAR_TABLE == HIGH (LOW_CHAR_TABLE + "@" - " ")
PUNCT_CHAR_COUNT EQU 32            ; the punctuation glyphs: the 22 above and [ \ ] ^ _ ` { | } ~

; Block-graphics (128-143) and UDG (144-164) character-code ranges —
; see GFX_CHAR_TO_FONT_OFFSET's .is_block_graphics/.is_udg. UDG_COUNT
; itself lives in include/sysvars.inc alongside UDG_TABLE (it sizes
; that RAM block, not just this code-range check); UDG_CODE_BASE is
; purely a character-code constant, so it stays here with the rest of
; this file's character-range logic instead.
UDG_CODE_BASE EQU 144

ROW_BASE_TABLE:
    DW   $4000, $4020, $4040, $4060, $4080, $40A0, $40C0, $40E0
    DW   $4800, $4820, $4840, $4860, $4880, $48A0, $48C0, $48E0
    DW   $5000, $5020, $5040, $5060, $5080, $50A0, $50C0, $50E0

; ---- font: space, 0-9, A-Z (37 glyphs, 8 bytes each). See file header
; re: confidence level — designed and visually reviewed, not from a
; recalled ROM dump, needs YOUR visual confirmation once assembled. ----
FONT_TABLE:
    ; ' '
    DB   $00, $00, $00, $00, $00, $00, $00, $00
    ; '0'
    DB   $70, $88, $98, $A8, $C8, $88, $70, $00
    ; '1'  (plan item 4.3, Leap-C delta D13: a flag and a full base, unlike 'l')
    DB   $20, $60, $A0, $20, $20, $20, $F8, $00
    ; '2'
    DB   $70, $88, $08, $10, $20, $40, $F8, $00
    ; '3'
    DB   $F0, $08, $10, $30, $08, $88, $70, $00
    ; '4'
    DB   $10, $30, $50, $90, $F8, $10, $10, $00
    ; '5'
    DB   $F8, $80, $F0, $08, $08, $88, $70, $00
    ; '6'
    DB   $30, $40, $80, $F0, $88, $88, $70, $00
    ; '7'
    DB   $F8, $08, $10, $20, $40, $40, $40, $00
    ; '8'
    DB   $70, $88, $88, $70, $88, $88, $70, $00
    ; '9'
    DB   $70, $88, $88, $78, $08, $10, $60, $00
    ; 'A'
    DB   $20, $50, $88, $88, $F8, $88, $88, $00
    ; 'B'
    DB   $F0, $88, $88, $F0, $88, $88, $F0, $00
    ; 'C'
    DB   $70, $88, $80, $80, $80, $88, $70, $00
    ; 'D'
    DB   $F0, $88, $88, $88, $88, $88, $F0, $00
    ; 'E'
    DB   $F8, $80, $80, $F0, $80, $80, $F8, $00
    ; 'F'
    DB   $F8, $80, $80, $F0, $80, $80, $80, $00
    ; 'G'
    DB   $70, $88, $80, $B8, $88, $88, $70, $00
    ; 'H'
    DB   $88, $88, $88, $F8, $88, $88, $88, $00
    ; 'I'
    DB   $70, $20, $20, $20, $20, $20, $70, $00
    ; 'J'
    DB   $08, $08, $08, $08, $08, $88, $70, $00
    ; 'K'
    DB   $88, $90, $A0, $C0, $A0, $90, $88, $00
    ; 'L'
    DB   $80, $80, $80, $80, $80, $80, $F8, $00
    ; 'M'
    DB   $88, $D8, $A8, $88, $88, $88, $88, $00
    ; 'N'
    DB   $88, $C8, $A8, $98, $88, $88, $88, $00
    ; 'O'
    DB   $70, $88, $88, $88, $88, $88, $70, $00
    ; 'P'
    DB   $F0, $88, $88, $F0, $80, $80, $80, $00
    ; 'Q'
    DB   $70, $88, $88, $88, $A8, $90, $68, $00
    ; 'R'
    DB   $F0, $88, $88, $F0, $A0, $90, $88, $00
    ; 'S'
    DB   $70, $88, $80, $70, $08, $88, $70, $00
    ; 'T'
    DB   $F8, $20, $20, $20, $20, $20, $20, $00
    ; 'U'
    DB   $88, $88, $88, $88, $88, $88, $70, $00
    ; 'V'
    DB   $88, $88, $88, $88, $88, $50, $20, $00
    ; 'W'
    DB   $88, $88, $88, $A8, $A8, $D8, $88, $00
    ; 'X'
    DB   $88, $50, $20, $20, $20, $50, $88, $00
    ; 'Y'
    DB   $88, $50, $20, $20, $20, $20, $20, $00
    ; 'Z'
    DB   $F8, $08, $10, $20, $40, $80, $F8, $00
    ; Q-26: '[' to '`' follow 'Z' and '{' to '~' follow 'z', so the letters'
    ; arithmetic reaches them (GFX_CHAR_TO_FONT_OFFSET); '_' moved here.
    ; '['
    DB   $70, $40, $40, $40, $40, $40, $70, $00
    ; '\'  (the mirror of '/')
    DB   $00, $40, $20, $10, $08, $04, $00, $00
    ; ']'
    DB   $70, $10, $10, $10, $10, $10, $70, $00
    ; '^'
    DB   $20, $50, $88, $00, $00, $00, $00, $00
    ; '_'
    DB   $00, $00, $00, $00, $00, $00, $F8, $00
    ; '`'
    DB   $40, $20, $00, $00, $00, $00, $00, $00
    ; ---- lowercase a-z appended below, same design/review discipline
    ; as the uppercase set above ----
    ; 'a'
    DB   $00, $00, $70, $08, $78, $88, $78, $00
    ; 'b'
    DB   $80, $80, $B0, $C8, $88, $88, $F0, $00
    ; 'c'
    DB   $00, $00, $70, $88, $80, $88, $70, $00
    ; 'd'
    DB   $08, $08, $68, $98, $88, $88, $78, $00
    ; 'e'
    DB   $00, $00, $70, $88, $F8, $80, $70, $00
    ; 'f'
    DB   $30, $40, $F0, $40, $40, $40, $40, $00
    ; 'g'  (v2.1.1, issue #6: the bowl on the x-height, rows 2-5, like Leap-C D24)
    DB   $00, $00, $78, $88, $88, $78, $08, $70
    ; 'h'
    DB   $80, $80, $B0, $C8, $88, $88, $88, $00
    ; 'i'
    DB   $20, $00, $60, $20, $20, $20, $70, $00
    ; 'j'
    DB   $10, $00, $30, $10, $10, $10, $90, $60
    ; 'k'
    DB   $80, $80, $90, $A0, $C0, $A0, $90, $00
    ; 'l'  (plan item 4.3, Leap-C delta D13: a tail to the right, no base, unlike '1')
    DB   $60, $20, $20, $20, $20, $20, $18, $00
    ; 'm'
    DB   $00, $00, $D0, $A8, $A8, $88, $88, $00
    ; 'n'
    DB   $00, $00, $B0, $C8, $88, $88, $88, $00
    ; 'o'
    DB   $00, $00, $70, $88, $88, $88, $70, $00
    ; 'p'  (v2.1.1, issue #6)
    DB   $00, $00, $F0, $88, $88, $F0, $80, $80
    ; 'q'  (v2.1.1, issue #6)
    DB   $00, $00, $78, $88, $88, $78, $08, $08
    ; 'r'
    DB   $00, $00, $B0, $C8, $80, $80, $80, $00
    ; 's'
    DB   $00, $00, $78, $80, $70, $08, $F0, $00
    ; 't'
    DB   $40, $40, $F0, $40, $40, $48, $30, $00
    ; 'u'
    DB   $00, $00, $88, $88, $88, $98, $68, $00
    ; 'v'
    DB   $00, $00, $88, $88, $88, $50, $20, $00
    ; 'w'
    DB   $00, $00, $88, $88, $A8, $A8, $50, $00
    ; 'x'
    DB   $00, $00, $88, $50, $20, $50, $88, $00
    ; 'y'
    DB   $00, $00, $88, $88, $88, $78, $08, $70
    ; 'z'
    DB   $00, $00, $F8, $10, $20, $40, $F8, $00
    ; '{'
    DB   $18, $20, $20, $40, $20, $20, $18, $00
    ; '|'
    DB   $20, $20, $20, $20, $20, $20, $20, $00
    ; '}'
    DB   $C0, $20, $20, $10, $20, $20, $C0, $00
    ; '~'
    DB   $00, $00, $40, $A8, $10, $00, $00, $00
    ; ---- punctuation, added as needed rather than up front — '"' was
    ; needed the moment PRINT "..." string literals became typeable,
    ; see kernel/io's SYMBOL SHIFT+P addition ----
    ; '"'
    DB   $50, $50, $00, $00, $00, $00, $00, $00
    ; ---- more punctuation: the confirmed-confidence subset of
    ; SYMBOL SHIFT's table (see kernel/io.asm's header — the real
    ; table is more complex than this, some keys give BASIC keyword
    ; tokens rather than symbols, some differ between plain SYMBOL
    ; SHIFT and a separate "extended mode"; only what's independently
    ; confirmed is implemented) ----
    ; '!'
    DB   $20, $20, $20, $20, $20, $00, $20, $00
    ; '@'
    DB   $70, $88, $B0, $B0, $80, $88, $70, $00
    ; '#'
    DB   $50, $50, $F8, $50, $F8, $50, $50, $00
    ; '$'
    DB   $20, $78, $A0, $70, $28, $F0, $20, $00
    ; '%'
    DB   $88, $10, $20, $20, $40, $88, $00, $00
    ; '&'
    DB   $60, $90, $60, $68, $90, $98, $68, $00
    ; '''
    DB   $20, $20, $00, $00, $00, $00, $00, $00
    ; '('
    DB   $10, $20, $40, $40, $40, $20, $10, $00
    ; ')'
    DB   $40, $20, $10, $10, $10, $20, $40, $00
    ; ':'
    DB   $00, $20, $00, $00, $20, $00, $00, $00
    ; '.'
    DB   $00, $00, $00, $00, $00, $00, $20, $00
    ; ','
    DB   $00, $00, $00, $00, $00, $20, $20, $40
    ; '='
    DB   $00, $00, $F8, $00, $F8, $00, $00, $00
    ; '+'
    DB   $00, $20, $20, $F8, $20, $20, $00, $00
    ; '-'
    DB   $00, $00, $00, $F8, $00, $00, $00, $00
    ; ';'
    DB   $00, $20, $00, $00, $20, $20, $40, $00
    ; '/' — diagonal stroke, lower-left to upper-right. Designed and
    ; visually reviewed as ASCII art before committing (see this
    ; project's established discipline for glyphs — needed once V=/
    ; was added for basic/'s division operator)
    DB   $00, $04, $08, $10, $20, $40, $00, $00
    ; '*' — vertical spine + diagonal rays converging at center,
    ; six-pointed asterisk. Same review discipline (needed once B=*
    ; was added for basic/'s multiplication operator)
    DB   $00, $10, $54, $38, $54, $10, $00, $00
    ; '<' — simple angle-bracket chevron, apex pointing left, single-
    ; pixel diagonal strokes converging on the left edge (column 0)
    ; and opening back out to column 3 top/bottom — stays within the
    ; same column range ($80-$08) every letter/digit glyph already
    ; uses, unlike '/' which intentionally reaches further right.
    ; Needed once basic/'s new IF condition relational operators
    ; (kernel/io's SYMBOL SHIFT+R) made '<' a real, typeable character
    ; rather than only usable via LOAD/hand-edited program text.
    ; Visually reviewed as ASCII art before committing, same discipline
    ; as every other glyph here.
    DB   $10, $20, $40, $80, $40, $20, $10, $00
    ; '>' — exact horizontal mirror of '<' within the same column
    ; range, apex pointing right toward column 4 instead of column 0.
    ; Needed alongside '<' for the same reason (kernel/io's SYMBOL
    ; SHIFT+T).
    DB   $40, $20, $10, $08, $10, $20, $40, $00
    ; '?' — top hook reuses '2''s exact top-curve shape (rows 0-2:
    ; arc, then right-hand downstroke), tapering to a single point at
    ; row 4 instead of '2''s full-width bottom bar, then a blank row
    ; and a centered dot — same gap-then-dot closing shape already
    ; established by '!' elsewhere in this table. Designed and
    ; visually reviewed as ASCII art before committing, same
    ; discipline as every other glyph here — not transcribed from any
    ; real ROM's font. Needed once kernel/io's SYMBOL SHIFT+C mapping
    ; was added (see that table's header) — mapping and glyph always
    ; ship together per this project's established rule.
    DB   $70, $88, $08, $10, $20, $00, $20, $00

; ============================================================================
; Sprites — GFX_SPRITE_CAPTURE / GFX_SPRITE_DRAW (2026-08-19)
;
; A save/restore pair for a rectangular region of the screen (bitmap +
; attributes), on top of the same screen-addressing math GFX_CHAR_SETUP/
; GFX_SET_ATTR already use and have hardware-confirmed. Together these
; two also implement a generic screen-to-screen COPY (capture from one
; position, draw at another) — matching this project's own deferred
; design note ("COPY/sprite save-restore") with one reusable pair
; rather than two separate mechanisms.
;
; Deliberately CELL-ALIGNED ONLY: the rectangle's top-left and size are
; always whole 8x8 character cells (row 0-23, col 0-31), never
; arbitrary pixel positions. This is the same "coarse but correct"
; scoping precedent GFX_CPLOT's own quadrant granularity already set —
; and here it's not just simplicity, it sidesteps a real ambiguity:
; a screen attribute belongs to a whole 8x8 cell, so a pixel-unaligned
; sprite would have no single well-defined attribute to capture at its
; own edges. Smooth pixel-level sprite movement is real future work,
; not attempted here — moving a sprite means capture-background/
; restore-background/draw-again, one 8-pixel step at a time.
;
; Buffer format: one 9-byte record per cell, row-major (top-left to
; bottom-right, rows outer) — 8 bitmap scanline bytes (top to bottom)
; followed by 1 attribute byte. Total buffer size needed = width_cells
; * height_cells * 9 bytes. The caller owns this buffer (no dynamic
; allocation exists in this project) — typically one "sprite" buffer
; and one "background save" buffer per on-screen sprite, sized for
; whatever cell rectangle that sprite uses.
; ============================================================================

; ============================================================================
; GFX_CELL_BITMAP_ADDR
; Row/col -> bitmap screen address, scanline 0 of that cell. Exactly
; the same ROW_BASE_TABLE[row]+col math GFX_CHAR_SETUP already uses and
; has hardware-confirmed (see that routine) — factored out here as its
; own small routine rather than reused directly, matching this file's
; own established precedent of small parallel address-math routines
; for contexts that don't need GFX_CHAR_SETUP's other half (font
; lookup) — GFX_CPLOT's own ROW_BASE_TABLE use is the same pattern.
; In:  B = row (0-23), C = col (0-31) — NOT bounds-checked here; callers
;      in this file always validate via GFX_SPRITE_BOUNDS_CHECK first
; Out: HL = bitmap address (scanline 0 of the cell)
; Destroys: AF, DE
; ============================================================================
GFX_CELL_BITMAP_ADDR:
    ld   a, b
    call GFX_ROW_BASE_ADDR
    ex   de, hl                       ; DE = row_base
    ld   a, c
    add  a, e
    ld   e, a
    jr   nc, .no_carry
    inc  d
.no_carry:
    ex   de, hl                        ; HL = row_base + col
    ret

; ============================================================================
; GFX_CELL_ATTR_ADDR
; Row/col -> attribute byte address. Shared by GFX_ATTR_SWAP, GFX_SET_ATTR,
; and the sprite paths so the bounds and address formula have one owner.
; In:  B = row (0-23), C = col (0-31)
; Out: carry clear + HL = attribute byte address; carry set if out of range
; Destroys: AF, DE
; ============================================================================
GFX_CELL_ATTR_ADDR:
    ld   a, b
    cp   24
    jr   nc, .out_of_range
    ld   a, c
    cp   32
    jr   nc, .out_of_range
    ld   h, 0
    ld   l, b
    add  hl, hl                      ; x2
    add  hl, hl                      ; x4
    add  hl, hl                      ; x8
    add  hl, hl                      ; x16
    add  hl, hl                      ; x32 -> row*32
    ld   de, ATTR_ADDR
    add  hl, de
    ld   d, 0
    ld   e, c
    add  hl, de                       ; HL = ATTR_ADDR + row*32 + col
    ret
.out_of_range:
    scf
    ret

; ============================================================================
; GFX_SPRITE_BOUNDS_CHECK
; Shared by GFX_SPRITE_CAPTURE and GFX_SPRITE_DRAW — both need the
; identical "does this whole rectangle fit on the 32x24 cell grid"
; check before touching anything.
; In:  B = top row, C = top col, D = width cells, E = height cells
; Out: carry clear if the whole rectangle fits; carry set otherwise
;      (width or height 0, or top+size overflowing the 32x24 grid) —
;      REJECTED outright rather than clipped, unlike GFX_PLOT_CLIPPED's
;      own convention: clipping here would silently leave the caller's
;      fixed-size buffer mismatched against what actually got
;      written/read, corrupting its own internal layout rather than
;      just drawing less on screen.
; Destroys: AF
; ============================================================================
GFX_SPRITE_BOUNDS_CHECK:
    ld   a, d
    or   a
    jr   z, .fail                      ; width 0 is invalid
    ld   a, e
    or   a
    jr   z, .fail                      ; height 0 is invalid

    ld   a, b
    add  a, e
    jr   c, .fail
    cp   25
    jr   nc, .fail                     ; top_row + height > 24

    ld   a, c
    add  a, d
    jr   c, .fail
    cp   33
    jr   nc, .fail                     ; top_col + width > 32

    or   a
    ret
.fail:
    scf
    ret

; ============================================================================
; GFX_SPRITE_CELL_ROWCOL
; SPRITE_TOP_ROW/COL + SPRITE_ROW_IDX/COL_IDX -> the real screen cell
; for CAPTURE/DRAW's current loop iteration. Small enough it could be
; inlined at both call sites, but it's called twice per cell in both
; routines (once for the bitmap address, again for the attribute
; address, since the scanline-copy loop between them clobbers B/C) —
; worth the one shared definition.
; In:  none (reads SPRITE_TOP_ROW/TOP_COL/ROW_IDX/COL_IDX)
; Out: B = real row, C = real col
; Destroys: AF, HL
; ============================================================================
GFX_SPRITE_CELL_ROWCOL:
    ld   a, (SPRITE_TOP_ROW)
    ld   hl, SPRITE_ROW_IDX
    add  a, (hl)
    ld   b, a
    ld   a, (SPRITE_TOP_COL)
    ld   hl, SPRITE_COL_IDX
    add  a, (hl)
    ld   c, a
    ret

; ============================================================================
; GFX_SPRITE_SETUP (internal)
; Shared prologue for GFX_SPRITE_CAPTURE/GFX_SPRITE_DRAW — bounds-checks
; the rectangle and stages it into SPRITE_BUF_PTR/TOP_ROW/TOP_COL/W/H/
; ROW_IDX, exactly the same regardless of which direction (capture vs
; draw) the caller's own row/col loop below will go. Confirmed
; byte-identical between the two routines before factoring this out.
; In:  B = top row (0-23), C = top col (0-31), D = width cells (1-32),
;      E = height cells (1-24), HL = buffer address
; Out: carry clear on success (staged); carry set if the rectangle
;      doesn't fit (GFX_SPRITE_BOUNDS_CHECK) — SPRITE_* state untouched
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_SPRITE_SETUP:
    call GFX_SPRITE_BOUNDS_CHECK
    ret  c

    ld   (SPRITE_BUF_PTR), hl
    ld   a, b
    ld   (SPRITE_TOP_ROW), a
    ld   a, c
    ld   (SPRITE_TOP_COL), a
    ld   a, d
    ld   (SPRITE_W), a
    ld   a, e
    ld   (SPRITE_H), a
    xor  a
    ld   (SPRITE_ROW_IDX), a
    ret

; ============================================================================
; GFX_SPRITE_TRANSFER (internal)
; Shared row/col loop behind GFX_SPRITE_CAPTURE/GFX_SPRITE_DRAW — same
; nested cell loop, cell-address computation, and DE-clobber protection
; (see the "REAL BUG FOUND 2026-08-19" note below) either way; only the
; copy DIRECTION differs, set by SPRITE_XFER_DIR (0 = capture: screen
; -> buffer; nonzero = draw: buffer -> screen). HL is always the screen
; address, DE always the buffer address, in both directions — this
; canonical convention (DRAW previously used the opposite: HL=buffer,
; DE=screen) is what lets the two directions share one attribute-copy
; sequence below without needing the original's two different orders
; (CAPTURE read-after-address-compute vs DRAW read-before-address-
; compute) — confirmed identical to the original per-direction
; behavior by direct A/B comparison under live ZEsarUX before this
; replaced the two separate routines.
; Caller must have already called GFX_SPRITE_SETUP.
; In:  none (reads SPRITE_TOP_ROW/COL/W/H/ROW_IDX and SPRITE_BUF_PTR,
;      staged by GFX_SPRITE_SETUP; SPRITE_XFER_DIR set by the caller)
; Out: carry clear (matches both wrappers' own "always succeeds once
;      SETUP has passed" contract)
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_SPRITE_TRANSFER:
.row_loop:
    xor  a
    ld   (SPRITE_COL_IDX), a
.col_loop:
    call GFX_SPRITE_CELL_ROWCOL         ; B = real row, C = real col
    call GFX_CELL_BITMAP_ADDR           ; HL = screen bitmap addr
                                        ; (scanline 0) — B/C untouched
                                        ; by this call (see its own
                                        ; header)
    ld   de, (SPRITE_BUF_PTR)           ; DE = buffer pointer

    ld   a, (SPRITE_XFER_DIR)
    or   a
    ld   b, 8
    jr   nz, .draw_scan
.cap_scan:
    ld   a, (hl)
    ld   (de), a
    inc  de
    ld   a, h
    add  a, 1                          ; next scanline: +256 to the
                                       ; SCREEN address (same non-linear
                                       ; screen layout GFX_PUTCHAR/
                                       ; GFX_CPLOT already step through
                                       ; this same way)
    ld   h, a
    djnz .cap_scan
    jr   .scan_done
.draw_scan:
    ld   a, (de)
    ld   (hl), a
    inc  de
    ld   a, h
    add  a, 1
    ld   h, a
    djnz .draw_scan
.scan_done:
    ; DE now holds the buffer's attribute-slot address (buf_ptr+8)
    ; either way — canonical DE=buffer convention, unlike the two
    ; routines this replaced. HL (screen) is stale past this cell's
    ; last scanline and gets recomputed below regardless.
    ;
    ; REAL BUG FOUND (2026-08-19, z80sim, not caught by inspection or
    ; check_asm.py, in the original two-routine version this replaced):
    ; DE holds the buffer's attribute-slot address at this point — but
    ; GFX_CELL_ATTR_ADDR's own documented contract destroys DE (it uses
    ; DE as scratch internally, same as GFX_SET_ATTR's proven address
    ; math it mirrors). An earlier version called GFX_SPRITE_CELL_
    ; ROWCOL/GFX_CELL_ATTR_ADDR here with no protection, silently
    ; clobbering DE before the attribute copy below ever ran — exactly
    ; lesson 1's register-survival bug class. Fix (still in force here):
    ; stash DE across both calls.
    push de
    call GFX_SPRITE_CELL_ROWCOL
    call GFX_CELL_ATTR_ADDR             ; HL = screen attr addr
    pop  de                             ; DE = buffer's attribute slot,
                                        ; restored
    ld   a, (SPRITE_XFER_DIR)           ; re-read fresh — the two calls
                                        ; above destroy AF, so a value
                                        ; loaded before them wouldn't
                                        ; survive
    or   a
    jr   nz, .draw_attr
    ld   a, (hl)                        ; capture: read screen attr
    ld   (de), a                        ; write buffer
    jr   .attr_done
.draw_attr:
    ld   a, (de)                        ; draw: read buffer attr
    ld   (hl), a                        ; write screen
.attr_done:
    inc  de
    ld   (SPRITE_BUF_PTR), de           ; advance past this cell's 9
                                        ; bytes total

    ld   a, (SPRITE_COL_IDX)
    inc  a
    ld   (SPRITE_COL_IDX), a
    ld   hl, SPRITE_W
    cp   (hl)
    jr   c, .col_loop

    ld   a, (SPRITE_ROW_IDX)
    inc  a
    ld   (SPRITE_ROW_IDX), a
    ld   hl, SPRITE_H
    cp   (hl)
    jr   c, .row_loop

    or   a                              ; success
    ret

; ============================================================================
; GFX_SPRITE_CAPTURE
; Captures a rectangular region of the screen (bitmap + attributes)
; into a caller-provided buffer — the "save" half of a save/restore
; sprite pair (GFX_SPRITE_DRAW is the "restore/show" half). See this
; section's own header above for the buffer format and cell-alignment
; scoping.
; In:  B = top row (0-23), C = top col (0-31), D = width cells (1-32),
;      E = height cells (1-24), HL = buffer address
; Out: carry clear on success (buffer filled); carry set + buffer
;      untouched if the rectangle doesn't fit (GFX_SPRITE_BOUNDS_CHECK)
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_SPRITE_CAPTURE:
    call GFX_SPRITE_SETUP
    ret  c
    xor  a
    ld   (SPRITE_XFER_DIR), a           ; 0 = capture
    jr   GFX_SPRITE_TRANSFER

; ============================================================================
; GFX_SPRITE_DRAW
; Draws a buffer previously filled by GFX_SPRITE_CAPTURE back onto the
; screen at a (possibly different) cell position — the "restore/show"
; half of the pair. A straight overwrite (bitmap + attribute both
; replaced outright), not an OR/XOR blend — this is the classic "save-
; under" sprite technique: showing a sprite means capturing the
; background first, then drawing the sprite buffer; hiding/moving it
; means drawing the saved background buffer back, exactly this same
; routine either way. No XOR-drawing is used anywhere, deliberately —
; on attribute-clash hardware, XOR-plotting individual sprite pixels
; can't cleanly erase against a background of different colors, while
; save-under works uniformly regardless of what's underneath.
; In:  B = top row (0-23), C = top col (0-31), D = width cells (1-32),
;      E = height cells (1-24), HL = buffer address (must have been
;      filled by a prior GFX_SPRITE_CAPTURE call with the SAME width/
;      height — this routine has no way to verify that)
; Out: carry clear on success (screen updated); carry set + screen
;      untouched if the rectangle doesn't fit (GFX_SPRITE_BOUNDS_CHECK)
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_SPRITE_DRAW:
    call GFX_SPRITE_SETUP
    ret  c
    ld   a, 1
    ld   (SPRITE_XFER_DIR), a           ; nonzero = draw
    jr   GFX_SPRITE_TRANSFER
