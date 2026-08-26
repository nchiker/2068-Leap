; ============================================================================
; rom/exrom_storage.asm — SAVE/LOAD, real-ROM-derived design (2026-08-24)
;
; This file INCLUDEs kernel/storage/storage.asm as-is, the same shape
; as before the 2026-08-24 archive/rewrite — see that file's own header
; for the full protocol design (ported from the real TS2068 ROM's own
; cassette routines) and kernel/storage/archive/README.md for why the
; previous from-scratch protocol was abandoned.
;
; HOW THIS CALLS BACK INTO HOME: kernel/storage/storage.asm's only call
; to a routine that isn't itself is STORAGE_REPORT_PROGRESS's own call
; through STORAGE_PROGRESS_HOOK — a function pointer BASIC sets into
; its own status-bar redraw code, living in Home's chunk 0-1 (basic.asm
; never moves, never paged), so `jp (hl)` to it works whether or not
; chunk 6 currently holds EXROM. All of STORAGE_SAVE/LOAD's own sysvars
; already live in chunk 4 (include/sysvars.inc) — also never paged, so
; no relocation is needed there either. Unlike the previous design,
; this one needs NO KTAB math aliases (STORAGE_MATH_MULTIPLY16/
; DIVIDE16) — the real ROM's own protocol has no percentage math to do
; at all.
;
; ENTRY POINTS: this file contributes NO entry stubs of its own —
; EXROM_ENTRY_SAVE ($C012) and EXROM_ENTRY_LOAD ($C018) live inside
; rom/exrom_checker.asm's own entry-stub block instead; this file just
; supplies the STORAGE_SAVE/STORAGE_LOAD labels they jump to.
;
; Assembled from rom/exrom_build.asm (the real driver), after
; rom/exrom_checker.asm — natural continuation, no ORG needed here.
; ============================================================================

    INCLUDE "kernel/storage/storage.asm"

; ============================================================================
; BASIC_FORMAT_STORAGE_STATUS — moved here from basic/basic.asm
; (2026-08-22, ROM-size audit); message table updated 2026-08-24 for
; the real-ROM-derived design's simpler completion states (no more
; N-blocks-lost count or S=/P=/B=/L= diagnostic fields — the old
; design's own retry/pilot-search sysvars those read from no longer
; exist). Reached via EXROM_ENTRY_FORMAT_STORAGE_STATUS ($C042, rom/
; exrom_checker.asm's own entry-stub block — see that file's own doc
; comment for the reentrancy note: STORAGE_SAVE/LOAD, both EXROM-
; resident, can call this NESTED via STORAGE_PROGRESS_HOOK while EXROM
; is already paged in, which only became safe once kernel/bank/
; bank.asm's BANK_PAGE_EXROM_IN/_OUT gained BANK_EXROM_DEPTH's nesting
; guard).
;
; Builds the message text for the CURRENT STORAGE_OP_STATE into
; STATUS_BUF (null-terminated), for BASIC_DRAW_STATUS_LINE's own
; dispatch to show. Shared between two callers with different needs:
; BASIC_DRAW_STATUS_LINE's own one-shot completion handling (states
; 2/4/5/6, cleared after showing) and — since STORAGE_PROGRESS_HOOK is
; set to point directly at BASIC_DRAW_STATUS_LINE itself, reusing its
; existing "no input, no output" contract and its own .print_status
; flicker-avoidance logic rather than building a separate hook routine
; — the SAME dispatch also handles states 1/3 (SAVING/LOADING in
; progress, NOT cleared, called once at the start of each operation).
;
; Uses the EXROM-local BASIC_APPEND_STR_EXROM formatter
; (include/exrom_jumptable.inc) — the only change from this routine's
; original Home-resident body, everything else moved verbatim, message
; strings included (each used ONLY here, confirmed before moving them
; — no other Home-side caller needed to keep its own copy).
;
; In:  none (reads STORAGE_OP_STATE)
; Out: STATUS_BUF filled and null-terminated
; Destroys: AF, BC, DE, HL
; ============================================================================
BASIC_FORMAT_STORAGE_STATUS:
    ld   hl, STATUS_BUF
    ld   (STATUS_WRITE_PTR), hl
    ld   a, (STORAGE_OP_STATE)
    cp   1
    jp   z, .saving
    cp   2
    jp   z, .saved
    cp   3
    jp   z, .loading
    cp   4
    jp   z, .loaded
    cp   7
    jp   z, .program_found
    ; only 6 remains among the values this is ever called for (the
    ; caller already ruled out 0 before calling)
    ld   hl, MSG_LOAD_FAILED
    jp BASIC_APPEND_STR_EXROM

.saving:
    ld   a, (STORAGE_PROGRESS_PCT)
    or   a
    jr   z, .saving_zero
    ld   hl, MSG_SAVING_TEN
    jp BASIC_APPEND_STR_EXROM
.saving_zero:
    ld   hl, MSG_SAVING_ZERO
    jp BASIC_APPEND_STR_EXROM
.loading:
    ld   hl, MSG_LOADING_ZERO
    jp BASIC_APPEND_STR_EXROM
.saved:
    ld   hl, MSG_SAVED
    jp BASIC_APPEND_STR_EXROM
.loaded:
    ld   hl, MSG_LOADED
    jp BASIC_APPEND_STR_EXROM
.program_found:
    ld   hl, MSG_PROGRAM
    call BASIC_APPEND_STR_EXROM            ; CALL not JP — real work
                                         ; (the filename copy below)
                                         ; still needs to run once this
                                         ; returns; KTAB_BASIC_APPEND_STR
                                         ; is just a fixed-address `jp
                                         ; BASIC_APPEND_STR` trampoline,
                                         ; so its own RET still lands
                                         ; back here same as a direct
                                         ; call would
    ld   hl, STORAGE_HEADER_BUF + STORAGE_HEADER_NAME_OFF
    ld   de, (STATUS_WRITE_PTR)
    ld   b, STORAGE_HEADER_FILENAME_LEN   ; 10 — fixed, space-padded,
                                         ; not null-terminated, so this
                                         ; can't go through BASIC_
                                         ; APPEND_STR's own null-scan
.program_copy:
    ld   a, (hl)
    ld   (de), a
    inc  hl
    inc  de
    djnz .program_copy
    xor  a
    ld   (de), a                          ; null-terminate — "PROGRAM: "
                                         ; (9) + 10 filename bytes = 19,
                                         ; well inside STATUS_BUF's own
                                         ; 28-byte append cap, so no
                                         ; budget check needed here
    ld   (STATUS_WRITE_PTR), de
    ld   hl, MSG_TEN_PCT
    jp BASIC_APPEND_STR_EXROM

MSG_LOAD_FAILED:    DB "LOAD FAILED", 0
MSG_SAVED:          DB "SAVED 100%", 0
MSG_LOADED:         DB "LOADED 100%", 0
MSG_SAVING_ZERO:    DB "SAVING 0%", 0
MSG_SAVING_TEN:     DB "SAVING 10%", 0
MSG_LOADING_ZERO:   DB "LOADING 0%", 0
MSG_PROGRAM:        DB "PROGRAM: ", 0
MSG_TEN_PCT:        DB " 10%", 0
