; ============================================================================
; BASIC-owned full-screen editor integration.
;
; These macros are expanded at their historical positions in basic.asm so
; this source-ownership cleanup does not change ROM layout or behavior. The
; generic line-buffer engine remains canonical in rom/exrom_editor.asm.
; ============================================================================

    IFDEF EMIT_BASIC_EDITOR_RESET_STATE
BASIC_RESET_EDIT_STATE:
    ld   hl, $FFFF
    ld   (CUR_EDIT_POS), hl
    ld   hl, 0
    ld   (CUR_EDIT_INDEX), hl
    ld   (VIEW_TOP_INDEX), hl
    ld   (CHECK_ERROR_COUNT), hl
    ret
    ENDIF

    IFDEF EMIT_BASIC_EDITOR_LOAD_LINE
BASIC_LOAD_EDIT_LINE:
    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    jr   nz, .load_existing

    ld   hl, EDIT_LINE_BUF
    ld   (hl), 0
    jr   .reset_offset

.load_existing:
    ld   hl, (CUR_EDIT_POS)
    inc  hl
    inc  hl                          ; skip the 2-byte length prefix
    ld   de, EDIT_LINE_BUF
    call BASIC_DETOKENIZE_TO_BUF

.reset_offset:
    ld   hl, 0
    ld   (EDIT_BUF_OFFSET), hl
    ret

; ============================================================================
; BASIC_FIND_INDEX_OF_POSITION
; Converts a statement's position back into its 0-based index — the
; reverse of BASIC_FIND_STATEMENT_AT_INDEX. Needed because
; BASIC_FIND_NEXT_ERROR/PREV_ERROR find a POSITION, but CUR_EDIT_INDEX
; (used for the status bar's "LINE n/m" and the scroll-adjustment
; logic below) needs the corresponding INDEX — walks the program from
; the start, counting, until the target position matches.
;
; Defensively checks for end-of-program (HL=0) before ever calling
; MEM_LINE_NEXT on it — if the target genuinely isn't found (e.g. a
; stale position from a list that's out of sync with the current
; program), looping forever on invalid data would be far worse than
; returning a clear failure.
;
; A real, confirmed bug lived here: MEM_LINE_NEXT destroys DE per its
; own documented contract (this project's own recurring register-
; survival lesson — see "Recurring bug patterns" in this project's own
; working memory), but the loop used to restore DE (the index counter)
; from the stack BEFORE calling MEM_LINE_NEXT, not after — so
; MEM_LINE_NEXT clobbered the counter, and the following "inc de"
; incremented garbage instead of the real count. Found from an actual
; diagnostic build printing the returned value on screen (24646/$6046
; instead of the expected 1) after an earlier hand-trace had
; incorrectly assumed DE survived the call without checking
; MEM_LINE_NEXT's own destroys-list. Fixed by pushing DE again
; immediately before the call and popping it back immediately after,
; the same protection HL already had.
;
; Hand-traced against a 2-statement program, searching for the second
; one's position: first iteration doesn't match (index 0, position
; differs), advances via MEM_LINE_NEXT with the index counter now
; correctly protected across that call, increments to 1; second
; iteration matches, returning DE=1.
; In:  HL = the statement position to find the index of
; Out: carry clear + DE = its 0-based index; carry set if the target
;      was never found (defensive — shouldn't normally happen)
; Destroys: AF, BC, HL
; ============================================================================
BASIC_FIND_INDEX_OF_POSITION:
    ld   (SEARCH_TARGET), hl
    call MEM_LINE_FIRST
    ld   de, 0
.loop:
    ld   a, h
    or   l
    jr   z, .not_found                   ; end of program, target
                                        ; never matched — defensive,
                                        ; shouldn't normally happen

    push de                            ; save index counter
    push hl                              ; save current statement
                                        ; pointer
    ld   de, (SEARCH_TARGET)
    or   a
    sbc  hl, de
    jr   z, .found

    pop  hl                                ; restore statement pointer
    pop  de                                  ; restore index counter

    push de                                    ; protect the index
                                              ; counter across
                                              ; MEM_LINE_NEXT, which
                                              ; destroys DE — see this
                                              ; routine's own header
    call MEM_LINE_NEXT
    pop  de                                      ; restore it
    inc  de
    jr   .loop

.found:
    pop  hl                                    ; discard — was the
                                              ; statement pointer,
                                              ; don't need it anymore
    pop  de                                      ; restore index
                                                ; counter — this is
                                                ; the answer
    or   a
    ret

.not_found:
    scf
    ret

; ============================================================================
; BASIC_HANDLE_NAV
; kernel/editor's EDITOR_NAV_HOOK target. Moves which statement is
; being edited up or down by one. Any uncommitted changes to whatever
; was being edited before are discarded — there's no undo/redo in this
; project, so silently discarding on navigation (rather than trying to
; auto-save) is the simplest honest behavior, matching how most line
; editors treat unsaved edits when you move away without committing.
; Also adjusts VIEW_TOP_INDEX so the target stays within the visible
; 24-row window — "scrolling" is just changing this and letting the
; existing full-redraw-every-keypress approach (BASIC_REDRAW_PROGRAM)
; handle the rest; no separate hardware-scroll primitive is needed.
;
; Hand-traced: at index 0 (the very first statement), UP is a no-op
; (checked before decrementing). From the sentinel (index == total),
; DOWN is a no-op (checked via the same sbc-based comparison DOWN
; already needs). Moving DOWN from index (total-1) — the last existing
; statement — correctly lands exactly on the sentinel (target==total).
;
; Also handles EDIR_DELETE_LINE and EDIR_INSERT_LINE (kernel/editor's
; EDITOR_LOOP routes an empty-buffer DELETE, CAPS SHIFT+1
; (KEY_DELETE_LINE — a direct one-keystroke route to the same
; EDIR_DELETE_LINE, no empty-buffer requirement), and KEY_INSERT_LINE
; here via the same hook — see that file's own comments). Both reuse
; .existing_line/.loaded below for finding/loading the resulting
; target and adjusting scroll, rather than duplicating that logic —
; delete just needs CUR_EDIT_INDEX to end up pointing at whatever now
; occupies that index (or the sentinel, if the last statement was
; deleted); insert needs CUR_EDIT_POS/INDEX to end up pointing at the
; new blank line, which are BOTH already correct without any
; recomputation, since that's exactly where the insert happened.
;
; Also handles EDIR_NEXT_ERROR and EDIR_PREV_ERROR (SYMBOL SHIFT+A/S —
; kernel/editor's EDITOR_LOOP routes these here via the same hook too).
; BASIC_FIND_NEXT_ERROR/PREV_ERROR find the target POSITION;
; BASIC_FIND_INDEX_OF_POSITION converts that back into the INDEX
; .loaded needs — then the exact same reused tail as everything else
; here handles loading the target and adjusting scroll. A no-op if
; CHECK_ERROR_LIST is empty (nothing flagged, or nothing pending — see
; those routines' own carry-set contract for "nothing to find").
; In:  A = EDIR_UP, EDIR_DOWN, EDIR_DELETE_LINE, EDIR_INSERT_LINE,
;      EDIR_NEXT_ERROR, or EDIR_PREV_ERROR
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
    ENDIF

    IFDEF EMIT_BASIC_EDITOR_NAVIGATION
BASIC_HANDLE_NAV:
    push af                              ; protect the requested nav
                                        ; action across the pending-
                                        ; delete cleanup below —
                                        ; nothing past this point knows
                                        ; about it otherwise
    ld   hl, (PENDING_DELETE_POS)
    ld   a, h
    cp   $FF
    jr   nz, .have_pending_delete
    ld   a, l
    cp   $FF
    jr   z, .no_pending_delete

.have_pending_delete:
    ; a rejected immediate command's text is still sitting in the
    ; program, kept only so the user could see it alongside the
    ; "INVALID RANGE" message — the cursor is about to move away from
    ; it now (this routine only runs on an actual navigation request),
    ; so remove it before processing whatever navigation was actually
    ; asked for. See PENDING_DELETE_POS's own sysvars.inc comment for
    ; the full reasoning; user-requested.
    push hl
    pop  de                              ; DE = same position — a
                                        ; single-statement range,
                                        ; matching EDITOR_BLOCK_
                                        ; DELETE's/.do_delete_line's
                                        ; own HL=DE precedent for
                                        ; deleting exactly one
                                        ; statement
    call MEM_LINE_DELETE_RANGE

    ld   hl, $FFFF
    ld   (PENDING_DELETE_POS), hl          ; consumed

    ld   hl, (CUR_EDIT_INDEX)
    dec  hl                              ; one fewer statement now
                                        ; exists — the removed line was
                                        ; always the last one (only
                                        ; ever appended right at
                                        ; PROG_END), so CUR_EDIT_INDEX
                                        ; (== the old total, since
                                        ; CUR_EDIT_POS is still the
                                        ; sentinel at this point) simply
                                        ; drops by one to match
    ld   (CUR_EDIT_INDEX), hl

    call BASIC_RESET_ROW_SHADOW            ; structural change to the
                                          ; program — same "force a
                                          ; fresh redraw" reasoning as
                                          ; DELETE's own earlier fix
                                          ; (see that routine's header)

.no_pending_delete:
    pop  af                              ; restore the originally-
                                        ; requested nav action —
                                        ; everything below is entirely
                                        ; unmodified from before this
                                        ; guard was added

    cp   EDIR_DELETE_LINE
    jp   z, .do_delete_line
    cp   EDIR_INSERT_LINE
    jp   z, .do_insert_line
    cp   EDIR_NEXT_ERROR
    jp   z, .do_next_error
    cp   EDIR_PREV_ERROR
    jp   z, .do_prev_error

    ; word-wrap: before treating Up/Down as a jump to the adjacent
    ; statement, check whether the CURRENTLY-EDITED line (whatever it
    ; is — an existing statement or the new-line sentinel, same
    ; EDIT_LINE_BUF/EDIT_BUF_OFFSET either way) has more wrapped rows
    ; of its own in that direction. Only once the cursor is already at
    ; the line's own top (Up) or bottom (Down) wrapped row does this
    ; fall through to the statement-to-statement jump below — same
    ; "stay local first" behavior as a real multi-line editor, rather
    ; than always treating Up/Down as one-statement-at-a-time.
    cp   EDIR_UP
    jr   z, .try_wrap_up
    jr   .try_wrap_down

.try_wrap_up:
    ld   hl, EDIT_LINE_BUF
    call BASIC_EDITOR_WRAP_CALC_EXROM
    ld   a, (EDIT_BUF_OFFSET)
    call BASIC_EDITOR_WRAP_OFFSET_TO_ROWCOL_EXROM      ; B = current sub-row, C =
                                          ; current column
    ld   a, b
    or   a
    jr   z, .wrap_up_fallthrough            ; already at the top wrapped
                                           ; row — nowhere local left to
                                           ; go
    dec  b                                   ; target = previous
                                             ; wrapped row, same column
                                             ; (clamped inside)
    call BASIC_EDITOR_WRAP_ROWCOL_TO_OFFSET_EXROM
    ld   (EDIT_BUF_OFFSET), a
    xor  a
    ld   (EDIT_BUF_OFFSET+1), a              ; high byte — offset never
                                            ; exceeds 127, but this is a
                                            ; real 2-byte sysvar other
                                            ; code reads as a full word;
                                            ; leaving it stale would be
                                            ; a real bug
    ret
.wrap_up_fallthrough:
    ld   a, EDIR_UP
    jr   .stmt_nav

.try_wrap_down:
    ld   hl, EDIT_LINE_BUF
    call BASIC_EDITOR_WRAP_CALC_EXROM
    ld   a, (EDIT_BUF_OFFSET)
    call BASIC_EDITOR_WRAP_OFFSET_TO_ROWCOL_EXROM      ; B = current sub-row, C =
                                          ; current column
    ld   a, (EDIT_WRAP_COUNT)
    dec  a
    cp   b
    jr   z, .wrap_down_fallthrough          ; already at the bottom
                                           ; wrapped row
    inc  b                                   ; target = next wrapped
                                             ; row, same column
                                             ; (clamped inside)
    call BASIC_EDITOR_WRAP_ROWCOL_TO_OFFSET_EXROM
    ld   (EDIT_BUF_OFFSET), a
    xor  a
    ld   (EDIT_BUF_OFFSET+1), a
    ret
.wrap_down_fallthrough:
    ld   a, EDIR_DOWN

.stmt_nav:
    push af
    call BASIC_COUNT_STATEMENTS
    ld   (NAV_TOTAL), de
    pop  af

    ld   hl, (CUR_EDIT_INDEX)
    cp   EDIR_UP
    jr   z, .go_up

    ; DOWN: target = current + 1; no-op if that would exceed total
    ; (i.e. we're already at the sentinel, nothing further down exists)
    inc  hl
    ld   de, (NAV_TOTAL)
    or   a
    sbc  hl, de
    jr   z, .set_target                ; target == total: lands exactly
                                       ; on the sentinel, valid
    jr   c, .set_target                  ; target < total: a real
                                         ; existing statement, valid
    ret                                    ; target > total: already
                                          ; past the sentinel, no-op

.go_up:
    ld   a, h
    or   l
    ret  z                              ; already at index 0 — no
                                        ; further up to go
    dec  hl
    jr   .have_target

.set_target:
    ld   hl, (CUR_EDIT_INDEX)             ; recompute cleanly rather
    inc  hl                                ; than trying to reverse the
                                          ; DOWN path's sbc above
.have_target:
    ld   (CUR_EDIT_INDEX), hl

    ld   de, (NAV_TOTAL)
    or   a
    sbc  hl, de
    jr   nz, .existing_line

    ; target == total: the sentinel
    ld   hl, $FFFF
    ld   (CUR_EDIT_POS), hl
    jr   .loaded

.existing_line:
    ld   hl, (CUR_EDIT_INDEX)
    ex   de, hl                          ; DE = target index
    call BASIC_FIND_STATEMENT_AT_INDEX     ; HL = that statement's position
    ld   (CUR_EDIT_POS), hl

.loaded:
    call BASIC_LOAD_EDIT_LINE

    ; word-wrap-aware minimal-scroll — centralized in BASIC_SCROLL_TO_
    ; FIT now (see its own header); this used to be the original copy
    ; the other two call sites duplicated from
    jp   BASIC_SCROLL_TO_FIT               ; tail call — BASIC_SCROLL_
                                          ; TO_FIT's own ret satisfies
                                          ; EDITOR_NAV_HOOK's "must end
                                          ; in a normal RET" contract
                                          ; just as well as one here
                                          ; would

; ---- EDIR_DELETE_LINE / EDIR_INSERT_LINE handlers ----
;
; .do_delete_line: hand-traced deleting the middle of 3 statements
; (A, B, C — deleting B) lands correctly on C, which slides into B's
; old index; deleting the LAST statement (index == new total after
; removal) correctly falls through to the sentinel; deleting the ONLY
; remaining statement correctly lands on the sentinel at index 0.
;
; .do_insert_line: hand-traced inserting before B in a 2-statement
; program (A, B) — CUR_EDIT_POS/INDEX are BOTH already correct
; afterward without recomputation, since the blank statement is
; inserted exactly at B's old position/index, which is exactly where
; the cursor should land to start typing it.
.do_delete_line:
    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    ret  z                                 ; on the sentinel — nothing
                                          ; to delete, no-op

    ld   hl, (CUR_EDIT_POS)
    ld   de, (CUR_EDIT_POS)                  ; first=last=this one
                                            ; statement — delete just it
    call MEM_LINE_DELETE_RANGE

    ; REAL BUG FOUND AND FIXED ([stated]-reported via screenshot,
    ; 2026-08-19): this routine never called BASIC_RESET_ROW_SHADOW —
    ; the EXACT same historical bug already found and fixed for the
    ; range DELETE command (BASIC_DO_DELETE, see that routine's own
    ; comment: "DELETE never called BASIC_RESET_ROW_SHADOW after its
    ; structural change... FOURTH bug, a stale redraw"), just never
    ; applied to THIS sibling delete mechanism (CAPS SHIFT+1/empty-
    ; line delete). Confirmed via screenshot: deleting a line left a
    ; ghost duplicate of the FOLLOWING line on screen until the next
    ; navigation forced a real redraw — the row-shadow diff comparing
    ; only (flags, address) never noticed the structural shift, same
    ; "shallow identity" class this project has hit before (see
    ; working memory's lesson 15).
    ; ALSO never re-ran the whole-program checker at all — unlike
    ; .commit_existing (the edit-a-line path), which explicitly does
    ; this after every commit specifically so CHECK_ERROR_COUNT and
    ; the STATUS_CHECK_VALID cache never go stale (see that routine's
    ; own "REAL BUG FOUND AND FIXED" comment — the ORIGINAL error-
    ; highlighting staleness bug this exact reasoning already fixed
    ; once). DELETE was missed entirely when that fix landed. This
    ; left CHECK_ERROR_COUNT frozen at whatever it was before the
    ; delete, AND — worse — meant STATUS_CHECK_VALID's cache (keyed on
    ; CUR_EDIT_POS, an address) could go stale in the SAME shallow-
    ; identity way as the row-shadow bug just above: if the freed
    ; address gets reoccupied by a shifted statement and CUR_EDIT_POS
    ; ends up pointing at that same address again, the cache would
    ; serve a leftover message for a DIFFERENT statement that used to
    ; live there. Both fixed together with the same two calls
    ; .commit_existing already uses.
    call BASIC_RESET_ROW_SHADOW
    call BASIC_FULL_CHECK_EXROM

    call BASIC_COUNT_STATEMENTS                ; DE = new total (one fewer)
    ld   (NAV_TOTAL), de

    ld   hl, (CUR_EDIT_INDEX)                    ; unchanged — whatever
    ld   de, (NAV_TOTAL)                           ; now occupies this
    or   a                                           ; same index number
    sbc  hl, de                                        ; becomes the target
    jr   nz, .existing_line

    ; index == new total: we just deleted the last statement — land on
    ; the sentinel
    ld   hl, $FFFF
    ld   (CUR_EDIT_POS), hl
    jr   .loaded

.do_insert_line:
    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    ret  z                                 ; no-op on the sentinel —
                                          ; "insert before the new
                                          ; line" isn't a meaningful
                                          ; operation

    ld   hl, (CUR_EDIT_POS)
    ld   de, .blank_statement
    call MEM_LINE_INSERT

    ; Forces a full redraw — same "structural change to the program"
    ; reasoning already established for the multi-statement DELETE
    ; range and the pending-delete cleanup above, extended here to
    ; single-statement insert too. Traced a real bug via static
    ; analysis (not yet hardware-reproduced, but the address math is
    ; deterministic): the row-shadow diff compares only (flags,
    ; address), never content. Two shift-enters in a row can move a
    ; DIFFERENT statement into the exact address the row below the
    ; cursor's shadow entry still holds from the previous redraw —
    ; e.g. insert #1 puts a blank statement at address P (shifting the
    ; old target to P+3); insert #2 puts ANOTHER blank statement at P
    ; (shifting the first blank line from P to P+3) — the exact
    ; address the row below the cursor was just recorded as showing.
    ; Single-statement DELETE never needed this because the cursor
    ; always lands exactly on the row that inherits the freed address
    ; (the "actively edited" row, which bypasses the shadow diff
    ; entirely) — insert has no equivalent protection, since the
    ; affected row is always the one below the cursor, which DOES go
    ; through the shadow diff.
    call BASIC_RESET_ROW_SHADOW

    ; CUR_EDIT_POS is unchanged — it now correctly points at the new
    ; blank statement, since that's exactly where it was inserted.
    ; CUR_EDIT_INDEX is unchanged too (the blank line takes that
    ; index, pushing what was there and everything after it later)
    ;
    ; A structural-insert redraw has a real two-pass dependency: the first
    ; pass establishes the empty active row's wrap/row-cache state after the
    ; following records have shifted; without a second pass, the statement
    ; immediately below the new blank row can remain physically undrawn even
    ; though program storage and the row shadow are already correct. The next
    ; typed character used to supply that missing pass, producing the visible
    ; "PRINT disappears until I type" bug. Perform the settling pass here;
    ; EDITOR_LOOP's normal hook-return redraw immediately follows and paints
    ; from the now-consistent state. Kept specific to structural insertion —
    ; ordinary navigation and character editing have no shifted successor.
    call BASIC_LOAD_EDIT_LINE
    call BASIC_SCROLL_TO_FIT
    call BASIC_REDRAW_PROGRAM
    ret

.blank_statement: DB $01, $00, $0D          ; length=1 (just the
                                           ; terminator), no content —
                                           ; the tokenized form of an
                                           ; empty line. A REAL BUG
                                           ; lived here for a long
                                           ; time: this used to be a
                                           ; GLOBAL label
                                           ; (BLANK_STATEMENT, no
                                           ; leading dot) sitting in
                                           ; the middle of what was
                                           ; meant to be one continuous
                                           ; local scope for
                                           ; BASIC_HANDLE_NAV — every
                                           ; local label defined AFTER
                                           ; it (.do_next_error,
                                           ; .do_prev_error,
                                           ; .goto_error_position, and
                                           ; more) silently got
                                           ; re-scoped to belong to
                                           ; THIS label instead of
                                           ; BASIC_HANDLE_NAV, without
                                           ; any warning until
                                           ; something tried to
                                           ; reference them from
                                           ; BASIC_HANDLE_NAV's own
                                           ; scope and the assembler
                                           ; genuinely couldn't find
                                           ; them. This meant every
                                           ; single test of the
                                           ; error-navigation feature
                                           ; ran against a stale binary
                                           ; that never actually
                                           ; contained this code at
                                           ; all — the extended
                                           ; debugging session
                                           ; chasing a runtime bug
                                           ; was chasing something
                                           ; that was never running

.do_next_error:
    call BASIC_FIND_NEXT_ERROR
    jr   c, .nav_error_noop                 ; empty list — nothing to
                                           ; navigate to
    jr   .goto_error_position

.do_prev_error:
    call BASIC_FIND_PREV_ERROR
    jr   c, .nav_error_noop
    ; fall through to .goto_error_position

.goto_error_position:
    ld   (CUR_EDIT_POS), hl

    call BASIC_FIND_INDEX_OF_POSITION
    jr   c, .index_lookup_failed             ; shouldn't normally
                                            ; happen — defensive
                                            ; fallback below
    ld   (CUR_EDIT_INDEX), de

    jr   .loaded                              ; reuse the exact same
                                             ; load+scroll tail every
                                             ; other nav path here uses

.index_lookup_failed:
    ld   hl, $FFFF
    ld   (CUR_EDIT_POS), hl                    ; revert to a safe,
                                              ; well-defined state
                                              ; rather than leave
                                              ; CUR_EDIT_POS/INDEX
                                              ; inconsistent with
                                              ; each other
    ret

.nav_error_noop:
    ret

; ============================================================================
; BASIC_TO_UPPER
; In:  A = a character
; Out: A = uppercased, if it was 'a'-'z'; unchanged otherwise
; Destroys: AF
; ============================================================================
    ENDIF

    IFDEF EMIT_BASIC_EDITOR_EXROM_WRAPPERS
BASIC_EDITOR_INIT_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C060

BASIC_EDITOR_ENTER_EXROM:
    push hl
    call GFX_SPRITE_INVALIDATE
    pop  hl
    call BASIC_CALL_EXROM_INLINE
    DW   $C066

BASIC_EDITOR_WRAP_CALC_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C06C

; BASIC_EDITOR_WRAP_TABLE_ADDR_EXROM removed (2026-08-23) — its one
; caller (BASIC_PRINT_LINE_WRAPPED_COMMON) now inlines the same
; HL+=A computation directly instead of routing through this
; trampoline, which was structurally broken for this specific routine
; (see that call site's own comment for the full bug writeup: every
; EXROM entry stub's magic-check preamble clobbers A before the real
; routine runs, silently breaking any routine that needs A as a real
; argument, not just HL). The $C072 entry stub (rom/exrom_checker.asm)
; is left in place unused rather than removed, to avoid renumbering
; every fixed entry address after it for a 6-byte EXROM saving.

BASIC_EDITOR_WRAP_OFFSET_TO_ROWCOL_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C078

BASIC_EDITOR_WRAP_ROWCOL_TO_OFFSET_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C07E

BASIC_EDITOR_BLOCK_DELETE_EXROM:
    call BASIC_CALL_EXROM_INLINE
    DW   $C084

; ============================================================================
; BASIC_SHOW_HELP_EXROM
; Thin Home-side wrapper: BASIC_SHOW_HELP and its topic tables/text now
; live in EXROM (rom/exrom_help.asm) — HELP's own migration, picked as
; the lowest-risk move available: pure text data behind a display
; routine, only ever called interactively, never from a running
; program or any hot path. Same "page in / call the fixed entry / page
; out" shape as every wrapper above, at EXROM_ENTRY_HELP's own $C01E
; (rom/exrom_checker.asm's entry-stub block — see that file's own doc
; block for why every stub lives together there regardless of which
; file supplies the real body).
;
; Unlike BASIC_CHECK_STATEMENT_EXROM/BASIC_SAVE_EXROM/BASIC_LOAD_EXROM,
; this one does NOT need BASIC_EXROM_EXIT_PROTECTED: BASIC_SHOW_HELP's
; own original contract was already "Destroys: AF, BC, DE, HL" with no
; meaningful output — same unprotected shape as BASIC_SCAN_LABELS_
; EXROM/BASIC_FULL_CHECK_EXROM above, for the same reason (nothing a
; caller relies on survives the original routine either, so there's
; nothing to protect across the page-out step).
;
; In:  HL = pointer to topic-name text (BASIC_SHOW_HELP's own contract,
;      unchanged) — BANK_PAGE_EXROM_IN only ever destroys AF (see its
;      own header), so HL passes through into the EXROM call untouched.
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
    ENDIF

    IFDEF EMIT_BASIC_EDITOR_DISPLAY
BASIC_PRINT_LINE_HIGHLIGHTED:
    xor  a
    jr   BASIC_PRINT_LINE_WRAPPED_COMMON

BASIC_PRINT_LINE_PLAIN_WRAPPED:
    ld   a, 1

; Real global label, not a local .start — a bare global label sitting
; between a jump and its target resets local-label scoping for
; everything after it (this project's own lesson 4, check_asm.py's
; scope-checker caught exactly this the first time this was written
; with BASIC_PRINT_LINE_PLAIN_WRAPPED's own declaration sitting between
; BASIC_PRINT_LINE_HIGHLIGHTED's jump and a shared dotted .start
; label). Reached either by JP from BASIC_PRINT_LINE_HIGHLIGHTED above
; or by plain fallthrough from BASIC_PRINT_LINE_PLAIN_WRAPPED just
; above it.
BASIC_PRINT_LINE_WRAPPED_COMMON:
    ld   (HILITE_PLAIN_MODE), a

    ld   (HILITE_LINE_BASE), hl
    ld   a, b
    ld   (HILITE_LINE_START_ROW), a

    ld   a, (HILITE_PLAIN_MODE)
    or   a
    jr   nz, .force_no_bold

    push hl
    call BASIC_DETECT_KEYWORD_PREFIX     ; sets HILITE_KW_COUNT/START/
                                        ; SPANLEN — HL pushed/popped
                                        ; since this routine is now
                                        ; free to destroy it internally
    pop  hl
    jr   .keyword_done
.force_no_bold:
    xor  a
    ld   (HILITE_KW_COUNT), a            ; 0 spans: the print loop's
                                        ; own bold check (BASIC_KW_
                                        ; OFFSET_BOLD) never finds a
                                        ; match — the plain entry point
                                        ; needs no separate branch
                                        ; there at all
.keyword_done:

    call BASIC_EDITOR_WRAP_CALC_EXROM                ; populates EDIT_WRAP_COUNT/
                                        ; START/LEN from this same HL

    xor  a
    ld   (HILITE_WRAP_ROW), a

.wrap_row_loop:
    ld   hl, EDIT_WRAP_COUNT
    ld   a, (HILITE_WRAP_ROW)
    cp   (hl)
    ret  nc                              ; wrap row >= count: done, all
                                        ; rows drawn

    ; this wrapped row's own screen row, start offset, and length
    ld   a, (HILITE_LINE_START_ROW)
    ld   b, a
    ld   a, (HILITE_WRAP_ROW)
    add  a, b
    ld   (HILITE_ROW), a

    ; HL = EDIT_WRAP_START/LEN + HILITE_WRAP_ROW, inlined directly
    ; rather than routed through BASIC_EDITOR_WRAP_TABLE_ADDR_EXROM —
    ; a REAL BUG FOUND HERE (2026-08-23, user-reported: only the first
    ; character of anything typed ever appeared on screen, though the
    ; full text was correctly stored — ENTER on "HELP" still dispatched
    ; HELP correctly). Root cause: EVERY EXROM entry stub's own
    ; preamble (EXROM_VERIFY_KTAB_MAGIC, rom/exrom_checker.asm) loads
    ; the magic byte into A before comparing it — unconditionally
    ; clobbering whatever a caller passed in A as a real argument.
    ; EDITOR_WRAP_TABLE_ADDR needs A (the row index) as real input, not
    ; just HL, so going through the standard trampoline (BANK_PAGE_
    ; EXROM_IN, which also uses A internally, then the magic-checked
    ; entry stub) silently replaced the caller's real index with
    ; KTAB_MAGIC's own byte value before the routine ever ran —
    ; consistently reading EDIT_WRAP_LEN[KTAB_MAGIC] instead of
    ; EDIT_WRAP_LEN[0], not the intended row length, which is why only
    ; one row's worth of *something* (not the real content) ever
    ; printed. This trampoline shape works fine for every OTHER EXROM
    ; call in this project because none of the others need a real
    ; argument in A — this was the first one that did. The cursor's
    ; own position (BASIC_EDITOR_WRAP_OFFSET_TO_ROWCOL_EXROM) was
    ; unaffected and always showed the true offset, because that
    ; routine calls EDITOR_WRAP_TABLE_ADDR directly, EXROM-internally,
    ; via a bare `call` — no trampoline, no clobbered A — which is why
    ; the cursor visibly landed in the right place while the glyphs
    ; behind it didn't render. Fixed by inlining this 4-instruction
    ; computation instead of routing it through EXROM at all: it never
    ; needed to leave Home in the first place (EDIT_WRAP_START/LEN are
    ; ordinary Home RAM, readable directly regardless of chunk 6's
    ; paging state), and inlining is both correct and smaller than the
    ; trampoline call it replaces.
    ld   a, (HILITE_WRAP_ROW)
    ld   hl, EDIT_WRAP_START
    add  a, l
    ld   l, a
    jr   nc, .no_carry_start
    inc  h
.no_carry_start:
    ld   a, (hl)
    ld   (HILITE_ROW_START), a

    ld   a, (HILITE_WRAP_ROW)
    ld   hl, EDIT_WRAP_LEN
    add  a, l
    ld   l, a
    jr   nc, .no_carry_len
    inc  h
.no_carry_len:
    ld   a, (hl)
    ld   (HILITE_ROW_LEN), a

    xor  a
    ld   (HILITE_COL), a
.print_loop:
    ld   a, (HILITE_COL)
    ld   b, a
    ld   a, (HILITE_ROW_LEN)
    cp   b
    jr   z, .row_done                    ; drawn every char on this row

    ; absolute offset within the line = ROW_START + COL — also happens
    ; to be exactly the buffer offset from HILITE_LINE_BASE, so it
    ; does double duty as the pointer offset just below
    ld   a, (HILITE_ROW_START)
    add  a, b
    ld   c, a                            ; C = absolute offset

    ld   hl, (HILITE_LINE_BASE)
    ld   e, c
    ld   d, 0
    add  hl, de
    ld   a, (hl)
    ld   e, a                            ; E = character to print, kept
                                        ; safe here — none of the LDs
                                        ; below touch E, and LD never
                                        ; touches flags either, so the
                                        ; CP's carry below survives
                                        ; straight through to the JR C
                                        ; after them

    ld   a, c                            ; A = absolute offset
    call BASIC_KW_OFFSET_BOLD             ; carry set if this offset
                                          ; falls inside a recorded
                                          ; bold span (always clear in
                                          ; plain mode, since
                                          ; HILITE_KW_COUNT is 0 there)
                                          ; — preserves BC/DE/HL, so E
                                          ; (the character) survives

    ld   a, (HILITE_ROW)
    ld   b, a
    ld   a, (HILITE_COL)
    ld   c, a
    ld   a, e                            ; A = character (restored)
    jr   c, .do_bold

    call GFX_PUTCHAR
    jr   .advance
.do_bold:
    call GFX_PUTCHAR_BOLD

.advance:
    ld   a, (HILITE_COL)
    inc  a
    ld   (HILITE_COL), a
    jr   .print_loop

.row_done:
    ld   a, (HILITE_WRAP_ROW)
    inc  a
    ld   (HILITE_WRAP_ROW), a
    jr   .wrap_row_loop

; ============================================================================
; BASIC_RESET_ROW_SHADOW
; Resets the screen-flicker fix's shadow state to "nothing here yet"
; ($FFFF for every row's position, the same sentinel used elsewhere;
; 0 for every row's flags) — the next redraw will then correctly treat
; every row as changed and draw it fresh, rather than risking a stale
; shadow entry claiming a row still shows what it used to before
; something else wiped the actual screen out from under it.
;
; Extracted into its own global routine (rather than staying inline in
; BASIC_COMMAND_LOOP, where it was first written) specifically because
; BASIC_RUN needs it too, and local labels can't be called across
; routines. A real, related bug shipped without this second call site:
; BASIC_RUN calls GFX_CLS unconditionally for its own program output,
; but never told the shadow state that had happened — so returning to
; the editor view afterward, BASIC_REDRAW_PROGRAM would see shadow
; entries that still matched what was previously on screen, and
; incorrectly skip redrawing rows that RUN's own GFX_CLS had actually
; just wiped blank. Found and fixed alongside the cold-boot version of
; the same underlying problem (see BASIC_COMMAND_LOOP's own comment).
; In:  none
; Out: none — ROW_SHADOW_POS, ROW_SHADOW_FLAGS, and LAST_RENDERED_ROWS
;      all reset
; Destroys: AF, BC, HL
; ============================================================================
BASIC_RESET_ROW_SHADOW:
    ld   hl, ROW_SHADOW_POS
    ld   b, 24
.init_shadow_loop:
    ld   (hl), $FF
    inc  hl
    ld   (hl), $FF
    inc  hl
    djnz .init_shadow_loop

    xor  a
    ld   hl, ROW_SHADOW_FLAGS
    ld   b, 24
.init_flags_loop:
    ld   (hl), a
    inc  hl
    djnz .init_flags_loop

    ; LAST_RENDERED_ROWS is set to 23 (the full program-display area —
    ; row 23 is always the separately-handled status line), NOT 0.
    ; A real bug shipped with 0 here: BASIC_REDRAW_PROGRAM's own
    ; leftover-rows cleanup (.clear_leftover_rows) only clears rows
    ; from the CURRENT row count up through LAST_RENDERED_ROWS-1 — it
    ; does nothing at all when LAST_RENDERED_ROWS is 0, since no count
    ; is ever less than 0. That's fine exactly when whatever called
    ; this reset also cleared the ENTIRE physical screen and drew
    ; NOTHING else on top of it — true for BASIC_RUN's GFX_CLS only by
    ; coincidence, in the cases tested so far, but false in general:
    ; BASIC_RUN prints its own program output after that GFX_CLS, and
    ; BASIC_SHOW_HELP prints a full topic screen after its own GFX_CLS
    ; — in both cases the physical screen has real content on however
    ; many rows that output used, not 0. Confirmed from a screenshot:
    ; returning from a 14-line HELP screen to a 3-row program listing
    ; left rows 3-13 showing the tail of the old HELP text untouched,
    ; because LAST_RENDERED_ROWS=0 meant the cleanup pass had nothing
    ; to do. Using 23 here instead means the next redraw's cleanup
    ; pass always clears every row from wherever the new content stops
    ; through row 22, regardless of how many rows the prior screen
    ; (RUN's output or a HELP screen) actually used — closing this
    ; same class of bug for RUN's own case too, even though it hadn't
    ; visibly surfaced there yet in testing.
    ld   a, 23
    ld   (LAST_RENDERED_ROWS), a

    ; LAST_STATUS_TEXT (the status bar's own flicker-fix comparison
    ; state) also needs resetting here, for the same reason as
    ; everything above — BASIC_RUN's own GFX_CLS wipes row 23 same as
    ; the rest of the screen, so this needs to stop claiming whatever
    ; text was shown before that happened. $FF as the first byte is
    ; never a valid printable character any real status message would
    ; ever start with, guaranteeing the very next comparison correctly
    ; mismatches and redraws rather than risking an accidental match
    ; against leftover RAM content
    ld   a, $FF
    ld   (LAST_STATUS_TEXT), a

    ; LAST_VIEW_TOP_INDEX (Priority 3's fast-scroll detector — see
    ; BASIC_REDRAW_PROGRAM's own use) also needs resetting here, same
    ; reasoning as LAST_STATUS_TEXT above: $FFFF can never be a real
    ; VIEW_TOP_INDEX (a 0-based statement count), so the next redraw's
    ; "changed by exactly +-1 since last time" check correctly misses
    ; and falls back to a full render instead of risking a false match
    ; against whatever this sysvar happened to hold before the reset.
    ld   hl, $FFFF
    ld   (LAST_VIEW_TOP_INDEX), hl
    ret

; ============================================================================
; BASIC_ROW_SHADOW_MATCHES
; Checks whether a row's current (flags, position) matches what was
; shown there as of the last redraw — part of the screen-flicker fix.
; Checks flags first (a single byte) before position (two bytes),
; since a flags mismatch alone is enough to answer "no" without ever
; needing the position value in flight at the same time — this keeps
; the whole routine to a single register-pair "in flight" at once,
; rather than needing to juggle two values across the address
; computation in between.
;
; Verified via a Python simulation of this exact match/update logic
; (initial-state mismatch, flags-only mismatch, position-only
; mismatch, and the flags-changing-without-position-changing case a
; program going from valid to error-flagged actually produces) before
; being written here.
; In:  B = row (0-23), C = flags to compare (0 or 1), DE = position
;      to compare
; Out: carry clear if it matches (safe to skip redrawing this row);
;      carry set if it differs (must redraw)
; Destroys: AF, HL, DE
; ============================================================================
BASIC_ROW_SHADOW_MATCHES:
    push de                       ; save the position to compare —
                                 ; only needed if flags match first
    ld   h, 0
    ld   l, b
    ld   de, ROW_SHADOW_FLAGS
    add  hl, de                    ; HL = this row's flags entry
    ld   a, (hl)
    cp   c
    jr   nz, .mismatch_flags_only    ; flags differ — position doesn't
                                    ; even need checking

    ld   h, 0
    ld   l, b
    add  hl, hl                        ; row*2
    ld   de, ROW_SHADOW_POS
    add  hl, de                          ; HL = this row's position entry

    pop  de                                 ; restore position to
                                           ; compare
    ld   a, (hl)
    cp   e
    jr   nz, .mismatch
    inc  hl
    ld   a, (hl)
    cp   d
    jr   nz, .mismatch

    or   a
    ret

.mismatch:
    scf
    ret

.mismatch_flags_only:
    pop  de                                    ; balance the stack —
                                              ; discard, not needed
    scf
    ret

; ============================================================================
; BASIC_UPDATE_ROW_SHADOW
; Records a row's current (flags, position) as what's now shown there
; — called after a row is actually redrawn, so the next redraw can
; correctly detect whether it's changed. Same address computation as
; BASIC_ROW_SHADOW_MATCHES, just writing instead of reading/comparing.
; In:  B = row (0-23), C = flags (0 or 1), DE = position
; Out: none
; Destroys: AF, HL
; ============================================================================
BASIC_UPDATE_ROW_SHADOW:
    push de
    ld   h, 0
    ld   l, b
    ld   de, ROW_SHADOW_FLAGS
    add  hl, de
    ld   a, c
    ld   (hl), a

    ld   h, 0
    ld   l, b
    add  hl, hl
    ld   de, ROW_SHADOW_POS
    add  hl, de

    pop  de
    ld   (hl), e
    inc  hl
    ld   (hl), d
    ret

; ============================================================================
; BASIC_ROW_SUM
; Shared "PROGRAM_ROW + STMT_ROW_COUNT" computation — appeared 6 times
; identically across BASIC_REDRAW_PROGRAM (both the "does this fit
; above the status bar" checks and the "advance PROGRAM_ROW past this
; statement" updates) before this.
; In:  none (reads PROGRAM_ROW, STMT_ROW_COUNT)
; Out: A = PROGRAM_ROW + STMT_ROW_COUNT
; Destroys: AF, B
; ============================================================================
BASIC_ROW_SUM:
    ld   a, (PROGRAM_ROW)
    ld   b, a
    ld   a, (STMT_ROW_COUNT)
    add  a, b
    ret

; ============================================================================
; BASIC_CLEAR_STMT_ROWS
; Clears every physical screen row the statement/line currently being
; rendered occupies — PROGRAM_ROW+0 through PROGRAM_ROW+STMT_ROW_COUNT-1
; (both sysvars, read directly, matching this file's other STMT_ROW_*
; helpers' style). Consolidates what used to be three near-identical
; ~14-line loops duplicated across BASIC_REDRAW_PROGRAM's active-line,
; settled-statement, and new-line branches — [stated] asked for exactly
; this kind of pass after the scroll-math consolidation earlier this
; session found the first instance of it.
; In:  none (reads PROGRAM_ROW, STMT_ROW_COUNT)
; Out: none
; Destroys: AF, BC (HL preserved — some callers need their own HL
;      intact across this, so it's saved/restored here rather than
;      leaving that up to each call site individually)
; ============================================================================
BASIC_CLEAR_STMT_ROWS:
    push hl
    xor  a
    ld   (STMT_ROW_IDX), a
.loop:
    ld   a, (STMT_ROW_IDX)
    ld   b, a
    ld   a, (STMT_ROW_COUNT)
    cp   b
    jr   z, .done
    ld   a, (PROGRAM_ROW)
    add  a, b
    ld   b, a
    push bc
    call GFX_CLEAR_ROW
    pop  bc
    ld   a, (STMT_ROW_IDX)
    inc  a
    ld   (STMT_ROW_IDX), a
    jr   .loop
.done:
    pop  hl
    ret

; ============================================================================
; BASIC_UPDATE_STMT_ROWS_SHADOW
; Records the given (flags, position) shadow entry for every physical
; row the statement/line currently being rendered occupies — same
; PROGRAM_ROW/STMT_ROW_COUNT range BASIC_CLEAR_STMT_ROWS uses.
; Consolidates two near-identical loops (the active line's own
; sentinel-flags/$FFFF-position convention, and a settled statement's
; real LINE_IS_ERROR flag/position) that used to be duplicated in
; BASIC_REDRAW_PROGRAM — same consolidation pass as BASIC_CLEAR_
; STMT_ROWS above. C and DE survive a real BASIC_UPDATE_ROW_SHADOW
; call by that routine's own contract, so they don't need re-loading
; each iteration — only the row number (B) varies per row.
; In:  C = flags, DE = position — same pair applied to every row
; Out: none
; Destroys: AF, B (C, DE, HL all preserved)
; ============================================================================
BASIC_UPDATE_STMT_ROWS_SHADOW:
    push hl
    xor  a
    ld   (STMT_ROW_IDX), a
.loop:
    ld   a, (STMT_ROW_IDX)
    ld   b, a
    ld   a, (STMT_ROW_COUNT)
    cp   b
    jr   z, .done
    ld   a, (PROGRAM_ROW)
    add  a, b
    ld   b, a
    call BASIC_UPDATE_ROW_SHADOW
    ld   a, (STMT_ROW_IDX)
    inc  a
    ld   (STMT_ROW_IDX), a
    jr   .loop
.done:
    pop  hl
    ret

; ============================================================================
; BASIC_DRAW_ACTIVE_ROW_TAIL
; Draws the currently-active line, plain, from EDIT_LINE_BUF, across
; whatever rows PROGRAM_ROW/STMT_ROW_COUNT (already set by the caller —
; same convention BASIC_CLEAR_STMT_ROWS/BASIC_UPDATE_STMT_ROWS_SHADOW
; use) name, then records the usual sentinel-flags/$FFFF-position
; shadow entry so a later redraw always mismatches once this row
; becomes settled. Factored out (2026-08-24, Priority 3's fast-scroll
; pass) — shared by BASIC_REDRAW_PROGRAM's own existing-statement-
; active branch and the fast-scroll path's newly-revealed-active-row
; draw; was duplicated inline in both before this.
; In:  none (PROGRAM_ROW, STMT_ROW_COUNT already set)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_DRAW_ACTIVE_ROW_TAIL:
    call BASIC_CLEAR_STMT_ROWS

    ld   hl, EDIT_LINE_BUF
    ld   a, (PROGRAM_ROW)
    ld   b, a
    call BASIC_PRINT_LINE_PLAIN_WRAPPED

    ld   c, 2
    ld   de, $FFFF
    jr BASIC_UPDATE_STMT_ROWS_SHADOW

; ============================================================================
; BASIC_DRAW_SETTLED_ROW_TAIL
; Renders one already-committed statement as a settled (highlighted,
; possibly error-colored) row: clear, highlighted print, error-flag
; coloring, shadow update. Assumes the caller already detokenized it
; into DETOK_BUF and set LINE_IS_ERROR (both are also needed for the
; shadow-match check that decides whether a redraw is needed at all,
; in BASIC_REDRAW_PROGRAM's own main render loop — redoing them here
; would repeat work already done for that check). Factored out
; (2026-08-24, Priority 3's fast-scroll pass) — shared by the main
; render loop's own needs-redraw branch and the fast-scroll path's
; settled-row redraw; was duplicated inline in both before this.
; In:  HL = statement position (length-prefix included); DETOK_BUF and
;      LINE_IS_ERROR already set; PROGRAM_ROW/STMT_ROW_COUNT already
;      set (same convention as BASIC_CLEAR_STMT_ROWS)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_DRAW_SETTLED_ROW_TAIL:
    call BASIC_CLEAR_STMT_ROWS

    push hl
    ld   hl, DETOK_BUF
    ld   a, (PROGRAM_ROW)
    ld   b, a
    call BASIC_PRINT_LINE_HIGHLIGHTED
    pop  hl

    ld   a, (LINE_IS_ERROR)
    or   a
    jr   z, .no_color

    xor  a
    ld   (STMT_ROW_IDX), a
.color_row_loop:
    ld   a, (STMT_ROW_IDX)
    ld   b, a
    ld   a, (STMT_ROW_COUNT)
    cp   b
    jr   z, .no_color

    ld   a, (PROGRAM_ROW)
    add  a, b
    push hl                              ; HL (statement position) must
                                        ; survive the GFX_SET_ATTR loop
                                        ; below — see BASIC_REDRAW_
                                        ; PROGRAM's own git history for
                                        ; the bug this guards against
    ld   b, a
    ld   c, 0
.color_col_loop:
    push bc
    ld   a, ATTR_ERROR_RED
    call GFX_SET_ATTR
    pop  bc
    inc  c
    ld   a, c
    cp   32
    jr   c, .color_col_loop
    pop  hl
    ld   a, (STMT_ROW_IDX)
    inc  a
    ld   (STMT_ROW_IDX), a
    jr   .color_row_loop

.no_color:
    push hl
    ex   de, hl
    ld   a, (LINE_IS_ERROR)
    ld   c, a
    call BASIC_UPDATE_STMT_ROWS_SHADOW
    pop  hl
    ret

; ============================================================================
; BASIC_REDRAW_PROGRAM
; kernel/editor's EDITOR_REDRAW_HOOK target — replaces
; EDITOR_REDRAW_SCREEN's default rendering while basic/ owns the
; session (see BASIC_COMMAND_LOOP, which sets the hook). Renders
; statements starting from VIEW_TOP_INDEX (scrolling is just changing
; that value — see BASIC_HANDLE_NAV), one per row, detokenized into
; DETOK_BUF (trivial for this project's tokenizer — no keyword
; compression) with keyword highlighting, EXCEPT whichever statement's
; position matches CUR_EDIT_POS: that one renders plain from
; EDIT_LINE_BUF instead, since it's the line actively being edited
; right now, not settled/committed text. If CUR_EDIT_POS is still the
; sentinel after all existing statements are rendered, the
; new/uncommitted line renders plain at the next row.
;
; The row counter (PROGRAM_ROW) is kept in memory, reloaded fresh each
; time it's needed, rather than trusting register B to survive across
; BASIC_PRINT_LINE_HIGHLIGHTED and MEM_LINE_NEXT — both destroy BC
; entirely. This exact mistake shipped once already: B silently held
; garbage by the time the loop's own "inc b" ran, corrupting every
; row's position after the first. Found via a screenshot showing a
; second committed statement overlapping the actively-typed line.
;
; TODO: still no scrolling PAST the 24-row window in a single redraw —
; VIEW_TOP_INDEX changing lets a DIFFERENT 24 statements come into
; view across separate redraws, but any one redraw still only shows 24.
; In:  none (matches EDITOR_REDRAW_SCREEN's own no-argument contract —
;      this is called via JP, not CALL, from there)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_REDRAW_PROGRAM:
    ; no longer starts with an unconditional GFX_CLS — that was the
    ; main source of visible flicker (the whole screen wiped and
    ; redrawn on every keystroke, even when only one row actually
    ; changed). Per-row clearing (GFX_CLEAR_ROW, called only for rows
    ; that genuinely differ from what's already there) replaces it —
    ; see .render_settled and .render_done below.

    ; Auto-scroll: keep VIEW_TOP_INDEX consistent with wherever
    ; CUR_EDIT_INDEX currently is, on EVERY redraw — not just explicit
    ; up/down navigation. Calls the same centralized BASIC_SCROLL_TO_
    ; FIT the other two call sites use (see its own header for why
    ; this one computation is centralized rather than duplicated, now
    ; that it's word-wrap-aware) — used to be its own inline copy of
    ; the old statement-counting formula here, matching this project's
    ; usual small-duplication convention, but that convention was
    ; about a few lines of arithmetic, not a multi-call computation.
    ; Needed because plain character typing never goes through
    ; BASIC_HANDLE_NAV at all — EDITOR_LOOP calls EDITOR_INSERT_CHAR
    ; directly, no nav hook involved — so appending statement after
    ; statement by simply typing and pressing ENTER never scrolled the
    ; view: once enough committed statements already filled every
    ; visible row, the next new line's cursor landed on the reserved
    ; status bar row, which BASIC_DRAW_STATUS_LINE's sentinel-render
    ; path then cleared and overwrote with the user's typed text
    ; (found via [stated] reporting exactly this symptom). Idempotent
    ; and safe to also run after nav (which already performs the same
    ; adjustment itself) — a second identical check against an
    ; already-correct VIEW_TOP_INDEX finds nothing further to do.
    call BASIC_SCROLL_TO_FIT

    ; ---- Priority 3 fast-scroll path (2026-08-24): a plain single
    ; arrow-key step (VIEW_TOP_INDEX moved by exactly one statement)
    ; can move real screen bytes via kernel/graphics's GFX_SCROLL_TEXT_
    ; UP/_DOWN instead of re-rendering all 23 rows. Declines (falls
    ; through to the existing full render at .auto_scroll_done) on ANY
    ; condition outside the narrow proven-safe case — see this block's
    ; own checks below for exactly what "safe" means here. Verified via
    ; kernel-primitive-level testing (rom/test_gfx_scroll.asm, deleted
    ; after use) before this integration; the derivation for why only
    ; checking the active line's own row count plus a whole-window
    ; no-wrap shadow scan is sufficient (not e.g. a per-row wrap check
    ; against every statement in view) is in this session's own working
    ; notes, not reproduced here — short version: a uniform 1-row
    ; hardware shift is correct for every row EXCEPT when a statement
    ; crossing a view boundary occupies more than one row, and the
    ; render loop below never draws a statement partially (a statement
    ; that doesn't fully fit isn't drawn at all — see .render_settled's
    ; own fit check), so "no two adjacent shadow entries share a
    ; position" is sufficient to rule that out everywhere in view.
    ld   hl, (VIEW_TOP_INDEX)
    ld   de, (LAST_VIEW_TOP_INDEX)
    or   a
    sbc  hl, de
    ld   a, h
    or   a
    jr   nz, .fs_check_neg1
    ld   a, l
    cp   1
    jr   z, .fs_direction_up
.fs_check_neg1:
    ld   a, h
    cp   $FF
    jp   nz, .auto_scroll_done
    ld   a, l
    cp   $FF
    jp   nz, .auto_scroll_done
    jr   .fs_direction_down

.fs_direction_up:
.fs_direction_down:
    ; common preconditions, either direction: an existing statement is
    ; active (not the uncommitted new-line placeholder), and it's
    ; exactly one row (no word-wrap) — BASIC_SCROLL_TO_FIT's own
    ; SCROLL_OWN_ROWS can be stale here (its down-navigation branch
    ; returns before ever setting it), so this is computed fresh rather
    ; than trusted
    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    jp   z, .auto_scroll_done

    ld   hl, EDIT_LINE_BUF
    call BASIC_EDITOR_WRAP_CALC_EXROM
    ld   a, (EDIT_WRAP_COUNT)
    cp   1
    jp   nz, .auto_scroll_done

    ; no wrapping anywhere in the OLD (pre-scroll) view: any two
    ; adjacent shadow rows sharing the same real (non-$FFFF) position
    ; mean a multi-row statement is straddling them
    ld   ix, ROW_SHADOW_POS
    ld   b, 22
.fs_wrap_scan:
    ld   e, (ix+0)
    ld   d, (ix+1)
    ld   l, (ix+2)
    ld   h, (ix+3)
    or   a
    sbc  hl, de
    jr   nz, .fs_wrap_scan_next
    ld   a, d
    inc  a
    jp   nz, .auto_scroll_done
    ld   a, e
    inc  a
    jp   nz, .auto_scroll_done
.fs_wrap_scan_next:
    push bc
    ld   bc, 2
    add  ix, bc
    pop  bc
    djnz .fs_wrap_scan

    ld   hl, (VIEW_TOP_INDEX)
    ld   de, (LAST_VIEW_TOP_INDEX)
    or   a
    sbc  hl, de
    ld   a, l
    cp   1
    jr   z, .fs_do_up
    jr   .fs_do_down

.fs_do_up:
    ld   a, (SCROLL_ROWS_BEFORE)          ; low byte — the new active
                                          ; row (window is capped at 23,
                                          ; fits in a byte)
    or   a
    jp   z, .auto_scroll_done             ; defensive: no room above it
                                          ; for a settled predecessor
                                          ; row — shouldn't happen given
                                          ; the checks above
    ld   (FAST_SCROLL_NEW_ROW), a

    ; the settled row now sitting one above it is whatever statement is
    ; (new_row - 1) steps forward from the NEW view's own top
    ; (SCROLL_TOP_PTR, already computed by BASIC_SCROLL_TO_FIT) — this
    ; is always the statement that occupied that same physical row
    ; before the shift, by construction, regardless of navigation
    ; specifics; bounded by the 23-row window, not program size
    ld   hl, (SCROLL_TOP_PTR)
    dec  a
    jr   z, .fs_up_have_old_pos           ; new_row was 1 -- zero steps
    ld   (STMT_ROW_IDX), a                ; walk counter kept in memory,
                                          ; not B -- MEM_LINE_NEXT's own
                                          ; documented contract destroys
                                          ; BC, so B can't survive the
                                          ; call the way a bare djnz
                                          ; would need it to (real bug,
                                          ; found via a genuine editor
                                          ; lockup, not caught by any
                                          ; static check or the earlier
                                          ; kernel-primitive-only test)
.fs_up_walk:
    call MEM_LINE_NEXT
    ld   a, (STMT_ROW_IDX)
    dec  a
    ld   (STMT_ROW_IDX), a
    jr   nz, .fs_up_walk
.fs_up_have_old_pos:
    ld   (FAST_SCROLL_OLD_POS), hl

    call GFX_SCROLL_TEXT_UP

    ld   hl, ROW_SHADOW_POS + 2
    ld   de, ROW_SHADOW_POS
    ld   bc, 22*2
    ldir
    ld   hl, ROW_SHADOW_FLAGS + 1
    ld   de, ROW_SHADOW_FLAGS
    ld   bc, 22
    ldir

    ld   a, (FAST_SCROLL_NEW_ROW)
    dec  a
    jr   .fs_redraw_settled

.fs_do_down:
    xor  a
    ld   (FAST_SCROLL_NEW_ROW), a

    ld   hl, (CUR_EDIT_POS)
    call MEM_LINE_NEXT
    ld   a, h
    or   l
    jr   z, .auto_scroll_done             ; old active was the new-line
                                          ; placeholder, not a real
                                          ; statement — rare, not worth
                                          ; the fast path
    ld   (FAST_SCROLL_OLD_POS), hl

    call GFX_SCROLL_TEXT_DOWN

    ld   hl, ROW_SHADOW_POS + 22*2 - 1
    ld   de, ROW_SHADOW_POS + 23*2 - 1
    ld   bc, 22*2
    lddr
    ld   hl, ROW_SHADOW_FLAGS + 21
    ld   de, ROW_SHADOW_FLAGS + 22
    ld   bc, 22
    lddr

    ld   a, 1

.fs_redraw_settled:
    ; A = the settled row's new position (post-shift) — draw the
    ; statement FAST_SCROLL_OLD_POS there in highlighted/settled style
    ; via the same shared tail .render_settled itself now uses
    ld   (PROGRAM_ROW), a
    ld   a, 1
    ld   (STMT_ROW_COUNT), a

    ld   hl, (FAST_SCROLL_OLD_POS)
    push hl
    inc  hl
    inc  hl
    ld   de, DETOK_BUF
    call BASIC_DETOKENIZE_TO_BUF
    pop  hl

    push hl
    call BASIC_IS_ERROR_STATEMENT
    jr   c, .fs_not_error
    ld   a, 1
    ld   (LINE_IS_ERROR), a
    jr   .fs_error_done
.fs_not_error:
    xor  a
    ld   (LINE_IS_ERROR), a
.fs_error_done:
    pop  hl

    call BASIC_DRAW_SETTLED_ROW_TAIL

    ; draw the newly-scrolled-into-view active line, plain, from
    ; EDIT_LINE_BUF — same shared tail .have_start's active-line branch
    ; itself now uses
    ld   a, (FAST_SCROLL_NEW_ROW)
    ld   (PROGRAM_ROW), a
    ld   a, 1
    ld   (STMT_ROW_COUNT), a
    call BASIC_DRAW_ACTIVE_ROW_TAIL

    ld   a, (FAST_SCROLL_NEW_ROW)
    ld   (BASIC_ACTIVE_ROW), a
    jp   .draw_cursor                     ; .draw_cursor itself updates
                                          ; LAST_VIEW_TOP_INDEX now

.auto_scroll_done:
    ; walk to the VIEW_TOP_INDEX-th statement — that's where row 0
    ; starts. MEM_LINE_FIRST must be called FIRST: its own contract
    ; says it destroys DE (it uses DE internally as PROG_AREA_START
    ; and never restores it), so loading VIEW_TOP_INDEX into DE before
    ; calling it would get silently overwritten — a real bug that
    ; shipped once already, caught via a diagnostic showing the
    ; correct underlying state (PROG_END, CUR_EDIT_INDEX, etc. were
    ; all exactly right) while the actual rendering showed nothing,
    ; narrowing it to this walk specifically rather than storage.
    call MEM_LINE_FIRST
    ld   de, (VIEW_TOP_INDEX)
.skip_to_view_top:
    ld   a, d
    or   e
    jr   z, .have_start                ; reached VIEW_TOP_INDEX
    ld   a, h
    or   l
    jr   z, .have_start                  ; ran out early — shouldn't
                                        ; normally happen given the
                                        ; scroll math, but stop
                                        ; defensively rather than
                                        ; operate on HL=0
    push de
    call MEM_LINE_NEXT
    pop  de
    dec  de
    jr   .skip_to_view_top

.have_start:
    xor  a
    ld   (PROGRAM_ROW), a
    ld   (RENDER_CACHE_IDX), a            ; reset the row-count cache
                                          ; read position — see
                                          ; ROW_COUNT_CACHE's own
                                          ; sysvars.inc header

.render_loop:
    ld   a, h
    or   l
    jp   z, .render_done                ; end of program
    ld   a, (PROGRAM_ROW)
    cp   23
    jp   nc, .render_done                 ; program view full — row 23
                                         ; is reserved for the status
                                         ; line (BASIC_DRAW_STATUS_LINE)

    push hl                                 ; save statement pointer —
                                           ; both branches below and
                                           ; MEM_LINE_NEXT will clobber
                                           ; HL, and MEM_LINE_NEXT needs
                                           ; the ORIGINAL pointer
    ld   de, (CUR_EDIT_POS)
    or   a
    sbc  hl, de
    pop  hl
    jr   nz, .render_settled

    ; this row IS the actively-edited existing line — plain, from
    ; EDIT_LINE_BUF. Always cleared+redrawn regardless of shadow state
    ; (its own content can change on every keystroke, nothing useful
    ; to diff against), across as many physical rows as it currently
    ; word-wraps to (EDITOR_WRAP_CALC/BASIC_PRINT_LINE_PLAIN_WRAPPED —
    ; see kernel/editor and that routine's own header).
    push hl
    ld   hl, EDIT_LINE_BUF
    call BASIC_EDITOR_WRAP_CALC_EXROM
    ld   a, (EDIT_WRAP_COUNT)
    ld   (STMT_ROW_COUNT), a

    call BASIC_ROW_SUM
    cp   24
    jr   nc, .active_existing_no_fit     ; wouldn't fully fit above the
                                        ; status bar — same "shouldn't
                                        ; actually be reachable, kept
                                        ; as cheap defensive insurance"
                                        ; reasoning as .render_done's
                                        ; own copy of this same check
                                        ; for the new-line case (see
                                        ; that one for the full
                                        ; reasoning) — BASIC_SCROLL_TO_
                                        ; FIT already guarantees
                                        ; CUR_EDIT_INDEX's own target
                                        ; fits, whether that target is
                                        ; an existing statement (this
                                        ; branch) or the new-line
                                        ; sentinel (that one)

    ld   a, (PROGRAM_ROW)
    ld   (BASIC_ACTIVE_ROW), a

    call BASIC_DRAW_ACTIVE_ROW_TAIL

    call BASIC_ROW_SUM
    ld   (PROGRAM_ROW), a

    pop  hl
    jp   .next_statement

.active_existing_no_fit:
    pop  hl
    jp   .render_done

.render_settled:
    push hl
    inc  hl
    inc  hl                                  ; skip the 2-byte length prefix
    ld   de, DETOK_BUF
    call BASIC_DETOKENIZE_TO_BUF
    pop  hl                                  ; HL = original statement
                                            ; position, restored

    ; is this statement one BASIC_CHECK_PROGRAM flagged? Remembered in
    ; LINE_IS_ERROR (a register can't survive the highlighted-print
    ; call below) and acted on afterward — coloring is a separate step
    ; from the character rendering itself, not intertwined with it
    push hl
    call BASIC_IS_ERROR_STATEMENT
    jr   c, .not_error_line
    ld   a, 1
    ld   (LINE_IS_ERROR), a
    jr   .error_check_done
.not_error_line:
    xor  a
    ld   (LINE_IS_ERROR), a
.error_check_done:
    pop  hl                               ; hl = statement position

    ; word-wrap: how many physical rows does this statement need, and
    ; does that many fit above the status bar from here? Needed before
    ; touching the shadow at all, since the fit decision doesn't depend
    ; on whether the content changed.
    ;
    ; PERFORMANCE FIX (2026-08-24, Priority 2 of the same pass as
    ; BASIC_SCROLL_TO_FIT's own rewrite): this used to call BASIC_
    ; EDITOR_WRAP_CALC_EXROM (a real EXROM round trip, not the "cheap"
    ; cost the old comment here assumed) unconditionally, EVERY redraw,
    ; for EVERY settled statement — even though BASIC_SCROLL_TO_FIT,
    ; called moments earlier in this exact same redraw, already
    ; computed the identical row count for every statement from
    ; VIEW_TOP_INDEX up to CUR_EDIT_INDEX (via BASIC_ROWS_BEFORE_INDEX)
    ; and left it in ROW_COUNT_CACHE. This statement is exactly the
    ; RENDER_CACHE_IDX-th one rendered so far this pass (both walks
    ; start at VIEW_TOP_INDEX, in the same MEM_LINE_NEXT order) — reuse
    ; the cached value when one's available; only the active line
    ; itself (never cached — BASIC_ROWS_BEFORE_INDEX's own walk stops
    ; right before CUR_EDIT_INDEX) and any settled statements AFTER it
    ; (extra room below the active line, never covered by that walk
    ; either) fall back to computing directly, same as before.
    ld   a, (RENDER_CACHE_IDX)
    ld   b, a
    ld   a, (ROW_COUNT_CACHE_LEN)
    cp   b
    jr   z, .settled_no_cache             ; every cached entry already
                                          ; consumed
    jr   c, .settled_no_cache             ; defensive: idx somehow past
                                          ; len — shouldn't happen,
                                          ; fall back rather than read
                                          ; past the valid entries
    push hl                              ; hl = statement position —
                                         ; survives the cache lookup
                                         ; below the same way it
                                         ; already survives the wrap-
                                         ; calc call in the no-cache
                                         ; path (MEM_LINE_NEXT at
                                         ; .next_statement still needs
                                         ; it): a stray un-preserved HL
                                         ; across a destructive
                                         ; sequence is this exact
                                         ; routine's own documented
                                         ; recurring bug class (see
                                         ; .settled_color_row_loop's
                                         ; own comment on it below)
    ld   hl, ROW_COUNT_CACHE
    ld   e, b
    ld   d, 0
    add  hl, de
    ld   a, (hl)
    ld   (STMT_ROW_COUNT), a
    pop  hl
    ld   a, (RENDER_CACHE_IDX)
    inc  a
    ld   (RENDER_CACHE_IDX), a
    jr   .settled_have_row_count
.settled_no_cache:
    push hl
    ld   hl, DETOK_BUF
    call BASIC_EDITOR_WRAP_CALC_EXROM
    pop  hl
    ld   a, (EDIT_WRAP_COUNT)
    ld   (STMT_ROW_COUNT), a
.settled_have_row_count:

    call BASIC_ROW_SUM
    cp   24
    jr   nc, .render_done                 ; wouldn't fully fit — stop
                                         ; rendering here, leave this
                                         ; statement (and anything
                                         ; after it) for a future
                                         ; scroll page

    ; screen-flicker fix: check EVERY physical row this statement
    ; occupies against the shadow — if ANY of them mismatches, treat
    ; the whole statement as needing a fresh draw (simpler and still
    ; correct vs. a true partial-row redraw, and matches this
    ; project's stated preference for simplicity over micro-
    ; optimization). Only skip drawing entirely if ALL of them match.
    xor  a
    ld   (STMT_ROW_IDX), a
.settled_shadow_check_loop:
    ld   a, (STMT_ROW_IDX)
    ld   b, a
    ld   a, (STMT_ROW_COUNT)
    cp   b
    jr   z, .settled_all_matched          ; checked every row, none
                                         ; mismatched

    ld   a, (PROGRAM_ROW)
    add  a, b
    ld   b, a                             ; B = this physical row
    push hl                               ; hl = statement position
    ex   de, hl
    ld   a, (LINE_IS_ERROR)
    ld   c, a
    call BASIC_ROW_SHADOW_MATCHES
    pop  hl
    jr   c, .settled_needs_redraw         ; mismatch — stop checking,
                                         ; go draw all of it

    ld   a, (STMT_ROW_IDX)
    inc  a
    ld   (STMT_ROW_IDX), a
    jr   .settled_shadow_check_loop

.settled_all_matched:
    jr   .settled_advance                 ; nothing changed — just
                                         ; advance PROGRAM_ROW

.settled_needs_redraw:
    ; genuinely changed — DETOK_BUF/LINE_IS_ERROR were already set
    ; above (needed for the shadow-match check that got us here), so
    ; the shared tail can go straight to clear+draw+color+shadow-update
    call BASIC_DRAW_SETTLED_ROW_TAIL

.settled_advance:
    call BASIC_ROW_SUM
    ld   (PROGRAM_ROW), a

.next_statement:
    call MEM_LINE_NEXT
    jp   .render_loop

.render_done:
    ; if CUR_EDIT_POS is still the sentinel, none of the existing
    ; statements above matched it — render the new/uncommitted line
    ; now. Always cleared+redrawn (same reasoning as the active-line
    ; branch above — its content changes every keystroke, nothing
    ; useful to diff against), across as many physical rows as it
    ; currently word-wraps to.
    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    jr   nz, .clear_leftover_rows          ; not the sentinel — an
                                          ; existing statement was
                                          ; already the active line,
                                          ; nothing new to draw here

    ld   hl, EDIT_LINE_BUF
    call BASIC_EDITOR_WRAP_CALC_EXROM
    ld   a, (EDIT_WRAP_COUNT)
    ld   (STMT_ROW_COUNT), a

    call BASIC_ROW_SUM
    cp   24
    jr   nc, .clear_leftover_rows          ; wouldn't fully fit above
                                          ; the status bar — shouldn't
                                          ; actually be reachable now
                                          ; that BASIC_SCROLL_TO_FIT
                                          ; (called at the top of this
                                          ; routine) already guarantees
                                          ; the target's full row-height
                                          ; fits before the render loop
                                          ; ever gets here; kept as a
                                          ; cheap defensive check rather
                                          ; than removed outright — if
                                          ; it ever does trigger, that
                                          ; means the two computations
                                          ; disagree somewhere, and
                                          ; skipping the draw here is
                                          ; still safer than corrupting
                                          ; the status bar row

    ld   a, (PROGRAM_ROW)
    ld   (BASIC_ACTIVE_ROW), a

    call BASIC_CLEAR_STMT_ROWS

    ld   hl, EDIT_LINE_BUF
    ld   a, (PROGRAM_ROW)
    ld   b, a
    call BASIC_PRINT_LINE_PLAIN_WRAPPED

    call BASIC_ROW_SUM
    ld   (PROGRAM_ROW), a                    ; the sentinel line counts
                                            ; for its own real row
                                            ; count now, not always +1,
                                            ; for the leftover-rows
                                            ; cleanup below

.clear_leftover_rows:
    ; if the previous redraw used MORE rows than this one (e.g. a
    ; statement was just deleted), the rows in between need to be
    ; explicitly cleared — nothing else would ever touch them, since
    ; the main loop above simply stops once it runs out of statements.
    ; Hand-verified via a Python simulation (1-row and multi-row
    ; shrink cases, plus the no-op cases where the count stayed the
    ; same or grew) before being written here.
    ld   a, (LAST_RENDERED_ROWS)
    ld   b, a
    ld   a, (PROGRAM_ROW)
    cp   b
    jr   nc, .no_leftover_rows                ; current count is >=
                                             ; the previous one —
                                             ; nothing leftover

    ld   a, (LAST_RENDERED_ROWS)                ; a = old count
                                               ; (unchanged since
                                               ; loaded above, but
                                               ; reloaded for clarity)
    ld   b, a
    ld   a, (PROGRAM_ROW)                          ; a = new count
.clear_leftover_loop:
    push af
    push bc
    ld   b, a
    call GFX_CLEAR_ROW
    pop  bc
    pop  af
    inc  a
    cp   b
    jr   nz, .clear_leftover_loop

.no_leftover_rows:
    ld   a, (PROGRAM_ROW)
    ld   (LAST_RENDERED_ROWS), a

.draw_cursor:
    ; the fast-scroll path's own "did VIEW_TOP_INDEX move by exactly
    ; one statement since last time" check needs an accurate baseline
    ; from EVERY redraw, not just its own successful runs — updated
    ; here, the one point both the full render loop and the fast path
    ; converge on, rather than duplicated in both
    ld   hl, (VIEW_TOP_INDEX)
    ld   (LAST_VIEW_TOP_INDEX), hl

    ; REAL BUG FIXED ALONGSIDE WORD-WRAP: this used to take EDIT_BUF_
    ; OFFSET's low byte directly as the screen column with no bounds
    ; check at all — correct only by coincidence, when every line was
    ; short enough to fit in 32 columns. For any offset >= 32 (which
    ; word-wrap now makes a completely ordinary, expected case, not a
    ; rare edge condition) it would pass an out-of-range column
    ; straight to GFX_INVERT_ATTR, the same class of silent-corruption
    ; risk BASIC_PRINT_LINE_HIGHLIGHTED's own column bounds check was
    ; originally added to prevent (see that routine's git history).
    ; Fixed by mapping the offset through the SAME wrap tables the
    ; active line was just drawn with, via EDITOR_WRAP_OFFSET_TO_
    ; ROWCOL, to get the real (sub-row, column) the cursor should
    ; blink at.
    ld   hl, EDIT_LINE_BUF
    call BASIC_EDITOR_WRAP_CALC_EXROM              ; recompute — BASIC_PRINT_LINE_
                                       ; PLAIN_WRAPPED's own internal
                                       ; call to this may have been
                                       ; overwritten since, by a later
                                       ; settled statement's own
                                       ; EDITOR_WRAP_CALC call in the
                                       ; loop above
    ld   a, (EDIT_BUF_OFFSET)          ; low byte only — offset never
                                       ; exceeds 127, fits in A
    call BASIC_EDITOR_WRAP_OFFSET_TO_ROWCOL_EXROM  ; B = sub-row within the active
                                       ; line, C = column
    ld   a, (BASIC_ACTIVE_ROW)
    add  a, b
    ld   b, a                          ; B = real screen row
    call GFX_INVERT_ATTR

    jr BASIC_DRAW_STATUS_LINE

; ============================================================================
; BASIC_DRAW_STATUS_LINE
; Renders a status line at row 23 (reserved, never used by the program
; view itself — see BASIC_REDRAW_PROGRAM's render bound). Normally
; shows either "NEW LINE" (on the sentinel) or "LINE n/m" — which
; statement is being edited, 1-based, out of how many exist — but
; shows an error-related message instead whenever CHECK_ERROR_COUNT is
; nonzero (see below). Shown in inverse video across the full row so
; it reads as a distinct status bar rather than blending with program
; content.
;
; CHECK_ERROR_COUNT is checked FIRST, before anything else — a whole-
; program check failure takes priority over the normal line indicator.
; Set by BASIC_CHECK_PROGRAM (via BASIC_RUN, when it decides not to run
; a program that failed the check) and left in place — deliberately —
; until the next successful commit clears it (see BASIC_COMMAND_LOOP),
; so the message stays visible while browsing the program, not just
; for one redraw. This replaces an earlier version of this feature
; that used BASIC_REPORT_ERROR's full-screen display instead — changed
; after direct feedback: a full-screen takeover blocks the rest of the
; program from view, which defeats the purpose once red-highlighted
; error lines and SYMBOL SHIFT+A/S navigation exist — you need to see
; the whole program AND the current error at the same time to browse
; between problems and fix them, which a full-screen message can't
; support at all.
;
; DELETE_INVALID_FLAG is checked before even that — highest priority
; of all, but shown for exactly ONE redraw rather than persisting: set
; by the DELETE dispatch when BASIC_DO_DELETE rejects a typed range
; (user-requested: rejecting a DELETE silently, only surfacing as
; SYNTAX ERROR on the next RUN, wasn't enough feedback). Read AND
; CLEARED here, in the same instruction sequence, so the very next
; time this routine runs (the user's first keystroke on the next line)
; it's already gone and normal status resumes — deliberately NOT
; sticky like CHECK_ERROR_COUNT, since there's no ongoing problem to
; keep showing once the rejected text has already been discarded (a
; sticky message here would be actively misleading — nothing is
; wrong with the program itself, just with what was typed a moment
; ago). STORAGE_CMD_INVALID_FLAG (SAVE/LOAD's own malformed-filename
; rejection) is checked right after, same one-shot shape, same
; reasoning — see that sysvar's own comment for why it's a separate
; flag rather than DELETE_INVALID_FLAG reused/generalized.
; STORAGE_OP_STATE follows right after, a richer replacement for what
; used to be three separate one-shot flags (LOAD_FAILED_FLAG, SAVE_
; SUCCESS_FLAG, LOAD_SUCCESS_FLAG) — see its own sysvars.inc comment
; and BASIC_FORMAT_STORAGE_STATUS (rom/exrom_storage.asm, reached via
; BASIC_FORMAT_STORAGE_STATUS_EXROM below) for the full dispatch, which
; also handles two NON-one-shot states (SAVING/LOADING in progress,
; showing a live percentage — not cleared here, the kernel-side block
; loop advances out of those itself).
;
; With the cursor sitting on one of the flagged lines specifically
; (checked via BASIC_IS_ERROR_STATEMENT, the same routine the red-
; highlighting logic uses), this shows THAT line's own specific
; message (SYNTAX ERROR, LABEL NOT FOUND, etc.) instead of the generic
; count — re-running BASIC_CHECK_STATEMENT on just that one statement
; to get it, rather than storing a message alongside every position in
; CHECK_ERROR_LIST (which would need real new storage — doubling every
; entry's size — for something this on-demand recomputation gets for
; free, since BASIC_CHECK_STATEMENT is already fully side-effect-free
; by design). Otherwise (errors exist, but the cursor isn't currently
; on one of them) falls back to the generic "N ERRORS FOUND" — e.g.
; right after RUN, while still on the sentinel, before any navigation
; has happened yet.
;
; Builds the combined string in STATUS_BUF via BASIC_APPEND_STR (a
; global routine, reused by both this and the error-count path here),
; tracking the write position in STATUS_WRITE_PTR (memory, not a
; register) — BASIC_NUM_TO_STRING destroys DE on every call, so
; nothing that needs to survive across it can live in a register here,
; same lesson as everywhere else in this project that assembles text
; from multiple converted numbers.
; In:  none (reads CHECK_ERROR_COUNT, CUR_EDIT_POS/CUR_EDIT_INDEX)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_DRAW_STATUS_LINE:
    ld   a, (DELETE_INVALID_FLAG)
    or   a
    jr   z, .no_delete_error
    xor  a
    ld   (DELETE_INVALID_FLAG), a          ; clear immediately — shown
                                          ; exactly once, see this
                                          ; routine's own header
    ld   hl, MSG_INVALID_RANGE
    jp   BASIC_PRINT_STATUS_TEXT

.no_delete_error:
    ld   a, (STORAGE_CMD_INVALID_FLAG)
    or   a
    jr   z, .no_storage_cmd_error
    xor  a
    ld   (STORAGE_CMD_INVALID_FLAG), a     ; same one-shot shape as
                                          ; DELETE_INVALID_FLAG just
                                          ; above — see that sysvar's
                                          ; own comment for why this is
                                          ; a separate flag, not that
                                          ; one generalized
    ld   hl, MSG_INVALID_FILENAME
    jp   BASIC_PRINT_STATUS_TEXT

.no_storage_cmd_error:
    ld   a, (STORAGE_OP_STATE)
    or   a
    jr   z, .no_storage_status              ; 0 = idle, nothing to show
    cp   1
    jr   z, .storage_in_progress            ; 1 = SAVING
    cp   3
    jr   z, .storage_in_progress            ; 3 = LOADING
    cp   7
    jr   z, .storage_in_progress            ; 7 = PROGRAM: <name> found,
                                           ; receiving data — see
                                           ; kernel/storage/storage.asm
                                           ; STORAGE_LOAD's own .length_ok
    ; anything else nonzero (2/4/5/6) is a one-shot completion state
.storage_one_shot:
    call BASIC_FORMAT_STORAGE_STATUS_EXROM
    xor  a
    ld   (STORAGE_OP_STATE), a              ; clear — shown exactly
                                           ; once, same one-shot shape
                                           ; as DELETE_INVALID_FLAG
    ld   hl, STATUS_BUF
    jp   BASIC_PRINT_STATUS_TEXT

.storage_in_progress:
    call BASIC_FORMAT_STORAGE_STATUS_EXROM
    ld   hl, STATUS_BUF
    jp   BASIC_PRINT_STATUS_TEXT            ; NOT cleared — the kernel-
                                           ; side block loop advances
                                           ; out of this state itself,
                                           ; not this routine

.no_storage_status:
    ld   hl, (CHECK_ERROR_COUNT)
    ld   a, h
    or   l
    jr   z, .normal_status

    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_ERROR_STATEMENT
    jr   c, .show_count                     ; cursor isn't on a
                                           ; flagged line — fall back
                                           ; to the generic count

    ; Dirty-check before paying for an EXROM call: BASIC_CHECK_
    ; STATEMENT_EXROM pages EXROM in and out on every call, and this
    ; whole routine is reached on EVERY status-line redraw — see
    ; BASIC_REDRAW_PROGRAM's own header ("full-redraw-every-keypress")
    ; — so re-deriving the same message from scratch every keystroke
    ; while the cursor sits still on one flagged line would page EXROM
    ; on every one of those keystrokes for an answer that hasn't
    ; changed. STATUS_CHECK_VALID/_CACHED_POS/_CACHED_MSG (sysvars.inc)
    ; remember the last result; reuse it if CUR_EDIT_POS still matches
    ; — invalidated by BASIC_SCAN_LABELS_EXROM/BASIC_FULL_CHECK_EXROM
    ; themselves whenever the whole-program check reruns (see those
    ; wrappers' own comments), so a stale cache can't survive a commit,
    ; RUN, or LOAD.
    ld   a, (STATUS_CHECK_VALID)
    or   a
    jr   z, .status_check_miss
    ld   hl, (STATUS_CHECK_CACHED_POS)
    ld   de, (CUR_EDIT_POS)
    or   a
    sbc  hl, de
    jr   nz, .status_check_miss             ; cache is for a DIFFERENT
                                           ; statement — doesn't apply
                                           ; here

    ld   hl, (STATUS_CHECK_CACHED_MSG)      ; cache hit — no EXROM call
    jp   BASIC_PRINT_STATUS_TEXT            ; this redraw at all

.status_check_miss:
    ld   de, 0
    ld   (PENDING_ERROR_MSG), de              ; fresh check — same
                                             ; reset BASIC_CHECK_
                                             ; PROGRAM's own loop does
                                             ; per statement
    ld   hl, (CUR_EDIT_POS)
    call BASIC_CHECK_STATEMENT_EXROM        ; now in EXROM — see that
                                           ; wrapper's own header for
                                           ; why this specific call
                                           ; site needed extra care
                                           ; (carry-flag survival, hot-
                                           ; path timing)
    jr   nc, .status_check_defensive        ; defensive — a flagged
                                           ; line should always fail
                                           ; this, but fall back rather
                                           ; than show nothing (or
                                           ; cache a wrong result) if
                                           ; it somehow doesn't

    ld   hl, (CUR_EDIT_POS)                 ; genuine hit — remember it
    ld   (STATUS_CHECK_CACHED_POS), hl      ; so the NEXT redraw of
    ld   hl, (PENDING_ERROR_MSG)            ; this same line (the
    ld   (STATUS_CHECK_CACHED_MSG), hl      ; common case — most
    ld   a, 1                              ; keystrokes don't move the
    ld   (STATUS_CHECK_VALID), a            ; cursor to a new
                                           ; statement) can skip EXROM
                                           ; entirely

    ld   hl, (PENDING_ERROR_MSG)
    jp   BASIC_PRINT_STATUS_TEXT

.status_check_defensive:
    jr   .show_count                        ; leave the cache exactly
                                           ; as it was (untouched, not
                                           ; marked valid) — don't let
                                           ; this "shouldn't happen"
                                           ; path poison a future
                                           ; redraw with a wrong cached
                                           ; hit

.show_count:
    ld   hl, STATUS_BUF
    ld   (STATUS_WRITE_PTR), hl

    ld   de, (CHECK_ERROR_COUNT)
    call BASIC_NUM_TO_STRING              ; HL = decimal string
    call BASIC_APPEND_STR

    ld   de, (CHECK_ERROR_COUNT)
    ld   a, d
    or   a
    jr   nz, .use_plural
    ld   a, e
    cp   1
    jr   nz, .use_plural

    ld   hl, MSG_ERROR_FOUND_SUFFIX_SING
    jr   .have_suffix
.use_plural:
    ld   hl, MSG_ERRORS_FOUND_SUFFIX
.have_suffix:
    call BASIC_APPEND_STR

    ld   hl, STATUS_BUF
    jr   BASIC_PRINT_STATUS_TEXT

.normal_status:
    ld   hl, (CUR_EDIT_POS)
    call BASIC_IS_SENTINEL
    jr   nz, .show_line_number

    ld   hl, STATUS_NEW_TEXT
    jr   BASIC_PRINT_STATUS_TEXT

.show_line_number:
    ; Redraw work-count optimization (2026-08-27): cursor movement and
    ; character typing reach this path on every keystroke. Previously each
    ; one walked the entire program through BASIC_COUNT_STATEMENTS and ran
    ; two integer-to-string conversions, only for BASIC_PRINT_STATUS_TEXT's
    ; final text comparison to discover that the same LINE n/m was already
    ; visible. LAST_STATUS_TEXT beginning with "LI" proves the last status
    ; was the normal line indicator (no other status message uses that
    ; prefix), and STATUS_TOTAL_TMP is repurposed between redraws as the
    ; index for which it was built. Structural edits reset LAST_STATUS_TEXT;
    ; appending advances CUR_EDIT_INDEX. Both therefore miss safely.
    ld   hl, (LAST_STATUS_TEXT)         ; first two cached characters
    ld   de, $494C                     ; little-endian "LI"
    or   a
    sbc  hl, de
    jr   nz, .line_status_changed
    ld   hl, (STATUS_TOTAL_TMP)         ; cached CUR_EDIT_INDEX
    ld   de, (CUR_EDIT_INDEX)
    or   a
    sbc  hl, de
    ret  z                              ; identical LINE n/m already shown

.line_status_changed:
    call BASIC_COUNT_STATEMENTS          ; DE = total
    ld   (STATUS_TOTAL_TMP), de

    ld   hl, STATUS_BUF
    ld   (STATUS_WRITE_PTR), hl

    ld   hl, STATUS_PREFIX_TEXT            ; "LINE "
    call BASIC_APPEND_STR

    ld   hl, (CUR_EDIT_INDEX)
    inc  hl                                  ; 1-based for display
    ex   de, hl
    call BASIC_NUM_TO_STRING                   ; HL = decimal string
    call BASIC_APPEND_STR

    ld   hl, STATUS_SLASH_TEXT
    call BASIC_APPEND_STR

    ld   de, (STATUS_TOTAL_TMP)
    call BASIC_NUM_TO_STRING
    call BASIC_APPEND_STR

    ld   de, (CUR_EDIT_INDEX)
    ld   (STATUS_TOTAL_TMP), de          ; cache key for the fast path above
    ld   hl, STATUS_BUF

; ============================================================================
; BASIC_PRINT_STATUS_TEXT
; Draws HL as the row-23 status line: inverted attribute, branding
; swatch in the rightmost 3 columns, no GFX_CLS (whatever's on rows
; 0-22 is left completely alone). Was BASIC_DRAW_STATUS_LINE's own
; internal .print_status tail; promoted to a real global entry point
; (2026-08-22) so BASIC_REPORT_ERROR could reuse the exact same
; "status bar, not a full-screen takeover" rendering for RUNTIME
; errors too — see that routine's own header for the reasoning.
; In:  HL = null-terminated message (should fit comfortably within 28
;      columns — the branding swatch owns columns 29-31, and nothing
;      here truncates for a caller that ignores that budget)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_PRINT_STATUS_TEXT:
    ; screen-flicker fix for the status bar itself: this routine runs
    ; on every single redraw regardless of whether the status text
    ; actually changed (unlike the diff-aware main render loop above),
    ; so clearing+reprinting+inverting unconditionally produced a
    ; visible flash even when nothing about it was different — found
    ; from the user reporting this exact symptom right after the
    ; earlier status-bar toggle fix. Compare against what was shown
    ; last time (LAST_STATUS_TEXT) and skip entirely if identical.
    ; Hand-traced against both the "unchanged" and "changed" cases
    ; (including the copy loop that records the new text afterward)
    ; before being trusted.
    push hl
    ld   de, LAST_STATUS_TEXT
.compare_loop:
    ld   a, (de)
    cp   (hl)
    jr   nz, .text_changed
    or   a
    jr   z, .text_unchanged            ; both hit the null terminator
                                      ; together — identical strings
    inc  hl
    inc  de
    jr   .compare_loop

.text_unchanged:
    pop  hl
    ret                                   ; already correctly shown —
                                        ; nothing to do

.text_changed:
    pop  hl

    push hl                                ; record the new text for
                                          ; next time's comparison
    ld   de, LAST_STATUS_TEXT
.copy_loop:
    ld   a, (hl)
    ld   (de), a
    or   a
    jr   z, .copy_done
    inc  hl
    inc  de
    jr   .copy_loop
.copy_done:
    pop  hl

    ; clear row 23's BITMAP only — GFX_CLEAR_ROW_TEXT, not
    ; GFX_CLEAR_ROW, deliberately leaves the attribute untouched. A
    ; smaller, but still-present, flash remained even after the
    ; earlier toggle-bug fix: that fix cleared to the DEFAULT
    ; attribute first, then toggled it to inverted — correct, but the
    ; row still visibly passed through a non-inverted intermediate
    ; state for the moment in between, on every text change. Clearing
    ; only the bitmap here, then setting the inverted attribute
    ; directly below (GFX_SET_ATTR, not GFX_INVERT_ATTR_STATIC) rather
    ; than toggling from a cleared default, means the attribute goes
    ; straight from whatever it was to the final inverted value in one
    ; step, with no visible state in between at all.
    push hl                        ; save the string pointer —
                                   ; GFX_CLEAR_ROW_TEXT destroys HL
    ld   b, 23
    call GFX_CLEAR_ROW_TEXT
    pop  hl

    ld   b, 23
    ld   c, 0
    call GFX_PRINT_STRING

    ; set the whole row's attribute directly to the inverted value —
    ; GFX_SET_ATTR, not GFX_INVERT_ATTR/GFX_INVERT_ATTR_STATIC, which
    ; both swap ink/paper relative to whatever's already there rather
    ; than setting a known, fixed value outright
    ld   c, 0
.invert_loop:
    push bc                        ; save column counter — GFX_SET_
                                   ; ATTR destroys BC entirely
    ld   a, ATTR_STATUS_BAR
    ld   b, 23
    call GFX_SET_ATTR
    pop  bc
    inc  c
    ld   a, c
    cp   32
    jr   c, .invert_loop

    ; Branding swatch: 3 solid-color cells in the status bar's
    ; reserved rightmost columns (29/30/31), echoing the red/green/
    ; blue bars under the real TS2068's "PERSONAL COLOR COMPUTER"
    ; logo. Drawn AFTER the uniform inverse-video pass above so it
    ; overrides those three cells rather than being overwritten by
    ; them. Safe against every status message this routine can show —
    ; the longest (LOAD FAILED's diagnostic suffix) tops out around 26
    ; characters, well clear of column 29. The cells themselves are
    ; already blank (GFX_CLEAR_ROW_TEXT cleared the whole row's bitmap
    ; before GFX_PRINT_STRING ran), so no pixels need drawing — a
    ; blank cell shows pure PAPER color regardless of INK, which is
    ; exactly what a solid block needs.
    ld   a, ATTR_SWATCH_RED
    ld   b, 23
    ld   c, 29
    call GFX_SET_ATTR
    ld   a, ATTR_SWATCH_GREEN
    ld   b, 23
    ld   c, 30
    call GFX_SET_ATTR
    ld   a, ATTR_SWATCH_BLUE
    ld   b, 23
    ld   c, 31
    jp GFX_SET_ATTR

; ============================================================================
; BASIC_APPEND_STR
; Appends a null-terminated string onto whatever's already been
; written to STATUS_BUF, tracked via STATUS_WRITE_PTR — the shared
; "build a message out of several pieces" primitive. Originally local
; to BASIC_DRAW_STATUS_LINE (for "LINE n/m"), promoted to a global
; routine once BASIC_RUN needed the exact same pattern to build an "N
; ERRORS FOUND" message out of a number and fixed text.
; Capped at STATUS_BUF+28 (2026-08-22): every caller before
; BASIC_REPORT_ERROR's own status-line rewrite appended only short,
; bounded pieces (a handful of digits, fixed short text) that could
; never approach STATUS_BUF's real 32-byte size — this had no bounds
; check because nothing before could trigger one. A detokenized
; program statement is neither short nor bounded, so silently keeping
; the old unbounded copy would risk walking straight past STATUS_BUF
; into STATUS_WRITE_PTR and whatever sysvar sits after it. 28 leaves
; the branding swatch's own reserved columns 29-31 untouched, matching
; BASIC_PRINT_STATUS_TEXT's own documented budget note.
; In:  HL = null-terminated source string to append
; Out: none — STATUS_BUF and STATUS_WRITE_PTR updated (silently
;      truncated if the combined text would exceed the cap)
; Destroys: AF, BC, DE, HL
; ============================================================================
    ENDIF
