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
; FONT_TABLE covers space, 0-9, A-Z, a-z, and 23 punctuation characters
; (86 glyphs total: " ! @ # $ % & ' ( ) _ : . , = + - ; / * < > ?) — grown
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

; Scroll all 24 program-output rows up, then clear the new bottom row.
; The editor primitive above deliberately protects its status row, so reuse
; it for rows 0-21 and finish the additional row here.
GFX_SCROLL_OUTPUT_UP:
    call GFX_SCROLL_TEXT_UP
    ld   a, 22
    ld   (GFX_SCROLL_DST_ROW), a
    ld   a, 23
    ld   (GFX_SCROLL_SRC_ROW), a
    call GFX_COPY_ROW_BITMAP
    ld   hl, ATTR_ADDR + 23*32
    ld   de, ATTR_ADDR + 22*32
    ld   bc, 32
    ldir
    ld   b, 23
    jp   GFX_CLEAR_ROW

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
; Destroys: AF, BC, HL — the punctuation-table scan uses B as its loop
;      counter, so B is NOT preserved. This was documented wrong for a
;      while (claimed only AF/HL) and caused a real bug in GFX_PUTCHAR,
;      which read B (its row parameter) after this call without saving
;      it first — fixed in GFX_PUTCHAR by protecting BC around this
;      call, not by changing what this routine touches.
; ============================================================================
GFX_CHAR_TO_FONT_OFFSET:
    ld   e, a                      ; E = input char, preserved across
                                   ; the punctuation table scan below
    cp   " "
    jr   z, .is_space
    cp   "0"
    jr   c, .try_punct             ; below '0' and not space: might be
                                   ; punctuation
    cp   "9" + 1
    jr   c, .is_digit
    cp   "A"
    jr   c, .try_punct              ; between '9' and 'A': might be
                                    ; punctuation
    cp   "Z" + 1
    jr   c, .is_upper
    cp   "a"
    jr   c, .try_punct               ; between 'Z' and 'a': might be
                                     ; punctuation
    cp   "z" + 1
    jr   c, .is_lower
    ; falls through toward .try_punct for anything above 'z' too, but
    ; codes 128-164 are intercepted first — block graphics (128-143)
    ; and UDGs (144-164) are never in PUNCT_CHAR_TABLE
    cp   128
    jr   c, .try_punct
    cp   UDG_CODE_BASE                  ; 144
    jr   c, .is_block_graphics
    cp   UDG_CODE_BASE + UDG_COUNT      ; 165
    jr   c, .is_udg
    ; 165+: unmapped, falls through to the punctuation scan same as
    ; any other unrecognized code (.not_found -> render as space)

.try_punct:
    ; Linear scan of PUNCT_CHAR_TABLE (char, index) pairs — cleaner and
    ; less error-prone than a long chain of individual cp/jr z checks
    ; once the punctuation set grew past a handful of characters.
    ld   hl, PUNCT_CHAR_TABLE
    ld   b, PUNCT_CHAR_COUNT
.punct_loop:
    ld   a, (hl)
    cp   e
    jr   z, .punct_found
    inc  hl
    inc  hl                          ; each entry is 2 bytes: char, index
    djnz .punct_loop
    jr   .not_found

.punct_found:
    inc  hl
    ld   a, (hl)                      ; A = this character's font index
    jr   .to_offset

.is_space:
    ld   hl, FONT_TABLE                ; offset 0 -> now an absolute
                                       ; pointer, same as every other
                                       ; case below (see this routine's
                                       ; header)
    or   a
    ret
.is_digit:
    sub  "0"
    add  a, 1                      ; index 0 is space; digits start at 1
    jr   .to_offset
.is_upper:
    sub  "A"
    add  a, 11                      ; index 0=space, 1-10=digits, 11-36=upper
    jr   .to_offset
.is_lower:
    sub  "a"
    add  a, 37                       ; 37-62=lowercase, added alongside
                                    ; upper — see FONT_TABLE's new tail
.to_offset:
    ; N*8 via three doublings. An earlier draft here tried to be clever
    ; with an extra add (aiming for x2,x4,x5,x8) and actually computed
    ; x10 — caught by re-deriving the arithmetic with a script rather
    ; than trusting the inline comment. Three plain doublings is both
    ; simpler and correct.
    ld   l, a
    ld   h, 0
    add  hl, hl                      ; x2
    add  hl, hl                      ; x4
    add  hl, hl                      ; x8
    ld   bc, FONT_TABLE                ; fold the ROM base in here so
    add  hl, bc                        ; every path out of this routine
                                       ; returns an absolute pointer
                                       ; uniformly (see header)
    or   a
    ret

.is_block_graphics:
    ; Codes 128-143: real TS2068/Spectrum-family hardware never stores
    ; these as glyph data — PO-GR-1 (MKBLKGR) in the ROM disassembly
    ; generates the 8-byte bitmap from the low nibble every time one is
    ; printed, and this mirrors that exact bit-to-quadrant algorithm
    ; (SBC A,A + mask, confirmed from the disassembly's PO-GR-2/PO-GR-3
    ; — see docs/programmers_reference.md for the full derivation,
    ; including the one part — the bottom-half repeat — reconstructed
    ; from the universal Spectrum-family technique rather than read
    ; directly, since the source PDF's text extraction cuts out exactly
    ; at that point). Low nibble bit0=top-right, bit1=top-left,
    ; bit2=bottom-right, bit3=bottom-left; each quadrant is a solid 4x4
    ; block, filled or blank, never partial.
    ld   b, e                          ; E still holds the original
                                       ; character (this routine's own
                                       ; convention, see its top) — B is
                                       ; free here since the punct-scan
                                       ; loop counter isn't live on this
                                       ; path
    rr   b
    sbc  a, a
    and  $0F
    ld   c, a                          ; right nibble (bit0 = top-right)
    rr   b
    sbc  a, a
    and  $F0
    or   c                             ; A = top-half byte (rows 0-3)
    ld   hl, BLOCK_GFX_SCRATCH
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    rr   b
    sbc  a, a
    and  $0F
    ld   c, a                          ; right nibble (bit2 = bottom-right)
    rr   b
    sbc  a, a
    and  $F0
    or   c                             ; A = bottom-half byte (rows 4-7)
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a
    inc  hl
    ld   (hl), a
    ld   hl, BLOCK_GFX_SCRATCH
    or   a
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

.not_found:
    scf
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
                                   ; see docs/programmers_reference.md's
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

; XOR-plots a glyph instead of replacing the destination bytes. Kept
; separate so every existing editor/status/help caller retains ordinary
; opaque text semantics; BASIC PRINT selects this only for OVER 1.
GFX_PUTCHAR_OVER:
    call GFX_CHAR_SETUP
    ret  c
    ld   b, 8
.scanline_loop:
    ld   a, (hl)
    ex   de, hl
    xor  (hl)
    ld   (hl), a
    inc  h
    ex   de, hl
    inc  hl
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
; Prints a null-terminated string with BASIC-style attributes. At column 32
; it wraps; past row 23 it scrolls all 24 output rows and continues on the
; newly cleared bottom row. It also sets the attribute cell
; under each character to a given byte — built for basic/'s INK/PAPER/
; FLASH/INVERSE support, which needs printed text to actually carry
; the current attribute state, unlike every other caller of
; GFX_PRINT_STRING (HELP screens, error messages, the editor), which
; always wants the plain default/inherited attribute and must NOT be
; affected by this. Kept as a separate routine rather than adding an
; attribute parameter to GFX_PRINT_STRING itself, so none of those
; existing callers need to change.
;
; The attribute value is stashed in PRINT_ATTR_SCRATCH (a real RAM
; sysvar, sysvars.inc), not a register — both GFX_PUTCHAR and
; GFX_SET_ATTR destroy AF/BC/DE/HL per their own contracts, so a bare
; register holding the attribute would not survive either call. This
; is the same "value must survive a call -> use memory, not a
; register" pattern this project has hit repeatedly (see
; MEM_LINE_FIRST/NEXT's own DE-clobbering history) — BUT NOTE: this
; scratch value must live in RAM specifically, never in a `DB` byte
; embedded in this file's own code. A `DB` byte sits in ROM once
; assembled, and this entire codebase assembles into ROM — writing to
; a ROM-resident "variable" via `ld (addr), a` is a silent no-op on
; real hardware, so the byte always reads back its compile-time
; initial value, never whatever was "written" at runtime. This was a
; real, shipped bug: an earlier version of this routine used exactly
; that pattern (a local `.attr_scratch: DB 0`), and every PRINT wrote
; attribute $00 (black-on-black) regardless of INK/PAPER, found via a
; real memory dump showing GFX_CLS's own fill elsewhere on screen was
; correctly $38 while PRINT's own writes were stuck at $00. See
; docs/programmers_reference.md's "INK / PAPER / FLASH / INVERSE /
; OVER" section for the full writeup.
; In:  HL = pointer to null-terminated string, B = row, C = column,
;      A = attribute byte to set at every printed cell, D = OVER flag
; Out: B/C = row/column immediately after the final character
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_PRINT_STRING_ATTR:
    ld   (PRINT_ATTR_SCRATCH), a
    ld   a, d
    ld   (PRINT_OVER_SCRATCH), a
.loop:
    ld   a, (hl)
    or   a
    ret  z
    push hl
    push bc                  ; GFX_PUTCHAR destroys BC entirely
    ld   a, (PRINT_OVER_SCRATCH)
    or   a
    jr   z, .opaque
    ld   a, (hl)
    call GFX_PUTCHAR_OVER
    jr   .glyph_done
.opaque:
    ld   a, (hl)
    call GFX_PUTCHAR
.glyph_done:
    pop  bc
    push bc                  ; GFX_SET_ATTR also destroys BC — needs
                             ; its own save/restore, same row/column
    ld   a, (PRINT_ATTR_SCRATCH)
    call GFX_SET_ATTR
    pop  bc
    pop  hl
    inc  hl
    inc  c
    ld   a, c
    cp   32
    jr   c, .loop
    ld   c, 0
    inc  b
    ld   a, b
    cp   24
    jr   c, .loop
    push hl
    call GFX_SCROLL_OUTPUT_UP
    pop  hl
    ld   b, 23
    ld   c, 0
    jr   .loop

; ============================================================================
; GFX_ATTR_SWAP (internal — not in kernel_api.inc)
; Shared address computation and ink/paper bit-swap for
; GFX_INVERT_ATTR and GFX_INVERT_ATTR_STATIC — written once here rather
; than duplicated in both, given how much trouble duplicated addressing
; logic has already caused in this project. The bit-swap instruction
; sequence was verified numerically against all 256 possible attribute
; byte values before being trusted — see docs/programmers_reference.md's
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
GFX_INVERT_ATTR_STATIC:
    call GFX_ATTR_SWAP
    ret  c                                    ; out of range — see
                                             ; GFX_INVERT_ATTR's own
                                             ; identical check just above
    ld   (hl), a
    ret

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
GFX_SET_ATTR_EXT:
    ld   d, a                    ; stash the attribute byte before
                                 ; using A as bounds-check scratch —
                                 ; same fix, same reasoning, as GFX_
                                 ; SET_ATTR just above (that routine's
                                 ; own header has the full story: this
                                 ; project's real, reproducible bug,
                                 ; not a hypothetical one)
    ld   a, b
    cp   192                     ; B here is a real scanline row
                                 ; (0-191), not a character row —
                                 ; different bound than GFX_SET_ATTR's
                                 ; own row check
    ret  nc
    ld   a, c
    cp   32
    ret  nc
    ld   a, d                    ; restore the attribute byte

    push af
    ld   h, 0
    ld   l, b
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl                  ; y*32
    ld   de, SECOND_DISPLAY_ADDR
    add  hl, de
    ld   d, 0
    ld   e, c
    add  hl, de                   ; HL = SECOND_DISPLAY_ADDR + y*32 + col
    pop  af
    ld   (hl), a
    ret

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
; docs/programmers_reference.md's Tier-2 session writeup) — zero would
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
; ============================================================================
GFX_SET_MODE:
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
; Reuses GFX_PUTCHAR (a space character, for the bitmap) and
; GFX_SET_ATTR (for the attribute), rather than reimplementing the
; Spectrum-family interleaved screen addressing from scratch — both
; are already proven, tested primitives, and a character row isn't
; contiguous in bitmap memory (it's 8 scanlines spread across the
; standard third-of-screen interleaving), so hand-rolling this
; addressing again here would just be duplicating logic that already
; exists and already works.
;
; Both GFX_PUTCHAR and GFX_SET_ATTR destroy B/C (row/column) per their
; own documented contracts, so each is wrapped in its own push/pop —
; this project's most recurring mistake is assuming a register
; survives a call without checking its "Destroys:" line first.
; In:  B = row (0-23)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_CLEAR_ROW:
    ld   c, 0
.loop:
    push bc
    ld   a, " "
    call GFX_PUTCHAR
    pop  bc

    push bc
    ld   a, ATTR_DEFAULT
    call GFX_SET_ATTR
    pop  bc

    inc  c
    ld   a, c
    cp   GFX_COLS
    jr   c, .loop
    ret

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
; In:  B = row (0-23)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_CLEAR_ROW_TEXT:
    ld   c, 0
.loop:
    push bc
    ld   a, " "
    call GFX_PUTCHAR
    pop  bc

    inc  c
    ld   a, c
    cp   GFX_COLS
    jr   c, .loop
    ret

; ============================================================================
; Pixel graphics: GFX_PIXEL_ADDR_SETUP / GFX_WRITE_PIXEL / GFX_READ_PIXEL /
; GFX_LINE
;
; Screen addressing verified two independent ways before any Z80 was
; written: (1) this file's own already-tested ROW_BASE_TABLE plus a
; row/col/scanline decomposition, and (2) the canonical, independently-
; known ZX Spectrum-family screen address formula
; ($4000 | (y&$C0)<<5 | (y&$07)<<8 | (y&$38)<<2 | x>>3). Checked against
; all 49152 (x,y) pixel positions in the 256x192 space, zero mismatches
; between the two methods, and confirmed every resulting address stays
; within the real 6144-byte bitmap and 768-byte attribute ranges.
;
; PLOT also sets the covering 8x8 attribute cell to the current INK/
; PAPER/FLASH/INVERSE (via GFX_SET_ATTR, called from GFX_WRITE_PIXEL) —
; this is real Sinclair-family hardware behavior (attribute clash is the
; hardware, not a choice this ROM makes), not something invented here.
; ============================================================================

; ============================================================================
; GFX_PIXEL_ADDR_SETUP (internal — not in kernel_api.inc)
; Shared address computation for GFX_WRITE_PIXEL and GFX_READ_PIXEL —
; written once here rather than duplicated in both, same reasoning as
; GFX_CHAR_SETUP/GFX_ATTR_SWAP above: duplicated addressing logic is this
; project's single most common source of real bugs.
; In:  B = x (0-255), C = y (0-191, caller's responsibility to clamp —
;      an out-of-range y indexes past ROW_BASE_TABLE)
; Out: HL = bitmap byte address, A = bit mask (bit7 = leftmost pixel in
;      the byte, matching this file's font glyph convention); also
;      leaves GFX_PIXEL_ROW/GFX_PIXEL_COL set, for a caller that also
;      needs the attribute-cell address
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_PIXEL_ADDR_SETUP:
    ld   a, c
    and  %00000111                 ; scanline = y & 7
    ld   (GFX_PIXEL_SCANLINE), a

    ld   a, c
    rrca
    rrca
    rrca
    and  %00011111                 ; char_row = y >> 3 (three RRCAs
                                   ; rotate the low 3 bits into the top
                                   ; of the byte; the mask discards
                                   ; them, leaving a clean 0-23)
    ld   (GFX_PIXEL_ROW), a

    ld   a, b
    and  %00000111                 ; bit_in_byte = x & 7
    ld   e, a
    ld   d, 0
    ld   hl, BIT_MASK_TABLE
    add  hl, de
    ld   a, (hl)
    ld   (GFX_PIXEL_MASK), a

    ld   a, b
    rrca
    rrca
    rrca
    and  %00011111                 ; col = x >> 3, same trick as row
    ld   (GFX_PIXEL_COL), a

    ; bitmap address = ROW_BASE_TABLE[char_row] + col; scanline adds
    ; directly to the high byte (each scanline down = +256, verified —
    ; see this file's header and GFX_CHAR_SETUP's own comment)
    ld   a, (GFX_PIXEL_ROW)
    call GFX_ROW_BASE_ADDR
    ex   de, hl                   ; DE = ROW_BASE_TABLE[char_row]
    ld   a, (GFX_PIXEL_COL)
    add  a, e
    ld   e, a
    jr   nc, .no_col_carry
    inc  d
.no_col_carry:
    ld   a, (GFX_PIXEL_SCANLINE)
    add  a, d
    ld   d, a                      ; DE = final bitmap byte address
    ld   h, d
    ld   l, e
    ld   a, (GFX_PIXEL_MASK)
    ret

; ============================================================================
; GFX_WRITE_PIXEL
; Sets or XOR-toggles one pixel, then colors its covering 8x8 attribute
; cell to match — PLOT's actual mechanism.
; In:  B = x (0-255), C = y (0-191, caller clamps), A = attribute byte
;      (same bit layout GFX_SET_ATTR/ATTR_DEFAULT already use), D = OVER
;      flag (0 = set the pixel outright (OR), nonzero = XOR-toggle it —
;      real Sinclair BASIC's own OVER semantics, applied to graphics the
;      same way this project's OVER already applies to text)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_WRITE_PIXEL:
    ld   (GFX_PIXEL_ATTR), a       ; stash attribute + OVER flag before
    ld   a, d                     ; GFX_PIXEL_ADDR_SETUP destroys AF —
    ld   (GFX_PIXEL_OVER), a       ; same PRINT_ATTR_SCRATCH reasoning

    call GFX_PIXEL_ADDR_SETUP      ; HL = bitmap byte address, A = mask;
                                   ; GFX_PIXEL_ROW/COL also now set
    ld   b, a                      ; B = mask — x/y (the original B/C)
                                   ; are no longer needed past this point
    ld   a, (GFX_PIXEL_OVER)
    or   a
    jr   z, .plot_set
    ld   a, (hl)
    xor  b
    jr   .plot_write
.plot_set:
    ld   a, (hl)
    or   b
.plot_write:
    ld   (hl), a

    ; Color the covering attribute — which formula depends on the
    ; active video mode. Normal mode reuses the already-tested GFX_
    ; SET_ATTR rather than re-deriving its addressing formula here;
    ; High Resolution Graphics mode needs a real scanline row (0-191),
    ; not a character row, reconstructed from GFX_PIXEL_ROW/SCANLINE
    ; (both already set by GFX_PIXEL_ADDR_SETUP above) rather than
    ; re-deriving it from the original x/y, which are no longer live
    ; in any register by this point.
    ld   a, (GFX_MODE)
    or   a
    jr   nz, .ext_attr

    ld   a, (GFX_PIXEL_ROW)
    ld   b, a
    ld   a, (GFX_PIXEL_COL)
    ld   c, a
    ld   a, (GFX_PIXEL_ATTR)
    jp GFX_SET_ATTR

.ext_attr:
    ld   a, (GFX_PIXEL_ROW)
    add  a, a
    add  a, a
    add  a, a                      ; row*8 (fits easily — row maxes at
                                   ; 23, so row*8 maxes at 184)
    ld   b, a
    ld   a, (GFX_PIXEL_SCANLINE)
    add  a, b
    ld   b, a                      ; B = real y (row*8 + scanline —
                                   ; exactly reconstructs the original
                                   ; y by construction, verified in
                                   ; Python for all 192 values before
                                   ; this was written)
    ld   a, (GFX_PIXEL_COL)
    ld   c, a
    ld   a, (GFX_PIXEL_ATTR)
    jp GFX_SET_ATTR_EXT

; ============================================================================
; GFX_READ_PIXEL
; Tests whether a pixel is currently set — the mechanism behind POINT(x,y).
; In:  B = x (0-255), C = y (0-191, caller clamps)
; Out: A = 1 if the pixel is set, 0 if not
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_READ_PIXEL:
    call GFX_PIXEL_ADDR_SETUP      ; HL = bitmap byte address, A = mask
    ld   b, a
    ld   a, (hl)
    and  b
    ret  z
    ld   a, 1
    ret

; ============================================================================
; GFX_LINE
; Draws a line between two points via Bresenham's algorithm — integer
; only, matching this project's pure-integer BASIC. Absolute coordinates
; for BOTH endpoints (QL SuperBASIC style), deliberately not classic
; Sinclair BASIC's relative-only DRAW — no "current position" to track
; before drawing the next segment.
;
; The exact planned register-level arithmetic (byte-sized dx/dy
; magnitudes, a signed 16-bit error term with truncating add, MATH_
; COMPARE16-style three-way branch tests) was verified via Python
; simulation against a textbook reference Bresenham implementation
; before any Z80 was written: 512 lines (every degenerate/edge case —
; a single point, pure horizontal, pure vertical, both screen corners —
; plus 500 random endpoint pairs across the full 256x192 space), zero
; mismatches.
;
; Takes all six of its inputs from memory, not registers — GFX_LINE_X0/
; Y0/X1/Y1/ATTR/OVER — there are more live values here than survive a
; loop that itself calls GFX_WRITE_PIXEL and MATH_COMPARE16 (both
; destroy registers freely per their own contracts) every iteration.
; Same "value that must survive a destructive call lives in memory"
; reasoning as DELETE_START/DELETE_END and IF_SCAN_POS elsewhere in this
; project, just with more values in play. BASIC_STMT_LINE fills these in
; directly before calling — see sysvars.inc's own comment on this block.
; In:  GFX_LINE_X0/Y0/X1/Y1/ATTR/OVER, all pre-set by the caller
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_LINE:
    ; ---- dx = abs(x1-x0), sx = sign ----
    ld   a, (GFX_LINE_X1)
    ld   b, a
    ld   a, (GFX_LINE_X0)
    ld   c, a
    sub  b                        ; A = x0 - x1; carry set means x0 < x1
    jr   nc, .x0_ge_x1
    ld   a, b
    sub  c                        ; A = x1 - x0
    ld   (GFX_LINE_DX), a
    ld   a, 1
    ld   (GFX_LINE_SX), a
    jr   .dx_done
.x0_ge_x1:
    ld   (GFX_LINE_DX), a         ; A already = x0 - x1, from the SUB
                                  ; above
    ld   a, $FF                   ; -1 (two's complement)
    ld   (GFX_LINE_SX), a
.dx_done:

    ; ---- dy_abs = abs(y1-y0), sy = sign — same shape as dx/sx above ----
    ld   a, (GFX_LINE_Y1)
    ld   b, a
    ld   a, (GFX_LINE_Y0)
    ld   c, a
    sub  b
    jr   nc, .y0_ge_y1
    ld   a, b
    sub  c
    ld   (GFX_LINE_DY_ABS), a
    ld   a, 1
    ld   (GFX_LINE_SY), a
    jr   .dy_done
.y0_ge_y1:
    ld   (GFX_LINE_DY_ABS), a
    ld   a, $FF
    ld   (GFX_LINE_SY), a
.dy_done:

    ; ---- err = dx - dy_abs (signed 16-bit; dx and dy_abs are always
    ; non-negative bytes, zero-extended here, so a plain 16-bit
    ; subtract is exact — no separate negation needed for this one) ----
    ld   a, (GFX_LINE_DX)
    ld   l, a
    ld   h, 0
    ld   a, (GFX_LINE_DY_ABS)
    ld   e, a
    ld   d, 0
    or   a
    sbc  hl, de
    ld   (GFX_LINE_ERR), hl

.loop:
    ld   a, (GFX_LINE_X0)
    ld   b, a
    ld   a, (GFX_LINE_Y0)
    ld   c, a
    ld   a, (GFX_LINE_OVER)
    ld   d, a
    ld   a, (GFX_LINE_ATTR)
    call GFX_WRITE_PIXEL

    ; ---- termination: current point == end point ----
    ld   a, (GFX_LINE_X0)
    ld   b, a
    ld   a, (GFX_LINE_X1)
    cp   b
    jr   nz, .not_done
    ld   a, (GFX_LINE_Y0)
    ld   b, a
    ld   a, (GFX_LINE_Y1)
    cp   b
    jr   nz, .not_done
    ret
.not_done:

    ; ---- e2 = err + err (16-bit, truncating add — same operation as
    ; MATH_ADD16's own body, done inline here to avoid a CALL inside
    ; this already CALL-heavy per-pixel loop) — saved to memory since
    ; BOTH branch decisions below need it, and it must survive the
    ; first MATH_COMPARE16 call (which destroys HL) to reach the second
    ld   hl, (GFX_LINE_ERR)
    add  hl, hl
    ld   (GFX_LINE_E2), hl

    ; ---- if e2 >= -dy_abs: err += -dy_abs; x0 += sx ----
    ld   a, (GFX_LINE_DY_ABS)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16             ; HL = -dy_abs
    ex   de, hl                    ; DE = -dy_abs, preserved across the
                                   ; compare below (MATH_COMPARE16 never
                                   ; writes DE, only reads it)
    ld   hl, (GFX_LINE_E2)
    call MATH_COMPARE16            ; A: 0 if equal, 1 if e2>DE, $FF if
                                   ; e2<DE
    cp   $FF
    jr   z, .skip_x_step           ; e2 < -dy_abs -> condition false
    ld   hl, (GFX_LINE_ERR)
    add  hl, de                    ; DE still = -dy_abs
    ld   (GFX_LINE_ERR), hl
    ld   a, (GFX_LINE_X0)
    ld   b, a
    ld   a, (GFX_LINE_SX)
    add  a, b
    ld   (GFX_LINE_X0), a
.skip_x_step:

    ; ---- if e2 <= dx: err += dx; y0 += sy ----
    ld   a, (GFX_LINE_DX)
    ld   e, a
    ld   d, 0
    ld   hl, (GFX_LINE_E2)
    call MATH_COMPARE16             ; A: 0 if equal, 1 if e2>dx, $FF if
                                    ; e2<dx
    cp   1
    jr   z, .skip_y_step            ; e2 > dx -> condition false
    ld   hl, (GFX_LINE_ERR)
    ld   a, (GFX_LINE_DX)
    ld   e, a
    ld   d, 0
    add  hl, de
    ld   (GFX_LINE_ERR), hl
    ld   a, (GFX_LINE_Y0)
    ld   b, a
    ld   a, (GFX_LINE_SY)
    add  a, b
    ld   (GFX_LINE_Y0), a
.skip_y_step:

    jr   .loop

; ============================================================================
; GFX_PLOT_CLIPPED (internal — not in kernel_api.inc)
; Wraps GFX_WRITE_PIXEL with an off-screen bounds check — for callers
; like GFX_CIRCLE whose computed points (center +/- radius) can
; legitimately land outside the visible 256x192 area. Silently skips
; out-of-range points rather than truncating a negative or >255/>191
; coordinate into a byte and plotting it on the wrong edge of the
; screen — that silent-wraparound failure mode is exactly why this
; takes its x/y as full signed 16-bit values instead of GFX_WRITE_
; PIXEL's own bytes.
; In:  HL = signed 16-bit x, DE = signed 16-bit y, A = attribute byte,
;      B = OVER flag (0 = set, nonzero = XOR-toggle)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_PLOT_CLIPPED:
    ld   (GFX_CLIP_ATTR), a
    ld   a, b
    ld   (GFX_CLIP_OVER), a

    ; valid x is 0-255: for a signed 16-bit value that's exactly "high
    ; byte is zero" — H=0 rules out both negative (H would have its top
    ; bit set) and >255 (H would be a nonzero positive value) in one test
    ld   a, h
    or   a
    ret  nz
    ; valid y is 0-191: same high-byte-zero test, plus an explicit
    ; upper-bound check since 191 isn't a byte's full range
    ld   a, d
    or   a
    ret  nz
    ld   a, e
    cp   192
    ret  nc

    ld   a, l
    ld   b, a                       ; B = x
    ld   a, e
    ld   c, a                       ; C = y
    ld   a, (GFX_CLIP_OVER)
    ld   d, a                       ; D = OVER flag
    ld   a, (GFX_CLIP_ATTR)
    jp GFX_WRITE_PIXEL

; ============================================================================
; GFX_FILL_PUSH (internal — not in kernel_api.inc)
; Pushes (x,y) onto GFX_FILL_STACK. Silently does nothing if the stack
; is already full — graceful truncation, matching this routine's own
; documented limitation (see sysvars.inc's GFX_FILL_STACK comment).
; Deliberately does NOT try to reconstruct GFX_FILL_SP from the SBC
; comparison below via a follow-up ADD — that would silently clobber
; the very carry flag being tested (ADD HL,DE sets its own carry), the
; same mistake already caught once this session in BASIC_STMT_BLOCK's
; own corner-normalization code. Re-reads GFX_FILL_SP fresh instead.
; In:  B = x, C = y
; Out: none
; Destroys: AF, DE, HL
; ============================================================================
GFX_FILL_PUSH:
    ld   hl, (GFX_FILL_SP)
    ld   de, GFX_FILL_STACK_END
    or   a
    sbc  hl, de                    ; carry set if SP < END (room left)
    ret  nc                        ; SP >= END: full, silently skip

    ld   hl, (GFX_FILL_SP)          ; re-read fresh rather than trying
                                    ; to reuse/restore the value above
    ld   (hl), b
    inc  hl
    ld   (hl), c
    inc  hl
    ld   (GFX_FILL_SP), hl
    ret

; ============================================================================
; GFX_FILL_POP (internal — not in kernel_api.inc)
; Pops the most recently pushed (x,y) off GFX_FILL_STACK.
; In:  none
; Out: B = x, C = y (undefined if carry set); carry SET if the stack
;      was already empty
; Destroys: AF, DE, HL
; ============================================================================
GFX_FILL_POP:
    ld   hl, (GFX_FILL_SP)
    ld   de, GFX_FILL_STACK
    or   a
    sbc  hl, de                    ; zero if SP == STACK (empty)
    jr   z, .empty

    ld   hl, (GFX_FILL_SP)
    dec  hl
    ld   c, (hl)                    ; y (pushed second, popped first)
    dec  hl
    ld   b, (hl)                    ; x
    ld   (GFX_FILL_SP), hl
    or   a                          ; clear carry: success (the SBC
                                    ; above already left it clear here
                                    ; since it wasn't zero, but stating
                                    ; it explicitly costs nothing and
                                    ; removes any doubt)
    ret
.empty:
    scf
    ret

; ============================================================================
; GFX_FILL_TRY_NEIGHBOR (internal — not in kernel_api.inc)
; Checks whether (nx,ny) still matches GFX_FILL_TARGET AND hasn't
; already been visited this fill (GFX_FILL_VISITED — see GFX_FILL's
; header for why a separate bitmap, not the pixel state itself, has
; to be the visited-tracker); if both pass, marks it visited, colors
; it, and pushes it for later expansion.
; Saves/restores BC around every call that might destroy it
; (GFX_READ_PIXEL/GFX_WRITE_PIXEL both take x/y via B/C) — (nx,ny) has
; to survive all the way to the final push.
; In:  B = nx, C = ny (caller has already bounds-checked these)
; Out: none
; Destroys: AF, DE, HL
; ============================================================================
GFX_FILL_TRY_NEIGHBOR:
    push bc
    call GFX_READ_PIXEL             ; A = pixel state at (nx,ny);
                                     ; destroys BC (its own contract)
    ld   e, a
    ld   a, (GFX_FILL_TARGET)
    cp   e
    jr   nz, .not_match

    pop  bc
    push bc                         ; restore real (nx,ny) — GFX_READ_
                                     ; PIXEL clobbered B/C above.
                                     ; GFX_FILL_VISITED_CHECK_SET only
                                     ; READS B/C (never writes them),
                                     ; so this one restore covers it.
    call GFX_FILL_VISITED_CHECK_SET ; carry SET if already visited;
                                     ; else marks it visited now
    jr   c, .not_match

    pop  bc
    push bc
    ld   d, 0                       ; always OR/set — see GFX_FILL's header
    ld   a, (GFX_FILL_ATTR)
    call GFX_WRITE_PIXEL
    pop  bc
    jr GFX_FILL_PUSH
.not_match:
    pop  bc
    ret

; ============================================================================
; GFX_FILL_VISITED_CHECK_SET (internal — not in kernel_api.inc)
; Checks GFX_FILL_VISITED (a 6144-byte, 1-bit-per-screen-pixel shadow
; bitmap — plain linear row*32+col layout, NOT the real screen's
; interleaved-thirds addressing, since this buffer has no display
; hardware to match) for pixel (x,y). If already set, returns with
; carry SET and touches nothing further. If clear, SETS it and
; returns with carry clear — same "check and claim in one call" shape
; as GFX_FILL_PUSH/POP elsewhere in this file, so a caller can't
; accidentally check without claiming or vice versa.
; In:  B = x (0-255), C = y (0-191)
; Out: carry SET if already visited; carry CLEAR if this call just
;      claimed it
; Destroys: AF, DE, HL
; ============================================================================
GFX_FILL_VISITED_CHECK_SET:
    ld   a, c                       ; y
    ld   l, a
    ld   h, 0
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl                     ; y*32
    ld   a, b                       ; x
    srl  a
    srl  a
    srl  a                          ; x>>3 (byte column, 0-31)
    ld   e, a
    ld   d, 0
    add  hl, de
    ld   de, GFX_FILL_VISITED
    add  hl, de                     ; HL = GFX_FILL_VISITED + y*32 + x/8

    ld   a, b
    and  %00000111                  ; bit_in_byte = x & 7 — same
    ld   e, a                       ; BIT_MASK_TABLE lookup
    ld   d, 0                       ; GFX_PIXEL_ADDR_SETUP already uses
    push hl
    ld   hl, BIT_MASK_TABLE
    add  hl, de
    ld   a, (hl)
    pop  hl
    ld   e, a                       ; E = mask
    ld   a, (hl)
    and  e
    jr   nz, .already
    ld   a, (hl)
    or   e
    ld   (hl), a
    or   a                          ; carry clear
    ret
.already:
    scf
    ret

; ============================================================================
; GFX_FILL
; Flood fill — FILL's mechanism. 4-connected, using an explicit
; bounded stack (GFX_FILL_PUSH/POP above) rather than recursion — see
; sysvars.inc's GFX_FILL_STACK comment for the real numbers behind why
; 2048 entries. Reuses GFX_READ_PIXEL/GFX_WRITE_PIXEL entirely for the
; actual pixel work — every touched pixel's covering attribute cell
; gets colored the normal way, no separate attribute logic needed
; here.
;
; Always writes in OR/"set" mode (never XOR/toggle) — GFX_FILL_TARGET
; still picks which pixel state (0 or 1) the flood matches and
; expands across, but every matched pixel is unconditionally set to 1
; with the new attribute, so recoloring an already-solid region is a
; clean repaint rather than an erase.
;
; Visited-tracking is a SEPARATE 6144-byte, 1-bit-per-screen-pixel
; bitmap (GFX_FILL_VISITED, cleared at the start of every call) —
; NOT folded into the bitmap write itself. Two earlier versions both
; shipped wrong, found via real hardware testing 2026-08-20, not
; caught by the ORIGINAL Python verification (which checked flood-
; connectivity/stack usage assuming "mark on push" via toggling the
; bit away from target, and never re-examined once the write mode
; changed): (1) deriving the OVER flag from the seed's own target
; value and using XOR when filling an already-set region silently
; erased the shape's bitmap on recolor, since FILL has no way to
; request "erase" from BASIC. (2) The first attempt at fixing that
; used the covering ATTRIBUTE CELL already matching the fill color as
; the "already visited" test instead — cheap (no extra memory) but
; wrong: attribute color applies to a whole 8x8 cell at once, so it
; looks "done" after the FIRST pixel in a cell is touched, but the
; flood still needs to physically walk every pixel in that cell to
; reach its far edges and cross into the NEXT cell — cell-granularity
; dedup stops that walk early and badly under-fills anything bigger
; than about one cell. A correct fix needs genuine per-PIXEL
; dedup independent of both the bitmap's own state and the attribute,
; which is what GFX_FILL_VISITED provides.
;
; Algorithm re-verified in Python before shipping this version (same
; standard the original had): a solid 51x51 box (the real failing
; case), a blank 51x51 enclosed region (the everyday "paint bucket
; into an empty area" case), and a full 256x192 screen fill against
; the real 2048-entry stack cap all checked byte-for-byte complete —
; the last one honestly stress-testing whether the existing stack
; size (already sized by the original author's own prior Python
; verification, unchanged here) still holds up under the new dedup
; scheme, not just asserting it does.
;
; In:  GFX_FILL_X/Y (seed point, 0-255/0-191), GFX_FILL_ATTR (fill
;      color) — all pre-set by the caller
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_FILL:
    ld   hl, GFX_FILL_STACK
    ld   (GFX_FILL_SP), hl          ; reset to empty

    ld   hl, GFX_FILL_VISITED       ; clear the 6144-byte visited
    ld   (hl), 0                    ; buffer — write one zero byte,
    ld   de, GFX_FILL_VISITED + 1   ; then LDIR propagates it through
    ld   bc, 6144 - 1               ; the rest (classic self-
    ldir                            ; propagating block-zero idiom)

    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call GFX_READ_PIXEL             ; A = pixel state at the seed
    ld   (GFX_FILL_TARGET), a       ; still picks which state to match

    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call GFX_FILL_VISITED_CHECK_SET ; claim the seed's own bit — carry
                                     ; ignored, buffer was just cleared
                                     ; so it can't already be set
    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    ld   d, 0                       ; always OR/set — see header
    ld   a, (GFX_FILL_ATTR)
    call GFX_WRITE_PIXEL            ; mark the seed itself filled
    ld   a, (GFX_FILL_X)
    ld   b, a
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call GFX_FILL_PUSH

.loop:
    call GFX_FILL_POP
    ret  c                          ; stack empty: done

    ld   a, b
    ld   (GFX_FILL_X), a            ; the pixel currently being
    ld   a, c                      ; expanded — GFX_FILL_TRY_NEIGHBOR/
    ld   (GFX_FILL_Y), a            ; PUSH/POP never touch these, only
                                    ; B/C, specifically so this survives
                                    ; unclobbered across all 4 checks
                                    ; below

    ; (x+1, y)
    ld   a, (GFX_FILL_X)
    cp   255
    jr   z, .skip_right
    ld   b, a
    inc  b
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call GFX_FILL_TRY_NEIGHBOR
.skip_right:

    ; (x-1, y)
    ld   a, (GFX_FILL_X)
    or   a
    jr   z, .skip_left
    ld   b, a
    dec  b
    ld   a, (GFX_FILL_Y)
    ld   c, a
    call GFX_FILL_TRY_NEIGHBOR
.skip_left:

    ; (x, y+1)
    ld   a, (GFX_FILL_Y)
    cp   191
    jr   nc, .skip_down
    ld   c, a
    inc  c
    ld   a, (GFX_FILL_X)
    ld   b, a
    call GFX_FILL_TRY_NEIGHBOR
.skip_down:

    ; (x, y-1)
    ld   a, (GFX_FILL_Y)
    or   a
    jr   z, .skip_up
    ld   c, a
    dec  c
    ld   a, (GFX_FILL_X)
    ld   b, a
    call GFX_FILL_TRY_NEIGHBOR
.skip_up:

    jr   .loop

; ============================================================================
; GFX_CIRCLE_PLOT_OFFSET (internal — not in kernel_api.inc)
; Shared per-point helper for GFX_CIRCLE — adds a signed (dx,dy) offset
; to the circle's center and plots the result via GFX_PLOT_CLIPPED
; (off-screen points are common here — a circle's own bounding box
; routinely extends past the screen edge — not an edge case).
; In:  HL = dx (signed 16-bit, offset from center x), DE = dy (signed
;      16-bit, offset from center y)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_CIRCLE_PLOT_OFFSET:
    push de                          ; stash dy across the xc addition
    ld   a, (GFX_CIRCLE_XC)
    ld   e, a
    ld   d, 0
    add  hl, de                      ; HL = xc + dx
    pop  de                          ; DE = dy (restored)
    push hl                          ; stash x-result across the yc
                                     ; addition
    ld   a, (GFX_CIRCLE_YC)
    ld   l, a
    ld   h, 0
    add  hl, de                      ; HL = yc + dy
    ex   de, hl                      ; DE = yc+dy (the y result)
    pop  hl                          ; HL = xc+dx (the x result,
                                     ; restored)
    ld   a, (GFX_CIRCLE_OVER)
    ld   b, a
    ld   a, (GFX_CIRCLE_ATTR)
    jp GFX_PLOT_CLIPPED

; ============================================================================
; GFX_CIRCLE_PLOT_POLES (internal — not in kernel_api.inc)
; Plots the 4 unique points at x=0 — the circle's top, bottom, left,
; and right. Called once, before GFX_CIRCLE's main loop, instead of
; letting the general 8-point logic run at x=0: verified in Python
; that the general formula's 8 offsets collapse to only 4 unique
; points there ((x,y) and (-x,y) are literally the same point when
; x=0, etc.) — plotting all 8 would double-plot each one, which is
; harmless under OVER 0 but wrong under OVER 1 (a second XOR-toggle
; cancels the first).
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_CIRCLE_PLOT_POLES:
    ; (0, +y)
    ld   a, (GFX_CIRCLE_Y)
    ld   e, a
    ld   d, 0
    ld   hl, 0
    call GFX_CIRCLE_PLOT_OFFSET
    ; (+y, 0)
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    ld   de, 0
    call GFX_CIRCLE_PLOT_OFFSET
    ; (-y, 0)
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ld   de, 0
    call GFX_CIRCLE_PLOT_OFFSET
    ; (0, -y)
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   hl, 0
    jr GFX_CIRCLE_PLOT_OFFSET

; ============================================================================
; GFX_CIRCLE_PLOT_GENERAL (internal — not in kernel_api.inc)
; Plots up to 8 symmetric points for the current (GFX_CIRCLE_X,
; GFX_CIRCLE_Y) — called only from the main loop, where x>=1 (x=0 is
; GFX_CIRCLE_PLOT_POLES's job, above). Skips the "swapped" 4 points
; when x==y — verified in Python that they exactly coincide with the
; first 4 in that case (the diagonal — (x,y) and (y,x) are the same
; point when x=y), same double-plot-under-OVER-1 reasoning as the
; poles case.
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_CIRCLE_PLOT_GENERAL:
    ; (x,y)
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call GFX_CIRCLE_PLOT_OFFSET
    ; (-x,y)
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    call GFX_CIRCLE_PLOT_OFFSET
    ; (x,-y)
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call GFX_CIRCLE_PLOT_OFFSET
    ; (-x,-y)
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    call GFX_CIRCLE_PLOT_OFFSET

    ; the "swapped" 4 points only apply when x != y — see this
    ; routine's own header
    ld   a, (GFX_CIRCLE_X)
    ld   b, a
    ld   a, (GFX_CIRCLE_Y)
    cp   b
    ret  z

    ; (y,x)
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call GFX_CIRCLE_PLOT_OFFSET
    ; (-y,x)
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    call GFX_CIRCLE_PLOT_OFFSET
    ; (y,-x)
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call GFX_CIRCLE_PLOT_OFFSET
    ; (-y,-x)
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    ex   de, hl
    ld   a, (GFX_CIRCLE_Y)
    ld   l, a
    ld   h, 0
    call MATH_NEGATE16
    jp GFX_CIRCLE_PLOT_OFFSET

; ============================================================================
; GFX_CIRCLE
; Draws a circle outline via the midpoint circle algorithm (8-way
; symmetry) — integer only, matching this project's pure-integer
; BASIC. Verified in Python against a reference implementation before
; any Z80 was written — 309 circles (edge cases including r=0 and
; radii far larger than the screen, plus 300 random center/radius
; combinations), zero mismatches — including the specific x=0 and
; x==y point-deduplication this routine relies on (see GFX_CIRCLE_
; PLOT_POLES/_GENERAL) and the discovery that the decision variable's
; x-y term needs real 16-bit width (observed up to +/-238 during
; verification, well outside an 8-bit signed byte's range).
; In:  GFX_CIRCLE_XC/YC/R/ATTR/OVER, all pre-set by the caller
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
GFX_CIRCLE:
    ld   a, (GFX_CIRCLE_R)
    or   a
    jr   nz, .r_nonzero

    ; r=0: a circle of radius zero is just its center pixel
    ld   a, (GFX_CIRCLE_XC)
    ld   l, a
    ld   h, 0
    ld   a, (GFX_CIRCLE_YC)
    ld   e, a
    ld   d, 0
    ld   a, (GFX_CIRCLE_OVER)
    ld   b, a
    ld   a, (GFX_CIRCLE_ATTR)
    jp GFX_PLOT_CLIPPED

.r_nonzero:
    xor  a
    ld   (GFX_CIRCLE_X), a           ; x = 0
    ld   a, (GFX_CIRCLE_R)
    ld   (GFX_CIRCLE_Y), a           ; y = r

    ; d = 1 - r (signed 16-bit)
    ld   hl, 1
    ld   e, a
    ld   d, 0
    or   a
    sbc  hl, de
    ld   (GFX_CIRCLE_D), hl

    call GFX_CIRCLE_PLOT_POLES        ; the x=0 case, handled once

.loop:
    ; x += 1
    ld   a, (GFX_CIRCLE_X)
    inc  a
    ld   (GFX_CIRCLE_X), a

    ld   hl, (GFX_CIRCLE_D)
    bit  7, h
    jr   z, .d_not_negative

    ; d < 0: d += 2x+1
    ld   a, (GFX_CIRCLE_X)
    ld   e, a
    ld   d, 0
    add  hl, de
    add  hl, de
    inc  hl
    ld   (GFX_CIRCLE_D), hl
    jr   .step_done

.d_not_negative:
    ; y -= 1; d += 2(x-y)+1 — x-y computed as a genuine 16-bit signed
    ; subtract (zero-extending both x and the just-decremented y first,
    ; not an 8-bit SUB — see this routine's own header on why that
    ; matters)
    ld   a, (GFX_CIRCLE_Y)
    dec  a
    ld   (GFX_CIRCLE_Y), a
    ld   e, a
    ld   d, 0                        ; DE = y (zero-extended)
    ld   a, (GFX_CIRCLE_X)
    ld   l, a
    ld   h, 0                        ; HL = x (zero-extended)
    or   a
    sbc  hl, de                      ; HL = x - y (real 16-bit signed)
    add  hl, hl                      ; HL = 2*(x-y)
    inc  hl                          ; HL = 2*(x-y)+1
    ex   de, hl                      ; DE = 2*(x-y)+1
    ld   hl, (GFX_CIRCLE_D)
    add  hl, de
    ld   (GFX_CIRCLE_D), hl

.step_done:
    ; continue while x <= y
    ld   a, (GFX_CIRCLE_X)
    ld   b, a
    ld   a, (GFX_CIRCLE_Y)
    cp   b
    ret  c                            ; y < x -> done

    call GFX_CIRCLE_PLOT_GENERAL
    jr   .loop

BIT_MASK_TABLE:
    DB   %10000000, %01000000, %00100000, %00010000
    DB   %00001000, %00000100, %00000010, %00000001

; ---- screen-row base addresses, computed and verified numerically
; (see file header) rather than derived by hand from the bit-shuffle
; formula ----
; ---- punctuation character -> font index lookup, used by
; GFX_CHAR_TO_FONT_OFFSET's table scan. Only the double-quote character
; needs single-quote delimiters here (to avoid self-conflict); every
; other character, including the apostrophe, safely uses double-quote
; delimiters instead — mirrors the convention already proven working
; for the standalone quote check this replaced. ----
PUNCT_CHAR_TABLE:
    DB   '"', 63
    DB   "!", 64
    DB   "@", 65
    DB   "#", 66
    DB   "$", 67
    DB   "%", 68
    DB   "&", 69
    DB   "'", 70
    DB   "(", 71
    DB   ")", 72
    DB   "_", 73
    DB   ":", 74
    DB   ".", 75
    DB   ",", 76
    DB   "=", 77
    DB   "+", 78
    DB   "-", 79
    DB   ";", 80
    DB   "/", 81
    DB   "*", 82
    DB   "<", 83
    DB   ">", 84
    DB   "?", 85
PUNCT_CHAR_COUNT EQU 23

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
    ; '1'
    DB   $20, $60, $20, $20, $20, $20, $70, $00
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
    ; 'g'
    DB   $00, $78, $88, $88, $78, $08, $70, $00
    ; 'h'
    DB   $80, $80, $B0, $C8, $88, $88, $88, $00
    ; 'i'
    DB   $20, $00, $60, $20, $20, $20, $70, $00
    ; 'j'
    DB   $10, $00, $30, $10, $10, $10, $90, $60
    ; 'k'
    DB   $80, $80, $90, $A0, $C0, $A0, $90, $00
    ; 'l'
    DB   $60, $20, $20, $20, $20, $20, $70, $00
    ; 'm'
    DB   $00, $00, $D0, $A8, $A8, $88, $88, $00
    ; 'n'
    DB   $00, $00, $B0, $C8, $88, $88, $88, $00
    ; 'o'
    DB   $00, $00, $70, $88, $88, $88, $70, $00
    ; 'p'
    DB   $00, $F0, $88, $88, $F0, $80, $80, $80
    ; 'q'
    DB   $00, $78, $88, $88, $78, $08, $08, $08
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
    ; '_'
    DB   $00, $00, $00, $00, $00, $00, $F8, $00
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

.row_loop:
    xor  a
    ld   (SPRITE_COL_IDX), a
.col_loop:
    call GFX_SPRITE_CELL_ROWCOL         ; B = real row, C = real col
    call GFX_CELL_BITMAP_ADDR           ; HL = screen bitmap addr
                                        ; (scanline 0) — B/C untouched
                                        ; by this call (see its own
                                        ; header)
    ld   de, (SPRITE_BUF_PTR)           ; DE = buffer write pointer

    ld   b, 8
.scan_loop:
    ld   a, (hl)
    ld   (de), a
    inc  de
    ld   a, h
    add  a, 1                          ; next scanline: +256 to the
                                       ; address (same non-linear
                                       ; screen layout GFX_PUTCHAR/
                                       ; GFX_CPLOT already step through
                                       ; this same way)
    ld   h, a
    djnz .scan_loop

    ; B/C were clobbered by the DJNZ loop above — recompute before the
    ; attribute address call, same "reload from memory, don't trust a
    ; register survived a destructive call" discipline as GFX_CPLOT's
    ; own scratch handling
    ;
    ; REAL BUG FOUND (2026-08-19, z80sim, not caught by inspection or
    ; check_asm.py): DE holds the buffer's attribute-slot address at
    ; this point (buf_ptr+8) — but GFX_CELL_ATTR_ADDR's own documented
    ; contract destroys DE (it uses DE as scratch internally, same as
    ; GFX_SET_ATTR's proven address math it mirrors). The original
    ; version called GFX_SPRITE_CELL_ROWCOL/GFX_CELL_ATTR_ADDR here
    ; with no protection, silently clobbering DE before the `ld (de),a`
    ; below ever ran — exactly lesson 1's register-survival bug class,
    ; this time self-inflicted rather than inherited. z80sim caught it
    ; immediately (buffer contents correct for 8 bitmap bytes, garbage
    ; after) where static inspection hadn't. Fix: stash DE across both
    ; calls, same push/pop-around-a-destructive-call pattern GFX_
    ; SPRITE_DRAW's own `push af`/`pop af` below already uses for
    ; exactly this reason.
    push de
    call GFX_SPRITE_CELL_ROWCOL
    call GFX_CELL_ATTR_ADDR             ; HL = screen attr addr
    ld   a, (hl)
    pop  de                             ; DE = buffer's attribute slot,
                                        ; restored
    ld   (de), a
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

.row_loop:
    xor  a
    ld   (SPRITE_COL_IDX), a
.col_loop:
    call GFX_SPRITE_CELL_ROWCOL         ; B = real row, C = real col
    call GFX_CELL_BITMAP_ADDR           ; HL = screen bitmap addr
                                        ; (scanline 0)
    ex   de, hl                         ; DE = screen dest addr now
    ld   hl, (SPRITE_BUF_PTR)           ; HL = buffer read pointer

    ld   b, 8
.scan_loop:
    ld   a, (hl)
    ld   (de), a
    inc  hl
    ld   a, d
    add  a, 1                          ; next scanline: +256 to the
                                       ; SCREEN address (DE this time,
                                       ; not HL — source/dest swapped
                                       ; from CAPTURE)
    ld   d, a
    djnz .scan_loop

    ; HL now points at this cell's attribute byte in the buffer
    ld   a, (hl)
    inc  hl
    ld   (SPRITE_BUF_PTR), hl           ; advance past this cell's 9
                                        ; bytes total
    push af                             ; stash the attribute byte —
                                        ; GFX_SPRITE_CELL_ROWCOL/
                                        ; GFX_CELL_ATTR_ADDR both
                                        ; destroy A
    call GFX_SPRITE_CELL_ROWCOL
    call GFX_CELL_ATTR_ADDR             ; HL = screen attr addr
    pop  af
    ld   (hl), a

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
