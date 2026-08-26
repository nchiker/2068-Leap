; ============================================================================
; kernel/editor/editor.asm — full-screen program editor
;
; ** DEBUG-INSTRUMENTED COPY for rom/test_nav_hook_debug.asm — NOT the
; real kernel/editor/editor.asm. ** Border-color markers trace the
; UP/DOWN nav-hook dispatch (red/yellow/cyan/green), and a cycling hex
; digit at top-right proves the loop stays alive. EDITOR_LOOP's own
; IO_READ_KEY already blocks naturally between keypresses, so state
; should hold steady on its own — an earlier draft added an extra
; pause here too, but it used a raw key-down check that silently
; consumed the user's NEXT intended keypress (e.g. a second UP press)
; as a mere "continue" signal rather than letting it reach real
; navigation logic, which was actually the cause of some confusing
; test results. Removed. Diff this against the real
; kernel/editor/editor.asm if you need the unmodified version; do not
; use this file for anything but this specific diagnostic.
;
; Replaces the original Sinclair line editor (which only ever let you edit
; the current input line, one line at a time, with no cursor movement
; across lines). This editor lets you move the cursor freely around the
; whole displayed program, insert/delete anywhere, search, and delete
; blocks of text — while keeping the "switch on and start typing"
; immediacy the machine is known for.
;
; Public API is declared in include/kernel_api.inc. BASIC (basic/) calls
; EDITOR_ENTER to hand control to the editor and gets control back at
; EDITOR_EXIT with the edited text committed to the program area via the
; normal kernel storage routines (kernel/memory, not yet written).
;
; NO LINE NUMBERS (design decision, see docs/programmers_reference.md):
; following QL SuperBASIC rather than classic Sinclair BASIC, this ROM's
; BASIC has no line numbers. GOTO/GOSUB targets are labels; structured
; control flow (procedures, REPeat/END REPeat, etc.) covers most of what
; line numbers + GOTO used to do. Consequences for this module:
;   - There is no EDITOR_RENUMBER. Renumbering only exists to keep GOTO
;     targets and line labels in sync after edits; with no line numbers
;     to renumber, the whole problem disappears rather than needing a
;     replacement.
;   - EDITOR_BLOCK_DELETE addresses text by cursor/selection position
;     (line index in the visible program, or a marked start/end position)
;     instead of by line number — see its header below.
;   - EDITOR_SEARCH is unaffected; still a plain substring scan.
;
; Design notes:
;   - Line buffer is separate from the in-place screen bitmap; the editor
;     renders from the buffer each frame/keypress rather than editing
;     screen bytes directly, so redraw logic is one routine, not scattered
;     special cases (this is the main structural difference vs. the
;     original ROM's editor).
;   - Cursor position is tracked as (row, col) in EDIT_CURSOR_ROW/COL,
;     plus a buffer offset EDIT_BUF_OFFSET kept in sync with it.
;   - Insert/delete operate on the buffer first, then trigger a redraw of
;     just the affected line (fast path) or full screen (rare path, e.g.
;     after block delete).
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"       ; owned by kernel/memory — see that
                                        ; file; EDIT_CURSOR_ROW/COL,
                                        ; EDIT_BUF_OFFSET, EDIT_LINE_BUF and
                                        ; EDIT_LINE_BUF_LEN are all defined
                                        ; there now, not duplicated here
    INCLUDE "include/keys.inc"          ; KEY_ENTER — cursor keys not yet
                                        ; defined, see that file

; ---- direction constants for EDITOR_MOVE_CURSOR ----
EDIR_UP             EQU 0
EDIR_DOWN           EQU 1
EDIR_LEFT           EQU 2
EDIR_RIGHT          EQU 3
EDIR_HOME           EQU 4       ; start of current line
EDIR_END            EQU 5       ; end of current line
EDIR_TOP            EQU 6       ; top of program
EDIR_BOTTOM         EQU 7       ; bottom of program

; ============================================================================
; EDITOR_INIT
; Clears editor state. Call once at cold start (and again on NEW).
; In:  none
; Out: EDIT_CURSOR_ROW/COL = 0, EDIT_BUF_OFFSET = 0, line buffer zeroed,
;      EDITOR_REDRAW_HOOK = 0 (default rendering — see that sysvar's
;      comment), EDITOR_NAV_HOOK = 0 (default UP/DOWN handling — see
;      that sysvar's comment)
; Destroys: AF, HL, BC
; ============================================================================
EDITOR_INIT:
    xor  a
    ld   (EDIT_CURSOR_ROW), a
    ld   (EDIT_CURSOR_COL), a
    ld   hl, 0
    ld   (EDIT_BUF_OFFSET), hl      ; 16-bit store — a previous draft
                                    ; used an 8-bit "ld (EDIT_BUF_OFFSET),a"
                                    ; here, which only zeroed the low
                                    ; byte of this 2-byte sysvar,
                                    ; leaving the high byte as whatever
                                    ; garbage was in RAM at cold start.
                                    ; Never caused a visible bug since
                                    ; the offset never exceeds 126 in
                                    ; practice, but a real latent gap —
                                    ; caught while touching this
                                    ; routine for an unrelated reason,
                                    ; fixed rather than left alone.
    ld   (EDITOR_REDRAW_HOOK), hl    ; also 0 — default rendering unless
                                    ; a caller (e.g. basic/) sets this
    ld   (EDITOR_NAV_HOOK), hl        ; also 0 — default (no-op)
                                    ; UP/DOWN handling unless a caller
                                    ; sets this
    ld   hl, EDIT_LINE_BUF
    ld   bc, EDIT_LINE_BUF_LEN
    call MEM_FILL_ZERO           ; kernel/memory — implemented
    ret

; ============================================================================
; EDITOR_ENTER
; Enters full-screen edit mode. Takes over keyboard scanning and the
; display until the user commits (ENTER on a clean line) or explicitly
; exits. Returns to caller only on exit.
; In:  HL = pointer to program text to load into the edit view
; Out: none (falls through to EDITOR_EXIT internally on commit)
; Destroys: AF, BC, DE, HL
; ============================================================================
EDITOR_ENTER:
    ld   (EDIT_PROGRAM_POS), hl    ; remember where this edit session
                                   ; belongs, for EDITOR_EXIT — see that
                                   ; routine's comment for why this alone
                                   ; isn't enough to make EDITOR_EXIT
                                   ; safe to call yet
    ; This still doesn't load existing text at HL into EDIT_LINE_BUF
    ; itself — it starts from whatever's already there (empty right
    ; after EDITOR_INIT, or whatever a caller put there beforehand).
    ; That's no longer a real gap now that EDITOR_NAV_HOOK exists: a
    ; caller can pre-populate EDIT_LINE_BUF before calling this (to
    ; start the session already editing existing text), and the hook
    ; lets it swap EDIT_LINE_BUF's content on UP/DOWN too — see
    ; basic/'s use of both for its multi-line program view.
    call EDITOR_REDRAW_SCREEN
EDITOR_LOOP:
    ; DIAGNOSTIC: cycling hex digit at row 0, column 31 (far right,
    ; clear of the main content on the left), incrementing every time
    ; this loop's top is reached — including before the very first
    ; keypress. If this keeps changing after the border reaches green,
    ; the loop is genuinely still alive and the problem is elsewhere
    ; (most likely IO_READ_KEY not detecting further presses). If it
    ; freezes, the loop has truly stopped returning here at all.
    ld   a, ($9001)
    inc  a
    and  $0F
    ld   ($9001), a
    push af
    cp   10
    jr   c, .diag_digit
    add  a, "A" - 10
    jr   .diag_have_char
.diag_digit:
    add  a, "0"
.diag_have_char:
    ld   b, 0
    ld   c, 31
    call GFX_PUTCHAR
    pop  af

    call IO_READ_KEY              ; kernel/io — implemented, including
                                  ; CAPS SHIFT+digit cursor/delete combos
                                  ; (see docs/hardware_notes.md — the
                                  ; TS2068 uses the standard Spectrum
                                  ; scheme, not dedicated cursor keys, an
                                  ; earlier draft here got that wrong)
    cp   KEY_ENTER
    jr   z, EDITOR_EXIT
    cp   KEY_CURSOR_LEFT
    jr   z, .move_left
    cp   KEY_CURSOR_RIGHT
    jr   z, .move_right
    cp   KEY_CURSOR_UP
    jr   z, .move_up
    cp   KEY_CURSOR_DOWN
    jr   z, .move_down
    cp   KEY_DELETE
    jr   z, .delete
    or   a
    jr   z, EDITOR_LOOP            ; A=0: IO_READ_KEY saw a key it
                                   ; doesn't have a mapping for yet
                                   ; (e.g. SYMBOL SHIFT alone) — ignore
                                   ; it rather than insert a NUL
    call EDITOR_INSERT_CHAR
    call EDITOR_REDRAW_SCREEN
    jr   EDITOR_LOOP

; EDITOR_NAV_HOOK contract (see that sysvar's comment in sysvars.inc):
; called with A = EDIR_UP or EDIR_DOWN, must end in a normal RET. The
; hook decides what "moving to a different line" means — typically
; loading different text into EDIT_LINE_BUF/EDIT_BUF_OFFSET — and
; EDITOR_LOOP redraws afterward regardless of what the hook did.
.move_left:
    ld   a, EDIR_LEFT
    jr   .do_move
.move_right:
    ld   a, EDIR_RIGHT
.do_move:
    call EDITOR_MOVE_CURSOR
    call EDITOR_REDRAW_SCREEN
    jr   EDITOR_LOOP

.move_up:
    ld   a, EDIR_UP
    jr   .do_nav
.move_down:
    ld   a, EDIR_DOWN
.do_nav:
    ld   ($9000), a                 ; DIAGNOSTIC: stash direction in
                                    ; fixed memory (not the stack) —
                                    ; keeping this instrumentation
                                    ; itself stack-neutral
    ld   a, 2                        ; red — entered .do_nav
    out  (PORT_ULA), a
    ld   a, ($9000)
    push af                       ; save direction across the hook check
    ld   hl, (EDITOR_NAV_HOOK)
    ld   a, h
    or   l
    jr   nz, .use_nav_hook

    pop  af                         ; no hook set — built-in (currently
                                    ; no-op) UP/DOWN handling
    call EDITOR_MOVE_CURSOR
    call EDITOR_REDRAW_SCREEN
    jr   EDITOR_LOOP

.use_nav_hook:
    ld   a, 6                          ; yellow — hook confirmed set
    out  (PORT_ULA), a
    pop  af                           ; A = EDIR_UP/EDIR_DOWN, for the hook
    ld   ($9000), a
    ld   a, 5                           ; cyan — about to jump (hl still
    out  (PORT_ULA), a                    ; holds the hook address, "out"
                                         ; doesn't touch it)
    ld   a, ($9000)
    ; Z80 has no indirect CALL instruction — only indirect JP. The
    ; standard idiom: push the address we want control to return to,
    ; then JP (HL); the hook's own RET pops that pushed address and
    ; lands us back at .hook_returned, same effect as CALL (HL) would
    ; have if it existed.
    ld   de, .hook_returned
    push de
    jp   (hl)
.hook_returned:
    ld   a, 4                             ; green — successfully returned
    out  (PORT_ULA), a                      ; from the hook
    call EDITOR_REDRAW_SCREEN
    ; (No extra pause here anymore — an earlier draft added one using a
    ; raw IO_ANY_KEY_DOWN check, but that's redundant: EDITOR_LOOP's
    ; own IO_READ_KEY call, right below via the jr, already blocks
    ; naturally until the next key. Worse, the raw check consumed
    ; ANY keypress as a "continue" signal rather than letting it reach
    ; the normal translation/dispatch logic — so a second UP press
    ; intended as the next navigation was being silently eaten as a
    ; mere dismissal instead of ever reaching BASIC_HANDLE_NAV. Removed
    ; once this was traced as the actual source of "press UP twice,
    ; second press does nothing/reverts" confusion.)
    jp   EDITOR_LOOP

.delete:
    call EDITOR_BACKSPACE
    call EDITOR_REDRAW_SCREEN
    jp   EDITOR_LOOP

; ============================================================================
; EDITOR_EXIT
; Commits the current line buffer back into the program area and returns
; control to BASIC.
; In:  editor state as left by EDITOR_ENTER's loop
; Out: program area updated via kernel/memory line-store routine
; Destroys: AF, HL, BC, DE
; ============================================================================
EDITOR_EXIT:
    ; EDIT_LINE_BUF holds raw null-terminated ASCII text; kernel/memory's
    ; MEM_LINE_STORE expects the length-prefixed, tokenized statement
    ; format documented in kernel/memory/memory.asm. Calling
    ; MEM_LINE_STORE directly on EDIT_LINE_BUF as-is would misread the
    ; first two characters typed as a 2-byte length field and corrupt
    ; the program area — a real bug, not a hypothetical one, caught by
    ; checking the two format contracts against each other rather than
    ; wiring the call and hoping it worked. The conversion (raw text ->
    ; tokenized statement) is fundamentally a basic/ tokenizer concern,
    ; not something kernel/editor should own — deferred until basic/
    ; exists. EDIT_PROGRAM_POS is tracked (see EDITOR_ENTER) so the
    ; position is ready to use the moment that conversion exists; this
    ; routine just doesn't call MEM_LINE_STORE with it yet.
    ret

; ============================================================================
; EDITOR_SCAN_LEN (internal, not in kernel_api.inc)
; Scans EDIT_LINE_BUF for its null terminator, storing the result in
; EDIT_CONTENT_LEN. Shared by EDITOR_INSERT_CHAR, EDITOR_DELETE_CHAR, and
; EDITOR_MOVE_CURSOR's RIGHT/END bounds checks, rather than duplicating
; this scan four times.
; In:  none
; Out: EDIT_CONTENT_LEN set; B = content length
; Destroys: AF, B, HL
; ============================================================================
EDITOR_SCAN_LEN:
    ld   hl, EDIT_LINE_BUF
    ld   b, 0
.loop:
    ld   a, b
    cp   EDIT_LINE_BUF_LEN
    jr   z, .done
    ld   a, (hl)
    or   a
    jr   z, .done
    inc  hl
    inc  b
    jr   .loop
.done:
    ld   a, b
    ld   (EDIT_CONTENT_LEN), a
    ret

; ============================================================================
; EDITOR_INSERT_CHAR
; Inserts one character at the current cursor position, shifting the rest
; of the line right, then advances the cursor past it. Refuses (carry
; set) if the line is already at EDIT_LINE_BUF_LEN-1 (one byte reserved
; for the trailing null, C-string style).
; In:  A = character to insert
; Out: carry clear on success, carry set if line full
; Destroys: AF, BC, DE, HL
; ============================================================================
EDITOR_INSERT_CHAR:
    push af                        ; save the char to insert
    call EDITOR_SCAN_LEN           ; B = content length

    ld   a, b
    cp   EDIT_LINE_BUF_LEN - 1
    jr   c, .has_room
    pop  af
    scf
    ret

.has_room:
    ; block_len = (content_len + 1) - EDIT_BUF_OFFSET — the "+1" folds
    ; the trailing null into the shift too, so it stays terminated.
    ; Hand-traced: buf="AB\0" (content_len=2), offset=1, insert 'X' ->
    ; block_len = 3-1 = 2 ("B\0"), shifted up by 1 to open the gap,
    ; giving "AXB\0" after the char is written — verified end to end.
    ld   a, (EDIT_CONTENT_LEN)
    inc  a
    ld   l, a
    ld   h, 0
    ld   de, (EDIT_BUF_OFFSET)
    or   a
    sbc  hl, de                      ; HL = block_len
    ld   b, h
    ld   c, l                          ; BC = block_len

    push bc                              ; save block_len across the
                                        ; insertion-pointer computation
    ld   hl, (EDIT_BUF_OFFSET)
    ld   de, EDIT_LINE_BUF
    add  hl, de                          ; HL = insertion pointer
    pop  bc                                ; BC = block_len (restored)
    ld   de, 1                              ; shift amount
    call MEM_SHIFT_UP

    pop  af                                  ; restore the char to insert
    ld   hl, (EDIT_BUF_OFFSET)
    ld   de, EDIT_LINE_BUF
    add  hl, de
    ld   (hl), a                              ; write it into the gap

    ld   hl, (EDIT_BUF_OFFSET)
    inc  hl
    ld   (EDIT_BUF_OFFSET), hl                 ; advance cursor past it

    or   a
    ret

; ============================================================================
; EDITOR_DELETE_CHAR
; Deletes the character at the current cursor position (forward-delete,
; like a DEL key — cursor doesn't move), shifting the rest of the line
; left. No-op if the cursor is at or past the end of the content.
; In:  none (uses EDIT_BUF_OFFSET)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
EDITOR_DELETE_CHAR:
    call EDITOR_SCAN_LEN            ; B = content length

    ; no-op check: offset >= content_length -> nothing to delete
    ld   h, 0
    ld   l, b
    ld   de, (EDIT_BUF_OFFSET)
    or   a
    sbc  hl, de                       ; HL = content_length - offset
    jr   c, .no_op                      ; borrow: offset > content_length
    ld   a, h
    or   l
    jr   z, .no_op                       ; zero: offset == content_length

    ; block_start = EDIT_LINE_BUF + offset + 1 (the char AFTER the one
    ; being deleted, through the trailing null)
    ld   hl, (EDIT_BUF_OFFSET)
    ld   de, EDIT_LINE_BUF
    add  hl, de
    inc  hl                             ; HL = block_start
    push hl                               ; save it across the block_len calc

    ; block_len = content_length - offset (recomputed cleanly rather
    ; than trying to reuse the no-op check's now-stale HL/flags — hand-
    ; traced: buf="AXB\0" (content_len=3), offset=1 (cursor on 'X') ->
    ; block_len=2 ("B\0"), shifted down by 1 from block_start=base+2 to
    ; base+1, giving "AB\0" — verified end to end.)
    ld   a, (EDIT_CONTENT_LEN)
    ld   l, a
    ld   h, 0
    ld   de, (EDIT_BUF_OFFSET)
    or   a
    sbc  hl, de                           ; HL = block_len
    ld   b, h
    ld   c, l                               ; BC = block_len
    pop  hl                                   ; HL = block_start (restored)

    ld   de, 1
    call MEM_SHIFT_DOWN
.no_op:
    ret

; ============================================================================
; EDITOR_BACKSPACE
; Deletes the character BEFORE the cursor and moves the cursor back —
; classic backspace semantics, as opposed to EDITOR_DELETE_CHAR's
; forward-delete (kept as its own primitive; this composes it with a
; cursor move rather than duplicating the shift logic). No-op at the
; start of the line. This is what the editor's DELETE key (CAPS
; SHIFT+0 / Fuse's mapped Backspace) actually calls — an earlier draft
; wired that key straight to EDITOR_DELETE_CHAR's forward-delete
; instead, which is the wrong behaviour for a key that both looks and
; is physically pressed like a backspace key.
; In:  none (uses EDIT_BUF_OFFSET)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
EDITOR_BACKSPACE:
    ld   hl, (EDIT_BUF_OFFSET)
    ld   a, h
    or   l
    ret  z                       ; already at start of line — nothing
                                 ; before the cursor to delete
    ld   a, EDIR_LEFT
    call EDITOR_MOVE_CURSOR
    jp   EDITOR_DELETE_CHAR        ; tail call — delete now happens at
                                  ; the position we just moved back to.
                                  ; Hand-traced: buf="AXB\0", offset=2
                                  ; -> move left -> offset=1 -> delete
                                  ; at offset 1 ('X') -> "AB\0",
                                  ; offset=1 — matches expected
                                  ; backspace result.

; ============================================================================
; EDITOR_MOVE_CURSOR
; Moves the cursor within the current line buffer. LEFT/RIGHT/HOME/END
; are implemented. UP/DOWN/TOP/BOTTOM need the multi-line scrollable
; program view (see EDITOR_ENTER's TODO) — deliberate no-ops for now,
; not undefined behaviour.
; In:  A = direction (EDIR_* constant)
; Out: EDIT_BUF_OFFSET updated (clamped, never past content or below 0)
; Destroys: AF, BC, DE, HL
; ============================================================================
EDITOR_MOVE_CURSOR:
    cp   EDIR_LEFT
    jr   z, .left
    cp   EDIR_RIGHT
    jr   z, .right
    cp   EDIR_HOME
    jr   z, .home
    cp   EDIR_END
    jr   z, .end
    ret                              ; UP/DOWN/TOP/BOTTOM: no-op, see header

.left:
    ld   hl, (EDIT_BUF_OFFSET)
    ld   a, h
    or   l
    ret  z                           ; already at 0
    dec  hl
    ld   (EDIT_BUF_OFFSET), hl
    ret

.right:
    call EDITOR_SCAN_LEN             ; B = content length
    ld   h, 0
    ld   l, b
    ld   de, (EDIT_BUF_OFFSET)
    or   a
    sbc  hl, de                        ; HL = content_length - offset
    ret  c                               ; borrow: already past end (shouldn't
                                        ; happen, but don't advance further
                                        ; if it somehow did)
    ld   a, h
    or   l
    ret  z                                ; zero: already at end
    ld   hl, (EDIT_BUF_OFFSET)
    inc  hl
    ld   (EDIT_BUF_OFFSET), hl
    ret

.home:
    ld   hl, 0
    ld   (EDIT_BUF_OFFSET), hl
    ret

.end:
    call EDITOR_SCAN_LEN              ; B = content length
    ld   h, 0
    ld   l, b
    ld   (EDIT_BUF_OFFSET), hl
    ret

; ============================================================================
; EDITOR_SEARCH
; Finds the next occurrence of a search string starting just after the
; cursor, wrapping to the top of the program once. Moves the cursor to
; the match on success.
; In:  HL = pointer to null-terminated search string
; Out: carry clear + cursor moved on match, carry set if not found
; Destroys: AF, BC, DE, HL
; ============================================================================
EDITOR_SEARCH:
    ; TODO: substring scan over program text, walking statements via
    ; MEM_LINE_FIRST/MEM_LINE_NEXT (kernel/memory — iterator exists now,
    ; scan loop itself doesn't yet). Documented stub for now.
    scf
    ret

; ============================================================================
; EDITOR_BLOCK_DELETE
; Deletes every program line in the inclusive range [HL, DE], addressed by
; editor line position (0-based index into the visible/logical program,
; e.g. as set by a mark-start/mark-end selection) rather than by line
; number — this ROM's BASIC has no line numbers (see header note above).
; No-op if the range is empty or out of order. Aborts without changing
; the program if any label inside the range is still referenced by a
; GOTO/GOSUB/RESTORE outside it (see docs/basic_language_reference.md,
; "Label table") — the same non-destructive property originally scoped
; for the (now-removed) EDITOR_RENUMBER.
; In:  HL = first line position, DE = last line position
; Out: carry clear on success, carry set + program unchanged on abort
; Destroys: AF, BC, DE, HL
; ============================================================================
EDITOR_BLOCK_DELETE:
    ; Mark-start/mark-end selection mechanism in the editor's input loop
    ; still doesn't exist (TODO, unchanged) — HL/DE below are shown as
    ; already-resolved positions for now.
    ;
    ; Non-destructive guarantee (see docs/basic_language_reference.md,
    ; "Label table"): before deleting, check the enclosing scope's label
    ; table for any label defined inside [HL, DE] that's referenced by a
    ; GOTO/GOSUB/RESTORE outside the range but still in that scope. This
    ; check is NOT implemented here or in kernel/memory — scanning
    ; program text for GOTO/GOSUB/RESTORE references needs a BASIC-syntax
    ; parser, which is basic/'s job (see kernel/memory/memory.asm's
    ; header). kernel/memory only has MEM_LABEL_LOOKUP against the
    ; DEFINITION table; the reference-scan half of this guarantee is
    ; still an open TODO once basic/ exists, not just an implementation
    ; detail to fill in here.
    call MEM_LINE_DELETE_RANGE     ; kernel/memory — routine exists, but see
                                   ; its own header: blocked on the same
                                   ; shift-primitive rewrite as EDITOR_EXIT
    ret

; ============================================================================
; EDITOR_REDRAW_SCREEN (internal)
; Redraws the current line buffer at a fixed screen row, then shows the
; cursor as a blinking inverse-video block at EDIT_BUF_OFFSET's column —
; GFX_INVERT_ATTR sets the ULA's hardware FLASH bit, so the blink is
; done by the hardware itself, no interrupt/timer code needed. Full
; multi-line scrolling program view is still TODO (see EDITOR_ENTER).
;
; Checks EDITOR_REDRAW_HOOK first: if a caller has set it (nonzero —
; see that sysvar's comment), control passes there instead of using the
; default rendering below. A plain JP, not CALL — the hook has the same
; "no input, no output, ret when done" contract as this routine itself,
; so whatever called EDITOR_REDRAW_SCREEN in the first place gets
; control back correctly once the hook's own RET runs. This is what
; lets basic/ own keyword highlighting without kernel/editor needing to
; know BASIC exists — kernel/editor stays generic, matching this
; project's own stated goal for kernel/* modules to stay reusable.
; ============================================================================
EDITOR_REDRAW_SCREEN:
    ld   hl, (EDITOR_REDRAW_HOOK)
    ld   a, h
    or   l
    jp   nz, .use_hook

    call GFX_CLS
    ld   hl, EDIT_LINE_BUF
    ld   b, 0
    ld   c, 0
    call GFX_PRINT_STRING

    ld   hl, (EDIT_BUF_OFFSET)
    ld   b, 0                     ; cursor's fixed row, matches the print
                                  ; above — both will need to track the
                                  ; real cursor row once multi-line
                                  ; scrolling exists
    ld   c, l                      ; EDIT_BUF_OFFSET fits in one byte
                                  ; (max 127, column is 0-31 anyway —
                                  ; TODO: this doesn't yet clamp/wrap for
                                  ; a line longer than 32 columns, since
                                  ; there's no line-wrap or horizontal
                                  ; scroll in the single-line view yet)
    call GFX_INVERT_ATTR
    ret

.use_hook:
    jp   (hl)
