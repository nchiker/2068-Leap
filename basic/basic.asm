; ============================================================================
; basic/basic.asm — the BASIC interpreter (growing)
;
; Production BASIC implementation, assembled into rom/test_basic.asm and
; covered by the automated Fuse regression suite. Historical implementation
; notes remain near the routines they describe.
;
; Scope, deliberately bounded:
;   - BASIC_TOKENIZE_LINE: converts EDIT_LINE_BUF's raw null-terminated
;     text into kernel/memory's length-prefixed statement format. NO
;     KEYWORD COMPRESSION (classic Sinclair BASIC token-packs keywords
;     into single bytes; this stores plain text, matched by string
;     comparison at run time instead — simpler to get right first).
;   - BASIC_COMMAND_LOOP: owns tying kernel/editor, the tokenizer, and
;     kernel/memory's storage together. Deliberately NOT done inside
;     kernel/editor itself — that would invert the intended layering.
;     REAL navigation now: CUR_EDIT_POS/CUR_EDIT_INDEX track which
;     statement is being edited (an existing one, moved into via
;     UP/DOWN, or the sentinel meaning "the new line at the end"), via
;     kernel/editor's EDITOR_NAV_HOOK (same pattern as
;     EDITOR_REDRAW_HOOK — an optional callback so kernel/editor never
;     needs to know BASIC exists).
;   - BASIC_RUN / BASIC_EXEC_STATEMENT: walks the program via
;     MEM_LINE_FIRST/MEM_LINE_NEXT, recognizing PRINT, INPUT,
;     assignment, and END/STOP. Unrecognized statements are silently
;     skipped — no error reporting implemented yet.
;   - Keyword matching is CASE-INSENSITIVE, matching kernel/io's
;     lowercase-default typing. Recognized keywords auto-uppercase and
;     render bold once a line is COMMITTED (ENTER) — not while still
;     being typed, which always shows plain. This is also where future
;     syntax validation would naturally go.
;
; The current implemented language and remaining limitations are listed in
; docs/user_manual.md and docs/basic_language_reference.md.
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    INCLUDE "basic/editor_integration.asm"

; ---- display constants ----
ATTR_ERROR_RED  EQU $3A     ; PAPER 7 (white, matching the default
                            ; background), INK 2 (red) — standard
                            ; Spectrum-family attribute byte format
                            ; (bits 7/6 FLASH/BRIGHT, bits 5-3 PAPER,
                            ; bits 2-0 INK; color codes 0=black,
                            ; 1=blue, 2=red, ..., 7=white). Used for
                            ; red-highlighted error lines in
                            ; BASIC_REDRAW_PROGRAM.

; ============================================================================
; BASIC_TOKENIZE_LINE
; Converts EDIT_LINE_BUF's raw null-terminated text into TOKEN_BUF, in
; kernel/memory's length-prefixed statement format:
; [length:2][content][terminator:$0D]. No keyword compression (see file
; header). Hand-traced: EDIT_LINE_BUF="HI" (2 chars) -> TOKEN_BUF =
; [$03,$00,'H','I',$0D] (length value 3 = 2 content bytes + 1
; terminator byte, not counting the length field itself).
; In:  none (reads EDIT_LINE_BUF)
; Out: TOKEN_BUF filled; HL = TOKEN_BUF
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_TOKENIZE_LINE:
    ld   hl, EDIT_LINE_BUF
    ld   b, 0
.scan_len:
    ld   a, b
    cp   EDIT_LINE_BUF_LEN
    jr   z, .scan_done
    ld   a, (hl)
    or   a
    jr   z, .scan_done
    inc  hl
    inc  b
    jr   .scan_len
.scan_done:
    ; B = content length (chars typed, not counting EDIT_LINE_BUF's own
    ; null terminator, which isn't copied — $0D replaces it below)
    ld   a, b
    inc  a                        ; +1 for the $0D terminator byte
    ld   (TOKEN_BUF), a
    xor  a
    ld   (TOKEN_BUF + 1), a        ; length field high byte — always 0,
                                  ; since max content (126) + 1 fits in
                                  ; one byte

    ld   hl, EDIT_LINE_BUF
    ld   de, TOKEN_BUF + 2
    ld   a, b
    or   a
    jr   z, .skip_copy             ; empty line — guard B=0 DJNZ
                                  ; wraparound, same class of Z80 gotcha
                                  ; flagged elsewhere in this project
.copy_loop:
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    djnz .copy_loop
.skip_copy:
    ld   a, $0D
    ld   (de), a

    ld   hl, TOKEN_BUF
    ret

; ============================================================================
; BASIC_COMMAND_LOOP
; Ties kernel/editor, BASIC_TOKENIZE_LINE, and kernel/memory's storage
; together — deliberately NOT done inside kernel/editor itself, to keep
; the layering one-directional (basic/ calls down into kernel modules,
; never the reverse).
;
; A genuine loop, with RUN recognized as an IMMEDIATE command rather
; than something that gets stored: type RUN alone (optionally followed
; only by trailing spaces) and it executes the currently stored
; program instead of being tokenized and saved. "RUNAWAY" or similar
; can't be mistaken for RUN — after matching the "RUN" prefix, the
; rest of the line must be empty or spaces only, checked explicitly
; below.
;
; REAL navigation now: CUR_EDIT_POS/CUR_EDIT_INDEX track which
; statement is currently being edited — either an existing one (moved
; into via UP/DOWN, handled by BASIC_HANDLE_NAV, kernel/editor's
; EDITOR_NAV_HOOK target) or the sentinel ($FFFF) meaning "the new,
; not-yet-committed line at the end". This state PERSISTS across loop
; iterations — unlike EDIT_LINE_BUF, which EDITOR_INIT zeroes every
; iteration and must be explicitly re-populated afterward via
; BASIC_LOAD_EDIT_LINE, based on whatever CUR_EDIT_POS currently is.
;
; Committing (ENTER) branches on CUR_EDIT_POS: the sentinel appends at
; PROG_END (as before) and CUR_EDIT_INDEX grows by one, staying in
; "add another new line" mode; an existing position replaces that
; statement in place (MEM_LINE_STORE already handles a differently-
; sized replacement correctly — tested), then advances to the next
; line by literally calling BASIC_HANDLE_NAV with EDIR_DOWN, the same
; logic real navigation uses — mirrors typical line-editor behavior
; where ENTER moves to the next line, and avoids duplicating the
; move-and-load logic a third time.
;
; A blank ENTER (nothing typed) is a no-op — for the sentinel case,
; not appending an empty statement; for an existing line, not replacing
; it with nothing (effectively cancelling that edit rather than
; deleting the line, since there's no explicit delete-line command
; yet).
;
; Keyword normalization (auto-uppercase) happens ONCE here, at commit
; time, right before tokenizing — not on every redraw. This is also
; where future syntax validation would naturally go.
; In:  none
; Out: never returns (loops forever, REPL-style)
; Destroys: AF, BC, DE, HL
; ============================================================================

; ============================================================================
; BASIC_RESET_EDIT_STATE
; Resets the editor's cursor/scroll/error-count state to "fresh,
; nothing edited yet, view at top" — shared by NEW and LOAD below,
; which both need exactly this after replacing the stored program
; (cold boot needs almost the same thing but also has to count any
; preloaded statements into CUR_EDIT_INDEX, so it keeps its own
; slightly different version rather than using this).
; In:  none
; Out: none
; Destroys: AF, HL
; ============================================================================
    DEFINE EMIT_BASIC_EDITOR_RESET_STATE
    INCLUDE "basic/editor_integration.asm"
    UNDEFINE EMIT_BASIC_EDITOR_RESET_STATE

BASIC_COMMAND_LOOP:
    ; one-time setup: clear the whole screen ONCE, here, at cold boot.
    ; A real bug shipped without this: the screen-flicker fix replaced
    ; the OLD per-redraw GFX_CLS (which cleared the entire screen to
    ; the normal background on every single redraw, including the very
    ; first) with per-row clearing that only touches rows the render
    ; loop actually draws — but at cold boot, with an empty program,
    ; almost the entire screen is never drawn by anything at all (only
    ; the sentinel line's own row gets touched), so the rest stayed
    ; whatever undefined state the hardware happened to be in — found
    ; from a screenshot showing a black screen with just one gray bar
    ; at the top. The per-row/leftover-rows logic only ever handles
    ; "this row previously had content and doesn't anymore" — it was
    ; never designed to handle "this row has never been touched by
    ; anything at all," which is exactly cold boot's own starting
    ; condition. One GFX_CLS here, run exactly once, establishes that
    ; known-clean starting state before the first diff-based redraw
    ; ever runs.
    call GFX_CLS

    ; also establish a known border colour here — the ULA's border bits
    ; have no defined power-on state this project controls (unlike the
    ; screen bitmap/attributes, which GFX_CLS just set), and BORDER
    ; didn't exist as a statement until now, so without this line the
    ; border would sit at whatever the hardware/emulator happened to
    ; power on with instead of matching the rest of the fresh white
    ; screen GFX_CLS just drew
    ld   a, BORDER_DEFAULT
    call GFX_SET_BORDER

    call BASIC_RESET_TEXT_ATTR         ; establish default INK/PAPER/
                                       ; FLASH/INVERSE/OVER state — same
                                       ; "no defined power-on state"
                                       ; reasoning as BORDER_DEFAULT

    xor  a
    call GFX_SET_MODE                   ; establish default video mode
                                        ; (0 = Normal) — same "no
                                        ; defined power-on state"
                                        ; reasoning as BORDER_DEFAULT/
                                        ; BASIC_RESET_TEXT_ATTR just
                                        ; above; GFX_MODE has no
                                        ; equivalent defensive reset
                                        ; anywhere else, unlike every
                                        ; other piece of drawing state
                                        ; in this file — found while
                                        ; investigating an unexplained
                                        ; visual difference between a
                                        ; Normal-mode shape and an
                                        ; identical one in an earlier
                                        ; test predating MODE (this
                                        ; call didn't exist yet then
                                        ; either — genuinely never
                                        ; guaranteed before now)
                                       ; just above

    ; start in "new line" mode with nothing yet typed, index 0 (an
    ; empty program has zero existing statements, so index 0 IS the
    ; sentinel position), view scrolled to the top
    ld   hl, $FFFF
    ld   (CUR_EDIT_POS), hl

    ; CUR_EDIT_INDEX must equal the REAL number of existing statements
    ; here, not a hardcoded 0 — 0 was only ever correct for the true
    ; empty-program case (real cold boot, or after NEW). It silently
    ; broke anything that places a program in memory before reaching
    ; here without going through the normal per-statement MEM_LINE_
    ; STORE commit path that would have incremented CUR_EDIT_INDEX
    ; itself — e.g. tools/preload_gen.py's test harnesses, which bulk-
    ; copy a whole program into RAM in one shot. CUR_EDIT_INDEX being
    ; wrong there meant every scroll-boundary check downstream (which
    ; reads CUR_EDIT_INDEX directly, in BASIC_HANDLE_NAV and the
    ; auto-scroll check both) silently worked against a fictional
    ; statement count, masking real scroll-bug testing entirely —
    ; found via a debug.bin dump showing CUR_EDIT_INDEX=3 instead of
    ; the expected 23 after a 20-statement preload + 3 typed lines,
    ; even after preload_gen.py's own harness was separately fixed to
    ; set CUR_EDIT_INDEX before this call — a fix that turned out to
    ; be powerless, since this routine's own init (right here) runs
    ; AFTER that and unconditionally overwrote it back to 0.
    ld   bc, 0                          ; running count
    call MEM_LINE_FIRST
.count_existing:
    ld   a, h
    or   l
    jr   z, .count_existing_done         ; HL=0 -> no (more) statements
    inc  bc
    push bc                              ; MEM_LINE_NEXT destroys BC
                                        ; too (AF/BC/DE/HL all
                                        ; destroyed per its own
                                        ; contract) — the running
                                        ; count must survive on the
                                        ; real stack across this call,
                                        ; not sit in a register
    call MEM_LINE_NEXT
    pop  bc
    jr   .count_existing
.count_existing_done:
    ld   (CUR_EDIT_INDEX), bc

    ; VIEW_TOP_INDEX, CHECK_ERROR_COUNT, DELETE_INVALID_FLAG,
    ; STORAGE_CMD_INVALID_FLAG, and STORAGE_OP_STATE are already zero from
    ; MEM_COLD_INIT.  Keeping a second set of cold-only stores here used 16
    ; bytes and obscured which routine owns the power-on invariant.
    ld   hl, $FFFF
    ld   (PENDING_DELETE_POS), hl        ; same reasoning again —
                                        ; garbage here at cold boot
                                        ; could otherwise look like a
                                        ; real position and delete
                                        ; whatever program the user
                                        ; first types the moment they
                                        ; navigate
    ; CALC_SP is likewise zero from MEM_COLD_INIT before calculator code can
    ; run; NEW still resets it explicitly in its own independent path.

    call BASIC_RESET_ROW_SHADOW

.loop:
    ; Defensive border reset — a program run via RUN may have left
    ; BORDER at whatever it last set (BASIC_RUN never restores it, and
    ; unlike cold boot/NEW/LOAD, this per-iteration re-entry into the
    ; editor never called GFX_SET_BORDER either). Same defensive-state
    ; pattern already established for GFX_MODE — real hardware can't be
    ; trusted to "just still be white" once a program has touched it.
    ld   a, BORDER_DEFAULT
    call GFX_SET_BORDER

    call BASIC_EDITOR_INIT_EXROM     ; reset the line buffer and cursor
                                     ; for a fresh session — this ALSO
                                     ; zeroes EDIT_LINE_BUF, which is
                                     ; why BASIC_LOAD_EDIT_LINE below is
                                     ; needed every iteration now, not
                                     ; just after navigation
    ld   hl, BASIC_REDRAW_PROGRAM
    ld   (EDITOR_REDRAW_HOOK), hl
    ld   hl, BASIC_HANDLE_NAV
    ld   (EDITOR_NAV_HOOK), hl
    ld   hl, BASIC_DRAW_STATUS_LINE
    ld   (STORAGE_PROGRESS_HOOK), hl      ; lets kernel/storage draw a
                                         ; live percentage during a
                                         ; blocking SAVE/LOAD — reuses
                                         ; BASIC_DRAW_STATUS_LINE's own
                                         ; existing "no input, no
                                         ; output" contract and its own
                                         ; flicker-avoidance logic
                                         ; rather than a separate hook
                                         ; routine, see BASIC_FORMAT_
                                         ; STORAGE_STATUS's own header

    call BASIC_LOAD_EDIT_LINE          ; populate EDIT_LINE_BUF from
                                       ; CUR_EDIT_POS (empty if the
                                       ; sentinel, detokenized existing
                                       ; text otherwise) — EDITOR_INIT
                                       ; just wiped it, so this can't be
                                       ; skipped

    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    jr   nz, .use_existing_pos
    ld   hl, (PROG_END)                  ; sentinel -> EDITOR_ENTER's
                                        ; position is the append point
    jr   .have_editor_pos
.use_existing_pos:
    ld   hl, (CUR_EDIT_POS)
.have_editor_pos:
    call BASIC_EDITOR_ENTER_EXROM
    ; EDITOR_EXIT has returned — EDIT_LINE_BUF holds whatever was typed

    ld   a, (EDIT_LINE_BUF)
    or   a
    jr   z, .loop                      ; blank ENTER — no-op

    ; REAL BUG FOUND AND FIXED (user-reported, confirmed via memory
    ; dump): every immediate command below (RUN/NEW/HELP/LIST/EDIT/
    ; DELETE) used to be checked for UNCONDITIONALLY, regardless of
    ; whether CUR_EDIT_POS was the sentinel (composing a genuinely new
    ; line) or an EXISTING statement being edited. Navigating to an
    ; existing line and editing its text to read e.g. "DELETE 3,3"
    ; then meant pressing ENTER EXECUTED that as a command instead of
    ; committing the edit — the original stored text was never
    ; replaced at all (proven via a memory dump: PROG_END still marked
    ; the exact same statement count as before, and the original
    ; "DELETE 3,1" text was still sitting there byte-for-byte
    ; unchanged, while DELETE_START/DELETE_END showed the NEW "3,3"
    ; had genuinely been parsed and acted on). Editing an existing
    ; line must always just replace its text, full stop — never get
    ; reinterpreted as a command to run, no matter what it happens to
    ; read. Guarded with a single check here, ahead of every command
    ; below, rather than adding the same guard six separate times.
    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    jp   nz, .not_delete                  ; editing an existing
                                         ; statement — skip straight to
                                         ; the normal tokenize+commit
                                         ; path; JP not JR, since this
                                         ; needs to clear the entire
                                         ; RUN/NEW/HELP/LIST/EDIT/
                                         ; DELETE dispatch chain below,
                                         ; well beyond JR's own ±129
                                         ; byte reach

    ld   hl, EDIT_LINE_BUF
    ld   de, KW_RUN
    call BASIC_MATCH_KEYWORD
    jr   c, .not_run                  ; didn't even start with "RUN"

.check_trailing:
    ld   a, (hl)
    or   a
    jr   z, .is_run                     ; end of line — genuinely just "RUN"
    cp   " "
    jr   nz, .not_run                     ; something else follows (e.g.
                                          ; "RUNAWAY") — not RUN alone
    inc  hl
    jr   .check_trailing

.is_run:
    call BASIC_RUN

    ld   hl, (CHECK_ERROR_COUNT)
    ld   a, h
    or   l
    jr   nz, .skip_wait                ; check pass failed — nothing
                                       ; was actually shown (BASIC_RUN
                                       ; returned immediately), so
                                       ; there's nothing to pause and
                                       ; read; go straight back to the
                                       ; editor view, where the status
                                       ; bar will show the error count

    call BASIC_WAIT_FOR_KEY           ; pause here — without this, the
                                      ; very next loop iteration's
                                      ; EDITOR_INIT/EDITOR_ENTER clears
                                      ; the screen (via GFX_CLS) almost
                                      ; immediately, wiping whatever
                                      ; RUN just displayed before there
                                      ; was any real chance to read it.
.skip_wait:
    jr   .loop

.not_run:
    ld   hl, EDIT_LINE_BUF
    ld   de, KW_NEW
    call BASIC_MATCH_KEYWORD
    jr   c, .not_new                  ; didn't even start with "NEW"

.check_new_trailing:
    ld   a, (hl)
    or   a
    jr   z, .is_new                     ; end of line — genuinely just "NEW"
    cp   " "
    jr   nz, .not_new                     ; something else follows (e.g.
                                          ; "NEWLINE") — not NEW alone
    inc  hl
    jr   .check_new_trailing

.is_new:
    call MEM_INIT                       ; program area + label table ->
                                        ; empty (see kernel/memory) —
                                        ; also resets VARS_START to
                                        ; empty now (Phase 4), so the
                                        ; separate VAR_TABLE zero-fill
                                        ; this block used to do here is
                                        ; gone, not just moved

    call BASIC_RESET_EDIT_STATE
    xor  a
    ld   (CALC_SP), a                    ; same reasoning as cold boot's
                                        ; own reset above — division
                                        ; always leaves this balanced
                                        ; back at 0 in practice, but NEW
                                        ; is meant to match cold boot's
                                        ; fresh state exactly, not rely
                                        ; on that

    call GFX_CLS
    ld   a, BORDER_DEFAULT               ; a real bug, reported by
                                         ; [stated]: NEW cleared the
                                         ; program and screen but left
                                         ; whatever BORDER colour a
                                         ; prior program had set — NEW
                                         ; is meant to be a full reset
                                         ; to the same fresh state as
                                         ; cold boot, and cold boot's
                                         ; own setup now sets this same
                                         ; default explicitly, so NEW
                                         ; must match it rather than
                                         ; silently skip the one piece
                                         ; of screen state GFX_CLS
                                         ; itself doesn't touch
    call GFX_SET_BORDER
    call BASIC_RESET_TEXT_ATTR         ; same reasoning as BORDER just
                                       ; above — NEW must reset text
                                       ; attribute state too, not just
                                       ; border, or a prior program's
                                       ; INK/PAPER/FLASH/INVERSE/OVER
                                       ; would silently leak into the
                                       ; fresh session
    xor  a
    call GFX_SET_MODE                   ; NEW resets video mode too —
                                        ; same reasoning as BORDER/text
                                        ; attrs just above; also matters
                                        ; for a reason those two don't
                                        ; share: GFX_SET_MODE clears
                                        ; High Resolution Graphics
                                        ; mode's attribute memory the
                                        ; first time mode 1 is entered,
                                        ; and a fresh NEW should start
                                        ; from Normal mode regardless
                                        ; of what a prior program left
                                        ; active
    call BASIC_RESET_ROW_SHADOW
    jp   .loop

.not_new:
    ld   hl, EDIT_LINE_BUF
    ld   de, KW_HELP
    call BASIC_MATCH_KEYWORD
    jr   c, .not_help                  ; didn't even start with "HELP"

    ld   a, (hl)
    or   a
    jr   z, .is_help                    ; "HELP" alone -> HL already at
                                        ; the null terminator, an empty
                                        ; topic name (lists topics)
    cp   " "
    jr   nz, .not_help                    ; e.g. "HELPME" — not HELP
                                          ; alone, falls through to be
                                          ; tokenized as a normal
                                          ; statement, same as RUN above
    inc  hl                                ; skip the one separating
                                           ; space between HELP and its
                                           ; argument
.skip_help_spaces:
    ld   a, (hl)
    cp   " "
    jr   nz, .is_help                       ; HL now at the first non-
                                            ; space character of the
                                            ; topic name, or at the null
                                            ; terminator if it was all
                                            ; spaces after "HELP"
    inc  hl
    jr   .skip_help_spaces

.is_help:
    call BASIC_SHOW_HELP_EXROM               ; HL = topic name text,
                                             ; possibly empty — HELP
                                             ; now lives in EXROM, see
                                             ; that wrapper's own
                                             ; comment
    jp   .loop

.not_help:
    ld   hl, EDIT_LINE_BUF
    ld   de, KW_LIST
    call BASIC_MATCH_KEYWORD
    jr   c, .not_list                  ; didn't even start with "LIST"

.check_list_trailing:
    ld   a, (hl)
    or   a
    jr   z, .is_list                    ; end of line — genuinely just "LIST"
    cp   " "
    jr   nz, .not_list                    ; e.g. "LISTING" — not LIST alone
    inc  hl
    jr   .check_list_trailing

.is_list:
    ld   de, 0                          ; index 0 — the top of the program
    call BASIC_GOTO_EDIT_INDEX
    jp   .loop

.not_list:
    ld   hl, EDIT_LINE_BUF
    ld   de, KW_EDIT
    call BASIC_MATCH_KEYWORD
    jr   c, .not_edit                  ; didn't even start with "EDIT"

    ld   a, (hl)
    cp   " "
    jr   nz, .not_edit                    ; "EDIT" with no argument (or
                                          ; something else entirely, e.g.
                                          ; "EDITOR") falls through to be
                                          ; tokenized as ordinary program
                                          ; text, same as any other
                                          ; malformed immediate command
.skip_edit_spaces:
    inc  hl
    ld   a, (hl)
    cp   " "
    jr   z, .skip_edit_spaces

    call BASIC_DO_EDIT                    ; HL = label name text
    jr   c, .not_edit                    ; malformed/not found — same
                                         ; fallthrough as above
    jp   .loop

.not_edit:
    ld   hl, EDIT_LINE_BUF
    ld   de, KW_DELETE
    call BASIC_MATCH_KEYWORD
    jr   c, .check_save                ; didn't even start with "DELETE"

    ld   a, (hl)
    cp   " "
    jr   nz, .check_save                  ; "DELETE" alone, or something
                                          ; else (e.g. "DELETED") — falls
                                          ; through, same as above
.skip_delete_spaces:
    inc  hl
    ld   a, (hl)
    cp   " "
    jr   z, .skip_delete_spaces

    call BASIC_DO_DELETE                  ; HL = text right after "DELETE "
    jr   c, .delete_invalid               ; malformed/out-of-range —
                                         ; show INVALID RANGE, then
                                         ; same fallthrough as above
    jp   .loop

.delete_invalid:
    ld   a, 1
    ld   (DELETE_INVALID_FLAG), a          ; BASIC_DRAW_STATUS_LINE
                                          ; reads and clears this on
                                          ; its very next run — see its
                                          ; own header and
                                          ; DELETE_INVALID_FLAG's own
                                          ; sysvars.inc comment. Only
                                          ; set here (once BASIC_DO_
                                          ; DELETE was actually called
                                          ; and genuinely rejected the
                                          ; range) — NOT for the
                                          ; earlier boundary checks
                                          ; above (bare "DELETE", or
                                          ; something like "DELETED"
                                          ; that merely starts with the
                                          ; same letters), which aren't
                                          ; real attempts at this
                                          ; command at all
    jr   .check_save

.check_save:
    ld   hl, EDIT_LINE_BUF
    ld   de, KW_SAVE
    call BASIC_MATCH_KEYWORD
    jr   c, .not_save                  ; didn't even start with "SAVE"

    ld   a, (hl)
    cp   " "
    jr   nz, .not_save                    ; "SAVE" alone, or something
                                          ; else (e.g. a future keyword
                                          ; that starts with the same
                                          ; letters) — falls through,
                                          ; same as DELETE/EDIT above
.skip_save_spaces:
    inc  hl
    ld   a, (hl)
    cp   " "
    jr   z, .skip_save_spaces

    call BASIC_DO_SAVE                    ; HL = text right after "SAVE "
    jr   c, .storage_cmd_invalid          ; malformed — show INVALID
                                         ; FILENAME, same fallthrough
                                         ; shape as DELETE above
    jp   .loop

.not_save:
    ld   hl, EDIT_LINE_BUF
    ld   de, KW_LOAD
    call BASIC_MATCH_KEYWORD
    jr   c, .not_load                  ; didn't even start with "LOAD"

    ld   a, (hl)
    cp   " "
    jr   nz, .not_load                    ; "LOAD" alone, or something
                                          ; else — falls through
.skip_load_spaces:
    inc  hl
    ld   a, (hl)
    cp   " "
    jr   z, .skip_load_spaces

    call BASIC_DO_LOAD                    ; HL = text right after "LOAD "
    jr   c, .storage_cmd_invalid          ; malformed — same as SAVE
    jp   .loop

.storage_cmd_invalid:
    ld   a, 1
    ld   (STORAGE_CMD_INVALID_FLAG), a     ; same one-shot shape as
                                          ; DELETE_INVALID_FLAG, but a
                                          ; separate sysvar — see that
                                          ; sysvar's own comment for
                                          ; why this wasn't unified
                                          ; with DELETE's flag
    jr   .not_load

.not_load:
.not_delete:
    call BASIC_UPPERCASE_KEYWORD_PREFIX  ; commit-time normalization
    call BASIC_TOKENIZE_LINE        ; HL = TOKEN_BUF
    ex   de, hl                      ; DE = TOKEN_BUF, for MEM_LINE_STORE's
                                    ; "new text" argument

    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    jr   nz, .commit_existing

    ; appending a new statement
    ld   hl, (PROG_END)
    ld   a, (DELETE_INVALID_FLAG)
    or   a
    jr   z, .not_pending_delete
    ld   (PENDING_DELETE_POS), hl          ; remember where this
                                          ; rejected command's text is
                                          ; about to be stored, so
                                          ; BASIC_HANDLE_NAV can remove
                                          ; it once the user navigates
                                          ; away — see PENDING_DELETE_
                                          ; POS's own sysvars.inc
                                          ; comment for the full
                                          ; reasoning. DELETE_INVALID_
                                          ; FLAG is still 1 here (it's
                                          ; only read-and-cleared by
                                          ; BASIC_DRAW_STATUS_LINE,
                                          ; which hasn't run yet at
                                          ; this point in the same
                                          ; command's own dispatch)
.not_pending_delete:
    call MEM_LINE_STORE

    ; REAL BUG FOUND AND FIXED ([stated]-reported): this used to just
    ; zero CHECK_ERROR_COUNT here instead of re-running the check —
    ; deliberately, per the removed comment, to avoid the status bar
    ; showing a "stale" error count after an edit. But CHECK_ERROR_
    ; LIST holds statement POSITIONS (memory addresses) from whenever
    ; BASIC_CHECK_PROGRAM last ran (only ever called from RUN) — and
    ; every commit can shift every statement's position after it,
    ; since this format stores text inline with no padding (a longer
    ; or shorter replacement shifts everything downstream). So editing
    ; and correcting ONE error line didn't just clear that line's own
    ; flag — with CHECK_ERROR_COUNT zeroed, BASIC_IS_ERROR_STATEMENT's
    ; own early-out (count==0 -> "not found" immediately, no address
    ; comparison at all) meant EVERY error indicator on screen went
    ; dark at once, correct or not, until the next RUN recomputed
    ; everything from scratch. [stated] reproduced this exactly:
    ; correcting the first error line, pressing ENTER, and watching
    ; every remaining (still genuinely broken) error line lose its red
    ; coloring too. Fixed by re-running the real check here instead —
    ; same BASIC_SCAN_LABELS-then-BASIC_CHECK_PROGRAM sequence
    ; BASIC_RUN already uses (GOTO validation needs the label table
    ; populated first, per that call site's own comment) — so error
    ; state stays live and accurate after every commit, not just reset
    ; to "unknown" until the next RUN. BASIC_SCAN_LABELS/BASIC_CHECK_
    ; PROGRAM now live in EXROM (ROM-size fix — see working memory);
    ; BASIC_FULL_CHECK_EXROM pages them in, runs both in the same
    ; order this comment describes, pages back out.
    call BASIC_FULL_CHECK_EXROM

    ld   hl, (CUR_EDIT_INDEX)
    inc  hl                              ; stay in "new line" mode, one
    ld   (CUR_EDIT_INDEX), hl              ; further along than before
    jp   .loop

.commit_existing:
    ld   hl, (CUR_EDIT_POS)
    call MEM_LINE_STORE

    call BASIC_FULL_CHECK_EXROM              ; see .not_pending_delete's
                                            ; own comment above — same
                                            ; live re-check, same reason
                                            ; (now via EXROM — see that
                                            ; comment)

    ld   hl, (CHECK_ERROR_COUNT)
    ld   a, h
    or   l
    jr   nz, .step_down_one              ; program still has at least
                                         ; one error somewhere — keep
                                         ; the existing "advance one
                                         ; line" workflow, useful for
                                         ; walking through several
                                         ; broken lines in sequence

    ; REAL BUG FOUND AND FIXED ([stated]-reported, 2026-08-19): the
    ; program is now completely clean, but the old code below
    ; unconditionally stepped down exactly ONE line regardless —
    ; landing on the NEXT existing statement whenever the just-fixed
    ; line wasn't the very last one, not the sentinel. RUN is only
    ; ever recognized as a command when CUR_EDIT_POS IS the sentinel
    ; (BASIC_COMMAND_LOOP's own guard above — itself a real historical
    ; fix for the OPPOSITE problem: an edited line's text being
    ; misread as a command). So typing RUN there silently committed
    ; the literal word "RUN" as THAT line's new text instead of
    ; running anything — RUN is never a recognized program-statement
    ; keyword (only the immediate-command dispatch above matches it,
    ; and KEYWORD_HILITE_TABLE bolds it as you type, which is
    ; misleading — it's still not a valid statement), so this
    ; immediately introduced a NEW syntax error, requiring yet another
    ; correct-and-retry cycle. [stated] reported needing several RUN
    ; presses after fixing an error before it actually ran; traced to
    ; this exact mechanism (BASIC_HANDLE_NAV's single-step EDIR_DOWN
    ; plus BASIC_COMMAND_LOOP's sentinel-only RUN guard).
    ; Fix: once the whole program is genuinely clean, keep stepping
    ; down — reusing BASIC_HANDLE_NAV, already proven to keep
    ; CUR_EDIT_INDEX/CUR_EDIT_POS/the edit buffer/scroll position all
    ; correctly in sync one step at a time (see its own EDIR_DOWN
    ; comments) — until the sentinel is actually reached, instead of
    ; stopping after exactly one step. Bounded and safe to loop on:
    ; BASIC_HANDLE_NAV's own EDIR_DOWN is a documented no-op once
    ; already at the sentinel, so this can never run away.
.advance_to_sentinel:
    ld   a, EDIR_DOWN
    call BASIC_HANDLE_NAV
    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    jr   nz, .advance_to_sentinel
    jp   .loop

.step_down_one:
    ld   a, EDIR_DOWN                      ; advance to the next line —
    call BASIC_HANDLE_NAV                    ; reuses the same move
                                            ; logic real navigation uses
    jp   .loop

; ============================================================================
; BASIC_WAIT_FOR_KEY
; Blocks until a key is pressed and released — consumes the whole
; press+release cycle (not via IO_READ_KEY, which would try to
; translate it into a character) so nothing leaks into the next
; EDITOR_ENTER session as an unwanted inserted character.
;
; REAL BUG FOUND AND FIXED (user-reported: a program consisting of just
; one PRINT statement appeared not to run at all — RUN seemed to
; silently return straight to the program listing, but the exact same
; PRINT inside a FOR/NEXT loop worked fine). Root cause: this routine
; used to go straight to .wait_press below with no flush step first.
; The ENTER keystroke that committed "RUN" is still physically held
; down at the exact instant BASIC_RUN returns for a single, near-
; instant statement — far faster than a human can release a key — so
; the OLD .wait_press was satisfied immediately by that SAME keystroke
; still being down, and .wait_release then returned the moment the
; user's finger naturally came off it a few tens of milliseconds later,
; long before there was any real chance to read the output. A FOR/NEXT
; loop takes long enough to execute that ENTER was already released by
; the time BASIC_RUN returned, so the old code happened to work
; correctly in that case — masking the bug rather than avoiding it.
; .flush below waits for NO key to be down first, so a key already
; held from whatever committed this call can never satisfy .wait_press
; by itself; only a genuinely new press-after-this-routine-started can.
; In:  none
; Out: none
; Destroys: AF
; ============================================================================
BASIC_WAIT_FOR_KEY:
.flush:
    call IO_ANY_KEY_DOWN
    jr   c, .flush
.wait_press:
    call IO_ANY_KEY_DOWN
    jr   nc, .wait_press
.wait_release:
    call IO_ANY_KEY_DOWN
    jr   c, .wait_release
    ret

; ============================================================================
; BASIC_IS_SENTINEL
; In:  HL = value to check
; Out: Z flag set if HL == $FFFF (the "new, uncommitted line" sentinel
;      used by CUR_EDIT_POS); Z clear otherwise. Callers use "jr z" for
;      "it's the sentinel" and "jr nz" for "it's a real position" —
;      kept consistent everywhere this is used.
; Destroys: AF
; ============================================================================
BASIC_IS_SENTINEL:
    ld   a, h
    cp   $FF
    ret  nz
    ld   a, l
    cp   $FF
    ret

; ============================================================================
; BASIC_COUNT_STATEMENTS
; Counts how many statements currently exist, by walking the whole
; program. The counter lives in memory (COUNT_TMP), not register DE —
; an earlier draft used DE directly and was wrong: MEM_LINE_FIRST sets
; DE = PROG_AREA_START internally and never restores it, and
; MEM_LINE_NEXT destroys DE too (see both routines' own "Destroys"
; lines) — so DE cannot hold a running count across either call. Found
; via a diagnostic showing correct underlying storage state while
; BASIC_REDRAW_PROGRAM (which has the same class of bug) rendered
; nothing at all.
; In:  none
; Out: DE = count (0 if empty)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_COUNT_STATEMENTS:
    ld   hl, 0
    ld   (COUNT_TMP), hl
    call MEM_LINE_FIRST
.loop:
    ld   a, h
    or   l
    jr   z, .done
    push hl                        ; save the statement pointer — the
                                   ; very bug this fixes: an earlier
                                   ; draft loaded HL from COUNT_TMP here
                                   ; WITHOUT saving the statement
                                   ; pointer first, so MEM_LINE_NEXT
                                   ; below received the counter value
                                   ; (e.g. 1) instead of a real address,
                                   ; reading garbage memory as if it
                                   ; were statement data — a real bug,
                                   ; found by re-reading this exact code
                                   ; against MEM_LINE_NEXT's documented
                                   ; input contract after a reported
                                   ; lockup during navigation
    ld   hl, (COUNT_TMP)
    inc  hl
    ld   (COUNT_TMP), hl
    pop  hl                          ; restore the statement pointer
    call MEM_LINE_NEXT
    jr   .loop
.done:
    ld   de, (COUNT_TMP)
    ret

; ============================================================================
; BASIC_FIND_STATEMENT_AT_INDEX
; Walks to the DE-th (0-based) statement. The target index is
; immediately stashed in memory (FIND_REMAINING) before calling
; MEM_LINE_FIRST, since that call would otherwise clobber the caller's
; DE before it's ever used (same root cause as BASIC_COUNT_STATEMENTS'
; fix above). The walk loop carefully preserves the statement pointer
; (HL, MEM_LINE_NEXT's actual result) across the counter decrement,
; since decrementing needs HL as scratch too — pushed and popped around
; that specific section, not left to chance.
; In:  DE = target index
; Out: carry clear + HL = that statement's position; carry set if the
;      index is out of range (>= total statement count)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_FIND_STATEMENT_AT_INDEX:
    ld   (FIND_REMAINING), de
    call MEM_LINE_FIRST
    ld   de, (FIND_REMAINING)
    ld   a, d
    or   e
    jr   z, .check_result             ; index 0 — MEM_LINE_FIRST's
                                      ; result is already the answer
.walk_loop:
    ld   a, h
    or   l
    jr   z, .out_of_range               ; ran out before reaching the index
    call MEM_LINE_NEXT
    push hl                               ; save the statement pointer —
                                         ; MEM_LINE_NEXT's actual result
                                         ; — before using HL as scratch
                                         ; for the counter below
    ld   hl, (FIND_REMAINING)
    dec  hl
    ld   (FIND_REMAINING), hl
    ld   a, h
    or   l
    pop  hl                                 ; restore the statement pointer
    jr   nz, .walk_loop
.check_result:
    ld   a, h
    or   l
    jr   z, .out_of_range
    or   a
    ret
.out_of_range:
    scf
    ret

; ============================================================================
; BASIC_STMT_ROW_COUNT
; How many physical (wrapped) screen rows does one stored statement
; occupy? Copies its text into DETOK_BUF exactly the way BASIC_REDRAW_
; PROGRAM's own .render_settled does (this tokenizer stores plain text,
; not compressed keyword tokens — see that block's own comment — so
; "detokenizing" is just a copy up to the CR terminator), then wraps
; it the same way. Deliberately mirrors that exact sequence rather
; than reading the stored length prefix directly, so this always
; agrees with whatever the redraw loop itself would compute — the one
; place that actually matters.
; In:  HL = statement position (pointing at its 2-byte length prefix)
; Out: A = row count (>= 1)
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_STMT_ROW_COUNT:
    push hl
    inc  hl
    inc  hl                                  ; skip the 2-byte length
                                            ; prefix
    ld   de, DETOK_BUF
.src_loop:
    ld   a, (hl)
    cp   $0D
    jr   z, .src_done
    ld   (de), a
    inc  hl
    inc  de
    jr   .src_loop
.src_done:
    xor  a
    ld   (de), a
    pop  hl                                  ; restored, though unused
                                            ; by the caller here —
                                            ; kept symmetrical with
                                            ; every other push/pop hl
                                            ; around this exact copy
                                            ; loop elsewhere in this
                                            ; file, for consistency

    ld   hl, DETOK_BUF
    call BASIC_EDITOR_WRAP_CALC_EXROM
    ld   a, (EDIT_WRAP_COUNT)
    ret

; ============================================================================
; BASIC_ROWS_BEFORE_INDEX
; Sums the wrapped row-counts of every statement from VIEW_TOP_INDEX up
; to (but not including) CUR_EDIT_INDEX — i.e. how many screen rows the
; statements ABOVE the target would occupy if the view started at
; VIEW_TOP_INDEX, which is exactly the target's own starting row in
; that view. Read directly from those two sysvars rather than taking
; parameters, matching BASIC_COUNT_STATEMENTS/BASIC_FIND_STATEMENT_AT_
; INDEX's own style of reading state directly.
;
; Bounded the same way BASIC_FIND_STATEMENT_AT_INDEX is: walks forward
; from VIEW_TOP_INDEX one statement at a time, calling BASIC_STMT_ROW_
; COUNT on each — no backward walk needed (kernel/memory has no
; MEM_LINE_PREV), and every caller of this only ever passes a
; VIEW_TOP_INDEX <= CUR_EDIT_INDEX, so this always terminates.
; In:  none (reads VIEW_TOP_INDEX, CUR_EDIT_INDEX)
; Out: DE = total row count of statements [VIEW_TOP_INDEX, CUR_EDIT_INDEX)
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_ROWS_BEFORE_INDEX:
    ld   hl, (VIEW_TOP_INDEX)
    ld   (ROWS_BEFORE_IDX), hl

    xor  a
    ld   (ROWS_BEFORE_TOTAL), a
    ld   (ROWS_BEFORE_TOTAL+1), a
    ld   (ROW_COUNT_CACHE_LEN), a         ; reset the row-count cache
                                          ; too — see its own sysvars.
                                          ; inc header (2026-08-24)

    ld   de, (VIEW_TOP_INDEX)
    call BASIC_FIND_STATEMENT_AT_INDEX        ; HL = statement position
                                              ; (VIEW_TOP_INDEX is
                                              ; always a valid index
                                              ; when this is called —
                                              ; carry ignored, same as
                                              ; every other caller of
                                              ; this that already knows
                                              ; the index is in range)
    ld   (ROWS_BEFORE_PTR), hl

.rbi_loop:
    ld   hl, (ROWS_BEFORE_IDX)
    ld   de, (CUR_EDIT_INDEX)
    or   a
    sbc  hl, de
    jr   z, .rbi_done                          ; reached the target
                                               ; index — stop

    ld   hl, (ROWS_BEFORE_PTR)
    call BASIC_STMT_ROW_COUNT                    ; A = this statement's
                                                ; own row count

    ; cache it (bounded at 23 entries — a single statement occupies at
    ; least 1 row, WRAP_MAX_ROWS is 8, so no more than 23 could ever
    ; fit the 23-row window regardless; see ROW_COUNT_CACHE's own
    ; sysvars.inc header for the full "why cache this at all" reasoning)
    ; so BASIC_REDRAW_PROGRAM's render loop can reuse it instead of
    ; paying for another BASIC_EDITOR_WRAP_CALC_EXROM round trip
    push af
    ld   a, (ROW_COUNT_CACHE_LEN)
    cp   23
    jr   nc, .rbi_cache_full
    ld   hl, ROW_COUNT_CACHE
    ld   e, a
    ld   d, 0
    add  hl, de
    inc  a
    ld   (ROW_COUNT_CACHE_LEN), a
    pop  af
    ld   (hl), a
    jr   .rbi_cached
.rbi_cache_full:
    pop  af
.rbi_cached:

    ld   h, 0
    ld   l, a
    ld   de, (ROWS_BEFORE_TOTAL)
    add  hl, de
    ld   (ROWS_BEFORE_TOTAL), hl

    ld   hl, (ROWS_BEFORE_PTR)
    call MEM_LINE_NEXT
    ld   (ROWS_BEFORE_PTR), hl

    ld   hl, (ROWS_BEFORE_IDX)
    inc  hl
    ld   (ROWS_BEFORE_IDX), hl
    jr   .rbi_loop

.rbi_done:
    ld   de, (ROWS_BEFORE_TOTAL)
    ret

; ============================================================================
; BASIC_SCROLL_TO_FIT
; Adjusts VIEW_TOP_INDEX so the target line (CUR_EDIT_INDEX) is fully
; visible within the 23-row window — word-wrap-aware, replacing the
; old "VIEW_TOP_INDEX+22" statement-counting formula that assumed one
; statement always meant one row.
;
; Centralized here rather than duplicated at each of its 3 call sites
; (BASIC_HANDLE_NAV's own nav tail, the multi-line DELETE handler, and
; BASIC_REDRAW_PROGRAM's own top-of-redraw auto-scroll check) —
; deliberately breaking from this project's usual small-duplication-
; over-refactor-risk convention (see GFX_SET_ATTR's own comment for
; that convention's normal reasoning). That convention fit a few lines
; of trivial arithmetic; this is now a real multi-call computation
; (EDITOR_WRAP_CALC plus BASIC_ROWS_BEFORE_INDEX's own per-statement
; walk), and after the FOUR-round debugging arc the original simpler
; version of this exact scroll math already went through once, tripling
; something this delicate seemed like asking for a repeat rather than
; avoiding risk.
;
; Scrolling UP (target above the current window) doesn't need row-
; awareness: setting VIEW_TOP_INDEX = CUR_EDIT_INDEX always makes the
; target the very first visible statement, and a single statement can
; occupy at most WRAP_MAX_ROWS (8) rows — always comfortably under the
; 23-row window on its own, so there's nothing to check.
;
; Scrolling DOWN (target at or below the window) does need it: advances
; VIEW_TOP_INDEX one statement at a time until everything fits within
; 23 rows. Terminates: once VIEW_TOP_INDEX reaches CUR_EDIT_INDEX,
; rows-before is 0 and the target's own row count alone is always <=
; 23.
;
; PERFORMANCE FIX (2026-08-24): the "does it fit yet" check used to
; call BASIC_ROWS_BEFORE_INDEX — a full walk from VIEW_TOP_INDEX to
; CUR_EDIT_INDEX, re-summing every statement's row count via BASIC_
; STMT_ROW_COUNT (an EXROM round trip each) — FRESH on every single
; loop iteration, even though only one statement (whichever now sits
; at the old VIEW_TOP_INDEX) actually left the window each time. Found
; while investigating a user report that the editor felt slow scrolling
; through a long program; this loop's own recomputation turned out to
; be the dominant cost — and since BASIC_REDRAW_PROGRAM calls this
; unconditionally on EVERY keystroke (not just navigation, so plain
; typing pays it too, see that routine's own header), it wasn't only a
; scrolling cost. Now computes the rows-before total via BASIC_ROWS_
; BEFORE_INDEX exactly ONCE, then on each iteration subtracts the
; leaving statement's own row count (SCROLL_TOP_PTR, walked forward one
; MEM_LINE_NEXT per iteration) from a running total (SCROLL_ROWS_
; BEFORE) instead — turning an O(iterations x window) walk into
; O(window + iterations). Purely an internal rewrite: the external
; contract (reads/writes VIEW_TOP_INDEX, reads CUR_EDIT_INDEX/EDIT_
; LINE_BUF, no output) is unchanged, so none of the 3 call sites needed
; touching.
; In:  none (reads/writes VIEW_TOP_INDEX, reads CUR_EDIT_INDEX and
;      EDIT_LINE_BUF)
; Out: none
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_SCROLL_TO_FIT:
    ld   hl, (CUR_EDIT_INDEX)
    ld   de, (VIEW_TOP_INDEX)
    or   a
    sbc  hl, de
    jr   nc, .scroll_down_check              ; target >= VIEW_TOP_INDEX
    ld   hl, (CUR_EDIT_INDEX)
    ld   (VIEW_TOP_INDEX), hl
    ret

.scroll_down_check:
    ld   hl, EDIT_LINE_BUF
    call BASIC_EDITOR_WRAP_CALC_EXROM
    ld   a, (EDIT_WRAP_COUNT)
    ld   (SCROLL_OWN_ROWS), a

    call BASIC_ROWS_BEFORE_INDEX               ; DE = rows before target
                                                ; — the one real full
                                                ; walk; every "does it
                                                ; still fit" check below
                                                ; updates this
                                                ; incrementally instead
                                                ; of repeating it
    ld   (SCROLL_ROWS_BEFORE), de

    ld   de, (VIEW_TOP_INDEX)
    call BASIC_FIND_STATEMENT_AT_INDEX          ; HL = VIEW_TOP_INDEX's
                                                ; own statement position
                                                ; — always a valid index
                                                ; here, carry ignored,
                                                ; same reasoning BASIC_
                                                ; ROWS_BEFORE_INDEX's own
                                                ; identical call already
                                                ; relies on
    ld   (SCROLL_TOP_PTR), hl

.fit_check:
    ld   a, (SCROLL_OWN_ROWS)
    ld   l, a
    ld   h, 0
    ld   de, (SCROLL_ROWS_BEFORE)
    add  hl, de                                 ; HL = total rows needed
                                                ; to show the target in
                                                ; full

    ld   de, 24
    or   a
    sbc  hl, de
    ret  c                                       ; total <= 23: fits,
                                                 ; nothing to do

    ; doesn't fit yet — advance VIEW_TOP_INDEX past whatever statement
    ; currently sits at its top, subtracting THAT statement's own row
    ; count from the running total (one BASIC_STMT_ROW_COUNT call)
    ; instead of re-summing the whole window again
    ld   hl, (SCROLL_TOP_PTR)
    call BASIC_STMT_ROW_COUNT                    ; A = the leaving
                                                ; statement's own row
                                                ; count
    ld   e, a
    ld   d, 0
    ld   hl, (SCROLL_ROWS_BEFORE)
    or   a
    sbc  hl, de
    ld   (SCROLL_ROWS_BEFORE), hl

    ld   hl, (SCROLL_TOP_PTR)
    call MEM_LINE_NEXT
    ld   (SCROLL_TOP_PTR), hl

    ld   hl, (VIEW_TOP_INDEX)
    inc  hl
    ld   (VIEW_TOP_INDEX), hl
    jr   .fit_check

; ============================================================================
; BASIC_GOTO_EDIT_INDEX
; Moves the edit cursor to a specific 0-based statement index, loading
; that statement into EDIT_LINE_BUF and scrolling the view so it's the
; first line shown (row 0) — built for LIST/EDIT, which both need to
; jump straight to a specific place in the program rather than moving
; one line at a time the way UP/DOWN (BASIC_HANDLE_NAV) do.
; Deliberately simpler than BASIC_HANDLE_NAV's own scroll logic (which
; does the minimum scroll needed to keep the target visible, for a
; smooth one-line-at-a-time feel): here, the target ALWAYS becomes the
; top of the screen — a reasonable, predictable choice for a "jump to
; X and show it to me" command. NOT reused by BASIC_DO_DELETE below,
; which wants the opposite (minimal scroll, so deleting a few lines
; doesn't yank the view away from wherever the user was looking) — see
; that routine's own header for why it duplicates the small scroll
; formula instead of calling this.
;
; The target index is clamped to the current total statement count if
; it's too large (landing on the sentinel) rather than reporting an
; error — callers that need a stricter "does this index/label actually
; exist" check (like BASIC_DO_DELETE) do that validation themselves
; before ever reaching a routine like this one.
; In:  DE = desired target index (any value; out-of-range clamps to
;      the sentinel)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_GOTO_EDIT_INDEX:
    push de
    call BASIC_COUNT_STATEMENTS       ; DE = total
    ld   (NAV_TOTAL), de              ; stash — reusing BASIC_HANDLE_NAV's
                                      ; own scratch sysvar; never
                                      ; concurrent with that routine
                                      ; (this is only ever called from
                                      ; the top-level command dispatch,
                                      ; never from inside navigation
                                      ; itself), so safe to share
                                      ; rather than allocate a new one
    pop  de                          ; DE = desired target again

    ld   hl, (NAV_TOTAL)
    or   a
    sbc  hl, de                       ; carry set if total < desired
                                      ; (desired out of range)
    jr   nc, .in_range
    ld   de, (NAV_TOTAL)               ; clamp: land on the sentinel
.in_range:
    ld   (CUR_EDIT_INDEX), de

    ld   hl, (NAV_TOTAL)
    or   a
    sbc  hl, de
    jr   nz, .existing_line

    ld   hl, $FFFF
    ld   (CUR_EDIT_POS), hl
    jr   .loaded

.existing_line:
    ld   hl, (CUR_EDIT_INDEX)
    ex   de, hl
    call BASIC_FIND_STATEMENT_AT_INDEX
    ld   (CUR_EDIT_POS), hl

.loaded:
    call BASIC_LOAD_EDIT_LINE

    ld   hl, (CUR_EDIT_INDEX)
    ld   (VIEW_TOP_INDEX), hl
    ret

; ============================================================================
; BASIC_DO_EDIT
; Parses a label name and jumps the edit cursor straight to that
; statement — the immediate-command counterpart to GOTO, reusing the
; exact same identifier-parsing/lookup pieces (BASIC_PARSE_IDENTIFIER,
; MEM_LABEL_LOOKUP) rather than inventing new ones.
;
; Rebuilds the label table first (BASIC_SCAN_LABELS) — unlike GOTO,
; which only ever runs during RUN (which already rebuilds the table
; itself right before executing), EDIT can be typed at any time,
; including before the program has ever been RUN even once, when the
; table may be stale or empty. BASIC_SCAN_LABELS is side-effect-free
; on the program text itself (label-table only), so calling it here
; has no cost beyond the walk itself.
;
; REAL BUG FOUND AND FIXED: BASIC_PARSE_IDENTIFIER always writes its
; result into DETOK_BUF — a single, shared scratch buffer reused
; throughout basic/, not something private to this call. The label
; name is copied out into EDIT_LABEL_COPY (its own dedicated buffer)
; immediately after parsing, BEFORE calling BASIC_SCAN_LABELS —
; because BASIC_SCAN_LABELS walks the whole program and calls
; BASIC_PARSE_IDENTIFIER again internally, once per statement, which
; overwrites DETOK_BUF with whatever the LAST statement in the program
; happens to contain. The original version here only protected the
; POINTER to DETOK_BUF across that call (push hl / push bc — pop bc /
; pop hl), which does nothing to protect the BUFFER'S CONTENTS from
; being overwritten by a nested call that reuses the exact same
; memory. Every EDIT <label> silently looked up garbage instead of the
; real name, always failed to find it, and fell through to being
; stored as plain (invalid) program text — found from the user
; reporting EDIT/DELETE both "doing nothing," confirmed by re-tracing
; this call chain specifically for a resource DELETE never touches.
;
; MEM_LABEL_LOOKUP returns a POSITION, not an index — converted via
; BASIC_FIND_INDEX_OF_POSITION (already built for the error-navigation
; feature) before handing off to BASIC_GOTO_EDIT_INDEX, which only
; understands indices. Three already-existing pieces stitched
; together; no new lookup/navigation mechanism needed.
; In:  HL = pointer to the label name text (already skipped "EDIT "
;      and any further leading spaces)
; Out: carry clear on success (cursor moved); carry set if the label
;      name doesn't parse or isn't found — caller falls through to
;      treating the whole typed line as ordinary program text, same
;      as a malformed RUN/NEW/HELP already does
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_DO_EDIT:
    call BASIC_PARSE_IDENTIFIER          ; HL = DETOK_BUF (shared!),
                                        ; B = length
    ld   a, b
    or   a
    jr   z, .fail                        ; no identifier at all — e.g.
                                        ; "EDIT" followed only by spaces

    ; copy out of the shared buffer into our own, BEFORE touching
    ; anything that might reuse DETOK_BUF for its own purposes.
    ; Capped at 31 chars (EDIT_LABEL_COPY's own size — smaller than
    ; PRINT_BUF's 64, since a label this long is a far more extreme
    ; edge case than a PRINT literal) — BASIC_PARSE_IDENTIFIER itself
    ; has no length limit, so a longer typed name is silently
    ; truncated rather than overflowing this buffer. Same honest,
    ; already-accepted tradeoff as PRINT_BUF's own string-literal
    ; truncation (see BASIC_STMT_PRINT's copy loop)
    ; — a label longer than 31 characters is an extreme edge case, not
    ; one worth a real length-checked error path for right now. The
    ; CLAMPED length (not the original) is what MEM_LABEL_LOOKUP uses
    ; below, since that's the true length of what's actually stored in
    ; EDIT_LABEL_COPY — passing the untruncated original would read
    ; past this buffer's own end.
    ld   a, b
    cp   32
    jr   c, .length_ok
    ld   b, 31
.length_ok:
    push bc                              ; preserve the (possibly
                                        ; clamped) length across the
                                        ; copy loop below, which
                                        ; destroys B as its own counter
    ld   de, EDIT_LABEL_COPY
.copy_loop:
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    djnz .copy_loop
    xor  a
    ld   (de), a                         ; null-terminate (defensive —
                                        ; MEM_LABEL_LOOKUP uses the
                                        ; length below, not this, but
                                        ; keeping it terminated matches
                                        ; every other string buffer in
                                        ; this project)
    pop  bc                              ; B = the same (possibly
                                        ; clamped) length again

    ; REAL BUG FOUND AND FIXED: BASIC_SCAN_LABELS destroys BC too
    ; (documented in its own header, same as AF/DE/HL) — the length
    ; just restored above does NOT survive the call below, even
    ; though EDIT_LABEL_COPY's CONTENTS are already safely protected.
    ; This is a second, distinct instance of the same underlying
    ; mistake the DETOK_BUF fix above addressed: fixing one shared
    ; resource (the buffer) doesn't automatically fix another (a
    ; register) that the exact same call also destroys. Found via a
    ; real memory dump showing EDIT_LABEL_COPY and the label table
    ; both held the CORRECT data — "LOOP" in both places — meaning the
    ; failure had to be in a register value at call time, not memory
    ; content, once memory was already ruled out.
    push bc                              ; protect the length across
                                        ; BASIC_SCAN_LABELS_EXROM
                                        ; specifically
    call BASIC_SCAN_LABELS_EXROM         ; rebuild the label table —
                                        ; safe to clobber DETOK_BUF now,
                                        ; our own copy is safely out of
                                        ; its way
    pop  bc                              ; B = the length again, THIS
                                        ; time actually surviving the
                                        ; call that destroys it

    ld   hl, EDIT_LABEL_COPY             ; HL = our own copy; B is the
                                        ; matching length, now properly
                                        ; protected across both calls
                                        ; that could have clobbered it
    call MEM_LABEL_LOOKUP                ; -> DE = position
    jr   c, .fail

    ex   de, hl                          ; HL = position (BASIC_FIND_
                                        ; INDEX_OF_POSITION's own
                                        ; input register)
    call BASIC_FIND_INDEX_OF_POSITION      ; DE = index
    jr   c, .fail                        ; defensive — shouldn't
                                        ; normally happen for a label
                                        ; that was just found

    call BASIC_GOTO_EDIT_INDEX
    or   a
    ret
.fail:
    scf
    ret

; ============================================================================
; BASIC_DO_DELETE
; Parses "<start-index>,<end-index>" — 1-based, inclusive, matching how
; a person reads down a program listing (the first line is "1", not
; "0") — and deletes every statement in that range, same expression-
; and-comma parsing shape as BASIC_STMT_AT's row/col pair.
;
; USER-FACING NUMBERING CHANGED FROM 0-BASED TO 1-BASED (user-
; reported confusion: "DELETE 1,1" was deleting the SECOND line, not
; the first, exactly as 0-based indexing would — working as
; originally designed, but not as anyone reading a listing top to
; bottom would expect). Internally this project addresses statements
; by a 0-based index everywhere (CUR_EDIT_INDEX, BASIC_GOTO_EDIT_INDEX,
; BASIC_FIND_STATEMENT_AT_INDEX, etc.) — deliberately NOT changed, to
; avoid an off-by-one risk rippling through LIST/EDIT and every
; navigation routine that already relies on that convention. Instead,
; ONLY this routine's own user input is translated: each parsed number
; is checked for zero (typing "DELETE 0,2" is rejected — there is no
; "line 0" once counting starts at 1) and then decremented once to
; convert it to the internal 0-based index before anything else here
; uses it. Nothing else in this routine changed.
;
; Deliberately conservative: ANY problem — a malformed expression, a
; missing comma, trailing text after the second number, a typed index
; of 0, start > end, or either index out of range — aborts with carry
; set and changes NOTHING, rather than trying to salvage a partial or
; best-guess delete. The caller then falls through to treating the
; whole typed line as ordinary program text (same fallback every
; malformed immediate command already has — see BASIC_COMMAND_LOOP's
; own RUN/NEW/HELP handling), which will surface as a SYNTAX ERROR on
; the next RUN rather than silently doing nothing or doing the wrong
; thing. This reuses existing error-surfacing (the program-check pass)
; rather than inventing a new "immediate command failed" display,
; since there's no CUR_EXEC_STMT to show for something typed outside
; RUN — see BASIC_REPORT_ERROR's own contract.
;
; Both parsed (and now 0-based) indices are stashed in DELETE_START/
; DELETE_END (real RAM sysvars, not registers or the stack) — this
; routine calls several destructive helpers (BASIC_EVAL_EXPR,
; BASIC_COUNT_STATEMENTS, BASIC_FIND_STATEMENT_AT_INDEX) in sequence,
; and juggling two 16-bit values purely through push/pop across all of
; them was tried first and found genuinely harder to get right than
; just naming two scratch bytes — same "value must survive a call ->
; use memory" lesson this project has hit many times, just for two
; values instead of one here.
;
; Real deletion happens via EDITOR_BLOCK_DELETE (position-addressed,
; not index-addressed), so both (0-based) indices are converted via
; BASIC_FIND_STATEMENT_AT_INDEX right before deleting.
;
; Deliberately does NOT reuse BASIC_GOTO_EDIT_INDEX for repositioning
; afterward — that routine always parks the target at the TOP of the
; screen (right for LIST/EDIT, which are "jump there and show me"
; commands), but DELETE removing a few lines from the middle of a long
; program shouldn't yank the view away from roughly where the user was
; looking. Instead this duplicates BASIC_HANDLE_NAV's own small
; "minimal scroll to keep the target visible" formula (scroll up if
; the target moved above the current view, scroll down only enough to
; keep it on the last visible row otherwise) — matching this project's
; established preference for duplicating a short, already-verified
; formula over refactoring a heavily-tested routine to share it. Always
; lands CUR_EDIT_POS back on the sentinel (append-ready) — real
; Sinclair BASIC's own DELETE similarly returns you to immediate-
; command mode, not into the middle of the edited program — since a
; range delete doesn't have an obviously "correct" single statement to
; land on afterward the way a single-line delete does.
; In:  HL = pointer to text right after "DELETE " (already skipped the
;      space)
; Out: carry clear on success (range deleted, cursor repositioned);
;      carry set if anything was invalid — program left UNCHANGED
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_DO_DELETE:
    call BASIC_EVAL_EXPR                  ; start index (1-based, as
                                         ; typed) -> DE
    jp   c, .fail                        ; JP not JR — .fail sits far
                                         ; enough away in this routine
                                         ; that JR's own +129 reach
                                         ; isn't enough (found via a
                                         ; real assembler error: "JR
                                         ; Target out of range", this
                                         ; project's #2 recurring
                                         ; lesson — every jr targeting
                                         ; .fail/.fail_pop in this
                                         ; routine converted to jp for
                                         ; the same reason, not just
                                         ; the three the assembler
                                         ; happened to flag)
    ld   a, d
    or   e
    jr   z, .fail                        ; typed "0" — no such line in
                                         ; 1-based counting
    dec  de                              ; 1-based typed value -> 0-
                                         ; based internal index
    ld   (DELETE_START), de

    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ","
    jr   nz, .fail
    inc  hl

    call BASIC_EVAL_EXPR                  ; end index (1-based, as
                                         ; typed) -> DE
    jr   c, .fail
    ld   a, d
    or   e
    jr   z, .fail                        ; typed "0" — same reasoning
                                         ; as the start index above
    dec  de                              ; 1-based -> 0-based
    ld   (DELETE_END), de

    call BASIC_SKIP_SPACES                ; require nothing else after
                                         ; the second number — a stray
                                         ; trailing token means this
                                         ; wasn't really "DELETE a,b"
    ld   a, (hl)
    or   a                                ; REAL BUG FOUND AND FIXED:
                                         ; this used to be "cp $0D",
                                         ; copied from BASIC_STMT_AT's
                                         ; own end-of-statement check —
                                         ; but BASIC_STMT_AT reads
                                         ; already-tokenized PROGRAM
                                         ; text, which genuinely ends
                                         ; in $0D. BASIC_DO_DELETE
                                         ; instead reads straight out
                                         ; of EDIT_LINE_BUF (the just-
                                         ; typed text, before it's ever
                                         ; tokenized), which is NULL-
                                         ; terminated — so this check
                                         ; compared the buffer's real
                                         ; terminator ($00) against the
                                         ; wrong byte ($0D) and failed
                                         ; every time, even for
                                         ; perfectly valid input like
                                         ; "1,1". Found via a real
                                         ; memory dump showing
                                         ; DELETE_START/DELETE_END had
                                         ; already been parsed
                                         ; correctly (both genuinely 1)
                                         ; before this check ran —
                                         ; meaning parsing itself was
                                         ; never the problem, only this
                                         ; one comparison.
    jr   nz, .fail

    ; validate start <= end
    ld   hl, (DELETE_START)
    ld   de, (DELETE_END)
    or   a
    sbc  hl, de                           ; HL = start - end
    jr   c, .order_ok                     ; start < end (borrow) — valid
    jr   z, .order_ok                     ; start == end — also valid
                                         ; (a one-statement range)
    jr   .fail                           ; neither: start > end

.order_ok:
    ; validate end < total (start <= end already confirmed, so this
    ; alone also guarantees start is in range)
    call BASIC_COUNT_STATEMENTS            ; DE = total
    ld   hl, (DELETE_END)
    or   a
    sbc  hl, de                           ; carry set if end < total
                                         ; (the valid case)
    jr   nc, .fail                        ; end >= total — out of range

    ; both indices are valid — convert to positions and delete
    ld   de, (DELETE_START)
    call BASIC_FIND_STATEMENT_AT_INDEX      ; HL = start position —
                                           ; should always succeed
                                           ; given the checks above;
                                           ; the carry check below is
                                           ; defensive, not expected to
                                           ; ever actually fire
    jr   c, .fail
    push hl                              ; protect the start position
                                         ; across the next lookup

    ld   de, (DELETE_END)
    call BASIC_FIND_STATEMENT_AT_INDEX      ; HL = end position
    jr   c, .fail_pop

    ex   de, hl                          ; DE = end position, for
                                         ; EDITOR_BLOCK_DELETE's own
                                         ; In: HL=first, DE=last
    pop  hl                              ; HL = start position
    call BASIC_EDITOR_BLOCK_DELETE_EXROM
    jr   c, .fail                        ; propagate EDITOR_BLOCK_
                                         ; DELETE's own (currently
                                         ; theoretical — see its own
                                         ; header) abort path rather
                                         ; than silently continuing as
                                         ; if it had succeeded

    ; reposition: land on the sentinel (append-ready), with a MINIMAL
    ; scroll adjustment — see this routine's own header for why
    ; BASIC_GOTO_EDIT_INDEX isn't used here instead
    call BASIC_COUNT_STATEMENTS             ; DE = new total (fewer
                                           ; than before)
    ld   (CUR_EDIT_INDEX), de
    ld   hl, $FFFF
    ld   (CUR_EDIT_POS), hl
    call BASIC_LOAD_EDIT_LINE

    ; REAL BUG FOUND AND FIXED (user-reported, confirmed via memory
    ; dump): DELETE's underlying data was always correct — the dump
    ; showed the program genuinely shrank to exactly the right
    ; statements — but the SCREEN kept showing stale content for rows
    ; whose underlying statement identity changed (e.g. row 1 still
    ; showing the just-deleted line's old text, not whatever slid up
    ; to take its place), until something else (LIST) forced a fresh
    ; redraw. Root cause: unlike NEW/RUN/HELP, which all call
    ; BASIC_RESET_ROW_SHADOW after their own structural changes to the
    ; program, DELETE never did — the row-shadow diffing that skips
    ; redrawing unchanged rows was never told this was a structural
    ; change, so it kept trusting stale (position, flags) shadow state
    ; matched against rows whose actual content had shifted.
    ; CORRECTION (2026-08-19, [stated]-reported via screenshot): the
    ; claim that used to sit here — that the single-line delete (CAPS
    ; SHIFT+1 / EDIR_DELETE_LINE) "never needed this" — was WRONG,
    ; never actually verified against real hardware. It hits the exact
    ; same ghosting bug (confirmed via screenshot: a duplicate leftover
    ; line persisting until the next navigation forced a redraw) — now
    ; fixed there too, see .do_delete_line's own comment.
    call BASIC_RESET_ROW_SHADOW

    ; REAL BUG FOUND AND FIXED (2026-08-19, [stated]-reported —
    ; discovered alongside the row-shadow gap above): this routine
    ; also never re-ran the whole-program checker at all, unlike
    ; .commit_existing (the edit-a-line path), which explicitly does
    ; so after every commit so CHECK_ERROR_COUNT and the STATUS_CHECK_
    ; VALID cache never go stale (see that routine's own comment — the
    ; ORIGINAL error-highlighting staleness fix this exact reasoning
    ; already covered once, which DELETE was missed by entirely). Left
    ; CHECK_ERROR_COUNT frozen at whatever it was before the delete,
    ; and — the more subtle half — let STATUS_CHECK_VALID's cache
    ; (keyed on CUR_EDIT_POS, an address) go stale the same shallow-
    ; identity way as the row-shadow bug above: once a freed address
    ; gets reoccupied by a shifted statement, a CUR_EDIT_POS landing
    ; back on that same address could serve a leftover cached message
    ; for a completely different statement that used to live there.
    call BASIC_FULL_CHECK_EXROM

    ; word-wrap-aware minimal-scroll — see BASIC_SCROLL_TO_FIT's own
    ; header for why this is centralized rather than duplicated here
    ; the way the old (pre-word-wrap) formula was
    call BASIC_SCROLL_TO_FIT
    or   a                                 ; this routine's own success
                                          ; contract to ITS caller — no
                                          ; failure path exists past
                                          ; this point, matching the
                                          ; unconditional clear-carry
                                          ; every exit here already had
    ret

.fail_pop:
    pop  hl                              ; discard the stashed start
                                         ; position — restores the
                                         ; stack before reporting
                                         ; failure
.fail:
    scf
    ret

; ============================================================================
; BASIC_DO_SAVE
; Parses SAVE "filename" (the only form — no CODE/LINE/array variants,
; matching this project's current scope: only whole BASIC programs can
; be saved). Computes the program's data length directly from
; PROG_AREA_START/PROG_END rather than taking it as an argument — this
; routine owns knowing what "the program" means in memory, the same
; way BASIC_DO_DELETE owns knowing what a statement range means,
; rather than pushing that knowledge out to the dispatcher.
;
; The data length is computed and stashed on the stack (via EX (SP),HL
; — a single-instruction swap, not a separate push/pop pair) BEFORE
; the filename is parsed, since parsing needs HL/DE/B and the length
; would otherwise have nowhere to live across that work — same
; register-scarcity reasoning as kernel/storage's own routines. Every
; exit path is hand-traced for stack balance: the two failure paths
; both go through .malformed_cleanup, which pops the stashed length
; before returning, exactly matching the one push earlier — worth
; re-checking by hand if this routine is ever edited, per this
; project's stack-ordering lesson (a mismatched push/pop here would
; corrupt the return address, same bug class as the IF/ELSEIF crash).
;
; In:  HL = text right after "SAVE " (already skipped by the
;      dispatcher, same convention as BASIC_DO_DELETE/BASIC_DO_EDIT) —
;      expected to start with an opening double-quote
; Out: carry set = malformed (dispatcher shows INVALID FILENAME via
;      STORAGE_CMD_INVALID_FLAG, then falls through to ordinary
;      tokenization — same shape as BASIC_DO_DELETE's own failure
;      path); carry clear = saved
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_DO_SAVE:
    ld   a, (hl)
    cp   '"'
    jr   nz, .malformed

    push hl                              ; stash pointer to the
                                         ; opening quote
    ld   hl, (PROG_END)
    ld   de, PROG_AREA_START
    or   a
    sbc  hl, de                          ; HL = data length (may be
                                         ; 0 — an empty program is
                                         ; real and valid, handled by
                                         ; STORAGE_SEND_BLOCK's own
                                         ; DE=0 case)
    ex   (sp), hl                        ; TOS = data length, HL =
                                         ; opening-quote pointer again

    inc  hl                              ; skip opening quote
    push hl
    pop  de                              ; DE = filename start pointer
    ld   b, 0                            ; B = filename length so far
.scan:
    ld   a, (hl)
    cp   '"'
    jr   z, .closed
    or   a
    jr   z, .malformed_cleanup           ; unterminated string —
                                         ; EDIT_LINE_BUF's real
                                         ; terminator is $00, not $0D
                                         ; (same fix BASIC_DO_DELETE
                                         ; needed — see its own header)
    inc  hl
    inc  b
    jr   .scan
.closed:
    inc  hl                              ; skip closing quote
.skip_trailing:
    ld   a, (hl)
    cp   " "
    jr   nz, .check_end
    inc  hl
    jr   .skip_trailing
.check_end:
    or   a
    jr   nz, .malformed_cleanup          ; trailing text after the
                                         ; closing quote

    ; DE = filename pointer, B = filename length, TOS = data length
    push de
    pop  hl                              ; HL = filename pointer
                                         ; (STORAGE_SAVE's own In: HL)
    pop  de                              ; DE = data length (the value
                                         ; stashed via EX (SP),HL above
                                         ; — this pop is what finally
                                         ; balances that one push)
    ld   ix, PROG_AREA_START
    call BASIC_SAVE_EXROM                 ; STORAGE_SAVE now lives in
                                         ; EXROM (rom/exrom_storage.
                                         ; asm) — this wrapper pages it
                                         ; in/out; sets STORAGE_OP_STATE
                                         ; itself
    ei                                    ; STORAGE_SAVE's own DI (tape-
                                         ; timing-critical section) now
                                         ; has a real handler to guard
                                         ; against — this re-enables it
                                         ; on every return path, since
                                         ; STORAGE_SAVE itself never
                                         ; does (see kernel/storage's
                                         ; own comment on why EI
                                         ; belongs at the call site,
                                         ; not inside that routine).
                                         ; Redundant-but-harmless as of
                                         ; the EXROM move: BANK_PAGE_
                                         ; EXROM_OUT (inside BASIC_SAVE_
                                         ; EXROM) already re-enables
                                         ; interrupts itself a couple
                                         ; instructions earlier — EI is
                                         ; idempotent, so this is kept
                                         ; as a defensive, self-
                                         ; documenting no-op rather than
                                         ; removed
                                         ; now (2=SAVED, or 7=SAVE
                                         ; FAILED if the data was too
                                         ; large) — BASIC_DRAW_STATUS_
                                         ; LINE picks either up on its
                                         ; own next run. STORAGE_SAVE's
                                         ; own carry (set only on the
                                         ; too-large case) is
                                         ; deliberately NOT propagated
                                         ; as this routine's own carry
                                         ; — the SAVE command's syntax
                                         ; was fine, only the data was
                                         ; too big, a different kind of
                                         ; outcome than a malformed
                                         ; command (which would
                                         ; otherwise show INVALID
                                         ; FILENAME and fall through to
                                         ; tokenization, wrong for this
                                         ; case)
    or   a                               ; clear carry: command
                                         ; recognized and processed —
                                         ; regardless of whether the
                                         ; save itself succeeded
    ret

.malformed_cleanup:
    pop  hl                              ; discard the stashed data
                                         ; length — rebalances the
                                         ; stack before falling through
                                         ; to the shared failure exit
.malformed:
    scf
    ret

; ============================================================================
; BASIC_DO_LOAD
; Parses LOAD "filename" syntax — same shape as BASIC_DO_SAVE's own
; filename scan. The filename is now genuinely passed to STORAGE_LOAD
; and matched against the header found on tape — LOAD "" (empty
; string) is the Sinclair wildcard convention, accepting whatever
; header is found with no name check.
;
; On success, replaces the program the same way NEW does
; (full reset: variables cleared, cursor/view/error-count back to
; fresh, screen cleared, border/text-attribute defaults restored).
; Additionally rebuilds the label table (BASIC_SCAN_LABELS) and
; forces a full redraw (BASIC_RESET_ROW_SHADOW). A failed data block
; is never accepted as a partial program.
;
; In:  HL = text right after "LOAD " (same convention as BASIC_DO_SAVE)
; Out: carry set = malformed syntax (same INVALID FILENAME path as
;      BASIC_DO_SAVE); carry clear = command recognized and processed
;      — STORAGE_LOAD sets STORAGE_OP_STATE itself (LOADED / LOADED
;      WITH ERRORS / LOAD FAILED), read by BASIC_DRAW_STATUS_LINE on
;      its own next run, same as SAVE's own STORAGE_OP_STATE=7 case
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_DO_LOAD:
    ld   a, (hl)
    cp   '"'
    jp   nz, .malformed

    inc  hl                              ; skip opening quote
    push hl
    pop  de                              ; DE = filename start pointer
    ld   b, 0                            ; B = filename length so far
                                         ; — stays 0 for LOAD "" (the
                                         ; wildcard case), naturally,
                                         ; if the closing quote comes
                                         ; immediately
.scan:
    ld   a, (hl)
    cp   '"'
    jr   z, .closed
    or   a
    jp    z, .malformed
    inc  hl
    inc  b
    jr   .scan
.closed:
    inc  hl                              ; skip closing quote
.skip_trailing:
    ld   a, (hl)
    cp   " "
    jr   nz, .check_end
    inc  hl
    jr   .skip_trailing
.check_end:
    or   a
    jr    nz, .malformed

    ; DE = filename pointer, B = filename length (0 = wildcard)
    ld   a, b
    or   a
    jp   z, .load_wildcard                ; B=0 (LOAD "") — pass
                                         ; through unchanged, no
                                         ; padding needed for a
                                         ; wildcard match

    ; REAL BUG FOUND AND FIXED: STORAGE_LOAD's own filename-matching
    ; requires the caller's name to already be space-padded to exactly
    ; 10 characters (matching the header's own fixed-width field) —
    ; this was documented as a STORAGE_LOAD precondition but never
    ; actually built here, so any real (non-wildcard) LOAD "name"
    ; shorter than 10 characters — which is virtually always — got
    ; rejected as a false mismatch before a single data block was ever
    ; attempted, regardless of whether the name genuinely matched what
    ; was on tape. Found via a debug.bin dump after a LOAD FAILED
    ; report against a tape independently verified byte-perfect
    ; (header and data blocks, checksums confirmed correct) — the failure was purely this
    ; missing padding step, not a signal or receive-logic problem.
    ex   de, hl                          ; HL = real scan pointer
                                         ; (was in DE)
    ; DETOK_BUF is shared redraw/parser scratch and can be overwritten by
    ; STORAGE_LOAD's initial progress-hook redraw before header matching.
    ; EDIT_LABEL_COPY is retained text storage and is idle for this
    ; blocking immediate command.
    ld   de, EDIT_LABEL_COPY
    ld   c, STORAGE_HEADER_FILENAME_LEN
.pad_copy:
    ld   a, b
    or   a
    jr   z, .pad_char
    ld   a, (hl)
    inc  hl
    dec  b
    jr   .pad_store
.pad_char:
    ld   a, ' '
.pad_store:
    ld   (de), a
    inc  de
    dec  c
    jr   nz, .pad_copy
    ld   hl, EDIT_LABEL_COPY             ; HL = the retained padded name
    ld   b, STORAGE_HEADER_FILENAME_LEN  ; B = 10, matching what
                                         ; STORAGE_LOAD's own check
                                         ; requires
    jr   .load_call

.load_wildcard:
    push de
    pop  hl                              ; HL = filename pointer
                                         ; (STORAGE_LOAD's own In: HL)
                                         ; — B already 0, untouched

.load_call:
    ; DE = max allowed data length — VARS_START (not the fixed PROG_
    ; AREA_MAX any more, since the CURRENT program's own scalars, not
    ; yet wiped at this point — that only happens below, on SUCCESS —
    ; may already occupy some of that space; see sysvars.inc's own
    ; VARS_START header) minus PROG_AREA_START. Can't be the compile-
    ; time constant it used to be now that the ceiling is a runtime
    ; value. STORAGE_LOAD's own bound, see its header + STORAGE_MAX_LEN
    ; in sysvars.inc. Preserve HL: it carries the filename pointer
    ; required by STORAGE_LOAD after this size calculation.
    push hl
    ld   hl, (VARS_START)
    ld   de, PROG_AREA_START
    or   a
    sbc  hl, de
    ex   de, hl
    pop  hl
    ld   ix, PROG_AREA_START
    call BASIC_LOAD_EXROM                 ; STORAGE_LOAD now lives in
                                         ; EXROM (rom/exrom_storage.
                                         ; asm) — this wrapper pages it
                                         ; in/out, preserving carry
                                         ; (and A, unused here) across
                                         ; the page-out step; sets
                                         ; STORAGE_OP_STATE itself
    ei                                    ; STORAGE_LOAD's own DI is
                                         ; unconditional from its very
                                         ; first line, so EVERY return
                                         ; path needs this — same
                                         ; reasoning as the SAVE call
                                         ; site just above in this file,
                                         ; and same redundant-but-
                                         ; harmless note re: BANK_PAGE_
                                         ; EXROM_OUT's own EI now (4/5/
                                         ; 6) — see this routine's own
                                         ; header. On carry clear, DE =
                                         ; actual data length received
                                         ; (A = 0 on success)
    jr   c, .load_failed

    ; success — DE = actual data length received
    ld   hl, PROG_AREA_START
    add  hl, de
    ld   (PROG_END), hl

    ld   hl, PROG_AREA_MAX
    ld   (VARS_START), hl                ; scalar pool -> empty, same
                                         ; reasoning as NEW's own reset
                                         ; (MEM_INIT) — a freshly loaded
                                         ; program's variables start
                                         ; clean, same as before

    call BASIC_RESET_EDIT_STATE          ; same fresh-state setup NEW
                                         ; already established — a
                                         ; different program is now
                                         ; loaded, so start over the
                                         ; same way NEW/cold boot do

    call GFX_CLS
    ld   a, BORDER_DEFAULT
    call GFX_SET_BORDER
    call BASIC_RESET_TEXT_ATTR
    xor  a
    call GFX_SET_MODE                   ; a freshly loaded program
                                        ; starts from Normal mode too —
                                        ; same reasoning as the other
                                        ; two call sites just above
                                        ; this file's own history

    call BASIC_SCAN_LABELS_EXROM           ; real program content now
                                         ; exists — rebuild the label
                                         ; table
    call BASIC_RESET_ROW_SHADOW

    ; REAL BUG FOUND AND FIXED (2026-08-24, real user report: "load
    ; program is never showing it is completed"): STORAGE_LOAD (kernel/
    ; storage/storage.asm) already draws LOADED to
    ; the status bar via STORAGE_PROGRESS_HOOK before it even returns
    ; here — but GFX_CLS just above wipes the ENTIRE screen, including
    ; that just-drawn text, before a human (or a screenshot) ever gets
    ; a real frame boundary to see it; it all happens within this same
    ; uninterrupted call chain. STORAGE_OP_STATE is still sitting at
    ; its real 4/5 value untouched by anything in between, so a second,
    ; LATER draw — after the screen has actually settled into its final
    ; post-load state — is what actually reaches the user.
    call BASIC_DRAW_STATUS_LINE
    or   a                               ; clear carry: success
    ret

.load_failed:
    ; STORAGE_LOAD already set STORAGE_OP_STATE=6 (LOAD FAILED) —
    ; BASIC_DRAW_STATUS_LINE shows it on its own next run. A=$FF means
    ; reception wrote into PROG_AREA before failing, so the former
    ; program is no longer trustworthy. Reset it to empty; failures
    ; before any destination write preserve the current program.
    inc  a                               ; $FF -> 0 only for dirty failure
    jr   nz, .load_failed_clean
    call MEM_INIT
    call BASIC_RESET_EDIT_STATE
    call BASIC_RESET_ROW_SHADOW
.load_failed_clean:
    or   a                               ; clear carry — the typed
                                         ; syntax itself was fine;
                                         ; only the receive failed,
                                         ; reported via the status
                                         ; line above, not as a
                                         ; dispatcher-level failure
    ret

.malformed:
    scf
    ret


; ============================================================================
; BASIC_LOAD_EDIT_LINE
; Populates EDIT_LINE_BUF (and resets EDIT_BUF_OFFSET to 0) based on
; CUR_EDIT_POS — empty if it's the sentinel, otherwise the detokenized
; text of that existing statement. "Detokenizing" is trivial for this
; project's tokenizer specifically (no keyword compression), same as
; BASIC_REDRAW_PROGRAM's own copy of this logic for display — this is
; the shared version, called both from BASIC_COMMAND_LOOP (every loop
; iteration, since EDITOR_INIT wipes EDIT_LINE_BUF each time) and
; BASIC_HANDLE_NAV (after moving to a different statement).
; In:  none (reads CUR_EDIT_POS)
; Out: EDIT_LINE_BUF and EDIT_BUF_OFFSET updated
; Destroys: AF, BC, DE, HL
; ============================================================================
; ============================================================================
; BASIC_DETOKENIZE_TO_BUF
; Shared parsing primitive: copies bytes from HL to DE until a $0D
; (statement terminator) is hit, then null-terminates the destination.
; Factors out this exact copy loop, duplicated identically at 3 sites
; (BASIC_LOAD_EDIT_LINE, the error-display detokenize, and
; BASIC_REDRAW_PROGRAM's own settled-row detokenize) — none of the
; three callers depend on HL/DE's exact final value, since each
; reloads or restores its own copy of HL immediately afterward.
; In:  HL = source text pointer (past any length prefix the caller
;      already skipped); DE = destination buffer
; Out: destination buffer holds a null-terminated copy of the source
;      up to (not including) the $0D
; Destroys: AF, HL, DE
; ============================================================================
BASIC_DETOKENIZE_TO_BUF:
    ld   a, (hl)
    cp   $0D
    jr   z, .done
    ld   (de), a
    inc  hl
    inc  de
    jr   BASIC_DETOKENIZE_TO_BUF
.done:
    xor  a
    ld   (de), a
    ret

    DEFINE EMIT_BASIC_EDITOR_LOAD_LINE
    INCLUDE "basic/editor_integration.asm"
    UNDEFINE EMIT_BASIC_EDITOR_LOAD_LINE

    DEFINE EMIT_BASIC_EDITOR_NAVIGATION
    INCLUDE "basic/editor_integration.asm"
    UNDEFINE EMIT_BASIC_EDITOR_NAVIGATION

BASIC_TO_UPPER:
    cp   "a"
    ret  c
    cp   "z" + 1
    ret  nc
    sub  $20
    ret

; ============================================================================
; BASIC_SKIP_SPACES
; In:  HL = text pointer
; Out: HL = advanced past any run of spaces (0 or more)
; Destroys: AF
; ============================================================================
BASIC_SKIP_SPACES:
    ld   a, (hl)
    cp   " "
    ret  nz
    inc  hl
    jr   BASIC_SKIP_SPACES

; ============================================================================
; BASIC_PARSE_IDENTIFIER
; Parses a run of letters (A-Z/a-z), copying an UPPERCASED VERSION into
; DETOK_BUF (reused as scratch space here — see IDENT_WRITE_PTR's own
; comment for why) — the source text itself is never touched. Labels
; are case-insensitive, matching this project's existing keyword
; convention, so whatever case a label was DEFINED in and whatever
; case a later GOTO references it in still match once both have
; passed through here.
;
; A real bug shipped in the first version of this: it uppercased the
; identifier IN PLACE in the source text instead of copying it, which
; meant every time a GOTO executed, it permanently rewrote its own
; label reference in the STORED PROGRAM — found from the user noticing
; "nowhere" had silently become "NOWHERE" after listing the program
; following a test run. Inconsistent with how this project normalizes
; everything else (keywords only get uppercased once, at commit time,
; never as a side effect of running). Fixed by copying instead of
; mutating — case-insensitive comparison still works exactly the same
; way, since MEM_LABEL_ADD/LOOKUP only care about the bytes at HL, not
; where they physically live.
;
; This is genuinely needed because labels are multi-character names,
; unlike this project's variables (always a single letter A-Z) —
; nothing else in basic/ has needed to parse a general identifier
; before now.
;
; Hand-traced against "loop:" (a label definition): starting at 'l',
; each of l/o/o/p is read from the source, uppercased into a LOCAL
; copy in A (the source byte itself is never written to), and appended
; to DETOK_BUF; ':' fails both the lowercase and uppercase-range
; checks, so the scan stops there with the source's read pointer (DE)
; landing exactly on ':', unchanged — B=4, HL=DETOK_BUF holding
; "LOOP\0".
; In:  HL = text pointer (source, read-only)
; Out: HL = pointer to DETOK_BUF (an uppercased COPY, null-terminated —
;      NOT the original source, which is never modified), B = length
;      (0 if the character at HL isn't a letter at all — not itself an
;      error, the caller decides what an empty identifier means),
;      DE = position in the SOURCE right after the identifier
; Destroys: AF
; ============================================================================
BASIC_PARSE_IDENTIFIER:
    ld   d, h
    ld   e, l                        ; DE = source read pointer, starts
                                     ; at HL — read-only from here on,
                                     ; never written back to
    ld   hl, DETOK_BUF
    ld   (IDENT_WRITE_PTR), hl
    ld   b, 0
.loop:
    ld   a, (de)
    cp   "a"
    jr   c, .check_upper
    cp   "z" + 1
    jr   nc, .check_upper
    sub  $20                          ; lowercase -> uppercase, in A
                                     ; only — (de) itself is never
                                     ; written to
.check_upper:
    cp   "A"
    jr   c, .done
    cp   "Z" + 1
    jr   nc, .done

    ld   hl, (IDENT_WRITE_PTR)
    ld   (hl), a
    inc  hl
    ld   (IDENT_WRITE_PTR), hl

    inc  de
    inc  b
    jr   .loop
.done:
    ld   hl, (IDENT_WRITE_PTR)
    xor  a
    ld   (hl), a                      ; null-terminate the copy

    ld   hl, DETOK_BUF
    ret

; ============================================================================
; BASIC_EVAL_EXPR / BASIC_EVAL_TERM / BASIC_EVAL_FACTOR / BASIC_EVAL_PRIMARY
;
; Recursive-descent expression evaluator, classic precedence-climbing
; grammar (each level handles one precedence tier, calling down to the
; next for its operands):
;   expression := term (('+'|'-') term)*
;   term       := factor (('*'|'/') factor)*
;   factor     := ['-'] primary
;   primary    := NUMBER | VARIABLE | '(' expression ')'
;
; BASIC_EVAL_EXPR is the only public entry point — a drop-in
; replacement for BASIC_PARSE_NUMBER wherever a value needs parsing:
; same HL-in/HL-out/DE-out/carry-on-fail contract, but understands the
; whole grammar above instead of just a bare literal. Multiplication
; uses kernel/math's MATH_MULTIPLY16 (verified numerically before this
; evaluator was written — see that module's own header). Division goes
; through the RST $28 calculator engine (rom/exrom_calc.asm's
; CALC_OP_DIV, 2026-08-21 — see BASIC_EVAL_TERM's own .divide_ok for
; why) rather than kernel/math's MATH_DIVIDE16; both truncate toward
; zero identically for every case that matters here.
;
; EXPR_PARSE_PTR (memory, not a register) tracks the current position
; internally, deliberately shared across recursion levels — a
; parenthesized sub-expression recursively calls BASIC_EVAL_EXPR again,
; and that inner call needs to advance the SAME ongoing position so the
; outer call sees where it left off. This is why HL isn't used directly
; as the working parse pointer the way BASIC_PARSE_NUMBER does: HL is
; needed as a genuine VALUE register during arithmetic (both operands
; of + and - pass through it), and fighting over HL between "current
; parse position" and "operand being computed" across recursive calls
; is exactly the kind of register-survival bug this project has been
; bitten by more than once already. Every routine here reads
; EXPR_PARSE_PTR fresh when it needs the current character and writes
; it back immediately after advancing — the caller-facing HL-in/HL-out
; contract on BASIC_EVAL_EXPR itself is just a thin copy-in/copy-out
; wrapper around that.
;
; Hand-traced against "3+4*2" end to end (see below) to confirm
; operator precedence actually works before trusting this design —
; multiplication must bind tighter than addition, giving 11, not 14.
; ============================================================================
BASIC_EVAL_EXPR:
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_TERM
    ret  c

.loop:
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   (EXPR_PARSE_PTR), hl
    ld   a, (hl)
    cp   "+"
    jr   z, .do_add
    cp   "-"
    jr   z, .do_sub
    or   a
    ret                                 ; done — DE already holds the
                                        ; accumulated value, HL is
                                        ; already the final position

.do_add:
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    push de                              ; save the left-hand accumulator
    call BASIC_EVAL_TERM
    jr   c, .fail_restore
    pop  hl                                ; HL = left, DE = right
    add  hl, de
    ex   de, hl                              ; result back into DE
    xor  a                                    ; a "+" just combined two
    ld   (FUNC_RESULT_IS_FLOAT), a            ; values — whatever float
                                              ; flag either side left
                                              ; behind no longer applies
                                              ; to THIS result (see
                                              ; FUNC_RESULT_IS_FLOAT's
                                              ; own sysvars.inc comment)
    jr   .loop

.do_sub:
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    push de
    call BASIC_EVAL_TERM
    jr   c, .fail_restore
    pop  hl
    or   a
    sbc  hl, de
    ex   de, hl
    xor  a
    ld   (FUNC_RESULT_IS_FLOAT), a            ; same reasoning as "+"
                                              ; above
    jr   .loop

.fail_restore:
    pop  hl                                ; discard the pushed left
                                          ; operand, keep the stack
                                          ; balanced
    scf
    ret

; ----------------------------------------------------------------------
BASIC_EVAL_TERM:
    call BASIC_EVAL_FACTOR
    ret  c

.loop:
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   (EXPR_PARSE_PTR), hl
    ld   a, (hl)
    cp   "*"
    jr   z, .do_mul
    cp   "/"
    jr   z, .do_div
    or   a
    ret

.do_mul:
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    push de
    call BASIC_EVAL_FACTOR
    jr   c, .fail_restore
    pop  hl                              ; HL = left, DE = right
    call MATH_MULTIPLY16                   ; HL = product
    ex   de, hl
    xor  a
    ld   (FUNC_RESULT_IS_FLOAT), a          ; same reasoning as "+"/"-"
                                           ; in BASIC_EVAL_EXPR above
    jr   .loop

.do_div:
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    push de
    call BASIC_EVAL_FACTOR
    jr   c, .fail_restore
    pop  hl                              ; HL = left (dividend), DE =
                                        ; right (divisor)

    ld   a, d
    or   e
    jr   nz, .divide_ok                    ; divisor genuinely 0 —
                                          ; MATH_DIVIDE16 would silently
                                          ; return 0 (its own deliberate
                                          ; safe default, documented in
                                          ; kernel/math's own header —
                                          ; but basic/ can and should do
                                          ; better now that real error
                                          ; reporting exists, since a
                                          ; caller here has actual
                                          ; context kernel/math doesn't
    ld   hl, MSG_DIVISION_BY_ZERO
    call BASIC_SET_PENDING_ERROR
    scf
    ret

.divide_ok:
    ; Routed through the RST $28 calculator engine (rom/exrom_calc.asm's
    ; CALC_OP_DIV, 2026-08-21) rather than kernel/math's MATH_DIVIDE16 —
    ; the first real BASIC integration for that engine (everything
    ; before this was standalone smoke tests only). Divisor-zero is
    ; already intercepted above, before this label is ever reached, so
    ; CALC_OP_DIV's own div-by-zero hang (no error-reporting path into
    ; BASIC exists at that layer yet) can never actually trigger from
    ; here. Behaviorally identical to MATH_DIVIDE16 for every ordinary
    ; case (both truncate toward zero); the one boundary case where they
    ; could differ, -32768/-1 (the dividend has no positive two's-
    ; complement counterpart, and the true quotient 32768 doesn't fit in
    ; signed 16 bits either), was already undefined/quirky through
    ; kernel/math's own inline abs-value step — not a behavior this
    ; switch needs to preserve bit-for-bit.
    push de                      ; save the divisor — CALC_INT_TO_FP
                                 ; destroys DE, and it's needed again
                                 ; for the second push below
    call CALC_INT_TO_FP_HOME     ; pushes the dividend (HL) as a float
                                 ; onto CALC_STACK
    pop  hl                      ; HL = divisor
    call CALC_INT_TO_FP_HOME     ; pushes the divisor too — CALC_STACK
                                 ; now holds [dividend, divisor], divisor
                                 ; on top ("second"/top operand),
                                 ; matching CALC_OP_DIV's first(lower)/
                                 ; second(top) = dividend/divisor
                                 ; convention (same as CALC_OP_SUB's)
    ld   b, 0                    ; ordinary top-level RST $28 call — see
                                 ; CALC_ENTRY_TRAMPOLINE's own contract
                                 ; for what B means here
    rst  $28
    DB   $05, $38                 ; division, end-calc
    call CALC_FP_TO_INT_HOME     ; HL = truncated-toward-zero quotient;
                                 ; CALC_SP back to 0 (2 pushed, 1
                                 ; produced by the division, 1 popped
                                 ; here) — deliberately not checking
                                 ; CALC_TRUNC_FLAG, same as MATH_
                                 ; DIVIDE16's own lack of an overflow
                                 ; signal
    ex   de, hl
    xor  a
    ld   (FUNC_RESULT_IS_FLOAT), a  ; "/" combined two values same as
                                    ; "+"/"-"/"*" above — its own
                                    ; truncated result is int-composed
                                    ; from here on, not the float PRINT
                                    ; could otherwise show (see FUNC_
                                    ; RESULT_IS_FLOAT's own sysvars.inc
                                    ; comment)
    jr   .loop

.fail_restore:
    pop  hl
    scf
    ret

; ----------------------------------------------------------------------
BASIC_EVAL_FACTOR:
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   (EXPR_PARSE_PTR), hl
    ld   a, (hl)
    cp   "-"
    jr   nz, .no_negate
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_PRIMARY
    ret  c
    ld   hl, 0                           ; negate DE (two's complement)
    or   a
    sbc  hl, de
    ex   de, hl
    push af                              ; survive across the sysvar
                                        ; write below — carry (checked
                                        ; further down, past the bug-
                                        ; fix comment) must reach the
                                        ; final `ret` unchanged
    xor  a
    ld   (FUNC_RESULT_IS_FLOAT), a       ; unary minus negates the
                                        ; truncated int only, not
                                        ; FUNC_RESULT_FLOAT — whatever
                                        ; the operand's own flag said,
                                        ; "-x" is no longer that bare
                                        ; float-producing call (see
                                        ; FUNC_RESULT_IS_FLOAT's own
                                        ; sysvars.inc comment)
    pop  af
    ; REAL, PRE-EXISTING BUG FOUND AND FIXED (caught by tools/z80sim
    ; while testing ABS(-32768), not by anything related to the new
    ; function-call feature itself — this path predates it and was
    ; never exercised through the simulator before now). SBC HL,DE
    ; sets the carry flag on a borrow, which happens on every
    ; negation of a nonzero value (0 - nonzero always borrows) — and
    ; that carry was falling straight through to this routine's own
    ; RET, where every caller up the chain (BASIC_EVAL_EXPR/TERM and
    ; everything built on them) treats carry-set as "parse failed."
    ; Concretely: "-5", "X=-5", "PRINT -5", "IF X>-1 THEN" — ANY
    ; expression containing a literal unary-minus on a nonzero value
    ; — was reporting a bogus SYNTAX ERROR, unconditionally, on
    ; correctly-formed input. Only "-0" (a degenerate case nobody
    ; would type) happened to avoid it, which is almost certainly why
    ; real testing never surfaced this. Fixed by clearing carry before
    ; returning, the same way every other genuinely-successful exit
    ; in this evaluator already does.
    or   a
    ret
.no_negate:
    jr   BASIC_EVAL_PRIMARY

; ----------------------------------------------------------------------
BASIC_EVAL_PRIMARY:
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   (EXPR_PARSE_PTR), hl
    ld   a, (hl)

    cp   "("
    jp   z, .do_paren

    cp   "0"
    jr   c, .check_var                     ; below '0' — not a digit
    cp   "9" + 1
    jp   c, .do_number                       ; '0'-'9' — genuinely a digit
                                             ; — JP not JR: .do_number
                                             ; is now far enough past
                                             ; the grown .check_var/
                                             ; .do_function_call block
                                             ; (MOD's two-argument
                                             ; parsing) that JR's
                                             ; +129 range doesn't reach
                                             ; it (project's own
                                             ; recurring JR-range
                                             ; lesson — see
                                             ; docs/programmers_
                                             ; reference.md)
    jr   .check_var                            ; above '9' — not a digit
                                               ; either (could be a letter)

.check_var:
    ; Try a built-in function call (ABS(x), SGN(x), ...) BEFORE the
    ; single-letter-variable check below — a function name's first
    ; letter would otherwise be consumed as an unrelated single-letter
    ; variable (e.g. "ABS(5)" misread as variable A followed by
    ; leftover, unparseable "BS(5)"). HL here is still the current,
    ; unconsumed text position (BASIC_EVAL_PRIMARY's own entry code
    ; above already skipped spaces and stored it to EXPR_PARSE_PTR;
    ; nothing between there and here has moved it).
    call BASIC_TRY_EVAL_FUNCTION
    jr   nc, .do_function_call

    ; REAL BUG FOUND AND FIXED (caught by tools/z80sim, not static
    ; analysis): BASIC_TRY_EVAL_FUNCTION destroys A along with
    ; AF/BC/DE/HL/IX (documented in its own header) — but everything
    ; below here was written assuming A still held the original raw
    ; character from BASIC_EVAL_PRIMARY's entry code above, the exact
    ; register-survival mistake this project has hit many times
    ; before (see kernel/math/math.asm and elsewhere). A plain
    ; variable reference like "X" reached BASIC_TRY_EVAL_FUNCTION,
    ; correctly found no match (carry set, HL correctly still pointing
    ; at "X"), but then BASIC_TO_UPPER ran on A's now-garbage leftover
    ; value from the failed table walk instead of 'X' — reading it as
    ; below "A" and failing with a bogus SYNTAX ERROR on every single
    ; variable reference. HL itself is fine (BASIC_MATCH_FUNCTION_
    ; NAME's own failure paths restore it), so reloading A from it
    ; here is enough; the fix costs nothing since this instruction
    ; would otherwise just be redundant on the ORIGINAL first-pass
    ; entry, not wrong.
    ld   a, (hl)

    call BASIC_VALIDATE_VAR_LETTER
    jp   c, .fail
    ld   d, a                              ; D = uppercased letter,
                                          ; stashed in a register (not
                                          ; overwritten by the array-
                                          ; ref peek below, which needs
                                          ; A as its own scratch)
    ld   hl, (EXPR_PARSE_PTR)
    inc  hl
    ld   a, (hl)
    cp   "("
    jr   z, .do_array_read                  ; letter immediately
                                            ; followed by "(" — array-
                                            ; index read (e.g. "A(3)"),
                                            ; not the plain scalar
                                            ; below; HL already points
                                            ; at "(", matching .do_
                                            ; array_read's own entry

    ld   a, d                              ; A = uppercased letter
                                          ; (restored)
    call BASIC_VAR_ADDR                    ; HL = variable's address
    ret  c                                 ; pool exhausted — error
                                          ; already recorded
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                             ; DE = variable's value
    ld   hl, (EXPR_PARSE_PTR)
    inc  hl                                    ; advance past the
    ld   (EXPR_PARSE_PTR), hl                    ; 1-character variable
    or   a
    ret

; ============================================================================
; .do_array_read — array-element read (A(i) used as a primary)
; In: D = uppercased array-variable letter, HL = pointer at "("
;
; REAL BUG FOUND AND FIXED (2026-08-22, "B = A(0)" silently storing
; into A's own VAR_TABLE slot instead of B's): the first draft stashed
; the array's own letter in CUR_VAR_LETTER — the SAME shared scratch
; byte BASIC_TRY_ASSIGNMENT/BASIC_TRY_ARRAY_ASSIGNMENT/BASIC_STMT_DIM
; already use for THEIR OWN "letter being assigned" bookkeeping. Since
; an array read can be reached WHILE one of those is still mid-parse
; (any array read appearing inside another statement's own RHS/index/
; size expression — "B = A(0)" is exactly this: B's own assignment
; stashes 'B' in CUR_VAR_LETTER, then evaluating "A(0)" for the RHS
; recurses in here and overwrites it with 'A' before the OUTER
; assignment ever reads it back), a shared memory scratch silently
; breaks — same "shared mutable scratch clobbered by a nested call"
; bug class as the FUNC_CALL_ID/ARGC bug in .do_function_call above
; and the DETOK_BUF collision in EDIT. Fixed by pushing the letter onto
; the real stack instead (in D here) — pushes naturally nest correctly
; no matter how deep the recursion goes, unlike one shared byte.
;
; BASIC_CHECK_ONLY-guarded, same reasoning USR's own guard above
; documents: this routine (via BASIC_EVAL_EXPR's own call chain) is
; also what the whole-program/live-typing checker uses to validate
; expression grammar WITHOUT really running the program — an array
; referenced here may not be DIM'd yet during that static pre-pass
; (DIM is itself just another statement, not necessarily executed
; before this one is checked), so "does the array exist"/"is the
; index in range" are both deliberately runtime-only questions; when
; checking, only the index expression's own grammar is validated, the
; real lookup/bounds-check are skipped and a harmless 0 returned.
; ============================================================================
.do_array_read:
    push de                                 ; stash the letter (D) —
                                            ; see this routine's own
                                            ; header for why the stack,
                                            ; not CUR_VAR_LETTER
    inc  hl                                 ; consume "("
    call BASIC_ARRAY_PARSE_SUBSCRIPTS        ; ARRAY_INDEX set, HL =
                                            ; past the closing ")" —
                                            ; shared with array write,
                                            ; see that routine's own
                                            ; header
    jr   c, .array_read_fail_pop

    ld   a, (BASIC_CHECK_ONLY)
    or   a
    jr   nz, .array_read_check_only_pop

    pop  de                                  ; D = letter (restored)
    ld   a, d
    ld   c, ARRAY_KIND_NUM
    call BASIC_ARRAY_FIND                    ; HL = data, DE = count
    jr   c, .array_read_not_dimmed
    call BASIC_ARRAY_ELEMENT_ADDR            ; HL = element address —
                                             ; bounds-checks the index,
                                             ; own header has the full
                                             ; contract
    ret  c                                   ; error already recorded
                                             ; by BASIC_ARRAY_ELEMENT_
                                             ; ADDR
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                                ; DE = element value
    ld   hl, (EXPR_PARSE_PTR)
    or   a
    ret

.array_read_check_only_pop:
    pop  de                                  ; balance the letter
                                             ; stash (unused on this
                                             ; path)
    ld   de, 0
    ld   hl, (EXPR_PARSE_PTR)
    or   a
    ret

.array_read_not_dimmed:
    ld   hl, MSG_ARRAY_NOT_DIMMED
    call BASIC_SET_PENDING_ERROR
    scf
    ret
.array_read_fail_pop:
    pop  de                                   ; balance the letter
                                              ; stash — error already
                                              ; recorded by whatever
                                              ; failed
    jp   .fail

.do_function_call:
    ; BASIC_TRY_EVAL_FUNCTION already matched a known function name and
    ; consumed it plus its opening '(' — HL is positioned right at the
    ; start of the first argument, EXPR_PARSE_PTR already holds that
    ; same position (see BASIC_MATCH_FUNCTION_NAME's own contract),
    ; and FUNC_CALL_HANDLER/FUNC_CALL_ARGC say which handler to enter
    ; and how many arguments it takes.
    ;
    ; REAL BUG FOUND AND FIXED (caught by tools/z80sim testing
    ; MOD(ABS(X),3) — a function call nested inside another function's
    ; own argument): FUNC_CALL_HANDLER/FUNC_CALL_ARGC are shared scratch,
    ; set by BASIC_TRY_EVAL_FUNCTION every time ANY function name is
    ; matched. The recursive BASIC_EVAL_EXPR call below, while parsing
    ; THIS call's own argument(s), can itself reach another function
    ; call (ABS(X) here) — which overwrites the handler/argc result with
    ; ITS OWN values before this (outer, MOD's) call ever gets to read
    ; them back. Concretely: MOD's ARGC=2 was being clobbered to
    ; ABS's ARGC=1 by the time this code checked it, so
    ; "MOD(ABS(X),3)" took the one-argument branch and rejected the
    ; following ',' as a syntax error. Same root-cause family as the
    ; DETOK_BUF collision bug in EDIT (see BASIC_DO_EDIT's own
    ; header) — shared mutable scratch clobbered by a nested call.
    ; Fixed by snapshotting our OWN ID/ARGC into BC and pushing that
    ; onto the real stack immediately, before any recursive call gets
    ; a chance to touch the shared sysvars — same "value must survive
    ; a destructive call" reasoning this project applies everywhere
    ; else, just via the stack instead of a dedicated sysvar, since
    ; this needs to survive an arbitrary, unbounded depth of recursion
    ; (nested/repeated function calls), not one specific call site.
    ld   bc, (FUNC_CALL_HANDLER)
    push bc
    ld   a, (FUNC_CALL_ARGC)
    push af                                    ; handler + argc snapshots,
                                               ; safe from nested calls

    ; ARGC_STR1 (100) is a sentinel, not a real argument count — LEN/
    ; CODE/VAL take one STRING argument, which doesn't fit the numeric
    ; one-arg/two-arg shapes below, so it's intercepted here, before
    ; the numeric zero/one/two-arg chain gets a chance to misinterpret
    ; 100 as an argument count. (ARGC_STR2/INSTR dropped 2026-08-22 —
    ; see FUNC_ID_INSTR's own comment for why.)
    cp   ARGC_STR1
    jr   z, .str_arg_1

    ; ARGC_ARRAYNAME (101) — DIMN(name), 2026-08-22. Same reasoning as
    ; ARGC_STR1: DIMN's own argument is a bare array-name LETTER, not
    ; an expression to evaluate (a plain "A" would otherwise just read
    ; scalar variable A's value) — intercept before the numeric argc
    ; chain below gets a chance to misread 101 as an argument count.
    cp   ARGC_ARRAYNAME
    jr   z, .array_name_dim_arg

    ; argc==0 (FREE, the only current 0-argument built-in) has no
    ; expression to parse at all — A still holds argc here (ld c,a
    ; just above left it untouched, and push bc doesn't touch A
    ; either), so this reuses that value rather than reloading it.
    or   a
    jp   z, .zero_arg                        ; JP not JR — the new
                                            ; ARGC_ARRAYNAME block above
                                            ; pushed .zero_arg out of
                                            ; JR's range (project's own
                                            ; recurring JR-range lesson)

    call BASIC_EVAL_EXPR                     ; DE = first argument, HL
                                            ; = advanced position
    jr   c, .fail_after_push                  ; must pop BC before
                                              ; propagating failure now

    pop  af                                    ; A = argc snapshot
    pop  bc                                    ; BC = handler snapshot
    cp   2
    jr   z, .two_arg

    ; ---- one-argument functions (ABS, SGN) ----
    ld   hl, (EXPR_PARSE_PTR)
    ld   a, (hl)
    cp   ")"
    jp   nz, .fail                             ; missing closing paren
                                              ; — JP not JR: .fail is
                                              ; ~150 source lines away
                                              ; now, past this project's
                                              ; own proactive JR-range
                                              ; threshold
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    ld   h, d
    ld   l, e                                  ; HL = the argument —
                                              ; every one-argument
                                              ; built-in takes it in
                                              ; HL (MATH_ABS16/
                                              ; MATH_SGN16's own
                                              ; contract)
    jp   .dispatch                               ; JP not JR — the new
                                                ; ARGC_STR1/STR2 string-
                                                ; argument dispatch
                                                ; block above pushed
                                                ; .dispatch out of JR's
                                                ; range (project's own
                                                ; recurring JR-range
                                                ; lesson)

    ; ---- two-argument functions (MOD) ----
.two_arg:
    push bc                                    ; save handler snapshot
                                              ; again, across the
                                              ; second recursive call
                                              ; below (which could
                                              ; itself reach a nested
                                              ; function call, same
                                              ; hazard as the first)
    ld   hl, (EXPR_PARSE_PTR)
    ld   a, (hl)
    cp   ","
    jr   nz, .two_arg_fail_early                 ; missing comma
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    push de                                    ; save the first argument
                                              ; across the recursive
                                              ; call — same idiom
                                              ; BASIC_EVAL_EXPR's own
                                              ; do_add/do_sub already
                                              ; use for the identical
                                              ; reason
    call BASIC_EVAL_EXPR                       ; DE = second argument,
                                              ; HL = advanced position
    jr   c, .two_arg_fail                        ; must pop before
                                                ; failing now that
                                                ; something's pushed

    ld   hl, (EXPR_PARSE_PTR)
    ld   a, (hl)
    cp   ")"
    jr   nz, .two_arg_fail                       ; missing closing paren
    inc  hl
    ld   (EXPR_PARSE_PTR), hl

    pop  hl                                      ; HL = first argument
                                                ; (dividend), DE =
                                                ; second argument
                                                ; (divisor) already in
                                                ; place — exactly
                                                ; MATH_MOD16's own
                                                ; HL-in/DE-in contract
    pop  bc                                      ; BC = our snapshot,
                                                ; restored again
    jp   .dispatch                               ; JP not JR — the new
                                                ; ARGC_STR1/STR2 string-
                                                ; argument dispatch
                                                ; block above pushed
                                                ; .dispatch out of JR's
                                                ; range (project's own
                                                ; recurring JR-range
                                                ; lesson)

.two_arg_fail_early:
    pop  bc                                      ; discard the re-pushed
                                                ; handler snapshot —
                                                ; nothing else pushed
                                                ; on this path yet
    scf
    ret

.two_arg_fail:
    pop  de                                      ; discard the pushed
                                                ; first argument, keep
                                                ; the stack balanced —
                                                ; same discard idiom
                                                ; used throughout this
                                                ; evaluator's other
                                                ; fail-restore paths
    pop  bc                                      ; discard our snapshot
    scf
    ret

.fail_after_push:
    pop  af                                      ; discard argc snapshot
    pop  bc                                      ; discard handler snapshot,
                                                ; keep the
                                                ; stack balanced
    scf
    ret

; ---- DIMN(name) — ARGC_ARRAYNAME, 2026-08-22 ----
; Returns an array's declared size — lets a procedure loop over an
; array without hardcoding it, e.g. "FOR i = 0 TO DIMN(A)-1". (Took a
; second "dim" argument for a while, alongside now-archived multi-
; dimensional array support — see docs/programmers_reference.md's
; "Multi-dimensional arrays (archived)" section — back to a single
; argument now that only one dimension exists to ask about.) The real
; parse/lookup body lives in EXROM (BASIC_ARRAY_DIMN_EXROM below) —
; moved there whole once multi-dimensional array support (still true
; even after archiving it — see rom/exrom_arrays.asm's own header)
; pushed Home ROM over budget; unlike every other ARGC branch here, it
; does its OWN full parse from EXPR_PARSE_PTR rather than taking pre-
; parsed input, since its argument (the array name) is never evaluated
; as an expression the way a normal function argument would be — see
; EXROM_ENTRY_DIMN's own header (rom/exrom_checker.asm) for why.
.array_name_dim_arg:
    pop  af                              ; discard argc snapshot
    pop  bc                              ; discard handler snapshot — EXROM
                                         ; body below does its own full
                                         ; parse, nothing here needs it
    call BASIC_ARRAY_DIMN_EXROM
    ret  c                               ; error already recorded by
                                         ; BASIC_ARRAY_DIMN_EXROM
    jp   .function_done

; ---- zero-argument functions (FREE) ----
; BASIC_MATCH_FUNCTION_NAME already consumed the name and the opening
; '(', so with no arguments to parse the very next non-space character
; must be the closing ')' — e.g. "FREE()".
.zero_arg:
    ld   hl, (EXPR_PARSE_PTR)
    ld   a, (hl)
    cp   ")"
    jr   nz, .zero_arg_fail
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    pop  af                                      ; discard argc snapshot
    pop  bc                                      ; BC = handler snapshot
    jp   .dispatch                               ; JP not JR — the new
                                                ; ARGC_STR1/STR2 string-
                                                ; argument dispatch
                                                ; block above pushed
                                                ; .dispatch out of JR's
                                                ; range (project's own
                                                ; recurring JR-range
                                                ; lesson)

.zero_arg_fail:
    pop  af
    pop  bc                                      ; discard snapshots
    scf
    ret

; ---- LEN/CODE/VAL (ARGC_STR1 — one string argument), 2026-08-22 ----
; (INSTR/ARGC_STR2 — two string arguments — was here too originally,
; dropped the same day to fit Home ROM's own budget alongside FILL$;
; see FUNC_ID_INSTR's own comment for the full reasoning.)
; Same nested-call hazard as BASIC_EVAL_STR_PRIMARY's own .str_func_
; call (e.g. LEN(UPPER$(A$)) — the string argument here can itself
; contain another string-function call), so the same fix applies: the
; acquired pool-buffer address lives on the real stack across the
; recursive BASIC_EVAL_STR_EXPR call, never in a shared sysvar. Our
; own handler/argc snapshot is already stack-based per this
; routine's own established pattern above — popped back right before
; .dispatch, same as every other branch here.
;
; LEN/CODE are trivial enough to compute directly from the buffer
; (a length-prefixed [len][content...] blob, same shape STR_FUNC_POOL
; slots always hold) without any EXROM round trip. VAL calls through
; BASIC_STRFUNC_EXROM like every other string-function body, STR_FUNC_
; CALL_ID is set to STRFUNC_ID_VAL only when the selected numeric-table
; handler reaches VAL's EXROM transform.
.str_arg_1:
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_PARSE_STR_ARG_TO_POOL     ; HL = buffer address (length
                                         ; prefix already written;
                                         ; releases on its own failure)
    jr   c, .str_arg_pool_fail
    push hl                              ; buffer address, across the
                                         ; ")" check below
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jr   nz, .str_arg_1_grammar_fail
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    pop  hl                              ; HL = buffer address
    pop  af                              ; discard argc snapshot
    pop  bc                              ; BC = handler snapshot
    jp   .dispatch

.str_arg_val:
    ld   a, STRFUNC_ID_VAL
    ld   (STR_FUNC_CALL_ID), a
    call BASIC_STRFUNC_EXROM             ; HL = buffer (in); DE =
                                         ; result (out)
    ex   de, hl                          ; HL = result, matching
                                         ; .dispatch's own tail
                                         ; convention (every case here
                                         ; ends with the result in HL,
                                         ; then .function_done does the
                                         ; final swap into DE)
    jp   .function_done

.str_arg_len:
    ld   a, (hl)                         ; A = length byte — HL still
                                         ; points at the buffer, whose
                                         ; very first byte IS the value
                                         ; LEN wants
    ld   l, a
    ld   h, 0                            ; HL = result
    jp   .function_done

.str_arg_code:
    ld   a, (hl)                         ; length byte
    or   a
    jr   z, .str_arg_code_empty
    inc  hl
    ld   a, (hl)                         ; first content byte
    ld   l, a
    ld   h, 0
    jp   .function_done
.str_arg_code_empty:
    ld   hl, 0
    jp   .function_done

.str_arg_pool_fail:
    pop  af                              ; discard argc snapshot
    pop  bc                              ; discard handler snapshot —
                                         ; nothing else pushed yet
    scf
    ret

.str_arg_1_grammar_fail:
    pop  hl                              ; discard the re-pushed buffer
                                         ; address (BASIC_PARSE_STR_
                                         ; ARG_TO_POOL's own failure
                                         ; already released it on ITS
                                         ; OWN failure paths — this one
                                         ; only covers a grammar check
                                         ; AFTER a successful parse)
    call STR_FUNC_POOL_RELEASE
    pop  af
    pop  bc                              ; discard snapshots
    scf
    ret

.call_attr:
    ; ATTR(row,col) reads the normal 32x24 attribute grid. Invalid
    ; coordinates return 0, matching POINT's deliberately forgiving
    ; screen-query behavior and keeping static checking value-agnostic.
    ld   a, h
    or   d
    jr   nz, .attr_zero
    ld   b, l
    ld   c, e
    call GFX_CELL_ATTR_ADDR
    jr   c, .attr_zero
    ld   a, (hl)
    ld   l, a
    ld   h, 0
    jp   .function_done
.attr_zero:
    ld   hl, 0
    jp   .function_done

.dispatch:
    ; Cleared here, unconditionally, before any of the cases below run
    ; — one shared reset point rather than one per case, since every
    ; case EXCEPT SQR/SIN is a genuine integer result (see FUNC_RESULT_
    ; IS_FLOAT's own sysvars.inc comment for the full "function-result
    ; float" design). This also correctly resets state left over from
    ; a NESTED float-producing call in one of THIS function's own
    ; arguments — e.g. MOD(SQR(2),3): SQR's inner dispatch sets the
    ; flag, but MOD's own dispatch (reached right here, after both
    ; arguments are already parsed) clears it right back to 0, since
    ; MOD's result is genuinely an integer regardless of what its
    ; arguments were.
    xor  a
    ld   (FUNC_RESULT_IS_FLOAT), a
    push bc                                    ; synthetic indirect call:
    ret                                        ; each handler converges on
                                               ; .function_done
                                              ; falling through
.call_abs:
    call MATH_ABS16
    jp   .function_done                        ; JP not JR — STICK's
                                              ; new check-only guard
                                              ; pushed .function_done
                                              ; out of JR's range
                                              ; (project's own
                                              ; recurring JR-range
                                              ; lesson)
.call_sgn:
    call MATH_SGN16
    jp   .function_done
.call_mod:
    call MATH_MOD16
    jr   .function_done
.call_sqr:
    call BASIC_SQR_FLOAT
    jr   .function_done
.call_div:
    call MATH_DIVIDE16                         ; same HL=dividend/
                                              ; DE=divisor contract as
                                              ; MOD's own call above —
                                              ; the two-argument parsing
                                              ; path already leaves HL/
                                              ; DE in exactly that shape
    jr   .function_done
.call_int:
                                              ; true no-op: this is a
                                              ; pure-integer BASIC, so
                                              ; every value is already
                                              ; its own INT() — HL
                                              ; already holds the
                                              ; argument, nothing to do
                                              ; (kept as its own table
                                              ; entry/dispatch case for
                                              ; SuperBASIC-syntax
                                              ; compatibility, not
                                              ; because it computes
                                              ; anything)
    jr   .function_done
.call_rnd:
    call MATH_RND16
    jr   .function_done
.call_point:
    ; GFX_READ_PIXEL's own contract is B/C=x/y -> A=0/1, not the
    ; HL/DE-in convention every MATH_* function above shares — POINT
    ; is the first built-in that isn't itself a MATH_* routine, so
    ; this is a small adapter, not a sign the dispatch convention is
    ; wrong.
    ; Y is clamped the same way PLOT/LINE/AT clamp it (192 pixels
    ; tall, not a power of 2) rather than left to silently index past
    ; ROW_BASE_TABLE.
    ld   b, l                      ; B = x (low byte; x's full 0-255
                                  ; range is already the whole valid
                                  ; screen width, no clamp needed)
    ld   a, e
    cp   192
    jr   c, .point_y_ok
    ld   a, 191
.point_y_ok:
    ld   c, a                      ; C = y (clamped)
    call GFX_READ_PIXEL            ; A = 0 or 1
    ld   l, a
    ld   h, 0
    jr   .function_done
.call_peek:
    ; HL = address (the one-argument path above already puts it there).
    ; Reads raw memory directly — deliberately NOT routed through a
    ; kernel/ API: unlike every other built-in here, the address is
    ; arbitrary, caller-supplied data, not a specific piece of kernel-
    ; owned hardware/sysvar state, so there's no hardware behavior to
    ; abstract (same reasoning as POKE and USR below).
    ld   a, (hl)
    ld   l, a
    ld   h, 0
    jr   .function_done
.call_free:
    call MEM_FREE_BYTES            ; -> HL = free bytes in the program area
    jr   .function_done
.call_usr:
    ; HL = address (one-argument path). Tail-calls into it via BASIC_
    ; CALL_USR's own "jp (hl)" — the user's machine code is expected to
    ; end with its own RET, result in HL, same CALL/USR convention real
    ; Sinclair BASIC uses. Genuinely a `call`, not a `jr`/`jp`: this
    ; dispatch chain was itself reached via jr/jp (not call), so the
    ; return address BASIC_CALL_USR's own `call` pushes is what makes
    ; the user routine's RET land back here instead of miles away in
    ; BASIC_EVAL_PRIMARY's original, unrelated caller.
    ;
    ; GUARDED: BASIC_EVAL_EXPR is also the exact routine the whole-
    ; program/live-typing checker uses to validate a statement's syntax
    ; WITHOUT really running it (BASIC_CHECK_ASSIGNMENT -> BASIC_EVAL_
    ; EXPR on the RHS) — every other built-in here is genuinely side-
    ; effect-free, so that's always been safe, but USR is a real jump
    ; to a real address. Unguarded, checking (not running) something
    ; like "X = USR(0)" would jump to address 0 — this ROM's own RST_00
    ; vector — restarting the machine from inside the checker's own
    ; call chain (confirmed: a real infinite-boot-loop hang in a
    ; throwaway smoke-test harness before this guard existed). BASIC_
    ; CHECK_ONLY is set only by the two EXROM checker wrapper routines
    ; (BASIC_FULL_CHECK_EXROM, BASIC_CHECK_STATEMENT_EXROM — see their
    ; own comments), never during real execution, so this skips the
    ; jump and returns a harmless 0 only when this expression is being
    ; checked, not run.
    ld   a, (BASIC_CHECK_ONLY)
    or   a
    jr   nz, .usr_checking_only
    call BASIC_CALL_USR
    jr   .function_done
.usr_checking_only:
    ld   hl, 0
    jr   .function_done
.call_sin:
    call BASIC_SIN_FLOAT
    jr   .function_done
.call_pi:
    call BASIC_PI_FLOAT
    jr   .function_done
.call_rad:
    call BASIC_RAD_FLOAT
    jr   .function_done
.call_deg:
    call BASIC_DEG_FLOAT
    jr   .function_done
.call_stick:
    ; STICK(device) — device must be 1 or 2 (two joystick ports),
    ; confirmed from the real ROM disassembly's own STICK command
    ; routine (M28F8/READ-STICK/TEST-STICK-ARG): out-of-range raises
    ; the real ROM's own REPORT-A ("Invalid argument"), reused here as
    ; MSG_INVALID_ARGUMENT. HL holds the parsed argument (this one-arg
    ; call site's own convention, same as ABS/SGN/SQR above).
    ;
    ; REAL BUG FOUND AND FIXED (2026-08-22): the first draft validated
    ; unconditionally, with no BASIC_CHECK_ONLY guard — this routine
    ; (via BASIC_EVAL_EXPR's own call chain) is also what the whole-
    ; program checker uses to validate expression grammar, and for a
    ; VARIABLE argument (e.g. "N = 1: PRINT STICK(N)") the check pass
    ; reads N's CURRENT VAR_TABLE value, not whatever it will actually
    ; hold once the preceding assignment has really run — check-time
    ; assignment is deliberately non-mutating (BASIC_CHECK_ASSIGNMENT's
    ; own header), so N could read as anything at that point. A
    ; perfectly valid program was failing the check outright. Unlike
    ; USR/array-reads, this one isn't a crash risk, just a false
    ; positive — but the fix is the same: skip real validation when
    ; checking, matching this project's established guard exactly.
    ld   a, (BASIC_CHECK_ONLY)
    or   a
    jr   nz, .stick_checking_only
    ld   a, h
    or   a
    jr   nz, .stick_bad_arg              ; high byte nonzero -> can't
                                         ; be 1 or 2 either way
    ld   a, l
    cp   1
    jr   z, .stick_read
    cp   2
    jr   nz, .stick_bad_arg
.stick_read:
    call STICK_READ                      ; HL = device (1 or 2) in,
                                         ; HL = stick value out — see
                                         ; kernel/io's own header
    jr   .function_done
.stick_checking_only:
    ld   hl, 0
    jr   .function_done
.stick_bad_arg:
    ld   hl, MSG_INVALID_ARGUMENT
    call BASIC_SET_PENDING_ERROR
    scf
    ret

.call_hit:
    ; HIT(slot1,slot2) — HL/DE already hold the two parsed arguments,
    ; the same 2-numeric-argument shape MOD/DIV/POINT above all share.
    ; No BASIC_CHECK_ONLY guard needed (unlike STICK above): the real
    ; body only ever READS sprite state (never mutates anything BASIC-
    ; visible), and gracefully treats any invalid/not-shown slot as
    ; "no collision" rather than erroring — see BASIC_SPRITE_HIT's own
    ; header (rom/exrom_sprite.asm) for why that's safe to run
    ; unconditionally even during a whole-program check pass.
    call BASIC_SPRITE_HIT_EXROM
    jr   .function_done

.function_done:
    ex   de, hl                                ; DE = result, matching
                                              ; every other
                                              ; BASIC_EVAL_PRIMARY exit
    ld   hl, (EXPR_PARSE_PTR)
    or   a
    ret

.do_number:
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_PARSE_NUMBER                ; DE = value, HL = advanced
                                          ; (its own leading-'-' handling
                                          ; never triggers here, since
                                          ; BASIC_EVAL_FACTOR already
                                          ; intercepts unary minus
                                          ; before this is ever reached
                                          ; with one)
    ld   (EXPR_PARSE_PTR), hl
    or   a
    ret

.do_paren:
    ld   hl, (EXPR_PARSE_PTR)
    inc  hl                                ; skip '('
    call BASIC_EVAL_EXPR                     ; recursive call — sets its
                                            ; own EXPR_PARSE_PTR = HL
                                            ; internally, consistent
    ret  c                                    ; propagate failure
                                              ; (unclosed/malformed)

    ld   a, (hl)                               ; HL = position right
    cp   ")"                                     ; after the inner
    jr   nz, .fail                                ; expression — expect
    inc  hl                                         ; the closing paren
    ld   (EXPR_PARSE_PTR), hl
    or   a
    ret

.fail:
    scf
    ret

; ============================================================================
; BASIC_CALL_USR
; Tail-jumps into a machine-code routine at an arbitrary, BASIC-supplied
; address — USR's whole job. Deliberately its own tiny routine rather
; than an inline `jp (hl)` at the USR call site: `call BASIC_CALL_USR`
; pushes a real return address (right after that call, in BASIC_EVAL_
; PRIMARY's .call_usr), so the user routine's own closing RET returns
; THERE — not to whatever unrelated address happened to be on the stack
; at BASIC_EVAL_PRIMARY's entry — letting normal expression evaluation
; (DE = result, EXPR_PARSE_PTR bookkeeping) continue exactly as it does
; for every other built-in function.
; In:  HL = address to call
; Out: whatever the user routine leaves — by convention, HL = result
; Destroys: whatever the user routine destroys
; ============================================================================
BASIC_CALL_USR:
    jp   (hl)

; ============================================================================
; BASIC_SQR_FLOAT
; SQR's new "function-result float" body (replaces the old plain `call
; MATH_SQRT16`, 2026-08-22 — see FUNC_RESULT_IS_FLOAT's own sysvars.inc
; comment for why SQR specifically needed this and most of the other
; built-ins didn't). MATH_SQRT16's floor(sqrt(n)) is usually wrong —
; SQR(2) genuinely is 1.4142..., not 1 — so this refines that same
; floor value with 4 Newton-Raphson iterations in float space
; (x_{k+1} = (x_k + n/x_k)/2), starting from MATH_SQRT16's own result
; as the initial guess (already within 1 of the true answer, a good
; seed — reuses kernel/math's existing verified work rather than
; deriving a guess from scratch).
;
; Iteration count chosen by exhaustive Python check (n = 1..49999):
; 3 iterations left a worst case (n=3) off by ~9e-5 — enough to flip
; the 4th displayed decimal digit (1.7321 vs the true 1.7320); 4
; iterations brought the worst case down to ~2e-9, safely below what
; 4 displayed digits can show. Every iteration is exactly the sequence
; DUPLICATE / push n / EXCHANGE+DIVIDE / ADD / push 2 / DIVIDE — see
; each rst $28 block below for why EXCHANGE is needed at all (CALC_
; STK_PNTRS_BINARY's own OP1=first(lower)/OP2=second(top) convention
; means pushing n after duplicating x_k leaves x_k as OP2 and n as
; OP1, i.e. x_k/n — backwards from the n/x_k this needs — so the pair
; is swapped immediately before dividing).
;
; In:  HL = n (signed; negative treated as 0, same contract as MATH_
;      SQRT16 itself — refinement is skipped entirely for n<=0, since
;      0 needs no Newton refinement and dividing by an x_k of 0 would
;      hang the very first iteration)
; Out: HL = truncated-toward-zero int (same shape MATH_SQRT16 used to
;      return, for BASIC_EVAL_PRIMARY's normal integer-composition
;      path). FUNC_RESULT_FLOAT/FUNC_RESULT_IS_FLOAT set for
;      BASIC_STMT_PRINT's own float-print path — see that sysvar's
;      own comment.
; Destroys: AF, BC, DE, HL.
; ============================================================================
BASIC_SQR_FLOAT:
    ld   (SQR_ARG_N), hl
    call MATH_SQRT16              ; HL = floor(sqrt(n)) — 0 for n<=0
    ld   a, h
    or   l
    jr   z, .sqr_zero              ; n<=0 — sqrt is exactly 0, no
                                   ; refinement needed or safe to run
    call CALC_INT_TO_FP_HOME       ; push initial guess x_0: [x_0]

    ld   b, 4                      ; 4 Newton iterations
.sqr_loop:
    push bc
    rst  $28
    DB   $31, $38                   ; duplicate: [x_k, x_k]
    ld   hl, (SQR_ARG_N)
    call CALC_INT_TO_FP_HOME        ; push n: [x_k, x_k, n]
    rst  $28
    DB   $01, $05, $38                ; exchange, divide: exchange makes
                                     ; the pair [n(OP1/lower), x_k(OP2/
                                     ; top)], divide -> n/x_k; stack:
                                     ; [x_k, n/x_k]
    rst  $28
    DB   $0F, $38                     ; add: x_k + n/x_k; stack: [sum]
    ld   hl, 2
    call CALC_INT_TO_FP_HOME          ; push 2: [sum, 2]
    rst  $28
    DB   $05, $38                      ; divide: sum/2 = new x_k;
                                       ; stack: [x_k]
    pop  bc
    djnz .sqr_loop

    ; stack: [x_k] (the refined result) — same duplicate/peek/truncate
    ; shape BASIC_FINISH_FLOAT_RESULT already does (RAD/DEG/SIN/PI all
    ; share it too — see that routine's own header); called rather than
    ; jumped to since SQR still needs its own extra step after
    call BASIC_FINISH_FLOAT_RESULT
    xor  a
    ld   (FUNC_RESULT_FLOAT_NEGATIVE), a   ; sqrt is never negative
    ret

.sqr_zero:
    ; REAL BUG FOUND AND FIXED (caught by this project's own visual
    ; smoke test, rom/test_sqr_sin_visual.asm: SQR(0) and SQR(-5) both
    ; showed a leftover value from whatever the PREVIOUS float result
    ; happened to be — "7424.0000" in that run — instead of 0.0000).
    ; byte0=0 is the packed float format's small-int-form MARKER, not
    ; "zero" by itself (see rom/exrom_calc.asm's CALC_UNPACK header) —
    ; the actual value still depends on bytes 1-3 (sign/low/high), so
    ; writing only byte0 left FUNC_RESULT_FLOAT's stale bytes 1-4 from
    ; a previous call intact and got interpreted as THEIR small-int
    ; value. Fixed by using CALC_INT_TO_FP_HOME(0) — the same boundary
    ; converter every other genuine int constant in this file already
    ; goes through — rather than hand-encoding the zero record here.
    ld   hl, 0
    call CALC_INT_TO_FP_HOME
    ld   hl, FUNC_RESULT_FLOAT
    call CALC_PEEK_TOP_AND_POP
    ld   a, 1
    ld   (FUNC_RESULT_IS_FLOAT), a
    xor  a
    ld   (FUNC_RESULT_FLOAT_NEGATIVE), a
    ld   hl, 0
    ret

; ============================================================================
; BASIC_SIN_FLOAT
; SIN's body — this project's first transcendental function. Takes
; DEGREES (not radians): with no float literal syntax anywhere in this
; BASIC, a caller can only ever pass a plain integer, and an integer
; number of radians is nearly useless (SIN(1) would be ~0.84, SIN(2)
; ~0.91, with no way to reach anything near a recognizable angle like
; pi/2) where an integer number of DEGREES covers exactly the values
; this dialect can actually express. A deliberate deviation from real
; Sinclair BASIC's own radians-based SIN, not an oversight.
;
; Algorithm: reduce to a reference angle in [0,90] degrees (using
; sin(x)=sin(180-x) and sin(-x)=-sin(x), tracking the true sign
; separately in FUNC_RESULT_FLOAT_NEGATIVE — the actual float value
; this computes is always >= 0, matching BASIC_FLOAT_TO_STRING's own
; sign-agnostic contract), convert to radians (via CALC_PUSH_PI —
; rom/exrom_calc.asm — since pi isn't a plain int CALC_INT_TO_FP could
; push), then a 5-term Maclaurin series (x - x^3/6 + x^5/120 -
; x^7/5040 + x^9/362880), computed via the sign-free recurrence
; power_k = power_{k-1} * x^2 / D_k (D_k = 6,20,42,72 for k=1..4 —
; see SIN_POWER's own sysvars.inc comment for why the recurrence form
; is used instead of the factorials directly: 9! = 362880 doesn't fit
; a 16-bit int, but every D_k does), alternating subtract/add into the
; running sum.
;
; Accuracy verified in Python across every integer degree in [-720,
; 720]: 5 terms' worst case is ~3.5e-6, safely inside what 4 displayed
; decimal digits can show (4 terms alone left SIN(90) displaying
; 0.9998 instead of the exact 1.0000 — the very first thing anyone
; would try — so the series was extended one more term specifically to
; get that case right).
;
; In:  HL = degrees (signed 16-bit)
; Out: HL = truncated-toward-zero int (-1, 0, or 1 for nearly every
;      integer-degree input — SIN's own genuinely useful result only
;      shows up through PRINT's float path, same "integer core"
;      reasoning as every other function-result-float case).
;      FUNC_RESULT_FLOAT/_NEGATIVE/FUNC_RESULT_IS_FLOAT set for
;      BASIC_STMT_PRINT's float-print path.
; Destroys: AF, BC, DE, HL.
; ============================================================================
BASIC_SIN_FLOAT:
    ; ---- reduce to a reference angle in [0,90], track the sign ----
    ex   de, hl                    ; DE = degrees (MATH_MOD16's own
                                  ; HL=dividend/DE=divisor contract
                                  ; needs the CONSTANT, 360, in DE... )
    ld   hl, 360
    ex   de, hl                     ; ... so put it back: HL=degrees,
                                   ; DE=360 (MATH_MOD16 In: HL=
                                   ; dividend, DE=divisor)
    call MATH_MOD16                 ; HL = degrees mod 360, sign of the
                                   ; dividend (kernel/math's own
                                   ; documented truncating-mod
                                   ; convention) — range (-359,359)
    xor  a
    ld   (FUNC_RESULT_FLOAT_NEGATIVE), a
    ld   a, h
    or   a
    jp   p, .sin_nonneg
    ; negative — negate it and remember the sign
    ld   a, 1
    ld   (FUNC_RESULT_FLOAT_NEGATIVE), a
    ld   a, h
    cpl
    ld   h, a
    ld   a, l
    cpl
    ld   l, a
    inc  hl
.sin_nonneg:
    ; HL = |degrees mod 360|, in [0,359]; fold [180,359] down using
    ; sin(x+180) = -sin(x)
    ld   a, h
    or   a
    jr   nz, .sin_ge180              ; H nonzero only possible if
                                     ; HL>=256, definitely >=180
    ld   a, l
    cp   180
    jr   c, .sin_lt180
.sin_ge180:
    ld   de, 180
    or   a
    sbc  hl, de
    ld   a, (FUNC_RESULT_FLOAT_NEGATIVE)
    xor  1
    ld   (FUNC_RESULT_FLOAT_NEGATIVE), a   ; flip the sign
.sin_lt180:
    ; HL in [0,179]; fold (90,179] down using sin(180-x)=sin(x) —
    ; equivalently, sin(x) for x in (90,179] equals sin(179-x+1)...
    ; simpler: reference = x if x<=90 else 180-x
    ld   a, l
    cp   91
    jr   c, .sin_ref_done             ; H already known 0 here (HL<180)
    ld   de, 180
    ex   de, hl
    or   a
    sbc  hl, de                        ; HL = -(x-180) = 180-x... need
                                       ; DE-HL not HL-DE
    ; the sbc above computed DE-HL-old_carry with operands swapped by
    ; the ex — i.e. this HL = 180 - x, exactly the reference angle
.sin_ref_done:
    ; HL = reference angle in [0,90] degrees. A reference angle of
    ; exactly 0 means the true result is exactly 0 regardless of which
    ; fold got it there (degrees mod 360 landing on 0 or 180 both fold
    ; to a 0 reference angle) — 0 has no sign, so force the flag back
    ; off here rather than let a fold that flipped it produce a
    ; cosmetic "-0.0000" (caught by this project's own visual smoke
    ; test on SIN(180)).
    ld   a, h
    or   l
    jr   nz, .sin_ref_nonzero
    xor  a
    ld   (FUNC_RESULT_FLOAT_NEGATIVE), a
.sin_ref_nonzero:

    ; ---- degrees -> radians: x_rad = degrees * pi / 180 ----
    call CALC_INT_TO_FP_HOME        ; push degrees: [d]
    call CALC_PUSH_PI_HOME          ; push pi: [d, pi]
    rst  $28
    DB   $04, $38                     ; multiply: d*pi; stack: [d*pi]
    ld   hl, 180
    call CALC_INT_TO_FP_HOME          ; push 180: [d*pi, 180]
    rst  $28
    DB   $05, $38                      ; divide: x_rad; stack: [x_rad]
    ld   hl, FUNC_RESULT_FLOAT          ; reuse this buffer as scratch
                                       ; before it holds the real
                                       ; result — nothing has set the
                                       ; real result yet at this point
    call CALC_PEEK_TOP_AND_POP          ; copies top to (HL), CALC_SP-1
    ld   hl, FUNC_RESULT_FLOAT
    ld   de, SIN_X_RAD
    ld   bc, 5
    ldir                                ; SIN_X_RAD = x_rad

    ; ---- x2 = x_rad * x_rad, cached for every term below ----
    ld   hl, SIN_X_RAD
    call CALC_PUSH_FP_RAW_HOME         ; push x_rad: [x_rad]
    ld   hl, SIN_X_RAD
    call CALC_PUSH_FP_RAW_HOME         ; push x_rad again: [x_rad,x_rad]
    rst  $28
    DB   $04, $38                       ; multiply: x2; stack: [x2]
    ld   hl, FUNC_RESULT_FLOAT
    call CALC_PEEK_TOP_AND_POP
    ld   hl, FUNC_RESULT_FLOAT
    ld   de, SIN_X2
    ld   bc, 5
    ldir                                ; SIN_X2 = x_rad^2

    ; ---- acc = x_rad (term_0); power = x_rad ----
    ld   hl, SIN_X_RAD
    ld   de, SIN_POWER
    ld   bc, 5
    ldir                                ; SIN_POWER = x_rad (term_0's
                                       ; magnitude, before any of the
                                       ; loop's own divides touch it)
    ld   hl, SIN_X_RAD
    call CALC_PUSH_FP_RAW_HOME          ; push term_0 as the running
                                       ; sum's starting value: [acc]

    ; ---- 4 more terms: power *= x2 / D_k; acc -= power (k odd) or
    ; acc += power (k even) ----
    ld   hl, SIN_DIVISOR_TABLE
    ld   b, 4
.sin_term_loop:
    push bc
    push hl                             ; save divisor-table pointer
    ld   hl, SIN_POWER
    call CALC_PUSH_FP_RAW_HOME           ; push power: [acc, power]
    ld   hl, SIN_X2
    call CALC_PUSH_FP_RAW_HOME           ; push x2: [acc, power, x2]
    rst  $28
    DB   $04, $38                         ; multiply: power*x2;
                                         ; stack: [acc, power*x2]
    pop  hl                              ; HL = divisor-table pointer
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    inc  hl
    push hl                              ; save advanced table pointer
    ex   de, hl                          ; HL = this term's D_k
    call CALC_INT_TO_FP_HOME              ; push D_k:
                                         ; [acc, power*x2, D_k]
    rst  $28
    DB   $05, $38                          ; divide: new power;
                                          ; stack: [acc, power]
    ld   hl, FUNC_RESULT_FLOAT
    call CALC_PEEK_TOP_AND_POP             ; stack: [acc]
    ld   hl, FUNC_RESULT_FLOAT
    ld   de, SIN_POWER
    ld   bc, 5
    ldir                                    ; SIN_POWER = new power

    ld   hl, SIN_POWER
    call CALC_PUSH_FP_RAW_HOME              ; push power again:
                                           ; [acc, power]
    pop  hl                                ; HL = advanced table ptr
    pop  bc                                ; BC = loop counter (B)
    push hl
    push bc
    ld   a, b
    and  1
    ; B is the countdown loop counter (4,3,2,1 across passes k=1,2,3,4
    ; respectively — djnz decrements it at the BOTTOM of the loop, so
    ; during pass k it still holds its pre-decrement value), NOT k
    ; itself — B is even exactly when k is odd (k=1->B=4, k=3->B=2)
    ; and odd exactly when k is even (k=2->B=3, k=4->B=1). Term k is
    ; subtracted for odd k, added for even k (see this routine's own
    ; header), so B-even means SUBTRACT here, not add — inverted from
    ; what a first pass at this got wrong; caught by this project's own
    ; visual smoke test (SIN(90) showing 2.1415 instead of 1.0000,
    ; SIN(30) showing 0.5471 instead of 0.5000 — every term past the
    ; first was landing with the wrong sign).
    jr   z, .sin_term_sub
    rst  $28
    DB   $0F, $38                            ; add (even k):
                                             ; acc+power; stack: [acc]
    jr   .sin_term_combined
.sin_term_sub:
    rst  $28
    DB   $03, $38                             ; subtract (odd k):
                                              ; acc-power; stack: [acc]
.sin_term_combined:
    pop  bc
    pop  hl
    djnz .sin_term_loop

    ; stack: [acc] — the reference angle's non-negative sine. Same
    ; duplicate/peek/truncate shape BASIC_FINISH_FLOAT_RESULT already
    ; does (RAD/DEG/SQR/PI all share it too) — tail-called since
    ; nothing more happens after here.
    jr   BASIC_FINISH_FLOAT_RESULT

SIN_DIVISOR_TABLE: DW 6, 20, 42, 72

; ============================================================================
; BASIC_PI_FLOAT
; PI()'s body — the simplest possible "function-result float" case
; (SQR_FLOAT/SIN_FLOAT's own header): no computation at all, just
; expose the calculator engine's already-existing PI_CONST (rom/
; exrom_calc.asm, pushed via CALC_PUSH_PI_HOME — built earlier for
; SIN's own degrees->radians conversion above) as a BASIC value. Same
; zero-argument shape as FREE() — see BASIC_EVAL_PRIMARY's own
; .do_function_call .zero_arg branch.
; In:  none
; Out: HL = 3 (truncated int fallback for a composed expression);
;      FUNC_RESULT_FLOAT/FUNC_RESULT_IS_FLOAT set for BASIC_STMT_
;      PRINT's own float-display branch to show 3.1416 instead, when
;      PI() is the ENTIRE printed expression (see that branch's own
;      header)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_PI_FLOAT:
    call CALC_PUSH_PI_HOME          ; push pi: [pi]
    call BASIC_FINISH_FLOAT_RESULT    ; same shared duplicate/peek/
                                      ; truncate shape RAD/DEG/SQR/SIN
                                      ; all use too
    xor  a
    ld   (FUNC_RESULT_FLOAT_NEGATIVE), a   ; pi is never negative
    ret

; ============================================================================
; BASIC_RAD_FLOAT / BASIC_DEG_FLOAT
; RAD(x) converts degrees->radians (x_rad = x*pi/180); DEG(x) converts
; radians->degrees (x_deg = x*180/pi) — the exact inverse formula, same
; multiply/divide pair as BASIC_SIN_FLOAT's own degrees->radians step
; above, just factored out as its own callable value instead of
; feeding straight into a Taylor series. Sign handling matches BASIC_
; SQR_FLOAT/BASIC_SIN_FLOAT's own convention exactly: extract the
; input's sign in the INTEGER domain first (so every calculator-engine
; operation below only ever sees a non-negative magnitude — BASIC_
; FLOAT_TO_STRING's own contract requires that), track it separately
; in FUNC_RESULT_FLOAT_NEGATIVE, and — same as SIN's own truncated-int
; fallback — do NOT re-apply the sign to the truncated-int HL result;
; a composed expression like "RAD(-90)+1" losing the sign in its int
; fallback is the same accepted, documented simplification SIN(-30)
; already has (see BASIC_STMT_PRINT's "function-result float" comment).
; In:  HL = x (signed 16-bit int; RAD's degrees, or DEG's radians)
; Out: HL = truncated int (magnitude only, see above);
;      FUNC_RESULT_FLOAT/_NEGATIVE/FUNC_RESULT_IS_FLOAT set for
;      BASIC_STMT_PRINT's own float-display branch
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_RAD_FLOAT:
    call BASIC_EXTRACT_SIGN            ; HL = |x|, FUNC_RESULT_FLOAT_
                                       ; NEGATIVE set
    call CALC_INT_TO_FP_HOME           ; push |x|: [d]
    call CALC_PUSH_PI_HOME             ; push pi: [d, pi]
    rst  $28
    DB   $04, $38                       ; multiply: [d*pi]
    ld   hl, 180
    call CALC_INT_TO_FP_HOME            ; push 180: [d*pi, 180]
    rst  $28
    DB   $05, $38                        ; divide: [x_rad]
    jr   BASIC_FINISH_FLOAT_RESULT

BASIC_DEG_FLOAT:
    call BASIC_EXTRACT_SIGN            ; HL = |x|, FUNC_RESULT_FLOAT_
                                       ; NEGATIVE set
    call CALC_INT_TO_FP_HOME           ; push |x|: [r]
    ld   hl, 180
    call CALC_INT_TO_FP_HOME            ; push 180: [r, 180]
    rst  $28
    DB   $04, $38                        ; multiply: [r*180]
    call CALC_PUSH_PI_HOME               ; push pi: [r*180, pi]
    rst  $28
    DB   $05, $38                         ; divide: [x_deg]
    jr   BASIC_FINISH_FLOAT_RESULT

; ============================================================================
; BASIC_EXTRACT_SIGN
; Shared first step for BASIC_RAD_FLOAT/BASIC_DEG_FLOAT: negates HL if
; negative and records that in FUNC_RESULT_FLOAT_NEGATIVE, else clears
; the flag — same inline sequence BASIC_SIN_FLOAT's own reference-angle
; reduction already does, factored out since RAD/DEG both need exactly
; this and nothing more (no angle-folding — that was SIN's own Taylor-
; series range optimization, not a signedness requirement).
; In:  HL = signed 16-bit int
; Out: HL = |input|; FUNC_RESULT_FLOAT_NEGATIVE = 1 if input was
;      negative, else 0
; Destroys: AF
; ============================================================================
BASIC_EXTRACT_SIGN:
    xor  a
    ld   (FUNC_RESULT_FLOAT_NEGATIVE), a
    ld   a, h
    or   a
    ret  p                              ; non-negative — nothing to do
    ld   a, 1
    ld   (FUNC_RESULT_FLOAT_NEGATIVE), a
    ld   a, h
    cpl
    ld   h, a
    ld   a, l
    cpl
    ld   l, a
    inc  hl
    ret

; ============================================================================
; BASIC_FINISH_FLOAT_RESULT
; Shared tail for BASIC_RAD_FLOAT/BASIC_DEG_FLOAT: stack top is the
; final (non-negative) float result — duplicate it, peek one copy into
; FUNC_RESULT_FLOAT, truncate the other into HL, set FUNC_RESULT_IS_
; FLOAT. Same three-step shape BASIC_SQR_FLOAT/BASIC_SIN_FLOAT's own
; final steps use, factored out since RAD/DEG share it byte-for-byte.
; In:  CALC_STACK top = one packed float, v >= 0 (CALC_SP > 0)
; Out: HL = truncated int; FUNC_RESULT_FLOAT = v; FUNC_RESULT_IS_FLOAT
;      = 1. FUNC_RESULT_FLOAT_NEGATIVE already set by BASIC_EXTRACT_
;      SIGN, untouched here.
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_FINISH_FLOAT_RESULT:
    rst  $28
    DB   $31, $38                        ; duplicate: [v, v]
    ld   hl, FUNC_RESULT_FLOAT
    call CALC_PEEK_TOP_AND_POP            ; FUNC_RESULT_FLOAT = v;
                                         ; stack back to [v]
    call CALC_FP_TO_INT_HOME              ; HL = truncated int; pops [v]
    ld   a, 1
    ld   (FUNC_RESULT_IS_FLOAT), a
    ret

; ============================================================================
; CALC_PEEK_TOP_AND_POP
; Shared scratch-copy step used throughout BASIC_SQR_FLOAT/BASIC_SIN_
; FLOAT above: copies CALC_STACK's current top slot to a Home buffer
; and pops it, all without an EXROM call — CALC_STACK/CALC_SP are
; plain RAM, readable and writable regardless of EXROM's paging state,
; the same reasoning BASIC_SQR_FLOAT's own inline copy uses (this
; routine just factors that same handful of lines out for SIN's many
; call sites instead of repeating them each time).
; In:  HL = destination buffer (5 bytes)
; Out: CALC_SP decremented by 1; *HL = the popped float
; Destroys: AF, BC, DE, HL.
; ============================================================================
CALC_PEEK_TOP_AND_POP:
    ex   de, hl                     ; de = destination (caller's arg)
    ld   a, (CALC_SP)
    dec  a
    ld   (CALC_SP), a
    ld   c, a
    ld   b, 0                        ; bc = popped slot's index
    ld   h, b
    ld   l, c                        ; hl = index
    add  hl, hl
    add  hl, hl                      ; hl = index*4
    add  hl, bc                      ; hl = index*5
    ld   bc, CALC_STACK
    add  hl, bc                      ; hl = popped slot's address
    ld   bc, 5
    ldir                              ; (de)=(hl) x5 — copies the
                                     ; popped float to the caller's
                                     ; destination buffer
    ret

; ============================================================================
; BASIC_EVAL_CONDITION / BASIC_EVAL_OR / BASIC_EVAL_AND / BASIC_EVAL_NOT /
; BASIC_EVAL_COMPARISON
;
; Boolean-condition grammar, layered directly on top of
; BASIC_EVAL_EXPR's arithmetic (same precedence-climbing shape, one
; level per tier, sharing EXPR_PARSE_PTR the exact same way the
; arithmetic levels already do — a boolean value is always represented
; as exactly 0 (false) or 1 (true) in DE, never any other nonzero
; value, so every combining step below can test it with a plain "OR A/
; OR E" rather than a full comparison):
;   condition  := or_expr
;   or_expr    := and_expr (OR and_expr)*
;   and_expr   := not_expr (AND not_expr)*
;   not_expr   := NOT not_expr | comparison
;   comparison := expr [relop expr]
;   relop      := '=' | '<>' | '<=' | '>=' | '<' | '>'
;
; A bare expression with no relop at all (comparison's optional part
; absent) is truthy/falsy the classic-BASIC way: nonzero is true,
; zero is false — this is what lets "IF X THEN" work directly on a
; variable, not just on an explicit comparison.
;
; AND/OR deliberately do NOT short-circuit — both sides are always
; evaluated, matching classic BASIC (and QL SuperBASIC) semantics
; rather than a control-flow short-circuit. A known, accepted
; consequence: "IF Y<>0 AND X/Y>1 THEN" still evaluates X/Y even when
; Y=0, and still raises DIVISION BY ZERO in that case — a real
; limitation, not a bug, and worth remembering if it ever surprises
; future testing.
; ============================================================================
BASIC_EVAL_CONDITION:
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_OR
    ret  c
    ; BASIC_EVAL_EXPR's own established contract is HL-out as well as
    ; DE-out (its header calls it a "drop-in replacement" for
    ; BASIC_PARSE_NUMBER on exactly that basis) — every caller of
    ; BASIC_EVAL_CONDITION (BASIC_STMT_IF, BASIC_RESOLVE_IF_CHAIN's own
    ; ELSEIF check) relies on that same contract to keep parsing
    ; (matching THEN) right where the condition left off. EXPR_PARSE_PTR
    ; itself is always correct on every success path through OR/AND/
    ; NOT/COMPARISON below, but the bare HL REGISTER isn't reloaded on
    ; every one of those paths — reload it once here, at the single
    ; point every successful call funnels through, rather than
    ; auditing/fixing every individual return statement deeper in the
    ; chain
    ld   hl, (EXPR_PARSE_PTR)
    or   a
    ret

; ----------------------------------------------------------------------
BASIC_EVAL_OR:
    call BASIC_EVAL_AND
    ret  c
.loop:
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   (EXPR_PARSE_PTR), hl
    push de                            ; save left boolean across the
                                      ; keyword match below, which
                                      ; needs DE for its own purpose
                                      ; (the reference keyword pointer)
    ld   de, KW_OR
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .no_match
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_AND                  ; DE = right boolean
    jr   c, .fail
    pop  hl                               ; HL = left boolean
    ld   a, h
    or   l
    jr   nz, .set_true
    ld   a, d
    or   e
    jr   z, .set_false
.set_true:
    ld   de, 1
    jr   .loop
.set_false:
    ld   de, 0
    jr   .loop
.no_match:
    pop  de                                ; restore left boolean,
                                          ; unchanged — no OR here
    or   a
    ret
.fail:
    pop  hl                                 ; discard saved left,
                                           ; balance the stack
    scf
    ret

; ----------------------------------------------------------------------
BASIC_EVAL_AND:
    call BASIC_EVAL_NOT
    ret  c
.loop:
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   (EXPR_PARSE_PTR), hl
    push de
    ld   de, KW_AND
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .no_match
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_NOT                    ; DE = right boolean
    jr   c, .fail
    pop  hl                                 ; HL = left boolean
    ld   a, h
    or   l
    jr   z, .set_false                       ; left already false —
                                            ; AND is false regardless
                                            ; of the right side (still
                                            ; evaluated above — see
                                            ; this block's own header
                                            ; note on no short-circuit)
    ld   a, d
    or   e
    jr   z, .set_false
    ld   de, 1
    jr   .loop
.set_false:
    ld   de, 0
    jr   .loop
.no_match:
    pop  de
    or   a
    ret
.fail:
    pop  hl
    scf
    ret

; ----------------------------------------------------------------------
BASIC_EVAL_NOT:
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   (EXPR_PARSE_PTR), hl
    ld   de, KW_NOT
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .no_not
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_NOT                     ; recursive — allows "NOT
                                           ; NOT X" etc, same as
                                           ; unary-minus recursion
                                           ; elsewhere isn't needed but
                                           ; this costs nothing extra
    ret  c
    ld   a, d
    or   e
    jr   z, .negate_to_true
    ld   de, 0
    ret
.negate_to_true:
    ld   de, 1
    ret
.no_not:
    jr   BASIC_EVAL_COMPARISON

; ----------------------------------------------------------------------
; BASIC_EVAL_RHS_AND_COMPARE
; Shared tail for every relop branch in BASIC_EVAL_COMPARISON below:
; evaluates the right-hand expression (EXPR_PARSE_PTR already
; positioned just past the operator), retrieves the left value
; BASIC_EVAL_COMPARISON pushed before it looked for an operator, and
; compares them via MATH_COMPARE16.
;
; A real bug lived here, caught only by single-stepping the actual
; hardware/emulator after exhaustive static/listing-file verification
; found nothing: since this routine is entered via CALL (not a tail
; jump), the CALL itself pushes THIS routine's own return address
; onto the stack BEFORE any of its own code runs — meaning the stack,
; from this routine's own point of view, holds [my own return
; address, the caller's saved left value, ...], not just [the saved
; left value, ...] the way a naive single "pop hl" assumes. A bare
; "pop hl" here was popping the return address itself, corrupting it
; permanently — the eventual "ret" then popped the LEFT VALUE (plain
; data, e.g. a variable's contents) as if it were a return address
; and jumped into garbage. This is why every relational comparison
; (=, <>, <, <=, >, >=) crashed identically regardless of operator,
; operand, or statement position, while PRINT (which never reaches
; this routine) was unaffected the whole time.
; The fix: lift the real return address off the top first, retrieve
; the actual left value now correctly on top, then put the return
; address back before doing anything else — the classic "swap the
; top two stack items" pattern, needed specifically because the
; value being retrieved was pushed by a CALLER, not by this routine
; itself (contrast BASIC_EVAL_OR/_AND above, which push and pop their
; own saved values within their own bodies, with only self-balanced
; calls — pushing and popping their own return address in a matched
; pair — happening in between; this same class of bug does not apply
; to them).
; In:  none (reads EXPR_PARSE_PTR; expects a value already pushed —
;      the left operand — before this is called)
; Out: carry clear + C = MATH_COMPARE16's result (0/1/$FF); carry set
;      on a malformed right-hand expression (stack already balanced
;      either way)
; Destroys: AF, BC, DE, HL
; ----------------------------------------------------------------------
BASIC_EVAL_RHS_AND_COMPARE:
    ; check-asm: allow-early-pop — audited return-address/left-value
    ; stack swap described in this routine's contract above.
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_EVAL_EXPR                    ; DE = right value
    jr   c, .fail
    pop  bc                                  ; BC = MY OWN return
                                            ; address — pushed by the
                                            ; call that invoked this
                                            ; routine, so it sits on
                                            ; TOP of the caller's
                                            ; saved left value; must
                                            ; come off first
    pop  hl                                  ; HL = left value (now
                                            ; correctly on top)
    push bc                                  ; put my own return
                                            ; address back so my own
                                            ; ret below still works
    call MATH_COMPARE16                       ; A = -1/0/1 (kernel/math)
    ld   c, a
    or   a
    ret
.fail:
    pop  bc                                    ; same reordering as
                                              ; the success path above
                                              ; — my own return
                                              ; address is on top,
                                              ; the caller's saved
                                              ; left value sits
                                              ; beneath it
    pop  hl                                    ; discard saved left,
                                              ; balance the stack —
                                              ; value itself unused
    push bc                                     ; restore my own
                                               ; return address
    scf
    ret

; ----------------------------------------------------------------------
BASIC_EVAL_COMPARISON:
    ld   hl, (EXPR_PARSE_PTR)
    ; peek for a string primary (quote or letter+$) before committing
    ; to the numeric path — non-destructive: BASIC_VALIDATE_VAR_LETTER
    ; only touches AF, and the inc/dec hl pair around it cancels out,
    ; so HL is still exactly EXPR_PARSE_PTR's value either way
    ld   a, (hl)
    cp   '"'
    jp   z, .string_path               ; JP, not JR — .string_path is
                                       ; too far away for JR's range
    call BASIC_VALIDATE_VAR_LETTER
    jr   c, .maybe_str_func            ; not a letter at all — could
                                       ; still be a string-function
                                       ; call name (UPPER$, CHR$, ...),
                                       ; which never looks like a bare
                                       ; letter+$ the check below wants
    inc  hl
    ld   a, (hl)
    dec  hl
    cp   '$'
    jp   z, .string_path               ; JP, same reasoning

.maybe_str_func:
    ; Peek only — BASIC_TRY_EVAL_STR_FUNCTION leaves HL/EXPR_PARSE_PTR
    ; untouched on failure (falls straight to .numeric_path exactly as
    ; before), but DOES advance them on a match, which we don't want
    ; here: .string_path's own BASIC_EVAL_STR_EXPR call expects to
    ; parse the WHOLE expression fresh, so the original entry position
    ; is stashed and restored before handing off to it.
    push hl
    call BASIC_TRY_EVAL_STR_FUNCTION
    jr   nc, .str_func_matched
    pop  hl
    jr   .numeric_path
.str_func_matched:
    pop  hl
    ld   (EXPR_PARSE_PTR), hl
    jp   .string_path

.numeric_path:
    call BASIC_EVAL_EXPR                      ; DE = left value
    ret  c
    push de                                    ; save left value across
                                              ; the operator scan below
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   (EXPR_PARSE_PTR), hl
    ld   a, (hl)
    cp   "="
    jr   z, .op_eq
    cp   "<"
    jr   z, .op_lt_variants
    cp   ">"
    jr   z, .op_gt_variants

    ; no relational operator at all — bare truthy expression
    pop  de
    ld   a, d
    or   e
    jr   z, .bare_false
    ld   de, 1
    or   a
    ret
.bare_false:
    ld   de, 0
    or   a
    ret

.op_eq:
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_RHS_AND_COMPARE
    ret  c
    ld   a, c
    or   a
    jp   z, .result_true
    jp   .result_false

.op_lt_variants:
    inc  hl
    ld   a, (hl)
    cp   "="
    jr   z, .op_le
    cp   ">"
    jr   z, .op_ne
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_RHS_AND_COMPARE
    ret  c
    ld   a, c
    cp   $FF
    jp   z, .result_true
    jp   .result_false
.op_le:
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_RHS_AND_COMPARE
    ret  c
    ld   a, c
    cp   1
    jp   z, .result_false
    jr   .result_true
.op_ne:
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_RHS_AND_COMPARE
    ret  c
    ld   a, c
    or   a
    jr   z, .result_false
    jr   .result_true

.op_gt_variants:
    inc  hl
    ld   a, (hl)
    cp   "="
    jr   z, .op_ge
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_RHS_AND_COMPARE
    ret  c
    ld   a, c
    cp   1
    jr   z, .result_true
    jr   .result_false
.op_ge:
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_RHS_AND_COMPARE
    ret  c
    ld   a, c
    cp   $FF
    jr   z, .result_false
    jr   .result_true

.string_path:
    ; Only = and <> are supported for strings — same narrow scope
    ; INKEY$'s own single-char comparison already established, just
    ; generalized to full string content. HL still holds EXPR_PARSE_
    ; PTR's value from this routine's own entry (see the peek above).
    ld   de, STR_EXPR_SCRATCH + 1
    ld   c, 31                        ; STR_EXPR_SCRATCH is a 32-byte
                                      ; slot (31 content + length prefix)
                                      ; — BASIC_EVAL_STR_EXPR's own
                                      ; budget is caller-supplied now,
                                      ; see its header (2026-08-23)
    call BASIC_EVAL_STR_EXPR           ; B = length written, HL advanced
                                       ; — full expression, '+' chains
                                       ; included (2026-08-22)
    jr   c, .str_fail
    ld   a, b
    ld   (STR_EXPR_SCRATCH), a
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_SKIP_SPACES
    ld   (EXPR_PARSE_PTR), hl
    ld   a, (hl)
    cp   "="
    jr   z, .str_op_eq
    cp   "<"
    jr   nz, .str_bad_op
    inc  hl
    ld   a, (hl)
    cp   ">"
    jr   nz, .str_bad_op
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_STR_RHS_AND_COMPARE
    ret  c
    ld   a, c
    or   a
    jr   z, .result_false              ; equal -> <> is false
    jr   .result_true
.str_op_eq:
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_STR_RHS_AND_COMPARE
    ret  c
    ld   a, c
    or   a
    jr   z, .result_true               ; equal -> = is true
    jr   .result_false
.str_bad_op:
    ; <, <=, >, >= aren't supported for strings — deliberately narrow,
    ; matching this dialect's existing INKEY$ scope note rather than
    ; silently doing something (like a byte-order compare) nobody asked
    ; for
    jp   BASIC_RAISE_SYNTAX_ERROR
.str_fail:
    scf
    ret

.result_true:
    ld   de, 1
    or   a
    ret
.result_false:
    ld   de, 0
    or   a
    ret

; ============================================================================
; BASIC_STR_RHS_AND_COMPARE
; Shared tail for BASIC_EVAL_COMPARISON's string path: evaluates the
; right-hand string primary (EXPR_PARSE_PTR already positioned just
; past the operator) into STR_CMP_RIGHT, then compares it byte-for-byte
; against STR_EXPR_SCRATCH (the left operand, already parsed and
; stashed there by the caller). Unlike BASIC_EVAL_RHS_AND_COMPARE, this
; IS a plain CALL/RET — no stack-reordering trick needed, since nothing
; is pushed by the caller before this runs (the left string lives in
; memory, not on the stack).
; In:  none (reads EXPR_PARSE_PTR; expects STR_EXPR_SCRATCH already
;      holding the left operand — length byte + content)
; Out: carry clear + C = 0 if equal, nonzero if different; carry set on
;      a malformed right-hand string primary
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STR_RHS_AND_COMPARE:
    ld   hl, (EXPR_PARSE_PTR)
    ld   de, STR_CMP_RIGHT + 1
    ld   c, 31                        ; STR_CMP_RIGHT is a 32-byte slot
                                      ; — see BASIC_EVAL_STR_EXPR's own
                                      ; header (2026-08-23)
    call BASIC_EVAL_STR_EXPR           ; full expression, '+' chains
                                       ; included (2026-08-22)
    ret  c
    ld   (EXPR_PARSE_PTR), hl
    ld   a, (STR_EXPR_SCRATCH)
    cp   b
    jr   nz, .not_equal
    or   a
    jr   z, .equal                    ; both zero-length — equal
    ld   b, a
    ld   hl, STR_EXPR_SCRATCH + 1
    ld   de, STR_CMP_RIGHT + 1
.cmp_loop:
    ld   a, (de)
    cp   (hl)
    jr   nz, .not_equal
    inc  hl
    inc  de
    djnz .cmp_loop
.equal:
    ld   c, 0
    or   a
    ret
.not_equal:
    ld   c, 1
    or   a
    ret

; ============================================================================
; BASIC_MATCH_KEYWORD
; Case-insensitive match of text at HL against a null-terminated,
; uppercase reference keyword at DE. Hand-traced: HL->"print x", DE->
; "PRINT\0" — 'p' upper='P' matches 'P', 'r'->'R' matches 'R', ... on
; reaching DE's null terminator, HL has advanced exactly past "print"
; (5 chars) and stops there, matched. On a non-match partway through
; (e.g. HL->"pretty"), HL/DE are restored to their original values
; before returning, so the caller can try a different keyword against
; the same starting position.
; In:  HL = text pointer, DE = pointer to uppercase reference keyword
; Out: carry clear + HL advanced past the matched keyword; carry set +
;      HL/DE unchanged if it didn't match
; Destroys: AF
; ============================================================================
BASIC_MATCH_KEYWORD:
    push de
    push hl
.loop:
    ld   a, (de)
    or   a
    jr   z, .matched
    ld   b, a
    ld   a, (hl)
    call BASIC_TO_UPPER
    cp   b
    jr   nz, .no_match
    inc  hl
    inc  de
    jr   .loop
.matched:
    pop  bc                        ; discard saved (pre-match) HL — the
                                   ; advanced HL from the loop is what
                                   ; the caller wants, not this
    pop  bc                        ; discard saved DE
    or   a
    ret
.no_match:
    pop  hl                        ; restore original HL
    pop  de                        ; restore original DE
    scf
    ret

; ============================================================================
; BASIC_MATCH_KEYWORD_BOUNDARY
; BASIC_MATCH_KEYWORD itself has no boundary check at all — it reports
; success as soon as the reference keyword's letters match, regardless
; of what follows. A real, pre-existing gap this project hadn't hit
; yet: "PRINTER" typed as a statement matches KW_PRINT (5 letters),
; leaving "ER" as PRINT's argument — which happens to parse as a
; harmless-looking single-variable PRINT of E, silently ignoring the
; trailing R, rather than being rejected as unrecognized. Found while
; adding GOTO specifically, since a label named "goto" (as "goto:")
; would be caught by the GOTO dispatch the same way — and labels,
; being user-chosen multi-character names rather than single letters,
; are far more likely to collide with a keyword prefix than anything
; that existed in this language before. Fixed here rather than left
; as a known gap, and wired into all six of BASIC_EXEC_STATEMENT's
; keyword checks, not just the new GOTO one, since the gap was never
; specific to GOTO.
;
; This is a DIFFERENT boundary check than BASIC_TRY_DETECT_ONE's own
; (used for live display highlighting) — that one operates on
; EDIT_LINE_BUF, which is null-terminated and can be followed by '=';
; this one operates on tokenized, STORED statement content, which is
; $0D-terminated instead, and none of this language's keywords are
; ever validly followed by '=' at the execution level.
; In:  HL = text pointer, DE = null-terminated reference keyword
;      (already uppercase)
; Out: carry clear + HL advanced past the keyword, only on a genuine
;      match (letters AND a real boundary — $0D or space — right
;      after); carry set + HL/DE unchanged otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_MATCH_KEYWORD_BOUNDARY:
    push hl
    push de
    call BASIC_MATCH_KEYWORD
    jr   c, .match_failed              ; BASIC_MATCH_KEYWORD already
                                       ; restored HL/DE itself here

    ld   a, (hl)
    cp   $0D
    jr   z, .boundary_ok
    cp   " "
    jr   z, .boundary_ok

    ; letters matched, but nothing valid follows — restore to the
    ; original position and report this as no match at all
    pop  de
    pop  hl
    scf
    ret

.boundary_ok:
    pop  bc                              ; discard the saved (pre-call)
    pop  bc                              ; DE/HL — keep the CURRENT,
                                        ; advanced HL/DE from the
                                        ; successful match instead;
                                        ; popping into BC (not DE/HL)
                                        ; is what keeps this a discard
                                        ; rather than an overwrite
    or   a
    ret

.match_failed:
    pop  bc                              ; same discard — HL/DE were
    pop  bc                              ; already restored by
                                        ; BASIC_MATCH_KEYWORD's own
                                        ; internal failure path
    scf
    ret

; ============================================================================
; BASIC_MATCH_FUNCTION_NAME
; Matches a built-in function name at HL against an uppercase reference
; name at DE, the same letter-by-letter case-insensitive comparison
; BASIC_MATCH_KEYWORD already does — but the required boundary here is
; '(' (a function call's opening paren), not the space/$0D boundary
; BASIC_MATCH_KEYWORD_BOUNDARY checks for statement keywords. Spaces
; between the name and '(' are tolerated ("ABS (5)"), matching this
; evaluator's existing liberal-whitespace style elsewhere (BASIC_EVAL_
; EXPR/TERM/FACTOR all skip spaces before their own operator checks).
; On success, HL is left pointing at the argument itself — past the
; name, past any spaces, and past the '(' — so BASIC_EVAL_PRIMARY's
; caller can go straight into evaluating the argument expression.
; In:  HL = text pointer, DE = pointer to uppercase reference function
;      name (null-terminated)
; Out: carry clear + HL advanced to the argument start, EXPR_PARSE_PTR
;      updated to match; carry set + HL/DE unchanged if the letters
;      don't match, or letters match but no '(' follows (only spaces
;      allowed in between)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_MATCH_FUNCTION_NAME:
    push hl
    push de
    call BASIC_MATCH_KEYWORD
    jr   c, .no_match                     ; BASIC_MATCH_KEYWORD already
                                          ; restored HL/DE itself here

    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   "("
    jr   nz, .not_a_call                   ; letters matched, but
                                          ; nothing valid follows —
                                          ; this identifier isn't a
                                          ; call to this function
    inc  hl
    ld   (EXPR_PARSE_PTR), hl

    pop  bc                                  ; discard the saved
    pop  bc                                  ; (pre-call) DE/HL — keep
                                            ; the current, advanced HL
    or   a
    ret

.not_a_call:
    pop  de
    pop  hl
    scf
    ret

.no_match:
    pop  de
    pop  hl
    scf
    ret

; ============================================================================
; BASIC_TRY_EVAL_FUNCTION
; Tries each entry in FUNCTION_TABLE against the text at HL via
; BASIC_MATCH_FUNCTION_NAME, same IX-walking shape as BASIC_DETECT_
; KEYWORD_PREFIX's own table walk. On a match, stashes the matched
; function's handler address and argument shape for BASIC_EVAL_PRIMARY.
; In:  HL = text pointer (spaces already skipped by the caller, per
;      BASIC_EVAL_PRIMARY's own existing convention)
; Out: carry clear + HL advanced to the argument start (handler/argc
;      set) if a function name matched; carry set + HL unchanged
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_TRY_EVAL_FUNCTION:
    ld   ix, FUNCTION_TABLE
.loop:
    ld   e, (ix+0)
    ld   d, (ix+1)                        ; DE = this entry's name
                                          ; reference pointer
    ld   a, d
    or   e
    jr   z, .no_match                      ; 0,0 = end-of-table sentinel

    push ix                                ; preserve table position
                                          ; across the call
    call BASIC_MATCH_FUNCTION_NAME
    pop  ix
    jr   c, .try_next                        ; not this one — HL was
                                            ; already restored by
                                            ; BASIC_MATCH_FUNCTION_
                                            ; NAME's own failure paths

    ld   a, (ix+2)                           ; matched — stash handler
    ld   (FUNC_CALL_HANDLER), a
    ld   a, (ix+3)
    ld   (FUNC_CALL_HANDLER+1), a
    ld   a, (ix+4)                           ; ...and argument shape
    ld   (FUNC_CALL_ARGC), a                   ; count
    or   a
    ret

.try_next:
    ld   bc, 5                               ; name pointer + handler
    add  ix, bc                              ; pointer + argcount
    jr   .loop

.no_match:
    scf
    ret

; ============================================================================
; BASIC_TRY_EVAL_STR_FUNCTION
; Same shape as BASIC_TRY_EVAL_FUNCTION above, one table entry smaller
; (no argcount byte — each string-returning function's own argument
; shape differs in TYPE, not just count, e.g. UPPER$ takes one string,
; LEFT$ takes a string and a number, so parsing is hand-written per
; function in BASIC_EVAL_STR_PRIMARY's own dispatch rather than driven
; generically from a count). Tries each STRING_FUNCTION_TABLE entry via
; the same BASIC_MATCH_FUNCTION_NAME every numeric function above also
; uses — that routine is already fully generic (keyword text in, "("
; boundary check), nothing string-specific needed to reuse it here.
; In:  HL = text pointer (spaces already skipped by the caller)
; Out: carry clear + HL advanced to the argument start (STR_FUNC_
;      CALL_ID set) if a string-function name matched; carry set + HL
;      unchanged otherwise
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_TRY_EVAL_STR_FUNCTION:
    ld   ix, STRING_FUNCTION_TABLE
.loop:
    ld   e, (ix+0)
    ld   d, (ix+1)
    ld   a, d
    or   e
    jr   z, .no_match                       ; 0,0 = end-of-table sentinel

    push ix
    call BASIC_MATCH_FUNCTION_NAME
    pop  ix
    jr   c, .try_next

    ld   a, (ix+2)                            ; matched — stash this
    ld   (STR_FUNC_CALL_ID), a                  ; entry's function ID
    or   a
    ret

.try_next:
    ld   bc, 3                                ; 3 bytes per entry
    add  ix, bc
    jr   .loop

.no_match:
    scf
    ret

; ============================================================================
; BASIC_VALIDATE_VAR_LETTER
; Shared parsing primitive: uppercases A and checks whether it's in the
; range 'A'-'Z'. Factors out the "TO_UPPER, cp 'A', cp 'Z'+1" range
; check duplicated at every point in this file that reads a single
; variable-letter token (FOR's var, NEXT's var, INPUT's var, a plain
; assignment target, etc.) — same duplication class as
; BASIC_EXPECT_COMMA_EXPR's own extraction. Callers that read the
; candidate letter from (HL) still do that themselves (`ld a,(hl)`)
; before calling this — only the uppercase+range-check step is shared,
; since what happens on success or failure (which register the letter
; ends up in, which local label a failure jumps to) differs enough
; per call site that folding those in too wouldn't be a real match.
; In:  A = candidate character
; Out: success — carry clear, A = uppercased letter. failure — carry
;      set, A undefined.
; Destroys: AF
; ============================================================================
BASIC_VALIDATE_VAR_LETTER:
    call BASIC_TO_UPPER
    cp   "A"
    jr   c, .invalid
    cp   "Z" + 1
    jr   nc, .invalid
    or   a
    ret
.invalid:
    scf
    ret

; ============================================================================
; BASIC_VAR_ADDR
; Maps a variable letter to its data in the dynamic scalar pool,
; auto-vivifying it (creating a fresh zero-initialized 2-byte record)
; on first reference — see BASIC_VAR_FIND_OR_CREATE's own header for
; the real logic; this is a thin kind-tagged wrapper into it, same
; shape BASIC_STR_ADDR uses. Replaces the old fixed VAR_TABLE's O(1)
; address math (Phase 4, 2026-08-23 — see include/sysvars.inc's own
; "Scalar variables in the dynamic pool" header). Case-insensitive.
; In:  A = variable letter
; Out: carry clear + HL = address of that variable's 2-byte data; carry
;      set + MSG_ARRAY_OUT_OF_MEMORY already recorded (pool exhausted)
;      otherwise — NEW as of this migration: the old fixed-table
;      version could never fail. Every call site must check carry now.
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_VAR_ADDR:
    call BASIC_TO_UPPER
    ld   c, VAR_KIND_NUM
    ld   de, VAR_NUM_UNITS
    jp   BASIC_VAR_FIND_OR_CREATE

; ============================================================================
; BASIC_STR_ADDR
; Maps a string-variable letter to its data in the dynamic scalar pool,
; auto-vivifying it (creating a fresh zero-initialized 32-byte record —
; byte 0 = length, bytes 1-31 = content, same layout STR_TABLE slots
; always used) on first reference. Thin kind-tagged wrapper into BASIC_
; VAR_FIND_OR_CREATE, same shape BASIC_VAR_ADDR uses. Replaces the old
; fixed STR_TABLE's O(1) address math (Phase 4, 2026-08-23 — see
; include/sysvars.inc's own "Scalar variables in the dynamic pool"
; header).
; In:  A = variable letter (already uppercased — every caller reaches
;      this via BASIC_DETECT_STRVAR, which already uppercases)
; Out: carry clear + HL = address of that variable's 32-byte data;
;      carry set + MSG_ARRAY_OUT_OF_MEMORY already recorded (pool
;      exhausted) otherwise — NEW as of this migration: the old fixed-
;      table version could never fail. Every call site must check
;      carry now.
; Destroys: AF, BC, DE, HL — already true before this migration too
;      (see this project's own real-bug history: a caller once relied
;      on DE surviving this call and silently corrupted a variable
;      slot when it didn't — every call site was already required to
;      treat DE, and now BC too, as clobbered).
; ============================================================================
BASIC_STR_ADDR:
    ld   c, VAR_KIND_STR
    ld   de, VAR_STR_UNITS
    jp   BASIC_VAR_FIND_OR_CREATE

; ============================================================================
; BASIC_DETECT_STRVAR
; Checks whether HL points at a string-variable reference: a single
; letter (A-Z, case-insensitive) immediately followed by '$'. Doesn't
; consume anything on failure — same "carry set, HL unchanged" contract
; every other BASIC_TRY_*/BASIC_CHECK_* probe in this file uses, so
; callers can freely try this and fall through to a different
; interpretation (a plain numeric variable, a keyword, ...) without
; needing their own save/restore dance.
; In:  HL = text pointer
; Out: carry clear + A = uppercased letter, HL advanced past both
;      characters, on a match; carry set + HL unchanged otherwise
; Destroys: AF
; ============================================================================
BASIC_DETECT_STRVAR:
    ld   a, (hl)
    call BASIC_VALIDATE_VAR_LETTER
    ret  c                          ; not even a letter — HL untouched,
                                    ; BASIC_VALIDATE_VAR_LETTER's own
                                    ; contract
    push af                         ; save the uppercased letter
    inc  hl
    ld   a, (hl)
    cp   "$"
    jr   z, .found
    dec  hl                         ; not a string var — undo the inc,
                                    ; HL back to its original position
    pop  af
    scf
    ret
.found:
    inc  hl                         ; consume the '$' too
    pop  af
    or   a
    ret

; ============================================================================
; BASIC_EVAL_STR_PRIMARY
; Parses one string primary — a quoted literal or a bare string-
; variable reference (X$) — and writes its content at (DE). No
; concatenation here (see basic_language_reference.md's own "Sound"-
; adjacent Strings section for that scope note) — just the one
; building block both string assignment and string comparison share.
;
; A too-long literal is truncated silently at C bytes (the caller's own
; remaining budget — see BASIC_EVAL_STR_EXPR below, the only caller
; that ever passes anything less than 31), matching the EXACT precedent
; BASIC_STMT_PRINT's own literal-copy path already set (that routine's
; own comment calls this an accepted TODO, not a considered decision
; unique to this one) — consistency with existing behavior beats
; inventing a new "STRING TOO LONG" error class just for this. An
; unterminated literal (hits end-of-statement before a closing quote)
; is also tolerated exactly like PRINT's own literal path: the closing
; quote just isn't consumed, statement-end parsing handles the rest.
; In:  HL = text pointer, DE = destination (at least C bytes free), C =
;      max bytes to write (callers with a single primary, not a whole
;      BASIC_EVAL_STR_EXPR chain, pass 31 — the full slot size)
; Out: carry clear, HL advanced past what was consumed, DE advanced by
;      the number of bytes written, B = bytes written (<=C, whichever
;      of source-length/literal-length/C is smallest); carry set (a
;      SYNTAX ERROR already recorded) if neither a literal nor a
;      string-variable reference starts here
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_EVAL_STR_PRIMARY:
    call BASIC_SKIP_SPACES           ; real bug found and fixed here
                                     ; (2026-08-22): callers between
                                     ; operator and operand (e.g.
                                     ; BASIC_EVAL_COMPARISON's string
                                     ; path, right after consuming '=')
                                     ; don't all skip spaces themselves
                                     ; first, unlike BASIC_EVAL_EXPR's
                                     ; own numeric path, which already
                                     ; tolerates a leading space
                                     ; internally — without this,
                                     ; "A$ = "HI"" failed the checker
                                     ; entirely (the space right after
                                     ; '=' reached here as an
                                     ; unrecognized primary)
    ld   a, (hl)
    cp   '"'
    jr   z, .literal

    push de                             ; caller's destination — must
                                        ; survive the call below (its
                                        ; own Destroys list includes
                                        ; DE/BC), same reason .str_
                                        ; func_call itself re-stashes
                                        ; these on the stack rather
                                        ; than trusting a register to
                                        ; survive a destructive call
    push bc                            ; caller's budget (C)
    call BASIC_TRY_EVAL_STR_FUNCTION    ; try a string-function call
                                        ; name BEFORE a bare variable —
                                        ; same order the numeric side's
                                        ; own BASIC_EVAL_PRIMARY already
                                        ; established, since a variable
                                        ; letter never carries a "(" the
                                        ; way a function call does
    pop  bc
    pop  de
    jp   nc, BASIC_EVAL_STR_FUNCTION_CALL  ; tail call — its own In/Out
                                           ; contract is exactly what
                                           ; this routine's own caller
                                           ; needs back (HL/DE/C in;
                                           ; carry/HL/B out)

    call BASIC_DETECT_STRVAR
    jr   nc, .var_ref
    ld   hl, MSG_SYNTAX_ERROR
    call BASIC_SET_PENDING_ERROR
    scf
    ret

.literal:
    inc  hl                          ; skip opening quote
    ld   b, 0
.lit_loop:
    ld   a, (hl)
    cp   '"'
    jr   z, .lit_closed
    cp   $0D
    jr   z, .lit_closed              ; unterminated — stop at
                                     ; statement end, same tolerance
                                     ; BASIC_STMT_PRINT's own literal
                                     ; path already has
    ld   a, b
    cp   c
    jr   z, .lit_closed              ; truncate silently at the caller's
                                     ; budget — see this routine's own
                                     ; header
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    inc  b
    jr   .lit_loop
.lit_closed:
    ld   a, (hl)
    cp   '"'
    jr   nz, .done                   ; unterminated — don't consume $0D
    inc  hl                          ; consume the closing quote
    jr   .done

.var_ref:
    ld   b, a
    ld   a, (hl)
    cp   "("
    jr   z, .array_ref
    ld   a, b
    ; A = uppercased letter, HL already advanced past "X$" — stash it,
    ; BASIC_STR_ADDR needs HL as its own scratch for the slot address.
    ; DE (the caller's destination pointer) must ALSO survive the
    ; call — BASIC_STR_ADDR destroys it too (see that routine's own
    ; header for the real bug this fixed) — so it's saved here right
    ; alongside HL, not left to the call. C (the caller's budget) used
    ; to survive BASIC_STR_ADDR on its own, but that routine's Destroys
    ; list now includes BC too (Phase 4, 2026-08-23 — it's a kind
    ; parameter into the dynamic scalar pool now) — same "the callee's
    ; documented Destroys list must be RIGHT, not just trusted" lesson
    ; this exact routine already hit once before, so C is saved here
    ; too now, not left to chance.
    push hl
    push de
    push bc
    call BASIC_STR_ADDR
    jr   c, .var_ref_oom              ; pool exhausted — error already
                                      ; recorded; unwind the 3 pushes
                                      ; above before propagating
    pop  bc
    pop  de
    ld   a, (hl)                     ; A = source length
    cp   c
    jr   c, .var_ref_within_budget   ; source length < budget — use it
                                     ; as-is
    ld   a, c                        ; source length >= budget — clamp
                                     ; to whatever's left (added for
                                     ; BASIC_EVAL_STR_EXPR's concat-
                                     ; enation loop, 2026-08-22; every
                                     ; other caller passes C=31, always
                                     ; >= any stored variable's own
                                     ; length, so this never actually
                                     ; clamps anything for them)
.var_ref_within_budget:
    push af                          ; stash the (possibly clamped)
                                     ; length — B becomes the loop
                                     ; counter below and would be 0 by
                                     ; the time DJNZ finishes, same
                                     ; reason the old C-based stash
                                     ; existed, just on the stack now
                                     ; that C itself is live input, not
                                     ; free scratch
    inc  hl
    or   a
    jr   z, .var_ref_empty
    ld   b, a
.var_ref_copy:
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    djnz .var_ref_copy
.var_ref_empty:
    pop  af
    ld   b, a                        ; B = bytes written (restored)
    pop  hl                          ; HL = text pointer, advanced past
                                     ; "X$"
.done:
    or   a
    ret

.var_ref_oom:
    pop  bc
    pop  de
    pop  hl
    ret                               ; carry survives the pops above
                                      ; untouched (only POP AF affects
                                      ; flags) — already set from
                                      ; BASIC_STR_ADDR's own failure

.array_ref:
    push bc                           ; B=array letter, C=budget
    inc  hl                           ; consume "("
    push de
    call BASIC_ARRAY_PARSE_SUBSCRIPTS
    jr   c, .array_ref_parse_fail
    ld   a, (BASIC_CHECK_ONLY)
    or   a
    jr   nz, .array_ref_check_only
    pop  de
    pop  bc
    ld   a, b
    push hl                           ; parsed text pointer
    push de                           ; destination
    push bc                           ; budget
    ld   c, ARRAY_KIND_STR
    call BASIC_ARRAY_FIND
    jr   c, .array_ref_not_dimmed
    call BASIC_STR_ARRAY_ELEMENT_ADDR
    jr   c, .array_ref_runtime_fail
    pop  bc
    pop  de
    ld   a, (hl)
    cp   c
    jr   c, .var_ref_within_budget
    ld   a, c
    jp   .var_ref_within_budget       ; common length/clamped copy tail
.array_ref_check_only:
    pop  de
    pop  bc
    ld   b, 0
    or   a
    ret
.array_ref_parse_fail:
    pop  de
    pop  bc
    ret
.array_ref_not_dimmed:
    ld   hl, MSG_ARRAY_NOT_DIMMED
    call BASIC_SET_PENDING_ERROR
.array_ref_runtime_fail:
    pop  bc
    pop  de
    pop  hl
    scf
    ret

; ============================================================================
; BASIC_EVAL_STR_FUNCTION_CALL
; Evaluates ONE string- or numeric-returning function call whose name
; BASIC_TRY_EVAL_STR_FUNCTION has already matched (STR_FUNC_CALL_ID
; set) — a standalone top-level routine rather than a local label
; inside BASIC_EVAL_STR_PRIMARY specifically so BASIC_STMT_PRINT and
; BASIC_EVAL_COMPARISON can call it too, without each duplicating this
; same ~150-line shape-dispatch/stack-juggling body — Home ROM's own
; tight budget can't absorb three copies of it. HL/EXPR_PARSE_PTR are
; already positioned at the argument start (past the matched name and
; its "("), same handoff BASIC_MATCH_FUNCTION_NAME already gives the
; numeric side's own .do_function_call. Grouped by argument SHAPE, not
; by function, for the same space reason — see STRING_FUNCTION_TABLE's
; own header for why CHR$/STR$, UPPER$/LOWER$, LEFT$/RIGHT$/FILL$, and
; INKEY$ share one dispatch body apiece instead of one each.
;
; REAL BUG CAUGHT BEFORE SHIPPING (2026-08-22), same family as this
; session's own FUNC_CALL_ID/ARGC and CUR_VAR_LETTER fixes: the first
; draft stashed the caller's destination (DE) and budget (C) — and
; each shape's own acquired pool-buffer address — in shared sysvars
; (STR_FUNC_DEST/BUDGET/ARGBUF) before parsing the argument(s). But
; the argument itself can contain ANOTHER string-function call (e.g.
; UPPER$(LEFT$(A$,3))) which recurses back through this exact
; dispatch and overwrites those shared cells before the OUTER call
; ever reads them back. Fixed by stashing all of it on the real Z80
; stack instead, which nests correctly at any depth for free — the
; caller's DE/C are pushed once at entry and popped back (per shape)
; immediately before the final BASIC_STRFUNC_EXROM call; STR_FUNC_DEST
; still exists as a sysvar (STRFUNC_EXROM reads it directly, no spare
; register to pass it through) but is only ever written from a stack-
; popped value, right before it's used, never trusted to survive a
; recursive parse on its own.
;
; Every failure path below must pop back to a balanced stack before
; reaching BASIC_RAISE_SYNTAX_ERROR — same "always restore on any exit"
; discipline BASIC_TRY_ARRAY_ASSIGNMENT already established. Each
; shape's own fail label documents exactly what's still outstanding at
; that point.
; In:  HL = text pointer (argument start), DE = destination buffer,
;      C = budget, STR_FUNC_CALL_ID already set to one of the 8
;      STRING_FUNCTION_TABLE IDs (CHR$/STR$/UPPER$/LOWER$/LEFT$/RIGHT$/
;      FILL$/INKEY$ — VAL/INSTR are numeric-returning and go through
;      their own bespoke parsing in BASIC_EVAL_PRIMARY's own .do_
;      function_call instead, not through here)
; Out: carry clear, HL advanced past the closing ")", B = bytes written
;      to the destination; carry set (message already recorded) on
;      failure
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_EVAL_STR_FUNCTION_CALL:
    push de                              ; caller's destination
    push bc                              ; caller's budget (C) — B is
                                         ; unused padding, pushed as a
                                         ; pair since Z80 has no single-
                                         ; register push
    ld   a, (STR_FUNC_CALL_ID)
    push af                              ; REAL BUG FOUND AND FIXED
                                         ; (2026-08-22, caught by live
                                         ; testing UPPER$(LEFT$(A$,5))
                                         ; — same bug class as this
                                         ; session's own FUNC_CALL_ID/
                                         ; ARGC and CUR_VAR_LETTER
                                         ; fixes): STR_FUNC_CALL_ID is
                                         ; shared scratch. Parsing THIS
                                         ; call's own argument can
                                         ; recurse into ANOTHER string-
                                         ; function call (LEFT$ here),
                                         ; which overwrites STR_FUNC_
                                         ; CALL_ID with ITS OWN id — so
                                         ; by the time this (outer)
                                         ; call reaches its own final
                                         ; BASIC_STRFUNC_EXROM below, it
                                         ; was dispatching the WRONG
                                         ; transform entirely (LEFT$'s
                                         ; body, fed UPPER$'s own
                                         ; leftover registers as if
                                         ; they were LEFT$'s arguments)
                                         ; — silently produced an empty
                                         ; string rather than "HELLO".
                                         ; Stashed here on the real
                                         ; stack (nests correctly at
                                         ; any depth) and restored in
                                         ; each shape below, right
                                         ; before its own final
                                         ; BASIC_STRFUNC_EXROM call —
                                         ; matches every other shared-
                                         ; scratch fix in this session.
    cp   STRFUNC_ID_INKEY
    jr   z, .sf_shape0
    cp   STRFUNC_ID_UPPER
    jr   z, .sf_shape_str1
    cp   STRFUNC_ID_LOWER
    jr   z, .sf_shape_str1
    cp   STRFUNC_ID_LEFT
    jr   z, .sf_shape_str_num
    cp   STRFUNC_ID_RIGHT
    jr   z, .sf_shape_str_num
    ; else CHR$ (1) / STR$ (2) — fall into shape_num1 directly, no jump
    ; needed (FILL$ dropped 2026-08-22 — see FUNC_ID_INSTR's own
    ; FUNCTION_TABLE comment for why)

.sf_shape_num1:
    ; CHR$(n) / STR$(n) — one numeric argument, no string-pool buffer
    ; needed at all. Stack here: [id][budget][dest] (our own entry
    ; push).
    call BASIC_EVAL_EXPR                 ; DE = n, HL/EXPR_PARSE_PTR
                                         ; advanced
    jp   c, .sf_fail
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jp   nz, .sf_fail
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    push de                              ; stash n — Z80 has no direct
    pop  ix                              ; DE->IX transfer, so move it
                                         ; through the stack into IX,
                                         ; freeing DE for the caller's
                                         ; own destination below
    pop  af                              ; A = our own STR_FUNC_CALL_ID,
    ld   (STR_FUNC_CALL_ID), a           ; restored — see this
                                         ; routine's own entry comment
    pop  bc                              ; BC = caller's budget (C)
    pop  de                              ; DE = caller's destination
    ld   (STR_FUNC_DEST), de
    push ix
    pop  de                              ; DE = n (restored, in place
                                         ; for STRFUNC_EXROM's own
                                         ; In: DE=numeric argument)
    call BASIC_STRFUNC_EXROM
    jp   .sf_finish

.sf_shape0:
    ; INKEY$() — no arguments at all, just the closing ")". Stack here:
    ; [id][budget][dest] (our own entry push, untouched).
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jp   nz, .sf_fail
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    pop  af                              ; A = our own STR_FUNC_CALL_ID,
    ld   (STR_FUNC_CALL_ID), a           ; restored
    pop  bc                              ; BC = caller's budget (C)
    pop  de                              ; DE = caller's destination
    ld   (STR_FUNC_DEST), de
    call BASIC_STRFUNC_EXROM
    jr   .sf_finish

.sf_shape_str1:
    ; UPPER$(s) / LOWER$(s) — one string argument
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_PARSE_STR_ARG_TO_POOL     ; HL = buffer address (length
                                         ; prefix already written;
                                         ; releases on its own failure)
    jr   c, .sf_fail
    push hl                              ; buffer address, across the
                                         ; ")" check below
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jr   nz, .sf_str1_grammar_fail
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    pop  hl                              ; HL = buffer address
    pop  af                              ; A = our own STR_FUNC_CALL_ID,
    ld   (STR_FUNC_CALL_ID), a           ; restored
    pop  bc                              ; BC = caller's budget (C)
    pop  de                              ; DE = caller's destination
    ld   (STR_FUNC_DEST), de
    call BASIC_STRFUNC_EXROM
    call STR_FUNC_POOL_RELEASE
    jr   .sf_finish

.sf_shape_str_num:
    ; LEFT$(s,n) / RIGHT$(s,n) / FILL$(s,n) — one string, one numeric
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_PARSE_STR_ARG_TO_POOL
    jr   c, .sf_fail
    push hl                              ; buffer address, across the
                                         ; "," check and the numeric-
                                         ; argument parse below
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ","
    jr   nz, .sf_strnum_grammar_fail
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_EXPR                 ; DE = n, HL/EXPR_PARSE_PTR
                                         ; advanced — this call
                                         ; tolerates its own leading
                                         ; space, same as every other
                                         ; numeric-argument site in this
                                         ; file
    jr   c, .sf_strnum_grammar_fail
    push de                              ; n, across the ")" check and
                                         ; the caller-dest/budget
                                         ; retrieval below
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jr   nz, .sf_strnum_late_fail
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    pop  ix                              ; IX = n
    pop  hl                              ; HL = buffer address
    pop  af                              ; A = our own STR_FUNC_CALL_ID,
    ld   (STR_FUNC_CALL_ID), a           ; restored
    pop  bc                              ; BC = caller's budget (C)
    pop  de                              ; DE = caller's destination
    ld   (STR_FUNC_DEST), de
    push ix
    pop  de                              ; DE = n (restored)
    call BASIC_STRFUNC_EXROM             ; HL=buffer, DE=n, C=budget
    call STR_FUNC_POOL_RELEASE
    jr   .sf_finish
.sf_strnum_late_fail:
    pop  de                              ; discard n
.sf_strnum_grammar_fail:
.sf_str1_grammar_fail:
    pop  hl                              ; discard the re-pushed buffer
                                         ; address (BASIC_PARSE_STR_
                                         ; ARG_TO_POOL's own failure
                                         ; already released the slot on
                                         ; ITS OWN failure paths — this
                                         ; one only covers a grammar
                                         ; check AFTER a successful
                                         ; parse, where the slot is
                                         ; still ours to release)
    call STR_FUNC_POOL_RELEASE
.sf_fail:
    pop  af                              ; discard our own STR_FUNC_
                                         ; CALL_ID snapshot — its value
                                         ; doesn't matter on a failure
                                         ; path, only the stack balance
    pop  bc                              ; discard caller's budget
    pop  de                              ; discard caller's destination
    jp   BASIC_RAISE_SYNTAX_ERROR

.sf_finish:
    jp   c, BASIC_RAISE_SYNTAX_ERROR     ; e.g. CHR$'s own range check —
                                         ; message already set by
                                         ; STRFUNC_EXROM itself; BASIC_
                                         ; SET_PENDING_ERROR's "first
                                         ; write wins" rule makes this
                                         ; jump's own MSG_SYNTAX_ERROR a
                                         ; no-op when one is already
                                         ; pending
    ld   hl, (EXPR_PARSE_PTR)
    or   a
    ret

; ============================================================================
; BASIC_EVAL_STR_EXPR
; Parses a string EXPRESSION: one primary, optionally followed by more
; primaries joined with '+' (concatenation) — Phase 3's second slice,
; on top of BASIC_EVAL_STR_PRIMARY's own single-primary foundation.
; Thin wrapper: each successive primary writes directly after the
; previous one's output (DE is already positioned there), so the actual
; concatenation is free — the only real work here is tracking a single
; shared budget across the whole chain (via BASIC_EVAL_STR_PRIMARY's
; own parametrized C) so a second or third operand can't overrun the
; destination slot the way calling BASIC_EVAL_STR_PRIMARY per term with
; a fixed C each time never would guard against.
; In:  HL = text pointer, DE = destination, C = total budget (max bytes
;      writable across the WHOLE "+"-chain) — WIDENED 2026-08-23 from a
;      hardcoded 31 to a real caller-supplied parameter: every existing
;      caller targets a 31/32-byte scratch slot (STR_EXPR_SCRATCH/
;      STR_CMP_RIGHT/a STR_FUNC_POOL buffer) and now passes C=31
;      explicitly at its own call site instead, unchanged in practice —
;      only BASIC_STMT_PRINT passes a wider budget, since PRINT_BUF
;      isn't a 31-char scalar slot and was silently capping concatenated
;      PRINT output at 31 chars for no real reason. The budget is kept
;      on the real Z80 stack for the whole routine, not a shared
;      sysvar, so a recursive call through a string-function argument
;      (e.g. "UPPER$(A$+B$)", which calls back into this exact routine
;      before the outer call is finished with it) nests correctly —
;      same reasoning BASIC_EVAL_STR_FUNCTION_CALL's own header already
;      documents for STR_FUNC_DEST/BUDGET/ARGBUF.
; Out: carry clear, HL advanced past the whole expression, B = total
;      bytes written (<=C — once the budget is exhausted, a further
;      term is still parsed for grammar but contributes 0 bytes, same
;      "truncate, don't error" precedent BASIC_EVAL_STR_PRIMARY's own
;      literal path set); carry set (error already recorded) if the
;      first primary is malformed
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_EVAL_STR_EXPR:
    ld   a, c                        ; the caller's total budget must
                                     ; survive BASIC_EVAL_STR_PRIMARY's
                                     ; own Destroys:...,BC,... across
                                     ; every term in the chain
    push af
    call BASIC_EVAL_STR_PRIMARY
    jr   c, .fail_early
    ld   a, b                        ; A = running total
.loop:
    push af                          ; stack: [budget][running_total]
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   "+"
    jr   nz, .no_more
    inc  hl
    call BASIC_SKIP_SPACES
    pop  af                          ; stack: [budget] — A = running total
    ld   b, a
    pop  af                          ; stack: [] — A = total budget
    push af                          ; stack: [budget] — put it right
                                     ; back, still needed on a further
                                     ; "+" after this one
    sub  b                           ; A = remaining budget
    ld   c, a
    ld   a, b                        ; A = running total (to re-stash
                                     ; across the call below — BC
                                     ; itself doesn't survive BASIC_
                                     ; EVAL_STR_PRIMARY, and its own B
                                     ; is this call's real return value,
                                     ; so the running total can't share
                                     ; that register across the call)
    push af                          ; stack: [budget][running_total]
    call BASIC_EVAL_STR_PRIMARY
    jr   c, .fail_mid
    ld   a, b                        ; A = bytes written THIS term
    ld   b, a                        ; stash it in B — the pop af right
                                     ; below would otherwise clobber A
                                     ; before it's added in
    pop  af                          ; stack: [budget] — A = running total
    add  a, b                        ; A = new running total
    jr   .loop
.no_more:
    pop  af                          ; stack: [budget] — A = running total
                                     ; (final)
    ld   b, a
    pop  af                          ; stack: [] — discard the budget,
                                     ; balances the entry push
    or   a
    ret
.fail_early:
    pop  af                          ; stack: [] — discard the budget
                                     ; (only the entry push happened —
                                     ; the FIRST BASIC_EVAL_STR_PRIMARY
                                     ; call failed, .loop never started)
    scf
    ret
.fail_mid:
    pop  af                          ; stack: [budget] — discard the
                                     ; re-stashed running total
    pop  af                          ; stack: [] — discard the budget
    scf
    ret

; ============================================================================
; STR_FUNC_POOL_ACQUIRE / STR_FUNC_POOL_RELEASE
; A small fixed pool of scratch string buffers for string-function
; arguments — see include/sysvars.inc's own STR_FUNC_POOL header for
; the full "why not just reuse STR_EXPR_SCRATCH" reasoning (nested
; calls like "UPPER$(LEFT$(A$,3))" need each level's own buffer alive
; at once). Simple bump allocator: ACQUIRE reserves the next free slot
; and returns its address; RELEASE gives back the most recently
; acquired one. Every call site must pair these exactly, same
; discipline as the array-letter stack-push/pop fix — acquire right
; before parsing an argument into the buffer, release right after the
; function that needed it is done with it, on EVERY exit path
; (success and failure alike).
; ============================================================================
; In:  none
; Out: carry clear + HL = buffer address (32 bytes, uninitialized);
;      carry set (error already recorded) if all STR_FUNC_POOL_SLOTS
;      are already in use
; Destroys: AF, HL
STR_FUNC_POOL_ACQUIRE:
    ld   a, (STR_FUNC_POOL_NEXT)
    cp   STR_FUNC_POOL_SLOTS
    jr   nc, .exhausted
    ld   h, 0
    ld   l, a
    add  hl, hl                      ; x2
    add  hl, hl                      ; x4
    add  hl, hl                      ; x8
    add  hl, hl                      ; x16
    add  hl, hl                      ; x32 — HL = slot_index * 32
    ld   de, STR_FUNC_POOL
    add  hl, de                      ; HL = this slot's buffer address
    ld   a, (STR_FUNC_POOL_NEXT)
    inc  a
    ld   (STR_FUNC_POOL_NEXT), a
    or   a
    ret
.exhausted:
    ld   hl, MSG_EXPRESSION_TOO_COMPLEX
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; In: none. Out: none. Destroys: AF.
STR_FUNC_POOL_RELEASE:
    ld   a, (STR_FUNC_POOL_NEXT)
    dec  a
    ld   (STR_FUNC_POOL_NEXT), a
    ret

; ============================================================================
; BASIC_PARSE_STR_ARG_TO_POOL
; Factors out the "acquire a pool slot, parse a string-argument
; expression into it, write its length prefix, release on failure"
; sequence shared by BASIC_EVAL_STR_FUNCTION_CALL's own .sf_shape_str1/
; .sf_shape_str_num and BASIC_EVAL_PRIMARY's .str_arg_1/.str_arg_2 —
; four near-identical copies of this same ~12-instruction sequence
; before this was pulled out, at a real premium once Home ROM's own
; budget went negative shipping this feature (2026-08-22). The
; terminator that follows the argument (")" or ",", depending on which
; function/argument-position called this) is deliberately NOT consumed
; here — every caller already needs its own different next step
; (another argument, or the closing paren) right after, so that check
; stays with the caller.
; In:  HL = text pointer (start of the string-argument expression)
; Out: carry clear, HL = pool-buffer address (length prefix already
;      written), EXPR_PARSE_PTR = position just past the parsed
;      expression (terminator not yet consumed); carry set (message
;      already recorded, any acquired pool slot already released) on
;      failure
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_PARSE_STR_ARG_TO_POOL:
    call STR_FUNC_POOL_ACQUIRE           ; HL = 32-byte buffer
    ret  c
    push hl                              ; buffer address, across the
                                         ; recursive string-expression
                                         ; parse below — NOT a shared
                                         ; sysvar, see BASIC_EVAL_STR_
                                         ; FUNCTION_CALL's own header
                                         ; for why (nested string-
                                         ; function calls)
    ld   d, h
    ld   e, l
    inc  de                              ; DE = buffer content start
    ld   c, 31                           ; the pool buffer is 32 bytes
                                         ; (31 content + length prefix)
                                         ; — this is now BASIC_EVAL_STR_
                                         ; EXPR's real budget parameter,
                                         ; not a redundant duplicate of
                                         ; its old internal hardcode
                                         ; (2026-08-23)
    ; REAL BUG FOUND AND FIXED (2026-08-22, caught by live emulator
    ; testing — "PRINT UPPER$("hello")" failing check with the
    ; argument-evaluation carrying garbage): STR_FUNC_POOL_ACQUIRE just
    ; above already clobbered HL with the BUFFER address, so calling
    ; BASIC_EVAL_STR_EXPR without reloading HL here fed it the buffer
    ; address as if it were the TEXT to parse, not the actual source
    ; text. The original .sf_shape_str1/.sf_shape_str_num code (before
    ; this routine was factored out to share their duplicated logic)
    ; had this exact reload; it was dropped by accident during that
    ; extraction and never caught until a real run exercised it — no
    ; string-function argument had ever actually been parsed through
    ; this path until then.
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_EVAL_STR_EXPR
    jr   c, .argeval_fail
    ; SECOND REAL BUG FOUND AND FIXED (2026-08-22, same debugging pass
    ; as the one above): BASIC_EVAL_STR_EXPR/BASIC_EVAL_STR_PRIMARY
    ; only advance the HL REGISTER, never EXPR_PARSE_PTR itself (every
    ; other existing caller either uses HL directly right afterward, or
    ; happens not to clobber it before its own next read) — the very
    ; next instruction here, `pop hl`, was overwriting that advanced HL
    ; with the buffer address before this routine's own documented
    ; "EXPR_PARSE_PTR = position just past the parsed expression" out-
    ; contract was ever actually honored, silently discarding it. Every
    ; caller's own subsequent `ld hl,(EXPR_PARSE_PTR)` (the ")"/","
    ; check) was then reading the STALE pre-argument position instead —
    ; e.g. seeing the argument's own opening quote instead of the
    ; closing paren. Caught by bisecting exactly this "PRINT
    ; UPPER$("hello")" case with per-branch border-color instrumentation
    ; once the first bug's fix alone didn't clear the check failure.
    ld   (EXPR_PARSE_PTR), hl            ; save the REAL advanced
                                         ; position before the buffer-
                                         ; address pop below destroys it
    pop  hl                              ; HL = buffer address
    ld   (hl), b                         ; store the length prefix
    or   a
    ret
.argeval_fail:
    pop  hl                              ; discard the buffer address —
                                         ; still need it to release the
                                         ; slot
.fail:
    call STR_FUNC_POOL_RELEASE
    scf
    ret

; ============================================================================
; BASIC_ARRAY_FIND
; Scans a dynamic-pool region for a record matching the given letter AND
; kind. Shared by numeric arrays, numeric scalars, and string scalars —
; the "option 3" unification this routine's own header always intended
; (see include/sysvars.inc's own "Scalar variables in the dynamic pool"
; section for the full two-ended-pool design this enables). Linear
; scan, not the O(1) address math VAR_TABLE/STR_TABLE used to use —
; unavoidable once records are variable-length rather than fixed slots,
; but cheap in practice: at most a handful of arrays/variables exist in
; any real program.
;
; Region is picked by kind, not passed in — there are only ever two
; possible regions (never a third), so a cheap 2-way dispatch at entry
; is far less code than a fully generic caller-supplied-bounds
; interface would cost at every one of this routine's own call sites:
; ARRAY_KIND_NUM scans PROG_END..ARRAYS_END (arrays, growing UP,
; RUN-scoped); VAR_KIND_NUM/VAR_KIND_STR scan VARS_START..PROG_AREA_MAX
; (scalars, growing DOWN, persist across RUN). Either way the resolved
; end boundary is stashed in POOL_SCAN_END and re-read fresh every loop
; iteration, same reasoning the original array-only version already
; had for ARRAYS_END: DE gets clobbered each iteration by the current
; record's own count field, so the boundary can't just live in a
; register across iterations — has to come back from memory (or, for
; scalars, be reloaded as the same PROG_AREA_MAX immediate every time)
; instead.
;
; Multi-dimensional array support (a genuinely two-way kind byte, 2D
; DIM/read/write) was built and verified here 2026-08-22, then archived
; the same day for Home ROM budget — see docs/programmers_reference.
; md's "Multi-dimensional arrays (archived)" section for the full
; design if reviving it is ever worth another look.
; In:  A = uppercased variable/array letter, C = kind (ARRAY_KIND_NUM /
;      VAR_KIND_NUM / VAR_KIND_STR — see include/sysvars.inc)
; Out: carry clear + HL = pointer to this record's DATA (past the
;      4-byte header), DE = unit count (element count for an array;
;      always VAR_NUM_UNITS/VAR_STR_UNITS for a scalar, not a real
;      bound — nothing indexes into a scalar); carry set (nothing
;      found — caller's job to raise the right NOT DIMENSIONED/first-
;      reference error) otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_ARRAY_FIND:
    ld   b, a                      ; B = target letter, stashed early
                                   ; (cheaper than push/pop) since the
                                   ; bounds setup below needs A as its
                                   ; own scratch for the kind comparison
    ld   a, c
    cp   ARRAY_KIND_NUM
    jr   z, .array_bounds
    cp   ARRAY_KIND_STR
    jr   nz, .scalar_bounds
.array_bounds:
    ld   hl, (PROG_END)
    ld   de, (ARRAYS_END)
    jr   .bounds_done
.scalar_bounds:
    ld   hl, (VARS_START)
    ld   de, PROG_AREA_MAX
.bounds_done:
    ld   (POOL_SCAN_END), de
.scan_loop:
    push hl
    ld   de, (POOL_SCAN_END)
    or   a
    sbc  hl, de
    pop  hl
    jr   nc, .not_found             ; HL >= end boundary — scanned every
                                    ; record, no match
    ld   a, (hl)                    ; kind byte
    ld   (POOL_RECORD_KIND), a
    inc  hl
    cp   c
    jr   nz, .skip_name              ; kind mismatch — A still holds the
                                     ; kind byte (always 0-2), which can
                                     ; NEVER equal a real letter (65-90)
                                     ; in the `cp b` below, so falling
                                     ; through the shared tail without
                                     ; re-reading name is safe: this
                                     ; record can never match regardless
                                     ; of what its name actually is
    ld   a, (hl)                     ; name byte (kind already matched)
.skip_name:
    inc  hl                          ; A now holds either the real name
                                     ; byte (kind matched) or the
                                     ; untouched kind byte (kind
                                     ; mismatched) — `cp b` below
                                     ; recomputes its own flags fresh
                                     ; either way, so nothing needs to
                                     ; survive from the `cp c` above
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                     ; DE = unit count
    inc  hl                          ; HL = this record's data start
    cp   b
    jr   z, .found                   ; exact match — HL/DE already hold
                                     ; exactly this routine's own Out
                                     ; contract
    ; mismatch — advance HL past this record's data (count*2 bytes,
    ; since HL is already a real address and DE already holds count,
    ; adding it twice is exactly + count*2)
    ld   a, (POOL_RECORD_KIND)
    cp   ARRAY_KIND_STR
    jr   nz, .skip_numeric
    sla  e
    rl   d
    sla  e
    rl   d
    sla  e
    rl   d
    sla  e
    rl   d
    sla  e
    rl   d                           ; string count * 32 bytes
    add  hl, de
    jr   .scan_loop
.skip_numeric:
    add  hl, de
    add  hl, de
    jr   .scan_loop
.found:
    or   a
    ret
.not_found:
    scf
    ret

; ============================================================================
; BASIC_VAR_FIND_OR_CREATE
; Shared core behind BASIC_VAR_ADDR/BASIC_STR_ADDR: looks a scalar up
; via BASIC_ARRAY_FIND (kind VAR_KIND_NUM/VAR_KIND_STR), and on the
; first-ever reference to a given letter, creates it — auto-vivifying
; the way a classic BASIC scalar always has (an unassigned variable
; reads as 0/"" rather than needing a DIM first), which a real dynamic
; pool can't get for free the way VAR_TABLE/STR_TABLE's old fixed 26-
; slot tables did (every letter already "existed" there, zeroed, with
; no notion of "not yet referenced"). Creation prepends a new record at
; VARS_START (the scalar pool's OWN high-water mark, growing DOWN from
; PROG_AREA_MAX — see include/sysvars.inc's own header for why scalars
; can't just grow up from PROG_END the way arrays do), mirroring BASIC_
; STMT_DIM's own append-and-zero-init logic exactly, just prepending
; instead of appending.
; In:  A = variable letter, C = kind (VAR_KIND_NUM/VAR_KIND_STR), DE =
;      unit count (VAR_NUM_UNITS/VAR_STR_UNITS — D=0 either way)
; Out: carry clear + HL = pointer to this variable's data (VAR_CHECK_
;      SCRATCH, untouched by real state, during a BASIC_CHECK_ONLY
;      pass — see below); carry set + MSG_ARRAY_OUT_OF_MEMORY already
;      recorded (pool exhausted — the two ends of the dynamic region
;      would cross) otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_VAR_FIND_OR_CREATE:
    ld   b, a                       ; B = letter, stashed in a register
                                    ; rather than pushed — cheaper, and
                                    ; BASIC_CHECK_ONLY's own check below
                                    ; needs A as its own scratch either
                                    ; way (only A can address memory
                                    ; directly on Z80)
    ld   a, (BASIC_CHECK_ONLY)
    or   a
    jr   z, .not_checking
    ld   hl, VAR_CHECK_SCRATCH       ; every call site just wants A
                                    ; readable/writable address — never
                                    ; auto-vivify a real pool record
                                    ; from a statement that hasn't
                                    ; actually run yet (same reasoning
                                    ; BASIC_CHECK_ARRAY_ASSIGNMENT's own
                                    ; header gives for arrays). Carry
                                    ; already clear from the `or a`
                                    ; above (logical ops always clear
                                    ; it on Z80) — no need to re-clear
    ret
.not_checking:
    ld   a, b                       ; A = letter (restored)
    push af
    push de
    call BASIC_ARRAY_FIND           ; C (kind) survives this call on
                                    ; its own — read-only throughout
                                    ; BASIC_ARRAY_FIND's body, never
                                    ; written — so it's not saved here
    jr   c, .create
    pop  de
    pop  af
    or   a                          ; BASIC_ARRAY_FIND already left
                                    ; carry clear (found) and HL correct
                                    ; — just re-clear carry, since the
                                    ; pops above trash flags with
                                    ; whatever was pushed before the call
    ret

.create:
    pop  de                         ; E = unit count (D=0) — the letter
                                    ; (af) stays untouched on the stack
                                    ; until the header write below,
                                    ; popped exactly once there rather
                                    ; than round-tripped through a pop+
                                    ; push here for no reason

    ; total record size = 4 (header) + units*2 (data)
    ld   h, d
    ld   l, e                       ; HL = unit count (copy — DE itself
                                    ; still holds it for one more line)
    push de                         ; NOW stash units — about to be
                                    ; destroyed for real by the size
                                    ; arithmetic below, needed again for
                                    ; the header write. C (kind) is
                                    ; still live in its own register,
                                    ; untouched this whole routine
    add  hl, hl                     ; HL = units*2
    ld   de, 4
    add  hl, de                     ; HL = this record's total size

    ; would-be new VARS_START = VARS_START - total size
    ld   de, (VARS_START)
    ex   de, hl                     ; HL = VARS_START, DE = total size
    or   a
    sbc  hl, de                     ; HL = new VARS_START

    ; must not cross ARRAYS_END (the arrays region's own growing end)
    push hl
    ld   de, (ARRAYS_END)
    or   a
    sbc  hl, de
    pop  hl
    jr   c, .var_out_of_memory

    ld   (VARS_START), hl           ; commit; HL = new record's own
                                    ; start address too
    pop  de                         ; E = unit count (restored)
    pop  af                         ; A = letter (restored)
    ld   (hl), c                    ; kind — never pushed, survived on
                                    ; its own the whole time
    inc  hl
    ld   (hl), a                    ; name
    inc  hl
    ld   (hl), e                    ; count (16-bit)
    inc  hl
    ld   (hl), d
    inc  hl                         ; HL = data start

    push hl                         ; data start — this routine's own
                                    ; Out contract
.zero_loop:
    ld   a, d
    or   e
    jr   z, .zero_done
    ld   (hl), 0
    inc  hl
    ld   (hl), 0
    inc  hl
    dec  de
    jr   .zero_loop
.zero_done:
    pop  hl                          ; carry already clear — reached
                                     ; only via the zero_loop's own `or
                                     ; e` above (jr z), and pop hl
                                     ; doesn't touch flags
    ret

.var_out_of_memory:
    pop  de
    pop  af
    ld   hl, MSG_ARRAY_OUT_OF_MEMORY   ; same underlying condition
                                       ; (dynamic pool exhausted), just
                                       ; from the scalar side now too
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_ARRAY_PARSE_SUBSCRIPTS
; Parses one index expression and the closing ")" — shared by array
; read (.do_array_read, BASIC_EVAL_PRIMARY) and array write
; (BASIC_TRY_ARRAY_ASSIGNMENT), which would otherwise duplicate this
; exact grammar. (Briefly parsed one-or-two comma-separated indices,
; 2026-08-22, for since-archived multi-dimensional array support — see
; docs/programmers_reference.md's "Multi-dimensional arrays (archived)"
; section.)
; In:  HL = pointer right after the array's own "(" (index expression
;      starts here)
; Out: carry clear + ARRAY_INDEX set, HL = pointer just past the
;      closing ")"; carry set on malformed grammar (error already
;      recorded by whatever failed, matching this project's "first
;      error wins" convention — see BASIC_SET_PENDING_ERROR's own
;      header — or left unset for a caller further out to raise
;      generically, matching this routine's own ")" mismatch case)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_ARRAY_PARSE_SUBSCRIPTS:
    ld   (EXPR_PARSE_PTR), hl
    call BASIC_EVAL_EXPR             ; DE = index, HL advanced
    ret  c
    ld   (ARRAY_INDEX), de
    ld   hl, (EXPR_PARSE_PTR)
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jr   nz, .grammar_fail
    inc  hl
    ld   (EXPR_PARSE_PTR), hl
    or   a
    ret
.grammar_fail:
    scf
    ret

; ============================================================================
; BASIC_ARRAY_ELEMENT_ADDR
; Given a successful BASIC_ARRAY_FIND result and a subscript already
; parsed into ARRAY_INDEX (via BASIC_ARRAY_PARSE_SUBSCRIPTS), bounds-
; checks it and returns the element's address — shared by array read
; and array write, same reasoning BASIC_ARRAY_PARSE_SUBSCRIPTS's own
; header gives.
; In:  HL = data start, DE = element count (BASIC_ARRAY_FIND's own Out)
; Out: carry clear + HL = element address; carry set + SUBSCRIPT OUT
;      OF RANGE already recorded otherwise
; Destroys: AF, DE, HL
; ============================================================================
BASIC_ARRAY_ELEMENT_ADDR:
    push hl                          ; data start — survives the bounds
                                     ; check below
    ld   hl, (ARRAY_INDEX)
    or   a
    sbc  hl, de                       ; index - count: carry set means
                                      ; in range (index < count) — also
                                      ; correctly rejects a "negative"
                                      ; index, which wraps to a huge
                                      ; unsigned value here
    jr   nc, .oob_pop
    ld   hl, (ARRAY_INDEX)
    add  hl, hl                       ; index*2
    pop  de                           ; DE = data start
    add  hl, de                       ; HL = element address
    or   a
    ret
.oob_pop:
    pop  de                          ; discard the data-start stash
    ld   hl, MSG_ARRAY_SUBSCRIPT_RANGE
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; String-array sibling: same bounds contract, but fixed 32-byte elements.
BASIC_STR_ARRAY_ELEMENT_ADDR:
    push hl
    ld   hl, (ARRAY_INDEX)
    or   a
    sbc  hl, de
    jr   nc, .str_oob
    ld   hl, (ARRAY_INDEX)
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    pop  de
    add  hl, de
    or   a
    ret
.str_oob:
    pop  de
    ld   hl, MSG_ARRAY_SUBSCRIPT_RANGE
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_STMT_DIM
; DIM <letter>(<n>) — declares a numeric array of n zero-initialized
; elements, indices 0..n-1. See include/sysvars.inc's own header for
; the memory model (appended to the dynamic arrays region, reset each
; RUN). 0-based indexing and the "must not already be DIM'd this run"
; restriction are both deliberate, simple choices — not an attempt at
; byte-for-byte real Sinclair BASIC fidelity (which is 1-based and
; would need a real reallocator to support re-DIMing cleanly).
;
; Multi-dimensional DIM (rows,cols) was built and verified here
; 2026-08-22, then archived the same day for Home ROM budget — see
; docs/programmers_reference.md's "Multi-dimensional arrays (archived)"
; section for the full design if reviving it is ever worth another
; look. This is back to its pre-that-work, 1D-only shape.
;
; In:  HL = pointer just past the DIM keyword
; Out: carry clear on success; carry set + error already recorded
;      otherwise
; Destroys: AF, BC, DE, HL
;
; REAL BUG FOUND AND FIXED (2026-08-22): an earlier draft stashed the
; array's own letter in CUR_VAR_LETTER before parsing the size
; expression — shared scratch BASIC_TRY_ASSIGNMENT/BASIC_TRY_ARRAY_
; ASSIGNMENT also use, which a nested array READ inside that size
; expression (e.g. "DIM A(B(0))", B already DIM'd) would silently
; clobber before this routine ever reads it back. Fixed by pushing the
; letter onto the real stack across just that one recursive call — see
; .do_array_read's own header (BASIC_EVAL_PRIMARY) for the fuller
; incident writeup, the same bug, found there first. Safe to write it
; into CUR_VAR_LETTER again once the size expression is fully parsed
; and stashed — nothing between there and the rest of this routine
; recurses into another expression evaluation.
; ============================================================================
BASIC_STMT_DIM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C0BA
    or   a
    ret  z
    dec  a
    jp   z, BASIC_RAISE_SYNTAX_ERROR
    dec  a
    ld   hl, MSG_INVALID_ARRAY_SIZE
    jr   z, .dim_set_error
    dec  a
    ld   hl, MSG_ARRAY_ALREADY_DIMMED
    jr   z, .dim_set_error
    ld   hl, MSG_ARRAY_OUT_OF_MEMORY
.dim_set_error:
    call BASIC_SET_PENDING_ERROR
    scf
    ret

    IF 0
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    call BASIC_VALIDATE_VAR_LETTER
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    push af                              ; stash the letter across the
                                         ; size expression's own
                                         ; recursive parse below
    inc  hl
    ld   a, (hl)
    cp   "("
    jp   nz, .dim_bad_syntax_pop        ; JP not JR — .dim_bad_syntax_
                                       ; pop is now far enough past
                                       ; this point that JR's range
                                       ; doesn't reach it (project's
                                       ; own recurring JR-range lesson)
    inc  hl
    call BASIC_EVAL_EXPR               ; DE = size, HL advanced
    jp   c, .dim_bad_syntax_pop
    ld   (ARRAY_DIM_COUNT), de          ; stash immediately — nothing
                                       ; further here needs to juggle
                                       ; registers across the several
                                       ; calls still to come
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ")"
    jp   nz, .dim_bad_syntax_pop
    inc  hl
    call BASIC_EXPECT_STATEMENT_END
    jr   c, .dim_bad_syntax_pop

    pop  af                              ; A = array's own letter
                                         ; (restored) — safe to park in
                                         ; CUR_VAR_LETTER now, see this
                                         ; routine's own header
    ld   (CUR_VAR_LETTER), a
    ld   hl, (ARRAY_DIM_COUNT)
    ld   a, h
    or   a
    jr   nz, .size_ok                    ; high byte nonzero — size is
                                        ; at least 256, definitely >=1
    ld   a, l
    or   a
    jr   z, .bad_size
.size_ok:
    ld   a, (CUR_VAR_LETTER)
    ld   c, ARRAY_KIND_NUM
    call BASIC_ARRAY_FIND
    jr   nc, .already_dimmed

    ; total record size = 4 (header) + count*2 (data)
    ld   hl, (ARRAY_DIM_COUNT)
    add  hl, hl                          ; count*2
    ld   de, 4
    add  hl, de                          ; HL = this record's total size
    ld   de, (ARRAYS_END)
    add  hl, de                          ; HL = would-be new ARRAYS_END
    ld   de, (VARS_START)                ; ceiling is VARS_START now,
                                         ; not the fixed PROG_AREA_MAX
                                         ; — scalars can occupy that
                                         ; upper space too (see sysvars.
                                         ; inc's own VARS_START header)
    or   a
    sbc  hl, de
    jr   c, .fits
    jr   z, .fits
    jr   .out_of_memory
.fits:
    ; recompute cleanly rather than try to recover values out of the
    ; check above's own destructive subtraction — simpler and safer,
    ; matching this project's own established "simple and correct beats
    ; clever" precedent (see DIV10's own header)
    ld   hl, (ARRAY_DIM_COUNT)
    add  hl, hl
    ld   de, 4
    add  hl, de                          ; HL = this record's total size
    ld   de, (ARRAYS_END)                ; DE = this record's own start
                                         ; address — where it gets
                                         ; written below
    push de
    add  hl, de
    ld   (ARRAYS_END), hl                ; commit the new region size
    pop  hl                              ; HL = this record's start
                                         ; address

    xor  a
    ld   (hl), a                          ; kind = ARRAY_KIND_NUM (0)
    inc  hl
    ld   a, (CUR_VAR_LETTER)
    ld   (hl), a                          ; name
    inc  hl
    ld   de, (ARRAY_DIM_COUNT)
    ld   (hl), e
    inc  hl
    ld   (hl), d                          ; count (16-bit)
    inc  hl                               ; HL = data start

.zero_loop:
    ld   a, d
    or   e
    jr   z, .zero_done
    ld   (hl), 0
    inc  hl
    ld   (hl), 0
    inc  hl
    dec  de
    jr   .zero_loop
.zero_done:
    ret                               ; carry already clear — reached
                                     ; only via the loop's own `or e`
                                     ; above (jr z), untouched since
    ; (Phase 4, 2026-08-23 — spotted while auditing this exact shape
    ; in the new scalar-pool code's own zero-init loop, see BASIC_VAR_
    ; FIND_OR_CREATE's identical .zero_done above)

.bad_size:
    ld   hl, MSG_INVALID_ARRAY_SIZE
    call BASIC_SET_PENDING_ERROR
    scf
    ret
.already_dimmed:
    ld   hl, MSG_ARRAY_ALREADY_DIMMED
    call BASIC_SET_PENDING_ERROR
    scf
    ret
.out_of_memory:
    ld   hl, MSG_ARRAY_OUT_OF_MEMORY
    call BASIC_SET_PENDING_ERROR
    scf
    ret
.dim_bad_syntax_pop:
    pop  af                              ; balance the letter stash
    jp   BASIC_RAISE_SYNTAX_ERROR
    ENDIF

; ============================================================================
; BASIC_ARRAY_DIMN_EXROM
; Thin Home-side wrapper for DIMN(name, dim) — see .array_name_dim_arg
; (BASIC_EVAL_PRIMARY) for the call site and ARRAY_EXROM_DIMN (rom/
; exrom_arrays.asm) for the real body.
; In/Out/Destroys: identical to ARRAY_EXROM_DIMN's own contract.
; ============================================================================
BASIC_ARRAY_DIMN_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C08A

; ============================================================================
; DIV10
; Unsigned 16-bit divide by 10, via 16-iteration shift-and-subtract —
; Z80 has no hardware divide. Verified numerically against all values
; 0-1999 plus edge cases (0, 65535, etc.) with a Python simulation
; before being trusted, same discipline as this project's other tricky
; arithmetic (the screen address formula, the ink/paper bit-swap).
; In:  HL = dividend
; Out: HL = quotient, DE = remainder (0-9)
; Destroys: AF, B
; ============================================================================
; ============================================================================
; BASIC_PARSE_NUMBER
; Parses an optionally-signed decimal integer starting at HL. Hand-
; traced digit-by-digit: "53" accumulates 0->5->53 via repeated
; (acc*10)+digit; "-7" negates the parsed magnitude (7) via two's
; complement after the digit loop.
; In:  HL = text pointer
; Out: carry clear + DE = parsed value, HL advanced past the number;
;      carry set if no digits were found at all (HL still advances
;      past a lone '-' if present, but that's not a valid number)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_PARSE_NUMBER:
    ld   b, 0                       ; B = sign flag, 0=positive
    ld   a, (hl)
    cp   "-"
    jr   nz, .no_sign
    ld   b, 1
    inc  hl
.no_sign:
    ld   de, 0                        ; DE = accumulator
    ld   c, 0                          ; C = digit count
.digit_loop:
    ld   a, (hl)
    cp   "0"
    jr   c, .done_digits
    cp   "9" + 1
    jr   nc, .done_digits
    sub  "0"                             ; A = digit value 0-9

    ; DE = DE*10 + A, computed via HL as scratch (text pointer saved on
    ; the stack across this, since we need HL free) — DE*10 =
    ; DE*8 + DE*2, hand-traced for "53": after '5', DE=5; processing
    ; '3': DE*2=10 (pushed), DE*8=40, pop+add->50, +digit(3)=53. Matches.
    push hl                                ; save text pointer
    ld   l, a
    ld   h, 0
    push hl                                  ; save digit value
    ld   h, d
    ld   l, e
    add  hl, hl                                ; HL = DE*2
    push hl                                      ; save DE*2
    ld   h, d
    ld   l, e
    add  hl, hl
    add  hl, hl
    add  hl, hl                                    ; HL = DE*8
    pop  de                                          ; DE = DE*2 (restored)
    add  hl, de                                        ; HL = DE*10
    pop  de                                              ; DE = digit
    add  hl, de                                            ; HL = DE*10+digit
    ex   de, hl                                              ; DE = new accumulator
    pop  hl                                                    ; HL = text ptr

    inc  hl
    inc  c
    jr   .digit_loop
.done_digits:
    ld   a, c
    or   a
    jr   z, .no_digits

    ld   a, b
    or   a
    jr   z, .positive
    ld   a, d
    cpl
    ld   d, a
    ld   a, e
    cpl
    ld   e, a
    inc  de
.positive:
    or   a
    ret
.no_digits:
    scf
    ret

; ============================================================================
; BASIC_NUM_TO_STRING
; Converts a signed 16-bit value to a null-terminated decimal ASCII
; string in PRINT_BUF, via repeated DIV10 (digits come out least-
; significant-first, so they're written backward from near the end of
; the buffer). Hand-traced for 53 -> "53", -7 -> "-7", and 0 -> "0"
; (the loop's "stop when quotient is 0" condition still produces
; exactly one digit for a zero input, not an empty string).
; In:  DE = signed value
; Out: HL = pointer to the resulting string (within PRINT_BUF)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_NUM_TO_STRING:
    call BASIC_CALL_EXROM_INLINE
    DW   $C09C

; ============================================================================
; BASIC_FLOAT_TO_STRING
; Converts a non-negative packed float already sitting on top of
; CALC_STACK into a "D.DDDD" (4 fractional digits, truncated toward
; zero) decimal string in PRINT_BUF — the float-result analog of
; BASIC_NUM_TO_STRING above, reusing that same routine for the integer
; part rather than duplicating its digit loop. Called by BASIC_STMT_
; PRINT's "function-result float" branch (see FUNC_RESULT_IS_FLOAT's
; own sysvars.inc comment) for both SQR and SIN.
;
; Sign is NOT handled here — both current callers only ever hand this
; a non-negative magnitude by construction: SQR's own MATH_SQRT16
; already floors a negative argument to 0 before BASIC_SQR_FLOAT's own
; refinement ever starts, and SIN's reference-angle reduction (see
; BASIC_SIN_FLOAT's own header) keeps the value it computes here
; non-negative, tracking the true sign separately in FUNC_RESULT_FLOAT_
; NEGATIVE for BASIC_STMT_PRINT to print as a literal "-" beforehand.
;
; In:  CALC_STACK top = one packed float, v >= 0 (CALC_SP > 0)
; Out: HL = pointer to a null-terminated "D.DDDD" string in PRINT_BUF.
;      CALC_SP back to whatever it was before v was pushed — this
;      consumes exactly the 1 slot it was given, no more, no less, so
;      callers don't need their own cleanup around it.
; Destroys: AF, BC, DE, HL.
; ============================================================================
BASIC_FLOAT_TO_STRING:
    call BASIC_CALL_EXROM_INLINE
    DW   $C0A8

; ============================================================================
; BASIC_ADVANCE_OUTPUT_ROW
; Advances BASIC_OUTPUT_ROW by one, scrolling all 24 output rows up if
; that would exceed the last valid row (23).
;
; Fixes a real, confirmed bug: both BASIC_STMT_PRINT and
; BASIC_STMT_INPUT used to increment BASIC_OUTPUT_ROW with no bounds
; check at all (each had its own separate copy of the same unbounded
; logic — a TODO comment had already flagged this as a known gap, but
; it went unfixed until it actually bit). A GOTO-driven infinite PRINT
; loop reached row 24 on its 25th line, and GFX_PUTCHAR/PRINT_STRING
; looked up ROW_BASE_TABLE[24] — one entry past its end — reading
; whatever memory happens to follow it (FONT_TABLE) as if it were a
; screen address. That produced a garbage address, and every print
; after that corrupted whatever it landed on instead of crashing
; outright, which is exactly what a screenshot showed: repeating
; garbled columns and stale "33" values in the wrong places, rather
; than an obvious hang.
;
; RUN output is incremental rather than editor-shadow rendered. It uses the
; dedicated 24-row scroll primitive; the editor's sibling primitive protects
; row 23 because that row is its status bar.
;
; Also resets BASIC_OUTPUT_COL to 0 — added alongside AT/TAB support:
; a new line always starts back at the left margin, matching real
; newline behavior, so an earlier AT/TAB's column positioning only
; ever affects the single PRINT statement that immediately follows it,
; not every PRINT from then on.
; In:  none
; Out: none
; Destroys: AF
; ============================================================================
BASIC_ADVANCE_OUTPUT_ROW:
    xor  a
    ld   (BASIC_OUTPUT_COL), a          ; a new line always starts back
                                        ; at the left margin — matches
                                        ; real newline behavior; any
                                        ; AT/TAB positioning only ever
                                        ; applies to the single PRINT
                                        ; that follows it
    ld   a, (BASIC_OUTPUT_ROW)
    inc  a
    cp   24
    jr   c, .no_wrap

    call GFX_SCROLL_OUTPUT_UP
    ld   a, 23
    ld   (BASIC_OUTPUT_ROW), a
    ret

.no_wrap:
    ld   (BASIC_OUTPUT_ROW), a
    or   a                              ; explicitly clear carry — "cp 24"
                                       ; just above left it SET (that's
                                       ; what got us onto this path in
                                       ; the first place), which used to
                                       ; be harmless since every caller
                                       ; discarded it, but now that
                                       ; carry is a real success/failure
                                       ; signal propagated further up,
                                       ; leaving it as-is would make
                                       ; ordinary non-wrapping PRINT
                                       ; calls look like errors
    ret

; ============================================================================
; BASIC_STMT_PRINT
; Parses and executes PRINT "string literal" or PRINT <variable> —
; nothing else yet (no numeric expressions, no multiple comma/
; semicolon-separated items). Silently does nothing if neither matches,
; rather than erroring (no error reporting implemented yet).
; In:  HL = pointer just past the PRINT keyword (and its trailing space,
;      if any — leading spaces are skipped below)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_PRINT:
.skip_spaces:
    ld   a, (hl)
    cp   " "
    jr   nz, .after_spaces
    inc  hl
    jr   .skip_spaces
.after_spaces:
    ; A string-typed PRINT argument (literal, variable, or function
    ; call) goes through BASIC_EVAL_STR_EXPR — the same concatenation-
    ; aware evaluator LET/assignment already uses — so
    ; PRINT "SUM=" + STR$(S) and PRINT M$ + N$ actually concatenate
    ; instead of silently printing only the first primary and dropping
    ; everything after the "+". REAL BUG FOUND AND FIXED (2026-08-23,
    ; caught reviewing demos/showcase.txt screen by screen): the three
    ; branches this replaced (.print_string/.print_strvar/.print_func_
    ; call, still visible in this file's own history) each grabbed
    ; exactly ONE primary and stopped, explicitly TOLERATING whatever
    ; followed as "trailing garbage" rather than evaluating it — so a
    ; "+" after a string in PRINT had silently never worked.
    ;
    ; Still probe with the three ORIGINAL, side-effect-free detectors
    ; first (quote peek, BASIC_DETECT_STRVAR, BASIC_TRY_EVAL_STR_
    ; FUNCTION) rather than just trying BASIC_EVAL_STR_EXPR speculatively
    ; and falling through to the numeric path on failure: unlike these
    ; probes, BASIC_EVAL_STR_PRIMARY's own no-match path calls BASIC_
    ; SET_PENDING_ERROR before returning carry set, which would leave a
    ; stale SYNTAX ERROR message sitting in PENDING_ERROR_MSG even after
    ; a legitimate numeric PRINT (e.g. "PRINT X") went on to succeed.
    push hl                          ; original start position — the
                                     ; probes below may advance the live
                                     ; HL on a match; BASIC_EVAL_STR_EXPR
                                     ; needs to re-parse from here, not
                                     ; from wherever a probe left off
    cp   '"'
    jr   z, .print_str_expr

    ; check for a string-variable reference (X$) before falling to the
    ; numeric path below — BASIC_DETECT_STRVAR leaves HL untouched on
    ; failure, so a plain numeric variable like "PRINT X" falls through
    ; to BASIC_EVAL_EXPR exactly as before, no regression risk
    call BASIC_DETECT_STRVAR
    jr   nc, .print_str_expr

    ; check for a string-FUNCTION call (UPPER$(...), CHR$(...), ...)
    ; next, same reason BASIC_EVAL_STR_PRIMARY's own entry tries this
    ; before a bare variable — carry set + HL unchanged on no match, so
    ; falling through to the numeric path below is exactly as safe as
    ; BASIC_DETECT_STRVAR's own failure already was
    call BASIC_TRY_EVAL_STR_FUNCTION
    jr   nc, .print_str_expr

    pop  hl                          ; not a string start after all —
                                     ; restore the original position
                                     ; (matches BASIC_DETECT_STRVAR's own
                                     ; "HL untouched on failure" contract
                                     ; exactly, just made explicit here
                                     ; since BASIC_TRY_EVAL_STR_FUNCTION
                                     ; was already probed too) and fall
                                     ; through to the numeric path,
                                     ; unchanged from before

    ; not a quote — evaluate as an expression. A bare variable is a
    ; valid expression on its own (just a primary with no operators),
    ; so this naturally subsumes what used to be a separate, narrower
    ; "PRINT single variable only" case — "PRINT x", "PRINT x+1",
    ; "PRINT 2*(3+4)" all go through the same path now.
    call BASIC_EVAL_EXPR
    jp   c, BASIC_RAISE_SYNTAX_ERROR      ; won't overwrite a more
                                         ; specific error (e.g.
                                         ; DIVISION BY ZERO) already
                                         ; recorded deeper in the
                                         ; evaluator — see that
                                         ; routine's own comments
    call BASIC_EXPECT_STATEMENT_END    ; BASIC_EXPECT_STATEMENT_END fix —
                                       ; DE (the value from BASIC_EVAL_EXPR)
                                       ; survives untouched, same pattern
                                       ; as every other rolled-out site
    ret  c
    call BASIC_COMPUTE_PRINT_ATTR         ; A = attribute byte —
                                         ; computed before
                                         ; BASIC_NUM_TO_STRING/BASIC_
                                         ; FLOAT_TO_STRING since both
                                         ; destroy BC, which the row/
                                         ; column setup below needs
    push af                              ; survive the calls below via
                                        ; the stack, same reasoning as
                                        ; every "value must survive a
                                        ; call" case in this project

    ; "Function-result float" — if the expression just evaluated was
    ; exactly one bare SQR/SIN call (see FUNC_RESULT_IS_FLOAT's own
    ; sysvars.inc comment), print its true fractional value instead of
    ; the truncated int DE already holds. FUNC_RESULT_FLOAT is always
    ; a non-negative magnitude (BASIC_FLOAT_TO_STRING's own contract),
    ; so a tracked-separately negative sign is poked into the byte
    ; immediately before the returned string — BASIC_NUM_TO_STRING
    ; always leaves at least one byte free there for a small int_part
    ; (both SQR and SIN's magnitudes are well under its 5-digit
    ; reserve — SQR's argument is a 16-bit int, so its root is never
    ; more than 3 digits), same trick rom/test_sqr_sin_visual.asm's
    ; own harness used to confirm this before it was wired in here.
    ld   a, (FUNC_RESULT_IS_FLOAT)
    or   a
    jr   z, .print_num_int
    ld   hl, FUNC_RESULT_FLOAT
    call CALC_PUSH_FP_RAW_HOME
    call BASIC_FLOAT_TO_STRING            ; HL = decimal string
    ld   a, (FUNC_RESULT_FLOAT_NEGATIVE)
    or   a
    jr   z, .print_num_common
    dec  hl
    ld   (hl), "-"
    jr   .print_num_common
.print_num_int:
    call BASIC_NUM_TO_STRING             ; HL = decimal string
.print_num_common:
    ld   a, (BASIC_OUTPUT_ROW)
    ld   b, a
    ld   a, (BASIC_OUTPUT_COL)
    ld   c, a
    pop  af                              ; A = attribute byte again
    ld   e, a
    ld   a, (CURRENT_OVER)
    ld   d, a
    ld   a, e                            ; D = CURRENT_OVER, A = attribute
    call GFX_PRINT_STRING_ATTR
    jr   .printed

.print_str_expr:
    pop  hl                          ; restore the original start
                                     ; position stashed in .after_spaces
                                     ; — ignore wherever the matching
                                     ; probe above left HL;
                                     ; BASIC_EVAL_STR_EXPR reparses the
                                     ; whole expression itself
    ld   de, PRINT_BUF
    ld   c, 63                       ; PRINT_BUF's real capacity (64
                                     ; bytes = 63 chars + null) — wider
                                     ; than every OTHER BASIC_EVAL_STR_
                                     ; EXPR caller's 31, since PRINT_BUF
                                     ; is scratch display space, not a
                                     ; 31-char scalar slot (see that
                                     ; routine's own header)
    call BASIC_EVAL_STR_EXPR          ; B = total bytes written (the
                                      ; whole "+"-chain, not just the
                                      ; first primary) — should always
                                      ; succeed here since one of the
                                      ; three probes above already
                                      ; confirmed a string primary
                                      ; starts here, but checked anyway
                                      ; rather than assumed
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ld   d, 0
    ld   e, b
    ld   hl, PRINT_BUF
    add  hl, de
    ex   de, hl                          ; DE = PRINT_BUF + B (just
                                        ; past the written content) —
                                        ; exactly what .closed expects
.closed:
    xor  a
    ld   (de), a                      ; null-terminate for GFX_PRINT_STRING_ATTR

    call BASIC_COMPUTE_PRINT_ATTR         ; A = attribute byte —
                                         ; computed before touching
                                         ; BC below, same reasoning as
                                         ; the numeric-expression path
                                         ; above
    push af
    ld   hl, PRINT_BUF
    ld   a, (BASIC_OUTPUT_ROW)
    ld   b, a
    ld   a, (BASIC_OUTPUT_COL)
    ld   c, a
    pop  af
    ld   e, a
    ld   a, (CURRENT_OVER)
    ld   d, a
    ld   a, e                            ; D = CURRENT_OVER, A = attribute
    call GFX_PRINT_STRING_ATTR

.printed:
    ld   a, b
    ld   (BASIC_OUTPUT_ROW), a
.advance_row:
    jp   BASIC_ADVANCE_OUTPUT_ROW

; ============================================================================
; BASIC_STMT_CLS
; Clears the screen (via the existing GFX_CLS kernel routine — this
; project's founding rule that BASIC only ever goes through documented
; kernel APIs, never touches hardware directly, applies here same as
; everywhere else), then repaints the attribute area to the CURRENT
; INK/PAPER/BRIGHT/FLASH/INVERSE state via BASIC_COMPUTE_PRINT_ATTR +
; GFX_FILL_ATTR — GFX_CLS itself always resets to a fixed white-paper/
; black-ink default (matching every other caller's expectations, see
; its own header), so without this second step CLS would silently
; ignore whatever PAPER/INK a program had just set, no matter what
; order they were issued in. Real gap found via user testing on
; demos/showcase.txt: PAPER before CLS was expected to fill the screen
; with that paper colour and didn't. Finally resets BASIC_OUTPUT_ROW/
; BASIC_OUTPUT_COL back to the top-left, so the next PRINT after a
; mid-program CLS starts fresh at row 0, column 0 again instead of
; wherever output had scrolled to or an earlier AT/TAB had positioned
; it. Takes no argument.
; In:  none
; Out: none (never fails — carry always clear)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_CLS:
    call GFX_CLS
    call BASIC_COMPUTE_PRINT_ATTR   ; A = current ink/paper/etc attribute
    call GFX_PAINT_ATTR
    xor  a
    ld   (BASIC_OUTPUT_ROW), a
    ld   (BASIC_OUTPUT_COL), a
    ret

; ============================================================================
; BASIC_STMT_REM
; REM is a comment — everything after the keyword itself is ignored,
; not just unparsed. Deliberately a pure no-op: the dispatcher already
; advanced HL past "REM" and its boundary character via
; BASIC_MATCH_KEYWORD_BOUNDARY before this is ever reached, and nothing
; further needs to happen with whatever text follows.
; In:  none (HL, unused, already points past "REM")
; Out: none (never fails — carry always clear)
; Destroys: none
; ============================================================================
BASIC_STMT_REM:
    or   a
    ret

; ============================================================================
; BASIC_STMT_BORDER
; Parses BORDER <expr> and sets the screen border to the low 3 bits of
; the result (kernel/graphics's GFX_SET_BORDER already masks these off,
; but the language itself only defines colours 0-7, same as every
; other colour-taking keyword in docs/basic_language_reference.md's
; screen-output table).
; In:  HL = pointer just past the BORDER keyword
; Out: none; carry set on a malformed expression (MSG_SYNTAX_ERROR
;      already recorded via BASIC_SET_PENDING_ERROR, same pattern as
;      BASIC_STMT_PRINT's own expression handling)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_BORDER:
    call BASIC_EVAL_EXPR
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    call BASIC_EXPECT_STATEMENT_END    ; BASIC_EXPECT_STATEMENT_END fix
                                       ; (see its own header) — confirms
                                       ; nothing trails the value before
                                       ; committing it
    ret  c                             ; error already recorded
    ld   a, e                      ; DE = evaluated value; only the low
                                   ; byte's low 3 bits matter for a
                                   ; border colour
    call GFX_SET_BORDER
    or   a
    ret

; ============================================================================
; BASIC_RESET_TEXT_ATTR
; Resets INK/PAPER/FLASH/INVERSE/OVER to their default state (INK 0
; black, PAPER 7 white, FLASH/INVERSE/OVER all 0) — same shape as
; BORDER_DEFAULT's own reset, called from the same two "start fresh"
; moments (cold boot and NEW), for the same reason: without this, a
; prior program's attribute state would leak into a fresh session, the
; text equivalent of the BORDER leak bug already fixed once for the
; screen edge.
; In:  none
; Out: none
; Destroys: AF
; ============================================================================
BASIC_RESET_TEXT_ATTR:
    xor  a
    ld   (CURRENT_INK), a
    ld   (CURRENT_FLASH), a
    ld   (CURRENT_INVERSE), a
    ld   (CURRENT_OVER), a
    ld   (CURRENT_BRIGHT), a
    ld   a, 7
    ld   (CURRENT_PAPER), a
    ret

; ============================================================================
; BASIC_STMT_INK / BASIC_STMT_PAPER / BASIC_STMT_FLASH /
; BASIC_STMT_INVERSE / BASIC_STMT_OVER / BASIC_STMT_TAB
; Parse <expr> and store the low byte of the result into the
; corresponding sysvar — same shape as BASIC_STMT_BORDER, just
; targeting text-attribute state (read later by
; BASIC_COMPUTE_PRINT_ATTR) or BASIC_OUTPUT_COL instead of the ULA
; border port. INK/PAPER accept 0-7 (masked the same way GFX_SET_
; BORDER masks a border colour); FLASH/INVERSE/OVER are boolean and
; only their bit 0 is kept, matching real Sinclair BASIC's own "any
; non-zero odd value means on" convention; TAB masks to 0-31
; (GFX_COLS, a clean power of 2).
;
; All six share IDENTICAL logic (parse, check end, mask, store) and
; differ only in WHICH sysvar and WHAT mask — collapsed into one
; shared body (BASIC_STMT_MASKED_EXPR_COMMON, below) plus a 3-line
; stub per keyword, rather than six near-copies of the same ~13-line
; routine. Matches this project's own established dedup precedent
; (BASIC_EXPECT_COMMA_EXPR, BASIC_PARSE_FOR_HEADER) and [stated]'s
; standing code-size priority — this consolidation was specifically
; motivated by adding BASIC_EXPECT_STATEMENT_END's own end-of-
; statement check (see that routine's header) to each of these,
; which would otherwise have meant paying that fix's cost six
; separate times on top of six copies that were already duplicated
; before the fix.
;
; BASIC_EVAL_EXPR destroys AF/BC/DE/HL (a full recursive-descent
; evaluator — see its own header), so there's no register free to
; carry "which sysvar, what mask" from the stub into the shared body
; across that call — STMT_TARGET_ADDR/STMT_TARGET_MASK (sysvars.inc)
; do that instead, in memory.
; In:  HL = pointer just past the keyword
; Out: none; carry set on a malformed expression or trailing garbage
;      (MSG_SYNTAX_ERROR already recorded via BASIC_SET_PENDING_ERROR)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_INK:
    ld   de, CURRENT_INK               ; DE, not HL -- HL is the
                                       ; caller's real text-parse
                                       ; pointer and must survive
                                       ; untouched into BASIC_EVAL_EXPR
    ld   (STMT_TARGET_ADDR), de
    ld   a, $07
    ld   (STMT_TARGET_MASK), a
    jr   BASIC_STMT_MASKED_EXPR_COMMON

BASIC_STMT_PAPER:
    ld   de, CURRENT_PAPER             ; DE, not HL -- see BASIC_STMT_
                                       ; INK's own comment above
    ld   (STMT_TARGET_ADDR), de
    ld   a, $07
    ld   (STMT_TARGET_MASK), a
    jr   BASIC_STMT_MASKED_EXPR_COMMON

BASIC_STMT_FLASH:
    ld   de, CURRENT_FLASH             ; DE, not HL -- see BASIC_STMT_
                                       ; INK's own comment above
    ld   (STMT_TARGET_ADDR), de
    ld   a, $01
    ld   (STMT_TARGET_MASK), a
    jr   BASIC_STMT_MASKED_EXPR_COMMON

BASIC_STMT_BRIGHT:
    ld   de, CURRENT_BRIGHT            ; DE, not HL -- see BASIC_STMT_
                                       ; INK's own comment above
    ld   (STMT_TARGET_ADDR), de
    ld   a, $01
    ld   (STMT_TARGET_MASK), a
    jr   BASIC_STMT_MASKED_EXPR_COMMON

BASIC_STMT_INVERSE:
    ld   de, CURRENT_INVERSE           ; DE, not HL -- see BASIC_STMT_
                                       ; INK's own comment above
    ld   (STMT_TARGET_ADDR), de
    ld   a, $01
    ld   (STMT_TARGET_MASK), a
    jr   BASIC_STMT_MASKED_EXPR_COMMON

BASIC_STMT_OVER:
    ld   de, CURRENT_OVER              ; DE, not HL -- see BASIC_STMT_
                                       ; INK's own comment above
    ld   (STMT_TARGET_ADDR), de
    ld   a, $01
    ld   (STMT_TARGET_MASK), a
    jr   BASIC_STMT_MASKED_EXPR_COMMON

; ============================================================================
; BASIC_STMT_MASKED_EXPR_COMMON
; Shared body for BASIC_STMT_INK/PAPER/FLASH/BRIGHT/INVERSE/OVER/TAB —
; see that block's own header for why this exists and why the stub-
; to-body handoff goes through memory (STMT_TARGET_ADDR/_MASK) rather
; than registers.
; In:  STMT_TARGET_ADDR/STMT_TARGET_MASK already set by the calling
;      stub; HL = pointer just past the keyword (the stub's own jp
;      preserves this — it never touches HL itself)
; Out: none; carry set on a malformed expression or trailing garbage
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_MASKED_EXPR_COMMON:
    call BASIC_EVAL_EXPR
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    call BASIC_EXPECT_STATEMENT_END    ; BASIC_EXPECT_STATEMENT_END fix
                                       ; — destroys AF/HL only, so DE
                                       ; (the parsed value) survives
    ret  c                             ; error already recorded
    ld   a, e
    ld   hl, STMT_TARGET_MASK
    and  (hl)
    ld   hl, (STMT_TARGET_ADDR)
    ld   (hl), a
    or   a
    ret

; ============================================================================
; BASIC_COMPUTE_PRINT_ATTR
; Builds the attribute byte PRINT should write at each printed cell
; from the current INK/PAPER/FLASH/INVERSE state. OVER is a bitmap
; operation rather than an attribute bit and is passed separately to
; GFX_PRINT_STRING_ATTR. Matches the same bit layout GFX_CLS's
; ATTR_DEFAULT already assumes: bit 7 = FLASH, bits 5-3 = PAPER, bits
; 2-0 = INK (bit 6/BRIGHT unused, same as everywhere else in this
; project). INVERSE swaps ink/paper at THIS read time rather than
; being folded into CURRENT_INK/PAPER when INK/PAPER/INVERSE are set —
; see sysvars.inc's own CURRENT_INVERSE comment for why.
; In:  none
; Out: A = attribute byte
; Destroys: AF, BC
; ============================================================================
BASIC_COMPUTE_PRINT_ATTR:
    ld   a, (CURRENT_INK)
    ld   b, a                    ; B = ink
    ld   a, (CURRENT_PAPER)
    ld   c, a                    ; C = paper
    ld   a, (CURRENT_INVERSE)
    or   a
    jr   z, .no_swap
    ld   a, b                    ; swap B/C (ink/paper)
    ld   b, c
    ld   c, a
.no_swap:
    ld   a, c                    ; A = paper (0-7)
    add  a, a
    add  a, a
    add  a, a                    ; paper << 3
    or   b                       ; | ink
    ld   c, a                    ; C = combined ink/paper bits so far
    ld   a, (CURRENT_BRIGHT)
    or   a
    jr   z, .no_bright
    ld   a, c
    or   $40                     ; set BRIGHT bit
    ld   c, a
.no_bright:
    ld   a, (CURRENT_FLASH)
    or   a
    jr   z, .no_flash
    ld   a, c
    or   $80                     ; set FLASH bit
    ret
.no_flash:
    ld   a, c
    ret

; ============================================================================
; BASIC_STMT_AT
; Parses AT <row-expr>,<col-expr> and positions the next PRINT
; statement there — sets BASIC_OUTPUT_ROW and BASIC_OUTPUT_COL, both
; read by BASIC_STMT_PRINT the same way it already reads
; BASIC_OUTPUT_ROW. Only affects the single PRINT that follows: once
; that PRINT runs, BASIC_ADVANCE_OUTPUT_ROW resets BASIC_OUTPUT_COL
; back to 0 for the next line, matching classic Sinclair BASIC's own
; AT behavior (a positioning command, not a persistent mode).
;
; Row is clamped into 0-23 (GFX_ROWS) rather than masked — 24 isn't a
; power of 2, so a bitmask can't cleanly bound it the way BORDER's
; AND $07 or column's AND $1F do; an out-of-range row just gets pinned
; to the last valid row instead of reporting an error, consistent
; with BORDER's own "silently keep it within valid hardware range"
; precedent. The clamp check is unsigned (a plain byte compare against
; 24), so a NEGATIVE row expression (e.g. "AT -1,5") also lands on 23
; rather than 0 — the low byte of -1 is $FF, which reads as "too high"
; the same way a genuinely too-high value would. Not fully correct for
; negative input, but an honest, documented simplification rather than
; a silent one — same spirit as OVER's own TODO above. Column IS
; masked with AND $1F since GFX_COLS (32) is a clean power of 2 (a
; negative column wraps into 0-31 via the mask instead of clamping,
; a different but equally simplified behavior, also undocumented
; anywhere as "correct" — TODO if this ever needs tightening).
; In:  HL = pointer just past the AT keyword
; Out: none; carry set on a malformed expression or a missing comma
;      (MSG_SYNTAX_ERROR already recorded via BASIC_SET_PENDING_ERROR)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_AT:
    call BASIC_EVAL_EXPR
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ld   a, e
    cp   GFX_ROWS
    jr   c, .row_in_range
    ld   a, GFX_ROWS - 1
.row_in_range:
    ld   (BASIC_OUTPUT_ROW), a

    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ","
    jp   nz, BASIC_RAISE_SYNTAX_ERROR
    inc  hl
    call BASIC_EVAL_EXPR
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    call BASIC_EXPECT_STATEMENT_END    ; BASIC_EXPECT_STATEMENT_END fix
                                       ; (destroys AF/HL only — DE/col
                                       ; survives, same as every other
                                       ; rolled-out call site)
    ret  c                             ; error already recorded
    ld   a, e
    and  $1F                     ; GFX_COLS (32) — power of 2, clean mask
    ld   (BASIC_OUTPUT_COL), a
    or   a
    ret

; ============================================================================
; BASIC_STMT_TAB
; Parses TAB <col-expr> and moves to that column on the CURRENT line —
; sets BASIC_OUTPUT_COL only, leaving BASIC_OUTPUT_ROW untouched
; (unlike AT, which sets both). Same "only affects the single
; following PRINT" lifetime as AT — see that routine's own header.
; Same masked-expr shape as INK/PAPER/FLASH/BRIGHT/INVERSE/OVER —
; folded into BASIC_STMT_MASKED_EXPR_COMMON too (see that block's own
; header).
; In:  HL = pointer just past the TAB keyword
; Out: none; carry set on a malformed expression or trailing garbage
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_TAB:
    ld   de, BASIC_OUTPUT_COL          ; DE, not HL -- see BASIC_STMT_
                                       ; INK's own comment above
    ld   (STMT_TARGET_ADDR), de
    ld   a, $1F                  ; GFX_COLS (32) — power of 2, clean mask
    ld   (STMT_TARGET_MASK), a
    jr   BASIC_STMT_MASKED_EXPR_COMMON

; ============================================================================
; BASIC_STMT_PLOT
; Parses PLOT <x-expr>,<y-expr> and sets that pixel via GFX_WRITE_PIXEL,
; using the current INK/PAPER/FLASH/INVERSE (BASIC_COMPUTE_PRINT_ATTR —
; the same attribute state text output already uses; screen hardware is
; one shared bitmap+attribute area, so this is honest reuse, not a
; coincidence) and OVER (CURRENT_OVER — the first real consumer of
; that sysvar; see its own sysvars.inc comment, written for exactly
; this).
;
; X: the screen is exactly 256 pixels wide — the low byte of the
; evaluated expression IS the whole valid range, no clamp needed, same
; as always. Y is clamped into 0-191 the same way AT's row is clamped
; (192 isn't a power of 2 either) — an out-of-range Y pins to the last
; valid row rather than reading past ROW_BASE_TABLE.
; In:  HL = pointer just past the PLOT keyword
; Out: none; carry set on a malformed expression or missing comma
; Destroys: AF, BC, DE, HL
; ============================================================================
; ============================================================================
; BASIC_EXPECT_COMMA_EXPR
; Shared parsing primitive: expects (after skipping spaces) a comma at
; HL, consumes it, then evaluates the expression that follows. Factors
; out the "comma, eval-expr, fail-on-either" sequence duplicated across
; every multi-coordinate statement (PLOT/CPLOT/FILL/LINE/BLOCK/CIRCLE)
; and the whole-program checker's own mirror of the same grammar —
; same duplication class as BASIC_PARSE_FOR_HEADER's own extraction.
; On failure, the error is already recorded (MSG_SYNTAX_ERROR via
; BASIC_SET_PENDING_ERROR) before returning — callers needing no extra
; cleanup can just propagate carry straight out (`ret c`) rather than
; jumping to a local fail label. Callers that need the PREVIOUS expr's
; value (DE) to survive across this call (PLOT/CPLOT, whose x hasn't
; been written to memory yet when this runs) must push/pop DE around
; the call themselves — this routine has no way to know the caller
; still needs it.
; In:  HL = text pointer, positioned just before the expected comma
;      (spaces before it are skipped here, same as every call site
;      used to do individually)
; Out: success — carry clear, DE = the expression's value, HL advanced
;      past it. failure — carry set, error already recorded via
;      BASIC_SET_PENDING_ERROR.
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_EXPECT_COMMA_EXPR:
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   ","
    jp   nz, BASIC_RAISE_SYNTAX_ERROR
    inc  hl
    call BASIC_EVAL_EXPR
    ret  nc
    jp   BASIC_RAISE_SYNTAX_ERROR

; ============================================================================
; BASIC_EXPECT_TO_EXPR
; Shared "TO <expr>" clause parser — same duplication class as BASIC_
; EXPECT_COMMA_EXPR above: skips spaces, requires the TO keyword at a
; real word boundary, then evaluates the expression that follows. Used
; by LINE/BLOCK's own x1/y1 parsing and FOR's end-value parsing (was
; duplicated identically across all three before this).
; In:  HL = text pointer, positioned just before the expected TO
; Out: success — DE = the expression's value, HL advanced past it.
;      failure — BASIC_RAISE_SYNTAX_ERROR already invoked (does not
;      return here, same as every call site's own original `jp c,
;      BASIC_RAISE_SYNTAX_ERROR` did)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_EXPECT_TO_EXPR:
    call BASIC_SKIP_SPACES
    ld   de, KW_TO
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jp   c, BASIC_RAISE_SYNTAX_ERROR

    call BASIC_EVAL_EXPR
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ret

; ============================================================================
; BASIC_STMT_POKE
; Parses POKE <addr-expr>,<value-expr> and writes the low byte of value
; to that address — raw memory write, deliberately NOT routed through a
; kernel/ API (see BASIC_EVAL_PRIMARY's .call_peek comment for why: the
; address is arbitrary caller-supplied data, not kernel-owned hardware/
; sysvar state). Same "expr, comma-expr, end" shape as AT/PLOT, just
; using BASIC_EXPECT_COMMA_EXPR for the second one instead of repeating
; that comma-check inline.
; In:  HL = pointer just past the POKE keyword
; Out: none; carry set (error already recorded) on a malformed
;      expression, missing comma, or trailing garbage
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_POKE:
    call BASIC_EVAL_EXPR               ; DE = address, HL advanced
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    push de                             ; save address across the
                                       ; second expression — same idiom
                                       ; BASIC_EXPECT_COMMA_EXPR's own
                                       ; header asks callers needing the
                                       ; PREVIOUS value to survive it
    call BASIC_EXPECT_COMMA_EXPR        ; DE = value, HL advanced
    jr   c, .fail
    call BASIC_EXPECT_STATEMENT_END
    jr   c, .fail
    pop  hl                             ; HL = address
    ld   a, e                           ; low byte of value
    ld   (hl), a
    or   a
    ret
.fail:
    pop  hl                             ; discard the saved address,
                                       ; keep the stack balanced —
                                       ; error already recorded by
                                       ; whichever call above failed
    scf
    ret

; ============================================================================
; BASIC_STMT_PAUSE
; Parses PAUSE <n-expr>. n=0 waits indefinitely for a keypress; n>0
; waits exactly n display-frame ticks (kernel/interrupt's FRAMES,
; INT_GET_FRAMES — see docs/basic_language_reference.md's "Program
; control" section for the exact contract, carried over unchanged from
; classic Sinclair BASIC). The n>0 wait loop keeps its target in DE
; across every INT_GET_FRAMES call rather than a sysvar, since that
; routine's own contract destroys only HL — no new sysvar needed.
; In:  HL = pointer just past the PAUSE keyword
; Out: none; carry set (error already recorded) on a malformed
;      expression or trailing garbage
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_PAUSE:
    call BASIC_EVAL_EXPR               ; DE = n, HL advanced
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    call BASIC_EXPECT_STATEMENT_END
    ret  c

    ld   a, d
    or   e
    jr   z, .wait_key                   ; n == 0 — wait for a keypress

    call INT_GET_FRAMES                 ; HL = current tick count
    add  hl, de                         ; HL = target (current + n)
    ex   de, hl                         ; DE = target, held across the
                                       ; loop below
.wait_loop:
    call INT_GET_FRAMES                 ; HL = current (destroys only
                                       ; HL, per its own contract — DE
                                       ; survives)
    or   a
    sbc  hl, de                         ; carry set while current < target
    jr   c, .wait_loop
    or   a
    ret

.wait_key:
    call IO_READ_KEY                    ; blocks until a key is read
    or   a
    ret

; ============================================================================
; BASIC_STMT_RANDOMISE
; Parses RANDOMISE <n>. n=0 resets kernel/math's RND_STATE back to its
; own "unseeded" sentinel, so the next RND() reseeds from real hardware
; entropy (the Z80 R register) exactly as a cold boot would; n<>0
; becomes the new deterministic seed directly — useful for reproducible
; "random" sequences. Same mandatory-single-expression shape as
; BORDER/PAUSE; "0 has special meaning" mirrors PAUSE's own convention
; rather than needing a separate optional-argument grammar.
; In:  HL = pointer just past the RANDOMISE keyword
; Out: none; carry set (error already recorded) on a malformed
;      expression or trailing garbage
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_RANDOMISE:
    call BASIC_EVAL_EXPR               ; DE = n, HL advanced
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    call BASIC_EXPECT_STATEMENT_END
    ret  c
    ex   de, hl                         ; HL = n, MATH_RND_SEED's own
                                       ; contract
    call MATH_RND_SEED
    or   a
    ret

; ============================================================================
; BASIC_EXPECT_STATEMENT_END
; Shared parsing primitive: confirms that parsing has genuinely reached
; the end of the current statement — the real end-of-statement gap this
; project's "Real end-to-end hardware test #1" found (BASIC_CHECK_
; ASSIGNMENT/BASIC_TRY_ASSIGNMENT declaring "x = 1c" valid because
; BASIC_EVAL_EXPR happily parses "1" and stops, leaving "c" sitting
; unconsumed and silently ignored — the exact same shape repeated
; across PLOT/LINE/CIRCLE/etc: parse the last argument, see carry
; clear, jump straight to success, no "did we actually reach the end"
; check anywhere). Every call site that currently finishes a statement
; the moment its last BASIC_EVAL_EXPR/BASIC_EXPECT_COMMA_EXPR call
; returns carry-clear has this gap; this routine is the ONE shared
; fix, matching this project's standing dedup priority and the same
; "same gap repeated N times" shape that motivated
; BASIC_EXPECT_COMMA_EXPR above.
; A statement genuinely ends at $0D (end of line) or ":" (start of the
; next colon-separated statement) — the same two terminators
; BASIC_FIND_STATEMENT_BOUNDARY itself recognizes. Spaces before
; either are skipped and don't count as trailing garbage. Anything
; else at this position (a stray digit, a bare letter, an unexpected
; operator) means real work was left over that nothing consumed —
; SYNTAX ERROR, same as every other malformed-statement case.
; Deliberately does NOT consume the terminator — callers that need to
; keep scanning (BASIC_EXEC_MULTI_STATEMENT et al.) still do their own
; colon/$0D handling afterward, unchanged; this routine only checks.
; In:  HL = text pointer, positioned just after the last thing this
;      statement parsed (spaces after it are skipped here)
; Out: success — carry clear, HL positioned at the terminator itself
;      (not consumed). failure — carry set, error already recorded via
;      BASIC_SET_PENDING_ERROR (MSG_SYNTAX_ERROR), matching
;      BASIC_EXPECT_COMMA_EXPR's own convention so callers needing no
;      extra cleanup can just propagate carry straight out (`ret c`).
; Destroys: AF, HL
; ============================================================================
BASIC_EXPECT_STATEMENT_END:
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   $0D
    jr   z, .ok
    cp   ":"
    jr   z, .ok
    jp   BASIC_RAISE_SYNTAX_ERROR
.ok:
    or   a
    ret

; ============================================================================
; BASIC_CLAMP_Y191
; Shared "clamp A to 0-191" — the exact 6-byte inline clamp PLOT/FILL/
; LINE(x2)/BLOCK(x2)/CIRCLE each did separately for their own
; y-coordinate, consolidated per this project's standing dedup priority
; (same shape as BASIC_EXPECT_STATEMENT_END/BASIC_STMT_MASKED_EXPR_COMMON
; above — a byte-identical fragment repeated at multiple call sites).
; CPLOT's cy (0-47) and cx (0-63) are deliberately NOT routed through
; this — different clamp bounds, only 2 call sites, not worth a second
; parameterized routine for that little reuse.
; In:  A = candidate y value (low byte of an evaluated expression)
; Out: A = clamped to 0-191 (191 if it was >= 192)
; Destroys: AF only
; ============================================================================
BASIC_CLAMP_Y191:
    cp   192
    ret  c
    ld   a, 191
    ret

BASIC_STMT_PLOT:
    call BASIC_EVAL_EXPR              ; DE = x
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    push de                            ; stash x (DE) across the shared
                                       ; helper below, which destroys DE
    call BASIC_EXPECT_COMMA_EXPR        ; DE = y (or carry set, error
                                        ; already recorded)
    jp   c, .comma_fail                  ; JP, not JR — target is well
                                        ; past .mode2 below (lesson 2)
    call BASIC_EXPECT_STATEMENT_END      ; BASIC_EXPECT_STATEMENT_END fix
                                        ; — confirms nothing trails y;
                                        ; destroys AF/HL only, DE (y)
                                        ; survives
    jr   c, .comma_fail                  ; error already recorded; same
                                        ; cleanup path (x still on the
                                        ; stack) works for this failure
                                        ; too
    ld   a, e
    call BASIC_CLAMP_Y191
    ld   c, a                           ; C = y (clamped)
    pop  de                              ; DE = x (restored)

    ld   b, e                            ; B = x
    push bc                              ; stash x,y across
                                         ; BASIC_COMPUTE_PRINT_ATTR,
                                         ; which destroys BC
    call BASIC_COMPUTE_PRINT_ATTR        ; A = attribute byte
    push af                              ; stash it (round-tripped
                                         ; through the same AF pair
                                         ; it's popped back into below —
                                         ; no flag/data mismatch risk)
    ld   a, (CURRENT_OVER)
    ld   e, a                            ; E = OVER flag — D/E are free
                                         ; here, untouched by
                                         ; BASIC_COMPUTE_PRINT_ATTR
    pop  af                              ; A = attribute (restored)
    pop  bc                              ; B = x, C = y (restored)
    ld   d, e                            ; D = OVER flag, GFX_WRITE_
                                         ; PIXEL's own parameter register
    call GFX_WRITE_PIXEL
    or   a
    ret

.comma_fail:
    pop  de                              ; keep the stack balanced —
                                        ; error already recorded by
                                        ; BASIC_EXPECT_COMMA_EXPR
    ret

; ============================================================================
; BASIC_STMT_CPLOT
; Parses CPLOT <cx-expr>,<cy-expr> and coarse-plots one 4x4-pixel
; quadrant via GFX_CPLOT. Same shape as BASIC_STMT_PLOT, but — unlike
; PLOT's x — CPLOT's coarse coordinates aren't a full byte's natural
; range (cx: 0-63, cy: 0-47), so both get the same explicit clamp
; PLOT's own y already gets, not just one of them.
; In:  HL = pointer just past the CPLOT keyword
; Out: none; carry set on a malformed expression or missing comma
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_CPLOT:
    call BASIC_EVAL_EXPR              ; DE = cx
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ld   a, e
    cp   64
    jr   c, .cx_in_range
    ld   a, 63
.cx_in_range:
    ld   e, a                          ; E = cx (clamped)
    push de                            ; stash cx across the shared
                                       ; helper below, which destroys DE
    call BASIC_EXPECT_COMMA_EXPR        ; DE = cy (or carry set, error
                                        ; already recorded)
    jr   c, .comma_fail
    call BASIC_EXPECT_STATEMENT_END      ; BASIC_EXPECT_STATEMENT_END fix
    jr   c, .comma_fail                  ; error already recorded; same
                                        ; cleanup path
    ld   a, e
    cp   48
    jr   c, .cy_in_range
    ld   a, 47
.cy_in_range:
    ld   c, a                           ; C = cy (clamped)
    pop  de                              ; DE = cx (restored)
    ld   b, e                            ; B = cx

    push bc
    call BASIC_COMPUTE_PRINT_ATTR
    push af
    ld   a, (CURRENT_OVER)
    ld   e, a
    pop  af
    pop  bc
    ld   d, e
    call GFX_CPLOT
    or   a
    ret

.comma_fail:
    pop  de                              ; keep the stack balanced —
                                        ; error already recorded by
                                        ; BASIC_EXPECT_COMMA_EXPR
    ret

; ============================================================================
; BASIC_STMT_MODE
; Parses MODE <n-expr> and switches video mode via GFX_SET_MODE. Only
; 0 (Normal) and 1 (High Resolution Graphics) are valid — unlike
; BORDER, which silently masks any value into range (matching real
; Sinclair convention for a colour that's genuinely fine at any of 8
; values), an out-of-range MODE has no such safe interpretation.
; Raises a real runtime error (MSG_INVALID_MODE) instead, same
; mechanism BASIC_EVAL_EXPR's own DIVISION BY ZERO check already uses
; for "this can't be known until the expression's actual value is
; seen" validation.
; 2 (64-Column) was removed 2026-08-20 — real overhead vs. value
; trade-off, freed for more core language features (see this
; project's own working memory for the accounting).
; In:  HL = pointer just past the MODE keyword
; Out: none; carry set on a malformed expression or an out-of-range
;      mode value
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_MODE:
    call BASIC_EVAL_EXPR
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    call BASIC_EXPECT_STATEMENT_END    ; BASIC_EXPECT_STATEMENT_END fix
    ret  c                             ; error already recorded
    ld   a, d
    or   a
    jr   nz, .invalid                 ; high byte nonzero -> can't be
                                      ; 0 or 1 either way
    ld   a, e
    cp   2
    jr   nc, .invalid                 ; e >= 2 -> out of range
    call GFX_SET_MODE
    or   a
    ret
.invalid:
    ld   hl, MSG_INVALID_MODE
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_STMT_BEEP
; Parses BEEP <duration-expr>,<pitch-expr> and calls kernel/sound's
; SOUND_BEEP. Same expr,expr comma shape as PLOT/AT — see that
; routine's own header. Deliberately NOT the real ROM's musical-note
; BEEP (a note number + duration, converted to frequency through the
; floating-point calculator's own note table) — that conversion alone
; is a bigger undertaking than the rest of this feature combined, and
; with no audio output in this project's own test environment to
; verify a note-to-Hz conversion against, it would be unverifiable
; guesswork layered on top of already-unverifiable guesswork. Both
; parameters here are raw integers instead: duration = number of full
; waveform cycles, pitch = the per-half-cycle busy-wait length (bigger
; = slower toggling = lower pitch) — see SOUND_BEEP's own header for
; the exact hardware mechanism.
; In:  HL = pointer just past the BEEP keyword
; Out: none; carry set on a malformed expression or missing comma
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_BEEP:
    call BASIC_EVAL_EXPR               ; DE = duration
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    push de                             ; stash duration across the
                                        ; shared comma-expr helper below
    call BASIC_EXPECT_COMMA_EXPR        ; DE = pitch (or carry set,
                                        ; error already recorded)
    jp   c, .comma_fail                 ; JP, not JR — same "target is
                                        ; well past this point" lesson
                                        ; PLOT's own .comma_fail jump
                                        ; documents
    call BASIC_EXPECT_STATEMENT_END
    jr   c, .comma_fail
    ld   b, d
    ld   c, e                            ; BC = pitch (SOUND_BEEP's
                                         ; own parameter register)
    pop  de                              ; DE = duration (restored)
    call SOUND_BEEP
    or   a
    ret
.comma_fail:
    pop  de                              ; keep the stack balanced —
                                         ; error already recorded
    ret

; ============================================================================
; BASIC_STMT_SOUND
; Parses SOUND <register-expr>,<data-expr> and calls BASIC_SOUND_EXROM.
; Same expr,expr comma shape as BEEP/PLOT/AT. Real hardware's own
; SOUND (register,data pair written straight to the AY-3-8912 via ports
; $F5/$F6 — confirmed from the ROM disassembly, see rom/exrom_sound.
; asm's own header) — this is the authentic command, unlike BEEP's own
; deliberately-narrowed reinterpretation. Only the semicolon-chained
; multi-pair grammar is left out; see rom/exrom_sound.asm for why.
; In:  HL = pointer just past the SOUND keyword
; Out: none; carry set on a malformed expression, missing comma, or an
;      out-of-range register (1-16)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_SOUND:
    call BASIC_EVAL_EXPR               ; DE = register
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    push de                             ; stash register across the
                                        ; shared comma-expr helper below
    call BASIC_EXPECT_COMMA_EXPR        ; DE = data (or carry set,
                                        ; error already recorded)
    jr   c, .comma_fail
    call BASIC_EXPECT_STATEMENT_END
    jr   c, .comma_fail
    ld   a, e
    ld   c, a                            ; C = data (low byte — the
                                         ; AY's own data registers are
                                         ; all 8-bit)
    pop  de                              ; DE = register (restored)
    ld   a, e
    ld   b, a                            ; B = register (low byte —
                                         ; BASIC_SOUND_EXROM's own
                                         ; range check rejects anything
                                         ; outside 1-16 regardless of
                                         ; what the high byte held)
    call BASIC_SOUND_EXROM
    jr   c, .bad_register
    or   a
    ret
.bad_register:
    ld   hl, MSG_INVALID_SOUND_REGISTER
    call BASIC_SET_PENDING_ERROR
    scf
    ret
.comma_fail:
    pop  de                              ; keep the stack balanced —
                                         ; error already recorded
    ret

; ============================================================================
; BASIC_STMT_FILL
; Parses FILL <x-expr>,<y-expr> and flood-fills the connected region
; from that seed point via GFX_FILL. x follows PLOT's own rule (full
; byte range, no separate clamp — it's already the natural width); y
; clamps to 0-191 same as everywhere else. Not yet mode-2-aware — see
; GFX_FILL's own header; same open gap CPLOT already has, not a new
; inconsistency.
; In:  HL = pointer just past the FILL keyword
; Out: none; carry set on a malformed expression or missing comma
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_FILL:
    call BASIC_EVAL_EXPR              ; DE = x
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ld   a, e
    ld   (GFX_FILL_X), a              ; x is safely in memory now — no
                                      ; register value needs to survive
                                      ; past this point, so (unlike an
                                      ; earlier draft of this routine)
                                      ; there is deliberately no push/
                                      ; pop de here. A stray pop right
                                      ; before storing y clobbered the
                                      ; just-computed y with this stale
                                      ; x value — found via a real
                                      ; hardware bug (FILL's seed
                                      ; landing at y=x instead of its
                                      ; own y-expression) before this
                                      ; fix.
    call BASIC_EXPECT_COMMA_EXPR      ; DE = y (or carry set, error
                                      ; already recorded)
    ret  c
    call BASIC_EXPECT_STATEMENT_END    ; BASIC_EXPECT_STATEMENT_END fix
    ret  c                             ; error already recorded
    ld   a, e
    call BASIC_CLAMP_Y191
    ld   (GFX_FILL_Y), a

    call BASIC_COMPUTE_PRINT_ATTR
    ld   (GFX_FILL_ATTR), a

    call GFX_FILL
    or   a
    ret

; ============================================================================
; BASIC_STMT_LINE
; Parses LINE <x0-expr>,<y0-expr> TO <x1-expr>,<y1-expr> and draws the
; line via GFX_LINE. Absolute coordinates for BOTH ends, QL SuperBASIC
; style, deliberately not classic Sinclair BASIC's relative-only DRAW —
; no "current position" to track before drawing the next segment.
; Every failure point tail-jumps straight to the shared BASIC_RAISE_
; SYNTAX_ERROR (see that routine's own header) rather than each
; repeating the usual 4-line error block inline.
; In:  HL = pointer just past the LINE keyword
; Out: none; carry set on a malformed expression, missing comma, or
;      missing TO
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_LINE:
    call BASIC_EVAL_EXPR
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ld   a, e
    ld   (GFX_LINE_X0), a

    call BASIC_EXPECT_COMMA_EXPR      ; DE = y0 (or carry set, error
                                      ; already recorded)
    ret  c
    ld   a, e
    call BASIC_CLAMP_Y191
    ld   (GFX_LINE_Y0), a

    call BASIC_EXPECT_TO_EXPR
    ld   a, e
    ld   (GFX_LINE_X1), a

    call BASIC_EXPECT_COMMA_EXPR      ; DE = y1 (or carry set, error
                                      ; already recorded)
    ret  c
    ld   a, e
    call BASIC_CLAMP_Y191
    ld   (GFX_LINE_Y1), a

    call BASIC_EXPECT_STATEMENT_END    ; BASIC_EXPECT_STATEMENT_END fix
    jp   c, BASIC_RAISE_SYNTAX_ERROR                ; error already recorded — all
                                        ; parsed values are already
                                        ; safely in sysvars by this
                                        ; point, nothing to unwind

    ld   a, (CURRENT_OVER)
    ld   (GFX_LINE_OVER), a

    call BASIC_COMPUTE_PRINT_ATTR
    ld   (GFX_LINE_ATTR), a
    call GFX_LINE
    or   a
    ret


; ============================================================================
; BASIC_STMT_BLOCK
; Parses BLOCK <x0-expr>,<y0-expr> TO <x1-expr>,<y1-expr> and fills the
; rectangle between the two corners via GFX_BLOCK. Normalizes corners
; into GFX_BLOCK_XMIN/XMAX
; while parsing (duplicated logic, not shared — the two need different
; comparison widths, so this mirrors LINE's own "write both sysvar
; sets, dispatch once at the end" shape rather than trying to force
; one normalization pass to serve both precisions). Min/max-via-CP
; logic verified in Python before being written here (2000 random
; pairs, zero mismatches) — the wide version reuses the identical
; comparison shape, just on 16-bit values via SBC HL,DE's carry flag
; (unsigned "less than", correct here since x is never negative).
; In:  HL = pointer just past the BLOCK keyword
; Out: none; carry set on a malformed expression, missing comma, or
;      missing TO
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_BLOCK:
    call BASIC_EVAL_EXPR
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ld   a, e
    ld   (GFX_BLOCK_XMIN), a
    ld   (GFX_BLOCK_XMAX), a          ; tentatively both = x0; corrected
                                      ; once x1 is known, below

    call BASIC_EXPECT_COMMA_EXPR      ; DE = y0 (or carry set, error
                                      ; already recorded)
    ret  c
    ld   a, e
    call BASIC_CLAMP_Y191
    ld   (GFX_BLOCK_YMIN), a
    ld   (GFX_BLOCK_YMAX), a

    call BASIC_EXPECT_TO_EXPR
    ld   a, e
    ld   b, a                          ; B = x1
    ld   a, (GFX_BLOCK_XMIN)           ; A = x0 (currently xmin==xmax)
    cp   b
    jr   c, .x1_is_max                 ; x0 < x1 -> x1 becomes xmax
    ld   a, b
    ld   (GFX_BLOCK_XMIN), a           ; x0 >= x1 -> x1 becomes xmin
    jr   .x_done
.x1_is_max:
    ld   a, b
    ld   (GFX_BLOCK_XMAX), a
.x_done:

    call BASIC_EXPECT_COMMA_EXPR      ; DE = y1 (or carry set, error
                                      ; already recorded)
    ret  c
    ld   a, e
    call BASIC_CLAMP_Y191
    ld   b, a                          ; B = y1 (clamped)
    ld   a, (GFX_BLOCK_YMIN)           ; A = y0
    cp   b
    jr   c, .y1_is_max
    ld   a, b
    ld   (GFX_BLOCK_YMIN), a
    jr   .y_done
.y1_is_max:
    ld   a, b
    ld   (GFX_BLOCK_YMAX), a
.y_done:
    call BASIC_EXPECT_STATEMENT_END    ; BASIC_EXPECT_STATEMENT_END fix
    jp   c, BASIC_RAISE_SYNTAX_ERROR                ; error already recorded — all
                                        ; parsed values are already
                                        ; safely in sysvars by this
                                        ; point, nothing to unwind

    ld   a, (CURRENT_OVER)
    ld   (GFX_BLOCK_OVER), a

    call BASIC_COMPUTE_PRINT_ATTR
    ld   (GFX_BLOCK_ATTR), a
    call GFX_BLOCK
    or   a
    ret


; ============================================================================
; BASIC_STMT_CIRCLE
; Parses CIRCLE <x-expr>,<y-expr>,<r-expr> and draws the outline via
; GFX_CIRCLE. x/y follow PLOT's own range rules (x: full byte range,
; no clamp; y: clamped to 0-191). r takes the same "low byte of the
; evaluated expression, whatever it is" convention x already uses —
; deliberately not given different handling than PLOT/LINE's own
; established x-coordinate behavior; a circle whose radius pushes it
; past the screen edge is simply clipped there by GFX_PLOT_CLIPPED,
; the same way any circle already extending past the edge would be.
; In:  HL = pointer just past the CIRCLE keyword
; Out: none; carry set on a malformed expression or missing comma
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_CIRCLE:
    call BASIC_EVAL_EXPR
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ld   a, e
    ld   (GFX_CIRCLE_XC), a

    call BASIC_EXPECT_COMMA_EXPR      ; DE = y (or carry set, error
                                      ; already recorded)
    ret  c
    ld   a, e
    call BASIC_CLAMP_Y191
    ld   (GFX_CIRCLE_YC), a

    call BASIC_EXPECT_COMMA_EXPR      ; DE = r (or carry set, error
                                      ; already recorded)
    ret  c
    ld   a, e
    ld   (GFX_CIRCLE_R), a

    call BASIC_EXPECT_STATEMENT_END    ; BASIC_EXPECT_STATEMENT_END fix
    ret  c                             ; error already recorded

    call BASIC_COMPUTE_PRINT_ATTR
    ld   (GFX_CIRCLE_ATTR), a
    ld   a, (CURRENT_OVER)
    ld   (GFX_CIRCLE_OVER), a

    call GFX_CIRCLE
    or   a
    ret

; ============================================================================
; BASIC_STMT_INPUT
; Home-side wrapper for the EXROM-resident INPUT implementation. INPUT
; is a cold blocking statement and moving it whole recovered Home-ROM
; space for its new string-variable form without duplicating parsing
; logic on both sides. See rom/exrom_input.asm.
; In:  HL = pointer just past the INPUT keyword
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_INPUT:
    call BASIC_CALL_EXROM_INLINE
    DW   $C0B4

; EXROM INPUT callback gateway. D selects a Home-resident service:
; 1=parse number, 2=numeric scalar address, 3=string scalar address,
; 4=advance output row, 5=draw one character. Each target already
; destroys D or does not consume it, so the selector countdown is safe.
BASIC_INPUT_SERVICE:
    dec  d
    jp   z, BASIC_PARSE_NUMBER
    dec  d
    jp   z, BASIC_VAR_ADDR
    dec  d
    jp   z, BASIC_STR_ADDR
    dec  d
    jp   z, BASIC_ADVANCE_OUTPUT_ROW
    jp   GFX_PUTCHAR

; ============================================================================
; BASIC_STMT_GOTO
; Recognizes GOTO <label>, looks it up, and — on success — sets
; GOTO_TARGET rather than jumping directly itself: this routine has no
; way to redirect BASIC_RUN's own execution loop, so it just leaves a
; note for that loop to act on after this statement returns (see
; BASIC_RUN's own comments for the jump-vs-advance-sequentially logic
; that reads GOTO_TARGET). A label referenced before its OWN
; definition appears later in the program (a forward GOTO) still works
; correctly, since BASIC_SCAN_LABELS (below) builds the complete label
; table before any statement executes, not incrementally as they run.
; In:  HL = text right after "GOTO " (already matched)
; Out: carry clear on success (GOTO_TARGET set); carry set on either
;      failure ("GOTO" with no label name at all — SYNTAX ERROR; a
;      named label that doesn't exist — LABEL NOT FOUND), having
;      already recorded the error via BASIC_SET_PENDING_ERROR (display
;      happens centrally in BASIC_RUN, not here)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_GOTO:
    call BASIC_SKIP_SPACES
    call BASIC_PARSE_IDENTIFIER          ; HL = name start, B = length,
                                         ; DE = real source-text
                                         ; position right after the
                                         ; identifier (BASIC_PARSE_
                                         ; IDENTIFIER's own internal
                                         ; read pointer, left where it
                                         ; stopped — see that routine's
                                         ; header)
    ld   a, b
    or   a
    jp   z, BASIC_RAISE_SYNTAX_ERROR

.have_identifier:
    push de                              ; stash the real source
                                         ; position — MEM_LABEL_LOOKUP
                                         ; destroys DE for its own
                                         ; return value below
    call MEM_LABEL_LOOKUP                   ; HL = name, B = length (still
                                           ; correct, untouched since the
                                           ; parse) -> DE = position
    jr   nc, .found

    pop  de                              ; keep the stack balanced —
                                         ; discard, error already
                                         ; recorded below
    ld   hl, MSG_LABEL_NOT_FOUND
    call BASIC_SET_PENDING_ERROR
    scf
    ret

.found:
    pop  hl                              ; HL = stashed real source
                                         ; position; DE (MEM_LABEL_
                                         ; LOOKUP's own return value —
                                         ; the label's target program
                                         ; position) is untouched by
                                         ; this POP
    call BASIC_EXPECT_STATEMENT_END      ; BASIC_EXPECT_STATEMENT_END
                                         ; fix — destroys AF/HL only,
                                         ; so DE (the target) survives.
                                         ; GOTO_TARGET deliberately NOT
                                         ; set below on failure
    ret  c                               ; error already recorded
    ld   (GOTO_TARGET), de
    or   a
    ret

; ============================================================================
; BASIC_STMT_GOSUB
; Recognizes GOSUB <label> (and CALL <label> — see below), looks it up
; exactly like GOTO does, then pushes a return position onto GOSUB_
; STACK before setting GOTO_TARGET, so BASIC_STMT_RETURN can come back
; here later. CALL is a deliberate second keyword routed to this exact
; same handler (this project's "modified stored procedures": a
; procedure is just a label you CALL instead of GOSUB, RETurn comes
; back either way — no new scoping, no LOCal variables, no parameter
; binding, per the project's own explicit scope decision here) — see
; BASIC_EXEC_STATEMENT_CONTENT's .do_gosub/.do_call, both of which call
; this same routine.
;
; The return position is computed the SAME way BASIC_RUN's own main
; loop would if this statement had just fallen through with no jump:
; MEM_LINE_NEXT on CUR_EXEC_STMT (the statement BASIC_RUN is currently
; executing — set fresh at the top of every loop iteration, so this is
; always GOSUB's own position, regardless of how deep in the call chain
; this routine is invoked from). This is deliberately NOT the pre-
; execution HL BASIC_RUN's own loop stashes on its own stack — that
; value belongs to BASIC_RUN's C stack frame, invisible to this
; routine; CUR_EXEC_STMT is the documented, intended way anything deep
; in the call chain recovers "which statement is this" (same mechanism
; BASIC_REPORT_ERROR already relies on).
;
; In:  HL = text right after "GOSUB " or "CALL " (already matched)
; Out: carry clear on success (a GOSUB_STACK entry pushed, GOTO_TARGET
;      set); carry set on failure (missing label name — SYNTAX ERROR;
;      unknown label — LABEL NOT FOUND; GOSUB_STACK already at
;      GOSUB_STACK_MAX depth — GOSUB TOO DEEP), error already recorded
;      via BASIC_SET_PENDING_ERROR
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_GOSUB:
    call BASIC_SKIP_SPACES
    call BASIC_PARSE_IDENTIFIER          ; HL = name start, B = length,
                                         ; DE = real source-text
                                         ; position right after the
                                         ; identifier — same contract
                                         ; BASIC_STMT_GOTO's own header
                                         ; documents
    ld   a, b
    or   a
    jp   z, BASIC_RAISE_SYNTAX_ERROR

    push de                              ; stash the real source
                                         ; position across the lookup —
                                         ; same reasoning as GOTO's own
    call MEM_LABEL_LOOKUP                   ; -> DE = target position
    jr   nc, .found

    pop  de                              ; keep the stack balanced —
                                         ; discard, error already
                                         ; recorded below
    ld   hl, MSG_LABEL_NOT_FOUND
    call BASIC_SET_PENDING_ERROR
    scf
    ret

.found:
    pop  hl                              ; HL = stashed real source
                                         ; position; DE (the target)
                                         ; untouched by this POP
    call BASIC_EXPECT_STATEMENT_END      ; destroys AF/HL only, so DE
                                         ; (the target) survives
    ret  c                               ; error already recorded

    push de                              ; save the target position
                                         ; across BASIC_GOSUB_PUSH_
                                         ; RETURN's own call below
    call BASIC_GOSUB_PUSH_RETURN         ; carry set on overflow
    pop  de                              ; restore the target position
    jr   c, .stack_overflow

    ld   (GOTO_TARGET), de
    or   a
    ret

.stack_overflow:
    ld   hl, MSG_GOSUB_TOO_DEEP
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_GOSUB_PUSH_RETURN
; Shared helper: computes GOSUB's own return position (MEM_LINE_NEXT on
; CUR_EXEC_STMT — see BASIC_STMT_GOSUB's own header for why that, not
; some other position) and pushes it onto GOSUB_STACK, bumping GOSUB_
; STACK_DEPTH. Split out from BASIC_STMT_GOSUB purely so that routine's
; own control flow (parse, look up, validate end-of-statement, THEN
; commit the push) doesn't have to interleave stack-array arithmetic
; with label resolution.
; In:  none (reads CUR_EXEC_STMT)
; Out: carry clear on success (GOSUB_STACK_DEPTH incremented, entry
;      written); carry set if GOSUB_STACK was already at GOSUB_
;      STACK_MAX depth (nothing written, depth unchanged)
; Destroys: AF, DE, HL
; ============================================================================
BASIC_GOSUB_PUSH_RETURN:
    ld   a, (GOSUB_STACK_DEPTH)
    cp   GOSUB_STACK_MAX
    jr   nc, .overflow

    ld   hl, (CUR_EXEC_STMT)
    call MEM_LINE_NEXT                   ; HL = return position (0 if
                                         ; GOSUB is the program's own
                                         ; last statement — a real,
                                         ; legitimate value here, NOT
                                         ; treated as an error; see
                                         ; BASIC_STMT_RETURN's own
                                         ; header for why popping this
                                         ; specific value back out needs
                                         ; special handling)
    ex   de, hl                          ; DE = return position

    ld   a, (GOSUB_STACK_DEPTH)
    add  a, a                            ; x2 — 2 bytes/entry
    ld   l, a
    ld   h, 0
    ld   bc, GOSUB_STACK
    add  hl, bc                          ; HL = &GOSUB_STACK[depth]
    ld   (hl), e
    inc  hl
    ld   (hl), d

    ld   a, (GOSUB_STACK_DEPTH)
    inc  a
    ld   (GOSUB_STACK_DEPTH), a
    or   a                               ; clear carry — success
    ret

.overflow:
    scf
    ret

; ============================================================================
; BASIC_STMT_RETURN
; Pops GOSUB_STACK and resumes at the popped position via GOTO_TARGET,
; same mechanism GOTO uses. Takes no argument — "matching the keyword
; IS the whole check", same shape as END/STOP.
;
; REAL EDGE CASE, reasoned through and guarded before it could ever be
; hit: a return position of exactly 0 is legitimate (BASIC_GOSUB_PUSH_
; RETURN's own header explains why — GOSUB was the program's last
; statement) but 0 is ALSO BASIC_RUN's own sentinel for "no jump
; pending" (see that routine's own .loop). Setting GOTO_TARGET to 0
; unguarded would NOT stop the program the way it should — BASIC_RUN
; would silently treat it as "no jump fired" and fall through to
; whatever text happens to sit right after THIS RETURN statement in
; the program's own storage order (unrelated code, not the caller's
; intent) instead of ending cleanly. Guarded here by checking for that
; specific value and using the SAME "stop, no error" contract END/STOP
; already have (carry set, PENDING_ERROR_MSG left at 0) rather than
; ever writing 0 into GOTO_TARGET.
; In:  HL = text right after "RETURN" (already matched)
; Out: carry clear + GOTO_TARGET set to the resumed position on
;      success; carry set on failure (RETURN WITHOUT GOSUB — empty
;      stack; trailing garbage after RETURN — SYNTAX ERROR) or on a
;      legitimate "GOSUB was the last statement" return (carry set,
;      no error recorded — same plain-stop contract as END/STOP)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_RETURN:
    call BASIC_EXPECT_STATEMENT_END
    ret  c

    ld   a, (GOSUB_STACK_DEPTH)
    or   a
    jr   z, .empty

    dec  a
    ld   (GOSUB_STACK_DEPTH), a
    add  a, a                            ; x2 — 2 bytes/entry
    ld   l, a
    ld   h, 0
    ld   bc, GOSUB_STACK
    add  hl, bc
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                         ; DE = the resumed position

    ld   a, d
    or   e
    jr   z, .end_of_program              ; DE = 0 — see this routine's
                                         ; own header

    ld   (GOTO_TARGET), de
    or   a
    ret

.end_of_program:
    scf                                   ; same plain-stop contract as
    ret                                   ; END/STOP — PENDING_ERROR_MSG
                                         ; is still 0, so BASIC_RUN's
                                         ; own .stop shows nothing

.empty:
    ld   hl, MSG_RETURN_WITHOUT_GOSUB
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_MATCH_ENDIF
; Recognizes the compound keyword "END IF" (or, as a harmless side
; effect of BASIC_SKIP_SPACES tolerating zero spaces, "ENDIF" written
; as one word too — not a deliberate second spelling to document or
; promote, just a natural consequence of how this is built, kept
; because rejecting it would take extra code for no real benefit).
; Deliberately does NOT use BASIC_MATCH_KEYWORD_BOUNDARY for the "END"
; part — that would require a real boundary (space or end-of-
; statement) immediately after "END", which is exactly wrong here
; since "END IF" always has more text (at least "IF") right after
; "END". This must be tried BEFORE the bare KW_END keyword check
; anywhere it matters (BASIC_EXEC_STATEMENT_CONTENT,
; BASIC_CHECK_STATEMENT_CONTENT, and this file's own IF/ELSEIF/ELSE
; block scanner below) — otherwise bare END's own boundary check
; (space counts as a valid boundary) would wrongly match the "END" of
; "END IF" first and treat the whole statement as a program-stop.
; In:  HL = content-start text pointer
; Out: carry clear + HL advanced to right after the "IF" of "END IF"
;      (the boundary itself — space or $0D — NOT consumed, same
;      convention as BASIC_MATCH_KEYWORD_BOUNDARY) on a genuine match;
;      carry set + HL unchanged otherwise
; Destroys: AF, BC, DE
; ============================================================================
BASIC_MATCH_ENDIF:
    push hl
    ld   de, KW_END
    call BASIC_MATCH_KEYWORD
    jr   c, .fail
    call BASIC_SKIP_SPACES
    ld   de, KW_IF
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .fail
    pop  bc                              ; discard the saved original
                                        ; HL — keep the advanced HL
                                        ; from the successful match
    or   a
    ret
.fail:
    pop  hl
    scf
    ret

; ============================================================================
; BASIC_IF_SCAN_STEP
; Shared by BASIC_RESOLVE_IF_CHAIN and BASIC_SKIP_TO_ENDIF below:
; classifies the statement at IF_SCAN_POS as a nested IF or a
; (possibly ours) END IF, adjusting IF_SCAN_DEPTH accordingly.
; Deliberately says nothing about ELSE/ELSEIF — those mean different
; things depending on which caller is scanning (a live alternative
; branch to resolve, vs. a sibling to skip straight past), so each
; caller checks those itself, and only after confirming via
; IF_SCAN_DEPTH that the current line isn't inside some inner nested
; IF block.
; In:  none (reads IF_SCAN_POS)
; Out: A = 0 (an ordinary line — not IF, not END IF at ALL, or a
;      nested END IF that just closed an inner block, depth already
;      adjusted either way, nothing more to classify), 1 (a nested IF —
;      IF_SCAN_DEPTH incremented), or 2 (this IS the matching END IF
;      at depth 0 — depth left alone, caller should stop scanning here)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_IF_SCAN_STEP:
    ld   hl, (IF_SCAN_POS)
    inc  hl
    inc  hl                              ; content start
    ld   de, KW_IF
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .check_end
    ld   a, (IF_SCAN_DEPTH)
    inc  a
    ld   (IF_SCAN_DEPTH), a
    ld   a, 1
    ret

.check_end:
    ld   hl, (IF_SCAN_POS)
    inc  hl
    inc  hl
    call BASIC_MATCH_ENDIF
    jr   c, .ordinary
    ld   a, (IF_SCAN_DEPTH)
    or   a
    jr   z, .found
    dec  a
    ld   (IF_SCAN_DEPTH), a
.ordinary:
    xor  a
    ret
.found:
    ld   a, 2
    ret

; ============================================================================
; BASIC_RESOLVE_IF_CHAIN
; Called when an IF's (or, via the scan below, an ELSEIF's) own
; condition was false. Scans forward statement by statement, tracking
; nested IF/END IF depth via BASIC_IF_SCAN_STEP, looking for THIS
; block's own ELSEIF, ELSE, or END IF at depth 0:
;   - a depth-0 ELSEIF has its OWN condition evaluated right here,
;     inline, during the scan — if true, this IS the branch to take;
;     if false, the scan just keeps going past it, looking for the
;     NEXT depth-0 branch. This is what lets BASIC_STMT_ELSEIF's own
;     top-level dispatch handler stay dead simple (see below) — it is
;     ONLY ever reached by falling through after a taken branch
;     finishes, never by a landing scan, so it can unconditionally
;     mean "skip to END IF" with no ambiguity about why it's running.
;   - a depth-0 ELSE is unconditional — first one found ends the scan.
;   - a depth-0 END IF with no ELSEIF/ELSE having matched means no
;     branch of this IF was taken at all — the whole thing is skipped.
; In every case the resolved target lands on the STATEMENT AFTER an
; ELSEIF/ELSE (the start of that branch's actual body — ELSE/ELSEIF's
; own statement handler is deliberately never reached this way), or
; directly ON an END IF (itself a no-op, so landing there needs
; nothing special).
; In:  HL = statement pointer to begin scanning from (the statement
;      immediately after the IF/ELSEIF whose condition just failed)
; Out: carry clear + GOTO_TARGET set to where execution should
;      continue; carry set + a pending error recorded (malformed
;      ELSEIF condition, or the program ran out before finding a
;      matching END IF at all) otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_RESOLVE_IF_CHAIN:
    ld   (IF_SCAN_POS), hl
    xor  a
    ld   (IF_SCAN_DEPTH), a

.loop:
    ld   hl, (IF_SCAN_POS)
    ld   a, h
    or   l
    jr   z, .missing_endif

    call BASIC_IF_SCAN_STEP
    cp   1
    jr   z, .advance
    cp   2
    jr   z, .found_endif

    ; A=0 (ordinary at whatever depth resulted) — only a depth-0 line
    ; can be a branch of OUR chain
    ld   a, (IF_SCAN_DEPTH)
    or   a
    jr   nz, .advance

    ld   hl, (IF_SCAN_POS)
    inc  hl
    inc  hl
    ld   de, KW_ELSEIF
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .check_else

    call BASIC_SKIP_SPACES
    call BASIC_EVAL_CONDITION
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    push de                               ; save the ELSEIF's own
                                         ; result across the THEN
                                         ; check below, which destroys
                                         ; DE for its own keyword
                                         ; pointer — same reasoning as
                                         ; BASIC_STMT_IF's IF_TEMP_RESULT,
                                         ; just via the stack instead
                                         ; since nothing else needs to
                                         ; survive alongside it here
    call BASIC_SKIP_SPACES
    ld   de, KW_THEN
    call BASIC_MATCH_KEYWORD_BOUNDARY     ; ELSEIF requires THEN too,
                                         ; matching IF's own grammar —
                                         ; BASIC_CHECK_STATEMENT_CONTENT
                                         ; validates this same
                                         ; requirement statically
    jr   c, .elseif_then_fail
    pop  de
    ld   a, d
    or   e
    jr   z, .advance                      ; this ELSEIF is false — keep
                                         ; scanning for the next branch
    jr   .take_branch                      ; true — this is the one
.elseif_then_fail:
    pop  af                                ; discard the saved result,
                                          ; balance the stack
    jp   BASIC_RAISE_SYNTAX_ERROR

.check_else:
    ld   hl, (IF_SCAN_POS)
    inc  hl
    inc  hl
    ld   de, KW_ELSE
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .advance
.take_branch:
    ld   hl, (IF_SCAN_POS)
    call MEM_LINE_NEXT
    ld   (GOTO_TARGET), hl
    or   a
    ret

.found_endif:
    ld   hl, (IF_SCAN_POS)
    ld   (GOTO_TARGET), hl
    or   a
    ret

.advance:
    ld   hl, (IF_SCAN_POS)
    call MEM_LINE_NEXT
    ld   (IF_SCAN_POS), hl
    jr   .loop

.missing_endif:
    ld   hl, MSG_MISSING_ENDIF
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_SKIP_TO_ENDIF
; Scans forward from a given statement, tracking nested IF/END IF
; depth via BASIC_IF_SCAN_STEP exactly like BASIC_RESOLVE_IF_CHAIN
; above, but ignoring ELSEIF/ELSE entirely — used when a branch's own
; body just finished executing and control falls through into the
; NEXT ELSEIF/ELSE/END IF of the SAME chain, all of which are now
; irrelevant siblings that must be skipped in their entirety, landing
; only on the chain's own END IF.
; In:  HL = statement pointer to begin scanning from
; Out: carry clear + GOTO_TARGET set to the matching END IF; carry set
;      + a pending error recorded if the program runs out first
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_SKIP_TO_ENDIF:
    ld   (IF_SCAN_POS), hl
    xor  a
    ld   (IF_SCAN_DEPTH), a

.loop:
    ld   hl, (IF_SCAN_POS)
    ld   a, h
    or   l
    jr   z, .missing_endif
    call BASIC_IF_SCAN_STEP
    cp   2
    jr   z, .found
    ld   hl, (IF_SCAN_POS)
    call MEM_LINE_NEXT
    ld   (IF_SCAN_POS), hl
    jr   .loop
.found:
    ld   hl, (IF_SCAN_POS)
    ld   (GOTO_TARGET), hl
    or   a
    ret

.missing_endif:
    ld   hl, MSG_MISSING_ENDIF
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_STMT_IF
; Handles both the block form (IF <cond> THEN, nothing else on the
; line — body follows as its own statements, up to a matching ELSEIF/
; ELSE/END IF) and the single-line short form (IF <cond> THEN
; <statement>, all on one line, no END IF needed — classic Sinclair-
; style, and possible here specifically BECAUSE this project already
; stores one whole typed line as one statement's text: the trailing
; text after THEN is just more of THIS statement's own content, not a
; separate stored statement, so no colon/multi-statement-line support
; is needed to make it work).
;
; Which form applies is decided by what's left after THEN: end-of-
; statement ($0D) means block form; anything else is the single-line
; form's own statement text, dispatched straight into
; BASIC_EXEC_STATEMENT_CONTENT — the same entry point
; BASIC_EXEC_STATEMENT itself uses after skipping a statement's length
; prefix, reused here directly on the remaining mid-statement text
; instead (see that split's own header comment).
;
; The condition's 0/1 result has to be saved somewhere OTHER than DE
; before the THEN keyword is matched, since BASIC_MATCH_KEYWORD_
; BOUNDARY destroys DE for its own reference-keyword-pointer argument —
; IF_TEMP_RESULT exists for exactly this, one byte, always exactly 0
; or 1.
; In:  HL = text right after "IF" (space not yet skipped — same
;      convention BASIC_STMT_GOTO already uses for text right after
;      its own keyword)
; Out: carry clear on success (either the true branch's body is about
;      to run via ordinary fallthrough, GOTO_TARGET has been set to
;      skip to the right place, or the single-line form's own
;      statement has been dispatched and its carry propagated); carry
;      set + a pending error recorded on a malformed condition or
;      missing THEN
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_IF:
    call BASIC_SKIP_SPACES
    call BASIC_EVAL_CONDITION
    jp   c, BASIC_RAISE_SYNTAX_ERROR

    ld   a, e
    ld   (IF_TEMP_RESULT), a

    call BASIC_SKIP_SPACES
    ld   de, KW_THEN
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jp   c, BASIC_RAISE_SYNTAX_ERROR

    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   $0D
    jr   z, .block_form
    ; --- single-line form: HL = the trailing statement's own text ---
    ld   a, (IF_TEMP_RESULT)
    or   a
    jr   z, .single_line_false
    jp   BASIC_EXEC_MULTI_STATEMENT         ; tail-jump — its own
                                           ; carry/error becomes ours
                                           ; directly, exactly as if
                                           ; this had been a normal
                                           ; top-level statement. Goes
                                           ; through the colon-splitter
                                           ; (not BASIC_EXEC_STATEMENT_
                                           ; CONTENT directly anymore),
                                           ; so "IF x THEN a=1: b=2" now
                                           ; runs both a=1 AND b=2, not
                                           ; just the first
.single_line_false:
    or   a
    ret

.block_form:
    ld   a, (IF_TEMP_RESULT)
    or   a
    jr   nz, .true_fallthrough
    ; false — resolve which branch (if any) of this IF actually runs
    ld   hl, (CUR_EXEC_STMT)
    call MEM_LINE_NEXT
    jp   BASIC_RESOLVE_IF_CHAIN
.true_fallthrough:
    or   a
    ret

; ============================================================================
; BASIC_STMT_ELSE_OR_ELSEIF
; Shared handler for both ELSE and ELSEIF's top-level dispatch. Both
; keywords are, by construction, ONLY ever reached this way via
; ordinary sequential fallthrough — the preceding branch's body just
; finished, and execution naturally advanced to the very next
; statement, which the IF-chain's own grammar guarantees is one of
; ELSEIF/ELSE/END IF. (A false condition earlier in the chain never
; lands execution exactly ON an ELSE, and an ELSEIF being tried as a
; live alternative is resolved entirely INSIDE BASIC_RESOLVE_IF_CHAIN's
; own scan, never by dispatching to this routine — see that routine's
; own header for why.) So this always means exactly one thing: skip
; forward to this chain's own END IF, discarding every remaining
; sibling branch along the way.
; In:  none (reads CUR_EXEC_STMT — set by BASIC_RUN's loop before
;      every statement executes)
; Out: carry clear + GOTO_TARGET set to the matching END IF; carry set
;      + a pending error recorded if the program runs out first
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_ELSE_OR_ELSEIF:
    ld   hl, (CUR_EXEC_STMT)
    call MEM_LINE_NEXT
    jr   BASIC_SKIP_TO_ENDIF

; ============================================================================
; BASIC_FOR_SCAN_STEP
; FOR/NEXT's own equivalent of BASIC_IF_SCAN_STEP above — classifies
; the statement at FOR_SCAN_POS as a nested FOR or a (possibly ours)
; NEXT, adjusting FOR_SCAN_DEPTH accordingly. Deliberately ignores
; IF/END IF entirely, same independence IF's own scan gives FOR/NEXT —
; these are two separate nesting structures that can freely interleave
; (a FOR body can contain an IF, an IF branch can contain a FOR), and
; each scan only tracks its own construct's depth.
; In:  none (reads FOR_SCAN_POS)
; Out: A = 0 (an ordinary line, or a nested NEXT that just closed an
;      inner FOR — depth already adjusted either way), 1 (a nested
;      FOR — FOR_SCAN_DEPTH incremented), or 2 (this IS the matching
;      NEXT at depth 0 — depth left alone, caller should stop scanning
;      here)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_FOR_SCAN_STEP:
    ld   hl, (FOR_SCAN_POS)
    inc  hl
    inc  hl                              ; content start
    ld   de, KW_FOR
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .check_next
    ld   a, (FOR_SCAN_DEPTH)
    inc  a
    ld   (FOR_SCAN_DEPTH), a
    ld   a, 1
    ret

.check_next:
    ld   hl, (FOR_SCAN_POS)
    inc  hl
    inc  hl
    ld   de, KW_NEXT
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .ordinary
    ld   a, (FOR_SCAN_DEPTH)
    or   a
    jr   z, .found
    dec  a
    ld   (FOR_SCAN_DEPTH), a
.ordinary:
    xor  a
    ret
.found:
    ld   a, 2
    ret

; ============================================================================
; BASIC_SKIP_TO_NEXT
; Scans forward from a given statement, tracking nested FOR/NEXT depth
; via BASIC_FOR_SCAN_STEP, used when a FOR's own initial start/end/step
; already fail its continue-condition — the whole loop body must be
; skipped without ever being entered (no FOR_STACK entry is pushed in
; this case at all).
;
; Unlike BASIC_SKIP_TO_ENDIF (which lands GOTO_TARGET directly ON the
; matching END IF — a genuine no-op no matter how it's reached), this
; must land PAST the matching NEXT instead: NEXT is never a no-op, it
; always tries to increment/re-check/pop whatever's on top of
; FOR_STACK, and landing execution exactly on a NEXT whose own FOR was
; never entered (so never pushed anything) would wrongly act on some
; OUTER loop's live entry instead.
; In:  HL = statement pointer to begin scanning from (the statement
;      immediately after the FOR whose condition just failed)
; Out: carry clear + GOTO_TARGET set to the statement right after the
;      matching NEXT; carry set + a pending error recorded (the
;      program ran out before finding a matching NEXT at all)
;      otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_SKIP_TO_NEXT:
    ld   (FOR_SCAN_POS), hl
    xor  a
    ld   (FOR_SCAN_DEPTH), a

.loop:
    ld   hl, (FOR_SCAN_POS)
    ld   a, h
    or   l
    jr   z, .missing_next

    call BASIC_FOR_SCAN_STEP
    cp   2
    jr   z, .found
    ld   hl, (FOR_SCAN_POS)
    call MEM_LINE_NEXT
    ld   (FOR_SCAN_POS), hl
    jr   .loop
.found:
    ld   hl, (FOR_SCAN_POS)               ; this IS the matching NEXT
    call MEM_LINE_NEXT                    ; skip PAST it — see header
    ld   (GOTO_TARGET), hl
    or   a
    ret

.missing_next:
    ld   hl, MSG_MISSING_NEXT
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_FOR_ENTRY_ADDR
; Shared by BASIC_STMT_FOR (pushing a new entry) and BASIC_STMT_NEXT
; (looking up the top entry) — both need "the address of FOR_STACK
; entry index A", previously duplicated inline in each.
; In:  A = FOR_STACK index (0-based)
; Out: HL = address of that index's own 7-byte entry within FOR_STACK
; Destroys: AF, DE
; ============================================================================
BASIC_FOR_ENTRY_ADDR:
    ld   l, a
    ld   h, 0
    ld   d, h
    ld   e, l                              ; DE = index (copy)
    add  hl, hl                            ; x2
    add  hl, hl                            ; x4
    add  hl, hl                            ; x8
    or   a
    sbc  hl, de                            ; x8 - x1 = x7
    ld   de, FOR_STACK
    add  hl, de
    ret

; ============================================================================
; BASIC_PARSE_FOR_HEADER
; FOR <var> = <start> TO <end> [STEP <step>]'s header grammar, shared
; by BASIC_STMT_FOR (real execution) and BASIC_CHECK_STATEMENT_CONTENT's
; own .check_for (static validation) — previously duplicated in full
; between the two, same as IF/ELSEIF's own check/exec split accepts
; elsewhere, but FOR's header is long enough that duplicating it was a
; real, worthwhile-to-remove cost rather than a harmless small overlap.
; Harmless for the static checker to call this for real: it writes
; FOR_TEMP_VAR/START/END/STEP as a side effect, but those are transient
; scratch only ever consumed by BASIC_STMT_FOR itself during a REAL
; run, always freshly reparsed before any actual FOR executes — a
; check-time call overwriting them has no effect on program behavior.
; In:  HL = text right after "FOR" (space not yet skipped)
; Out: carry clear on success (FOR_TEMP_VAR/START/END/STEP populated,
;      HL advanced past the whole header); carry set + a pending error
;      already recorded on a malformed header
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_PARSE_FOR_HEADER:
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    call BASIC_VALIDATE_VAR_LETTER
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ld   (FOR_TEMP_VAR), a
    inc  hl

    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   "="
    jp   nz, BASIC_RAISE_SYNTAX_ERROR
    inc  hl

    call BASIC_EVAL_EXPR                   ; DE = start value
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ld   (FOR_TEMP_START), de

    call BASIC_EXPECT_TO_EXPR                   ; DE = end value
    ld   (FOR_TEMP_END), de

    call BASIC_SKIP_SPACES
    ld   de, KW_STEP
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   c, .no_step
    call BASIC_EVAL_EXPR                   ; DE = step value
    jp   c, BASIC_RAISE_SYNTAX_ERROR
    ld   (FOR_TEMP_STEP), de
    or   a
    ret

.no_step:
    ld   de, 1
    ld   (FOR_TEMP_STEP), de
    or   a
    ret

; ============================================================================
; BASIC_STMT_FOR
; FOR <var> = <start> TO <end> [STEP <step>] — always block form (no
; single-line short form the way IF has one; a loop body of exactly
; one statement still needs its own NEXT on the following line).
; Header grammar itself lives in BASIC_PARSE_FOR_HEADER (shared with
; the static checker — see that routine's own header); this routine
; picks up right after a successfully parsed header and decides
; whether the loop is even entered at all: if the very first check
; already fails (e.g. "FOR I = 5 TO 1" with the default STEP 1), the
; whole body is skipped via BASIC_SKIP_TO_NEXT and NO FOR_STACK entry
; is pushed — matching real BASIC's classic "a FOR loop whose start is
; already past its end never runs its body, not even once" semantics.
; STEP 0 is accepted without special-casing (var never advances, so
; the loop runs forever if start/end otherwise allow entry) —
; genuinely useful for a deliberate infinite loop with EXIT-less
; structure, not guarded against here any more than QL SuperBASIC
; itself guards against it.
; In:  HL = text right after "FOR" (space not yet skipped, same
;      convention every other BASIC_STMT_* here uses)
; Out: carry clear on success (either the loop was entered — var
;      assigned, a FOR_STACK entry pushed, falling through into the
;      body — or the whole thing was skipped via BASIC_SKIP_TO_NEXT);
;      carry set + a pending error recorded on a malformed header, a
;      missing matching NEXT, or FOR_STACK_MAX nesting exceeded
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_FOR:
    call BASIC_PARSE_FOR_HEADER
    ret  c                                 ; malformed header — error
                                          ; already recorded

    ld   a, (FOR_TEMP_STEP+1)              ; step's high byte -> sign
    bit  7, a
    jr   nz, .neg_step    ; step >= 0: enter the loop unless start > end
    ld   hl, (FOR_TEMP_START)
    ld   de, (FOR_TEMP_END)
    call MATH_COMPARE16
    cp   1
    jr   z, .dont_enter
    jr   .enter
.neg_step:
    ; step < 0: enter the loop unless start < end
    ld   hl, (FOR_TEMP_START)
    ld   de, (FOR_TEMP_END)
    call MATH_COMPARE16
    cp   $FF
    jr   z, .dont_enter
    ; fall through to .enter

.enter:
    ld   a, (FOR_STACK_DEPTH)
    cp   FOR_STACK_MAX
    jp   nc, BASIC_RAISE_SYNTAX_ERROR

    ; var = start
    ld   a, (FOR_TEMP_VAR)
    call BASIC_VAR_ADDR
    ret  c                                 ; pool exhausted — error
                                          ; already recorded
    ld   de, (FOR_TEMP_START)
    ld   (hl), e
    inc  hl
    ld   (hl), d

    ld   a, (FOR_STACK_DEPTH)
    call BASIC_FOR_ENTRY_ADDR
    ld   (FOR_ENTRY_PTR), hl

    ; write the entry: var, end, step, then body-start
    ld   a, (FOR_TEMP_VAR)
    ld   (hl), a
    inc  hl
    ld   de, (FOR_TEMP_END)
    ld   (hl), e
    inc  hl
    ld   (hl), d
    inc  hl
    ld   de, (FOR_TEMP_STEP)
    ld   (hl), e
    inc  hl
    ld   (hl), d
    inc  hl                                ; HL = entry+5, the body-start
                                          ; field's own write position
    push hl                                ; survive MEM_LINE_NEXT below
                                          ; (destroys AF/BC/DE/HL) — same
                                          ; reasoning as this sysvar's
                                          ; own header comment
    ld   hl, (CUR_EXEC_STMT)
    call MEM_LINE_NEXT                     ; HL = the loop body's first
                                          ; statement (this FOR's own
                                          ; "body-start")
    ex   de, hl                            ; DE = body-start value
    pop  hl                                ; HL = write position (entry+5)
    ld   (hl), e
    inc  hl
    ld   (hl), d

    ld   a, (FOR_STACK_DEPTH)
    inc  a
    ld   (FOR_STACK_DEPTH), a

    or   a
    ret                                     ; fall through into the
                                          ; body via ordinary sequential
                                          ; execution, same as IF's own
                                          ; true-branch fallthrough

.dont_enter:
    ld   hl, (CUR_EXEC_STMT)
    call MEM_LINE_NEXT
    jp   BASIC_SKIP_TO_NEXT

; ============================================================================
; BASIC_STMT_NEXT
; NEXT [<var>] — closes the innermost open FOR loop (FOR_STACK's own
; top entry). The variable name is optional, matching classic BASIC's
; own "bare NEXT" convention (not just QL SuperBASIC's own always-
; named-loop convention) — since [stated] chose NEXT over END FOR
; specifically to match that classic-BASIC feel; when given, it's
; checked against the top entry's own variable and rejected as a
; mismatch if it doesn't match, catching a malformed/misnested program
; the same defensive way FOR_STACK_DEPTH==0 is caught below, rather
; than silently acting on the wrong loop.
;
; Reached only by ordinary sequential fallthrough — the loop body's
; last statement just finished — same assumption BASIC_STMT_
; ELSE_OR_ELSEIF makes about its own dispatch.
; In:  HL = text right after "NEXT" (space not yet skipped)
; Out: carry clear on success (either GOTO_TARGET set to loop back to
;      the body-start for another iteration, or the FOR_STACK entry
;      popped and execution falls through past this NEXT); carry set +
;      a pending error recorded if there's no open FOR loop at all, or
;      the given variable doesn't match the innermost one
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_NEXT:
    call BASIC_SKIP_SPACES
    ld   a, (FOR_STACK_DEPTH)
    or   a
    jp   z, .no_for

    ld   a, (hl)
    call BASIC_VALIDATE_VAR_LETTER
    jr   c, .no_var_given
    ld   b, a                              ; B = given letter (uppercase)
    inc  hl                                ; advance past the letter —
                                           ; needed so the end-of-
                                           ; statement check below sees
                                           ; the right position
    jr   .have_var_flag
.no_var_given:
    ld   b, 0                              ; B = 0 means "no var given"
.have_var_flag:
    push bc                                ; stash the var flag (B)
                                           ; across the check below —
                                           ; destroys AF/HL only, but B
                                           ; lives in BC, easiest just
                                           ; to push the pair (C is
                                           ; don't-care either side)
    call BASIC_EXPECT_STATEMENT_END        ; BASIC_EXPECT_STATEMENT_END
                                           ; fix — bare NEXT or NEXT
                                           ; <var>, nothing else legal
                                           ; (e.g. "NEXT xy" is
                                           ; malformed, same gap class
                                           ; as every other statement
                                           ; here)
    jp   c, .end_fail
    pop  bc

    ; entry address = FOR_STACK + (FOR_STACK_DEPTH-1)*7 — the top entry
    ld   a, (FOR_STACK_DEPTH)
    dec  a
    call BASIC_FOR_ENTRY_ADDR
    ld   (FOR_ENTRY_PTR), hl

    ld   a, b
    or   a
    jr   z, .var_ok
    ld   hl, (FOR_ENTRY_PTR)
    ld   a, (hl)
    cp   b
    jp   nz, BASIC_RAISE_SYNTAX_ERROR
.var_ok:

    ; new value = current value + step
    ld   hl, (FOR_ENTRY_PTR)
    ld   a, (hl)
    call BASIC_VAR_ADDR
    ret  c                                 ; pool exhausted — error
                                          ; already recorded (shouldn't
                                          ; be reachable in practice,
                                          ; since FOR already created
                                          ; this same letter, but never
                                          ; skip the check)
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                           ; DE = current value
    push de

    ld   hl, (FOR_ENTRY_PTR)
    inc  hl
    inc  hl
    inc  hl                                ; entry+3 = step LSB
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                           ; DE = step

    pop  hl                                ; HL = current value
    call MATH_ADD16                        ; HL = new value
    ld   (FOR_NEXT_NEWVAL), hl

    ld   hl, (FOR_ENTRY_PTR)
    ld   a, (hl)
    call BASIC_VAR_ADDR
    ret  c                                 ; pool exhausted — error
                                          ; already recorded (same
                                          ; "shouldn't happen, still
                                          ; check" reasoning above)
    ld   de, (FOR_NEXT_NEWVAL)
    ld   (hl), e
    inc  hl
    ld   (hl), d

    ; re-check the continue condition against the (now stale) step sign
    ld   hl, (FOR_ENTRY_PTR)
    inc  hl
    inc  hl
    inc  hl
    inc  hl                                ; entry+4 = step MSB
    ld   a, (hl)
    bit  7, a
    jr   nz, .neg_step_check
    ld   hl, (FOR_ENTRY_PTR)
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                           ; DE = end value
    ld   hl, (FOR_NEXT_NEWVAL)
    call MATH_COMPARE16
    cp   1
    jr   z, .loop_done
    jr   .loop_continue
.neg_step_check:
    ld   hl, (FOR_ENTRY_PTR)
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                           ; DE = end value
    ld   hl, (FOR_NEXT_NEWVAL)
    call MATH_COMPARE16
    cp   $FF
    jr   z, .loop_done    ; fall through to .loop_continue

.loop_continue:
    ld   hl, (FOR_ENTRY_PTR)
    inc  hl
    inc  hl
    inc  hl
    inc  hl
    inc  hl                                ; entry+5 = body-start
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   (GOTO_TARGET), de
    or   a
    ret

.loop_done:
    ld   a, (FOR_STACK_DEPTH)
    dec  a
    ld   (FOR_STACK_DEPTH), a
    or   a
    ret

.no_for:
    ld   hl, MSG_NEXT_WITHOUT_FOR
    call BASIC_SET_PENDING_ERROR
    scf
    ret

.end_fail:
    pop  bc                                ; keep the stack balanced —
                                           ; error already recorded by
                                           ; BASIC_EXPECT_STATEMENT_END
    ret

; ============================================================================
; BASIC_STMT_EXIT
; EXIT FOR — breaks out of the innermost open FOR loop early, without
; leaving the enclosing program (see docs/basic_language_reference.md's
; "RETurn vs. EXIT" — RETurn is a completely separate mechanism for
; GOSUB/procedures, not built yet, don't conflate the two).
;
; Deliberately "EXIT FOR", not bare "EXIT" the way NEXT accepts a bare
; form: the language design already documents "EXIT <name>" as the
; general form REPeat will use once built, to disambiguate which of
; several nested named loops is being exited. Bare "EXIT" isn't
; reserved for anything yet, but consuming it now for FOR specifically
; — a construct that has no name at all — would mean guessing how it
; ought to interact with REPeat's own named-exit matching later.
; "EXIT FOR" sidesteps that guess entirely: unambiguous today, and
; doesn't claim territory a not-yet-built feature might need.
;
; Mechanically: reuses exactly the same "pop FOR_STACK, scan forward to
; the matching NEXT" shape FOR's own "never entered" skip path already
; established (BASIC_SKIP_TO_NEXT) — no new scanning logic needed.
; In:  HL = text right after "EXIT" (space not yet skipped)
; Out: carry clear + GOTO_TARGET set past the matching NEXT, FOR_STACK
;      popped; carry set + a pending error recorded if there's no open
;      FOR loop at all, or the trailing syntax is malformed
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_EXIT:
    call BASIC_SKIP_SPACES
    ld   de, KW_FOR
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jp   c, BASIC_RAISE_SYNTAX_ERROR      ; only "EXIT FOR" is valid —
                                         ; no other loop construct
                                         ; exists yet to exit

    call BASIC_EXPECT_STATEMENT_END
    ret  c                                ; error already recorded

    ld   a, (FOR_STACK_DEPTH)
    or   a
    jr   z, .no_for
    dec  a
    ld   (FOR_STACK_DEPTH), a              ; pop the innermost entry —
                                           ; same FOR_STACK_DEPTH--
                                           ; NEXT's own .loop_done does
                                           ; once a loop genuinely ends

    ld   hl, (CUR_EXEC_STMT)
    call MEM_LINE_NEXT
    jp   BASIC_SKIP_TO_NEXT                ; scans forward from just
                                           ; after this EXIT, finds the
                                           ; (now-popped) loop's own
                                           ; matching NEXT, sets
                                           ; GOTO_TARGET past it —
                                           ; propagates its own carry/
                                           ; error (MSG_MISSING_NEXT) if
                                           ; the program runs out first
.no_for:
    ld   hl, MSG_EXIT_WITHOUT_FOR
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_SPRITE_EXROM
; Thin Home-side wrapper: SPRITE GRAB/SHOW/HIDE and everything they
; depend on (parse-slot, per-slot buffer addressing, range checks) now
; live in EXROM (rom/exrom_sprite.asm) — moved there whole in a ROM-
; shrink pass (2026-08-22) once Phase 3's string work left only 159
; Home ROM bytes free. Same "page in / call the fixed entry / page
; out" shape as BASIC_SAVE_EXROM/BASIC_SOUND_EXROM above, at EXROM_
; ENTRY_SPRITE's own $C054 (rom/exrom_checker.asm's entry-stub block).
; In:  HL = text right after "SPRITE"
; Out: carry clear on success; carry set + error already recorded
;      otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_SPRITE_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C054

; ============================================================================
; BASIC_SPRITE_HIT_EXROM
; Thin wrapper for HIT(slot1,slot2) — rom/exrom_sprite.asm's own
; BASIC_SPRITE_HIT, reached via its dedicated entry stub ($C096, added
; alongside SPRITE MOVE and the SPRITE_SLOT_MAX increase, 2026-08-23).
; Takes its two slot numbers in HL/DE (not A) — deliberately: this
; trampoline's own magic-check preamble clobbers A (see EDITOR_WRAP_
; OFFSET_TO_ROWCOL's own header, rom/exrom_editor.asm, for the full
; bug writeup behind that rule), and HL/DE survive it untouched.
; In:  HL = slot1, DE = slot2
; Out: HL = 1 or 0
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_SPRITE_HIT_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C096

; ============================================================================
; BASIC_SCAN_LABELS_EXROM / BASIC_FULL_CHECK_EXROM /
; BASIC_CHECK_STATEMENT_EXROM
; Thin Home-side wrappers: BASIC_SCAN_LABELS, BASIC_CHECK_PROGRAM, and
; the per-statement grammar checker they depend on (BASIC_CHECK_
; ASSIGNMENT/BASIC_CHECK_STATEMENT/BASIC_CHECK_STATEMENT_CONTENT) now
; all live in EXROM (rom/exrom_checker.asm) — the ROM-size fix, see
; this project's own working memory "ROM-SIZE CRISIS" section. Every
; former direct `call BASIC_SCAN_LABELS` / `call BASIC_CHECK_PROGRAM`
; / `call BASIC_CHECK_STATEMENT` site in this file now calls through
; one of these three instead. See kernel/bank/bank.asm for the paging
; primitives themselves (BANK_PAGE_EXROM_IN/OUT).
;
; Three wrappers, not one, because callers need three different
; behaviors:
;   - BASIC_DO_EDIT (label lookup) and post-LOAD only ever need the
;     label table rebuilt, not a full syntax check.
;   - BASIC_RUN and post-commit re-validation need both, always label-
;     rebuild-then-check (GOTO validation needs the table populated
;     first — see the original BASIC_RUN call site's own comment,
;     preserved in rom/exrom_checker.asm's EXROM_FULL_CHECK_IMPL).
;   - BASIC_DRAW_STATUS_LINE needs to re-check ONE already-known
;     statement (no label rebuild) to recover its specific error
;     message. THIS WAS A HOT PATH — called on EVERY status-line
;     redraw during editing (BASIC_REDRAW_PROGRAM's own header:
;     "full-redraw-every-keypress"), not just RUN/EDIT/LOAD — so it
;     gets its own entry ($C006) and, unlike the other two wrappers
;     here, must preserve the CARRY FLAG across BANK_PAGE_EXROM_OUT
;     (which does `xor a` and would otherwise silently clobber BASIC_
;     CHECK_STATEMENT's own carry-flag result — see this project's
;     lesson 1, register/flag survival across a "destroys" contract).
;     BASIC_DRAW_STATUS_LINE's own caller-side cache (STATUS_CHECK_
;     VALID/_CACHED_POS/_CACHED_MSG, sysvars.inc) now skips this call
;     entirely on any redraw where CUR_EDIT_POS hasn't moved since the
;     last one — which is every keystroke typed WITHIN a line, the
;     common case — so this wrapper itself still only runs once per
;     genuinely new statement position, not once per keypress. Still
;     flagged for extra hardware-timing scrutiny once tested, since
;     it's the only one of the three actually reachable from a tight
;     interactive loop at all.
;
; In/Out/Destroys for each: identical to the routine it replaces
; (BASIC_SCAN_LABELS, the combined SCAN_LABELS-then-CHECK_PROGRAM
; pair, and BASIC_CHECK_STATEMENT respectively) — paging itself only
; ever touches AF (see BANK_PAGE_EXROM_IN/OUT's own headers), so HL
; (BASIC_CHECK_STATEMENT_EXROM's real argument) passes through
; untouched in every case.
;
; CODE-SIZE REVIEW (updated 2026-08-27): ordinary wrappers now use
; BASIC_CALL_EXROM_INLINE's five-byte CALL+DW form rather than repeating
; page-in/call/page-out at every entry. Twenty-four wrappers share that
; trampoline, recovering a measured 74 Home-ROM bytes after its own cost
; (64 -> 138 bytes free). BASIC_FULL_CHECK_EXROM and BASIC_CHECK_STATEMENT_
; EXROM remain explicit because they have Home-side state work after the
; EXROM call; CALC_ENTRY_TRAMPOLINE remains explicit because its RST $28
; literal-stream stack protocol cannot tolerate an ordinary call shape.
; ============================================================================
BASIC_SCAN_LABELS_EXROM:
    xor  a                               ; invalidate the status-line
    ld   (STATUS_CHECK_VALID), a          ; check cache — statement
                                        ; positions may shift under a
                                        ; label rebuild (see sysvars.
                                        ; inc's own comment on these
                                        ; three fields)
    call BASIC_CALL_EXROM_INLINE
    DW   $C000

BASIC_FULL_CHECK_EXROM:
    xor  a                               ; invalidate — same reasoning
    ld   (STATUS_CHECK_VALID), a          ; as BASIC_SCAN_LABELS_EXROM
                                        ; above, plus the error SET
                                        ; itself can change here
    ld   a, 1
    ld   (BASIC_CHECK_ONLY), a            ; USR's static-check guard —
                                        ; see BASIC_CHECK_ONLY's own
                                        ; sysvars.inc comment
    call BANK_PAGE_EXROM_IN
    call $C006
    xor  a
    ld   (BASIC_CHECK_ONLY), a            ; real execution again —
                                        ; $C006 never diverges control
                                        ; flow (a guarded USR just
                                        ; returns 0 like any other
                                        ; function), so this always runs
    jp   BANK_PAGE_EXROM_OUT             ; same reasoning as above —
                                        ; the original SCAN_LABELS-
                                        ; then-CHECK_PROGRAM pair never
                                        ; left flags for its callers

BASIC_CHECK_STATEMENT_EXROM:
    ; In:  HL = pointer to the statement's length prefix (BASIC_CHECK_
    ;      STATEMENT's own contract, unchanged)
    ; Out: carry set if invalid, clear if fine (BASIC_CHECK_STATEMENT's
    ;      own contract, unchanged) — see this routine's own comment
    ;      block above for why this one, unlike its two siblings,
    ;      must protect AF across the page-out step
    ; Destroys: AF, BC, DE — HL passes through untouched (see above)
    ld   a, 1
    ld   (BASIC_CHECK_ONLY), a            ; USR's static-check guard —
                                        ; see BASIC_CHECK_ONLY's own
                                        ; sysvars.inc comment. This
                                        ; wrapper is the live-typing hot
                                        ; path (BASIC_DRAW_STATUS_LINE,
                                        ; every status-line redraw) —
                                        ; without this, even just TYPING
                                        ; "X = USR(0)" (before RUN is
                                        ; ever pressed) would jump to
                                        ; address 0
    call BANK_PAGE_EXROM_IN
    call $C00C
    push af                               ; protect BASIC_CHECK_
                                        ; STATEMENT's own carry result
                                        ; across clearing BASIC_CHECK_
                                        ; ONLY below
    xor  a
    ld   (BASIC_CHECK_ONLY), a
    pop  af
    jp   BASIC_EXROM_EXIT_PROTECTED      ; protects BASIC_CHECK_
                                        ; STATEMENT's own carry-flag
                                        ; result across the page-out —
                                        ; see BASIC_EXROM_EXIT_
                                        ; PROTECTED's own header below

; ============================================================================
; BASIC_SAVE_EXROM / BASIC_LOAD_EXROM
; Thin Home-side wrappers: STORAGE_SAVE/STORAGE_LOAD now live in EXROM
; (rom/exrom_storage.asm — SAVE/LOAD's own migration, 2026-08-19),
; same "page in / call the fixed entry / page out" shape as the three
; checker wrappers just above, at the checker's own $C000/$C006/$C00C
; addresses' new EXROM_ENTRY_SAVE/EXROM_ENTRY_LOAD siblings ($C012/
; $C018 — see rom/exrom_checker.asm's own entry-point doc block for
; why both subsystems' entry stubs live together in that file).
;
; Unlike BASIC_SCAN_LABELS_EXROM/BASIC_FULL_CHECK_EXROM (which never
; needed flag protection) both of these DO protect AF across the
; page-out step, same as BASIC_CHECK_STATEMENT_EXROM above:
;   - BASIC_SAVE_EXROM: STORAGE_SAVE's own carry (set only on the
;     too-large case) is currently ignored by BASIC_DO_SAVE (which
;     unconditionally clears carry after this call regardless) — but
;     preserved anyway rather than relying on that staying true.
;   - BASIC_LOAD_EXROM: STORAGE_LOAD's own carry (set on total
;     failure) IS live-checked by its caller (BASIC_DO_LOAD's `jp c,
;     .load_failed`), so protecting it here isn't optional. DE
;     (actual data length received) needs no protection — BANK_PAGE_
;     EXROM_OUT only ever destroys AF (see its own header), so DE
;     passes straight through untouched regardless.
;
; In/Out/Destroys for each: identical to the routine it replaces
; (STORAGE_SAVE / STORAGE_LOAD respectively) — HL/DE/IX (SAVE) and
; IX/HL/B (LOAD) pass straight through, same as every wrapper above.
;
; INTERRUPT NOTE (both): STORAGE_SAVE/STORAGE_LOAD each `di` at their
; own very first line and rely on the CALLER to `ei` after return —
; see kernel/storage/storage.asm's own header. BANK_PAGE_EXROM_OUT's
; own internal `ei` (it brackets only its own port writes with DI/EI —
; see kernel/bank/bank.asm) ends up re-enabling interrupts a couple of
; instructions before this file's own explicit `ei` at each call site
; runs. Confirmed harmless, not just assumed: EI is idempotent, no
; sysvar either wrapper touches lives in chunk 6, and KBD_ISR_TICK
; never touches chunk 6 either (see docs/memory_map.md) — so it does
; not matter that interrupts come back on a few instructions earlier
; than the original single-image code turned them on. The call sites'
; own explicit `ei` is kept anyway, as a defensive, self-documenting
; no-op, not removed.
; ============================================================================
BASIC_SAVE_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C012

BASIC_LOAD_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C018

; ============================================================================
; BASIC_SOUND_EXROM
; Thin Home-side wrapper: SOUND's real body (register-range check + the
; two AY port writes) lives in EXROM (rom/exrom_sound.asm) — pushed
; there purely for Home ROM budget, unlike BEEP's kernel/sound module
; which stayed Home-resident (kernel/sound/sound.asm's own header has
; the reasoning). Same "page in / call the fixed entry / page out"
; shape as BASIC_SAVE_EXROM/BASIC_LOAD_EXROM above, at EXROM_ENTRY_
; SOUND's own $C048 (rom/exrom_checker.asm's entry-stub block).
; In:  B = register (1-16), C = data (0-255)
; Out: carry set if register out of range, clear on success
; Destroys: AF
; ============================================================================
BASIC_SOUND_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C048

; Shared wrapper for ULAPLUS (B=0) and PALETTE (B=1).
BASIC_ULAPLUS_EXROM:
    call BANK_PAGE_EXROM_IN
    call $C0AE
    push af
    jr   nc, .ulaplus_result_ready
    ld   hl, MSG_INVALID_ARGUMENT
    call BASIC_SET_PENDING_ERROR
.ulaplus_result_ready:
    pop  af
    jp   BASIC_EXROM_EXIT_PROTECTED

; ============================================================================
; BASIC_STRFUNC_EXROM
; Thin Home-side wrapper: the actual body of every string function
; (CHR$/STR$/UPPER$/LOWER$/LEFT$/RIGHT$/INKEY$/VAL — FILL$/INSTR
; dropped 2026-08-22 to fit Home ROM's own budget) lives in EXROM
; (rom/exrom_strfuncs.asm) — pushed there for Home ROM budget, same
; reasoning SOUND/SPRITE already established. Same "page in / call
; the fixed entry / page out" shape, at EXROM_ENTRY_STRFUNC's own
; $C05A. Callers set up STR_FUNC_CALL_ID and whatever per-ID arguments
; that function needs BEFORE calling this (see STRFUNC_EXROM's own
; header in rom/exrom_strfuncs.asm for the exact convention).
; Destroys: whatever STRFUNC_EXROM's own contract defines, plus AF
; ============================================================================
BASIC_STRFUNC_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C05A

; ============================================================================
; BASIC_EDITOR_*_EXROM (2026-08-22)
; Thin Home-side wrappers: kernel/editor's entire full-screen editor
; now lives in EXROM (rom/exrom_editor.asm) — the module moved there
; whole in a ROM-shrink pass once the string-functions feature alone
; left Home ROM hundreds of bytes over its 16K cap even after every
; other realistic saving was applied. Same "page in / call the fixed
; entry / page out" shape as every wrapper above, one per fixed entry
; stub in rom/exrom_checker.asm ($C060-$C089). Every register these
; pass through survives BANK_PAGE_EXROM_IN/OUT untouched (both
; Destroy AF only) and BASIC_EXROM_EXIT_PROTECTED's own AF-preserving
; page-out already covers every result these seven ever return in A
; or carry — none of them needed special-casing beyond the standard
; shape, including the ones returning through B/C/HL, which the page-
; out call never touches at all.
;
; BASIC_EDITOR_ENTER_EXROM in particular pages EXROM in ONCE and keeps
; it paged in for the WHOLE interactive editing session — EDITOR_ENTER
; doesn't return to Home until the user commits — see rom/exrom_
; editor.asm's own header for why that's safe (BANK_EXROM_DEPTH makes
; any nested page-in/out the session's own hooks trigger a cheap
; counter bump, not a real port write).
; ============================================================================
    DEFINE EMIT_BASIC_EDITOR_EXROM_WRAPPERS
    INCLUDE "basic/editor_integration.asm"
    UNDEFINE EMIT_BASIC_EDITOR_EXROM_WRAPPERS

BASIC_SHOW_HELP_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C01E

; ============================================================================
; BASIC_FORMAT_STORAGE_STATUS_EXROM
; Thin Home-side wrapper: BASIC_FORMAT_STORAGE_STATUS and its own
; MSG_* message strings now live in EXROM (rom/exrom_storage.asm) —
; a ROM-size audit candidate, picked because it's a cold path: only
; ever called from BASIC_DRAW_STATUS_LINE while STORAGE_OP_STATE is
; nonzero, i.e. during or just after an actual SAVE/LOAD, never on an
; ordinary status-line redraw. Same "page in / call the fixed entry /
; page out" shape as every wrapper above, at EXROM_ENTRY_FORMAT_
; STORAGE_STATUS's own $C042 (rom/exrom_checker.asm's entry-stub
; block).
;
; REENTRANCY: this CAN run nested inside an already-paged-in EXROM
; call — STORAGE_SAVE/STORAGE_LOAD (EXROM-resident, rom/exrom_storage.
; asm) call it repeatedly mid-transfer via STORAGE_PROGRESS_HOOK,
; which is set to point at THIS wrapper's caller, BASIC_DRAW_STATUS_
; LINE (Home-resident, never paged). Safe only because kernel/bank/
; bank.asm's BANK_PAGE_EXROM_IN/_OUT are nesting-safe (BANK_EXROM_
; DEPTH) — see that sysvar's own comment for the SIN/PI incident this
; guards against; without it, this exact call pattern would unmap
; EXROM out from under STORAGE_SAVE/LOAD's own still-in-flight call
; chain mid-transfer.
;
; Does NOT need BASIC_EXROM_EXIT_PROTECTED: this routine's own
; original contract was already "Destroys: AF, BC, DE, HL" with no
; meaningful output register — same unprotected shape as BASIC_SHOW_
; HELP_EXROM above, for the same reason.
;
; In:  none. Out: STATUS_BUF filled and null-terminated (memory,
;      survives regardless). Destroys: AF, BC, DE, HL.
; ============================================================================
BASIC_FORMAT_STORAGE_STATUS_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C042

; ============================================================================
; CALC_INT_TO_FP_HOME / CALC_FP_TO_INT_HOME
; Home-side wrappers for CALC_INT_TO_FP/CALC_FP_TO_INT (rom/exrom_
; calc.asm) — same "page in / call the fixed entry / page out" shape as
; BASIC_SHOW_HELP_EXROM above, at rom/exrom_checker.asm's own new
; $C02A/$C030 entry stubs. Added 2026-08-21 alongside BASIC_EVAL_TERM's
; own .divide_ok wiring "/" through the calculator engine — neither
; converter is a CALC_TABLE literal, so unlike CALC_ENTRY_TRAMPOLINE
; above (which reaches CALC_OP_ADD/SUB/MUL/DIV via RST $28's literal-
; stream dispatch) they had no way to be called from Home at all until
; these two stubs existed.
;
; Neither needs BASIC_EXROM_EXIT_PROTECTED: BANK_PAGE_EXROM_OUT only
; ever destroys AF (see its own header), so CALC_INT_TO_FP_HOME's
; input (HL, passed straight through the page-in call untouched — same
; reasoning as BASIC_SHOW_HELP_EXROM's own HL argument above) and
; CALC_FP_TO_INT_HOME's output (HL, the converted int) both survive a
; plain tail-jump into the page-out step with nothing to protect.
;
; CALC_INT_TO_FP_HOME  In:  HL = signed 16-bit int
;                      Out: CALC_SP incremented by 1 (memory, not a
;                           register — survives regardless)
; CALC_FP_TO_INT_HOME  In:  none (pops CALC_STACK)
;                      Out: HL = converted int, CALC_TRUNC_FLAG set on
;                           overflow (memory, survives regardless)
; Both: Destroys AF, BC, DE, HL — identical to the routines they wrap.
; ============================================================================
CALC_INT_TO_FP_HOME:
    call BASIC_CALL_EXROM_INLINE
    DW   $C02A
    ret  nc
    jp   CALC_REPORT_ERROR

CALC_FP_TO_INT_HOME:
    call BASIC_CALL_EXROM_INLINE
    DW   $C030
    ret  nc
    jp   CALC_REPORT_ERROR

; ============================================================================
; CALC_PUSH_PI_HOME / CALC_PUSH_FP_RAW_HOME
; Same page-in/call-fixed-stub/page-out shape as CALC_INT_TO_FP_HOME
; above. Added 2026-08-22 for SQR/SIN's "function-result float" wiring
; (see FUNC_RESULT_IS_FLOAT's own sysvars.inc comment).
;
; CALC_PUSH_PI_HOME      In:  none. Out: CALC_SP incremented by 1 (pi
;                        pushed). Takes no argument — pi is a fixed
;                        constant baked into rom/exrom_calc.asm, not
;                        something Home could point EXROM at (Home
;                        can't reference an EXROM label at all — see
;                        that file's own CALC_OP_END_CALC header).
; CALC_PUSH_FP_RAW_HOME  In:  HL = pointer to a 5-byte packed float
;                        (a Home-resident buffer, e.g. FUNC_RESULT_
;                        FLOAT below — ordinary RAM, unaffected by
;                        EXROM paging). Out: CALC_SP incremented by 1.
; Both: Destroys AF, BC, DE, HL — identical to CALC_PUSH_FP_RAW's own
; contract; HL survives BANK_PAGE_EXROM_IN untouched, same reasoning as
; CALC_INT_TO_FP_HOME's own HL argument.
; ============================================================================
CALC_PUSH_PI_HOME:
    call BASIC_CALL_EXROM_INLINE
    DW   $C036
    ret  nc
    jp   CALC_REPORT_ERROR

CALC_PUSH_FP_RAW_HOME:
    call BASIC_CALL_EXROM_INLINE
    DW   $C03C
    ret  nc
    jp   CALC_REPORT_ERROR

; ============================================================================
; CALC_ENTRY_TRAMPOLINE / CALC_EXIT_TRAMPOLINE
; The calculator engine's own variant of the page-in/call/page-out shape
; above — CANNOT reuse BASIC_SHOW_HELP_EXROM's plain `call $C0xx` form.
; RST $28's return address (pushed by the RST itself, at rom/main.asm's
; RST_28) is not an ordinary return address: it's a pointer into the
; byte-coded literal-op stream that follows every RST $28 call site, and
; the calculator's own entry logic (CALC_GEN_ENT_2, in rom/exrom_calc.
; asm) grabs it directly off the top of the stack via EX (SP),HL. A
; normal `call` into EXROM would push a SECOND address on top of that
; one and corrupt the mechanism; a `call` for the page-out side has the
; opposite problem (see CALC_EXIT_TRAMPOLINE below). Both halves here
; use `jp`, not `call`, for exactly that reason:
;
; CALC_ENTRY_TRAMPOLINE: RST_28 jumps straight here (never called).
; BANK_PAGE_EXROM_IN's own call/ret pair is self-contained and stack-
; neutral (see its header), so by the time the final `jp` below fires,
; the literal-pointer RST pushed is still exactly on top of the stack,
; untouched. That final `jp` is a genuine tail-jump into EXROM_ENTRY_
; CALCULATE ($C024, rom/exrom_checker.asm's stub block) — it does NOT
; push anything, so the calculator's own entry code sees the same
; stack it would have seen with no EXROM layer involved at all.
; In:  B = passed through unchanged from the RST $28 call site (the
;      calculator's own entry contract — see rom/exrom_calc.asm)
; Out/Destroys: whatever the calculator's own top-level contract is —
;      this trampoline itself only destroys AF (BANK_PAGE_EXROM_IN's
;      own contract), BC/DE/HL pass through untouched
; ============================================================================
CALC_ENTRY_TRAMPOLINE:
    call BANK_PAGE_EXROM_IN
    jp   $C024                           ; EXROM_ENTRY_CALCULATE

; ============================================================================
; CALC_EXIT_TRAMPOLINE
; The far end of the chain above. CALC_OP_END_CALC (rom/exrom_calc.asm)
; is EXROM-resident, so it cannot safely call BANK_PAGE_EXROM_OUT
; itself: the instant that call pages Home back in over $C000-$DFFF,
; the very next instruction fetch — BANK_PAGE_EXROM_OUT's own `ret` —
; would read whatever Home ROM byte now sits at that EXROM address
; instead of the real one, since paging affects the address range
; end_calc's own code is still executing from. A `jp` doesn't have that
; problem: it's a plain PC write, valid regardless of what's paged in,
; and this stub's own bytes live in Home (basic.asm), always mapped —
; so end_calc's LAST EXROM instruction is a tail-jump here, and only
; once execution is safely back on Home-resident code does the actual
; page-out happen. By the time control reaches here, end_calc has
; already restored the TRUE original RST $28 caller's return address
; onto the stack (see its own header) — BANK_PAGE_EXROM_OUT's own `ret`
; pops exactly that, so this really is the final return, one level up
; from BASIC_EXROM_EXIT_PROTECTED's shape below (that one protects AF
; across a page-out an ordinary `call` site is waiting on; this one has
; no ordinary call site waiting at all — the RST $28 caller several
; frames up the literal-stream chain is the only one still waiting).
; In:  stack top = the true original RST $28 caller's return address
; Out: none (real ret, to the true original caller)
; Destroys: AF (BANK_PAGE_EXROM_OUT's own contract)
; ============================================================================
CALC_EXIT_TRAMPOLINE:
    call BANK_PAGE_EXROM_OUT
    ld   a, (CALC_ERROR_CODE)
    or   a
    ret  z
    call CALC_REPORT_ERROR
    ret

; Converts CALC_ERROR_CODE into the BASIC error channel. The specific
; division and numeric-range messages are retained; malformed bytecode,
; stack depth, overflow, and unavailable operations share a calculator
; error because none are valid source-level BASIC constructs.
CALC_REPORT_ERROR:
    ld   a, (CALC_ERROR_CODE)
    cp   CALC_ERR_DIVISION_BY_ZERO
    ld   hl, MSG_DIVISION_BY_ZERO
    jr   z, .record
    cp   CALC_ERR_NUMERIC_OVERFLOW
    ld   hl, MSG_NUMERIC_OVERFLOW
    jr   z, .record
    ld   hl, MSG_CALCULATOR_ERROR
.record:
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_EXROM_EXIT_PROTECTED
; Shared tail-jump target for BASIC_CHECK_STATEMENT_EXROM/BASIC_SAVE_
; EXROM/BASIC_LOAD_EXROM — the three EXROM wrappers whose callers rely
; on AF surviving the page-out step (see each one's own header above).
; A plain `jp` here (not `call`) is a true tail call: the `ret` below
; pops the ORIGINAL caller's return address, exactly as if each site
; still had its own inline copy. In: AF = the just-called EXROM
; entry's real result. Destroys: nothing beyond what BANK_PAGE_EXROM_
; OUT itself destroys (AF only, protected here) — BC/DE/HL/IX pass
; through untouched, same contract every call site already had.
; ============================================================================
BASIC_EXROM_EXIT_PROTECTED:
    push af
    call BANK_PAGE_EXROM_OUT
    pop  af
    ret

; ==========================================================================
; BASIC_CALL_EXROM_INLINE
; Shared ordinary Home-to-EXROM call trampoline. The caller places the
; fixed EXROM entry address in the two bytes immediately after CALL:
;
;     call BASIC_CALL_EXROM_INLINE
;     DW   $C0xx
;
; The CALL return address points at that word. The trampoline removes it,
; decodes the target with the otherwise-unused alternate BC/DE/HL register
; set, and constructs this stack chain:
;
;     EXROM target -> BASIC_EXROM_EXIT_PROTECTED -> original caller
;
; Thus the inline word is data, never executed, and every primary register
; reaches the EXROM entry exactly as it did through the former wrappers.
; This project and its interrupt handler do not use EXX anywhere else;
; alternate BC/DE/HL are explicitly scratch here. If that changes, this
; contract must be revisited.
;
; In/Out: defined by the selected EXROM entry
; Destroys: alternate BC/DE/HL, plus whatever the selected entry destroys
; ==========================================================================
BASIC_CALL_EXROM_INLINE:
    ; check-asm: allow-early-pop -- intentionally consumes this routine's
    ; own CALL return address, which points at the inline DW above.
    exx
    pop  hl                             ; inline target-word address;
                                        ; original caller is now on top
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                        ; DE' = fixed EXROM target
    ld   hl, BASIC_EXROM_EXIT_PROTECTED
    push hl                             ; target returns to protected OUT
    push de                             ; trampoline RET enters target
    exx
    call BANK_PAGE_EXROM_IN
    ret


; ============================================================================
; BASIC_IS_LABEL_DEFINITION
; Checks whether the content at HL is ENTIRELY a bare identifier
; followed by ':' — a label definition — without touching the label
; table at all. Same pattern BASIC_SCAN_LABELS uses to actually build
; the table (identifier, then ':', then end of statement), kept here
; as its own small, separate check rather than refactored to share
; code with that already-working routine.
;
; Needed now that BASIC_EXEC_STATEMENT's "unrecognized statement"
; fallback reports a real error instead of silently no-opping: before
; error reporting existed, a label like "loop:" and genuine garbage
; both fell into the same silent no-op, so the distinction never
; mattered. Now it does — this is what lets a label keep working
; exactly as before while genuine garbage gets reported.
; In:  HL = statement content start (past the length prefix)
; Out: carry clear if this IS a label definition; carry set if not
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_IS_LABEL_DEFINITION:
    call BASIC_PARSE_IDENTIFIER
    ld   a, b
    or   a
    jr   z, .not_label

    ld   a, (de)
    cp   ":"
    jr   nz, .not_label

    inc  de
    ld   a, (de)
    cp   $0D
    jr   nz, .not_label

    or   a
    ret
.not_label:
    scf
    ret

; ============================================================================
; BASIC_FIND_STATEMENT_BOUNDARY
; Scans forward from HL for the end of ONE colon-separated statement
; segment — either an unquoted ':' or the line's own terminating $0D,
; whichever comes first. Built for the statement-separator feature
; (BASIC_EXEC_MULTI_STATEMENT/BASIC_CHECK_MULTI_STATEMENT below): this
; project's individual statement handlers (BASIC_STMT_PRINT and
; friends) were never built to track or return "where did I stop
; parsing" — every one of them just runs to completion and returns,
; trusting that a whole stored statement always naturally ends at
; $0D. Teaching all of them to report an end position would touch a
; couple dozen routines. Splitting a line into segments FIRST, each
; one synthetically re-terminated to look exactly like a real, whole
; statement, means none of them need to change at all.
;
; A ':' inside a quoted string is not a real separator — "PRINT
; "a:b"" must print "a:b", not stop after "a". Tracked via
; BOUNDARY_IN_STRING, a simple toggle on every '"' seen; matches how
; string literals are recognized everywhere else in this project (no
; escape-sequence support, so a bare toggle is sufficient).
;
; REM is a special case, checked FIRST via the exact same
; BASIC_MATCH_KEYWORD_BOUNDARY every other keyword dispatch already
; uses (so this recognizes "REM" as a comment under precisely the
; same conditions BASIC_STMT_REM's own dispatch would) — once
; recognized, the entire rest of the line is comment text, colons
; included, matching classic BASIC's own REM behavior. Does NOT
; consume the "REM" text itself before scanning — HL is restored
; first, so the whole "REM ..." text still ends up as this segment's
; own content when the caller copies it.
;
; Verified in Python (a faithful line-splitter matching this exact
; control flow) against 7 cases — plain colons, a colon inside a
; quoted string, REM with embedded colons, a double colon (empty
; segment), a trailing colon, and a line with no colon at all — before
; writing this.
; In:  HL = scan start (the current segment's own start position)
; Out: DE = boundary position (pointing AT the ':' or the $0D itself,
;      never past it); A = the boundary character found (':' or $0D)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_FIND_STATEMENT_BOUNDARY:
    push hl
    ld   de, KW_REM
    call BASIC_MATCH_KEYWORD_BOUNDARY
    pop  hl
    jr   c, .not_rem                     ; carry set = didn't match REM

    ; whole rest of the line is a comment — scan straight to $0D,
    ; ignoring any colons entirely
.rem_scan:
    ld   a, (hl)
    cp   $0D
    jr   z, .found_eol
    inc  hl
    jr   .rem_scan

.not_rem:
    xor  a
    ld   (BOUNDARY_IN_STRING), a
.scan_loop:
    ld   a, (hl)
    cp   $0D
    jr   z, .found_eol
    cp   '"'
    jr   nz, .check_colon
    ld   a, (BOUNDARY_IN_STRING)
    xor  1
    ld   (BOUNDARY_IN_STRING), a
    jr   .advance
.check_colon:
    cp   ":"
    jr   nz, .advance
    ld   a, (BOUNDARY_IN_STRING)
    or   a
    jr   nz, .advance                     ; inside a string — not a
                                         ; real separator, just text
    ex   de, hl
    ld   a, ":"
    ret
.advance:
    inc  hl
    jr   .scan_loop

.found_eol:
    ex   de, hl
    ld   a, $0D
    ret

; ============================================================================
; BASIC_SET_PENDING_ERROR
; Records that an error occurred, WITHOUT displaying anything —
; detecting a problem and deciding what to do about it are now two
; separate steps. Real execution (BASIC_RUN's loop) still displays and
; halts immediately, exactly as before; the difference is WHERE that
; decision is made — centrally, once, rather than at each of the four
; places that can detect a failure (GOTO's two failure modes, PRINT's
; malformed expression, the expression evaluator's divide-by-zero
; check). This is what will let a future whole-program check pass
; reuse this exact same detection logic to find every problem in a
; program without stopping at the first one or executing anything.
;
; Only sets PENDING_ERROR_MSG if nothing is pending yet — an error
; found deep in a call chain (e.g. DIVISION BY ZERO inside an
; assignment's own value expression) must win over a more generic one
; an outer caller might also detect on the way back out (assignment's
; own fallback trying to report a generic SYNTAX ERROR on top of it).
; This replaces the old ERROR_REPORTED boolean flag with the same
; "first one wins" logic, just now carrying the actual message instead
; of just a yes/no.
; In:  HL = pointer to a null-terminated error message
; Out: none
; Destroys: AF
; ============================================================================
BASIC_SET_PENDING_ERROR:
    push hl
    ld   hl, (PENDING_ERROR_MSG)
    ld   a, h
    or   l
    jr   nz, .already_pending

    pop  hl
    ld   (PENDING_ERROR_MSG), hl
    ret

.already_pending:
    pop  hl
    ret

; ============================================================================
; BASIC_RAISE_SYNTAX_ERROR
; Shared tail-jump target: records MSG_SYNTAX_ERROR as the pending
; error and returns with carry set. This exact 4-instruction sequence
; (ld hl, MSG_SYNTAX_ERROR / call BASIC_SET_PENDING_ERROR / scf / ret)
; used to be duplicated INLINE at 24 separate sites across this file —
; every statement/expression parser's "malformed input" fallback,
; found in a 2026-08-19 code review. Consolidated here, the same
; "actively hunt down duplication" pass that already produced BASIC_
; STMT_MASKED_EXPR_COMMON and BASIC_EXPECT_STATEMENT_END. Every call
; site now either tail-jumps here directly on failure (`jp cc,
; BASIC_RAISE_SYNTAX_ERROR`) or, for a routine with multiple internal
; failure points that already funneled through one shared local label
; (LINE/BLOCK/CIRCLE's own .syntax_fail, IF/FOR's .fail, ELSEIF's
; .cond_fail, etc.), has that local label's body replaced by a jump
; straight here instead — same external behavior, no local body left
; to duplicate this any more. Along the way, one of those local labels
; (BASIC_STMT_FOR's own .fail) turned out to have zero references
; anywhere in its scope — genuinely unreachable dead code, not just
; duplicated — and was deleted outright rather than redirected.
; BASIC_SET_PENDING_ERROR's own "first
; error wins" semantics
; (see its header just above) are preserved exactly: this routine
; doesn't change what happens when a more specific error (e.g.
; DIVISION BY ZERO) was already recorded deeper in a call chain.
; In:  none
; Out: carry set
; Destroys: AF, HL
; ============================================================================
BASIC_RAISE_SYNTAX_ERROR:
    ld   hl, MSG_SYNTAX_ERROR
    call BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_REPORT_ERROR
; Displays a runtime error via the SAME row-23 status-line rendering
; BASIC_DRAW_STATUS_LINE uses for check-time errors (BASIC_PRINT_
; STATUS_TEXT) — "<message> IN: <failing statement>", truncated to
; BASIC_APPEND_STR's own cap. Deliberately does NOT call GFX_CLS —
; unlike a check-time error (which only ever happens with the editor's
; own listing already on screen), a RUNTIME error can happen with
; anything on rows 0-22 (mid-PRINT output, a half-drawn graphic,
; whatever the program was doing right up to the failing statement),
; and that's exactly the context most useful to still be looking at
; when the error is reported. (2026-08-22 — replaced the previous
; design, a full GFX_CLS followed by a 2-row report; see git history/
; README for that version if ever needed again.)
; This is now called from exactly one place — BASIC_RUN's loop, after
; a statement returns carry set and PENDING_ERROR_MSG is nonzero —
; rather than from each individual failure point directly. Reads
; CUR_EXEC_STMT (set by BASIC_RUN at the top of every loop iteration)
; to know which statement to show.
; In:  HL = pointer to a null-terminated error message
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_REPORT_ERROR:
    ld   (ERR_MSG_PTR), hl               ; stash the caller's message
                                        ; pointer first — BASIC_
                                        ; DETOKENIZE_TO_BUF below has
                                        ; its own destroys list, safer
                                        ; not to trust HL survives it

    ld   hl, STATUS_BUF
    ld   (STATUS_WRITE_PTR), hl

    ld   hl, (ERR_MSG_PTR)
    call BASIC_APPEND_STR

    ld   hl, MSG_ERROR_IN_TEXT
    call BASIC_APPEND_STR

    ld   hl, (CUR_EXEC_STMT)
    inc  hl
    inc  hl                            ; skip the 2-byte length prefix
    ld   de, DETOK_BUF
    call BASIC_DETOKENIZE_TO_BUF

    ld   hl, DETOK_BUF
    call BASIC_APPEND_STR

    ld   hl, STATUS_BUF
    jp   BASIC_PRINT_STATUS_TEXT

; ============================================================================
; BASIC_TRY_STR_ASSIGNMENT
; Recognizes and executes <string-variable> = <string-primary> — the
; string counterpart to BASIC_TRY_ASSIGNMENT below, tried first (see
; BASIC_EXEC_STATEMENT_CONTENT's dispatch chain) since "X$" can never
; be mistaken for a numeric assignment: BASIC_TRY_ASSIGNMENT's own
; letter-then-'='-or-space check already fails cleanly on the '$'
; (neither), restoring HL and returning "not a match" — so trying this
; one first costs nothing on ordinary numeric assignments and doesn't
; need any change to that routine's own logic.
; In:  HL = statement content start
; Out: carry clear if this was a valid string assignment (already
;      executed); carry set + HL unchanged if not
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_TRY_STR_ASSIGNMENT:
    push hl                          ; save start position, for restore
                                     ; on failure
    call BASIC_DETECT_STRVAR
    jp   c, .fail                    ; HL already restored — BASIC_
                                     ; DETECT_STRVAR's own contract
    ld   (STR_ASSIGN_LETTER), a
    xor  a
    ld   (STR_ASSIGN_KIND), a
    ld   a, (hl)
    cp   "("
    jr   nz, .skip_spaces1
    inc  hl
    call BASIC_ARRAY_PARSE_SUBSCRIPTS
    jr   c, .fail
    ld   de, (ARRAY_INDEX)
    ld   (STR_ASSIGN_INDEX), de
    ld   a, ARRAY_KIND_STR
    ld   (STR_ASSIGN_KIND), a
.skip_spaces1:
    ld   a, (hl)
    cp   " "
    jr   nz, .check_equals
    inc  hl
    jr   .skip_spaces1
.check_equals:
    cp   "="
    jr   nz, .fail
    inc  hl
.skip_spaces2:
    ld   a, (hl)
    cp   " "
    jr   nz, .parse_value
    inc  hl
    jr   .skip_spaces2
.parse_value:
    ld   de, STR_EXPR_SCRATCH + 1     ; byte 0 is the length prefix,
                                      ; filled in after we know it
    ld   c, 31                        ; STR_EXPR_SCRATCH is a 32-byte
                                      ; slot — see BASIC_EVAL_STR_EXPR's
                                      ; own header (2026-08-23)
    call BASIC_EVAL_STR_EXPR          ; B = bytes written, HL advanced
                                      ; — full expression, '+' chains
                                      ; included (2026-08-22)
    jr   c, .fail

    call BASIC_EXPECT_STATEMENT_END   ; Destroys AF, HL only — B (the
                                      ; parsed length) survives
    jr   c, .fail

    ld   a, b                         ; A = parsed length
    ld   (STR_EXPR_SCRATCH), a
    ld   a, (STR_ASSIGN_KIND)
    or   a
    jr   nz, .array_destination
    ld   a, (STR_ASSIGN_LETTER)
    call BASIC_STR_ADDR
    jr   c, .fail
    jr   .destination_ready
.array_destination:
    ld   de, (STR_ASSIGN_INDEX)
    ld   (ARRAY_INDEX), de
    ld   a, (STR_ASSIGN_LETTER)
    ld   c, ARRAY_KIND_STR
    call BASIC_ARRAY_FIND
    jr   c, .array_not_dimmed
    call BASIC_STR_ARRAY_ELEMENT_ADDR
    jr   c, .fail
.destination_ready:
    ld   a, (STR_EXPR_SCRATCH)
    ld   b, a
    ld   (hl), a                       ; store the length byte
    inc  hl
    ld   a, b
    or   a
    jr   z, .copy_done
    ld   de, STR_EXPR_SCRATCH + 1
.copy_loop:
    ld   a, (de)
    ld   (hl), a
    inc  hl
    inc  de
    djnz .copy_loop
.copy_done:
    pop  af                            ; discard saved start position
    or   a
    ret
.array_not_dimmed:
    ld   hl, MSG_ARRAY_NOT_DIMMED
    call BASIC_SET_PENDING_ERROR
    jr   .fail
.fail:
    pop  hl                          ; restore original position
    scf
    ret

; ============================================================================
; BASIC_TRY_ARRAY_ASSIGNMENT
; Recognizes and executes "<letter>(<index>) = <expr>" — array-element
; assignment. Tried before BASIC_TRY_ASSIGNMENT in this file's own
; dispatch tail, same reasoning BASIC_TRY_STR_ASSIGNMENT is tried
; before that: "A(3) = 5" would otherwise be misread as variable A
; followed by leftover "(3) = 5" garbage.
;
; Always restores the original position and returns carry set on ANY
; failure — not just "this isn't an array reference at all", but also
; a genuinely malformed one (bad index, missing "=", ...) or a valid-
; shaped one that fails at runtime (array not DIM'd, subscript out of
; range) — same uniform discipline BASIC_TRY_STR_ASSIGNMENT already
; established, rather than raising a syntax error directly the moment
; the "letter(" shape is confirmed. This matters here specifically
; because a runtime failure still needs to record its OWN, more
; specific message (ARRAY NOT DIMENSIONED, not a generic SYNTAX
; ERROR) — safe to do and still restore/cascade, since BASIC_SET_
; PENDING_ERROR never overwrites an already-pending message (see its
; own header), so the eventual generic SYNTAX ERROR this dispatch
; chain falls back to once every alternative is exhausted becomes a
; harmless no-op once a specific one is already set.
;
; REAL BUG FOUND AND FIXED (2026-08-22): the first draft stashed the
; array's own letter in CUR_VAR_LETTER — shared scratch BASIC_TRY_
; ASSIGNMENT/BASIC_STMT_DIM also use — which a nested array READ
; while parsing the index or RHS expression below (e.g. "A(B(0)) =
; C(1)") would silently clobber before this routine ever reads it
; back. Fixed by pushing the letter onto the real stack instead (see
; .do_array_read's own header, in BASIC_EVAL_PRIMARY, for the fuller
; incident writeup — the same bug, found there first).
; In:  HL = statement content start
; Out: carry clear if this was a valid array assignment (already
;      executed); carry set + HL restored to its original position
;      otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_TRY_ARRAY_ASSIGNMENT:
    push hl                          ; save start position — restored
                                     ; on every failure below, whatever
                                     ; the cause
    ld   a, (hl)
    call BASIC_VALIDATE_VAR_LETTER
    jr   c, .array_assign_fail
    push af                          ; stash the array's own letter —
                                     ; on the stack, not CUR_VAR_LETTER
                                     ; (see this routine's own header)
    inc  hl
    ld   a, (hl)
    cp   "("
    jr   nz, .array_assign_fail_pop   ; not an array reference — could
                                      ; still be "A = ..."/"A$..." etc,
                                      ; let the caller try those next
    inc  hl                           ; consume "("
    call BASIC_ARRAY_PARSE_SUBSCRIPTS  ; ARRAY_INDEX set, HL = past the
                                      ; closing ")" — shared with array
                                      ; read, see that routine's own
                                      ; header
    jr   c, .array_assign_fail_pop
    call BASIC_SKIP_SPACES
    ld   a, (hl)
    cp   "="
    jr   nz, .array_assign_fail_pop
    inc  hl
    call BASIC_EVAL_EXPR              ; DE = RHS value, HL advanced
    jr   c, .array_assign_fail_pop
    ld   (ARRAY_ASSIGN_VALUE), de
    call BASIC_EXPECT_STATEMENT_END
    jr   c, .array_assign_fail_pop

    pop  af                             ; A = array's own letter
                                        ; (restored)
    ld   c, ARRAY_KIND_NUM
    call BASIC_ARRAY_FIND              ; HL = data, DE = count
    jr   c, .array_assign_not_dimmed
    call BASIC_ARRAY_ELEMENT_ADDR      ; HL = element address —
                                       ; bounds-checks the index, own
                                       ; header has the full contract
    jr   c, .array_assign_fail          ; error already recorded by
                                        ; BASIC_ARRAY_ELEMENT_ADDR;
                                        ; stack is already down to just
                                        ; the entry start-position
                                        ; push, matching what .array_
                                        ; assign_fail itself expects
    ld   de, (ARRAY_ASSIGN_VALUE)
    ld   (hl), e
    inc  hl
    ld   (hl), d
    pop  af                               ; discard saved start
                                          ; position — success
    or   a
    ret
.array_assign_not_dimmed:
    ld   hl, MSG_ARRAY_NOT_DIMMED
    call BASIC_SET_PENDING_ERROR
    jr   .array_assign_fail
.array_assign_fail_pop:
    pop  af                                 ; balance the letter stash
.array_assign_fail:
    pop  hl                                 ; restore original position
    scf
    ret

; ============================================================================
; BASIC_TRY_ASSIGNMENT
; Recognizes and executes <variable> = <expression> — assignment now
; takes a full arithmetic expression via BASIC_EVAL_EXPR (not just a
; bare literal). Hand-traced for "x = 5": 'x' uppercases to 'X' and
; passes the A-Z range check; skip-spaces/'='/skip-spaces consumes
; " = "; leaves HL at '5'; BASIC_EVAL_EXPR gives DE=5; stored into
; VAR_TABLE's 'X' slot.
; A keyword like "INPUT X" can never be mistaken for this: after 'I',
; the very next non-space character is 'N', not '=', so the '='
; check fails and this correctly reports "not an assignment" — tried
; after the keyword checks in BASIC_EXEC_STATEMENT anyway, for clarity,
; though the ordering isn't load-bearing for correctness.
;
; The variable letter is stashed in CUR_VAR_LETTER (memory), not a
; register — a real bug here originally kept it in C, not noticing
; that BASIC_PARSE_NUMBER (called in between) uses C as its OWN digit-
; count register internally, exactly as its own "Destroys: AF, BC, DE,
; HL" docstring already said it would. The result: "x=5" was writing 5
; into whatever garbage address BASIC_VAR_ADDR computed from the
; leftover digit count instead of X's real slot, leaving X actually
; uninitialized — silently wrong, no crash, only visible once PRINT x
; read back nothing sensible. Caught the same way the GFX_PUTCHAR bug
; was: by checking a callee's documented Destroys list against what
; the caller actually assumed, after the symptom (assignment appearing
; to do nothing) pointed here.
; In:  HL = statement content start
; Out: carry clear if this was a valid assignment (already executed);
;      carry set + HL unchanged if not
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_TRY_ASSIGNMENT:
    push hl                          ; save start position, for restore
                                     ; on failure
    ld   a, (hl)
    call BASIC_VALIDATE_VAR_LETTER
    jr   c, .fail
    ld   (CUR_VAR_LETTER), a           ; stashed in memory, not register
                                       ; C — see header note above
    inc  hl
.skip_spaces1:
    ld   a, (hl)
    cp   " "
    jr   nz, .check_equals
    inc  hl
    jr   .skip_spaces1
.check_equals:
    cp   "="
    jr   nz, .fail
    inc  hl
.skip_spaces2:
    ld   a, (hl)
    cp   " "
    jr   nz, .parse_value
    inc  hl
    jr   .skip_spaces2
.parse_value:
    call BASIC_EVAL_EXPR                ; was BASIC_PARSE_NUMBER — now
                                        ; accepts a full expression
                                        ; (x = y + 1, x = 2*(3+4), etc.),
                                        ; not just a bare literal. Same
                                        ; HL-in/DE-out/carry-on-fail
                                        ; contract, so nothing else in
                                        ; this routine needed to change
    jr   c, .fail

    call BASIC_EXPECT_STATEMENT_END      ; BASIC_EXPECT_STATEMENT_END fix
                                         ; — THE bug this project's
                                         ; "Real end-to-end hardware
                                         ; test #1" found ("x = 1c" was
                                         ; silently accepted as x=1,
                                         ; with "c" dropped). Destroys
                                         ; AF/HL only, so DE (the
                                         ; parsed value) survives
    jr   c, .fail                        ; same restore-original-
                                         ; position path as every other
                                         ; failure in this routine

    pop  af                             ; discard saved start position —
                                        ; success, don't need it
    ld   a, (CUR_VAR_LETTER)
    push de                              ; save parsed value across the
                                         ; BASIC_VAR_ADDR call
    call BASIC_VAR_ADDR
    jr   c, .var_addr_oom                 ; pool exhausted — error
                                          ; already recorded; unwind
                                          ; the pushed value first
    pop  de
    ld   (hl), e
    inc  hl
    ld   (hl), d
    or   a
    ret
.var_addr_oom:
    pop  de
    ret
.fail:
    pop  hl                                ; restore original position
    scf
    ret

; ============================================================================
; BASIC_EXEC_STATEMENT
; Executes one statement (now potentially several, colon-separated —
; see BASIC_EXEC_MULTI_STATEMENT). A thin wrapper: skips the
; statement's own 2-byte length prefix, then hands off. Split out
; specifically so BASIC_STMT_IF's single-line short form ("IF <cond>
; THEN <statement>", all one statement's text) can dispatch its
; trailing text directly into the SAME keyword/assignment/label/
; colon-splitting recognition every top-level statement already goes
; through, without a length prefix of its own to skip — see
; BASIC_STMT_IF's header for why this is possible without a stored
; statement's own length prefix.
; In:  HL = pointer to the statement's length prefix (as returned by
;      MEM_LINE_FIRST/MEM_LINE_NEXT)
; Out: see BASIC_EXEC_MULTI_STATEMENT
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_EXEC_STATEMENT:
    inc  hl
    inc  hl                          ; HL = content start (past the
                                     ; 2-byte length prefix)
    jp   BASIC_EXEC_MULTI_STATEMENT

; ============================================================================
; BASIC_EXEC_STATEMENT_CONTENT
; The real dispatch, operating directly on statement TEXT rather than
; a length-prefixed statement pointer — see BASIC_EXEC_STATEMENT above
; for why these are split. END IF's compound-keyword check MUST come
; before the bare END check: "END IF" would otherwise match KW_END's
; own boundary check (a space counts as a valid boundary) and get
; treated as a program-stop, silently ignoring the " IF" — see
; BASIC_MATCH_ENDIF's own header for the full explanation. ELSEIF is
; checked before ELSE purely for clarity; BASIC_MATCH_KEYWORD_BOUNDARY
; already makes the check order harmless either way, since matching
; "ELSE" against "ELSEIF ..." fails its own boundary check (the next
; character is 'I', not a space or end-of-statement).
; In:  HL = statement content start (text, past any length prefix)
; Out: carry set if execution should stop — either END/STOP was
;      encountered, or an error was reported (BASIC_REPORT_ERROR
;      already called, message already on screen); carry clear to
;      continue. BASIC_RUN's loop treats both the same way (stop),
;      but only an error leaves a message behind to explain why.
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_EXEC_STATEMENT_CONTENT:
    call BASIC_MATCH_ENDIF
    jp   nc, .done                    ; END IF is a pure no-op —
                                      ; whether reached by ordinary
                                      ; fallthrough (a taken branch's
                                      ; body just ended) or by landing
                                      ; here via a skip scan, execution
                                      ; just continues to whatever
                                      ; comes next either way

    push ix                           ; IX is not part of this routine's
                                      ; documented destroy set
    ld   ix, BASIC_EXEC_DISPATCH_TABLE
.dispatch_loop:
    ld   e, (ix+0)
    ld   d, (ix+1)
    ld   a, d
    or   e
    jr   z, .try_assignments
    call BASIC_MATCH_KEYWORD_BOUNDARY
    jr   nc, .dispatch_match
    ld   de, 4
    add  ix, de
    jr   .dispatch_loop
.dispatch_match:
    ld   e, (ix+2)
    ld   d, (ix+3)
    pop  ix
    push de
    ret                               ; synthetic indirect jump; HL is
                                      ; still advanced past the keyword

.try_assignments:
    pop  ix
    call BASIC_TRY_STR_ASSIGNMENT
    jp   nc, .done                    ; string assignment handled it

    call BASIC_TRY_ARRAY_ASSIGNMENT
    jp   nc, .done                    ; array-element assignment
                                      ; handled it — tried before the
                                      ; plain scalar assignment below,
                                      ; same reasoning: "A(3) = 5"
                                      ; would otherwise be misread as
                                      ; variable A with "(3) = 5" left
                                      ; as garbage

    call BASIC_TRY_ASSIGNMENT
    jr   nc, .done                    ; assignment handled it

    ; not a keyword and not an assignment — but this might still be a
    ; legitimate label definition (a no-op), not genuine garbage, so
    ; check that before reporting an error
    call BASIC_IS_LABEL_DEFINITION
    jp   c, BASIC_RAISE_SYNTAX_ERROR      ; won't overwrite a more
                                         ; specific error (e.g. "x =
                                         ; 5/0" — assignment's own
                                         ; value expression already
                                         ; recorded DIVISION BY ZERO)

.is_label:
    or   a
    ret

.do_input:
    call BASIC_STMT_INPUT
    or   a
    ret
.do_ulaplus:
    ld   b, 0
    jp   BASIC_ULAPLUS_EXROM
.do_palette:
    ld   b, 1
    jp   BASIC_ULAPLUS_EXROM
.do_stop:
    scf
    ret
.done:
    or   a
    ret

; Keyword pointer + handler pointer. END IF remains the dedicated pre-check
; above because it is the only compound statement-leading keyword. Duplicate
; handler pointers are intentional aliases (END/STOP, ELSEIF/ELSE, GOSUB/CALL).
BASIC_EXEC_DISPATCH_TABLE:
    DW KW_PRINT, BASIC_STMT_PRINT
    DW KW_CLS, BASIC_STMT_CLS
    DW KW_REM, BASIC_STMT_REM
    DW KW_BORDER, BASIC_STMT_BORDER
    DW KW_INK, BASIC_STMT_INK
    DW KW_PAPER, BASIC_STMT_PAPER
    DW KW_FLASH, BASIC_STMT_FLASH
    DW KW_BRIGHT, BASIC_STMT_BRIGHT
    DW KW_INVERSE, BASIC_STMT_INVERSE
    DW KW_OVER, BASIC_STMT_OVER
    DW KW_AT, BASIC_STMT_AT
    DW KW_TAB, BASIC_STMT_TAB
    DW KW_PLOT, BASIC_STMT_PLOT
    DW KW_LINE, BASIC_STMT_LINE
    DW KW_BLOCK, BASIC_STMT_BLOCK
    DW KW_CIRCLE, BASIC_STMT_CIRCLE
    DW KW_CPLOT, BASIC_STMT_CPLOT
    DW KW_FILL, BASIC_STMT_FILL
    DW KW_BEEP, BASIC_STMT_BEEP
    DW KW_SOUND, BASIC_STMT_SOUND
    DW KW_DIM, BASIC_STMT_DIM
    DW KW_MODE, BASIC_STMT_MODE
    DW KW_ULAPLUS, BASIC_EXEC_STATEMENT_CONTENT.do_ulaplus
    DW KW_PALETTE, BASIC_EXEC_STATEMENT_CONTENT.do_palette
    DW KW_END, BASIC_EXEC_STATEMENT_CONTENT.do_stop
    DW KW_STOP, BASIC_EXEC_STATEMENT_CONTENT.do_stop
    DW KW_INPUT, BASIC_EXEC_STATEMENT_CONTENT.do_input
    DW KW_GOTO, BASIC_STMT_GOTO
    DW KW_IF, BASIC_STMT_IF
    DW KW_ELSEIF, BASIC_STMT_ELSE_OR_ELSEIF
    DW KW_ELSE, BASIC_STMT_ELSE_OR_ELSEIF
    DW KW_FOR, BASIC_STMT_FOR
    DW KW_NEXT, BASIC_STMT_NEXT
    DW KW_EXIT, BASIC_STMT_EXIT
    DW KW_SPRITE, BASIC_SPRITE_EXROM
    DW KW_POKE, BASIC_STMT_POKE
    DW KW_PAUSE, BASIC_STMT_PAUSE
    DW KW_RANDOMISE, BASIC_STMT_RANDOMISE
    DW KW_GOSUB, BASIC_STMT_GOSUB
    DW KW_CALL, BASIC_STMT_GOSUB
    DW KW_RETURN, BASIC_STMT_RETURN
    DW 0

; ============================================================================
; BASIC_EXEC_MULTI_STATEMENT
; Splits the text at HL into colon-separated segments and executes
; each one in turn via BASIC_EXEC_STATEMENT_CONTENT — the statement-
; separator (:) feature. See BASIC_FIND_STATEMENT_BOUNDARY's own
; header for why this is a pre-split rather than teaching every
; individual statement handler to report an end position.
;
; A label definition ("loop:") is checked FIRST, via the existing,
; completely unmodified BASIC_IS_LABEL_DEFINITION — labels currently
; require the WHOLE line to be nothing but "identifier:" (see that
; routine's own contract), so if this line IS one, it's dispatched
; whole, unsplit, exactly as before this feature existed. This is
; deliberate and load-bearing: it means labels/GOTO are completely
; unaffected by this feature, zero risk of a false split on the
; label's own trailing colon. A line that is NOT entirely a label
; definition never reaches the label-recognition code at all here —
; if someone writes "loop: PRINT 1", the colon-splitter treats "loop"
; and " PRINT 1" as two ordinary segments, "loop" alone is neither a
; label definition (fails BASIC_IS_LABEL_DEFINITION's own end-of-
; statement requirement) nor a recognized keyword/assignment, so it
; reports SYNTAX ERROR — labels sharing a line with other statements
; is simply not supported, not silently misinterpreted.
;
; Empty segments (a double colon, or a trailing colon with nothing
; after it) are silently skipped rather than dispatched — an empty
; string sent to BASIC_EXEC_STATEMENT_CONTENT would report SYNTAX
; ERROR for what real BASIC treats as a harmless no-op. Verified in
; Python (a faithful simulation of this exact loop, including the
; skip and a mid-line STOP correctly preventing any further segment
; from running) against 6 cases before writing this.
; In:  HL = content start (a statement's own text, past any length
;      prefix — or, when called from BASIC_STMT_IF's single-line THEN
;      form, whatever trailing text follows THEN)
; Out: carry set if execution should stop (matches BASIC_EXEC_
;      STATEMENT_CONTENT's own contract) — from either a genuine
;      stop/error in one of the segments, or (see above) this whole
;      line being an unsplit label definition
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_EXEC_MULTI_STATEMENT:
    push hl
    call BASIC_IS_LABEL_DEFINITION
    pop  hl
    jp   nc, BASIC_EXEC_STATEMENT_CONTENT  ; IS a label — dispatch the
                                          ; whole line unsplit; tail
                                          ; call, reuses its own ret

.loop:
    ld   (MULTI_SEG_START), hl
    call BASIC_FIND_STATEMENT_BOUNDARY      ; DE = boundary position,
                                           ; A = boundary char
    ld   (MULTI_SEG_END), de
    ld   (MULTI_SEG_BOUNDARY_CHAR), a

    ; empty segment? (start == end) — skip dispatching it entirely
    ld   hl, (MULTI_SEG_START)
    or   a
    sbc  hl, de
    jr   z, .next_segment

    ; copy [MULTI_SEG_START, MULTI_SEG_END) into MULTI_STMT_BUF,
    ; synthetically $0D-terminated
    ld   hl, (MULTI_SEG_START)
    ld   de, MULTI_STMT_BUF
.copy_loop:
    ld   bc, (MULTI_SEG_END)
    ld   a, h
    cp   b
    jr   nz, .copy_one
    ld   a, l
    cp   c
    jr   z, .copy_done
.copy_one:
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    jr   .copy_loop
.copy_done:
    ld   a, $0D
    ld   (de), a

    ld   hl, MULTI_STMT_BUF
    call BASIC_EXEC_STATEMENT_CONTENT
    jr   c, .stop
.next_segment:
    ld   a, (MULTI_SEG_BOUNDARY_CHAR)
    cp   $0D
    jr   z, .all_done                    ; that was the last segment

    ld   hl, (MULTI_SEG_END)
    inc  hl                              ; skip past the ':' — next
                                        ; segment starts right after it
    call BASIC_SKIP_SPACES               ; ...and past any run of
                                        ; spaces before it — a natural
                                        ; "a: b" style otherwise leaves
                                        ; the next segment starting on
                                        ; a space, which nothing
                                        ; downstream (BASIC_EXEC_
                                        ; STATEMENT_CONTENT's own
                                        ; keyword checks included)
                                        ; tolerates. Found via a real
                                        ; SYNTAX ERROR on every colon-
                                        ; joined statement in a preload
                                        ; test program, traced to
                                        ; exactly this — same fix
                                        ; applies to BASIC_CHECK_MULTI_
                                        ; STATEMENT's own identical
                                        ; next-segment advance further
                                        ; down
    jr   .loop

.stop:
    scf
    ret
.all_done:
    or   a
    ret

; ============================================================================
; BASIC_GET_CAPPED_ERROR_COUNT
; Shared parsing primitive: loads CHECK_ERROR_COUNT and clamps it to
; CHECK_ERROR_LIST's own 16-entry capacity (entries beyond the 16th
; were never stored, so searching past that would just read garbage).
; Factors out this exact clamp, duplicated identically in
; BASIC_IS_ERROR_STATEMENT/BASIC_FIND_NEXT_ERROR/BASIC_FIND_PREV_ERROR.
; In:  none (reads CHECK_ERROR_COUNT)
; Out: B = min(CHECK_ERROR_COUNT, 16)
; Destroys: AF, DE
; ============================================================================
BASIC_GET_CAPPED_ERROR_COUNT:
    ld   de, (CHECK_ERROR_COUNT)
    ld   a, d
    or   a
    jr   nz, .cap
    ld   a, e
    cp   17
    jr   nc, .cap
    ld   b, e
    ret
.cap:
    ld   b, 16
    ret

; ============================================================================
; BASIC_IS_ERROR_STATEMENT
; Checks whether a given statement position is one BASIC_CHECK_PROGRAM
; found invalid — searches CHECK_ERROR_LIST linearly, capped at
; whichever is smaller: CHECK_ERROR_COUNT or the list's own 16-entry
; capacity (entries beyond the 16th were never stored, so searching
; past that would just read garbage). Verified via a Python simulation
; of this exact search before writing it in Z80 (found, not-found,
; empty-list, and single-entry cases, all correct) — see this
; project's own working memory for that verification.
; In:  HL = statement position to check
; Out: carry clear if this position IS in the list; carry set if not
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_IS_ERROR_STATEMENT:
    ld   (SEARCH_TARGET), hl

    call BASIC_GET_CAPPED_ERROR_COUNT
    ld   a, b
    or   a
    jr   z, .not_found                      ; nothing to search at all
    ld   hl, CHECK_ERROR_LIST
.search_loop:
    push bc                                  ; save remaining-count —
                                             ; the comparison below
                                             ; needs BC as scratch
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    inc  hl                                    ; DE = this entry, HL
                                              ; advanced to the next
    push hl                                       ; save the list-
                                                 ; walking pointer

    ld   hl, (SEARCH_TARGET)
    or   a
    sbc  hl, de
    jr   z, .found_cleanup

    pop  hl                                          ; restore list
                                                     ; pointer
    pop  bc                                            ; restore
                                                       ; remaining count
    djnz .search_loop

    jr   .not_found

.found_cleanup:
    pop  hl                                              ; discard —
    pop  bc                                                ; found,
                                                          ; don't need
                                                          ; either
    or   a
    ret

.not_found:
    scf
    ret

; ============================================================================
; BASIC_FIND_NEXT_ERROR
; Finds the smallest CHECK_ERROR_LIST entry strictly greater than
; CUR_EDIT_POS — the next error in program order. CHECK_ERROR_LIST is
; already in ascending program order (the check pass appends each
; error as it walks the program sequentially), so a single forward
; scan for the first qualifying entry is all this needs. Wraps to the
; first entry (index 0) if none qualifies — either CUR_EDIT_POS is at
; or past the last error already, or it's the sentinel ($FFFF, which
; is greater than every real statement position, so nothing in the
; list is ever "greater than" it — this naturally falls through to the
; wrap case without needing to special-case the sentinel at all).
;
; Hand-traced against a 2-entry list [A, B] with A < B: starting from
; A finds B directly (A - A = 0, not strictly greater, skip; A - B
; borrows, since A < B — wait, this compares CUR_EDIT_POS - entry, so
; starting from A: A - A = 0 (skip, not strictly greater), then A - B
; borrows since A < B, meaning B > A — found); starting from B (the
; last entry) finds nothing greater and wraps to A.
; In:  none (reads CUR_EDIT_POS)
; Out: carry clear + HL = the found position; carry set if
;      CHECK_ERROR_LIST is empty (nothing to navigate to at all)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_FIND_NEXT_ERROR:
    call BASIC_GET_CAPPED_ERROR_COUNT
    ld   a, b
    or   a
    jr   z, .empty

    ld   hl, CHECK_ERROR_LIST
.scan_loop:
    push bc
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    inc  hl                                ; DE = this entry, HL
                                          ; advanced to the next
    push hl                                   ; save the list-walking
                                             ; pointer

    ld   hl, (CUR_EDIT_POS)
    or   a
    sbc  hl, de                              ; HL = CUR_EDIT_POS - entry
                                            ; — carry set means entry >
                                            ; CUR_EDIT_POS (a borrow was
                                            ; needed), which is exactly
                                            ; what "next" is looking for
    jr   c, .found

    pop  hl
    pop  bc
    djnz .scan_loop

    ; nothing qualified — wrap to the first entry
    ld   hl, CHECK_ERROR_LIST
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    or   a
    ret

.found:
    pop  hl                                   ; discard saved list
                                             ; pointer — found, don't
                                             ; need it
    pop  bc                                     ; discard saved count
    ex   de, hl                                   ; HL = the found
                                                 ; entry (was in DE)
    or   a
    ret

.empty:
    scf
    ret

; ============================================================================
; BASIC_FIND_PREV_ERROR
; Finds the largest CHECK_ERROR_LIST entry strictly less than
; CUR_EDIT_POS — the previous error in program order. Walks the list
; backward from its last entry, remembering that last entry's value
; upfront (WRAP_TARGET) so wrapping around doesn't need to recompute
; anything if the scan reaches the start without finding a qualifying
; entry.
;
; The "strictly less than" check needs two comparisons, not one:
; CUR_EDIT_POS - entry has no borrow (carry clear) both when entry is
; less than CUR_EDIT_POS (what's wanted) AND when they're equal (not
; wanted, would find the statement's own error again rather than
; genuinely moving) — so a zero result after the subtraction is
; explicitly excluded, on top of the carry check.
;
; Hand-traced against a 2-entry list [A, B] with A < B, searching from
; B (the last entry): B - B = 0 with no borrow, excluded by the
; explicit zero check (not strictly less); steps back to A: B - A has
; no borrow and a nonzero result (since B > A) — found. Searching from
; A (the first entry) would find nothing less and wrap to B.
; In:  none (reads CUR_EDIT_POS)
; Out: carry clear + HL = the found position; carry set if
;      CHECK_ERROR_LIST is empty
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_FIND_PREV_ERROR:
    call BASIC_GET_CAPPED_ERROR_COUNT
    ld   a, b
    or   a
    jr   z, .empty

    ; compute the last entry's address (CHECK_ERROR_LIST + (count-1)*2)
    ; and remember its VALUE for the wrap case, before the backward
    ; scan begins
    dec  a
    add  a, a
    ld   e, a
    ld   d, 0
    ld   hl, CHECK_ERROR_LIST
    add  hl, de                              ; HL = address of the
                                            ; last entry
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    dec  hl                                    ; DE = last entry's
                                              ; value; HL back to its
                                              ; own low byte
    ld   (WRAP_TARGET), de

.scan_loop:
    push bc
    push hl                                     ; save the scan
                                               ; pointer

    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    dec  hl                                       ; DE = the entry at
                                                 ; the current scan
                                                 ; position

    ld   hl, (CUR_EDIT_POS)
    or   a
    sbc  hl, de
    jr   c, .not_this_one                          ; entry > CUR_EDIT_POS
    ld   a, h
    or   l
    jr   z, .not_this_one                            ; entry ==
                                                    ; CUR_EDIT_POS — not
                                                    ; strictly less,
                                                    ; excluded

    ; found — entry (in DE) is strictly less than CUR_EDIT_POS
    pop  hl                                            ; discard saved
                                                      ; scan pointer
    pop  bc
    ex   de, hl
    or   a
    ret

.not_this_one:
    pop  hl                                              ; restore
                                                        ; scan pointer
    pop  bc
    dec  hl
    dec  hl                                                ; step
                                                          ; backward to
                                                          ; the previous
                                                          ; entry
    djnz .scan_loop

    ; exhausted — wrap to the remembered last entry
    ld   hl, (WRAP_TARGET)
    or   a
    ret

.empty:
    scf
    ret

; ============================================================================
; BASIC_RUN
; Runs the program currently in the program area, from the start —
; but only if BASIC_CHECK_PROGRAM finds nothing wrong first. If it
; does, this simply returns without running anything — CHECK_ERROR_COUNT
; is already set by BASIC_CHECK_PROGRAM, and BASIC_DRAW_STATUS_LINE
; picks it up on the very next redraw (back in the editor view, showing
; "N ERRORS FOUND" in place of the usual "LINE n/m"), rather than this
; routine taking over the whole screen the way a single runtime error
; still does. Deliberate: with the whole program visible again right
; after a failed check, you can browse it (and, once red-highlighted
; error lines and SYMBOL SHIFT+A/S navigation exist, jump straight to
; each problem) instead of staring at one line at a time on a screen
; that blocks the rest of the program from view — the full-screen
; single-error display was never going to work once those features
; existed, so this changes it now rather than building navigation on
; top of something that would need tearing out anyway.
;
; Rebuilds the label table fresh via BASIC_SCAN_LABELS before checking
; OR executing — see that routine's own comments for why this happens
; every RUN rather than being kept in sync incrementally during
; editing, and why a forward GOTO (referencing a label defined later in
; the program) still works correctly either way.
;
; The check pass is not exhaustive — see BASIC_CHECK_STATEMENT's own
; comments — so a program that passes it can still fail during real
; execution for a reason the static check can't see ahead of time
; (e.g. PRINT x/y where y is a variable, not a literal zero); the
; existing per-statement error reporting below still applies in that
; case, and still takes over the screen the way it always has — only
; the whole-program check-failure path changed here.
; In:  none
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_RUN:
    ; REAL BUG FOUND AND FIXED ([stated]-reported, 2026-08-19): the
    ; check used to run AFTER GFX_CLS/BASIC_RESET_ROW_SHADOW and the
    ; BASIC_OUTPUT_ROW/COL/PENDING_ERROR_MSG/GOTO_TARGET resets below —
    ; so a FAILED check still blanked the screen and reset all of that
    ; RUN-only state, for a run that was about to be rejected anyway.
    ; The check itself never needed any of that (BASIC_FULL_CHECK_EXROM
    ; only touches the label table and CHECK_ERROR_COUNT/CHECK_ERROR_
    ; LIST/CHECK_FIRST_ERROR_STMT, none of which this side-effect block
    ; sets), so there's no reason it must run after them. Moved the
    ; check first, and everything below it only runs once we're
    ; actually about to execute — [stated] reported RUN sometimes
    ; needing several presses (with a correct, unchanged program and
    ; cursor already confirmed correctly on the sentinel) before it
    ; actually ran, each failed attempt visually looking like "goes
    ; away, program is listed again"; this removes one real source of
    ; needless screen churn on a failed attempt, though it was not
    ; possible to fully confirm from static reading alone whether it's
    ; the SAME mechanism [stated] hit — see working memory for the
    ; open status of this investigation.
    call BASIC_FULL_CHECK_EXROM         ; scan labels then check the
                                        ; whole program — GOTO
                                        ; validation needs the label
                                        ; table populated first; both
                                        ; now live in EXROM (see that
                                        ; wrapper's own header)

    ld   hl, (CHECK_ERROR_COUNT)
    ld   a, h
    or   l
    jp   nz, .return_to_editor          ; something failed — leave the
                                        ; CURRENT editor screen exactly
                                        ; as it was; BASIC_DRAW_STATUS_
                                        ; LINE picks up CHECK_ERROR_
                                        ; COUNT on the very next redraw

    ; RUN owns giving itself a clean screen — a caller (the editor's
    ; last redraw, or whatever was on screen before) shouldn't leak
    ; into a program's own output. Was originally the test file's job
    ; (rom/test_basic.asm's COLD_START), which meant output visibly
    ; overlapped the just-typed statement — confirmed as a real
    ; annoyance in testing, not just a hypothetical edge case, so
    ; fixed here instead of leaving it to every future caller to
    ; remember. Only reached now once the check above has actually
    ; passed — see this routine's own header comment above.
    call GFX_CLS
    call BASIC_RESET_ROW_SHADOW           ; tell the screen-flicker
                                         ; fix's shadow state that the
                                         ; screen it was tracking no
                                         ; longer reflects reality —
                                         ; without this, the NEXT
                                         ; BASIC_REDRAW_PROGRAM call
                                         ; (whenever control returns to
                                         ; the editor after RUN) would
                                         ; see shadow entries that
                                         ; still matched what was
                                         ; showing BEFORE this GFX_CLS,
                                         ; and incorrectly skip
                                         ; redrawing rows this call
                                         ; just wiped blank — a real,
                                         ; related bug found alongside
                                         ; the cold-boot version of the
                                         ; same underlying problem (see
                                         ; BASIC_RESET_ROW_SHADOW's own
                                         ; comment)
    xor  a
    ld   (BASIC_OUTPUT_ROW), a
    ld   (BASIC_OUTPUT_COL), a          ; RUN always starts fresh at
                                        ; the top-left, same reasoning
                                        ; as BASIC_OUTPUT_ROW's own
                                        ; reset just above — a prior
                                        ; run's AT/TAB positioning must
                                        ; not leak into this one
    ld   hl, 0
    ld   (PENDING_ERROR_MSG), hl        ; no error pending yet this RUN
    ld   (GOTO_TARGET), hl              ; no jump pending at the start
                                        ; show, don't run anything

    ld   hl, (PROG_END)
    ld   (ARRAYS_END), hl                ; reset the dynamic arrays
                                         ; region to empty — arrays are
                                         ; RUN-scoped (classic BASIC's
                                         ; own "RUN implies CLEAR"),
                                         ; and this is also what makes
                                         ; it safe for the editor to
                                         ; freely overwrite whatever
                                         ; stale array bytes a PRIOR
                                         ; run left above PROG_END —
                                         ; see include/sysvars.inc's
                                         ; own ARRAYS_END header

    call MEM_LINE_FIRST
.loop:
    ld   a, h
    or   l
    jp   z, .return_to_editor         ; HL=0: end of program, stop

    push hl                            ; save this statement's pointer —
                                      ; BASIC_EXEC_STATEMENT clobbers HL,
                                      ; and MEM_LINE_NEXT below needs the
                                      ; ORIGINAL (unexecuted) pointer,
                                      ; not wherever execution left HL
    ld   (CUR_EXEC_STMT), hl            ; so BASIC_REPORT_ERROR knows
                                       ; which statement to show,
                                       ; regardless of how deep in the
                                       ; call chain it's invoked from

    call IO_CHECK_BREAK                 ; polled once per statement,
                                        ; same "between lines" cadence
                                        ; classic Sinclair BASIC uses —
                                        ; non-blocking, so this never
                                        ; slows execution down
    jr   nc, .no_break
    pop  hl                             ; balance the stack, same as
                                        ; .stop's own discard below —
                                        ; not needed once stopping
    ld   hl, MSG_BREAK
    call BASIC_REPORT_ERROR             ; reuses the same "message on
                                        ; row 0, failing statement's
                                        ; text on row 1" display an
                                        ; error uses — CUR_EXEC_STMT is
                                        ; already set to the statement
                                        ; BREAK was caught before
                                        ; executing
    jr   .return_to_editor
.no_break:
    ld   hl, (CUR_EXEC_STMT)            ; REAL BUG FOUND AND FIXED
                                        ; ([stated]-reported, screenshot:
                                        ; spurious "SYNTAX ERROR" on a
                                        ; perfectly valid FOR statement):
                                        ; IO_CHECK_BREAK's own documented
                                        ; contract destroys HL. The
                                        ; original code relied on HL
                                        ; still holding the statement
                                        ; pointer from before the push
                                        ; above — true before this
                                        ; session's BREAK-poll call was
                                        ; inserted between the push and
                                        ; this call, false after
                                        ; (classic lesson-1 register-
                                        ; survival violation, introduced
                                        ; by the very fix that added the
                                        ; poll). BASIC_EXEC_STATEMENT was
                                        ; being handed whatever garbage
                                        ; IO_CHECK_BREAK's keyboard scan
                                        ; left in HL instead of the real
                                        ; statement — reloading from
                                        ; CUR_EXEC_STMT (set to the exact
                                        ; same value just above, and
                                        ; untouched by IO_CHECK_BREAK)
                                        ; restores it correctly without
                                        ; disturbing the stack.
    call BASIC_EXEC_STATEMENT
    jr   c, .stop

    ld   hl, (GOTO_TARGET)
    ld   a, h
    or   l
    jr   z, .no_jump                   ; no GOTO fired during that
                                       ; statement — advance normally

    ; a GOTO fired: jump there instead of continuing sequentially. The
    ; pushed (pre-execution) statement pointer is no longer relevant —
    ; discard it rather than advance from it.
    pop  hl
    ld   hl, (GOTO_TARGET)
    ld   de, 0
    ld   (GOTO_TARGET), de              ; clear the pending flag before
                                       ; re-entering the loop, so the
                                       ; TARGET statement's own
                                       ; execution doesn't see a stale
                                       ; jump request left over from
                                       ; this one
    jr   .loop

.no_jump:
    pop  hl
    call MEM_LINE_NEXT
    jr   .loop
.stop:
    pop  hl                             ; balance the stack (discard —
                                       ; not needed once stopping)
    ld   hl, (PENDING_ERROR_MSG)
    ld   a, h
    or   l
    jr   z, .return_to_editor           ; a plain END/STOP — no error
                                        ; was recorded, nothing to show

    call BASIC_REPORT_ERROR             ; HL is already the pending
                                        ; message, loaded just above
.return_to_editor:
    ; ULAplus is deliberately a program-only display facility.  A
    ; program may leave its palette enabled for as long as it runs,
    ; but every route back to the editor (normal exhaustion, END/STOP,
    ; BREAK, a runtime error, or even a rejected pre-run check) must
    ; restore the stock ULA display.  Keeping this at BASIC_RUN's one
    ; exit boundary means future statements cannot accidentally bypass
    ; the lifecycle rule.  Every future BASIC_RUN exit must branch here
    ; rather than returning directly.
    call BASIC_ULAPLUS_DISABLE
    ret

; Select the ULAplus mode register and clear its enable bit.  This is
; kept in Home ROM because BASIC_RUN can return while EXROM is paged
; out, and paging a bank merely to write two ports would be larger and
; more fragile than the direct operation.
BASIC_ULAPLUS_DISABLE:
    ld   a, ULAPLUS_MODE_GROUP
    ld   bc, PORT_ULAPLUS_SELECT
    out  (c), a
    xor  a
    ld   bc, PORT_ULAPLUS_DATA
    out  (c), a
    ret

; ============================================================================
; BASIC_TRY_UPPERCASE_MATCH
; Checks whether EDIT_LINE_BUF starts with the given keyword
; (case-insensitive), followed by a real word boundary (space, '=', or
; end of line — so "PRINTER" is never mistaken for "PRINT"). If it
; matches, uppercases that prefix IN PLACE within EDIT_LINE_BUF and
; records its length in HILITE_KW_LEN. Hand-traced for "print x" vs
; KW_PRINT: BASIC_MATCH_KEYWORD matches the 5 letters case-insensitively
; and leaves HL at the space right after; the boundary check passes;
; the uppercase loop then rewrites EDIT_LINE_BUF's "print" to "PRINT"
; using the ORIGINAL saved start/keyword pointers (not the ones
; BASIC_MATCH_KEYWORD left advanced), and the final HL-minus-start
; subtraction gives exactly 5 — matching "PRINT"'s length.
; In:  HL = EDIT_LINE_BUF, DE = uppercase keyword reference
; Out: carry clear if matched (EDIT_LINE_BUF mutated, HILITE_KW_LEN
;      set); carry set if not (nothing changed)
; Destroys: AF, BC, DE, HL
; ============================================================================
; ============================================================================
; BASIC_KEYWORD_MATCH_OK
; Shared "matched" tail for the keyword-boundary matchers below: HL -
; DE is the matched keyword's length (HL = position just past it, DE =
; original text start, both already popped/set by the caller — each
; caller's own stack shape differs too much to unify further), records
; it in HILITE_KW_LEN, and returns with carry clear. Was duplicated
; identically across 4 call sites before this.
; In:  HL = position just past the matched keyword, DE = original text
;      start
; Out: HILITE_KW_LEN set; carry clear
; Destroys: AF, HL
; ============================================================================
BASIC_KEYWORD_MATCH_OK:
    or   a
    sbc  hl, de
    ld   a, l
    ld   (HILITE_KW_LEN), a
    or   a
    ret

; ============================================================================
; BASIC_TRY_DETECT_ONE
; Checks whether the text at HL starts with the given keyword
; (case-insensitive), followed by a real word boundary (space, '=', or
; end of string — so "PRINTER" is never mistaken for "PRINT"). Read-
; only: does NOT mutate the text, unlike the commit-time normalizer
; below. Used for displaying any already-settled line (bold where a
; keyword is), independent of whether that line is being typed right
; now.
; In:  HL = text pointer, DE = uppercase keyword reference
; Out: carry clear if matched (HILITE_KW_LEN set to the keyword's
;      length); carry set if not (HILITE_KW_LEN untouched — caller's
;      responsibility to have zeroed it first)
; Destroys: AF, DE, HL
; ============================================================================
BASIC_TRY_DETECT_ONE:
    push hl                        ; save original text start — the
                                   ; only thing needed for the length
                                   ; calc below
    call BASIC_MATCH_KEYWORD          ; on success, HL advances past the
                                      ; keyword; on failure, HL/DE are
                                      ; already restored by
                                      ; BASIC_MATCH_KEYWORD itself
    jr   c, .fail

    ld   a, (hl)
    or   a
    jr   z, .ok
    cp   " "
    jr   z, .ok
    cp   "="
    jr   z, .ok
    jr   .fail                        ; e.g. "PRINTER" — not a keyword

.ok:
    pop  de                            ; DE = original text start
    jr   BASIC_KEYWORD_MATCH_OK

.fail:
    pop  hl                              ; discard saved start (unused —
                                        ; just balances the stack)
    scf
    ret

; ============================================================================
; BASIC_TRY_DETECT_ENDIF
; Read-only counterpart to BASIC_TRY_DETECT_ONE, but for the compound
; two-word keyword "END IF" (or "ENDIF" — same zero-spaces tolerance
; as BASIC_MATCH_ENDIF, not a deliberate second spelling, just a
; harmless consequence of how the space-skip loop works). Needed
; because BASIC_TRY_DETECT_ONE only ever matches a single flat
; reference keyword — matching bare KW_END against "END IF" text would
; only bold "END" and silently leave "IF" unbolded, the exact same
; class of gap BASIC_MATCH_ENDIF exists to close on the execution
; side, just here for live display instead. Must be tried BEFORE the
; bare KW_END check in BASIC_DETECT_KEYWORD_PREFIX for the same
; reason: bare END's own boundary check (space counts) would otherwise
; wrongly match first and stop at "END", never reaching "IF".
; In:  HL = text pointer (NOT mutated)
; Out: carry clear + HILITE_KW_LEN set to the FULL matched span
;      (through "IF"'s last letter, including any spacing between the
;      two words) if matched; carry set + HILITE_KW_LEN untouched
;      otherwise
; Destroys: AF, DE, HL
; ============================================================================
BASIC_TRY_DETECT_ENDIF:
    push hl                              ; absolute original start
    ld   de, KW_END
    call BASIC_MATCH_KEYWORD
    jr   c, .fail

.skip_spaces:
    ld   a, (hl)
    cp   " "
    jr   nz, .try_if
    inc  hl
    jr   .skip_spaces

.try_if:
    ld   de, KW_IF
    call BASIC_MATCH_KEYWORD
    jr   c, .fail
    ld   a, (hl)
    or   a
    jr   z, .ok
    cp   " "
    jr   z, .ok
    cp   "="
    jr   z, .ok
    jr   .fail                            ; e.g. "END IFX" — not really
                                         ; END IF, matching the same
                                         ; boundary discipline as
                                         ; everything else here

.ok:
    pop  de                                ; DE = absolute original start
    jr   BASIC_KEYWORD_MATCH_OK

.fail:
    pop  hl                                 ; discard saved start,
                                           ; balance the stack
    scf
    ret

; ============================================================================
; BASIC_DETECT_KEYWORD_PREFIX
; Thin EXROM wrapper — the real multi-keyword bold-highlighting scan
; (table walk, per-segment loop, and boundary scanning, all of it)
; lives in rom/exrom_highlight.asm whole (2026-08-23), once it grew
; past what the Home budget could spare alongside the preload test
; harness (see that file's own header for the full story and the real
; build-overflow that forced the move). Stashes KEYWORD_HILITE_TABLE's
; own real address into HILITE_TABLE_PTR on every call, right before
; paging in — EXROM is a separate compilation unit with no way to see
; a Home ROM label's address directly (the exact "Label not found"
; trap this project's own CALC_EXIT_TRAMPOLINE KTAB entry comment
; already documents), so the real table walk needs a RUNTIME pointer
; instead of a compile-time one. Otherwise the same "page in / call
; the fixed entry / page out" shape as every other "_EXROM" wrapper in
; this file. The one call site (BASIC_PRINT_LINE_WRAPPED_COMMON,
; below) needed no changes: the contract is identical to what this
; routine's own body used to provide directly.
; In:  HL = text pointer (start of the whole line)
; Out: HILITE_KW_COUNT/HILITE_KW_START/HILITE_KW_SPANLEN populated
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_DETECT_KEYWORD_PREFIX:
    push hl
    ld   hl, KEYWORD_HILITE_TABLE
    ld   (HILITE_TABLE_PTR), hl
    pop  hl
    call BASIC_CALL_EXROM_INLINE
    DW   $C090

; ============================================================================
; BASIC_KW_OFFSET_BOLD
; Checks whether one absolute character offset within the line falls
; inside any of the spans BASIC_DETECT_KEYWORD_PREFIX recorded.
; Preserves BC/DE/HL — the print loop that calls this once per
; character still needs its own copies of all three right afterward.
; In:  A = absolute offset to test
; Out: carry set if this offset should render bold; carry clear
;      otherwise (always clear when HILITE_KW_COUNT is 0, e.g. the
;      active/plain-mode line, or a settled line with no keyword on
;      it at all)
; Destroys: AF
; ============================================================================
BASIC_KW_OFFSET_BOLD:
    push bc
    push de
    push hl
    ld   b, a                             ; B = offset under test
    xor  a
    ld   c, a                             ; C = slot index, 0-based
.loop:
    ld   a, (HILITE_KW_COUNT)
    cp   c
    jr   z, .no                           ; index == count: exhausted

    ld   hl, HILITE_KW_START
    ld   e, c
    ld   d, 0
    add  hl, de
    ld   a, b
    sub  (hl)                             ; A = offset - start[index]
    jr   c, .next                         ; offset < start[index]

    ld   hl, HILITE_KW_SPANLEN
    add  hl, de
    cp   (hl)                             ; carry set if (offset-start)
                                          ; < len[index] -> bold
    jr   c, .yes

.next:
    inc  c
    jr   .loop

.no:
    pop  hl
    pop  de
    pop  bc
    or   a
    ret

.yes:
    pop  hl
    pop  de
    pop  bc
    scf
    ret

; ============================================================================
; BASIC_UPPERCASE_KEYWORD_PREFIX
; The MUTATING counterpart to BASIC_DETECT_KEYWORD_PREFIX — used only
; at commit time (ENTER), not on every redraw. Uppercases a recognized
; keyword prefix of EDIT_LINE_BUF in place (real normalization of the
; typed/stored text, not just a display trick), matching the same
; boundary rule (space, '=', or end of line) so "PRINTER" is never
; mistaken for "PRINT". Hand-traced for "print x": BASIC_MATCH_KEYWORD
; matches the 5 letters case-insensitively and leaves HL at the space
; right after; the boundary check passes; the uppercase loop rewrites
; "print" to "PRINT" using the saved original start/keyword pointers
; (not BASIC_MATCH_KEYWORD's own advanced copies); the final HL-minus-
; start subtraction gives exactly 5.
; Table-driven since the keyword-table unification (see
; KEYWORD_HILITE_TABLE's own header) — walks the SAME table
; BASIC_DETECT_KEYWORD_PREFIX uses, via IX, calling the local
; .try_upper helper (unchanged) once per entry. HL is loaded with
; EDIT_LINE_BUF once before the loop, not before every call — like
; BASIC_TRY_DETECT_ONE, .try_upper restores HL on a failed match (see
; its own .no_match_cleanup), so the next iteration already has the
; right starting point.
; In:  none (reads/mutates EDIT_LINE_BUF)
; Out: HILITE_KW_LEN set (0 if nothing matched); carry clear if
;      matched, carry set if not
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_UPPERCASE_KEYWORD_PREFIX:
    xor  a
    ld   (HILITE_KW_LEN), a

    call BASIC_UPPERCASE_ENDIF            ; compound "END IF" — must be
                                         ; tried before the table
                                         ; below, which has no entry
                                         ; for it, same reasoning as
                                         ; the detect side
    ret  nc

    ld   hl, EDIT_LINE_BUF
    ld   ix, KEYWORD_HILITE_TABLE
.loop:
    ld   e, (ix+0)
    ld   d, (ix+1)
    ld   a, d
    or   e
    jr   z, .no_match                      ; 0,0 = end-of-table sentinel

    push ix                                ; preserve table position
                                          ; across the call
    call .try_upper                         ; HL = EDIT_LINE_BUF, still
                                           ; valid — .try_upper
                                           ; restores it on failure the
                                           ; same way BASIC_TRY_DETECT_
                                           ; ONE does (see .no_match_
                                           ; cleanup below)
    pop  ix
    ret  nc                                  ; matched — HILITE_KW_LEN
                                            ; already set, carry clear,
                                            ; propagate straight through

    inc  ix
    inc  ix
    jr   .loop

.no_match:
    scf
    ret

.try_upper:
    push hl
    push de
    call BASIC_MATCH_KEYWORD
    jr   c, .no_match_cleanup

    ld   a, (hl)
    or   a
    jr   z, .boundary_ok
    cp   " "
    jr   z, .boundary_ok
    cp   "="
    jr   z, .boundary_ok
    jr   .no_match_cleanup

.boundary_ok:
    pop  de
    pop  hl
    push hl
.upper_loop:
    ld   a, (de)
    or   a
    jr   z, .upper_done
    ld   a, (hl)
    call BASIC_TO_UPPER
    ld   (hl), a
    inc  hl
    inc  de
    jr   .upper_loop
.upper_done:
    pop  de
    jp   BASIC_KEYWORD_MATCH_OK

.no_match_cleanup:
    pop  de
    pop  hl
    scf
    ret

; ============================================================================
; BASIC_UPPERCASE_ENDIF
; Mutating counterpart to BASIC_TRY_DETECT_ENDIF, for the compound
; two-word keyword "END IF" — can't reuse BASIC_UPPERCASE_KEYWORD_
; PREFIX's own local .try_upper helper, since that assumes one
; contiguous reference keyword with no internal gap; "END" and "IF"
; are uppercased as two separate spans here, with whatever spacing sat
; between them left untouched (spaces don't need case-normalizing).
; Same "ENDIF" one-word tolerance as BASIC_MATCH_ENDIF/BASIC_TRY_
; DETECT_ENDIF, for the same reason (the space-skip loop tolerates
; zero spaces, not a deliberate second spelling).
; In:  none (reads/mutates EDIT_LINE_BUF)
; Out: carry clear + EDIT_LINE_BUF mutated + HILITE_KW_LEN set to the
;      full matched span if matched; carry set + nothing changed
;      otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_UPPERCASE_ENDIF:
    ld   hl, EDIT_LINE_BUF
    push hl                              ; absolute original start
    ld   de, KW_END
    call BASIC_MATCH_KEYWORD              ; case-insensitive match only —
                                         ; doesn't mutate source; HL
                                         ; advances past "END"'s 3
                                         ; letters on success
    jr   c, .fail

    ld   de, EDIT_LINE_BUF
    ld   b, 3
.upper_end_loop:
    ld   a, (de)
    call BASIC_TO_UPPER
    ld   (de), a
    inc  de
    djnz .upper_end_loop

.skip_spaces:
    ld   a, (hl)
    cp   " "
    jr   nz, .try_if
    inc  hl
    jr   .skip_spaces

.try_if:
    push hl                              ; "IF" segment's own start —
                                        ; needed to uppercase it once
                                        ; the match (and boundary)
                                        ; below confirm this really is
                                        ; "IF", not just some other
                                        ; text starting with those
                                        ; letters
    ld   de, KW_IF
    call BASIC_MATCH_KEYWORD
    jr   c, .fail_if

    ld   a, (hl)
    or   a
    jr   z, .boundary_ok
    cp   " "
    jr   z, .boundary_ok
    cp   "="
    jr   z, .boundary_ok
    jr   .fail_if
.boundary_ok:
    pop  de                                ; DE = "IF" segment's start
    push hl                                 ; save "just past IF"
                                           ; (final position)
    ld   b, 2
.upper_if_loop:
    ld   a, (de)
    call BASIC_TO_UPPER
    ld   (de), a
    inc  de
    djnz .upper_if_loop

    pop  hl                                  ; HL = final position
    pop  de                                   ; DE = absolute original
                                             ; start
    jp   BASIC_KEYWORD_MATCH_OK

.fail_if:
    pop  hl                                    ; discard "IF segment
                                              ; start" — falls through
                                              ; to .fail below to
                                              ; discard the absolute
                                              ; start too
.fail:
    pop  hl                                     ; discard absolute
                                               ; original start,
                                               ; balances the stack
                                               ; regardless of which
                                               ; stage failed
    scf
    ret

; ============================================================================
; BASIC_PRINT_LINE_HIGHLIGHTED / BASIC_PRINT_LINE_PLAIN_WRAPPED
; Prints one null-terminated line of text, word-wrapped across as many
; screen rows as EDITOR_WRAP_CALC says it needs (see kernel/editor),
; starting at the given row. Two entry points sharing one body — the
; only real difference between "settled statement, keyword-bold
; highlighted" and "actively-edited line, plain" turned out to be
; which characters get GFX_PUTCHAR_BOLD instead of GFX_PUTCHAR, and
; that's driven entirely by BASIC_KW_OFFSET_BOLD testing each
; character's absolute offset against whatever spans BASIC_DETECT_
; KEYWORD_PREFIX recorded (2026-08-23: now potentially several per
; line, one per colon-separated segment plus mid-statement keywords
; like THEN — see that routine's own header) — so the plain entry
; point just forces HILITE_KW_COUNT to 0 (no span table means nothing
; ever matches, so the bold branch below simply never triggers)
; instead of calling BASIC_DETECT_KEYWORD_PREFIX to compute real ones.
; No separate branch needed anywhere in the actual per-character loop.
;
; Originally two separate ~90-line routines with this exact same wrap/
; row/character-loop structure duplicated between them — [stated]'s
; second consolidation request this session, after noticing how much
; of it really was identical once the first (EDITOR_WRAP_TABLE_ADDR)
; made the overlap obvious.
;
; Keyword bold is decided from each character's ABSOLUTE offset within
; the line (row_start + column), not its screen column — a keyword
; only ever starts at absolute offset 0, which is also screen column 0
; on the FIRST wrapped row but not necessarily on any row after it.
;
; Row/column state is kept in memory (HILITE_*), reloaded fresh each
; loop iteration, rather than trying to preserve it in registers
; across the GFX_PUTCHAR/GFX_PUTCHAR_BOLD calls — both destroy BC
; entirely, so keeping values alive via push/pop juggling across many
; iterations would be needlessly fragile; a plain reload is simpler
; and safer, same lesson as this project's other register-survival
; bugs.
;
; Can't just call GFX_PRINT_STRING per row: that routine prints until
; a null terminator, and a wrapped row is a SLICE of a larger buffer
; with no null of its own at the break point — it would run straight
; through into the next row's text instead of stopping. So this walks
; characters itself, bounded by EDIT_WRAP_LEN.
; In:  HL = pointer to a null-terminated line (NOT mutated — assumed
;      already settled/normalized if it came from a stored statement),
;      B = starting row
; Out: none
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
    DEFINE EMIT_BASIC_EDITOR_DISPLAY
    INCLUDE "basic/editor_integration.asm"
    UNDEFINE EMIT_BASIC_EDITOR_DISPLAY

BASIC_APPEND_STR:
    call BASIC_CALL_EXROM_INLINE
    DW   $C0A2

STATUS_NEW_TEXT:    DB "NEW LINE", 0
STATUS_PREFIX_TEXT: DB "LINE ", 0
STATUS_SLASH_TEXT:  DB "/", 0

; ============================================================================
; FUNCTION_TABLE — built-in functions callable from expressions
; (ABS(x), SGN(x), MOD(x,y), ...), matched by BASIC_TRY_EVAL_FUNCTION.
;
; Each entry is 5 bytes: name pointer, final handler pointer, and argument
; shape. BASIC_EVAL_PRIMARY snapshots the latter two on the Z80 stack before
; recursively parsing arguments, then enters the handler with push/ret so HL
; and DE remain available for the parsed values.
; ============================================================================
FUNCTION_TABLE:
    DW KW_FN_ABS, BASIC_EVAL_PRIMARY.call_abs
    DB 1
    DW KW_FN_SGN, BASIC_EVAL_PRIMARY.call_sgn
    DB 1
    DW KW_FN_MOD, BASIC_EVAL_PRIMARY.call_mod
    DB 2
    DW KW_FN_SQR, BASIC_EVAL_PRIMARY.call_sqr
    DB 1
    DW KW_FN_DIV, BASIC_EVAL_PRIMARY.call_div
    DB 2
    DW KW_FN_INT, BASIC_EVAL_PRIMARY.call_int
    DB 1
    DW KW_FN_RND, BASIC_EVAL_PRIMARY.call_rnd
    DB 1
    DW KW_FN_POINT, BASIC_EVAL_PRIMARY.call_point
    DB 2
    DW KW_FN_ATTR, BASIC_EVAL_PRIMARY.call_attr
    DB 2
    DW KW_FN_SIN, BASIC_EVAL_PRIMARY.call_sin
    DB 1
    DW KW_FN_PEEK, BASIC_EVAL_PRIMARY.call_peek
    DB 1
    DW KW_FN_FREE, BASIC_EVAL_PRIMARY.call_free
    DB 0
    DW KW_FN_USR, BASIC_EVAL_PRIMARY.call_usr
    DB 1
    DW KW_FN_PI, BASIC_EVAL_PRIMARY.call_pi
    DB 0
    DW KW_FN_RAD, BASIC_EVAL_PRIMARY.call_rad
    DB 1
    DW KW_FN_DEG, BASIC_EVAL_PRIMARY.call_deg
    DB 1
    ; KW_FN_INKEY/FUNC_ID_INKEY removed (2026-08-22) — INKEY$ upgraded
    ; to return a real string, moved to STRING_FUNCTION_TABLE below
    ; (STRFUNC_ID_INKEY) now that string scalars/comparison exist to
    ; make that worthwhile. See docs/basic_language_reference.md's own
    ; INKEY$ section for the full history.
    DW KW_FN_STICK, BASIC_EVAL_PRIMARY.call_stick
    DB 1
    DW KW_FN_LEN, BASIC_EVAL_PRIMARY.str_arg_len
    DB ARGC_STR1                       ; 1 string argument — see
                                      ; .do_function_call's own new
                                      ; ARGC_STR1/STR2 check, tried
                                      ; before the normal 0/1/2-numeric-
                                      ; arg dispatch
    DW KW_FN_CODE, BASIC_EVAL_PRIMARY.str_arg_code
    DB ARGC_STR1
    DW KW_FN_VAL, BASIC_EVAL_PRIMARY.str_arg_val
    DB ARGC_STR1
    ; INSTR dropped (2026-08-22) — see FUNC_ID_INSTR's own comment below
    DW KW_FN_DIMN, BASIC_EVAL_PRIMARY.array_name_dim_arg
    DB ARGC_ARRAYNAME
    DW KW_FN_HIT, BASIC_EVAL_PRIMARY.call_hit
    DB 2
    DW   0
ARGC_ARRAYNAME EQU 101   ; sentinel FUNC_CALL_ARGC value: DIMN's own
                         ; one argument is a bare array-name LETTER,
                         ; never evaluated as an expression at all,
                         ; unlike every real 0/1/2-arg numeric function
                         ; (see ARGC_STR1's own precedent for the same
                         ; reasoning, one value higher so the two
                         ; sentinels can never collide)

KW_FN_ABS: DB "ABS", 0
KW_FN_SGN: DB "SGN", 0
KW_FN_MOD: DB "MOD", 0
KW_FN_SQR: DB "SQR", 0
KW_FN_DIV: DB "DIV", 0
KW_FN_INT: DB "INT", 0
KW_FN_RND: DB "RND", 0
KW_FN_POINT: DB "POINT", 0
KW_FN_ATTR: DB "ATTR", 0
KW_FN_SIN: DB "SIN", 0
KW_FN_PEEK: DB "PEEK", 0
KW_FN_FREE: DB "FREE", 0
KW_FN_USR: DB "USR", 0
KW_FN_PI: DB "PI", 0
KW_FN_RAD: DB "RAD", 0
KW_FN_DEG: DB "DEG", 0
; KW_FN_INKEY moved to the STRING_FUNCTION_TABLE section below
; (2026-08-22, INKEY$'s string upgrade)
KW_FN_STICK: DB "STICK", 0
KW_FN_LEN: DB "LEN", 0
KW_FN_CODE: DB "CODE", 0
KW_FN_VAL: DB "VAL", 0
; KW_FN_INSTR removed (2026-08-22) — see FUNC_ID_INSTR's own comment
; above
KW_FN_DIMN: DB "DIMN", 0
KW_FN_HIT: DB "HIT", 0

; ============================================================================
; STRING_FUNCTION_TABLE
; Same table-driven shape as FUNCTION_TABLE above (name pointer + ID),
; one field smaller — no argcount byte, since each string-returning
; function's own argument shape differs in TYPE (numeric vs string),
; not just count, so parsing is hand-written per shape in BASIC_EVAL_
; STR_PRIMARY's own dispatch (see BASIC_TRY_EVAL_STR_FUNCTION above).
; STR_FUNC_ID_* constants live in include/sysvars.inc, shared with
; rom/exrom_strfuncs.asm, which reads STR_FUNC_CALL_ID to dispatch the
; real per-function transform — see that file's own header.
; ============================================================================
STRING_FUNCTION_TABLE:
    DW   KW_FN_CHR
    DB   STRFUNC_ID_CHR
    DW   KW_FN_STR
    DB   STRFUNC_ID_STR
    DW   KW_FN_UPPER
    DB   STRFUNC_ID_UPPER
    DW   KW_FN_LOWER
    DB   STRFUNC_ID_LOWER
    DW   KW_FN_LEFT
    DB   STRFUNC_ID_LEFT
    DW   KW_FN_RIGHT
    DB   STRFUNC_ID_RIGHT
    ; FILL$ dropped (2026-08-22) — see FUNC_ID_INSTR's own FUNCTION_
    ; TABLE comment for why
    DW   KW_FN_INKEY
    DB   STRFUNC_ID_INKEY
    DW   0

KW_FN_CHR: DB "CHR$", 0
KW_FN_STR: DB "STR$", 0
KW_FN_UPPER: DB "UPPER$", 0
KW_FN_LOWER: DB "LOWER$", 0
KW_FN_LEFT: DB "LEFT$", 0
KW_FN_RIGHT: DB "RIGHT$", 0
KW_FN_INKEY: DB "INKEY$", 0       ; called as INKEY$() -- the "(" is
                                 ; still required, matching FREE()/PI()'s
                                 ; own zero-argument convention
                                 ; (BASIC_MATCH_FUNCTION_NAME insists on
                                 ; one), not real classic BASIC's bare
                                 ; INKEY$ with no parens at all

; ---- keyword reference strings (uppercase, null-terminated; read-only
; ROM data, fine — BASIC_MATCH_KEYWORD only reads these) ----
; Statement/connector keywords ALSO validated by the checker (rom/
; exrom_checker.asm) now live in include/checker_keywords.inc —
; INCLUDEd by both this file and that one, single source of truth
; (2026-08-19, replacing a hand-duplicated copy + a dedicated sync-
; check tool). Keywords the checker never sees stay directly below,
; Home-only.
    INCLUDE "include/checker_keywords.inc"
KW_RUN:   DB "RUN", 0
KW_HELP:  DB "HELP", 0
KW_AND:     DB "AND", 0
KW_OR:      DB "OR", 0
KW_NOT:     DB "NOT", 0
KW_NEW:     DB "NEW", 0
KW_LIST:    DB "LIST", 0
KW_EDIT:    DB "EDIT", 0
KW_DELETE:  DB "DELETE", 0
KW_SAVE:    DB "SAVE", 0
KW_LOAD:    DB "LOAD", 0
KW_STEP:    DB "STEP", 0          ; connector keyword within FOR's own
                                 ; grammar only, same non-statement-
                                 ; leading role KW_TO (include/checker_
                                 ; keywords.inc) has — still
                                 ; deliberately NOT in KEYWORD_HILITE_
                                 ; TABLE (2026-08-23: KW_THEN, the
                                 ; other connector that used to share
                                 ; this same reasoning, joined the
                                 ; table once BASIC_DETECT_KEYWORD_
                                 ; PREFIX stopped being limited to a
                                 ; line's very first word — see that
                                 ; table's own header. STEP/TO stay out
                                 ; simply because nobody's asked for
                                 ; them yet, not because of any
                                 ; remaining technical limitation.)

; ---- KEYWORD_HILITE_TABLE: the single list of keywords eligible for
; live bold-highlighting (BASIC_DETECT_KEYWORD_PREFIX) and commit-time
; uppercase normalization (BASIC_UPPERCASE_KEYWORD_PREFIX). Both
; routines now walk this ONE table instead of each keeping their own
; hardcoded copy — previously two separate hardcoded lists that had to
; be kept in sync by hand, which is exactly how IF/ELSEIF/ELSE shipped
; without bolding (see docs/programmers_reference.md's basic/ section
; for the full story). Adding a keyword to bold/uppercase highlighting
; now means adding ONE row here; both consumers pick it up
; automatically. Each entry is a pointer to a KW_ reference string,
; terminated by a 0 word. Order matches the original two hardcoded
; lists exactly (order is harmless either way per
; BASIC_MATCH_KEYWORD_BOUNDARY's own behavior, but kept identical to
; avoid any behavioral change). "END IF" is NOT in this table — it's a
; compound two-word keyword handled by its own dedicated pre-check
; (BASIC_TRY_DETECT_ENDIF / BASIC_UPPERCASE_ENDIF) before either loop
; starts, same as before this change.
;
; BASIC_DETECT_KEYWORD_PREFIX bolds EVERY colon-separated segment's own
; LEADING keyword now (2026-08-23), not just the line's very first —
; that's what lets "INK 7:PAPER 5" bold both INK and PAPER. KW_THEN is
; in this table but is CURRENTLY DEAD WEIGHT, not a working case: it's
; never a colon-segment's own leading word in valid grammar (nothing
; ever legitimately starts a statement with THEN), so the segment-
; start-only scan can never reach it. "IF x THEN y" is ONE segment (no
; colon at all), and the scanner only tries ONE match per segment, at
; its own start — it bolds IF, then just scans to the next ':' (finds
; none) and stops; THEN, a second word inside that same segment, is
; never attempted. Confirmed by the user directly (2026-08-23) after
; the segment-scan was first shipped: "if THEN don't bold the THEN
; with the current solution." This was always the known tradeoff of
; the cheaper colon-segment-only design over the fuller "any keyword,
; anywhere" scanner that was scoped and explicitly declined earlier
; the same session for its larger EXROM cost — not a regression, just
; a real gap in what got built. Catching THEN specifically (without
; the full general scanner) would need a small IF-THEN-specific
; extension to the segment scan, not attempted yet — EXROM only has
; ~19 bytes free at the moment this table was last touched, nowhere
; near enough room for it without shrinking something else first.
; BASIC_UPPERCASE_KEYWORD_PREFIX (commit-time) is UNCHANGED, still
; first-word-only — typing "if x then y" still only auto-uppercases
; "IF", not "THEN".
; NOTE: this table does NOT drive BASIC_EXEC_STATEMENT_CONTENT or
; BASIC_CHECK_STATEMENT_CONTENT — those two still have their own
; separate per-keyword dispatch, because each keyword's *validation*
; logic genuinely differs (some take an expression, some take an
; identifier, IF/ELSEIF have unique multi-part grammar) in a way that
; doesn't reduce to a flat list the way "is this word present, yes or
; no" does. Unifying those two as well would need each inline .check_*
; block split into its own named routine first — a bigger, separate
; change; not done here.
; ----
KEYWORD_HILITE_TABLE:
    DW   KW_PRINT, KW_END, KW_STOP, KW_INPUT, KW_GOTO
    DW   KW_IF, KW_ELSEIF, KW_ELSE
    DW   KW_FOR, KW_NEXT, KW_EXIT
    DW   KW_SPRITE
    DW   KW_RUN, KW_NEW, KW_LIST, KW_EDIT, KW_DELETE, KW_SAVE, KW_LOAD
    DW   KW_CLS, KW_REM, KW_BORDER
    DW   KW_INK, KW_PAPER, KW_FLASH, KW_BRIGHT, KW_INVERSE, KW_OVER
    DW   KW_AT, KW_TAB
    DW   KW_PLOT, KW_LINE, KW_BLOCK, KW_CIRCLE, KW_CPLOT, KW_FILL, KW_MODE
    DW   KW_ULAPLUS, KW_PALETTE
    DW   KW_POKE, KW_PAUSE, KW_RANDOMISE
    DW   KW_GOSUB, KW_RETURN, KW_CALL
    DW   KW_BEEP, KW_SOUND, KW_DIM
    DW   0                              ; end-of-table sentinel

; ---- error messages (uppercase, null-terminated — read by
; BASIC_REPORT_ERROR, never mutated) ----
; MSG_SYNTAX_ERROR / MSG_LABEL_NOT_FOUND now come from the
; include/checker_keywords.inc INCLUDE above (shared with the
; checker) — not redefined here.
MSG_DIVISION_BY_ZERO:  DB "DIVISION BY ZERO", 0
MSG_NUMERIC_OVERFLOW:  DB "NUMERIC OVERFLOW", 0
MSG_CALCULATOR_ERROR:  DB "CALCULATOR ERROR", 0
MSG_INVALID_MODE:      DB "INVALID MODE", 0
MSG_INVALID_SOUND_REGISTER: DB "INVALID SOUND REGISTER", 0
MSG_INVALID_ARRAY_SIZE:   DB "INVALID ARRAY SIZE", 0
MSG_ARRAY_ALREADY_DIMMED: DB "ARRAY ALREADY DIMENSIONED", 0
MSG_ARRAY_OUT_OF_MEMORY:  DB "OUT OF MEMORY", 0
; MSG_ARRAY_NOT_DIMMED moved to include/checker_keywords.inc — still
; raised from both here (array read/write) and rom/exrom_arrays.asm
; (DIMN).
MSG_ARRAY_SUBSCRIPT_RANGE: DB "SUBSCRIPT OUT OF RANGE", 0   ; also
                                 ; reused for "wrong number of
                                 ; subscripts" — see BASIC_ARRAY_
                                 ; ELEMENT_ADDR's own .wrong_count
; MSG_INVALID_ARGUMENT moved to include/checker_keywords.inc (shared —
; rom/exrom_strfuncs.asm's own CHR$ needs it too, 2026-08-22)
MSG_EXPRESSION_TOO_COMPLEX: DB "EXPRESSION TOO COMPLEX", 0
MSG_BREAK:              DB "BREAK", 0
MSG_ERROR_IN_TEXT:      DB " IN: ", 0    ; BASIC_REPORT_ERROR's own
                                         ; "<message> IN: <statement>"
                                         ; status-line separator
MSG_ERRORS_FOUND_SUFFIX:      DB " ERRORS FOUND", 0
MSG_ERROR_FOUND_SUFFIX_SING:  DB " ERROR FOUND", 0
MSG_MISSING_ENDIF:     DB "IF WITHOUT END IF", 0
MSG_MISSING_NEXT:      DB "FOR WITHOUT NEXT", 0
MSG_NEXT_WITHOUT_FOR:  DB "NEXT WITHOUT FOR", 0
MSG_GOSUB_TOO_DEEP:    DB "GOSUB TOO DEEP", 0
MSG_EXIT_WITHOUT_FOR:  DB "EXIT WITHOUT FOR", 0
; MSG_SPRITE_* moved to rom/exrom_sprite.asm alongside SPRITE GRAB/
; SHOW/HIDE's own code (2026-08-22 ROM-shrink pass)
MSG_INVALID_RANGE:     DB "INVALID RANGE", 0
MSG_INVALID_FILENAME:  DB "INVALID FILENAME", 0
; MSG_LOAD_FAILED/MSG_SAVED/MSG_LOADED/MSG_SAVE_FAILED_TOO_LARGE/
; MSG_SAVING_PREFIX/MSG_LOADING_PREFIX/MSG_PERCENT_SIGN/MSG_LOADED_
; ERRORS_PREFIX/MSG_BLOCKS_LOST_SUFFIX/MSG_DIAG_STAGE_PREFIX/MSG_DIAG_
; PILOT_PREFIX/MSG_DIAG_SUM_PREFIX moved to rom/exrom_storage.asm
; (2026-08-22, ROM-size audit) alongside BASIC_FORMAT_STORAGE_STATUS,
; the only routine that ever referenced them.
