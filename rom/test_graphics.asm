; ============================================================================
; rom/test_graphics.asm — kernel/graphics visual test
;
; Not a pass/fail test like rom/test_memory.asm — there's no formula to
; check glyph SHAPES against, only your eyes. Prints the entire font
; table (space, 0-9, A-Z, a-z, punctuation) across six rows so every
; glyph can be checked in one screenshot, then sets the border cyan as
; a "finished rendering, go look at the screen" signal — not a
; verdict, just "done."
;
; Row 5's punctuation string was corrected alongside adding '<'/'>':
; it had already drifted out of sync with FONT_TABLE once before (`/`
; and `*` were added to the font and keyboard when basic/'s expression
; evaluator needed them, but this test file's row 5 string was never
; updated to include them) — now covers all 22 punctuation glyphs.
;
; What to check: do the letters/digits look like what they're supposed
; to be? Any glyph that's garbled, mirrored, or clearly wrong is a bug
; in FONT_TABLE (kernel/graphics/graphics.asm) — tell me which
; character and what it looks like instead.
;
; This also serves as the first real test of GFX_CLS and the screen
; addressing math (ROW_BASE_TABLE) together — if the address math were
; wrong, you'd likely see garbled/overlapping/misplaced text rather
; than clean rows, even before considering whether individual glyphs
; look right.
;
; NOT YET ASSEMBLED OR TESTED BY THE AUTHOR — reviewed-by-eye only.
;
; Build:
;   sjasmplus rom/test_graphics.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_graphics.bin --rom-ts2068-1 rom1.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"      ; UDG_TABLE, for the row-7 UDG
                                       ; POKE-simulation below

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call GFX_CLS

    ld   hl, ROW0_TEXT
    ld   b, 0
    ld   c, 0
    call GFX_PRINT_STRING

    ld   hl, ROW1_TEXT
    ld   b, 2
    ld   c, 0
    call GFX_PRINT_STRING

    ld   hl, ROW2_TEXT
    ld   b, 4
    ld   c, 0
    call GFX_PRINT_STRING

    ld   hl, ROW3_TEXT
    ld   b, 6
    ld   c, 0
    call GFX_PRINT_STRING

    ld   hl, ROW4_TEXT
    ld   b, 8
    ld   c, 0
    call GFX_PRINT_STRING

    ld   hl, ROW5_TEXT
    ld   b, 10
    ld   c, 0
    call GFX_PRINT_STRING

    ; Row 6: all 16 block-graphics characters (128-143), algorithmically
    ; generated at print time by GFX_CHAR_TO_FONT_OFFSET's .is_block_
    ; graphics branch, not stored as glyph data — see that routine's
    ; own header (2026-08-22). Expected shapes, left to right: blank,
    ; then every combination of the four quadrants filling in (top-
    ; right first per the confirmed bit0 mapping, then top-left,
    ; bottom-right, bottom-left), ending solid at code 143.
    ld   hl, ROW6_TEXT
    ld   b, 12
    ld   c, 0
    call GFX_PRINT_STRING

    ; Row 7: three UDGs (144-146), POKE-defined here the same way a
    ; running BASIC program would (raw writes into UDG_TABLE) rather
    ; than pre-supplied glyph data — real hardware never ships default
    ; UDG art either. Patterns: a filled diamond, a checkerboard, and a
    ; single diagonal stripe — chosen to be visually easy to verify by
    ; eye and distinct from every block-graphics/font shape above.
    ld   hl, UDG_DIAMOND
    ld   de, UDG_TABLE
    ld   bc, 8
    ldir
    ld   hl, UDG_CHECKER
    ld   de, UDG_TABLE + 8
    ld   bc, 8
    ldir
    ld   hl, UDG_STRIPE
    ld   de, UDG_TABLE + 16
    ld   bc, 8
    ldir

    ld   hl, ROW7_TEXT
    ld   b, 14
    ld   c, 0
    call GFX_PRINT_STRING

    ld   a, 5                  ; cyan — "finished rendering" signal
    out  (PORT_ULA), a
    jr   $

; ---- test strings covering every glyph in FONT_TABLE ----
ROW0_TEXT: DB " 0123456789", 0
ROW1_TEXT: DB "ABCDEFGHIJKLMNOP", 0
ROW2_TEXT: DB "QRSTUVWXYZ", 0
ROW3_TEXT: DB "abcdefghijklmnop", 0
ROW4_TEXT: DB "qrstuvwxyz", 0
ROW5_TEXT: DB '"', "!@#$%&'()_:.,=+-;/*<>", 0
ROW6_TEXT: DB 128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143, 0
ROW7_TEXT: DB 144,145,146, 0

; Row-7 UDG test patterns — raw 8-byte bitmaps, written into UDG_TABLE
; at runtime above rather than declared as real FONT_TABLE-style glyph
; data, since UDGs are never ROM-resident on real hardware (see
; GFX_CHAR_TO_FONT_OFFSET's .is_udg header).
UDG_DIAMOND:
    DB   $10, $38, $7C, $FE, $7C, $38, $10, $00
UDG_CHECKER:
    DB   $CC, $CC, $33, $33, $CC, $CC, $33, $33
UDG_STRIPE:
    DB   $80, $40, $20, $10, $08, $04, $02, $01

    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"      ; graphics.asm's LINE/CIRCLE
                                        ; call MATH_NEGATE16/COMPARE16
                                        ; — this file never actually
                                        ; assembled before this was
                                        ; added (2026-08-22, see this
                                        ; file's own former "NOT YET
                                        ; ASSEMBLED" header note)

    DS   $4000 - $, $FF

    SAVEBIN "test_graphics.bin", $0000, $4000
