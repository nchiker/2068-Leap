; ============================================================================
; rom/exrom_highlight.asm — multi-keyword bold-highlighting scan, EXROM
;
; Moved here whole (2026-08-23), cut from basic/basic.asm's own
; BASIC_DETECT_KEYWORD_PREFIX/BASIC_FIND_DISPLAY_STMT_BOUNDARY, once
; extending BASIC_DETECT_KEYWORD_PREFIX to bold every colon-separated
; segment's own leading keyword (not just the line's very first word —
; see docs/programmers_reference.md's own writeup for the full
; feature) landed at ~159 bytes of new Home ROM cost and left the
; plain interactive build's own margin (40 bytes free) too thin for
; the preload test harness (tools/preload_gen.py) to still fit
; alongside it — confirmed by a real build overflow, not guessed.
; Same "cold-ish, move it whole" pattern SAVE/LOAD/HELP/the editor/
; SPRITE/SOUND/DIMN already used before this.
;
; A first draft of this move kept the actual KEYWORD_HILITE_TABLE walk
; Home-resident (calling back into Home once per line segment instead)
; specifically to dodge the fact that EXROM, a SEPARATE compilation
; unit, can't reference that table's address as a compile-time label
; (the same "Label not found" trap CALC_EXIT_TRAMPOLINE's own KTAB
; entry hit once — see include/exrom_jumptable.inc). That draft
; assembled fine but didn't free enough Home ROM: several of this
; project's own preload-harness tests (tests/cf2.txt and others) still
; overflowed by up to 42 bytes, confirmed by a real build. Reworked to
; move the table walk here too, using a RUNTIME pointer instead of a
; compile-time label: BASIC_DETECT_KEYWORD_PREFIX (the Home-side
; wrapper, basic/basic.asm) stashes KEYWORD_HILITE_TABLE's own real
; address into HILITE_TABLE_PTR (an ordinary RAM sysvar, readable from
; EXROM like any other data) on every call, right before paging in.
;
; "Cold-ish" rather than truly cold: this runs once per SETTLED
; statement per screen redraw (i.e. on every keystroke, for every
; visible committed line) — much more often than a one-shot statement
; like DIMN, but nowhere near the true per-CHARACTER hot loop
; BASIC_KW_OFFSET_BOLD sits in (which is why THAT one small helper
; stayed Home-resident — see its own header, basic/basic.asm). Given
; the editing session already keeps EXROM paged in for its whole
; duration (BASIC_EDITOR_ENTER_EXROM), every call in here is a cheap
; BANK_EXROM_DEPTH counter bump, not a real port write.
;
; HOW THIS CALLS BACK INTO HOME: BASIC_SKIP_SPACES/BASIC_TRY_DETECT_
; ONE/BASIC_TRY_DETECT_ENDIF (all Home-resident — BASIC_SKIP_SPACES in
; particular is used pervasively throughout basic.asm's own parser and
; can't move) go through the fixed KTAB_* jump table (include/
; exrom_jumptable.inc), same reasoning as every other EXROM file.
; KEYWORD_HILITE_TABLE and KW_REM stay reachable as plain DATA reads
; via HILITE_TABLE_PTR / a direct address respectively — paging only
; affects CODE fetches from chunk 6's own $C000-$DFFF range, never
; reads of Home addresses, which are always mapped regardless (same
; rule this project has relied on since the checker's own first
; migration). The HILITE_* sysvars this file reads/writes are ordinary
; Home RAM for the same reason — no special handling needed.
;
; ENTRY POINT: $C090 — EXROM_ENTRY_DETECT_KEYWORDS, declared alongside
; this project's other fixed entry stubs in rom/exrom_checker.asm (see
; that file's own header for why every stub lives together there
; regardless of which file supplies the real body). This file supplies
; only BASIC_DETECT_KEYWORD_PREFIX_EXROM_BODY, the stub's forward
; reference target.
;
; Home-side caller: basic/basic.asm's BASIC_DETECT_KEYWORD_PREFIX,
; now a thin wrapper (stash the table pointer, page in / call $C090 /
; page out) — same overall shape as every other "_EXROM" wrapper in
; that file. Its own single caller (BASIC_PRINT_LINE_WRAPPED_COMMON)
; needed no changes at all: the contract (In: HL = line text; Out:
; HILITE_KW_COUNT/START/SPANLEN populated) is identical to what it was
; before this move, and the wrapper keeps the exact same name.
; ============================================================================

; ============================================================================
; BASIC_DETECT_KEYWORD_PREFIX_EXROM_BODY
; Walks the WHOLE line at HL, one colon-separated segment at a time,
; and tries KEYWORD_HILITE_TABLE (plus the compound "END IF") against
; each segment's own leading word — recording every match as a
; (start, length) span in HILITE_KW_START/HILITE_KW_SPANLEN. This is
; what lets "INK 7:PAPER 5" bold both INK and PAPER, and "IF x THEN y"
; bold both IF and THEN (now that THEN is in KEYWORD_HILITE_TABLE —
; see that table's own header, basic/basic.asm).
;
; Segment boundaries reuse BASIC_FIND_DISPLAY_STMT_BOUNDARY (below) —
; the same quote-aware, REM-aware colon scan BASIC_FIND_STATEMENT_
; BOUNDARY (basic/basic.asm) already does for the EXECUTION side,
; adapted for this routine's own NUL-terminated display buffers
; (EDIT_LINE_BUF/DETOK_BUF) instead of stored, $0D-terminated
; statement text.
;
; In:  HL = text pointer (start of the whole line — same value already
;      stashed in HILITE_LINE_BASE by the Home-side caller, read back
;      here to compute each match's offset). HILITE_TABLE_PTR must
;      already hold KEYWORD_HILITE_TABLE's real address (the Home-side
;      wrapper sets this on every call, before paging in).
; Out: HILITE_KW_COUNT/HILITE_KW_START/HILITE_KW_SPANLEN populated
;      (COUNT may be 0, meaning nothing on this line bolds at all —
;      e.g. a bare assignment like "x=5")
; Destroys: AF, BC, DE, HL, IX
; ============================================================================
BASIC_DETECT_KEYWORD_PREFIX_EXROM_BODY:
    xor  a
    ld   (HILITE_KW_COUNT), a

.segment_loop:
    call KTAB_BASIC_SKIP_SPACES          ; HL = this segment's first
                                         ; non-space character
    push hl                              ; kept across .try_match_here
                                         ; below (which is free to
                                         ; destroy HL) — this exact
                                         ; position is also where the
                                         ; boundary scan for THIS
                                         ; segment must start
    call .try_match_here
    pop  hl

    call BASIC_FIND_DISPLAY_STMT_BOUNDARY  ; DE = boundary pos, A =
                                           ; boundary char (':' or 0)
    cp   ":"
    ret  nz                               ; NUL terminator — whole
                                          ; line scanned, done

    ex   de, hl
    inc  hl                               ; skip past the ':' itself
    jr   .segment_loop

; ---- .try_match_here: tries END-IF then the table at HL (already
; positioned past leading spaces); records a span if either matches.
; Does not need to preserve HL for its caller — .segment_loop keeps
; its own copy on the stack across this call. ----
.try_match_here:
    push hl
    call KTAB_BASIC_TRY_DETECT_ENDIF     ; compound "END IF" — must be
                                        ; tried before the table below,
                                        ; which has no entry for it
    jr   nc, .record

    ; REAL BUG FOUND AND FIXED HERE (2026-08-23, user-reported:
    ; keywords were being uppercased at commit time correctly but never
    ; rendered bold). Root cause: this used to load HILITE_TABLE_PTR
    ; via `ld hl,(HILITE_TABLE_PTR) / push hl / pop ix`, in the mistaken
    ; belief that `LD IX,(nn)` isn't a real Z80 instruction — it is
    ; (confirmed directly against sjasmplus). The HL-relay version
    ; clobbered HL, which at this exact point still held the live TEXT
    ; SCAN POSITION (the match-start position, saved on the stack by
    ; .try_match_here's own caller, but this instruction sequence ran
    ; BEFORE that value was needed again by KTAB_BASIC_TRY_DETECT_ONE
    ; below, which needs HL = text pointer as its own input) — so every
    ; table-walk attempt below ran against garbage text (whatever
    ; HILITE_TABLE_PTR's own address's contents happened to look like
    ; as "text"), never the real line, and never matched anything.
    ; `LD IX,(nn)` loads directly from memory with no HL involved at
    ; all, sidestepping this entirely.
    ld   ix, (HILITE_TABLE_PTR)
.tbl_loop:
    ld   e, (ix+0)
    ld   d, (ix+1)                        ; DE = this entry's keyword
                                          ; reference pointer
    ld   a, d
    or   e
    jr   z, .no_match_here                 ; 0,0 = end-of-table sentinel

    push ix                                ; preserve table position
                                          ; across the call
    call KTAB_BASIC_TRY_DETECT_ONE
    pop  ix
    jr   nc, .record                         ; matched — HILITE_KW_LEN
                                            ; already set

    inc  ix
    inc  ix                                  ; advance to next entry
    jr   .tbl_loop

.no_match_here:
    pop  hl                              ; discard the saved match-
                                         ; start position, balance the
                                         ; stack — nothing to record
    ret

.record:
    pop  hl                              ; HL = this match's own start
                                         ; position (offset basis)
    ld   de, (HILITE_LINE_BASE)
    or   a
    sbc  hl, de                           ; HL = offset from line base
                                         ; (L only — always < 128)
    ld   b, l                             ; B = offset, stashed across
                                         ; the slot bookkeeping below

    ld   a, (HILITE_KW_COUNT)
    cp   HILITE_KW_MAX_SPANS
    ret  nc                               ; table already full — this
                                          ; match just goes unbolded

    ld   c, a                             ; C = this match's slot index
    ld   hl, HILITE_KW_START
    ld   e, c
    ld   d, 0
    add  hl, de
    ld   (hl), b                          ; store start offset

    ld   hl, HILITE_KW_SPANLEN
    add  hl, de
    ld   a, (HILITE_KW_LEN)
    ld   (hl), a                          ; store span length

    ld   a, c
    inc  a
    ld   (HILITE_KW_COUNT), a
    ret

; ============================================================================
; BASIC_FIND_DISPLAY_STMT_BOUNDARY
; Same job as BASIC_FIND_STATEMENT_BOUNDARY (the colon-splitter used at
; execution time, basic/basic.asm) but for the highlighter's own
; NUL-terminated display buffers instead of stored, $0D-terminated
; statement text — a separate small routine rather than parameterizing
; the original, since that one's REM pre-check (BASIC_MATCH_KEYWORD_
; BOUNDARY) is itself hardwired to $0D too, and touching either risks
; the execution path this project already relies on everywhere. REM
; detection here reuses BASIC_TRY_DETECT_ONE instead (the same case-
; insensitive, space/'='/NUL-boundary matcher this file's own keyword
; matching already uses on this exact kind of buffer).
; In:  HL = scan start (already past any leading spaces — the same
;      position BASIC_DETECT_KEYWORD_PREFIX_EXROM_BODY just tried a
;      keyword match against)
; Out: DE = boundary position (pointing AT the ':' or the NUL
;      terminator, never past it); A = the boundary character found
;      (':' or 0)
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_FIND_DISPLAY_STMT_BOUNDARY:
    push hl
    ld   de, KW_REM
    call KTAB_BASIC_TRY_DETECT_ONE
    pop  hl
    jr   c, .not_rem

    ; whole rest of the line is a comment — scan straight to the NUL
    ; terminator, ignoring any colons entirely
.rem_scan:
    ld   a, (hl)
    or   a
    jr   z, .found_end
    inc  hl
    jr   .rem_scan

.not_rem:
    xor  a
    ld   (BOUNDARY_IN_STRING), a
.scan_loop:
    ld   a, (hl)
    or   a
    jr   z, .found_end
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

.found_end:
    ex   de, hl
    xor  a
    ret
