; ============================================================================
; rom/exrom_editor.asm — full-screen program editor (EXROM-resident)
;
; Migrated from kernel/editor/editor.asm (2026-08-22) in a ROM-shrink
; pass. This is now the editor's single canonical implementation.
; kernel/editor/editor.asm is only a standalone-test compatibility
; adapter: it maps the KTAB_* external names below to direct Home
; routines and includes this exact file, so test and production editor
; logic cannot drift apart. Production external calls (to kernel/
; graphics, kernel/io, kernel/memory) route through the KTAB_* jump
; table because EXROM and Home are separate compilation units with no
; linker between them — see include/exrom_jumptable.inc. Every call
; between routines
; DEFINED IN THIS FILE (EDITOR_REDRAW_SCREEN, EDITOR_SCAN_LEN,
; EDITOR_MOVE_CURSOR, EDITOR_INSERT_CHAR, EDITOR_DELETE_CHAR, EDITOR_
; BACKSPACE, EDITOR_WRAP_TABLE_ADDR, EDITOR_EXIT) is UNCHANGED — still
; a plain call/jp, since they're all in this same EXROM image now.
;
; SIX entry points basic/basic.asm calls from Home: EDITOR_INIT,
; EDITOR_ENTER, EDITOR_WRAP_CALC, EDITOR_WRAP_OFFSET_TO_ROWCOL,
; EDITOR_WRAP_ROWCOL_TO_OFFSET, EDITOR_BLOCK_DELETE —
; each has its own fixed stub in rom/exrom_checker.asm ($C060-$C089)
; and its own thin BASIC_EDITOR_*_EXROM wrapper on the Home side
; (basic/basic.asm, near the other _EXROM wrappers). EDITOR_EXIT/
; INSERT_CHAR/DELETE_CHAR/BACKSPACE/MOVE_CURSOR/SEARCH are NOT called
; from basic/basic.asm directly (only internally, from within EDITOR_
; ENTER's own loop) — no stub needed for those, matching this file's
; own "only externally-reached entries get a stub" precedent from
; every other EXROM migration this session.
;
; PAGING NOTE: EDITOR_ENTER runs the ENTIRE interactive editing
; session — every keystroke — before ever returning to Home, via its
; own internal EDITOR_LOOP; Home's BASIC_EDITOR_ENTER_EXROM wrapper
; therefore pages EXROM in once, calls EDITOR_ENTER, and only pages
; back out once the whole session ends (ENTER on a clean line commits
; and falls through EDITOR_EXIT). EDITOR_NAV_HOOK/EDITOR_REDRAW_HOOK
; (set by basic/ to its own Home routines, e.g. for keyword-
; highlighted redraw and multi-line cursor navigation) are invoked via
; a plain `jp (hl)` straight into Home — safe regardless of chunk 6's
; paging state, since Home ROM ($0000-$3FFF) is always mapped there
; regardless of what's paged into chunk 6 ($C000-$DFFF). If one of
; those Home-side hooks itself needs to call back into EXROM (e.g. the
; redraw hook re-running EDITOR_WRAP_CALC once per visible program
; line), its own thin wrapper's page-in/out is a cheap BANK_EXROM_
; DEPTH counter bump, not a real second port write — see kernel/bank/
; bank.asm's own header for the nesting-safety mechanism this whole
; design leans on. Nothing this project's sysvars ever use lives in
; chunk 6, so keeping it paged to EXROM for an entire (potentially
; minutes-long) editing session is safe.
; ============================================================================

; ---- direction constants for EDITOR_MOVE_CURSOR: EDIR_* now live in
; include/sysvars.inc (2026-08-22), not here — basic/basic.asm's own
; EDITOR_NAV_HOOK target (BASIC_HANDLE_NAV) reads them as plain
; compile-time values too, and needs them from the Home side where
; this file (EXROM-only) isn't reachable from; sysvars.inc is the
; shared file both already INCLUDE, same reasoning STRFUNC_ID_* used
; there. ----

; ============================================================================
; EDITOR_INIT
; Clears editor state. Call once at cold start (and again on NEW).
; In:  none
; Out: EDIT_BUF_OFFSET = 0, line buffer zeroed,
;      EDITOR_REDRAW_HOOK = 0 (default rendering — see that sysvar's
;      comment), EDITOR_NAV_HOOK = 0 (default UP/DOWN handling — see
;      that sysvar's comment)
; Destroys: AF, HL, BC
; ============================================================================
EDITOR_INIT:
    xor  a
    ld   hl, 0
    ld   (EDIT_BUF_OFFSET), hl
    ld   (EDITOR_REDRAW_HOOK), hl    ; also 0 — default rendering unless
                                    ; a caller (e.g. basic/) sets this
    ld   (EDITOR_NAV_HOOK), hl        ; also 0 — default (no-op)
                                    ; UP/DOWN handling unless a caller
                                    ; sets this
    ld   hl, EDIT_LINE_BUF
    ld   bc, EDIT_LINE_BUF_LEN
    jp KTAB_MEM_FILL_ZERO

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
    call KTAB_IO_READ_KEY         ; including CAPS SHIFT+digit cursor/
                                  ; delete combos (see docs/hardware_
                                  ; notes.md — the TS2068 uses the
                                  ; standard Spectrum scheme, not
                                  ; dedicated cursor keys)
    cp   KEY_ENTER
    jp   z, EDITOR_EXIT
    cp   KEY_CURSOR_LEFT
    jp   z, .move_left
    cp   KEY_CURSOR_RIGHT
    jp   z, .move_right
    cp   KEY_CURSOR_UP
    jp   z, .move_up
    cp   KEY_CURSOR_DOWN
    jp   z, .move_down
    cp   KEY_DELETE
    jp   z, .delete
    cp   KEY_DELETE_LINE
    jp   z, .delete_line_key
    cp   KEY_INSERT_LINE
    jp   z, .insert_line
    cp   KEY_NEXT_ERROR
    jp   z, .next_error
    cp   KEY_PREV_ERROR
    jp   z, .prev_error
    or   a
    jp   z, EDITOR_LOOP            ; A=0: IO_READ_KEY saw a key it
                                   ; doesn't have a mapping for yet
                                   ; (e.g. SYMBOL SHIFT alone) — ignore
                                   ; it rather than insert a NUL
    call EDITOR_INSERT_CHAR
    call EDITOR_REDRAW_SCREEN
    jp   EDITOR_LOOP

; EDITOR_NAV_HOOK contract (see that sysvar's comment in sysvars.inc):
; called with A = EDIR_UP, EDIR_DOWN, EDIR_DELETE_LINE,
; EDIR_INSERT_LINE, EDIR_NEXT_ERROR, or EDIR_PREV_ERROR, must end in a
; normal RET. The hook decides what each means — typically loading
; different text into EDIT_LINE_BUF/EDIT_BUF_OFFSET, or restructuring
; the underlying program storage, or moving the cursor to a flagged
; statement — and EDITOR_LOOP redraws afterward regardless of what the
; hook did.
.move_left:
    ld   a, EDIR_LEFT
    jr   .do_move
.move_right:
    ld   a, EDIR_RIGHT
.do_move:
    ; Cursor-only fast path: the text, wrap table, active screen row, view,
    ; and status are all unchanged by LEFT/RIGHT. Save the old physical
    ; cursor cell, move the buffer offset, restore that old cell's normal
    ; attribute, then map/draw only the new cursor. This avoids routing a
    ; cursor key through BASIC_REDRAW_PROGRAM's complete visible-program
    ; traversal. EDITOR_WRAP_OFFSET_TO_ROWCOL reads EDIT_BUF_OFFSET directly
    ; and the wrap table is guaranteed current from the preceding redraw.
    push af
    call EDITOR_WRAP_OFFSET_TO_ROWCOL   ; B=old sub-row, C=old column
    ld   a, (BASIC_ACTIVE_ROW)
    add  a, b
    ld   b, a                           ; B=old physical row
    pop  af
    push bc
    call EDITOR_MOVE_CURSOR
    pop  bc
    call .clear_cursor_attr
    call EDITOR_WRAP_OFFSET_TO_ROWCOL   ; B=new sub-row, C=new column
    ld   a, (BASIC_ACTIVE_ROW)
    add  a, b
    ld   b, a                           ; B=new physical row
    call KTAB_GFX_INVERT_ATTR
    jp   EDITOR_LOOP

; Restores a cursor cell to the active editor line's known base attribute.
; BASIC_REDRAW_PROGRAM clears active-line rows through GFX_CLEAR_ROW before
; drawing, so ATTR_DEFAULT is exactly what sits underneath the cursor. A
; direct RAM write also clears FLASH; applying GFX_INVERT_ATTR twice would
; swap the colors back but incorrectly leave FLASH set. Attribute RAM stays
; visible while EXROM occupies chunk 6, so no Home callback is needed.
; In: B = physical row, C = column
; Destroys: AF, DE, HL
.clear_cursor_attr:
    ld   h, 0
    ld   l, b
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl                       ; HL = row * 32
    ld   de, ATTR_ADDR
    add  hl, de
    ld   d, 0
    ld   e, c
    add  hl, de
    ld   (hl), %00111000                 ; paper 7, ink 0, no FLASH
    ret

.move_up:
    ld   a, EDIR_UP
    jr   .do_nav
.move_down:
    ld   a, EDIR_DOWN
.do_nav:
    push af                       ; save direction across the hook check
    ld   hl, (EDITOR_NAV_HOOK)
    ld   a, h
    or   l
    jr   nz, .use_nav_hook

    pop  af                         ; no hook set — built-in (currently
                                    ; no-op) UP/DOWN handling
    call EDITOR_MOVE_CURSOR
    call EDITOR_REDRAW_SCREEN
    jp   EDITOR_LOOP

.use_nav_hook:
    pop  af                           ; A = EDIR_UP/EDIR_DOWN, for the hook
    ; Z80 has no indirect CALL instruction — only indirect JP. The
    ; standard idiom: push the address we want control to return to,
    ; then JP (HL); the hook's own RET pops that pushed address and
    ; lands us back at .hook_returned, same effect as CALL (HL) would
    ; have if it existed. The hook itself is a Home address (basic/'s
    ; own routine) — reachable via a bare JP regardless of chunk 6's
    ; own paging state, since Home ROM is always mapped below $4000;
    ; see this file's own header for the full paging reasoning.
    ld   de, .hook_returned
    push de
    jp   (hl)
.hook_returned:
    call EDITOR_REDRAW_SCREEN
    jp   EDITOR_LOOP

.delete:
    ld   a, (EDIT_LINE_BUF)
    or   a
    jr   nz, .do_backspace            ; buffer has content — normal,
                                      ; character-level backspace
    ; buffer is already empty — this is basic/'s cue that "delete"
    ; here might mean "delete this whole line" rather than a character
    ; (which there's nothing left of anyway). kernel/editor doesn't
    ; know whether we're on a real existing line or the new-line
    ; sentinel — that's exactly what the hook is for.
    ld   a, EDIR_DELETE_LINE
    jr   .do_nav_only

.do_backspace:
    call EDITOR_BACKSPACE
    call EDITOR_REDRAW_SCREEN
    jp   EDITOR_LOOP

.delete_line_key:
    ; CAPS SHIFT+1 — unlike .delete above (which only reaches
    ; EDIR_DELETE_LINE once the buffer is already empty, since a
    ; plain DELETE is ordinarily a character-level backspace),
    ; KEY_DELETE_LINE always means "delete the whole current line",
    ; regardless of what's currently in EDIT_LINE_BUF — so it goes
    ; straight to the same EDIR_DELETE_LINE hook dispatch with no
    ; buffer check. Whatever's in the buffer is discarded; the hook
    ; (basic/'s BASIC_HANDLE_NAV — see kernel/editor's own dispatch
    ; contract above) reloads EDIT_LINE_BUF from the line that ends
    ; up at this index once the delete completes.
    ld   a, EDIR_DELETE_LINE
    jr   .do_nav_only

.insert_line:
    ld   a, EDIR_INSERT_LINE
    jr   .do_nav_only

.next_error:
    ld   a, EDIR_NEXT_ERROR
    jr   .do_nav_only

.prev_error:
    ld   a, EDIR_PREV_ERROR
    ; fall through to .do_nav_only

; EDIR_DELETE_LINE/EDIR_INSERT_LINE/EDIR_NEXT_ERROR/EDIR_PREV_ERROR
; dispatch. Unlike .do_nav above
; (EDIR_UP/DOWN, which EDITOR_MOVE_CURSOR genuinely implements), these
; four have NO built-in kernel/editor meaning at all — so unlike
; .do_nav, there's no fallback to EDITOR_MOVE_CURSOR when no hook is
; set, just a clean no-op instead. Same indirect-call idiom as .do_nav
; otherwise (push a return address, then JP (HL) — see that block's
; own comment for why, Z80 has no indirect CALL).
.do_nav_only:
    push af
    ld   hl, (EDITOR_NAV_HOOK)
    ld   a, h
    or   l
    jr   nz, .use_nav_hook_only

    pop  af                            ; no hook set — genuine no-op
    jp   EDITOR_LOOP

.use_nav_hook_only:
    pop  af
    ld   de, .hook_returned_only
    push de
    jp   (hl)
.hook_returned_only:
    call EDITOR_REDRAW_SCREEN
    jp   EDITOR_LOOP

; ============================================================================
; EDITOR_EXIT
; Ends the editor session and returns the raw line buffer to BASIC. The
; BASIC command loop owns normalization, tokenization, immediate-command
; handling, and committing an existing or new statement.
; In:  editor state as left by EDITOR_ENTER's loop
; Out: EDIT_LINE_BUF and EDIT_PROGRAM_POS remain available to the caller
; Destroys: none
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
    ; not something the generic editor should own. BASIC_COMMAND_LOOP now
    ; performs that conversion and commit after EDITOR_ENTER returns.
    ret

; ============================================================================
; EDITOR_SCAN_LEN (internal)
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
    call KTAB_MEM_SHIFT_UP

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
    ; than trying to reuse the no-op check's now-stale HL/flags)
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
    call KTAB_MEM_SHIFT_DOWN
.no_op:
    ret

; ============================================================================
; EDITOR_BACKSPACE
; Deletes the character BEFORE the cursor and moves the cursor back —
; classic backspace semantics, as opposed to EDITOR_DELETE_CHAR's
; forward-delete (kept as its own primitive; this composes it with a
; cursor move rather than duplicating the shift logic). No-op at the
; start of the line.
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

; ============================================================================
; EDITOR_MOVE_CURSOR
; Moves the cursor within the current line buffer. LEFT/RIGHT/HOME/END
; are implemented. UP/DOWN/TOP/BOTTOM need the multi-line scrollable
; program view — deliberate no-ops for now, not undefined behaviour.
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
; EDITOR_BLOCK_DELETE
; Deletes every program line in the inclusive range [HL, DE], addressed by
; editor line position (0-based index into the visible/logical program,
; e.g. as set by a mark-start/mark-end selection) rather than by line
; number — this ROM's BASIC has no line numbers.
; No-op if the range is empty or out of order. Aborts without changing
; the program if any label inside the range is still referenced by a
; GOTO/GOSUB/RESTORE outside it (see docs/basic_language_reference.md,
; "Label table").
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
    ; parser, which is basic/'s job. kernel/memory only has MEM_LABEL_
    ; LOOKUP against the DEFINITION table; the reference-scan half of
    ; this guarantee is still an open TODO once basic/ exists, not just
    ; an implementation detail to fill in here.
    jp KTAB_MEM_LINE_DELETE_RANGE

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
; know BASIC exists.
; ============================================================================
EDITOR_REDRAW_SCREEN:
    ld   hl, (EDITOR_REDRAW_HOOK)
    ld   a, h
    or   l
    jp   nz, .use_hook

    call KTAB_GFX_CLS
    ld   hl, EDIT_LINE_BUF
    ld   b, 0
    ld   c, 0
    call KTAB_GFX_PRINT_STRING

    ld   hl, (EDIT_BUF_OFFSET)
    ld   b, 0                     ; cursor's fixed row, matches the print
                                  ; above — both will need to track the
                                  ; real cursor row once multi-line
                                  ; scrolling exists
    ld   c, l                      ; EDIT_BUF_OFFSET fits in one byte
                                  ; (max 127, column is 0-31 anyway)
    jp KTAB_GFX_INVERT_ATTR

.use_hook:
    jp   (hl)                     ; Home address — safe regardless of
                                  ; chunk 6's own paging state, see this
                                  ; file's own header

; ============================================================================
; EDITOR_WRAP_CALC
; Splits one null-terminated line of text into display rows of at most
; 32 columns, breaking at the last space at-or-before column 32 (word-
; boundary wrap) rather than always at a fixed column — no word is ever
; split across rows. Falls back to a hard break at exactly column 32 only
; when a single "word" itself has no space within the whole 32-char
; window (e.g. a very long unbroken identifier or string literal) —
; unavoidable, there's nowhere else to break.
;
; Works on ANY null-terminated buffer, not just EDIT_LINE_BUF — callers
; pass HL, results always land in the shared EDIT_WRAP_* tables (see
; sysvars.inc), so a second call overwrites the first; nothing here is
; per-buffer. Caller must fully consume one buffer's wrap results
; before wrapping another.
;
; In:  HL = pointer to a null-terminated line (max EDIT_LINE_BUF_LEN-1
;      content chars — same limit as every other buffer this size in
;      the project; not re-checked here, the caller's own buffer size
;      already enforces it)
; Out: EDIT_WRAP_COUNT/START/LEN populated (see sysvars.inc); always at
;      least 1 row, even for an empty line (COUNT=1, START[0]=0,
;      LEN[0]=0)
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
EDITOR_WRAP_CALC:
    ld   (WRAP_TEXT_PTR), hl

    ; total content length, scanning for the null terminator
    ld   b, 0
.scan_len_loop:
    ld   a, b
    cp   EDIT_LINE_BUF_LEN - 1
    jr   z, .scan_len_done
    ld   a, (hl)
    or   a
    jr   z, .scan_len_done
    inc  hl
    inc  b
    jr   .scan_len_loop
.scan_len_done:
    ld   a, b
    ld   (WRAP_REMAIN), a

    xor  a
    ld   (WRAP_START_OFS), a
    ld   (WRAP_ROW_IDX), a

.row_loop:
    ; last row? remaining fits in one row outright — no scan needed
    ld   a, (WRAP_REMAIN)
    cp   33
    jr   c, .last_row                  ; remaining <= 32

    ; scan the 32-char window starting at WRAP_TEXT_PTR for the LAST
    ; space — IX walks the window without disturbing WRAP_TEXT_PTR,
    ; which stays the row's own start until a break is chosen below
    ld   hl, (WRAP_TEXT_PTR)
    push hl
    pop  ix
    ld   c, $FF                        ; C = position of last space
                                       ; found so far, $FF = "none yet"
    ld   b, 0                          ; B = window position 0-31
.scan_window:
    ld   a, (ix+0)
    cp   ' '
    jr   nz, .not_space
    ld   c, b
.not_space:
    inc  ix
    inc  b
    ld   a, b
    cp   32
    jr   nz, .scan_window

    ld   a, c
    cp   $FF
    jr   z, .hard_break

    ; word-boundary break: row content length = C (chars before the
    ; space), consumed = C + 1 (the space itself is skipped, never
    ; drawn)
    ld   a, c
    ld   d, a                          ; D = row content length
    inc  a
    ld   e, a                          ; E = consumed
    jr   .store_row

.hard_break:
    ld   d, 32                         ; row content length = full width
    ld   e, 32                         ; consumed = 32, nothing skipped
    jr   .store_row

.last_row:
    ld   a, (WRAP_REMAIN)
    ld   d, a                          ; row content length = whatever's
                                       ; left
    ld   e, a                          ; consumed = same — this is the
                                       ; final row, no next row to skip
                                       ; into
.store_row:
    ; write EDIT_WRAP_START[row_idx] and EDIT_WRAP_LEN[row_idx] — HL is
    ; free to use as a scratch table pointer here since WRAP_TEXT_PTR
    ; already holds the real text pointer safely in memory
    ld   a, (WRAP_ROW_IDX)
    ld   hl, EDIT_WRAP_START
    call EDITOR_WRAP_TABLE_ADDR
    ld   a, (WRAP_START_OFS)
    ld   (hl), a

    ld   a, (WRAP_ROW_IDX)
    ld   hl, EDIT_WRAP_LEN
    call EDITOR_WRAP_TABLE_ADDR
    ld   a, d
    ld   (hl), a

    ; advance: row start += consumed, remaining -= consumed,
    ; text ptr += consumed, row index += 1
    ld   a, (WRAP_START_OFS)
    add  a, e
    ld   (WRAP_START_OFS), a

    ld   a, (WRAP_REMAIN)
    sub  e
    ld   (WRAP_REMAIN), a

    ld   hl, (WRAP_TEXT_PTR)
    ld   b, 0
    ld   c, e
    add  hl, bc
    ld   (WRAP_TEXT_PTR), hl

    ld   a, (WRAP_ROW_IDX)
    inc  a
    ld   (WRAP_ROW_IDX), a

    ; two stop conditions: remaining == 0 (this was the last row,
    ; already computed and stored above via .last_row), or the row
    ; table is full (WRAP_MAX_ROWS — pathological input only, see this
    ; routine's header)
    cp   WRAP_MAX_ROWS                 ; A still holds the just-
                                       ; incremented row index
    jr   nc, .done
    ld   a, (WRAP_REMAIN)
    or   a
    jr   z, .done
    jp   .row_loop

.done:
    ld   a, (WRAP_ROW_IDX)
    ld   (EDIT_WRAP_COUNT), a
    ret

; ============================================================================
; EDITOR_WRAP_TABLE_ADDR
; HL += A — the "index into an 8-entry byte table" address computation
; shared by every wrap-table lookup in this file and in basic.asm's
; wrap-aware print routines (EDIT_WRAP_START/EDIT_WRAP_LEN are both
; this shape). No sign extension needed — every real caller's index is
; 0-7.
; In:  HL = table base, A = index
; Out: HL = table base + index
; Destroys: AF
; ============================================================================
EDITOR_WRAP_TABLE_ADDR:
    add  a, l
    ld   l, a
    ret  nc
    inc  h
    ret

; ============================================================================
; EDITOR_WRAP_OFFSET_TO_ROWCOL
; Maps a buffer offset into which wrapped display row it falls on and
; the column within that row, using whatever EDITOR_WRAP_CALC last
; computed — caller must call that first, on the matching buffer.
;
; A row's span covers its own content PLUS any word-wrap space skipped
; right after it (never drawn), so an offset landing exactly on that
; skipped space maps to the END of the row before it — column == that
; row's own content length — rather than jumping to the start of the
; next row. This keeps the cursor visually resting right after the
; last visible character instead of appearing to jump ahead by one.
;
; REAL BUG FIXED HERE (2026-08-23, user-reported: "flashing cursor in
; editor on long lines is not matching typing cursor - always appears
; to be the same place... column 13"). This routine's own entry stub
; (EXROM_ENTRY_EDITOR_WRAP_OFFSET_TO_ROWCOL, rom/exrom_checker.asm)
; does `call EXROM_VERIFY_KTAB_MAGIC` before jumping here — and that
; magic-check unconditionally overwrites A with the KTAB_MAGIC byte it
; compares, before this routine ever ran. Every Home-side caller sets
; A = EDIT_BUF_OFFSET right before calling in, but by the time this
; code actually executed, A held that fixed magic byte instead — the
; exact same bug class already found and fixed once this session in
; basic/basic.asm's own BASIC_PRINT_LINE_WRAPPED_COMMON (see that
; routine's own comment for the full writeup): any EXROM entry that
; needs a real argument in A, not just HL/DE/BC, is broken by the
; standard trampoline shape, because BOTH BANK_PAGE_EXROM_IN and the
; magic-check preamble use A internally. A constant wrong offset
; produces a constant wrong (row, column) — matching "always the same
; place" exactly. Fixed by reading EDIT_BUF_OFFSET directly from
; memory instead of trusting A to have survived the trampoline; every
; real caller already loaded A from this exact sysvar immediately
; before calling in anyway (basic/basic.asm, three call sites), so
; this changes nothing about what value is actually used, only where
; it's read from.
; In:  none (reads EDIT_BUF_OFFSET directly — low byte only, offset
;      never exceeds 127)
; Out: B = row index (0-based), C = column within that row (0-32)
; Destroys: AF, DE, HL
; ============================================================================
EDITOR_WRAP_OFFSET_TO_ROWCOL:
    ld   a, (EDIT_BUF_OFFSET)
    ld   e, a                          ; E = target offset
    ld   d, 0                          ; D = row index

.rc_loop:
    ld   hl, EDIT_WRAP_START
    ld   a, d
    call EDITOR_WRAP_TABLE_ADDR
    ld   a, (hl)
    ld   c, a                          ; C = this row's start offset

    ld   hl, EDIT_WRAP_LEN
    ld   a, d
    call EDITOR_WRAP_TABLE_ADDR
    ld   b, (hl)                       ; B = this row's content length

    ld   hl, EDIT_WRAP_COUNT
    ld   a, (hl)
    dec  a                             ; A = index of the last valid row
    cp   d
    jr   z, .rc_found                  ; D is the last row — always
                                       ; matches (target never exceeds
                                       ; total length, by contract)

    ; not the last row: bound = EDIT_WRAP_START[D+1]
    ld   hl, EDIT_WRAP_START
    ld   a, d
    inc  a
    call EDITOR_WRAP_TABLE_ADDR
    ld   a, (hl)                       ; A = bound (next row's start)
    cp   e                             ; A(bound) - E(target)
    jr   z, .rc_not_this_row           ; bound == target: not this row
    jr   c, .rc_not_this_row           ; bound < target: not this row
    jr   .rc_found                     ; bound > target: this row

.rc_not_this_row:
    inc  d
    jr   .rc_loop

.rc_found:
    ; col = target - row_start, clamped to row_len
    ld   a, e
    sub  c
    cp   b
    jr   c, .rc_col_ok
    ld   a, b
.rc_col_ok:
    ld   c, a
    ld   b, d
    ret

; ============================================================================
; EDITOR_WRAP_ROWCOL_TO_OFFSET
; The reverse of EDITOR_WRAP_OFFSET_TO_ROWCOL — maps a wrapped (row,
; column) back to a buffer offset, using whatever EDITOR_WRAP_CALC last
; computed (caller must call that first, on the matching buffer). Built
; for cursor Up/Down within a wrapped line's own rows (see BASIC_
; HANDLE_NAV): moving to row-1 or row+1 wants to land at "the same
; visual column, or as close as this row's own length allows" — column
; is clamped to the target row's own content length here, rather than
; requiring the caller to check first.
;
; In:  B = target row index (0-based; caller's responsibility to keep
;      it within 0..EDIT_WRAP_COUNT-1, same as EDITOR_WRAP_OFFSET_TO_
;      ROWCOL's own contract), C = desired column (clamped internally)
; Out: A = buffer offset
; Destroys: AF, HL
; ============================================================================
EDITOR_WRAP_ROWCOL_TO_OFFSET:
    ld   hl, EDIT_WRAP_START
    ld   a, b
    call EDITOR_WRAP_TABLE_ADDR
    ld   a, (hl)
    ld   d, a                          ; D = this row's start offset

    ld   hl, EDIT_WRAP_LEN
    ld   a, b
    call EDITOR_WRAP_TABLE_ADDR
    ld   a, (hl)                       ; A = this row's content length
    cp   c
    jr   nc, .rto_col_ok               ; row_len >= desired col: use it
                                       ; as-is
    ld   c, a                          ; clamp col to row_len
.rto_col_ok:
    ld   a, d
    add  a, c
    ret
