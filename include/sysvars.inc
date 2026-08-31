; ============================================================================
; sysvars.inc — system variables owned by kernel/memory
;
; Replaces the placeholder addresses kernel/editor/editor.asm originally
; defined for itself before kernel/memory existed (see that file's history
; and docs/programmers_reference.md's suggested-changes notes). All fixed
; RAM addresses used by more than one module go here, not in the module
; that happens to use them first.
;
; ---- $8000+ migration (see docs/memory_map.md for the full writeup) ----
; This entire block used to start at $5D00 — inside the TS2068's dedicated
; 16K video RAM chip pool ($4000-$7FFF), not the general 32K RAM pool
; ($8000-$FFFF). Harmless while only Standard video mode existed, but a
; real conflict once "High Resolution Graphics"/64-Column/Dual-Screen mode
; support was designed (their extra display data occupies the REST of that
; same 16K pool, $6000-$77FF — fixed by the hardware, not relocatable).
; Every address below was shifted by a uniform +$2300 (moving the lowest,
; EDIT_CURSOR_ROW, from $5D00 to exactly $8000) to get this project's own
; RAM out of the video pool entirely and permanently, rather than trying to
; carve out just enough space to dodge one mode's footprint.
;
; Comments below that narrate this project's OWN move-history (e.g.
; PROG_AREA_START's "moved again, from $X to $Y" chain, and any "History:"
; lists) describe events that happened at the OLD pre-migration addresses
; and were NOT rewritten address-by-address — they're accurate as history,
; just not as current values. Trust a specific hex value quoted inside
; prose only if it's on the same line as (or clearly labeled as) the
; CURRENT value; the real current value is whatever the assembler computes
; (see below), not any hex literal typed into a comment.
;
; ---- assembler-computed addresses (2026-08-23) ----
; Every declaration below this point is `NAME: DEFS <size>` (or a bare
; `NAME:` label for PROG_AREA_START, which reserves nothing — it just
; marks where the growable program area begins), not a hand-typed hex
; `EQU`. sjasmplus computes each address itself as a running offset from
; `ORG $8000`, the same way it already computes label addresses in real
; code — this file used to require manually re-deriving and retyping
; every downstream hex address whenever a field's size changed anywhere
; above it (see the many "moved from $X to $Y" History notes still
; scattered below, describing exactly that by-hand process), which is
; this project's own single most error-prone class of change to this
; file. Converted mechanically (address-EQU lines only; the small
; separate set of plain-integer constants like EDIT_LINE_BUF_LEN,
; UDG_COUNT, STRFUNC_ID_* etc. were left untouched, since those were
; already values, not addresses) and verified byte-for-byte identical
; against the prior hand-numbered layout via a `--sym` diff across a
; full basic/test_basic.asm + exrom_build.asm build before being kept —
; every existing address is unchanged, this only changes who computes
; them. `SYSVARS_RETURN_ORG` below captures the includer's real PC
; before this RAM-only, never-SAVEBIN'd $8000+ range is declared, so
; normal ROM assembly can resume exactly where it left off afterward.
;
; Layout within $8000+ is still provisional in the same sense
; docs/memory_map.md already flags — this migration fixes WHICH pool
; everything lives in, not the final internal layout within it.
; ============================================================================

    IFNDEF SYSVARS_INC
    DEFINE SYSVARS_INC

; see this file's own header ("assembler-computed addresses") for why
; everything from here on is DEFS-based instead of hand-typed hex EQUs
SYSVARS_RETURN_ORG EQU $
    ORG $8000

; ---- kernel/editor working storage ----
; The original row/column cursor bytes were write-only after editing became a
; linear-buffer operation. EDIT_BUF_OFFSET is the sole cursor authority now.
EDIT_BUF_OFFSET:     DEFS 2           ; 2 bytes ($5D02-$5D03)
EDIT_LINE_BUF_LEN   EQU 128
; Shared by the interactive editor and runtime string-function pool. Chunk 7
; stays mapped during EXROM editor/string calls; see the upper-RAM assertions
; beside UDG_TABLE for the complete packed layout and stack margin.
EDIT_LINE_BUF        EQU $F228
; A blocking named LOAD may reuse the edit line after parsing its command, but
; its retained filename must not share STATUS_BUF: STORAGE_LOAD invokes the
; progress redraw before header comparison. Keep the semantic alias explicit
; so the cross-subsystem lifetime rule is assembly-checked below.
STORAGE_LOAD_NAME_BUF EQU EDIT_LINE_BUF
    ASSERT STORAGE_LOAD_NAME_BUF != STATUS_BUF

; ---- kernel/memory label table (top-level scope only, for now) ----
; TODO: per-procedure scopes (see docs/basic_language_reference.md,
; "Label table") each need their own table once DEFine PROCedure/
; DEFine FuNction storage exists. Single top-level table is enough to
; get kernel/memory's label routines working before that's built.
; Persistent, but safe in chunk 7: EXROM pages only chunk 6, so label
; lookup/checking can reach this table from every HOME/EXROM call path.
LABEL_TABLE_TOP      EQU $F100
LABEL_TABLE_MAXLEN  EQU 128     ; bytes reserved for the top-level table;
                                ; revisit alongside the memory map's open
                                ; "label table size budget" question

; ---- BASIC program area ----
; Program text (line-length-prefixed statements, no line numbers — see
; docs/basic_language_reference.md) starts here and grows upward.
; PROG_AREA_START — CURRENT VALUE now defined further down (near
; STMT_TARGET_MASK — see this file's own header on why an EQU moves
; instead of getting a second definition). Last moved from
                                ; $9554 to $9555 (1 byte), to make
                                ; room for EXROM_KTAB_MISMATCH_FLAG
                                ; (see that EQU below).
                                ; Before that: moved from $954B to
                                ; $954D (2 bytes), for kernel/storage's
                                ; STORAGE_MAX_LEN (see that EQU
                                ; below). Before that: moved from
                                ; $9504 to $954B (71 bytes), to make
                                ; room for structured FOR/NEXT's own
                                ; FOR_STACK (8 entries * 7 bytes) plus
                                ; FOR_STACK_DEPTH/FOR_TEMP_*/FOR_SCAN_*/
                                ; FOR_ENTRY_PTR/FOR_NEXT_NEWVAL (see
                                ; those EQUs above). Earlier
                                ; history below is accurate as history,
                                ; not current value — see this file's
                                ; own header. Before that: moved from
                                ; $94FE to $9504 (6 bytes), to make
                                ; room for kernel/interrupt's KBD_*
                                ; keyboard-ISR state (see those EQUs
                                ; above) — the real fix for the
                                ; editor's keyboard-lag/lost-keystroke
                                ; bugs. Previously moved from
                                ; $94FD to $94FE (1 byte), for BASIC_
                                ; PRINT_LINE_HIGHLIGHTED/_PLAIN_
                                ; WRAPPED's merge, which needs
                                ; HILITE_PLAIN_MODE to remember which
                                ; entry point was used. Before that:
                                ; $94F6 to $94FD (7 bytes), for the new
                                ; row-height-aware scroll math's own
                                ; SCROLL_OWN_ROWS/ROWS_BEFORE_IDX/
                                ; TOTAL/PTR scratch. Before that: $94F4
                                ; to $94F6 (2 bytes), for BASIC_
                                ; REDRAW_PROGRAM's own STMT_ROW_COUNT/
                                ; IDX scratch (multi-row statement
                                ; iteration). Before that: $94EE to
                                ; $94F4 (6 bytes), for BASIC_PRINT_
                                ; LINE_HIGHLIGHTED's own new
                                ; HILITE_LINE_BASE/WRAP_ROW/
                                ; LINE_START_ROW/ROW_START/ROW_LEN
                                ; scratch (now that it prints multiple
                                ; wrapped rows per call — see that
                                ; routine's own header). Before that:
                                ; $94D8 to $94EE (22 bytes), to make
                                ; room for the word-wrap tables and
                                ; EDITOR_WRAP_CALC's own scratch just
                                ; above (EDIT_WRAP_COUNT/START/LEN,
                                ; WRAP_TEXT_PTR/REMAIN/START_OFS/
                                ; ROW_IDX). Before that: $84D1 to $94D8
                                ; (4103
                                ; bytes), to make room for GFX_FILL's
                                ; own bounded flood-fill stack (see its
                                ; own comment further down — that
                                ; earlier jump was real and deliberate,
                                ; not a mistake: a 2048-entry stack
                                ; sized from actual peak-usage
                                ; measurements in Python, not guessed)
                                ; — zero bytes were free before this
                                ; point (same as every previous move
                                ; in this chain). Earlier history:
                                ; $84CF to $84D1 (2 bytes), for GFX_
                                ; CIRCLE64_XC; $84C5 to $84CF (10
                                ; bytes), for GFX_BLOCK64's own
                                ; scratch; $84B5
                                ; to $84C5 (16 bytes), for GFX_LINE64's
                                ; own scratch; $84B4
                                ; to $84B5 (1 byte), for CURRENT_
                                ; BRIGHT; $84B0 to $84B4 (4 bytes), for
                                ; 64-Column mode's own scratch; $84AF
                                ; to $84B0 (1 byte), for GFX_PALETTE;
                                ; $84AD to $84AF (2 bytes), for GFX_
                                ; MODE/PORT_FF_SHADOW; $61AB to $61AD
                                ; (2 bytes), for CPLOT's own tiny
                                ; scratch. The whole sysvars.inc block,
                                ; this symbol included, was earlier
                                ; shifted by a uniform +$2300 out of
                                ; the video RAM chip pool and into the
                                ; general RAM pool (see this file's own
                                ; header and docs/memory_map.md) —
                                ; $61AD from that point in the chain is
                                ; $84AD today; every other address
                                ; quoted in the history below is
                                ; similarly a pre-migration value, not
                                ; current. Previous history below is
                                ; unchanged; this is simply the next
                                ; entry in it.
                                ; make room for the statement-separator
                                ; feature's working storage
                                ; (BOUNDARY_IN_STRING through
                                ; MULTI_STMT_BUF, 134 bytes total,
                                ; dominated by MULTI_STMT_BUF's own
                                ; 128) — this feature and kernel/
                                ; storage's SAVE/LOAD redesign were
                                ; built in two separate, parallel
                                ; conversations that both started from
                                ; the same shared base and each
                                ; independently claimed the address
                                ; range starting at $60C3 for
                                ; completely different purposes.
                                ; Reconciled here (not a mechanical
                                ; file-diff merge) by keeping
                                ; kernel/storage's entire block at its
                                ; own original addresses ($60C3-$60F4,
                                ; unchanged) and appending the
                                ; statement-separator block immediately
                                ; after, at $60F5 onward — see that
                                ; block's own comment further down.
                                ; Re-verified via grep that every
                                ; reference to this boundary anywhere
                                ; in the codebase still uses this
                                ; symbolic constant, never a hardcoded
                                ; address. Moved with margin ($617B-
                                ; $6182 free, 8 bytes) rather than the
                                ; bare minimum, matching this
                                ; boundary's established habit of
                                ; needing to move again later.
                                ; History: $6030 -> $6090 (screen-
                                ; flicker fix's shadow-state tracking,
                                ; 73 bytes) -> $6098 (text-attribute
                                ; sysvars) -> $60A0 (DELETE_START/END)
                                ; -> $60C8 (EDIT_LABEL_COPY, 32 bytes)
                                ; -> $60DF (STORAGE_HEADER_BUF, 18
                                ; bytes) -> $60E6 (LOAD-side receive
                                ; primitives) -> $60EE (block-based
                                ; protocol rewrite) -> $60F1 (pilot-
                                ; search diagnostics) -> $60F2 (byte-
                                ; reception LAST_SUM) -> $60F3 (MIN_SUM)
                                ; -> $60F4 (CONSECUTIVE_FAILS) -> $60F5
                                ; (STORAGE_LOAD_STAGE) -> $6183
                                ; (statement-separator merge) -> $6184
                                ; (RND_STATE) -> $6198 (pixel graphics:
                                ; PLOT/LINE/POINT) -> $61AB (BLOCK/
                                ; CIRCLE) -> $61AD (this change — CPLOT)
PROG_END:            DEFS 2           ; 2-byte pointer to just past the last byte
                                ; of program text; PROG_END = PROG_AREA_START
                                ; means an empty program. Placed immediately
                                ; after LABEL_TABLE_TOP's reserved span
                                ; ($5D84 + LABEL_TABLE_MAXLEN) — checked for
                                ; overlap, unlike its first draft address.

; ---- kernel/memory internal scratch — NOT part of the public API in
; kernel_api.inc. Used internally by MEM_LABEL_*/MEM_LINE_* to avoid
; fragile register-only threading through multi-step address arithmetic;
; callers of the public routines never touch these directly. Getting
; sizeable (~300 bytes) — a real implementation would likely reuse
; storage between routines that never run concurrently (e.g. STORE_*
; and DELRANGE_* never active at the same time), but that's an
; optimization to revisit once everything here is confirmed correct,
; not before.
LOOKUP_NAME_PTR:     DEFS 2           ; 2 bytes
LOOKUP_NAME_LEN:     DEFS 1           ; 1 byte
LOOKUP_ENTRY_COUNT:  DEFS 2           ; 2 bytes
LABEL_TABLE_USED:    DEFS 2           ; 2 bytes — total bytes used in LABEL_TABLE_TOP
ADD_POSITION:        DEFS 2           ; 2 bytes
REMOVE_ENTRY_START:  DEFS 2           ; 2 bytes
REMOVE_ENTRY_SIZE:   DEFS 1           ; 1 byte
REMOVE_BLOCK_START:  DEFS 2           ; 2 bytes
REMOVE_BLOCK_LEN:    DEFS 2           ; 2 bytes
STORE_POSITION:      DEFS 2           ; 2 bytes
STORE_NEW_PTR:       DEFS 2           ; 2 bytes
STORE_OLD_LEN:       DEFS 2           ; 2 bytes
STORE_NEW_LEN:       DEFS 2           ; 2 bytes
STORE_OLD_TOTAL:     DEFS 2           ; 2 bytes
STORE_NEW_TOTAL:     DEFS 2           ; 2 bytes
STORE_BLOCK_START:   DEFS 2           ; 2 bytes
STORE_BLOCK_LEN:     DEFS 2           ; 2 bytes
DELRANGE_FIRST:      DEFS 2           ; 2 bytes
DELRANGE_LAST_START: DEFS 2           ; 2 bytes
DELRANGE_LAST_LEN:   DEFS 2           ; 2 bytes
DELRANGE_LAST_END:   DEFS 2           ; 2 bytes
DELRANGE_TOTAL_LEN:  DEFS 2           ; 2 bytes
DELRANGE_BLOCK_LEN:  DEFS 2           ; 2 bytes — ends $5E31, clear of
                                 ; PROG_AREA_START ($6000) — verified by
                                 ; computing the full layout with a script
                                 ; rather than by eye, after the PROG_END
                                 ; overlap mistake earlier in this project

; ---- kernel/io working storage ----
IO_SCAN_TABLE:       DEFS 8           ; 8 bytes — one per keyboard matrix row,
                                 ; right after kernel/memory's scratch
                                 ; block ($5E06-$5E31), same "compute it,
                                 ; don't eyeball it" discipline

; ---- kernel/editor internal scratch ----
EDIT_PROGRAM_POS:    DEFS 2           ; 2 bytes — program-area position this
                                 ; edit session belongs to, set by
                                 ; EDITOR_ENTER, read by EDITOR_EXIT
EDIT_CONTENT_LEN:    DEFS 1           ; 1 byte — scratch result of scanning
                                 ; EDIT_LINE_BUF for its null terminator,
                                 ; shared by EDITOR_INSERT_CHAR/DELETE_CHAR/
                                 ; MOVE_CURSOR rather than each re-deriving
                                 ; it inline

; ---- kernel/io working storage, continued ----
; IO_SCAN_TABLE_SHIFTED and IO_RETRY_COUNT used to follow here. The
; interrupt-driven decoder reads modifier state from IO_SCAN_TABLE directly;
; ISR debounce replaced its bounded settle loop, leaving both reservations
; unreferenced. They were removed in the RAM audit.

; ---- basic/ working storage ----
TOKEN_BUF:           DEFS 130         ; 130 bytes — 2-byte length prefix + up
                                 ; to 127 content bytes + $0D terminator,
                                 ; matching EDIT_LINE_BUF's max content
                                 ; (EDIT_LINE_BUF_LEN-1); see
                                 ; basic/basic.asm's BASIC_TOKENIZE_LINE
PRINT_BUF:           DEFS 64          ; 64 bytes (63 chars + null) — scratch
                                 ; for one PRINT string-literal argument
                                 ; before handing it to GFX_PRINT_STRING.
                                 ; Widened from 32 (2026-08-23): a 39-char
                                 ; literal in demos/showcase.txt was
                                 ; silently truncating mid-word — see
                                 ; BASIC_STMT_PRINT's .print_string copy
                                 ; loop in basic/basic.asm. Any literal
                                 ; starting at screen column 0 still only
                                 ; SHOWS up to 32 chars (GFX_CHAR_SETUP's
                                 ; own column-31 bounds check silently
                                 ; clips the rest off-screen, safely) —
                                 ; this widening is about not losing the
                                 ; tail of the string in the buffer
                                 ; itself, for AT-positioned prints and
                                 ; any future use of the captured text
                                 ; beyond just this one draw call.
BASIC_OUTPUT_ROW:    DEFS 1           ; 1 byte — next screen row a PRINT
                                 ; statement writes to; no scrolling yet
; VAR_TABLE (26 fixed 2-byte numeric-scalar slots) lived here through
; Phase 3 — retired in Phase 4 (2026-08-23), moved into the dynamic
; pool alongside arrays (see "Scalar variables in the dynamic pool"
; below). Removing it shifts every sysvar after this point down by 52
; bytes, same as removing anything else in this DEFS-computed chain —
; the assembler re-derives every address, nothing to do by hand.
INPUT_BUF:           DEFS 8           ; 8 bytes — raw digit accumulation for
                                 ; INPUT (sign + up to 5 digits + null),
                                 ; before parsing into a variable
CUR_VAR_LETTER:      DEFS 1           ; 1 byte — which variable letter the
                                 ; current INPUT or assignment statement
                                 ; targets. Stashed in memory rather
                                 ; than a register — originally named
                                 ; INPUT_VAR for just INPUT's use, but
                                 ; BASIC_TRY_ASSIGNMENT needed the exact
                                 ; same pattern for the same reason
                                 ; (BASIC_PARSE_NUMBER clobbers BC
                                 ; internally, so a register can't
                                 ; survive a call to it), so this is
                                 ; shared and renamed to reflect that

; ---- kernel/editor redraw hook ----
EDITOR_REDRAW_HOOK:  DEFS 2           ; 2 bytes — optional custom redraw
                                 ; routine address. 0 (default, set by
                                 ; EDITOR_INIT) means EDITOR_REDRAW_SCREEN
                                 ; uses its own built-in rendering;
                                 ; nonzero means it JPs there instead.
                                 ; Exists so basic/ can own keyword
                                 ; highlighting without kernel/editor
                                 ; needing to know BASIC exists at all —
                                 ; keeps kernel/editor generic and
                                 ; reusable by other future software,
                                 ; per this project's own stated design
                                 ; goal for kernel/* modules.

; ---- basic/ keyword-highlighting state ----
HILITE_KW_LEN:       DEFS 1           ; 1 byte — length of the recognized
                                 ; keyword prefix at the start of
                                 ; whichever line BASIC_PRINT_LINE_
                                 ; HIGHLIGHTED is currently rendering
                                 ; (0 if none), set by
                                 ; BASIC_DETECT_KEYWORD_PREFIX. Also
                                 ; used momentarily by
                                 ; BASIC_UPPERCASE_KEYWORD_PREFIX at
                                 ; commit time (ENTER), which is the
                                 ; only place that MUTATES text — this
                                 ; sysvar itself is just "how many
                                 ; leading chars to bold," read-only
                                 ; everywhere else
HILITE_COL:          DEFS 1           ; 1 byte — column counter used while
                                 ; BASIC_PRINT_LINE_HIGHLIGHTED walks a
                                 ; line
HILITE_ROW:          DEFS 1           ; 1 byte — which row
                                 ; BASIC_PRINT_LINE_HIGHLIGHTED is
                                 ; currently rendering to. Kept in
                                 ; memory, not a register, since
                                 ; GFX_PUTCHAR/GFX_PUTCHAR_BOLD destroy
                                 ; BC entirely on every call within
                                 ; that routine's per-character loop —
                                 ; reloading fresh each iteration is
                                 ; simpler and safer than trying to
                                 ; keep it alive across those calls via
                                 ; push/pop juggling
DETOK_BUF            EQU $F2A8         ; 128 bytes, follows EDIT_LINE_BUF
                                 ; — scratch for converting one stored
                                 ; (tokenized) statement back into a
                                 ; null-terminated display string when
                                 ; the multi-line view redraws it.
                                 ; "Detokenizing" is trivial for this
                                 ; project's tokenizer specifically
                                 ; (no keyword compression — see
                                 ; basic/basic.asm's file header): just
                                 ; copy content bytes up to the $0D
                                 ; terminator. Sized for a full line,
                                 ; not reusing the smaller PRINT_BUF
                                 ; (64 bytes), which would truncate
                                 ; anything longer than a PRINT string
                                 ; literal
BASIC_ACTIVE_ROW:    DEFS 1           ; 1 byte — which screen row the
                                 ; CURRENTLY-EDITED line is on (new
                                 ; uncommitted line, OR an existing
                                 ; statement being edited — see
                                 ; CUR_EDIT_POS) — set by
                                 ; BASIC_REDRAW_PROGRAM each redraw, so
                                 ; the cursor gets drawn on the right row
PROGRAM_ROW:         DEFS 1           ; 1 byte — BASIC_REDRAW_PROGRAM's own
                                 ; row counter while walking the
                                 ; program, kept in memory rather than
                                 ; register B — a real bug (found via a
                                 ; screenshot) showed B getting
                                 ; clobbered by BASIC_PRINT_LINE_
                                 ; HIGHLIGHTED and MEM_LINE_NEXT before
                                 ; the loop's own "inc b" ran, corrupting
                                 ; every row after the first
CUR_EDIT_POS:        DEFS 2           ; 2 bytes — program position of the
                                 ; statement currently being edited, OR
                                 ; the sentinel $FFFF meaning "the new,
                                 ; not-yet-committed line at the end"
CUR_EDIT_INDEX:      DEFS 2           ; 2 bytes — 0-based statement index
                                 ; matching CUR_EDIT_POS (index among
                                 ; existing statements; equals the
                                 ; total statement count when
                                 ; CUR_EDIT_POS is the sentinel) — kept
                                 ; in lockstep as the user navigates,
                                 ; used for scroll-window math
VIEW_TOP_INDEX:      DEFS 2           ; 2 bytes — 0-based statement index
                                 ; shown at screen row 0; scrolling is
                                 ; just changing this and letting the
                                 ; existing full-redraw-every-keypress
                                 ; approach handle the rest — no
                                 ; separate hardware-scroll primitive
                                 ; needed
EDITOR_NAV_HOOK:     DEFS 2           ; 2 bytes — kernel/editor's optional
                                 ; UP/DOWN navigation callback, same
                                 ; pattern as EDITOR_REDRAW_HOOK: 0
                                 ; (default, zeroed by EDITOR_INIT)
                                 ; means EDITOR_LOOP's built-in (no-op)
                                 ; MOVE_CURSOR UP/DOWN handling runs;
                                 ; nonzero means EDITOR_LOOP calls this
                                 ; instead, letting basic/ own what
                                 ; "moving to a different line" means
                                 ; (loading a different statement to
                                 ; edit) without kernel/editor needing
                                 ; to know statements or BASIC exist
; ---- EDIR_* direction constants for EDITOR_MOVE_CURSOR/EDITOR_NAV_
; HOOK (2026-08-22, moved here from kernel/editor/editor.asm when that
; module migrated whole to EXROM — rom/exrom_editor.asm's EDITOR_LOOP
; sets these, basic/basic.asm's BASIC_HANDLE_NAV (the EDITOR_NAV_HOOK
; target) reads them, and since EXROM/Home are separate compilation
; units with no linker, a plain code label wouldn't resolve across
; that boundary the way these compile-time EQU values do from a
; shared include both sides already pull in — same reasoning STRFUNC_
; ID_* already established there). Plain small integers, not
; addresses — belongs alongside EDITOR_NAV_HOOK just above since
; that's the sysvar these values actually flow through. ----
EDIR_UP             EQU 0
EDIR_DOWN           EQU 1
EDIR_LEFT           EQU 2
EDIR_RIGHT          EQU 3
EDIR_HOME           EQU 4       ; start of current line
EDIR_END            EQU 5       ; end of current line
EDIR_TOP            EQU 6       ; top of program
EDIR_BOTTOM         EQU 7       ; bottom of program
; pseudo-directions for EDITOR_NAV_HOOK only — EDITOR_MOVE_CURSOR has
; no meaning for these at all, unlike EDIR_UP/DOWN above (which it
; DOES implement, even though basic/'s hook currently intercepts them
; first). These exist purely to route KEY_INSERT_LINE and an empty-
; buffer KEY_DELETE through the same hook mechanism UP/DOWN already
; use, so kernel/editor never needs to know what "insert a line" or
; "delete this line" actually mean — that's 100% basic/'s concern.
EDIR_DELETE_LINE    EQU 8
EDIR_INSERT_LINE    EQU 9
EDIR_NEXT_ERROR     EQU 10      ; SYMBOL SHIFT+A — same reasoning as
                                ; the two above: routes KEY_NEXT_ERROR
                                ; through the existing hook mechanism,
                                ; "what does jumping to the next error
                                ; mean" is entirely basic/'s concern
EDIR_PREV_ERROR     EQU 11      ; SYMBOL SHIFT+S

NAV_TOTAL:           DEFS 2           ; 2 bytes — total existing statement
                                 ; count, computed fresh by
                                 ; BASIC_HANDLE_NAV each time it runs
                                 ; (via BASIC_COUNT_STATEMENTS) and
                                 ; stashed here since it's needed
                                 ; across several comparisons in that
                                 ; routine
COUNT_TMP:           DEFS 2           ; 2 bytes — BASIC_COUNT_STATEMENTS'
                                 ; running counter, kept in memory
                                 ; rather than a register: both
                                 ; MEM_LINE_FIRST and MEM_LINE_NEXT
                                 ; destroy DE (and MEM_LINE_NEXT
                                 ; destroys BC too), so no register
                                 ; pair can hold a counter across
                                 ; calls to either — a real bug shipped
                                 ; once already from assuming DE would
                                 ; survive
FIND_REMAINING:      DEFS 2           ; 2 bytes — BASIC_FIND_STATEMENT_AT_
                                 ; INDEX's remaining-steps counter,
                                 ; same reason as COUNT_TMP above

; ---- basic/ status line (row 23) ----
; TOKEN_BUF is live only between BASIC_TOKENIZE_LINE and MEM_LINE_STORE.
; Status construction happens during redraw/check/storage, after that copy is
; complete (or before tokenization for an immediate storage command), so this
; transient buffer can safely reuse its first 32 bytes.
STATUS_BUF           EQU TOKEN_BUF
                                 ; text ("LINE n/m" or "NEW LINE")
STATUS_WRITE_PTR:    DEFS 2           ; 2 bytes — current write position
                                 ; within STATUS_BUF while assembling
                                 ; the text from multiple pieces (a
                                 ; prefix, a converted number, "/",
                                 ; another converted number) — kept in
                                 ; memory rather than trusting a
                                 ; register to survive across
                                 ; BASIC_NUM_TO_STRING calls, which
                                 ; destroy DE (same lesson as
                                 ; everywhere else in this project)
STATUS_TOTAL_TMP:    DEFS 2           ; 2 bytes — total statement count,
                                 ; stashed here since it's needed after
                                 ; an intervening BASIC_NUM_TO_STRING
                                 ; call that would otherwise clobber it

; ---- expression evaluation (basic/) ----
EXPR_PARSE_PTR:      DEFS 2           ; 2 bytes — basic/'s current position
                                 ; while evaluating an expression.
                                 ; Genuinely shared across recursion
                                 ; levels (nested parens call the
                                 ; evaluator again) — unlike the
                                 ; kernel/math scratch below, this is
                                 ; NOT reset per-call; it's the single,
                                 ; ongoing position in the source text
                                 ; that every level of recursion reads
                                 ; and advances together, by design

; ---- kernel/math scratch ----
; All of these are pure per-call scratch, safe to share across nested
; calls: each multiply/divide fully consumes and finishes with its own
; value before any other multiply/divide call begins (Z80 execution is
; sequential, and nothing in this project calls one of these while
; another is still mid-calculation) — unlike EXPR_PARSE_PTR above,
; which deliberately IS shared/persistent across recursion.
DIV_DIVIDEND:        DEFS 2           ; 2 bytes — MATH_UDIV16's dividend,
                                 ; shifted left one bit per iteration
DIV_QUOT:            DEFS 2           ; 2 bytes — MATH_UDIV16's quotient
                                 ; accumulator, built up bit by bit
DIV_COUNTER:         DEFS 1           ; 1 byte — MATH_UDIV16's loop counter
                                 ; (16 iterations) — kept in memory
                                 ; since BC is needed for the divisor
                                 ; throughout, unlike DIV10 (a fixed
                                 ; constant) which could use DJNZ/B
MATH_SIGN:           DEFS 1           ; 1 byte — MATH_MULTIPLY16/
                                 ; MATH_DIVIDE16's result-sign scratch
                                 ; (0=positive, $80=negative), shared
                                 ; by both since they're never active
                                 ; simultaneously

; ---- program area ceiling ----
; Was $FF00 (matching main.asm's placeholder stack pointer, "a round
; number, not a considered RAM budget"). Lowered to $C000 (2026-08-18)
; to formally reserve chunk 6 ($C000-$DFFF) for EXROM paging — see
; docs/memory_map.md's chunk-by-chunk audit for why chunk 6 is the
; paging target (general RAM, distant from both live sysvar state and
; the stack; independently corroborated by the stock ROM's own
; EXTINIT routine marking chunk 6 as expendable). The two live-editing
; growth paths (MEM_LINE_INSERT/MEM_LINE_STORE) already checked
; PROG_END against this constant correctly before this change — only
; the value moved, not the check itself. STORAGE_LOAD's own separate
; gap (no length check on incoming tape data at all) was fixed
; first, before lowering this — see STORAGE_MAX_LEN below.
PROG_AREA_MAX        EQU $C000

; ---- labels / GOTO (basic/) ----
GOTO_TARGET:         DEFS 2           ; 2 bytes — set by BASIC_STMT_GOTO on
                                 ; a successful label lookup; checked
                                 ; by BASIC_RUN's loop after every
                                 ; statement to decide whether to jump
                                 ; instead of advancing sequentially.
                                 ; $0000 means "no jump pending" — safe
                                 ; sentinel, since $0000 is never a
                                 ; valid program position
                                 ; (PROG_AREA_START is $6000)
SCAN_STMT_POS:       DEFS 2           ; 2 bytes — BASIC_SCAN_LABELS' own
                                 ; "current statement's position"
                                 ; scratch while walking the program
                                 ; looking for label definitions,
                                 ; memory-backed for the same reason
                                 ; every other program-walking loop in
                                 ; this project uses memory instead of
                                 ; a register: MEM_LINE_NEXT needs the
                                 ; real pointer, and BASIC_PARSE_
                                 ; IDENTIFIER's own use of HL in
                                 ; between would otherwise clobber it

; ---- error reporting (basic/) ----
CUR_EXEC_STMT:       DEFS 2           ; 2 bytes — the statement currently
                                 ; being executed by BASIC_RUN's loop,
                                 ; set fresh at the top of every
                                 ; iteration. Lets BASIC_REPORT_ERROR
                                 ; show which statement failed
                                 ; regardless of how deep in the call
                                 ; chain it's invoked from (GOTO's
                                 ; label lookup, an expression buried
                                 ; inside PRINT or assignment, etc.) —
                                 ; those routines don't otherwise have
                                 ; any way to know which top-level
                                 ; statement they're being called from
PENDING_ERROR_MSG:   DEFS 2           ; 2 bytes — holds a pointer to the
                                 ; error message if one is pending, or
                                 ; $0000 if none. Replaces the earlier
                                 ; 1-byte ERROR_REPORTED flag: the
                                 ; underlying need is the same (a
                                 ; specific error detected deep in the
                                 ; call chain — e.g. DIVISION BY ZERO
                                 ; inside an expression — shouldn't get
                                 ; overwritten by a more generic one
                                 ; from an outer caller), but now the
                                 ; MESSAGE itself is carried here too,
                                 ; not just a boolean, since detecting
                                 ; an error and DISPLAYING it are two
                                 ; separate steps now (see
                                 ; BASIC_SET_PENDING_ERROR and
                                 ; BASIC_RUN's own comments) — real
                                 ; execution displays immediately and
                                 ; halts, same as before, but a future
                                 ; whole-program check pass will reuse
                                 ; the exact same detection logic
                                 ; without displaying anything, just
                                 ; recording each one and continuing.
                                 ; Reset to $0000 by BASIC_RUN at the
                                 ; start of every RUN. Fits exactly in
                                 ; the gap the old 1-byte flag left
                                 ; before ERR_MSG_PTR — no sysvar
                                 ; addresses needed to move
ERR_MSG_PTR:         DEFS 2           ; 2 bytes — BASIC_REPORT_ERROR's own
                                 ; stash for the caller's message
                                 ; pointer. A real bug shipped once
                                 ; already: the caller sets HL to the
                                 ; message before calling, but
                                 ; BASIC_REPORT_ERROR called GFX_CLS
                                 ; (which destroys HL, per its own
                                 ; documented contract) before ever
                                 ; using it — the exact register-
                                 ; survival mistake this project has
                                 ; hit many times before, made again
                                 ; in the very routine meant to help
                                 ; catch this class of thing

IDENT_WRITE_PTR:     DEFS 2           ; 2 bytes — current write position
                                 ; while BASIC_PARSE_IDENTIFIER fills
                                 ; DETOK_BUF (reused as scratch space
                                 ; here — it's already 128 bytes, safe
                                 ; to share since nothing needs it for
                                 ; display at the same time an
                                 ; identifier is being parsed for
                                 ; lookup; a dedicated 32-byte buffer
                                 ; was tried first and found to
                                 ; collide with PROG_AREA_START, since
                                 ; only 14 bytes were actually free at
                                 ; that point in the sysvar range).
                                 ; Kept in memory rather than a
                                 ; register since HL is needed for
                                 ; other things mid-loop here

; ---- whole-program static check pass (basic/) ----
CHECK_ERROR_COUNT:   DEFS 2           ; 2 bytes — how many statements
                                 ; failed BASIC_CHECK_STATEMENT during
                                 ; the most recent BASIC_CHECK_PROGRAM
                                 ; pass
CHECK_FIRST_ERROR_STMT:DEFS 2         ; 2 bytes — position of the FIRST
                                 ; failing statement found — "first"
                                 ; meaning earliest in program order,
                                 ; not necessarily most severe. Used to
                                 ; point BASIC_REPORT_ERROR's row-1
                                 ; display at something concrete when
                                 ; multiple errors exist, rather than
                                 ; an arbitrary or blank statement
CHECK_ERROR_LIST:    DEFS 32          ; 32 bytes — up to 16 statement
                                 ; positions (2 bytes each), every one
                                 ; BASIC_CHECK_PROGRAM found invalid,
                                 ; not just the first. Populated fresh
                                 ; on every check pass, alongside
                                 ; CHECK_ERROR_COUNT/CHECK_FIRST_ERROR_
                                 ; STMT above. 16 is a deliberate cap,
                                 ; not a discovered limit — a hobbyist
                                 ; BASIC program with more than 16
                                 ; simultaneous syntax errors is an
                                 ; extreme edge case; entries beyond
                                 ; the 16th still count toward
                                 ; CHECK_ERROR_COUNT (so "N ERRORS
                                 ; FOUND" stays accurate) but won't get
                                 ; red-highlighted individually. This
                                 ; is what BASIC_REDRAW_PROGRAM checks,
                                 ; via BASIC_IS_ERROR_STATEMENT, to
                                 ; decide whether to render a given
                                 ; line's ink in red
SEARCH_TARGET:       DEFS 2           ; 2 bytes — BASIC_IS_ERROR_STATEMENT's
                                 ; own scratch for the position it's
                                 ; currently searching CHECK_ERROR_LIST
                                 ; for, kept in memory rather than a
                                 ; register since HL is needed to walk
                                 ; the list itself during the search
LINE_IS_ERROR:       DEFS 1           ; 1 byte — BASIC_REDRAW_PROGRAM's own
                                 ; scratch, remembering whether the
                                 ; statement it's currently rendering
                                 ; is in CHECK_ERROR_LIST, across the
                                 ; character-printing step
                                 ; (BASIC_PRINT_LINE_HIGHLIGHTED
                                 ; destroys registers, so this can't
                                 ; live in one) — checked afterward to
                                 ; decide whether to color that row's
                                 ; ink red
WRAP_TARGET:         DEFS 2           ; 2 bytes — BASIC_FIND_PREV_ERROR's
                                 ; own scratch, remembering the last
                                 ; entry in CHECK_ERROR_LIST before its
                                 ; backward scan begins, so it has
                                 ; something to wrap to without
                                 ; recomputing if the scan reaches the
                                 ; start of the list without finding a
                                 ; strictly-earlier entry (e.g. moving
                                 ; "previous" from the very first
                                 ; error wraps around to the last one)

; ---- screen-flicker fix (basic/'s BASIC_REDRAW_PROGRAM) ----
; BASIC_REDRAW_PROGRAM used to do a full GFX_CLS + complete re-render
; on every single keystroke, navigation, or commit — the main source
; of visible flicker. These track what was actually shown at each row
; last time, so a settled row whose content genuinely hasn't changed
; can be skipped entirely (no clear, no redraw) instead of being wiped
; and redrawn identically every time.
ROW_SHADOW_POS:      DEFS 48          ; 48 bytes — 24 rows x 2 bytes each,
                                 ; the statement position shown at
                                 ; that row as of the last redraw, or
                                 ; $FFFF (the same sentinel used
                                 ; elsewhere for "no statement here")
                                 ; if the row was blank/unused. The
                                 ; active (currently-being-edited) row
                                 ; always redraws regardless of this —
                                 ; its content can change on every
                                 ; keystroke — but still gets its
                                 ; shadow entry set to a value that
                                 ; will correctly mismatch once it
                                 ; becomes a settled row later
ROW_SHADOW_FLAGS:    DEFS 24          ; 24 bytes — 1 byte per row,
                                 ; bit 0 = "was this row error-
                                 ; flagged (shown in red) as of the
                                 ; last redraw" — compared alongside
                                 ; ROW_SHADOW_POS, since the same
                                 ; statement could go from unflagged
                                 ; to flagged (or back) between
                                 ; redraws without its position
                                 ; changing at all (e.g. right after
                                 ; RUN finds new errors)
LAST_RENDERED_ROWS:  DEFS 1           ; 1 byte — how many rows were
                                 ; actually used (statement rows plus
                                 ; the active/cursor row) as of the
                                 ; last redraw. If the current redraw
                                 ; uses fewer rows than that (e.g. a
                                 ; statement was just deleted), the
                                 ; rows in between need to be
                                 ; explicitly cleared — nothing else
                                 ; would ever touch them, since the
                                 ; main render loop simply stops once
                                 ; it runs out of statements
LAST_STATUS_TEXT:    DEFS 33          ; 33 bytes (32 chars + null
                                 ; terminator) — the status bar's own
                                 ; piece of the screen-flicker fix.
                                 ; BASIC_DRAW_STATUS_LINE runs on
                                 ; every redraw regardless of whether
                                 ; the status text actually changed;
                                 ; without this, clearing+reprinting+
                                 ; inverting row 23 every single time
                                 ; produced a visible flash even when
                                 ; nothing about it was different —
                                 ; found from the user reporting this
                                 ; exact symptom right after the
                                 ; earlier status-bar toggle fix

; ---- Structured IF/ELSEIF/ELSE/END IF ----
IF_SCAN_POS:         DEFS 2           ; 2 bytes — BASIC_IF_SCAN_STEP/
                                 ; BASIC_RESOLVE_IF_CHAIN/
                                 ; BASIC_SKIP_TO_ENDIF's shared current
                                 ; scan position, same EXPR_PARSE_PTR-
                                 ; style reasoning: MEM_LINE_NEXT and
                                 ; keyword matching both clobber
                                 ; registers freely, so the position
                                 ; that must survive across them lives
                                 ; in memory, reloaded fresh each step,
                                 ; never carried in a bare register
IF_SCAN_DEPTH:       DEFS 1           ; 1 byte — nesting depth while
                                 ; scanning forward past a false IF/
                                 ; ELSEIF condition or past a taken
                                 ; branch's body; only ELSE/ELSEIF seen
                                 ; at depth 0 belong to the block being
                                 ; resolved, not some inner nested IF
IF_TEMP_RESULT:      DEFS 1           ; 1 byte — BASIC_STMT_IF's own
                                 ; condition result (always exactly 0
                                 ; or 1), saved here because matching
                                 ; the following THEN keyword destroys
                                 ; DE, which is where
                                 ; BASIC_EVAL_CONDITION returns it

; ---- Text-attribute state (INK/PAPER/FLASH/INVERSE/OVER) ----
; Persistent current print-attribute state, same idea as BORDER_DEFAULT
; but for text rather than the screen edge: BASIC_STMT_INK/PAPER/FLASH/
; INVERSE/OVER each write one of these, and BASIC_COMPUTE_PRINT_ATTR
; (basic.asm) reads all four attribute-affecting ones together to build
; the byte GFX_PRINT_STRING_ATTR writes per printed character. Kept as
; separate bytes rather than one packed attribute byte because INVERSE
; needs to swap ink/paper at read time, not overwrite them — packing
; now would lose the original (pre-swap) values.
CURRENT_INK:         DEFS 1           ; 1 byte, 0-7, default 0 (black) —
                                 ; only the 6-byte gap's first slot was
                                 ; needed before this batch of 5 new
                                 ; sysvars; the gap is now full, and
                                 ; PROG_AREA_START moves below to make
                                 ; room for the rest
CURRENT_PAPER:       DEFS 1           ; 1 byte, 0-7, default 7 (white) —
                                 ; fits the gap's last free byte
                                 ; ($608E-$608F were the only 2 bytes
                                 ; free before this change)
CURRENT_FLASH:       DEFS 1           ; 1 byte, 0/1, default 0
CURRENT_INVERSE:     DEFS 1           ; 1 byte, 0/1, default 0 — swaps ink/
                                 ; paper when BASIC_COMPUTE_PRINT_ATTR
                                 ; builds the attribute byte, rather
                                 ; than being folded into CURRENT_INK/
                                 ; PAPER directly, so the underlying
                                 ; ink/paper values survive INVERSE
                                 ; being toggled back off later
CURRENT_OVER:        DEFS 1           ; 1 byte, 0/1, default 0 — stored for
                                 ; static-checker validation and consumed
                                 ; by BASIC's PRINT path: OVER 1 XOR-plots
                                 ; glyph pixels onto the existing bitmap.

; ---- AT/TAB cursor positioning ----
BASIC_OUTPUT_COL:    DEFS 1           ; 1 byte, 0-31, default 0 — column
                                 ; companion to BASIC_OUTPUT_ROW
                                 ; ($5EE9, no free byte adjacent to it,
                                 ; hence living here instead). Read by
                                 ; BASIC_STMT_PRINT the same way
                                 ; BASIC_OUTPUT_ROW already is; written
                                 ; by AT <row>,<col> (sets both) and
                                 ; TAB <col> (sets only this), and reset
                                 ; to 0 by BASIC_ADVANCE_OUTPUT_ROW —
                                 ; each new line starts back at the left
                                 ; margin unless positioned again.
                                 ; Fits the 5-byte gap left before
                                 ; PROG_AREA_START by the text-attribute
                                 ; sysvars above ($6093-$6097 were free;
                                 ; 4 bytes remain, $6094-$6097)

; ---- kernel/graphics working storage — NOT part of the public API,
; used internally the same way kernel/memory's own scratch area is ----
PRINT_ATTR_SCRATCH:  DEFS 1           ; 1 byte — GFX_PRINT_STRING_ATTR's own
                                 ; attribute value, carried across its
                                 ; per-character GFX_PUTCHAR/GFX_SET_ATTR
                                 ; calls. REAL BUG FOUND AND FIXED: this
                                 ; was originally a `DB 0` byte embedded
                                 ; directly in kernel/graphics/
                                 ; graphics.asm's CODE (a "self-modifying
                                 ; ROM" pattern) — which silently cannot
                                 ; work, since this entire codebase
                                 ; assembles into ROM, not RAM. Writing
                                 ; to it via `ld (.attr_scratch), a` was
                                 ; a no-op on real hardware (ROM can't be
                                 ; written at runtime), so the routine
                                 ; always read back the DB's compile-
                                 ; time value (0) regardless of what
                                 ; INK/PAPER/FLASH/INVERSE actually said
                                 ; — every PRINT wrote attribute $00
                                 ; (black ink, black paper) to the
                                 ; screen, no matter what color was
                                 ; requested. Found via a real memory
                                 ; dump from the user's own build: attr
                                 ; bytes for printed text were $00 while
                                 ; GFX_CLS's own fill elsewhere on
                                 ; screen was correctly $38, proving
                                 ; only PRINT's OWN attribute write was
                                 ; wrong, not the computation feeding it
                                 ; (CURRENT_INK/PAPER themselves read
                                 ; back correctly as 0/7). Fixed by
                                 ; moving this scratch value to real RAM
                                 ; (here), the same place every other
                                 ; piece of mutable state in this
                                 ; project already lives. Fits the 4-
                                 ; byte gap left before PROG_AREA_START
                                 ; by BASIC_OUTPUT_COL above; 3 bytes
                                 ; remain ($6095-$6097)
PRINT_OVER_SCRATCH:  DEFS 1           ; GFX_PRINT_STRING_ATTR's OVER flag;
                                 ; survives per-character graphics calls

; ---- LIST / EDIT <label> / DELETE <range> ----
DELETE_START:        DEFS 2           ; 2 bytes — BASIC_DO_DELETE's own
                                 ; parsed start index, held here rather
                                 ; than threaded through registers or
                                 ; the stack across the several
                                 ; destructive calls (BASIC_EVAL_EXPR,
                                 ; BASIC_COUNT_STATEMENTS,
                                 ; BASIC_FIND_STATEMENT_AT_INDEX) that
                                 ; come between parsing it and using it
DELETE_END:          DEFS 2           ; 2 bytes — same reasoning, for the
                                 ; parsed end index. Only 3 bytes were
                                 ; free before PROG_AREA_START — not
                                 ; enough for these 4 bytes together,
                                 ; so PROG_AREA_START moves again below

; EDIT and LOAD are recognized before the command-line tokenizer runs. Their
; retained label/filename copy is dead before control can fall through to
; BASIC_TOKENIZE_LINE, so it shares the same command-phase storage too.
EDIT_LABEL_COPY      EQU TOKEN_BUF
                                 ; copy of the parsed label name,
                                 ; capped at 31 chars + null terminator
                                 ; (same silently-truncate convention
                                 ; PRINT_BUF uses, just a smaller cap —
                                 ; a label this long is a much more
                                 ; extreme edge case than a PRINT
                                 ; literal).
                                 ; REAL BUG FOUND AND FIXED: this used
                                 ; to not exist — BASIC_DO_EDIT read
                                 ; the name straight out of DETOK_BUF
                                 ; (a shared scratch buffer reused all
                                 ; over basic/), then called
                                 ; BASIC_SCAN_LABELS, which overwrites
                                 ; DETOK_BUF internally while rescanning
                                 ; the whole program. By the time the
                                 ; lookup ran, DETOK_BUF no longer held
                                 ; the label name at all — every EDIT
                                 ; <label> silently failed. Fixed by
                                 ; copying the name out to its own
                                 ; buffer (here) before ever calling
                                 ; BASIC_SCAN_LABELS. See
                                 ; BASIC_DO_EDIT's own header for the
                                 ; full writeup.

DELETE_INVALID_FLAG: DEFS 1           ; 1 byte, 0/1 — set by the DELETE
                                 ; dispatch when BASIC_DO_DELETE
                                 ; rejects the typed range (malformed
                                 ; number, missing comma, a typed 0,
                                 ; start>end, or out of range); read
                                 ; AND CLEARED by
                                 ; BASIC_DRAW_STATUS_LINE the very next
                                 ; time it runs, so the "INVALID RANGE"
                                 ; message shows exactly once (the
                                 ; first redraw right after the
                                 ; rejection) rather than lingering
                                 ; through the next line the user
                                 ; types.

PENDING_DELETE_POS:  DEFS 2           ; 2 bytes — position of a just-
                                 ; rejected immediate command's text,
                                 ; stored (per the existing "any
                                 ; problem falls through to being
                                 ; tokenized as ordinary text"
                                 ; fallback) but not meant to become a
                                 ; permanent part of the program.
                                 ; $FFFF means "nothing pending" (same
                                 ; sentinel convention BASIC_IS_
                                 ; SENTINEL already uses for
                                 ; CUR_EDIT_POS). Set by the DELETE
                                 ; append path (basic.asm's own
                                 ; ".not_delete" fallback) at the same
                                 ; moment DELETE_INVALID_FLAG is still
                                 ; 1; consumed and cleared by
                                 ; BASIC_HANDLE_NAV the next time the
                                 ; user navigates (UP/DOWN/etc), which
                                 ; silently deletes the pending line
                                 ; before processing whatever
                                 ; navigation was actually requested —
                                 ; user-requested: show the error, let
                                 ; the rejected text stay visible while
                                 ; they read it, then remove it once
                                 ; they move on, so it never becomes
                                 ; a real part of the saved program.
                                 ; Fits the 7-byte gap left before
                                 ; PROG_AREA_START by DELETE_INVALID_
                                 ; FLAG above; 5 bytes remain
                                 ; ($60C3-$60C7)

; ---- shared hardware state: port $FE (ULA) shadow ----
; Last byte written to port $FE (border colour in bits 0-2; MIC in
; bit 3, used by kernel/storage's tape routines; bit 4 unused so
; far). Neither GFX_SET_BORDER nor a bare OUT can read hardware
; state back, so this is the only way either side knows what the
; other last left in the port. Fixes a real gap: GFX_SET_BORDER's
; own comment already promised not to disturb the EAR/MIC bits, but
; until this sysvar existed there was nothing for it to preserve
; them FROM — it just masked its own colour and wrote straight to
; the port, silently zeroing bits 3+ every time. GFX_SET_BORDER and
; STORAGE_PULSE both read-modify-write this byte now instead of
; writing the port blind. Owned here (not kernel/graphics or the
; new kernel/storage) because it's genuinely shared cross-module
; state, per this file's own convention above.
PORT_FE_SHADOW:      DEFS 1           ; 1 byte — fits the 5-byte gap
                                 ; left before PROG_AREA_START by
                                 ; PENDING_DELETE_POS above; 4 bytes
                                 ; remain ($60C4-$60C7)

; ---- kernel/storage — tape SAVE/LOAD, ported from the real TS2068
; ROM's own cassette routines (2026-08-24) ----
; This project's SAVE/LOAD previously used a from-scratch protocol
; (many small checksummed blocks with a bitmap) that kept finding
; genuine real-signal timing bugs with no ground truth to calibrate
; against. Replaced with a direct port of the real ROM's own SA-BYTES/
; LD-BYTES protocol — see kernel/storage/storage.asm's own header for
; the full design writeup and kernel/storage/archive/README.md for why
; the old design was abandoned. The new protocol needs far less state:
; exactly two blocks (header + one data block, no chunking), no bitmap,
; no per-chunk retry bookkeeping.
STORAGE_SEND_LEN:    DEFS 2           ; 2 bytes — STORAGE_SAVE's own
                                 ; scratch: the caller's data length,
                                 ; stashed here while HL/BC get reused
                                 ; building the header (not a live
                                 ; countdown during the actual transfer
                                 ; — STORAGE_SEND_BLOCK/RECEIVE_BLOCK
                                 ; both keep that in the DE register the
                                 ; whole time, matching the real ROM).
STORAGE_CHECKSUM:    DEFS 1           ; 1 byte — header-search retry
                                 ; count scratch for STORAGE_LOAD. The
                                 ; current real-ROM-derived send/receive
                                 ; routines keep their running XOR in H,
                                 ; so this former checksum sysvar is free
                                 ; for that purpose without moving later
                                 ; sysvars.
STORAGE_HEADER_BUF:  DEFS 17          ; Stock TS2068 BASIC header payload:
                                 ; type (1), filename (10, space-padded),
                                 ; data length (2), autostart (2), and
                                 ; program length (2). The tape block's
                                 ; $00 flag and XOR checksum sit outside
                                 ; these 17 bytes.
                                 ; This IS the header block's own
                                 ; payload (STORAGE_SAVE/LOAD pass this
                                 ; straight to STORAGE_SEND_BLOCK/
                                 ; RECEIVE_BLOCK as IX/DE=17 — the
                                 ; receive loop naturally consumes
                                 ; exactly 17+2 bytes total (block flag
                                 ; + 17 real + trailing checksum) on
                                 ; its own from DE=17; no caller-side
                                 ; +1 is needed.
STORAGE_HEADER_FILENAME_LEN EQU 10 ; NOT a sysvar address — a plain
                                 ; protocol constant (the filename
                                 ; field width baked into STORAGE_
                                 ; HEADER_BUF's own 17-byte layout
                                 ; above). basic.asm's own BASIC_DO_
                                 ; LOAD needs this exact number too, to
                                 ; pad a typed filename to the same
                                 ; width STORAGE_LOAD's own header-
                                 ; matching check requires, before ever
                                 ; calling into EXROM — same shared-
                                 ; constant pattern as STORAGE_MAX_LEN
                                 ; below.
STORAGE_PROGRAM_TYPE   EQU 0
STORAGE_EXTENSION_TYPE EQU 4
STORAGE_REQUEST_TYPE: DEFS 1      ; requested header type for SAVE/LOAD
STORAGE_CMD_INVALID_FLAG:DEFS 1          ; 1 byte, 0/1 — SAVE/LOAD command
                                 ; syntax validation, unrelated to the
                                 ; tape protocol itself.
STORAGE_OP_STATE:    DEFS 1           ; 1 byte — what BASIC_DRAW_STATUS_
                                 ; LINE shows: 0=idle (nothing to
                                 ; show), 1=SAVING in progress, 2=save
                                 ; completed OK (one-shot "SAVED"),
                                 ; 3=LOADING in progress, 4=load
                                 ; completed cleanly (one-shot
                                 ; "LOADED"), 5=reserved (the former
                                 ; backup-copy completion state),
                                 ; 6=load failed entirely (one-shot
                                 ; "LOAD FAILED"), 7=matching header
                                 ; found, now receiving the data block
                                 ; ("PROGRAM: <name>", NOT one-shot —
                                 ; see STORAGE_LOAD's own .length_ok),
                                 ; 8=SAVE rejected (one-shot
                                 ; "SAVE FAILED").
                                 ; States 2/4/5/6/8 are one-shot (read-
                                 ; and-cleared by BASIC_DRAW_STATUS_LINE
                                 ; on its next run); states 0/1/3/7 are
                                 ; NOT cleared automatically — the
                                 ; kernel-side SAVE/LOAD routine is what
                                 ; advances out of them, since only it
                                 ; knows when the operation is actually
                                 ; still running vs finished.
STORAGE_PROGRESS_PCT:DEFS 1           ; 1 byte — timing-safe milestone
                                 ; progress: 0 at entry, 10 after the
                                 ; header block, 100 after the data
                                 ; block. Never updated by drawing from
                                 ; inside a pulse-critical block.
; STORAGE_USED_BACKUP was a one-byte compatibility hole left by the removed
; private backup-copy state. Addresses are assembler-derived now, so keeping a
; dead gap no longer serves a compatibility purpose.
STORAGE_ENTRY_RETRY: DEFS 2           ; 2 bytes — STORAGE_RECEIVE_
                                 ; BLOCK's own internal .entry_start
                                 ; retry budget (see STORAGE_ENTRY_
                                 ; RETRY_MAX in kernel/storage/
                                 ; storage.asm for the full reasoning).
                                 ; Bounds a single call's own leader-
                                 ; search loop, which the real ROM
                                 ; leaves genuinely unbounded (fine for
                                 ; a human watching a real tape deck,
                                 ; not for an unattended call) — without
                                 ; this, a call that couldn't re-acquire
                                 ; a leader tone for the data block would
                                 ; spin forever with no way out but a
                                 ; manual BREAK. Counts down once per
                                 ; .entry_start attempt; hitting 0 fails
                                 ; the call cleanly (carry set) instead
                                 ; of retrying again. 2 bytes because a
                                 ; real-world-adequate retry budget
                                 ; (thousands, to tolerate several real
                                 ; seconds of lead-in silence before a
                                 ; leader tone starts) doesn't fit in 1.

STORAGE_PROGRESS_HOOK:DEFS 2           ; 2 bytes — address of a caller-
                                 ; supplied "redraw current status"
                                 ; routine, or 0 for none. Same
                                 ; contract and pattern as kernel/
                                 ; editor's own EDITOR_REDRAW_HOOK: no
                                 ; input, no output, just draws
                                 ; whatever STORAGE_OP_STATE currently
                                 ; says and RETs. Called (not tail-
                                 ; jumped) since STORAGE_SAVE/LOAD need
                                 ; control back afterward — see
                                 ; STORAGE_REPORT_PROGRESS in kernel/
                                 ; storage/storage.asm.

; ---- statement separator (:) ----
; BASIC_FIND_STATEMENT_BOUNDARY/BASIC_EXEC_MULTI_STATEMENT/BASIC_CHECK_
; MULTI_STATEMENT's own working storage. See those routines' own
; headers in basic.asm for the full design (why a whole line is pre-
; split into colon-separated segments, copied one at a time into
; MULTI_STMT_BUF, and fed to the EXISTING, completely unmodified
; BASIC_EXEC_STATEMENT_CONTENT/BASIC_CHECK_STATEMENT_CONTENT as if
; each were its own standalone statement — rather than teaching every
; individual statement handler to track and return an end position).
; Placed right after kernel/storage's own new sysvars above (not
; alongside DELETE_INVALID_FLAG/PENDING_DELETE_POS, where this
; feature was originally built in a separate, parallel conversation)
; — both that work and kernel/storage's SAVE/LOAD redesign started
; from the same shared base and independently claimed the same
; address range; reconciled here by keeping kernel/storage's block at
; its own original addresses and appending this feature's block
; immediately after, rather than interleaving or arbitrarily
; reordering either side.
BOUNDARY_IN_STRING:  DEFS 1           ; 1 byte, 0/1 — BASIC_FIND_
                                 ; STATEMENT_BOUNDARY's own toggle,
                                 ; tracking whether the scan is
                                 ; currently inside a quoted string
                                 ; literal (a ':' inside one is just
                                 ; text, never a real separator)
MULTI_SEG_START:     DEFS 2           ; 2 bytes — current segment's start
                                 ; position, held here (not a
                                 ; register) since BASIC_FIND_
                                 ; STATEMENT_BOUNDARY's own scan
                                 ; destroys HL
MULTI_SEG_END:       DEFS 2           ; 2 bytes — current segment's
                                 ; boundary position (pointing AT the
                                 ; ':' or the terminating $0D),
                                 ; returned by BASIC_FIND_STATEMENT_
                                 ; BOUNDARY and needed again both for
                                 ; the copy-loop's own end check and
                                 ; for computing where the NEXT
                                 ; segment starts afterward
MULTI_SEG_BOUNDARY_CHAR:DEFS 1           ; 1 byte — which character
                                 ; BASIC_FIND_STATEMENT_BOUNDARY
                                 ; actually stopped at (':' or $0D) —
                                 ; needed to decide whether to keep
                                 ; looping for more segments or stop;
                                 ; a register can't survive the
                                 ; segment-dispatch call in between
; Execution/checking only sees statements after MEM_LINE_STORE copied the
; tokenizer output into the dynamic program area. Reuse TOKEN_BUF's full
; 128-byte payload capacity rather than reserving a second line-sized buffer.
MULTI_STMT_BUF       EQU TOKEN_BUF
                                 ; colon-separated segment's own copy,
                                 ; synthetically $0D-terminated so the
                                 ; existing, completely unmodified
                                 ; BASIC_EXEC_STATEMENT_CONTENT/BASIC_
                                 ; CHECK_STATEMENT_CONTENT see exactly
                                 ; the same shape of input a real,
                                 ; whole stored statement always has.
                                 ; Sized to match EDIT_LINE_BUF_LEN —
                                 ; a single segment can never exceed
                                 ; what a person could have typed on
                                 ; one line in the first place

    ASSERT STATUS_BUF == TOKEN_BUF
    ASSERT EDIT_LABEL_COPY == TOKEN_BUF
    ASSERT MULTI_STMT_BUF == TOKEN_BUF
    ASSERT EDIT_LINE_BUF_LEN <= 128

; ---- built-in function calls in expressions (ABS(x), SGN(x), MOD(x,y), ...) ----
FUNC_CALL_HANDLER:   DEFS 2           ; 2-byte handler address from
                                 ; FUNCTION_TABLE. BASIC_EVAL_PRIMARY
                                 ; snapshots it on the Z80 stack before
                                 ; recursively parsing arguments, so a
                                 ; nested function may safely overwrite
                                 ; this shared lookup result.
FUNC_CALL_ARGC:      DEFS 1           ; 1 byte — how many arguments the
                                 ; matched function takes (1 or 2),
                                 ; set alongside FUNC_CALL_HANDLER by the
                                 ; same BASIC_TRY_EVAL_FUNCTION table
                                 ; lookup, read by BASIC_EVAL_PRIMARY's
                                 ; .do_function_call to decide whether
                                 ; to expect ')' or ',' right after the
                                 ; first argument. Added alongside
                                 ; MOD(x,y), this project's first
                                 ; two-argument built-in. Fits the
                                 ; remaining low-RAM gap.

; ---- kernel/math scratch (MATH_SQRT16's own loop state) ----
SQRT_OP:             DEFS 2           ; 2 bytes — MATH_SQRT16's working
                                 ; copy of the input, shrinking each
                                 ; iteration as digits are extracted.
                                 ; Same reasoning as MATH_UDIV16's own
                                 ; DIV_DIVIDEND right above (see that
                                 ; routine): the compare-then-subtract
                                 ; step needs a copy of this value in
                                 ; HL, but HL is also needed for other
                                 ; work in the same iteration, so it's
                                 ; kept here between uses rather than
                                 ; fought for in a register. Fits the
                                 ; 6-byte gap left before
                                 ; PROG_AREA_START by FUNC_CALL_ARGC
                                 ; above; 4 bytes remain ($617F-$6182)
SQRT_RES:            DEFS 2           ; 2 bytes — MATH_SQRT16's
                                 ; result-in-progress (same "needs a
                                 ; copy in HL, but HL is busy"
                                 ; reasoning as SQRT_OP above). Fits
                                 ; the 4-byte gap left before
                                 ; PROG_AREA_START by SQRT_OP above;
                                 ; 2 bytes remain ($6181-$6182)
SQRT_COUNTER:        DEFS 1           ; 1 byte — MATH_SQRT16's loop
                                 ; counter (8 iterations, same
                                 ; DJNZ-can't-reach-it reasoning as
                                 ; MATH_UDIV16's own DIV_COUNTER — 'one'
                                 ; already occupies BC the whole loop,
                                 ; so the usual DJNZ-in-B trick isn't
                                 ; available here). Fits the 2-byte gap
                                 ; left before PROG_AREA_START by
                                 ; SQRT_RES above; 1 byte remains
                                 ; ($6182-$6182)
RND_STATE:           DEFS 2           ; 2 bytes — MATH_RND16's LFSR
                                 ; state, persists across calls (each
                                 ; RND(x) both reads and updates it —
                                 ; a register can't hold this between
                                 ; separate BASIC statements). Never
                                 ; 0 — a maximal-length LFSR treats 0
                                 ; as a degenerate fixed point (stays
                                 ; 0 forever), so BASIC_INIT_RND seeds
                                 ; this from the Z80 R register OR'd
                                 ; with 1 to guarantee nonzero, the
                                 ; first time RND(x) is ever called
                                 ; (checked via "is this still 0" —
                                 ; MEM_INIT zeroes all of RAM at cold
                                 ; start, so 0 doubles as "not yet
                                 ; seeded"). Only 1 byte was free
                                 ; before PROG_AREA_START at this
                                 ; point — PROG_AREA_START moves again
                                 ; below to make room, same established
                                 ; pattern as every earlier move (see
                                 ; PROG_AREA_START's own history
                                 ; comment)

; ---- kernel/graphics pixel-plotting working storage — NOT part of the
; public API, same "internal, not for outside callers" status as
; PRINT_ATTR_SCRATCH above ----
; GFX_PIXEL_* is GFX_PIXEL_ADDR_SETUP's own scratch, shared by
; GFX_WRITE_PIXEL and GFX_READ_PIXEL (both call it) — memory, not bare
; registers, because GFX_WRITE_PIXEL needs the attribute byte and OVER
; flag to survive that computation, and because GFX_PIXEL_ROW/COL are
; read again afterward by GFX_WRITE_PIXEL's own trailing GFX_SET_ATTR
; call, which happens well after the registers used to compute them
; have been reused for the bitmap write itself.
GFX_PIXEL_ROW:       DEFS 1           ; 1 byte — char row (0-23) of the
                                 ; pixel currently being plotted/read
GFX_PIXEL_COL:       DEFS 1           ; 1 byte — char column (0-31), same
GFX_PIXEL_SCANLINE:  DEFS 1           ; 1 byte — scanline within the cell
                                 ; (0-7), used only during address
                                 ; computation, not read again after
GFX_PIXEL_MASK:      DEFS 1           ; 1 byte — bit mask for the target
                                 ; pixel within its byte (bit7 =
                                 ; leftmost, matching this file's font
                                 ; glyph convention)
GFX_PIXEL_ATTR:      DEFS 1           ; 1 byte — GFX_WRITE_PIXEL's own
                                 ; attribute byte parameter, stashed
                                 ; here the moment it's passed in (same
                                 ; reasoning as PRINT_ATTR_SCRATCH: it
                                 ; must survive GFX_PIXEL_ADDR_SETUP,
                                 ; which destroys AF)
GFX_PIXEL_OVER:      DEFS 1           ; 1 byte — GFX_WRITE_PIXEL's own OVER
                                 ; flag parameter (0 = set, nonzero =
                                 ; XOR toggle), same reasoning

; GFX_LINE_* is GFX_LINE's own Bresenham state. Six logical inputs
; (both endpoints, the attribute byte, the OVER flag) plus five working
; values that must all survive a per-pixel loop calling GFX_WRITE_PIXEL
; and MATH_COMPARE16 — both of which destroy registers freely per their
; own contracts — is more live state than Z80's register set holds at
; once, the same "value must survive a destructive call -> memory, not
; a register" reasoning as DELETE_START/DELETE_END and IF_SCAN_POS
; above, just with more values in play than either of those needed.
; BASIC_STMT_LINE fills every one of these in directly before calling
; GFX_LINE, rather than GFX_LINE taking any register parameters at all.
GFX_LINE_X0          EQU EXTENSION_ARG0 ; stable ABI byte; start x
GFX_LINE_Y0          EQU EXTENSION_ARG1 ; stable ABI byte; start y
                                 ; also GFX_LINE's own "current point"
                                 ; while the loop runs, advanced by
                                 ; GFX_LINE_SX/SY each iteration
GFX_LINE_X1          EQU EXTENSION_ARG2 ; stable ABI byte; end x
                                 ; the loop starts (the termination
                                 ; check compares GFX_LINE_X0/Y0
                                 ; against these)
GFX_LINE_Y1          EQU EXTENSION_ARG3 ; stable ABI byte; end y
GFX_LINE_ATTR:       DEFS 1           ; 1 byte — attribute byte, passed
                                 ; through to GFX_WRITE_PIXEL unchanged
                                 ; every iteration
GFX_LINE_OVER:       DEFS 1           ; 1 byte — OVER flag, same
GFX_LINE_DX:         DEFS 1           ; 1 byte — abs(x1-x0), always fits a
                                 ; byte (max 255)
GFX_LINE_DY_ABS:     DEFS 1           ; 1 byte — abs(y1-y0), always fits a
                                 ; byte (max 191); kept as a positive
                                 ; magnitude, unlike the textbook
                                 ; algorithm's own "dy" (which is
                                 ; conventionally already negated) —
                                 ; GFX_LINE negates it itself where the
                                 ; algorithm needs that, via
                                 ; MATH_NEGATE16, rather than storing
                                 ; the negative form here
GFX_LINE_SX:         DEFS 1           ; 1 byte — x step, always exactly +1
                                 ; or -1 (two's complement $01/$FF)
GFX_LINE_SY:         DEFS 1           ; 1 byte — y step, same
GFX_LINE_ERR:        DEFS 2           ; 2 bytes ($6194-$6195) — signed
                                 ; 16-bit Bresenham error accumulator;
                                 ; needs the full 16-bit signed range
                                 ; (roughly -191 to +255, and e2 below
                                 ; doubles that), not just a byte
GFX_LINE_E2:         DEFS 2           ; 2 bytes ($6196-$6197) — this
                                 ; iteration's err*2, computed once and
                                 ; read by BOTH the x-step and y-step
                                 ; decisions (the textbook algorithm
                                 ; itself does this — it is NOT
                                 ; recomputed between them), so it has
                                 ; to survive the first MATH_COMPARE16
                                 ; call (which destroys HL) to be
                                 ; usable by the second

; GFX_CLIP_* — GFX_PLOT_CLIPPED's own scratch. GFX_CIRCLE's computed
; points (center +/- radius) can legitimately land off-screen (negative
; or >255/>191); GFX_PLOT_CLIPPED wraps GFX_WRITE_PIXEL with a bounds
; check rather than letting an out-of-range value get silently
; truncated into a byte and plotted on the wrong edge of the screen.
; Same "value must survive a destructive call" reasoning as everywhere
; else in this block — the bounds check itself needs A as scratch.
GFX_CLIP_ATTR:       DEFS 1           ; 1 byte
GFX_CLIP_OVER:       DEFS 1           ; 1 byte

; GFX_CIRCLE_* — CIRCLE's own working storage, midpoint circle
; algorithm. X/Y are the algorithm's own octant offsets (0..r), always
; bytes; D is the signed 16-bit decision variable. Verified in Python
; against a reference implementation before any Z80 was written,
; including the x=0 pole case (handled once, before the main loop —
; see GFX_CIRCLE_PLOT_POLES) and the x==y diagonal case (the loop's
; "swapped" 4 points are skipped there — see GFX_CIRCLE_PLOT_GENERAL) —
; both verified to be exact-duplicate points, not just visually close,
; so skipping them changes nothing about the rendered circle but does
; matter for OVER 1/XOR correctness (plotting the same pixel twice
; would toggle it back off). That same verification also caught that
; x-y needs real 16-bit width during the decision-variable update
; (observed up to +/-238 across tested radii — well outside an 8-bit
; signed byte's -128..127 range), not the 8-bit SUB an unverified
; implementation would reach for.
GFX_CIRCLE_XC:       DEFS 1           ; 1 byte — center x (0-255)
GFX_CIRCLE_YC:       DEFS 1           ; 1 byte — center y (0-191)
GFX_CIRCLE_R:        DEFS 1           ; 1 byte — radius (0-255; off-screen
                                 ; points from a large radius are
                                 ; clipped by GFX_PLOT_CLIPPED, not
                                 ; rejected here)
GFX_CIRCLE_ATTR:     DEFS 1           ; 1 byte
GFX_CIRCLE_OVER:     DEFS 1           ; 1 byte
GFX_CIRCLE_X:        DEFS 1           ; 1 byte — current octant x offset
GFX_CIRCLE_Y:        DEFS 1           ; 1 byte — current octant y offset
GFX_CIRCLE_D:        DEFS 2           ; 2 bytes ($61A9-$61AA) — signed
                                 ; 16-bit decision variable

; GFX_MODE / PORT_FF_SHADOW — MODE's own state. GFX_MODE is this
; project's own friendly 0/1 numbering (0=Normal, 1=High Resolution
; Graphics), consulted by GFX_WRITE_PIXEL to decide which attribute-
; addressing formula applies — kept separate from the raw hardware
; byte actually written to port $FF (see hardware.inc's PORT_SCLD
; comment for the real values and why they're not used directly as
; this sysvar's own encoding).
; PORT_FF_SHADOW is the read-modify-write shadow GFX_SET_MODE always
; goes through — same established pattern as PORT_FE_SHADOW above
; (that one exists because an earlier version of GFX_SET_BORDER had
; no shadow to preserve EAR/MIC from and silently zeroed them; port
; $FF has even more going on sharing the same byte — INTEN, EXROM/
; cartridge select — so this project isn't repeating that mistake
; here from the start).
GFX_MODE:            DEFS 1          ; 1 byte — 0 or 1, see above
PORT_FF_SHADOW:      DEFS 1          ; 1 byte

; CURRENT_BRIGHT — BRIGHT's own state, same shape as CURRENT_FLASH/
; INVERSE/OVER above (boolean, only bit 0 kept). The attribute byte's
; bit 6 has always existed and been writable — GFX_SET_ATTR/GFX_SET_
; ATTR_EXT never cared which bits their caller set — but nothing ever
; set it, since no statement existed to. BASIC_COMPUTE_PRINT_ATTR now
; reads this the same way it already reads CURRENT_FLASH.
CURRENT_BRIGHT:      DEFS 1          ; 1 byte, 0/1, default 0

; GFX_FILL_* — FILL's own state, incl. its bounded flood-fill stack.
; Deliberately NOT recursive and NOT unbounded — real hardware has no
; call-stack depth to spare, and even an iterative approach needs an
; explicit limit since a large enough enclosed region could otherwise
; grow the stack without bound. 2048 entries (x,y per entry) sized
; from real peak-stack measurements in Python before any Z80 was
; written: a "mark on push" 4-connected fill (using the bitmap itself
; as the already-claimed tracker, via GFX_READ_PIXEL/GFX_WRITE_PIXEL —
; no separate visited-set needed) peaks at ~2069 stack entries for a
; filled circle of radius 50 on this screen, ~768 for radius 30 — a
; genuinely naive "mark on pop" version was measured needing MORE
; stack entries than there are pixels in the fill for a large open
; area, which is why this project didn't ship that simpler-looking
; version. If GFX_FILL_STACK does fill up (a very large enclosed
; region), further expansion from that point silently stops — pixels
; already queued still get processed and colored correctly, but a
; genuinely huge fill may not reach its full extent. No crash, no
; memory corruption — a documented, deliberate limitation.
;
; The stack is transient, so it lives above the persistent BASIC ceiling
; instead of consuming 4K below PROG_AREA_START. Together with the visited
; bitmap at $C000 it occupies $C000-$E7FF only while FILL is executing.
; FILL is HOME-ROM code and makes no EXROM calls, so EXROM temporarily
; hiding $C000-$DFFF can never overlap a live fill operation.
GFX_FILL_STACK       EQU $D800         ; 4096 bytes (2048 x/y entries)
GFX_FILL_STACK_END     EQU GFX_FILL_STACK + 4096
GFX_FILL_SP:         DEFS 2           ; 2 bytes — pointer into GFX_FILL_
                                   ; STACK; == GFX_FILL_STACK means
                                   ; empty, == GFX_FILL_STACK_END means
                                   ; full
GFX_FILL_TARGET:     DEFS 1           ; 1 byte — the pixel value (0 or 1)
                                   ; being replaced, read from the seed
GFX_FILL_ATTR:       DEFS 1           ; 1 byte — fill color
GFX_FILL_X:          DEFS 1           ; 1 byte — the pixel currently
                                   ; being expanded (popped from the
                                   ; stack); NOT reused as scratch by
                                   ; GFX_FILL_TRY_NEIGHBOR/PUSH/POP —
                                   ; those work entirely through B/C,
                                   ; specifically so they can't clobber
                                   ; this while the outer loop is still
                                   ; using it to compute all 4
                                   ; neighbors of the SAME pixel
GFX_FILL_Y:          DEFS 1           ; 1 byte

; ---- kernel/editor word-wrap tables ----
; Populated by EDITOR_WRAP_CALC (kernel/editor/editor.asm) from a line
; buffer's text; consumed by both the multi-row redraw (BASIC_REDRAW_
; PROGRAM/BASIC_PRINT_LINE_HIGHLIGHTED) and cursor row/col mapping
; (EDITOR_MOVE_CURSOR's UP/DOWN, BASIC_DRAW_CURSOR). WRAP_MAX_ROWS=8
; comfortably covers EDIT_LINE_BUF_LEN-1 (127) content chars at a
; 32-column width (127/32 rounds up to 4 rows minimum; 8 leaves
; headroom for pathological word-boundary breaking without needing a
; bounds check on every write — see EDITOR_WRAP_CALC's own header for
; what happens if real content would need more than 8).
WRAP_MAX_ROWS          EQU 8
EDIT_WRAP_COUNT:     DEFS 1           ; 1 byte — number of wrapped rows,
                                   ; always >= 1 even for an empty line
EDIT_WRAP_START:     DEFS 8           ; 8 bytes — EDIT_WRAP_START+i =
                                   ; buffer offset where wrapped row i's
                                   ; content begins
EDIT_WRAP_LEN:       DEFS 8           ; 8 bytes — EDIT_WRAP_LEN+i =
                                   ; number of characters drawn on
                                   ; wrapped row i (0-32)
; EDITOR_WRAP_CALC's own working scratch — kept in memory rather than
; juggled across registers through the routine's inner lookahead scan,
; same "reload rather than preserve" reasoning as HILITE_ROW/etc
; elsewhere in this project.
WRAP_TEXT_PTR:       DEFS 2           ; 2 bytes — current position in the
                                   ; buffer being wrapped
WRAP_REMAIN:         DEFS 1           ; 1 byte — chars left from
                                   ; WRAP_TEXT_PTR to the line's end
WRAP_START_OFS:      DEFS 1           ; 1 byte — current row's start
                                   ; offset from the buffer base
WRAP_ROW_IDX:        DEFS 1           ; 1 byte — current row index

; BASIC_PRINT_LINE_HIGHLIGHTED's own scratch, now that it prints
; multiple wrapped rows per call instead of one — see that routine's
; header for the full reasoning.
HILITE_LINE_BASE:    DEFS 2           ; 2 bytes — the line's own base
                                   ; pointer, saved before EDITOR_WRAP_
                                   ; CALC runs (which advances its own
                                   ; WRAP_TEXT_PTR past the end as it
                                   ; walks, so that can't double as this)
HILITE_WRAP_ROW:     DEFS 1           ; 1 byte — which wrapped row (0-
                                   ; based, within THIS line) is
                                   ; currently being printed
HILITE_LINE_START_ROW:DEFS 1           ; 1 byte — the SCREEN row the first
                                   ; wrapped row lands on (the B param
                                   ; this routine was called with);
                                   ; HILITE_ROW itself now holds
                                   ; wherever wrap row HILITE_WRAP_ROW
                                   ; actually draws (LINE_START_ROW +
                                   ; WRAP_ROW), recomputed once per row
HILITE_ROW_START:    DEFS 1           ; 1 byte — current wrapped row's own
                                   ; start offset within the line
                                   ; (EDIT_WRAP_START[HILITE_WRAP_ROW])
HILITE_ROW_LEN:      DEFS 1           ; 1 byte — current wrapped row's own
                                   ; content length
                                   ; (EDIT_WRAP_LEN[HILITE_WRAP_ROW])
; BASIC_REDRAW_PROGRAM's own scratch for iterating a statement's
; multiple physical rows (clear/print/shadow/error-color/advance) —
; see that routine's own header.
STMT_ROW_COUNT:      DEFS 1           ; 1 byte — how many physical rows
                                   ; the statement/line currently being
                                   ; rendered occupies
STMT_ROW_IDX:        DEFS 1           ; 1 byte — loop index into those rows

; Row-height-aware scroll math (BASIC_SCROLL_TO_FIT/BASIC_ROWS_BEFORE_
; INDEX/BASIC_STMT_ROW_COUNT) — centralized rather than the usual
; small-duplication convention, since this computation is now a real
; multi-call sequence (EDITOR_WRAP_CALC + a per-statement walk), not
; the few-line arithmetic the 3 call sites used to duplicate; see
; BASIC_SCROLL_TO_FIT's own header for the full reasoning.
SCROLL_OWN_ROWS:     DEFS 1           ; 1 byte — the target line's own
                                   ; wrapped row count (from EDIT_LINE_
                                   ; BUF, already loaded by the time
                                   ; any of the 3 call sites run this)
ROWS_BEFORE_IDX:     DEFS 2           ; 2 bytes — BASIC_ROWS_BEFORE_
                                   ; INDEX's own running statement-
                                   ; index counter
ROWS_BEFORE_TOTAL:   DEFS 2           ; 2 bytes — running row-count total
ROWS_BEFORE_PTR:     DEFS 2           ; 2 bytes — running statement
                                   ; position pointer

; BASIC_SCROLL_TO_FIT's own .scroll_down_check loop state (2026-08-24)
; — added when that loop stopped calling BASIC_ROWS_BEFORE_INDEX (a
; full O(view-window) re-walk, EXROM round trip per statement) on
; EVERY iteration and switched to computing the rows-before total ONCE
; then subtracting the row count of whichever statement leaves the top
; of the view as VIEW_TOP_INDEX advances — same "compute once, update
; incrementally" fix for the "editor scrolling/typing is slow in a
; long program" performance report. Distinct from ROWS_BEFORE_TOTAL/
; _PTR above (BASIC_ROWS_BEFORE_INDEX's OWN internal scratch, used only
; once at the very start of this loop now, not per-iteration) since
; this loop's own pointer walks from VIEW_TOP_INDEX forward — a
; different position than where BASIC_ROWS_BEFORE_INDEX's own walk
; ends up (CUR_EDIT_INDEX's statement).
SCROLL_ROWS_BEFORE:  DEFS 2           ; 2 bytes — running total, updated
                                   ; incrementally instead of resummed
SCROLL_TOP_PTR:      DEFS 2           ; 2 bytes — position of whatever
                                   ; statement currently sits at
                                   ; VIEW_TOP_INDEX, advanced one
                                   ; MEM_LINE_NEXT per loop iteration

; Row-count cache (2026-08-24, Priority 2 of the same editor-
; performance pass): BASIC_ROWS_BEFORE_INDEX's walk (called once per
; redraw via BASIC_SCROLL_TO_FIT) and BASIC_REDRAW_PROGRAM's own
; render loop both compute the SAME statements' wrapped row counts
; independently, in the SAME redraw — the render loop always starts
; at VIEW_TOP_INDEX too, and BASIC_SCROLL_TO_FIT already guarantees
; CUR_EDIT_INDEX fits, so every statement BASIC_ROWS_BEFORE_INDEX just
; walked is exactly a prefix of what the render loop is about to walk
; again. BASIC_ROWS_BEFORE_INDEX now records each row count here as it
; computes it (in walk order); BASIC_REDRAW_PROGRAM's .render_settled
; consumes them in the same order instead of re-calling BASIC_EDITOR_
; WRAP_CALC_EXROM (a real EXROM round trip, not the "cheap" cost that
; routine's own OLD comment assumed) for statements already covered.
; Bounded at 23 entries — WRAP_MAX_ROWS (8) means no more than 23
; statements could ever fit in the 23-row view even if every one were
; a single row, so this is a hard ceiling, not a guess.
ROW_COUNT_CACHE:     DEFS 23          ; 23 bytes — one row-count per
                                   ; statement, in VIEW_TOP_INDEX order
ROW_COUNT_CACHE_LEN: DEFS 1           ; 1 byte — how many entries above
                                   ; are valid this redraw (written by
                                   ; BASIC_ROWS_BEFORE_INDEX)
RENDER_CACHE_IDX:    DEFS 1           ; 1 byte — BASIC_REDRAW_PROGRAM's
                                   ; own read position into the cache,
                                   ; reset to 0 at the top of every
                                   ; render pass

; kernel/graphics's GFX_SCROLL_TEXT_UP/_DOWN own cross-call scratch
; (2026-08-24, Priority 3 of the same editor-performance pass) — a
; single text row's bitmap is copied 8 scanlines at a time (ROW_BASE_
; TABLE's non-linear addressing means each scanline is a separate 32-
; byte block, not one contiguous run), and GFX_COPY_ROW_BITMAP needs
; both row numbers alive across two GFX_ROW_BASE_ADDR calls plus the
; scanline-copy loop — kept in memory rather than registers for the
; same reason STMT_ROW_IDX and friends are, elsewhere in this file.
GFX_SCROLL_DST_ROW:  DEFS 1           ; 1 byte — destination row (0-22)
GFX_SCROLL_SRC_ROW:  DEFS 1           ; 1 byte — source row (0-22)

; BASIC_REDRAW_PROGRAM's own fast-scroll detection (2026-08-24,
; Priority 3): remembers VIEW_TOP_INDEX as of the END of the last
; redraw, so the NEXT redraw can tell whether the view moved by
; exactly one statement (the common single arrow-key-press case) and
; take the hardware GFX_SCROLL_TEXT_UP/_DOWN shortcut instead of the
; full per-row render loop. Reset to an invalid sentinel ($FFFF, never
; a real VIEW_TOP_INDEX value) by BASIC_RESET_ROW_SHADOW — any
; structural change that already forces a full shadow reset (DELETE,
; NEW, RUN, LOAD, HELP, ...) correctly disables the fast path for the
; next redraw too, same "when in doubt, fall back to the slow path"
; discipline the fast-scroll integration follows throughout.
LAST_VIEW_TOP_INDEX: DEFS 2           ; 2 bytes

; BASIC_REDRAW_PROGRAM's own fast-scroll path (same pass as LAST_VIEW_
; TOP_INDEX above) — pure scratch, both written and consumed entirely
; within one redraw, never needs resetting between redraws
FAST_SCROLL_NEW_ROW: DEFS 1           ; 1 byte — row the newly-scrolled-
                                 ; into-view active line lands on
FAST_SCROLL_OLD_POS: DEFS 2           ; 2 bytes — program position of
                                 ; the statement that WAS the active
                                 ; line before this scroll (now
                                 ; settled — needs a highlighted
                                 ; redraw at its shifted row)

; BASIC_PRINT_LINE_HIGHLIGHTED/BASIC_PRINT_LINE_PLAIN_WRAPPED merge —
; [stated]'s second consolidation request this session. Both entry
; points now share one body; this flag is the only thing distinguishing
; them (see that routine's own header for how it's used).
HILITE_PLAIN_MODE:   DEFS 1           ; 1 byte — nonzero when called via
                                   ; the plain (no keyword-bold) entry
                                   ; point

; kernel/interrupt's keyboard-scan state — the real interrupt-driven
; scan replacing kernel/io's old fully-blocking IO_READ_KEY (see that
; routine's own header). All owned/written only by KBD_ISR_TICK
; (kernel/interrupt/interrupt.asm); readers (the new IO_READ_KEY) only
; ever read KBD_LASTK/KBD_KEYHIT, never write them, to avoid a race
; against the ISR — matches this project's re-entrancy-scratch lesson
; even though this is single-writer, not nested-call, re-entrancy.
KBD_LASTK:           DEFS 1           ; 1 byte — most recently accepted/
                                   ; repeated key code, stock-LASTK-
                                   ; style
KBD_KEYHIT:          DEFS 1           ; 1 byte — nonzero = KBD_LASTK holds
                                   ; an unconsumed key; the new
                                   ; IO_READ_KEY clears this after
                                   ; reading
KBD_CUR_ROW:         DEFS 1           ; 1 byte — row (0-7) of the single
                                   ; non-modifier key currently being
                                   ; tracked/debounced/repeated, or
                                   ; $FF if none
KBD_CUR_BIT:         DEFS 1           ; 1 byte — bit (0-4) within that row
KBD_DEBOUNCE:        DEFS 1           ; 1 byte — ticks remaining before a
                                   ; newly-seen key is accepted as
                                   ; genuinely pressed (counts down
                                   ; from KBD_DEBOUNCE_TICKS)
KBD_REPEAT:          DEFS 1           ; 1 byte — ticks remaining until the
                                   ; next auto-repeat fire, once
                                   ; accepted (counts down from
                                   ; KBD_REPDEL, then KBD_REPPER after
                                   ; each fire — see kernel/interrupt)

; ---- Structured FOR/NEXT ----
; A real runtime stack (unlike IF/ELSEIF/ELSE, which needs no stack at
; all — see IF_SCAN_POS's own header — a loop's live state, not just a
; branch target, must survive across every statement in its body, so
; it can't be recomputed by a forward scan the way IF's branch
; resolution can). Each of the FOR_STACK_MAX entries is 7 bytes: 1-byte
; loop variable letter ('A'-'Z'), 2-byte end value, 2-byte step value,
; 2-byte body-start pointer (the statement right after FOR, which is
; where BASIC_STMT_NEXT jumps back to for another iteration). Pushed
; by BASIC_STMT_FOR when a loop is actually entered (never pushed at
; all if the initial start/end/step already fail the loop's own
; continue-condition — same "skip the whole thing" treatment IF gives
; a false condition, via BASIC_SKIP_TO_NEXT below); popped by
; BASIC_STMT_NEXT once its own re-checked condition fails.
FOR_STACK_MAX          EQU 8       ; max nesting depth — generous
                                   ; headroom over any real program
                                   ; this project's small-memory target
                                   ; is likely to run, same sizing
                                   ; philosophy as WRAP_MAX_ROWS
FOR_STACK_ENTRY_LEN    EQU 7
FOR_STACK:           DEFS 56          ; FOR_STACK_MAX*FOR_STACK_ENTRY_LEN
                                   ; = 56 bytes, through $953B
FOR_STACK_DEPTH:     DEFS 1           ; 1 byte — number of live entries;
                                   ; the top (most recently pushed) is
                                   ; always the one BASIC_STMT_NEXT acts
                                   ; on, since loops nest strictly (an
                                   ; inner FOR's own NEXT always pops
                                   ; before the outer body can reach
                                   ; ITS matching NEXT)
; BASIC_STMT_FOR's own header-parsing scratch — var/start/end/step all
; need to survive multiple BASIC_EVAL_EXPR calls (which each destroy
; whatever's in HL/DE the way every other expression call in this file
; does), so parsed pieces are stashed here as they're read, then
; assembled into a FOR_STACK entry only once the whole header has
; parsed successfully — same "don't push partial/invalid state" care
; BASIC_TRY_ASSIGNMENT already takes with CUR_VAR_LETTER.
FOR_TEMP_VAR:        DEFS 1           ; 1 byte
FOR_TEMP_START:      DEFS 2           ; 2 bytes
FOR_TEMP_END:        DEFS 2           ; 2 bytes
FOR_TEMP_STEP:       DEFS 2           ; 2 bytes
; BASIC_SKIP_TO_NEXT's own forward-scan position/depth, same role and
; same reasoning as IF_SCAN_POS/IF_SCAN_DEPTH above — used only when a
; FOR's initial condition means the loop body must be skipped entirely
; without ever being entered.
FOR_SCAN_POS:        DEFS 2           ; 2 bytes
FOR_SCAN_DEPTH:      DEFS 1           ; 1 byte
; BASIC_STMT_FOR's own scratch for the new FOR_STACK entry's address
; while it's being assembled field-by-field — same EXPR_PARSE_PTR-style
; reasoning as everything else here: MEM_LINE_NEXT (used to compute the
; entry's body-start field) destroys AF/BC/DE/HL, so the entry pointer
; can't just be held in a register across that call.
FOR_ENTRY_PTR:       DEFS 2           ; 2 bytes
; BASIC_STMT_NEXT's own scratch for the freshly-incremented loop
; variable's value — computed once (current value + step, via
; MATH_ADD16), then read back twice more (writing it into the
; variable, and comparing it against the entry's end value) without
; needing to recompute or juggle it through a register across those
; intervening BASIC_VAR_ADDR/MATH_COMPARE16 calls.
FOR_NEXT_NEWVAL:     DEFS 2           ; 2 bytes

; ---- kernel/storage: incoming-length guard (2026-08-18) ----
; STORAGE_LOAD's own In: contract gained a caller-supplied max-length
; bound after an audit (in the course of designing EXROM paging —
; see docs/memory_map.md's chunk-6 reservation) found that the write
; itself had NO ceiling check at all: it grows straight from the
; caller's destination pointer for as many bytes as the tape header
; CLAIMS, so a corrupted or oversized incoming header could already
; silently overrun into anything above the destination, including the
; stack, with no error raised. DE is unused at STORAGE_LOAD's own
; entry (HL/BC are the only registers it preserves via push across
; header reception), so the caller's bound rides in there and gets
; stashed here immediately, before HL/DE get reused for header
; reception. Checked once, right after the header's own real length
; field is read (.name_matches, before any data block is requested) —
; failing there is strictly cheaper than failing mid-transfer, and
; means nothing is ever written past the bound in the first place.
STORAGE_MAX_LEN:     DEFS 2           ; 2 bytes — caller's max allowed
                                 ; data length, passed in via DE at
                                 ; STORAGE_LOAD's entry

; ---- kernel/interrupt: real-time frame counter (2026-08-18) ----
; Added for two reasons at once: (1) the real ZX Spectrum system
; variable of the same name and purpose (a free-running tick counter,
; incremented once per interrupt) — this project didn't have one
; despite already having a real IM1 handler; (2) it's the actual
; primitive BASIC's planned WAIT FRAME needs (see BASIC language
; design notes: "build WAIT FRAME first... blocks until the next
; interrupt tick"), and it's what the EXROM trampoline's own isolation
; test uses to hold a paged window open across several real interrupt
; ticks rather than a fixed busy-wait loop (a busy-wait proves
; nothing about whether interrupts actually fired during the window;
; watching this counter actually advance does). Incremented
; unconditionally, first thing inside KBD_ISR_TICK (before any of its
; own early-exit branches), so every real interrupt is counted exactly
; once regardless of what else the tick does. Wraps at 65536, same as
; the real Spectrum's own FRAMES (which is 3 bytes there; 2 is enough
; headroom here — wrapping only matters to a caller measuring an
; elapsed duration across a wrap boundary, which no current or planned
; use of this does).
FRAMES:              DEFS 2           ; 2 bytes

; ---- status-line checker-result cache (added for the EXROM checker
; migration's status-line dirty-check — see basic/basic.asm's own
; BASIC_DRAW_STATUS_LINE comments) ----
; BASIC_CHECK_STATEMENT_EXROM pages chunk 6 to EXROM and back on every
; call — cheap in isolation, but BASIC_DRAW_STATUS_LINE calls it on
; EVERY status-line redraw, and BASIC_REDRAW_PROGRAM's own header
; documents that as "full-redraw-every-keypress." Without a cache,
; every keystroke while the cursor sits on a flagged line would page
; EXROM in and out again for a result that's usually unchanged since
; the last redraw. These three sysvars let BASIC_DRAW_STATUS_LINE
; reuse the last check's result instead, whenever CUR_EDIT_POS hasn't
; moved since it was computed. Invalidated (STATUS_CHECK_VALID
; cleared) by both BASIC_SCAN_LABELS_EXROM and BASIC_FULL_CHECK_EXROM,
; since either can change which statement positions are flagged or
; shift positions outright.
STATUS_CHECK_VALID:  DEFS 1           ; 1 byte — nonzero: the two
                                     ; fields below hold a real,
                                     ; still-current result; zero:
                                     ; ignore them, a fresh check is
                                     ; needed
STATUS_CHECK_CACHED_POS:DEFS 2           ; 2 bytes — the CUR_EDIT_POS
                                     ; value the cached result below
                                     ; was computed for
STATUS_CHECK_CACHED_MSG:DEFS 2           ; 2 bytes — the PENDING_ERROR_MSG
                                     ; value BASIC_CHECK_STATEMENT_
                                     ; EXROM produced for that position

; ---- EXROM/Home jump-table consistency check (added alongside the
; macro-generated single-source-of-truth KTAB table — see include/
; exrom_jumptable.inc's own header) ----
; The macro removes the risk of the Home-side and EXROM-side ENTRY
; LISTS going out of sync with each other in SOURCE — but the two are
; still separately assembled and separately deployed binaries (rom0/
; rom1 in Fuse, or two real EPROMs), so a stale rom1.bin paired with a
; freshly-reassembled rom0.bin (forgot to rebuild/redeploy one side)
; is still possible and would silently call the wrong routine with no
; assembler error at all. EXROM_VERIFY_KTAB_MAGIC (rom/exrom_checker.
; asm) checks a magic byte Home stamps into ROM against what THIS
; EXROM image was built expecting, before trusting the table for real
; work; on mismatch it sets this flag and halts visibly rather than
; silently misbehaving — see that routine's own header for the full
; reasoning (this project's lesson 10: diagnose with real values, not
; guesses).
EXROM_KTAB_MISMATCH_FLAG:DEFS 1           ; 1 byte — 0 = never tripped;
                                     ; $FF = EXROM_VERIFY_KTAB_MAGIC
                                     ; found a mismatch and halted —
                                     ; visible from a debug.bin dump
                                     ; even though the screen itself
                                     ; never updates again once halted

; ---- BASIC_STMT_MASKED_EXPR_COMMON scratch (added during the Home
; ROM-size consolidation pass — collapses BASIC_STMT_INK/PAPER/FLASH/
; BRIGHT/INVERSE/OVER/TAB, 7 near-identical "parse one expr, mask it,
; store it" handlers, into one shared routine, each keyword now a
; thin stub) ----
; BASIC_EVAL_EXPR destroys AF/BC/DE/HL (it's a full recursive-descent
; evaluator — see its own header), so there's no register left to
; carry "which sysvar, what mask" through the call from the stub into
; the shared body. These two cells do that instead, set by the stub
; immediately before the shared body runs.
STMT_TARGET_ADDR:    DEFS 2           ; 2 bytes — sysvar address the parsed
                                ; value gets masked and stored into
STMT_TARGET_MASK:    DEFS 1           ; 1 byte — AND mask applied before
                                ; storing (e.g. $07 for INK/PAPER,
                                ; $01 for the boolean attributes,
                                ; $1F for TAB)

; ---- GFX_SPRITE_CAPTURE/GFX_SPRITE_DRAW scratch (Sprites feature,
; 2026-08-19) ----
; Both routines run the same nested row/col loop over a rectangle of
; whole 8x8 character cells, and both call out to GFX_CELL_BITMAP_ADDR/
; GFX_CELL_ATTR_ADDR partway through each cell — routines that destroy
; AF/DE/HL per their own contracts — so the loop's own live state
; (which cell, how far through the buffer) has to survive those calls
; via memory, not registers, same defensive pattern GFX_FILL/GFX_CPLOT
; already established for their own scratch state.
SPRITE_BUF_PTR:      DEFS 2           ; 2 bytes — next unwritten (CAPTURE) or
                                ; unread (DRAW) byte in the caller's
                                ; buffer; advances by 9 per cell
SPRITE_TOP_ROW:      DEFS 1           ; 1 byte — the rectangle's own top
                                ; character row (0-23), fixed for the
                                ; whole call
SPRITE_TOP_COL:      DEFS 1           ; 1 byte — same, top column (0-31)
SPRITE_W:            DEFS 1           ; 1 byte — width in cells (1-32)
SPRITE_H:            DEFS 1           ; 1 byte — height in cells (1-24)
SPRITE_ROW_IDX:      DEFS 1           ; 1 byte — 0-based row offset from
                                ; SPRITE_TOP_ROW, current cell
SPRITE_COL_IDX:      DEFS 1           ; 1 byte — same, column offset

; ---- BASIC-level sprite slots (2026-08-19) — SPRITE GRAB/SHOW/HIDE ----
; Fixed slots, not arrays — this project's BASIC has no array/named-
; buffer support yet (see docs/language design), so a small fixed
; number of numbered slots is the buildable-now option, same pragmatic
; choice EXIT FOR made picking classic NEXT over SuperBASIC's END FOR.
; Each slot is capped at SPRITE_CELL_MAX x SPRITE_CELL_MAX whole 8x8
; cells (4x4 = 32x32 pixels), fixing every slot's buffer at exactly
; SPRITE_SLOT_BYTES regardless of what GRAB actually captures (a
; smaller w/h just leaves the unused tail of the buffer alone).
SPRITE_SLOT_MAX     EQU 8       ; number of slots (0-7). Doubled from
                                ; 4 (2026-08-23) — free in ROM terms
                                ; (the slot-offset math is a `djnz`
                                ; loop, not unrolled per-slot code, and
                                ; GRAB/SHOW/HIDE/MOVE/HIT all already
                                ; take the slot count as a runtime
                                ; bound, not a compile-time one), so
                                ; the only real cost is RAM. The large
                                ; image/background buffers now live at
                                ; $E800-$F0FF; only the small per-slot
                                ; metadata remains below PROG_AREA_START.
SPRITE_CELL_MAX     EQU 4       ; max cells per dimension per slot
SPRITE_SLOT_BYTES   EQU 144     ; SPRITE_CELL_MAX*SPRITE_CELL_MAX*9
                                ; (GFX_SPRITE_CAPTURE/DRAW's own 9-
                                ; bytes-per-cell buffer format)

SPRITE_SLOT_DEFINED: DEFS 8           ; 8 bytes (1/slot) — has GRAB been
                                ; called for this slot yet (SHOW
                                ; refuses otherwise)
SPRITE_SLOT_SHOWN:   DEFS 8           ; 8 bytes (1/slot) — currently drawn
                                ; on screen (HIDE/MOVE refuse
                                ; otherwise; SHOW refuses if already
                                ; shown — call MOVE, or HIDE then SHOW,
                                ; to reposition a shown sprite)
SPRITE_SLOT_W:       DEFS 8           ; 8 bytes (1/slot) — width in cells,
                                ; as given to the slot's own GRAB
                                ; (1-4)
SPRITE_SLOT_H:       DEFS 8           ; 8 bytes (1/slot) — height in cells
                                ; (1-4)
SPRITE_SLOT_ROW:     DEFS 8           ; 8 bytes (1/slot) — current display
                                ; row, meaningful only while SHOWN
                                ; (HIDE/MOVE need this to know where
                                ; the saved background goes back)
SPRITE_SLOT_COL:     DEFS 8           ; 8 bytes (1/slot) — same, column
SPRITE_DISPLAY_DEPTH: DEFS 1          ; number of slots currently shown
SPRITE_DISPLAY_STACK: DEFS 8          ; slot numbers in SHOW order;
                                ; save-under restoration must pop these
                                ; in reverse order to preserve overlaps
; The two large buffers are persistent across EXROM calls, so they live in
; chunk 7, which this project never pages. This returns 2304 bytes below
; PROG_AREA_START to BASIC while keeping the buffers visible to the EXROM-
; resident sprite driver. Their $F100 end leaves $0E00 (3584) bytes before
; the machine stack at $FF00.
SPRITE_SLOT_IMG_BUF  EQU $E800         ; 1152 bytes — captured sprite
                                ; image itself (SPRITE_SLOT_MAX *
                                ; SPRITE_SLOT_BYTES), filled once per
                                ; GRAB, read (never written) by every
                                ; SHOW/MOVE
SPRITE_SLOT_BG_BUF   EQU $EC80         ; 1152 bytes — saved background
                                ; under the sprite, captured fresh by
                                ; each SHOW/MOVE, consumed by the
                                ; matching HIDE/MOVE

    ASSERT SPRITE_SLOT_IMG_BUF + (SPRITE_SLOT_MAX * SPRITE_SLOT_BYTES) == SPRITE_SLOT_BG_BUF
    ASSERT SPRITE_SLOT_BG_BUF + (SPRITE_SLOT_MAX * SPRITE_SLOT_BYTES) == $F100
    ASSERT $F100 <= $FF00              ; preserve machine-stack headroom

; Parse-time scratch for GRAB/SHOW's own multi-argument grammar (slot,
; row, col[, w, h]) — each argument gets evaluated and written here
; immediately (same "write it down, don't trust a register to survive
; the next call" shape LINE/BLOCK already use for their own multi-
; coordinate parsing) before the next BASIC_EXPECT_COMMA_EXPR call
; destroys BC/DE/HL. Shared between GRAB and SHOW (never both live at
; once — one statement's parse completes before the next begins).
SPRITE_ARG_SLOT:     DEFS 1           ; 1 byte
SPRITE_ARG_ROW:      DEFS 1           ; 1 byte
SPRITE_ARG_COL:      DEFS 1           ; 1 byte
SPRITE_ARG_W:        DEFS 1           ; 1 byte
SPRITE_ARG_H:        DEFS 1           ; 1 byte

; GFX_FILL's per-pixel visited-tracker — see GFX_FILL's own header
; (kernel/graphics/graphics.asm) for why this has to be a separate
; buffer rather than folded into the bitmap write. Plain linear
; row*32+col layout (NOT the real screen's interleaved-thirds
; addressing — this buffer has no display hardware to match), cleared
; at the start of every FILL call. This is transient scratch in the reserved
; HOME-RAM EXROM window, not persistent storage: $C000-$D7FF is available
; whenever HOME is mapped, and no EXROM call occurs while the bitmap is live.
GFX_FILL_VISITED     EQU $C000         ; 6144 bytes, through $D7FF

    ASSERT GFX_FILL_VISITED + 6144 == GFX_FILL_STACK
    ASSERT GFX_FILL_STACK_END == $E800
    ASSERT GFX_FILL_STACK_END <= $FF00 ; keep clear of machine stack

; Calculator engine (RST $28) working storage — RPN stack, calculator
; "memory" cells, and recursive-entry counter, matching the real
; Spectrum ROM's CALCULATE subroutine (see project notes). Deliberately
; a FIXED-size block, not a dynamic RAM-growing stack like the real
; ROM's: this project's calculator only ever handles transient
; expression/function results (never stored into VAR_TABLE as floats —
; see that EQU's own comment), so a small fixed allocation avoids the
; runtime-bounds-check-against-a-moving-boundary shape that's caused
; real bugs elsewhere in this project (PROG_AREA_START's own history
; below; GFX_FILL's visited-buffer conflicts). 8 stack slots chosen to
; match FOR_STACK's own margin-over-minimum sizing (8 entries) —
; real RPN expressions peak around 3-4 deep, so this is generous
; headroom, not a tight fit; bump this EQU later if it's ever too small.
CALC_STACK:          DEFS 40          ; 40 bytes (8 slots x 5-byte float)
CALC_SP:             DEFS 1           ; 1 byte — stack index, 0 = empty
; The original calculator design reserved six five-byte mem-N slots here.
; No implemented dispatcher operation reads or writes them: SQR/SIN use the
; explicit Home-side fields below instead of the ROM SERIES generator. Remove
; the unused 30-byte block; add it back only with an implemented st/get-mem op.
CALC_BREG:           DEFS 1           ; 1 byte — mirrors the real ROM's BREG:
                                ; recursive-entry counter used by
                                ; GEN_ENT_1/GEN_ENT_2 so a nested
                                ; CALCULATE call (e.g. SERIES calling
                                ; back into itself) doesn't disturb the
                                ; outer call's own op counter
CALC_TRUNC_FLAG:     DEFS 1           ; set by CALC_FP_TO_INT: 1 when the
                                ; result exceeded signed 16-bit range, 0
                                ; otherwise; simulator-observed calculator
                                ; boundary status alongside carry/error code
; Calculator error codes. CALC_ERROR_CODE aliases the original diagnostic
; byte so the hardening pass changes no RAM addresses.
CALC_ERR_NONE              EQU 0
CALC_ERR_INVALID_LITERAL   EQU 1
CALC_ERR_STACK_UNDERFLOW   EQU 2
CALC_ERR_STACK_OVERFLOW    EQU 3
CALC_ERR_DIVISION_BY_ZERO  EQU 4
CALC_ERR_NUMERIC_OVERFLOW  EQU 5
CALC_ERR_UNIMPLEMENTED     EQU 6
CALC_UNIMPLEMENTED_LITERAL_FLAG:DEFS 1         ; retained ABI name
CALC_ERROR_CODE       EQU CALC_UNIMPLEMENTED_LITERAL_FLAG
                                ; nonzero CALC_ERR_* value. RST $28
                                ; failures scan to END-CALC and return
                                ; through the normal paging trampoline;
                                ; direct push/conversion entries return
                                ; carry set. No calculator error writes
                                ; outside CALC_STACK.
                                ; Formerly held the CALC_
                                ; TABLE index (byte offset) that
                                ; dispatched to the unimplemented-op
                                ; stub, NOT a reconstructed literal
                                ; byte value (index>>1 recovers the
                                ; literal for the $00-$3D path only —
                                ; see rom/exrom_calc.asm's CALC_OP_
                                ; UNIMPLEMENTED for why the multi-
                                ; purpose ($80+) path can't be
                                ; recovered the same way); that historical
                                ; detail value is no longer stored.
CALC_LITERAL_PTR:    DEFS 2           ; 2 bytes — current position in the RST
                                ; $28 literal-byte stream. Added 2026-
                                ; 08-20 when the dispatcher was reworked
                                ; away from the real ROM's EXX/EX (SP),HL
                                ; register-banking trick (see rom/exrom_
                                ; calc.asm's own header for the full
                                ; reasoning) — this plain sysvar replaces
                                ; the primed HL' register's role. [stated]
                                ; explicit design goal: smallest possible
                                ; Home ROM footprint once TRIG functions
                                ; land, which is a EXROM-placement
                                ; argument, not a reason to keep the
                                ; fragile register trick — this sysvar
                                ; costs 2 bytes of RAM, not ROM, and pays
                                ; for full simulator-testability plus
                                ; removing a whole class of "which
                                ; register bank is live right now" bugs
CALC_OP1_PTR:        DEFS 2           ; 2 bytes — first-operand pointer,
                                ; recomputed fresh from CALC_SP on EVERY
                                ; dispatch iteration (not carried
                                ; incrementally like the real ROM's HL) —
                                ; deliberate: trusting ~60 future op
                                ; routines to each correctly maintain a
                                ; raw pointer is the same fragile-
                                ; incremental-state risk already rejected
                                ; for CALC_STACK itself (see that EQU's
                                ; own comment); recomputing from the
                                ; authoritative CALC_SP index every time
                                ; means a bug in one op shows up on the
                                ; very next dispatch, not several ops
                                ; later. Each op routine's own first
                                ; instruction is `LD HL,(CALC_OP1_PTR)`
CALC_OP2_PTR:        DEFS 2           ; 2 bytes — second-operand pointer
                                ; (binary ops only), same recompute-
                                ; fresh-every-time reasoning as CALC_
                                ; OP1_PTR above. Binary op routines load
                                ; it via `LD DE,(CALC_OP2_PTR)`
CALC_LITERAL_PARAM:  DEFS 1           ; 1 byte — the 5-bit parameter CALC_
                                ; SCAN_ENT extracts for "multi-purpose"
                                ; literals (get-mem-N, st-mem-N, etc.,
                                ; literal value >=$80) — not read by any
                                ; op yet (end-calc, the only op
                                ; implemented so far, is a plain $00-$3D
                                ; literal with no parameter), but the
                                ; decode logic produces this value
                                ; regardless, so it needs a home now
                                ; rather than a redesign when the first
                                ; parameterized op (e.g. get-mem-3) lands
CALC_STACK_OVERFLOW_FLAG:DEFS 1         ; 1 byte — diagnostic stack depth at
                                ; the moment `duplicate` (literal $31)
                                ; found no room left (CALC_SP already at
                                ; the 8-slot cap). CALC_ERROR_CODE carries
                                ; the recoverable error classification.
                                ; Real ROM has no equivalent — its stack
                                ; grows into free RAM and only fails on
                                ; genuine memory exhaustion; this
                                ; project's fixed 8-slot CALC_STACK
                                ; (see that EQU's own comment) can hit
                                ; its cap from an 8-deep RPN expression
                                ; alone, a normal-ish case worth a clear
                                ; diagnostic rather than silent memory
                                ; corruption past the array's end

; ---- Real arithmetic (add/sub/multiply) + INT_TO_FP/FP_TO_INT, added
; 2026-08-21. All scratch, no persistent state carried between calls.
CALC_UNP_A:          DEFS 6           ; 6 bytes — unpacked-float record for
                                ; operand A: byte0=sign ($00/$FF,
                                ; matching the float format's own small-
                                ; int-form convention), byte1=biased
                                ; exponent (0=zero value), bytes2-5=
                                ; 32-bit mantissa MSB-first with the
                                ; implicit leading bit made explicit
                                ; (bit7 of byte2 set for any nonzero
                                ; value). Filled by CALC_UNPACK, read by
                                ; CALC_PACK and the arithmetic engines.
                                ; Also doubles as the RESULT record for
                                ; every op below — the final answer
                                ; always ends up here before CALC_PACK.
CALC_UNP_B:          DEFS 6           ; 6 bytes — same layout, operand B
CALC_SHIFT_COUNT:    DEFS 1           ; 1 byte — scratch shift/loop counter,
                                ; shared across CALC_UNPACK's
                                ; normalization loop and the add/sub
                                ; engine's alignment-shift loop (never
                                ; live across a call boundary, so one
                                ; shared byte is safe — same reasoning
                                ; already applied to CALC_LITERAL_PARAM)
CALC_MUL_ACC:        DEFS 8           ; 8 bytes — 64-bit product accumulator
                                ; for CALC_OP_MUL's shift-add multiply,
                                ; byte0=LSB..byte7=MSB
CALC_MUL_CAND:       DEFS 8           ; 8 bytes — 64-bit shifting multiplicand
                                ; for the same routine (top 4 bytes
                                ; start zero, bottom 4 = operand A's
                                ; mantissa, then shifts left each of the
                                ; 32 iterations)
CALC_DIV_REM:        DEFS 4           ; 4 bytes — 32-bit remainder for
                                ; CALC_OP_DIV's shift-subtract mantissa
                                ; divide, MSB-first (matching CALC_UNP_*'s
                                ; own mantissa byte order). Starts as the
                                ; dividend mantissa (optionally pre-
                                ; shifted right 1 — see that routine's own
                                ; header), shifted left and conditionally
                                ; reduced by the divisor mantissa once per
                                ; iteration.
CALC_DIV_QUOT:       DEFS 4           ; 4 bytes — 32-bit quotient accumulator
                                ; for the same routine, MSB-first, built
                                ; up one bit per iteration alongside
                                ; CALC_DIV_REM above.

; ---- "function-result float" scratch (2026-08-22): SQR and SIN now
; compute through the calculator engine and can PRINT a genuine
; fractional result, while every other keyword stays int-only (see
; docs/programmers_reference.md's function-table section for the
; full per-keyword audit). FUNC_RESULT_IS_FLOAT/_NEGATIVE/_FLOAT are
; how a function call tells BASIC_STMT_PRINT "the value you're about
; to print has a truer float answer than the truncated int you also
; got back" — set only when the WHOLE printed expression turns out to
; be exactly one such bare call (see BASIC_STMT_PRINT and the do_add/
; do_sub/do_mul/do_div/negate clear-sites in BASIC_EVAL_EXPR/TERM/
; FACTOR for how that's enforced); SIN/SQR_ARG_N and the SIN_* buffers
; are pure scratch for those two routines' own internal orchestration.
FUNC_RESULT_IS_FLOAT:DEFS 1          ; 1 byte — 1 if FUNC_RESULT_FLOAT holds
                                ; a meaningful value for the expression
                                ; just evaluated, 0 otherwise. Cleared
                                ; at the top of every BASIC_STMT_PRINT,
                                ; at every EXPR/TERM combine step, and
                                ; before every function dispatch;set
                                ; back to 1 only by SQR/SIN's own
                                ; dispatch bodies, after the clear.
FUNC_RESULT_FLOAT_NEGATIVE:DEFS 1         ; 1 byte — 1 if the true value in
                                ; FUNC_RESULT_FLOAT should print with a
                                ; leading "-". FUNC_RESULT_FLOAT itself
                                ; is always a non-negative magnitude
                                ; (true of both SQR's and SIN's own
                                ; results by construction — see those
                                ; routines' own headers) so the sign
                                ; is tracked separately here rather
                                ; than folded into the packed float,
                                ; which keeps BASIC_FLOAT_TO_STRING
                                ; itself sign-agnostic.
FUNC_RESULT_FLOAT:   DEFS 5           ; 5 bytes — packed float (rom/exrom_
                                ; calc.asm's own format), valid only
                                ; when FUNC_RESULT_IS_FLOAT=1. A plain
                                ; copy taken from CALC_STACK's top slot
                                ; right after the result is computed —
                                ; not left sitting on CALC_STACK itself,
                                ; so a PRINT that never materializes
                                ; (LET x = SQR(2), IF SQR(2)>1 THEN...)
                                ; can never leak a stack slot.
FLOAT_PRINT_INTPART: DEFS 2           ; 2 bytes — BASIC_FLOAT_TO_STRING's own
                                ; scratch: the truncated integer part,
                                ; stashed across the BASIC_NUM_TO_STRING
                                ; call (which needs DE, and destroys
                                ; everything) so it can be re-pushed as
                                ; a float afterward for the fractional-
                                ; remainder subtraction
SQR_ARG_N:           DEFS 2           ; 2 bytes — BASIC_SQR_FLOAT's own
                                ; scratch: the original int argument,
                                ; re-pushed as a float on every Newton
                                ; iteration (n/x_k) rather than kept on
                                ; CALC_STACK across the loop
SIN_X_RAD:           DEFS 5           ; 5 bytes — BASIC_SIN_FLOAT's own
                                ; scratch: the reduced argument in
                                ; radians (packed float), computed once
                                ; and re-pushed from here on every
                                ; power/term step instead of re-running
                                ; the degrees->radians conversion each
                                ; time
SIN_X2:              DEFS 5           ; 5 bytes — x_rad squared, packed float,
                                ; computed once and reused every
                                ; iteration of the term-generating loop
SIN_POWER:           DEFS 5           ; 5 bytes — running |term_k| (always
                                ; non-negative — see BASIC_SIN_FLOAT's
                                ; own header for the sign-free
                                ; recurrence this depends on), packed
                                ; float, updated in place each iteration

; ---- USR's static-check guard (2026-08-22) ----
; USR(addr) genuinely jumps to and executes whatever's at addr — unlike
; every other built-in function, it can't be "side-effect-free by
; nature" the way BASIC_CHECK_STATEMENT's own header assumes every
; validation primitive is. The checker (BASIC_FULL_CHECK_EXROM/BASIC_
; CHECK_STATEMENT_EXROM, called on every RUN AND on every live-typing
; status-line redraw — see those routines' own header) evaluates
; expressions for real, through the exact same BASIC_EVAL_EXPR real
; execution uses, so an unguarded USR() in a statement being merely
; TYPED (not yet run) would jump to whatever its argument currently
; evaluates to — for an as-yet-unassigned variable, address 0, which is
; this ROM's own RST_00 vector: `di / jp COLD_START`, restarting the
; entire machine from inside the checker's own call chain. Confirmed by
; a real hang in a throwaway preload-harness smoke test (see this
; project's own working memory) before this guard existed. Set to
; nonzero by both wrapper routines around their own page-in/call/page-
; out, checked by BASIC_EVAL_PRIMARY's USR dispatch case, which skips
; the actual jump and returns 0 instead whenever this is set.
BASIC_CHECK_ONLY:    DEFS 1           ; 1 byte — 0 = real execution (USR
                                ; really jumps), nonzero = a static
                                ; check pass is in progress (USR is a
                                ; no-op, returns 0)

; ---- kernel/bank's EXROM paging nesting counter (2026-08-22) ----
; BANK_PAGE_EXROM_IN/_OUT used to be bare, non-reentrant port writes —
; fine for every ORIGINAL caller (each pages in, does its one thing,
; pages out, no nesting). That broke the moment a caller could itself
; be invoked FROM WITHIN an already-paged-in EXROM call: the whole-
; program/live-typing checker (BASIC_FULL_CHECK_EXROM/BASIC_CHECK_
; STATEMENT_EXROM) pages EXROM in, then calls into ITS OWN EXROM-
; resident code, which calls back into Home (KTAB_BASIC_EVAL_EXPR) to
; validate an expression — and if that expression contains SIN()/PI()/
; RAD()/DEG() (any "function-result float" built-in that touches the
; calculator engine via a CALC_*_HOME wrapper), that wrapper does its
; OWN inner BANK_PAGE_EXROM_IN/_OUT round trip. The inner page-OUT
; unmapped chunk 6 back to Home while the OUTER checker call was still
; logically "inside" EXROM-resident code (its own return address, from
; `call KTAB_BASIC_EVAL_EXPR`, points into $C0xx) — so when that outer
; call eventually returned, it jumped into whatever Home now has
; mapped at $C0xx instead of the real EXROM checker code, a genuine
; hang. Confirmed as a REAL, PRE-EXISTING bug (not new — it already
; affected SIN(), just never triggered before: SIN's own prior testing
; called BASIC_SIN_FLOAT directly as a routine, rom/test_sqr_sin_
; visual.asm, bypassing the checker entirely) via a throwaway preload-
; harness reproduction: `PRINT "START" : A = SIN(30)` hung before even
; "START" printed — proof the whole-program check itself never
; completed, not a bug in SIN's own math.
;
; BANK_EXROM_DEPTH makes BANK_PAGE_EXROM_IN/_OUT nesting-safe: IN only
; does the real port write when depth was 0 (0->1 transition), OUT
; only does the real port write when depth reaches back to 0 — any
; inner, nested pair just adjusts the counter and leaves chunk 6
; mapped exactly as the outer caller left it. The single-call (depth
; 0->1->0) case — every caller before this — is completely unchanged.
BANK_EXROM_DEPTH:    DEFS 1           ; 1 byte — 0 = chunk 6 currently Home

; ---- GOSUB/RETURN return-address stack (2026-08-22) ----
; Same shape as FOR_STACK below (fixed array + depth counter) — the
; established precedent for "a bounded call-nesting depth" in this
; project — but each entry is just a 2-byte program position (the
; statement to resume at), not FOR's fuller 7-byte loop-state record.
; BASIC_STMT_GOSUB computes the return position the same way BASIC_
; RUN's own main loop would if no jump had happened (MEM_LINE_NEXT on
; CUR_EXEC_STMT), pushes it here, then sets GOTO_TARGET to the called
; label's position exactly like GOTO does. BASIC_STMT_RETURN pops it
; back into GOTO_TARGET. GOSUB_STACK_MAX matches FOR_STACK_MAX's own
; "generous but bounded" sizing rather than being separately justified.
GOSUB_STACK_MAX     EQU 8
GOSUB_STACK_ENTRY_LEN EQU 2
GOSUB_STACK:         DEFS 16          ; GOSUB_STACK_MAX*GOSUB_STACK_ENTRY_LEN
                                ; = 16 bytes, through $B2A0
GOSUB_STACK_DEPTH:   DEFS 1           ; 1 byte — number of live entries

; ---- UDG table + block-graphics scratch (2026-08-22) ----
; Real TS2068/Spectrum-family hardware (confirmed via the ROM
; disassembly's PO-T&UDG/PO-GR-1) stores UDGs as plain RAM, POKE-
; defined, one 8-byte bitmap per character code — no BASIC statement
; needed to define one, exactly like this project's existing POKE
; already allows. UDG_TABLE holds all 21 slots (codes 144-164)
; contiguously; kernel/graphics's GFX_CHAR_TO_FONT_OFFSET computes
; UDG_TABLE + (code-144)*8 directly, same shape as its existing
; FONT_TABLE + index*8 math.
;
; BLOCK_GFX_SCRATCH is unrelated to UDGs but shares this comment block
; since it was sized/placed alongside them: block-graphics characters
; (128-143) are never stored as static glyph data at all on real
; hardware — PO-GR-1 (MKBLKGR) generates the 8-byte bitmap on the fly
; from the character code's low nibble every time one is printed. This
; project's GFX_CHAR_TO_FONT_OFFSET does the same, writing the
; generated bytes here and returning this address instead of a
; FONT_TABLE offset. Must be real RAM, not a ROM-resident DB byte —
; see GFX_PRINT_STRING_ATTR's own PRINT_ATTR_SCRATCH comment for why a
; `ld (addr),a` into a ROM address is a silent no-op on real hardware.
UDG_COUNT           EQU 21
; Persistent UDG glyphs also live in never-paged chunk 7, immediately after
; the label table. Graphics calls remain able to read them while EXROM owns
; chunk 6. `$F328-$F3A7` holds STR_FUNC_POOL and `$F3A8-$F3AE` holds
; minimal DEF FN state. Extension state occupies `$F3AF-$F3C2`, and the
; fixed module window occupies `$F400-$F5FF`; genuine stack headroom starts
; at `$F600`.
UDG_TABLE            EQU $F180
    ASSERT LABEL_TABLE_TOP + LABEL_TABLE_MAXLEN == UDG_TABLE
    ASSERT UDG_TABLE + 168 == $F228
    ASSERT UDG_TABLE + 168 == EDIT_LINE_BUF
    ASSERT EDIT_LINE_BUF + EDIT_LINE_BUF_LEN == DETOK_BUF
    ASSERT DETOK_BUF + 128 == $F328
    ASSERT $F600 <= $FF00              ; 2304 bytes of stack headroom
BLOCK_GFX_SCRATCH:   DEFS 8           ; 8 bytes, through $B351

; ---- String scalars (Phase 3, 2026-08-22) ----
; STR_TABLE (26 fixed 32-byte string-scalar slots, byte 0 = length,
; bytes 1-31 = content) lived here through Phase 3 — retired in Phase 4
; (2026-08-23), moved into the dynamic pool alongside arrays and
; numeric scalars (see "Scalar variables in the dynamic pool" below).
; Not null-terminated internally — length is explicit, same reasoning
; TOKEN_BUF's own 2-byte length prefix already established for this
; project's other variable-length text; the pool's own scalar records
; still use this exact same length+content shape, unchanged.
;
; STR_EXPR_SCRATCH and STR_CMP_RIGHT are shared working buffers, same
; 32-byte slot shape (length + content) as a string scalar's own data
; — deliberately reused across features rather than one dedicated
; buffer per statement type, since string assignment/PRINT/comparison
; never run concurrently within a single statement's execution:
;   - Assignment (BASIC_TRY_STR_ASSIGNMENT): RHS is evaluated into
;     STR_EXPR_SCRATCH before being copied into the target variable's
;     pool record.
;   - Comparison (BASIC_EVAL_COMPARISON's string path): the LEFT
;     operand also lands in STR_EXPR_SCRATCH (assignment isn't live
;     mid-comparison, so no collision); the RIGHT operand needs its
;     OWN buffer since both sides must be held simultaneously to
;     compare them — that's STR_CMP_RIGHT, the one buffer that
;     couldn't be shared with anything else.
STR_EXPR_SCRATCH:    DEFS 32          ; 32 bytes, through $B6B1
STR_CMP_RIGHT:       DEFS 32          ; 32 bytes, through $B6D1

; ---- Numeric arrays (Phase 3, part 3, 2026-08-22) ----
; Option 2 from the design discussion: a DYNAMIC region, not a fixed
; per-letter table like VAR_TABLE/STR_TABLE above — DIM'd arrays are
; appended right after program text (starting at PROG_END) and grow
; toward PROG_AREA_MAX, so array capacity is limited only by whatever
; RAM the current program isn't using, not a fixed slot count. Reset
; (ARRAYS_END := PROG_END) at the start of every RUN and at cold boot
; (MEM_INIT) — arrays are RUN-scoped, matching classic BASIC's own
; "RUN implies CLEAR" semantics, and this sidesteps ever needing to
; relocate array data when the editor inserts/deletes program text:
; MEM_LINE_INSERT's own space check already compares PROG_END+new
; content against the fixed PROG_AREA_MAX ceiling, oblivious to
; whatever stale array bytes might currently sit above PROG_END — safe
; to overwrite, since anything there is guaranteed to be reset (or
; already was, if no DIM has run yet this session) before it's ever
; read again.
;
; Record format, deliberately including a KIND byte even though only
; one kind (numeric) exists yet: [kind:1][name:1][count:2][data...],
; kind 0 = numeric (data = count*2 bytes, signed 16-bit elements).
; Designed so a future string-array kind (or, further out, unifying
; scalars into this same region per the design discussion) can reuse
; BASIC_ARRAY_FIND's scan-by-name-and-kind shape rather than needing a
; second, incompatible lookup mechanism. See basic/basic.asm's
; BASIC_ARRAY_FIND/BASIC_STMT_DIM for the real code.
;
; ARRAY_DIM_COUNT/ARRAY_INDEX/ARRAY_ASSIGN_VALUE are small scratch
; fields, not persistent state — parsed values stashed here rather than
; juggled through registers across the several destructive calls (BASIC_
; EVAL_EXPR, BASIC_ARRAY_FIND) each statement needs, same "value must
; survive a call, use memory not a register" pattern this project has
; used repeatedly (SPRITE_ARG_*, GFX_FILL_X/Y, etc.).
ARRAYS_END:          DEFS 2           ; 2 bytes — current top of the dynamic
                                ; arrays region (== PROG_END when empty)
ARRAY_DIM_COUNT:     DEFS 2           ; 2 bytes — DIM's own parsed size,
                                ; between parsing and committing
ARRAY_INDEX:         DEFS 2           ; 2 bytes — a parsed array subscript,
                                ; shared by the read and write paths
                                ; (never live at the same time)
ARRAY_ASSIGN_VALUE:  DEFS 2           ; 2 bytes — array assignment's own
                                ; parsed RHS value, between parsing and
                                ; the store

; ---- Scalar variables in the dynamic pool (Phase 4, 2026-08-23) ----
; "Option 3" from the design discussion above: VAR_TABLE/STR_TABLE's
; fixed 26-slot tables are replaced by two more kinds in this SAME
; record pool, reusing BASIC_ARRAY_FIND's scan-by-name shape exactly as
; that routine's own header always intended. kind 1 = numeric scalar
; (count is always VAR_NUM_UNITS, so data is always 2 bytes — a scalar
; is literally a fixed 1-element array under the hood, needing zero new
; skip-arithmetic in the scan). kind 2 = string scalar (count is always
; VAR_STR_UNITS, data is always 32 bytes, same length/layout STR_TABLE
; slots always used — byte 0 = length, bytes 1-31 = content). The count
; field is meaningless as a real bound for kind 2 (nothing indexes into
; a string scalar); it exists purely so the scan's existing count*2
; skip-past-this-record math keeps working unmodified for every kind.
;
; Arrays and scalars do NOT share one growth direction, because they
; don't share a reset schedule: arrays are RUN-scoped (ARRAYS_END :=
; PROG_END at the start of every RUN), but scalars persist ACROSS RUN
; (only reset at NEW/LOAD, matching VAR_TABLE's own pre-migration
; behavior). Growing scalars upward from PROG_END the way arrays do
; would mean editing the program between runs (which grows PROG_END)
; could silently overwrite live scalar data sitting just above it —
; arrays get away with that only because they're always freshly
; recreated after such an edit, scalars are not. So this is a genuine
; two-ended pool instead: arrays keep growing UP from PROG_END exactly
; as before; scalars grow DOWN from PROG_AREA_MAX. VARS_START is the
; scalar side's own high-water mark (its lowest used address — "empty"
; is VARS_START == PROG_AREA_MAX, mirroring ARRAYS_END == PROG_END).
; The two ends meeting (ARRAYS_END would pass VARS_START, or vice
; versa) is this pool's own out-of-memory condition — see BASIC_VAR_
; ADDR/BASIC_ARRAY_FIND (basic/basic.asm) and MEM_FREE_BYTES (kernel/
; memory/memory.asm) for the real code; MEM_FREE_BYTES and the
; program-growth boundary check both compare against VARS_START now,
; not the fixed PROG_AREA_MAX, since scalars can occupy that space too.
ARRAY_KIND_NUM       EQU 0    ; numeric array (existing, Phase 3)
VAR_KIND_NUM         EQU 1    ; numeric scalar
VAR_KIND_STR         EQU 2    ; string scalar
ARRAY_KIND_STR       EQU 3    ; string array, 32 bytes per element
VAR_NUM_UNITS        EQU 1    ; numeric scalar data = 1*2 = 2 bytes
VAR_STR_UNITS        EQU 16   ; string scalar data = 16*2 = 32 bytes
VARS_START:          DEFS 2           ; 2 bytes — scalar pool's own
                                ; high-water mark, grows DOWN from
                                ; PROG_AREA_MAX (opposite direction
                                ; from ARRAYS_END)
POOL_SCAN_END:       DEFS 2           ; 2 bytes — BASIC_ARRAY_FIND's own
                                ; scratch: the resolved end boundary
                                ; for whichever region the current scan
                                ; is searching (ARRAYS_END or PROG_AREA_
                                ; MAX), re-read fresh every loop
                                ; iteration since DE is busy holding
                                ; each record's own count field
POOL_RECORD_KIND:    DEFS 1           ; current record kind during scan
ARRAY_DIM_KIND:      DEFS 1           ; DIM allocator's requested kind
ARRAY_ALLOC_BYTES:   DEFS 2           ; DIM's computed data-byte count
STR_ASSIGN_KIND:     DEFS 1           ; 0=scalar, nonzero=string array
STR_ASSIGN_LETTER:   DEFS 1           ; target survives nested RHS parsing
STR_ASSIGN_INDEX:    DEFS 2           ; target index survives RHS parsing
VAR_CHECK_SCRATCH:   DEFS 32          ; 32 bytes — BASIC_VAR_FIND_OR_
                                ; CREATE's dummy return address during
                                ; a BASIC_CHECK_ONLY whole-program check
                                ; pass, so a scalar reference in a
                                ; statement that hasn't run yet can't
                                ; auto-vivify a REAL pool record (or
                                ; spuriously OUT-OF-MEMORY) just from
                                ; being checked — same "check pass must
                                ; not mutate real state" reasoning
                                ; BASIC_CHECK_ARRAY_ASSIGNMENT's own
                                ; header already gives for arrays.
                                ; Dedicated rather than reused (STR_
                                ; EXPR_SCRATCH etc. could genuinely be
                                ; live mid-evaluation of a NESTED
                                ; expression at the moment this fires)
                                ; — 32 bytes covers either scalar shape
                                ; (2-byte numeric or 32-byte string)

; Multi-dimensional array support (2D DIM/read/write, ARRAY_DIM2_
; COUNT/ARRAY_INDEX2/ARRAY_SUBSCRIPT_COUNT/ARRAY_DIMN_ARG) was built,
; verified structurally, and then archived 2026-08-22 — it worked, but
; cost more Home ROM than this project could spare at the time. See
; docs/programmers_reference.md's "Multi-dimensional arrays (archived)"
; section for the full design if this is ever worth reviving; DIMN
; itself survived the archival, simplified to DIMN(name) (single
; argument, no dimension number — nothing left to ask for one).

; ---- String/INKEY$ functions (2026-08-22) ----
; STR_FUNC_POOL is a small FIXED POOL of scratch string buffers for
; string-function ARGUMENTS (CHR$/STR$/UPPER$/LOWER$/LEFT$/RIGHT$/
; FILL$/LEN/CODE/VAL/INSTR) — deliberately NOT the existing STR_EXPR_
; SCRATCH/STR_CMP_RIGHT (those stay reserved for assignment-RHS/
; comparison-operand use exactly as before). A shared buffer here would
; hit the SAME "shared mutable scratch clobbered by a nested call" bug
; class this project has now hit twice this session (CUR_VAR_LETTER,
; function handler/argc scratch) — a call like "UPPER$(LEFT$(A$,3))" needs the
; OUTER call's own argument buffer to survive while the INNER call
; evaluates ITS OWN argument into a buffer too. STR_FUNC_POOL_NEXT is a
; simple bump-allocator index (0..STR_FUNC_POOL_SLOTS-1): reserve the
; next free slot before evaluating a string argument, release it
; (decrement) once done — every call site pairs these exactly like the
; array-letter fix's stack push/pop discipline, just via a counter
; instead of the real Z80 stack (32-byte buffers don't fit in a
; register to push). 4 slots covers INSTR's own two SIMULTANEOUS
; arguments plus up to two more levels of nesting elsewhere — generous
; for any realistic program, not unbounded (matches this project's own
; established "small fixed pool" precedent — FOR_STACK_MAX, GOSUB_
; STACK_MAX, SPRITE_SLOT_MAX all made the same tradeoff).
STR_FUNC_POOL_SLOTS EQU 4
; Runtime execution is mutually exclusive with editing, but the static checker
; is not: BASIC_DRAW_STATUS_LINE may validate a stored, flagged statement while
; EDIT_LINE_BUF contains the user's uncommitted edits. String functions invoked
; by that check therefore need an independent pool or they can corrupt the live
; line. This dedicated reservation restores that separation.
; Relocated out of chunk 4 so this persistent-but-fixed scratch does not
; reduce BASIC program space. Chunk 7 is always visible during EXROM calls.
; The measured valid nested-expression stress peak is 126 machine-stack
; bytes; placing this at the former bottom of stack headroom still leaves
; fixed upper-RAM state and module window remain below the genuine stack
; headroom at `$F600-$FEFF` (2,304 bytes below SP=$FF00).
STR_FUNC_POOL        EQU $F328
    ASSERT 128 == (STR_FUNC_POOL_SLOTS * 32)
    ASSERT STR_FUNC_POOL + 128 == $F3A8
    ASSERT STR_FUNC_POOL + 128 <= $FF00
; Minimal numeric DEF FN runtime state. Kept beside the relocated string pool
; so the spike consumes no BASIC program RAM. Definitions are established when
; their DEF statement executes; recursive FN evaluation is rejected.
DEF_FN_NAME          EQU $F3A8
DEF_FN_PARAM         EQU $F3A9
DEF_FN_EXPR_PTR      EQU $F3AA
DEF_FN_ARG           EQU $F3AC
DEF_FN_ACTIVE        EQU $F3AE
    ASSERT DEF_FN_ACTIVE + 1 == $F3AF
    ASSERT DEF_FN_ACTIVE + 1 <= $FF00
; Single-slot loadable BASIC-extension proof registry. Registration is only
; valid through BASIC_EXTENSION_REGISTER, which writes the magic last and
; invalidates the editor's cached checker verdict. NEW/cold init clear magic.
; The module payload itself is loaded at EXTENSION_MODULE_BASE and must remain
; below EXTENSION_MODULE_LIMIT, leaving more than 2K of stack headroom.
EXTENSION_MAGIC       EQU $F3AF       ; 2 bytes; zero means no extension
EXTENSION_NAME_PTR    EQU $F3B1       ; 2 bytes; null-terminated RAM keyword
EXTENSION_EXEC_PTR    EQU $F3B3       ; 2 bytes; callback after two args parsed
INSTR_POS             EQU $F3B5       ; current 1-based candidate position
EXT_SERVICE_VERSION_ADDR EQU $F3B6
EXT_SERVICE_REGISTER     EQU $F3B7    ; three-byte callable JP veneer
EXT_SERVICE_PRINT_ATTR   EQU $F3BA
EXT_SERVICE_WRITE_PIXEL  EQU $F3BD
EXT_SERVICE_READ_OVER    EQU $F3C0
EXT_SERVICE_TABLE_END    EQU $F3C3
EXTENSION_GRAMMAR        EQU $F3C3       ; 0=expr,expr; 1=LINE-shaped
EXTENSION_ARG0           EQU $F3C4
EXTENSION_ARG1           EQU $F3C5
EXTENSION_ARG2           EQU $F3C6
EXTENSION_ARG3           EQU $F3C7
EXT_SERVICE_ABI_VERSION  EQU 1
EXTENSION_REG_MAGIC   EQU $5845       ; "EX" little-endian
EXTENSION_MODULE_BASE EQU $F400
EXTENSION_MODULE_LIMIT EQU $F600
    ASSERT INSTR_POS + 1 == $F3B6
    ASSERT EXT_SERVICE_VERSION_ADDR == INSTR_POS + 1
    ASSERT EXT_SERVICE_REGISTER == EXT_SERVICE_VERSION_ADDR + 1
    ASSERT EXT_SERVICE_PRINT_ATTR == EXT_SERVICE_REGISTER + 3
    ASSERT EXT_SERVICE_WRITE_PIXEL == EXT_SERVICE_PRINT_ATTR + 3
    ASSERT EXT_SERVICE_READ_OVER == EXT_SERVICE_WRITE_PIXEL + 3
    ASSERT EXT_SERVICE_TABLE_END == EXT_SERVICE_READ_OVER + 3
    ASSERT EXTENSION_ARG3 + 1 <= EXTENSION_MODULE_BASE
    ASSERT EXTENSION_MODULE_LIMIT <= $FF00
STR_FUNC_POOL_NEXT:  DEFS 1           ; 1 byte — next free slot (0-4); reset
                                ; to 0 at MEM_INIT/BASIC_RUN as a safety
                                ; net, same precedent GOSUB_STACK_DEPTH
                                ; already set, though correct pairing
                                ; within a single statement's own
                                ; evaluation should always leave it at
                                ; 0 again on its own
STR_FUNC_CALL_ID:    DEFS 1           ; 1 byte — which STRING_FUNCTION_TABLE
                                ; entry matched; numeric functions now store
                                ; a handler pointer instead
                                ; own shape for the numeric side
STR_FUNC_DEST:       DEFS 2           ; 2 bytes — the CALLER's own target
                                ; buffer (BASIC_EVAL_STR_PRIMARY's own
                                ; DE-in contract), stashed here across
                                ; argument parsing, which needs DE for
                                ; its own purposes (BASIC_EVAL_EXPR's
                                ; result, BASIC_EVAL_STR_EXPR's own
                                ; destination-in-progress)

; NOTE (2026-08-22): a dedicated named-scratch block (STRFN_PATLEN,
; PATPTR, PATIDX, COPYLEN, REMAIN, S1LEN, S1PTR, S2LEN, S2PTR, POS —
; 13 bytes) lived here for FILL$'s wraparound pattern-copy and INSTR's
; two-string search. Both functions were dropped the same day to fit
; Home ROM's own budget (see basic/basic.asm's FUNC_ID_INSTR comment),
; so this whole block went with them — nothing references these
; addresses any more.

; NOTE (2026-08-22): a STR_FUNC_BUDGET/STR_FUNC_ARGBUF pair (caller's
; budget, acquired pool-buffer address) was tried here as shared
; scratch, mirroring STR_FUNC_DEST — then rejected before it shipped:
; a nested string-function call inside this call's OWN argument (e.g.
; UPPER$(LEFT$(A$,3))) recurses back through this exact dispatch and
; would clobber those shared cells before the outer call got to read
; them back, the identical bug class the numeric handler/argc scratch
; ARGC and CUR_VAR_LETTER fixes already hit twice. BASIC_EVAL_STR_
; PRIMARY's own .str_func_call instead stashes the caller's DE/C (and
; each shape's own pool-buffer address) on the REAL Z80 stack, which
; nests correctly at any depth for free — see that routine's own
; header for the full reasoning. STR_FUNC_DEST alone stays a sysvar
; (below) since STRFUNC_EXROM reads it directly with no spare register
; to pass it through instead — it's written fresh from the stack right
; before each BASIC_STRFUNC_EXROM call, never trusted to survive a
; recursive parse on its own.

; ---- string-function ID constants — plain small integers, not
; addresses, but they need to be visible from BOTH basic/basic.asm
; (which sets STR_FUNC_CALL_ID) and rom/exrom_strfuncs.asm
; (which reads it to dispatch) — sysvars.inc is the file both already
; INCLUDE, so this is where a genuinely shared constant like this
; lives, same reasoning UDG_COUNT above already established for a
; count (not an address) that still belongs alongside its own related
; sysvars. STRFUNC_ID_* are string-RETURNING functions, tried from
; string-expression context (basic/basic.asm's BASIC_TRY_EVAL_STR_
; FUNCTION); FUNC_ID_VAL (a NUMBER-returning function that happens to
; take a STRING argument) is tried from the existing numeric FUNCTION_
; TABLE/BASIC_TRY_EVAL_FUNCTION via a reserved argc sentinel
; (ARGC_STR1) rather than a whole second table — see basic/basic.asm's
; own FUNCTION_TABLE comment for why LEN/CODE stayed Home-resident
; instead of also routing through EXROM like VAL does. (INSTR/
; STRFUNC_ID_INSTR/ARGC_STR2 and FILL$/STRFUNC_ID_FILL were both here
; too originally — dropped 2026-08-22 to fit Home ROM's own budget.)
STRFUNC_ID_CHR      EQU 1
STRFUNC_ID_STR      EQU 2
STRFUNC_ID_UPPER    EQU 3
STRFUNC_ID_LOWER    EQU 4
STRFUNC_ID_LEFT     EQU 5
STRFUNC_ID_RIGHT    EQU 6
STRFUNC_ID_INKEY    EQU 8   ; numbering keeps the original gaps where
                            ; STRFUNC_ID_FILL (7) and STRFUNC_ID_INSTR
                            ; (10) used to be, rather than renumbering
                            ; everything after a drop — these are
                            ; internal dispatch IDs, not anything a
                            ; BASIC program can observe
STRFUNC_ID_VAL      EQU 9
ARGC_STR1           EQU 100  ; sentinel FUNC_CALL_ARGC value: 1 string
                             ; argument (LEN, CODE, VAL)
ARGC_STR2           EQU 102  ; two string arguments (INSTR)

; ---- keyword-highlighting bold spans (2026-08-23) ---- BASIC_DETECT_
; KEYWORD_PREFIX used to record just ONE (start=0, length) bold run —
; a leading keyword no line could have more than one of. Extended to
; record every colon-separated segment's own leading keyword (e.g.
; "INK 7:PAPER 5" bolding both INK and PAPER, "IF x THEN y" bolding
; both IF and THEN now that THEN is in KEYWORD_HILITE_TABLE) as a
; small fixed table of spans instead — same "small fixed table, no
; dynamic growth" shape as EDIT_WRAP_START/LEN above. HILITE_KW_LEN
; itself is untouched and still means what it always did (the length
; of whatever BASIC_TRY_DETECT_ONE/_ENDIF most recently matched,
; still used standalone by BASIC_UPPERCASE_KEYWORD_PREFIX at commit
; time, which only ever normalizes the FIRST word — unchanged).
HILITE_KW_MAX_SPANS EQU 4        ; more colon-separated keyword
                                 ; segments than this on one 128-byte
                                 ; line is not realistically reachable
HILITE_KW_COUNT:     DEFS 1           ; 1 byte — how many spans below are
                                ; valid (0-HILITE_KW_MAX_SPANS)
HILITE_KW_START:     DEFS 4           ; HILITE_KW_MAX_SPANS bytes — each
                                ; span's start offset from
                                ; HILITE_LINE_BASE
HILITE_KW_SPANLEN:   DEFS 4           ; HILITE_KW_MAX_SPANS bytes — each
                                ; span's length
HILITE_TABLE_PTR:    DEFS 2           ; 2 bytes — KEYWORD_HILITE_TABLE's own
                                ; real address (basic/basic.asm),
                                ; stashed here by the Home-side
                                ; BASIC_DETECT_KEYWORD_PREFIX wrapper
                                ; on every call so rom/exrom_highlight.
                                ; asm's own table walk can start from
                                ; it — EXROM is a separate compilation
                                ; unit with no way to see that label's
                                ; address directly (the same "Label not
                                ; found" trap CALC_EXIT_TRAMPOLINE's
                                ; own KTAB entry comment documents)

PROG_AREA_START:   ; Current value $84B4. No longer a hand-tracked hex EQU
                                ; (2026-08-23) — see
                                ; this file's own "assembler-computed
                                ; addresses" header. Relocating FILL's
                                ; 10,240 transient bytes and the sprite
                                ; buffers' 2,304 persistent bytes to
                                ; reserved upper HOME RAM moved this from
                                ; $B8C9 to $87C9 on 2026-08-28. Moving the
                                ; label/UDG/editor/detokenizer storage and
                                ; overlaying string scratch then lowered it
                                ; to $8521 on 2026-08-29. The next RAM audit
                                ; overlaid four mutually-exclusive command-
                                ; phase buffers and removed 45 bytes of dead
                                ; state, initially lowering it to $8434. An
                                ; independent lifetime review restored the
                                ; checker-visible 128-byte string-function
                                ; pool, settling the safe layout at $84B4.
                                ; Before that,
                                ; retiring VAR_TABLE/
                                ; STR_TABLE the same day (see "Scalar
                                ; variables in the dynamic pool" above)
                                ; moved this from $BC01 down to $B8B1,
                                ; growing the program+array+scalar
                                ; region from 1023 to 1871 bytes — the
                                ; whole point of that migration. This is
                                ; the LAST manually-narrated move in
                                ; this History chain; the assembler
                                ; derives every value from here on, so
                                ; there's nothing left to hand-retype on
                                ; a future move. History below this
                                ; point is accurate as of the addresses
                                ; that were current through 2026-08-23:
                                ; CURRENT VALUE. Moved from $B769 to
                                ; $BC01 (1176 bytes) 2026-08-23 for
                                ; SPRITE_SLOT_MAX's own 4 -> 8 increase
                                ; above (every SPRITE_SLOT_* array/
                                ; buffer doubling, cascading through
                                ; SPRITE_ARG_SLOT and everything below
                                ; it in this file). A real, deliberate
                                ; trade against user program space —
                                ; program area shrank from $C000-$B769
                                ; (2199 bytes) to $C000-$BC01 (1023
                                ; bytes) for this alone. Before that:
                                ; moved from $B75E to $B769 (11 bytes)
                                ; 2026-08-23 for HILITE_KW_COUNT/START/
                                ; SPANLEN/HILITE_TABLE_PTR above
                                ; (multi-keyword bold highlighting).
                                ; Before that: multi-dimensional
                                ; $B765 (2026-08-22) for ARRAY_DIM2_
                                ; COUNT/ARRAY_INDEX2/ARRAY_DIMN_ARG/
                                ; ARRAY_SUBSCRIPT_COUNT — reverted to
                                ; $B75E the same day when that support
                                ; was archived for Home ROM budget (see
                                ; the note right before STR_FUNC_POOL_
                                ; SLOTS above). Before that: moved
                                ; from $B76B to $B75E (13 bytes
                                ; reclaimed), when the STRFN_PATLEN..POS
                                ; named-scratch block above was removed
                                ; (FILL$/INSTR dropped, 2026-08-22 —
                                ; see the STRFUNC_ID_CHR comment above).
                                ; Before that: moved from $B6DA to $B75E (132 bytes), for
                                ; STR_FUNC_POOL/STR_FUNC_POOL_NEXT/
                                ; STR_FUNC_CALL_ID/STR_FUNC_DEST above
                                ; (string functions + INKEY$ string
                                ; upgrade). Before that: moved from
                                ; $B6D2 to $B6DA (8 bytes), for
                                ; ARRAYS_END/ARRAY_DIM_COUNT/ARRAY_
                                ; INDEX/ARRAY_ASSIGN_VALUE above
                                ; (Phase 3 numeric arrays). Before that:
                                ; moved from $B352 to $B6D2 (896 bytes),
                                ; for STR_TABLE/STR_EXPR_SCRATCH/STR_CMP_
                                ; RIGHT above (Phase 3 string scalars —
                                ; assignment, PRINT, = / <> comparison).
                                ; Before that: moved from $B2A2 to
                                ; $B352 (176 bytes), for
                                ; UDG_TABLE/BLOCK_GFX_SCRATCH above
                                ; (block-graphics + UDG glyph support).
                                ; Before that: moved from $B290 to
                                ; $B2A2 (18 bytes), for GOSUB_
                                ; STACK/GOSUB_STACK_DEPTH above (bare
                                ; GOSUB/RETURN and CALL). Before that:
                                ; moved from $B28F to $B290 (1 byte),
                                ; for BANK_EXROM_DEPTH (the EXROM paging
                                ; reentrancy fix). Before that: moved
                                ; from $B28E to $B28F (1 byte), for
                                ; BASIC_CHECK_ONLY (USR's static-check
                                ; guard). Before that: moved from
                                ; $B274 to $B28E (26 bytes), for the
                                ; "function-result float" scratch above
                                ; (FUNC_RESULT_IS_FLOAT/_NEGATIVE/_FLOAT,
                                ; FLOAT_PRINT_INTPART, SQR_ARG_N,
                                ; SIN_X_RAD/X2/POWER) — SQR/SIN wired
                                ; through rom/exrom_calc.asm's
                                ; calculator engine, see that area's
                                ; own comment.
                                ; Before that: moved from
                                ; $B26C to $B274 (8 bytes), for
                                ; CALC_DIV_REM/CALC_DIV_QUOT above (CALC_
                                ; OP_DIV's own scratch — see rom/exrom_
                                ; calc.asm's header for why these aren't
                                ; just reused from CALC_MUL_ACC/CALC_MUL_
                                ; CAND: those are 8 bytes each, sized for
                                ; MUL's 64-bit product/candidate, and
                                ; naming them for DIV's unrelated 32-bit
                                ; remainder/quotient would read as a typo
                                ; waiting to happen, not a deliberate reuse).
                                ; Before that: moved from
                                ; $B24F to $B26C (29 bytes), for
                                ; CALC_UNP_A/CALC_UNP_B/CALC_SHIFT_COUNT/
                                ; CALC_MUL_ACC/CALC_MUL_CAND above (real
                                ; arithmetic engine scratch space).
                                ; Before that: moved from $B24E to
                                ; $B24F (1 byte), for
                                ; CALC_STACK_OVERFLOW_FLAG above.
                                ; Before that: moved from $B247 to
                                ; $B24E (7 bytes), for the
                                ; calculator dispatcher's rework
                                ; (CALC_LITERAL_PTR/OP1_PTR/OP2_PTR/
                                ; LITERAL_PARAM) above — see rom/exrom_
                                ; calc.asm's header for why the rework
                                ; happened.
                                ; Before that: moved from $B1FD to $B247
                                ; (74 bytes), for the calculator engine
                                ; (CALC_STACK/SP/MEM/BREG/TRUNC_FLAG/
                                ; UNIMPLEMENTED_LITERAL_FLAG) above.
                                ; Before that: moved from $99FD to
                                ; $B1FD (6144 bytes), for
                                ; GFX_FILL_VISITED above.
                                ; Before that: moved from $99F8 to
                                ; $99FD (5 bytes), for the
                                ; SPRITE_ARG_* parse scratch above.
                                ; Before that: moved from $9560 to
                                ; $99F8 (1176 bytes), for the
                                ; SPRITE_SLOT_* state above.
                                ; Before that: moved from $9558 to
                                ; $9560 (8 bytes), for the
                                ; SPRITE_* scratch above.
                                ; Before that: moved from $9555 to
                                ; $9558 (3 bytes), for
                                ; STMT_TARGET_ADDR/STMT_TARGET_MASK
                                ; above.
                                ; Before that: moved from $9554 to
                                ; $9555 (1 byte), to make

    ORG SYSVARS_RETURN_ORG

    ENDIF
