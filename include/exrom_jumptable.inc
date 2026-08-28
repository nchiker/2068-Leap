; ============================================================================
; include/exrom_jumptable.inc — fixed-address call table for EXROM->Home calls
;
; WHY THIS EXISTS: rom/exrom_checker.asm is assembled as its OWN,
; SEPARATE sjasmplus invocation (own ORG $C000, own SAVEBIN) — it is
; NOT INCLUDEd into the Home build the way every kernel/* module is
; INCLUDEd into rom/test_basic.asm. sjasmplus has no real linker, so
; the EXROM image has no way to know the real addresses of the Home
; routines it needs to call (MEM_LINE_FIRST, BASIC_PARSE_IDENTIFIER,
; etc.) — those addresses shift every time basic.asm or a kernel
; module is edited, even for changes unrelated to the checker.
;
; THE FIX: a small table of `jp` trampolines at FIXED, hand-reserved
; addresses ($0040 upward — chosen because it's real unused space
; between RST_38's tiny 5-byte body and COLD_START at $0100 in every
; real Home build file; see rom/test_basic.asm) that never moves.
;
; SINGLE SOURCE OF TRUTH (2026-08-18 rework): this file used to be
; edited twice per change — once here (as EQUs) and once, by hand, in
; rom/test_basic.asm's own copy of the same ordered list (as `jp`
; instructions) — nothing checked the two agreed beyond a size
; ASSERT, so a silent reorder between them would have meant EXROM
; calling the wrong routine with no assembler error at all. Fixed by
; making THIS file the only place the entry list is written: the
; KTAB_LIST macro below expands, via KTAB_ENTRY, into a `jp realname`
; sequence when included from the Home side, or into a `ktabname EQU
; KTAB_BASE + 3*n` sequence (auto-numbered by KTAB_INDEX, same order)
; when included from anywhere else. Both sides now derive from one
; list; there is no second copy to drift out of sync.
;
; UNVERIFIED SJASMPLUS SYNTAX — flag this clearly rather than assume
; it: the MACRO/ENDM, IFDEF, and DEFL (redefinable label, used here
; for KTAB_INDEX's running count) forms below are written from
; documented sjasmplus behavior, but this sandbox has no sjasmplus to
; actually assemble them against (see this project's own "verify
; tooling facts, never guess" lesson — applying it to myself here).
; CONFIRM this file actually assembles clean before trusting it for
; anything beyond static review.
;
; STILL NOT FULLY AUTOMATIC: the Home build (rom/test_basic.asm) and
; the EXROM build (rom/exrom_checker.asm) are still two SEPARATE
; compiled binaries, deployed independently (two files handed to
; Fuse, or two real EPROMs) — this file removes the SOURCE-level sync
; risk, not the risk of pairing a freshly-rebuilt rom0.bin with a
; stale rom1.bin (forgot to reassemble/redeploy one side). See
; KTAB_MAGIC below for the runtime check that catches THAT case.
;
; TO ADD/REMOVE/REORDER AN ENTRY: edit ONLY the KTAB_LIST macro body
; below, AND bump KTAB_MAGIC by 1 (its whole job is to change whenever
; this list's shape changes) — nothing else in this file, and nothing
; in either build file, needs touching.
;
; HOME-SIDE USAGE (in rom/test_basic.asm, right after the RST_38
; stub, before `DS $0100 - $, $FF`):
;     DEFINE EXROM_JUMPTABLE_HOME_SIDE
;     INCLUDE "include/exrom_jumptable.inc"
;     ORG  KTAB_BASE
;     KTAB_LIST                            ; expands to 20 `jp`s
;     ASSERT $ <= KTAB_END                 ; catches a KTAB_LIST edit
;                                          ; that changed the entry
;                                          ; COUNT without KTAB_COUNT
;                                          ; being updated to match
;     DB   KTAB_MAGIC                      ; at KTAB_MAGIC_ADDR —
;                                          ; EXROM_VERIFY_KTAB_MAGIC
;                                          ; checks this against its
;                                          ; own build's KTAB_MAGIC
; DEFINE EXROM_JUMPTABLE_HOME_SIDE MUST happen before the INCLUDE, and
; only in the Home build — leave it undefined anywhere else (EXROM's
; own INCLUDE takes the EQU-generating branch below by default).
;
; EXROM-SIDE USAGE (now rom/exrom_build.asm, the real driver — see
; that file's own header; used to be rom/exrom_checker.asm directly
; before SAVE/LOAD's own migration needed to share this table too):
; `INCLUDE` this file (no DEFINE needed), then `KTAB_LIST` once,
; early, to actually generate the KTAB_<name> EQUs — then `call
; KTAB_MEM_LINE_FIRST` etc., exactly like any other external call.
; The fixed address resolves through Home's own `jp` to wherever the
; real routine actually landed this build.
;
; 20 entries x 3 bytes = 60 bytes, +1 byte for KTAB_MAGIC = 61 bytes.
; KTAB_BASE..KTAB_MAGIC_ADDR must stay inside the free $0040-$00FF
; window (never touch RST_38 below it or COLD_START at $0100 above
; it) — see the Home-side ASSERT above.
; ============================================================================

    IFNDEF EXROM_JUMPTABLE_INC
    DEFINE EXROM_JUMPTABLE_INC

KTAB_BASE EQU $0040

    IFDEF EXROM_JUMPTABLE_HOME_SIDE

    MACRO KTAB_ENTRY realname, ktabname
    jp   realname
    ENDM

    ELSE

KTAB_INDEX: DEFL 0

    MACRO KTAB_ENTRY realname, ktabname
ktabname EQU KTAB_BASE + 3*KTAB_INDEX
KTAB_INDEX: DEFL KTAB_INDEX + 1
    ENDM

    ENDIF

; ---- THE list — every entry named twice (real Home routine, then
; this file's own KTAB_ name for it) on one line, in one file, so a
; mismatch between the two is a one-line eyeball check, not a cross-
; file hunt. Order matters (it's what fixes each entry's address) —
; append new entries at the END, never insert in the middle, or every
; entry after the insertion point silently shifts address and every
; existing binary pairing (Home jp table vs already-built EXROM EQUs)
; goes stale until BOTH sides are reassembled together. ----
    MACRO KTAB_LIST
    KTAB_ENTRY MEM_LABEL_TABLE_CLEAR,          KTAB_MEM_LABEL_TABLE_CLEAR
    KTAB_ENTRY MEM_LINE_FIRST,                 KTAB_MEM_LINE_FIRST
    KTAB_ENTRY MEM_LINE_NEXT,                  KTAB_MEM_LINE_NEXT
    KTAB_ENTRY MEM_LABEL_ADD,                  KTAB_MEM_LABEL_ADD
    KTAB_ENTRY MEM_LABEL_LOOKUP,               KTAB_MEM_LABEL_LOOKUP
    KTAB_ENTRY BASIC_PARSE_IDENTIFIER,         KTAB_BASIC_PARSE_IDENTIFIER
    KTAB_ENTRY BASIC_SET_PENDING_ERROR,        KTAB_BASIC_SET_PENDING_ERROR
    KTAB_ENTRY BASIC_EVAL_CONDITION,           KTAB_BASIC_EVAL_CONDITION
    KTAB_ENTRY BASIC_EVAL_EXPR,                KTAB_BASIC_EVAL_EXPR
    KTAB_ENTRY BASIC_EXPECT_COMMA_EXPR,        KTAB_BASIC_EXPECT_COMMA_EXPR
    KTAB_ENTRY BASIC_FIND_STATEMENT_BOUNDARY,  KTAB_BASIC_FIND_STATEMENT_BOUNDARY
    KTAB_ENTRY BASIC_IS_LABEL_DEFINITION,      KTAB_BASIC_IS_LABEL_DEFINITION
    KTAB_ENTRY BASIC_MATCH_ENDIF,              KTAB_BASIC_MATCH_ENDIF
    KTAB_ENTRY BASIC_MATCH_KEYWORD_BOUNDARY,   KTAB_BASIC_MATCH_KEYWORD_BOUNDARY
    KTAB_ENTRY BASIC_PARSE_FOR_HEADER,         KTAB_BASIC_PARSE_FOR_HEADER
    KTAB_ENTRY BASIC_SKIP_SPACES,              KTAB_BASIC_SKIP_SPACES
    KTAB_ENTRY BASIC_VALIDATE_VAR_LETTER,      KTAB_BASIC_VALIDATE_VAR_LETTER
    KTAB_ENTRY BASIC_EXPECT_STATEMENT_END,     KTAB_BASIC_EXPECT_STATEMENT_END
                                        ; appended at the END, per this
                                        ; file's own rule — the checker
                                        ; needs this too (BASIC_CHECK_
                                        ; ASSIGNMENT and siblings, once
                                        ; rolled out, must apply the
                                        ; SAME end-of-statement check
                                        ; real execution does)
    KTAB_ENTRY MATH_MULTIPLY16,                KTAB_MATH_MULTIPLY16
    KTAB_ENTRY MATH_DIVIDE16,                  KTAB_MATH_DIVIDE16
                                        ; appended for SAVE/LOAD's own
                                        ; EXROM migration (rom/exrom_
                                        ; storage.asm) — kernel/storage/
                                        ; storage.asm's ONLY two calls
                                        ; out to a routine that isn't
                                        ; itself, both in the save/load
                                        ; progress-percentage calc; see
                                        ; that file's own header for
                                        ; the STORAGE_MATH_* alias
                                        ; convention this table feeds
    KTAB_ENTRY GFX_CLS,                        KTAB_GFX_CLS
    KTAB_ENTRY GFX_PRINT_STRING,                KTAB_GFX_PRINT_STRING
    KTAB_ENTRY BASIC_WAIT_FOR_KEY,              KTAB_BASIC_WAIT_FOR_KEY
    KTAB_ENTRY BASIC_RESET_ROW_SHADOW,          KTAB_BASIC_RESET_ROW_SHADOW
    KTAB_ENTRY BASIC_MATCH_KEYWORD,             KTAB_BASIC_MATCH_KEYWORD
                                        ; appended for HELP's own EXROM
                                        ; migration (rom/exrom_help.asm)
                                        ; — the five Home routines
                                        ; BASIC_SHOW_HELP's body calls
                                        ; out to (screen clear, string
                                        ; print, key-wait, row-shadow
                                        ; reset, and the topic-name
                                        ; keyword match)
    KTAB_ENTRY CALC_EXIT_TRAMPOLINE,            KTAB_CALC_EXIT_TRAMPOLINE
                                        ; appended for the calculator
                                        ; engine's own EXROM migration
                                        ; (rom/exrom_calc.asm) — CALC_
                                        ; OP_END_CALC's tail-jump target
                                        ; (basic/basic.asm). A direct
                                        ; `jp CALC_EXIT_TRAMPOLINE` from
                                        ; exrom_calc.asm FAILED TO
                                        ; ASSEMBLE ("Label not found") —
                                        ; caught by [stated] running the
                                        ; real sjasmplus this sandbox
                                        ; doesn't have — because EXROM
                                        ; and Home are separate
                                        ; compilation units, exactly the
                                        ; problem this whole file exists
                                        ; to solve (see this file's own
                                        ; header); missed applying that
                                        ; existing pattern to the new
                                        ; file, fixed here instead of
                                        ; inventing a workaround
    KTAB_ENTRY BASIC_APPEND_STR,                KTAB_BASIC_APPEND_STR
    KTAB_ENTRY BASIC_NUM_TO_STRING,             KTAB_BASIC_NUM_TO_STRING
                                        ; appended for BASIC_FORMAT_
                                        ; STORAGE_STATUS's own EXROM
                                        ; migration (rom/exrom_storage.
                                        ; asm, 2026-08-22 — a ROM-size
                                        ; audit candidate: cold path,
                                        ; only called while an actual
                                        ; SAVE/LOAD is in progress or
                                        ; just finished) — the two Home
                                        ; routines that routine's own
                                        ; message-building body calls
    KTAB_ENTRY BASIC_DETECT_STRVAR,             KTAB_BASIC_DETECT_STRVAR
    KTAB_ENTRY BASIC_EVAL_STR_EXPR,             KTAB_BASIC_EVAL_STR_EXPR
                                        ; retargeted from BASIC_EVAL_
                                        ; STR_PRIMARY to BASIC_EVAL_STR_
                                        ; EXPR (2026-08-22, Phase 3's
                                        ; concatenation slice) — same
                                        ; slot, so this needed no
                                        ; KTAB_COUNT/KTAB_MAGIC bump;
                                        ; the checker's own BASIC_CHECK_
                                        ; STR_ASSIGNMENT (rom/exrom_
                                        ; checker.asm) is this entry's
                                        ; only caller, and now validates
                                        ; '+' chains too, for free
                                        ; appended for Phase 3 string
                                        ; scalars (2026-08-22) — rom/
                                        ; exrom_checker.asm's own
                                        ; BASIC_CHECK_STR_ASSIGNMENT and
                                        ; .check_print need both to
                                        ; validate "X$ = ..." and
                                        ; "PRINT X$" grammar; IF's own
                                        ; string comparison needed NO
                                        ; new KTAB entry at all — it
                                        ; already reaches BASIC_EVAL_
                                        ; COMPARISON (which now has its
                                        ; own string path) transitively
                                        ; through the existing KTAB_
                                        ; BASIC_EVAL_CONDITION entry
                                        ; above
    KTAB_ENTRY GFX_SPRITE_CAPTURE,              KTAB_GFX_SPRITE_CAPTURE
    KTAB_ENTRY GFX_SPRITE_DRAW,                 KTAB_GFX_SPRITE_DRAW
                                        ; appended for the SPRITE ROM-
                                        ; shrink pass (2026-08-22) —
                                        ; rom/exrom_sprite.asm's own
                                        ; BASIC_STMT_SPRITE_GRAB/SHOW/
                                        ; HIDE (moved from basic/
                                        ; basic.asm whole) are the only
                                        ; callers; every OTHER Home
                                        ; primitive that move needed
                                        ; (BASIC_SKIP_SPACES, BASIC_
                                        ; MATCH_KEYWORD_BOUNDARY,
                                        ; BASIC_EVAL_EXPR, BASIC_
                                        ; EXPECT_COMMA_EXPR/STATEMENT_
                                        ; END, BASIC_SET_PENDING_ERROR)
                                        ; was already in this table for
                                        ; other reasons
    KTAB_ENTRY IO_READ_KEY_NONBLOCK,            KTAB_IO_READ_KEY_NONBLOCK
                                        ; appended for the string-
                                        ; functions ROM-shrink pass
                                        ; (2026-08-22) — rom/exrom_
                                        ; strfuncs.asm's own INKEY$
                                        ; body (upgraded to return a
                                        ; real string) needs it; the
                                        ; original integer-only INKEY$
                                        ; called this directly since it
                                        ; was Home-resident, no KTAB
                                        ; needed at the time
    KTAB_ENTRY GFX_INVERT_ATTR,                 KTAB_GFX_INVERT_ATTR
    KTAB_ENTRY IO_READ_KEY,                     KTAB_IO_READ_KEY
    KTAB_ENTRY MEM_FILL_ZERO,                   KTAB_MEM_FILL_ZERO
    KTAB_ENTRY MEM_SHIFT_UP,                    KTAB_MEM_SHIFT_UP
    KTAB_ENTRY MEM_SHIFT_DOWN,                  KTAB_MEM_SHIFT_DOWN
    KTAB_ENTRY MEM_LINE_DELETE_RANGE,           KTAB_MEM_LINE_DELETE_RANGE
                                        ; appended for kernel/editor's
                                        ; own EXROM migration (rom/
                                        ; exrom_editor.asm, 2026-08-22) —
                                        ; the six external Home
                                        ; routines the editor's body
                                        ; calls (blocking key read,
                                        ; cursor-block redraw, and four
                                        ; kernel/memory primitives for
                                        ; insert/delete/init); GFX_CLS/
                                        ; GFX_PRINT_STRING were already
                                        ; in this table for other
                                        ; reasons
    KTAB_ENTRY BASIC_TRY_EVAL_STR_FUNCTION,     KTAB_BASIC_TRY_EVAL_STR_FUNCTION
    KTAB_ENTRY BASIC_EVAL_STR_FUNCTION_CALL,    KTAB_BASIC_EVAL_STR_FUNCTION_CALL
                                        ; appended (2026-08-22) — a
                                        ; real bug found empirically:
                                        ; rom/exrom_checker.asm's own
                                        ; .check_print never learned
                                        ; about string-function-call
                                        ; syntax when it was added,
                                        ; only quote-literals and bare
                                        ; string variables, so "PRINT
                                        ; UPPER$(A$)" failed the whole-
                                        ; program check with a SYNTAX
                                        ; ERROR despite executing fine.
                                        ; IF's own string comparison
                                        ; needed no new entry (already
                                        ; reaches the real, already-
                                        ; fixed BASIC_EVAL_COMPARISON
                                        ; transitively via KTAB_BASIC_
                                        ; EVAL_CONDITION above), but
                                        ; PRINT's checker path is its
                                        ; own separate, narrower
                                        ; routine that needed the same
                                        ; fix applied directly.
    KTAB_ENTRY BASIC_ARRAY_FIND,                KTAB_BASIC_ARRAY_FIND
                                        ; appended for DIM/DIMN's own
                                        ; EXROM migration (rom/exrom_
                                        ; arrays.asm, 2026-08-22,
                                        ; multi-dimensional arrays) —
                                        ; the one array-mechanics call
                                        ; both need that stays Home-
                                        ; resident itself (read/write
                                        ; stay Home-side too, hot-path,
                                        ; unlike DIM/DIMN which are
                                        ; both cold — see rom/exrom_
                                        ; arrays.asm's own header)
    KTAB_ENTRY BASIC_TRY_DETECT_ONE,            KTAB_BASIC_TRY_DETECT_ONE
    KTAB_ENTRY BASIC_TRY_DETECT_ENDIF,          KTAB_BASIC_TRY_DETECT_ENDIF
                                        ; appended for the multi-keyword
                                        ; bold-highlighting scan's own
                                        ; EXROM migration (rom/exrom_
                                        ; highlight.asm, 2026-08-23) —
                                        ; BASIC_SKIP_SPACES was already
                                        ; in this table for other
                                        ; reasons; these two single-
                                        ; keyword matchers are the only
                                        ; Home calls the table walk
                                        ; needs. KEYWORD_HILITE_TABLE
                                        ; itself is a real assembler
                                        ; label in basic/basic.asm's own
                                        ; build, with no address EXROM
                                        ; (a SEPARATE compilation unit)
                                        ; can see directly — same "Label
                                        ; not found" trap CALC_EXIT_
                                        ; TRAMPOLINE's own KTAB entry
                                        ; comment already documents —
                                        ; so BASIC_DETECT_KEYWORD_PREFIX
                                        ; (the Home-side wrapper) stashes
                                        ; the table's real address into
                                        ; HILITE_TABLE_PTR (a plain RAM
                                        ; sysvar, readable from EXROM
                                        ; like any other) on every call,
                                        ; and the EXROM-side table walk
                                        ; starts from THAT instead
    KTAB_ENTRY BASIC_INPUT_SERVICE,             KTAB_BASIC_INPUT_SERVICE
                                        ; one selector-dispatched gateway
                                        ; for INPUT's EXROM migration;
                                        ; avoids five fixed KTAB entries
    ENDM

KTAB_COUNT      EQU 45
KTAB_END        EQU KTAB_BASE + 3*KTAB_COUNT   ; must be <= $0100
KTAB_MAGIC_ADDR EQU KTAB_END                    ; where Home stamps
                                                ; KTAB_MAGIC — see
                                                ; EXROM_VERIFY_KTAB_
                                                ; MAGIC (rom/exrom_
                                                ; checker.asm)
KTAB_MAGIC      EQU 15  ; bump by 1 any time KTAB_LIST's entry COUNT
                        ; or ORDER, or shared low-ROM ABI changes — its
                        ; job is to change when paired-image contracts
                        ; change, so a stale
                        ; binary pairing gets caught at runtime; the
                        ; exact value carries no other meaning

    ENDIF
