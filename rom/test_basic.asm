; ============================================================================
; rom/test_basic.asm — end-to-end interpreter test
;
; INTERACTIVE, REPL-style, genuinely multi-statement, with REAL
; navigation, deletion, and insertion now. BASIC_COMMAND_LOOP loops
; forever: type a line, press ENTER — it's appended to the growing
; program (or, if you've navigated UP into an existing line first,
; replaces THAT line instead). Type RUN alone to execute the WHOLE
; stored program so far. A blank ENTER (nothing typed) is a no-op.
;
; Arrow UP/DOWN move between existing committed lines — press UP to
; edit a previous line, change it, press ENTER to commit the change
; (which then advances to the next line, same as a normal text editor).
; Any uncommitted changes are discarded if you navigate away without
; pressing ENTER first — there's no undo, so this is deliberate, not a
; bug. A status line at the bottom (row 23, inverse video) shows
; LINE n/m for whichever line you're on, or NEW LINE on the fresh
; uncommitted line — disappears automatically once you RUN. Scrolls
; automatically once the program exceeds 23 lines.
;
; DELETE on an already-empty EXISTING line removes it outright (there's
; nothing left to backspace character-by-character, so DELETE means
; something different there) — everything after it shifts up to fill
; the gap. No-op on the new-line sentinel; only a real committed line
; can be deleted this way.
;
; CAPS SHIFT+1 deletes the current line outright in one keystroke, no
; need to empty it first — same underlying delete-and-shift-up
; behavior as the empty-line DELETE flow above, just reachable
; directly regardless of what's currently in the line buffer.
;
; CAPS SHIFT+ENTER inserts a blank line BEFORE the one currently being
; edited, then positions you on that new blank line to start typing.
; No-op on the sentinel — "insert before the new line" isn't a
; meaningful operation there.
;
; Assignment and PRINT both take full arithmetic expressions now, not
; just a bare literal or variable — +, -, *, /, unary minus, and
; parentheses, with normal precedence (* and / bind tighter than +
; and -). Try:
;   x = 3 + 4 * 2
;   PRINT x               (shows "11" — confirms * binds tighter than +)
;   y = (x + 1) * 2
;   PRINT y                 (shows "24")
;   x = x + 1
;   PRINT x                   (shows "12" — self-referential assignment
;                              reads the OLD x before storing the NEW one)
;
; Labels and GOTO now exist too. A label is a statement that's
; ENTIRELY a bare name followed by ':' — nothing else on that line.
; Both label names and GOTO references are case-insensitive. Try:
;   x = 1
;   loop:
;   PRINT x
;   x = x + 1
;   GOTO loop
;   RUN                 (prints 1, 2, 3, ... forever — there's no
;                        condition to stop it yet, since IF doesn't
;                        exist; this is an infinite loop on purpose,
;                        to confirm GOTO actually jumps backward
;                        repeatedly, not just once. No way to break
;                        out short of resetting the emulator/hardware.
;                        Screen clears and restarts from the top every
;                        24 lines — RUN's output has no true scrolling,
;                        so this is the safe way it handles running
;                        past the bottom of the screen, not a bug.)
;
; Runtime errors are reported now instead of silently doing nothing —
; a message (inverse video, top row) plus the failing statement's text
; below it, then execution stops. Try each of these as a SEPARATE
; single-statement program (clear the others first, or just add one
; and RUN before adding the next):
;   GOTO nowhere        RUN  (shows "LABEL NOT FOUND" and "GOTO nowhere")
;   x = 5 / 0            RUN  (shows "DIVISION BY ZERO" and "x = 5 / 0")
;   qqq                    RUN  (shows "SYNTAX ERROR" and "qqq" — not a
;                                keyword, not an assignment, not a
;                                label either)
; A genuine label ("loop:") should NOT trigger any of this — it's the
; one case that looks similarly "unrecognized" but is actually valid.
;
; Before any of that even runs, a whole-program check pass looks at
; EVERY statement first — try a program with more than one problem:
;   GOTO nowhere
;   qqq
;   RUN                  (goes straight back to the editor view — no
;                        wait, nothing was run — showing both lines,
;                        with the status bar reading "2 ERRORS FOUND"
;                        instead of the usual "LINE n/m"; deliberately
;                        NOT a full-screen message, so the whole
;                        program stays visible while browsing it. The
;                        message clears on the next commit, not on
;                        navigation — try pressing UP/DOWN first and
;                        confirm it stays put. BOTH lines should also
;                        render in RED ink now, not just the first one
;                        found — recognized keywords within them stay
;                        bold, same as always, just bold-red instead
;                        of bold-black. Fix and commit just one of the
;                        two lines, and only the remaining broken one
;                        should still show red.)
; This check isn't exhaustive — something like "PRINT x/y" can't be
; statically flagged as division by zero unless y happens to be a
; literal 0, since a static pass has no way to know what a variable
; will hold without actually running the program. The single-error
; runtime checks above still catch that case when real execution
; reaches it.
;
; With the two errors above still showing, SYMBOL SHIFT+A jumps to the
; next flagged statement, SYMBOL SHIFT+S to the previous — try both
; from either line and confirm it cycles between just the two errors
; (wrapping at either end), regardless of where in the program you
; start or how many valid lines sit in between. The status bar should
; also show that SPECIFIC line's own message while you're on it —
; "LABEL NOT FOUND" on "GOTO nowhere", "SYNTAX ERROR" on "qqq" — not
; just the overall "2 ERRORS FOUND"; moving back to the sentinel (or
; any unflagged line) reverts to the generic count.
;
; Try, across separate ENTER presses:
;   x = 5
;   PRINT x
;   RUN             (shows "5" — two statements run together)
;   PRINT "HELLO"
;   RUN               (now runs all three statements in order)
; Then press UP twice to land back on "x = 5", change the 5 to a
; different number, press ENTER (commits the change and moves down to
; "PRINT x"), then RUN again — the new value should show. Try CAPS
; SHIFT+ENTER while on "PRINT x" to insert a blank line before it, type
; something there, then press UP and DELETE on an empty existing line
; to remove it again.
;
; Recognized keywords (print, input, run, end, stop, goto) auto-
; uppercase and render bold once a line is COMMITTED (ENTER) — not
; while still being typed, which always shows plain. "printer" or
; similar deliberately does NOT trigger this (a real word boundary is
; required after the match) — this now applies at EXECUTION time too,
; not just display: a label named "goto" would previously have been
; caught by the GOTO dispatch itself, a real gap fixed alongside adding
; GOTO (see docs/programmers_reference.md).
;
; HELP is now a real command, typed at the command line like RUN:
;   HELP                  (lists available topics — currently just
;                         EDITOR — full-screen, press any key to return)
;   HELP EDITOR            (shows the editor's navigation keys and the
;                          SYMBOL SHIFT+A/S error-navigation keys from
;                          above, full-screen, press any key to return)
;   HELP NOWHERE             (unrecognized topic — falls back to the
;                            same topic list as plain HELP, not an
;                            error)
; Confirm the screen you were on before HELP (mid-edit line, error
; highlighting, scroll position) is intact and redraws correctly once
; you return — this exercises the same BASIC_RESET_ROW_SHADOW path RUN
; uses, so a stale-shadow regression here would look like leftover
; HELP text not being cleared, or a settled line failing to redraw.
;
; This is the ongoing test exercising the FULL pipeline together:
; kernel/editor (typing and navigation, via basic/'s
; EDITOR_REDRAW_HOOK and EDITOR_NAV_HOOK, and now also the error-
; navigation pseudo-directions via the same hook) -> basic/'s
; tokenizer -> kernel/memory (storage — append, in-place replace,
; mid-program insert via MEM_LINE_INSERT, range delete via
; MEM_LINE_DELETE_RANGE, and the label table via MEM_LABEL_ADD/LOOKUP/
; TABLE_CLEAR) -> kernel/memory's iterator (RUN, redrawing, and
; finding a statement by index for navigation) -> basic/'s expression
; evaluator (BASIC_EVAL_EXPR and friends) -> kernel/math
; (MATH_MULTIPLY16/MATH_DIVIDE16, for the * and / operators) ->
; basic/'s label scanner, whole-program check pass, statement
; executor (including GOTO), error reporter (BASIC_REPORT_ERROR,
; BASIC_DRAW_STATUS_LINE), and error-list search (BASIC_FIND_NEXT_
; ERROR/PREV_ERROR) -> kernel/graphics (output, including
; GFX_PUTCHAR_BOLD for keyword highlighting, GFX_INVERT_ATTR_STATIC
; for the status line, and GFX_SET_ATTR for red error lines). A
; failure anywhere in this chain would show up here even if every
; individual module's own tests passed.
;
; Expression evaluation, labels, GOTO, single-error runtime reporting,
; the whole-program check pass (with its status-bar display),
; red-highlighted error lines, SYMBOL SHIFT+A/S error navigation, and
; per-line error messages in the status bar are all confirmed working —
; including several real bugs found and fixed along the way: RUN's
; output row had no bounds check (corrupting the screen past row 23),
; the error display read a message pointer AFTER a call that clobbers
; it (garbage instead of the intended message), GOTO permanently
; rewrote its own label reference in the stored program the first time
; it ran, the check-failure display moved from a full-screen takeover
; to the status bar after direct feedback, the red-coloring loop never
; saved HL across 32 calls to a routine that destroys it, an accidental
; global label silently broke sjasmplus's local-label scoping and meant
; an entire round of navigation testing ran against a stale binary that
; never contained the feature being tested, and MEM_LINE_NEXT destroys
; DE per its own documented contract, but a loop restored its index
; counter from the stack before calling it rather than after, silently
; corrupting the count (see docs/programmers_reference.md for the full
; account of all of these, including a purpose-built scope checker now
; used to catch the first class of mistake going forward).
;
; The screen-flicker fix's first real test — a screenshot of a black
; screen with just one gray bar at the top, on cold boot — surfaced two
; real bugs at once, both the same underlying mistake in two different
; places: removing the per-redraw GFX_CLS meant nothing established the
; normal background for rows the render loop never actually touches
; (almost the entire screen, at cold boot with an empty program), and
; separately, BASIC_RUN's own unconditional GFX_CLS for program output
; never told the shadow state that had happened, so returning to the
; editor afterward incorrectly skipped redrawing rows that clear had
; just wiped blank. Both fixed with a new BASIC_RESET_ROW_SHADOW,
; called once at cold boot and once right after BASIC_RUN's own clear.
; This was the single largest change made to BASIC_REDRAW_PROGRAM, the
; project's most complex routine, in one pass — every piece was
; verified via a Python simulation of its exact behavior before being
; written in Z80, and a real near-miss (an incorrect sysvar address
; expression) was caught by this project's own overlap-checking process
; before it ever reached the assembler — but real testing still found
; two genuine gaps that verification alone had missed, underscoring why
; this project treats actual runs, not just careful design, as
; necessary (see docs/programmers_reference.md for the full account).
;
; IF/ELSEIF/ELSE/END IF now exist too — block form (nestable, with
; ELSEIF chains), a single-line short form (IF <cond> THEN <stmt>, no
; END IF needed), relational operators (= <> < > <= >=), and AND/OR/
; NOT (no short-circuiting — both sides of AND/OR always evaluate).
; See README.md's "Testing basic/" section for specific programs to
; try, including a GOTO loop that can finally break on a real
; condition instead of running forever. A genuine "IF WITHOUT END IF"
; error is reported at RUN time for an unterminated block — the static
; checker validates each IF/ELSEIF/ELSE/END IF line's own syntax but
; doesn't verify whole-program block balance (see
; docs/programmers_reference.md's "IF/ELSEIF/ELSE/END IF" section for
; why, and for the full execution-mechanism writeup).
;
; CLS, REM, BORDER <n>, and NEW now exist too — the first batch pulled
; directly from docs/basic_language_reference.md's remaining gap list.
; CLS clears the screen and resets where PRINT writes next back to row
; 0. REM is a comment — everything after the keyword is ignored,
; whatever it says (matches bare "REM" only; the full "REMark" spelling
; from the design doc isn't recognized yet, consistent with every
; other keyword in this project having no optional-letter abbreviation
; support). BORDER <n> takes a full expression, not just a literal,
; and sets the screen border via a new kernel/graphics routine
; (GFX_SET_BORDER). NEW is a second immediate command alongside RUN —
; typed alone, it clears the stored program AND all 26 variables,
; dropping back to the same fresh state as cold boot.
;
; INK <n>, PAPER <n>, FLASH <n>, INVERSE <n>, and OVER <n> now exist
; too, same shape as BORDER <n> but for text rather than the screen
; edge. Unlike BORDER, INK/PAPER/FLASH/INVERSE actually change what
; PRINT draws - see docs/programmers_reference.md's "INK / PAPER /
; FLASH / INVERSE / OVER" section for how the attribute byte is
; computed. OVER is stored/validated but doesn't affect drawing yet
; (documented gap). NEW/cold boot now reset all five back to defaults
; the same way they already reset BORDER.
;
; USER-CONFIRMED WORKING: INK/PAPER/FLASH/INVERSE genuinely change
; printed text colour on real hardware/Fuse. A real bug was found and
; fixed along the way (GFX_PRINT_STRING_ATTR's own cross-call scratch
; value was accidentally a ROM-resident DB byte rather than a RAM
; sysvar, so PRINT's attribute write was silently a no-op every time,
; landing on the DB's compile-time 0 regardless of what INK/PAPER
; actually said) - see docs/programmers_reference.md's own section
; for the full writeup, including how a raw memory dump (not static
; analysis) is what actually found it.
;
; AT <row>,<col> and TAB <col> now position the next PRINT statement —
; AT sets both row (clamped 0-23) and column (masked 0-31), TAB sets
; column only. Positioning lasts for exactly one PRINT: the following
; line automatically resets back to column 0, matching classic
; Sinclair BASIC's own AT/TAB behavior. See
; docs/programmers_reference.md's "AT / TAB" section for the full
; write-up, including the documented negative-row clamp limitation.
; Shares BASIC_STMT_PRINT's output path with the now-fixed INK/PAPER
; work above, but not yet specifically retested by the user itself.
;
; LIST, EDIT <label>, and DELETE <start>,<end> now exist too — three
; new IMMEDIATE commands (typed and committed like RUN/NEW, not
; program statements). LIST jumps the editor view to the top of the
; program; EDIT <label> jumps straight to that label's line (rebuilds
; the label table first, so it works even before the program has ever
; been RUN); DELETE <start>,<end> removes a 1-based inclusive range of
; program lines (the first line is 1, matching how a listing reads top
; to bottom). Any malformed/out-of-range DELETE or EDIT, or a typed 0,
; leaves the program unchanged. USER-CONFIRMED: EDIT/DELETE both did
; nothing at all — FOUR real bugs found and fixed, each different.
; EDIT had two: BASIC_PARSE_IDENTIFIER writes into a scratch buffer,
; DETOK_BUF, shared across basic/ — BASIC_SCAN_LABELS overwrites it
; internally while rebuilding the label table, so the label name was
; gone by the time the lookup ran (fixed by copying it out first);
; then, even after that fix, the length value ALSO didn't survive the
; same BASIC_SCAN_LABELS call (it destroys BC too, not just
; DETOK_BUF) — fixed with a second push/pop specifically around that
; call. DELETE had two more: first a build failure, not a code bug:
; the user's compile actually errored ("JR Target out of range" x3 in
; BASIC_DO_DELETE, .fail sitting too far away for a couple of its
; jumps), so Fuse was almost certainly still running an older binary
; that predated this routine (fixed: jr -> jp for every jump to
; .fail/.fail_pop in that routine, not just the three flagged). Once
; it could finally compile, another real bug surfaced: the "nothing
; else should follow" check compared against $0D (carriage return,
; correct for already-tokenized PROGRAM text) instead of $00 (the
; real terminator for EDIT_LINE_BUF, the just-typed text this routine
; actually reads) — copied from BASIC_STMT_AT's own check without
; noticing the two operate on different kinds of text (fixed: cp $0D
; -> or a). A memory dump then confirmed the delete itself was always
; correct, but the SCREEN kept showing stale content afterward — a
; FOURTH bug, a stale redraw: DELETE never called
; BASIC_RESET_ROW_SHADOW after its structural change, unlike
; NEW/RUN/HELP, which all do (fixed: added the missing call).
; USER-CONFIRMED: EDIT <label> now works correctly, and DELETE's
; redraw fix worked too — the next report turned out to be the screen
; correctly showing a 0-based deletion, not a redraw bug. That
; surfaced a FIFTH change, a design one not a bug: DELETE counted from
; 0 (matching this project's internal indexing exactly as designed)
; but not how anyone reading a listing top to bottom expects — changed
; to 1-based, narrowly, only in how DELETE's own typed numbers are
; interpreted; everything else stays 0-based internally, unchanged.
; USER-CONFIRMED working. A SIXTH change (user-requested, not a bug):
; a rejected DELETE now shows "INVALID RANGE" in the status bar for
; one redraw — new DELETE_INVALID_FLAG sysvar, set by the dispatch,
; read-and-cleared by BASIC_DRAW_STATUS_LINE on its very next run
; (deliberately NOT sticky like CHECK_ERROR_COUNT's own "N ERRORS
; FOUND" — nothing ongoing left to warn about once the bad text is
; already gone). A SEVENTH bug found (user-reported, affects ALL SIX
; immediate commands, not just DELETE): editing an EXISTING line to
; read something like "DELETE 3,3" and pressing ENTER EXECUTED it
; instead of committing the text edit — every immediate command was
; checked for unconditionally regardless of whether CUR_EDIT_POS was
; the sentinel (new line) or an existing statement. Confirmed via
; memory dump: PROG_END still showed the same statement count, the
; original stored text was untouched, yet DELETE_START/DELETE_END
; showed the new range had genuinely been parsed. Fixed with ONE
; guard ahead of the whole RUN/NEW/HELP/LIST/EDIT/DELETE dispatch
; chain (BASIC_IS_SENTINEL check, JP not JR since it needs to clear
; the entire chain, well beyond JR's own range) rather than patching
; each command separately. USER-CONFIRMED this fix is the intended
; behavior going forward. EIGHTH feature, user-requested follow-up: a
; rejected command's text now auto-removes itself once the cursor
; moves on (any navigation via BASIC_HANDLE_NAV) rather than becoming
; a permanent stored line — new PENDING_DELETE_POS sysvar, set at
; commit time alongside DELETE_INVALID_FLAG, consumed by a prepended
; guard at BASIC_HANDLE_NAV's own entry (existing tested logic there
; left completely untouched). Scope limit stated directly: only
; triggers on explicit navigation, not on typing further lines or
; pressing RUN without navigating first. See
; docs/programmers_reference.md's "LIST / EDIT / DELETE" section for
; the full write-up. MERGE was deliberately NOT built — LOAD now
; exists (kernel/storage/storage.asm, built in a separate, parallel
; conversation — see docs/programmers_reference.md's own kernel/
; storage section) but replaces the current program outright rather
; than merging into it; MERGE itself remains a genuinely separate,
; unbuilt command.
;
; Statement separator (:) now implemented too — the last item from
; this session's original list. A line is pre-split into colon-
; separated segments, each fed to the existing, completely unmodified
; statement dispatch as if it were its own standalone statement, so no
; individual statement handler needed to change. A ':' inside a
; quoted string or after REM is just text, never a separator. Empty
; statements (double colon, trailing colon) are silently allowed,
; matching classic BASIC. Works inside single-line IF's THEN branch
; too now. Labels still cannot share a line with other statements —
; deliberate, keeps this feature's risk to GOTO/labels at zero by
; construction (the label-recognition code path is untouched, not
; just tested), not an oversight. See
; docs/programmers_reference.md's own "Statement separator" section
; for the full write-up, including the Python verification done
; before any Z80 was written.
;
; THIS FILE IS A MERGE of two separate, parallel conversations — one
; building the statement separator above, the other rebuilding SAVE/
; LOAD from scratch (see docs/programmers_reference.md's kernel/
; storage section for that work's own history, including its own
; separately-confirmed test results). Both conversations branched from
; the same starting point and independently added new sysvars in the
; same free address range ($60C3 onward) for completely unrelated
; purposes; reconciled with a full from-scratch overlap check across
; EVERY sysvar in the merged include/sysvars.inc, not just the ones
; either side touched — see that file's own PROG_AREA_START comment
; for the exact addresses. The statement-separator code itself has
; not been assembled/tested against a real build as of this merge
; (verified via Python simulation and static analysis only, same as
; every other feature before its first real test in this project).
;
; See README.md's "Testing basic/" section for specific programs to
; try. Static checks (duplicate labels, local-label scope, stack-
; ordering fingerprints) all clean.
;
; UPDATED 2026-08-18 — no longer self-contained: the whole-program
; checker (BASIC_SCAN_LABELS, BASIC_CHECK_PROGRAM, and the per-
; statement grammar checker they depend on) now lives in EXROM, not
; here — see the ROM-size writeup in this project's own working
; memory. UPDATED AGAIN 2026-08-19 — SAVE/LOAD moved to EXROM too (see
; rom/exrom_storage.asm); kernel/storage/storage.asm is no longer
; INCLUDEd here at all. Both subsystems now assemble together from
; ONE driver, rom/exrom_build.asm — see that file's own header. This
; file's own rom1.bin placeholder reference below is now WRONG for any
; test that RUNs, EDITs, LOADs, SAVEs, or otherwise triggers a check
; pass: rom-ts2068-1 MUST be exrom.bin (built from rom/exrom_build.
; asm), not an all-zero or unrelated placeholder, or every one of
; those operations will page in garbage and crash. CONFIRMED WORKING
; ON REAL HARDWARE (2026-08-19) with a real exrom.bin paired in, for
; both changes: `x = 1c`/`INK 1c` show red WHILE TYPING (checker), and
; a real SAVE+LOAD round-trip completed correctly (storage) — see this
; project's own working memory for both confirmations, plus the
; subsequent RUN-requires-multiple-presses investigation that ran
; against this same production build afterward.
;
; Build:
;   sjasmplus rom/test_basic.asm
;   sjasmplus rom/exrom_build.asm
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_basic.bin \
;        --rom-ts2068-1 exrom.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    DEFINE EXROM_JUMPTABLE_HOME_SIDE     ; must precede the INCLUDE
                                         ; below — selects the `jp`-
                                         ; emitting branch of KTAB_LIST
                                         ; rather than the EQU-emitting
                                         ; one exrom_build.asm gets
    INCLUDE "include/exrom_jumptable.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START

    DS   $0028 - $, $FF
; ---- RST 28: calculator engine entry point (matches the real
; Spectrum ROM's own RST $28 convention). MUST be a bare `jp`, not
; `call` — see basic/basic.asm's CALC_ENTRY_TRAMPOLINE header for why
; (RST pushed the literal-op byte stream's address as the return
; address; the calculator itself needs that exact value untouched on
; top of the stack). Added 2026-08-20 alongside rom/exrom_calc.asm —
; this file (not rom/main.asm, an earlier bring-up driver not used for
; real builds) is what test_basic.bin actually assembles from, so this
; is the vector that has to carry the real wiring. ----
RST_28:
    jp   CALC_ENTRY_TRAMPOLINE

    DS   $0038 - $, $FF
; ---- RST 38 / IM 1 maskable interrupt entry point ----
; Real keyboard-scan ISR now lives here — see kernel/interrupt/
; interrupt.asm's own header for why this exists (confirmed root
; cause of the editor's keyboard-lag/lost-keystroke bugs) and the
; open question about the real tick rate this assumes.
RST_38:
    call KBD_ISR_TICK
    ei
    reti

; ---- EXROM call table — single source of truth is now include/
; exrom_jumptable.inc's own KTAB_LIST macro (2026-08-18 rework); this
; file no longer hand-maintains a copy of the entry list, only invokes
; it. See that file's own header for the full reasoning. ----
    ORG  KTAB_BASE
    KTAB_LIST
    ASSERT $ <= KTAB_END                 ; catches KTAB_LIST changing
                                        ; entry COUNT without KTAB_
                                        ; COUNT being bumped to match
    DB   KTAB_MAGIC                      ; at KTAB_MAGIC_ADDR (==
                                        ; KTAB_END) — EXROM_VERIFY_
                                        ; KTAB_MAGIC checks this
                                        ; against its own build's
                                        ; KTAB_MAGIC before trusting
                                        ; the table above for real work

    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_INIT
    call KBD_ISR_INIT                ; kernel/interrupt — must run
                                     ; before the EI below, so RST_38
                                     ; never fires against
                                     ; uninitialized KBD_* state
    ; EDITOR_INIT is no longer called here — BASIC_COMMAND_LOOP now
    ; calls it itself at the start of every loop iteration (including
    ; the first), since it needs to reset the line buffer between
    ; commands anyway, not just once at cold start

    im   1
    ei                                ; real interrupts now on —
                                     ; previously never enabled at all
                                     ; (kernel/interrupt didn't exist);
                                     ; SAVE/LOAD (now in EXROM — see
                                     ; rom/exrom_storage.asm) still DI
                                     ; around their own tape-timing-
                                     ; critical sections and now re-EI
                                     ; on return (see basic.asm's
                                     ; BASIC_SAVE_EXROM/_LOAD_EXROM)

    call BASIC_COMMAND_LOOP          ; never returns — see file header

    INCLUDE "basic/basic.asm"
                                    ; kernel/editor/editor.asm no longer
                                    ; INCLUDEd here (2026-08-22) — moved
                                    ; whole to EXROM (rom/exrom_editor.
                                    ; asm) in a ROM-shrink pass; basic.
                                    ; asm's own BASIC_EDITOR_*_EXROM
                                    ; wrappers call it via the fixed
                                    ; $C060-$C089 entry stubs instead of
                                    ; calling kernel/editor labels
                                    ; directly.
    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/io/io.asm"
    INCLUDE "kernel/graphics/graphics.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "kernel/sound/sound.asm"
    INCLUDE "kernel/interrupt/interrupt.asm"
    INCLUDE "kernel/bank/bank.asm"
                                    ; kernel/storage/storage.asm no
                                    ; longer INCLUDEd here (2026-08-19)
                                    ; — SAVE/LOAD moved to EXROM, see
                                    ; rom/exrom_storage.asm. basic.asm's
                                    ; BASIC_STMT_SAVE/LOAD now call the
                                    ; thin BASIC_SAVE_EXROM/_LOAD_EXROM
                                    ; wrappers instead of STORAGE_SAVE/
                                    ; STORAGE_LOAD directly.

    DS   $4000 - $, $FF

    SAVEBIN "test_basic.bin", $0000, $4000
