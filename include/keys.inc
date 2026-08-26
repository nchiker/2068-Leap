; ============================================================================
; keys.inc — symbolic key/ASCII constants
;
; KEY_ENTER is confirmed — the keyboard matrix's ENTER position translates
; to $0D in kernel/io/io.asm's KEY_ASCII_TABLE, which happens to match
; LINE_TERMINATOR in kernel/memory/memory.asm ($0D) — not a coincidence
; forced by this file, just both independently landing on the standard
; ASCII carriage-return value, which is conveniently consistent.
;
; CORRECTED: an earlier draft of this file left cursor keys undefined,
; on the wrong assumption that the TS2068 has dedicated cursor keys with
; an unconfirmed matrix position. It doesn't — the TS2068 keyboard is
; laid out the same as the original Spectrum (see docs/hardware_notes.md),
; so the standard CAPS SHIFT+5/6/7/8/0 combo scheme applies directly and
; these ARE confirmed. Values chosen from the low control-code range
; (below $20), clear of every printable ASCII value used in
; KEY_ASCII_TABLE and clear of KEY_ENTER ($0D).
; ============================================================================

    IFNDEF KEYS_INC
    DEFINE KEYS_INC

KEY_ENTER         EQU $0D
KEY_CURSOR_LEFT   EQU $01
KEY_CURSOR_DOWN   EQU $02
KEY_CURSOR_UP     EQU $03
KEY_CURSOR_RIGHT  EQU $04
KEY_DELETE        EQU $08   ; CAPS SHIFT + 0 — matches classic ASCII
                            ; backspace ($08), a natural fit for what
                            ; this combo does
KEY_INSERT_LINE   EQU $0B   ; CAPS SHIFT + ENTER — inserts a blank
                            ; statement before the one being edited
                            ; (basic/'s own concept; kernel/io just
                            ; reports the key, kernel/editor forwards
                            ; it through the same nav-hook mechanism
                            ; already used for UP/DOWN). Project-
                            ; specific combo — not verified against
                            ; real hardware docs either way, unlike the
                            ; digit-row combos (which DO have
                            ; documented real meanings this project
                            ; deliberately doesn't implement)
KEY_NEXT_ERROR    EQU $0C   ; SYMBOL SHIFT + A — jump to the next
                            ; statement basic/'s check pass flagged
                            ; (basic/'s own concept, same forwarding
                            ; mechanism as KEY_INSERT_LINE). Row 1 of
                            ; SYMBOL SHIFT's table (A-G) gives keyword
                            ; tokens on real hardware and is otherwise
                            ; deliberately left unmapped in this
                            ; project (see kernel/io's own header) —
                            ; project-specific here for the same
                            ; reason KEY_INSERT_LINE is, not a real
                            ; hardware meaning being reused
KEY_PREV_ERROR    EQU $0E   ; SYMBOL SHIFT + S — same as
                            ; KEY_NEXT_ERROR, previous direction
KEY_DELETE_LINE   EQU $0F   ; CAPS SHIFT + 1 — deletes the whole
                            ; current line in one keystroke (unlike
                            ; KEY_DELETE, which only deletes the
                            ; current line once its buffer is already
                            ; empty). Project-specific combo, same
                            ; reasoning as KEY_INSERT_LINE/
                            ; KEY_NEXT_ERROR: CAPS SHIFT+1 has no
                            ; historical Spectrum-family meaning (see
                            ; KEY_ASCII_TABLE_UPPER's row-3 comment in
                            ; kernel/io/io.asm), so this doesn't
                            ; conflict with real hardware behavior.
KEY_BREAK         EQU $10   ; CAPS SHIFT + SPACE (row 7, bit 0) —
                            ; this is the standard, confirmed Spectrum-
                            ; family BREAK combo (see
                            ; docs/hardware_notes.md), NOT a project-
                            ; specific one. Deliberately scoped this
                            ; way: whether the TS2068's added physical
                            ; BREAK keycap is a genuinely separate
                            ; matrix position, or the same electrical
                            ; combo under a different keycap, is still
                            ; unconfirmed — implementing the confirmed
                            ; standard combo covers the "different
                            ; keycap" case either way, and a real
                            ; separate matrix position (if the BREAK
                            ; keycap turns out to be one) remains
                            ; unimplemented until checked against
                            ; hardware.

    ENDIF
