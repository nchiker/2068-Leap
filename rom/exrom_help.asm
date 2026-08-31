; ============================================================================
; rom/exrom_help.asm — HELP migrated to EXROM
;
; NOT yet hardware/emulator-confirmed. Third subsystem migrated onto
; the EXROM trampoline, same pattern the checker (rom/exrom_checker.
; asm) and SAVE/LOAD (rom/exrom_storage.asm) already proved on real
; hardware. Picked as the next move because it's the safest kind
; available: pure text data (a dozen null-terminated strings) behind a
; straightforward display routine, only ever invoked interactively
; from the editor's own command loop — never from a running program,
; never in a hot loop — same low-risk profile the checker and storage
; moves had before their own migrations.
;
; WHAT MOVED HERE (cut verbatim from basic/basic.asm, not rewritten):
; BASIC_SHOW_HELP, HELP_TEXT_EDITOR, and the HTE_* line strings
; underneath it — roughly 155 lines that were pure overhead sitting in
; the Home budget for a feature that only runs when a human is
; actively at the keyboard typing HELP.
;
; SINGLE-TOPIC BY DESIGN (2026-08-23): a short-lived category-topic
; expansion (STRING/MATH topics, a topic-list screen) was built, then
; deliberately reverted the same day — HELP now always shows the one
; EDITOR screen below, regardless of what (if anything) follows the
; word HELP. See docs/programmers_reference.md's "HELP reverted to a
; single EDITOR screen" section for why.
;
; HOW THIS CALLS BACK INTO HOME: every call this file makes to a
; routine that still lives in Home (GFX_CLS, GFX_PRINT_STRING,
; BASIC_WAIT_FOR_KEY, BASIC_RESET_ROW_SHADOW) goes through the fixed
; jump table in include/exrom_jumptable.inc (KTAB_*), NOT a direct
; call to the real label — same reasoning as every other EXROM file in
; this project (see exrom_checker.asm's own header for the full
; explanation of why a direct call would silently break on the next
; basic.asm edit).
;
; ENTRY POINT: $C01E — EXROM_ENTRY_HELP, declared alongside this
; project's other five fixed entry stubs at the top of rom/exrom_
; checker.asm (see that file's own header for why every stub lives
; together there regardless of which file supplies the real body).
; This file supplies only BASIC_SHOW_HELP itself, the stub's forward
; reference target.
;
; HELP_ROW (include/sysvars.inc) is an ordinary RAM sysvar in chunk 4,
; which stays Home-mapped the whole time chunk 6 is paged to EXROM —
; no special handling needed to read/write it from here, same as every
; other EXROM file's sysvar access.
;
; Home-side caller: basic/basic.asm's BASIC_SHOW_HELP_EXROM wrapper
; (page in / call $C01E / page out — see that routine's own comment
; for why, unlike BASIC_CHECK_STATEMENT_EXROM/BASIC_SAVE_EXROM/
; BASIC_LOAD_EXROM, it needs no AF protection across the page-out
; step: BASIC_SHOW_HELP's own original contract already destroyed
; AF/BC/DE/HL with no meaningful output for a caller to lose).
; ============================================================================

; ============================================================================
; BASIC_SHOW_HELP
; Implements the HELP command. Always shows the one EDITOR help
; screen — whatever (if anything) follows the word HELP is accepted
; but ignored, since there's only this one screen to show. Full-screen
; takeover (same pattern as BASIC_REPORT_ERROR), wait for any key, then
; BASIC_RESET_ROW_SHADOW before returning to the normal editor redraw —
; without that reset this would hit the exact same stale-shadow bug
; RUN's own screen once did (see BASIC_RESET_ROW_SHADOW's own comment).
; In:  HL = pointer to topic-name text (accepted for call-site
;      compatibility with BASIC_SHOW_HELP_EXROM's own contract; not
;      read)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_SHOW_HELP:
    call KTAB_GFX_CLS                  ; destroys HL — load the real
                                       ; text pointer only after this
    ld   hl, HELP_TEXT_EDITOR

    xor  a
    ld   (HELP_ROW), a
.line_loop:
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    inc  hl
    ld   a, d
    or   e
    jr   z, .lines_done                     ; line-table's own 0
                                            ; sentinel — done

    push hl                                 ; save line-table walk
                                            ; position across the print
                                            ; call below
    ex   de, hl                             ; HL = this line's string
    ld   a, (HELP_ROW)
    ld   b, a
    ld   c, 0
    call KTAB_GFX_PRINT_STRING
    ld   a, (HELP_ROW)
    inc  a
    ld   (HELP_ROW), a
    pop  hl
    jr   .line_loop

.lines_done:
    call KTAB_BASIC_WAIT_FOR_KEY
    jp KTAB_BASIC_RESET_ROW_SHADOW

; ---- HELP topic text: a table of line-string pointers, one per
; screen row, ended by a 0 pointer. Every line kept under 32 columns
; (GFX_COLS) and using only glyphs the font actually has (no "<" or
; ">" — see kernel/graphics's punctuation table). ----
HELP_TEXT_EDITOR:
    DW HTE_L01, HTE_L02, HTE_L03, HTE_L04, HTE_L05, HTE_L06, HTE_L07
    DW 0

HTE_L01: DB "EDITOR HELP", 0
HTE_L02: DB "MOVE  CS+5 8 7 6", 0
HTE_L03: DB "DELETE CHAR  CS+0", 0
HTE_L04: DB "INSERT  CS+ENTER", 0
HTE_L05: DB "DELETE LINE  CS+1", 0
HTE_L06: DB "ERRORS NEXT SS+A PREV SS+S", 0
HTE_L07: DB "ANY KEY RETURNS", 0
