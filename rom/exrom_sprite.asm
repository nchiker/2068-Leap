; ============================================================================
; rom/exrom_sprite.asm — SPRITE GRAB/SHOW/HIDE (moved from basic/basic.asm)
;
; ROM-shrink pass (2026-08-22), done ahead of Phase 3's array work once
; string scalars + concatenation left only 159 Home ROM bytes free.
; This whole feature (587 bytes, the largest single self-contained
; statement family in basic.asm after the ones that can't move — see
; this project's own size-audit reasoning: PRINT/GOTO/expression-eval/
; the main dispatch table are all far too hot-path to page in and out
; of EXROM on every statement) moved here verbatim, following the exact
; SAVE/LOAD/HELP/CALC/SOUND migration pattern: a thin Home-side
; BASIC_SPRITE_EXROM wrapper (basic/basic.asm) pages this in, calls a
; fixed entry stub (rom/exrom_checker.asm's EXROM_ENTRY_SPRITE, $C054),
; pages back out. The checker's OWN SPRITE validation
; (rom/exrom_checker.asm's .check_sprite) was already fully independent
; of this code before this move (grammar-only: argument count/shape,
; not range/state) — this move needed zero changes there.
;
; Every call that used to reach a Home-resident shared primitive
; (BASIC_SKIP_SPACES, BASIC_MATCH_KEYWORD_BOUNDARY, BASIC_EVAL_EXPR,
; BASIC_EXPECT_COMMA_EXPR, BASIC_EXPECT_STATEMENT_END, BASIC_SET_
; PENDING_ERROR) now goes through the existing KTAB_* entry for it —
; all six were already in the jump table for other reasons, so this
; move needed zero new KTAB entries for parsing. GFX_SPRITE_CAPTURE/
; GFX_SPRITE_DRAW (kernel/graphics) were the only two NEW KTAB entries
; this move needed (KTAB_COUNT +2, KTAB_MAGIC bumped accordingly).
; BASIC_RAISE_SYNTAX_ERROR (a bare `jp` target, not a KTAB-style
; `call`) has no jump-table entry of its own — duplicated locally
; instead as SPRITE_RAISE_SYNTAX_ERROR, cheaper than adding one for
; just two call sites. The six MSG_SPRITE_* error strings moved here
; too, alongside the only code that ever reads them.
; ============================================================================

; ============================================================================
; Sprites — SPRITE GRAB/SHOW/HIDE (2026-08-19)
; A fixed-slot (not array-based) sprite system on top of kernel/
; graphics' GFX_SPRITE_CAPTURE/GFX_SPRITE_DRAW (see that section's own
; header for the buffer format and cell-alignment scoping). Fixed
; slots because this BASIC has no array/named-buffer support yet — the
; same pragmatic "buildable now" call EXIT FOR made picking classic
; NEXT over SuperBASIC's END FOR. SPRITE_SLOT_MAX slots (currently 8),
; each capped at SPRITE_CELL_MAX x SPRITE_CELL_MAX whole 8x8 cells (see
; sysvars.inc's own SPRITE_SLOT_* comments for the exact layout).
;
; Grammar:
;   SPRITE GRAB <slot>,<row>,<col>,<w>,<h>  — capture whatever's on
;     screen at that cell rectangle into slot <slot>'s own image
;     buffer. Can be re-GRABbed any time, whether or not currently
;     shown (doesn't touch the shown state).
;   SPRITE SHOW <slot>,<row>,<col>          — GRAB must have happened
;     for this slot already. Captures the background at the new
;     position, draws the sprite there. Refuses (SPRITE ALREADY SHOWN)
;     if this slot is already shown — HIDE it first. This is
;     deliberate: each statement does one job, matching this project's
;     existing single-purpose-statement convention, rather than SHOW
;     silently auto-hiding first.
;   SPRITE HIDE <slot>                      — restores the background
;     saved by this slot's own SHOW/MOVE. Refuses (SPRITE NOT SHOWN) if
;     not currently shown.
;   SPRITE MOVE <slot>,<row>,<col>          — repositions an already-
;     SHOWN sprite in one statement: restores the background at its
;     OLD position, then captures+draws exactly like SHOW at the new
;     one. Refuses (SPRITE NOT SHOWN) if not currently shown — call
;     SHOW first, same as HIDE. Added 2026-08-23 alongside HIT()
;     (BASIC_EVAL_PRIMARY, basic/basic.asm) once it was clear HIDE-
;     then-SHOW as two separate statements was the only way to
;     reposition a sprite — MOVE doesn't draw anything HIDE-then-SHOW
;     wouldn't have anyway (same two GFX_SPRITE_DRAW/CAPTURE calls
;     either way — this hardware has no way to batch drawing within a
;     frame), just removes the need for a program to track/re-supply
;     w/h and spells out the intent directly.
;
; <row>/<col>/<w>/<h> are validated at BASIC level (0-23/0-31/1-4/1-4)
; BEFORE ever reaching GFX_SPRITE_BOUNDS_CHECK — deliberately: that
; kernel-level check computes row+height/col+width as a plain 8-bit
; ADD with no overflow guard of its own (fine for its own callers so
; far, all of which pass already-small values), so a grossly out-of-
; range row/col from a user expression could theoretically wrap an
; 8-bit sum back under the check's own threshold and slip through.
; Validating the small ranges here first makes that wraparound
; unreachable from BASIC, rather than fixing the kernel routine itself
; (out of scope this round — would need re-verification of already-
; z80sim-confirmed code). Once those ranges are confirmed small,
; GFX_SPRITE_BOUNDS_CHECK's own "does it actually fit on the 32x24
; grid" rejection is safe to rely on as-is (reported as SPRITE OUT OF
; RANGE).
; ============================================================================
BASIC_STMT_SPRITE:
    call KTAB_BASIC_SKIP_SPACES
    ld   de, KW_GRAB
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jp   nc, BASIC_STMT_SPRITE_GRAB

    ld   de, KW_SHOW
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jp   nc, BASIC_STMT_SPRITE_SHOW

    ld   de, KW_HIDE
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jp   nc, BASIC_STMT_SPRITE_HIDE

    ld   de, KW_MOVE
    call KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    jp   nc, BASIC_STMT_SPRITE_MOVE

    jp   SPRITE_RAISE_SYNTAX_ERROR

; ============================================================================
; BASIC_SPRITE_PARSE_SLOT
; Shared by GRAB/SHOW/HIDE/MOVE — all four start with a slot number.
; In:  HL = text pointer at the slot expression
; Out: carry clear + SPRITE_ARG_SLOT set + HL advanced past the
;      expression; carry set + error already recorded (SYNTAX ERROR
;      for a malformed expression, BAD SPRITE SLOT for one that parses
;      but is out of range) otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_SPRITE_PARSE_SLOT:
    call KTAB_BASIC_EVAL_EXPR
    jp   c, SPRITE_RAISE_SYNTAX_ERROR
    ld   a, e
    cp   SPRITE_SLOT_MAX
    jp   nc, .bad_slot
    ld   (SPRITE_ARG_SLOT), a
    or   a
    ret
.bad_slot:
    ld   hl, MSG_SPRITE_BAD_SLOT
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_SPRITE_SLOT_IMG_ADDR / BASIC_SPRITE_SLOT_BG_ADDR
; SPRITE_ARG_SLOT -> that slot's own fixed-size buffer address, in the
; image buffer or the background-save buffer respectively. Both
; buffers are laid out identically (SPRITE_SLOT_BYTES per slot,
; contiguous, slot 0 first) — same formula, different base, so these
; are two thin routines rather than one parameterized one, matching
; this file's existing preference for small dedicated routines over a
; shared one that needs an extra parameter to pick its base address.
; In:  none (reads SPRITE_ARG_SLOT)
; Out: HL = that slot's buffer address
; Destroys: AF, BC, HL
; ============================================================================
BASIC_SPRITE_SLOT_IMG_ADDR:
    ld   hl, SPRITE_SLOT_IMG_BUF
    jp   BASIC_SPRITE_ADD_SLOT_OFFSET
BASIC_SPRITE_SLOT_BG_ADDR:
    ld   hl, SPRITE_SLOT_BG_BUF
    ; falls through — see BASIC_SPRITE_ADD_SLOT_OFFSET below. Made this
    ; a real global tail-jump target (not a local .label) after check_
    ; asm.py caught the obvious first draft: a local label defined
    ; under THIS scope can't be jumped to from BASIC_SPRITE_SLOT_IMG_
    ; ADDR's own scope above, only from here — same class of mistake
    ; BASIC_RAISE_SYNTAX_ERROR exists to avoid project-wide by being a
    ; real global label instead.
BASIC_SPRITE_ADD_SLOT_OFFSET:
    ld   a, (SPRITE_ARG_SLOT)
    or   a
    ret  z                              ; slot 0 -> no offset needed
    ld   b, a                           ; B = slot (1-7 here; 0 already
                                        ; handled above)
    ld   de, SPRITE_SLOT_BYTES
.mul_loop:
    add  hl, de                         ; += SPRITE_SLOT_BYTES, once per
                                        ; slot — SPRITE_SLOT_MAX is 8,
                                        ; so at most 7 iterations; a
                                        ; loop reads more clearly here
                                        ; than a real multiply would for
                                        ; a range this small
    djnz .mul_loop
    ret

; ============================================================================
; BASIC_SPRITE_HAVE_ROW_COL / BASIC_SPRITE_HAVE_WH
; Small shared range-validators for GRAB/SHOW's own row/col/w/h
; arguments — see this section's own header for why these ranges are
; checked here rather than trusted to GFX_SPRITE_BOUNDS_CHECK alone.
; In:  A = the value just parsed
; Out: carry clear if in range; carry set + MSG_SPRITE_OUT_OF_RANGE (row/
;      col) or MSG_SPRITE_TOO_LARGE (w/h) already recorded otherwise
; Destroys: AF
; ============================================================================
BASIC_SPRITE_CHECK_ROW:
    cp   24
    jp   nc, BASIC_SPRITE_RANGE_FAIL
    or   a
    ret
BASIC_SPRITE_CHECK_COL:
    cp   32
    jp   nc, BASIC_SPRITE_RANGE_FAIL
    or   a
    ret
BASIC_SPRITE_RANGE_FAIL:
    ld   hl, MSG_SPRITE_OUT_OF_RANGE
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

BASIC_SPRITE_CHECK_WH:
    or   a
    jp   z, .size_fail                  ; 0 is invalid
    cp   SPRITE_CELL_MAX + 1
    jp   nc, .size_fail
    or   a
    ret
.size_fail:
    ld   hl, MSG_SPRITE_TOO_LARGE
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_STMT_SPRITE_GRAB
; SPRITE GRAB <slot>,<row>,<col>,<w>,<h> — see this section's own
; header above for the full grammar/design.
; In:  HL = text right after "GRAB"
; Out: carry clear on success; carry set + error already recorded
;      otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_SPRITE_GRAB:
    call BASIC_SPRITE_PARSE_SLOT
    ret  c

    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    ld   a, e
    call BASIC_SPRITE_CHECK_ROW
    ret  c
    ld   (SPRITE_ARG_ROW), a

    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    ld   a, e
    call BASIC_SPRITE_CHECK_COL
    ret  c
    ld   (SPRITE_ARG_COL), a

    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    ld   a, e
    call BASIC_SPRITE_CHECK_WH
    ret  c
    ld   (SPRITE_ARG_W), a

    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    ld   a, e
    call BASIC_SPRITE_CHECK_WH
    ret  c
    ld   (SPRITE_ARG_H), a

    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c

    call BASIC_SPRITE_SLOT_IMG_ADDR         ; HL = this slot's image
                                            ; buffer — untouched by the
                                            ; A-register-only loads
                                            ; below, so it survives
                                            ; naturally through to the
                                            ; GFX_SPRITE_CAPTURE call
    ld   a, (SPRITE_ARG_ROW)
    ld   b, a
    ld   a, (SPRITE_ARG_COL)
    ld   c, a
    ld   a, (SPRITE_ARG_W)
    ld   d, a
    ld   a, (SPRITE_ARG_H)
    ld   e, a
    call KTAB_GFX_SPRITE_CAPTURE
    jp   c, .out_of_range

    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_DEFINED
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   (hl), 1
    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_W
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (SPRITE_ARG_W)
    ld   (hl), a
    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_H
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (SPRITE_ARG_H)
    ld   (hl), a
    or   a
    ret

.out_of_range:
    ld   hl, MSG_SPRITE_OUT_OF_RANGE
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_SPRITE_SLOT_FLAG_ADDR
; SPRITE_ARG_SLOT + a given per-slot 1-byte array's base -> that slot's
; own byte address. Shared by GRAB/SHOW/HIDE for all the small per-slot
; flag/coordinate arrays (SPRITE_SLOT_DEFINED/_SHOWN/_W/_H/_ROW/_COL) —
; unlike the image/background buffers (SPRITE_SLOT_BYTES apart, see
; BASIC_SPRITE_SLOT_IMG_ADDR/_BG_ADDR above), these are exactly 1 byte
; apart, so this is a plain HL+slot add, no multiply loop needed.
; In:  A = SPRITE_ARG_SLOT's own value (caller re-reads it fresh —
;      simpler than documenting yet another "destroys A" contract),
;      HL = the array's base address
; Out: HL = that slot's own byte address within the array
; Destroys: none (A unchanged; only HL is written, deliberately, since
;      it's also the output)
; ============================================================================
BASIC_SPRITE_SLOT_FLAG_ADDR:
    push de
    ld   e, a
    ld   d, 0
    add  hl, de
    pop  de
    ret

; ============================================================================
; BASIC_SPRITE_LOAD_WH
; Loads this slot's own w/h (fixed by its last GRAB) into SPRITE_ARG_
; W/H. Shared by SHOW and MOVE — neither re-parses w/h from the
; statement text.
; In:  SPRITE_ARG_SLOT set
; Out: SPRITE_ARG_W/H set
; Destroys: AF, HL
; ============================================================================
BASIC_SPRITE_LOAD_WH:
    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_W
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    ld   (SPRITE_ARG_W), a
    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_H
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    ld   (SPRITE_ARG_H), a
    ret

; ============================================================================
; BASIC_SPRITE_LOAD_OLD_POS
; Loads this slot's CURRENT row/col/w/h (as tracked by its last SHOW/
; MOVE) into SPRITE_ARG_ROW/COL/W/H. Shared first step of both HIDE
; and MOVE — "which rectangle needs its background restored" is the
; same question either way.
; In:  SPRITE_ARG_SLOT set
; Out: SPRITE_ARG_ROW/COL/W/H set to the slot's own tracked position
; Destroys: AF, HL
; ============================================================================
BASIC_SPRITE_LOAD_OLD_POS:
    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_ROW
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    ld   (SPRITE_ARG_ROW), a
    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_COL
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    ld   (SPRITE_ARG_COL), a
    jp   BASIC_SPRITE_LOAD_WH             ; tail call — same w/h load
                                          ; SHOW/MOVE's OWN "new
                                          ; position" step needs, just
                                          ; also needed here for the
                                          ; OLD position's rectangle
                                          ; size

; ============================================================================
; BASIC_SPRITE_RESTORE_BG
; SPRITE_ARG_ROW/COL/W/H must already be set. Draws this slot's saved
; background buffer back over the screen there — the shared "erase"
; step both HIDE and MOVE need.
; In:  SPRITE_ARG_SLOT/ROW/COL/W/H all set
; Out: carry clear on success; carry set on failure (caller's own
;      error path handles that — this never records one itself)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_SPRITE_RESTORE_BG:
    call BASIC_SPRITE_SLOT_BG_ADDR
    ld   a, (SPRITE_ARG_ROW)
    ld   b, a
    ld   a, (SPRITE_ARG_COL)
    ld   c, a
    ld   a, (SPRITE_ARG_W)
    ld   d, a
    ld   a, (SPRITE_ARG_H)
    ld   e, a
    jp   KTAB_GFX_SPRITE_DRAW             ; tail call — carry (and the
                                          ; ret) pass straight through
                                          ; to our own caller

; ============================================================================
; BASIC_SPRITE_CAPTURE_AND_SHOW
; SPRITE_ARG_ROW/COL/W/H must already be set (the target position plus
; this slot's own w/h — BASIC_SPRITE_LOAD_WH). Captures the background
; there, draws the image on top, and updates SPRITE_SLOT_ROW/COL to
; match — the shared "put the sprite here" step both SHOW and MOVE
; need. Does NOT touch SPRITE_SLOT_SHOWN — SHOW sets it, MOVE doesn't
; need to (it only ever runs while already shown).
; In:  SPRITE_ARG_SLOT/ROW/COL/W/H all set
; Out: carry clear on success; carry set on failure (caller's own
;      error path handles that — this never records one itself)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_SPRITE_CAPTURE_AND_SHOW:
    call BASIC_SPRITE_SLOT_BG_ADDR
    ld   a, (SPRITE_ARG_ROW)
    ld   b, a
    ld   a, (SPRITE_ARG_COL)
    ld   c, a
    ld   a, (SPRITE_ARG_W)
    ld   d, a
    ld   a, (SPRITE_ARG_H)
    ld   e, a
    call KTAB_GFX_SPRITE_CAPTURE
    ret  c

    call BASIC_SPRITE_SLOT_IMG_ADDR
    ld   a, (SPRITE_ARG_ROW)
    ld   b, a
    ld   a, (SPRITE_ARG_COL)
    ld   c, a
    ld   a, (SPRITE_ARG_W)
    ld   d, a
    ld   a, (SPRITE_ARG_H)
    ld   e, a
    call KTAB_GFX_SPRITE_DRAW
    ret  c                                ; can't happen (same
                                          ; rectangle GFX_SPRITE_
                                          ; CAPTURE above just
                                          ; accepted) but handled
                                          ; anyway rather than assumed

    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_ROW
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (SPRITE_ARG_ROW)
    ld   (hl), a
    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_COL
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (SPRITE_ARG_COL)
    ld   (hl), a
    or   a
    ret

; ============================================================================
; BASIC_STMT_SPRITE_SHOW
; SPRITE SHOW <slot>,<row>,<col> — see this section's own header above.
; In:  HL = text right after "SHOW"
; Out: carry clear on success; carry set + error already recorded
;      otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_SPRITE_SHOW:
    call BASIC_SPRITE_PARSE_SLOT
    ret  c

    ; REAL BUG FOUND AND FIXED ([stated]-reported, screenshot: spurious
    ; "SYNTAX ERROR" on a perfectly valid "SPRITE SHOW 0,10,i"): after
    ; BASIC_SPRITE_PARSE_SLOT returns, HL holds the live TEXT PARSE
    ; POINTER (positioned right after the slot expression, at the
    ; comma before row) — the exact value BASIC_EXPECT_COMMA_EXPR below
    ; needs to keep parsing from. The DEFINED/SHOWN flag lookups in
    ; between both do `ld hl, <array base>` before calling BASIC_
    ; SPRITE_SLOT_FLAG_ADDR, silently clobbering that parse pointer —
    ; by the time BASIC_EXPECT_COMMA_EXPR ran, HL held a leftover
    ; SPRITE_SLOT_* array address instead of real program text, so it
    ; read whatever data byte happened to be there, almost certainly
    ; not a ",", and raised a spurious SYNTAX ERROR. Exactly this
    ; project's lesson-1 register-survival bug class, and exactly why
    ; the z80sim driver's SCRIPTED stubs didn't catch it — a scripted
    ; call substitutes its own canned output regardless of what HL
    ; actually was at the call site, so the test never noticed HL was
    ; wrong going in. Fix: stash the parse pointer across both flag
    ; checks with push/pop, same pattern already used elsewhere for
    ; exactly this class of problem — MOVE below inherits the same
    ; discipline for the exact same reason.
    push hl
    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_DEFINED
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    or   a
    jp   z, .not_defined_pop

    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_SHOWN
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    or   a
    jp   nz, .already_shown_pop
    pop  hl                              ; restore the real parse
                                         ; pointer before continuing
                                         ; to parse row/col

    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    ld   a, e
    call BASIC_SPRITE_CHECK_ROW
    ret  c
    ld   (SPRITE_ARG_ROW), a

    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    ld   a, e
    call BASIC_SPRITE_CHECK_COL
    ret  c
    ld   (SPRITE_ARG_COL), a

    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c

    call BASIC_SPRITE_LOAD_WH
    call BASIC_SPRITE_CAPTURE_AND_SHOW
    jp   c, .out_of_range

    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_SHOWN
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   (hl), 1
    or   a
    ret

.not_defined_pop:
    pop  hl                              ; keep the stack balanced —
                                         ; error already recorded below
.not_defined:
    ld   hl, MSG_SPRITE_NOT_DEFINED
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret
.already_shown_pop:
    pop  hl
.already_shown:
    ld   hl, MSG_SPRITE_ALREADY_SHOWN
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret
.out_of_range:
    ld   hl, MSG_SPRITE_OUT_OF_RANGE
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_STMT_SPRITE_HIDE
; SPRITE HIDE <slot> — see this section's own header above.
; In:  HL = text right after "HIDE"
; Out: carry clear on success; carry set + error already recorded
;      otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_SPRITE_HIDE:
    call BASIC_SPRITE_PARSE_SLOT
    ret  c

    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c

    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_SHOWN
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    or   a
    jp   z, .not_shown

    call BASIC_SPRITE_LOAD_OLD_POS
    call BASIC_SPRITE_RESTORE_BG
    jp   c, .out_of_range             ; can't happen (SHOW/MOVE already
                                      ; accepted this same rectangle)
                                      ; but handled anyway

    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_SHOWN
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   (hl), 0
    or   a
    ret

.not_shown:
    ld   hl, MSG_SPRITE_NOT_SHOWN
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret
.out_of_range:
    ld   hl, MSG_SPRITE_OUT_OF_RANGE
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

; ============================================================================
; BASIC_STMT_SPRITE_MOVE
; SPRITE MOVE <slot>,<row>,<col> — see this section's own header above
; for the full grammar/design. Refuses (SPRITE NOT SHOWN) if the slot
; isn't currently shown — same rule HIDE uses.
; In:  HL = text right after "MOVE"
; Out: carry clear on success; carry set + error already recorded
;      otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_STMT_SPRITE_MOVE:
    call BASIC_SPRITE_PARSE_SLOT
    ret  c

    ; same register-survival discipline SHOW's own header documents in
    ; detail: HL holds the live parse pointer here, and BASIC_SPRITE_
    ; SLOT_FLAG_ADDR (reached via every helper below) clobbers it, so
    ; it's pushed once, up front, and only popped back once the erase
    ; step is done with it.
    push hl
    ld   a, (SPRITE_ARG_SLOT)
    ld   hl, SPRITE_SLOT_SHOWN
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    or   a
    jp   z, .not_shown_pop

    ; erase: restore the background at this slot's OLD position
    call BASIC_SPRITE_LOAD_OLD_POS
    call BASIC_SPRITE_RESTORE_BG
    jp   c, .out_of_range_pop         ; can't happen (SHOW/MOVE already
                                      ; accepted this exact rectangle)
                                      ; but handled anyway

    pop  hl                              ; restore the real parse
                                         ; pointer — nothing between
                                         ; here and the comma-expr
                                         ; parses below touches it
                                         ; again
    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    ld   a, e
    call BASIC_SPRITE_CHECK_ROW
    ret  c
    ld   (SPRITE_ARG_ROW), a

    call KTAB_BASIC_EXPECT_COMMA_EXPR
    ret  c
    ld   a, e
    call BASIC_SPRITE_CHECK_COL
    ret  c
    ld   (SPRITE_ARG_COL), a

    call KTAB_BASIC_EXPECT_STATEMENT_END
    ret  c

    ; put the sprite down at the new position
    call BASIC_SPRITE_LOAD_WH
    call BASIC_SPRITE_CAPTURE_AND_SHOW
    ret  nc                              ; carry already clear on
                                         ; success — nothing more to do

.out_of_range:
    ld   hl, MSG_SPRITE_OUT_OF_RANGE
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

.not_shown_pop:
    pop  hl                              ; discard the saved parse
                                         ; pointer — error already
                                         ; recorded below, balances the
                                         ; stack
.not_shown:
    ld   hl, MSG_SPRITE_NOT_SHOWN
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret
.out_of_range_pop:
    pop  hl
    jr   .out_of_range

; ============================================================================
; BASIC_SPRITE_HIT
; HIT(slot1,slot2) — 1 if both slots are currently SPRITE_SLOT_SHOWN
; and their rectangles overlap, 0 otherwise. An invalid/out-of-range
; slot number is treated as "not shown" (0), not a runtime error —
; deliberately more forgiving than GRAB/SHOW/HIDE/MOVE's own strict
; range errors, since a collision check is exactly the kind of thing a
; game loop calls every frame and shouldn't need its own bounds check
; first (same reasoning kernel/graphics's own POINT() Y-clamp uses).
; In:  L = slot1 (low byte only, matching BASIC_SPRITE_PARSE_SLOT's
;      own unsigned range check), E = slot2
; Out: HL = 1 (collision) or 0 (no collision / invalid slot(s) / not
;      both shown)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_SPRITE_HIT:
    ld   a, l
    cp   SPRITE_SLOT_MAX
    jp   nc, .no_hit                     ; JP not JR — .no_hit is well
                                         ; outside JR's range from here
                                         ; (project's own recurring
                                         ; JR-range lesson)
    ld   b, a                            ; B = slot1 — survives every
                                         ; BASIC_SPRITE_SLOT_FLAG_ADDR
                                         ; call below (that routine
                                         ; only ever writes HL, per its
                                         ; own contract)
    ld   a, e
    cp   SPRITE_SLOT_MAX
    jp   nc, .no_hit
    ld   c, a                            ; C = slot2

    ld   a, b
    ld   hl, SPRITE_SLOT_SHOWN
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    or   a
    jp   z, .no_hit
    ld   a, c
    ld   hl, SPRITE_SLOT_SHOWN
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    or   a
    jr   z, .no_hit

    ; standard 4-comparison rectangle-overlap test: row1 < row2+h2 AND
    ; row2 < row1+h1 AND col1 < col2+w2 AND col2 < col1+w1. All values
    ; are 0-35 (row/col 0-31, w/h 1-4), so plain 8-bit arithmetic is
    ; safe — no wraparound risk at this range. D is used as a one-shot
    ; accumulator for each "other slot's far edge" sum in turn; it
    ; also survives BASIC_SPRITE_SLOT_FLAG_ADDR calls (same reason B/C
    ; do), so it's safe to compute, then compare against a value
    ; fetched by a LATER call without it being clobbered in between.
    ld   a, c
    ld   hl, SPRITE_SLOT_ROW
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   d, (hl)                         ; D = row2
    ld   a, c
    ld   hl, SPRITE_SLOT_H
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    add  a, d
    ld   d, a                            ; D = row2+h2
    ld   a, b
    ld   hl, SPRITE_SLOT_ROW
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)                         ; A = row1
    cp   d
    jr   nc, .no_hit                     ; row1 >= row2+h2

    ld   a, b
    ld   hl, SPRITE_SLOT_H
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   d, (hl)                         ; D = h1
    ld   a, b
    ld   hl, SPRITE_SLOT_ROW
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    add  a, d
    ld   d, a                            ; D = row1+h1
    ld   a, c
    ld   hl, SPRITE_SLOT_ROW
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)                         ; A = row2
    cp   d
    jr   nc, .no_hit                     ; row2 >= row1+h1

    ld   a, c
    ld   hl, SPRITE_SLOT_COL
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   d, (hl)                         ; D = col2
    ld   a, c
    ld   hl, SPRITE_SLOT_W
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    add  a, d
    ld   d, a                            ; D = col2+w2
    ld   a, b
    ld   hl, SPRITE_SLOT_COL
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)                         ; A = col1
    cp   d
    jr   nc, .no_hit                     ; col1 >= col2+w2

    ld   a, b
    ld   hl, SPRITE_SLOT_W
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   d, (hl)                         ; D = w1
    ld   a, b
    ld   hl, SPRITE_SLOT_COL
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)
    add  a, d
    ld   d, a                            ; D = col1+w1
    ld   a, c
    ld   hl, SPRITE_SLOT_COL
    call BASIC_SPRITE_SLOT_FLAG_ADDR
    ld   a, (hl)                         ; A = col2
    cp   d
    jr   nc, .no_hit                     ; col2 >= col1+w1

    ld   hl, 1
    ret

.no_hit:
    ld   hl, 0
    ret

; ============================================================================
; SPRITE_RAISE_SYNTAX_ERROR
; EXROM-local equivalent of basic/basic.asm's BASIC_RAISE_SYNTAX_ERROR
; (ld hl, MSG_SYNTAX_ERROR / call BASIC_SET_PENDING_ERROR / scf / ret) —
; that routine itself has no KTAB entry (it's a 4-instruction tail, not
; worth a jump-table slot), so this duplicates it locally rather than
; adding one just for these two call sites. MSG_SYNTAX_ERROR is shared
; text (include/checker_keywords.inc, INCLUDEd on both sides), so no
; new string data needed here either.
; ============================================================================
SPRITE_RAISE_SYNTAX_ERROR:
    ld   hl, MSG_SYNTAX_ERROR
    call KTAB_BASIC_SET_PENDING_ERROR
    scf
    ret

; ---- error message text — moved here verbatim from basic/basic.asm
; alongside the code that's their only user (2026-08-22 ROM-shrink
; pass, ahead of Phase 3's array work) ----
MSG_SPRITE_BAD_SLOT:      DB "BAD SPRITE SLOT", 0
MSG_SPRITE_TOO_LARGE:     DB "SPRITE TOO LARGE", 0
MSG_SPRITE_OUT_OF_RANGE:  DB "SPRITE OUT OF RANGE", 0
MSG_SPRITE_NOT_DEFINED:   DB "SPRITE NOT DEFINED", 0
MSG_SPRITE_ALREADY_SHOWN: DB "SPRITE ALREADY SHOWN", 0
MSG_SPRITE_NOT_SHOWN:     DB "SPRITE NOT SHOWN", 0
