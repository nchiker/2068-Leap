; ============================================================================
; include/checker_keywords.inc — keyword/message strings shared between
; basic.asm's real dispatch/highlighting and the EXROM checker
;
; WHY THIS EXISTS (2026-08-19): BASIC_CHECK_STATEMENT_CONTENT (moved to
; EXROM — rom/exrom_checker.asm) references these ~33 labels as DATA,
; not as calls (`ld de, KW_PRINT`, `ld hl, MSG_SYNTAX_ERROR`), so they
; can't go through the KTAB jump table (that only resolves code entry
; points). The SAME labels are also used by Home's own real execution
; dispatch (BASIC_EXEC_STATEMENT_CONTENT) and KEYWORD_HILITE_TABLE, so
; they can't move OUT of Home's reach either — Home needs the real
; bytes resident, EXROM needs its own copy resident in its own image.
;
; ORIGINAL APPROACH (superseded): rom/exrom_checker.asm carried a
; hand-duplicated copy of these same `DB "text", 0` lines, kept in
; sync by a dedicated tripwire tool, tools/check_exrom_data_sync.py,
; run after any edit to either copy. That worked but was a permanent
; process burden for something structurally avoidable: THIS file is
; now the single source, INCLUDEd from BOTH basic/basic.asm (in the
; same spot these definitions used to live directly) and rom/exrom_
; checker.asm (replacing its old hand-copy). Two divergent copies are
; no longer possible, so check_exrom_data_sync.py has been retired.
;
; SCOPE: only the keywords/messages the checker's own grammar
; validation actually references. Keywords the checker never sees
; (RUN/HELP/NEW/LIST/EDIT/DELETE/SAVE/LOAD/AND/OR/NOT/STEP, and every
; MSG_* beyond the two below) stay defined directly in basic.asm —
; duplicating those into EXROM's image would cost real EXROM bytes for
; data EXROM never reads, working against the same space-consciousness
; this project applies to Home ROM.
;
; If BASIC_CHECK_STATEMENT_CONTENT ever grows to validate a keyword
; that ISN'T here yet, add it to this file (not to either includer
; directly) — both sides pick it up automatically, no sync step
; needed.
; ============================================================================

    IFNDEF CHECKER_KEYWORDS_INC
    DEFINE CHECKER_KEYWORDS_INC

    INCLUDE "include/shared_lowrom_data.inc"

KW_PRINT: DB "PRINT", 0
KW_END:   DB "END", 0
KW_STOP:  DB "STOP", 0
KW_INPUT: DB "INPUT", 0
KW_GOTO:  DB "GOTO", 0
KW_THEN:    DB "THEN", 0
KW_ELSEIF:  DB "ELSEIF", 0        ; checked BEFORE KW_ELSE everywhere,
                                 ; since "ELSE" is a prefix of "ELSEIF"
                                 ; and BASIC_MATCH_KEYWORD_BOUNDARY
                                 ; would otherwise match "ELSE" against
                                 ; "ELSEIF ..." and leave "IF ..." as
                                 ; unrecognized trailing garbage
KW_ELSE:    DB "ELSE", 0
KW_CLS:     DB "CLS", 0
KW_REM:     DB "REM", 0            ; matches bare "REM" only, same as
                                  ; every other keyword in this project
                                  ; (no optional-letter abbreviation
                                  ; support exists anywhere yet) — see
                                  ; BASIC_STMT_REM's own header
KW_BORDER:  DB "BORDER", 0
KW_INK:     DB "INK", 0
KW_PAPER:   DB "PAPER", 0
KW_FLASH:   DB "FLASH", 0
KW_BRIGHT:  DB "BRIGHT", 0
KW_INVERSE: DB "INVERSE", 0
KW_OVER:    DB "OVER", 0
KW_AT:      DB "AT", 0
KW_TAB:     DB "TAB", 0
KW_PLOT:    DB "PLOT", 0
KW_BEEP:    DB "BEEP", 0
KW_SOUND:   DB "SOUND", 0
KW_DIM:     DB "DIM", 0
KW_LINE:    DB "LINE", 0
KW_CIRCLE:  DB "CIRCLE", 0
KW_FILL:    DB "FILL", 0
KW_MODE:    DB "MODE", 0
KW_ULAPLUS: DB "ULAPLUS", 0
KW_PALETTE: DB "PALETTE", 0
KW_TO:      DB "TO", 0            ; connector keyword within LINE's own
                                 ; grammar (and FOR's own) only, same
                                 ; non-statement-leading role as
                                 ; KW_THEN — deliberately NOT in
                                 ; KEYWORD_HILITE_TABLE, matching
                                 ; THEN/AND/OR/NOT's own precedent
                                 ; there (see that table's header)
KW_FOR:     DB "FOR", 0
KW_NEXT:    DB "NEXT", 0
KW_EXIT:    DB "EXIT", 0          ; only "EXIT FOR" is valid right now —
                                 ; see BASIC_STMT_EXIT's own header for
                                 ; why bare EXIT is deliberately not
                                 ; used for FOR the way bare NEXT is
KW_SPRITE:  DB "SPRITE", 0
KW_GRAB:    DB "GRAB", 0          ; SPRITE GRAB — sub-keyword, same
                                 ; non-statement-leading role as TO/
                                 ; THEN (deliberately not in
                                 ; KEYWORD_HILITE_TABLE either, matching
                                 ; that table's own precedent)
KW_SHOW:    DB "SHOW", 0          ; SPRITE SHOW
KW_HIDE:    DB "HIDE", 0          ; SPRITE HIDE
KW_MOVE:    DB "MOVE", 0          ; SPRITE MOVE (2026-08-23)
KW_POKE:    DB "POKE", 0
KW_PAUSE:   DB "PAUSE", 0
KW_RANDOMISE: DB "RANDOMISE", 0
KW_GOSUB:   DB "GOSUB", 0
KW_RETURN:  DB "RETURN", 0
KW_CALL:    DB "CALL", 0          ; alias for GOSUB — see BASIC_STMT_
                                 ; GOSUB's own header for why CALL
                                 ; shares its exact statement handler
KW_DEF:     DB "DEF", 0
KW_FN:      DB "FN", 0

; ---- error messages (uppercase, null-terminated — read by
; BASIC_REPORT_ERROR on the Home side, never mutated) ----
MSG_LABEL_NOT_FOUND:   DB "LABEL NOT FOUND", 0
; MSG_INVALID_ARGUMENT is fixed shared low-ROM data — STICK
                                 ; (basic/basic.asm) and CHR$ (rom/
                                 ; exrom_strfuncs.asm) both raise it
MSG_RETURN_WITHOUT_GOSUB: DB "RETURN WITHOUT GOSUB", 0
; MSG_ARRAY_NOT_DIMMED is fixed shared low-ROM data — raised
                                 ; from basic.asm's own Home-resident
                                 ; array read/write AND rom/exrom_
                                 ; arrays.asm's DIMN (2026-08-22)

    ENDIF
