; ============================================================================
; rom/exrom_printer.asm — LPRINT and LLIST (real ZX Printer output)
;
; Pushed to EXROM entirely, same migration pattern as SOUND/SPRITE/HELP —
; see rom/exrom_sound.asm's own header. The only Home-resident pieces are
; BASIC_STMT_LPRINT (shares BASIC_EVAL_PRINT_ARG with PRINT — basic/
; basic.asm), the thin BASIC_LPRINT_EXROM/BASIC_LLIST_EXROM page-in/call/
; page-out wrappers, KW_LLIST's immediate-command dispatch (LLIST, like
; LIST, is immediate-only), and one new selector value (D=6) on the
; EXISTING BASIC_INPUT_SERVICE gateway that this file's own row renderer
; calls through for glyph lookups — see that gateway's own comment for
; why (the KTAB callback window this would otherwise have needed is
; already fully packed; extending an existing gateway needed no new
; fixed-address slot at all).
;
; HARDWARE PROTOCOL (PORT_PRINTER = $FB, include/hardware.inc) — ported
; from the sibling 2068-forth project's core/printer.asm, whose own
; header documents the full derivation and verification history: this
; exact bit-bang sequence was checked against a real, verbatim Timex
; Sinclair 2068 ROM disassembly (COPY-LINE at M0A4A) and confirmed via
; a real Fuse retest producing a correct 256x8 .pbm raster. Not
; re-derived here — see that file for the "why" behind every write/
; poll below; hardware.inc's own PORT_PRINTER comment has the short
; version.
;
; RASTER FORMAT: one printed line is 256 dot columns (32 characters x 8
; pixels), 8 dot ROWS tall, MSB-first within each byte. The last two of
; the 8 rows go out at slow motor speed (matches the real ROM's own
; scan-line countdown), presumably to let the paper-feed mechanism
; settle before the next character row begins.
;
; RAM SHAPE (deliberately NOT 2068-forth's shape): that project renders
; a whole 256-byte (8-row) line into a buffer before sending any of it.
; This one renders and sends ONE 32-byte ROW at a time into sysvars.
; inc's own PRINT_ROW_BUF, re-running the char->glyph lookup once per
; row instead of once per line (8x more BASIC_INPUT_SERVICE round trips)
; to avoid paying 256 bytes of resident RAM for a full line buffer —
; printer output is already mechanically slow enough (each dot column
; polls a hardware ready bit) that the extra lookups cost nothing
; observable.
;
; WHAT THIS ADDS:
;   LPRINT ( same single string-or-numeric-expr grammar as PRINT )
;      prints the evaluated text to the real ZX Printer instead of the
;      screen, wrapped into as many 32-column printed lines as needed
;      (the last space-padded if shorter than 32; an empty string
;      still prints exactly one blank line, matching classic LPRINT).
;   LLIST ( no argument )
;      prints the CURRENT PROGRAM's own stored lines to the printer,
;      one program line per printed line (also wrapped/padded to 32
;      columns), in program order — this project's own program lines
;      are stored as plain text (BASIC_TOKENIZE_LINE's own header: "no
;      keyword compression"), so this is a direct walk of MEM_LINE_
;      FIRST/MEM_LINE_NEXT with no detokenizing step needed. This
;      dialect has no classic line numbers (labels replace them — see
;      docs/basic_language_reference.md), so none are printed, matching
;      what the on-screen editor already shows.
; ============================================================================

; ============================================================================
; PRINTER_MOTOR_STOP -- NOT a BASIC entry point.
; ============================================================================
PRINTER_MOTOR_STOP:
    ld   a, %00000100
    out  (PORT_PRINTER), a
    ret

; ============================================================================
; PRINT_RASTER_ROW ( HL = 32-byte row buffer, A = 1 for slow speed
; else 0 -- not a BASIC entry point ) — bit-bangs one 256-dot raster
; row, MSB-first within each byte. Returns early only if the printer
; explicitly reports "not configured" (port read bit 6) — real hardware
; sets this for a specific fault condition, not merely "no printer
; attached at all"; with NO printer attached (the common case: real
; hardware with none connected, or Fuse without its ZX Printer
; peripheral enabled — this build's own `fuse --help` has no flag for
; it) the port read floats and bit 7 ("start of paper") never comes,
; so .wait_paper below spins forever. CONFIRMED by direct test
; (2026-09-14): a real LPRINT run under this environment's Fuse, no
; printer attached, hangs exactly here — never reaches its own trailing
; BORDER 2 even after 15+ seconds. This is NOT a bug: it matches real
; Sinclair BASIC's own well-documented behavior (LPRINT with no ZX
; Printer connected hangs a real Spectrum/TS2068 the same way) — see
; this project's own tests/ directory note on why no automated fixture
; exercises LPRINT/LLIST end-to-end.
; Destroys: AF, BC, DE, HL
; ============================================================================
PRINT_RASTER_ROW:
    add  a, a               ; speed bit into position 1 (%00000010)
    ld   c, a                ; c = this row's own combined baseline
                              ; (bit2=0 run, bit1=speed, bit7=0) --
                              ; reused below for every real pixel too
    out  (PORT_PRINTER), a   ; per-row setup write -- unconditional, no
                              ; poll (matches the real ROM's own once-
                              ; per-scan-line write)
.wait_paper:
    in   a, (PORT_PRINTER)
    bit  6, a
    ret  nz                   ; "printer not configured" fault -- abort,
                                ; same as the real ROM (see this
                                ; routine's own header: this does NOT
                                ; cover "no printer at all", which
                                ; hangs below instead, matching real
                                ; hardware)
    bit  7, a
    jr   z, .wait_paper          ; not yet "start of paper" -- keep
                                   ; waiting
    ld   b, 32                     ; 32 bytes = 256 dot columns
.byteloop:
    ld   e, (hl)
    inc  hl
    ld   d, 8                  ; 8 bits in this byte
.bitloop:
    rlc  e                       ; original bit 7 of e -> carry
                                  ; (MSB-first)
    ld   a, 0
    jr   nc, .stylus_off
    ld   a, %10000000
.stylus_off:
    or   c
    push af                        ; save the byte to send -- IN below
                                     ; will overwrite A
.waitready:
    in   a, (PORT_PRINTER)
    and  1
    jr   z, .waitready
    pop  af
    out  (PORT_PRINTER), a
    dec  d
    jr   nz, .bitloop
    djnz .byteloop
    ret

; ============================================================================
; PRINTER_RENDER_ROW ( -- ) -- not a BASIC entry point. Renders raster
; row PRINT_ROW_IDX (0-7) of the PRINT_CHUNK_LEN real characters at
; PRINT_CHUNK_ADDR into PRINT_ROW_BUF, space-padding columns past
; PRINT_CHUNK_LEN. A character with no glyph at all renders as a blank
; column, same treatment GFX_PUTCHAR gives it. Font lookups go through
; KTAB_BASIC_INPUT_SERVICE's D=6 selector (basic/basic.asm) — EXROM is
; a separate compilation unit and GFX_CHAR_TO_FONT_OFFSET has no direct
; KTAB entry of its own (see this module's own header for why).
; Destroys: AF, BC, DE, HL
; ============================================================================
PRINTER_RENDER_ROW:
    xor  a
    ld   b, a                    ; b = current column (0-31)
.colloop:
    ld   a, b
    cp   32
    ret  z
    ld   a, (PRINT_CHUNK_LEN)
    cp   b
    jr   z, .usespace              ; len==col: past the real text
    jr   c, .usespace                ; len<col: also past the real text
    push bc
    ld   hl, (PRINT_CHUNK_ADDR)
    ld   c, b
    ld   b, 0
    add  hl, bc
    ld   a, (hl)                     ; a = this column's real character
    pop  bc
    jr   .havechar
.usespace:
    ld   a, " "
.havechar:
    push bc
    ld   a, (PRINT_ROW_IDX)
    ld   c, a                            ; c = row (D=6's own contract)
    ld   d, 6
    call KTAB_BASIC_INPUT_SERVICE          ; a = glyph byte for this
                                           ; row (0 if no glyph)
    pop  bc
    ld   hl, PRINT_ROW_BUF
    ld   e, b
    ld   d, 0
    add  hl, de
    ld   (hl), a
    inc  b
    jr   .colloop

; ============================================================================
; PRINTER_SEND_CHUNK ( -- ) -- not a BASIC entry point. Renders and
; sends the 8 raster rows of the PRINT_CHUNK_LEN-character chunk at
; PRINT_CHUNK_ADDR (rows 6-7 at slow speed, matching the real ROM's own
; scan-line countdown), then stops the motor once at the end.
; Destroys: AF, BC, DE, HL
; ============================================================================
PRINTER_SEND_CHUNK:
    xor  a
    ld   (PRINT_ROW_IDX), a
.rowloop:
    call PRINTER_RENDER_ROW
    ld   hl, PRINT_ROW_BUF
    ld   a, (PRINT_ROW_IDX)
    cp   6
    jr   c, .fastspeed
    ld   a, 1                      ; rows 6-7: slow
    jr   .callrow
.fastspeed:
    xor  a
.callrow:
    call PRINT_RASTER_ROW
    ld   a, (PRINT_ROW_IDX)
    inc  a
    ld   (PRINT_ROW_IDX), a
    cp   8
    jr   c, .rowloop
    jp   PRINTER_MOTOR_STOP

; ============================================================================
; PRINTER_SEND_TEXT ( HL = addr, BC = len -- ) -- not a BASIC entry
; point. Prints len characters starting at addr, wrapped into as many
; 32-column printed lines as needed (the last space-padded if shorter
; than 32). len=0 still sends exactly one blank line — matches classic
; LPRINT's own "printing nothing still advances the paper one line"
; behavior. Shared by both LPRINT (one call, the whole evaluated
; string) and LLIST (one call per stored program line).
; Destroys: AF, BC, DE, HL
; ============================================================================
PRINTER_SEND_TEXT:
    ld   (PRINT_REMAINING), bc
    ld   (PRINT_CUR_ADDR), hl
.lineloop:
    ld   hl, (PRINT_REMAINING)
    ld   a, h
    or   a
    jr   nz, .chunk32           ; remaining >= 256: definitely >= 32
    ld   a, l
    cp   32
    jr   nc, .chunk32
    ld   (PRINT_CHUNK_LEN), a    ; remaining < 32: chunk = remaining
    jr   .havechunk
.chunk32:
    ld   a, 32
    ld   (PRINT_CHUNK_LEN), a
.havechunk:
    ld   hl, (PRINT_CUR_ADDR)
    ld   (PRINT_CHUNK_ADDR), hl
    call PRINTER_SEND_CHUNK
    ld   a, (PRINT_CHUNK_LEN)
    ld   e, a
    ld   d, 0
    ld   hl, (PRINT_CUR_ADDR)
    add  hl, de
    ld   (PRINT_CUR_ADDR), hl
    ld   hl, (PRINT_REMAINING)
    or   a
    sbc  hl, de
    ld   (PRINT_REMAINING), hl
    ld   a, h
    or   l
    jr   nz, .lineloop            ; more left: another full-or-partial
                                    ; chunk; len=0 already sent its one
                                    ; blank chunk above and exits here
                                    ; on the first pass
    ret

; ============================================================================
; BASIC_STMT_LPRINT_EXROM ( HL = null-terminated text -- ) -- EXROM_
; ENTRY_LPRINT's real body. Measures the string's length, then hands
; off to PRINTER_SEND_TEXT. HL is provided by BASIC_EVAL_PRINT_ARG
; (basic/basic.asm), the same shared evaluator PRINT itself uses.
; Out: carry always clear on return — but see PRINT_RASTER_ROW's own
;      header: with no real ZX Printer attached this never returns at
;      all (matches real Sinclair BASIC's own LPRINT behavior)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_LPRINT_EXROM:
    push hl
    ld   bc, 0
.strlen:
    ld   a, (hl)
    or   a
    jr   z, .havelen
    inc  hl
    inc  bc
    jr   .strlen
.havelen:
    pop  hl
    call PRINTER_SEND_TEXT
    or   a
    ret

; ============================================================================
; BASIC_STMT_LLIST_EXROM ( -- ) -- EXROM_ENTRY_LLIST's real body.
; Walks the program area via KTAB_MEM_LINE_FIRST/KTAB_MEM_LINE_NEXT,
; sending each stored statement's own text to the printer. The 2-byte
; length prefix on each record (kernel/memory's own LINE_LEN_SIZE,
; value 2 — EXROM is a separate compilation unit and can't reference
; that Home label directly, same "Label not found" trap this project's
; other EXROM modules already document) counts content bytes plus a
; trailing $0D terminator, so content length is (stored length - 1).
; Out: carry always clear
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_LLIST_EXROM:
    call KTAB_MEM_LINE_FIRST
.walkloop:
    ld   a, h
    or   l
    jr   z, .done                 ; end of the program
    ld   (PRINT_LLIST_LINE), hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                   ; de = stored length (content + $0D)
    inc  hl                        ; hl -> content start
    dec  de                        ; de = real content length
    push hl
    ld   b, d
    ld   c, e
    pop  hl
    call PRINTER_SEND_TEXT
    ld   hl, (PRINT_LLIST_LINE)
    call KTAB_MEM_LINE_NEXT
    jr   .walkloop
.done:
    or   a
    ret
